# Architecture

## General goal

The goal of this project is to enable the definition of remote architectures within Lean, like Terraform/OpenTofu.
Objects are defined in Lean leveraging dependent types so that it should be impossible to define impossible states or target states.
Remote state, remote objects can be pulled from the remote service they live in.
A target state can be defined, to set the desired state of the remote system.
An engine can call the remote service to sync the current state and implement the target.
To implement a target, objects defining states should allow state diffs.
This is an object-level, structural diff computed over the Lean values themselves (which fields/objects differ and how), not a text/source-code diff of the `.lean` files they are defined in.

## Remote services

To start, we will target the following remote cloud providers:
- AWS: https://aws.amazon.com/
- Scaleway: https://www.scaleway.com/

Later we will support other clouds:
- GCP: 
- Azure: 
- OVH: 

## Coverage

We will start with the basic services:
- IAM
- Object store
- Compute
- Queues
- Secrets
- Image registry

With an emphasis on
- Serverless compute
- Serverless db
- Object store
- AI model

And on what's common to AWS and Scaleway

## Abstractions

Common concepts across services are abstracted, and these concepts can be manipulated and
implemented across various backends. It should still be possible to manipulate lower level
concepts, closer to the service provider.

Both halves of that are carried by one mechanism: `Kind` (`Infra/Core/Kind.lean`) and the spec
it dispatches to via `SpecOf` (`Infra/Specs/Basic.lean`).

**`SpecOf` is indexed by `Kind` alone, never by provider.** A spec is therefore
provider-independent, and the provider enters only at apply time through a `Backend`. The same
spec value can be used under any cloud — `Infra/Demo.lean` uses one `ObjectStoreSpec` under
both AWS and Scaleway to demonstrate exactly this.

`Kind` splits into two groups:

- **Portable kinds** — `iam`, `objectStore`, `compute`, `queues`, `secrets`, `imageRegistry`,
  `postgres`, matching the coverage list above. These are the cross-cutting abstractions. Being
  the common denominator constrains them: a portable spec carries **no cross-resource
  references at all**, because a reference has type `K p k` and so names a provider. `compute`
  is serverless-shaped for the same reason — a required subnet reference would make the kind
  undeployable on serverless functions.
- **Provider-local kinds** — `s3Bucket`, `securityGroup`, `awsInstance`, `scalewayFunction`,
  `scalewayContainer`. The escape hatch to concepts closer to one provider: richer, free to
  reference other resources, and not portable. `awsInstance` is where that freedom is used
  hardest — its `securityGroup` reference is *required*, which is exactly what the portable
  `compute` kind cannot have and why EC2 needs a kind of its own.

A provider that does not implement a kind sets that `(provider, kind)` pair's key type to
`Nothing`, so a plan **cannot mention** what its provider lacks. Non-portability is
unrepresentable rather than merely detected, and reaching for a provider-local kind makes the
loss of portability visible in the type.

Authentication is orthogonal to all of this and stays where it was —
`Infra/Core/Auth.lean` and `Infra/Abstractions/Auth.lean`, see `docs/authentication.md`.

### Where portability actually stops

Making a spec provider-independent does not make every *field* meaningful on
every cloud, and three kinds of exception have shown up in practice. All are
listed in `docs/providers.md`; the shapes are:

- **A field one cloud cannot express.** Reported `unknown` there, and by the
  rule in `docs/diff-semantics.md` `unknown` is never drift — so the target is
  accepted and the field quietly unenforced. `iam.policies` on Scaleway is the
  clearest case: AWS policy ARNs have no counterpart.
- **A field one cloud requires and the other has no concept of.** Optional in
  the spec, with the backend that needs it raising a named error.
  `compute.executionRole` (Lambda) and `compute.namespace'` (Scaleway
  Containers) point in opposite directions.
- **A field that turned out to be vestigial.** `compute.runtime` became
  advisory once compute was defined in terms of container images: the runtime
  is baked into the image and neither cloud reports it.

The alternative to naming these is a spec that looks portable and silently does
the wrong thing on one cloud.

### Secrets never live in a target

Two decisions follow from the target being the committed source of truth:
`secrets.valueFrom` names an *environment variable* (`SecretSource.fromEnv`),
and `postgres.masterPasswordSecret` names a *secret*. Neither field holds a
value.

