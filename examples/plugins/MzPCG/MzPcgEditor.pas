// MzPCG - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// The panel: the Object Pascal counterpart of Source/PluginEditor.cpp and Look.cpp, on
// PascalJUCE's controls. No LCL or VCL here: the panel is designed as a form
// (MzPcgEditorForm.lfm, in Lazarus with MzPcgDesign.lpi, or MzPcgEditorForm.dfm in Delphi),
// embedded in the library, and built from it at run time. The form holds the IDE's own
// controls as stand-ins for the C++ panel's: when the panel is built each stand-in is
// swapped for the real control (MzPCF's PcfControls, and PcgControls for the gain's
// picture), with its name, place and properties -
//
//   Face, PcgUnit, OutUnit           TJucePanel   -> TPcfFace (drawFace)
//   Depth, Attack, Hold, Decay,      TJuceKnob    -> TPcfKnob (Look::drawRotarySlider, the
//   Mix, Level                                       C++ Knob's drag, wheel and bubble)
//   PatternNumber                    TJuceDisplay -> TPcfLedNumber (LedNumber), on "pattern"
//   GainDisplay                      TJuceDisplay -> TPcgGainDisplay (GainDisplay)
//   Mode, Rate                       TJuceButton  -> TPcfSwitch (Switch)
//
// and every hover hint is set from the parameter table (MzPcgParams), as the C++ sets them
// from params::spec. The gain's picture follows the parameters and what the plug-in
// publishes (MzPcgPlugin.MeterStep, MeterGain) on the editor's 30 Hz timer, as the C++
// timerCallback does. A fixed 840 x 170, as the C++ editor.
unit MzPcgEditor;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ENDIF}

interface

uses
  JucePlugin, JuceUI, JuceControls, PcfControls, PcgEngine, PcgControls, MzPcgParams;

type
  TMzPcgEditor = class(TJuceEditor)
  private
    FSpecControl: array[0..NumSpecs - 1] of TJuceParamControl;   // by index in Specs
    FDisplay: TPcgGainDisplay;
    FParamIndex: array[0..NumSpecs - 1] of Integer;               // the editor's, by spec
    function Swap(const Name: string; NewClass: TJuceControlClass): TJuceControl;
    procedure FollowDisplay(Sender: TObject);
  public
    constructor Create(APlugin: TJucePlugin); override;
    // The control of a parameter (index in Specs), or nil.
    function SpecControl(Index: Integer): TJuceParamControl;
    // The parameters as the panel reads them, into settings (the C++ editor's reader).
    function ReadSettings: TPcgSettings;
    property GainDisplay: TPcgGainDisplay read FDisplay;
  end;

const
  // The C++ GainDisplay's hint.
  GainDisplayHint = 'The pattern''s sixteen steps, each as tall as its level, and over them the gain they ' +
    'make with the knobs as they are (drawn at 120 bpm). The step playing is lit while your ' +
    'DAW plays; the meter at the right is the gain now.';

implementation

uses
  Math, JuceLayout, MzPcgPlugin;

// The designed panel, compiled into an RCDATA resource named after the form's class
// (TMZPCGEDITORFORM).
{$IFDEF FPC}
  {$R MzPcgEditorForm.lfm}
{$ELSE}
  {$R MzPcgEditorForm.dfm}
{$ENDIF}

function TMzPcgEditor.Swap(const Name: string; NewClass: TJuceControlClass): TJuceControl;
begin
  Result := FindControl(Name);
  if Result <> nil then
    Result := PcfReplaceControl(Result, NewClass);
end;

constructor TMzPcgEditor.Create(APlugin: TJucePlugin);
const
  Knobs: array[0..5] of Integer = (PDepth, PAttack, PHold, PDecay, PMix, PLevel);
  KnobNames: array[0..5] of string = ('Depth', 'Attack', 'Hold', 'Decay', 'Mix', 'Level');
  Switches: array[0..1] of Integer = (PMode, PRate);
  SwitchNames: array[0..1] of string = ('Mode', 'Rate');
var
  I: Integer;
  C: TJuceControl;
begin
  inherited Create(APlugin);
  // Size, theme and every control come from the form.
  JuceLoadLayoutResource(Self, 'TMzPcgEditorForm');

  for I := 0 to NumSpecs - 1 do
    FParamIndex[I] := FindParameter(Specs[I].Id);

  // the faces of the panel and its two units
  Swap('Face', TPcfFace);
  Swap('PcgUnit', TPcfFace);
  Swap('OutUnit', TPcfFace);

  // the knobs, the C++ Knob: the name in capitals and what it does
  for I := 0 to High(Knobs) do
  begin
    C := Swap(KnobNames[I], TPcfKnob);
    if C is TJuceParamControl then
      FSpecControl[Knobs[I]] := TJuceParamControl(C);
  end;

  // the pattern number, the gain's picture, MODE and RATE
  C := Swap('PatternNumber', TPcfLedNumber);
  if C is TPcfLedNumber then
  begin
    TPcfLedNumber(C).ParameterId := Specs[PPattern].Id;
    TPcfLedNumber(C).Caption := '';
    FSpecControl[PPattern] := TJuceParamControl(C);
  end;
  C := Swap('GainDisplay', TPcgGainDisplay);
  if C is TPcgGainDisplay then
  begin
    FDisplay := TPcgGainDisplay(C);
    FDisplay.Caption := '';
    FDisplay.Hint := GainDisplayHint;
    FDisplay.OnFollow := FollowDisplay;
    FollowDisplay(FDisplay);   // opened showing the pattern, not after the first tick
  end;
  for I := 0 to High(Switches) do
  begin
    C := Swap(SwitchNames[I], TPcfSwitch);
    if C is TJuceParamControl then
      FSpecControl[Switches[I]] := TJuceParamControl(C);
  end;

  for I := 0 to NumSpecs - 1 do
    if FSpecControl[I] <> nil then
      FSpecControl[I].Hint := HintFor(I);
end;

function TMzPcgEditor.ReadSettings: TPcgSettings;
var
  Values: array[0..NumSpecs - 1] of Single;
  I: Integer;
begin
  for I := 0 to NumSpecs - 1 do
    if FParamIndex[I] >= 0 then
      Values[I] := ParamToPlain(FParamIndex[I], ParamNormalised(FParamIndex[I]))
    else
      Values[I] := DefaultValue(I);
  Result := SettingsFromValues(Values);
end;

procedure TMzPcgEditor.FollowDisplay(Sender: TObject);
var
  V, G: Single;
  S: Integer;
begin
  if FDisplay = nil then
    Exit;
  S := -1;
  V := Meter(MeterStep);
  if not IsNan(V) and (V >= 0) and (V < PcgStepCount) then
    S := Round(V);
  G := Meter(MeterGain);
  if IsNan(G) then
    G := 0;
  FDisplay.Show(ReadSettings, S, G);
end;

function TMzPcgEditor.SpecControl(Index: Integer): TJuceParamControl;
begin
  if (Index >= 0) and (Index < NumSpecs) then
    Result := FSpecControl[Index]
  else
    Result := nil;
end;

end.
