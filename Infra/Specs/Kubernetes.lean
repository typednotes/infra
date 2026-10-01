import Linen.Data.Json.Encode
import Linen.Data.Json.Decode
import Lean.Data.Json
import Infra.Core.JsonExact
import Infra.Core.Image

/-
  The pure half of the two Kubernetes kinds: what an in-cluster object is,
  how its fleet name is spelled, and the manifest a declaration renders to.

  Kept free of any backend so that three readers share one copy: the
  plan-time checks (`Plan.kubernetesProblem`), the live object backend
  (`Kinds.Kubernetes`), and the Terraform exporter. Two renderings of the
  same object would drift, and the drift would be a plan that never
  converges.

  ## An object's fleet name is its address

  A fleet key's name must equal the cloud-side identifier (`Keys.name`, and
  `Engine.pullEntries` matching a listing by it), and an in-cluster object is
  only identified by four things together — the cluster, the namespace, the
  object's kind and its name. So the fleet name *is* those four, joined:

      <cluster>/<namespace>/<kind>[.<group>]/<name>
      main/default/statefulset.apps/postgres
      main/default/service/postgres

  `<cluster>` is the fleet name of a `kubernetesCluster` on the **same
  cloud** — same-cloud by construction, since the name carries no cloud and
  the engine resolves it on the object's own (`Engine.impliedByName`).
  `<namespace>` is a DNS-1123 label, or `_` for a cluster-scoped object
  (only a `raw` shape can be one). `<kind>` is the lowercased Kubernetes kind
  with its API group, the way `kubectl` spells a resource type
  (`deployment.apps`); the core group has none (`service`). Two objects of
  different kinds can therefore share a name — a Service fronting the
  StatefulSet of the same name — without their keys colliding, which is the
  reason the kind is in the name at all. See `docs/kubernetes.md`, "Where the
  implementation differs".
-/

namespace Infra.Specs

open Data.Json (Value)

/-! ## Environment variables, storage, shapes -/

/-- One environment variable of a workload: a literal, or the value of a
    `secrets` resource on the same cloud, named by its fleet name.

    A secret's value is read once, on the apply path, and written into the
    object; it is never reported back — `read` maps it to its secret's name
    and drops the value (`docs/kubernetes.md`, hard edge 3). -/
inductive EnvVar where
  | lit    (name value : String)
  | secret (name secretName : String)
  deriving Repr, DecidableEq, BEq, Lean.ToJson, Lean.FromJson

def EnvVar.name : EnvVar → String
  | .lit n _ | .secret n _ => n

/-- The sort key for comparing environment lists as sets. -/
def EnvVar.key : EnvVar → String
  | .lit n v    => "l\u0000" ++ n ++ "\u0000" ++ v
  | .secret n s => "s\u0000" ++ n ++ "\u0000" ++ s

/-- A StatefulSet's volume claim template: one `ReadWriteOnce` claim per
    replica, of `sizeGb` GiB in the cluster's `storageClass` (a name — the
    storage class is the cluster's, not infra's), mounted at `mountPath`.

    Immutable once created — Kubernetes refuses a change to a StatefulSet's
    `volumeClaimTemplates` — so a change to any of the three is a `REPLACE`. -/
structure ClaimTemplate where
  sizeGb       : Nat
  storageClass : String
  mountPath    : String := "/data"
  deriving Repr, DecidableEq, BEq, Lean.ToJson, Lean.FromJson

/-- Which in-cluster object a `kubernetesObject` resource is, and its
    configuration. One inductive rather than one `Kind` per object type: a new
    shape is an additive change here, not a new `Kind` and its checklist.

    * `deployment` / `statefulSet` — one container, `replicas` of it, pods
      labelled `app = <name>`. A StatefulSet may carry a volume claim
      template.
    * `service` — a ClusterIP service on `port`, forwarding to `targetPort`
      (`0`: the same as `port`), selecting `selector` (`[]`: pods labelled
      `app = <name>`, the label every workload infra creates carries — so a
      service fronts the workload of the same name without naming it twice).
    * `raw` — any other object, `apiVersion` and `kind` plus the rest of it
      as a JSON object (`spec`, `data`, …), carried verbatim. The escape
      hatch; infra sets `metadata.name`, `namespace` and the marker label
      itself. -/
