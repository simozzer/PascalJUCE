// Mz950 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Plugin/Source/S950/Engine.h and Engine.cpp. Renders the same
// samples as the C++, bit for bit (verify\build_verify.cmd checks it); see S950Math for how.
//
// The C++'s std::atomic members are S950Math's TAtomicSingle / TAtomicDouble / TAtomicBool /
// TAtomicInt, and its shared_ptr<const Patch> is TS950Patch's reference count: see the note
// on TrySetPatch for who holds what.

unit S950Engine;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$MINFPCONSTPREC 64}   // a real literal is a double, as in C++ (1.0 would otherwise be a Single)
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  S950Math, S950Cal, S950Patch, S950Voice;

const
  // What the machine has. Voices past this steal the oldest.
  EnginePolyphony = 8;

  //
  // What each keygroup has been asked to play, for a window that lights them up.
  //
  // A COUNT of notes answered, not a flag, and the last note: a drum hit is over
  // between two redraws of a window, and a flag would be off again before anything
  // saw it. A count that moved says "this was hit", however briefly. Written on the
  // audio thread as a note starts, read from anywhere.
  //
  EngineActivitySlots = 64;

type
  //
  // The player's trims, applied to every keygroup of whatever is loaded. See Trims.
  //
  // One atomic each rather than one lock around the set: they are written by the
  // message thread and read by the audio thread, and nothing here needs them to change
  // together. A control moved half a block before another is exactly what a pair of
  // hands does anyway.
  //
  TAtomicTrims = record
    Cutoff, Amount: TAtomicSingle;
    VcaAttack, VcaDecay, VcaSustain, VcaRelease: TAtomicSingle;
    VcfAttack, VcfDecay, VcfSustain, VcfRelease: TAtomicSingle;
    LfoRate, LfoDepth, LfoDelay: TAtomicSingle;
    VelToFilter, VelToLoudness: TAtomicSingle;
    Resonance: TAtomicSingle;
    LfoShape, LfoToFilter: TAtomicSingle;
    LfoSync, LfoSyncDiv: TAtomicSingle;

    // The C++'s initial values: all zero, bar lfoSyncDiv at 8.
    procedure Init;

    // One reading of the lot, for a stretch of audio to be rendered against.
    function Read: TTrims;
  end;

  //
  // The instrument: eight voices, a patch, and a buffer to fill.
  //
  // Nothing in here knows what is driving it. In the C# an editor drives it from a piano
  // keyboard and a MIDI port; here a host drives it from its note events; the checks drive
  // it from a loop and render to a file. That separation is the one decision that made
  // this port a port rather than a rewrite.
  //
  // THREADS
  //
  // render() runs on the audio thread and must never allocate, never lock and never block.
  // Notes arrive from somewhere else, so they go into a small lock-free ring and are picked
  // up at the top of the next render(). A lock here would be a dropout.
  //
  TS950Engine = class
  private
    const
      EvNoteOn   = 1;
      EvNoteOff  = 2;
      EvWheel    = 3;
      EvAllOff   = 4;
      EvBend     = 5;
      EvPressure = 6;
      EvGlide    = 7;
      EvVoices   = 8;
      EvWide     = 9;

      RingSize = 256;

      GlideSlots = 64;
    type
      TEvent = record
        Kind, A, B: Byte;
        At: Word;                 // samples into the block this belongs to
      end;

      //
      // Portamento's memory, one slot per keygroup, indexed by keygroupIndex.
      //
      // Per keygroup because a glide only makes sense INSIDE one. A keygroup is one sample
      // over one range of keys; crossing into the next is a different sample, and on a
      // split it is a different instrument - a bass note sliding up into the lead above it
      // is not portamento, it is a mistake. So each keygroup remembers its own last note
      // and glides only from that.
      //
      // pitch is -1 until the keygroup has played, so its first note has nowhere to come
      // from. voice is the voice that note started, and sequence proves it has not since
      // been taken for something else. Fixed-size so a note never allocates; a keygroup
      // past the end of the table simply does not glide. Cleared when the patch changes,
      // because keygroup 3 of one programme has nothing to do with keygroup 3 of another.
      //
      TGlideMemory = record
        Pitch: Double;
        Voice: Integer;
        Sequence: Int64;
        procedure Init;
      end;
  private
    FSampleRate: Double;

    FVoices: array[0..EnginePolyphony - 1] of TS950Voice;
    FMatched: TKeygroupMatches;    // reused, so starting a note allocates nothing

    FRing: array[0..RingSize - 1] of TEvent;
    FWriteIndex: TAtomicInt;
    FReadIndex: TAtomicInt;

    //
    // The patch, exchanged between threads without either one waiting.
    //
    // audioPatch belongs to the audio thread and nothing else touches it. pending is
    // filled by the message thread and taken by the audio thread; retired goes the other
    // way. Both hand-offs move the shared_ptr rather than copying it, so no reference
    // count is touched on the audio thread and nothing is ever freed there.
    //
    FAudioPatch: TS950Patch;
    FPending: TS950Patch;
    FRetired: TS950Patch;
    FPendingReady: TAtomicBool;
    FRetiredReady: TAtomicBool;

    FSequence: Int64;
    FSharedPhase: Double;
    FSharedRate: Double;   // the shared LFO's rate on the panel's 0..99, or -1 for none

    // the host's transport, for tempo sync - see setTransport. Audio thread only.
    FHostBpm, FHostPpq, FHostBarQuarters: Double;
    FHostPlaying: Boolean;
    FSharedCycle: UInt32;
    FWheel: Integer;
    FPressure: Integer;            // channel aftertouch, at rest at nothing
    FBend14: Integer;              // the pitch wheel, at rest in the middle

    FGlideOn: Boolean;
    FGlideFrom: array[0..GlideSlots - 1] of TGlideMemory;

    FKeygroupHits: array[0..EngineActivitySlots - 1] of TAtomicInt;
    FKeygroupLastNote: array[0..EngineActivitySlots - 1] of TAtomicInt;

    FVoiceLimit: Integer;          // in NOTES - see getNoteLimit
    FWideOn: Boolean;

    //
    // The keys that are down, oldest first, with how hard each was struck.
    //
    // Kept whatever the voice count, because switching to mono with keys held must know
    // what they are. Only mono reads it: letting go of the top key goes back to the one
    // below. A key appears once - struck again, it moves to the top.
    //
    FHeldNote, FHeldVelocity: array[0..127] of Integer;
    FHeldCount: Integer;

    procedure Post(Kind: Byte; A, B, At: Integer);
    procedure TakePendingPatch;

    // The next event's place in this block, clamped into it. False if there is none.
    function PeekEvent(out At: Integer; Count: Integer): Boolean;

    // Take the next event off the ring and do it.
    procedure ApplyNextEvent;

    // Every voice into one stretch of the buffer.
    procedure RenderSpan(Left, Right: PSampleBuffer; Count: Integer);
    procedure Repatch;
    // `legato` allows a mono voice to move to this note rather than strike it.
    procedure StartNote(Note, Velocity: Integer; Legato: Boolean = False);
    procedure StopNote(Note: Integer);

    //
    // A DRUM NOTE is one every keygroup answering it plays constant-pitch and one-shot -
    // which is what a kit's keygroups are, on a library disk and on the Synth tab's.
    //
    // Drums live outside the polyphony limit and outside mono. With Poly at 1 a kick
    // must not steal the lead, and a snare key held down is not a "held key" for legato
    // to return to. So a drum is played from the voices ABOVE the limit (all of them
    // when there is no limit), never enters the held-key stack, and never moves a voice
    // legato. take (true) hands out those voices.
    //
    function IsDrumNote(Note, Velocity: Integer): Boolean;

    // Voice i let go, and forgotten as a glide's origin if it was cut off mid-glide.
    procedure ReleaseVoice(I: Integer; Now: Boolean = False);
    // The voice to start a note on, as its index (the C++ returns a reference).
    function Take(Drum: Boolean = False): Integer;

    // A keygroup answered `note`: count it, for the window. See getKeygroupHits.
    procedure NoteHit(KeygroupIndex, Note: Integer);

    // Kill voice i, and its twin with it if it is half of a pair. See Engine::wide.
    procedure KillPair(I: Integer);

    procedure PressKey(Note, Velocity: Integer);
    procedure LiftKey(Note: Integer);

    // Where a note in this keygroup glides from: -1 for nowhere.
    function GlideOrigin(KeygroupIndex: Integer): Double;
  public
    // The master trim, as a plain gain. Eight voices at once can clip.
    Gain: TAtomicSingle;

    Trims: TAtomicTrims;

    //
    // How far the wheel bends, in semitones. The machine's MIDI page offers 1 to 12.
    //
    // Not read off the disk. It is a setting of the machine rather than of a programme,
    // and the OVERALL SETTINGS file that would hold it is only written when someone saves
    // it deliberately - so the plugin owns it, as the host's user does.
    //
    BendRange: TAtomicDouble;

    // How long a glide takes, whatever the interval. Read when a note starts.
    GlideSeconds: TAtomicDouble;

    WideCents: TAtomicDouble;        // each half, either way
    WideSpread: TAtomicDouble;       // 0 centred, 1 hard left and right
    WideOffset: TAtomicBool;         // sharp half starts 7 ms in

    constructor Create(ASampleRate: Double);
    destructor Destroy; override;

    function GetSampleRate: Double;

    //
    // What to play.
    //
    // Called from the message thread. The patch is handed over rather than shared: see
    // the note in Engine.cpp on why this is a two-slot exchange and not simply an
    // atomic pointer. Call collectRetiredPatch() from the message thread now and then -
    // a timer, or the top of the next setPatch - or the old patch is never released.
    //
    // The caller keeps its own reference: the engine takes one of its own (Retain).
    //
    procedure SetPatch(Patch: TS950Patch);

    //
    // Hand over a patch if the audio thread has taken the last one - false, touching
    // nothing, if it has not.
    //
    // setPatch used to overwrite `pending` unconditionally, which is a race the moment
    // the audio thread is taking the previous one at the same instant. A programme change
    // a minute is never going to hit it; an edit knob dragged at thirty changes a second
    // will. So a caller that changes the patch often keeps what it wants and tries again
    // - see VirtualS950Processor::timerCallback - and the newest wins.
    //
    function TrySetPatch(Patch: TS950Patch): Boolean;

    //
    // Release whatever the audio thread has finished with.
    //
    // Message thread only. Freeing a patch is freeing every sample buffer in it, and
    // that must not happen where a late free is a click.
    //
    procedure CollectRetiredPatch;

    // ------------------------------------------------------------------- playing

    //
    // `at` is where in the next block the event belongs, in samples.
    //
    // A host hands over a block of audio and, with it, the events that happen part
    // way through it. Applying them all at the start instead - which is what the C#
    // does, because nothing driving it has anything better to offer - rounds every
    // note to the block boundary. At a 512-sample buffer that is 11 ms of jitter,
    // and 11 ms is audible on a drum pattern, which is what this instrument is for.
    //
    // Zero is "at the start of the next block", which is right for a note struck by
    // hand, by a MIDI port, or by anything else with no finer timing to give.
    //
    procedure NoteOn(Note, Velocity: Integer; At: Integer = 0);
    procedure NoteOff(Note: Integer; At: Integer = 0);
    procedure Modwheel(Value: Integer; At: Integer = 0);

    // Channel aftertouch, 0..127. One value for the whole keyboard: the S950 has no
    // polyphonic pressure input, so there is nothing per-key to carry.
    procedure Aftertouch(Value: Integer; At: Integer = 0);

    //
    // The pitch wheel, 0..16383 with 8192 at rest.
    //
    // Split across the event's two byte fields because fourteen bits do not fit in one,
    // and reassembled in applyNextEvent. Sample-accurate like every other message: a bend
    // lands where the host put it rather than on the block boundary, which matters more
    // for a wheel than for a note because a sweep is a stream of them.
    //
    procedure PitchBend(Value: Integer; At: Integer = 0);

    procedure AllNotesOff(At: Integer = 0);

    //
    // PORTAMENTO, WHICH THE S950 NEVER HAD
    //
    // Everything else in this engine is the machine, measured. This is not: it is an
    // addition, and it is off until something turns it on, so a programme still plays
    // exactly as the disk describes it.
    //
    // Switched through the ring rather than an atomic, so it lands on the sample the host
    // put it at. A sequenced line toggling glide between two notes a few samples apart
    // has to get the order right, and a flag read once a block cannot promise that.
    //
    // Each new note glides from the pitch of the note struck before it IN THE SAME
    // KEYGROUP - or from where that note had got to, if it was still gliding. Crossing
    // into another keygroup does not glide: see GlideMemory. Within one keygroup a line
    // slides, and a chord slides as a whole from the note before it, because every note
    // of it starts from the same place.
    //
    procedure Glide(On_: Boolean; At: Integer = 0);

    //
    // How many of the eight voices to use, 1 to 8. Also not the machine's: it always
    // has all eight.
    //
    // One is MONO, and mono plays like a monosynth rather than a sampler with seven
    // voices missing. A key struck while another is still down in the same keygroup
    // moves the sounding note to it - legato, the sample carrying on - gliding there if
    // glide is on. Letting go of the top key goes back to the last one still held. A
    // detached note, or one in a different keygroup, strikes afresh. A layered programme
    // sounds only its first keygroup, there being one voice to sound it with.
    //
    // Through the ring like glide, so it lands on its sample. Voices past a lowered limit
    // are not cut off: they finish what they are playing and are then left alone.
    //
    procedure SetVoiceLimit(Count: Integer; At: Integer = 0);

    //
    // WIDE, WHICH THE S950 NEVER HAD EITHER
    //
    // Every note sounds as two voices, one detuned flat and leaning left, one detuned
    // sharp by the same amount and leaning right - centred on the right pitch, and as
    // loud as one voice. Mono or poly.
    //
    // A pair is two of the eight voices, so wide caps the notes at FOUR: the machine's
    // eight voices, two to a note. Below four the Polyphony control still sets it. The
    // two halves are stolen together, never one alone - a note left with only its flat
    // half would sound flat and off to one side, which is the worst artifact this could
    // have. Constant-pitch keygroups are not doubled: a drum has no pitch to detune.
    //
    // The switch is an event, like glide, and reaches the NEXT note struck. Detune and
    // spread are read every stretch and reach notes already sounding. The start offset
    // is read when a note starts.
    //
    procedure Wide(On_: Boolean; At: Integer = 0);

    // How many notes can sound at once right now, after wide has had its say.
    function GetNoteLimit: Integer;

    // -------------------------------------------------------------------- render

    // Fill `count` mono samples. Allocates nothing.
    // Mono, as it always was. Bit-identical to before.
    procedure Render(Buffer: PSingle; Count: Integer); overload;

    //
    // Stereo, honouring each keygroup's output port.
    //
    // The machine's LEFT and RIGHT sockets are two mono outputs rather than a pan pot, so
    // a keygroup sent to one is absent from the other - 38 keygroups across four library
    // programmes, TUBULAR 2's bells among them. Everything else lands on both at full
    // level, which is what the mono path always did with everything.
    //
    procedure Render(Left, Right: PSingle; Count: Integer); overload;

    //
    // Where the host's transport is, for tempo sync. Audio thread, before render().
    //
    // `ppq` is the position at the start of the next block in quarter notes, and is only
    // read while `playing` - then the shared LFO is locked to it, so a synced S&H steps
    // on the grid and draws the same levels at the same bar every pass. Stopped, or with
    // no host at all (the standalone), the LFO runs free at the tempo. With no call at
    // all it runs at 120.
    //
    procedure SetTransport(Bpm, Ppq: Double; Playing: Boolean; QuartersPerBar: Double);

    // ------------------------------------------------------------ for the caller

    function GetActiveVoices: Integer;

    function GetKeygroupHits(Keygroup: Integer): UInt32;
    function GetKeygroupLastNote(Keygroup: Integer): Integer;

    function GetVoice(I: Integer): PS950Voice;
  end;

