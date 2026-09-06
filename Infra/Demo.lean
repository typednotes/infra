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

/-- The namespace the demo function is placed into. Now a resource in its own
    right: `scalewayFunction.namespace'` is a reference, so the fleet has to
    declare the namespace rather than naming it in a string. -/
inductive Ns | demo
  deriving Repr, DecidableEq

instance : Finite Ns where
  elems := [.demo]
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
  | .scaleway, .scalewayFunctionNamespace => Ns
  | .scaleway, .scalewayFunction => Fn
  | _,         _                 => Nothing

def demoName : (p : ProviderId) → (k : Kind) → demoKey p k → String
  | .aws,      .objectStore,      .assets => "assets"
  | .aws,      .objectStore,      .logs   => "logs"
  | .scaleway, .objectStore,      .assets => "assets"
  | .scaleway, .objectStore,      .logs   => "logs"
  | .scaleway, .compute,          .api    => "api"
  | .aws,      .s3Bucket,         .cold   => "cold"
  | .scaleway, .scalewayFunctionNamespace, .demo => "demo"
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
  runtime      := "python311"
  namespace'   := Ns.demo
  sourceBucket := some Archive.cold

def demoPlan : Plan demoKeys where
  assign
    | .aws,      .objectStore,      b => .present (bucketSpec (demoName .aws .objectStore b))
    | .scaleway, .objectStore,      b => .present (bucketSpec (demoName .scaleway .objectStore b))
    | .scaleway, .compute,          _ => .present apiSpec
    | .aws,      .s3Bucket,         _ =>
        .present { name := "cold", versioning := .unknown
                   objectLock := true }
    | .scaleway, .scalewayFunctionNamespace, _ =>
        .present { name := "demo", description := "the demo fleet's functions" }
    | .scaleway, .scalewayFunction, _ => .present ingestSpec
    | _,         _,                 _ => .unmanaged

/-- Every key `unmanaged`: ⊥ of the `Status` order, so satisfied by anything. -/
def idlePlan : Plan demoKeys where
  assign _ _ _ := .unmanaged

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

/-! ## And a third time, with the cloud written once

  Same fleet again, with `provider` grouping the three resources instead of
  each line naming Scaleway for itself.

  `provider` is grouping, not a mode: it changes where the identifier is
  written and nothing else, so this must be indistinguishable from `viaMacro`
  — same buckets, same names, same plan, same ordering. The guards below are
  what say so, and are why the block form can be recommended without
  qualification. -/

fleet viaBlock where
  provider scaleway where
    resource secrets "db-password" as blockDbPassword
      { valueFrom := fromEnv "DB_PASSWORD" }
    resource secrets "db-url"
      { valueFrom := composed
          expr!"postgres://dbadmin:{secretValueOf blockDbPassword}@{endpointOf blockMainDb}/main" }
    resource postgres "main" as blockMainDb
      { masterUsername := "dbadmin"
      , masterPasswordSecret := "db-password"
      , minCapacity := 1
      , maxCapacity := 4 }

section BlockGuards

/- Identical to `viaMacro` in every way the rest of the library can observe:
   the buckets and their order, the names, and the scheduled plan. -/
#guard viaBlock.names.scaleway.secrets = viaMacro.names.scaleway.secrets
#guard viaBlock.names.scaleway.postgres = viaMacro.names.scaleway.postgres
#guard viaBlock.keys.providers = viaMacro.keys.providers
#guard viaBlock.keys.count .scaleway .secrets = viaMacro.keys.count .scaleway .secrets
#guard viaBlock.keys.count .scaleway .postgres = viaMacro.keys.count .scaleway .postgres

/- Same plan and same ordering — including the composed secret still coming
   last, which is the part that would break if a reference crossing the block
   boundary were resolved differently. -/
#guard ((actions viaBlock.plan (worldOf [])).map Action.slot)
     = ((actions viaMacro.plan (worldOf [])).map Action.slot)

#guard viaBlock.plan.secretsAreSound

end BlockGuards

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
-- The ordered slot lists agreeing implies the counts do, so only the stronger
-- claim is stated.
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
#guard dbUrlExpr.deps.any (fun d => d.need == Need.secretValue)
#guard dbUrlExpr.deps.any (fun d => d.kind == Kind.postgres)

/- `expr!` must be sugar and nothing more: the same references, read for the
   same reasons, in the same order as the hand-written `map`/`ap` chain — and
   the same string once evaluated. `deps` is what the scheduler uses, so
   agreeing on it is what makes the ordering identical. -/
