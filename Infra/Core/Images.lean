import Infra.Core.Backend

namespace Infra.Core

open Infra.Specs

/-- Resolve all image fields of a settled spec, across all container kinds. -/
def pinSpecImages (b : Backend) : (k : Kind) → ProviderSpec k → IO (ProviderSpec k)
  | .compute, s => do return { s with image := ← b.resolveImage s.image }
  | .scalewayContainer, s => do return { s with image := ← b.resolveImage s.image }
  | .kubernetesObject, s => do
    let mut pins : List (String × String) := []
    for image in s.shape.images.eraseDups do
      pins := (image, ← b.resolveImage image) :: pins
    return { s with shape := s.shape.mapImages fun image => (pins.lookup image).getD image }
  | _, s => pure s

/-- Read image selectors without settling unrelated fields (a container can
    name a namespace or secret which its first apply has not created yet). -/
def planImages {κ : Keys} (T : Plan κ) (W : World κ) (p : ProviderId) (k : Kind)
    (key : κ.Key p k) : List String :=
  let env := (envOfWorld W).withRedactedSecrets
  match k with
  | .compute => match T.assign p .compute key with
      | .present s => (Expr.eval? env s.image).toList
      | _ => []
  | .scalewayContainer => match T.assign p .scalewayContainer key with
      | .present s => (Expr.eval? env s.image).toList
      | _ => []
  | .kubernetesObject => match T.assign p .kubernetesObject key with
      | .present s => ((Expr.eval? env s.shape).map (·.images)).getD []
      | _ => []
  | _ => []

/-- Resolve each distinct image once per cloud/slot's backend in this run.
    Preserve expression dependencies: newly-created inputs are resolved when
    the action settles, rather than replaced by an unrelated literal.
    Foreign resources are skipped before any registry lookup. -/
def fetchImagePins {κ : Keys} (bs : Backends) (T : Plan κ) (W : World κ)
    (skip : List String) : IO (List (ProviderId × String × String)) := do
  let mut pins : List (ProviderId × String × String) := []
  for p in Finite.elems (α := ProviderId) do
    for k in [.compute, .scalewayContainer, .kubernetesObject] do
      for key in Finite.elems (α := κ.Key p k) do
        let nm := κ.name p k key
        if skip.contains (slotId p k nm) then continue
        for image in (planImages T W p k key).eraseDups do
          unless pins.any (fun x => x.1 == p && x.2.1 == image) do
            let pinned ← try (bs.backendFor p k nm).resolveImage image catch e =>
              throw (IO.userError s!"{slotId p k nm}: could not resolve image '{image}': {e}")
            pins := (p, image, pinned) :: pins
  return pins

/-- Rewrite the prepared fields without losing any expression dependencies. -/
def withImagePins {κ : Keys} (T : Plan κ) (pins : List (ProviderId × String × String)) :
    Plan κ :=
  let rewrite (p : ProviderId) (image : String) :=
    ((pins.find? fun x => x.1 == p && x.2.1 == image).map (·.2.2)).getD image
  { assign := fun p k key =>
    match k, key with
    | .compute, key => match T.assign p .compute key with
        | .present s => .present { s with image := s.image.map (rewrite p) }
        | other => other
    | .scalewayContainer, key => match T.assign p .scalewayContainer key with
        | .present s => .present { s with image := s.image.map (rewrite p) }
        | other => other
    | .kubernetesObject, key => match T.assign p .kubernetesObject key with
        | .present s => .present { s with shape := s.shape.map (ObjectShape.mapImages (rewrite p)) }
        | other => other
    | k, key => T.assign p k key }

end Infra.Core
