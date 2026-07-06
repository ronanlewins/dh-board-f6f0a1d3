#!/usr/bin/env python3
"""Schema validator for data/weeks.json.

Fails loudly (nonzero exit) and names the offending week/field if:
  - the file is not valid JSON,
  - any week is missing a required numeric in `metrics` (cpl, ctr, frequency, enquiries, spend),
  - any week is missing a required card/band field (incl. the 4 audience_freshness fields),
  - any top-level band array (`cpl_bands`, `ctr_bands`, `frequency_bands`) is malformed
    (not an ordered ascending array, missing key/color, a non-final max that isn't a
    number, or a final max that isn't null).

Run:  python3 validate.py [path/to/weeks.json]   (defaults to data/weeks.json)
Used by build.sh BEFORE inline/encrypt so a bad schema never deploys.
"""
import json
import sys
import os

# Required numeric fields inside each week's `metrics` object.
REQUIRED_METRICS = ["cpl", "ctr", "frequency", "enquiries", "spend"]

# Required top-level zone-band arrays (ordered ascending upper-bound, final max=null).
REQUIRED_BAND_ARRAYS = ["cpl_bands", "ctr_bands", "frequency_bands"]


def validate_band_array(name, bands, errors):
    """Validate one ordered ascending upper-bound band array; append problems to errors."""
    if bands is None:
        errors.append(f"top-level: missing required `{name}` array")
        return
    if not isinstance(bands, list) or len(bands) == 0:
        errors.append(f"top-level: `{name}` must be a non-empty array")
        return
    prev_max = None
    for i, band in enumerate(bands):
        where = f"{name}[{i}]"
        if not isinstance(band, dict):
            errors.append(f"{where}: band must be an object")
            continue
        if not band.get("key"):
            errors.append(f"{where}: missing `key`")
        if not band.get("color"):
            errors.append(f"{where}: missing `color`")
        if "max" not in band:
            errors.append(f"{where}: missing `max`")
            continue
        mx = band["max"]
        is_final = i == len(bands) - 1
        if is_final:
            if mx is not None:
                errors.append(f"{where}: final band `max` must be null (got {mx!r})")
        else:
            if not isinstance(mx, (int, float)) or isinstance(mx, bool):
                errors.append(f"{where}: non-final band `max` must be a number (got {mx!r})")
            else:
                if prev_max is not None and mx <= prev_max:
                    errors.append(
                        f"{where}: `max` ({mx}) must be greater than previous band's max ({prev_max}) — bands must be ordered ascending"
                    )
                prev_max = mx


# Required string/display fields inside each week's `cards` object.
REQUIRED_CARDS = [
    "spend",
    "enquiries",
    "cost_per_enquiry",
    "cost_per_enquiry_band",
    "cost_per_enquiry_band_label",
    "click_rate",
    "click_rate_band",
    "click_rate_band_label",
    "audience_freshness",
    "audience_freshness_sub",
    "audience_freshness_band",
    "audience_freshness_band_label",
    "best_ad",
]


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "data", "weeks.json"
    )

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

    # --- top-level band arrays -------------------------------------------
    for name in REQUIRED_BAND_ARRAYS:
        validate_band_array(name, data.get(name), errors)
    bands = data.get("cpl_bands")

    # --- weeks -----------------------------------------------------------
    weeks = data.get("weeks")
    if not isinstance(weeks, list) or len(weeks) == 0:
        errors.append("top-level: `weeks` must be a non-empty array")
        weeks = []

    for w in weeks:
        wid = w.get("week_ending") or w.get("week_label") or "<unknown week>"

        metrics = w.get("metrics")
        if not isinstance(metrics, dict):
            errors.append(f"week {wid}: missing or invalid `metrics` object")
        else:
            for key in REQUIRED_METRICS:
                if key not in metrics:
                    errors.append(f"week {wid}: metrics.{key} is missing")
                elif not isinstance(metrics[key], (int, float)) or isinstance(metrics[key], bool):
                    errors.append(
                        f"week {wid}: metrics.{key} must be a number (got {metrics[key]!r})"
                    )

        cards = w.get("cards")
        if not isinstance(cards, dict):
            errors.append(f"week {wid}: missing or invalid `cards` object")
        else:
            for key in REQUIRED_CARDS:
                val = cards.get(key)
                if val is None or (isinstance(val, str) and val.strip() == ""):
                    errors.append(f"week {wid}: cards.{key} is missing or empty")

    # --- current_cycle (monthly view) -----------------------------------
    cc = data.get("current_cycle")
    if not isinstance(cc, dict):
        errors.append("top-level: missing or invalid `current_cycle` object")
    else:
        for key in ["cycle_start", "cycle_end", "cycle_label", "status", "status_label"]:
            v = cc.get(key)
            if v is None or (isinstance(v, str) and v.strip() == ""):
                errors.append(f"current_cycle.{key} is missing or empty")
        funnel = cc.get("funnel")
        if not isinstance(funnel, list) or len(funnel) == 0:
            errors.append("current_cycle.funnel must be a non-empty array")
        else:
            for i, f in enumerate(funnel):
                if not isinstance(f, dict) or not f.get("label") or not str(f.get("value", "")).strip():
                    errors.append(f"current_cycle.funnel[{i}] must have a non-empty label + value")

    # --- all_time (standing cards) --------------------------------------
    at = data.get("all_time")
    if not isinstance(at, dict):
        errors.append("top-level: missing or invalid `all_time` object")
    else:
        cards = at.get("cards")
        if not isinstance(cards, list) or len(cards) == 0:
            errors.append("all_time.cards must be a non-empty array")
        else:
            for i, c in enumerate(cards):
                if not isinstance(c, dict) or not c.get("label") or not str(c.get("value", "")).strip():
                    errors.append(f"all_time.cards[{i}] must have a non-empty label + value")

    if errors:
        print(f"SCHEMA VALIDATION FAILED ({len(errors)} error(s)) in {path}:", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        sys.exit(1)

    print(f"OK: {path} valid ({len(weeks)} week(s), {len(bands or [])} cpl_band(s)).")
    sys.exit(0)


if __name__ == "__main__":
    main()
