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
  archive contributes only the members whose symbols are referenced, so there
  is no need for Linen's libpq or DuckDB flags here.

  Resolution happens at lakefile-elaboration time on the build machine, so
  nothing is hardcoded to one developer's paths.
-/

-- ⟪native-link-flags:begin⟫ — mirrored verbatim into `Infra/Cli/New.lean`.
-- `ci/check-lakefile-sync.sh` fails the build if the two ever differ.
/-- Ask `pkg-config` for a package's flags, degrading to `#[]` when it or the
    package is missing — matching how Linen treats optional native
    dependencies. -/
def pkgConfigFlags (args : Array String) : IO (Array String) := do
  try
    let out ← IO.Process.output { cmd := "pkg-config", args }
    if out.exitCode != 0 then return #[]
    return (out.stdout.trimAscii.copy.splitOn " ").toArray.map (·.trimAscii.copy)
      |>.filter (· != "")
  catch _ => return #[]

/-- Link flags naming each library file outright, rather than adding its
    directory to the search path.

    On Linux, `pkg-config --variable=libdir` is typically
    `/usr/lib/x86_64-linux-gnu`, which holds the *system* `libc.so` alongside
    everything else. Passing that as `-L` makes `ld.lld` prefer the system
    glibc over the one Lean bundles, and Lean's own `Scrt1.o` references
    `__libc_csu_init` — removed in glibc 2.34. The result is a link that fails
    with an undefined symbol in the C runtime, nowhere near anything this
    package wrote.

    Linen has the same `-L` and never hits this, because only `lean_lib Linen`
    is a default target there: `lake build` never links an executable. `infra`
    does.

    Naming `<libdir>/libfoo.so` directly links exactly the intended file and
    shadows nothing. Falls back to `-lfoo` if the file is absent, so a distro
    with a different layout still gets a chance. -/
def pkgAbsoluteLibs (pkg : String) : IO (Array String) := do
  let libs ← pkgConfigFlags #["--libs", pkg]
  let libdirs ← pkgConfigFlags #["--variable=libdir", pkg]
  let libdir : Option String := (libdirs.filter (· != ""))[0]?
  let mut out : Array String := #[]
  for tok in libs do
    if tok.startsWith "-L" then
      continue                                  -- deliberately dropped
    else if tok.startsWith "-l" then
      let name := (tok.drop 2).toString
      match libdir with
      | some d =>
        let candidate : FilePath := (d : FilePath) / s!"lib{name}.so"
        if ← candidate.pathExists then
          out := out.push candidate.toString
        else
          out := out.push tok
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

open Lean Elab Command in
run_cmd do
  let mkDef (n : Name) (flags : Array String) : CommandElabM Unit := do
    let lits : Array (TSyntax `term) := flags.map (fun s => quote s)
    elabCommand (← `(def $(mkIdent n) : Array String := #[$lits,*]))
  -- `System.Keychain`: Security.framework on macOS, libsecret on Linux.
  let keychain : Array String ←
    if System.Platform.isOSX then
      (macSdkArgs).map (· ++ #["-framework", "Security", "-framework", "CoreFoundation"])
    else if System.Platform.isWindows then
      pure #["-ladvapi32", "-lcredui"]
    else
      pkgAbsoluteLibs "libsecret-1"
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
  mkDef `nativeLinkArgs keychain
-- ⟪native-link-flags:end⟫

package infra where
  version := v!"0.4.7"
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
-- uses to sign a service-account assertion. Pinned to `main` as before, but an
-- older checkout fails to build with "Unknown identifier FFI.privkeyPemToDer"
-- rather than with anything about versions — hence this comment.
require linen from git "https://github.com/typednotes/linen" @ "main"

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

/-- `example/MultiRegion.lean`: one fleet in four regions, placed with nested
    `provider`/`in` blocks. Placeholder-backed like `cross-cloud`, so a bare
    invocation needs no credentials. -/
@[default_target]
lean_exe «multi-region» where
  srcDir := "example"
  root := `MultiRegion
