// Mz808 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Checks of the plug-in layer (Mz808Plugin), through the library's real entry point
// with a fake host: the parameter declarations, MIDI and the CC map, MIDI learn, the Patch
// parameter, the panel's pads and their lights, and the saved state (the CC map) -
// including hostile state. And the panel as the layout builds it (Mz808Editor, without a
// window): every knob bound, every pad where the C++ panel has it, and pressed, playing.
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
  Classes, SysUtils, Math, JuceTypes, JucePlugin, JuceUI, JuceControls,
  Tr808Settings, Tr808Engine, Mz808Params, Mz808Presets, Mz808Plugin, Mz808Editor;
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

  // The editor's mouse, as the wrapper delivers it.
  TPanelProbe = class(TMz808Editor)
  public
    procedure Mouse(Kind: Integer; X, Y: Single; Modifiers: Integer);
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
  RefPads: array[0..15] of Integer;   // pads from the panel: note + 256 * velocity, played at the top
  NumRefPads: Integer;
  StateBytes: TBytes;

procedure Check(Ok: Boolean; const What, Detail: string);
const
  Verdict: array[Boolean] of string = ('FAIL', 'ok  ');
begin
  Writeln(Format('  %s  %-58s %s', [Verdict[Ok], What, Detail]));
  if not Ok then
    Inc(Failures);
end;

procedure TPanelProbe.Mouse(Kind: Integer; X, Y: Single; Modifiers: Integer);
var
  E: TJcpMouseEvent;
begin
  FillChar(E, SizeOf(E), 0);
  E.StructSize := SizeOf(E);
  E.Kind := Kind;
  E.X := X;
  E.Y := Y;
  E.Modifiers := Modifiers;
  E.ClickCount := 1;
  MouseEvent(E);
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

function Plugin: TMz808;
begin
  Result := TMz808(Inst);
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

// A pad struck on the panel: the reference plays it at the top of the next block.
procedure RefPad(Voice: Integer; Accented: Boolean);
begin
  if Accented then
    RefPads[NumRefPads] := VoiceInfo(Voice).Note + 256 * PadAccentVelocity
  else
    RefPads[NumRefPads] := VoiceInfo(Voice).Note + 256 * PadVelocity;
  Inc(NumRefPads);
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

procedure ProcessRef(N: Integer);
var
  I, Pos: Integer;
begin
  Ref.SetSettings(RefSettings);
  for I := 0 to NumRefPads - 1 do
    Ref.NoteOn(RefPads[I] and 255, RefPads[I] shr 8);
  NumRefPads := 0;
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
  NumRefPads := 0;
end;

procedure EndPair;
begin
  VT.Destroy(Inst);
  Inst := nil;
  Ref.Free;
  Ref := nil;
end;

// What Process published as a sound's hit count.
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
  Check(Factory.GetParameterCount = NumParams, 'parameter count', Format('%d', [Factory.GetParameterCount]));
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
  Check(Bad = 0, 'ids, names, kinds, ranges, defaults as Params.cpp', Format('%d mismatches', [Bad]));
  Bad := 0;
  for I := 0 to NumSpecs - 1 do
    if not Learnable(Specs[I].Cc) then
      Inc(Bad);
  Check(Bad = 0, 'every default CC is learnable (the C++ jassert)', Format('%d not', [Bad]));
  Factory.GetParameterInfo(PPatch, @Info);
  Check((string(Info.Id) = 'patch') and (Info.MaxValue = NumPresets - 1), 'Patch: a choice of the 9 factory kits', string(Info.Id));
end;

procedure TextChecks;
var
  Buf: array[0..63] of AnsiChar;
  R1, R2, R3: Integer;
  T1, T2: string;
begin
  Writeln;
  Writeln('display text');
  R1 := VT.GetParameterText(Inst, PBdDecay, 6, @Buf[0], Length(Buf));
  T1 := string(PAnsiChar(@Buf[0]));
  R2 := VT.GetParameterText(Inst, PCyTone, 2.34, @Buf[0], Length(Buf));
  T2 := string(PAnsiChar(@Buf[0]));
  R3 := VT.GetParameterText(Inst, PPatch, 1, @Buf[0], Length(Buf));
  Check((R1 = 1) and (T1 = '6.0') and (R2 = 1) and (T2 = '2.3'), 'knobs show one decimal place', T1 + ', ' + T2);
  Check(R3 = 0, 'the patch shows its kit''s name (host default)', '');
end;

