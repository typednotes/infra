# Coverage in 0.2.0

What this version actually does, and — more usefully — how far each part has
been exercised. Everything below is the state on 2026-09-05.

This page is the canonical answer; the README and `docs/tutorial.md` link here
rather than repeating it, so there is one place to correct.

## Clouds

| Cloud | Status |
|---|---|
| **AWS** | implemented |
| **Scaleway** | implemented |
| GCP, Azure, OVH | not started — named in `docs/architecture.md` as intended, no code |

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

Two of the seven need no per-cloud code at all, because both clouds speak the
same API. That is the portability claim actually paying off rather than being
asserted.

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

### Verified offline, on every build

Signing against AWS's published SigV4 test vectors; both provider error
dialects; the divergence rules; `Content-MD5` for S3 configuration writes; the
credential chain and its redaction; composed secrets creating three resources
in one correctly-ordered apply with no value leaking into output or cache; that
the `fleet` command produces a fleet indistinguishable from the hand-written
equivalent; and DAG scheduling over a sixteen-resource graph with a diamond,
fan-in, a redundant edge, a four-deep chain and cross-cloud edges, checked in
both directions by a checker that recomputes the edges independently.

### Never run against any account

- **Most of AWS** — Lambda, RDS, ECR, Secrets Manager and IAM have never been
  called. S3 and EC2 have; the rest have not.
- **Every `update` and `delete` path, on both clouds.** What is confirmed is
  creation and observation. Nothing here has been seen to modify or tear down
  a real resource, and `destroy` in particular is the least exercised code in
  the library relative to how much it can cost to get wrong.
- **Ingress rules and tags** — `CreateSecurityGroup` succeeded, but whether
  `AuthorizeSecurityGroupIngress` applied the rules correctly, and whether tags
  land, is not established by a group merely existing.
- **Most endpoint shapes** — roughly 1,200 lines across `Kinds/*.lean`.
- **`scalewayContainer.secretEnv`** — how Scaleway actually binds a secret to
  an environment variable. Implemented against the plaintext-at-set-time
  assumption; if the real mechanism is a native reference, the backend
  simplifies and the types do not change.
- **Scaleway Serverless SQL Database** — honestly stubbed rather than guessed.

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
