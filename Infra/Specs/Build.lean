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

def securityGroup (name : Expr K String) (description : Expr K String)
    (ingress : Partial (Expr K (List (Nat × String))) := .unknown) :
    SecurityGroupSpec K Partial (Expr K) :=
  { name, description, ingress }

/-- Note that `securityGroup` has no default: it is required, so an instance
    cannot be built without naming one. That is the whole point of the kind —
    see `AwsInstanceSpec`. -/
def awsInstance (name : Expr K String) (imageId : Expr K String)
    (instanceType : Expr K String) (securityGroup : Expr K (K .aws .securityGroup))
    (keyName : Partial (Expr K String) := .unknown)
    (subnetId : Partial (Expr K String) := .unknown) :
    AwsInstanceSpec K Partial (Expr K) :=
  { name, imageId, instanceType, securityGroup, keyName, subnetId }

/-- Serves both namespace kinds; the expected return type picks which. -/
def scalewayFunctionNamespace (name : Expr K String)
    (description : Partial (Expr K String) := .unknown) :
    ScalewayNamespaceSpec K Partial (Expr K) :=
  { name, description }

def scalewayContainerNamespace (name : Expr K String)
    (description : Partial (Expr K String) := .unknown) :
    ScalewayNamespaceSpec K Partial (Expr K) :=
  { name, description }

def scalewayFunction (name : Expr K String) (runtime : Expr K String)
    (namespace' : Expr K (K .scaleway .scalewayFunctionNamespace))
    (sourceBucket : Partial (Expr K (Option (K .aws .s3Bucket))) := .unknown) :
    ScalewayFunctionSpec K Partial (Expr K) :=
  { name, runtime, namespace', sourceBucket }

def scalewayContainer (name : Expr K String)
    (namespace' : Expr K (K .scaleway .scalewayContainerNamespace))
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

/-- Total over `Kind`, and checking the *correspondence* rather than just that
    the names exist.

    Each branch ascribes the builder's result type, so renaming a builder, or
    changing which kind's spec it returns, fails here — a bare `let _ := @iam`
    would only have asserted that something called `iam` was in scope. That
    matters because `Infra.Core.Declare`'s `fleet` command resolves
    `Infra.Specs.Build ++ k.getId` by name: without this, a rename would break
    every `fleet` declaration in every consumer repo with an unknown-identifier
    error from inside a macro expansion.

    Ten separate `def`s cannot be a `Kind`-indexed table the way `fillableOf`
    is — their arities differ — so this is the cheap substitute. -/
@[reducible] def buildersAreTotal : Kind → Unit
  | .iam               => let _ : ∀ {K}, Expr K String → _ → IamSpec K Partial (Expr K) :=
                            @iam; ()
  | .objectStore       => let _ : ∀ {K}, Expr K String → _ → _ →
                            ObjectStoreSpec K Partial (Expr K) := @objectStore; ()
  | .compute           => let _ : ∀ {K}, Expr K String → Expr K String → _ → _ → _ → _ → _ →
                            _ → _ → ComputeSpec K Partial (Expr K) := @compute; ()
  | .queues            => let _ : ∀ {K}, Expr K String → _ → QueuesSpec K Partial (Expr K) :=
                            @queues; ()
  | .secrets           => let _ : ∀ {K}, Expr K String → Expr K SecretSource →
                            SecretsSpec K Partial (Expr K) := @secrets; ()
  | .imageRegistry     => let _ : ∀ {K}, Expr K String → _ →
                            ImageRegistrySpec K Partial (Expr K) := @imageRegistry; ()
  | .postgres          => let _ : ∀ {K}, Expr K String → Expr K String → Expr K String →
                            Expr K Nat → Expr K Nat → _ → _ →
                            PostgresSpec K Partial (Expr K) := @postgres; ()
  | .s3Bucket          => let _ : ∀ {K}, Expr K String → _ → _ → _ →
                            S3BucketSpec K Partial (Expr K) := @s3Bucket; ()
  | .securityGroup     => let _ : ∀ {K}, Expr K String → Expr K String → _ →
                            SecurityGroupSpec K Partial (Expr K) := @securityGroup; ()
  | .awsInstance       => let _ : ∀ {K}, Expr K String → Expr K String → Expr K String →
                            Expr K (K .aws .securityGroup) → _ → _ →
                            AwsInstanceSpec K Partial (Expr K) := @awsInstance; ()
  | .scalewayFunctionNamespace  =>
      let _ : ∀ {K}, Expr K String → _ → ScalewayNamespaceSpec K Partial (Expr K) :=
        @scalewayFunctionNamespace; ()
  | .scalewayContainerNamespace =>
      let _ : ∀ {K}, Expr K String → _ → ScalewayNamespaceSpec K Partial (Expr K) :=
        @scalewayContainerNamespace; ()
  | .scalewayFunction  => let _ : ∀ {K}, Expr K String → Expr K String →
                            Expr K (K .scaleway .scalewayFunctionNamespace) → _ →
                            ScalewayFunctionSpec K Partial (Expr K) := @scalewayFunction; ()
  | .scalewayContainer => let _ : ∀ {K}, Expr K String →
                            Expr K (K .scaleway .scalewayContainerNamespace) →
                            Expr K String → _ → _ → _ → _ → _ → _ → _ → _ →
                            ScalewayContainerSpec K Partial (Expr K) := @scalewayContainer; ()

end Infra.Specs.Build
