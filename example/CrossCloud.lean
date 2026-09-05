import Infra

/-!
  # Example: one fleet, two clouds, and a reference crossing between them

  Object storage is the clearest place to see what the type system is
  actually buying, because all three of the design's moves show up in a
  fleet of four resources:

  1. **A portable spec is one value, used under either cloud.** The same
     `objectStore` declaration appears at `aws` and at `scaleway`. Nothing in
     it names a provider — that is what "portable" means here, and it is why
     `SpecOf` is indexed by `Kind` alone.
  2. **A provider-local kind is the escape hatch, and the loss of
     portability is visible in the type.** S3 Object Lock has no Scaleway
     counterpart, so it lives on `s3Bucket` rather than being bolted onto the
     portable kind and quietly ignored on one cloud.
  3. **A reference is an index into this very fleet**, so it cannot dangle —
     and it may cross clouds. The Scaleway function below reads the AWS
     bucket, and `push` schedules the bucket first because the reference
     says so, not because anything here lists an order.

      lake exe cross-cloud                # offline: the plan, from placeholders
      lake exe cross-cloud plan           # reads BOTH accounts
      lake exe cross-cloud apply          # creates real resources in both
      lake exe cross-cloud plan --destroy # what tearing it down would delete
      lake exe cross-cloud destroy        # delete it all again

  A bare invocation is offline and free. Unlike every other example here, the
  live commands need **both** clouds' credentials, because the fleet genuinely
  spans both — which is what `Keys.providers` reports, and `Infra.Cli`
  authenticates exactly the clouds a fleet declares into.

  ## Paris is the only place this fleet can be

  `in paris` below is a `Locality`, and it places *both* clouds — AWS at
  `eu-west-3`, Scaleway at `fr-par`. It is also the only locality that can be
  written here, and that is the fourth thing the type system is buying: the
  two clouds overlap in exactly one place, so `in warsaw` (Scaleway has it,
  AWS does not) and `in ireland` (the reverse) are both compile errors *for
  this fleet* while being perfectly legal for a single-cloud one. See "What
  the types rule out" below.

  ## Before applying

  - **S3 bucket names are globally unique across all of AWS.**
    `typednotes-assets` may well be taken by someone else, in which case
    creating it fails with `BucketAlreadyExists`. Change the names first; they
    are illustrative, not reserved.
  - **The Scaleway function needs its namespace to already exist.**
    `namespace' := "typednotes"` is not created by this fleet — a
    `scalewayFunction` is *placed into* an existing Serverless Functions
    namespace, and no kind here provisions one.
  - **Removing a line un-manages a resource; it does not delete it.** To
    actually remove what this created, use `destroy`, which reconciles against
    `Plan.absent` — the same keys, every one declared `.absent`. Deleting the
    `resource` lines instead removes the keys, and the buckets stay, unmanaged.
    Deletion runs in reverse, so the function goes before the bucket it reads.

  To have it refuse to run against the wrong accounts:

      export INFRA_EXPECT_AWS_ACCOUNT=<id>
      export INFRA_EXPECT_SCALEWAY_ORG=<id>
-/

open Infra.Core
open Infra.Specs

fleet crossCloud in paris where
  -- The same portable spec, declared in both clouds. `objectStore` is the
  -- common denominator: a name, versioning, tags — nothing provider-shaped.
  resource aws objectStore "typednotes-assets" as assetsAws
    { versioning := true
    , tags       := [("project", "typednotes"), ("tier", "hot")] }

  resource scaleway objectStore "typednotes-assets" as assetsScaleway
    { versioning := true
    , tags       := [("project", "typednotes"), ("tier", "hot")] }

  -- AWS-only, and deliberately so: Object Lock is an S3 concept, and
  -- `objectLock` is settable only at creation — so changing it is a REPLACE,
  -- not an UPDATE. Reaching for `s3Bucket` is how that becomes expressible,
  -- at the cost of portability, which the kind's name makes obvious.
  --
  -- `region` here is the *bucket's own* field, not the fleet's placement, and
  -- the two must agree: the backend creates the bucket at the endpoint the
  -- placement builds and then reports that region back, so a spec saying
  -- anything else diverges on a field marked `forcesReplace` and proposes a
  -- replacement that could never converge. `in paris` above is what makes
  -- `eu-west-3` the right thing to write. See `docs/providers.md`.
  resource aws s3Bucket "typednotes-archive" as archive
    { objectLock := true
    , region     := "eu-west-3" }

  -- A Scaleway function that reads the AWS bucket. `sourceBucket` has type
  -- `Option (K .aws .s3Bucket)`, so it can only ever name a bucket that this
  -- fleet actually declares, in that cloud, of that kind.
  -- The namespace is now a resource this fleet *creates*, not a string it
  -- hopes already exists. `apply` used to fail here with
  -- "no namespace named 'typednotes'"; the reference makes that unrepresentable
  -- and orders the namespace first.
  resource scaleway scalewayFunctionNamespace "typednotes" as ns
    { description := "the cross-cloud example's functions" }

  -- Scaleway spells runtimes without punctuation, so this is `python311`
  -- rather than `python3.12` — which it rejected as `invalid runtime`. The
  -- exact set is Scaleway's to define and changes with versions; if this one
  -- has aged out, the error now lists what the region does accept.
  resource scaleway scalewayFunction "reindex" as reindex
    { runtime      := "python311"
    , namespace'   := ns
    , sourceBucket := some archive }

/-! ## What the types rule out

  Each of these is a compile error, not a runtime check — so they are written
  as comments, since a file demonstrating them could not be built. The
  messages below are the real ones, copied from the compiler rather than
  paraphrased. -/

