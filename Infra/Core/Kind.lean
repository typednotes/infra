import Infra.Core.Finite
import Lean.Data.Json

/-
  The nominal axis: which sort of thing a resource is, and which cloud it lives in.

  Settled statically, and orthogonal to the refinement axis in `Infra.Core.Refine`. Add a
  `Kind` constructor and every total match over `Kind` fails to compile until you handle it —
  which is what keeps `SpecOf`, `ObservedOf` and `Fillable` honest.
-/

namespace Infra.Core

open Lean (ToJson FromJson)

/-- Which cloud. A fleet is indexed by this as well as by `Kind`, so one `Plan` can hold
    resources in several clouds at once — see `Infra.Core.Keys`. -/
inductive ProviderId
  | aws
  | scaleway
  | gcp
  deriving Repr, DecidableEq, BEq

instance : Finite ProviderId where
  elems := [.aws, .scaleway, .gcp]
  complete := by intro a; cases a <;> simp
  nodup := by decide

def ProviderId.name : ProviderId → String
  | .aws      => "aws"
  | .scaleway => "scaleway"
  | .gcp      => "gcp"

/-- The sort of resource.

    Split deliberately into **portable** kinds, whose specs every provider can honour, and
    **provider-local** kinds, which are richer but tie a plan to one cloud. `SpecOf` is indexed
    by `Kind` alone and never by provider, so a plan built from portable kinds applies through
    any backend; reaching for a provider-local kind makes that loss visible in the type.
    See `docs/diff-semantics.md`. -/
inductive Kind
  -- portable: `docs/architecture.md`'s coverage list
  | iam
  | objectStore
  | compute
  | queues
  | secrets
  | imageRegistry
  | postgres
  -- provider-local: the escape hatch to concepts closer to one provider
  | s3Bucket
  | securityGroup
  | awsInstance
  | scalewayFunctionNamespace
  | scalewayFunction
  | scalewayContainerNamespace
  | scalewayContainer
  deriving Repr, DecidableEq, BEq

instance : Finite Kind where
  elems :=
    [.iam, .objectStore, .compute, .queues, .secrets, .imageRegistry, .postgres,
     .s3Bucket, .securityGroup, .awsInstance,
     .scalewayFunctionNamespace, .scalewayFunction,
     .scalewayContainerNamespace, .scalewayContainer]
  complete := by intro a; cases a <;> simp
  nodup := by decide

def Kind.name : Kind → String
  | .iam                => "iam"
  | .objectStore        => "object-store"
  | .compute            => "compute"
  | .queues             => "queues"
  | .secrets            => "secrets"
  | .imageRegistry      => "image-registry"
  | .postgres           => "postgres"
  | .s3Bucket           => "s3-bucket"
  | .securityGroup      => "security-group"
  | .awsInstance        => "aws-instance"
  | .scalewayFunctionNamespace  => "scaleway-function-namespace"
  | .scalewayFunction   => "scaleway-function"
  | .scalewayContainerNamespace => "scaleway-container-namespace"
  | .scalewayContainer  => "scaleway-container"

/-- The *physical* identifier, assigned by the provider at create time.

    Indexed by `Kind`, so a `Handle .queues` can never be passed where a `Handle .secrets` is
    wanted. Never appears in an authored spec — it only exists inside the post-apply modality,
    reached through `Infra.Core.Expr.observed`. -/
structure Handle (k : Kind) where
  raw : String
  deriving Repr, DecidableEq, ToJson, FromJson

/-! ## Provider-computed state, one shape per kind

  Never authored, therefore never `Partial` in the "author chose not to say" sense. Each
  carries its `Handle` plus whatever else the provider assigns. -/

structure IamObserved where
  handle : Handle .iam
  arn    : String
  deriving Repr, DecidableEq, ToJson, FromJson

structure ObjectStoreObserved where
  handle : Handle .objectStore
  url    : String
  deriving Repr, DecidableEq, ToJson, FromJson

structure ComputeObserved where
  handle : Handle .compute
  status : String
  deriving Repr, DecidableEq, ToJson, FromJson

structure QueuesObserved where
  handle : Handle .queues
  url    : String
  deriving Repr, DecidableEq, ToJson, FromJson

structure SecretsObserved where
  handle  : Handle .secrets
  version : String
  deriving Repr, DecidableEq, ToJson, FromJson

structure ImageRegistryObserved where
  handle        : Handle .imageRegistry
  repositoryUri : String
  deriving Repr, DecidableEq, ToJson, FromJson

structure PostgresObserved where
  handle   : Handle .postgres
  endpoint : String
  deriving Repr, DecidableEq, ToJson, FromJson

