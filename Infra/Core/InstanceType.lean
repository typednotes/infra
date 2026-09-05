import Infra.Core.Finite

/-
  EC2 instance types, in two axes rather than one string.

  `AwsInstanceSpec.instanceType` was a `String`, which made `"t3.nanoo"` a
  declaration that elaborates, plans, and fails at `RunInstances` with
  `InvalidParameterValue` — after the security group it references has already
  been created. It also offered nothing to an author who does not already know
  the catalogue by heart.

  An instance type is not really a string, though: AWS names it
  `<family>.<size>`, and both halves are drawn from small closed sets. Written
  that way, autocomplete lists the families and then the sizes, and the
  *combination* is checked — `t3` has no `32xlarge`, and asking for one is a
  compile error rather than an API error.

      instanceType := InstanceType.of .t3 .nano

  ## Why not one enum of instance types

  Because there are several hundred of them and the cross product is what
  makes this table small: a family contributes one constructor and one size
  list, not eight constructors. `InstanceFamily.sizes` is the only place the
  two axes meet, so a family that gains a size is one edit.

  ## What it does not check

  **That the type exists in the region the fleet is placed in.** `eu-west-3`
  carries a narrower catalogue than `us-east-1`, and nothing here reads
  `Infra.Core.Region`. Encoding that would mean a third table — family ×
  region — large, fast-moving, and prone to rejecting valid declarations when
  stale, which is a worse failure than the one it prevents. Recorded in
  `docs/diff-semantics.md`'s ledger as a known gap.

  **That the account may use it.** Some families need a quota increase, and
  quotas are per-account state, not catalogue.

  So `InstanceType.of .c7i .xlarge48` elaborates and can still fail at
  `RunInstances`. What it cannot do is fail because of a typo.

  ## Staleness

  This is a snapshot of someone else's catalogue — see `AGENTS.md`, "Provider
  facts go stale". `InstanceType.raw` is the way past it, spelled differently
  from `of` so that reaching past the table is visible in the declaration.
-/

namespace Infra.Core

/-! ## The two axes -/

/-- How large, within a family.

    Constructor names cannot begin with a digit, so AWS's `2xlarge` is
    `xlarge2` here and `InstanceSize.code` puts it back. The `metal` sizes are
    spelled two ways by AWS itself — plain `metal` on older families, suffixed
    (`metal-24xl`) on the ones that come in more than one bare-metal shape —
    and both spellings are here because both are real. -/
inductive InstanceSize
  -- burstable only
  | nano | micro | small | medium
  -- the common ladder
  | large | xlarge | xlarge2 | xlarge4 | xlarge8
  | xlarge12 | xlarge16 | xlarge24 | xlarge32 | xlarge48
  -- bare metal
  | metal | metal24xl | metal48xl
  deriving Repr, DecidableEq, BEq

instance : Finite InstanceSize where
  elems :=
    [ .nano, .micro, .small, .medium
    , .large, .xlarge, .xlarge2, .xlarge4, .xlarge8
    , .xlarge12, .xlarge16, .xlarge24, .xlarge32, .xlarge48
    , .metal, .metal24xl, .metal48xl ]
  complete := by intro a; cases a <;> simp
  nodup := by decide

/-- What AWS calls this size. -/
def InstanceSize.code : InstanceSize → String
  | .nano      => "nano"
  | .micro     => "micro"
  | .small     => "small"
  | .medium    => "medium"
  | .large     => "large"
  | .xlarge    => "xlarge"
  | .xlarge2   => "2xlarge"
  | .xlarge4   => "4xlarge"
  | .xlarge8   => "8xlarge"
  | .xlarge12  => "12xlarge"
  | .xlarge16  => "16xlarge"
  | .xlarge24  => "24xlarge"
  | .xlarge32  => "32xlarge"
  | .xlarge48  => "48xlarge"
  | .metal     => "metal"
  | .metal24xl => "metal-24xl"
  | .metal48xl => "metal-48xl"

