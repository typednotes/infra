# Providers

How each `Kind` reaches each cloud, what is genuinely portable, and what is
known not to be.

## Layers

```
Infra/Providers/Live.lean          one Backend per cloud, dispatching on Kind
Infra/Providers/Kinds/*.lean       per-kind request shaping and response mapping
Infra/Providers/Aws/Protocols.lean the four AWS wire dialects
Infra/Providers/Aws/Sign.lean      SigV4, over Linen's Crypto.SigV4
Infra/Providers/Scaleway/Rest.lean Scaleway's own API
Infra/Providers/Http.lean          the single egress point: retries, timeouts, errors
```

Everything leaves through `Http.sendChecked`, which applies the retry policy
and turns a non-2xx into the provider's *own* code and message. Both dialects
are handled — AWS answers with an XML `<Error>`, Scaleway with JSON — and an
unparseable body keeps its text rather than vanishing. "403" alone is not a
diagnosis; `SignatureDoesNotMatch` is.

## Wire dialects

| Dialect | Shape | Used by |
|---|---|---|
| S3 (REST-XML) | bucket in the path, XML reply | object storage, `s3Bucket` |
| Query | `POST /` form body, XML reply | IAM, RDS, EC2 |
| AWS-JSON | `POST /` + `X-Amz-Target` | Secrets Manager, ECR, SQS |
| REST-JSON | method and path carry meaning | Lambda |
| Scaleway REST | `api.scaleway.com`, `X-Auth-Token` | everything Scaleway-native |

All four AWS dialects sign identically, which is why signing lives once in
`Aws/Sign.lean`.

## Coverage

All `(provider, kind)` pairs are implemented. `Live.lean` has no
catch-all: Lean reported one as unreachable, so adding a `Kind` now fails that
file to compile.

| Kind | AWS | Scaleway | Shared client? |
|---|---|---|---|
| `objectStore` | S3 | Object Storage | **yes** — one implementation |
| `queues` | SQS | Messaging & Queuing | **yes** — one implementation |
| `imageRegistry` | ECR | Container Registry | no |
| `secrets` | Secrets Manager | Secret Manager | no |
| `compute` | Lambda (image) | Serverless Containers | no |
| `iam` | IAM users | IAM applications | no |
| `postgres` | RDS | Managed Database | no — and routed on shape: a set `instanceClass` means a classic instance, capacity bounds mean serverless. Scaleway's Serverless SQL Database is implemented (`serverless-sqldb/v1alpha1`, capacity as `cpu_min`/`cpu_max`); AWS's Aurora Serverless v2 raises a named error, and GCP's Cloud SQL has no serverless tier at all, so it raises with the tier to set instead |
| `s3Bucket` | S3 | — | AWS-only kind |
| `securityGroup` | EC2 security groups | — | AWS-only kind |
| `awsInstance` | EC2 instances | — | AWS-only kind; the portable `compute` kind is serverless-shaped and cannot carry a required network reference |
| `scalewayFunctionNamespace` | — | Serverless Functions namespaces | Scaleway-only kind |
| `scalewayContainerNamespace` | — | Serverless Containers namespaces | Scaleway-only kind; creating one implicitly creates a Container Registry namespace, whose endpoint is observed |
| `scalewayFunction` | — | Serverless Functions | Scaleway-only kind |
| `scalewayContainer` | — | Serverless Containers | Scaleway-only kind; the portable `compute` kind cannot bind secret-backed env vars |

Two kinds — `objectStore` and `queues` — need no per-cloud code *between AWS
and Scaleway*, because Scaleway's endpoints are S3- and SQS-compatible. That is
the portability claim actually paying off, and `infra check` asserts it:
`S3.endpoint` differs only in host, and both sign service `s3`.

GCP is not in that sharing, and it is worth being exact about why rather than
leaving it as an omission. Cloud Storage does expose an S3-compatible API, but
it authenticates with HMAC keys — a credential obtained by hand in the console,
and never one this library holds, since every GCP credential here is a bearer
token. Pub/Sub is not SQS in any sense. So both kinds have a second
implementation for GCP (`Gcp.Storage`, `Gcp.PubSub`), and `objectStore` in
particular was silently routed to the S3 client until that was noticed.

## Every call names itself in a failure

Three clouds, three levels of helpfulness in an error, and the gap had to be
closed in this library rather than waited out.

