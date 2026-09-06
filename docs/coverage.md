# Coverage in 0.3.0

What this version actually does, and — more usefully — how far each part has
been exercised. Everything below is the state on 2026-09-05.

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
`lake test -- <provider>` is the live round trip, run from a manual workflow
trigger, one cloud at a time. **All three legs pass as of 2026-09-06.**

#### What one live leg does

Six steps, in order, against a real account. Each is a real API call, not a
mock:

| # | Step | What it proves |
|---|---|---|
| 1 | `pull` | `list` works, and the account is reachable with the credentials the chain found |
| 2 | `push … apply` | `create` works |
| 3 | poll `pull` until the plan is empty (≤ 60 s) | `list` and `read` report the resource, **and the diff of observed-against-declared is empty** — i.e. a second apply would do nothing |
| 4 | `push (Plan.absent) apply` | `delete` works |
| 5 | poll until the listing shows nothing (≤ 60 s) | the delete really took, rather than being issued while the resource was still invisible |
| 6 | `Persistence.load` is empty | the state cache agrees with the account |

Steps 3 and 5 poll rather than read once, because every list API here is
eventually consistent to some degree and a single read after a write measures
propagation delay rather than correctness. Step 6 exists because it is exactly
what a past defect needed: `save` left the file of an emptied
`(provider, kind)` pair on disk, so the cache went on listing what had just
been deleted.

Teardown runs from a `finally`, and its failure is reported *alongside* the
original rather than replacing it. There is a backstop teardown in the workflow
if the driver dies between create and delete. Everything created is named
`ci-tests-infra-…`, so anything ever leaked is identifiable at a glance.

#### What it covers, and what it does not

**What has actually run is one kind, on three clouds**: `queues` — SQS on AWS,
Scaleway Queues, a Pub/Sub topic on GCP. All three legs passed on 2026-09-06.

**What the fleets now declare is nine kinds**, and that has *not* run yet. The
two are separated deliberately, because a document whose whole job is to say
how far this has been exercised must not count code that has never executed.

| Cloud | Kinds the live fleet declares | Resources |
|---|---|---|
| AWS | `queues`, `secrets`, `imageRegistry`, `objectStore`, `s3Bucket`, `securityGroup`, `iam` | 9 |
| Scaleway | the same minus `s3Bucket`/`securityGroup`, plus both namespaces and `scalewayContainer` | 10 |
| GCP | the same minus `s3Bucket`/`securityGroup`, plus `compute` | 8 |

**Eleven of the fourteen kinds.** `compute` became testable once a *public*
image was allowed — Cloud Run pulls Google's own sample, so nothing has to be
built — and `scalewayContainer` for the same reason, since Serverless
Containers can pull from an external registry. Lambda still cannot: a container
function must come from an ECR repository in the same account.

Eleven of the fourteen kinds, 22 (cloud, kind) pairs. Every one is written to be
created from nothing and deleted again, and the set matters as much as the
count: a fleet is applied and torn down as a *set*, so `create` and `delete`
each run seven times in one pass and the absence check covers all of them — a
single-resource test cannot tell a working scheduler from a lucky one.

**None of the multi-kind legs has been run.** They are blocked on permissions
neither CI identity holds — AWS's role was scoped to SQS alone and GCP's
service account holds only `roles/pubsub.editor` — so the first run of each
will most likely fail with the cloud's own refusal until `ci/README.md`'s grants
are applied. This section will say so when they pass, and not before.

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

**Buckets needed a decision.** Object storage names are unique across an
entire cloud, not per account, and a fleet's names are compile-time constants —
which is why buckets were excluded until now. A fixed random suffix
(`bucketSuffix`) resolves it: unique in practice, still constant. The honest
cost is that a **fork will collide with this repository's buckets** unless it
changes the suffix, and `test/Live.lean` says so where someone will read it.

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
exercised code in the library relative to how much it can cost to get wrong",
and it is now on the CI path for all three clouds.

### Verified offline, on every build

Signing against AWS's published SigV4 test vectors; both provider error
dialects; the divergence rules; `Content-MD5` for S3 configuration writes; the
credential chain and its redaction; composed secrets creating three resources
in one correctly-ordered apply with no value leaking into output or cache; that
the `fleet` command produces a fleet indistinguishable from the hand-written
equivalent; and DAG scheduling over a sixteen-resource graph with a diamond,
fan-in, a redundant edge, a four-deep chain and cross-cloud edges, checked in
both directions by a checker that recomputes the edges independently.

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

- **Most of AWS** — Lambda, RDS, ECR, Secrets Manager and IAM have never been
  called. S3 and EC2 have; the rest have not.
- **`delete` is now partly exercised on AWS.** A live run created an SQS
  queue, converged, and deleted it — and then found a *library* bug on the way
  out: `pullEntries` assumed anything `list` returned still existed when it
  read it, so the post-delete refresh saw the queue in SQS's
  eventually-consistent listing, failed to read it, and aborted. Fixed; a
  resource that vanishes between list and read is now treated as absent, while
  a permission error still fails. `update` remains unexercised.
- **Every `update` and `delete` path, on both clouds.** The first live AWS run
  of the test attempted one and the harness, not the library, got in the way:
  it read SQS's listing immediately after creating and reported a
  non-convergence that was really propagation delay, then tore down against a
  world it could not see and left the queue behind while reporting success.
  Both directions poll now. `destroy` remains unverified against a real
  account. What is confirmed is
  creation and observation. Nothing here has been seen to modify or tear down
  a real resource, and `destroy` in particular is the least exercised code in
  the library relative to how much it can cost to get wrong.
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

## Known defects

Recorded in full in [`diff-semantics.md`](diff-semantics.md)'s ledger. The one
most likely to matter:

- **`Plan.outside` is declared and not consumed.** Scoping works through the
  key family instead, which is the mechanism to rely on.

Not a surprise waiting to be discovered; it is written down.

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
