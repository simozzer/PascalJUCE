// Mz909 - an emulation of the TR-909 Rhythm Composer
// Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Checks of the plug-in layer (Mz909Plugin) and the panel (Mz909Editor), through the
// library's real entry point with a fake host: the parameter declarations, MIDI and the
// CC map, MIDI learn, the Patch parameter, the pads and their lights, the saved state
// (the CC map) - including hostile state - and the panel built from its form, driven with
// the mouse through a fake editor host.
// Audio is compared, sample for sample, with the engine driven directly as the C++
// PluginProcessor drives it.
//
// Build with run-time checks: fpc -Mdelphi -Cr -Co -Ct -CR -gl -gh (see build_verify.cmd).
// With range checks on the form is loaded in strict mode: an unknown property in it fails.
program PluginCheck;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  Classes, SysUtils, Math, JuceTypes, JucePlugin, JuceUI, JuceControls,
  Tr909Settings, Tr909Engine, Mz909Params, Mz909Presets, Mz909Plugin, Mz909Editor;
const
  Rate = 48000.0;
  BlockSize = 256;
  EditorToken = Pointer($5150);
  GraphicsToken = Pointer($6160);

type
  TFakeHost = record
    Params: array[0..NumParams - 1] of Single;     // what the host delivers to Process
    Requested: array[0..NumParams - 1] of Single;  // the latest SetParameter, not yet delivered
    Dirty: array[0..NumParams - 1] of Boolean;
    SetCalls: Integer;
    GestureDepth: Integer;
    Gestures: Integer;
    Meters: array[0..63] of Single;                // what Process publishes for the panel
  end;
  PFakeHost = ^TFakeHost;

  TEvent = record
    Pos: Integer;
    Bytes: array[0..2] of Byte;
    Size: Integer;
  end;

  // The editor's side of the wrapper.
  TFakeEditorHost = record
    BadHandles: Integer;
    SetSizes, LastW, LastH: Integer;
    MenusShown, LastMenuId, LastMenuCount: Integer;
    LastMenuText: string;
    Begins, Ends: Integer;
    DesignW, DesignH: Integer;
    MinScale, MaxScale: Single;
    Ops, Texts: Integer;
    UrlCalls: Integer;
    LastUrl: string;
    LookCalls: Integer;
    LastLook: TJcpEditorLook;
  end;

var
  Failures: Integer = 0;
  Host: TFakeHost;
  HostApi: TJcpHostApi;
  Factory: TJcpPluginFactory;
  VT: TJcpPluginVTable;
  Inst: Pointer;
  Transport: TJuceTransport;
  BufL, BufR: array[0..BlockSize - 1] of Single;
  Channels: array[0..1] of PJuceSampleArray;
  Events: array[0..63] of TEvent;
  NumEvents: Integer;
  MidiEvents: array[0..63] of TJuceMidiEvent;

  // the reference: the engine driven directly, as the C++ processBlock drives it
  Ref: TEngine;
  RefSettings: TSettings;
  RefOut: array[0..BlockSize - 1] of Single;
  RefPads: array[0..63] of Integer;   // pads struck: note + 256 * velocity, played at sample 0
  NumRefPads: Integer;
  StateBytes: TBytes;

  FE: TFakeEditorHost;
  FakeApi: TJcpEditorApi;
  EdVT: TJcpEditorVTable;
  Ed: Pointer;

procedure Check(Ok: Boolean; const What, Detail: string);
const
  Verdict: array[Boolean] of string = ('FAIL', 'ok  ');
begin
  Writeln(Format('  %s  %-58s %s', [Verdict[Ok], What, Detail]));
  if not Ok then
    Inc(Failures);
end;

{ ---- the fake host ---- }

procedure HSetParam(H: PJcpHost; Index: Int32; Value: Single); cdecl;
begin
  Inc(PFakeHost(H)^.SetCalls);
  if (Index >= 0) and (Index < NumParams) then
  begin
    PFakeHost(H)^.Requested[Index] := Value;
    PFakeHost(H)^.Dirty[Index] := True;
  end;
end;

function HGetParam(H: PJcpHost; Index: Int32): Single; cdecl;
begin
  if (Index >= 0) and (Index < NumParams) then
    Result := PFakeHost(H)^.Params[Index]
  else
    Result := 0;
end;

procedure HBegin(H: PJcpHost; Index: Int32); cdecl;
begin
  Inc(PFakeHost(H)^.GestureDepth);
  Inc(PFakeHost(H)^.Gestures);
end;

procedure HEnd(H: PJcpHost; Index: Int32); cdecl;
begin
  Dec(PFakeHost(H)^.GestureDepth);
end;

function HGetSampleRate(H: PJcpHost): Double; cdecl;
begin
  Result := Rate;
end;

procedure HLog(H: PJcpHost; Msg: PAnsiChar); cdecl;
begin
end;

procedure HSetMeter(H: PJcpHost; Index: Int32; Value: Single); cdecl;
begin
  if (Index >= 0) and (Index <= High(PFakeHost(H)^.Meters)) then
    PFakeHost(H)^.Meters[Index] := Value;
end;

// What the wrapper does on its message thread: the latest value of each parameter set.
procedure Deliver;
var
  I: Integer;
begin
  for I := 0 to NumParams - 1 do
    if Host.Dirty[I] then
    begin
      Host.Params[I] := Host.Requested[I];
      Host.Dirty[I] := False;
    end;
end;

procedure ResetHost;
var
  I: Integer;
begin
  FillChar(Host, SizeOf(Host), 0);
  for I := 0 to NumSpecs - 1 do
    Host.Params[I] := DefaultValue(I);
  FillChar(HostApi, SizeOf(HostApi), 0);
  HostApi.StructSize := SizeOf(HostApi);
  HostApi.AbiVersion := JCP_ABI_VERSION;
  HostApi.SetParameter := HSetParam;
  HostApi.GetParameter := HGetParam;
  HostApi.Log := HLog;
  HostApi.GetSampleRate := HGetSampleRate;
  HostApi.BeginParameterGesture := HBegin;
  HostApi.EndParameterGesture := HEnd;
  HostApi.SetMeter := HSetMeter;
  FillChar(Transport, SizeOf(Transport), 0);
  Transport.StructSize := SizeOf(Transport);
  Transport.Bpm := 120;
  Transport.TimeSigNumerator := 4;
  Transport.TimeSigDenominator := 4;
end;

function CreateInstance: Pointer;
begin
  FillChar(VT, SizeOf(VT), 0);
  VT.StructSize := SizeOf(VT);
  Result := Factory.Create(@HostApi, @Host, @VT);
  if Result <> nil then
    VT.Prepare(Result, Rate, BlockSize);
end;

function Plugin: TMz909;
begin
  Result := TMz909(Inst);
end;

{ ---- blocks, through the plug-in and through the reference ---- }

procedure Midi(Pos: Integer; B0, B1, B2: Byte);
begin
  Events[NumEvents].Pos := Pos;
  Events[NumEvents].Bytes[0] := B0;
  Events[NumEvents].Bytes[1] := B1;
  Events[NumEvents].Bytes[2] := B2;
  Events[NumEvents].Size := 3;
  Inc(NumEvents);
end;

procedure ProcessPlugin(N: Integer);
var
  Ctx: TJuceProcessContext;
  I: Integer;
begin
  for I := 0 to NumEvents - 1 do
  begin
    MidiEvents[I].Data := @Events[I].Bytes[0];
    MidiEvents[I].Size := Events[I].Size;
    MidiEvents[I].SamplePosition := Events[I].Pos;
  end;
  Channels[0] := @BufL;
  Channels[1] := @BufR;
  FillChar(Ctx, SizeOf(Ctx), 0);
  Ctx.StructSize := SizeOf(Ctx);
  Ctx.NumSamples := N;
  Ctx.Channels := @Channels;
  Ctx.MidiEvents := @MidiEvents;
  Ctx.Parameters := @Host.Params;
  Ctx.Transport := @Transport;
  Ctx.NumChannels := 2;
  Ctx.NumInputChannels := 0;
  Ctx.NumOutputChannels := 2;
  Ctx.NumMidiEvents := NumEvents;
  Ctx.NumParameters := NumParams;
  Ctx.MidiEventSize := SizeOf(TJuceMidiEvent);
  VT.Process(Inst, @Ctx);
end;

