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

    `outside` is the disposition of keys not in this fleet's key types: `absent` = closed world
    (garbage-collect), `unmanaged` = open world. -/
structure Plan (κ : Keys) where
  assign  : (p : ProviderId) → (k : Kind) → (key : κ.Key p k) →
              Status (SpecOf.{1} k κ.Key Partial (Expr κ.Key))
  outside : Status Unit

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

    This is how a fleet is torn down, and it is worth being precise about why
    it is not the same as deleting the resources from the source file.
    `assign` is total over `κ.Key`, so a resource *removed* from a declaration
    no longer has a key for anything to mention — it becomes unmanaged, and
    whatever exists in the cloud is left alone. Keeping the keys and saying
    `.absent` is what turns "I no longer want this" into a DELETE.

    `outside` stays `unmanaged`: this says nothing about resources the fleet
    never claimed, only that the ones it did claim should go. -/
def Plan.absent (κ : Keys) : Plan κ where
  assign _ _ _ := .absent
  outside := .unmanaged

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

/-- Whether the world realises the target everywhere. Decidable, because every key type is
    `Finite`: fold over the enumerations. -/
def satisfies {κ : Keys} (T : Plan κ) (W : World κ) : Bool :=
  (Finite.elems (α := ProviderId)).all fun p =>
    (Finite.elems (α := Kind)).all fun k =>
      (Finite.elems (α := κ.Key p k)).all fun key => satisfiesAt T W p k key

scoped notation:50 W " ⊨ " T => Infra.Core.satisfies T W = true

end Infra.Core
