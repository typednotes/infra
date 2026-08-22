import Infra.Core.Diff
import Lean.Data.Json

/-
  Serverless Postgres, abstracted across backends (`docs/architecture.md`'s Abstractions
  section, "with an emphasis on ... Serverless db"). `PostgresTarget`/`PostgresState`/`Diffable`
  are defined once here so provider modules can reuse them directly instead of duplicating diff
  logic.
-/

namespace Infra.Abstractions

open Infra.Core
open Lean (ToJson FromJson)

/-- Every field optional: unset means "use the provider default on create, or leave as-is". -/
structure PostgresTarget where
  name    : Option String := none
  version : Option String := none

structure PostgresState where
  name     : String
  id       : String
  version  : String
  endpoint : String
deriving DecidableEq, Repr, ToJson, FromJson

/-- `some v` means "call the API to set this field to `v`"; `none` means nothing to do.
    The all-`none` value, `({} : PostgresState.Delta)`, means the target is already realized.
    `endpoint` isn't diffable: it's assigned by the provider on create, never set by a target. -/
structure PostgresState.Delta where
  name    : Option String := none
  version : Option String := none
deriving DecidableEq, Repr

instance : Diffable PostgresTarget PostgresState where
  Delta := PostgresState.Delta
  diff t c := { name := fieldDiff t.name c.name, version := fieldDiff t.version c.version }
  apply c d := { c with name := fieldApply c.name d.name, version := fieldApply c.version d.version }
  Satisfies t c := fieldSatisfied t.name c.name ∧ fieldSatisfied t.version c.version
  satisfies_apply_diff t c :=
    ⟨fieldSatisfies_fieldApply t.name c.name, fieldSatisfies_fieldApply t.version c.version⟩

/-- Mirrors Terraform/OpenTofu's provider CRUD contract; see `ObjectStoreBackend` for why
    there's no `readPostgres` here (that's `SyncEngine.pull`, not per-resource). -/
class ServerlessPostgresBackend (α : Type) where
  listPostgres   : α → IO (List (String × PostgresState))
  createPostgres : α → PostgresTarget → IO PostgresState
  updatePostgres : α → PostgresState → PostgresState.Delta → IO PostgresState
  deletePostgres : α → PostgresState → IO Unit

end Infra.Abstractions