implementation

const
  GainDefault: Single = 0.7;      // the C++'s 0.7f
  SyncDivDefault: Single = 8.0;
  HalfF: Single = 0.5;
  OneF: Single = 1.0;
  MinusOneF: Single = -1.0;

{ TAtomicTrims }

procedure TAtomicTrims.Init;
begin
  FillChar(Self, SizeOf(Self), 0);   // every float 0.0f
  LfoSyncDiv.Store(SyncDivDefault);
end;

function TAtomicTrims.Read: TTrims;
begin
  Result.Cutoff     := Cutoff.Load;
  Result.Amount     := Amount.Load;
  Result.VcaAttack  := VcaAttack.Load;
  Result.VcaDecay   := VcaDecay.Load;
  Result.VcaSustain := VcaSustain.Load;
  Result.VcaRelease := VcaRelease.Load;
  Result.VcfAttack  := VcfAttack.Load;
  Result.VcfDecay   := VcfDecay.Load;
  Result.VcfSustain := VcfSustain.Load;
  Result.VcfRelease := VcfRelease.Load;
  Result.LfoRate    := LfoRate.Load;
  Result.LfoDepth   := LfoDepth.Load;
  Result.LfoDelay   := LfoDelay.Load;
  Result.VelToFilter   := VelToFilter.Load;
  Result.VelToLoudness := VelToLoudness.Load;
  Result.Resonance     := Resonance.Load;
  Result.LfoShape      := LfoShape.Load;
  Result.LfoToFilter   := LfoToFilter.Load;
  Result.LfoSync       := LfoSync.Load;
  Result.LfoSyncDiv    := LfoSyncDiv.Load;
