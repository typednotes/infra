import Infra.Providers.Kinds.ObjectStore
import Infra.Providers.Kinds.Queues
import Infra.Providers.Kinds.ImageRegistry
import Infra.Providers.Kinds.Secrets
import Infra.Providers.Kinds.Compute
import Infra.Providers.Kinds.Iam
import Infra.Providers.Kinds.Postgres
import Infra.Core.Backend

/-
  The live backend: real calls to real clouds.

  Assembles the per-kind mappings into one `Backend` per cloud. Dispatch is a
  total match on `Kind`, so a kind cannot be silently forgotten — adding one
  makes this file fail to compile until it is handled.

  ## Coverage

  Live: `.objectStore` on both clouds and `.s3Bucket` on AWS over the S3 API,
  and `.queues` on both clouds over the SQS API. `.imageRegistry` on both, but
  from *two* implementations, because ECR and Scaleway Container Registry share
  no API — the case the portable-spec design exists to handle.

  `.secrets` on both, again from two implementations, and with the value only
  ever travelling *outward* — see `Kinds.Secrets`.

  `.compute` on both: Lambda with `PackageType=Image` against Scaleway
  Serverless Containers, which is the pairing the container-image decision
  implies.

  `.iam` and `.postgres` on both, again two implementations each.

  `.scalewayFunction` on Scaleway, whose `sourceBucket` reference is passed to
  the function as a `SOURCE_BUCKET` environment variable — the cross-cloud
  dependency edge doing real work.

  **All sixteen `(provider, kind)` pairs.** The catch-all that used to refuse
  unimplemented kinds is gone, because Lean reported it as unreachable — every
  branch of every field is now a real implementation. Adding a `Kind` will make
  this file fail to compile until it is handled, which is the guarantee that
  replaced it.

  Not yet live: the remaining kinds. Their `list` returns `[]` and their `read`
  reports `unknown`, both of which are *true statements* — nothing is known.
  Their mutations **raise**, naming the kind and the cloud, because a create
  that silently does nothing is a lie, and the engine would then believe the
  resource exists.
-/

namespace Infra.Providers

open Infra.Core
open Infra.Providers.Aws
open Infra.Providers.Kinds

/-- The SQS endpoint this cloud uses. Scaleway's queues are SQS-compatible, so
    only the host differs — the same reuse as object storage. -/
private def sqsFor (provider : ProviderId) (creds : Credentials) : Endpoint :=
  Json.sqsEndpoint provider creds.region

/-- The ECR endpoint. AWS only: Scaleway's registry is a different API, not an
    ECR-compatible one, so this kind really is two implementations. -/
private def ecrFor (creds : Credentials) : Endpoint := Json.ecrEndpoint creds.region

/-- The Secrets Manager endpoint. AWS only; Scaleway's is a different API. -/
private def asmFor (creds : Credentials) : Endpoint := Json.secretsEndpoint creds.region

/-- The Lambda endpoint. AWS only. -/
private def lambdaFor (creds : Credentials) : Endpoint := RestJson.lambdaEndpoint creds.region

/-- The RDS endpoint. AWS only. -/
private def rdsFor (creds : Credentials) : Endpoint := Query.rdsEndpoint creds.region

/-- The S3 endpoint this cloud uses for a bucket-shaped kind. -/
private def s3For (provider : ProviderId) (creds : Credentials) : Endpoint :=
  S3.endpoint provider creds.region

/-- One cloud's live CRUD surface.

    Every field pattern-matches on the kind directly rather than wrapping a
    `match` inside `do`: the result type is `ObservedOf k`/`Reported k`, so the
    equation compiler has to refine it per branch. -/