procedure AudioChecks;
var
  B, V: Integer;
  Worst: Double;
  Counts: string;
begin
  Writeln;
  Writeln('MIDI into audio, against the engine driven directly');

  StartPair;
  Worst := 0;
  Midi(10, $99, 36, 100);                      // channel 10: the bass drum
  Worst := Max(Worst, Both);
  Check(Hits(VoiceBD) = 1, 'a hit is counted for the panel''s light', Format('BD %d', [Hits(VoiceBD)]));
  for B := 1 to 60 do
  begin
    case B of
      2: begin Midi(5, $90, 38, 127); Midi(5, $90, 42, 101); end;      // accented, on one sample
      3: Midi(77, $91, 46, 100);                                       // channel 2: open hat
      4: Midi(0, $80, 46, 0);                                          // note-offs do nothing
      5: Midi(200, $9F, 42, 30);                                       // closed hat chokes it
      6: Midi(128, $90, 49, 0);                                        // velocity 0: nothing
      7: begin Midi(1, $90, 39, 90); Midi(2, $90, 70, 90); end;        // clap, maracas cut it
      9: begin Midi(64, $90, 43, 110); Midi(64, $90, 64, 100); end;    // tom, its conga
      11: begin Midi(30, $90, 37, 100); Midi(31, $90, 75, 120); end;   // rim shot, claves
      13: begin Midi(0, $90, 56, 100); Midi(255, $90, 50, 100); end;
      15: Midi(100, $90, 62, 127);
      17: begin Midi(12, $90, 47, 100); Midi(13, $90, 63, 100); end;
      19: Midi(3, $90, 60, 100);                                       // not on the map
      21: Midi(9, $A0, 36, 100);                                       // aftertouch: nothing
      23: Midi(50, $B0, 120, 0);                                       // all sound off
      25: begin Midi(0, $90, 35, 127); Midi(0, $90, 40, 100); Midi(0, $90, 52, 100); end;
    end;
    Worst := Max(Worst, Both);
  end;
  Check(Worst = 0, 'every sound, accents, chokes: bit-identical, L = R', Format('max diff %.3e', [Worst]));
  Counts := '';
  for V := 0 to VoiceCount - 1 do
    Counts := Counts + VoiceInfo(V).Code + IntToStr(Hits(V)) + ' ';
  Check((Hits(VoiceBD) = 2) and (Hits(VoiceSD) = 2) and (Hits(VoiceCH) = 2) and (Hits(VoiceOH) = 1)
    and (Hits(VoiceCY) = 1) and (Hits(VoiceCP) = 1) and (Hits(VoiceMA) = 1) and (Hits(VoiceLC) = 1),
    'the hit counts are published', Trim(Counts));
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

  // CC 17 is BASS DRUM DECAY: it moves the parameter, and the sound from this sample.
  Midi(100, $B0, 17, 30);
  Worst := Max(Worst, Both);
  Expect := CcToValue(PBdDecay, 30);
  Check(Host.Dirty[PBdDecay] and (Host.Requested[PBdDecay] = Expect), 'CC 17 sets BASS DRUM DECAY through the host',
    Format('%.4f (%.4f)', [Host.Requested[PBdDecay], Expect]));

  // The host has not reported it back yet: the engine must keep the CC's value.
  for B := 0 to 5 do
    Worst := Max(Worst, Both);
  Deliver;
  for B := 0 to 5 do
    Worst := Max(Worst, Both);
  Check(Worst = 0, 'takes effect at its sample, and stays while the host catches up', Format('max diff %.3e', [Worst]));

  // 0..127 spans the knob: VOLUME (CC 7) at 0 is 0, ACCENT (CC 14) at 127 is 10
  Midi(5, $B0, 7, 127);
  Midi(9, $B0, 14, 127);
  Midi(40, $90, 38, 127);
  Worst := Max(Worst, Both);
  Check((Host.Requested[PVolume] = 10) and (Host.Requested[PAccent] = 10), 'CC 7 and CC 14 at 127 are 10',
    Format('volume %.2f, accent %.2f', [Host.Requested[PVolume], Host.Requested[PAccent]]));
  Midi(5, $B0, 105, 0);
  Midi(6, $B0, 123, 0);                                  // all notes off: an 808 has none
  Midi(7, $90, 42, 100);
  Worst := Max(Worst, Both);
  Check(Host.Requested[PChLevel] = 0, 'CC 105 at 0: CLOSED HIHAT LEVEL 0', '');
  for B := 0 to 9 do
    Worst := Max(Worst, Both);
  Check(Host.GestureDepth = 0, 'gestures balanced', Format('%d open', [Host.GestureDepth]));
  Check(Worst = 0, 'all bit-identical', Format('max diff %.3e', [Worst]));

  // all sound off
  Midi(0, $90, 49, 127);
  Worst := Max(Worst, Both);
  Midi(20, $B0, 120, 0);
  Worst := Max(Worst, Both);
  Check(not Plugin.Engine.Awake(CymC) and (Worst = 0), 'CC 120 all sound off', '');
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

  // Choose 'Tight': applied once the choice has settled (50 ms), not before.
  Host.Params[PPatch] := 2;
  Applied := -1;
  PresetValuesOf(2, Values);
  for B := 1 to 30 do
  begin
    if B = 12 then
      Midi(0, $90, 46, 127);
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
  Check(Bad = 0, 'every control set: defaults, then the kit', Format('%d wrong', [Bad]));
  Check((Values[PBdDecay] = 2.5) and (Values[POhDecay] = 1.5) and (Values[PAccent] = 6) and (Values[PBdLevel] = 8),
    'Tight as Presets.cpp', '');
  Check(Host.GestureDepth = 0, 'each change in a gesture', Format('%d gestures, %d open', [Host.Gestures, Host.GestureDepth]));
  Check(Worst = 0, 'sounds from the block it is applied, before the host reports back', Format('max diff %.3e', [Worst]));

  Deliver;
  Midi(10, $90, 38, 100);
  for B := 0 to 9 do
    Worst := Max(Worst, Both);
  Check(Worst = 0, 'and after', Format('max diff %.3e', [Worst]));

  // The user turns a knob after the kit: the kit is not applied again.
  Calls := Host.SetCalls;
  Host.Params[PSdTone] := 9;
  RefSettings.SdTone := 9;
  Midi(10, $90, 38, 100);
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

