{
  JuceAudio.pas - object layer over juce_c_audio for Free Pascal/Lazarus and Delphi.

  Threading rules
  ---------------
  * Call JuceInitialise once from the main thread before anything else, and
    JuceShutdown at the end, after freeing every Juce object.
  * TJuceAudioDeviceManager.OnAudio runs on the audio thread and
    TJuceMidiInput's handler on a MIDI thread. Keep them real-time safe: no
    allocation, locks, UI, WriteLn or TThread.Synchronize there.
  * OnAudioStart / OnAudioStop run on the thread that opens or restarts the
    device (normally the main thread). OnChange runs on the main thread.
  * Assign OnAudio / OnAudioStart / OnAudioStop while no device is open
    (setting them on an open device raises EJuceError).
  * Console programs (and Linux GUI programs) must call JuceDispatchMessages
    regularly; Windows/macOS VCL/LCL apps don't need to.
  * Free Pascal on Unix: juce_c_audio pulls in cthreads itself.
  * Free (or Close) a device manager before freeing objects its handlers use,
    on the thread that called JuceInitialise.
}
unit JuceAudio;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  SysUtils, Types, JuceTypes, juce_c_audio;

const
  { Result codes, re-exported so `uses JuceAudio` is enough. }
  JUCE_C_OK               = juce_c_audio.JUCE_C_OK;
  JUCE_C_INVALID_ARGUMENT = juce_c_audio.JUCE_C_INVALID_ARGUMENT;
  JUCE_C_OUT_OF_MEMORY    = juce_c_audio.JUCE_C_OUT_OF_MEMORY;
  JUCE_C_JUCE_ERROR       = juce_c_audio.JUCE_C_JUCE_ERROR;
  JUCE_C_OUT_OF_RANGE     = juce_c_audio.JUCE_C_OUT_OF_RANGE;
  JUCE_C_BUFFER_TOO_SMALL = juce_c_audio.JUCE_C_BUFFER_TOO_SMALL;
  JUCE_C_NOT_INITIALISED  = juce_c_audio.JUCE_C_NOT_INITIALISED;
  JUCE_C_INVALID_STATE    = juce_c_audio.JUCE_C_INVALID_STATE;
  { Name of the native library this binding loads. }
  JuceCAudioLib           = juce_c_audio.JuceCAudioLib;

