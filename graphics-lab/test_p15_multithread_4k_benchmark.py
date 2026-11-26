#!/usr/bin/env python3
"""Unit & loopback protocol tests for Phase 15A benchmark suite.

Owner: @DNPMBHC
"""
from __future__ import annotations

import os
from pathlib import Path
import socket
import struct
import time
import unittest

import p15_multithread_4k_benchmark as p15


def _checksum(data: bytes) -> int:
    if len(data) % 2 == 1:
        data += b"\x00"
    total = sum(struct.unpack(f"!{len(data)//2}H", data))
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return (~total) & 0xFFFF


def _l4_checksum(src_ip: bytes, dst_ip: bytes, proto: int, seg: bytes) -> int:
    pseudo = src_ip + dst_ip + struct.pack("!BBH", 0, proto, len(seg))
    return _checksum(pseudo + seg)


def _build_eth_ipv4(dst_mac: bytes, src_mac: bytes, proto: int, src_ip: bytes, dst_ip: bytes, l4: bytes) -> bytes:
    ip_hdr = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(l4), 1, 0x4000, 64, proto, 0, src_ip, dst_ip)
    cs = _checksum(ip_hdr)
    ip_hdr = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(l4), 1, 0x4000, 64, proto, cs, src_ip, dst_ip)
    return dst_mac + src_mac + b"\x08\x00" + ip_hdr + l4


def _build_tcp_frame(
    dst_mac: bytes,
    src_mac: bytes,
    src_ip: bytes,
    dst_ip: bytes,
    sport: int,
    dport: int,
    seq: int,
    ack: int,
    flags: int,
    payload: bytes = b"",
) -> bytes:
    hdr = struct.pack("!HHIIBBHHH", sport, dport, seq, ack, 0x50, flags, 65535, 0, 0)
    cs = _l4_checksum(src_ip, dst_ip, 6, hdr + payload)
    hdr = struct.pack("!HHIIBBHHH", sport, dport, seq, ack, 0x50, flags, 65535, cs, 0)
    return _build_eth_ipv4(dst_mac, src_mac, 6, src_ip, dst_ip, hdr + payload)


def _send_stream_frame(sock: socket.socket, frame: bytes) -> None:
    sock.sendall(struct.pack("!I", len(frame)) + frame)


def _recv_stream_frame(sock: socket.socket) -> bytes:
    hdr = b""
    while len(hdr) < 4:
        chunk = sock.recv(4 - len(hdr))
        if not chunk:
            raise EOFError("stream closed")
        hdr += chunk
    length = struct.unpack("!I", hdr)[0]
    body = b""
    while len(body) < length:
        chunk = sock.recv(length - len(body))
        if not chunk:
            raise EOFError("stream closed mid-frame")
        body += chunk
    return body


