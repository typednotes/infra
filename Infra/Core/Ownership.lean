import Infra.Core.Ledger

/-
  Whether a resource is ours.

  This is the question that decides whether deleting a line from a declaration
  destroys the resource or abandons it, and getting it wrong is expensive in
  both directions. It is the replacement for an earlier answer that could not
  work (see below). `Engine.push` calls `ownershipOf` from two places — the
  adoption loop, and the recheck immediately before a `deleteOrphan` runs —
  and `Infra.Providers.Live` writes the marker on create. The `#guard`s below
  pin the semantics this is meant to have, independent of which kinds are
  wired up.

  ## Where the marker is written, when tags are not available

  Not every cloud lets every kind carry tags, and a marker that cannot be
  written is a marker that cannot be read back. So a backend picks the
  strongest of three rungs for each `(cloud, kind)` it serves:

  1. **Tags.** Real key/value tags, which most kinds have. `Evidence.tags`.
  2. **A description.** No tags here, but one writable free-text field — GCP's
     service-account `description`, Scaleway's API-key `description`. The
     marker is serialised into it with `encodeMarkerText` and decoded back with
     `decodeMarkerText`, so what reaches this module is *also* `Evidence.tags`:
     the semantics are identical and only the bytes live somewhere else. This
     module deliberately cannot tell the two apart, which is what keeps the
     rule in one place.
  3. **The name, and nothing else.** Scaleway's Serverless SQL Database and its
     mnq queues offer no writable field at all beyond the name they were
     created with. `Evidence.named` says so, and ownership then rests on
     `Boundary.namePrefix`. Because infra never renames anything, that rung is
     a *check on what the declaration already says* rather than a marker this
     tool writes — which is weaker, and is why it is the last rung and why it
     is opt-in.

  `Evidence.unreadable` is not a rung: it means the backend could not find out,
  which is refused rather than guessed.

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

/-! ## The marker, written into a free-text field

  The second rung of the ladder in the module note. Two clouds have a kind
  with no tags and exactly one writable string on it, and `key=value` in that
  string is a marker in every sense that matters: this tool writes it, reads
  it back, and nothing else has a reason to produce it.

  The serialisation is deliberately the same one `Scaleway.encodeTag` uses for
  that cloud's flat `[]string` tags — same shape, same "first `=` splits key
  from the rest" rule — because it is the same problem: a key/value pair that
  has to travel inside a single string. It lives here rather than there
  because GCP needs it too and must not depend on the Scaleway client. -/

/-- The marker as one string, for a field that holds one string. -/
def encodeMarkerText (value : String) : String := markerKey ++ "=" ++ value

/-- Read a marker back out of such a field, as the tag list the rest of this
    module speaks in.

    A field holding something else entirely — a description a human wrote —
    decodes to a single tag whose key is that text and whose value is empty,
    which `markedBy` then correctly refuses. It is *not* dropped: a field that
    silently decoded to `[]` would read the same as a field this tool had
    never touched, and those two must stay distinguishable in a listing. -/
def decodeMarkerText (s : String) : List (String × String) :=
  if s.isEmpty then [] else
  match s.splitOn "=" with
  | k :: rest =>
    if rest.isEmpty then [(k, "")] else [(k, String.intercalate "=" rest)]
  | [] => [(s, "")]

/-- What a backend was able to find out about one resource's ownership.

    Four answers rather than `Option (tags × createdAt)`, because "this cloud
    cannot tag this kind, here is the only thing it can tell you" and "this
    backend could not find out" are different situations with different
    remedies, and collapsing them is what lets a permanent gap masquerade as
    an unfinished one. See the ladder in the module note.

    `createdAt` rides along on the two informative constructors so that
    `Boundary.since` applies to both rungs; it is ISO-8601 in UTC, or `none`
    where the provider does not report one. -/
inductive Evidence
  /-- Real tags, or a marker decoded out of a description — see
      `decodeMarkerText`. Indistinguishable here on purpose. -/
  | tags (tags : List (String × String)) (createdAt : Option String)
  /-- This `(cloud, kind)` has no writable marker field at all; the resource's
      own name is the whole of the evidence. `Boundary.namePrefix` decides. -/
  | named (name : String) (createdAt : Option String)
  /-- Nothing could be read: a kind no backend has been taught, or a call that
      failed. Never claimed and never destroyed on this answer. -/
  | unreadable
  deriving Repr, DecidableEq, BEq

