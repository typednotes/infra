import Infra.Core.Diff

/-
  Sync-loop skeleton. No live implementation — `pull`/`push` are supplied per provider
  module once real API calls are added.
-/

namespace Infra.Core

/-- `push` takes the already-computed `Delta`, not `target`/`current` directly, since
    `Delta` carries exactly what a real implementation needs to build its API requests
    (callers may skip the call entirely when `delta = ({} : Delta)`). A successful `push`
    is expected (informally; not provable in general, since it depends on a live remote
    system) to leave the remote's current state equal to `Diffable.apply current delta`. -/
structure SyncEngine (Target Current : Type) [Diffable Target Current] where
  pull : IO Current
  push : (current : Current) → Diffable.Delta (Target := Target) (Current := Current) → IO Current

end Infra.Core
