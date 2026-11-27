// MzPCG - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Checks of the plug-in layer (MzPcgPlugin), through the library's real entry point with a
// fake host: the parameter declarations against the C++ Params.cpp, the value texts, the
// host's timeline (playing, stopped, none, a loop, a tempo change), mono and stereo, the
// step and the gain published for the panel, empty blocks, reset, and the state (there is
// none beyond the parameters; hostile state changes nothing). Audio is compared, bit for
// bit, with the engine driven directly as the C++ PluginProcessor drives it. And the panel
// as the layout builds it (MzPcgEditor, without a window): every stand-in swapped for the
// C++ panel's control, where the C++ editor lays it out, in its drawing order, with its
// hint; and the gain's picture, worked out when (and only when) the C++ works it out.
//
// Build with run-time checks: fpc -Mdelphi -Cr -Co -Ct -CR -gl -gh (see build_verify.cmd).
program PluginCheck;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  Classes, SysUtils, Math, JuceTypes, JucePlugin, JuceCanvas, JuceUI, JuceControls,
  PcfMath, PcfPatterns, PcfControls, PcgEngine, PcgControls, MzPcgParams, MzPcgPlugin, MzPcgEditor;

const
  Rate = 48000.0;
  BlockSize = 512;

type
  TFakeHost = record
    Params: array[0..NumParams - 1] of Single;
    Meters: array[0..63] of Single;
    SetCalls: Integer;
  end;
  PFakeHost = ^TFakeHost;

  // The C++ Params.cpp, as written there: what each parameter must be.
  TExpected = record
    Id, Name: string;
    Kind: TJuceParameterKind;
    Min, Max, Def: Single;
    Choices: string;
  end;

const
  Expected: array[0..NumParams - 1] of TExpected = (
    (Id: 'pattern'; Name: 'Pattern'; Kind: jpkInt; Min: 1; Max: 32; Def: 1; Choices: ''),
    (Id: 'mode'; Name: 'Mode'; Kind: jpkChoice; Min: 0; Max: 1; Def: 0; Choices: 'GATE|DUCK'),
    (Id: 'rate'; Name: 'Rate'; Kind: jpkChoice; Min: 0; Max: 2; Def: 1; Choices: '1/8|1/16|1/32'),
    (Id: 'depth'; Name: 'Depth'; Kind: jpkFloat; Min: 0; Max: 1; Def: 1; Choices: ''),
    (Id: 'attack'; Name: 'Attack'; Kind: jpkFloat; Min: 0; Max: 1; Def: 0.2; Choices: ''),
    (Id: 'hold'; Name: 'Hold'; Kind: jpkFloat; Min: 0; Max: 1; Def: 0.5; Choices: ''),
    (Id: 'decay'; Name: 'Decay'; Kind: jpkFloat; Min: 0; Max: 1; Def: 0.2; Choices: ''),
    (Id: 'mix'; Name: 'Mix'; Kind: jpkFloat; Min: 0; Max: 1; Def: 1; Choices: ''),
    (Id: 'level'; Name: 'Level'; Kind: jpkFloat; Min: -24; Max: 12; Def: 0; Choices: '')
  );

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
  NumChannels: Integer;
  UseTransport: Boolean;

  // the reference: the engine driven directly, as the C++ processBlock drives it
  Ref: TPcg;
  RefL, RefR: array[0..BlockSize - 1] of Single;
  Phase: Single;
  StateBytes: TBytes;
  StateCalls: Integer;

procedure Check(Ok: Boolean; const What, Detail: string);
const
  Verdict: array[Boolean] of string = ('FAIL', 'ok  ');
begin
  Writeln(Format('  %s  %-62s %s', [Verdict[Ok], What, Detail]));
  if not Ok then
    Inc(Failures);
end;

{ ---- the fake host ---- }

procedure HSetParam(H: PJcpHost; Index: Int32; Value: Single); cdecl;
begin
  Inc(PFakeHost(H)^.SetCalls);
end;

function HGetParam(H: PJcpHost; Index: Int32): Single; cdecl;
begin
  if (Index >= 0) and (Index < NumParams) then
    Result := PFakeHost(H)^.Params[Index]
  else
    Result := 0;
end;

procedure HGesture(H: PJcpHost; Index: Int32); cdecl;
begin
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

