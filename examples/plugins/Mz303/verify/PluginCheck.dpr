// Mz303 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Checks of the plug-in layer (Mz303Plugin), through the library's real entry point
// with a fake host: the parameter declarations, MIDI and the CC map, MIDI learn, the Patch
// parameter, the panel's keyboard and lights, and the saved state (the CC map) -
// including hostile state.
// Audio is compared, sample for sample, with the engine driven directly as the C++
// PluginProcessor drives it.
//
// Build with run-time checks: fpc -Mdelphi -Cr -Co -Ct -CR -gl -gh (see build_verify.cmd).
program PluginCheck;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  Classes, SysUtils, Math, JuceTypes, JucePlugin,
  Tb303Settings, Tb303Engine, Mz303Params, Mz303Presets, Mz303Plugin;
const
  Rate = 48000.0;
  BlockSize = 256;

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
  RefPanelKey: Integer = -1;    // a key from the panel: note + 256 * velocity, played at the top
  StateBytes: TBytes;
procedure Check(Ok: Boolean; const What, Detail: string);
const
  Verdict: array[Boolean] of string = ('FAIL', 'ok  ');
begin
  Writeln(Format('  %s  %-52s %s', [Verdict[Ok], What, Detail]));
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

function Plugin: TMz303;
begin
  Result := TMz303(Inst);
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


procedure RefHandle(const E: TEvent);
var
  Status, D1, D2, I: Integer;
  V: Single;
begin
  Status := E.Bytes[0] and $F0;
  D1 := E.Bytes[1];
  D2 := E.Bytes[2];
  if (Status = $90) and (D2 > 0) then
    Ref.NoteOn(D1, D2)
  else if (Status = $80) or (Status = $90) then
    Ref.NoteOff(D1)
  else if Status = $E0 then
  begin
    V := (D1 or (D2 shl 7)) - 8192;
    Ref.SetPitchBend(V / 8192);
  end
  else if (Status = $B0) and ((D1 = 123) or (D1 = 120)) then
    Ref.AllNotesOff
  else if Status = $B0 then
    for I := 0 to NumSpecs - 1 do
      if Specs[I].Cc = D1 then
      begin
        SetSettingValue(RefSettings, I, CcToValue(I, D2));
        Ref.SetSettings(RefSettings);
        Break;
      end;
end;

procedure ProcessRef(N: Integer);
var
  I, Pos: Integer;
begin
  Ref.SetSettings(RefSettings);
  if RefPanelKey >= 256 then
    Ref.NoteOn(RefPanelKey and 255, RefPanelKey shr 8)
  else if RefPanelKey >= 0 then
    Ref.NoteOff(RefPanelKey);
  RefPanelKey := -1;
  Pos := 0;
  for I := 0 to NumEvents - 1 do
  begin
    if Events[I].Pos > Pos then
    begin
      Ref.Render(@RefOut[Pos], Events[I].Pos - Pos);
      Pos := Events[I].Pos;
    end;
    RefHandle(Events[I]);
  end;
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

procedure StartPair;
begin
  ResetHost;
  Inst := CreateInstance;
  Ref := TEngine.Create;
  Ref.Prepare(Rate);
  RefSettings := TSettings.Defaults;
  Ref.SetSettings(RefSettings);
  NumEvents := 0;
end;

procedure EndPair;
begin
  VT.Destroy(Inst);
  Inst := nil;
  Ref.Free;
  Ref := nil;
end;

{ ---- the checks ---- }

procedure DeclarationChecks;
var
  Info: TJcpParameterInfo;
  I, Bad: Integer;
  Kinds: array[TSpecKind] of Int32;
