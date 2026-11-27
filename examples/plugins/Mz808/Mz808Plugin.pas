// Mz808 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// The plug-in: the Object Pascal counterpart of Source/PluginProcessor.cpp, on the
// PascalJUCE framework rather than juce::AudioProcessor.
//
// The panel is Mz808Editor (a form designed in Lazarus, Mz808EditorForm.lfm). What differs
// from the C++ processor:
//
//   - The preset menu is the "Patch" parameter. Choosing a kit sets every control, the
//     way the C++ setCurrentProgram does, through SetParameter so the host sees it.
//   - What the panel shows of the engine (each sound's hit count, which lights its pad) is
//     published from Process with SetMeter; the panel never touches the engine.
//   - The panel's pads play through a lock-free queue (Strike, QueueKey), read at the top
//     of each block, as the C++ MidiKeyboardState's pads are.
//
// MIDI learn is the C++ one: each control answers to one CC or none, each CC drives one
// control at most, the first learnable CC to arrive while a control waits is taken by it
// and does nothing else, and the map is saved in the state (by parameter id). The panel
// and the audio thread share the map through atomics only.

unit Mz808Plugin;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  SysUtils, JucePlugin, JuceTypes, Tr808Settings, Tr808Engine, Mz808Params, Mz808Presets;

const
  // The parameter beyond the panel's controls (0..NumSpecs - 1).
  PPatch = NumSpecs;
  NumParams = NumSpecs + 1;

  // What Process publishes for the panel (TJucePlugin.SetMeter slots).
  MeterHits = 0;             // 16 slots, one per sound (Tr808Engine's Voice*): its hit
                             // count, modulo 2^24 so a Single holds it exactly
  NumHitMeters = VoiceCount;

  // Pads from the panel waiting for the audio thread.
  KeyQueueSize = 256;

  // The pads' velocities: plain, and accented (shift-click, or ACCENT lit) - the C++
  // strike's 100 and 127.
  PadVelocity = 100;
  PadAccentVelocity = 127;

type
  // A value this plug-in has set (from a CC, a patch or a loaded project) that the host
  // has not reported back yet: SetParameter reaches it a little later, from its message
  // thread. Until it does, the engine is given this value rather than the stale one.
  TPendingValue = record
    Active: Boolean;
    Value: Single;     // what was set
    From: Single;      // what the host had then; any change from it ends the wait
    Age: Integer;      // samples waited so far
  end;

  TMz808 = class(TJucePlugin)
  private
    FEngine: TEngine;
    FHostValues: array[0..NumParams - 1] of Single;   // as the host last reported them
    FValues: array[0..NumParams - 1] of Single;       // what the engine is given
    FPending: array[0..NumParams - 1] of TPendingValue;
    FPendingTimeout: Integer;

    FAppliedPatch: Integer;     // -1: take whatever the host has, without applying it
    FPatchCandidate: Integer;
    FPatchWait, FPatchDebounce: Integer;

    // Shared with the panel (message thread): atomics only.
    FCcOf: array[0..NumSpecs - 1] of Integer;   // the CC each control answers to, -1 none
    FLearning: Integer;                         // the control waiting for a CC, -1 none
    FMapVersion: Integer;                       // bumped on every change of the above
    FKeyQueue: array[0..KeyQueueSize - 1] of Integer;  // note + 256 * velocity
    FKeyHead, FKeyTail: Integer;                // written by QueueKey / by Process

    procedure AssignCc(Index, Cc: Integer);
    procedure ResetCcs;
    procedure TakePanelKeys;
    procedure PublishMeters;

    procedure ReadValues(const Ctx: TJuceProcessContext);
    procedure SetOwnParameter(Index: Integer; Value: Single);
    procedure CheckPatch(NumSamples: Integer);
    procedure ApplyPatch(Patch: Integer);
    procedure UpdateEngine;
    procedure Handle(const Event: TJuceMidiEvent);
  public
    constructor Create; override;
    destructor Destroy; override;
    procedure Prepare(ASampleRate: Double; AMaxBlockSize: Integer); override;
    procedure Process(const Ctx: TJuceProcessContext); override;
    function SaveState: TBytes; override;
    procedure LoadState(const Data: TBytes); override;
    function TailSeconds: Double; override;
    function ParameterToText(Index: Integer; Value: Single; out Text: string): Boolean; override;
    function CreateEditor: TJuceEditorBase; override;

    // MIDI CC assignments, by control (its index in Specs). Any thread.
    function CcFor(Index: Integer): Integer;
    procedure Learn(Index: Integer);              // -1 cancels
    function LearningIndex: Integer;
    procedure ForgetCc(Index: Integer);
    procedure RestoreDefaultCc(Index: Integer);
    procedure ResetAllCcs;
    function MidiMapVersion: Integer;             // changes whenever the map or learning does

    // The panel's pads: a pad is a note like any other (the C++ strike) - its voice's GM
    // note, at PadVelocity or, accented, PadAccentVelocity - played at the top of the next
    // block. False if the queue is full (the hit is dropped).
    function Strike(Voice: Integer; Accented: Boolean): Boolean;
    // Any note (Velocity 1..127; 0 is a note-off, which the 808 ignores).
    function QueueKey(Note, Velocity: Integer): Boolean;

    // For tests: the engine, read-only use.
    property Engine: TEngine read FEngine;
  end;