procedure ResetHost;
var
  I: Integer;
begin
  FillChar(Host, SizeOf(Host), 0);
  for I := 0 to NumParams - 1 do
    Host.Params[I] := Expected[I].Def;
  for I := 0 to High(Host.Meters) do
    Host.Meters[I] := 99;
  FillChar(HostApi, SizeOf(HostApi), 0);
  HostApi.StructSize := SizeOf(HostApi);
  HostApi.AbiVersion := JCP_ABI_VERSION;
  HostApi.SetParameter := HSetParam;
  HostApi.GetParameter := HGetParam;
  HostApi.Log := HLog;
  HostApi.GetSampleRate := HGetSampleRate;
  HostApi.BeginParameterGesture := HGesture;
  HostApi.EndParameterGesture := HGesture;
  HostApi.SetMeter := HSetMeter;
  FillChar(Transport, SizeOf(Transport), 0);
  Transport.StructSize := SizeOf(Transport);
  Transport.HasInfo := 1;
  Transport.Bpm := 120;
  Transport.TimeSigNumerator := 4;
  Transport.TimeSigDenominator := 4;
  NumChannels := 2;
  UseTransport := True;
end;

function CreateInstance(SampleRate: Double = Rate): Pointer;
begin
  FillChar(VT, SizeOf(VT), 0);
  VT.StructSize := SizeOf(VT);
  Result := Factory.Create(@HostApi, @Host, @VT);
  if Result <> nil then
    VT.Prepare(Result, SampleRate, BlockSize);
end;

function Plugin: TMzPcg;
begin
  Result := TMzPcg(Inst);
end;

// The C++ params::Reader, written out: the host's values into Settings.
function RefSettings: TPcgSettings;
begin
  Result := TPcgSettings.Defaults;
  Result.Pattern := Round(Host.Params[PPattern]) - 1;
  Result.Mode := Round(Host.Params[PMode]);
  Result.Rate := Round(Host.Params[PRate]);
  Result.Depth := Host.Params[PDepth];
  Result.Attack := Host.Params[PAttack];
  Result.Hold := Host.Params[PHold];
  Result.Decay := Host.Params[PDecay];
  Result.Mix := Host.Params[PMix];
  Result.Level := Host.Params[PLevel];
end;

procedure StartPair(SampleRate: Double = Rate);
begin
  ResetHost;
  Inst := CreateInstance(SampleRate);
  // prepareToPlay: prepare, then the settings
  Ref.Init;
  Ref.Prepare(SampleRate);
  Ref.SetSettings(RefSettings);
  Phase := 0;
end;

procedure EndPair;
begin
  VT.Destroy(Inst);
  Inst := nil;
end;

// A block of the input (a saw on the left, its inverse plus a little on the right) into
// both the plug-in's buffers and the reference's.
procedure FillInput(N: Integer);
const
  Inc_: Single = 0.0023;
var
  I: Integer;
begin
  for I := 0 to N - 1 do
  begin
    BufL[I] := 2 * Phase - 1;
    BufR[I] := 0.25 - Phase;
    Phase := Phase + Inc_;
    if Phase >= 1 then
      Phase := Phase - 1;
  end;
  Move(BufL, RefL, SizeOf(BufL));
  Move(BufR, RefR, SizeOf(BufR));
end;

procedure ProcessPlugin(N: Integer);
var
  Ctx: TJuceProcessContext;
begin
  Channels[0] := @BufL;
  Channels[1] := @BufR;
  FillChar(Ctx, SizeOf(Ctx), 0);
  Ctx.StructSize := SizeOf(Ctx);
  Ctx.NumSamples := N;
  Ctx.Channels := @Channels;
  Ctx.Parameters := @Host.Params;
  if UseTransport then
    Ctx.Transport := @Transport;
  Ctx.NumChannels := NumChannels;
  Ctx.NumInputChannels := NumChannels;
  Ctx.NumOutputChannels := NumChannels;
  Ctx.NumParameters := NumParams;
  Ctx.MidiEventSize := SizeOf(TJuceMidiEvent);
  VT.Process(Inst, @Ctx);
end;

// What the C++ processBlock does with the same block.
procedure ProcessRef(N: Integer);
var
  Playing: Boolean;
  Ppq, Bpm: Double;
  R: PPcfSamples;
