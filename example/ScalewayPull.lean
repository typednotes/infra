import Infra

/-!
  # Example: authenticate to Scaleway alone, pull, export

  Demonstrates the smallest useful slice of `infra` against one cloud:

    1. authenticate to Scaleway only, via the credential chain in
       `docs/authentication.md` (no AWS credentials are read or needed);
    2. ask every `Kind` what Scaleway reports for it — a raw `Backend.list`,
       not `Infra.Core.pull`, because `pull` only keeps resources a
       compile-time `Keys` fleet already declares by name (see
       `docs/persistence.md`), and the point here is to show *everything* an
       account reports without first having to name it;
    3. write what came back to `out/scaleway/`, once as JSON and once as
       elaborable Lean source.

  The Lean file is a snapshot for a human to read next to the target
  definitions, in the spirit of the "persist as Lean source" option
  `docs/persistence.md` considered and set aside for the on-disk cache
  specifically — nothing here re-elaborates it, and nothing in `Infra.Core`
  reads `out/`.

  Run with:

      lake exe scaleway-pull
-/

open Infra.Core
open Lean (Json toJson)

/-- Gitignored scratch output, same as the top-level `out/` every other local
    artifact in this repo lands in. -/
def outDir : System.FilePath := "out" / "scaleway"

/-- `Repr (ObservedOf k)` isn't generic in `k` the way `ToJson (ObservedOf k)`
    is (`Infra.Core.Kind` only declares the latter), so dispatch by hand — one
    branch per kind, same as `Infra.Core.observedHandle`. -/
def reprObserved : (k : Kind) → ObservedOf k → String
  | .iam,              o => toString (repr o)
  | .objectStore,      o => toString (repr o)
  | .compute,          o => toString (repr o)
  | .queues,           o => toString (repr o)
  | .secrets,          o => toString (repr o)
  | .imageRegistry,    o => toString (repr o)
  | .postgres,         o => toString (repr o)
  | .s3Bucket,         o => toString (repr o)
  | .scalewayFunction, o => toString (repr o)

/-- The `def` name and `Kind` constructor to write into the generated Lean
    file for each kind. -/
def declFor : Kind → String × String
  | .iam              => ("pulledIam", "iam")
  | .objectStore      => ("pulledObjectStore", "objectStore")
  | .compute          => ("pulledCompute", "compute")
  | .queues           => ("pulledQueues", "queues")
  | .secrets          => ("pulledSecrets", "secrets")
  | .imageRegistry    => ("pulledImageRegistry", "imageRegistry")
  | .postgres         => ("pulledPostgres", "postgres")
  | .s3Bucket         => ("pulledS3Bucket", "s3Bucket")
  | .scalewayFunction => ("pulledScalewayFunction", "scalewayFunction")

/-- One resource per array element, exactly what a `pull`-cached file would
    hold for this kind (`Infra.Core.Persistence.rowsAt`). -/
def jsonOf {k : Kind} (observed : List (ObservedOf k)) : Json :=
  Json.arr (observed.map toJson).toArray

/-- A literal `List (ObservedOf .<kind>)` — the same record syntax
    `Infra.Demo` writes by hand, produced here from what Scaleway actually
    reported instead of typed in as a fixture. -/
def leanOf (k : Kind) (observed : List (ObservedOf k)) : String :=
  let (defName, ctor) := declFor k
  let entries := String.intercalate ",\n  " (observed.map (reprObserved k))
  s!"import Infra\n\n\
open Infra.Core\n\n\
/-- {observed.length} `{k.name}` resource(s), pulled live from Scaleway.\n\
    A snapshot for a human to read, not re-elaborated by anything in\n\
    `Infra` — re-run the example to refresh it. -/\n\
def {defName} : List (ObservedOf .{ctor}) :=\n\
  [ {entries}\n\
  ]\n"

def main : IO Unit := do
  IO.println "authenticating to Scaleway..."
  let creds ← Credentials.load .scaleway
  IO.println s!"authenticated (region {creds.region})"

  let backend := Infra.Providers.liveBackend .scaleway creds
  IO.FS.createDirAll outDir

  let mut total := 0
  for k in Finite.elems (α := Kind) do
    let observed ← backend.list k
    unless observed.isEmpty do
      total := total + observed.length
      let jsonPath := outDir / s!"{k.name}.json"
      let leanPath := outDir / s!"{k.name}.lean"
      IO.FS.writeFile jsonPath (jsonOf observed).pretty
      IO.FS.writeFile leanPath (leanOf k observed)
      IO.println s!"  {k.name}: {observed.length} resource(s) -> {jsonPath}, {leanPath}"

  if total == 0 then
    IO.println s!"nothing found; wrote no files under {outDir}"
  else
    IO.println s!"done: {total} resource(s) across every kind Scaleway reported"