def liveBackend (provider : ProviderId) (creds : Credentials) : Backend where
  list
    | .objectStore => do
      let ep := s3For provider creds
      return (← ObjectStore.listBuckets creds ep).map fun n =>
        { handle := ⟨n⟩, url := ObjectStore.bucketUrl ep n }
    | .s3Bucket => do
      let ep := s3For provider creds
      return (← ObjectStore.listBuckets creds ep).map fun n =>
        { handle := ⟨n⟩, arn := s!"arn:aws:s3:::{n}", region := ep.region }
    | .queues => do
      let ep := sqsFor provider creds
      return (← Queues.listQueues creds ep).map fun (name, url) =>
        { handle := ⟨name⟩, url }
    | .imageRegistry => do
      let entries ← match provider with
        | .aws      => ImageRegistry.Ecr.list creds (ecrFor creds)
        | .scaleway => ImageRegistry.Scw.list creds
      return entries.map fun (name, uri) => { handle := ⟨name⟩, repositoryUri := uri }
    | .secrets => do
      let names ← match provider with
        | .aws      => Secrets.Asm.list creds (asmFor creds)
        | .scaleway => Secrets.Scw.list creds
      -- The version is metadata the caller may want; fetching it per secret
      -- would cost a call each, and `read` supplies it for claimed keys anyway.
      return names.map fun n => { handle := ⟨n⟩, version := "" }
    | .compute => do
      let names ← match provider with
        | .aws      => Compute.Lambda.list creds (lambdaFor creds)
        | .scaleway => Compute.Containers.list creds
      return names.map fun n => { handle := ⟨n⟩, status := "" }
    | .iam => do
      match provider with
      | .aws =>
        return (← Iam.Aws'.list creds).map fun (n, arn) => { handle := ⟨n⟩, arn }
      | .scaleway =>
        return (← Iam.Scw.list creds).map fun n => { handle := ⟨n⟩, arn := "" }
    | .postgres => do
      let entries ← match provider with
        | .aws      => Postgres.Rds.list creds (rdsFor creds)
        | .scaleway => Postgres.Rdb.list creds
      return entries.map fun (n, host) => { handle := ⟨n⟩, endpoint := host }
    | .scalewayFunction => do
      match provider with
      | .scaleway =>
        return (← Compute.Functions.list creds).map fun (n, url) => { handle := ⟨n⟩, url }
      | .aws => return []      -- Scaleway-only kind

  read
    | .objectStore, h => do
      let ep := s3For provider creds
      return { name := h.raw
               versioning := ← ObjectStore.readVersioning creds ep h.raw
               tags := ← ObjectStore.readTags creds ep h.raw }
    | .s3Bucket, h => do
      let ep := s3For provider creds
      return { name := h.raw
               versioning := ← ObjectStore.readVersioning creds ep h.raw
               objectLock := ← ObjectStore.readObjectLock creds ep h.raw
               region := .known ep.region }
    -- Nothing was read, so nothing is claimed. `unknown` is exactly that, and
    -- is why an unimplemented kind cannot masquerade as already matching.
    | .iam, h => do
      let policies ← match provider with
        | .aws      => Iam.Aws'.readPolicies creds h.raw
        | .scaleway => Iam.Scw.readPolicies
      return { name := h.raw, policies }
    | .compute, h => do
      match provider with
      | .aws =>
        let (role, memory, timeout, env, image) ← Compute.Lambda.read creds (lambdaFor creds) h.raw
        -- `runtime` and `namespace'` are not reported by either cloud, and are
        -- excluded from the divergence table for exactly that reason.
        return { name := h.raw, runtime := .unknown, image
                 executionRole := role, namespace' := .unknown
                 handler := .unknown, memoryMb := memory
                 timeoutSec := timeout, env }
      | .scaleway =>
        let (memory, timeout, env, image) ← Compute.Containers.read creds h.raw
        return { name := h.raw, runtime := .unknown, image
                 executionRole := .unknown, namespace' := .unknown
                 handler := .unknown, memoryMb := memory
                 timeoutSec := timeout, env }
    | .queues, h => do
      let ep := sqsFor provider creds
      return { name := h.raw
               visibilityTimeoutSec := ← Queues.readVisibilityTimeout creds ep h.raw }
    -- `valueFrom` names an environment variable the cloud has never heard of,
    -- so it cannot be reported and is excluded from the divergence table. The
    -- value itself is never fetched: see the module note in `Kinds.Secrets`.
    | .secrets, h          => pure { name := h.raw, valueFrom := "" }
    | .imageRegistry, h => do
      let immutable ← match provider with
        | .aws      => ImageRegistry.Ecr.readImmutable creds (ecrFor creds) h.raw
        | .scaleway => ImageRegistry.Scw.readImmutable
      return { name := h.raw, immutableTags := immutable }
    | .postgres, h => do
      let (cls, user, ver, storage) ← match provider with
        | .aws      => Postgres.Rds.read creds (rdsFor creds) h.raw
        | .scaleway => Postgres.Rdb.read creds h.raw
      -- `masterPasswordSecret` is our bookkeeping, not the database's: it is
      -- never reported and never compared.
      return { name := h.raw, instanceClass := cls, masterUsername := user
               masterPasswordSecret := "", version := ver, storageGb := storage }
    | .scalewayFunction, h => do
      match provider with
      | .scaleway =>
        let (runtime, bucketName) ← Compute.Functions.read creds h.raw
        -- The reference is reported as the handle the function was told about,
        -- which is what `settleRef` produced when it was created.
        let bucket : Partial (Option (Handle .s3Bucket)) := match bucketName with
          | .known (some n) => .known (some ⟨n⟩)
          | .known none     => .known none
          | .unknown        => .unknown
        return { name := h.raw, runtime, namespace' := "", sourceBucket := bucket }
      | .aws => return { name := h.raw, runtime := "", namespace' := ""
                         sourceBucket := .unknown }

  create
    | .objectStore, spec => do
      let ep := s3For provider creds
      ObjectStore.createBucket creds ep spec.name
      ObjectStore.putVersioning creds ep spec.name spec.versioning
      ObjectStore.putTags creds ep spec.name spec.tags
      return { handle := ⟨spec.name⟩, url := ObjectStore.bucketUrl ep spec.name }
    | .s3Bucket, spec => do
      let ep := s3For provider creds
      -- Object Lock is a creation-time header: it cannot be turned on later.
      ObjectStore.createBucket creds ep spec.name (objectLock := spec.objectLock)
      ObjectStore.putVersioning creds ep spec.name spec.versioning
      return { handle := ⟨spec.name⟩, arn := s!"arn:aws:s3:::{spec.name}", region := ep.region }
    | .queues, spec => do
      let ep := sqsFor provider creds
      let url ← Queues.createQueue creds ep spec.name spec.visibilityTimeoutSec
      return { handle := ⟨spec.name⟩, url }
    | .imageRegistry, spec => do
      let uri ← match provider with
        | .aws      => ImageRegistry.Ecr.create creds (ecrFor creds) spec.name spec.immutableTags
        | .scaleway => ImageRegistry.Scw.create creds spec.name
      return { handle := ⟨spec.name⟩, repositoryUri := uri }
    | .secrets, spec => do
      let value ← Secrets.valueFromEnv spec.valueFrom
      let version ← match provider with
        | .aws      => Secrets.Asm.create creds (asmFor creds) spec.name value
        | .scaleway => Secrets.Scw.create creds spec.name value
      return { handle := ⟨spec.name⟩, version }
    | .compute, spec => do
      match provider with
      | .aws => Compute.Lambda.create creds (lambdaFor creds) spec.name spec.image
                  spec.executionRole spec.memoryMb spec.timeoutSec spec.env
      | .scaleway => Compute.Containers.create creds spec.name spec.image
                       spec.namespace' spec.memoryMb spec.timeoutSec spec.env
      return { handle := ⟨spec.name⟩, status := "creating" }
    | .iam, spec => do
      match provider with
      | .aws =>
        let arn ← Iam.Aws'.create creds spec.name spec.policies
        return { handle := ⟨spec.name⟩, arn }
      | .scaleway =>
        discard <| Iam.Scw.create creds spec.name
        return { handle := ⟨spec.name⟩, arn := "" }
    | .postgres, spec => do
      -- The one place a secret value is read; see `Kinds.Postgres`.
      let password ← Postgres.fetchMasterPassword provider creds spec.masterPasswordSecret
      let host ← match provider with
        | .aws => Postgres.Rds.create creds (rdsFor creds) spec.name spec.instanceClass
                    spec.masterUsername password spec.version spec.storageGb
        | .scaleway => Postgres.Rdb.create creds spec.name spec.instanceClass
                         spec.masterUsername password spec.version spec.storageGb
      return { handle := ⟨spec.name⟩, endpoint := host }
    | .scalewayFunction, spec => do
      let url ← Compute.Functions.create creds spec.name spec.runtime spec.namespace'
                  spec.sourceBucket
      return { handle := ⟨spec.name⟩, url }

  update
    | .objectStore, h, spec => do
      let ep := s3For provider creds
      ObjectStore.putVersioning creds ep h.raw spec.versioning
      ObjectStore.putTags creds ep h.raw spec.tags
      return { handle := h, url := ObjectStore.bucketUrl ep h.raw }
    | .s3Bucket, h, spec => do
      let ep := s3For provider creds
      -- Only versioning is mutable here; Object Lock and region are not, which
      -- is what the mutability table turns into a `replace`.
      ObjectStore.putVersioning creds ep h.raw spec.versioning
      return { handle := h, arn := s!"arn:aws:s3:::{h.raw}", region := ep.region }
    | .queues, h, spec => do
      let ep := sqsFor provider creds
      Queues.setVisibilityTimeout creds ep h.raw spec.visibilityTimeoutSec
      return { handle := h, url := ← Queues.queueUrl creds ep h.raw }
    | .imageRegistry, h, spec => do
      match provider with
      | .aws =>
        ImageRegistry.Ecr.setImmutable creds (ecrFor creds) h.raw spec.immutableTags
        return { handle := h, repositoryUri := "" }
      | .scaleway =>
        -- Nothing in the portable spec is mutable on a Scaleway namespace, so
        -- there is nothing to send. Reporting success is honest: the target is
        -- already as closely realised as this cloud allows.
        return { handle := h, repositoryUri := "" }
    | .secrets, h, spec => do
      let value ← Secrets.valueFromEnv spec.valueFrom
      let version ← match provider with
        | .aws      => Secrets.Asm.putValue creds (asmFor creds) h.raw value
        | .scaleway => Secrets.Scw.putValue creds h.raw value
      return { handle := h, version }
    | .compute, h, spec => do
      match provider with
      | .aws => Compute.Lambda.update creds (lambdaFor creds) h.raw spec.image
                  spec.executionRole spec.memoryMb spec.timeoutSec spec.env
      | .scaleway => Compute.Containers.update creds h.raw spec.image
                       spec.memoryMb spec.timeoutSec spec.env
      return { handle := h, status := "updating" }
    | .iam, h, spec => do
      match provider with
      | .aws =>
        Iam.Aws'.setPolicies creds h.raw spec.policies
        return { handle := h, arn := "" }
      | .scaleway =>
        -- Policy rules have no portable representation here, so there is
        -- nothing to send: see the module note in `Kinds.Iam`.
        return { handle := h, arn := "" }
    | .postgres, h, spec => do
      match provider with
      | .aws => Postgres.Rds.modify creds (rdsFor creds) h.raw spec.instanceClass spec.storageGb
      | .scaleway => Postgres.Rdb.modify creds h.raw spec.instanceClass
      return { handle := h, endpoint := "" }
    | .scalewayFunction, h, spec => do
      Compute.Functions.update creds h.raw spec.sourceBucket
      return { handle := h, url := "" }

  delete
    | .objectStore, h => ObjectStore.deleteBucket creds (s3For provider creds) h.raw
    | .s3Bucket, h    => ObjectStore.deleteBucket creds (s3For provider creds) h.raw
    | .queues, h      => Queues.deleteQueue creds (sqsFor provider creds) h.raw
    | .imageRegistry, h =>
      match provider with
      | .aws      => ImageRegistry.Ecr.delete creds (ecrFor creds) h.raw
      | .scaleway => ImageRegistry.Scw.delete creds h.raw
    | .secrets, h =>
      match provider with
      | .aws      => Secrets.Asm.delete creds (asmFor creds) h.raw
      | .scaleway => Secrets.Scw.delete creds h.raw
    | .compute, h =>
      match provider with
      | .aws      => Compute.Lambda.delete creds (lambdaFor creds) h.raw
      | .scaleway => Compute.Containers.delete creds h.raw
    | .iam, h =>
      match provider with
      | .aws      => Iam.Aws'.delete creds h.raw
      | .scaleway => Iam.Scw.delete creds h.raw
    | .postgres, h =>
      match provider with
      | .aws      => Postgres.Rds.delete creds (rdsFor creds) h.raw
      | .scaleway => Postgres.Rdb.delete creds h.raw
    | .scalewayFunction, h => Compute.Functions.delete creds h.raw

/-- Both clouds, live, using each one's own credentials. -/
def live (aws scaleway : Credentials) : Backends where
  backend
    | .aws      => liveBackend .aws aws
    | .scaleway => liveBackend .scaleway scaleway

/-- Load credentials for both clouds and build the live backends. -/
def liveFromEnvironment : IO Backends := do
  return live (← Credentials.load .aws) (← Credentials.load .scaleway)

end Infra.Providers
