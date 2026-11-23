{
  juce_c_audio.pas - raw import unit for juce_c_audio (see include/juce_c_audio.h,
  which documents every function, its threading rules and error behaviour).

  Works with Free Pascal / Lazarus and Delphi. All imports are cdecl.
  Most code should use the object layer in JuceAudio.pas instead.
}
unit juce_c_audio;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$PACKRECORDS C}
{$ELSE}
  {$ALIGN 8}
  {$MINENUMSIZE 4}
{$ENDIF}

interface

uses
{$IFDEF FPC}{$IFDEF UNIX}
  cthreads, { JUCE calls back on its own threads: FPC needs a thread manager }
{$ENDIF}{$ENDIF}
  JuceTypes;

const
{$IFDEF MSWINDOWS}
  JuceCAudioLib = 'juce_c_audio.dll';
{$ELSE}
  {$IFDEF FPC}
  { Free Pascal links Unix libraries by name (-ljuce_c_audio): the file is
    libjuce_c_audio.so (Linux) or libjuce_c_audio.dylib (macOS). Pass its
    folder with -Fl, and give the program an rpath (see README.md). }
  JuceCAudioLib = 'juce_c_audio';
  {$IFDEF DARWIN}
    {$LINKLIB juce_c_audio} { name the library for the Darwin linker explicitly }
  {$ENDIF}
  {$ELSE}
    {$IF DEFINED(MACOS)}
  JuceCAudioLib = 'libjuce_c_audio.dylib';
    {$ELSE}
  JuceCAudioLib = 'libjuce_c_audio.so';
    {$IFEND}
  {$ENDIF}
{$ENDIF}

  JUCE_C_AUDIO_ABI_VERSION = 4;

  { juce_c_result (int32_t) }
  JUCE_C_OK               = 0;
  JUCE_C_INVALID_ARGUMENT = 1;
  JUCE_C_OUT_OF_MEMORY    = 2;
  JUCE_C_JUCE_ERROR       = 3;
  JUCE_C_OUT_OF_RANGE     = 4;
  JUCE_C_BUFFER_TOO_SMALL = 5;
  JUCE_C_NOT_INITIALISED  = 6;
  JUCE_C_INVALID_STATE    = 7;

type
  TJuceCResult = Int32;
  TJuceCSize   = NativeUInt; { size_t }
  PJuceCSize   = ^TJuceCSize;
  PJuceCChar   = PAnsiChar;  { NUL-terminated UTF-8 }

  { Opaque handles }
  PJuceCAudioBuffer        = type Pointer;
  PJuceCMidiBuffer         = type Pointer;
  PJuceCAudioDeviceManager = type Pointer;
  PJuceCMidiDeviceList     = type Pointer;
  PJuceCMidiInput          = type Pointer;
  PJuceCMidiOutput         = type Pointer;
  PJuceCAudioFileReader    = type Pointer;
  PJuceCAudioFileWriter    = type Pointer;

  PPJuceCAudioBuffer        = ^PJuceCAudioBuffer;
  PPJuceCMidiBuffer         = ^PJuceCMidiBuffer;
  PPJuceCAudioDeviceManager = ^PJuceCAudioDeviceManager;
  PPJuceCMidiDeviceList     = ^PJuceCMidiDeviceList;
  PPJuceCMidiInput          = ^PJuceCMidiInput;
  PPJuceCMidiOutput         = ^PJuceCMidiOutput;
  PPJuceCAudioFileReader    = ^PJuceCAudioFileReader;
  PPJuceCAudioFileWriter    = ^PJuceCAudioFileWriter;

  { Sample data types live in JuceTypes; aliased here for convenience. }
  TJuceSampleArray  = JuceTypes.TJuceSampleArray;
  PJuceSampleArray  = JuceTypes.PJuceSampleArray;
  TJuceChannelArray = JuceTypes.TJuceChannelArray;
  PJuceChannelArray = JuceTypes.PJuceChannelArray;

  PPSingle = ^PSingle;  { PSingle comes from System }

  { 600 bytes, no padding. Channel n = bit (n mod 64) of word (n div 64). }
  TJuceCAudioDeviceSetup = packed record
    StructSize: Int32;                { = SizeOf(TJuceCAudioDeviceSetup) }
    BufferSize: Int32;
    SampleRate: Double;
    InputChannels: array[0..3] of UInt64;
    OutputChannels: array[0..3] of UInt64;
    UseDefaultInputChannels: Int32;
    UseDefaultOutputChannels: Int32;
    OutputDeviceName: array[0..255] of AnsiChar;  { UTF-8 }
    InputDeviceName: array[0..255] of AnsiChar;   { UTF-8 }
  end;
  PJuceCAudioDeviceSetup = ^TJuceCAudioDeviceSetup;

  { Callbacks }
  TJuceCAudioCallback = procedure(UserData: Pointer;
    InputChannels: PJuceChannelArray; InputChannelCount: Int32;
    OutputChannels: PJuceChannelArray; OutputChannelCount: Int32;
    SampleCount: Int32; Midi: PJuceCMidiBuffer); cdecl;
  TJuceCAudioStartCallback = procedure(UserData: Pointer; SampleRate: Double;
    ExpectedBlockSize: Int32); cdecl;
  TJuceCAudioStopCallback = procedure(UserData: Pointer); cdecl;
  TJuceCChangeCallback = procedure(UserData: Pointer); cdecl;
  TJuceCMidiEventVisitor = function(UserData: Pointer; Message: PByte;
    MessageSize: Int32; SamplePosition: Int32): Int32; cdecl;
  TJuceCMidiInputCallback = procedure(UserData: Pointer; Message: PByte;
    MessageSize: Int32; TimestampSeconds: Double); cdecl;

  TJuceCAudioCallbacks = record
    StructSize: Int32;                { = SizeOf(TJuceCAudioCallbacks) }
    Reserved: Int32;
    UserData: Pointer;
    OnAudio: TJuceCAudioCallback;
    OnStart: TJuceCAudioStartCallback;
    OnStop: TJuceCAudioStopCallback;
  end;
  PJuceCAudioCallbacks = ^TJuceCAudioCallbacks;

  TJuceCVirtualDeviceOptions = record
    StructSize: Int32;                { = SizeOf(TJuceCVirtualDeviceOptions) }
    Realtime: Int32;
    InputSignal: Int32;
    Reserved: Int32;
  end;
  PJuceCVirtualDeviceOptions = ^TJuceCVirtualDeviceOptions;

