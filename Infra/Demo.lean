import Infra.Providers
import Infra.Core.Ergonomics
import Infra.Core.Declare
import Infra.Core.Compose
import Infra.Core.Engine

/-
  A worked fleet, and the checks that the design claims actually hold.

  This module exists to *demonstrate* rather than to assert. The claims under test:

    * a spec is provider-independent — one `ObjectStoreSpec` value is used under both clouds
    * one `Plan` can span clouds, with a reference crossing between them
    * `unmanaged` is ⊥ — an all-`unmanaged` plan is satisfied by any world and asks for nothing
    * a plan cannot mention a `(provider, kind)` pair its fleet leaves as `Nothing`
-/

namespace Infra.Demo

open Infra.Core
open Infra.Specs

/-! ## Key types: one finite enumeration per `(provider, kind)` the fleet uses -/

inductive Bucket | assets | logs
  deriving Repr, DecidableEq

instance : Finite Bucket where
  elems := [.assets, .logs]
  complete := by intro a; cases a <;> simp
  nodup := by decide

inductive Fn | api
  deriving Repr, DecidableEq

instance : Finite Fn where
  elems := [.api]
  complete := by intro a; cases a <;> simp
  nodup := by decide

inductive Archive | cold
  deriving Repr, DecidableEq

instance : Finite Archive where
  elems := [.cold]
  complete := by intro a; cases a <;> simp
  nodup := by decide

/-- Everything not listed is `Nothing`, so the plan below literally cannot mention it. -/
@[reducible] def demoKey : ProviderId → Kind → Type
  | .aws,      .objectStore      => Bucket
  | .scaleway, .objectStore      => Bucket
  | .scaleway, .compute          => Fn
  | .aws,      .s3Bucket         => Archive
  | .scaleway, .scalewayFunction => Fn
  | _,         _                 => Nothing

def demoName : (p : ProviderId) → (k : Kind) → demoKey p k → String
  | .aws,      .objectStore,      .assets => "assets"
  | .aws,      .objectStore,      .logs   => "logs"
  | .scaleway, .objectStore,      .assets => "assets"
  | .scaleway, .objectStore,      .logs   => "logs"
  | .scaleway, .compute,          .api    => "api"
  | .aws,      .s3Bucket,         .cold   => "cold"
  | .scaleway, .scalewayFunction, .api    => "ingest"
  | _,         _,                 _       => ""

def demoKeys : Keys where
  Key    := demoKey
  finite p k := by cases p <;> cases k <;> exact inferInstance
  decEq  p k := by cases p <;> cases k <;> exact inferInstance
  name   := demoName

/-! ## Specs

  `bucketSpec` takes the key family as a parameter and never mentions a `ProviderId`, which is
  what makes it portable. It is used at `.aws` *and* at `.scaleway` in `demoPlan` below —
  the same value, both clouds. -/

def bucketSpec {K : ProviderId → Kind → Type} (nm : String) :
    ObjectStoreSpec K Partial (Expr K) where
  name       := nm
  versioning := true
  tags       := .unknown          -- not yet said; `Fillable` will default it

def apiSpec {K : ProviderId → Kind → Type} : ComputeSpec K Partial (Expr K) where
  name       := "api"
  runtime    := "python3.12"                 -- advisory; never compared
  image      := "rg.fr-par.scw.cloud/demo/api:latest"
  executionRole := .unknown                  -- AWS-only; Scaleway needs none
  namespace' := "demo"                       -- Scaleway placement
  handler    := .unknown
  memoryMb   := 512
  timeoutSec := .unknown
  env        := .unknown

/-! ## The plan

  Spans both clouds, and `ingestSpec.sourceBucket` points from a Scaleway function at an AWS
  bucket — a reference crossing clouds inside one target. -/

def ingestSpec : ScalewayFunctionSpec demoKey Partial (Expr demoKey) where
  name         := "ingest"
  runtime      := "python3.12"
  namespace'   := "demo"
  sourceBucket := some Archive.cold

