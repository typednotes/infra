# infra

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

## Project status

Early and evolving. The core engine (`Kind`/`SpecOf`/`Plan`/`push`) is
exercised by offline self-checks on every commit, and a couple of Scaleway
examples are exercised against a real account by hand (see below). Coverage
across `Kind`s and providers is uneven — check
[`docs/providers.md`](docs/providers.md) for what is actually confirmed
against a live API versus implemented against best-guess field names and
flagged as unverified. Breaking changes to the Lean API should be expected
before a first tagged release.

## Requirements

- [`elan`](https://github.com/leanprover/elan) (Lean's toolchain manager) —
  `lean-toolchain` pins the exact version this project builds with
  (`leanprover/lean4:v4.33.1`).
- Linux or macOS. Native FFI dependencies for `libpq`, OpenSSL headers, and
  the OS keychain (`libsecret` on Linux, Keychain on macOS) — see the
  `lean_action_ci.yml` install steps for the exact packages if `lake build`
  fails looking for a header.

## Build

```sh
lake build
lake exe infra check   # offline self-checks; no cloud, no credentials needed
```

## Running against real accounts

`infra` needs credentials for both clouds — see
[`docs/authentication.md`](docs/authentication.md) for the config file /
keychain / environment-variable chain it tries, in that order.

```sh
lake exe infra check     # offline self-checks (default, no cloud)
lake exe infra refresh   # observe both clouds, cache to .infra/
lake exe infra plan      # show what would change, no changes made
lake exe infra apply     # actually reconcile
```

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

Read its header before applying: the AMI id is unverified, the *region* comes
from your credentials rather than the declaration, and the EC2 backend has
never been run against a real account.

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

- [`docs/architecture.md`](docs/architecture.md) — overall design and the portability rules
- [`docs/authentication.md`](docs/authentication.md) — where credentials come from
- [`docs/persistence.md`](docs/persistence.md) — how observed state is cached
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
