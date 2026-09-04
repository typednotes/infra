import Infra.Core.Spec
import Infra.Core.Coe

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

/-- Where a secret's value comes from.

    Two constructors rather than two optional fields, so "exactly one of these"
    is *structural* rather than a decidable side condition that nothing forces
    — the same reasoning that makes `PostgresSpec.classic`/`serverless` smart
    constructors preferable to `hasCapacityChoice` alone.

    Neither constructor is meant to hold a plaintext secret from the committed
    target. `fromEnv` names a variable read at apply time. `composed` carries a
    value *computed* at apply time from post-apply state — the point being that
    the target holds the function, not the result. A plaintext constant
    smuggled in as `composed "hunter2"` is representable but caught by
    `SecretsSpec.sourceIsSound`; see `docs/diff-semantics.md`'s ledger. -/
inductive SecretSource
  | fromEnv  (varName : String)
  | composed (value   : String)
  deriving DecidableEq, BEq
  -- Deliberately NOT deriving `Repr`/`ToJson`/`FromJson`: see the `Repr`
  -- instance below, and `Kind.lean` for why nothing serialises this.

/-- Redacting, exactly as `Credentials`' own `Repr` does — so a stray trace or
    error message cannot print a composed value. -/
instance : Repr SecretSource where
  reprPrec
    | .fromEnv v,  _ => f!"SecretSource.fromEnv {repr v}"
    | .composed _, _ => f!"SecretSource.composed <redacted>"

/-- A secret.

    `valueFrom` names an **environment variable**, or describes a value composed
    at apply time — never the value itself as a literal: plaintext here would be
    a secret in the file that is meant to be committed. Apply resolves it at the
    moment it is needed, so the value never enters the target, the `.infra/`
    cache, or any log.

    Nothing reads the value back. `read` reports only what the cloud will say
    without handing over plaintext, which means a value changed outside this
    tool is **not** detected as drift — an accepted limitation, and the price
    of never pulling secrets into the engine. The cloud's own version
    identifier is carried in `ObservedOf`, where computed state belongs.

    That same limitation is what makes a `composed` secret **create-only**: its
    value cannot be compared, so it is never drift, and a second apply asks for
    nothing. Rotating one is an explicit action, not a reconciliation. -/
structure SecretsSpec (K : ProviderId → Kind → Type) (o : Type u → Type u)
    (f : Type → Type u) where
  name      : Field .required o f String
  /-- An environment variable's name, or a value composed at apply time. -/
  valueFrom : Field .required o f SecretSource

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

/-- `valueFrom := fromEnv "SECRETS_MASTER_KEY"`.

    A helper rather than a bare `.fromEnv`, because dot-notation resolves
    against the *expected* type's head — which is `Expr`, not `SecretSource` —
    so `.fromEnv` alone does not elaborate under the wrapper. -/
def fromEnv {K : ProviderId → Kind → Type} (varName : String) : Expr K SecretSource :=
  .lit (.fromEnv varName)

/-- `valueFrom := composed (someExprOverPostApplyState)`.

    The argument is an `Expr`, so what the target stores is the *recipe*. Its
    references become dependency edges via `HasDeps SecretsSpec`, which is what
    orders the resources it reads from before this secret is created. -/
def composed {K : ProviderId → Kind → Type} (e : Expr K String) : Expr K SecretSource :=
  .map SecretSource.composed e

/-- Whether this secret's source is honest about where its value comes from.

    An env-var name is a literal and references nothing. A composed value must
    depend on at least one post-apply value — so a plaintext constant, whether
    written directly as `.lit (.composed "hunter2")` or laundered through
    `composed (.lit "hunter2")`, has no dependencies and is rejected.

    This is the decidable replacement for what used to be a structural
    guarantee ("no field of this spec can hold a value"). Use it fleet-wide via
    `Plan.secretsAreSound`. -/
def SecretsSpec.sourceIsSound {K : ProviderId → Kind → Type}
    (s : SecretsSpec K Partial (Expr K)) : Bool :=
  -- One scrutinee, not a pair: `asLit` answers `some` only for `.lit`, whose
  -- `deps` is `[]` by construction, so the cases that pair the two up cannot
  -- both be informative.
  match s.valueFrom.asLit with
  | some (.fromEnv _)  => true
  | some (.composed _) => false                     -- plaintext, written directly
  | none               => !s.valueFrom.deps.isEmpty -- `map`-wrapped: needs a reference

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

/-- A Serverless namespace, for either product.

    One spec shape serves both `scalewayFunctionNamespace` and
    `scalewayContainerNamespace`: the two are different *kinds*, because they
    are different products and must not be confused for one another, but they
    are configured identically. `SpecOf` maps both to this, so `Fillable` and
    `HasDeps` are written once. -/
structure ScalewayNamespaceSpec (K : ProviderId → Kind → Type) (o : Type u → Type u)
    (f : Type → Type u) where
  name        : Field .required o f String
  description : Field .optional o f String

/-- `sourceBucket` is an `Option (K .aws .s3Bucket)`, not a `Partial` of one: `Partial` means
    "not yet said", `Option` means "said: nothing". Conflating them is what `Cloud.lean` §13
    warns about when it flags `.lit default` as a lie. -/
structure ScalewayFunctionSpec (K : ProviderId → Kind → Type) (o : Type u → Type u)
    (f : Type → Type u) where
  name         : Field .required o f String
  runtime      : Field .required o f String
  /-- The namespace this function is placed into — a *reference*, not a name.

      Serverless Functions requires one, and it must already exist, so a bare
      string meant a misspelling surfaced at apply time as
      "no namespace named 'typndotes'". As a reference into this very fleet it
      cannot be misspelled, cannot dangle, and orders the namespace first. -/
  namespace'   : Field .required o f (K .scaleway .scalewayFunctionNamespace)
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
  /-- The namespace this container is placed into — a reference, for the same
      reason as `ScalewayFunctionSpec.namespace'`, and to a *containers*
      namespace specifically: the two products are separate kinds, so this
      cannot accidentally name a functions namespace. -/
  namespace' : Field .required o f (K .scaleway .scalewayContainerNamespace)
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

