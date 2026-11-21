{
  Tests for pascal/JuceAudio.pas (and, through it, juce_c_audio.pas) against
  the real juce_c_audio library. Device tests use the Virtual device, so they
  run on any machine; the MIDI loopback test runs only where the Windows MIDI
  Services loopback ports exist.

  Deliberately uses only JuceAudio (plus RTL units): everything a user needs
  must be reachable from that one unit.

  Build with checks on: fpc -Mdelphi -Cr -Co -Ct -CR -gl -gh ...
}
program test_app_units;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}
{$APPTYPE CONSOLE}

uses
{$IFDEF FPC}{$IFDEF UNIX}
  cthreads,
{$ENDIF}{$ENDIF}
  SysUtils, Classes, Math, JuceAudio, TestFramework;

{ ---------------------------------------------------------------------------- }

procedure WaitMs(Ms: Integer);
var
  Deadline: Double;
begin
  Deadline := JuceMillisecondCounter + Ms;
  while JuceMillisecondCounter < Deadline do
    JuceDispatchMessages(5);
end;

procedure TestLibrary;
var
  Before, During: {$IFDEF FPC}TFPUExceptionMask{$ELSE}TArithmeticExceptionMask{$ENDIF};
begin
  Suite('Library');
  Check(Pos('JUCE v', JuceVersion) = 1, 'JuceVersion = "' + JuceVersion + '"');
  Check(not JuceIsInitialised, 'not initialised before JuceInitialise');
  JuceShutdown;
  Check(True, 'JuceShutdown before JuceInitialise is a no-op');

  SetExceptionMask([exPrecision]); { like a Delphi app: invalid/zero-div/overflow unmasked }
  Before := GetExceptionMask;
  JuceInitialise;
  During := GetExceptionMask;
  Check(exInvalidOp in During, 'JuceInitialise masks FP exceptions on the main thread');
  JuceInitialise;
  JuceShutdown;
  Check(JuceIsInitialised and (exInvalidOp in GetExceptionMask), 'nested init/shutdown keeps state');
  JuceShutdown;
  Check(not JuceIsInitialised, 'balanced shutdown');
  Check(GetExceptionMask = Before, 'previous FP mask restored by the last JuceShutdown');

  JuceInitialise(False);
  Check(GetExceptionMask = Before, 'JuceInitialise(False) leaves the FP mask alone');
  JuceShutdown;
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);

  JuceInitialise;
  JuceDispatchMessages(0);
  Check(True, 'JuceDispatchMessages on the main thread');
end;

procedure MakeBadBuffer;
begin
  TJuceAudioBuffer.Create(0, 0).Free;
end;

procedure TestBuffers;
var
  A, B: TJuceAudioBuffer;
  Cached: PJuceSampleArray;
begin
  Suite('Audio buffers');
  CheckRaises(EJuceError, MakeBadBuffer, 'invalid size raises EJuceError');
  Check(Pos('positive', LastExceptionMessage) > 0, 'message from the C side: ' + LastExceptionMessage);

  A := TJuceAudioBuffer.Create(2, 64);
  B := TJuceAudioBuffer.Create(2, 64);
  try
    Check((A.NumChannels = 2) and (A.NumSamples = 64), 'dimensions');
    A[0]^[10] := 0.5;
    A.ApplyGain(2.0);
    CheckEquals(1.0, A[0]^[10], 1e-6, 'write pointer + ApplyGain');
    B.CopyFrom(1, 0, A, 0, 0, 64);
    B.AddFrom(1, 0, A, 0, 0, 64, 0.5);
    CheckEquals(1.5, B.Magnitude(1, 0, 64), 1e-6, 'CopyFrom + AddFrom + Magnitude');
    A.Clear(0, 32);
    CheckEquals(0.0, A[0]^[10], 0, 'Clear region');

    { Regression: cached pointer + Clear must not make later operations no-ops. }
    Cached := A[0];
    A.Clear;
    Cached^[5] := 0.25;
    CheckEquals(0.25, A.Magnitude(0, 0, 64), 1e-7, 'writes via a cached pointer after Clear are seen');

    A.SetSize(1, 128);
    Check((A.NumChannels = 1) and (A.NumSamples = 128), 'SetSize');
  finally
    A.Free;
    B.Free;
  end;
end;

{ ---------------------------------------------------------------------------- }

type
  TMidiProbe = class
    Count, LastPos: Integer;
    LastStatus: Byte;
    RaiseOnVisit: Boolean;
    procedure Visit(Data: PByte; Size, SamplePosition: Integer);
  end;

