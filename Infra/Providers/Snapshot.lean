import Infra.Providers.Placeholder
import Infra.Core.Ownership
import Infra.Core.Engine
import Lean.Data.Json

/-
  An infrastructure, as data: what `dump` writes, and what tests replay.

  A `Snapshot` is the resources an account holds — each with its cloud, kind,
  name, region, the ownership evidence a backend would report for it (tags or a
  decoded description marker, its bare name, or nothing readable), and
  optionally what the cloud reported about it (`ObservedOf`).

  Two uses, one format:

  * **`dump`** (`Infra.Cli`) writes the live account as a snapshot — the way to
    look at what a fleet manages, since nothing is stored locally.
  * **`Snapshot.backends`** replays a snapshot as a set of in-memory backends:
    `list`, `read` and `ownershipInfo` answer from it, and `delete` records
    what was asked instead of calling anything. So a test can describe an
    infrastructure in a few lines — or load a real dump — and run `plan`,
    `claimUndeclared` or `push` against it offline.

  It is not a record the engine reads back: no plan depends on a snapshot
  unless a test hands it one. (This is the shape the retired ledger and
  observed-state cache had — names, regions, observations — kept for the job
  it is actually good at.)
-/

namespace Infra.Providers.Snapshot

open Infra.Core
open Lean (Json ToJson FromJson toJson fromJson?)

/-- One resource in an account. -/
structure Resource where
  cloud    : ProviderId
  kind     : Kind
  name     : String
  region   : String := ""
  /-- What `Backend.ownershipInfo` answers for it. -/
  evidence : Evidence := .unreadable
  /-- What the cloud reported (`ObservedOf kind`, as JSON), if captured;
      replayed as a placeholder observation otherwise. -/
  observed : Option Json := none
  deriving BEq

def Resource.slot (r : Resource) : String := slotId r.cloud r.kind r.name

/-- A resource carrying the marker `managed-by-infra=<fleet>`. -/
def marked (cloud : ProviderId) (kind : Kind) (name fleet : String) (region := "") : Resource :=
  { cloud, kind, name, region, evidence := .tags [(markerKey, fleet)] none }

