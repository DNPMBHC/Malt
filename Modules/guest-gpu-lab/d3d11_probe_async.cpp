// M2.5 asynchronous fence-pipelined command-only client (GFX1 v3).
// Owner: @DNPMBHC
// Standalone prototype in Whisky/Modules/guest-gpu-lab; never modifies frozen M2 d3d11_probe.cpp.

#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

constexpr uint16_t kVersionV3 = 3;
constexpr uint16_t kKindHello = 1;
constexpr uint16_t kKindFrame = 2;
constexpr uint16_t kKindAck = 3;
constexpr uint32_t kAckFlagGpuOk = 1;
constexpr uint32_t kHeaderSize = 32;
constexpr uint32_t kAckMetricsSize = 24;
constexpr uint32_t kAckPacketSize = kHeaderSize + kAckMetricsSize;
constexpr uint32_t kDrawCount = 16;
constexpr uint32_t kCommandBytes = kDrawCount * 32;

struct Options {
    std::string host = "127.0.0.1";
    uint16_t port = 39013;
    uint32_t width = 1280;
    uint32_t height = 720;
    uint32_t warmup = 60;
    uint32_t frames = 300;
    uint32_t commandEvery = 30;
    uint32_t resourceEvery = 30;
    uint32_t resourceBytes = 65536;
    uint32_t resourceSeed = 0;
    uint32_t maxInFlight = 2;
    bool tcpNoDelay = true;
    bool splitSend = false;
    std::string outputCsv = "m25_async_frames.csv";
    std::string summaryJson = "";
};

struct InFlightFrame {
    uint32_t sequence = 0;
    uint32_t fenceId = 0;
    double submitMs = 0.0;
    double submitIntervalMs = 0.0;
    uint32_t bytesSent = 0;
    uint32_t depthAfterSubmit = 0;
};

struct FrameRecord {
    uint32_t sequence = 0;
    uint32_t fenceId = 0;
    bool isWarmup = false;
    double submitMs = 0.0;
    double ackMs = 0.0;
    double submitIntervalMs = 0.0;
    double ackIntervalMs = 0.0;
    double frameRttMs = 0.0;
    double hostReceiveMs = 0.0;
    double hostGpuMs = 0.0;
    uint32_t bytesSent = 0;
    uint32_t inFlightDepth = 0;
    uint64_t hostResidentBytes = 0;
    uint64_t hostTextureBytes = 0;
};

double nowMs() {
    static LARGE_INTEGER freq = [] {
        LARGE_INTEGER f{};
        QueryPerformanceFrequency(&f);
        return f;
    }();
    LARGE_INTEGER counter{};
    QueryPerformanceCounter(&counter);
    return static_cast<double>(counter.QuadPart) * 1000.0 / static_cast<double>(freq.QuadPart);
}

void writeU16(uint8_t* dst, uint16_t v) {
    dst[0] = static_cast<uint8_t>(v & 0xFFu);
    dst[1] = static_cast<uint8_t>((v >> 8) & 0xFFu);
}

void writeU32(uint8_t* dst, uint32_t v) {
    dst[0] = static_cast<uint8_t>(v & 0xFFu);
    dst[1] = static_cast<uint8_t>((v >> 8) & 0xFFu);
    dst[2] = static_cast<uint8_t>((v >> 16) & 0xFFu);
    dst[3] = static_cast<uint8_t>((v >> 24) & 0xFFu);
}

uint16_t readU16(const uint8_t* src) {
    return static_cast<uint16_t>(src[0]) | (static_cast<uint16_t>(src[1]) << 8);
}

uint32_t readU32(const uint8_t* src) {
    return static_cast<uint32_t>(src[0]) |
           (static_cast<uint32_t>(src[1]) << 8) |
           (static_cast<uint32_t>(src[2]) << 16) |
           (static_cast<uint32_t>(src[3]) << 24);
}

uint64_t readU64(const uint8_t* src) {
    return static_cast<uint64_t>(readU32(src)) | (static_cast<uint64_t>(readU32(src + 4)) << 32);
}

void encodeHeader(uint8_t* dst, uint16_t kind, uint32_t seq, uint32_t w, uint32_t h,
                  uint32_t cmdBytes, uint32_t resBytes, uint32_t aux) {
    std::memcpy(dst, "GFX1", 4);
    writeU16(dst + 4, kVersionV3);
    writeU16(dst + 6, kind);
    writeU32(dst + 8, seq);
    writeU32(dst + 12, w);
    writeU32(dst + 16, h);
    writeU32(dst + 20, cmdBytes);
    writeU32(dst + 24, resBytes);
    writeU32(dst + 28, aux);
}

