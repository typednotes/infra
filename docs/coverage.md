# Coverage in 0.6.0

What this version actually does, and — more usefully — how far each part has
been exercised. Everything below is the state on 2026-09-07.

This page is the canonical answer; the README and `docs/tutorial.md` link here
rather than repeating it, so there is one place to correct.

## Clouds

| Cloud | Status |
|---|---|
| **AWS** | implemented |
| **Scaleway** | implemented |
| **GCP** | **all seven portable kinds have live clients** — Pub/Sub, Cloud Storage, Secret Manager, Artifact Registry, Cloud Run, IAM service accounts, Cloud SQL. Two stated limits: a serverless `postgres` declaration raises (Cloud SQL has no such tier), and `iam` reads policies but refuses to write them. Provider-local kinds report no counterpart rather than a missing client |
| Azure, OVH | not started |

Adding a cloud is a `ProviderId` constructor, after which every total match
over it fails to compile until handled. That is the intended cost: mechanical
and loud, not a plugin boundary.

## Resource kinds

Fourteen, split deliberately. **Portable** kinds are the common denominator and
carry no cross-resource references, so the same spec value applies to either
cloud. **Provider-local** kinds are richer and tie a plan to one cloud, which
the kind's name makes obvious.

Every `(provider, kind)` pair is implemented — `Live.lean` has no catch-all,
and Lean reports one as unreachable.

### Portable — one spec, either cloud

| Kind | AWS | Scaleway | Shared client |
|---|---|---|---|
| `objectStore` | S3 | Object Storage | **yes** |
| `queues` | SQS | Messaging & Queuing | **yes** |
| `secrets` | Secrets Manager | Secret Manager | no |
| `imageRegistry` | ECR | Container Registry | no |
| `compute` | Lambda (container image) | Serverless Containers | no |
| `iam` | IAM users | IAM applications | no |
| `postgres` | RDS | Managed Database | no |

Two of the seven — `objectStore` and `queues` — need no per-cloud code
*between AWS and Scaleway*, because Scaleway's endpoints are S3- and
SQS-compatible, so one client serves both. That is the portability claim
paying off rather than being asserted.

The qualifier matters and used to be absent: GCP shares neither. Cloud Storage
authenticates its S3-compatible API with HMAC keys, which is a credential this
library never holds, and Pub/Sub is not SQS at all — so both kinds needed a
GCP client of their own (`Gcp.Storage`, `Gcp.PubSub`). Three clouds, two
clients for those kinds, not one.

### Provider-local — the escape hatch

| Kind | Cloud | Why it is not portable |
|---|---|---|
| `s3Bucket` | AWS | Object Lock has no Scaleway counterpart |
| `securityGroup` | AWS | no portable networking model |
| `awsInstance` | AWS | needs a *required* network reference, which the serverless-shaped `compute` cannot carry |
| `scalewayFunctionNamespace` | Scaleway | Functions and Containers are different products with different API prefixes |
| `scalewayFunction` | Scaleway | as above |
| `scalewayContainerNamespace` | Scaleway | as above |
| `scalewayContainer` | Scaleway | binds secret-backed environment variables, which `compute` cannot |

## Language and engine features

| Feature | State |
|---|---|
| `fleet` declaration DSL, with `provider` and `in` blocks | complete |
| Placement — per cloud, and per resource across regions | complete |
| Typed localities and region codes, checked at elaboration | complete |
| Typed EC2 instance types (family × size), checked at elaboration | complete |
| References between resources, including across clouds | complete |
| DAG scheduling of creations *and* deletions, cycles rejected | complete |
| Composed secrets — a value assembled from post-apply state, in one apply | complete |
| Account guard — refuse to run against the wrong account | complete |
| Offline planning against placeholder backends | complete |
| Observed-state cache on disk | complete |
| `check` / `refresh` / `plan` / `apply` / `destroy` | complete |
| Scoping — manage some resources, leave the rest alone | complete, via the key family |
| Terraform/OpenTofu export (`toHcl`) | works; not a round trip — see below |
| Terraform/OpenTofu import (`fleetOfState`) | works, from `terraform show -json` |
| `lake test` — offline by default, live per provider on request | complete |

## How far each part has actually been run

