#!/usr/bin/env bash
# Lint every workflow under .github/workflows with actionlint.
#
# This exists because live-test.yml shipped with two `env:` keys on one job
# (0.20.0). A duplicate YAML key makes the whole file invalid, and GitHub says
# so only by recording a zero-second failed run of it on every push — for a
# workflow that is manual-only and so is never expected to run on a push at
# all, which reads as noise — and by refusing to dispatch it. Nothing in this
# repository parsed the workflows, so the first to notice was a person
# looking at the Actions tab.
#
# actionlint rather than a YAML parser: it checks what GitHub checks
# (duplicate keys, unknown keys, bad `${{ }}` expressions, a `needs` naming a
# job that does not exist), not just that the file is YAML. Shellcheck and
# pyflakes integration are off: this is a check that the workflows are valid,
# not a style review of every inline script.
#
# Usage: ci/check-workflows.sh [path/to/actionlint]
set -euo pipefail
cd "$(dirname "$0")/.."

actionlint="${1:-actionlint}"
if ! command -v "$actionlint" >/dev/null 2>&1; then
  echo "error: actionlint not found (looked for '$actionlint'). Install it" \
    "(https://github.com/rhysd/actionlint) or pass its path as the first argument." >&2
  exit 2
fi

shopt -s nullglob
files=(.github/workflows/*.yml .github/workflows/*.yaml)
if [ "${#files[@]}" -eq 0 ]; then
  # An empty glob must not read as "every workflow is valid".
  echo "error: no workflow files found under .github/workflows" >&2
  exit 2
fi

"$actionlint" -shellcheck= -pyflakes= "${files[@]}"
echo "ok: ${#files[@]} workflow file(s) pass actionlint"
