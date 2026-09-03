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
    typed reference, which would have to name a provider.

    Classic and serverless share one structure rather than splitting into two kinds: `instanceClass`
    picks a classic managed instance; `minCapacity`/`maxCapacity` pick a serverless one. Exactly one
    of the two should be set — `PostgresSpec.classic`/`PostgresSpec.serverless` build one shape each
    without a proof obligation, and `PostgresSpec.hasCapacityChoice` is there for anyone writing the
    raw structure literal instead. See its doc comment for why that check cannot live in the
    structure itself. -/
structure PostgresSpec (K : ProviderId → Kind → Type) (o : Type u → Type u)
    (f : Type → Type u) where
  name                 : Field .required o f String
  /-- Set for a classic managed instance; leave unset and set `minCapacity`/`maxCapacity` instead
      for a serverless one. -/
  instanceClass        : Field .optional o f String
  masterUsername       : Field .required o f String
  /-- The name of a secret holding the master password, not the password. -/
  masterPasswordSecret : Field .required o f String
  version              : Field .optional o f String
  storageGb            : Field .optional o f Nat
  /-- Serverless capacity floor, in the cloud's own capacity units (AWS Aurora Serverless v2
      ACUs; Scaleway Serverless SQL Database's own unit, unconfirmed — see `docs/providers.md`).
      Set together with `maxCapacity` for a serverless target, and leave `instanceClass` unset. -/
  minCapacity          : Field .optional o f Nat
  /-- Serverless capacity ceiling — see `minCapacity`. -/
  maxCapacity          : Field .optional o f Nat

/-- Whether an authored postgres target picked one of the two capacity shapes: a fixed
    `instanceClass`, or both `minCapacity` and `maxCapacity`. Neither being set makes the target
    unrealisable by either backend.

    This can't be a proof field on `PostgresSpec` itself: the structure is instantiated across
    both the authoring stage (`o = Partial`, where `.isKnown` makes sense) and the settled stage
    (`o = Conc`, where optionality has already been erased and there is nothing left to ask).
    A field typed to only exist at one stage doesn't typecheck, so this lives as a standalone,
    decidable `Bool`-valued function instead — usable as a `by decide` check
    (`Assert spec.hasCapacityChoice`) by anyone writing the raw structure literal, the way
    `Infra.Core.Ergonomics`'s `KeySpec.named` checks `namesNodup`. -/
def PostgresSpec.hasCapacityChoice {K : ProviderId → Kind → Type}
    (s : PostgresSpec K Partial (Expr K)) : Bool :=
  s.instanceClass.isKnown || (s.minCapacity.isKnown && s.maxCapacity.isKnown)

/-- A classic, fixed-capacity managed instance. The complement of `PostgresSpec.serverless` —
    see `hasCapacityChoice`. -/
def PostgresSpec.classic {K : ProviderId → Kind → Type}
    (name masterUsername masterPasswordSecret instanceClass : Expr K String)
    (version : Partial (Expr K String) := .unknown)
    (storageGb : Partial (Expr K Nat) := .unknown) :
    PostgresSpec K Partial (Expr K) where
  name := name
  instanceClass := .known instanceClass
  masterUsername := masterUsername
  masterPasswordSecret := masterPasswordSecret
  version := version
  storageGb := storageGb
  minCapacity := .unknown
  maxCapacity := .unknown

/-- A serverless instance: capacity bounds instead of a fixed `instanceClass`. The complement of
    `PostgresSpec.classic` — see `hasCapacityChoice`. -/
def PostgresSpec.serverless {K : ProviderId → Kind → Type}
    (name masterUsername masterPasswordSecret : Expr K String)
    (minCapacity maxCapacity : Expr K Nat)
    (version : Partial (Expr K String) := .unknown)
    (storageGb : Partial (Expr K Nat) := .unknown) :
    PostgresSpec K Partial (Expr K) where
  name := name
  instanceClass := .unknown
  masterUsername := masterUsername
  masterPasswordSecret := masterPasswordSecret
  version := version
  storageGb := storageGb
  minCapacity := .known minCapacity
  maxCapacity := .known maxCapacity

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

