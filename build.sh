#!/usr/bin/env bash
# Build the encrypted dashboard in a strict, fail-loud 5-step sequence (Plan P3, Codex #11/#12):
#   1) validate    — schema validator on data/weeks.json (abort on failure)
#   2) render       — inline data/weeks.json into _src/template.html at __DATA__ -> _build/index.html
#   3) pre-checks   — on the READABLE _build/index.html: light theme, required markup, AA contrast
#   4) encrypt      — StatiCrypt _build/index.html -> served ./index.html (unchanged password scheme)
#   5) size gate    — fail if the ENCRYPTED index.html > 200KB (only exists after step 4)
# Any step exits nonzero -> the whole build aborts and publish.sh will not push.
# Password is read from .staticrypt-pw (gitignored — never committed).
set -euo pipefail
cd "$(dirname "$0")"

# ---------------------------------------------------------------------------
# Step 1: Validate the data schema BEFORE anything is rendered or encrypted.
# ---------------------------------------------------------------------------
echo "[1/5] validate  -> python3 validate.py data/weeks.json"
python3 validate.py data/weeks.json

mkdir -p _build

# ---------------------------------------------------------------------------
# Step 2: Inline data/weeks.json into the template at the __DATA__ marker.
# ---------------------------------------------------------------------------
echo "[2/5] render    -> inline data/weeks.json into _src/template.html"
python3 - <<'PY'
import json
tpl = open('_src/template.html').read()
data = open('data/weeks.json').read().strip()
json.loads(data)  # fail loud if the data isn't valid JSON
assert '__DATA__' in tpl, "template is missing the __DATA__ marker"
open('_build/index.html', 'w').write(tpl.replace('__DATA__', data))
print("      inlined data -> _build/index.html")
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
#   file only exists now). Fail if the served index.html exceeds 200KB.
# ---------------------------------------------------------------------------
echo "[5/5] size gate -> encrypted index.html must be <= 200KB"
[ -f index.html ] || { echo "ERROR: encrypted index.html was not produced."; exit 1; }
MAX_BYTES=$((200 * 1024))
SIZE=$(wc -c < index.html | tr -d ' ')
if [ "$SIZE" -gt "$MAX_BYTES" ]; then
  echo "ERROR: encrypted index.html is ${SIZE} bytes (> ${MAX_BYTES} byte / 200KB budget)." >&2
  exit 1
fi
echo "      size ok: ${SIZE} bytes (<= ${MAX_BYTES})"

echo "BUILD OK: encrypted -> index.html"
