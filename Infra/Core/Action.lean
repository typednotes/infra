import Infra.Core.Settle
import Infra.Core.Fleet

/-
  What reconciling a `Plan` against a `World` asks the providers to do, and in what order.
-/

namespace Infra.Core

open Infra.Specs

/-- One unit of work at one key. Carries its `(provider, kind, key)` so the scheduler can order
    it without re-deriving where it came from. -/
inductive Action (κ : Keys) where
  | create  (p : ProviderId) (k : Kind) : κ.Key p k → Action κ
  | update  (p : ProviderId) (k : Kind) : κ.Key p k → Action κ
  | replace (p : ProviderId) (k : Kind) : κ.Key p k → Action κ   -- immutable field changed
  | delete  (p : ProviderId) (k : Kind) : κ.Key p k → Action κ

/-- The environment a plan's expressions resolve against: whatever already
    exists in the world. -/
def envOfWorld {κ : Keys} (W : World κ) : Env κ.Key :=
  fun p k key => (W.sighting p k key).map (·.observed)

/-- What must change for the world to realise the target.

    Existence alone decides create and delete. For a resource that already
    exists the decision needs its *configuration*, which is what `Sighting`
    carries and what makes the third outcome — nothing to do — reachable at
    all. Without it every existing resource looked like an update for ever.

    A target that cannot be settled (it references something that does not
    exist yet) is reported as an update rather than skipped: the reference will
    resolve once its dependency is created, and silently dropping the action
    would leave the resource unreconciled. -/
def actions {κ : Keys} (T : Plan κ) (W : World κ) : List (Action κ) :=
  let env := envOfWorld W
  (Finite.elems (α := ProviderId)).flatMap fun p =>
    (Finite.elems (α := Kind)).flatMap fun k =>
      (Finite.elems (α := κ.Key p k)).filterMap fun key =>
        match T.assign p k key, W.sighting p k key with
        | .unmanaged, _        => none
        | .absent,    none     => none
        | .absent,    some _   => some (.delete p k key)
        | .present _, none     => some (.create p k key)
        | .present authored, some seen =>
          match settleSpec k env authored with
          | none        => some (.update p k key)
          | some target =>
            match repairOf k target seen.reported with
            | none                 => none                      -- already right
            | some .mutable        => some (.update p k key)
            | some .forcesReplace  => some (.replace p k key)

/-- The dependency edges of the creation graph.

    Deletion edges are the TRANSPOSE of these: create B then A, but delete A then B. A mixed
    plan is the creation DAG unioned with the reversed deletion DAG — which is why `Action`
    carries the direction explicitly rather than letting the scheduler infer it. -/
class HasDeps (S : SpecShape.{1}) where
  deps : {K : ProviderId → Kind → Type} → S K Partial (Expr K) →
           List ((p : ProviderId) × (k : Kind) × K p k)

/-- Portable specs carry no cross-resource references at all — a reference type `K p k` names a
    provider, which is exactly what a portable spec must not do — so their dependency sets are
    empty by construction, not by oversight. -/
instance : HasDeps IamSpec           where deps _ := []
instance : HasDeps ObjectStoreSpec   where deps _ := []
instance : HasDeps ComputeSpec       where deps _ := []
instance : HasDeps QueuesSpec        where deps _ := []
instance : HasDeps SecretsSpec       where deps _ := []
instance : HasDeps ImageRegistrySpec where deps _ := []
instance : HasDeps PostgresSpec      where deps _ := []
instance : HasDeps S3BucketSpec      where deps _ := []

/-- The one spec with a real edge — and it crosses clouds: a Scaleway function reading from an
    AWS bucket. `Expr.asLit` is what reads the key back out; a key is a plan-time constant, so
    it is always a literal. -/
instance : HasDeps ScalewayFunctionSpec where
  deps s :=
    match s.sourceBucket with
    | .unknown => []
    | .known e =>
      match e.asLit with
      | some (some key) => [⟨.aws, .s3Bucket, key⟩]
      | _               => []

/-- List-generalized version of `ScalewayFunctionSpec`'s single reference: every secret named in
    `secretEnv` is a dependency, same-cloud this time. -/
instance : HasDeps ScalewayContainerSpec where
  deps s :=
    match s.secretEnv with
    | .unknown => []
    | .known e =>
      match e.asLit with
      | some entries => entries.map fun entry => ⟨.scaleway, .secrets, entry.2⟩
      | none         => []

/-- Total over `Kind`, so a new kind cannot silently contribute no edges. -/
@[reducible] def hasDepsOf : (k : Kind) → HasDeps (SpecOf.{1} k)
  | .iam               => inferInstanceAs (HasDeps IamSpec)
  | .objectStore       => inferInstanceAs (HasDeps ObjectStoreSpec)
  | .compute           => inferInstanceAs (HasDeps ComputeSpec)
  | .queues            => inferInstanceAs (HasDeps QueuesSpec)
  | .secrets           => inferInstanceAs (HasDeps SecretsSpec)
  | .imageRegistry     => inferInstanceAs (HasDeps ImageRegistrySpec)
  | .postgres          => inferInstanceAs (HasDeps PostgresSpec)
  | .s3Bucket          => inferInstanceAs (HasDeps S3BucketSpec)
  | .scalewayFunction  => inferInstanceAs (HasDeps ScalewayFunctionSpec)
  | .scalewayContainer => inferInstanceAs (HasDeps ScalewayContainerSpec)

end Infra.Core
