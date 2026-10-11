import Infra

open Infra.Core Infra.Specs

/-- An existing, same-project Scaleway Private Network. infra validates it
    before writes; it does not manage or delete the VPC itself. -/
def networkId := "00000000-0000-4000-8000-000000000000"

fleet privateServices in paris where
  provider scaleway where
    resource scalewayContainerNamespace "private-services" as ns
      { description := "native access policy example" }
    resource secrets "private-services-db-password"
      { valueFrom := fromEnv "PRIVATE_SERVICES_DB_PASSWORD" }
    resource postgres "private-services-db" as database
      { instanceClass := "db-dev-s"
      , masterUsername := "app_admin"
      , masterPasswordSecret := "private-services-db-password"
      , scalewayAccess := some (ScalewayAccess.internalOnly networkId) }
    resource scalewayContainer "private-services-api" as api
      { namespace' := ns, image := "docker.io/library/httpd:latest"
      , port := 80, access := some (ScalewayAccess.internalOnly networkId) }
    resource scalewayContainer "private-services-app"
      { namespace' := ns, image := "docker.io/library/httpd:latest", port := 80
      , access := some (ScalewayAccess.publicInNetwork networkId)
      , env := (privateUrlOf api).map fun url => [("API_URL", url)] }
    resource scalewayContainer "private-services-admin"
      { namespace' := ns, image := "docker.io/library/nginx:alpine", port := 8080
      , memoryMb := 512, cpuLimit := 500
      , access := some (ScalewayAccess.publicInNetwork networkId)
      , proxy := proxyTo api ["203.0.113.10/32", "2001:db8::10/128"] }

#guard privateServices.plan.accessIsSound

def main (args : List String) : IO UInt32 :=
  Infra.Cli.run "private-services" privateServices (args := args)