// Declares the parameters and registers TMz808. Call once, from the library's begin..end.
procedure RegisterMz808;

implementation

uses
  Math, Mz808Editor;

const
  // The custom state: the CC map. Everything else is a parameter, saved by the wrapper.
  //   'M' 'z' '8' 'S'   magic
  //   version           1 byte, StateVersion
  // the CC map (the C++ "midiMap" property), by parameter id, so that a control added or
  // removed later cannot shift anyone else's:
  //   'C' 'C'           magic
  //   entries           1 byte
  //   entries x         id length (1 byte, 1..64), id (ASCII), CC (1 byte; 255 = none)
  // A build refuses a later version, and keeps what it has.
  StateMagic: array[0..3] of Byte = (Ord('M'), Ord('z'), Ord('8'), Ord('S'));
  StateVersion = 1;
  StateHeader = 5;
  MapMagic: array[0..1] of Byte = (Ord('C'), Ord('C'));
  NoCcByte = 255;
  MaxIdLength = 64;

  // How long a newly chosen patch must stay chosen before it is applied: covers the moment
  // in which the wrapper has restored a project's parameters but not yet called LoadState,
  // which would otherwise look like the user choosing that project's patch.
  PatchDebounceSeconds = 0.05;

  // A hit count as a meter: below 2^24, which a Single holds exactly.
  HitMask = $FFFFFF;

// What the panel and the audio thread share are aligned 32-bit values, read and written
// with interlocked instructions: lock-free, no allocation.
function AtomicLoad(var Target: Integer): Integer; inline;
begin
  {$IFDEF FPC}
  Result := InterlockedCompareExchange(Target, 0, 0);
  {$ELSE}
  Result := AtomicCmpExchange(Target, 0, 0);
  {$ENDIF}
end;

procedure AtomicStore(var Target: Integer; Value: Integer); inline;
begin
  {$IFDEF FPC}
  InterlockedExchange(Target, Value);
  {$ELSE}
  AtomicExchange(Target, Value);
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

procedure AtomicInc(var Target: Integer); inline;
begin
  {$IFDEF FPC}
  InterlockedIncrement(Target);
  {$ELSE}
  AtomicIncrement(Target);
  {$ENDIF}
end;

{ TMz808 }

constructor TMz808.Create;
begin
  inherited Create;
  FEngine := TEngine.Create;
  FAppliedPatch := -1;
  FPatchCandidate := -1;
  FPendingTimeout := 48000;
  FPatchDebounce := 2400;
  FLearning := -1;
  ResetCcs;
end;

destructor TMz808.Destroy;
begin
  FEngine.Free;
  inherited Destroy;
end;

function TMz808.CreateEditor: TJuceEditorBase;
begin
  Result := TMz808Editor.Create(Self);
end;

{ ---- MIDI learn ---- }

procedure TMz808.ResetCcs;
var
  I: Integer;
begin
  for I := 0 to NumSpecs - 1 do
    AtomicStore(FCcOf[I], Specs[I].Cc);
  AtomicInc(FMapVersion);
end;

procedure TMz808.AssignCc(Index, Cc: Integer);
var
  I: Integer;
begin
  if (Index < 0) or (Index >= NumSpecs) or ((Cc <> -1) and not Learnable(Cc)) then
    Exit;
  // whoever had this CC gives it up
  if Cc >= 0 then
    for I := 0 to NumSpecs - 1 do
      if (I <> Index) and (AtomicLoad(FCcOf[I]) = Cc) then
        AtomicStore(FCcOf[I], -1);
  AtomicStore(FCcOf[Index], Cc);
  AtomicInc(FMapVersion);
end;

function TMz808.CcFor(Index: Integer): Integer;
begin
  if (Index >= 0) and (Index < NumSpecs) then
    Result := AtomicLoad(FCcOf[Index])
  else
    Result := -1;
