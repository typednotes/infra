import Infra.Core.Diff
import Infra.Core.State

/-
  AWS IAM, no matching cross-cutting Abstraction (`docs/architecture.md`'s Coverage section
  lists IAM as a base service, not one of the five Abstractions). Defines its own
  `TargetState`/`RemoteState`/`Diffable` pair, following `Infra.Providers.Scaleway.Iam`'s
  worked pattern.
-/

namespace Infra.Providers.Aws.Iam

open Infra.Core

/-- Every field optional: unset means "use the provider default on create, or leave as-is". -/
structure TargetState where
  name       : Option String := none
  policyArns : Option (List String) := none

structure RemoteState where
  name       : String
  id         : String
  policyArns : List String
deriving DecidableEq, Repr

/-- `some v` means "call the API to set this field to `v`"; `none` means nothing to do. -/
structure RemoteState.Delta where
  name       : Option String := none
  policyArns : Option (List String) := none
deriving DecidableEq, Repr

instance : Diffable TargetState RemoteState where
  Delta := RemoteState.Delta
  diff t c := { name := fieldDiff t.name c.name, policyArns := fieldDiff t.policyArns c.policyArns }
  apply c d :=
    { c with name := fieldApply c.name d.name, policyArns := fieldApply c.policyArns d.policyArns }
  Satisfies t c := fieldSatisfied t.name c.name ∧ fieldSatisfied t.policyArns c.policyArns
  satisfies_apply_diff t c :=
    ⟨fieldSatisfies_fieldApply t.name c.name, fieldSatisfies_fieldApply t.policyArns c.policyArns⟩

instance : Keyed RemoteState where
  key s := { provider := "aws", service := "iam", id := s.id }

class IamBackend (α : Type) where
  createIam : α → TargetState → IO RemoteState
  updateIam : α → RemoteState → RemoteState.Delta → IO RemoteState
  deleteIam : α → RemoteState → IO Unit

structure Backend where

instance : IamBackend Backend where
  createIam _ t := pure { name := t.name.getD "unnamed", id := "placeholder-id", policyArns := t.policyArns.getD [] }
  updateIam _ c d := pure (Diffable.apply (Target := TargetState) c d)
  deleteIam _ _ := pure ()

end Infra.Providers.Aws.Iam