begin
  Writeln;
  Writeln('parameters');
  Kinds[skKnob] := Ord(jpkFloat);
  Kinds[skSwitch] := Ord(jpkChoice);

  Check(JuceDeclarationError = '', 'declarations are valid', JuceDeclarationError);
  Check(Factory.GetParameterCount = NumParams, 'parameter count', Format('%d', [Factory.GetParameterCount]));
  Bad := 0;
  for I := 0 to NumSpecs - 1 do
  begin
    FillChar(Info, SizeOf(Info), 0);
    Info.StructSize := SizeOf(Info);
    Factory.GetParameterInfo(I, @Info);
    if (string(Info.Id) <> Specs[I].Id) or (string(Info.Name) <> Specs[I].Name) or (Info.Kind <> Kinds[Specs[I].Kind])
      or (Info.DefaultValue <> DefaultValue(I)) or (Info.MinValue <> Specs[I].MinValue)
      or (Info.MaxValue <> Specs[I].MaxValue) then
    begin
      Writeln('    mismatch at ', I, ': ', Info.Id);
      Inc(Bad);
    end;
  end;
  Check(Bad = 0, 'ids, names, kinds, ranges, defaults as Params.cpp', Format('%d mismatches', [Bad]));
  Factory.GetParameterInfo(PPatch, @Info);
  Check((string(Info.Id) = 'patch') and (Info.MaxValue = NumPresets - 1), 'Patch: a choice of the 8 factory patches', string(Info.Id));
end;

procedure TextChecks;
var
  Buf: array[0..63] of AnsiChar;
  R1, R2, R3, R4, R5: Integer;
  T1, T2, T3, T4: string;
begin
  Writeln;
  Writeln('display text');
  R1 := VT.GetParameterText(Inst, PCutoff, 6, @Buf[0], Length(Buf));
  T1 := string(PAnsiChar(@Buf[0]));
  R2 := VT.GetParameterText(Inst, PDecay, 2.34, @Buf[0], Length(Buf));
  T2 := string(PAnsiChar(@Buf[0]));
  R3 := VT.GetParameterText(Inst, PTune, 12.4, @Buf[0], Length(Buf));
  T3 := string(PAnsiChar(@Buf[0]));
  R4 := VT.GetParameterText(Inst, PTune, -37, @Buf[0], Length(Buf));
  T4 := string(PAnsiChar(@Buf[0]));
  R5 := VT.GetParameterText(Inst, PWave, 1, @Buf[0], Length(Buf));
  Check((R1 = 1) and (T1 = '6.0') and (R2 = 1) and (T2 = '2.3'), 'knobs show one decimal place', T1 + ', ' + T2);
  Check((R3 = 1) and (T3 = '+12 cents') and (R4 = 1) and (T4 = '-37 cents'), 'TUNING shows cents', T3 + ', ' + T4);
  Check(R5 = 0, 'the switch shows its position names (host default)', '');
end;

function Lights: string;
begin
  Result := Format('accent %g slide %g', [Host.Meters[MeterAccent], Host.Meters[MeterSlide]]);
end;

procedure AudioChecks;
var
  B: Integer;
  Worst: Double;
  Lit: string;
