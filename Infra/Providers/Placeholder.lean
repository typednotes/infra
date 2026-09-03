import Infra.Core.Backend

/-
  Honest placeholder scaffolding, shared by both providers.

  There is no live AWS or Scaleway client yet: no SigV4 signing, no OAuth token use, no HTTP.
  Every backend method below returns a value that is obviously not real rather than pretending
  to have talked to a cloud. `list` returning `[]` means "no objects known yet", which is also
  what keeps `actions` from proposing deletions it has no business proposing.
-/

namespace Infra.Providers

open Infra.Core

/-- An `ObservedOf k` with a given handle and placeholder computed fields, for every kind.
    Total over `Kind`, so a new kind cannot be silently unimplemented. -/
def placeholderObserved : (k : Kind) → String → ObservedOf k
  | .iam,              id => { handle := ⟨id⟩, arn := "arn:placeholder" }
  | .objectStore,      id => { handle := ⟨id⟩, url := "https://placeholder.invalid" }
  | .compute,          id => { handle := ⟨id⟩, status := "pending" }
  | .queues,           id => { handle := ⟨id⟩, url := "https://placeholder.invalid/queue" }
  | .secrets,          id => { handle := ⟨id⟩, version := "1" }
  | .imageRegistry,    id => { handle := ⟨id⟩, repositoryUri := "placeholder.invalid/repo" }
  | .postgres,         id => { handle := ⟨id⟩, endpoint := "placeholder.invalid:5432" }
  | .s3Bucket,         id => { handle := ⟨id⟩, arn := "arn:placeholder", region := "eu-west-1" }
  | .scalewayFunction, id => { handle := ⟨id⟩, url := "https://placeholder.invalid/fn" }
  | .scalewayContainer, id => { handle := ⟨id⟩, url := "https://placeholder.invalid/container" }

/-- Every optional field `unknown`: a placeholder has seen nothing, and
    `unknown` is exactly "could not see". Reporting invented values would make
    the engine believe a resource already matched its target. -/
def placeholderReported : (k : Kind) → Handle k → Reported k
  | .iam,              h => { name := h.raw, policies := .unknown }
  | .objectStore,      h => { name := h.raw, versioning := .unknown, tags := .unknown }
  | .compute,          h => { name := h.raw, runtime := .unknown, image := ""
                              executionRole := .unknown, namespace' := .unknown
                              handler := .unknown, memoryMb := .unknown
                              timeoutSec := .unknown, env := .unknown }
  | .queues,           h => { name := h.raw, visibilityTimeoutSec := .unknown }
  | .secrets,          h => { name := h.raw, valueFrom := .fromEnv "" }
  | .imageRegistry,    h => { name := h.raw, immutableTags := .unknown }
  | .postgres,         h => { name := h.raw, instanceClass := .unknown, masterUsername := ""
                              masterPasswordSecret := "", version := .unknown
                              storageGb := .unknown, minCapacity := .unknown
                              maxCapacity := .unknown }
  | .s3Bucket,         h => { name := h.raw, versioning := .unknown,
                              objectLock := .unknown, region := .unknown }
  | .scalewayFunction, h => { name := h.raw, runtime := "", namespace' := ""
                              sourceBucket := .unknown }
  | .scalewayContainer, h => { name := h.raw, namespace' := "", image := ""
                               port := .unknown, minScale := .unknown, maxScale := .unknown
                               memoryMb := .unknown, cpuLimit := .unknown, timeoutSec := .unknown
                               env := .unknown, secretEnv := .unknown }

/-- A backend that talks to nothing. Both providers are this, for now, differing only in the
    identifier they stamp on what they claim to have created. -/
def placeholderBackend (who : String) : Backend where
  list _ := pure []
  read k h := pure (placeholderReported k h)
  create k _ := pure (placeholderObserved k s!"{who}-placeholder-id")
  update k h _ := pure (placeholderObserved k h.raw)
  delete _ _ := pure ()
  -- A canary rather than `""`: the offline self-checks assert this string
  -- never appears in plan output, apply logs, or the `.infra/` cache, which is
  -- how "a composed secret's value does not leak" is actually tested.
  secretValue _ := pure s!"{who}-placeholder-secret-value"

end Infra.Providers
