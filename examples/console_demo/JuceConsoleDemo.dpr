{
  JuceConsoleDemo - lists audio/MIDI devices, opens the default output and
  plays a sine wave whose pitch follows incoming MIDI notes.

  Usage: JuceConsoleDemo [--seconds N] [--silent] [--midi]
    --seconds N  how long to run (default 3)
    --silent     output silence (still runs the audio callback)
    --midi       enable all MIDI inputs so you can play the sine from a keyboard

  Builds with FPC/Lazarus (fpc -Mdelphi -Fu../../pascal) and Delphi.
  juce_c_audio.dll must be next to the executable or on PATH.
}
program JuceConsoleDemo;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}
{$APPTYPE CONSOLE}

uses
  SysUtils, StrUtils, JuceAudio;

type
  TSineSynth = class
  public
    { Written on the audio thread, read on the main thread (word-sized, so
      plain reads are fine for display purposes). }
    Blocks: Integer;
    MidiEvents: Integer;
    SampleRate: Double;
    Gain: Single;
    Phase: Double;
    Frequency: Double;
    procedure HandleStart(Sender: TJuceAudioDeviceManager; ASampleRate: Double; ExpectedBlockSize: Integer);
    procedure HandleMidi(Data: PByte; Size, SamplePosition: Integer);
    procedure HandleAudio(Sender: TJuceAudioDeviceManager;
      Inputs: PJuceChannelArray; NumInputs: Integer;
      Outputs: PJuceChannelArray; NumOutputs: Integer;
      NumSamples: Integer; const Midi: TJuceMidiView);
  end;

procedure TSineSynth.HandleStart(Sender: TJuceAudioDeviceManager; ASampleRate: Double; ExpectedBlockSize: Integer);
begin
  SampleRate := ASampleRate;
  Phase := 0;
end;

procedure TSineSynth.HandleMidi(Data: PByte; Size, SamplePosition: Integer);
var
  Status, Note, Velocity: Byte;
begin
  Inc(MidiEvents);
  if Size < 3 then
    Exit;
  Status := Data[0] and $F0;
  Note := Data[1];
  Velocity := Data[2];
  if (Status = $90) and (Velocity > 0) then
    Frequency := 440.0 * Exp((Note - 69) / 12 * Ln(2));
end;

procedure TSineSynth.HandleAudio(Sender: TJuceAudioDeviceManager;
  Inputs: PJuceChannelArray; NumInputs: Integer;
  Outputs: PJuceChannelArray; NumOutputs: Integer;
  NumSamples: Integer; const Midi: TJuceMidiView);
var
  I, Ch: Integer;
  Delta: Double;
  S: Single;
begin
  Inc(Blocks);
  Midi.Enumerate(HandleMidi);
  if SampleRate <= 0 then
    Exit;

  Delta := 2 * Pi * Frequency / SampleRate;
  for I := 0 to NumSamples - 1 do
  begin
    S := Gain * Sin(Phase);
    Phase := Phase + Delta;
    if Phase > 2 * Pi then
      Phase := Phase - 2 * Pi * Int(Phase / (2 * Pi)); { wraps any step size }
    for Ch := 0 to NumOutputs - 1 do
      if Outputs^[Ch] <> nil then
        Outputs^[Ch]^[I] := S;
  end;
end;

procedure ListDevices(Mgr: TJuceAudioDeviceManager);
var
  T, D: Integer;
  Midi: TJuceMidiDeviceInfoArray;