std::vector<uint8_t> buildCommandBatch(uint32_t width, uint32_t resourceBytes) {
    std::vector<uint8_t> buf(kCommandBytes, 0);
    for (uint32_t i = 0; i < kDrawCount; ++i) {
        uint8_t* p = buf.data() + i * 32;
        writeU32(p + 0, 1u);
        writeU32(p + 4, 3u);
        writeU32(p + 8, 0u);
        writeU32(p + 12, 0u);
        writeU32(p + 16, kCommandBytes);
        writeU32(p + 20, resourceBytes);
        writeU32(p + 24, width);
        writeU32(p + 28, 0u);
    }
    return buf;
}

std::vector<uint8_t> buildResourcePayload(uint32_t seed, uint32_t epoch, uint32_t byteCount) {
    std::vector<uint8_t> buf(byteCount, 0);
    if (seed == 0) {
        // Legacy pattern identical to frozen graphics-lab/d3d11_probe.cpp
        for (uint32_t i = 0; i < byteCount; ++i) {
            buf[i] = static_cast<uint8_t>((i * 31u + 7u) & 0xFFu);
        }
        return buf;
    }
    uint32_t state = seed ^ (epoch * 0x9E3779B9u);
    if (state == 0) state = 1u;
    for (uint32_t i = 0; i < byteCount; ++i) {
        state ^= (state << 13);
        state ^= (state >> 17);
        state ^= (state << 5);
        buf[i] = static_cast<uint8_t>(state & 0xFFu);
    }
    return buf;
}

void sendAll(SOCKET sock, const uint8_t* data, size_t size) {
    size_t offset = 0;
    while (offset < size) {
        int sent = send(sock, reinterpret_cast<const char*>(data + offset),
                        static_cast<int>(size - offset), 0);
        if (sent == SOCKET_ERROR || sent == 0) {
            throw std::runtime_error("socket send failed");
        }
        offset += static_cast<size_t>(sent);
    }
}

void recvAll(SOCKET sock, uint8_t* data, size_t size) {
    size_t offset = 0;
    while (offset < size) {
        int got = recv(sock, reinterpret_cast<char*>(data + offset),
                       static_cast<int>(size - offset), 0);
        if (got == SOCKET_ERROR || got == 0) {
            throw std::runtime_error("socket recv failed");
        }
        offset += static_cast<size_t>(got);
    }
}

double percentileOf(std::vector<double> vals, double pct) {
    if (vals.empty()) return 0.0;
    std::sort(vals.begin(), vals.end());
    if (pct <= 0.0) return vals.front();
    if (pct >= 100.0) return vals.back();
    double rank = static_cast<double>(vals.size() - 1) * (pct / 100.0);
    size_t lo = static_cast<size_t>(std::floor(rank));
    size_t hi = static_cast<size_t>(std::ceil(rank));
    if (lo == hi) return vals[lo];
    double w = rank - static_cast<double>(lo);
    return vals[lo] * (1.0 - w) + vals[hi] * w;
}

double meanOf(const std::vector<double>& vals) {
    if (vals.empty()) return 0.0;
    double sum = 0.0;
    for (double v : vals) sum += v;
    return sum / static_cast<double>(vals.size());
}

Options parseArgs(int argc, char** argv) {
    Options o;
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        auto next = [&]() -> std::string {
            if (i + 1 >= argc) throw std::runtime_error("missing value for " + arg);
            return argv[++i];
        };
        if (arg == "--transport-host") o.host = next();
        else if (arg == "--transport-port") o.port = static_cast<uint16_t>(std::stoul(next()));
        else if (arg == "--width") o.width = static_cast<uint32_t>(std::stoul(next()));
        else if (arg == "--height") o.height = static_cast<uint32_t>(std::stoul(next()));
        else if (arg == "--warmup") o.warmup = static_cast<uint32_t>(std::stoul(next()));
        else if (arg == "--frames") o.frames = static_cast<uint32_t>(std::stoul(next()));
        else if (arg == "--command-every") o.commandEvery = static_cast<uint32_t>(std::stoul(next()));
        else if (arg == "--resource-every") o.resourceEvery = static_cast<uint32_t>(std::stoul(next()));
        else if (arg == "--resource-bytes") o.resourceBytes = static_cast<uint32_t>(std::stoul(next()));
        else if (arg == "--resource-seed") o.resourceSeed = static_cast<uint32_t>(std::stoul(next()));
        else if (arg == "--max-in-flight") o.maxInFlight = static_cast<uint32_t>(std::stoul(next()));
        else if (arg == "--tcp-nodelay") o.tcpNoDelay = (std::stoul(next()) != 0);
        else if (arg == "--split-send") o.splitSend = (std::stoul(next()) != 0);
        else if (arg == "--output") o.outputCsv = next();
        else if (arg == "--summary-json") o.summaryJson = next();
        else throw std::runtime_error("unknown option: " + arg);
    }
    if (o.maxInFlight < 1 || o.maxInFlight > 3) {
        throw std::runtime_error("--max-in-flight must be in 1..3");
    }
    return o;
}

}  // namespace

