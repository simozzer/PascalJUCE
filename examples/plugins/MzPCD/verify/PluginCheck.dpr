// MzPCD - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Checks of the plug-in layer (MzPcdPlugin), through the library's real entry point with a
// fake host: the parameter declarations against the C++ Params.cpp, the value texts, the
// latency and the tail, the host's timeline (playing, stopped, none, a loop, a tempo
// change, every RATE), mono and stereo, the step and the push published for the panel,
// empty blocks, reset, and the state (there is none beyond the parameters; hostile state
// changes nothing). Audio is compared, bit for bit, with the engine driven directly as the
// C++ PluginProcessor drives it. And the panel as the layout builds it (MzPcdEditor,
// without a window): every stand-in swapped for the C++ panel's control, where the C++
// editor lays it out, in its drawing order, with its hint.
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
  PcfMath, PcfPatterns, PcfControls, PcdEngine, PcdControls, MzPcdParams, MzPcdPlugin, MzPcdEditor;

const
  Rate = 48000.0;
  BlockSize = 512;

type
  TFakeHost = record
    Params: array[0..NumParams - 1] of Single;
    Meters: array[0..63] of Single;
    SetCalls: Integer;
    Latency: Integer;
    LatencyCalls: Integer;
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
    (Id: 'rate'; Name: 'Rate'; Kind: jpkChoice; Min: 0; Max: 2; Def: 1; Choices: '1/8|1/16|1/32'),
    (Id: 'drive'; Name: 'Drive'; Kind: jpkFloat; Min: 0; Max: 1; Def: 70 / 127; Choices: ''),
    (Id: 'shape'; Name: 'Shape'; Kind: jpkFloat; Min: 0; Max: 1; Def: 0; Choices: ''),
    (Id: 'tone'; Name: 'Tone'; Kind: jpkFloat; Min: 0; Max: 1; Def: 0.5; Choices: ''),
    (Id: 'feedback'; Name: 'Feedback'; Kind: jpkFloat; Min: 0; Max: 1; Def: 0; Choices: ''),
    (Id: 'driveAmount'; Name: 'Pattern Drive'; Kind: jpkFloat; Min: 0; Max: 1; Def: 0.5; Choices: ''),
    (Id: 'toneAmount'; Name: 'Pattern Tone'; Kind: jpkFloat; Min: -1; Max: 1; Def: 0; Choices: ''),
    (Id: 'feedbackAmount'; Name: 'Pattern Feedback'; Kind: jpkFloat; Min: 0; Max: 1; Def: 0; Choices: ''),
    (Id: 'decay'; Name: 'Pattern Decay'; Kind: jpkFloat; Min: 0; Max: 1; Def: 0.35; Choices: ''),
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
  Ref: TPcd;
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

function Same(A, B: Single): Boolean;
begin
  Result := PCardinal(@A)^ = PCardinal(@B)^;
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

procedure HSetLatency(H: PJcpHost; Samples: Int32); cdecl;
begin
  PFakeHost(H)^.Latency := Samples;
  Inc(PFakeHost(H)^.LatencyCalls);
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
  Host.Latency := -1;
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
  HostApi.SetLatencySamples := HSetLatency;
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

function Plugin: TMzPcd;
begin
  Result := TMzPcd(Inst);
end;

// The C++ params::Reader, written out: the host's values into Settings.
function RefSettings: TPcdSettings;
begin
  Result := TPcdSettings.Defaults;
  Result.Pattern := Round(Host.Params[PPattern]) - 1;
  Result.Rate := Round(Host.Params[PRate]);
  Result.Drive := Host.Params[PDrive];
  Result.Shape := Host.Params[PShape];
  Result.Tone := Host.Params[PTone];
  Result.Feedback := Host.Params[PFeedback];
  Result.DriveAmount := Host.Params[PDriveAmount];
  Result.ToneAmount := Host.Params[PToneAmount];
  Result.FeedbackAmount := Host.Params[PFeedbackAmount];
  Result.Decay := Host.Params[PDecay];
  Result.Mix := Host.Params[PMix];
  Result.Level := Host.Params[PLevel];
end;

