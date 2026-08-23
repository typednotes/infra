import Infra.Providers

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
  name       := .lit nm
  versioning := .known (.lit true)
  tags       := .unknown          -- not yet said; `Fillable` will default it

def apiSpec {K : ProviderId → Kind → Type} : ComputeSpec K Partial (Expr K) where
  name       := .lit "api"
  runtime    := .lit "python3.12"
  handler    := .unknown
  memoryMb   := .known (.lit 512)
  timeoutSec := .unknown
  env        := .unknown

/-! ## The plan

  Spans both clouds, and `ingestSpec.sourceBucket` points from a Scaleway function at an AWS
  bucket — a reference crossing clouds inside one target. -/

def ingestSpec : ScalewayFunctionSpec demoKey Partial (Expr demoKey) where
  name         := .lit "ingest"
  runtime      := .lit "python3.12"
  sourceBucket := .known (.lit (some Archive.cold))

def demoPlan : Plan demoKeys where
  assign
    | .aws,      .objectStore,      b => .present (bucketSpec (demoName .aws .objectStore b))
    | .scaleway, .objectStore,      b => .present (bucketSpec (demoName .scaleway .objectStore b))
    | .scaleway, .compute,          _ => .present apiSpec
    | .aws,      .s3Bucket,         _ =>
        .present { name := .lit "cold", versioning := .unknown
                   storageClass := .known (.lit "GLACIER"), region := .unknown }
    | .scaleway, .scalewayFunction, _ => .present ingestSpec
    | _,         _,                 _ => .unmanaged
  outside := .unmanaged

/-- Every key `unmanaged`: ⊥ of the `Status` order, so satisfied by anything. -/
def idlePlan : Plan demoKeys where
  assign _ _ _ := .unmanaged
  outside := .unmanaged

/-! ## Worlds -/

def emptyWorld : World demoKeys := worldOf []

/-- A world where the AWS `assets` bucket exists but nothing else does. -/
def partialWorld : World demoKeys :=
  worldOf [⟨.aws, .objectStore, .assets, { handle := ⟨"assets"⟩, url := "https://x.invalid" }⟩]

section Guards

-- `unmanaged` is ⊥: the idle plan is satisfied by every world, and asks for nothing.
#guard satisfies idlePlan emptyWorld
#guard satisfies idlePlan partialWorld
#guard (actions idlePlan emptyWorld).isEmpty
#guard (actions idlePlan partialWorld).isEmpty

-- The real plan is not yet realised, and every declared resource needs creating.
#guard !(satisfies demoPlan emptyWorld)
#guard (actions demoPlan emptyWorld).length = 7

-- One resource already exists, so it becomes an update rather than a create; the count is
-- unchanged because the work-list covers both.
#guard (actions demoPlan partialWorld).length = 7
#guard satisfies demoPlan partialWorld = false

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