#guard dbUrlExpr.deps.map (fun d => (d.provider, d.kind, d.need))
     = dbUrlExprByHand.deps.map (fun d => (d.provider, d.kind, d.need))

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
                    objectLock := .known false } }⟩]

section Guards

-- `unmanaged` is ⊥: the idle plan is satisfied by every world, and asks for nothing.
#guard satisfies idlePlan emptyWorld
#guard satisfies idlePlan partialWorld
#guard (actions idlePlan emptyWorld).isEmpty
#guard (actions idlePlan partialWorld).isEmpty

-- The real plan is not yet realised, and every declared resource needs creating.
#guard !(satisfies demoPlan emptyWorld)
-- Eight now: the demo fleet declares the namespace its function sits in.
#guard (actions demoPlan emptyWorld).length = 8

-- One resource already exists *and already matches*, so it drops out of the
-- work-list entirely: six actions, not seven. This is the case that makes a
-- second apply come back empty, and the one an existence-only comparison could
-- never produce.
#guard (actions demoPlan partialWorld).length = 7

-- Extent is still unsatisfied, because six other resources are missing.
#guard satisfies demoPlan partialWorld = false

-- A mutable field that disagrees is an update; the count returns to seven.
#guard (actions demoPlan driftedWorld).length = 8
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

-- Two references, and they are the two kinds of edge worth having: the bucket
-- it reads, in the *other* cloud, and the namespace it is placed into, in this
-- one. Both are discovered from the spec rather than declared as an order.
#guard (HasDeps.deps (S := ScalewayFunctionSpec) ingestSpec).length = 2
#guard (HasDeps.deps (S := ScalewayFunctionSpec) ingestSpec).any
         (fun d => d.provider = ProviderId.aws && d.kind = Kind.s3Bucket)
#guard (HasDeps.deps (S := ScalewayFunctionSpec) ingestSpec).any
         (fun d => d.kind = Kind.scalewayFunctionNamespace)

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

/-! ## Scheduling: a DAG the easy cases would not catch

  `orderActions` is Kahn's algorithm, and the fleets above exercise it only in
  its easy shapes — short chains whose declaration order is already
  topological. This section is the hard shape: a diamond, a fan-in of three, a
  redundant edge that duplicates a path already implied, a four-deep chain,
  edges through three different kinds, and one crossing clouds.

  The point is not the fleet but the **checker**: `isTopological` recomputes
  every edge from `HasDeps` and verifies the emitted order against them, rather
  than trusting the scheduler's own notion of what depends on what. A bug that
  dropped an edge would satisfy the scheduler and fail here.

  Composed secrets are what make an arbitrary graph writable at all: a
  `secretValueOf` may name any other secret, so secret→secret edges can be
  wired into any shape. -/

fleet dagFleet in paris where
  provider scaleway where
    resource secrets "root" as dagRoot { valueFrom := fromEnv "ROOT" }
    -- Referenced by nothing and referencing nothing: an isolated node must
    -- still be scheduled, not dropped.
    resource secrets "iso" as _dagIso { valueFrom := fromEnv "ISO" }

    -- Fan-out of three from one root...
    resource secrets "b" as dagB { valueFrom := composed expr!"b={secretValueOf dagRoot}" }
    resource secrets "c" as dagC { valueFrom := composed expr!"c={secretValueOf dagRoot}" }
    resource secrets "d" as dagD { valueFrom := composed expr!"d={secretValueOf dagRoot}" }

    -- ...fanning back in, plus a *redundant* direct edge to the root, which
    -- the three paths above already imply. A scheduler that mishandled a
    -- duplicated dependency would show up here.
    resource secrets "sink" as dagSink
      { valueFrom := composed
          expr!"{secretValueOf dagB}|{secretValueOf dagC}|{secretValueOf dagD}|{secretValueOf dagRoot}" }

    -- A chain off the sink, so the graph has depth as well as width.
    resource secrets "tail1" as dagT1 { valueFrom := composed expr!"1={secretValueOf dagSink}" }
    resource secrets "tail2" as dagT2 { valueFrom := composed expr!"2={secretValueOf dagT1}" }
    resource secrets "tail3" as dagT3 { valueFrom := composed expr!"3={secretValueOf dagT2}" }

    -- Edges through a different kind, in both directions: the database needs
    -- a secret for its password, and a secret needs the endpoint the database
    -- does not have until it exists.
    resource postgres "db" as dagDb
      { masterUsername := "admin", masterPasswordSecret := "root"
      , minCapacity := 1, maxCapacity := 4 }
    resource secrets "dburl" as _dagUrl
      { valueFrom := composed expr!"u={secretValueOf dagT3}@{endpointOf dagDb}" }

    -- Key-typed payload references rather than `Expr` ones: a different
    -- `HasDeps` path (`depsKey`/`depsKeys`) reaching the same scheduler.
    resource scalewayContainerNamespace "ns" as dagNs { description := "x" }
    resource scalewayContainer "svc"
      { namespace' := dagNs, image := "img"
      , secretEnv := [("A", dagRoot), ("B", dagSink), ("C", dagT3)] }

  provider aws where
    -- Crossing clouds: an AWS secret composed from a Scaleway one.
    resource secrets "xr" as _dagXr { valueFrom := composed expr!"x={secretValueOf dagRoot}" }
    -- The library's only *required* key reference.
    resource securityGroup "web" as dagGrp { description := "w" }
    resource awsInstance "i1"
      { imageId := "ami-1", instanceType := InstanceType.of .t3 .nano
      , securityGroup := dagGrp }