procedure TMidiProbe.Visit(Data: PByte; Size, SamplePosition: Integer);
begin
  Inc(Count);
  LastPos := SamplePosition;
  if Size > 0 then
    LastStatus := Data^;
  if RaiseOnVisit then
    raise EInvalidOp.Create('visitor failure');
end;

var
  GBuf: TJuceMidiBuffer;
  GProbe: TMidiProbe;

procedure AddTruncated;
begin
  GBuf.Add([$90, 60], 0);
end;

procedure EnumerateRaising;
begin
  GBuf.Enumerate(GProbe.Visit);
end;

procedure DescribeNegative;
begin
  MidiDescription(nil, -1);
end;

procedure TestMidi;
var
  Bytes: TBytes;
begin
  Suite('MIDI buffers and helpers');
  GBuf := TJuceMidiBuffer.Create;
  GProbe := TMidiProbe.Create;
  try
    GBuf.Add(MidiNoteOn(1, 60, 100), 5);
    GBuf.Add(MidiNoteOff(1, 60), 40);
    GBuf.Add(MidiControlChange(2, 7, 127), 20);
    CheckEquals(3, GBuf.Count, 'three events');
    GBuf.Enumerate(GProbe.Visit);
    Check((GProbe.Count = 3) and (GProbe.LastPos = 40) and (GProbe.LastStatus = $80), 'Enumerate in time order');
    CheckRaises(EJuceError, AddTruncated, 'truncated message rejected');

    GProbe.Count := 0;
    GProbe.RaiseOnVisit := True;
    CheckRaises(EInvalidOp, EnumerateRaising, 'exception in visitor is re-raised (regression)');
    CheckEquals(1, GProbe.Count, 'iteration stops at the failing event');
  finally
    GProbe.Free;
    GBuf.Free;
  end;

  CheckEquals('C3', MidiNoteName(60), 'MidiNoteName(60)');
  CheckEquals('Db3', MidiNoteName(61, False), 'MidiNoteName(61, flats)');
  CheckEquals(440.0, MidiNoteToHz(69), 1e-9, 'MidiNoteToHz(69)');
  Check(Pos('Note on', MidiDescription(MidiNoteOn(1, 60, 100))) = 1, 'MidiDescription');
  CheckRaises(EJuceError, DescribeNegative, 'MidiDescription rejects negative size');
  Bytes := MidiNoteOn(1, 300, -5);
  Check((Bytes[1] = 127) and (Bytes[2] = 0), 'helpers clamp data bytes to 0..127');
  Bytes := MidiNoteOn(99, 60, 1);
  CheckEquals($9F, Bytes[0], 'channel clamped to 16');
  CheckEquals($40, MidiPitchBend(1, $2000)[2], 'pitch bend centre');
end;

{ ---------------------------------------------------------------------------- }

type
  TAudioProbe = class
    Blocks, Starts, Stops, MidiEvents, LastNote, Changes: Integer;
    StartRate: Double;
    LastSamples: Integer;
    InputPeak: Single;
    Work: Integer;
    RaiseEvery: Integer;
    RaiseInMidi: Boolean;
    procedure Audio(Sender: TJuceAudioDeviceManager; Inputs: PJuceChannelArray; NumInputs: Integer;
      Outputs: PJuceChannelArray; NumOutputs: Integer; NumSamples: Integer; const Midi: TJuceMidiView);
    procedure Started(Sender: TJuceAudioDeviceManager; SampleRate: Double; ExpectedBlockSize: Integer);
    procedure Stopped(Sender: TObject);
    procedure Changed(Sender: TObject);
    procedure OnMidi(Data: PByte; Size, SamplePosition: Integer);
  end;

procedure TAudioProbe.OnMidi(Data: PByte; Size, SamplePosition: Integer);
begin
  Inc(MidiEvents);
  if Size >= 2 then
    LastNote := Data[1];
  if RaiseInMidi then
    raise Exception.Create('midi handler failure');
end;

procedure TAudioProbe.Audio(Sender: TJuceAudioDeviceManager; Inputs: PJuceChannelArray; NumInputs: Integer;
  Outputs: PJuceChannelArray; NumOutputs: Integer; NumSamples: Integer; const Midi: TJuceMidiView);
var
  S: string;
  A: array of Integer;
  I, Ch: Integer;
  Peak: Single;
begin
  Inc(Blocks);
  LastSamples := NumSamples;
  { Deliberately NOT real-time safe: heap, strings and exceptions on a JUCE
    thread exercise the FPC threadvar fix (heap/exception state per thread). }
  S := Format('block %d of %d samples', [Blocks, NumSamples]);
  SetLength(A, 64 + Blocks mod 32);
  A[High(A)] := Length(S);
  Work := Work + A[High(A)];
  Peak := 0;
  for Ch := 0 to NumInputs - 1 do
    for I := 0 to NumSamples - 1 do
      Peak := Max(Peak, Abs(Inputs^[Ch]^[I]));
  InputPeak := Peak;
  Midi.Enumerate(OnMidi);
  if (RaiseEvery > 0) and (Blocks mod RaiseEvery = 0) then
    raise Exception.CreateFmt('planned failure in block %d', [Blocks]);