Google is the good case: it names the API, the project, the resource, the
console page to enable it, and the propagation delay. AWS names an action code
and sometimes a regex. Scaleway's REST errors name neither product nor
operation (`403 permissions_denied: insufficient permissions`), and its
S3-compatible endpoint is worse still — `403 AccessDenied: Access Denied
(request txgc…)`, with no indication of which of a fleet's calls was refused.

So both transports prefix their failures with the call:

- `Scaleway.call` — `scaleway GET /iam/v1alpha1/applications: …`
- `Aws.call` — `s3 PUT s3.fr-par.scw.cloud/bucket-name: …`

`Aws.call` is the single chokepoint for every signed request in the library, so
one change covers S3, EC2, SQS, ECR, Secrets Manager, IAM, RDS and Lambda —
and Scaleway's S3-compatible endpoints, which is where it was actually needed.
The query string is included because the query-protocol services carry their
`Action` there; nothing secret does, since SigV4 signs in a header.

This is not cosmetic. Every Scaleway debugging round in this project so far has
turned on knowing *which call* was refused, and the first one that did not name
it cost the most.

## Scaleway listings are scoped to a project, and must be

A Scaleway collection endpoint with no `project_id` is evaluated against the
whole **organization**. Fourteen of them were unscoped, which caused two
problems of very different severity.

The visible one: a project-scoped credential is refused with
`403 permissions_denied`, and nothing in the message suggests that the *scope*
rather than the permission is at fault. That is how it was found — a CI
credential holding `AllProductsFullAccess` on one project could not list
secrets.

The dangerous one: an unscoped listing returns **other projects' resources**,
and `Infra.Core.pullEntries` matches a listed resource to a fleet key *by
name*. So a fleet in one project could adopt a same-named resource belonging to
another, diff it, and destroy it. This was measured rather than theorised: the
organization used for testing had two container-registry namespaces, both in a
different project from the fleet's, and an unscoped listing saw both.

`ci/check-scaleway-scoping.py` enforces it, with two deliberate exceptions —
`/runtimes` is a catalogue rather than a resource collection, and IAM
`/applications` is organization-scoped by nature.

Note this is a Scaleway-shaped hazard specifically. AWS scopes by the
credential's account and region implicitly; GCP puts the project in the path,
so an unscoped call is not expressible.

## Regions reach a backend through the credentials

Every endpoint builder in `Aws/Protocols.lean` and `Scaleway/Rest.lean` takes a
region string, and `Live.lean` supplies `creds.region` to all of them. That is
still true — placement did not add a second path. `Infra.Cli.liveFor` resolves
the fleet's declared region and **writes it into the `Credentials` value** it
hands to `liveBackend`, so one funnel keeps serving every kind and no backend
had to learn what a `Regions` is.

Two endpoints deliberately ignore it. `Query.iamEndpoint` and
`Query.stsEndpoint` are global and always sign `us-east-1`, whatever region is
in force; signing them regionally is a common and confusing mistake, so the
region is fixed in the builder rather than passed in.

A cloud the fleet does not place still reads its region from the credentials,
and `Credentials.requireRegion` is what turns a missing one into a message
naming all three ways to supply it, before any call is attempted.

### There is no per-resource region *field*

`s3Bucket` used to have a `region` field, and it was a trap. It did not place
the bucket — `createBucket` sends the location constraint from `ep.region`, the
endpoint the placement builds, and `read` reported that same value back — so
the field was only ever *compared*, on a `forcesReplace` row. `Fillable` filled
an unwritten one with `eu-west-1`, so any bucket in a fleet placed elsewhere
diverged on an immutable field and proposed a replacement that recreated it
exactly where it already was. It never converged, and `REPLACE` is
`DeleteBucket` first.

The field is removed. Placement is the one mechanism, and there is nothing left
that can disagree with it — the inconsistency is unrepresentable rather than
guarded against.

The *observed* region survives, in `S3BucketObserved.region`, which is where
the cloud says the bucket is. This is the same split Terraform's AWS provider
made in v6.0: an authored `region` that routes the call, and a read-only
`bucket_region` that reports where the thing actually is. Our placement plays
the role of their `region` argument; `S3BucketObserved.region` plays the role
of `bucket_region`.

