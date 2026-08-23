import Infra.Core.Spec

/-
  One spec per `Kind`.

  **Portable** specs (the first seven) are the common denominator every provider can honour, so
  they carry no cross-resource references at all: a reference has type `K p k` and therefore
  names a provider, which would tie the spec to one cloud. `Field .required` is the other place
  portability dies — a required field no provider-in-general can satisfy makes the kind
  undeployable — so required is used sparingly and only for genuinely universal fields.

  **Provider-local** specs (the last two) are the escape hatch: richer, and free to reference
  other resources. `ScalewayFunctionSpec.sourceBucket` deliberately points at an AWS bucket, to
  show that references may cross clouds within one `Plan`.
-/

namespace Infra.Specs

open Infra.Core

universe u

/-! ## Portable kinds -/

structure IamSpec (K : ProviderId → Kind → Type) (o : Type u → Type u) (f : Type → Type u) where
  name     : Field .required o f String
  policies : Field .optional o f (List String)

structure ObjectStoreSpec (K : ProviderId → Kind → Type) (o : Type u → Type u)
    (f : Type → Type u) where
  name       : Field .required o f String
  versioning : Field .optional o f Bool
  tags       : Field .optional o f (List (String × String))

/-- Serverless-shaped on purpose. `Cloud.lean`'s own `ComputeSpec` is EC2-shaped — a required
    `subnet` reference — which would make this kind undeployable on Scaleway serverless
    functions. `docs/architecture.md` emphasises serverless compute, so that is what the
    portable kind means; VM-shaped compute belongs on a provider-local kind. -/
structure ComputeSpec (K : ProviderId → Kind → Type) (o : Type u → Type u)
    (f : Type → Type u) where
  name       : Field .required o f String
  runtime    : Field .required o f String
  handler    : Field .optional o f String
  memoryMb   : Field .optional o f Nat
  timeoutSec : Field .optional o f Nat
  env        : Field .optional o f (List (String × String))

structure QueuesSpec (K : ProviderId → Kind → Type) (o : Type u → Type u)
    (f : Type → Type u) where
  name                : Field .required o f String
  visibilityTimeoutSec : Field .optional o f Nat

structure SecretsSpec (K : ProviderId → Kind → Type) (o : Type u → Type u)
    (f : Type → Type u) where
  name  : Field .required o f String
  value : Field .required o f String

structure ImageRegistrySpec (K : ProviderId → Kind → Type) (o : Type u → Type u)
    (f : Type → Type u) where
  name          : Field .required o f String
  immutableTags : Field .optional o f Bool

structure PostgresSpec (K : ProviderId → Kind → Type) (o : Type u → Type u)
    (f : Type → Type u) where
  name      : Field .required o f String
  version   : Field .optional o f String
  storageGb : Field .optional o f Nat

/-! ## Provider-local kinds -/

/-- Richer than the portable `.objectStore`, and therefore not portable. Reaching for this
    kind is what makes the loss of portability visible in the type. -/
structure S3BucketSpec (K : ProviderId → Kind → Type) (o : Type u → Type u)
    (f : Type → Type u) where
  name         : Field .required o f String
  versioning   : Field .optional o f Bool
  storageClass : Field .optional o f String
  region       : Field .optional o f String

/-- `sourceBucket` is an `Option (K .aws .s3Bucket)`, not a `Partial` of one: `Partial` means
    "not yet said", `Option` means "said: nothing". Conflating them is what `Cloud.lean` §13
    warns about when it flags `.lit default` as a lie. -/
structure ScalewayFunctionSpec (K : ProviderId → Kind → Type) (o : Type u → Type u)
    (f : Type → Type u) where
  name         : Field .required o f String
  runtime      : Field .required o f String
  sourceBucket : Field .optional o f (Option (K .aws .s3Bucket))

/-! ## Dispatch -/

/-- Total over `Kind`, so adding a kind without a spec is a compile error. -/
@[reducible] def SpecOf : Kind → SpecShape.{u}
  | .iam              => IamSpec
  | .objectStore      => ObjectStoreSpec
  | .compute          => ComputeSpec
  | .queues           => QueuesSpec
  | .secrets          => SecretsSpec
  | .imageRegistry    => ImageRegistrySpec
  | .postgres         => PostgresSpec
  | .s3Bucket         => S3BucketSpec
  | .scalewayFunction => ScalewayFunctionSpec

/-! ## Realisability -/

/-- Every optional hole has a default.

    The *existence of an instance* is the compile-time certificate that any well-typed target
    of this kind can actually be created. Add a field with no sensible default and `fill` stops
    typechecking: the unrealisable target is caught at the definition site, not at apply
    time. -/
class Fillable (S : SpecShape.{1}) where
  fill : {K : ProviderId → Kind → Type} → S K Partial (Expr K) → S K Conc (Expr K)

instance : Fillable IamSpec where
  fill s := { name := s.name, policies := s.policies.getD (.lit []) }

instance : Fillable ObjectStoreSpec where
  fill s :=
    { name       := s.name
      versioning := s.versioning.getD (.lit true)
      tags       := s.tags.getD (.lit []) }

instance : Fillable ComputeSpec where
  fill s :=
    { name       := s.name
      runtime    := s.runtime
      handler    := s.handler.getD (.lit "main")
      memoryMb   := s.memoryMb.getD (.lit 256)
      timeoutSec := s.timeoutSec.getD (.lit 30)
      env        := s.env.getD (.lit []) }

instance : Fillable QueuesSpec where
  fill s :=
    { name := s.name, visibilityTimeoutSec := s.visibilityTimeoutSec.getD (.lit 30) }

instance : Fillable SecretsSpec where
  fill s := { name := s.name, value := s.value }

instance : Fillable ImageRegistrySpec where
  fill s := { name := s.name, immutableTags := s.immutableTags.getD (.lit false) }

instance : Fillable PostgresSpec where
  fill s :=
    { name      := s.name
      version   := s.version.getD (.lit "16")
      storageGb := s.storageGb.getD (.lit 10) }

instance : Fillable S3BucketSpec where
  fill s :=
    { name         := s.name
      versioning   := s.versioning.getD (.lit true)
      storageClass := s.storageClass.getD (.lit "STANDARD")
      region       := s.region.getD (.lit "eu-west-1") }

/-- `sourceBucket` defaults to `.lit none` — "said: nothing" — rather than to a faked
    `Inhabited` witness. This is the honest fix `Cloud.lean` §13 asks for. -/
instance : Fillable ScalewayFunctionSpec where
  fill s :=
    { name         := s.name
      runtime      := s.runtime
      sourceBucket := s.sourceBucket.getD (.lit none) }

/-- Total over `Kind`, so a kind whose spec has no defaults cannot be forgotten. -/
@[reducible] def fillableOf : (k : Kind) → Fillable (SpecOf.{1} k)
  | .iam              => inferInstanceAs (Fillable IamSpec)
  | .objectStore      => inferInstanceAs (Fillable ObjectStoreSpec)
  | .compute          => inferInstanceAs (Fillable ComputeSpec)
  | .queues           => inferInstanceAs (Fillable QueuesSpec)
  | .secrets          => inferInstanceAs (Fillable SecretsSpec)
  | .imageRegistry    => inferInstanceAs (Fillable ImageRegistrySpec)
  | .postgres         => inferInstanceAs (Fillable PostgresSpec)
  | .s3Bucket         => inferInstanceAs (Fillable S3BucketSpec)
  | .scalewayFunction => inferInstanceAs (Fillable ScalewayFunctionSpec)

end Infra.Specs
