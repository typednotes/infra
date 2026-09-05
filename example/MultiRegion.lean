import Infra

/-!
  # Example: one fleet, four regions

  Placement started per *cloud* — one region each, and a fleet spanning two
  regions of the same cloud was not expressible. It is now per *resource*, and
  the syntax for it is a block that scopes like a `with` in Python: it applies
  to what is nested inside it and to nothing else.

      lake exe multi-region                # offline: the plan, from placeholders
      lake exe multi-region plan           # reads BOTH accounts, in four regions
      lake exe multi-region apply          # creates real buckets in four regions
      lake exe multi-region destroy        # delete them again

  ## What the blocks do

  Three things are worth noticing in the declaration below, because each is a
  thing a region *string* on each resource could not do.

  1. **A locality resolves per cloud.** `in paris` at the top places AWS at
     `eu-west-3` and Scaleway at `fr-par` — one name, two codes, and the right
     one reaches each backend.
  2. **A block overrides only what is inside it.** `eu-assets` has no block
     around it, so it takes the fleet's Paris; `us-east-assets` sits in
     `in nVirginia` and does not.
  3. **An impossible placement does not elaborate.** Scaleway has no Oregon
     region, so a Scaleway resource inside `in oregon` is a compile error —
     the same `Locality`-covers check the whole-fleet `in` clause uses, applied
     one resource at a time.

  ## What it costs to pull

  Listing is per region, so a fleet in four regions lists more than a fleet in
  one. The set is derived from the fleet's own declarations rather than
  configured: `Regions.used` returns the distinct regions of each
  `(provider, kind)` bucket, so this fleet makes three AWS `s3Bucket` listings
  and one Scaleway `objectStore` listing per region it names — and never a
  listing in a region it declares nothing in. A single-region fleet lists once,
  exactly as before.

  The matching that follows is what makes this safe: a listing from
  `us-east-1` is compared only against the slots placed in `us-east-1`. Without
  that, a bucket named `assets` in one region would satisfy a key placed in
  another and the engine would believe it already existed.

  ## Before applying

  **S3 bucket names are globally unique across all of AWS**, so the names below
  are almost certainly taken. Change them before applying. `destroy` is how to
  remove what this creates; deleting the lines un-manages them instead.

      export INFRA_EXPECT_AWS_ACCOUNT=<id>
      export INFRA_EXPECT_SCALEWAY_ORG=<id>
-/

open Infra.Core
open Infra.Specs

fleet spread in paris where
  provider aws where
    -- No block: takes the fleet's own placement, which for AWS is `eu-west-3`.
    --
    -- `region` is written out on every `s3Bucket` here, and it must agree with
    -- the block around it. That is a wart, not a feature — see "The `region`
    -- field is a trap" below. Leaving it off does not mean "wherever the fleet
    -- is"; it means `eu-west-1`, and the plan then proposes a replacement that
    -- can never converge.
    resource s3Bucket "typednotes-eu-assets"
      { versioning := true, region := "eu-west-3" }

    in nVirginia where
      resource s3Bucket "typednotes-us-east-assets"
        { versioning := true, region := "us-east-1" }
      resource objectStore "typednotes-us-east-logs" { versioning := true }

    in oregon where
      resource s3Bucket "typednotes-us-west-assets"
        { versioning := true, region := "us-west-2" }

  provider scaleway where
    resource objectStore "typednotes-eu-cache" { versioning := true }

    in amsterdam where
      resource objectStore "typednotes-nl-cache" { versioning := true }

/-! ## What the placement came out as

  `codeFor` is what `Infra.Cli` asks for each slot when it builds that slot's
  backend, so these are the regions the fleet will actually be built in. -/

-- One locality, two clouds, two codes.
#guard spread.regions.codeFor .aws .s3Bucket "typednotes-eu-assets" = some "eu-west-3"
#guard spread.regions.codeFor .scaleway .objectStore "typednotes-eu-cache" = some "fr-par"

-- A block overrides, per resource, and reaches every resource inside it.
#guard spread.regions.codeFor .aws .s3Bucket "typednotes-us-east-assets" = some "us-east-1"
#guard spread.regions.codeFor .aws .objectStore "typednotes-us-east-logs" = some "us-east-1"
#guard spread.regions.codeFor .aws .s3Bucket "typednotes-us-west-assets" = some "us-west-2"
#guard spread.regions.codeFor .scaleway .objectStore "typednotes-nl-cache" = some "nl-ams"

-- Every resource is placed, so neither cloud's credentials need a region at
-- all: `Infra.Cli.liveFor` only calls `requireRegion` for an unplaced slot.
#guard spread.regions.covers spread.keys

/-! ## What it will cost to pull

  One listing per entry here. Derived, not configured — which is why it cannot
  drift from the declaration above. -/

#guard spread.regions.used spread.keys .aws .s3Bucket ""
     = ["eu-west-3", "us-east-1", "us-west-2"]
