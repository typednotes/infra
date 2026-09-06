import Infra.Providers.Kinds.ObjectStore
import Infra.Providers.Kinds.Queues
import Infra.Providers.Kinds.ImageRegistry
import Infra.Providers.Kinds.Secrets
import Infra.Providers.Kinds.Compute
import Infra.Providers.Kinds.Iam
import Infra.Providers.Kinds.Postgres
import Infra.Providers.Kinds.Ec2
import Infra.Providers.Scaleway.Sqs
import Infra.Core.Backend
import Infra.Providers.Gcp.PubSub
import Infra.Providers.Gcp.SecretManager
import Infra.Providers.Gcp.Storage

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

  `.iam` and `.postgres` on both, again two implementations each. `.postgres` additionally routes
  between a classic managed instance and a serverless one on whether the settled spec's
  `instanceClass` is set: classic goes to RDS/RDB as before; serverless goes to a named "not
  implemented" error on AWS (Aurora Serverless v2), and to the honestly stubbed
  `Kinds.Postgres.ServerlessSql` on Scaleway.

  `.scalewayFunction` on Scaleway, whose `sourceBucket` reference is passed to
  the function as a `SOURCE_BUCKET` environment variable — the cross-cloud
  dependency edge doing real work.

  `.scalewayContainer` on Scaleway, same-cloud references this time:
  `secretEnv` names `.secrets` resources whose values are read once at apply
  (`Kinds.Secrets.fetchValue`) and bound as environment variables.

  `.securityGroup` and `.awsInstance` on AWS over the EC2 Query API — the
  pair that carries the library's only *required* reference, so an instance is
  always scheduled after the group it names. Scaleway's half of both returns
  `[]`: they are AWS-only kinds.

  **Every `(provider, kind)` pair.** The catch-all that used to refuse
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

/-- The kind is another cloud's local concept, and GCP has no counterpart.

    Deliberately not `noGcp`, which promises a client that has not been
    written yet. This is not a to-do: there is no GCP security group and no
    Scaleway container namespace on GCP, so the honest report is that the
    declaration names something which cannot exist there — not that nobody has
    got round to it. Conflating the two made `grep noGcp` overstate the work
    remaining by about a third. -/
private def notOnGcp {α : Type} (kind : String) : IO α :=
  throw (IO.userError s!"{kind} is a provider-local kind and has no GCP \
counterpart; declare it on the cloud it belongs to. See docs/architecture.md \
on provider-local kinds.")

/-- Every GCP branch in this file. There is no live GCP backend yet: the types,
    placement, scheduling, diffing and HCL export all work for GCP, but nothing
    here can talk to it.

    Raising rather than returning `[]` or `unknown` is deliberate and is the
    same rule the rest of this file follows: an empty list would say "nothing
    exists there", which would make the engine propose creating a whole fleet
    it cannot then create. Saying so at the first call is the honest failure.

    Kept as one helper so that implementing a GCP product is a matter of
    replacing its call, and `grep noGcp` is *most* of the to-do list — with
    one caveat worth stating, because it cost a confusing CI failure.

    `.queues` never had one of these. It routed straight to the SQS client for
    every cloud, which was right for AWS and Scaleway and wrong for GCP, so a
    GCP queue failed deep inside `Scaleway.Sqs.credentialsFor` with a remark
    about SQS compatibility instead of saying the backend was missing. A kind
    that reuses another cloud's client can be unimplemented *without*
    appearing in this list, so the list is a lower bound, not a census. -/
private def noGcp {α : Type} : IO α :=
  throw (IO.userError
    "no live GCP backend yet — the types work, the client does not. \
See docs/coverage.md for what is implemented")

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
private def ec2For (creds : Credentials) : Endpoint := Query.ec2Endpoint creds.region

private def s3For (provider : ProviderId) (creds : Credentials) : Endpoint :=
  S3.endpoint provider creds.region

/-- One cloud's live CRUD surface.

    Every field pattern-matches on the kind directly rather than wrapping a
    `match` inside `do`: the result type is `ObservedOf k`/`Reported k`, so the
    equation compiler has to refine it per branch. -/
