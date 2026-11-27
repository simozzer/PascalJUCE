{
  Unit tests for pascal/JucePlugin.pas, driven through the real exported
  entry point (pascaljuce_plugin_entry) with a fake host written in Pascal.
  No JUCE, no DLLs: exercises the ABI records (layout must match
  plugin/include/juce_c_plugin.h, which static_asserts the same numbers),
  the declaration registry, struct_size handling, trampolines, exception
  containment and state plumbing.

  Build with checks on: fpc -Mdelphi -Cr -Co -Ct -CR -gl -gh ...
}
program test_plugin_unit;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}
{$APPTYPE CONSOLE}

uses
{$IFDEF FPC}{$IFDEF UNIX}
  cthreads, { first: the units below may start the RTL's threading in their initialisation }
{$ENDIF}{$ENDIF}
  SysUtils, Math, JuceTypes, JucePlugin, TestFramework;

{ ---------------------------------------------------------------------------- }
{ Fake host                                                                    }
{ ---------------------------------------------------------------------------- }

type
  TFakeHost = record
    MidiCount: Integer;
    MidiData: array[0..15] of Byte;
    MidiSize: Integer;
    MidiPos: Integer;
    ParamValues: array[0..15] of Single;
    SetParamCalls: Integer;
    Gestures: Integer;
    Latency: Integer;
    LogCount: Integer;
    LastLog: string;
  end;
  PFakeHost = ^TFakeHost;

var
  Host: TFakeHost;
  HostApi: TJcpHostApi;

procedure HAddMidi(H: PJcpHost; Data: PByte; Size, SamplePosition: Int32); cdecl;
begin
  Inc(PFakeHost(H)^.MidiCount);
  PFakeHost(H)^.MidiSize := Size;
  PFakeHost(H)^.MidiPos := SamplePosition;
  if (Size > 0) and (Size <= Length(PFakeHost(H)^.MidiData)) then
    Move(Data^, PFakeHost(H)^.MidiData[0], Size);
end;

procedure HSetParam(H: PJcpHost; Index: Int32; Value: Single); cdecl;
begin
  Inc(PFakeHost(H)^.SetParamCalls);
  if (Index >= 0) and (Index <= High(PFakeHost(H)^.ParamValues)) then
    PFakeHost(H)^.ParamValues[Index] := Value;
end;

function HGetParam(H: PJcpHost; Index: Int32): Single; cdecl;
begin
  if (Index >= 0) and (Index <= High(PFakeHost(H)^.ParamValues)) then
    Result := PFakeHost(H)^.ParamValues[Index]
  else
    Result := -1;
end;

procedure HSetLatency(H: PJcpHost; Samples: Int32); cdecl;
begin
  PFakeHost(H)^.Latency := Samples;
end;

procedure HLog(H: PJcpHost; Msg: PAnsiChar); cdecl;
var
  R: RawByteString;
begin
  Inc(PFakeHost(H)^.LogCount);
  SetString(R, Msg, StrLen(Msg));
  SetCodePage(R, CP_UTF8, False);
  PFakeHost(H)^.LastLog := string(R);
end;

function HGetSampleRate(H: PJcpHost): Double; cdecl;
begin
  Result := 44100;
end;

var
  ProgramsChangedCalls: Integer;

procedure HProgramsChanged(H: PJcpHost); cdecl;
begin
  Inc(ProgramsChangedCalls);
end;

procedure HGesture(H: PJcpHost; Index: Int32); cdecl;
begin
  Inc(PFakeHost(H)^.Gestures);
end;

procedure ResetHost;
begin
  FillChar(Host, SizeOf(Host), 0);
  Host.LastLog := '';
  FillChar(HostApi, SizeOf(HostApi), 0);
  HostApi.StructSize := SizeOf(HostApi);
  HostApi.AbiVersion := JCP_ABI_VERSION;
  HostApi.AddMidiOutput := HAddMidi;
  HostApi.SetParameter := HSetParam;
  HostApi.GetParameter := HGetParam;
  HostApi.SetLatencySamples := HSetLatency;
  HostApi.Log := HLog;
  HostApi.GetSampleRate := HGetSampleRate;
  HostApi.BeginParameterGesture := HGesture;
  HostApi.EndParameterGesture := HGesture;
  HostApi.ProgramsChanged := HProgramsChanged;
  ProgramsChangedCalls := 0;
end;

{ ---------------------------------------------------------------------------- }
{ Test plug-in                                                                 }
{ ---------------------------------------------------------------------------- }

var
  PGain, PMode, PFlag, PSteps: Integer;
  RaiseInCreate, RaiseInProcess, RaiseInPrepare, RaiseInLoad: Boolean;
  LiveInstances: Integer;
  LoadedState: TBytes;
  LoadStateCalls: Integer;

type
  TProbePlugin = class(TJucePlugin)
  public
    PreparedRate: Double;
    ResetCalls: Integer;
    LastParamOutOfRange: Single;
    ChannelOutOfRangeIsNil: Boolean;
    MidiOutOfRangeIsNil: Boolean;
    constructor Create; override;
    destructor Destroy; override;
    procedure Prepare(ASampleRate: Double; AMaxBlockSize: Integer); override;
    procedure Reset; override;
    procedure Process(const Ctx: TJuceProcessContext); override;
    function SaveState: TBytes; override;
    procedure LoadState(const Data: TBytes); override;
    function TailSeconds: Double; override;
    function ParameterToText(Index: Integer; Value: Single; out Text: string): Boolean; override;
    function ProgramCount: Integer; override;
    function CurrentProgram: Integer; override;
    procedure SelectProgram(Index: Integer); override;
    function ProgramName(Index: Integer): string; override;
  public
    Program_: Integer;
  end;

function TProbePlugin.ProgramCount: Integer;
begin
  Result := 3;
end;

function TProbePlugin.CurrentProgram: Integer;
begin
  Result := Program_;
end;

procedure TProbePlugin.SelectProgram(Index: Integer);
begin
  if Index = 2 then
    raise Exception.Create('program 2 always raises; must be contained');
  Program_ := Index;
  ProgramsChanged;
end;

function TProbePlugin.ProgramName(Index: Integer): string;
begin
  case Index of
    0: Result := 'Bass';
    1: Result := 'Caf' + #$00E9 + ' Organ';     { non-ASCII: UTF-8 }
  else
    raise Exception.Create('no name; must be contained');
  end;
end;

constructor TProbePlugin.Create;
begin
  inherited Create;
  Inc(LiveInstances);
  if RaiseInCreate then
    raise Exception.Create('create failed');
  Log('created ' + #$00E9); { non-ASCII exercises UTF-8 }
  SetLatencySamples(64);
end;

destructor TProbePlugin.Destroy;
begin
  Dec(LiveInstances);
  inherited;
end;

procedure TProbePlugin.Prepare(ASampleRate: Double; AMaxBlockSize: Integer);
begin
  if RaiseInPrepare then
    raise Exception.Create('prepare failed');
  PreparedRate := ASampleRate;
end;

procedure TProbePlugin.Reset;
begin
  Inc(ResetCalls);
  raise Exception.Create('reset always raises; must be contained');
end;

procedure TProbePlugin.Process(const Ctx: TJuceProcessContext);
var
  Ch, I: Integer;
  Gain: Single;
  Ev: PJuceMidiEvent;
begin
  if RaiseInProcess then
  begin
    Ctx.Channel(0)^[0] := 123; { partially written, then fail }
    raise Exception.Create('process failed');
  end;
  Gain := Ctx.Param(PGain);
  LastParamOutOfRange := Ctx.Param(999);
  ChannelOutOfRangeIsNil := (Ctx.Channel(Ctx.NumChannels) = nil) and (Ctx.Channel(-1) = nil);
  MidiOutOfRangeIsNil := (Ctx.MidiEvent(Ctx.NumMidiEvents) = nil) and (Ctx.MidiEvent(-1) = nil);
  for Ch := 0 to Ctx.NumChannels - 1 do
    for I := 0 to Ctx.NumSamples - 1 do
      Ctx.Channel(Ch)^[I] := Ctx.Channel(Ch)^[I] * Gain;
  Ev := Ctx.MidiEvent(0);
  if (Ev <> nil) and (Ev^.Size = 3) then
    SendMidi([Ev^.Data[0], Ev^.Data[1] + 12, Ev^.Data[2]], Ev^.SamplePosition);
end;

function TProbePlugin.SaveState: TBytes;
begin
  Result := nil;
  SetLength(Result, 3);
  Result[0] := 7;
  Result[1] := 8;
  Result[2] := 9;
end;

procedure TProbePlugin.LoadState(const Data: TBytes);
begin
  Inc(LoadStateCalls);
  LoadedState := Copy(Data, 0, Length(Data));
  if RaiseInLoad then
    raise Exception.Create('load failed');
end;

function TProbePlugin.TailSeconds: Double;
begin
  Result := 1.25;
end;

function TProbePlugin.ParameterToText(Index: Integer; Value: Single; out Text: string): Boolean;
var
  Raw: RawByteString;
begin
  Result := Index = PGain;
  if Result and (Value = 99) then
  begin
    { invalid UTF-8, as FormatFloat makes with the fr-FR thousands separator $A0 }
    SetLength(Raw, 3);
    Raw[1] := 'a';
    Raw[2] := #$A0;
    Raw[3] := 'b';
    SetCodePage(Raw, CP_UTF8, False);
    Text := string(Raw);
  end
  else if Result then
    Text := Format('x%.1f ' + #$00E9#$00E9#$00E9, [Value]); { multi-byte UTF-8 at the end }
end;

{ ---------------------------------------------------------------------------- }

var
  StateBytes: TBytes;

procedure CollectState(Writer: Pointer; Data: Pointer; Size: Int32); cdecl;
var
  N: Integer;
begin
  N := Length(StateBytes);
  SetLength(StateBytes, N + Size);
  Move(Data^, StateBytes[N], Size);
end;

function OffsetOf(Base, Field: Pointer): Integer;
begin
  Result := PAnsiChar(Field) - PAnsiChar(Base);
end;

function NewFactory: TJcpPluginFactory;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.StructSize := SizeOf(Result);
end;

procedure TestLayout;
var
  Info: TJcpParameterInfo;
  Tr: TJuceTransport;
  Ctx: TJuceProcessContext;
  Api: TJcpHostApi;
  VT: TJcpPluginVTable;
  F: TJcpPluginFactory;
  Ev: TJuceMidiEvent;
begin
  Suite('ABI record layout (= static_asserts in pascaljuce_plugin_processor.cpp)');
{$IFDEF CPU64}
  CheckEquals(64, SizeOf(TJcpParameterInfo), 'jcp_parameter_info size');
  CheckEquals(8, OffsetOf(@Info, @Info.Id), 'jcp_parameter_info.id');
  CheckEquals(40, OffsetOf(@Info, @Info.MinValue), 'jcp_parameter_info.min_value');
  CheckEquals(60, OffsetOf(@Info, @Info.VersionHint), 'jcp_parameter_info.version_hint');
  CheckEquals(16, SizeOf(TJuceMidiEvent), 'jcp_midi_event size');
  CheckEquals(12, OffsetOf(@Ev, @Ev.SamplePosition), 'jcp_midi_event.sample_position');
  CheckEquals(72, SizeOf(TJuceTransport), 'jcp_transport size');
  CheckEquals(32, OffsetOf(@Tr, @Tr.TimeInSamples), 'jcp_transport.time_in_samples');
  CheckEquals(64, OffsetOf(@Tr, @Tr.TimeSigDenominator), 'jcp_transport.time_sig_denominator');
  CheckEquals(72, SizeOf(TJuceProcessContext), 'jcp_process_context size');
  CheckEquals(8, OffsetOf(@Ctx, @Ctx.Channels), 'jcp_process_context.channels');
  CheckEquals(40, OffsetOf(@Ctx, @Ctx.NumChannels), 'jcp_process_context.num_channels');
  CheckEquals(68, OffsetOf(@Ctx, @Ctx.IsNonRealtime), 'jcp_process_context.is_non_realtime');
  CheckEquals(96, SizeOf(TJcpHostApi), 'jcp_host_api size (with programs_changed)');
  CheckEquals(72, OffsetOf(@Api, @@Api.GetExtension), 'jcp_host_api.get_extension');
  CheckEquals(88, OffsetOf(@Api, @@Api.ProgramsChanged), 'jcp_host_api.programs_changed');
  CheckEquals(128, SizeOf(TJcpPluginVTable), 'jcp_plugin_vtable size (with the program functions)');
  CheckEquals(120, OffsetOf(@VT, @@VT.GetProgramName), 'jcp_plugin_vtable.get_program_name');
  CheckEquals(40, OffsetOf(@VT, @@VT.Process), 'jcp_plugin_vtable.process');
  CheckEquals(72, OffsetOf(@VT, @@VT.GetParameterText), 'jcp_plugin_vtable.get_parameter_text');
  CheckEquals(48, SizeOf(TJcpPluginFactory), 'jcp_plugin_factory size');
  CheckEquals(32, OffsetOf(@F, @@F.Create), 'jcp_plugin_factory.create');
  CheckEquals(40, OffsetOf(@F, @F.ErrorMessage), 'jcp_plugin_factory.error_message');
{$ELSE}
  Skip('layout checks', 'expected values are for 64-bit targets');
{$ENDIF}
  CheckEquals(4, SizeOf(TJucePluginKind), 'plug-in kind enum is 4 bytes');
end;

procedure TestEntryAndParameters;
var
  Factory: TJcpPluginFactory;
  Info: TJcpParameterInfo;
begin
  Suite('Entry point and parameter registry');
  Factory := NewFactory;
  CheckEquals(1, pascaljuce_plugin_entry(JCP_ABI_VERSION, @Factory), 'entry refuses before JuceRegisterPlugin');
  Check(Pos('JuceRegisterPlugin', string(UTF8String(Factory.ErrorMessage))) > 0,
    'error message explains: ' + string(UTF8String(Factory.ErrorMessage)));

  PGain := JuceAddFloatParameter('gain', 'Gain', 0, 2, 1, 'x', 0.5);
  PMode := JuceAddChoiceParameter('mode', 'Mode', ['A', 'B', 'C'], 2);
  PFlag := JuceAddBoolParameter('flag', 'Flag', True, False);
  PSteps := JuceAddIntParameter('steps', 'Steps', -4, 4, 1, 'st', True, 3);
  CheckEquals(0, PGain, 'first parameter index 0');
  CheckEquals(3, PSteps, 'fourth parameter index 3');
  CheckEquals('', JuceDeclarationError, 'no declaration errors so far');

  JuceRegisterPlugin(TProbePlugin, jkEffect);
  Factory := NewFactory;
  CheckEquals(1, pascaljuce_plugin_entry(JCP_ABI_VERSION + 1, @Factory), 'entry refuses a different ABI');
  Check(Pos('ABI', string(UTF8String(Factory.ErrorMessage))) > 0, 'ABI mismatch explained');
  CheckEquals(1, pascaljuce_plugin_entry(JCP_ABI_VERSION, nil), 'entry refuses nil factory');
  Factory := NewFactory;
  Factory.StructSize := 24; { a wrapper too old to have Create }
  CheckEquals(1, pascaljuce_plugin_entry(JCP_ABI_VERSION, @Factory), 'entry refuses a too-small factory');
  Check(Factory.ErrorMessage = nil, 'no write past a too-small factory (ErrorMessage untouched)');

  Factory := NewFactory;
  CheckEquals(0, pascaljuce_plugin_entry(JCP_ABI_VERSION, @Factory), 'entry accepts');
  CheckEquals(JCP_ABI_VERSION, Factory.AbiVersion, 'factory ABI version');
  CheckEquals(Ord(jkEffect), Factory.Kind, 'factory reports the registered kind');
  Check(Factory.ErrorMessage = nil, 'no error message on success');

  CheckEquals(4, Factory.GetParameterCount(), 'parameter count');
  FillChar(Info, SizeOf(Info), 0);
  Info.StructSize := SizeOf(Info);
  CheckEquals(0, Factory.GetParameterInfo(PGain, @Info), 'info(gain)');
  CheckEquals('gain', string(UTF8String(Info.Id)), 'id');
  CheckEquals('x', string(UTF8String(Info.LabelText)), 'units');
  CheckEquals(0, Info.Kind, 'float kind');
  CheckEquals(0.5, Info.Step, 0, 'step');
  CheckEquals(JCP_PARAM_FLAG_AUTOMATABLE, Info.Flags, 'automatable by default');
  CheckEquals(1, Info.VersionHint, 'default version hint');

  Factory.GetParameterInfo(PMode, @Info);
  CheckEquals('A|B|C', string(UTF8String(Info.Choices)), 'choices joined with |');
  CheckEquals(2.0, Info.MaxValue, 0, 'choice max = count-1');
  Factory.GetParameterInfo(PFlag, @Info);
  CheckEquals(0, Info.Flags, 'not automatable when asked');
  Factory.GetParameterInfo(PSteps, @Info);
  CheckEquals(3, Info.VersionHint, 'custom version hint');

  CheckEquals(1, Factory.GetParameterInfo(4, @Info), 'info(past end) fails');
  CheckEquals(1, Factory.GetParameterInfo(-1, @Info), 'info(-1) fails');
  CheckEquals(1, Factory.GetParameterInfo(0, nil), 'info(nil) fails');
  Info.StructSize := 16;
  CheckEquals(1, Factory.GetParameterInfo(0, @Info), 'info into a too-small struct fails (no overrun)');
end;

procedure TestInstance;
var
  Factory: TJcpPluginFactory;
  VT: TJcpPluginVTable;
  Inst: Pointer;
  P: TProbePlugin;
  Left, Right: array[0..7] of Single;
  Chans: array[0..1] of PJuceSampleArray;
  Params: array[0..3] of Single;
  NoteOn: array[0..2] of Byte;
  Events: array[0..0] of TJuceMidiEvent;
  Transport: TJuceTransport;
  Ctx: TJuceProcessContext;
  I: Integer;
  AllZero: Boolean;
  Text: array[0..15] of AnsiChar;
  R: RawByteString;
begin
  Suite('Instance lifecycle through the vtable');
  ResetHost;
  Factory := NewFactory;
  pascaljuce_plugin_entry(JCP_ABI_VERSION, @Factory);

  FillChar(VT, SizeOf(VT), 0);
  VT.StructSize := SizeOf(VT);
  RaiseInCreate := True;
  Check(Factory.Create(@HostApi, @Host, @VT) = nil, 'exception in constructor -> create returns nil');
  RaiseInCreate := False;
  CheckEquals(0, LiveInstances, 'failed create left no instance (destructor ran)');

  HostApi.AbiVersion := 99;
  Check(Factory.Create(@HostApi, @Host, @VT) = nil, 'create refuses a host API of another ABI');
  HostApi.AbiVersion := JCP_ABI_VERSION;

  { A wrapper with a smaller (older) vtable: only the fields that fit are written. }
  FillChar(VT, SizeOf(VT), $AB);
  VT.StructSize := 48; { up to and including Process }
  Inst := Factory.Create(@HostApi, @Host, @VT);
  Check((Inst <> nil) and Assigned(VT.Process) and (PtrUInt(PPointer(@@VT.GetState)^) = PtrUInt($ABABABABABABABAB)),
    'small vtable: core entries set, fields past struct_size untouched');
  VT.Destroy(Inst);

  FillChar(VT, SizeOf(VT), 0);
  VT.StructSize := SizeOf(VT);
  Inst := Factory.Create(@HostApi, @Host, @VT);
  Check(Inst <> nil, 'create returns an instance');
  if Inst = nil then
    Exit;
  P := TProbePlugin(Inst);
  CheckEquals(1, LiveInstances, 'one live instance');
  Check(Assigned(VT.Destroy) and Assigned(VT.Process) and Assigned(VT.GetState) and Assigned(VT.SetState)
    and Assigned(VT.GetTailSeconds) and Assigned(VT.GetParameterText) and Assigned(VT.GetExtension),
    'all vtable entries filled');
  CheckEquals(2, Host.LogCount, 'constructor can use host services (Log)');
  CheckEquals('created ' + #$00E9, Host.LastLog, 'Log passes UTF-8');
  CheckEquals(64, Host.Latency, 'constructor can set latency');

  VT.Prepare(Inst, 96000, 256);
  CheckEquals(96000.0, P.SampleRate, 0, 'SampleRate property');
  CheckEquals(256, P.MaxBlockSize, 'MaxBlockSize property');
  RaiseInPrepare := True;
  VT.Prepare(Inst, 48000, 128);
  RaiseInPrepare := False;
  CheckEquals(48000.0, P.SampleRate, 0, 'exception in Prepare contained');
  VT.Reset(Inst);
  CheckEquals(1, P.ResetCalls, 'exception in Reset contained');

  for I := 0 to 7 do
  begin
    Left[I] := 1;
    Right[I] := -0.5;
  end;
  Chans[0] := @Left;
  Chans[1] := @Right;
  Params[0] := 0.5;
  Params[1] := 2;
  Params[2] := 1;
  Params[3] := 0;
  NoteOn[0] := $90;
  NoteOn[1] := 60;
  NoteOn[2] := 100;
  Events[0].Data := @NoteOn;
  Events[0].Size := 3;
  Events[0].SamplePosition := 5;
  FillChar(Transport, SizeOf(Transport), 0);
  Transport.StructSize := SizeOf(Transport);
  FillChar(Ctx, SizeOf(Ctx), 0);
  Ctx.StructSize := SizeOf(Ctx);
  Ctx.NumSamples := 8;
  Ctx.Channels := @Chans;
  Ctx.MidiEvents := @Events;
  Ctx.Parameters := @Params;
  Ctx.Transport := @Transport;
  Ctx.NumChannels := 2;
  Ctx.NumInputChannels := 2;
  Ctx.NumOutputChannels := 2;
  Ctx.NumMidiEvents := 1;
  Ctx.NumParameters := 4;
  Ctx.MidiEventSize := SizeOf(TJuceMidiEvent);

  VT.Process(Inst, @Ctx);
  CheckEquals(0.5, Left[7], 0, 'in-place gain (left)');
  CheckEquals(-0.25, Right[0], 0, 'in-place gain (right)');
  CheckEquals(0.0, P.LastParamOutOfRange, 0, 'Param out of range -> 0');
  Check(P.ChannelOutOfRangeIsNil, 'Channel out of range -> nil');
  Check(P.MidiOutOfRangeIsNil, 'MidiEvent out of range -> nil');
  CheckEquals(1, Host.MidiCount, 'SendMidi reached host');
  CheckEquals(72, Host.MidiData[1], 'SendMidi data');
  CheckEquals(5, Host.MidiPos, 'SendMidi position');

  RaiseInProcess := True;
  VT.Process(Inst, @Ctx);
  RaiseInProcess := False;
  AllZero := True;
  for I := 0 to 7 do
    AllZero := AllZero and (Left[I] = 0) and (Right[I] = 0);
  Check(AllZero, 'exception in Process: whole block silenced');
  CheckEquals(1, P.ProcessErrors, 'ProcessErrors counted');

  { Host services, gestures }
  P.SetParameter(2, 0.75);
  CheckEquals(0.75, P.GetParameter(2), 0, 'Set/GetParameter via host');
  P.BeginGesture(2);
  P.EndGesture(2);
  CheckEquals(2, Host.Gestures, 'Begin/EndGesture reach host');

  { A host API that predates gestures: those services are skipped, not called. }
  HostApi.StructSize := 56; { ends after GetSampleRate }
  Host.Gestures := 0;
  P.BeginGesture(2);
  CheckEquals(0, Host.Gestures, 'service beyond host struct_size is not called');
  HostApi.StructSize := SizeOf(HostApi);

  { Parameter text: bounded, NUL-terminated, never splits UTF-8 }
  FillChar(Text, SizeOf(Text), 'Z');
  CheckEquals(1, VT.GetParameterText(Inst, PGain, 1.5, @Text, SizeOf(Text)), 'parameter text provided');
  SetString(R, PAnsiChar(@Text), StrLen(PAnsiChar(@Text)));
  SetCodePage(R, CP_UTF8, False);
  CheckEquals('x1.5 ' + #$00E9#$00E9#$00E9, string(R), 'text round-trips');
  FillChar(Text, SizeOf(Text), 'Z');
  VT.GetParameterText(Inst, PGain, 1.5, @Text, 7); { room for 6 bytes: 'x1.5 ' + half an e-acute }
  CheckEquals(5, StrLen(PAnsiChar(@Text)), 'truncated at a UTF-8 boundary, NUL inside the buffer');
  Check(Text[7] = 'Z', 'nothing written past BufferSize');
  CheckEquals(0, VT.GetParameterText(Inst, PMode, 1, @Text, SizeOf(Text)), 'no text -> 0 (default)');
  CheckEquals(0, VT.GetParameterText(Inst, PGain, 1, nil, 10), 'nil buffer -> 0');
  FillChar(Text, SizeOf(Text), 'Z');
  CheckEquals(1, VT.GetParameterText(Inst, PGain, 99, @Text, SizeOf(Text)), 'invalid UTF-8 text still provided');
  SetString(R, PAnsiChar(@Text), StrLen(PAnsiChar(@Text)));
  CheckEquals('a?b', string(R), 'invalid UTF-8 bytes repaired, not blanked by the wrapper (round 4)');

  { State }
  StateBytes := nil;
  VT.GetState(Inst, CollectState, nil);
  Check((Length(StateBytes) = 3) and (StateBytes[0] = 7) and (StateBytes[2] = 9), 'SaveState bytes');
  VT.SetState(Inst, @StateBytes[0], Length(StateBytes));
  Check((LoadStateCalls = 1) and (Length(LoadedState) = 3) and (LoadedState[1] = 8), 'SetState -> LoadState');
  VT.SetState(Inst, nil, 0);
  Check((LoadStateCalls = 2) and (Length(LoadedState) = 0), 'empty state -> empty array');
  VT.SetState(Inst, nil, 5);
  Check((LoadStateCalls = 3) and (Length(LoadedState) = 0), 'nil data with size -> empty array (no read)');
  VT.SetState(Inst, @StateBytes[0], -1);
  Check((LoadStateCalls = 4) and (Length(LoadedState) = 0), 'negative size -> empty array');
  RaiseInLoad := True;
  VT.SetState(Inst, @StateBytes[0], 3);
  RaiseInLoad := False;
  CheckEquals(5, LoadStateCalls, 'exception in LoadState contained');

  CheckEquals(1.25, VT.GetTailSeconds(Inst), 0, 'TailSeconds');

  { host programs }
  Check(Assigned(VT.GetProgramCount) and Assigned(VT.GetCurrentProgram) and Assigned(VT.SetCurrentProgram)
    and Assigned(VT.GetProgramName), 'the program callbacks are filled');
  CheckEquals(3, VT.GetProgramCount(Inst), 'ProgramCount');
  CheckEquals(0, VT.GetCurrentProgram(Inst), 'CurrentProgram');
  VT.SetCurrentProgram(Inst, 1);
  CheckEquals(1, VT.GetCurrentProgram(Inst), 'SelectProgram(1)');
  CheckEquals(1, ProgramsChangedCalls, 'ProgramsChanged reaches the host');
  VT.SetCurrentProgram(Inst, 2);
  CheckEquals(1, VT.GetCurrentProgram(Inst), 'an exception in SelectProgram is contained');
  VT.SetCurrentProgram(Inst, 3);
  VT.SetCurrentProgram(Inst, -1);
  CheckEquals(1, VT.GetCurrentProgram(Inst), 'out-of-range programs are not selected');
  FillChar(Text, SizeOf(Text), 'x');
  CheckEquals(1, VT.GetProgramName(Inst, 1, @Text[0], SizeOf(Text)), 'ProgramName');
  R := PAnsiChar(@Text[0]);
  Check((Length(R) = 11) and (Copy(R, 1, 3) = 'Caf') and (Ord(R[4]) = $C3) and (Ord(R[5]) = $A9)
    and (Copy(R, 6, 6) = ' Organ'), 'the name in UTF-8');
  FillChar(Text, SizeOf(Text), 'x');
  CheckEquals(1, VT.GetProgramName(Inst, 1, @Text[0], 5), 'a short buffer');
  R := PAnsiChar(@Text[0]);
  Check(R = 'Caf', 'cut, never inside a character');
  CheckEquals(0, VT.GetProgramName(Inst, 7, @Text[0], SizeOf(Text)), 'an exception in ProgramName is contained');
  CheckEquals(0, VT.GetProgramName(Inst, 0, nil, 10), 'no buffer');
  Check(VT.GetExtension(Inst, 'anything') = nil, 'no extensions yet');
  VT.Release(Inst);
  VT.Destroy(Inst);
  CheckEquals(0, LiveInstances, 'destroy frees the instance');
end;

procedure TestWithoutHost;
var
  P: TProbePlugin;
begin
  Suite('Plug-in object created outside a host');
  P := TProbePlugin.Create;
  try
    P.SendMidi([$90, 60, 1], 0);
    P.SetParameter(0, 1);
    P.BeginGesture(0);
    CheckEquals(0.0, P.GetParameter(0), 0, 'host services are safe no-ops without a host');
  finally
    P.Free;
  end;
end;

procedure TestDeclarationErrors;
var
  Factory: TJcpPluginFactory;
  Saved: TFPUExceptionMask;
  NaNValue: Single;
  Res: Integer;
begin
  Suite('Declaration errors are reported, not raised');
  CheckEquals(-1, JuceAddFloatParameter('gain', 'Again', 0, 1, 0), 'duplicate id -> -1');
  Check(Pos('duplicate', JuceDeclarationError) > 0, 'first error recorded: ' + JuceDeclarationError);
  CheckEquals(-1, JuceAddFloatParameter('bad id!', 'X', 0, 1, 0), 'invalid id chars -> -1');
  CheckEquals(-1, JuceAddFloatParameter('', 'X', 0, 1, 0), 'empty id -> -1');
  CheckEquals(-1, JuceAddFloatParameter('rev', 'X', 1, 0, 0), 'min > max -> -1');
  CheckEquals(-1, JuceAddFloatParameter('outside', 'X', 0, 1, 2), 'default outside range -> -1');
  CheckEquals(-1, JuceAddFloatParameter('nan', 'X', 0, 1, 0, '', -1), 'negative step -> -1');
  CheckEquals(-1, JuceAddIntParameter('same', 'X', 3, 3, 3), 'int min = max -> -1');
  CheckEquals(-1, JuceAddChoiceParameter('one', 'X', ['Only']), 'single choice -> -1 (would be NaN in JUCE)');
  CheckEquals(-1, JuceAddChoiceParameter('pipe', 'X', ['A|B', 'C']), 'choice containing | -> -1');
  CheckEquals(-1, JuceAddChoiceParameter('idx', 'X', ['A', 'B'], 5), 'choice default out of range -> -1');
  CheckEquals(-1, JuceAddBoolParameter('ver', 'X', False, True, 0), 'version hint 0 -> -1');
  Check(Pos('duplicate', JuceDeclarationError) > 0, 'the FIRST error is the one kept');
  { Fable review round 1: a NaN argument made the FP compare in IsFinite trap
    (EInvalidOp) when FP exceptions were unmasked. }
  Saved := GetExceptionMask;
  SetExceptionMask([exDenormalized, exUnderflow, exPrecision]); { invalid op, zero-divide, overflow unmasked }
  Res := 0;
  try
    PCardinal(@NaNValue)^ := $7FC00000;
    try
      Res := JuceAddFloatParameter('nanmin', 'X', NaNValue, 1, 0);
    except
      Res := -999;
    end;
  finally
    SetExceptionMask(Saved);
  end;
  CheckEquals(-1, Res, 'NaN declaration with FP exceptions unmasked -> -1, not an exception');

  Factory := NewFactory;
  CheckEquals(1, pascaljuce_plugin_entry(JCP_ABI_VERSION, @Factory), 'entry refuses after a declaration error');
  Check(Pos('duplicate', string(UTF8String(Factory.ErrorMessage))) > 0,
    'factory error message carries the declaration error');
  Check(not Assigned(Factory.Create), 'no create function handed out');
end;

begin
  TestLayout;
  TestEntryAndParameters;
  TestInstance;
  TestWithoutHost;
  TestDeclarationErrors; { last: a declaration error disables the entry point for good }
  Halt(TestSummary);
end.