This is the section worth reading before trusting anything. Correctness of
*signing* is established; correctness of *what is being signed* mostly is not.

### Verified against a real account

- **Scaleway `list`, every kind.** `example/ScalewayPull.lean` calls raw
  `Backend.list` for all fourteen kinds. Run on 2026-09-05 it returned nine
  resources — IAM applications (3), a container image registry (2), a
  serverless container and its namespace, a queue, and a compute unit — and an
  empty list for the rest, which is a *successful* call finding nothing rather
  than a skipped one. Twelve of the fourteen make a real Scaleway call; only
  `securityGroup` and `awsInstance` short-circuit, being AWS-only kinds.
- **GCP service-account authentication**, end to end against a real service
  account on 2026-09-05: a key file parsed, an RFC 7523 assertion signed
  RS256, exchanged with Google for a live access token, and the credential
  chain picking the file up from `GOOGLE_APPLICATION_CREDENTIALS`. The key was
  created for the test and deleted immediately after.
- **GCP `objectStore`**, over the Cloud Storage JSON API, and **GCP
  `secrets`**, over Secret Manager — both full CRUD. Neither is live-tested
  against a real project yet; only `queues` is. Two things they exposed:

  `objectStore` had *no GCP branch at all* and routed unconditionally to the
  S3 client, so a declared GCP bucket was signed with SigV4 and sent to
  `storage.googleapis.com`. GCS's S3-compatible API needs HMAC keys, which are
  a credential this library never holds, so it could only ever have failed.
  Same shape as the `queues` defect: unimplemented without appearing in `grep
  noGcp`.

  And a Secret Manager secret is *two* resources — a container with a
  replication policy, and a version holding the bytes — so creating one with a
  value is two calls that cannot be made one. If the second fails the secret
  exists and is empty, which a retry cannot fix (`ALREADY_EXISTS` while the
  value is still missing), so that error says exactly what state it left.
- **GCP `queues`**, over Pub/Sub topics — `list`, `create`, `read`, `delete`,
  exercised by the live CI round trip. The first live GCP client of any kind,
  and the one that motivated three fixes above the backend: Google nests its
  error body one level deeper than the other two clouds (so every GCP failure
  had rendered with an empty message), federated credential files were being
  read as service-account keys, and a topic is not a queue — the portable
  `visibilityTimeoutSec` belongs to a Pub/Sub *subscription*, so it is
  reported unknown rather than guessed at.
- **Scaleway `queues`** — `list`, `create`, `read`, via
  `example/ScalewayQueue.lean`. Two bugs only surfaced here: the endpoint host
  was wrong in a way that did not resolve at all, and Scaleway's SQS-compatible
  API refuses the main API key and needs a dedicated minted credential.
- **AWS S3 `create` and `list`** — `example/CrossCloud.lean` applied against a
  real account. The cache holds a real bucket URL
  (`s3.eu-west-3.amazonaws.com/typednotes-assets`) and a real ARN
  (`arn:aws:s3:::typednotes-archive`), so both the portable `objectStore` and
  the provider-local `s3Bucket` create paths work.
- **AWS EC2 `create` and `read`** — `example/ParisInstances.lean` applied
  against a real account. The cache holds a real security group
  (`sg-…`, with its VPC) and two instances with real ids, private IPs and state
  `running`. That means `CreateSecurityGroup`, `RunInstances`,
  `DescribeSecurityGroups` and `DescribeInstances` all work with the parameter
  names in `Kinds/Ec2.lean` — which this document, until now, described as
  unverified guesses.

### Exercised by CI

`lake test` runs the offline driver on every push, and every example with it.
`lake test -- <provider>` is the live sequence, run from a manual workflow
trigger, one cloud at a time.

**Where the staged sequence has got to, as of 2026-09-07.** Stages 1 and 2 pass
on all three clouds — which is the first time membership has been exercised
live: stage 2 drops two resources whose lines are gone from the declaration, so
the ledger is the only thing that can name them, and the account came back
holding exactly what the stage declared. Stage 3 failed on all three, for one
reason in the tool and not in any cloud: the "destroying most of the ledger"
brake fired on the teardown, which is the one plan it was never meant to
question. Fixed by deriving the exemption from the target
(`Plan.declaresAnything`) instead of taking a flag every caller had to
remember. **The full three-stage sequence has not yet completed on any cloud**,
and the resources from those runs had to be cleaned up with
`lake test -- <cloud> destroy`.

