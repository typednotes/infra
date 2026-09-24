import Infra.Core.Backend
import Infra.Core.Ansi

/-
  The sync loop: observe the world, work out what has to change, and — when
  told to — change it.
-/

namespace Infra.Core

-- ══════════════════════════════════════════════════════════════
-- Pull
-- ══════════════════════════════════════════════════════════════

/-- Ask every backend to list every kind, and match what comes back to fleet
    keys by `Keys.name`.

    **Existence comes from `list`, configuration from `read`, and the split is
    not incidental.** A per-resource "does this exist" probe was tried and
    removed: it has to be answered by the provider layer, and several
    `(provider, kind)` pairs there cannot answer it — `liveRead`'s `.secrets`
    clause makes no cloud call at all, and every not-yet-live pair reports
    `unknown` fields *successfully*. Reading that as "it exists" meant a
    declared secret was never created. `list` can be wrong only by omission,
    which is the safe direction, and it is the call this repo has actually
    exercised against real accounts for all fourteen kinds.

    This answers only "what does the declaration's name point at right now".
    Which resources this fleet *manages* is a different question, answered by
    their markers: `claimUndeclared` for the ones the declaration no longer
    names, `foreignDeclared` for the declared names held by something else. -/
def pullEntries {κ : Keys} (bs : Backends) : IO (List (Entry κ)) := do
  let mut acc : List (Entry κ) := []
  for p in Finite.elems (α := ProviderId) do
    for k in Finite.elems (α := Kind) do
      -- Bound once: `Finite.elems` on a built key family allocates a fresh
      -- list on each evaluation.
      let keys := Finite.elems (α := κ.Key p k)
      -- A pair with no keys cannot be claimed by this fleet, so listing it
      -- could only produce rows that are immediately dropped. Skipping it is
      -- not just an optimisation: it is what lets an all-Scaleway fleet run
      -- without ever calling AWS, and so without AWS credentials.
      if keys.isEmpty then
        continue
      -- One listing per region this bucket's resources live in. Each is
      -- matched only against the slots placed in *that* region: see
      -- `Backends.listers` for why the pairing is not optional.
      for (b, here) in bs.listers p k do
        let observed ← b.list k
        for key in keys do
          let nm := κ.name p k key
          if here nm then
            match observed.find? (fun o => (observedHandle k o).raw == nm) with
            | some o =>
              -- Only now, for a key the fleet actually claims, is the extra
              -- per-resource read worth paying for.
              --
              -- A resource can disappear between the listing and this read,
              -- and it is not an exotic case: every cloud's list API is
              -- eventually consistent, so a `plan` moments after a delete
              -- sees the deleted thing in the listing and then fails to read
              -- it. Treating that as "absent" is the truthful reading — it
              -- *is* absent — and the alternative was an aborted pull.
              match ← (b.read k (observedHandle k o)).toBaseIO with
              | .ok reported => acc := ⟨p, k, key, { observed := o, reported }⟩ :: acc
              | .error e =>
                unless readsAsAbsent (toString e) do throw e
            | none   => pure ()
  return acc

/-- Observe the world. Nothing is written anywhere: see `Infra.Cli`'s `dump`
    for a snapshot on disk. -/
def pull {κ : Keys} (bs : Backends) : IO (World κ) :=
  worldOf <$> pullEntries bs

/-- What would have to change for the world to realise the target. Pure: it
    decides, it does not act. -/
def plan {κ : Keys} (T : Plan κ) (W : World κ) (orphans : List Orphan := [])
    (releases : List Orphan := []) : List (Action κ) := actions T W orphans releases

/-! ## Which physical thing a listing shows

  Two kinds can list the same physical resources: an S3 bucket is both an
  `objectStore` and an `s3Bucket`, and a Scaleway Serverless Container is both
  a `compute` and a `scalewayContainer`. Anything that decides a resource is
  *undeclared* has to ask about the physical thing, not the `(kind, name)`
  pair — otherwise a container declared as `scalewayContainer` shows up,
  undeclared, under `compute`, and is destroyed. Checked against each
  backend's `list` (2026-09-23): these are the only overlaps. -/

/-- The physical class a `(cloud, kind)` listing shows: equal for two kinds
    that list the same resources, distinct otherwise. -/
def physicalClass (p : ProviderId) : Kind → String
  | .objectStore | .s3Bucket => "bucket"
  | .compute => if p == .scaleway then "container" else "compute"
  | .scalewayContainer => "container"
  | k => k.name

#guard physicalClass .scaleway .compute == physicalClass .scaleway .scalewayContainer
#guard physicalClass .aws .objectStore == physicalClass .aws .s3Bucket
#guard physicalClass .aws .compute != physicalClass .aws .scalewayContainer
#guard physicalClass .scaleway .scalewayContainer != physicalClass .scaleway .scalewayContainerNamespace

/-- Whether a kind has anything on cloud `p` for `claimUndeclared` to find.

    Not a list of exemptions — the two facts that make a `(cloud, kind)` pair
    empty by construction:

    * a provider-local kind exists only on its own cloud;
    * `postgresMigrations` is rows in a database, not a cloud object: its
      listing can only name declared histories, and its delete is a FORGET
      that touches nothing.

    Every other pair is listed, including kinds the declaration no longer has
    anything of — which is where the last resource of a kind, just removed,
    has to be found. -/
