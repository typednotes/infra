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
- `aws-permissions-policy.json` — **what the role may do.** Only the calls the
  live test makes, and only against resources named `ci-tests-infra-*`. The
  exceptions are the *listing* actions, which AWS does not allow to be
  resource-scoped, so the role can see every queue, bucket, instance and user
  name in the account and modify none but its own.

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
or drop `resource iam` from `awsFull` in `test/Live.lean`.

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
fleet declares, as of 0.10.0 — read off the `#guard`s at the foot of
`test/Live.lean`, which are what pin them:

| Cloud | Kinds in the live fleet |
|---|---|
| AWS | `awsInstance`, `iam`, `imageRegistry`, `objectStore`, `queues`, `s3Bucket`, `secrets`, `securityGroup` |
| Scaleway | `imageRegistry`, `objectStore`, `queues`, `scalewayContainer`, `scalewayContainerNamespace`, `scalewayFunction`, `scalewayFunctionNamespace`, `secrets` |
| GCP | `compute`, `iam`, `imageRegistry`, `objectStore`, `queues`, `secrets` |

`awsInstance` is the one that arrived after this table was first written, and
the policy did not follow it: `ec2:RunInstances`, `ec2:TerminateInstances`,
`ec2:ModifyInstanceAttribute` and the two describes (`ec2:DescribeInstances`
for the lister, `ec2:DescribeImages` for `imageId := "latest"`) are in the
document now.

A second one is easy to miss because it is not in any declaration at all: the
**ownership marker**. Every AWS kind that can carry a tag has it written at
create and read back on the next `push` (`Infra/Core/Ownership.lean`), so each
one needs *two* permissions beyond the create and the delete — one to tag, one
to read tags. On AWS that is `sqs:TagQueue`/`sqs:ListQueueTags`,
`secretsmanager:TagResource` (`DescribeSecret` carries the tags back),
`s3:PutBucketTagging`/`s3:GetBucketTagging`, `ec2:CreateTags`
(`DescribeSecurityGroups`/`DescribeInstances` carry them back) and
`iam:TagUser`/`iam:ListUserTags`.

Missing the *write* half fails loudly, which is how `iam:TagUser` was found:

    CREATE aws/iam/ci-tests-infra-user failed: iam POST iam.amazonaws.com/:
    HTTP 403 AccessDenied: … is not authorized to perform: iam:TagUser …

Missing the *read* half is worse, because it is quiet. `readOwnership` reports
`none` when the call fails, which the engine reads as "this cloud cannot answer"
and falls back to the ledger — so the ownership perimeter silently stops being
enforced for that kind rather than failing. `sqs:ListQueueTags` and
`iam:ListUserTags` were both absent for that reason.

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

#### Run CI in its own project

The live fleet creates and destroys real resources, and a credential that can
do that in the project holding production is a credential worth not having. So
CI gets its own project — `Typednotes CI` — and its permissions are scoped to
that project alone.

CI has **its own project and its own application**, so its credential can
reach neither production resources nor any identity:

| | |
|---|---|
| Project | `Typednotes CI` — `93e968f6-3d1e-4f28-ac82-b7ed6b4b6658` |
| Application | `Typednotes-CI` — `b9037b93-b20f-4cce-b02b-5b03bf5ec603` |

A dedicated **application** matters as much as the project. Before this, CI
authenticated with a *user* API key, which inherits the user's own rights —
org-wide, every project — so an isolated project would have bought nothing.
The tell was that CI created resources in the `default` project while no
application held any permission there.

