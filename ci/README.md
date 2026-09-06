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

## Upgrading the CI permissions for the extended live tests

The live legs went from one kind to nine, and neither identity was allowed to
do the extra work. Each leg will fail with the cloud's own permission error
until this is granted — which is the right failure, but it is not a bug in the
library and it is worth not spending an afternoon on.

Everything below is scoped to `ci-tests-infra-*` wherever the cloud lets a
permission name a resource. Where it does not — every *listing* call, on all
three clouds — the grant is read-only and account-wide, because that is the
only shape available.

### AWS

`ci/aws-permissions-policy.json` in this repository is the policy document. It
is scoped to `ci-tests-infra-*` wherever the API lets a permission name a
resource; the listing actions in the last statement cannot be scoped, and are
read-only.

That note lives here rather than in the file because **an IAM policy document
cannot carry a comment.** The grammar admits only `Version`, `Id` and
`Statement`, JSON has no comments, and a `"Comment"` key makes
`create-policy` fail — which then surfaces one command later as
`NoSuchEntity … does not exist or is not attachable` from the *attach* step,
naming neither the cause nor the file. `ci/check-aws-policy.py` runs in CI to
stop that recurring.

Apply it as a managed policy on `infra-ci`:

```sh
# As a managed policy (recommended: versioned, and detachable in one step)
aws iam create-policy \
  --policy-name infra-ci-live-tests \
  --policy-document file://ci/aws-permissions-policy.json

aws iam attach-role-policy \
  --role-name infra-ci \
  --policy-arn arn:aws:iam::616568506952:policy/infra-ci-live-tests

# Later, to update it in place
aws iam create-policy-version \
  --policy-arn arn:aws:iam::616568506952:policy/infra-ci-live-tests \
  --policy-document file://ci/aws-permissions-policy.json \
  --set-as-default
```

If `PowerUserAccess` is attached instead, note what it does **not** cover:
`PowerUserAccess` explicitly denies almost all of IAM, so the `iam` resource in
the live fleet will fail under it. Either attach the policy above alongside it,
or drop `resource iam` from `awsLive` in `test/Live.lean`.

To check what is actually attached:

```sh
aws iam list-attached-role-policies --role-name infra-ci
aws iam list-role-policies --role-name infra-ci          # inline policies
```

**If `attach-role-policy` says the policy does not exist**, the `create-policy`
before it failed — attach reports only that the ARN is absent, not why. Run the
create on its own and read its error; `MalformedPolicyDocument` means the
document, not the role. Two ways to check the document before sending it:

```sh
./ci/check-aws-policy.py                    # grammar, offline, no credentials

aws accessanalyzer validate-policy \
  --policy-document file://ci/aws-permissions-policy.json \
  --policy-type IDENTITY_POLICY              # AWS's own validator
```

An alternative to the managed policy, which avoids the two-step entirely: put
it inline on the role, where there is nothing to attach afterwards.

```sh
aws iam put-role-policy --role-name infra-ci \
  --policy-name infra-ci-live-tests \
  --policy-document file://ci/aws-permissions-policy.json
```

### Google Cloud

Google needs **two** things, and a role alone is not enough. Each API must be
*enabled on the project* before anything can call it, which is a separate act
from granting permission to call it — and it fails with its own error:

    HTTP 403 PERMISSION_DENIED: Secret Manager API has not been used in
    project typednotes before or it is disabled.

That is not a missing role. Enable the services the live fleet touches:

```sh
gcloud services enable --project=typednotes \
  pubsub.googleapis.com \
  secretmanager.googleapis.com \
  storage.googleapis.com \
  artifactregistry.googleapis.com \
  run.googleapis.com \
  iam.googleapis.com \
  cloudresourcemanager.googleapis.com
```

`cloudresourcemanager` is there for `Gcp.Iam.readPolicies`, which reads the
project's IAM policy to report the roles bound to a service account. That one
degrades to `unknown` rather than failing if it is unavailable, so it is the
only optional entry.

`sqladmin.googleapis.com` is deliberately absent: `postgres` is not in the live
fleet, and enabling an API is not free of consequence — it widens what a
compromised credential could reach.

To see what is already on:

```sh
gcloud services list --enabled --project=typednotes
```

Then the roles. `infra-ci@typednotes.iam.gserviceaccount.com` holds
`roles/pubsub.editor`,
which covers `queues` and nothing else. The remaining four kinds need one role
each. These are **project-level** grants, which is broader than the AWS policy
above — Google's predefined roles are not resource-scoped, and writing a custom
role for this is a larger job than the test justifies:

```sh
PROJECT=typednotes
SA=infra-ci@typednotes.iam.gserviceaccount.com

for ROLE in \
  roles/pubsub.editor \
  roles/secretmanager.admin \
  roles/artifactregistry.admin \
  roles/storage.admin \
  roles/iam.serviceAccountAdmin \
  roles/run.admin
do
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:$SA" --role="$ROLE" --condition=None
done
```

What each is for:

