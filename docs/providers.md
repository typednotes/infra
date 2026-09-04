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
| `postgres` | RDS | Managed Database | no — and routed on shape: a set `instanceClass` means a classic instance, capacity bounds mean serverless (AWS raises a named error; Scaleway's Serverless SQL Database is stubbed) |
| `s3Bucket` | S3 | — | AWS-only kind |
| `securityGroup` | EC2 security groups | — | AWS-only kind |
| `awsInstance` | EC2 instances | — | AWS-only kind; the portable `compute` kind is serverless-shaped and cannot carry a required network reference |
| `scalewayFunction` | — | Serverless Functions | Scaleway-only kind |
| `scalewayContainer` | — | Serverless Containers | Scaleway-only kind; the portable `compute` kind cannot bind secret-backed env vars |

Two kinds need no per-cloud code at all, because both clouds speak the same
API. That is the portability claim actually paying off, and `infra check`
asserts it: `S3.endpoint` differs only in host, and both sign service `s3`.

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
infra pull             # observe both clouds, cache to .infra/
infra plan             # what would change
infra push             # same as plan — a dry run
infra push --apply     # actually reconcile
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
  Scaleway function referencing it.
- The credential chain, redaction, and the not-found message.
- Composed secrets: three resources created in one apply, ordered so the
  composed secret comes after both the password it reads and the database
  whose endpoint it needs; no secret value in plan output, apply log, or the
  cache; and a second apply is a no-op, since a composed secret is create-only.
- That the `fleet` command produces a fleet indistinguishable from the
  hand-written equivalent — same cardinalities, providers, names, and ordered
  action list.

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
`Kinds/*.lean` — roughly 1,200 lines. Those can only be confirmed against real
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
