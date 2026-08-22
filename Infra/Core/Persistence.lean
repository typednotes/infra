import Lean.Data.Json

/-
  Filesystem storage interface for cached current-state, resolving `docs/persistence.md`'s
  "Decision" (serialize as JSON) and its open questions on layout/location: one JSON file per
  (provider, service), object-keyed by each resource's local key (see `docs/diff-semantics.md`),
  under a gitignored root (`.infra/state/` by convention — the caller picks `root`).
-/

namespace Infra.Core.Persistence

open Lean (Json ToJson FromJson toJson fromJson?)

def statePath (root : System.FilePath) (provider service : String) : System.FilePath :=
  root / provider / s!"{service}.json"

/-- Reads a persisted keyed collection. A missing file means "nothing pulled yet" — not an
    error, since this is exactly the state before the very first `pull`. -/
def load [FromJson α] (path : System.FilePath) : IO (List (String × α)) := do
  if ← path.pathExists then
    let contents ← IO.FS.readFile path
    let json ← match Json.parse contents with
      | .ok j => pure j
      | .error e => throw (IO.userError s!"{path}: {e}")
    let obj ← match json.getObj? with
      | .ok o => pure o
      | .error e => throw (IO.userError s!"{path}: {e}")
    match obj.toList.mapM fun (k, v) => (fromJson? v).map (k, ·) with
    | .ok kvs => pure kvs
    | .error e => throw (IO.userError s!"{path}: {e}")
  else
    pure []

/-- Writes a keyed collection, creating the parent directory if it doesn't exist yet. -/
def save [ToJson α] (path : System.FilePath) (state : List (String × α)) : IO Unit := do
  match path.parent with
  | some dir => IO.FS.createDirAll dir
  | none => pure ()
  let json := Json.mkObj (state.map fun (k, v) => (k, toJson v))
  IO.FS.writeFile path json.compress

end Infra.Core.Persistence