#### What one live leg does

Three declarations, applied in order against one ledger. Each stage is a real
apply against a real account, and after each one the account must hold
*exactly* what that stage declares:

| Stage | Declares | What it proves |
|---|---|---|
| 1 `full` | eleven resources on AWS and Scaleway, ten on GCP | `create` works, and the dependency order works: five secrets forming a fan-out of two, a fan-in of three with a redundant edge, and a four-deep chain, all in one apply |
| 2 `trimmed` | two resources dropped, one field changed, one added | `deleteOrphan` for the dropped — their lines are *gone*, so only the ledger knows they exist — plus `update` for the changed field and `create` for the new one |
| 3 `empty` | nothing at all | `deleteOrphan` for everything left. This is `apply` against an empty declaration, which is the same operation `destroy` performs, and the half that had never run |

Stage 2 is the one that earns the sequence. If membership still came from the
declaration, its two dropped resources would be silently abandoned, stage 3
would find nothing to clean up, and both stages would pass while leaking two
billable resources per cloud. The assertion that catches that compares the
ledger against the stage's own declared slots, derived from the key family
rather than written out.

Each stage polls for convergence rather than reading once, because every list
API here is eventually consistent to some degree and a single read after a
write measures propagation delay rather than correctness. The sequence ends by
asserting the ledger is empty, which is the descendant of a check that existed
because of a past defect: `save` left the file of an emptied
`(provider, kind)` pair on disk, so the cache went on listing what had just
been deleted.

Teardown runs from a `finally`, and its failure is reported *alongside* the
original rather than replacing it. There is a backstop teardown in the workflow
if the driver dies between create and delete. Everything created is named
`ci-tests-infra-…`, so anything ever leaked is identifiable at a glance.

#### What it covers, and what it does not

**What has actually run — all three clouds, full legs, on 2026-09-06:**

| Cloud | Resources | Kinds |
|---|---|---|
| AWS | 9 | `queues`, three `secrets`, `imageRegistry`, `objectStore`, `s3Bucket`, `securityGroup`, `iam` |
| Scaleway | 9 | `queues`, three `secrets`, `imageRegistry`, `objectStore`, both namespaces, `scalewayContainer` |
| GCP | 8 | `queues`, three `secrets`, `imageRegistry`, `objectStore`, `compute`, `iam` |

Each created from nothing, converged (`a second apply would do nothing`),
deleted, and the state cache verified empty. In every case the workflow's
backstop step was *skipped*, which is the evidence that the driver's own
teardown ran and left nothing behind — and the accounts were checked afterwards
and are clean.

**Eleven of the fourteen kinds; 21 (cloud, kind) pairs.**

**All three dependency patterns are exercised live.** The chain and the fan-out
run on every cloud. The **fan-in** was Scaleway-only and is now covered: its
container depends on its namespace by *key* reference and on the base secret
through `secretEnv`, two edges of different provenance converging on one
resource, both of which teardown reverses.

There is no longer a gap between "what the fleets declare" and "what has run"
for these kinds. The distinction still matters for everything else in this
document, and is still drawn.

| Cloud | Kinds the live fleet declares | Resources |
|---|---|---|
| AWS | `queues`, `secrets`, `imageRegistry`, `objectStore`, `s3Bucket`, `securityGroup`, `iam` | 9 |
| Scaleway | the same minus `s3Bucket`/`securityGroup`/`iam`, plus both namespaces and `scalewayContainer` | 9 |
| GCP | the same minus `s3Bucket`/`securityGroup`, plus `compute` | 8 |

**Eleven of the fourteen kinds**, and 21 (cloud, kind) pairs.

`iam` is deliberately absent from the Scaleway fleet, which is the one place a
kind was dropped rather than never added. Scaleway's IAM applications live in
the **organization**, not in a project, so covering the kind there would need
CI to hold organization-level IAM rights — and those cannot be confined to the
isolated project the rest of the Scaleway fleet lives in. Giving up one
(cloud, kind) pair is cheaper than giving a CI credential org-wide IAM. The
kind is still covered on AWS and GCP, where the identity is account- or
project-scoped.

