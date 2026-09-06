import Infra.Core.Stage

/-
  A fleet: the set of resources one target speaks about, across all the clouds it spans.
-/

namespace Infra.Core

open Infra.Specs (SpecOf)

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
  /-- A stable string per key, for the on-disk cache. See `docs/persistence.md`. -/
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
    question is now answered per-resource by the ledger
    (`Infra.Core.Ledger`), which records exactly what this fleet manages and
    survives a resource's line being deleted. -/
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

    Resources this fleet never claimed are untouched either way: they have no
    ledger row, so nothing here can name them. -/
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

/-- The key carrying this name, if this fleet has one.

    Decidable because every key type is `Finite`. Both the membership test
    below and `Persistence.load` need it, and it was written out at both. -/
def Keys.keyOfName? (κ : Keys) (p : ProviderId) (k : Kind) (name : String) :
    Option (κ.Key p k) :=
  (Finite.elems (α := κ.Key p k)).find? fun key => κ.name p k key == name

/-- Whether any key in this fleet carries that name, for that `(provider, kind)`.

    Decidable because every key type is `Finite`. This is the test that turns a
    ledger row into either "still declared" or "an orphan". -/
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

/-- Whether the world realises the target everywhere. Decidable, because every key type is
    `Finite`: fold over the enumerations. -/
def satisfies {κ : Keys} (T : Plan κ) (W : World κ) : Bool :=
  (Finite.elems (α := ProviderId)).all fun p =>
    (Finite.elems (α := Kind)).all fun k =>
      (Finite.elems (α := κ.Key p k)).all fun key => satisfiesAt T W p k key

scoped notation:50 W " ⊨ " T => Infra.Core.satisfies T W = true

end Infra.Core
