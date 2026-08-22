import Infra.Core.Diff
import Lean.Data.Json

/-
  Secret management, abstracted across backends (`docs/architecture.md`'s Abstractions section).
  `SecretTarget`/`SecretState`/`Diffable` are defined once here so provider modules can reuse
  them directly instead of duplicating diff logic.
-/

namespace Infra.Abstractions

open Infra.Core
open Lean (ToJson FromJson)

/-- Every field optional: unset means "use the provider default on create, or leave as-is". -/
structure SecretTarget where
  name  : Option String := none
  value : Option String := none

structure SecretState where
  name  : String
  id    : String
  value : String
deriving DecidableEq, Repr, ToJson, FromJson

/-- `some v` means "call the API to set this field to `v`"; `none` means nothing to do.
    The all-`none` value, `({} : SecretState.Delta)`, means the target is already realized. -/
structure SecretState.Delta where
  name  : Option String := none
  value : Option String := none
deriving DecidableEq, Repr

instance : Diffable SecretTarget SecretState where
  Delta := SecretState.Delta
  diff t c := { name := fieldDiff t.name c.name, value := fieldDiff t.value c.value }
  apply c d := { c with name := fieldApply c.name d.name, value := fieldApply c.value d.value }
  Satisfies t c := fieldSatisfied t.name c.name ∧ fieldSatisfied t.value c.value
  satisfies_apply_diff t c :=
    ⟨fieldSatisfies_fieldApply t.name c.name, fieldSatisfies_fieldApply t.value c.value⟩

/-- Mirrors Terraform/OpenTofu's provider CRUD contract; see `ObjectStoreBackend` for why
    there's no `readSecret` here (that's `SyncEngine.pull`, not per-resource). -/
class SecretsBackend (α : Type) where
  listSecrets  : α → IO (List (String × SecretState))
  createSecret : α → SecretTarget → IO SecretState
  updateSecret : α → SecretState → SecretState.Delta → IO SecretState
  deleteSecret : α → SecretState → IO Unit

end Infra.Abstractions
