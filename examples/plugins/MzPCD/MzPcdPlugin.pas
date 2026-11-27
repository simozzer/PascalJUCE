// MzPCD - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// The plug-in: the Object Pascal counterpart of Source/PluginProcessor.cpp, on the
// PascalJUCE framework rather than juce::AudioProcessor. An effect: stereo in and out, or
// mono in and out (the C++ isBusesLayoutSupported); no MIDI.
//
// Each block, as the C++ processBlock: the parameters are read into the engine's settings,
// then the host's timeline at the top of the block (playing, position, tempo) is given to
// the engine, which runs its clock forward sample by sample from there. No timeline, or
// stopped: nothing is struck, and the knobs alone set the distortion.
//
// The oversampling's delay (PcdLatency, 31 samples) is reported to the host from Prepare,
// so it can line the track up with the others; the C++ reports it from its constructor
// (setLatencySamples), which the framework has no hook for - it delivers latency set in
// Prepare before the plug-in is activated. The tail is the C++'s 1.5 s: the feedback rings
// on.
//
// The panel (MzPcdEditor) shows the step playing and the push: Process publishes them with
// SetMeter (MeterStep, -1 stopped; MeterPush, the envelope 0..1), where the C++ panel reads
// the engine's atomics.
//
// No state beyond the parameters (the wrapper saves those), as the C++ saves only its
// parameter tree.

unit MzPcdPlugin;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  SysUtils, JucePlugin, JuceTypes, PcfMath, PcdEngine, MzPcdParams;

const
  // What Process publishes for the panel (TJucePlugin.SetMeter slots).
  MeterStep = 0;   // the step last struck, 0..15; -1 stopped
  MeterPush = 1;   // the envelope as it stands, 0..1: the push the pattern gives now

  // getTailLengthSeconds: the feedback rings on
  PcdTailSeconds = 1.5;

type
  TMzPcd = class(TJucePlugin)
  private
    FEngine: TPcd;
    FValues: array[0..NumParams - 1] of Single;
    procedure Publish;
  public
    constructor Create; override;
    procedure Prepare(ASampleRate: Double; AMaxBlockSize: Integer); override;
    procedure Reset; override;
    procedure Process(const Ctx: TJuceProcessContext); override;
    function TailSeconds: Double; override;
    function ParameterToText(Index: Integer; Value: Single; out Text: string): Boolean; override;
    function CreateEditor: TJuceEditorBase; override;

    // The step last struck, for the panel; -1 stopped. (The panel reads it as a meter.)
    function Step: Integer;
    // The envelope as it stands, 0..1. (The panel reads it as a meter too.)
    function Envelope: Single;
  end;

// Declares the parameters and registers TMzPcd. Call once, from the library's begin..end.
procedure RegisterMzPcd;

implementation

uses
  MzPcdEditor;

{ TMzPcd }

constructor TMzPcd.Create;
begin
  inherited Create;
  FEngine.Init;
end;

function TMzPcd.CreateEditor: TJuceEditorBase;
begin
  Result := TMzPcdEditor.Create(Self);
end;

procedure TMzPcd.Publish;
begin
  SetMeter(MeterStep, FEngine.Step);
  SetMeter(MeterPush, FEngine.Envelope);
end;

procedure TMzPcd.Prepare(ASampleRate: Double; AMaxBlockSize: Integer);
var
  I: Integer;
begin
  // the oversampling's delay, so a host can line the track up with the others
  SetLatencySamples(PcdLatency);
  FEngine.Prepare(ASampleRate);
  for I := 0 to NumParams - 1 do
    FValues[I] := GetParameter(I);
  FEngine.SetSettings(SettingsFromValues(FValues));
  Publish;
end;

procedure TMzPcd.Reset;
begin
  FEngine.Reset;
  Publish;
end;

procedure TMzPcd.Process(const Ctx: TJuceProcessContext);
var
  I: Integer;
  Playing: Boolean;
  Ppq, Bpm: Double;
  T: PJuceTransport;
  Right: PPcfSamples;
begin
  for I := 0 to NumParams - 1 do
    FValues[I] := Ctx.Param(I);
  FEngine.SetSettings(SettingsFromValues(FValues));

  // Where the host's timeline is at the top of this block. The engine runs it forward
  // sample by sample from there, and is put right again every block - so a loop jump or a
  // tempo change is followed within one block. No timeline, or stopped: nothing is struck,
  // and the knobs alone set the distortion.
  Playing := False;
  Ppq := 0.0;
  Bpm := 120.0;
  T := Ctx.Transport;
  if (T <> nil) and (T^.HasInfo <> 0) then
  begin
    Playing := T^.IsPlaying <> 0;
    Ppq := T^.PpqPosition;
    Bpm := T^.Bpm;
  end;
  FEngine.SetHostClock(Playing, Ppq, Bpm);

  if (Ctx.NumChannels > 0) and (Ctx.Channel(0) <> nil) then
  begin
    Right := nil;
    if Ctx.NumChannels > 1 then
      Right := PPcfSamples(Ctx.Channel(1));
    FEngine.Process(PPcfSamples(Ctx.Channel(0)), Right, Ctx.NumSamples);
  end;

  Publish;
end;

function TMzPcd.TailSeconds: Double;
begin
  Result := PcdTailSeconds;
end;

function TMzPcd.ParameterToText(Index: Integer; Value: Single; out Text: string): Boolean;
begin
  Text := FormatValue(Index, Value);
  Result := Text <> '';
end;

function TMzPcd.Step: Integer;
begin
  Result := FEngine.Step;
end;

function TMzPcd.Envelope: Single;
begin
  Result := FEngine.Envelope;
end;

procedure RegisterMzPcd;
var
  I: Integer;
begin
  // In the order of Specs, so each control's parameter index is its index there.
  for I := 0 to NumSpecs - 1 do
    case Specs[I].Kind of
      skKnob:
        JuceAddFloatParameter(Specs[I].Id, Specs[I].Name, Specs[I].Min, Specs[I].Max, DefaultValue(I));
      skChoice:
        JuceAddChoiceParameter(Specs[I].Id, Specs[I].Name, ['1/8', '1/16', '1/32'], Round(DefaultValue(I)));
      skNumber:
        JuceAddIntParameter(Specs[I].Id, Specs[I].Name, Round(Specs[I].Min), Round(Specs[I].Max),
          Round(DefaultValue(I)));
    end;

  JuceRegisterPlugin(TMzPcd, jkEffect);
end;

end.