end;

{ TS950Engine.TGlideMemory }

procedure TS950Engine.TGlideMemory.Init;
begin
  Pitch    := -1.0;
  Voice    := -1;
  Sequence := -1;
end;

{ TS950Engine }

constructor TS950Engine.Create(ASampleRate: Double);
var
  I: Integer;
begin
  inherited Create;
  if ASampleRate <= 0 then FSampleRate := 48000.0 else FSampleRate := ASampleRate;

  for I := 0 to EnginePolyphony - 1 do
    FVoices[I].Init;
  FMatched.Count := 0;

  FWriteIndex.Store(0);
  FReadIndex.Store(0);
  FPendingReady.Store(False);
  FRetiredReady.Store(False);

  FSequence    := 0;
  FSharedPhase := 0.0;
  FSharedRate  := -1.0;
  FHostBpm := 120.0; FHostPpq := 0.0; FHostBarQuarters := 4.0;
  FHostPlaying := False;
  FSharedCycle := 0;
  FWheel := 0;
  FPressure := 0;
  FBend14 := 8192;
  FGlideOn := False;
  for I := 0 to GlideSlots - 1 do
    FGlideFrom[I].Init;
  FVoiceLimit := EnginePolyphony;
  FWideOn := False;
  FHeldCount := 0;

  Gain.Store(GainDefault);
  Trims.Init;
  BendRange.Store(2.0);
  GlideSeconds.Store(0.12);
  WideCents.Store(10.0);
  WideSpread.Store(0.7);
  WideOffset.Store(True);

  // std::atomic's default constructor leaves the value wherever the memory was.
  for I := 0 to EngineActivitySlots - 1 do
  begin
    FKeygroupHits[I].Store(0);
    FKeygroupLastNote[I].Store(-1);
  end;
end;

destructor TS950Engine.Destroy;
var
  I: Integer;
begin
  for I := 0 to EnginePolyphony - 1 do
    FVoices[I].Done;
  ReleasePatch(FAudioPatch);
  ReleasePatch(FPending);
  ReleasePatch(FRetired);
  inherited Destroy;
