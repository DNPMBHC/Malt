/*
 * malt_vmnet_bridge.c — Minimal macOS LaunchDaemon bridge from QEMU `-netdev stream`
 * Unix domain sockets to Apple's kernel `vmnet.framework` (VMNET_SHARED_MODE).
 *
 * Owner: @DNPMBHC
 * Compliance: Pure networking bridge (TCP/UDP/ICMP/ARP/DHCP via macOS kernel vmnet).
 * Requires NO paid Apple Developer ID signing and NO SIP disabling — only a one-time
 * standard administrator LaunchDaemon installation.
 *
 * Protocol: QEMU `-netdev stream,id=net0,server=off,addr.type=unix,path=<sock>`
 * framing: 4-byte big-endian uint32 frame length followed by raw Ethernet frame bytes.
 */

#include <arpa/inet.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread/qos.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <unistd.h>
#include <vmnet/vmnet.h>
#include <xpc/xpc.h>

#define MALT_VMNET_BRIDGE_VERSION "1.1.0"
#define DEFAULT_SOCKET_PATH "/var/run/malt-vmnet-bridge.sock"
#define MAX_ETH_FRAME_BYTES 65536

static volatile sig_atomic_t g_stop_requested = 0;
static int g_listen_fd = -1;
static char g_socket_path[sizeof(((struct sockaddr_un *)0)->sun_path)] = DEFAULT_SOCKET_PATH;

/* Root owns the parent directory; only the active console user owns the socket. */
static uid_t console_uid(void) {
    struct stat info;
    if (stat("/dev/console", &info) != 0 || info.st_uid < 501) {
        return 0;
    }
    return info.st_uid;
}

static bool client_authorized(int fd) {
    uid_t peer_uid = 0;
    gid_t peer_gid = 0;
    uid_t active_uid = console_uid();
    return active_uid >= 501 && getpeereid(fd, &peer_uid, &peer_gid) == 0 && peer_uid == active_uid;
}

static bool refresh_socket_owner(void) {
    uid_t owner = console_uid();
    struct stat info;
    if (lstat(g_socket_path, &info) != 0 || !S_ISSOCK(info.st_mode)) {
        return false;
    }
    if (info.st_uid != owner && chown(g_socket_path, owner, 0) != 0) {
        return false;
    }
    return chmod(g_socket_path, 0600) == 0;
}

static void handle_signal(int sig) {
    (void)sig;
    g_stop_requested = 1;
    if (g_listen_fd >= 0) {
        close(g_listen_fd);
        g_listen_fd = -1;
    }
}

static bool write_all(int fd, const uint8_t *buf, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        if (!client_authorized(fd) || g_stop_requested) {
            return false;
        }
        ssize_t n = write(fd, buf + sent, len - sent);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return false;
        }
        if (n == 0) {
            return false;
        }
        sent += (size_t)n;
    }
    return true;
}

static bool read_all(int fd, uint8_t *buf, size_t len) {
    size_t got = 0;
    while (got < len) {
        if (!client_authorized(fd) || g_stop_requested) {
            return false;
        }
        struct pollfd waiter = {.fd = fd, .events = POLLIN};
        int ready = poll(&waiter, 1, 1000);
        if (ready < 0 && errno == EINTR) {
            continue;
        }
        if (ready == 0) {
            continue;
        }
        if (ready < 0 || !(waiter.revents & POLLIN)) {
            return false;
        }
        ssize_t n = read(fd, buf + got, len - got);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return false;
        }
        if (n == 0) {
            return false;
        }
        got += (size_t)n;
    }
    return true;
}

typedef struct {
    int client_fd;
    interface_ref iface;
    size_t max_pkt_size;
    dispatch_queue_t vmnet_queue;
    dispatch_queue_t tx_queue;
    _Atomic bool closed;
} bridge_session_t;