begin
  WriteLn('Audio device types:');
  for T := 0 to Mgr.DeviceTypeCount - 1 do
  begin
    WriteLn('  ', Mgr.DeviceTypeName(T));
    for D := 0 to Mgr.DeviceCount(T, False) - 1 do
      WriteLn('    out: ', Mgr.DeviceName(T, False, D));
    for D := 0 to Mgr.DeviceCount(T, True) - 1 do
      WriteLn('    in : ', Mgr.DeviceName(T, True, D));
  end;

  Midi := JuceMidiInputDevices;
  WriteLn('MIDI inputs: ', Length(Midi));
  for D := 0 to High(Midi) do
    WriteLn('  ', Midi[D].Name, '  [', Midi[D].Identifier, ']');
  Midi := JuceMidiOutputDevices;
  WriteLn('MIDI outputs: ', Length(Midi));
  for D := 0 to High(Midi) do
    WriteLn('  ', Midi[D].Name, '  [', Midi[D].Identifier, ']');
end;

var
  Mgr: TJuceAudioDeviceManager;
  Synth: TSineSynth;
  Seconds, I: Integer;
  Silent, UseMidi: Boolean;
  Deadline: Double;
  MidiIns: TJuceMidiDeviceInfoArray;
  Rates: TDoubleDynArray;
begin
  Seconds := 3;
  Silent := False;
  UseMidi := False;
  I := 1;
  while I <= ParamCount do
  begin
    if ParamStr(I) = '--silent' then
      Silent := True
    else if ParamStr(I) = '--midi' then
      UseMidi := True
    else if (ParamStr(I) = '--seconds') and (I < ParamCount) then
    begin
      Inc(I);
      Seconds := StrToIntDef(ParamStr(I), Seconds);
    end;
    Inc(I);
  end;

  JuceInitialise;
  try
    WriteLn(JuceVersion, ' via ', JuceCAudioLib);
    Synth := TSineSynth.Create;
    Mgr := nil;
    try
      Mgr := TJuceAudioDeviceManager.Create;
      ListDevices(Mgr);

      Synth.Frequency := 440;
      if Silent then
        Synth.Gain := 0
      else
        Synth.Gain := 0.1;
      Mgr.OnAudioStart := Synth.HandleStart;
      Mgr.OnAudio := Synth.HandleAudio;
      Mgr.Initialise(0, 2);

      WriteLn;
      WriteLn('Opened "', Mgr.CurrentDeviceName, '" (', Mgr.CurrentDeviceType, ')');
      WriteLn(Format('  %.0f Hz, %d samples/block, %d-bit, %d output channels, latency %d samples',
        [Mgr.SampleRate, Mgr.BlockSize, Mgr.BitDepth, Mgr.ActiveOutputChannelCount, Mgr.OutputLatency]));
      Rates := Mgr.AvailableSampleRates;
      Write('  available rates:');
      for I := 0 to High(Rates) do
        Write(Format(' %.0f', [Rates[I]]));
      WriteLn;

      if UseMidi then
      begin
        MidiIns := JuceMidiInputDevices;
        for I := 0 to High(MidiIns) do
        begin
          Mgr.SetMidiInputEnabled(MidiIns[I].Identifier, True);
          WriteLn('  MIDI input enabled: ', MidiIns[I].Name);
        end;
      end;

      { Inject a note through the same path as hardware MIDI: A4 -> E5. }
      Mgr.AddMidiMessage(MidiNoteOn(1, 76, 100));

      WriteLn(Format('Running for %d s%s...', [Seconds, IfThen(Silent, ' (silent)', '')]));
      Deadline := JuceMillisecondCounter + Seconds * 1000.0;
      while JuceMillisecondCounter < Deadline do
        JuceDispatchMessages(50);

      WriteLn(Format('Audio blocks: %d, MIDI events: %d, frequency now %.1f Hz, CPU %.2f%%, xruns %d, callback errors %d',
        [Synth.Blocks, Synth.MidiEvents, Synth.Frequency, Mgr.CpuUsage * 100, Mgr.XRunCount,
         Mgr.ConsumeCallbackErrorCount]));
      Mgr.Close;
    finally
      Mgr.Free;   { first: stops the callbacks that use Synth }
      Synth.Free;
    end;
  finally
    JuceShutdown;
  end;
end.