end;

function TS950Engine.GetSampleRate: Double;
begin
  Result := FSampleRate;
end;

procedure TS950Engine.SetPatch(Patch: TS950Patch);
begin
  TrySetPatch(Patch);
end;

//
// WHY THE PATCH CHANGES HANDS THIS WAY
//
// The C# simply assigned a reference and let the garbage collector work out when the old
// programme could go. There is no collector here, and the two obvious replacements are
// both wrong in the same place:
//
//   - An atomic<Patch*> leaks, or frees while a voice is halfway through a sample.
//   - A shared_ptr read on the audio thread copies, which touches a reference count and,
//     if that copy turns out to be the last, frees every sample buffer in the programme
//     inside the audio callback. That is a dropout waiting for the worst moment.
//
// So the pointer is moved, never copied, and only ever in one direction at a time. The
// message thread puts a patch in `pending`; the audio thread moves it into `audioPatch`
// and moves what was there into `retired`; the message thread takes `retired` away and
// destroys it. Moving a shared_ptr touches no reference count and allocates nothing, so
// the audio thread's half costs two pointer swaps.
//
// The audio thread declines to take a new patch while a retired one is still waiting to
// be collected. That means a second programme change before the host's message thread
// has run is simply held until it has - a programme arriving a few milliseconds late
// being the whole cost of never freeing on the wrong thread.
//
// (In this port: `pending` holds a reference the engine took with Retain; the moves are
// plain pointer assignments, so the audio thread touches no count either. A voice still
// holds a reference to the SOUND it plays, as the C++'s does, so a voice starting a new
// note can give back the last reference to an old sound on the audio thread - exactly
// as the C++'s shared_ptr can.)
//
function TS950Engine.TrySetPatch(Patch: TS950Patch): Boolean;
var
  Rate: Double;
  I: Integer;
begin
  CollectRetiredPatch;          // make room, if the audio thread has handed one back

  // The audio thread has not taken the last one yet: `pending` is still its to take,
  // and writing it now could land mid-take. Leave it; the caller will try again.
  if FPendingReady.Load then
  begin
    Result := False;
    Exit;
  end;

  // The shared LFO runs at the rate the programme's keygroups ask for. They almost
  // always agree; where they do not, the first one wins, since one shared oscillator
  // cannot be at two rates at once.
  //
  // Kept as the panel's 0..99 rather than as a step, because the Rate trim goes on top
  // of it every stretch - see renderSpan. Worked out once here, it used to leave the
  // Rate knob doing nothing at all to any keygroup riding the shared LFO.
  Rate := -1.0;                 // no keygroup rides it
  if Patch <> nil then
  begin
    for I := 0 to High(Patch.Keygroups) do
    begin
      if Patch.Keygroups[I].LfoDesync then Continue;

      Rate := Patch.Keygroups[I].LfoRate;
      Break;
    end;
  end;

  FSharedRate := Rate;          // read only by the audio thread; a double write is atomic enough here
  ReleasePatch(FPending);       // empty: the audio thread moved the last one out
  if Patch <> nil then
    FPending := Patch.Retain    // a copy: the caller keeps its own reference
  else
    FPending := nil;
  FPendingReady.Store(True);
  Result := True;
end;

procedure TS950Engine.CollectRetiredPatch;
begin
  if not FRetiredReady.Load then
    Exit;

  ReleasePatch(FRetired);       // the frees happen HERE, on the message thread
  FRetiredReady.Store(False);
end;

procedure TS950Engine.TakePendingPatch;
var
  Had, Now: Integer;
  I: Integer;
begin
  if not FPendingReady.Load then
    Exit;

  // Only if the last one has been collected - otherwise we would have nowhere to put
  // what we are replacing, and dropping it here would free it on this thread.
  if FRetiredReady.Load then
    Exit;

  FRetired    := FAudioPatch;
  FAudioPatch := FPending;
  FPending    := nil;

  FPendingReady.Store(False);
  FRetiredReady.Store(True);

  // Notes already sounding take up the new settings where they stand, rather than
  // waiting to be struck again.
  Repatch;

  //
  // A programme with a different SHAPE - more keygroups, fewer - has no last notes
  // yet: glide memory is per keygroup, and keygroup 3 of one programme is nothing to
  // do with keygroup 3 of another. The same shape keeps its memory: that is the Synth
  // tab re-rendering under a held line, and the line must go on gliding through it.
  //
  if FRetired <> nil then Had := Length(FRetired.Keygroups) else Had := -1;
  if FAudioPatch <> nil then Now := Length(FAudioPatch.Keygroups) else Now := -1;

  if Had <> Now then
    for I := 0 to GlideSlots - 1 do
      FGlideFrom[I].Init;
end;

// ---------------------------------------------------------------------- the ring

procedure TS950Engine.Post(Kind: Byte; A, B, At: Integer);
var
  W, Next: Integer;
begin
  W    := FWriteIndex.Load;
  Next := (W + 1) mod RingSize;

  if Next = FReadIndex.Load then
    Exit;                       // full: drop it rather than block

  FRing[W].Kind := Kind;
  if A < 0 then FRing[W].A := 0 else if A > 255 then FRing[W].A := 255 else FRing[W].A := A;
  if B < 0 then FRing[W].B := 0 else if B > 255 then FRing[W].B := 255 else FRing[W].B := B;
  if At < 0 then FRing[W].At := 0 else if At > 65535 then FRing[W].At := 65535 else FRing[W].At := At;

  FWriteIndex.Store(Next);
end;

function TS950Engine.PeekEvent(out At: Integer; Count: Integer): Boolean;
var
  R: Integer;
begin
  At := 0;
  R := FReadIndex.Load;

  if R = FWriteIndex.Load then
  begin
    Result := False;
    Exit;
  end;

  //
  // Clamped into this block rather than carried over to the next.
  //
  // A host should never hand over an offset past the end of the block it came
  // with, but if one does, holding the event back would mean keeping state about
  // a block that has already gone. Late by a few samples beats lost.
  //
  At := FRing[R].At;
  if At > Count - 1 then At := Count - 1;
  if At < 0 then At := 0;

  Result := True;
end;

procedure TS950Engine.ApplyNextEvent;
var
  R, I: Integer;
  E: TEvent;
