// Mz950 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Plugin/Source/S950/Disk.h and Disk.cpp.
//
// A NOTE ON THE PORT. The C++ Disk is a value: `Disk d = other` copies it, which here is
// TS950Disk.Assign, and Disk::blank returns one, which here is a new object the caller
// frees. A PatchPtr is a TS950Patch reference: BuildPatch hands its caller the one
// reference it returns (see S950Patch).
//
// Entries are records in a dynamic array, and what Find and EntryInSlot return points into
// it, as the C++'s Entry pointers point into its vector: both are good until the directory
// is next parsed (LoadBytes, AddSample, AddProgram). The methods that take an entry take it
// `const`, which FPC and Delphi pass by reference, as the C++ takes `const Entry&`; none of
// them parses the directory while it holds one, in either language.
//
// Where the C++ narrows a long long to int (a hostile sample header's 32-bit counts), or
// adds two ints that can overflow, the port wraps explicitly, as the C++ does in practice,
// so the range and overflow checks the verify builds run with stay quiet. Names are ASCII:
// the C++ upper-cases bytes in the C locale, and so does this, character by character.

unit S950Disk;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  SysUtils, S950Math, S950Patch;

type
  //
  // Every setting of a keygroup that can be changed in place, one byte each.
  //
  // The byte positions and encodings are the C# Studio's (AkaiS950Studio/Editors.cs,
  // KeygroupEditor), so a disk edited here reads the same there and on the machine:
  //
  //   - most are 0..99, stored as they are;
  //   - velocity to release, warp depth, the VCF amount, and a zone's transpose and
  //     loudness are signed, -50..+50, in two's complement;
  //   - the output port is the panel's 0..10 stored one LOWER, so ALL is 0xFF;
  //   - a zone's fine is 0..255, the LOW byte of one signed 16-bit pitch offset whose high
  //     byte is the transpose, counting sixteenths of a semitone (see Zone::pitchOffset);
  //   - the four flags are single bits of byte 18, and change one at a time, so the bits
  //     nobody has decoded yet survive every edit.
  //
  TKeygroupParam = (
    kpHighKey, kpLowKey, kpVelocitySwitch,
    kpVcaAttack, kpVcaDecay, kpVcaSustain, kpVcaRelease,
    kpVelToFilter, kpKeyToFilter, kpVelToAttack, kpVelToRelease, kpVelToLoudness,
    kpWarpVelocity, kpWarpDepth, kpWarpTime,
    kpLfoDelay, kpLfoRate, kpLfoDepth, kpLfoAftertouch, kpLfoModwheel,
    kpOutputPort,
    kpVcfAmount, kpVcfAttack, kpVcfDecay, kpVcfSustain, kpVcfRelease,
    kpZone1Fine, kpZone1Transpose, kpZone1Filter, kpZone1Loudness,
    kpZone2Fine, kpZone2Transpose, kpZone2Filter, kpZone2Loudness,
    kpConstantPitch, kpLfoDesync, kpOneShot, kpVelocityReleaseOn);

const
  // KeygroupParam::Count
  KeygroupParamCount = Ord(High(TKeygroupParam)) + 1;

type
  TKeygroupParamKind = (pkUnsigned, pkSigned, pkPort, pkBit);

  TKeygroupParamInfo = record
    Name: string;
    Offset: Integer;               // within the 70-byte keygroup record
    Lo, Hi: Integer;               // the panel's range, which writing clamps to
    Kind: TKeygroupParamKind;
    Mask: Integer;                 // Bit only
  end;

// Where a setting lives and how it is written. The one table everything reads.
function KeygroupParamInfo(P: TKeygroupParam): TKeygroupParamInfo;

const
  // Disk::DdBlocks and Disk::HdBlocks, here as well as on TS950Disk.
  DdBlocks = 800;
  HdBlocks = 1600;

