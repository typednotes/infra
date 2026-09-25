<p align="center">
  <img src="assets/logo-wordmark.svg" alt="infra" width="300">
</p>

<p align="center">
  <em>Infrastructure as code, in Lean 4 — an unrealisable target is a compile error.</em><br>
  <a href="https://typednotes.github.io/infra/">Website</a> ·
  <a href="docs/tutorial.md">Tutorial</a> ·
  <a href="docs/coverage.md">Coverage</a>
</p>

[![CI](https://github.com/typednotes/infra/actions/workflows/lean_action_ci.yml/badge.svg)](https://github.com/typednotes/infra/actions/workflows/lean_action_ci.yml)
[![Lean](https://img.shields.io/badge/Lean-v4.34.0-blue)](https://leanprover.github.io/)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

Terraform/OpenTofu-style infrastructure as code, defined in Lean instead of a
bespoke DSL. Target and observed cloud state are dependently-typed Lean
values, so an unrealisable target is a compile error rather than a runtime
surprise.

- **One portable spec, many clouds.** A resource declared with a portable
  `Kind` (object store, compute, queues, secrets, Postgres, ...) can be
  pushed to AWS or Scaleway without change — the provider only enters at
  apply time, through a `Backend`.
- **Provider-local escape hatches.** When a portable abstraction can't carry
  a provider-specific field, a `Kind` scoped to that one provider (e.g.
  Scaleway's `scalewayFunction`, `scalewayContainer`) fills the gap without
  weakening the portable kind's guarantees.
- **Diffing is a Lean function, not a side effect.** Plan vs. observed state
  is compared structurally over the Lean values themselves; `plan` prints
  what it would do and only `apply` changes anything.

See [`docs/architecture.md`](docs/architecture.md) for the full design and
the portability rules.

## What 0.18.0 covers

**3 clouds** (AWS, Scaleway, GCP) · **15 resource kinds** (8 portable, 7
provider-local) · every `(provider, kind)` pair implemented.

All the portable kinds have live clients on **all three clouds** — on GCP:
Pub/Sub, Cloud Storage, Secret Manager, Artifact Registry, Cloud Run, IAM
service accounts and Cloud SQL. Create-and-destroy round trips run in CI on
**all three clouds** — AWS 12 resources, Scaleway 12, Google Cloud 10,
covering thirteen of the fifteen kinds and 22 (cloud, kind) pairs. Each leg
applies five declarations in sequence: the whole fleet, a scale up, a scale
down, a version with resources dropped, then one that declares nothing. After
every stage the account must hold exactly what that stage declares, so a
dropped resource has to be *destroyed* rather than abandoned. The five-stage
sequence has not yet been passed honestly on any cloud: the 2026-09-08 runs
found two defects, both fixed and neither re-verified — `docs/coverage.md`
says what each run showed. All three
dependency patterns are exercised live: a
chain, a fan-out, and a fan-in through both key and expression references.

One GCP limit is stated rather than papered over: a serverless `postgres`
declaration **raises**, because Cloud SQL has no capacity range that scales to
a floor and picking a tier from `minCapacity` would invent a bill you did not
write down.

`iam` used to be a second such limit — it read the roles bound to a service
account and refused to write them, because granting a role on GCP is a
read-modify-write of the whole project's IAM policy and getting that wrong
removes other identities' access. It writes them now, and the care is in the
method rather than in a refusal: the policy object is *edited* rather than
rebuilt, so `etag`, `auditConfigs` and anything unrecognised pass through
untouched; the `etag` travelling with it makes a concurrent edit fail the call
instead of clobbering it; and a binding carrying an IAM `condition` is left
strictly alone, reported by `plan` and refused at apply, because `policies`
cannot express the condition and rewriting it would change what it means.

Verification varies by kind, and it is worth knowing which before you rely on
any one of them:

| | |
|---|---|
| Verified against a real account | a three-stage sequence on **all three clouds**: 32 resources across 11 of the 14 kinds, created, converged, partly dropped, and destroyed. Stage 2 deletes resources whose lines are *gone* from the declaration, so it cannot pass unless membership works |
| Verified offline, every build | signing, diffing, DAG scheduling, credentials, composed secrets, that the marker decides (orphans found and destroyed, nothing else), dump round-trip and replay, fleet isolation and naming, `forget` releasing (unmarking, not deleting), orphans found on a cloud no longer declared, orphan recheck and retry, and that a sweep deletes only what it created |
| **Never run against an account** | AWS Lambda and RDS, Scaleway's `postgres` and `scalewayFunction`, GCP Cloud SQL — the kinds a test cannot arrange. Most `update` paths: only `queues` has one that runs, and only on two clouds |

It converts both ways: `toHcl` writes `.tf` from a fleet (with real HCL
references, and a `# TODO` for anything HCL cannot express), and
`fleetOfState` reads `terraform show -json` back into a fleet declaration.

[`docs/coverage.md`](docs/coverage.md) is the full breakdown — kinds, features,
what is verified how, and the known defects. It is kept current deliberately,
including the parts that are embarrassing.

Early and evolving: breaking changes to the Lean API should be expected before
a first tagged release.

## Requirements

- [`elan`](https://github.com/leanprover/elan) (Lean's toolchain manager) —
  `lean-toolchain` pins the exact version this project builds with
  (`leanprover/lean4:v4.34.0`).
- Linux or macOS. Native FFI dependencies for `libpq`, OpenSSL headers, and
  the OS keychain (`libsecret` on Linux, Keychain on macOS) — see the
  `lean_action_ci.yml` install steps for the exact packages if `lake build`
  fails looking for a header.

## Start a project

An infra project is an ordinary Lean project with one dependency, so it starts
the ordinary way. `lake init`, add the dependency, then one command turns it
into a declaration repository:

```sh
lake init my_infra && cd my_infra
```

Add `infra` to the `lakefile.toml` Lake just wrote:

```toml
[[require]]
name = "infra"
git = "https://github.com/typednotes/infra"
rev = "v0.18.0"
```

Then:

```sh
lake update                # fetch infra
lake exe infra init        # turn this project into an infra project
lake build
lake exe my_infra          # offline plan — free, no credentials
lake exe my_infra plan     # read your real accounts, change nothing
lake exe my_infra apply    # make it so
```

`lake exe infra` runs the scaffolder straight out of the dependency, so there
is nothing to install and nothing to keep on your `PATH`.

**What `infra init` does to the project.** It adds `Fleet.lean` (the
declaration you edit), `Catalogue.lean` (every resource kind, declared once,
to copy from), rewrites Lake's stub `Main.lean` to run the fleet, adds a
`.gitignore` for Lake's build output, and adds CI for **GitHub Actions,
GitLab CI, CircleCI, Azure Pipelines and Jenkins** — each with the same
plan/apply split, so a plan runs on every push and an apply waits for a person
to press the button. Delete the ones you do not use. It writes only what is
absent and names what it kept, so it is safe to re-run and safe on a project
with work in it. Your own libraries and executables are preserved.

`Catalogue.lean` is **compiled and never applied**: `Main.lean` runs
`Fleet.plan` and nothing else, so nothing in it is created or billed. Compiling
it is the point — commented-out examples drift from the API and nothing
notices, whereas these are type-checked by your own `lake build` against the
version of `infra` you actually depend on. Delete the file when it stops being
useful; nothing imports it.

It also **converts `lakefile.toml` to `lakefile.lean`**, keeping the original
as `lakefile.toml.replaced-by-infra`. That conversion is not cosmetic: the
native link flags are computed on the build machine by running `pkg-config`,
which TOML cannot express, and they are not optional because Lake does not
propagate a dependency's `moreLinkArgs`. Without them the link fails on
undefined symbols from the FFI. If the TOML contains anything the converter
does not recognise it refuses and says so, rather than rewriting a lakefile on
a guess.

Your declaration is a Lean program, so `lake exe my_infra` *is* the CLI —
there is no separate binary to keep in step with your code, and no state file
to commit: what is managed is marked on the resources themselves and read from
the cloud on every run, and nothing is stored locally. `dump` writes what a run
sees, without secret values. See `docs/persistence.md`.

### Starting from nothing

`infra new <dir>` does all of the above *and* the `lake init`, for a directory
that does not exist yet:

```sh
lake exe infra new my_infra   # from any project that has infra
cd my_infra && lake update && lake build
```

Both commands produce the same project. `new` is the shortcut when there is
nothing there yet; `init` is the one to use on a project that already exists.

## Build this repository

```sh
lake build
lake exe infra check   # offline self-checks; no cloud, no credentials needed
lake test              # the test driver, offline
```

## Running against real accounts

`infra` needs credentials for both clouds — see
[`docs/authentication.md`](docs/authentication.md) for the config file /
keychain / environment-variable chain it tries, in that order.

```sh
lake exe infra check            # offline self-checks (default, no cloud)
lake exe infra plan             # show what would change, no changes made
lake exe infra plan --destroy   # show what tearing the fleet down would delete
lake exe infra apply            # actually reconcile
lake exe infra apply --force    # reconcile even if that destroys most of the fleet
lake exe infra destroy          # delete everything carrying the fleet's marker
lake exe infra destroy --keep-data  # ...except databases, their histories and buckets
lake exe infra apply --refresh-secrets  # also rewrite secrets whose value went stale
lake exe infra dump [FILE]      # JSON snapshot of what the fleet sees, no secrets
```

**Deleting a resource from the declaration destroys it.** A resource is yours
if it carries the marker this tool writes on everything it creates, it is
inside the realm your declaration names, and it is not on the exclusion list.
The marker's value is the **fleet's name**, which every fleet has: `fleet
typednotes` is named `typednotes`, `fleet crossCloud` is `cross-cloud` (the
identifier in kebab-case), and `boundary := { fleetName := some "…" }`
overrides it. So two fleets sharing an account read each other's resources as
foreign and leave them alone. A live command refuses a name that cannot be a
marker value on every cloud (1–63 lowercase letters, digits, `-`, `_`,
starting with a letter), and renaming the declaration renames the fleet: its
resources then read as foreign and are left alone, never destroyed, until
`fleetName` pins the old name.

Every cloud and kind reports that evidence, on one of three rungs: a tag, or —
where the object has no tags but one writable free-text field — a marker
written into its `description`, or, for the two Scaleway products with
neither, the resource's own name against a prefix: the fleet's name and a
hyphen (`typednotes-…`) by default, replaced by `namePrefix` / `namePrefixes`
if you set them. A resource whose line you deleted is found by its marker —
`plan` and `apply` ask the cloud for everything carrying this fleet's marker,
in every region and kind of every cloud the fleet declares or names in
`accounts` — so deleting a line destroys the resource from any machine, a
fresh CI runner included; nothing local is consulted, because nothing local is
kept. And the rule runs the other way too: only a resource carrying this
fleet's marker is ever changed or destroyed, so a declared name held by
something else is foreign — its changes are dropped with a warning. A
resource carrying `managed-by-infra=true`, the value unnamed fleets wrote
before 0.17.0, matches no fleet: it is warned about by name, with the retag
that brings it back, and never touched. Saying
`.absent` within the declaration does the same thing; `destroy` is `apply`
against an empty declaration. All three end at the same call, and deletions
run in the reverse of creation order so a resource goes before whatever it
depends on.

Nothing about that needs committing, which is deliberate: membership is a
consequence of applying, not a statement of intent, so CI never has to write
back to your branch. `Infra/Core/Ownership.lean` records the reasoning, and
which way each rule fails. `dump` writes what a run sees — every resource with
its ownership evidence and observed state, the undeclared ones the next apply
destroys, the forgotten ones it releases, the foreign ones, the warnings,
never a secret value — and the same JSON replays as in-memory backends for
tests. It is a record, never an input. The cases that can still strand an
orphan are enumerated in `docs/coverage.md`: a resource on the name rung named
outside the fleet's prefix (there is no marker on it), and anything on a cloud
named neither in the declaration nor in `accounts` — that cloud is not
scanned. So to retire a cloud, delete its lines but keep it in `accounts`
until the apply that empties it, then drop it from `accounts`.

To stop managing something *without* destroying it, say so:

```lean
forget aws queues "old-queue"
```

It is checked: a `forget` for something the fleet still declares does not
compile. The next apply **releases** the resource — removes this fleet's
marker and leaves everything else as it was; the plan shows `RELEASE
aws/queues/old-queue` — after which it is no fleet's and the `forget` line can
be deleted. The two Scaleway kinds whose name is their marker (Serverless SQL
databases, queues) cannot be unmarked, so a `forget` line for one of them has
to stay for as long as the resource exists. For `postgresMigrations` a delete
is already a forget: it prints FORGET and touches nothing.

Resources you never marked are untouched throughout. They carry no marker of
this fleet's, so nothing here can claim them.

`plan` never changes a cloud. Treat `apply` like you would `terraform apply`:
read the plan first. Output is coloured by verb when stdout is a terminal —
green to create, yellow to update, magenta to replace, red to delete — and
plain when piped, so a redirect or a CI step summary stays free of escape
codes. `NO_COLOR` disables it, `FORCE_COLOR` forces it on.

## Examples

### Pulling Scaleway state alone

`example/ScalewayPull.lean` is a smaller, self-contained slice: authenticate
to **Scaleway only** (no AWS credentials read or required), pull whatever the
account reports for every `Kind`, and write it to `out/scaleway/` — once as
JSON, once as elaborable Lean source.

```
$ lake exe scaleway-pull
authenticating to Scaleway...
authenticated (region fr-par)
  object-store: 2 resource(s) -> out/scaleway/object-store.json, out/scaleway/object-store.lean
  compute: 1 resource(s) -> out/scaleway/compute.json, out/scaleway/compute.lean
done: 3 resource(s) across every kind Scaleway reported
```

Only Scaleway credentials are needed for this one — `~/.config/scw/config.yaml`,
the OS keychain, or `SCW_ACCESS_KEY`/`SCW_SECRET_KEY` (see
`docs/authentication.md`). Output lands under the gitignored `out/`, so it is
safe to inspect and delete.

### Declaring and pushing a Scaleway queue

`example/ScalewayQueue.lean` is the counterpart to the one above: instead of
listing what already exists, it declares a target and reconciles it. It is also
the shortest file in the repo, and deliberately so — the whole declaration is:

```lean
fleet exampleQueue in paris where
  resource scaleway queues "example-queue-jobs"
    { visibilityTimeoutSec := 30 }
```

```
$ lake exe scaleway-queue          # offline: the plan, from placeholders
would CREATE scaleway/queues/example-queue-jobs
(dry run — nothing changed)

$ lake exe scaleway-queue apply
CREATE scaleway/queues/example-queue-jobs ... ok
```

A real, billable resource in your Scaleway account. A Scaleway queue can carry
no tag, so its only marker is its name, checked against the fleet's prefix —
by default the fleet's name and a hyphen, here `example-queue-` from `fleet
exampleQueue`. That is why the queue is named `example-queue-jobs`: it is
managed like everything else — deleting the line or `lake exe scaleway-queue
destroy` deletes it. A `forget` line keeps it, and since a name cannot be
unmarked, that line stays for as long as the queue exists.

### Two instances behind a security group

`example/ParisInstances.lean` is the one to read for what the types actually
buy. `AwsInstanceSpec.securityGroup` is a **required** reference, so an
instance with no security group, one naming a group outside the fleet, and one
naming something that is not a group are all compile errors — the file quotes
the three messages verbatim. The group is scheduled before both instances
because of that reference, not because of the order it is written in.

```
$ lake exe paris-instances
would CREATE aws/security-group/web
would CREATE aws/aws-instance/web-1
would CREATE aws/aws-instance/web-2
```

Read its header before applying: the AMI id is unverified and the EC2 backend
has never been run against a real account. The *region* is declared —
`fleet paris in paris where …` puts it in `eu-west-3`, so `AWS_REGION` is
neither read nor needed, and the same file no longer builds a different fleet
for each operator who runs it.

### One fleet across four regions

`example/MultiRegion.lean` places resources per *resource* rather than per
cloud, with blocks that nest and scope like a `with` in Python:

```lean
fleet spread in paris where
  provider aws where
    resource s3Bucket "eu-assets" { versioning := true }   -- the fleet's Paris
    in nVirginia where
      resource s3Bucket "us-east-assets" { versioning := true }
  provider scaleway where
    in amsterdam where
      resource objectStore "nl-cache" { versioning := true }
```

One `in paris` reaches both clouds with each one's own code; a block overrides
only what is nested inside it; and a resource placed where its cloud has no
region — a Scaleway one inside `in oregon` — is a compile error. The regions a
pull has to list are derived from the declaration, so a single-region fleet
still lists once.

### One fleet across both clouds

`example/CrossCloud.lean` puts the same portable `objectStore` declaration
under both clouds, Object Lock on the AWS-only `s3Bucket`, and a Scaleway
function that reads the AWS bucket — a reference crossing clouds, which is what
orders the bucket first.

```
$ lake exe cross-cloud
would CREATE aws/object-store/typednotes-assets
would CREATE aws/s3-bucket/typednotes-archive
would CREATE scaleway/object-store/typednotes-assets
would CREATE scaleway/scaleway-function/reindex
```

The only example needing *both* clouds' credentials to run live. S3 bucket
names are globally unique, so change them before applying.

### All three share one entry point

A bare invocation is offline: it plans against the placeholder backends, needs
no credentials and creates nothing. `plan` reads the real account; `apply`
changes it. That is `Infra.Cli.run`, the same front end `infra`'s own
binary and a consumer repo both use — the examples deliberately contain no
argument parsing, credential loading or backend wiring of their own.

Any of them will refuse to touch the wrong account if you say which you expect:

```sh
export INFRA_EXPECT_AWS_ACCOUNT=<id>
export INFRA_EXPECT_SCALEWAY_ORG=<id>
```

```
$ lake exe cross-cloud plan
aws: account 123456789012 ok
scaleway: organization 4d7c630f-… ok
```

## Documentation

Start here:

- [`docs/coverage.md`](docs/coverage.md) — **what this version actually does**,
  and how far each part has been exercised
- [`docs/tutorial.md`](docs/tutorial.md) — **getting started**: an empty
  directory to a fleet in two clouds, with the commands, credentials,
  placement, references and secrets explained in order. Every snippet in it
  compiles.

Then the design documents, which explain *why* and are worth reading before
extending anything:

- [`docs/architecture.md`](docs/architecture.md) — overall design and the portability rules
- [`docs/internals.md`](docs/internals.md) — **how it works**: the pipeline
  from source to API call, the type stack, the scheduler, and the membership
  mechanism, with diagrams. The one to read before changing the engine
- [`docs/authentication.md`](docs/authentication.md) — where credentials come from
- [`docs/permissions.md`](docs/permissions.md) — **what those credentials must
  be allowed to do**: the AWS actions each kind calls, an adaptable operator
  policy, and why the ownership marker needs two grants per kind rather than one
- [`docs/persistence.md`](docs/persistence.md) — why nothing is stored
  locally, the two local records that used to be, and why membership is not
  intent
- [`docs/branding.md`](docs/branding.md) — the logo, the colours, and the
  trademark policies that constrain them
- [`docs/ci-auth.md`](docs/ci-auth.md) — how CI authenticates without storing
  a key, for AWS and GCP, with the policies in [`ci/`](ci/)
- [`CHANGELOG.md`](CHANGELOG.md) — what changed, and when
- [`docs/providers.md`](docs/providers.md) — how each `Kind` maps onto each cloud's API, and what is actually verified live
- [`docs/diff-semantics.md`](docs/diff-semantics.md) — how target vs. observed state is compared

## Contributing

Issues and PRs are welcome — this is early-stage, so a design discussion
before a large PR will save rework. When extending a `Kind`, grep for its
existing cases first: every provider/kind pair is a total match across
several files by design (`Infra/Core/Kind.lean`, `Infra/Specs/Basic.lean`,
`Infra/Core/Action.lean`, `Infra/Core/Diverge.lean`,
`Infra/Core/Settle.lean`, `Infra/Providers/Live.lean`,
`Infra/Providers/Placeholder.lean`), so a missed site is a compile error
rather than a silent gap.

This project depends on [`linen`](https://github.com/typednotes/linen) for
its native (FFI-backed) building blocks — SigV4 signing, TLS, the OS
keychain. If something you need is missing there, propose the addition to
`linen` directly rather than working around it here.

## License

Apache License 2.0 — see [`LICENSE`](LICENSE).