One consequence worth knowing: **changing where a resource is placed does not
move it.** Listing happens per region, so a bucket whose block moved is not
found in the new region, the plan proposes a create there, and the old one is
left behind unmanaged — the same thing that happens when a resource is removed
from the declaration. Terraform has exactly this hole with provider aliases and
does not document it. `destroy` before re-placing is the safe path.

## What is not portable, and is not pretended to be

These are cases where a portable spec field has no counterpart on one cloud.
Each is reported `unknown` there, which by design never counts as drift — so
the target is accepted and the field quietly unenforced. Stating them plainly
is the point; a mapping that looked like it worked would be worse.

| Field | Unenforced on | Why |
|---|---|---|
| `imageRegistry.immutableTags` | Scaleway | no tag-immutability concept |
| `iam.policies` | Scaleway | AWS policy ARNs have no Scaleway equivalent; its policies are rule sets over permission sets and scopes |
| `compute.runtime` | both | vestigial under container images — baked into the image, reported by neither |
| `secrets.valueFrom` | both | names an environment variable the cloud has never heard of |
| `scalewayFunction.namespace'` | Scaleway | placement, not configuration: the API does not report which namespace a function is in, so it can never diverge — moving one between namespaces is not detected |
| `scalewayContainer.namespace'` | Scaleway | same |
| `postgres.masterPasswordSecret` | both | bookkeeping, never reported by the database |

Two fields point the opposite way — required by one cloud, meaningless to the
other. Both are optional in the spec, and the backend that needs one raises a
named error rather than passing through an unhelpful API message:

- `compute.executionRole` — Lambda requires an execution role ARN.
- `compute.namespace'` — Serverless Containers requires a namespace.

## EC2: what these two kinds do and do not do

Both are keyed by a name a person chooses, never by an AWS-assigned id, because
`Keys.name` has to be writable in the target before the resource exists
(`Engine.pullEntries` matches it against `observedHandle`). A security group is
keyed by `GroupName`; an instance by its **`Name` tag**, which `create` sets
immediately after `RunInstances`. The `sg-…` and `i-…` ids are post-apply
values and live in `ObservedOf`, which is where `delete` and `update` read them
from.

`awsInstance.securityGroup` is the library's **only required reference**. An
instance therefore always contributes a dependency edge, cannot be declared
without a group, and cannot be settled until that group exists — see
`example/ParisInstances.lean`.

Deleting an instance **waits** for it to reach `terminated` rather than just
issuing `TerminateInstances`, and the security-group delete retries while AWS
reports `DependencyViolation`. Both exist because a real `destroy` failed
without them: terminate is asynchronous, so ordering the instance first is
necessary but not sufficient — its network interface holds the group for a
while after the call returns. Bounded at a couple of minutes, then a named
error telling the operator to re-run.

Two deliberate limitations, both visible in a plan before anything is applied:

- **`instanceType` is `forcesReplace`.** EC2 can resize a *stopped* instance,
  but doing it in place means stop → poll until stopped → modify → start, a
  state machine this backend does not have. Replace is the honest description
  of what this tool will actually do, and the plan says REPLACE.
- **Ingress rules are only ever added.** `update` authorizes rules the target
  has and the cloud does not; revoking one the cloud has and the target does
  not is not implemented. The divergence is still *reported*, so a plan is
  honest about wanting a change it will only partly make.

Rules the spec cannot express — anything that is not a single TCP port with a
CIDR — are dropped by `read` rather than misreported, so `ingress` diverging
can also mean "the cloud has a rule this tool cannot see".

## Errors name the action, and the fixable ones name the fix

A provider's error is about a *request*, so on its own it identifies neither
the resource nor the verb. `Engine.runAction` wraps every backend call so a
failure reads

```
error: CREATE scaleway/scaleway-function/reindex failed: HTTP 400: invalid runtime
```

rather than `HTTP 400: invalid runtime`. One wrapper, so every kind and every
provider gets it. `Infra.Cli` reports failures rather than letting them escape
as `uncaught exception: …`, which read like a crash in the tool instead of a
refusal by a cloud, and exits 1.

Where a refusal has a knowable answer, the error fetches it. `invalid runtime`
is the clearest case: Scaleway names runtimes without punctuation
(`python311`, not `python3.12`), the set changes with versions, and
`/functions/v1beta1/regions/{region}/runtimes` lists it — so the error appends
what this region actually accepts.

## Namespaces are declared, not assumed

