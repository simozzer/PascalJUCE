// Mz101 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Checks of the plug-in layer (Mz101Plugin), through the library's real entry point
// with a fake host: the parameter declarations, MIDI and the CC map, MIDI learn, the Patch
// parameter, the momentary buttons, the panel's buttons and keyboard, and the saved state
// (the sequence and the CC map) - including hostile state.
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
  Sh101Settings, Sh101Engine, Mz101Params, Mz101Presets, Mz101Plugin;

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
  RefHostAvailable, RefHostPlaying: Boolean;
  RefPpq, RefBpm: Double;
  RefPanelKey: Integer = -1;    // a key from the panel: + 128 for down, played at the top

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

function Plugin: TMz101;
begin
  Result := TMz101(Inst);
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
    Ref.NoteOn(D1)
  else if (Status = $80) or (Status = $90) then
    Ref.NoteOff(D1)
  else if Status = $E0 then
  begin
    V := (D1 or (D2 shl 7)) - 8192;
    Ref.SetPitchBend(V / 8192);
  end
  else if (Status = $B0) and (D1 = 1) then
  begin
    V := D2;
    Ref.SetModLever(V / 127);
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
  Ref.SetHostClock(RefHostAvailable, RefHostPlaying, RefPpq, RefBpm);
  if RefPanelKey >= 128 then
    Ref.NoteOn(RefPanelKey - 128)
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
  RefHostAvailable := False;
  RefHostPlaying := False;
  RefPpq := 0;
  RefBpm := 120;
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
  Kinds[skSlider] := Ord(jpkFloat);
  Kinds[skSwitch] := Ord(jpkChoice);
  Kinds[skButton] := Ord(jpkBool);

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
  Check((string(Info.Id) = 'patch') and (Info.MaxValue = NumPresets - 1), 'Patch: a choice of the 10 factory patches', string(Info.Id));
end;

procedure TextChecks;
var
  Buf: array[0..63] of AnsiChar;
  R1, R2, R3: Integer;
  T1, T2: string;
begin
  Writeln;
  Writeln('display text');
  R1 := VT.GetParameterText(Inst, PCutoff, 6, @Buf[0], Length(Buf));
  T1 := string(PAnsiChar(@Buf[0]));
  R2 := VT.GetParameterText(Inst, PTune, -12.34, @Buf[0], Length(Buf));
  T2 := string(PAnsiChar(@Buf[0]));
  R3 := VT.GetParameterText(Inst, PRange, 1, @Buf[0], Length(Buf));
  Check((R1 = 1) and (T1 = '6.0') and (R2 = 1) and (T2 = '-12.3'), 'sliders show one decimal place', T1 + ', ' + T2);
  Check(R3 = 0, 'switches show their position names (host default)', '');
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
  Midi(10, $90, 48, 100);
  Worst := Max(Worst, Both);
  for B := 1 to 20 do
  begin
    if B = 3 then Midi(77, $91, 55, 1);        // channel 2: all channels play
    if B = 5 then Midi(0, $E0, 0, 96);          // bend up
    if B = 6 then Midi(200, $B0, 1, 100);       // mod lever
    if B = 8 then Midi(128, $90, 55, 0);        // note-on velocity 0 is a note-off
    if B = 9 then Midi(3, $E0, 0, 64);          // centre
    if B = 12 then
    begin
      Midi(50, $80, 48, 0);
      Midi(50, $90, 60, 90);                    // two events on one sample
    end;
    if B = 15 then Midi(255, $80, 60, 0);
    Worst := Max(Worst, Both);
  end;
  Check(Worst = 0, 'notes, bend, mod lever: bit-identical, L = R', Format('max diff %.3e', [Worst]));
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

  // CC 74 is VCF Freq: it moves the parameter, and the sound from this sample.
  Midi(100, $B0, 74, 30);
  Worst := Max(Worst, Both);
  Expect := CcToValue(PCutoff, 30);
  Check(Host.Dirty[PCutoff] and (Host.Requested[PCutoff] = Expect), 'CC 74 sets VCF Freq through the host',
    Format('%.4f (%.4f)', [Host.Requested[PCutoff], Expect]));

  // The host has not reported it back yet: the engine must keep the CC's value.
  for B := 0 to 5 do
    Worst := Max(Worst, Both);
  Deliver;
  for B := 0 to 5 do
    Worst := Max(Worst, Both);
  Check(Worst = 0, 'takes effect at its sample, and stays while the host catches up', Format('max diff %.3e', [Worst]));

  // a switch: CC 15 (VCO Range) at 127 is 2'; CC 64 is HOLD
  Midi(5, $B0, 15, 127);
  Midi(9, $B0, 64, 127);
  Worst := Max(Worst, Both);
  Check((Host.Requested[PRange] = RangeFeet2) and (Host.Requested[PArpHold] = 1), 'a switch takes the nearest position; CC 64 is HOLD',
    Format('range %.0f, hold %.0f', [Host.Requested[PRange], Host.Requested[PArpHold]]));
  Check(Host.GestureDepth = 0, 'gestures balanced', Format('%d open', [Host.GestureDepth]));

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

  // Choose 'Acid Line': applied once the choice has settled (50 ms), not before.
  Host.Params[PPatch] := 2;
  Applied := -1;
  PresetValuesOf(2, Values);
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