```sh
CI=93e968f6-3d1e-4f28-ac82-b7ed6b4b6658
APP=b9037b93-b20f-4cce-b02b-5b03bf5ec603

# The key. Its secret is shown ONCE — put it straight into the repository
# secrets and nowhere else.
scw iam api-key create application-id="$APP" \
  description="GitHub Actions live tests" \
  default-project-id="$CI"

# Product permissions, confined to the CI project. No IAM permission sets:
# `resource iam` is dropped from `scalewayFull`, so CI needs no
# organization-level rights at all.
scw iam policy create name=infra-ci-live-tests application-id="$APP" \
  rules.0.project-ids.0="$CI" rules.0.permission-set-names.0=MessagingAndQueuingFullAccess \
  rules.1.project-ids.0="$CI" rules.1.permission-set-names.0=SecretManagerFullAccess \
  rules.2.project-ids.0="$CI" rules.2.permission-set-names.0=ContainerRegistryFullAccess \
  rules.3.project-ids.0="$CI" rules.3.permission-set-names.0=ObjectStorageFullAccess \
  rules.4.project-ids.0="$CI" rules.4.permission-set-names.0=FunctionsFullAccess \
  rules.5.project-ids.0="$CI" rules.5.permission-set-names.0=ContainersFullAccess
```

Then three repository secrets:

| Secret | Value |
|---|---|
| `SCW_ACCESS_KEY` | from `scw iam api-key create` |
| `SCW_SECRET_KEY` | from the same command — shown once, so capture it then |
| `SCW_DEFAULT_PROJECT_ID` | `93e968f6-3d1e-4f28-ac82-b7ed6b4b6658` |

`SCW_DEFAULT_ORGANIZATION_ID` is **not** required. Only `Iam.Scw` reads it, and
`resource iam` is out of `scalewayFull`. The workflow still passes it, so that
re-adding the kind does not also mean remembering this line.

`project-ids` rather than `organization-id` is the point: with the former, a
credential that goes wrong cannot reach anything outside the CI project.

**The policy above needs no organization-level rights, and that is deliberate.**
Scaleway's IAM applications live in the *organization*, not in a project, so
covering the `iam` kind would have meant granting CI org-wide IAM — which the
isolated project cannot contain, and which is the one grant that could reach
production identities.

So `resource iam` was **dropped from `scalewayFull`**. CI's Scaleway credential
now holds project-scoped product permissions and nothing else. A `#guard` in
`test/Live.lean` pins the absence, because adding the resource back would
silently re-introduce the requirement.

The kind is still covered live on AWS and GCP, where an identity is account- or
project-scoped and can be confined. If you ever want it on Scaleway too,
`IAMApplicationManager` at organization scope is the narrowest grant that
works — narrower than `IAMManager`, which also carries ProjectManager — but a
separate organization is the only thing that really isolates it.

#### The permission sets, and one trap



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

`IAMManager` is the coarse one, and there *is* a narrower set:
`IAMApplicationManager` covers applications alone, where `IAMManager` also
carries ProjectManager. Prefer the narrower one — or drop `resource iam` from
`scalewayFull` and grant no organization-level rights at all.

**A trap worth naming**, because it cost a round of debugging: a policy
attached to the wrong *application* is indistinguishable from no policy. The
403 names the call, not the identity. Check which application CI's key belongs
to before creating a policy:

```sh
scw iam api-key list          # shows application_id or user_id per key
scw iam application list      # names them
```

To see what an application currently has:

```sh
scw iam policy list application-id="$APP_ID"
scw iam permission-set list
```

## Running the live test

`.github/workflows/live-test.yml` is manual only. Nothing pushes to it: a job
that creates billable resources should be started by a person who meant to.

```sh
gh workflow run live-test.yml -f provider=aws    # aws | scaleway | gcp
gh run list --workflow=live-test.yml --limit 3
```

There is no `all` here, unlike the Cleanup workflow. Each fleet in
`test/Live.lean` is single-cloud and a run authenticates only the provider it
was given — the AWS leg never reads Scaleway's secrets, which falls out of
`Keys.providers` rather than out of the workflow's `if`s. Three clouds is three
runs.

The run then **waits for a review**, because it declares `environment:
production`; approve it as below. On AWS that environment is load-bearing
rather than procedural: the role's trust policy pins `sub` to
`repo:typednotes/infra:environment:production`, so removing the line does not
loosen the gate, it breaks OIDC entirely.

### Approving a run

Both this workflow and Cleanup stop here. In the Actions UI, or:

