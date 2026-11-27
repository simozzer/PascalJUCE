// MzPCF - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// The plug-in: the Object Pascal counterpart of Source/PluginProcessor.cpp, on the
// PascalJUCE framework rather than juce::AudioProcessor. An effect: stereo in and out, or
// mono in and out (the C++ isBusesLayoutSupported); no MIDI.
//
// Each block, as the C++ processBlock: the parameters are read into the engine's settings,
// then the host's timeline at the top of the block (playing, position, tempo) is given to
// the engine, which runs its clock forward sample by sample from there. No timeline, or
// stopped: nothing is struck and the filter settles back to FREQ.
//
// The panel (MzPcfEditor) shows the step playing: Process publishes it with SetMeter (slot
// MeterStep; -1 stopped), where the C++ panel reads the engine's atomic.
//
// No state beyond the parameters (the wrapper saves those), as the C++ saves only its
// parameter tree.

unit MzPcfPlugin;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  SysUtils, JucePlugin, JuceTypes, PcfMath, PcfEngine, MzPcfParams;

const
  // What Process publishes for the panel (TJucePlugin.SetMeter slots).
  MeterStep = 0;   // the step last struck, 0..15; -1 stopped

type
  TMzPcf = class(TJucePlugin)
  private
    FEngine: TPcf;
    FValues: array[0..NumParams - 1] of Single;
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
    // For tests: the engine, read-only use.
    function Engine: TPcf;
  end;

// Declares the parameters and registers TMzPcf. Call once, from the library's begin..end.
procedure RegisterMzPcf;

implementation

uses
  MzPcfEditor;

{ TMzPcf }

constructor TMzPcf.Create;
begin
  inherited Create;
  FEngine.Init;
end;

function TMzPcf.CreateEditor: TJuceEditorBase;
begin
  Result := TMzPcfEditor.Create(Self);
end;

procedure TMzPcf.Prepare(ASampleRate: Double; AMaxBlockSize: Integer);
var
  I: Integer;
begin
  FEngine.Prepare(ASampleRate);
  for I := 0 to NumParams - 1 do
    FValues[I] := GetParameter(I);
  FEngine.SetSettings(SettingsFromValues(FValues));
  SetMeter(MeterStep, FEngine.Step);
end;

procedure TMzPcf.Reset;
begin
  FEngine.Reset;
  SetMeter(MeterStep, FEngine.Step);
end;

procedure TMzPcf.Process(const Ctx: TJuceProcessContext);
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
  // tempo change is followed within one block. No timeline, or stopped: nothing is struck.
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

  SetMeter(MeterStep, FEngine.Step);
end;

function TMzPcf.TailSeconds: Double;
begin
  Result := 0.0;
end;

function TMzPcf.ParameterToText(Index: Integer; Value: Single; out Text: string): Boolean;
begin
  Text := FormatValue(Index, Value);
  Result := Text <> '';
end;

function TMzPcf.Step: Integer;
begin
  Result := FEngine.Step;
end;

function TMzPcf.Engine: TPcf;
begin
  Result := FEngine;
end;

procedure RegisterMzPcf;
var
  I: Integer;
begin
  // In the order of Specs, so each control's parameter index is its index there.
  for I := 0 to NumSpecs - 1 do
    case Specs[I].Kind of
      skKnob:
        JuceAddFloatParameter(Specs[I].Id, Specs[I].Name, Specs[I].Min, Specs[I].Max, DefaultValue(I));
      skChoice:
        JuceAddChoiceParameter(Specs[I].Id, Specs[I].Name, ['LP', 'BP'], Round(DefaultValue(I)));
      skNumber:
        JuceAddIntParameter(Specs[I].Id, Specs[I].Name, Round(Specs[I].Min), Round(Specs[I].Max),
          Round(DefaultValue(I)));
    end;

  JuceRegisterPlugin(TMzPcf, jkEffect);
end;

end.
