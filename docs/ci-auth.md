# CI authentication

How the live-test workflow gets credentials, and how to set it up in a fresh
account. The goal for both clouds is the same: **no long-lived key stored
anywhere**. The CI platform vouches for the job, the cloud trades that for a
short-lived token, and there is nothing to leak, rotate, or revoke in a hurry.

Scaleway is the exception and has no federation, so it keeps a scoped API key.

Everything below was set up for real in `typednotes` (GCP) and is written out
for AWS; the values are this project's and are not secrets — an AWS account id
appears in every ARN, and a GCP project number in every resource name.

## How the exchange actually works

Both clouds do the same thing in the same order — GitHub vouches for the job,
the cloud checks the claim against conditions you set, and hands back something
short-lived. They differ in how many hops it takes and where the conditions
live.

### AWS: one hop

```
  ┌──────────────────────┐
  │  GitHub Actions job  │   typednotes/infra, workflow_dispatch
  └──────────┬───────────┘
             │ 1. "give me an OIDC token for aud=sts.amazonaws.com"
             │    (needs  permissions: id-token: write)
             ▼
  ┌──────────────────────┐
  │  GitHub OIDC issuer  │   token.actions.githubusercontent.com
  └──────────┬───────────┘
             │ 2. a signed JWT whose claims say who the job is:
             │
             │       iss  token.actions.githubusercontent.com
             │       aud  sts.amazonaws.com
             │       sub  repo:typednotes/infra:ref:refs/heads/main
             │
             ▼
  ┌──────────────────────┐
  │  job calls AWS STS   │   sts:AssumeRoleWithWebIdentity
  │  with the JWT + the  │   RoleArn = arn:aws:iam::616568506952:role/infra-ci
  │  role ARN            │
  └──────────┬───────────┘
             │ 3. AWS verifies the signature against the IAM OIDC provider
             │    registered for that issuer, then evaluates the ROLE'S
             │    TRUST POLICY:
             │
             │       aud == sts.amazonaws.com          ← anyone gets this
             │       sub LIKE repo:typednotes/infra:*  ← THIS is the boundary
             │                                     ↑
             │                 without it, any repo on GitHub passes
             ▼
  ┌──────────────────────┐
  │  temporary creds     │   AccessKeyId + SecretAccessKey + SessionToken,
  │  for role infra-ci   │   expiring in an hour
  └──────────┬───────────┘
             │ 4. exported into the environment
             ▼
       `infra` reads them through its ordinary credential chain and
       signs SigV4 exactly as it would with a static key. Nothing
       below `Infra.Cli` knows the difference.
```

What the role may *do* is a separate document
(`ci/aws-permissions-policy.json`) and a separate question from who may
assume it. Both conditions live on the role.

### GCP: two hops

GCP splits it, because the pool identity and the service account are different
things. The federated identity cannot call APIs itself; it can only ask to
*impersonate* a service account, and that is a second permission.

```
  ┌──────────────────────┐
  │  GitHub Actions job  │
  └──────────┬───────────┘
             │ 1. OIDC token, same as above but aud = the provider
             ▼
  ┌──────────────────────┐
  │  GitHub OIDC issuer  │
  └──────────┬───────────┘
             │ 2.  sub                 repo:typednotes/infra:...
             │     repository          typednotes/infra
             │     repository_owner    typednotes
             ▼
  ┌──────────────────────────────────────────────┐
  │  GCP STS — sts.googleapis.com                │
  │  pool `github`, provider `github-provider`   │
  └──────────┬───────────────────────────────────┘
             │ 3. verifies the issuer, then evaluates the PROVIDER'S
             │    attribute-condition:
             │
             │       assertion.repository_owner == 'typednotes'
             │                    ↑  narrowing #1 — the org
             │
             │    and maps claims onto attributes IAM can match on:
             │       assertion.repository  →  attribute.repository
             ▼
  ┌──────────────────────┐
  │  a federated token   │   principalSet://…/attribute.repository/
  │  — cannot call any   │              typednotes/infra
  │    API on its own    │
  └──────────┬───────────┘
             │ 4. asks to impersonate the service account
             │    (iamcredentials.generateAccessToken)
             ▼
  ┌──────────────────────────────────────────────┐
  │  service account infra-ci                    │
  │  its IAM policy says who may impersonate it: │
  │                                              │
  │    roles/iam.workloadIdentityUser to         │
  │    principalSet://…/typednotes/infra         │
  │                 ↑  narrowing #2 — the repo   │
  └──────────┬───────────────────────────────────┘
             │ 5. an OAuth2 access token for infra-ci, ~1 hour
             ▼
       exported as GOOGLE_OAUTH_ACCESS_TOKEN; `infra` sends it as
       `Authorization: Bearer …`. Same place a `gcloud` token or a
       service-account key would have landed.
```

