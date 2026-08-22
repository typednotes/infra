import Infra.Core.Diff
import Infra.Core.State

/-
  Scaleway image registry (Container Registry), no matching cross-cutting Abstraction. Defines
  its own `TargetState`/`RemoteState`/`Diffable` pair, following
  `Infra.Providers.Scaleway.Iam`'s worked pattern.
-/

namespace Infra.Providers.Scaleway.ImageRegistry

open Infra.Core

/-- Every field optional: unset means "use the provider default on create, or leave as-is". -/
structure TargetState where
  name : Option String := none
  tags : Option (List String) := none

structure RemoteState where
  name          : String
  id            : String
  tags          : List String
  repositoryUri : String
deriving DecidableEq, Repr

/-- `some v` means "call the API to set this field to `v`"; `none` means nothing to do.
    `repositoryUri` isn't diffable: it's assigned by the provider on create, never set by a
    target. -/
structure RemoteState.Delta where
  name : Option String := none
  tags : Option (List String) := none
deriving DecidableEq, Repr

instance : Diffable TargetState RemoteState where
  Delta := RemoteState.Delta
  diff t c := { name := fieldDiff t.name c.name, tags := fieldDiff t.tags c.tags }
  apply c d := { c with name := fieldApply c.name d.name, tags := fieldApply c.tags d.tags }
  Satisfies t c := fieldSatisfied t.name c.name ∧ fieldSatisfied t.tags c.tags
  satisfies_apply_diff t c :=
    ⟨fieldSatisfies_fieldApply t.name c.name, fieldSatisfies_fieldApply t.tags c.tags⟩

instance : Keyed RemoteState where
  key s := { provider := "scaleway", service := "image-registry", id := s.id }

class ImageRegistryBackend (α : Type) where
  createRepository : α → TargetState → IO RemoteState
  updateRepository : α → RemoteState → RemoteState.Delta → IO RemoteState
  deleteRepository : α → RemoteState → IO Unit

structure Backend where

instance : ImageRegistryBackend Backend where
  createRepository _ t :=
    pure { name := t.name.getD "unnamed", id := "placeholder-id", tags := t.tags.getD [],
           repositoryUri := "placeholder.invalid/unnamed" }
  updateRepository _ c d := pure (Diffable.apply (Target := TargetState) c d)
  deleteRepository _ _ := pure ()

end Infra.Providers.Scaleway.ImageRegistry