There is one deliberate extension, `SecretSource.composed`, and it is worth
being precise about what it does and does not allow. A secret whose value is
built from post-apply state — a connection string needing both a master
password and the endpoint a cloud assigns at creation — used to require two
`apply` runs with an operator composing the string by hand in between.
A target can now hold the *function* instead, written as `map`/`ap` over
`Expr.secretValue` (another of the fleet's secrets) and `Expr.observed` (a
resource that does not exist yet). `HasDeps` turns both into ordering edges,
so one apply creates the password, then the database, then the secret that
reads them.

Because that composition is the whole point and its `map`/`ap` spelling is
pure plumbing, it is written the way `s!` is:

```lean
composed expr!"postgres://admin:{secretValueOf dbPassword}@{endpointOf mainDb}/main"
```

`expr!` (`Infra/Core/Compose.lean`) expands to exactly the `map`/`ap` chain,
so nothing is added to `Expr` and no evaluation rule changes. The applicative
restriction is not loosened, only made invisible — there is still nowhere in
the syntax to branch on an unknown value. `Infra/Demo.lean` keeps the
hand-written chain next to the `expr!` version and `#guard`s that they agree
on both their dependency edges and their evaluated string.

What that does **not** allow is a plaintext value in the committed file. It is
now *expressible* (`.lit (.composed "hunter2")`), so it is checked rather than
impossible: `SecretsSpec.sourceIsSound` rejects a composed value with no
dependencies, and `Plan.secretsAreSound` lifts it over a fleet. See
`docs/diff-semantics.md`'s ledger for the tier change, which was a real
weakening and is recorded as one.

Values are read in exactly two places, both narrow and both on the apply path:
`Kinds.Postgres.fetchMasterPassword` for database creation, and
`Backend.secretValue`, whose only caller is `Engine.settleFor`. Neither stores
what it reads. The planning path cannot reach either — `Env.secretValue`
defaults to knowing nothing and `actions` settles against a redacted
environment — so a dry run cannot print a secret because it never has one.
Nothing observed, cached, or reported carries a value either, which is also
why a composed secret can never be diffed: it is create-only.

## Fleets across several clouds

A fleet's key family is indexed by provider as well as kind
(`Keys.Key : ProviderId → Kind → Type`), so one target can hold resources in several clouds at
once, with references crossing between them. `Infra/Demo.lean` has a Scaleway function reading
from an AWS bucket in a single `Plan`.

## Declaring a fleet

A fleet needs a `Keys` (one `Finite`+`DecidableEq` key type per `(provider, kind)` pair) and a
`Plan` (a `Status` assignment total over that key type — see `docs/diff-semantics.md`).
`Infra/Demo.lean` builds both by hand: a bespoke `inductive` enum and a hand-proved `Finite`
instance per resource-set, a `(provider, kind) → key-type` match, a `name` match, and an
`assign` match arm per resource. That is a demonstration of what a `Keys`/`Plan` *are*, not the
recommended way to write one for a real project — it is proportionate ceremony for one demo
fleet and disproportionate for dozens of real resources.

There are three ways to write one, in increasing order of sugar. All produce
the same `Keys`/`Plan`, and all keep the same guarantees — see
`docs/diff-semantics.md`.

**1. By hand.** `Infra/Demo.lean`'s `demoKeys`/`demoPlan`, above. Use it when
you want the strongest form of "no duplicate keys": a hand-rolled `inductive`
key type gets that from constructor distinctness, unconditionally.

**2. With the combinators in `Infra/Core/Ergonomics.lean`.**
`Keys.build (table : ProviderId → Kind → KeySpec)` replaces the
`Key`/`finite`/`decEq`/`name` quadruple with one table, where each row is
either `.unused` (the pair's key type is `Nothing`) or `.named [ ... ]` (the
pair's key type is `NamedKey`, a generic `List String`-backed key generated
once rather than per resource-set). `Keys.assignFromNamed` similarly replaces
a hand-written `match` arm per resource with a name-indexed association list.
`Infra/Specs/Build.lean` gives one builder per `Kind` whose optional fields
default to `.unknown`, and `Infra/Core/Coe.lean` lets a bare value stand for
`.lit v` / `.known (.lit v)` — so a resource is one function call with the
fields you actually mean.

**3. With the `fleet` command** (`Infra/Core/Declare.lean`), which is the
recommended default for a consumer project:

```lean
fleet myFleet in paris where
  provider scaleway where
    resource secrets "db-password" as dbPassword
      { valueFrom := fromEnv "DB_PASSWORD" }
    resource postgres "main" as mainDb
      { masterUsername := "dbadmin", masterPasswordSecret := "db-password"
        minCapacity := 1, maxCapacity := 4 }
```

