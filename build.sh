#!/usr/bin/env bash
# Build the encrypted dashboard in a strict, fail-loud 5-step sequence (Plan P3, Codex #11/#12):
#   1) validate    — schema validators on data/weeks.json AND data/funnel.json (abort on failure)
#   2) render       — inline data/weeks.json + a COMPACTED, RANKED subset of data/funnel.json
#                      into _src/template.html at __DATA__ -> _build/index.html
#   3) pre-checks   — on the READABLE _build/index.html: light theme, required markup, AA contrast
#   4) encrypt      — StatiCrypt _build/index.html -> served ./index.html (unchanged password scheme)
#   5) size gate    — fail if the ENCRYPTED index.html > 200KB (only exists after step 4)
# Any step exits nonzero -> the whole build aborts and publish.sh will not push.
# Password is read from .staticrypt-pw (gitignored — never committed).
#
# Funnel data flow (reference/funnel-data-contract.md in the workspace repo is the spec):
#   data/funnel.json  — the FULL, authoritative stage register (23 records). Validated in
#     full by validate_funnel.py so a missing stage value/source/basis/sample_n/band/caveat
#     fails THIS build, never ships as a blank stage. Never shipped to the browser as-is.
#   Step 2 below reads that full file, computes the §6 bottleneck ranking (largest loss
#   share over role:"step" edges, Block 1 excluded, never across a bridge, pending/partial
#   endpoints excluded), and derives a REDUCED per-record payload
#   (id/block/label/value/render/tier/band_label/caveat + a bottleneck flag on the winner)
#   for every record whose render isn't "none" and whose role isn't "prohibited". This is
#   what actually ships — "validate the full record, ship the rendered subset" (phase 7).
set -euo pipefail
cd "$(dirname "$0")"

# ---------------------------------------------------------------------------
# Step 1: Validate BOTH data schemas BEFORE anything is rendered or encrypted.
# ---------------------------------------------------------------------------
echo "[1/5] validate  -> python3 validate.py data/weeks.json"
python3 validate.py data/weeks.json
echo "[1/5] validate  -> python3 validate_funnel.py data/funnel.json"
python3 validate_funnel.py data/funnel.json

mkdir -p _build

# ---------------------------------------------------------------------------
# Step 2: Inline data/weeks.json + the compacted/ranked funnel subset into the
#          template at the __DATA__ marker.
# ---------------------------------------------------------------------------
echo "[2/5] render    -> inline data/weeks.json + compacted data/funnel.json"
python3 - <<'PY'
import json

tpl = open('_src/template.html').read()
weeks_data = json.loads(open('data/weeks.json').read())
funnel_full = json.loads(open('data/funnel.json').read())
records = funnel_full['records']

RENDER_CODE = {"count": "c", "percent": "p", "fraction": "f", "fraction_percent": "fp", "annotation": "a"}
TIER_CODE = {"banded": "b", "directional": "d", "baseline-pending": "p"}


def rank_bottleneck(recs):
    """§6 of the funnel data contract: largest loss share over declared role:"step" edges
    only (never node pairs). Block 1 excluded entirely. Never across a bridge (bridges are
    kind:"bridge", not "edge", so they are structurally excluded). Excludes any edge with a
    pending/partial endpoint or the NO_RANK prohibition. loss_share = 1 - (to/from); a
    loss_share <= 0 drops out. Ties break on absolute people lost, then earliest step
    (approximated here by declaration order in the file, which follows block/stage order)."""
    by_id = {r["id"]: r for r in recs}
    best = None
    for idx, r in enumerate(recs):
        if r.get("kind") != "edge" or r.get("role") != "step":
            continue
        if r.get("block") == 1:
            continue
        if "NO_RANK" in (r.get("prohibitions") or []):
            continue
        from_rec = by_id.get(r.get("denominator"))
        to_rec = by_id.get(r.get("to_node"))
        if not from_rec or not to_rec:
            continue
        from_v, to_v = from_rec.get("value"), to_rec.get("value")
        if not isinstance(from_v, (int, float)) or isinstance(from_v, bool):
            continue  # excludes a pending/partial FROM endpoint
        if not isinstance(to_v, (int, float)) or isinstance(to_v, bool):
            continue  # excludes a pending/partial TO endpoint
        if from_v == 0:
            continue
        loss_share = 1 - (to_v / from_v)
        if loss_share <= 0:
            continue  # never a false win — e.g. started->submitted running >100%
        lost_people = from_v - to_v
        candidate = (loss_share, lost_people, -idx)
        if best is None or candidate > best[0]:
            best = (candidate, r["id"])
    return best[1] if best else None


