#!/usr/bin/env bash
# AGENTS.md's release checklist: "a release bumps the version everywhere it is
# written down". Nine places, one string, and nothing before this script
# checked that a release actually touched all of them — the scaffold-check CI
# step went eight commits missing one of its own spots (`@ "main"` instead of
# the pinned tag) before anyone noticed, which is exactly the failure mode
# this exists to catch on the release path too.
#
# It was seven places until 0.11.0, and the two it did not know about had both
# gone stale: the page's "what's new" banner and README.md's "What X covers"
# heading were still advertising **0.9.0** two releases later. Neither is a
# `rev = ` line, so neither was caught, and a reader's first impression of the
# project is precisely the banner. The lesson is the one this script already
# embodies: a place that is not checked is a place that drifts, so widening
# the check matters more than fixing the two strings.
#
# The rule for what belongs here: anything that names the *current* version.
# A historical reference ("fixed in 0.9.1") does not, and neither does a
# "last checked on" marker — `ci/README.md` uses a date for exactly that
# reason, so it is not one more thing a release has to remember.
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
# The two that went stale for two releases before anything looked.
check README.md                "## What $version covers"
check site/index.html          "<strong>$version</strong>"

if [ "$fail" -ne 0 ]; then
  echo "error: release $version is missing from one or more of the places AGENTS.md's \
release checklist names — fix these before tagging" >&2
  exit 1
fi
echo "ok: version $version is consistent across all nine places"
