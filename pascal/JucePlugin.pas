{
  JucePlugin.pas - write VST3 / AU / LV2 / Standalone plug-ins in Pascal.

  Your plug-in is a Pascal *library* that:
    1. declares its parameters (JuceAddFloatParameter, ...),
    2. registers a TJucePlugin subclass and its kind (JuceRegisterPlugin),
    3. exports pascaljuce_plugin_entry.

    library MySynth;
    uses JucePlugin, MySynthUnit;
    exports pascaljuce_plugin_entry;
    begin
      ParamGain := JuceAddFloatParameter('gain', 'Gain', 0, 1, 0.8);
      JuceRegisterPlugin(TMySynth, jkInstrument);
    end.

  Declaration mistakes (duplicate ids, bad ranges, ...) do not raise - that
  would crash inside the host's DLL loader. They are recorded and reported
  by the wrapper ("refused to load: ..."), shown in the plug-in window and
  the host's log. JuceDeclarationError returns the first one.

  Threading: Process runs on the host's audio thread - no allocation, locks,
  file I/O or UI there. Everything else runs on a non-real-time thread.
  LoadState/SaveState never run concurrently with Process. Exceptions are
  caught at the boundary; an exception in Process silences that block.

  Security: LoadState data comes from project files and MIDI comes from
  devices and hosts: validate sizes and ranges before using them.

  Works with Delphi (Win64) and Free Pascal (Delphi mode is set below).
}
unit JucePlugin;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$PACKRECORDS C}
  {$PACKENUM 4}
{$ELSE}
  {$ALIGN 8}
  {$MINENUMSIZE 4}
{$ENDIF}

interface

uses
{$IFDEF FPC}{$IFDEF UNIX}
  cthreads, { hosts call in from many threads: FPC needs a thread manager }
{$ENDIF}{$ENDIF}
  SysUtils, JuceTypes;

const
  JCP_ABI_VERSION = 2;

  JCP_PARAM_FLAG_AUTOMATABLE = 1;