begin
  Ref.SetSettings(RefSettings);
  Playing := False;
  Ppq := 0;
  Bpm := 120;
  if UseTransport and (Transport.HasInfo <> 0) then
  begin
    Playing := Transport.IsPlaying <> 0;
    Ppq := Transport.PpqPosition;
    Bpm := Transport.Bpm;
  end;
  Ref.SetHostClock(Playing, Ppq, Bpm);
  if NumChannels = 0 then
    Exit;
  R := nil;
  if NumChannels > 1 then
    R := @RefR;
  Ref.Process(@RefL, R, N);
end;

// One block through both; the number of samples whose bits differ (and the right channel
// of a mono block must be left alone), plus the step and the gain published. The timeline
// moves on while playing.
function Both(N: Integer = BlockSize): Integer;
var
  I: Integer;
  Before: array[0..BlockSize - 1] of Single;
  G: Single;
begin
  FillInput(N);
  Move(BufR, Before, SizeOf(BufR));
  ProcessPlugin(N);
  ProcessRef(N);
  Result := 0;
  for I := 0 to N - 1 do
  begin
    if PCardinal(@BufL[I])^ <> PCardinal(@RefL[I])^ then
      Inc(Result);
    if (NumChannels > 1) and (PCardinal(@BufR[I])^ <> PCardinal(@RefR[I])^) then
      Inc(Result);
    if (NumChannels = 1) and (PCardinal(@BufR[I])^ <> PCardinal(@Before[I])^) then
      Inc(Result);
  end;
  if Round(Host.Meters[MeterStep]) <> Ref.Step then
    Inc(Result);
  G := Ref.Gain;
  if PCardinal(@Host.Meters[MeterGain])^ <> PCardinal(@G)^ then
    Inc(Result);
  if (Transport.IsPlaying <> 0) and (Transport.HasInfo <> 0) then
    Transport.PpqPosition := Transport.PpqPosition + N * Transport.Bpm / (60.0 * Rate);
end;

function Step: Integer;
begin
  Result := Round(Host.Meters[MeterStep]);
end;

function GainNow: Single;
begin
  Result := Host.Meters[MeterGain];
end;

{ ---- the checks ---- }

procedure DeclarationChecks;
var
  Info: TJcpParameterInfo;
  I, Bad: Integer;
begin
  Writeln;
  Writeln('parameters (Params.cpp)');

  Check(JuceDeclarationError = '', 'declarations are valid', JuceDeclarationError);
  Check(Factory.Kind = Ord(jkEffect), 'an effect', '');
  Check(Factory.GetParameterCount = NumParams, 'parameter count', Format('%d', [Factory.GetParameterCount]));
  Bad := 0;
  for I := 0 to NumParams - 1 do
  begin
    FillChar(Info, SizeOf(Info), 0);
    Info.StructSize := SizeOf(Info);
    Factory.GetParameterInfo(I, @Info);
    if (string(Info.Id) <> Expected[I].Id) or (string(Info.Name) <> Expected[I].Name)
      or (Info.Kind <> Ord(Expected[I].Kind)) or (Info.MinValue <> Expected[I].Min)
      or (Info.MaxValue <> Expected[I].Max) or (Info.DefaultValue <> Expected[I].Def)
      or (string(Info.LabelText) <> '')
      or ((Expected[I].Choices <> '') and (JuceParameterChoices(I) <> Expected[I].Choices)) then
    begin
      Writeln('    mismatch at ', I, ': ', Info.Id);
      Inc(Bad);
    end;
  end;
  Check(Bad = 0, 'ids, names, kinds, ranges, defaults, choices', Format('%d mismatches', [Bad]));
  Bad := 0;
  for I := 0 to NumSpecs - 1 do
    if (Specs[I].Id <> Expected[I].Id) or (DefaultValue(I) <> Expected[I].Def) then
      Inc(Bad);
  Check(Bad = 0, 'the panel''s table agrees', '');
end;

function TextOf(Index: Integer; Value: Single; out Text: string): Integer;
var
  Buf: array[0..63] of AnsiChar;
begin
  Result := VT.GetParameterText(Inst, Index, Value, @Buf[0], Length(Buf));
  Text := string(PAnsiChar(@Buf[0]));
