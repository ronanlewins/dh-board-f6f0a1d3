#!/usr/bin/env bash
# Rebuild (inline + encrypt) and push. Usage: ./publish.sh "week ending YYYY-MM-DD"
set -euo pipefail
cd "$(dirname "$0")"
MSG="${1:-update dashboard}"

# Gate the push on a clean build: build.sh runs validate -> render -> pre-encryption
# checks -> encrypt -> size gate, exiting nonzero on ANY failure. If it fails, abort
# here and push nothing (a bad schema / failed check / oversized artefact never ships).
if ! ./build.sh; then
  echo "ERROR: build.sh failed — aborting publish. Nothing was pushed." >&2
  exit 1
fi

git add -A
git commit -m "Update: $MSG" || { echo "Nothing to commit."; exit 0; }
git push origin main
echo "Pushed. GitHub Pages will redeploy in ~1 minute."