end;

procedure TMz808.Learn(Index: Integer);
begin
  if (Index < 0) or (Index >= NumSpecs) then
    Index := -1;
  AtomicStore(FLearning, Index);
  AtomicInc(FMapVersion);
end;

function TMz808.LearningIndex: Integer;
begin
  Result := AtomicLoad(FLearning);
end;

procedure TMz808.ForgetCc(Index: Integer);
begin
  AssignCc(Index, -1);
end;

procedure TMz808.RestoreDefaultCc(Index: Integer);
begin
  if (Index >= 0) and (Index < NumSpecs) then
    AssignCc(Index, Specs[Index].Cc);
end;

procedure TMz808.ResetAllCcs;
begin
  ResetCcs;
end;

function TMz808.MidiMapVersion: Integer;
begin
  Result := AtomicLoad(FMapVersion);
end;

{ ---- the panel's pads ---- }

function TMz808.Strike(Voice: Integer; Accented: Boolean): Boolean;
begin
  Result := False;
  if (Voice < 0) or (Voice >= VoiceCount) then
    Exit;
  if Accented then
    Result := QueueKey(VoiceInfo(Voice).Note, PadAccentVelocity)
  else
    Result := QueueKey(VoiceInfo(Voice).Note, PadVelocity);
end;

// One producer (the message thread) and one consumer (Process): the producer owns
// FKeyHead and the consumer FKeyTail; a slot is written before the head that publishes it.
function TMz808.QueueKey(Note, Velocity: Integer): Boolean;
var
  Head, Next: Integer;
begin
  Result := False;
  if (Note < 0) or (Note > 127) then
    Exit;
  Velocity := EnsureRange(Velocity, 0, 127);
  Head := AtomicLoad(FKeyHead);
  Next := (Head + 1) mod KeyQueueSize;
  if Next = AtomicLoad(FKeyTail) then
    Exit;   // full
  AtomicStore(FKeyQueue[Head], Note + 256 * Velocity);
  AtomicStore(FKeyHead, Next);
  Result := True;
end;

// The panel's pads, at the top of the block (as the C++ MidiKeyboardState puts its pads
// at sample 0). There is nothing to release: a pad's note-off would be ignored.
procedure TMz808.TakePanelKeys;
var
  Tail, Head, K: Integer;
begin
  Tail := AtomicLoad(FKeyTail);
  Head := AtomicLoad(FKeyHead);
  while Tail <> Head do
  begin
    K := AtomicLoad(FKeyQueue[Tail]);
    FEngine.NoteOn(K and 255, K shr 8);
    Tail := (Tail + 1) mod KeyQueueSize;
  end;
  AtomicStore(FKeyTail, Tail);
end;

procedure TMz808.PublishMeters;
var
  V: Integer;
begin
  for V := 0 to NumHitMeters - 1 do
    SetMeter(MeterHits + V, FEngine.HitCount(V) and HitMask);
end;

{ ---- parameters ---- }

procedure TMz808.Prepare(ASampleRate: Double; AMaxBlockSize: Integer);
var
  I: Integer;
begin
  FPendingTimeout := Max(1, Round(ASampleRate));   // a second: the host has had time
  FPatchDebounce := Max(1, Round(ASampleRate * PatchDebounceSeconds));
  // The patch the controls are already set to: a patch chosen from now on is applied, even
  // before the first block. (A project loaded later says its own, in LoadState.)
  if FAppliedPatch < 0 then
    FAppliedPatch := Round(GetParameter(PPatch));

  FEngine.Prepare(ASampleRate);
  // the pads waiting are dropped, as the C++ padState.reset()
  AtomicStore(FKeyTail, AtomicLoad(FKeyHead));

  for I := 0 to NumParams - 1 do
  begin
    FHostValues[I] := GetParameter(I);
    if FPending[I].Active then
      FValues[I] := FPending[I].Value
    else
      FValues[I] := FHostValues[I];
  end;
  UpdateEngine;
  PublishMeters;
end;

procedure TMz808.UpdateEngine;
begin
  FEngine.SetSettings(SettingsFromValues(FValues));
end;

procedure TMz808.ReadValues(const Ctx: TJuceProcessContext);
var
  I: Integer;
  P: Single;
begin
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

// Change a parameter from inside the plug-in: at once for the engine, and for the host via
// SetParameter (which the wrapper delivers from the message thread, in a gesture).
procedure TMz808.SetOwnParameter(Index: Integer; Value: Single);
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

procedure TMz808.CheckPatch(NumSamples: Integer);
var
  P: Integer;
begin
  P := Round(FHostValues[PPatch]);

  if FAppliedPatch < 0 then
  begin
    FAppliedPatch := P;   // a fresh instance or project: the controls are already as saved
    FPatchCandidate := -1;
  end
  else if P = FAppliedPatch then
    FPatchCandidate := -1
  else
  begin
    if P <> FPatchCandidate then
    begin
      FPatchCandidate := P;
      FPatchWait := NumSamples;
    end
    else
      Inc(FPatchWait, NumSamples);

    if FPatchWait >= FPatchDebounce then
      ApplyPatch(P);
  end;
end;

// Every control to its default, then the kit's own values on top (presets::apply).
procedure TMz808.ApplyPatch(Patch: Integer);
var
  Values: array[0..NumSpecs - 1] of Single;
  I: Integer;
begin
  FAppliedPatch := Patch;
  FPatchCandidate := -1;
  if (Patch < 0) or (Patch >= NumPresets) then
    Exit;

  PresetValuesOf(Patch, Values);
  for I := 0 to NumSpecs - 1 do
    SetOwnParameter(I, Values[I]);
end;

{ ---- audio ---- }

procedure TMz808.Process(const Ctx: TJuceProcessContext);
var
  N, Ch, E, At, Pos, I: Integer;
  Buf, Other: PJuceSampleArray;
  Event: PJuceMidiEvent;
begin
  N := Ctx.NumSamples;

  ReadValues(Ctx);
  CheckPatch(N);
  UpdateEngine;
  TakePanelKeys;

  for Ch := 0 to Ctx.NumChannels - 1 do
  begin
    Buf := Ctx.Channel(Ch);
    if Buf <> nil then
      for I := 0 to N - 1 do
        Buf^[I] := 0;
  end;

  Buf := Ctx.Channel(0);
  if (Buf = nil) or (Ctx.NumOutputChannels = 0) then
  begin
    PublishMeters;
    Exit;
  end;

  // The 808 is a mono machine: render one channel, and split the block at each MIDI
  // event so a hit lands on its sample rather than at the top of the block.
  Pos := 0;
  for E := 0 to Ctx.NumMidiEvents - 1 do
  begin
    Event := Ctx.MidiEvent(E);
    if Event = nil then
      Continue;
    At := EnsureRange(Event^.SamplePosition, 0, N);
    if At > Pos then
    begin
      FEngine.Render(@Buf^[Pos], At - Pos);
      Pos := At;
    end;
    Handle(Event^);
  end;

  if Pos < N then
    FEngine.Render(@Buf^[Pos], N - Pos);

  for Ch := 1 to Ctx.NumOutputChannels - 1 do
  begin
    Other := Ctx.Channel(Ch);
    if Other <> nil then
      for I := 0 to N - 1 do
        Other^[I] := Buf^[I];
  end;
  PublishMeters;
end;

procedure TMz808.Handle(const Event: TJuceMidiEvent);
var
  Status, Data1, Data2, I, Waiting: Integer;
begin
  if (Event.Data = nil) or (Event.Size < 1) then
    Exit;
  Status := Event.Data[0] and $F0;
  if Event.Size >= 2 then Data1 := Event.Data[1] and $7F else Data1 := 0;
  if Event.Size >= 3 then Data2 := Event.Data[2] and $7F else Data2 := 0;

  // Every channel plays: a drum part from the host is often on 10, a pad controller
  // on whatever it likes. Note-offs are ignored: every sound runs out on its own.
  if (Status = $90) and (Event.Size >= 3) and (Data2 <> 0) then
    FEngine.NoteOn(Data1, Data2)
  else if (Status = $B0) and (Event.Size >= 3) then
  begin
    if Data1 = 120 then                             // all sound off
      FEngine.AllSoundOff
    else
    begin
      // MIDI learn: the first learnable CC to arrive is taken, and does nothing else.
      Waiting := AtomicLoad(FLearning);
      if (Waiting >= 0) and Learnable(Data1) and AtomicCas(FLearning, -1, Waiting) then
      begin
        AssignCc(Waiting, Data1);
        Exit;
      end;
      // A mapped CC moves the parameter itself - so the panel follows, the host can record
      // it, and the project saves it - and takes effect from this sample, not the next
      // block. 0-127 spans the knob's whole travel.
      for I := 0 to NumSpecs - 1 do
        if AtomicLoad(FCcOf[I]) = Data1 then
        begin
          SetOwnParameter(I, CcToValue(I, Data2));
          UpdateEngine;
          Break;
        end;
    end;
  end;
end;

{ ---- state ---- }

function TMz808.SaveState: TBytes;
var
  I, J, P, Size, Cc: Integer;
  Id: AnsiString;
begin
  Result := nil;
  Size := StateHeader + 3;
  for I := 0 to NumSpecs - 1 do
    Inc(Size, 2 + Length(Specs[I].Id));
  SetLength(Result, Size);
  for I := 0 to 3 do
    Result[I] := StateMagic[I];
  Result[4] := StateVersion;
  // the CC map: every control, id and CC
  P := StateHeader;
  Result[P] := MapMagic[0];
  Result[P + 1] := MapMagic[1];
  Result[P + 2] := NumSpecs;
  Inc(P, 3);
  for I := 0 to NumSpecs - 1 do
  begin
    Id := AnsiString(Specs[I].Id);
    Result[P] := Length(Id);
    for J := 1 to Length(Id) do
      Result[P + J] := Ord(Id[J]);
    Inc(P, 1 + Length(Id));
    Cc := CcFor(I);
    if Cc < 0 then
      Result[P] := NoCcByte
    else
      Result[P] := Cc;
    Inc(P);
  end;
end;

// The CC map, from Data[Start] to Data[Stop - 1]: the entries with an id this build knows
// and a CC it would learn (or none), Count of them in Index / Cc. False if the map is
// malformed or does not end exactly at Stop (bounds-checked throughout).
function ParseMap(const Data: TBytes; Start, Stop: Integer; var Index, Cc: array of Integer;
  out Count: Integer): Boolean;
var
  P, Entries, E, Len, J, I, C: Integer;
  Id: string;
begin
  Result := False;
  Count := 0;
  P := Start;
  if (Stop > Length(Data)) or (P < 0) or (P + 3 > Stop) or (Data[P] <> MapMagic[0]) or (Data[P + 1] <> MapMagic[1]) then
    Exit;
  Entries := Data[P + 2];
  Inc(P, 3);
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
    if (I >= 0) and ((C = -1) or Learnable(C)) and (Count <= High(Index)) then
    begin
      Index[Count] := I;
      Cc[Count] := C;
      Inc(Count);
    end;
  end;
  Result := P = Stop;
end;

procedure TMz808.LoadState(const Data: TBytes);
var
  MapIndex, MapCc: array[0..255] of Integer;
  I, MapCount: Integer;
  Valid: Boolean;
begin
  // The CC map. Never trust the data: it comes from a project file. Known magic and
  // version, then a well-formed map to the end. All or nothing: damaged data changes
  // nothing.
  MapCount := 0;
  if Length(Data) = 0 then
  begin
    AtomicStore(FLearning, -1);
    ResetCcs;                               // a project with no CC map: the defaults
  end
  else
  begin
    Valid := Length(Data) >= StateHeader;
    for I := 0 to 3 do
      if Valid and (Data[I] <> StateMagic[I]) then
        Valid := False;
    Valid := Valid and (Data[4] = StateVersion);
    if Valid then
      Valid := ParseMap(Data, StateHeader, Length(Data), MapIndex, MapCc, MapCount);
    if Valid then
    begin
      // CC assignments: the defaults, then whatever the project changed.
      AtomicStore(FLearning, -1);
      ResetCcs;
      for I := 0 to MapCount - 1 do
        AssignCc(MapIndex[I], MapCc[I]);
    end;
    // else: damaged or from a later version - keep the map there is
  end;

  // The controls were restored just before this: they are the project's, not a patch
  // waiting to be applied.
  FAppliedPatch := Round(GetParameter(PPatch));
  FPatchCandidate := -1;
end;

function TMz808.TailSeconds: Double;
begin
  Result := 4.0;
end;

function TMz808.ParameterToText(Index: Integer; Value: Single; out Text: string): Boolean;
begin
  // Knobs as the C++ shows them; the patch by name.
  Result := (Index >= 0) and (Index < NumSpecs);
  if Result then
    Text := FormatKnobValue(Index, Value)
  else
    Text := '';
end;

procedure RegisterMz808;
var
  I: Integer;
begin
  // In the order of Specs, so each control's parameter index is its index there.
  for I := 0 to NumSpecs - 1 do
    JuceAddFloatParameter(Specs[I].Id, Specs[I].Name, KnobMin, KnobMax, DefaultValue(I));

  // The editor's preset menu.
  JuceAddChoiceParameter('patch', 'Patch', PresetNames, 0);

  JuceRegisterPlugin(TMz808, jkInstrument);
end;

end.