// The C++ Mz909Processor::handle.
procedure RefHandle(const E: TEvent);
var
  Status, D1, D2, I: Integer;
begin
  Status := E.Bytes[0] and $F0;
  D1 := E.Bytes[1];
  D2 := E.Bytes[2];
  if (Status = $90) and (D2 > 0) then
    Ref.NoteOn(D1, D2)
  else if (Status = $B0) and (D1 = 120) then
    Ref.AllSoundOff
  else if Status = $B0 then
    for I := 0 to NumSpecs - 1 do
      if Specs[I].Cc = D1 then
      begin
        SetSettingValue(RefSettings, I, CcToValue(I, D2));
        Ref.SetSettings(RefSettings);
        Break;
      end;
end;

procedure RefTakePads;
var
  I: Integer;
begin
  for I := 0 to NumRefPads - 1 do
    Ref.NoteOn(RefPads[I] and 255, RefPads[I] shr 8);
  NumRefPads := 0;
end;

// The C++ processBlock: the pads' notes join the MIDI at sample 0, after the host's.
procedure ProcessRef(N: Integer);
var
  I, Pos: Integer;
  Taken: Boolean;
begin
  Ref.SetSettings(RefSettings);
  Pos := 0;
  Taken := False;
  for I := 0 to NumEvents - 1 do
  begin
    if (Events[I].Pos > 0) and not Taken then
    begin
      RefTakePads;
      Taken := True;
    end;
    if Events[I].Pos > Pos then
    begin
      Ref.Render(@RefOut[Pos], Events[I].Pos - Pos);
      Pos := Events[I].Pos;
    end;
    RefHandle(Events[I]);
  end;
  if not Taken then
    RefTakePads;
  if Pos < N then
    Ref.Render(@RefOut[Pos], N - Pos);
end;

// One block through both; the largest difference between them, and between L and R.
function Both(N: Integer = BlockSize): Double;
var
  I: Integer;
begin
  ProcessPlugin(N);
  ProcessRef(N);
  NumEvents := 0;
  Result := 0;
  for I := 0 to N - 1 do
  begin
    Result := Max(Result, Abs(BufL[I] - RefOut[I]));
    Result := Max(Result, Abs(BufR[I] - BufL[I]));
  end;
end;

procedure RefPad(Note, Velocity: Integer);
begin
  RefPads[NumRefPads] := Note + 256 * Velocity;
  Inc(NumRefPads);
end;

procedure StartPair;
begin
  ResetHost;
  Inst := CreateInstance;
  Ref := TEngine.Create;
  Ref.Prepare(Rate);
  RefSettings := TSettings.Defaults;
  Ref.SetSettings(RefSettings);
  NumEvents := 0;
  NumRefPads := 0;
end;

procedure EndPair;
begin
  VT.Destroy(Inst);
  Inst := nil;
  Ref.Free;
  Ref := nil;
end;

function Hits(Voice: Integer): Integer;
begin
  Result := Round(Host.Meters[MeterHits + Voice]);
end;

{ ---- the checks ---- }

procedure DeclarationChecks;
var
  Info: TJcpParameterInfo;
  I, Bad: Integer;
begin
  Writeln;
  Writeln('parameters');

  Check(JuceDeclarationError = '', 'declarations are valid', JuceDeclarationError);
  Check(Factory.GetParameterCount = NumParams, 'parameter count: 28 knobs and the Patch', Format('%d', [Factory.GetParameterCount]));
  Bad := 0;
  for I := 0 to NumSpecs - 1 do
  begin
    FillChar(Info, SizeOf(Info), 0);
    Info.StructSize := SizeOf(Info);
    Factory.GetParameterInfo(I, @Info);
    if (string(Info.Id) <> Specs[I].Id) or (string(Info.Name) <> Specs[I].Name) or (Info.Kind <> Ord(jpkFloat))
      or (Info.DefaultValue <> DefaultValue(I)) or (Info.MinValue <> 0) or (Info.MaxValue <> 10) then
    begin
      Writeln('    mismatch at ', I, ': ', Info.Id);
      Inc(Bad);
    end;
  end;
  Check(Bad = 0, 'ids, names, ranges (0..10), defaults as Params.cpp', Format('%d mismatches', [Bad]));
  Check((DefaultValue(PBdLevel) = 8) and (DefaultValue(POhDecay) = 10) and (DefaultValue(PRsLevel) = 6)
    and (DefaultValue(PVolume) = 7), 'the C++ Settings defaults', '');
  Factory.GetParameterInfo(PPatch, @Info);
  Check((string(Info.Id) = 'patch') and (Info.MaxValue = NumPresets - 1), 'Patch: a choice of the 9 factory kits', string(Info.Id));
  Bad := 0;
  for I := 0 to NumSpecs - 1 do
    if not Learnable(Specs[I].Cc) then
      Inc(Bad);
  Check(Bad = 0, 'every default CC is learnable (the C++ jassert)', '');
end;

procedure TextChecks;
var
  Buf: array[0..63] of AnsiChar;
  R1, R2, R3: Integer;
  T1, T2: string;
begin
  Writeln;
  Writeln('display text');
  R1 := VT.GetParameterText(Inst, PBdTune, 6, @Buf[0], Length(Buf));
  T1 := string(PAnsiChar(@Buf[0]));
  R2 := VT.GetParameterText(Inst, PChDecay, 2.34, @Buf[0], Length(Buf));
  T2 := string(PAnsiChar(@Buf[0]));
  R3 := VT.GetParameterText(Inst, PPatch, 1, @Buf[0], Length(Buf));
  Check((R1 = 1) and (T1 = '6.0') and (R2 = 1) and (T2 = '2.3'), 'knobs show one decimal place', T1 + ', ' + T2);
  Check(R3 = 0, 'the Patch shows its kit''s name (host default)', '');
  Check(Abs(VT.GetTailSeconds(Inst) - 4) < 1e-9, 'tail: 4 s, as the C++', '');
end;

procedure AudioChecks;
var
  B: Integer;
  Worst: Double;
begin
  Writeln;
  Writeln('MIDI into audio, against the engine driven directly');

  StartPair;
  Worst := 0;
  Midi(10, $99, 36, 100);                       // the kick, on channel 10
  Midi(10, $99, 42, 101);                       // and an accented closed hat on the same sample
  Worst := Max(Worst, Both);
  for B := 1 to 60 do
  begin
    if B = 2 then Midi(77, $90, 38, 127);       // channel 1: every channel plays
    if B = 3 then Midi(5, $89, 38, 0);          // a note-off: ignored
    if B = 4 then Midi(128, $90, 46, 0);        // note-on velocity 0: a note-off, ignored
    if B = 5 then
    begin
      Midi(0, $9F, 46, 90);                     // the open hat ...
      Midi(200, $90, 44, 60);                   // ... choked by the pedal hat
    end;
    if B = 7 then
    begin
      Midi(3, $90, 49, 127); Midi(3, $90, 51, 30); Midi(9, $90, 39, 100); Midi(9, $90, 37, 110);
      Midi(17, $90, 41, 100); Midi(18, $90, 45, 100); Midi(19, $90, 48, 100); Midi(255, $90, 60, 100);
    end;
    if B = 9 then Midi(40, $B0, 123, 0);        // all notes off: nothing to do on a 909
    if B = 12 then Midi(100, $B0, 120, 0);      // all sound off
    if B = 14 then
    begin
      Midi(0, $90, 36, 127);
      Midi(256, $90, 38, 127);                  // at the very end of the block
    end;
    Worst := Max(Worst, Both);
  end;
  Check(Worst = 0, 'notes, accents, chokes, all sound off: bit-identical, L = R', Format('max diff %.3e', [Worst]));
  Check((Hits(VoiceBD) = 2) and (Hits(VoiceSD) = 2) and (Hits(VoiceCH) = 2) and (Hits(VoiceOH) = 1) and (Hits(VoiceRC) = 1)
    and (Hits(VoiceLT) = 1) and (Hits(VoiceMT) = 1) and (Hits(VoiceHT) = 1),
    'each sound''s hit count is published, for the pads'' lights',
    Format('BD %d SD %d CH %d OH %d', [Hits(VoiceBD), Hits(VoiceSD), Hits(VoiceCH), Hits(VoiceOH)]));
  Check(Plugin.ProcessErrors = 0, 'no exceptions in Process', '');
  EndPair;
end;

procedure CcChecks;
var
  B: Integer;
  Worst: Double;
  Expect: Single;