end;

function TextIs(Index: Integer; Value: Single; const Want: string; var Got: string): Boolean;
var
  T: string;
begin
  Result := (TextOf(Index, Value, T) = 1) and (T = Want);
  if not Result then
    Got := Got + Format(' [%g: "%s", not "%s"]', [Value, T, Want]);
end;

procedure TextChecks;
var
  Got: string;
  Ok: Boolean;
  T: string;
  R: array[0..1] of Integer;
begin
  Writeln;
  Writeln('value text (the C++ withStringFromValueFunction)');
  Got := '';
  Ok := TextIs(PDepth, 1, '100', Got) and TextIs(PDepth, 0.006, '1', Got) and TextIs(PDepth, 0, '0', Got);
  Check(Ok, 'DEPTH 0 to 100', Got);
  Got := '';
  Ok := TextIs(PHold, 0.5, '50%', Got) and TextIs(PMix, 1, '100%', Got) and TextIs(PMix, 0.333, '33%', Got);
  Check(Ok, 'HOLD and MIX in percent', Got);
  Got := '';
  Ok := TextIs(PLevel, 0, '0.0 dB', Got) and TextIs(PLevel, 1.5, '+1.5 dB', Got) and TextIs(PLevel, -24, '-24.0 dB', Got)
    and TextIs(PLevel, 12, '+12.0 dB', Got) and TextIs(PLevel, 1.25, '+1.2 dB', Got) and TextIs(PLevel, 0.75, '+0.8 dB', Got)
    and TextIs(PLevel, -0.25, '-0.2 dB', Got) and TextIs(PLevel, -0.04, '-0.0 dB', Got);
  Check(Ok, 'LEVEL in dB, signed above 0, halves to even (printf)', Got);
  Got := '';
  Ok := TextIs(PAttack, 0, '0.5 ms', Got) and TextIs(PAttack, 0.2, '1.3 ms', Got) and TextIs(PAttack, 1, '50 ms', Got)
    and TextIs(PAttack, 0.8, '19.9054 ms', Got);
  Check(Ok, 'ATTACK in ms (a C++ stream''s six digits from 10 ms)', Got);
  Got := '';
  Ok := TextIs(PDecay, 0, '5.0 ms', Got) and TextIs(PDecay, 0.2, '15.6457 ms', Got) and TextIs(PDecay, 1, '1.50 s', Got);
  Check(Ok, 'DECAY in ms, then seconds', Got);
  R[0] := TextOf(PPattern, 7, T);
  R[1] := TextOf(PMode, 1, T);
  Check((R[0] = 0) and (R[1] = 0) and (TextOf(PRate, 2, T) = 0), 'pattern, mode, rate: the host''s own (the number, the choice)', '');
  Check(VT.GetTailSeconds(Inst) = 0, 'no tail (getTailLengthSeconds)', '');
  Check((JuceNumberText(0.125, 2) = '0.12') and (JuceNumberText(0.375, 2) = '0.38') and (JuceNumberText(999.99996, 0) = '1000')
    and (JuceNumberText(99.999996, 0) = '100') and (JuceNumberText(12.5, 0) = '12.5') and (JuceNumberText(1.0e-300, 1) = '0.0'),
    'juce::String(double, n): %.nf and %g, exactly', '');
end;

procedure AudioChecks;
var
  B, Diff, Lit, Struck: Integer;
  SawSteps: array[0..PcgStepCount - 1] of Boolean;
  S, R, M: Integer;
