import Linen.Data.Json.Types

/-
  The image identity used by reconciliation. Tags select content; a SHA-256
  manifest digest identifies it. Live backends resolve selectors before the
  engine compares targets, and write the resolved reference to the cloud.
  The cloud's image field is the durable record — no local image ledger.
-/
namespace Infra.Core.Image

/-- An OCI SHA-256 manifest digest, not a tag or a truncated hash. -/
def isDigest (s : String) : Bool :=
  s.startsWith "sha256:" && s.length == 71 &&
    ((s.drop 7).toString.toList.all fun c => c.isDigit || (c >= 'a' && c <= 'f'))

/-- A digest explicitly carried by an image reference. -/
def digest? (s : String) : Option String :=
  match s.splitOn "@" with
  | [_, d] => if isDigest d then some d else none
  | _ => none

/-- Once resolved, tags and repository spelling do not change image content.
    Unresolved references retain the offline comparison's old behaviour. -/
def sameContent (a b : String) : Bool :=
  match digest? a, digest? b with
  | some x, some y => x == y
  | _, _ => a == b

/-- Parsed Docker/OCI reference. Docker Hub's unqualified-name conventions
    are applied here; the wire host and the canonical reference can differ. -/
structure Reference where
  registry : String
  repository : String
  selector : String
  deriving BEq, Repr

def Reference.host (r : Reference) : String :=
  if r.registry == "docker.io" then "registry-1.docker.io" else r.registry

def Reference.pinned (r : Reference) (digest : String) : String :=
  s!"{r.registry}/{r.repository}@{digest}"

/-- Parse without guessing away a scheme, userinfo, path traversal or malformed
    digest. Registries are HTTPS; an explicit port is preserved. -/
def parse? (s : String) : Option Reference := do
  if s.isEmpty || s.toList.any (fun c => c.isWhitespace || "?#\\".contains c) then none
  let (base, pinned) ← match s.splitOn "@" with
    | [b] => some (b, none)
    | [b, d] => if isDigest d then some (b, some d) else none
    | _ => none
  let parts := base.splitOn "/"
  let first := parts.headD ""
  let explicit := parts.length > 1 &&
    (first.contains '.' || first.contains ':' || first == "localhost")
  let registry := if explicit then first else "docker.io"
  let registry := if registry == "index.docker.io" || registry == "registry-1.docker.io"
                  then "docker.io" else registry
  let path := if explicit then parts.drop 1 else parts
  let last := path.getLastD ""
  let (name, tag) ← match last.splitOn ":" with
    | [n] => some (n, "latest")
    | [n, t] => some (n, t)
    | _ => none
  let names := path.dropLast ++ [name]
  if !(names.all fun n => !n.isEmpty && n != "." && n != ".." &&
      n.toList.all (fun c => (c.isLower && c.isAlpha) || c.isDigit || "._-".contains c))
      || tag.isEmpty || tag.length > 128 ||
      !tag.toList.all (fun c => c.isAlphanum || "_.-".contains c) then none
  if registry.isEmpty || !registry.toList.all
      (fun c => c.isAlphanum || ".:-".contains c) then none
  let repository := String.intercalate "/" names
  let repository := if registry == "docker.io" && names.length == 1
                    then "library/" ++ repository else repository
  return { registry, repository, selector := pinned.getD tag }

-- Kubernetes' built-in pod-bearing shapes, including raw manifests. A CRD's
-- arbitrary fields are opaque: a field named "image" need not be a container.
def podPath (kind : String) : Option (List String) :=
  match kind.toLower with
  | "pod" => some ["spec"]
  | "deployment" | "daemonset" | "statefulset" | "replicaset" | "replicationcontroller"
  | "job" => some ["spec", "template", "spec"]
  | "cronjob" => some ["spec", "jobTemplate", "spec", "template", "spec"]
  | _ => none

def atPath (v : Data.Json.Value) : List String → Option Data.Json.Value
  | [] => some v
  | key :: rest => (v.lookup key).bind (fun child => atPath child rest)

def mapAtPath (v : Data.Json.Value) (f : Data.Json.Value → Data.Json.Value) :
    List String → Data.Json.Value
  | [] => f v
  | key :: rest => match v with
    | .object fields => .object (fields.map fun (k, child) =>
        (k, if k == key then mapAtPath child f rest else child))
    | _ => v

def containerFields : List String := ["containers", "initContainers", "ephemeralContainers"]

/-- Container references in a pod specification, including init containers. -/
def podImages (v : Data.Json.Value) : List String :=
  containerFields.flatMap fun key =>
    ((v.lookup key).bind (·.asArray) |>.getD #[]).toList.filterMap fun c =>
      (c.lookup "image").bind (·.asString)

def mapPodImages (f : String → String) (v : Data.Json.Value) : Data.Json.Value :=
  match v with
  | .object fields => .object (fields.map fun (key, value) =>
      (key, if containerFields.contains key then
        match value with
        | .array cs => .array (cs.map fun c => match c with
            | .object fs => .object (fs.map fun (k, x) =>
                (k, if k == "image" then match x with
                    | .string image => .string (f image)
                    | _ => x
                  else x))
            | _ => c)
        | _ => value
        else value))
  | _ => v

private def d0 : String := "sha256:" ++ String.ofList (List.replicate 64 '0')
private def d1 : String := "sha256:" ++ String.ofList (List.replicate 64 '1')
#guard isDigest d0
#guard !isDigest "sha256:1234"
#guard (parse? "postgres:17").map (fun r => (r.host, r.repository, r.selector)) ==
  some ("registry-1.docker.io", "library/postgres", "17")
#guard (parse? "ghcr.io/org/app:latest").map (·.selector) == some "latest"
#guard (parse? s!"ghcr.io/org/app:latest@{d0}").map (·.selector) == some d0
#guard ["http://registry/app", "registry/app@sha256:short", "a//b", "registry.io/../app",
        "registry.io/a:tag?query", "registry.io/a:bad tag"].all (parse? · |>.isNone)
#guard sameContent s!"a:latest@{d0}" s!"b:v1@{d0}"
#guard !sameContent s!"a:latest@{d0}" s!"a:latest@{d1}"
#guard !sameContent "a:latest" s!"a:latest@{d0}"

end Infra.Core.Image