section DagGuards

/-- The slots one action depends on, recomputed from `HasDeps` — deliberately
    not reusing the scheduler's own `dependsOn`, which is what is under test. -/
private def dagDeps (T : Plan dagFleet.keys) : Action dagFleet.keys → List String
  | .create p k key | .update p k key | .replace p k key | .delete p k key =>
    match T.assign p k key with
    | .present spec => ((hasDepsOf k).deps spec).map fun d =>
        Ledger.slotId d.provider d.kind (dagFleet.keys.name d.provider d.kind d.key)
    | _ => []
  -- Neither carries a key, so neither has a spec to read edges from. This
  -- checker is about the declared graph; the ledger records names and
  -- regions, not references. See `Engine.stepOf`.
  | .deleteOrphan .. | .forget .. => []

/-- Every dependency that is itself scheduled appears strictly earlier.

    `rest` rather than `as`: `as` is a parser token of the `fleet` command, so
    it cannot be an identifier in a file that imports it. -/
private def isTopological (T : Plan dagFleet.keys) (ordered : List (Action dagFleet.keys)) :
    Bool :=
  let ids := ordered.map Action.slot
  let rec go (seen : List String) : List (Action dagFleet.keys) → Bool
    | []        => true
    | a :: rest =>
      let needed := (dagDeps T a).filter fun d => ids.contains d && d != a.slot
      needed.all seen.contains && go (seen ++ [a.slot]) rest
  go [] ordered

private def dagBuild : List (Action dagFleet.keys) :=
  match orderActions dagFleet.plan (actions dagFleet.plan (worldOf [])) with
  | .ok o    => o
  | .error _ => []

/- Sixteen resources, all scheduled — a vacuous pass is visible as a count. -/
#guard (actions dagFleet.plan (worldOf [])).length = 16
#guard dagBuild.length = 16

/- The claim: every edge is respected. -/
#guard isTopological dagFleet.plan dagBuild

/- And the shape is really what it claims: the sink genuinely fans in on four. -/
#guard (dagDeps dagFleet.plan (Action.create .scaleway .secrets dagSink)).length = 4

private def dagAt (slot : String) : Nat := (dagBuild.map Action.slot).idxOf slot

#guard dagAt "scaleway/secrets/root" < dagAt "scaleway/secrets/sink"
#guard dagAt "scaleway/secrets/sink" < dagAt "scaleway/secrets/tail3"
#guard dagAt "scaleway/postgres/db" < dagAt "scaleway/secrets/dburl"
#guard dagAt "aws/security-group/web" < dagAt "aws/aws-instance/i1"
#guard dagAt "scaleway/secrets/root" < dagAt "aws/secrets/xr"       -- crosses clouds
#guard dagAt "scaleway/scaleway-container-namespace/ns"
     < dagAt "scaleway/scaleway-container/svc"

/-! ### Tearing the same graph down

  Deletion is the transpose: a resource goes before everything it depends on.
  `Plan.absent` carries no specs, so the fleet's own plan is what supplies the
  edges — that is `orderActions`' `edges` argument, and `Infra.Cli` passes it
  for exactly this. -/

/-- The whole fleet, already applied. Only `observed` matters for producing
    deletions; `reported` is never consulted by `actions` for an absent key. -/
private def dagWorld : World dagFleet.keys :=
  worldOf <| (Finite.elems (α := Kind)).flatMap fun k =>
    (Finite.elems (α := ProviderId)).flatMap fun p =>
      (Finite.elems (α := dagFleet.keys.Key p k)).map fun key =>
        ⟨p, k, key, { observed := Infra.Providers.placeholderObserved k (dagFleet.keys.name p k key)
                      reported := Infra.Providers.placeholderReported k
                        ⟨dagFleet.keys.name p k key⟩ }⟩

