#!/usr/bin/env bash
# The native link-flag block exists twice: in this repo's `lakefile.lean`, and
# embedded as a string in `Infra/Cli/New.lean` so that `infra new` can write it
# into a scaffolded project. Lake cannot propagate `moreLinkArgs` from a
# dependency, so every consumer needs its own copy — there is no way to have
# one.
#
# Two copies drift. These two did: the scaffolder's lost `pkgAbsoluteLibs`
# entirely and gained OpenSSL flags, which between them break the link on
# Linux — the exact failure the canonical block's comments exist to prevent,
# reintroduced into every project the scaffolder produced.
#
# So the duplication is checked rather than trusted.
set -euo pipefail
cd "$(dirname "$0")/.."

extract() {
  # Everything between the markers, inclusive.
  sed -n '/⟪native-link-flags:begin⟫/,/⟪native-link-flags:end⟫/p' "$1"
}

a=$(mktemp); b=$(mktemp)
trap 'rm -f "$a" "$b"' EXIT

extract lakefile.lean > "$a"
# The scaffolder holds it inside a Lean string literal, so quotes are escaped.
extract Infra/Cli/New.lean | sed 's/\\"/"/g' > "$b"

if [ ! -s "$a" ]; then
  echo "error: no marked block found in lakefile.lean" >&2
  exit 1
fi
if [ ! -s "$b" ]; then
  echo "error: no marked block found in Infra/Cli/New.lean" >&2
  exit 1
fi

if diff -u "$a" "$b" > /dev/null; then
  echo "lakefile link-flag block: in sync ($(wc -l < "$a" | tr -d ' ') lines)"
else
  echo "error: the native link-flag block has drifted." >&2
  echo "  lakefile.lean is the source of truth; Infra/Cli/New.lean mirrors it." >&2
  echo >&2
  diff -u "$a" "$b" >&2 || true
  exit 1
fi
