import Infra

open Infra.Core

/-- Round-trips a small keyed collection through `Persistence.save`/`load` in a scratch temp
    directory, to check the on-disk format is actually readable back, not just writable. -/
def checkPersistenceRoundTrip : IO Unit := do
  let tmp ← IO.FS.createTempDir
  try
    let path := Persistence.statePath tmp "aws" "object-store"
    let saved : List (String × Infra.Abstractions.BucketState) :=
      [("my_bucket", { name := "my_bucket", id := "b-1", tags := ["env:dev"] })]
    Persistence.save path saved
    let loaded ← Persistence.load (α := Infra.Abstractions.BucketState) path
    if loaded = saved then
      IO.println "persistence round-trip: ok"
    else
      throw (IO.userError s!"persistence round-trip mismatch: saved {repr saved}, loaded {repr loaded}")
  finally
    IO.FS.removeDirAll tmp

def main : IO Unit := do
  IO.println "infra: foundation layer loaded"
  checkPersistenceRoundTrip
