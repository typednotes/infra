# CI policy documents

The IAM policies the live-test workflow's AWS role uses, kept as files so the
commands in [`../docs/ci-auth.md`](../docs/ci-auth.md) are runnable rather than
illustrative, and so a change to them shows up in a diff.

- `aws-trust-policy.json` — **who may assume the role.** The `sub` condition is
  the security boundary: without it, any GitHub repository could. Scoped to
  `repo:typednotes/infra:*`.
- `aws-trust-policy-environment.json` — the tighter variant, pinning `sub` to
  a GitHub *environment* rather than any branch. Stronger, because an
  environment can require reviewers and a branch cannot. Needs
  `environment: production` on the job as well; the policy alone rejects
  every run.
- `aws-permissions-policy.json` — **what the role may do.** Only the SQS calls
  the live test makes, and only against queues named `ci-tests-infra-*`. The
  one exception is `ListQueues`, which AWS does not allow to be
  resource-scoped, so the role can see every queue name in the account and
  modify none but its own.

**Note this project attaches `PowerUserAccess` rather than the least-privilege
policy above.** The reasoning is in the guide: it excludes IAM, so a
compromised run cannot grant itself persistence or widen its own access, and
the compensating control for the rest is restricting *who may assume the role*
rather than what it can do. `aws-permissions-policy.json` remains here as the
least-privilege alternative, and as documentation of what the live test
actually needs.

Both subjects carry **immutable owner and repository IDs**
(`typednotes@192230886/infra@1342807595`) rather than plain names, because that
is what GitHub actually issues for this repository — see the guide. A policy
written from the documentation's `repo:owner/name` example is an exact-string
mismatch and fails with an error that mentions neither subjects nor names.

None of these contains a secret. An account id appears in every ARN, and the
owner and repository IDs are public.

GCP's equivalent is not here because `gcloud` takes those conditions as command
arguments rather than documents; the commands are in the same guide.
