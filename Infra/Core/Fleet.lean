import Infra.Core.Stage
import Infra.Core.Diverge
import Infra.Core.Slot
import Infra.Core.SqlDeps

/-
  A fleet: the set of resources one target speaks about, across all the clouds it spans.
-/

namespace Infra.Core

open Infra.Specs (SpecOf Migration MigrationDecl resolvedMigrations?)

/-- A key family: one finite, decidable key type per `(provider, kind)` pair.

    Use `Nothing` for a pair this fleet does not manage. Because each `Key p k` is a genuine
    `Finite` type rather than `String`, the cardinality of the fleet is a compile-time number
    and exhaustiveness over keys is checked.

    Indexed by `ProviderId` as well as `Kind` so one `Plan` can hold resources in several
    clouds at once, with `Expr` references crossing between them. `SpecOf` is *not* so indexed,
    which is what keeps specs portable. -/
structure Keys where
  Key    : ProviderId → Kind → Type
  finite : ∀ p k, Finite (Key p k)
  decEq  : ∀ p k, DecidableEq (Key p k)
  /-- A stable string per key: the resource's cloud-side name, which is how
      a key is matched to what the cloud lists. -/
  name   : ∀ p k, Key p k → String

attribute [instance] Keys.finite Keys.decEq

/-- How many resources of this kind this fleet declares in this cloud. Known statically. -/
@[reducible] def Keys.count (κ : Keys) (p : ProviderId) (k : Kind) : Nat := card (κ.Key p k)

/-- Whether this fleet can name anything at all in a provider.

    False exactly when every one of the provider's key types is empty, in which
    case the fleet cannot declare, plan, or push anything there — so its
    credentials are never needed and its API is never called. This is what
    makes a single-cloud fleet genuinely single-cloud rather than
    a two-cloud fleet with one half left `.unused`. -/
def Keys.uses (κ : Keys) (p : ProviderId) : Bool :=
  (Finite.elems (α := Kind)).any fun k => κ.count p k != 0

/-- The providers this fleet actually declares resources in. -/
def Keys.providers (κ : Keys) : List ProviderId :=
  (Finite.elems (α := ProviderId)).filter κ.uses

/-- The target state.

    `assign` is TOTAL over `κ.Key p k`. That is the single decision doing most of the work
    here:

      * total  ⇒ no key can be forgotten, and `absent` is expressible, so DELETION is part of
                 the target rather than an inference from omission. A partial map can only ever
                 say "at least these".
      * function ⇒ duplicate keys are unrepresentable.
      * finite domain ⇒ cardinality is determined even when every field inside is `unknown`.
                 Shape outside the modality, contents inside — a fleet may have three unknown
                 handles, never an unknown number of instances.

    There is deliberately no field for "everything else". There used to be one,
    `outside : Status Unit`, meant to choose between a closed world
    (garbage-collect anything undeclared) and an open one. Nothing ever read
    it, and it could not have worked as a single verdict: closing the world
    requires knowing *which* resources were once managed, and a fleet-wide
    `absent` would have proposed deleting every resource in the account. That
    question is now answered per-resource by the ownership marker
    (`Infra.Core.Ownership`), which is on the resource itself and so survives
    its line being deleted (`Engine.claimUndeclared`). -/
structure Plan (κ : Keys) where
  assign  : (p : ProviderId) → (k : Kind) → (key : κ.Key p k) →
              Status (SpecOf.{1} k κ.Key Partial (Expr κ.Key))

/-- What a backend saw at one key: the provider-computed state, and the
    configuration actually in force.

    Both are needed and neither substitutes for the other: `observed` carries
    the handle and the fields only the cloud can assign, `reported` carries the
    fields the target has an opinion about. Comparing a target against
    `observed` alone can only ever decide whether a resource exists. -/
structure Sighting (k : Kind) where
  observed : ObservedOf k
  reported : Reported k

/-- The observed world. `none` = the resource does not exist. -/
structure World (κ : Keys) where
  sighting : (p : ProviderId) → (k : Kind) → κ.Key p k → Option (Sighting k)

/-- Whether the world realises the target at one key.

    Only the *extent* half is checked here (existence / non-existence). Checking that the
    observed spec refines the target spec additionally requires a `Refines` instance for each
    `SpecOf k`; see the ledger in `docs/diff-semantics.md` for why that is deferred — an
    authored field holds an `Expr`, which contains functions and so has no decidable order
    until it has been evaluated against a world. -/