function MapIsSane(P: TMz808; out Why: string): Boolean;
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

function MapIsDefault(P: TMz808): Boolean;
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

  // BASS DRUM DECAY learns CC 14 (ACCENT's): the CC is taken and does nothing else
  Version := Plugin.MidiMapVersion;
  Plugin.Learn(PBdDecay);
  Check((Plugin.LearningIndex = PBdDecay) and (Plugin.MidiMapVersion <> Version), 'MIDI Learn: the control waits', '');
  Calls := Host.SetCalls;
  Midi(40, $B0, 0, 90);          // bank select is not learnable
  Midi(41, $B0, 32, 5);
  Midi(42, $B0, 121, 5);         // nor the channel mode messages
  Worst := Max(Worst, Both);
  Check((Plugin.LearningIndex = PBdDecay) and (Host.SetCalls = Calls), 'CC 0, 32 and 121 are not learned; it keeps waiting', '');
  Midi(10, $B0, 14, 100);
  ProcessPlugin(BlockSize);
  NumEvents := 0;
  Check((Plugin.LearningIndex = -1) and (Plugin.CcFor(PBdDecay) = 14), 'the first learnable CC is taken',
    Format('BASS DRUM DECAY: CC %d', [Plugin.CcFor(PBdDecay)]));
  Check(Host.SetCalls = Calls, 'and does nothing else (no parameter moved)', Format('%d set', [Host.SetCalls - Calls]));
  Check((Plugin.CcFor(PAccent) = -1) and MapIsSane(Plugin, Why), 'ACCENT gives CC 14 up: one control per CC', Why);

  // now CC 14 moves BASS DRUM DECAY, and CC 17 nothing
  Midi(10, $B0, 14, 30);
  Midi(20, $B0, 17, 127);
  ProcessPlugin(BlockSize);
  NumEvents := 0;
  Check(Host.Dirty[PBdDecay] and (Host.Requested[PBdDecay] = CcToValue(PBdDecay, 30)) and not Host.Dirty[PAccent],
    'the learned CC moves the control; the old one does nothing', Format('%.4f', [Host.Requested[PBdDecay]]));
  Deliver;

  // the mod wheel can be learned (the C++ learnable: 1 up)
  Plugin.Learn(PCyTone);
  Midi(0, $B0, 1, 64);
  ProcessPlugin(BlockSize);
  NumEvents := 0;
  Check(Plugin.CcFor(PCyTone) = 1, 'CC 1, the mod wheel, can be learned', Format('CC %d', [Plugin.CcFor(PCyTone)]));

  // cancel
  Plugin.Learn(PCbLevel);
  Plugin.Learn(-1);
  Midi(0, $B0, 29, 127);
  ProcessPlugin(BlockSize);
  NumEvents := 0;
  Check((Plugin.LearningIndex = -1) and (Plugin.CcFor(PCbLevel) = 29) and Host.Dirty[PCbLevel],
    'Cancel MIDI Learn: the CC goes where it went', '');
  Deliver;

  // forget, restore default (taking the CC back from whoever learned it), reset all
  Plugin.ForgetCc(PVolume);
  Check(Plugin.CcFor(PVolume) = -1, 'Forget CC', '');
  Plugin.Learn(PHtTuning);
  Midi(0, $B0, 7, 1);
  ProcessPlugin(BlockSize);
  NumEvents := 0;
  Check(Plugin.CcFor(PHtTuning) = 7, 'HI TOM TUNING learns VOLUME''s CC 7', '');
  Plugin.RestoreDefaultCc(PVolume);
  Check((Plugin.CcFor(PVolume) = 7) and (Plugin.CcFor(PHtTuning) = -1) and MapIsSane(Plugin, Why),
    'Restore default takes CC 7 back', Why);
  Plugin.Learn(PSdTone);
  Plugin.ResetAllCcs;
  Check(Plugin.LearningIndex = PSdTone, 'Reset all leaves learning alone', '');
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
    Result := (Plugin.CcFor(PCyDecay) = 20) and (Plugin.CcFor(PSdSnappy) = -1) and (Plugin.CcFor(PVolume) = -1);
  end;

