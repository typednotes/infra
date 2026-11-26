#!/usr/bin/env bash
# Verify the linker helper kept for TOML projects that pin older Infra.
set -euo pipefail
cd "$(dirname "$0")/.."
.lake/packages/linen/ci/consumer/check-link-helpers.sh Infra/Cli/New.lean