static void bridge_handle_client(int client_fd) {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);

    int buf_sz = 4 * 1024 * 1024;
    setsockopt(client_fd, SOL_SOCKET, SO_RCVBUF, &buf_sz, sizeof(buf_sz));
    setsockopt(client_fd, SOL_SOCKET, SO_SNDBUF, &buf_sz, sizeof(buf_sz));
    struct timeval write_timeout = {.tv_sec = 2, .tv_usec = 0};
    setsockopt(client_fd, SOL_SOCKET, SO_SNDTIMEO, &write_timeout, sizeof(write_timeout));

    bridge_session_t *sess = calloc(1, sizeof(bridge_session_t));
    if (!sess) {
        close(client_fd);
        return;
    }
    sess->client_fd = client_fd;
    sess->max_pkt_size = 1518;
    sess->vmnet_queue = dispatch_queue_create(
        "com.malt.vmnet-bridge.vmnet",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0)
    );
    sess->tx_queue = dispatch_queue_create(
        "com.malt.vmnet-bridge.tx",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0)
    );

    xpc_object_t desc = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(desc, vmnet_operation_mode_key, VMNET_SHARED_MODE);
    xpc_dictionary_set_bool(desc, vmnet_enable_isolation_key, false);

    dispatch_semaphore_t start_sem = dispatch_semaphore_create(0);
    __block vmnet_return_t start_status = VMNET_FAILURE;

    sess->iface = vmnet_start_interface(desc, sess->vmnet_queue, ^(vmnet_return_t status, xpc_object_t interface_param) {
        start_status = status;
        if (status == VMNET_SUCCESS && interface_param != NULL) {
            uint64_t mp = xpc_dictionary_get_uint64(interface_param, vmnet_max_packet_size_key);
            if (mp >= 1518 && mp <= MAX_ETH_FRAME_BYTES) {
                sess->max_pkt_size = (size_t)mp;
            }
        }
        dispatch_semaphore_signal(start_sem);
    });
    xpc_release(desc);

    dispatch_semaphore_wait(start_sem, DISPATCH_TIME_FOREVER);
    if (sess->iface == NULL || start_status != VMNET_SUCCESS) {
        fprintf(stderr, "[malt-vmnet-bridge] vmnet_start_interface failed (status=%u). Ensure daemon runs as root LaunchDaemon.\n",
                (unsigned)start_status);
        close(client_fd);
        dispatch_release(sess->vmnet_queue);
        dispatch_release(sess->tx_queue);
        free(sess);
        return;
    }

    uint8_t *rx_buf = malloc(sess->max_pkt_size);
    if (!rx_buf) {
        goto cleanup;
    }

    vmnet_interface_set_event_callback(
        sess->iface,
        VMNET_INTERFACE_PACKETS_AVAILABLE,
        sess->vmnet_queue,
        ^(interface_event_t event_id, xpc_object_t event) {
            (void)event_id;
            if (sess->closed) {
                return;
            }
            uint64_t avail = xpc_dictionary_get_uint64(event, vmnet_estimated_packets_available_key);
            int budget = (avail > 0 && avail < 64) ? (int)avail : 32;
            for (int i = 0; i < budget && !sess->closed; i++) {
                struct iovec iov = {
                    .iov_base = rx_buf,
                    .iov_len = sess->max_pkt_size,
                };
                struct vmpktdesc pkt = {
                    .vm_pkt_size = sess->max_pkt_size,
                    .vm_pkt_iov = &iov,
                    .vm_pkt_iovcnt = 1,
                    .vm_flags = 0,
                };
                int pkt_cnt = 1;
                vmnet_return_t rc = vmnet_read(sess->iface, &pkt, &pkt_cnt);
                if (rc != VMNET_SUCCESS || pkt_cnt <= 0) {
                    break;
                }
                if (pkt.vm_pkt_size == 0 || pkt.vm_pkt_size > MAX_ETH_FRAME_BYTES) {
                    continue;
                }
                uint32_t net_len = htonl((uint32_t)pkt.vm_pkt_size);
                uint8_t *copy = malloc(4 + pkt.vm_pkt_size);
                if (!copy) {
                    continue;
                }
                memcpy(copy, &net_len, 4);
                memcpy(copy + 4, rx_buf, pkt.vm_pkt_size);
                size_t total = 4 + pkt.vm_pkt_size;
                dispatch_async(sess->tx_queue, ^{
                    if (!sess->closed) {
                        if (!write_all(sess->client_fd, copy, total)) {
                            sess->closed = 1;
                            shutdown(sess->client_fd, SHUT_RDWR);
                        }
                    }
                    free(copy);
                });
            }
        }
    );

    uint8_t *tx_buf = malloc(MAX_ETH_FRAME_BYTES);
    if (tx_buf) {
        uint8_t hdr[4];
        while (!sess->closed && !g_stop_requested) {
            if (!read_all(client_fd, hdr, 4)) {
                break;
            }
            uint32_t frame_len = 0;
            memcpy(&frame_len, hdr, 4);
            frame_len = ntohl(frame_len);
            if (frame_len == 0 || frame_len > MAX_ETH_FRAME_BYTES) {
                break;
            }
            if (!read_all(client_fd, tx_buf, frame_len)) {
                break;
            }
            struct iovec iov = {
                .iov_base = tx_buf,
                .iov_len = frame_len,
            };
            struct vmpktdesc pkt = {
                .vm_pkt_size = frame_len,
                .vm_pkt_iov = &iov,
                .vm_pkt_iovcnt = 1,
                .vm_flags = 0,
            };
            int pkt_cnt = 1;
            (void)vmnet_write(sess->iface, &pkt, &pkt_cnt);
        }
        free(tx_buf);
    }

