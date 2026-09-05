import Infra.Core.Backend
import Infra.Core.Persistence
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

    Listed resources that no fleet key claims are dropped, which is what makes
    a real `list` safe: the fleet's key types decide what this target manages,
    so an account full of unmanaged buckets cannot become a pile of proposed
    deletions. -/
def pullEntries {κ : Keys} (bs : Backends) : IO (List (Entry κ)) := do
  let mut acc : List (Entry κ) := []
  for p in Finite.elems (α := ProviderId) do
    for k in Finite.elems (α := Kind) do
      -- A pair with no keys cannot be claimed by this fleet, so listing it
      -- could only produce rows that are immediately dropped. Skipping it is
      -- not just an optimisation: it is what lets an all-Scaleway fleet run
      -- without ever calling AWS, and so without AWS credentials.
      if (Finite.elems (α := κ.Key p k)).isEmpty then
        continue
      -- One listing per region this bucket's resources live in — for a fleet
      -- in one region per cloud that is exactly one, as it always was. Each
      -- listing is matched only against the slots placed in *that* region:
      -- see `Backends.listers` for why the pairing is not optional.
      for (b, here) in bs.listers p k do
        let observed ← b.list k
        for key in Finite.elems (α := κ.Key p k) do
          let nm := κ.name p k key
          if here nm then
            match observed.find? (fun o => (observedHandle k o).raw == nm) with
            | some o =>
              -- Only now, for a key the fleet actually claims, is the extra
              -- per-resource read worth paying for.
              let reported ← b.read k (observedHandle k o)
              acc := ⟨p, k, key, { observed := o, reported }⟩ :: acc
            | none   => pure ()
  return acc

/-- Observe the world and cache it. -/
def pull {κ : Keys} (root : System.FilePath) (bs : Backends) : IO (World κ) := do
  let es ← pullEntries (κ := κ) bs
  Persistence.save root (es.map Entry.cached)
  return worldOf es

/-- What would have to change for the world to realise the target. Pure: it
    decides, it does not act. -/
def plan {κ : Keys} (T : Plan κ) (W : World κ) : List (Action κ) := actions T W

-- ══════════════════════════════════════════════════════════════
-- Ordering
-- ══════════════════════════════════════════════════════════════

/-- A stable identifier for a resource slot. A string, so steps of different
    kinds can share one list — the dependent key cannot. -/
def slotId (p : ProviderId) (k : Kind) (name : String) : String :=
  s!"{p.name}/{k.name}/{name}"

def Action.verb {κ : Keys} : Action κ → String
  | .create ..  => "CREATE"
  | .update ..  => "UPDATE"
  | .replace .. => "REPLACE"
  | .delete ..  => "DELETE"

/-- Whether this action removes a resource. Deletions are ordered against the
    transpose of the creation graph. -/
def Action.isDestructive {κ : Keys} : Action κ → Bool
  | .delete .. => true
  | _          => false

/-- The slot an action points at. -/
def Action.slot {κ : Keys} : Action κ → String
  | .create p k key | .update p k key | .replace p k key | .delete p k key =>
    slotId p k (κ.name p k key)

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
      slotId d.provider d.kind (κ.name d.provider d.kind d.key)
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
  | .delete p k key => inContext s!"DELETE {slotId p k (κ.name p k key)}" do
    match (worldOf entries).sighting p k key with
    | some seen => (bs.backendFor p k (κ.name p k key)).delete k (observedHandle k seen.observed)
    | none      => pure ()
    return entries

/-- Reconcile the world to the target.

    Returns the lines describing what was done — or, in a dry run, what would
    have been. A dry run performs no backend IO at all: it does not skip the
    writes, it never reaches them. -/
def push {κ : Keys} (bs : Backends) (T : Plan κ) (W : World κ)
    (opts : PushOptions := {}) (edges : Plan κ := T) : IO (List String) := do
  let work ← match orderActions T (plan T W) edges with
    | .ok o    => pure o
    | .error e => throw (IO.userError e)
  if work.isEmpty then
    return [Ansi.style opts.colour Ansi.dim "nothing to do"]
  if !opts.apply then
    return (work.map fun a =>
        Ansi.style opts.colour Ansi.dim "would " ++ a.renderStyled opts.colour) ++
      [Ansi.style opts.colour Ansi.dim "(dry run — nothing changed)"]
  let mut entries ← pullEntries (κ := κ) bs
  let mut log : List String := []
  for a in work do
    entries ← runAction bs T entries a
    log := s!"{a.renderStyled opts.colour} {Ansi.style opts.colour Ansi.green "... ok"}" :: log
  return log.reverse

end Infra.Core