/-! ## The size shapes

  Twenty-six families, but only **nine distinct size lists** between them —
  which is why they are named and shared rather than written out per family.
  Each name below is one fact about AWS's catalogue, stated once, and the
  differences between them are exactly the places a hand-written table goes
  wrong.

  Checked against AWS's `docs.aws.amazon.com/ec2/latest/instancetypes/`
  general-purpose, compute-optimized and memory-optimized tables on
  2026-09-05, and cross-checked against AWS's public spot-advisor dataset:
  exact set equality for all twenty-six. -/

/-- `t3`, `t3a`, `t4g`. The only families with `nano`/`micro`/`small`, and the
    only ones with no bare-metal size at all. -/
private def burstable : List InstanceSize :=
  [.nano, .micro, .small, .medium, .large, .xlarge, .xlarge2]

/-- `m6i`, `c6i`, `r6i`. Intel gen-6 stops at `32xlarge`: **no `48xlarge`**,
    unlike its AMD sibling. -/
private def gen6Intel : List InstanceSize :=
  [.large, .xlarge, .xlarge2, .xlarge4, .xlarge8,
   .xlarge12, .xlarge16, .xlarge24, .xlarge32, .metal]

/-- `m6a`, `c6a`, `r6a`. AMD gen-6 has both `32xlarge` and `48xlarge`. -/
private def gen6Amd : List InstanceSize :=
  [.large, .xlarge, .xlarge2, .xlarge4, .xlarge8,
   .xlarge12, .xlarge16, .xlarge24, .xlarge32, .xlarge48, .metal]

/-- `m6g`, `c6g`, `r6g`. Graviton gen-6 tops out at `16xlarge`, and — like
    every Graviton here — offers `medium` above the burstable tier. -/
private def gen6Graviton : List InstanceSize :=
  [.medium, .large, .xlarge, .xlarge2, .xlarge4,
   .xlarge8, .xlarge12, .xlarge16, .metal]

/-- `m7i`, `c7i`, `r7i`. The row most likely to be written wrong: gen-7 Intel
    jumps `24xlarge` → `48xlarge` with **no `32xlarge`**, and its bare metal
    comes in two suffixed shapes rather than one plain `metal`. -/
private def gen7Intel : List InstanceSize :=
  [.large, .xlarge, .xlarge2, .xlarge4, .xlarge8, .xlarge12,
   .xlarge16, .xlarge24, .xlarge48, .metal24xl, .metal48xl]

/-- `m7i-flex`, `c7i-flex`. Separate families, not sizes of `m7i`/`c7i`: no
    `medium`, no metal, and nothing above `16xlarge`. -/
private def gen7Flex : List InstanceSize :=
  [.large, .xlarge, .xlarge2, .xlarge4, .xlarge8, .xlarge12, .xlarge16]

/-- `m7a`, `c7a`, `r7a`. AMD gen-7 keeps `32xlarge` where Intel gen-7 drops
    it, and has only the one metal shape. -/
private def gen7Amd : List InstanceSize :=
  [.medium, .large, .xlarge, .xlarge2, .xlarge4, .xlarge8, .xlarge12,
   .xlarge16, .xlarge24, .xlarge32, .xlarge48, .metal48xl]

/-- `m7g`, `c7g`, `r7g`. Same ceiling as Graviton gen-6. -/
private def gen7Graviton : List InstanceSize :=
  [.medium, .large, .xlarge, .xlarge2, .xlarge4,
   .xlarge8, .xlarge12, .xlarge16, .metal]

/-- `m8g`, `c8g`, `r8g`. Graviton gen-8 finally reaches `48xlarge` — still
    with no `32xlarge` — and takes the suffixed metal spellings. -/
private def gen8Graviton : List InstanceSize :=
  [.medium, .large, .xlarge, .xlarge2, .xlarge4, .xlarge8, .xlarge12,
   .xlarge16, .xlarge24, .xlarge48, .metal24xl, .metal48xl]

/-! ## The families -/

/-- A current-generation EC2 instance family.

    Current as of 2026-09-05, checked against AWS's previous-generation list
    (which holds A1, C1, C3, C4, G3, I2, M1, M2, M3, M4, P3, P3dn, R3, R4, T1
    — none of them here).

    Deliberately *not* the whole catalogue: AWS also has gen-8 Intel/AMD and
    gen-9 Graviton, plus accelerated and storage-optimised families, and each
    would bring sizes this enum does not have (`3xlarge`, `6xlarge`,
    `64xlarge`, `96xlarge`, `metal-96xl`). Adding a family is a constructor,
    a `code` row and a `sizes` row; until then `InstanceType.raw` reaches
    them. -/