`in` is where the fleet is (above); `provider` writes the cloud once instead
of on every line. Both are optional and neither changes what is produced — a
`resource` outside a block names its own cloud, blocks and bare lines mix, and
`Infra/Demo.lean` declares one fleet three ways (by hand, bare `resource`
lines, `provider` block) and guards that the keys, names, plan and ordering
come out identical.

This exists for one reason the other two cannot address: a resource's name
would otherwise be written three or four times — a name list, a key
abbreviation, the spec's own `name` field, an `assign` entry — with only two
of them coupled by a check. Here the name list is derived from the resources.
It is the only piece of metaprogramming in the library, deliberately confined
to the `Keys`/`Plan` wiring, which genuinely cannot be a function because the
key type must exist before the specs that reference it and is itself derived
from them. Everything else stayed an ordinary function so that this could stay
small; it expands to the level-2 combinators, so errors point at your own
code. `Infra/Demo.lean` declares one fleet at both levels and `#guard`s that
the results agree.

## Where a fleet is

A fleet declares which region each of its clouds is in, alongside which
accounts it is for. Before this existed the region came from the credentials
and nowhere else — every endpoint in `Infra/Providers/Live.lean` is built from
`creds.region` — so the same committed file built a different system depending
on who ran it, and refused to run at all when `AWS_REGION` was unset.
`Infra/Core/Region.lean` closes both halves.

Two spellings, and the choice between them is the portability choice again:

- **A `Locality`** — `.paris` — is a place, named before any cloud names it.
  Each cloud maps it to its own code or to nothing: AWS's Paris is
  `eu-west-3`, Scaleway's is `fr-par`, and neither has a region in the
  other's Warsaw or Ireland. One `in paris` places both clouds correctly,
  which a region string could not.
- **A `Region p`** — `Region.of .aws "eu-west-3"` — is one cloud's own code,
  indexed by that cloud. The index stops an AWS region reaching Scaleway *by
  typing*; `Region.of` adds a decidable check that the code is one that cloud
  actually has.

Three mistakes are therefore compile errors rather than DNS failures, all by
the same `Assert`/`by decide` mechanism `NamedKey.of` uses:

| Mistake | Caught by |
|---|---|
| a place one of the fleet's clouds is not in | `Locality.covers` |
| a region code from the wrong cloud, or a typo in one | `Region.of` |
| a placement that leaves one of the fleet's clouds unplaced | `Regions.covering` |

The `fleet` command's optional `in` clause generates all of it:

```lean
fleet myFleet in paris where …                       -- both clouds' Paris
fleet myFleet in aws "eu-west-1", scaleway "fr-par" where …
```

An entry without a string is a locality and places every cloud; an entry with
one places that cloud, and may override a locality written before it. Omitting
`in` keeps the old behaviour — each cloud's region comes from its credentials,
and a cloud whose credentials carry none fails with a message naming all three
ways to supply it.

`knownRegions` is *derived* from the `Locality` table rather than written out
twice, so the two cannot drift; the cost is that a region no locality names —
GovCloud, or one added last week — needs `Region.raw`, which is spelled
differently precisely so that reaching past the table is visible.

**Placement is per cloud, not per resource.** Every endpoint for a cloud is
built from one region, which is the shape `Live.lean` already has, so a fleet
spanning two regions of the same cloud is not expressible. `S3BucketSpec` has
a `region` field that predates this and is *not* that mechanism: it is
compared against the region the bucket is reported in, and must agree with
where the fleet places AWS. See `docs/providers.md`.

## Values that are not really strings

Placement was one case of a wider shape, and `instanceType` is the second:
a spec field typed `String` whose inhabitants are actually drawn from a small
closed set the provider publishes. Written as a string, `"t3.nanoo"`
elaborates, plans, and fails at `RunInstances` — after the security group it
references has been created — and the author gets no help discovering what
`t3` even comes in.

`Infra/Core/InstanceType.lean` splits it the way AWS names it, into a family
and a size, and checks the *pair*:

```lean
instanceType := InstanceType.of .t3 .nano
```

Autocomplete lists the families, then the sizes, and `InstanceType.of .t3
.xlarge32` does not elaborate because `t3` has no `32xlarge`. Twenty-six
families share nine size lists between them, so the cross product covers 257
types from a table small enough to keep true — and the differences between
those nine lists (gen-7 Intel skips `32xlarge`; Gravitons before gen-8 stop at
`16xlarge`; bare metal is spelled `metal` on some families and `metal-24xl` on
others) are each stated once rather than three times.