begin
  R := FReadIndex.Load;

  if R = FWriteIndex.Load then
    Exit;

  E := FRing[R];
  FReadIndex.Store((R + 1) mod RingSize);

  case E.Kind of
    // Legato only if another key is still down once this one is counted.
    // A drum key is not a held key: it never joins the stack mono returns to, and
    // never asks for legato.
    EvNoteOn:
      begin
        if IsDrumNote(E.A, E.B) then
          StartNote(E.A, E.B, False)
        else
        begin
          PressKey(E.A, E.B);
          StartNote(E.A, E.B, FHeldCount > 1);
        end;
      end;

    EvNoteOff:
      begin
        if not IsDrumNote(E.A, 127) then LiftKey(E.A);
        StopNote(E.A);
      end;

    EvWide:    FWideOn := E.A <> 0;

    EvVoices:
      if E.A < 1 then FVoiceLimit := 1
      else if E.A > EnginePolyphony then FVoiceLimit := EnginePolyphony
      else FVoiceLimit := E.A;
    EvWheel:    FWheel := E.A;
    EvPressure: FPressure := E.A;
    EvBend:     FBend14 := (E.A shl 7) or E.B;
    EvGlide:    FGlideOn := E.A <> 0;

    EvAllOff:
      begin
        FHeldCount := 0;
        for I := 0 to EnginePolyphony - 1 do ReleaseVoice(I, True);   // a panic: no latency
      end;
  else
  end;
end;

//
// Hand every sounding voice its keygroup out of the patch now loaded.
//
// Matched by keygroup index rather than by key range: a voice belongs to the keygroup
// that started it, and an edit may have moved the ranges under it.
//
procedure TS950Engine.Repatch;
var
  I, K, Want: Integer;
begin
  if FAudioPatch = nil then
  begin
    // Nothing to point at any more. The voices hold a shared_ptr to their audio, so
    // they can finish what they are playing - but their keygroup is gone.
    for I := 0 to EnginePolyphony - 1 do
      if FVoices[I].IsActive then FVoices[I].Kill;

    Exit;
  end;

  for I := 0 to EnginePolyphony - 1 do
  begin
    if not FVoices[I].IsActive then Continue;

    Want := FVoices[I].GetKeygroupIndex;
    if Want < 0 then Continue;

    for K := 0 to High(FAudioPatch.Keygroups) do
    begin
      if FAudioPatch.Keygroups[K].KeygroupIndex <> Want then Continue;
      if (FVoices[I].GetVelocity < FAudioPatch.Keygroups[K].VelocityFrom)
         or (FVoices[I].GetVelocity > FAudioPatch.Keygroups[K].VelocityTo) then Continue;

      FVoices[I].Adopt(FAudioPatch.Keygroups[K]);
      Break;
    end;
  end;
end;

procedure TS950Engine.PressKey(Note, Velocity: Integer);
begin
  LiftKey(Note);                    // struck again: to the top, not in twice

  if FHeldCount < 128 then
  begin
    FHeldNote[FHeldCount]     := Note;
    FHeldVelocity[FHeldCount] := Velocity;
    Inc(FHeldCount);
  end;
end;

procedure TS950Engine.LiftKey(Note: Integer);
var
  I, J: Integer;
begin
  for I := 0 to FHeldCount - 1 do
  begin
    if FHeldNote[I] <> Note then Continue;

    for J := I + 1 to FHeldCount - 1 do
    begin
      FHeldNote[J - 1]     := FHeldNote[J];
      FHeldVelocity[J - 1] := FHeldVelocity[J];
    end;

    Dec(FHeldCount);
    Exit;
  end;
end;

function TS950Engine.IsDrumNote(Note, Velocity: Integer): Boolean;
var
  I: Integer;
begin
  Result := False;
  if FAudioPatch = nil then Exit;

  FAudioPatch.Matching(Note, Velocity, FMatched);
  if FMatched.Count = 0 then Exit;

  for I := 0 to FMatched.Count - 1 do
    if not (FMatched.Items[I].ConstantPitch and FMatched.Items[I].OneShot) then Exit;

  Result := True;
end;

procedure TS950Engine.NoteHit(KeygroupIndex, Note: Integer);
begin
  if (KeygroupIndex < 0) or (KeygroupIndex >= EngineActivitySlots) then Exit;
  FKeygroupLastNote[KeygroupIndex].Store(Note);
  FKeygroupHits[KeygroupIndex].Add(1);
end;

procedure TS950Engine.StartNote(Note, Velocity: Integer; Legato: Boolean);
var
  Drum, Mono, Offset: Boolean;
  GlideTime, From, GlideSemis, Fade, WheelCents: Double;
  Kg: PKeygroupPatch;
  Twin, M, FadeCount, Index, V, W, First, Second, MemVoice: Integer;
  FadeLow, FadeHigh: array[0..EnginePolyphony - 1] of Integer;
