// MzPCG - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// The plug-in: the Object Pascal counterpart of Source/PluginProcessor.cpp, on the
// PascalJUCE framework rather than juce::AudioProcessor. An effect: stereo in and out, or
// mono in and out (the C++ isBusesLayoutSupported); no MIDI.
//
// Each block, as the C++ processBlock: the parameters are read into the engine's settings,
// then the host's timeline at the top of the block (playing, position, tempo) is given to
// the engine, which runs its clock forward sample by sample from there. No timeline, or
// stopped: nothing is struck and the sound passes untouched.
//
// The panel (MzPcgEditor) shows the step playing and the gain as it stands: Process
// publishes them with SetMeter (slots MeterStep, -1 stopped, and MeterGain), where the C++
// panel reads the engine's atomics.
//
// No state beyond the parameters (the wrapper saves those), as the C++ saves only its
// parameter tree.

unit MzPcgPlugin;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  SysUtils, JucePlugin, JuceTypes, PcfMath, PcgEngine, MzPcgParams;

const
  // What Process publishes for the panel (TJucePlugin.SetMeter slots).
  MeterStep = 0;   // the step last struck, 0..15; -1 stopped
  MeterGain = 1;   // the gain as it stands, before MIX and LEVEL

type
  TMzPcg = class(TJucePlugin)
  private
    FEngine: TPcg;
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

    // The step last struck, for the panel; -1 stopped.
    function Step: Integer;
    // The gain as it stands, for the meter.
    function Gain: Single;
    // For tests: the engine, read-only use.
    function Engine: TPcg;
  end;

// Declares the parameters and registers TMzPcg. Call once, from the library's begin..end.
procedure RegisterMzPcg;

implementation

uses
  MzPcgEditor;

{ TMzPcg }

constructor TMzPcg.Create;
begin
  inherited Create;
  FEngine.Init;
  Publish;
end;

function TMzPcg.CreateEditor: TJuceEditorBase;
begin
  Result := TMzPcgEditor.Create(Self);
end;

procedure TMzPcg.Publish;
begin
  SetMeter(MeterStep, FEngine.Step);
  SetMeter(MeterGain, FEngine.Gain);
end;

procedure TMzPcg.Prepare(ASampleRate: Double; AMaxBlockSize: Integer);
var
  I: Integer;
begin
  // prepare, then the settings, as prepareToPlay: the reset in prepare sees the old mode
  FEngine.Prepare(ASampleRate);
  for I := 0 to NumParams - 1 do
    FValues[I] := GetParameter(I);
  FEngine.SetSettings(SettingsFromValues(FValues));
  Publish;
end;

procedure TMzPcg.Reset;
begin
  FEngine.Reset;
  Publish;
end;

procedure TMzPcg.Process(const Ctx: TJuceProcessContext);
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
  // and the sound passes untouched.
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

function TMzPcg.TailSeconds: Double;
begin
  Result := 0.0;
end;

function TMzPcg.ParameterToText(Index: Integer; Value: Single; out Text: string): Boolean;
begin
  Text := FormatValue(Index, Value);
  Result := Text <> '';
end;

function TMzPcg.Step: Integer;
begin
  Result := FEngine.Step;
end;

function TMzPcg.Gain: Single;
begin
  Result := FEngine.Gain;
end;

function TMzPcg.Engine: TPcg;
begin
  Result := FEngine;
end;

procedure RegisterMzPcg;
var
  I: Integer;
begin
  // In the order of Specs, so each control's parameter index is its index there.
  for I := 0 to NumSpecs - 1 do
    case Specs[I].Kind of
      skKnob:
        JuceAddFloatParameter(Specs[I].Id, Specs[I].Name, Specs[I].Min, Specs[I].Max, DefaultValue(I));
      skChoice:
        if I = PMode then
          JuceAddChoiceParameter(Specs[I].Id, Specs[I].Name, ['GATE', 'DUCK'], Round(DefaultValue(I)))
        else
          JuceAddChoiceParameter(Specs[I].Id, Specs[I].Name, ['1/8', '1/16', '1/32'], Round(DefaultValue(I)));
      skNumber:
        JuceAddIntParameter(Specs[I].Id, Specs[I].Name, Round(Specs[I].Min), Round(Specs[I].Max),
          Round(DefaultValue(I)));
    end;

  JuceRegisterPlugin(TMzPcg, jkEffect);
end;

end.