begin
  Writeln;
  Writeln('the CC map');

  StartPair;
  Worst := 0;
  Midi(0, $90, 36, 100);
  Worst := Max(Worst, Both);

  // CC 15 is BASS DRUM LEVEL: it moves the parameter, and the sound from this sample.
  Midi(100, $B0, 15, 30);
  Worst := Max(Worst, Both);
  Expect := CcToValue(PBdLevel, 30);
  Check(Host.Dirty[PBdLevel] and (Host.Requested[PBdLevel] = Expect), 'CC 15 sets BASS DRUM LEVEL through the host',
    Format('%.4f (%.4f)', [Host.Requested[PBdLevel], Expect]));

  // The host has not reported it back yet: the engine must keep the CC's value.
  for B := 0 to 5 do
    Worst := Max(Worst, Both);
  Deliver;
  for B := 0 to 5 do
    Worst := Max(Worst, Both);
  Check(Worst = 0, 'takes effect at its sample, and stays while the host catches up', Format('max diff %.3e', [Worst]));

  // the ends of the travel; VOLUME is GM's 7
  Midi(5, $B0, 7, 0);
  Midi(9, $B0, 110, 127);
  Midi(20, $90, 51, 100);
  Worst := Max(Worst, Both);
  Check((Host.Requested[PVolume] = 0) and (Host.Requested[PRdTune] = 10),
    'CC 7 at 0 is VOLUME 0; CC 110 at 127 is RIDE TUNE 10',
    Format('volume %.1f, ride tune %.1f', [Host.Requested[PVolume], Host.Requested[PRdTune]]));
  Check(Host.GestureDepth = 0, 'gestures balanced', Format('%d open', [Host.GestureDepth]));
  Check(Worst = 0, 'all bit-identical', Format('max diff %.3e', [Worst]));
  EndPair;
end;

procedure PatchChecks;
var
  B, Applied, Calls, I, Bad: Integer;
  Worst: Double;
  Values: array[0..NumSpecs - 1] of Single;
begin
  Writeln;
  Writeln('the Patch parameter');

  StartPair;
  Worst := 0;
  Midi(0, $90, 36, 100);
  Worst := Max(Worst, Both);

  // Choose 'Techno': applied once the choice has settled (50 ms), not before.
  Host.Params[PPatch] := 2;
  Applied := -1;
  PresetValuesOf(2, Values);
  for B := 1 to 30 do
  begin
    Calls := Host.SetCalls;
    if B mod 8 = 0 then
      Midi(10, $90, 36, 110);
    ProcessPlugin(BlockSize);
    if (Host.SetCalls > Calls) and (Applied < 0) then
    begin
      Applied := B;
      RefSettings := SettingsFromValues(Values);   // the plug-in used it from this block's start
    end;
    ProcessRef(BlockSize);
    NumEvents := 0;
    for I := 0 to BlockSize - 1 do
      Worst := Max(Worst, Abs(BufL[I] - RefOut[I]));
  end;
  Check((Applied > 0) and (Applied * BlockSize >= 0.05 * Rate) and (Applied * BlockSize < 0.05 * Rate + 2 * BlockSize),
    'applied after 50 ms', Format('in block %d (%.1f ms)', [Applied, Applied * BlockSize * 1000 / Rate]));
  Bad := 0;
  for I := 0 to NumSpecs - 1 do
    if (not Host.Dirty[I]) or (Host.Requested[I] <> Values[I]) then
      Inc(Bad);
  Check(Bad = 0, 'every knob set: defaults, then the kit', Format('%d wrong', [Bad]));
  Check((Values[PBdDecay] = 7.5) and (Values[PBdTune] = 3) and (Values[PAccent] = 7) and (Values[POhDecay] = 2.5)
    and (Values[PVolume] = 7), 'Techno as Presets.cpp', '');
  Check(Host.GestureDepth = 0, 'each change in a gesture', Format('%d gestures, %d open', [Host.Gestures, Host.GestureDepth]));
  Check(Worst = 0, 'sounds from the block it is applied, before the host reports back', Format('max diff %.3e', [Worst]));

  Deliver;
  for B := 0 to 9 do
    Worst := Max(Worst, Both);
  Check(Worst = 0, 'and after', Format('max diff %.3e', [Worst]));

  // The user turns a knob after the kit: the kit is not applied again.
  Calls := Host.SetCalls;
  Host.Params[PBdTune] := 9;
  RefSettings.BdTune := 9;
  Midi(0, $90, 36, 100);
  for B := 0 to 20 do
    Worst := Max(Worst, Both);
  Check((Host.SetCalls = Calls) and (Worst = 0), 'tweaking a knob afterwards keeps the tweak', '');

  // every kit's values are within the knobs' range, and no knob twice in a kit
  Bad := 0;
  for I := 0 to NumPresetValues - 1 do
  begin
    if (PresetValues[I].Value < 0) or (PresetValues[I].Value > 10) or (PresetValues[I].Preset < 1)
      or (PresetValues[I].Preset >= NumPresets) then
      Inc(Bad);
    for B := I + 1 to NumPresetValues - 1 do
      if (PresetValues[B].Preset = PresetValues[I].Preset) and (PresetValues[B].Param = PresetValues[I].Param) then
        Inc(Bad);
  end;
  Check(Bad = 0, 'the kit table is sane', Format('%d bad rows', [Bad]));
  EndPair;
end;

procedure StateWriter(Writer: Pointer; Data: Pointer; Size: Int32); cdecl;
var
  N: Integer;
begin
  N := Length(StateBytes);
  SetLength(StateBytes, N + Size);
  Move(Data^, StateBytes[N], Size);
end;

// The size of the CC map in a saved state: magic, count, and id length, id, CC per control.
function MapBytes: Integer;
var
  I: Integer;
begin
  Result := 3;
  for I := 0 to NumSpecs - 1 do
    Inc(Result, 2 + Length(Specs[I].Id));
end;

function MapIsSane(P: TMz909; out Why: string): Boolean;
var
  I, J, C: Integer;
begin
  Result := False;
  for I := 0 to NumSpecs - 1 do
  begin
    C := P.CcFor(I);
    if (C <> -1) and not Learnable(C) then
    begin
      Why := Format('%s has CC %d', [Specs[I].Id, C]);
      Exit;
    end;
    for J := I + 1 to NumSpecs - 1 do
      if (C >= 0) and (P.CcFor(J) = C) then
      begin
        Why := Format('CC %d drives %s and %s', [C, Specs[I].Id, Specs[J].Id]);
        Exit;
      end;
  end;
  Why := '';
  Result := True;
end;

function MapIsDefault(P: TMz909): Boolean;
var
  I: Integer;
begin
  Result := P.LearningIndex = -1;
  for I := 0 to NumSpecs - 1 do
    if P.CcFor(I) <> Specs[I].Cc then
      Result := False;
end;

procedure LearnChecks;
var
  Calls, Version: Integer;
  Worst: Double;
  Why: string;
