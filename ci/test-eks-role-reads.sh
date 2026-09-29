#!/usr/bin/env bash
# Exercise the preflight against both existing and absent service-linked
# roles, and failures that must never be mistaken for authorised absence.
set -euo pipefail
cd "$(dirname "$0")/.."

aws() {
  local operation="${2:-}" role="${4:-}"
  case "$1/$operation" in
    iam/get-role|iam/list-attached-role-policies) ;;
    *) echo "unexpected AWS operation: $*" >&2; return 99 ;;
  esac
  case "$SCENARIO/$operation/$role" in
    cold/get-role/AWSServiceRoleForAmazonEKS*)
      echo 'An error occurred (NoSuchEntity) when calling the GetRole operation' >&2
      return 254 ;;
    denied/get-role/AWSServiceRoleForAmazonEKSNodegroup)
      echo 'An error occurred (AccessDenied) when calling the GetRole operation' >&2
      return 254 ;;
    missing/get-role/ci-tests-infra-eks-nodes)
      echo 'An error occurred (NoSuchEntity) when calling the GetRole operation' >&2
      return 254 ;;
    policies/list-attached-role-policies/ci-tests-infra-eks-nodes)
      echo 'An error occurred (AccessDenied) when calling the ListAttachedRolePolicies operation' >&2
      return 254 ;;
    transport/get-role/AWSServiceRoleForAmazonEKSNodegroup)
      echo 'Could not connect to the endpoint URL' >&2
      return 255 ;;
  esac
  return 0
}
export -f aws

for scenario in existing cold denied missing policies transport; do
  status=0
  output=$(SCENARIO="$scenario" bash ci/check-eks-role-reads.sh 2>&1) || status=$?
  case "$scenario" in
    existing|cold) expected=0 ;;
    *) expected=1 ;;
  esac
  if [ "$status" -ne "$expected" ]; then
    echo "error: EKS preflight $scenario returned $status, expected $expected: $output" >&2
    exit 1
  fi
  if [ "$scenario" = cold ] && [[ "$output" != *"authorised; EKS will create it on first use"* ]]; then
    echo "error: EKS preflight did not recognise authorised first-use absence" >&2
    exit 1
  fi
done
echo "EKS role-read preflight: existing/cold-start roles pass; access denied, missing prerequisites, policy-read and transport failures stop the run"