/-- When the provider says the resource was created, where it says so. -/
def Evidence.createdAt : Evidence → Option String
  | .tags _ t   => t
  | .named _ t  => t
  | .unreadable => none

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
  /-- The prefix every resource of a kind that **cannot carry a marker** must
      be named with, for this fleet to claim it.

      The third rung of the ladder in the module note, and the only one where
      the evidence is something the *declaration* wrote rather than something
      this tool did. Two `(cloud, kind)` pairs need it today — Scaleway's
      Serverless SQL Database and its mnq queues — because neither has tags,
      labels, a description, or any other writable field to put a marker in.

      **Verified, never applied.** infra does not rename anything and does not
      add the prefix for you: a fleet key is the cloud-side name (see
      `Keys.name`), and rewriting it would break that identity everywhere. So
      this asks a question about the names already in the declaration, and
      `push` warns by name about every one that fails to answer it.

      `none` — the default — means there is no marker to check, so such a
      resource is `foreign`: never adopted, and never deleted as an orphan.
      That is exactly the behaviour these kinds had before this field existed,
      which is what keeps an existing fleet unchanged until it opts in.

      Weaker than a tag, and worth being plain about how. A tag is written by
      this tool at create; a prefix is written by whoever typed the name, so a
      stranger who happens to use the same prefix in the same project is
      indistinguishable from us. The realm check (`Infra.Cli.Accounts`) is
      what bounds that, exactly as it bounds `fleetName := none`. Prefer a
      prefix nobody would pick by accident — a fleet name, not `db-`. -/
  namePrefix : Option String := none

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

/-- The same question for a resource whose name is the only evidence there is.

    An **empty** prefix answers `false`, not `true`. It would otherwise match
    every name in the account, turning the weakest rung of the ladder into a
    blanket claim on everything — precisely the exclusion-shaped reasoning the
    module note explains fails dangerous. A fleet that wants to claim by name
    has to say which names. -/
