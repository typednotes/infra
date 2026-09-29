#!/usr/bin/env bash
# Read-only preflight for the AWS Kubernetes live leg. Check the calls EKS
# makes as the caller before spending minutes provisioning a control plane.
# This checks role reads, not every permission required to create a cluster.
set -euo pipefail

if ! command -v aws >/dev/null 2>&1; then
  echo "error: aws CLI is required for the EKS role-read preflight." >&2
  exit 2
fi

export AWS_PAGER=""
for role in ci-tests-infra-eks-cluster ci-tests-infra-eks-nodes \
    AWSServiceRoleForAmazonEKS AWSServiceRoleForAmazonEKSNodegroup; do
  if reply=$(aws iam get-role --role-name "$role" --output json 2>&1); then
    echo "ok: iam:GetRole on $role"
  elif [[ "$role" == AWSServiceRoleForAmazonEKS || "$role" == AWSServiceRoleForAmazonEKSNodegroup ]] \
      && [[ "$reply" == *"(NoSuchEntity)"* ]]; then
    # Not-found is the authorised, first-use result. EKS creates its own
    # service-linked roles; the two declared roles must already exist.
    echo "ok: iam:GetRole on $role authorised; EKS will create it on first use"
  else
    echo "error: EKS role-read preflight failed for $role: $reply" >&2
    exit 1
  fi
done

for role in ci-tests-infra-eks-cluster ci-tests-infra-eks-nodes; do
  if reply=$(aws iam list-attached-role-policies --role-name "$role" --output json 2>&1); then
    echo "ok: iam:ListAttachedRolePolicies on $role"
  else
    echo "error: EKS role-policy-read preflight failed for $role: $reply" >&2
    exit 1
  fi
done