def demoPlan : Plan demoKeys where
  assign
    | .aws,      .objectStore,      b => .present (bucketSpec (demoName .aws .objectStore b))
    | .scaleway, .objectStore,      b => .present (bucketSpec (demoName .scaleway .objectStore b))
    | .scaleway, .compute,          _ => .present apiSpec
    | .aws,      .s3Bucket,         _ =>
        .present { name := "cold", versioning := .unknown
                   objectLock := true, region := .unknown }
    | .scaleway, .scalewayFunction, _ => .present ingestSpec
    | _,         _,                 _ => .unmanaged
  outside := .unmanaged

/-- Every key `unmanaged`: ⊥ of the `Status` order, so satisfied by anything. -/
def idlePlan : Plan demoKeys where
  assign _ _ _ := .unmanaged
  outside := .unmanaged

/-! ## A second fleet: a composed secret, in one apply

  The fleet above is hand-rolled, to show what a `Keys`/`Plan` *is*. This one
  is written the way a real consumer project should write one — with
  `Infra.Core.Ergonomics`' combinators — and exists to exercise the thing
  hand-rolling cannot demonstrate: a secret whose value is *computed at apply
  time* from another secret's value and a resource that does not exist yet.

  A database URL needs the master password and the endpoint the cloud assigns
  on creation. Composing it by hand would mean two applies with an operator
  pasting a connection string in between. Instead the target holds the
  **function**, as `map`/`ap` over `.secretValue` and `.observed`, and
  `HasDeps` turns both references into ordering edges — so one apply creates
  the password, then the database, then the URL secret.

  Note what is *not* here: any plaintext. `dbUrl` names no value, and
  `secretsAreSound` below is what checks that mechanically. -/

def composedNames : List String := ["db-password", "db-url"]

def composedKeys : Keys := Keys.build fun
  | .scaleway, .secrets  => .named composedNames
  | .scaleway, .postgres => .named ["main"]
  | _,         _         => .unused

/-- Referenced by name, checked at elaboration: a typo here does not compile. -/
def dbPasswordKey : composedKeys.Key .scaleway .secrets :=
  NamedKey.of composedNames "db-password"
def dbUrlKey : composedKeys.Key .scaleway .secrets :=
  NamedKey.of composedNames "db-url"
def mainDbKey : composedKeys.Key .scaleway .postgres :=
  NamedKey.of ["main"] "main"

def mainDbSpec : PostgresSpec composedKeys.Key Partial (Expr composedKeys.Key) :=
  PostgresSpec.serverless "main" "dbadmin" "db-password" 1 4

/-- The composed value: the password supplies one hole, the not-yet-assigned
    endpoint the other, and neither is known when this is written down.

    `expr!` is `s!` for plan-time strings — it expands to the `map`/`ap` chain
    spelled out in `dbUrlExprByHand` below, which is kept alongside it so the
    guards can check the two agree. -/
def dbUrlExpr : Expr composedKeys.Key String :=
  expr!"postgres://dbadmin:{secretValueOf dbPasswordKey}@{endpointOf mainDbKey}/main"

/-- The same value, written out. Retained only as the thing `expr!` is checked
    against; a fleet should use `expr!`. -/
def dbUrlExprByHand : Expr composedKeys.Key String :=
  .ap (.map (fun pw (o : ObservedOf .postgres) =>
              s!"postgres://dbadmin:{pw}@{o.endpoint}/main")
            (.secretValue .scaleway dbPasswordKey))
      (.observed .scaleway .postgres mainDbKey)

def composedSecretsAssign :=
  Keys.assignFromNamed (κ := composedKeys) .scaleway .secrets
    [ ("db-password", .present { name := "db-password"
                                 valueFrom := fromEnv "DB_PASSWORD" })
    , ("db-url",      .present { name := "db-url"
                                 valueFrom := composed dbUrlExpr }) ]

def composedPostgresAssign :=
  Keys.assignFromNamed (κ := composedKeys) .scaleway .postgres
    [ ("main", .present mainDbSpec) ]