def markedByName (prefix' : Option String) (name : String) : Bool :=
  match prefix' with
  | none   => false
  | some p => !p.isEmpty && name.startsWith p

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
    (e : Evidence) : Ownership :=
  if b.exclusions.any (fun x => x.cloud == cloud && x.kind == k && x.name == name) then
    .excluded
  else
    -- One line per rung of the ladder, and `unreadable` grants nothing. Which
    -- rung a `(cloud, kind)` is on is the backend's business, not this rule's.
    let claimed := match e with
      | .tags ts _  => markedBy b.fleetName ts
      | .named nm _ => markedByName b.namePrefix nm
      | .unreadable => false
    if !claimed then
      .foreign
    else
      match b.since, e.createdAt with
      | some cutoff, some made => if made < cutoff then .excluded else .managed
      | _,           _         => .managed

/-- Whether this tool may destroy the resource. The only caller that matters. -/
def Ownership.isOurs : Ownership → Bool
  | .managed => true
  | _        => false

/-- The verdict, as a warning line's worth of English — and, when it is not
    ours, which rung of the ladder said so.

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
    tool offers, and it has to name the fix.

    It takes the `Evidence` as well as the verdict because the three `foreign`
    cases call for three different actions — retag it, rename it, or teach the
    backend — and a single sentence covering all three would name none of
    them. -/
def describeVerdict (b : Boundary) (e : Evidence) : Ownership → String
  | .managed  => "managed"
  | .excluded => "excluded from management, by the boundary or a release"
  | .foreign  =>
    match e with
    | .tags _ _   => s!"not carrying the '{markerKey}' tag, so not ours"
    | .named nm _ =>
      match b.namePrefix with
      | some pre => s!"named '{nm}', which does not start with this fleet's \
`namePrefix` '{pre}' — and this cloud cannot tag this kind, so the name is the \
only marker there is"
      | none     => s!"of a kind this cloud cannot tag, and no `namePrefix` is \
set on this fleet's boundary, so there is no marker to check. Set one, and name \
this resource with it"
    | .unreadable => "of a kind whose marker this backend cannot read, so \
unverifiable"

/-! ## Guards

  The failure directions, pinned. These are the assertions to read first if the
  ownership rule is ever changed: each one names a mistake that would be
  expensive in production. -/

private def anyKind : Kind := .queues

/-- `Evidence.tags` with no creation time — what most of these assertions want
    to say, written once so the rung under test is the visible part. -/
private def tagged (ts : List (String × String)) : Evidence := .tags ts none

/- The marker grants ownership, and its absence withholds it. -/
#guard ownershipOf {} .aws anyKind "x" (tagged [(markerKey, "mine")]) = .managed
#guard ownershipOf {} .aws anyKind "x" (tagged []) = .foreign
#guard ownershipOf {} .aws anyKind "x" (tagged [("team", "infra")]) = .foreign

/- *The* safety property: something nobody mentioned is not ours. An empty
   boundary claims nothing, so a first run against a populated account proposes
   no deletions at all. -/
#guard ownershipOf {} .aws anyKind "someone-elses-bucket" (tagged []) = .foreign

/- ### The fleet's own name, in the value

   Unset, the value is not read at all — which is the behaviour that existed
   before the field, and is what keeps this change from touching any fleet that
   does not ask for it. -/
#guard ownershipOf {} .aws anyKind "x" (tagged [(markerKey, "some-other-fleet")]) = .managed

/- Set, a value that is not ours is `foreign`: the same verdict as no marker,
   and the same consequence — left alone. This is the isolation the field is
   for, and the direction it has to fail in. -/
#guard ownershipOf { fleetName := some "mine" }
         .aws anyKind "x" (tagged [(markerKey, "theirs")]) = .foreign
#guard ownershipOf { fleetName := some "mine" }
         .aws anyKind "x" (tagged [(markerKey, "mine")]) = .managed

/- The legacy value matches every fleet, permanently: naming a fleet must not
   turn an estate tagged before the name existed into somebody else's. This is
   the assertion to read if `legacyMarkerValue` is ever tempting to remove. -/
#guard ownershipOf { fleetName := some "mine" }
         .aws anyKind "x" (tagged [(markerKey, legacyMarkerValue)]) = .managed

/- And the value never *grants* what the key did not: a fleet's own name under
   some other key is not a marker. -/
#guard ownershipOf { fleetName := some "mine" }
         .aws anyKind "x" (tagged [("owner", "mine")]) = .foreign

/- An exclusion overrides the marker, not the other way round. This is what
   makes a released resource stay released even though this tool created it and
   tagged it. -/
#guard ownershipOf { exclusions := [⟨.aws, anyKind, "x", "released 2026-09-06"⟩] }
         .aws anyKind "x" (tagged [(markerKey, "mine")]) = .excluded

/- An exclusion is per cloud and per kind, not by name alone: two clouds can
   hold resources of the same name, and this example does. -/
#guard ownershipOf { exclusions := [⟨.aws, anyKind, "x", "why"⟩] }
         .scaleway anyKind "x" (tagged [(markerKey, "mine")]) = .managed

/- The cutoff ages out a marked resource older than adoption. -/
#guard ownershipOf { since := some "2026-09-01T00:00:00Z" }
         .aws anyKind "x" (.tags [(markerKey, "mine")] (some "2026-08-01T00:00:00Z")) = .excluded
#guard ownershipOf { since := some "2026-09-01T00:00:00Z" }
         .aws anyKind "x" (.tags [(markerKey, "mine")] (some "2026-09-15T00:00:00Z")) = .managed

/- An unknown creation time does not age anything out, and does not claim
   anything either: the marker decides alone. Guessing in either direction
   would be a silent wrong answer. -/
#guard ownershipOf { since := some "2026-09-01T00:00:00Z" }
         .aws anyKind "x" (tagged [(markerKey, "mine")]) = .managed
#guard ownershipOf { since := some "2026-09-01T00:00:00Z" }
         .aws anyKind "x" (tagged []) = .foreign

/- And the cutoff never promotes: an unmarked resource created yesterday is
   still not ours. The cutoff is a backstop on the marker, never a substitute
   for it, which is the difference between this and "assume everything new is
   mine". -/
#guard ownershipOf { since := some "2026-09-01T00:00:00Z" }
         .aws anyKind "x" (.tags [] (some "2026-09-15T00:00:00Z")) = .foreign

/-! ### The description rung

  A marker in a free-text field is the same marker, and these pin that: what
  `encodeMarkerText` writes, `decodeMarkerText` reads back as the very tag list
  the assertions above are written against. The two rungs are then
  indistinguishable to `ownershipOf`, which is the property that keeps the rule
  in one place. -/

#guard decodeMarkerText (encodeMarkerText "my-fleet") = [(markerKey, "my-fleet")]
#guard ownershipOf { fleetName := some "my-fleet" }
         .gcp .iam "sa" (tagged (decodeMarkerText (encodeMarkerText "my-fleet"))) = .managed
#guard ownershipOf { fleetName := some "my-fleet" }
         .gcp .iam "sa" (tagged (decodeMarkerText (encodeMarkerText "other-fleet"))) = .foreign

/- A description somebody wrote by hand is not a marker — and, importantly, it
   does not decode to `[]` either, so a listing can still tell "described by a
   human" from "never touched". -/
#guard decodeMarkerText "the CI deploy identity" = [("the CI deploy identity", "")]
#guard ownershipOf {} .gcp .iam "sa" (tagged (decodeMarkerText "the CI deploy identity"))
     = .foreign
#guard decodeMarkerText "" = []

/-! ### The name rung

  The weakest rung, and the one whose failure directions are worth the most
  care: this is the only evidence infra does not itself write. -/

/- With no prefix configured there is no marker to check, so nothing is ours.
   This is the pre-existing behaviour of every untaggable kind, now stated as a
   rule rather than left to the engine's `none` branch. -/
#guard ownershipOf {} .scaleway .postgres "secrets-db" (.named "secrets-db" none) = .foreign

/- With one configured, the prefix grants and its absence withholds — the same
   inclusion-marker shape as the tag rung. -/
#guard ownershipOf { namePrefix := some "typednotes-" }
         .scaleway .postgres "typednotes-secrets-db"
         (.named "typednotes-secrets-db" none) = .managed
#guard ownershipOf { namePrefix := some "typednotes-" }
         .scaleway .postgres "secrets-db" (.named "secrets-db" none) = .foreign

/- A prefix is a *prefix*, not a substring: a stranger's resource that merely
   contains the fleet's name somewhere is not ours. Matching anywhere in the
   string would claim `staging-typednotes-db`, which belongs to somebody else. -/
#guard ownershipOf { namePrefix := some "typednotes-" }
         .scaleway .postgres "staging-typednotes-db"
         (.named "staging-typednotes-db" none) = .foreign

/- An empty prefix claims nothing. It would otherwise match every name in the
   account — the one way this rung could turn into the exclusion-shaped rule
   the module note explains must never decide ownership. -/
#guard ownershipOf { namePrefix := some "" }
         .scaleway .postgres "anything" (.named "anything" none) = .foreign

/- The boundary's other two controls still apply on this rung. A prefix is
   evidence like any other, so an exclusion still overrides it and the `since`
   cutoff still ages it out; neither may be quietly tag-only. -/
#guard ownershipOf { namePrefix := some "tn-"
                     exclusions := [⟨.scaleway, .postgres, "tn-db", "released"⟩] }
         .scaleway .postgres "tn-db" (.named "tn-db" none) = .excluded
