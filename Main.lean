import Infra

open Infra.Core
open Infra.Demo

/-- Whether `needle` occurs in `haystack`. Used by the leak checks, which are
    the only reason this file needs a substring test — one copy, so the four
    call sites cannot drift. -/
private def mentions (haystack needle : String) : Bool :=
  (haystack.splitOn needle).length > 1

/-- Where a slot first appears in a rendered plan, for the ordering checks. -/
private def slotIdx (lines : List String) (needle : String) : Option Nat :=
  lines.findIdx? fun l => mentions l needle

/-- The boundary of the demo fleets, named `demo` — what `Infra.Cli.run`
    resolves every fleet's boundary to (`Fleet.name`). -/
private def demo : Boundary := { fleetName := some "demo" }

/-- `Infra.Providers.all`, except every backend reports the marker — what a
    real backend reports for resources the `demo` fleet created. The
    placeholder alone answers `.unreadable`, which `push` now treats as "not
    ours": it refuses to change or destroy a resource it cannot verify. -/
private def ownedBackends : Backends where
  backend p :=
    { Infra.Providers.placeholderBackend p.name with
        ownershipInfo := fun _ _ => pure (.tags [(markerKey, "demo")] none) }

/-- A `Backends` whose `.aws` backend answers `ownershipInfo` with a fixed
    verdict, rather than the placeholder default of `.unreadable`. This is what
    lets the checks below exercise `Ownership.ownershipOf` itself — the
    placeholder backends alone can only ever exercise the refusal path, since
    their `ownershipInfo` never reports any evidence. -/
private def gatedBackends (marked : Bool) (value : String := "demo") :
    Backends where
  backend
    | .aws =>
      { Infra.Providers.placeholderBackend "aws" with
          ownershipInfo := fun _ _ =>
            pure (.tags (if marked then [(markerKey, value)] else []) none) }
    | .scaleway => Infra.Providers.placeholderBackend "scaleway"
    | .gcp      => Infra.Providers.placeholderBackend "gcp"

/-- The same, on the **name** rung: a backend for a kind that cannot carry a
    marker at all, which reports only the resource's name.

    Separate from `gatedBackends` because the interesting property is that the
    two rungs reach the same verdicts by different evidence, and a double that
    could only produce tags could not show that. -/
private def namedBackends (nm : String) : Backends where
  backend
    | .aws =>
      { Infra.Providers.placeholderBackend "aws" with
          ownershipInfo := fun _ _ => pure (.named nm none) }
    | .scaleway => Infra.Providers.placeholderBackend "scaleway"
    | .gcp      => Infra.Providers.placeholderBackend "gcp"

/-- The marker gates every change to a declared resource: a bucket holding a
    declared name without this fleet's marker is not replaced, and the run
    says so by name; with the marker, the same drift is a replace. -/
def checkOwnershipGate : IO Unit := do
  let (said, lines) ← IO.FS.withIsolatedStreams
    (push (gatedBackends false) demoPlan immutableDriftWorld {} (boundary := demo))
  if lines.any (mentions · "REPLACE aws/s3-bucket/cold") then
    throw (IO.userError s!"replaced a bucket that does not carry the marker: {lines}")
  unless mentions said "aws/s3-bucket/cold" && mentions said markerKey do
    throw (IO.userError s!"an unmarked declared bucket was passed over silently: {said}")
  let marked ← push (gatedBackends true) demoPlan immutableDriftWorld {} (boundary := demo)
  unless marked.any (mentions · "REPLACE aws/s3-bucket/cold") do
    throw (IO.userError s!"a marked bucket with drift was not replaced: {marked}")
  IO.println "ownership gate: ok (a declared name is changed only if it carries the marker)"

/-- Two fleets, one account, one bucket name — the marker's *value* keeps them
    apart. Only this fleet's own name is accepted: another fleet's value, and
    the retired `true`, are as good as no marker — and say so by name — and a
    boundary without a name accepts nothing. -/
def checkFleetIsolation : IO Unit := do
  let changes (me : Option String) (tagValue : String) : IO Bool := do
    let (_, lines) ← IO.FS.withIsolatedStreams
      (push (gatedBackends true tagValue) demoPlan immutableDriftWorld {}
        (boundary := { fleetName := me }))
    return lines.any (mentions · "REPLACE aws/s3-bucket/cold")
  if ← changes (some "mine") "theirs" then
    throw (IO.userError "changed a bucket marked by another fleet")
  unless ← changes (some "mine") "mine" do
    throw (IO.userError "did not change a bucket carrying this fleet's own name")
  if ← changes (some "mine") retiredMarkerValue then
    throw (IO.userError "changed a declared bucket carrying the retired marker value")
  if ← changes none "anything-at-all" then
    throw (IO.userError "a boundary without a name changed a marked bucket")
  -- The retired value is not passed over silently: the warning names it and
  -- says how to take the resource back.
  let (said, _) ← IO.FS.withIsolatedStreams
    (push (gatedBackends true retiredMarkerValue) demoPlan immutableDriftWorld {}
      (boundary := { fleetName := some "mine" }))
  unless mentions said s!"{markerKey}={retiredMarkerValue}" && mentions said s!"{markerKey}=mine" do
    throw (IO.userError s!"the retired marker was not named, with its fix: {said}")
  IO.println "fleet isolation: ok (only this fleet's own name is accepted; the retired \
'true' matches no fleet, and says how to retag)"

/-- An orphan's marker is re-checked at the moment of deleting it, on both
    rungs: gone, the delete is refused; present, it proceeds. -/
def checkOrphanRecheck : IO Unit := do
  let old : Orphan := { cloud := .aws, kind := .objectStore, name := "old-bucket", region := "eu-west-1" }
  let refused (bs : Backends) (b : Boundary) : IO Bool := do
    match ← (push bs demoPlan emptyWorld { apply := true } (orphans := [old])
        (boundary := b)).toBaseIO with
    | .error e => return mentions (toString e) "no longer carries this fleet's marker"
    | .ok _    => return false
  let deleted (bs : Backends) (b : Boundary) : IO Bool := do
    let lines ← push bs demoPlan emptyWorld { apply := true } (orphans := [old]) (boundary := b)
    return lines.any (mentions · "DELETE aws/object-store/old-bucket")
  let me : Boundary := { fleetName := some "me" }
  unless ← refused (gatedBackends false) me do
    throw (IO.userError "deleted an orphan whose marker is gone")
  unless ← deleted (gatedBackends true "me") me do
    throw (IO.userError "did not delete an orphan carrying this fleet's name")
  -- The retired value belongs to no fleet, and a boundary without a name
  -- claims nothing by tag.
  unless ← refused (gatedBackends true retiredMarkerValue) me do
    throw (IO.userError "deleted an orphan carrying the retired marker value")
  unless ← refused (gatedBackends true) {} do
    throw (IO.userError "a boundary without a name deleted an undeclared resource by tag")
  -- The name rung: no prefix, or a wrong one, refuses; a matching one deletes.
  unless ← refused (namedBackends "old-bucket") {} do
    throw (IO.userError "deleted a name-only orphan with no prefix configured")
  unless ← refused (namedBackends "old-bucket") { namePrefix := some "mine-" } do
    throw (IO.userError "deleted a name-only orphan outside the prefix")
  unless ← deleted (namedBackends "old-bucket") { namePrefix := some "old-" } do
    throw (IO.userError "did not delete a name-only orphan inside the prefix")
  IO.println "orphan recheck: ok (a stripped or retired marker refuses the delete; this fleet's name lets it proceed)"
  IO.println "name rung: ok (no prefix and a wrong prefix both refuse; a matching one deletes)"

/-- A refused orphan delete is retried, and only fails when it stops making
    progress: orphans have no edges to sort by, so a provider's
    "DependencyViolation" is taken at its word and asked again after the rest.
    A refusal that never clears fails the apply in the provider's own words. -/
def checkOrphanRetry : IO Unit := do
  let orphan (nm : String) : Orphan :=
    { cloud := .aws, kind := .objectStore, name := nm, region := "eu-west-1" }
  let orphans := [orphan "blocked", orphan "other"]
  let flaky (limit : Nat) : IO (Backends × IO.Ref Nat) := do
    let tries ← IO.mkRef 0
    return ({ backend := fun p =>
                { Infra.Providers.placeholderBackend p.name with
                    ownershipInfo := fun _ _ => pure (.tags [(markerKey, "me")] none)
                    delete := fun _ h => do
                      if h.raw == "blocked" && (← tries.get) < limit then
                        tries.modify (· + 1)
                        throw (IO.userError "DependencyViolation: resource is in use")
                      pure () } }, tries)
  let (bs, tries) ← flaky 1
  let lines ← push bs (Plan.absent demoKeys) emptyWorld { apply := true } (orphans := orphans)
    (boundary := { fleetName := some "me" })
  unless (← tries.get) == 1 do
    throw (IO.userError "the refusal never happened, so the retry proves nothing")
  for nm in ["blocked", "other"] do
    unless lines.any (mentions · s!"aws/object-store/{nm}") do
      throw (IO.userError s!"the log does not report deleting {nm}: {lines}")
  let (stuck, _) ← flaky 99
  match ← (push stuck (Plan.absent demoKeys) emptyWorld { apply := true }
      (orphans := orphans) (boundary := { fleetName := some "me" })).toBaseIO with
  | .ok l => throw (IO.userError s!"a permanently refused delete reported success: {l}")
  | .error e =>
    for expected in ["aws/object-store/blocked", "DependencyViolation"] do
      unless mentions (toString e) expected do
        throw (IO.userError s!"the refusal does not mention {expected}: {toString e}")
  IO.println "orphan retry: ok (a refused orphan delete is retried; a permanent \
refusal still fails)"

