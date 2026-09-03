import Infra.Core.Diverge

/-
  Turning an authored target into something a backend can be handed.

  `Plan.assign` yields `SpecOf k κ.Key Partial (Expr κ.Key)`; `Backend.create`
  wants `ProviderSpec k = SpecOf k Resolved Conc Conc`. Two substitutions
  separate them, and only one of them already existed:

    * `Partial → Conc` on the optionality axis — `Fillable.fill` does this.
    * `Expr κ.Key → Conc`, *and* rewriting the residual `κ.Key p k` references
      into the `Handle k` the cloud assigned — nothing did this.

  The second is what `Settleable` adds. It cannot be generic: Lean has no way
  to traverse an arbitrary record's fields, so it is one instance per kind,
  exactly like `Fillable`, `HasDeps` and `Divergent`.

  ## Why indexed by `Kind` and not by `SpecShape`

  The input sits at universe 1 (it holds `Expr`, which does) and the output at
  universe 0. A class parameterised by the shape would have to fix one
  universe; parameterising by the *kind* lets `SpecOf` be applied at each.
-/

namespace Infra.Core

open Infra.Specs

/-- What a spec's references resolve against: the resources observed so far.

    `none` for a resource not yet created, which is a scheduling fact rather
    than an error — `push` creates dependencies first precisely so this becomes
    `some` in time. -/
abbrev Env (K : ProviderId → Kind → Type) :=
  (p : ProviderId) → (k : Kind) → K p k → Option (ObservedOf k)

/-- Resolve one field: evaluate the expression, and fail cleanly if it names
    something that does not exist yet. -/
def settleField {K : ProviderId → Kind → Type} {α : Type}
    (env : Env K) (e : Expr K α) : Option α :=
  Expr.eval? env e

/-- Resolve an optional reference field to a handle.

    A `sourceBucket` names a fleet key at plan time; a backend needs the
    physical handle. This is the substitution `Fillable` and `eval` between
    them cannot perform. -/
def settleRef {K : ProviderId → Kind → Type}
    (env : Env K) (p : ProviderId) (k : Kind) (r : Option (K p k)) :
    Option (Option (Handle k)) :=
  match r with
  | none     => some none                    -- said: nothing
  | some key => (env p k key).map fun o => some (observedHandle k o)

/-- List-generalized `settleRef`: resolve every reference in a
    `(name, key)` list to a `(name, handle)` list. Unlike `settleRef`, there is no "said:
    nothing" case here — every entry names a real secret, so a missing observation fails the
    whole list, exactly like `settleField`. -/
def settleRefs {K : ProviderId → Kind → Type}
    (env : Env K) (p : ProviderId) (k : Kind) (refs : List (String × K p k)) :
    Option (List (String × Handle k)) :=
  refs.mapM fun (name, key) => (env p k key).map fun o => (name, observedHandle k o)

/-- Turn a filled spec into one a backend can act on. -/
class Settleable (k : Kind) where
  settle : {K : ProviderId → Kind → Type} → Env K →
           SpecOf.{1} k K Conc (Expr K) → Option (ProviderSpec k)

/-! ## Per-kind instances

  Portable kinds hold no references, so their `settle` is `eval?` field by
  field and can only fail if an expression names a resource that does not exist
  — which for a reference-free spec it cannot. `ScalewayFunctionSpec` is the
  one with a real reference, and the one that can genuinely return `none`. -/

instance : Settleable .iam where
  settle env s := do
    return { name := ← settleField env s.name, policies := ← settleField env s.policies }

instance : Settleable .objectStore where
  settle env s := do
    return { name := ← settleField env s.name
             versioning := ← settleField env s.versioning
             tags := ← settleField env s.tags }

