import Infra.Core.Diff
import Lean.Data.Json

/-
  Object store, abstracted across backends (`docs/architecture.md`'s Abstractions section).
  `BucketTarget`/`BucketState`/`Diffable` are defined once here so provider modules
  (`Infra/Providers/{Aws,Scaleway}/ObjectStore.lean`) can reuse them directly instead of
  duplicating diff logic.
-/

namespace Infra.Abstractions

open Infra.Core
open Lean (ToJson FromJson)

/-- Every field optional: unset means "use the provider default on create, or leave as-is". -/
structure BucketTarget where
  name : Option String := none
  tags : Option (List String) := none

structure BucketState where
  name : String
  id   : String
  tags : List String
deriving DecidableEq, Repr, ToJson, FromJson

/-- `some v` means "call the API to set this field to `v`"; `none` means nothing to do.
    The all-`none` value, `({} : BucketState.Delta)`, means the target is already realized. -/
structure BucketState.Delta where
  name : Option String := none
  tags : Option (List String) := none
deriving DecidableEq, Repr

instance : Diffable BucketTarget BucketState where
  Delta := BucketState.Delta
  diff t c := { name := fieldDiff t.name c.name, tags := fieldDiff t.tags c.tags }
  apply c d := { c with name := fieldApply c.name d.name, tags := fieldApply c.tags d.tags }
  Satisfies t c := fieldSatisfied t.name c.name ∧ fieldSatisfied t.tags c.tags
  satisfies_apply_diff t c :=
    ⟨fieldSatisfies_fieldApply t.name c.name, fieldSatisfies_fieldApply t.tags c.tags⟩

/-- Mirrors Terraform/OpenTofu's provider CRUD contract (Create/Read/Update/Delete): `Read` is
    covered at the `SyncEngine.pull` level (fetching `Current` isn't per-resource), but
    `Create`/`Update`/`Delete` are per-resource and belong on the backend. `updateBucket` takes
    the already-computed `Delta` so a real implementation can build one in-place API request
    instead of destroying and recreating the bucket. -/
class ObjectStoreBackend (α : Type) where
  listBuckets  : α → IO (List (String × BucketState))
  createBucket : α → BucketTarget → IO BucketState
  updateBucket : α → BucketState → BucketState.Delta → IO BucketState
  deleteBucket : α → BucketState → IO Unit

section Guards

private def target : BucketTarget := { name := some "b2" }   -- tags left unset
private def current : BucketState := { name := "b", id := "1", tags := ["env:prod"] }
private def delta := Diffable.diff target current
private def result := Diffable.apply current delta

#guard delta.name = some "b2"          -- a real API call is needed, and to what value
#guard delta.tags = none               -- unset field: nothing to push
#guard result.name = "b2"              -- specified field gets updated
#guard result.tags = ["env:prod"]      -- unset field is left as-is, not cleared
#guard result.id = "1"                 -- fields Diffable doesn't touch are untouched

private def alreadyRealized : BucketTarget := { name := some "b" }  -- matches current.name
private def noopDelta : BucketState.Delta := Diffable.diff alreadyRealized current
#guard noopDelta = ({} : BucketState.Delta)  -- nothing to push

-- Collection-level reconciliation: "new" only in targets, "gone" only in currents, "kept" in
-- both (with a real field difference to reconcile).
private def newBucket : BucketTarget := { name := some "n" }
private def goneBucket : BucketState := { name := "g", id := "2", tags := [] }
private def keptTarget : BucketTarget := { name := some "k2" }
private def keptCurrent : BucketState := { name := "k", id := "3", tags := [] }

private def collectionDelta : CollectionDelta BucketTarget BucketState :=
  reconcile [("new", newBucket), ("kept", keptTarget)] [("gone", goneBucket), ("kept", keptCurrent)]

#guard collectionDelta.toCreate.map Prod.fst = ["new"]     -- target-only key -> create
#guard collectionDelta.toDelete.map Prod.fst = ["gone"]    -- current-only key -> delete
#guard collectionDelta.toUpdate.map (fun (k, _, _) => k) = ["kept"]  -- shared key -> field diff
#guard collectionDelta.toUpdate.map (fun (_, _, d) => d) = [({ name := some "k2" } : BucketState.Delta)]

end Guards

end Infra.Abstractions