type
  TSmallIntArray = array of SmallInt;
  TIntArray = array of Integer;

  // One 24-byte entry in the directory.
  TDiskEntry = record
    Slot: Integer;
    Name: string;
    EntryType: Char;               // 'P' program, 'S' sample, 'D' drum set, 'O' overall
    Length: Integer;               // bytes, including the 60-byte file header
    StartBlock: Integer;
    ChainBlocks: Integer;
    ChainOk: Boolean;              // the allocation covers the declared length

    // Samples only, from the file's own 60-byte header.
    SampleCount: Int64;
    SampleRate: Integer;
    Tuning: Integer;               // 16ths of a semitone, C3 = 960
    LoopMode: Char;                // 'O' one-shot, 'L' loop, 'A' alternating
    LoopDirection: Char;
    LoopStart, LoopEnd, LoopLength: Int64;
    Loudness: Integer;             // signed

    // The C++'s default member initialisers.
    procedure Init;

    function NominalPitch: Integer;
    function FinePitch: Integer;
    function Seconds: Double;
  end;

  PDiskEntry = ^TDiskEntry;
  TDiskEntryArray = array of TDiskEntry;

  // One zone of a keygroup: which sample, and how it is trimmed.
  TDiskZone = record
    Name: string;
    ZonePointer: Integer;          // the C++'s `pointer`
    Fine: Integer;
    Transpose: Integer;            // signed
    Filter: Integer;
    Loudness: Integer;             // signed

    procedure Init;

    //
    // The zone's pitch offset in semitones: transpose and fine are ONE signed 16-bit
    // number, transpose the high byte and fine the low, counting SIXTEENTHS of a
    // semitone - the unit the sample header's own pitch is kept in.
    //
    // NOT transpose + fine/256, which is what this assumed until it was measured.
    // MEASURED 2026-09-27: DSKA0058 SEQ BASS, whose five keygroups carry (fine,
    // transpose) of (192,0), (80,0), (0,0), (144,-1) and (64,-1). The machine played
    // them +12, +5, 0, -7 and -12 semitones - all ten notes within 1.7 cents of that
    // reading - where the old one put some keygroups five semitones out. Across the
    // library the reading lands on -12, +24, +12, -5, +7 and sixteenth-step detunes,
    // which is what a programmer sets; read the old way, most are odd fractions.
    //
    function PitchOffset: Double;

    //
    // "2 SAMPLE" is what the panel leaves in a zone it is not using, and a pointer
    // of zero says the same thing. Reading those as a sample name is how the editor
    // came to show leftovers as though a second zone were loaded.
    //
    function InUse: Boolean;

    // The same field as ZonePointer, under the C++'s name.
    property Pointer_: Integer read ZonePointer write ZonePointer;
  end;

  // One 70-byte keygroup record.
  TDiskKeygroup = record
    Index: Integer;
    HighKey, LowKey: Integer;
    VelocitySwitch: Integer;

    VcaAttack, VcaDecay, VcaSustain, VcaRelease: Integer;
    VcfAttack, VcfDecay, VcfSustain, VcfRelease: Integer;
    VcfAmount: Integer;            // signed

    VelToFilter, KeyToFilter, VelToLoudness: Integer;
    VelToAttack, VelToRelease: Integer;

    //
    // WARP, bytes 12 to 14: a pitch bend at note-on that decays back to pitch. Byte 13
    // is the DEPTH and is signed; byte 12 is how far velocity scales it, with 0 meaning
    // always full; byte 14 is the time constant. See cal::warpRatio.
    //
    WarpVelocity, WarpDepth, WarpTime: Integer;

    //
    // Byte 19: which output the keygroup goes to. The panel value, which the byte
    // stores one lower - so ALL is -1, the default in 1617 of 1908 keygroups.
    //
    //     0 ALL,  1..8 MONO 1 to 8,  9 LEFT,  10 RIGHT
    //
    OutputPort: Integer;

    LfoDelay, LfoRate, LfoDepth: Integer;
    LfoAftertouchDepth, LfoModwheelDepth: Integer;

    Flags: Integer;

    Zone1, Zone2: TDiskZone;

    procedure Init;

    function ConstantPitch: Boolean;
    function LfoDesync: Boolean;
    function OneShot: Boolean;

    //
    // Bit 4: the ON/OFF beside Release on the velocity page, found by diffing a disk
    // saved either side of flipping it. It enables velToRelease - with it clear, every
    // note is released as though its velocity were 1, which is not the same as no
    // effect. Clear in all 1908 keygroups of the library.
    //
    function VelocityReleaseOn: Boolean;
    function HasSecondZone: Boolean;
  end;

  TDiskKeygroupArray = array of TDiskKeygroup;

  // Disk::NewSample
  TNewSample = record
    Name: string;
    Words12: TSmallIntArray;       // signed, -2048..2047; an odd last word is dropped
    Rate: Integer;
    RootNote: Integer;             // the key it plays at its own rate on
    Fine: Integer;
    LoopMode: Char;                // 'L' looped, 'O' one-shot, 'A' alternating
    LoopLength: Integer;           // words; -1 is the whole sample

    // The C++'s defaults: 40000, 60, 0, 'L', -1.
    procedure Init;
  end;

  // A programme's slot and where its records start in the arena (std::pair<int, int>).
  TSlotRecord = record
    Slot, Rec: Integer;
  end;
  TSlotRecordArray = array of TSlotRecord;

  //
  // An Akai S900/S950 floppy, in either density the S950 formats:
  //
  //     double density   800K  = 80 cylinders x 2 heads x  5 sectors of 1024 bytes
  //     high density    1600K  = 80 cylinders x 2 heads x 10 sectors of 1024 bytes
  //
  // Block 0 holds a 64-entry directory at 0x000 and a 16-bit allocation table at 0x600,
  // one entry per block - 800 on DD, 1600 on HD - so the header is 4 blocks on one and 5
  // on the other, and file data starts at headerBlocks(). The two are identical up to the
  // 800th entry (akaiutil's akai_fllhead_s and akai_flhhead_s). A file's blocks are a chain
  // through that table rather than a run, so a file is not contiguous and cannot be read
  // as one.
  //
  // The reading half of AkaiS950List, ported - and one narrow kind of writing.
  //
  // A keygroup's SETTINGS can be changed where they stand: an envelope time, a filter, an
  // LFO rate, a key range. Each is one byte at a fixed place in the programme, and changing
  // its value moves nothing else. That is all this writes. Adding or removing a file, a
  // keygroup or a sample stays in the Studio, where a human is watching - because that is
  // where the rules that make writing dangerous live: that the directory must stay
  // contiguous, and that zone pointers are positions that have to be recomputed rather
  // than shifted. A value edit touches neither, and setKeygroupParam refuses to write
  // anywhere but inside one keygroup record of one programme.
  //
  // The encodings are the C# Studio's, field for field - see KeygroupParam.
  //
  TS950Disk = class
  public
    const
      BlockSize  = 1024;
      DirOffset  = $000;
      DirEntries = 64;
      EntrySize  = 24;
      FatOffset  = $600;
      FatEnd     = $8000;          // end-of-chain marker
      HeaderSize = 60;             // per-file header before the payload

      ProgHeaderSize     = 38;
      KeygroupSize       = 70;
      KeygroupNameOffset = 24;     // zone 1's sample name
      KeygroupZoneStride = 22;     // zone 2's is 22 bytes further on

      DdBlocks = 800;
      HdBlocks = 1600;

  private
    const
      SampleRamBase       = $18000;
      LoopDescriptorBase  = $B6F4;
      ArenaDefault        = $C5F6;
      KeygroupChainOffset = 68;
      MaxKeygroups        = 64;

  private
    FSource: string;
    FImage: TBytes;
    FEntries: TDiskEntryArray;

    FFromHfe: Boolean;
    FBadCrcSectors, FMissingSectors: Integer;

    FRevision: Integer;
    FArenaBaseCache: Integer;      // mutable

    // Byte `offset` of a file, through its chain. False past the end of the file.
    function FileByteAt(const E: TDiskEntry; Offset: Integer; out At: NativeInt): Boolean;

    // the writing half's helpers
    class function NormaliseName(const AName: string): string; static;
    function AddFile(const AName: string; AType: Char; const Contents: TBytes;
                     MinSlot: Integer; out SlotOut: Integer; out Error: string): Boolean;
    procedure MakeRoomAt(Slot: Integer);
    procedure SetFat(Block, Value: Integer);
    procedure PutU16(At: NativeInt; Value: Integer);
    procedure PokeFile(const E: TDiskEntry; Offset: Integer; Value: Byte);

    // The keygroup arena: where each programme's records start, and how many there are.
    function ArenaBase: Integer;
    function ArenaRecords(out FirstBySlot: TSlotRecordArray): Integer;
    function SampleTableAddress: Integer;
    function ChainOf(const Prog: TBytes; Keygroup: Integer): Integer;

    function Fat(Block: Integer): Integer;
    function Chain(Start: Integer): TIntArray;
    procedure ParseDirectory;
    procedure ReadSampleHeader(var E: TDiskEntry);

    function TotalBlocks: Integer;

    function U32(At: NativeInt): Cardinal;
    function U16(At: NativeInt): Integer;

    class function CleanName(const B: TBytes; At: NativeInt): string; static;
    class function ParseZone(const Raw: TBytes; At: NativeInt): TDiskZone; static;

    // One sample, decoded and normalised, ready for a voice to read. The caller holds the
    // one reference, or gets nil.
    function SoundFor(const Sample: TDiskEntry): TS950Sound;

    // A hash of a sample file's bytes. See Sound::fingerprint.
    function FingerprintOf(const Sample: TDiskEntry): UInt64;

  public
    constructor Create;

    // ------------------------------------------------------------------ loading

    // Read an image from disk. False, with `error` set, if it is not one.
    function LoadFile(const Path: string; out Error: string): Boolean;

    // The same from bytes already in hand - which is how a plugin will restore one
    // out of a host's saved project. The bytes are copied.
    function LoadBytes(const AName: string; const Bytes: TBytes; out Error: string): Boolean;

    property Name: string read FSource;
    property Entries: TDiskEntryArray read FEntries;

    // True if this came out of an .hfe rather than a plain sector image.
    function WasHfe: Boolean;

    //
    // The decoded sectors, as a plain image.
    //
    // For putting a disk somewhere it can be got back from - a host's saved project,
    // say. Always the sectors, never the .hfe it may have arrived in: decoding is
    // deterministic and one-way, so keeping the result means a reload does no MFM work
    // and cannot come out differently.
    //
    // The disk's own array, as the C++ returns a const reference: read it, do not write
    // to it (Copy it to keep a snapshot).
    //
    function Image: TBytes;

    //
    // How the recovery went, for an .hfe. Both zero for a plain image.
    //
    // Worth showing rather than hiding: an archived floppy is thirty years old, and a
    // disk that reads with three bad sectors is a different thing from one that reads
    // cleanly - especially if it is about to be played into a recording.
    //
    property BadCrcSectors: Integer read FBadCrcSectors;
    property MissingSectors: Integer read FMissingSectors;

    // The entry of that name and type, or nil.
    function Find(const AName: string; AType: Char): PDiskEntry;

    // ------------------------------------------------------------------ reading

    // A file's bytes, following its chain through the allocation table.
    function ReadFile(const E: TDiskEntry): TBytes;

    // A sample as stored: signed 12-bit values, -2048..2047.
    function SampleWords12(const E: TDiskEntry): TSmallIntArray;

    // A program's keygroup records, in order.
    function Keygroups(const Prog: TDiskEntry): TDiskKeygroupArray;

    class function KeygroupCount(const Prog: TDiskEntry): Integer; static;

    // -------------------------------------------------------- ready to be played

    //
    // Turn a programme into something the engine can play.
    //
    // The same job Instrument.SetProgram does in the C# editor, and the same rule at
    // the centre of it: the two zones of a keygroup are velocity ALTERNATIVES, not
    // layers. They split the range at the switch, and a switch of 128 leaves zone 1 the
    // whole of it, which is how the panel turns the second zone off.
    //
    //
    // `reuse` is the patch this one replaces, if any. A sample it already holds is taken
    // from it by name rather than decoded again - which makes rebuilding after a settings
    // edit cheap, and, more to the point, keeps the SAME sound object: Voice::adopt only
    // follows a change onto a held note when the sound it is playing is the one it had.
    // An edit that decoded afresh would leave every held note deaf to it.
    //
    // Nil if `program` is not a programme. The caller owns the one reference returned
    // (ReleasePatch it); the patch holds a reference to each of its sounds.
    //
    function BuildPatch(const Prog: TDiskEntry; Reuse: TS950Patch = nil): TS950Patch;

    // ---------------------------------------------------------- changing settings

    //
    // One keygroup setting, as the panel shows it.
    //
    // A filter envelope an S900 left blank - bytes 34 to 37 all spaces - reads as the
    // flat one the engine gives it, 0/0/99/0, rather than as 32s.
    //
    function GetKeygroupParam(const Prog: TDiskEntry; Keygroup: Integer; P: TKeygroupParam): Integer;

    //
    // Change one keygroup setting, in place. The value is clamped to the panel's range.
    //
    // Writes one byte, or for a blank filter envelope all four of it: the first edit to
    // any stage writes the flat 0/0/99/0 under the one being set, as the Studio does, so
    // the envelope becomes a real one rather than three spaces and a number.
    //
    // False if nothing could be written - no such keygroup, or the programme's chain
    // does not reach that far. True otherwise, whether or not the value changed.
    //
    function SetKeygroupParam(const Prog: TDiskEntry; Keygroup: Integer; P: TKeygroupParam;
                              Value: Integer): Boolean;

    // True if an S900 left this keygroup's filter envelope blank.
    function VcfBlank(const Prog: TDiskEntry; Keygroup: Integer): Boolean;

    // ----------------------------------------------------------- making a disk

    //
    // The second kind of writing: building a disk from nothing.
    //
    // A blank S950 disk is 800K of zeroes - an empty directory and an empty allocation
    // table ARE the format's idea of formatted - and onto it go samples and programmes,
    // in that order of concern: samples first, so their RAM addresses follow on from one
    // another in directory order, then programmes, which are put BEFORE them in the
    // directory so the P / S grouping every library disk has survives.
    //
    // This is the C# library's AddSample / AddProgram / RebuildPointers, ported, and it
    // is what makes the plugin's Synth page an S950 rather than a synthesiser: a sound
    // designed there is a disk, and a disk goes to the real machine. The C# path has
    // been played on one; this port is held to it by reading its disks with both readers.
    //
    // Every rule the hardware turned out to care about is here:
    //   - the directory is contiguous, or the machine reads to the first gap and stops;
    //   - a zone's pointer is the sample's POSITION, table + 70 x index, not an address;
    //   - the programme header restates the layout - where its keygroups load and how
    //     many there are - and the machine believes the header;
    // and rebuildPointers() derives all of them from the directory rather than shifting
    // anything, which is the only way they cannot drift.
    //

    // 800K of nothing, ready to be written to - or 1600K, with highDensity. A new object,
    // which the caller frees.
    class function Blank(const AName: string = 'NEW DISK'; HighDensity: Boolean = False): TS950Disk; static;

    // `a = b`: everything copied, the image and the entries deep.
    procedure Assign(Source: TS950Disk);

    // Add a sample after the last one. False, with `error`, if the disk is full or
    // the name is taken.
    function AddSample(const S: TNewSample; out Error: string): Boolean;

    //
    // Add a programme of `keygroups` template keygroups, each across the whole
    // keyboard with an empty second zone, after the last programme. The caller then
    // shapes them with setKeygroupParam and setZoneSample, and calls rebuildPointers()
    // once when the disk is complete.
    //
    function AddProgram(const AName: string; AKeygroups: Integer; out Error: string): Boolean;

    // Name the sample a keygroup's zone plays (0 soft, 1 hard). Its pointer follows.
    function SetZoneSample(const Prog: TDiskEntry; Keygroup, Zone: Integer; const Sample: string): Boolean;

    //
    // Rewrite every chain pointer, zone pointer and programme header from the
    // directory. Returns how many bytes changed. Call after adding anything; it is
    // what the C# calls after every structural edit, and what the machine needs.
    //
    function RebuildPointers: Integer;

    // The entry in a directory slot, or nil.
    function EntryInSlot(Slot: Integer): PDiskEntry;

    // A sample's position among the samples, in directory order, or -1.
    function SampleIndex(const AName: string): Integer;

    // The name a file of this name would be given: up to 10 characters, upper-cased.
    class function NormaliseNameFor(const AName: string): string; static;

    // Bumped by every write, so a caller can tell a disk has changed since it looked.
    function Revision: Integer;

    // Where byte `offset` of keygroup `keygroup` is in the image. False if nowhere.
    // Public so a check can say exactly which bytes an edit was allowed to touch.
    function KeygroupByteAt(const Prog: TDiskEntry; Keygroup, Offset: Integer; out At: NativeInt): Boolean;

    // A high-density (1600K) disk rather than a double-density (800K) one.
    function IsHighDensity: Boolean;

    // The directory-and-FAT header, and where file data starts: 4 blocks on DD, 5 on HD.
    function HeaderBlocks: Integer;
  end;

implementation

uses
  S950Hfe;

const
  UnusedZone = '2 SAMPLE';

//
// The C++'s static_cast<int> of a wider integer, and its int arithmetic where a hostile
// header can overflow it: the low 32 bits, as two's complement - what the C++ does in
// practice. Arithmetic rather than a cast, so no range check fires.
//
function Wrap32(X: Int64): Integer;
var
  L: Int64;
begin
  L := X and $FFFFFFFF;
  if L >= $80000000 then
    L := L - $100000000;
  Result := L;
end;

// static_cast<signed char> of a byte.
function Signed8(B: Integer): Integer; inline;
begin
  if B >= 128 then
    Result := B - 256
  else
    Result := B;
end;

// static_cast<short> of a 16-bit value.
function Signed16(W: Integer): Integer; inline;
begin
  if W >= 32768 then
    Result := W - 65536
  else
    Result := W;
end;