| Role | Kind |
|---|---|
| `roles/pubsub.editor` | `queues` |
| `roles/secretmanager.admin` | `secrets` — including *reading* a value, which the composed secrets do |
| `roles/artifactregistry.admin` | `imageRegistry` |
| `roles/storage.admin` | `objectStore` |
| `roles/iam.serviceAccountAdmin` | `iam` |
| `roles/run.admin` | `compute` |

**This table is derived from `test/Live.lean`, and it went stale once already**
— `roles/run.admin` was missing after `compute` joined the GCP fleet, and the
first live run said so:

    HTTP 403 PERMISSION_DENIED: Permission 'run.services.list' denied on
    resource 'projects/typednotes/locations/europe-west9/services'

Adding a kind to a live fleet means adding its permission here. The kinds each
fleet declares, as of 0.4.0:

| Cloud | Kinds in the live fleet |
|---|---|
| AWS | `iam`, `imageRegistry`, `objectStore`, `queues`, `s3Bucket`, `secrets`, `securityGroup` |
| Scaleway | the same minus `s3Bucket`/`securityGroup`, plus `scalewayContainer`, `scalewayContainerNamespace`, `scalewayFunctionNamespace` |
| GCP | `compute`, `iam`, `imageRegistry`, `objectStore`, `queues`, `secrets` |

One permission is easy to miss because no resource names it: the fleets contain
two **composed** secrets, whose values are built from a base secret's value at
settle time. That is a *read* of a secret, so every cloud needs read as well as
write — on AWS it is `secretsmanager:GetSecretValue`, which was missing from
the policy for the same reason.

Two not on that list, deliberately. `roles/cloudsql.admin` is not granted
because `postgres` is not in the live fleet — it takes longer to create than
the workflow's step timeout. And nothing grants
`resourcemanager.projects.setIamPolicy`: `Gcp.Iam` refuses to write policy
bindings by design, so the permission would be unused, and granting the ability
to rewrite a project's IAM policy to a CI identity is not something to do for
an unused code path.

`Gcp.Iam.readPolicies` does read the project policy, and degrades to `unknown`
rather than failing if it may not — so `roles/browser` or
`roles/iam.securityReviewer` is optional and only makes `plan` more
informative.

#### And one grant that is not a role

Deploying a Cloud Run service as an identity requires
`iam.serviceAccounts.actAs` **on that identity**, which is not implied by
`roles/run.admin`. Without it:

    PERMISSION_DENIED: Permission 'iam.serviceaccounts.actAs' denied on
    service account …@… (or it may not exist)

The live fleet names `infra-ci` as its own Cloud Run runtime identity, so the
grant is `infra-ci` being allowed to act as itself:

```sh
gcloud iam service-accounts add-iam-policy-binding \
  infra-ci@typednotes.iam.gserviceaccount.com \
  --member=serviceAccount:infra-ci@typednotes.iam.gserviceaccount.com \
  --role=roles/iam.serviceAccountUser \
  --project=typednotes
```

It names an identity deliberately. A Cloud Run service with none runs as the
project's **default compute service account**, which Google grants
`roles/editor` — so a declaration silent about identity gets an Editor on the
whole project. `infra` warns when `executionRole` is unset for exactly that
reason, and the test names one rather than enshrining the default as the
example.

To check what is granted:

```sh
gcloud projects get-iam-policy typednotes \
  --flatten="bindings[].members" \
  --filter="bindings.members:infra-ci@typednotes.iam.gserviceaccount.com" \
  --format="table(bindings.role)"
```

### Scaleway

Scaleway grants permission *sets* to an IAM application through a policy, and
they are coarse — one per product family:

```sh
ORG=$(scw config get default-organization-id)
APP_ID=<the application id whose API key CI uses>

scw iam policy create \
  name=infra-ci-live-tests \
  application-id="$APP_ID" \
  rules.0.organization-id="$ORG" \
  rules.0.permission-set-names.0=MessagingAndQueuingFullAccess \
  rules.1.organization-id="$ORG" \
  rules.1.permission-set-names.0=SecretManagerFullAccess \
  rules.2.organization-id="$ORG" \
  rules.2.permission-set-names.0=ContainerRegistryFullAccess \
  rules.3.organization-id="$ORG" \
  rules.3.permission-set-names.0=ObjectStorageFullAccess \
  rules.4.organization-id="$ORG" \
  rules.4.permission-set-names.0=IAMManager \
  rules.5.organization-id="$ORG" \
  rules.5.permission-set-names.0=FunctionsFullAccess \
  rules.6.organization-id="$ORG" \
  rules.6.permission-set-names.0=ContainersFullAccess
```

`MessagingAndQueuingFullAccess` is the one already needed, and note it covers
more than the queue itself: minting the dedicated SQS credential is an IAM-ish
operation on the Queues product, which is why the reclaim path in
`Scaleway.Sqs` needs it too.

`IAMManager` is the coarse one and the one to think about — it is what lets the
`iam` resource create and delete an application, and Scaleway has no
narrower set for that. Dropping `resource iam` from `scalewayLive` is the
alternative.

To see what an application currently has:

```sh
scw iam policy list application-id="$APP_ID"
scw iam permission-set list
```
