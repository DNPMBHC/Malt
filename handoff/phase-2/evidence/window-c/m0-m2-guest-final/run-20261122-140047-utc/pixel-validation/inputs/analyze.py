#!/usr/bin/env python3
"""Validate and summarize benchmark CSV emitted by d3d11_probe."""

from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
import sys
from pathlib import Path
from typing import Iterable


FIELDS = (
    "transport_mode",
    "frame_index",
    "initialization_ms",
    "warmup_ms",
    "cpu_frame_ms",
    "cpu_submit_ms",
    "process_cpu_ms",
    "gpu_ms",
    "synthetic_input_to_present_return_ms",
    "transferred_bytes",
    "command_bytes",
    "resource_bytes",
    "resident_bytes",
    "device_memory_bytes",
    "power_w",
    "temperature_c",
    "network_bytes_out",
    "network_bytes_in",
    "host_receive_to_present_ms",
    "host_gpu_ms",
    "host_resident_bytes",
    "host_texture_bytes",
)
OPTIONAL = {
    "gpu_ms",
    "device_memory_bytes",
    "network_bytes_out",
    "network_bytes_in",
    "power_w",
    "temperature_c",
    "host_receive_to_present_ms",
    "host_gpu_ms",
    "host_resident_bytes",
    "host_texture_bytes",
}
INTEGER_FIELDS = {
    "frame_index",
    "transferred_bytes",
    "command_bytes",
    "resource_bytes",
    "resident_bytes",
    "device_memory_bytes",
    "network_bytes_out",
    "network_bytes_in",
    "host_resident_bytes",
    "host_texture_bytes",
}
TRANSPORT_MODES = {"direct_present", "offload_tcp"}


class DataError(ValueError):
    """Raised when a CSV cannot be safely interpreted as benchmark data."""


def _number(raw: str | None, field: str, line: int, optional: bool) -> float | int | None:
    if raw is None or raw.strip() == "":
        if optional:
            return None
        raise DataError(f"line {line}: {field} is required")
    try:
        value = float(raw)
    except ValueError as exc:
        raise DataError(f"line {line}: {field} must be numeric") from exc
    if not math.isfinite(value):
        raise DataError(f"line {line}: {field} must be finite")
    if value < 0:
        raise DataError(f"line {line}: {field} must be non-negative")
    if field in INTEGER_FIELDS:
        if not value.is_integer():
            raise DataError(f"line {line}: {field} must be an integer")
        return int(value)
    return value


def load_rows(stream: Iterable[str]) -> list[dict[str, float | int | None]]:
    reader = csv.DictReader(stream)
    if tuple(reader.fieldnames or ()) != FIELDS:
        raise DataError("CSV header does not match the required benchmark schema and order")

    rows: list[dict[str, float | int | str | None]] = []
    transport_mode: str | None = None
    for line, raw_row in enumerate(reader, start=2):
        if None in raw_row:
            raise DataError(f"line {line}: too many columns")
        raw_mode = raw_row.get("transport_mode")
        if raw_mode not in TRANSPORT_MODES:
            raise DataError(f"line {line}: transport_mode must be direct_present or offload_tcp")
        if transport_mode is None:
            transport_mode = raw_mode
        elif raw_mode != transport_mode:
            raise DataError("transport_mode must remain constant within one CSV run")
        row: dict[str, float | int | str | None] = {"transport_mode": raw_mode}
        for field in FIELDS:
            if field == "transport_mode":
                continue
            row[field] = _number(raw_row.get(field), field, line, field in OPTIONAL)
        expected_index = len(rows)
        if row["frame_index"] != expected_index:
            raise DataError(f"line {line}: frame_index must be contiguous from zero")
        if expected_index == 0 and row["cpu_frame_ms"] != 0:
            raise DataError("line 2: first cpu_frame_ms must be zero (no preceding frame)")
        if expected_index > 0 and row["cpu_frame_ms"] == 0:
            raise DataError(f"line {line}: cpu_frame_ms must be positive after the first frame")
        rows.append(row)
    if not rows:
        raise DataError("CSV contains no benchmark frames")
    return rows


