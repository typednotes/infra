import Lake
open System Lake DSL

/-
  Build configuration.

  This was `lakefile.toml` until `infra` started using Linen's FFI-backed
  features (`System.Keychain` for credentials, and OpenSSL-backed TLS/SigV4 for
  the provider clients). Lake does **not** propagate a dependency's
  `moreLinkArgs` to a dependent's executable: `liblinenffi.a` is on the link
  line, but the flags its members need are not, so `keychain.o` fails to link
  with undefined `SecItemCopyMatching`/`CFRelease`. TOML has no way to express
  the platform-conditional flags that fixes, hence Lean.

  Only the flags for the FFI `infra` actually reaches are declared. A static
  archive contributes only the members whose symbols are referenced — DuckDB
  stays out for that reason — but libpq no longer does: the
  `postgresMigrations` backend talks the Postgres wire protocol through
  `Linen.Database.SQL`, so `linen_pg_*` symbols are now on the link line of
  every executable that reaches `Infra.Cli`, and every consumer needs
  `libpq`/`pkg-config` installed wherever it builds (CI already installs
  `libpq-dev`/`brew install libpq` — see the workflows, and
  `docs/migrations.md`'s "What it costs").

  Resolution happens at lakefile-elaboration time on the build machine, so
  nothing is hardcoded to one developer's paths.
-/

-- ⟪native-link-flags:begin⟫ — mirrored verbatim into `Infra/Cli/New.lean`.
-- `ci/check-lakefile-sync.sh` fails the build if the two ever differ.
-- The helpers are linen's canonical block (`ci/consumer/link-helpers.lean` at
-- the pinned tag), pasted between its own markers and checked against it by
-- `ci/check-lakefile-sync.sh`; which libraries to name is decided below.
-- ⟪linen-link-helpers:begin⟫
-- The link-flag helpers every executable that requires `linen` needs.
-- Canonical copy: `ci/consumer/link-helpers.lean` in `typednotes/linen`, at
-- the tag the consumer pins. Paste this block, markers included, into the
-- consumer's `lakefile.lean` above its own `run_cmd`, and check it with
-- `ci/consumer/check-link-helpers.sh lakefile.lean` (from the pinned linen
-- checkout, usually `.lake/packages/linen`).
--
-- Why a copy at all: Lake links an executable with its own package's
-- `moreLinkArgs` only (Lean 4.34, `Lake/Config/LeanExe.lean`), so a
-- dependency cannot hand these to a consumer. The block is helpers only —
-- which libraries to name is the consumer's choice, in its own `run_cmd`.

/-- Ask `pkg-config` for a package's flags, split on whitespace, degrading to
    `#[]` when `pkg-config` or the package is missing — matching how `linen`
    treats optional native dependencies. -/
