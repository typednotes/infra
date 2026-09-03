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
- **Provider-local kinds** — `s3Bucket`, `scalewayFunction`. The escape hatch to concepts closer
  to one provider: richer, free to reference other resources, and not portable.

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
`push --apply` runs with an operator composing the string by hand in between.
A target can now hold the *function* instead, written as `map`/`ap` over
`Expr.secretValue` (another of the fleet's secrets) and `Expr.observed` (a
resource that does not exist yet). `HasDeps` turns both into ordering edges,
so one apply creates the password, then the database, then the secret that
reads them.

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
fleet myFleet where
  resource scaleway secrets "db-password" as dbPassword
    { valueFrom := fromEnv "DB_PASSWORD" }
  resource scaleway postgres "main" as mainDb
    { masterUsername := "dbadmin", masterPasswordSecret := "db-password"
      minCapacity := 1, maxCapacity := 4 }
```

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
`Infra/Core/Credentials.lean`. The browser flow stays for whenever AWS SSO or a Scaleway OAuth
flow is added.