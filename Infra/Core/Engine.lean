import Infra.Core.Backend
import Infra.Core.Persistence
import Infra.Core.Ledger
import Infra.Core.Ansi

/-
  The sync loop: observe the world, work out what has to change, and — when
  told to — change it.
-/

namespace Infra.Core

-- ══════════════════════════════════════════════════════════════
-- Pull
-- ══════════════════════════════════════════════════════════════

/-- Where the two records live, and how to place a slot.

    `cacheRoot` holds observations (`Persistence`), `ledgerRoot` holds
    membership (`Ledger`). Both are optional so that the offline suite can
    push against no storage at all; the CLI always supplies them.

    `regionOf` is how a ledger row learns where its resource is. It has to be
    recorded at apply time, because after the declaration that placed the
    resource is deleted there is nothing left to derive it from, and
    `Backends.backendFor` needs it to route the delete. -/
structure Store (κ : Keys) where
  /-- One root for both records. They are distinguished by filename
      (`Ledger.path` vs `Persistence.statePath`), never by directory, so two
      roots could only ever disagree. -/
  root       : Option System.FilePath := none
  /-- What the ledger already records. Membership, and the only source of it. -/
  rows       : List Ledger.Row := []
  /-- Names being released rather than destroyed. -/
  forgets    : List (Released κ) := []
  regionOf   : ProviderId → Kind → String → String := fun _ _ _ => ""

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

    What listing no longer decides is *membership*. It used to: a listed
    resource no fleet key claimed was dropped, which is what made deleting a
    line abandon the resource. That question is now the ledger's
    (`Infra.Core.Ledger`), and this function answers only "what is out there
    right now". -/
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
              -- eventually consistent, so a `refresh` moments after a delete
              -- sees the deleted thing in the listing and then fails to read
              -- it. Treating that as "absent" is the truthful reading — it
              -- *is* absent — and the alternative was an aborted pull.
              match ← (b.read k (observedHandle k o)).toBaseIO with
              | .ok reported => acc := ⟨p, k, key, { observed := o, reported }⟩ :: acc
              | .error e =>
                unless readsAsAbsent (toString e) do throw e
            | none   => pure ()
  return acc

/-- Observe the world and cache it, keeping the entries.

    Separate from `pull` because `push` needs the entries and not just the
    `World` built from them: a `World` is a function, so it cannot be
    enumerated back into the list `runAction` threads forward. Without this
    the CLI pulled once for the plan and `push` pulled again for the apply,
    reading every declared resource twice per invocation. -/
def observe {κ : Keys} (root : System.FilePath) (bs : Backends) :
    IO (List (Entry κ)) := do
  let es ← pullEntries (κ := κ) bs
  Persistence.save root (es.map Entry.cached)
  return es

/-- Observe the world and cache it. -/
def pull {κ : Keys} (root : System.FilePath) (bs : Backends) : IO (World κ) :=
  worldOf <$> observe root bs

/-- What would have to change for the world to realise the target. Pure: it
    decides, it does not act. -/
def plan {κ : Keys} (T : Plan κ) (W : World κ)
    (ledger : List Ledger.Row := []) (forgets : List (Released κ) := []) :
    List (Action κ) := actions T W ledger forgets

-- ══════════════════════════════════════════════════════════════
-- Ordering
-- ══════════════════════════════════════════════════════════════

def Action.verb {κ : Keys} : Action κ → String
  | .create ..  => "CREATE"
  | .update ..  => "UPDATE"
  | .replace .. => "REPLACE"
  | .delete ..  => "DELETE"
  | .deleteOrphan .. => "DELETE"
  | .forget ..  => "FORGET"

/-- Whether this action removes a resource. Deletions are ordered against the
    transpose of the creation graph. -/
def Action.isDestructive {κ : Keys} : Action κ → Bool
  | .delete ..       => true
  | .deleteOrphan .. => true
  -- `forget` touches the ledger and never the cloud, so it is not destructive
  -- and must not be ordered against the teardown graph.
  | _                => false

/-- The slot an action points at. Identical for an orphan and for a declared
    resource, so a plan reads the same whether something was dropped from the
    declaration or told to be absent within it. -/