begin
  Writeln;
  Writeln('MIDI into audio, against the engine driven directly');

  StartPair;
  Worst := 0;
  Lit := '';
  Midi(10, $90, 36, 80);
  Worst := Max(Worst, Both);
  for B := 1 to 40 do
  begin
    if B = 3 then Midi(77, $91, 48, 110);       // channel 2, accented, over the first: a slide
    if B = 4 then Lit := Lit + Lights + '; ';
    if B = 5 then Midi(0, $E0, 0, 96);          // bend up
    if B = 8 then Midi(128, $90, 48, 0);        // note-on velocity 0 is a note-off: slides back,
                                                // still lit as accented, as the C++ engine
    if B = 9 then Midi(3, $E0, 0, 64);          // centre
    if B = 10 then Lit := Lit + Lights + '; ';
    if B = 12 then
    begin
      Midi(50, $80, 36, 0);
      Midi(50, $90, 60, 100);                   // two events on one sample: no slide
    end;
    if B = 13 then Lit := Lit + Lights + '; ';
    if B = 15 then Midi(255, $80, 60, 0);
    if B = 16 then Lit := Lit + Lights;
    Worst := Max(Worst, Both);
  end;
  Check(Worst = 0, 'notes, accents, slides, bend: bit-identical, L = R', Format('max diff %.3e', [Worst]));
  Check(Lit = 'accent 1 slide 1; accent 1 slide 1; accent 1 slide 0; accent 0 slide 0',
    'the ACCENT and SLIDE lights are published', Lit);
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
  Midi(0, $90, 45, 100);
  Worst := Max(Worst, Both);

  // CC 74 is CUT OFF FREQ: it moves the parameter, and the sound from this sample.
  Midi(100, $B0, 74, 30);
  Worst := Max(Worst, Both);
  Expect := CcToValue(PCutoff, 30);
  Check(Host.Dirty[PCutoff] and (Host.Requested[PCutoff] = Expect), 'CC 74 sets CUT OFF FREQ through the host',
    Format('%.4f (%.4f)', [Host.Requested[PCutoff], Expect]));

  // The host has not reported it back yet: the engine must keep the CC's value.
  for B := 0 to 5 do
    Worst := Max(Worst, Both);
  Deliver;
  for B := 0 to 5 do
    Worst := Max(Worst, Both);
  Check(Worst = 0, 'takes effect at its sample, and stays while the host catches up', Format('max diff %.3e', [Worst]));

  // the switch: CC 70 (WAVEFORM) takes the nearest position; TUNING spans -100..100
  Midi(5, $B0, 70, 64);
  Midi(9, $B0, 14, 0);
  Worst := Max(Worst, Both);
  Check((Host.Requested[PWave] = WaveSquare) and (Host.Requested[PTune] = -100),
    'CC 70 at 64 is SQUARE; CC 14 at 0 is -100 cents',
    Format('wave %.0f, tune %.0f', [Host.Requested[PWave], Host.Requested[PTune]]));
  Midi(5, $B0, 70, 63);
  Worst := Max(Worst, Both);
  Check(Host.Requested[PWave] = WaveSaw, 'and at 63, SAW', '');
  Check(Host.GestureDepth = 0, 'gestures balanced', Format('%d open', [Host.GestureDepth]));
  Check(Worst = 0, 'all bit-identical', Format('max diff %.3e', [Worst]));

  // all notes off
  Midi(20, $B0, 123, 0);
  Worst := Max(Worst, Both);
  Check(not Plugin.Engine.GateIsOn and (Worst = 0), 'CC 123 all notes off', '');
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
  Midi(0, $90, 40, 100);
  Worst := Max(Worst, Both);

  // Choose 'Accent Wow': applied once the choice has settled (50 ms), not before.
  Host.Params[PPatch] := 4;
  Applied := -1;
  PresetValuesOf(4, Values);
  for B := 1 to 30 do
  begin
    Calls := Host.SetCalls;
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
  Check(Bad = 0, 'every control set: defaults, then the patch', Format('%d wrong', [Bad]));
  Check((Values[PRes] = 10) and (Values[PAccent] = 10) and (Values[PCutoff] = 1.5), 'Accent Wow as Presets.cpp', '');
  Check(Host.GestureDepth = 0, 'each change in a gesture', Format('%d gestures, %d open', [Host.Gestures, Host.GestureDepth]));
  Check(Worst = 0, 'sounds from the block it is applied, before the host reports back', Format('max diff %.3e', [Worst]));

  Deliver;
  for B := 0 to 9 do
    Worst := Max(Worst, Both);
  Check(Worst = 0, 'and after', Format('max diff %.3e', [Worst]));

  // The user turns a knob after the patch: the patch is not applied again.
  Calls := Host.SetCalls;
  Host.Params[PCutoff] := 9;
  RefSettings.Cutoff := 9;
  for B := 0 to 20 do
    Worst := Max(Worst, Both);
  Check((Host.SetCalls = Calls) and (Worst = 0), 'tweaking a control afterwards keeps the tweak', '');
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

function MapIsSane(P: TMz303; out Why: string): Boolean;
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

