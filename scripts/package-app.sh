#!/usr/bin/env bash
# Build the zip to upload to Hostinger.
#
#   bash package-app.sh <app-dir> [git-ref]        # default ref: HEAD
#
# Rules this enforces, each one learned the hard way:
#   * only committed files — an untracked file that works on your machine and is
#     missing from the zip is a deploy that fails for reasons you cannot see
#   * no node_modules, no build output, no .env, no database files
#   * no non-ASCII filenames: unzip mangles UTF-8 names stored without the UTF-8
#     flag and truncates the file
set -euo pipefail

APP="${1:-.}"
REF="${2:-HEAD}"
cd "$APP"
NAME=$(basename "$PWD" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
OUT="${TMPDIR:-/tmp}/${NAME}-hostinger-$(date +%Y%m%d-%H%M).zip"

git rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repository — commit first"; exit 1; }
if [ -n "$(git status --porcelain)" ]; then
  echo "warning: uncommitted changes will NOT be in the package:"
  git status --short | sed 's/^/  /'
  echo ""
fi

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
git archive --format=tar "$REF" | (cd "$STAGE" && tar x)

DROPPED=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  rm -f "$STAGE/$f"
  DROPPED="$DROPPED  $f\n"
done < <(cd "$STAGE" && find . -type f | LC_ALL=C grep '[^ -~]' | sed 's|^\./||' || true)

for junk in .env .env.local; do rm -f "$STAGE/$junk"; done
find "$STAGE" -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' | while read -r f; do
  echo "dropping database file: ${f#$STAGE/}"; rm -f "$f"
done

(cd "$STAGE" && zip -qr "$OUT" . -x '.*')

echo ""
echo "package: $OUT"
echo "size:    $(du -h "$OUT" | cut -f1)"
echo "files:   $(unzip -l "$OUT" | tail -1 | awk '{print $2}')"
echo "ref:     $REF ($(git rev-parse --short "$REF"))"
if [ -n "$DROPPED" ]; then
  echo ""
  echo "dropped (non-ASCII filenames — unzip corrupts these):"
  printf "$DROPPED"
  echo "  If any of those are needed at run time, rename them and commit first."
fi
echo ""
echo "Upload with: Framework=Other · Root=./ · Output directory EMPTY · Entry=server.js"
echo "Set every environment variable BEFORE the first deploy."