// std::toupper in the C locale.
function UpperC(C: Integer): Integer; inline;
begin
  if (C >= Ord('a')) and (C <= Ord('z')) then
    Result := C - 32
  else
    Result := C;
end;

function MaxI64(A, B: Int64): Int64; inline;
begin
  if A < B then
    Result := B
  else
    Result := A;
end;

function MinI64(A, B: Int64): Int64; inline;
begin
  if B < A then
    Result := B
  else
    Result := A;
end;

{ TDiskEntry }

procedure TDiskEntry.Init;
begin
  Slot := 0;
  Name := '';
  EntryType := #0;
  Length := 0;
  StartBlock := 0;
  ChainBlocks := 0;
  ChainOk := False;
  SampleCount := 0;
  SampleRate := 0;
  Tuning := 0;
  LoopMode := 'O';
  LoopDirection := 'N';
  LoopStart := 0;
  LoopEnd := 0;
  LoopLength := 0;
  Loudness := 0;
end;

function TDiskEntry.NominalPitch: Integer;
begin
  Result := Tuning div 16;
end;

function TDiskEntry.FinePitch: Integer;
begin
  Result := Tuning mod 16;
end;

function TDiskEntry.Seconds: Double;
var
  Count: Double;
begin
  if SampleRate > 0 then
  begin
    Count := SampleCount;
    Result := Count / SampleRate;
  end
  else
    Result := 0.0;
end;

{ TDiskZone }

procedure TDiskZone.Init;
begin
  Name := '';
  ZonePointer := 0;
  Fine := 0;
  Transpose := 0;
  Filter := 99;
  Loudness := 0;
end;

function TDiskZone.PitchOffset: Double;
begin
  Result := (Transpose * 256 + Fine) / 16.0;
end;

function TDiskZone.InUse: Boolean;
begin
  Result := (Name <> '') and (Name <> UnusedZone) and (ZonePointer <> 0);
end;

{ TDiskKeygroup }

procedure TDiskKeygroup.Init;
begin
  Index := 0;
  HighKey := 127;
  LowKey := 0;
  VelocitySwitch := 128;
  VcaAttack := 0;
  VcaDecay := 0;
  VcaSustain := 99;
  VcaRelease := 0;
  VcfAttack := 0;
  VcfDecay := 0;
  VcfSustain := 99;
  VcfRelease := 0;
  VcfAmount := 0;
  VelToFilter := 0;
  KeyToFilter := 0;
  VelToLoudness := 0;
  VelToAttack := 0;
  VelToRelease := 0;
  WarpVelocity := 0;
  WarpDepth := 0;
  WarpTime := 0;
  OutputPort := 0;
  LfoDelay := 0;
  LfoRate := 0;
  LfoDepth := 0;
  LfoAftertouchDepth := 0;
  LfoModwheelDepth := 0;
  Flags := 0;
  Zone1.Init;
  Zone2.Init;
end;

function TDiskKeygroup.ConstantPitch: Boolean;
begin
  Result := (Flags and $01) <> 0;
end;

function TDiskKeygroup.LfoDesync: Boolean;
begin
  Result := (Flags and $04) <> 0;
end;

function TDiskKeygroup.OneShot: Boolean;
begin
  Result := (Flags and $08) <> 0;
end;

function TDiskKeygroup.VelocityReleaseOn: Boolean;
begin
  Result := (Flags and $10) <> 0;
end;

function TDiskKeygroup.HasSecondZone: Boolean;
begin
  Result := Zone2.InUse;
end;

{ TNewSample }

procedure TNewSample.Init;
begin
  Name := '';
  Words12 := nil;
  Rate := 40000;
  RootNote := 60;
  Fine := 0;
  LoopMode := 'L';
  LoopLength := -1;
end;

// ---------------------------------------------------------------------------- loading

constructor TS950Disk.Create;
begin
  inherited Create;
  FArenaBaseCache := -1;
end;

function TS950Disk.LoadFile(const Path: string; out Error: string): Boolean;
var
  H: THandle;
  Size: Int64;
  Bytes: TBytes;
  Done, Got: Integer;
begin
  Error := '';
  Result := False;

  H := FileOpen(Path, fmOpenRead or fmShareDenyNone);
  if H = THandle(-1) then
  begin
    Error := 'could not open ' + Path;
    Exit;
  end;

  Bytes := nil;
  Size := FileSeek(H, Int64(0), 2);
  FileSeek(H, Int64(0), 0);
  if Size > 0 then
  begin
    SetLength(Bytes, Size);
    Done := 0;
    while Done < Size do
    begin
      if Size - Done > $40000000 then
        Got := FileRead(H, Bytes[Done], $40000000)
      else
        Got := FileRead(H, Bytes[Done], Integer(Size - Done));
      if Got <= 0 then
        Break;
      Inc(Done, Got);
    end;
    SetLength(Bytes, Done);
  end;
  FileClose(H);

  Result := LoadBytes(Path, Bytes, Error);
end;

function TS950Disk.LoadBytes(const AName: string; const Bytes: TBytes; out Error: string): Boolean;
var
  Recovered, Taken: TBytes;
  Decoded: Boolean;
begin
  Error := '';
  Result := False;

  FFromHfe := False;
  FBadCrcSectors := 0;
  FMissingSectors := 0;

  Taken := Bytes;
  Decoded := False;

  //
  // An .hfe is not a picture of the sectors - it is a recording of the flux a floppy
  // controller would see reading them. Getting an image out of one means doing what
  // the controller does, which is what Hfe.cpp is for.
  //
  if HfeLooksLikeHfe(Taken) then
  begin
    Recovered := HfeExtract(Taken, FBadCrcSectors, FMissingSectors);

    if System.Length(Recovered) = 0 then
    begin
      Error := 'that HFE image could not be decoded';
      Exit;
    end;

    FFromHfe := True;
    Taken := Recovered;
    Decoded := True;
  end;

  if (System.Length(Taken) <> 819200) and (System.Length(Taken) <> 1638400) then
  begin
    Error := 'not an 800K or 1600K image (' + IntToStr(System.Length(Taken)) + ' bytes)';
    Exit;
  end;

  FSource := AName;
  // The C++ moves its by-value vector in; a Pascal dynamic array is shared, not copied,
  // on assignment, so the caller's bytes are copied rather than aliased.
  if Decoded then
    FImage := Taken
  else
    FImage := Copy(Bytes);
  ParseDirectory;
  Result := True;
end;

function TS950Disk.U16(At: NativeInt): Integer;
begin
  if At + 1 >= System.Length(FImage) then
  begin
    Result := 0;
    Exit;
  end;
  Result := FImage[At] or (FImage[At + 1] shl 8);
end;

function TS950Disk.U32(At: NativeInt): Cardinal;
begin
  if At + 3 >= System.Length(FImage) then
  begin
    Result := 0;
    Exit;
  end;
  Result := Cardinal(FImage[At])
         or (Cardinal(FImage[At + 1]) shl 8)
         or (Cardinal(FImage[At + 2]) shl 16)
         or (Cardinal(FImage[At + 3]) shl 24);
end;

class function TS950Disk.CleanName(const B: TBytes; At: NativeInt): string;
var
  I, N: Integer;
  C: Byte;
begin
  SetLength(Result, 10);

  for I := 0 to 9 do
  begin
    C := B[At + I];
    if (C >= $20) and (C < $7F) then
      Result[I + 1] := Char(C)
    else
      Result[I + 1] := ' ';
  end;

  N := 10;
  while (N > 0) and (Result[N] = ' ') do
    Dec(N);
  SetLength(Result, N);
end;

function TS950Disk.Fat(Block: Integer): Integer;
var
  At: NativeInt;
begin
  At := NativeInt(FatOffset) + NativeInt(Block) * 2;
  if At + 1 >= System.Length(FImage) then
  begin
    Result := FatEnd;
    Exit;
  end;
  Result := U16(At);
end;

//
// A file's blocks, in order.
//
// `seen` is not caution for its own sake: a damaged allocation table can point a block
// at itself or back into the chain, and without it this would not return.
//
function TS950Disk.Chain(Start: Integer): TIntArray;
var
  Seen: array of Boolean;
  B, N, Total: Integer;
begin
  Total := TotalBlocks;
  SetLength(Seen, Total);
  if Total > 0 then
    FillChar(Seen[0], Total, 0);

  Result := nil;
  N := 0;

  B := Start;
  while (B <> FatEnd) and (B >= 0) and (B < Total) and not Seen[B] do
  begin
    Seen[B] := True;
    if N = System.Length(Result) then
      SetLength(Result, N * 2 + 16);
    Result[N] := B;
    Inc(N);
    B := Fat(B);
  end;

  SetLength(Result, N);
end;

procedure TS950Disk.ParseDirectory;
var
  I, Len, Start, Needed, N: Integer;
  O: NativeInt;
  T: Char;
  E: TDiskEntry;
begin
  FEntries := nil;
  N := 0;

  for I := 0 to DirEntries - 1 do
  begin
    O := NativeInt(DirOffset) + NativeInt(I) * EntrySize;
    if O + EntrySize > System.Length(FImage) then
      Break;
    if FImage[O] = $00 then
      Continue;                                           // free slot

    T := Char(FImage[O + 16]);
    if (T <> 'P') and (T <> 'S') and (T <> 'D') and (T <> 'O') then
      Continue;                                           // not a file entry

    Len := FImage[O + 17]
        or (FImage[O + 18] shl 8)
        or (FImage[O + 19] shl 16);
    Start := U16(O + 20);

    if (Start < 0) or (Start >= TotalBlocks) then
      Continue;

    E.Init;
    E.Slot := I;
    E.Name := CleanName(FImage, O);
    E.EntryType := T;
    E.Length := Len;
    E.StartBlock := Start;

    E.ChainBlocks := System.Length(Chain(Start));
    Needed := (Len + BlockSize - 1) div BlockSize;
    E.ChainOk := E.ChainBlocks >= Needed;

    if T = 'S' then
      ReadSampleHeader(E);

    SetLength(FEntries, N + 1);
    FEntries[N] := E;
    Inc(N);
  end;
end;

procedure TS950Disk.ReadSampleHeader(var E: TDiskEntry);
var
  O: NativeInt;
begin
  O := NativeInt(E.StartBlock) * BlockSize;
  if O + HeaderSize > System.Length(FImage) then
    Exit;

  E.SampleCount := U32(O + $10);
  E.SampleRate := U16(O + $14);
  E.Tuning := U16(O + $16);
  E.Loudness := Signed16(U16(O + $18));
  E.LoopMode := Char(FImage[O + $1A]);
  E.LoopEnd := U32(O + $1C);
  E.LoopStart := U32(O + $20);
  E.LoopLength := U32(O + $24);
  E.LoopDirection := Char(FImage[O + $2B]);
end;

function TS950Disk.Find(const AName: string; AType: Char): PDiskEntry;
var
  I: Integer;
begin
  for I := 0 to High(FEntries) do
    if (FEntries[I].EntryType = AType) and (FEntries[I].Name = AName) then
    begin
      Result := @FEntries[I];
      Exit;
    end;

  Result := nil;
