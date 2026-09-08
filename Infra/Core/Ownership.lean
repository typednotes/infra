import Infra.Core.Ledger

/-
  Whether a resource is ours.

  This is the question that decides whether deleting a line from a declaration
  destroys the resource or abandons it, and getting it wrong is expensive in
  both directions. It is the replacement for an earlier answer that could not
  work (see below). `Engine.push` calls `ownershipOf` from two places — the
  adoption loop, and the recheck immediately before a `deleteOrphan` runs —
  for every `(cloud, kind)` whose backend can report a resource's tags
  (`Backend.ownershipInfo`); `Infra.Providers.Live` writes the marker on
  create for those same kinds. A kind not yet taught to report tags still
  falls back to the ledger alone, unchanged from before this module existed.
  The `#guard`s below pin the semantics this is meant to have, independent of
  which kinds are wired up.

  ## Why not a committed ledger

  The first attempt recorded membership in a file committed next to the
  declaration, on the reasoning that what a fleet manages is *intent* and
  intent belongs in version control. That reasoning was wrong, and CI is where
  it shows: a row appears because a resource **was created**, which is an event
  at apply time on whatever machine ran the apply. Intent is what you wrote in
  the declaration; membership is a consequence of applying it. So the file
  needed writing back from CI to the branch it was applied from — needing push
  permissions, racing with concurrent merges, and looping unless guarded.
  Terraform keeps state remote rather than committed for exactly this reason.

  ## The three answers, and which way each fails

  Membership is instead *derived*, from three things a human authors and none of
  which a run has to write back:

  1. **The realm** — a hard container per cloud, checked before anything is
     touched (`Infra.Cli.Accounts`). Nothing outside it is ever a candidate.
  2. **The marker** — a tag this tool puts on what it creates. Present means
     ours.
  3. **The exclusions** — a snapshot of what already existed when management
     started, plus anything since released. Never ours, whatever else says.

  The ordering of 2 and 3 is the safety property, and it is worth being explicit
  about why it is that way round rather than the other:

  - Deciding membership by an **inclusion** marker fails *safe*. A resource
    with no marker is not ours and is left alone. The cost of losing a marker
    is an orphan: something keeps running and we stop tracking it.
  - Deciding it by **exclusion** alone fails *dangerous*. A resource missing
    from the exclusion list is assumed ours and destroyed. The cost of an
    incomplete list is deleting a stranger's resource.

  So the marker is what grants ownership and the exclusion list only ever takes
  it away. An exclusion list is not consulted to *find* what is ours, which is
  what keeps a missing entry from being catastrophic.
-/

namespace Infra.Core

/-- The tag this tool puts on everything it creates, and the only positive
    evidence that a resource is ours.

    A constant rather than something a fleet configures. Two fleets in one
    account would then be indistinguishable, which is a real limitation and the
    reason the realm is checked first: two fleets sharing an account is not a
    supported arrangement, and `Accounts` is what refuses it. Making the key
    configurable would look like it solved that, and would not.

    The **key** is constant; the **value** is where a fleet writes its own
    name (`Boundary.fleetName`), and that is the split rather than the other way
    round for one reason worth keeping: a constant key is what makes "what did
    this tool create in this account?" answerable at all, which is the question
    `Infra.Cli.discover` and any audit of the account rests on. A configurable
    key would take that away, and a key with a typo in it would leave an entire
    estate looking like it belonged to nobody. -/
def markerKey : String := "managed-by-infra"

/-- The value the marker carried before a fleet could name itself, and the
    value written by any fleet that still does not.

    It is **grandfathered**: a resource tagged with it matches every fleet, so
    naming a fleet cannot orphan an estate that was tagged before the name
    existed. Without that, setting `Boundary.fleetName` on an existing fleet would
    turn every resource it already manages `foreign` in one step — a fleet that
    warns about its whole estate and refuses to destroy any of it.

    The grandfathering is permanent rather than a migration window, because
    there is nothing to migrate *to* on a schedule: a resource is retagged when
    it is next updated, and a resource nobody updates would otherwise become
    unmanageable for having been created early. -/
def legacyMarkerValue : String := "true"

/-- Where a resource sits relative to this tool.

    Three states rather than two, because "not ours" has two causes that must
    not be conflated: something nobody told us about, and something we were
    explicitly told to leave alone. The second is a decision on the record and
    would survive a sweep of the account for the marker; the first is just an
    absence. -/
inductive Ownership
  /-- Carries the marker, and is not excluded. Deleting its line destroys it. -/
  | managed
  /-- Named in the exclusion snapshot. Never touched, marker or no marker. -/
  | excluded
  /-- No marker. Not ours, and nothing here will touch it. -/
  | foreign
  deriving Repr, DecidableEq, BEq

