#!/usr/bin/env bash
# Offline behavioral checks for the shared release gate. Optional arguments are
# other copies to exercise; no GitHub request, push or production checkout edit.
# Identical in all eight publishing repositories; keep copies in sync.
set -euo pipefail
for tool in bash git gh jq mktemp; do
  command -v "$tool" >/dev/null 2>&1 \
    || { printf 'error: required test tool is missing: %s\n' "$tool" >&2; exit 2; }
done
root=$(cd "$(dirname "$0")/.." && pwd)
if [[ $# == 0 ]]; then set -- "$root/ci/require-main-ci.sh"; fi
scratch=$(mktemp -d "${TMPDIR:-/tmp}/main-ci-gate.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/repo"

# The mock accepts only the documented read-only, workflow-specific query.
cat > "$scratch/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ $# == 4 && "$1" == api && "$2" == --method && "$3" == GET ]]
[[ "$4" == "$EXPECTED_ENDPOINT" ]]
printf '%s\n' "$4" >> "$MOCK_CALLS"
[[ "${API_FAIL:-0}" == 0 ]] || exit 1
printf '%s\n' "$API_RESPONSE"
MOCK
chmod +x "$scratch/bin/gh"
export PATH="$scratch/bin:$PATH" GH_TOKEN=offline-test GITHUB_REPOSITORY=typednotes/fixture
export GIT_AUTHOR_NAME='CI fixture' GIT_AUTHOR_EMAIL=ci@example.invalid
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
export MOCK_CALLS="$scratch/calls"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
cd "$scratch/repo"
git init -q -b main
git -c core.hooksPath=/dev/null -c commit.gpgSign=false commit -q --allow-empty -m base
base=$(git rev-parse HEAD)
git -c core.hooksPath=/dev/null -c tag.gpgSign=false tag -a v1.2.3 -m fixture
git -c tag.gpgSign=false tag v1.2.3-rc.1
git -c core.hooksPath=/dev/null -c commit.gpgSign=false commit -q --allow-empty -m tip
tip=$(git rev-parse HEAD)
git update-ref refs/remotes/origin/main "$tip"
git checkout -q --detach "$base"
# Simulates a manual dispatch from newer main releasing an older tested tag.
export GITHUB_SHA="$tip"

good=$(jq -nc --arg sha "$base" '{workflow_runs:[{event:"push",head_branch:"main",head_sha:$sha,status:"completed",conclusion:"success"}]}')
checks=0
expect() {
  local expected=$1 label=$2 workflow=${3:-ci.yml} tag=${4:-v1.2.3} rc=0
  local checkout_sha
  checkout_sha=$(git rev-parse HEAD)
  export EXPECTED_ENDPOINT="repos/$GITHUB_REPOSITORY/actions/workflows/$workflow/runs?event=push&branch=main&head_sha=$checkout_sha&per_page=1"
  export GITHUB_OUTPUT="$scratch/output"
  rm -f "$GITHUB_OUTPUT" "$MOCK_CALLS"
  bash "$helper" "$workflow" "$tag" > "$scratch/log" 2>&1 || rc=$?
  if [[ "$expected" == pass ]]; then
    [[ "$rc" == 0 ]] || { cat "$scratch/log" >&2; printf 'FAILED: %s\n' "$label" >&2; exit 1; }
    [[ -s "$MOCK_CALLS" ]] || { printf 'Gate passed without API evidence\n' >&2; exit 1; }
    [[ "$(cat "$GITHUB_OUTPUT")" == "$(printf 'sha=%s\ntag=%s' "$base" "$tag")" ]]
  else
    [[ "$rc" != 0 ]] || { printf 'FAILED: gate accepted %s\n' "$label" >&2; exit 1; }
    [[ ! -s "$GITHUB_OUTPUT" ]] || { printf 'Denied gate emitted publish outputs\n' >&2; exit 1; }
  fi
  checks=$((checks + 1))
}

for helper in "$@"; do
  [[ "$helper" == /* ]] || helper="$root/$helper"
  export API_RESPONSE="$good" API_FAIL=0
  expect pass 'annotated tag; actual checkout differs from dispatch GITHUB_SHA'
  expect pass 'Lean workflow identity' lean_action_ci.yml
  expect pass 'lightweight prerelease tag' ci.yml v1.2.3-rc.1
  for change in \
    '.workflow_runs[0].status = "queued"' \
    '.workflow_runs[0].status = "in_progress"' \
    '.workflow_runs[0].conclusion = "failure"' \
    '.workflow_runs[0].conclusion = "cancelled"' \
    '.workflow_runs[0].conclusion = "skipped"' \
    '.workflow_runs[0].conclusion = null' \
    '.workflow_runs[0].event = "pull_request"' \
    '.workflow_runs[0].event = "workflow_dispatch"' \
    '.workflow_runs[0].head_branch = "feature"' \
    '.workflow_runs[0].head_sha = "another-commit"' \
    'del(.workflow_runs[0].head_sha)' \
    '.workflow_runs = []' \
    'del(.workflow_runs)' \
    '.workflow_runs = {}'; do
    export API_RESPONSE
    API_RESPONSE=$(jq -c "$change" <<< "$good")
    expect fail "$change"
  done
  export API_RESPONSE='not json'
  expect fail 'malformed API response'
  # API per_page=1 exposes only the latest attempt: if that attempt failed,
  # an older successful attempt is never considered by the gate.
  export API_RESPONSE
  API_RESPONSE=$(jq -c '.workflow_runs[0].conclusion = "failure"' <<< "$good")
  expect fail 'latest attempt failed despite an older success'
  export API_RESPONSE="$good" API_FAIL=1
  expect fail 'API access refused/network failure'
  export API_FAIL=0
  expect fail 'non-version manual input' ci.yml main
  expect fail 'missing version tag' ci.yml v9.9.9
  expect fail 'workflow path injection' '../ci.yml'
  expect fail 'version tag injection' ci.yml 'v1.2.3;exit 0'
  expect fail 'leading-zero version' ci.yml v01.2.3
  export GH_TOKEN=''
  expect fail 'missing Actions token'
  export GH_TOKEN=offline-test
  export GITHUB_REPOSITORY='invalid/repo/endpoint'
  expect fail 'invalid repository identity'
  export GITHUB_REPOSITORY=typednotes/fixture

  git checkout -q --detach "$tip"
  API_RESPONSE=$(jq -c --arg sha "$tip" '.workflow_runs[0].head_sha = $sha' <<< "$good")
  expect fail 'checkout is main, not selected tag'
  git checkout -q --detach "$base"
  export API_RESPONSE="$good"
  git update-ref -d refs/remotes/origin/main
  expect fail 'missing main ref/shallow checkout'
  git update-ref refs/remotes/origin/main "$tip"

  git checkout -q --orphan fixture-unrelated
  git -c core.hooksPath=/dev/null -c commit.gpgSign=false commit -q --allow-empty -m unrelated
  git -c tag.gpgSign=false tag v4.5.6
  API_RESPONSE=$(jq -c --arg sha "$(git rev-parse HEAD)" '.workflow_runs[0].head_sha = $sha' <<< "$good")
  expect fail 'tag is outside main ancestry' ci.yml v4.5.6
  git checkout -q --detach "$base"
  git tag -d v4.5.6 >/dev/null
  git branch -D fixture-unrelated >/dev/null
  printf 'ok: behavioral release gate checks: %s\n' "$helper"
done
printf 'ok: %s offline gate cases\n' "$checks"
