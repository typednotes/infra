# CI authentication

How the live-test workflow gets credentials, and how to set it up in a fresh
account. The goal for both clouds is the same: **no long-lived key stored
anywhere**. The CI platform vouches for the job, the cloud trades that for a
short-lived token, and there is nothing to leak, rotate, or revoke in a hurry.

Scaleway is the exception and has no federation, so it keeps a scoped API key.

Everything below was set up for real in `typednotes` (GCP) and is written out
for AWS; the values are this project's and are not secrets — an AWS account id
appears in every ARN, and a GCP project number in every resource name.

## The shape of it

Two independent narrowings on each cloud, because one is not enough:

| | AWS | GCP |
|---|---|---|
| Trust the platform | an IAM OIDC provider for `token.actions.githubusercontent.com` | a workload identity pool provider for the same issuer |
| Narrow to us | the role's trust policy, on `sub` | the provider's `attribute-condition`, on `repository_owner` |
| Narrow to one repo | the same `sub` condition | the service account's own IAM policy |
| Grant anything | a permissions policy | a project role binding |

The last row is deliberately separate from the rest. Federation without
authorisation is inert and safe, and it is worth confirming it works before
granting anything.

## AWS

### 1. The OIDC provider (once per account)

```sh
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

The thumbprint is still a required parameter, and AWS no longer uses it to
validate this particular issuer — it secures the connection to well-known
providers through its own trust store. The console's guided flow does not ask
for one at all. Pass it, do not worry about keeping it current.

If the provider already exists, this fails with `EntityAlreadyExists`, which is
fine — there is one per account and it is shared by every role.

### 2. The trust policy

This is the security boundary. **`sub` is the line that matters**: with only
the `aud` condition, any GitHub repository in the world could assume the role.

`ci/aws-trust-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::616568506952:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:typednotes/infra:*"
      }
    }
  }]
}
```

`repo:typednotes/infra:*` allows any branch and any workflow in that one
repository, which is what a `workflow_dispatch` job needs. To tighten it,
replace the `StringLike` with a `StringEquals` on one of:

- `repo:typednotes/infra:ref:refs/heads/main` — only from `main`
- `repo:typednotes/infra:environment:production` — only from jobs that declare
  that environment, which is also where required reviewers live

The second is the stronger of the two, because a branch can be created by
anyone who can push and an environment gate cannot.

### 3. The permissions policy

Only what the live test does: create a queue, read it, delete it. Scoped to the
`ci-tests-infra-` prefix, so this role cannot touch a real queue.

`ci/aws-permissions-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ManageTestQueuesOnly",
      "Effect": "Allow",
      "Action": [
        "sqs:CreateQueue",
        "sqs:DeleteQueue",
        "sqs:GetQueueUrl",
        "sqs:GetQueueAttributes",
        "sqs:SetQueueAttributes",
        "sqs:TagQueue"
      ],
      "Resource": "arn:aws:sqs:eu-west-1:616568506952:ci-tests-infra-*"
    },
    {
      "Sid": "ListingCannotBeScoped",
      "Effect": "Allow",
      "Action": "sqs:ListQueues",
      "Resource": "*"
    }
  ]
}
```

`ListQueues` is not a resource-level action, so it cannot be narrowed — the
role can *see* every queue name in the account and modify none but its own.
That is the tightest this gets, and it is worth knowing rather than assuming
the prefix confines everything.

### 4. Create the role and attach

```sh
aws iam create-role \
  --role-name infra-ci \
  --description "Assumed by GitHub Actions in typednotes/infra via OIDC" \
  --assume-role-policy-document file://ci/aws-trust-policy.json \
  --max-session-duration 3600

aws iam put-role-policy \
  --role-name infra-ci \
  --policy-name infra-ci-live-test \
  --policy-document file://ci/aws-permissions-policy.json
```

An inline policy rather than a managed one: it belongs to this role, is deleted
with it, and cannot be attached to something else by accident.

### 5. Point the workflow at it

Set a repository **variable** — not a secret, because a role ARN is not one:

```
AWS_ROLE_ARN = arn:aws:iam::616568506952:role/infra-ci
```

The workflow already has `permissions: id-token: write`, which is what allows
GitHub to mint the token in the first place, and
`aws-actions/configure-aws-credentials` exports the three variables the
credential chain reads.

### 6. Verify

```sh
aws iam get-role --role-name infra-ci \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition' --output json
```

The `sub` condition should name `typednotes/infra`. If it says only `aud`, stop
and fix it — the role is assumable by anyone.

## GCP

Already set up in `typednotes`. For the record, and to redo it elsewhere:

```sh
gcloud services enable iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com

gcloud iam workload-identity-pools create github --location=global \
  --display-name="GitHub Actions"

gcloud iam workload-identity-pools providers create-oidc github-provider \
  --location=global --workload-identity-pool=github \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner,attribute.ref=assertion.ref" \
  --attribute-condition="assertion.repository_owner == 'typednotes'"

gcloud iam service-accounts create infra-ci --display-name="infra CI"

gcloud iam service-accounts add-iam-policy-binding \
  infra-ci@typednotes.iam.gserviceaccount.com \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/113928363564/locations/global/workloadIdentityPools/github/attribute.repository/typednotes/infra"

# Only what the live test needs. Widen as backends land, not before.
gcloud projects add-iam-policy-binding typednotes \
  --member="serviceAccount:infra-ci@typednotes.iam.gserviceaccount.com" \
  --role="roles/pubsub.editor"
```

The `attribute-condition` is the equivalent of AWS's `sub` condition and is
equally load-bearing: without it the provider trusts every token GitHub issues,
from any repository.

Note the asymmetry with AWS. GCP's condition is on the *org* and the
per-repository narrowing lives on the service account, whereas AWS puts both on
the role's trust policy. Either is fine; what matters is that both layers exist.

## Scaleway

No federation exists, so a scoped API key is the only option. Keep it
**project-scoped rather than organization-scoped**, and set
`SCW_ACCESS_KEY`, `SCW_SECRET_KEY` and `SCW_DEFAULT_PROJECT_ID` as repository
secrets.

## What is deliberately not here

**A key file for GCP.** `Infra.Core.GcpAuth` can read a service-account JSON
key and mint its own token, and that is the right answer for a long-running
process on a machine that cannot federate. It is the wrong answer for CI, where
federation is available and a key file is a long-lived secret sitting in a
variable. See `docs/authentication.md`.
