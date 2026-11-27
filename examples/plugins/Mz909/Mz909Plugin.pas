// Mz909 - an emulation of the TR-909 Rhythm Composer
// Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// The plug-in: the Object Pascal counterpart of Source/PluginProcessor.cpp, on the
// PascalJUCE framework rather than juce::AudioProcessor.
//
// The panel is Mz909Editor (a form designed in Lazarus, Mz909EditorForm.lfm). What differs
// from the C++ processor:
//
//   - The preset menu is the "Patch" parameter. Choosing a kit sets every knob, the way
//     the C++ setCurrentProgram does, through SetParameter so the host sees it.
//   - What the panel shows of the engine (each sound's hit count, for the pads' lights) is
//     published from Process with SetMeter; the panel never touches the engine.
//   - The pads play through a lock-free queue (QueueKey, Strike), read in each block just
//     after the host's MIDI at its first sample - where the C++ MidiKeyboardState puts
//     them.
//
// MIDI learn is the C++ one: each control answers to one CC or none, each CC drives one
// control at most, the first learnable CC to arrive while a control waits is taken by it
// and does nothing else, and the map is saved in the state (by parameter id). The panel
// and the audio thread share the map through atomics only.
//
// Output: the 909 is a mono machine. The C++ plug-in has one stereo (or mono) output bus,
// renders one channel and copies it to the other; so does this one. There are no
// individual outputs, no sequencer and no host sync in the C++ either: it is played from
// MIDI, on the General MIDI drum map.

unit Mz909Plugin;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  SysUtils, JucePlugin, JuceTypes, Tr909Settings, Tr909Engine, Mz909Params, Mz909Presets;

const
  // The parameter beyond the panel's knobs (0..NumSpecs - 1).
  PPatch = NumSpecs;
  NumParams = NumSpecs + 1;

  // What Process publishes for the panel (TJucePlugin.SetMeter slots): each sound's hit
  // count (VoiceBD .. VoiceRC), modulo 2^24 so a Single holds it exactly. A pad lights when
  // its count changes, as the C++ panel's lights follow Engine::hitCount.
  MeterHits = 0;
  HitCountMask = $FFFFFF;

  // Pad strikes waiting for the audio thread.
  KeyQueueSize = 256;

  // The pads' velocities: plain, and accented (the C++ strike's 100 and 127).
  PadVelocity = 100;
  PadAccentVelocity = 127;

type
  // A value this plug-in has set (from a CC, a kit or a loaded project) that the host
  // has not reported back yet: SetParameter reaches it a little later, from its message
  // thread. Until it does, the engine is given this value rather than the stale one.
  TPendingValue = record
    Active: Boolean;
    Value: Single;     // what was set
    From: Single;      // what the host had then; any change from it ends the wait
    Age: Integer;      // samples waited so far
  end;

  TMz909 = class(TJucePlugin)
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

    // A pad: its sound's note at the pad velocity, accented or not (the C++ strike), played
    // in the next block. False if the queue is full (the hit is dropped).
    function Strike(Voice: Integer; Accented: Boolean): Boolean;
    // Any note (Velocity 1..127), the same way. Note-offs are not needed: a 909 ignores them.
    function QueueKey(Note, Velocity: Integer): Boolean;

    // For tests: the engine, read-only use.
    property Engine: TEngine read FEngine;
  end;

// Declares the parameters and registers TMz909. Call once, from the library's begin..end.
procedure RegisterMz909;

implementation

uses
  Math, Mz909Editor;

const
  // The custom state: the CC map. Everything else is a parameter, saved by the wrapper.
  //   'M' 'z' '9' 'S'   magic
  //   version           1 byte, StateVersion
  // the CC map (the C++ "midiMap" property), by parameter id, so that a control added or
  // removed later cannot shift anyone else's:
  //   'C' 'C'           magic
  //   entries           1 byte
  //   entries x         id length (1 byte, 1..64), id (ASCII), CC (1 byte; 255 = none)
  // A build refuses a later version, and keeps what it has.
  StateMagic: array[0..3] of Byte = (Ord('M'), Ord('z'), Ord('9'), Ord('S'));
  StateVersion = 1;
  StateHeader = 5;
  MapMagic: array[0..1] of Byte = (Ord('C'), Ord('C'));
  NoCcByte = 255;
  MaxIdLength = 64;

  // How long a newly chosen kit must stay chosen before it is applied: covers the moment
  // in which the wrapper has restored a project's parameters but not yet called LoadState,
  // which would otherwise look like the user choosing that project's kit.
  PatchDebounceSeconds = 0.05;

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

