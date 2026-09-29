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

/-- An optional field whose *target* being empty means "not chosen".

    `Field .optional` settles to `""` when the declaration omits it, so the
    target cannot distinguish "I did not choose" from "there must be none" —
    and for a launch-time field the cloud fills in regardless (a subnet, a key
    pair), the second reading is one no cloud can be asked for. Comparing it
    would put the field in every plan for ever; on a `.forcesReplace` field
    that is a fleet that cannot converge, which is what the 2026-09-08 live
    run hit on `AwsInstanceSpec.subnetId`.

    So an unset target is not compared, and the price is stated rather than
    hidden: a fleet that leaves the field out does not notice the cloud's
    choice changing. See `docs/diff-semantics.md`. -/
def divergesIfSet (name : String) (m : Mutability)
    (target : String) (reported : Partial String) : List (String × Mutability) :=
  if target.isEmpty then [] else diverges name m target reported

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
    -- The master user cannot be renamed after creation — for a *classic*
    -- instance. A serverless target (`instanceClass` unset) has no root user
    -- at all: Scaleway's Serverless SQL Database reports none, so `read`
    -- leaves it `""` the way "not found" and "not applicable" both do
    -- elsewhere (see `Live.lean`'s `.postgres` read). Comparing that against
    -- the target's required `masterUsername` would disagree on every single
    -- apply and force-replace the database each time — a live account hit
    -- exactly this on 2026-09-10. So this field only diverges for a classic
    -- target, matching the same `instanceClass.isEmpty` discriminator
    -- `Live.lean` routes create/read on.
    ++ (if t.instanceClass.isEmpty then []
        else divergesReq "masterUsername" .forcesReplace t.masterUsername r.masterUsername)
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

/-- The append-only comparison: the first point at which `applied` stops
    being a prefix of `target` (matching `id` *and* `sql`), if it does.

    `none` covers both "equal" and "applied is a strict prefix" — the two
    states that are legal history. The caller decides what the difference
    between them means. -/
def migrationsConflict (applied target : List Migration) : Option String :=
  match applied, target with
  | [],        _          => none
  | a :: _,    []         => some a.id
  | a :: rest, b :: rest' =>
      if a.id == b.id && a.sql == b.sql then migrationsConflict rest rest'
      else some a.id

/-- What a declared migration set disagrees with its target about, and
    whether it can be fixed in place.

    `migrations` is the interesting one, and it is *not* a `diverges`
    comparison: the reported list is what the database already applied, and
    the legal relationship to the target is "prefix of", not "equal to".
    A strict prefix means pending work — `UPDATE`, which the backend turns
    into applying exactly the suffix. Anything else — an id with different
    content, or an applied id the target no longer names — is a history
    conflict, and `Engine.push` refuses the plan before any action is
    derived, via `Plan.migrationsAppendOnly`. This table still answers it
    (as `forcesReplace`, so a caller using `repairOf` directly cannot read
    conflict as quietly fixable), but `push` gets there first and says what
    the conflict actually is.

    The two secret-name fields are not compared at all: which secret holds
    a URL is bookkeeping, and rotating one must not propose a replace —
    `SecretsSpec.valueFrom`'s reading. `name`, `database` and `schema` are
    `forcesReplace` because the rows live in exactly that database and
    schema: a different one is a different resource, and "replace" here is
    `delete` — a FORGET that does nothing and touches no schema — followed by a
    create against the new parent. -/
instance : Divergent .postgresMigrations where
  divergence t r :=
    divergesReq "name" .forcesReplace t.name r.name
    ++ divergesReq "database" .forcesReplace t.database r.database
    ++ divergesReq "schema" .forcesReplace t.schema r.schema
    ++ (let applied := r.migrations.filterMap MigrationDecl.resolved?
        match resolvedMigrations? t.migrations with
        -- Unfetched SQL cannot be compared; `push` refuses such a plan
        -- before anything reaches this table.
        | none => [("migrations (sources not fetched)", .forcesReplace)]
        | some target =>
          match migrationsConflict applied target with
          | none =>
              if applied.length == target.length then []
              else [("migrations", .mutable)]
          | some _ => [("migrations (history conflict)", .forcesReplace)])

/- The three shapes the prefix comparison exists to tell apart, pinned: no
   applied history is a prefix of anything (a first apply), an exact match is
   not a conflict, and the same id with different content is. The second is
   the one a plain equality would get wrong in the dangerous direction — it
   would call pending work "converged". -/
private def m1 : Migration := { id := "0001", sql := "CREATE SCHEMA x" }
private def m2 : Migration := { id := "0002", sql := "CREATE TABLE x.t ()" }
#guard (migrationsConflict [] [m1, m2]).isNone
#guard (migrationsConflict [m1] [m1, m2]).isNone
#guard (migrationsConflict [m1, m2] [m1, m2]).isNone
#guard migrationsConflict [{ id := "0001", sql := "different" }] [m1] == some "0001"
#guard migrationsConflict [m1, m2] [m1] == some "0002"

/-! ### Kubernetes

  The comparisons here are written out rather than `diverges`, because three
  of the cluster's fields are spelled differently by the declaration and the
  cloud, and comparing the spellings would propose work on every plan: a
  declared minor version against a reported patch release, a role *name*
  against its ARN, a network name against the id the cloud also reports. -/

/-- Whether a reported Kubernetes version realises a declared one, at the
    declared precision: `1.31` is realised by `1.31.4-eks-a1b2`, and `v1.31.4`
    by `1.31.4`. -/
def k8sVersionMatches (declared reported : String) : Bool :=
  let strip (v : String) := if v.startsWith "v" then (v.drop 1).toString else v
  let d := strip declared
  let r := strip reported
  r == d || r.startsWith (d ++ ".") || r.startsWith (d ++ "-") || r.startsWith (d ++ "+")

#guard k8sVersionMatches "1.31" "1.31.4-eks-a1b2"
#guard k8sVersionMatches "1.31.4" "v1.31.4"
#guard ¬ k8sVersionMatches "1.31" "1.310.1"
#guard ¬ k8sVersionMatches "1.31" "1.30.9"

/-- A node type, the way the three clouds compare it: case-insensitively,
    with `-` and `_` the same (Kapsule spells one type both ways). -/
def nodeTypeKey (t : String) : String := (t.toLower.map fun c => if c == '-' then '_' else c)

#guard nodeTypeKey "GP1-S" == nodeTypeKey "gp1_s"

/-- Whether a reported IAM role (an ARN) is the declared one, given as an ARN
    or as a bare role name. -/
def roleMatches (declared reported : String) : Bool :=
  reported == declared || reported.endsWith ("/" ++ declared)

#guard roleMatches "eks-cluster" "arn:aws:iam::123456789012:role/eks-cluster"
#guard ¬ roleMatches "eks" "arn:aws:iam::123456789012:role/eks-cluster"

/-- One optional string field compared with a matcher, only when the target
    sets it — `divergesIfSet` with the equality replaced. -/
def divergesIfSetBy (name : String) (m : Mutability) (realises : String → String → Bool)
    (target : String) (reported : Partial String) : List (String × Mutability) :=
  if target.isEmpty then [] else
  match reported with
  | .unknown => []
  | .known v => if realises target v then [] else [(name, m)]

/-- A cluster's disagreements.

    Nothing that can be changed in place is a `REPLACE`, because replacing a
    cluster destroys everything running in it: a new `nodeType` or `nodeRole`
    replaces the *node pool* (the backend's `update` creates the new pool,
    then deletes the old, and pods reschedule onto it), and a new `version` is
    an upgrade. Only what no cloud can change on a live cluster forces a
    replace: `network`, and EKS's `clusterRole`.

    `nodeCount` is not compared while the pool autoscales: the autoscaler owns
    the number then, and comparing it would fight it on every plan.

    The reported `network` may carry several spellings of one network,
    newline-separated — an EKS VPC's id and its `Name` tag — and matches if
    the declared one is among them. -/
instance : Divergent .kubernetesCluster where
  divergence t r :=
    -- Bound with its type: projecting straight out of the reducible
    -- `Conc` wrapper makes the code generator emit "invalid projection"
    -- (the same trap `Live.lean` notes for `Handle`).
    let asc : Nat × Nat := t.autoscale
    let tType : String := t.nodeType
    let rType : String := r.nodeType
    divergesReq "name" .forcesReplace t.name r.name
    ++ divergesIfSetBy "version" .mutable k8sVersionMatches t.version r.version
    -- An empty reported type is a cloud that could not say (a pool being
    -- replaced), which is not a request to change it.
    ++ (if rType.isEmpty || nodeTypeKey rType == nodeTypeKey tType then []
        else [("nodeType", .mutable)])
    ++ (if asc.2 == 0 then diverges "nodeCount" .mutable t.nodeCount r.nodeCount else [])
    ++ diverges "autoscale" .mutable t.autoscale r.autoscale
    ++ divergesIfSetBy "network" .forcesReplace
         (fun d rep => (rep.splitOn "\n").contains d) t.network r.network
    ++ divergesIfSetBy "clusterRole" .forcesReplace roleMatches t.clusterRole r.clusterRole
    ++ divergesIfSetBy "nodeRole" .mutable roleMatches t.nodeRole r.nodeRole

/-- What an object's shape disagrees with, field by field, and whether each
    can change in place. Defaults are compared in the form they take on the
    wire — a service's `targetPort` of `0` is its `port`, an empty selector is
    `app = <name>` — so a declaration that spells a default out, and one that
    leaves it implicit, both converge. Environment lists compare as sets, and
    a secret-sourced variable by its secret's *name*: its value is never
    reported, so a changed value is not drift (`--refresh-secrets` rewrites
    it). A raw manifest compares as JSON, so whitespace is not drift. -/
def objectShapeDivergence (objName : String) :
    Infra.Specs.ObjectShape → Infra.Specs.ObjectShape → List (String × Mutability)
  | .deployment i r p e, .deployment i' r' p' e' =>
    divergesReq "image" .mutable i i' ++ divergesReq "replicas" .mutable r r'
    ++ divergesSet "ports" .mutable toString p (.known p')
    ++ divergesSet "env" .mutable Infra.Specs.EnvVar.key e (.known e')
  | .statefulSet i r p e st, .statefulSet i' r' p' e' st' =>
    divergesReq "image" .mutable i i' ++ divergesReq "replicas" .mutable r r'
    ++ divergesSet "ports" .mutable toString p (.known p')
    ++ divergesSet "env" .mutable Infra.Specs.EnvVar.key e (.known e')
    -- Kubernetes refuses any change to `volumeClaimTemplates`.
    ++ divergesReq "storage" .forcesReplace st st'
  | .service p t sel, .service p' t' sel' =>
    let objShort := ((Infra.Specs.ObjectName.parse? objName).map (·.name)).getD objName
    let eff (port target : Nat) := if target == 0 then port else target
    let effSel (s : List (String × String)) :=
      if s.isEmpty then [(Infra.Specs.appLabel, objShort)] else s
    divergesReq "port" .mutable p p'
    ++ divergesReq "targetPort" .mutable (eff p t) (eff p' t')
    ++ divergesSet "selector" .mutable pairKey (effSel sel) (.known (effSel sel'))
  | .raw av k m, .raw av' k' m' =>
    let asJson (s : String) := (Data.Json.Decode.decode s).toOption
    divergesReq "apiVersion" .forcesReplace av av' ++ divergesReq "kind" .forcesReplace k k'
    ++ (if asJson m == asJson m' && (asJson m).isSome then [] else
        if m == m' then [] else [("manifest", .mutable)])
  -- A different kind of object behind the same address: nothing converts one
  -- into the other in place.
  | _, _ => [("shape", .forcesReplace)]

instance : Divergent .kubernetesObject where
  divergence t r :=
    divergesReq "name" .forcesReplace t.name r.name
    ++ objectShapeDivergence t.name t.shape r.shape

section
open Infra.Specs
#guard (objectShapeDivergence "c/default/service/pg" (.service 5432) (.service 5432 5432
  [("app", "pg")])).isEmpty
#guard objectShapeDivergence "c/default/deployment.apps/w" (.deployment "a:1" 1 [80, 443])
  (.deployment "a:2" 1 [443, 80]) == [("image", .mutable)]
#guard objectShapeDivergence "c/default/statefulset.apps/pg"
  (.statefulSet "p" 1 [] [] (some { sizeGb := 20, storageClass := "x" }))
  (.statefulSet "p" 1 [] [] (some { sizeGb := 10, storageClass := "x" }))
  == [("storage", .forcesReplace)]
-- A secret's value is never compared: only which secret it comes from.
#guard (objectShapeDivergence "c/default/deployment.apps/w"
  (.deployment "a" 1 [] [.secret "PW" "db"]) (.deployment "a" 1 [] [.secret "PW" "db"])).isEmpty
#guard (objectShapeDivergence "c/default/configmap/cfg" (.raw "v1" "ConfigMap" "{\"a\": 1}")
  (.raw "v1" "ConfigMap" "{\"a\":1}")).isEmpty
end

instance : Divergent .s3Bucket where
  divergence t r :=
    divergesReq "name" .forcesReplace t.name r.name
    ++ diverges "versioning" .mutable t.versioning r.versioning
    -- Object Lock can only be set when the bucket is created.
    ++ diverges "objectLock" .forcesReplace t.objectLock r.objectLock

instance : Divergent .securityGroup where
  divergence t r :=
    divergesReq "name" .forcesReplace t.name r.name
    -- EC2 has no API for changing a group's description after creation.
    ++ divergesReq "description" .forcesReplace t.description r.description
    -- Rules can be authorized on a live group. Compared as a set, since the
    -- order EC2 reports them in is not the order they were given.
    -- `pairKey` rather than a bespoke separator: it uses `\u0000`, chosen so a
    -- key containing the separator cannot collide, and that only stays true
    -- while there is one copy of it.
    ++ divergesSet "ingress" .mutable (fun (port, cidr) => pairKey (toString port, cidr))
         t.ingress r.ingress

instance : Divergent .awsInstance where
  divergence t r :=
    -- The `Name` tag, which `CreateTags` can change on a live instance.
    divergesReq "name" .mutable t.name r.name
    -- A running instance cannot change image — but `"latest"` is not an image
    -- id, it is an instruction, and `Infra.Providers.Live` carries it out
    -- inside `create` (`DescribeImages` for the newest Amazon Linux 2023 in
    -- the instance's own region). So the target holds the word and the
    -- instance reports `ami-…`, which are never equal: comparing them puts
    -- `REPLACE` in every plan for ever, and each apply destroys and recreates
    -- a healthy instance. The live test hit exactly that.
    --
    -- The price is stated rather than hidden: a fleet that says `"latest"` is
    -- not rebuilt when AWS publishes a newer image. That is the weaker of the
    -- two readings of the word — "latest at create time", not "track latest" —
    -- and it is the only one this tool can implement, because rebuilding on a
    -- schedule set by someone else's release cadence is not something a diff
    -- should decide. Pin an id to get drift detection back.
    ++ (if t.imageId == "latest" then []
        else divergesReq "imageId" .forcesReplace t.imageId r.imageId)
    -- EC2 *can* resize a stopped instance, but this tool never stops one, so
    -- the honest classification for what it will actually do is replace — and
    -- a plan says REPLACE before anything is applied. See `docs/providers.md`.
    ++ divergesReq "instanceType" .forcesReplace t.instanceType r.instanceType
    -- `ModifyInstanceAttribute` reassigns groups on a running instance.
    ++ divergesReq "securityGroup" .mutable t.securityGroup r.securityGroup
    -- Both are launch-time only, and both are optional fields the cloud fills
    -- in whether or not the declaration asked: every instance is in a subnet.
    -- So an unset one is not a request — `divergesIfSet`, not `diverges`,
    -- or the plan proposes REPLACE for ever and the fleet never converges.
    ++ divergesIfSet "keyName" .forcesReplace t.keyName r.keyName
    ++ divergesIfSet "subnetId" .forcesReplace t.subnetId r.subnetId

/-- Both namespace kinds compare the same two fields. A namespace cannot be
    renamed — the name is its identity here, as with a bucket. -/
private def namespaceDivergence
    (t : ProviderSpec .scalewayFunctionNamespace) (r : Reported .scalewayFunctionNamespace) :
    List (String × Mutability) :=
  divergesReq "name" .forcesReplace t.name r.name
  ++ diverges "description" .mutable t.description r.description

instance : Divergent .scalewayFunctionNamespace where
  divergence t r := namespaceDivergence t r

instance : Divergent .scalewayContainerNamespace where
  divergence t r := namespaceDivergence t r

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
  | .postgresMigrations  => inferInstanceAs (Divergent .postgresMigrations)
  | .kubernetesCluster => inferInstanceAs (Divergent .kubernetesCluster)
  | .kubernetesObject  => inferInstanceAs (Divergent .kubernetesObject)
  | .s3Bucket          => inferInstanceAs (Divergent .s3Bucket)
  | .securityGroup     => inferInstanceAs (Divergent .securityGroup)
  | .awsInstance       => inferInstanceAs (Divergent .awsInstance)
  | .scalewayFunctionNamespace  => inferInstanceAs (Divergent .scalewayFunctionNamespace)
  | .scalewayFunction  => inferInstanceAs (Divergent .scalewayFunction)
  | .scalewayContainerNamespace => inferInstanceAs (Divergent .scalewayContainerNamespace)
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