def satisfiesAt {κ : Keys} (T : Plan κ) (W : World κ)
    (p : ProviderId) (k : Kind) (key : κ.Key p k) : Bool :=
  match T.assign p k key, W.sighting p k key with
  | .unmanaged, _        => true
  | .absent,    none     => true
  | .absent,    some _   => false
  | .present _, some _   => true
  | .present _, none     => false

/-- The empty declaration: everything this fleet knows about must not exist.

    This is what `destroy` reconciles against, and it is the *same* statement
    as deleting every `resource` line and applying. Both destroy everything
    the fleet manages; they differ only in which constructor carries it
    (`Action.delete` here, `Action.deleteOrphan` there), and both end at the
    same `Backend.delete` call addressed by name. `destroy` exists because
    saying it is easier and more reviewable than emptying a file, not because
    it does anything a declaration cannot.

    Resources that do not carry this fleet's marker are untouched either way:
    the scan does not claim them, and `push` drops any change to a declared
    one (`Engine.foreignDeclared`). -/
def Plan.absent (κ : Keys) : Plan κ where
  assign _ _ _ := .absent

/-- Whether every secret this plan declares is honest about where its value
    comes from — no plaintext written into the committed target.

    `Expr.secretValue` made "a secret in the target" *expressible*, where it
    used to be structurally impossible, so this is the decidable replacement:
    a fleet writes `#guard myPlan.secretsAreSound` (or the `fleet` declaration
    emits it) and gets the guarantee back at compile time. Decidable because
    every key type is `Finite`. See `SecretsSpec.sourceIsSound` for the
    per-secret rule and `docs/diff-semantics.md`'s ledger for the tier change. -/
def Plan.secretsAreSound {κ : Keys} (T : Plan κ) : Bool :=
  (Finite.elems (α := ProviderId)).all fun p =>
    (Finite.elems (α := κ.Key p .secrets)).all fun key =>
      match T.assign p .secrets key with
      | .present s => s.sourceIsSound
      | _          => true

/-! ## Ordering between migration histories, read from their SQL

  Two histories on one database are ordered by what their SQL says: one
  that `references` a table is scheduled after the one that `create`s it
  (`SqlDeps`). Computed over the *resolved* histories of a database — every
  source inline or already fetched — because a URL nobody has read yet says
  nothing about tables. `Infra.Cli.run` fetches every source before `plan`
  and `apply`, so on those paths every database is resolved; only offline
  `check` sees unresolved ones, and it orders them without these edges. -/

/-- One present history, as the dependency analysis sees it. -/
structure HistoryInfo where
  name       : String
  database   : String
  /-- `none` while any source is an unfetched URL. -/
  migrations : Option (List Migration)

/-- Every present history on cloud `p`. -/
def Plan.histories {κ : Keys} (T : Plan κ) (p : ProviderId) : List HistoryInfo :=
  (Finite.elems (α := κ.Key p .postgresMigrations)).filterMap fun key =>
    match T.assign p .postgresMigrations key with
    | .present s =>
      match s.database.asLit with
      | some db => some { name := κ.name p .postgresMigrations key, database := db
                          migrations := s.migrations.asLit.bind resolvedMigrations? }
      | none    => none
    | _ => none

private def historyCreates (h : HistoryInfo) : List SqlDeps.TableName :=
  (h.migrations.getD []).flatMap fun m => SqlDeps.creates m.sql

private def historyRefs (h : HistoryInfo) : List SqlDeps.TableName :=
  (h.migrations.getD []).flatMap fun m => SqlDeps.references m.sql

/-- The histories on the same database as `h`, when all of them — `h`
    included — are resolved; `none` otherwise (no edges can be read yet). -/
private def resolvedPeers (all : List HistoryInfo) (h : HistoryInfo) : Option (List HistoryInfo) :=
  let peers := all.filter (·.database == h.database)
  if peers.all (·.migrations.isSome) then some peers else none

/-- The histories `name` (on cloud `p`) must follow: every other history on
    its database whose SQL creates a table `name`'s SQL references. Empty
    while that database has unresolved sources, and for a table the history
    creates itself. Ambiguity and unresolved references are not decided
    here — `migrationDepsProblem` refuses them — so this never guesses. -/
def Plan.historyDeps {κ : Keys} (T : Plan κ) (p : ProviderId) (name : String) : List String :=
  let all := T.histories p
  match all.find? (·.name == name) with
  | none   => []
  | some h =>
    match resolvedPeers all h with
    | none       => []
    | some peers =>
      let own := historyCreates h
      let wanted := (historyRefs h).filter fun t => !own.contains t
      (peers.filter fun g => g.name != name && (historyCreates g).any wanted.contains).map (·.name)

