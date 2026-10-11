import Infra.Core.Kind
import Infra.Core.Expr
import Std.Net.Addr

namespace Infra.Specs

open Infra.Core
open Lean (ToJson FromJson)

/-- Native Scaleway endpoint policy. Network ids reference existing networks;
    infra does not own/create the VPC. Containers and classic RDB implement
    this policy; Serverless SQL and the other clouds refuse it.
    Verified against the generated container/v1 and rdb/v1 SDK, 2026-10-11. -/
structure ScalewayAccess where
  privateNetworkId : Option String := none
  publicEndpoint : Bool := true
  privateEndpoint : Bool := false
  deriving Repr, DecidableEq, BEq, ToJson, FromJson

def ScalewayAccess.internalOnly (networkId : String) : ScalewayAccess :=
  { privateNetworkId := some networkId, publicEndpoint := false, privateEndpoint := true }

def ScalewayAccess.publicInNetwork (networkId : String) : ScalewayAccess :=
  { privateNetworkId := some networkId, publicEndpoint := true }

def ScalewayAccess.problem (access : ScalewayAccess) : Option String :=
  if access.privateNetworkId.any (fun id => id.isEmpty ||
      !id.toList.all (fun c => c.isAlphanum || c == '-')) then
    some "privateNetworkId must be a non-empty Scaleway network id"
  else if access.privateEndpoint && access.privateNetworkId.isNone then
    some "privateEndpoint requires privateNetworkId"
  else none

inductive ScalewayContainerPrivacy where
  | openAccess | authenticated
  deriving Repr, DecidableEq, BEq

def ScalewayContainerPrivacy.apiValue : ScalewayContainerPrivacy → String
  | .openAccess => "public"
  | .authenticated => "private"

/-- IP-restricted, single-upstream HTTP ingress. A typed reference makes the
    private upstream a dependency. The provider runs the official NGINX image,
    writes its config and checks actual config/command readback for drift.
    The path prefix is preserved (e.g. pgweb's /db-inspector/). -/
structure ScalewayContainerProxy (K : ProviderId → Kind → Type) where
  backend : K .scaleway .scalewayContainer
  allowedCidrs : List String
  pathPrefix : String := "/"

/-- Avoid exposing the key-family/staging wrappers when authoring a proxy. -/
def proxyTo {K : ProviderId → Kind → Type} (backend : K .scaleway .scalewayContainer)
    (allowedCidrs : List String) (pathPrefix := "/") : Expr K (Option (ScalewayContainerProxy K)) :=
  .lit (some { backend, allowedCidrs, pathPrefix })

instance {K} [BEq (K .scaleway .scalewayContainer)] : BEq (ScalewayContainerProxy K) where
  beq a b := a.backend == b.backend && a.pathPrefix == b.pathPrefix &&
    a.allowedCidrs.mergeSort (· ≤ ·) == b.allowedCidrs.mergeSort (· ≤ ·)

instance {K} [Repr (K .scaleway .scalewayContainer)] : Repr (ScalewayContainerProxy K) where
  reprPrec proxy _ := "{ backend := " ++ repr proxy.backend ++
    ", allowedCidrs := " ++ repr proxy.allowedCidrs ++ ", pathPrefix := " ++ repr proxy.pathPrefix ++ " }"

def boundedCidr (cidr : String) : Bool :=
  match cidr.splitOn "/" with
  | [address, bits] =>
    match bits.toNat? with
    | some n => n > 0 &&
      (((Std.Net.IPv4Addr.ofString address).isSome && n ≤ 32) ||
       ((Std.Net.IPv6Addr.ofString address).isSome && n ≤ 128))
    | none => false
  | _ => false

def ScalewayContainerProxy.problem {K} (proxy : ScalewayContainerProxy K) : Option String :=
  if proxy.allowedCidrs.isEmpty || !proxy.allowedCidrs.all boundedCidr then
    some "proxy.allowedCidrs must contain bounded IPv4/IPv6 CIDRs (no empty or world-open policy)"
  else if !proxy.pathPrefix.startsWith "/" || !proxy.pathPrefix.endsWith "/" ||
      !proxy.pathPrefix.toList.all (fun c => c.isAlphanum || c == '/' || c == '-' || c == '_') then
    some "proxy.pathPrefix must be a literal slash-delimited path ending in '/'"
  else none

def isNginxImage (image : String) : Bool :=
  ["docker.io/library/nginx:", "docker.io/library/nginx@", "nginx:", "nginx@"].any fun prefix_ => image.startsWith prefix_

/-- Runtime generated config uses only a validated private hostname. The
    observed ingress peer/proxy ranges were checked against Scaleway on
    2026-10-11; recursive resolution retains the last untrusted client address. -/
def nginxProxyConfig (port : Nat) (allowedCidrs : List String) (pathPrefix backendHost : String) : String :=
  "events {}\nhttp {\n  resolver 169.254.169.254 valid=10s ipv6=off;\n" ++
  String.join (["127.0.0.1", "::1", "100.64.0.0/10", "10.0.0.0/8", "172.16.0.0/12",
    "192.168.0.0/16", "fc00::/7"].map fun range => s!"  set_real_ip_from {range};\n") ++
  "  real_ip_header X-Forwarded-For;\n  real_ip_recursive on;\n" ++
  "  geo $operator_allowed {\n    default 0;\n" ++
  String.join ((allowedCidrs.mergeSort (· ≤ ·)).map fun cidr => s!"    {cidr} 1;\n") ++
  "  }\n  access_log /dev/stdout;\n  error_log /dev/stderr;\n" ++
  "  map $http_upgrade $connection_upgrade { default upgrade; '' close; }\n" ++
  s!"  server \{\n    listen {port};\n" ++
  "    if ($operator_allowed = 0) { return 403; }\n" ++
  "    client_max_body_size 64m;\n    proxy_read_timeout 900s;\n" ++
  "    proxy_http_version 1.1;\n    proxy_set_header Upgrade $http_upgrade;\n" ++
  "    proxy_set_header Connection $connection_upgrade;\n" ++
  "    proxy_set_header X-Forwarded-For $remote_addr;\n" ++
  "    proxy_set_header X-Forwarded-Proto https;\n" ++
  "    location = /health { return 200 'ok'; }\n" ++
  (if pathPrefix == "/" then "" else
    s!"    location = {(pathPrefix.dropEnd 1).toString} \{ return 301 {pathPrefix}; }\n") ++
  s!"    location {pathPrefix} \{\n      set $backend {backendHost};\n" ++
  "      proxy_set_header Host $backend;\n      proxy_pass http://$backend;\n    }\n" ++
  (if pathPrefix == "/" then "" else "    location / { return 404; }\n") ++
  "  }\n}\n"

def nginxProxyCommand : List String := ["/bin/sh"]
def nginxProxyArgs : List String :=
  ["-c", "printf '%s' \"$NGINX_CONFIG\" > /etc/nginx/nginx.conf; exec nginx -g 'daemon off;'"]

#guard boundedCidr "203.0.113.10/32"
#guard boundedCidr "2001:db8::10/128"
#guard !boundedCidr "0.0.0.0/0"
#guard !boundedCidr "::/0"
#guard !boundedCidr "1.2.3.999/32"
#guard !boundedCidr "1.2.3.4/33"
#guard !boundedCidr "1.2.3.4/32; allow all"

end Infra.Specs