end;

function TS950Disk.WasHfe: Boolean;
begin
  Result := FFromHfe;
end;

function TS950Disk.Image: TBytes;
begin
  Result := FImage;
end;

function TS950Disk.Revision: Integer;
begin
  Result := FRevision;
end;

function TS950Disk.TotalBlocks: Integer;
begin
  Result := System.Length(FImage) div BlockSize;
end;

function TS950Disk.IsHighDensity: Boolean;
begin
  Result := TotalBlocks > DdBlocks;
end;

function TS950Disk.HeaderBlocks: Integer;
begin
  if IsHighDensity then
    Result := 5
  else
    Result := 4;
end;

procedure TS950Disk.Assign(Source: TS950Disk);
begin
  if (Source = nil) or (Source = Self) then
    Exit;

  FSource := Source.FSource;
  FImage := Copy(Source.FImage);
  FEntries := Copy(Source.FEntries);
  FFromHfe := Source.FFromHfe;
  FBadCrcSectors := Source.FBadCrcSectors;
  FMissingSectors := Source.FMissingSectors;
  FRevision := Source.FRevision;
  FArenaBaseCache := Source.FArenaBaseCache;
end;

// ---------------------------------------------------------------- changing settings

// In the order of the enum. The ranges and kinds are the Studio's KeygroupEditor.
const
  ParamTable: array[TKeygroupParam] of TKeygroupParamInfo = (
    (Name: 'High key';             Offset: 0;  Lo: 0;   Hi: 127; Kind: pkUnsigned; Mask: 0),
    (Name: 'Low key';              Offset: 1;  Lo: 0;   Hi: 127; Kind: pkUnsigned; Mask: 0),
    (Name: 'Velocity switch';      Offset: 2;  Lo: 1;   Hi: 128; Kind: pkUnsigned; Mask: 0),
    (Name: 'VCA attack';           Offset: 3;  Lo: 0;   Hi: 99;  Kind: pkUnsigned; Mask: 0),
    (Name: 'VCA decay';            Offset: 4;  Lo: 0;   Hi: 99;  Kind: pkUnsigned; Mask: 0),
    (Name: 'VCA sustain';          Offset: 5;  Lo: 0;   Hi: 99;  Kind: pkUnsigned; Mask: 0),
    (Name: 'VCA release';          Offset: 6;  Lo: 0;   Hi: 99;  Kind: pkUnsigned; Mask: 0),
    (Name: 'Velocity to filter';   Offset: 7;  Lo: 0;   Hi: 99;  Kind: pkUnsigned; Mask: 0),
    (Name: 'Key to filter';        Offset: 8;  Lo: 0;   Hi: 99;  Kind: pkUnsigned; Mask: 0),
    (Name: 'Velocity to attack';   Offset: 9;  Lo: 0;   Hi: 99;  Kind: pkUnsigned; Mask: 0),
    (Name: 'Velocity to release';  Offset: 10; Lo: -50; Hi: 50;  Kind: pkSigned;   Mask: 0),
    (Name: 'Velocity to loudness'; Offset: 11; Lo: 0;   Hi: 99;  Kind: pkUnsigned; Mask: 0),
    (Name: 'Warp velocity';        Offset: 12; Lo: 0;   Hi: 99;  Kind: pkUnsigned; Mask: 0),
    (Name: 'Warp depth';           Offset: 13; Lo: -50; Hi: 50;  Kind: pkSigned;   Mask: 0),
    (Name: 'Warp time';            Offset: 14; Lo: 0;   Hi: 99;  Kind: pkUnsigned; Mask: 0),
    (Name: 'LFO delay';            Offset: 15; Lo: 0;   Hi: 99;  Kind: pkUnsigned; Mask: 0),
    (Name: 'LFO rate';             Offset: 16; Lo: 0;   Hi: 99;  Kind: pkUnsigned; Mask: 0),
    (Name: 'LFO depth';            Offset: 17; Lo: 0;   Hi: 99;  Kind: pkUnsigned; Mask: 0),
    (Name: 'LFO from aftertouch';  Offset: 21; Lo: 0;   Hi: 50;  Kind: pkUnsigned; Mask: 0),
    (Name: 'LFO from modwheel';    Offset: 22; Lo: 0;   Hi: 50;  Kind: pkUnsigned; Mask: 0),
    (Name: 'Output';               Offset: 19; Lo: 0;   Hi: 10;  Kind: pkPort;     Mask: 0),
    (Name: 'VCF amount';           Offset: 23; Lo: -50; Hi: 50;  Kind: pkSigned;   Mask: 0),
    (Name: 'VCF attack';           Offset: 34; Lo: 0;   Hi: 99;  Kind: pkUnsigned; Mask: 0),
    (Name: 'VCF decay';            Offset: 35; Lo: 0;   Hi: 99;  Kind: pkUnsigned; Mask: 0),
    (Name: 'VCF sustain';          Offset: 36; Lo: 0;   Hi: 99;  Kind: pkUnsigned; Mask: 0),
    (Name: 'VCF release';          Offset: 37; Lo: 0;   Hi: 99;  Kind: pkUnsigned; Mask: 0),
    (Name: 'Soft fine';            Offset: 42; Lo: 0;   Hi: 255; Kind: pkUnsigned; Mask: 0),
    (Name: 'Soft transpose';       Offset: 43; Lo: -50; Hi: 50;  Kind: pkSigned;   Mask: 0),
    (Name: 'Soft filter';          Offset: 44; Lo: 0;   Hi: 99;  Kind: pkUnsigned; Mask: 0),
    (Name: 'Soft loudness';        Offset: 45; Lo: -50; Hi: 50;  Kind: pkSigned;   Mask: 0),
    (Name: 'Loud fine';            Offset: 64; Lo: 0;   Hi: 255; Kind: pkUnsigned; Mask: 0),
    (Name: 'Loud transpose';       Offset: 65; Lo: -50; Hi: 50;  Kind: pkSigned;   Mask: 0),
    (Name: 'Loud filter';          Offset: 66; Lo: 0;   Hi: 99;  Kind: pkUnsigned; Mask: 0),
    (Name: 'Loud loudness';        Offset: 67; Lo: -50; Hi: 50;  Kind: pkSigned;   Mask: 0),
    (Name: 'Constant pitch';       Offset: 18; Lo: 0;   Hi: 1;   Kind: pkBit;      Mask: $01),
    (Name: 'LFO desync';           Offset: 18; Lo: 0;   Hi: 1;   Kind: pkBit;      Mask: $04),
    (Name: 'One shot';             Offset: 18; Lo: 0;   Hi: 1;   Kind: pkBit;      Mask: $08),
    (Name: 'Velocity release on';  Offset: 18; Lo: 0;   Hi: 1;   Kind: pkBit;      Mask: $10));

// (The C++'s static_assert - one row per KeygroupParam, in order - is the array's index
// type here: the table cannot have a row too many or too few.)

function KeygroupParamInfo(P: TKeygroupParam): TKeygroupParamInfo;
begin
  Result := ParamTable[P];
end;

function IsVcfStage(P: TKeygroupParam): Boolean; inline;
begin
  Result := (P = kpVcfAttack) or (P = kpVcfDecay) or (P = kpVcfSustain) or (P = kpVcfRelease);
end;

function TS950Disk.FileByteAt(const E: TDiskEntry; Offset: Integer; out At: NativeInt): Boolean;
var
  Blocks: TIntArray;
  Bi: Integer;
begin
  At := 0;
  Result := False;

  if (Offset < 0) or (Offset >= E.Length) then
    Exit;

  Blocks := Chain(E.StartBlock);
  Bi := Offset div BlockSize;

  if Bi >= System.Length(Blocks) then
    Exit;

  At := NativeInt(Blocks[Bi]) * BlockSize + NativeInt(Offset mod BlockSize);

  Result := At < System.Length(FImage);
end;

//
// Mapped one byte at a time, never as a run: a programme is chained through the
// allocation table, and a 70-byte keygroup can straddle the end of one block and the
// start of another that is nowhere near it.
//
function TS950Disk.KeygroupByteAt(const Prog: TDiskEntry; Keygroup, Offset: Integer;
                                  out At: NativeInt): Boolean;
begin
  At := 0;
  Result := False;

  if (Prog.EntryType <> 'P') or (Offset < 0) or (Offset >= KeygroupSize) then
    Exit;

  if (Keygroup < 0) or (Keygroup >= KeygroupCount(Prog)) then
    Exit;

  Result := FileByteAt(Prog, ProgHeaderSize + Keygroup * KeygroupSize + Offset, At);
end;

function TS950Disk.VcfBlank(const Prog: TDiskEntry; Keygroup: Integer): Boolean;
var
  O: Integer;
  At: NativeInt;
begin
  Result := False;

  for O := 34 to 37 do
  begin
    if (not KeygroupByteAt(Prog, Keygroup, O, At)) or (FImage[At] <> $20) then
      Exit;
  end;

  Result := True;
end;

function TS950Disk.GetKeygroupParam(const Prog: TDiskEntry; Keygroup: Integer;
                                    P: TKeygroupParam): Integer;
var
  At: NativeInt;
  B: Integer;
begin
  if IsVcfStage(P) then
  begin
    if VcfBlank(Prog, Keygroup) then
    begin
      if P = kpVcfSustain then
        Result := 99
      else
        Result := 0;
      Exit;
    end;
  end;

  if not KeygroupByteAt(Prog, Keygroup, ParamTable[P].Offset, At) then
  begin
    Result := 0;
    Exit;
  end;

  B := FImage[At];

  case ParamTable[P].Kind of
    pkSigned:
      Result := Signed8(B);
    pkPort:
      if B = $FF then
        Result := 0
      else
        Result := B + 1;
    pkBit:
      if (B and ParamTable[P].Mask) <> 0 then
        Result := 1
      else
        Result := 0;
  else
    Result := B;
  end;
end;

function TS950Disk.SetKeygroupParam(const Prog: TDiskEntry; Keygroup: Integer;
                                    P: TKeygroupParam; Value: Integer): Boolean;
const
  Flat: array[0..3] of Byte = (0, 0, 99, 0);
var
  At, Stage: NativeInt;
  V, O, B: Integer;
begin
  Result := False;

  if not KeygroupByteAt(Prog, Keygroup, ParamTable[P].Offset, At) then
    Exit;

  if Value < ParamTable[P].Lo then
    V := ParamTable[P].Lo
  else if Value > ParamTable[P].Hi then
    V := ParamTable[P].Hi
  else
    V := Value;

  // A blank S900 filter envelope becomes the flat one first, as the Studio does it.
  if IsVcfStage(P) and VcfBlank(Prog, Keygroup) then
  begin
    for O := 0 to 3 do
    begin
      if KeygroupByteAt(Prog, Keygroup, 34 + O, Stage) then
        FImage[Stage] := Flat[O];
    end;
  end;

  B := FImage[At];

  case ParamTable[P].Kind of
    pkSigned:
      B := V and $FF;

    pkPort:
      if V = 0 then
        B := $FF
      else
        B := (V - 1) and $FF;

    pkBit:
      if V <> 0 then
        B := (B or ParamTable[P].Mask) and $FF
      else
        B := (B and not ParamTable[P].Mask) and $FF;

  else
    B := V and $FF;
  end;

  FImage[At] := B;
  Inc(FRevision);
  Result := True;