begin
  Writeln;
  Writeln('MIDI learn');

  StartPair;
  Worst := Both;
  Check(MapIsDefault(Plugin) and MapIsSane(Plugin, Why), 'starts with the default CCs, nothing learning', Why);

  // BASS DRUM TUNE learns the mod wheel (learnable here, as in the C++ Mz909)
  Version := Plugin.MidiMapVersion;
  Plugin.Learn(PBdTune);
  Check((Plugin.LearningIndex = PBdTune) and (Plugin.MidiMapVersion <> Version), 'MIDI Learn: the knob waits', '');
  Calls := Host.SetCalls;
  Midi(40, $B0, 0, 5);           // bank select is not learnable
  Midi(42, $B0, 32, 5);
  Midi(43, $B0, 121, 5);         // nor a channel mode message
  Worst := Max(Worst, Both);
  Check((Plugin.LearningIndex = PBdTune) and (Host.SetCalls = Calls), 'CC 0, 32 and 121 are not learned; it keeps waiting', '');
  Midi(10, $B0, 1, 100);
  ProcessPlugin(BlockSize);
  NumEvents := 0;
  Check((Plugin.LearningIndex = -1) and (Plugin.CcFor(PBdTune) = 1), 'the first learnable CC (1, the mod wheel) is taken',
    Format('BASS DRUM TUNE: CC %d', [Plugin.CcFor(PBdTune)]));
  Check(Host.SetCalls = Calls, 'and does nothing else (no parameter moved)', Format('%d set', [Host.SetCalls - Calls]));

  // a CC already in use is taken from its owner: one control per CC
  Plugin.Learn(PBdDecay);
  Midi(10, $B0, 14, 100);        // ACCENT's
  ProcessPlugin(BlockSize);
  NumEvents := 0;
  Check((Plugin.CcFor(PBdDecay) = 14) and (Plugin.CcFor(PAccent) = -1) and MapIsSane(Plugin, Why),
    'ACCENT gives CC 14 up to BASS DRUM DECAY', Why);

  // now CC 1 moves BASS DRUM TUNE, CC 16 nothing
  Midi(10, $B0, 1, 30);
  Midi(20, $B0, 16, 127);
  ProcessPlugin(BlockSize);
  NumEvents := 0;
  Calls := 0;
  for Version := 0 to NumParams - 1 do
    if Host.Dirty[Version] then
      Inc(Calls);
  Check(Host.Dirty[PBdTune] and (Host.Requested[PBdTune] = CcToValue(PBdTune, 30)) and (Calls = 1),
    'the learned CC moves the knob; the old one does nothing', Format('%.4f', [Host.Requested[PBdTune]]));
  Deliver;

  // cancel
  Plugin.Learn(PSdTone);
  Plugin.Learn(-1);
  Midi(0, $B0, 21, 127);
  ProcessPlugin(BlockSize);
  NumEvents := 0;
  Check((Plugin.LearningIndex = -1) and (Plugin.CcFor(PSdTone) = 21) and Host.Dirty[PSdTone],
    'Cancel MIDI Learn: the CC goes where it went', '');
  Deliver;

  // all sound off is never learned: it silences, as the C++ checks it first
  Plugin.Learn(PRsLevel);
  Midi(0, $B0, 120, 0);
  ProcessPlugin(BlockSize);
  NumEvents := 0;
  Check(Plugin.LearningIndex = PRsLevel, 'CC 120 (all sound off) is not learned', '');
  Plugin.Learn(-1);

  // forget, restore default (taking the CC back from whoever learned it), reset all
  Plugin.ForgetCc(PVolume);
  Check(Plugin.CcFor(PVolume) = -1, 'Forget CC', '');
  Plugin.Learn(PHtTune);
  Midi(0, $B0, 7, 1);
  ProcessPlugin(BlockSize);
  NumEvents := 0;
  Check(Plugin.CcFor(PHtTune) = 7, 'HI TOM TUNE learns VOLUME''s CC 7', '');
  Plugin.RestoreDefaultCc(PVolume);
  Check((Plugin.CcFor(PVolume) = 7) and (Plugin.CcFor(PHtTune) = -1) and MapIsSane(Plugin, Why),
    'Restore default takes CC 7 back', Why);
  Plugin.Learn(PCrTune);
  Plugin.ResetAllCcs;
  Check(Plugin.LearningIndex = PCrTune, 'Reset all leaves learning alone', '');
  Plugin.Learn(-1);
  Check(MapIsDefault(Plugin), 'Reset all CCs to defaults', '');
  Check(Host.GestureDepth = 0, 'gestures balanced', '');
  Check(Plugin.ProcessErrors = 0, 'no exceptions in Process', '');
  EndPair;
end;

var
  Seed: UInt32;

function NextRandom: UInt32;
begin
  Seed := Seed xor UInt32(Seed shl 13);
  Seed := Seed xor (Seed shr 17);
  Seed := Seed xor UInt32(Seed shl 5);
  Result := Seed;
end;

procedure StateChecks;
var
  I, Exceptions, Bad, Run: Integer;
  Saved, Data: TBytes;
  Why: string;

  procedure Load(const D: TBytes);
  begin
    try
      Plugin.LoadState(D);
    except
      Inc(Exceptions);
    end;
  end;

  function Learned: Boolean;
  begin
    Result := (Plugin.CcFor(PBdTune) = 20) and (Plugin.CcFor(PSdTune) = -1) and (Plugin.CcFor(PVolume) = -1);
  end;

begin
  Writeln;
  Writeln('the saved state: the CC map');

  StartPair;
  Plugin.Learn(PBdTune);
  Midi(0, $B0, 20, 1);           // SNARE DRUM TUNE's
  ProcessPlugin(BlockSize);
  NumEvents := 0;
  Plugin.ForgetCc(PVolume);
  StateBytes := nil;
  VT.GetState(Inst, StateWriter, nil);
  Saved := Copy(StateBytes);
  Check(Length(Saved) = 5 + MapBytes, 'saved: header and the CC map', Format('%d bytes', [Length(Saved)]));
  Check((Length(Saved) > 4) and (Saved[0] = Ord('M')) and (Saved[2] = Ord('9')), 'with the Mz909''s own magic', '');
  EndPair;

  StartPair;
  VT.SetState(Inst, @Saved[0], Length(Saved));
  Check(Learned and MapIsSane(Plugin, Why), 'a new instance takes the map back', Why);

  // Hostile state: never an exception, never a broken map; damaged data changes nothing.
  Exceptions := 0;
  Data := Copy(Saved); SetLength(Data, Length(Data) - 1); Load(Data);   // truncated
  Data := Copy(Saved); SetLength(Data, Length(Data) + 1); Load(Data);   // trailing byte
  Data := Copy(Saved); Data[0] := Ord('X'); Load(Data);                 // magic
  Data := Copy(Saved); Data[4] := 2; Load(Data);                        // a later version
  Data := Copy(Saved); Data[7] := 200; Load(Data);                      // entries beyond the data
  SetLength(Data, 3);
  Load(Data);
  Check(Learned and (Exceptions = 0), 'damaged state is refused; the map stays', '');

  Bad := 0;
  Seed := 2463534242;
  for Run := 0 to 19999 do
  begin
    if Run mod 2 = 0 then
    begin
      Data := Copy(Saved);            // a valid state, mutated
      for I := 0 to Integer(NextRandom mod 4) do
        Data[NextRandom mod UInt32(Length(Data))] := NextRandom and $FF;
      if NextRandom mod 4 = 0 then
        SetLength(Data, Integer(NextRandom mod UInt32(Length(Data) + 8)));
    end
    else
    begin
      SetLength(Data, NextRandom mod 400);
      for I := 0 to High(Data) do
        Data[I] := NextRandom and $FF;
    end;
    Load(Data);
    if not MapIsSane(Plugin, Why) then
      Inc(Bad);
  end;
  Check((Exceptions = 0) and (Bad = 0), '20000 random and mutated states', Format('%d exceptions, %d broken', [Exceptions, Bad]));

  VT.SetState(Inst, nil, 0);
  Check(MapIsDefault(Plugin), 'a project without state has the default CCs', '');
  Check(Plugin.ProcessErrors = 0, 'no exceptions in Process', '');
  EndPair;
end;

type
  // Changes the map and strikes pads from another thread while Process runs: the panel's side.
  TPanelThread = class(TThread)
  protected
    procedure Execute; override;
  public
    P: TMz909;
    Changes: Integer;
  end;

procedure TPanelThread.Execute;
var
  I: Integer;
begin
  I := 0;
  while not Terminated do
  begin
    case I mod 5 of
      0: P.Learn(I mod NumSpecs);
      1: P.ForgetCc(I mod NumSpecs);
      2: P.RestoreDefaultCc((I * 7) mod NumSpecs);
      3: P.Learn(-1);
      4: if I mod 50 = 4 then P.ResetAllCcs;
    end;
    P.Strike(I mod VoiceCount, I mod 3 = 0);
    Inc(I);
    Inc(Changes);
  end;
end;

procedure PadChecks;
var
  B, V: Integer;
  Worst, Reversed: Double;
  Changer: TPanelThread;
  Why: string;
  Other: TEngine;
  OtherOut: array[0..BlockSize - 1] of Single;
