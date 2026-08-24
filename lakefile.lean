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

/-- Link flags for a `pkg-config` package, including an explicit `-L` so a
    keg-only Homebrew prefix resolves.

    macOS only — see `pkgAbsoluteLibs` for why adding a search directory is
    unsafe on Linux. -/
def pkgLinkFlags (pkg : String) : IO (Array String) := do
  let libs ← pkgConfigFlags #["--libs", pkg]
  let libdir ← pkgConfigFlags #["--variable=libdir", pkg]
  return (libdir.filter (· != "")).map ("-L" ++ ·) ++ libs

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
  -- TLS and the SHA-256/HMAC behind SigV4 are OpenSSL-backed.
  --
  -- macOS needs this explicitly: without pointing at Homebrew's OpenSSL, dyld
  -- can bind these to the system's incompatible `libboringssl`, which links
  -- cleanly and then crashes on the first TLS call.
  --
  -- Linux links it by absolute path for the same reason as libsecret: the
  -- flags are needed (`jose.o` and `tls.o` reference OpenSSL), but the `-L`
  -- that would come with them is what broke the CI link.
  let ssl ← if System.Platform.isOSX then pkgLinkFlags "openssl"
            else pkgAbsoluteLibs "openssl"
  mkDef `nativeLinkArgs (keychain ++ ssl)

package infra where
  version := v!"0.1.0"
  moreLinkArgs := nativeLinkArgs

require linen from git "https://github.com/typednotes/linen" @ "main"

@[default_target]
lean_lib Infra

@[default_target]
lean_exe infra where
  root := `Main
