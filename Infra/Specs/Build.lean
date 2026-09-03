import Infra.Specs.Basic

/-
  One builder per `Kind`, so an author names only the fields they mean.

  A spec structure cannot carry Lean field defaults: the same structure is
  instantiated at `o = Partial` (authoring) and `o = Conc` (settled), and a
  `:= .unknown` default would not typecheck at the latter. So the defaults
  live here instead, as ordinary optional *arguments* — the mechanism
  `PostgresSpec.classic`/`serverless` already used.

  Combined with `Infra.Core.Coe`'s wrapper coercions, authoring a resource
  reaches about the density of an HCL block, with no metaprogramming and
  ordinary Lean error messages:

      Build.scalewayContainer (name := "secrets-server") (namespace' := "typednotes")
        (image := "rg.fr-par.scw.cloud/typednotes/secrets-server:latest") (port := 8200)

  A misspelled field gives ``Invalid argument name `nmae` for function
  `Build.scalewayContainer` `` with a did-you-mean diff; a wrong-typed value
  gives an ordinary type mismatch at the offending token; an omitted
  *required* field is a missing-argument error naming the function. Every
  field is a named parameter, so order never matters.

  Required fields deliberately have no defaults — that is what keeps "a target
  that cannot be created because a mandatory field is missing" a compile
  error, per `Infra.Core.Field`.

  ## Naming

  Each builder is named exactly after its `Kind` constructor. `Infra.Core.Declare`'s
  `fleet` command relies on that to find the builder for a declared resource,
  so renaming one breaks the macro. `buildersAreTotal` below is what makes a
  newly added `Kind` fail here rather than silently lack a builder.
-/

namespace Infra.Specs.Build

open Infra.Core

variable {K : ProviderId → Kind → Type}

def iam (name : Expr K String)
    (policies : Partial (Expr K (List String)) := .unknown) :
    IamSpec K Partial (Expr K) :=
  { name, policies }

def objectStore (name : Expr K String)
    (versioning : Partial (Expr K Bool) := .unknown)
    (tags : Partial (Expr K (List (String × String))) := .unknown) :
    ObjectStoreSpec K Partial (Expr K) :=
  { name, versioning, tags }

def compute (name : Expr K String) (image : Expr K String)
    (runtime : Partial (Expr K String) := .unknown)
    (executionRole : Partial (Expr K String) := .unknown)
    (namespace' : Partial (Expr K String) := .unknown)
    (handler : Partial (Expr K String) := .unknown)
    (memoryMb : Partial (Expr K Nat) := .unknown)
    (timeoutSec : Partial (Expr K Nat) := .unknown)
    (env : Partial (Expr K (List (String × String))) := .unknown) :
    ComputeSpec K Partial (Expr K) :=
  { name, runtime, image, executionRole, namespace', handler, memoryMb, timeoutSec, env }

def queues (name : Expr K String)
    (visibilityTimeoutSec : Partial (Expr K Nat) := .unknown) :
    QueuesSpec K Partial (Expr K) :=
  { name, visibilityTimeoutSec }

/-- `valueFrom` takes a `SecretSource`, built with `fromEnv` or `composed` —
    never a plaintext literal. See `SecretsSpec.sourceIsSound`. -/
def secrets (name : Expr K String) (valueFrom : Expr K SecretSource) :
    SecretsSpec K Partial (Expr K) :=
  { name, valueFrom }

def imageRegistry (name : Expr K String)
    (immutableTags : Partial (Expr K Bool) := .unknown) :
    ImageRegistrySpec K Partial (Expr K) :=
  { name, immutableTags }

/-- Serverless by default, because that is what this project targets; pass
    `instanceClass` instead of the capacity bounds for a classic instance.

    Both shapes delegate to the existing smart constructors, so "exactly one
    of `instanceClass` or the capacity pair" stays structural rather than
    becoming a proof obligation on this builder — an `Assert` auto-param here
    was tried and rejected, because it reports a confusing second error
    whenever any *other* argument fails to elaborate. -/
def postgres (name : Expr K String) (masterUsername : Expr K String)
    (masterPasswordSecret : Expr K String)
    (minCapacity : Expr K Nat) (maxCapacity : Expr K Nat)
    (version : Partial (Expr K String) := .unknown)
    (storageGb : Partial (Expr K Nat) := .unknown) :
    PostgresSpec K Partial (Expr K) :=
  PostgresSpec.serverless name masterUsername masterPasswordSecret
    minCapacity maxCapacity version storageGb

/-- A classic, fixed-capacity managed instance. Named apart from `postgres`
    because the two capacity shapes are genuinely different targets. -/
def postgresClassic (name : Expr K String) (masterUsername : Expr K String)
    (masterPasswordSecret : Expr K String) (instanceClass : Expr K String)
    (version : Partial (Expr K String) := .unknown)
    (storageGb : Partial (Expr K Nat) := .unknown) :
    PostgresSpec K Partial (Expr K) :=
  PostgresSpec.classic name masterUsername masterPasswordSecret instanceClass
    version storageGb

def s3Bucket (name : Expr K String)
    (versioning : Partial (Expr K Bool) := .unknown)
    (objectLock : Partial (Expr K Bool) := .unknown)
    (region : Partial (Expr K String) := .unknown) :
    S3BucketSpec K Partial (Expr K) :=
  { name, versioning, objectLock, region }

def scalewayFunction (name : Expr K String) (runtime : Expr K String)
    (namespace' : Expr K String)
    (sourceBucket : Partial (Expr K (Option (K .aws .s3Bucket))) := .unknown) :
    ScalewayFunctionSpec K Partial (Expr K) :=
  { name, runtime, namespace', sourceBucket }

def scalewayContainer (name : Expr K String) (namespace' : Expr K String)
    (image : Expr K String)
    (port : Partial (Expr K Nat) := .unknown)
    (minScale : Partial (Expr K Nat) := .unknown)
    (maxScale : Partial (Expr K Nat) := .unknown)
    (memoryMb : Partial (Expr K Nat) := .unknown)
    (cpuLimit : Partial (Expr K Nat) := .unknown)
    (timeoutSec : Partial (Expr K Nat) := .unknown)
    (env : Partial (Expr K (List (String × String))) := .unknown)
    (secretEnv : Partial (Expr K (List (String × K .scaleway .secrets))) := .unknown) :
    ScalewayContainerSpec K Partial (Expr K) :=
  { name, namespace', image, port, minScale, maxScale, memoryMb, cpuLimit, timeoutSec,
    env, secretEnv }

/-- Total over `Kind`, so adding one fails *here* rather than leaving it with
    no builder and `Infra.Core.Declare`'s `fleet` command unable to name it.

    Ten separate `def`s cannot be checked for completeness the way `fillableOf`
    is; this restores that, cheaply, by forcing each builder to be mentioned. -/
@[reducible] def buildersAreTotal : Kind → Unit
  | .iam               => let _ := @iam; ()
  | .objectStore       => let _ := @objectStore; ()
  | .compute           => let _ := @compute; ()
  | .queues            => let _ := @queues; ()
  | .secrets           => let _ := @secrets; ()
  | .imageRegistry     => let _ := @imageRegistry; ()
  | .postgres          => let _ := @postgres; ()
  | .s3Bucket          => let _ := @s3Bucket; ()
  | .scalewayFunction  => let _ := @scalewayFunction; ()
  | .scalewayContainer => let _ := @scalewayContainer; ()

end Infra.Specs.Build
