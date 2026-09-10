#!/usr/bin/env bash
# AGENTS.md's release checklist: "a release bumps the version everywhere it is
# written down" — lakefile.lean's `version`, Infra/Cli/New.lean's `infraRev`,
# the rev/@ in README.md, docs/tutorial.md and site/index.html, and the
# heading in CHANGELOG.md and docs/coverage.md. Seven places, one string, and
# nothing before this script checked that a release actually touched all
# seven — the scaffold-check CI step went eight commits missing one of its own
# spots (`@ "main"` instead of the pinned tag) before anyone noticed, which is
# exactly the failure mode this exists to catch on the release path too.
#
# Usage: ci/check-release-version.sh 0.9.4   (no leading "v")
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -ne 1 ]; then
  echo "usage: $0 <version, e.g. 0.9.4>" >&2
  exit 2
fi
version="$1"
case "$version" in
  v*) echo "error: pass the version without a leading 'v' (got '$version')" >&2; exit 2 ;;
esac

fail=0
check() {
  local file="$1" pattern="$2"
  if ! grep -qF "$pattern" "$file"; then
    echo "error: $file does not contain expected string: $pattern" >&2
    fail=1
  fi
}

check lakefile.lean            "version := v!\"$version\""
check Infra/Cli/New.lean       "infraRev : String := \"v$version\""
check README.md                "rev = \"v$version\""
check docs/tutorial.md         "@ \"v$version\""
check site/index.html          "rev = \"v$version\""
check CHANGELOG.md             "## [$version]"
check docs/coverage.md         "# Coverage in $version"

if [ "$fail" -ne 0 ]; then
  echo "error: release $version is missing from one or more of the places AGENTS.md's \
release checklist names — fix these before tagging" >&2
  exit 1
fi
echo "ok: version $version is consistent across all seven places"