`compute` became testable once a *public* image was allowed — Cloud Run pulls Google's own sample, so nothing has to be
built — and `scalewayContainer` for the same reason, since Serverless
Containers can pull from an external registry. Lambda still cannot: a container
function must come from an ECR repository in the same account.

Eleven of the fourteen kinds, 22 (cloud, kind) pairs. Every one is written to be
created from nothing and deleted again, and the set matters as much as the
count: a fleet is applied and torn down as a *set*, so `create` and `delete`
each run seven times in one pass and the absence check covers all of them — a
single-resource test cannot tell a working scheduler from a lucky one.

**All three legs pass.** This section says which have passed and which have
not, rather than counting the fleets as coverage — and for the first time
those are the same set.

**The three that are not covered, each for a reason a test cannot arrange:**

| Kind | Why not |
|---|---|
| `scalewayFunction` | Needs deployable code, not just an image — there is no public equivalent to pull |
| `awsInstance` | Needs a region-specific AMI id that goes stale, which would put a rotting constant in a test whose failure looks like a library bug. Bills by the second and takes minutes to terminate |
| `postgres` | Five to fifteen minutes to create and as long to delete, on every cloud — longer than the workflow's step timeout, so it would not be a slow test but a failing one |

### Three dependency patterns, exercised live

Ordering is the part of this engine most likely to be wrong in a way that only
a real cloud reveals, so the fleets are built to have shape rather than just
size. Each pattern fails differently when the schedule is wrong:

| Pattern | How it is built | What breaks if ordering is wrong |
|---|---|---|
| **Chain** | `derived-a` composes the base secret's *value* | The create fails reading a secret that does not exist yet |
| **Fan-out** | `derived-a` and `derived-b` both compose the same base | Teardown deletes the base while two dependents still reference it |
| **Fan-in** | Scaleway's container depends on its namespace (`depsKey`) *and* the base secret (`depsKeys secretEnv`) | Either dependency missing at create time is a hard failure |

The fan-in is the only place the live test exercises **key** references rather
than expression references — two edges of different provenance converging on
one resource, both of which teardown has to reverse.

All three are also pinned offline by `#guard`s on the create order, including
negative ones, so a scheduler regression is a compile error rather than
something found against an account. The negative guards matter: without them
the positive ones would pass if everything were trivially "before" everything.

**Two kinds have globally-scoped names, and only one of them is obvious.**
Object storage names are unique across an entire cloud rather than per account,
and a fleet's names are compile-time constants — which is why buckets were
excluded from the live test until a fixed random suffix (`bucketSuffix`)
resolved it.

Scaleway's **registry namespaces** are the same shape, and nothing about the
kind advertises it: the namespace name *is* the hostname path,
`rg.fr-par.scw.cloud/<name>`, so it is unique per region across every project.
A leftover from a failed run blocks every later run in any project with
`400 Namespace already exist` — the same permanent-deadlock shape as the SQS
credential name, and found the same way. It carries the suffix now too.

AWS's ECR repositories are account-scoped and GCP's Artifact Registry
repositories are project-scoped, so neither needs it. If a fourth cloud is
added, "is this name global?" is worth asking of every kind rather than only of
buckets.

The honest cost of the suffix is that a **fork will collide with this
repository's names** unless it changes `bucketSuffix`, and `test/Live.lean` says
so where someone will read it.

**Permissions are the current gate.** Nine kinds need more than the identities
hold — AWS's role was scoped to SQS alone, GCP's service account holds only
`roles/pubsub.editor`. `ci/README.md` gives the CLI commands per cloud.
Until they are granted a leg fails with the cloud's own refusal, which is the
correct failure but is not a defect in the library.

The settle window is 180 seconds, up from 60: it is not the resource count
that raised it but the slowest member — Scaleway's Functions and Containers
namespaces take tens of seconds to appear and tens more to go. It is not a
coverage matrix; it is a proof that the whole engine — credential chain,
region resolution, list, create, diff, delete, settle, persistence — works
end to end against three different real APIs. Everything it does *not* cover
is covered offline or not at all, and the two sections around this one say
which.

