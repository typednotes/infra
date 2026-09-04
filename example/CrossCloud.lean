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
      lake exe cross-cloud push --apply   # creates real resources in both

  A bare invocation is offline and free. Unlike every other example here, the
  live commands need **both** clouds' credentials, because the fleet genuinely
  spans both — which is what `Keys.providers` reports, and `Infra.Cli`
  authenticates exactly the clouds a fleet declares into.

  ## Before applying

  - **S3 bucket names are globally unique across all of AWS.**
    `typednotes-assets` may well be taken by someone else, in which case
    creating it fails with `BucketAlreadyExists`. Change the names first; they
    are illustrative, not reserved.
  - **The Scaleway function needs its namespace to already exist.**
    `namespace' := "typednotes"` is not created by this fleet — a
    `scalewayFunction` is *placed into* an existing Serverless Functions
    namespace, and no kind here provisions one.
  - **Removing a line un-manages a resource; it does not delete it.** Set its
    status to `.absent`, or delete by hand.

  To have it refuse to run against the wrong accounts:

      export INFRA_EXPECT_AWS_ACCOUNT=<id>
      export INFRA_EXPECT_SCALEWAY_ORG=<id>
-/

open Infra.Core
open Infra.Specs

fleet crossCloud where
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
  resource aws s3Bucket "typednotes-archive" as archive
    { objectLock := true
    , region     := "eu-west-3" }

  -- A Scaleway function that reads the AWS bucket. `sourceBucket` has type
  -- `Option (K .aws .s3Bucket)`, so it can only ever name a bucket that this
  -- fleet actually declares, in that cloud, of that kind.
  resource scaleway scalewayFunction "reindex" as reindex
    { runtime      := "python3.12"
    , namespace'   := "typednotes"
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

-- The function depends on the bucket it reads, and on nothing else.
#guard (HasDeps.deps (S := ScalewayFunctionSpec)
         (Build.scalewayFunction (K := crossCloud.keys.Key)
           (name := "reindex") (runtime := "python3.12")
           (namespace' := "typednotes") (sourceBucket := some archive))).length = 1

/-- What a bare invocation does: the plan, from the placeholder backends. -/
def demo : IO Unit := do
  IO.println "cross-cloud: a plan spanning AWS and Scaleway\n"
  for line in ← push Infra.Providers.all crossCloud.plan (worldOf []) {} do
    IO.println line
  IO.println "\nNote the order: the AWS bucket is created before the Scaleway"
  IO.println "function that reads it. Nothing above declares that order — it"
  IO.println "falls out of `sourceBucket` being a reference."
  IO.println "\nThat was the placeholder backend — neither cloud was contacted."
  IO.println "For the real thing: `plan`, then `push --apply`."

/-- Its own cache root: this fleet's key family is not any other's, and two
    different shapes must never be read as if they were the same. -/
def cacheRoot : System.FilePath := ".infra" / "cross-cloud"

def main (args : List String) : IO UInt32 := do
  Infra.Cli.run "cross-cloud" crossCloud.plan demo
    (accounts := ← Infra.Cli.Accounts.fromEnv) (cacheRoot := cacheRoot) (args := args)
