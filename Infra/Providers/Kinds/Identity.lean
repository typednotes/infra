import Infra.Providers.Aws.Protocols
import Infra.Providers.Scaleway.Rest

/-
  Which account am I actually pointed at?

  Every other call in this directory changes or reads a resource. This one
  exists for a different reason: to refuse to do any of that against the wrong
  account.

  The mistake it prevents is mundane and expensive. Credentials come from a
  three-source chain (`docs/authentication.md`), so the ones in force are
  whichever the environment, the keychain or a config file happened to supply
  — and an exported `AWS_PROFILE`, a stale `SCW_DEFAULT_PROJECT_ID`, or a
  CI secret pointing at staging all look identical at the point of use. The
  first visible sign would be a plan proposing to create a production fleet
  somewhere it does not belong, or worse, `push --apply` doing it.

  A fleet can therefore state which account it is for, and this is what checks
  the claim before anything else happens. Cheap: one call per cloud, made once
  per command, before any resource is listed.
-/

namespace Infra.Providers.Kinds.Identity

open Infra.Core
open Infra.Providers
open Infra.Providers.Aws

/-- The AWS account these credentials belong to, and the ARN of the principal.

    `GetCallerIdentity` is the right call for this and no other: it needs no
    permissions at all, so it cannot fail for a reason unrelated to the answer,
    and it works identically for an IAM user, an assumed role and an Identity
    Center session. -/
def awsCaller (creds : Credentials) : IO (String × String) := do
  let root ← Query.call creds Query.stsEndpoint "GetCallerIdentity" "2011-06-15"
  match root.child "GetCallerIdentityResult" with
  | none => throw (IO.userError "sts GetCallerIdentity returned no result")
  | some r =>
    return ((r.childText "Account").getD "", (r.childText "Arn").getD "")

/-- The Scaleway organization these credentials belong to.

    Scaleway has no `GetCallerIdentity`; the organization is a property of the
    API key, which `iam/v1alpha1/api-keys/<access-key>` reports. Falls back to
    whatever the credential chain already carried, so a config file that sets
    `default_organization_id` still gives an answer if the call is unavailable
    — the check is then weaker, but it is never silently skipped: `none` means
    "could not establish", which the caller treats as a failure, not a pass. -/
def scalewayOwner (creds : Credentials) : IO (Option String) := do
  let attempt ← (do
    let prefix' := Scaleway.globalPrefix "iam" "v1alpha1"
    let reply ← Scaleway.call creds "GET" s!"{prefix'}/api-keys/{creds.accessKey}"
    return JsonRead.stringField reply "organization_id").toBaseIO
  match attempt with
  | .ok (some org) => return some org
  | _              => return creds.organizationId

end Infra.Providers.Kinds.Identity
