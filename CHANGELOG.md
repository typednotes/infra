# Changelog

Notable changes to `infra`. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions are
[semantic](https://semver.org/), with the 0.x caveat that a minor bump may
break the Lean API — and before a first tagged release, several will.

`docs/coverage.md` is the standing statement of what exists and how far it has
been exercised; this file is what changed and when.

## [Unreleased]

### Pending: `JsonRead.setField` belongs in `linen`

"Rewrite one field of a JSON object, leaving every other field and their order
alone" is a `Data.Json.Value` operation, not an infrastructure-as-code one. It
lives in `Infra/Providers/JsonRead.lean` because GCP's `setIamPolicy` needs it
and nothing in `linen`'s `Data.Json` offers it yet. Listed here rather than
left implicit, for the reason the moves below are.

### Pending: delete the code that has moved to `linen`
`linen` 0.16.0 adds `Linen.Cloud`, a cloud-services layer that includes the
building blocks this project has been carrying:

| moved to `linen` | was here |
|---|---|
| `Cloud.Provider` — the three clouds, `Locality`, per-cloud region codes, `Region p` | `Infra/Core/Kind.lean` (`ProviderId`), `Infra/Core/Region.lean` |
| `Cloud.Credentials` (+ `.Keychain`, `.Gcp`) — the three-source chain, redacting `Repr`, `normalizeEnv`, `sourceDescriptions` | `Infra/Core/Credentials.lean`, `Infra/Core/GcpAuth.lean` |
| `Cloud.Endpoint` — per-service hosts and signing scopes | `Infra/Providers/Aws/Protocols.lean`, `Infra/Providers/{Scaleway,Gcp}/Rest.lean` |
| `Cloud.Auth`, `Cloud.Transport` — signing and the single egress point | `Infra/Providers/Aws/Sign.lean`, `Infra/Providers/Http.lean` |
| `Cloud.Protocol.{S3,AwsJson,GoogleRest,ScalewayRest}` — the four wire dialects | `Infra/Providers/Aws/Protocols.lean`, `.../{Scaleway,Gcp}/Rest.lean` |
| `Cloud.Error` — the classified taxonomy, including the not-found code list | `Infra/Core/Backend.lean`'s `readsAsAbsent`, and the access-denied half of its `readsAsRefused` (0.17.2) |

`readsAsRefused` is not a straight duplicate of `Cloud.Error.Class.denied`:
`linen`'s `denied` also covers signature and credential failures
(`SignatureDoesNotMatch`, `ExpiredToken`, …) and does not tell a disabled
Google API from a hidden resource, and both of those must *not* read as
"this one resource is not ours". The move therefore needs `linen` to split
`denied` (refused-for-this-resource vs. not-authenticated vs. service off)
first; proposed there rather than worked around here.

`linen` also gained the **data plane** these never had — object CRUD, message
send/receive/ack, and secret reads — which `Infra/Providers/Kinds/*`
deliberately excluded ("bucket-level operations only: no object CRUD").

**Not done here yet, and why.** That first blocker is gone: the pin is
`v1.0.0`, `lake update linen` has run, and `Linen.Cloud` builds here — so the
"cannot yet be built" reason no longer applies and should not be reached for
again. What remains is the part that was never mechanical: `ProviderId` and
`Credentials` thread through most of `Infra/`, and `Region` is indexed by
`ProviderId`, so switching to `Cloud.Provider` and `Cloud.Credentials` touches
the engine as well as the providers. It is written down rather than
half-applied.

Note that `infra` still imports none of `Linen.Cloud` — only the general
modules (`Crypto`, `Data`, `Network`, `System.Keychain`, `Text`) — so every
duplicate listed above is still live in both repositories.

Three corrections to take at the same time, all of which `linen`'s versions
already carry:

- **Pagination that reports whether it finished.** `Gcp/Storage.lean` and
  `Gcp/PubSub.lean` cap at 50 pages, warn on stderr, and return a `List`
  indistinguishable from a complete one — which their own comments explain is
  dangerous, since a truncated listing read as complete makes the planner
  propose creating resources that already exist. `Cloud.Page.Listing` carries
  `truncated` and derives `complete` from it.
- **Unsupported operations as values rather than raises.**
  `Scaleway/Sqs.lean:206` raises, and `Aws/Protocols.lean:199` signs against a
  deliberately `.invalid` host; `Cloud.Error.Class.unsupported` is returned
  instead.
- **No panicking UTF-8 decode.** `Kinds/Secrets.lean` uses `String.fromUTF8!`
  in two places; `linen` uses `String.fromUTF8?` and reports a `protocol`
  error.

One thing deliberately **not** moved: `Scaleway/Sqs.lean`'s credential minting.
It makes "`infra` is this library's name" a rule, and its `reclaim` deletes any
credential holding that name — defensible for a tool that owns its fleet,
unacceptable in a library, so `linen` reads a dedicated credential instead.

### Fixed: the page had been advertising 0.9.0 for two releases

`site/index.html`'s "what's new" banner still read **0.9.0** — through 0.10.0,
0.10.1 and into this release — and `README.md`'s "What 0.9.0 covers" heading
with it. The README's *body* underneath it was accurate; only the heading was
stale, which is the worst shape for this kind of drift, since nothing about
reading the section suggests the number above it is wrong.

Fixing the two strings is the small half. `ci/check-release-version.sh` did
not know about either, because neither is a `rev = ` line — so the release
workflow, which gates a tag on that script, passed v0.10.0 and v0.10.1 with
the page announcing a release two behind. The script now checks **nine**
places rather than seven, `AGENTS.md`'s checklist names them, and it says to
read the list off the script rather than counting by hand.

One marker moved the other way: `ci/README.md`'s "as of 0.10.0" on its live-
fleet table is now a date. It records when somebody last checked the table,
not which release it belongs to, and a version there would be one more thing
every release has to remember for no benefit.

### Changed: `ci/` is bash, all of it

`check-aws-policy.py` and `check-scaleway-scoping.py` are now `.sh`, and the
scaffold step's inline Python here-doc is bash too — so every check in this
repository is one language, and `AGENTS.md` says so.

JSON is not a reason to reach for Python: `jq` is pre-installed on both runner
images (ubuntu-24.04 ships 1.7, macos-15 ships 1.8.2), and the script checks
for it rather than assuming, since a missing interpreter must not produce an
empty report that reads as a pass.

Both rewrites were validated by running the old and new versions side by side
over deliberately broken inputs and diffing, rather than by watching them both
pass on the current tree — which proves nothing, as the first draft of the
scoping check demonstrated by silently matching nothing and passing. That
exercise found three defects that the happy path could not:

- the scoping check sorted findings lexically, so line 196 was reported before
  line 67;
- the policy check crashed inside `jq` when `Statement` was an object rather
  than a list, and reported the crash as "is not valid JSON";
- and, in the process, that the **Python** version raised an uncaught
  `AttributeError` on a `Statement` holding non-objects. The bash version
  reports `statement 0: must be an object, found string`, so this is one
  behaviour that is better rather than merely equivalent.

The inline block loses `sed -i` along with Python: BSD sed reads the next
argument as a backup suffix and GNU sed does not, which is the dialect split
that put Python there in the first place. Writing to a temporary file and
moving it over needs no dialect.

## [0.18.0] — 2026-09-25

### Added: `--refresh-secrets`, on `plan` and `apply`

A secret was create-only: no cloud shows its value in metadata, so once it
existed nothing compared it, and a second apply asked for nothing. That left
every copy of a value as it was first written — a CI secret changed after the
first apply never reached the cloud, and a connection string composed from a
rebuilt database kept the old endpoint. The only remedy was renaming the
secret.

With the flag, `Engine.refreshSecrets` reads the stored value of every
declared `fromEnv` and `composed` secret that exists and carries the fleet's
marker, compares it with what the declaration would write now (the variable;
the recipe settled against its inputs' current values), and plans an `UPDATE`
where they differ. The copies follow, in dependency order: a composed secret
built from a rewritten one — or from a resource this run creates or replaces —
is rewritten after it, without being compared; a `compute` (`env` through
`secretValueOf`) or `scalewayContainer` (`secretEnv`) holding one is updated
after that. Each addition has a `refresh-secrets:` line saying why; none says
a value. Without the flag nothing changes: a plan reads no value at all.

Not covered, and said so in `docs/coverage.md`: `apiKeyFor` (rotation revokes
a live key — delete the secret and apply), a database's
`masterPasswordSecret` (read once, at creation), and a `secretValueOf` in any
kind whose `update` does not re-send it (`resendsSecretsOnUpdate`; warned by
name). `checkRefreshSecrets` pins it offline — a stale variable, a stale
recipe, the cascade, convergence, no read without the flag, no value printed,
the minted key never read.

`envSecretValue` moved from `Kinds.Secrets` to `Infra.Specs`, so the backend
writing a secret and the engine comparing one read the variable the same way.

### Added: `destroy --keep-data`, and `plan --destroy --keep-data`

A teardown that leaves the data standing: `postgres`, `postgresMigrations`,
`objectStore`, `s3Bucket`, and the secret a declared database names as its
`masterPasswordSecret` — declared or orphaned alike (`Plan.keepingData`,
`keptByTeardown`; `Kind.holdsData` is total, so a new kind has to be
decided). Each kept resource that exists gets a `KEEP` line. What is kept
keeps the fleet's marker, so the next `apply` finds it and manages it again.
`checkKeepData` pins it offline.

### Changed: CLI flags are parsed, not matched

`parseReconcile` replaces the list of exact argument lists. Flags may come in
any order; an unknown one, a repeated one, or one that means nothing for the
command (`--keep-data` without a teardown, `--refresh-secrets` on one) is a
usage error rather than ignored.

## [0.17.3] — 2026-09-24

### Fixed: a missing tag-read permission read as one warning per resource

0.17.2 left alone every undeclared resource whose marker read was refused, and
said so per resource. Nothing in a refusal tells "this resource's own policy
shuts us out" from "these credentials may not read tags", so a role missing a
tag-read permission (`s3:GetBucketTagging`, say) turned a whole kind into
warnings: every orphan of it left standing, and the run green. That is the
widening from one resource to a whole kind that a refused listing already
fails for.

Now reading the marker is required to handle a kind that carries one. A
refusal is left alone only when the same scan read another marker of that
kind, in that region. If none was read, one declared resource of the kind is
read as a probe; if that is refused too, or there is none, the run fails,
naming the kind, every refused resource and the way out
(`Engine.refusedWithoutPermission`). `forget`ed resources do not count, so a
kind whose only other resource is locked on purpose can still run. The
`docs.typednotes.org` case this rule exists for is unchanged: its sibling
bucket `typednotes` is readable.

`checkRefusedIsNotManaged` gains the three cases: every read refused fails, a
readable declared resource settles it, and a refused one does not. Each was
checked by removing it from the engine and watching the suite fail.

### Fixed: the Scaleway and GCP live tests could not list every kind

Since 0.17.0 every run lists every kind on the fleet's clouds, declared or not,
and the CI credentials had been confined so that they could not: the Scaleway
leg failed on `GET /iam/v1alpha1/applications` (`403 permissions_denied`), and
the GCP leg on Cloud SQL (`Cloud SQL Admin API has not been used in project …
or it is disabled`). A refused listing stays fatal — that is the design — so
the credentials now hold read access to exactly what the scan calls, and
nothing that can change it (2026-09-24, `ci/README.md`):

- **Scaleway**, on the existing `infra-ci-live-tests` policy:
  `RelationalDatabasesReadOnly` and `ServerlessSQLDatabaseReadOnly` in the CI
  project, and `IAMApplicationReadOnly` at **organization** scope — the one
  organization-level rule CI holds, read-only and applications-only.
- **GCP**: `sqladmin.googleapis.com` enabled, and a custom role
  `infraCiCloudSqlRead` holding only `cloudsql.instances.list` and `.get` —
  not `roles/cloudsql.viewer`, which also carries `cloudsql.instances.export`.

`live-test.yml` now passes `SCW_DEFAULT_ORGANIZATION_ID` to the backstop
teardown, whose `destroy` had failed with `no Scaleway organization configured`
since the scan began listing IAM, and requires it in the secrets check. Two
stale passages in `ci/README.md` are corrected: an organization-wide
`IAMManager` policy shown as the one CI uses, and "a tag read that errors
fails the run", which 0.17.2 made untrue for access-denied reads of undeclared
resources.

## [0.17.2] — 2026-09-24

### Changed: what infra may not read, it does not manage

An undeclared resource whose ownership marker the cloud refuses to show these
credentials — access denied, after the listing that showed it succeeded — is
now warned about by name and left alone, and the run goes on. Before, it failed
the whole run, although it could never have been claimed: changing or
destroying anything needs a readable marker naming this fleet.

Found by `typednotes-infra`'s first CI apply on 0.17.1. Once bucket requests
went to the right project, the scan found `docs.typednotes.org`, a
hand-managed Scaleway bucket whose bucket policy names only a user and a
deleted application; `GetBucketTagging` answered `403 AccessDenied` to the CI
key, and every plan and apply failed on a bucket the fleet has nothing to do
with. (The green `Plan` run on the same commit hit the same 403 and hid it:
that workflow pipes into `tee` without `pipefail`.)

Narrow on purpose, and each limit is tested (`checkRefusedIsNotManaged`):

- only a **marker read** of an **undeclared** resource. A refused *listing*
  still fails the run — it could hide a whole kind's orphans — as does a
  declared resource that cannot be read, and the re-reads before an orphan's
  delete or release;
- only **access denied** (`Backend.readsAsRefused`): a 403 carrying
  `AccessDenied`, `AccessDeniedException`, `UnauthorizedOperation`,
  `permissions_denied` or `PERMISSION_DENIED`. A disabled Google API (also
  `PERMISSION_DENIED`), a signature or credential failure, and every non-403
  still fail;
- warned once per physical resource, however many kinds list it; a forgotten
  one that cannot be read is neither released nor claimed, and its `forget`
  line stays.

Any other failed marker read now names the resource it was reading, rather
than printing only the provider's error. `Snapshot.Resource` gains `refusal`,
so a snapshot can describe a resource whose marker read is refused.

The cost, stated in `docs/coverage.md`: this is the one place two machines
can disagree. If such a resource did carry this fleet's marker, credentials
that can read it would act on it and credentials that cannot would leave it.

## [0.17.1] — 2026-09-23

### Fixed: Scaleway Object Storage requests went to the API key's default project

S3 has no project parameter, so Scaleway serves an S3 request from the API
key's *own* default project unless the access key is written
`<key>@<project-id>`. infra signed with the bare key, so every Scaleway bucket
call — listing included — went to whatever project the key defaulted to,
while every other Scaleway call passed the fleet's `project_id`. Found by
`typednotes-infra`'s first 0.17.0 CI apply: its key defaults to a project it
has no rights in, and the bucket scan every run now performs failed with
`403 AccessDenied`. Locally it was silent and worse: the key defaulted to an
empty project, so the scan found no buckets and a bucket this fleet left
behind in its real project would never have been found. `Endpoint` gains a
`project`, which `s3For` fills for Scaleway and the signer appends to the
access key (checked offline in `checkSigning`, and live with the same key
against both projects).

A refused listing during the scan now says which kind was being listed and
why every kind is listed, rather than only the raw HTTP error.

## [0.17.0] — 2026-09-23

Five simplifications, each removing an exception to "the marker decides".

### Changed: every fleet has a name; the `true` marker is retired

**Breaking.** `Infra.Core.Fleet` has a required `name`. The `fleet` command
sets it from the identifier in kebab-case (`fleetNameOfIdent`: `fleet
typednotes` → `typednotes`, `fleet crossCloud` → `cross-cloud`), and
`Boundary.fleetName` is now an override of it. `Infra.Cli.run` resolves the
name once and, before any live command, checks it is a valid marker value on
every cloud (`validFleetName`: 1–63 lowercase letters, digits, `-`, `_`,
starting with a letter), saying whether to rename the declaration or fix
`fleetName`. Renaming a declaration renames its fleet; pin the old name with
`fleetName` to keep what it created.

The value `true`, which unnamed fleets wrote and every fleet accepted, is
gone: nothing writes it, and nothing accepts it (`retiredMarkerValue` exists
only to warn). A declared resource carrying it is foreign — not changed, and
the warning says to retag it `managed-by-infra=<name>`; an undeclared one is
warned about and never destroyed. With it go `legacyMarkerValue`, the
grandfathering rule, and the "an unnamed fleet claims nothing undeclared"
rule. `claimsUndeclared` is now the same verdict as `ownershipOf`.
`liveBackend`, `live`, `liveFromEnvironment` and `Infra.Cli.liveFor` take the
fleet's name as a required `String`.

### Changed: the name prefix defaults to the fleet's name

`Boundary.prefixes` is `[fleetName ++ "-"]` when neither `namePrefix` nor
`namePrefixes` is set (setting either replaces the default). So a name-rung
resource — a Scaleway Serverless SQL database or queue — named `<fleet>-…` is
managed, and destroyed once undeclared, without configuration.
`example/ScalewayQueue.lean`'s queue is renamed `example-queue-jobs` to match.

### Changed: clouds named in `accounts` are scanned too

Before, a cloud the declaration no longer named was not scanned, so its last
resources had to be removed with `destroy` before the last line went. Now the
scan covers every cloud the fleet declares **or names in `accounts`**: those
are loaded, account-checked (`checkAccounts` covers every named cloud) and
scanned in the fleet's region for them. A named cloud without credentials
here is reported and skipped; a declared one still fails. Retire a cloud by
removing its lines and keeping it in `accounts` until the apply that empties
it. Deliberately not "every cloud whose credentials are loaded": a laptop
holds credentials for unrelated accounts, and `accounts` is the checked
statement of where the fleet lives. `claimUndeclared` scans every cloud the
backends give scanners for; `liveFor` takes `extra` clouds and gives none to
a cloud without credentials.

### Added: `forget` releases the resource

A resource named in `forget` that still carries this fleet's marker on a rung
that can be rewritten — tags, labels, a description — has the marker removed
on the next apply (and on `destroy`): `RELEASE cloud/kind/name` in the plan,
not destructive. It is then no fleet's, and the `forget` line can be deleted.
New: `Action.release`, `Backend.release` (the default refuses),
`Discovered.releases`, `push (releases := …)`, and `released` in `dump`. The
marker is re-checked just before releasing, and every per-cloud
implementation removes it only if it names this fleet, keeping every other
tag, label and word of the description. Implemented for every taggable
`(cloud, kind)` pair on AWS, GCP and Scaleway. A name cannot be unwritten, so
Scaleway queues and Serverless SQL databases keep their `forget` line.
Verified live on Scaleway (a secret and a container namespace: released,
then left alone once their lines were removed); the AWS and GCP calls are
checked offline only until the live suite runs.

### Changed: the Scaleway Queues credential is shared through Secret Manager

The minted SQS credential is also stored as the Scaleway secret
`infra-sqs-credential` in the same project and region, tagged
`infra-internal=sqs-credential` and carrying **no** ownership marker, so no
fleet claims or destroys it. The lookup is memo → keychain → this copy (each
verified against the project's credentials) → mint, then store in both. So CI
runners, which have no keychain, reuse one credential instead of minting a
new one (and invalidating everyone else's) on every run. It is a cache;
deleting it costs one mint. It is the only secret value infra reads back.
Verified live.

## [0.16.0] — 2026-09-23

### Removed: the ledger and the observed-state cache — there is no local state

0.15.0 made the markers decide what a fleet manages, but kept the ledger
(`.infra/<exe>/infra.ledger.json`) and the per-kind cache beside them as
"only a cache". A second record that can disagree with the first is a source
of the very bug 0.15.0 fixed, so both are gone: `Infra.Core.Ledger`,
`Infra.Core.Persistence`, `Engine.observe`/`discover`, the adoption loop, the
`unreachable`-cloud refusal and `Backend.CachedEntry`. Every run reads the
markers from the cloud; a fresh CI runner and the laptop that created a
resource reach the same plan, and there is nothing to gitignore, lose or share.

**Breaking:**
- **CLI:** `refresh` and `discover` are removed. The commands are
  `check | plan [--destroy] | apply [--force] | destroy | dump [FILE]`.
- **`Infra.Cli.run` takes no `cacheRoot`.**
- **Orphans are `Infra.Core.Orphan`** (`cloud`, `kind`, `name`, `region`, in
  the new `Infra/Core/Slot.lean`, with `slotId`, formerly `Ledger.slotId`).
  `Engine.plan`/`actions` take them in place of ledger rows; `push` takes
  `(orphans := …)`.
- **The FORGET action is gone for everything but `postgresMigrations`**, whose
  delete still prints `FORGET` and now does nothing at all. A `forget`
  declaration makes the scan skip the name — and since the resource keeps its
  marker, **the `forget` line must stay for as long as the resource exists**;
  removing it makes the resource an orphan, destroyed on the next apply.
- **A fleet without `fleetName` destroys no undeclared resource by tag.** It
  cannot tell its own resources from another fleet's in a shared account, so
  they are warned about instead (the name rung still claims by prefix). The
  grandfathered marker value `true` was already warned about, not destroyed.
  Name your fleet — the scaffold now does by default.

### Added: `dump` writes a snapshot, and a snapshot is a test fixture

`dump [FILE]` writes what the fleet sees as JSON
(`Infra.Providers.Snapshot`): every resource on the declared clouds and
regions with its ownership evidence and observed state, the undeclared ones
the next apply destroys, the foreign ones it leaves alone, and the warnings —
never a secret value (checked with a canary). `Snapshot.load` reads one back
and `Snapshot.backends` replays it as in-memory backends that record deletes,
so a real account's dump can be a test. `checkMarkerDecides` now runs against
a snapshot, and `checkDumpReplays` checks that a dump round-trips and replays
to the same orphans. A cache may come back one day, but only as a real cache:
deleting it could never change a plan.

### Changed: Scaleway queues are scanned like every other kind

0.15.0 scanned queues only while the fleet declared one, because listing them
needs a minted SQS credential and `plan` must not change the account. Listing
now first asks, read-only, whether Queues is enabled in the project
(`Scaleway.Sqs.enabled`, `GET /mnq/v1beta1/regions/{region}/sqs-info`): if not,
there are no queues and nothing is activated or minted. If it is, listing goes
through the dedicated `infra` SQS credential, minting it the first time — the
one account change a `plan` can still make, and only in a project that already
uses Queues. Queues still have no tags on Scaleway (no `TagQueue` or
`ListQueueTags`), so they are claimed on the name rung.

### Fixed: Scaleway queue calls could be signed for the wrong project

The dedicated SQS credential was cached in the keychain under the constant
account `scaleway-sqs`, whatever the project. So on a machine that had used
Queues in one project, every other project's queue calls were signed with that
credential — which Scaleway scopes to the project it was minted in. Found
live: `typednotes-infra`'s plan listed the *default* project's queues instead
of its own. Now that every fleet scans queues, that means a name-rung fleet
could have claimed another project's queue as an orphan and deleted it there.
The keychain account is now `scaleway-sqs/<project>/<region>`, and a cached
credential is used only after a read-only check that it is still one of that
project's credentials (a credential deleted in the console is replaced rather
than failing). The old entry is no longer read.

### Changed: the scaffold names the fleet

`infra new` now writes `boundary := { fleetName := some "<name>" }`
uncommented, and its README and `Fleet.lean` header say what is now true:
removing a line destroys the resource on the next apply, and only what
carries the fleet's marker is touched.

## [0.15.0] — 2026-09-23

### Changed: the marker decides what a fleet manages — on every run

Two halves of one principle, now written at the top of `AGENTS.md`.

**A resource carrying this fleet's marker that the declaration no longer
names is destroyed on the next apply, on any machine.** Until now orphans came
only from the ledger (`.infra/`), and the marker-based derivation existed only
as the manual `discover` command. So on a machine without the ledger — every
CI runner — deleting a line abandoned the resource. Found on
`typednotes-infra`: its CI applies left `secrets-db-app` (an IAM application
with table-structure rights), `secrets-db-key` (its live API key) and two stale
secrets standing after their lines were removed. `Infra.Cli.run` now asks the
cloud before planning (`Engine.claimUndeclared`). It scans every region the
fleet uses, and every kind the fleet's clouds offer — including a kind the
declaration no longer has anything of, where the *last* resource of it was
just removed (`Backends.scanners`, `Engine.scannableUndeclared`).

**Only a resource carrying the marker is changed or destroyed.** `update`,
`replace` and the keyed `delete` (so `destroy`) used to run against whatever
held a declared name. Only an orphan's delete re-checked the marker — while
the adoption warning told the reader such a resource "will not be created,
changed or destroyed". `push` now drops those actions for a declared resource
that is not verifiably this fleet's, on the plan path too, and says so by name
(`Engine.foreignDeclared`). **Behaviour change:** a backend whose
`ownershipInfo` answers `.unreadable` for a kind can no longer update, replace
or delete resources of that kind. That was the documented intent, and is now
the behaviour.

Details that make it safe rather than merely eager:

- **Physical identity.** An S3 bucket lists as both `objectStore` and
  `s3Bucket`, a Scaleway container as both `compute` and `scalewayContainer`
  (`Engine.physicalClass`). A resource declared under one is not an orphan of
  the other, and an undeclared one gets one row. `discover` had the same flaw
  for a fleet declaring both kinds of a pair; it is class-aware now too.
- **A named fleet destroys only what names it.** The grandfathered marker
  value matches every fleet, so it may still adopt a declared resource but
  never licenses destroying an undeclared one (`Ownership.claimsUndeclared`) —
  warned about instead.
- **`plan` stays read-only.** Scaleway queues are scanned only while the
  fleet declares one, because listing them mints a credential. That, and the
  other cases this cannot reach, are enumerated in `docs/coverage.md`.
- **A listing that fails stops the run**, naming the kind, rather than
  reading as "nothing there". This matters now that kinds a fleet does not use
  are listed: its credentials need read access to them.

Tested with an **empty ledger** — `checkMarkerDecides`, which fails if the
physical-class mapping is removed (checked). Also tested live: a plan of
`typednotes-infra` with no `.infra/` found exactly its four abandoned
resources, plus the two actions it had pending, and claimed nothing else.
The offline push/teardown checks now run against a backend that reports the
marker, and assert the refusal against the placeholder.

## [0.14.1] — 2026-09-23

### Fixed: a minted key's principal was empty after the apply that minted it

`principalOf` and `accessKeyOf` read a minted API key's identity and public
half from the key secret's observed state, and the `.secrets` listing —
which is where observed state comes from — reported both as `""` for every
secret. They were right only in the apply that *minted* the key, whose
observed state came from `create`'s return. So a composed secret declared in
a later apply was built with an empty user name. CI runners start with no
`.infra/` cache, so every apply re-lists.

Found by `typednotes-infra`'s second apply: a new connection string for its
DB inspector composed as `postgres://:…@…`, and pgweb crashed on
`authentication failed`. Composed secrets are create-only, so the bad value
stays until that secret is replaced.

The listing now reads each secret's tags from the same listing call on all
three clouds (`listTagged`: AWS `ListSecrets` entries, GCP secret labels,
Scaleway's flat tags). For a secret carrying the minted-key back-reference
(`Secrets.apiKeyTags`, what `delete` already relies on) it rebuilds both
fields the way `create` computes them. The key id is the public half. The
principal is the AWS user name, the GCP service-account email, or the
Scaleway application's id — one IAM lookup per minted key, Scaleway only.

Checked against the real Scaleway account: the three rebuilt principals equal
the IAM applications' ids (`scw iam application list`), and the one composed
into the first apply's observer URL. Before the fix, all three were `""`.

Known limit: a minted key whose identity was deleted outside infra is
reported with no principal, rather than failing the listing of every secret
in the project.

### Verified live: `postgresMigrations` on Scaleway

`typednotes-infra`'s first apply (2026-09-23) created four migration
histories on two Serverless SQL databases — SQL read from each service's
repository at its release tag, ordered by foreign keys — and gated five
container rollouts on them; a plan afterwards proposed nothing for them.
It settled both provider facts `docs/diff-semantics.md` carried, so that
entry is deleted: `ServerlessSQLDatabaseReadWrite` may `CREATE SCHEMA`
(the permission page lists only tables and indexes), and the read identity
sees every table the DDL identity created, with `SELECT` only.

It also found one nobody predicted: Serverless SQL routes connections by
TLS SNI and refuses a client that sends none. libpq — this library's
driver — sends it; Go's `lib/pq` does not, and needs the
`options=databaseid%3D<id>` parameter Scaleway documents. Recorded in
`docs/migrations.md`.


## [0.14.0] — 2026-09-23

### Added: migrations read from their service's repository

A migration is now declared with a **source** — inline SQL, or an `https://`
URL — instead of carrying its SQL directly:

```lean
migrations := github "typednotes/ledger" "v0.2.0" ["sql/0001_init.sql"]
```

`Infra.Cli.run` fetches every URL before `plan`, `apply` and `refresh`, once
per run and never cached across runs; `Engine.push` refuses a plan that still
holds an unfetched source, and so does the backend. `check` stays offline: it
prints the plan with a labelled stand-in and says which sources it did not
read. So the SQL stays in the service's repository as plain `.sql`, and the
fleet names files at a release tag — adopting a migration is a one-line diff.

Checked against the real thing, not only offline: `fetchSql` read a file from
`raw.githubusercontent.com`, refused a 404 (naming the URL and asking whether
the tag is pushed) and an `http://` URL, and `withFetchedSources` substituted
it into a plan whose ordering was then inferred correctly.

**Breaking:** `PostgresMigrationsSpec.migrations` is `List MigrationDecl`.
Inline histories write `inlineMigrations [(id, sql), …]`; `Migration`
remains the resolved `{ id, sql }` shape.

### Added: ordering between histories, read from the SQL

`typednotes-infra`, the first real consumer of 0.13.0, declares three
histories on one database — the app's (`users`, `orgs`), `ledger`'s
(`usage_events … references orgs(id)`) and `liaison`'s. All three name the
same database and secrets, so they became ready in the same scheduling wave
and ran in *declaration order*: correct only by accident. The foreign keys
already state the dependency, so infra now reads them. `Infra.Core.SqlDeps`
is a conservative, total scanner (comments, strings and dollar-quoted bodies
skipped; unqualified names mean `public`) for `CREATE TABLE` and
`REFERENCES`, and a history is scheduled after every other history on its
database that creates a table it references.

What it cannot settle is refused, never guessed (`Plan.migrationDepsProblem`,
at compile time for inline SQL via `migrationsAreSound`, and in `push` once
URLs are fetched): a reference to a table no history on the database
creates, and a table two histories create.

Pinned by `example/PostgresMigrations.lean`, which declares the dependent
history *first* — checked by deleting the `REFERENCES` and watching the
ordering guard fail — plus negative fleets for an unresolved reference and a
doubly-created table, and a positive one for the same table name on two
databases.

A first draft of this release had an explicit `after : List String` field
instead; it was replaced before the release was pushed, because it declared
a second time what the foreign key already says.

### Changed: a container's `migrations` is a list

A dependency that lives in a service's *code* rather than its SQL — a broker
writing the ledger's tables — is not a history edge; it belongs on the
container. `ScalewayContainerSpec.migrations` is now
`List (K .scaleway .postgresMigrations)` and portable `ComputeSpec.migrations`
is `List String`, so a rollout waits for every history it names.
**Breaking:** `migrations := some h` becomes `migrations := [h]`.

### Added: `Boundary.namePrefixes`

Further prefixes on the name rung, each claiming exactly as `namePrefix`
does; `Boundary.prefixes` is the union and `ownershipOf` checks it. A fleet
that already owns a `secrets-db` cannot bring it under a new prefix —
infra never renames — and should not name a second database, for other
services, after the vault. Listing both prefixes is the honest answer.
Backwards compatible: the field defaults to `[]`, and a boundary that sets
only `namePrefix` behaves exactly as before. An empty entry claims nothing
even beside real ones, and the `foreign` warning names every prefix, not
the first; both pinned in `Ownership.lean`.

### Fixed: a refused `GRANT` no longer aborts a migrations apply

The backend grants `SELECT` on `<schema>.infra_migrations` to `role_read`
when that role exists. Scaleway's "Known differences between Serverless SQL
Databases and PostgreSQL" page (checked 2026-09-23) lists `GRANT … TO role`
as a command that *cannot be performed* — access is managed only through
IAM permission sets. On the one cloud the grant was written for, it could
therefore fail, and a failed statement aborted the apply session before any
migration ran. The `EXECUTE` now sits in its own `BEGIN … EXCEPTION` block
and a refusal is a `NOTICE`. Checked against a local Postgres by running the
exact block as a role that does not own the table. The observation path's
read still fails loudly if the observer truly cannot see the table.

Also newly flagged rather than assumed: the same permission page lists
`CREATE/ALTER/DROP TABLE` and `INDEX` for `ServerlessSQLDatabaseReadWrite`,
not `CREATE SCHEMA`, which the backend needs. Unverified live; recorded in
`docs/diff-semantics.md`'s ledger and the backend's module note.

### Fixed: a one-migration history skipped the empty-`sql` check

`historyIsSound` read `… all fun (a, b) => a.id < b.id && ms.all fun m => …`.
A `fun` body extends as far right as it can, so the empty-id/empty-`sql`
check sat *inside* the pairwise-order lambda — and a history with one
migration has no pairs, so it was never evaluated: `[{ id := "0001",
sql := "" }]` passed `migrationsAreSound`. Every conjunct is now
parenthesised, and `example/PostgresMigrations.lean`'s `emptySql` fleet pins
the case. Found by a new check written the same way, which did not fire.

## [0.13.0] — 2026-09-23

### Added: `postgresMigrations` — a declared migration history

The fifteenth kind, and the first whose backend is a data plane rather than
a cloud control plane: an ordered list of SQL migrations applied to a
declared database's schema by `infra` itself, over the Postgres wire
(`Kinds/Migrations.lean`, through `linen`'s `Database.SQL`).
`docs/migrations.md` is the design doc, written and argued before any of
this was implemented.

- **The plan names the work.** A pending migration is an `UPDATE` against
  the resource, and the SQL under review is the diff of the declaration —
  the review surface the design doc exists to argue for. A history the
  database no longer matches is refused before any action is derived
  (`Plan.migrationsAppendOnly`), answered again by the `Divergent` table
  (conflict can never read as quietly fixable), and checked a third time by
  the backend before it applies anything.
- **Delete means FORGET.** The plan prints `FORGET`, the ledger row goes,
  and the schema stays: its lifetime is the database's, and the `postgres`
  resource's own delete is what drops it.
- **Two identities, deliberately.** Apply reads a read-write URL secret;
  observation (`refresh`/`plan`) reads a *read-only* one — the one widening
  of "the planning path holds no secret value" this kind costs, recorded
  in `docs/diff-semantics.md`'s ledger, and the reason the ephemeral-key
  alternative was rejected: it would have made `refresh` mutating.
- **Ordering is structural.** `scalewayContainer` gained an optional typed
  `migrations` reference, and portable `compute` a name-based one, so a
  rollout waits for its migrations inside the same `apply`.
- **The link line grew.** `infra` now reaches `linen`'s libpq FFI, so the
  native link-flag block — and its mirror in `Infra/Cli/New.lean`, and every
  consumer's duplicated copy — names `libpq`. CI already installed the
  package everywhere for the headers; a consumer now needs it at link time
  too. `typednotes-infra`'s ~80-line copy moves with the same
  `ci/check-lakefile-sync.sh` discipline it always had.

Also: this kind's `list` is route-driven — the only migration sets a
backend can even name are the declared ones, and `discover` cannot rebuild
those ledger rows. That is safe *because* delete is a no-op FORGET; the two
properties are one design decision, carried together in
`docs/coverage.md`.

## [0.12.1] — 2026-09-21

### Fixed

- **A serverless Postgres target no longer demands a master password it
  discards.** `Live.lean`'s `.postgres` create read
  `masterPasswordSecret` *before* routing on `instanceClass`, so a Scaleway
  Serverless SQL Database — a product with no master user, whose `create`
  takes the password as `_password` and drops it — still had to name a secret
  that really existed. `fetchMasterPassword` throws on a missing name and on
  `""` alike, so there was no way to say "there isn't one".

  The failure landed at create, after the IAM application had already been
  made: `CREATE scaleway/postgres/… failed: scaleway secrets: no secret named
  '…'`. The fetch now lives inside the classic branch, which is the only one
  with a master user to set a password on.

  `example/ServerlessSqlIam.lean` was written with
  `masterPasswordSecret := "unused-serverless-sql-is-iam-only"` and so could
  not have been applied as written either. It now says `""`, which is the
  spelling this release makes available for "there is no master password";
  on a classic target `""` still fails, and loudly. An example that compiles
  but is never run is what hid this.

## [0.12.0] — 2026-09-21

### Changed: `linen` v1.0.0 — a consumer builds a tenth of what it used to

The pin moves from `v0.20.0`, and the headline change in that release is
`lean_lib Linen`'s `precompileModules := true` becoming `false`. Precompiling
forces `Linen:shared`, a whole-library artifact, so nothing could link
against one module until all ~770 were compiled — a dependent paid for the
entire library whatever it imported.

Measured here, not estimated:

| | v0.20.0 | v1.0.0 |
|---|---|---|
| `lake build` in this repo | 2481 jobs | **265** |
| a scaffolded consumer project | 2468 jobs | **252** |

Nothing in `infra` needed changing for it: the toolchain is the same 4.34.0,
no API moved, and a consumer does **not** need `precompileModules := true`
on its own library — checked by scaffolding a project and building it the way
CI does.

A minor bump rather than a patch, even though `infra`'s own Lean API is
untouched. What a consumer builds is part of what a release gives them, and
this changes it by an order of magnitude; a patch number would say "nothing
to think about here", which is the wrong thing to say about a build that goes
from thousands of jobs to hundreds.

## [0.11.1] — 2026-09-20

### Fixed: AWS IAM users read back as carrying no tags at all

The first live run of 0.11.0's new ownership check failed on AWS, and it was
right to:

    [aws] ownership: 1 resource(s) this run created do not read as ours —
    aws/iam/ci-tests-infra-user (not carrying the 'managed-by-infra' tag)

`Iam.Aws'.readOwnership` **double-unwrapped** the `ListUserTags` reply. It
took `root.child "ListUserTagsResult"` and then called
`members … "Tags" "member"` — but `members` unwraps a result element itself,
so the second call looked for a `<member>` inside a `<member>` and always
found nothing. Every other call site in the file passes the response root and
the `…Result` name; this one passed an already-unwrapped element.

So `create` was writing the marker tag perfectly well and `read` could never
see it. Any AWS IAM user this tool created was `foreign`: never adopted,
never deleted as an orphan, and invisible to `discover`.

Pre-existing — introduced with the AWS IAM ownership read, not in 0.11.0,
which only changed the surrounding signature. It survived because nothing
asked: the live sequence records a resource in the ledger as it creates it,
so the adoption loop never queries it; the trimmed stage does not drop the
user, so the orphan recheck never queries it either; and no offline test
could reach an XML body.

The parse is now `tagsOfListUserTags`, a pure function of the parsed XML with
three `#guard`s against a real reply body — including that the marker is
found in it, and that `<Tags/>` reads as no tags rather than as an error.
Checked by restoring the bug and watching the guards fail. That body is a
wire format, not an account, so this could have been tested offline at any
point; the value of the live check was in asking a question nobody had
thought to ask, and the value of the guard is that it need not be asked
live again.

## [0.11.0] — 2026-09-20

A minor bump rather than a patch, for the reason this file's header gives: it
breaks the Lean API. `Backend.ownershipInfo` returns an `Evidence` instead of
`Option (tags × createdAt)`, `ownershipOf` takes one, `Ownership.describe` is
replaced by `describeVerdict`, and several provider `create` functions gained
a `markerValue` parameter. A consumer pinned to `v0.10.1` is unaffected until
it moves the pin.

### Changed: Lean 4.34.0, and `linen` v0.20.0

`lean-toolchain`, the README badge and `docs/tutorial.md`'s scaffold listing
all move from `v4.33.1`, and the `linen` pin moves from `v0.19.1` to
`v0.20.0` — one commit, "Upgrade to Lean 4.34.0", with no API change, which
is why nothing here needed adjusting for it.

Worth pinning down *why* the pin had to move, since it is not what the
failure would have looked like. Lake builds a dependency's **source** with
the root package's toolchain, so `infra` on 4.34.0 against `linen` on 4.33.1
compiled and passed the whole suite — the mismatch was invisible, not
broken. What it actually cost was two first-party repositories disagreeing
about their own pin, which is the state `AGENTS.md` calls out for duplicates
and the same reasoning applies: a divergence nobody has written down is a
divergence that will drift.

`linen`'s three deprecation warnings under 4.34.0 (`if_neg`, `if_true`) are
gone with it, so the build is clean again rather than clean-with-noise.

### Added

- **`iam` works on all three clouds, `policies` included.** `policies` used to
  be documented as "AWS managed-policy ARNs", reported `unknown` on Scaleway
  and refused on write by GCP — so on two clouds out of three a declared
  permission was quietly never granted. It now means *the cloud's own name for
  a set of permissions*, granted at that cloud's natural scope, and all three
  read it back and reconcile it: a managed-policy ARN on AWS, a permission-set
  name scoped to the project on Scaleway (one infra-owned `Policy` per
  application, rules overwritten with `PUT /rules`), a role name on GCP.

  Nothing translates between the three spellings, on purpose. Two refusals
  rather than silent divergence: Scaleway raises if somebody else's policy is
  attached to the same application, and GCP raises on a conditional binding
  — both naming what to do instead, and both still *reporting* the grant so it
  is visible in `plan` rather than hidden.

  GCP's write is the one that needed care, and its three properties are worth
  restating: the policy object is edited with `JsonRead.setField` rather than
  rebuilt (so `etag`, `auditConfigs` and unknown fields survive), the `etag`
  travels back with it (so a concurrent edit fails the call), and conditional
  bindings are never touched.

- **`SecretSource.apiKeyFor` — a credential minted straight into a secret.**
  A cloud API key's secret half is returned once, at creation, and never
  again, so it can be neither declared (it does not exist yet) nor observed
  (observed state is cached and printed). Creating a secret is already
  write-only, so that is where the key is minted: `valueFrom := apiKeyFor
  "my-app"` creates an AWS access key, a Scaleway API key or a GCP
  service-account key for that identity and writes the secret half in.

  The two halves that are *not* secret — `accessKey`, and the `principal` the
  key authenticates as — come back in `SecretsObserved`, reachable from
  `expr!` as `accessKeyOf` and `principalOf`. `SecretsObserved`'s `FromJson`
  is hand-written for this: Lean's derived decoder does not fall back to a
  field's default, so a derived one would fail to load an existing `.infra/`
  cache.

  Create-only, and refused on update rather than re-minted: a second key would
  be as live as the first and referenced by nothing. Deleting the secret
  deletes the key, found through two tags written on the secret beside the
  ownership marker — the only thing still standing when `Backend.delete` is
  handed a bare `Handle`.

  This is what makes Scaleway's Serverless SQL Database declarable at all. It
  has no master user: the PostgreSQL user name is an IAM application's **id**
  and the password is its API secret key. `example/ServerlessSqlIam.lean` is
  the whole fleet — identity, key, database, URL — in one apply, where it used
  to be three `scw` commands and a secret pasted in by hand.

- **A new example and a new self-check.** `lake exe serverless-sql-iam` is
  offline and credential-free like the other three; `checkMintedKey` in the
  offline suite pins the ordering, the teardown order, the create-only
  property and that no value leaks.

- **Live coverage for all of the above.** `test/Live.lean` gains three things,
  and the first is the one that matters:

  - **`assertOwnershipEvidence`**, run after stage 1 on every live leg. Every
    declared resource must report a marker and read as `managed`, or the leg
    fails naming the pair. `Backend.ownershipInfo` is the only question in
    this library whose answer is a fact about a provider's API rather than
    about this code, and the Scaleway tagging claim was wrong for months
    because nothing ever asked a real account. One call per resource, on one
    stage out of five.
  - **`iam.policies` in the AWS ramp**, attached on the way up and detached on
    the way down, with `AWSDenyAll` — the only managed policy that is safe to
    attach to a user in a real account, since it grants nothing. It was the
    last field in the divergence tables that no live leg had ever moved.
  - **`lake test -- <aws|gcp> identity`**, opt-in and run by no CI job: mints
    a real key with `apiKeyFor`, drops *only* the secret, and fails unless the
    key is gone while its identity still stands. That is the assertion worth
    making — deleting the identity would take the key with it on every cloud,
    so a test that dropped both would pass with the back-reference removed
    from the library. It needs `iam:CreateAccessKey` (which this repo's own
    operator policy denies) or `roles/iam.serviceAccountKeyAdmin`, and
    granting either to an identity that runs on every pull request is a
    decision about security posture rather than about coverage.

  `Store.boundary` is now threaded through `runStage` as `liveBoundary`
  (`namePrefix := "ci-tests-infra-"`), so the name rung is load-bearing in the
  live legs rather than only in `Ownership`'s guards — a Scaleway mnq queue
  has no other marker to carry.

  Three numbers in that file's coverage note were also wrong and are now
  counted rather than remembered: it claimed eleven of fourteen kinds and
  "AWS 9, Scaleway 9, GCP 8", while the fleets declare **thirteen of
  fourteen** and 12/12/10. The section listing `scalewayFunction` and
  `awsInstance` as impossible had survived both of them being added.

### Changed

- **Ownership decides for every `(cloud, kind)` pair.** Eight pairs reported
  no evidence at all — plus one within-pair gap, Scaleway's Serverless SQL
  half of `postgres` — which the engine treats as "refuse": never adopted,
  never deleted as an orphan. `Backend.ownershipInfo` now returns an
  `Evidence` rather than `Option (tags × createdAt)`, with three informative
  rungs — real tags, a marker serialised into the object's one writable
  free-text field, and the resource's own name against the new
  `Boundary.namePrefix` — plus `.unreadable`, which grants nothing.
  `docs/coverage.md` has the table of which pair sits where.

  The name rung is opt-in and *verifying*: infra does not rename anything,
  because a fleet key is the cloud-side name. Unset, a name-only resource
  behaves exactly as it did before. An empty prefix claims nothing rather than
  everything.

  Four of the nine had a stated permanent reason and five had none. Of the
  four reasons, **one was simply false**: a Scaleway IAM application has
  always carried `tags`, and the claim had been copied between the code,
  `docs/providers.md` and `docs/coverage.md` until it looked settled. GCP
  service accounts and Scaleway registry namespaces have a `description`,
  which is a marker. Only Scaleway's Serverless SQL Database and its mnq
  queues genuinely have neither. The rule that comes out of this is now in
  `AGENTS.md`.

  The five with no reason at all — `s3Bucket` and `securityGroup` on AWS, and
  `imageRegistry` on all three clouds, which was not mentioned in the dispatch
  at all — now write a marker at create and read it back. The S3 bucket is the
  plainest: the code to tag one already existed for `objectStore` and this
  kind simply never called it.

- **`push` says which rung refused, and how to fix it.** `Ownership.describe`
  is replaced by `describeVerdict`, which takes the evidence: "retag it", "set
  a `namePrefix` and name it accordingly" and "the marker cannot be read here"
  are three different instructions, and the single sentence that covered all
  three named none of them.

### Fixed

- **Two dependency edges existed only by accident of the `Kind` enum.**
  `PostgresSpec.masterPasswordSecret` and `SecretSource.apiKeyFor` name a
  resource rather than referencing it — a reference would name a provider and
  break portability — so `HasDeps` reported no edge, and the order that came
  out was right only because `.iam` precedes `.secrets` precedes `.postgres`
  in the enum and ties break by enumeration order. Reordering the enum would
  have broken both. `Engine.impliedByName` builds the edge from the name and
  the kind it must name, which is all the scheduler needs; an edge to a slot
  no action touches is ignored, so naming an unmanaged identity stays legal.

  It matters most on teardown: an AWS IAM user holding an access key cannot be
  deleted, so the secret that owns the key has to go first.

- **An AWS IAM user holding an access key could not be torn down.**
  `Iam.Aws'.delete` detached policies and called `DeleteUser`, which answers
  `DeleteConflict` while a key exists. It strips access keys too now.

- **`iam:CreateAccessKey` is denied by this repo's own operator policy**, and
  that is correct — it is step three of a privilege escalation the
  `NeverMintUsableCredentials` statement exists to close. The template keeps
  the `Deny`; `docs/permissions.md` gains a section on the narrow way to allow
  it for a fleet that uses `apiKeyFor`, and what allowing it costs. The error
  raised on the 403 names that section, so it reads as the policy working
  rather than as a misconfiguration.

## [0.10.1] — 2026-09-14

### Fixed

- **Scaleway Serverless SQL Database's `endpoint` was a full connection URI**,
  not the bare `host:port` every other backend's `.endpoint` carries and
  `Compose.endpointOf` assumes. A secret composed from it —
  `postgres://user:{secretValueOf pw}@{endpointOf db}/name`, the documented
  pattern — nested a second scheme, path and query inside the first and
  produced a value nothing could parse as a URL, surfacing downstream as
  `sqlx`'s "invalid port number" against the resulting connection string.
  `listRaw` and `create` now strip the scheme, userinfo and path/query before
  the endpoint is ever returned. See `docs/coverage.md`'s "Implemented, never
  exercised" section for the full account; this is the fourth bug this
  product's client has needed since 0.9.1.

## [0.10.0] — 2026-09-11

### Added

- **`docs/permissions.md` — what a credential must be allowed to do**, which
  nothing stated before. The AWS actions each of the ten AWS-capable kinds
  calls, read off the call sites in `Infra/Providers/Kinds/`; why the ownership
  marker costs *two* grants per kind rather than one, and why the missing read
  half is the dangerous one (it fails silently, falling back to the ledger,
  where the missing write half fails loudly at create); and pointers to the
  GCP roles and Scaleway permission sets, which are documents nowhere because
  neither cloud takes a policy document.
- **`docs/aws-operator-policy.json` — that table as an adaptable IAM
  document**, with `ACCOUNT`/`REGION`/`PREFIX` placeholders and one statement
  per kind, so a fleet declaring three kinds keeps three statements. It covers
  `compute` (Lambda) and `postgres` (RDS) too, and says so in the Sids —
  `LambdaNotExercisedByCi`, `RdsNotExercisedByCi` — because neither kind is in
  any live fleet, so those two rows are read from the code and have never been
  checked against a real 403, unlike the other seven.
- `ci/check-aws-policy.py` now grammar-checks both documents rather than one.

### Changed

- `AGENTS.md` now records that `linen` is a first-party sibling rather than a
  third-party dependency, what the test for "belongs in `linen`" is, and that
  pending moves are written down rather than left implicit.


- **`linen` is pinned to `v0.19.1`** (was `v0.16.0` in `lake-manifest.json`;
  `lakefile.lean` said `v0.17.0`, so the two had drifted — the pin had been
  bumped without a `lake update`, and the manifest is what the build reads).
  `lake build`, the offline self-check suite and all four offline examples pass
  against it, and the build is warning-free again: the three deprecation and
  unused-binding warnings `linen` emitted here are fixed upstream in 0.19.0.

  Nothing `infra` calls changed behaviour — 0.18.0 and 0.19.0 both work on
  `Linen.Cloud`, which this project does not import yet. Three things from
  those releases were checked against this repository rather than assumed:

  - **0.19.0's GCP token-exchange bug is not shared here.** `linen`'s
    `exchange` used the key file's `token_uri` as the assertion's `aud` and
    posted to a hardcoded host, so a key file naming another endpoint signed
    for one host and posted to a different one. `Infra/Core/GcpAuth.lean` reads
    `sa.tokenUri` for *both* — the `aud` claim and the POST target — so the two
    agree by construction. It is more permissive about the value than `linen`
    now is: a non-`https` `token_uri` is accepted rather than refused, and a
    query string folds into the path. Neither can leak the assertion, because
    `Infra/Providers/Http.lean` hardcodes `port := 443` and `isSecure := true`,
    so a plaintext `token_uri` is silently upgraded rather than honoured. Worth
    knowing that it coerces instead of refusing; a `token_uri` naming a
    non-standard port would be quietly misrouted.
  - **`System.Keychain` on Linux** no longer truncates a secret at an embedded
    NUL, which `Infra/Core/Credentials.lean` gets for free.
  - **DuckDB links sealed on Linux, and this repository is what found the bug
    in it.** `infra` names no DuckDB flags of its own, but building this
    package fetches DuckDB into `<repo>/.lake/duckdb` and builds `linen`'s
    `liblinenffi.so`, whose link line carries `-lduckdb_sealed` — so an
    earlier draft of this entry, which said DuckDB does not reach here, was
    wrong. On Linux the link failed:

        ld.lld: error: unable to find library -lduckdb_sealed

    `linen` wrote the sealed library to its own `pkg.buildDir/ffi` while the
    `-L` resolved `.lake/build/ffi` against the *working directory*, which for
    a dependency is the consumer's root. The two coincide only when `linen` is
    built standalone — which is every build its own CI does, so v0.17.0,
    v0.18.0 and v0.19.0 all shipped unbuildable for Linux consumers.

    Fixed in `linen` v0.19.1 rather than worked around here: a consumer cannot
    influence the link of a dependency's own target. The pin is v0.19.1.


- **Both AWS policies are now wide per product and narrow per resource** —
  `sqs:*`, `s3:*`, `secretsmanager:*`, `lambda:*`, `rds:*`, `ecr:*`, each
  confined to `PREFIX*` ARNs — instead of an enumerated action list. The
  enumeration protected almost nothing (the prefix is what confines the
  credential) and rotted on every change: `iam:TagUser` was found as a 403 in
  the middle of a live run, and the same audit found four more gaps. Adding a
  kind of an existing product now needs no policy change at all; adding a
  product needs one statement. `lambda` and `rds` are included ahead of any
  fleet declaring them, for the same reason.

  Three carve-outs, all named in the documents. EC2 stays enumerated because
  its resources are ids rather than names, so there is no prefix to scope by
  and the action list is the only limit that exists. `iam:*` on `PREFIX*` users
  is paired with an explicit `Deny` on every action that mints a usable
  credential, because create-user → attach-admin → create-key is a path to
  full admin that the prefix does nothing to stop. And `iam:PassRole` stays
  pinned to one role with an `iam:PassedToService` condition.

- **Recorded what `PowerUserAccess` actually is**, since it is attached to
  `infra-ci` alongside the above: `Allow NotAction: iam:*` on `Resource: "*"`
  — an allow of everything except IAM, not a deny. While it is attached the
  role already holds every non-IAM permission account-wide with no prefix, so
  the scoping in `ci/aws-permissions-policy.json` is inert and only its IAM
  statements grant anything new. `ci/README.md` now says so, and gives the
  detach command, rather than leaving the document looking like the effective
  grant.

- **The CI policy is inline on `infra-ci`, and that is now the only documented
  route.** `ci/README.md` gave the managed spelling and `docs/ci-auth.md` the
  inline one, so the role ended up carrying *both* — a managed policy and an
  inline policy of the same name, one of them a release behind. IAM unions
  their Allows so nothing failed; it just meant no way to tell from the role
  which document was in force. The managed copy and its versions are deleted.
  Inline is the right shape for this one: it is a single role's grant, not
  something to reuse, and inline cannot be attached to a second principal by
  accident.

### Fixed

- **The AWS CI policy did not cover the ownership marker, and the live leg
  failed on it.** `Iam.Aws'.create` writes the marker tag as part of
  `CreateUser`, which AWS authorises as a separate `iam:TagUser` action, and
  the policy granted `iam:CreateUser` alone:

      CREATE aws/iam/ci-tests-infra-user failed: … is not authorized to
      perform: iam:TagUser on resource: …:user/ci-tests-infra-user

  `ci/aws-permissions-policy.json` now grants `iam:TagUser`. Auditing the rest
  of the document against what the AWS leg actually calls turned up three more
  gaps, all from kinds and calls added after it was last written:

  - `iam:ListUserTags` and `sqs:ListQueueTags` — the *read* half of the same
    marker. These fail quietly rather than loudly: `readOwnership` reports
    `none` when its call fails, the engine reads that as "this cloud cannot
    answer" and falls back to the ledger, so the ownership perimeter stops
    being enforced for that kind without saying so.
  - `ec2:RunInstances`, `ec2:TerminateInstances`, `ec2:ModifyInstanceAttribute`,
    `ec2:DescribeInstances`, `ec2:DescribeImages` — the `awsInstance` kind
    joined the live fleet and the policy never followed it.

  The document is the least-privilege alternative to `PowerUserAccess` and is
  documented as "what the live test actually needs", so a stale one is a trap
  rather than a spare.

### Documentation

- `docs/ci-auth.md` no longer inlines a copy of the permissions policy. Its
  copy still described a two-statement, SQS-only role from when the live fleet
  was one kind; the document has eight statements. It points at
  `ci/aws-permissions-policy.json` and `ci/README.md` instead.
- `ci/README.md`'s per-cloud table of live-fleet kinds was missing
  `awsInstance` (and described Scaleway's by difference from a stale AWS row).
  It is now spelled out per cloud, read off the `#guard`s in `test/Live.lean`
  that pin it, and it names the ownership marker's tag permissions as the
  thing that is easy to forget.
- `docs/ci-auth.md` now says that `PowerUserAccess` is not merely broader than
  needed but *insufficient*: it excludes IAM, and the live fleet declares
  `resource iam`, so the least-privilege document has to be attached alongside.

## [0.9.4] — 2026-09-10

### Fixed

- **Ownership was never the only rule deciding "mine".** Both places the
  engine grants ownership of a resource — the adoption loop in `push` and
  `deleteOrphan` in `runStep` — fell back to naming/ledger matching alone for
  any backend that could not yet report tags, which is exactly the naming-only
  rule that let `destroy` cascade-delete an unmanaged sibling container in the
  2026-09-10 incident `AGENTS.md` records. A backend that cannot read tags is
  now refused rather than adopted or deleted-on-the-ledger's-say-so — the
  fleet manages less than it declares until that kind's backend is taught to
  report tags, loudly warned, rather than silently trusting a name. Tag-based
  `readOwnership` was added for every remaining kind across AWS, GCP and
  Scaleway to close that gap, leaving four documented, permanent exceptions
  where the underlying API has no place to put a tag.

### Added

- **A live ownership-perimeter test per cloud** (`lake test -- <aws|scaleway|gcp>
  perimeter`), proving the fix above holds against a real account rather than
  only the offline engine. Each run plants one untagged, unmanaged decoy where
  the fleet's own listing would see it — a container sharing Scaleway's
  managed namespace (whose own delete cascades — the shape of the 2026-09-10
  incident), a secret sharing the account/project on AWS and GCP (the same
  flat namespace every other kind those fleets manage lives in) — then runs
  the fleet's create, two updates and an orphan-deletion pass around it and
  fails unless the decoy is still standing after each. The decoy and the
  managed fleet are both torn down unconditionally, on any outcome.

## [0.9.3] — 2026-09-10

### Changed

- **`linen` is now pinned to a tag, not `main`.** `linen` cuts real releases
  now (`v0.16.0` is current, and matches what `main` already built against),
  so tracking its tip had the same downside `typednotes-infra`'s own comment
  on pinning `infra` already describes: the next breaking change there would
  have arrived here unannounced. `lakefile.lean` now requires `v0.16.0`
  explicitly — a no-op today, since that tag and `main` are the same commit,
  but the point is the next bump becomes a deliberate `lake update linen`
  rather than a silent one.

## [0.9.1] — 2026-09-10

### Fixed

- **Scaleway `postgres` `read`, `list` and `delete` never looked at Serverless
  SQL Database.** All three unconditionally called the classic Managed
  Database (`Rdb`) client, so a fleet declaring a *serverless* `postgres`
  (`minCapacity`/`maxCapacity`, no `instanceClass` — the shape `Fleet.lean`'s
  `secrets-db` example uses) would `create` correctly and then fail the very
  same apply: `push` calls `read` right after `create` to record what it
  made, `Rdb.read` looked for the name among classic instances, found none,
  and raised — surfacing as `CREATE scaleway/postgres/<name> failed: scaleway
  rdb: no instance named '<name>'` even though the database now existed.
  `list` had the matching gap the other direction: a live serverless database
  was invisible to drift/orphan detection, since it never appeared in what
  Scaleway's classic-instance listing returned. `delete` would have failed
  the same way `read` did, the one time a real teardown reached it.

  Fixed by trying both Scaleway products at each of the three call sites
  (`ServerlessSql` first, since it is the shape this backend is more likely
  to have created, falling back to `Rdb`) rather than assuming classic.
  `docs/coverage.md`'s "Implemented, never exercised" entry for Serverless
  SQL Database is updated with what a live account surfaced.

- **Scaleway `postgres.ServerlessSql.create` never sent `version`.** The
  payload carried `name`, `project_id`, `cpu_min` and `cpu_max` only;
  `PostgresSpec.version` was accepted as a parameter but silently ignored.
  Scaleway's create endpoint requires `version` and rejected every request
  without one: `HTTP 400 invalid_arguments: invalid argument(s)` — the next
  failure a live apply hit once the `read`/`list`/`delete` fix above let
  `create` actually be reached and retried. Fixed by sending it, defaulting
  to `"16"` (the only PostgreSQL version this product currently supports)
  when the spec leaves it unset.

- **`Divergent .postgres` force-replaced every serverless Scaleway database,
  on every apply.** `masterUsername` is a required field; Fleet declarations
  always set it, so the target side is never empty. But Scaleway's
  Serverless SQL Database has no root user, so `read` (see above) reports
  `""` for it — the same sentinel `Live.lean` uses elsewhere for "not
  applicable" — and the two were compared unconditionally with
  `.forcesReplace`. The result: the very next apply after the two fixes
  above let `create`+`read` finally succeed once, `plan` proposed replacing
  the database it had just made, and the resulting `REPLACE` hit the same
  `HTTP 400 invalid_arguments` `create` had, this time on the recreate. Left
  unfixed, this would destroy and rebuild the database on every single apply
  forever. Fixed by only comparing `masterUsername` when `instanceClass` is
  set — the same discriminator `Live.lean` already routes `create`/`read` on
  — so a serverless target's inapplicable root user is never compared at
  all.

## [0.9.0] — 2026-09-09

### Changed

- **`Infra.Cli.run` takes the fleet, not three pieces of it.** A declaration
  now elaborates to a value of its own — `myFleet : Infra.Core.Fleet`, holding
  the keys, the plan, the placement and the `forget`s that `myFleet.keys`,
  `myFleet.plan`, `myFleet.regions` and `myFleet.forgets` still name
  individually — and the front end takes that:

      Infra.Cli.run "my-infra" myFleet (accounts := accounts) (args := args)

  **Breaking.** Every call site loses `(regions := …)` and `(forgets := …)`
  and names the fleet instead of its plan; a hand-written fleet builds the
  record itself (`{ keys := …, plan := …, forgets := [] }`, see
  `Infra.Demo.demoFleet`). The three arguments spelled the same fleet's name
  three times, but the reason to bundle them is not brevity: `Plan κ` and
  `Released κ` are indexed by the key family and `Regions` deliberately is
  not, so `run "x" a.plan (regions := b.regions)` compiled and built fleet `a`
  wherever `b` said it lived. There is no second argument to take the other
  half from now.

  `forgets` keeps its no-default guarantee, moved to the field: a hand-written
  `Fleet` that omits it does not elaborate, and a declared one cannot omit it
  because the `fleet` command fills it in.

  `run` also gained `headline`, which titles the default offline self-check —
  the whole of what three of the four examples passed `selfCheck` for, and the
  last place a call site had to name the plan a second time.

### Fixed

- **A refused orphan delete no longer stops a teardown.** Orphans are the one
  part of a work-list with nothing to sort by: a resource whose declaration is
  gone has no spec, and a ledger row holds a name and a region rather than
  references. So the order is now discovered rather than computed — `push`
  holds a refused `deleteOrphan` back ("DependencyViolation: resource is in
  use", on a security group an orphaned instance still holds) and tries it
  again once the rest of the work-list has run, bounded by the number of
  deferred orphans. A round that frees nothing ends the apply with the
  provider's own words, naming the slot, so a refusal that was never about
  ordering is delayed rather than swallowed. Only orphan deletion works this
  way; every other verb has edges, and a failure there still stops the apply
  immediately.

  This was the entry heading `docs/diff-semantics.md`'s ledger, and it is
  deleted from it rather than softened: the references are still not recorded,
  deliberately, and the ordering question they left open is answered.
  `Main.lean`'s `checkOrphanRetry` pins both halves offline. It generalises the
  retry AWS's security-group delete already did for one kind on one cloud, and
  it is the answer `test/Live.lean`'s `sweepPass` has always given to the same
  question.

- **A green live run asks the account, not just the ledger.** The driver's
  end-of-run check compared the ledger against the declaration, and a teardown
  empties both — so anything that emptied the ledger without deleting
  satisfied it, which is how the 0.8.0 placeholder defect went unnoticed on two
  clouds. `liveTeardown` and `liveSequence` now end with `assertAccountClean`:
  the cloud's own listings for `ci-tests-infra-*`, polled through the settle
  window because a delete a cloud has accepted can still be listed for a
  while, and a failure naming everything still standing.

  It is the sweep's walk without the deletes, and it is *the same* walk:
  `forEachDebris` is now the one traversal of "every kind, every region the
  fleet uses, every prefixed name", with the sweep and the audit differing only
  in what they do on finding one — so the audit can never see less than the
  sweep would. `checkAuditListsWithoutDeleting` asserts offline that it deletes
  nothing, scopes by prefix rather than by substring, and reports an empty
  account as clean.

### Changed

- **`Engine.push`'s per-action work — the marker recheck, the ledger and cache
  writes, the log line — is one `runStep`.** It runs from two places now, the
  main pass and the retry rounds, and two copies of "then persist what it did"
  is the shape that let the two spellings of `delete` drift apart.
- **The home page no longer mentions known defects.** The banner said what the
  live sequence found and the coverage section pointed at the ledger; both are
  the report's business, and the page now says what is generally true and links
  to it.

## [0.8.0] — 2026-09-08

**Three convergence and ownership defects the first post-ownership live run
found.** All three had the same shape as far as an operator is concerned — the
fleet does not do what the declaration says — and none of them was visible
offline, because the placeholder backends echo the target back.

### Fixed

- **A teardown could report success while deleting nothing.** `liveFor`
  authenticates exactly `κ.providers` and substitutes
  `Providers.placeholderBackend` for the rest, and a placeholder's `delete`
  returns `()` while its `list` returns `[]` — so an apply against a
  declaration that names no cloud emptied the ledger, touched no account, and
  printed a clean teardown. The live test's last stage was exactly such a
  declaration, and on 2026-09-08 GCP and Scaleway both reported `ok — all 5
  stages` with their whole estate standing; only AWS came out clean, because
  its run failed and the workflow's backstop sweep ran.

  Fixed on both sides. `Backend.unreachable : Option String` says that a
  backend cannot reach its cloud and why; `liveFor` sets it on every
  substitution, and `push` refuses before running any action if the ledger
  holds a row for such a provider. A placeholder used deliberately as a test
  double answers `none`, so the offline suite is unaffected. And
  `Live.emptyStage` now builds the teardown as `Plan.absent κ` over the
  cloud's own key family, so the credentials load in the first place.
  `Main.lean`'s `checkUnreachableRefusal` and a `#guard` on the stage's
  `κ.providers` pin the two halves — neither is visible offline otherwise,
  which is how this survived three rounds of live runs.
- **An unset optional launch field could never converge.**
  `AwsInstanceSpec.subnetId` settles to `""` when the declaration omits it,
  every EC2 instance is in a subnet regardless, and the field is
  `.forcesReplace`: `REPLACE` in every plan for ever, which is what the AWS leg
  of the 2026-09-08 run failed on. `Diverge.divergesIfSet` reads an empty
  target as "I did not choose" rather than "there must be none" and does not
  compare it; a declared subnet is compared exactly as before. `keyName` has
  the same shape and goes through it too. The mirror image of
  `imageId := "latest"` below, and `checkUnsetLaunchField` is its offline
  stand-in.
- **`imageId := "latest"` could never converge.** The word is resolved to a
  real AMI id inside `create`, so the target held `"latest"` while the instance
  reported `ami-…`, on a `.forcesReplace` field: `REPLACE` in every plan for
  ever, and every real `apply` destroying and recreating a healthy instance.
  `Divergent .awsInstance` now treats a target of `"latest"` as matching
  whatever is reported. The consequence is stated where it is decided and in
  `docs/providers.md`: latest *at create time*, not track-latest, so pin an id
  to keep drift detection on the image.
- **The ownership marker was written into a field the diff compares.**
  `objectStore` compares tags as an equal set, so every bucket created since
  the marker landed would have diverged on `tags` for ever — an `update` that
  rewrites the marker and leaves the divergence exactly where it was.
  `Live.withoutMarker` strips it as the tags are read; `Backend.ownershipInfo`
  still sees the raw set, which is a different question.
- **A declared resource that exists without the marker was passed over in
  silence.** Refusing to adopt it is deliberate and stays — a name match is how
  you delete a stranger's bucket — but nothing said so, and nothing else about
  that state is observable: no action, no plan line, no ledger row, and a fleet
  managing less than it declares. `push` now warns per resource, naming the
  verdict (`Ownership.describe`) and the two ways out. `docs/persistence.md`
  has the full note.

### Added

- **A fleet can name itself, in the ownership marker's value.**
  `Boundary.fleetName` is written into the marker by everything a fleet creates
  and required back out of it, so two fleets in one account read each other's
  resources as `foreign` and leave them alone. One field feeds both directions
  — `Infra.Cli.liveFor` stamps it, `ownershipOf` checks it — so a fleet cannot
  claim one name and write another. Opt-in: unset, the value is not read, which
  is exactly the previous behaviour. The marker *key* stays constant on purpose,
  because it is what makes "what did this tool create in this account?"
  answerable, and the legacy value `"true"` matches every fleet permanently so
  that naming a fleet cannot turn an estate tagged before the name existed
  foreign in one step.

  Spelled `fleetName`, not `fleet`: `fleet` is a parser token of the `fleet`
  command, so `{ fleet := … }` does not parse in any file that declares one.
  Third instance of that trap, after `Ledger.Row.cloud` and `Declare.Res`.
- **`lake test -- <cloud> sweep --prefix <p>`** scopes a sweep to one project's
  debris, for an account shared with a fork or a second checkout whose
  resources also look like a test's. Defaults to `ci-tests-infra-`; an empty
  prefix is refused rather than read as "everything". `ci/README.md` is the
  runbook.
- **`checkLatestImage`** in the offline suite, comparing a `"latest"` target
  against a resolved id — the pair a live pull produces — plus `#guard`s on
  `withMarker`/`withoutMarker` in `Infra/Providers/Live.lean`, and a
  captured-stream assertion in `checkOwnershipGate` that the unmanaged-resource
  warning is actually printed. `checkFleetIsolation` covers all four legs of
  the fleet-name scheme, and `checkSweepPrefixScopes` both directions of the
  sweep prefix.

### Changed

- **Every cloud is reachable with a long-lived key from every entry point.**
  AWS and Scaleway always were — a key pair is the first thing their chains
  look for — but GCP's equivalent, a service-account key file, was tried only
  by `Infra.Cli.liveFor`. `Infra.Providers.liveFromEnvironment`, which is what
  a consumer's own code calls, went through `Credentials.load`, and that cannot
  try a key file: minting a token from one needs HTTP, which needs
  `Credentials`. So the same key counted through the CLI and silently did not
  count through the library.

  `GcpAuth.loadWithKeyFile` is now the one place the fourth source is added and
  both front ends call it. The not-found message names all four sources in the
  order they are tried, `Credentials.gcpKeyFileVar` holds the variable's name
  once so a diagnostic cannot name a variable no loader reads, and
  `checkCredentials` asserts both — a source nobody is told about is a source
  nobody can use. `docs/authentication.md` has the per-cloud table.
- **`GcpAuth.tokenFromKeyFile` is back**, and is no longer dead: it is the
  explicit-path entry point — a path that did not come from the environment,
  or a scope other than the default — which the env-var-only `fromKeyFile`
  cannot serve. Both now share `GcpAuth.tokenFor`, the sign-then-exchange pair
  that is all they ever had in common. Removed earlier in this cycle as
  unreferenced, which was the wrong call: it was the general one of the pair.
- **`Regions.coversSlots` is defined from a per-cloud `coversSlotsIn`**, which
  is what `Infra.Cli.liveFor` now calls. The per-slot walk existed twice —
  once in `Region.lean` uncalled, once inlined in `liveFor` — and two docs
  claimed the first was what ran. One definition, and the claim is true.

### Removed

- **Two unreachable declarations**, from a dead-code sweep of every `.lean`
  outside `.lake`: `JsonRead.asString` (`stringArrayField` does that itself)
  and `Credentials.storeInKeychain` (a wrapper for the `infra login`
  `docs/authentication.md` decides against; `storeInKeychainAccount` is the one
  in use).

  Kept, and why, so the next sweep does not re-propose them: `LawfulMerge` is a
  stated law awaiting a proof and is listed as such below; `Core.Auth`'s
  `authorizationUrl`/`openBrowser` are the pieces a future device-grant login
  reuses; `Specs.Build.postgresClassic` is public builder surface with no
  example yet; `Scaleway.Rest.zonalPrefix` is what a zone-scoped product needs;
  the three `describeVersion` implementations are what version-based drift
  detection on `.secrets` would call, and `Infra/Providers/Live.lean` now says
  that instead of claiming `read` supplies a version, which it does not.

### Breaking

- **`Ec2.Instance'.create` and `.update` take the marker value** as a final
  argument, with no default: writing `"true"` by accident produces a resource
  the fleet cannot tell apart from another's, so the compiler asks. Only
  `Infra.Providers.Live` calls them.
- **`Infra.Providers.liveBackend`, `live` and `liveFromEnvironment` take an
  optional `fleet` name**, defaulting to `none` — the previous behaviour. So
  does `Infra.Cli.liveFor`, which `Infra.Cli.run` now feeds from
  `boundary.fleetName`.

`docs/diff-semantics.md` records the general lesson under the perpetual-replace
section, which has now been hit four times in two shapes: the *report* is a
sentinel, or the *target* is not a value the cloud can be asked for. It also
now states the harness property behind all of this — anything the live backend
writes on create that the declaration did not say is invisible to the offline
suite.

## [0.7.0] — 2026-09-07

**The live sequence ramps.** Each cloud now applies five declarations against
one ledger rather than three: the whole fleet, the same fleet scaled *up*, the
same scaled back *down*, a trimmed version, then one that declares nothing.

The two new stages exist to close the hole `docs/coverage.md` has been naming
since the first live run: almost no `update` path had ever been called. Every
field the ramps move is on a `.mutable` row of its kind's divergence table, so
each ramp stage is an `update` rather than a replace, and doing it in both
directions exercises the path each way. Scaleway's container goes from a floor
of zero instances to a floor of one and a ceiling of three, with twice the
memory and twice the timeout, and then back — scaling *down* to a floor of zero
being the direction that costs money if it does not work. Cloud Run goes to a
gigabyte and back. A queue's visibility timeout goes to two minutes and back.
ECR tag immutability goes off and on.

Three guards keep the ramps honest, because a ramp that had rotted into a no-op
would pass every live assertion while testing nothing: each ramp stage must
declare *exactly* what stage 1 declares (same resources, same names, same
graph — only mutable fields move), and each must declare something, so none is
mistaken for a teardown by the brake.

### Documentation

- **How to run the live test is written down**, in `ci/README.md` ("Running the
  live test"): the `gh workflow run live-test.yml -f provider=…` invocation,
  the approval the `production` environment demands, what the driver prints
  while it runs, and the sixty-second gap AWS needs between two runs. Only the
  *cleanup* half of that had a runbook; triggering the thing it cleans up after
  existed as a workflow file and a sentence in `docs/coverage.md` saying it was
  manual. The approval commands now live once and Cleanup points at them.
- **The live step's sizing comment named nine resources**, where stage 1
  declares twelve on AWS and Scaleway and ten on GCP — `#guard`ed in
  `test/Live.lean` since the fleets grew. Corrected in the workflow and quoted
  from the guards in the runbook.
- **The claim that three clouds had passed the sequence is withdrawn**, in
  `docs/coverage.md` and on the page: it was a three-stage claim about a
  five-stage sequence, and the runs that looked like passes were the false
  green above. What each run actually showed is written down instead, and the
  claim to make after the next one is named. `docs/internals.md` gains "Which
  clouds get authenticated, and the hole that leaves"; `docs/diff-semantics.md`
  gains the unset-optional-field shape as the fifth entry in the list of things
  that make a fleet unable to converge.
- **The page's Coverage section is now a link to the coverage report**, and
  nothing else. It held three cards, a stage table and the kind matrices, all
  of which had to be re-edited by hand every time a run changed what was true
  — and two of its claims were stale in exactly that way when this round
  started. Which clouds have passed which stages is a property of the last CI
  run, so it belongs next to the tests, in a file that moves with them. The
  kind matrices are in `docs/coverage.md` too. The dead CSS went with them.

### Breaking

- **`Infra.Cli.run` requires `forgets`** as of 0.6.0, and consumer projects
  need `(forgets := myFleet.forgets)` added. `infra new`'s template does this;
  an existing `Main.lean` does not, and the error names the missing argument.

### Two more kinds go live: thirteen of fourteen

Both were excluded for a stated reason, and both are included now because the
reason was removed rather than waived.

**`awsInstance`.** `imageId := "latest"` resolves the newest Amazon Linux 2023
image in the instance's own region at apply time, through a new
`Ec2.Image.latestAl2023` (`DescribeImages`, filtered to Amazon's own published
naming scheme and `owner-alias = amazon`, newest by `creationDate`). Anything
else is used verbatim, so pinning an id still works. That deleted the excuse —
"a rotting constant in a test whose failure looks like a library bug" — and
also deleted the pinned id from `example/ParisInstances.lean`, which had
carried one with a comment admitting it was unverified.

It is also the one resource in the live fleet with a *required* reference, so
its creation order is forced rather than incidental: the security group first,
and teardown in reverse.

**`scalewayFunction`.** Serverless Functions deploys from an uploaded archive
and takes code no other way, so the declaration carries the code:
`ScalewayFunctionSpec.code` is inline source and `handler` is the entry point.
The backend zips it and deploys it — fetch a presigned URL, PUT the archive,
call deploy. The live fleet's function is a four-line Python handler returning
`Hello, world!`.

Three new pieces made that possible:

- **`Infra.Providers.Zip`** — CRC-32 and a stored-method ZIP writer. No
  compression: method 0 is sufficient for a handler and smaller than the code
  that would deflate one. Deterministic, because the DOS date fields are
  written as zero rather than read from the clock, so an unchanged redeploy
  produces identical bytes. Checked offline against `crc32 "123456789" =
  0xCBF43926` and against the archive's own signature bytes.
- **`Http.requestPresigned`** — a request whose query string is used exactly as
  given. `Http.request` renders queries through `canonicalQuery`, which encodes
  and sorts them; correct when this library signs, and fatal when somebody else
  already did.
- **`code` and `handler` are optional**, not required, and that is deliberate:
  the reported shape shares the structure and Scaleway does not hand source
  back, so a required field would force the backend to report a blank, and a
  blank compared against a real target is a divergence on every pull. `runtime`
  and `namespace'` did exactly that once and made every plan propose a replace.

### Still not covered

`postgres`, on all three clouds: five to fifteen minutes to create and as long
to delete, longer than the workflow step it would run in. It wants its own
opt-in leg with its own timeout, which does not exist yet.

## [0.6.0] — 2026-09-07

**Deleting a resource from a declaration now destroys it.** It used to leave it
running, and that was a defect rather than a design: `Plan.outside` was
declared and never consumed, so a resource whose line you removed had no key
for anything to mention and was silently abandoned, still billing. The minor
bump marks the fix and the API break that comes with it.

### An apply records what it claims, not just what it changed

Worth stating separately because it was the substantive bug in this work, and
because it is the kind that only a live account finds. The ledger originally
learned about a resource through an *action*, so a resource that already
existed and already matched produced none and was never recorded — after which
nothing could destroy it. That is a leak, and it is the commonest case there
is, since it is what every second apply looks like.

An apply now adopts everything the declaration claims and the cloud already
has, before running anything, and persists that before the first mutation.
It also no longer returns early on an empty work-list: having nothing to do and
having something to record are different questions.

Claiming a resource because the declaration names it and it exists is the same
rule the planner already uses to call it converged, so this adds no new
judgement. It is a rule about *names*, which is what `Infra.Core.Ownership`
exists to improve on.

### The mechanism

What a fleet manages is recorded in `Infra.Core.Ledger` — a local file of
`(cloud, kind, name, region)` rows, under `.infra/`, deliberately *not* indexed
by the key family. That last part is the whole trick: `CachedEntry κ` is
indexed by `κ.Key`, so it structurally cannot hold a row for a resource the
current declaration no longer mentions, which is exactly the row that has to
survive for "deleted from the file" to mean "destroy".

`Action` gains `deleteOrphan`, addressed by name and region because there is no
key left to ask, and routed on the region the ledger recorded rather than
through a placement table that by definition no longer names the slot.

`destroy` is now demonstrably the same operation as applying an empty
declaration. `.delete` addresses the resource by name rather than by whatever
handle the world was holding, so it and `deleteOrphan` share one body and end
at one `Backend.delete` call. Two spellings of one delete is the shape that let
`S3BucketSpec.region` disagree with the placement.

### `forget`

To stop managing something without destroying it:

```lean
forget scaleway queues "old-queue"
```

The counterpart of Terraform's `removed { … lifecycle { destroy = false } }`,
and a declaration rather than a command for the reason HashiCorp gives for
preferring theirs over `terraform state rm`: it shows up in a plan before it
happens, and in a diff when it is reviewed.

Four things about it are the type system's job rather than a convention, each
recorded in `Infra/Demo.lean` with the message the compiler actually produces:

- Forgetting something the same fleet still declares does not elaborate
  (`Assert (!claimedByKey …)`, discharged by `decide`).
- One fleet's releases cannot be handed to another: `Released` is indexed by
  the key family.
- A release cannot be built by hand — `Released.mk` is private, so `releasing`
  and its check are the only way to obtain one.
- A fleet that declares a `forget` and does not pass it to `Cli.run` does not
  compile, because `forgets` has no default.

That last one was a real hole and not a hypothetical: `forgets` shipped as a
defaulted parameter that nothing passed, so `forget` compiled, discharged its
check, and then destroyed the resource anyway.

### Breaking

- **`Infra.Cli.run` requires `forgets`.** Pass `myFleet.forgets`; the
  scaffolder's template does. A fleet with no releases passes `[]`.
- **`Plan.outside` is gone.** A single fleet-wide verdict could not close the
  world: closing it requires knowing *which* resources were once managed, and
  a fleet-wide `absent` would have proposed deleting every resource in the
  account.
- `Backends.backendAt` is new; `Store` is indexed by the key family.

### Live tests are a sequence now

Each cloud runs three declarations against one ledger — the whole fleet, a
trimmed version, then one that declares nothing — and after each stage the
account must hold *exactly* what that stage declares. The middle stage is the
one that earns it: it drops two resources, so their lines are gone entirely and
only the ledger knows they exist. If membership still came from the
declaration, they would be silently abandoned and every assertion would still
pass, leaking two billable resources per cloud.

When the final stage fails, the sequence no longer re-runs it as a fallback.
It *is* the teardown, so re-running it issued the same request, failed the same
way, and printed every error twice — the same shape as the workflow backstop
that used to re-run a create after a failed create.

The dependency graph is the same on all three clouds and is no longer just a
fan-out: five secrets forming a fan-out of two, a fan-in of three including a
redundant edge, and a four-deep chain — the shape `Infra/Demo.lean`'s
`dagFleet` already checks offline. The last stage is `apply` against an empty
declaration, which is the half that had never run live.

**All three legs pass.** Every stage, on AWS, Scaleway and GCP: 32 resources
across 11 of the 14 kinds. It took two rounds of failures to get there, both
recorded in `docs/coverage.md` because the second is the kind of bug only a
real account finds — the ledger learned about a resource only through an
*action*, so resources that already existed and already matched were never
recorded, and the teardown then deleted only the ones that had needed doing.

### A cleanup that works between runs

`lake test -- <cloud> sweep`, and `lake test -- all sweep`, delete every
resource named `ci-tests-infra-*` from an account. Unlike `destroy` this asks
the account rather than the ledger, so it needs no local state: it works in a
fresh checkout, and it clears debris an older version of the fleet created,
which `destroy` never could.

`.github/workflows/cleanup.yml` runs it weekly and on demand, one job per
cloud. Each job shares that cloud's concurrency group with the live test, so a
sweep cannot race the run whose resources it would delete, and each job holds
only its own cloud's credentials.

The sweep has no dependency graph to order by, so it repeats until a pass
deletes nothing — which is how a container gets deleted before its namespace
without anything knowing that it must. Both properties are checked offline on
every push: that it deletes debris and *only* debris, and that it retries past
a dependency.

### A probe that was added and removed

Making membership the ledger's business invited answering *existence* per
resource, by name, the way Terraform does. Terraform can, because its providers
implement a per-resource read that returns not-found. This provider layer
cannot: `liveRead`'s `.secrets` clause makes no cloud call at all, and every
`(provider, kind)` pair that is not live yet reports `unknown` fields
*successfully*. Reading that as "it exists" meant a declared secret was never
created.

So existence comes from `list` again — wrong only by omission, which is the
safe direction, and the call this repo has exercised against real accounts for
all fourteen kinds. Membership stays the ledger's. Separating the two questions
was right; answering the second per resource was not.

### Also

- `Infra.Core.Ownership` sketches a marker-and-boundary model meant to replace
  the ledger as the authority on membership, so that nothing has to be written
  back from CI. Nothing writes the marker and nothing reads the boundary yet:
  it decides nothing today, and says so.
- `apply` refuses a plan that would destroy more than half the ledger *while
  still declaring other resources*. HashiCorp deprecated `terraform refresh`
  because misconfigured credentials could make it read every object as deleted
  and destroy them all with no prompt; the same hazard exists wherever an
  observation can mean "gone", and an edited-by-mistake declaration is the
  local version of it.

  The exemption is derived, not passed: a declaration that asks for nothing to
  exist *is* a teardown, and `Plan.declaresAnything` reads that off the target.
  It took a flag at first, so every caller had to remember to set it for a
  teardown — the CLI did, the live-test driver did not, and the first live run
  of the staged sequence created and trimmed correctly on all three clouds and
  then could not delete anything. The brake had fired on the one plan it was
  never meant to question.
- `docs/persistence.md`'s claim that the cache is gitignored because it can
  hold secret values was false and is corrected: `SecretsObserved` is a handle
  and a version, no `ObservedOf` has a value field, and `Backend.read` for
  `.secrets` never fetches one.

## [0.5.0] — 2026-09-06

**All three clouds pass a full live round trip.** That is what the minor bump
marks, and it is the first time the set of kinds that *run* equals the set the
fleets *declare*.

| Cloud | Resources | Kinds |
|---|---|---|
| AWS | 9 | queues, 3 secrets, imageRegistry, objectStore, s3Bucket, securityGroup, iam |
| Scaleway | 9 | queues, 3 secrets, imageRegistry, objectStore, both namespaces, scalewayContainer |
| GCP | 8 | queues, 3 secrets, imageRegistry, objectStore, compute, iam |

Eleven of fourteen kinds, 21 (cloud, kind) pairs. Each leg creates from
nothing, converges, deletes, and verifies the state cache is empty; the
workflow's backstop was skipped on every one, which is the evidence teardown
ran. All three dependency shapes are exercised live — a chain, a fan-out, and
a fan-in through both key and expression references.

### What getting here found

Eleven defects that no offline check could have reached, which is the argument
for having done it. In rough order of severity rather than discovery:

- A **perpetual replace**: a Scaleway container's `namespace` was compared as a
  required field while `read` returned a blank, so a fleet containing one never
  converged. The symptom was a hang, not an error. `scalewayFunction` had it
  too, and both carried a comment asserting the field was excluded from the
  divergence table — it was not.
- **Scaleway listings were organization-wide**, so a fleet could adopt and
  destroy a *different project's* resources. Measured, not theorised.
- **A Cloud Run service silently ran as project Editor**, because
  `executionRole` was unmapped and Cloud Run's default is the compute service
  account.
- **Every AWS secret create was broken** for want of a `ClientRequestToken`
  that the API reference calls optional and every SDK supplies.
- **A Scaleway run minted an SQS credential per API call**, in a delete-and-mint
  loop, because the only cache was a keychain a CI runner does not have.
- **A GCP secret's value could not be read**, so composed secrets failed on a
  kind whose own CRUD was complete.
- **A federated credentials file was read as a service-account key**, so GCP
  auth failed with a valid token in the environment.
- **The live test's settle window counted iterations, not seconds**, and hit the
  step timeout looking like a hang.
- **A Scaleway registry namespace name is region-global** — a leftover blocked
  every later run in any project.
- **An EC2 security group description cannot contain an apostrophe.**
- **A scaffolded project could not link on Linux**, from a drifted copy of the
  link-flag block.

Six checks were added so that most of these classes cannot recur:
`check-lakefile-sync.sh`, `check-site-assets-sync.sh`, `check-aws-policy.py`,
`check-scaleway-scoping.py`, a Secrets Manager token check, and a check that
the SQS credential memo short-circuits.

### Still not covered

`update`, on all three clouds — the live test creates and deletes, so it never
diffs a *changed* target against an existing resource. `postgres`,
`awsInstance` and `scalewayFunction`, each for a reason in
`docs/coverage.md`. And `scalewayContainer.timeoutSec` is never compared,
because Scaleway reports a duration string.

## [0.4.11] — 2026-09-06

### Fixed

- **A Scaleway container and function proposed `REPLACE` for ever, so a fleet
  containing one never converged.** `Divergent` compares their `namespace`
  with `divergesReq … .forcesReplace` — required, so no `unknown` escape —
  while `read` reported it as a blank handle. Target and observed differed on
  every pull, the plan proposed a replace every time, and the live test polled
  until the workflow's step timeout. The symptom was a hang, not an error.

  Both now resolve the namespace id back to the name a fleet keys on. Fixing
  `read` rather than excluding the field is deliberate: a container genuinely
  cannot move namespace, so a *changed* declaration really does need a
  replace, and excluding it would hide a real case to avoid a false one.

  The code carried a comment asserting that `Divergent` excluded the field. It
  did not. `docs/diff-semantics.md` now states the general rule — a required
  field the backend reports as a sentinel is a permanent divergence, and
  `.forcesReplace` on top of that is a permanent replace — and records that
  `S3BucketSpec.region` was the first instance of exactly this.

## [0.4.10] — 2026-09-06

### Fixed

- **The live test's settle window counted iterations, not seconds**, so a
  Scaleway leg hit the workflow's step timeout and was reported as a hang
  having done nothing wrong. `waitFor` decremented `settleSeconds` once per
  loop, and each loop is a whole `pull` — sixteen HTTP calls for the Scaleway
  fleet — plus a one-second sleep. A "180 second" window therefore took
  180 × (pull + 1s), which at three seconds per pull is twelve minutes.

  It measures elapsed wall-clock time now. Both polls use the same window, so
  the worst case is twice it plus create and delete.

- **A long run printed nothing while running.** Progress lines went through
  `IO.println`, and stdout is buffered, so they appeared only when the process
  exited — while stderr notes appeared immediately. A credential warning
  followed by eight minutes of silence is indistinguishable from a hang. They
  flush now, and `waitFor` emits a heartbeat every fifteen seconds naming what
  is still outstanding, because *which* resource has not appeared is the whole
  diagnosis.

- **The step timeout is sized from the driver**, 12 minutes to 16. A timeout
  below the worst case turns a slow-but-working run into a reported failure,
  which leaves resources behind *and* sends the reader hunting a bug that is
  not there.

## [0.4.9] — 2026-09-06

### Fixed

- **A Scaleway registry namespace name is global, and the live test treated it
  as local.** The name *is* the hostname path —
  `rg.fr-par.scw.cloud/<name>` — so it is unique per region across every
  project, which nothing about the kind advertises. A leftover from a failed
  run therefore blocked every later run, in any project, with
  `400 Namespace already exist`: the same permanent-deadlock shape as the SQS
  credential name.

  It carries the uniqueness suffix now, like the buckets, with a guard pinning
  it. AWS's ECR repositories are account-scoped and GCP's Artifact Registry
  repositories are project-scoped, so neither needs it — but "is this name
  global?" is now a question `docs/coverage.md` says to ask of every kind.

## [0.4.8] — 2026-09-06

### Fixed

- **Signed requests did not name themselves in a failure.** Scaleway's
  S3-compatible endpoint refuses with `403 AccessDenied: Access Denied
  (request txgc…)` — no operation, no host, no bucket — which for a
  nine-resource fleet says only that *something* was refused. `Aws.call` is the
  single chokepoint for every signed request in the library, so it now prefixes
  errors with service, method, host, path and query. That covers S3, EC2, SQS,
  ECR, Secrets Manager, IAM, RDS and Lambda, and Scaleway's S3-compatible
  endpoints, which is where the gap was found.

  The REST transports were given the same treatment earlier. `docs/providers.md`
  now records why: the three clouds differ sharply in how much an error says,
  and the difference decides how much diagnostic work each client has to do
  itself.

## [0.4.7] — 2026-09-06

### Fixed

- **A Scaleway run minted an SQS credential per API call.**
  `Sqs.credentialsFor` is reached a few hundred times in one live run — five
  call sites, once per listing, inside a poll loop — and cached only in the OS
  keychain. A CI runner has none, so every call missed; and once `reclaim` made
  a duplicate-name mint *succeed* rather than fail at `409`, each miss deleted
  the previous credential and minted another. One run churned two dozen.

  That was worse than the deadlock reclaiming had replaced: it hammers
  Scaleway's IAM and would eventually be rate-limited. There is now an
  in-process memo keyed by project and region, so a run mints at most once
  whatever the keychain does — and a self-check establishes the memo
  short-circuits, rather than a comment asserting it.

### Documentation

- **CI gets its own Scaleway project.** The live fleet creates and destroys
  real resources, and a credential able to do that in the project holding
  production is a credential worth not having. `ci/README.md` has the commands,
  scoping the policy with `project-ids` rather than `organization-id`.

  With the caveat that a project cannot isolate everything: Scaleway's IAM
  applications live in the *organization*, so the `iam` kind is org-scoped
  whatever project CI uses. Dropping `resource iam` from `scalewayLive` is the
  tightest posture and costs one kind of coverage; `IAMApplicationManager` is
  the narrower grant if you keep it.

- **A policy on the wrong application is indistinguishable from no policy** —
  the 403 names the call, not the identity. Named as a trap, with the two
  commands that check it.

## [0.4.6] — 2026-09-06

### Fixed

- **Fourteen Scaleway listings were not scoped to a project**, which a
  project-scoped CI credential surfaced as `403 permissions_denied` on
  `GET /secret-manager/…/secrets`. A Scaleway collection endpoint without
  `project_id` is evaluated against the whole **organization**.

  The 403 is the mild consequence. The serious one is that an unscoped listing
  returns **other projects' resources**, and `pullEntries` matches a listed
  resource to a fleet key *by name* — so a fleet in one project could adopt a
  same-named resource belonging to another, diff it, and `destroy` it. Measured,
  not theorised: the test organization had two container-registry namespaces in
  a different project, and an unscoped listing saw both.

  `ci/check-scaleway-scoping.py` enforces it now, with two deliberate
  exceptions: `/runtimes` is a catalogue rather than a collection, and IAM
  `/applications` is organization-scoped by nature.

  This is Scaleway-shaped specifically. AWS scopes by the credential's account
  and region implicitly; GCP puts the project in the path, so an unscoped call
  is not even expressible.

## [0.4.5] — 2026-09-06

### Verified

- **GCP's full live leg passes** — 8 resources across 6 kinds: `queues`,
  three `secrets`, `imageRegistry`, `objectStore`, `compute`, `iam`. Created,
  converged, deleted, state cache checked empty, backstop skipped.

  So Pub/Sub, Cloud Storage, Secret Manager, Artifact Registry, Cloud Run and
  IAM service accounts have each answered a real call — six of the seven
  portable kinds on GCP. Only Cloud SQL is untested, because `postgres` cannot
  be in the live fleet.

  `docs/coverage.md`'s ledger for GCP shrinks from "everything except Pub/Sub"
  to "Cloud SQL only". Two of three clouds now pass a full leg; Scaleway is the
  one outstanding, and is waiting on a re-run rather than on a grant.

  Worth recording what the GCP leg cost, because it is the argument for doing
  this at all: three genuine defects, none of which any offline check could
  have found — a federated credentials file read as a service-account key, a
  Cloud Run service silently inheriting an Editor identity, and a secret value
  that could not be read at all.

## [0.4.4] — 2026-09-06

### Fixed

- **A GCP secret's value could not be read**, so composed secrets failed on
  GCP. `Gcp.SecretManager` had list, create, put, delete and describe —
  everything except reading a value, which nothing in the `secrets` kind itself
  needs. What needs it is a *dependency between resources*: a composed secret
  builds its value from another's at settle time. Implemented via the
  `versions/latest:access` sub-resource.

- **`postgres` on GCP had the same gap, in a different file.**
  `Postgres.fetchMasterPassword` was a near-copy of `Secrets.fetchValue`, and
  GCP had been implemented in one and not the other, so a GCP `postgres` would
  have failed identically. It delegates now, and the remaining duplication is
  marked.

  The general point is in `docs/coverage.md`: per-kind CRUD is not the whole
  surface. Cross-resource paths — reading a secret's value, resolving a key
  reference — are separate, are not exercised by a fleet of independent
  resources, and live in files named after a different kind.

## [0.4.3] — 2026-09-06

### Fixed

- **A Cloud Run service could silently run as project Editor.**
  `ComputeSpec.executionRole` was left unmapped on GCP, on the reasoning that
  it is Lambda's concept and Cloud Run's service account is a different one.
  Both name the identity the code runs as, and not sending one is *not*
  neutral: Cloud Run then uses the project's default compute service account,
  which Google grants `roles/editor`. So a declaration that said nothing about
  identity got an Editor on the whole project — the opposite of what leaving a
  field unspoken means everywhere else here, where it means "whatever the
  cloud has, stays". On a create there is no such thing; there is a default,
  and this one is enormous.

  `executionRole` now maps to the service's `serviceAccount`, `read` reports it
  so a declared identity is diffable, and omitting it warns. Found by a live
  run failing with `iam.serviceaccounts.actAs denied` — an error about
  permission that revealed a problem about which identity was being chosen.

### Documentation

- **`iam.serviceAccounts.actAs` is a grant, not a role**, and is not implied by
  `roles/run.admin`. `ci/README.md` has it, along with why the live fleet names
  a runtime identity rather than accepting the default.

## [0.4.2] — 2026-09-06

### Verified

- **AWS's full live leg passes.** Nine resources across seven kinds —
  `queues`, three `secrets`, `imageRegistry`, `objectStore`, `s3Bucket`,
  `securityGroup`, `iam` — created, converged, deleted, with the state cache
  checked empty afterwards. Two of the three dependency patterns were
  exercised for real: the chain and the fan-out.

  `docs/coverage.md`'s "never run" ledger is rewritten rather than amended.
  It listed ECR, Secrets Manager and IAM as never called; all three now create,
  read and delete on every AWS run. What remains on AWS is Lambda and RDS —
  the two kinds the live fleet cannot include.

  The significant remaining hole is now **`update`**, on all three clouds, and
  the live test cannot close it by design: it creates and deletes, so it never
  diffs a *changed* target against an existing resource. That needs a second
  apply with a modified fleet, which is a different test shape.

  Scaleway and GCP still pass for `queues` only; their legs are blocked on
  grants, not code.

## [0.4.1] — 2026-09-06

Everything the first extended live runs found after 0.4.0 was tagged. All of
it is prerequisites and diagnostics rather than the engine — which is the
useful signal: the parts that had never met a real account were the edges, not
the core.

### Fixed

- **An EC2 security group description could not contain an apostrophe**, and
  saying so was left to raw XML. EC2 allows only
  `a-zA-Z0-9. _-:/()#,@[]+=&;{}!$*`, so "created and destroyed by infra's live
  test" was refused. A fleet's descriptions are compile-time constants, so this
  would have failed every apply rather than intermittently. The client
  validates the set and names the offending characters, and the live fleet's
  descriptions are pinned by a guard.

- **The live workflow's backstop re-created what it was meant to remove.**
  `lake test -- <provider>` is a create *and* a destroy, and the comment
  justifying the backstop said "destroy against the same fleet is idempotent"
  — true of destroy, and this was not destroy. A failed leg was followed by a
  second create that failed identically, so the cleanup could leave more behind
  than it removed. The driver takes a `destroy` argument now, sharing one code
  path with the round trip's own teardown rather than being a second
  implementation of the operation where being wrong costs money.

### Documentation

- **Google Cloud needs its APIs enabled**, which is a separate act from
  granting a role to call them — the permission list was complete and the
  calls still failed with `Secret Manager API has not been used in project …
  before or it is disabled`. `ci/README.md` now has the
  `gcloud services enable` line for the seven APIs the live fleet touches, and
  says why `sqladmin` is deliberately absent.

## [0.4.0] — 2026-09-06

A minor bump rather than a patch: GCP stopped being a type-level cloud, and
the way a project is started changed shape.

### Added

- **All seven portable kinds now work on all three clouds.** GCP gained
  `objectStore` (Cloud Storage), `secrets` (Secret Manager), `queues`
  (Pub/Sub topics), `imageRegistry` (Artifact Registry), `compute` (Cloud
  Run), `iam` (service accounts) and `postgres` (Cloud SQL). `grep noGcp` was
  the to-do list; it is empty and the helper is deleted.

  Three of those APIs do not finish the work in the call that starts it, which
  is new here, so `Gcp.Rest` gained two operation pollers — Google has two
  shapes, `longrunning.Operation` with a `done` boolean and Cloud SQL's own
  with a `status` string. Both bounded by fuel rather than `partial`.

  Two limits stated rather than hidden. A serverless `postgres` declaration
  **raises** on GCP: Cloud SQL has no capacity range that scales to a floor,
  and choosing a tier from `minCapacity` would invent a bill nobody wrote
  down. And `iam` **reads** the roles bound to a service account but refuses
  to write them, because granting a role on GCP is a read-modify-write of the
  whole project's IAM policy and getting it wrong removes other identities'
  access — so a declared policy shows in `plan` and is refused at apply with
  the `gcloud` command that would bind it, rather than being silently dropped.

- **`infra init`** turns the directory you are already in into a declaration
  project, so the ordinary flow works: `lake init`, add the dependency,
  `lake exe infra init`. It **converts `lakefile.toml` to `lakefile.lean`**,
  preserving the package name, version, libraries, executables and requires,
  and keeping the original as `lakefile.toml.replaced-by-infra` — the
  conversion is not cosmetic, because the native link flags are computed by
  running `pkg-config` on the build machine and TOML cannot express that.
  A TOML file it does not fully recognise is refused rather than rewritten on
  a guess. `infra new` remains the shortcut that does the `lake init` too.

- **`Catalogue.lean`** in every scaffolded project: all fourteen kinds across
  all three clouds, **compiled and never applied**. Commented-out examples
  rot; these are type-checked by the user's own build against the version of
  `infra` they depend on.

- **CI for five systems** in a scaffolded project — GitHub Actions, GitLab CI,
  CircleCI, Azure Pipelines and Jenkins — each using the approval mechanism
  its host actually gates on, because an approval that does not gate is
  decorative.

- **The live round trip now declares eleven of the fourteen kinds** — 22
  (cloud, kind) pairs, eight to ten resources per leg — each created from
  nothing, checked, and deleted.

  It also has **shape**, not just size: a chain (a secret composed from
  another's value), a fan-out (two secrets from one base), and a fan-in
  (Scaleway's container depending on its namespace by key reference *and* on a
  secret through `secretEnv`). Ordering is the part of the engine most likely
  to be wrong in a way only a real cloud reveals, and each pattern fails
  differently when the schedule is wrong. All three are pinned offline by
  guards on the create order, negative ones included.

  What has actually *run* is still `queues` on all three clouds. The
  seven-kind legs are blocked on permissions neither CI identity holds, and
  `docs/coverage.md` keeps those two facts apart rather than counting code
  that has not executed.

  Three kinds remain excluded, listed in `docs/coverage.md`:
  `scalewayFunction` needs deployable code rather than an image;
  `awsInstance` needs a stale-prone AMI id and bills by the second;
  `postgres` takes longer to create than the workflow's step timeout.
  `compute` and `scalewayContainer` came *in* once a public image was allowed
  — Cloud Run and Serverless Containers both pull one, so nothing has to be
  built first. Lambda still cannot, needing an ECR image in-account.

  Buckets are included for the first time. Their names are unique across a
  whole cloud and a fleet's names are compile-time constants, which is why they
  were excluded before; a fixed random suffix resolves it, at the stated cost
  that a fork must change it to avoid colliding.

  This needs permissions neither CI identity had — AWS's role was scoped to
  SQS alone, GCP's service account holds only `roles/pubsub.editor`.
  `ci/README.md` now gives the CLI commands per cloud, and
  `ci/aws-permissions-policy.json` is the extended policy.

- **Scaleway Serverless SQL Database** is implemented, where it used to be a
  stub that raised. `postgres` with capacity bounds and no instance class now
  works on Scaleway — endpoint family confirmed against the live API, field
  names from Scaleway's own CLI reference. A Serverless SQL Database has no
  root user, so `masterUsername` and `masterPasswordSecret` have no
  counterpart and are ignored rather than sent.

- **Discovery metadata**: repository topics, canonical URL, Open Graph, a
  Twitter card, JSON-LD, and a real 1200x630 social card rendered from the
  project's own mark.

- **The vendors' real AWS, Google Cloud and Scaleway marks** on the page,
  installed unmodified, with provenance and trademark status recorded in
  `assets/providers/SOURCES.md`.

### Fixed

- **AWS Secrets Manager rejected every `create`.** `CreateSecret` and
  `PutSecretValue` require a `ClientRequestToken`; the API reference calls it
  optional, which it is through an SDK, because every SDK generates one when
  the caller omits it. This library does not use an SDK. Found by the first
  live AWS secret — nothing offline distinguishes a field an SDK supplies from
  one the service defaults — and now covered by an offline check on the
  token's shape and freshness.

- **Scaleway failures did not say which call failed.** Its error bodies are
  the terse ones of the three clouds: a refused request reports
  `403 permissions_denied: insufficient permissions` and nothing else, no
  product, operation or resource, which across a ten-resource fleet is a
  needle in a haystack. Its calls now name the method and path.

- **A scaffolded project could not link on Linux.** `Infra/Cli/New.lean`
  embeds a copy of this repo's native link-flag block, and it had drifted: it
  had lost `pkgAbsoluteLibs` and gained OpenSSL flags, which are the two
  things the canonical block's comments exist to prevent. Every project the
  scaffolder ever produced failed to link on the platform its own generated CI
  runs on. Now a verbatim copy between markers, with
  `ci/check-lakefile-sync.sh` failing the build on any divergence and a CI step
  that scaffolds a project and builds it.

- **`objectStore` on GCP was signed with SigV4** and sent to
  `storage.googleapis.com`. It had no GCP branch at all and borrowed the S3
  client; GCS's S3-compatible API needs HMAC keys, which this library never
  holds, so it could only ever have returned 403. The same defect `queues` had.

- **Google's errors rendered with an empty message.** Its error body nests one
  level deeper than either other cloud (`{"error":{"message":…}}`), so every
  GCP failure read as `HTTP 404 :` with the only useful part dropped.

- **A federated credentials file was read as a service-account key.**
  `google-github-actions/auth` points `GOOGLE_APPLICATION_CREDENTIALS` at the
  `external_account` file that Workload Identity Federation writes, so the key
  path fired, threw on the type, and never reached the access token sitting in
  the environment. Such a file now declines rather than failing.

- **Scaleway queues could deadlock permanently.** The SQS credential's secret
  is shown once and the mint call rejects a duplicate name, so one uncaptured
  mint took the name and every later attempt failed with `409` forever. The
  name is now reclaimed. Also: caching that credential no longer fails the
  operation it optimises, and an already-activated project answers activation
  with `409`, not `200`.

- **Page legibility.** A contrast audit in both colour schemes reported 20
  failures in light and 27 in dark; all are fixed. Blue-as-text and
  blue-as-fill were one token doing two jobs and are now two.

- **The published site's assets could drift from their source**, and did — a
  `<picture>` source pointed at a file present only on the source side, and a
  matching `<source>` that 404s does not fall back to its `<img>`, so dark mode
  would have shown broken images with every local check passing.
  `ci/check-site-assets-sync.sh` now resolves every reference against the
  published tree.

- **The scaffold CI step was macOS-broken**, using GNU `sed -i`, and rebuilt
  the whole of `linen` a second time — killed by the OOM killer locally.

### Changed

- **The cloud strip shows supported clouds only.** Planned ones were listed
  greyed, which made a landing page carry a roadmap, and a roadmap reads as a
  promise.
- **Provider marks are no longer boxed.** Dark mode sets the row on one light
  band rather than recolouring artwork, which their guidelines forbid.

## [0.3.5] — 2026-09-06

### Fixed

- **A pull aborted if a resource vanished between `list` and `read`.** Every
  cloud's list API is eventually consistent, so a refresh moments after a
  delete sees the deleted resource listed and then fails to read it — which
  took down the whole pull rather than reporting the resource as gone. The
  same happens when anything is deleted out of band mid-refresh. A read that
  fails with a recognised not-found code is now treated as absence; anything
  else, notably a permission error, still fails, because mistaking *denied*
  for *absent* would have the next apply create a duplicate. Found by the
  first live AWS run that got far enough to try.

### Added

- **`AWS_ROLE_ARN` is trimmed** and read from either a variable or a secret;
  a missing one now fails with a message naming the setting.
- **The workflow prints its own OIDC claims** before assuming a role, since
  `Not authorized to perform sts:AssumeRoleWithWebIdentity` names neither the
  claim nor the condition that rejected it.
- Trust policies use **immutable subject claims** (`owner@id/repo@id`), which
  is what GitHub issues for repositories created after 15 July 2026.

## [0.3.4] — 2026-09-05

### Added

- **`infra gcp-check <key.json>`** — verifies a service-account key by
  actually using it: parse, sign, exchange. Prints neither the key nor the
  token. The GCP key path is now confirmed working end to end against a real
  service account, including the credential chain reading
  `GOOGLE_APPLICATION_CREDENTIALS`.
- **The live workflow declares `environment: production`**, which is what
  makes the AWS role's environment-pinned trust policy usable — and where
  required reviewers go, so assuming a `PowerUserAccess` role needs a human.
  Adding the reviewers is a repository setting and the one part neither the
  workflow nor the policy can do for itself.
- **ASCII diagrams of both federation flows** in `docs/ci-auth.md`, because
  the difference between them is where the checks live and that does not
  survive prose: AWS puts both narrowings on the role's trust policy in one
  hop; GCP splits them across a provider condition and a service account's own
  IAM policy, in two.
- **`docs/ci-auth.md` and `ci/`** — the AWS OIDC role, its trust policy and its
  permissions policy, as runnable documents rather than prose, alongside the
  GCP commands. Both clouds now federate; neither stores a key.

- **GCP Workload Identity Federation** is set up and wired into the live
  workflow: `google-github-actions/auth@v2` exchanges GitHub's OIDC token for
  a short-lived one, so neither AWS nor GCP has a stored credential any more.

### Fixed

- **The live test read a cloud's listing once, immediately after writing.**
  Every list API here is eventually consistent — SQS's `ListQueues`
  explicitly so — so the first real AWS run reported "did not converge" for a
  queue that had almost certainly been created and was simply not visible yet.
  Worse, the teardown that followed found nothing to delete and reported
  success, so a real resource could have been left behind while the job
  claimed to be clean. Both directions now poll for up to 60 seconds.
  Confirmed after the fact: the queue was still in `eu-west-1`.
- **Documented AWS's sixty-second window.** SQS refuses to recreate a queue
  deleted less than a minute earlier, and a fleet's names are fixed at compile
  time, so the live test cannot dodge it with a unique name. Back-to-back AWS
  runs inside that window fail on create; the workflow's `concurrency` group
  prevents overlap but not proximity.

## [0.3.3] — 2026-09-05

### Added

- **GCP service-account key files.** `GOOGLE_APPLICATION_CREDENTIALS` is now
  the first GCP credential source: `Infra.Core.GcpAuth` reads the key, builds
  an RFC 7523 assertion, signs it RS256 and exchanges it for an access token,
  with no `gcloud` in the picture. **Requires linen ≥ 0.13.0**, which is where
  the RSA signing came from — this is what that addition was for.
- **AWS OIDC in CI.** The live-test workflow federates a role instead of
  storing a key, so there is no long-lived AWS secret in the repository at
  all. Needs a repository *variable* `AWS_ROLE_ARN` — not a secret.
- `docs/authentication.md` now has a table of which method belongs where, and
  says plainly why browser login is not implemented for any of the three.

## [0.3.2] — 2026-09-05

### Added

- **`infra new <dir>`** scaffolds a declaration repository: the canonical
  structure, a commented example fleet that compiles, a `.gitignore` that
  excludes the state cache, a README, and CI for **both GitHub and GitLab**
  with the plan/apply split already wired. It wraps `lake init` rather than
  reimplementing toolchain pinning, and it emits the platform link-flag block
  every consumer needs — which Lake cannot propagate from a dependency and
  which is the most annoying part of starting one of these by hand.

### Fixed

- **`certificate verify failed` on every live CI call.** Lean's toolchain
  bundles a static OpenSSL whose compile-time trust-store path does not exist
  on a runner. `SSL_CERT_FILE`/`SSL_CERT_DIR` are now set in the live-test
  workflow *and* in every workflow `infra new` generates. Found by the AWS
  live test on its first real run.

## [0.3.1] — 2026-09-05

### Fixed

- **The observed-state cache was never cleaned.** `Persistence.save` wrote
  only the `(provider, kind)` pairs that had rows and never removed the file
  of a pair that had become empty, so after a `destroy` the cache went on
  listing every resource that had just been deleted — indefinitely, since
  nothing ever wrote that path again. No plan was affected: `load` has no
  callers and the engine plans from a fresh `pull`. What it damaged was the
  cache's value as a record, and it was believed. `Main.lean` now checks that
  saving nothing loads back nothing, and the live test asserts the same after
  a real teardown.

## [0.3.0] — 2026-09-05

### Added

- **GCP as a third cloud**, at the type level. Resources can be declared,
  placed, referenced, scheduled, diffed and exported to HCL for GCP today.
  There is **no live client**: every backend branch raises rather than
  returning an empty list, because an empty list would claim nothing exists
  there and the engine would propose creating a fleet it cannot create.
  `grep noGcp` is the to-do list.
- **A GCP credential source.** GCP is the first cloud here that does not sign
  its requests, so `Credentials` gains an `accessToken`, and the chain gains a
  row that shells out to `gcloud auth print-access-token`, then the keychain,
  then `GOOGLE_OAUTH_ACCESS_TOKEN`. The token expires within the hour and a
  long apply can outlive one; that is written down rather than discovered.
- **20 GCP regions**, checked against Google's own location lists. Four
  apparent matches are deliberately absent because they are traps:
  `europe-west1` is Belgium not Ireland, `europe-west4` is Eemshaven not
  Amsterdam, `europe-southwest1` is Madrid where AWS's Spain is Aragón, and
  `northamerica-northeast1` is Montréal where AWS names only "Canada
  (Central)".
- **Terraform / OpenTofu interoperability, both directions**
  (`Infra/Interop/Terraform.lean`). `toHcl` writes `.tf` from a fleet, with
  real HCL references where the fleet has references and a per-resource
  `region` from the placement; `fleetOfState` reads `terraform show -json`
  back into a fleet declaration. Neither is a round trip and both say so.
- **A test driver** (`lake test`), offline by default. `lake test -- aws`
  (or `scaleway`, `gcp`) creates one real queue, checks the fleet converged,
  and deletes it again — with teardown guaranteed even when the assertions
  fail, and a teardown failure reported *alongside* the original rather than
  replacing it. Everything it creates is named `ci-tests-infra-…`.
- **A manually-triggered live workflow**, one cloud at a time
  (`.github/workflows/live-test.yml`), plus a backstop teardown if the driver
  dies between create and delete.
- **A landing page** (`site/`, deployed to GitHub Pages), a logo, and
  `docs/branding.md` recording the trademark constraints behind both.
- **`docs/tutorial.md`** — a path from an empty directory to a two-cloud
  fleet. Every snippet in it is compiled.
- **`docs/coverage.md`** — the canonical statement of what this version does
  and how far each part has been run.

### Changed

- **Deletions are now topologically sorted**, not merely reversed. Teardown
  is the reverse of a topological sort of the same graph, so it no longer
  depends on `Kind` enum order or declaration order happening to agree with
  the dependency direction. `orderActions` takes the plan to read deletion
  edges from as a third argument, because `Plan.absent` carries no specs.
- **`instanceType` is a family and a size**, not a string. The pair is checked
  at elaboration: `t3` has no `32xlarge`, and gen-7 Intel skips `32xlarge`
  entirely.
- Package metadata (`description`, `keywords`, `homepage`, `license`) is now
  declared, so Reservoir has something to show.

### Removed

- **`S3BucketSpec.region`.** It did not place the bucket — the placement did —
  so it was only ever compared, on a `forcesReplace` row, and a bucket
  declared without it filled to `eu-west-1` and proposed a replacement that
  recreated it exactly where it already was. It never converged. Placement is
  now the single mechanism and the disagreement is unrepresentable.
  `S3BucketObserved.region` survives, which is Terraform's `bucket_region`.

### Fixed

- **A nested-block scoping bug**: region blocks had a greedy item list, so
  `in oregon where` silently swallowed the `provider` group that followed it.
  Indentation is now load-bearing (`withPosition`/`colGt`).
- **`Regions.set` discarded per-resource placements** made before it.
- **A false claim in the documentation.** The README, the page and
  `coverage.md` said no AWS call had ever been made against a real account.
  That was inferred from `providers.md` listing only Scaleway as verified, and
  it was wrong — the `.infra/` cache held real S3 URLs, a real security group
  and two running EC2 instances. EC2's parameter names, described here as
  unverified guesses, in fact work.

## [0.2.0] — 2026-09-05

### Added

- **A fleet can say where it is.** `fleet myFleet in paris where …` places
  every cloud the fleet uses; `in aws "eu-west-1", scaleway "fr-par"` places
  them individually. A `Locality` is a place named before any cloud names it,
  so one word resolves per cloud.
- **Per-resource placement**, with `provider` and `in` blocks that nest and
  scope like a `with` in Python. Precedence is innermost-first, and the set of
  regions a pull must list is derived from the declaration rather than
  configured.
- Typed region codes (`Region.of`), checked against a per-cloud table, with
  `Region.raw` as the deliberately more visible escape hatch.
- `provider` blocks, so a fleet mostly in one cloud names it once.

### Changed

- `Infra.Cli.run` takes a `regions` argument; a placed cloud no longer needs a
  region in its credentials.

## [0.1.0]

The engine: `Kind`/`SpecOf`/`Plan`/`push`, the `fleet` command, portable and
provider-local kinds across AWS and Scaleway, composed secrets, the credential
chain, the account guard, and the observed-state cache.