class Phase15BenchmarkUnitTests(unittest.TestCase):
    def test_audit_p15_device_tree_detects_clean_and_residual_bloat(self) -> None:
        clean_cmd = (
            "QEMULauncher -device nec-usb-xhci,id=usb-bus -device virtio-mouse-pci "
            "-device usb-kbd,bus=usb-bus.0 -device virtio-ramfb-gl,hostmem=8G,blob=true "
            "-device intel-hda -device virtio-blk-pci,drive=drive0 "
            "-netdev stream,id=net0,server=off,addr.type=inet,addr.host=127.0.0.1,addr.port=18443 "
            "-device virtio-net-pci,netdev=net0,ioeventfd=on,rx_queue_size=1024"
        )
        res = p15.audit_p15_device_tree(clean_cmd)
        self.assertTrue(res["deemulated_clean"])
        self.assertTrue(res["has_virtio_mouse"])
        self.assertFalse(res["has_usb_mouse"])
        self.assertEqual(res["usb_redir_device_count"], 0)
        self.assertEqual(res["extra_qemu_xhci_count"], 0)
        self.assertFalse(res["has_slirp_user_net"])

        bloated_cmd = (
            "QEMULauncher -device usb-tablet -device usb-mouse -device qemu-xhci,id=usb-controller-0 "
            "-chardev spicevmc,name=usbredir,id=u0 -device usb-redir,chardev=u0 "
            "-netdev user,id=net0 -device virtio-balloon-pci"
        )
        bad = p15.audit_p15_device_tree(bloated_cmd)
        self.assertFalse(bad["deemulated_clean"])
        self.assertEqual(bad["usb_redir_device_count"], 1)
        self.assertEqual(bad["extra_qemu_xhci_count"], 1)
        self.assertTrue(bad["has_slirp_user_net"])

    def test_compare_multithread_scaling_and_iosurface_and_network(self) -> None:
        s1 = {"api": "vulkan", "width": 3840, "height": 2160, "threads": 1, "record_cpu_ms_mean": 12.0, "total_frame_ms_mean": 16.0, "fps_mean": 62.5}
        s4 = {"api": "vulkan", "width": 3840, "height": 2160, "threads": 4, "record_cpu_ms_mean": 3.5, "total_frame_ms_mean": 7.5, "fps_mean": 133.33}
        s8 = {"api": "vulkan", "width": 3840, "height": 2160, "threads": 8, "record_cpu_ms_mean": 2.4, "total_frame_ms_mean": 6.4, "fps_mean": 156.25}
        sc = p15.compare_multithread_scaling(s1, [s4, s8])
        self.assertEqual(sc["resolution"], "3840x2160")
        self.assertEqual(sc["best_mt_arm"]["threads"], 8)
        self.assertAlmostEqual(sc["best_mt_arm"]["record_cpu_speedup_x"], 5.0, places=2)
        self.assertGreater(sc["best_mt_arm"]["fps_gain_pct"], 140.0)

        io_cmp = p15.compare_iosurface_present_arms(
            {"width": 3840, "height": 2160, "frame_metrics": {"fps_mean": 75.0, "fps_p1_low": 55.0, "frame_ms_p99": 18.0, "frame_ms_jitter_p99_p50": 4.2}},
            {"width": 3840, "height": 2160, "frame_metrics": {"fps_mean": 82.0, "fps_p1_low": 63.0, "frame_ms_p99": 15.0, "frame_ms_jitter_p99_p50": 2.8}},
        )
        self.assertAlmostEqual(io_cmp["eliminated_shadow_copy_mib_per_frame"], 31.641, places=2)
        self.assertGreater(io_cmp["estimated_saved_bandwidth_mib_per_sec"], 2500.0)

        net_cmp = p15.compare_mixed_network_arms(
            {"label": "slirp", "udp": {"loss_pct": 0.1, "burst_loss_ge3": 1, "p50_rtt_ms": 1.0, "p99_rtt_ms": 6.0, "loaded_p99_rtt_ms": 9.0}, "tcp": {"p50_rtt_ms": 2.0, "p99_rtt_ms": 10.0, "loaded_p99_rtt_ms": 15.0}},
            {"label": "full-stream", "udp": {"loss_pct": 0.0, "burst_loss_ge3": 0, "p50_rtt_ms": 0.7, "p99_rtt_ms": 3.5, "loaded_p99_rtt_ms": 4.5}, "tcp": {"connect_success_pct": 100.0, "ops_err": 0, "verify_errors": 0, "p50_rtt_ms": 1.1, "p99_rtt_ms": 4.0, "loaded_p99_rtt_ms": 5.5}},
        )
        self.assertTrue(net_cmp["udp_zero_loss"])
        self.assertTrue(net_cmp["tcp_zero_verify_errors"])
        self.assertLess(net_cmp["udp_loaded_p99_delta_pct"], 0.0)

    def test_full_tcp_udp_icmp_proxy_loopback_handshake_and_data_transfer(self) -> None:
        if not p15.GO_BIN.is_file():
            self.skipTest("go toolchain not installed")
        echo = p15.HostMixedEchoServer()
        echo.start()
        proxy_proc = None
        client = None
        try:
            proxy_proc, ep, qos_ok = p15.start_full_tcp_udp_proxy()
            self.assertTrue(qos_ok, "Expected pthread USER_INTERACTIVE QoS on macOS")
            host, port_s = ep.split(":")
            client = socket.create_connection((host, int(port_s)), timeout=5.0)
            client.settimeout(5.0)

            guest_mac = b"\x52\x54\x00\xaa\xbb\xcc"
            gw_mac = b"\x52\x54\x00\x15\x00\x01"
            guest_ip = bytes([10, 12, 0, 15])
            gw_ip = bytes([10, 12, 0, 1])

            # 1. ICMP Echo test
            icmp_req = struct.pack("!BBHHH", 8, 0, 0, 0x1234, 1) + b"PING15A"
            icmp_cs = _checksum(icmp_req)
            icmp_req = struct.pack("!BBHHH", 8, 0, icmp_cs, 0x1234, 1) + b"PING15A"
            _send_stream_frame(client, _build_eth_ipv4(gw_mac, guest_mac, 1, guest_ip, gw_ip, icmp_req))
            icmp_reply = _recv_stream_frame(client)
            self.assertEqual(icmp_reply[23], 1)
            self.assertEqual(icmp_reply[34], 0)  # Echo Reply
            self.assertIn(b"PING15A", icmp_reply)

            # 2. UDP Echo test via proxy to host echo server
            udp_payload = b"UDP-128TICK-P15A"
            udp_hdr = struct.pack("!HHHH", 40001, echo.udp_port, 8 + len(udp_payload), 0)
            udp_cs = _l4_checksum(guest_ip, gw_ip, 17, udp_hdr + udp_payload)
            udp_seg = struct.pack("!HHHH", 40001, echo.udp_port, 8 + len(udp_payload), udp_cs) + udp_payload
            _send_stream_frame(client, _build_eth_ipv4(gw_mac, guest_mac, 17, guest_ip, gw_ip, udp_seg))
            udp_reply = _recv_stream_frame(client)
            self.assertEqual(udp_reply[23], 17)
            self.assertIn(udp_payload, udp_reply)

            # 3. Full TCP 3-way handshake + payload echo + FIN teardown
            client_isn = 100000
            _send_stream_frame(
                client,
                _build_tcp_frame(gw_mac, guest_mac, guest_ip, gw_ip, 50001, echo.tcp_port, client_isn, 0, 0x02),
            )
            synack = _recv_stream_frame(client)
            self.assertEqual(synack[23], 6)
            srv_seq, srv_ack = struct.unpack("!II", synack[38:46])
            srv_flags = synack[47]
            self.assertEqual(srv_flags & 0x12, 0x12)  # SYN+ACK
            self.assertEqual(srv_ack, client_isn + 1)

            # Complete handshake (ACK)
            _send_stream_frame(
                client,
                _build_tcp_frame(gw_mac, guest_mac, guest_ip, gw_ip, 50001, echo.tcp_port, client_isn + 1, srv_seq + 1, 0x10),
            )
            # Send TCP payload and verify exact echo back through NAT
            tcp_msg = b"PHASE15A-FULL-TCP-PAYLOAD-" * 10
            _send_stream_frame(
                client,
                _build_tcp_frame(
                    gw_mac, guest_mac, guest_ip, gw_ip, 50001, echo.tcp_port,
                    client_isn + 1, srv_seq + 1, 0x18, tcp_msg,
                ),
            )
            received_data = b""
            deadline = time.monotonic() + 5.0
            while len(received_data) < len(tcp_msg) and time.monotonic() < deadline:
                f = _recv_stream_frame(client)
                if f[23] == 6:
                    ihl = (f[14] & 0x0F) * 4
                    tot_len = struct.unpack("!H", f[16:18])[0]
                    tcp_off = 14 + ihl
                    tcp_hdr_len = (f[tcp_off + 12] >> 4) * 4
                    data_part = f[tcp_off + tcp_hdr_len : 14 + tot_len]
                    if data_part:
                        received_data += data_part
            self.assertEqual(received_data, tcp_msg)
        finally:
            if client is not None:
                client.close()
            if proxy_proc is not None:
                proxy_proc.terminate()
                proxy_proc.wait(timeout=5)
                if proxy_proc.stdout:
                    proxy_proc.stdout.close()
                if proxy_proc.stderr:
                    proxy_proc.stderr.close()
            echo.stop()

    def test_windows_tools_compile_out_of_repo(self) -> None:
        if not p15.MINGW_GXX.is_file():
            self.skipTest("mingw-w64 cross compiler not installed")
        gfx_exe = p15.build_windows_tool("mt_gfx_bench", p15.MT_GFX_BENCH_CPP_SRC, ["-ld3d11", "-ldxgi", "-ld3dcompiler"])
        net_exe = p15.build_windows_tool("net_mixed_bench", p15.NET_MIXED_BENCH_CPP_SRC, ["-lws2_32"])
        self.assertTrue(gfx_exe.is_file())
        self.assertTrue(net_exe.is_file())
        # Ensure compiled binaries remain strictly outside repository and have zero non-system MinGW DLL deps
        repo = p15.WORKSPACE_ROOT.resolve()
        objdump = Path("/opt/homebrew/bin/x86_64-w64-mingw32-objdump")
        for bin_path in (gfx_exe, net_exe):
            with self.assertRaises(ValueError):
                bin_path.resolve().relative_to(repo)
            if objdump.is_file():
                import subprocess
                out = subprocess.check_output([str(objdump), "-p", str(bin_path)], text=True)
                self.assertNotIn("libwinpthread", out)
                self.assertNotIn("libstdc++", out)
                self.assertNotIn("libgcc_s", out)


if __name__ == "__main__":
    unittest.main()
