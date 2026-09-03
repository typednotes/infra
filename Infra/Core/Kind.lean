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
  deriving Repr, DecidableEq, BEq

instance : Finite ProviderId where
  elems := [.aws, .scaleway]
  complete := by intro a; cases a <;> simp
  nodup := by decide

def ProviderId.name : ProviderId → String
  | .aws      => "aws"
  | .scaleway => "scaleway"

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
  | scalewayFunction
  | scalewayContainer
  deriving Repr, DecidableEq, BEq

instance : Finite Kind where
  elems :=
    [.iam, .objectStore, .compute, .queues, .secrets, .imageRegistry, .postgres,
     .s3Bucket, .scalewayFunction, .scalewayContainer]
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
  | .scalewayFunction   => "scaleway-function"
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
  | .scalewayFunction  => ScalewayFunctionObserved
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
  | .scalewayFunction,  o => ScalewayFunctionObserved.handle o
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
  | .scalewayFunction  => inferInstanceAs (ToJson ScalewayFunctionObserved)
  | .scalewayContainer => inferInstanceAs (ToJson ScalewayContainerObserved)

instance : (k : Kind) → FromJson (ObservedOf k)
  | .iam               => inferInstanceAs (FromJson IamObserved)
  | .objectStore       => inferInstanceAs (FromJson ObjectStoreObserved)
  | .compute           => inferInstanceAs (FromJson ComputeObserved)
  | .queues            => inferInstanceAs (FromJson QueuesObserved)
  | .secrets           => inferInstanceAs (FromJson SecretsObserved)
  | .imageRegistry     => inferInstanceAs (FromJson ImageRegistryObserved)
  | .postgres          => inferInstanceAs (FromJson PostgresObserved)
  | .s3Bucket          => inferInstanceAs (FromJson S3BucketObserved)
  | .scalewayFunction  => inferInstanceAs (FromJson ScalewayFunctionObserved)
  | .scalewayContainer => inferInstanceAs (FromJson ScalewayContainerObserved)

section Guards

#guard card Kind = 10
#guard card ProviderId = 2
#guard card Nothing = 0

-- A handle is kind-indexed: this is the same raw string at two kinds, and the types differ.
private def h1 : Handle .objectStore := { raw := "b-1" }
private def h2 : Handle .secrets := { raw := "b-1" }
#guard h1.raw = h2.raw

end Guards

end Infra.Core
