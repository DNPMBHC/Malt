#!/usr/bin/env python3
"""Native sender for protocol/Metal smoke tests; it is not a D3D workload."""

from __future__ import annotations

import argparse
import csv
import resource
import socket
import struct
import time
from pathlib import Path

HEADER = struct.Struct("<4sHHIIIIII")
ACK_METRICS = struct.Struct("<IIQQ")
CSV_FIELDS = (
    "transport_mode", "frame_index", "initialization_ms", "warmup_ms",
    "cpu_frame_ms", "cpu_submit_ms", "process_cpu_ms", "gpu_ms",
    "synthetic_input_to_present_return_ms", "transferred_bytes", "command_bytes",
    "resource_bytes", "resident_bytes", "device_memory_bytes", "power_w",
    "temperature_c", "network_bytes_out", "network_bytes_in",
    "host_receive_to_present_ms", "host_gpu_ms", "host_resident_bytes",
    "host_texture_bytes",
)


def receive_exact(sock: socket.socket, count: int) -> bytes:
    result = bytearray()
    while len(result) < count:
        chunk = sock.recv(count - len(result))
        if not chunk:
            raise ConnectionError("receiver closed before acknowledgement")
        result.extend(chunk)
    return bytes(result)


def packet(kind: int, sequence: int, width: int, height: int,
           command_bytes: int, resource_bytes: int, pixel_bytes: int) -> bytes:
    return HEADER.pack(b"GFX1", 1, kind, sequence, width, height,
                       command_bytes, resource_bytes, pixel_bytes)


def rss_bytes() -> int:
    # ru_maxrss is a peak on macOS and Linux; documented separately from live D3D RSS.
    value = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return int(value if value > 10**7 else value * 1024)


def run(args: argparse.Namespace) -> None:
    command = b"".join(struct.pack("<IIII", 1, i, 0, i * 17 + 3)
                       for i in range(args.commands))
    resource_data = bytes((i * 31 + 7) & 255 for i in range(args.resource_bytes))
    pixels = bytearray(args.width * args.height * 4)
    for y in range(args.height):
        for x in range(args.width):
            offset = (y * args.width + x) * 4
            value = ((x * 3 + y * 5) ^ (x >> 3) ^ (y >> 2)) & 255
            pixels[offset:offset + 4] = bytes((value, (value + 73) & 255,
                                                (255 - value), 255))

    started = time.perf_counter()
    sock = socket.create_connection((args.host, args.port), timeout=30)
    sock.settimeout(30)
    initialization_ms = (time.perf_counter() - started) * 1000
    pixels_bytes = len(pixels)
    sock.sendall(packet(1, args.warmup, args.width, args.height,
                        len(command), len(resource_data), pixels_bytes))
    rows: list[dict[str, object]] = []
    previous = time.perf_counter()
    warmup_started = previous
    warmup_ms = 0.0
    frame_count = args.warmup + args.frames
    for sequence in range(frame_count):
        frame_start = time.perf_counter()
        cpu_started = time.process_time()
        command_update = sequence % args.command_every == 0
        command_part = command if command_update else b""
        resource_update = sequence % args.resource_every == 0
        resource_part = resource_data if resource_update else b""
        data = packet(2, sequence, args.width, args.height,
                      len(command_part), len(resource_part), pixels_bytes) + command_part + resource_part + pixels
        sock.sendall(data)
        ack = receive_exact(sock, HEADER.size)
        decoded = HEADER.unpack(ack)
        if decoded[:3] != (b"GFX1", 1, 3) or decoded[3] != sequence:
            raise RuntimeError("invalid frame acknowledgement")
        receive_us, gpu_us, host_rss, texture_bytes = ACK_METRICS.unpack(receive_exact(sock, ACK_METRICS.size))
        ack_time = time.perf_counter()
        cpu_elapsed = (time.process_time() - cpu_started) * 1000
        if sequence + 1 == args.warmup:
            warmup_ms = (ack_time - warmup_started) * 1000
        if sequence >= args.warmup:
            index = sequence - args.warmup
            frame_interval = 0 if index == 0 else (frame_start - previous) * 1000
            out_bytes = len(data)
            in_bytes = HEADER.size + ACK_METRICS.size
            rows.append({
                "transport_mode": "offload_tcp", "frame_index": index,
                "initialization_ms": initialization_ms,
                "warmup_ms": warmup_ms,
                "cpu_frame_ms": frame_interval,
                "cpu_submit_ms": (ack_time - frame_start) * 1000,
                "process_cpu_ms": cpu_elapsed,
                "gpu_ms": "", "synthetic_input_to_present_return_ms": (ack_time - frame_start) * 1000,
                "transferred_bytes": out_bytes + in_bytes,
                "command_bytes": len(command_part), "resource_bytes": len(resource_part),
                "resident_bytes": rss_bytes(), "device_memory_bytes": "",
                "power_w": "", "temperature_c": "", "network_bytes_out": out_bytes,
                "network_bytes_in": in_bytes,
                "host_receive_to_present_ms": receive_us / 1000,
                "host_gpu_ms": gpu_us / 1000 if gpu_us else "",
                "host_resident_bytes": host_rss if host_rss else "",
                "host_texture_bytes": texture_bytes,
            })
        previous = frame_start
    sock.close()
    if args.csv:
        with Path(args.csv).open("w", newline="", encoding="utf-8") as stream:
            writer = csv.DictWriter(stream, fieldnames=CSV_FIELDS)
            writer.writeheader()
            for row in rows:
                writer.writerow(row)
    print(f"frames={args.frames} warmup={args.warmup} resolution={args.width}x{args.height}")
    print(f"connection_setup_ms={initialization_ms:.3f} emitted_csv={bool(args.csv)}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=39003)
    parser.add_argument("--frames", type=int, default=120)
    parser.add_argument("--warmup", type=int, default=20)
    parser.add_argument("--width", type=int, default=640)
    parser.add_argument("--height", type=int, default=360)
    parser.add_argument("--commands", type=int, default=16)
    parser.add_argument("--command-every", type=int, default=1,
                        help="resend the command batch on every Nth frame; frame zero always seeds the host cache")
    parser.add_argument("--resource-bytes", type=int, default=65536)
    parser.add_argument("--resource-every", type=int, default=1,
                        help="resend the resource on every Nth frame; frame zero always seeds the host cache")
    parser.add_argument("--csv", help="optional benchmark CSV output")
    args = parser.parse_args()
    if (min(args.frames, args.width, args.height, args.commands, args.resource_bytes,
            args.command_every, args.resource_every) <= 0
            or args.width > 4096 or args.height > 4096 or args.commands > 262144
            or args.resource_bytes > 32 * 1024 * 1024
            or args.width * args.height * 4 + args.commands * 16 + args.resource_bytes > 64 * 1024 * 1024):
        parser.error("workload exceeds positive size limits")
    try:
        run(args)
    except (OSError, ConnectionError, RuntimeError, struct.error) as exc:
        parser.exit(2, f"synthetic_client: {exc}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
