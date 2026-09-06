import Infra.Core.Kind
import Infra.Core.Finite
import Lean.Data.Json

/-
  What this fleet manages, as opposed to what it last saw.

  The ledger answers one question — *is this resource mine?* — and it is the
  only thing that can answer it, because the key family cannot. A `CachedEntry`
  is indexed by `κ.Key p k`, so it structurally cannot hold a row for a
  resource the current declaration no longer mentions, and that is precisely
  the row that has to survive for "deleted from the file" to mean "destroy".

  So a row here is a plain record, deliberately *outside* the key family. It is
  the one place in this library where not using a dependent index is the point:
  the ledger has to be able to name something the types no longer can.

  ## Not committed, and not the authority

  This file was briefly committed next to the declaration, on the reasoning
  that what a fleet manages is intent. That was wrong: a row appears because a
  resource *was created*, which is an event at apply time on whatever machine
  ran the apply, so the file needed writing back from CI to the branch it came
  from. `Infra.Core.Ownership` explains the failure and holds the replacement.

  So this is now a local record under the cache root, disposable like the rest
  of it, and it is what drives the destroy path: deleting a resource needs a
  name and a region, and this is where they are.

  It is also, today, the *only* thing consulted — `Action.actionsOrphaned` asks
  it and nothing else. `Infra.Core.Ownership` holds the marker-and-boundary
  model that is meant to replace it as the authority, but nothing writes the
  marker and nothing reads the boundary yet, so it decides nothing. Until it
  does, a lost ledger means an orphan, not a `discover`.
-/

namespace Infra.Core.Ledger

open Lean (Json ToJson FromJson toJson fromJson?)

/-- One managed resource.

    `region` is not decoration. Placement comes from the declaration
    (`myFleet.regions`), so once a resource's line is deleted there is nothing
    left to say where it lives, and `Backends.backendFor` needs that to route
    the delete. A row without a region is undeletable in a multi-region fleet.

    Nothing provider-computed is stored: `Backend.delete` takes a `Handle k`,
    which wraps a `String`, so these four fields are the whole destroy path. -/
structure Row where
  /-- Named `cloud`, not `provider`, for the same reason `Declare.Res` is:
      `provider` is a parser token of the `fleet` command, so a file that
      imports it cannot use that word as a field name. The *JSON* key stays
      `"provider"` — the on-disk format should not be shaped by a Lean
      tokenisation detail. -/
  cloud    : ProviderId
  kind     : Kind
  name     : String
  region   : String
  deriving Repr, DecidableEq, BEq

/-- A stable identifier for a resource slot. A string, so steps of different
    kinds can share one list — the dependent key cannot.

    Lives here rather than in `Engine` because a ledger row has to print the
    same string an action does, and this is the lower of the two modules. It
    used to be spelled twice, with a doc comment asserting the two matched and
    nothing enforcing it — change the separator and a plan line would silently
    stop matching a ledger line. -/
def slotId (p : ProviderId) (k : Kind) (name : String) : String :=
  s!"{p.name}/{k.name}/{name}"

/-- Where a row lives, as the engine addresses everything else. -/
def Row.slot (r : Row) : String := slotId r.cloud r.kind r.name

/-- The address half of a row, which is what identity means here.

    The derived `BEq` on `Row` compares the region too, so it answers the wrong
    question: two rows for the same resource recorded from different placements
    are the same resource. This was respelled inline as
    `r.cloud == p && r.kind == k && r.name == nm` at four sites. -/
def Row.isAt (r : Row) (p : ProviderId) (k : Kind) (name : String) : Bool :=
  r.cloud == p && r.kind == k && r.name == name

/-! ## Names, parsed back from the same table that writes them

  Derived from `Finite` plus `.name` rather than written out a second time, for
  the reason `knownRegions` is derived from the locality table: two spellings of
  one fact drift. -/