Serverless Functions and Serverless Containers each group their resources into
a namespace, and neither will place one into a namespace that does not exist.
That used to surface at apply time as

```
uncaught exception: scaleway functions: no namespace named 'typednotes'
```

because `namespace'` was a bare `String` and nothing created the thing it
named. It is now a **required reference** to a namespace resource in the same
fleet, so the namespace is declared, created first, and cannot be misspelled.

They are **two kinds, not one**, because Functions namespaces and Containers
namespaces are different products at different API prefixes
(`functions/v1beta1` and `containers/v1beta1`). Two kinds make pointing a
container at a functions namespace a type error rather than a 404. They share
one *spec shape*, since they are configured identically — `SpecOf` maps both
to `ScalewayNamespaceSpec`.

The portable `compute` kind keeps a `String` namespace, necessarily: a portable
spec carries no cross-resource references, which is the same reason `compute`
is serverless-shaped at all.

## S3 requires an integrity header on configuration writes

A bucket-configuration write with a body — `PutBucketVersioning`,
`PutBucketTagging` and relatives — is refused without `Content-MD5` or one of
the `x-amz-checksum-*` family:

```
HTTP 400 InvalidRequest: Missing required header for this request:
Content-MD5 OR x-amz-checksum-*
```

`S3.call` now adds `Content-MD5` (base64 of the body's MD5) whenever there is a
body. Note this is *not* the same thing as SigV4's `x-amz-content-sha256`,
which is a signing input rather than an integrity declaration, so having one
never satisfied the other — which is why signing was verified and these calls
still failed.

The digest is checked offline against `openssl dgst -md5 -binary | base64`
rather than against this implementation, because a *wrong* integrity header is
worse than a missing one: S3 would reject the body as corrupt instead of as
unsigned, which reads like a very different bug.

Found by running `cross-cloud apply` against a real account.

## Secrets only travel outward

`secrets.valueFrom` is a `SecretSource`. `fromEnv` names an environment
variable, read at apply time. `read` calls `DescribeSecret`, never
`GetSecretValue`, and reports `valueFrom := .fromEnv ""`, so plaintext never
enters a `Sighting` or the `.infra/` cache.

There are exactly two inbound paths, both narrow, both apply-time only:

- `Kinds/Postgres.fetchMasterPassword` — both RDS and RDB demand a master
  password at creation, and the spec holds only the secret's name.
- `Backend.secretValue` (`Kinds/Secrets.fetchValue`) — for a
  `SecretSource.composed` value, whose only caller is `Engine.settleFor`. It
  fetches only the secrets a spec actually names, so a fleet with no composed
  secrets never calls it.

Both fetch once, pass straight to a single create/update call, and never
return or store what they read. The planning path cannot reach either:
`Env.secretValue` defaults to knowing nothing and `actions` settles against a
redacted environment, so a dry run has no value to leak. The placeholder
backend returns a canary string, and `lake exe infra check` asserts it appears
in neither plan output, apply logs, nor the on-disk cache.

The consequence, in every case: **a value changed outside this tool is not
detected as drift.** Detecting it would mean holding plaintext in the engine,
which is a far worse trade than missing a drift. For a composed secret this
also means it is **create-only** — its value cannot be compared, so once it
exists a second apply asks for nothing, and rotation is an explicit act rather
than a reconciliation.

## Identity

`pullEntries` matches a listed resource to a fleet key by comparing the
resource's handle against `Keys.name`. So the handle is always a *name*.

- AWS mostly addresses resources by name already.
- SQS addresses queues by URL, so the name is the handle and the URL travels in
  `ObservedOf`.
- Scaleway addresses nearly everything by UUID, so its operations resolve
  name → id first. That costs an extra call per operation and keeps fleet keys
  readable instead of UUIDs.

## Running against real accounts

```
infra check            # offline self-checks; the default
infra refresh          # observe both clouds, cache to .infra/
infra plan             # what would change
infra push             # same as plan — a dry run
infra apply     # actually reconcile
```

Dry run is the default and performs **no** backend IO — it returns before
reaching one. `actions` derives deletions from the target, so a mistaken key
type or stale fleet definition could otherwise destroy live resources on a
first run.

Credentials come from the chain in `docs/authentication.md`. Scaleway
additionally needs `default_project_id`, and `iam` needs
`default_organization_id`.

## What is verified, and what is not

Verified offline, by `infra check`:

- **SigV4** against AWS's published test vectors — canonical request,
  string-to-sign, derived key and signature, each pinned separately.
- Both error dialects, and that an unparseable body survives.
- Divergence: `unknown` is not drift; a mutable difference is an update; an
  immutable one is a `replace`.
- `push` dry-run ordering, including that an AWS bucket is scheduled before the
  Scaleway function referencing it, and that a teardown reverses it.
- `Content-MD5` for S3 configuration writes, against `openssl`'s digests.
- The credential chain, redaction, and the not-found message.
- Composed secrets: three resources created in one apply, ordered so the
  composed secret comes after both the password it reads and the database
  whose endpoint it needs; no secret value in plan output, apply log, or the
  cache; and a second apply is a no-op, since a composed secret is create-only.
- That the `fleet` command produces a fleet indistinguishable from the
  hand-written equivalent — same cardinalities, providers, names, and ordered
  action list.

**Since verified against a real account, and this section said otherwise for
too long**: EC2. `example/ParisInstances.lean` was applied, and the cache holds
a real security group with its VPC and two instances with real ids and state
`running` — so `CreateSecurityGroup`, `RunInstances`, `DescribeSecurityGroups`
and `DescribeInstances` work as written. What is still unconfirmed is narrower:
whether `AuthorizeSecurityGroupIngress` applied the rules, whether
`CreateTags` lands, and the whole of `ModifyInstanceAttribute` and
`TerminateInstances`. AWS S3 creation is likewise confirmed, for both
`objectStore` and `s3Bucket`.

The paragraph below is what this file used to say, kept because the reasoning
still applies to everything that *has* not been run:

**Not verified against any account, and the newest of the lot**: every EC2
endpoint path, parameter name and response shape in `Kinds/Ec2.lean` —
`DescribeSecurityGroups`, `CreateSecurityGroup`,
`AuthorizeSecurityGroupIngress`, `DeleteSecurityGroup`, `DescribeInstances`,
`RunInstances`, `CreateTags`, `ModifyInstanceAttribute`, `TerminateInstances`.
The Query protocol itself is shared with RDS and IAM and its signing is
verified offline; the parameter names above are not. `RunInstances` resolves
the referenced group's name to an id via `DescribeSecurityGroups` first, so
that `SecurityGroupId` is used rather than the name-based parameter, which only
works in a default VPC — also unverified.

**Not verified against any account, and load-bearing for `secretEnv`**: how
Scaleway Serverless Containers actually binds a secret to an environment
variable. It is implemented against the plaintext-at-set-time assumption,
using the same narrowly-scoped read as everything else here, so if the real
mechanism turns out to be a native reference the backend simplifies and the
Lean types do not change. First thing to check live.

**Not verified**: Scaleway's Serverless SQL Database API shape, which is why
`Postgres.ServerlessSql` is honestly stubbed rather than guessed at, and
whether either cloud permits adjusting serverless capacity bounds in place
(assumed mutable, like `storageGb`).

**Not verified, and checked only against docs**: whether Serverless Containers
can pull from `ghcr.io` directly. Scaleway's documentation says public
external registries work but discourages them for production ("uncontrolled
rate limiting"), and does not support private ones at all — so
`typednotes-infra` mirrors its image into Scaleway Container Registry instead.
No live test has confirmed either half of that.

**Not verified here**: the endpoint paths, field names and payload shapes in
`Kinds/*.lean` and `Gcp/*.lean` — about 2,250 lines, counted rather than
recalled. Those can only be confirmed against real
accounts. Signing correctness is established; *what* is being signed is not.

**Verified against a real account**: Scaleway `.queues` — `list`, `create`,
`read`, via `example/ScalewayQueue.lean` and `example/ScalewayPull.lean`. Two
things were wrong until this was exercised live:

- the endpoint was `sqs.mnq.{region}.scw.cloud`, which does not resolve at
  all; the real host is `sqs.mnq.{region}.scaleway.com`
  (`Infra.Providers.Aws.Protocols.sqsEndpoint`).
- Scaleway's SQS-compatible API refuses the main Scaleway API key outright.
  It needs a *dedicated* credential, minted after a one-time activation call
  and cached in the OS keychain — see `Infra.Providers.Scaleway.Sqs`.

Both were plausible-looking and both failed hard against the real API, which
is exactly the risk this whole section exists to name for the other fifteen
`(provider, kind)` pairs.
