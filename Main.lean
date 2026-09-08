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

/-- The ledger round-trips, keeps rows the declaration has dropped, and
    refuses to read a file it did not write.

    The middle property is the one that matters and the one the cache cannot
    have: `Persistence.load` drops any name the current key family does not
    claim, which is exactly why membership could not live there. A ledger that
    silently dropped an undeclared row would abandon the resource instead of
    destroying it, which is the bug this whole mechanism exists to fix. -/
def checkLedger : IO Unit := do
  let tmp ← IO.FS.createTempDir
  try
    let rows : List Ledger.Row :=
      [ { cloud := .aws,      kind := .objectStore, name := "assets", region := "eu-west-3" }
      , { cloud := .scaleway, kind := .queues,      name := "jobs",   region := "fr-par" } ]
    Ledger.save tmp rows
    let loaded ← Ledger.load tmp
    unless loaded.length == rows.length do
      throw (IO.userError s!"ledger round-trip: saved {rows.length}, loaded {loaded.length}")
    -- Every field survives. The region especially: without it a row is
    -- undeletable in a multi-region fleet, and nothing else records it once
    -- the declaration that placed the resource is gone.
    unless loaded.any (fun r => r.cloud == .aws && r.name == "assets"
                                && r.region == "eu-west-3") do
      throw (IO.userError "ledger round-trip lost a row's cloud, name or region")

    -- `save` sorts and `load` deliberately does not, so this checks what was
    -- written rather than what was read. Comparing against `Ledger.sorted`
    -- rather than re-spelling its comparator: a copy would have to be edited
    -- alongside it and would keep passing either way.
    unless loaded == Ledger.sorted loaded do
      throw (IO.userError "ledger rows were not written in sorted order")

    -- An empty ledger is a *file* saying "nothing is managed", not a missing
    -- one. Distinguishing the two is the point: a missing file cannot be told
    -- apart from a deleted file, and the difference decides whether anything
    -- gets destroyed.
    Ledger.save tmp []
    unless (← (Ledger.path tmp).pathExists) do
      throw (IO.userError "an emptied ledger deleted its own file")
    unless (← Ledger.load tmp).isEmpty do
      throw (IO.userError "an emptied ledger still reported rows")

    -- A file this tool did not write must stop the run rather than read as
    -- empty. Reading it as empty would orphan everything it recorded.
    IO.FS.writeFile (Ledger.path tmp) "{\"rows\": []}"
    match ← (Ledger.load tmp).toBaseIO with
    | .error _ => pure ()
    | .ok _    => throw (IO.userError "a ledger with no version was accepted")

    IO.println "ledger: ok (round-trip, sorted, empty is a file, unversioned is refused)"
  finally
    IO.FS.removeDirAll tmp

/-- An apply records what it claims, even when it has nothing to do.

    This is the check the offline suite was missing, and its absence cost three
    live runs. The ledger used to learn about a resource only through an
    *action*: a resource that already existed and already matched produced
    none, so it was never recorded — and then nothing could ever destroy it.
    On a real account that is a leak, and it is the commonest case there is,
    because it is what every second apply looks like.

    `composedAppliedWorld` is exactly that world: all three resources exist and
    match, so the work-list is empty. The assertion is that the ledger comes
    out holding all three anyway. -/
def checkLedgerAdoption : IO Unit := do
  let tmp ← IO.FS.createTempDir
  try
    let bs := Infra.Providers.all
    let store : Store composedKeys :=
      { root := some tmp, regionOf := fun _ _ _ => "fr-par" }
    -- Nothing to do: the world already realises the target.
    let dry ← push bs composedPlan composedAppliedWorld {} (store := store)
    unless dry.any (fun l => (l.splitOn "nothing to do").length > 1) do
      throw (IO.userError s!"expected an empty plan, got: {dry}")
    -- A dry run must not have written anything.
    unless (← Ledger.load tmp).isEmpty do
      throw (IO.userError "a dry run wrote to the ledger")

    let applied ← push bs composedPlan composedAppliedWorld { apply := true } (store := store)
    unless applied.any (fun l => (l.splitOn "nothing to do").length > 1) do
      throw (IO.userError s!"expected an empty apply, got: {applied}")
    let rows ← Ledger.load tmp
    unless rows.length == 3 do
      throw (IO.userError s!"an apply with nothing to do recorded {rows.length} of 3 \
resources; a resource that needs no action is still managed")
    -- And the region was recorded, which is what routes its eventual delete.
    unless rows.all (fun r => r.region == "fr-par") do
      throw (IO.userError "adopted rows lost their region")
    IO.println "ledger: ok (an apply with nothing to do still records what it claims)"
  finally
    IO.FS.removeDirAll tmp

