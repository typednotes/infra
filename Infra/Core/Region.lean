import Infra.Core.Ergonomics

/-
  Where a fleet's resources live.

  Until now the region came from the credentials and nowhere else: every
  endpoint in `Infra.Providers.Live` is built from `creds.region`, so a fleet
  ran wherever `AWS_REGION` or `default_region` happened to point. Two things
  were wrong with that. The first is ergonomic — a declaration that cannot say
  where it is refuses to run until an environment variable is set, which is
  exactly the failure this module removes. The second is worse: placement is
  part of what a fleet *declares*, and leaving it to the environment means the
  same committed file builds a different system depending on who runs it.
  `example/ParisInstances.lean` said so in prose ("the region comes from your
  credentials, not from this file") because there was no way to say it in code.

  ## Two ways to say it, one of them portable

  A `Locality` is a place — `.paris` — and each cloud maps it to its own code
  (`eu-west-3` on AWS, `fr-par` on Scaleway) or to nothing at all, because no
  cloud is everywhere. A `Region p` is one cloud's own code, tagged with the
  cloud it belongs to, so an AWS region cannot reach Scaleway.

  Both are checked when the fleet is elaborated, never at apply time:

  - `Region.of .scaleway "eu-west-3"` — not a Scaleway region, compile error.
  - `Regions.everywhere κ .warsaw` on a fleet that uses AWS — AWS is not in
    Warsaw, compile error.
  - a placement that leaves one of the fleet's clouds unplaced — compile error
    (`Regions.covering`).

  The escape hatch is `Region.raw`, and it exists because `knownRegions` is
  derived from the `Locality` table: a region no locality names — a GovCloud
  region, or one a cloud added this morning — is unwritable otherwise, and a
  stale table must never be a hard block.

  ## Per cloud, then per resource

  A `Regions` says two things. `region` is where a cloud goes by default, and
  for a fleet in one region per cloud it is the whole story. `slot` places one
  *resource*, addressed by its `Keys.name` — the string that is also the
  cloud's physical identifier and the one `pullEntries` matches listings on.
  `codeFor` is the resolution: the slot's own placement if it has one, then its
  cloud's, then nothing, which means "ask the credentials".

  Keyed by name rather than by `κ.Key`, so `Regions` stays independent of any
  one fleet's key family — the same choice `Infra.Cli.Accounts` makes. A name
  is unique within a `(provider, kind)` bucket (`namesNodup` is what
  guarantees it), so a `slot` entry addresses exactly one resource.

  `used` is what bounds the cost of a pull: the distinct regions of one
  bucket, derived from the declarations rather than configured, so a fleet
  lists exactly the regions it names and a single-region fleet lists once.

  The block syntax that writes all this is in `Infra.Core.Declare`, and the
  routing that acts on it is `Backends.backendFor`/`listers`. See
  `docs/architecture.md`.
-/

namespace Infra.Core

/-! ## `Locality` — a place, before any cloud names it -/

/-- A place a cloud may or may not have a region in.

    Named the way each cloud's own documentation names the place, which is why
    a few are countries (`.ireland`, `.spain`, `.uae`) or a compass point
    (`.canadaCentral`) rather than cities: AWS's `eu-west-1` is "Europe
    (Ireland)" and its `ca-central-1` is "Canada (Central)" — it never says
    Dublin or Montreal, and calling it `.montreal` would also have collided
    with `ca-west-1`, "Canada West (Calgary)". A city/country pair was the
    alternative and would have had to invent a city for each of these.

    The list is the union of what the supported clouds offer, so most entries
    exist on exactly one of them — which is the point. `.warsaw` is a Scaleway
    region and not an AWS one, `.ireland` the reverse, and that asymmetry is
    what the compile-time check reads.

    **Not exhaustive, and a snapshot.** AWS's opt-in regions past the ones
    below, GovCloud and China are reachable through `Region.raw`. See
    `AGENTS.md`, "Provider facts go stale". -/
inductive Locality
  -- Europe
  | paris | amsterdam | warsaw | ireland | london
  | frankfurt | zurich | stockholm | milan | spain
  -- Americas
  | nVirginia | ohio | nCalifornia | oregon
  | canadaCentral | calgary | mexicoCentral | saoPaulo
  -- Middle East and Africa
  | uae | telAviv | capeTown
  -- Asia Pacific
  | tokyo | osaka | seoul | mumbai | hyderabad
  | singapore | jakarta | sydney | hongKong
  deriving Repr, DecidableEq, BEq

instance : Finite Locality where
  elems :=
    [ .paris, .amsterdam, .warsaw, .ireland, .london
    , .frankfurt, .zurich, .stockholm, .milan, .spain
    , .nVirginia, .ohio, .nCalifornia, .oregon
    , .canadaCentral, .calgary, .mexicoCentral, .saoPaulo
    , .uae, .telAviv, .capeTown
    , .tokyo, .osaka, .seoul, .mumbai, .hyderabad
    , .singapore, .jakarta, .sydney, .hongKong ]
  complete := by intro a; cases a <;> simp
  nodup := by decide

/-- AWS's code for a place, or `none` where AWS is not.

    Checked against AWS's "Regions and Zones" table on 2026-09-05.

    Written out rather than defaulted through a wildcard, on the same rule as
    every other total match here: adding a `Locality` must fail to compile
    until both clouds have been asked about it, because a silent `none` is a
    claim that a cloud is absent somewhere. -/
private def awsCode : Locality → Option String
  | .paris         => some "eu-west-3"
  | .ireland       => some "eu-west-1"
  | .london        => some "eu-west-2"
  | .frankfurt     => some "eu-central-1"
  | .zurich        => some "eu-central-2"
  | .stockholm     => some "eu-north-1"
  | .milan         => some "eu-south-1"
  | .spain         => some "eu-south-2"
  | .nVirginia     => some "us-east-1"
  | .ohio          => some "us-east-2"
  | .nCalifornia   => some "us-west-1"
  | .oregon        => some "us-west-2"
  | .canadaCentral => some "ca-central-1"
  | .calgary       => some "ca-west-1"
  | .mexicoCentral => some "mx-central-1"
  | .saoPaulo      => some "sa-east-1"
  | .uae           => some "me-central-1"
  | .telAviv       => some "il-central-1"
  | .capeTown      => some "af-south-1"
  | .tokyo         => some "ap-northeast-1"
  | .osaka         => some "ap-northeast-3"
  | .seoul         => some "ap-northeast-2"
  | .mumbai        => some "ap-south-1"
  | .hyderabad     => some "ap-south-2"
  | .singapore     => some "ap-southeast-1"
  | .jakarta       => some "ap-southeast-3"
  | .sydney        => some "ap-southeast-2"
  | .hongKong      => some "ap-east-1"
  -- AWS has no region in either.
  | .amsterdam | .warsaw => none

/-- Scaleway's code for a place, or `none` where Scaleway is not.

    Checked against Scaleway's VPC and Instance API region parameters on
    2026-09-05: four regions, `it-mil` having opened in March 2026. Scaleway
    has announced Sweden and Germany next, and `.stockholm` and `.frankfurt`
    are already here waiting for them.

    Regions, not availability zones: `fr-par-1` is a zone inside `fr-par` and
    is not a value that belongs in this table.

    The `none`s are grouped into one arm rather than written as a wildcard, so
    that adding a `Locality` still breaks the match. -/
private def scalewayCode : Locality → Option String
  | .paris     => some "fr-par"
  | .amsterdam => some "nl-ams"
  | .warsaw    => some "pl-waw"
  | .milan     => some "it-mil"
  | .ireland | .london | .frankfurt | .zurich | .stockholm | .spain
  | .nVirginia | .ohio | .nCalifornia | .oregon
  | .canadaCentral | .calgary | .mexicoCentral | .saoPaulo
  | .uae | .telAviv | .capeTown
  | .tokyo | .osaka | .seoul | .mumbai | .hyderabad
  | .singapore | .jakarta | .sydney | .hongKong => none

/-- What this cloud calls this place, if it is there at all. -/
def Locality.code (l : Locality) : ProviderId → Option String
  | .aws      => awsCode l
  | .scaleway => scalewayCode l

/-- Whether every cloud `κ` declares resources in has a region at `l`.

    Named rather than inlined so that the compile error a violation produces
    reads as `Assert (Locality.warsaw.covers keys)` — which names the place —
    instead of an unfolded `List.all` over an inlined `Locality.code`. -/
def Locality.covers (l : Locality) (κ : Keys) : Bool :=
  κ.providers.all fun p => (l.code p).isSome

/-! ## `Region` — one cloud's own code, tagged with the cloud -/

/-- A region code, indexed by the cloud it belongs to.

    The index is what stops `eu-west-3` reaching Scaleway *by typing*; the
    constructors below add the weaker, decidable check that the code is one
    that cloud actually has. -/
structure Region (p : ProviderId) where
  code : String
  deriving Repr, DecidableEq

/-- Every region code the `Locality` table names for a cloud.

    Derived from that table rather than written out a second time, so the two
    cannot drift: every region with a code here has a portable name, and one
    without a portable name needs `Region.raw`. -/
def knownRegions (p : ProviderId) : List String :=
  (Finite.elems (α := Locality)).filterMap (Locality.code · p)

/-- A cloud's own region code, checked against `knownRegions` at elaboration.

    Catches both halves of "compatible": a code from the wrong cloud, and a
    typo in a code from the right one. Neither survives to a DNS failure. -/
def Region.of (p : ProviderId) (code : String)
    (_h : Assert ((knownRegions p).contains code) := by decide) : Region p :=
  ⟨code⟩

/-- A region code taken on trust.

    `knownRegions` is a hand-maintained table and clouds add regions, so there
    has to be a way past it — but it is spelled differently from `Region.of`,
    so reaching for it is visible in the declaration rather than silent. -/
def Region.raw (p : ProviderId) (code : String) : Region p := ⟨code⟩

/-- The region a cloud uses for a place, refusing to elaborate if it has none
    there. -/
def Locality.region (l : Locality) (p : ProviderId)
    (h : Assert (l.code p).isSome := by decide) : Region p :=
  ⟨(l.code p).get h⟩

/-! ## `Regions` — where one fleet is, cloud by cloud -/

/-- Which region each cloud's half of a fleet lives in.

    A total function over `ProviderId` rather than one named field per cloud,
    for the same reason `Infra.Cli.Accounts` is: the enum is `Finite` and the
    rest of the library already treats it uniformly, so a third cloud should be
    a row rather than a third copy of everything that reads this.

    `none` means "take it from the credentials", which is what every fleet did
    before this existed and is still what a fleet with no `in` clause does. -/
structure Regions where
  region : (p : ProviderId) → Option (Region p) := fun _ => none
  /-- A single slot that lives somewhere other than its cloud's own region,
      identified by its `Keys.name` — which is the cloud's physical
      identifier, and the same string `pullEntries` matches listings on.

      Keyed by name rather than by `κ.Key`, so `Regions` stays independent of
      any one fleet's key family, exactly as `Infra.Cli.Accounts` does. The
      name is unique within a `(provider, kind)` bucket — `namesNodup` is what
      guarantees it — so this addresses exactly one resource. -/
  slot : ProviderId → Kind → String → Option String := fun _ _ _ => none

namespace Regions

/-- Put every cloud the fleet uses at one place.

    The portable spelling, and the one that carries a real obligation: `_h`
    fails for a place one of the fleet's clouds is not in. It is a fresh
    placement rather than an override, so it belongs first in a chain. -/
def everywhere (κ : Keys) (l : Locality) (_h : Assert (l.covers κ) := by decide) : Regions where
  region p := (l.code p).map Region.mk

/-- Place one cloud, overriding whatever was said for it. The cloud is implicit
    because `r`'s type names it.

    `{ rs with … }` rather than a fresh structure: rebuilding one would reset
    `slot` to its default and silently drop every per-resource placement made
    before it. -/
def set (rs : Regions) {p : ProviderId} (r : Region p) : Regions :=
  { rs with region := fun q => if h : p = q then some (h ▸ r) else rs.region q }

/-- The region code in force for one slot: its own, if it was placed
    individually, and otherwise its cloud's. -/
def codeFor (rs : Regions) (p : ProviderId) (k : Kind) (name : String) : Option String :=
  match rs.slot p k name with
  | some c => some c
  | none   => (rs.region p).map Region.code

/-- Place one resource, overriding the region its cloud is otherwise in.

    This is what a region block inside a fleet expands to. `k` and `name`
    together name one slot; the cloud comes from `r`'s type. -/
def setSlot (rs : Regions) {p : ProviderId} (k : Kind) (name : String)
    (r : Region p) : Regions :=
  { rs with slot := fun p' k' n' =>
      if p' == p && k' == k && n' == name then some r.code else rs.slot p' k' n' }

/-- Whether every cloud `κ` declares resources in has a default region.

    Deliberately *not* per slot, and the reason is worth recording because the
    per-slot version was written first and had to be withdrawn: it is
    discharged by `by decide`, which reduces in the **kernel**, and a per-slot
    check compares the slot's name against every `setSlot` in the chain. Kernel
    `String` equality walks a list of characters, so a six-resource fleet in
    four regions took Lean down with a stack overflow.

    Nothing is lost. A resource inside a region block is placed *by
    construction* — the block is what places it — so the only thing a coverage
    check can catch is a cloud whose resources fall back to a default that does
    not exist, and that is exactly this. Slots that fall back with no default
    are caught at the one place that can afford to look: `Infra.Cli.liveFor`,
    at runtime, where the same walk is a handful of string comparisons and the
    failure names the cloud and all three ways to fix it. -/
def covers (rs : Regions) (κ : Keys) : Bool :=
  κ.providers.all fun p => (rs.region p).isSome

/-- Whether every *resource* has a region, counting per-slot placements.

    The honest coverage question, and the one `covers` cannot afford to be. Not
    an `Assert`: only ever evaluated at runtime. -/
def coversSlots (rs : Regions) (κ : Keys) : Bool :=
  (Finite.elems (α := ProviderId)).all fun p =>
    (Finite.elems (α := Kind)).all fun k =>
      (Finite.elems (α := κ.Key p k)).all fun key =>
        (rs.codeFor p k (κ.name p k key)).isSome

/-- The distinct regions a `(provider, kind)` bucket's resources live in,
    with `fallback` standing for a slot the fleet does not place.

    This is what bounds the cost of a pull: `pullEntries` lists once per entry
    here, and the list is derived from the fleet's own declarations — so it is
    exactly the regions the fleet uses, deduplicated, and never one it declares
    nothing in. A fleet in one region lists once, as it always did. -/
def used (rs : Regions) (κ : Keys) (p : ProviderId) (k : Kind)
    (fallback : String) : List String :=
  (Finite.elems (α := κ.Key p k)).foldl (init := []) fun acc key =>
    let c := (rs.codeFor p k (κ.name p k key)).getD fallback
    if acc.contains c then acc else acc ++ [c]

/-- `rs`, refusing to elaborate unless it places every cloud `κ` uses.

    The check `everywhere` cannot make on its own: a fleet placed cloud by
    cloud can simply leave one out, and the consequence — that cloud silently
    falling back to whatever the credentials say — is the behaviour this module
    exists to end. A fleet that says nothing at all is untouched by this; only
    a fleet that says *something* is held to saying it about everything. -/
def covering (κ : Keys) (rs : Regions) (_h : Assert (rs.covers κ) := by decide) : Regions := rs

end Regions

/-! ## Self-checks -/

-- Paris and Milan are the two places both clouds are, which is what a
-- cross-cloud fleet can be declared at. Milan only since March 2026 — this
-- table said three Scaleway regions until it was checked against Scaleway's
-- own API docs, which is the whole of `AGENTS.md`'s "Provider facts go stale".
#guard Locality.paris.code .aws = some "eu-west-3"
#guard Locality.paris.code .scaleway = some "fr-par"
#guard Locality.milan.code .aws = some "eu-south-1"
#guard Locality.milan.code .scaleway = some "it-mil"

-- Scaleway is in Warsaw and Amsterdam; AWS is in neither.
#guard Locality.warsaw.code .scaleway = some "pl-waw"
#guard Locality.warsaw.code .aws = none
#guard Locality.amsterdam.code .aws = none

-- ...and AWS is in a great many places Scaleway is not.
#guard Locality.ireland.code .aws = some "eu-west-1"
#guard Locality.ireland.code .scaleway = none

-- Scaleway has exactly four regions. If this changes, `scalewayCode` is the
-- one place to change, and this guard is what notices it did not — it is how
-- the missing `it-mil` was found.
#guard (knownRegions .scaleway).length = 4
#guard knownRegions .scaleway = ["fr-par", "nl-ams", "pl-waw", "it-mil"]

-- The two clouds overlap in exactly these places, which is the set a
-- cross-cloud fleet can be declared at.
#guard (Finite.elems (α := Locality)).filter
  (fun l => (l.code .aws).isSome && (l.code .scaleway).isSome) = [.paris, .milan]

-- `Region.of`'s check is exactly membership in that list, which is what makes
-- an AWS code at Scaleway a compile error rather than a DNS failure:
--
--   Region.of .scaleway "eu-west-3"
--
--   could not synthesize default value for parameter '_h' using tactics
--   Tactic `decide` proved that the proposition
--     Assert ((knownRegions ProviderId.scaleway).contains "eu-west-3")
--   is false
#guard (knownRegions .scaleway).contains "eu-west-3" = false
#guard (knownRegions .aws).contains "eu-west-3" = true
#guard (knownRegions .aws).contains "eu-west-33" = false

#guard (Region.of .aws "eu-west-3").code = "eu-west-3"
#guard (Locality.paris.region .scaleway).code = "fr-par"
#guard (Region.raw .aws "us-gov-west-1").code = "us-gov-west-1"

-- Every code a locality names is a known region of that cloud, so `Region.of`
-- accepts everything `Locality.region` can produce.
#guard (Finite.elems (α := Locality)).all fun l =>
  (Finite.elems (α := ProviderId)).all fun p =>
    match l.code p with
    | some c => (knownRegions p).contains c
    | none   => true

section RegionsGuards

private def oneCloud : Keys := Keys.build fun
  | .aws, .objectStore => .named ["assets"]
  | _,    _            => .unused

private def bothClouds : Keys := Keys.build fun
  | .aws,      .objectStore => .named ["assets"]
  | .scaleway, .objectStore => .named ["assets"]
  | _,         _            => .unused

#guard oneCloud.providers = [.aws]
#guard bothClouds.providers = [.aws, .scaleway]

-- A locality covers a fleet when every cloud the fleet uses is there. Warsaw
-- covers a Scaleway-only fleet and not a cross-cloud one — this Bool is
-- precisely what `Regions.everywhere`'s auto-param asserts, so these two lines
-- are the compile error, evaluated rather than triggered.
#guard Locality.paris.covers bothClouds = true
#guard Locality.milan.covers bothClouds = true
#guard Locality.warsaw.covers bothClouds = false
#guard Locality.ireland.covers oneCloud = true
#guard Locality.warsaw.covers oneCloud = false

-- The portable spelling reaches both clouds with each one's own code.
private def atParis : Regions := Regions.everywhere bothClouds .paris
#guard (atParis.region .aws).map Region.code = some "eu-west-3"
#guard (atParis.region .scaleway).map Region.code = some "fr-par"
#guard atParis.covers bothClouds = true

-- `set` overrides one cloud and leaves the other alone: "both in Paris, except
-- Scaleway in Warsaw".
private def parisButWarsaw : Regions := atParis.set (Region.of .scaleway "pl-waw")
#guard (parisButWarsaw.region .aws).map Region.code = some "eu-west-3"
#guard (parisButWarsaw.region .scaleway).map Region.code = some "pl-waw"

-- Cloud by cloud, with no locality involved.
private def perCloud : Regions :=
  (({} : Regions).set (Region.of .aws "eu-west-1")).set (Region.of .scaleway "fr-par")
#guard (perCloud.region .aws).map Region.code = some "eu-west-1"
#guard (perCloud.region .scaleway).map Region.code = some "fr-par"
#guard perCloud.covers bothClouds = true

-- Placing only one half of a two-cloud fleet does not cover it, which is what
-- `Regions.covering` refuses. The same value covers the one-cloud fleet, so
-- the check is about the fleet, not about the placement alone.
private def awsOnly : Regions := ({} : Regions).set (Region.of .aws "eu-west-1")
#guard awsOnly.covers bothClouds = false
#guard awsOnly.covers oneCloud = true

-- Saying nothing is not a partial placement: it is the pre-existing
-- "ask the credentials" behaviour, and no fleet is held to it.
#guard ({} : Regions).covers oneCloud = false
#guard (({} : Regions).region .aws).isNone = true

end RegionsGuards

end Infra.Core
