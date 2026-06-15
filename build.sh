#!/usr/bin/env bash
# Build the encrypted dashboard: inline data into the template, then encrypt the whole page.
# Password is read from .staticrypt-pw (gitignored — never committed).
set -euo pipefail
cd "$(dirname "$0")"

[ -f .staticrypt-pw ] || { echo "ERROR: .staticrypt-pw not found. Create it with the shared password."; exit 1; }
PW="$(tr -d '\n\r' < .staticrypt-pw)"
[ -n "$PW" ] || { echo "ERROR: .staticrypt-pw is empty."; exit 1; }

mkdir -p _build

# 1) Inline data/weeks.json into the template at the __DATA__ marker.
python3 - <<'PY'
import json
tpl = open('_src/template.html').read()
data = open('data/weeks.json').read().strip()
json.loads(data)  # fail loud if the data isn't valid JSON
assert '__DATA__' in tpl, "template is missing the __DATA__ marker"
open('_build/index.html', 'w').write(tpl.replace('__DATA__', data))
print("inlined data -> _build/index.html")
PY

# 2) Encrypt _build/index.html with the shared password -> ./index.html (the only file served).
npx --yes staticrypt _build/index.html -p "$PW" -d . --short \
  --template-title "Dark Horse — Meta Ads" \
  --template-instructions "Enter the password Ronan shared with you." \
  --template-button "View dashboard" \
  --template-placeholder "Password" \
  --template-color-primary "#efc88e" \
  --template-color-secondary "#0d0b0a" >/dev/null

echo "encrypted -> index.html"