`secrets` was chosen as the second kind on the same grounds as the first, plus
one that nearly disqualified AWS: Secrets Manager *schedules* deletion with a
recovery window of at least seven days by default, and a name under scheduled
deletion cannot be reused — so this test would have been unrunnable a second
time. It works only because `Secrets.Asm.delete` passes
`ForceDeleteWithoutRecovery`. Its value comes from the environment, never the
file, which is what `secretsAreSound` proves at compile time for all three
live fleets.

Queues were chosen for a reason worth keeping. Their names are region-scoped,
so two accounts running this concurrently do not collide; they cost
approximately nothing; and they create and delete in seconds. A bucket is the
obvious alternative and the wrong one — bucket names are globally unique across
all of AWS, and a fleet's resource names are fixed at compile time, so the
test would be one name away from being permanently unrunnable by anyone else.
Widening live coverage to `objectStore` means solving that first.

One asymmetry to know: a Pub/Sub topic has no visibility timeout — that
belongs to a subscription — so the GCP leg declares `visibilityTimeoutSec := 30`
and the backend reports it `unknown`. The convergence check in step 3 is still
meaningful, because an unknown field is not a divergence, but it does not mean
that 30 was stored anywhere.

That closes the gap this document named a version ago: `destroy` was "the least
exercised code in the library relative to how much it can cost to get wrong".
It is now on the CI path for all three clouds, and on AWS it has actually
deleted seven kinds of resource and been checked against both a fresh listing
and the state cache.

### Verified offline, on every build

Signing against AWS's published SigV4 test vectors; both provider error
dialects; the divergence rules; `Content-MD5` for S3 configuration writes; the
credential chain and its redaction; composed secrets creating three resources
in one correctly-ordered apply with no value leaking into output or cache; that
the `fleet` command produces a fleet indistinguishable from the hand-written
equivalent; and DAG scheduling over a sixteen-resource graph with a diamond,
fan-in, a redundant edge, a four-deep chain and cross-cloud edges, checked in
both directions by a checker that recomputes the edges independently.

### What the first multi-kind live runs found

Two rounds so far, and every failure was a different kind of thing.

**Round two** — the `ClientRequestToken` fix worked, and AWS got as far as the
security group before failing on this:

    InvalidParameterValue: Invalid security group description. Valid
    descriptions are strings less than 256 characters from the following
    set:  a-zA-Z0-9. _-:/()#,@[]+=&;{}!$*

The description was "created and destroyed by infra's live test". An
**apostrophe** is not in that set. A perfectly ordinary English description,
invalid for a reason no reader would guess, and — since descriptions are
compile-time constants — one that would have failed every apply forever. The
client now validates the character set and names the offending characters, and
the fleet's descriptions are pinned by a `#guard`.

That run also exposed something worse than the bug it was reporting: the
workflow's **backstop re-ran the whole test**. `lake test -- aws` is a create
*and* a destroy, not a destroy, so a failed leg was followed by a second create
that failed identically — the log shows the same security-group error twice,
once from the test and once from its own cleanup, and a backstop that creates
can leave more behind than it removes. The driver now has a `destroy` mode that
tears down and nothing else, sharing one code path with the round trip's own
teardown so the two cannot drift.

**Round three** — AWS repeated round two's failure because the fix was not yet
pushed, Scaleway's newly-contextual error pinpointed itself
(`GET /iam/v1alpha1/applications: 403`, the `iam` kind's listing during
`pull`), and GCP produced a *third* kind of prerequisite:

    Secret Manager API has not been used in project typednotes before or
    it is disabled.

On Google Cloud an API must be **enabled on the project** before anything can
call it, which is a separate act from being permitted to call it. Roles were
documented; enablement was not. `ci/README.md` now has the
`gcloud services enable` line, and notes that `sqladmin` is deliberately left
off because `postgres` is not in the fleet and enabling an API widens what a
compromised credential can reach.

Worth noting for contrast: Google's message names the API, the project, the
console page and the propagation delay. AWS's named a regex. Scaleway's named
nothing until this repo made it.

**Round one** — three legs, three different failures:

Only one was a permissions gap of the kind expected.