end;

procedure TAudioProbe.Started(Sender: TJuceAudioDeviceManager; SampleRate: Double; ExpectedBlockSize: Integer);
begin
  Inc(Starts);
  StartRate := SampleRate;
end;

procedure TAudioProbe.Stopped(Sender: TObject);
begin
  Inc(Stops);
end;

procedure TAudioProbe.Changed(Sender: TObject);
begin
  Inc(Changes);
end;

var
  GMgr: TJuceAudioDeviceManager;
  GAudio: TAudioProbe;

procedure SetHandlerWhileOpen;
begin
  GMgr.OnAudio := GAudio.Audio;
end;

procedure ShutdownWithLiveManager;
begin
  JuceShutdown;
end;

procedure LongDeviceName;
var
  S: TJuceAudioDeviceSetup;
begin
  S := GMgr.Setup;
  S.OutputDeviceName := StringOfChar('x', 300);
  GMgr.Setup := S;
end;

procedure TestDeviceManager;
var
  Setup: TJuceAudioDeviceSetup;
  I, Blocks0, Churn: Integer;
  Junk: TStringDynArray;
  Types: TStringDynArray;
  HasVirtual: Boolean;
begin
  Suite('Device manager on the Virtual device');
  GAudio := TAudioProbe.Create;
  GMgr := TJuceAudioDeviceManager.Create;
  try
    GMgr.OnAudio := GAudio.Audio;
    GMgr.OnAudioStart := GAudio.Started;
    GMgr.OnAudioStop := GAudio.Stopped;
    GMgr.OnChange := GAudio.Changed;
    GMgr.AddVirtualDeviceType(True, viTone);

    Types := GMgr.DeviceTypeNames;
    HasVirtual := False;
    for I := 0 to High(Types) do
      HasVirtual := HasVirtual or (Types[I] = 'Virtual');
    Check(HasVirtual and (Length(Types) > 1), 'Virtual listed alongside platform types');

    GMgr.Initialise(2, 2, 'Virtual');
    CheckEquals('Virtual', GMgr.CurrentDeviceType, 'Initialise(..., ''Virtual'')');
    CheckEquals('Virtual Device', GMgr.CurrentDeviceName, 'device name');
    CheckEquals(1, GAudio.Starts, 'OnAudioStart once');
    CheckEquals(GMgr.SampleRate, GAudio.StartRate, 0, 'OnAudioStart rate');
    CheckEquals(8, Length(GMgr.ChannelNames(True)), 'channel names');
    Check(Length(GMgr.AvailableSampleRates) = 6, 'available sample rates');
    CheckRaises(EJuceError, SetHandlerWhileOpen, 'changing OnAudio while open raises');

    { Heap churn on the main thread while the audio thread allocates too. }
    Blocks0 := GAudio.Blocks;
    GAudio.RaiseEvery := 7;
    Churn := 0;
    while GAudio.Blocks < Blocks0 + 30 do
    begin
      SetLength(Junk, 200);
      for I := 0 to High(Junk) do
        Junk[I] := IntToStr(I * Churn) + '...';
      Inc(Churn);
      JuceDispatchMessages(1);
    end;
    GAudio.RaiseEvery := 0;
    Check(GAudio.Work > 0, Format('allocating handler ran %d blocks alongside %d main-thread churn rounds',
      [GAudio.Blocks - Blocks0, Churn]));
    Check(GMgr.ConsumeCallbackErrorCount >= 3, 'exceptions in OnAudio contained and counted');
    CheckEquals(0, GMgr.ConsumeCallbackErrorCount, 'count resets');
    CheckEquals(0.25, GAudio.InputPeak, 0.01, 'virtual input tone visible in Inputs');

    GMgr.AddMidiMessage(MidiNoteOn(1, 64, 100));
    WaitMs(150);
    Check((GAudio.MidiEvents = 1) and (GAudio.LastNote = 64), 'AddMidiMessage -> Midi.Enumerate in OnAudio');
    GAudio.RaiseInMidi := True;
    GMgr.AddMidiMessage(MidiNoteOn(1, 65, 100));
    WaitMs(150);
    GAudio.RaiseInMidi := False;
    CheckEquals(1, GMgr.ConsumeCallbackErrorCount, 'exception in a MIDI handler inside OnAudio is counted (regression)');

    Setup := GMgr.Setup;
    CheckEquals('Virtual Device', Setup.OutputDeviceName, 'Setup.OutputDeviceName');
    Check((0 in Setup.OutputChannels) and (1 in Setup.OutputChannels) and not (2 in Setup.OutputChannels),
      'Setup.OutputChannels = [0, 1]');
    Setup.SampleRate := 96000;
    Setup.BufferSize := 128;
    Setup.OutputChannels := [3];
    Setup.UseDefaultOutputChannels := False;
    GMgr.Setup := Setup;
    CheckEquals(96000.0, GMgr.SampleRate, 0, 'sample-rate change via Setup');
    CheckEquals(1, GMgr.ActiveOutputChannelCount, 'channel set [3] -> one active output');
    WaitMs(50);
    CheckEquals(128, GAudio.LastSamples, 'OnAudio sees the new block size');
    Check(GAudio.Changes > 0, 'OnChange fired');
    CheckRaises(EJuceError, LongDeviceName, 'device name over 255 UTF-8 bytes raises instead of truncating');

    I := GMgr.XRunCount;
    GMgr.SimulateXRun;
    CheckEquals(I + 1, GMgr.XRunCount, 'SimulateXRun');

    CheckRaises(EJuceError, ShutdownWithLiveManager, 'JuceShutdown with a live manager raises');
    Check(JuceIsInitialised, '...and leaves JUCE running');

    GMgr.Close;
    Check(GAudio.Stops >= 1, 'OnAudioStop after Close');
    GMgr.OnAudio := GAudio.Audio;
    Check(True, 'handlers can be changed while closed');
    GMgr.Initialise(0, 2, 'Virtual');
    Check(GMgr.IsDeviceOpen, 'Initialise again after Close');
  finally
    GMgr.Free;
    GAudio.Free;
  end;
