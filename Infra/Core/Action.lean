import Infra.Core.Settle
import Infra.Core.Fleet
import Infra.Core.Ledger

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
  /-- Destroy a resource this fleet *used* to declare.

      Addressed by name and region rather than by a key, because there is no
      key: its line was deleted from the declaration, so `κ.Key p k` has no
      inhabitant for it any more. That is the whole reason this constructor
      exists and the reason the ledger stores strings — see
      `Infra.Core.Ledger.Row`.

      Everything needed to carry it out is here: `Backend.delete` takes a
      `Handle k`, which wraps the name, and `region` is what routes the call. -/
  | deleteOrphan (p : ProviderId) (k : Kind) (name : String) (region : String) : Action κ
  /-- Stop managing a resource without destroying it: drop its ledger row and
      leave the cloud alone.

      The counterpart of Terraform's `removed { … lifecycle { destroy = false }
      }`. It is an action rather than a silent ledger edit so that it appears
      in a plan before it happens, which is the reason HashiCorp gives for
      preferring `removed` over `terraform state rm`.

      No region, because nothing is called. -/
  | forget (p : ProviderId) (k : Kind) (name : String) : Action κ

/-- The resource an action points at, outside the key family.

    Every total match over `Action` wants this, and before it existed the
    `(cloud, kind, name)` triple was rebuilt inline at four sites, each with
    its own hand-written three-clause equality. -/
def Action.address {κ : Keys} : Action κ → ProviderId × Kind × String
  | .create p k key | .update p k key | .replace p k key | .delete p k key =>
    (p, k, κ.name p k key)
  | .deleteOrphan p k nm _ | .forget p k nm => (p, k, nm)

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
def actionsDeclared {κ : Keys} (T : Plan κ) (W : World κ) : List (Action κ) :=
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

/-- What to do about resources the ledger records and the declaration no longer
    names.

    A row still claimed by a key is not an orphan and is handled by
    `actionsDeclared`. A row named in `forgets` is released rather than
    destroyed. Everything else the declaration has dropped gets destroyed,
    which is what makes deleting a line mean what it reads like.

    `forgets` cannot overlap the declared names: the `forget` declaration
    discharges `Assert (!claimedByKey …)` at compile time, so a `forget` for
    something still declared does not elaborate. -/
def actionsOrphaned (κ : Keys) (ledger : List Ledger.Row)
    (forgets : List (Released κ)) : List (Action κ) :=
  ledger.filterMap fun r =>
    if claimedByKey κ r.cloud r.kind r.name then
      none
    else if forgets.any (·.isAt r.cloud r.kind r.name) then
      some (.forget r.cloud r.kind r.name)
    else
      some (.deleteOrphan r.cloud r.kind r.name r.region)

/-- Everything reconciling this target asks for: the declared resources, then
    the ones the declaration has dropped.

    `ledger` and `forgets` default to empty so that a pure question about a
    declaration alone — which is what every `#guard` in `example/` asks — needs
    neither. The engine passes the real ones. -/
def actions {κ : Keys} (T : Plan κ) (W : World κ)
    (ledger : List Ledger.Row := []) (forgets : List (Released κ) := []) :
    List (Action κ) :=
  actionsDeclared T W ++ actionsOrphaned κ ledger forgets

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

/-- The key held *in* a required key-typed field's payload.

    `p` and `k` come from the field's own type, so a caller cannot write down a
    provider/kind pair that disagrees with what the field declares — which the
    three hand-written copies of this could. -/
def depsKey {K : ProviderId → Kind → Type} {p : ProviderId} {k : Kind}
    (e : Expr K (K p k)) : List (Dep K) :=
  match e.asLit with
  | some key => [⟨p, k, key, .handle⟩]
  | none     => []

/-- The key held in an *optional* key-typed field's payload, where "said:
    nothing" is a real case. -/
def depsKeyOpt {K : ProviderId → Kind → Type} {p : ProviderId} {k : Kind} :
    Partial (Expr K (Option (K p k))) → List (Dep K)
  | .unknown => []
  | .known e =>
    match e.asLit with
    | some (some key) => [⟨p, k, key, .handle⟩]
    | _               => []

/-- Every key held in a *list*-of-references payload. -/
def depsKeys {K : ProviderId → Kind → Type} {p : ProviderId} {k : Kind} :
    Partial (Expr K (List (String × K p k))) → List (Dep K)
  | .unknown => []
  | .known e =>
    match e.asLit with
    | some entries => entries.map fun entry => ⟨p, k, entry.2, .handle⟩
    | none         => []

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

/-- The cross-cloud edge — a Scaleway function reading from an AWS bucket —
    and the first of the two key-typed *payload* reads. -/
instance : HasDeps ScalewayFunctionSpec where
  deps s :=
    depsReq s.name ++ depsReq s.runtime
    ++ depsReq s.namespace' ++ depsKey s.namespace'
    ++ depsOpt s.sourceBucket ++ depsKeyOpt s.sourceBucket

/-- A namespace references nothing; it is what gets referenced. -/
instance : HasDeps ScalewayNamespaceSpec where
  deps s := depsReq s.name ++ depsOpt s.description

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
    ++ depsReq s.securityGroup ++ depsKey s.securityGroup
    ++ depsOpt s.keyName ++ depsOpt s.subnetId

/-- List-generalized version of `ScalewayFunctionSpec`'s single reference: every secret named in
    `secretEnv` is a dependency, same-cloud this time. -/
instance : HasDeps ScalewayContainerSpec where
  deps s :=
    depsReq s.name ++ depsReq s.namespace' ++ depsKey s.namespace' ++ depsReq s.image
    ++ depsOpt s.port ++ depsOpt s.minScale ++ depsOpt s.maxScale
    ++ depsOpt s.memoryMb ++ depsOpt s.cpuLimit ++ depsOpt s.timeoutSec
    ++ depsOpt s.env ++ depsOpt s.secretEnv ++ depsKeys s.secretEnv

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
  | .scalewayFunctionNamespace  => inferInstanceAs (HasDeps ScalewayNamespaceSpec)
  | .scalewayFunction  => inferInstanceAs (HasDeps ScalewayFunctionSpec)
  | .scalewayContainerNamespace => inferInstanceAs (HasDeps ScalewayNamespaceSpec)
  | .scalewayContainer => inferInstanceAs (HasDeps ScalewayContainerSpec)

end Infra.Core
