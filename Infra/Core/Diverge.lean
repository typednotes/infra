import Infra.Core.Stage

/-
  Where a resource disagrees with its target, and whether that can be fixed in
  place.

  This is what turns the extent-level work-list into a real plan. Before it,
  `actions` could only say "exists" or "does not exist", so every existing
  resource looked like it needed an update, for ever. With it, an already-correct
  resource produces no action at all, and a resource differing in an immutable
  field produces `replace` rather than a doomed `update`.

  ## `unknown` is not drift

  A field the provider did not report is `unknown`, and `unknown` never counts
  as divergence. The alternative — treating "could not see" as "differs" —
  would rewrite the resource on every single apply. This is the same asymmetry
  `docs/diff-semantics.md` derives at the field level: the comparison runs
  *observed ⊑ target*, not the other way round.

  ## Lists are compared as sets

  Tags, policies and environment variables come back in whatever order the
  service felt like. Comparing them positionally would report drift on every
  apply for a resource nobody had touched.
-/

namespace Infra.Core

open Infra.Specs

/-- One optional field's contribution to the divergence list.

    `unknown` contributes nothing: see the module note. -/
def diverges {α : Type} [BEq α] (name : String) (m : Mutability)
    (target : α) (reported : Partial α) : List (String × Mutability) :=
  match reported with
  | .unknown => []
  | .known v => if v == target then [] else [(name, m)]

/-- A required field's contribution. Always reported, so always comparable. -/
def divergesReq {α : Type} [BEq α] (name : String) (m : Mutability)
    (target reported : α) : List (String × Mutability) :=
  if reported == target then [] else [(name, m)]

/-- An optional list field, compared as a set.

    Sorting first is not cosmetic: without it a service returning the same tags
    in a different order reads as drift, and every apply rewrites them. -/
def divergesSet {α : Type} [BEq α] (name : String) (m : Mutability)
    (key : α → String) (target : List α) (reported : Partial (List α)) :
    List (String × Mutability) :=
  match reported with
  | .unknown => []
  | .known v =>
    let norm (xs : List α) := xs.mergeSort fun a b => compare (key a) (key b) != .gt
    if norm v == norm target then [] else [(name, m)]

/-- The sort key for a `(key, value)` pair, so tags and environment variables
    compare as sets. -/
def pairKey (kv : String × String) : String := kv.1 ++ "\u0000" ++ kv.2

/-- Which fields of a resource disagree with its target, and whether each can
    be changed in place. -/
class Divergent (k : Kind) where
  divergence : ProviderSpec k → Reported k → List (String × Mutability)

/-! ## Per-kind tables

  Each entry names a field and says whether changing it can be done in place.
  `forcesReplace` is not a guess: it means the cloud genuinely refuses to change
  the field on an existing resource. -/

instance : Divergent .iam where
  divergence t r :=
    divergesReq "name" .forcesReplace t.name r.name
    ++ divergesSet "policies" .mutable id t.policies r.policies

instance : Divergent .objectStore where
  divergence t r :=
    -- A bucket cannot be renamed: the name *is* the identity.
    divergesReq "name" .forcesReplace t.name r.name
    ++ diverges "versioning" .mutable t.versioning r.versioning
    ++ divergesSet "tags" .mutable pairKey t.tags r.tags

instance : Divergent .compute where
  divergence t r :=
    divergesReq "name" .forcesReplace t.name r.name
    -- `runtime` is advisory under the container-image model and neither cloud
    -- reports it, so it is not compared. `namespace'` is Scaleway placement,
    -- likewise not reported.
    ++ divergesReq "image" .mutable t.image r.image
    ++ diverges "executionRole" .mutable t.executionRole r.executionRole
    ++ diverges "handler" .mutable t.handler r.handler
    ++ diverges "memoryMb" .mutable t.memoryMb r.memoryMb
    ++ diverges "timeoutSec" .mutable t.timeoutSec r.timeoutSec
    ++ divergesSet "env" .mutable pairKey t.env r.env

instance : Divergent .queues where
  divergence t r :=
    divergesReq "name" .forcesReplace t.name r.name
    ++ diverges "visibilityTimeoutSec" .mutable t.visibilityTimeoutSec r.visibilityTimeoutSec

instance : Divergent .secrets where
  divergence t r :=
    divergesReq "name" .forcesReplace t.name r.name
    -- `valueFrom` names an environment variable, which the cloud has never
    -- heard of and can never report. Comparing it would diverge on every
    -- apply. A value changed outside this tool is therefore not detected —
    -- the documented price of never reading secrets back.

instance : Divergent .imageRegistry where
  divergence t r :=
    divergesReq "name" .forcesReplace t.name r.name
    ++ diverges "immutableTags" .mutable t.immutableTags r.immutableTags