end;

// --------------------------------------------------------------------- making a disk

const
  // A programme's 38-byte header as a library disk has it: the name, then the load
  // address 0xC5F6 at 18..19, keygroup count at 23, MIDI programme at 26.
  ProgramTemplate: array[0..37] of Byte = (
    67, 79, 77, 32, 32, 32, 32, 32, 32, 32, 0, 32, 32, 32, 32, 32, 0, 0, 246, 197,
    0, 0, 255, 1, 0, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);

  // One keygroup as the machine writes a fresh one: the whole keyboard, no second
  // zone, every setting at the panel's default. The four VCF bytes are spaces, which
  // is "no filter envelope"; a caller that wants one writes all four.
  KeygroupTemplate: array[0..69] of Byte = (
    127, 24, 128, 0, 80, 99, 30, 10, 50, 0, 0, 30, 0, 0, 99, 64, 64, 0, 4, 255,
    0, 0, 50, 0, 84, 79, 78, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32,
    0, 211, 0, 0, 99, 0, 50, 32, 83, 65, 77, 80, 76, 69, 32, 32, 32, 32, 32, 32,
    32, 32, 0, 0, 0, 0, 99, 0, 0, 0);

function Trimmed(const S: string): string;
var
  First, Last: Integer;
begin
  Last := Length(S);
  while (Last > 0) and (S[Last] = ' ') do
    Dec(Last);
  First := 1;
  while (First <= Last) and (S[First] = ' ') do
    Inc(First);
  Result := Copy(S, First, Last - First + 1);
end;

function SameName(const A, B: string): Boolean;
var
  X, Y: string;
  I: Integer;
begin
  Result := False;
  X := Trimmed(A);
  Y := Trimmed(B);
  if Length(X) <> Length(Y) then
    Exit;
  for I := 1 to Length(X) do
    if UpperC(Ord(X[I])) <> UpperC(Ord(Y[I])) then
      Exit;
  Result := True;
end;

function Clip12(V: Integer): Integer;
begin
  if V > 2047 then
    V := 2047;
  if V < -2048 then
    V := -2048;
  Result := V and $FFF;
end;

// The sampler's RAM a sample takes: two bytes a word, in sixteens.
function RamSize(Words: Int64): Integer;
begin
  Result := Wrap32((2 * Words + 15) div 16 * 16);
end;

// 10-byte loop descriptors a sample consumes, by loop mode and whole 128K pages.
function LoopRecords(Words: Int64; LoopMode: Char): Integer;
var
  Pages: Integer;
begin
  Pages := Wrap32(2 * Words div 131072);
  case LoopMode of
    'L': Result := 3 + Pages;
    'A': Result := 3 * (1 + Pages);
  else
    Result := 2 + Pages;                                // 'O', one-shot
  end;
end;

procedure Put16(var B: TBytes; At: NativeInt; V: Integer);
begin
  B[At] := V and $FF;
  B[At + 1] := (V shr 8) and $FF;
end;

procedure Put32(var B: TBytes; At: NativeInt; V: Int64);
var
  I: Integer;
begin
  for I := 0 to 3 do
    B[At + I] := (V shr (8 * I)) and $FF;
end;

procedure PutName(var B: TBytes; At: NativeInt; const Clean: string);
var
  I: Integer;
begin
  for I := 0 to 9 do
    if I < Length(Clean) then
      B[At + I] := Ord(Clean[I + 1]) and $FF
    else
      B[At + I] := Ord(' ');
end;

class function TS950Disk.Blank(const AName: string; HighDensity: Boolean): TS950Disk;
var
  Error: string;
  Blocks: Integer;
  Zeroes: TBytes;
begin
  // An S950 disk is empty when its directory and allocation table are zero, so an
  // image of nothing but zeroes is already a formatted blank - on either density.
  Result := TS950Disk.Create;
  if HighDensity then
    Blocks := HdBlocks
  else
    Blocks := DdBlocks;
  SetLength(Zeroes, Blocks * BlockSize);
  FillChar(Zeroes[0], Blocks * BlockSize, 0);
  Result.LoadBytes(AName, Zeroes, Error);
end;

// A filename the S900/S950 will accept: up to 10 printable characters, upper-cased.
class function TS950Disk.NormaliseName(const AName: string): string;
var
  I, N, U: Integer;
begin
  SetLength(Result, 10);
  N := 0;
  for I := 1 to Length(AName) do
  begin
    if N = 10 then
      Break;
    U := UpperC(Ord(AName[I]));
    Inc(N);
    if (U >= $20) and (U < $7F) then
      Result[N] := Char(U)
    else
      Result[N] := ' ';
  end;
  while (N > 0) and (Result[N] = ' ') do
    Dec(N);
  SetLength(Result, N);
  if N = 0 then
    Result := 'UNTITLED';
end;

class function TS950Disk.NormaliseNameFor(const AName: string): string;
begin
  Result := NormaliseName(AName);
end;

procedure TS950Disk.SetFat(Block, Value: Integer);
begin
  PutU16(NativeInt(FatOffset) + NativeInt(Block) * 2, Value);
end;

procedure TS950Disk.PutU16(At: NativeInt; Value: Integer);
begin
  if At + 1 >= System.Length(FImage) then
    Exit;
  FImage[At] := Value and $FF;
  FImage[At + 1] := (Value shr 8) and $FF;
end;

procedure TS950Disk.PokeFile(const E: TDiskEntry; Offset: Integer; Value: Byte);
var
  At: NativeInt;
begin
  if FileByteAt(E, Offset, At) then
  begin
    FImage[At] := Value;
    Inc(FRevision);
  end;
end;

function TS950Disk.EntryInSlot(Slot: Integer): PDiskEntry;
var
  I: Integer;
begin
  for I := 0 to High(FEntries) do
    if FEntries[I].Slot = Slot then
    begin
      Result := @FEntries[I];
      Exit;
    end;
  Result := nil;
end;

function TS950Disk.SampleIndex(const AName: string): Integer;
var
  I, E: Integer;
begin
  I := 0;
  for E := 0 to High(FEntries) do
  begin
    if FEntries[E].EntryType <> 'S' then
      Continue;
    if SameName(FEntries[E].Name, AName) then
    begin
      Result := I;
      Exit;
    end;
    Inc(I);
  end;
  Result := -1;
end;

//
// A new file into free blocks and a directory slot at or after `minSlot`. Nothing
// already on the disk moves. Samples must land after the last sample, so their RAM
// addresses follow on; that is what minSlot is for.
//
function TS950Disk.AddFile(const AName: string; AType: Char; const Contents: TBytes;
                           MinSlot: Integer; out SlotOut: Integer; out Error: string): Boolean;
var
  Clean: string;
  I, B, Need, Slot, NFree: Integer;
  FreeBlocks: TIntArray;
  Off, From, Take, D: NativeInt;
begin
  Result := False;
  SlotOut := 0;
  Error := '';

  Clean := NormaliseName(AName);

  // Names are unique within a type, not across the disk: library images routinely
  // name a programme after the sample it plays.
  for I := 0 to High(FEntries) do
    if (FEntries[I].EntryType = AType) and SameName(FEntries[I].Name, Clean) then
    begin
      Error := '''' + Clean + ''' is already used by another file of that type';
      Exit;
    end;

  Need := MaxI(1, Wrap32((Int64(System.Length(Contents)) + BlockSize - 1) div BlockSize));
  SetLength(FreeBlocks, 0);
  NFree := 0;
  B := HeaderBlocks;
  while (B < TotalBlocks) and (NFree < Need) do
  begin
    if Fat(B) = 0 then
    begin
      SetLength(FreeBlocks, NFree + 1);
      FreeBlocks[NFree] := B;
      Inc(NFree);
    end;
    Inc(B);
  end;

  if NFree < Need then
  begin
    Error := 'not enough room on the disk: ' + IntToStr(Need) + ' blocks needed';
    Exit;
  end;

  Slot := -1;
  for I := MaxI(0, MinSlot) to DirEntries - 1 do
    if FImage[DirOffset + I * EntrySize] = $00 then
    begin
      Slot := I;
      Break;
    end;

  if Slot < 0 then
  begin
    Error := 'the directory is full: 64 files is the limit';
    Exit;
  end;

  for I := 0 to Need - 1 do
  begin
    Off := NativeInt(FreeBlocks[I]) * BlockSize;
    From := NativeInt(I) * BlockSize;
    if System.Length(Contents) > From then
      Take := System.Length(Contents) - From
    else
      Take := 0;
    if Take > BlockSize then
      Take := BlockSize;

    FillChar(FImage[Off], BlockSize, 0);
    if Take > 0 then
      Move(Contents[From], FImage[Off], Take);

    if I = Need - 1 then
      SetFat(FreeBlocks[I], FatEnd)
    else
      SetFat(FreeBlocks[I], FreeBlocks[I + 1]);
  end;

  D := NativeInt(DirOffset) + NativeInt(Slot) * EntrySize;
  FillChar(FImage[D], EntrySize, 0);
  PutName(FImage, D, Clean);
  FImage[D + 16] := Ord(AType) and $FF;
  FImage[D + 17] := System.Length(Contents) and $FF;
  FImage[D + 18] := (System.Length(Contents) shr 8) and $FF;
  FImage[D + 19] := (System.Length(Contents) shr 16) and $FF;
  PutU16(D + 20, FreeBlocks[0]);

  Inc(FRevision);
  ParseDirectory;
  SlotOut := Slot;
  Result := True;
end;

// Open a directory slot by moving every later entry up one. Needs a free slot.
procedure TS950Disk.MakeRoomAt(Slot: Integer);
var
  I: Integer;
begin
  for I := DirEntries - 1 downto Slot + 1 do
    Move(FImage[DirOffset + (I - 1) * EntrySize], FImage[DirOffset + I * EntrySize], EntrySize);

  FillChar(FImage[DirOffset + Slot * EntrySize], EntrySize, 0);
  Inc(FRevision);
  ParseDirectory;
end;

function TS950Disk.AddSample(const S: TNewSample; out Error: string): Boolean;
var
  N, Ram, Ptr, LastSlot, Mem, Half, I, A, B, Slot: Integer;
  H: NativeInt;
  FileBytes: TBytes;
  Clean: string;
  LoopLength: Integer;
  DataAt: NativeInt;
