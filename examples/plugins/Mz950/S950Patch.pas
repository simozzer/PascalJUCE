// Mz950 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Plugin/Source/S950/Patch.h.
//
// std::shared_ptr is a reference count here: TS950Sound and TS950Patch are counted
// objects. Whoever creates one holds its first reference; Retain takes another and
// ReleaseSound / ReleasePatch gives one back, freeing the object with the last. The count is
// interlocked, as shared_ptr's is, because a sound is held by voices on the audio thread
// and by patches on the message thread at once.

unit S950Patch;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$MINFPCONSTPREC 64}   // a real literal is a double, as in C++ (1.0 would otherwise be a Single)
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  S950Math;

type
  TSingleArray = array of Single;

  //
  // One sample's audio, ready to be played.
  //
  // Normalised to +-1 once, when the patch is built, rather than per sample in the render
  // loop. The engine never sees a disk image: whoever builds the patch does the reading,
  // which is what lets the same engine sit behind a WinForms window, a plugin, or a test.
  //
  // Held by shared_ptr, which the C# did not need and this does. A voice reads this audio
  // on the audio thread; the message thread may replace the patch at any moment. Sharing
  // ownership means the buffer a voice is halfway through cannot be freed under it - the
  // last holder releases it, and if that turns out to be a voice, see the note on
  // Engine::setPatch about where that release happens.
  //
  TS950Sound = class
  private
    FRefs: Integer;
  public
    Name: string;

    //
    // A hash of the bytes this was decoded from, so a rebuilt programme can tell a
    // sample that is the same from one that merely has the same name - the Synth tab
    // re-renders "OSC1" with different audio under the same name every time a wave knob
    // moves. Reusing an unchanged sample's Sound is what lets a held note follow an edit
    // in place (Voice::adopt keeps a note only on the sound it started with).
    //
    Fingerprint: UInt64;
    Audio: TSingleArray;           // -1 .. +1
    SourceRate: Integer;           // hertz, as stored on the disk
    RootPitch: Double;             // the MIDI note at which it plays at sourceRate

    //
    // The loop, in frames. The machine plays end-length .. end round and round, so the
    // loop start follows from the length. The start marker (0x20) is where a note
    // begins, not the loop: audio already starts there (Disk::soundFor crops it).
    //
    LoopFrom, LoopTo: Integer;

    //
    // Loop mode 'A': forward, then backward, then forward again.
    //
    // MEASURED, run 13. A loop of N frames comes round every 2N, not 2N-2 - the frame at
    // each end is played twice as the direction turns rather than once. Four lengths from
    // 20 frames to 128 were played on the hardware and every one autocorrelated at exactly
    // 2N with a coefficient of 0.9996 or better, while the forward controls gave exactly N.
    // On a short loop that is the difference between a tenth of a semitone right and wrong,
    // which is why it was measured rather than chosen.
    //
    // 18 of the 1110 samples on the real disks use it, and they are the ones where it
    // shows: cymbals, sustained strings and piano, and ambient beds - WIND, RAIN, THUNDER,
    // WATER, INSECTS, TRAFFIC, JET.
    //
    Alternates: Boolean;
    Loops: Boolean;

    // How many samples of the loop join were crossfaded, or 0 for a plain splice.
    LoopSmoothed: Integer;

    // One reference, the creator's.
    constructor Create;

    // Another reference. Returns the sound, for `held := sound.Retain`.
    function Retain: TS950Sound;
  end;

  //
  // One keygroup, flattened into what a voice needs.
  //
  // The raw 0..99 panel bytes are kept rather than seconds and hertz, because the mappings
  // from one to the other are the measured part and belong in one place - Cal.
  //
  // A plain record with no managed fields, so a voice copies one on the audio thread
  // without touching anything. `Sound` here does not hold a reference: the patch the entry
  // sits in holds one (TS950Patch.Add), and a voice holds its own (TS950Voice.Start).
  //
  TKeygroupPatch = record
    LowKey, HighKey: Integer;

    //
    // Which velocities this entry answers to.
    //
    // A keygroup holds up to two VELOCITY zones - alternatives, not layers. The switch
    // in byte 2 is the boundary: softer than it plays zone 1, at it or harder plays
    // zone 2, and a switch of 128 is how the panel says "no second zone", since no
    // velocity can reach it.
    //
    // Sounding both was the C# engine's worst bug. 74 of the library's 168 two-zone
    // keygroups name the SAME sample in both, so playing them together put two copies of
    // one sample on top of each other - and 121 of the 168 set the switch to 128, so
    // their second zone should never have sounded at all. Together they rang like a bell
    // over every note. Keep the ranges; do not "simplify" this into layering.
    //
    VelocityFrom, VelocityTo: Integer;

    // Which keygroup this came from. Only the checks care, and they care a lot: two
    // entries from the SAME keygroup must never answer one strike.
    KeygroupIndex: Integer;

    Sound: TS950Sound;

    VcaAttack, VcaDecay, VcaSustain, VcaRelease: Integer;
    VcfAttack, VcfDecay, VcfSustain, VcfRelease: Integer;
    VcfWritten: Boolean;           // an S900 program leaves the four bytes as spaces
    VcfAmount: Integer;            // signed, -50..+50

    VelToFilter, KeyToFilter, VelToLoudness: Integer;

    // Byte 9: how far a hard strike shortens the attack. See cal::velocityAttackByte.
    VelToAttack: Integer;

    // Byte 10, signed: which way velocity moves the release. See cal::velocityReleaseByte.
    VelToRelease: Integer;

    // Byte 18 bit 4. Clear means every note releases as though struck at velocity 1,
    // which is not the same as no effect at all.
    VelocityReleaseOn: Boolean;

    // WARP, bytes 12/13/14: a pitch bend at note-on. See cal::warpRatio. 13 is the depth
    // and is signed; 12 is how far velocity scales it, 0 meaning always full; 14 is the
    // time constant.
    WarpVelocity, WarpDepth, WarpTime: Integer;

    // Byte 19 + 1: 0 ALL, 1..8 the individual outputs, 9 LEFT, 10 RIGHT.
    // See cal::outputGains.
    OutputPort: Integer;

    LfoDelay, LfoRate, LfoDepth, LfoModwheelDepth: Integer;

    // Byte 21: how far channel pressure scales the LFO's depth, exactly as byte 22
    // does for the modwheel. Measured on the aftertouch run - see Engine::startNote.
    LfoAftertouchDepth: Integer;

    LfoDesync: Boolean;            // set in 1652 keygroups of 1908

    ZoneFilter: Integer;           // zone 1's cutoff, 0..99
    ZoneLoudness: Integer;         // signed trim, in the machine's decibel count
    ZoneTranspose: Double;         // semitones, including the fine part

    ConstantPitch: Boolean;
    OneShot: Boolean;

    // The C++'s default member initialisers.
    procedure Init;

    //
    // The four VCF bytes read as ASCII spaces means the program was written by an S900,
    // which had no filter envelope at all - not an envelope that happens to be set to
    // 32. In the library this never bites, because none of the 1684 keygroups with blank
    // bytes sets an amount, but it would the moment one did.
    //
    class function LooksWritten(A, D, S, R: Integer): Boolean; static;
  end;

  PKeygroupPatch = ^TKeygroupPatch;
  TKeygroupPatchArray = array of TKeygroupPatch;

