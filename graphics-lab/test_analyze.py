import io
import unittest

import analyze


def csv_text(rows: list[list[str]]) -> str:
    return ",".join(analyze.FIELDS) + "\n" + "\n".join(",".join(row) for row in rows) + "\n"


def row(index: int, frame_ms: str, latency_ms: str, *, gpu_ms: str = "1.0",
        device_bytes: str = "4096", power_w: str = "", temp_c: str = "",
        mode: str = "offload_tcp", network_out: str = "120", network_in: str = "32",
        host_ms: str = "5.0", host_gpu_ms: str = "1.2", host_rss: str = "16384",
        host_texture: str = "921600") -> list[str]:
    return [mode, str(index), "12.5", "30", frame_ms, "2.0", "0.2", gpu_ms,
            latency_ms, "100", "32", "64", "8192", device_bytes, power_w, temp_c,
            network_out, network_in, host_ms, host_gpu_ms, host_rss, host_texture]


class AnalyzeTests(unittest.TestCase):
    def test_summarizes_frames_percentiles_bytes_and_missing_telemetry(self) -> None:
        rows = analyze.load_rows(io.StringIO(csv_text([
            row(0, "0", "4.0", power_w="8.0", temp_c="41.0"),
            row(1, "10", "6.0", gpu_ms="", device_bytes="", power_w="", temp_c="",
                host_ms="", host_gpu_ms="", host_rss="", host_texture=""),
            row(2, "20", "8.0", gpu_ms="3.0", device_bytes="8192", power_w="10.0", temp_c="43.0"),
        ])))
        summary = analyze.summarize(rows)
        self.assertEqual(summary["frame_count"], 3)
        timing = summary["timing"]
        self.assertAlmostEqual(timing["derived_fps_from_mean_interval"], 66.6666666667)
        self.assertEqual(timing["cpu_frame_interval_ms"]["p50"], 15.0)
        self.assertEqual(timing["cpu_frame_interval_ms"]["p95"], 19.5)
        self.assertEqual(timing["synthetic_input_to_present_return_ms"]["p99"], 7.96)
        self.assertEqual(timing["gpu_ms"]["coverage"], 2 / 3)
        self.assertEqual(summary["transfer"]["transferred_bytes"]["total"], 300)
        self.assertEqual(summary["transfer"]["network_bytes_out"]["total"], 360)
        self.assertEqual(summary["transfer"]["network_bytes_in"]["total"], 96)
        self.assertEqual(summary["transfer"]["network_bytes_total"]["total"], 456)
        self.assertEqual(summary["memory"]["device_memory_bytes"]["missing"], 1)
        self.assertEqual(summary["memory"]["host_texture_bytes"]["coverage"], 2 / 3)
        self.assertEqual(summary["timing"]["host_receive_to_present_ms"]["sample_count"], 2)
        self.assertEqual(summary["environment_telemetry"]["power_w"]["sample_count"], 2)

    def test_rejects_wrong_header_order(self) -> None:
        text = csv_text([row(0, "0", "4")]).replace("frame_index,initialization_ms", "initialization_ms,frame_index", 1)
        with self.assertRaises(analyze.DataError):
            analyze.load_rows(io.StringIO(text))

    def test_rejects_non_finite_negative_and_fractional_counters(self) -> None:
        variants = [csv_text([row(0, "0", "NaN")])]
        negative = row(0, "0", "4")
        negative[9] = "-1"
        variants.append(csv_text([negative]))
        fractional = row(0, "0", "4")
        fractional[9] = "1.5"
        variants.append(csv_text([fractional]))
        for text in variants:
            with self.subTest(text=text):
                with self.assertRaises(analyze.DataError):
                    analyze.load_rows(io.StringIO(text))

    def test_rejects_non_contiguous_frames_and_empty_data(self) -> None:
        with self.assertRaises(analyze.DataError):
            analyze.load_rows(io.StringIO(csv_text([row(1, "0", "4")])))
        with self.assertRaises(analyze.DataError):
            analyze.load_rows(io.StringIO(",".join(analyze.FIELDS) + "\n"))

    def test_rejects_unknown_or_mixed_transport_modes(self) -> None:
        bad_mode = row(0, "0", "4", mode="unknown")
        with self.assertRaises(analyze.DataError):
            analyze.load_rows(io.StringIO(csv_text([bad_mode])))
        with self.assertRaises(analyze.DataError):
            analyze.load_rows(io.StringIO(csv_text([
                row(0, "0", "4", mode="direct_present", network_out="0", network_in="0"),
                row(1, "10", "6", mode="offload_tcp"),
            ])))


if __name__ == "__main__":
    unittest.main()
