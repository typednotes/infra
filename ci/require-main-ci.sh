#!/usr/bin/env bash
# Identical in Typednotes publishing repos; keep copies in sync.
# Usage: bash ci/require-main-ci.sh <CI workflow filename> <version tag>
# Trust boundary: GitHub's Actions API and the fetched Git refs. A PR result,
# manual CI, or another commit's success cannot authorize publication.
set -euo pipefail

fail() { printf '::error::%s\n' "$*" >&2; exit 1; }
[[ $# == 2 ]] || fail 'Expected a CI workflow filename and a version tag'
workflow=$1
tag=$2
[[ "$workflow" =~ ^[A-Za-z0-9_-]+\.ya?ml$ ]] || fail 'Invalid CI workflow filename'
[[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?(\+[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] \
  || fail "Expected a version tag (vX.Y.Z, optionally prerelease/build): $tag"
[[ "${GITHUB_REPOSITORY:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || fail 'GITHUB_REPOSITORY must identify the publishing repository'
[[ -n "${GH_TOKEN:-}" ]] || fail 'GH_TOKEN with actions:read is required'
for tool in git gh jq; do
  command -v "$tool" >/dev/null 2>&1 || fail "Required tool is missing: $tool"
done

# Use the actual checkout, including workflow_dispatch's selected tag, never
# GITHUB_SHA (which can name the default branch for a manual dispatch).
sha=$(git rev-parse --verify 'HEAD^{commit}')
tag_sha=$(git rev-parse --verify "refs/tags/$tag^{commit}") \
  || fail "Version tag does not exist: $tag"
[[ "$sha" == "$tag_sha" ]] || fail "Checkout HEAD does not match $tag"
git show-ref --verify --quiet refs/remotes/origin/main \
  || fail 'origin/main is missing; checkout must use fetch-depth: 0'
git merge-base --is-ancestor "$sha" refs/remotes/origin/main \
  || fail "Tag $tag is not reachable from origin/main"

# Do not filter by success: a newer pending/failed attempt must block an older
# green attempt. The workflow endpoint also binds the evidence to its filename.
endpoint="repos/$GITHUB_REPOSITORY/actions/workflows/$workflow/runs?event=push&branch=main&head_sha=$sha&per_page=1"
runs=$(gh api --method GET "$endpoint") || fail 'Unable to read main CI runs'
if ! jq -e --arg sha "$sha" '
  (.workflow_runs | type == "array" and length == 1) and
  (.workflow_runs[0] |
    .event == "push" and .head_branch == "main" and .head_sha == $sha and
    .status == "completed" and .conclusion == "success")
' <<< "$runs" >/dev/null; then
  fail "Latest push-to-main run of $workflow for $sha must be completed/success. Push main, wait for CI, then push the version tag (or rerun this publisher)."
fi
printf 'Verified %s at %s against successful main CI (%s)\n' "$tag" "$sha" "$workflow"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'sha=%s\ntag=%s\n' "$sha" "$tag" >> "$GITHUB_OUTPUT"
fi