def Action.slot {κ : Keys} (a : Action κ) : String :=
  let (p, k, nm) := a.address; Ledger.slotId p k nm

/-- A human-readable line for a plan. -/
def Action.render {κ : Keys} (a : Action κ) : String := s!"{a.verb} {a.slot}"

/-- The colour each verb earns, by how much it costs to get wrong.

    Creating is safe, updating is reversible, replacing destroys and recreates,
    deleting just destroys — so they run green, yellow, magenta, red. -/
def Action.colour {κ : Keys} : Action κ → String
  | .create ..  => Ansi.green
  | .update ..  => Ansi.yellow
  | .replace .. => Ansi.magenta
  | .delete ..  => Ansi.red
  | .deleteOrphan .. => Ansi.red
  -- Blue: it changes what is managed, not what exists.
  | .forget ..  => Ansi.blue

/-- `render`, with the verb coloured. Identical to `render` when `colour` is
    off, which is what keeps a rendered plan matchable as plain text. -/
def Action.renderStyled {κ : Keys} (colour : Bool) (a : Action κ) : String :=
  s!"{Ansi.style colour a.colour a.verb} {a.slot}"

/-- The slots a resource's spec references, if the plan wants it present. -/
private def dependsOn {κ : Keys} (T : Plan κ) (p : ProviderId) (k : Kind)
    (key : κ.Key p k) : List String :=
  match T.assign p k key with
  | .present authored =>
    -- The `Need` tag is ignored here: a handle and a value are the same edge
    -- as far as ordering goes.
    ((hasDepsOf k).deps authored).map fun d =>
      Ledger.slotId d.provider d.kind (κ.name d.provider d.kind d.key)
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
  -- group's delete with `DependencyViolation` until the instance is gone. The
  -- ledger records names and regions, not references. Recording edges too
  -- would make it a second copy of the declaration.
  | a@(.deleteOrphan ..) => { action := a, id := a.slot, after := [] }
  -- Touches the ledger, never a provider, so it depends on nothing.
  | a@(.forget ..)       => { action := a, id := a.slot, after := [] }

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
      object as deleted and then destroy them all without asking. Membership
      here comes from the ledger and existence from a per-name `read`, which
      is the same shape, so it needs the same brake. A plan that removes most
      of the ledger is either a real teardown, in which case `destroy` says so
      explicitly, or something is wrong with the credentials. -/
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
          s!"{Ledger.slotId p k (κ.name p k key)}: needs the value of \
{Ledger.slotId d.provider d.kind nm}, which does not exist yet")
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
        s!"{Ledger.slotId p k (κ.name p k key)}: a referenced resource does not exist yet")
  | _ => throw (IO.userError s!"{Ledger.slotId p k (κ.name p k key)}: nothing to apply")

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
  | .create p k key => inContext s!"CREATE {Ledger.slotId p k (κ.name p k key)}" do
    let o ← (bs.backendFor p k (κ.name p k key)).create k (← settleFor T bs entries p k key)
    remember bs entries p k key o
  | .update p k key => inContext s!"UPDATE {Ledger.slotId p k (κ.name p k key)}" do
    match (worldOf entries).sighting p k key with
    | some seen =>
      let o ← (bs.backendFor p k (κ.name p k key)).update k (observedHandle k seen.observed)
        (← settleFor T bs entries p k key)
      remember bs entries p k key o
    | none => throw (IO.userError s!"{Ledger.slotId p k (κ.name p k key)}: vanished before update")
  | .replace p k key => inContext s!"REPLACE {Ledger.slotId p k (κ.name p k key)}" do
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
  | .delete p k key => inContext s!"DELETE {Ledger.slotId p k (κ.name p k key)}" do
    let nm := κ.name p k key
    (bs.backendFor p k nm).delete k ⟨nm⟩
    return entries
  -- The same call, for a resource whose declaration is gone, so `destroy` and
  -- "deleted every line, then applied" end in the same place. Routed on the
  -- region the *ledger* recorded: `backendFor` resolves a region by looking
  -- the name up in the placement table, and an orphan is precisely a name that
  -- table no longer contains, so it would fall back to the wrong endpoint for
  -- anything placed outside the credentials' own region.
  | .deleteOrphan p k nm region => inContext s!"DELETE {Ledger.slotId p k nm}" do
    (bs.backendAt p region).delete k ⟨nm⟩
    return entries
  -- Nothing is called. The row is dropped from the ledger by `push`, which is
  -- the only thing a forget does.
  | .forget .. => return entries