/-- One resource this tool must never touch.

    Same shape as a ledger row minus the region, which is only needed to route
    a delete, and nothing here is ever deleted. Authored by a human (or written
    once by a sweep of the account and then committed), so unlike the ledger it
    never has to be written back by a run. -/
structure Exclusion where
  cloud : ProviderId
  kind  : Kind
  name  : String
  /-- Why, in one line. Free text, and required rather than optional: an
      exclusion is a standing instruction that outlives whoever added it, and
      "why is this here" is the question its next reader will have. -/
  why   : String
  deriving Repr, DecidableEq, BEq

/-- What a declaration says about the boundary, as opposed to about resources.

    `since` is the creation-date cutoff: anything older is treated as
    pre-existing even if it somehow carries the marker. It is a coarse
    backstop for the case the marker cannot cover, namely a resource created
    before this tool was adopted whose tags someone later copied from a managed
    one. `none` means no cutoff. -/
structure Boundary where
  exclusions : List Exclusion := []
  since      : Option String := none
  /-- This fleet's own name, written into the marker's value and required back
      out of it.

      **Named `fleetName` rather than `fleet`** for the reason `Ledger.Row`'s
      first field is `cloud` rather than `provider`: `fleet` is a parser token
      of the `fleet` command, so a file that imports the DSL — which is every
      file that declares one — cannot write `{ fleet := … }`. The field
      compiles fine here, where the DSL is not imported, and fails in exactly
      the place a user would write it. Third instance of this trap; the rule is
      that a field a declaration author types must not be spelled like a
      command keyword.

      `none` — the default — is exactly the behaviour that existed before this
      field: the marker's presence decides and its value is not read, so one
      account holding two fleets has them claiming each other's resources by
      name, which is why `Accounts` refuses that arrangement in the first
      place. Naming the fleet is what makes the arrangement *safe* rather than
      merely refused: a resource marked `some other-fleet` reads as `foreign`,
      and foreign resources are left alone.

      Two things it is honest to say about it. It is **opt-in on both sides**:
      a fleet that names itself is protected from one that does not, but not
      the reverse — the unnamed fleet still accepts any value it finds, so
      isolation between two fleets needs both of them to set this. And it is
      one string, not an identity: nothing stops a second fleet writing the
      same name, so this separates *fleets that agree to be separate*. The
      realm (`Infra.Cli.Accounts`) is still the hard container. -/
  fleetName  : Option String := none

/-- Whether the marker is present *and* claimed by this fleet, given the tags
    a listing reported.

    Three cases, and the middle one is the whole point of the value:

    - no `markerKey` at all: not ours, whoever we are.
    - `markerKey` with `legacyMarkerValue`: ours, whatever fleet asks. See
      that constant for why.
    - `markerKey` with anything else: ours only if the fleet did not name
      itself, or named itself this. -/
def markedBy (fleet : Option String) (tags : List (String × String)) : Bool :=
  tags.any fun t =>
    t.1 == markerKey &&
      (match fleet with
       | none    => true
       | some me => t.2 == me || t.2 == legacyMarkerValue)

/-- The decision.

    Marker first, then exclusions, and the order is the safety property: the
    marker is the only thing that grants ownership, and an exclusion can only
    ever take it away. A resource missing from the exclusion list is therefore
    `foreign` rather than `managed`, which is the direction that leaves a
    stranger's resource alone.

    "The marker" now means key *and*, where a fleet has named itself, value —
    see `markedBy`. A resource carrying another fleet's name fails in the same
    direction as one carrying no marker at all: `foreign`, and left alone.

    `createdAt` is compared as a string because every provider reports it as
    ISO-8601 in UTC, and ISO-8601 in UTC sorts lexicographically. A resource
    whose creation time is unknown is *not* aged out: `none` means the provider
    did not say, and guessing "old" would silently exclude, while guessing
    "new" would silently claim. Neither is acceptable, so the cutoff simply
    does not apply and the marker decides. -/
def ownershipOf (b : Boundary) (cloud : ProviderId) (k : Kind) (name : String)
    (tags : List (String × String)) (createdAt : Option String) : Ownership :=
  if b.exclusions.any (fun e => e.cloud == cloud && e.kind == k && e.name == name) then
    .excluded
  else if !markedBy b.fleetName tags then
    .foreign
  else
    match b.since, createdAt with
    | some cutoff, some made => if made < cutoff then .excluded else .managed
    | _,           _         => .managed

/-- Whether this tool may destroy the resource. The only caller that matters. -/
def Ownership.isOurs : Ownership → Bool
  | .managed => true
  | _        => false

/-- The verdict, as a warning line's worth of English.

    There is one place this is needed and it is the case that used to be
    silent: a declaration names a resource, the resource exists, and it is not
    ours. Nothing then happens to it — no create, because it exists; no
    update, because a plan only touches what it manages; no destroy, ever.
    A fleet in that state manages less than it declares and, before this,
    said nothing at all about it.

    Which is a worse failure than it looks. The resource is unreachable by
    every path: `push` will not adopt it, `destroy` only knows the ledger, and
    `discover` re-derives from the same marker and reaches the same verdict.
    Only a name-based sweep can see it. So the warning is the whole remedy the
    tool offers, and it has to name the fix. -/
