#!/usr/bin/env python3
"""Schema validator for data/funnel.json — the three-block Meta funnel stage register.

Contract: reference/funnel-data-contract.md (workspace repo) §3 "The stage record — schema
and validation". This validator enforces every required field on the FULL record so a
missing stage value, source, basis, sample size, band or caveat fails the deploy rather
than rendering a blank stage (plan task 11). It runs against the full, unshipped record
file — build.sh compacts a reduced subset for the browser AFTER this passes. Never weaken
this validator to save shipped bytes; the byte budget is enforced elsewhere (the size gate).

Run:  python3 validate_funnel.py [path/to/funnel.json]   (defaults to data/funnel.json)
Used by build.sh BEFORE compaction/render so a bad or incomplete funnel record never ships.
"""
import json
import sys
import os

REQUIRED_FIELDS = [
    "id", "block", "kind", "role", "label", "value", "render", "source",
    "time_basis", "attribution_basis", "denominator", "tier", "band_source",
    "band_label", "sample_n", "interval", "prohibitions", "caveat",
]

VALID_BLOCKS = {1, 2, 3, "bridge1", "bridge2"}
VALID_KINDS = {"node", "edge", "bridge", "cross_check"}
VALID_ROLES = {"step", "diagnostic", "span", "annotation", "prohibited"}
VALID_TIERS = {"banded", "directional", "baseline-pending"}
VALID_RENDERS = {"count", "fraction", "percent", "fraction_percent", "annotation", "none"}
VALID_PROHIBITIONS = {
    "NO_PERCENT", "NO_BAND", "NO_SUM", "NO_CROSS_BRIDGE", "NO_CLAMP",
    "NO_RANK", "NO_ZERO_FILL", "NEVER_COMPUTE", "FRACTION_FIRST",
    # Added 11.08.26: data/funnel.json (hand-maintained, gitignored) started carrying
    # NO_BENCHMARK_BAND on b3.e_trial_to_member and b3.e_enquiry_to_member when those
    # edges moved to signed targets with no benchmark band behind them. The code was a
    # real, deliberate authoring choice; this validator's vocabulary had simply not
    # caught up, so the build failed on valid data.
    "NO_BENCHMARK_BAND",
}


def is_nonempty_str(v):
    return isinstance(v, str) and v.strip() != ""