bottleneck_id = rank_bottleneck(records)

compact = []
for r in records:
    if r.get("render") == "none" or r.get("role") == "prohibited":
        continue  # cross-checks and the NEVER_COMPUTE guard never ship to the funnel
    if r.get("kind") == "bridge":
        continue  # bridge annotation text is generated live in JS from the linked node
        # records (b1.link_clicks, b2.page_visits) — the bridge record itself carries no
        # rendered content the dashboard ever reads, so shipping it would only cost bytes.
    # `block` is deliberately NOT shipped: the renderer groups stages by fixed id
    # sequences per block (funnelSection() in the template), so a per-record block tag
    # would be dead weight in the 200KB-constrained payload. If the renderer is ever
    # rewritten to group dynamically instead, re-add "blk": r["block"] here first.
    ren = r.get("render")
    entry = {
        "id": r["id"],
        "lbl": r["label"],
        "val": r["value"],
        "ren": RENDER_CODE.get(ren, ren),
        "cav": r["caveat"],
    }
    tier = r.get("tier")
    if tier in TIER_CODE:
        entry["tier"] = TIER_CODE[tier]
        if tier == "banded":
            entry["band"] = r.get("band_label", "none")
    if r["id"] == bottleneck_id:
        entry["bn"] = True
    compact.append(entry)

weeks_data["funnel"] = {"asOf": funnel_full.get("as_of", ""), "records": compact}

data = json.dumps(weeks_data, separators=(",", ":"))
assert '__DATA__' in tpl, "template is missing the __DATA__ marker"
open('_build/index.html', 'w').write(tpl.replace('__DATA__', data))
print(f"      inlined data + {len(compact)} funnel record(s), bottleneck={bottleneck_id!r} -> _build/index.html")
PY

# ---------------------------------------------------------------------------
# Step 3: Pre-encryption checks on the READABLE _build/index.html.
#   These MUST run on the plaintext build (StatiCrypt would obscure the markup).
#   - light theme present (off-white #fbfbfa, no dark-theme page bg)
#   - required card/zone markup present (zone cards, audience_freshness card,
#     #week-select, button.metric-card, card-panel)
#   - WCAG 2.2 AA contrast (normal text >= 4.5:1) for each zone number on its wash,
#     parsed live from the BANDS map so a future colour edit fails loud here.
# ---------------------------------------------------------------------------
echo "[3/5] pre-checks-> theme + markup + AA contrast on _build/index.html"
python3 - <<'PY'
import re, sys

html = open('_build/index.html').read()
errors = []

# --- 3a. Light theme present, no dark-theme page background -----------------
if '#fbfbfa' not in html:
    errors.append("light theme: off-white page bg '#fbfbfa' not found")
# The dark theme used a near-black page bg; if it reappears as a --bg value the
# reskin has regressed. (The StatiCrypt unlock-screen colour lives in build.sh,
# not in this rendered file, so it won't false-trip this.)
m = re.search(r'--bg:\s*(#[0-9a-fA-F]{3,6})', html)
if not m:
    errors.append("light theme: no `--bg:` page background variable found")
else:
    bg = m.group(1).lower()
    if bg != '#fbfbfa':
        errors.append(f"light theme: --bg is {bg}, expected #fbfbfa (dark-theme regression?)")

# --- 3b. Required card/zone markup present ----------------------------------
required_markup = {
    "zone card styling (.card.zone)":          ".card.zone",
    "zone icon markup (.zone-icon)":           "zone-icon",
    "audience_freshness card":                 "audience_freshness",
    "week selector (#week-select)":            "week-select",
    "button metric-card":                      'class="card metric-card',
    "expandable card panel (.card-panel)":     "card-panel",
}
for name, needle in required_markup.items():
    if needle not in html:
        errors.append(f"markup: {name} not found (looked for {needle!r})")

# --- 3c. AA contrast: each zone number colour on its washed background -------
# Parse the BANDS map: each band line carries  tc: "#text"  ...  bg: "#wash".
def _lum(hexc):
    hexc = hexc.lstrip('#')
    r, g, b = (int(hexc[i:i+2], 16) / 255.0 for i in (0, 2, 4))
    def chan(c):
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    return 0.2126 * chan(r) + 0.7152 * chan(g) + 0.0722 * chan(b)