const
  // As many entries as one strike can match: 64 keygroups of two zones apiece is the most
  // a programme holds, and the zones of one keygroup never both answer.
  MaxMatches = 128;

type
  // What TS950Patch.Matching fills: a fixed array, so the audio thread allocates nothing.
  TKeygroupMatches = record
    Count: Integer;
    Items: array[0..MaxMatches - 1] of PKeygroupPatch;
  end;

  // A program: the keygroups a note might land in.
  TS950Patch = class
  private
    FRefs: Integer;
  public
    Name: string;
    Keygroups: TKeygroupPatchArray;

    //
    // Program header byte 21: fade overlapping keygroups into one another rather than
    // sounding both at full level. See cal::XfadeDb.
    //
    PositionalCrossfade: Boolean;

    // One reference, the creator's.
    constructor Create;
    destructor Destroy; override;

    function Retain: TS950Patch;

    // push_back: the entry's sound gains a reference, held until the patch goes.
    procedure Add(const K: TKeygroupPatch);

    //
    // Every entry this note and velocity should sound.
    //
    // Plural on purpose, but for one reason only: overlapping KEYGROUPS do layer, and
    // the machine sounds all of them. The two zones INSIDE a keygroup do not - they are
    // velocity alternatives, and only one of them answers any given strike.
    //
    // Fills a caller's vector rather than returning one, because the caller is the audio
    // thread and it keeps one around: allocating here would be a dropout waiting for a
    // busy moment.
    //
    procedure Matching(Note, Velocity: Integer; var Into: TKeygroupMatches);
  end;