procedure StartPair(SampleRate: Double = Rate);
begin
  ResetHost;
  Inst := CreateInstance(SampleRate);
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
// of a mono block must be left alone), and the step and the push published must be the
// reference's. The timeline moves on while playing.
function Both(N: Integer = BlockSize): Integer;
var
  I: Integer;
  Before: array[0..BlockSize - 1] of Single;
begin
  FillInput(N);
  Move(BufR, Before, SizeOf(BufR));
  ProcessPlugin(N);
  ProcessRef(N);
  Result := 0;
  for I := 0 to N - 1 do
  begin
    if not Same(BufL[I], RefL[I]) then
      Inc(Result);
    if (NumChannels > 1) and not Same(BufR[I], RefR[I]) then
      Inc(Result);
    if (NumChannels = 1) and not Same(BufR[I], Before[I]) then
      Inc(Result);
  end;
  if Round(Host.Meters[MeterStep]) <> Ref.Step then
    Inc(Result);
  if not Same(Host.Meters[MeterPush], Ref.Envelope) then
    Inc(Result);
  if (Transport.IsPlaying <> 0) and (Transport.HasInfo <> 0) then
    Transport.PpqPosition := Transport.PpqPosition + N * Transport.Bpm / (60.0 * Rate);
end;

function Step: Integer;
begin
  Result := Round(Host.Meters[MeterStep]);
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
      or (Info.MaxValue <> Expected[I].Max) or not Same(Info.DefaultValue, Expected[I].Def)
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
    if (Specs[I].Id <> Expected[I].Id) or not Same(DefaultValue(I), Expected[I].Def) then
      Inc(Bad);
  Check(Bad = 0, 'the panel''s table agrees', '');
  Check(Same(DefaultValue(PDrive), 70 / 127) and (FormatValue(PDrive, DefaultValue(PDrive)) = '70'),
    'DRIVE starts at ReBirth''s 70 (70.0f / 127.0f)', FormatValue(PDrive, DefaultValue(PDrive)));
end;

function TextOf(Index: Integer; Value: Single; out Text: string): Integer;
var
  Buf: array[0..63] of AnsiChar;
begin
  Result := VT.GetParameterText(Inst, Index, Value, @Buf[0], Length(Buf));
  Text := string(PAnsiChar(@Buf[0]));
end;

function Texts(Index: Integer; const Values: array of Single): string;
var
  I: Integer;
  T: string;
begin
  Result := '';
  for I := 0 to High(Values) do
  begin
    if TextOf(Index, Values[I], T) <> 1 then
      T := '<host>';
    if I > 0 then
      Result := Result + ', ';
    Result := Result + T;
  end;
end;

procedure TextChecks;
var
  T: string;
  R0, R1: Integer;
  T0, T1: string;
begin
  Writeln;
  Writeln('value text (the C++ withStringFromValueFunction)');
  T := Texts(PDrive, [0, 70 / 127, 0.5, 1]);
  Check(T = '0, 70, 64, 127', 'DRIVE and SHAPE: ReBirth''s 0 to 127', T);
  T := Texts(PShape, [0, 0.25]);
  Check(T = '0, 32', 'SHAPE', T);
  T := Texts(PTone, [0, 0.5, 0.2, 1]);
  Check(T = '500 Hz, 2.4 kHz, 944 Hz, 12.0 kHz', 'TONE in Hz and kHz', T);
  T := Texts(PFeedback, [0, 0.5, 0.006]);
  Check(T = '0, 50, 1', 'FDBK 0 to 100', T);
  T := Texts(PDriveAmount, [0, 0.5, 1]);
  Check(T = '+0, +64, +127', 'the pattern''s DRIVE: a push, signed', T);
  T := Texts(PToneAmount, [-1, -0.35, 0, 0.2]);
  Check(T = '-100, -35, 0, +20', 'the pattern''s TONE: either way', T);
  T := Texts(PDecay, [0, 0.35, 0.9, 1]);
  Check(T = '15 ms, 75 ms, 946 ms, 1.50 s', 'DEC in ms, then s', T);
  T := Texts(PMix, [1, 0.333]);
  Check(T = '100%, 33%', 'MIX in percent', T);
  T := Texts(PLevel, [0, 1.5, -24, 12, -17.25, 5.25]);
  Check(T = '0.0 dB, +1.5 dB, -24.0 dB, +12.0 dB, -17.2 dB, +5.2 dB', 'LEVEL in dB, signed above 0, ties to even as printf', T);
  R0 := TextOf(PPattern, 7, T0);
  R1 := TextOf(PRate, 1, T1);
  Check((R0 = 0) and (R1 = 0), 'pattern and rate: the host''s own (the number, the choice)', '');
  Check(VT.GetTailSeconds(Inst) = 1.5, 'a tail of 1.5 s, the feedback ringing on (getTailLengthSeconds)', '');
