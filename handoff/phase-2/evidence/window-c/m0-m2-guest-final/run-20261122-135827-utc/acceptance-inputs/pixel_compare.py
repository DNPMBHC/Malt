#!/usr/bin/env python3
"""Compare two raw, top-left-origin RGBA8 frames without conversion or scaling."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path


def compare_rgba(reference: bytes, actual: bytes, width: int, height: int, tolerance: int = 1) -> dict:
    for name, value in (("width", width), ("height", height)):
        if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
            raise ValueError(f"{name} must be a positive integer")
    if isinstance(tolerance, bool) or not isinstance(tolerance, int) or not 0 <= tolerance <= 255:
        raise ValueError("tolerance must be an integer from 0 through 255")
    required = width * height * 4
    if len(reference) != required or len(actual) != required:
        raise ValueError("RGBA frame length does not match width * height * 4")
    if not isinstance(reference, bytes) or not isinstance(actual, bytes):
        raise ValueError("RGBA frames must be bytes")
    maximum = 0
    failed_channels = 0
    failed_pixels = 0
    first_failure = None
    pixel_failed = False
    for i, (expected, observed) in enumerate(zip(reference, actual)):
        error = abs(expected - observed)
        maximum = max(maximum, error)
        if i % 4 == 0:
            pixel_failed = False
        if error > tolerance:
            failed_channels += 1
            if not pixel_failed:
                failed_pixels += 1
                pixel_failed = True
            if first_failure is None:
                pixel = i // 4
                first_failure = {"x": pixel % width, "y": pixel // width,
                                 "channel": "RGBA"[i % 4], "reference": expected,
                                 "actual": observed, "error": error}
    return {"schema_version": 1, "format": "RGBA8", "origin": "top-left",
            "width": width, "height": height, "tolerance_lsb": tolerance,
            "compared_pixels": width * height, "max_channel_error": maximum,
            "over_threshold_pixels": failed_pixels, "over_threshold_channels": failed_channels,
            "first_failure": first_failure, "passed": failed_channels == 0,
            "reference_sha256": hashlib.sha256(reference).hexdigest(),
            "actual_sha256": hashlib.sha256(actual).hexdigest()}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--actual", type=Path, required=True)
    parser.add_argument("--width", type=int, required=True)
    parser.add_argument("--height", type=int, required=True)
    parser.add_argument("--tolerance", type=int, default=1)
    parser.add_argument("--output-json", type=Path)
    args = parser.parse_args()
    try:
        result = compare_rgba(args.reference.read_bytes(), args.actual.read_bytes(),
                              args.width, args.height, args.tolerance)
        encoded = json.dumps(result, indent=2, sort_keys=True) + "\n"
        if args.output_json:
            from benchmark_support import writable_path
            writable_path(args.output_json).write_text(encoded, encoding="utf-8")
        print(encoded, end="")
        return 0 if result["passed"] else 1
    except (OSError, ValueError):
        print(json.dumps({"error": "invalid or unreadable RGBA comparison input"}))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