function MapIsDefault(P: TMz303): Boolean;
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

  // CUT OFF FREQ learns CC 16 (ACCENT's): the CC is taken and does nothing else
  Version := Plugin.MidiMapVersion;
  Plugin.Learn(PCutoff);
  Check((Plugin.LearningIndex = PCutoff) and (Plugin.MidiMapVersion <> Version), 'MIDI Learn: the control waits', '');
  Calls := Host.SetCalls;
  Midi(40, $B0, 1, 90);          // the mod wheel is not learnable
  Midi(41, $B0, 0, 5);           // nor bank select
  Midi(42, $B0, 32, 5);
  Worst := Max(Worst, Both);
  Check((Plugin.LearningIndex = PCutoff) and (Host.SetCalls = Calls), 'CC 1, 0 and 32 are not learned; it keeps waiting', '');
  Midi(10, $B0, 16, 100);
  ProcessPlugin(BlockSize);
  NumEvents := 0;
  Check((Plugin.LearningIndex = -1) and (Plugin.CcFor(PCutoff) = 16), 'the first learnable CC is taken',
    Format('CUT OFF FREQ: CC %d', [Plugin.CcFor(PCutoff)]));
  Check(Host.SetCalls = Calls, 'and does nothing else (no parameter moved)', Format('%d set', [Host.SetCalls - Calls]));
  Check((Plugin.CcFor(PAccent) = -1) and MapIsSane(Plugin, Why), 'ACCENT gives CC 16 up: one control per CC', Why);

  // now CC 16 moves CUT OFF FREQ, and CC 74 nothing
  Midi(10, $B0, 16, 30);
  Midi(20, $B0, 74, 127);
  ProcessPlugin(BlockSize);
  NumEvents := 0;
  Check(Host.Dirty[PCutoff] and (Host.Requested[PCutoff] = CcToValue(PCutoff, 30)) and not Host.Dirty[PAccent],
    'the learned CC moves the control; the old one does nothing', Format('%.4f', [Host.Requested[PCutoff]]));
  Deliver;

  // cancel
  Plugin.Learn(PDecay);
  Plugin.Learn(-1);
  Midi(0, $B0, 75, 127);
  ProcessPlugin(BlockSize);
  NumEvents := 0;
  Check((Plugin.LearningIndex = -1) and (Plugin.CcFor(PDecay) = 75) and Host.Dirty[PDecay],
    'Cancel MIDI Learn: the CC goes where it went', '');
  Deliver;

  // forget, restore default (taking the CC back from whoever learned it), reset all
  Plugin.ForgetCc(PVolume);
  Check(Plugin.CcFor(PVolume) = -1, 'Forget CC', '');
  Plugin.Learn(PTune);
  Midi(0, $B0, 7, 1);
  ProcessPlugin(BlockSize);
  NumEvents := 0;
  Check(Plugin.CcFor(PTune) = 7, 'TUNING learns VOLUME''s CC 7', '');
  Plugin.RestoreDefaultCc(PVolume);
  Check((Plugin.CcFor(PVolume) = 7) and (Plugin.CcFor(PTune) = -1) and MapIsSane(Plugin, Why),
    'Restore default takes CC 7 back', Why);
  Plugin.Learn(PRes);
  Plugin.ResetAllCcs;
  Check(Plugin.LearningIndex = PRes, 'Reset all leaves learning alone', '');
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
  Saved, Scoped, Data: TBytes;
  Why: string;
  Time: Single;

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
    Result := (Plugin.CcFor(PCutoff) = 20) and (Plugin.CcFor(PVolume) = -1);
  end;

begin
  Writeln;
  Writeln('the saved state: the CC map');

  StartPair;
  Plugin.Learn(PCutoff);
  Midi(0, $B0, 20, 1);
  ProcessPlugin(BlockSize);
  NumEvents := 0;
  Plugin.ForgetCc(PVolume);
  StateBytes := nil;
  VT.GetState(Inst, StateWriter, nil);
  Saved := Copy(StateBytes);
  Check(Length(Saved) = 5 + MapBytes, 'saved: header and the CC map', Format('%d bytes', [Length(Saved)]));
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
  Scoped := Copy(Saved);                                                // the first builds': + a scope time
  SetLength(Scoped, Length(Scoped) + 6);
  Scoped[High(Scoped) - 5] := Ord('S');
  Scoped[High(Scoped) - 4] := Ord('T');
  Time := 20;
  Move(Time, Scoped[High(Scoped) - 3], 4);
  Data := Copy(Scoped);                                                 // NaN time
  for I := Length(Data) - 4 to Length(Data) - 1 do
    Data[I] := $FF;
  Load(Data);
  Data := Copy(Scoped);                                                 // 0.5 ms: too short
  Time := 0.5;
  Move(Time, Data[Length(Data) - 4], 4);
  Load(Data);
  Data := Copy(Scoped); Data[Length(Data) - 6] := Ord('X'); Load(Data); // not a scope block
  SetLength(Data, 3);
  Load(Data);
  Check(Learned and (Exceptions = 0), 'damaged state is refused; the map stays', '');
  VT.SetState(Inst, nil, 0);
  Load(Scoped);
  Check(Learned and (Exceptions = 0), 'a state from the first builds, with a scope time, still loads', '');

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
      SetLength(Data, NextRandom mod 300);
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
  // Changes the map and plays keys from another thread while Process runs: the panel's side.
  TPanelThread = class(TThread)
  protected
    procedure Execute; override;
  public
    P: TMz303;
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
    if I mod 2 = 0 then
      P.QueueKey(30 + I mod 30, PanelVelocity)
    else
      P.QueueKey(30 + I mod 30, 0);
    Inc(I);
    Inc(Changes);
  end;
