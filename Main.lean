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

    -- Saving *nothing* must empty the cache, not leave the previous contents
    -- lying there. It used to: `save` skipped every `(provider, kind)` with no
    -- rows, so an emptied pair kept its old file — and after a `destroy` the
    -- cache went on listing resources that had just been deleted, forever,
    -- because nothing ever wrote that path again.
    Persistence.save (κ := demoKeys) tmp []
    let afterEmpty ← Persistence.load (κ := demoKeys) tmp
    unless afterEmpty.isEmpty do
      throw (IO.userError
        s!"a destroyed fleet left {afterEmpty.length} entry(ies) in the cache")
    IO.println "persistence: an emptied fleet empties its cache"
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
  let partial' ← push bs demoPlan partialWorld {}
  unless (partial'.filter (·.startsWith "would")).length == 7 do
    throw (IO.userError s!"expected 7 actions against partialWorld: {partial'}")

  -- An immutable field that disagrees is a replace, not an update.
  let immutable ← push bs demoPlan immutableDriftWorld {}
  unless immutable.any (mentions · "REPLACE aws/s3-bucket/cold") do
    throw (IO.userError s!"expected a replace for the object-lock change: {immutable}")

  -- An idle plan asks for nothing at all.
  let idle ← push bs idlePlan emptyWorld {}
  unless idle == ["nothing to do"] do
    throw (IO.userError s!"idle plan should be a no-op: {idle}")

  IO.println "push: ok (dry run, cross-cloud ordering, no-op and replace)"

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

  -- Nor may it reach the on-disk cache.
  let tmp ← IO.FS.createTempDir
  try
    let _ ← pull (κ := composedKeys) tmp bs
    for entry in ← tmp.walkDir do
      if mentions (← IO.FS.readFile entry) canary then
        throw (IO.userError s!"cache leaked a secret value: {entry}")
  finally
    IO.FS.removeDirAll tmp

  -- Create-only: a composed value cannot be compared, so once the resources
  -- exist a second apply must ask for nothing. Without this, every plan would
  -- show a perpetual UPDATE and churn a new secret version on every run.
  let again ← push bs composedPlan composedAppliedWorld {}
  unless again == ["nothing to do"] do
    throw (IO.userError s!"second apply should be a no-op, got: {again}")

  IO.println "composed secrets: ok (one apply, ordered, no leak, converges)"

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

  -- Against a world where the referenced bucket exists, the delete appears.
  let dry ← push bs (Plan.absent demoKeys) partialWorld {}
  unless (dry.filter (·.startsWith "would DELETE")).length == 1 do
    throw (IO.userError s!"expected one delete against partialWorld: {dry}")

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
                        namespace' := ⟨"demo"⟩, sourceBucket := .unknown } }⟩ ]
  let ordered ← push bs (Plan.absent demoKeys) both {}
  match slotIdx ordered "scaleway/scaleway-function/ingest",
        slotIdx ordered "aws/s3-bucket/cold" with
  | some fn, some bucket =>
    unless fn < bucket do
      throw (IO.userError s!"on teardown the function must go before its bucket: {ordered}")
  | _, _ => throw (IO.userError s!"expected both deletes: {ordered}")

  IO.println "teardown: ok (no-op when absent, reverse order when present)"

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

/-- Self-checks, run when no subcommand is given. Everything here works
    offline; nothing touches a cloud. -/
def selfCheck : IO Unit := do
  IO.println "infra: refinement core loaded"
  checkPersistenceRoundTrip
  checkPullAndPlan
  checkCredentials
  checkSigning
  checkPush
  checkTeardown
  checkSecretComposition
  checkGcpAssertion

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
    IO.eprintln "usage: lake exe infra new <directory>" *> pure 2
  | ["new", dir] => Infra.Cli.New.scaffold dir
  | _ => Infra.Cli.run "infra" demoPlan selfCheck (args := args)