def percentile(values: list[float], p: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    pos = (len(ordered) - 1) * p
    lower = math.floor(pos)
    upper = math.ceil(pos)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (pos - lower)


def distribution(values: list[float]) -> dict[str, float | int | None]:
    return {
        "sample_count": len(values),
        "mean": statistics.fmean(values) if values else None,
        "p50": percentile(values, 0.50),
        "p95": percentile(values, 0.95),
        "p99": percentile(values, 0.99),
        "max": max(values) if values else None,
    }


def _present_values(rows: list[dict[str, float | int | str | None]], field: str) -> list[float]:
    return [float(row[field]) for row in rows if row[field] is not None]


def _telemetry(rows: list[dict[str, float | int | str | None]], field: str) -> dict[str, float | int | None]:
    values = _present_values(rows, field)
    summary = distribution(values)
    summary["coverage"] = len(values) / len(rows)
    summary["missing"] = len(rows) - len(values)
    return summary


def summarize(rows: list[dict[str, float | int | str | None]]) -> dict[str, object]:
    frame_ms = [float(row["cpu_frame_ms"]) for row in rows[1:]]
    latency_ms = _present_values(rows, "synthetic_input_to_present_return_ms")

    def byte_stats(field: str) -> dict[str, float | int | None]:
        values = [int(row[field]) for row in rows if row[field] is not None]
        if not values:
            return {"sample_count": 0, "coverage": 0.0, "per_frame_mean": None,
                    "per_frame_min": None, "per_frame_max": None, "total": None}
        return {
            "per_frame_mean": statistics.fmean(values),
            "per_frame_min": min(values),
            "per_frame_max": max(values),
            "total": sum(values),
            "sample_count": len(values),
            "coverage": len(values) / len(rows),
        }

    network_out = byte_stats("network_bytes_out")
    network_in = byte_stats("network_bytes_in")
    paired_network = [
        int(row["network_bytes_out"]) + int(row["network_bytes_in"])
        for row in rows
        if row["network_bytes_out"] is not None and row["network_bytes_in"] is not None
    ]
    network_total = {
        "sample_count": len(paired_network),
        "coverage": len(paired_network) / len(rows),
        "per_frame_mean": statistics.fmean(paired_network) if paired_network else None,
        "per_frame_min": min(paired_network) if paired_network else None,
        "per_frame_max": max(paired_network) if paired_network else None,
        "total": sum(paired_network) if paired_network else None,
    }

    return {
        "schema_version": 1,
        "frame_count": len(rows),
        "transport_mode": rows[0]["transport_mode"],
        "timing": {
            "cpu_frame_interval_ms": distribution(frame_ms),
            "derived_fps_from_mean_interval": 1000.0 / statistics.fmean(frame_ms) if frame_ms else None,
            "cpu_submit_ms": distribution(_present_values(rows, "cpu_submit_ms")),
            "process_cpu_ms": distribution(_present_values(rows, "process_cpu_ms")),
            "gpu_ms": _telemetry(rows, "gpu_ms"),
            "synthetic_input_to_present_return_ms": distribution(latency_ms),
            "host_receive_to_present_ms": _telemetry(rows, "host_receive_to_present_ms"),
            "host_gpu_ms": _telemetry(rows, "host_gpu_ms"),
            "latency_note": "Synthetic frame-request-to-Present-return proxy; it is not physical input-to-photon latency.",
        },
        "transfer": {
            "transferred_bytes": byte_stats("transferred_bytes"),
            "command_bytes": byte_stats("command_bytes"),
            "resource_bytes": byte_stats("resource_bytes"),
            "network_bytes_out": network_out,
            "network_bytes_in": network_in,
            "network_bytes_total": network_total,
        },
        "memory": {
            "process_resident_bytes": distribution(_present_values(rows, "resident_bytes")),
            "device_memory_bytes": _telemetry(rows, "device_memory_bytes"),
            "host_resident_bytes": _telemetry(rows, "host_resident_bytes"),
            "host_texture_bytes": _telemetry(rows, "host_texture_bytes"),
        },
        "environment_telemetry": {
            "power_w": _telemetry(rows, "power_w"),
            "temperature_c": _telemetry(rows, "temperature_c"),
            "note": "Missing readings remain null and are not inferred.",
        },
        "run": {
            "initialization_ms": float(rows[0]["initialization_ms"]),
            "warmup_ms": float(rows[0]["warmup_ms"]),
        },
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv_file", type=Path, help="benchmark CSV to validate and summarize")
    parser.add_argument("--compact", action="store_true", help="emit compact JSON")
    args = parser.parse_args(argv)
    try:
        with args.csv_file.open("r", encoding="utf-8-sig", newline="") as stream:
            rows = load_rows(stream)
        print(json.dumps(summarize(rows), ensure_ascii=False, indent=None if args.compact else 2, sort_keys=True))
        return 0
    except (OSError, UnicodeError, csv.Error, DataError) as exc:
        print(f"analyze: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