/-- A `Backends` whose `.aws` backend answers `ownershipInfo` with a fixed
    verdict, rather than the placeholder default of `none`. This is what lets
    the checks below exercise `Ownership.ownershipOf` itself — the placeholder
    backends alone can only ever exercise the "not migrated" fallback, since
    their `ownershipInfo` never answers `some`. -/
private def gatedBackends (marked : Bool) (value : String := legacyMarkerValue) :
    Backends where
  backend
    | .aws =>
      { Infra.Providers.placeholderBackend "aws" with
          ownershipInfo := fun _ _ =>
            pure (some ((if marked then [(markerKey, value)] else []), none)) }
    | .scaleway => Infra.Providers.placeholderBackend "scaleway"
    | .gcp      => Infra.Providers.placeholderBackend "gcp"

/-- The adoption loop in `push` and the recheck before a `deleteOrphan` both
    used to be pure name matches; both now consult `Ownership.ownershipOf`
    where a backend can answer it. This is what checks that wiring actually
    runs, not just that it type-checks. -/
def checkOwnershipGate : IO Unit := do
  let tmp ← IO.FS.createTempDir
  try
    -- The AWS `assets` bucket already exists and matches its spec, but this
    -- account's backend reports no marker tag on it: someone else's bucket,
    -- named the same as the one this fleet declares. Adopting it anyway is
    -- exactly the bug this model exists to prevent.
    let foreign : Store demoKeys := { root := some tmp, regionOf := fun _ _ _ => "eu-west-1" }
    -- Streams captured, because *saying so* is half of the behaviour here. Not
    -- adopting the bucket is the safe half; the loud half is that the operator
    -- is told, since a fleet managing less than it declares produces no plan
    -- line, no action and no other trace. The live test's ledger assertion is
    -- what turns this warning into a red build in CI.
    let (said, _) ← IO.FS.withIsolatedStreams
      (push (gatedBackends false) demoPlan partialWorld { apply := true } (store := foreign))
    let rows ← Ledger.load tmp
    if rows.any (Ledger.Row.isAt · .aws .objectStore "assets") then
      throw (IO.userError "an unmarked bucket was adopted into the ledger")
    unless mentions said "aws/object-store/assets" && mentions said markerKey do
      throw (IO.userError s!"an unmarked but declared bucket was passed over silently; \
the run said: {said}")

    -- Same bucket, marker present: this time it must be adopted.
    let managed : Store demoKeys := { root := some tmp, regionOf := fun _ _ _ => "eu-west-1" }
    let _ ← push (gatedBackends true) demoPlan partialWorld { apply := true } (store := managed)
    unless (← Ledger.load tmp).any (Ledger.Row.isAt · .aws .objectStore "assets") do
      throw (IO.userError "a marked bucket was not adopted into the ledger")

    IO.println "ownership gate: ok (adoption follows the marker, not just a name match)"
  finally
    IO.FS.removeDirAll tmp

/-- Two fleets, one account, one bucket name — and the marker's *value* is
    what keeps them apart.

    `Boundary.fleet` is opt-in, so this also pins the two directions that must
    not change for anyone who never sets it: an unnamed fleet still accepts any
    marker value it finds, and the legacy value still matches every fleet. That
    second one is what stops naming a fleet from orphaning an estate tagged
    before the name existed — the failure this would otherwise ship with. -/
