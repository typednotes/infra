import Infra.Abstractions.ServerlessCompute

/-
  Scaleway serverless compute (Serverless Functions), backed entirely by
  `Infra.Abstractions.ServerlessCompute` — see `docs/architecture.md`'s Abstractions section.
  No live Scaleway client yet: `Backend` is an empty placeholder handle and every method
  returns an honest placeholder value.
-/

namespace Infra.Providers.Scaleway.Compute

open Infra.Abstractions
open Infra.Core

structure Backend where

instance : ServerlessComputeBackend Backend where
  createCompute _ t :=
    pure { name := t.name.getD "unnamed", id := "placeholder-id", runtime := t.runtime.getD "", status := "pending" }
  updateCompute _ c d := pure (Diffable.apply (Target := ComputeTarget) c d)
  deleteCompute _ _ := pure ()

end Infra.Providers.Scaleway.Compute