def validate_record(r, idx, errors, seen_ids):
    where = f"records[{idx}]" if not isinstance(r, dict) or not r.get("id") else f"record '{r['id']}'"

    if not isinstance(r, dict):
        errors.append(f"{where}: record must be an object")
        return

    # --- presence of every required field (absence is always a bug — §3 principle 1) ---
    for field in REQUIRED_FIELDS:
        if field not in r:
            errors.append(f"{where}: missing required field `{field}`")

    rid = r.get("id")
    if not is_nonempty_str(rid):
        errors.append(f"{where}: `id` must be a non-empty string")
    elif rid in seen_ids:
        errors.append(f"{where}: duplicate id `{rid}` — ids are never renamed or reused once shipped")
    else:
        seen_ids.add(rid)

    kind = r.get("kind")
    if kind not in VALID_KINDS:
        errors.append(f"{where}: `kind` must be one of {sorted(VALID_KINDS)} (got {kind!r})")

    role = r.get("role")
    if role not in VALID_ROLES:
        errors.append(f"{where}: `role` must be one of {sorted(VALID_ROLES)} (got {role!r})")

    block = r.get("block")
    if block not in VALID_BLOCKS:
        errors.append(f"{where}: `block` must be one of {sorted(str(b) for b in VALID_BLOCKS)} (got {block!r})")

    if not is_nonempty_str(r.get("label")):
        errors.append(f"{where}: `label` must be a non-empty string (may be a placeholder '-' for prohibited edges)")

    # value: never blank, never null (numbers, or the literal strings "pending"/"partial:N"/
    # explicit n/a markers for bridges + the prohibited edge are all acceptable).
    value = r.get("value", "__MISSING__")
    if value in (None, "", "__MISSING__"):
        errors.append(f"{where}: `value` is missing, null or blank — NO_ZERO_FILL: use \"pending\" instead")
    is_number = isinstance(value, (int, float)) and not isinstance(value, bool)
    is_pending_like = isinstance(value, str) and (
        value == "pending" or value.startswith("partial:") or value.startswith("n/a")
    )
    is_fraction_str = isinstance(value, str) and "/" in value and not value.startswith("n/a")
    if not (is_number or is_pending_like or is_fraction_str):
        errors.append(f"{where}: `value` {value!r} is not a number, \"pending\", \"partial:N\", a fraction string, or an n/a marker")

    # pending_reason required whenever value isn't a plain number (§3: "if value != number")
    if not is_number and not is_fraction_str:
        if not is_nonempty_str(r.get("pending_reason")) and not str(value).startswith("n/a"):
            errors.append(f"{where}: `pending_reason` is required because value is {value!r}")

    render = r.get("render")
    if render not in VALID_RENDERS:
        errors.append(f"{where}: `render` must be one of {sorted(VALID_RENDERS)} (got {render!r})")

    for field in ("source", "time_basis", "attribution_basis"):
        if not is_nonempty_str(r.get(field)):
            errors.append(f"{where}: `{field}` must be a non-empty string")

    denom = r.get("denominator")
    if not is_nonempty_str(denom):
        errors.append(f"{where}: `denominator` must be a non-empty string (id, \"n/a - count\", or \"n/a - prohibited\")")

    # to_node: the downstream node id this edge measures a drop against. Required on every
    # edge (except node/bridge/cross_check kinds) — the bottleneck ranking (§6) needs an
    # unambiguous FROM/TO node pair and must never infer it from the rendered `value`
    # (which may be a percent, a fraction string, or "pending" — none of those are a safe
    # proxy for the raw downstream count).
    if kind == "edge":
        to_node = r.get("to_node")
        if not is_nonempty_str(to_node):
            errors.append(f"{where}: `to_node` is required on every edge record (drives the bottleneck ranking's FROM/TO pair)")

    tier = r.get("tier")
    # Bridges and the one NEVER_COMPUTE edge sit outside the 3-tier scale entirely.
    tier_exempt = kind == "bridge" or role == "prohibited"
    if tier_exempt:
        if tier != "n/a":
            errors.append(f"{where}: bridges and prohibited edges must carry tier \"n/a\" (got {tier!r})")
    elif tier not in VALID_TIERS:
        errors.append(f"{where}: `tier` must be one of {sorted(VALID_TIERS)} (got {tier!r})")

    band_source = r.get("band_source")
    if not is_nonempty_str(band_source):
        errors.append(f"{where}: `band_source` must be a non-empty string — \"none\" is a value, absence is a bug")

    band_label = r.get("band_label")
    if not is_nonempty_str(band_label):
        errors.append(f"{where}: `band_label` must be a non-empty string — \"none\" is a value, absence is a bug")
    elif tier != "banded" and band_label != "none":
        errors.append(f"{where}: `band_label` must be \"none\" unless tier == \"banded\" (tier={tier!r}, band_label={band_label!r}) — colour/band names appear ONLY at tier banded")

    if tier == "banded" and "straddles_boundary" not in r:
        errors.append(f"{where}: `straddles_boundary` is required when tier == \"banded\"")

    if block == 2 and kind == "node" and "window_coverage" not in r:
        errors.append(f"{where}: `window_coverage` is required for Block 2 nodes (drives the partial-window rule)")
    wc = r.get("window_coverage")
    if wc is not None and wc not in ("full", "N/A") and not (isinstance(wc, str) and wc.split("/")[0].isdigit() and wc.endswith("/28")):
        errors.append(f"{where}: `window_coverage` must be \"full\", \"N/A\" or \"N/28\" (got {wc!r})")

    for field in ("sample_n", "interval", "caveat"):
        if not is_nonempty_str(r.get(field)):
            errors.append(f"{where}: `{field}` must be a non-empty string — never empty")

    prohibitions = r.get("prohibitions")
    if not isinstance(prohibitions, list):
        errors.append(f"{where}: `prohibitions` must be an array ([] is allowed — the key itself is not optional)")
    else:
        for code in prohibitions:
            if code not in VALID_PROHIBITIONS:
                errors.append(f"{where}: unknown prohibition code {code!r}")

    # --- cross-field consistency rules ------------------------------------------------
    if render == "percent" and isinstance(prohibitions, list) and "NO_PERCENT" in prohibitions:
        errors.append(f"{where}: render=\"percent\" contradicts prohibition NO_PERCENT")

    if role == "prohibited":
        if not (isinstance(prohibitions, list) and "NEVER_COMPUTE" in prohibitions):
            errors.append(f"{where}: role \"prohibited\" edges must carry the NEVER_COMPUTE prohibition")
        if is_number:
            errors.append(f"{where}: a NEVER_COMPUTE edge must never carry a numeric value, not even for validation")
        if render != "none":
            errors.append(f"{where}: a NEVER_COMPUTE edge must render \"none\"")

    if kind == "cross_check" and render != "none":
        errors.append(f"{where}: cross_check records render \"none\" on the funnel (analyst doc only)")

    if isinstance(prohibitions, list) and "NO_ZERO_FILL" in prohibitions:
        if is_number and value == 0:
            errors.append(f"{where}: NO_ZERO_FILL stage carries literal 0 — use \"pending\"/\"partial:N\" unless this is a validated true zero")