What `infra-ci` may *do* is a third thing again — a project role binding
(`roles/pubsub.editor`) — and is why steps 3 and 4 can both succeed while every
API call still returns 403.

The asymmetry is the thing to remember when moving between them: **AWS puts
both narrowings in one document; GCP puts them in two different places**, and
it is easy to set up one and believe you have set up both.

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

### What this project actually grants

`PowerUserAccess`, not the least-privilege policy above, and not
`AdministratorAccess`:

```sh
aws iam attach-role-policy --role-name infra-ci \
  --policy-arn arn:aws:iam::aws:policy/PowerUserAccess
```

The reasoning, so the trade is visible rather than implied. The live test needs
six SQS calls; `PowerUserAccess` is far more than that, and the reason to take
it anyway is that the next backend to be exercised live will need something
else, and widening a policy per product is friction that ends with someone
reaching for `AdministratorAccess` instead.

What it buys over `AdministratorAccess` is the thing that matters most:
**`PowerUserAccess` excludes IAM.** A compromised run can create and destroy
resources — which is expensive — but cannot grant itself a role, create a user,
or alter the trust policy that let it in. It cannot make itself persistent, and
it cannot quietly widen its own access. The blast radius is bounded and
recoverable; with admin it is neither.

What it does not buy: a run that can still delete production data. So the
compensating control is on the *other* side of the trust boundary — restrict
who can assume the role, rather than what the role can do.

### Gating on an environment — this is what the workflow does

`.github/workflows/live-test.yml` declares `environment: production`, so use
`ci/aws-trust-policy-environment.json` when creating the role. It replaces the
branch-agnostic `StringLike` with an exact match on a GitHub *environment*:

```json
"StringEquals": {
  "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
  "token.actions.githubusercontent.com:sub":
    "repo:typednotes/infra:environment:production"
}
```

An environment is stronger than a branch, because a branch can be created by
anyone who can push, while an environment can carry **required reviewers** — so
assuming the role needs a human to approve the run. That is what makes a broad
permissions policy defensible.

Both halves are needed and both are now in place. The workflow half is done;
the policy half is the document you pass to `create-role`.

Three things worth knowing about the ordering:

- **The permissive policy still works.** `repo:typednotes/infra:*` matches
  `repo:typednotes/infra:environment:production`, so a role created with
  `aws-trust-policy.json` keeps working — it simply no longer buys anything,
  since every run now carries the environment claim. Tighten it when
  convenient; nothing breaks either way.
- **GitHub creates the environment on first use** if it does not exist, with
  no protection rules. So the job will run, and the gate will be a gate in
  name only, until you add reviewers in *Settings → Environments →
  production*. **That step is the whole point** and is the one thing neither
  the workflow nor the policy can do for itself.
- **Removing `environment: production` from the job does not loosen the
  gate** — with the exact-match policy it breaks AWS authentication outright,
  because the `sub` claim changes. That is the failure mode to want.

### 5. Point the workflow at it

Set `AWS_ROLE_ARN`:

```
AWS_ROLE_ARN = arn:aws:iam::616568506952:role/infra-ci
```

A **variable** is the right home — an ARN is not a secret, it appears in every
policy document — but the workflow reads
`${{ vars.AWS_ROLE_ARN || secrets.AWS_ROLE_ARN }}`, so either works. That
fallback exists because putting it in the wrong namespace produces no error at
all: the action simply omits `role-to-assume`, falls back to looking for static
keys, and reports *"Could not load credentials from any providers"* — which
names neither the variable nor the fact that OIDC never happened. A guard step
now catches the empty case first and says which setting is missing.

The workflow already has `permissions: id-token: write`, which is what allows
GitHub to mint the token in the first place, and
`aws-actions/configure-aws-credentials` exports the three variables the
credential chain reads.

### If it fails with "the web identity token could not be validated"

That error is about the *token*, not the role, and it almost always means step
1 was skipped: **there is no IAM OIDC provider** for
`token.actions.githubusercontent.com` in the account, so AWS has nothing to
validate the signature against. Check:

```sh
aws iam list-open-id-connect-providers
aws iam get-open-id-connect-provider --open-id-connect-provider-arn \
  arn:aws:iam::616568506952:oidc-provider/token.actions.githubusercontent.com
```

The `ClientIDList` must contain `sts.amazonaws.com`, which is the audience the
action requests. A provider registered with a different client id validates
nothing.

Distinguish it from the neighbouring failures, which look similar and are not:

| Message | Means |
|---|---|
| `Could not load credentials from any providers` | `role-to-assume` was empty — the ARN setting is missing |
| `the web identity token could not be validated` | no OIDC provider, or an audience mismatch |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | provider fine; the **trust policy** rejected the claim |

The third is the one to expect if the `sub` condition and the workflow's
`environment:` disagree.

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