cleanup:
    sess->closed = 1;
    vmnet_interface_set_event_callback(sess->iface, VMNET_INTERFACE_PACKETS_AVAILABLE, NULL, NULL);
    dispatch_semaphore_t stop_sem = dispatch_semaphore_create(0);
    vmnet_stop_interface(sess->iface, sess->vmnet_queue, ^(vmnet_return_t status) {
        (void)status;
        dispatch_semaphore_signal(stop_sem);
    });
    dispatch_semaphore_wait(stop_sem, DISPATCH_TIME_FOREVER);
    dispatch_sync(sess->tx_queue, ^{});
    free(rx_buf);
    close(client_fd);
    dispatch_release(sess->vmnet_queue);
    dispatch_release(sess->tx_queue);
    free(sess);
}

static void print_usage(const char *prog) {
    fprintf(stderr,
            "Usage: %s [--socket <path>] [--mode <octal>] [--self-check] [--version]\n",
            prog);
}

int main(int argc, char **argv) {
    mode_t socket_mode = 0600;
    bool self_check = false;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--version") == 0) {
            printf("malt-vmnet-bridge %s\n", MALT_VMNET_BRIDGE_VERSION);
            return 0;
        } else if (strcmp(argv[i], "--self-check") == 0) {
            self_check = true;
        } else if (strcmp(argv[i], "--socket") == 0 && i + 1 < argc) {
            const char *path = argv[++i];
            if (strcmp(path, DEFAULT_SOCKET_PATH) != 0) {
                fprintf(stderr, "only the fixed system socket is permitted\n");
                return 2;
            }
            snprintf(g_socket_path, sizeof(g_socket_path), "%s", path);
        } else if (strcmp(argv[i], "--mode") == 0 && i + 1 < argc) {
            const char *mode = argv[++i];
            if (strcmp(mode, "0600") != 0 && strcmp(mode, "600") != 0) {
                fprintf(stderr, "socket mode must be 0600\n");
                return 2;
            }
            socket_mode = 0600;
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            print_usage(argv[0]);
            return 0;
        } else {
            print_usage(argv[0]);
            return 2;
        }
    }

    if (self_check) {
        bool symbols_linked = (&vmnet_start_interface != NULL && &vmnet_stop_interface != NULL &&
                               &vmnet_read != NULL && &vmnet_write != NULL);
        printf("{\"ok\":%s,\"version\":\"%s\",\"uid\":%u,\"vmnet_symbols_linked\":%s,\"default_socket\":\"%s\"}\n",
               symbols_linked ? "true" : "false",
               MALT_VMNET_BRIDGE_VERSION,
               (unsigned)geteuid(),
               symbols_linked ? "true" : "false",
               g_socket_path);
        return symbols_linked ? 0 : 1;
    }

    if (geteuid() != 0) {
        fprintf(stderr, "register and approve the bundled system service before use\n");
        return 77;
    }
    umask(0077);
    signal(SIGPIPE, SIG_IGN);
    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);

    struct stat existing;
    if (lstat(g_socket_path, &existing) == 0 && !S_ISSOCK(existing.st_mode)) {
        fprintf(stderr, "refusing to replace a non-socket system entry\n");
        return 1;
    }
    unlink(g_socket_path);
    g_listen_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (g_listen_fd < 0) {
        perror("socket");
        return 1;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (strlen(g_socket_path) >= sizeof(addr.sun_path)) {
        fprintf(stderr, "socket path too long: %s\n", g_socket_path);
        close(g_listen_fd);
        return 1;
    }
    strncpy(addr.sun_path, g_socket_path, sizeof(addr.sun_path) - 1);

    if (bind(g_listen_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        perror("bind");
        close(g_listen_fd);
        return 1;
    }
    if (chmod(g_socket_path, socket_mode) != 0 || !refresh_socket_owner()) {
        perror("socket permissions");
        close(g_listen_fd);
        unlink(g_socket_path);
        return 1;
    }

    if (listen(g_listen_fd, 8) != 0) {
        perror("listen");
        close(g_listen_fd);
        unlink(g_socket_path);
        return 1;
    }

    fprintf(stdout, "READY %s\n", g_socket_path);
    fflush(stdout);

    while (!g_stop_requested) {
        if (!refresh_socket_owner()) {
            break;
        }
        struct pollfd waiter = {.fd = g_listen_fd, .events = POLLIN};
        int ready = poll(&waiter, 1, 1000);
        if (ready == 0 || (ready < 0 && errno == EINTR)) {
            continue;
        }
        if (ready < 0 || !(waiter.revents & POLLIN)) {
            break;
        }
        int client_fd = accept(g_listen_fd, NULL, NULL);
        if (client_fd < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        if (!client_authorized(client_fd)) {
            close(client_fd);
            continue;
        }
        bridge_handle_client(client_fd);
    }

    if (g_listen_fd >= 0) {
        close(g_listen_fd);
    }
    unlink(g_socket_path);
    return 0;
}