procedure ButtonChecks;
var
  B: Integer;
begin
  Writeln;
  Writeln('the momentary buttons');

  StartPair;
  Both;
  Host.Params[PKeyTranspose] := 1;   // pressed, and the host is slow to switch it back
  for B := 0 to 9 do
    Both;
  Check(Plugin.Engine.KeyTransposeArmed, 'KEY TRANSPOSE: one press, however long it reads on', '');
  Check(Host.Dirty[PKeyTranspose] and (Host.Requested[PKeyTranspose] = 0), 'and the plug-in switches it back off', '');
  Deliver;
  Both;
  Host.Params[PKeyTranspose] := 1;   // a second click
  for B := 0 to 4 do
    Both;
  Check(not Plugin.Engine.KeyTransposeArmed, 'a second click is a second press (disarms)', '');
  Deliver;

  // LEGATO only means something in LOAD
  Host.Params[PSeqMode] := SeqLoad;
  Both;
  Host.Params[PLegato] := 1;
  for B := 0 to 4 do
    Both;
  Check(Plugin.Engine.SeqLegatoArmed, 'LEGATO arms a tie in LOAD', '');
  Check(Host.GestureDepth = 0, 'gestures balanced', '');
  EndPair;
end;

var
  StateBytes: TBytes;

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

function SequenceText(E: TEngine): string;
var
  I: Integer;
  St: UInt32;
begin
  Result := '';
  for I := 0 to E.SeqLength - 1 do
  begin
    St := E.SeqStep(I);
    if (St and StepRest) <> 0 then
      Result := Result + 'rest'
    else
      Result := Result + IntToStr(St and StepNoteMask);
    if (St and StepTie) <> 0 then
      Result := Result + '~';
    Result := Result + ' ';
  end;
end;

procedure StateChecks;
var
  B, I, Exceptions, Bad, Run, N: Integer;
  Saved, Seq: string;
  Data: TBytes;
  Seed: UInt32;

  function NextRandom: UInt32;
  begin
    Seed := Seed xor UInt32(Seed shl 13);
    Seed := Seed xor (Seed shr 17);
    Seed := Seed xor UInt32(Seed shl 5);
    Result := Seed;
  end;

  procedure Load(const D: TBytes);
  begin
    try
      Plugin.LoadState(D);
    except
      Inc(Exceptions);
    end;
  end;