begin
  Result := False;
  Error := '';

  N := System.Length(S.Words12) and not 1;                    // the packing works in pairs
  if N < 2 then
  begin
    Error := 'there is no audio to add';
    Exit;
  end;

  //
  // The RAM address and the loop-descriptor pointer follow on from the last sample
  // already there - which is why a new sample has to land after it in the directory.
  // The header is the only place either is written down.
  //
  Ram := SampleRamBase;
  Ptr := LoopDescriptorBase;
  LastSlot := -1;
  for I := 0 to High(FEntries) do
  begin
    if (FEntries[I].EntryType <> 'S') or (FEntries[I].Slot <= LastSlot) then
      Continue;

    H := NativeInt(FEntries[I].StartBlock) * BlockSize;
    Mem := FImage[H + $36] or (FImage[H + $37] shl 8) or (FImage[H + $38] shl 16);

    Ram := Wrap32(Int64(Mem) + RamSize(FEntries[I].SampleCount));
    Ptr := Wrap32(Int64(U16(H + $28)) + 10 * Int64(LoopRecords(FEntries[I].SampleCount, FEntries[I].LoopMode)));
    LastSlot := FEntries[I].Slot;
  end;

  // The 12-bit split-nibble packing of section 6.2, exactly as the C# writes it.
  Half := N div 2;
  SetLength(FileBytes, HeaderSize + N + Half);
  FillChar(FileBytes[0], System.Length(FileBytes), 0);
  DataAt := HeaderSize;

  for I := 0 to Half - 1 do
  begin
    A := Clip12(S.Words12[I]);
    B := Clip12(S.Words12[Half + I]);

    FileBytes[DataAt + 2 * I] := (((A and $0F) shl 4) or (B and $0F)) and $FF;
    FileBytes[DataAt + 2 * I + 1] := (A shr 4) and $FF;
    FileBytes[DataAt + N + I] := (B shr 4) and $FF;
  end;

  Clean := NormaliseName(S.Name);
  PutName(FileBytes, 0, Clean);

  if S.LoopMode = 'O' then
    LoopLength := MinI(N, 2000)
  else if S.LoopLength < 0 then
    LoopLength := N
  else
    LoopLength := MinI(S.LoopLength, N);

  Put32(FileBytes, $10, N);
  Put16(FileBytes, $14, S.Rate);
  Put16(FileBytes, $16, S.RootNote * 16 + S.Fine);
  Put16(FileBytes, $18, 0);                                   // loudness
  FileBytes[$1A] := Ord(S.LoopMode) and $FF;
  Put32(FileBytes, $1C, N);                                   // end marker
  Put32(FileBytes, $20, 0);                                   // start marker
  Put32(FileBytes, $24, LoopLength);
  Put16(FileBytes, $28, Ptr);
  FileBytes[$2B] := Ord('N');                                 // loop direction
  FileBytes[$36] := Ram and $FF;
  FileBytes[$37] := (Ram shr 8) and $FF;
  FileBytes[$38] := (Ram shr 16) and $FF;

  Slot := 0;
  Result := AddFile(Clean, 'S', FileBytes, LastSlot + 1, Slot, Error);
end;

function TS950Disk.AddProgram(const AName: string; AKeygroups: Integer; out Error: string): Boolean;
var
  Body, Raw: TBytes;
  Clean: string;
  Taken: array[0..127] of Boolean;
  I, K, Z, Number, Slot, Landed: Integer;
  Kg, Zone: NativeInt;
begin
  Result := False;
  Error := '';

  if (AKeygroups < 1) or (AKeygroups > MaxKeygroups) then
  begin
    Error := 'a programme holds 1 to 64 keygroups';
    Exit;
  end;

  SetLength(Body, ProgHeaderSize + AKeygroups * KeygroupSize);
  FillChar(Body[0], System.Length(Body), 0);
  Move(ProgramTemplate[0], Body[0], SizeOf(ProgramTemplate));

  // The file repeats its own name in bytes 0..9, and that copy is what the S950 puts
  // on its display, not the directory entry.
  Clean := NormaliseName(AName);
  PutName(Body, 0, Clean);
  Body[23] := AKeygroups;

  // the lowest MIDI programme number nothing on the disk is using
  begin
    for I := 0 to 127 do
      Taken[I] := False;
    for I := 0 to High(FEntries) do
      if FEntries[I].EntryType = 'P' then
      begin
        Raw := ReadFile(FEntries[I]);
        if System.Length(Raw) > 26 then
          Taken[Raw[26] and $7F] := True;
      end;
    Number := 0;
    while (Number < 127) and Taken[Number] do
      Inc(Number);
    Body[26] := Number;
  end;

  for K := 0 to AKeygroups - 1 do
  begin
    Kg := ProgHeaderSize + K * KeygroupSize;
    Move(KeygroupTemplate[0], Body[Kg], SizeOf(KeygroupTemplate));

    Body[Kg + 0] := 127;                                      // high key
    Body[Kg + 1] := 0;                                        // low key
    Body[Kg + KeygroupChainOffset] := 0;                      // rebuildPointers fills these
    Body[Kg + KeygroupChainOffset + 1] := 0;

    // Both zones empty: "2 SAMPLE" with a zero pointer is how the library marks
    // an unused zone, and what the Studio's ClearZone writes.
    for Z := 0 to 1 do
    begin
      Zone := Kg + KeygroupNameOffset + Z * KeygroupZoneStride;
      PutName(Body, Zone, UnusedZone);
      Body[Zone + 16] := 0;
      Body[Zone + 17] := 0;
    end;
  end;

  // After the last programme, so the P / S grouping survives - which means opening a
  // slot if samples already sit there.
  Slot := 0;
  for I := 0 to High(FEntries) do
    if FEntries[I].EntryType = 'P' then
      Slot := FEntries[I].Slot + 1;

  if Slot < System.Length(FEntries) then
  begin
    if System.Length(FEntries) >= DirEntries then
    begin
      Error := 'the directory is full: 64 files is the limit';
      Exit;
    end;
    MakeRoomAt(Slot);
  end;

  Landed := 0;
  if not AddFile(Clean, 'P', Body, Slot, Landed, Error) then
    Exit;

  RebuildPointers;       // one more programme moves the sample table
  Result := True;
end;

function TS950Disk.SetZoneSample(const Prog: TDiskEntry; Keygroup, Zone: Integer;
                                 const Sample: string): Boolean;
var
  Clean: string;
  At, I, Index, Ptr: Integer;
begin
  Result := False;
  if (Prog.EntryType <> 'P') or (Zone < 0) or (Zone > 1) then
    Exit;
  if (Keygroup < 0) or (Keygroup >= KeygroupCount(Prog)) then
    Exit;

  Clean := NormaliseName(Sample);
  At := ProgHeaderSize + Keygroup * KeygroupSize + KeygroupNameOffset + Zone * KeygroupZoneStride;

  for I := 0 to 9 do
    if I < System.Length(Clean) then
      PokeFile(Prog, At + I, Ord(Clean[I + 1]) and $FF)
    else
      PokeFile(Prog, At + I, Ord(' '));

  // The pointer is the sample's POSITION in the descriptor table, not an address.
  Index := SampleIndex(Clean);
  if Index >= 0 then
    Ptr := SampleTableAddress + KeygroupSize * Index
  else
    Ptr := 0;

  PokeFile(Prog, At + 16, Ptr and $FF);
  PokeFile(Prog, At + 17, (Ptr shr 8) and $FF);
  Result := True;
end;

// ------------------------------------------------------------- the keygroup arena

function TS950Disk.ChainOf(const Prog: TBytes; Keygroup: Integer): Integer;
var
  At: NativeInt;
begin
  At := NativeInt(ProgHeaderSize) + NativeInt(Keygroup) * KeygroupSize + KeygroupChainOffset;
  if At + 1 >= System.Length(Prog) then
  begin
    Result := 0;
    Exit;
  end;
  Result := Prog[At] or (Prog[At + 1] shl 8);
end;

//
// Programmes are packed in directory order with one empty 70-byte record between
// consecutive ones. That predicts every chain pointer and every table base on all 98
// library disks that have them, exactly.
//
function TS950Disk.ArenaRecords(out FirstBySlot: TSlotRecordArray): Integer;
var
  I, N, Rec: Integer;
begin
  FirstBySlot := nil;
  N := 0;
  Rec := 0;
  for I := 0 to High(FEntries) do
  begin
    if FEntries[I].EntryType <> 'P' then
      Continue;
    SetLength(FirstBySlot, N + 1);
    FirstBySlot[N].Slot := FEntries[I].Slot;
    FirstBySlot[N].Rec := Rec;
    Inc(N);
    Rec := Rec + KeygroupCount(FEntries[I]) + 1;
  end;
  Result := MaxI(0, Rec - 1);
end;

type
  // The votes for a base: std::vector<std::pair<int, int>>.
  TVote = record
    Value, Count: Integer;
  end;
  TVoteArray = array of TVote;

// One vote for `B`; the count it now has.
function Vote(var Votes: TVoteArray; B: Integer): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(Votes) do
    if Votes[I].Value = B then
    begin
      Inc(Votes[I].Count);
      Result := Votes[I].Count;
    end;
  if Result = 0 then
  begin
    SetLength(Votes, Length(Votes) + 1);
    Votes[High(Votes)].Value := B;
    Votes[High(Votes)].Count := 1;
    Result := 1;
  end;
end;

//
// Where the arena starts. Nothing stores it, so it is read back from the zone
// pointers - the ones the sampler follows - and only from the keygroup chains when a
// disk has no samples to point at; a blank disk gets the value 97 of the library's 100
// disks start at. Captured on first use, because the counts it derives from change the
// moment anything is added.
//
function TS950Disk.ArenaBase: Integer;
var
  Programs, TotalKeygroups, I, K, Z, Si, B, N, Best, BestCount, FromZones, Start, V, F: Integer;
  Votes: TVoteArray;
  Groups: TDiskKeygroupArray;
  Zone: TDiskZone;
  First: TSlotRecordArray;
begin
  if FArenaBaseCache >= 0 then
  begin
    Result := FArenaBaseCache;
    Exit;
  end;

  Programs := 0;
  TotalKeygroups := 0;
  for I := 0 to High(FEntries) do
    if FEntries[I].EntryType = 'P' then
    begin
      Inc(Programs);
      Inc(TotalKeygroups, KeygroupCount(FEntries[I]));
    end;

  // the table base most zones agree on
  begin
    Votes := nil;
    Best := -1;
    BestCount := 0;

    for I := 0 to High(FEntries) do
    begin
      if FEntries[I].EntryType <> 'P' then
        Continue;
      Groups := Keygroups(FEntries[I]);
      for K := 0 to High(Groups) do
        for Z := 0 to 1 do
        begin
          if Z = 0 then
            Zone := Groups[K].Zone1
          else
            Zone := Groups[K].Zone2;

          if (not Zone.InUse) or (Zone.ZonePointer = 0) then
            Continue;
          Si := SampleIndex(Zone.Name);
          if Si < 0 then
            Continue;

          B := Zone.ZonePointer - KeygroupSize * Si;
          N := Vote(Votes, B);
          if N > BestCount then
          begin
            BestCount := N;
            Best := B;
          end;
        end;
    end;

    if Best >= 0 then
    begin
      FromZones := Best - KeygroupSize * (TotalKeygroups + Programs - 1);
      if (FromZones > 0) and (FromZones < SampleRamBase) then
      begin
        FArenaBaseCache := FromZones;
        Result := FArenaBaseCache;
        Exit;
      end;
    end;
  end;

  // otherwise the chains: each programme with two or more keygroups implies a base
  begin
    ArenaRecords(First);

    Votes := nil;
    Best := -1;
    BestCount := 0;

    for I := 0 to High(FEntries) do
    begin
      if (FEntries[I].EntryType <> 'P') or (KeygroupCount(FEntries[I]) < 2) then
        Continue;

      Start := 0;
      for F := 0 to High(First) do
        if First[F].Slot = FEntries[I].Slot then
          Start := First[F].Rec;

      V := ChainOf(ReadFile(FEntries[I]), 0) - KeygroupSize * (Start + 1);
      if (V <= 0) or (V >= SampleRamBase) then
        Continue;

      N := Vote(Votes, V);
      if N > BestCount then
      begin
        BestCount := N;
        Best := V;
      end;
    end;

    if Best > 0 then
      FArenaBaseCache := Best
    else
      FArenaBaseCache := ArenaDefault;
    Result := FArenaBaseCache;
  end;
