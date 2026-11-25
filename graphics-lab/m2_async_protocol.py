"""M2.5 asynchronous fence-pipelined command-only wire protocol (GFX1 v3).

Owner: @DNPMBHC
Scope: graphics-lab M2.5 async pipeline prototype (isolated from frozen M2 v2 files).
"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass
import math
import struct
from typing import Iterable

MAGIC = b"GFX1"
VERSION_V3 = 3
HEADER_STRUCT = struct.Struct("<4sHH6I")
METRICS_STRUCT = struct.Struct("<IIQQ")
DESCRIPTOR_STRUCT = struct.Struct("<8I")

KIND_HELLO = 1
KIND_FRAME = 2
KIND_ACK = 3

ACK_FLAG_GPU_OK = 1
MAX_IN_FLIGHT_LIMIT = 3
MAX_BODY_BYTES = 64 * 1024 * 1024


class AsyncProtocolError(ValueError):
    """Raised when an M2.5 GFX1 v3 packet or fence transition violates contract."""


def _require_uint32(value: int, name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 0xFFFFFFFF:
        raise AsyncProtocolError(f"{name} must be uint32")
    return value


@dataclass(frozen=True)
class AsyncHeader:
    kind: int
    sequence: int
    width: int
    height: int
    command_bytes: int
    resource_bytes: int
    aux: int = 0

    def encode(self) -> bytes:
        for field_name in ("sequence", "width", "height", "command_bytes", "resource_bytes", "aux"):
            _require_uint32(getattr(self, field_name), field_name)
        if self.kind not in (KIND_HELLO, KIND_FRAME, KIND_ACK):
            raise AsyncProtocolError("unsupported packet kind")
        if self.kind == KIND_HELLO:
            max_in_flight = self.aux
            if not 1 <= max_in_flight <= MAX_IN_FLIGHT_LIMIT:
                raise AsyncProtocolError("hello max_in_flight must be in 1..3")
            if not 1 <= self.width <= 4096 or not 1 <= self.height <= 4096:
                raise AsyncProtocolError("invalid hello dimensions")
            if self.command_bytes == 0 or self.command_bytes % DESCRIPTOR_STRUCT.size != 0:
                raise AsyncProtocolError("invalid hello command_bytes")
            if self.resource_bytes < 4 or self.resource_bytes % 4 != 0:
                raise AsyncProtocolError("invalid hello resource_bytes")
        elif self.kind == KIND_FRAME:
            if self.aux != 0:
                raise AsyncProtocolError("command-only v3 frame cannot carry pixel bytes")
            if self.command_bytes + self.resource_bytes > MAX_BODY_BYTES:
                raise AsyncProtocolError("frame body exceeds limit")
        elif self.kind == KIND_ACK:
            if self.aux != METRICS_STRUCT.size:
                raise AsyncProtocolError("ack payload size must be 24 bytes")
        return HEADER_STRUCT.pack(
            MAGIC,
            VERSION_V3,
            self.kind,
            self.sequence,
            self.width,
            self.height,
            self.command_bytes,
            self.resource_bytes,
            self.aux,
        )

    @classmethod
    def decode(cls, raw: bytes) -> AsyncHeader:
        if len(raw) != HEADER_STRUCT.size:
            raise AsyncProtocolError("header must be 32 bytes")
        magic, version, kind, seq, width, height, cmd_bytes, res_bytes, aux = HEADER_STRUCT.unpack(raw)
        if magic != MAGIC or version != VERSION_V3:
            raise AsyncProtocolError("invalid magic or GFX1 v3 version")
        header = cls(kind, seq, width, height, cmd_bytes, res_bytes, aux)
        header.encode()
        return header


@dataclass(frozen=True)
class AsyncAck:
    sequence: int
    fence_id: int
    width: int
    height: int
    gpu_ok: bool
    receive_us: int
    gpu_us: int
    resident_bytes: int
    texture_bytes: int

    def encode(self) -> bytes:
        _require_uint32(self.sequence, "sequence")
        _require_uint32(self.fence_id, "fence_id")
        if self.fence_id != self.sequence + 1:
            raise AsyncProtocolError("fence_id must equal sequence + 1")
        flags = ACK_FLAG_GPU_OK if self.gpu_ok else 0
        header = AsyncHeader(
            kind=KIND_ACK,
            sequence=self.sequence,
            width=self.width,
            height=self.height,
            command_bytes=self.fence_id,
            resource_bytes=flags,
            aux=METRICS_STRUCT.size,
        ).encode()
        metrics = METRICS_STRUCT.pack(
            _require_uint32(self.receive_us, "receive_us"),
            _require_uint32(self.gpu_us, "gpu_us"),
            self.resident_bytes,
            self.texture_bytes,
        )
        return header + metrics

    @classmethod
    def decode(cls, raw: bytes) -> AsyncAck:
        expected_size = HEADER_STRUCT.size + METRICS_STRUCT.size
        if len(raw) != expected_size:
            raise AsyncProtocolError("ack packet must be 56 bytes")
        header = AsyncHeader.decode(raw[: HEADER_STRUCT.size])
        if header.kind != KIND_ACK:
            raise AsyncProtocolError("expected ACK packet kind")
        fence_id = header.command_bytes
        if fence_id != header.sequence + 1:
            raise AsyncProtocolError("ack fence_id mismatch")
        receive_us, gpu_us, resident_bytes, texture_bytes = METRICS_STRUCT.unpack(raw[HEADER_STRUCT.size :])
        return cls(
            sequence=header.sequence,
            fence_id=fence_id,
            width=header.width,
            height=header.height,
            gpu_ok=bool(header.resource_bytes & ACK_FLAG_GPU_OK),
            receive_us=receive_us,
            gpu_us=gpu_us,
            resident_bytes=resident_bytes,
            texture_bytes=texture_bytes,
        )


def make_hello(
    width: int = 1280,
    height: int = 720,
    warmup: int = 60,
    command_bytes: int = 512,
    resource_bytes: int = 65536,
    max_in_flight: int = 2,
) -> bytes:
    return AsyncHeader(
        kind=KIND_HELLO,
        sequence=warmup,
        width=width,
        height=height,
        command_bytes=command_bytes,
        resource_bytes=resource_bytes,
        aux=max_in_flight,
    ).encode()


def make_frame(
    sequence: int,
    width: int,
    height: int,
    commands: bytes = b"",
    resource: bytes = b"",
) -> bytes:
    return (
        AsyncHeader(
            kind=KIND_FRAME,
            sequence=sequence,
            width=width,
            height=height,
            command_bytes=len(commands),
            resource_bytes=len(resource),
            aux=0,
        ).encode()
        + commands
        + resource
    )


class FenceWindowTracker:
    """Tracks bounded in-flight frame fences with strict FIFO ordering."""

    def __init__(self, max_in_flight: int):
        if isinstance(max_in_flight, bool) or not isinstance(max_in_flight, int):
            raise AsyncProtocolError("max_in_flight must be an integer")
        if not 1 <= max_in_flight <= MAX_IN_FLIGHT_LIMIT:
            raise AsyncProtocolError("max_in_flight must be in 1..3")
        self.max_in_flight = max_in_flight
        self._next_sequence = 0
        self._pending: deque[tuple[int, int, float]] = deque()
        self.max_observed_depth = 0
        self.completed_frames = 0

    @property
    def in_flight(self) -> int:
        return len(self._pending)

    def can_submit(self) -> bool:
        return len(self._pending) < self.max_in_flight

    def on_submit(self, sequence: int, submit_time_ms: float) -> int:
        if not self.can_submit():
            raise AsyncProtocolError("in-flight window exhausted")
        if sequence != self._next_sequence:
            raise AsyncProtocolError("non-monotonic frame sequence")
        fence_id = sequence + 1
        self._pending.append((sequence, fence_id, submit_time_ms))
        self._next_sequence += 1
        if len(self._pending) > self.max_observed_depth:
            self.max_observed_depth = len(self._pending)
        return fence_id

    def on_ack(self, ack: AsyncAck, ack_time_ms: float) -> float:
        if not self._pending:
            raise AsyncProtocolError("unexpected ACK with empty in-flight queue")
        if not ack.gpu_ok:
            raise AsyncProtocolError("host GPU completion failed")
        expected_seq, expected_fence, submit_ms = self._pending[0]
        if ack.sequence != expected_seq or ack.fence_id != expected_fence:
            raise AsyncProtocolError("out-of-order ACK fence")
        self._pending.popleft()
        self.completed_frames += 1
        return max(0.0, ack_time_ms - submit_ms)

    def assert_drained(self) -> None:
        if self._pending:
            raise AsyncProtocolError(f"{len(self._pending)} frame fences remain undrained")


def percentile(values: Iterable[float], pct: float) -> float:
    ordered = sorted(float(v) for v in values)
    if not ordered:
        return 0.0
    if pct <= 0:
        return ordered[0]
    if pct >= 100:
        return ordered[-1]
    rank = (len(ordered) - 1) * (pct / 100.0)
    low = math.floor(rank)
    high = math.ceil(rank)
    if low == high:
        return ordered[low]
    weight = rank - low
    return ordered[low] * (1.0 - weight) + ordered[high] * weight


def summarize_samples(values: Iterable[float]) -> dict[str, float]:
    ordered = [float(v) for v in values]
    if not ordered:
        return {"mean": 0.0, "p50": 0.0, "p95": 0.0, "p99": 0.0, "min": 0.0, "max": 0.0}
    return {
        "mean": round(sum(ordered) / len(ordered), 6),
        "p50": round(percentile(ordered, 50.0), 6),
        "p95": round(percentile(ordered, 95.0), 6),
        "p99": round(percentile(ordered, 99.0), 6),
        "min": round(min(ordered), 6),
        "max": round(max(ordered), 6),
    }