instance : Divergent .postgres where
  divergence t r :=
    divergesReq "name" .forcesReplace t.name r.name
    ++ diverges "instanceClass" .mutable t.instanceClass r.instanceClass
    -- The master user cannot be renamed after creation.
    ++ divergesReq "masterUsername" .forcesReplace t.masterUsername r.masterUsername
    -- Which secret holds the password is our bookkeeping, not the database's:
    -- the service never reports it, so it can never diverge.
    ++ diverges "version" .mutable t.version r.version
    -- Managed Postgres storage can grow but not shrink; growth is in place.
    ++ diverges "storageGb" .mutable t.storageGb r.storageGb
    -- Unverified whether either cloud allows adjusting serverless capacity bounds on a live
    -- instance; assumed mutable like `storageGb` until confirmed against a real account — see
    -- `docs/providers.md`.
    ++ diverges "minCapacity" .mutable t.minCapacity r.minCapacity
    ++ diverges "maxCapacity" .mutable t.maxCapacity r.maxCapacity

instance : Divergent .s3Bucket where
  divergence t r :=
    divergesReq "name" .forcesReplace t.name r.name
    ++ diverges "versioning" .mutable t.versioning r.versioning
    -- Object Lock can only be set when the bucket is created.
    ++ diverges "objectLock" .forcesReplace t.objectLock r.objectLock
    -- A bucket cannot move region.
    ++ diverges "region" .forcesReplace t.region r.region

instance : Divergent .scalewayFunction where
  divergence t r :=
    divergesReq "name" .forcesReplace t.name r.name
    ++ divergesReq "runtime" .forcesReplace t.runtime r.runtime
    -- A function cannot move namespace.
    ++ divergesReq "namespace" .forcesReplace t.namespace' r.namespace'
    ++ diverges "sourceBucket" .mutable t.sourceBucket r.sourceBucket

instance : Divergent .scalewayContainer where
  divergence t r :=
    divergesReq "name" .forcesReplace t.name r.name
    -- A container cannot move namespace, same as `scalewayFunction`.
    ++ divergesReq "namespace" .forcesReplace t.namespace' r.namespace'
    ++ divergesReq "image" .mutable t.image r.image
    ++ diverges "port" .mutable t.port r.port
    ++ diverges "minScale" .mutable t.minScale r.minScale
    ++ diverges "maxScale" .mutable t.maxScale r.maxScale
    ++ diverges "memoryMb" .mutable t.memoryMb r.memoryMb
    ++ diverges "cpuLimit" .mutable t.cpuLimit r.cpuLimit
    ++ diverges "timeoutSec" .mutable t.timeoutSec r.timeoutSec
    ++ divergesSet "env" .mutable pairKey t.env r.env
    -- `secretEnv` is read once at apply and handed straight to the API (see
    -- `docs/providers.md`); nothing reports whether the currently-bound value
    -- differs from the target, so it is not compared — same limitation as
    -- `SecretsSpec.valueFrom` above.

/-- Total over `Kind`, so a new kind cannot silently compare as always-equal. -/
@[reducible] def divergentOf : (k : Kind) → Divergent k
  | .iam               => inferInstanceAs (Divergent .iam)
  | .objectStore       => inferInstanceAs (Divergent .objectStore)
  | .compute           => inferInstanceAs (Divergent .compute)
  | .queues            => inferInstanceAs (Divergent .queues)
  | .secrets           => inferInstanceAs (Divergent .secrets)
  | .imageRegistry     => inferInstanceAs (Divergent .imageRegistry)
  | .postgres          => inferInstanceAs (Divergent .postgres)
  | .s3Bucket          => inferInstanceAs (Divergent .s3Bucket)
  | .scalewayFunction  => inferInstanceAs (Divergent .scalewayFunction)
  | .scalewayContainer => inferInstanceAs (Divergent .scalewayContainer)

/-- The fields of a resource that disagree with its target. -/
def divergence (k : Kind) (t : ProviderSpec k) (r : Reported k) :
    List (String × Mutability) :=
  (divergentOf k).divergence t r

/-- Whether the observed configuration realises the target.

    Derived from `divergence` rather than written separately, so the boolean
    and the field list can never disagree about what counts as a match. -/
def realises (k : Kind) (t : ProviderSpec k) (r : Reported k) : Bool :=
  (divergence k t r).isEmpty

/-- What has to happen to a resource that already exists.

    `none` means it is already right — the case that makes a second apply come
    back empty, and the one the extent-only comparison could never produce. -/
def repairOf (k : Kind) (t : ProviderSpec k) (r : Reported k) : Option Mutability :=
  let d := divergence k t r
  if d.isEmpty then none
  else if d.any (·.2 == .forcesReplace) then some .forcesReplace
  else some .mutable

end Infra.Core