def liveBackend (provider : ProviderId) (creds : Credentials) : Backend where
  list
    | .objectStore => do
      match provider with
      -- Cloud Storage's JSON API, not the S3-compatible one: that needs HMAC
      -- keys, and every GCP credential here is a bearer token. See the module
      -- note in `Gcp.Storage` — this kind had no GCP branch at all and routed
      -- to the S3 client, so it was unimplemented without appearing in
      -- `grep noGcp`.
      | .gcp =>
        let project ← Gcp.requireProject creds
        return (← Gcp.Storage.listBuckets creds project).map fun n =>
          { handle := ⟨n⟩, url := Gcp.Storage.bucketUrl n }
      | .aws | .scaleway =>
        let ep := s3For provider creds
        return (← ObjectStore.listBuckets creds ep).map fun n =>
          { handle := ⟨n⟩, url := ObjectStore.bucketUrl ep n }
    | .s3Bucket => do
      let ep := s3For provider creds
      return (← ObjectStore.listBuckets creds ep).map fun n =>
        { handle := ⟨n⟩, arn := s!"arn:aws:s3:::{n}", region := ep.region }
    | .securityGroup => do
      match provider with
      -- AWS-only kind. `[]` is a *successful* listing that found nothing, not
      -- a skipped one — the same answer Scaleway gives, and the right one:
      -- `noGcp` would claim the client is merely unwritten, when there is no
      -- GCP concept for it to talk to.
      | .gcp | .scaleway => return []
      | .aws =>
        let groups ← Ec2.SecurityGroup.list creds (ec2For creds)
        return groups.map fun g => { handle := ⟨g.1⟩, groupId := g.2.1, vpcId := g.2.2 }
    | .awsInstance => do
      match provider with
      -- AWS-only kind: neither GCP nor Scaleway has a counterpart. `[]` is a
      -- *successful* listing that found nothing, not a skipped one.
      | .gcp | .scaleway => return []
      | .aws =>
        let insts ← Ec2.Instance'.list creds (ec2For creds)
        return insts.map fun i =>
          { handle := ⟨i.1⟩, instanceId := i.2.1
            privateIp := i.2.2.1, state := i.2.2.2 }
    | .queues => do
      match provider with
      -- Pub/Sub, not SQS: a different API, so a different client. The
      -- resource name stands in for the URL — a topic has no endpoint of its
      -- own, and the name is what identifies it everywhere else.
      | .gcp =>
        let project ← Gcp.requireProject creds
        return (← Gcp.PubSub.listTopics creds project).map fun (name, resource) =>
          { handle := ⟨name⟩, url := resource }
      | .aws | .scaleway =>
        let ep := sqsFor provider creds
        let sqsCreds ← Scaleway.Sqs.credentialsFor provider creds
        return (← Queues.listQueues sqsCreds ep).map fun (name, url) =>
          { handle := ⟨name⟩, url }
    | .imageRegistry => do
      let entries ← match provider with
        | .gcp => noGcp
        | .aws      => ImageRegistry.Ecr.list creds (ecrFor creds)
        | .scaleway => ImageRegistry.Scw.list creds
      return entries.map fun (name, uri) => { handle := ⟨name⟩, repositoryUri := uri }
    | .secrets => do
      let names ← match provider with
        | .gcp      => Gcp.SecretManager.list creds (← Gcp.requireProject creds)
        | .aws      => Secrets.Asm.list creds (asmFor creds)
        | .scaleway => Secrets.Scw.list creds
      -- The version is metadata the caller may want; fetching it per secret
      -- would cost a call each, and `read` supplies it for claimed keys anyway.
      return names.map fun n => { handle := ⟨n⟩, version := "" }
    | .compute => do
      let names ← match provider with
        | .gcp => noGcp
        | .aws      => Compute.Lambda.list creds (lambdaFor creds)
        | .scaleway => Compute.Containers.list creds
      return names.map fun n => { handle := ⟨n⟩, status := "" }
    | .iam => do
      match provider with
      | .gcp => noGcp
      | .aws =>
        return (← Iam.Aws'.list creds).map fun (n, arn) => { handle := ⟨n⟩, arn }
      | .scaleway =>
        return (← Iam.Scw.list creds).map fun n => { handle := ⟨n⟩, arn := "" }
    | .postgres => do
      let entries ← match provider with
        | .gcp => noGcp
        | .aws      => Postgres.Rds.list creds (rdsFor creds)
        | .scaleway => Postgres.Rdb.list creds
      return entries.map fun (n, host) => { handle := ⟨n⟩, endpoint := host }
    | .scalewayFunctionNamespace => do
      match provider with
      -- Scaleway-only kind: neither GCP nor AWS has a counterpart. `[]` is a
      -- *successful* listing that found nothing, not a skipped one.
      | .gcp | .aws => return []
      | .scaleway =>
        return (← Compute.Functions.listNamespaces creds).map fun (n, i) =>
          { handle := ⟨n⟩, namespaceId := i }
    | .scalewayContainerNamespace => do
      match provider with
      -- Scaleway-only kind: neither GCP nor AWS has a counterpart. `[]` is a
      -- *successful* listing that found nothing, not a skipped one.
      | .gcp | .aws => return []
      | .scaleway =>
        return (← Compute.Containers.listNamespaces creds).map fun (n, i) =>
          { handle := ⟨n⟩, namespaceId := i, registryEndpoint := "" }
    | .scalewayFunction => do
      match provider with
      -- Scaleway-only kind: neither GCP nor AWS has a counterpart. `[]` is a
      -- *successful* listing that found nothing, not a skipped one.
      | .gcp | .aws => return []
      | .scaleway =>
        return (← Compute.Functions.list creds).map fun (n, url) => { handle := ⟨n⟩, url }
    | .scalewayContainer => do
      match provider with
      -- Scaleway-only kind: neither GCP nor AWS has a counterpart. `[]` is a
      -- *successful* listing that found nothing, not a skipped one.
      | .gcp | .aws => return []
      | .scaleway =>
        return (← Compute.Containers.listFull creds).map fun (n, url) => { handle := ⟨n⟩, url }

  read
    | .objectStore, h => do
      match provider with
      | .gcp =>
        return { name := h.raw
                 versioning := ← Gcp.Storage.readVersioning creds h.raw
                 tags := ← Gcp.Storage.readLabels creds h.raw }
      | .aws | .scaleway =>
        let ep := s3For provider creds
        return { name := h.raw
                 versioning := ← ObjectStore.readVersioning creds ep h.raw
                 tags := ← ObjectStore.readTags creds ep h.raw }
    | .s3Bucket, h => do
      let ep := s3For provider creds
      return { name := h.raw
               versioning := ← ObjectStore.readVersioning creds ep h.raw
               objectLock := ← ObjectStore.readObjectLock creds ep h.raw }
    | .securityGroup, h => do
      let (_, description, ingress) ← Ec2.SecurityGroup.read creds (ec2For creds) h.raw
      return { name := h.raw, description, ingress }
    | .awsInstance, h => do
      let (imageId, instanceType, group, keyName, subnetId) ←
        Ec2.Instance'.read creds (ec2For creds) h.raw
      -- The security group comes back as a *name*, which is exactly what the
      -- settled spec holds, so the two are directly comparable. The instance
      -- type comes back as a string and is wrapped rather than parsed:
      -- `InstanceType` is a string underneath precisely so that reading one
      -- cannot fail, even for a family this library's table does not name.
      return { name := h.raw, imageId
               instanceType := InstanceType.raw instanceType
               securityGroup := ⟨group⟩, keyName, subnetId }
    -- Nothing was read, so nothing is claimed. `unknown` is exactly that, and
    -- is why an unimplemented kind cannot masquerade as already matching.
    | .iam, h => do
      let policies ← match provider with
        | .gcp => noGcp
        | .aws      => Iam.Aws'.readPolicies creds h.raw
        | .scaleway => Iam.Scw.readPolicies
      return { name := h.raw, policies }
    | .compute, h => do
      match provider with
      | .gcp => noGcp
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
      match provider with
      -- The read is what proves the topic is there; nothing is extracted from
      -- it. `visibilityTimeoutSec` is a *subscription's* ack deadline on
      -- Pub/Sub and there is no subscription here, so it is unknown rather
      -- than invented — which is also what stops a declared timeout being
      -- read as a change to apply on every run. See the module note.
      | .gcp =>
        let project ← Gcp.requireProject creds
        discard <| Gcp.PubSub.readTopic creds project h.raw
        return { name := h.raw, visibilityTimeoutSec := .unknown }
      | .aws | .scaleway =>
        let ep := sqsFor provider creds
        let sqsCreds ← Scaleway.Sqs.credentialsFor provider creds
        return { name := h.raw
                 visibilityTimeoutSec := ← Queues.readVisibilityTimeout sqsCreds ep h.raw }
    -- `valueFrom` names an environment variable the cloud has never heard of,
    -- so it cannot be reported and is excluded from the divergence table. The
    -- value itself is never fetched: see the module note in `Kinds.Secrets`.
    | .secrets, h          => pure { name := h.raw, valueFrom := .fromEnv "" }
    | .imageRegistry, h => do
      let immutable ← match provider with
        | .gcp => noGcp
        | .aws      => ImageRegistry.Ecr.readImmutable creds (ecrFor creds) h.raw
        | .scaleway => ImageRegistry.Scw.readImmutable
      return { name := h.raw, immutableTags := immutable }
    | .postgres, h => do
      let (cls, user, ver, storage) ← match provider with
        | .gcp => noGcp
        | .aws      => Postgres.Rds.read creds (rdsFor creds) h.raw
        | .scaleway => Postgres.Rdb.read creds h.raw
      -- `masterPasswordSecret` is our bookkeeping, not the database's: it is
      -- never reported and never compared. `cls` is `""` both for "not found"
      -- and for a genuinely classless (serverless) instance — neither Rds.read
      -- nor Rdb.read distinguish them, so both read as `unknown` here, same as
      -- every other field this backend cannot see.
      let instanceClass : Partial String := if cls.isEmpty then .unknown else .known cls
      return { name := h.raw, instanceClass, masterUsername := user
               masterPasswordSecret := "", version := ver, storageGb := storage
               minCapacity := .unknown, maxCapacity := .unknown }
    | .scalewayFunctionNamespace, h => do
      return { name := h.raw, description := ← Compute.Functions.readNamespace creds h.raw }
    | .scalewayContainerNamespace, h => do
      return { name := h.raw, description := ← Compute.Containers.readNamespace creds h.raw }
    | .scalewayFunction, h => do
      match provider with
      | .gcp => notOnGcp "scalewayFunction"
      | .scaleway =>
        let (runtime, bucketName) ← Compute.Functions.read creds h.raw
        -- The reference is reported as the handle the function was told about,
        -- which is what `settleRef` produced when it was created.
        let bucket : Partial (Option (Handle .s3Bucket)) := match bucketName with
          | .known (some n) => .known (some ⟨n⟩)
          | .known none     => .known none
          | .unknown        => .unknown
        -- `namespace'` is placement, not configuration: the API does not
        -- report which namespace a function is in, so it cannot diverge and
        -- `Divergent` excludes it. A blank handle is the honest "not reported".
        return { name := h.raw, runtime, namespace' := ⟨""⟩, sourceBucket := bucket }
      | .aws => return { name := h.raw, runtime := "", namespace' := ⟨""⟩
                         sourceBucket := .unknown }
    -- `secretEnv` is read once at apply and handed straight to the API, so
    -- it cannot be reported back and is excluded from the divergence table
    -- — same limitation as `.secrets`' own `valueFrom`.
    | .scalewayContainer, h => do
      match provider with
      | .gcp => notOnGcp "scalewayContainer"
      | .scaleway =>
        let (port, minScale, maxScale, memoryMb, cpuLimit, timeoutSec, env, image) ←
          Compute.Containers.readFull creds h.raw
        return { name := h.raw, namespace' := ⟨""⟩, image
                 port, minScale, maxScale, memoryMb, cpuLimit, timeoutSec, env
                 secretEnv := .unknown }
      | .aws => return { name := h.raw, namespace' := ⟨""⟩, image := ""
                         port := .unknown, minScale := .unknown, maxScale := .unknown
                         memoryMb := .unknown, cpuLimit := .unknown, timeoutSec := .unknown
                         env := .unknown, secretEnv := .unknown }

  create
    | .objectStore, spec => do
      match provider with
      -- One call, unlike S3's create-then-configure: the JSON API takes
      -- versioning and labels in the insert body.
      | .gcp =>
        let project ← Gcp.requireProject creds
        Gcp.Storage.createBucket creds project spec.name spec.versioning spec.tags
        return { handle := ⟨spec.name⟩, url := Gcp.Storage.bucketUrl spec.name }
      | .aws | .scaleway =>
        let ep := s3For provider creds
        ObjectStore.createBucket creds ep spec.name
        ObjectStore.putVersioning creds ep spec.name spec.versioning
        ObjectStore.putTags creds ep spec.name spec.tags
        return { handle := ⟨spec.name⟩, url := ObjectStore.bucketUrl ep spec.name }
    | .securityGroup, spec => do
      -- `CreateSecurityGroup` does not report the VPC, so that stays blank
      -- until the next `pull` observes it.
      let groupId ← Ec2.SecurityGroup.create creds (ec2For creds)
        spec.name spec.description spec.ingress
      return { handle := ⟨spec.name⟩, groupId, vpcId := "" }
    | .awsInstance, spec => do
      -- `spec.securityGroup` is a settled `Handle .securityGroup`, i.e. the
      -- group's name; the backend resolves it to an id.
      -- Bound with its type rather than projected inline: `spec.securityGroup`
      -- reaches `Handle` through the reducible `Resolved`, and chaining `.raw`
      -- straight onto it makes the code generator emit "invalid projection".
      let group : Handle .securityGroup := spec.securityGroup
      -- Bound with its type for the same reason as `group` above.
      let itype : InstanceType := spec.instanceType
      let r ← Ec2.Instance'.create creds (ec2For creds)
        spec.name spec.imageId itype.name group.raw
        spec.keyName spec.subnetId
      return { handle := ⟨spec.name⟩, instanceId := r.1
               privateIp := r.2.1, state := r.2.2 }
    | .s3Bucket, spec => do
      let ep := s3For provider creds
      -- Object Lock is a creation-time header: it cannot be turned on later.
      ObjectStore.createBucket creds ep spec.name (objectLock := spec.objectLock)
      ObjectStore.putVersioning creds ep spec.name spec.versioning
      return { handle := ⟨spec.name⟩, arn := s!"arn:aws:s3:::{spec.name}", region := ep.region }
    | .queues, spec => do
      match provider with
      | .gcp =>
        let project ← Gcp.requireProject creds
        let resource ← Gcp.PubSub.createTopic creds project spec.name
        return { handle := ⟨spec.name⟩, url := resource }
      | .aws | .scaleway =>
        let ep := sqsFor provider creds
        let sqsCreds ← Scaleway.Sqs.credentialsFor provider creds
        let url ← Queues.createQueue sqsCreds ep spec.name spec.visibilityTimeoutSec
        return { handle := ⟨spec.name⟩, url }
    | .imageRegistry, spec => do
      let uri ← match provider with
        | .gcp => noGcp
        | .aws      => ImageRegistry.Ecr.create creds (ecrFor creds) spec.name spec.immutableTags
        | .scaleway => ImageRegistry.Scw.create creds spec.name
      return { handle := ⟨spec.name⟩, repositoryUri := uri }
    | .secrets, spec => do
      -- `fromEnv` reads the operator's environment; `composed` was already
      -- evaluated at settle time from post-apply state. Either way the value
      -- goes straight into the one create call and is never stored.
      let value ← match spec.valueFrom with
        | .fromEnv v  => Secrets.valueFromEnv v
        | .composed v => pure v
      let version ← match provider with
        | .gcp      =>
          Gcp.SecretManager.create creds (← Gcp.requireProject creds) spec.name value
        | .aws      => Secrets.Asm.create creds (asmFor creds) spec.name value
        | .scaleway => Secrets.Scw.create creds spec.name value
      return { handle := ⟨spec.name⟩, version }
    | .compute, spec => do
      match provider with
      | .gcp => noGcp
      | .aws => Compute.Lambda.create creds (lambdaFor creds) spec.name spec.image
                  spec.executionRole spec.memoryMb spec.timeoutSec spec.env
      | .scaleway => Compute.Containers.create creds spec.name spec.image
                       spec.namespace' spec.memoryMb spec.timeoutSec spec.env
      return { handle := ⟨spec.name⟩, status := "creating" }
    | .iam, spec => do
      match provider with
      | .gcp => noGcp
      | .aws =>
        let arn ← Iam.Aws'.create creds spec.name spec.policies
        return { handle := ⟨spec.name⟩, arn }
      | .scaleway =>
        discard <| Iam.Scw.create creds spec.name
        return { handle := ⟨spec.name⟩, arn := "" }
    | .postgres, spec => do
      -- The one place a secret value is read; see `Kinds.Postgres`.
      let password ← Postgres.fetchMasterPassword provider creds spec.masterPasswordSecret
      -- Routed on `instanceClass` being set, not on a separate spec flag: `Fillable`'s `""`
      -- sentinel is what `PostgresSpec.serverless` leaves behind, same convention as every
      -- other "said: nothing" default in this codebase.
      let host ←
        if spec.instanceClass.isEmpty then
          match provider with
          | .gcp => noGcp
          | .aws => throw (IO.userError
              "postgres: AWS Aurora Serverless v2 is not implemented; set instanceClass for a classic instance")
          | .scaleway => Postgres.ServerlessSql.create creds spec.name spec.masterUsername
                           password spec.version spec.minCapacity spec.maxCapacity
        else
          match provider with
          | .gcp => noGcp
          | .aws => Postgres.Rds.create creds (rdsFor creds) spec.name spec.instanceClass
                      spec.masterUsername password spec.version spec.storageGb
          | .scaleway => Postgres.Rdb.create creds spec.name spec.instanceClass
                           spec.masterUsername password spec.version spec.storageGb
      return { handle := ⟨spec.name⟩, endpoint := host }
    | .scalewayFunctionNamespace, spec => do
      let (i, _) ← Compute.Functions.createNamespace creds spec.name spec.description
      return { handle := ⟨spec.name⟩, namespaceId := i }
    | .scalewayContainerNamespace, spec => do
      -- The registry endpoint comes back from the create call: making a
      -- containers namespace implicitly makes a Container Registry namespace,
      -- and that is where its images have to be pushed.
      let (i, reg) ← Compute.Containers.createNamespace creds spec.name spec.description
      return { handle := ⟨spec.name⟩, namespaceId := i, registryEndpoint := reg }
    | .scalewayFunction, spec => do
      let ns : Handle .scalewayFunctionNamespace := spec.namespace'
      let url ← Compute.Functions.create creds spec.name spec.runtime ns.raw
                  spec.sourceBucket
      return { handle := ⟨spec.name⟩, url }
    | .scalewayContainer, spec => do
      -- The one place a `.scalewayContainer` reads a secret's value; see
      -- `Kinds.Secrets.fetchValue`.
      let secretVals ← spec.secretEnv.mapM fun (name, h) => do
        return (name, ← Secrets.fetchValue .scaleway creds h.raw)
      let ns : Handle .scalewayContainerNamespace := spec.namespace'
      let url ← Compute.Containers.createFull creds spec.name spec.image ns.raw
                  spec.port spec.minScale spec.maxScale spec.memoryMb spec.cpuLimit
                  spec.timeoutSec spec.env secretVals
      return { handle := ⟨spec.name⟩, url }

  update
    | .objectStore, h, spec => do
      match provider with
      | .gcp =>
        Gcp.Storage.patchBucket creds h.raw spec.versioning spec.tags
        return { handle := h, url := Gcp.Storage.bucketUrl h.raw }
      | .aws | .scaleway =>
        let ep := s3For provider creds
        ObjectStore.putVersioning creds ep h.raw spec.versioning
        ObjectStore.putTags creds ep h.raw spec.tags
        return { handle := h, url := ObjectStore.bucketUrl ep h.raw }
    | .securityGroup, h, spec => do
      -- Additive: a rule present in the cloud but absent from the target is
      -- left alone. See `Kinds/Ec2.lean` and `docs/providers.md`.
      let groupId ← Ec2.SecurityGroup.update creds (ec2For creds) h.raw spec.ingress
      return { handle := h, groupId, vpcId := "" }
    | .awsInstance, h, spec => do
      let ep := ec2For creds
      let group : Handle .securityGroup := spec.securityGroup
      match ← Ec2.Instance'.byName creds ep h.raw with
      | none => throw (IO.userError
          s!"instance '{h.raw}' disappeared between plan and apply")
      | some (instanceId, privateIp, state) =>
        Ec2.Instance'.update creds ep instanceId spec.name group.raw
        return { handle := ⟨spec.name⟩, instanceId, privateIp, state }
    | .s3Bucket, h, spec => do
      let ep := s3For provider creds
      -- Only versioning is mutable here; Object Lock and region are not, which
      -- is what the mutability table turns into a `replace`.
      ObjectStore.putVersioning creds ep h.raw spec.versioning
      return { handle := h, arn := s!"arn:aws:s3:::{h.raw}", region := ep.region }
    | .queues, h, spec => do
      match provider with
      -- Nothing in the portable spec is mutable on a topic: the only field is
      -- the timeout, which belongs to a subscription. So this is a no-op that
      -- re-reports, not an unimplemented branch.
      | .gcp =>
        let project ← Gcp.requireProject creds
        return { handle := h, url := ← Gcp.PubSub.readTopic creds project h.raw }
      | .aws | .scaleway =>
        let ep := sqsFor provider creds
        let sqsCreds ← Scaleway.Sqs.credentialsFor provider creds
        Queues.setVisibilityTimeout sqsCreds ep h.raw spec.visibilityTimeoutSec
        return { handle := h, url := ← Queues.queueUrl sqsCreds ep h.raw }
    | .imageRegistry, h, spec => do
      match provider with
      | .gcp => noGcp
      | .aws =>
        ImageRegistry.Ecr.setImmutable creds (ecrFor creds) h.raw spec.immutableTags
        return { handle := h, repositoryUri := "" }
      | .scaleway =>
        -- Nothing in the portable spec is mutable on a Scaleway namespace, so
        -- there is nothing to send. Reporting success is honest: the target is
        -- already as closely realised as this cloud allows.
        return { handle := h, repositoryUri := "" }
    | .secrets, h, spec => do
      let value ← match spec.valueFrom with
        | .fromEnv v  => Secrets.valueFromEnv v
        | .composed v => pure v
      let version ← match provider with
        | .gcp      =>
          Gcp.SecretManager.putValue creds (← Gcp.requireProject creds) h.raw value
        | .aws      => Secrets.Asm.putValue creds (asmFor creds) h.raw value
        | .scaleway => Secrets.Scw.putValue creds h.raw value
      return { handle := h, version }
    | .compute, h, spec => do
      match provider with
      | .gcp => noGcp
      | .aws => Compute.Lambda.update creds (lambdaFor creds) h.raw spec.image
                  spec.executionRole spec.memoryMb spec.timeoutSec spec.env
      | .scaleway => Compute.Containers.update creds h.raw spec.image
                       spec.memoryMb spec.timeoutSec spec.env
      return { handle := h, status := "updating" }
    | .iam, h, spec => do
      match provider with
      | .gcp => noGcp
      | .aws =>
        Iam.Aws'.setPolicies creds h.raw spec.policies
        return { handle := h, arn := "" }
      | .scaleway =>
        -- Policy rules have no portable representation here, so there is
        -- nothing to send: see the module note in `Kinds.Iam`.
        return { handle := h, arn := "" }
    | .postgres, h, spec => do
      if spec.instanceClass.isEmpty then
        match provider with
        | .gcp => noGcp
        | .aws => throw (IO.userError
            "postgres: AWS Aurora Serverless v2 is not implemented; set instanceClass for a classic instance")
        | .scaleway => Postgres.ServerlessSql.modify creds h.raw spec.minCapacity spec.maxCapacity
      else
        match provider with
        | .gcp => noGcp
        | .aws => Postgres.Rds.modify creds (rdsFor creds) h.raw spec.instanceClass spec.storageGb
        | .scaleway => Postgres.Rdb.modify creds h.raw spec.instanceClass
      return { handle := h, endpoint := "" }
    | .scalewayFunctionNamespace, h, spec => do
      Compute.Functions.updateNamespace creds h.raw spec.description
      return { handle := h, namespaceId := "" }
    | .scalewayContainerNamespace, h, spec => do
      Compute.Containers.updateNamespace creds h.raw spec.description
      return { handle := h, namespaceId := "", registryEndpoint := "" }
    | .scalewayFunction, h, spec => do
      Compute.Functions.update creds h.raw spec.sourceBucket
      return { handle := h, url := "" }
    | .scalewayContainer, h, spec => do
      let secretVals ← spec.secretEnv.mapM fun (name, sh) => do
        return (name, ← Secrets.fetchValue .scaleway creds sh.raw)
      let url ← Compute.Containers.updateFull creds h.raw spec.image
                  spec.port spec.minScale spec.maxScale spec.memoryMb spec.cpuLimit
                  spec.timeoutSec spec.env secretVals
      return { handle := h, url }

  delete
    | .objectStore, h =>
      match provider with
      | .gcp => Gcp.Storage.deleteBucket creds h.raw
      | .aws | .scaleway => ObjectStore.deleteBucket creds (s3For provider creds) h.raw
    | .s3Bucket, h    => ObjectStore.deleteBucket creds (s3For provider creds) h.raw
    | .securityGroup, h => Ec2.SecurityGroup.delete creds (ec2For creds) h.raw
    | .awsInstance, h => do
      -- Termination is by instance id, which only the observed state knows, so
      -- it is looked up from the `Name` tag this fleet keys on. Already gone is
      -- not an error: `delete` is reached from a plan, and EC2 keeps reporting
      -- a terminated instance for a while after it is really finished.
      let ep := ec2For creds
      match ← Ec2.Instance'.byName creds ep h.raw with
      | none                    => pure ()
      | some (instanceId, _, _) => Ec2.Instance'.delete creds ep instanceId
    | .queues, h      => do
      match provider with
      | .gcp =>
        Gcp.PubSub.deleteTopic creds (← Gcp.requireProject creds) h.raw
      | .aws | .scaleway =>
        Queues.deleteQueue (← Scaleway.Sqs.credentialsFor provider creds)
          (sqsFor provider creds) h.raw
    | .imageRegistry, h =>
      match provider with
      | .gcp => noGcp
      | .aws      => ImageRegistry.Ecr.delete creds (ecrFor creds) h.raw
      | .scaleway => ImageRegistry.Scw.delete creds h.raw
    | .secrets, h =>
      match provider with
      | .gcp      => do
        Gcp.SecretManager.delete creds (← Gcp.requireProject creds) h.raw
      | .aws      => Secrets.Asm.delete creds (asmFor creds) h.raw
      | .scaleway => Secrets.Scw.delete creds h.raw
    | .compute, h =>
      match provider with
      | .gcp => noGcp
      | .aws      => Compute.Lambda.delete creds (lambdaFor creds) h.raw
      | .scaleway => Compute.Containers.delete creds h.raw
    | .iam, h =>
      match provider with
      | .gcp => noGcp
      | .aws      => Iam.Aws'.delete creds h.raw
      | .scaleway => Iam.Scw.delete creds h.raw
    | .postgres, h =>
      match provider with
      | .gcp => noGcp
      | .aws      => Postgres.Rds.delete creds (rdsFor creds) h.raw
      | .scaleway => Postgres.Rdb.delete creds h.raw
    | .scalewayFunctionNamespace, h => Compute.Functions.deleteNamespace creds h.raw
    | .scalewayContainerNamespace, h => Compute.Containers.deleteNamespace creds h.raw
    | .scalewayFunction, h => Compute.Functions.delete creds h.raw
    | .scalewayContainer, h => Compute.Containers.delete creds h.raw
  -- The one inbound plaintext path; see `Backend.secretValue`. `fetchValue`
  -- already exists and is already the narrowly-scoped reader for both clouds.
  secretValue h := Secrets.fetchValue provider creds h.raw

/-- Every cloud, live, using each one's own credentials.

    GCP is included for totality and will raise on first use — see `noGcp`.
    `Infra.Cli.liveFor` is the path real fleets take and it only authenticates
    the clouds a fleet actually declares, so a fleet with no GCP resources
    never reaches this. -/
def live (aws scaleway gcp : Credentials) : Backends where
  backend
    | .aws      => liveBackend .aws aws
    | .scaleway => liveBackend .scaleway scaleway
    | .gcp      => liveBackend .gcp gcp

/-- Load credentials for every cloud and build the live backends. -/
def liveFromEnvironment : IO Backends := do
  return live (← Credentials.load .aws) (← Credentials.load .scaleway)
    (← Credentials.load .gcp)

end Infra.Providers