begin
  Writeln;
  Writeln('the pads');

  StartPair;
  Worst := Both;
  // a pad plays from the top of the next block, as MIDI at sample 0
  Check(Plugin.Strike(VoiceBD, False), 'a pad''s hit is queued', '');
  RefPad(36, PadVelocity);
  for B := 0 to 9 do
    Worst := Max(Worst, Both);
  Check(Hits(VoiceBD) = 1, 'it sounds, and its hit count shows it', Format('BD %d', [Hits(VoiceBD)]));
  // accented: velocity 127
  Plugin.Strike(VoiceSD, True);
  RefPad(38, PadAccentVelocity);
  Midi(100, $90, 36, 100);
  for B := 0 to 9 do
    Worst := Max(Worst, Both);
  Check((Worst = 0) and (Hits(VoiceSD) = 1), 'plain and accented: bit-identical to the same notes from MIDI',
    Format('max diff %.3e', [Worst]));

  // A pad's note joins the host's MIDI at sample 0 after the host's own: a closed hat from
  // a pad chokes an open one the host sends at sample 0 - the other way round, it would not.
  for B := 0 to 40 do
    Both;
  Other := TEngine.Create;
  Other.Prepare(Rate);
  Other.SetSettings(RefSettings);
  Midi(0, $90, 46, 100);
  Plugin.Strike(VoiceCH, False);
  RefPad(42, PadVelocity);
  Other.NoteOn(42, PadVelocity);    // pad first ...
  Other.NoteOn(46, 100);            // ... then the host: the wrong order
  Worst := Max(Worst, Both);
  Other.Render(@OtherOut[0], BlockSize);
  Reversed := 0;
  for B := 0 to BlockSize - 1 do
    Reversed := Max(Reversed, Abs(OtherOut[B] - RefOut[B]));
  Other.Free;
  Check((Worst = 0) and (Reversed > 0), 'pads after the host''s MIDI at sample 0, as the C++ MidiKeyboardState',
    Format('max diff %.3e (the other order differs by %.3e)', [Worst, Reversed]));

  Check(not Plugin.Strike(-1, False) and not Plugin.Strike(VoiceCount, False), 'voices out of range are refused', '');
  Check(not Plugin.QueueKey(128, 80) and not Plugin.QueueKey(-1, 80) and not Plugin.QueueKey(60, 0)
    and not Plugin.QueueKey(60, 128), 'notes and velocities out of range are refused', '');
  for B := 1 to KeyQueueSize - 1 do
    Plugin.Strike(B mod VoiceCount, False);
  Check(not Plugin.Strike(VoiceBD, False), 'a full queue refuses, it does not overwrite', '');
  ProcessPlugin(BlockSize);
  Check(Plugin.Strike(VoiceBD, False), 'and takes hits again once a block has run', '');
  ProcessPlugin(BlockSize);
  V := 0;
  for B := 0 to VoiceCount - 1 do
    Inc(V, Hits(B));
  Check(V = 2 + 1 + 2 + (KeyQueueSize - 1) + 1, 'every queued hit was played, once (and the MIDI)', Format('%d hits', [V]));
  EndPair;

  // the hand-off under load: the panel's thread changes the map and strikes while Process
  // runs with CCs (lock-free: nothing here may block or corrupt the other side)
  StartPair;
  Changer := TPanelThread.Create(True);
  Changer.P := Plugin;
  Changer.Start;
  for B := 0 to 2999 do
  begin
    Midi(B mod BlockSize, $B0, 1 + B mod 118, B mod 128);
    ProcessPlugin(BlockSize);
    NumEvents := 0;
    if B mod 10 = 0 then
      Deliver;
  end;
  Changer.Terminate;
  Changer.WaitFor;
  Check((Plugin.ProcessErrors = 0) and (Changer.Changes > 0), 'Process alongside a thread changing the map',
    Format('%d changes', [Changer.Changes]));
  Changer.Free;
  Plugin.ResetAllCcs;
  Plugin.Learn(-1);
  Check(MapIsDefault(Plugin) and MapIsSane(Plugin, Why), 'and the map is whole afterwards', Why);
  EndPair;
end;

{ ---- the fake editor host ---- }

procedure CheckEd(E: PJcpEditor);
begin
  if E <> EditorToken then
    Inc(FE.BadHandles);
end;

procedure CheckG(G: PJcpGraphics);
begin
  if G <> GraphicsToken then
    Inc(FE.BadHandles);
  Inc(FE.Ops);
end;

function FromUtf8(P: PAnsiChar): string;
var
  U: UTF8String;
begin
  if P = nil then
    Result := ''
  else
  begin
    SetString(U, P, StrLen(P));
    Result := string(U);
  end;
end;

procedure FRepaint(E: PJcpEditor; X, Y, W, H: Single); cdecl; begin CheckEd(E); end;
procedure FSetSize(E: PJcpEditor; W, H: Int32); cdecl;
begin
  CheckEd(E);
  Inc(FE.SetSizes);
  FE.LastW := W;
  FE.LastH := H;
end;
procedure FSetResizeLimits(E: PJcpEditor; A, B, C, D: Int32); cdecl; begin CheckEd(E); end;
procedure FStartTimer(E: PJcpEditor; Hz: Int32); cdecl; begin CheckEd(E); end;
procedure FStopTimer(E: PJcpEditor); cdecl; begin CheckEd(E); end;
procedure FSetTooltip(E: PJcpEditor; Text: PAnsiChar); cdecl; begin CheckEd(E); end;

function FShowPopupMenu(E: PJcpEditor; Items: PJcpMenuItem; Count, ItemSize, MenuId: Int32; X, Y: Single): Int32; cdecl;
begin
  CheckEd(E);
  Result := 0;
  if (Items = nil) or (ItemSize <> SizeOf(TJcpMenuItem)) then
    Exit;
  Inc(FE.MenusShown);
  FE.LastMenuId := MenuId;
  FE.LastMenuCount := Count;
  FE.LastMenuText := FromUtf8(Items^.Text);
  Result := 1;
end;

function ValidIndex(I: Int32): Boolean;
begin
  Result := (I >= 0) and (I < NumParams);
end;

function Span(Index: Integer): Single;
begin
  if Index = PPatch then
    Result := NumPresets - 1
  else
    Result := 10;
end;

function FGetParameterCount(E: PJcpEditor): Int32; cdecl;
begin
  CheckEd(E);
  Result := NumParams;
end;

function FFindParameter(E: PJcpEditor; Id: PAnsiChar): Int32; cdecl;
begin
  CheckEd(E);
  if FromUtf8(Id) = 'patch' then
    Result := PPatch
  else
    Result := IndexOfId(FromUtf8(Id));
end;

function FGetParameterNormalised(E: PJcpEditor; Index: Int32): Single; cdecl;
begin
  CheckEd(E);
  if ValidIndex(Index) then Result := Host.Params[Index] / Span(Index) else Result := 0;
end;

function FGetParameterDefault(E: PJcpEditor; Index: Int32): Single; cdecl;
begin
  CheckEd(E);
  if (Index >= 0) and (Index < NumSpecs) then Result := DefaultValue(Index) / 10 else Result := 0;
end;

function FNormalisedToPlain(E: PJcpEditor; Index: Int32; V: Single): Single; cdecl;
begin
  CheckEd(E);
  Result := V * Span(Index);
end;

function FPlainToNormalised(E: PJcpEditor; Index: Int32; V: Single): Single; cdecl;
begin
  CheckEd(E);
  Result := V / Span(Index);
end;

function FGetParameterText(E: PJcpEditor; Index: Int32; V: Single; Buffer: PAnsiChar; Size: Int32): Int32; cdecl;
begin
  CheckEd(E);
  Result := 0;
  if Size > 0 then
    Buffer[0] := #0;
end;

procedure FBeginGesture(E: PJcpEditor; Index: Int32); cdecl; begin CheckEd(E); Inc(FE.Begins); end;
procedure FSetParameterNormalised(E: PJcpEditor; Index: Int32; V: Single); cdecl;
begin
  CheckEd(E);
  if ValidIndex(Index) then
    Host.Params[Index] := V * Span(Index);
end;
procedure FEndGesture(E: PJcpEditor; Index: Int32); cdecl; begin CheckEd(E); Inc(FE.Ends); end;

function FGetMeter(E: PJcpEditor; Index: Int32): Single; cdecl;
begin
  CheckEd(E);
  if (Index >= 0) and (Index <= High(Host.Meters)) then Result := Host.Meters[Index] else Result := 0;
end;

function FCreateImage(E: PJcpEditor; Data: Pointer; Size: Int32): Int32; cdecl; begin CheckEd(E); Result := 0; end;
procedure FDestroyImage(E: PJcpEditor; Image: Int32); cdecl; begin CheckEd(E); end;
function FGetImageSize(E: PJcpEditor; Image: Int32; var W, H: Int32): Int32; cdecl;
begin
  CheckEd(E);
  W := 0;
  H := 0;
  Result := 0;
