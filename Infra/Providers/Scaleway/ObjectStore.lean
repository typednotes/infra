import Infra.Abstractions.ObjectStore

/-
  Scaleway object store, backed entirely by `Infra.Abstractions.ObjectStore` — see
  `docs/architecture.md`'s Abstractions section. No live Scaleway client yet: `Backend` is an
  empty placeholder handle and every method returns an honest placeholder value.
-/

namespace Infra.Providers.Scaleway.ObjectStore

open Infra.Abstractions
open Infra.Core

structure Backend where

instance : ObjectStoreBackend Backend where
  listBuckets _ := pure []
  createBucket _ t := pure { name := t.name.getD "unnamed", id := "placeholder-id", tags := t.tags.getD [] }
  updateBucket _ c d := pure (Diffable.apply (Target := BucketTarget) c d)
  deleteBucket _ _ := pure ()

end Infra.Providers.Scaleway.ObjectStore