private def dagTeardown : List (Action dagFleet.keys) :=
  match orderActions (Plan.absent dagFleet.keys)
          (actions (Plan.absent dagFleet.keys) dagWorld) dagFleet.plan with
  | .ok o    => o
  | .error _ => []

#guard dagTeardown.length = 16

private def killAt (slot : String) : Nat := (dagTeardown.map Action.slot).idxOf slot

/- Every creation edge, reversed. The root goes last of its component; the
   deepest dependant goes first. -/
#guard killAt "scaleway/secrets/sink" < killAt "scaleway/secrets/root"
#guard killAt "scaleway/secrets/tail3" < killAt "scaleway/secrets/sink"
#guard killAt "scaleway/secrets/dburl" < killAt "scaleway/postgres/db"
#guard killAt "aws/aws-instance/i1" < killAt "aws/security-group/web"
#guard killAt "aws/secrets/xr" < killAt "scaleway/secrets/root"
#guard killAt "scaleway/scaleway-container/svc"
     < killAt "scaleway/scaleway-container-namespace/ns"

/- `dburl` before `db` is the case that used to come out backwards: `secrets`
   precedes `postgres` in the `Kind` enum, so reverse-of-enumeration deleted
   the database first. It is now derived from the graph, so where the enum sits
   no longer matters. -/
#guard killAt "scaleway/secrets/dburl" < killAt "scaleway/postgres/db"

/- The transpose is exactly the reverse: deleting is the build order backwards,
   restricted to the same slots. -/
#guard dagTeardown.map Action.slot = (dagBuild.map Action.slot).reverse

end DagGuards

/-! ## Membership: what the ledger says, not what the declaration says

  The declaration below keeps one resource and releases another. What matters
  is a third name, in the ledger and in neither list: that is a resource whose
  line was deleted, and destroying it is the whole point of the ledger. -/

/-! A declaration with nothing in it, which is what the last stage of a live
  sequence applies. Its key family is empty, so it cannot name anything. -/

fleet nothingDeclared where

fleet ledgerFleet in paris where
  resource scaleway queues "keep" { visibilityTimeoutSec := 30 }
  -- Released: still in the ledger, must not be destroyed.
  forget scaleway queues "released"

section LedgerGuards

private def row (k : Kind) (nm : String) : Ledger.Row :=
  { cloud := .scaleway, kind := k, name := nm, region := "fr-par" }

/-- Three rows: one still declared, one released, one simply dropped. -/
private def ledgerRows : List Ledger.Row :=
  [row .queues "keep", row .queues "released", row .queues "dropped"]

/- The `forget` declaration reached the fleet, as a `Released` carrying this
   fleet's own key family — which is what stops it being handed to another. -/
#guard ledgerFleet.forgets.map (fun r => (r.cloud, r.kind, r.name))
     = [(ProviderId.scaleway, Kind.queues, "released")]
#guard ledgerFleet.forgets.length = 1

/- `keep` is still claimed by a key, so it is not the orphan pass's business. -/
#guard Infra.Core.claimedByKey ledgerFleet.keys .scaleway .queues "keep" = true
#guard Infra.Core.claimedByKey ledgerFleet.keys .scaleway .queues "dropped" = false

/- The three rows produce exactly two actions, and each is the right one:
   nothing for the declared resource, a release for the forgotten one, and a
   delete for the one whose line was deleted. This is the behaviour the whole
   change exists for. -/
#guard (actionsOrphaned ledgerFleet.keys ledgerRows ledgerFleet.forgets).map Action.slot
     = ["scaleway/queues/released", "scaleway/queues/dropped"]
#guard (actionsOrphaned ledgerFleet.keys ledgerRows ledgerFleet.forgets).map Action.verb
     = ["FORGET", "DELETE"]

/- A release is not destructive, so it is never ordered against the teardown
   graph: it changes what is managed, not what exists. -/
#guard (actionsOrphaned ledgerFleet.keys ledgerRows ledgerFleet.forgets).map
         Action.isDestructive = [false, true]

/- With no ledger, nothing is an orphan — which is what keeps every `#guard`
   in `example/` asking about a declaration alone, and what makes a first run
   against an empty ledger propose no deletions at all. -/
#guard actionsOrphaned ledgerFleet.keys [] ledgerFleet.forgets = []

