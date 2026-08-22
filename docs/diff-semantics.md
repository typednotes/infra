# Diff Semantics

## Problem

`docs/architecture.md` calls for objects to "be diff-able at their structure level" so an
engine can move current state to target. `Infra.Core.Diff` implements this at the level of a
single object (`Diffable.diff`/`apply`/`Satisfies`), but two things were left informal:

1. What does an unset (`none`) field on a `Target` actually mean — is it "reset this to
   nothing" or "leave whatever's there alone"? This matters because every `TargetState` in
   this codebase makes its fields `Option`.
2. What happens when a whole *object* is missing from one side or the other — e.g. a target
   defines a bucket that has no matching pulled object yet, or a pulled object has no matching
   target anymore? `Diffable` alone, being object-to-object, has no way to express this.

This doc formalizes both, using Terraform/OpenTofu's attribute model as the reference point
per `docs/architecture.md`'s "Inspirations" section.

## Field level: which Terraform attribute kind matches `fieldDiff`?

Terraform/OpenTofu providers classify each resource attribute as one of:

- **Required** — must always appear in config; always participates in the diff.
- **Optional** — may be omitted from config. Omission means "no value"; if the attribute
  previously had a value, omitting it in config plans to *clear* it.
- **Computed** — never set from config; the provider assigns it (on create or on every read).
  Never part of a config-vs-state diff.
- **Optional + Computed** — may be set from config, but omission does **not** mean "clear
  it." It means "the provider may default it, and if a value already exists (from a prior
  apply or the provider's own default), leave it alone." No diff is generated purely from the
  attribute being absent from config; a diff is only generated when config sets it to a value
  that disagrees with the current one.

`Infra.Core.Diff.fieldDiff`/`fieldApply`/`fieldSatisfied` implement **Optional + Computed**,
not plain Optional:

```lean
def fieldDiff [DecidableEq α] (target : Option α) (current : α) : Option α :=
  match target with
  | some v => if v = current then none else some v
  | none   => none
```

`target := none` always produces `none` — no diff, regardless of `current`. This is a
deliberate, existing property, not new behavior; this doc makes it explicit. Concretely: every
`Option`-typed field on every `TargetState` in this codebase (`BucketTarget.name`,
`SecretTarget.value`, etc.) behaves as Optional+Computed. There is currently no plain-Optional
field anywhere (one whose omission would actively reset an existing value) — if one is ever
needed, it requires a different helper than `fieldDiff`, not a reinterpretation of `none`.

## Collection level: create / update / delete

A single `Diffable.diff` compares one `Target` to one `Current` that are already known to
correspond to the same real-world object. Before that comparison can happen, a collection of
targets has to be matched up against a collection of currently-known objects — and some
targets or currents may simply have no match. `Infra.Core.CollectionDelta`/`reconcile`
implement this matching with three rules, given directly by the user for this project:

- **Present in target only → create.** No corresponding current object exists yet; the engine
  should call the backend's `create*`.
- **Present in current only → delete.** The pulled object has no target defining it anymore;
  the engine should call the backend's `delete*`.
- **Present in both → per-field diff.** Reduces to the field-level semantics above via
  `Diffable.diff`, whose result (a `Delta`) drives `update*`.

```lean
def reconcile [Diffable Target Current]
    (targets  : List (String × Target))
    (currents : List (String × Current)) :
    CollectionDelta Target Current
```

### Matching key: local address, not `ObjectKey`

`reconcile` matches entries by a plain `String` key supplied alongside each `Target`/`Current`
by whoever assembles the collection (e.g. `("my_bucket", target)`) — **not** by
`Keyed`/`ObjectKey{provider, service, id}` from `Infra.Core.State`. `ObjectKey.id` is
assigned by the provider on creation, so a not-yet-created `Target` has no `id` to match on;
the local key is the only identity available on both sides before and after creation. This is
exactly Terraform's distinction between a resource's address (`type.name`, chosen by whoever
writes the config, stable across applies) and its provider-assigned id embedded in state. The
local key is never added as a field to a `TargetState`/`RemoteState` struct — it stays external
to the object, matching how a Terraform resource's label isn't one of its own attributes.

### Why `toUpdate` always includes matched pairs

`reconcile` puts every key present in both collections into `toUpdate`, even when
`Diffable.diff` computes an all-`none` ("nothing to change") `Delta`. This mirrors how
`SyncEngine.push` already treats an empty `Delta` as a no-op update — reconciliation doesn't
need a separate "unchanged" bucket; an unchanged object is just an update whose delta happens
to be empty.

## Out of scope

Executing a `CollectionDelta` against a real backend (`SyncEngine.push`) is not part of this
doc or the increment that introduced `reconcile` — see the persistence/pull work in
`docs/persistence.md` and `Infra.Core.pull` for what is implemented so far.
