# CI policy documents

The IAM policies the live-test workflow's AWS role uses, kept as files so the
commands in [`../docs/ci-auth.md`](../docs/ci-auth.md) are runnable rather than
illustrative, and so a change to them shows up in a diff.

- `aws-trust-policy.json` — **who may assume the role.** The `sub` condition is
  the security boundary: without it, any GitHub repository could. Scoped to
  `repo:typednotes/infra:*`.
- `aws-permissions-policy.json` — **what the role may do.** Only the SQS calls
  the live test makes, and only against queues named `ci-tests-infra-*`. The
  one exception is `ListQueues`, which AWS does not allow to be
  resource-scoped, so the role can see every queue name in the account and
  modify none but its own.

Neither contains a secret. An account id appears in every ARN.

GCP's equivalent is not here because `gcloud` takes those conditions as command
arguments rather than documents; the commands are in the same guide.