/-- The ledger after one action has succeeded.

    Membership changes on exactly four events: something was created (it is
    mine now), something was destroyed (it is not), something was forgotten
    (it is not, and it still exists), and an update or replace of something
    already recorded (no change, but recording it is what repairs a ledger
    that lost a row). -/
private def rowsAfter {κ : Keys} (store : Store κ) (rows : List Ledger.Row)
    (a : Action κ) : List Ledger.Row :=
  let (p, k, nm) := a.address (κ := κ)
  let without := rows.filter fun r => !Ledger.Row.isAt r p k nm
  match a with
  -- Recorded, and re-recorded rather than left alone, so that an `update`
  -- repairs a row whose region went stale.
  | .create .. | .update .. | .replace .. =>
    { cloud := p, kind := k, name := nm, region := store.regionOf p k nm } :: without
  -- Destroyed, or released. Either way it is no longer ours.
  | .delete .. | .deleteOrphan .. | .forget .. => without

/-- Reconcile the world to the target.

    Returns the lines describing what was done — or, in a dry run, what would
    have been. A dry run performs no backend IO at all: it does not skip the
    writes, it never reaches them. -/
def push {κ : Keys} (bs : Backends) (T : Plan κ) (W : World κ)
    (opts : PushOptions := {}) (edges : Plan κ := T) (store : Store κ := {})
    (seen : Option (List (Entry κ)) := none) : IO (List String) := do
  let work ← match orderActions T (plan T W store.rows store.forgets) edges with
    | .ok o    => pure o
    | .error e => throw (IO.userError e)
  if work.isEmpty then
    return [Ansi.style opts.colour Ansi.dim "nothing to do"]
  if !opts.apply then
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
  -- Counted against the ledger rather than the work-list, because the question
  -- is "how much of what I manage is about to go", and a plan that also
  -- creates things would otherwise dilute the ratio.
  let doomed := work.countP (·.isDestructive)
  if !opts.force && T.declaresAnything && store.rows.length > 1
      && doomed * 2 > store.rows.length then
    throw (IO.userError s!"this would destroy {doomed} of {store.rows.length} managed \
      resources while still declaring others, which is not a teardown. If the declaration \
      is right, re-run with --force; if it is not, check the credentials are for the \
      account you meant")
  -- Reuse what the caller already observed. Re-reading would double the API
  -- calls on every apply, and the two pulls are microseconds apart, so they
  -- cannot usefully disagree.
  let mut entries ← match seen with
    | some es => pure es
    | none    => pullEntries (κ := κ) bs
  let mut rows := store.rows
  let mut log : List String := []
  for a in work do
    let rowsBefore := rows
    let entriesBefore := entries.length
    entries ← runAction bs T entries a
    -- Written after *every* action, not once at the end. An apply that fails
    -- halfway has still created things, and a created resource missing from
    -- the ledger is an orphan nothing can name.
    rows := rowsAfter store rows a
    -- But only when something changed. `runAction` returns `entries`
    -- untouched for every deletion, and `rowsAfter` returns `rows` untouched
    -- when it re-records something already recorded, so a teardown of N
    -- resources would otherwise rewrite both records N times with identical
    -- bytes — and `Persistence.save` is a whole-world writer that visits all
    -- 42 `(provider, kind)` pairs on each call.
    if let some root := store.root then
      unless rows == rowsBefore do Ledger.save root rows
      unless entries.length == entriesBefore do
        Persistence.save root (entries.map Entry.cached)
    log := s!"{a.renderStyled opts.colour} {Ansi.style opts.colour Ansi.green "... ok"}" :: log
  return log.reverse

end Infra.Core