#guard ownershipOf { namePrefix := some "tn-", since := some "2026-09-01T00:00:00Z" }
         .scaleway .postgres "tn-db" (.named "tn-db" (some "2026-08-01T00:00:00Z")) = .excluded
#guard ownershipOf { namePrefix := some "tn-", since := some "2026-09-01T00:00:00Z" }
         .scaleway .postgres "tn-db" (.named "tn-db" (some "2026-09-15T00:00:00Z")) = .managed

/- The two rungs do not leak into one another. A prefix must not rescue a
   resource whose tags say it is somebody else's, and a marker tag must not
   rescue a name-only resource that is misnamed — otherwise the ladder would be
   a disjunction of weak tests rather than one test per kind. -/
#guard ownershipOf { fleetName := some "mine", namePrefix := some "mine-" }
         .aws anyKind "mine-x" (tagged [(markerKey, "theirs")]) = .foreign
#guard ownershipOf { fleetName := some "mine", namePrefix := some "mine-" }
         .scaleway .postgres "theirs-x" (.named "theirs-x" none) = .foreign

/-! ### Unreadable

  Not a rung: it grants nothing, whatever else is configured. A fleet that
  named itself and set a prefix still cannot claim a resource whose marker
  nobody could read — which is what stops "we could not check" from decaying
  into "assume yes" the moment a boundary is well configured. -/
#guard ownershipOf { fleetName := some "mine", namePrefix := some "" } .aws anyKind "x"
         .unreadable = .foreign
#guard ownershipOf { fleetName := some "mine", namePrefix := some "x" } .aws anyKind "x"
         .unreadable = .foreign
#guard Evidence.unreadable.createdAt = none

/-! ### The warnings

  Three `foreign` cases with three different remedies, so three different
  sentences. A reader who is told "not carrying the tag" about a resource on a
  cloud that cannot tag it has been sent to fix the wrong thing. -/

private def b0 : Boundary := {}
private def bPre : Boundary := { namePrefix := some "tn-" }

#guard describeVerdict b0 (tagged []) .foreign
     != describeVerdict b0 (.named "x" none) .foreign
#guard describeVerdict b0 (.named "x" none) .foreign
     != describeVerdict bPre (.named "x" none) .foreign
#guard describeVerdict b0 .unreadable .foreign != describeVerdict b0 (tagged []) .foreign

/- The two unowned verdicts must not read the same: "nobody told us about
   this" and "we were told to leave it alone" call for different actions from
   whoever reads the warning. -/
#guard describeVerdict b0 (tagged []) .foreign != describeVerdict b0 (tagged []) .excluded

/- Only `managed` is destroyable. -/
#guard Ownership.managed.isOurs = true
#guard Ownership.excluded.isOurs = false
#guard Ownership.foreign.isOurs = false

end Infra.Core
