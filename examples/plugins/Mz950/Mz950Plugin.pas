// Mz950 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// The plug-in: the Object Pascal counterpart of Plugin/Source/PluginProcessor.cpp
// (VirtualS950Processor), on the PascalJUCE framework rather than juce::AudioProcessor.
// The engine and everything that decides the sound is in the S950* units; this is what a
// host needs on top of it - a block, the notes inside it, the disk and its programmes, and
// the saved state.
//
// THE PUBLIC API is the C++ processor's, in PascalCase, for the panel (Mz950Editor): see
// the "for the editor" section of TMz950. The panel reads parameters through the
// framework's parameter API, as the C++ editor reads the APVTS.
//
// THREADS - who calls what, and the one lock
//
//   Process (the host's audio thread) owns the engine's event side: every note, CC, bend,
//   all-off and the glide / voice-count / wide switches are posted from Process only, before
//   Render, as processBlock posts them (the engine's ring has one producer). Process reads
//   the parameters from its context, the engine pointer (only Prepare replaces it, never
//   while Process runs), and the CC map (atomics). It takes NO lock and allocates nothing.
//
//   Everything else - the disk, the programme list, the patch the panel side holds, keygroup
//   edits, the synth recipe and its render, and the engine's patch hand-over (TrySetPatch,
//   CollectRetiredPatch, which must be serialised with each other) - is "panel side" and is
//   serialised by FLock (a TCriticalSection). Every public method that touches that state
//   takes it: the editor's calls (message thread), the host's SelectProgram (a non-real-time
//   thread, never alongside Process), LoadState / SaveState, Prepare (which rebuilds the
//   engine) and the housekeeping thread. Process never does, so the lock costs the audio
//   thread nothing.
//
//   THE HOUSEKEEPING THREAD stands in for the C++'s juce::Timer, which PascalJUCE does not
//   give a processor - and the patch has to reach the engine even with no editor open. It
//   is started lazily (Prepare, or the first time something needs it), wakes every 30 ms
//   (or at once, on FWake) and runs PanelTick: collect the retired patch, pay a patch the
//   engine refused (TrySetPatch refuses while Process has not taken the last one), finish a
//   synth render that is done or start one that is due, and tell the host when its program
//   chooser is out of step. The destructor stops and joins it. The editor's own timer may
//   call PanelTick too; it is the same work under the same lock. LoadState, SelectProgram
//   and SetKeygroupValue hand the patch over at once when the engine will take it, so the
//   thread only pays debts.
//
//   THE HAND-OVER'S ONE RULE. The engine's take of a patch (TakePendingPatch, as the C++
//   takePendingPatch) marks the patch it replaced ready to collect and then still reads it; a
//   collect from another thread in that moment frees it under the read (the C++ has the same
//   window). So the panel side never calls TrySetPatch or CollectRetiredPatch until Process
//   has rendered two whole blocks since the last hand-over (EngineQuietLocked, counted by
//   FBlocksRendered): by then the take is certainly over. A patch handed over meanwhile is
//   owed, and the next tick pays it.
//
//   THE HOST'S PROGRAM LIST. ProgramCount, CurrentProgram and ProgramName may be called on
//   any thread, while Process runs, and must neither lock nor allocate. ProgramCount is the
//   constant 64 (the directory's size: the C++'s getNumPrograms explains why it must never
//   change). CurrentProgram reads one atomic integer. ProgramName reads an immutable
//   snapshot (TProgramSnapshot: all 64 slot names, as the C++ getProgramName answers them)
//   that the panel side builds and swaps in with one interlocked exchange whenever the disk
//   or the programme changes; the reader returns one of its strings (a reference-count
//   increment, no allocation). A replaced snapshot is freed only once it is safe: a reader
//   increments FSnapshotReaders BEFORE it loads the pointer and decrements it after, so once
//   the swap is done, seeing the count at zero proves no reader still holds the old one (a
//   reader that loaded it would still be counted; one that comes later loads the new one).
//   Until then the old ones wait in a list, which every publish and every PanelTick tries to
//   empty, and the destructor empties for good.
//
//   THE SYNTH RENDER runs as the C++'s does: SetRecipe keeps the recipe and makes a render
//   due 100 ms later; PanelTick starts one TMz950RenderThread at a time, with copies of the
//   recipe and of the disk it will replace; it signals Done through an atomic flag; the next
//   PanelTick joins it and adopts the disk (programme 0, a new generation, the host told) -
//   unless a disk was loaded meanwhile, in which case the result is dropped. A knob turned
//   while one runs leaves another due, which starts when that one is finished. The wave
//   cache belongs to the render thread (there is only ever one). The destructor joins it.
//
// MIDI: the C++'s fixed controller table (General MIDI's sound controllers, and the
// undefined numbers it took), with the same behaviour per control: a trim follows its CC
// across its range and is heard from this block; 65 and 107 switch glide and wide at their
// own sample; 106 sets the voice count in eight bands of sixteen; and so on. Added to the
// C++: MIDI learn, as the Mz909's - every parameter answers to one CC or none, each CC
// drives one parameter at most, the first learnable CC to arrive while one waits is taken
// by it, and the map is saved in the state by parameter id.
//
// What else differs from the C++, and why:
//   - A CC moves a parameter with SetParameter, which reaches the host a moment later from
//     its message thread; until then the engine is given the new value (TPendingValue, as
//     the Mz909's), so it is heard from this block as the C++'s setValueNotifyingHost is.
//   - A block of no samples still posts its MIDI (at sample 0 of the next block); the C++
//     returns first and loses it, which can leave a note hanging.
//   - The state is the plug-in's own binary format (see SaveState), not the C++'s XML; it
//     also keeps the editor's tab and the MIDI map. A state with no disk goes back to the
//     placeholder rather than keeping whatever was loaded. A state loaded while a synth
//     render runs drops its result, as loading a disk does.
//   - An edit (SetKeygroupValue) cannot mark the host's project dirty: the framework has
//     no updateHostDisplay (nonParameterStateChanged) to call.
//   - gain and glideTime are linear for the host: the framework has no skewed ranges. The
//     C++'s skew is kept for CC 5 (Mz950Params.CcToValue).

unit Mz950Plugin;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$MINFPCONSTPREC 64}   // a real literal is a double, as in C++
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}
// whether overflow and range checks are on, to put them back after BlocksSince
{$IFOPT Q+}{$DEFINE MZ950_CHECKS_Q}{$ENDIF}
{$IFOPT R+}{$DEFINE MZ950_CHECKS_R}{$ENDIF}

interface

uses
  SysUtils, Classes, SyncObjs, JucePlugin, JuceTypes,
  S950Math, S950Patch, S950Engine, S950Disk, S950SynthPatch, Mz950Params;

const
  // The host's program slots: the directory's 64 entries, whatever the disk (see
  // VirtualS950Processor::getNumPrograms).
  ProgramSlots = 64;

  // How long after the last SetRecipe a render starts.
  RenderDebounceMs = 100;

  // How often the housekeeping thread looks.
  HousekeepingMs = 30;

  // The editor's tabs (the C++ editorTab): 0 Program, 1 Perform, 2 Synth.
  EditorTabCount = 3;

