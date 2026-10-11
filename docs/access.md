# Declarative access policies (0.23.0)

Network visibility is part of the resource target, compared on plan and
reconciled through the provider. No consumer-side networking script is needed.
This release implements Scaleway Serverless Containers and classic Managed
PostgreSQL; unsupported clouds and Serverless SQL are refused explicitly.

## Container properties

`ScalewayContainerSpec` adds:

- `access : Option ScalewayAccess`: existing `privateNetworkId`,
  `publicEndpoint` and `privateEndpoint`.
- `privacy : Option ScalewayContainerPrivacy`: `openAccess` (native public
  privacy) or `authenticated` (Scaleway IAM/token authentication).
- `httpsOnly : Option Bool`, `command` and `args`.
- `proxy : Option (ScalewayContainerProxy K)`: a typed private backend,
  `allowedCidrs` and `pathPrefix`. `proxyTo` hides the staging wrappers.

Unspecified access, privacy, HTTPS and command/args preserve the cloud's choice
during unrelated updates. An explicit access record manages all network/endpoint
settings, including removal of an attachment. Private ingress requires a network.
Setting both endpoints off is supported for containers.

```lean
resource scalewayContainer "api" as api
  { namespace' := ns, image := "docker.io/library/httpd:latest", port := 80
  , access := some (ScalewayAccess.internalOnly networkId) }

resource scalewayContainer "app"
  { namespace' := ns, image := "docker.io/library/httpd:latest", port := 80
  , access := some (ScalewayAccess.publicInNetwork networkId)
  , env := (privateUrlOf api).map fun url => [("API_URL", url)] }

resource scalewayContainer "admin"
  { namespace' := ns, image := "docker.io/library/nginx:alpine", port := 8080
  , memoryMb := 512, cpuLimit := 500
  , access := some (ScalewayAccess.publicInNetwork networkId)
  , proxy := proxyTo api ["203.0.113.10/32", "2001:db8::10/128"] }
```

`privateUrlOf` uses the native private URL in `ScalewayContainerObserved`, never
a URL guessed from the fleet handle (a name, not a UUID). The new `containerId`
and `privateUrl` fields decode older snapshots compatibly. The complete runnable
example is `example/PrivateServices.lean`; its bare invocation is offline.

## Restricted HTTP ingress

Scaleway has no native container IP allowlist. A declared `proxy` manages an
official NGINX container, generated environment/entrypoint and public privacy/
HTTPS. Its single backend needs explicit private-only access on the same network.
The prefix is preserved: use `proxyTo inspector cidrs "/db-inspector/"` with
pgweb's `PGWEB_URL_PREFIX=/db-inspector`.

Filtering covers health and redirects. Empty, malformed and world-open CIDRs
are refused. Recursive XFF resolution trusts the observed internal Scaleway
proxy ranges and keeps the last untrusted client address, preventing forged
leftmost headers from granting access. Application authentication passes through.

Policy metadata is **not** proof of enforcement. Observation checks actual
NGINX config, command/args, image, HTTPS/privacy and the current upstream URL.
Corruption or stale configuration produces drift. Removing a managed proxy
clears its generated environment/entrypoint. `NGINX_CONFIG` and
`INFRA_PROXY_POLICY` are reserved in proxy mode.

Custom domains and triggers bypass default-public-endpoint disabling.
Private-only observation treats them as exposure, and apply refuses conflicting
policy rather than deleting separately configured resources. The same check
applies to a proxy backend. IAM-authenticated upstreams are refused because
the proxy does not inject Scaleway IAM tokens.

## PostgreSQL endpoints

Classic `postgres` adds explicitly provider-specific `scalewayAccess`:

```lean
resource postgres "compute" as db
  { instanceClass := "db-dev-s", masterUsername := "app_admin"
  , masterPasswordSecret := "compute-password"
  , scalewayAccess := some (ScalewayAccess.internalOnly networkId) }
```

Child endpoints are reconciled in place without replacing the data instance.
IPAM assigns the private IP; optional public endpoints are created/removed;
`endpointOf db` reports the actual host/port. Dual-endpoint instances preserve
public endpoint preference; private-only instances use the private endpoint.
At least one PostgreSQL endpoint must remain; its network attachment is its
private endpoint.

The RDB API systematically creates a public endpoint during instance creation.
The provider requests private IPAM in `init_endpoints`, removes the unwanted
public endpoint and waits for policy convergence before returning the observation.
A failed private transition never creates a public fallback. This new native
creation path has not yet been exercised by this release.

Existing same-project networks are prerequisites, validated before writes.
This release does not create/delete VPCs or Private Networks. AWS/GCP and
Serverless SQL reject `scalewayAccess`; Serverless SQL remains public and
IAM-protected unless migrated to another product.

## Planning and verification

`Plan.accessProblem`/`accessIsSound` validates literal policies before work is
derived. Changes are mutable updates and retain the ownership gate. Typed proxy
references and observed URLs add dependency edges. Endpoint changes update
container callers in dependency order. Existing connection secrets require
`--refresh-secrets`; a plan without it refuses rather than keeping stale URLs.
With the flag, recipes evaluate after endpoint changes and copied bindings follow.
Secret values remain absent from plans/logs.

Terraform export marks compound policies as explicit TODOs; it does not claim
a proxy/endpoint-policy round-trip.

Generated Scaleway container/v1 and rdb/v1 SDKs were checked 2026-10-11. The
container adapter uses v1 `image`, byte-valued memory, `mvcpu_limit`, duration
strings and environment maps. HTTPS request spelling differs on create
(`https_connections_only`) and update (`https_connection_only`); both are tested.

`checkNetworkAccess` covers payloads/readback, legacy snapshots, private PostgreSQL
parsing, unsupported-product and proxy-bypass refusal, enforcement drift and
dependent URL/secret refresh. New provider live verification is read-only;
native create/update round-trip coverage is not yet claimed. Read-only native
policy observation passed for all eight Typednotes containers and its private
compute database on 2026-10-11, including omitted nullable API fields.
