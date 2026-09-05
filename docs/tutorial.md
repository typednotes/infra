# Tutorial

A guided path from an empty directory to a fleet running in two clouds. Every
snippet here compiles; the design reasoning behind each feature lives in the
documents linked at the end.

## The idea in one page

A **fleet** is an ordinary Lean value describing the resources you want. You do
not write steps. You write the destination, and the engine works out the route:

1. **observe** what actually exists in your accounts (`refresh`),
2. **diff** that against what you declared,
3. **reconcile** — create what is missing, update what drifted, replace what
   cannot be updated in place, delete what you declared absent.

That much is Terraform's model too. What differs is where mistakes are caught.
A reference to a resource that does not exist, a resource in a cloud that has
no such service, a region a cloud is not in, an instance size that does not
exist, a plaintext password in the committed file — none of these are runtime
errors here. Most are type errors, and the rest are decided while the file
elaborates. The compiler is the first line of defence, not a validation pass
that runs later.

Two consequences worth internalising before you start:

- **Removing a `resource` line does not delete anything.** It removes the key,
  and an unkeyed resource is *unmanaged* — it keeps running and keeps billing.
  Deletion is `destroy`, which reconciles against "everything absent".
- **A bare invocation is offline.** It plans against placeholder backends: no
  credentials, no network, no charges. You have to ask for the real thing.

> **Before you invest much in it:** this is early software. Two clouds, 14
> resource kinds, and a maturity that varies a lot by kind — notably, *no AWS
> call in this library has ever been made against a real account*.
> [`coverage.md`](coverage.md) is the honest breakdown, and worth two minutes
> before you go further.

---

## 1. A project

