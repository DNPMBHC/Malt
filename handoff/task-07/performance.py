#!/usr/bin/env python3
"""Validate samples and compare matching configurations using the standard library.

The input schema is performance-sample-v1 with metadata and runs. Metadata must
contain host {machineId, chip, os, sdk, architecture}, guest {os, architecture},
vm, backend, driver, gameVersionRegion {version, region}, resolution {width,
height}, quality, and scene. Strings must be nonempty. Each run contains startup
(cold/hot), startupMs, frameTimesMs, inputLatencyMs, cpuPercent, gpuPercent,
memoryMiB, powerW, and thermalState. Nullable measurements require a nonempty
reason in the run's missing object. Every represented startup mode needs three
or more repeats. Outputs contain only schema and metrics, with no input labels.

Frame percentiles use linear interpolation. Aggregates summarize per-run
percentiles with equal weight per repeat; stddev is the population deviation
across repeats. Cold and hot results are never pooled.
"""

from __future__ import annotations

import json
import math
import statistics
import sys
from collections import Counter
from pathlib import Path
from typing import Any

SCHEMA = "performance-sample-v1"
COMPARE_SCHEMA = "performance-compare-v1"
REQUIRED_METADATA = ("host", "guest", "vm", "backend", "driver",
                     "gameVersionRegion", "resolution", "quality", "scene")
NUMERIC_METRICS = ("startupMs", "inputLatencyMs", "cpuPercent", "gpuPercent",
                   "memoryMiB", "powerW")
RUN_FIELDS = ("startup", "frameTimesMs", *NUMERIC_METRICS, "thermalState")
STARTUP_STATES = ("cold", "hot")
THERMAL_STATES = ("nominal", "fair", "serious", "critical")
SAFE_REASONS = frozenset({"not_collected", "sensor_unavailable", "permission_required",
                          "instrumentation_unavailable", "not_applicable", "measurement_failed"})


class SampleError(ValueError):
    """A fixed error code safe to emit without input content."""


def _fail(code: str) -> None:
    raise SampleError(code)


def _number(value: Any, *, positive: bool = False) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        _fail("invalid_number")
    try:
        number = float(value)
    except OverflowError:
        _fail("invalid_number")
    if not math.isfinite(number) or number < 0 or (positive and number == 0):
        _fail("invalid_number")
    return number


def _string(value: Any) -> None:
    if not isinstance(value, str) or not value.strip():
        _fail("invalid_metadata")


def _metadata_value(value: Any) -> None:
    if isinstance(value, str):
        _string(value)
    elif isinstance(value, dict):
        if not value:
            _fail("invalid_metadata")
        for key, child in value.items():
            _string(key)
            _metadata_value(child)
    elif isinstance(value, list):
        if not value:
            _fail("invalid_metadata")
        for child in value:
            _metadata_value(child)
    elif isinstance(value, bool):
        return
    elif isinstance(value, (int, float)):
        _number(value)
    else:
        _fail("invalid_metadata")


def _required_strings(value: Any, keys: tuple[str, ...]) -> None:
    if not isinstance(value, dict) or any(key not in value for key in keys):
        _fail("invalid_metadata")
    for key in keys:
        _string(value[key])