{ Library }
function juce_c_get_abi_version: Int32; cdecl; external JuceCAudioLib;
function juce_c_get_last_error_message: PJuceCChar; cdecl; external JuceCAudioLib;
function juce_c_get_juce_version(Buffer: PJuceCChar; BufferSize: PJuceCSize): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_initialise: TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_shutdown: TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_is_initialised: Int32; cdecl; external JuceCAudioLib;
function juce_c_dispatch_messages(Milliseconds: Int32): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_get_millisecond_counter_hires: Double; cdecl; external JuceCAudioLib;

{ Audio buffers }
function juce_c_audio_buffer_create(ChannelCount, SampleCount: Int32; Res: PPJuceCAudioBuffer): TJuceCResult; cdecl; external JuceCAudioLib;
procedure juce_c_audio_buffer_destroy(Buffer: PJuceCAudioBuffer); cdecl; external JuceCAudioLib;
function juce_c_audio_buffer_get_channel_count(Buffer: PJuceCAudioBuffer): Int32; cdecl; external JuceCAudioLib;
function juce_c_audio_buffer_get_sample_count(Buffer: PJuceCAudioBuffer): Int32; cdecl; external JuceCAudioLib;
function juce_c_audio_buffer_set_size(Buffer: PJuceCAudioBuffer; ChannelCount, SampleCount, KeepExistingContent: Int32): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_buffer_get_read_pointer(Buffer: PJuceCAudioBuffer; Channel: Int32; Res: PPSingle): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_buffer_get_write_pointer(Buffer: PJuceCAudioBuffer; Channel: Int32; Res: PPSingle): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_buffer_clear(Buffer: PJuceCAudioBuffer): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_buffer_clear_region(Buffer: PJuceCAudioBuffer; StartSample, SampleCount: Int32): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_buffer_apply_gain(Buffer: PJuceCAudioBuffer; Gain: Single): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_buffer_apply_gain_ramp(Buffer: PJuceCAudioBuffer; StartSample, SampleCount: Int32; StartGain, EndGain: Single): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_buffer_add_from(Dest: PJuceCAudioBuffer; DestChannel, DestStartSample: Int32; Source: PJuceCAudioBuffer; SourceChannel, SourceStartSample, SampleCount: Int32; Gain: Single): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_buffer_copy_from(Dest: PJuceCAudioBuffer; DestChannel, DestStartSample: Int32; Source: PJuceCAudioBuffer; SourceChannel, SourceStartSample, SampleCount: Int32): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_buffer_get_magnitude(Buffer: PJuceCAudioBuffer; Channel, StartSample, SampleCount: Int32; Res: PSingle): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_buffer_get_rms_level(Buffer: PJuceCAudioBuffer; Channel, StartSample, SampleCount: Int32; Res: PSingle): TJuceCResult; cdecl; external JuceCAudioLib;

