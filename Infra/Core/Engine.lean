import Infra.Core.Diff
import Infra.Core.Persistence
import Lean.Data.Json

/-
  Sync loop. `pull`/`push` are collection-shaped — a keyed list of `Current`, not a single
  object — because deciding "an object is missing" (`docs/diff-semantics.md`'s collection-level
  rules) only makes sense across a whole collection, never for one object in isolation.
-/

namespace Infra.Core

open Lean (ToJson FromJson)

/-- `push` takes the target and current collections and is expected (informally; not provable
    in general, since it depends on a live remote system) to leave the remote's collection
    reconciled per `reconcile`'s three rules. Not implemented this round — see `pull` below,
    which is. -/
structure SyncEngine (Target Current : Type) [Diffable Target Current] where
  pull : IO (List (String × Current))
  push : List (String × Target) → List (String × Current) → IO (List (String × Current))

/-- Pulls the current collection from a backend's `list*` method and persists it to the local
    JSON cache (`docs/persistence.md`) before returning it, so the next `pull` (or a future
    `push`) has a record of what was last seen even before any live provider call exists.
    `list` is the backend's own structural, still-placeholder `list*` stub — `pull` itself does
    real, runnable work (reads a backend, writes a real file) even though nothing behind `list`
    is live yet. -/
def pull [ToJson Current] [FromJson Current]
    (root : System.FilePath) (provider service : String)
    (list : IO (List (String × Current))) : IO (List (String × Current)) := do
  let remote ← list
  Persistence.save (Persistence.statePath root provider service) remote
  pure remote

end Infra.Core
