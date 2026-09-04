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
    exists in the world.

    Note what this deliberately omits: `Env.secretValue`. Taking its default
    ("knows nothing") is what makes the planning path *structurally* unable to
    hold a secret value — see `Env`'s doc comment. Only `Engine.settleFor`,
    on the apply path, ever fills it in. -/
def envOfWorld {κ : Keys} (W : World κ) : Env κ.Key where
  observed p k key := (W.sighting p k key).map (·.observed)

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
          -- Redacted, not empty: a composed value's *shape* must settle so the
          -- spec reaches `repairOf` and the kind's own `Divergent` decides.
          -- `.secrets` deliberately never compares its value, so a composed
          -- secret is create-only and a second apply comes back empty — while
          -- a genuinely missing *observation* still yields `.update` below.
          match settleSpec k env.withRedactedSecrets authored with
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
  deps : {K : ProviderId → Kind → Type} → S K Partial (Expr K) → List (Dep K)

/-! ## Two readings, unioned

  A spec names another resource in two structurally different ways, and both
  are dependency edges:

  * **In a field's payload.** A *key-typed* field like `sourceBucket` holds
    `Expr K (Option (K .aws .s3Bucket))` — the key is the value, so
    `Expr.asLit` reads it back out. `Expr.deps` returns `[]` for these,
    because there is no `.observed` node anywhere in `.lit (some key)`.
  * **As a node in the expression.** `.observed` and `.secretValue` are
    references *inside* an `Expr`, and `Expr.deps` is what finds them. These
    can occur in any field of any kind, including a plain `Expr K String`.

  So the two are not alternatives, and reading only one loses real edges.
  Each instance below takes the union: `depsReq`/`depsOpt` over every field,
  plus the payload read for the two kinds that have a key-typed field.

  This is why the previous "portable specs have no dependencies by
  construction" claim no longer holds: it was true while the only references
  were key-typed (and so provider-naming, hence non-portable), but
  `.secretValue` is a reference that lives in a `String` field, so any kind
  can contribute an edge. -/

/-- Reference nodes inside a required field. -/
def depsReq {K : ProviderId → Kind → Type} {α : Type} (e : Expr K α) : List (Dep K) := e.deps

/-- Reference nodes inside an optional field. An unspecified field names nothing. -/
def depsOpt {K : ProviderId → Kind → Type} {α : Type} : Partial (Expr K α) → List (Dep K)
  | .unknown => []
  | .known e => e.deps

instance : HasDeps IamSpec where
  deps s := depsReq s.name ++ depsOpt s.policies

instance : HasDeps ObjectStoreSpec where
  deps s := depsReq s.name ++ depsOpt s.versioning ++ depsOpt s.tags

instance : HasDeps ComputeSpec where
  deps s := depsReq s.name ++ depsOpt s.runtime ++ depsReq s.image
            ++ depsOpt s.executionRole ++ depsOpt s.namespace' ++ depsOpt s.handler
            ++ depsOpt s.memoryMb ++ depsOpt s.timeoutSec ++ depsOpt s.env

instance : HasDeps QueuesSpec where
  deps s := depsReq s.name ++ depsOpt s.visibilityTimeoutSec

/-- Now a real contributor: a composed `valueFrom` names the secrets and
    resources its value is built from, which is what orders them before it. -/
instance : HasDeps SecretsSpec where
  deps s := depsReq s.name ++ depsReq s.valueFrom

instance : HasDeps ImageRegistrySpec where
  deps s := depsReq s.name ++ depsOpt s.immutableTags

instance : HasDeps PostgresSpec where
  deps s := depsReq s.name ++ depsOpt s.instanceClass ++ depsReq s.masterUsername
            ++ depsReq s.masterPasswordSecret ++ depsOpt s.version ++ depsOpt s.storageGb
            ++ depsOpt s.minCapacity ++ depsOpt s.maxCapacity

instance : HasDeps S3BucketSpec where
  deps s := depsReq s.name ++ depsOpt s.versioning ++ depsOpt s.objectLock
            ++ depsOpt s.region

/-- The cross-cloud edge — a Scaleway function reading from an AWS bucket —
    and the first of the two key-typed *payload* reads. -/
instance : HasDeps ScalewayFunctionSpec where
  deps s :=
    depsReq s.name ++ depsReq s.runtime ++ depsReq s.namespace'
    ++ depsOpt s.sourceBucket
    ++ (match s.sourceBucket with
        | .unknown => []
        | .known e =>
          match e.asLit with
          | some (some key) => [⟨.aws, .s3Bucket, key, .handle⟩]
          | _               => [])

/-- A security group references nothing; it is what gets referenced. -/
instance : HasDeps SecurityGroupSpec where
  deps s := depsReq s.name ++ depsReq s.description ++ depsOpt s.ingress

/-- The second key-typed *payload* read, and the only **required** one in the
    library: `securityGroup` is not an `Option`, so unlike `sourceBucket` there
    is no "said: nothing" case to fall through — an instance always contributes
    exactly this edge, which is what guarantees its group is created first. -/
instance : HasDeps AwsInstanceSpec where
  deps s :=
    depsReq s.name ++ depsReq s.imageId ++ depsReq s.instanceType
    ++ depsReq s.securityGroup ++ depsOpt s.keyName ++ depsOpt s.subnetId
    ++ (match s.securityGroup.asLit with
        | some key => [⟨.aws, .securityGroup, key, .handle⟩]
        | none     => [])

/-- List-generalized version of `ScalewayFunctionSpec`'s single reference: every secret named in
    `secretEnv` is a dependency, same-cloud this time. -/
instance : HasDeps ScalewayContainerSpec where
  deps s :=
    depsReq s.name ++ depsReq s.namespace' ++ depsReq s.image
    ++ depsOpt s.port ++ depsOpt s.minScale ++ depsOpt s.maxScale
    ++ depsOpt s.memoryMb ++ depsOpt s.cpuLimit ++ depsOpt s.timeoutSec
    ++ depsOpt s.env ++ depsOpt s.secretEnv
    ++ (match s.secretEnv with
        | .unknown => []
        | .known e =>
          match e.asLit with
          | some entries => entries.map fun entry => ⟨.scaleway, .secrets, entry.2, .handle⟩
          | none         => [])

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
  | .securityGroup     => inferInstanceAs (HasDeps SecurityGroupSpec)
  | .awsInstance       => inferInstanceAs (HasDeps AwsInstanceSpec)
  | .scalewayFunction  => inferInstanceAs (HasDeps ScalewayFunctionSpec)
  | .scalewayContainer => inferInstanceAs (HasDeps ScalewayContainerSpec)

end Infra.Core
