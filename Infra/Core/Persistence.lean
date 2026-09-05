import Infra.Core.Backend
import Lean.Data.Json

/-
  Caching the observed world on local disk.

  One JSON file per `(provider, kind)`: an object mapping each fleet key's `Keys.name` to that
  resource's serialised `ObservedOf`. Lives under a gitignored root because it can hold values
  pulled through the `secrets` kind — see `docs/persistence.md`.

  Only the *observed* half of a `Sighting` is cached, not the reported
  configuration. The cache is a record of what was last seen; the configuration
  is re-read on every pull anyway, so persisting it would add a JSON codec per
  kind and buy nothing.
-/

namespace Infra.Core.Persistence

open Lean (Json ToJson FromJson toJson fromJson?)

def statePath (root : System.FilePath) (p : ProviderId) (k : Kind) : System.FilePath :=
  root / p.name / s!"{k.name}.json"

private def orThrow {α : Type} (path : System.FilePath) : Except String α → IO α
  | .ok a    => pure a
  | .error e => throw (IO.userError s!"{path}: {e}")

/-- The rows belonging to one `(provider, kind)`, as `(key name, observed)` pairs.

    No dependent cast needed, unlike `worldOf`: the result type is a plain `String × Json`, so
    the entry's own indices are enough to serialise it and `(p, k)` only has to filter. -/
private def rowsAt {κ : Keys} (es : List (CachedEntry κ)) (p : ProviderId) (k : Kind) :
    List (String × Json) :=
  es.filterMap fun e =>
    match e with
    | ⟨p', k', key', o⟩ =>
      if p' = p ∧ k' = k then some (κ.name p' k' key', toJson o) else none

/-- Writes the `(provider, kind)` pairs that have something in them, and **removes the file for
    a pair that has become empty**.

    That second half was missing, and its absence made the cache lie. Writing only non-empty
    pairs is right — the cache should not fill with empty files for every unused kind — but
    skipping an emptied pair left its previous contents on disk untouched, mtime and all. After a
    `destroy`, the cache still listed every resource that had just been deleted, and went on
    doing so indefinitely, because nothing ever wrote that path again.

    Nothing *reads* the cache today (`load` has no callers; the engine plans from a fresh
    `pull`), so no plan was ever wrong because of this. What it wrecked was the cache's value as
    a record: it is the thing a human or an external tool looks at to see what a fleet last
    observed, and it was reporting resources that no longer existed. It fooled the author of this
    comment into asserting that two terminated EC2 instances were still running.

    Deleting is guarded by `pathExists` rather than caught, so a genuine permission error still
    surfaces instead of being swallowed. -/
def save {κ : Keys} (root : System.FilePath) (es : List (CachedEntry κ)) : IO Unit := do
  for p in Finite.elems (α := ProviderId) do
    for k in Finite.elems (α := Kind) do
      let rows := rowsAt es p k
      let path := statePath root p k
      if rows.isEmpty then
        if ← path.pathExists then
          IO.FS.removeFile path
      else
        if let some dir := path.parent then
          IO.FS.createDirAll dir
        IO.FS.writeFile path (Json.mkObj rows).compress

/-- A missing file means "nothing cached yet" rather than an error — that is exactly the state
    before the first pull. A cached name the current fleet no longer declares is skipped: the
    key type is the source of truth about what the fleet contains, not the cache. -/
def load {κ : Keys} (root : System.FilePath) : IO (List (CachedEntry κ)) := do
  let mut acc : List (CachedEntry κ) := []
  for p in Finite.elems (α := ProviderId) do
    for k in Finite.elems (α := Kind) do
      let path := statePath root p k
      if ← path.pathExists then
        let contents ← IO.FS.readFile path
        let json ← orThrow path (Json.parse contents)
        let obj ← orThrow path json.getObj?
        for (nm, v) in obj.toList do
          match (Finite.elems (α := κ.Key p k)).find? (fun key => κ.name p k key == nm) with
          | some key =>
            let o ← orThrow path (fromJson? (α := ObservedOf k) v)
            acc := ⟨p, k, key, o⟩ :: acc
          | none => pure ()
  return acc

end Infra.Core.Persistence