end;

function TS950Disk.SampleTableAddress: Integer;
var
  First: TSlotRecordArray;
  Records: Integer;
begin
  Records := ArenaRecords(First);
  Result := ArenaBase + KeygroupSize * Records;
end;

function TS950Disk.RebuildPointers: Integer;
var
  First: TSlotRecordArray;
  Records, Arena, Table, Changed, E, Count, Start, F, K, Z: Integer;
  Load, Kg, Co, WantNext, No, Po, Have, I, WantZone: Integer;
  Raw: TBytes;
  ZoneName: string;
begin
  Records := ArenaRecords(First);
  Arena := ArenaBase;
  Table := Arena + KeygroupSize * Records;
  Changed := 0;

  for E := 0 to High(FEntries) do
  begin
    if FEntries[E].EntryType <> 'P' then
      Continue;

    Count := KeygroupCount(FEntries[E]);
    Start := 0;
    for F := 0 to High(First) do
      if First[F].Slot = FEntries[E].Slot then
        Start := First[F].Rec;

    Raw := ReadFile(FEntries[E]);

    // The header restates the layout - where the keygroups load and how many there
    // are - and the sampler believes the header. See the memory of DSKA0000.
    Load := Arena + KeygroupSize * Start;
    if (System.Length(Raw) > 19) and ((Raw[18] or (Raw[19] shl 8)) <> Load) then
    begin
      PokeFile(FEntries[E], 18, Load and $FF);
      PokeFile(FEntries[E], 19, (Load shr 8) and $FF);
      Inc(Changed);
    end;
    if (System.Length(Raw) > 23) and (Raw[23] <> Count) then
    begin
      PokeFile(FEntries[E], 23, Count and $FF);
      Inc(Changed);
    end;

    for K := 0 to Count - 1 do
    begin
      Kg := ProgHeaderSize + K * KeygroupSize;

      Co := Kg + KeygroupChainOffset;
      if K = Count - 1 then
        WantNext := 0
      else
        WantNext := Arena + KeygroupSize * (Start + K + 1);
      if (Co + 1 < System.Length(Raw)) and (ChainOf(Raw, K) <> WantNext) then
      begin
        PokeFile(FEntries[E], Co, WantNext and $FF);
        PokeFile(FEntries[E], Co + 1, (WantNext shr 8) and $FF);
        Inc(Changed);
      end;

      for Z := 0 to 1 do
      begin
        No := Kg + KeygroupNameOffset + Z * KeygroupZoneStride;
        Po := No + 16;
        if Po + 1 >= System.Length(Raw) then
          Continue;

        ZoneName := Trimmed(CleanName(Raw, No));
        Have := Raw[Po] or (Raw[Po + 1] shl 8);
        if (ZoneName = '') or (ZoneName = UnusedZone) or (Have = 0) then
          Continue;

        I := SampleIndex(ZoneName);
        if I < 0 then
          Continue;

        WantZone := Table + KeygroupSize * I;
        if Have <> WantZone then
        begin
          PokeFile(FEntries[E], Po, WantZone and $FF);
          PokeFile(FEntries[E], Po + 1, (WantZone shr 8) and $FF);
          Inc(Changed);
        end;
      end;
    end;
  end;

  Result := Changed;
end;

// ---------------------------------------------------------------------------- reading

function TS950Disk.ReadFile(const E: TDiskEntry): TBytes;
var
  Blocks: TIntArray;
  I, N: Integer;
  At: NativeInt;
begin
  Result := nil;
  Blocks := Chain(E.StartBlock);

  SetLength(Result, System.Length(Blocks) * BlockSize);
  N := 0;

  for I := 0 to High(Blocks) do
  begin
    At := NativeInt(Blocks[I]) * BlockSize;
    if At + BlockSize > System.Length(FImage) then
      Break;
    Move(FImage[At], Result[N], BlockSize);
    Inc(N, BlockSize);
  end;

  SetLength(Result, N);

  if (N > E.Length) and (E.Length >= 0) then
    SetLength(Result, E.Length);
end;

// signed12 in the C++ (a lambda there).
function Signed12(W: Integer): SmallInt; inline;
begin
  if W >= 2048 then
    Result := W - 4096
  else
    Result := W;
end;

//
// A sample as stored: signed 12-bit, in the split-nibble layout of section 6.2.
//
// Three bytes hold two words, and the two halves of the sample are interleaved rather
// than laid out one after another: word i and word half+i share a byte of nibbles. The
// count is rounded down to a pair, and a truncated file gives back what it does hold
// rather than reading past the end.
//
function TS950Disk.SampleWords12(const E: TDiskEntry): TSmallIntArray;
var
  Raw: TBytes;
  Payload, Half, I, Nibbles: Integer;
  N: Int64;
begin
  Result := nil;
  if E.EntryType <> 'S' then
    Exit;

  Raw := ReadFile(E);
  Payload := System.Length(Raw) - HeaderSize;
  if Payload <= 0 then
    Exit;

  N := MinI64(E.SampleCount, Int64(Payload) * 2 div 3);
  N := N and not Int64(1);
  if N <= 0 then
    Exit;

  Half := N div 2;
  SetLength(Result, N);

  for I := 0 to Half - 1 do
  begin
    Nibbles := Raw[HeaderSize + 2 * I];

    Result[I] := Signed12((Raw[HeaderSize + 2 * I + 1] shl 4) or (Nibbles shr 4));

    Result[Half + I] := Signed12((Raw[HeaderSize + N + I] shl 4) or (Nibbles and $0F));
  end;
end;

class function TS950Disk.KeygroupCount(const Prog: TDiskEntry): Integer;
var
  N: Integer;
begin
  if (Prog.EntryType <> 'P') or (Prog.Length < ProgHeaderSize + KeygroupSize) then
  begin
    Result := 0;
    Exit;
  end;

  N := Prog.Length - ProgHeaderSize;
  if N mod KeygroupSize = 0 then
    Result := N div KeygroupSize
  else
    Result := 0;
end;

class function TS950Disk.ParseZone(const Raw: TBytes; At: NativeInt): TDiskZone;
begin
  Result.Init;
  Result.Name := CleanName(Raw, At);
  Result.ZonePointer := Raw[At + 16] or (Raw[At + 17] shl 8);
  Result.Fine := Raw[At + 18];
  Result.Transpose := Signed8(Raw[At + 19]);
  Result.Filter := Raw[At + 20];
  Result.Loudness := Signed8(Raw[At + 21]);
end;

function TS950Disk.Keygroups(const Prog: TDiskEntry): TDiskKeygroupArray;
var
  N, K, Count: Integer;
  Body: TBytes;
  O: NativeInt;
  Kg: TDiskKeygroup;
begin
  Result := nil;

  N := KeygroupCount(Prog);
  if N = 0 then
    Exit;

  Body := ReadFile(Prog);

  SetLength(Result, N);
  Count := 0;

  for K := 0 to N - 1 do
  begin
    O := NativeInt(ProgHeaderSize) + NativeInt(K) * KeygroupSize;

    if O + KeygroupSize > System.Length(Body) then
      Break;

    Kg.Init;
    Kg.Index := K;
    Kg.HighKey := Body[O + 0];
    Kg.LowKey := Body[O + 1];

    Kg.VelocitySwitch := Body[O + 2];

    Kg.VcaAttack := Body[O + 3];
    Kg.VcaDecay := Body[O + 4];
    Kg.VcaSustain := Body[O + 5];
    Kg.VcaRelease := Body[O + 6];

    Kg.VelToFilter := Body[O + 7];
    Kg.KeyToFilter := Body[O + 8];
    Kg.VelToAttack := Body[O + 9];
    Kg.VelToRelease := Signed8(Body[O + 10]);
    Kg.VelToLoudness := Body[O + 11];

    Kg.WarpVelocity := Body[O + 12];
    Kg.WarpDepth := Signed8(Body[O + 13]);
    Kg.WarpTime := Body[O + 14];
    Kg.OutputPort := Signed8(Body[O + 19]) + 1;

    Kg.LfoDelay := Body[O + 15];
    Kg.LfoRate := Body[O + 16];
    Kg.LfoDepth := Body[O + 17];
    Kg.Flags := Body[O + 18];

    Kg.LfoAftertouchDepth := Body[O + 21];
    Kg.LfoModwheelDepth := Body[O + 22];

    Kg.VcfAmount := Signed8(Body[O + 23]);
    Kg.VcfAttack := Body[O + 34];
    Kg.VcfDecay := Body[O + 35];
    Kg.VcfSustain := Body[O + 36];
    Kg.VcfRelease := Body[O + 37];

    Kg.Zone1 := ParseZone(Body, O + KeygroupNameOffset);
    Kg.Zone2 := ParseZone(Body, O + KeygroupNameOffset + KeygroupZoneStride);

    Result[Count] := Kg;
    Inc(Count);
  end;

  SetLength(Result, Count);
end;

// ---------------------------------------------------------------- ready to be played

// One step of FNV-1a. The multiply wraps, as unsigned arithmetic does in C++, so the
// overflow and range checks are off for it alone.
{$IFOPT Q+}{$DEFINE S950DISK_Q}{$Q-}{$ENDIF}
{$IFOPT R+}{$DEFINE S950DISK_R}{$R-}{$ENDIF}
function FnvStep(H: UInt64; B: Byte): UInt64;
begin
  Result := (H xor B) * UInt64(1099511628211);
end;
{$IFDEF S950DISK_Q}{$Q+}{$UNDEF S950DISK_Q}{$ENDIF}
{$IFDEF S950DISK_R}{$R+}{$UNDEF S950DISK_R}{$ENDIF}

// FNV-1a over a sample file's bytes: header and audio both, so a marker edit counts.
function TS950Disk.FingerprintOf(const Sample: TDiskEntry): UInt64;
var
  Raw: TBytes;
  I: Integer;
  H: UInt64;