begin
  Writeln;
  Writeln('the sequence in the saved state');

  StartPair;
  // record C, rest, E~ (overlapping), G through MIDI and the REST button
  Host.Params[PSeqMode] := SeqLoad;
  Both;
  Midi(0, $90, 60, 100); Both; Both; Midi(0, $80, 60, 0); Both; Both;
  Host.Params[PKeyTranspose] := 1; Both; Both; Deliver; Both;
  Midi(0, $90, 62, 100); Both; Both; Midi(0, $90, 64, 100); Both; Both;
  Midi(0, $80, 62, 0); Midi(0, $80, 64, 0); Both; Both;
  Midi(0, $90, 67, 100); Both; Both; Midi(0, $80, 67, 0); Both; Both;
  Saved := SequenceText(Plugin.Engine);
  Check(Saved = '60 rest 62 64~ 67 ', 'recorded through MIDI and the REST button', Saved);

  StateBytes := nil;
  VT.GetState(Inst, StateWriter, nil);
  Check(Length(StateBytes) = 6 + 4 * 5 + MapBytes, 'saved: header, 5 steps and the CC map', Format('%d bytes', [Length(StateBytes)]));
  EndPair;

  // Reopen, as saved mid-recording: LOAD would wipe it, so it comes back at OFF.
  StartPair;
  Host.Params[PSeqMode] := SeqLoad;
  VT.SetState(Inst, @StateBytes[0], Length(StateBytes));
  Check(Host.Dirty[PSeqMode] and (Host.Requested[PSeqMode] = SeqOff), 'a project saved in LOAD reopens at OFF', '');
  for B := 0 to 9 do
    ProcessPlugin(BlockSize);     // the host has not reported OFF back yet
  Seq := SequenceText(Plugin.Engine);
  Check(Seq = Saved, 'the sequence survives reopening', Seq);

  // Hostile state: never an exception, never a step outside note/REST/TIE, never more
  // than 100; damaged data leaves the sequence as it was.
  Exceptions := 0;
  Bad := 0;
  Data := Copy(StateBytes);
  SetLength(Data, Length(Data) - 1);   Load(Data);  // truncated
  Data := Copy(StateBytes);
  SetLength(Data, Length(Data) + 1);   Load(Data);  // trailing byte
  Data := Copy(StateBytes); Data[0] := Ord('X'); Load(Data);   // magic
  Data := Copy(StateBytes); Data[4] := 3; Load(Data);          // a later version
  Data := Copy(StateBytes); Data[5] := 101; Load(Data);        // count beyond the sequencer
  Data := Copy(StateBytes); Data[5] := 255; Load(Data);
  SetLength(Data, 3); Load(Data);
  Seq := SequenceText(Plugin.Engine);
  Check((Seq = Saved) and (Exceptions = 0), 'damaged state is refused; the sequence stays', Seq);

  Seed := 2463534242;
  for Run := 0 to 19999 do
  begin
    if Run mod 2 = 0 then
    begin
      Data := Copy(StateBytes);       // a valid state, mutated
      for I := 0 to Integer(NextRandom mod 4) do
        Data[NextRandom mod UInt32(Length(Data))] := NextRandom and $FF;
      if NextRandom mod 3 = 0 then
      begin
        N := 6 + 4 * Integer(NextRandom mod 101);
        Data[5] := (N - 6) div 4;
        SetLength(Data, N);
        for I := Length(StateBytes) to N - 1 do
          Data[I] := NextRandom and $FF;
      end;
    end
    else
    begin
      SetLength(Data, NextRandom mod 600);
      for I := 0 to High(Data) do
        Data[I] := NextRandom and $FF;
    end;
    Load(Data);
    if Plugin.Engine.SeqLength > MaxSteps then
      Inc(Bad);
    for I := 0 to Plugin.Engine.SeqLength - 1 do
      if (Plugin.Engine.SeqStep(I) and not (StepNoteMask or StepRest or StepTie)) <> 0 then
        Inc(Bad);
  end;
  Check((Exceptions = 0) and (Bad = 0), '20000 random and mutated states', Format('%d exceptions, %d bad steps', [Exceptions, Bad]));

  for B := 0 to 3 do
    ProcessPlugin(BlockSize);
  VT.SetState(Inst, nil, 0);
  Check(Plugin.Engine.SeqLength = 0, 'a project without a sequence has none', '');
  Check(Plugin.ProcessErrors = 0, 'no exceptions in Process', '');
  EndPair;
end;

procedure HostClockChecks;
var
  B: Integer;
  Worst: Double;
