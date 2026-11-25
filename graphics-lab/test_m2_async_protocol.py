"""Unit tests for M2.5 asynchronous fence-pipelined protocol (GFX1 v3).

Owner: @DNPMBHC
"""

from __future__ import annotations

import pathlib
import sys
import unittest

LAB_DIR = pathlib.Path(__file__).resolve().parent
if str(LAB_DIR) not in sys.path:
    sys.path.insert(0, str(LAB_DIR))

import m2_async_protocol as proto  # noqa: E402


class M2AsyncProtocolTests(unittest.TestCase):
    def test_hello_and_frame_roundtrip(self) -> None:
        raw_hello = proto.make_hello(width=1280, height=720, warmup=60, max_in_flight=3)
        self.assertEqual(len(raw_hello), 32)
        hello = proto.AsyncHeader.decode(raw_hello)
        self.assertEqual(hello.kind, proto.KIND_HELLO)
        self.assertEqual(hello.sequence, 60)
        self.assertEqual(hello.width, 1280)
        self.assertEqual(hello.height, 720)
        self.assertEqual(hello.command_bytes, 512)
        self.assertEqual(hello.resource_bytes, 65536)
        self.assertEqual(hello.aux, 3)

        raw_frame = proto.make_frame(sequence=7, width=1280, height=720)
        self.assertEqual(len(raw_frame), 32)
        frame = proto.AsyncHeader.decode(raw_frame)
        self.assertEqual(frame.kind, proto.KIND_FRAME)
        self.assertEqual(frame.sequence, 7)
        self.assertEqual(frame.command_bytes, 0)
        self.assertEqual(frame.resource_bytes, 0)
        self.assertEqual(frame.aux, 0)

    def test_ack_roundtrip_and_56_byte_wire_parity(self) -> None:
        ack = proto.AsyncAck(
            sequence=12,
            fence_id=13,
            width=1280,
            height=720,
            gpu_ok=True,
            receive_us=120,
            gpu_us=881,
            resident_bytes=64 * 1024 * 1024,
            texture_bytes=1280 * 720 * 4,
        )
        encoded = ack.encode()
        self.assertEqual(len(encoded), 56)
        decoded = proto.AsyncAck.decode(encoded)
        self.assertEqual(decoded, ack)

    def test_rejects_invalid_in_flight_or_mismatched_fence(self) -> None:
        with self.assertRaises(proto.AsyncProtocolError):
            proto.make_hello(max_in_flight=0)
        with self.assertRaises(proto.AsyncProtocolError):
            proto.make_hello(max_in_flight=4)
        with self.assertRaises(proto.AsyncProtocolError):
            proto.AsyncAck(
                sequence=5,
                fence_id=7,
                width=1280,
                height=720,
                gpu_ok=True,
                receive_us=1,
                gpu_us=2,
                resident_bytes=0,
                texture_bytes=0,
            ).encode()

    def test_fence_window_tracker_fifo_and_drain(self) -> None:
        tracker = proto.FenceWindowTracker(max_in_flight=3)
        self.assertEqual(tracker.on_submit(0, 10.0), 1)
        self.assertEqual(tracker.on_submit(1, 11.0), 2)
        self.assertEqual(tracker.on_submit(2, 12.0), 3)
        self.assertFalse(tracker.can_submit())
        self.assertEqual(tracker.max_observed_depth, 3)

        with self.assertRaises(proto.AsyncProtocolError):
            tracker.on_submit(3, 13.0)

        out_of_order = proto.AsyncAck(1, 2, 1280, 720, True, 100, 800, 0, 0)
        with self.assertRaises(proto.AsyncProtocolError):
            tracker.on_ack(out_of_order, 15.0)

        for seq, ack_ms in ((0, 14.5), (1, 15.5), (2, 16.5)):
            rtt = tracker.on_ack(proto.AsyncAck(seq, seq + 1, 1280, 720, True, 50, 800, 0, 0), ack_ms)
            self.assertAlmostEqual(rtt, 4.5, places=6)

        tracker.assert_drained()
        self.assertEqual(tracker.completed_frames, 3)

    def test_fence_window_rejects_gpu_failure_ack(self) -> None:
        tracker = proto.FenceWindowTracker(max_in_flight=2)
        tracker.on_submit(0, 1.0)
        failed_ack = proto.AsyncAck(0, 1, 1280, 720, False, 10, 0, 0, 0)
        with self.assertRaises(proto.AsyncProtocolError):
            tracker.on_ack(failed_ack, 2.0)

    def test_summarize_samples(self) -> None:
        stats = proto.summarize_samples([10.0, 20.0, 30.0, 40.0, 50.0])
        self.assertEqual(stats["mean"], 30.0)
        self.assertEqual(stats["p50"], 30.0)
        self.assertEqual(stats["min"], 10.0)
        self.assertEqual(stats["max"], 50.0)

    def test_benchmark_aggregation_pooled_fps(self) -> None:
        import m2_async_benchmark as bench

        mode = bench.MODES[2]
        fake_runs = [
            {
                "measured_frames": 300,
                "elapsed_drain_ms": 600.0,
                "throughput_fps_drain_inclusive": 500.0,
                "max_observed_depth": 2,
                "ack_interval_ms": {"mean": 2.0, "p50": 1.8, "p95": 3.0, "p99": 4.0},
                "frame_rtt_ms": {"mean": 4.0, "p95": 6.0},
                "host_gpu_ms": {"mean": 0.7},
                "avg_wire_bytes_per_frame": 2289.6,
            },
            {
                "measured_frames": 300,
                "elapsed_drain_ms": 900.0,
                "throughput_fps_drain_inclusive": 333.3333,
                "max_observed_depth": 2,
                "ack_interval_ms": {"mean": 3.0, "p50": 2.5, "p95": 5.0, "p99": 7.0},
                "frame_rtt_ms": {"mean": 5.0, "p95": 8.0},
                "host_gpu_ms": {"mean": 0.9},
                "avg_wire_bytes_per_frame": 2289.6,
            },
        ]
        agg = bench.aggregate_mode_runs(mode, fake_runs)
        self.assertEqual(agg["total_measured_frames"], 600)
        self.assertAlmostEqual(agg["pooled_throughput_fps"], 400.0, places=3)
        self.assertEqual(agg["max_observed_depth"], 2)


if __name__ == "__main__":
    unittest.main()