inductive ObjectShape where
  | deployment (image : String) (replicas : Nat := 1) (ports : List Nat := [])
      (env : List EnvVar := [])
  | statefulSet (image : String) (replicas : Nat := 1) (ports : List Nat := [])
      (env : List EnvVar := []) (storage : Option ClaimTemplate := none)
  | service (port : Nat) (targetPort : Nat := 0) (selector : List (String × String) := [])
  | raw (apiVersion kind : String) (manifest : String)
  deriving Repr, DecidableEq, BEq

/-- Every container image this shape declares. Raw built-in pod workloads
    include sidecars and init containers; custom-resource fields stay opaque. -/
def ObjectShape.images : ObjectShape → List String
  | .deployment i .. | .statefulSet i .. => [i]
  | .service .. => []
  | .raw _ kind text => (do
      let path ← Infra.Core.Image.podPath kind
      let json ← (Data.Json.Decode.decode text).toOption
      let pod ← Infra.Core.Image.atPath json path
      pure (Infra.Core.Image.podImages pod)).getD []

/-- Rewrite only actual container references, preserving the rest of a raw
    manifest, including its numbers, through the exact encoder. -/
def ObjectShape.mapImages (f : String → String) : ObjectShape → ObjectShape
  | .deployment i r p e => .deployment (f i) r p e
  | .statefulSet i r p e st => .statefulSet (f i) r p e st
  | s@(.service ..) => s
  | s@(.raw av kind text) =>
    match Infra.Core.Image.podPath kind, Data.Json.Decode.decode text with
    | some path, .ok json =>
      let mapped := Infra.Core.Image.mapAtPath json (Infra.Core.Image.mapPodImages f) path
      match Infra.Core.JsonExact.encodeExact "container images" mapped with
      | .ok text' => .raw av kind text'
      | .error _ => s -- the declaration's soundness check reports malformed/lossy JSON
    | _, _ => s

/-- The API group of an `apiVersion` — `apps` for `apps/v1`, `""` for the
    core group's `v1`. -/
def apiGroupOf (apiVersion : String) : String :=
  match apiVersion.splitOn "/" with
  | [g, _] => g
  | _      => ""

/-- The `<kind>[.<group>]` segment a shape's fleet name must carry. -/
def ObjectShape.kindSegment : ObjectShape → String
  | .deployment ..  => "deployment.apps"
  | .statefulSet .. => "statefulset.apps"
  | .service ..     => "service"
  | .raw av k _     =>
    let g := apiGroupOf av
    if g.isEmpty then k.toLower else s!"{k.toLower}.{g}"

/-- The API version and kind a shape is served under. -/
def ObjectShape.apiVersionKind : ObjectShape → String × String
  | .deployment ..  => ("apps/v1", "Deployment")
  | .statefulSet .. => ("apps/v1", "StatefulSet")
  | .service ..     => ("v1", "Service")
  | .raw av k _     => (av, k)

/-- The secrets a shape reads, by fleet name. -/
def ObjectShape.secretNames : ObjectShape → List String
  | .deployment _ _ _ env | .statefulSet _ _ _ env _ =>
    env.filterMap fun | .secret _ s => some s | .lit .. => none
  | .service .. | .raw .. => []

/-! ## Names -/

/-- A DNS-1123 label: 1–63 characters of lowercase letters, digits and `-`,
    starting and ending with a letter or digit. What Kubernetes requires of a
    namespace, and of most object names' segments. -/
def isDns1123Label (s : String) : Bool :=
  let cs := s.toList
  let ok (c : Char) := (c.isLower && c.isAlpha) || c.isDigit || c == '-'
  let edge (c : Char) := (c.isLower && c.isAlpha) || c.isDigit
  !cs.isEmpty && cs.length ≤ 63 && cs.all ok
    && (cs.head?.map edge).getD false && (cs.getLast?.map edge).getD false

/-- A DNS-1123 subdomain: dot-separated labels, at most 253 characters. What
    Kubernetes requires of a Deployment's or a ConfigMap's name. -/
def isDns1123Subdomain (s : String) : Bool :=
  s.length ≤ 253 && (s.splitOn ".").all isDns1123Label

/-- A DNS-1035 label: a DNS-1123 label that starts with a letter. What
    Kubernetes requires of a Service's name. -/