def Ownership.describe : Ownership → String
  | .managed  => "managed"
  | .excluded => "excluded from management, by the boundary or a release"
  | .foreign  => s!"not carrying the '{markerKey}' tag, so not ours"

/-! ## Guards

  The failure directions, pinned. These are the assertions to read first if the
  ownership rule is ever changed: each one names a mistake that would be
  expensive in production. -/

private def anyKind : Kind := .queues

/- The marker grants ownership, and its absence withholds it. -/
#guard ownershipOf {} .aws anyKind "x" [(markerKey, "mine")] none = .managed
#guard ownershipOf {} .aws anyKind "x" [] none = .foreign
#guard ownershipOf {} .aws anyKind "x" [("team", "infra")] none = .foreign

/- *The* safety property: something nobody mentioned is not ours. An empty
   boundary claims nothing, so a first run against a populated account proposes
   no deletions at all. -/
#guard ownershipOf {} .aws anyKind "someone-elses-bucket" [] none = .foreign

/- ### The fleet's own name, in the value

   Unset, the value is not read at all — which is the behaviour that existed
   before the field, and is what keeps this change from touching any fleet that
   does not ask for it. -/
#guard ownershipOf {} .aws anyKind "x" [(markerKey, "some-other-fleet")] none = .managed

/- Set, a value that is not ours is `foreign`: the same verdict as no marker,
   and the same consequence — left alone. This is the isolation the field is
   for, and the direction it has to fail in. -/
#guard ownershipOf { fleetName := some "mine" }
         .aws anyKind "x" [(markerKey, "theirs")] none = .foreign
#guard ownershipOf { fleetName := some "mine" }
         .aws anyKind "x" [(markerKey, "mine")] none = .managed

/- The legacy value matches every fleet, permanently: naming a fleet must not
   turn an estate tagged before the name existed into somebody else's. This is
   the assertion to read if `legacyMarkerValue` is ever tempting to remove. -/
#guard ownershipOf { fleetName := some "mine" }
         .aws anyKind "x" [(markerKey, legacyMarkerValue)] none = .managed

/- And the value never *grants* what the key did not: a fleet's own name under
   some other key is not a marker. -/
#guard ownershipOf { fleetName := some "mine" }
         .aws anyKind "x" [("owner", "mine")] none = .foreign

/- An exclusion overrides the marker, not the other way round. This is what
   makes a released resource stay released even though this tool created it and
   tagged it. -/
#guard ownershipOf { exclusions := [⟨.aws, anyKind, "x", "released 2026-09-06"⟩] }
         .aws anyKind "x" [(markerKey, "mine")] none = .excluded

/- An exclusion is per cloud and per kind, not by name alone: two clouds can
   hold resources of the same name, and this example does. -/
#guard ownershipOf { exclusions := [⟨.aws, anyKind, "x", "why"⟩] }
         .scaleway anyKind "x" [(markerKey, "mine")] none = .managed

/- The cutoff ages out a marked resource older than adoption. -/
#guard ownershipOf { since := some "2026-09-01T00:00:00Z" }
         .aws anyKind "x" [(markerKey, "mine")] (some "2026-08-01T00:00:00Z") = .excluded
#guard ownershipOf { since := some "2026-09-01T00:00:00Z" }
         .aws anyKind "x" [(markerKey, "mine")] (some "2026-09-15T00:00:00Z") = .managed

/- An unknown creation time does not age anything out, and does not claim
   anything either: the marker decides alone. Guessing in either direction
   would be a silent wrong answer. -/
#guard ownershipOf { since := some "2026-09-01T00:00:00Z" }
         .aws anyKind "x" [(markerKey, "mine")] none = .managed
#guard ownershipOf { since := some "2026-09-01T00:00:00Z" }
         .aws anyKind "x" [] none = .foreign

/- And the cutoff never promotes: an unmarked resource created yesterday is
   still not ours. The cutoff is a backstop on the marker, never a substitute
   for it, which is the difference between this and "assume everything new is
   mine". -/
#guard ownershipOf { since := some "2026-09-01T00:00:00Z" }
         .aws anyKind "x" [] (some "2026-09-15T00:00:00Z") = .foreign

/- The two unowned verdicts must not read the same: "nobody told us about
   this" and "we were told to leave it alone" call for different actions from
   whoever reads the warning. -/
#guard Ownership.foreign.describe != Ownership.excluded.describe

/- Only `managed` is destroyable. -/
#guard Ownership.managed.isOurs = true
#guard Ownership.excluded.isOurs = false
#guard Ownership.foreign.isOurs = false

end Infra.Core
