// MzPCF - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// The panel: the Object Pascal counterpart of Source/PluginEditor.cpp and Look.cpp, on
// PascalJUCE's controls. No LCL or VCL here: the panel is designed as a form
// (MzPcfEditorForm.lfm, in Lazarus with MzPcfDesign.lpi, or MzPcfEditorForm.dfm in Delphi),
// embedded in the library, and built from it at run time. The form holds the IDE's own
// controls as stand-ins for the C++ panel's (PcfControls): when the panel is built each
// stand-in is swapped for the real control, with its name, place and properties -
//
//   Face, PcfUnit, OutUnit           TJucePanel   -> TPcfFace (drawFace)
//   Freq, Q, Amount, Decay, Mix,     TJuceKnob    -> TPcfKnob (Look::drawRotarySlider, the
//   Level                                            C++ Knob's drag, wheel and bubble)
//   PatternNumber                    TJuceDisplay -> TPcfLedNumber (LedNumber), on "pattern"
//   PatternDisplay                   TJuceDisplay -> TPcfPatternDisplay (PatternDisplay)
//   Mode                             TJuceButton  -> TPcfSwitch (Switch)
//
// and every hover hint is set from the parameter table (MzPcfParams), as the C++ sets them
// from params::spec. The pattern's picture follows the pattern parameter and the step the
// plug-in publishes (MzPcfPlugin.MeterStep) on the editor's 30 Hz timer, as the C++
// timerCallback does. A fixed 690 x 170, as the C++ editor.
unit MzPcfEditor;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ENDIF}

interface

uses
  JucePlugin, JuceUI, JuceControls, PcfControls, MzPcfParams;

type
  TMzPcfEditor = class(TJuceEditor)
  private
    FSpecControl: array[0..NumSpecs - 1] of TJuceParamControl;   // by index in Specs
    FDisplay: TPcfPatternDisplay;
    function Swap(const Name: string; NewClass: TJuceControlClass): TJuceControl;
  public
    constructor Create(APlugin: TJucePlugin); override;
    // The control of a parameter (index in Specs), or nil.
    function SpecControl(Index: Integer): TJuceParamControl;
    property PatternDisplay: TPcfPatternDisplay read FDisplay;
  end;

const
  // The C++ PatternDisplay's hint.
  PatternDisplayHint = 'The pattern: on each sixteenth the filter is opened by that much, and closes again by DEC. ' +
    'The step playing is lit while your DAW plays.';

implementation

uses
  JuceLayout, MzPcfPlugin;

// The designed panel, compiled into an RCDATA resource named after the form's class
// (TMZPCFEDITORFORM).
{$IFDEF FPC}
  {$R MzPcfEditorForm.lfm}
{$ELSE}
  {$R MzPcfEditorForm.dfm}
{$ENDIF}

function TMzPcfEditor.Swap(const Name: string; NewClass: TJuceControlClass): TJuceControl;
begin
  Result := FindControl(Name);
  if Result <> nil then
    Result := PcfReplaceControl(Result, NewClass);
end;

constructor TMzPcfEditor.Create(APlugin: TJucePlugin);
const
  Knobs: array[0..5] of Integer = (PFreq, PQ, PAmount, PDecay, PMix, PLevel);
  KnobNames: array[0..5] of string = ('Freq', 'Q', 'Amount', 'Decay', 'Mix', 'Level');
var
  I: Integer;
  C: TJuceControl;
begin
  inherited Create(APlugin);
  // Size, theme and every control come from the form.
  JuceLoadLayoutResource(Self, 'TMzPcfEditorForm');

  // the faces of the panel and its two units
  Swap('Face', TPcfFace);
  Swap('PcfUnit', TPcfFace);
  Swap('OutUnit', TPcfFace);

  // the knobs, the C++ Knob: the name in capitals and what it does
  for I := 0 to High(Knobs) do
  begin
    C := Swap(KnobNames[I], TPcfKnob);
    if C is TJuceParamControl then
      FSpecControl[Knobs[I]] := TJuceParamControl(C);
  end;

  // the pattern number, its picture, and MODE
  C := Swap('PatternNumber', TPcfLedNumber);
  if C is TPcfLedNumber then
  begin
    TPcfLedNumber(C).ParameterId := Specs[PPattern].Id;
    TPcfLedNumber(C).Caption := '';
    FSpecControl[PPattern] := TJuceParamControl(C);
  end;
  C := Swap('PatternDisplay', TPcfPatternDisplay);
  if C is TPcfPatternDisplay then
  begin
    FDisplay := TPcfPatternDisplay(C);
    FDisplay.PatternParameterId := Specs[PPattern].Id;
    FDisplay.MeterIndex := MeterStep;
    FDisplay.Caption := '';
    FDisplay.Hint := PatternDisplayHint;
  end;
  C := Swap('Mode', TPcfSwitch);
  if C is TJuceParamControl then
    FSpecControl[PMode] := TJuceParamControl(C);

  for I := 0 to NumSpecs - 1 do
    if FSpecControl[I] <> nil then
      FSpecControl[I].Hint := HintFor(I);
end;

function TMzPcfEditor.SpecControl(Index: Integer): TJuceParamControl;
begin
  if (Index >= 0) and (Index < NumSpecs) then
    Result := FSpecControl[Index]
  else
    Result := nil;
end;

end.