def isDns1035Label (s : String) : Bool :=
  isDns1123Label s && ((s.toList.head?.map Char.isAlpha).getD false)

/-- A cluster's fleet name, which is also its cloud-side name on all three
    clouds: a DNS-1035 label of at most 40 characters. The intersection of
    EKS (1–100 of `[A-Za-z0-9_-]`, starting alphanumeric), GKE (lowercase
    letters, digits and `-`, at most 40, starting with a letter) and Kapsule
    (a free-form name), so one name is valid everywhere. -/
def isClusterName (s : String) : Bool :=
  isDns1035Label s && s.length ≤ 40

#guard isDns1123Label "postgres"
#guard isDns1123Label "a-b-1"
#guard ¬ isDns1123Label "-a"
#guard ¬ isDns1123Label "A"
#guard ¬ isDns1123Label ""
#guard ¬ isDns1123Label "a_b"
#guard isDns1123Subdomain "web.v2"
#guard ¬ isDns1123Subdomain "web..v2"
#guard isDns1035Label "postgres"
#guard ¬ isDns1035Label "1db"
#guard isClusterName "main"
#guard ¬ isClusterName "Main"

/-- An in-cluster object's fleet name, parsed: see the module note. -/
structure ObjectName where
  cluster   : String
  /-- The namespace: a DNS-1123 label, or `_` for a cluster-scoped object.
      (`namespace` is a Lean keyword.) -/
  ns        : String
  /-- `<kind>[.<group>]`, lowercased. -/
  kind      : String
  name      : String
  deriving Repr, DecidableEq, BEq

def ObjectName.render (n : ObjectName) : String :=
  s!"{n.cluster}/{n.ns}/{n.kind}/{n.name}"

def ObjectName.parse? (s : String) : Option ObjectName :=
  match s.splitOn "/" with
  | [c, ns, k, n] => some { cluster := c, ns, kind := k, name := n }
  | _             => none

/-- Whether the object is cluster-scoped (namespace segment `_`). -/
def ObjectName.clusterScoped (n : ObjectName) : Bool := n.ns == "_"

#guard (ObjectName.parse? "main/default/service/postgres").map (·.render)
  = some "main/default/service/postgres"
#guard (ObjectName.parse? "main/default/postgres").isNone

/-- What is wrong with an object's fleet name given its shape, if anything.
    `none` means the name is well formed and agrees with the shape. -/
def objectNameProblem (full : String) (shape : ObjectShape) : Option String :=
  match ObjectName.parse? full with
  | none => some s!"'{full}' is not <cluster>/<namespace>/<kind>/<name> — an in-cluster \
object's fleet name is its address; see docs/kubernetes.md"
  | some n =>
    if !isClusterName n.cluster then
      some s!"'{n.cluster}' is not a valid cluster name (lowercase letters, digits and '-', \
starting with a letter, at most 40)"
    else if n.clusterScoped then
      match shape with
      | .raw .. => if isDns1123Subdomain n.name then none
                   else some s!"'{n.name}' is not a DNS-1123 subdomain"
      | _ => some s!"'{full}': only a raw object can be cluster-scoped (namespace '_'); \
a {shape.kindSegment} lives in a namespace"
    else if !isDns1123Label n.ns then
      some s!"'{n.ns}' is not a DNS-1123 label, which a namespace must be"
    else if n.kind != shape.kindSegment then
      some s!"'{full}' names kind '{n.kind}', but its shape is a '{shape.kindSegment}'"
    else
      let nameOk := match shape with
        | .service ..     => isDns1035Label n.name
        -- A StatefulSet's pods are named `<name>-<ordinal>` and carry that as
        -- their hostname, a label.
        | .statefulSet .. => isDns1123Label n.name
        | _               => isDns1123Subdomain n.name
      if nameOk then none
      else some s!"'{n.name}' is not a valid name for a {shape.kindSegment} (DNS-1123; a \
service's must also start with a letter)"

#guard objectNameProblem "main/default/statefulset.apps/postgres"
  (.statefulSet "postgres:17") = none
#guard objectNameProblem "main/default/service/postgres" (.service 5432) = none
#guard (objectNameProblem "main/default/deployment.apps/postgres" (.service 5432)).isSome
#guard (objectNameProblem "main/_/service/postgres" (.service 5432)).isSome
#guard objectNameProblem "main/_/clusterrole.rbac.authorization.k8s.io/reader"
  (.raw "rbac.authorization.k8s.io/v1" "ClusterRole" "{}") = none