type
  TJucePluginKind = (jkInstrument, jkEffect, jkMidiEffect);   { = JCP_KIND_* }
  TJuceParameterKind = (jpkFloat, jpkInt, jpkBool, jpkChoice); { = JCP_PARAM_* }

  { --- C ABI records (mirror plugin/include/juce_c_plugin.h) --- }

  TJcpParameterInfo = record
    StructSize: Int32;
    Kind: Int32;
    Id: PAnsiChar;
    Name: PAnsiChar;
    LabelText: PAnsiChar;
    Choices: PAnsiChar;
    MinValue: Single;
    MaxValue: Single;
    DefaultValue: Single;
    Step: Single;
    Flags: Int32;
    VersionHint: Int32;
  end;
  PJcpParameterInfo = ^TJcpParameterInfo;

  TJuceMidiEvent = record
    Data: PByte;            { one complete message; valid only during Process }
    Size: Int32;
    SamplePosition: Int32;
  end;
  PJuceMidiEvent = ^TJuceMidiEvent;
  TJuceMidiEventArray = array[0..$FFFFF] of TJuceMidiEvent;
  PJuceMidiEventArray = ^TJuceMidiEventArray;

  TJuceTransport = record
    StructSize: Int32;
    HasInfo: Int32;          { 0 = host supplied no position (defaults used) }
    Bpm: Double;
    PpqPosition: Double;
    PpqBarStart: Double;
    TimeInSamples: Int64;
    TimeInSeconds: Double;
    IsPlaying: Int32;
    IsRecording: Int32;
    IsLooping: Int32;
    TimeSigNumerator: Int32;
    TimeSigDenominator: Int32;
    Reserved: Int32;
  end;
  PJuceTransport = ^TJuceTransport;

  { Everything Process needs for one block. Audio is processed in place:
    inputs (effects) arrive in Channels and outputs are written there too. }
  TJuceProcessContext = record
    StructSize: Int32;
    NumSamples: Int32;
    Channels: PJuceChannelArray;       { Channels^[0..NumChannels-1]^[0..NumSamples-1] }
    MidiEvents: PJuceMidiEventArray;   { prefer MidiEvent(I) }
    Parameters: PJuceSingleArray;      { prefer Param(I) }
    Transport: PJuceTransport;
    NumChannels: Int32;
    NumInputChannels: Int32;
    NumOutputChannels: Int32;
    NumMidiEvents: Int32;
    NumParameters: Int32;
    MidiEventSize: Int32;
    MidiEventsDropped: Int32;          { events beyond the per-block limit (16384) }
    IsNonRealtime: Int32;              { 1 while the host renders offline }
    { Bounds-checked accessors }
    function Param(Index: Integer): Single;              { 0 if out of range }
    function Channel(Index: Integer): PJuceSampleArray;  { nil if out of range }
    function MidiEvent(Index: Integer): PJuceMidiEvent;  { nil if out of range }
  end;
  PJuceProcessContext = ^TJuceProcessContext;

  PJcpHost = Pointer;

  TJcpAddMidiOutput = procedure(Host: PJcpHost; Data: PByte; Size, SamplePosition: Int32); cdecl;
  TJcpSetParameter = procedure(Host: PJcpHost; Index: Int32; Value: Single); cdecl;
  TJcpGetParameter = function(Host: PJcpHost; Index: Int32): Single; cdecl;
  TJcpSetLatency = procedure(Host: PJcpHost; Samples: Int32); cdecl;
  TJcpLog = procedure(Host: PJcpHost; Message: PAnsiChar); cdecl;
  TJcpGetSampleRate = function(Host: PJcpHost): Double; cdecl;
  TJcpGesture = procedure(Host: PJcpHost; Index: Int32); cdecl;
  TJcpHostExtension = function(Host: PJcpHost; Id: PAnsiChar): Pointer; cdecl;

  TJcpHostApi = record
    StructSize: Int32;
    AbiVersion: Int32;
    AddMidiOutput: TJcpAddMidiOutput;
    SetParameter: TJcpSetParameter;
    GetParameter: TJcpGetParameter;
    SetLatencySamples: TJcpSetLatency;
    Log: TJcpLog;
    GetSampleRate: TJcpGetSampleRate;
    BeginParameterGesture: TJcpGesture;
    EndParameterGesture: TJcpGesture;
    GetExtension: TJcpHostExtension;
  end;
  PJcpHostApi = ^TJcpHostApi;

  TJcpStateWriter = procedure(Writer: Pointer; Data: Pointer; Size: Int32); cdecl;

  TJcpPluginVTable = record
    StructSize: Int32;
    Reserved: Int32;
    Destroy: procedure(Inst: Pointer); cdecl;
    Prepare: procedure(Inst: Pointer; SampleRate: Double; MaxBlockSize: Int32); cdecl;
    Release: procedure(Inst: Pointer); cdecl;
    Reset: procedure(Inst: Pointer); cdecl;
    Process: procedure(Inst: Pointer; Context: PJuceProcessContext); cdecl;
    GetState: procedure(Inst: Pointer; Write: TJcpStateWriter; Writer: Pointer); cdecl;
    SetState: procedure(Inst: Pointer; Data: Pointer; Size: Int32); cdecl;
    GetTailSeconds: function(Inst: Pointer): Double; cdecl;
    GetParameterText: function(Inst: Pointer; Index: Int32; Value: Single; Buffer: PAnsiChar;
      BufferSize: Int32): Int32; cdecl;
    GetExtension: function(Inst: Pointer; Id: PAnsiChar): Pointer; cdecl;
  end;
  PJcpPluginVTable = ^TJcpPluginVTable;

  TJcpPluginFactory = record
    StructSize: Int32;
    AbiVersion: Int32;
    Kind: Int32;
    Reserved: Int32;
    GetParameterCount: function: Int32; cdecl;
    GetParameterInfo: function(Index: Int32; Info: PJcpParameterInfo): Int32; cdecl;
    Create: function(Api: PJcpHostApi; Host: PJcpHost; VTable: PJcpPluginVTable): Pointer; cdecl;
    ErrorMessage: PAnsiChar;
  end;
  PJcpPluginFactory = ^TJcpPluginFactory;

  { --- Base class: subclass this --- }

  TJucePlugin = class
  private
    FHostApi: PJcpHostApi;
    FHost: PJcpHost;
    FSampleRate: Double;
    FMaxBlockSize: Integer;
    FProcessErrors: Integer;
    function HostHas(Field: Pointer): Boolean;
  public
    { Runs on the host's main thread. Allocate here or in Prepare. }
    constructor Create; virtual;
    { Called before playback starts, and whenever rate/block size change.
      AMaxBlockSize is the host's expected maximum; always honour
      Ctx.NumSamples in Process. }
    procedure Prepare(ASampleRate: Double; AMaxBlockSize: Integer); virtual;
    procedure Release; virtual;
    { Host asks to silence voices/tails (e.g. on transport jump). Some hosts
      call this on the audio thread, between Process calls: keep it
      real-time safe (no allocation, locks or I/O). }
    procedure Reset; virtual;
    { The audio callback. Must be real-time safe. }
    procedure Process(const Ctx: TJuceProcessContext); virtual; abstract;
    { Extra state beyond parameters (which are saved automatically). Data
      passed to LoadState is untrusted: it comes from a project file. It is
      empty if the saved state had no custom data. }
    function SaveState: TBytes; virtual;
    procedure LoadState(const Data: TBytes); virtual;
    function TailSeconds: Double; virtual;
    { Optional display text for a parameter value (e.g. '-6.0 dB'). Return
      False to use the default. May run on any host thread, concurrently with
      Process and LoadState: read only immutable data, keep it quick. }
    function ParameterToText(Index: Integer; Value: Single; out Text: string): Boolean; virtual;

    { Host services }
    { Process only: emit one complete MIDI message (needs KIND midi_effect or
      MIDI_OUTPUT ON). Invalid messages are dropped. }
    procedure SendMidi(const Data: array of Byte; SamplePosition: Integer);
    { Change a parameter and tell the host (e.g. from a custom editor). Wrap
      continuous changes (a drag) in BeginGesture / EndGesture. Not from the
      audio thread. }
    procedure SetParameter(Index: Integer; Value: Single);
    procedure BeginGesture(Index: Integer);
    procedure EndGesture(Index: Integer);
    function GetParameter(Index: Integer): Single;
    procedure SetLatencySamples(Samples: Integer);
    { Not real-time safe. }
    procedure Log(const Msg: string);

    property SampleRate: Double read FSampleRate;
    property MaxBlockSize: Integer read FMaxBlockSize;
    { Exceptions caught in Process so far. }
    property ProcessErrors: Integer read FProcessErrors;
  end;
  TJucePluginClass = class of TJucePlugin;

{ Parameter declarations - call from the library's begin..end block, before
  JuceRegisterPlugin. Each returns the parameter's index (its slot in
  TJuceProcessContext.Parameters), or -1 if the declaration is invalid.
  Ids: 1-128 characters of A-Z a-z 0-9 _ - . ; unique; never change them once
  you ship (hosts save them). VersionHint: the plug-in release (>= 1) in which
  the parameter was added - required by AU when you add parameters later. }