def validate_referential_integrity(records, errors):
    """Every edge's denominator and to_node must name an id that exists in this file
    (unless it is an explicit n/a marker)."""
    ids = {r.get("id") for r in records if isinstance(r, dict)}
    for r in records:
        if not isinstance(r, dict):
            continue
        denom = r.get("denominator", "")
        if isinstance(denom, str) and not denom.startswith("n/a") and denom not in ids:
            errors.append(f"record '{r.get('id')}': denominator {denom!r} does not name an id present in this file")
        to_node = r.get("to_node")
        if to_node is not None and to_node not in ids:
            errors.append(f"record '{r.get('id')}': to_node {to_node!r} does not name an id present in this file")


def main():
    default_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "funnel.json")
    path = sys.argv[1] if len(sys.argv) > 1 else default_path

    errors = []

    try:
        with open(path) as f:
            data = json.load(f)
    except FileNotFoundError:
        print(f"FAIL: file not found: {path}", file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"FAIL: {path} is not valid JSON: {e}", file=sys.stderr)
        sys.exit(1)

    records = data.get("records")
    if not isinstance(records, list) or len(records) == 0:
        print("SCHEMA VALIDATION FAILED: top-level `records` must be a non-empty array", file=sys.stderr)
        sys.exit(1)

    seen_ids = set()
    for i, r in enumerate(records):
        validate_record(r, i, errors, seen_ids)

    validate_referential_integrity(records, errors)

    # Structural guard: the exact stages the contract names as NEVER_COMPUTE / cross-check
    # must exist and be flagged correctly — catches silent deletion, not just malformed edits.
    by_id = {r.get("id"): r for r in records if isinstance(r, dict)}
    if "b3.e_attended_to_member" not in by_id:
        errors.append("required guard record 'b3.e_attended_to_member' (NEVER_COMPUTE) is missing from the file")
    if "b2.thankyou_arrivals" not in by_id:
        errors.append("required cross-check record 'b2.thankyou_arrivals' is missing from the file")

    if errors:
        print(f"FUNNEL SCHEMA VALIDATION FAILED ({len(errors)} error(s)) in {path}:", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        sys.exit(1)

    print(f"OK: {path} valid ({len(records)} record(s)).")
    sys.exit(0)


if __name__ == "__main__":
    main()