/- The same row, against a declaration that does not mention it, is destroyed.
   That is the whole mechanism in one line: membership is the ledger, and
   whether a managed resource survives depends on whether the declaration still
   claims it. `dagFleet` declares plenty, but no `scaleway/queues/keep`. -/
#guard (actionsOrphaned dagFleet.keys [row .queues "keep"] []).map Action.verb = ["DELETE"]
#guard (actionsOrphaned dagFleet.keys [row .queues "keep"] []).map Action.slot
     = ["scaleway/queues/keep"]

/- So `destroy` is not a second teardown mechanism. It reconciles against
   `Plan.absent`, which deletes every declared resource; deleting every line
   and applying orphans the same resources and deletes those. Both end at the
   same `Backend.delete`, addressed by name — see `Engine.runAction`, where the
   two cases share one body. -/
#guard (actions (Plan.absent ledgerFleet.keys)
          (worldOf [⟨.scaleway, .queues, ⟨0, by decide⟩,
                    { observed := { handle := ⟨"keep"⟩, url := "" }
                      reported := { name := "keep", visibilityTimeoutSec := .unknown } }⟩])).map
         Action.verb = ["DELETE"]

/-! ### The brake, and what it must not stop

  `push` refuses a plan that destroys most of the ledger — the hazard being a
  declaration edited by mistake, or a rename that orphans everything. What it
  must *not* refuse is a teardown, and the first live run of the staged test
  failed on exactly that: all three clouds created and trimmed correctly, then
  the final stage could not delete anything, because the brake fired on the one
  plan it was never meant to question.

  The lesson was about depth, not about a missing flag. The brake originally
  took `force` from its caller, so every caller had to remember to set it for a
  teardown; the CLI did and the test driver did not. It now decides from the
  target, because "asks for nothing to exist" is what a teardown *is* and the
  target already says it. -/

/- An empty declaration declares nothing, and `Plan.absent` says the same
   thing about a fleet that has keys. Both are teardowns. -/
#guard nothingDeclared.plan.declaresAnything = false
#guard (Plan.absent ledgerFleet.keys).declaresAnything = false

/- A declaration with resources in it does declare something, however many of
   them are on their way out. This is the case the brake is for: dropping most
   of a fleet while still declaring the rest. -/
#guard ledgerFleet.plan.declaresAnything = true
#guard dagFleet.plan.declaresAnything = true

/-! ### Negative checks

  Recorded as prose because a `#guard` can only witness what elaborates.

    * **Forgetting something you also declare.** `forget` carries
      `Assert (!claimedByKey …)`, discharged by `decide`, so the two
      statements cannot both be in force:

          forget scaleway queues "keep"

          could not synthesize default value for parameter '_h' using tactics
          Tactic `decide` proved that the proposition
            Assert (!claimedByKey ledgerFleet.keys ProviderId.scaleway Kind.queues "keep")
          is false

    * **A `forget` naming only a kind**, outside a `provider` block, is
      rejected by the elaborator with the same message shape `resource` uses.

    * **One fleet's releases handed to another.** `Released` is indexed by the
      key family, so the two are different types:

          example : List (Released dagFleet.keys) := ledgerFleet.forgets

          Type mismatch
            ledgerFleet.forgets
          has type
            List (Released ledgerFleet.keys)
          but is expected to have type
            List (Released dagFleet.keys)

      This is what the index buys. It used to be a bare
      `ProviderId × Kind × String`, so the `Assert` held at the one call site
      the macro generated and nowhere after it.

    * **Building a release by hand**, skipping the check entirely:

          example : Released ledgerFleet.keys :=
            { cloud := .scaleway, kind := .queues, name := "keep" }

          invalid {...} notation, constructor for `Released` is marked as
          private

      `releasing` is the only way to make one, which is what turns "the check
      is present" into "the check cannot be avoided".

    * **Omitting the releases at the call site.** `Cli.run`'s `forgets` has no
      default, so a fleet that declares a `forget` and forgets to pass it does
      not compile:

          Infra.Cli.run "ledger" ledgerFleet.plan (args := args)

          Type mismatch
            fun forgets => Infra.Cli.run "ledger" ledgerFleet.plan … forgets args
          has type
            List (Released ledgerFleet.keys) → IO UInt32
          but is expected to have type
            IO UInt32

      The same shape a missing required field takes everywhere else here: what
      you are left holding is a function still waiting for the argument. Before
      the default was removed, that combination compiled and then destroyed the
      resource. -/

end LedgerGuards

end Infra.Demo