function JuceAddFloatParameter(const Id, Name: string; MinValue, MaxValue, DefaultValue: Single;
  const Units: string = ''; Step: Single = 0; Automatable: Boolean = True;
  VersionHint: Integer = 1): Integer;
function JuceAddIntParameter(const Id, Name: string; MinValue, MaxValue, DefaultValue: Integer;
  const Units: string = ''; Automatable: Boolean = True; VersionHint: Integer = 1): Integer;
function JuceAddBoolParameter(const Id, Name: string; DefaultValue: Boolean;
  Automatable: Boolean = True; VersionHint: Integer = 1): Integer;
function JuceAddChoiceParameter(const Id, Name: string; const Choices: array of string;
  DefaultIndex: Integer = 0; Automatable: Boolean = True; VersionHint: Integer = 1): Integer;

{ Kind must match KIND in pascaljuce_add_plugin. }
procedure JuceRegisterPlugin(PluginClass: TJucePluginClass; Kind: TJucePluginKind = jkInstrument);

{ First declaration error, or '' if all declarations are valid. }
function JuceDeclarationError: string;

{ Export this from your library: exports pascaljuce_plugin_entry; }
function pascaljuce_plugin_entry(HostAbiVersion: Int32; Factory: PJcpPluginFactory): Int32; cdecl;

implementation

uses
  Math;

type
  TParamDecl = record
    Id, Name, Units, Choices: UTF8String;
    Kind: TJuceParameterKind;
    Automatable: Boolean;
    VersionHint: Integer;
    MinValue, MaxValue, DefaultValue, Step: Single;
  end;

var
  GParams: array of TParamDecl;
  GPluginClass: TJucePluginClass;
  GPluginKind: TJucePluginKind = jkInstrument;
  GDeclError: UTF8String;
  GEntryError: UTF8String;
  { Layout probes for "does the other side's struct have this field?" }
  ApiProbe: TJcpHostApi;

threadvar
  { Handed to TJucePlugin.Create, so the constructor can use host services. }
  GCreatingApi: PJcpHostApi;
  GCreatingHost: PJcpHost;

{ ---------------------------------------------------------------------------- }

{ Text for the host must be valid UTF-8, or the wrapper blanks it. Pascal can
  produce invalid bytes without meaning to: a locale separator read as a single
  ANSI byte (fr-FR thousands separator $A0), or Copy() splitting a character.
  Invalid bytes become '?'. }
function Utf8(const S: string): UTF8String;
var
  I, N, Need, K: Integer;
  C: Byte;
  CodePoint: Cardinal;
