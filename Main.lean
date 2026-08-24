import Infra

open Infra.Core
open Infra.Demo

/-- Round-trips observed state through the on-disk cache in a scratch directory, to check the
    format is readable back and not merely writable. Exercises `Partial`'s JSON encoding
    indirectly: what is cached is `ObservedOf`, which is never partial, but the path, key
    naming and per-`(provider, kind)` layout are all new. -/
def checkPersistenceRoundTrip : IO Unit := do
  let tmp ← IO.FS.createTempDir
  try
    -- The cache stores the observed half only, so this uses `CachedEntry`.
    let saved : List (CachedEntry demoKeys) :=
      [⟨.aws, .objectStore, .assets, { handle := ⟨"assets"⟩, url := "https://x.invalid" }⟩,
       ⟨.scaleway, .compute, .api, { handle := ⟨"api"⟩, status := "ready" }⟩]
    Persistence.save tmp saved
    let loaded ← Persistence.load (κ := demoKeys) tmp
    if loaded.length = saved.length then
      IO.println s!"persistence round-trip: ok ({loaded.length} entries)"
    else
      throw (IO.userError s!"round-trip lost entries: saved {saved.length}, loaded {loaded.length}")
  finally
    IO.FS.removeDirAll tmp

/-- Pulls from both placeholder backends, caches the result, and reports what the target would
    still ask for. Nothing behind `list` is live yet, so the world comes back empty and every
    declared resource needs creating. -/
def checkPullAndPlan : IO Unit := do
  let tmp ← IO.FS.createTempDir
  try
    let world ← pull (κ := demoKeys) tmp Infra.Providers.all
    let work := plan demoPlan world
    IO.println s!"pull: world observed, {work.length} actions outstanding"
    IO.println s!"idle plan (all unmanaged): {(plan idlePlan world).length} actions"
  finally
    IO.FS.removeDirAll tmp

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
       default_region: fr-par\n"
    let scw ← loadFrom paths .scaleway
    unless scw.accessKey == "SCWXXXXXXXXXXXXXXXXX" && scw.region == "fr-par" do
      throw (IO.userError "scaleway credentials not read from config.yaml")

    -- Secrets must not survive rendering: this is what stops a stray trace or
    -- an error message from leaking one.
    let mentions (haystack needle : String) : Bool := (haystack.splitOn needle).length > 1
    let shown := toString aws
    if mentions shown "wJalrXUtnFEMI" then
      throw (IO.userError "Credentials rendering leaked the secret key")
    unless mentions shown "<redacted>" do
      throw (IO.userError "Credentials rendering did not redact")

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

  IO.println "signing: ok (S3 and Query vectors, shared endpoints, both error dialects)"

/-- Checks `push`'s planning and ordering without touching a cloud.

    Uses the placeholder backends, but a dry run never calls them at all — it
    returns before any backend IO — so what this exercises is the decision and
    the schedule, which is exactly the part worth checking offline. -/
def checkPush : IO Unit := do
  let bs := Infra.Providers.all

  -- Nothing exists: every declared resource is a create, plus the notice.
  let dry ← push bs demoPlan emptyWorld {}
  let creates := dry.filter (·.startsWith "would CREATE")
  unless creates.length == 7 do
    throw (IO.userError s!"expected 7 creates, got {creates.length}: {dry}")
  unless dry.any (·.startsWith "(dry run") do
    throw (IO.userError "dry run did not say it was a dry run")

  -- Ordering: the Scaleway function references the AWS bucket, so the bucket
  -- must be created first. This is the dependency DAG doing its job, and it
  -- crosses clouds.
  let idx (needle : String) : Option Nat :=
    (dry.findIdx? (fun l => (l.splitOn needle).length > 1))
  match idx "aws/s3-bucket/cold", idx "scaleway/scaleway-function/ingest" with
  | some bucket, some fn =>
    unless bucket < fn do
      throw (IO.userError s!"bucket must be created before the function that reads it: {dry}")
  | _, _ => throw (IO.userError s!"expected both slots in the plan: {dry}")

  -- A resource that already matches drops out entirely.
  let partial' ← push bs demoPlan partialWorld {}
  unless (partial'.filter (·.startsWith "would")).length == 6 do
    throw (IO.userError s!"expected 6 actions against partialWorld: {partial'}")

  -- An immutable field that disagrees is a replace, not an update.
  let immutable ← push bs demoPlan immutableDriftWorld {}
  unless immutable.any (fun l => (l.splitOn "REPLACE aws/s3-bucket/cold").length > 1) do
    throw (IO.userError s!"expected a replace for the object-lock change: {immutable}")

  -- An idle plan asks for nothing at all.
  let idle ← push bs idlePlan emptyWorld {}
  unless idle == ["nothing to do"] do
    throw (IO.userError s!"idle plan should be a no-op: {idle}")

  IO.println "push: ok (dry run, cross-cloud ordering, no-op and replace)"

/-- Where the observed-state cache lives. Gitignored: see `docs/persistence.md`. -/
def cacheRoot : System.FilePath := ".infra"

/-- Self-checks, run when no subcommand is given. Everything here works
    offline; nothing touches a cloud. -/
def selfCheck : IO Unit := do
  IO.println "infra: refinement core loaded"
  checkPersistenceRoundTrip
  checkPullAndPlan
  checkCredentials
  checkSigning
  checkPush

def usage : String := String.intercalate "\n"
  [ "usage: infra [check | plan | pull | push [--apply]]"
  , ""
  , "  check           run the offline self-checks (default)"
  , "  pull            observe both clouds and cache what is there"
  , "  plan            show what would change, without changing anything"
  , "  push            same as plan — a dry run"
  , "  push --apply    actually reconcile"
  ]

/-- Live commands need credentials for both clouds; the failure names every
    place that was searched. -/
def withLive (act : Infra.Core.Backends → IO Unit) : IO Unit := do
  act (← Infra.Providers.liveFromEnvironment)

def main (args : List String) : IO UInt32 := do
  match args with
  | [] | ["check"] => selfCheck; return 0
  | ["pull"] =>
    withLive fun bs => do
      let world ← pull (κ := demoKeys) cacheRoot bs
      let outstanding := plan demoPlan world
      IO.println s!"pulled; {outstanding.length} action(s) outstanding"
    return 0
  | ["plan"] | ["push"] =>
    withLive fun bs => do
      let world ← pull (κ := demoKeys) cacheRoot bs
      for line in ← push bs demoPlan world {} do IO.println line
    return 0
  | ["push", "--apply"] =>
    withLive fun bs => do
      let world ← pull (κ := demoKeys) cacheRoot bs
      for line in ← push bs demoPlan world { apply := true } do IO.println line
    return 0
  | _ =>
    IO.eprintln usage
    return 2
