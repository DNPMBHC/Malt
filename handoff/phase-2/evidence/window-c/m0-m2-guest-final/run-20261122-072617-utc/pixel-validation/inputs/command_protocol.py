"""Independent command-only wire codec and localhost test client.

This client exercises real receivers. Its optional CPU reference is an auxiliary
oracle; it is not a substitute for a D3D11 software reference frame.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import socket
import struct
from dataclasses import dataclass
from typing import Any

HEADER = struct.Struct("<4sHH6I")
DESCRIPTOR = struct.Struct("<8I")
METRICS = struct.Struct("<IIQQ")
MAX_BODY_BYTES = 64 * 1024 * 1024
VERSION = 2
MAGIC = b"GFX1"


class ProtocolError(ValueError):
    pass


def _uint32(value: int, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 0xFFFFFFFF:
        raise ProtocolError(f"{name} must be uint32")
    return value


@dataclass(frozen=True)
class PacketHeader:
    kind: int
    sequence: int
    width: int
    height: int
    command_bytes: int
    resource_bytes: int
    pixel_bytes: int = 0

    def encode(self) -> bytes:
        for name in ("sequence", "width", "height", "command_bytes", "resource_bytes", "pixel_bytes"):
            _uint32(getattr(self, name), name)
        if self.kind not in (1, 2, 3):
            raise ProtocolError("unsupported packet kind")
        if self.pixel_bytes != 0:
            raise ProtocolError("command-only packets cannot contain pixels")
        if self.command_bytes + self.resource_bytes > MAX_BODY_BYTES:
            raise ProtocolError("packet body exceeds limit")
        return HEADER.pack(MAGIC, VERSION, self.kind, self.sequence, self.width, self.height,
                           self.command_bytes, self.resource_bytes, self.pixel_bytes)

    @classmethod
    def decode(cls, data: bytes) -> PacketHeader:
        if len(data) != HEADER.size:
            raise ProtocolError("packet header must be 32 bytes")
        magic, version, kind, sequence, width, height, commands, resources, pixels = HEADER.unpack(data)
        if magic != MAGIC or version != VERSION:
            raise ProtocolError("invalid magic or command-only version")
        header = cls(kind, sequence, width, height, commands, resources, pixels)
        header.encode()
        return header


def command_batch(width: int, resource_bytes: int = 65536, count: int = 16) -> bytes:
    if isinstance(count, bool) or not isinstance(count, int) or not 1 <= count <= 4096:
        raise ProtocolError("draw count must be in 1...4096")
    _uint32(width, "width")
    _uint32(resource_bytes, "resource_bytes")
    if not width or resource_bytes < 4 or resource_bytes % 4:
        raise ProtocolError("image width and aligned resource size are required")
    offset = (count * DESCRIPTOR.size + 15) & ~15
    return DESCRIPTOR.pack(1, 3, 0, 0, offset, resource_bytes, width, 0) * count


def validate_commands(data: bytes, width: int, resource_bytes: int) -> None:
    if not data or len(data) % DESCRIPTOR.size:
        raise ProtocolError("command batch must contain complete 32-byte descriptors")
    expected_offset = (len(data) + 15) & ~15
    for offset in range(0, len(data), DESCRIPTOR.size):
        opcode, vertices, start, reserved, payload_offset, payload_bytes, image_width, pad = DESCRIPTOR.unpack_from(data, offset)
        if (opcode, vertices, start, reserved, pad) != (1, 3, 0, 0, 0):
            raise ProtocolError("unsupported draw descriptor")
        if payload_offset != expected_offset or payload_bytes != resource_bytes or image_width != width:
            raise ProtocolError("draw constants disagree with retained input layout")


def hello_packet(width: int, height: int, warmup: int = 60,
                 resource_bytes: int = 65536, count: int = 16) -> bytes:
    commands = command_batch(width, resource_bytes, count)
    if not 1 <= width <= 4096 or not 1 <= height <= 4096:
        raise ProtocolError("invalid image dimensions")
    return PacketHeader(1, warmup, width, height, len(commands), resource_bytes).encode()


def frame_packet(sequence: int, width: int, height: int,
                 commands: bytes = b"", resource: bytes = b"") -> bytes:
    return PacketHeader(2, sequence, width, height, len(commands), len(resource)).encode() + commands + resource


class CommandSession:
    """Validate packets from a captured wire stream and retained resource state."""

    def __init__(self, hello: bytes):
        self.hello = PacketHeader.decode(hello)
        h = self.hello
        if h.kind != 1 or not 1 <= h.width <= 4096 or not 1 <= h.height <= 4096:
            raise ProtocolError("invalid hello dimensions or kind")
        if not 1 <= h.command_bytes // DESCRIPTOR.size <= 4096 or h.command_bytes % DESCRIPTOR.size:
            raise ProtocolError("invalid hello command bytes")
        if not 4 <= h.resource_bytes <= 32 * 1024 * 1024 or h.resource_bytes % 4:
            raise ProtocolError("invalid hello resource bytes")
        self.expected_sequence = 0
        self.commands = b""
        self.resource = b""

    def consume(self, packet: bytes) -> PacketHeader:
        header = PacketHeader.decode(packet[:HEADER.size])
        h = self.hello
        if header.kind != 2 or header.sequence != self.expected_sequence:
            raise ProtocolError("frame sequence mismatch")
        if (header.width, header.height) != (h.width, h.height):
            raise ProtocolError("frame dimensions changed")
        if header.command_bytes not in (0, h.command_bytes) or header.resource_bytes not in (0, h.resource_bytes):
            raise ProtocolError("partial state update is unsupported")
        if len(packet) != HEADER.size + header.command_bytes + header.resource_bytes:
            raise ProtocolError("packet body length mismatch")
        if self.expected_sequence == 0 and (not header.command_bytes or not header.resource_bytes):
            raise ProtocolError("first frame must initialize all retained state")
        start = HEADER.size
        commands = packet[start:start + header.command_bytes] if header.command_bytes else self.commands
        start += header.command_bytes
        resource = packet[start:] if header.resource_bytes else self.resource
        validate_commands(commands, h.width, h.resource_bytes)
        if len(resource) != h.resource_bytes:
            raise ProtocolError("resource cache is incomplete")
        self.commands, self.resource = commands, resource
        self.expected_sequence += 1
        return header


def seeded_resource(seed: int, epoch: int = 0, byte_count: int = 65536) -> bytes:
    _uint32(seed, "seed")
    _uint32(epoch, "epoch")
    if isinstance(byte_count, bool) or not isinstance(byte_count, int) or byte_count < 4 or byte_count % 4:
        raise ProtocolError("resource size must be a positive multiple of four")
    state = (seed ^ ((epoch * 0x9E3779B9) & 0xFFFFFFFF)) or 1
    result = bytearray(byte_count)
    for index in range(byte_count):
        state ^= (state << 13) & 0xFFFFFFFF
        state ^= state >> 17
        state ^= (state << 5) & 0xFFFFFFFF
        state &= 0xFFFFFFFF
        result[index] = state & 255
    return bytes(result)


def recv_exact(connection: socket.socket, count: int) -> bytes:
    result = bytearray()
    while len(result) < count:
        chunk = connection.recv(count - len(result))
        if not chunk:
            raise ProtocolError("peer closed before packet completed")
        result.extend(chunk)
    return bytes(result)


def read_ack(connection: socket.socket, sequence: int) -> dict[str, Any]:
    header = PacketHeader.decode(recv_exact(connection, HEADER.size))
    if header.kind != 3 or header.sequence != sequence:
        raise ProtocolError("acknowledgement sequence mismatch")
    if any((header.width, header.height, header.command_bytes, header.resource_bytes, header.pixel_bytes)):
        raise ProtocolError("acknowledgement header contains unexpected payload fields")
    receive_us, gpu_us, resident, texture = METRICS.unpack(recv_exact(connection, METRICS.size))
    return {"sequence": sequence, "host_receive_ms": receive_us / 1000.0,
            "host_gpu_ms": gpu_us / 1000.0, "host_resident_bytes": resident,
            "host_texture_bytes": texture, "ack_bytes": HEADER.size + METRICS.size}


def run_client(host: str = "127.0.0.1", port: int = 39003, frames: int = 3,
               width: int = 1280, height: int = 720, seed: int = 7,
               command_every: int = 30, resource_every: int = 30) -> dict[str, Any]:
    if frames < 1 or command_every < 1 or resource_every < 1:
        raise ProtocolError("frame count and update intervals must be positive")
    commands = command_batch(width)
    hello = hello_packet(width, height, warmup=0)
    session = CommandSession(hello)
    records = []
    with socket.create_connection((host, port), timeout=30) as connection:
        connection.sendall(hello)
        for sequence in range(frames):
            updated_commands = commands if sequence % command_every == 0 else b""
            updated_resource = seeded_resource(seed, sequence // resource_every) if sequence % resource_every == 0 else b""
            packet = frame_packet(sequence, width, height, updated_commands, updated_resource)
            session.consume(packet)
            connection.sendall(packet)
            ack = read_ack(connection, sequence)
            records.append({**ack, "request_bytes": len(packet),
                            "command_bytes": len(updated_commands), "resource_bytes": len(updated_resource),
                            "resource_sha256": hashlib.sha256(session.resource).hexdigest()})
    return {"offload_mode": "command-only", "protocol_version": VERSION,
            "hello_bytes": len(hello), "frame_count": frames, "records": records}


def main() -> int:
    parser = argparse.ArgumentParser(description="Exercise a real command-only Metal receiver")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=39003)
    parser.add_argument("--frames", type=int, default=3)
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=720)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--command-every", type=int, default=30)
    parser.add_argument("--resource-every", type=int, default=30)
    args = parser.parse_args()
    try:
        result = run_client(**vars(args))
    except (ProtocolError, OSError):
        print(json.dumps({"passed": False, "error": "protocol client failed"}, sort_keys=True))
        return 2
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