begin
  Result := UTF8String(S);
  N := Length(Result);
  I := 1;
  while I <= N do
  begin
    C := Ord(Result[I]);
    if C < $80 then
    begin
      Inc(I);
      Continue;
    end;
    if (C >= $C2) and (C <= $DF) then Need := 1
    else if (C >= $E0) and (C <= $EF) then Need := 2
    else if (C >= $F0) and (C <= $F4) then Need := 3
    else Need := -1;
    if (Need > 0) and (I + Need <= N) then
    begin
      CodePoint := C and ($3F shr Need);
      for K := 1 to Need do
        if (Ord(Result[I + K]) and $C0) = $80 then
          CodePoint := (CodePoint shl 6) or (Ord(Result[I + K]) and $3F)
        else
          Need := -1;
      { reject overlong forms, surrogates and values above U+10FFFF }
      if (Need = 2) and ((CodePoint < $800) or ((CodePoint >= $D800) and (CodePoint <= $DFFF))) then Need := -1;
      if (Need = 3) and ((CodePoint < $10000) or (CodePoint > $10FFFF)) then Need := -1;
    end
    else
      Need := -1;
    if Need < 0 then
    begin
      Result[I] := '?';
      Inc(I);
    end
    else
      Inc(I, Need + 1);
  end;
end;

{ Byte offset just past a pointer-sized field: StructSize >= this => present. }
function FieldEnd(Base, Field: Pointer): Integer;
begin
  Result := Integer(PAnsiChar(Field) - PAnsiChar(Base)) + SizeOf(Pointer);
end;

procedure DeclError(const Msg: string);
begin
  if GDeclError = '' then
    GDeclError := Utf8(Msg);
end;

function JuceDeclarationError: string;
begin
  Result := string(GDeclError);
end;

function ValidId(const Id: string): Boolean;
var
  I: Integer;
  C: Char;
begin
  Result := (Length(Id) >= 1) and (Length(Id) <= 128);
  for I := 1 to Length(Id) do
  begin
    C := Id[I];
    if not (((C >= 'A') and (C <= 'Z')) or ((C >= 'a') and (C <= 'z')) or ((C >= '0') and (C <= '9'))
      or (C = '_') or (C = '-') or (C = '.')) then
      Result := False;
  end;
end;

function IsFinite(V: Single): Boolean;
var
  Bits: Cardinal;
begin
  { Bit test, not an FP compare: comparing a NaN traps when FP exceptions are
    unmasked, and declarations must never raise. Exponent all ones = Inf/NaN. }
  Move(V, Bits, SizeOf(Bits));
  Result := (Bits and $7F800000) <> $7F800000;
end;

function AddParamChecked(const Id, Name: string; Kind: TJuceParameterKind; MinValue, MaxValue,
  DefaultValue, Step: Single; const Units, Choices: string; Automatable: Boolean;
  VersionHint: Integer): Integer;
var
  I: Integer;
  Problem: string;
begin
  Result := -1;
  Problem := '';
  if not ValidId(Id) then
    Problem := 'id must be 1-128 characters of A-Z a-z 0-9 _ - .'
  else if not (IsFinite(MinValue) and IsFinite(MaxValue) and IsFinite(DefaultValue) and IsFinite(Step)) then
    Problem := 'range values must be finite'
  else if (Kind in [jpkFloat, jpkInt]) and not (MinValue < MaxValue) then
    Problem := 'min must be less than max'
  else if (Kind in [jpkFloat, jpkInt]) and ((DefaultValue < MinValue) or (DefaultValue > MaxValue)) then
    Problem := 'default must lie within min..max'
  else if Step < 0 then
    Problem := 'step must be >= 0'
  else if (Kind = jpkChoice) and (MaxValue < 1) then
    Problem := 'a choice needs at least 2 options'
  else if (Kind = jpkChoice) and ((DefaultValue < 0) or (DefaultValue > MaxValue)) then
    Problem := 'default choice index out of range'
  else if VersionHint < 1 then
    Problem := 'version hint must be >= 1';
  for I := 0 to High(GParams) do
    if (Problem = '') and (GParams[I].Id = Utf8(Id)) then
      Problem := 'duplicate id';
  if (Problem = '') and (Length(GParams) >= 4096) then
    Problem := 'too many parameters (4096 max)';

  if Problem <> '' then
  begin
    DeclError(Format('parameter "%s": %s', [Id, Problem]));
    Exit;
  end;

  Result := Length(GParams);
  SetLength(GParams, Result + 1);
  GParams[Result].Id := Utf8(Id);
  GParams[Result].Name := Utf8(Name);
  GParams[Result].Units := Utf8(Units);
  GParams[Result].Choices := Utf8(Choices);
  GParams[Result].Kind := Kind;
  GParams[Result].Automatable := Automatable;
  GParams[Result].VersionHint := VersionHint;
  GParams[Result].MinValue := MinValue;
  GParams[Result].MaxValue := MaxValue;
  GParams[Result].DefaultValue := DefaultValue;
  GParams[Result].Step := Step;
