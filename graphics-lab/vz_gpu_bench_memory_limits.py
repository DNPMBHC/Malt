#!/usr/bin/env python3
"""Isolate VZ configuration aperture limits without exhausting RAM. Owner: @DNPMBHC."""
from __future__ import annotations

import json

import vz_gpu_bench_runner as runner


def main() -> int:
    page = 16384
    candidates = [page, page + 1, 256 * 1024 * 1024]
    candidates += [1 << exponent for exponent in range(40, 64)]
    candidates += [(1 << 64) - page, (1 << 64) - 1]
    results = []
    for size in candidates:
        result = runner.capture([str(runner.BINARY), "--mode", "shared-memory-capacity-case",
                                 "--region-bytes", str(size)], timeout=15)
        row = {"requested_bytes": size, "process_exit": result.returncode}
        if result.returncode == 0:
            row["native"] = json.loads(result.stdout)
        else:
            row["exception"] = runner.redact(result.stderr.split("*** First throw call stack:")[0],
                                            runner.ROOT)[:1200]
        results.append(row)
    accepted = [row["requested_bytes"] for row in results if row.get("native", {}).get("validated")]
    report = {"owner": "@DNPMBHC", "native_binary_sha256": runner.sha256_file(runner.BINARY),
              "scope": "configuration_aperture_not_physical_RAM_allocation",
              "physical_allocation_attempted": False, "physical_allocation_maximum_established": False,
              "maximum_accepted_requested_bytes": max(accepted, default=0), "cases": results}
    runner.save_json(runner.EVIDENCE / "shared-memory-capacity-boundary.json", report)
    print(json.dumps({"owner": "@DNPMBHC", "configuration_cases": len(results),
                      "maximum_accepted_requested_bytes": report["maximum_accepted_requested_bytes"],
                      "physical_allocation_attempted": False}))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(runner.redact(type(error).__name__ + ": " + str(error), runner.ROOT))
        raise SystemExit(1) from None