instance : Settleable .compute where
  settle env s := do
    return { name := ← settleField env s.name
             runtime := ← settleField env s.runtime
             image := ← settleField env s.image
             executionRole := ← settleField env s.executionRole
             namespace' := ← settleField env s.namespace'
             handler := ← settleField env s.handler
             memoryMb := ← settleField env s.memoryMb
             timeoutSec := ← settleField env s.timeoutSec
             env := ← settleField env s.env }

instance : Settleable .queues where
  settle env s := do
    return { name := ← settleField env s.name
             visibilityTimeoutSec := ← settleField env s.visibilityTimeoutSec }

instance : Settleable .secrets where
  settle env s := do
    return { name := ← settleField env s.name, valueFrom := ← settleField env s.valueFrom }

instance : Settleable .imageRegistry where
  settle env s := do
    return { name := ← settleField env s.name
             immutableTags := ← settleField env s.immutableTags }

instance : Settleable .postgres where
  settle env s := do
    return { name := ← settleField env s.name
             instanceClass := ← settleField env s.instanceClass
             masterUsername := ← settleField env s.masterUsername
             masterPasswordSecret := ← settleField env s.masterPasswordSecret
             version := ← settleField env s.version
             storageGb := ← settleField env s.storageGb
             minCapacity := ← settleField env s.minCapacity
             maxCapacity := ← settleField env s.maxCapacity }

instance : Settleable .s3Bucket where
  settle env s := do
    return { name := ← settleField env s.name
             versioning := ← settleField env s.versioning
             objectLock := ← settleField env s.objectLock
             region := ← settleField env s.region }

/-- The one instance that can genuinely fail: `sourceBucket` names another
    resource, so settling it needs that resource to exist already. -/
instance : Settleable .scalewayFunction where
  settle env s := do
    let refKey ← settleField env s.sourceBucket
    return { name := ← settleField env s.name
             runtime := ← settleField env s.runtime
             namespace' := ← settleField env s.namespace'
             sourceBucket := ← settleRef env .aws .s3Bucket refKey }

/-- List-generalized version of `scalewayFunction`'s single reference: every `secretEnv` entry
    must resolve, same-cloud this time. -/
instance : Settleable .scalewayContainer where
  settle env s := do
    let refs ← settleField env s.secretEnv
    return { name := ← settleField env s.name
             namespace' := ← settleField env s.namespace'
             image := ← settleField env s.image
             port := ← settleField env s.port
             minScale := ← settleField env s.minScale
             maxScale := ← settleField env s.maxScale
             memoryMb := ← settleField env s.memoryMb
             cpuLimit := ← settleField env s.cpuLimit
             timeoutSec := ← settleField env s.timeoutSec
             env := ← settleField env s.env
             secretEnv := ← settleRefs env .scaleway .secrets refs }

/-- Total over `Kind`, so a new kind cannot be forgotten here. -/
@[reducible] def settleableOf : (k : Kind) → Settleable k
  | .iam               => inferInstanceAs (Settleable .iam)
  | .objectStore       => inferInstanceAs (Settleable .objectStore)
  | .compute           => inferInstanceAs (Settleable .compute)
  | .queues            => inferInstanceAs (Settleable .queues)
  | .secrets           => inferInstanceAs (Settleable .secrets)
  | .imageRegistry     => inferInstanceAs (Settleable .imageRegistry)
  | .postgres          => inferInstanceAs (Settleable .postgres)
  | .s3Bucket          => inferInstanceAs (Settleable .s3Bucket)
  | .scalewayFunction  => inferInstanceAs (Settleable .scalewayFunction)
  | .scalewayContainer => inferInstanceAs (Settleable .scalewayContainer)

/-- Fill defaults and resolve references in one step: the whole journey from
    what was authored to what a backend receives. -/
def settleSpec {K : ProviderId → Kind → Type} (k : Kind) (env : Env K)
    (authored : SpecOf.{1} k K Partial (Expr K)) : Option (ProviderSpec k) :=
  (settleableOf k).settle env ((fillableOf k).fill authored)

end Infra.Core