begin
  Writeln;
  Writeln('the host clock');

  StartPair;
  Host.Params[PArpMode] := ArpUp;
  Host.Params[PClockSource] := ClockHost;
  RefSettings.ArpMode := ArpUp;
  RefSettings.ClockSource := ClockHost;
  Transport.HasInfo := 1;
  Transport.IsPlaying := 1;
  Transport.Bpm := 132;
  RefHostAvailable := True;
  RefHostPlaying := True;
  RefBpm := 132;
  Worst := 0;
  Midi(0, $90, 60, 100);
  Midi(0, $90, 63, 100);
  Midi(0, $90, 67, 100);
  for B := 0 to 299 do
  begin
    if B = 200 then
    begin
      Transport.IsPlaying := 0;            // stop, then jump
      RefHostPlaying := False;
    end;
    if B = 230 then
    begin
      Transport.IsPlaying := 1;
      Transport.PpqPosition := 33.5;
      RefHostPlaying := True;
    end;
    RefPpq := Transport.PpqPosition;
    Worst := Max(Worst, Both);
    if Transport.IsPlaying <> 0 then
      Transport.PpqPosition := Transport.PpqPosition + 132 / 60.0 * BlockSize / Rate;
  end;
  Check(Worst = 0, 'arpeggio on the host''s grid, through stop and a jump', Format('max diff %.3e', [Worst]));

  // no timeline: HasInfo = 0 is the standalone app
  Transport.HasInfo := 0;
  RefHostAvailable := False;
  RefHostPlaying := False;
  RefPpq := 0;
  RefBpm := 120;
  for B := 0 to 49 do
    Worst := Max(Worst, Both);
  Check(Worst = 0, 'and without one, on the modulator', Format('max diff %.3e', [Worst]));
  EndPair;
end;