def checkFleetIsolation : IO Unit := do
  -- One leg, in its own ledger: an account whose bucket carries `tagValue`, a
  -- fleet calling itself `me`, and whether the bucket ends up managed.
  let adopts (me : Option String) (tagValue : String) : IO (Bool × String) := do
    let tmp ← IO.FS.createTempDir
    let store : Store demoKeys :=
      { root := some tmp, regionOf := fun _ _ _ => "eu-west-1"
        boundary := { fleetName := me } }
    let (said, _) ← IO.FS.withIsolatedStreams
      (push (gatedBackends true tagValue) demoPlan partialWorld { apply := true }
        (store := store))
    let managed := (← Ledger.load tmp).any (Ledger.Row.isAt · .aws .objectStore "assets")
    IO.FS.removeDirAll tmp
    return (managed, said)

  -- The isolation itself: another fleet's marker is as good as no marker.
  let (theirs, said) ← adopts (some "mine") "theirs"
  if theirs then
    throw (IO.userError "a bucket marked by another fleet was adopted")
  unless mentions said "aws/object-store/assets" do
    throw (IO.userError s!"another fleet's bucket was passed over silently: {said}")
  -- Our own name, adopted.
  unless (← adopts (some "mine") "mine").1 do
    throw (IO.userError "a bucket carrying this fleet's own name was not adopted")
  -- The legacy value, adopted whatever the fleet is called. Deleting this
  -- assertion is deleting the upgrade path.
  unless (← adopts (some "mine") legacyMarkerValue).1 do
    throw (IO.userError "a bucket tagged before fleets had names was not adopted")
  -- And an unnamed fleet is unchanged: it reads the key and ignores the value.
  unless (← adopts none "anything-at-all").1 do
    throw (IO.userError "an unnamed fleet stopped adopting a marked bucket")
  IO.println "fleet isolation: ok (the marker's value separates fleets; the legacy value \
still matches every fleet)"

/-- A ledger row for a name the current declaration no longer claims is an
    orphan, and `push` re-checks its marker immediately before deleting it —
    see the comment above that check in `Engine.push`. This pins both halves:
    a stripped marker refuses the delete, and a marker still present lets it
    proceed. -/
def checkOrphanRecheck : IO Unit := do
  let tmp ← IO.FS.createTempDir
  try
    let staleRow : Ledger.Row :=
      { cloud := .aws, kind := .objectStore, name := "old-bucket", region := "eu-west-1" }

    let unmarked : Store demoKeys := { root := some tmp, rows := [staleRow] }
    match ← (push (gatedBackends false) demoPlan emptyWorld { apply := true }
        (store := unmarked)).toBaseIO with
    | .error e =>
      unless mentions (toString e) "no longer carries the marker tag" do
        throw (IO.userError s!"orphan recheck failed for the wrong reason: {toString e}")
    | .ok lines => throw (IO.userError s!"expected the recheck to refuse the delete, got: {lines}")
    unless (← Ledger.load tmp).any (·.name == "old-bucket") do
      throw (IO.userError "a refused delete still dropped the ledger row")

    let marked : Store demoKeys := { root := some tmp, rows := [staleRow] }
    let _ ← push (gatedBackends true) demoPlan emptyWorld { apply := true } (store := marked)
    if (← Ledger.load tmp).any (·.name == "old-bucket") then
      throw (IO.userError "a marked orphan was not deleted")

    IO.println "orphan recheck: ok (a stripped marker refuses the delete; present, it proceeds)"
  finally
    IO.FS.removeDirAll tmp

/-- A refused orphan delete is retried, and only fails when it stops making
    progress.

    Orphans are the one part of a work-list with no edges to sort by: a
    resource whose declaration is gone has no spec, so nothing states what it
    referenced, and a ledger row holds a name and a region rather than a
    dependency list. So the order is discovered instead of computed — a
    provider that refuses ("DependencyViolation: resource is in use", the
    security group an instance still holds) is taken at its word and asked
    again after the rest of the work-list has run.

    Both halves are pinned, because the second is what stops the first from
    swallowing real failures: a refusal that clears is retried until the
    teardown completes, and one that never clears fails the apply with the
    provider's own words. -/