def pkgConfigFlags (args : Array String) : IO (Array String) := do
  try
    let out ← IO.Process.output { cmd := "pkg-config", args }
    if out.exitCode != 0 then return #[]
    -- Whitespace folded to spaces with a `Char` predicate rather than a
    -- `replace` of escape sequences: this block is also embedded in string
    -- literals (a scaffolder's copy), and a backslash does not survive that.
    let normalized := out.stdout.map fun c => if c.isWhitespace then ' ' else c
    return (normalized.splitOn " ").filter (· != "") |>.toArray
  catch _ => return #[]

/-- Link flags naming each library file outright, rather than adding its
    directory to the search path.

    On Linux, `pkg-config --variable=libdir` is typically
    `/usr/lib/<multiarch>`, which holds the *system* `libc.so`. Passing that as
    `-L` makes `ld.lld` prefer the system glibc over the one Lean bundles, and
    Lean's `Scrt1.o` references `__libc_csu_init` — removed in glibc 2.34 — so
    an executable fails to link with an undefined symbol in the C runtime.
    Naming the file shadows nothing: `.dylib` on macOS (a Homebrew libpq is
    `libpq.dylib`), `.so` on Linux, falling back to `-lfoo` when the file is
    absent. -/
def pkgAbsoluteLibs (pkg : String) : IO (Array String) := do
  let libs ← pkgConfigFlags #["--libs", pkg]
  let dirs ← pkgConfigFlags #["--variable=libdir", pkg]
  let dir : Option String := (dirs.filter (· != ""))[0]?
  let ext := if System.Platform.isOSX then "dylib" else "so"
  let mut out : Array String := #[]
  for tok in libs do
    if tok.startsWith "-L" then
      continue                                  -- deliberately dropped
    else if tok.startsWith "-l" then
      let name := (tok.drop 2).toString
      match dir with
      | some d =>
        let c : System.FilePath := (d : System.FilePath) / s!"lib{name}.{ext}"
        if ← c.pathExists then out := out.push c.toString else out := out.push tok
      | none => out := out.push tok
    else
      out := out.push tok
  return out

/-- The active macOS SDK's framework and library search paths. Lean ships its
    own `lld`, which has no default framework path, so these are required for
    `-framework` to resolve. `#[]` off macOS. -/
def macSdkArgs : IO (Array String) := do
  try
    let out ← IO.Process.output { cmd := "xcrun", args := #["--show-sdk-path"] }
    if out.exitCode != 0 then return #[]
    let sdk := out.stdout.trimAscii.copy
    if sdk.isEmpty then return #[]
    return #["-F", sdk ++ "/System/Library/Frameworks", "-L", sdk ++ "/usr/lib"]
  catch _ => return #[]

/-- What `System.Keychain` needs: Security.framework on macOS, the Windows
    credential API, libsecret elsewhere. -/
def keychainLinkArgs : IO (Array String) := do
  if System.Platform.isOSX then
    return (← macSdkArgs) ++ #["-framework", "Security", "-framework", "CoreFoundation"]
  else if System.Platform.isWindows then
    return #["-ladvapi32", "-lcredui"]
  else
    pkgAbsoluteLibs "libsecret-1"

-- OpenSSL is deliberately absent: Lean ends every executable link with its
-- own static `libssl.a`/`libcrypto.a`, and naming a distro's `libssl.so` as
-- well fails the link on glibc symbols Lean's bundled glibc predates.
-- ⟪linen-link-helpers:end⟫

open Lean Elab Command in
run_cmd do
  let mkDef (n : Name) (flags : Array String) : CommandElabM Unit := do
    let lits : Array (TSyntax `term) := flags.map (fun s => quote s)
    elabCommand (← `(def $(mkIdent n) : Array String := #[$lits,*]))
  -- `System.Keychain`: Security.framework on macOS, libsecret on Linux.
  let keychain : Array String ← keychainLinkArgs
  -- `Database.SQL`'s libpq. Absolute-path form on Linux for the same reason
  -- the comment on `pkgAbsoluteLibs` gives: an `-L` to the system libdir
  -- lets the distro's glibc shadow Lean's bundled one.
  let libpq : Array String ← pkgAbsoluteLibs "libpq"
  -- OpenSSL is deliberately absent, though `jose.o` and `tls.o` both reference
  -- it. Lean already ends every executable link with its own
  -- `LEANC_INTERNAL_LINKER_FLAGS`:
  --
  --     -L <toolchain>/lib … -lgmp -luv -lssl -lcrypto
  --
  -- which resolves against the *static* `libssl.a`/`libcrypto.a` the release
  -- toolchain bundles (`script/prepare-llvm-linux.sh`: `cp $OPENSSL/lib/libssl.a
  -- $OPENSSL/lib/libcrypto.a stage1/lib/`). Those archives are already the
  -- last thing on the line, which is exactly where an archive has to sit to
  -- satisfy `liblinenffi.a` above it.
  --
  -- Naming the system OpenSSL as well is not merely redundant on Linux, it is
  -- fatal. A current distro's `libssl.so`/`libcrypto.so` need
  -- `stat@GLIBC_2.33`, `dlopen@GLIBC_2.34` and `__isoc23_strtol@GLIBC_2.38`,
  -- while the glibc Lean bundles under `lib/glibc` predates all three — it
  -- still has the `__libc_csu_init` that glibc 2.34 removed. Under lld's
  -- default `--no-allow-shlib-undefined` that is an immediate link failure on
  -- eighteen symbols no code here can reach.
  --
  -- Dropping it retires the macOS hazard too: the reason to point at
  -- Homebrew's OpenSSL was that dyld could otherwise bind to the system's
  -- incompatible `libboringssl` and crash on the first TLS call. A static
  -- archive cannot be re-bound at runtime, so the failure mode is gone rather
  -- than merely avoided.
  --
  -- The Linux CI still installs `libssl-dev`, for the *headers* Linen's
  -- `jose.c`/`tls.c` compile against. Only the link flags are unnecessary.
  mkDef `nativeLinkArgs (keychain ++ libpq)
-- ⟪native-link-flags:end⟫

package infra where
  version := v!"0.21.3"
  -- Metadata Reservoir (the Lake package index) surfaces on the package page.
  -- Reservoir indexes public Lean repos automatically — no submission — but it
  -- only shows what is declared here, and the repo link is all it can infer.
  description := "Terraform-style infrastructure as code in Lean 4: \
dependently-typed target and observed cloud state, so an unrealisable \
target is a compile error"
  keywords := #["devtool", "cloud", "infrastructure", "devops", "dsl"]
  homepage := "https://typednotes.github.io/infra/"
  license := "Apache-2.0"
  moreLinkArgs := nativeLinkArgs

-- Needs linen >= 0.13.0 for `Crypto.JOSE.rsaSign`, which `Infra.Core.GcpAuth`
-- uses to sign a service-account assertion — an older checkout fails to build
-- with "Unknown identifier FFI.privkeyPemToDer" rather than with anything
-- about versions, hence this comment. Pinned to the tag rather than `main`:
-- `linen` cuts real releases now, so tracking its tip has the same downside
-- `typednotes-infra`'s own comment on pinning `infra` describes — the next
-- breaking change arrives unannounced. Bump deliberately, the same way.
require linen from git "https://github.com/typednotes/linen" @ "v1.9.1"

@[default_target]
lean_lib Infra

@[default_target]
lean_exe infra where
  root := `Main

/-- `example/ScalewayPull.lean`: authenticate to Scaleway alone, pull, and
    export what came back to `out/scaleway/` as JSON and as Lean. Compiled by
    `lake build` like everything else, but only touches a network when run. -/
@[default_target]
lean_exe «scaleway-pull» where
  srcDir := "example"
  root := `ScalewayPull

/-- `example/ScalewayQueue.lean`: declare and push a single Scaleway queue,
    the `Keys`/`Plan`/`push` counterpart to `scaleway-pull`'s raw
    `Backend.list`. -/
@[default_target]
lean_exe «scaleway-queue» where
  srcDir := "example"
  root := `ScalewayQueue

/-- `example/ParisInstances.lean`: two EC2 instances behind one security
    group, demonstrating the library's only *required* cross-resource
    reference — an instance with no security group is not representable.
    Placeholder-backed, so it costs nothing to run. -/
@[default_target]
lean_exe «paris-instances» where
  srcDir := "example"
  root := `ParisInstances

/-- `example/CrossCloud.lean`: one fleet spanning both clouds, with a
    reference crossing between them. Unlike the two above it runs against the
    placeholder backends, so it needs no credentials and touches no network —
    it is there to be read and compiled, not to provision anything. -/
@[default_target]
lean_exe «cross-cloud» where
  srcDir := "example"
  root := `CrossCloud

/-- The test driver, which `lake test` runs.

    Offline with no arguments — that is what ordinary CI runs, and it needs no
    credentials and costs nothing. `lake test -- aws` (or `scaleway`, `gcp`)
    creates one real queue, checks the fleet converged, and deletes it again,
    with the teardown guaranteed by a `finally`. See `test/Live.lean`. -/
@[test_driver]
lean_exe «live-test» where
  srcDir := "test"
  root := `Live

/-- `example/ServerlessSqlIam.lean`: an IAM application, an API key minted
    into a secret, and a Serverless SQL Database that only IAM can open —
    the fleet `SecretSource.apiKeyFor` exists for. Placeholder-backed on a
    bare invocation, so it needs no credentials. -/
@[default_target]
lean_exe «serverless-sql-iam» where
  srcDir := "example"
  root := `ServerlessSqlIam

/-- `example/MultiRegion.lean`: one fleet in four regions, placed with nested
    `provider`/`in` blocks. Placeholder-backed like `cross-cloud`, so a bare
    invocation needs no credentials. -/
@[default_target]
lean_exe «multi-region» where
  srcDir := "example"
  root := `MultiRegion

/-- `example/PostgresMigrations.lean`: a database, the two identities and
    URL secrets that gate it, a declared migration history, and a container
    whose rollout waits on it — the `postgresMigrations` kind's whole
    story in one fleet. Placeholder-backed, so a bare invocation needs no
    credentials and touches no network: it is there to be read and
    compiled, and the ordering of its plan is what it proves. -/
@[default_target]
lean_exe «postgres-migrations» where
  srcDir := "example"
  root := `PostgresMigrations

/-- `example/KubernetesPostgres.lean`: a managed cluster, and a Postgres
    StatefulSet behind a Service inside it — the `kubernetesCluster` and
    `kubernetesObject` kinds' story in one fleet. Placeholder-backed, so a
    bare invocation needs no credentials; the ordering of its plan and the
    refusals of its broken siblings are what it proves. -/
@[default_target]
lean_exe «kubernetes-postgres» where
  srcDir := "example"
  root := `KubernetesPostgres