end;

procedure LatencyChecks;
begin
  Writeln;
  Writeln('latency (setLatencySamples (Pcd::latency()))');
  StartPair;
  Check((Host.Latency = PcdLatency) and (PcdLatency = 31), 'the oversampler''s delay, 31 samples, reported from Prepare',
    Format('%d (%d calls)', [Host.Latency, Host.LatencyCalls]));
  VT.Prepare(Inst, 96000, BlockSize);
  Check(Host.Latency = 31, 'the same at another rate (samples at the host''s rate)', IntToStr(Host.Latency));
  EndPair;
end;

procedure AudioChecks;
var
  B, Diff, Lit, Struck, R: Integer;
  SawSteps: array[0..PcfStepCount - 1] of Boolean;
  S: Integer;
  MaxPush: Single;
begin
  Writeln;
  Writeln('audio, against the engine driven as the C++ processBlock drives it');

  // playing from the top, stereo, the defaults
  StartPair;
  Transport.IsPlaying := 1;
  Diff := 0;
  MaxPush := 0;
  FillChar(SawSteps, SizeOf(SawSteps), 0);
  for B := 0 to 199 do
  begin
    Inc(Diff, Both);
    S := Step;
    if (S >= 0) and (S < PcfStepCount) then
      SawSteps[S] := True;
    MaxPush := Max(MaxPush, Host.Meters[MeterPush]);
  end;
  Lit := 0;
  for S := 0 to PcfStepCount - 1 do
    if SawSteps[S] then
      Inc(Lit);
  Check(Diff = 0, 'playing, stereo: bit-identical, the step and push published', Format('%d differ', [Diff]));
  Check(Lit = PcfStepCount, 'every one of the 16 steps lit in turn (published as a meter)', Format('%d', [Lit]));
  Check((MaxPush > 0.5) and (MaxPush <= 1), 'the push published (the envelope, as the C++ envelope())', Format('%.3f', [MaxPush]));

  // the knobs moved between blocks, the pattern too
  Host.Params[PPattern] := 9;
  Host.Params[PShape] := 0.4;
  Host.Params[PFeedback] := 0.8;
  Host.Params[PFeedbackAmount] := 0.5;
  Host.Params[PToneAmount] := -0.7;
  Host.Params[PLevel] := 6;
  Host.Params[PMix] := 0.5;
  Diff := 0;
  for B := 0 to 99 do
  begin
    Host.Params[PDrive] := B / 100;
    Host.Params[PTone] := 1 - B / 100;
    Inc(Diff, Both(BlockSize - B));
  end;
  Check(Diff = 0, 'knobs and the pattern moved while playing, odd blocks', Format('%d differ', [Diff]));

  // every RATE, playing
  Diff := 0;
  for R := 0 to 2 do
  begin
    Host.Params[PRate] := R;
    for B := 0 to 39 do
      Inc(Diff, Both(100 + 7 * B));
  end;
  Check(Diff = 0, 'every RATE (1/8, 1/16, 1/32), the clock''s grid with it', Format('%d differ', [Diff]));
  Host.Params[PRate] := 1;

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

  // stopped: nothing struck, the step dark, the push dying away
  Transport.IsPlaying := 0;
  Diff := 0;
  for B := 0 to 99 do
    Inc(Diff, Both);
  Check((Diff = 0) and (Step = -1) and (Plugin.Envelope < 1.0e-4), 'stopped: nothing struck, the step -1, the push gone',
    Format('%d differ, step %d', [Diff, Step]));
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
  Host.Params[PFeedback] := 1;
  Host.Params[PRate] := 2;
  Diff := 0;
  for B := 0 to 299 do
    Inc(Diff, Both(1 + (B * 37) mod BlockSize));
  Check(Diff = 0, 'mono at 96 kHz, odd blocks: bit-identical, right untouched', Format('%d differ', [Diff]));

  // reset: the envelope, the filters, the oversampler and the loop cleared, the step dark
  VT.Reset(Inst);
  Ref.Reset;
  Check(Step = -1, 'reset darkens the step', '');
  Diff := 0;
  for B := 0 to 49 do
    Inc(Diff, Both);
  Check(Diff = 0, 'and plays on as the C++ does after reset()', Format('%d differ', [Diff]));

  // prepared again at another rate
  VT.Prepare(Inst, 44100, BlockSize);
  Ref.Prepare(44100);
  Check(Step = -1, 'prepare darkens the step', '');
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