begin
  Writeln;
  Writeln('the saved state: the CC map');

  StartPair;
  Plugin.Learn(PCyDecay);
  Midi(0, $B0, 20, 1);           // SNARE DRUM SNAPPY's
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
  Data := Copy(Saved); Data[2] := Ord('3'); Load(Data);                 // another plug-in's
  Data := Copy(Saved); Data[4] := 2; Load(Data);                        // a later version
  Data := Copy(Saved); Data[7] := 200; Load(Data);                      // entries beyond the data
  Data := Copy(Saved); Data[8] := 0; Load(Data);                        // an id of no length
  Data := Copy(Saved); Data[9] := Ord(' '); Load(Data);                 // an id that is not one
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
  // Changes the map and strikes pads from another thread while Process runs: the panel's side.
  TPanelThread = class(TThread)
  protected
    procedure Execute; override;
  public
    P: TMz808;
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
  Worst: Double;
  Changer: TPanelThread;
  Why: string;
begin
  Writeln;
  Writeln('the panel''s pads');

  StartPair;
  Worst := Both;
  // a pad plays from the top of the next block, as a note at sample 0
  Check(Plugin.Strike(VoiceSD, False), 'a pad is queued', '');
  RefPad(VoiceSD, False);
  Midi(100, $90, 36, 100);
  Worst := Max(Worst, Both);
  Check((Hits(VoiceSD) = 1) and (Hits(VoiceBD) = 1), 'it sounds, alongside the host''s notes, and lights',
    Format('SD %d, BD %d', [Hits(VoiceSD), Hits(VoiceBD)]));
  for B := 0 to 9 do
    Worst := Max(Worst, Both);
  // accented (shift-click, or ACCENT lit): velocity 127; and every pad, in one block
  for V := 0 to VoiceCount - 1 do
  begin
    Plugin.Strike(V, Odd(V));
    RefPad(V, Odd(V));
  end;
  for B := 0 to 39 do
    Worst := Max(Worst, Both);
  Check(Worst = 0, 'plain and accented, every pad: bit-identical to MIDI', Format('max diff %.3e', [Worst]));
  Check((Hits(VoiceCH) = 1) and (Hits(VoiceSD) = 2) and (Hits(VoiceMA) = 1), 'each pad''s hit counted', '');
  Check(not Plugin.Strike(-1, False) and not Plugin.Strike(VoiceCount, True) and not Plugin.QueueKey(128, 100),
    'voices and notes out of range are refused', '');
  for B := 1 to KeyQueueSize - 1 do
    Plugin.Strike(VoiceCB, False);
  Check(not Plugin.Strike(VoiceCB, False), 'a full queue refuses, it does not overwrite', '');
  ProcessPlugin(BlockSize);
  Check(Plugin.Strike(VoiceCB, False) and (Hits(VoiceCB) = KeyQueueSize), 'and takes pads again once a block has run',
    Format('CB %d', [Hits(VoiceCB)]));
  // prepare drops the pads waiting, as the C++ padState.reset()
  VT.Prepare(Inst, Rate, BlockSize);
  ProcessPlugin(BlockSize);
  Check(Plugin.Engine.HitCount(VoiceCB) = KeyQueueSize, 'prepare drops the pads still waiting', '');
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