int main(int argc, char** argv) {
    try {
        Options o = parseArgs(argc, argv);
        WSADATA wsa{};
        if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
            throw std::runtime_error("WSAStartup failed");
        }
        SOCKET sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (sock == INVALID_SOCKET) {
            WSACleanup();
            throw std::runtime_error("socket creation failed");
        }
        int nodelay = o.tcpNoDelay ? 1 : 0;
        setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&nodelay), sizeof(nodelay));

        DWORD timeoutMs = 30000;
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&timeoutMs), sizeof(timeoutMs));
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char*>(&timeoutMs), sizeof(timeoutMs));

        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(o.port);
        if (InetPtonA(AF_INET, o.host.c_str(), &addr.sin_addr) != 1) {
            closesocket(sock);
            WSACleanup();
            throw std::runtime_error("invalid IPv4 host");
        }
        if (connect(sock, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == SOCKET_ERROR) {
            closesocket(sock);
            WSACleanup();
            throw std::runtime_error("connect failed");
        }

        std::array<uint8_t, kHeaderSize> hello{};
        encodeHeader(hello.data(), kKindHello, o.warmup, o.width, o.height,
                     kCommandBytes, o.resourceBytes, o.maxInFlight);
        sendAll(sock, hello.data(), hello.size());

        const auto commands = buildCommandBatch(o.width, o.resourceBytes);
        const uint32_t totalFrames = o.warmup + o.frames;

        std::deque<InFlightFrame> inflight;
        std::vector<FrameRecord> records;
        records.reserve(totalFrames);

        double prevSubmitMs = 0.0;
        double prevAckMs = 0.0;
        std::vector<uint8_t> packetBuf;
        packetBuf.reserve(kHeaderSize + kCommandBytes + o.resourceBytes);

        auto consumeOneAck = [&]() {
            if (inflight.empty()) throw std::runtime_error("consumeOneAck with empty queue");
            std::array<uint8_t, kAckPacketSize> rawAck{};
            recvAll(sock, rawAck.data(), rawAck.size());
            double ackNow = nowMs();

            if (std::memcmp(rawAck.data(), "GFX1", 4) != 0) throw std::runtime_error("bad ACK magic");
            if (readU16(rawAck.data() + 4) != kVersionV3) throw std::runtime_error("bad ACK version");
            if (readU16(rawAck.data() + 6) != kKindAck) throw std::runtime_error("bad ACK kind");
            uint32_t ackSeq = readU32(rawAck.data() + 8);
            uint32_t ackFence = readU32(rawAck.data() + 20);
            uint32_t ackFlags = readU32(rawAck.data() + 24);
            uint32_t ackPayloadLen = readU32(rawAck.data() + 28);
            if ((ackFlags & kAckFlagGpuOk) == 0 || ackPayloadLen != kAckMetricsSize) {
                throw std::runtime_error("host GPU failed or invalid ACK");
            }

            InFlightFrame front = inflight.front();
            inflight.pop_front();
            if (ackSeq != front.sequence || ackFence != front.fenceId) {
                throw std::runtime_error("out-of-order ACK fence");
            }

            uint32_t recvUs = readU32(rawAck.data() + 32);
            uint32_t gpuUs = readU32(rawAck.data() + 36);
            uint64_t resident = readU64(rawAck.data() + 40);
            uint64_t texBytes = readU64(rawAck.data() + 48);

            FrameRecord rec{};
            rec.sequence = front.sequence;
            rec.fenceId = front.fenceId;
            rec.isWarmup = (front.sequence < o.warmup);
            rec.submitMs = front.submitMs;
            rec.ackMs = ackNow;
            rec.submitIntervalMs = front.submitIntervalMs;
            rec.ackIntervalMs = (prevAckMs > 0.0) ? (ackNow - prevAckMs) : 0.0;
            rec.frameRttMs = std::max(0.0, ackNow - front.submitMs);
            rec.hostReceiveMs = static_cast<double>(recvUs) / 1000.0;
            rec.hostGpuMs = static_cast<double>(gpuUs) / 1000.0;
            rec.bytesSent = front.bytesSent;
            rec.inFlightDepth = front.depthAfterSubmit;
            rec.hostResidentBytes = resident;
            rec.hostTextureBytes = texBytes;
            prevAckMs = ackNow;
            records.push_back(rec);
        };

        for (uint32_t seq = 0; seq < totalFrames; ++seq) {
            while (inflight.size() >= o.maxInFlight) {
                consumeOneAck();
            }
            bool sendCmd = (seq == 0) || (o.commandEvery > 0 && (seq % o.commandEvery == 0));
            bool sendRes = (seq == 0) || (o.resourceEvery > 0 && (seq % o.resourceEvery == 0));
            uint32_t cmdLen = sendCmd ? kCommandBytes : 0u;
            uint32_t resLen = sendRes ? o.resourceBytes : 0u;

            std::vector<uint8_t> resBuf;
            if (sendRes) {
                uint32_t epoch = (o.resourceEvery > 0) ? (seq / o.resourceEvery) : 0u;
                resBuf = buildResourcePayload(o.resourceSeed, epoch, o.resourceBytes);
            }

            double submitNow = nowMs();
            double subInterval = (prevSubmitMs > 0.0) ? (submitNow - prevSubmitMs) : 0.0;
            prevSubmitMs = submitNow;

            if (o.splitSend && (cmdLen > 0 || resLen > 0)) {
                std::array<uint8_t, kHeaderSize> hdr{};
                encodeHeader(hdr.data(), kKindFrame, seq, o.width, o.height, cmdLen, resLen, 0);
                sendAll(sock, hdr.data(), hdr.size());
                if (cmdLen > 0) sendAll(sock, commands.data(), cmdLen);
                if (resLen > 0) sendAll(sock, resBuf.data(), resLen);
            } else {
                packetBuf.resize(kHeaderSize + cmdLen + resLen);
                encodeHeader(packetBuf.data(), kKindFrame, seq, o.width, o.height, cmdLen, resLen, 0);
                size_t pos = kHeaderSize;
                if (cmdLen > 0) {
                    std::memcpy(packetBuf.data() + pos, commands.data(), cmdLen);
                    pos += cmdLen;
                }
                if (resLen > 0) {
                    std::memcpy(packetBuf.data() + pos, resBuf.data(), resLen);
                }
                sendAll(sock, packetBuf.data(), packetBuf.size());
            }

            InFlightFrame entry{};
            entry.sequence = seq;
            entry.fenceId = seq + 1;
            entry.submitMs = submitNow;
            entry.submitIntervalMs = subInterval;
            entry.bytesSent = kHeaderSize + cmdLen + resLen;
            entry.depthAfterSubmit = static_cast<uint32_t>(inflight.size() + 1);
            inflight.push_back(entry);

            // Synchronous mode drains immediately after submit (1-frame ping-pong).
            if (o.maxInFlight == 1) {
                consumeOneAck();
            }
        }

        while (!inflight.empty()) {
            consumeOneAck();
        }
        shutdown(sock, SD_SEND);
        closesocket(sock);
        WSACleanup();

        // Write per-frame CSV
        std::ofstream csv(o.outputCsv, std::ios::binary);
        csv << "sequence,fence_id,is_warmup,submit_interval_ms,ack_interval_ms,frame_rtt_ms,"
               "host_receive_ms,host_gpu_ms,bytes_sent,in_flight_depth,host_resident_bytes,host_texture_bytes\n";
        for (const auto& r : records) {
            csv << r.sequence << ',' << r.fenceId << ',' << (r.isWarmup ? 1 : 0) << ','
                << std::fixed << std::setprecision(6)
                << r.submitIntervalMs << ',' << r.ackIntervalMs << ',' << r.frameRttMs << ','
                << r.hostReceiveMs << ',' << r.hostGpuMs << ','
                << r.bytesSent << ',' << r.inFlightDepth << ','
                << r.hostResidentBytes << ',' << r.hostTextureBytes << '\n';
        }
        csv.close();

        // Compute measured-window summary (strictly excluding warmup; drain-inclusive throughput)
        std::vector<double> submitIntervals, ackIntervals, rtts, hostGpus, hostRecvs;
        uint64_t totalWireBytes = 0;
        uint32_t maxDepth = 0;
        double firstMeasuredSubmit = 0.0;
        double lastMeasuredAck = 0.0;
        bool hasMeasured = false;
        for (const auto& r : records) {
            if (r.isWarmup) continue;
            if (!hasMeasured) {
                firstMeasuredSubmit = r.submitMs;
                hasMeasured = true;
            }
            lastMeasuredAck = r.ackMs;
            submitIntervals.push_back(r.submitIntervalMs);
            ackIntervals.push_back(r.ackIntervalMs);
            rtts.push_back(r.frameRttMs);
            hostGpus.push_back(r.hostGpuMs);
            hostRecvs.push_back(r.hostReceiveMs);
            totalWireBytes += static_cast<uint64_t>(r.bytesSent) + kAckPacketSize;
            if (r.inFlightDepth > maxDepth) maxDepth = r.inFlightDepth;
        }
        double elapsedMs = hasMeasured ? std::max(0.001, lastMeasuredAck - firstMeasuredSubmit) : 0.001;
        double throughputFps = static_cast<double>(o.frames) * 1000.0 / elapsedMs;
        double avgWireBytesPerFrame = static_cast<double>(totalWireBytes) / std::max<uint32_t>(1u, o.frames);

        std::ostringstream js;
        js << std::fixed << std::setprecision(6)
           << "{\n"
           << "  \"protocol_version\": 3,\n"
           << "  \"width\": " << o.width << ",\n"
           << "  \"height\": " << o.height << ",\n"
           << "  \"warmup_frames\": " << o.warmup << ",\n"
           << "  \"measured_frames\": " << o.frames << ",\n"
           << "  \"tcp_nodelay\": " << (o.tcpNoDelay ? "true" : "false") << ",\n"
           << "  \"max_in_flight\": " << o.maxInFlight << ",\n"
           << "  \"max_observed_depth\": " << maxDepth << ",\n"
           << "  \"split_send\": " << (o.splitSend ? "true" : "false") << ",\n"
           << "  \"elapsed_drain_ms\": " << elapsedMs << ",\n"
           << "  \"throughput_fps_drain_inclusive\": " << throughputFps << ",\n"
           << "  \"avg_wire_bytes_per_frame\": " << avgWireBytesPerFrame << ",\n"
           << "  \"ack_interval_ms\": {\"mean\": " << meanOf(ackIntervals)
           << ", \"p50\": " << percentileOf(ackIntervals, 50.0)
           << ", \"p95\": " << percentileOf(ackIntervals, 95.0)
           << ", \"p99\": " << percentileOf(ackIntervals, 99.0) << "},\n"
           << "  \"submit_interval_ms\": {\"mean\": " << meanOf(submitIntervals)
           << ", \"p50\": " << percentileOf(submitIntervals, 50.0)
           << ", \"p95\": " << percentileOf(submitIntervals, 95.0)
           << ", \"p99\": " << percentileOf(submitIntervals, 99.0) << "},\n"
           << "  \"frame_rtt_ms\": {\"mean\": " << meanOf(rtts)
           << ", \"p50\": " << percentileOf(rtts, 50.0)
           << ", \"p95\": " << percentileOf(rtts, 95.0)
           << ", \"p99\": " << percentileOf(rtts, 99.0) << "},\n"
           << "  \"host_gpu_ms\": {\"mean\": " << meanOf(hostGpus)
           << ", \"p50\": " << percentileOf(hostGpus, 50.0)
           << ", \"p95\": " << percentileOf(hostGpus, 95.0)
           << ", \"p99\": " << percentileOf(hostGpus, 99.0) << "},\n"
           << "  \"host_receive_ms\": {\"mean\": " << meanOf(hostRecvs) << "}\n"
           << "}\n";

        if (!o.summaryJson.empty()) {
            std::ofstream out(o.summaryJson, std::ios::binary);
            out << js.str();
        }
        std::cout << js.str();
        return 0;
    } catch (const std::exception& ex) {
        std::cerr << "d3d11_probe_async error: " << ex.what() << "\n";
        return 1;
    }
}
