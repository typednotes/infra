import Infra.Core.Stage

/-
  A ZIP archive, written by hand, because one cloud will not take code any
  other way.

  Scaleway Functions deploys from an uploaded archive: create the function, ask
  for a presigned URL, PUT a zip at it, then deploy. There is no path that
  takes a source file, and no path that takes a registry image (that is
  Containers, which this library reaches through a different kind). So
  `scalewayFunction` was the one kind the live test could not cover, and the
  reason recorded in `docs/coverage.md` was "needs deployable code, and there
  is no public equivalent to pull".

  A whole compression library is not needed for that. ZIP's method 0 is
  *stored* — the bytes go in uncompressed — and a hello-world handler is a few
  hundred bytes, so stored is both sufficient and smaller than the code that
  would deflate it. What method 0 still requires is a CRC-32 of the contents,
  which is the only real arithmetic here.

  Everything is little-endian, per the format. Sizes are 32-bit, so this is
  good for archives under 4 GiB; a function handler that approaches that has
  other problems.

  Reference: PKWARE's APPNOTE.TXT, sections 4.3.7 (local header), 4.3.12
  (central directory) and 4.3.16 (end of central directory).
-/

namespace Infra.Providers.Zip

/-! ## CRC-32

  The ordinary one: reflected, polynomial `0xEDB88320`, initial and final
  complement. Computed a bit at a time rather than from a 256-entry table,
  because a table costs 1 KiB of static data and this runs over a few hundred
  bytes once per deploy. -/

private def crcStep (c : UInt32) (byte : UInt8) : UInt32 :=
  let mix := fun (acc : UInt32) (_ : Nat) =>
    if acc &&& 1 == 1 then (0xEDB88320 : UInt32) ^^^ (acc >>> 1) else acc >>> 1
  (List.range 8).foldl mix (c ^^^ byte.toUInt32)

/-- CRC-32 of a byte array, as ZIP wants it. -/
def crc32 (bs : ByteArray) : UInt32 :=
  0xFFFFFFFF ^^^ bs.foldl crcStep 0xFFFFFFFF

/-! ## Little-endian scalars -/

private def le16 (n : Nat) : ByteArray :=
  ⟨#[UInt8.ofNat (n % 256), UInt8.ofNat (n / 256 % 256)]⟩

private def le32 (n : Nat) : ByteArray :=
  ⟨#[ UInt8.ofNat (n % 256), UInt8.ofNat (n / 256 % 256)
    , UInt8.ofNat (n / 65536 % 256), UInt8.ofNat (n / 16777216 % 256) ]⟩

private def le32' (n : UInt32) : ByteArray := le32 n.toNat

/-- One file to put in the archive. -/
structure Entry where
  /-- The path inside the archive. Forward slashes, no leading slash. -/
  name : String
  body : ByteArray

/-- Build a stored (uncompressed) archive.

    No timestamps: the DOS date and time fields are written as zero rather than
    read from the clock. That makes the output a pure function of its input,
    which is what lets the offline check below assert exact bytes — and it
    means redeploying unchanged code produces an identical archive rather than
    a spuriously different one. -/
def archive (entries : List Entry) : ByteArray :=
  -- Local headers and file data, with each entry's offset remembered for the
  -- central directory that follows.
  let (body, records, _) :=
    entries.foldl
      (fun (acc : ByteArray × List (Entry × UInt32 × Nat) × Nat) e =>
        let (bytes, recs, offset) := acc
        let nm := e.name.toUTF8
        let crc := crc32 e.body
        let local' :=
          (ByteArray.mk #[0x50, 0x4B, 0x03, 0x04])   -- local file header
            ++ le16 20                                -- version needed: 2.0
            ++ le16 0                                 -- flags
            ++ le16 0                                 -- method 0: stored
            ++ le16 0 ++ le16 0                       -- time, date: zero
            ++ le32' crc
            ++ le32 e.body.size ++ le32 e.body.size   -- compressed = raw
            ++ le16 nm.size ++ le16 0                 -- name len, extra len
            ++ nm ++ e.body
        (bytes ++ local', recs ++ [(e, crc, offset)], offset + local'.size))
      (ByteArray.empty, [], 0)
  let central :=
    records.foldl
      (fun (bytes : ByteArray) (r : Entry × UInt32 × Nat) =>
        let (e, crc, offset) := r
        let nm := e.name.toUTF8
        bytes
          ++ (ByteArray.mk #[0x50, 0x4B, 0x01, 0x02])  -- central directory
          ++ le16 20 ++ le16 20                        -- made by, needed
          ++ le16 0 ++ le16 0                          -- flags, method
          ++ le16 0 ++ le16 0                          -- time, date
          ++ le32' crc
          ++ le32 e.body.size ++ le32 e.body.size
          ++ le16 nm.size ++ le16 0 ++ le16 0          -- name, extra, comment
          ++ le16 0 ++ le16 0                          -- disk, internal attrs
          -- External attributes: 0644 in the high word, which is how a unix
          -- zip records a mode. Without it some extractors produce a file with
          -- no permissions at all, and a handler that cannot be read is a
          -- deploy that fails for a reason nothing explains.
          ++ le32 0x81A40000
          ++ le32 offset
          ++ nm)
      ByteArray.empty
  body ++ central
    ++ (ByteArray.mk #[0x50, 0x4B, 0x05, 0x06])        -- end of central dir
    ++ le16 0 ++ le16 0                                -- this disk, start disk
    ++ le16 records.length ++ le16 records.length
    ++ le32 central.size ++ le32 body.size
    ++ le16 0                                          -- comment length

/-! ## Checks

  Run on every build. A zip writer is exactly the sort of code that looks right
  and produces an archive nothing can open, so the assertions are about bytes
  and about a published CRC value rather than about it running without error. -/

/- The canonical CRC-32 check value: `"123456789"` is `0xCBF43926`, the vector
   every implementation of this polynomial is tested against. Then the empty
   case and two short strings. -/
#guard crc32 "123456789".toUTF8 = 0xCBF43926
#guard crc32 ByteArray.empty = 0
#guard crc32 "a".toUTF8 = 0xE8B7BE43
#guard crc32 "hello, world".toUTF8 = 0xFFAB723A

private def sample : ByteArray := archive [⟨"handler.py", "x".toUTF8⟩]

/- The four signatures, in order: local header, central directory, and the end
   record. An archive missing any of them opens nowhere. -/
#guard sample.toList.take 4 = [0x50, 0x4B, 0x03, 0x04]
#guard (sample.toList.drop (sample.size - 22)).take 4 = [0x50, 0x4B, 0x05, 0x06]
#guard ((sample.toList.take (sample.size - 22)).drop
          (sample.size - 22 - 46 - "handler.py".length)).take 4
     = [0x50, 0x4B, 0x01, 0x02]

/- One entry, and the end record says so in both count fields. -/
#guard (sample.toList.drop (sample.size - 22 + 8)).take 4 = [1, 0, 1, 0]

/- Stored, not deflated: method 0 sits at offset 8 of the local header. -/
#guard (sample.toList.drop 8).take 2 = [0, 0]

/- Deterministic: no clock, so the same input is the same bytes. That is what
   makes the assertions above legitimate, and it stops an unchanged redeploy
   looking like a change. -/
#guard archive [⟨"handler.py", "x".toUTF8⟩] == sample

/- An empty archive is still a well-formed one: just the end record. -/
#guard (archive []).size = 22

end Infra.Providers.Zip