end;
function FGetTextWidth(E: PJcpEditor; Text, FontName: PAnsiChar; Height: Single; Style: Int32): Single; cdecl;
begin
  CheckEd(E);
  Result := StrLen(Text) * Height * 0.5;
end;

procedure GSetColour(G: PJcpGraphics; C: Cardinal); cdecl; begin CheckG(G); end;
procedure GSetGradient(G: PJcpGraphics; C1: Cardinal; X1, Y1: Single; C2: Cardinal; X2, Y2: Single; R: Int32); cdecl; begin CheckG(G); end;
procedure GFillAll(G: PJcpGraphics); cdecl; begin CheckG(G); end;
procedure GRect(G: PJcpGraphics; X, Y, W, H: Single); cdecl; begin CheckG(G); end;
procedure GRectT(G: PJcpGraphics; X, Y, W, H, T: Single); cdecl; begin CheckG(G); end;
procedure GRectRT(G: PJcpGraphics; X, Y, W, H, R, T: Single); cdecl; begin CheckG(G); end;
procedure GLine(G: PJcpGraphics; X1, Y1, X2, Y2, T: Single); cdecl; begin CheckG(G); end;
procedure GPath(G: PJcpGraphics); cdecl; begin CheckG(G); end;
procedure GPoint(G: PJcpGraphics; X, Y: Single); cdecl; begin CheckG(G); end;
procedure GQuad(G: PJcpGraphics; A, B, C, D: Single); cdecl; begin CheckG(G); end;
procedure GCubic(G: PJcpGraphics; A, B, C, D, E, F: Single); cdecl; begin CheckG(G); end;
procedure GArc(G: PJcpGraphics; CX, CY, RX, RY, A0, A1: Single; S: Int32); cdecl; begin CheckG(G); end;
procedure GStroke(G: PJcpGraphics; T: Single; J, C: Int32); cdecl; begin CheckG(G); end;
procedure GFont(G: PJcpGraphics; Name: PAnsiChar; H: Single; S: Int32); cdecl; begin CheckG(G); end;
procedure GText(G: PJcpGraphics; Text: PAnsiChar; X, Y, W, H: Single; J, E: Int32); cdecl; begin CheckG(G); Inc(FE.Texts); end;
procedure GImage(G: PJcpGraphics; Img: Int32; DX, DY, DW, DH, SX, SY, SW, SH, O: Single); cdecl; begin CheckG(G); end;
procedure GSave(G: PJcpGraphics); cdecl; begin CheckG(G); end;
procedure GRestore(G: PJcpGraphics); cdecl; begin CheckG(G); end;
function GClip(G: PJcpGraphics; X, Y, W, H: Single): Int32; cdecl; begin CheckG(G); Result := Ord((W > 0) and (H > 0)); end;
procedure GTranslate(G: PJcpGraphics; DX, DY: Single); cdecl; begin CheckG(G); end;

procedure FSetDesignSize(E: PJcpEditor; W, H: Int32; MinS, MaxS: Single; Flags: Int32); cdecl;
begin
  CheckEd(E);
  FE.DesignW := W;
  FE.DesignH := H;
  FE.MinScale := MinS;
  FE.MaxScale := MaxS;
end;
function FGetScale(E: PJcpEditor): Single; cdecl; begin CheckEd(E); Result := 1; end;
function FOpenUrl(E: PJcpEditor; Url: PAnsiChar): Int32; cdecl;
begin
  CheckEd(E);
  Inc(FE.UrlCalls);
  FE.LastUrl := FromUtf8(Url);
  Result := 1;
end;
procedure FSetLook(E: PJcpEditor; Look: PJcpEditorLook); cdecl;
begin
  CheckEd(E);
  Inc(FE.LookCalls);
  if Look <> nil then
  begin
    FE.LastLook := Look^;
    FE.LastLook.FontName := nil;
  end;
end;
function FChooseFile(E: PJcpEditor; RequestId, Mode: Int32; Title, Patterns, Initial: PAnsiChar): Int32; cdecl;
begin
  CheckEd(E);
  Result := 0;
end;

procedure ResetFakeEditor;
begin
  FE.LastMenuText := '';
  FE.LastUrl := '';
  FillChar(FE, SizeOf(FE), 0);
  FillChar(FakeApi, SizeOf(FakeApi), 0);
  FakeApi.StructSize := SizeOf(FakeApi);
  FakeApi.Repaint := FRepaint;
  FakeApi.SetSize := FSetSize;
  FakeApi.SetResizeLimits := FSetResizeLimits;
  FakeApi.StartTimer := FStartTimer;
  FakeApi.StopTimer := FStopTimer;
  FakeApi.SetTooltip := FSetTooltip;
  FakeApi.ShowPopupMenu := FShowPopupMenu;
  FakeApi.GetParameterCount := FGetParameterCount;
  FakeApi.FindParameter := FFindParameter;
  FakeApi.GetParameterNormalised := FGetParameterNormalised;
  FakeApi.GetParameterDefault := FGetParameterDefault;
  FakeApi.NormalisedToPlain := FNormalisedToPlain;
  FakeApi.PlainToNormalised := FPlainToNormalised;
  FakeApi.GetParameterText := FGetParameterText;
  FakeApi.BeginGesture := FBeginGesture;
  FakeApi.SetParameterNormalised := FSetParameterNormalised;
  FakeApi.EndGesture := FEndGesture;
  FakeApi.GetMeter := FGetMeter;
  FakeApi.CreateImage := FCreateImage;
  FakeApi.DestroyImage := FDestroyImage;
  FakeApi.GetImageSize := FGetImageSize;
  FakeApi.GetTextWidth := FGetTextWidth;
  FakeApi.SetColour := GSetColour;
  FakeApi.SetGradient := GSetGradient;
  FakeApi.FillAll := GFillAll;
  FakeApi.FillRect := GRect;
  FakeApi.DrawRect := GRectT;
  FakeApi.FillRoundedRect := GRectT;
  FakeApi.DrawRoundedRect := GRectRT;
  FakeApi.FillEllipse := GRect;
  FakeApi.DrawEllipse := GRectT;
  FakeApi.DrawLine := GLine;
  FakeApi.PathBegin := GPath;
  FakeApi.PathMoveTo := GPoint;
  FakeApi.PathLineTo := GPoint;
  FakeApi.PathQuadTo := GQuad;
  FakeApi.PathCubicTo := GCubic;
  FakeApi.PathArc := GArc;
  FakeApi.PathClose := GPath;
  FakeApi.FillPath := GPath;
  FakeApi.StrokePath := GStroke;
  FakeApi.SetFont := GFont;
  FakeApi.DrawText := GText;
  FakeApi.DrawImage := GImage;
  FakeApi.SaveState := GSave;
  FakeApi.RestoreState := GRestore;
  FakeApi.ClipRect := GClip;
  FakeApi.Translate := GTranslate;
  FakeApi.SetDesignSize := FSetDesignSize;
  FakeApi.GetScale := FGetScale;
  FakeApi.OpenUrl := FOpenUrl;
  FakeApi.SetLook := FSetLook;
  FakeApi.ChooseFile := FChooseFile;
end;

function OpenEditor: TMz909Editor;
var
  W, H: Int32;
begin
  FillChar(EdVT, SizeOf(EdVT), 0);
  EdVT.StructSize := SizeOf(EdVT);
  W := 400;
  H := 300;
  Ed := VT.CreateEditor(Inst, @FakeApi, EditorToken, @EdVT, W, H);
  Result := TMz909Editor(Ed);
  if Ed <> nil then
  begin
    FE.LastW := W;
    FE.LastH := H;
  end;
end;

procedure CloseEditor;
begin
  if Ed <> nil then
    EdVT.Destroy(Ed);
  Ed := nil;
end;

procedure Mouse(Kind: Integer; X, Y: Single; Mods: Integer);
var
  E: TJcpMouseEvent;
begin
  FillChar(E, SizeOf(E), 0);
  E.StructSize := SizeOf(E);
  E.Kind := Kind;
  E.X := X;
  E.Y := Y;
  E.Modifiers := Mods;
  E.ClickCount := 1;
  EdVT.Mouse(Ed, @E);
end;