begin
  Writeln;
  Writeln('audio, against the engine driven as the C++ processBlock drives it');

  StartPair;
  Check((Step = -1) and (GainNow = 1), 'prepared: the step dark, the gain 1 (the C++ atomics'' first values)',
    Format('%d, %g', [Step, GainNow]));

  // playing from the top, stereo, the defaults
  Transport.IsPlaying := 1;
  Diff := 0;
  FillChar(SawSteps, SizeOf(SawSteps), 0);
  for B := 0 to 199 do
  begin
    Inc(Diff, Both);
    S := Step;
    if (S >= 0) and (S < PcgStepCount) then
      SawSteps[S] := True;
  end;
  Lit := 0;
  for S := 0 to PcgStepCount - 1 do
    if SawSteps[S] then
      Inc(Lit);
  Check(Diff = 0, 'playing, stereo: bit-identical, the step and gain published', Format('%d differ', [Diff]));
  Check(Lit = PcgStepCount, 'every one of the 16 steps lit in turn (published as a meter)', Format('%d', [Lit]));

  // every mode and rate, the knobs moved between blocks, odd blocks
  Diff := 0;
  for M := 0 to 1 do
    for R := 0 to 2 do
    begin
      Host.Params[PMode] := M;
      Host.Params[PRate] := R;
      Host.Params[PPattern] := 9 + R + 3 * M;
      Host.Params[PLevel] := 6;
      Host.Params[PMix] := 0.5;
      for B := 0 to 49 do
      begin
        Host.Params[PDepth] := B / 50;
        Host.Params[PHold] := 1 - B / 50;
        Host.Params[PAttack] := B / 70;
        Host.Params[PDecay] := B / 60;
        Inc(Diff, Both(BlockSize - B * 7));
      end;
    end;
  Check(Diff = 0, 'GATE and DUCK, every RATE, knobs moved while playing, odd blocks', Format('%d differ', [Diff]));

  // a loop back to the bar, and a tempo change
  Transport.PpqPosition := 0;
  Diff := Both;
  Transport.Bpm := 173;
  for B := 0 to 49 do
    Inc(Diff, Both);
  Transport.PpqPosition := 0.37;
  for B := 0 to 49 do
    Inc(Diff, Both);
  Check(Diff = 0, 'a loop, a tempo change, a jump into a step', Format('%d differ', [Diff]));

  // stopped, in GATE: nothing struck, the sound passes (the gain back to 1)
  Host.Params[PMode] := 0;
  Host.Params[PMix] := 1;
  Host.Params[PLevel] := 0;
  Transport.IsPlaying := 0;
  Diff := 0;
  for B := 0 to 99 do
    Inc(Diff, Both);
  Check((Diff = 0) and (Step = -1) and (Abs(GainNow - 1) < 1.0e-4), 'stopped, GATE: nothing struck, the sound passes',
    Format('%d differ, step %d, gain %g', [Diff, Step, GainNow]));
  // ... and in DUCK
  Host.Params[PMode] := 1;
  Diff := 0;
  for B := 0 to 99 do
    Inc(Diff, Both);
  Check((Diff = 0) and (Step = -1) and (Abs(GainNow - 1) < 1.0e-4), 'stopped, DUCK: nothing pushed down', Format('%d differ, gain %g', [Diff, GainNow]));
  Struck := Step;

  // a timeline that says playing but has no position: not playing (the C++ needs a ppq)
  Transport.IsPlaying := 1;
  Transport.HasInfo := 0;
  Diff := 0;
  for B := 0 to 49 do
    Inc(Diff, Both);
  Check((Diff = 0) and (Step = -1) and (Struck = -1), 'no position from the host: nothing struck', Format('%d differ', [Diff]));

  // no transport at all
  Transport.HasInfo := 1;
  UseTransport := False;
  Diff := 0;
  for B := 0 to 9 do
    Inc(Diff, Both);
  Check((Diff = 0) and (Step = -1), 'no transport at all: nothing struck', Format('%d differ', [Diff]));
  UseTransport := True;

  // empty blocks, and a block with no channels
  Diff := Both(0);
  Check(GainNow = 1, 'an empty block publishes the gain as 1, as the C++ does', Format('%g', [GainNow]));
  NumChannels := 0;
  Inc(Diff, Both);
  NumChannels := 2;
  Inc(Diff, Both);
  Check(Diff = 0, 'empty blocks and blocks without channels', Format('%d differ', [Diff]));
  Check(Plugin.ProcessErrors = 0, 'no exceptions in Process', '');
  EndPair;

  // mono: the right channel is left alone, as the C++ passes nullptr
  StartPair(96000);
  NumChannels := 1;
  Transport.IsPlaying := 1;
  Transport.Bpm := 133;
  Host.Params[PPattern] := 26;
  Host.Params[PRate] := 2;
  Diff := 0;
  for B := 0 to 299 do
    Inc(Diff, Both(1 + (B * 37) mod BlockSize));
  Check(Diff = 0, 'mono at 96 kHz, odd blocks: bit-identical, right untouched', Format('%d differ', [Diff]));

  // reset: the envelope back to rest, the step dark
  VT.Reset(Inst);
  Ref.Reset;
  Check(Step = -1, 'reset darkens the step', '');
  Diff := 0;
  for B := 0 to 49 do
    Inc(Diff, Both);
  Check(Diff = 0, 'and plays on as the C++ does after reset()', Format('%d differ', [Diff]));

  // prepared again at another rate, in DUCK: the reset sees the mode the engine had
  Host.Params[PMode] := 1;
  Inc(Diff, Both);
  VT.Prepare(Inst, 44100, BlockSize);
  Ref.Prepare(44100);
  Ref.SetSettings(RefSettings);
  Check(Step = -1, 'prepare darkens the step', '');
  Diff := 0;
  for B := 0 to 49 do
    Inc(Diff, Both);
  Check(Diff = 0, 'and plays on as the C++ does after prepareToPlay()', Format('%d differ', [Diff]));
  Check(Plugin.ProcessErrors = 0, 'no exceptions in Process', '');
  EndPair;