- **AWS: a real library bug.** `CreateSecret` was rejected with
  `You must provide a ClientRequestToken value`. The API reference calls that
  field optional, and it is — *through an SDK*, which generates one when the
  caller omits it. This library does not use an SDK, so it was never optional
  here. Nothing offline distinguishes a field an SDK fills in from one the
  service defaults, which is exactly why `docs/coverage.md` listed Secrets
  Manager under "never run" and exactly what a first live call is for. Fixed,
  with an offline check on the token's shape and freshness.

- **GCP: a permission missing because a table went stale.**
  `Permission 'run.services.list' denied` — `roles/run.admin` was never added
  to `ci/README.md` when `compute` joined the GCP fleet a commit earlier. The
  table is derived from `test/Live.lean` and now says so.

- **Scaleway: a permissions gap, reported uselessly.**
  `HTTP 403 permissions_denied: insufficient permissions`, with no product, no
  operation and no resource — across a ten-resource fleet. AWS names the
  action and Google names the exact permission *and* resource; Scaleway's
  bodies are the terse ones. Its calls now prefix failures with the method and
  path, which identifies the product and operation.

### A kind can be "implemented" and still miss the path a dependency needs

Worth its own heading, because it happened twice in the same shape and the
second one was found by reading rather than by a failure.

`Gcp.SecretManager` had `list`, `create`, `putValue`, `delete` and
`describeVersion` — everything except **reading a value**. Nothing in the
`secrets` kind itself needs that: a secret's value is written, never read
back, and `read` deliberately reports only a version identifier. What needs it
is a *dependency between resources*: a composed secret builds its value from
another secret's value at settle time. So the first live GCP fleet with a
composed secret failed on `derived-a` with "no backend yet", from a kind whose
own CRUD was complete.

Then the same gap existed a second time in a different file.
`Postgres.fetchMasterPassword` was a near-copy of `Secrets.fetchValue`, and the
GCP branch had been implemented in one and not the other — so a GCP `postgres`
would have failed identically. It delegates now.

The general lesson, for whoever adds the fourth cloud: per-kind CRUD is not the
whole surface. The cross-resource paths — reading a secret's value, resolving a
key reference — are separate, they are not exercised by a fleet of independent
resources, and they live in files named after a different kind.

### Known gap: `scalewayContainer.timeoutSec` is never compared

Scaleway reports a container's `timeout` as a **duration string** (`'300s'`),
and `Compute.Containers.readFull` reads it with `natField`, which fails on a
string and yields `unknown`. `unknown` diverges from nothing, so the field is
silently *unchecked* rather than wrong — no false replace, no false update, and
no verification either.

Deliberately not fixed on the eve of a live run: parsing it would start
comparing a field that has never been compared, and if the declared and stored
values differ in any way this would introduce a fresh non-convergence into the
path being tested. `Gcp.CloudRun.parseSeconds` already exists and is the
obvious implementation, once Scaleway's leg is green and a change can be
attributed.

The same reading explains why `max_concurrency` is consulted first in that
function — it is a number, so it tells the code the response was parsed at all.

### Implemented, never exercised

- **Scaleway Serverless SQL Database** — the `postgres` kind's serverless
  shape on Scaleway. It was a stub that raised; it is a client now. The
  endpoint family was confirmed against the live API rather than recalled
  (`/serverless-sqldb/v1alpha1/regions/fr-par/databases` answers `401`
  unauthenticated where `serverless_sqldb`, `v1beta1` and a bogus route all
  answer `404`), and the field names come from Scaleway's own CLI reference for
  `scw sdb sql`. No account has run it.

  Note what the portable spec cannot say here: a Serverless SQL Database has no
  root user, so `masterUsername` and `masterPasswordSecret` have no
  counterpart and are ignored, and there is no node type, version or fixed
  storage to report. All four read as absent, which diverges from nothing.

  **AWS's serverless shape is still not implemented** — Aurora Serverless v2
  raises a named error — and **GCP's cannot be**: Cloud SQL has no capacity
  range that scales to a floor, so it raises with the tier to set instead. So
  a serverless `postgres` declaration works on exactly one of the three
  clouds.

### Never run against any account