structure S3BucketObserved where
  handle : Handle .s3Bucket
  arn    : String
  region : String
  deriving Repr, DecidableEq, ToJson, FromJson

/-- A security group, identified by its *name*.

    `handle` is `GroupName`, not `sg-…`: `Keys.name` has to equal whatever
    `observedHandle` returns (see `Engine.pullEntries`), and a fleet has to be
    able to write that identifier down before the resource exists. The
    AWS-assigned id is carried alongside, which is what `awsInstance` needs
    when it references one. -/
structure SecurityGroupObserved where
  handle  : Handle .securityGroup
  groupId : String
  vpcId   : String
  deriving Repr, DecidableEq, ToJson, FromJson

/-- An EC2 instance, identified by its `Name` tag.

    Same reasoning as `SecurityGroupObserved`: the instance id is assigned at
    launch and so cannot be a fleet key, whereas the `Name` tag is chosen by
    whoever declares it. `instanceId` is the real handle for API calls and
    lives here, where post-apply values belong. -/
structure AwsInstanceObserved where
  handle     : Handle .awsInstance
  instanceId : String
  privateIp  : String
  state      : String
  deriving Repr, DecidableEq, ToJson, FromJson

/-- A Serverless Functions namespace, identified by name.

    Functions and Containers namespaces are **different products** — different
    API prefixes (`functions/v1beta1` and `containers/v1beta1`) — so they are
    two kinds rather than one with a discriminator. That is what makes pointing
    a container at a functions namespace a type error rather than a 404. -/
structure ScalewayFunctionNamespaceObserved where
  handle      : Handle .scalewayFunctionNamespace
  namespaceId : String
  deriving Repr, DecidableEq, ToJson, FromJson

/-- A Serverless Containers namespace.

    Carries `registryEndpoint` as well, because creating one implicitly creates
    a Container Registry namespace and that is where images for its containers
    have to be pushed — a post-apply value worth observing rather than
    reconstructing by hand. -/
structure ScalewayContainerNamespaceObserved where
  handle           : Handle .scalewayContainerNamespace
  namespaceId      : String
  registryEndpoint : String
  deriving Repr, DecidableEq, ToJson, FromJson

structure ScalewayFunctionObserved where
  handle : Handle .scalewayFunction
  url    : String
  deriving Repr, DecidableEq, ToJson, FromJson

structure ScalewayContainerObserved where
  handle : Handle .scalewayContainer
  url    : String
  deriving Repr, DecidableEq, ToJson, FromJson

/-- Dispatch. Total over `Kind`, so adding a kind without observed state is a compile error. -/
@[reducible] def ObservedOf : Kind → Type
  | .iam               => IamObserved
  | .objectStore       => ObjectStoreObserved
  | .compute           => ComputeObserved
  | .queues            => QueuesObserved
  | .secrets           => SecretsObserved
  | .imageRegistry     => ImageRegistryObserved
  | .postgres          => PostgresObserved
  | .s3Bucket          => S3BucketObserved
  | .securityGroup     => SecurityGroupObserved
  | .awsInstance       => AwsInstanceObserved
  | .scalewayFunctionNamespace  => ScalewayFunctionNamespaceObserved
  | .scalewayFunction  => ScalewayFunctionObserved
  | .scalewayContainerNamespace => ScalewayContainerNamespaceObserved
  | .scalewayContainer => ScalewayContainerObserved

/-- The handle of an observed resource, whichever kind it is.

    Deliberately *not* named `ObservedOf.handle`: `ObservedOf` is reducible, so dot-notation on
    an `ObservedOf k` would resolve `o.handle` to this function rather than to the underlying
    structure projection, and it would recurse into itself. -/
def observedHandle : (k : Kind) → ObservedOf k → Handle k
  | .iam,               o => IamObserved.handle o
  | .objectStore,       o => ObjectStoreObserved.handle o
  | .compute,           o => ComputeObserved.handle o
  | .queues,            o => QueuesObserved.handle o
  | .secrets,           o => SecretsObserved.handle o
  | .imageRegistry,     o => ImageRegistryObserved.handle o
  | .postgres,          o => PostgresObserved.handle o
  | .s3Bucket,          o => S3BucketObserved.handle o
  | .securityGroup,     o => SecurityGroupObserved.handle o
  | .awsInstance,       o => AwsInstanceObserved.handle o
  | .scalewayFunctionNamespace,  o => ScalewayFunctionNamespaceObserved.handle o
  | .scalewayFunction,  o => ScalewayFunctionObserved.handle o
  | .scalewayContainerNamespace, o => ScalewayContainerNamespaceObserved.handle o
  | .scalewayContainer, o => ScalewayContainerObserved.handle o

