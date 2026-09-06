import Infra.Core.Ledger

/-
  Whether a resource is ours.

  This is the question that decides whether deleting a line from a declaration
  destroys the resource or abandons it, and getting it wrong is expensive in
  both directions. It replaces an earlier answer that could not work.

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

    The value is the fleet's executable name, so a plan can at least *report*
    which fleet claims a resource even though it cannot use that to decide. -/
def markerKey : String := "managed-by-infra"

/-- Where a resource sits relative to this tool.

    Three states rather than two, because "not ours" has two causes that must
    not be conflated: something nobody told us about, and something we were
    explicitly told to leave alone. The second is a decision on the record and
    survives a `discover`; the first is just an absence. -/
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
    once by `discover` and then committed), so unlike the ledger it never has
    to be written back by a run. -/
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

/-- Whether the marker is present, given the tags a listing reported. -/
def markedBy (tags : List (String × String)) : Bool :=
  tags.any fun t => t.1 == markerKey

/-- The decision.

    Marker first, then exclusions, and the order is the safety property: the
    marker is the only thing that grants ownership, and an exclusion can only
    ever take it away. A resource missing from the exclusion list is therefore
    `foreign` rather than `managed`, which is the direction that leaves a
    stranger's resource alone.

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
  else if !markedBy tags then
    .foreign
  else
    match b.since, createdAt with
    | some cutoff, some made => if made < cutoff then .excluded else .managed
    | _,           _         => .managed

/-- Whether this tool may destroy the resource. The only caller that matters. -/
def Ownership.isOurs : Ownership → Bool
  | .managed => true
  | _        => false

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

/- Only `managed` is destroyable. -/
#guard Ownership.managed.isOurs = true
#guard Ownership.excluded.isOurs = false
#guard Ownership.foreign.isOurs = false

end Infra.Core