def providerOfName? (s : String) : Option ProviderId :=
  (Finite.elems (α := ProviderId)).find? fun p => p.name == s

def kindOfName? (s : String) : Option Kind :=
  (Finite.elems (α := Kind)).find? fun k => k.name == s

instance : ToJson Row where
  toJson r := Json.mkObj
    [ ("provider", Json.str r.cloud.name)
    , ("kind",     Json.str r.kind.name)
    , ("name",     Json.str r.name)
    , ("region",   Json.str r.region) ]

instance : FromJson Row where
  fromJson? j := do
    let get (f : String) : Except String String := do
      match j.getObjValAs? String f with
      | .ok v    => pure v
      | .error e => throw s!"field '{f}': {e}"
    let p ← get "provider"
    let k ← get "kind"
    let nm ← get "name"
    let rg ← get "region"
    match providerOfName? p, kindOfName? k with
    | some pid, some kid => pure { cloud := pid, kind := kid, name := nm, region := rg }
    | none,     _        => throw s!"unknown provider '{p}'"
    | _,        none     => throw s!"unknown kind '{k}'"

/-- Rows in a stable order: by cloud, then kind, then name.

    The ledger is committed, so its diff is read by humans. An unstable order
    would make every apply touch every line. -/
def sorted (rows : List Row) : List Row :=
  rows.mergeSort fun a b => compare (a.slot) (b.slot) != .gt

/-- The current format version, written into the file.

    Present from the first release so that a later shape change has something
    to branch on. A file without it is a file this tool did not write. -/
def formatVersion : Nat := 1

def path (root : System.FilePath) : System.FilePath := root / "infra.ledger.json"

/-- Pretty-printed and sorted, because this file is committed and reviewed.

    An empty ledger writes an empty `rows` array rather than deleting the file.
    The cache does the opposite — see `Persistence.save`, where an emptied pair
    removes its file — and the difference is deliberate: a missing cache means
    "not pulled yet", whereas a missing ledger would mean "manages nothing",
    which is indistinguishable from "someone deleted the ledger". Keeping the
    file makes an empty ledger an explicit, reviewable state. -/
def save (root : System.FilePath) (rows : List Row) : IO Unit := do
  let body := Json.mkObj
    [ ("version", toJson formatVersion)
    , ("rows",    Json.arr ((sorted rows).map toJson).toArray) ]
  let p := path root
  if let some dir := p.parent then
    IO.FS.createDirAll dir
  IO.FS.writeFile p (body.pretty ++ "\n")

/-- A missing file means "manages nothing yet", which is the state before the
    first apply, and is not an error. Anything else that fails to parse *is* an
    error: this file decides what gets destroyed, so guessing is not an option
    and a corrupt ledger must stop the run rather than read as empty. -/
def load (root : System.FilePath) : IO (List Row) := do
  let p := path root
  if !(← p.pathExists) then
    return []
  let contents ← IO.FS.readFile p
  let fail {α : Type} (msg : String) : IO α := throw (IO.userError s!"{p}: {msg}")
  let orFail {α : Type} (what : String) : Except String α → IO α
    | .ok a    => pure a
    | .error e => fail s!"{what}: {e}"
  let json ← orFail "not valid JSON" (Json.parse contents)
  let version ← match json.getObjValAs? Nat "version" with
    | .ok v    => pure v
    | .error _ => fail "no 'version' field: this is not a file infra wrote"
  if version != formatVersion then
    fail s!"format version {version}, but this build understands {formatVersion}"
  let rows ← orFail "field 'rows'" (json.getObjValAs? (Array Json) "rows")
  -- Not re-sorted: `save` is the only writer and it sorts. Sorting on read as
  -- well would hide a file whose order had been hand-edited, which is exactly
  -- the thing a reviewer of a diff would want to see.
  rows.toList.mapM fun r => orFail "bad row" (fromJson? (α := Row) r)

end Infra.Core.Ledger