end;

{ Declarations run in the library's start-up code: nothing may raise there. }
function AddParam(const Id, Name: string; Kind: TJuceParameterKind; MinValue, MaxValue,
  DefaultValue, Step: Single; const Units, Choices: string; Automatable: Boolean;
  VersionHint: Integer): Integer;
begin
  try
    Result := AddParamChecked(Id, Name, Kind, MinValue, MaxValue, DefaultValue, Step, Units, Choices,
      Automatable, VersionHint);
  except
    on E: Exception do
    begin
      DeclError('parameter "' + Id + '": ' + E.Message);
      Result := -1;
    end;
  end;
end;

function JuceAddFloatParameter(const Id, Name: string; MinValue, MaxValue, DefaultValue: Single;
  const Units: string; Step: Single; Automatable: Boolean; VersionHint: Integer): Integer;
begin
  Result := AddParam(Id, Name, jpkFloat, MinValue, MaxValue, DefaultValue, Step, Units, '',
    Automatable, VersionHint);
end;

function JuceAddIntParameter(const Id, Name: string; MinValue, MaxValue, DefaultValue: Integer;
  const Units: string; Automatable: Boolean; VersionHint: Integer): Integer;
begin
  try { the Integer-to-Single conversions happen here, outside AddParam's guard }
    Result := AddParam(Id, Name, jpkInt, MinValue, MaxValue, DefaultValue, 1, Units, '',
      Automatable, VersionHint);
  except
    on E: Exception do
    begin
      DeclError('parameter "' + Id + '": ' + E.Message);
      Result := -1;
    end;
  end;
end;

function JuceAddBoolParameter(const Id, Name: string; DefaultValue: Boolean; Automatable: Boolean;
  VersionHint: Integer): Integer;
begin
  Result := AddParam(Id, Name, jpkBool, 0, 1, Ord(DefaultValue), 1, '', '', Automatable, VersionHint);
end;

function JuceAddChoiceParameter(const Id, Name: string; const Choices: array of string;
  DefaultIndex: Integer; Automatable: Boolean; VersionHint: Integer): Integer;
var
  Joined: string;
  I: Integer;
begin
  try
  Joined := '';
  for I := 0 to High(Choices) do
  begin
    if (Choices[I] = '') or (Pos('|', Choices[I]) > 0) then
    begin
      DeclError(Format('parameter "%s": choice names must be non-empty and must not contain "|"', [Id]));
      Exit(-1);
    end;
    if I > 0 then
      Joined := Joined + '|';
    Joined := Joined + Choices[I];
  end;
  Result := AddParam(Id, Name, jpkChoice, 0, High(Choices), DefaultIndex, 1, '', Joined,
    Automatable, VersionHint);
  except
    on E: Exception do
    begin
      DeclError('parameter "' + Id + '": ' + E.Message);
      Result := -1;
    end;
  end;
end;

procedure JuceRegisterPlugin(PluginClass: TJucePluginClass; Kind: TJucePluginKind);
begin
  GPluginClass := PluginClass;
  GPluginKind := Kind;
end;

{ ---------------------------------------------------------------------------- }
{ TJuceProcessContext                                                          }
{ ---------------------------------------------------------------------------- }

function TJuceProcessContext.Param(Index: Integer): Single;
begin
  if (Index >= 0) and (Index < NumParameters) and (Parameters <> nil) then
    Result := Parameters^[Index]
  else
    Result := 0;
end;

function TJuceProcessContext.Channel(Index: Integer): PJuceSampleArray;
begin
  if (Index >= 0) and (Index < NumChannels) and (Index <= High(TJuceChannelArray)) and (Channels <> nil) then
    Result := Channels^[Index]
  else
    Result := nil;
end;

function TJuceProcessContext.MidiEvent(Index: Integer): PJuceMidiEvent;
begin
  if (Index >= 0) and (Index < NumMidiEvents) and (MidiEvents <> nil) and (MidiEventSize >= SizeOf(TJuceMidiEvent)) then
    Result := PJuceMidiEvent(PAnsiChar(MidiEvents) + NativeInt(Index) * MidiEventSize)
  else
    Result := nil;
end;

{ ---------------------------------------------------------------------------- }
{ TJucePlugin                                                                  }
{ ---------------------------------------------------------------------------- }

constructor TJucePlugin.Create;
begin
  inherited Create;
  FHostApi := GCreatingApi;
  FHost := GCreatingHost;
end;

{ True if the wrapper's host API is big enough to contain Field (a field of
  ApiProbe) and the function is present. }
function TJucePlugin.HostHas(Field: Pointer): Boolean;
begin
  Result := (FHostApi <> nil) and (FHostApi^.StructSize >= FieldEnd(@ApiProbe, Field))
    and (PPointer(PAnsiChar(FHostApi) + (PAnsiChar(Field) - PAnsiChar(@ApiProbe)))^ <> nil);
end;

procedure TJucePlugin.Prepare(ASampleRate: Double; AMaxBlockSize: Integer);
begin
end;

procedure TJucePlugin.Release;
begin
end;

procedure TJucePlugin.Reset;
begin
end;

function TJucePlugin.SaveState: TBytes;
begin
  Result := nil;
end;

procedure TJucePlugin.LoadState(const Data: TBytes);
begin
end;

function TJucePlugin.TailSeconds: Double;
begin
  Result := 0;
end;

function TJucePlugin.ParameterToText(Index: Integer; Value: Single; out Text: string): Boolean;
begin
  Text := '';
  Result := False;
end;

procedure TJucePlugin.SendMidi(const Data: array of Byte; SamplePosition: Integer);
begin
  if (Length(Data) > 0) and HostHas(@@ApiProbe.AddMidiOutput) then
    FHostApi^.AddMidiOutput(FHost, @Data[0], Length(Data), SamplePosition);
end;

procedure TJucePlugin.SetParameter(Index: Integer; Value: Single);
begin
  if HostHas(@@ApiProbe.SetParameter) then
    FHostApi^.SetParameter(FHost, Index, Value);
end;

procedure TJucePlugin.BeginGesture(Index: Integer);
begin
  if HostHas(@@ApiProbe.BeginParameterGesture) then
    FHostApi^.BeginParameterGesture(FHost, Index);
end;

procedure TJucePlugin.EndGesture(Index: Integer);
begin
  if HostHas(@@ApiProbe.EndParameterGesture) then
    FHostApi^.EndParameterGesture(FHost, Index);
end;

function TJucePlugin.GetParameter(Index: Integer): Single;
begin
  if HostHas(@@ApiProbe.GetParameter) then
    Result := FHostApi^.GetParameter(FHost, Index)
  else
    Result := 0;
end;

procedure TJucePlugin.SetLatencySamples(Samples: Integer);
begin
  if HostHas(@@ApiProbe.SetLatencySamples) then
    FHostApi^.SetLatencySamples(FHost, Samples);
end;

procedure TJucePlugin.Log(const Msg: string);
var
  U: UTF8String;
begin
  if HostHas(@@ApiProbe.Log) then
  begin
    U := Utf8(Msg);
    FHostApi^.Log(FHost, PAnsiChar(U));
  end;
end;

{ ---------------------------------------------------------------------------- }
{ C trampolines - every one catches all exceptions                             }
{ ---------------------------------------------------------------------------- }

procedure VDestroy(Inst: Pointer); cdecl;
begin
  try
    TJucePlugin(Inst).Free;
  except
  end;
end;

procedure VPrepare(Inst: Pointer; SampleRate: Double; MaxBlockSize: Int32); cdecl;
var
  P: TJucePlugin;
begin
  P := TJucePlugin(Inst);
  try
    P.FSampleRate := SampleRate;
    P.FMaxBlockSize := MaxBlockSize;
    P.Prepare(SampleRate, MaxBlockSize);
  except
  end;
end;

procedure VRelease(Inst: Pointer); cdecl;
begin
  try
    TJucePlugin(Inst).Release;
  except
  end;
end;

procedure VReset(Inst: Pointer); cdecl;
begin
  try
    TJucePlugin(Inst).Reset;
  except
  end;
end;

procedure SilenceOutputs(const Ctx: TJuceProcessContext);
var
  Ch, I: Integer;
  Buf: PJuceSampleArray;
begin
  { Runs inside an except handler: must not raise itself, even with -Cr. }
  try
    for Ch := 0 to Min(Ctx.NumChannels, (High(TJuceChannelArray) + 1)) - 1 do
    begin
      Buf := Ctx.Channel(Ch);
      if Buf <> nil then
        for I := 0 to Min(Ctx.NumSamples, (High(TJuceSampleArray) + 1)) - 1 do
          Buf^[I] := 0;
    end;
  except
  end;
end;

procedure VProcess(Inst: Pointer; Context: PJuceProcessContext); cdecl;
var
  P: TJucePlugin;
begin
  { A context from a different wrapper version that lacks fields we read is
    skipped rather than read past its end. }
  if (Context = nil) or (Context^.StructSize < SizeOf(TJuceProcessContext))
    or ((Context^.Transport <> nil) and (Context^.Transport^.StructSize < SizeOf(TJuceTransport))) then
    Exit;
  P := TJucePlugin(Inst);
  try
    P.Process(Context^);
  except
    if P.FProcessErrors < High(Integer) then // saturate: -Co must not raise here
      Inc(P.FProcessErrors);
    SilenceOutputs(Context^);
  end;
end;

procedure VGetState(Inst: Pointer; Write: TJcpStateWriter; Writer: Pointer); cdecl;
var
  Data: TBytes;
begin
  try
    Data := TJucePlugin(Inst).SaveState;
    { The ABI length is Int32: a 2 GB+ state is dropped, never cut short (the
      wrapper also refuses custom state above 64 MB). }
    if (Length(Data) > 0) and (Length(Data) <= High(Int32)) then
      Write(Writer, @Data[0], Length(Data));
  except
  end;
end;

procedure VSetState(Inst: Pointer; Data: Pointer; Size: Int32); cdecl;
var
  Bytes: TBytes;
begin
  try
    Bytes := nil;
    if (Size > 0) and (Data <> nil) then
    begin
      SetLength(Bytes, Size);
      Move(Data^, Bytes[0], Size);
    end;
    TJucePlugin(Inst).LoadState(Bytes);
  except
  end;
end;

function VGetTailSeconds(Inst: Pointer): Double; cdecl;
begin
  try
    Result := TJucePlugin(Inst).TailSeconds;
  except
    Result := 0;
  end;
end;

function VGetParameterText(Inst: Pointer; Index: Int32; Value: Single; Buffer: PAnsiChar;
  BufferSize: Int32): Int32; cdecl;
var
  Text: string;
  U: UTF8String;
  N: Integer;
begin
  Result := 0;
  try
    if (Buffer = nil) or (BufferSize <= 1) then { no room for any text: let the host use its own }
      Exit;
    if not TJucePlugin(Inst).ParameterToText(Index, Value, Text) then
      Exit;
    U := Utf8(Text);
    N := Length(U);
    if N > BufferSize - 1 then
    begin
      N := BufferSize - 1;
      while (N > 0) and ((Ord(U[N + 1]) and $C0) = $80) do { don't split a UTF-8 sequence }
        Dec(N);
    end;
    if N > 0 then
      Move(PAnsiChar(U)^, Buffer^, N);
    Buffer[N] := #0;
    Result := 1;
  except
    Result := 0;
  end;
end;

function VGetExtension(Inst: Pointer; Id: PAnsiChar): Pointer; cdecl;
begin
  Result := nil;
end;

function FGetParameterCount: Int32; cdecl;
begin
  Result := Length(GParams);
end;

function FGetParameterInfo(Index: Int32; Info: PJcpParameterInfo): Int32; cdecl;
begin
  Result := 1;
  { The wrapper's struct must hold every field this library writes. }
  if (Info = nil) or (Index < 0) or (Index > High(GParams)) or (Info^.StructSize < SizeOf(TJcpParameterInfo)) then
    Exit;
  Info^.Kind := Ord(GParams[Index].Kind);
  Info^.Id := PAnsiChar(GParams[Index].Id);
  Info^.Name := PAnsiChar(GParams[Index].Name);
  Info^.LabelText := PAnsiChar(GParams[Index].Units);
  Info^.Choices := PAnsiChar(GParams[Index].Choices);
  Info^.MinValue := GParams[Index].MinValue;
  Info^.MaxValue := GParams[Index].MaxValue;
  Info^.DefaultValue := GParams[Index].DefaultValue;
  Info^.Step := GParams[Index].Step;
  if GParams[Index].Automatable then
    Info^.Flags := JCP_PARAM_FLAG_AUTOMATABLE
  else
    Info^.Flags := 0;
  Info^.VersionHint := GParams[Index].VersionHint;
  Result := 0;
end;

function Fits(StructSize: Int32; Base, Field: Pointer): Boolean;
begin
  Result := StructSize >= FieldEnd(Base, Field);
end;

function FCreate(Api: PJcpHostApi; Host: PJcpHost; VTable: PJcpPluginVTable): Pointer; cdecl;
var
  Plugin: TJucePlugin;
begin
  Result := nil;
  if (GPluginClass = nil) or (VTable = nil) or (Api = nil) or (Api^.StructSize < 8) or (Api^.AbiVersion <> JCP_ABI_VERSION)
    or not Fits(VTable^.StructSize, VTable, @@VTable^.Process) then
    Exit;
  try
    GCreatingApi := Api;
    GCreatingHost := Host;
    try
      Plugin := GPluginClass.Create;
    finally
      GCreatingApi := nil;
      GCreatingHost := nil;
    end;
    { Also when a subclass constructor forgot to call inherited Create. }
    Plugin.FHostApi := Api;
    Plugin.FHost := Host;

    { Fill only what the wrapper's vtable has room for. }
    VTable^.Destroy := VDestroy;
    VTable^.Prepare := VPrepare;
    VTable^.Release := VRelease;
    VTable^.Reset := VReset;
    VTable^.Process := VProcess;
    if Fits(VTable^.StructSize, VTable, @@VTable^.GetState) then VTable^.GetState := VGetState;
    if Fits(VTable^.StructSize, VTable, @@VTable^.SetState) then VTable^.SetState := VSetState;
    if Fits(VTable^.StructSize, VTable, @@VTable^.GetTailSeconds) then VTable^.GetTailSeconds := VGetTailSeconds;
    if Fits(VTable^.StructSize, VTable, @@VTable^.GetParameterText) then VTable^.GetParameterText := VGetParameterText;
    if Fits(VTable^.StructSize, VTable, @@VTable^.GetExtension) then VTable^.GetExtension := VGetExtension;
    Result := Plugin;
  except
    Result := nil;
  end;
end;

function pascaljuce_plugin_entry(HostAbiVersion: Int32; Factory: PJcpPluginFactory): Int32; cdecl;
var
  Problem: string;
begin
  Result := 1;
  if (Factory = nil) or (Factory^.StructSize < 8) then
    Exit;
  try
    Problem := '';
    if HostAbiVersion <> JCP_ABI_VERSION then
      Problem := Format('wrapper ABI %d, library ABI %d (rebuild the plug-in)', [HostAbiVersion, JCP_ABI_VERSION])
    else if GDeclError <> '' then
      Problem := string(GDeclError)
    else if GPluginClass = nil then
      Problem := 'JuceRegisterPlugin was not called in the library''s begin..end block'
    else if not Fits(Factory^.StructSize, Factory, @@Factory^.Create) then
      Problem := 'wrapper factory struct too small';

    Factory^.AbiVersion := JCP_ABI_VERSION;
    if Problem <> '' then
    begin
      GEntryError := Utf8(Problem);
      if Fits(Factory^.StructSize, Factory, @Factory^.ErrorMessage) then
        Factory^.ErrorMessage := PAnsiChar(GEntryError);
      Exit;
    end;

    Factory^.Kind := Ord(GPluginKind);
    Factory^.GetParameterCount := FGetParameterCount;
    Factory^.GetParameterInfo := FGetParameterInfo;
    Factory^.Create := FCreate;
    Result := 0;
  except
    Result := 1;
  end;
end;

initialization
  { Hosts call us from their own threads. }
  IsMultiThread := True;
{$IFDEF FPC}
  { In -Mdelphi, string is an AnsiString in DefaultSystemCodePage. Make that
    UTF-8 for this library (its RTL is its own, so the host is unaffected):
    parameter names, units and Log text then reach the host unchanged, with
    -FcUTF8 or CODEPAGE UTF8 sources, whatever the Windows ANSI code page. }
  DefaultSystemCodePage := CP_UTF8;
  { ...and file names the RTL returns (FindFirst, GetCurrentDir, ...). }
  SetMultiByteRTLFileSystemCodePage(CP_UTF8);
  { Separators are read from Windows as single ANSI bytes (fr-FR uses $A0);
    under UTF-8 those would be invalid text. }
  if Ord(DefaultFormatSettings.ThousandSeparator) >= $80 then DefaultFormatSettings.ThousandSeparator := ' ';
  if Ord(DefaultFormatSettings.DecimalSeparator) >= $80 then DefaultFormatSettings.DecimalSeparator := '.';
  if Ord(DefaultFormatSettings.DateSeparator) >= $80 then DefaultFormatSettings.DateSeparator := '/';
  if Ord(DefaultFormatSettings.TimeSeparator) >= $80 then DefaultFormatSettings.TimeSeparator := ':';
  if Ord(DefaultFormatSettings.ListSeparator) >= $80 then DefaultFormatSettings.ListSeparator := ',';
{$ENDIF}
{$IFNDEF FPC}
  { Delphi DLLs otherwise reset FPU state to Delphi's defaults, which unmask
    exceptions hosts don't expect. Make Delphi's defaults all-masked.
    (FPC libraries adopt the host's settings; the wrapper also masks and
    restores FP state around every call.) }
  Default8087CW := $133F;
  {$IFDEF CPUX64}
  DefaultMXCSR := $1F80;
  {$ENDIF}
{$ENDIF}

end.