begin
  Raw := ReadFile(Sample);
  H := UInt64(1469598103934665603);
  for I := 0 to High(Raw) do
    H := FnvStep(H, Raw[I]);
  Result := H;
end;

function TS950Disk.SoundFor(const Sample: TDiskEntry): TS950Sound;
var
  Words: TSmallIntArray;
  S: TS950Sound;
  I: Integer;
  ToW, From, Size, PlaysTo, FirstW: Int64;
begin
  Result := nil;

  Words := SampleWords12(Sample);
  if System.Length(Words) = 0 then
    Exit;

  S := TS950Sound.Create;
  S.Name := Sample.Name;
  S.Fingerprint := FingerprintOf(Sample);
  if Sample.SampleRate < 1000 then
    S.SourceRate := 40000
  else
    S.SourceRate := Sample.SampleRate;
  S.RootPitch := Sample.NominalPitch + Sample.FinePitch / 16.0;

  // words[i] / 2048.0f: a 12-bit value over a power of two, exact in any precision.
  SetLength(S.Audio, System.Length(Words));
  for I := 0 to High(Words) do
    S.Audio[I] := Words[I] / 2048.0;

  //
  // The machine plays end-length .. end round and round, so the start follows from
  // the length rather than from the stored start - which is simply zero in 250 of the
  // library's 324 looped samples.
  //
  ToW := MinI64(Sample.LoopEnd, System.Length(Words));
  From := MaxI64(0, Sample.LoopEnd - Sample.LoopLength);

  S.Loops := (Sample.LoopMode <> 'O') and (Sample.LoopLength > 0) and (Sample.LoopEnd > 0) and (ToW > From);
  S.Alternates := Sample.LoopMode = 'A';

  //
  // A note starts at the start marker (0x20), not at word 0.
  //
  // MEASURED, 2026-09-27: DSKA0039 GRAND1, note 60 struck twelve times on the machine.
  // Every GRAND sample has its marker at 1000 words, past 500-750 words of lead-in at
  // -30 to -36 dB. The machine's attack went straight from silence to within 6 dB of
  // the peak; played from word 0, the same note first spent 24 ms at about -30 dB.
  // Played from the marker, the attack matched the machine's shape within 2 dB.
  //
  // Cropping here keeps the voice unaware of it. A marker at or past the end of what
  // would play is ignored, as the Studio's audition ignores it.
  //
  // And a sample that does not loop STOPS at its end marker (0x1C), not at the end of
  // its audio. MEASURED, 2026-09-27: DSKA0004 DRUM-A's COWBELL, whose end marker sits
  // 4000 words (100 ms) short of its audio - the machine's note fell away to nothing
  // around the marker while the engine's played on to the last word. A looping sample
  // already turns round at the same marker, so only one-shots change.
  //
  Size := System.Length(Words);
  if S.Loops then
    PlaysTo := ToW
  else if (Sample.LoopEnd > 0) and (Sample.LoopEnd < Size) then
    PlaysTo := Sample.LoopEnd
  else
    PlaysTo := Size;
  if (not S.Loops) and (PlaysTo < Size) then
    SetLength(S.Audio, PlaysTo);

  if (Sample.LoopStart > 0) and (Sample.LoopStart < PlaysTo) then
    FirstW := Sample.LoopStart
  else
    FirstW := 0;
  if FirstW > 0 then
  begin
    Move(S.Audio[FirstW], S.Audio[0], (System.Length(S.Audio) - FirstW) * SizeOf(Single));
    SetLength(S.Audio, System.Length(S.Audio) - FirstW);
    From := MaxI64(From, FirstW);
  end;

  S.LoopFrom := Wrap32(From - FirstW);
  S.LoopTo := Wrap32(ToW - FirstW);

  Result := S;
end;

type
  // What buildPatch has decoded: one per sample, however many keygroups name it.
  TDecodedSound = record
    Name: string;
    Sound: TS950Sound;
    Fresh: Boolean;                // decoded here, so the creator's reference is ours
  end;
  TDecodedSoundArray = array of TDecodedSound;

function TS950Disk.BuildPatch(const Prog: TDiskEntry; Reuse: TS950Patch): TS950Patch;
var
  Patch: TS950Patch;
  Head: TBytes;
  Decoded: TDecodedSoundArray;
  Groups: TDiskKeygroupArray;
  G, Split, I: Integer;

  procedure Remember(const AName: string; Sound: TS950Sound; Fresh: Boolean);
  var
    N: Integer;
  begin
    N := System.Length(Decoded);
    SetLength(Decoded, N + 1);
    Decoded[N].Name := AName;
    Decoded[N].Sound := Sound;
    Decoded[N].Fresh := Fresh;
  end;

  function SoundNamed(const AName: string): TS950Sound;
  var
    D, K: Integer;
    E: PDiskEntry;
    Print: UInt64;
    S: TS950Sound;
  begin
    Result := nil;
    if AName = '' then
      Exit;

    for D := 0 to High(Decoded) do
      if Decoded[D].Name = AName then
      begin
        Result := Decoded[D].Sound;
        Exit;
      end;

    E := Find(AName, 'S');

    // Only a sample whose BYTES are the ones the old sound was decoded from: the
    // same name is not enough, since the Synth tab re-renders a wave under its name.
    if (Reuse <> nil) and (E <> nil) then
    begin
      Print := FingerprintOf(E^);
      for K := 0 to High(Reuse.Keygroups) do
        if (Reuse.Keygroups[K].Sound <> nil) and (Reuse.Keygroups[K].Sound.Name = AName)
           and (Reuse.Keygroups[K].Sound.Fingerprint = Print) then
        begin
          Remember(AName, Reuse.Keygroups[K].Sound, False);
          Result := Reuse.Keygroups[K].Sound;
          Exit;
        end;
    end;

    if E <> nil then
      S := SoundFor(E^)
    else
      S := nil;

    Remember(AName, S, True);
    Result := S;
  end;

  procedure AddZone(const Kg: TDiskKeygroup; const Zone: TDiskZone; VelFrom, VelTo: Integer);
  var
    Sound: TS950Sound;
    P: TKeygroupPatch;
  begin
    if (VelTo < VelFrom) or (Zone.Name = '') then
      Exit;

    Sound := SoundNamed(Zone.Name);
    if Sound = nil then
      Exit;

    P.Init;
    P.LowKey := Kg.LowKey;
    P.HighKey := Kg.HighKey;
    P.KeygroupIndex := Kg.Index;
    P.VelocityFrom := VelFrom;
    P.VelocityTo := VelTo;
    P.Sound := Sound;

    P.VcaAttack := Kg.VcaAttack;
    P.VcaDecay := Kg.VcaDecay;
    P.VcaSustain := Kg.VcaSustain;
    P.VcaRelease := Kg.VcaRelease;

    P.VcfWritten := TKeygroupPatch.LooksWritten(Kg.VcfAttack, Kg.VcfDecay,
                                                Kg.VcfSustain, Kg.VcfRelease);
    P.VcfAttack := Kg.VcfAttack;
    P.VcfDecay := Kg.VcfDecay;
    P.VcfSustain := Kg.VcfSustain;
    P.VcfRelease := Kg.VcfRelease;
    P.VcfAmount := Kg.VcfAmount;

    P.VelToFilter := Kg.VelToFilter;
    P.KeyToFilter := Kg.KeyToFilter;
    P.VelToLoudness := Kg.VelToLoudness;
    P.VelToAttack := Kg.VelToAttack;
    P.VelToRelease := Kg.VelToRelease;
    P.VelocityReleaseOn := Kg.VelocityReleaseOn;

    P.WarpVelocity := Kg.WarpVelocity;
    P.WarpDepth := Kg.WarpDepth;
    P.WarpTime := Kg.WarpTime;
    P.OutputPort := Kg.OutputPort;

    P.LfoDelay := Kg.LfoDelay;
    P.LfoRate := Kg.LfoRate;
    P.LfoDepth := Kg.LfoDepth;
    P.LfoModwheelDepth := Kg.LfoModwheelDepth;
    P.LfoAftertouchDepth := Kg.LfoAftertouchDepth;
    P.LfoDesync := Kg.LfoDesync;

    P.ZoneFilter := Zone.Filter;
    P.ZoneLoudness := Zone.Loudness;
    P.ZoneTranspose := Zone.PitchOffset;

    P.ConstantPitch := Kg.ConstantPitch;
    P.OneShot := Kg.OneShot;

    Patch.Add(P);                  // the patch's own reference to the sound
  end;

begin
  Result := nil;
  if Prog.EntryType <> 'P' then
    Exit;

  Patch := TS950Patch.Create;
  Patch.Name := Prog.Name;

  // Program header byte 21: fade overlapping keygroups rather than sounding both at
  // full level. 48 library programmes set it and overlap, and they are the
  // multi-sampled instruments - the pianos above all.
  begin
    Head := ReadFile(Prog);
    Patch.PositionalCrossfade := (System.Length(Head) > 21) and (Head[21] <> 0);
  end;

  // One decode per sample, however many keygroups name it.
  Decoded := nil;

  Groups := Keygroups(Prog);
  for G := 0 to High(Groups) do
  begin
    //
    // The two zones split the velocity range at the switch rather than both
    // sounding. A switch of 128 leaves zone 1 the whole range, which is how the
    // panel says there is no second zone.
    //
    // Getting this wrong is not subtle: 74 of the library's 168 two-zone keygroups
    // name the SAME sample in both, so layering them puts two copies of one sample
    // on top of each other and every note rings like a bell.
    //
    Split := Groups[G].VelocitySwitch;
    if (Split < 1) or (Split > 128) then
      Split := 128;

    if not Groups[G].HasSecondZone then
    begin
      AddZone(Groups[G], Groups[G].Zone1, 0, 127);
    end
    else
    begin
      //
      // The byte is the LAST velocity of zone 1, not the first of zone 2.
      //
      // This read `zone1 0..split-1, zone2 split..127` and was out by one step.
      // Measured on the hardware with a sine in zone 1 and noise in zone 2:
      //
      //     switch    1     zone 1 at velocity 1,  zone 2 from 2
      //     switch   64     zone 1 through 64,     zone 2 from 65
      //     switch  127     zone 1 through 127,    zone 2 never
      //
      // That last line is what makes it certain. At a switch of 127 the hard sample
      // cannot be reached at all, which only follows if zone 2 begins at 128 - and
      // it is why the panel's range runs to 128 and why 128 means the switch is off.
      // The special case that used to say so has gone: with zone 2 starting at
      // split + 1, a split of 127 or 128 leaves it an empty range and addZone
      // declines it on its own.
      //
      AddZone(Groups[G], Groups[G].Zone1, 0, MinI(127, Split));
      AddZone(Groups[G], Groups[G].Zone2, Split + 1, 127);
    end;
  end;

  // The sounds decoded here were created holding one reference, which the shared_ptr
  // they stand for would have dropped as `decoded` went: give it back, leaving the patch's.
  for I := 0 to High(Decoded) do
    if Decoded[I].Fresh then
      ReleaseSound(Decoded[I].Sound);

  Result := Patch;
end;

end.
