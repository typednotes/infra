import Infra.Providers.Gcp.Rest
import Infra.Core.Stage

/-
  Container image repositories on GCP: Artifact Registry.

  Container Registry (`gcr.io`) is the older service and the wrong target: it
  is deprecated, it has no create call — a repository appears when the first
  image is pushed — and so there is nothing for a declarative tool to create.
  Artifact Registry has real, named, createable repositories.

  ## Regional, and the first kind here that is

  A repository lives in a location, so its path carries one, taken from the
  credentials' region like every other endpoint in this library. A consequence
  worth knowing: the same repository name in two regions is two repositories,
  and moving a fleet between regions will propose creating the second rather
  than seeing the first.

  ## Creation is asynchronous

  Both create and delete return a long-running operation, so both wait for it.
  That is new for this kind — ECR and Scaleway's registry both finish inline —
  and it is why `Gcp.Rest.awaitLro` exists.

  Endpoints and field names checked against Google's Artifact Registry REST
  reference (`v1`, `projects.locations.repositories`), 2026-09.
-/

namespace Infra.Providers.Gcp.ArtifactRegistry

open Infra.Core
open Infra.Providers
open Infra.Providers.Gcp
open Infra.Providers.JsonRead
open Data.Json (Value)
open Network.HTTP.Types (Query)

def host : String := "artifactregistry.googleapis.com"

private def parent (project location : String) : String :=
  s!"/v1/projects/{project}/locations/{location}/repositories"

private def repoPath (project location name : String) : String :=
  parent project location ++ "/" ++ name

/-- Where a pushed image would be addressed. The analogue of ECR's
    `repositoryUri`. -/
def repositoryUri (project location name : String) : String :=
  s!"{location}-docker.pkg.dev/{project}/{name}"

/-- Every Docker repository in the project and location, with its URI. -/
def list (creds : Credentials) (project location : String) :
    IO (List (String × String)) := do
  let rec go (fuel : Nat) (token : String) (acc : List (String × String)) :
      IO (List (String × String)) := do
    match fuel with
    | 0 =>
      IO.eprintln "warning: gcp artifact registry: stopped paginating repositories \
after 50 pages; the list may be incomplete"
      return acc
    | fuel' + 1 =>
      let query : Query := if token.isEmpty then [] else [("pageToken", some token)]
      let reply ← Gcp.call creds "GET" host (parent project location) query
      let here := (arrayField reply "repositories").filterMap fun r =>
        (stringField r "name").map fun n =>
          let short := Gcp.shortName n
          (short, repositoryUri project location short)
      let acc := acc ++ here
      match stringField reply "nextPageToken" with
      | some next => if next.isEmpty then return acc else go fuel' next acc
      | none      => return acc
  go 50 "" []

/-- Whether tags are immutable.

    Artifact Registry carries this under `dockerConfig.immutableTags`, and a
    repository created without the field simply does not report it — which is
    `unknown`, not `false`. -/
def readImmutable (creds : Credentials) (project location name : String) :
    IO (Partial Bool) := do
  let reply ← Gcp.call creds "GET" host (repoPath project location name)
  match field reply "dockerConfig" with
  | none => return .unknown
  | some cfg =>
    match boolField cfg "immutableTags" with
    | some b => return .known b
    | none   => return .unknown

/-- Create a Docker repository and wait for it. Returns its URI. -/
def create (creds : Credentials) (project location name : String)
    (immutableTags : Bool) : IO String := do
  let payload : Value := .object
    [ ("format", .string "DOCKER")
    , ("dockerConfig", .object [("immutableTags", .bool immutableTags)]) ]
  let started ← Gcp.call creds "POST" host (parent project location)
    [("repositoryId", some name)] (payload := some payload)
  discard <| Gcp.awaitLro creds host "v1" started s!"artifact registry: create {name}"
  return repositoryUri project location name

/-- Turn tag immutability on or off. `PATCH` with an explicit update mask,
    which Artifact Registry requires — without it the call is accepted and
    changes nothing, which is the silent no-op this codebase treats as a bug
    rather than a quirk. -/
def setImmutable (creds : Credentials) (project location name : String)
    (immutableTags : Bool) : IO Unit := do
  discard <| Gcp.call creds "PATCH" host (repoPath project location name)
    [("updateMask", some "dockerConfig.immutableTags")]
    (payload := some (.object
      [("dockerConfig", .object [("immutableTags", .bool immutableTags)])]))

/-- Delete the repository and everything in it, and wait for it.

    Deleting takes the images with it, which is why this is not softened: a
    `destroy` that left a repository of images behind while reporting success
    would be the more expensive lie. -/
def delete (creds : Credentials) (project location name : String) : IO Unit := do
  match ← (Gcp.call creds "DELETE" host (repoPath project location name)).toBaseIO with
  | .error e =>
    let msg := toString e
    unless (msg.splitOn "HTTP 404").length > 1 || (msg.splitOn "NOT_FOUND").length > 1 do
      throw e
  | .ok started =>
    discard <| Gcp.awaitLro creds host "v1" started s!"artifact registry: delete {name}"

#guard repositoryUri "typednotes" "europe-west9" "images"
  = "europe-west9-docker.pkg.dev/typednotes/images"

end Infra.Providers.Gcp.ArtifactRegistry