end;

procedure PanelChecks;
var
  B: Integer;
  Worst: Double;
  Changer: TPanelThread;
  Why: string;
begin
  Writeln;
  Writeln('the panel''s keyboard');

  StartPair;
  Worst := Both;
  // a key from the panel plays from the top of the next block, as MIDI at sample 0
  Check(Plugin.QueueKey(36, PanelVelocity), 'a key down is queued', '');
  RefPanelKey := 36 + 256 * PanelVelocity;
  for B := 0 to 9 do
    Worst := Max(Worst, Both);
  Check(Plugin.Engine.GateIsOn and not Plugin.Engine.Accented and (Host.Meters[MeterKeysHeld + 2] = 16),
    'it sounds, unaccented, and the key shows as held', Format('keys %g', [Host.Meters[MeterKeysHeld + 2]]));
  // with ACCENT latched: velocity 127, an accent - and over the held key, a slide
  Plugin.QueueKey(43, PanelAccentVelocity);
  RefPanelKey := 43 + 256 * PanelAccentVelocity;
  for B := 0 to 9 do
    Worst := Max(Worst, Both);
  Check(Plugin.Engine.Accented and (Host.Meters[MeterAccent] = 1) and (Host.Meters[MeterSlide] = 1),
    'ACCENT latched: accented, and slid into', Lights);
  Plugin.QueueKey(43, 0);
  RefPanelKey := 43;
  for B := 0 to 9 do
    Worst := Max(Worst, Both);
  Plugin.QueueKey(36, 0);
  RefPanelKey := 36;
  for B := 0 to 9 do
    Worst := Max(Worst, Both);
  Check((Worst = 0) and (Host.Meters[MeterKeysHeld + 2] = 0), 'and lets go: bit-identical to MIDI', Format('max diff %.3e', [Worst]));
  Check(not Plugin.QueueKey(128, 80) and not Plugin.QueueKey(-1, 80), 'notes out of range are refused', '');
  for B := 1 to KeyQueueSize - 1 do
    Plugin.QueueKey(60, 80 * (B mod 2));
  Check(not Plugin.QueueKey(60, 80), 'a full queue refuses, it does not overwrite', '');
  ProcessPlugin(BlockSize);
  Check(Plugin.QueueKey(60, 0), 'and takes keys again once a block has run', '');
  ProcessPlugin(BlockSize);
  EndPair;

  // the hand-off under load: the panel's thread changes the map and plays while Process
  // runs with CCs (lock-free: nothing here may block or corrupt the other side)
  StartPair;
  Changer := TPanelThread.Create(True);
  Changer.P := Plugin;
  Changer.Start;
  for B := 0 to 2999 do
  begin
    Midi(B mod BlockSize, $B0, 2 + B mod 117, B mod 128);
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

begin
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  Writeln('Mz303_Pascal plug-in check');

  RegisterMz303;
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
  PanelChecks;

  Writeln;
  if Failures = 0 then
    Writeln('all checks passed')
  else
    Writeln(Failures, ' FAILED');
  if Failures <> 0 then
    ExitCode := 1;
end.