/-- An EC2 security group. AWS-only: security groups are a VPC concept with no
    Scaleway counterpart, so this is a provider-local kind.

    `description` is required because `CreateSecurityGroup` demands one, and it
    cannot be changed afterwards. -/
structure SecurityGroupSpec (K : ProviderId → Kind → Type) (o : Type u → Type u)
    (f : Type → Type u) where
  name        : Field .required o f String
  description : Field .required o f String
  /-- Inbound TCP rules, as `(port, CIDR)`. Only TCP, and only single ports —
      enough to be useful and honest about what the backend actually sends;
      anything richer belongs in a future revision rather than being implied
      by a field that is only half-supported. -/
  ingress     : Field .optional o f (List (Nat × String))

/-- An EC2 instance. AWS-only, and the *reason* `compute` cannot cover it:
    `compute` is deliberately serverless-shaped, because a required network
    reference would make that kind undeployable on serverless functions (see
    `docs/architecture.md`).

    **This is the only spec in the library with a required reference**, and it
    is the interesting part: an instance with no security group is not a thing
    this tool can be asked for. There is no `Option`, no default, and no
    validation pass — the structure literal is incomplete without one, so the
    unrealisable target is rejected where it is written.

    `name` is the instance's `Name` tag, not an instance id. An id is assigned
    at launch, so it could never be a fleet key; the tag is chosen by whoever
    declares the instance, which is what `Keys.name` needs. See
    `AwsInstanceObserved`. -/
structure AwsInstanceSpec (K : ProviderId → Kind → Type) (o : Type u → Type u)
    (f : Type → Type u) where
  name          : Field .required o f String
  /-- The AMI to launch. Immutable: changing it replaces the instance. -/
  imageId       : Field .required o f String
  instanceType  : Field .required o f String
  /-- The security group this instance sits in — required, and a reference
      into this very fleet, so it can neither be omitted nor dangle. -/
  securityGroup : Field .required o f (K .aws .securityGroup)
  /-- An existing EC2 key pair. Optional: an instance can launch without SSH
      access, and this tool does not create key pairs. -/
  keyName       : Field .optional o f String
  subnetId      : Field .optional o f String

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
  | .securityGroup     => SecurityGroupSpec
  | .awsInstance       => AwsInstanceSpec
  | .scalewayFunctionNamespace  => ScalewayNamespaceSpec
  | .scalewayFunction  => ScalewayFunctionSpec
  | .scalewayContainerNamespace => ScalewayNamespaceSpec
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

/-- `ingress := []` is the safe default: a group that lets nothing in. -/
instance : Fillable SecurityGroupSpec where
  fill s :=
    { name        := s.name
      description := s.description
      ingress     := s.ingress.getD (.lit []) }

/-- Note what has no default: `securityGroup`. A required field never reaches
    `Fillable`, which is what makes the existence of this instance a
    certificate that every well-typed instance target is launchable. -/
instance : Fillable AwsInstanceSpec where
  fill s :=
    { name          := s.name
      imageId       := s.imageId
      instanceType  := s.instanceType
      securityGroup := s.securityGroup
      keyName       := s.keyName.getD (.lit "")
      subnetId      := s.subnetId.getD (.lit "") }

/-- Serves both namespace kinds. -/
instance : Fillable ScalewayNamespaceSpec where
  fill s := { name := s.name, description := s.description.getD (.lit "") }

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
  | .securityGroup     => inferInstanceAs (Fillable SecurityGroupSpec)
  | .awsInstance       => inferInstanceAs (Fillable AwsInstanceSpec)
  | .scalewayFunctionNamespace  => inferInstanceAs (Fillable ScalewayNamespaceSpec)
  | .scalewayFunction  => inferInstanceAs (Fillable ScalewayFunctionSpec)
  | .scalewayContainerNamespace => inferInstanceAs (Fillable ScalewayNamespaceSpec)
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

/-! ### Authoring a field without naming its wrappers

  `Infra.Core.Coe` lets a bare value stand for `.lit v` on a required field and
  for `.known (.lit v)` on an optional one. These check the *result*, not just
  that it elaborates: each coerced field must be indistinguishable from the
  explicit form it replaces. `String`, `Bool`, a list and a numeral are all
  covered, because numerals reach the field by a different route (`OfNat`,
  which Lean tries before any coercion) than everything else. -/

private def coerced : ObjectStoreSpec NoKeys Partial (Expr NoKeys) where
  name       := "assets"
  versioning := true
  tags       := [("team", "infra")]

#guard (coerced.name matches .lit "assets")
#guard (coerced.versioning matches .known (.lit true))
#guard (coerced.tags matches .known (.lit [("team", "infra")]))

private def coercedNumeral : QueuesSpec NoKeys Partial (Expr NoKeys) where
  name                 := "infra-example"
  visibilityTimeoutSec := 30

#guard (coercedNumeral.visibilityTimeoutSec matches .known (.lit 30))

/-- `.unknown` deliberately has no coercion: "not specifying this" stays
    visible, and must still be writable alongside coerced fields. -/
private def coercedWithHole : ObjectStoreSpec NoKeys Partial (Expr NoKeys) where
  name       := "cold"
  versioning := .unknown
  tags       := [("team", "infra")]

#guard (coercedWithHole.versioning matches .unknown)
end

end Infra.Specs
