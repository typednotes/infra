# Container image selectors and digests

Available since 0.22.0. A declaration may use
`image := "ghcr.io/typednotes/typednotes:latest"`. Each live plan/apply resolves
that selector afresh and compares the selected manifest's SHA-256 with the
digest recorded in the cloud's configured image reference. Apply writes the
frozen `registry/repository@sha256:…` reference, so a registry change during
the rollout cannot change what an already-resolved action deploys.

Same digest: no image update. Different digest: update in place. An older
tag-only configuration needs one update to start recording its content.
Offline `check`, rendering and replay use no registry; teardown looks up no
images. A failed registry/authentication/hash check stops reconciliation rather
than quietly reporting convergence. Migration SQL remains explicitly versioned;
tracking image content does not invent or automatically adopt migrations.

## References and authentication

Docker Hub's short names work (`postgres:17` → `docker.io/library/postgres:17`),
as do qualified HTTPS registry names and ports. OCI and Docker v2 manifests and
indexes are supported. An index is hashed/pinned as an index, without selecting
one architecture; its referenced platform manifests are themselves immutable.
Explicit `@sha256:` pins are recognized without fetching. Insecure HTTP, legacy
schema-1 manifests and non-SHA-256 pins are refused with an error.

Public GHCR and Docker Hub use their anonymous Bearer exchange first, so a stale
Docker login cannot break a public pull. After an authentication refusal, private
auth reads `$DOCKER_CONFIG/config.json` (default `~/.docker/config.json`),
including `auths`, `identitytoken`, `credHelpers` and `credsStore`. Helpers need
to be available on PATH and get a 30-second deadline; their output is never
printed. Standard Basic/Bearer registry authentication is supported. Token scopes
are constrained to the declared repository's `pull`; arbitrary foreign token
realms never receive registry passwords (Docker Hub's `auth.docker.io` is its
explicit documented exception). A private registry with a separate token issuer
must be usable through its Docker identity token or configured credentials.

Without explicit Docker auth, the selected cloud's credentials are used only for
its known registry hosts: Scaleway `rg.<region>.scw.cloud` (`nologin`), Google
Artifact Registry/GCR (OAuth), and standard AWS private ECR hosts
(`ecr:GetAuthorizationToken`, which needs `Resource: "*"`). A different cloud's
registry still needs Docker credentials. AWS China/other custom ECR host forms
can use Docker auth instead of the standard-host native fallback.

No Docker daemon or registry CLI is required for public images or native cloud
auth. OCI's manifest and authentication building blocks are candidates for a
future `linen` module; only infra's target preparation/diff policy belongs here.

## Kubernetes scope

Typed Deployment and StatefulSet shapes are covered. Raw built-in Pod,
Deployment, DaemonSet, StatefulSet, ReplicaSet, ReplicationController, Job and
CronJob shapes resolve all containers, init containers and ephemeral containers
in their pod specifications. Unrelated fields, ConfigMaps and arbitrary CRD
schemas are not interpreted as container specifications.

## Verification

`lake exe infra check` exercises the real resolver with an injected wire and
reconciles snapshots: moved/unchanged tags, same digest under different tags,
pinning during apply, convergence, failed auth/lookups/hash checks, skipped foreign
resources, all compute clouds, Scaleway containers and raw pod image lists.
Public-registry lookup can be verified read-only; actual rollout against every
cloud is separate live coverage, not claimed by the offline checks.

On 2026-10-01 the compiled resolver was checked read-only against all five
Typednotes image repositories' `latest` tags (four on GHCR, pgweb on Docker Hub).
The manifest hashes matched the independently fetched registry digests. Scaleway's
read-only inventory example also passed; no new container rollout was performed.