def composedPlan : Plan composedKeys where
  assign
    | .scaleway, .secrets,  key => composedSecretsAssign key
    | .scaleway, .postgres, key => composedPostgresAssign key
    | _,         _,         _   => .unmanaged
  outside := .unmanaged

def composedEmptyWorld : World composedKeys := worldOf []

/-- The same fleet, already applied: all three resources exist and match.

    Used to check that a composed secret is **create-only**. Its value cannot
    be compared (no cloud reports one), so once it exists there is nothing to
    reconcile and a second apply must ask for nothing. The optional reported
    fields are `unknown` — not observed — and `unknown` is never drift. -/
def composedAppliedWorld : World composedKeys :=
  worldOf
    [ ⟨.scaleway, .secrets, dbPasswordKey,
        { observed := { handle := ⟨"db-password"⟩, version := "1" }
          reported := { name := "db-password", valueFrom := .fromEnv "" } }⟩
    , ⟨.scaleway, .secrets, dbUrlKey,
        { observed := { handle := ⟨"db-url"⟩, version := "1" }
          reported := { name := "db-url", valueFrom := .fromEnv "" } }⟩
    , ⟨.scaleway, .postgres, mainDbKey,
        { observed := { handle := ⟨"main"⟩, endpoint := "main.db.invalid:5432" }
          reported := { name := "main", instanceClass := .unknown
                        masterUsername := "dbadmin", masterPasswordSecret := ""
                        version := .unknown, storageGb := .unknown
                        minCapacity := .unknown, maxCapacity := .unknown } }⟩ ]

/-! ## The same fleet again, via `fleet`

  `composedKeys`/`composedPlan` above are written by hand with the
  `Ergonomics` combinators. This declares what should be the *same* fleet with
  `Infra.Core.Declare`'s `fleet` command, so the guards below can check that
  the command is only sugar — that it produces a fleet indistinguishable from
  the one a person would write.

  Note `db-url` references `mainDb`, which is declared *after* it: every `as`
  abbreviation is emitted before any spec, so declaration order does not
  constrain reference order. -/

fleet viaMacro where
  resource scaleway secrets "db-password" as macroDbPassword
    { valueFrom := fromEnv "DB_PASSWORD" }
  resource scaleway secrets "db-url"
    { valueFrom := composed
        expr!"postgres://dbadmin:{secretValueOf macroDbPassword}@{endpointOf macroMainDb}/main" }
  resource scaleway postgres "main" as macroMainDb
    { masterUsername := "dbadmin"
    , masterPasswordSecret := "db-password"
    , minCapacity := 1
    , maxCapacity := 4 }

section MacroGuards

/- Same shape as the hand-written fleet: same buckets, same cardinalities,
   same names, same single cloud. -/
#guard viaMacro.keys.count .scaleway .secrets = composedKeys.count .scaleway .secrets
#guard viaMacro.keys.count .scaleway .postgres = composedKeys.count .scaleway .postgres
#guard viaMacro.keys.count .aws .secrets = 0
#guard viaMacro.keys.providers = composedKeys.providers
#guard viaMacro.keys.name .scaleway .secrets macroDbPassword = "db-password"

/- Same plan: the same number of actions, and the same ordered slots — which
   is what would break if the generated `HasDeps` edges differed, since the
   composed secret must still come last. -/
#guard (actions viaMacro.plan (worldOf [])).length
     = (actions composedPlan composedEmptyWorld).length
#guard ((actions viaMacro.plan (worldOf [])).map Action.slot)
     = ((actions composedPlan composedEmptyWorld).map Action.slot)

/- And the same soundness: no plaintext smuggled in by the expansion. -/
#guard viaMacro.plan.secretsAreSound

end MacroGuards

section ComposedGuards

/- Both references are found, and tagged for what they are read for: the
    password as a *value*, the database as a *handle*. The `.secretValue` tag
    is what tells the engine this action needs the one inbound plaintext path
    at all. -/