{ MIDI buffers / messages }
function juce_c_midi_buffer_create(Res: PPJuceCMidiBuffer): TJuceCResult; cdecl; external JuceCAudioLib;
procedure juce_c_midi_buffer_destroy(Buffer: PJuceCMidiBuffer); cdecl; external JuceCAudioLib;
function juce_c_midi_buffer_clear(Buffer: PJuceCMidiBuffer): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_midi_buffer_get_event_count(Buffer: PJuceCMidiBuffer): Int32; cdecl; external JuceCAudioLib;
function juce_c_midi_buffer_add_event(Buffer: PJuceCMidiBuffer; Message: PByte; MessageSize: TJuceCSize; SamplePosition: Int32): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_midi_buffer_get_event(Buffer: PJuceCMidiBuffer; EventIndex: Int32; Message: PByte; MessageSize: PJuceCSize; SamplePosition: PInteger): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_midi_buffer_for_each(Buffer: PJuceCMidiBuffer; Visitor: TJuceCMidiEventVisitor; UserData: Pointer): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_midi_message_get_description(Message: PByte; MessageSize: TJuceCSize; Buffer: PJuceCChar; BufferSize: PJuceCSize): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_midi_get_note_name(NoteNumber, UseSharps, IncludeOctave, MiddleCOctave: Int32; Buffer: PJuceCChar; BufferSize: PJuceCSize): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_midi_get_note_frequency(NoteNumber: Int32; FrequencyOfA: Double): Double; cdecl; external JuceCAudioLib;