type
  // VirtualS950Processor::EnvelopeShape: one keygroup's envelope, for the panel to draw.
  TEnvelopeShape = record
    Attack, Decay, Sustain, Release: Integer;
    Written: Boolean;        // False for an S900 programme, whose filter bytes were blank
    HasRelease: Boolean;
  end;

  // VirtualS950Processor::KeygroupActivity.
  TKeygroupActivity = record
    Hits: UInt32;            // notes answered since the engine was built
    LastNote: Integer;       // -1 for none
    Sounding: Boolean;       // a voice is playing it now
  end;

  // A value the plug-in has set (from a CC) that the host has not reported back yet: see
  // TMz950.SetOwnParameter. (The Mz909's.)
  TPendingValue = record
    Active: Boolean;
    Value: Single;
    From: Single;
    Age: Integer;
  end;

  // What ProgramName answers from: every slot's name, never changed once published.
  TProgramSnapshot = class
  public
    Names: array[0..ProgramSlots - 1] of string;
  end;

  TMz950 = class;

  TMz950Housekeeper = class(TThread)
  private
    FOwner: TMz950;
  protected
    procedure Execute; override;
  end;

  TMz950RenderThread = class(TThread)
  private
    FRecipe: TRecipe;
    FCache: TWaveCache;
    FPrevious: TS950Disk;     // owned
    FRendered: TS950Disk;     // owned until taken
    FFailure: string;
    FDone: TAtomicBool;
  protected
    procedure Execute; override;
  public
    destructor Destroy; override;
  end;

  TMz950 = class(TJucePlugin)
  private
    // ---- the audio thread's (Process) ----
    FEngine: TS950Engine;                 // replaced only by Prepare, under FLock
    FLeft, FRight: array of Single;       // the engine's two channels, sized in Prepare
    FHostValues: array[0..NumParams - 1] of Single;
    FValues: array[0..NumParams - 1] of Single;
    FPending: array[0..NumParams - 1] of TPendingValue;
    FPendingTimeout: Integer;
    FGlidePosted, FVoicesPosted, FWidePosted: Integer;   // -1: not yet
    FHeldNotes: array[0..1] of Int64;     // written by Process only, read anywhere
    FClearPending: Integer;               // ResetPerformance asks Process to drop them

    // ---- the CC map, shared through atomics ----
    FCcOf: array[0..NumParams - 1] of Integer;   // -1 for none
    FLearning: Integer;
    FMapVersion: Integer;

    // ---- the panel side, under FLock ----
    FLock: TCriticalSection;
    FWake: TEvent;
    FHousekeeper: TMz950Housekeeper;
    FPatch: TS950Patch;                   // what plays; one reference
    FPatchOwed: Boolean;
    FDisk: TS950Disk;
    FDiskSerial: Integer;                 // bumped whenever FDisk is another disk
    FDiskPath: string;
    FProgramNames: TArray<string>;
    FSelected: Integer;
    FSynthDisk: Boolean;
    FRecipe: TRecipe;
    FWaveCache: TWaveCache;               // the render thread's
    FRenderWanted: Boolean;
    FRenderDueAt: Int64;
    FRenderThread: TMz950RenderThread;
    FRenderDropped: Boolean;
    FRenderError: string;
    FNotifyPrograms: Boolean;             // tell the host once FLock is let go
    FPackedImage: TBytes;                 // the last SaveState's gzip, and what it was of
    FPackedSerial, FPackedRevision: Integer;

    // ---- read anywhere (atomics) ----
    FDiskGeneration: Integer;
    FEditRevision: Integer;
    FCurrentProgram: Integer;             // max (0, FSelected), for CurrentProgram
    FHostOutOfStep: Integer;
    FBlocksRendered: Integer;             // Process: blocks that called Render, wrapping
    FHandOverOpen: Boolean;               // under FLock: a patch handed over, maybe not taken yet
    FHandOverAt: Integer;                 // FBlocksRendered when it was
    FSnapshot: Pointer;                   // TProgramSnapshot
    FSnapshotReaders: Integer;
    FRetiredSnapshots: TList;             // under FLock
    FTail: Double;

    // panel side
    procedure Lock;
    procedure Unlock;
    procedure EnsureHousekeeper;
    procedure SendPatchLocked;
    procedure PublishProgramsLocked;
    procedure FreeRetiredSnapshotsLocked;
    function NthProgramLocked(Index: Integer; out E: TDiskEntry): Boolean;
    function SelectedEntryLocked(out E: TDiskEntry): Boolean;
    procedure SelectProgramLocked(Index: Integer; FromHost: Boolean);
    function AdoptDiskLocked(Opened: TS950Disk; out Error: string): Boolean;
    procedure DropDiskLocked;
    function TakeDisk(Opened: TS950Disk; const Path: string; out Error: string): Boolean;
    procedure SetRecipeLocked(const R: TRecipe);
    procedure StartRenderLocked;
    procedure FinishRenderLocked;

    // the CC map
    procedure ResetCcs;
    procedure AssignCc(Index, Cc: Integer);

    // audio
    procedure ReadValues(const Ctx: TJuceProcessContext);
    procedure SetOwnParameter(Index: Integer; Value: Single);
    procedure HoldNote(Note: Integer; Down: Boolean);
    procedure Handle(const Event: TJuceMidiEvent; At: Integer);
    procedure ApplyCc(Index, Value, At: Integer);
    procedure StoreTrims;
    procedure ProcessBlock(const Ctx: TJuceProcessContext; var Rendered: Boolean);
    function EngineQuietLocked: Boolean;
  public
    // Which tab the window last showed - 0 Program, 1 Perform, 2 Synth - so reopening it
    // comes back where it was. (Saved with the state here; the C++ keeps it per session.)
    EditorTab: Integer;

    constructor Create; override;
    destructor Destroy; override;
    procedure Prepare(ASampleRate: Double; AMaxBlockSize: Integer); override;
    procedure Process(const Ctx: TJuceProcessContext); override;
    function SaveState: TBytes; override;
    procedure LoadState(const Data: TBytes); override;
    function TailSeconds: Double; override;
    function ParameterToText(Index: Integer; Value: Single; out Text: string): Boolean; override;
    function CreateEditor: TJuceEditorBase; override;

    // The host's programs: the disk's programmes on 64 fixed slots. See the unit header.
    function ProgramCount: Integer; override;
    function CurrentProgram: Integer; override;
    procedure SelectProgram(Index: Integer); override;     // the host's choice
    function ProgramName(Index: Integer): string; override;

    // ------------------------------------------------------------- for the editor
    // (message thread, unless said otherwise)

    // How many voices are sounding. Approximate by nature.
    function GetActiveVoices: Integer;
    // What is loaded, for the panel to name ('Placeholder saw' with no disk).
    function GetPatchName: string;
    // The first keygroup with a sample's envelope (amplitude, or Filter).
    function GetEnvelope(Filter: Boolean): TEnvelopeShape;

    // Open an image (.img or .hfe) and play its first programme; every Perform setting
    // back to its start (ResetPerformance) and a synth render queued or running dropped.
    function LoadDisk(const Path: string; out Error: string): Boolean;
    // The same with the file's bytes already read (the panel's file dialog): Name is what
    // GetDiskName returns (the C++ names a disk by its full path), Path what GetDiskPath does.
    function LoadDiskBytes(const Name, Path: string; const Bytes: TBytes; out Error: string): Boolean;
    // Every parameter but gain and bend range to its default, through the host.
    procedure ResetPerformance;

    // The disk's programmes, in directory order (empty with no disk).
    function GetProgramNames: TArray<string>;
    // Play one of them (the C++ selectProgram; the host is told). Out of range does nothing.
    procedure SelectProgramFromPanel(Index: Integer);
    function GetSelectedProgram: Integer;       // -1 for none; any thread
    function GetDiskName: string;
    function GetDiskPath: string;
    function GetBadSectors: Integer;
    function GetMissingSectors: Integer;
    // Bumped whenever the disk or the programme changes, however. Any thread.
    function GetDiskGeneration: Integer;

    // The selected programme's keygroups, read and changed in place on the disk image.
    // Kg is 0-based; -1 means every keygroup at once (SetKeygroupValue only).
    function GetKeygroupCount: Integer;
    function GetKeygroupValue(Kg: Integer; P: TKeygroupParam): Integer;
    procedure SetKeygroupValue(Kg: Integer; P: TKeygroupParam; V: Integer);
    function IsVcfBlank(Kg: Integer): Boolean;
    // The sample a keygroup's zone (1 soft, 2 loud) plays, or ''.
    function GetZoneSample(Kg, Zone: Integer): string;
    // Bumped by every edit (and every finished render). Any thread.
    function GetEditRevision: Integer;
    function GetKeygroupActivity(Kg: Integer): TKeygroupActivity;
    // A key held down over MIDI right now. Any thread.
    function IsNoteHeld(Note: Integer): Boolean;

    // The Synth tab's recipe, and its rendering to a disk.
    function GetRecipe: TRecipe;
    procedure SetRecipe(const R: TRecipe);      // keep it, and render it shortly
    function IsRendering: Boolean;
    function GetRenderError: string;
    function DiskIsSynth: Boolean;

    // The disk as it now stands, edits and all, as a plain sector image.
    function SaveDiskAs(const Path: string; out Error: string): Boolean;
    function SaveDiskBytes: TBytes;             // the same bytes, for a SaveFile handler; nil with no disk

    // The C++ timerCallback's work (see the unit header). Any thread but the audio thread;
    // the housekeeping thread runs it every 30 ms, and the editor's timer may as well.
    procedure PanelTick;

    // MIDI CC assignments, by parameter index (an addition: the C++ has a fixed table).
    // Any thread.
    function CcFor(Index: Integer): Integer;    // -1 for none
    procedure Learn(Index: Integer);            // -1 cancels
    function LearningIndex: Integer;
    procedure ForgetCc(Index: Integer);
    procedure RestoreDefaultCc(Index: Integer);
    procedure ResetAllCcs;
    function MidiMapVersion: Integer;           // changes whenever the map or learning does

    // For the checks.
    function PatchOwed: Boolean;
    function HousekeeperRunning: Boolean;
    property Engine: TS950Engine read FEngine;
  end;

// Declares the parameters and registers TMz950. Call once, from the library's begin..end.
procedure RegisterMz950;

// The placeholder the C++ plays until a disk is loaded: eight cycles of a sawtooth, looped
// (makePlaceholderPatch). The caller holds the one reference.
function MakePlaceholderPatch: TS950Patch;

// A recipe with every setting held to the range its knob has (a saved one is untrusted).
function SanitisedRecipe(const R: TRecipe): TRecipe;

implementation

uses
  S950Cal, S950Voice, Mz950Gzip
  {$IFNDEF MZ950_NO_EDITOR}, Mz950Editor{$ENDIF};

// ------------------------------------------------------------------------ helpers

function NowMs: Int64;
begin
  {$IFDEF FPC}
  Result := Int64(GetTickCount64);
  {$ELSE}
  Result := Int64(TThread.GetTickCount64);
  {$ENDIF}
end;

function LoadPointer(var P: Pointer): Pointer; inline;
begin
  {$IFDEF FPC}
  Result := InterlockedCompareExchange(P, nil, nil);
  {$ELSE}
  Result := AtomicCmpExchange(P, nil, nil);
  {$ENDIF}
end;

function ExchangePointer(var P: Pointer; V: Pointer): Pointer; inline;
begin
  {$IFDEF FPC}
  Result := InterlockedExchange(P, V);
  {$ELSE}
  Result := AtomicExchange(P, V);
  {$ENDIF}
end;

// True if Target was Expected (and is now Value).
function AtomicCas(var Target: Integer; Value, Expected: Integer): Boolean; inline;
begin
  {$IFDEF FPC}
  Result := InterlockedCompareExchange(Target, Value, Expected) = Expected;
  {$ELSE}
  Result := AtomicCmpExchange(Target, Value, Expected) = Expected;
  {$ENDIF}
end;

function Clamp(V, Lo, Hi: Integer): Integer; inline;
begin
  if V < Lo then Result := Lo
  else if V > Hi then Result := Hi
  else Result := V;
end;

function SanitisedRecipe(const R: TRecipe): TRecipe;
var
  I: Integer;
begin
  Result := R;
  if Length(Result.Name) > 64 then
    SetLength(Result.Name, 64);
  for I := 0 to 2 do
    with Result.Osc[I] do
    begin
      if (Ord(Kind) < 0) or (Ord(Kind) >= Ord(okCount)) then Kind := okOff;
      Level := Clamp(Level, 0, 99);
      Octave := Clamp(Octave, -2, 2);
      Fine := Clamp(Fine, -50, 50);
      Phase := Clamp(Phase, 0, 99);
      Intensity := Clamp(Intensity, 0, 99);
      Sweep := Clamp(Sweep, 0, 99);
    end;
  for I := 0 to DrumSlotCount - 1 do
    with Result.Drums[I] do
    begin
      Tune := Clamp(Tune, -12, 12);
      Decay := Clamp(Decay, 0, 99);
      Tone := Clamp(Tone, 0, 99);
      Level := Clamp(Level, -50, 50);
    end;
  Result.Filter := Clamp(Result.Filter, 0, 99);
  Result.KeyTrack := Clamp(Result.KeyTrack, 0, 99);
  Result.VelFilter := Clamp(Result.VelFilter, 0, 99);
  Result.A := Clamp(Result.A, 0, 99);
  Result.D := Clamp(Result.D, 0, 99);
  Result.S := Clamp(Result.S, 0, 99);
  Result.R := Clamp(Result.R, 0, 99);
  Result.VcfA := Clamp(Result.VcfA, 0, 99);
  Result.VcfD := Clamp(Result.VcfD, 0, 99);
  Result.VcfS := Clamp(Result.VcfS, 0, 99);
  Result.VcfR := Clamp(Result.VcfR, 0, 99);
  Result.VcfAmount := Clamp(Result.VcfAmount, -50, 50);
  Result.VelLoudness := Clamp(Result.VelLoudness, 0, 99);
  Result.LfoRate := Clamp(Result.LfoRate, 0, 99);
  Result.LfoDepth := Clamp(Result.LfoDepth, 0, 99);
  Result.LfoDelay := Clamp(Result.LfoDelay, 0, 99);