def checkOrphanRetry : IO Unit := do
  let tmp ← IO.FS.createTempDir
  try
    let row (nm : String) : Ledger.Row :=
      { cloud := .aws, kind := .objectStore, name := nm, region := "eu-west-1" }
    let rows := [row "blocked", row "other"]
    -- Refuses to delete `blocked` its first `limit` times and then allows it,
    -- which is the shape of a dependency refusal — no until something else is
    -- gone — without needing a second kind or a real graph.
    let flaky (limit : Nat) : IO (Backends × IO.Ref Nat) := do
      let tries ← IO.mkRef 0
      return ({ backend := fun p =>
                  { Infra.Providers.placeholderBackend p.name with
                      delete := fun _ h => do
                        if h.raw == "blocked" && (← tries.get) < limit then
                          tries.modify (· + 1)
                          throw (IO.userError "DependencyViolation: resource is in use")
                        pure () } }, tries)

    -- One refusal, then it clears: the apply must finish and empty the ledger.
    let (bs, tries) ← flaky 1
    Ledger.save tmp rows
    let lines ← push bs (Plan.absent demoKeys) emptyWorld { apply := true }
      (store := { root := some tmp, rows := rows })
    unless (← tries.get) == 1 do
      throw (IO.userError "the refusal never happened, so the retry proves nothing")
    unless (← Ledger.load tmp).isEmpty do
      throw (IO.userError s!"a retried teardown left the ledger holding {(← Ledger.load tmp).length} row(s)")
    for nm in ["blocked", "other"] do
      unless lines.any (mentions · s!"aws/object-store/{nm}") do
        throw (IO.userError s!"the log does not report deleting {nm}: {lines}")

    -- A refusal that never clears is a failure, reported as the provider put
    -- it and naming the slot. Retrying must not turn a real error into
    -- silence.
    let (stuck, _) ← flaky 99
    Ledger.save tmp rows
    match ← (push stuck (Plan.absent demoKeys) emptyWorld { apply := true }
        (store := { root := some tmp, rows := rows })).toBaseIO with
    | .ok l => throw (IO.userError s!"a permanently refused delete reported success: {l}")
    | .error e =>
      for expected in ["aws/object-store/blocked", "DependencyViolation"] do
        unless mentions (toString e) expected do
          throw (IO.userError s!"the refusal does not mention {expected}: {toString e}")
    -- The one that could go, went; the one that could not, is still recorded.
    let left ← Ledger.load tmp
    unless left.map (·.name) == ["blocked"] do
      throw (IO.userError s!"the ledger after a stuck teardown holds {left.map (·.name)}")

    IO.println "orphan retry: ok (a refused orphan delete is retried; a permanent \
refusal still fails)"
  finally
    IO.FS.removeDirAll tmp

/-- A teardown routed through a cloud nobody authenticated must refuse.

    This is the defect the 2026-09-08 live runs hid: `Infra.Cli.liveFor` loads
    credentials for the providers a key family names and substitutes a
    placeholder for the rest, and a placeholder's `delete` returns `()`. Two
    clouds reported a clean teardown with their whole estate standing.

    The two halves are checked here because nothing else can see them: a real
    cloud is not available offline, and the substitution is invisible by
    construction — a placeholder answers exactly as an empty account does. So
    the marked backend must refuse and leave the row, and an unmarked one —
    every test double in this file, and every live backend — must still be
    free to delete. -/
def checkUnreachableRefusal : IO Unit := do
  let tmp ← IO.FS.createTempDir
  try
    let staleRow : Ledger.Row :=
      { cloud := .aws, kind := .objectStore, name := "old-bucket", region := "eu-west-1" }
    -- Exactly what `liveFor` hands back for a cloud it loaded no credentials
    -- for, and otherwise the same placeholder the rest of this suite uses.
    let unreachable : Backends :=
      { backend := fun p =>
          { Infra.Providers.placeholderBackend p.name with
              unreachable := some "no aws credentials were loaded" } }

    -- Written to disk first, because the refusal happens before `push` writes
    -- anything: "the row survived" has to mean the file still holds it, not
    -- that a file was never created.
    Ledger.save tmp [staleRow]

    match ← (push unreachable (Plan.absent demoKeys) emptyWorld { apply := true }
        (store := { root := some tmp, rows := [staleRow] })).toBaseIO with
    | .error e =>
      unless mentions (toString e) "aws/object-store/old-bucket" do
        throw (IO.userError s!"the refusal did not name the row: {toString e}")
      unless mentions (toString e) "without deleting any of them" do
        throw (IO.userError s!"push refused for the wrong reason: {toString e}")
    | .ok lines =>
      throw (IO.userError s!"a teardown through an unreachable cloud was allowed: {lines}")
    unless (← Ledger.load tmp).any (·.name == "old-bucket") do
      throw (IO.userError "a refused teardown still dropped the ledger row")

    -- And the same teardown through a reachable backend still empties it, so
    -- the guard is the substitution and not teardowns in general.
    let reachable : Backends := { backend := fun p => Infra.Providers.placeholderBackend p.name }
    let _ ← push reachable (Plan.absent demoKeys) emptyWorld { apply := true }
      (store := { root := some tmp, rows := [staleRow] })
    unless (← Ledger.load tmp).isEmpty do
      throw (IO.userError "a teardown through a reachable backend left the ledger populated")

    IO.println "unreachable cloud: ok (a ledger row it cannot reach refuses the apply)"
  finally
    IO.FS.removeDirAll tmp