You need [`elan`](https://github.com/leanprover/elan) and a Lean toolchain.
Three files:

`lean-toolchain`

```
leanprover/lean4:v4.33.1
```

`lakefile.lean`

```lean
import Lake
open Lake DSL

package «my-infra» where
  version := v!"0.1.0"

require infra from git "https://github.com/typednotes/infra" @ "main"

@[default_target]
lean_exe «my-infra» where
  root := `Main
```

> **Note.** `infra` links native code (SigV4, TLS, the OS keychain) through
> [`linen`](https://github.com/typednotes/linen). Lake does not propagate a
> dependency's `moreLinkArgs` to a dependent's executable, so you will need to
> copy the platform link-flag block from `infra`'s own `lakefile.lean`. See
> that file's header comment — it explains what each flag is for.

Then `lake update` once to fetch the dependency.

## 2. Your first fleet

`Main.lean`

```lean
import Infra

open Infra.Core
open Infra.Specs

fleet myFleet in paris where
  provider scaleway where
    resource objectStore "my-first-bucket"
      { versioning := true
      , tags       := [("project", "tutorial")] }

def main (args : List String) : IO UInt32 :=
  Infra.Cli.run "my-infra" myFleet.plan
    (regions := myFleet.regions) (args := args)
```

That is a complete, working declaration. Build and run it:

```
$ lake build
$ lake exe my-infra

would CREATE scaleway/object-store/my-first-bucket
(dry run — nothing changed)

That was the placeholder backend — no cloud was contacted.
For the real thing: `plan` (reads), then `apply` (changes).
```

Nothing was contacted and nothing was charged. Read the four pieces:

- `fleet myFleet` declares the fleet and generates `myFleet.keys`,
  `myFleet.plan` and `myFleet.regions`.
- `in paris` says where it lives — see §5.
- `provider scaleway where` names the cloud once for everything under it.
- `resource objectStore "my-first-bucket"` is one resource: its **kind**, its
  **name**, and the fields you care about. The name is the cloud's real
  identifier, and it is written exactly once.

Fields you do not mention are not "set to a default and enforced" — they are
simply not spoken about, and whatever the cloud has stays. That distinction is
the whole of `docs/diff-semantics.md`.

## 3. Credentials

Three sources, tried in order, first hit wins:

1. the CLIs' own config files — `~/.aws/credentials` + `~/.aws/config`,
   `~/.config/scw/config.yaml`
2. the OS keychain (service `infra`, account `aws` / `scaleway`)
3. environment variables

```
export SCW_ACCESS_KEY=…  SCW_SECRET_KEY=…  SCW_DEFAULT_PROJECT_ID=…
export AWS_ACCESS_KEY_ID=…  AWS_SECRET_ACCESS_KEY=…
```

You do **not** need `AWS_REGION` or `SCW_DEFAULT_REGION` if your fleet declares
where it is, which the one above does.

Only the clouds your fleet actually uses are authenticated. A Scaleway-only
fleet never reads AWS credentials and never calls AWS — that falls out of the
key family, not from a flag.

### Refusing to run in the wrong account

Being authenticated is not the same as being pointed at the right place. State
which accounts the fleet is for, and every live command checks before touching
anything:

```lean
def accounts : Infra.Cli.Accounts where
  expect
    | .aws      => some "123456789012"
    | .scaleway => some "your-org-uuid"

def main (args : List String) : IO UInt32 :=
  Infra.Cli.run "my-infra" myFleet.plan
    (accounts := accounts) (regions := myFleet.regions) (args := args)
```

Neither value is a secret — an AWS account id appears in every ARN — and they
belong in the repo that declares the fleet. If you cannot hardcode them, use
`← Infra.Cli.Accounts.fromEnv`, which reads `INFRA_EXPECT_AWS_ACCOUNT` and
`INFRA_EXPECT_SCALEWAY_ORG`.

## 4. The five commands

```
lake exe my-infra                # check (default) — offline, free
lake exe my-infra refresh        # observe the clouds, cache what is there
lake exe my-infra plan           # what would change — reads, changes nothing
lake exe my-infra apply          # actually reconcile
lake exe my-infra plan --destroy # what tearing it down would delete
lake exe my-infra destroy        # delete everything this fleet declares
```

`check` and a bare invocation are the same thing and are always safe. `plan`
reads your accounts. `apply` and `destroy` change them.

Observed state is cached under `.infra/<exe>/` — one directory per executable,
so two fleets cannot read each other's state. Add `.infra/` to `.gitignore`.

## 5. Where it runs

`in paris` is a **locality** — a place, named before any cloud names it. Each
cloud maps it to its own code, so one word places every cloud correctly:

| locality | AWS | Scaleway |
|---|---|---|
| `paris` | `eu-west-3` | `fr-par` |
| `amsterdam` | — | `nl-ams` |
| `ireland` | `eu-west-1` | — |

A dash means that cloud is not there, and asking for it is a compile error
rather than a DNS failure. You can also name a cloud's own code directly:

```lean
fleet myFleet in aws "eu-west-1", scaleway "fr-par" where …
```

Codes are checked too: `Region.of .scaleway "eu-west-3"` does not elaborate.
For a region the built-in table does not know — a brand-new one, or GovCloud —
`Region.raw` takes it on trust, and is spelled differently on purpose.

### Per-resource placement

Blocks nest and scope like a `with` in Python:

```lean
fleet spread in paris where
  provider aws where
    resource s3Bucket "eu-assets"
      { versioning := true, region := "eu-west-3" }

    in nVirginia where
      resource s3Bucket "us-east-assets"
        { versioning := true, region := "us-east-1" }

  provider scaleway where
    in amsterdam where
      resource objectStore "nl-cache" { versioning := true }
```

**Indentation is load-bearing** — a resource belongs to a block only while
indented past its keyword. Precedence is strictly innermost-wins:

```
innermost `in` block  →  outer `in` block  →  fleet-level `in`  →  credentials
```

Only the regions your fleet actually names are ever listed during a refresh, so
a single-region fleet costs exactly what it always did.

> **One mechanism only.** A resource has no region field of its own to
> disagree with the block around it. `s3Bucket` used to carry one, which did
> not place anything and was only compared — so a bucket declared without it
> proposed a replacement that could never converge. It is gone; the blocks are
> the only thing that places anything.

## 6. One resource referring to another

Give a resource an `as` name and other resources can point at it:

```lean
fleet web in paris where
  provider aws where
    resource securityGroup "web" as webGroup
      { description := "http from anywhere"
      , ingress     := ([(80, "0.0.0.0/0")] : List (Nat × String)) }

    resource awsInstance "web-1"
      { imageId       := "ami-0d3c032f5934e1b41"
      , instanceType  := InstanceType.of .t3 .nano
      , securityGroup := webGroup }
```

A reference is an index into *this fleet's own keys*, which rules out three
mistakes without any check running:

- **a dangling reference** — there is no "not found" case to handle;
- **a reference to the wrong kind** — a bucket key is a different type;
- **a reference to the wrong cloud** — keys are indexed by provider too.

**Ordering falls out of it.** The group is created before the instance because
the instance references it, not because of the order you wrote them in.
References may point *forward*, and deletion runs the graph in reverse. The
scheduler handles arbitrary DAGs — diamonds, fan-in, chains, edges crossing
clouds — and rejects cycles by name.

## 7. Secrets

A secret's *value* never appears in the fleet. You name where it comes from:

```lean
resource secrets "db-password" as dbPassword
  { valueFrom := fromEnv "DB_PASSWORD" }
```

For a value that can only be known after other resources exist — a connection
string needing both a password and an endpoint the cloud assigns at creation —
write the *function*:

```lean
resource postgres "main" as mainDb
  { masterUsername       := "dbadmin"
  , masterPasswordSecret := "db-password"
  , minCapacity          := 1
  , maxCapacity          := 4 }

resource secrets "db-url"
  { valueFrom := composed
      expr!"postgres://dbadmin:{secretValueOf dbPassword}@{endpointOf mainDb}/main" }
```

Both references become ordering edges, so **one `apply`** creates the password,
then the database, then the secret that reads them — no second run, no
operator pasting a connection string in between. The value is never known to
the file, the plan output, or the on-disk cache.

A plaintext value is *expressible* and therefore *checked* rather than
impossible: `#guard myFleet.plan.secretsAreSound` rejects a composed value with
no dependencies. Put that line in your fleet file.

## 8. What is managed, and what is left alone

**Only what you name.** A `(provider, kind)` pair you never mention has no key
for the plan to talk about, and a name not listed under a pair you do use is
equally invisible. Whatever else exists in your accounts is left alone
unconditionally — there is no "unmanaged" flag, and none is needed.

To manage some buckets and not others, list only the ones you manage.

## 9. Errors you will actually hit

These are the compiler's own messages.

**A place your cloud is not in.** Scaleway has a Warsaw region; AWS does not,
so `in warsaw` fails for any fleet that uses AWS:

```
Tactic `decide` proved that the proposition
  Assert (Locality.warsaw.covers keys)
is false
```

**An instance size that does not exist.** `t3` stops at `2xlarge`:

```
Tactic `decide` proved that the proposition
  Assert (InstanceFamily.t3.sizes.contains InstanceSize.xlarge32)
is false
```

**A missing required field.** Lean reports a *function* where a spec was
expected, and the binder names what is missing:

```
Type mismatch
  fun securityGroup => Build.awsInstance …
has type
  Expr ?m (?m ProviderId.aws Kind.securityGroup) → AwsInstanceSpec …
```

A lambda where a resource belongs means a required field was left out.

**A resource naming only a kind, outside a `provider` block:**

```
this resource names only a kind, so it needs a provider: write
`resource <provider> objectStore …`, or put it inside a `provider … where` block
```

**A typo in a resource name used as a reference** — `NamedKey.of` checks it
against the fleet's own list at elaboration, so it is a compile error, not a
runtime `none`.

## 10. Reading the real examples

Each of these is a working executable, and the header of each is the lesson:

| file | what it shows |
|---|---|
| `example/ScalewayQueue.lean` | the smallest complete fleet |
| `example/ParisInstances.lean` | required references, and what cannot be written |
| `example/CrossCloud.lean` | one fleet in two clouds, a reference crossing between |
| `example/MultiRegion.lean` | nested `provider`/`in` blocks, four regions |
| `example/ScalewayPull.lean` | reading an account without declaring anything |
| `Infra/Demo.lean` | the same fleet written three ways, with the guards proving they agree |

All but `ScalewayPull` run offline and free with a bare invocation.

## Where to go next

The design documents explain *why*, and are worth reading before extending
anything:

- [`coverage.md`](coverage.md) — what this version covers and how far each part
  has been exercised
- [`architecture.md`](architecture.md) — the overall design, portability rules,
  and placement
- [`diff-semantics.md`](diff-semantics.md) — how target and observed state are
  compared, and the **ledger** of what is a compile error, what is decidable,
  what is runtime, and what the current soft spots are
- [`providers.md`](providers.md) — how each kind maps onto each cloud's API,
  and what has actually been verified against a live account
- [`authentication.md`](authentication.md) — the credential chain
- [`persistence.md`](persistence.md) — the on-disk cache

If something here did not work, the ledger in `diff-semantics.md` is the honest
list of what is not finished — it is kept current deliberately, including the
parts that are embarrassing.