// Give back a reference, freeing the object with the last, and clear the variable. Nil is
// fine, as resetting an empty shared_ptr is.
procedure ReleaseSound(var S: TS950Sound);
procedure ReleasePatch(var P: TS950Patch);

implementation

{ TS950Sound }

constructor TS950Sound.Create;
begin
  inherited Create;
  FRefs := 1;
  SourceRate := 40000;
  RootPitch := 60.0;
end;

function TS950Sound.Retain: TS950Sound;
begin
  AtomicIncrement32(FRefs);
  Result := Self;
end;

procedure ReleaseSound(var S: TS950Sound);
var
  Held: TS950Sound;
begin
  Held := S;
  S := nil;
  if (Held <> nil) and (AtomicDecrement32(Held.FRefs) = 0) then
    Held.Free;
end;

{ TKeygroupPatch }

procedure TKeygroupPatch.Init;
begin
  FillChar(Self, SizeOf(Self), 0);
  LowKey := 0;
  HighKey := 127;
  VelocityFrom := 0;
  VelocityTo := 127;
  KeygroupIndex := -1;
  Sound := nil;
  VcaSustain := 99;
  VcfSustain := 99;
  VcfWritten := True;
  LfoDesync := True;
  ZoneFilter := 99;
  ZoneTranspose := 0.0;
end;

class function TKeygroupPatch.LooksWritten(A, D, S, R: Integer): Boolean;
begin
  Result := not ((A = $20) and (D = $20) and (S = $20) and (R = $20));
end;

{ TS950Patch }

constructor TS950Patch.Create;
begin
  inherited Create;
  FRefs := 1;
end;

destructor TS950Patch.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(Keygroups) do
    ReleaseSound(Keygroups[I].Sound);
  Keygroups := nil;
  inherited Destroy;
end;

function TS950Patch.Retain: TS950Patch;
begin
  AtomicIncrement32(FRefs);
  Result := Self;
end;

procedure TS950Patch.Add(const K: TKeygroupPatch);
var
  N: Integer;
begin
  N := Length(Keygroups);
  SetLength(Keygroups, N + 1);
  Keygroups[N] := K;
  if K.Sound <> nil then
    K.Sound.Retain;
end;

procedure TS950Patch.Matching(Note, Velocity: Integer; var Into: TKeygroupMatches);
var
  I, Lo, Hi: Integer;
begin
  Into.Count := 0;

  for I := 0 to High(Keygroups) do
  begin
    if (Keygroups[I].Sound = nil) or (Length(Keygroups[I].Sound.Audio) = 0) then
      Continue;

    Lo := MinI(Keygroups[I].LowKey, Keygroups[I].HighKey);
    Hi := MaxI(Keygroups[I].LowKey, Keygroups[I].HighKey);

    if (Note < Lo) or (Note > Hi) then
      Continue;
    if (Velocity < Keygroups[I].VelocityFrom) or (Velocity > Keygroups[I].VelocityTo) then
      Continue;

    // The C++'s vector grows; this one is as big as a programme can need (MaxMatches).
    if Into.Count < MaxMatches then
    begin
      Into.Items[Into.Count] := @Keygroups[I];
      Inc(Into.Count);
    end;
  end;
end;

procedure ReleasePatch(var P: TS950Patch);
var
  Held: TS950Patch;
begin
  Held := P;
  P := nil;
  if (Held <> nil) and (AtomicDecrement32(Held.FRefs) = 0) then
    Held.Free;
end;

end.