#guard (objectNameProblem "main/default/service/1db" (.service 5432)).isSome

/-- What is wrong with a shape on its own, if anything: ports in range, env
    names present, a raw manifest that is a JSON object whose numbers survive
    encoding (`Infra.Core.JsonExact` — a manifest is re-encoded to be sent,
    and linen's encoder would change a number like `1e-7`). -/
def ObjectShape.problem : ObjectShape → Option String
  | .deployment image _ ports env | .statefulSet image _ ports env _ =>
    if image.isEmpty then some "the image is empty"
    else if ports.any (fun p => p == 0 || p > 65535) then some "a port is outside 1-65535"
    else if env.any (·.name.isEmpty) then some "an environment variable has no name"
    else if env.any (fun | .secret _ s => s.isEmpty | _ => false) then
      some "an environment variable names an empty secret"
    else none
  | .service port target _ =>
    if port == 0 || port > 65535 || target > 65535 then some "a port is outside 1-65535"
    else none
  | .raw av k m =>
    if av.isEmpty || k.isEmpty then some "a raw object needs its apiVersion and kind"
    else match Data.Json.Decode.decode m with
      | .ok v@(.object _) =>
        match Infra.Core.JsonExact.lossyNumbers v with
        | []     => none
        | n :: _ => some s!"a raw manifest holds the number {n}, which would be sent as \
{Data.Json.Encode.renderNumber n} — write it as a string, or as an integer in smaller units"
      | .ok _           => some "a raw manifest must be a JSON object"
      | .error e        => some s!"a raw manifest is not JSON: {e}"

#guard (ObjectShape.raw "v1" "ConfigMap" "{\"data\": {\"a\": \"1e-7\"}, \"n\": 3}").problem = none
#guard (ObjectShape.raw "v1" "ConfigMap" "{\"spec\": {\"ratio\": 0.5}}").problem = none
-- A number the encoder would change is refused before any run.
#guard (ObjectShape.raw "v1" "ConfigMap" "{\"spec\": {\"ratio\": 1e-7}}").problem.isSome

/-! ## Rendering the manifest -/

/-- The label every object infra creates carries, and the one its pods carry
    for a service to select: `app = <name>`. -/
def appLabel : String := "app"

/-- The annotation that records which environment variables came from which
    secret, so `read` can report `EnvVar.secret` and drop the value. -/
def secretEnvAnnotation : String := "infra.typednotes.org/secret-env"

/-- The annotation carrying a raw object's declared manifest, verbatim — what
    `read` reports for it, since a live object also holds everything the
    server defaulted and there is nothing else to compare against. -/
def manifestAnnotation : String := "infra.typednotes.org/manifest"

private def str (s : String) : Value := .string s
private def num (n : Nat) : Value := .number (Float.ofNat n)
private def obj (fs : List (String × Value)) : Value := .object fs
private def arr (vs : List Value) : Value := .array vs.toArray

/-- `secret-env` annotation text: `NAME=secret,NAME=secret`. -/
def encodeSecretEnv (env : List EnvVar) : String :=
  ",".intercalate (env.filterMap fun | .secret n s => some s!"{n}={s}" | .lit .. => none)

def decodeSecretEnv (s : String) : List (String × String) :=
  (s.splitOn ",").filterMap fun kv =>
    match kv.splitOn "=" with
    | [n, sec] => if n.isEmpty then none else some (n, sec)
    | _        => none

#guard decodeSecretEnv (encodeSecretEnv [.lit "A" "1", .secret "PW" "db-password"])
  = [("PW", "db-password")]

/-- The environment as the container receives it. `secretValue` supplies a
    `.secret` entry's value — the real one on the apply path, a redaction
    everywhere else (Terraform export). -/
private def envJson (secretValue : String → String) (env : List EnvVar) : Value :=
  arr (env.map fun
    | .lit n v    => obj [("name", str n), ("value", str v)]
    | .secret n s => obj [("name", str n), ("value", str (secretValue s))])

private def metadataOf (n : ObjectName) (labels : List (String × String))
    (annotations : List (String × String)) : Value :=
  obj ([("name", str n.name)]
    ++ (if n.clusterScoped then [] else [("namespace", str n.ns)])
    ++ [("labels", obj (labels.map fun (k, v) => (k, str v)))]
    ++ (if annotations.isEmpty then [] else
          [("annotations", obj (annotations.map fun (k, v) => (k, str v)))]))

private def containerOf (n : ObjectName) (image : String) (ports : List Nat)
    (env : List EnvVar) (secretValue : String → String)
    (mount : Option ClaimTemplate) : Value :=
  obj ([("name", str n.name), ("image", str image)]
    ++ (if ports.isEmpty then [] else
          [("ports", arr (ports.map fun p => obj [("containerPort", num p)]))])
    ++ (if env.isEmpty then [] else [("env", envJson secretValue env)])
    ++ (match mount with
        | some c => [("volumeMounts", arr [obj [("name", str "data"),
                                               ("mountPath", str c.mountPath)]])]
        | none   => []))

/-- The object a declaration asks for, as the JSON the Kubernetes API takes.

    `marker` is the ownership label, `(markerKey, fleet name)` — on the
    object's own `metadata.labels` and, for a StatefulSet, on its claim
    template (so its PVCs say whose they are), and **never** on a pod
    template: a ReplicaSet or a pod carrying the marker would be found by the
    scan as an undeclared resource of this fleet's and deleted from under its
    controller. `Err` for a raw manifest that is not a JSON object, which
    `ObjectShape.problem` refuses at plan time. -/
def renderManifest (n : ObjectName) (shape : ObjectShape) (marker : String × String)
    (secretValue : String → String) : Except String Value := do
  let (apiVersion, kind) := shape.apiVersionKind
  let head := [("apiVersion", str apiVersion), ("kind", str kind)]
  let selector := obj [(appLabel, str n.name)]
  match shape with
  | .deployment image replicas ports env =>
    let annotations := if encodeSecretEnv env |>.isEmpty then []
      else [(secretEnvAnnotation, encodeSecretEnv env)]
    return obj (head ++
      [ ("metadata", metadataOf n [marker] annotations)
      , ("spec", obj
          [ ("replicas", num replicas)
          , ("selector", obj [("matchLabels", selector)])
          , ("template", obj
              [ ("metadata", obj [("labels", selector)])
              , ("spec", obj [("containers",
                  arr [containerOf n image ports env secretValue none])]) ]) ]) ])
  | .statefulSet image replicas ports env storage =>
    let annotations := if encodeSecretEnv env |>.isEmpty then []
      else [(secretEnvAnnotation, encodeSecretEnv env)]
    let claims := match storage with
      | some c =>
        [("volumeClaimTemplates", arr [obj
          [ ("metadata", obj [("name", str "data"),
                              ("labels", obj [(marker.1, str marker.2)])])
          , ("spec", obj
              [ ("accessModes", arr [str "ReadWriteOnce"])
              , ("storageClassName", str c.storageClass)
              , ("resources", obj [("requests",
                  obj [("storage", str s!"{c.sizeGb}Gi")])]) ]) ]])]
      | none => []
    return obj (head ++
      [ ("metadata", metadataOf n [marker] annotations)
      , ("spec", obj (
          [ ("replicas", num replicas)
          , ("serviceName", str n.name)
          , ("selector", obj [("matchLabels", selector)])
          , ("template", obj
              [ ("metadata", obj [("labels", selector)])
              , ("spec", obj [("containers",
                  arr [containerOf n image ports env secretValue storage])]) ]) ]
          ++ claims)) ])
  | .service port targetPort sel =>
    let sel' := if sel.isEmpty then [(appLabel, n.name)] else sel
    let target := if targetPort == 0 then port else targetPort
    return obj (head ++
      [ ("metadata", metadataOf n [marker] [])
      , ("spec", obj
          [ ("selector", obj (sel'.map fun (k, v) => (k, str v)))
          , ("ports", arr [obj [("port", num port), ("targetPort", num target)]]) ]) ])
  | .raw _ _ manifest =>
    match Data.Json.Decode.decode manifest with
    | .ok (.object fields) =>
      -- The declared fields, minus anything infra sets itself.
      let body := fields.filter fun (k, _) =>
        k != "apiVersion" && k != "kind" && k != "metadata"
      -- The declaration's own labels and annotations are kept; the marker and
      -- the manifest annotation are added.
      let declaredMeta := (fields.lookup "metadata").bind (·.asObject) |>.getD []
      let labels := ((declaredMeta.lookup "labels").bind (·.asObject) |>.getD []).filterMap
        fun (k, v) => v.asString.map (k, ·)
      let annotations := ((declaredMeta.lookup "annotations").bind (·.asObject) |>.getD []).filterMap
        fun (k, v) => v.asString.map (k, ·)
      return obj (head ++
        [("metadata", metadataOf n (marker :: labels.filter (·.1 != marker.1))
            (annotations.filter (·.1 != manifestAnnotation) ++ [(manifestAnnotation, manifest)]))]
        ++ body)
    | .ok _    => throw "a raw manifest must be a JSON object"
    | .error e => throw s!"a raw manifest is not JSON: {e}"

/-! ## Reading an object back -/

private def lookupPath (v : Value) : List String → Option Value
  | []      => some v
  | k :: ks => (v.lookup k).bind (lookupPath · ks)

private def natOf? : Value → Option Nat
  | .number n => some n.toUInt64.toNat
  | .string s => s.toNat?
  | _         => none

/-- A Kubernetes quantity in whole GiB, for the units infra writes (`Gi`) and
    the ones a server or a person might (`Ti`, `G`, `T`, `Mi` rounded up). -/
def gibOfQuantity (q : String) : Option Nat :=
  let num (suffix : String) : Option Nat :=
    if q.endsWith suffix then (q.dropEnd suffix.length).toString.toNat? else none
  match num "Gi" with
  | some n => some n
  | none => match num "Ti" with
    | some n => some (n * 1024)
    | none => match num "Mi" with
      | some n => some ((n + 1023) / 1024)
      | none => match num "G" with
        | some n => some n
        | none => match num "T" with
          | some n => some (n * 1000)
          | none => none

#guard gibOfQuantity "20Gi" = some 20
#guard gibOfQuantity "1Ti" = some 1024
#guard gibOfQuantity "512Mi" = some 1
#guard gibOfQuantity "20" = none

/-- The label value `key` on a live object, if any. -/
def labelOf (live : Value) (key : String) : Option String :=
  (lookupPath live ["metadata", "labels", key]).bind (·.asString)

/-- A live object's labels, for ownership evidence. -/
def labelsOf (live : Value) : List (String × String) :=
  ((lookupPath live ["metadata", "labels"]).bind (·.asObject) |>.getD []).filterMap
    fun (k, v) => v.asString.map (k, ·)

/-- A live object's annotation `key`, if any. -/
def annotationOf (live : Value) (key : String) : Option String :=
  (lookupPath live ["metadata", "annotations", key]).bind (·.asString)

private def firstContainer (live : Value) : Option Value :=
  (lookupPath live ["spec", "template", "spec", "containers"]).bind fun v =>
    v.asArray.bind (·[0]?)

private def envOfLive (live : Value) (container : Value) : List EnvVar :=
  let fromSecret := (annotationOf live secretEnvAnnotation).map decodeSecretEnv |>.getD []
  ((container.lookup "env").bind (·.asArray) |>.getD #[]).toList.filterMap fun e =>
    match (e.lookup "name").bind (·.asString) with
    | none => none
    | some n =>
      match fromSecret.lookup n with
      -- The value is dropped here, before anything leaves this function.
      | some sec => some (.secret n sec)
      | none     => some (.lit n ((e.lookup "value").bind (·.asString) |>.getD ""))

private def portsOfLive (container : Value) : List Nat :=
  ((container.lookup "ports").bind (·.asArray) |>.getD #[]).toList.filterMap fun p =>
    (p.lookup "containerPort").bind natOf?

/-- The shape a live object realises, as the declaration would say it.

    Chosen by what the object *is*: one carrying the manifest annotation was
    created from a `raw` shape and is reported as one, whatever its kind — so
    a raw Deployment is compared as raw, never as a typed one. A secret
    environment variable is reported by its secret's name; its value is read
    over the wire (the API returns whole objects) and dropped here. `none` for
    an object of a kind with no typed shape and no annotation: not something
    infra created, so nothing to report. -/
def shapeOfLive (n : ObjectName) (live : Value) : Option ObjectShape :=
  match annotationOf live manifestAnnotation with
  | some m =>
    let av := (live.lookup "apiVersion").bind (·.asString) |>.getD ""
    let k := (live.lookup "kind").bind (·.asString) |>.getD ""
    some (.raw av k m)
  | none =>
    match (live.lookup "kind").bind (·.asString) with
    | some "Deployment" =>
      let c := (firstContainer live).getD (.object [])
      some (.deployment ((c.lookup "image").bind (·.asString) |>.getD "")
        ((lookupPath live ["spec", "replicas"]).bind natOf? |>.getD 1)
        (portsOfLive c) (envOfLive live c))
    | some "StatefulSet" =>
      let c := (firstContainer live).getD (.object [])
      let claim := (lookupPath live ["spec", "volumeClaimTemplates"]).bind fun v =>
        v.asArray.bind (·[0]?)
      let storage := claim.map fun t =>
        let mount := ((c.lookup "volumeMounts").bind (·.asArray) |>.getD #[]).toList.find?
          fun m => (m.lookup "name").bind (·.asString) == some "data"
        { sizeGb := (lookupPath t ["spec", "resources", "requests", "storage"]).bind
              (·.asString) |>.bind gibOfQuantity |>.getD 0
          storageClass := (lookupPath t ["spec", "storageClassName"]).bind (·.asString) |>.getD ""
          mountPath := (mount.bind (·.lookup "mountPath")).bind (·.asString) |>.getD "" }
      some (.statefulSet ((c.lookup "image").bind (·.asString) |>.getD "")
        ((lookupPath live ["spec", "replicas"]).bind natOf? |>.getD 1)
        (portsOfLive c) (envOfLive live c) storage)
    | some "Service" =>
      let p := (lookupPath live ["spec", "ports"]).bind fun v => v.asArray.bind (·[0]?)
      let port := (p.bind (·.lookup "port")).bind natOf? |>.getD 0
      let target := (p.bind (·.lookup "targetPort")).bind natOf? |>.getD port
      let sel := ((lookupPath live ["spec", "selector"]).bind (·.asObject) |>.getD []).filterMap
        fun (k, v) => v.asString.map (k, ·)
      -- Reported in the declaration's normal form: the defaults it would
      -- have written as `0` and `[]` are reported as such, so an object
      -- created from a declaration that left them out does not diverge.
      some (.service port (if target == port then 0 else target)
        (if sel == [(appLabel, n.name)] then [] else sel))
    | _ => none

/- The round trip the diff rests on: a rendered object reads back as the
   shape it was rendered from — with a secret's value dropped on the way. -/
private def rtName : ObjectName :=
  { cluster := "main", ns := "default", kind := "statefulset.apps", name := "pg" }
private def rtShape : ObjectShape :=
  .statefulSet "postgres:17" 1 [5432] [.lit "POSTGRES_USER" "dbadmin", .secret "PW" "db-pw"]
    (some { sizeGb := 20, storageClass := "scw-bssd", mountPath := "/var/lib/postgresql" })
#guard (do
    let v ← (renderManifest rtName rtShape ("managed-by-infra", "f") fun _ => "hunter2").toOption
    shapeOfLive rtName v) == some rtShape
private def svcName : ObjectName := { rtName with kind := "service" }
#guard (do
    let v ← (renderManifest svcName (.service 5432) ("managed-by-infra", "f") fun _ => "").toOption
    shapeOfLive svcName v) == some (.service 5432)
#guard (do
    let v ← (renderManifest svcName (.service 80 8080) ("managed-by-infra", "f") fun _ => "").toOption
    shapeOfLive svcName v) == some (.service 80 8080)
-- A pod template never carries the marker, and the object itself always does.
#guard (do
    let v ← (renderManifest rtName rtShape ("managed-by-infra", "f") fun _ => "").toOption
    pure (labelOf v "managed-by-infra" == some "f"
      && (lookupPath v ["spec", "template", "metadata", "labels", "managed-by-infra"]).isNone))
    == some true
private def cmName : ObjectName := { rtName with kind := "configmap", name := "cfg" }
private def cmShape : ObjectShape := .raw "v1" "ConfigMap" "{\"data\":{\"a\":\"1\"}}"
#guard (do
    let v ← (renderManifest cmName cmShape ("managed-by-infra", "f") fun _ => "").toOption
    shapeOfLive cmName v) == some cmShape

end Infra.Specs