type
  { Re-exported so `uses JuceAudio` is enough. }
  TJuceSampleArray  = JuceTypes.TJuceSampleArray;
  PJuceSampleArray  = JuceTypes.PJuceSampleArray;
  TJuceChannelArray = JuceTypes.TJuceChannelArray;
  PJuceChannelArray = JuceTypes.PJuceChannelArray;
  TStringDynArray   = Types.TStringDynArray;
  TDoubleDynArray   = Types.TDoubleDynArray;
  TIntegerDynArray  = Types.TIntegerDynArray;

  EJuceError = class(Exception)
  private
    FCode: Integer;
  public
    constructor CreateCode(ACode: Integer; const AMessage: string);
    property Code: Integer read FCode;
  end;

  TJuceMidiBuffer = class;
  TJuceAudioDeviceManager = class;
  TJuceMidiInput = class;

  { MIDI event visitor. Data is only valid during the call; check Size before
    indexing Data (MIDI from devices and hosts is untrusted input). }
  TJuceMidiEventHandler = procedure(Data: PByte; Size, SamplePosition: Integer) of object;

  { This block's MIDI, as passed to OnAudio. Valid only during the callback. }
  TJuceMidiView = record
    Handle: Pointer; { PJuceCMidiBuffer }
    function Count: Integer;
    { Real-time safe. An exception raised by Handler stops the iteration and
      is re-raised here. }
    procedure Enumerate(Handler: TJuceMidiEventHandler);
  end;

  { Audio thread. Outputs are zero-filled before the call. Access samples as
    Outputs^[Channel]^[Index] for Channel < NumOutputs, Index < NumSamples.
    NumSamples can vary from block to block. }
  TJuceAudioEvent = procedure(Sender: TJuceAudioDeviceManager;
    Inputs: PJuceChannelArray; NumInputs: Integer;
    Outputs: PJuceChannelArray; NumOutputs: Integer;
    NumSamples: Integer; const Midi: TJuceMidiView) of object;
  TJuceAudioStartEvent = procedure(Sender: TJuceAudioDeviceManager;
    SampleRate: Double; ExpectedBlockSize: Integer) of object;
  TJuceNotifyEvent = procedure(Sender: TObject) of object;

  { MIDI thread. Timestamp is JuceMillisecondCounter / 1000 at arrival. }
  TJuceMidiInputEvent = procedure(Sender: TJuceMidiInput; Data: PByte; Size: Integer;
    TimestampSeconds: Double) of object;

  { What a Virtual device's inputs carry (see AddVirtualDeviceType). }
  TJuceVirtualInput = (viSilence, viTone, viLoopback);

  { Channels 0..255; e.g. Setup.OutputChannels := [0, 1]. }
  TJuceChannelSet = set of 0..255;

  TJuceAudioDeviceSetup = record
    OutputDeviceName: string;     { '' = none }
    InputDeviceName: string;      { '' = none }
    SampleRate: Double;           { 0 = device default }
    BufferSize: Integer;          { 0 = device default }
    InputChannels: TJuceChannelSet;
    OutputChannels: TJuceChannelSet;
    UseDefaultInputChannels: Boolean;   { True = ignore InputChannels }
    UseDefaultOutputChannels: Boolean;
  end;

  TJuceMidiDeviceInfo = record
    Name: string;
    Identifier: string;
  end;
  TJuceMidiDeviceInfoArray = array of TJuceMidiDeviceInfo;

  { juce::AudioBuffer<float> }
  {$IFDEF FPC}{$PUSH}{$WARN 3018 OFF}{$ENDIF} { CreateFromHandle is protected on purpose }
  TJuceAudioBuffer = class
  private
    FHandle: PJuceCAudioBuffer;
    function GetNumChannels: Integer;
    function GetNumSamples: Integer;
    function GetChannel(Index: Integer): PJuceSampleArray;
  protected
    { Takes ownership of a handle created by the C API. }
    constructor CreateFromHandle(AHandle: PJuceCAudioBuffer);
  public
    constructor Create(NumChannels, NumSamples: Integer);
    destructor Destroy; override;
    procedure SetSize(NumChannels, NumSamples: Integer; KeepContent: Boolean = False);
    procedure Clear; overload;
    procedure Clear(StartSample, Count: Integer); overload;
    procedure ApplyGain(Gain: Single);
    procedure ApplyGainRamp(StartSample, Count: Integer; StartGain, EndGain: Single);
    procedure AddFrom(DestChannel, DestStart: Integer; Source: TJuceAudioBuffer;
      SourceChannel, SourceStart, Count: Integer; Gain: Single = 1.0);
    procedure CopyFrom(DestChannel, DestStart: Integer; Source: TJuceAudioBuffer;
      SourceChannel, SourceStart, Count: Integer);
    function Magnitude(Channel, StartSample, Count: Integer): Single;
    function RMSLevel(Channel, StartSample, Count: Integer): Single;
    property Handle: PJuceCAudioBuffer read FHandle;
    property NumChannels: Integer read GetNumChannels;
    property NumSamples: Integer read GetNumSamples;
    { Raises EJuceError for an invalid channel. The returned pointer is valid
      until the buffer is resized or freed; index only below NumSamples. }
    property Channel[Index: Integer]: PJuceSampleArray read GetChannel; default;
  end;
  {$IFDEF FPC}{$POP}{$ENDIF}

  { juce::MidiBuffer }
  TJuceMidiBuffer = class
  private
    FHandle: PJuceCMidiBuffer;
    function GetCount: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    { Data must be exactly one complete MIDI message. }
    procedure Add(const Data: array of Byte; SamplePosition: Integer);
    procedure Enumerate(Handler: TJuceMidiEventHandler);
    property Handle: PJuceCMidiBuffer read FHandle;
    property Count: Integer read GetCount;
  end;

  { juce::AudioDeviceManager }
  TJuceAudioDeviceManager = class
  private
    FHandle: PJuceCAudioDeviceManager;
    FOnAudio: TJuceAudioEvent;
    FOnAudioStart: TJuceAudioStartEvent;
    FOnAudioStop: TJuceNotifyEvent;
    FOnChange: TJuceNotifyEvent;
    FInCallback: Integer; { > 0 inside OnAudioStart/OnAudioStop/OnChange (message thread) }
    FConstructed: Boolean; { set by AfterConstruction: devices may only open after that }
    procedure CheckConstructed;
    procedure CheckClosed(const What: string);
    procedure SetOnAudio(const Value: TJuceAudioEvent);
    procedure SetOnAudioStart(const Value: TJuceAudioStartEvent);
    procedure SetOnAudioStop(const Value: TJuceNotifyEvent);
    procedure SetOnChange(const Value: TJuceNotifyEvent);
    function GetCurrentDeviceType: string;
    procedure SetCurrentDeviceType(const Value: string);
    function GetSetup: TJuceAudioDeviceSetup;
    procedure SetSetup(const Value: TJuceAudioDeviceSetup);
  public
    constructor Create;
    { Checks the thread and closes the device before any (subclass) destructor
      body runs, so no callback can reach a half-destroyed object. Raises
      EJuceError, freeing nothing, if called off the JUCE message thread. }
    procedure BeforeDestruction; override;
    { Devices can only be opened once construction has finished: a subclass
      constructor that raised after opening one would otherwise leave the
      audio thread calling into a half-destroyed object (Pascal skips
      BeforeDestruction when a constructor fails). Open devices after Create
      returns, or override AfterConstruction (call inherited first). }
    procedure AfterConstruction; override;
    destructor Destroy; override;

    { Registers the "Virtual" device type (tests, CI, headless/offline use).
      Realtime = False renders as fast as possible. Input: what the inputs
      carry - silence, a 440 Hz sine at 0.25, or loopback (each input is the
      matching output of the previous block). }
    procedure AddVirtualDeviceType(Realtime: Boolean = True; Input: TJuceVirtualInput = viSilence);
    { Virtual device only: count a simulated dropout. }
    procedure SimulateXRun;

    { Opens default devices; may be called again (e.g. after Close). }
    procedure Initialise(NumInputChannels, NumOutputChannels: Integer); overload;
    { Opens devices of exactly this type (no fallback to another type). }
    procedure Initialise(NumInputChannels, NumOutputChannels: Integer;
      const DeviceType: string); overload;
    procedure Initialise(NumInputChannels, NumOutputChannels: Integer;
      const DeviceType: string; const Preferred: TJuceAudioDeviceSetup); overload;
    procedure Close;
    procedure Restart;

    function DeviceTypeCount: Integer;
    function DeviceTypeName(TypeIndex: Integer): string;
    function DeviceTypeNames: TStringDynArray;
    function DeviceCount(TypeIndex: Integer; IsInput: Boolean): Integer;
    function DeviceName(TypeIndex: Integer; IsInput: Boolean; DeviceIndex: Integer): string;
    function DeviceNames(TypeIndex: Integer; IsInput: Boolean): TStringDynArray;
    function DefaultDeviceIndex(TypeIndex: Integer; IsInput: Boolean): Integer;
    procedure ApplySetup(const Value: TJuceAudioDeviceSetup; TreatAsChosenDevice: Boolean = True);

    function IsDeviceOpen: Boolean;
    function CurrentDeviceName: string;
    function SampleRate: Double;
    function BlockSize: Integer;
    function BitDepth: Integer;
    function InputLatency: Integer;
    function OutputLatency: Integer;
    function ActiveInputChannelCount: Integer;
    function ActiveOutputChannelCount: Integer;
    function ChannelNames(IsInput: Boolean): TStringDynArray;
    function AvailableSampleRates: TDoubleDynArray;
    function AvailableBufferSizes: TIntegerDynArray;
    function CpuUsage: Double;
    function XRunCount: Integer;
    { Exceptions caught in the callbacks (OnAudio, OnAudioStart/Stop,
      OnChange) since the last call. }
    function ConsumeCallbackErrorCount: Cardinal;
    procedure PlayTestSound;

    { MIDI inputs whose messages arrive in OnAudio's Midi view. }
    procedure SetMidiInputEnabled(const Identifier: string; Enabled: Boolean);
    function IsMidiInputEnabled(const Identifier: string): Boolean;
    { Queue one complete MIDI message for the next audio block. Any thread
      except the audio thread. }
    procedure AddMidiMessage(const Data: array of Byte);

    property Handle: PJuceCAudioDeviceManager read FHandle;
    property CurrentDeviceType: string read GetCurrentDeviceType write SetCurrentDeviceType;
    property Setup: TJuceAudioDeviceSetup read GetSetup write SetSetup;
    property OnAudio: TJuceAudioEvent read FOnAudio write SetOnAudio;
    property OnAudioStart: TJuceAudioStartEvent read FOnAudioStart write SetOnAudioStart;
    property OnAudioStop: TJuceNotifyEvent read FOnAudioStop write SetOnAudioStop;
    property OnChange: TJuceNotifyEvent read FOnChange write SetOnChange;
  end;

  { juce::MidiInput. The handler is fixed at construction. }
  TJuceMidiInput = class
  private
    FHandle: PJuceCMidiInput;
    FOnMessage: TJuceMidiInputEvent;
    FErrors: Integer;
    FHandlerThread: TThreadID; { the MIDI thread while it runs the handler, else 0 }
    FConstructed: Boolean;
    function GetName: string;
  public
    constructor Create(const Identifier: string; Handler: TJuceMidiInputEvent);
    destructor Destroy; override;
    { Closes the device before any subclass destructor runs, so the handler is
      never called on half-destroyed fields. Raises (and the input stays alive)
      inside any MIDI handler, so never FreeAndNil an input from a handler:
      the variable would already be nil while the input keeps running. }
    procedure BeforeDestruction; override;
    { Start is refused until construction has finished (see the device manager). }
    procedure AfterConstruction; override;
    procedure Start;
    procedure Stop;
    { Exceptions caught in the handler since the last call. }
    function ConsumeCallbackErrorCount: Cardinal;
    property Handle: PJuceCMidiInput read FHandle;
    property Name: string read GetName;
  end;

  { juce::MidiOutput }
  TJuceMidiOutput = class
  private
    FHandle: PJuceCMidiOutput;
    function GetName: string;
  public
    constructor Create(const Identifier: string);
    destructor Destroy; override;
    { Data must be exactly one complete MIDI message. }
    procedure Send(const Data: array of Byte);
    { Schedule a buffer; StartTimeMs on the JuceMillisecondCounter clock
      (<= 0 = now). }
    procedure SendBlock(Buffer: TJuceMidiBuffer; StartTimeMs, SampleRate: Double);
    procedure ClearPending;
    property Handle: PJuceCMidiOutput read FHandle;
    property Name: string read GetName;
  end;

  { Streams frames from an audio file. Treat files as untrusted input:
    decoding happens in JUCE's parsers. }
  TJuceAudioFileReader = class
  private
    FHandle: PJuceCAudioFileReader;
    function GetSampleRate: Double;
    function GetNumChannels: Integer;
    function GetLength: Int64;
    function GetBitsPerSample: Integer;
    function GetIsFloat: Boolean;
    function GetFormatName: string;
  public
    constructor Create(const FileName: string);
    destructor Destroy; override;
    { Mono files are copied to every channel of Dest; past the end reads 0. }
    procedure Read(Dest: TJuceAudioBuffer; DestStart, Count: Integer; FileStart: Int64);
    property Handle: PJuceCAudioFileReader read FHandle;
    property SampleRate: Double read GetSampleRate;
    property NumChannels: Integer read GetNumChannels;
    property Length: Int64 read GetLength;
    property BitsPerSample: Integer read GetBitsPerSample;
    property IsFloatingPoint: Boolean read GetIsFloat;
    property FormatName: string read GetFormatName;
  end;

  { Writes WAV, AIFF, FLAC or Ogg. The file is complete when freed. }
  TJuceAudioFileWriter = class
  private
    FHandle: PJuceCAudioFileWriter;
  public
    { FormatName: 'wav', 'aiff', 'flac', 'ogg' or '' for "from extension".
      BitsPerSample: WAV/AIFF 8/16/24/32, FLAC 16/24; Ogg ignores it. }
    constructor Create(const FileName: string; SampleRate: Double; NumChannels: Integer;
      BitsPerSample: Integer = 24; const FormatName: string = ''; QualityIndex: Integer = 0);
    destructor Destroy; override;
    procedure Write(Source: TJuceAudioBuffer; StartSample, Count: Integer);
    procedure WriteChannels(Channels: PJuceChannelArray; NumChannels, Count: Integer);
    procedure Flush;
    property Handle: PJuceCAudioFileWriter read FHandle;
  end;

{ Library. JuceInitialise masks floating-point exceptions on the calling
  (main) thread, because JUCE code running from your message loop (timers,
  device notifications) assumes C/C++ defaults; the previous mask is restored
  by the matching JuceShutdown. Pass False to leave the FPU alone. }
procedure JuceInitialise(MaskFPUExceptions: Boolean = True);
procedure JuceShutdown;
function JuceIsInitialised: Boolean;
procedure JuceDispatchMessages(Milliseconds: Integer = 0);
function JuceVersion: string;
function JuceMillisecondCounter: Double;

{ Audio files }
function JuceLoadAudioFile(const FileName: string; out SampleRate: Double): TJuceAudioBuffer;
{ e.g. '*.wav;*.aiff;*.flac;...' }
function JuceAudioFileWildcard: string;

{ MIDI devices }
function JuceMidiInputDevices: TJuceMidiDeviceInfoArray;
function JuceMidiOutputDevices: TJuceMidiDeviceInfoArray;
{ '' when there is none. }
function JuceDefaultMidiInput: string;
function JuceDefaultMidiOutput: string;

{ MIDI message helpers. Channel is 1..16; values are clamped to 0..127. }
function MidiNoteOn(Channel, Note, Velocity: Integer): TBytes;
function MidiNoteOff(Channel, Note: Integer; Velocity: Integer = 0): TBytes;
function MidiControlChange(Channel, Controller, Value: Integer): TBytes;
function MidiProgramChange(Channel, Program_: Integer): TBytes;
function MidiPitchBend(Channel, Value14Bit: Integer): TBytes;
function MidiAllNotesOff(Channel: Integer): TBytes;
function MidiDescription(const Data: array of Byte): string; overload;
function MidiDescription(Data: PByte; Size: Integer): string; overload;
function MidiNoteName(Note: Integer; UseSharps: Boolean = True;
  IncludeOctave: Boolean = True; MiddleCOctave: Integer = 3): string;
function MidiNoteToHz(Note: Integer; FrequencyOfA: Double = 440.0): Double;

{ Helpers for working with the raw C API. }
procedure JuceCheck(Code: TJuceCResult);
function JuceFromUtf8(P: PAnsiChar): string;
function JuceToUtf8(const S: string): UTF8String;

implementation

uses
  {$IF not defined(FPC) and defined(MSWINDOWS)} Winapi.Windows, {$IFEND} { Delphi: GetCurrentThreadId }
  Math;

{ ---------------------------------------------------------------------------- }
{ String plumbing                                                              }
{ ---------------------------------------------------------------------------- }

procedure CheckAbi; forward;

{ Object arguments may be nil by mistake: raise a clean EJuceError rather than
  dereferencing nil (an access violation inside a library is far harder to debug). }
function HandleOf(Obj: TObject): Pointer; forward;

{ CheckNotLive note: "Mgr.Create;" on an existing object (instead of
  "Mgr := T.Create;") used to replace its handle and orphan an open device,
  whose callbacks then outlived the object. Constructors now keep the handle
  (managers close their device, MIDI inputs stop) and return. Raising is not an
  option: FPC destroys the object when a constructor called that way raises,
  and under FPC AfterConstruction runs again. Never write "Obj.Create;". }

type
  { Every text getter in the C API has the shape (args..., buffer, size*);
    capture the args and dispatch by kind so one retry loop serves them all. }
  TStrKind = (skJuceVersion, skDeviceTypeName, skCurrentDeviceType, skDeviceName,
    skCurrentDeviceName, skChannelName, skMidiListName, skMidiListId, skDefaultMidi,
    skMidiInputName, skMidiOutputName, skNoteName, skDescription, skWildcard, skFileFormat);

  TStrArgs = record
    Kind: TStrKind;
    Handle: Pointer;
    A, B, C, D: Integer;
    Data: PByte;
    Size: TJuceCSize;
  end;

function CallStr(const Args: TStrArgs; Buf: PAnsiChar; Size: PJuceCSize): TJuceCResult;
begin
  case Args.Kind of
    skJuceVersion:       Result := juce_c_get_juce_version(Buf, Size);
    skDeviceTypeName:    Result := juce_c_audio_device_manager_get_device_type_name(Args.Handle, Args.A, Buf, Size);
    skCurrentDeviceType: Result := juce_c_audio_device_manager_get_current_device_type(Args.Handle, Buf, Size);
    skDeviceName:        Result := juce_c_audio_device_manager_get_device_name(Args.Handle, Args.A, Args.B, Args.C, Buf, Size);
    skCurrentDeviceName: Result := juce_c_audio_device_manager_get_device_name_current(Args.Handle, Buf, Size);
    skChannelName:       Result := juce_c_audio_device_manager_get_channel_name(Args.Handle, Args.A, Args.B, Buf, Size);
    skMidiListName:      Result := juce_c_midi_device_list_get_name(Args.Handle, Args.A, Buf, Size);
    skMidiListId:        Result := juce_c_midi_device_list_get_identifier(Args.Handle, Args.A, Buf, Size);
    skDefaultMidi:       Result := juce_c_midi_get_default_device_identifier(Args.A, Buf, Size);
    skMidiInputName:     Result := juce_c_midi_input_get_name(Args.Handle, Buf, Size);
    skMidiOutputName:    Result := juce_c_midi_output_get_name(Args.Handle, Buf, Size);
    skNoteName:          Result := juce_c_midi_get_note_name(Args.A, Args.B, Args.C, Args.D, Buf, Size);
    skDescription:       Result := juce_c_midi_message_get_description(Args.Data, Args.Size, Buf, Size);
    skWildcard:          Result := juce_c_audio_file_get_wildcard(Buf, Size);
    skFileFormat:        Result := juce_c_audio_file_reader_get_format_name(Args.Handle, Buf, Size);
  else
    Result := JUCE_C_INVALID_ARGUMENT;
  end;
end;

function FetchStr(const Args: TStrArgs): string;
var
  Small: array[0..511] of AnsiChar;
  Big: array of AnsiChar;
  Size: TJuceCSize;
  R: TJuceCResult;
  Attempt: Integer;
begin
  CheckAbi;
  Size := SizeOf(Small);
  R := CallStr(Args, @Small[0], @Size);
  if R = JUCE_C_OK then
    Exit(JuceFromUtf8(@Small[0]));

  { The text may grow between calls (e.g. device lists): retry a few times. }
  for Attempt := 1 to 4 do
  begin
    if R <> JUCE_C_BUFFER_TOO_SMALL then
      JuceCheck(R);
    SetLength(Big, Size);
    R := CallStr(Args, @Big[0], @Size);
    if R = JUCE_C_OK then
      Exit(JuceFromUtf8(@Big[0]));
  end;
  JuceCheck(R);
  Result := '';
end;

function StrArgs(Kind: TStrKind; Handle: Pointer = nil; A: Integer = 0; B: Integer = 0;
  C: Integer = 0; D: Integer = 0): TStrArgs;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Kind := Kind;
  Result.Handle := Handle;
  Result.A := A;
  Result.B := B;
  Result.C := C;
  Result.D := D;
end;

function CStrLen(P: PAnsiChar): Integer;
begin
  Result := 0;
  while P[Result] <> #0 do
    Inc(Result);
end;

{ Exactly Len bytes are read: never scans past the given length. }
function Utf8BytesToString(P: PAnsiChar; Len: Integer): string;
var
  R: RawByteString;
begin
  if (P = nil) or (Len <= 0) then
    Exit('');
  SetString(R, P, Len);
  SetCodePage(R, CP_UTF8, False);
  Result := string(R);
end;

function JuceFromUtf8(P: PAnsiChar): string;
begin
  if P = nil then
    Exit('');
  Result := Utf8BytesToString(P, CStrLen(P));
end;

function JuceToUtf8(const S: string): UTF8String;
begin
  { An embedded #0 would silently cut the text at the C boundary ("evil.wav"#0".txt"
    opens evil.wav): refuse it instead. }
  if Pos(#0, S) > 0 then
    raise EJuceError.CreateCode(JUCE_C_INVALID_ARGUMENT, 'Text passed to the audio library contains a NUL character');
  Result := UTF8String(S);
end;

function HandleOf(Obj: TObject): Pointer;
begin
  if Obj = nil then
    raise EJuceError.CreateCode(JUCE_C_INVALID_ARGUMENT, 'A nil buffer object was passed to the audio library');
  if Obj is TJuceAudioBuffer then
    Result := TJuceAudioBuffer(Obj).Handle
  else if Obj is TJuceMidiBuffer then
    Result := TJuceMidiBuffer(Obj).Handle
  else
    raise EJuceError.CreateCode(JUCE_C_INVALID_ARGUMENT, 'Unexpected object type: ' + Obj.ClassName);
end;

{ Fixed char[256] fields: never read past the array, even without a NUL. }
function FixedToString(const Name: array of AnsiChar): string;
var
  N: Integer;
begin
  N := 0;
  while (N < Length(Name)) and (Name[N] <> #0) do
    Inc(N);
  Result := Utf8BytesToString(@Name[0], N);
end;

procedure StringToFixed(var Dest: array of AnsiChar; const Name: string);
var
  U: UTF8String;
begin
  FillChar(Dest[0], Length(Dest), 0);
  U := JuceToUtf8(Name);
  if Length(U) > High(Dest) then
    raise EJuceError.CreateCode(JUCE_C_INVALID_ARGUMENT,
      Format('Device name is longer than %d UTF-8 bytes: %s', [High(Dest), Name]));
  if Length(U) > 0 then
    Move(PAnsiChar(U)^, Dest[0], Length(U));
end;

{ ---------------------------------------------------------------------------- }
{ Errors                                                                       }
{ ---------------------------------------------------------------------------- }

constructor EJuceError.CreateCode(ACode: Integer; const AMessage: string);
begin
  inherited Create(AMessage);
  FCode := ACode;
end;

procedure JuceCheck(Code: TJuceCResult);
var
  Msg: string;
begin
  if Code = JUCE_C_OK then
    Exit;
  Msg := JuceFromUtf8(juce_c_get_last_error_message);
  if Msg = '' then
    Msg := Format('juce_c_audio error %d', [Code]);
  raise EJuceError.CreateCode(Code, Msg);
end;

function BytesPtr(const Data: array of Byte): PByte;
begin
  if Length(Data) = 0 then
    Result := nil
  else
    Result := @Data[0];
end;

function AtomicInc(var Target: Integer): Integer;
begin
{$IFDEF FPC}
  Result := InterLockedIncrement(Target);
{$ELSE}
  Result := AtomicIncrement(Target);
{$ENDIF}
end;

function AtomicTake(var Target: Integer): Integer;
begin
{$IFDEF FPC}
  Result := InterLockedExchange(Target, 0);
{$ELSE}
  Result := AtomicExchange(Target, 0);
{$ENDIF}
end;

{ ---------------------------------------------------------------------------- }
{ Setup conversion                                                             }
{ ---------------------------------------------------------------------------- }

function SetupToC(const S: TJuceAudioDeviceSetup): TJuceCAudioDeviceSetup;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.StructSize := SizeOf(Result);
  Result.BufferSize := S.BufferSize;
  Result.SampleRate := S.SampleRate;
  Move(S.InputChannels, Result.InputChannels, SizeOf(Result.InputChannels));
  Move(S.OutputChannels, Result.OutputChannels, SizeOf(Result.OutputChannels));
  Result.UseDefaultInputChannels := Ord(S.UseDefaultInputChannels);
  Result.UseDefaultOutputChannels := Ord(S.UseDefaultOutputChannels);
  StringToFixed(Result.OutputDeviceName, S.OutputDeviceName);
  StringToFixed(Result.InputDeviceName, S.InputDeviceName);
end;

function SetupFromC(const C: TJuceCAudioDeviceSetup): TJuceAudioDeviceSetup;
begin
  Result.OutputDeviceName := FixedToString(C.OutputDeviceName);
  Result.InputDeviceName := FixedToString(C.InputDeviceName);
  Result.SampleRate := C.SampleRate;
  Result.BufferSize := C.BufferSize;
  Move(C.InputChannels, Result.InputChannels, SizeOf(Result.InputChannels));
  Move(C.OutputChannels, Result.OutputChannels, SizeOf(Result.OutputChannels));
  Result.UseDefaultInputChannels := C.UseDefaultInputChannels <> 0;
  Result.UseDefaultOutputChannels := C.UseDefaultOutputChannels <> 0;
end;

{ ---------------------------------------------------------------------------- }
{ Library                                                                      }
{ ---------------------------------------------------------------------------- }

var
  { The thread that called JuceInitialise (JUCE's message thread); until then
    the thread that ran unit initialisation. }
  GMessageThreadID: TThreadID;
  GInitCount: Integer = 0;
  GSavedMask: {$IFDEF FPC}TFPUExceptionMask{$ELSE}TArithmeticExceptionMask{$ENDIF};
  GMaskedFPU: Boolean = False;
  { Set first in finalization, on whatever thread: callbacks then return at once
    (a leaked manager or MIDI input must not run handlers in a finalised RTL). }
  GFinalizing: Boolean = False;

procedure CheckMessageThread(const What: string); forward;

const
  AllFPUExceptions = [exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision];

var
  GAbiChecked: Boolean = False;

{ The library and this binding must agree on the ABI. Checked on first use of
  anything (file and buffer users never call JuceInitialise). }
procedure CheckAbi;
begin
  if GAbiChecked then
    Exit;
  if juce_c_get_abi_version <> JUCE_C_AUDIO_ABI_VERSION then
    raise EJuceError.CreateCode(JUCE_C_INVALID_STATE,
      Format('%s ABI version %d does not match the Pascal binding (%d)',
        [JuceCAudioLib, juce_c_get_abi_version, JUCE_C_AUDIO_ABI_VERSION]));
  if (juce_c_audio_device_setup_size <> SizeOf(TJuceCAudioDeviceSetup))
    or (SizeOf(TJuceChannelSet) <> 32) then
    raise EJuceError.CreateCode(JUCE_C_INVALID_STATE, 'Record layout mismatch with ' + JuceCAudioLib);
  GAbiChecked := True;
end;

procedure JuceInitialise(MaskFPUExceptions: Boolean);
begin
  CheckAbi;

  JuceCheck(juce_c_initialise);
  Inc(GInitCount);
  if GInitCount = 1 then
    GMessageThreadID := GetCurrentThreadId; { JUCE's message thread from now on }
  if (GInitCount = 1) and MaskFPUExceptions then
  begin
    GSavedMask := GetExceptionMask;
    SetExceptionMask(AllFPUExceptions);
    GMaskedFPU := True;
  end;
end;

procedure JuceShutdown;
begin
  if GInitCount = 0 then
    Exit;
  JuceCheck(juce_c_shutdown);
  Dec(GInitCount);
  if (GInitCount = 0) and GMaskedFPU then
  begin
    SetExceptionMask(GSavedMask);
    GMaskedFPU := False;
  end;
end;

function JuceIsInitialised: Boolean;
begin
  Result := juce_c_is_initialised <> 0;
end;

procedure JuceDispatchMessages(Milliseconds: Integer);
begin
  JuceCheck(juce_c_dispatch_messages(Milliseconds));
end;

function JuceVersion: string;
begin
  Result := FetchStr(StrArgs(skJuceVersion));
end;

function JuceMillisecondCounter: Double;
begin
  Result := juce_c_get_millisecond_counter_hires;
end;

{ ---------------------------------------------------------------------------- }
{ MIDI device enumeration                                                      }
{ ---------------------------------------------------------------------------- }

function MidiDevices(IsInput: Boolean): TJuceMidiDeviceInfoArray;
var
  List: PJuceCMidiDeviceList;
  I, N: Integer;
begin
  CheckAbi;
  Result := nil;
  JuceCheck(juce_c_midi_device_list_create(Ord(IsInput), @List));
  try
    N := juce_c_midi_device_list_get_count(List);
    SetLength(Result, N);
    for I := 0 to N - 1 do
    begin
      Result[I].Name := FetchStr(StrArgs(skMidiListName, List, I));
      Result[I].Identifier := FetchStr(StrArgs(skMidiListId, List, I));
    end;
  finally
    juce_c_midi_device_list_destroy(List);
  end;
end;

function JuceMidiInputDevices: TJuceMidiDeviceInfoArray;
begin
  Result := MidiDevices(True);
end;

function JuceMidiOutputDevices: TJuceMidiDeviceInfoArray;
begin
  Result := MidiDevices(False);
end;

function JuceDefaultMidiInput: string;
begin
  Result := FetchStr(StrArgs(skDefaultMidi, nil, 1));
end;

function JuceDefaultMidiOutput: string;
begin
  Result := FetchStr(StrArgs(skDefaultMidi, nil, 0));
end;

{ ---------------------------------------------------------------------------- }
{ MIDI message helpers                                                         }
{ ---------------------------------------------------------------------------- }

function StatusByte(Status, Channel: Integer): Byte;
begin
  Result := Byte(Status or ((EnsureRange(Channel, 1, 16) - 1) and $0F));
end;

function Bytes3(B0, B1, B2: Integer): TBytes;
begin
  Result := nil;
  SetLength(Result, 3);
  Result[0] := Byte(B0);
  Result[1] := Byte(EnsureRange(B1, 0, 127));
  Result[2] := Byte(EnsureRange(B2, 0, 127));
end;

function MidiNoteOn(Channel, Note, Velocity: Integer): TBytes;
begin
  Result := Bytes3(StatusByte($90, Channel), Note, Velocity);
end;

function MidiNoteOff(Channel, Note: Integer; Velocity: Integer): TBytes;
begin
  Result := Bytes3(StatusByte($80, Channel), Note, Velocity);
end;

function MidiControlChange(Channel, Controller, Value: Integer): TBytes;
begin
  Result := Bytes3(StatusByte($B0, Channel), Controller, Value);
end;

function MidiProgramChange(Channel, Program_: Integer): TBytes;
begin
  Result := nil;
  SetLength(Result, 2);
  Result[0] := StatusByte($C0, Channel);
  Result[1] := Byte(EnsureRange(Program_, 0, 127));
end;

function MidiPitchBend(Channel, Value14Bit: Integer): TBytes;
var
  V: Integer;
begin
  V := EnsureRange(Value14Bit, 0, $3FFF);
  Result := Bytes3(StatusByte($E0, Channel), V and $7F, V shr 7);
end;

function MidiAllNotesOff(Channel: Integer): TBytes;
begin
  Result := MidiControlChange(Channel, 123, 0);
end;

function MidiDescription(Data: PByte; Size: Integer): string;
var
  Args: TStrArgs;
begin
  if Size < 0 then
    raise EJuceError.CreateCode(JUCE_C_INVALID_ARGUMENT, 'MidiDescription: negative size');
  Args := StrArgs(skDescription);
  Args.Data := Data;
  Args.Size := Size;
  Result := FetchStr(Args);
end;

function MidiDescription(const Data: array of Byte): string;
begin
  Result := MidiDescription(BytesPtr(Data), Length(Data));
end;

function MidiNoteName(Note: Integer; UseSharps, IncludeOctave: Boolean; MiddleCOctave: Integer): string;
begin
  Result := FetchStr(StrArgs(skNoteName, nil, Note, Ord(UseSharps), Ord(IncludeOctave), MiddleCOctave));
end;

function MidiNoteToHz(Note: Integer; FrequencyOfA: Double): Double;
begin
  Result := juce_c_midi_get_note_frequency(Note, FrequencyOfA);
end;

{ ---------------------------------------------------------------------------- }
{ TJuceMidiView / MIDI iteration                                               }
{ ---------------------------------------------------------------------------- }

type
  TVisitContext = record
    Handler: TMethod;
    Error: Pointer; { acquired exception object, re-raised after iteration }
  end;
  PVisitContext = ^TVisitContext;

function MidiVisitorTrampoline(UserData: Pointer; Message: PByte; MessageSize: Int32;
  SamplePosition: Int32): Int32; cdecl;
var
  Ctx: PVisitContext;
begin
  Result := 0;
  Ctx := PVisitContext(UserData);
  try
    TJuceMidiEventHandler(Ctx^.Handler)(Message, MessageSize, SamplePosition);
  except
    Ctx^.Error := AcquireExceptionObject; { never unwind through C++ }
    Result := 1;
  end;
end;

procedure EnumerateHandle(Buffer: PJuceCMidiBuffer; Handler: TJuceMidiEventHandler);
var
  Ctx: TVisitContext;
  R: TJuceCResult;
begin
  if (Buffer = nil) or not Assigned(Handler) then
    Exit;
  Ctx.Handler := TMethod(Handler);
  Ctx.Error := nil;
  R := juce_c_midi_buffer_for_each(Buffer, MidiVisitorTrampoline, @Ctx);
  if Ctx.Error <> nil then
    raise TObject(Ctx.Error);
  JuceCheck(R);
end;

function TJuceMidiView.Count: Integer;
begin
  Result := juce_c_midi_buffer_get_event_count(Handle);
end;

procedure TJuceMidiView.Enumerate(Handler: TJuceMidiEventHandler);
begin
  EnumerateHandle(Handle, Handler);
end;

{ ---------------------------------------------------------------------------- }
{ TJuceAudioBuffer                                                             }
{ ---------------------------------------------------------------------------- }

constructor TJuceAudioBuffer.Create(NumChannels, NumSamples: Integer);
begin
  inherited Create;
  if FHandle <> nil then
    Exit; { "Obj.Create;" on a live object: leave it untouched (see CheckNotLive note) }
  CheckAbi;
  JuceCheck(juce_c_audio_buffer_create(NumChannels, NumSamples, @FHandle));
end;

constructor TJuceAudioBuffer.CreateFromHandle(AHandle: PJuceCAudioBuffer);
begin
  inherited Create;
  if FHandle <> nil then
  begin
    juce_c_audio_buffer_destroy(AHandle); { we were given ownership: don't leak it }
    Exit;
  end;
  if AHandle = nil then
    raise EJuceError.CreateCode(JUCE_C_INVALID_ARGUMENT, 'TJuceAudioBuffer: nil handle');
  FHandle := AHandle;
end;

destructor TJuceAudioBuffer.Destroy;
begin
  if FHandle <> nil then
    juce_c_audio_buffer_destroy(FHandle);
  inherited;
end;

function TJuceAudioBuffer.GetNumChannels: Integer;
begin
  Result := juce_c_audio_buffer_get_channel_count(FHandle);
end;

function TJuceAudioBuffer.GetNumSamples: Integer;
begin
  Result := juce_c_audio_buffer_get_sample_count(FHandle);
end;

function TJuceAudioBuffer.GetChannel(Index: Integer): PJuceSampleArray;
var
  P: PSingle;
begin
  JuceCheck(juce_c_audio_buffer_get_write_pointer(FHandle, Index, @P));
  Result := PJuceSampleArray(P);
end;

procedure TJuceAudioBuffer.SetSize(NumChannels, NumSamples: Integer; KeepContent: Boolean);
begin
  JuceCheck(juce_c_audio_buffer_set_size(FHandle, NumChannels, NumSamples, Ord(KeepContent)));
end;

procedure TJuceAudioBuffer.Clear;
begin
  JuceCheck(juce_c_audio_buffer_clear(FHandle));
end;

procedure TJuceAudioBuffer.Clear(StartSample, Count: Integer);
begin
  JuceCheck(juce_c_audio_buffer_clear_region(FHandle, StartSample, Count));
end;

procedure TJuceAudioBuffer.ApplyGain(Gain: Single);
begin
  JuceCheck(juce_c_audio_buffer_apply_gain(FHandle, Gain));
end;

procedure TJuceAudioBuffer.ApplyGainRamp(StartSample, Count: Integer; StartGain, EndGain: Single);
begin
  JuceCheck(juce_c_audio_buffer_apply_gain_ramp(FHandle, StartSample, Count, StartGain, EndGain));
end;

procedure TJuceAudioBuffer.AddFrom(DestChannel, DestStart: Integer; Source: TJuceAudioBuffer;
  SourceChannel, SourceStart, Count: Integer; Gain: Single);
begin
  JuceCheck(juce_c_audio_buffer_add_from(FHandle, DestChannel, DestStart, HandleOf(Source),
    SourceChannel, SourceStart, Count, Gain));
end;

procedure TJuceAudioBuffer.CopyFrom(DestChannel, DestStart: Integer; Source: TJuceAudioBuffer;
  SourceChannel, SourceStart, Count: Integer);
begin
  JuceCheck(juce_c_audio_buffer_copy_from(FHandle, DestChannel, DestStart, HandleOf(Source),
    SourceChannel, SourceStart, Count));
end;

function TJuceAudioBuffer.Magnitude(Channel, StartSample, Count: Integer): Single;
begin
  JuceCheck(juce_c_audio_buffer_get_magnitude(FHandle, Channel, StartSample, Count, @Result));
end;

function TJuceAudioBuffer.RMSLevel(Channel, StartSample, Count: Integer): Single;
begin
  JuceCheck(juce_c_audio_buffer_get_rms_level(FHandle, Channel, StartSample, Count, @Result));
end;

{ ---------------------------------------------------------------------------- }
{ TJuceMidiBuffer                                                              }
{ ---------------------------------------------------------------------------- }

constructor TJuceMidiBuffer.Create;
begin
  inherited Create;
  if FHandle <> nil then
    Exit; { "Obj.Create;" on a live object: leave it untouched (see CheckNotLive note) }
  CheckAbi;
  JuceCheck(juce_c_midi_buffer_create(@FHandle));
end;

destructor TJuceMidiBuffer.Destroy;
begin
  if FHandle <> nil then
    juce_c_midi_buffer_destroy(FHandle);
  inherited;
end;

function TJuceMidiBuffer.GetCount: Integer;
begin
  Result := juce_c_midi_buffer_get_event_count(FHandle);
end;

procedure TJuceMidiBuffer.Clear;
begin
  JuceCheck(juce_c_midi_buffer_clear(FHandle));
end;

procedure TJuceMidiBuffer.Add(const Data: array of Byte; SamplePosition: Integer);
begin
  JuceCheck(juce_c_midi_buffer_add_event(FHandle, BytesPtr(Data), Length(Data), SamplePosition));
end;

procedure TJuceMidiBuffer.Enumerate(Handler: TJuceMidiEventHandler);
begin
  EnumerateHandle(FHandle, Handler);
end;

{ ---------------------------------------------------------------------------- }
{ TJuceAudioDeviceManager                                                      }
{ ---------------------------------------------------------------------------- }

procedure SilenceChannels(Channels: PJuceChannelArray; NumChannels, NumSamples: Integer);
var
  Ch, I: Integer;
begin
  if Channels = nil then
    Exit;
  { Runs inside an except handler: must not raise itself, even with -Cr. }
  try
    for Ch := 0 to Min(NumChannels, (High(TJuceChannelArray) + 1)) - 1 do
      if Channels^[Ch] <> nil then
        for I := 0 to Min(NumSamples, (High(TJuceSampleArray) + 1)) - 1 do
          Channels^[Ch]^[I] := 0;
  except
  end;
end;

procedure AudioTrampoline(UserData: Pointer; InputChannels: PJuceChannelArray;
  InputChannelCount: Int32; OutputChannels: PJuceChannelArray; OutputChannelCount: Int32;
  SampleCount: Int32; Midi: PJuceCMidiBuffer); cdecl;
var
  Mgr: TJuceAudioDeviceManager;
  View: TJuceMidiView;
begin
  if GFinalizing then
  begin
    SilenceChannels(OutputChannels, OutputChannelCount, SampleCount);
    Exit;
  end;
  Mgr := TJuceAudioDeviceManager(UserData);
  try
    if Assigned(Mgr.FOnAudio) then
    begin
      View.Handle := Midi;
      Mgr.FOnAudio(Mgr, InputChannels, InputChannelCount, OutputChannels,
        OutputChannelCount, SampleCount, View);
    end;
  except
    juce_c_audio_device_manager_report_callback_error(Mgr.FHandle);
    SilenceChannels(OutputChannels, OutputChannelCount, SampleCount); { never play a half-written block }
  end;
end;

procedure AudioStartTrampoline(UserData: Pointer; SampleRate: Double; ExpectedBlockSize: Int32); cdecl;
var
  Mgr: TJuceAudioDeviceManager;
begin
  if GFinalizing then
    Exit;
  Mgr := TJuceAudioDeviceManager(UserData);
  try
    Inc(Mgr.FInCallback);
    try
      if Assigned(Mgr.FOnAudioStart) then
        Mgr.FOnAudioStart(Mgr, SampleRate, ExpectedBlockSize);
    finally
      Dec(Mgr.FInCallback);
    end;
  except
    juce_c_audio_device_manager_report_callback_error(Mgr.FHandle);
  end;
end;

procedure AudioStopTrampoline(UserData: Pointer); cdecl;
var
  Mgr: TJuceAudioDeviceManager;
begin
  if GFinalizing then
    Exit;
  Mgr := TJuceAudioDeviceManager(UserData);
  try
    Inc(Mgr.FInCallback);
    try
      if Assigned(Mgr.FOnAudioStop) then
        Mgr.FOnAudioStop(Mgr);
    finally
      Dec(Mgr.FInCallback);
    end;
  except
    juce_c_audio_device_manager_report_callback_error(Mgr.FHandle);
  end;
end;

procedure ChangeTrampoline(UserData: Pointer); cdecl;
var
  Mgr: TJuceAudioDeviceManager;
begin
  if GFinalizing then
    Exit;
  Mgr := TJuceAudioDeviceManager(UserData);
  try
    Inc(Mgr.FInCallback);
    try
      if Assigned(Mgr.FOnChange) then
        Mgr.FOnChange(Mgr);
    finally
      Dec(Mgr.FInCallback);
    end;
  except
    juce_c_audio_device_manager_report_callback_error(Mgr.FHandle);
  end;
end;

{ Managers still alive when the program ends (a forgotten Free, or an
  exception that skipped it) keep their audio thread calling into Pascal
  while the RTL finalises. Message thread only. }
var
  GLiveManagers: array of TJuceAudioDeviceManager;

procedure RegisterLive(M: TJuceAudioDeviceManager);
begin
  SetLength(GLiveManagers, Length(GLiveManagers) + 1);
  GLiveManagers[High(GLiveManagers)] := M;
end;

procedure UnregisterLive(M: TJuceAudioDeviceManager);
var
  I: Integer;
begin
  for I := High(GLiveManagers) downto 0 do
    if GLiveManagers[I] = M then
    begin
      GLiveManagers[I] := GLiveManagers[High(GLiveManagers)];
      SetLength(GLiveManagers, Length(GLiveManagers) - 1);
      Exit;
    end;
end;

procedure CloseLiveManagers;
var
  I: Integer;
begin
  for I := High(GLiveManagers) downto 0 do
    if GLiveManagers[I].FHandle <> nil then
    begin
      juce_c_audio_device_manager_close(GLiveManagers[I].FHandle); { result ignored: best effort }
      juce_c_audio_device_manager_set_change_callback(GLiveManagers[I].FHandle, nil, nil);
    end;
end;

constructor TJuceAudioDeviceManager.Create;
var
  Callbacks: TJuceCAudioCallbacks;
begin
  inherited Create;
  if FHandle <> nil then
  begin
    { "Obj.Create;" on a live object: back to the just-constructed state, so
      subclass constructor code (e.g. OnAudio := ...) neither trips CheckClosed
      nor, if it raises and FPC destroys the object, leaves callbacks running. }
    juce_c_audio_device_manager_close(FHandle); { result ignored }
    Exit;
  end;
  CheckAbi;
  FillChar(Callbacks, SizeOf(Callbacks), 0);
  Callbacks.StructSize := SizeOf(Callbacks);
  Callbacks.UserData := Self;
  Callbacks.OnAudio := AudioTrampoline;
  Callbacks.OnStart := AudioStartTrampoline;
  Callbacks.OnStop := AudioStopTrampoline;
  JuceCheck(juce_c_audio_device_manager_create(@Callbacks, @FHandle));
  JuceCheck(juce_c_audio_device_manager_set_change_callback(FHandle, ChangeTrampoline, Self));
  RegisterLive(Self);
end;

procedure TJuceAudioDeviceManager.AfterConstruction;
begin
  inherited;
  FConstructed := True;
end;

procedure TJuceAudioDeviceManager.CheckConstructed;
begin
  if not FConstructed then
    raise EJuceError.CreateCode(JUCE_C_INVALID_STATE,
      'Open audio devices after the constructor has returned (or in AfterConstruction): ' +
      'a constructor that raised later would leave the audio thread calling into a half-destroyed object');
end;

procedure TJuceAudioDeviceManager.BeforeDestruction;
begin
  if FHandle <> nil then { nil: a constructor failed; let its own error through }
  begin
    CheckMessageThread('Freeing a device manager');
    if FInCallback > 0 then
      raise EJuceError.CreateCode(JUCE_C_INVALID_STATE,
        'A device manager cannot be freed from inside its own OnAudioStart, OnAudioStop or OnChange');
    { Stop callbacks before any destructor body frees what handlers use. }
    if IsDeviceOpen then
      JuceCheck(juce_c_audio_device_manager_close(FHandle));
    { A close queues a change notification, and a subclass destructor that pumps
      messages would deliver it to freed fields. }
    juce_c_audio_device_manager_set_change_callback(FHandle, nil, nil);
    FOnAudio := nil;
    FOnAudioStart := nil;
    FOnAudioStop := nil;
    FOnChange := nil;
  end;
  inherited;
end;

destructor TJuceAudioDeviceManager.Destroy;
begin
  { Only a constructed manager is registered, and only on the message thread: a
    constructor that failed on another thread must not walk the list there. }
  if FHandle <> nil then
    UnregisterLive(Self);
  if FHandle <> nil then
    JuceCheck(juce_c_audio_device_manager_destroy(FHandle)); { no callbacks after this returns }
  FHandle := nil;
  inherited;
end;

procedure CheckMessageThread(const What: string);
begin
  if GetCurrentThreadId <> GMessageThreadID then
    raise EJuceError.CreateCode(JUCE_C_INVALID_STATE,
      What + ' must happen on the thread that called JuceInitialise');
end;

procedure TJuceAudioDeviceManager.CheckClosed(const What: string);
begin
  { Handlers are read by the audio thread: change them only on the JUCE
    message thread, and only while no device is open (a method pointer is two
    words and could otherwise be read half-written). }
  CheckMessageThread('Changing ' + What);
  if (FHandle <> nil) and IsDeviceOpen then
    raise EJuceError.CreateCode(JUCE_C_INVALID_STATE,
      What + ' can only be changed while no device is open (call Close first)');
end;

procedure TJuceAudioDeviceManager.SetOnAudio(const Value: TJuceAudioEvent);
begin
  CheckClosed('OnAudio');
  FOnAudio := Value;
end;

procedure TJuceAudioDeviceManager.SetOnAudioStart(const Value: TJuceAudioStartEvent);
begin
  CheckClosed('OnAudioStart');
  FOnAudioStart := Value;
end;

procedure TJuceAudioDeviceManager.SetOnAudioStop(const Value: TJuceNotifyEvent);
begin
  CheckClosed('OnAudioStop');
  FOnAudioStop := Value;
end;

procedure TJuceAudioDeviceManager.SetOnChange(const Value: TJuceNotifyEvent);
begin
  { OnChange runs on the message thread, so only the thread check is needed. }
  CheckMessageThread('Changing OnChange');
  FOnChange := Value;
end;

procedure TJuceAudioDeviceManager.AddVirtualDeviceType(Realtime: Boolean; Input: TJuceVirtualInput);
var
  Options: TJuceCVirtualDeviceOptions;
begin
  FillChar(Options, SizeOf(Options), 0);
  Options.StructSize := SizeOf(Options);
  Options.Realtime := Ord(Realtime);
  Options.InputSignal := Ord(Input);
  JuceCheck(juce_c_audio_device_manager_add_virtual_device_type(FHandle, @Options));
end;

procedure TJuceAudioDeviceManager.SimulateXRun;
begin
  JuceCheck(juce_c_audio_device_manager_simulate_xrun(FHandle));
end;

procedure TJuceAudioDeviceManager.Initialise(NumInputChannels, NumOutputChannels: Integer);
begin
  CheckConstructed;
  JuceCheck(juce_c_audio_device_manager_initialize(FHandle, NumInputChannels, NumOutputChannels));
end;

procedure TJuceAudioDeviceManager.Initialise(NumInputChannels, NumOutputChannels: Integer;
  const DeviceType: string);
var
  U: UTF8String;
begin
  CheckConstructed;
  U := JuceToUtf8(DeviceType);
  JuceCheck(juce_c_audio_device_manager_initialize_with_setup(FHandle, NumInputChannels,
    NumOutputChannels, PAnsiChar(U), nil));
end;

procedure TJuceAudioDeviceManager.Initialise(NumInputChannels, NumOutputChannels: Integer;
  const DeviceType: string; const Preferred: TJuceAudioDeviceSetup);
var
  U: UTF8String;
  C: TJuceCAudioDeviceSetup;
begin
  CheckConstructed;
  U := JuceToUtf8(DeviceType);
  C := SetupToC(Preferred);
  JuceCheck(juce_c_audio_device_manager_initialize_with_setup(FHandle, NumInputChannels,
    NumOutputChannels, PAnsiChar(U), @C));
end;

procedure TJuceAudioDeviceManager.Close;
begin
  JuceCheck(juce_c_audio_device_manager_close(FHandle));
end;

procedure TJuceAudioDeviceManager.Restart;
begin
  CheckConstructed;
  JuceCheck(juce_c_audio_device_manager_restart(FHandle));
end;

function TJuceAudioDeviceManager.DeviceTypeCount: Integer;
begin
  Result := juce_c_audio_device_manager_get_device_type_count(FHandle);
end;

function TJuceAudioDeviceManager.DeviceTypeName(TypeIndex: Integer): string;
begin
  Result := FetchStr(StrArgs(skDeviceTypeName, FHandle, TypeIndex));
end;

function TJuceAudioDeviceManager.DeviceTypeNames: TStringDynArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, DeviceTypeCount);
  for I := 0 to High(Result) do
    Result[I] := DeviceTypeName(I);
end;

function TJuceAudioDeviceManager.DeviceCount(TypeIndex: Integer; IsInput: Boolean): Integer;
begin
  Result := juce_c_audio_device_manager_get_device_count(FHandle, TypeIndex, Ord(IsInput));
end;

function TJuceAudioDeviceManager.DeviceName(TypeIndex: Integer; IsInput: Boolean;
  DeviceIndex: Integer): string;
begin
  Result := FetchStr(StrArgs(skDeviceName, FHandle, TypeIndex, Ord(IsInput), DeviceIndex));
end;

function TJuceAudioDeviceManager.DeviceNames(TypeIndex: Integer; IsInput: Boolean): TStringDynArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, DeviceCount(TypeIndex, IsInput));
  for I := 0 to High(Result) do
    Result[I] := DeviceName(TypeIndex, IsInput, I);
end;

function TJuceAudioDeviceManager.DefaultDeviceIndex(TypeIndex: Integer; IsInput: Boolean): Integer;
begin
  Result := juce_c_audio_device_manager_get_default_device_index(FHandle, TypeIndex, Ord(IsInput));
end;

function TJuceAudioDeviceManager.GetCurrentDeviceType: string;
begin
  Result := FetchStr(StrArgs(skCurrentDeviceType, FHandle));
end;

procedure TJuceAudioDeviceManager.SetCurrentDeviceType(const Value: string);
var
  U: UTF8String;
begin
  CheckConstructed;
  U := JuceToUtf8(Value);
  JuceCheck(juce_c_audio_device_manager_set_current_device_type(FHandle, PAnsiChar(U), 1));
end;

function TJuceAudioDeviceManager.GetSetup: TJuceAudioDeviceSetup;
var
  C: TJuceCAudioDeviceSetup;
begin
  FillChar(C, SizeOf(C), 0);
  C.StructSize := SizeOf(C);
  JuceCheck(juce_c_audio_device_manager_get_setup(FHandle, @C));
  Result := SetupFromC(C);
end;

procedure TJuceAudioDeviceManager.SetSetup(const Value: TJuceAudioDeviceSetup);
begin
  ApplySetup(Value, True);
end;

procedure TJuceAudioDeviceManager.ApplySetup(const Value: TJuceAudioDeviceSetup;
  TreatAsChosenDevice: Boolean);
var
  C: TJuceCAudioDeviceSetup;
begin
  CheckConstructed;
  C := SetupToC(Value);
  JuceCheck(juce_c_audio_device_manager_set_setup(FHandle, @C, Ord(TreatAsChosenDevice)));
end;

function TJuceAudioDeviceManager.IsDeviceOpen: Boolean;
begin
  Result := juce_c_audio_device_manager_is_device_open(FHandle) <> 0;
end;

function TJuceAudioDeviceManager.CurrentDeviceName: string;
begin
  Result := FetchStr(StrArgs(skCurrentDeviceName, FHandle));
end;

function TJuceAudioDeviceManager.SampleRate: Double;
begin
  Result := juce_c_audio_device_manager_get_sample_rate(FHandle);
end;

function TJuceAudioDeviceManager.BlockSize: Integer;
begin
  Result := juce_c_audio_device_manager_get_block_size(FHandle);
end;

function TJuceAudioDeviceManager.BitDepth: Integer;
begin
  Result := juce_c_audio_device_manager_get_bit_depth(FHandle);
end;

function TJuceAudioDeviceManager.InputLatency: Integer;
begin
  Result := juce_c_audio_device_manager_get_input_latency(FHandle);
end;

function TJuceAudioDeviceManager.OutputLatency: Integer;
begin
  Result := juce_c_audio_device_manager_get_output_latency(FHandle);
end;

function TJuceAudioDeviceManager.ActiveInputChannelCount: Integer;
begin
  Result := juce_c_audio_device_manager_get_active_input_channel_count(FHandle);
end;

function TJuceAudioDeviceManager.ActiveOutputChannelCount: Integer;
begin
  Result := juce_c_audio_device_manager_get_active_output_channel_count(FHandle);
end;

function TJuceAudioDeviceManager.ChannelNames(IsInput: Boolean): TStringDynArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, juce_c_audio_device_manager_get_channel_name_count(FHandle, Ord(IsInput)));
  for I := 0 to High(Result) do
    Result[I] := FetchStr(StrArgs(skChannelName, FHandle, Ord(IsInput), I));
end;

function TJuceAudioDeviceManager.AvailableSampleRates: TDoubleDynArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, juce_c_audio_device_manager_get_available_sample_rate_count(FHandle));
  for I := 0 to High(Result) do
    Result[I] := juce_c_audio_device_manager_get_available_sample_rate(FHandle, I);
end;

function TJuceAudioDeviceManager.AvailableBufferSizes: TIntegerDynArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, juce_c_audio_device_manager_get_available_buffer_size_count(FHandle));
  for I := 0 to High(Result) do
    Result[I] := juce_c_audio_device_manager_get_available_buffer_size(FHandle, I);
end;

function TJuceAudioDeviceManager.CpuUsage: Double;
begin
  Result := juce_c_audio_device_manager_get_cpu_usage(FHandle);
end;

function TJuceAudioDeviceManager.XRunCount: Integer;
begin
  Result := juce_c_audio_device_manager_get_xrun_count(FHandle);
end;

function TJuceAudioDeviceManager.ConsumeCallbackErrorCount: Cardinal;
begin
  Result := juce_c_audio_device_manager_consume_callback_error_count(FHandle);
end;

procedure TJuceAudioDeviceManager.PlayTestSound;
begin
  JuceCheck(juce_c_audio_device_manager_play_test_sound(FHandle));
end;

procedure TJuceAudioDeviceManager.SetMidiInputEnabled(const Identifier: string; Enabled: Boolean);
var
  U: UTF8String;
begin
  U := JuceToUtf8(Identifier);
  JuceCheck(juce_c_audio_device_manager_set_midi_input_enabled(FHandle, PAnsiChar(U), Ord(Enabled)));
end;

function TJuceAudioDeviceManager.IsMidiInputEnabled(const Identifier: string): Boolean;
var
  U: UTF8String;
begin
  U := JuceToUtf8(Identifier);
  Result := juce_c_audio_device_manager_is_midi_input_enabled(FHandle, PAnsiChar(U)) <> 0;
end;

procedure TJuceAudioDeviceManager.AddMidiMessage(const Data: array of Byte);
begin
  JuceCheck(juce_c_audio_device_manager_add_midi_message(FHandle, BytesPtr(Data), Length(Data)));
end;

{ ---------------------------------------------------------------------------- }
{ TJuceMidiInput                                                               }
{ ---------------------------------------------------------------------------- }

procedure MidiInputTrampoline(UserData: Pointer; Message: PByte; MessageSize: Int32;
  TimestampSeconds: Double); cdecl;
var
  Input: TJuceMidiInput;
begin
  if GFinalizing then
    Exit;
  Input := TJuceMidiInput(UserData);
  try
    Input.FHandlerThread := GetCurrentThreadId;
    try
      if Assigned(Input.FOnMessage) then
        Input.FOnMessage(Input, Message, MessageSize, TimestampSeconds);
    finally
      Input.FHandlerThread := 0;
    end;
  except
    AtomicInc(Input.FErrors);
  end;
end;

constructor TJuceMidiInput.Create(const Identifier: string; Handler: TJuceMidiInputEvent);
var
  U: UTF8String;
begin
  inherited Create;
  if FHandle <> nil then
  begin
    juce_c_midi_input_stop(FHandle); { as for the device manager; result ignored }
    Exit;
  end;
  CheckAbi;
  FOnMessage := Handler;
  U := JuceToUtf8(Identifier);
  JuceCheck(juce_c_midi_input_open(PAnsiChar(U), MidiInputTrampoline, Self, @FHandle));
end;

procedure TJuceMidiInput.BeforeDestruction;
begin
  if FHandle <> nil then
  begin
    if FHandlerThread = GetCurrentThreadId then
      raise EJuceError.CreateCode(JUCE_C_INVALID_STATE, 'A MIDI input cannot be freed from inside its own handler');
    { Refused (raises, object stays alive) from inside any MIDI handler. }
    JuceCheck(juce_c_midi_input_destroy(FHandle)); { no callbacks after this returns }
    FHandle := nil;
  end;
  inherited;
end;

destructor TJuceMidiInput.Destroy;
begin
  if FHandle <> nil then
    juce_c_midi_input_destroy(FHandle); { no callbacks after this returns }
  inherited;
end;

procedure TJuceMidiInput.AfterConstruction;
begin
  inherited;
  FConstructed := True;
end;

procedure TJuceMidiInput.Start;
begin
  if not FConstructed then
    raise EJuceError.CreateCode(JUCE_C_INVALID_STATE,
      'Start MIDI inputs after the constructor has returned (or in AfterConstruction)');
  JuceCheck(juce_c_midi_input_start(FHandle));
end;

procedure TJuceMidiInput.Stop;
begin
  JuceCheck(juce_c_midi_input_stop(FHandle));
end;

function TJuceMidiInput.ConsumeCallbackErrorCount: Cardinal;
begin
  Result := Cardinal(AtomicTake(FErrors));
end;

function TJuceMidiInput.GetName: string;
begin
  Result := FetchStr(StrArgs(skMidiInputName, FHandle));
end;

{ ---------------------------------------------------------------------------- }
{ TJuceMidiOutput                                                              }
{ ---------------------------------------------------------------------------- }

constructor TJuceMidiOutput.Create(const Identifier: string);
var
  U: UTF8String;
begin
  inherited Create;
  if FHandle <> nil then
    Exit; { "Obj.Create;" on a live object: leave it untouched (see CheckNotLive note) }
  CheckAbi;
  U := JuceToUtf8(Identifier);
  JuceCheck(juce_c_midi_output_open(PAnsiChar(U), @FHandle));
end;

destructor TJuceMidiOutput.Destroy;
begin
  if FHandle <> nil then
    juce_c_midi_output_destroy(FHandle);
  inherited;
end;

procedure TJuceMidiOutput.Send(const Data: array of Byte);
begin
  JuceCheck(juce_c_midi_output_send(FHandle, BytesPtr(Data), Length(Data)));
end;

procedure TJuceMidiOutput.SendBlock(Buffer: TJuceMidiBuffer; StartTimeMs, SampleRate: Double);
begin
  JuceCheck(juce_c_midi_output_send_block(FHandle, HandleOf(Buffer), StartTimeMs, SampleRate));
end;

procedure TJuceMidiOutput.ClearPending;
begin
  JuceCheck(juce_c_midi_output_clear_pending(FHandle));
end;

function TJuceMidiOutput.GetName: string;
begin
  Result := FetchStr(StrArgs(skMidiOutputName, FHandle));
end;

{ ---------------------------------------------------------------------------- }
{ Audio files                                                                  }
{ ---------------------------------------------------------------------------- }

function JuceLoadAudioFile(const FileName: string; out SampleRate: Double): TJuceAudioBuffer;
var
  U: UTF8String;
  H: PJuceCAudioBuffer;
begin
  CheckAbi;
  U := JuceToUtf8(FileName);
  SampleRate := 0;
  H := nil;
  JuceCheck(juce_c_audio_file_load(PAnsiChar(U), @H, @SampleRate));
  Result := TJuceAudioBuffer.CreateFromHandle(H);
end;

function JuceAudioFileWildcard: string;
begin
  Result := FetchStr(StrArgs(skWildcard));
end;

constructor TJuceAudioFileReader.Create(const FileName: string);
var
  U: UTF8String;
begin
  inherited Create;
  if FHandle <> nil then
    Exit; { "Obj.Create;" on a live object: leave it untouched (see CheckNotLive note) }
  CheckAbi;
  U := JuceToUtf8(FileName);
  JuceCheck(juce_c_audio_file_reader_open(PAnsiChar(U), @FHandle));
end;

destructor TJuceAudioFileReader.Destroy;
begin
  if FHandle <> nil then
    juce_c_audio_file_reader_destroy(FHandle);
  inherited;
end;

procedure TJuceAudioFileReader.Read(Dest: TJuceAudioBuffer; DestStart, Count: Integer; FileStart: Int64);
begin
  JuceCheck(juce_c_audio_file_reader_read(FHandle, HandleOf(Dest), DestStart, Count, FileStart));
end;

function TJuceAudioFileReader.GetSampleRate: Double;
begin
  Result := juce_c_audio_file_reader_get_sample_rate(FHandle);
end;

function TJuceAudioFileReader.GetNumChannels: Integer;
begin
  Result := juce_c_audio_file_reader_get_channel_count(FHandle);
end;

function TJuceAudioFileReader.GetLength: Int64;
begin
  Result := juce_c_audio_file_reader_get_length(FHandle);
end;

function TJuceAudioFileReader.GetBitsPerSample: Integer;
begin
  Result := juce_c_audio_file_reader_get_bits_per_sample(FHandle);
end;

function TJuceAudioFileReader.GetIsFloat: Boolean;
begin
  Result := juce_c_audio_file_reader_is_floating_point(FHandle) <> 0;
end;

function TJuceAudioFileReader.GetFormatName: string;
begin
  Result := FetchStr(StrArgs(skFileFormat, FHandle));
end;

constructor TJuceAudioFileWriter.Create(const FileName: string; SampleRate: Double;
  NumChannels, BitsPerSample: Integer; const FormatName: string; QualityIndex: Integer);
var
  UPath, UFormat: UTF8String;
begin
  inherited Create;
  if FHandle <> nil then
    Exit; { "Obj.Create;" on a live object: leave it untouched (see CheckNotLive note) }
  CheckAbi;
  UPath := JuceToUtf8(FileName);
  UFormat := JuceToUtf8(FormatName);
  JuceCheck(juce_c_audio_file_writer_create(PAnsiChar(UPath), PAnsiChar(UFormat), SampleRate,
    NumChannels, BitsPerSample, QualityIndex, @FHandle));
end;

destructor TJuceAudioFileWriter.Destroy;
begin
  if FHandle <> nil then
    juce_c_audio_file_writer_destroy(FHandle);
  inherited;
end;

procedure TJuceAudioFileWriter.Write(Source: TJuceAudioBuffer; StartSample, Count: Integer);
begin
  JuceCheck(juce_c_audio_file_writer_write_buffer(FHandle, HandleOf(Source), StartSample, Count));
end;

procedure TJuceAudioFileWriter.WriteChannels(Channels: PJuceChannelArray; NumChannels, Count: Integer);
begin
  JuceCheck(juce_c_audio_file_writer_write_channels(FHandle, Channels, NumChannels, Count));
end;

procedure TJuceAudioFileWriter.Flush;
begin
  JuceCheck(juce_c_audio_file_writer_flush(FHandle));
end;

initialization
  GMessageThreadID := GetCurrentThreadId;
  { Threading set-up (IsMultiThread, cthreads, FPC thread warm-up) lives in juce_c_audio. }

finalization
  GFinalizing := True;
  if GetCurrentThreadId = GMessageThreadID then
    CloseLiveManagers;

end.
