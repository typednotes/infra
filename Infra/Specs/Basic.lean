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
  /-- Advisory only, and never compared.

      Choosing container images made this vestigial: Lambda with
      `PackageType=Image` has no `Runtime`, and the Scaleway counterpart is
      Serverless *Containers*, which has none either — the runtime is baked
      into the image. Kept as documentation of intent, optional so that neither
      cloud has to invent a value it cannot report. -/
  runtime    : Field .optional o f String
  /-- A container image reference.

      Required, because a function with no code is not a function — which is
      the "an unrealisable target should not be representable" rule applied to
      this kind. A container image is what keeps the kind portable: AWS Lambda
      takes it as `Code.ImageUri` with `PackageType=Image`, Scaleway Functions
      as `registry_image`. An archive would mean noticeably different things on
      the two clouds. -/
  image      : Field .required o f String
  /-- The identity the function runs as.

      AWS Lambda requires an execution role ARN; Scaleway Functions has no
      equivalent and ignores this. Optional rather than required precisely
      because it genuinely is optional across clouds — forcing a Scaleway-only
      target to invent one would make the portable spec less portable. The AWS
      backend raises a clear error naming this field if it reaches create
      without one. -/
  executionRole : Field .optional o f String
  /-- Scaleway groups containers into a namespace and requires one; AWS has no
      equivalent and ignores this. Optional for the same reason
      `executionRole` is: it genuinely is optional across clouds, and the
      backend that needs it raises a named error when it is missing. -/
  namespace'    : Field .optional o f String
  handler    : Field .optional o f String
  memoryMb   : Field .optional o f Nat
  timeoutSec : Field .optional o f Nat
  env        : Field .optional o f (List (String × String))

structure QueuesSpec (K : ProviderId → Kind → Type) (o : Type u → Type u)
    (f : Type → Type u) where
  name                : Field .required o f String
  visibilityTimeoutSec : Field .optional o f Nat

/-- A secret.

    `valueFrom` names an **environment variable**, never the value itself: a
    literal here would be a plaintext secret in the file that is meant to be
    committed. Apply reads the variable at the moment it is needed, so the
    value never enters the target, the `.infra/` cache, or any log.

    Nothing reads the value back. `read` reports only what the cloud will say
    without handing over plaintext, which means a value changed outside this
    tool is **not** detected as drift — an accepted limitation, and the price
    of never pulling secrets into the engine. The cloud's own version
    identifier is carried in `ObservedOf`, where computed state belongs. -/
structure SecretsSpec (K : ProviderId → Kind → Type) (o : Type u → Type u)
    (f : Type → Type u) where
  name      : Field .required o f String
  /-- The name of an environment variable holding the value. -/
  valueFrom : Field .required o f String

structure ImageRegistrySpec (K : ProviderId → Kind → Type) (o : Type u → Type u)
    (f : Type → Type u) where
  name          : Field .required o f String
  immutableTags : Field .optional o f Bool

/-- Managed Postgres.

    `masterPasswordSecret` names a secret in the cloud's own secret manager; it
    is **never** the password itself. Both RDS and Scaleway RDB demand master
    credentials at creation, and a password in a target file is a password in
    git. Apply reads the named secret at the moment it is needed, so the target
    stays safe to commit and the credential never reaches the `.infra/` cache
    either.

    A secret *name* is a plain `String`, so this stays portable — unlike a
    typed reference, which would have to name a provider. -/
structure PostgresSpec (K : ProviderId → Kind → Type) (o : Type u → Type u)
    (f : Type → Type u) where
  name                 : Field .required o f String
  instanceClass        : Field .required o f String
  masterUsername       : Field .required o f String
  /-- The name of a secret holding the master password, not the password. -/
  masterPasswordSecret : Field .required o f String
  version              : Field .optional o f String
  storageGb            : Field .optional o f Nat

/-! ## Provider-local kinds -/

/-- Richer than the portable `.objectStore`, and therefore not portable. Reaching for this
    kind is what makes the loss of portability visible in the type. -/
structure S3BucketSpec (K : ProviderId → Kind → Type) (o : Type u → Type u)
    (f : Type → Type u) where
  name             : Field .required o f String
  versioning       : Field .optional o f Bool
  /-- Object Lock, which only S3 has. Settable **only at creation**: changing
      it later means replacing the bucket, which is what makes this kind's
      `Mutability` table non-trivial. -/
  objectLock       : Field .optional o f Bool
  region           : Field .optional o f String

/-- `sourceBucket` is an `Option (K .aws .s3Bucket)`, not a `Partial` of one: `Partial` means
    "not yet said", `Option` means "said: nothing". Conflating them is what `Cloud.lean` §13
    warns about when it flags `.lit default` as a lie. -/
structure ScalewayFunctionSpec (K : ProviderId → Kind → Type) (o : Type u → Type u)
    (f : Type → Type u) where
  name         : Field .required o f String
  runtime      : Field .required o f String
  /-- Serverless Functions groups functions into a namespace. Required here
      rather than optional, because this kind is Scaleway-only: there is no
      other cloud for whom the field would be meaningless. -/
  namespace'   : Field .required o f String
  /-- A bucket the function reads from.

      The function is not *deployed from* this bucket — Scaleway Functions
      cannot fetch code from arbitrary S3 — it is *told about* it: the resolved
      bucket name is passed as a `SOURCE_BUCKET` environment variable. That is
      what a cross-resource reference is for, and it is why the bucket must
      exist before the function is created. -/
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
      runtime    := s.runtime.getD (.lit "")
      image      := s.image
      executionRole := s.executionRole.getD (.lit "")
      namespace'    := s.namespace'.getD (.lit "")
      handler    := s.handler.getD (.lit "main")
      memoryMb   := s.memoryMb.getD (.lit 256)
      timeoutSec := s.timeoutSec.getD (.lit 30)
      env        := s.env.getD (.lit []) }

instance : Fillable QueuesSpec where
  fill s :=
    { name := s.name, visibilityTimeoutSec := s.visibilityTimeoutSec.getD (.lit 30) }

instance : Fillable SecretsSpec where
  fill s := { name := s.name, valueFrom := s.valueFrom }

instance : Fillable ImageRegistrySpec where
  fill s := { name := s.name, immutableTags := s.immutableTags.getD (.lit false) }

instance : Fillable PostgresSpec where
  fill s :=
    { name                 := s.name
      instanceClass        := s.instanceClass
      masterUsername       := s.masterUsername
      masterPasswordSecret := s.masterPasswordSecret
      version              := s.version.getD (.lit "16")
      storageGb            := s.storageGb.getD (.lit 10) }

instance : Fillable S3BucketSpec where
  fill s :=
    { name       := s.name
      versioning := s.versioning.getD (.lit true)
      objectLock := s.objectLock.getD (.lit false)
      region     := s.region.getD (.lit "eu-west-1") }

/-- `sourceBucket` defaults to `.lit none` — "said: nothing" — rather than to a faked
    `Inhabited` witness. This is the honest fix `Cloud.lean` §13 asks for. -/
instance : Fillable ScalewayFunctionSpec where
  fill s :=
    { name         := s.name
      runtime      := s.runtime
      namespace'   := s.namespace'
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