```sh
RUN=<the run id printed above>
# The environment id, and whether you are allowed to approve it
gh api "repos/typednotes/infra/actions/runs/$RUN/pending_deployments" \
  -q '.[] | "\(.environment.name) \(.environment.id) approvable=\(.current_user_can_approve)"'

gh api -X POST "repos/typednotes/infra/actions/runs/$RUN/pending_deployments" \
  -F 'environment_ids[]=<the id from above>' \
  -f state=approved -f comment='live test, aws'

gh run watch "$RUN" --exit-status
```

A reviewer cannot approve their own run in some configurations, which is what
`approvable=false` means when you are certain you are on the reviewer list.

### Reading the run

The driver flushes a progress line per stage, so a run in flight is legible
rather than an eight-minute silence:

```sh
gh run view "$RUN" --log | grep -E "applying|converged|outstanding|ok — all"
```

Five stages per cloud — `full`, `ramp-up`, `ramp-down`, `trimmed`, `empty` —
and each prints `[<cloud>/<stage>] applying (N declared, M managed)…` and then
`[<cloud>/<stage>] converged; M managed`. While a stage settles, a line every
fifteen seconds names what is still outstanding. The last stage declares
nothing, so a clean run ends `[aws] ok — all 5 stages` and leaves the account
empty; the `empty` stage *is* the teardown.

Before any of that the job builds, runs the offline suite, and checks that the
chosen provider's credentials are present — a missing repository secret fails
there, naming the variable, rather than later as an opaque 403. What those
credentials are and how they were provisioned is `docs/ci-auth.md`. The live
step is capped at sixteen minutes and the job at twenty, sized from the
driver's `settleSeconds := 180` polls plus create and delete of what stage 1
declares — twelve resources on AWS and Scaleway, ten on GCP, pinned by `#guard`
in `test/Live.lean`.

### Repeating a run

`concurrency: live-test-<provider>` queues a second run for the same cloud
rather than cancelling it, so two runs can never see each other's resources and
a run always reaches its teardown. What it does not impose is a *gap*, and AWS
needs one: SQS refuses to recreate a queue deleted less than sixty seconds ago.
Back-to-back AWS runs fail on create with an error saying exactly that. Wait a
minute between them.

A run that fails tears itself down: the backstop step calls `destroy` and then
`sweep`. A run that is cancelled, times out at the job level, or loses its
runner does not reach the backstop at all — that is the next section.

A run that *passes* checks the account itself, which it did not always: the
driver's last act is `assertAccountClean`, the sweep's listing without the
deletes, polled through the settle window. So a green leg means the cloud
reported no `ci-tests-infra-*` resource, not merely that the local ledger came
out empty — those are different claims, and 0.8.0 shipped a defect that
satisfied the second while leaving two whole estates standing.

## Cleaning up after a failed live run

A failed leg leaves the accounts in whatever state it died in. The workflow's
own backstop tears down and then sweeps, so most failures clean up after
themselves — but a job that is cancelled, times out, or loses its runner
does not run the backstop at all, and a resource nobody deleted keeps
billing quietly.

Two verbs, and picking the wrong one is why this section exists:

| | What it deletes | When it is the right one |
|---|---|---|
| `lake test -- <cloud> destroy` | what the **local ledger** records (`.infra/live-<cloud>/infra.ledger.json`) | on the machine that ran the apply, straight after it failed |
| `lake test -- <cloud> sweep` | every resource named `ci-tests-infra-*` the credentials can **list** | anywhere else, and always in CI |

The ledger is gitignored and does not survive a CI job, so a fresh runner asked
to `destroy` finds an empty ledger and deletes nothing however much is
standing. That is the whole reason `sweep` exists: it asks the account instead
of asking local state. Every resource the live fleets declare is named
`ci-tests-infra-*`, and a `#guard` in `test/Live.lean` holds that naming rule
precisely so a sweep can rely on it — `isDebris` is the only thing standing
between a sweep and somebody else's resources, which is why it is one function
used in one place.

### The normal route: the Cleanup workflow

`.github/workflows/cleanup.yml` sweeps with CI's own credentials, one job per
cloud, in the same concurrency group as that cloud's live test so a sweep can
never race the run whose resources it would delete. It also runs weekly on a
schedule, because debris costs money quietly.