inductive InstanceFamily
  -- burstable
  | t3 | t3a | t4g
  -- general purpose
  | m6i | m6a | m6g | m7i | m7iFlex | m7a | m7g | m8g
  -- compute optimised
  | c6i | c6a | c6g | c7i | c7iFlex | c7a | c7g | c8g
  -- memory optimised
  | r6i | r6a | r6g | r7i | r7a | r7g | r8g
  deriving Repr, DecidableEq, BEq

instance : Finite InstanceFamily where
  elems :=
    [ .t3, .t3a, .t4g
    , .m6i, .m6a, .m6g, .m7i, .m7iFlex, .m7a, .m7g, .m8g
    , .c6i, .c6a, .c6g, .c7i, .c7iFlex, .c7a, .c7g, .c8g
    , .r6i, .r6a, .r6g, .r7i, .r7a, .r7g, .r8g ]
  complete := by intro a; cases a <;> simp
  nodup := by decide

/-- What AWS calls this family. Only the two flex families differ from their
    constructor name, because a Lean identifier cannot hold the hyphen. -/
def InstanceFamily.code : InstanceFamily -> String
  | .t3 => "t3" | .t3a => "t3a" | .t4g => "t4g"
  | .m6i => "m6i" | .m6a => "m6a" | .m6g => "m6g"
  | .m7i => "m7i" | .m7iFlex => "m7i-flex" | .m7a => "m7a"
  | .m7g => "m7g" | .m8g => "m8g"
  | .c6i => "c6i" | .c6a => "c6a" | .c6g => "c6g"
  | .c7i => "c7i" | .c7iFlex => "c7i-flex" | .c7a => "c7a"
  | .c7g => "c7g" | .c8g => "c8g"
  | .r6i => "r6i" | .r6a => "r6a" | .r6g => "r6g"
  | .r7i => "r7i" | .r7a => "r7a" | .r7g => "r7g" | .r8g => "r8g"

/-- Which sizes this family actually comes in. The one place the two axes
    meet, and what `InstanceType.of` checks against. -/
def InstanceFamily.sizes : InstanceFamily -> List InstanceSize
  | .t3 | .t3a | .t4g            => burstable
  | .m6i | .c6i | .r6i           => gen6Intel
  | .m6a | .c6a | .r6a           => gen6Amd
  | .m6g | .c6g | .r6g           => gen6Graviton
  | .m7i | .c7i | .r7i           => gen7Intel
  | .m7iFlex | .c7iFlex          => gen7Flex
  | .m7a | .c7a | .r7a           => gen7Amd
  | .m7g | .c7g | .r7g           => gen7Graviton
  | .m8g | .c8g | .r8g           => gen8Graviton

/-! ## The type itself -/

/-- An EC2 instance type.

    A string underneath, so the backend hands it straight to `RunInstances`
    and reads it straight back from `DescribeInstances` without a parse that
    could fail. The two axes are how you *write* one; they are not how it is
    stored, which is what keeps the read path total. -/
structure InstanceType where
  name : String
  deriving Repr, DecidableEq, BEq, Inhabited

/-- `t3.nano`, built from a family and a size that family comes in.

    The auto-param is the whole point: `InstanceType.of .t3 .xlarge32` does
    not elaborate, because `t3` has no `32xlarge`. -/
def InstanceType.of (f : InstanceFamily) (s : InstanceSize)
    (_h : Assert (f.sizes.contains s) := by decide) : InstanceType :=
  ⟨s!"{f.code}.{s.code}"⟩

/-- An instance type taken on trust.

    The table above is a snapshot of a catalogue AWS extends without telling
    us, so there has to be a way past it — spelled differently from `of`, so
    that reaching past it is visible in the declaration rather than silent.
    Also the only way to name an accelerated, storage-optimised or
    newer-generation family. -/
def InstanceType.raw (name : String) : InstanceType := ⟨name⟩

