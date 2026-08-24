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
| Query | `POST /` form body, XML reply | IAM, RDS |
| AWS-JSON | `POST /` + `X-Amz-Target` | Secrets Manager, ECR, SQS |
| REST-JSON | method and path carry meaning | Lambda |
| Scaleway REST | `api.scaleway.com`, `X-Auth-Token` | everything Scaleway-native |

All four AWS dialects sign identically, which is why signing lives once in
`Aws/Sign.lean`.

## Coverage

All sixteen `(provider, kind)` pairs are implemented. `Live.lean` has no
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
| `postgres` | RDS | Managed Database | no |
| `s3Bucket` | S3 | — | AWS-only kind |
| `scalewayFunction` | — | Serverless Functions | Scaleway-only kind |

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

## Secrets only travel outward

`secrets.valueFrom` names an environment variable, read at apply time. `read`
calls `DescribeSecret`, never `GetSecretValue`, so plaintext never enters a
`Sighting` or the `.infra/` cache.

There is exactly one exception, `Kinds/Postgres.fetchMasterPassword`: both RDS
and RDB demand a master password at creation, and the spec holds only the
secret's name. The value is fetched once, passed straight to the create call,
and never returned or stored.

The consequence, in both cases: **a value changed outside this tool is not
detected as drift.** Detecting it would mean holding plaintext in the engine,
which is a far worse trade than missing a drift.

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

**Not verified here**: the endpoint paths, field names and payload shapes in
`Kinds/*.lean` — roughly 1,200 lines. Those can only be confirmed against real
accounts. Signing correctness is established; *what* is being signed is not.