/-- `imageId := "latest"` must not diverge.

    It reads like an image id and is not one: it is an instruction, carried out
    inside `Live.liveBackend`'s `create` by asking `DescribeImages` for the
    newest Amazon Linux 2023 in the instance's own region. So the target holds
    the word `"latest"` and the instance reports `ami-…` — never equal, and
    `imageId` forces a replace. The live test found what that means: `REPLACE`
    in every plan for ever, a fleet that cannot converge, and an apply that
    destroys and recreates a healthy instance each time.

    Nothing offline could see it, because the resolution only exists in the
    live backend. This check is the offline stand-in: it compares a target
    saying `"latest"` against a report saying a real id, which is exactly the
    pair a live pull produces. -/
def checkLatestImage : IO Unit := do
  let spec (imageId : String) : ProviderSpec .awsInstance :=
    { name := "vm", imageId := imageId
      instanceType := InstanceType.of .t3 .nano
      securityGroup := ⟨"sg"⟩, keyName := "", subnetId := "" }
  let seen (imageId : String) : Reported .awsInstance :=
    { name := "vm", imageId := imageId
      instanceType := InstanceType.of .t3 .nano
      securityGroup := ⟨"sg"⟩, keyName := .unknown, subnetId := .unknown }
  let fields (t : ProviderSpec .awsInstance) (r : Reported .awsInstance) : List String :=
    (divergence .awsInstance t r).map (·.1)

  unless fields (spec "latest") (seen "ami-0123456789abcdef0") == [] do
    throw (IO.userError s!"'latest' diverged from a resolved AMI id: \
{fields (spec "latest") (seen "ami-0123456789abcdef0")} — every plan would REPLACE the instance")
  -- A pinned id still means what it says, which is the half that must survive
  -- the exemption: this is drift detection, not an excuse to stop comparing.
  unless fields (spec "ami-1111111111111111") (seen "ami-2222222222222222") == ["imageId"] do
    throw (IO.userError "a pinned AMI id stopped being compared")
  unless fields (spec "ami-1111111111111111") (seen "ami-1111111111111111") == [] do
    throw (IO.userError "a matching pinned AMI id reported drift")
  IO.println "latest AMI: ok ('latest' converges; a pinned id still detects drift)"

/-- An unset optional launch field must not diverge either.

    The same failure as `checkLatestImage` from the other side: there the
    target was an instruction, here it is an absence the cloud fills in.
    `subnetId` is optional and settles to `""`, every EC2 instance is in a
    subnet, so `DescribeInstances` reports `subnet-…`, and the field is
    `.forcesReplace` — `REPLACE` in every plan for ever. That is what the AWS
    leg of the 2026-09-08 live run failed on, after ten polls of a fleet that
    could never converge.

    Invisible offline until this check, for the reason `docs/diff-semantics.md`
    gives: the placeholder backend reports `subnetId := .unknown`, and
    `unknown` contributes nothing to a divergence. So the report here is built
    by hand to be what a live pull actually returns. -/
def checkUnsetLaunchField : IO Unit := do
  let spec (keyName subnetId : String) : ProviderSpec .awsInstance :=
    { name := "vm", imageId := "ami-1111111111111111"
      instanceType := InstanceType.of .t3 .nano
      securityGroup := ⟨"sg"⟩, keyName, subnetId }
  let seen (keyName subnetId : String) : Reported .awsInstance :=
    { name := "vm", imageId := "ami-1111111111111111"
      instanceType := InstanceType.of .t3 .nano
      securityGroup := ⟨"sg"⟩
      keyName := .known keyName, subnetId := .known subnetId }
  let fields (t : ProviderSpec .awsInstance) (r : Reported .awsInstance) : List String :=
    (divergence .awsInstance t r).map (·.1)

  -- Unset, and the cloud chose: not a request, so not a divergence.
  unless fields (spec "" "") (seen "kp-ci" "subnet-0abc") == [] do
    throw (IO.userError s!"an unset subnet/key pair diverged from what AWS assigned: {fields (spec "" "") (seen "kp-ci" "subnet-0abc")} — every plan would REPLACE the instance and it would never converge")
  -- Asked for, and honoured.
  unless fields (spec "kp-ci" "subnet-0abc") (seen "kp-ci" "subnet-0abc") == [] do
    throw (IO.userError "a satisfied subnet request reported drift")
  -- Asked for, and not honoured: the half that must survive the exemption.
  unless fields (spec "kp-ci" "subnet-0abc") (seen "kp-ci" "subnet-0def") == ["subnetId"] do
    throw (IO.userError "a declared subnet stopped being compared")
  unless fields (spec "kp-ci" "subnet-0abc") (seen "kp-other" "subnet-0abc") == ["keyName"] do
    throw (IO.userError "a declared key pair stopped being compared")
  IO.println "unset launch fields: ok (a subnet nobody asked for converges; a declared one still detects drift)"

/-- Pulls from both placeholder backends, caches the result, and reports what the target would
    still ask for. Nothing behind `list` is live yet, so the world comes back empty and every
    declared resource needs creating. -/
def checkPullAndPlan : IO Unit := do
  let world ← pull (κ := demoKeys) Infra.Providers.all
  let work := plan demoPlan world
  IO.println s!"pull: world observed, {work.length} actions outstanding"
  IO.println s!"idle plan (all unmanaged): {(plan idlePlan world).length} actions"

/-- Exercises the credential chain against a scratch home directory.

    Only the file source can be driven deterministically from here: Lean has no
    `setenv`, so the environment source is checked by running this binary with
    the variables set (see `docs/providers.md`). The not-found message is only
    asserted when the real environment is genuinely empty, so a developer with
    `AWS_ACCESS_KEY_ID` exported does not see a spurious failure. -/
def checkCredentials : IO Unit := do
  let tmp ← IO.FS.createTempDir
  try
    let paths := Paths.under tmp
    IO.FS.createDirAll (tmp / ".aws")
    IO.FS.writeFile paths.awsCredentials
      "[default]\n\
       aws_access_key_id = AKIAIOSFODNN7EXAMPLE\n\
       aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\n"
    IO.FS.writeFile paths.awsConfig "[default]\nregion = eu-west-1\n"
    let aws ← loadFrom paths .aws
    unless aws.accessKey == "AKIAIOSFODNN7EXAMPLE" do
      throw (IO.userError "aws access key not read from ~/.aws/credentials")
    -- The region comes from the *other* file, which is where `aws configure`
    -- puts it.
    unless aws.region == "eu-west-1" do
      throw (IO.userError s!"aws region not read from config: {aws.region}")

    IO.FS.createDirAll (tmp / ".config" / "scw")
    IO.FS.writeFile paths.scwConfig
      "access_key: SCWXXXXXXXXXXXXXXXXX\n\
       secret_key: 7f0a4e33-1234-5678-9abc-def012345678\n\
       default_region: fr-par\n\
       default_project_id: 11111111-1111-1111-1111-111111111111\n\
       default_organization_id: 22222222-2222-2222-2222-222222222222\n"
    let scw ← loadFrom paths .scaleway
    unless scw.accessKey == "SCWXXXXXXXXXXXXXXXXX" && scw.region == "fr-par" do
      throw (IO.userError "scaleway credentials not read from config.yaml")
    -- `iam` and creation calls are organization-/project-scoped
    -- (`docs/authentication.md`), so a config file that sets these two but
    -- doesn't get them read back is a silent failure, not a missing feature.
    unless scw.projectId == some "11111111-1111-1111-1111-111111111111" do
      throw (IO.userError s!"scaleway project id not read from config.yaml: {scw.projectId}")
    unless scw.organizationId == some "22222222-2222-2222-2222-222222222222" do
      throw (IO.userError
        s!"scaleway organization id not read from config.yaml: {scw.organizationId}")

    -- Secrets must not survive rendering: this is what stops a stray trace or
    -- an error message from leaking one.
    let shown := toString aws
    if mentions shown "wJalrXUtnFEMI" then
      throw (IO.userError "Credentials rendering leaked the secret key")
    unless mentions shown "<redacted>" do
      throw (IO.userError "Credentials rendering did not redact")

    -- GCP's first source is added from above (`GcpAuth.loadWithKeyFile`), so
    -- nothing in `Credentials` can try it — but the not-found message is built
    -- there, and a source the user is never told about is a source they cannot
    -- use. Order matters too: it is what decides whether an explicit key or
    -- whatever `gcloud` last logged into wins.
    let gcpSources := sourceDescriptions paths .gcp "default"
    for expected in [gcpKeyFileVar, "gcloud", "keychain", "GOOGLE_OAUTH_ACCESS_TOKEN"] do
      unless gcpSources.any (mentions · expected) do
        throw (IO.userError s!"the gcp source list omits {expected}: {gcpSources}")
    unless (gcpSources.head?.map (mentions · gcpKeyFileVar)).getD false do
      throw (IO.userError s!"the gcp source list does not lead with the key file: {gcpSources}")

    -- With no config, no keychain entry and no environment, the failure must
    -- name every place that was tried.
    let empty := Paths.under (tmp / "nonexistent")
    match ← IO.getEnv "AWS_ACCESS_KEY_ID" with
    | none =>
      match ← (loadFrom empty .aws).toBaseIO with
      | .ok _ => throw (IO.userError "expected no credentials to be found")
      | .error e =>
        let msg := toString e
        for expected in ["credentials", "keychain", "AWS_ACCESS_KEY_ID"] do
          unless mentions msg expected do
            throw (IO.userError s!"not-found message omits {expected}: {msg}")
      IO.println "credentials: ok (files, redaction, and a message naming all three sources)"
    | some envKey =>
      -- The environment is set, so instead of the not-found message this
      -- checks the third source itself: with no files and no keychain entry,
      -- the chain must fall through to it.
      let fromEnv ← loadFrom empty .aws
      unless fromEnv.accessKey == envKey do
        throw (IO.userError "chain did not fall through to the environment")
      IO.println "credentials: ok (files, redaction, and fall-through to the environment)"
  finally
    IO.FS.removeDirAll tmp