{ ---- MIDI learn, its state, and the panel's input ---- }

// Every CC is none or learnable, and no CC drives two controls.
function MapIsSane(P: TMz101; out Why: string): Boolean;
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

function MapIsDefault(P: TMz101): Boolean;
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

  // VCF Freq learns CC 20 (Sub Level's): the CC is taken and does nothing else
  Version := Plugin.MidiMapVersion;
  Plugin.Learn(PCutoff);
  Check((Plugin.LearningIndex = PCutoff) and (Plugin.MidiMapVersion <> Version), 'MIDI Learn: the control waits', '');
  Calls := Host.SetCalls;
  Midi(40, $B0, 1, 90);          // the mod lever is not learnable: it moves the lever
  Midi(41, $B0, 0, 5);           // bank select is not learnable
  Midi(42, $B0, 32, 5);
  Worst := Max(Worst, Both);
  Check((Plugin.LearningIndex = PCutoff) and (Host.SetCalls = Calls), 'CC 1, 0 and 32 are not learned; it keeps waiting', '');
  Midi(10, $B0, 20, 100);
  ProcessPlugin(BlockSize);
  NumEvents := 0;
  Check((Plugin.LearningIndex = -1) and (Plugin.CcFor(PCutoff) = 20), 'the first learnable CC is taken',
    Format('VCF Freq: CC %d', [Plugin.CcFor(PCutoff)]));
  Check(Host.SetCalls = Calls, 'and does nothing else (no parameter moved)', Format('%d set', [Host.SetCalls - Calls]));
  Check((Plugin.CcFor(PSub) = -1) and MapIsSane(Plugin, Why), 'Sub Level gives CC 20 up: one control per CC', Why);

  // now CC 20 moves VCF Freq, and CC 74 nothing
  Midi(10, $B0, 20, 30);
  Midi(20, $B0, 74, 127);
  ProcessPlugin(BlockSize);
  NumEvents := 0;
  Check(Host.Dirty[PCutoff] and (Host.Requested[PCutoff] = CcToValue(PCutoff, 30)) and not Host.Dirty[PSub],
    'the learned CC moves the control', Format('%.4f', [Host.Requested[PCutoff]]));
  Check(Host.Requested[PCutoff] = CcToValue(PCutoff, 30), 'the old CC does nothing', '');
  Deliver;

  // one CC per control: VCF Freq learns again, and lets CC 20 go
  Plugin.Learn(PCutoff);
  Midi(0, $B0, 50, 64);
  ProcessPlugin(BlockSize);
  NumEvents := 0;
  Check((Plugin.CcFor(PCutoff) = 50) and MapIsSane(Plugin, Why), 'learning again replaces the control''s CC', Why);

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
  Check(Plugin.CcFor(PTune) = 7, 'Tune learns Volume''s CC 7', '');
  Plugin.RestoreDefaultCc(PVolume);
  Check((Plugin.CcFor(PVolume) = 7) and (Plugin.CcFor(PTune) = -1) and MapIsSane(Plugin, Why),
    'Restore default takes CC 7 back', Why);
  Plugin.RestoreDefaultCc(PTune);
  Plugin.Learn(PRes);
  Plugin.ResetAllCcs;
  Check(Plugin.CcFor(PTune) = 105, 'Restore default', '');
  Check(Plugin.LearningIndex = PRes, 'Reset all leaves learning alone', '');
  Plugin.Learn(-1);
  Check(MapIsDefault(Plugin), 'Reset all CCs to defaults', '');
  Check(Host.GestureDepth = 0, 'gestures balanced', '');
  Check(Plugin.ProcessErrors = 0, 'no exceptions in Process', '');
  EndPair;
end;

// The previous build's LoadState parsing (version 1 only), as it was: what it makes of a
// state from this build. Compiled with range checks, so an out-of-bounds read raises.
function OldParse(const Data: TBytes; out N: Integer): Boolean;
const
  OldVersion = 1;
var
  I: Integer;
begin
  N := 0;
  Result := (Length(Data) >= 6) and (Data[4] = OldVersion);
  for I := 0 to 3 do
    if Result and (Data[I] <> Ord('MzSq'[I + 1])) then
      Result := False;
  if Result then
  begin
    N := Data[5];
    Result := (N <= MaxSteps) and (Length(Data) = 6 + 4 * N);
  end;
end;

procedure LearnStateChecks;
var
  Saved, Old, Data: TBytes;
  Why, Seq: string;
  I, N, Run, Exceptions, Bad: Integer;
  Seed: UInt32;

  function NextRandom: UInt32;
  begin
    Seed := Seed xor UInt32(Seed shl 13);
    Seed := Seed xor (Seed shr 17);
    Seed := Seed xor UInt32(Seed shl 5);
    Result := Seed;
  end;

  procedure Load(const D: TBytes);
  begin
    try
      Plugin.LoadState(D);
    except
      Inc(Exceptions);
    end;
  end;

begin
  Writeln;
  Writeln('the CC map in the saved state');

  // learn two, forget one, record a step; save
  StartPair;
  Host.Params[PSeqMode] := SeqLoad;
  Both;
  Midi(0, $90, 62, 100); Both; Midi(0, $80, 62, 0); Both;
  Host.Params[PSeqMode] := SeqOff;
  Both;
  Plugin.Learn(PCutoff);
  Midi(0, $B0, 20, 1);
  Both;
  Plugin.ForgetCc(PVolume);
  Plugin.Learn(PAttack);            // learning is not saved
  Saved := Plugin.SaveState;
  Check((Length(Saved) = 6 + 4 + MapBytes) and (Saved[4] = 2), 'saved as version 2: the step and the map',
    Format('%d bytes', [Length(Saved)]));
  EndPair;

  StartPair;
  Plugin.LoadState(Saved);
  Check((Plugin.CcFor(PCutoff) = 20) and (Plugin.CcFor(PSub) = -1) and (Plugin.CcFor(PVolume) = -1)
    and (Plugin.CcFor(PRes) = 71) and (Plugin.LearningIndex = -1) and MapIsSane(Plugin, Why),
    'reopened: learned, given up and forgotten CCs come back; not learning', Why);
  Seq := SequenceText(Plugin.Engine);
  Check(Seq = '62 ', 'and the sequence', Seq);

  // a project saved by the builds whose panel had a scope: version 3, the same with the
  // scope's TIME (20 ms) after the map - loads, the time ignored
  Data := Copy(Saved);
  Data[4] := 3;
  SetLength(Data, Length(Data) + 6);
  Data[High(Data) - 5] := Ord('S'); Data[High(Data) - 4] := Ord('T');
  Data[High(Data) - 3] := 0; Data[High(Data) - 2] := 0; Data[High(Data) - 1] := $A0; Data[High(Data)] := $41;
  Plugin.LoadState(nil);   // none: the defaults
  Plugin.LoadState(Data);
  Check((Plugin.CcFor(PCutoff) = 20) and (Plugin.CcFor(PVolume) = -1) and (SequenceText(Plugin.Engine) = '62 '),
    'a version 3 state (with a scope time) still loads: sequence and map', '');
  Plugin.LoadState(nil);   // none: the defaults
  Data[High(Data) - 5] := Ord('X');
  Plugin.LoadState(Data);
  Check(MapIsDefault(Plugin), 'and a damaged one is refused', '');
  Plugin.LoadState(Saved);

  // a project from before MIDI learn: version 1, the same sequence
  Old := Copy(Saved, 0, 6 + 4);
  Old[4] := 1;
  Plugin.LoadState(Old);
  Seq := SequenceText(Plugin.Engine);
  Check(MapIsDefault(Plugin) and (Seq = '62 '), 'a version 1 state loads with the default CCs', Seq);

  // and the other way: the previous build's parser, given this build's state
  Exceptions := 0;
  try
    Check(not OldParse(Saved, N), 'the previous build refuses a version 2 state (keeps its sequence)', '');
  except
    Inc(Exceptions);
  end;
  Check(OldParse(Old, N) and (N = 1), 'and still reads a version 1 state', '');

  // hostile map data: never an exception, never a map that breaks the rules; damaged
  // data leaves the map as it was
  Plugin.LoadState(Saved);
  Data := Copy(Saved);
  SetLength(Data, Length(Data) - 1);
  Load(Data);                                                       // truncated
  Data := Copy(Saved);
  SetLength(Data, Length(Data) + 1);
  Load(Data);                                                       // trailing byte
  Data := Copy(Saved); Data[6 + 4] := Ord('X'); Load(Data);        // map magic
  Data := Copy(Saved); Data[6 + 4 + 2] := 200; Load(Data);         // too many entries
  Data := Copy(Saved); Data[6 + 4 + 3] := 0; Load(Data);           // an empty id
  Data := Copy(Saved); Data[6 + 4 + 3] := 250; Load(Data);         // a long id
  Data := Copy(Saved); Data[6 + 4 + 4] := Ord(' '); Load(Data);    // a bad character
  Check((Exceptions = 0) and (Plugin.CcFor(PCutoff) = 20) and (Plugin.CcFor(PVolume) = -1)
    and (SequenceText(Plugin.Engine) = '62 '), 'damaged maps are refused; map and sequence stay', '');

  // well-formed, with things this build would not take: skipped
  Data := Copy(Saved);
  I := 6 + 4 + 3;                     // the first entry: lfoRate
  Data[I + 1] := Ord('X');            // an id this build does not know
  Load(Data);
  Check((Exceptions = 0) and (Plugin.CcFor(PLfoRate) = Specs[PLfoRate].Cc) and (Plugin.CcFor(PCutoff) = 20),
    'an unknown id is skipped (its control keeps the default)', '');
  Data := Copy(Saved);
  Data[I + 1 + Length(Specs[0].Id)] := 120;   // a CC that is not learnable
  Load(Data);
  Check((Exceptions = 0) and (Plugin.CcFor(PLfoRate) = Specs[PLfoRate].Cc), 'a CC that is not learnable is skipped', '');
  Data := Copy(Saved);
  Data[I + 1 + Length(Specs[0].Id)] := 74;    // VCF Freq's default, twice
  Load(Data);
  Check((Exceptions = 0) and MapIsSane(Plugin, Why), 'a CC given twice still drives one control', Why);

  Seed := 88172645;
  Bad := 0;
  for Run := 0 to 19999 do
  begin
    Data := Copy(Saved);
    for I := 0 to Integer(NextRandom mod 4) do
      Data[6 + 4 + Integer(NextRandom mod UInt32(MapBytes))] := NextRandom and $FF;
    if NextRandom mod 4 = 0 then
      SetLength(Data, Integer(NextRandom mod UInt32(Length(Data) + 8)));
    Load(Data);
    if not MapIsSane(Plugin, Why) then
      Inc(Bad);
    try
      OldParse(Data, N);
    except
      Inc(Exceptions);
    end;
  end;
  Check((Exceptions = 0) and (Bad = 0), '20000 mutated maps, here and in the previous parser',
    Format('%d exceptions, %d broken maps', [Exceptions, Bad]));
  EndPair;
end;

type
  // Changes the map from another thread while Process runs: the panel's side.
  TMapChanger = class(TThread)
  protected
    procedure Execute; override;
  public
    P: TMz101;
    Changes: Integer;
  end;

procedure TMapChanger.Execute;
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
    P.PressKeyTranspose;
    P.QueueKey(40 + I mod 30, I mod 2 = 0);
    Inc(I);
    Inc(Changes);
  end;
end;

procedure PanelChecks;
var
  B, Calls: Integer;
  Worst: Double;
  Changer: TMapChanger;
  Why: string;
begin
  Writeln;
  Writeln('the panel''s buttons and keyboard');

  StartPair;
  Worst := Both;
  // a key from the panel plays from the top of the next block, as MIDI at sample 0
  Check(Plugin.QueueKey(48, True), 'a key down is queued', '');
  RefPanelKey := 48 + 128;
  for B := 0 to 9 do
    Worst := Max(Worst, Both);
  Check(Plugin.Engine.GateIsOn and (Host.Meters[MeterKeysHeld + 3] = 1), 'it sounds, and the key shows as held',
    Format('keys %g', [Host.Meters[MeterKeysHeld + 3]]));
  Plugin.QueueKey(48, False);
  RefPanelKey := 48;
  for B := 0 to 9 do
    Worst := Max(Worst, Both);
  Check((Worst = 0) and (Host.Meters[MeterKeysHeld + 3] = 0), 'and lets go: bit-identical to MIDI', Format('max diff %.3e', [Worst]));
  Check(not Plugin.QueueKey(128, True) and not Plugin.QueueKey(-1, True), 'notes out of range are refused', '');
  for B := 1 to KeyQueueSize - 1 do
    Plugin.QueueKey(60, B mod 2 = 1);
  Check(not Plugin.QueueKey(60, True), 'a full queue refuses, it does not overwrite', '');
  ProcessPlugin(BlockSize);
  Check(Plugin.QueueKey(60, False), 'and takes keys again once a block has run', '');
  ProcessPlugin(BlockSize);

  // the buttons: one press each, however many before a block
  Calls := Host.SetCalls;
  Plugin.PressKeyTranspose;
  ProcessPlugin(BlockSize);
  Check(Plugin.Engine.KeyTransposeArmed and (Host.Meters[MeterTransposeArmed] = 1),
    'TRANS/REST from the panel arms KEY TRANSPOSE, and its LED shows it', '');
  Plugin.PressKeyTranspose;
  Plugin.PressKeyTranspose;
  ProcessPlugin(BlockSize);
  Check(Plugin.Engine.KeyTransposeArmed and (Host.SetCalls = Calls), 'two presses in one block are two (no parameter moved)', '');
  Plugin.PressKeyTranspose;
  ProcessPlugin(BlockSize);
  Check(not Plugin.Engine.KeyTransposeArmed and (Host.Meters[MeterTransposeArmed] = 0), 'and another disarms it', '');
  Host.Params[PSeqMode] := SeqLoad;
  ProcessPlugin(BlockSize);
  Plugin.PressLegato;
  ProcessPlugin(BlockSize);
  Check(Plugin.Engine.SeqLegatoArmed and (Host.Meters[MeterLegatoArmed] = 1), 'LEGATO from the panel, and its LED', '');
  Midi(0, $90, 60, 100);
  ProcessPlugin(BlockSize);
  NumEvents := 0;
  Check(Host.Meters[MeterSeqLength] = Plugin.Engine.SeqLength, 'the step count is published for the readout',
    Format('%g', [Host.Meters[MeterSeqLength]]));
  Midi(0, $80, 60, 0);
  Midi(1, $B0, 123, 0);
  ProcessPlugin(BlockSize);
  NumEvents := 0;
  Check(Host.Meters[MeterKeysHeld + 3] = 0, 'all notes off clears the keys shown', '');
  Host.Params[PSeqMode] := SeqOff;
  ProcessPlugin(BlockSize);
  EndPair;

  // the hand-off under load: the panel's thread changes the map, presses and plays while
  // Process runs with CCs (lock-free: nothing here may block or corrupt the other side)
  StartPair;
  Changer := TMapChanger.Create(True);
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
  Writeln('Mz101_Pascal plug-in check');

  RegisterMz101;
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
  ButtonChecks;
  StateChecks;
  LearnChecks;
  LearnStateChecks;
  PanelChecks;
  HostClockChecks;

  Writeln;
  if Failures = 0 then
    Writeln('all checks passed')
  else
    Writeln(Failures, ' FAILED');
  if Failures <> 0 then
    ExitCode := 1;
end.