{ Audio device manager }
function juce_c_audio_device_setup_size: Int32; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_create(Callbacks: PJuceCAudioCallbacks; Res: PPJuceCAudioDeviceManager): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_destroy(Manager: PJuceCAudioDeviceManager): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_set_change_callback(Manager: PJuceCAudioDeviceManager; Callback: TJuceCChangeCallback; UserData: Pointer): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_add_virtual_device_type(Manager: PJuceCAudioDeviceManager; Options: PJuceCVirtualDeviceOptions): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_simulate_xrun(Manager: PJuceCAudioDeviceManager): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_initialize(Manager: PJuceCAudioDeviceManager; InputChannelCount, OutputChannelCount: Int32): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_initialize_with_setup(Manager: PJuceCAudioDeviceManager; InputChannelCount, OutputChannelCount: Int32; DeviceType: PJuceCChar; Preferred: PJuceCAudioDeviceSetup): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_close(Manager: PJuceCAudioDeviceManager): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_restart(Manager: PJuceCAudioDeviceManager): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_get_device_type_count(Manager: PJuceCAudioDeviceManager): Int32; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_get_device_type_name(Manager: PJuceCAudioDeviceManager; TypeIndex: Int32; Buffer: PJuceCChar; BufferSize: PJuceCSize): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_get_current_device_type(Manager: PJuceCAudioDeviceManager; Buffer: PJuceCChar; BufferSize: PJuceCSize): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_set_current_device_type(Manager: PJuceCAudioDeviceManager; TypeName: PJuceCChar; TreatAsChosenDevice: Int32): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_get_device_count(Manager: PJuceCAudioDeviceManager; TypeIndex, IsInput: Int32): Int32; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_get_device_name(Manager: PJuceCAudioDeviceManager; TypeIndex, IsInput, DeviceIndex: Int32; Buffer: PJuceCChar; BufferSize: PJuceCSize): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_get_default_device_index(Manager: PJuceCAudioDeviceManager; TypeIndex, IsInput: Int32): Int32; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_get_setup(Manager: PJuceCAudioDeviceManager; Setup: PJuceCAudioDeviceSetup): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_set_setup(Manager: PJuceCAudioDeviceManager; Setup: PJuceCAudioDeviceSetup; TreatAsChosenDevice: Int32): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_is_device_open(Manager: PJuceCAudioDeviceManager): Int32; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_get_device_name_current(Manager: PJuceCAudioDeviceManager; Buffer: PJuceCChar; BufferSize: PJuceCSize): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_get_sample_rate(Manager: PJuceCAudioDeviceManager): Double; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_get_block_size(Manager: PJuceCAudioDeviceManager): Int32; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_get_bit_depth(Manager: PJuceCAudioDeviceManager): Int32; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_get_input_latency(Manager: PJuceCAudioDeviceManager): Int32; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_get_output_latency(Manager: PJuceCAudioDeviceManager): Int32; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_get_active_input_channel_count(Manager: PJuceCAudioDeviceManager): Int32; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_get_active_output_channel_count(Manager: PJuceCAudioDeviceManager): Int32; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_get_channel_name_count(Manager: PJuceCAudioDeviceManager; IsInput: Int32): Int32; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_get_channel_name(Manager: PJuceCAudioDeviceManager; IsInput, ChannelIndex: Int32; Buffer: PJuceCChar; BufferSize: PJuceCSize): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_get_available_sample_rate_count(Manager: PJuceCAudioDeviceManager): Int32; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_get_available_sample_rate(Manager: PJuceCAudioDeviceManager; Index: Int32): Double; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_get_available_buffer_size_count(Manager: PJuceCAudioDeviceManager): Int32; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_get_available_buffer_size(Manager: PJuceCAudioDeviceManager; Index: Int32): Int32; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_get_cpu_usage(Manager: PJuceCAudioDeviceManager): Double; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_get_xrun_count(Manager: PJuceCAudioDeviceManager): Int32; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_play_test_sound(Manager: PJuceCAudioDeviceManager): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_set_midi_input_enabled(Manager: PJuceCAudioDeviceManager; DeviceIdentifier: PJuceCChar; Enabled: Int32): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_is_midi_input_enabled(Manager: PJuceCAudioDeviceManager; DeviceIdentifier: PJuceCChar): Int32; cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_add_midi_message(Manager: PJuceCAudioDeviceManager; Message: PByte; MessageSize: TJuceCSize): TJuceCResult; cdecl; external JuceCAudioLib;
procedure juce_c_audio_device_manager_report_callback_error(Manager: PJuceCAudioDeviceManager); cdecl; external JuceCAudioLib;
function juce_c_audio_device_manager_consume_callback_error_count(Manager: PJuceCAudioDeviceManager): UInt32; cdecl; external JuceCAudioLib;

{ MIDI devices }
function juce_c_midi_device_list_create(IsInput: Int32; Res: PPJuceCMidiDeviceList): TJuceCResult; cdecl; external JuceCAudioLib;
procedure juce_c_midi_device_list_destroy(List: PJuceCMidiDeviceList); cdecl; external JuceCAudioLib;
function juce_c_midi_device_list_get_count(List: PJuceCMidiDeviceList): Int32; cdecl; external JuceCAudioLib;
function juce_c_midi_device_list_get_name(List: PJuceCMidiDeviceList; Index: Int32; Buffer: PJuceCChar; BufferSize: PJuceCSize): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_midi_device_list_get_identifier(List: PJuceCMidiDeviceList; Index: Int32; Buffer: PJuceCChar; BufferSize: PJuceCSize): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_midi_get_default_device_identifier(IsInput: Int32; Buffer: PJuceCChar; BufferSize: PJuceCSize): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_midi_input_open(DeviceIdentifier: PJuceCChar; Callback: TJuceCMidiInputCallback; UserData: Pointer; Res: PPJuceCMidiInput): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_midi_input_destroy(Input: PJuceCMidiInput): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_midi_input_start(Input: PJuceCMidiInput): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_midi_input_stop(Input: PJuceCMidiInput): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_midi_input_get_name(Input: PJuceCMidiInput; Buffer: PJuceCChar; BufferSize: PJuceCSize): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_midi_output_open(DeviceIdentifier: PJuceCChar; Res: PPJuceCMidiOutput): TJuceCResult; cdecl; external JuceCAudioLib;
procedure juce_c_midi_output_destroy(Output: PJuceCMidiOutput); cdecl; external JuceCAudioLib;
function juce_c_midi_output_get_name(Output: PJuceCMidiOutput; Buffer: PJuceCChar; BufferSize: PJuceCSize): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_midi_output_send(Output: PJuceCMidiOutput; Message: PByte; MessageSize: TJuceCSize): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_midi_output_send_block(Output: PJuceCMidiOutput; Buffer: PJuceCMidiBuffer; StartTimeMs, SampleRate: Double): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_midi_output_clear_pending(Output: PJuceCMidiOutput): TJuceCResult; cdecl; external JuceCAudioLib;