/-- `discover` rebuilds a ledger row straight from `list` and `ownershipInfo`,
    with no ledger to start from at all — the "lost ledger" case
    `docs/persistence.md` claims `discover` recovers from. -/
def checkDiscover : IO Unit := do
  let listsOneBucket (marked : Bool) : Backend :=
    { Infra.Providers.placeholderBackend "aws" with
        list := fun k =>
          match k with
          | .objectStore => pure [Infra.Providers.placeholderObserved .objectStore "assets"]
          | _            => pure []
        ownershipInfo := fun _ _ =>
          pure (some ((if marked then [(markerKey, "true")] else []), none)) }
  let bs (marked : Bool) : Backends :=
    { backend := fun p =>
        match p with
        | .aws      => listsOneBucket marked
        | .scaleway => Infra.Providers.placeholderBackend "scaleway"
        | .gcp      => Infra.Providers.placeholderBackend "gcp" }

  let found ← discover (κ := demoKeys) (bs true) {} (fun _ _ _ => "eu-west-1") []
  unless found.any (Ledger.Row.isAt · .aws .objectStore "assets") do
    throw (IO.userError s!"discover did not recover the marked bucket, found {found.length} row(s)")

  let notFound ← discover (κ := demoKeys) (bs false) {} (fun _ _ _ => "eu-west-1") []
  if notFound.any (Ledger.Row.isAt · .aws .objectStore "assets") then
    throw (IO.userError "discover claimed an unmarked bucket")

  IO.println "discover: ok (rebuilds a lost ledger from the marker tag, not from naming)"

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
                        namespace' := ⟨"demo"⟩, code := .unknown
                        handler := .unknown, sourceBucket := .unknown } }⟩ ]
  let ordered ← push bs (Plan.absent demoKeys) both {}
  match slotIdx ordered "scaleway/scaleway-function/ingest",
        slotIdx ordered "aws/s3-bucket/cold" with
  | some fn, some bucket =>
    unless fn < bucket do
      throw (IO.userError s!"on teardown the function must go before its bucket: {ordered}")
  | _, _ => throw (IO.userError s!"expected both deletes: {ordered}")

  IO.println "teardown: ok (no-op when absent, reverse order when present)"

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
  let gone ← pull (κ := demoKeys) (← IO.FS.createTempDir)
    (backendsWith "HTTP 400 com.amazonaws.sqs#QueueDoesNotExist: The specified queue does not exist.")
  match gone.sighting .aws .objectStore .assets with
  | none   => pure ()
  | some _ => throw (IO.userError "a vanished resource was reported as present")

  -- Denied: the pull must fail rather than silently report absence, because
  -- "absent" would make the next apply create a duplicate.
  match ← (pull (κ := demoKeys) (← IO.FS.createTempDir)
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
  checkPersistenceRoundTrip
  checkLedger
  checkLedgerAdoption
  checkOwnershipGate
  checkFleetIsolation
  checkOrphanRecheck
  checkOrphanRetry
  checkUnreachableRefusal
  checkDiscover
  checkLatestImage
  checkUnsetLaunchField
  checkPullAndPlan
  checkCredentials
  checkSigning
  checkPush
  checkTeardown
  checkSecretComposition
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
  -- `demoPlan` is hand-written rather than declared by the `fleet` command, so
  -- it has no `forget` declarations to pass.
  | _ => Infra.Cli.run "infra" demoPlan selfCheck (forgets := []) (args := args)