def scannableUndeclared (p : ProviderId) : Kind → Bool
  | .postgresMigrations => false
  | .s3Bucket | .securityGroup | .awsInstance => p == .aws
  | .scalewayFunctionNamespace | .scalewayFunction
  | .scalewayContainerNamespace | .scalewayContainer => p == .scaleway
  | _ => true

/-- Whether the declaration names physical resource `nm` of class `cls` on
    `p` — under any kind of that class, and whatever it asks for it
    (`present`, `absent`, or `unmanaged`, which is "not my business"). -/
def declaredPhysically (κ : Keys) (p : ProviderId) (cls name : String) : Bool :=
  (Finite.elems (α := Kind)).any fun k =>
    physicalClass p k == cls &&
      (Finite.elems (α := κ.Key p k)).any fun key => κ.name p k key == name

/-- What discovery found: the undeclared resources this fleet owns, and the
    warnings for what it saw but may not claim. -/
structure Discovered where
  orphans  : List Orphan := []
  /-- Resources the declaration `forget`s that still carry this fleet's
      marker on a rung that can be rewritten: apply removes it
      (`Action.release`), and the `forget` line can then go. -/
  releases : List Orphan := []
  warnings : List String := []

/-- Whether the evidence is a tag set carrying the retired marker value. -/
def carriesRetiredMarker : Evidence → Bool
  | .tags ts _ => ts.any fun t => t.1 == markerKey && t.2 == retiredMarkerValue
  | _          => false

/-- The warning for an undeclared resource carrying the retired marker value:
    it is left alone, and this says what to do. (A *declared* one is reported
    by `foreignDeclared`, through `describeVerdict`.) -/
def retiredMarkerWarning (boundary : Boundary) (slot : String) : String :=
  let me := boundary.fleetName.getD "<this fleet's name>"
  let fix := s!"if it is this fleet's, retag it '{markerKey}={me}' and the next apply \
destroys it, or delete it by hand; otherwise leave it"
  s!"warning: {slot} is not declared and carries '{markerKey}={retiredMarkerValue}', the marker fleets without a \
name wrote before infra 0.17.0. It matches no fleet now, so it is left alone: {fix}."

/-- The warning for an undeclared resource whose marker the cloud refused to
    show (`readsAsRefused`): it is treated as not this fleet's and left alone.

    **An unreadable resource is not managed.** Rule 3 already forbids changing
    or destroying anything without a readable marker naming this fleet, so a
    refused read could never lead to a claim; failing the run over it only
    blocked every other change. And the refusal is evidence in itself: infra
    writes no bucket policy or other per-resource access rule, so a resource
    that shuts this fleet's credentials out was put out of its reach by
    somebody else. (The case that forced it: a hand-managed Scaleway bucket
    whose bucket policy named only a user and a deleted application, which
    failed every CI plan of the fleet next to it.)

    Narrow on purpose. Only an **undeclared** resource, only **after its
    listing succeeded**, and only an **access-denied** answer
    (`readsAsRefused`): a refused listing still fails the run — it would
    otherwise turn one missing permission into a whole kind never cleaned up —
    as does a declared resource that cannot be read, and any other error.

    Said out loud, because it is the one place two machines can disagree: if
    such a resource did carry this fleet's marker, credentials that can read it
    would destroy it and credentials that cannot would leave it. -/
def refusedMarkerWarning (boundary : Boundary) (slot : String) (forgotten : Bool) : String :=
  let me := boundary.fleetName.getD "<this fleet's name>"
  let tail := if forgotten then
      " It is forgotten (`forget`), and whether it still carries the marker is unknown, \
so keep its `forget` line until it can be read."
    else
      s!" If it is this fleet's ('{markerKey}={me}'), grant these credentials read access \
to it and the next apply destroys it, since it is no longer declared."
  s!"warning: {slot} is not declared, and the cloud refused to show its ownership \
marker to these credentials, so it is treated as not this fleet's and left alone.{tail}"

/-- **Every resource marked as this fleet's that the declaration does not name,
    found by asking the cloud.**

    This is what makes deleting a line destroy the resource, on any machine:
    there is no local record of what a fleet manages, only the markers on the
    resources themselves (`claimsUndeclared`) — a tag or description carrying
    this fleet's name, or the name prefix for the kinds that carry nothing.

    Scope: every region the fleet uses on every cloud it uses (`scanners`),
    and every kind `scannableUndeclared` allows there, plus every kind the
    declaration names. A resource named in a `forget`, or declared under any
    kind of its physical class, is not an orphan and is skipped. One orphan per
    physical resource, however many kinds list it.

    A resource carrying the retired marker value (`retiredMarkerValue`,
    written by fleets without a name before 0.17.0) is not claimed — it
    belongs to no fleet any more — and is warned about by name, because it is
    most likely this fleet's own and waiting to be retagged.

    A resource whose marker the cloud refuses to show these credentials
    (`readsAsRefused`, after the listing that found it succeeded) is not
    claimed either, and is warned about by name (`refusedMarkerWarning`): what
    infra may not read, it does not manage. A refused *listing*, or any other
    failure to read a marker, still fails the run. -/