end;

procedure StateWriter(Writer: Pointer; Data: Pointer; Size: Int32); cdecl;
var
  N: Integer;
begin
  Inc(StateCalls);
  N := Length(StateBytes);
  SetLength(StateBytes, N + Size);
  if Size > 0 then
    Move(Data^, StateBytes[N], Size);
end;

procedure StateChecks;
var
  I, Diff: Integer;
  Junk: array[0..999] of Byte;
begin
  Writeln;
  Writeln('the saved state: the parameters only (the wrapper saves those)');
  StartPair;
  StateBytes := nil;
  StateCalls := 0;
  VT.GetState(Inst, StateWriter, nil);
  Check(Length(StateBytes) = 0, 'nothing beyond the parameters', Format('%d bytes', [Length(StateBytes)]));

  // anything a project file holds is ignored, and changes nothing
  Transport.IsPlaying := 1;
  for I := 0 to High(Junk) do
    Junk[I] := (I * 131 + 7) and 255;
  VT.SetState(Inst, @Junk[0], Length(Junk));
  VT.SetState(Inst, @Junk[0], 1);
  VT.SetState(Inst, nil, 0);
  Diff := 0;
  for I := 0 to 49 do
    Inc(Diff, Both);
  Check(Diff = 0, 'state from a project changes nothing', Format('%d differ', [Diff]));
  EndPair;
end;

// The control named Name, if it is of class C, else nil.
function Find(Ed: TJuceEditor; const Name: string; C: TJuceControlClass): TJuceControl;
begin
  Result := Ed.FindControl(Name);
  if (Result <> nil) and not (Result is C) then
    Result := nil;
end;

function IndexIn(C: TJuceControl): Integer;
var
  I: Integer;
begin
  Result := -1;
  if (C = nil) or (C.Parent = nil) then
    Exit;
  for I := 0 to C.Parent.ControlCount - 1 do
    if C.Parent.Controls[I] = C then
      Exit(I);
end;

function At(C: TJuceControl; X, Y, W, H: Integer): Boolean;
begin
  Result := (C <> nil) and (Round(C.AbsoluteX) = X) and (Round(C.AbsoluteY) = Y) and (C.Width = W) and (C.Height = H);
end;

// No stand-in left anywhere: no ready-made knob, display or button.
function StandIns(C: TJuceControl): Integer;
var
  I: Integer;
begin
  Result := 0;
  if (C is TJuceKnob) or (C is TJuceDisplay) or (C is TJuceButton) then
    Inc(Result);
  for I := 0 to C.ControlCount - 1 do
    Inc(Result, StandIns(C.Controls[I]));
end;

function SameCurve(const A, B: TPcgCurve): Boolean;
var
  I: Integer;
begin
  Result := Length(A) = Length(B);
  if Result then
    for I := 0 to High(A) do
      if PCardinal(@A[I])^ <> PCardinal(@B[I])^ then
        Exit(False);
end;