def _metadata(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or any(key not in value for key in REQUIRED_METADATA):
        _fail("invalid_metadata")
    _metadata_value(value)
    _required_strings(value["host"], ("machineId", "chip", "os", "sdk", "architecture"))
    _required_strings(value["guest"], ("os", "architecture"))
    _required_strings(value["gameVersionRegion"], ("version", "region"))
    for key in ("vm", "backend", "driver", "quality", "scene"):
        _string(value[key])
    resolution = value["resolution"]
    if not isinstance(resolution, dict) or any(key not in resolution for key in ("width", "height")):
        _fail("invalid_metadata")
    for key in ("width", "height"):
        if isinstance(resolution[key], bool) or not isinstance(resolution[key], int) or resolution[key] <= 0:
            _fail("invalid_metadata")
    return value


def _reason(value: Any) -> str:
    if not isinstance(value, str) or not value.strip():
        _fail("missing_reason_required")
    return value if value in SAFE_REASONS else "redacted_reason"


def _run(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or any(field not in value for field in RUN_FIELDS):
        _fail("incomplete_run")
    if not isinstance(value["startup"], str) or value["startup"] not in STARTUP_STATES:
        _fail("invalid_startup")
    frames = value["frameTimesMs"]
    if not isinstance(frames, list) or not frames:
        _fail("frame_samples_required")
    result = {"startup": value["startup"], "frameTimesMs": [
        _number(frame, positive=True) for frame in frames], "missing": {}}
    reasons = value.get("missing", {})
    fields = (*NUMERIC_METRICS, "thermalState")
    if not isinstance(reasons, dict) or any(key not in fields for key in reasons):
        _fail("invalid_missing_reasons")
    for metric in fields:
        measurement = value[metric]
        if measurement is None:
            result["missing"][metric] = _reason(reasons.get(metric))
        elif metric in reasons:
            _fail("unexpected_missing_reason")
        elif metric == "thermalState":
            if not isinstance(measurement, str) or measurement not in THERMAL_STATES:
                _fail("invalid_thermal_state")
        else:
            measurement = _number(measurement)
        result[metric] = measurement
    return result


def validate_sample(sample: Any) -> dict[str, Any]:
    if not isinstance(sample, dict) or sample.get("schema") != SCHEMA:
        _fail("unsupported_sample_schema")
    metadata = _metadata(sample.get("metadata"))
    runs = sample.get("runs")
    if not isinstance(runs, list) or len(runs) < 3:
        _fail("insufficient_repeats")
    runs = [_run(run) for run in runs]
    if any(count < 3 for count in Counter(run["startup"] for run in runs).values()):
        _fail("insufficient_startup_repeats")
    return {"schema": SCHEMA, "metadata": metadata, "runs": runs}


def _percentile(values: list[float], percentile: float) -> float:
    ordered = sorted(values)
    position = (len(ordered) - 1) * percentile / 100
    lower, upper = math.floor(position), math.ceil(position)
    return round(ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower), 6)


def _measurement(run: dict[str, Any], metric: str) -> dict[str, Any]:
    value = run[metric]
    return {"value": value, **({"reason": run["missing"][metric]} if value is None else {})}


def _run_metrics(run: dict[str, Any]) -> dict[str, Any]:
    return {
        "startup": run["startup"],
        "frameTimeMs": {"samples": len(run["frameTimesMs"]), **{
            key: _percentile(run["frameTimesMs"], percentile)
            for key, percentile in (("p50", 50), ("p95", 95), ("p99", 99))}},
        **{metric: _measurement(run, metric) for metric in (*NUMERIC_METRICS, "thermalState")},
    }


def _distribution(values: list[float], expected: int) -> dict[str, Any]:
    missing = expected - len(values)
    result = {
        "median": _percentile(values, 50) if values else None,
        "min": min(values) if values else None, "max": max(values) if values else None,
        "stddev": round(statistics.pstdev(values), 6) if values else None,
        "samples": len(values), "missing": missing,
    }
    if missing:
        result["reason"] = "partial_missing" if values else "not_collected"
    return result


def _group_metrics(runs: list[dict[str, Any]]) -> dict[str, Any]:
    per_run = [_run_metrics(run) for run in runs]
    thermal = [run["thermalState"] for run in runs if run["thermalState"] is not None]
    missing = len(runs) - len(thermal)
    return {
        "runs": len(runs), "frameSamples": sum(len(run["frameTimesMs"]) for run in runs),
        "frameTimeMs": {key: _distribution([run["frameTimeMs"][key] for run in per_run], len(runs))
                        for key in ("p50", "p95", "p99")},
        **{metric: _distribution([run[metric] for run in runs if run[metric] is not None], len(runs))
           for metric in NUMERIC_METRICS},
        "thermalState": {
            "observed": [state for state in THERMAL_STATES if state in thermal] if thermal else None,
            "samples": len(thermal), "missing": missing,
            **({"reason": "partial_missing" if thermal else "not_collected"} if missing else {})},
    }


def summarize(sample: dict[str, Any]) -> dict[str, Any]:
    runs = validate_sample(sample)["runs"]
    return {"runs": len(runs), "perRun": [_run_metrics(run) for run in runs],
            "startup": {state: _group_metrics([run for run in runs if run["startup"] == state])
                        for state in STARTUP_STATES if any(run["startup"] == state for run in runs)}}


def _delta(candidate: dict[str, Any], baseline: dict[str, Any]) -> dict[str, Any]:
    if candidate["missing"] or baseline["missing"]:
        return {"value": None, "reason": "incomplete_measurement"}
    return {"value": round(candidate["median"] - baseline["median"], 6)}


def compare_samples(baseline: Any, candidate: Any) -> dict[str, Any]:
    baseline, candidate = validate_sample(baseline), validate_sample(candidate)
    def canonical(value):
        return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)
    if canonical(baseline["metadata"]) != canonical(candidate["metadata"]):
        _fail("metadata_mismatch")
    if Counter(run["startup"] for run in baseline["runs"]) != Counter(run["startup"] for run in candidate["runs"]):
        _fail("startup_repeats_mismatch")
    baseline, candidate = summarize(baseline), summarize(candidate)
    deltas = {}
    for startup, baseline_group in baseline["startup"].items():
        candidate_group = candidate["startup"][startup]
        deltas[startup] = {
            "frameTimeMs": {key: _delta(candidate_group["frameTimeMs"][key], baseline_group["frameTimeMs"][key])
                            for key in ("p50", "p95", "p99")},
            **{metric: _delta(candidate_group[metric], baseline_group[metric]) for metric in NUMERIC_METRICS}}
    return {"schema": COMPARE_SCHEMA, "metrics": {
        "baseline": baseline, "candidate": candidate, "delta": deltas}}


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result = {}
    for key, value in pairs:
        if key in result:
            _fail("invalid_sample_input")
        result[key] = value
    return result


def _load(path: str) -> Any:
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"),
                          parse_constant=lambda _: _fail("invalid_number"), object_pairs_hook=_unique_object)
    except (OSError, UnicodeError, json.JSONDecodeError, RecursionError) as error:
        raise SampleError("invalid_sample_input") from error


def _main(argv: list[str]) -> int:
    try:
        if len(argv) == 2 and argv[0] == "validate":
            result = {"schema": SCHEMA, "metrics": summarize(_load(argv[1]))}
        elif len(argv) == 3 and argv[0] == "compare":
            result = compare_samples(_load(argv[1]), _load(argv[2]))
        else:
            _fail("usage_validate_sample_or_compare_baseline_candidate")
    except SampleError as error:
        print(json.dumps({"schema": SCHEMA, "metrics": {"valid": False, "error": str(error)}}, sort_keys=True), file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True, separators=(",", ":"), allow_nan=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