def claimUndeclared {κ : Keys} (bs : Backends) (boundary : Boundary)
    (forgets : List (Released κ)) : IO Discovered := do
  let mut found : List (String × Orphan) := []   -- (physical class, orphan)
  let mut releases : List (String × Orphan) := []
  let mut warnings : List String := []
  let mut refused : List (ProviderId × String × String) := []   -- (cloud, class, name), warned once
  -- Every cloud the backends can scan — not only the declared ones. Which
  -- clouds those are is the front end's decision (`Infra.Cli.liveFor` loads
  -- the declared clouds and the ones `Accounts` names, and gives any other
  -- cloud no scanners), so a cloud whose last line was just removed is still
  -- asked for what it left behind.
  for p in Finite.elems (α := ProviderId) do
    for (code, b) in bs.scanners p do
      for k in Finite.elems (α := Kind) do
        let declaresKind := !(Finite.elems (α := κ.Key p k)).isEmpty
        unless k != .postgresMigrations && (declaresKind || scannableUndeclared p k) do
          continue
        let cls := physicalClass p k
        -- A refused listing fails the run — an unlisted kind could hide an
        -- orphan — but says what was being listed and why, since the fleet
        -- may declare nothing of this kind at all.
        let listed ← try b.list k catch e =>
          throw (IO.userError s!"listing {p.name} {k.name}{if code.isEmpty then "" else s!" in {code}"} \
failed. Every kind on the fleet's clouds is listed, declared or not, to find resources \
carrying this fleet's marker that the declaration no longer names — so the credentials \
need read access to it. The cloud said: {e}")
        for o in listed do
          let handle := observedHandle k o
          let nm := handle.raw
          let sameThing := fun (q : ProviderId) (k' : Kind) (n : String) =>
            q == p && physicalClass q k' == cls && n == nm
          if declaredPhysically κ p cls nm
              || found.any (fun (c, r) => c == cls && r.cloud == p && r.name == nm)
              || releases.any (fun (c, r) => c == cls && r.cloud == p && r.name == nm)
              || refused.contains (p, cls, nm) then
            continue
          -- The marker, or `none` if the cloud refused to show it — see
          -- `refusedMarkerWarning`. Any other failure fails the run, naming
          -- the resource.
          let slot := slotId p k nm
          let evidence? ← try some <$> b.ownershipInfo k handle catch e =>
            if readsAsRefused (toString e) then pure none
            else throw (IO.userError s!"reading the ownership marker of {slot}{if code.isEmpty then "" else s!" in {code}"} \
failed. It is not declared, so it is read to find out whether it carries this fleet's \
marker. The cloud said: {e}")
          let isForgotten := forgets.any (fun r => sameThing r.cloud r.kind r.name)
          let evidence ← match evidence? with
            | some ev => pure ev
            | none =>
              refused := refused ++ [(p, cls, nm)]
              warnings := warnings ++ [refusedMarkerWarning boundary slot isForgotten]
              continue
          -- A forgotten resource is never an orphan. If it still carries
          -- this fleet's marker, and the marker is somewhere that can be
          -- rewritten, apply removes it; a name-only one keeps its marker —
          -- its name — and its `forget` line has to stay.
          if isForgotten then
            if claimsUndeclared boundary p k nm evidence then
              match evidence with
              | .tags _ _ =>
                releases := releases ++ [(cls, { cloud := p, kind := k, name := nm, region := code })]
              | _ => pure ()
            continue
          if claimsUndeclared boundary p k nm evidence then
            found := found ++ [(cls, { cloud := p, kind := k, name := nm, region := code })]
          else if carriesRetiredMarker evidence then
            warnings := warnings ++ [retiredMarkerWarning boundary (slotId p k nm)]
  return { orphans := found.map (·.2), releases := releases.map (·.2), warnings }

-- ══════════════════════════════════════════════════════════════
-- Ordering
-- ══════════════════════════════════════════════════════════════

def Action.verb {κ : Keys} : Action κ → String
  | .create ..  => "CREATE"
  | .update ..  => "UPDATE"
  | .replace .. => "REPLACE"
  -- FORGET, not DELETE, for the one kind whose delete touches no cloud: the
  -- schema's lifetime is the database's, not the declaration's, so removing
  -- the line releases the rows from management and destroys nothing. The
  -- plan must not read as if it did. See `docs/migrations.md`, hard edge 1.
  | .delete _ k _ => if k == .postgresMigrations then "FORGET" else "DELETE"
  | .deleteOrphan _ k _ _ => if k == .postgresMigrations then "FORGET" else "DELETE"
  | .release .. => "RELEASE"

/-- Whether this action removes a resource. Deletions are ordered against the
    transpose of the creation graph. -/
def Action.isDestructive {κ : Keys} : Action κ → Bool
  | .delete ..       => true
  | .deleteOrphan .. => true
  | _                => false

/-- The slot an action points at. Identical for an orphan and for a declared
    resource, so a plan reads the same whether something was dropped from the
    declaration or told to be absent within it. -/
def Action.slot {κ : Keys} (a : Action κ) : String :=
  let (p, k, nm) := a.address; slotId p k nm

/-- A human-readable line for a plan. -/
def Action.render {κ : Keys} (a : Action κ) : String := s!"{a.verb} {a.slot}"

/-- The colour each verb earns, by how much it costs to get wrong.

    Creating is safe, updating is reversible, replacing destroys and recreates,
    deleting just destroys — so they run green, yellow, magenta, red. -/
def Action.colour {κ : Keys} : Action κ → String
  | .create ..  => Ansi.green
  | .update ..  => Ansi.yellow
  | .replace .. => Ansi.magenta
  -- Blue for a history's FORGET: it touches no cloud.
  | .delete _ k _ => if k == .postgresMigrations then Ansi.blue else Ansi.red
  | .deleteOrphan _ k _ _ => if k == .postgresMigrations then Ansi.blue else Ansi.red
  -- Blue, like FORGET: nothing is destroyed; the resource stops being ours.
  | .release .. => Ansi.blue

/-- `render`, with the verb coloured. Identical to `render` when `colour` is
    off, which is what keeps a rendered plan matchable as plain text. -/
def Action.renderStyled {κ : Keys} (colour : Bool) (a : Action κ) : String :=
  s!"{Ansi.style colour a.colour a.verb} {a.slot}"

/-- The slots a spec depends on by **naming** one, rather than by holding a
    typed reference to it.

    Four specs do this, all for the same reason: a reference has
    type `K p k`, which names a provider, and a portable spec that named a
    provider would not be portable. So they carry a plain `String` —
    `PostgresSpec.masterPasswordSecret`, `SecretSource.apiKeyFor`, every
    field of `PostgresMigrationsSpec` that names another resource, and
    `ComputeSpec.migrations` — and `HasDeps`, which can only produce edges
    out of real references, reports nothing for the name-bearing fields.

    The consequence was an ordering that happened to be right. Nothing said a
    secret must exist before the database whose password it holds; it did,
    because `.secrets` precedes `.postgres` in the `Kind` enum and ties are
    broken by enumeration order. Exactly the same accident put `.iam` before
    `.secrets`, which is what would have made `apiKeyFor` appear to work.
    Reordering the enum — a change nobody would expect to matter — would have
    broken both, and the failure would have been a create against a resource
    that does not exist yet: intermittent-looking, and blamed on the cloud.

    A name is not a reference and never will be one here, but the *scheduler*
    does not need a reference: it orders `String` slot ids, and a name plus
    the kind it must name is enough to build one. An edge to a slot no action
    touches is ignored by `schedule`, so naming an identity this fleet does
    not manage stays legal and simply constrains nothing.

    Both edges are same-cloud, which is right: a secret's value is read
    through the cloud's own secret manager, and an API key is minted by the
    cloud's own IAM. Neither has a cross-cloud reading. -/
def impliedByName {κ : Keys} (p : ProviderId) :
    (k : Kind) → Infra.Specs.SpecOf.{1} k κ.Key Partial (Expr κ.Key) → List String
  | .secrets, s =>
    match s.valueFrom.asLit with
    | some (.apiKeyFor identity) =>
      if identity.isEmpty then [] else [slotId p .iam identity]
    | _ => []
  | .postgres, s =>
    match s.masterPasswordSecret.asLit with
    | some nm => if nm.isEmpty then [] else [slotId p .secrets nm]
    | none    => []
  -- Three name-borne edges: the parent database, and the two URL secrets.
  -- Same-cloud on purpose — the read-only and read-write identities are
  -- minted by the same cloud that hosts the database, and a cross-cloud
  -- reading would mean the database's schema was legible from somewhere it
  -- was never granted to.
  --
  -- The edges *between* histories are not here: they come from the SQL, and
  -- reading them needs the whole plan, not one spec (`dependsOn`,
  -- `Plan.historyDeps`).
  | .postgresMigrations, s =>
    match s.database.asLit, s.connectionSecret.asLit, s.observerSecret.asLit with
    | some db, some cs, some os =>
        (if db.isEmpty then [] else [slotId p .postgres db])
        ++ (if cs.isEmpty then [] else [slotId p .secrets cs])
        ++ (if os.isEmpty then [] else [slotId p .secrets os])
    | _, _, _ => []
  -- The rollout-ordering edges: a compute waits for every migration set its
  -- `migrations` field names. An empty name constrains nothing.
  | .compute, s =>
    match s.migrations with
    | .known e => match e.asLit with
      | some nms => nms.filterMap fun nm =>
          if nm.isEmpty then none else some (slotId p .postgresMigrations nm)
      | none     => []
    | .unknown => []
  | _, _ => []

/-- The slots a resource's spec references, if the plan wants it present. -/
private def dependsOn {κ : Keys} (T : Plan κ) (p : ProviderId) (k : Kind)
    (key : κ.Key p k) : List String :=
  match T.assign p k key with
  | .present authored =>
    -- The `Need` tag is ignored here: a handle and a value are the same edge
    -- as far as ordering goes.
    (((hasDepsOf k).deps authored).map fun d =>
      slotId d.provider d.kind (κ.name d.provider d.kind d.key))
    ++ impliedByName p k authored
    -- A history follows the histories whose tables its SQL references.
    ++ (if k == .postgresMigrations then
          (T.historyDeps p (κ.name p k key)).map (slotId p .postgresMigrations)
        else [])
  | _ => []

/-- One scheduling step. -/
private structure Step (κ : Keys) where
  action : Action κ
  id     : String
  after  : List String

/-- Uniform over the four verbs, including `delete`, which used to be given no
    edges at all. Which *plan* the edges are read from is the caller's choice —
    see `orderActions`. -/
private def stepOf {κ : Keys} (T : Plan κ) : Action κ → Step κ
  | a@(.create p k key)  => { action := a, id := a.slot, after := dependsOn T p k key }
  | a@(.update p k key)  => { action := a, id := a.slot, after := dependsOn T p k key }
  | a@(.replace p k key) => { action := a, id := a.slot, after := dependsOn T p k key }
  | a@(.delete p k key)  => { action := a, id := a.slot, after := dependsOn T p k key }
  -- No edges, and there cannot be any. A resource whose declaration is gone
  -- has no spec, so nothing states what it referenced. It is deleted in the
  -- teardown half of `orderActions`, which is the transpose of the build
  -- graph, so an orphan with no edges is unconstrained relative to the rest
  -- and simply runs among them.
  --
  -- The consequence is worth naming: if an orphaned instance still references
  -- an orphaned security group, nothing here knows, and AWS will refuse the
  -- group's delete with `DependencyViolation` until the instance is gone —
  -- which is why `push` retries a refused orphan delete after the rest.
  | a@(.deleteOrphan ..) => { action := a, id := a.slot, after := [] }
  -- A release touches nothing but the marker, so it depends on nothing.
  | a@(.release ..) => { action := a, id := a.slot, after := [] }

/-- Kahn's algorithm, bounded by the number of steps.

    The recursion is on a `Nat` starting at the step count, and every round
    removes at least one step — so the bound is a real measure, not a guess.
    Exhausting it with steps left over means a cycle, so the same argument
    gives both termination and the diagnosis. -/
private def schedule {κ : Keys} : Nat → List (Step κ) → List String → List (Action κ) →
    Except String (List (Action κ))
  | _,   [],      _,    acc => .ok acc.reverse
  | 0,   pending, _,    _   =>
    .error s!"dependency cycle among: {String.intercalate ", " (pending.map (·.id))}"
  | n+1, pending, done, acc =>
    let ready := pending.filter fun st =>
      st.after.all fun d => done.contains d || !(pending.any (·.id == d))
    if ready.isEmpty then
      .error s!"dependency cycle among: {String.intercalate ", " (pending.map (·.id))}"
    else
      let readyIds := ready.map (·.id)
      schedule n (pending.filter fun st => !readyIds.contains st.id)
        (done ++ readyIds) (ready.reverse.map (·.action) ++ acc)

/-- Order a work-list: dependencies first, then deletions against the
    transpose of the same graph — create B then A means delete A then B.

    Both halves are now *sorted*. Deletions used to be the input list simply
    reversed, which is enumeration order — `Kind` order, then declaration
    order within a bucket — and therefore related to the dependency graph only
    by luck. It came out right for the fleets here and wrong for others: a
    composed secret reading a database endpoint got the database deleted first,
    because `secrets` precedes `postgres` in the `Kind` enum. Reversing a
    topological sort is the same answer wherever the enum happens to sit.

    `edges` is where a *deletion*'s dependencies are read from, and it is
    separate from `T` for one reason: `destroy` reconciles against
    `Plan.absent`, whose `assign` is `.absent` everywhere, so it carries no
    specs and therefore no edges. The fleet's own declaration still does, and
    is what `Infra.Cli` passes. Defaulting to `T` keeps every other caller —
    and every plan that is not a teardown — exactly as it was.

    A cycle here cannot be new: the deletion graph is the creation graph, so
    anything cyclic has already been rejected by the first `schedule`. -/
def orderActions {κ : Keys} (T : Plan κ) (as : List (Action κ))
    (edges : Plan κ := T) : Except String (List (Action κ)) := do
  let builds := as.filter (!·.isDestructive)
  let ordered ← schedule builds.length (builds.map (stepOf T)) [] []
  let kills := as.filter (·.isDestructive)
  -- Sorted dependencies-first like the builds, then reversed: a resource is
  -- deleted before everything it depends on.
  let killOrder ← schedule kills.length (kills.map (stepOf edges)) [] []
  return ordered ++ killOrder.reverse

-- ══════════════════════════════════════════════════════════════
-- Push
-- ══════════════════════════════════════════════════════════════

/-- Whether to actually change anything.

    Dry run is the default. `actions` derives deletions from the target, so a
    mistaken key type or a stale fleet definition would otherwise destroy live
    resources on a first run. -/
structure PushOptions where
  apply : Bool := false
  /-- Allow a plan that destroys most of what is managed.

      Off by default, and the reason is a documented accident rather than
      caution for its own sake: HashiCorp deprecated `terraform refresh`
      because misconfigured credentials could make it read every managed
      object as deleted and then destroy them all without asking. A plan that
      destroys most of what this fleet manages is either a real teardown, in
      which case `destroy` says so explicitly, or something is wrong with the
      credentials or the declaration. -/
  force : Bool := false
  /-- Colour the rendered lines. **Off by default**, deliberately: every
      existing caller — including `infra check`, which matches rendered lines
      as plain text — keeps getting plain strings, and only a caller that knows
      it is talking to a terminal turns it on. See `Infra.Core.Ansi`. -/
  colour : Bool := false

/-- Settle a target for one slot against what exists so far.

    **The only place a secret value enters the engine.** If this slot's spec
    reads any (`Expr.secretValue`, tagged `Need.secretValue` by `HasDeps`),
    each one is fetched here through `Backend.secretValue`, put in the `Env`
    handed to `settleSpec`, and dropped when this function returns — the
    resulting `ProviderSpec` goes straight to one create/update call. Nothing
    is cached across actions: two resources reading one secret cost two reads,
    deliberately, so no value outlives the call that needs it.

    Fetching only for keys the spec actually names is what keeps a fleet with
    no composed secrets from ever calling `Backend.secretValue`. -/
private def settleFor {κ : Keys} (T : Plan κ) (bs : Backends) (entries : List (Entry κ))
    (p : ProviderId) (k : Kind) (key : κ.Key p k) : IO (ProviderSpec k) := do
  match T.assign p k key with
  | .present authored =>
    let world := worldOf entries
    let base := envOfWorld world
    -- Secret values, for exactly the secrets this spec reads.
    let wanted := ((hasDepsOf k).deps authored).filter fun d => d.need == Need.secretValue
    let mut values : List (ProviderId × String × String) := []
    for d in wanted do
      -- `Expr.deps` tags every `.secretValue` edge with `.secrets`, but that is
      -- not visible in `d.kind`, so the handle is built from the name rather
      -- than from `observedHandle`. Sound for the same reason `pullEntries`
      -- matches on it: `Keys.name` *is* the cloud's physical identifier.
      let nm := κ.name d.provider d.kind d.key
      unless (world.sighting d.provider d.kind d.key).isSome do
        throw (IO.userError
          s!"{slotId p k (κ.name p k key)}: needs the value of \
{slotId d.provider d.kind nm}, which does not exist yet")
      -- Deduplicated: a spec naming one secret twice would otherwise pay for
      -- two plaintext reads, which is the most expensive call to repeat.
      unless values.any (fun v => v.1 == d.provider && v.2.1 == nm) do
        values := (d.provider, nm,
                   ← (bs.backendFor d.provider d.kind nm).secretValue ⟨nm⟩) :: values
    let env : Env κ.Key :=
      { base with secretValue := fun p' key' =>
          (values.find? fun v => v.1 == p' && v.2.1 == κ.name p' .secrets key').map (·.2.2) }
    match settleSpec k env authored with
    | some spec => return spec
    | none => throw (IO.userError
        s!"{slotId p k (κ.name p k key)}: a referenced resource does not exist yet")
  | _ => throw (IO.userError s!"{slotId p k (κ.name p k key)}: nothing to apply")

/-- Record what a mutation produced, so later steps can reference it. -/
private def remember {κ : Keys} (bs : Backends) (entries : List (Entry κ))
    (p : ProviderId) (k : Kind) (key : κ.Key p k) (o : ObservedOf k) :
    IO (List (Entry κ)) := do
  let reported ← (bs.backendFor p k (κ.name p k key)).read k (observedHandle k o)
  return ⟨p, k, key, { observed := o, reported }⟩ :: entries

/-- Run `act`, and if it fails, say what was being done to what.

    A provider's error is about a *request* — "invalid runtime", "certificate
    verify failed", "DependencyViolation" — and on its own it names neither the
    resource nor the verb. That is the difference between

        HTTP 400: invalid runtime

    and

        CREATE scaleway/scaleway-function/reindex failed: HTTP 400: invalid runtime

    which is the same information plus the two facts the reader needs to know
    where to look. Wrapping it here rather than in each backend means every
    kind and every provider gets it from one place. -/
private def inContext {α : Type} (what : String) (act : IO α) : IO α := do
  match ← act.toBaseIO with
  | .ok a    => return a
  | .error e => throw (IO.userError s!"{what} failed: {e}")

/-- Run one action, returning the updated set of known resources.

    Threading the resources forward is what lets a later step reference one an
    earlier step created — the reason `push` cannot simply map over the
    work-list. -/
private def runAction {κ : Keys} (bs : Backends) (T : Plan κ)
    (entries : List (Entry κ)) : Action κ → IO (List (Entry κ))
  -- Every mutation goes to the slot's *own* backend, which for a fleet in one
  -- region per cloud is the cloud's only one.
  | .create p k key => inContext s!"CREATE {slotId p k (κ.name p k key)}" do
    let o ← (bs.backendFor p k (κ.name p k key)).create k (← settleFor T bs entries p k key)
    remember bs entries p k key o
  | .update p k key => inContext s!"UPDATE {slotId p k (κ.name p k key)}" do
    match (worldOf entries).sighting p k key with
    | some seen =>
      let o ← (bs.backendFor p k (κ.name p k key)).update k (observedHandle k seen.observed)
        (← settleFor T bs entries p k key)
      remember bs entries p k key o
    | none => throw (IO.userError s!"{slotId p k (κ.name p k key)}: vanished before update")
  | .replace p k key => inContext s!"REPLACE {slotId p k (κ.name p k key)}" do
    -- Destroy then create: the key survives, the handle does not.
    match (worldOf entries).sighting p k key with
    | some seen => (bs.backendFor p k (κ.name p k key)).delete k (observedHandle k seen.observed)
    | none      => pure ()
    let o ← (bs.backendFor p k (κ.name p k key)).create k (← settleFor T bs entries p k key)
    remember bs entries p k key o
  -- Deleting addresses the resource by *name*, not by the handle the world
  -- happens to be holding. That is not a shortcut: `Handle` is the name for
  -- every kind in this library, and going through the name is what makes this
  -- case and `deleteOrphan` below the same operation. Two spellings of one
  -- delete is exactly the shape that let `S3BucketSpec.region` disagree with
  -- the placement, so there is one.
  | .delete p k key => inContext s!"{Action.verb (.delete p k key)} {slotId p k (κ.name p k key)}" do
    let nm := κ.name p k key
    (bs.backendFor p k nm).delete k ⟨nm⟩
    return entries
  -- The same call, for a resource the declaration does not name, so `destroy`
  -- and "deleted every line, then applied" end in the same place. Routed on
  -- the region it was *found* in: `backendFor` resolves a region by looking
  -- the name up in the placement table, and an orphan is precisely a name that
  -- table does not contain.
  | .deleteOrphan p k nm region =>
    inContext s!"{Action.verb ((.deleteOrphan p k nm region : Action κ))} {slotId p k nm}" do
    (bs.backendAt p region).delete k ⟨nm⟩
    return entries
  -- Routed like an orphan: on the region it was found in.
  | .release p k nm region =>
    inContext s!"RELEASE {slotId p k nm}" do
    (bs.backendAt p region).release k ⟨nm⟩
    return entries

/-- What one action left behind: the resources seen so far and the log lines,
    threaded from action to action — from two places, the main pass and the
    retry rounds for refused orphan deletions. -/
private structure Progress (κ : Keys) where
  entries : List (Entry κ)
  log     : List String

/-- Run one action.

    An orphan's delete re-checks its marker first, at the moment of deleting:
    the scan that found it ran before the plan, and deleting is the one step
    that cannot be taken back. The check is `claimsUndeclared`, the same one
    the scan used, so nothing is deleted here that the scan would not have
    claimed. A history's delete is a FORGET that touches no cloud, so there is
    nothing to protect and no check. -/
private def runStep {κ : Keys} (bs : Backends) (T : Plan κ) (boundary : Boundary)
    (opts : PushOptions) (st : Progress κ) (a : Action κ) : IO (Progress κ) := do
  match a with
  | .deleteOrphan p k nm region =>
    unless k == .postgresMigrations do
      let evidence ← (bs.backendAt p region).ownershipInfo k ⟨nm⟩
      unless claimsUndeclared boundary p k nm evidence do
        throw (IO.userError s!"{slotId p k nm}: no longer carries this fleet's marker; \
refusing to delete it")
  -- A release re-checks too: removing a marker that is no longer this
  -- fleet's would unmark somebody else's resource. Already unmarked is the
  -- outcome asked for, so it is reported rather than refused.
  | .release p k nm region =>
    let evidence ← (bs.backendAt p region).ownershipInfo k ⟨nm⟩
    unless claimsUndeclared boundary p k nm evidence do
      return { st with log := s!"{a.renderStyled opts.colour} \
{Ansi.style opts.colour Ansi.dim "... already not this fleet's"}" :: st.log }
  | _ => pure ()
  let entries ← runAction bs T st.entries a
  return { entries
           log := s!"{a.renderStyled opts.colour} \
{Ansi.style opts.colour Ansi.green "... ok"}" :: st.log }

/-- Declared resources that exist but are **not** this fleet's, by slot, with
    the verdict in English.

    The other half of "the marker decides": a resource may be changed or
    destroyed only if it carries this fleet's marker, whatever the
    declaration says about it. Before 0.15.0 only an orphan's delete checked
    (`runStep`); an `update`, a `replace`, or a `destroy` of a *declared* name
    ran against whatever held that name — while the (then) adoption warning
    told the reader such a resource "will not be created, changed or destroyed". Now it
    will not be: `push` drops those actions, on the plan path too, so a plan
    never shows work it will refuse.

    A kind whose marker this backend cannot read counts as foreign — refusing
    only means this fleet manages less than it declares (and says so), while
    guessing could destroy someone else's resource. `unmanaged` keys are not
    asked about: they are "not my business". -/
def foreignDeclared {κ : Keys} (bs : Backends) (T : Plan κ) (W : World κ)
    (boundary : Boundary) : IO (List (String × String)) := do
  let mut out : List (String × String) := []
  for p in Finite.elems (α := ProviderId) do
    for k in Finite.elems (α := Kind) do
      for key in Finite.elems (α := κ.Key p k) do
        match T.assign p k key, W.sighting p k key with
        | .unmanaged, _ => pure ()
        | _, none       => pure ()
        | _, some sighting =>
          let nm := κ.name p k key
          let slot := slotId p k nm
          match ← (bs.backendFor p k nm).ownershipInfo k (observedHandle k sighting.observed) with
          | .unreadable =>
            out := out ++ [(slot, "of a kind whose marker this backend cannot read, so its \
ownership cannot be verified")]
          | evidence =>
            let verdict := ownershipOf boundary p k nm evidence
            unless verdict.isOurs do
              out := out ++ [(slot, describeVerdict boundary evidence verdict)]
  return out

/-- Reconcile the world to the target.

    Returns the lines describing what was done — or, in a dry run, what would
    have been. A dry run performs no backend IO at all: it does not skip the
    writes, it never reaches them. -/
def push {κ : Keys} (bs : Backends) (T : Plan κ) (W : World κ)
    (opts : PushOptions := {}) (edges : Plan κ := T) (orphans : List Orphan := [])
    (boundary : Boundary := {}) (seen : Option (List (Entry κ)) := none)
    (releases : List Orphan := []) :
    IO (List String) := do
  -- The migrations contract, refused before any action is derived — so a
  -- plan shows the refusal exactly where it would have shown the work, and
  -- an apply never reaches the backend's own third check. Runs on the
  -- placeholder path too, where it is vacuous: no sighting, no history.
  -- Unknown SQL cannot be applied, diffed or ordered: a URL source is
  -- fetched by `Infra.Cli.run` before it calls here, and a caller that
  -- skipped that is refused rather than served a guess.
  match T.unresolvedMigrationSources with
  | [] => pure ()
  | slots => throw (IO.userError s!"{String.intercalate ", " slots}: migration sources \
have not been fetched — `Infra.Cli.run` reads every `url` source before `plan` and `apply`; \
a caller that builds its own backends must do the same (`Infra.Cli.fetchMigrationSources` then `withFetchedSources`)")
  if let some msg := T.migrationDepsProblem then
    throw (IO.userError msg)
  if let some msg := T.migrationsAppendOnly W then
    throw (IO.userError msg)
  let work ← match orderActions T (plan T W orphans releases) edges with
    | .ok o    => pure o
    | .error e => throw (IO.userError e)
  -- Only resources carrying this fleet's marker are changed or destroyed —
  -- see `foreignDeclared`. Said out loud per resource, on every run: the
  -- state it describes (declared, existing, and not ours) is otherwise
  -- invisible — no action, no plan line.
  let foreign ← foreignDeclared bs T W boundary
  for (slot, why) in foreign do
    IO.eprintln s!"warning: {slot} is declared and exists, but is {why}. It will not be \
changed or destroyed by this fleet, which therefore manages less than it declares. Either \
exclude it deliberately, or delete it and let this fleet create it — see docs/persistence.md"
  let work := work.filter fun a =>
    match a with
    | .update .. | .replace .. | .delete .. => !foreign.any (·.1 == a.slot)
    | _ => true
  -- A dry run returns here and writes nothing. An apply has nothing to record
  -- — membership is the markers, written at create — so an empty work-list
  -- is simply "nothing to do", below the brake.
  if !opts.apply then
    if work.isEmpty then
      return [Ansi.style opts.colour Ansi.dim "nothing to do"]
    return (work.map fun a =>
        Ansi.style opts.colour Ansi.dim "would " ++ a.renderStyled opts.colour) ++
      [Ansi.style opts.colour Ansi.dim "(dry run — nothing changed)"]
  -- The brake, and note what it is *not* asked on: a declaration that asks for
  -- nothing to exist. That is a teardown, it is the explicit statement this
  -- check exists to demand, and it is recognisable from the target itself —
  -- `Plan.absent` and a declaration with no resources in it are the same
  -- statement. Deciding it here rather than taking a flag is what stops every
  -- caller having to remember one; the first live run of the staged test
  -- failed on exactly that, because the test driver built its own
  -- `PushOptions` and the CLI's teardown flag was not in them.
  --
  -- Counted against what this fleet manages — the declared resources that
  -- exist and carry its marker, plus the orphans — rather than the work-list,
  -- because the question is "how much of what I manage is about to go", and a
  -- plan that also creates things would otherwise dilute the ratio.
  let declaredOurs := (Finite.elems (α := ProviderId)).foldl (init := 0) fun n p =>
    (Finite.elems (α := Kind)).foldl (init := n) fun n k =>
      (Finite.elems (α := κ.Key p k)).foldl (init := n) fun n key =>
        match T.assign p k key, W.sighting p k key with
        | .unmanaged, _ => n
        | _, some _ => if foreign.any (·.1 == slotId p k (κ.name p k key)) then n else n + 1
        | _, none => n
  let managed := declaredOurs + orphans.length
  let doomed := work.countP (·.isDestructive)
  if !opts.force && T.declaresAnything && managed > 1 && doomed * 2 > managed then
    throw (IO.userError s!"this would destroy {doomed} of {managed} managed \
      resources while still declaring others, which is not a teardown. If the declaration \
      is right, re-run with --force; if it is not, check the credentials are for the \
      account you meant")
  -- Reuse what the caller already observed. Re-reading would double the API
  -- calls on every apply, and the two pulls are microseconds apart, so they
  -- cannot usefully disagree.
  let mut entries ← match seen with
    | some es => pure es
    | none    => pullEntries (κ := κ) bs
  if work.isEmpty then
    return [Ansi.style opts.colour Ansi.dim "nothing to do"]
  let mut st : Progress κ := { entries, log := [] }
  -- Orphan deletions are the one part of the work-list with no dependency
  -- edges to sort by: a resource whose declaration is gone has no spec, so
  -- nothing states what it referenced, and the scan reports names and
  -- regions rather than references (`Orphan`). So an orphan delete the
  -- provider refuses — `DependencyViolation` on a security group an orphaned
  -- instance still uses — is *held back* rather than fatal, and tried again
  -- once the rest of the work-list has run. The schedule converges by
  -- repetition instead of by ordering, which is the same answer
  -- `test/Live.lean`'s `sweepPass` gives to the same question: an ordering
  -- nothing can know is discovered from what the provider allows.
  --
  -- Only `deleteOrphan` is treated this way. Every other verb has edges, so a
  -- failure there is a real failure and stops the apply as it always did.
  let mut deferred : List (Action κ × IO.Error) := []
  for a in work do
    match a with
    | .deleteOrphan .. =>
      match ← (runStep bs T boundary opts st a).toBaseIO with
      | .ok st'  => st := st'
      | .error e => deferred := deferred ++ [(a, e)]
    | _ => st ← runStep bs T boundary opts st a
  -- Bounded, and the bound is a real measure: a round that deletes nothing
  -- stops, so every round but the last removes at least one orphan.
  for _ in [0:deferred.length] do
    if deferred.isEmpty then break
    let before := deferred.length
    let mut left : List (Action κ × IO.Error) := []
    for (a, _) in deferred do
      match ← (runStep bs T boundary opts st a).toBaseIO with
      | .ok st'  => st := st'
      | .error e => left := left ++ [(a, e)]
    deferred := left
    -- Nothing went this round, so nothing will go next round either: what is
    -- left is not waiting on an ordering.
    if left.length == before then break
  -- Reported with the provider's own words, from the last attempt, so a
  -- refusal that was never about ordering reads exactly as it did before.
  match deferred with
  | (_, e) :: _ => throw e
  | []          => pure ()
  return st.log.reverse

end Infra.Core