end;

function MakePlaceholderPatch: TS950Patch;
const
  // Eight cycles rather than one, so the loop is a whole number of samples AND of cycles:
  // 1468 samples at 48 kHz is middle C to three hundredths of a cent.
  Cycles = 8;
  Words = 1468;
var
  Sound: TS950Sound;
  K: TKeygroupPatch;
  I: Integer;
  Phase: Double;
  S: Single;
begin
  Sound := TS950Sound.Create;
  Sound.Name := 'SAW';
  Sound.SourceRate := 48000;
  Sound.RootPitch := 60.0;
  SetLength(Sound.Audio, Words);
  for I := 0 to Words - 1 do
  begin
    Phase := FmodD(I * Cycles / Words, 1.0);
    S := Phase * 2.0 - 1.0;
    Sound.Audio[I] := S;
  end;
  Sound.Loops := True;
  Sound.LoopFrom := 0;
  Sound.LoopTo := Words;

  Result := TS950Patch.Create;
  Result.Name := 'Placeholder saw';

  K.Init;
  K.LowKey := 0;
  K.HighKey := 127;
  K.KeygroupIndex := 0;
  K.Sound := Sound;
  K.VcaAttack := 0;
  K.VcaDecay := 0;
  K.VcaSustain := 99;
  K.VcaRelease := 25;
  K.ZoneFilter := 70;          // something to hear the filter doing its job
  K.KeyToFilter := 50;         // measured: 50 is one-for-one tracking
  K.LfoDesync := True;
  Result.Add(K);               // the patch takes its own reference to the sound
  ReleaseSound(Sound);
end;

{ TMz950Housekeeper }

procedure TMz950Housekeeper.Execute;
begin
  while not Terminated do
  begin
    FOwner.FWake.WaitFor(HousekeepingMs);
    if Terminated then
      Break;
    try
      FOwner.PanelTick;
    except
      // nothing escapes a thread; the next tick tries again
    end;
  end;
end;

{ TMz950RenderThread }

procedure TMz950RenderThread.Execute;
var
  Out_: TS950Disk;
  Why: string;
begin
  Out_ := nil;
  try
    Out_ := TS950Disk.Create;
    Why := '';
    if Render(FRecipe, FCache, FPrevious, Out_, Why) then
    begin
      FRendered := Out_;
      Out_ := nil;
    end;
    FFailure := Why;
  except
    on E: Exception do
      FFailure := 'the render failed: ' + E.Message;
  end;
  Out_.Free;
  FDone.Store(True);
end;

destructor TMz950RenderThread.Destroy;
begin
  inherited Destroy;          // joins
  FPrevious.Free;
  FRendered.Free;
end;

{ TMz950 }

constructor TMz950.Create;
var
  I: Integer;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FRetiredSnapshots := TList.Create;
  FWaveCache := TWaveCache.Create;
  FPatch := MakePlaceholderPatch;
  FSelected := -1;
  FRecipe := NewRecipe;
  FPendingTimeout := 48000;
  FGlidePosted := -1;
  FVoicesPosted := -1;
  FWidePosted := -1;
  FLearning := -1;
  FPackedSerial := -1;
  for I := 0 to NumParams - 1 do
  begin
    FHostValues[I] := DefaultValue(I);
    FValues[I] := DefaultValue(I);
  end;
  ResetCcs;
  // The longest release the machine can be told to do, so a host does not cut a note off.
  FTail := EnvSeconds(99);
  FSnapshot := nil;
  Lock;
  try
    PublishProgramsLocked;
  finally
    Unlock;
  end;
end;

destructor TMz950.Destroy;
var
  I: Integer;
begin
  if FHousekeeper <> nil then
  begin
    FHousekeeper.Terminate;
    FWake.SetEvent;
    FHousekeeper.WaitFor;
    FreeAndNil(FHousekeeper);
  end;
  // a render still running holds copies of its own; let it finish rather than tear the
  // cache out from under it
  FreeAndNil(FRenderThread);
  FreeAndNil(FEngine);
  ReleasePatch(FPatch);
  FreeAndNil(FDisk);
  FreeAndNil(FWaveCache);
  for I := 0 to FRetiredSnapshots.Count - 1 do
    TObject(FRetiredSnapshots[I]).Free;
  FreeAndNil(FRetiredSnapshots);
  TObject(FSnapshot).Free;
  FSnapshot := nil;
  FreeAndNil(FWake);
  FreeAndNil(FLock);
  inherited Destroy;
end;

function TMz950.CreateEditor: TJuceEditorBase;
begin
  {$IFDEF MZ950_NO_EDITOR}
  Result := nil;
  {$ELSE}
  Result := TMz950Editor.Create(Self);
  {$ENDIF}
end;