begin
  if FAudioPatch = nil then
    Exit;

  // A drum plays as a drum whatever the polyphony says: outside mono, outside the
  // limit, every keygroup answering it. See isDrumNote.
  Drum := IsDrumNote(Note, Velocity);

  FAudioPatch.Matching(Note, Velocity, FMatched);

  Mono := (FVoiceLimit = 1) and not Drum;
  GlideTime := GlideSeconds.Load;

  //
  // Mono legato: the one voice is still held, playing this keygroup's sample, so move
  // it to the new key instead of striking it again. The glide comes from the same
  // per-keygroup memory as ever - which is this voice, as it sounds right now.
  //
  if Mono and Legato and (FMatched.Count > 0) then
  begin
    Kg := FMatched.Items[0];

    if FVoices[0].IsHeld and (FVoices[0].GetKeygroupIndex = Kg.KeygroupIndex)
       and (FVoices[0].GetSound = Kg.Sound) then
    begin
      From := GlideOrigin(Kg.KeygroupIndex);
      if FGlideOn and (From >= 0.0) then GlideSemis := From - Note else GlideSemis := 0.0;

      FVoices[0].LegatoTo(Note, GlideSemis, GlideTime);
      NoteHit(Kg.KeygroupIndex, Note);

      // A wide pair moves as one.
      Twin := FVoices[0].GetPartner;
      if (Twin > 0) and (Twin < EnginePolyphony) and (FVoices[Twin].GetPartner = 0) then
        FVoices[Twin].LegatoTo(Note, GlideSemis, GlideTime);

      if (Kg.KeygroupIndex >= 0) and (Kg.KeygroupIndex < GlideSlots) then
      begin
        FGlideFrom[Kg.KeygroupIndex].Pitch    := Note;
        FGlideFrom[Kg.KeygroupIndex].Voice    := 0;
        FGlideFrom[Kg.KeygroupIndex].Sequence := FVoices[0].GetStartedAt;
      end;

      Exit;
    end;
  end;

  //
  // The positional crossfade needs every keygroup answering this note at once, so the
  // ranges are gathered before any voice starts. With the flag off, or with one
  // keygroup answering, crossfadeGain returns 1 and nothing below changes.
  //
  // Fixed arrays rather than a vector: this is the audio thread, and one note can
  // start no more voices than the polyphony allows.
  //
  FadeCount := MinI(FMatched.Count, EnginePolyphony);

  for M := 0 to FadeCount - 1 do
  begin
    FadeLow[M]  := FMatched.Items[M].LowKey;
    FadeHigh[M] := FMatched.Items[M].HighKey;
  end;

  Index := -1;

  for M := 0 to FMatched.Count - 1 do
  begin
    Kg := FMatched.Items[M];
    Inc(Index);

    // One voice, one keygroup - and at full level, since the crossfade is a balance
    // between keygroups and there is no second one here to balance against.
    if Mono and (Index > 0) then Break;

    if (not Mono) and FAudioPatch.PositionalCrossfade and (Index < FadeCount) then
      Fade := CrossfadeGain(Note, FadeLow, FadeHigh, FadeCount, Index)
    else
      Fade := 1.0;

    //
    // What the two performance controllers add, in cents.
    //
    // The modwheel is byte 22 and channel pressure is byte 21, and the aftertouch
    // run measured them to be THE SAME MECHANISM from different sources. At full,
    // aftertouch gave 71.95 cents against the wheel's 72.3 - one constant, not
    // two. Byte 21 scales it proportionally, reading 0.511 of full at 50 where a
    // straight proportion is 0.505 and byte 22 gave 0.509. And the two ADD: wheel
    // alone read 71.87 cents, wheel and pressure together 149.79, where taking the
    // larger would have left it at 71.87.
    //
    // Byte 21 used to be read and dropped, on the grounds that it is 0 in all 1908
    // keygroups of one person's disks. Other people have other disks.
    //
    WheelCents := LfoWheelCentsAtFull
                    * (Kg.LfoModwheelDepth / 99.0)
                    * (FWheel / 127.0)
                + LfoWheelCentsAtFull
                    * (Kg.LfoAftertouchDepth / 99.0)
                    * (FPressure / 127.0);

    if Kg.LfoDepth * LfoDepthCentsPerUnit + WheelCents < 0.5 then
      WheelCents := 0.0;

    //
    // The trims go on before start(), not after: start() works out the envelope from
    // them and primes the filter with the cutoff at time zero, so a voice that began
    // from untrimmed settings would attack wrongly and click its way to the right
    // ones.
    //
    //
    // Where this keygroup glides from - asked BEFORE take(), which may steal the very
    // voice holding the answer. Per keygroup, so a layered programme's two keygroups
    // each slide from their own last note, and a split never slides across itself.
    //
    From := GlideOrigin(Kg.KeygroupIndex);
    if FGlideOn and (From >= 0.0) then GlideSemis := From - Note else GlideSemis := 0.0;

    //
    // A glide away from a note whose key is already up takes that note over, so its
    // tail fades rather than ringing on beside the glide as a unison. See
    // Voice::handOver. A note still held is left sounding: that is a chord.
    //
    if (GlideSemis <> 0.0) and (GlideTime > 0.0005)
       and (Kg.KeygroupIndex >= 0) and (Kg.KeygroupIndex < GlideSlots) then
    begin
      MemVoice := FGlideFrom[Kg.KeygroupIndex].Voice;

      if (MemVoice >= 0) and FVoices[MemVoice].IsActive
                         and not FVoices[MemVoice].IsHeld
                         and (FVoices[MemVoice].GetStartedAt = FGlideFrom[Kg.KeygroupIndex].Sequence) then
      begin
        FVoices[MemVoice].HandOver;

        // and its twin, if it was wide: both halves were the one note
        Twin := FVoices[MemVoice].GetPartner;
        if (Twin >= 0) and (Twin < EnginePolyphony) and (FVoices[Twin].GetPartner = MemVoice) then
          FVoices[Twin].HandOver;
      end;
    end;

    V := Take(Drum);
    FVoices[V].SetTrims(Trims.Read);

    First := V;

    if (Kg.KeygroupIndex >= 0) and (Kg.KeygroupIndex < GlideSlots) then
    begin
      FGlideFrom[Kg.KeygroupIndex].Pitch    := Note;
      FGlideFrom[Kg.KeygroupIndex].Voice    := First;
      FGlideFrom[Kg.KeygroupIndex].Sequence := FSequence;
    end;

    FVoices[V].Start(Kg^, Note, Velocity, FSampleRate, WheelCents, FSequence, Fade,
                     GlideSemis, GlideTime);
    Inc(FSequence);
    NoteHit(Kg.KeygroupIndex, Note);

    //
    // Wide: the second half. take() cannot hand back `v` - it is the newest voice and
    // held, and there are always at least two voices to choose from when wide is on -
    // so this is always another voice. Started identically, then the pair is told
    // which half is which. A drum is left single: it has no pitch to detune.
    //
    if FWideOn and not Kg.ConstantPitch then
    begin
      W := Take(Drum);
      FVoices[W].SetTrims(Trims.Read);
      FVoices[W].Start(Kg^, Note, Velocity, FSampleRate, WheelCents, FSequence, Fade,
                       GlideSemis, GlideTime);
      Inc(FSequence);

      Second := W;
      Offset := WideOffset.Load;

      FVoices[V].MakeWide(-1, Second, False);
      FVoices[W].MakeWide(+1, First,  Offset);
    end;
  end;
end;

//
// The last note this keygroup played, as it sounds NOW if its voice is still ours and
// still sounding - so a key struck mid-glide carries on from where the slide had got to
// rather than jumping back to where it began. Otherwise the last key struck in it.
//
function TS950Engine.GlideOrigin(KeygroupIndex: Integer): Double;
var
  MemVoice: Integer;
begin
  if (KeygroupIndex < 0) or (KeygroupIndex >= GlideSlots) then
  begin
    Result := -1.0;
    Exit;
  end;

  MemVoice := FGlideFrom[KeygroupIndex].Voice;

  if (MemVoice >= 0) and FVoices[MemVoice].IsActive
                     and (FVoices[MemVoice].GetStartedAt = FGlideFrom[KeygroupIndex].Sequence) then
  begin
    Result := FVoices[MemVoice].GetPitchNow;
    Exit;
  end;

  Result := FGlideFrom[KeygroupIndex].Pitch;
end;

//
// Let go of every voice holding this note.
//
// Every one, not the first: pressing the same key twice before releasing it is ordinary,
// and leaving the older voice held would strand it.
//
procedure TS950Engine.StopNote(Note: Integer);
var
  From, I: Integer;
