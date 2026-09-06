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
[![Lean](https://img.shields.io/badge/Lean-v4.33.1-blue)](https://leanprover.github.io/)
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

## What 0.3.0 covers

**3 clouds** (AWS, Scaleway, GCP) · **14 resource kinds** (7 portable, 7
provider-local) · every `(provider, kind)` pair implemented.

All seven portable kinds have live clients on **all three clouds** — on GCP:
Pub/Sub, Cloud Storage, Secret Manager, Artifact Registry, Cloud Run, IAM
service accounts and Cloud SQL. Full create-and-destroy round trips pass in
CI on **AWS** (9 resources, 7 kinds) and **Google Cloud** (8 resources, 6
kinds), each including a chain and a fan-out of dependencies. Scaleway passes
for `queues`; its remaining kinds are waiting on a CI re-run rather than on
code.

Two GCP limits are stated rather than papered over. A serverless `postgres`
declaration **raises**, because Cloud SQL has no capacity range that scales to
a floor and picking a tier from `minCapacity` would invent a bill you did not
write down. And `iam` reads the roles bound to a service account but refuses to
write them: granting a role on GCP is a read-modify-write of the whole
project's IAM policy, and getting that wrong removes other identities' access,
so a declared policy shows up in `plan` and is refused at apply with the
`gcloud` command that would bind it.

Verification varies by kind, and it is worth knowing which before you rely on
any one of them:

| | |
|---|---|
| Verified against a real account | Scaleway `list` for every kind and queues end to end; on AWS, S3 and EC2 `create` |
| Verified offline, every build | signing, diffing, DAG scheduling, credentials, composed secrets |
| **Never run against an account** | most of AWS (Lambda, RDS, ECR, Secrets Manager, IAM), every Google Cloud client but Pub/Sub, every `update` path — about 2,250 lines of endpoint shapes |

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
  (`leanprover/lean4:v4.33.1`).
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
rev = "main"
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
`.gitignore` that excludes the state cache, and adds CI for **GitHub Actions,
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
to lose.

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
lake exe infra refresh          # observe both clouds, cache to .infra/
lake exe infra plan             # show what would change, no changes made
lake exe infra plan --destroy   # show what tearing the fleet down would delete
lake exe infra apply            # actually reconcile
lake exe infra destroy          # delete everything the fleet declares
```

`destroy` reconciles against `Plan.absent` — the fleet's own keys, every one
declared `.absent`. That distinction matters: **deleting a resource from the
declaration does not delete it from the cloud.** `Plan.assign` is total over
the fleet's keys, so a removed resource has no key for anything to mention and
is simply left alone, still running. Saying `.absent` is what turns "I no
longer want this" into a DELETE, and deletions run in the reverse of creation
order so a resource goes before whatever it depends on.

`plan` never touches a cloud. Treat `apply` like you would `terraform apply`:
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
fleet exampleQueue where
  resource scaleway queues "infra-example"
    { visibilityTimeoutSec := 30 }
```

```
$ lake exe scaleway-queue          # offline: the plan, from placeholders
would CREATE scaleway/queues/infra-example
(dry run — pass --apply to execute)

$ lake exe scaleway-queue apply
CREATE scaleway/queues/infra-example ... ok
```

A real, billable resource in your Scaleway account — delete it from the Queues
console when you are done. Re-running `plan` afterwards prints `nothing to do`,
since the queue already matches the target. Note that *removing the line* only
un-manages the queue; it does not delete it.

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
- [`docs/authentication.md`](docs/authentication.md) — where credentials come from
- [`docs/persistence.md`](docs/persistence.md) — how observed state is cached
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
