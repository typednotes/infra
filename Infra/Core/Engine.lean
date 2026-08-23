import Infra.Core.Backend
import Infra.Core.Persistence

/-
  The sync loop: observe the world, then work out what has to change.

  `push` — actually running the `Action` list against the backends — is deliberately not here
  yet. Ordering it correctly needs the dependency DAG from `HasDeps` (creation edges, and the
  transpose for deletion), and executing it needs live provider clients, neither of which
  exists in this increment.
-/

namespace Infra.Core

/-- Ask every backend to list every kind, and match what comes back to fleet keys by
    `Keys.name`.

    Listed resources that no fleet key claims are simply dropped, which is what makes a real
    `list` safe to plug in: the fleet's key types decide what this target manages, so an
    account full of unmanaged buckets cannot turn into a pile of proposed deletions. -/
def pullEntries {κ : Keys} (bs : Backends) : IO (List (Entry κ)) := do
  let mut acc : List (Entry κ) := []
  for p in Finite.elems (α := ProviderId) do
    for k in Finite.elems (α := Kind) do
      let observed ← (bs.backend p).list k
      for key in Finite.elems (α := κ.Key p k) do
        match observed.find? (fun o => (observedHandle k o).raw == κ.name p k key) with
        | some o => acc := ⟨p, k, key, o⟩ :: acc
        | none   => pure ()
  return acc

/-- Observe the world and cache it. The cache is written before the `World` is returned, so a
    later run has a record of what was last seen even though nothing behind `list` is live
    yet. -/
def pull {κ : Keys} (root : System.FilePath) (bs : Backends) : IO (World κ) := do
  let es ← pullEntries (κ := κ) bs
  Persistence.save root es
  return worldOf es

/-- What would have to change for the world to realise the target. Pure: it decides, it does
    not act. `Action` carries its direction explicitly so the eventual scheduler can union the
    creation DAG with the reversed deletion DAG. -/
def plan {κ : Keys} (T : Plan κ) (W : World κ) : List (Action κ) := actions T W

end Infra.Core
