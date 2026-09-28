# TODO

Suggestions from the linen v1.6.1 dependency review (2026-09-28), which moved
infra from linen v1.0.0 to v1.6.1. None of the linen modules infra imports
changed in that range, and `lake build` / `lake test` pass on macOS. Each item
names where it comes from; re-check before acting.

Pending moves into linen are tracked in `CHANGELOG.md` under `[Unreleased]`
(see `AGENTS.md`, "## Linen"); this file is the wider list, and items that
become moves should be recorded there too.

## After the bump

- [ ] **Pin Linux CI runners to `ubuntu-24.04`.** Since linen 1.2.0 every
  linking build on Linux compiles `duckdb_glibc_compat.c` and runs linen's
  sealed-DuckDB audit (it shells out to `nm`), which fails loudly if a newer
  runner's libstdc++ needs a glibc symbol linen does not shim. It has only been
  measured on ubuntu-24.04; infra's workflows use `ubuntu-latest`. linen pinned
  its own runners for this reason. (XS)
- [ ] **Fix the stale `[Unreleased]` notes.** `fromUTF8!` has six uses, not two
  (`Providers/Http.lean:158,161`, `Kinds/Secrets.lean:142,167`,
  `Kinds/Postgres.lean:78`, `Gcp/Iam.lean:366`), and the `Scaleway/Sqs.lean:206`
  reference now lands on a doc comment. (XS)

## Duplicates of linen

- [ ] **`JsonRead.field`** (`Infra/Providers/JsonRead.lean:22`) is
  `Data.Json.Value.lookup` (`linen/Linen/Data/Json/Types.lean:63`). (XS)
- [ ] **`JsonRead.setField`** (`JsonRead.lean:79`, already a pending move):
  liaison has its own (`liaison/Liaison/Egress/Credential.lean:214`), so two
  siblings need it — move it into linen's `Data.Json` and delete both. The
  lenient `stringField`/`natField`/`boolField` could go with it. (S)
- [ ] **The `Linen.Cloud` migration** is still blocked on one thing: linen's
  `Cloud.Error.Class.denied` is a single case (`linen/Linen/Cloud/Error.lean:82`),
  where infra needs refused / not authenticated / service off. Upstream that
  split first (M), then migrate in steps:
  - `Core/Credentials.lean`, `Core/GcpAuth.lean` → `Cloud.Credentials(.Gcp)`.
    linen's is stricter: it refuses an `http://` `token_uri` (infra rewrites it
    to https, `GcpAuth.lean:167`) and one with a query string.
  - `Providers/Http.lean:110-161`, `Aws/Sign.lean` → `Cloud.Transport`/`Cloud.Auth`.
  - `Gcp/Storage.lean:56`, `Gcp/PubSub.lean:68` stop at 50 pages with a warning;
    `Cloud.Page` records whether a listing was truncated. (L overall)
- [ ] **Terminal colour.** `Infra/Core/Ansi.lean` overlaps
  `linen/Linen/System/Console/Ansi.lean`; linen lacks `dim`, the `style` switch
  and `wanted` (`NO_COLOR`/`FORCE_COLOR`/tty). Move those into linen;
  typednotes-compiler reads `NO_COLOR` too. (S)

## Workarounds that linen could remove

- [ ] **The native link-flag block** (`lakefile.lean:29-144`, mirrored in
  `Infra/Cli/New.lean:90-205` and kept in sync by `ci/check-lakefile-sync.sh`)
  is copied in six repos. Lake 4.34 only links an executable with its own
  package's flags (`Lake/Config/LeanExe.lean:103`), so linen cannot fix it
  alone: ask linen for a versioned canonical snippet (consumers diff against
  it), or propose the Lake change. (M, coordination)
- [ ] **CA bundles in scaffolds** (`Infra/Cli/New.lean:376,436,505,568,634,719`)
  exist because linen's TLS only uses OpenSSL's compiled-in default paths
  (`linen/ffi/tls.c:553`). A fallback in linen would drop them.

## Watch

- [ ] **JSON number precision.** linen's `Data.Json.Encode` writes non-integer
  numbers with 6 significant digits. The GCP IAM read-modify-write
  (`Gcp/Iam.lean:204`) re-encodes whole policies — safe only while every number
  in them is an integer.
