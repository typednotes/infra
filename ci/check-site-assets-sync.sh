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

# One-way, not a mirror. `assets/` is the source and may legitimately hold more
# than the page currently uses — artwork for a cloud that is not supported yet,
# and the `SOURCES.md` ledger, which has no business being served. What must
# hold is that every file the site publishes is byte-identical to its source.
while IFS= read -r f; do
  rel="${f#site/providers/}"
  if [ ! -f "assets/providers/$rel" ]; then
    echo "error: site/providers/$rel has no counterpart in assets/providers/" >&2
    echo "  assets/ is the source: add it there, or delete the published copy." >&2
    fail=1
  elif ! cmp -s "$f" "assets/providers/$rel"; then
    echo "error: site/providers/$rel differs from assets/providers/$rel" >&2
    echo "  assets/ is the source; refresh with: cp assets/providers/$rel $f" >&2
    fail=1
  fi
done < <(find site/providers -type f -name '*.svg')

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

# Not a failure, but worth saying: artwork carried in the source and not
# published. Silence here is how an unused file becomes a file nobody knows the
# status of.
while IFS= read -r f; do
  rel="${f#assets/providers/}"
  [ -f "site/providers/$rel" ] || echo "note: assets/providers/$rel is not published (unused by the page)"
done < <(find assets/providers -type f -name '*.svg')

if [ "$fail" -eq 0 ]; then
  echo "site assets: every published file matches its source, and every reference resolves"
fi
exit "$fail"