begin
  //
  // Mono, letting go of the sounding key while others are still down: go back to the
  // newest of those, the way a monosynth does - legato if it is in the same keygroup,
  // gliding if glide is on, struck afresh at its own velocity if it is not.
  //
  From := 0;

  if (FVoiceLimit = 1) and (FHeldCount > 0) and FVoices[0].IsHeld and (FVoices[0].GetNote = Note) then
  begin
    StartNote(FHeldNote[FHeldCount - 1], FHeldVelocity[FHeldCount - 1], True);
    From := 1;                       // voice 0 now plays the held key: leave it be
  end;

  for I := From to EnginePolyphony - 1 do
    if FVoices[I].IsActive and (FVoices[I].GetNote = Note) and FVoices[I].IsHeld then
      ReleaseVoice(I);
end;

//
// Let one voice go - and if it was still gliding, forget it as a place to glide from.
//
// A glide abandoned half way has no pitch worth starting from: the next note in that
// keygroup plays at its own pitch, as though nothing had gone before. A glide that had
// already ARRIVED is a finished note, and the next one still slides from it as usual.
//
// Only when this voice is the one the keygroup remembers. Letting go of an older note
// of a chord says nothing about where the keygroup's line has got to.
//
procedure TS950Engine.ReleaseVoice(I: Integer; Now: Boolean);
var
  K: Integer;
begin
  if FVoices[I].IsHeld and FVoices[I].IsGliding then
  begin
    K := FVoices[I].GetKeygroupIndex;

    if (K >= 0) and (K < GlideSlots) and (FGlideFrom[K].Voice = I)
                and (FGlideFrom[K].Sequence = FVoices[I].GetStartedAt) then
      FGlideFrom[K].Init;
  end;

  // A note-off is taken the way the machine takes one: the key is up now, the
  // envelope lets go cal::NoteOffLatencySeconds later.
  if Now then FVoices[I].Release else FVoices[I].LetGo;
end;

//
// A voice to start a note on.
//
// Idle first, obviously. Then the oldest one that has already been let go and is only
// fading - taking that costs a tail nobody is listening to. Only if every voice is still
// held does it take one of those, and then the oldest.
//
// Taking the oldest regardless, which the C# did at first, would cut off a key the player
// is holding while a released note was left ringing beside it - which reads exactly like
// "the release did not happen".
//
function TS950Engine.Take(Drum: Boolean): Integer;
var
  Limit, From, To_, I, Pick, PerNote: Integer;
begin
  //
  // Only the first so many voices are handed out for NOTES: one per note allowed, or
  // two when wide. Mono always plays voice 0 (and 1, wide), which is what lets
  // startNote find the note it may move legato.
  //
  // DRUMS take the voices above that - the seven a mono lead leaves idle - so a kick
  // never steals the lead and the lead never steals the kick. With no limit there is
  // nothing above it, and a drum is a note like any other.
  //
  if FWideOn then PerNote := 2 else PerNote := 1;
  Limit := MinI(EnginePolyphony, GetNoteLimit * PerNote);
  if Drum and (Limit < EnginePolyphony) then
  begin
    From := Limit;
    To_  := EnginePolyphony;
  end
  else
  begin
    From := 0;
    To_  := Limit;
  end;

  for I := From to To_ - 1 do
    if not FVoices[I].IsActive then
    begin
      Result := I;
      Exit;
    end;

  Pick := -1;
  for I := From to To_ - 1 do
  begin
    if FVoices[I].IsHeld then Continue;                 // still down: leave it
    if (Pick < 0) or (FVoices[I].GetStartedAt < FVoices[Pick].GetStartedAt) then Pick := I;
  end;

  if Pick < 0 then
  begin
    Pick := From;
    for I := From + 1 to To_ - 1 do
      if FVoices[I].GetStartedAt < FVoices[Pick].GetStartedAt then Pick := I;
  end;

  KillPair(Pick);
  Result := Pick;
end;

procedure TS950Engine.KillPair(I: Integer);
var
  Twin: Integer;
begin
  Twin := FVoices[I].GetPartner;

  // Only a twin that still points back: a voice restarted since is no longer its pair.
  if (Twin >= 0) and (Twin < EnginePolyphony) and (FVoices[Twin].GetPartner = I) then
    FVoices[Twin].Kill;

  FVoices[I].Kill;
end;

function TS950Engine.GetActiveVoices: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to EnginePolyphony - 1 do
    if FVoices[I].IsActive then Inc(Result);
end;

function TS950Engine.GetKeygroupHits(Keygroup: Integer): UInt32;
begin
  if (Keygroup >= 0) and (Keygroup < EngineActivitySlots) then
    Result := UInt32(FKeygroupHits[Keygroup].Load)
  else
    Result := 0;
end;

function TS950Engine.GetKeygroupLastNote(Keygroup: Integer): Integer;
begin
  if (Keygroup >= 0) and (Keygroup < EngineActivitySlots) then
    Result := FKeygroupLastNote[Keygroup].Load
  else
    Result := -1;
end;

function TS950Engine.GetVoice(I: Integer): PS950Voice;
begin
  Result := @FVoices[I];
end;

function TS950Engine.GetNoteLimit: Integer;
begin
  if FWideOn then
    Result := MinI(FVoiceLimit, EnginePolyphony div 2)
  else
    Result := FVoiceLimit;
end;

procedure TS950Engine.NoteOn(Note, Velocity: Integer; At: Integer);
begin
  Post(EvNoteOn, Note, Velocity, At);
end;

procedure TS950Engine.NoteOff(Note: Integer; At: Integer);
begin
  Post(EvNoteOff, Note, 0, At);
end;

procedure TS950Engine.Modwheel(Value: Integer; At: Integer);
begin
  Post(EvWheel, Value, 0, At);
end;

procedure TS950Engine.Aftertouch(Value: Integer; At: Integer);
begin
  Post(EvPressure, Value, 0, At);
end;

procedure TS950Engine.PitchBend(Value: Integer; At: Integer);
var
  V: Integer;
begin
  if Value < 0 then V := 0 else if Value > 16383 then V := 16383 else V := Value;
  Post(EvBend, (V shr 7) and $7F, V and $7F, At);
end;

procedure TS950Engine.AllNotesOff(At: Integer);
begin
  Post(EvAllOff, 0, 0, At);
end;

procedure TS950Engine.Glide(On_: Boolean; At: Integer);
begin
  Post(EvGlide, Ord(On_), 0, At);
end;

procedure TS950Engine.SetVoiceLimit(Count: Integer; At: Integer);
begin
  Post(EvVoices, Count, 0, At);
end;

procedure TS950Engine.Wide(On_: Boolean; At: Integer);
begin
  Post(EvWide, Ord(On_), 0, At);