/-- A resource whose only evidence is its name (the ladder's last rung). -/
def byName (cloud : ProviderId) (kind : Kind) (name : String) (region := "") : Resource :=
  { cloud, kind, name, region, evidence := .named name none }

/-- A resource carrying no marker at all — someone else's. -/
def unmarked (cloud : ProviderId) (kind : Kind) (name : String) (region := "") : Resource :=
  { cloud, kind, name, region, evidence := .tags [] none }

abbrev Snapshot := List Resource

-- ── JSON ────────────────────────────────────────────────────────────────

private def evidenceJson : Evidence → Json
  | .tags ts at_ => Json.mkObj ([("tags", Json.mkObj (ts.map fun (k, v) => (k, Json.str v)))]
                      ++ (at_.map fun a => [("createdAt", Json.str a)]).getD [])
  | .named n at_ => Json.mkObj ([("named", Json.str n)]
                      ++ (at_.map fun a => [("createdAt", Json.str a)]).getD [])
  | .unreadable  => Json.str "unreadable"

private def evidenceOf (j : Json) : Except String Evidence := do
  if j == Json.str "unreadable" then return .unreadable
  let at_ : Option String := (j.getObjValAs? String "createdAt").toOption
  match j.getObjVal? "tags" with
  | .ok (.obj kvs) =>
    let ts ← kvs.toList.mapM fun (k, v) => do return (k, ← v.getStr?)
    return .tags ts at_
  | _ =>
    match j.getObjValAs? String "named" with
    | .ok n    => return .named n at_
    | .error _ => throw "evidence: expected \"unreadable\", {\"tags\": …} or {\"named\": …}"

instance : ToJson Resource where
  toJson r := Json.mkObj ([ ("slot", Json.str r.slot), ("cloud", Json.str r.cloud.name)
                          , ("kind", Json.str r.kind.name), ("name", Json.str r.name)
                          , ("region", Json.str r.region), ("evidence", evidenceJson r.evidence) ]
                          ++ (r.observed.map fun o => [("observed", o)]).getD [])

instance : FromJson Resource where
  fromJson? j := do
    let cloudName ← j.getObjValAs? String "cloud"
    let kindName ← j.getObjValAs? String "kind"
    let some cloud := providerOfName? cloudName | throw s!"unknown cloud '{cloudName}'"
    let some kind := kindOfName? kindName | throw s!"unknown kind '{kindName}'"
    return { cloud, kind
             name := ← j.getObjValAs? String "name"
             region := (j.getObjValAs? String "region").toOption.getD ""
             evidence := ← evidenceOf (← j.getObjVal? "evidence")
             observed := (j.getObjVal? "observed").toOption }

-- ── Replay ──────────────────────────────────────────────────────────────

/-- The observation a replayed `list` returns: the captured one if it
    decodes, a placeholder named after the resource otherwise. -/
private def observedOf (r : Resource) (k : Kind) : ObservedOf k :=
  match r.observed.map (fromJson? (α := ObservedOf k)) with
  | some (.ok o) => o
  | _            => placeholderObserved k r.name

/-- Whether a delete of slot `gone` removed resource `r`: the same physical
    thing, whichever kind it was deleted through — deleting a container as a
    `compute` removes its `scalewayContainer` listing too, as the cloud does
    (`Engine.physicalClass`). -/
private def removedBy (r : Resource) (gone : String) : Bool :=
  (Finite.elems (α := Kind)).any fun k =>
    physicalClass r.cloud k == physicalClass r.cloud r.kind && gone == slotId r.cloud k r.name

/-- The snapshot as backends, one per cloud, answering from the snapshot.

    `deleted` collects every slot `delete` is asked for, in order — the thing
    a test asserts on — and a deleted resource stops being listed under any
    kind that shows it, so a second pass sees the account as the first left
    it. `released`, if given, does the same for `release`: the resource then
    reports its tags without the marker. `create` and `update` answer like
    the placeholder. -/
def backends (snap : Snapshot) (deleted : IO.Ref (List String))
    (released : Option (IO.Ref (List String)) := none) : Backends where
  backend p :=
    { placeholderBackend p.name with
        list := fun k => do
          let gone ← deleted.get
          return (snap.filter fun r => r.cloud == p && r.kind == k
              && !gone.any (removedBy r)).map (observedOf · k)
        -- A released resource reports its tags without the marker, as the
        -- cloud would after `release`.
        ownershipInfo := fun k h => do
          let freed ← match released with
            | some ref => ref.get
            | none     => pure []
          let ev := (snap.find? fun r => r.cloud == p && r.kind == k && r.name == h.raw).map
            (·.evidence) |>.getD .unreadable
          return match ev with
            | .tags ts at' =>
              if freed.contains (slotId p k h.raw) then .tags (ts.filter (·.1 != markerKey)) at'
              else ev
            | _ => ev
        delete := fun k h => deleted.modify (· ++ [slotId p k h.raw])
        release := fun k h => match released with
          | some ref => ref.modify (· ++ [slotId p k h.raw])
          | none     => pure () }

/-- The snapshot inside a `dump` file (its `resources` array). -/
def ofDump (j : Json) : Except String Snapshot := do
  let rs ← j.getObjValAs? (Array Json) "resources"
  rs.toList.mapM fromJson?

/-- Read a `dump` file back as a snapshot, to replay a real account offline. -/
def load (path : System.FilePath) : IO Snapshot := do
  match Json.parse (← IO.FS.readFile path) >>= ofDump with
  | .ok snap => return snap
  | .error e => throw (IO.userError s!"{path}: {e}")

/-! ## Guards -/

private def sample : Snapshot :=
  [ marked .scaleway .secrets "db-url" "tn" "fr-par"
  , byName .scaleway .postgres "tn-db"
  , unmarked .aws .objectStore "theirs"
  , { cloud := .gcp, kind := .iam, name := "x", evidence := .unreadable } ]

-- JSON round-trips, evidence and all.
#guard match sample.mapM fun r => fromJson? (α := Resource) (toJson r) with
  | .ok back => back == sample
  | .error _ => false

end Infra.Providers.Snapshot