procedure Click(X, Y: Single; Mods: Integer = JCP_MOD_LEFT);
begin
  Mouse(JCP_MOUSE_DOWN, X, Y, Mods);
  Mouse(JCP_MOUSE_UP, X, Y, Mods and not (JCP_MOD_LEFT or JCP_MOD_RIGHT or JCP_MOD_POPUP));
end;

const
  // The C++ Panel's layout (Panel::resized), in panel coordinates.
  Margin = 14; ColumnWidth = 92; ColumnGap = 6; ColumnTop = 62; TitleHeight = 44; KnobHeight = 76;
  PadTop = 358; PadWidth = 38; PadHeight = 70;

type
  TKnobPlace = record
    Param, Column, Row: Integer;
  end;

const
  KnobPlaces: array[0..NumSpecs - 1] of TKnobPlace = (
    (Param: PAccent; Column: 0; Row: 0),
    (Param: PBdLevel; Column: 1; Row: 0), (Param: PBdTune; Column: 1; Row: 1),
    (Param: PBdAttack; Column: 1; Row: 2), (Param: PBdDecay; Column: 1; Row: 3),
    (Param: PSdLevel; Column: 2; Row: 0), (Param: PSdTune; Column: 2; Row: 1),
    (Param: PSdTone; Column: 2; Row: 2), (Param: PSdSnappy; Column: 2; Row: 3),
    (Param: PLtLevel; Column: 3; Row: 0), (Param: PLtTune; Column: 3; Row: 1), (Param: PLtDecay; Column: 3; Row: 2),
    (Param: PMtLevel; Column: 4; Row: 0), (Param: PMtTune; Column: 4; Row: 1), (Param: PMtDecay; Column: 4; Row: 2),
    (Param: PHtLevel; Column: 5; Row: 0), (Param: PHtTune; Column: 5; Row: 1), (Param: PHtDecay; Column: 5; Row: 2),
    (Param: PRsLevel; Column: 6; Row: 0), (Param: PCpLevel; Column: 7; Row: 0),
    (Param: PHhLevel; Column: 8; Row: 0), (Param: PChDecay; Column: 8; Row: 1), (Param: POhDecay; Column: 8; Row: 2),
    (Param: PCrLevel; Column: 9; Row: 0), (Param: PCrTune; Column: 9; Row: 1),
    (Param: PRdLevel; Column: 10; Row: 0), (Param: PRdTune; Column: 10; Row: 1),
    (Param: PVolume; Column: 11; Row: 0)
  );

  // Each pad's column, and its place in it (the hihat column has two).
  PadColumn: array[0..VoiceCount - 1] of Integer = (1, 2, 3, 4, 5, 6, 7, 8, 8, 9, 10);
  PadSlot: array[0..VoiceCount - 1] of Integer = (0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0);
  PadsInColumn: array[0..VoiceCount - 1] of Integer = (1, 1, 1, 1, 1, 1, 1, 2, 2, 1, 1);

function ColumnX(Column: Integer): Integer;
begin
  Result := Margin + Column * (ColumnWidth + ColumnGap);
end;

// The C++ Pad component's left edge.
function PadX(Voice: Integer): Integer;
var
  N, SpanW: Integer;
begin
  N := PadsInColumn[Voice];
  SpanW := N * PadWidth + (N - 1) * 6;
  Result := ColumnX(PadColumn[Voice]) + (ColumnWidth - SpanW) div 2 + PadSlot[Voice] * (PadWidth + 6);
end;

// Plays the pads' queued hits through the plug-in and the reference, a few blocks' worth.
function Blocks(Count: Integer): Double;
var
  B: Integer;
begin
  Result := 0;
  for B := 1 to Count do
    Result := Max(Result, Both);
end;

procedure EditorChecks;
var
  E: TMz909Editor;
  I, V, Bad, X, Y: Integer;
  C: TJuceControl;
  Worst: Double;
  Why, Detail: string;
  Mk: TJuceControl;