def _ratio(fg, bg):
    l1, l2 = _lum(fg), _lum(bg)
    hi, lo = max(l1, l2), min(l1, l2)
    return (hi + 0.05) / (lo + 0.05)

band_pairs = re.findall(
    r'(\w+):\s*\{[^}]*?tc:\s*"(#[0-9a-fA-F]{6})"[^}]*?bg:\s*"(#[0-9a-fA-F]{6})"',
    html,
)
if not band_pairs:
    errors.append("AA contrast: could not locate any BANDS tc/bg colour pairs to check")
else:
    AA_NORMAL = 4.5
    seen = set()
    for key, tc, bg in band_pairs:
        sig = (tc.lower(), bg.lower())
        if sig in seen:
            continue
        seen.add(sig)
        ratio = _ratio(tc, bg)
        if ratio < AA_NORMAL:
            errors.append(
                f"AA contrast: zone '{key}' number {tc} on wash {bg} = {ratio:.2f}:1 "
                f"(< {AA_NORMAL}:1 required)"
            )
        else:
            print(f"      AA ok: {key} {tc} on {bg} = {ratio:.2f}:1")

if errors:
    print("PRE-ENCRYPTION CHECKS FAILED:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)
print("      pre-encryption checks passed")
PY

# ---------------------------------------------------------------------------
# Step 4: Encrypt _build/index.html -> ./index.html (the only file served).
#   Unchanged StatiCrypt invocation + password scheme.
# ---------------------------------------------------------------------------
echo "[4/5] encrypt   -> StatiCrypt _build/index.html -> ./index.html"
[ -f .staticrypt-pw ] || { echo "ERROR: .staticrypt-pw not found. Create it with the shared password."; exit 1; }
PW="$(tr -d '\n\r' < .staticrypt-pw)"
[ -n "$PW" ] || { echo "ERROR: .staticrypt-pw is empty."; exit 1; }

npx --yes staticrypt _build/index.html -p "$PW" -d . --short \
  --template-title "Dark Horse — Meta Ads" \
  --template-instructions "Enter the password Ronan shared with you." \
  --template-button "View dashboard" \
  --template-placeholder "Password" \
  --template-color-primary "#efc88e" \
  --template-color-secondary "#0d0b0a" >/dev/null

# ---------------------------------------------------------------------------
# Step 5: Post-encryption size gate. Must run AFTER encryption (the encrypted
#   file only exists now).
#
#   Ceiling raised 200KB -> 400KB on 05.08.26, Ronan's call. The old 200KB
#   limit was set to protect Conor's phone load, but the funnel rebuild left
#   only ~2KB of margin and each weekly entry costs ~8-9KB, so the NEXT normal
#   update would have aborted the build. Ronan chose to let the file grow with
#   accumulating history rather than prune older weeks.
#
#   The gate is kept rather than removed, for two reasons: it still catches a
#   runaway (a bad loop inlining data repeatedly), and the warning threshold
#   below gives notice before the ceiling is reached instead of failing cold.
#   400KB is roughly 22 more weekly entries.
# ---------------------------------------------------------------------------
echo "[5/5] size gate -> encrypted index.html must be <= 400KB"
[ -f index.html ] || { echo "ERROR: encrypted index.html was not produced."; exit 1; }
MAX_BYTES=$((400 * 1024))
WARN_BYTES=$((340 * 1024))
SIZE=$(wc -c < index.html | tr -d ' ')
if [ "$SIZE" -gt "$MAX_BYTES" ]; then
  echo "ERROR: encrypted index.html is ${SIZE} bytes (> ${MAX_BYTES} byte / 400KB budget)." >&2
  echo "       Prune older weeks from weeks.json, or raise the ceiling deliberately." >&2
  exit 1
fi
if [ "$SIZE" -gt "$WARN_BYTES" ]; then
  echo "      WARNING: ${SIZE} bytes is within ~7 weekly entries of the 400KB ceiling."
  echo "               Time to decide about pruning older weeks from weeks.json."
fi
echo "      size ok: ${SIZE} bytes (<= ${MAX_BYTES})"

echo "BUILD OK: encrypted -> index.html"