#guard dbUrlExpr.deps.length = 2
#guard dbUrlExpr.deps.any (fun d => d.2.2.2 == Need.secretValue)
#guard dbUrlExpr.deps.any (fun d => d.2.1 == Kind.postgres)

/- `expr!` must be sugar and nothing more: the same references, read for the
   same reasons, in the same order as the hand-written `map`/`ap` chain — and
   the same string once evaluated. `deps` is what the scheduler uses, so
   agreeing on it is what makes the ordering identical. -/
#guard dbUrlExpr.deps.map (fun d => (d.1, d.2.1, d.2.2.2))
     = dbUrlExprByHand.deps.map (fun d => (d.1, d.2.1, d.2.2.2))

/- Same value, too. Evaluated against an environment that supplies both
   unknowns, the two must produce the same string. -/
private def probeEnv : Env composedKeys.Key where
  observed p k _key :=
    match p, k with
    | .scaleway, .postgres => some { handle := ⟨"main"⟩, endpoint := "db.invalid:5432" }
    | _,         _         => none
  secretValue _ _ := some "s3cret"

#guard dbUrlExpr.eval? probeEnv = some "postgres://dbadmin:s3cret@db.invalid:5432/main"
#guard dbUrlExpr.eval? probeEnv = dbUrlExprByHand.eval? probeEnv

/- Three resources, three creates — in *one* apply. -/
#guard (actions composedPlan composedEmptyWorld).length = 3

/- No plaintext anywhere in the fleet. This is the decidable replacement for
    what used to be a structural guarantee. -/
#guard composedPlan.secretsAreSound

/- …and it actually rejects the two ways a plaintext value could be written:
    directly, and laundered through `map` so it is no longer a bare literal. -/
#guard ¬ ({ name := "leak", valueFrom := .lit (.composed "hunter2") } :
  SecretsSpec composedKeys.Key Partial (Expr composedKeys.Key)).sourceIsSound
#guard ¬ ({ name := "leak", valueFrom := composed (.lit "hunter2") } :
  SecretsSpec composedKeys.Key Partial (Expr composedKeys.Key)).sourceIsSound

/- An env-var reference is sound, and a composed value over real references is
    sound — so the check is not just refusing everything. -/
#guard ({ name := "ok", valueFrom := fromEnv "DB_PASSWORD" } :
  SecretsSpec composedKeys.Key Partial (Expr composedKeys.Key)).sourceIsSound
#guard ({ name := "ok", valueFrom := composed dbUrlExpr } :
  SecretsSpec composedKeys.Key Partial (Expr composedKeys.Key)).sourceIsSound

/- `Repr` must not print a composed value: this is what keeps one out of a
    stray trace or error message. -/
#guard ((toString (repr (SecretSource.composed "CANARY"))).splitOn "CANARY").length == 1

/- This fleet is Scaleway-only, so AWS is never authenticated or called. -/
#guard composedKeys.providers = [.scaleway]

end ComposedGuards

/-! ## Worlds -/

def emptyWorld : World demoKeys := worldOf []

/-- A world where the AWS `assets` bucket exists and matches its target.

    Its optional fields are `unknown` — the provider did not report them — and
    `unknown` is deliberately *not* drift. So this bucket needs no action, which
    is the case an extent-only comparison could never produce. -/
def partialWorld : World demoKeys :=
  worldOf [⟨.aws, .objectStore, .assets,
    { observed := { handle := ⟨"assets"⟩, url := "https://x.invalid" }
      reported := { name := "assets", versioning := .unknown, tags := .unknown } }⟩]

/-- The same bucket, but reporting versioning *off* while the target asks for
    it on. A mutable field, so this is an update. -/
def driftedWorld : World demoKeys :=
  worldOf [⟨.aws, .objectStore, .assets,
    { observed := { handle := ⟨"assets"⟩, url := "https://x.invalid" }
      reported := { name := "assets", versioning := .known false, tags := .known [] } }⟩]

