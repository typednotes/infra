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

/-- A backend that talks to nothing. Both providers are this, for now, differing only in the
    identifier they stamp on what they claim to have created. -/
def placeholderBackend (who : String) : Backend where
  list _ := pure []
  create k _ := pure (placeholderObserved k s!"{who}-placeholder-id")
  update k h _ := pure (placeholderObserved k h.raw)
  delete _ _ := pure ()

end Infra.Providers