end;

procedure TS950Engine.SetTransport(Bpm, Ppq: Double; Playing: Boolean; QuartersPerBar: Double);
begin
  if Bpm > 0.0 then FHostBpm := Bpm else FHostBpm := 120.0;
  FHostPpq     := Ppq;
  FHostPlaying := Playing;
  if QuartersPerBar > 0.0 then FHostBarQuarters := QuartersPerBar else FHostBarQuarters := 4.0;
end;

procedure TS950Engine.RenderSpan(Left, Right: PSampleBuffer; Count: Integer);
var
  Now: TTrims;
  BendNow, Cents, Spread, SharedHz, SharedStep: Double;
  I: Integer;
begin
  if Count <= 0 then Exit;

  // Read once for the whole stretch, so every voice in it is shaped by the same
  // settings and a control moved mid-block cannot land differently on two voices.
  Now := Trims.Read;

  //
  // The pitch wheel, as a multiplier on the playback rate, worked out once per stretch.
  //
  // Read here rather than at note-on because a bend has to reach notes that are already
  // sounding - that is the whole point of a wheel, and it is what separates it from
  // velocity, which is settled when the key goes down.
  //
  // 8192 is the rest position and the two halves are not the same width: 8192 steps
  // below it and 8191 above. Dividing by 8192 either way would make a full upward bend
  // fall one step short of the range, which is inaudible but wrong; dividing by the
  // right half of the range gets both ends exactly.
  //
  BendNow := BendRatio(FBend14, BendRange.Load);

  // Wide's detune and spread, like the trims: once per stretch, so a knob reaches
  // notes already sounding. Voices that are not half of a pair ignore them.
  Cents  := WideCents.Load;
  Spread := WideSpread.Load;

  // The shared LFO's speed this stretch, which the voices riding it follow sample by
  // sample - see Voice::render - so it can run as fast as their own.
  // Synced, it runs at the tempo whether or not any keygroup rides it by itself: sync
  // puts every voice on it.
  if Now.LfoSync >= 0.5 then
    SharedHz := FHostBpm / 60.0
                / LfoDivisionQuarters(LRound(Now.LfoSyncDiv), FHostBarQuarters)
  else if FSharedRate < 0.0 then
    SharedHz := 0.0
  else
    SharedHz := LfoRateHz(FSharedRate, Now.LfoRate);

  SharedStep := 2.0 * Pi64 * SharedHz / FSampleRate;

  for I := 0 to EnginePolyphony - 1 do
    if FVoices[I].IsActive then
    begin
      FVoices[I].SetTrims(Now);
      FVoices[I].SetBend(BendNow);
      FVoices[I].SetWide(Cents, Spread);
      FVoices[I].Render(Left, Right, Count, FSharedPhase, FSharedCycle, SharedStep);
    end;

  // The shared LFO moves with the audio, so it advances per stretch rather than
  // once per block - otherwise splitting a block would change how it sounds. The
  // whole cycles are counted too: they are what S&H draws a new level on.
  FSharedPhase := FSharedPhase + SharedStep * Count;
  while FSharedPhase > 2.0 * Pi64 do
  begin
    FSharedPhase := FSharedPhase - 2.0 * Pi64;
    Inc(FSharedCycle);
  end;
end;

procedure TS950Engine.Render(Buffer: PSingle; Count: Integer);
begin
  Render(Buffer, nil, Count);
end;

//
// Fill the block, stopping at each event to do it where it belongs.
//
// The C# renders a block and then applies whatever arrived, because a keyboard and a
// MIDI port have no finer timing to give it. A host does: every note comes with an
// offset into the block it was handed with, and rounding those to the block boundary
// is up to 11 ms of jitter at a 512-sample buffer.
//
// So the block is rendered in stretches between events. With nothing in the ring
// that is one stretch and the same work as before; with a note at sample 200 of 512
// it is two, and the note starts on sample 200.
//
procedure TS950Engine.Render(Left, Right: PSingle; Count: Integer);
var
  Buf, RightBuf, RightAt: PSampleBuffer;
  Div_, At, Next, Until_, I: Integer;
  Cycles, Whole: Double;
  G, V, R: Single;
begin
  TakePendingPatch;

  if Count <= 0 then Exit;

  Buf      := PSampleBuffer(Left);
  RightBuf := PSampleBuffer(Right);

  FillChar(Buf^, Count * SizeOf(Single), 0);
  if RightBuf <> nil then
    FillChar(RightBuf^, Count * SizeOf(Single), 0);

  //
  // Tempo sync, with the transport running: put the shared LFO where the grid says it
  // is, once a block. Its phase is the fraction of the way through the current cycle
  // and its cycle count the whole cycles since the song's start - which is what S&H
  // draws on, so the same bar gets the same levels every time it plays. Between here
  // and the next block it moves at the tempo (renderSpan), so this only ever corrects
  // rounding, and a jump in the song lands on the right step at once.
  //
  if (Trims.LfoSync.Load >= HalfF) and FHostPlaying then
  begin
    Div_   := LRoundF(Trims.LfoSyncDiv.Load);
    Cycles := FHostPpq / LfoDivisionQuarters(Div_, FHostBarQuarters);
    Whole  := FloorD(Cycles);

    FSharedPhase := 2.0 * Pi64 * (Cycles - Whole);
    // static_cast<unsigned> (static_cast<long long> (whole)): the low 32 bits
    FSharedCycle := UInt32(Trunc(Whole) and $FFFFFFFF);
  end;

  At := 0;
  while At < Count do
  begin
    // everything due by now, in the order it arrived
    while PeekEvent(Next, Count) and (Next <= At) do
      ApplyNextEvent;

    // up to the next one, or to the end of the block
    if PeekEvent(Next, Count) then Until_ := Next else Until_ := Count;
    if Until_ <= At then Until_ := At + 1;      // never stand still
    if Until_ > Count then Until_ := Count;

    if RightBuf <> nil then RightAt := @RightBuf^[At] else RightAt := nil;
    RenderSpan(@Buf^[At], RightAt, Until_ - At);
    At := Until_;
  end;

  G := Gain.Load;

  for I := 0 to Count - 1 do
  begin
    V := Buf^[I] * G;
    if V > OneF then Buf^[I] := OneF
    else if V < MinusOneF then Buf^[I] := MinusOneF
    else Buf^[I] := V;

    if RightBuf <> nil then
    begin
      R := RightBuf^[I] * G;
      if R > OneF then RightBuf^[I] := OneF
      else if R < MinusOneF then RightBuf^[I] := MinusOneF
      else RightBuf^[I] := R;
    end;
  end;
end;

end.