-- **Wrong cloud for the reference.** `sourceBucket` wants a key in AWS; the
-- Scaleway bucket's key is a different type, because `Key` is indexed by
-- provider as well as kind.
--
--   sourceBucket := some assetsScaleway
--
--   Application type mismatch: The argument
--     some assetsScaleway
--   has type
--     Option (keys.Key ProviderId.scaleway Kind.objectStore)
--   but is expected to have type
--     ... (Option (keys.Key ProviderId.aws Kind.s3Bucket)) ...

-- **Wrong kind for the reference**, even in the right cloud. An object-store
-- key is not an `s3Bucket` key, so pointing the function at the AWS
-- *objectStore* bucket instead of the AWS *s3Bucket* one is also rejected:
--
--   sourceBucket := some assetsAws
--
--   has type
--     Option (keys.Key ProviderId.aws Kind.objectStore)
--   but is expected to have type
--     ... (Option (keys.Key ProviderId.aws Kind.s3Bucket)) ...
--
-- Note this is the case a stringly-typed reference could not catch at all:
-- both buckets exist, both are in AWS, and the names are similar.

-- **A missing required field.** `namespace'` is `Field .required`, so it has
-- no default to fall back on and the resource is simply not fully applied.
-- Lean reports that as a function where a spec was expected — the binder
-- names the field that is missing:
--
--   resource scaleway scalewayFunction "reindex" { runtime := "python3.12" }
--
--   Type mismatch
--     fun namespace' => Build.scalewayFunction (Expr.lit "f") (Expr.lit "py") namespace'
--   has type
--     Expr ?m String → ScalewayFunctionSpec ?m Partial (Expr ?m)
--   but is expected to have type
--     SpecOf Kind.scalewayFunction keys.Key Partial (Expr keys.Key)
--
-- Less direct than "missing argument `namespace'`", and worth knowing to
-- read: a *function* where a spec belongs means a required field was left
-- out, and the lambda binder says which. This is how Lean reports any
-- partially applied named-argument call, not something the `fleet` command
-- introduces — a direct `Build.scalewayFunction` call reports the same.

-- **A place one of the two clouds is not in.** This is the cross-cloud case
-- of the placement check: the fleet uses both clouds, so `Locality.covers` has
-- to hold for both, and only Paris does.
--
--   fleet crossCloud in warsaw where …
--
--   could not synthesize default value for parameter '_h' using tactics
--   Tactic `decide` proved that the proposition
--     Assert (Locality.warsaw.covers keys)
--   is false
--
-- Written cloud by cloud instead, the same fleet is caught by the *other*
-- check — placing one cloud and forgetting the other is not a placement:
--
--   fleet crossCloud in aws "eu-west-3" where …
--
--   Tactic `decide` proved that the proposition
--     Assert (({ }.set (Region.of ProviderId.aws "eu-west-3" ⋯)).covers keys)
--   is false

-- A resource in a `(provider, kind)` pair this fleet never declared. There is
-- no key to write down, so it cannot be named at all — which is also the
-- scoping mechanism: whatever else exists in these accounts is left alone.
#guard crossCloud.keys.count .scaleway .s3Bucket = 0
#guard crossCloud.keys.count .aws .scalewayFunction = 0
#guard crossCloud.keys.count .aws .postgres = 0

/-! ## What the fleet says -/

-- Four resources, in two clouds.
#guard crossCloud.keys.count .aws .objectStore = 1
#guard crossCloud.keys.count .scaleway .objectStore = 1
#guard crossCloud.keys.count .aws .s3Bucket = 1
#guard crossCloud.keys.count .scaleway .scalewayFunction = 1

-- Genuinely both clouds, so both sets of credentials are needed here —
-- unlike a single-cloud fleet, which `Infra.Cli` authenticates one side of.
#guard crossCloud.keys.providers = [.aws, .scaleway]

-- One `in paris`, two region codes: this is what "portable placement" means,
-- and why a `Locality` is not just an alias for a region string.
#guard (crossCloud.regions.region .aws).map Region.code = some "eu-west-3"
#guard (crossCloud.regions.region .scaleway).map Region.code = some "fr-par"

-- Paris is the only locality both clouds have, so it is the only one this
-- fleet can be declared at. The two `false`s are the compile errors above,
-- evaluated instead of triggered.
#guard Locality.paris.covers crossCloud.keys = true
#guard Locality.warsaw.covers crossCloud.keys = false     -- Scaleway yes, AWS no
#guard Locality.ireland.covers crossCloud.keys = false    -- AWS yes, Scaleway no
#guard (Finite.elems (α := Locality)).filter (·.covers crossCloud.keys) = [.paris]

-- The bucket's own `region` field agrees with where the fleet places AWS.
-- They are separate mechanisms and nothing couples them, so this guard is
-- what notices if one moves without the other.
#guard (crossCloud.regions.region .aws).map Region.code = some "eu-west-3"

-- The function depends on the bucket it reads, and on nothing else.
#guard (HasDeps.deps (S := ScalewayFunctionSpec)
         (Build.scalewayFunction (K := crossCloud.keys.Key)
           (name := "reindex") (runtime := "python3.12")
           (namespace' := ns) (sourceBucket := some archive))).length = 2

def main (args : List String) : IO UInt32 := do
  Infra.Cli.run "cross-cloud" crossCloud.plan
    (selfCheck := Infra.Cli.offlinePlan crossCloud.plan
      "cross-cloud: a plan spanning AWS and Scaleway")
    (accounts := ← Infra.Cli.Accounts.fromEnv)
    (regions := crossCloud.regions) (args := args)