procedure PanelChecks;
const
  KnobIds: array[0..5] of Integer = (PDepth, PAttack, PHold, PDecay, PMix, PLevel);
  KnobX: array[0..5] of Integer = (438, 494, 550, 606, 698, 754);
  KnobW: array[0..5] of Integer = (54, 54, 54, 54, 56, 56);
  KnobLegend: array[0..5] of string = ('DEPTH', 'ATK', 'HOLD', 'DEC', 'MIX', 'LEVEL');
var
  Ed: TMzPcgEditor;
  I, Bad, N: Integer;
  C, Face, PcgUnit, OutUnit, Led, Display, Mode, RateC: TJuceControl;
  Where: string;
  K: TPcfKnob;
  S: TJuceRect;
  St: TPcgSettings;
  Curve: TPcgCurve;
  Lo, Hi: Single;
begin
  Writeln;
  Writeln('the panel (the layout, without a window)');
  StartPair;
  Ed := TMzPcgEditor.Create(Plugin);
  try
    Check((Ed.Width = 840) and (Ed.Height = 170), 'the C++ editor''s size', Format('%d x %d', [Ed.Width, Ed.Height]));
    Check(StandIns(Ed.Root) = 0, 'every stand-in swapped for the C++ panel''s control', IntToStr(StandIns(Ed.Root)));

    Face := Find(Ed, 'Face', TPcfFace);
    PcgUnit := Find(Ed, 'PcgUnit', TPcfFace);
    OutUnit := Find(Ed, 'OutUnit', TPcfFace);
    Check(At(Face, 10, 10, 820, 150) and At(PcgUnit, 20, 48, 662, 104) and At(OutUnit, 690, 48, 130, 104)
      and (TPcfFace(Face).Color = PcfBrighter(PcfRail, 0.15)) and (TPcfFace(PcgUnit).Color = PcfMixer)
      and (TPcfFace(OutUnit).Color = PcfMixer), 'the face and the two units (drawFace), where resized() puts them', '');

    Bad := 0;
    Where := '';
    for I := 0 to High(KnobIds) do
    begin
      C := Ed.SpecControl(KnobIds[I]);
      if not (C is TPcfKnob) or not At(C, KnobX[I], 72, KnobW[I], 74) or (C.Caption <> KnobLegend[I])
        or (TPcfKnob(C).ParameterId <> Specs[KnobIds[I]].Id) or (TPcfKnob(C).Sensitivity <> 180)
        or (TPcfKnob(C).ValueBubble <> jvbDragAndHover) or (C.Hint <> HintFor(KnobIds[I]))
        or (TPcfKnob(C).BodyColor <> PcfKnobCap) or (TPcfKnob(C).PointerColor <> PcfPointer)
        or (TPcfKnob(C).TrackColor <> PcfLight) or (IndexIn(C) < IndexIn(OutUnit)) then
      begin
        Inc(Bad);
        Where := Where + Specs[KnobIds[I]].Id + ' ';
      end;
    end;
    Check(Bad = 0, 'six knobs, bound, with their legends, hints and colours', Where);
    K := TPcfKnob(Ed.SpecControl(PDepth));
    S := K.SliderRect;
    Check((S.X = 0) and (S.Y = 12) and (S.W = 54) and (S.H = 54), 'a knob''s slider: square, under its 12 px legend',
      Format('%g %g %g %g', [S.X, S.Y, S.W, S.H]));
    S := TPcfKnob(Ed.SpecControl(PLevel)).SliderRect;
    Check((S.W = 56) and (S.H = 56), 'the output knobs'' a little bigger', '');

    Led := Ed.SpecControl(PPattern);
    Check((Led is TPcfLedNumber) and At(Led, 28, 88, 44, 32) and (TPcfLedNumber(Led).ParameterId = 'pattern')
      and (TPcfLedNumber(Led).Digits = 2) and (Led.Hint = 'PATTERN'#10 + Specs[PPattern].Hint),
      'PATTERN: a two-digit readout on the parameter', '');
    Display := Ed.GainDisplay;
    Check((Display <> nil) and (Ed.FindControl('GainDisplay') = Display) and At(Display, 80, 76, 230, 66)
      and (Display.Hint = GainDisplayHint) and (Display.Caption = '') and (TPcgGainDisplay(Display).Color = PcfDisplay),
      'the gain''s picture, where the C++ puts it', '');
    Mode := Ed.SpecControl(PMode);
    Check((Mode is TPcfSwitch) and At(Mode, 318, 76, 54, 46) and (Mode.Caption = 'MODE')
      and (TPcfSwitch(Mode).ParameterId = 'mode') and (Mode.Hint = 'MODE'#10 + Specs[PMode].Hint),
      'MODE: a pad on the mode', '');
    RateC := Ed.SpecControl(PRate);
    Check((RateC is TPcfSwitch) and At(RateC, 376, 76, 54, 46) and (RateC.Caption = 'RATE')
      and (TPcfSwitch(RateC).ParameterId = 'rate') and (RateC.Hint = 'RATE'#10 + Specs[PRate].Hint),
      'RATE: a pad on the rate', '');
    Check((IndexIn(Face) < IndexIn(PcgUnit)) and (IndexIn(PcgUnit) < IndexIn(Led)) and (IndexIn(Led) < IndexIn(Display))
      and (IndexIn(Display) < IndexIn(Mode)) and (IndexIn(Mode) < IndexIn(RateC)) and (IndexIn(RateC) < IndexIn(Ed.SpecControl(PDepth))),
      'drawn in the form''s order: faces under the controls', '');

    // the picture: opened showing the defaults' curve (no wrapper here: the defaults)
    St := TPcgSettings.Defaults;
    Check((Ed.GainDisplay.Simulations = 1) and SameCurve(Ed.GainDisplay.Curve, PcgGainCurve(St))
      and (Length(Ed.GainDisplay.Curve) = 8000), 'opened with the curve worked out, once: 16 steps of 500 at 4 kHz',
      IntToStr(Length(Ed.GainDisplay.Curve)));
    N := Ed.GainDisplay.Simulations;
    St.Mix := 0.3;
    St.Level := -6;
    Ed.GainDisplay.Show(St, 4, 0.5);
    Check((Ed.GainDisplay.Simulations = N) and (Ed.GainDisplay.Step = 4) and (Ed.GainDisplay.Gain = 0.5),
      'MIX and LEVEL do not change the picture; the step and the gain shown', '');
    Ed.GainDisplay.Show(St, 4, 0.501);
    Check(Ed.GainDisplay.Gain = 0.5, 'a change of the gain under 0.002 is not repainted', '');
    St.Hold := 1;
    St.Pattern := 2;
    Ed.GainDisplay.Show(St, 4, 0.5);
    Curve := Ed.GainDisplay.Curve;
    Lo := 2;
    Hi := -1;
    for I := 0 to High(Curve) do
    begin
      Lo := Min(Lo, Curve[I]);
      Hi := Max(Hi, Curve[I]);
    end;
    Check((Ed.GainDisplay.Simulations = N + 1) and (Lo > 0.999) and (Hi <= 1.0001),
      'pattern 3 (every step full), HOLD all of it: the gate stays open', Format('%g..%g', [Lo, Hi]));
    St.Rate := PcgRateEighth;
    St.Mode := PcgModeDuck;
    St.Pattern := 0;
    Ed.GainDisplay.Show(St, -1, 1);
    Check((Ed.GainDisplay.Simulations = N + 2) and (Length(Ed.GainDisplay.Curve) = 16000)
      and (Ed.GainDisplay.Curve[100] < 0.05) and (Ed.GainDisplay.Curve[4100] < 0.05),
      'DUCK at 1/8: twice as long, pushed down on the beat', Format('%g', [Ed.GainDisplay.Curve[100]]));

    C := Ed.FindControl('ProjectLink');
    Check((C is TJuceLink) and (C.Caption = 'MzPCG_Pascal 0.3.0  -  github.com/simozzer/MzPCG')
      and (TJuceLink(C).Url = 'https://github.com/simozzer/MzPCG'), 'the project line', C.Caption);
    C := Ed.FindControl('Subtitle');
    Check((C is TJuceLabel) and (C.Caption = 'PATTERN CONTROLLED GAIN') and (C.Left = 106), 'the title', '');
    C := Ed.FindControl('PcgTagText');
    Check((C is TJuceLabel) and (C.Caption = 'PCG') and At(C, 28, 54, 60, 15), 'the unit''s tag', '');
  finally
    Ed.Free;
  end;
  EndPair;
end;

begin
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  Writeln('MzPCG_Pascal plug-in check');

  RegisterMzPcg;
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