/-- The AWS `cold` bucket exists with Object Lock off, while the target asks
    for it on. Object Lock can only be set at creation, so this cannot be
    repaired in place. -/
def immutableDriftWorld : World demoKeys :=
  worldOf [⟨.aws, .s3Bucket, .cold,
    { observed := { handle := ⟨"cold"⟩, arn := "arn:aws:s3:::cold", region := "eu-west-1" }
      reported := { name := "cold", versioning := .unknown
                    objectLock := .known false, region := .known "eu-west-1" } }⟩]

section Guards

-- `unmanaged` is ⊥: the idle plan is satisfied by every world, and asks for nothing.
#guard satisfies idlePlan emptyWorld
#guard satisfies idlePlan partialWorld
#guard (actions idlePlan emptyWorld).isEmpty
#guard (actions idlePlan partialWorld).isEmpty

-- The real plan is not yet realised, and every declared resource needs creating.
#guard !(satisfies demoPlan emptyWorld)
#guard (actions demoPlan emptyWorld).length = 7

-- One resource already exists *and already matches*, so it drops out of the
-- work-list entirely: six actions, not seven. This is the case that makes a
-- second apply come back empty, and the one an existence-only comparison could
-- never produce.
#guard (actions demoPlan partialWorld).length = 6

-- Extent is still unsatisfied, because six other resources are missing.
#guard satisfies demoPlan partialWorld = false

-- A mutable field that disagrees is an update; the count returns to seven.
#guard (actions demoPlan driftedWorld).length = 7
#guard (actions demoPlan driftedWorld).any fun
  | .update .aws .objectStore .assets => true
  | _ => false

-- An *immutable* field that disagrees is a replace, not a doomed update.
-- Object Lock can only be set when the bucket is created.
#guard (actions demoPlan immutableDriftWorld).any fun
  | .replace .aws .s3Bucket .cold => true
  | _ => false
#guard !((actions demoPlan immutableDriftWorld).any fun
  | .update .aws .s3Bucket .cold => true
  | _ => false)

-- The cross-cloud reference is discovered: a Scaleway function depends on an AWS bucket.
#guard (HasDeps.deps (S := ScalewayFunctionSpec) ingestSpec).length = 1
#guard (HasDeps.deps (S := ScalewayFunctionSpec) ingestSpec).any
         (fun d => d.1 = ProviderId.aws && d.2.1 = Kind.s3Bucket)

-- Portable specs have no references at all — by construction, not by oversight.
#guard (HasDeps.deps (S := ObjectStoreSpec) (bucketSpec (K := demoKey) "assets")).isEmpty
#guard (HasDeps.deps (S := ComputeSpec) (apiSpec (K := demoKey))).isEmpty

-- Cardinality is a compile-time number, even though every field inside may be `unknown`.
#guard demoKeys.count .aws .objectStore = 2
#guard demoKeys.count .scaleway .compute = 1
#guard demoKeys.count .aws .postgres = 0        -- `Nothing`: not in this fleet

/-
  NEGATIVE CHECKS — these are compile errors, recorded here rather than as passing guards
  because a guard can only witness what *does* elaborate.

    * A `(provider, kind)` pair the fleet leaves as `Nothing` has no key to write down, so
      `demoPlan` cannot mention `.aws .postgres` at all. Non-portability is unrepresentable,
      not merely detected.

        def bad : Plan demoKeys := { demoPlan with
          assign := fun | .aws, .postgres, key => .present ... }
        -- `key : Nothing`, so there is no case to write and nothing to assign.

    * Omitting a `Field .required` fails to elaborate — the structure literal is incomplete:

        def bad : ObjectStoreSpec demoKey Partial (Expr demoKey) :=
          { versioning := .unknown, tags := .unknown }
        -- error: field 'name' not provided

    * A key from the wrong kind is a type error, because `Handle` and `Key` are kind-indexed:

        def bad : Handle .secrets := (⟨"x"⟩ : Handle .objectStore)
-/

end Guards

end Infra.Demo
