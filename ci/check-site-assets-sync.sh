#!/usr/bin/env bash
# `assets/` is where the artwork lives; `site/` is what GitHub Pages publishes,
# and `pages.yml` uploads `site/` alone. So the page needs its own copy, and
# there are two copies of every file.
#
# They drifted immediately. A commit added `*-dark.svg` variants to
# `assets/providers/` and referenced them from the page — which serves
# `site/providers/`, where they did not exist. A `<picture>` whose matching
# `<source>` 404s does *not* fall back to its `<img>`, so dark mode would have
# shown broken images on the published site while every local check passed.
#
# Same lesson as ci/check-lakefile-sync.sh: duplication that cannot be removed
# gets checked instead.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0

# Only the artwork is compared. `assets/providers/SOURCES.md` is the provenance
# ledger and has no business being served, so it lives on the source side only.
if ! diff -rq --exclude='*.md' assets/providers site/providers > /tmp/providers-diff 2>&1; then
  echo "error: assets/providers and site/providers differ." >&2
  echo "  assets/ is the source; refresh the copy with:" >&2
  echo "    rm -rf site/providers && cp -r assets/providers site/providers \\" >&2
  echo "      && rm -f site/providers/*.md" >&2
  echo >&2
  cat /tmp/providers-diff >&2
  fail=1
fi

if ! cmp -s assets/logo.svg site/logo.svg; then
  echo "error: assets/logo.svg and site/logo.svg differ (assets/ is the source)." >&2
  fail=1
fi

# Every image the page references must exist in the published tree. This is the
# check that would have caught the broken dark sources.
missing=0
while read -r ref; do
  [ -n "$ref" ] || continue
  case "$ref" in http*|data:*) continue ;; esac
  if [ ! -f "site/$ref" ]; then
    echo "error: site/index.html references '$ref', which is not in site/" >&2
    missing=1
  fi
done < <(grep -oE '(src|srcset)="[^"]+"' site/index.html | sed -E 's/^(src|srcset)="//; s/"$//')

[ "$missing" -eq 0 ] || fail=1

if [ "$fail" -eq 0 ]; then
  echo "site assets: in sync, and every reference resolves"
fi
exit "$fail"
