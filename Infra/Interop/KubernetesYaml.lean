import Infra.Core.Fleet
import Infra.Core.Ownership
import Infra.Specs.Kubernetes
import Infra.Interop.Yaml

/-
  The in-cluster objects a fleet declares, rendered as Kubernetes YAML — what
  `helm template` is to a chart. `infra render` prints it.

  **Exactly what `apply` sends.** Each document is `Specs.renderManifest` of
  the declared shape — the one function the live backend calls
  (`Kinds.Kubernetes`), not a second rendering that could drift — with this
  fleet's ownership label (`managed-by-infra: <fleet name>`) on every object,
  as applied. Offline: no cloud, no cluster and no credentials are asked.

  Two things differ from what reaches a cluster, and both are said in the
  output:

  * **A secret-sourced environment variable is a placeholder**,
    `<secret NAME>`. Its value is fetched from the cloud on the apply path and
    never leaves it — the rule the Terraform export follows too. A document
    holding one says so in a comment above it.
  * **Nothing the cluster adds** — defaults, status, a server-set `uid`. This
    is the declaration, not a read.

  A declaration `kubernetesIsSound` refuses renders nothing: the problem is
  the error, as `plan` would give it.

  Documents come in declaration order, `---` before each, and each is headed
  `# Source: <slot>` — the fleet key's plan-line id, which names the cloud and
  the cluster. `only` narrows the output to one cloud, or one cluster on one
  cloud, which is what `kubectl apply -f -` needs: it talks to one cluster.
-/

namespace Infra.Interop.KubernetesYaml

open Infra.Core
open Infra.Specs

/-- Which objects to render: every one, those on one cloud, or those in one
    cluster on one cloud. -/
inductive Scope where
  | all
  | cloud (p : ProviderId)
  | cluster (p : ProviderId) (name : String)
  deriving Repr, DecidableEq

def Scope.admits : Scope → ProviderId → String → Bool
  | .all,         _, _ => true
  | .cloud q,     p, _ => p == q
  | .cluster q c, p, n => p == q && n == c

/-- `render`'s argument: `<cloud>` or `<cloud>/<cluster>`. -/
def Scope.parse? (s : String) : Option Scope :=
  let cloudOf (c : String) := (Finite.elems (α := ProviderId)).find? (·.name == c)
  match s.splitOn "/" with
  | [c]    => (cloudOf c).map .cloud
  | [c, n] => if n.isEmpty then none else (cloudOf c).map (.cluster · n)
  | _      => none

#guard Scope.parse? "scaleway" = some (.cloud .scaleway)
#guard Scope.parse? "aws/main" = some (.cluster .aws "main")
#guard Scope.parse? "azure" = none
#guard Scope.parse? "aws/" = none

/-- The placeholder a secret-sourced value is rendered as. -/
def secretPlaceholder (secret : String) : String := s!"<secret {secret}>"

/-- One object's document: its header comments and its YAML. -/
def document (p : ProviderId) (name : String) (n : ObjectName) (shape : ObjectShape)
    (fleet : String) : Except String String := do
  let manifest ← renderManifest n shape (markerKey, fleet) secretPlaceholder
  let body ← (Infra.Interop.Yaml.encode manifest).mapError
    (s!"{slotId p .kubernetesObject name}: " ++ ·)
  let secrets := shape.secretNames.eraseDups
  let note := if secrets.isEmpty then [] else
    [s!"# Secret-sourced values are placeholders ({String.intercalate ", " secrets}): \
`apply` reads them from the cloud and they never leave it."]
  return String.intercalate "\n"
    (["---", s!"# Source: {slotId p .kubernetesObject name}"] ++ note ++ [body])

/-- Every declared object `scope` admits, rendered, in declaration order; or
    the declaration's Kubernetes problem. Empty when there is nothing to
    render — the caller says so. -/
def render {κ : Keys} (T : Plan κ) (fleet : String) (scope : Scope := .all) :
    Except String String := do
  if let some problem := T.kubernetesProblem then throw problem
  let docs ← (Finite.elems (α := ProviderId)).flatMapM fun p =>
    (Finite.elems (α := κ.Key p .kubernetesObject)).filterMapM fun key => do
      let name := κ.name p .kubernetesObject key
      match T.assign p .kubernetesObject key, ObjectName.parse? name with
      | .present s, some n =>
        if !scope.admits p n.cluster then return none
        -- `kubernetesIsSound` has just required the shape to be a literal.
        match s.shape.asLit with
        | some shape => return some (← document p name n shape fleet)
        | none       => throw s!"{slotId p .kubernetesObject name}: the shape is not a literal"
      | _, _ => return none
  return String.intercalate "\n" docs ++ (if docs.isEmpty then "" else "\n")

end Infra.Interop.KubernetesYaml