procedure PanelChecks;
const
  // MzPcdEditor::resized(): the levels from x 318, the pattern's pushes from 558, a knob
  // every 56; the output's two in their unit
  KnobX: array[0..9] of Integer = (318, 374, 430, 486, 558, 614, 670, 726, 824, 880);
  KnobW: array[0..9] of Integer = (54, 54, 54, 54, 54, 54, 54, 54, 56, 56);
  KnobLegend: array[0..9] of string = ('DRIVE', 'SHAPE', 'TONE', 'FDBK', 'DRIVE', 'TONE', 'FDBK', 'DEC', 'MIX', 'LEVEL');
var
  Ed: TMzPcdEditor;
  I, Bad: Integer;
  C, Face, PcdUnit, OutUnit, Led, Display, RateSwitch, Levels, Pushes: TJuceControl;
  Where: string;
  K: TPcfKnob;
  S: TJuceRect;
begin
  Writeln;
  Writeln('the panel (the layout, without a window)');
  StartPair;
  Ed := TMzPcdEditor.Create(Plugin);
  try
    Check((Ed.Width = 966) and (Ed.Height = 186), 'the C++ editor''s size', Format('%d x %d', [Ed.Width, Ed.Height]));
    Check(StandIns(Ed.Root) = 0, 'every stand-in swapped for the C++ panel''s control', IntToStr(StandIns(Ed.Root)));

    Face := Find(Ed, 'Face', TPcfFace);
    PcdUnit := Find(Ed, 'PcdUnit', TPcfFace);
    OutUnit := Find(Ed, 'OutUnit', TPcfFace);
    Check(At(Face, 10, 10, 946, 166) and At(PcdUnit, 20, 48, 788, 120) and At(OutUnit, 816, 48, 130, 120)
      and (TPcfFace(Face).Color = PcfBrighter(PcfRail, 0.15)) and (TPcfFace(PcdUnit).Color = PcfMixer)
      and (TPcfFace(OutUnit).Color = PcfMixer), 'the face and the two units (drawFace), where resized() puts them', '');

    Levels := Find(Ed, 'LevelsGroup', TPcdGroupLabel);
    Pushes := Find(Ed, 'PushesGroup', TPcdGroupLabel);
    Check(At(Levels, 318, 72, 222, 12) and At(Pushes, 558, 72, 222, 12) and (Levels.Caption = 'LEVELS')
      and (Pushes.Caption = 'PATTERN PUSHES') and (TPcdGroupLabel(Levels).Color = PcfWithAlpha(PcfLight, 0.8))
      and (TPcdGroupLabel(Levels).FontSize = 9) and TPcdGroupLabel(Pushes).Bold
      and (TPcdGroupLabel(Levels).BoxColor = PcfMixer) and (TPcdGroupLabel(Levels).LineColor = PcfWithAlpha(PcfLight, 0.35))
      and (IndexIn(Levels) > IndexIn(PcdUnit)), 'LEVELS and PATTERN PUSHES named over their knobs', '');

    Bad := 0;
    Where := '';
    for I := 0 to High(KnobSpecs) do
    begin
      C := Ed.SpecControl(KnobSpecs[I]);
      if not (C is TPcfKnob) or not At(C, KnobX[I], 86, KnobW[I], 76) or (C.Caption <> KnobLegend[I])
        or (TPcfKnob(C).ParameterId <> Specs[KnobSpecs[I]].Id) or (TPcfKnob(C).Sensitivity <> 180)
        or (TPcfKnob(C).ValueBubble <> jvbDragAndHover) or (C.Hint <> HintFor(KnobSpecs[I]))
        or (TPcfKnob(C).BodyColor <> PcfKnobCap) or (TPcfKnob(C).PointerColor <> PcfPointer)
        or (TPcfKnob(C).TrackColor <> PcfLight) or (IndexIn(C) < IndexIn(OutUnit)) then
      begin
        Inc(Bad);
        Where := Where + Specs[KnobSpecs[I]].Id + ' ';
      end;
    end;
    Check(Bad = 0, 'ten knobs, bound, with their legends, hints and colours', Where);
    Check(Ed.SpecControl(PDriveAmount).Hint = 'PATTERN DRIVE'#10 + Specs[PDriveAmount].Hint,
      'a push''s hint: its name in capitals, then what it does', '');
    K := TPcfKnob(Ed.SpecControl(PDrive));
    S := K.SliderRect;
    Check((S.X = 0) and (S.Y = 12) and (S.W = 54) and (S.H = 54), 'a knob''s slider: square, under its 12 px legend',
      Format('%g %g %g %g', [S.X, S.Y, S.W, S.H]));
    S := TPcfKnob(Ed.SpecControl(PLevel)).SliderRect;
    Check((S.W = 56) and (S.H = 56), 'the output knobs'' a little bigger', '');

    Led := Ed.SpecControl(PPattern);
    Check((Led is TPcfLedNumber) and At(Led, 28, 94, 44, 32) and (TPcfLedNumber(Led).ParameterId = 'pattern')
      and (TPcfLedNumber(Led).Digits = 2) and (Led.Hint = 'PATTERN'#10 + Specs[PPattern].Hint),
      'PATTERN: a two-digit readout on the parameter', '');
    Display := Ed.PatternDisplay;
    Check((Display <> nil) and (Ed.FindControl('PatternDisplay') = Display) and At(Display, 80, 80, 164, 78)
      and (Ed.PatternDisplay.MeterIndex = MeterStep) and (Ed.PatternDisplay.PatternParameterId = 'pattern')
      and Ed.PatternDisplay.ShowPush and (Ed.PatternDisplay.PushMeterIndex = MeterPush)
      and (Display.Hint = PatternDisplayHint), 'the pattern''s picture, the step and the push meter published', '');
    RateSwitch := Ed.SpecControl(PRate);
    Check((RateSwitch is TPcfSwitch) and At(RateSwitch, 252, 82, 54, 46) and (RateSwitch.Caption = 'RATE')
      and (TPcfSwitch(RateSwitch).ParameterId = 'rate') and (RateSwitch.Hint = 'RATE'#10 + Specs[PRate].Hint),
      'RATE: a pad on the rate', '');
    Check((IndexIn(Face) < IndexIn(PcdUnit)) and (IndexIn(PcdUnit) < IndexIn(Led)) and (IndexIn(Led) < IndexIn(Display))
      and (IndexIn(Display) < IndexIn(RateSwitch)) and (IndexIn(RateSwitch) < IndexIn(Ed.SpecControl(PDrive))),
      'drawn in the form''s order: faces under the controls', '');

    Ed.PatternDisplay.Show(8, 3, 0.5);
    Ed.PatternDisplay.Show(8, 3, 0.501);
    Check((Ed.PatternDisplay.Pattern = 8) and (Ed.PatternDisplay.Step = 3) and (Ed.PatternDisplay.Push = 0.5),
      'the picture shows a pattern, a step and the push (a change under 0.002 not repainted)', '');
    C := Ed.FindControl('ProjectLink');
    Check((C is TJuceLink) and (C.Caption = 'MzPCD_Pascal 0.4.0  -  github.com/simozzer/MzPCD')
      and (TJuceLink(C).Url = 'https://github.com/simozzer/MzPCD'), 'the project line', C.Caption);
    C := Ed.FindControl('Subtitle');
    Check((C is TJuceLabel) and (C.Caption = 'PATTERN CONTROLLED DISTORTION'), 'the title', '');
    C := Ed.FindControl('PcdTagText');
    Check((C is TJuceLabel) and (C.Caption = 'PCD') and At(C, 28, 54, 60, 15), 'the unit''s tag', '');
  finally
    Ed.Free;
  end;
  EndPair;
end;

begin
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  Writeln('MzPCD_Pascal plug-in check');

  RegisterMzPcd;
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

  LatencyChecks;
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
