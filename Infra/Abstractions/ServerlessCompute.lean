import Infra.Core.Diff
import Lean.Data.Json

/-
  Serverless compute, abstracted across backends (`docs/architecture.md`'s Abstractions
  section, "with an emphasis on Serverless compute"). `ComputeTarget`/`ComputeState`/`Diffable`
  are defined once here so provider modules can reuse them directly instead of duplicating diff
  logic.
-/

namespace Infra.Abstractions

open Infra.Core
open Lean (ToJson FromJson)

/-- Every field optional: unset means "use the provider default on create, or leave as-is". -/
structure ComputeTarget where
  name    : Option String := none
  runtime : Option String := none

structure ComputeState where
  name    : String
  id      : String
  runtime : String
  status  : String
deriving DecidableEq, Repr, ToJson, FromJson

/-- `some v` means "call the API to set this field to `v`"; `none` means nothing to do.
    The all-`none` value, `({} : ComputeState.Delta)`, means the target is already realized.
    `status` isn't diffable: it reflects the provider's own lifecycle, never set by a target. -/
structure ComputeState.Delta where
  name    : Option String := none
  runtime : Option String := none
deriving DecidableEq, Repr

instance : Diffable ComputeTarget ComputeState where
  Delta := ComputeState.Delta
  diff t c := { name := fieldDiff t.name c.name, runtime := fieldDiff t.runtime c.runtime }
  apply c d := { c with name := fieldApply c.name d.name, runtime := fieldApply c.runtime d.runtime }
  Satisfies t c := fieldSatisfied t.name c.name ∧ fieldSatisfied t.runtime c.runtime
  satisfies_apply_diff t c :=
    ⟨fieldSatisfies_fieldApply t.name c.name, fieldSatisfies_fieldApply t.runtime c.runtime⟩

/-- Mirrors Terraform/OpenTofu's provider CRUD contract; see `ObjectStoreBackend` for why
    there's no `readCompute` here (that's `SyncEngine.pull`, not per-resource). -/
class ServerlessComputeBackend (α : Type) where
  listCompute   : α → IO (List (String × ComputeState))
  createCompute : α → ComputeTarget → IO ComputeState
  updateCompute : α → ComputeState → ComputeState.Delta → IO ComputeState
  deleteCompute : α → ComputeState → IO Unit

end Infra.Abstractions