end;

{ ---------------------------------------------------------------------------- }

{ ---------------------------------------------------------------------------- }
{ Concurrency stress: both threads hammer the Pascal heap at the same time.   }
{ Without per-thread RTL state for JUCE's threads (the FPC threadvar issue)  }
{ this corrupts the heap within a few hundred milliseconds.                  }

type
  TStressProbe = class
    Blocks: Integer;
    Bad: Integer;
    procedure Audio(Sender: TJuceAudioDeviceManager; Inputs: PJuceChannelArray; NumInputs: Integer;
      Outputs: PJuceChannelArray; NumOutputs: Integer; NumSamples: Integer; const Midi: TJuceMidiView);
  end;

procedure TStressProbe.Audio(Sender: TJuceAudioDeviceManager; Inputs: PJuceChannelArray; NumInputs: Integer;
  Outputs: PJuceChannelArray; NumOutputs: Integer; NumSamples: Integer; const Midi: TJuceMidiView);
var
  K: Integer;
  S: string;
  A: array of Integer;
begin
  for K := 1 to 200 do
  begin
    S := IntToStr(K) + '-audio-' + IntToStr(Blocks);
    SetLength(A, 1 + K mod 17);
    A[High(A)] := K;
    if (A[High(A)] <> K) or (Pos('-audio-', S) = 0) then
      Inc(Bad);
  end;
  Inc(Blocks);
end;

{ ---------------------------------------------------------------------------- }
{ Round-1 review regressions                                                    }

type
  TLoopProbe = class
    Blocks: Integer;
    RaiseNext: Boolean;      { next block: write full scale, then raise }
    WriteNext: Boolean;      { next block: write full scale normally }
    InputPeakAfter: Single;  { peak of the inputs in the block after the action }
    Phase: Integer;          { 0 idle, 1 acted (inspect next block), 2 inspected }
    procedure Audio(Sender: TJuceAudioDeviceManager; Inputs: PJuceChannelArray; NumInputs: Integer;
      Outputs: PJuceChannelArray; NumOutputs: Integer; NumSamples: Integer; const Midi: TJuceMidiView);
  end;

procedure TLoopProbe.Audio(Sender: TJuceAudioDeviceManager; Inputs: PJuceChannelArray; NumInputs: Integer;
  Outputs: PJuceChannelArray; NumOutputs: Integer; NumSamples: Integer; const Midi: TJuceMidiView);
var
  Ch, I: Integer;
  Peak: Single;
begin
  Inc(Blocks);
  if Phase = 1 then
  begin
    Peak := 0;
    for Ch := 0 to NumInputs - 1 do
      for I := 0 to NumSamples - 1 do
        Peak := Max(Peak, Abs(Inputs^[Ch]^[I]));
    InputPeakAfter := Peak;
    Phase := 2;
  end;
  if RaiseNext or WriteNext then
  begin
    for Ch := 0 to NumOutputs - 1 do
      for I := 0 to NumSamples - 1 do
        Outputs^[Ch]^[I] := 0.9;
    Phase := 1;
    if RaiseNext then
    begin
      RaiseNext := False;
      raise Exception.Create('after writing a full-scale block');
    end;
    WriteNext := False;
  end;
end;

type
  TSetterThread = class(TThread)
  public
    Mgr: TJuceAudioDeviceManager;
    Handler: TJuceAudioEvent;
    Raised: Boolean;
    procedure Execute; override;
  end;

procedure TSetterThread.Execute;
begin
  try
    Mgr.OnAudio := Handler;
  except
    on EJuceError do
      Raised := True;
  end;
end;

procedure WaitPhase(P: TLoopProbe);
var
  Deadline: Double;
begin
  Deadline := JuceMillisecondCounter + 2000;
  while (P.Phase <> 2) and (JuceMillisecondCounter < Deadline) do
    JuceDispatchMessages(2);
end;

procedure TestRound1Regressions;
var
  Mgr: TJuceAudioDeviceManager;
  P: TLoopProbe;
  T: TSetterThread;
begin
  Suite('Review round 1 regressions');
  P := TLoopProbe.Create;
  Mgr := TJuceAudioDeviceManager.Create;
  try
    Mgr.OnAudio := P.Audio;
    Mgr.AddVirtualDeviceType(True, viLoopback);
    Mgr.Initialise(2, 2, 'Virtual');

    P.WriteNext := True;
    WaitPhase(P);
    CheckEquals(0.9, P.InputPeakAfter, 1e-6, 'loopback carries a normally written block');

    P.Phase := 0;
    P.RaiseNext := True;
    WaitPhase(P);
    CheckEquals(0.0, P.InputPeakAfter, 0, 'block written then raised in OnAudio is silenced (not played)');
    Check(Mgr.ConsumeCallbackErrorCount >= 1, 'and counted');

    Mgr.Close;
    T := TSetterThread.Create(True);
    try
      T.Mgr := Mgr;
      T.Handler := P.Audio;
      T.Start;
      T.WaitFor;
      Check(T.Raised, 'assigning OnAudio from another thread raises (even when closed)');
    finally
      T.Free;
    end;
  finally
    Mgr.Free;
    P.Free;
  end;
end;

function CodeOfRaise(Proc: TTestProcPlain): Integer;
begin
  Result := -1;
  try
    Proc;
    Result := 0;
  except
    on E: EJuceError do
      Result := E.Code;
    on E: Exception do
      Result := -2;
  end;
end;

procedure NulInPath;
var
  R: TJuceAudioFileReader;
begin
  R := TJuceAudioFileReader.Create('missing'#0'.wav');
  R.Free;
end;

procedure NilSource;
var
  B: TJuceAudioBuffer;
begin
  B := TJuceAudioBuffer.Create(1, 8);
  try
    B.AddFrom(0, 0, nil, 0, 0, 8, 1.0);
  finally
    B.Free;
  end;
end;

procedure NilCopySource;
var
  B: TJuceAudioBuffer;
begin
  B := TJuceAudioBuffer.Create(1, 8);
  try
    B.CopyFrom(0, 0, nil, 0, 0, 8);
  finally
    B.Free;
  end;
end;

type
  TReenterProbe = class
  public
    Mgr: TJuceAudioDeviceManager;
    CloseCode, FreeCode: Integer;
    Starts: Integer;
    procedure Start(Sender: TJuceAudioDeviceManager; SampleRate: Double; BlockSize: Integer);
  end;

procedure TReenterProbe.Start(Sender: TJuceAudioDeviceManager; SampleRate: Double; BlockSize: Integer);
begin
  Inc(Starts);
  if Starts <> 1 then
    Exit;
  try
    Mgr.Close;
    CloseCode := 0;
  except
    on E: EJuceError do
      CloseCode := E.Code;
  end;
  try
    Mgr.Free;
    FreeCode := 0;
  except
    on E: EJuceError do
      FreeCode := E.Code;
  end;
end;

procedure TestReentrancy;
var
  P: TReenterProbe;
begin
  Suite('Re-entrant calls from manager handlers');
  P := TReenterProbe.Create;
  P.CloseCode := -1;
  P.FreeCode := -1;
  P.Mgr := TJuceAudioDeviceManager.Create;
  try
    P.Mgr.OnAudioStart := P.Start;
    P.Mgr.AddVirtualDeviceType(True, viSilence);
    P.Mgr.Initialise(0, 2, 'Virtual');
    CheckEquals(JUCE_C_INVALID_STATE, P.CloseCode, 'Close inside OnAudioStart raises EJuceError (was a use-after-free)');
    CheckEquals(JUCE_C_INVALID_STATE, P.FreeCode, 'Free inside OnAudioStart raises and keeps the object alive');
    Check(P.Mgr.IsDeviceOpen, 'device still open after the refused calls');
  finally
    P.Mgr.Free;
    P.Free;
  end;
end;

type
  { Fable review round 1: a constructor that opened the device and then raised
    left the audio thread calling into its half-destroyed fields. }
  TOpenInCreate = class(TJuceAudioDeviceManager)
  public
    constructor Create;
  end;

  TOpenAfterConstruction = class(TJuceAudioDeviceManager)
  public
    procedure AfterConstruction; override;
  end;

constructor TOpenInCreate.Create;
begin
  inherited Create;
  AddVirtualDeviceType(True, viSilence);
  Initialise(0, 2, 'Virtual'); { refused: construction has not finished }
end;

procedure TOpenAfterConstruction.AfterConstruction;
begin
  inherited;
  AddVirtualDeviceType(True, viSilence);
  Initialise(0, 2, 'Virtual');
end;

procedure OpenInConstructor;
var
  M: TOpenInCreate;
begin
  M := TOpenInCreate.Create;
  M.Free;
end;

procedure TestConstructionRules;
var
  M: TOpenAfterConstruction;
begin
  Suite('Opening devices only after construction');
  CheckEquals(JUCE_C_INVALID_STATE, CodeOfRaise(OpenInConstructor),
    'Initialise inside a constructor is refused (a later raise would leave callbacks running)');
  M := TOpenAfterConstruction.Create;
  try
    Check(M.IsDeviceOpen, 'opening in AfterConstruction works');
  finally
    M.Free;
  end;
end;

var
  GLiveBuffer: TJuceAudioBuffer;

procedure RecreateLiveBuffer;
begin
  GLiveBuffer.Create(1, 8); { the slip "Obj.Create;" instead of "Obj := T.Create;" }
end;

procedure TestRecreateLive;
begin
  Suite('Create on an existing object');
  GLiveBuffer := TJuceAudioBuffer.Create(1, 8);
  try
    CheckEquals(0, CodeOfRaise(RecreateLiveBuffer),
      'Create called on a live object is a no-op (used to orphan its handle)');
    CheckEquals(8, GLiveBuffer.NumSamples, 'the object is unchanged');
  finally
    GLiveBuffer.Free;
  end;
end;

type
  { Fable round 3: the slip on a subclass whose constructor sets OnAudio used to
    raise on the open device, and FPC then destroyed it with callbacks running. }
  TSubManager = class(TJuceAudioDeviceManager)
  public
    Blocks: Integer;
    constructor Create;
    procedure HandleAudio(Sender: TJuceAudioDeviceManager; Inputs: PJuceChannelArray;
      NumInputs: Integer; Outputs: PJuceChannelArray; NumOutputs, NumSamples: Integer;
      const Midi: TJuceMidiView);
  end;

constructor TSubManager.Create;
begin
  inherited Create;
  OnAudio := HandleAudio;
end;

procedure TSubManager.HandleAudio(Sender: TJuceAudioDeviceManager; Inputs: PJuceChannelArray;
  NumInputs: Integer; Outputs: PJuceChannelArray; NumOutputs, NumSamples: Integer;
  const Midi: TJuceMidiView);
begin
  Inc(Blocks);
end;

var
  GSub: TSubManager;

procedure RecreateSubManager;
begin
  GSub.Create;
end;

procedure TestRecreateSubclass;
begin
  Suite('Create on an existing subclass with an open device');
  GSub := TSubManager.Create;
  try
    GSub.AddVirtualDeviceType(True, viSilence);
    GSub.Initialise(0, 2, 'Virtual');
    CheckEquals(0, CodeOfRaise(RecreateSubManager), 'the slip does not raise (device closed first)');
    Check(not GSub.IsDeviceOpen, 'device closed: no callbacks into a re-constructed object');
    GSub.Initialise(0, 2, 'Virtual');
    Check(GSub.IsDeviceOpen, 'the object stays usable');
  finally
    GSub.Free;
  end;
end;

procedure TestRound2Regressions;
begin
  Suite('Review round 2 regressions');
  CheckEquals(JUCE_C_INVALID_ARGUMENT, CodeOfRaise(NulInPath),
    'a NUL inside a string is refused, not silently truncated');
  CheckEquals(JUCE_C_INVALID_ARGUMENT, CodeOfRaise(NilSource), 'nil source buffer raises EJuceError, not an AV');
  CheckEquals(JUCE_C_INVALID_ARGUMENT, CodeOfRaise(NilCopySource), 'nil CopyFrom source raises EJuceError');
end;

procedure TestThreadingStress;
var
  Mgr: TJuceAudioDeviceManager;
  Probe: TStressProbe;
  Deadline: Double;
  Rounds, K, MainBad: Integer;
  Strings: array[0..255] of string;
begin
  Suite('Concurrency stress (Pascal heap on JUCE threads)');
  Probe := TStressProbe.Create;
  Mgr := TJuceAudioDeviceManager.Create;
  try
    Mgr.OnAudio := Probe.Audio;
    Mgr.AddVirtualDeviceType(False); { offline: the audio thread never sleeps }
    Mgr.Initialise(0, 2, 'Virtual');
    Rounds := 0;
    MainBad := 0;
    Deadline := JuceMillisecondCounter + 400;
    while JuceMillisecondCounter < Deadline do
    begin
      for K := 0 to High(Strings) do
        Strings[K] := IntToStr(K * Rounds) + '-main';
      for K := 0 to High(Strings) do
        if Strings[K] <> IntToStr(K * Rounds) + '-main' then
          Inc(MainBad);
      Inc(Rounds);
    end;
    Mgr.Close;
    Check(Probe.Blocks > 100, Format('%d audio blocks x 200 allocations ran against %d main-thread rounds',
      [Probe.Blocks, Rounds]));
    CheckEquals(0, Probe.Bad + MainBad, 'no corrupted values on either thread');
    CheckEquals(0, Mgr.ConsumeCallbackErrorCount, 'no exceptions on the audio thread');
  finally
    Mgr.Free;
    Probe.Free;
  end;
end;

var
  GPtrs: array[0..0] of PJuceSampleArray;
  GWriter: TJuceAudioFileWriter;

procedure WriteNilChannel;
begin
  GWriter.WriteChannels(@GPtrs, 1, 16);
end;

procedure OpenMissingFile;
begin
  TJuceAudioFileReader.Create(GetTempDir + 'pascaljuce_missing.wav').Free;
end;

procedure TestAudioFiles;
const
  N = 4800;
var
  Src, Loaded, Stereo: TJuceAudioBuffer;
  Writer: TJuceAudioFileWriter;
  Reader: TJuceAudioFileReader;
  Dir, WavPath, FlacPath, OggPath: string;
  I: Integer;
  Rate, MaxErr: Double;
begin
  Suite('Audio files');
  Check(Pos('*.wav', JuceAudioFileWildcard) > 0, 'wildcard includes *.wav');

  Dir := IncludeTrailingPathDelimiter(GetTempDir) + 'pascaljuce_test';
  ForceDirectories(Dir);
  WavPath := Dir + PathDelim + 'sine.wav';
  FlacPath := Dir + PathDelim + 'sine.flac';
  OggPath := Dir + PathDelim + 'sine.ogg';

  Src := TJuceAudioBuffer.Create(1, N);
  try
    for I := 0 to N - 1 do
      Src[0]^[I] := 0.5 * Sin(2 * Pi * 440 * I / 48000);

    Writer := TJuceAudioFileWriter.Create(WavPath, 48000, 1, 32);
    try
      Writer.Write(Src, 0, N);
      Writer.Flush;
    finally
      Writer.Free;
    end;
    Writer := TJuceAudioFileWriter.Create(FlacPath, 48000, 1, 24);
    try
      GPtrs[0] := nil;
      GWriter := Writer;
      CheckRaises(EJuceError, WriteNilChannel, 'WriteChannels rejects a nil channel pointer');
      GPtrs[0] := Src[0];
      Writer.WriteChannels(@GPtrs, 1, N);
    finally
      Writer.Free;
    end;
    Writer := TJuceAudioFileWriter.Create(OggPath, 48000, 1); { default 24-bit: Ogg ignores depth }
    Writer.Write(Src, 0, N);
    Writer.Free;
    Check(FileExists(OggPath), 'Ogg written with the default bit depth (regression)');

    Loaded := JuceLoadAudioFile(WavPath, Rate);
    try
      Check((Rate = 48000) and (Loaded.NumChannels = 1) and (Loaded.NumSamples = N), 'WAV loads');
      MaxErr := 0;
      for I := 0 to N - 1 do
        MaxErr := Max(MaxErr, Abs(Loaded[0]^[I] - Src[0]^[I]));
      CheckEquals(0.0, MaxErr, 0, '32-bit float WAV round-trip is exact');
    finally
      Loaded.Free;
    end;

    Reader := TJuceAudioFileReader.Create(FlacPath);
    Stereo := TJuceAudioBuffer.Create(2, N);
    try
      Check((Reader.FormatName = 'FLAC file') and (Reader.BitsPerSample = 24) and (Reader.Length = N), 'FLAC info');
      Reader.Read(Stereo, 0, N, 0);
      MaxErr := 0;
      for I := 0 to N - 1 do
        MaxErr := Max(MaxErr, Abs(Stereo[1]^[I] - Src[0]^[I]));
      Check(MaxErr < 1e-5, Format('24-bit FLAC mono -> stereo (max err %.2g)', [MaxErr]));
    finally
      Stereo.Free;
      Reader.Free;
    end;
  finally
    Src.Free;
  end;

  CheckRaises(EJuceError, OpenMissingFile, 'missing file raises');
  Check(Pos('File not found', LastExceptionMessage) = 1, 'message: ' + LastExceptionMessage);

  DeleteFile(WavPath);
  DeleteFile(FlacPath);
  DeleteFile(OggPath);
  RemoveDir(Dir);
end;

{ ---------------------------------------------------------------------------- }

type
  TMidiReceiver = class
    Received, LastNote: Integer;
    Fail: Boolean;
    procedure Handle(Sender: TJuceMidiInput; Data: PByte; Size: Integer; TimestampSeconds: Double);
  end;

procedure TMidiReceiver.Handle(Sender: TJuceMidiInput; Data: PByte; Size: Integer; TimestampSeconds: Double);
begin
  if (Size = 3) and ((Data[0] and $F0) = $90) then
  begin
    LastNote := Data[1];
    Inc(Received);
  end;
  if Fail then
    raise Exception.Create('receiver failure');
end;

function FindDevice(const Devices: TJuceMidiDeviceInfoArray; const Name: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Devices) do
    if Devices[I].Name = Name then
      Exit(Devices[I].Identifier);
end;

procedure OpenBogusOutput;
begin
  TJuceMidiOutput.Create('no-such-device').Free;
end;

procedure TestMidiDevices;
var
  OutId, InId: string;
  Output: TJuceMidiOutput;
  Input: TJuceMidiInput;
  Receiver: TMidiReceiver;
  Deadline: Double;
begin
  Suite('MIDI devices');
  Check(Length(JuceMidiInputDevices) >= 0, Format('%d MIDI inputs, %d outputs',
    [Length(JuceMidiInputDevices), Length(JuceMidiOutputDevices)]));
  CheckRaises(EJuceError, OpenBogusOutput, 'unknown output identifier raises (regression)');

  OutId := FindDevice(JuceMidiOutputDevices, 'Default App Loopback (A)');
  InId := FindDevice(JuceMidiInputDevices, 'Default App Loopback (B)');
  if (OutId = '') or (InId = '') then
  begin
    Skip('MIDI loopback', 'Windows MIDI Services loopback ports not present');
    Exit;
  end;

  Receiver := TMidiReceiver.Create;
  Input := TJuceMidiInput.Create(InId, Receiver.Handle);
  Output := TJuceMidiOutput.Create(OutId);
  try
    Input.Start;
    Output.Send(MidiNoteOn(1, 64, 90));
    Deadline := JuceMillisecondCounter + 2000;
    while (Receiver.Received = 0) and (JuceMillisecondCounter < Deadline) do
      JuceDispatchMessages(10);
    Check((Receiver.Received = 1) and (Receiver.LastNote = 64), 'loopback note received on a MIDI thread');

    Receiver.Fail := True;
    Output.Send(MidiNoteOn(1, 65, 90));
    Deadline := JuceMillisecondCounter + 2000;
    while (Receiver.Received = 1) and (JuceMillisecondCounter < Deadline) do
      JuceDispatchMessages(10);
    WaitMs(20);
    CheckEquals(1, Input.ConsumeCallbackErrorCount, 'handler exception counted atomically');
    CheckEquals(0, Input.ConsumeCallbackErrorCount, 'count resets');
    Input.Stop;
  finally
    Output.Free;
    Input.Free;
    Receiver.Free;
  end;
end;

begin
  try
    TestLibrary;
    TestBuffers;
    TestMidi;
    TestDeviceManager;
    TestThreadingStress;
    TestRound1Regressions;
    TestRound2Regressions;
    TestReentrancy;
    TestConstructionRules;
    TestRecreateLive;
    TestRecreateSubclass;
    TestAudioFiles;
    TestMidiDevices;
    JuceShutdown;
    Check(not JuceIsInitialised, 'final JuceShutdown');
  except
    on E: Exception do
      Check(False, 'Unhandled ' + E.ClassName + ': ' + E.Message);
  end;
  Halt(TestSummary);
end.
