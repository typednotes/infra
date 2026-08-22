import Infra.Core.Diff
import Infra.Core.State

/-
  AWS queues (SQS), no matching cross-cutting Abstraction. Defines its own
  `TargetState`/`RemoteState`/`Diffable` pair, following `Infra.Providers.Scaleway.Iam`'s
  worked pattern.
-/

namespace Infra.Providers.Aws.Queues

open Infra.Core

/-- Every field optional: unset means "use the provider default on create, or leave as-is". -/
structure TargetState where
  name              : Option String := none
  visibilityTimeout : Option Nat := none

structure RemoteState where
  name              : String
  id                : String
  visibilityTimeout : Nat
deriving DecidableEq, Repr

/-- `some v` means "call the API to set this field to `v`"; `none` means nothing to do. -/
structure RemoteState.Delta where
  name              : Option String := none
  visibilityTimeout : Option Nat := none
deriving DecidableEq, Repr

instance : Diffable TargetState RemoteState where
  Delta := RemoteState.Delta
  diff t c :=
    { name := fieldDiff t.name c.name, visibilityTimeout := fieldDiff t.visibilityTimeout c.visibilityTimeout }
  apply c d :=
    { c with
      name := fieldApply c.name d.name
      visibilityTimeout := fieldApply c.visibilityTimeout d.visibilityTimeout }
  Satisfies t c := fieldSatisfied t.name c.name ∧ fieldSatisfied t.visibilityTimeout c.visibilityTimeout
  satisfies_apply_diff t c :=
    ⟨fieldSatisfies_fieldApply t.name c.name,
     fieldSatisfies_fieldApply t.visibilityTimeout c.visibilityTimeout⟩

instance : Keyed RemoteState where
  key s := { provider := "aws", service := "queues", id := s.id }

class QueuesBackend (α : Type) where
  createQueue : α → TargetState → IO RemoteState
  updateQueue : α → RemoteState → RemoteState.Delta → IO RemoteState
  deleteQueue : α → RemoteState → IO Unit

structure Backend where

instance : QueuesBackend Backend where
  createQueue _ t :=
    pure { name := t.name.getD "unnamed", id := "placeholder-id", visibilityTimeout := t.visibilityTimeout.getD 30 }
  updateQueue _ c d := pure (Diffable.apply (Target := TargetState) c d)
  deleteQueue _ _ := pure ()

end Infra.Providers.Aws.Queues