{ TMz909 }

constructor TMz909.Create;
begin
  inherited Create;
  FEngine := TEngine.Create;   // builds the ROMs (once per process), off the audio thread
  FAppliedPatch := -1;
  FPatchCandidate := -1;
  FPendingTimeout := 48000;
  FPatchDebounce := 2400;
  FLearning := -1;
  ResetCcs;
end;

destructor TMz909.Destroy;
begin
  FEngine.Free;
  inherited Destroy;
end;

function TMz909.CreateEditor: TJuceEditorBase;
begin
  Result := TMz909Editor.Create(Self);
end;

{ ---- MIDI learn ---- }

procedure TMz909.ResetCcs;
var
  I: Integer;
begin
  for I := 0 to NumSpecs - 1 do
    AtomicStore(FCcOf[I], Specs[I].Cc);
  AtomicInc(FMapVersion);
end;

procedure TMz909.AssignCc(Index, Cc: Integer);
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

function TMz909.CcFor(Index: Integer): Integer;
begin
  if (Index >= 0) and (Index < NumSpecs) then
    Result := AtomicLoad(FCcOf[Index])
  else
    Result := -1;
end;

procedure TMz909.Learn(Index: Integer);
begin
  if (Index < 0) or (Index >= NumSpecs) then
    Index := -1;
  AtomicStore(FLearning, Index);
  AtomicInc(FMapVersion);
end;

function TMz909.LearningIndex: Integer;
begin
  Result := AtomicLoad(FLearning);
end;

procedure TMz909.ForgetCc(Index: Integer);
begin
  AssignCc(Index, -1);
end;

procedure TMz909.RestoreDefaultCc(Index: Integer);
begin
  if (Index >= 0) and (Index < NumSpecs) then
    AssignCc(Index, Specs[Index].Cc);
end;

procedure TMz909.ResetAllCcs;
begin
  ResetCcs;
end;

function TMz909.MidiMapVersion: Integer;
begin
  Result := AtomicLoad(FMapVersion);
end;

{ ---- the pads ---- }

// One producer (the message thread) and one consumer (Process): the producer owns
// FKeyHead and the consumer FKeyTail; a slot is written before the head that publishes it.
function TMz909.QueueKey(Note, Velocity: Integer): Boolean;
var
  Head, Next: Integer;
begin
  Result := False;
  if (Note < 0) or (Note > 127) or (Velocity < 1) or (Velocity > 127) then
    Exit;
  Head := AtomicLoad(FKeyHead);
  Next := (Head + 1) mod KeyQueueSize;
  if Next = AtomicLoad(FKeyTail) then
    Exit;   // full
  AtomicStore(FKeyQueue[Head], Note + 256 * Velocity);
  AtomicStore(FKeyHead, Next);
  Result := True;
end;

function TMz909.Strike(Voice: Integer; Accented: Boolean): Boolean;
begin
  // a pad is a note like any other: the same path, the same sample-accurate timing
  Result := False;
  if (Voice < 0) or (Voice >= VoiceCount) then
    Exit;
  if Accented then
    Result := QueueKey(VoiceInfo(Voice).Note, PadAccentVelocity)
  else
    Result := QueueKey(VoiceInfo(Voice).Note, PadVelocity);
end;

// The pads' hits, at the block's first sample (as the C++ MidiKeyboardState puts them,
// after whatever the host sent for that sample).
procedure TMz909.TakePanelKeys;
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

procedure TMz909.PublishMeters;
var
  V: Integer;
begin
  for V := 0 to VoiceCount - 1 do
    SetMeter(MeterHits + V, FEngine.HitCount(V) and HitCountMask);
