import Linen.Data.Yaml
import Infra.Core.Ownership
import Infra.Specs.Kubernetes
import Infra.Interop.Yaml
import Infra.Interop.KubernetesYaml

/-
  Kubernetes YAML in, `kubernetesObject` declarations out — the import half
  of `infra render`, and what `infra import kubernetes` and
  `infra import helm` print.

  Like `Terraform.fleetOfState`, the result is **Lean source text**, not a
  `Plan`: a fleet's keys are derived from its resource names while the file
  elaborates, so importing means writing a declaration to paste and compile.

  ## Typed only when exact

  Each object is offered first to the typed shape its kind has
  (`Specs.shapeOfLive`, the same reading the live backend uses), then to
  `raw`. A shape is accepted only if **rendering it gives back the input**
  (`faithful`): `Specs.renderManifest` of the shape, compared with the
  cleaned input as JSON, ignoring key order, the fleet marker label and
  infra's raw-manifest annotation, and treating an empty `labels` or
  `annotations` as absent. So a Deployment whose container carries a probe,
  a resource limit or a second port name is not squeezed into
  `deployment …` — it imports as `raw`, whole. `Imported.faithful` carries
  that check as a proof field, so no `Imported` exists that skipped it.

  What neither shape can carry is an error, not a quiet loss: `raw` carries
  every top-level field and, of `metadata`, only `name`, `namespace` (both
  in the address), `labels` and `annotations` — so `finalizers` or
  `generateName` make the import fail and say which object and why.

  ## Skipped, and said so

  Some objects in real YAML are not declarations, and importing them would
  create a second owner. They are listed in the output with a reason and
  never declared:

  * a `Secret` (core `v1`) — its values would be written into Lean source.
    Declare a `secrets` resource and reference it from the workload instead;
  * an object with `ownerReferences` — its controller recreates it
    (ReplicaSets, Pods, ControllerRevisions in `kubectl get all` output);
  * `Endpoints`, `EndpointSlice` and `Event` — maintained by the cluster;
  * an object annotated `helm.sh/hook` — a Helm hook runs at a lifecycle
    point, which a declared object does not have.

  ## Cleaned before comparison

  Output of `kubectl get -o yaml` carries what the server set; this is
  removed, by an enumerated list: `status`, and `metadata.uid`,
  `resourceVersion`, `creationTimestamp`, `generation`, `managedFields`,
  `selfLink`, `deletionTimestamp`, `deletionGracePeriodSeconds`, plus the
  annotations `kubectl.kubernetes.io/last-applied-configuration` and
  `deployment.kubernetes.io/revision`. Anything else the server defaulted
  (a Service's `clusterIP`, a Deployment's `strategy`) is kept and makes the
  object `raw` — infra cannot tell a default from a choice.

  `infra render` output reads back as what was declared: the marker label is
  dropped, a raw object's manifest annotation is its shape, and the
  `secret-env` annotation maps a workload's secret placeholders back to
  `.secret` entries. A workload with that annotation that is *not*
  expressible as its typed shape is refused: as `raw` its secret values
  would be written into the declaration.

  ## Namespaces

  A namespaced object's address takes its `metadata.namespace`, or the
  importer's default (`--namespace`, `default`). A cluster-scopedDoc object's is
  `_`: a built-in kind from `clusterScopedKinds`, or a custom kind whose
  `CustomResourceDefinition` in the same input says `scope: Cluster`. A
  custom kind with no CRD in the input is assumed namespaced, and the output
  says so above that object.
-/

namespace Infra.Interop.KubernetesImport

open Data.Json (Value)
open Infra.Core (markerKey ProviderId)
open Infra.Specs

/-! ## JSON helpers -/

/-- A value with every object's fields sorted by key, recursively: the form
    two values are compared in, since key order means nothing in a manifest. -/
def canon : Value → Value
  | .object fs => .object ((fs.attach.map fun ⟨(k, v), _⟩ => (k, canon v)).mergeSort
      fun a b => decide (a.1 ≤ b.1))
  | .array xs  => .array (xs.attach.map fun ⟨x, _⟩ => canon x)
  | v          => v
decreasing_by
  all_goals simp_wf
  all_goals first
    | (have := List.sizeOf_lt_of_mem ‹(k, v) ∈ fs›; simp at this; omega)
    | (have := Array.sizeOf_lt_of_mem ‹x ∈ xs›; omega)

