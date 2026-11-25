#!/usr/bin/env python3
"""Compile handoff/module-f/evidence.json into a lightweight read-only compatibility-matrix.json for Whisky.app."""

import argparse
import hashlib
import json
import pathlib
import sys


def compile_matrix(evidence_data: dict, evidence_sha256: str) -> dict:
    snapshot = evidence_data["snapshot"]
    products = {p["target_id"]: p for p in evidence_data["products"]}
    scopes = {s["scope_id"]: s for s in evidence_data["scopes"]}
    claims = {c["claim_id"]: c for c in evidence_data["claims"]}

    # Extract WoA bare-metal vs Virtualized ARM64 Guest orthogonal split summaries
    woa_splits = {}
    for cid in ("P-WOA-PRISM", "A-WOA-SPLIT", "A-CN-WOA-SPLIT"):
        if cid in claims:
            c = claims[cid]
            woa_splits[cid] = {
                "claim_id": cid,
                "scope_id": c["scope_id"],
                "topic": c["topic"],
                "status": c["status"],
                "updated_on": c["updated_on"],
                "summary_zh": c["summary_zh"],
                "limitation_zh": c["limitation_zh"],
                "value": c["value"],
            }

    records = []
    for rec in evidence_data["compatibility_matrix"]:
        sc = scopes[rec["scope_id"]]
        prod = products.get(sc["target_id"], {})
        records.append({
            "record_id": rec["record_id"],
            "scope_id": rec["scope_id"],
            "target_id": sc["target_id"],
            "product_name": prod.get("public_product_name", sc["scope_id"]),
            "platform": sc["platform"],
            "distribution": sc["distribution"],
            "region": sc["region"],
            "environment": rec["environment"],
            "guest_cpu_architecture": rec["guest_cpu_architecture"],
            "updated_on": rec["updated_on"],
            "five_dimension_states": {
                "publisher_permission": rec["publisher_permission"]["value"],
                "publisher_support": rec["publisher_support"]["value"],
                "driver_load": rec["driver_load"]["value"],
                "game_start": rec["game_start"]["value"],
                "protected_session": rec["protected_session"]["value"],
            },
            "basis_claim_ids": sorted(
                set(
                    rec["publisher_permission"]["basis_claim_ids"]
                    + rec["publisher_support"]["basis_claim_ids"]
                )
            ),
        })

    return {
        "schema_version": "1.0.0",
        "source_dataset_id": evidence_data["dataset_id"],
        "source_snapshot_id": f"{snapshot['as_of']}#{evidence_sha256[:16]}",
        "source_evidence_sha256": evidence_sha256,
        "as_of": snapshot["as_of"],
        "timezone": snapshot["timezone"],
        "source_count": len(evidence_data["sources"]),
        "claim_count": len(evidence_data["claims"]),
        "woa_and_vm_orthogonal_split": woa_splits,
        "records": records,
        "consumption_rules": evidence_data["consumption_rules"],
    }


def validate_compiled(matrix: dict, expected_sha256: str):
    if matrix.get("schema_version") != "1.0.0":
        raise ValueError("invalid schema_version")
    if matrix.get("source_evidence_sha256") != expected_sha256:
        raise ValueError("source_evidence_sha256 mismatch")
    if not matrix.get("records") or len(matrix["records"]) < 7:
        raise ValueError("expected at least 7 regional VM records")
    for key in ("P-WOA-PRISM", "A-WOA-SPLIT", "A-CN-WOA-SPLIT"):
        if key not in matrix.get("woa_and_vm_orthogonal_split", {}):
            raise ValueError(f"missing WoA/VM orthogonal split claim: {key}")
    for rec in matrix["records"]:
        states = rec["five_dimension_states"]
        for k in ("driver_load", "game_start", "protected_session"):
            if states[k] != "unknown":
                raise ValueError(f"{rec['record_id']}: untested runtime state promoted: {k}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--input",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parents[4] / "handoff/module-f/evidence.json",
    )
    parser.add_argument(
        "--output",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parents[4]
        / "Whisky/Whisky/Resources/compatibility-matrix.json",
    )
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    raw_bytes = args.input.read_bytes()
    ev_sha256 = hashlib.sha256(raw_bytes).hexdigest()
    evidence_data = json.loads(raw_bytes.decode("utf-8"))

    compiled = compile_matrix(evidence_data, ev_sha256)
    validate_compiled(compiled, ev_sha256)

    if args.self_test:
        tampered = json.loads(json.dumps(compiled))
        tampered["records"][0]["five_dimension_states"]["protected_session"] = "passed"
        try:
            validate_compiled(tampered, ev_sha256)
        except ValueError:
            pass
        else:
            raise ValueError("self-test failed to reject promoted protected_session")

    serialized = json.dumps(compiled, ensure_ascii=False, indent=2) + "\n"
    if any(tok in serialized for tok in ("/" + "Users" + "/", "/" + "home" + "/")):
        raise ValueError("private path in compiled compatibility-matrix.json")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(serialized, encoding="utf-8")
    out_sha256 = hashlib.sha256(args.output.read_bytes()).hexdigest()
    print(json.dumps({
        "result": "passed",
        "records": len(compiled["records"]),
        "source_snapshot_id": compiled["source_snapshot_id"],
        "compiled_sha256": out_sha256,
    }, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"Matrix compilation failed: {type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(1)