end;

{ ---- parameters ---- }

procedure TMz909.Prepare(ASampleRate: Double; AMaxBlockSize: Integer);
var
  I: Integer;
begin
  FPendingTimeout := Max(1, Round(ASampleRate));   // a second: the host has had time
  FPatchDebounce := Max(1, Round(ASampleRate * PatchDebounceSeconds));
  // The kit the knobs are already set to: a kit chosen from now on is applied, even before
  // the first block. (A project loaded later says its own, in LoadState.)
  if FAppliedPatch < 0 then
    FAppliedPatch := Round(GetParameter(PPatch));

  FEngine.Prepare(ASampleRate);

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

procedure TMz909.UpdateEngine;
begin
  FEngine.SetSettings(SettingsFromValues(FValues));
end;

procedure TMz909.ReadValues(const Ctx: TJuceProcessContext);
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
procedure TMz909.SetOwnParameter(Index: Integer; Value: Single);
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

procedure TMz909.CheckPatch(NumSamples: Integer);
var
  P: Integer;
begin
  P := Round(FHostValues[PPatch]);

  if FAppliedPatch < 0 then
  begin
    FAppliedPatch := P;   // a fresh instance or project: the knobs are already as saved
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

// Every knob to its default, then the kit's own values on top (presets::apply).
procedure TMz909.ApplyPatch(Patch: Integer);
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

procedure TMz909.Process(const Ctx: TJuceProcessContext);
var
  N, Ch, E, At, Pos, I: Integer;
  Buf, Other: PJuceSampleArray;
  Event: PJuceMidiEvent;
  PadsTaken: Boolean;
begin
  N := Ctx.NumSamples;

  ReadValues(Ctx);
  CheckPatch(N);
  UpdateEngine;

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
    // the C++ returns before playing anything; the pads' hits wait for a block that plays
    PublishMeters;
    Exit;
  end;

  // The 909 is a mono machine: render one channel, and split the block at each MIDI
  // event so a hit lands on its sample rather than at the top of the block.
  Pos := 0;
  PadsTaken := False;
  for E := 0 to Ctx.NumMidiEvents - 1 do
  begin
    Event := Ctx.MidiEvent(E);
    if Event = nil then
      Continue;
    At := EnsureRange(Event^.SamplePosition, 0, N);
    if (At > 0) and not PadsTaken then
    begin
      TakePanelKeys;
      PadsTaken := True;
    end;
    if At > Pos then
    begin
      FEngine.Render(@Buf^[Pos], At - Pos);
      Pos := At;
    end;
    Handle(Event^);
  end;
  if not PadsTaken then
    TakePanelKeys;

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

procedure TMz909.Handle(const Event: TJuceMidiEvent);
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
    if Data1 = 120 then                              // all sound off
    begin
      FEngine.AllSoundOff;
      Exit;
    end;

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

{ ---- state ---- }

function TMz909.SaveState: TBytes;
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

procedure TMz909.LoadState(const Data: TBytes);
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

  // The knobs were restored just before this: they are the project's, not a kit waiting
  // to be applied.
  FAppliedPatch := Round(GetParameter(PPatch));
  FPatchCandidate := -1;
end;

function TMz909.TailSeconds: Double;
begin
  Result := 4.0;
end;

function TMz909.ParameterToText(Index: Integer; Value: Single; out Text: string): Boolean;
begin
  // Knobs as the C++ shows them; the kit by name.
  Result := (Index >= 0) and (Index < NumSpecs);
  if Result then
    Text := FormatKnobValue(Index, Value)
  else
    Text := '';
end;

procedure RegisterMz909;
var
  I: Integer;
begin
  // In the order of Specs, so each control's parameter index is its index there.
  for I := 0 to NumSpecs - 1 do
    JuceAddFloatParameter(Specs[I].Id, Specs[I].Name, KnobMin, KnobMax, DefaultValue(I));

  // The editor's kit menu.
  JuceAddChoiceParameter('patch', 'Patch', PresetNames, 0);

  JuceRegisterPlugin(TMz909, jkInstrument);
end;

end.