#guard spread.regions.used spread.keys .aws .objectStore "" = ["us-east-1"]
#guard spread.regions.used spread.keys .scaleway .objectStore "" = ["fr-par", "nl-ams"]

/-! ## The `region` field is a trap, and this is the guard against it

  `S3BucketSpec.region` predates fleet placement and does **not** place
  anything: `Live.lean` creates the bucket at the endpoint the placement builds
  and reports that region back, so the field is only ever *compared* — on a
  `forcesReplace` row, because a bucket cannot move.

  `Fillable` fills an unwritten one with `.lit "eu-west-1"`. So a bucket
  declared without a region, in a fleet placed anywhere else, diverges on an
  immutable field; the replacement recreates it at the endpoint's region, which
  is the region it already had, and the next plan proposes the same
  replacement. It never converges, and `REPLACE` is `DeleteBucket` first.

  This example had exactly that bug: all three buckets replaced forever. The
  guard below is the property that was violated — **a converged fleet has
  nothing to do** — and it is worth more than the three `region :=` lines,
  because it fails if either the placement or the field moves without the
  other. See `docs/diff-semantics.md`'s soft spots. -/

private def bucketSighting (name region : String) : Sighting .s3Bucket :=
  { observed := { handle := ⟨name⟩, arn := s!"arn:aws:s3:::{name}", region }
    reported := { name, versioning := .known true
                  objectLock := .known false, region := .known region } }

private def storeSighting (name : String) : Sighting .objectStore :=
  { observed := { handle := ⟨name⟩, url := s!"https://{name}" }
    reported := { name, versioning := .known true, tags := .unknown } }

/-- The fleet exactly as `apply` leaves it: every bucket in the region its
    block places it in, which is the region `read` reports back. -/
private def applied : World spread.keys :=
  worldOf
    [ ⟨.aws, .s3Bucket, NamedKey.of spread.names.aws.s3Bucket "typednotes-eu-assets",
        bucketSighting "typednotes-eu-assets" "eu-west-3"⟩
    , ⟨.aws, .s3Bucket, NamedKey.of spread.names.aws.s3Bucket "typednotes-us-east-assets",
        bucketSighting "typednotes-us-east-assets" "us-east-1"⟩
    , ⟨.aws, .s3Bucket, NamedKey.of spread.names.aws.s3Bucket "typednotes-us-west-assets",
        bucketSighting "typednotes-us-west-assets" "us-west-2"⟩
    , ⟨.aws, .objectStore, NamedKey.of spread.names.aws.objectStore "typednotes-us-east-logs",
        storeSighting "typednotes-us-east-logs"⟩
    , ⟨.scaleway, .objectStore,
        NamedKey.of spread.names.scaleway.objectStore "typednotes-eu-cache",
        storeSighting "typednotes-eu-cache"⟩
    , ⟨.scaleway, .objectStore,
        NamedKey.of spread.names.scaleway.objectStore "typednotes-nl-cache",
        storeSighting "typednotes-nl-cache"⟩ ]

-- **Applying twice changes nothing.** This is the guard that was failing:
-- before the `region :=` lines above, all three buckets proposed a REPLACE
-- against a fleet that was already exactly right.
#guard actions spread.plan applied = []

/-! ## What cannot be written

  The message is the compiler's own, from actually writing the broken version. -/

-- **A cloud that is not in the place.** Scaleway has no Oregon region, so this
-- is rejected where it is written rather than at the API:
--
--   provider scaleway where
--     in oregon where
--       resource objectStore "x" { versioning := true }
--
--   could not synthesize default value for parameter 'h' using tactics
--   Tactic `decide` proved that the proposition
--     Assert (Locality.oregon.code ProviderId.scaleway).isSome
--   is false

-- Scaleway is in four places and none of them is Oregon; AWS is in Oregon and
-- not in Amsterdam. The blocks above are exactly the legal half of this.
#guard (Locality.oregon.code .scaleway).isSome = false
#guard (Locality.amsterdam.code .aws).isSome = false
#guard (Locality.oregon.code .aws) = some "us-west-2"
#guard (Locality.amsterdam.code .scaleway) = some "nl-ams"

/-! ## What the fleet says -/

#guard spread.keys.count .aws .s3Bucket = 3
#guard spread.keys.count .aws .objectStore = 1
#guard spread.keys.count .scaleway .objectStore = 2
#guard spread.keys.providers = [.aws, .scaleway]

-- Six resources, six creates.
#guard (actions spread.plan (worldOf [])).length = 6

def main (args : List String) : IO UInt32 := do
  Infra.Cli.run "multi-region" spread.plan
    (selfCheck := Infra.Cli.offlinePlan spread.plan
      "multi-region: six buckets across Paris, Amsterdam, N. Virginia and Oregon")
    (accounts := ← Infra.Cli.Accounts.fromEnv)
    (regions := spread.regions) (args := args)