/-- Whether two values are the same manifest, key order aside. Compared
    through the encoder, which is exact for every number `JsonExact`
    admits — and the importer refuses the others before comparing. -/
def sameJson (a b : Value) : Bool :=
  Data.Json.Encode.encode (canon a) == Data.Json.Encode.encode (canon b)

private def fieldsOf (v : Value) : List (String × Value) := v.asObject.getD []

private def strAt (v : Value) (k : String) : Option String := (v.lookup k).bind (·.asString)

/-- `fs` with `k` replaced by `f` of its value; unchanged if `k` is absent. -/
private def updateField (fs : List (String × Value)) (k : String) (f : Value → Value) :
    List (String × Value) :=
  fs.map fun (k', v) => if k' == k then (k', f v) else (k', v)

/-- `fs` with `k` set to `v`, appended if absent. -/
private def putField (fs : List (String × Value)) (k : String) (v : Value) :
    List (String × Value) :=
  if fs.any (·.1 == k) then updateField fs k fun _ => v else fs ++ [(k, v)]

/-- A string map field (`labels`, `annotations`) as pairs, string values only. -/
private def stringMap (md : List (String × Value)) (k : String) : List (String × String) :=
  ((md.lookup k).bind (·.asObject) |>.getD []).filterMap fun (k, v) => v.asString.map (k, ·)

/-- `metadata` with the map `k` filtered by `keep`, and removed when empty. -/
private def filterMap' (md : List (String × Value)) (k : String) (keep : String → Bool) :
    List (String × Value) :=
  match md.lookup k with
  | some (.object fs) =>
    let fs' := fs.filter (keep ·.1)
    if fs'.isEmpty then md.filter (·.1 != k) else updateField md k fun _ => .object fs'
  | some _ => md
  | none   => md

/-- `metadata` without the fleet marker label, an empty `labels` removed. -/
private def withoutMarker (m : Value) : Value :=
  .object (filterMap' (fieldsOf m) "labels" (· != markerKey))

/-- The form both sides of `faithful` are compared in: the marker label —
    on the object and on a StatefulSet's claim templates, the two places the
    renderer writes it — and the raw-manifest annotation dropped, empty
    `labels`/`annotations` removed. The renderer adds both; the marker's
    value is the fleet's, which an import does not carry over. -/
def normalize (v : Value) : Value :=
  match v with
  | .object fs =>
    let fs := updateField fs "metadata" fun m =>
      .object (filterMap' (fieldsOf (withoutMarker m)) "annotations" (· != manifestAnnotation))
    .object (updateField fs "spec" fun spec =>
      .object (updateField (fieldsOf spec) "volumeClaimTemplates" fun
        | .array ts => .array (ts.map fun t =>
            .object (updateField (fieldsOf t) "metadata" withoutMarker))
        | v => v))
  | v => v

/-! ## The witness -/

/-- Whether declaring `shape` at `n` renders exactly `source`. The render's
    secret values are `secretPlaceholder`s — the cleaned input carries the
    same placeholders where the `secret-env` annotation names a variable. -/
def faithful (n : ObjectName) (shape : ObjectShape) (source : Value) : Bool :=
  match renderManifest n shape (markerKey, "import") Infra.Interop.KubernetesYaml.secretPlaceholder with
  | .ok rendered => sameJson (normalize rendered) (normalize source)
  | .error _     => false

/-- One imported object. `faithful` is a proof, so every `Imported` is one
    whose declaration renders exactly the object read. -/
structure Imported where
  name     : ObjectName
  shape    : ObjectShape
  source   : Value
  faithful : faithful name shape source = true
  /-- Said above the declaration: an assumption the importer made. -/
  note     : Option String := none

/-- What became of one object in the input. -/
inductive Item where
  | imported (o : Imported)
  | skipped (what reason : String)

/-! ## Scope -/

/-- The built-in kinds Kubernetes serves cluster-scopedDoc, as `(group, Kind)`,
    the core group `""`. From the Kubernetes 1.31 API reference; a kind
    missing here imports as namespaced, which `objectNameProblem` then
    accepts — so a missing row is a wrong address, and this table is the
    place to fix it. Custom kinds come from CRDs in the same input. -/
def clusterScopedKinds : List (String × String) :=
  [ ("", "Namespace"), ("", "Node"), ("", "PersistentVolume"), ("", "ComponentStatus")
  , ("rbac.authorization.k8s.io", "ClusterRole")
  , ("rbac.authorization.k8s.io", "ClusterRoleBinding")
  , ("apiextensions.k8s.io", "CustomResourceDefinition")
  , ("apiregistration.k8s.io", "APIService")
  , ("storage.k8s.io", "StorageClass"), ("storage.k8s.io", "CSIDriver")
  , ("storage.k8s.io", "CSINode"), ("storage.k8s.io", "VolumeAttachment")
  , ("scheduling.k8s.io", "PriorityClass")
  , ("networking.k8s.io", "IngressClass")
  , ("node.k8s.io", "RuntimeClass")
  , ("certificates.k8s.io", "CertificateSigningRequest")
  , ("admissionregistration.k8s.io", "ValidatingWebhookConfiguration")
  , ("admissionregistration.k8s.io", "MutatingWebhookConfiguration")
  , ("admissionregistration.k8s.io", "ValidatingAdmissionPolicy")
  , ("admissionregistration.k8s.io", "ValidatingAdmissionPolicyBinding")
  , ("flowcontrol.apiserver.k8s.io", "FlowSchema")
  , ("flowcontrol.apiserver.k8s.io", "PriorityLevelConfiguration") ]

/-- Custom kinds' scopes, read off the CRDs in the input:
    `(group, Kind, clusterScoped)`. -/
def crdScopes (docs : List Value) : List (String × String × Bool) :=
  docs.filterMap fun d =>
    if strAt d "kind" == some "CustomResourceDefinition" then do
      let spec ← d.lookup "spec"
      let group ← strAt spec "group"
      let kind ← (spec.lookup "names").bind (strAt · "kind")
      let scope ← strAt spec "scope"
      pure (group, kind, scope == "Cluster")
    else none

/-- The API groups Kubernetes itself serves (1.31), the core group `""`. A
    kind in one of them that `clusterScopedKinds` does not list is
    namespaced. Enumerated rather than matched on `.k8s.io`: CRD-served groups
    use that suffix too (`gateway.networking.k8s.io`'s `GatewayClass` is
    cluster-scopedDoc). -/
def builtinGroups : List String :=
  [ "", "apps", "batch", "autoscaling", "policy", "networking.k8s.io"
  , "rbac.authorization.k8s.io", "storage.k8s.io", "scheduling.k8s.io", "node.k8s.io"
  , "certificates.k8s.io", "admissionregistration.k8s.io", "apiextensions.k8s.io"
  , "apiregistration.k8s.io", "coordination.k8s.io", "discovery.k8s.io", "events.k8s.io"
  , "flowcontrol.apiserver.k8s.io", "resource.k8s.io" ]

/-- Whether a kind is cluster-scopedDoc: `some true`/`some false` when known,
    `none` for a custom kind no CRD in the input describes. -/
def scopeOf (crds : List (String × String × Bool)) (apiVersion kind : String) : Option Bool :=
  let g := apiGroupOf apiVersion
  if clusterScopedKinds.contains (g, kind) then some true
  else if builtinGroups.contains g then some false
  else (crds.find? fun (g', k', _) => g' == g && k' == kind).map (·.2.2)

/-! ## One object -/

/-- How the importer places objects: the cluster every address names, and the
    namespace for a namespaced object that does not say. -/
structure Options where
  cluster   : String := "main"
  ns        : String := "default"
  deriving Repr

/-- Metadata the server sets, removed before anything is compared. -/
def serverMetadata : List String :=
  [ "uid", "resourceVersion", "creationTimestamp", "generation", "managedFields", "selfLink"
  , "deletionTimestamp", "deletionGracePeriodSeconds" ]

/-- Annotations tools set, removed likewise. -/
def serverAnnotations : List String :=
  ["kubectl.kubernetes.io/last-applied-configuration", "deployment.kubernetes.io/revision"]

/-- The metadata keys a declaration can carry. Any other is an error. -/
def carriedMetadata : List String := ["name", "namespace", "labels", "annotations"]

/-- Why an object is not a declaration, if it is not one. -/
def skipReason (apiVersion kind : String) (md : List (String × Value)) : Option String :=
  let owners := (md.lookup "ownerReferences").bind (·.asArray) |>.getD #[]
  if let some o := owners[0]? then
    some s!"owned by {strAt o "kind" |>.getD "?"}/{strAt o "name" |>.getD "?"}, \
whose controller recreates it"
  else if apiVersion == "v1" && kind == "Secret" then
    some "a Secret's values would be written into the declaration — declare a `secrets` \
resource and reference it from the workload (`.secret`)"
  else if (stringMap md "annotations").any (·.1 == "helm.sh/hook") then
    some "a Helm hook runs at a lifecycle point, which a declared object does not have"
  else if (apiVersion == "v1" && (kind == "Endpoints" || kind == "Event"))
      || (apiGroupOf apiVersion == "discovery.k8s.io" && kind == "EndpointSlice")
      || (apiGroupOf apiVersion == "events.k8s.io" && kind == "Event") then
    some "maintained by the cluster"
  else none

/-- A workload's containers' secret-sourced values replaced by placeholders,
    for the variables the `secret-env` annotation names. -/
private def redactSecretEnv (secretEnv : List (String × String)) (obj : Value) : Value :=
  if secretEnv.isEmpty then obj else
  let redactEnv (e : Value) : Value :=
    match strAt e "name" >>= (List.lookup · secretEnv) with
    | some sec => .object (putField (fieldsOf e) "value"
        (.string (Infra.Interop.KubernetesYaml.secretPlaceholder sec)))
    | none => e
  let redactContainer (c : Value) : Value :=
    .object (updateField (fieldsOf c) "env" fun
      | .array es => .array (es.map redactEnv)
      | v => v)
  .object (updateField (fieldsOf obj) "spec" fun spec =>
    .object (updateField (fieldsOf spec) "template" fun t =>
      .object (updateField (fieldsOf t) "spec" fun ps =>
        .object (updateField (fieldsOf ps) "containers" fun
          | .array cs => .array (cs.map redactContainer)
          | v => v))))

/-- A raw shape's manifest text: the object without `apiVersion`/`kind`, and
    of its metadata only the labels and annotations (name and namespace are
    the address). -/
def rawManifest (obj : Value) : Except String String :=
  let fs := (fieldsOf obj).filter fun (k, _) => k != "apiVersion" && k != "kind"
  let fs := updateField fs "metadata" fun m =>
    .object ((fieldsOf m).filter fun (k, _) => k == "labels" || k == "annotations")
  let fs := match fs.lookup "metadata" with
    | some (.object []) => fs.filter (·.1 != "metadata")
    | _ => fs
  Infra.Core.JsonExact.encodeExact "the manifest" (.object fs)

/-- One document: imported, skipped, or why it cannot be imported. -/
def importObject (opts : Options) (crds : List (String × String × Bool)) (doc : Value) :
    Except String Item := do
  let some _ := doc.asObject | throw "a document is not a mapping"
  let some apiVersion := strAt doc "apiVersion" | throw "a document has no apiVersion"
  let some kind := strAt doc "kind" | throw "a document has no kind"
  let md := fieldsOf ((doc.lookup "metadata").getD (.object []))
  let some name := strAt (.object md) "name"
    | throw s!"a {kind} has no metadata.name{if md.any (·.1 == "generateName") then
        " (generateName is not a declaration: the server picks the name)" else ""}"
  let what := s!"{kind} {name}"
  if let some reason := skipReason apiVersion kind md then return .skipped what reason
  -- Clean: what the server set, the fleet marker, infra's raw annotation.
  let annotations := stringMap md "annotations"
  let declaredRaw := annotations.lookup manifestAnnotation
  let secretEnv := (annotations.lookup secretEnvAnnotation).map decodeSecretEnv |>.getD []
  let md := md.filter (!serverMetadata.contains ·.1)
  let md := filterMap' md "annotations" fun k =>
    !serverAnnotations.contains k && k != manifestAnnotation
  let md := filterMap' md "labels" (· != markerKey)
  -- Where it lives.
  let scope := scopeOf crds apiVersion kind
  let clusterScoped := scope.getD false
  let declaredNs := strAt (.object md) "namespace"
  if clusterScoped && declaredNs.isSome then
    throw s!"{what}: a {kind} is cluster-scopedDoc, but it names namespace '{declaredNs.getD ""}'"
  let ns := if clusterScoped then "_" else declaredNs.getD opts.ns
  let md := if clusterScoped then md else putField md "namespace" (.string ns)
  let note := if scope.isNone then
      some s!"{kind} ({apiVersion}) is not a built-in kind and no CRD in the input gives its \
scope: assumed namespaced"
    else none
  let unsupported := md.filter (!carriedMetadata.contains ·.1) |>.map (·.1)
  unless unsupported.isEmpty do
    throw s!"{what}: metadata.{String.intercalate ", metadata." unsupported} cannot be declared \
(a declaration carries name, namespace, labels and annotations)"
  let fs := (fieldsOf doc).filter (·.1 != "status")
  -- `normalize` also takes the source fleet's marker off claim templates, so
  -- a raw StatefulSet does not carry another fleet's label into this one.
  let cleaned := normalize (redactSecretEnv secretEnv (.object (putField fs "metadata" (.object md))))
  if let n :: _ := Infra.Core.JsonExact.lossyNumbers cleaned then
    throw s!"{what}: holds the number {n}, which would be sent as \
{Data.Json.Encode.renderNumber n} — write it as a string"
  -- The shape: infra's own raw annotation, else typed, else raw.
  let probe : ObjectShape := .raw apiVersion kind "{}"
  let n : ObjectName := { cluster := opts.cluster, ns, kind := probe.kindSegment, name }
  let candidates : List ObjectShape ← match declaredRaw with
    | some m => pure [.raw apiVersion kind m]
    | none =>
      let typed := match kind, apiVersion with
        | "Deployment", "apps/v1" | "StatefulSet", "apps/v1" | "Service", "v1" =>
          (shapeOfLive { n with kind := (if kind == "Service" then "service"
                                          else s!"{kind.toLower}.apps") } cleaned).toList
        | _, _ => []
      -- A secret-sourced workload must be typed: as raw, its values are in the text.
      if secretEnv.isEmpty then pure (typed ++ [.raw apiVersion kind (← rawManifest cleaned)])
      else pure typed
  let found := candidates.findSome? fun shape =>
    let n' := { n with kind := shape.kindSegment }
    if h : faithful n' shape cleaned = true then
      some ({ name := n', shape, source := cleaned, faithful := h, note } : Imported)
    else none
  match found with
  | some o =>
    if let some p := objectNameProblem o.name.render o.shape then throw s!"{what}: {p}"
    if let some p := o.shape.problem then throw s!"{what}: {p}"
    return .imported o
  | none =>
    if !secretEnv.isEmpty then
      throw s!"{what}: carries secret-sourced values ({secretEnvAnnotation}) but is not \
expressible as a typed {kind}; as a raw object its values would be written into the declaration"
    else
      throw s!"{what}: does not render back as itself"

/-! ## Documents -/

/-- The objects of a stream: empty documents dropped, a `kind: List`'s items
    spliced in. -/
def objectsOf (docs : List Value) : List Value :=
  docs.flatMap fun
    | .null => []
    | d => if strAt d "kind" == some "List" && (d.lookup "items").isSome then
             ((d.lookup "items").bind (·.asArray) |>.getD #[]).toList
           else [d]

/-- Every object of a YAML stream, each imported or skipped; or every reason
    the stream cannot be imported, one per line. -/
def importText (opts : Options) (text : String) : Except String (List Item) := do
  let ys ← (Data.Yaml.parseDocuments text).mapError (s!"not YAML: " ++ ·)
  let docs := objectsOf (ys.map Infra.Interop.Yaml.ofYaml)
  let crds := crdScopes docs
  let results := docs.map (importObject opts crds)
  let errors := results.filterMap fun | .error e => some e | .ok _ => none
  let items := results.filterMap fun | .ok i => some i | .error _ => none
  let addresses := items.filterMap fun | .imported o => some o.name.render | .skipped .. => none
  let dups := addresses.filter fun a => addresses.count a > 1
  let errors := errors ++ (dups.eraseDups.map (s!"{·} is declared twice"))
  unless errors.isEmpty do throw (String.intercalate "\n" errors)
  return items

/-! ## Lean source -/

private def hex2 (n : Nat) : String :=
  let d := Nat.toDigits 16 n
  String.ofList (List.replicate (2 - d.length) '0' ++ d)

/-- A Lean string literal. -/
def leanString (s : String) : String :=
  let esc : Char → String
    | '"'  => "\\\""
    | '\\' => "\\\\"
    | '\n' => "\\n"
    | '\t' => "\\t"
    | '\r' => "\\r"
    | c    => if c.toNat < 0x20 || c.toNat == 0x7f then "\\x" ++ hex2 c.toNat else c.toString
  "\"" ++ String.join (s.toList.map esc) ++ "\""

def envSource : EnvVar → String
  | .lit n v    => s!".lit {leanString n} {leanString v}"
  | .secret n s => s!".secret {leanString n} {leanString s}"

private def envArg (env : List EnvVar) : String :=
  if env.isEmpty then "" else s!" (env := [{String.intercalate ", " (env.map envSource)}])"

/-- A shape as the builder call that declares it, defaults left out. -/
def shapeSource : ObjectShape → String
  | .deployment i r p e =>
    s!"deployment (image := {leanString i})"
      ++ (if r == 1 then "" else s!" (replicas := {r})")
      ++ (if p.isEmpty then "" else s!" (ports := {p})") ++ envArg e
  | .statefulSet i r p e st =>
    s!"statefulSet (image := {leanString i})"
      ++ (if r == 1 then "" else s!" (replicas := {r})")
      ++ (if p.isEmpty then "" else s!" (ports := {p})") ++ envArg e
      ++ (match st with
          | some c => s!" (storage := some \{ sizeGb := {c.sizeGb}, storageClass := \
{leanString c.storageClass}, mountPath := {leanString c.mountPath} })"
          | none => "")
  | .service port t sel =>
    s!"service {port}"
      ++ (if t == 0 then "" else s!" (targetPort := {t})")
      ++ (if sel.isEmpty then "" else
          s!" (selector := [{String.intercalate ", "
            (sel.map fun (k, v) => s!"({leanString k}, {leanString v})")}])")
  | .raw av k m => s!"rawObject {leanString av} {leanString k} {leanString m}"

/-- One `resource` line, at `indent`. -/
def resourceSource (indent : String) (o : Imported) : String :=
  let note := match o.note with
    | some n => s!"{indent}-- {n}\n"
    | none   => ""
  s!"{note}{indent}resource kubernetesObject {leanString o.name.render}\n\
{indent}  \{ shape := {shapeSource o.shape} }"

/-- The fields the cloud's cluster needs that YAML cannot say, for the stub. -/
def clusterFieldsNeeded : ProviderId → String
  | .aws      => "nodeType, network, clusterRole and nodeRole"
  | .scaleway => "nodeType and network"
  | .gcp      => "nodeType"

/-- The import as a `fleet` declaration (or, `objectsOnly`, just its
    `resource` lines, to paste into a fleet that declares the cluster).

    The cluster is a stub with no fields — its node type, network and roles
    are the cloud's and are in no manifest — so the declaration does not
    compile until they are supplied, and the error names each one: the
    `fleetOfState` convention. -/
def fleetSource (fleetIdent : String) (cloud : ProviderId) (opts : Options) (origin : String)
    (items : List Item) (objectsOnly : Bool := false) : String :=
  let imported := items.filterMap fun | .imported o => some o | .skipped .. => none
  let skipped := items.filterMap fun | .skipped w r => some (w, r) | .imported _ => none
  let typed := imported.filter fun o => !(o.shape matches .raw ..)
  let header := [ s!"-- Imported from {origin} by `infra import`."
    , s!"-- {imported.length} object(s): {typed.length} typed, \
{imported.length - typed.length} raw; {skipped.length} skipped."
    , "-- Every declaration renders exactly the object it was read from (`infra render`"
    , "-- prints it back); `raw` is used wherever a typed shape could not say all of it." ]
  let skippedLines := skipped.map fun (w, r) => s!"-- skipped {w}: {r}"
  if objectsOnly then
    String.intercalate "\n" (header ++ skippedLines ++ imported.map (resourceSource "")) ++ "\n"
  else
    let cluster := s!"    -- The cluster the objects live in. A manifest does not say its \
{clusterFieldsNeeded cloud}:\n    -- this does not compile until they are supplied.\n    \
resource kubernetesCluster {leanString opts.cluster} \{ }"
    String.intercalate "\n" (header
      ++ ["-- Add a placement (`in <locality>`) and the cluster's fields, and this is a fleet."]
      ++ skippedLines
      ++ [s!"fleet {fleetIdent} where", s!"  provider {cloud.name} where", cluster]
      ++ imported.map (resourceSource "    ")) ++ "\n"

/-! ## Checks -/

private def shapesOf (text : String) (opts : Options := {}) : Option (List (String × ObjectShape)) :=
  match importText opts text with
  | .ok items => some (items.filterMap fun
      | .imported o => some (o.name.render, o.shape) | .skipped .. => none)
  | .error _ => none

private def skippedOf (text : String) : Option (List String) :=
  match importText {} text with
  | .ok items => some (items.filterMap fun | .skipped w _ => some w | .imported _ => none)
  | .error _ => none

private def errorOf (text : String) : Option String :=
  match importText {} text with
  | .error e => some e
  | .ok _    => none

private def mentions (s t : String) : Bool := (s.splitOn t).length > 1

/- The round trip `render` → import, typed shapes and a secret included: what
   infra renders reads back as what was declared. -/
private def rtShapes : List (ObjectName × ObjectShape) :=
  [ ({ cluster := "main", ns := "default", kind := "statefulset.apps", name := "pg" },
      .statefulSet "postgres:17" 1 [5432] [.lit "POSTGRES_USER" "dbadmin", .secret "PW" "db-pw"]
        (some { sizeGb := 20, storageClass := "scw-bssd", mountPath := "/var/lib/postgresql" }))
  , ({ cluster := "main", ns := "apps", kind := "deployment.apps", name := "web" },
      .deployment "nginx:1.27" 2 [80, 443] [.lit "MODE" "on"])
  , ({ cluster := "main", ns := "default", kind := "service", name := "pg" }, .service 5432)
  , ({ cluster := "main", ns := "default", kind := "service", name := "web" },
      .service 80 8080 [("tier", "front")])
  , ({ cluster := "main", ns := "default", kind := "configmap", name := "cfg" },
      .raw "v1" "ConfigMap" "{\"data\":{\"a\":\"1\",\"tpl\":\"{{ x }}\"}}")
  , ({ cluster := "main", ns := "_", kind := "namespace", name := "apps" },
      .raw "v1" "Namespace" "{}") ]

private def rtText : String :=
  String.intercalate "\n" (rtShapes.filterMap fun (n, s) =>
    (Infra.Interop.KubernetesYaml.document .scaleway n.render n s "my-fleet").toOption)

#guard shapesOf rtText = some (rtShapes.map fun (n, s) => (n.render, s))

/- A raw StatefulSet keeps its claim template, minus the source fleet's marker. -/
#guard (shapesOf "apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: db
spec:
  serviceName: db
  volumeClaimTemplates:
  - metadata:
      name: data
      labels:
        managed-by-infra: old-fleet
        keep: me
").any fun shapes => shapes.any fun
  | (_, .raw _ _ m) => mentions m "\"keep\":\"me\"" && !mentions m "old-fleet"
  | _ => false

/- Plain YAML: typed when exact, raw when a typed shape would drop something. -/
private def plain : String := "apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: web
        image: nginx:1.27
        ports:
        - containerPort: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: probed
  labels:
    tier: front
spec:
  replicas: 1
  selector:
    matchLabels:
      app: probed
  template:
    metadata:
      labels:
        app: probed
    spec:
      containers:
      - name: probed
        image: nginx:1.27
        readinessProbe:
          httpGet:
            path: /
            port: 80
"
#guard (shapesOf plain).map (·.map (·.1)) =
  some ["main/default/deployment.apps/web", "main/default/deployment.apps/probed"]
#guard (shapesOf plain).bind (·.lookup "main/default/deployment.apps/web") =
  some (.deployment "nginx:1.27" 3 [80] [])
#guard ((shapesOf plain).bind (·.lookup "main/default/deployment.apps/probed")).any
  fun | .raw "apps/v1" "Deployment" m => mentions m "readinessProbe" && mentions m "tier"
      | _ => false

/- The options place the objects. -/
#guard (shapesOf plain { cluster := "prod", ns := "web" }).map (·.map (·.1)) =
  some ["prod/web/deployment.apps/web", "prod/web/deployment.apps/probed"]

/- `kubectl get -o yaml` output: what the server set is cleaned away; owned
   objects, Secrets, Endpoints and hooks are skipped by name. -/
private def live : String := "apiVersion: v1
kind: List
items:
- apiVersion: v1
  kind: ConfigMap
  metadata:
    name: cfg
    namespace: default
    uid: 0d6c
    resourceVersion: \"42\"
    creationTimestamp: \"2026-11-17T10:00:00Z\"
    annotations:
      kubectl.kubernetes.io/last-applied-configuration: \"{}\"
    managedFields:
    - manager: kubectl
  data:
    a: \"1\"
- apiVersion: apps/v1
  kind: ReplicaSet
  metadata:
    name: web-5d9
    ownerReferences:
    - kind: Deployment
      name: web
- apiVersion: v1
  kind: Secret
  metadata:
    name: creds
  data:
    password: aHVudGVyMg==
- apiVersion: v1
  kind: Endpoints
  metadata:
    name: web
- apiVersion: batch/v1
  kind: Job
  metadata:
    name: migrate
    annotations:
      helm.sh/hook: pre-install
"
#guard shapesOf live = some [("main/default/configmap/cfg", .raw "v1" "ConfigMap" "{\"data\":{\"a\":\"1\"}}")]
#guard skippedOf live = some ["ReplicaSet web-5d9", "Secret creds", "Endpoints web", "Job migrate"]
-- The Secret's value appears nowhere in the output.
#guard match importText {} live with
  | .ok items => !mentions (fleetSource "imported" .scaleway {} "test" items) "aHVudGVyMg"
  | .error _ => false

/- Scopes: built-in cluster-scopedDoc kinds, a CRD's own scope, an unknown kind
   assumed namespaced (and said so). -/
private def scopedDoc : String := "apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: widgets.example.com
spec:
  group: example.com
  scope: Cluster
  names:
    kind: Widget
    plural: widgets
---
apiVersion: example.com/v1
kind: Widget
metadata:
  name: w
---
apiVersion: other.io/v1
kind: Gadget
metadata:
  name: g
"
#guard (shapesOf scopedDoc).map (·.map (·.1)) = some
  [ "main/_/customresourcedefinition.apiextensions.k8s.io/widgets.example.com"
  , "main/_/widget.example.com/w", "main/default/gadget.other.io/g" ]
#guard match importText {} scopedDoc with
  | .ok items => mentions (fleetSource "imported" .scaleway {} "test" items)
      "-- Gadget (other.io/v1) is not a built-in kind and no CRD in the input gives its scope"
  | .error _ => false

/- Refusals: what cannot be declared fails the import, naming the object. -/
#guard (errorOf "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: c\n  finalizers: [x]\n").any
  (mentions · "ConfigMap c: metadata.finalizers cannot be declared")
#guard (errorOf "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  generateName: c-\n").any
  (mentions · "generateName is not a declaration")
#guard (errorOf "apiVersion: v1\nkind: Namespace\nmetadata:\n  name: a\n  namespace: b\n").any
  (mentions · "cluster-scopedDoc")
#guard (errorOf "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: c\n---\n\
apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: c\n").any (mentions · "declared twice")
#guard (errorOf "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: c\ndata:\n  r: 1.0e-7\n").any
  (mentions · "write it as a string")
#guard (errorOf "a: &x 1\n").any (mentions · "not YAML")
-- A secret-sourced workload that is no longer exactly typed is refused, not
-- imported raw with its values in the text.
#guard (errorOf "apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  annotations:
    infra.typednotes.org/secret-env: PW=db-pw
spec:
  replicas: 1
  paused: true
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: web
        image: nginx
        env:
        - name: PW
          value: hunter2
").any fun e => mentions e "secret-sourced values" && !mentions e "hunter2"

/- The Lean source: typed builders with defaults left out, raw manifests as
   escaped strings, and the cluster stub. -/
#guard shapeSource (.deployment "nginx:1.27" 1 [] []) = "deployment (image := \"nginx:1.27\")"
#guard shapeSource (.service 80 8080 [("a", "b")]) =
  "service 80 (targetPort := 8080) (selector := [(\"a\", \"b\")])"
#guard shapeSource (.raw "v1" "ConfigMap" "{\"a\":\"x\\ny\"}") =
  "rawObject \"v1\" \"ConfigMap\" \"{\\\"a\\\":\\\"x\\\\ny\\\"}\""
#guard match importText {} plain with
  | .ok items =>
    let src := fleetSource "imported" .scaleway {} "test" items
    mentions src "fleet imported where\n  provider scaleway where\n"
      && mentions src "resource kubernetesCluster \"main\" { }"
      && mentions src ("    resource kubernetesObject \"main/default/deployment.apps/web\"\n"
        ++ "      { shape := deployment (image := \"nginx:1.27\") (replicas := 3) (ports := [80]) }")
  | .error _ => false

end Infra.Interop.KubernetesImport