Rewritten after AWS's full leg passed, because most of what this section said
about AWS is no longer true. It listed ECR, Secrets Manager and IAM as never
called; all three now create, read and delete on every AWS live run.

- **AWS: Lambda and RDS.** The two remaining never-called clients, and the two
  kinds the live fleet cannot include — `compute` needs an ECR image in the
  same account, `postgres` takes longer to create than the workflow's step
  timeout.
- **Scaleway: `postgres` and `scalewayFunction`.** Everything else creates,
  reads and deletes on every Scaleway live run. `iam` is deliberately not in
  the fleet — Scaleway's IAM applications are organization-scoped, and CI holds
  no organization-level rights — so its Scaleway client is unexercised by
  choice rather than by omission.
- **GCP: Cloud SQL only.** Everything else — Pub/Sub, Cloud Storage, Secret
  Manager, Artifact Registry, Cloud Run, IAM service accounts — creates, reads
  and deletes on every GCP live run. Cloud SQL is untested because `postgres`
  cannot be in the fleet.
- **Every `update` path, on all three clouds.** This is the significant
  remaining hole, and the live test cannot close it by design: it creates and
  deletes, so it never diffs a *changed* target against an existing resource.
  Closing it needs a second apply with a modified fleet, which is a different
  test shape.

  `delete`, which used to sit here beside `update`, is now exercised on AWS
  across seven kinds and checked against both a fresh listing and the state
  cache. Two library bugs were found on the way out of that: `pullEntries`
  assumed anything `list` returned still existed when it read it — so the
  post-delete refresh saw the queue in SQS's eventually-consistent listing,
  failed to read it, and aborted the pull — and before that, the harness read
  the listing immediately after creating and reported propagation delay as
  non-convergence. Both directions poll now.
- **Ingress rules and tags** — `CreateSecurityGroup` succeeded, but whether
  `AuthorizeSecurityGroupIngress` applied the rules correctly, and whether tags
  land, is not established by a group merely existing.
- **Most endpoint shapes** — roughly 2,250 lines across `Kinds/*.lean`.
- **`scalewayContainer.secretEnv`** — how Scaleway actually binds a secret to
  an environment variable. Implemented against the plaintext-at-set-time
  assumption; if the real mechanism is a native reference, the backend
  simplifies and the types do not change.

## Interoperability with Terraform and OpenTofu

Both directions exist, in `Infra/Interop/Terraform.lean`, and neither is a
round trip — which is stated because the temptation to oversell this is
obvious.

**Out** — `toHcl` turns a fleet into `.tf`: a `resource` block per resource,
`provider` blocks from the placement, and *real* HCL references where the
fleet has references, since a reference is an index into the fleet and so the
target's Terraform type and label are both derivable. What HCL cannot express
— a composed secret, a value over post-apply state — becomes a `# TODO`
naming what was dropped, because a silently wrong value is worse than a
visible hole. A fleet spanning several regions of one cloud emits aliased
providers plus a note that the per-resource `provider =` arguments are *not*
generated.

**In** — `fleetOfState` reads `terraform show -json` and writes a `fleet`
declaration. Source text rather than a value, necessarily: a fleet's key type
is derived from its resource names while the file elaborates, so importing
means writing a declaration for you to compile. Fields are left empty on
purpose, so anything with a required field will not compile until you supply
it — and the error names the field. Resource types this library does not model
are skipped, with a count.

The `(provider, kind) → resource type` table is **unverified against either
registry**, and the attribute names inside each block are a looser guess
still. Same standing as the endpoint shapes in `Kinds/*.lean`.

### `infra` is a reserved credential name on Scaleway Queues

Scaleway's SQS-compatible endpoint refuses the main API key and needs a
dedicated one, minted once and cached in the OS keychain. A CI runner has no
keychain, so the cache always misses, and the minted secret is shown only
once — so every run must mint afresh.

Minting rejects a duplicate name. That combination is a trap: one uncaptured
mint takes the name and every later attempt fails with `409 already_exists`,
permanently, with nothing the tool can do about it. So the name is reclaimed
instead — the credential holding it is deleted and replaced. An uncaptured
secret is unrecoverable, so nothing that worked is destroyed, and exactly one
credential named `infra` ever exists.