/-- A Scaleway Serverless Container. Like `ScalewayFunctionSpec`, provider-local because it
    references other resources — here, secrets to bind as environment variables, which the
    portable `.compute` kind forbids by design (see `ComputeSpec`'s doc comment). -/
structure ScalewayContainerSpec (K : ProviderId → Kind → Type) (o : Type u → Type u)
    (f : Type → Type u) where
  name       : Field .required o f String
  /-- Serverless Containers groups containers into a namespace, same as
      `ScalewayFunctionSpec.namespace'`. Required: this kind is Scaleway-only. -/
  namespace' : Field .required o f String
  image      : Field .required o f String
  port       : Field .optional o f Nat
  minScale   : Field .optional o f Nat
  maxScale   : Field .optional o f Nat
  memoryMb   : Field .optional o f Nat
  cpuLimit   : Field .optional o f Nat
  timeoutSec : Field .optional o f Nat
  env        : Field .optional o f (List (String × String))
  /-- Environment variables whose values come from `.secrets` resources in this fleet, rather
      than literal strings. Each pair is an env-var name and a reference to a secret. The
      real Scaleway secret-binding mechanism is unconfirmed — see `Infra/Providers/Live.lean`
      and `docs/providers.md`. -/
  secretEnv  : Field .optional o f (List (String × K .scaleway .secrets))

/-! ## Dispatch -/

/-- Total over `Kind`, so adding a kind without a spec is a compile error. -/
@[reducible] def SpecOf : Kind → SpecShape.{u}
  | .iam               => IamSpec
  | .objectStore       => ObjectStoreSpec
  | .compute           => ComputeSpec
  | .queues            => QueuesSpec
  | .secrets           => SecretsSpec
  | .imageRegistry     => ImageRegistrySpec
  | .postgres          => PostgresSpec
  | .s3Bucket          => S3BucketSpec
  | .scalewayFunction  => ScalewayFunctionSpec
  | .scalewayContainer => ScalewayContainerSpec

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

/-- `instanceClass` and the capacity fields default to `.lit ""`/`.lit 0` — unset sentinels,
    same convention as every other "said: nothing" default here. `Live.lean` routes between the
    classic and serverless backends on whether the settled `instanceClass` is empty. -/
instance : Fillable PostgresSpec where
  fill s :=
    { name                 := s.name
      instanceClass        := s.instanceClass.getD (.lit "")
      masterUsername       := s.masterUsername
      masterPasswordSecret := s.masterPasswordSecret
      version              := s.version.getD (.lit "16")
      storageGb            := s.storageGb.getD (.lit 10)
      minCapacity          := s.minCapacity.getD (.lit 0)
      maxCapacity          := s.maxCapacity.getD (.lit 0) }

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

/-- `secretEnv` defaults to `.lit []` — no secret-backed env vars — matching the
    "said: nothing" convention `sourceBucket` established above. -/
instance : Fillable ScalewayContainerSpec where
  fill s :=
    { name       := s.name
      namespace' := s.namespace'
      image      := s.image
      port       := s.port.getD (.lit 8080)
      minScale   := s.minScale.getD (.lit 0)
      maxScale   := s.maxScale.getD (.lit 1)
      memoryMb   := s.memoryMb.getD (.lit 256)
      cpuLimit   := s.cpuLimit.getD (.lit 140)
      timeoutSec := s.timeoutSec.getD (.lit 30)
      env        := s.env.getD (.lit [])
      secretEnv  := s.secretEnv.getD (.lit []) }

/-- Total over `Kind`, so a kind whose spec has no defaults cannot be forgotten. -/
@[reducible] def fillableOf : (k : Kind) → Fillable (SpecOf.{1} k)
  | .iam               => inferInstanceAs (Fillable IamSpec)
  | .objectStore       => inferInstanceAs (Fillable ObjectStoreSpec)
  | .compute           => inferInstanceAs (Fillable ComputeSpec)
  | .queues            => inferInstanceAs (Fillable QueuesSpec)
  | .secrets           => inferInstanceAs (Fillable SecretsSpec)
  | .imageRegistry     => inferInstanceAs (Fillable ImageRegistrySpec)
  | .postgres          => inferInstanceAs (Fillable PostgresSpec)
  | .s3Bucket          => inferInstanceAs (Fillable S3BucketSpec)
  | .scalewayFunction  => inferInstanceAs (Fillable ScalewayFunctionSpec)
  | .scalewayContainer => inferInstanceAs (Fillable ScalewayContainerSpec)

/-! ## Self-checks -/

section
private def NoKeys : ProviderId → Kind → Type := fun _ _ => Nothing

#guard (PostgresSpec.classic (K := NoKeys)
  (.lit "db") (.lit "admin") (.lit "master-pw") (.lit "db.t3.micro")).hasCapacityChoice
#guard (PostgresSpec.serverless (K := NoKeys)
  (.lit "db") (.lit "admin") (.lit "master-pw") (.lit 1) (.lit 4)).hasCapacityChoice
#guard ¬ ({ name := .lit "db", instanceClass := .unknown, masterUsername := .lit "admin"
            masterPasswordSecret := .lit "master-pw", version := .unknown, storageGb := .unknown
            minCapacity := .unknown, maxCapacity := .unknown } :
    PostgresSpec NoKeys Partial (Expr NoKeys)).hasCapacityChoice
end

end Infra.Specs