The pattern generalises, and its three parts are worth naming because the next
such field should reuse them:

1. **A string underneath.** `InstanceType` wraps a `String`, so the backend
   hands it to the API and reads it back with no parse that can fail. The
   axes are how a value is *written*, not how it is stored — which is what
   keeps the read path total for a family the table has never heard of.
2. **A decidable check at the call site**, `Assert … := by decide`, the same
   auto-param `NamedKey.of` uses.
3. **A visibly-spelled escape hatch.** `InstanceType.raw` and `Region.raw`
   exist because both tables are snapshots of catalogues that grow. A stale
   table must cost the author a more conspicuous spelling, never a hard block.
   `AGENTS.md` records the obligation to check them against the providers'
   docs.

What this does *not* check is whether the type exists in the region the fleet
is placed in, or whether the account's quota allows it — see
`docs/diff-semantics.md`'s soft spots. `imageId` is deliberately left a string:
an AMI id is region- and account-specific and there is no table to check it
against.

## Declaring a fleet, continued

**This table is the scoping mechanism** the project's `AGENTS.md` calls for ("the ability to
scope what's managed vs. left alone"): a `(provider, kind)` pair left `.unused`, or a resource
name simply not listed under a pair that is used, has no key for `Plan.assign` to mention it
by — so whatever exists there in the cloud is left alone unconditionally, independent of
`Plan.outside` (see that field's status in `docs/diff-semantics.md`'s known soft spots). There
is no separate "unmanaged within a kind" flag, and none is needed.

## Basic local system services

Basic file manipulation, network, and other IO use:
- Lean standard lib
- and the latest release of Linen: https://github.com/typednotes/linen

## Definitions

There are 2 kinds of objects:
- Objects to define the current state of a remote system and cache it on disk
- Objects to define a target state

The idea is that each remote object can be defined locally in lean.
Each lean state object definition can be persisted locally.
A target state can be defined in a Lean source code and this code can be versioned in git.
Dependent types should be used wherever possible to make impossible states or target states non-representable.
Object defining the remote state or the state target can be diffed so the controller can use the diff to move to target: an object-level, structural diff over the Lean values, not a text/source-code diff of the `.lean` files.

Objects defining parts of the state or the target state:
- should be diff-able at their structure level,
- should be serializable/deserializable to/from JSON or JSONB.

How this is realized is set out in `docs/diff-semantics.md`. In short: the nominal axis (`Kind`)
and the refinement axis (`Partial`, ordered by `⊑`) are kept apart, a target is a *value* rather
than a type, and the design rule throughout is that an **unrealisable target should not be
representable**. That document's ledger records concretely which impossible states are ruled out
by typing, which are decidable `Assert` obligations, which are genuinely runtime, and where the
current soft spots are — so the aspiration on this page can be checked against what the code
actually delivers.

## Inspirations

Terraform/OpenTofu are sources of inspiration to the extend they don't use dependent types in their declaration language.

## Authentication

The original intent was that "basic authentication to a service happens by opening the browser."
That turned out not to be what either cloud wants: AWS and Scaleway are both driven by static
API keys, so the browser flow in `Infra/Core/Auth.lean` is built but unused.

What credentials actually do is a three-source chain — the CLIs' own config files, then the OS
keychain, then environment variables — resolved in `docs/authentication.md` and implemented in
`Infra/Core/Credentials.lean`.

Browser login has since been **decided against** rather than merely deferred. Scaleway has no
browser flow for programmatic credentials at all, and AWS's is IAM Identity Center, which the
account this targets does not use. `Infra/Core/Auth.lean` stays, but note that it sketches the
authorization-*code* flow, and AWS browser login is the *device authorization* grant — so it is
not the starting point it looks like. See `docs/authentication.md`'s "Still open".

Being authenticated is not the same as being pointed at the right place, so a fleet also states
which accounts it is for, and every live command verifies that before listing anything
(`Infra.Cli.Accounts`, `Kinds/Identity.lean`).

The account and the region are the two halves of "where is this about to build", and they are
declared alike but enforced differently. An API key *belongs* to one account and cannot be
pointed at another, so the account is **checked** against what the credentials report and a
mismatch is refused. Which region to build in is a free choice, so placement **overrides**
whatever region the credentials carry — see "Where a fleet is" above. `checkAccounts` prints
both on one line, because reading them apart is what let a fleet aimed at the right account in
the wrong region look fine.