instance : (k : Kind) → ToJson (ObservedOf k)
  | .iam               => inferInstanceAs (ToJson IamObserved)
  | .objectStore       => inferInstanceAs (ToJson ObjectStoreObserved)
  | .compute           => inferInstanceAs (ToJson ComputeObserved)
  | .queues            => inferInstanceAs (ToJson QueuesObserved)
  | .secrets           => inferInstanceAs (ToJson SecretsObserved)
  | .imageRegistry     => inferInstanceAs (ToJson ImageRegistryObserved)
  | .postgres          => inferInstanceAs (ToJson PostgresObserved)
  | .s3Bucket          => inferInstanceAs (ToJson S3BucketObserved)
  | .securityGroup     => inferInstanceAs (ToJson SecurityGroupObserved)
  | .awsInstance       => inferInstanceAs (ToJson AwsInstanceObserved)
  | .scalewayFunctionNamespace  => inferInstanceAs (ToJson ScalewayFunctionNamespaceObserved)
  | .scalewayFunction  => inferInstanceAs (ToJson ScalewayFunctionObserved)
  | .scalewayContainerNamespace => inferInstanceAs (ToJson ScalewayContainerNamespaceObserved)
  | .scalewayContainer => inferInstanceAs (ToJson ScalewayContainerObserved)

/-- `Repr` per kind, alongside the two JSON instances and for the same reason:
    `ObservedOf` is a `def`, so a generic instance cannot be found through it.
    Without this every caller wanting to print observed state writes its own
    twelve-branch dispatch — `example/ScalewayPull.lean` did. -/
instance : (k : Kind) → Repr (ObservedOf k)
  | .iam               => inferInstanceAs (Repr IamObserved)
  | .objectStore       => inferInstanceAs (Repr ObjectStoreObserved)
  | .compute           => inferInstanceAs (Repr ComputeObserved)
  | .queues            => inferInstanceAs (Repr QueuesObserved)
  | .secrets           => inferInstanceAs (Repr SecretsObserved)
  | .imageRegistry     => inferInstanceAs (Repr ImageRegistryObserved)
  | .postgres          => inferInstanceAs (Repr PostgresObserved)
  | .s3Bucket          => inferInstanceAs (Repr S3BucketObserved)
  | .securityGroup     => inferInstanceAs (Repr SecurityGroupObserved)
  | .awsInstance       => inferInstanceAs (Repr AwsInstanceObserved)
  | .scalewayFunctionNamespace  => inferInstanceAs (Repr ScalewayFunctionNamespaceObserved)
  | .scalewayFunction  => inferInstanceAs (Repr ScalewayFunctionObserved)
  | .scalewayContainerNamespace => inferInstanceAs (Repr ScalewayContainerNamespaceObserved)
  | .scalewayContainer => inferInstanceAs (Repr ScalewayContainerObserved)

instance : (k : Kind) → FromJson (ObservedOf k)
  | .iam               => inferInstanceAs (FromJson IamObserved)
  | .objectStore       => inferInstanceAs (FromJson ObjectStoreObserved)
  | .compute           => inferInstanceAs (FromJson ComputeObserved)
  | .queues            => inferInstanceAs (FromJson QueuesObserved)
  | .secrets           => inferInstanceAs (FromJson SecretsObserved)
  | .imageRegistry     => inferInstanceAs (FromJson ImageRegistryObserved)
  | .postgres          => inferInstanceAs (FromJson PostgresObserved)
  | .s3Bucket          => inferInstanceAs (FromJson S3BucketObserved)
  | .securityGroup     => inferInstanceAs (FromJson SecurityGroupObserved)
  | .awsInstance       => inferInstanceAs (FromJson AwsInstanceObserved)
  | .scalewayFunctionNamespace  => inferInstanceAs (FromJson ScalewayFunctionNamespaceObserved)
  | .scalewayFunction  => inferInstanceAs (FromJson ScalewayFunctionObserved)
  | .scalewayContainerNamespace => inferInstanceAs (FromJson ScalewayContainerNamespaceObserved)
  | .scalewayContainer => inferInstanceAs (FromJson ScalewayContainerObserved)

section Guards

#guard card Kind = 14
#guard card ProviderId = 3
#guard card Nothing = 0

-- A handle is kind-indexed: this is the same raw string at two kinds, and the types differ.
private def h1 : Handle .objectStore := { raw := "b-1" }
private def h2 : Handle .secrets := { raw := "b-1" }
#guard h1.raw = h2.raw

end Guards

end Infra.Core
