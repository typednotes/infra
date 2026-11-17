import Infra.Interop.Yaml
import Infra.Interop.KubernetesYaml
import Infra.Interop.KubernetesImport

/-
  A fleet's in-cluster objects as a Helm chart — what `infra render --chart`
  writes, for installing the same objects where Helm, not infra, is the
  deploy path (a self-hosted install, someone else's cluster).

  The fleet stays the source of truth: a chart is an export, regenerated, not
  edited and read back. `docs/kubernetes.md`, "Interop", says why infra does
  not *deploy* through Helm, and why exporting to it does not contradict that.

  ## What becomes a value

  A fleet's own parameters are Lean functions, which a `values.yaml` cannot
  carry, so the values are the typed fields a chart user changes per
  install, read off the declaration mechanically:

  * each Deployment and StatefulSet: its `image` and `replicas`, under
    `objects."<namespace>/<kind>/<name>"`;
  * each secret a workload reads (`.secret`): the Kubernetes Secret and key
    it comes from, under `secrets."<secret>"` — `name` defaults to the
    secret's fleet name, `key` to `value`. The Secret must exist in the
    workload's namespace; the chart never holds a value.

  Everything else is literal: Services, every field of a `raw` object
  (including images inside it), ports, literal environment values,
  namespaces. `values.schema.json` types every value (a non-empty string, a
  non-negative integer, a DNS-1123 Secret name, a Secret key), so `helm
  install` refuses a value of the wrong shape, as the fleet would.

  ## How the chart differs from `infra render`

  * No fleet marker label and no `infra.typednotes.org/*` annotations: Helm
    owns these objects, and an object carrying a fleet's marker in a cluster
    that fleet manages would be claimed — and deleted — as its orphan.
  * A secret-sourced variable is `valueFrom.secretKeyRef`, where `render`
    shows a placeholder value.

  `defaults` renders exactly what `helm template` produces from the chart
  with its default values (the CI check `ci/check-helm-chart.sh` compares the
  two through the real `helm`). Go's template engine is Helm's, not
  infra's: that comparison is the evidence the templates mean what
  `defaults` says, and the stated trusted boundary.

  ## Templating

  Each object is rendered by `Specs.renderManifest` — the function `apply`
  uses — with every value position holding a sentinel string, encoded as
  YAML, and the sentinels then replaced by Go template actions. Any `{{` the
  object itself holds (a ConfigMap of templates) is escaped first, as
  `{{"{{"}}`, so Helm prints it back literally.
-/

namespace Infra.Interop.HelmChart

open Data.Json (Value)
open Infra.Core
open Infra.Specs
open Infra.Interop.KubernetesYaml (Scope declaredObjects secretPlaceholder)

/-! ## Values -/

/-- A position in the chart that `values.yaml` sets. -/
inductive Param where
  | image      (obj : String)
  | replicas   (obj : String)
  | secretName (secret : String)
  | secretKey  (secret : String)
  deriving Repr, DecidableEq, BEq

/-- A Go string literal. -/
def goString (s : String) : String :=
  "\"" ++ (s.replace "\\" "\\\\" |>.replace "\"" "\\\"") ++ "\""

/-- The template action that reads a parameter's value. -/
def Param.action : Param → String
  | .image o      => s!"\{\{ index .Values.objects {goString o} \"image\" | quote }}"
  | .replicas o   => s!"\{\{ index .Values.objects {goString o} \"replicas\" | int }}"
  | .secretName s => s!"\{\{ index .Values.secrets {goString s} \"name\" | quote }}"
  | .secretKey s  => s!"\{\{ index .Values.secrets {goString s} \"key\" | quote }}"

/-- An object's key under `objects`: its address within the cluster. -/
def objectKey (n : ObjectName) : String := s!"{n.ns}/{n.kind}/{n.name}"

/-- The key a secret-sourced variable reads from by default. -/
def defaultSecretKey : String := "value"

/-- Every parameter an object has, with its default value. -/
def paramsOf (n : ObjectName) : ObjectShape → List (Param × Value)
  | .deployment image replicas _ env | .statefulSet image replicas _ env _ =>
    [(.image (objectKey n), .string image), (.replicas (objectKey n), .number (Float.ofNat replicas))]
      ++ env.flatMap fun
        | .secret _ s => [(.secretName s, .string s), (.secretKey s, .string defaultSecretKey)]
        | .lit .. => []
  | .service .. | .raw .. => []

/-! ## One object -/

private def fieldsOf (v : Value) : List (String × Value) := v.asObject.getD []

private def updateField (fs : List (String × Value)) (k : String) (f : Value → Value) :
    List (String × Value) :=
  fs.map fun (k', v) => if k' == k then (k', f v) else (k', v)

private def under (v : Value) (k : String) (f : Value → Value) : Value :=
  .object (updateField (fieldsOf v) k f)

/-- Metadata without infra's annotations, an empty `annotations` removed.
    (`KubernetesImport.normalize` has already taken the marker label.) -/
private def withoutInfraAnnotations (m : Value) : Value :=
  let fs := fieldsOf m
  match fs.lookup "annotations" with
  | some (.object as) =>
    let as' := as.filter fun (k, _) => k != secretEnvAnnotation && k != manifestAnnotation
    .object (if as'.isEmpty then fs.filter (·.1 != "annotations")
             else updateField fs "annotations" fun _ => .object as')
  | _ => m

/-- The object as the chart installs it, every parameter position holding
    `sub` of its parameter: the defaults for `defaults`, sentinels for the
    templates. -/
def chartManifest (n : ObjectName) (shape : ObjectShape) (sub : Param → Value) :
    Except String Value := do
  let rendered ← renderManifest n shape (markerKey, "chart") secretPlaceholder
  let m := under (Infra.Interop.KubernetesImport.normalize rendered) "metadata"
    withoutInfraAnnotations
  match shape with
  | .deployment _ _ _ env | .statefulSet _ _ _ env _ =>
    let key := objectKey n
    let secretOf (v : String) : Option String :=
      env.findSome? fun | .secret v' s => if v' == v then some s else none | .lit .. => none
    let envEntry (e : Value) : Value :=
      match (e.lookup "name").bind (·.asString) with
      | some v =>
        match secretOf v with
        | some s => .object [("name", .string v), ("valueFrom", .object [("secretKeyRef",
            .object [("name", sub (.secretName s)), ("key", sub (.secretKey s))])])]
        | none => e
      | none => e
    let container (c : Value) : Value :=
      let c := under c "image" fun _ => sub (.image key)
      under c "env" fun | .array es => .array (es.map envEntry) | v => v
    return under m "spec" fun spec =>
      let spec := under spec "replicas" fun _ => sub (.replicas key)
      under spec "template" fun t => under t "spec" fun ps => under ps "containers" fun
        | .array cs => .array (cs.map container)
        | v => v
  | .service .. | .raw .. => return m

/-! ## The chart -/

/-- A chart name Helm accepts: lowercase letters, digits and `-`. -/
def isChartName (s : String) : Bool := isDns1123Label s

/-- `MAJOR.MINOR.PATCH`, optionally `-prerelease`: the SemVer 2 versions Helm
    requires, build metadata aside. -/
def isSemver (s : String) : Bool :=
  let (core, pre) := match s.splitOn "-" with
    | c :: rest => (c, if rest.isEmpty then none else some (String.intercalate "-" rest))
    | [] => ("", none)
  let numeric (p : String) := !p.isEmpty && p.all Char.isDigit && (p == "0" || !p.startsWith "0")
  match core.splitOn "." with
  | [a, b, c] => numeric a && numeric b && numeric c
      && (pre.map fun p => !p.isEmpty && p.all fun c => c.isAlphanum || c == '.' || c == '-').getD true
  | _ => false

#guard isSemver "0.1.0" && isSemver "1.20.3-rc.1" && !isSemver "1.2" && !isSemver "01.0.0"
  && !isSemver "1.0.0-"

/-- The prefix every sentinel carries; refused in an object's own text. -/
def sentinelPrefix : String := "__infra_helm_value_"

private def sentinel (i : Nat) : String := s!"{sentinelPrefix}{i}__"

/-- The objects a chart is made of: one cluster on one cloud, or why not. -/
def chartObjects {κ : Keys} (T : Plan κ) (scope : Scope) :
    Except String (ProviderId × String × List (String × ObjectName × ObjectShape)) := do
  let objs ← declaredObjects T scope
  let clusters := (objs.map fun (p, _, n, _) => (p, n.cluster)).eraseDups
  match clusters with
  | [] => throw "no Kubernetes objects are declared in that scope"
  | [(p, c)] =>
    return (p, c, objs.map fun (p, name, n, shape) => (slotId p .kubernetesObject name, n, shape))
  | _ => throw s!"a chart installs into one cluster, and these objects are in \
{String.intercalate ", " (clusters.map fun (p, c) => s!"{p.name}/{c}")}: name one as \
<cloud>/<cluster>"

/-- Every parameter of the chart, once each, in declaration order. -/
def chartParams (objs : List (String × ObjectName × ObjectShape)) : List (Param × Value) :=
  objs.foldl (init := []) fun acc (_, n, shape) =>
    (paramsOf n shape).foldl (init := acc) fun acc (p, v) =>
      if acc.any (·.1 == p) then acc else acc ++ [(p, v)]

/-- What `helm template` renders from the chart with its default values, as
    YAML documents headed by their plan-line ids. -/
def defaults (objs : List (String × ObjectName × ObjectShape)) : Except String String := do
  let params := chartParams objs
  let docs ← objs.mapM fun (slot, n, shape) => do
    let m ← chartManifest n shape fun p => (params.lookup p).getD .null
    let yaml ← Infra.Interop.Yaml.encode m
    return s!"---\n# Source: {slot}\n{yaml}"
  return String.intercalate "\n" docs ++ "\n"

/-- The file name of an object's template. `_` never occurs in an address
    segment, so names cannot collide. -/
def templateFile (n : ObjectName) : String :=
  s!"templates/{if n.clusterScoped then "cluster" else n.ns}_{n.kind}_{n.name}.yaml"

/-- One object's template text. -/
def template (params : List (Param × Value)) (slot : String) (n : ObjectName)
    (shape : ObjectShape) : Except String String := do
  let plain ← Infra.Interop.Yaml.encode
    (← chartManifest n shape fun p => (params.lookup p).getD .null)
  if (plain.splitOn sentinelPrefix).length > 1 then
    throw s!"{slot}: holds the text '{sentinelPrefix}', which the chart export reserves"
  let indexOf (p : Param) : Nat := (params.findIdx? (·.1 == p)).getD 0
  let marked ← Infra.Interop.Yaml.encode
    (← chartManifest n shape fun p => .string (sentinel (indexOf p)))
  -- `{{` in the object's own text is printed back literally by Helm.
  let escaped := marked.replace "{{" "{{\"{{\"}}"
  let filled := params.foldl (init := escaped) fun text (p, _) =>
    text.replace (sentinel (indexOf p)) p.action
  return s!"# Source: {slot}\n{filled}\n"

/-- The JSON schema of the chart's values. -/
def valuesSchema (params : List (Param × Value)) : Value :=
  let objs := (params.filterMap fun | (.image o, _) => some o | _ => none)
  let secrets := (params.filterMap fun | (.secretName s, _) => some s | _ => none)
  let closed (props : List (String × Value)) : Value :=
    .object ([("type", .string "object"), ("additionalProperties", .bool false)]
      ++ (if props.isEmpty then [] else
            [("required", .array (props.map (.string ·.1)).toArray)])
      ++ [("properties", .object props)])
  let objectSchema := closed
    [ ("image", .object [("type", .string "string"), ("minLength", .number 1)])
    , ("replicas", .object [("type", .string "integer"), ("minimum", .number 0)]) ]
  let secretSchema := closed
    [ ("name", .object [("type", .string "string"), ("maxLength", .number 253),
        ("pattern", .string "^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$")])
    , ("key", .object [("type", .string "string"),
        ("pattern", .string "^[-._a-zA-Z0-9]+$")]) ]
  .object
    [ ("$schema", .string "https://json-schema.org/draft-07/schema#")
    , ("type", .string "object")
    , ("required", .array #[.string "objects", .string "secrets"])
    , ("properties", .object
        [ ("objects", closed (objs.map (·, objectSchema)))
        , ("secrets", closed (secrets.map (·, secretSchema))) ]) ]

/-- The chart's default `values.yaml`, with its header. -/
def valuesYaml (chartName fleet : String) (params : List (Param × Value)) :
    Except String String := do
  let objs := (params.filterMap fun | (.image o, _) => some o | _ => none)
  let secrets := (params.filterMap fun | (.secretName s, _) => some s | _ => none)
  let get (p : Param) := (params.lookup p).getD .null
  let v : Value := .object
    [ ("objects", .object (objs.map fun o =>
        (o, .object [("image", get (.image o)), ("replicas", get (.replicas o))])))
    , ("secrets", .object (secrets.map fun s =>
        (s, .object [("name", get (.secretName s)), ("key", get (.secretKey s))]))) ]
  let body ← Infra.Interop.Yaml.encode v
  return s!"# Values of the {chartName} chart, generated by `infra render --chart` from the \
fleet {fleet}.\n\
# objects: each Deployment's and StatefulSet's image and replicas, by \
<namespace>/<kind>/<name>.\n\
# secrets: the Kubernetes Secret (in the workload's namespace) and key each secret-sourced\n\
#   variable reads. The chart never holds a secret's value.\n\
# values.schema.json types every value; helm refuses an install that does not fit.\n{body}\n"

/-- The chart's files, as `(path, contents)`, or why it cannot be made. -/
def chart {κ : Keys} (T : Plan κ) (fleet : String) (scope : Scope) (chartName version : String) :
    Except String (List (String × String)) := do
  unless isChartName chartName do
    throw s!"'{chartName}' is not a chart name Helm accepts (lowercase letters, digits and '-', \
at most 63)"
  unless isSemver version do
    throw s!"'{version}' is not a SemVer 2 version (MAJOR.MINOR.PATCH[-PRERELEASE]), which Helm \
requires"
  let (p, cluster, objs) ← chartObjects T scope
  let params := chartParams objs
  for (prm, _) in params do
    if let .secretName s := prm then
      unless isDns1123Subdomain s do
        throw s!"the secret '{s}' is not a Kubernetes Secret name (DNS-1123), so it cannot be \
the default of values.secrets.{s}.name"
  let templates ← objs.mapM fun (slot, n, shape) => do
    return (templateFile n, ← template params slot n shape)
  let chartYaml ← Infra.Interop.Yaml.encode (.object
    [ ("apiVersion", .string "v2"), ("name", .string chartName)
    , ("description", .string s!"The Kubernetes objects of the {fleet} fleet in {p.name}/{cluster}, \
generated by infra render --chart.")
    , ("type", .string "application"), ("version", .string version) ])
  return [ ("Chart.yaml", chartYaml ++ "\n")
         , ("values.yaml", ← valuesYaml chartName fleet params)
         , ("values.schema.json", Data.Json.Encode.encodePretty (valuesSchema params) ++ "\n") ]
    ++ templates

/-! ## Checks -/

private def mentions (s t : String) : Bool := (s.splitOn t).length > 1

private def web : ObjectName :=
  { cluster := "main", ns := "default", kind := "deployment.apps", name := "web" }
private def webShape : ObjectShape :=
  .deployment "nginx:1.27" 2 [80] [.lit "MODE" "on", .secret "PW" "db-pw"]
private def webParams := paramsOf web webShape

/- The template reads each value through `index`, quotes strings, makes
   replicas an integer, and turns the secret into a `secretKeyRef`; the
   fleet's marker and infra's annotations are gone. -/
#guard match template webParams "s" web webShape with
  | .ok t =>
    mentions t "image: {{ index .Values.objects \"default/deployment.apps/web\" \"image\" | quote }}"
      && mentions t "replicas: {{ index .Values.objects \"default/deployment.apps/web\" \"replicas\" | int }}"
      && mentions t "name: {{ index .Values.secrets \"db-pw\" \"name\" | quote }}"
      && mentions t "key: {{ index .Values.secrets \"db-pw\" \"key\" | quote }}"
      && !mentions t "managed-by-infra" && !mentions t "infra.typednotes.org"
      && !mentions t sentinelPrefix && !mentions t "<secret"
  | .error _ => false

/- The default rendering is the template with each action replaced by its
   default: the same object `render` sends, marker and annotations aside. -/
#guard match chartManifest web (.deployment "nginx:1.27" 2 [80] [])
          fun p => ((paramsOf web (.deployment "nginx:1.27" 2 [80] [])).lookup p).getD .null,
        renderManifest web (.deployment "nginx:1.27" 2 [80] []) ("managed-by-infra", "f") secretPlaceholder with
  | .ok c, .ok r => Infra.Interop.KubernetesImport.sameJson c (Infra.Interop.KubernetesImport.normalize r)
  | _, _ => false

/- An object's own `{{` is escaped, so Helm prints it back. -/
private def cm : ObjectName := { web with kind := "configmap", name := "tpl" }
#guard match template [] "s" cm (.raw "v1" "ConfigMap" "{\"data\":{\"t\":\"{{ x }}\"}}") with
  | .ok t => mentions t "t: \"{{\"{{\"}} x }}\""
  | .error _ => false
-- And the reserved sentinel text is refused rather than replaced.
#guard (template [] "s" cm (.raw "v1" "ConfigMap" "{\"data\":{\"t\":\"__infra_helm_value_0__\"}}")
  matches .error _)

/- The schema closes each map and types each value. -/
#guard mentions (Data.Json.Encode.encode (valuesSchema webParams)) "\"replicas\":{\"type\":\"integer\""

end Infra.Interop.HelmChart