{ ---- the panel side's lock ---- }

procedure TMz950.Lock;
begin
  FLock.Enter;
end;

// Let go, and tell the host what changed while it was held - not from inside, so a host
// answering at once (getProgramName ...) never finds the lock taken by its own caller.
procedure TMz950.Unlock;
var
  Notify: Boolean;
begin
  Notify := FNotifyPrograms;
  FNotifyPrograms := False;
  FLock.Leave;
  if Notify then
    ProgramsChanged;
end;

procedure TMz950.EnsureHousekeeper;
begin
  if FHousekeeper <> nil then
    Exit;
  FHousekeeper := TMz950Housekeeper.Create(True);
  FHousekeeper.FOwner := Self;
  FHousekeeper.FreeOnTerminate := False;
  FHousekeeper.Start;
end;

function TMz950.HousekeeperRunning: Boolean;
begin
  Lock;
  try
    Result := FHousekeeper <> nil;
  finally
    Unlock;
  end;
end;

function TMz950.PatchOwed: Boolean;
begin
  Lock;
  try
    Result := FPatchOwed;
  finally
    Unlock;
  end;
end;

// Give the engine the patch now, or remember that it is owed and let the next tick pay it.
procedure TMz950.SendPatchLocked;
begin
  // No engine yet is not a debt: Prepare hands the current patch to the one it builds.
  if FEngine = nil then
  begin
    FPatchOwed := False;
    Exit;
  end;
  // Not while the last hand-over may still be in progress on the audio thread: see
  // EngineQuietLocked. The next tick tries again.
  if not EngineQuietLocked then
    FPatchOwed := True
  else if FEngine.TrySetPatch(FPatch) then
  begin
    FPatchOwed := False;
    FHandOverOpen := True;
    FHandOverAt := AtomicLoad(FBlocksRendered);
  end
  else
    FPatchOwed := True;
  if FPatchOwed then
  begin
    EnsureHousekeeper;
    FWake.SetEvent;
  end;
end;

// Blocks rendered since Then_, the counter wrapping as it likes.
{$Q-}{$R-}
function BlocksSince(Now_, Then_: Integer): Cardinal;
begin
  Result := Cardinal(Now_) - Cardinal(Then_);
end;
{$IFDEF MZ950_CHECKS_Q}{$Q+}{$ENDIF}{$IFDEF MZ950_CHECKS_R}{$R+}{$ENDIF}

// May the panel side touch the engine's patch hand-over (TrySetPatch, CollectRetiredPatch)
// now? Not while Process may be inside the engine's take of the patch last handed over.
//
// The engine's take (TakePendingPatch, as the C++ takePendingPatch) marks the replaced patch
// ready to collect and THEN reads it, to compare the two patches' shapes. A collect in that
// moment frees the patch under the audio thread's read. So after a hand-over the panel side
// waits until Process has rendered two more whole blocks: the block in progress when the
// patch was handed over may have passed its take already, but the one after it started
// later, so it took the patch (nothing was waiting to be collected: TrySetPatch collects
// first), and it has finished. Only blocks that called Render count - a block of no samples
// takes nothing. No Process at all, and the hand-over simply waits, as the patch does.
function TMz950.EngineQuietLocked: Boolean;
begin
  if FHandOverOpen and (BlocksSince(AtomicLoad(FBlocksRendered), FHandOverAt) >= 2) then
    FHandOverOpen := False;
  Result := not FHandOverOpen;
end;

procedure TMz950.PublishProgramsLocked;
var
  S: TProgramSnapshot;
  Old: Pointer;
  I, N: Integer;
begin
  S := TProgramSnapshot.Create;
  N := Length(FProgramNames);
  for I := 0 to ProgramSlots - 1 do
    if I < N then
      S.Names[I] := FProgramNames[I]
    else if N = 0 then
    begin
      // a slot with no disk, or past the end of this one: a name, never a blank row
      if I = 0 then S.Names[I] := 'Placeholder saw' else S.Names[I] := '- no disk -';
    end
    else
      S.Names[I] := '-';
  if FSelected > 0 then
    AtomicStore(FCurrentProgram, FSelected)
  else
    AtomicStore(FCurrentProgram, 0);
  Old := ExchangePointer(FSnapshot, S);
  if Old <> nil then
    FRetiredSnapshots.Add(Old);
  FreeRetiredSnapshotsLocked;
end;

procedure TMz950.FreeRetiredSnapshotsLocked;
var
  I: Integer;
begin
  if FRetiredSnapshots.Count = 0 then
    Exit;
  // Every one in the list was swapped out before now. With no reader counted now, none
  // holds any of them: see the unit header.
  if AtomicLoad(FSnapshotReaders) <> 0 then
    Exit;
  for I := 0 to FRetiredSnapshots.Count - 1 do
    TObject(FRetiredSnapshots[I]).Free;
  FRetiredSnapshots.Clear;
end;

// The nth programme in directory order, which is the order the names were read in.
function TMz950.NthProgramLocked(Index: Integer; out E: TDiskEntry): Boolean;
var
  Entries: TDiskEntryArray;
  I, Seen: Integer;
begin
  Result := False;
  E.Init;
  if (FDisk = nil) or (Index < 0) then
    Exit;
  Entries := FDisk.Entries;
  Seen := 0;
  for I := 0 to High(Entries) do
  begin
    if Entries[I].EntryType <> 'P' then
      Continue;
    if Seen = Index then
    begin
      E := Entries[I];
      Result := True;
      Exit;
    end;
    Inc(Seen);
  end;
end;

function TMz950.SelectedEntryLocked(out E: TDiskEntry): Boolean;
begin
  Result := (FDisk <> nil) and (FSelected >= 0) and NthProgramLocked(FSelected, E);
end;

procedure TMz950.SelectProgramLocked(Index: Integer; FromHost: Boolean);
var
  E: TDiskEntry;
  Built: TS950Patch;
begin
  if (FDisk = nil) or (Index < 0) or (Index >= Length(FProgramNames)) then
    Exit;
  if not NthProgramLocked(Index, E) then
    Exit;

  // Reusing the current patch's samples where the bytes are the same: a programme change
  // decodes only what is new, and a held note keeps its sample object.
  Built := FDisk.BuildPatch(E, FPatch);
  if Built = nil then
    Exit;
  if Length(Built.Keygroups) = 0 then
  begin
    ReleasePatch(Built);           // leave what is playing alone
    Exit;
  end;

  FSelected := Index;
  ReleasePatch(FPatch);
  FPatch := Built;
  SendPatchLocked;
  AtomicIncrement32(FDiskGeneration);
  PublishProgramsLocked;

  // And tell the host, so its chooser follows this one - unless the host is where the
  // change came from.
  if not FromHost then
    FNotifyPrograms := True;
end;

function TMz950.AdoptDiskLocked(Opened: TS950Disk; out Error: string): Boolean;
var
  Names: TArray<string>;
  Entries: TDiskEntryArray;
  I, N: Integer;
begin
  Result := False;
  Error := '';
  if Opened = nil then
  begin
    Error := 'no disk';
    Exit;
  end;
  Entries := Opened.Entries;
  N := 0;
  SetLength(Names, Length(Entries));
  for I := 0 to High(Entries) do
    if Entries[I].EntryType = 'P' then
    begin
      Names[N] := Entries[I].Name;
      Inc(N);
    end;
  SetLength(Names, N);
  if N = 0 then
  begin
    Error := 'that disk has no programmes on it';
    Exit;
  end;

  FDisk.Free;
  FDisk := Opened;
  Inc(FDiskSerial);
  FDiskPath := '';
  FProgramNames := Names;
  FSelected := -1;

  SelectProgramLocked(0, False);
  AtomicIncrement32(FDiskGeneration);
  // a new set of names on the same 64 slots
  PublishProgramsLocked;
  FNotifyPrograms := True;
  Result := True;
end;

// No disk: the placeholder again.
procedure TMz950.DropDiskLocked;
begin
  FreeAndNil(FDisk);
  Inc(FDiskSerial);
  FDiskPath := '';
  FProgramNames := nil;
  FSelected := -1;
  FSynthDisk := False;
  ReleasePatch(FPatch);
  FPatch := MakePlaceholderPatch;
  SendPatchLocked;
  AtomicIncrement32(FDiskGeneration);
  PublishProgramsLocked;
  FNotifyPrograms := True;
end;

// A disk from a file (LoadDisk, LoadDiskBytes): the C++ loadDisk, after reading.
function TMz950.TakeDisk(Opened: TS950Disk; const Path: string; out Error: string): Boolean;
begin
  Lock;
  try
    Result := AdoptDiskLocked(Opened, Error);
    if not Result then
    begin
      Opened.Free;
      Exit;
    end;
    FDiskPath := Path;
    FSynthDisk := False;
    // A render asked for before this disk was opened would land on top of it.
    FRenderWanted := False;
    FRenderDropped := FRenderThread <> nil;
  finally
    Unlock;
  end;
  ResetPerformance;
end;

function TMz950.LoadDisk(const Path: string; out Error: string): Boolean;
var
  Opened: TS950Disk;
begin
  Result := False;
  Error := '';
  try
    Opened := TS950Disk.Create;
    if not Opened.LoadFile(Path, Error) then
    begin
      Opened.Free;
      Exit;
    end;
    Result := TakeDisk(Opened, Path, Error);
  except
    on E: Exception do
    begin
      Error := E.Message;
      Result := False;
    end;
  end;
end;

function TMz950.LoadDiskBytes(const Name, Path: string; const Bytes: TBytes; out Error: string): Boolean;
var
  Opened: TS950Disk;
begin
  Result := False;
  Error := '';
  try
    Opened := TS950Disk.Create;
    if not Opened.LoadBytes(Name, Bytes, Error) then
    begin
      Opened.Free;
      Exit;
    end;
    Result := TakeDisk(Opened, Path, Error);
  except
    on E: Exception do
    begin
      Error := E.Message;
      Result := False;
    end;
  end;
end;

procedure TMz950.ResetPerformance;
var
  I: Integer;
begin
  // Process drops what CCs set and the host has not delivered: the reset is newer.
  AtomicStore(FClearPending, 1);
  for I := 0 to NumParams - 1 do
  begin
    if (I = PGain) or (I = PBendRange) then
      Continue;
    // through the host, so an automation lane or a control surface follows
    BeginGesture(I);
    SetParameter(I, Specs[I].Def);
    EndGesture(I);
  end;
end;

function TMz950.GetProgramNames: TArray<string>;
begin
  Lock;
  try
    Result := Copy(FProgramNames);
  finally
    Unlock;
  end;
end;

procedure TMz950.SelectProgramFromPanel(Index: Integer);
begin
  Lock;
  try
    SelectProgramLocked(Index, False);
  finally
    Unlock;
  end;
end;

function TMz950.GetSelectedProgram: Integer;
begin
  Lock;
  try
    Result := FSelected;
  finally
    Unlock;
  end;
end;

function TMz950.GetDiskName: string;
begin
  Lock;
  try
    if FDisk <> nil then Result := FDisk.Name else Result := '';
  finally
    Unlock;
  end;
end;

function TMz950.GetDiskPath: string;
begin
  Lock;
  try
    Result := FDiskPath;
  finally
    Unlock;
  end;
end;

function TMz950.GetBadSectors: Integer;
begin
  Lock;
  try
    if FDisk <> nil then Result := FDisk.BadCrcSectors else Result := 0;
  finally
    Unlock;
  end;
end;

function TMz950.GetMissingSectors: Integer;
begin
  Lock;
  try
    if FDisk <> nil then Result := FDisk.MissingSectors else Result := 0;
  finally
    Unlock;
  end;
end;

function TMz950.GetDiskGeneration: Integer;
begin
  Result := AtomicLoad(FDiskGeneration);
end;

{ ---- editing the programme ---- }

function TMz950.GetKeygroupCount: Integer;
var
  E: TDiskEntry;
begin
  Lock;
  try
    if SelectedEntryLocked(E) then
      Result := TS950Disk.KeygroupCount(E)
    else
      Result := 0;
  finally
    Unlock;
  end;
end;

function TMz950.GetKeygroupValue(Kg: Integer; P: TKeygroupParam): Integer;
var
  E: TDiskEntry;
begin
  Lock;
  try
    if SelectedEntryLocked(E) then
      Result := FDisk.GetKeygroupParam(E, Kg, P)
    else
      Result := 0;
  finally
    Unlock;
  end;
end;

function TMz950.IsVcfBlank(Kg: Integer): Boolean;
var
  E: TDiskEntry;
begin
  Lock;
  try
    Result := SelectedEntryLocked(E) and FDisk.VcfBlank(E, Kg);
  finally
    Unlock;
  end;
end;

function TMz950.GetZoneSample(Kg, Zone: Integer): string;
var
  E: TDiskEntry;
  Groups: TDiskKeygroupArray;
  Z: TDiskZone;
begin
  Result := '';
  Lock;
  try
    if not SelectedEntryLocked(E) then
      Exit;
    Groups := FDisk.Keygroups(E);
    if (Kg < 0) or (Kg >= Length(Groups)) then
      Exit;
    if Zone = 2 then Z := Groups[Kg].Zone2 else Z := Groups[Kg].Zone1;
    if Z.InUse then
      Result := Z.Name;
  finally
    Unlock;
  end;
end;

procedure TMz950.SetKeygroupValue(Kg: Integer; P: TKeygroupParam; V: Integer);
var
  E: TDiskEntry;
  Count, From, To_, K: Integer;
  Rebuilt: TS950Patch;
begin
  Lock;
  try
    if not SelectedEntryLocked(E) then
      Exit;
    Count := TS950Disk.KeygroupCount(E);
    if Kg < 0 then
    begin
      From := 0;
      To_ := Count;
    end
    else
    begin
      From := Kg;
      To_ := MinI(Kg + 1, Count);
    end;

    for K := From to To_ - 1 do
    begin
      // An S900 programme's blank filter envelope ignores its VCF amount, so an amount
      // dialled in would do nothing at all: the flat 0/0/99/0 goes under it first.
      if (P = kpVcfAmount) and FDisk.VcfBlank(E, K) then
        FDisk.SetKeygroupParam(E, K, kpVcfSustain, 99);
      FDisk.SetKeygroupParam(E, K, P, V);
    end;

    // Rebuilt from the disk rather than patched in memory, so what plays is always what a
    // reload would give; reusing the current patch's samples keeps held notes following.
    Rebuilt := FDisk.BuildPatch(E, FPatch);
    if Rebuilt <> nil then
    begin
      if Length(Rebuilt.Keygroups) > 0 then
      begin
        ReleasePatch(FPatch);
        FPatch := Rebuilt;
        SendPatchLocked;
      end
      else
        ReleasePatch(Rebuilt);
    end;

    AtomicIncrement32(FEditRevision);
  finally
    Unlock;
  end;
end;

function TMz950.GetEditRevision: Integer;
begin
  Result := AtomicLoad(FEditRevision);
end;

function TMz950.GetKeygroupActivity(Kg: Integer): TKeygroupActivity;
var
  I: Integer;
  V: PS950Voice;
begin
  Result.Hits := 0;
  Result.LastNote := -1;
  Result.Sounding := False;
  Lock;
  try
    if (FEngine = nil) or (Kg < 0) or (Kg >= EngineActivitySlots) then
      Exit;
    Result.Hits := FEngine.GetKeygroupHits(Kg);
    Result.LastNote := FEngine.GetKeygroupLastNote(Kg);
    for I := 0 to EnginePolyphony - 1 do
    begin
      V := FEngine.GetVoice(I);
      if (V <> nil) and V^.IsActive and (V^.GetKeygroupIndex = Kg) then
      begin
        Result.Sounding := True;
        Break;
      end;
    end;
  finally
    Unlock;
  end;
end;

function TMz950.IsNoteHeld(Note: Integer): Boolean;
begin
  if (Note < 0) or (Note > 127) then
    Result := False
  else
    Result := ((AtomicLoad64(FHeldNotes[Note shr 6]) shr (Note and 63)) and 1) <> 0;
end;

{ ---- the synth ---- }

function TMz950.GetRecipe: TRecipe;
begin
  Lock;
  try
    Result := FRecipe;
  finally
    Unlock;
  end;
end;

procedure TMz950.SetRecipeLocked(const R: TRecipe);
begin
  FRecipe := R;
  FRenderWanted := True;
  // A tenth of a second after the last change: a knob mid-drag does not render every step.
  FRenderDueAt := NowMs + RenderDebounceMs;
  EnsureHousekeeper;
end;

procedure TMz950.SetRecipe(const R: TRecipe);
begin
  Lock;
  try
    SetRecipeLocked(R);
  finally
    Unlock;
  end;
end;

function TMz950.IsRendering: Boolean;
begin
  Lock;
  try
    Result := FRenderThread <> nil;
  finally
    Unlock;
  end;
end;

function TMz950.GetRenderError: string;
begin
  Lock;
  try
    Result := FRenderError;
  finally
    Unlock;
  end;
end;

function TMz950.DiskIsSynth: Boolean;
begin
  Lock;
  try
    Result := FSynthDisk;
  finally
    Unlock;
  end;
end;

procedure TMz950.StartRenderLocked;
var
  T: TMz950RenderThread;
begin
  FRenderWanted := False;
  // The thread gets copies: the recipe as it is now, and the disk it will replace (for the
  // settings a render keeps), so nothing done here meanwhile can reach it.
  T := TMz950RenderThread.Create(True);
  T.FreeOnTerminate := False;
  T.FRecipe := FRecipe;
  UniqueString(T.FRecipe.Name);
  T.FCache := FWaveCache;
  T.FDone.Store(False);
  if FDisk <> nil then
  begin
    T.FPrevious := TS950Disk.Create;
    T.FPrevious.Assign(FDisk);
  end;
  FRenderThread := T;
  T.Start;
end;

procedure TMz950.FinishRenderLocked;
var
  Rendered: TS950Disk;
  Why: string;
begin
  FRenderThread.WaitFor;
  Rendered := FRenderThread.FRendered;
  FRenderThread.FRendered := nil;
  FRenderError := FRenderThread.FFailure;
  FreeAndNil(FRenderThread);

  // A disk was opened while this ran: that is what was asked for last, so it stays.
  if FRenderDropped then
  begin
    FRenderDropped := False;
    FreeAndNil(Rendered);
  end;

  if Rendered <> nil then
  begin
    if AdoptDiskLocked(Rendered, Why) then
    begin
      FSynthDisk := True;
      FDiskPath := '';
    end
    else
    begin
      FRenderError := Why;
      Rendered.Free;
    end;
  end;

  AtomicIncrement32(FEditRevision);    // the Program tab shows the new disk's settings
end;

procedure TMz950.PanelTick;
begin
  Lock;
  try
    if (FEngine <> nil) and EngineQuietLocked then
      FEngine.CollectRetiredPatch;
    if FPatchOwed then
      SendPatchLocked;

    // the synth: collect a finished render, or start one that is due
    if FRenderThread <> nil then
    begin
      if FRenderThread.FDone.Load then
        FinishRenderLocked;
    end
    else if FRenderWanted and (NowMs >= FRenderDueAt) then
      StartRenderLocked;

    // The host chose an empty slot: saying what is current puts its chooser back.
    if AtomicCas(FHostOutOfStep, 0, 1) then
      FNotifyPrograms := True;

    FreeRetiredSnapshotsLocked;
  finally
    Unlock;
  end;
end;

function TMz950.SaveDiskBytes: TBytes;
begin
  Lock;
  try
    if FDisk <> nil then
      Result := Copy(FDisk.Image)
    else
      Result := nil;
  finally
    Unlock;
  end;
end;

function TMz950.SaveDiskAs(const Path: string; out Error: string): Boolean;
var
  Image: TBytes;
  F: TFileStream;
begin
  Result := False;
  Error := '';
  Image := SaveDiskBytes;
  if Image = nil then
  begin
    Error := 'no disk is loaded';
    Exit;
  end;
  try
    F := TFileStream.Create(Path, fmCreate);
    try
      F.WriteBuffer(Image[0], Length(Image));
    finally
      F.Free;
    end;
    Result := True;
  except
    Error := 'could not write ' + Path;
  end;
end;

{ ---- for the editor ---- }

function TMz950.GetActiveVoices: Integer;
begin
  Lock;
  try
    if FEngine <> nil then Result := FEngine.GetActiveVoices else Result := 0;
  finally
    Unlock;
  end;
end;

function TMz950.GetPatchName: string;
begin
  Lock;
  try
    if FPatch <> nil then Result := FPatch.Name else Result := 'nothing loaded';
  finally
    Unlock;
  end;
end;

function TMz950.GetEnvelope(Filter: Boolean): TEnvelopeShape;
var
  I: Integer;
begin
  Result.Attack := 0;
  Result.Decay := 0;
  Result.Sustain := 99;
  Result.Release := 0;
  Result.Written := True;
  Result.HasRelease := True;
  Lock;
  try
    if FPatch = nil then
      Exit;
    for I := 0 to High(FPatch.Keygroups) do
      with FPatch.Keygroups[I] do
      begin
        if (Sound = nil) or (Length(Sound.Audio) = 0) then
          Continue;
        if Filter then
        begin
          // no filter envelope of its own: drawn as the flat one the engine gives it
          Result.Written := VcfWritten;
          if VcfWritten then
          begin
            Result.Attack := VcfAttack;
            Result.Decay := VcfDecay;
            Result.Sustain := VcfSustain;
            Result.Release := VcfRelease;
          end;
        end
        else
        begin
          Result.Attack := VcaAttack;
          Result.Decay := VcaDecay;
          Result.Sustain := VcaSustain;
          Result.Release := VcaRelease;
        end;
        Break;
      end;
  finally
    Unlock;
  end;
end;

{ ---- the host's programs (any thread: no lock, no allocation) ---- }

function TMz950.ProgramCount: Integer;
begin
  Result := ProgramSlots;
end;

function TMz950.CurrentProgram: Integer;
begin
  Result := AtomicLoad(FCurrentProgram);
end;

function TMz950.ProgramName(Index: Integer): string;
var
  S: TProgramSnapshot;
begin
  Result := '';
  if (Index < 0) or (Index >= ProgramSlots) then
    Exit;
  AtomicIncrement32(FSnapshotReaders);       // before the load: see the unit header
  S := TProgramSnapshot(LoadPointer(FSnapshot));
  if S <> nil then
    Result := S.Names[Index];
  AtomicDecrement32(FSnapshotReaders);
end;

procedure TMz950.SelectProgram(Index: Integer);
begin
  Lock;
  try
    // A slot past the end of this disk: nothing to play, so put the host's chooser back -
    // from the next tick, not from inside the host's own call.
    if (Index < 0) or (Index >= Length(FProgramNames)) then
    begin
      AtomicStore(FHostOutOfStep, 1);
      EnsureHousekeeper;
    end
    else
      SelectProgramLocked(Index, True);
  finally
    Unlock;
  end;
end;

{ ---- MIDI learn ---- }

procedure TMz950.ResetCcs;
var
  I: Integer;
begin
  for I := 0 to NumParams - 1 do
    AtomicStore(FCcOf[I], Specs[I].Cc);
  AtomicIncrement32(FMapVersion);
end;

procedure TMz950.AssignCc(Index, Cc: Integer);
var
  I: Integer;
begin
  if (Index < 0) or (Index >= NumParams) or ((Cc <> -1) and not Learnable(Cc)) then
    Exit;
  // whoever had this CC gives it up
  if Cc >= 0 then
    for I := 0 to NumParams - 1 do
      if (I <> Index) and (AtomicLoad(FCcOf[I]) = Cc) then
        AtomicStore(FCcOf[I], -1);
  AtomicStore(FCcOf[Index], Cc);
  AtomicIncrement32(FMapVersion);
end;

function TMz950.CcFor(Index: Integer): Integer;
begin
  if (Index >= 0) and (Index < NumParams) then
    Result := AtomicLoad(FCcOf[Index])
  else
    Result := -1;
end;

procedure TMz950.Learn(Index: Integer);
begin
  if (Index < 0) or (Index >= NumParams) then
    Index := -1;
  AtomicStore(FLearning, Index);
  AtomicIncrement32(FMapVersion);
end;

function TMz950.LearningIndex: Integer;
begin
  Result := AtomicLoad(FLearning);
end;

procedure TMz950.ForgetCc(Index: Integer);
begin
  AssignCc(Index, -1);
end;

procedure TMz950.RestoreDefaultCc(Index: Integer);
begin
  if (Index >= 0) and (Index < NumParams) then
  begin
    if Specs[Index].Cc >= 0 then
      AssignCc(Index, Specs[Index].Cc)
    else
      AssignCc(Index, -1);
  end;
end;

procedure TMz950.ResetAllCcs;
begin
  ResetCcs;
end;

function TMz950.MidiMapVersion: Integer;
begin
  Result := AtomicLoad(FMapVersion);
end;

{ ---- audio ---- }

procedure TMz950.Prepare(ASampleRate: Double; AMaxBlockSize: Integer);
var
  I, Size: Integer;
  Old: TS950Engine;
begin
  Lock;
  try
    // Rebuilt rather than retuned: a voice works out its pitch, filter ceiling and LFO step
    // from the rate it started at. Never while Process runs.
    Old := FEngine;
    FEngine := nil;
    Old.Free;
    FEngine := TS950Engine.Create(ASampleRate);
    FEngine.SetPatch(FPatch);
    FPatchOwed := False;
    FHandOverOpen := True;              // the next block takes it
    FHandOverAt := AtomicLoad(FBlocksRendered);

    // a new engine starts with glide off, eight voices and wide off, whatever the
    // parameters say: the next block tells it
    FGlidePosted := -1;
    FVoicesPosted := -1;
    FWidePosted := -1;

    // Process must not allocate: two channels, a little over the promise.
    Size := AMaxBlockSize;
    if Size < 1024 then
      Size := 1024;
    SetLength(FLeft, Size);
    SetLength(FRight, Size);

    FPendingTimeout := Round(ASampleRate);     // a second: the host has had time
    if FPendingTimeout < 1 then
      FPendingTimeout := 1;
    for I := 0 to NumParams - 1 do
    begin
      FHostValues[I] := GetParameter(I);
      if FPending[I].Active then
        FValues[I] := FPending[I].Value
      else
        FValues[I] := FHostValues[I];
    end;
    EnsureHousekeeper;
  finally
    Unlock;
  end;
end;

procedure TMz950.ReadValues(const Ctx: TJuceProcessContext);
var
  I: Integer;
  P: Single;
begin
  if AtomicCas(FClearPending, 0, 1) then
    for I := 0 to NumParams - 1 do
      FPending[I].Active := False;
  for I := 0 to NumParams - 1 do
  begin
    P := Ctx.Param(I);
    FHostValues[I] := P;
    if FPending[I].Active then
    begin
      if (P <> FPending[I].From) or (P = FPending[I].Value) or (FPending[I].Age >= FPendingTimeout) then
        FPending[I].Active := False   // the host has caught up, or someone else moved it
      else
      begin
        Inc(FPending[I].Age, Ctx.NumSamples);
        P := FPending[I].Value;
      end;
    end;
    FValues[I] := P;
  end;
end;

// A parameter changed from inside the plug-in (a CC): at once for the engine, and for the
// host through SetParameter, which reaches it a moment later in a gesture.
procedure TMz950.SetOwnParameter(Index: Integer; Value: Single);
begin
  FValues[Index] := Value;
  if Value <> FHostValues[Index] then
  begin
    FPending[Index].Active := True;
    FPending[Index].Value := Value;
    FPending[Index].From := FHostValues[Index];
    FPending[Index].Age := 0;
  end
  else
    FPending[Index].Active := False;

  BeginGesture(Index);
  SetParameter(Index, Value);
  EndGesture(Index);
end;

procedure TMz950.HoldNote(Note: Integer; Down: Boolean);
var
  Bit, Word_: Int64;
begin
  if (Note < 0) or (Note > 127) then
    Exit;
  Bit := Int64(1) shl (Note and 63);
  // Process is the only writer, so a load and a store do what fetch_or / fetch_and do.
  Word_ := AtomicLoad64(FHeldNotes[Note shr 6]);
  if Down then
    Word_ := Word_ or Bit
  else
    Word_ := Word_ and not Bit;
  AtomicStore64(FHeldNotes[Note shr 6], Word_);
end;

// A mapped CC: what the C++'s processBlock does for that control's number.
procedure TMz950.ApplyCc(Index, Value, At: Integer);
var
  V: Single;
  On_: Boolean;
begin
  V := CcToValue(Index, Value);
  case Index of
    // glide and wide switch at their own sample, AND move the parameter so the button
    // follows; the posted value is set too, so the next block posts nothing twice
    PGlide:
      begin
        On_ := V >= 0.5;
        FEngine.Glide(On_, At);
        FGlidePosted := Ord(On_);
      end;
    PWide:
      begin
        On_ := V >= 0.5;
        FEngine.Wide(On_, At);
        FWidePosted := Ord(On_);
      end;
    // eight equal bands of sixteen
    PVoices:
      begin
        FEngine.SetVoiceLimit(Round(V), At);
        FVoicesPosted := Round(V);
      end;
  end;
  // set only if it differs, so a held pedal or a resent value does not spam the host
  if V <> FValues[Index] then
    SetOwnParameter(Index, V);
end;

procedure TMz950.Handle(const Event: TJuceMidiEvent; At: Integer);
var
  Status, D1, D2, I, Waiting: Integer;
begin
  if (Event.Data = nil) or (Event.Size < 1) then
    Exit;
  Status := Event.Data[0] and $F0;
  if Event.Size >= 2 then D1 := Event.Data[1] and $7F else D1 := 0;
  if Event.Size >= 3 then D2 := Event.Data[2] and $7F else D2 := 0;

  // every channel plays, as the C++'s (it never asks a message's channel)
  if (Status = $90) and (Event.Size >= 3) and (D2 > 0) then
  begin
    FEngine.NoteOn(D1, D2, At);
    HoldNote(D1, True);
  end
  else if ((Status = $80) or (Status = $90)) and (Event.Size >= 3) then
  begin
    FEngine.NoteOff(D1, At);
    HoldNote(D1, False);
  end
  else if (Status = $B0) and (Event.Size >= 3) then
  begin
    if D1 = 1 then
      FEngine.Modwheel(D2, At)
    else if (D1 = 123) or (D1 = 120) then          // all notes off, all sound off
    begin
      FEngine.AllNotesOff(At);
      AtomicStore64(FHeldNotes[0], 0);
      AtomicStore64(FHeldNotes[1], 0);
    end
    else
    begin
      // MIDI learn: the first learnable CC to arrive is taken, and does nothing else.
      Waiting := AtomicLoad(FLearning);
      if (Waiting >= 0) and Learnable(D1) and AtomicCas(FLearning, -1, Waiting) then
      begin
        AssignCc(Waiting, D1);
        Exit;
      end;
      for I := 0 to NumParams - 1 do
        if AtomicLoad(FCcOf[I]) = D1 then
        begin
          ApplyCc(I, D2, At);
          Break;
        end;
    end;
  end
  else if (Status = $E0) and (Event.Size >= 3) then
    FEngine.PitchBend(D1 or (D2 shl 7), At)
  // Channel pressure drives keygroup byte 21, the LFO's aftertouch depth. The machine has
  // no polyphonic pressure input, so only the channel message counts.
  else if (Status = $D0) and (Event.Size >= 2) then
    FEngine.Aftertouch(D1, At);
end;

procedure TMz950.StoreTrims;
begin
  with FEngine.Trims do
  begin
    Cutoff.Store(FValues[PVcfCutoff]);
    Amount.Store(FValues[PVcfAmount]);
    VcaAttack.Store(FValues[PVcaAttack]);
    VcaDecay.Store(FValues[PVcaDecay]);
    VcaSustain.Store(FValues[PVcaSustain]);
    VcaRelease.Store(FValues[PVcaRelease]);
    VcfAttack.Store(FValues[PVcfAttack]);
    VcfDecay.Store(FValues[PVcfDecay]);
    VcfSustain.Store(FValues[PVcfSustain]);
    VcfRelease.Store(FValues[PVcfRelease]);
    LfoRate.Store(FValues[PLfoRate]);
    LfoDepth.Store(FValues[PLfoDepth]);
    LfoDelay.Store(FValues[PLfoDelay]);
    VelToFilter.Store(FValues[PVelToFilter]);
    VelToLoudness.Store(FValues[PVelToLoudness]);
    Resonance.Store(FValues[PResonance]);
    LfoShape.Store(FValues[PLfoShape]);
    LfoToFilter.Store(FValues[PLfoToFilter]);
    LfoSync.Store(FValues[PLfoSync]);
    LfoSyncDiv.Store(FValues[PLfoSyncDiv]);
  end;
end;

procedure TMz950.Process(const Ctx: TJuceProcessContext);
var
  Rendered: Boolean;
begin
  Rendered := False;
  try
    ProcessBlock(Ctx, Rendered);
  finally
    // after the engine has finished with the block: see EngineQuietLocked
    if Rendered then
      AtomicIncrement32(FBlocksRendered);
  end;
end;

procedure TMz950.ProcessBlock(const Ctx: TJuceProcessContext; var Rendered: Boolean);
var
  N, Ch, I, E, At, Wanted: Integer;
  Buf: PJuceSampleArray;
  Event: PJuceMidiEvent;
  T: PJuceTransport;
  Bpm, QuartersPerBar: Double;
begin
  N := Ctx.NumSamples;
  ReadValues(Ctx);

  for Ch := 0 to Ctx.NumChannels - 1 do
  begin
    Buf := Ctx.Channel(Ch);
    if Buf <> nil then
      for I := 0 to N - 1 do
        Buf^[I] := 0;
  end;

  if (FEngine = nil) or (N < 0) or (N > Length(FLeft)) then
    Exit;

  FEngine.Gain.Store(FValues[PGain]);
  // Before the messages, so a bend in this block is read against this block's range.
  FEngine.BendRange.Store(FValues[PBendRange]);

  // The three switches, from their parameters - the button, automation, a restored set -
  // posted at the top of the block and only when changed, ahead of this block's notes.
  if FValues[PGlide] >= 0.5 then Wanted := 1 else Wanted := 0;
  if Wanted <> FGlidePosted then
  begin
    FEngine.Glide(Wanted <> 0, 0);
    FGlidePosted := Wanted;
  end;
  Wanted := Round(FValues[PVoices]);
  if Wanted <> FVoicesPosted then
  begin
    FEngine.SetVoiceLimit(Wanted, 0);
    FVoicesPosted := Wanted;
  end;
  if FValues[PWide] >= 0.5 then Wanted := 1 else Wanted := 0;
  if Wanted <> FWidePosted then
  begin
    FEngine.Wide(Wanted <> 0, 0);
    FWidePosted := Wanted;
  end;

  // Every message, where in the block it happens.
  for E := 0 to Ctx.NumMidiEvents - 1 do
  begin
    Event := Ctx.MidiEvent(E);
    if Event = nil then
      Continue;
    At := Event^.SamplePosition;
    if At > N - 1 then At := N - 1;
    if At < 0 then At := 0;
    Handle(Event^, At);
  end;

  // The trims after the messages, so a CC in this block is heard in it. A block is the
  // resolution for a knob; notes get their sample.
  StoreTrims;
  FEngine.GlideSeconds.Store(FValues[PGlideTime] / 1000.0);
  FEngine.WideCents.Store(FValues[PWideDetune]);
  FEngine.WideSpread.Store(FValues[PWideSpread] / 100.0);
  FEngine.WideOffset.Store(FValues[PWideOffset] >= 0.5);

  // The host's tempo and position, for the LFO's tempo sync. No position from the host
  // leaves the engine at 120 and running free.
  T := Ctx.Transport;
  if (T <> nil) and (T^.HasInfo <> 0) then
  begin
    Bpm := T^.Bpm;
    if not (Bpm > 0) then
      Bpm := 120.0;
    if T^.TimeSigDenominator > 0 then
      QuartersPerBar := T^.TimeSigNumerator * 4.0 / T^.TimeSigDenominator
    else
      QuartersPerBar := 4.0;
    FEngine.SetTransport(Bpm, T^.PpqPosition, T^.IsPlaying <> 0, QuartersPerBar);
  end;

  if N = 0 then
    Exit;     // the messages wait in the engine for the next block

  // Two channels, because a keygroup can be sent to LEFT or RIGHT. A third channel and on
  // get the left; a mono host gets the left, as from the machine's left socket.
  Rendered := True;
  FEngine.Render(@FLeft[0], @FRight[0], N);
  for Ch := 0 to Ctx.NumOutputChannels - 1 do
  begin
    Buf := Ctx.Channel(Ch);
    if Buf = nil then
      Continue;
    if Ch = 1 then
      for I := 0 to N - 1 do Buf^[I] := FRight[I]
    else
      for I := 0 to N - 1 do Buf^[I] := FLeft[I];
  end;
end;

function TMz950.TailSeconds: Double;
begin
  Result := FTail;
end;

function TMz950.ParameterToText(Index: Integer; Value: Single; out Text: string): Boolean;
begin
  Result := FormatValue(Index, Value, Text);
end;

{ ---- the state ---- }

//
// THE SAVED STATE: the whole disk, not a path to it (see the C++'s note: a path breaks the
// moment the library moves; the sound IS the disk), and everything else the C++ saves
// beside the parameters - which the framework saves itself, as the APVTS part of the C++'s.
//
//   'M' 'z' '9' '5'   magic
//   version           1 byte, StateVersion
//   sections, to the end of the data, each:
//     tag             4 ASCII bytes
//     length          UInt32, little-endian: the payload's
//     payload
//   'DISK'  the plain sector image, gzipped (at most MaxPacked bytes; unpacks to at most
//           GzipDefaultMaxOutput)
//   'NAME'  the disk's name, UTF-8        'PATH'  where it was read from, UTF-8
//   'PROG'  the selected programme: Int32 index (-1..63), then its name, UTF-8
//   'SYNT'  1 byte: the disk is the Synth tab's rendering (0/1); then the recipe as text
//   'CCMP'  the CC map, by parameter id: entries (1 byte), then each: id length (1..64),
//           id (ASCII), CC (1 byte; 255 = none)
//   'ETAB'  1 byte: the editor's tab (0..2)
// Every section at most once; one this build does not know is skipped. A state is checked
// whole before any of it is used: a bad length, an unknown version, a section twice, text
// that is not UTF-8, a value out of range or a gzip that does not unpack exactly and
// within its cap, and nothing changes. A well-formed state whose disk the reader refuses
// keeps the disk there is (as the C++ does) and takes the rest.
//
const
  StateMagic: array[0..3] of Byte = (Ord('M'), Ord('z'), Ord('9'), Ord('5'));
  StateVersion = 1;
  StateHeader = 5;
  MaxSections = 32;
  MaxPacked = 4 * 1024 * 1024;
  MaxNameBytes = 4096;
  MaxProgNameBytes = 256;
  MaxRecipeBytes = 64 * 1024;
  MaxIdLength = 64;
  NoCcByte = 255;

type
  TParsedState = record
    HaveDisk: Boolean;
    Image: TBytes;
    DiskName, DiskPath: string;
    HaveProg: Boolean;
    ProgIndex: Integer;
    ProgName: string;
    HaveSynth: Boolean;
    SynthActive: Boolean;
    RecipeText: string;
    HaveMap: Boolean;
    MapCount: Integer;
    MapIndex, MapCc: array[0..255] of Integer;
    HaveTab: Boolean;
    Tab: Integer;
  end;

function Tag(const S: AnsiString): Cardinal;
begin
  Result := Cardinal(Ord(S[1])) or (Cardinal(Ord(S[2])) shl 8) or (Cardinal(Ord(S[3])) shl 16)
    or (Cardinal(Ord(S[4])) shl 24);
end;

function Utf8Bytes(const S: string): TBytes;
var
  U: UTF8String;
begin
  Result := nil;
  U := UTF8String(S);
  SetLength(Result, Length(U));
  if Length(U) > 0 then
    Move(U[1], Result[0], Length(U));
end;

// Strictly well-formed UTF-8, no NUL, no overlong forms or surrogates.
function ValidUtf8(const B: TBytes; At, Len: Integer): Boolean;
var
  P, Stop, Need, I: Integer;
  C, Cp, Min: Cardinal;
begin
  Result := False;
  P := At;
  Stop := At + Len;
  while P < Stop do
  begin
    C := B[P];
    if C = 0 then Exit;
    if C < $80 then
    begin
      Inc(P);
      Continue;
    end;
    if (C and $E0) = $C0 then begin Need := 1; Cp := C and $1F; Min := $80; end
    else if (C and $F0) = $E0 then begin Need := 2; Cp := C and $0F; Min := $800; end
    else if (C and $F8) = $F0 then begin Need := 3; Cp := C and $07; Min := $10000; end
    else Exit;
    if P + Need >= Stop then Exit;            // the sequence runs past the text
    for I := 1 to Need do
    begin
      if (B[P + I] and $C0) <> $80 then Exit;
      Cp := (Cp shl 6) or (B[P + I] and $3F);
    end;
    if (Cp < Min) or (Cp > $10FFFF) or ((Cp >= $D800) and (Cp <= $DFFF)) then Exit;
    Inc(P, Need + 1);
  end;
  Result := True;
end;

function TextOf(const B: TBytes; At, Len: Integer): string;
var
  U: UTF8String;
begin
  SetLength(U, Len);
  if Len > 0 then
    Move(B[At], U[1], Len);
  Result := string(U);
end;

procedure PutU32(var B: TBytes; var P: Integer; V: Cardinal);
begin
  B[P] := V and $FF;
  B[P + 1] := (V shr 8) and $FF;
  B[P + 2] := (V shr 16) and $FF;
  B[P + 3] := (V shr 24) and $FF;
  Inc(P, 4);
end;

function GetU32(const B: TBytes; P: Integer): Cardinal;
begin
  Result := Cardinal(B[P]) or (Cardinal(B[P + 1]) shl 8) or (Cardinal(B[P + 2]) shl 16)
    or (Cardinal(B[P + 3]) shl 24);
end;

procedure AddSection(var B: TBytes; var Used: Integer; const ATag: AnsiString; const Payload: TBytes);
var
  Need: Integer;
begin
  Need := Used + 8 + Length(Payload);
  if Need > Length(B) then
    SetLength(B, Need + Need div 2 + 64);
  B[Used] := Ord(ATag[1]);
  B[Used + 1] := Ord(ATag[2]);
  B[Used + 2] := Ord(ATag[3]);
  B[Used + 3] := Ord(ATag[4]);
  Inc(Used, 4);
  PutU32(B, Used, Length(Payload));
  if Length(Payload) > 0 then
    Move(Payload[0], B[Used], Length(Payload));
  Inc(Used, Length(Payload));
end;

function TMz950.SaveState: TBytes;
var
  HasDisk: Boolean;
  Image, Packed_, Payload, Text: TBytes;
  Name, Path, ProgName, RecipeText: string;
  Index, Serial, Revision, Used, I, J, P, Cc: Integer;
  Synth: Boolean;
  Id: AnsiString;
begin
  Result := nil;
  Image := nil;
  Packed_ := nil;
  Lock;
  try
    HasDisk := (FDisk <> nil) and (Length(FProgramNames) > 0);
    Serial := FDiskSerial;
    Revision := 0;
    if HasDisk then
    begin
      Revision := FDisk.Revision;
      Name := FDisk.Name;
      Path := FDiskPath;
      Index := FSelected;
      if (Index >= 0) and (Index < Length(FProgramNames)) then
        ProgName := FProgramNames[Index]
      else
        ProgName := '';
      // the last save's gzip, if the disk has not changed since
      if (FPackedSerial = Serial) and (FPackedRevision = Revision) and (FPackedImage <> nil) then
        Packed_ := FPackedImage
      else
        Image := Copy(FDisk.Image);
    end;
    RecipeText := ToText(FRecipe);
    Synth := FSynthDisk;
  finally
    Unlock;
  end;

  if HasDisk and (Packed_ = nil) then
  begin
    if not GzipCompress(Image, Packed_, 9) then
      Packed_ := nil;
    if Packed_ <> nil then
    begin
      Lock;
      try
        FPackedImage := Packed_;
        FPackedSerial := Serial;
        FPackedRevision := Revision;
      finally
        Unlock;
      end;
    end;
  end;

  SetLength(Result, 256 + Length(Packed_));
  for I := 0 to 3 do
    Result[I] := StateMagic[I];
  Result[4] := StateVersion;
  Used := StateHeader;

  if HasDisk and (Packed_ <> nil) then
  begin
    AddSection(Result, Used, 'DISK', Packed_);
    Text := Utf8Bytes(Name);
    if Length(Text) > MaxNameBytes then SetLength(Text, 0);
    AddSection(Result, Used, 'NAME', Text);
    Text := Utf8Bytes(Path);
    if Length(Text) > MaxNameBytes then SetLength(Text, 0);
    AddSection(Result, Used, 'PATH', Text);
    // Also by name: a disk edited since can have its programmes in another order, and
    // the name is what was meant.
    Text := Utf8Bytes(ProgName);
    if Length(Text) > MaxProgNameBytes then SetLength(Text, 0);
    SetLength(Payload, 4 + Length(Text));
    P := 0;
    PutU32(Payload, P, Cardinal(Index));
    if Length(Text) > 0 then
      Move(Text[0], Payload[4], Length(Text));
    AddSection(Result, Used, 'PROG', Payload);
  end;

  // The Synth tab's recipe, so its knobs come back as they were.
  Text := Utf8Bytes(RecipeText);
  if Length(Text) > MaxRecipeBytes then SetLength(Text, 0);
  SetLength(Payload, 1 + Length(Text));
  Payload[0] := Ord(Synth and HasDisk);
  if Length(Text) > 0 then
    Move(Text[0], Payload[1], Length(Text));
  AddSection(Result, Used, 'SYNT', Payload);

  // the CC map: every parameter, id and CC
  SetLength(Payload, 1);
  Payload[0] := NumParams;
  P := 1;
  for I := 0 to NumParams - 1 do
  begin
    Id := AnsiString(Specs[I].Id);
    SetLength(Payload, P + 2 + Length(Id));
    Payload[P] := Length(Id);
    for J := 1 to Length(Id) do
      Payload[P + J] := Ord(Id[J]);
    Inc(P, 1 + Length(Id));
    Cc := CcFor(I);
    if Cc < 0 then Payload[P] := NoCcByte else Payload[P] := Cc;
    Inc(P);
  end;
  AddSection(Result, Used, 'CCMP', Payload);

  SetLength(Payload, 1);
  Payload[0] := Clamp(EditorTab, 0, EditorTabCount - 1);
  AddSection(Result, Used, 'ETAB', Payload);

  SetLength(Result, Used);
end;

// The CC map payload: the entries with an id this build knows and a CC it would learn (or
// none). False if malformed or not ending exactly at Stop.
function ParseMap(const Data: TBytes; Start, Stop: Integer; var S: TParsedState): Boolean;
var
  P, Entries, E, Len, J, I, C: Integer;
  Id: string;
begin
  Result := False;
  S.MapCount := 0;
  P := Start;
  if (Stop > Length(Data)) or (P < 0) or (P + 1 > Stop) then
    Exit;
  Entries := Data[P];
  Inc(P);
  for E := 1 to Entries do
  begin
    if P >= Stop then
      Exit;
    Len := Data[P];
    if (Len < 1) or (Len > MaxIdLength) or (P + Len + 2 > Stop) then
      Exit;
    Id := '';
    for J := 1 to Len do
    begin
      if not (Data[P + J] in [Ord('A')..Ord('Z'), Ord('a')..Ord('z'), Ord('0')..Ord('9'), Ord('_'), Ord('-'), Ord('.')]) then
        Exit;
      Id := Id + Chr(Data[P + J]);
    end;
    C := Data[P + Len + 1];
    Inc(P, Len + 2);
    if C = NoCcByte then
      C := -1;
    I := IndexOfId(Id);
    // an id this build does not know, or a CC it would not learn: skipped
    if (I >= 0) and ((C = -1) or Learnable(C)) and (S.MapCount <= High(S.MapIndex)) then
    begin
      S.MapIndex[S.MapCount] := I;
      S.MapCc[S.MapCount] := C;
      Inc(S.MapCount);
    end;
  end;
  Result := P = Stop;
end;

// The whole state, checked. False if any of it is wrong; then S means nothing.
function ParseState(const Data: TBytes; out S: TParsedState): Boolean;
var
  P, Len, Sections, I: Integer;
  T: Cardinal;
  Seen: array[0..6] of Boolean;
  Which: Integer;
begin
  Result := False;
  S.HaveDisk := False;
  S.Image := nil;
  S.DiskName := '';
  S.DiskPath := '';
  S.HaveProg := False;
  S.ProgIndex := 0;
  S.ProgName := '';
  S.HaveSynth := False;
  S.SynthActive := False;
  S.RecipeText := '';
  S.HaveMap := False;
  S.MapCount := 0;
  S.HaveTab := False;
  S.Tab := 0;
  for I := 0 to High(Seen) do
    Seen[I] := False;

  if Length(Data) < StateHeader then
    Exit;
  for I := 0 to 3 do
    if Data[I] <> StateMagic[I] then
      Exit;
  if Data[4] <> StateVersion then
    Exit;                                     // a later version: keep what there is

  P := StateHeader;
  Sections := 0;
  while P < Length(Data) do
  begin
    Inc(Sections);
    if Sections > MaxSections then
      Exit;
    if Length(Data) - P < 8 then
      Exit;
    T := GetU32(Data, P);
    if GetU32(Data, P + 4) > Cardinal(Length(Data) - P - 8) then
      Exit;
    Len := Integer(GetU32(Data, P + 4));
    Inc(P, 8);

    if T = Tag('DISK') then Which := 0
    else if T = Tag('NAME') then Which := 1
    else if T = Tag('PATH') then Which := 2
    else if T = Tag('PROG') then Which := 3
    else if T = Tag('SYNT') then Which := 4
    else if T = Tag('CCMP') then Which := 5
    else if T = Tag('ETAB') then Which := 6
    else Which := -1;

    if Which >= 0 then
    begin
      if Seen[Which] then
        Exit;                                 // twice
      Seen[Which] := True;
    end;

    case Which of
      0:
        begin
          if Len > MaxPacked then Exit;
          if not GzipDecompress(Data, P, Len, GzipDefaultMaxOutput, S.Image) then Exit;
          if Length(S.Image) = 0 then Exit;
          S.HaveDisk := True;
        end;
      1:
        begin
          if (Len > MaxNameBytes) or not ValidUtf8(Data, P, Len) then Exit;
          S.DiskName := TextOf(Data, P, Len);
        end;
      2:
        begin
          if (Len > MaxNameBytes) or not ValidUtf8(Data, P, Len) then Exit;
          S.DiskPath := TextOf(Data, P, Len);
        end;
      3:
        begin
          if (Len < 4) or (Len - 4 > MaxProgNameBytes) then Exit;
          S.ProgIndex := Integer(GetU32(Data, P));
          if (S.ProgIndex < -1) or (S.ProgIndex >= ProgramSlots) then Exit;
          if not ValidUtf8(Data, P + 4, Len - 4) then Exit;
          S.ProgName := TextOf(Data, P + 4, Len - 4);
          S.HaveProg := True;
        end;
      4:
        begin
          if (Len < 1) or (Len - 1 > MaxRecipeBytes) or (Data[P] > 1) then Exit;
          if not ValidUtf8(Data, P + 1, Len - 1) then Exit;
          S.SynthActive := Data[P] = 1;
          S.RecipeText := TextOf(Data, P + 1, Len - 1);
          S.HaveSynth := True;
        end;
      5:
        begin
          if not ParseMap(Data, P, P + Len, S) then Exit;
          S.HaveMap := True;
        end;
      6:
        begin
          if (Len <> 1) or (Data[P] >= EditorTabCount) then Exit;
          S.Tab := Data[P];
          S.HaveTab := True;
        end;
    end;
    Inc(P, Len);
  end;
  // a disk's name and programme come with it, or not at all
  if (Seen[1] or Seen[2] or Seen[3]) and not S.HaveDisk then
    Exit;
  Result := P = Length(Data);
end;

procedure TMz950.LoadState(const Data: TBytes);
var
  S: TParsedState;
  Restored: TS950Disk;
  Why: string;
  Recipe: TRecipe;
  I, Index: Integer;
  Adopted: Boolean;
begin
  try
    // A project with no custom state: the default CC map, and nothing else to restore.
    if Length(Data) = 0 then
    begin
      AtomicStore(FLearning, -1);
      ResetCcs;
      Exit;
    end;

    if not ParseState(Data, S) then
      Exit;                              // damaged, or from a later version: keep what there is

    // The disk is read before the lock is taken: decoding is the slow part.
    Restored := nil;
    if S.HaveDisk then
    begin
      Restored := TS950Disk.Create;
      if not Restored.LoadBytes(S.DiskName, S.Image, Why) then
        FreeAndNil(Restored);
    end;

    if S.HaveSynth then
      Recipe := SanitisedRecipe(FromText(S.RecipeText))
    else
      Recipe := NewRecipe;

    // the CC map: the defaults, then whatever the project changed
    AtomicStore(FLearning, -1);
    ResetCcs;
    if S.HaveMap then
      for I := 0 to S.MapCount - 1 do
        AssignCc(S.MapIndex[I], S.MapCc[I]);
    if S.HaveTab then
      EditorTab := S.Tab;

    Lock;
    try
      FRecipe := Recipe;
      // Whatever a render was going to land, this is what was asked for last.
      FRenderWanted := False;
      FRenderDropped := FRenderThread <> nil;

      if not S.HaveDisk then
        DropDiskLocked
      else if Restored <> nil then
      begin
        Adopted := AdoptDiskLocked(Restored, Why);
        if not Adopted then
          FreeAndNil(Restored)
        else
        begin
          Restored := nil;
          FDiskPath := S.DiskPath;
          FSynthDisk := S.SynthActive;
          // Back to the programme that was playing: by name first, the index as the fallback.
          Index := -1;
          if S.HaveProg then
          begin
            for I := 0 to High(FProgramNames) do
              if FProgramNames[I] = S.ProgName then
              begin
                Index := I;
                Break;
              end;
            if Index < 0 then
              Index := S.ProgIndex;
          end;
          if Index >= 0 then
            SelectProgramLocked(Index, False);

          // A Synth-tab disk from before the tuning fix, or from before the oscillators were
          // mixed into one loop, is rendered again from its recipe.
          if FSynthDisk and (FDisk <> nil)
            and (HasOldTuning(FRecipe, FDisk) or HasSeparateOscillators(FRecipe, FDisk)) then
            SetRecipeLocked(FRecipe);
        end;
      end;
      // else: a disk this build cannot read - keep the one there is, as the C++ does
    finally
      Unlock;
    end;
    Restored.Free;
  except
    // never out of here: a bad state leaves what there was
  end;
end;

{ ---- registration ---- }

procedure RegisterMz950;
var
  I: Integer;
begin
  // In the order of Specs, so each parameter's index is its index there.
  for I := 0 to NumParams - 1 do
    with Specs[I] do
      case Kind of
        mkFloat:  JuceAddFloatParameter(Id, Name, Lo, Hi, Def);
        mkInt:    JuceAddIntParameter(Id, Name, Round(Lo), Round(Hi), Round(Def));
        mkBool:   JuceAddBoolParameter(Id, Name, Def >= 0.5);
        mkChoice: JuceAddChoiceParameter(Id, Name, ChoiceNames(I), Round(Def));
      end;
  JuceRegisterPlugin(TMz950, jkInstrument);
end;

end.
