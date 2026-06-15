#!/usr/bin/env bash
# Rebuild (inline + encrypt) and push. Usage: ./publish.sh "week ending YYYY-MM-DD"
set -euo pipefail
cd "$(dirname "$0")"
MSG="${1:-update dashboard}"
./build.sh
git add -A
git commit -m "Update: $MSG" || { echo "Nothing to commit."; exit 0; }
git push origin main
echo "Pushed. GitHub Pages will redeploy in ~1 minute."