/-- What is wrong with the ordering the SQL implies, if anything, for every
    database whose histories are all resolved:

    * a table created by two histories — which one a reference means is a
      guess, so it is refused;
    * a reference to a table no history on that database creates — the
      dependency exists but points nowhere this fleet can order against,
      which is also how a table created where the scanner cannot see (a
      `DO` block) surfaces, rather than as a silently missing edge.

    A cycle is not checked here: `orderActions` refuses it, naming the
    slots. `Engine.push` refuses a plan with a problem before deriving any
    action; `migrationsAreSound` includes it, so an inline fleet gets it at
    compile time. -/
def Plan.migrationDepsProblem {κ : Keys} (T : Plan κ) : Option String :=
  let problems : List String :=
    (Finite.elems (α := ProviderId)).flatMap fun p =>
      let all := T.histories p
      all.flatMap fun h =>
        match resolvedPeers all h with
        | none       => []
        | some peers =>
          let own := historyCreates h
          let ambiguous := own.filterMap fun t =>
            let owners := peers.filter fun g => (historyCreates g).contains t
            if owners.length > 1 && (owners.head?.map (·.name)) == some h.name then
              some s!"{slotId p .postgresMigrations h.name}: table {t} on database \
'{h.database}' is created by several histories ({String.intercalate ", " (owners.map (·.name))}), \
so which one a reference means would be a guess"
            else none
          let unresolved := (historyRefs h).filterMap fun t =>
            if own.contains t || peers.any (fun g => (historyCreates g).contains t) then none
            else some s!"{slotId p .postgresMigrations h.name}: its SQL references {t}, \
which no declared history on database '{h.database}' creates — declare the history that \
creates it (or, if it is created where a scanner cannot see, such as inside a DO block, create \
it with a plain CREATE TABLE)"
          ambiguous ++ unresolved
  match problems.eraseDups with
  | []  => none
  | ps  => some (String.intercalate "\n" ps)

/-- Every `url` source not yet fetched, by slot. `Engine.push` refuses a
    plan that still has one: only `Infra.Cli.run`'s fetch turns a URL into
    SQL, and applying or diffing a history whose content is unknown would
    be a guess. -/
def Plan.unresolvedMigrationSources {κ : Keys} (T : Plan κ) : List String :=
  (Finite.elems (α := ProviderId)).flatMap fun p =>
    (T.histories p).filterMap fun h =>
      if h.migrations.isNone then some (slotId p .postgresMigrations h.name) else none

/-- Whether every declared migration history is sound, as far as can be
    decided from the declaration: each history's own rule
    (`PostgresMigrationsSpec.historyIsSound` — ids ordered, sources sound,
    schema quotable, literals throughout), and, where the SQL is known
    (inline sources), the ordering it implies (`migrationDepsProblem`).
    The decidable companion of `secretsAreSound`; a fleet writes
    `#guard myPlan.migrationsAreSound`. URL-sourced SQL is checked once
    fetched, by `Engine.push`. -/
def Plan.migrationsAreSound {κ : Keys} (T : Plan κ) : Bool :=
  ((Finite.elems (α := ProviderId)).all fun p =>
    (Finite.elems (α := κ.Key p .postgresMigrations)).all fun key =>
      match T.assign p .postgresMigrations key with
      | .present s => s.historyIsSound
      | _          => true)
  && T.migrationDepsProblem.isNone

/-- The runtime half of the migrations contract: what the database has
    applied must be a prefix of what the declaration names, with matching
    content.

    This cannot be a compile-time check — it needs observed state — so it
    is the one rule `Engine.push` refuses to act past: `push` throws this
    message before deriving any action, on the plan path as well as the
    apply path. The `Divergent` table answers the same question again (as a
    `forcesReplace` named "history conflict") for any caller that reaches
    `repairOf` without going through `push`; the backend re-checks a third
    time before applying, because defense against a rewritten history is
    cheap at every tier and fatal at none.

    A sighting against a target whose `migrations` is not a literal, or
    still has an unfetched URL, is skipped here rather than guessed at —
    `migrationsAreSound` refuses the first at compile time, and `push`
    refuses the second before it gets here. -/