/-- Every type this table can name. Not used to check anything — `of` checks
    against the family's own row — but it is what the self-check below counts,
    and it is a useful thing to print. -/
def InstanceType.all : List InstanceType :=
  (Finite.elems (α := InstanceFamily)).flatMap fun f =>
    f.sizes.map fun s => ⟨s!"{f.code}.{s.code}"⟩

/-! ## Self-checks -/

/-- Local, because `Infra.Core.Ergonomics`' `namesNodup` is the same function
    but lives above this file in the import order. -/
private def noRepeats : List String -> Bool
  | []      => true
  | n :: ns => !ns.contains n && noRepeats ns

#guard (InstanceType.of .t3 .nano).name = "t3.nano"
#guard (InstanceType.of .m7i .xlarge48).name = "m7i.48xlarge"
#guard (InstanceType.of .c7iFlex .large).name = "c7i-flex.large"
#guard (InstanceType.of .m7i .metal24xl).name = "m7i.metal-24xl"
#guard (InstanceType.of .r6g .metal).name = "r6g.metal"
#guard (InstanceType.raw "p5.48xlarge").name = "p5.48xlarge"

-- The pair check, which is what a bare string could not do. Each of these
-- `false`s is a compile error at the call site:
--
--   InstanceType.of .t3 .xlarge32
--
--   could not synthesize default value for parameter '_h' using tactics
--   Tactic `decide` proved that the proposition
--     Assert (InstanceFamily.t3.sizes.contains InstanceSize.xlarge32)
--   is false
#guard (InstanceFamily.t3.sizes.contains .xlarge32) = false   -- burstable stops at 2xlarge
#guard (InstanceFamily.t3.sizes.contains .metal) = false      -- and has no bare metal
#guard (InstanceFamily.m7i.sizes.contains .xlarge32) = false  -- gen-7 Intel skips 32xlarge
#guard (InstanceFamily.m7i.sizes.contains .xlarge48) = true   -- ...and jumps to 48
#guard (InstanceFamily.m6i.sizes.contains .xlarge48) = false  -- gen-6 Intel stops at 32
#guard (InstanceFamily.m6a.sizes.contains .xlarge48) = true   -- ...its AMD sibling does not
#guard (InstanceFamily.m7g.sizes.contains .xlarge24) = false  -- Graviton gen-7 stops at 16
#guard (InstanceFamily.m8g.sizes.contains .xlarge48) = true   -- Graviton gen-8 reaches 48
#guard (InstanceFamily.m7iFlex.sizes.contains .medium) = false -- flex has no medium
#guard (InstanceFamily.m7iFlex.sizes.contains .metal) = false  -- ...and no metal

-- Metal is spelled two ways and each family takes exactly one of them.
#guard (InstanceFamily.m6i.sizes.contains .metal) = true
#guard (InstanceFamily.m6i.sizes.contains .metal48xl) = false
#guard (InstanceFamily.m7i.sizes.contains .metal) = false
#guard (InstanceFamily.m7a.sizes.contains .metal24xl) = false  -- AMD gen-7: only metal-48xl
#guard (InstanceFamily.m7a.sizes.contains .metal48xl) = true

-- Every family lists at least one size...
#guard (Finite.elems (α := InstanceFamily)).all fun f => !f.sizes.isEmpty

-- ...and no two of the 257 names collide, which is the same fact as "no
-- family lists a size twice" plus "no two families share a code". Written
-- over the rendered names because that is what actually has to be unique.
#guard noRepeats (InstanceType.all.map InstanceType.name)

-- 26 families, 257 types between them. A number rather than a shrug: if a
-- family or a size list changes, this is what says so.
#guard card InstanceFamily = 26
#guard card InstanceSize = 17
#guard InstanceType.all.length = 257

-- Every size in the enum is used by some family, so the enum has no
-- constructor invented for a size AWS does not offer in this scope. This is
-- what caught `metal-16xl` and `metal-32xl`, which were written from memory
-- and exist only in families outside it.
#guard (Finite.elems (α := InstanceSize)).all fun s =>
  (Finite.elems (α := InstanceFamily)).any fun f => f.sizes.contains s

end Infra.Core