{ Audio files - never call these from the audio thread }
function juce_c_audio_file_get_wildcard(Buffer: PJuceCChar; BufferSize: PJuceCSize): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_file_reader_open(Path: PJuceCChar; Res: PPJuceCAudioFileReader): TJuceCResult; cdecl; external JuceCAudioLib;
procedure juce_c_audio_file_reader_destroy(Reader: PJuceCAudioFileReader); cdecl; external JuceCAudioLib;
function juce_c_audio_file_reader_get_sample_rate(Reader: PJuceCAudioFileReader): Double; cdecl; external JuceCAudioLib;
function juce_c_audio_file_reader_get_channel_count(Reader: PJuceCAudioFileReader): Int32; cdecl; external JuceCAudioLib;
function juce_c_audio_file_reader_get_length(Reader: PJuceCAudioFileReader): Int64; cdecl; external JuceCAudioLib;
function juce_c_audio_file_reader_get_bits_per_sample(Reader: PJuceCAudioFileReader): Int32; cdecl; external JuceCAudioLib;
function juce_c_audio_file_reader_is_floating_point(Reader: PJuceCAudioFileReader): Int32; cdecl; external JuceCAudioLib;
function juce_c_audio_file_reader_get_format_name(Reader: PJuceCAudioFileReader; Buffer: PJuceCChar; BufferSize: PJuceCSize): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_file_reader_read(Reader: PJuceCAudioFileReader; Dest: PJuceCAudioBuffer; DestStartSample, SampleCount: Int32; ReaderStartSample: Int64): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_file_load(Path: PJuceCChar; Res: PPJuceCAudioBuffer; SampleRate: PDouble): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_file_writer_create(Path, FormatName: PJuceCChar; SampleRate: Double; ChannelCount, BitsPerSample, QualityIndex: Int32; Res: PPJuceCAudioFileWriter): TJuceCResult; cdecl; external JuceCAudioLib;
procedure juce_c_audio_file_writer_destroy(Writer: PJuceCAudioFileWriter); cdecl; external JuceCAudioLib;
function juce_c_audio_file_writer_write_buffer(Writer: PJuceCAudioFileWriter; Source: PJuceCAudioBuffer; StartSample, SampleCount: Int32): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_file_writer_write_channels(Writer: PJuceCAudioFileWriter; Channels: PJuceChannelArray; ChannelCount, SampleCount: Int32): TJuceCResult; cdecl; external JuceCAudioLib;
function juce_c_audio_file_writer_flush(Writer: PJuceCAudioFileWriter): TJuceCResult; cdecl; external JuceCAudioLib;

implementation

{$IFDEF FPC}{$IFNDEF MSWINDOWS}
function NoopThread(Parameter: Pointer): PtrInt;
begin
  Result := 0;
end;

{ JUCE calls back on its own audio/MIDI threads, which must get their own
  Free Pascal per-thread state (threadvars: heap free lists, exception
  frames). On Windows the RTL uses the PE TLS directory, so this is already
  true from program start (verified by tests/pascal/test_app_units, suite
  "Concurrency stress"). On other platforms the threadvar machinery may only
  be switched on by the first BeginThread, so start and join one thread now. }
procedure InitPascalThreading;
var
  Handle: TThreadID;
begin
  Handle := BeginThread(NoopThread, nil);
  if Handle <> TThreadID(0) then
  begin
    WaitForThreadTerminate(Handle, 0);
    CloseThread(Handle);
  end;
end;
{$ENDIF}{$ENDIF}

initialization
  { Callbacks arrive on JUCE threads: the RTL heap must be thread-safe. }
  IsMultiThread := True;
{$IFDEF FPC}{$IFNDEF MSWINDOWS}
  { Not on Windows (the PE TLS directory already covers foreign threads), and
    never in a library: unit initialisation runs under the OS loader lock
    there, and joining a new thread would deadlock the host's LoadLibrary. }
  if not IsLibrary then
    InitPascalThreading;
{$ENDIF}{$ENDIF}

end.