/-- Checks that the protocol clients produce correctly signed requests, without
    a network and without credentials.

    This is the load-bearing offline check of the provider layer: a signing bug
    is otherwise invisible until a live call returns `SignatureDoesNotMatch`
    with nothing to say why. The credentials are AWS's published documentation
    pair, and the expected signatures were derived independently rather than
    from this implementation. -/
def checkSigning : IO Unit := do
  let creds : Credentials :=
    { accessKey := "AKIDEXAMPLE"
      secretKey := "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
      region := "eu-west-1" }
  -- 2015-08-30T12:36:00Z, the timestamp AWS's own examples use.
  let signedAt : Data.Time.UTCTime := Data.Time.UTCTime.ofNanosSinceEpoch (1440938160 * 1000000000)
  let authOf (req : Network.HTTP.Client.Request) : String :=
    (req.headers.find? (fun h => h.1 == Data.CI.mk' "Authorization")).map (·.2) |>.getD ""

  -- S3: `PUT /my-bucket`, path signed as sent (no double encoding).
  let s3 ← Infra.Providers.Aws.signedRequestAt creds
    (Infra.Providers.Aws.S3.endpoint .aws "eu-west-1") signedAt "PUT" "/my-bucket"
  let expectedS3 := "AWS4-HMAC-SHA256 \
Credential=AKIDEXAMPLE/20150830/eu-west-1/s3/aws4_request, \
SignedHeaders=host;x-amz-content-sha256;x-amz-date, \
Signature=b1ba7bd1e79e9726d5be98201bf756baa5d2e2b505a3ff12e45bbaa0e7068520"
  unless authOf s3 == expectedS3 do
    throw (IO.userError s!"S3 signature mismatch:\n  got      {authOf s3}\n  expected {expectedS3}")
  -- Scaleway Object Storage addresses a project through the access key:
  -- signed as `<key>@<project>`, or the API key's own default project is used.
  let scw ← Infra.Providers.Aws.signedRequestAt creds
    { Infra.Providers.Aws.S3.endpoint .scaleway "fr-par" with project := some "proj-1" }
    signedAt "GET" "/"
  unless mentions (authOf scw) "Credential=AKIDEXAMPLE@proj-1/20150830/fr-par/s3/" do
    throw (IO.userError s!"a Scaleway S3 request was not signed for its project: {authOf scw}")

  -- Query protocol: `POST /` with a form body, IAM, always signed us-east-1.
  let form := Infra.Providers.Aws.Query.formBody
    [("Action", "ListUsers"), ("Version", "2010-05-08")]
  unless String.fromUTF8! form == "Action=ListUsers&Version=2010-05-08" do
    throw (IO.userError s!"form body: {String.fromUTF8! form}")
  let iam ← Infra.Providers.Aws.signedRequestAt creds Infra.Providers.Aws.Query.iamEndpoint signedAt
    "POST" "/" []
    [("Content-Type", "application/x-www-form-urlencoded; charset=utf-8")]
    form (doubleEncodePath := true)
  let expectedIam := "AWS4-HMAC-SHA256 \
Credential=AKIDEXAMPLE/20150830/us-east-1/iam/aws4_request, \
SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date, \
Signature=21cccf6f70b4372af8e137af9b15333d9485d91e393b87fc2b9e034f8ef7a77d"
  unless authOf iam == expectedIam do
    throw (IO.userError s!"IAM signature mismatch:\n  got      {authOf iam}\n  expected {expectedIam}")

  -- Endpoints: one S3 client, two clouds. This is what makes the portable
  -- `.objectStore` kind portable at all.
  unless (Infra.Providers.Aws.S3.endpoint .aws "eu-west-1").host == "s3.eu-west-1.amazonaws.com" do
    throw (IO.userError "unexpected AWS S3 host")
  unless (Infra.Providers.Aws.S3.endpoint .scaleway "fr-par").host == "s3.fr-par.scw.cloud" do
    throw (IO.userError "unexpected Scaleway S3 host")
  unless (Infra.Providers.Aws.S3.endpoint .scaleway "fr-par").service == "s3" do
    throw (IO.userError "Scaleway object storage must sign as the s3 service")

  -- Error bodies: the provider's own code and message must survive, in both
  -- dialects, because "403" alone is not a diagnosis.
  let xmlErr := Infra.Providers.Http.describeError 404
    "<?xml version=\"1.0\"?><Error><Code>NoSuchBucket</Code>\
<Message>The specified bucket does not exist</Message><RequestId>TX1</RequestId></Error>"
  unless xmlErr.code == "NoSuchBucket" && xmlErr.requestId == some "TX1" do
    throw (IO.userError s!"XML error not parsed: {xmlErr.code}")
  let jsonErr := Infra.Providers.Http.describeError 400
    "{\"message\":\"invalid argument\",\"type\":\"invalid_arguments\"}"
  unless jsonErr.message == "invalid argument" do
    throw (IO.userError s!"JSON error not parsed: {jsonErr.message}")
  -- An unparseable body keeps its text rather than vanishing.
  let rawErr := Infra.Providers.Http.describeError 502 "upstream exploded"
  unless rawErr.message == "upstream exploded" do
    throw (IO.userError s!"raw error body lost: {rawErr.message}")

  -- `Content-MD5` on S3 bucket-configuration writes. Checked against
  -- `openssl dgst -md5 -binary | base64` rather than against this
  -- implementation: a wrong integrity header is worse than a missing one,
  -- because S3 would reject the body as corrupt rather than as unsigned.
  unless Infra.Providers.Aws.S3.contentMd5 ByteArray.empty == "1B2M2Y8AsgTpgAmY7PhCfg==" do
    throw (IO.userError
      s!"Content-MD5 of empty: {Infra.Providers.Aws.S3.contentMd5 ByteArray.empty}")
  unless Infra.Providers.Aws.S3.contentMd5 "abc".toUTF8 == "kAFQmDzST7DWlj99KOF/cg==" do
    throw (IO.userError
      s!"Content-MD5 of \"abc\": {Infra.Providers.Aws.S3.contentMd5 "abc".toUTF8}")

  IO.println "signing: ok (S3 and Query vectors, Content-MD5, both error dialects)"

/- The principle this library rests on, checked end to end: **the marker
    decides what is managed.** A resource carrying this fleet's name that the
    declaration no longer names is found and destroyed; everything else is
    left alone. -/
fleet markerFleet in paris where
  provider scaleway where
    resource secrets "kept" { valueFrom := Infra.Specs.fromEnv "X" }
    resource scalewayContainerNamespace "ns" as markerNs { description := "d" }
    resource scalewayContainer "app" { namespace' := markerNs, image := "i", port := 8080 }

open Infra.Providers.Snapshot in
/-- The account `checkMarkerDecides` runs against, as data: what the fleet
    declares (`kept`, `app`, `ns`), what it no longer does (`old-*`), and what
    is not its own — another fleet's, the retired `true`, unmarked. The container
    is listed under both kinds that show Serverless Containers. -/
private def markerAccount : Snapshot :=
  [ marked .scaleway .secrets "kept" "tn"
  , marked .scaleway .secrets "old-secret" "tn"
  , { cloud := .scaleway, kind := .secrets, name := "legacy-secret"
      evidence := .tags [(markerKey, retiredMarkerValue)] none }
  , marked .scaleway .secrets "theirs" "another-fleet"
  , unmarked .scaleway .secrets "stranger"
  , marked .scaleway .compute "app" "tn", marked .scaleway .scalewayContainer "app" "tn"
  , marked .scaleway .compute "old-app" "tn", marked .scaleway .scalewayContainer "old-app" "tn"
  , marked .scaleway .scalewayContainerNamespace "ns" "tn"
  -- Queues are scanned like every other kind, though this fleet declares
  -- none: removing the last one must still destroy it.
  , marked .scaleway .queues "old-queue" "tn" ]

def checkMarkerDecides : IO Unit := do
  let boundary : Boundary := { fleetName := some "tn" }
  let deleted ← IO.mkRef []
  let bs := Infra.Providers.Snapshot.backends markerAccount deleted
  let found ← claimUndeclared (κ := markerFleet.keys) bs boundary []
  let slots := found.orphans.map (·.slot)
  -- Exactly the three undeclared resources carrying this fleet's name — the
  -- container once, though two kinds list it, and the queue although the
  -- fleet declares no queue at all.
  unless slots.length == 3 && slots.contains "scaleway/secrets/old-secret"
      && slots.contains "scaleway/queues/old-queue"
      && slots.any (fun sl => (sl.splitOn "/old-app").length > 1) do
    throw (IO.userError s!"expected old-secret, old-app and old-queue, got {slots}")
  -- `app` is declared as a `scalewayContainer`; its `compute` listing is the
  -- same container, not an orphan.
  if slots.any (fun sl => (sl.splitOn "/app").length > 1 && (sl.splitOn "old-app").length == 1) then
    throw (IO.userError s!"a declared container was claimed as an orphan via another kind: {slots}")
  -- The retired marker belongs to no fleet: warned about (it is likely ours, awaiting a retag), not claimed.
  unless found.warnings.length == 1 && (found.warnings.head!.splitOn "legacy-secret").length > 1 do
    throw (IO.userError s!"expected one warning, about legacy-secret: {found.warnings}")
  -- Applied: every orphan is deleted, and nothing that is not this fleet's is
  -- touched. (Declared resources may be replaced — the replay's placeholder
  -- report differs from their specs — and that is theirs to be.)
  let entries ← pullEntries (κ := markerFleet.keys) bs
  let _ ← push bs markerFleet.plan (worldOf entries) { apply := true } (orphans := found.orphans)
    (boundary := boundary) (seen := some entries)
  let gone ← deleted.get
  unless slots.all gone.contains do
    throw (IO.userError s!"not every orphan was deleted: deleted {gone}, orphans {slots}")
  if gone.any (fun g => ["theirs", "stranger", "legacy-secret", "kept"].any
      fun n => g == s!"scaleway/secrets/{n}") then
    throw (IO.userError s!"deleted a resource that is not an orphan of this fleet: {gone}")
  -- And a second pass over the account the first one left finds nothing.
  let again ← claimUndeclared (κ := markerFleet.keys) bs boundary []
  unless again.orphans.isEmpty do
    throw (IO.userError s!"orphans survived the apply: {again.orphans.map (·.slot)}")
  IO.println "marker: ok (what carries this fleet's name and is not declared is found and destroyed — every kind, queues included — and nothing else)"

fleet releaseFleet in paris where
  provider scaleway where
    resource secrets "kept" { valueFrom := Infra.Specs.fromEnv "X" }
    forget scaleway secrets "let-go"
    forget scaleway postgres "tn-db"
    forget scaleway secrets "already-free"

open Infra.Providers.Snapshot in
/-- `forget` releases: a forgotten resource still carrying this fleet's marker
    has the marker removed on apply — not destroyed — and then reads as no
    fleet's, so the `forget` line can go. A name-only resource cannot be
    unmarked and is left alone (its line stays). One already unmarked needs
    nothing. -/
def checkForgetReleases : IO Unit := do
  let account : Snapshot :=
    [ marked .scaleway .secrets "kept" "tn"
    , marked .scaleway .secrets "let-go" "tn"
    , { cloud := .scaleway, kind := .postgres, name := "tn-db", evidence := .named "tn-db" none }
    , unmarked .scaleway .secrets "already-free" ]
  let deleted ← IO.mkRef []
  let released ← IO.mkRef []
  let bs := Infra.Providers.Snapshot.backends account deleted (some released)
  let boundary : Boundary := { fleetName := some "tn" }
  let found ← claimUndeclared (κ := releaseFleet.keys) bs boundary releaseFleet.forgets
  unless found.orphans.isEmpty do
    throw (IO.userError s!"a forgotten resource was treated as an orphan: {found.orphans.map (·.slot)}")
  unless found.releases.map (·.slot) == ["scaleway/secrets/let-go"] do
    throw (IO.userError s!"expected exactly let-go to be released, got {found.releases.map (·.slot)}")
  let entries ← pullEntries (κ := releaseFleet.keys) bs
  let dry ← push bs releaseFleet.plan (worldOf entries) {} (boundary := boundary)
    (seen := some entries) (releases := found.releases)
  unless dry.any (mentions · "would RELEASE scaleway/secrets/let-go") do
    throw (IO.userError s!"the plan does not show the release: {dry}")
  let _ ← push bs releaseFleet.plan (worldOf entries) { apply := true } (boundary := boundary)
    (seen := some entries) (releases := found.releases)
  unless (← released.get) == ["scaleway/secrets/let-go"] && (← deleted.get).isEmpty do
    throw (IO.userError s!"released {← released.get}, deleted {← deleted.get}")
  -- Afterwards it is no fleet's: nothing left to release, and nothing claims it.
  let again ← claimUndeclared (κ := releaseFleet.keys) bs boundary releaseFleet.forgets
  unless again.releases.isEmpty && again.orphans.isEmpty do
    throw (IO.userError s!"after the release: releases {again.releases.map (·.slot)}, \
orphans {again.orphans.map (·.slot)}")
  IO.println "forget releases: ok (a marked forgotten resource is unmarked on apply, not destroyed; a name-only one is left, and its line stays)"

open Infra.Providers.Snapshot in
/-- **What infra may not read, it does not manage.** An undeclared resource
    whose marker read is refused (access denied, after its listing succeeded)
    is warned about by name and left alone, and the rest of the run goes on:
    the orphans around it are still found and destroyed. The limits hold too —
    reading the marker is required to handle a kind that carries one, so a
    kind whose every read is refused fails the run unless a declared resource
    of it is readable; a refused *listing*, and any failure that is not a
    refusal, still fail the run; a physical resource listed under two kinds is
    warned about once; and a forgotten one keeps its `forget` line, and does
    not count against the permission. -/
def checkRefusedIsNotManaged : IO Unit := do
  let boundary : Boundary := { fleetName := some "tn" }
  -- The case that forced it: a hand-managed bucket whose bucket policy does
  -- not name these credentials, next to this fleet's own orphan. On AWS the
  -- same bucket is listed under both kinds that show buckets. (`markerAccount`
  -- without its own orphans, so the one here is the only one.)
  -- Each refused bucket has a readable sibling of its kind: the refusal is
  -- then that bucket's own, not a missing permission.
  let account : Snapshot := markerAccount.filter (!·.name.startsWith "old-") ++
    [ refused .scaleway .objectStore "docs.example.org" "fr-par"
    , marked .scaleway .objectStore "tn-old-bucket" "tn" "fr-par"
    , refused .aws .objectStore "locked", refused .aws .s3Bucket "locked"
    , unmarked .aws .objectStore "readable", unmarked .aws .s3Bucket "readable" ]
  let deleted ← IO.mkRef []
  let bs := Infra.Providers.Snapshot.backends account deleted
  let found ← claimUndeclared (κ := markerFleet.keys) bs boundary []
  let slots := found.orphans.map (·.slot)
  unless slots.contains "scaleway/object-store/tn-old-bucket" do
    throw (IO.userError s!"an orphan next to a refused resource was not found: {slots}")
  if slots.any (fun s => mentions s "docs.example.org" || mentions s "locked") then
    throw (IO.userError s!"a resource whose marker could not be read was claimed: {slots}")
  let aboutDocs := found.warnings.filter (mentions · "docs.example.org")
  unless aboutDocs.length == 1 && aboutDocs.all (mentions · "refused to show its ownership marker") do
    throw (IO.userError s!"expected one refusal warning about docs.example.org: {found.warnings}")
  unless (found.warnings.filter (mentions · "locked")).length == 1 do
    throw (IO.userError s!"a bucket listed under two kinds was not warned about exactly once: \
{found.warnings}")
  -- Applied, the orphan goes and the refused resources stay.
  let entries ← pullEntries (κ := markerFleet.keys) bs
  let _ ← push bs markerFleet.plan (worldOf entries) { apply := true } (orphans := found.orphans)
    (boundary := boundary) (seen := some entries)
  let gone ← deleted.get
  unless gone.contains "scaleway/object-store/tn-old-bucket" do
    throw (IO.userError s!"the orphan was not deleted: {gone}")
  if gone.any (fun g => mentions g "docs.example.org" || mentions g "locked") then
    throw (IO.userError s!"deleted a resource whose marker could not be read: {gone}")
  -- Anything but a refusal still fails the run, and says which resource.
  let broken := Infra.Providers.Snapshot.backends
    [refused .scaleway .secrets "flaky" (message := "HTTP 500 InternalError: try again")] (← IO.mkRef [])
  match ← (claimUndeclared (κ := markerFleet.keys) broken boundary []).toBaseIO with
  | .ok _ => throw (IO.userError "a failed marker read that is not a refusal did not fail the run")
  | .error e =>
    unless mentions (toString e) "scaleway/secrets/flaky" && mentions (toString e) "InternalError" do
      throw (IO.userError s!"the failure does not name the resource and the cause: {e}")
  -- A refused *listing* still fails the run: it would hide a whole kind.
  let refusedList : Backends :=
    { backend := fun p =>
        { Infra.Providers.placeholderBackend p.name with
            list := fun k =>
              if p == .scaleway && k == .queues then
                throw (IO.userError "scaleway GET /mnq/v1beta1/regions/fr-par/sqs-info: \
HTTP 403 permissions_denied: insufficient permissions")
              else pure [] } }
  match ← (claimUndeclared (κ := markerFleet.keys) refusedList boundary []).toBaseIO with
  | .ok _ => throw (IO.userError "a refused listing did not fail the run")
  | .error e =>
    unless mentions (toString e) "listing scaleway queues" do
      throw (IO.userError s!"the refused listing does not say what was listed: {e}")
  -- Reading the marker is required to handle a kind that carries one: when
  -- every read of a kind is refused, that is a missing permission, not each
  -- resource's own policy, and the run fails naming the kind and the fix.
  let allRefused : Snapshot :=
    [ refused .aws .queues "q1", refused .aws .queues "q2" ]
  match ← (claimUndeclared (κ := markerFleet.keys)
      (Infra.Providers.Snapshot.backends allRefused (← IO.mkRef [])) boundary []).toBaseIO with
  | .ok d => throw (IO.userError s!"a kind whose every marker read is refused did not fail the run: \
warnings {d.warnings}")
  | .error e =>
    let said := toString e
    unless mentions said "every ownership-marker read of aws queues was refused"
        && mentions said "aws/queues/q1" && mentions said "aws/queues/q2" && mentions said "forget" do
      throw (IO.userError s!"the failure does not name the kind, the resources and the way out: {said}")
  -- A declared resource of the kind proves the permission when no undeclared
  -- one can: `kept` is declared and readable, so the refused secret is that
  -- secret's own business.
  let probed ← claimUndeclared (κ := markerFleet.keys)
    (Infra.Providers.Snapshot.backends
      [marked .scaleway .secrets "kept" "tn", refused .scaleway .secrets "locked-secret"] (← IO.mkRef []))
    boundary []
  unless probed.orphans.isEmpty && probed.warnings.any (mentions · "locked-secret") do
    throw (IO.userError s!"a readable declared resource did not settle the permission: \
orphans {probed.orphans.map (·.slot)}, warnings {probed.warnings}")
  -- …and a declared one that is refused too settles nothing.
  match ← (claimUndeclared (κ := markerFleet.keys)
      (Infra.Providers.Snapshot.backends
        [refused .scaleway .secrets "kept", refused .scaleway .secrets "locked-secret"] (← IO.mkRef []))
      boundary []).toBaseIO with
  | .ok _ => throw (IO.userError "a refused declared probe was taken as proof of the permission")
  | .error e =>
    unless mentions (toString e) "every ownership-marker read of scaleway secrets" do
      throw (IO.userError s!"unexpected failure: {e}")
  -- A forgotten resource that cannot be read is neither released nor claimed,
  -- and the warning says to keep its line. Its refusal does not count against
  -- the permission — `forget` is the way out for a kind whose only other
  -- resource is locked on purpose — so this passes although nothing of the
  -- kind was read.
  let forgot ← claimUndeclared (κ := releaseFleet.keys)
    (Infra.Providers.Snapshot.backends [refused .scaleway .secrets "let-go"] (← IO.mkRef []))
    boundary releaseFleet.forgets
  unless forgot.releases.isEmpty && forgot.orphans.isEmpty
      && forgot.warnings.any (fun w => mentions w "let-go" && mentions w "keep its `forget` line") do
    throw (IO.userError s!"a forgotten, unreadable resource: releases {forgot.releases.map (·.slot)}, \
orphans {forgot.orphans.map (·.slot)}, warnings {forgot.warnings}")
  IO.println "refused: ok (an undeclared resource whose marker is refused is left alone when another of its kind is readable; a kind with none readable, a refused listing, or any other failure fails the run)"

open Infra.Providers.Snapshot in
/-- A cloud the declaration no longer names is still scanned, when the
    backends can scan it (the CLI loads every cloud `Accounts` names): the
    `tn` fleet declares only Scaleway resources, and its bucket left on AWS
    is found and destroyed — another fleet's bucket there is not. -/
def checkRetiredCloud : IO Unit := do
  let account : Snapshot := markerAccount ++
    [ marked .aws .objectStore "tn-left-behind" "tn"
    , marked .aws .objectStore "not-ours" "someone-else" ]
  let found ← claimUndeclared (κ := markerFleet.keys)
    (Infra.Providers.Snapshot.backends account (← IO.mkRef [])) { fleetName := some "tn" } []
  let slots := found.orphans.map (·.slot)
  unless slots.any (mentions · "tn-left-behind") do
    throw (IO.userError s!"a marked resource on a cloud no longer declared was not found: {slots}")
  if slots.any (mentions · "not-ours") then
    throw (IO.userError s!"claimed another fleet's resource on the retired cloud: {slots}")
  IO.println "retired cloud: ok (what this fleet left on a cloud it no longer declares is found; nothing else there is)"

/-- Every fleet has a name, and it is checked before any cloud is asked: the
    `fleet` command's identifier in kebab-case by default, `fleetName` when
    set, and a name that cannot be a marker value on every cloud stops a live
    command with a message saying which of the two to fix. -/
def checkFleetName : IO Unit := do
  unless markerFleet.name == "marker-fleet" do
    throw (IO.userError s!"expected the identifier in kebab-case, got {markerFleet.name}")
  let refusal (boundary : Boundary) : IO String := do
    let (said, code) ← IO.FS.withIsolatedStreams
      (Infra.Cli.run "t" markerFleet (boundary := boundary) (args := ["plan"]))
    unless code == 1 do throw (IO.userError s!"an invalid fleet name was not refused: {said}")
    return said
  let said ← refusal { fleetName := some "Not_Valid" }
  unless mentions said "'Not_Valid' cannot be this fleet's name" && mentions said "fleetName" do
    throw (IO.userError s!"the refusal does not name the value and the fix: {said}")
  IO.println "fleet name: ok (the identifier in kebab-case by default; an invalid name is refused before any cloud is asked)"

/-- A `dump` is a snapshot, and a snapshot replays: dumping the account
    `checkMarkerDecides` uses, reading the file back and scanning the replay
    finds the same orphans. This is what makes a real account's dump usable as
    a test fixture. -/
def checkDumpReplays : IO Unit := do
  let boundary : Boundary := { fleetName := some "tn" }
  let bs := Infra.Providers.Snapshot.backends markerAccount (← IO.mkRef [])
  let found ← claimUndeclared (κ := markerFleet.keys) bs boundary []
  let entries ← pullEntries (κ := markerFleet.keys) bs
  let snap ← Infra.Cli.snapshotOf bs markerFleet.regions entries found.orphans
  let tmp ← IO.FS.createTempDir
  try
    let path := tmp / "dump.json"
    IO.FS.writeFile path (Infra.Cli.dumpJson snap found.orphans [] found.warnings).pretty
    let back ← Infra.Providers.Snapshot.load path
    unless back == snap do
      throw (IO.userError "a dump did not read back as the same snapshot")
    let replayed ← claimUndeclared (κ := markerFleet.keys)
      (Infra.Providers.Snapshot.backends back (← IO.mkRef [])) boundary []
    unless replayed.orphans == found.orphans do
      throw (IO.userError s!"the replayed dump found {replayed.orphans.map (·.slot)}, \
the account {found.orphans.map (·.slot)}")
  finally
    IO.FS.removeDirAll tmp
  IO.println "dump: ok (a dump reads back as the same snapshot, and replaying it finds the same orphans)"

/-- Checks `push`'s planning and ordering without touching a cloud.

    Uses the placeholder backends, but a dry run never calls them at all — it
    returns before any backend IO — so what this exercises is the decision and
    the schedule, which is exactly the part worth checking offline. -/
def checkPush : IO Unit := do
  let bs := Infra.Providers.all

  -- Nothing exists: every declared resource is a create, plus the notice.
  let dry ← push bs demoPlan emptyWorld {}
  let creates := dry.filter (·.startsWith "would CREATE")
  -- Eight: the demo fleet now declares the namespace its function sits in,
  -- because `scalewayFunction.namespace'` is a reference rather than a string.
  unless creates.length == 8 do
    throw (IO.userError s!"expected 8 creates, got {creates.length}: {dry}")
  unless dry.any (·.startsWith "(dry run") do
    throw (IO.userError "dry run did not say it was a dry run")

  -- Ordering: the Scaleway function references the AWS bucket, so the bucket
  -- must be created first. This is the dependency DAG doing its job, and it
  -- crosses clouds.
  match slotIdx dry "aws/s3-bucket/cold", slotIdx dry "scaleway/scaleway-function/ingest" with
  | some bucket, some fn =>
    unless bucket < fn do
      throw (IO.userError s!"bucket must be created before the function that reads it: {dry}")
  | _, _ => throw (IO.userError s!"expected both slots in the plan: {dry}")

  -- A resource that already matches drops out entirely.
  let partial' ← push ownedBackends demoPlan partialWorld {} (boundary := demo)
  unless (partial'.filter (·.startsWith "would")).length == 7 do
    throw (IO.userError s!"expected 7 actions against partialWorld: {partial'}")

  -- An immutable field that disagrees is a replace, not an update.
  let immutable ← push ownedBackends demoPlan immutableDriftWorld {} (boundary := demo)
  unless immutable.any (mentions · "REPLACE aws/s3-bucket/cold") do
    throw (IO.userError s!"expected a replace for the object-lock change: {immutable}")
  -- …but only of a resource this fleet can show is its own. The placeholder
  -- cannot read a marker, so the same drift proposes nothing: a declared name
  -- is not evidence of ownership (0.15.0; before, this replaced it anyway).
  let unverified ← push bs demoPlan immutableDriftWorld {}
  if unverified.any (mentions · "REPLACE aws/s3-bucket/cold") then
    throw (IO.userError s!"replaced a resource whose ownership it could not verify: {unverified}")

  -- An idle plan asks for nothing at all.
  let idle ← push bs idlePlan emptyWorld {}
  unless idle == ["nothing to do"] do
    throw (IO.userError s!"idle plan should be a no-op: {idle}")

  IO.println "push: ok (dry run, cross-cloud ordering, no-op, replace — and no replace of what is not ours)"

/-- Checks a composed secret: one apply, right order, and no leakage.

    The placeholder backends' `secretValue` returns a canary string, so
    "a secret value does not escape" is *tested* rather than asserted — if any
    of the plan output, the apply log, or the on-disk cache ever contained a
    real value, it would contain this one. -/
def checkSecretComposition : IO Unit := do
  let bs := Infra.Providers.all
  let canary := "placeholder-secret-value"

  -- The whole fleet in one apply: three creates, no manual step in between.
  let dry ← push bs composedPlan composedEmptyWorld {}
  let creates := dry.filter (·.startsWith "would CREATE")
  unless creates.length == 3 do
    throw (IO.userError s!"expected 3 creates in one apply, got {creates.length}: {dry}")

  -- Ordering: the composed secret reads the password *and* the database, so
  -- both must be created before it. This is `HasDeps` seeing through `map`/`ap`.
  let idx (needle : String) : Option Nat := dry.findIdx? (fun l => mentions l needle)
  match idx "secrets/db-password", idx "postgres/main", idx "secrets/db-url" with
  | some pw, some db, some url =>
    unless pw < url && db < url do
      throw (IO.userError s!"composed secret must be created last: {dry}")
  | _, _, _ => throw (IO.userError s!"expected all three slots in the plan: {dry}")

  -- A dry run must not read a secret at all, let alone print one.
  for line in dry do
    if mentions line canary then
      throw (IO.userError s!"dry run leaked a secret value: {line}")

  -- Applying really does resolve the value — and still must not log it.
  let applied ← push bs composedPlan composedEmptyWorld { apply := true }
  for line in applied do
    if mentions line canary then
      throw (IO.userError s!"apply log leaked a secret value: {line}")

  -- Nor may it reach a `dump`, the one thing written to disk.
  let entries ← pullEntries (κ := composedKeys) bs
  let snap ← Infra.Cli.snapshotOf bs {} entries []
  if mentions (Infra.Cli.dumpJson snap [] [] []).pretty canary then
    throw (IO.userError "dump leaked a secret value")

  -- Create-only: a composed value cannot be compared, so once the resources
  -- exist a second apply must ask for nothing. Without this, every plan would
  -- show a perpetual UPDATE and churn a new secret version on every run.
  let again ← push bs composedPlan composedAppliedWorld {}
  unless again == ["nothing to do"] do
    throw (IO.userError s!"second apply should be a no-op, got: {again}")

  IO.println "composed secrets: ok (one apply, ordered, no leak, converges)"

/-- The minted-key fleet: one apply, right order, create-only, and the URL it
    settles to is the one Scaleway will accept.

    `Infra.Demo`'s `#guard`s already pin the composition and the implied edge.
    What they cannot reach is the engine: this runs the plan through `push`,
    which is where the ordering, the create-only property and the redaction of
    a settled value actually happen. -/
def checkMintedKey : IO Unit := do
  let bs := Infra.Providers.all
  let canary := "placeholder-secret-value"

  let dry ← push bs identityPlan identityEmptyWorld {}
  let creates := dry.filter (·.startsWith "would CREATE")
  unless creates.length == 4 do
    throw (IO.userError s!"expected 4 creates in one apply, got {creates.length}: {dry}")

  -- The identity before the key that belongs to it. This is the edge
  -- `Engine.impliedByName` supplies out of `apiKeyFor`'s name, seen through
  -- the scheduler rather than in isolation.
  let idx (needle : String) : Option Nat := dry.findIdx? (fun l => mentions l needle)
  match idx "iam/reports-app", idx "secrets/app-key", idx "secrets/app-db-url",
        idx "postgres/reports" with
  | some app, some key, some url, some db =>
    unless app < key do
      throw (IO.userError s!"the application must be created before its key: {dry}")
    unless key < url && db < url do
      throw (IO.userError s!"the composed URL must be created last: {dry}")
  | _, _, _, _ => throw (IO.userError s!"expected all four slots in the plan: {dry}")

  -- Teardown is the transpose, and this is the half that matters on AWS: an
  -- IAM user holding an access key cannot be deleted, so the secret that owns
  -- the key has to go first.
  -- Against a backend that reports the marker: a teardown deletes only what
  -- is verifiably this fleet's, and a placeholder cannot say.
  let down ← push ownedBackends (Plan.absent identityKeys) identityAppliedWorld
    { apply := true } (edges := identityPlan) (boundary := demo)
  match down.findIdx? (fun l => mentions l "secrets/app-key"),
        down.findIdx? (fun l => mentions l "iam/reports-app") with
  | some key, some app =>
    unless key < app do
      throw (IO.userError s!"the key's secret must be deleted before its identity: {down}")
  | _, _ => throw (IO.userError s!"expected both slots in the teardown: {down}")

  -- A minted key is a secret like any other: it must not reach a log.
  let applied ← push bs identityPlan identityEmptyWorld { apply := true }
  for line in dry ++ applied do
    if mentions line canary then
      throw (IO.userError s!"the minted-key fleet leaked a secret value: {line}")

  -- Create-only. Re-minting on a second apply would leave the previous key
  -- live and unreferenced, which is the leak `apiKeyFor` is careful about.
  let again ← push bs identityPlan identityAppliedWorld {}
  unless again == ["nothing to do"] do
    throw (IO.userError s!"second apply should be a no-op, got: {again}")

  IO.println "minted keys: ok (identity first, key before URL, teardown reversed, converges)"

/-- Checks the empty declaration: what `destroy` reconciles against.

    Two claims worth pinning. First, `Plan.absent` deletes what exists and
    nothing else — `actions` maps `.absent` against an unseen resource to no
    action, so tearing down a fleet that was never applied is a no-op rather
    than a pile of doomed deletes. Second, deletions run in the *reverse* of
    creation order, which is what `orderActions` does by reversing them: a
    resource must go before whatever it depends on is taken away. -/
def checkTeardown : IO Unit := do
  let bs := Infra.Providers.all

  -- Nothing observed: the empty declaration asks for nothing.
  let onNothing ← push bs (Plan.absent demoKeys) emptyWorld {}
  unless onNothing == ["nothing to do"] do
    throw (IO.userError s!"tearing down an unapplied fleet should be a no-op: {onNothing}")

  -- Against a world where the referenced bucket exists, the delete appears…
  let dry ← push ownedBackends (Plan.absent demoKeys) partialWorld {} (boundary := demo)
  unless (dry.filter (·.startsWith "would DELETE")).length == 1 do
    throw (IO.userError s!"expected one delete against partialWorld: {dry}")
  -- …and does not, for a resource that is not verifiably ours: `destroy`
  -- deletes what carries the marker, not whatever holds a declared name.
  let refused ← push bs (Plan.absent demoKeys) partialWorld {}
  unless refused == ["nothing to do"] do
    throw (IO.userError s!"destroy reached a resource it could not verify: {refused}")

  -- Ordering, on the fleet that has a real cross-cloud edge: the Scaleway
  -- function reads the AWS bucket, so on the way down the function goes first.
  let both : World demoKeys := worldOf
    [ ⟨.aws, .s3Bucket, .cold,
        { observed := { handle := ⟨"cold"⟩, arn := "arn:x", region := "eu-west-1" }
          reported := { name := "cold", versioning := .unknown
                        objectLock := .unknown } }⟩
    , ⟨.scaleway, .scalewayFunction, .api,
        { observed := { handle := ⟨"ingest"⟩, url := "https://x.invalid" }
          reported := { name := "ingest", runtime := "python3.12"
                        namespace' := ⟨"demo"⟩, code := .unknown
                        handler := .unknown, sourceBucket := .unknown } }⟩ ]
  let ordered ← push ownedBackends (Plan.absent demoKeys) both {} (boundary := demo)
  match slotIdx ordered "scaleway/scaleway-function/ingest",
        slotIdx ordered "aws/s3-bucket/cold" with
  | some fn, some bucket =>
    unless fn < bucket do
      throw (IO.userError s!"on teardown the function must go before its bucket: {ordered}")
  | _, _ => throw (IO.userError s!"expected both deletes: {ordered}")

  IO.println "teardown: ok (no-op when absent, reverse order when present, only what is ours)"

/-- A resource that vanishes between `list` and `read` is absent, not fatal.

    This is the shape the first successful live AWS run failed on: `destroy`
    deleted the queue, the post-delete `pull` still saw it in SQS's
    eventually-consistent listing, and reading it then raised
    `QueueDoesNotExist` — aborting a pull whose only honest answer was "it is
    gone". The same happens whenever anything is deleted out of band while a
    refresh is running.

    The backend here lists one bucket and refuses to read it, each way round:
    once with a not-found error, which must be absorbed, and once with a
    permission error, which must not — mistaking that for absence would have
    the engine propose creating something that already exists. -/
def checkVanishingResource : IO Unit := do
  let listsOneRefusingToRead (err : String) : Backend :=
    { Infra.Providers.placeholderBackend "test" with
      -- Lists one bucket, then refuses to read it. Both halves matter: the
      -- listing is what makes the engine try the read at all.
      list := fun k => match k with
        | .objectStore => pure [{ handle := ⟨"assets"⟩, url := "https://x.invalid" }]
        | _            => pure []
      read := fun _ _ => throw (IO.userError err) }
  let backendsWith (err : String) : Backends :=
    { backend := fun _ => listsOneRefusingToRead err }

  -- Not found: the pull completes and reports nothing there.
  let gone ← pull (κ := demoKeys)
    (backendsWith "HTTP 400 com.amazonaws.sqs#QueueDoesNotExist: The specified queue does not exist.")
  match gone.sighting .aws .objectStore .assets with
  | none   => pure ()
  | some _ => throw (IO.userError "a vanished resource was reported as present")

  -- Denied: the pull must fail rather than silently report absence, because
  -- "absent" would make the next apply create a duplicate.
  match ← (pull (κ := demoKeys)
            (backendsWith "HTTP 403 AccessDenied: not authorised")).toBaseIO with
  | .error _ => pure ()
  | .ok _    => throw (IO.userError "a permission error was mistaken for absence")

  IO.println "pull: ok (a vanished resource is absent; a denied one still fails)"

/-- A GCP service-account assertion is built, signed, and verifies.

    The crypto itself is `linen`'s and is tested there; what this checks is
    *this* library's part — that the claims document, the header and the
    base64url assembly produce something whose signature validates. A JWT
    Google would reject is useless however good the signing primitive is.

    The key is a throwaway generated for this check. It signs nothing else and
    guards nothing; it is test data, like a fixed seed. -/
def checkGcpAssertion : IO Unit := do
  let keyFile := "{\"type\":\"service_account\",\"project_id\":\"p\",\
\"client_email\":\"ci@p.iam.gserviceaccount.com\",\"private_key\":\"-----BEGIN PRIVATE KEY-----\\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDpcDBZHjvbtp68\\nZJmXXFGQzgYVgOUZXMVs/mFiyelPoBrY2ZuQ+McU8m0xXzzGvEbe/isgChZ3g8+l\\nJsL900iwLetXfnhdqFU7j+WPpB1Jx/tfqG3qOFPR0tCPndwKFtVyn1nJjHmZYT5N\\n7RBSrVIfWhwa7y5tkpF19Rbrta0KH4d2+rXmYwFMT5Ft6wUpe6WifTdThfWNd47/\\nc6kdqkWZtzTE9q7RkWCNrqk1C+W5lU3HdaxYEGmGk5tSWWiM3ZjqO3IYPXylc/Yi\\nOZE2zCu6b59geQIuyp14kzDmHHp/qqNP0ykdKbyZTJgZr74Ug8mLDekupAl4Knd5\\nejWze0aXAgMBAAECggEABfU6ZqviNI4JUx7w2e9zQtI0pDaGol+/HN8JNppB/X7v\\n8HpCrC/in42TF+ApuZtzO5xvwVZAkzWmsRJiMP7u1gBLXLpPnCRVuJAdoyLkfyOU\\nLjGATKq6CPBBKR6K+n7xXQblexgTam9pmwI37m7vWk7UdM4x+H311HWNljUsK3FC\\nExQwifiT1eRcFLtGOYm5iNpJtLIbKZYguhb5rDoHYoqBflt5T9/R1cGMfcAR5V7J\\n6uF8hwcc1vvv/knNHbkbA9qOAz+imFFr6LDzFltOU4rrqg9/4BMciQRQUg+FBWS0\\nXUi8Z6X+UfQwyMkgsF6NQ+2F9Ii6M0haGh0WXgShkQKBgQD/IjVOr1j3enLrYKCi\\niVEy7L1aPxK9be4qx+W0n86e6jfaFNUx1u7eL+zKvNdWUWA4JPSr8LGYREcbJVns\\nYzO6VLfuiOjIcUvz45DQKcADoc0HT1KE235QMr9+HlLMtDka46Alo2Y4zYfmX0jY\\nR56CiHSMG1iSejwRMuYcq+fbAwKBgQDqOx7XoWP1cYNfydf2WMArgTrUW8y5PdjT\\ntJcSgmSjb3ALRsl8Dvhc/DTSb1g5Rm6JL7TSnUx4yCYWvdBVxOxiQ3F5fR705k2F\\npUZTkvTJ5GhaSgIs/SIryVG1RiD0kVOspV+MI/7M9iLB52ltRlQkCqQYS+ulUC/l\\nio3m92dn3QKBgQCMNZB2HYcW+gQNtpyQtkYZZmDpJ6B02eT5PcHO8cPrMWxgPPKs\\n4SGEmXHYOM9ecHogYK7VjwEKXPt2v6AbeKkEzWoHfNXw0dKbxYPf4hHT7SdvzPfc\\na4OPL1RtStzWAnUfgdiQ1qtmrAzzXYn60eEae0MRfDXAycwY54/uUcqpYQKBgCcK\\n670tnafP4AIbdvANIxsdU10KYDmQYZAIThY7veKwNJDsn7EaHbQCJhvdi2sgnlQn\\nq5Bfv9tyIUcxJITnai+G5mdFv986dDmOrwZHPJ5agDpsk6hEGWoLCJ+arOuXPcdN\\nWXvWlCY98NU5aY1ZZ7UKQQf7v6+yiglM6xJQst/RAoGAIWEVDnRDRTMupQ6yyPei\\nqwtb2/Ew+5iwjMLHAhUdRrDJbl/kmI6DC2yLkFA5YjHoqx+9kOXzZzmLae9V384y\\npPJ+UAHBFApKyTS/x/dRWY6fVvnGrk3SXgyOizCg+rOlBxTYacPMXiJlEuIGANBH\\ntgNxv+cGCEjoVJaNhTyrGYs=\\n-----END PRIVATE KEY-----\"}"
  let sa ← match Infra.Core.GcpAuth.parse keyFile with
    | .ok sa   => pure sa
    | .error e => throw (IO.userError s!"gcp key parse: {e}")
  -- Nothing may render the private key, whatever is done with it.
  if ((toString sa).splitOn "PRIVATE KEY").length > 1 then
    throw (IO.userError "gcp: the service-account key leaked into its own Repr")
  let jwt ← Infra.Core.GcpAuth.assertion sa Infra.Core.GcpAuth.defaultScope
  match jwt.splitOn "." with
  | [h, p, sig] =>
    let n ← Crypto.JOSE.FFI.base64urlDecode "6XAwWR4727aevGSZl1xRkM4GFYDlGVzFbP5hYsnpT6Aa2NmbkPjHFPJtMV88xrxG3v4rIAoWd4PPpSbC_dNIsC3rV354XahVO4_lj6QdScf7X6ht6jhT0dLQj53cChbVcp9ZyYx5mWE-Te0QUq1SH1ocGu8ubZKRdfUW67WtCh-Hdvq15mMBTE-RbesFKXulon03U4X1jXeO_3OpHapFmbc0xPau0ZFgja6pNQvluZVNx3WsWBBphpObUllojN2Y6jtyGD18pXP2IjmRNswrum-fYHkCLsqdeJMw5hx6f6qjT9MpHSm8mUyYGa--FIPJiw3pLqQJeCp3eXo1s3tGlw"
    let e ← Crypto.JOSE.FFI.base64urlDecode "AQAB"
    let jwk : Crypto.JOSE.JWK :=
      { kty := .RSA, material := .rsa n e none
        kty_material_coherent := by
          refine ⟨fun _ => ⟨n, e, none, rfl⟩, fun hh => ?_, fun hh => ?_⟩ <;> cases hh }
    let sigBytes ← Crypto.JOSE.FFI.base64urlDecode sig
    let ok ← Crypto.JOSE.JWS.verifySignature .RS256 jwk (h ++ "." ++ p).toUTF8 sigBytes
    unless ok do throw (IO.userError "gcp: the assertion's own signature does not verify")
    IO.println "gcp auth: ok (service-account assertion signs and verifies)"
  | _ => throw (IO.userError s!"gcp: assertion is not a three-part JWT")

/-- Secrets Manager's idempotency token, whose shape is checkable offline.

    Worth a check because the bug it fixes was not: `CreateSecret` rejects a
    request with no `ClientRequestToken`, the API reference calls the field
    optional — it is, through an SDK, which fills it in — and nothing offline
    distinguishes a field an SDK supplies from one the service defaults. It
    took the first live AWS secret to find. What *can* be established here is
    that the token this now sends is well-formed and fresh. -/
def checkSecretsRequestToken : IO Unit := do
  let mut seen : List String := []
  for _ in [0:200] do
    let t ← Infra.Providers.Kinds.Secrets.Asm.requestTokenForCheck
    unless t.length == 32 do
      throw (IO.userError s!"secrets token: length {t.length}, expected 32 — {t}")
    unless t.all (fun c => c.isDigit || (c ≥ 'a' && c ≤ 'f')) do
      throw (IO.userError s!"secrets token: not lowercase hex — {t}")
    -- Fresh per call: the token is an idempotency key, so a repeat with
    -- different contents is itself an error.
    if seen.contains t then
      throw (IO.userError s!"secrets token: repeated within 200 calls — {t}")
    seen := t :: seen
  IO.println "secrets: request tokens are 32 hex characters and never repeat"

/-- The Scaleway SQS credential memo short-circuits.

    `credentialsFor` is reached a few hundred times in one live run — five call
    sites, once per listing, inside a poll loop. On a machine with a keychain
    that costs one mint; without one, every call missed, and once `reclaim`
    made a duplicate-name mint succeed instead of failing, each miss deleted
    the previous credential and minted another. A run churned two dozen.

    The memo bounds it to one per process. This checks the mechanism, which is
    all that is checkable without a keychain-less machine and a real account. -/
def checkSqsCredentialMemo : IO Unit := do
  unless ← Infra.Providers.Scaleway.Sqs.memoRoundTripsForCheck do
    throw (IO.userError
      "scaleway sqs: the credential memo did not retain a stored credential, so \
a live run would mint one per call")
  IO.println "scaleway sqs: the credential memo short-circuits (one mint per run)"

/-- Self-checks, run when no subcommand is given. Everything here works
    offline; nothing touches a cloud. -/

def selfCheck : IO Unit := do
  IO.println "infra: refinement core loaded"
  checkOwnershipGate
  checkFleetIsolation
  checkOrphanRecheck
  checkOrphanRetry
  checkLatestImage
  checkUnsetLaunchField
  checkPullAndPlan
  checkCredentials
  checkSigning
  checkMarkerDecides
  checkDumpReplays
  checkFleetName
  checkRetiredCloud
  checkForgetReleases
  checkRefusedIsNotManaged
  checkPush
  checkTeardown
  checkSecretComposition
  checkMintedKey
  checkGcpAssertion
  checkVanishingResource
  checkSecretsRequestToken
  checkSqsCredentialMemo

/-- `infra gcp-check <key.json>` — does this service-account key actually work?

    Parses the file, signs an assertion with it, and exchanges that with
    Google for an access token. Reports whether each step worked and **never
    prints the token or the key**: the point is a yes/no, and a diagnostic that
    leaks the thing it is diagnosing is worse than no diagnostic.

    Worth having as a command rather than only as a library path, because the
    failure modes are all indistinguishable from the outside — a wrong file
    type, a disabled key, a service account with no roles, and a clock skewed
    past the assertion's window all surface as one opaque 4xx from the token
    endpoint. -/
def gcpCheck (path : String) : IO UInt32 := do
  let contents ← try IO.FS.readFile path
    catch _ => IO.eprintln s!"error: cannot read {path}"; return 1
  match Infra.Core.GcpAuth.parse contents with
  | .error e => IO.eprintln s!"error: {path}: {e}"; return 1
  | .ok sa =>
    IO.println s!"key file:   ok — {sa.clientEmail}"
    IO.println s!"project:    {sa.projectId.getD "(none in the key)"}"
    let jwt ← try Infra.Core.GcpAuth.assertion sa Infra.Core.GcpAuth.defaultScope
      catch e => IO.eprintln s!"error: could not sign the assertion: {e}"; return 1
    IO.println s!"assertion:  ok — signed RS256, {jwt.length} chars"
    match ← (Infra.Core.GcpAuth.exchange sa jwt).toBaseIO with
    | .error e =>
      IO.eprintln s!"error: the token exchange failed: {e}"
      IO.eprintln "  Common causes: the key is disabled or deleted; the IAM API is\n\
  not enabled on the project; this machine's clock is off by more than the\n\
  assertion's window."
      return 1
    | .ok token =>
      -- Length only. The token is a bearer credential for the whole project.
      IO.println s!"token:      ok — {token.length} chars, not printed"
      IO.println "\nThis key can authenticate. Point GOOGLE_APPLICATION_CREDENTIALS at it."
      return 0

/-- `infra` is two things: the demo fleet's own front end, and the scaffolder.

    The dispatch itself lives in `Infra.Cli`, which is also what a declaration
    repo calls — so this binary exercises the same front end consumers get,
    rather than a parallel copy of it.

    `new` is the exception, handled here, because it is not a fleet command: it
    reads no plan, touches no cloud and needs no credentials. It creates a
    repository. -/
def main (args : List String) : IO UInt32 :=
  match args with
  | ["new"] =>
    IO.eprintln "usage: lake exe infra new <directory>" *>
    IO.eprintln "       lake exe infra init [directory]   # set up a directory that exists" *>
    pure 2
  | ["new", dir] => Infra.Cli.New.scaffold dir
  -- `init` is to `new` what Lake's own pair is to each other: same output,
  -- one makes the directory and one works in the directory you are in.
  -- Defaults to `.`, which is the only argument anyone passes it.
  | ["init"] => Infra.Cli.New.scaffold "." (inPlace := true)
  | ["init", dir] => Infra.Cli.New.scaffold dir (inPlace := true)
  | ["gcp-check"] =>
    IO.eprintln "usage: lake exe infra gcp-check <service-account-key.json>" *> pure 2
  | ["gcp-check", path] => gcpCheck path
  -- `demoFleet` is hand-written rather than declared by the `fleet` command;
  -- it bundles `demoPlan` with an empty release list. See `Infra.Demo`.
  | _ => Infra.Cli.run "infra" demoFleet (selfCheck := selfCheck) (args := args)