// The panel, as the layout builds it, without a window. Its coordinates are the C++
// Panel::resized()'s (and editor_check.cpp's).
procedure PanelChecks;
const
  // the pads' columns: x of the column, and of each pad in it (C++: centred, 38 wide, 6 apart)
  PadX: array[0..VoiceCount - 1] of Integer = (
    112 + 27, 210 + 27, 308 + 5, 308 + 49, 406 + 5, 406 + 49, 504 + 5, 504 + 49,
    602 + 5, 602 + 49, 700 + 5, 700 + 49, 798 + 27, 896 + 27, 994 + 27, 1092 + 27);
  // each knob's column, in Specs order
  KnobCol: array[0..NumSpecs - 1] of Integer = (0, 1, 1, 1, 2, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 9, 9, 10, 10, 11, 12);
  KnobRow: array[0..NumSpecs - 1] of Integer = (0, 0, 1, 2, 0, 1, 2, 0, 1, 0, 1, 0, 1, 0, 0, 0, 0, 1, 2, 0, 1, 0, 0);
var
  Ed: TPanelProbe;
  I, V, Bad, BadPads: Integer;
  C: TJuceControl;
  Worst: Double;
  Where: string;
begin
  Writeln;
  Writeln('the panel (the layout, without a window)');

  StartPair;
  Ed := TPanelProbe.Create(Plugin);
  try
    Check((Ed.Width = 1296) and (Ed.Height = 500), 'the C++ panel''s size', Format('%d x %d', [Ed.Width, Ed.Height]));
    Bad := 0;
    Where := '';
    for I := 0 to NumSpecs - 1 do
    begin
      C := Ed.SpecControl(I);
      if not (C is TJuceKnob) or (Round(C.AbsoluteX) <> 14 + 98 * KnobCol[I] + 13)
        or (Round(C.AbsoluteY) <> 62 + 44 + 84 * KnobRow[I]) or (C.Width <> 66) or (C.Height <> 66) then
      begin
        Inc(Bad);
        Where := Where + Specs[I].Id + ' ';
      end;
    end;
    Check(Bad = 0, 'every knob bound, where the C++ PanelKnob has it', Where);
    BadPads := 0;
    Where := '';
    for V := 0 to VoiceCount - 1 do
      if (Ed.Pad(V) = nil) or (Ed.PadLight(V) = nil) or (Round(Ed.Pad(V).AbsoluteX) <> PadX[V])
        or (Round(Ed.Pad(V).AbsoluteY) <> 62 + 312 + 14) or (Ed.Pad(V).Width <> 38) or (Ed.Pad(V).Height <> 56)
        or (Round(Ed.PadLight(V).AbsoluteX) <> PadX[V] + 15) or (Round(Ed.PadLight(V).AbsoluteY) <> 62 + 313)
        or (Ed.Pad(V).Mode <> jbmMomentary) or (Pos(UpperCase(VoiceInfo(V).Name), Ed.Pad(V).Hint) <> 1) then
      begin
        Inc(BadPads);
        Where := Where + VoiceInfo(V).Code + ' ';
      end;
    Check(BadPads = 0, 'every pad and its light, where the C++ Pad has them', Where);
    C := Ed.FindControl('AccentButton');
    Check((C is TJuceButton) and (Round(C.AbsoluteX) = 24) and (Round(C.AbsoluteY) = 396) and (C.Width = 72)
      and (C.Height = 40) and (TJuceButton(C).Mode = jbmToggle), 'ACCENT, a latching button under its knob', '');
    C := Ed.FindControl('PatchBox');
    Check((C is TJuceComboBox) and (TJuceComboBox(C).ParameterId = 'patch') and (C.Left = 1062),
      'the kit menu is the Patch parameter', '');
    C := Ed.FindControl('ProjectLink');
    Check((C is TJuceLink) and (C.Caption = 'Mz808_Pascal 0.3.0  -  github.com/simozzer/Mz808')
      and (TJuceLink(C).Url = 'https://github.com/simozzer/Mz808'), 'the project line', C.Caption);
    Check(Ed.SpecControl(PBdTone).Hint = HintFor(PBdTone, 16, False), 'knob hints name the CC',
      StringReplace(Ed.SpecControl(PBdTone).Hint, #10, ' | ', [rfReplaceAll]));

    // a press plays the pad, a release nothing more; shift, or ACCENT lit, accents it
    Worst := 0;
    Ed.Mouse(JCP_MOUSE_DOWN, PadX[VoiceBD] + 19, 62 + 312 + 14 + 28, JCP_MOD_LEFT);
    RefPad(VoiceBD, False);
    Ed.Mouse(JCP_MOUSE_UP, PadX[VoiceBD] + 19, 62 + 312 + 14 + 28, 0);
    Worst := Max(Worst, Both);
    Check(Hits(VoiceBD) = 1, 'a click on the BD pad strikes the bass drum, once', Format('BD %d', [Hits(VoiceBD)]));
    // the code and note on the pad do not take the click
    Ed.Mouse(JCP_MOUSE_DOWN, PadX[VoiceCL] + 19, 62 + 312 + 15 + 8 + 9, JCP_MOD_LEFT or JCP_MOD_SHIFT);
    RefPad(VoiceCL, True);
    Ed.Mouse(JCP_MOUSE_UP, PadX[VoiceCL] + 19, 62 + 312 + 15 + 8 + 9, 0);
    Ed.Mouse(JCP_MOUSE_DOWN, PadX[VoiceCH] + 19, 62 + 312 + 15 + 54 - 12, JCP_MOD_LEFT);
    RefPad(VoiceCH, False);
    Ed.Mouse(JCP_MOUSE_UP, PadX[VoiceCH] + 19, 62 + 312 + 15 + 54 - 12, 0);
    Worst := Max(Worst, Both);
    Check((Hits(VoiceCL) = 1) and (Hits(VoiceCH) = 1), 'through the code and the note printed on a pad, too', '');
    Ed.Mouse(JCP_MOUSE_DOWN, 60, 416, JCP_MOD_LEFT);       // ACCENT
    Ed.Mouse(JCP_MOUSE_UP, 60, 416, 0);
    Check(Ed.AccentLit, 'a click lights ACCENT', '');
    Ed.Mouse(JCP_MOUSE_DOWN, PadX[VoiceSD] + 19, 62 + 312 + 14 + 28, JCP_MOD_LEFT);
    RefPad(VoiceSD, True);
    Ed.Mouse(JCP_MOUSE_UP, PadX[VoiceSD] + 19, 62 + 312 + 14 + 28, 0);
    Ed.Mouse(JCP_MOUSE_DOWN, 60, 416, JCP_MOD_LEFT);
    Ed.Mouse(JCP_MOUSE_UP, 60, 416, 0);
    Ed.Mouse(JCP_MOUSE_DOWN, PadX[VoiceSD] + 19, 62 + 312 + 14 + 28, JCP_MOD_LEFT);
    RefPad(VoiceSD, False);
    Ed.Mouse(JCP_MOUSE_UP, PadX[VoiceSD] + 19, 62 + 312 + 14 + 28, 0);
    for I := 0 to 39 do
      Worst := Max(Worst, Both);
    Check(not Ed.AccentLit and (Hits(VoiceSD) = 2), 'ACCENT lit, then not: the snare accented, then plain', '');
    Check(Worst = 0, 'shift-click and ACCENT accent the hit: bit-identical to MIDI', Format('max diff %.3e', [Worst]));
    // a right-click on a pad does nothing (the C++ Pad ignores the popup button)
    Ed.Mouse(JCP_MOUSE_DOWN, PadX[VoiceMA] + 19, 62 + 312 + 14 + 28, JCP_MOD_RIGHT or JCP_MOD_POPUP);
    Ed.Mouse(JCP_MOUSE_UP, PadX[VoiceMA] + 19, 62 + 312 + 14 + 28, 0);
    Both;
    Check(Hits(VoiceMA) = 0, 'a right-click on a pad plays nothing', '');
  finally
    Ed.Free;
  end;
  Check(Plugin.ProcessErrors = 0, 'no exceptions in Process', '');
  EndPair;
end;

begin
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  Writeln('Mz808_Pascal plug-in check');

  RegisterMz808;
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
  PanelChecks;

  Writeln;
  if Failures = 0 then
    Writeln('all checks passed')
  else
    Writeln(Failures, ' FAILED');
  if Failures <> 0 then
    ExitCode := 1;
end.