```sh
gh workflow run cleanup.yml -f provider=all      # or: aws | scaleway | gcp
gh run list --workflow=cleanup.yml --limit 3
```

**The jobs then wait for a review**, because they carry `environment:
production` and that environment requires a reviewer. That gate is deliberate:
a sweep deletes without asking anything else. Approve it exactly as under
*Approving a run* above, then:

```sh
gh run watch "$RUN" --exit-status
gh run view "$RUN" --log | grep -E "sweeping|deleted|swept|nothing to sweep|would not delete"
```

A sweep that finds nothing prints `nothing to sweep — the account is clean` and
exits zero, so it is also the check: run it twice, and the second pass should
find nothing. A sweep that finds something is worth reading — it means a run
did not clean up after itself, and the workflow says so in its step summary.

### Sweeping from a laptop

Same code path, your credentials. Each cloud needs only its own variables, and
the region has to match where the live fleet is placed — `awsFull in ireland`,
`scalewayFull in paris`, `gcpFull in paris` (`test/Live.lean`), which
`Infra/Core/Region.lean` maps to `eu-west-1`, `fr-par` and `europe-west9`.
The variable names are `Infra/Core/Credentials.lean`'s, not the CLIs':

```sh
# AWS. AWS_SESSION_TOKEN only if the credentials are temporary.
AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=… AWS_REGION=eu-west-1 \
  lake test -- aws sweep

# Scaleway.
SCW_ACCESS_KEY=… SCW_SECRET_KEY=… SCW_DEFAULT_PROJECT_ID=… SCW_DEFAULT_REGION=fr-par \
  lake test -- scaleway sweep

# Google Cloud.
GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud auth print-access-token)" \
GOOGLE_CLOUD_PROJECT=typednotes GOOGLE_CLOUD_REGION=europe-west9 \
  lake test -- gcp sweep
```

### What a sweep cannot reach

Three limits, all structural rather than bugs, and worth knowing before
concluding an account is clean:

- **Only prefixed names.** Anything not called `ci-tests-infra-*` is somebody's,
  and a sweep must never touch it. A resource the fleet renamed *away* from the
  prefix would be invisible — which is what the naming `#guard` prevents.

  The prefix cuts the other way too: one account can hold *two* projects' test
  resources — a fork, a second checkout, someone's branch — and a plain sweep
  deletes both, including the ones a run currently in flight is using.
  `--prefix` narrows it:

  ```sh
  lake test -- scaleway sweep --prefix ci-tests-fork-
  lake test -- all sweep --prefix ci-tests-fork-
  ```

  It defaults to `ci-tests-infra-`, and an empty value is refused rather than
  read as "match everything" (`checkedPrefix`). The complementary fix is on the
  *fleet* rather than the sweep: `boundary := { fleetName := some "…" }` puts
  the fleet's name in the ownership marker, so two fleets in one account do not
  claim each other's resources at all — see
  [`../docs/persistence.md`](../docs/persistence.md).
- **Only kinds a lister covers, in regions the fleet declares.** A sweep
  enumerates `Kind` through `Backends.listers`, so a resource placed somewhere
  the declaration never mentions is out of reach. Concretely on Scaleway: the
  **SQS credential named `infra`** is not a `Kind` at all, so no sweep sees it.
  It is harmless — `Scaleway.Sqs` reclaims and re-mints the name on a `409`,
  and logs a `note:` when it does — but it is permanent. Remove it by hand
  through the Queues console, or through the API the code itself uses:
  `GET`/`DELETE https://api.scaleway.com/mnq/v1beta1/regions/fr-par/sqs-credentials[/{id}]`.
- **Unmarked resources are not the sweep's problem, but they look like it.**
  A resource that exists, matches a declared line and lacks the ownership
  marker is refused by `push` rather than adopted, so no teardown will remove
  it and only a sweep will — see `docs/persistence.md`. If a live run fails
  with *declared but not managed*, that is this case, and a sweep is the fix.
