#!/usr/bin/env bash
# Validate this repository's AWS policy documents against IAM's policy grammar.
#
# This exists because the file shipped with a top-level `"Comment"` key. IAM's
# grammar allows only `Version`, `Id` and `Statement`, so `aws iam
# create-policy` rejected it — and the failure surfaced one command later, as
#
#     NoSuchEntity: Policy arn:aws:iam::…:policy/infra-ci-live-tests
#     does not exist or is not attachable
#
# from the *attach* step, which names neither the real problem nor the file.
# JSON has no comments and IAM has no comment field, so prose about the policy
# belongs in `ci/README.md`; this check is what stops it drifting back into the
# document.
#
# It is a grammar check, not an authorisation review. For the latter:
#
#     aws accessanalyzer validate-policy \
#       --policy-document file://ci/aws-permissions-policy.json \
#       --policy-type IDENTITY_POLICY
#
# Bash and jq rather than Python, so that `ci/` is one language. jq is
# pre-installed on both runner images this workflow uses (ubuntu-24.04 ships
# 1.7, macos-15 ships 1.8.2), and is checked for below rather than assumed —
# a missing interpreter should say so, not produce an empty report that looks
# like a pass.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required by this check and was not found on PATH." >&2
  echo "  It is pre-installed on GitHub's runners; locally, 'brew install jq'" >&2
  echo "  or 'apt-get install jq'." >&2
  exit 2
fi

# Both AWS policy documents in the repository: the CI role's inline grant, and
# the operator template `docs/permissions.md` tells a real user to adapt. The
# template carries REGION/ACCOUNT/PREFIX placeholders, which live in `Resource`
# strings and so do not affect the grammar — but its actions and Sids are
# checked exactly like the real one's, because a template that IAM would reject
# is worse than no template.
PATHS=("ci/aws-permissions-policy.json" "docs/aws-operator-policy.json")

# One jq program, emitting one error string per line and nothing on success.
# Written as a filter rather than as a series of `jq -e` calls so that a
# document with three problems reports three, which is what makes a fix one
# round trip instead of three.
read -r -d '' PROGRAM <<'JQ' || true
def top: ["Version", "Id", "Statement"];
def stmt: ["Sid", "Effect", "Action", "NotAction", "Resource", "NotResource",
           "Condition", "Principal", "NotPrincipal"];
def actions: if (.Action | type) == "string" then [.Action]
             elif (.Action | type) == "array" then .Action
             else [] end;
# Rendered as a plain comma-separated list rather than as JSON. The reader is
# being told which *keys* are wrong, and `Comment` reads better than
# `["Comment"]` in the middle of an English sentence.
def names: sort | join(", ");

[
  ( [keys_unsorted[] | select(IN(top[]) | not)]
    | select(length > 0)
    | "top-level key(s) IAM does not accept: \(names) (only \(top|names) are allowed — a comment cannot go here)" ),

  ( select(.Version != "2012-10-17")
    | "Version should be \"2012-10-17\", found \(.Version|tojson)" ),

  ( select((.Statement | type) != "array" or (.Statement | length) == 0)
    | "Statement must be a non-empty list" ),

  # Guarded on `Statement` really being an array of objects. Without the
  # guard a `Statement` that is an object — a plausible hand-edit, since one
  # statement looks like it should not need a list — made this crash inside
  # jq, and the crash was then reported as "is not valid JSON", which is both
  # wrong and unfixable-looking. The Python version this replaces raised an
  # AttributeError on the same input.
  ( (if (.Statement | type) == "array" then .Statement else [] end)
    | to_entries[]
    | .key as $i | .value as $s
    | if ($s | type) != "object" then
        "statement \($i): must be an object, found \($s | type)"
      else
        ($s.Sid // "statement \($i)") as $where
        | (
            ( [$s | keys_unsorted[] | select(IN(stmt[]) | not)]
              | select(length > 0)
              | "\($where): key(s) IAM does not accept: \(names)" ),
            ( select(($s.Effect // "") | IN("Allow", "Deny") | not)
              | "\($where): Effect must be Allow or Deny" ),
            ( select(($s | has("Action")) or ($s | has("NotAction")) | not)
              | "\($where): needs Action or NotAction" ),
            ( select(($s | has("Resource")) or ($s | has("NotResource")) | not)
              | "\($where): needs Resource or NotResource" ),
            ( select(($s | has("Sid")) and (($s.Sid | tostring) | test("^[A-Za-z0-9]+$") | not))
              | "\($where): Sid must be alphanumeric, found \($s.Sid|tojson)" ),
            ( $s | actions[]
              | select(test("^[a-z0-9-]+:[A-Za-z0-9*]+$") | not)
              | "\($where): \(tojson) is not a service:Action pair" )
          )
      end ),

  # Duplicate Sids, which need a pass over all the statements at once rather
  # than a per-statement check.
  ( (if (.Statement | type) == "array" then .Statement else [] end)
    | map(select(type == "object") | .Sid | select(. != null))
    | group_by(.)[] | select(length > 1)
    | "\(.[0]): duplicate Sid" )
] | .[]
JQ

fail=0
for path in "${PATHS[@]}"; do
  if ! errors=$(jq -r "$PROGRAM" "$path" 2>&1); then
    echo "error: $path is not valid JSON:" >&2
    echo "  $errors" >&2
    fail=1
    continue
  fi
  if [ -n "$errors" ]; then
    echo "error: $path would be rejected by IAM:" >&2
    while IFS= read -r e; do echo "  - $e" >&2; done <<< "$errors"
    fail=1
    continue
  fi
  count=$(jq '.Statement | length' "$path")
  echo "$path: conforms to IAM's policy grammar ($count statements)"
done

exit "$fail"