def Plan.migrationsAppendOnly {κ : Keys} (T : Plan κ) (W : World κ) : Option String :=
  let declared : List (String × List Migration × List Migration) :=
    (Finite.elems (α := ProviderId)).flatMap fun p =>
      (Finite.elems (α := κ.Key p .postgresMigrations)).flatMap fun key =>
        match T.assign p .postgresMigrations key, W.sighting p .postgresMigrations key with
        | .present s, some seen =>
            match s.migrations.asLit.bind resolvedMigrations? with
            | some target => [(slotId p .postgresMigrations
                                 (κ.name p .postgresMigrations key),
                               seen.reported.migrations.filterMap MigrationDecl.resolved?,
                               target)]
            | none        => []
        | _, _ => []
  match declared.filterMap fun (slot, applied, target) =>
          (migrationsConflict applied target).map fun id => (slot, id) with
  | []            => none
  | (slot, id) :: _ => some s!"{slot}: the database has applied '{id}' in a form the \
declaration does not match — migrations are append-only. An applied migration must stay in \
the declaration's history with the same content forever, and the database cannot have \
applied an entry the declaration no longer names. Restore the history, or resolve the \
conflict deliberately — see docs/migrations.md"

/-- The key carrying this name, if this fleet has one.

    Decidable because every key type is `Finite`. The membership test below
    is built on it. -/
def Keys.keyOfName? (κ : Keys) (p : ProviderId) (k : Kind) (name : String) :
    Option (κ.Key p k) :=
  (Finite.elems (α := κ.Key p k)).find? fun key => κ.name p k key == name

/-- Whether any key in this fleet carries that name, for that `(provider, kind)`.

    Decidable because every key type is `Finite`. This is the test that keeps a
    declared name from ever becoming an orphan's delete (`actionsOrphaned`),
    and that `forget` asserts is false. -/
def claimedByKey (κ : Keys) (p : ProviderId) (k : Kind) (name : String) : Bool :=
  (κ.keyOfName? p k name).isSome

/-- A resource released from *this* fleet's management: not declared by it, and
    not to be destroyed with it.

    Indexed by `κ`, and the constructor is private, so the only way to obtain
    one is `releasing` below — which cannot elaborate for a name the fleet
    still declares. The index and the privacy together are what carry that
    guarantee to every consumer: a bare `ProviderId × Kind × String` (which is
    what this used to be) put the check at the single macro-generated call
    site and nowhere else, so a release list could be handed to a different
    fleet, or assembled by hand, with nothing to object. -/
structure Released (κ : Keys) where
  private mk ::
  cloud : ProviderId
  kind  : Kind
  name  : String
  deriving DecidableEq, BEq

/-- Whether a release names this resource. -/
def Released.isAt {κ : Keys} (r : Released κ) (p : ProviderId) (k : Kind)
    (name : String) : Bool :=
  r.cloud == p && r.kind == k && r.name == name

/-- One `forget` declaration, checked.

    The auto-param is the point, exactly as in `InstanceType.of`: `forget`ting
    a name this fleet still declares does not elaborate, so a declaration
    cannot say "manage this" and "stop managing this" at the same time. The
    error names the fleet and the resource.

    This is the only constructor of `Released κ`, which is what makes the
    check impossible to route around rather than merely present. -/
def releasing (κ : Keys) (p : ProviderId) (k : Kind) (name : String)
    (_h : Assert (!claimedByKey κ p k name) := by decide) : Released κ :=
  .mk p k name

/-- Whether this declaration asks for anything to exist.

    False for `Plan.absent`, and false for a declaration with no resources in
    it — which is the same statement, and is what makes a teardown recognisable
    from the target alone rather than from a flag the caller has to remember to
    pass. Decidable because every key type is `Finite`. -/
def Plan.declaresAnything {κ : Keys} (T : Plan κ) : Bool :=
  (Finite.elems (α := ProviderId)).any fun p =>
    (Finite.elems (α := Kind)).any fun k =>
      (Finite.elems (α := κ.Key p k)).any fun key =>
        match T.assign p k key with
        | .present _ => true
        | _          => false

/-- Whether the world realises the target everywhere. Decidable, because every key type is
    `Finite`: fold over the enumerations. -/
def satisfies {κ : Keys} (T : Plan κ) (W : World κ) : Bool :=
  (Finite.elems (α := ProviderId)).all fun p =>
    (Finite.elems (α := Kind)).all fun k =>
      (Finite.elems (α := κ.Key p k)).all fun key => satisfiesAt T W p k key

scoped notation:50 W " ⊨ " T => Infra.Core.satisfies T W = true

end Infra.Core