begin
  Writeln;
  Writeln('the panel (Mz909EditorForm.lfm, strict), through a fake editor host');

  StartPair;
  ResetFakeEditor;
  E := OpenEditor;
  Check(E <> nil, 'the panel is built from its form', '');
  if E = nil then
  begin
    EndPair;
    Exit;
  end;
  Check((FE.LastW = 1198) and (FE.LastH = 540), 'the C++ panel''s size, 1198 x 540', Format('%d x %d', [FE.LastW, FE.LastH]));
  Check((FE.DesignW = 1198) and (FE.DesignH = 540) and (FE.MinScale = 0.5) and (FE.MaxScale = 2),
    'scalable from half to twice its size, as the C++ editor', Format('%g..%g', [FE.MinScale, FE.MaxScale]));
  Check((FE.LookCalls > 0) and (FE.LastLook.TooltipBackground = $FF111214) and (FE.LastLook.TooltipOutline = $FFD8392B)
    and (FE.LastLook.MenuBackground = $FF252528) and (FE.LastLook.MenuHighlight = $FFD8392B)
    and (FE.LastLook.TooltipText = $FFE8E6E0), 'tooltips and menus in the C++ PanelLook''s colours', '');

  // every knob, bound and where the C++ puts it
  Bad := 0;
  Detail := '';
  for I := 0 to NumSpecs - 1 do
  begin
    C := E.SpecControl(KnobPlaces[I].Param);
    X := ColumnX(KnobPlaces[I].Column) + 4 + KnobInsetX;
    Y := ColumnTop + TitleHeight + KnobPlaces[I].Row * KnobHeight;
    if not (C is TJuceKnob) or (Round(C.AbsoluteX) <> X) or (Round(C.AbsoluteY) <> Y) or (C.Width <> 66)
      or (C.Height <> KnobHeight - LegendHeight) then
    begin
      Inc(Bad);
      if C <> nil then
        Detail := Detail + Format(' %s at %g,%g', [Specs[KnobPlaces[I].Param].Id, C.AbsoluteX, C.AbsoluteY])
      else
        Detail := Detail + ' ' + Specs[KnobPlaces[I].Param].Id + ' missing';
    end;
  end;
  Check(Bad = 0, 'the 28 knobs, bound, in the C++ columns and rows', Detail);

  // every pad and its light
  Bad := 0;
  for V := 0 to VoiceCount - 1 do
    if (E.Pad(V) = nil) or (E.PadLed(V) = nil) or (Round(E.Pad(V).AbsoluteX) <> PadX(V))
      or (Round(E.Pad(V).AbsoluteY) <> ColumnTop + PadTop + 14) or (E.Pad(V).Width <> PadWidth)
      or (E.Pad(V).Height <> PadHeight - 14) or (E.Pad(V).Mode <> jbmMomentary)
      or (Abs(E.PadLed(V).AbsoluteX + 4.5 - (PadX(V) + PadWidth / 2)) > 1) then
      Inc(Bad);
  Check(Bad = 0, 'the 11 pads (momentary) and their lights, where the C++ puts them', Format('%d wrong', [Bad]));
  C := E.FindControl('AccentButton');
  Check((C is TJuceButton) and (Round(C.AbsoluteX) = ColumnX(0) + 10) and (Round(C.AbsoluteY) = ColumnTop + PadTop + 22)
    and (TJuceButton(C).Mode = jbmToggle), 'ACCENT, a latching button under the ACCENT knob', '');
  C := E.FindControl('ProjectLink');
  Check((C is TJuceLink) and (C.Caption = 'Mz909_Pascal 0.3.0  -  github.com/simozzer/Mz909')
    and (TJuceLink(C).Url = 'https://github.com/simozzer/Mz909') and (C.Left = 1198 - 14 - 220 - 16 - 420),
    'the project link, beside the kit menu', C.Caption);
  C := E.FindControl('PatchBox');
  Check((C is TJuceComboBox) and (TJuceComboBox(C).ChoiceCount = NumPresets) and (C.Left = 1198 - 14 - 220),
    'the kit menu offers the 9 kits', '');

  // paint everything once
  EdVT.Paint(Ed, GraphicsToken);
  Check((FE.BadHandles = 0) and (FE.Texts >= 80), 'paints (every label, legend and pad: 80 texts)', Format('%d texts', [FE.Texts]));

  // The pads: a press plays (the release does nothing), shift or ACCENT accent it.
  Worst := Blocks(2);
  EdVT.Timer(Ed);
  Check(not E.PadLed(VoiceBD).Lit, 'the lights start dark', '');
  X := PadX(VoiceBD) + PadWidth div 2;
  Y := ColumnTop + PadTop + 40;
  Mouse(JCP_MOUSE_DOWN, X, Y, JCP_MOD_LEFT);
  RefPad(36, PadVelocity);
  Worst := Max(Worst, Blocks(1));
  Mouse(JCP_MOUSE_UP, X, Y, 0);
  Worst := Max(Worst, Blocks(3));
  EdVT.Timer(Ed);
  Check((Hits(VoiceBD) = 1) and E.PadLed(VoiceBD).Lit and not E.PadLed(VoiceSD).Lit,
    'a press on BD plays it once, and lights its pad', Format('BD %d', [Hits(VoiceBD)]));
  Sleep(PadLightMs + 60);
  EdVT.Timer(Ed);
  Check(not E.PadLed(VoiceBD).Lit, 'the light goes out after 110 ms', '');

  X := PadX(VoiceSD) + PadWidth div 2;
  Click(X, Y, JCP_MOD_LEFT or JCP_MOD_SHIFT);
  RefPad(38, PadAccentVelocity);
  Worst := Max(Worst, Blocks(4));
  X := PadX(VoiceOH) + PadWidth div 2;
  Click(X, Y + 20);                                      // on the note number: still the pad
  RefPad(46, PadVelocity);
  Worst := Max(Worst, Blocks(4));
  Click(ColumnX(0) + 46, ColumnTop + PadTop + 42);       // ACCENT on
  Check(E.AccentLit, 'a click lights ACCENT', '');
  X := PadX(VoiceCH) + PadWidth div 2;
  Click(X, Y);
  RefPad(42, PadAccentVelocity);
  Worst := Max(Worst, Blocks(4));
  Click(ColumnX(0) + 46, ColumnTop + PadTop + 42);       // and off
  X := PadX(VoiceRC) + PadWidth div 2;
  Click(X, ColumnTop + PadTop + 4);                      // on its light: the light is the pad's too
  RefPad(51, PadVelocity);
  Click(X, Y, JCP_MOD_RIGHT or JCP_MOD_POPUP);           // a right-click plays nothing
  Worst := Max(Worst, Blocks(4));
  Check((Worst = 0) and (Hits(VoiceSD) = 1) and (Hits(VoiceCH) = 1) and (Hits(VoiceOH) = 1) and (Hits(VoiceRC) = 1)
    and not E.AccentLit, 'shift-click and ACCENT play accented: bit-identical to the notes from MIDI',
    Format('max diff %.3e, RC %d', [Worst, Hits(VoiceRC)]));

  // MIDI learn from the panel: right-click BASS DRUM TUNE, choose MIDI Learn
  C := E.SpecControl(PBdTune);
  Check(Pos('MIDI CC 16.', C.Hint) > 0, 'a knob''s hint names its CC', StringReplace(C.Hint, #10, ' | ', [rfReplaceAll]));
  Mk := E.LearnMarker;
  Check(not Mk.Visible, 'no outline yet', '');
  Click(C.AbsoluteX + 33, C.AbsoluteY + 29, JCP_MOD_RIGHT or JCP_MOD_POPUP);
  Check((FE.MenusShown = 1) and (FE.LastMenuCount = 6) and (FE.LastMenuText = 'Bass Drum Tune  -  CC 16'),
    'right-click opens the MIDI learn menu', FE.LastMenuText);
  EdVT.PopupResult(Ed, FE.LastMenuId, MenuLearn);
  EdVT.Timer(Ed);
  Check((Plugin.LearningIndex = PBdTune) and (Pos('MIDI LEARN', C.Hint) > 0), '"MIDI Learn": the knob waits, and its hint says so', '');
  X := ColumnX(1) + 4;
  Y := ColumnTop + TitleHeight + KnobHeight;
  Check(Mk.Visible and (Round(Mk.AbsoluteX) = X) and (Round(Mk.AbsoluteY) = Y) and (Mk.Width = 84) and (Mk.Height = KnobHeight),
    'the red outline round the knob and its legend (the C++ PanelKnob)',
    Format('%g,%g %dx%d', [Mk.AbsoluteX, Mk.AbsoluteY, Mk.Width, Mk.Height]));
  Midi(30, $B0, 1, 99);
  ProcessPlugin(BlockSize);
  NumEvents := 0;
  EdVT.Timer(Ed);
  Check((Plugin.CcFor(PBdTune) = 1) and not Mk.Visible and (Pos('MIDI CC 1, learned (default 16)', C.Hint) > 0),
    'a CC is learned; the outline goes, the hint says so', StringReplace(C.Hint, #10, ' | ', [rfReplaceAll]));
  Click(C.AbsoluteX + 33, C.AbsoluteY + 29, JCP_MOD_RIGHT or JCP_MOD_POPUP);
  EdVT.PopupResult(Ed, FE.LastMenuId, MenuRestore);
  Check(Plugin.CcFor(PBdTune) = 16, '"Restore default (CC 16)" from the menu', '');
  Click(C.AbsoluteX + 33, C.AbsoluteY + 29, JCP_MOD_RIGHT or JCP_MOD_POPUP);
  EdVT.PopupResult(Ed, FE.LastMenuId, MenuForget);
  Check(Plugin.CcFor(PBdTune) = -1, '"Forget CC"', '');
  Click(C.AbsoluteX + 33, C.AbsoluteY + 29, JCP_MOD_RIGHT or JCP_MOD_POPUP);
  EdVT.PopupResult(Ed, FE.LastMenuId, MenuResetAll);
  Check(MapIsDefault(Plugin) and MapIsSane(Plugin, Why), '"Reset all CCs to defaults"', Why);

  // a knob drag is one gesture on its own parameter
  FE.Begins := 0;
  FE.Ends := 0;
  C := E.SpecControl(PSdTone);
  Mouse(JCP_MOUSE_DOWN, C.AbsoluteX + 33, C.AbsoluteY + 29, JCP_MOD_LEFT);
  Mouse(JCP_MOUSE_DRAG, C.AbsoluteX + 33, C.AbsoluteY + 29 - 45, JCP_MOD_LEFT);
  Mouse(JCP_MOUSE_UP, C.AbsoluteX + 33, C.AbsoluteY + 29 - 45, 0);
  Check((FE.Begins = 1) and (FE.Ends = 1) and (Abs(Host.Params[PSdTone] - 7.5) < 0.01) and (Host.Params[PSdTune] = 5),
    '45 px up SNARE DRUM TONE (180 px for the whole turn, as the C++) moves it a quarter',
    Format('%.3f', [Host.Params[PSdTone]]));

  // the project link
  C := E.FindControl('ProjectLink');
  Click(C.AbsoluteX + C.Width - 40, C.AbsoluteY + 13);
  Check((FE.UrlCalls = 1) and (FE.LastUrl = 'https://github.com/simozzer/Mz909'), 'a click on the link opens the project''s page', FE.LastUrl);

  CloseEditor;

  // A panel opened after hits does not flash them; many open and close.
  Midi(0, $90, 36, 100);
  Both;
  E := OpenEditor;
  EdVT.Timer(Ed);
  Check((E <> nil) and not E.PadLed(VoiceBD).Lit, 'opening the panel does not light what was struck before', '');
  CloseEditor;
  for I := 1 to 20 do
  begin
    OpenEditor;
    EdVT.Timer(Ed);
    if I mod 5 = 0 then
      EdVT.Paint(Ed, GraphicsToken);
    CloseEditor;
  end;
  Check((FE.BadHandles = 0) and (Plugin.ProcessErrors = 0), '20 panels opened and closed', '');
  EndPair;
end;

begin
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  Writeln('Mz909_Pascal plug-in check');

  RegisterMz909;
  FillChar(Factory, SizeOf(Factory), 0);
  Factory.StructSize := SizeOf(Factory);
  if pascaljuce_plugin_entry(JCP_ABI_VERSION, @Factory) <> 0 then
  begin
    Writeln('entry point refused: ', JuceDeclarationError);
    Halt(1);
  end;

  ResetHost;
  Inst := CreateInstance;
  DeclarationChecks;
  TextChecks;
  VT.Destroy(Inst);

  AudioChecks;
  CcChecks;
  PatchChecks;
  LearnChecks;
  StateChecks;
  PadChecks;
  EditorChecks;

  Writeln;
  if Failures = 0 then
    Writeln('all checks passed')
  else
    Writeln(Failures, ' FAILED');
  if Failures <> 0 then
    ExitCode := 1;
end.