The consequence to know: **do not create a Scaleway SQS credential named
`infra` by hand.** `infra` will delete it.

## Membership, and what of it has been run

The ledger (`Infra.Core.Ledger`), `forget`, and orphan deletion are new, and
this is how far they have actually been exercised.

**Verified offline, every build.** The ledger round-trips through JSON with
every field intact — the region especially, since nothing else records it once
a resource's line is gone. Rows come back sorted, because the file is
committed and its diff is read. An emptied ledger stays a *file*, so "manages
nothing" is distinguishable from "someone deleted the ledger". A file without a
version is refused rather than read as empty, because reading it as empty would
orphan everything it recorded. And `actionsOrphaned` is guarded on the three
cases that matter: a row still declared produces nothing, a row named in
`forget` produces a non-destructive `FORGET`, and a row the declaration has
dropped produces a `DELETE`.

**Verified by the compiler.** Four things, each recorded with the message it
actually produces in `Infra/Demo.lean`'s negative checks:

- `forget`ting a resource the same fleet still declares does not elaborate, via
  `Assert (!claimedByKey …)` discharged by `decide`.
- One fleet's releases cannot be handed to another: `Released` is indexed by the
  key family.
- A release cannot be built by hand — `Released.mk` is private, so `releasing`
  and its check are the only way to obtain one.
- A fleet that declares a `forget` and does not pass it to `Cli.run` does not
  compile, because `forgets` has no default. That combination used to compile
  and then destroy the resource.

**Never run against an account.** The wiring in `Infra.Cli` that loads the
ledger, hands it to `push`, and writes it back after each action — though the
live legs are now *shaped* to exercise it: each cloud runs three declarations
in sequence and the middle one drops two resources, so an orphan delete is the
only way the stage can pass. That has been written and compiled, not run. The
`#guard`s cover the decision (what a set of rows plus a declaration should
do); they do not cover the plumbing, because a bare invocation runs the
offline self-check and never reads a ledger. Specifically unexercised: that a
`DELETE` derived from a ledger row reaches the right region's endpoint, that
the ledger is correctly rewritten when an apply fails halfway, and the
more-than-half brake.

**A `Backend.probe` field was added and then removed**, and the reason is worth
keeping because it is a fact about this provider layer rather than about the
design. Making membership the ledger's business invited answering *existence*
per resource, by name, the way Terraform does. Terraform can, because its
providers implement a per-resource read that returns not-found. This one cannot:
`liveRead`'s `.secrets` clause makes no cloud call at all, and every
`(provider, kind)` pair that is not live yet reports `unknown` fields
*successfully*. Reading that as "it exists" meant a declared secret was never
created.

So existence comes from `list` again, which can be wrong only by omission — the
safe direction — and which is the call this repo has exercised against real
accounts for all fourteen kinds. Membership stays the ledger's. The two
questions were conflated before this change; separating them was right, and
answering the second one per resource was not.

## Known defects

Recorded in full in [`diff-semantics.md`](diff-semantics.md)'s ledger. The one
most likely to matter:

- **An orphan's references are not recorded.** The ledger holds names and
  regions, not dependency edges, so deleting two lines at once where one
  referenced the other can have the provider refuse the second delete until
  the first is done. See `docs/diff-semantics.md`.

Not a surprise waiting to be discovered; it is written down.

`Plan.outside` used to head this list — declared, never consumed, and the
reason deleting a resource from a declaration left it running in the cloud. It
is gone, not softened: membership is now `Infra.Core.Ledger`, a committed
record that survives the declaration it came from, and `forget` is how a
resource leaves it without being destroyed.

`S3BucketSpec.region` used to head this list — a field that did not place the
bucket and was only compared, so a bucket declared without it proposed a
replacement that could never converge. It is removed: placement is the one
mechanism, and the disagreement is now unrepresentable rather than documented.

## Not in this version

More clouds, more kinds, and more of each cloud's surface — networking beyond
security groups, DNS, load balancers, Kubernetes. Also: checking an instance
type against the region it is placed in, which is now *possible* because both
facts are declared, and is not done because a stale availability table would
reject valid fleets.

Breaking changes to the Lean API should be expected before a first tagged
release.
