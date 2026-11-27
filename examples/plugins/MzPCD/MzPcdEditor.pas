// MzPCD - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// The panel: the Object Pascal counterpart of Source/PluginEditor.cpp and Look.cpp, on
// PascalJUCE's controls and MzPCF's (PcfControls, shared - the C++ MzPCD draws its panel as
// MzPCF draws its own). No LCL or VCL here: the panel is designed as a form
// (MzPcdEditorForm.lfm, in Lazarus with MzPcdDesign.lpi, or MzPcdEditorForm.dfm in Delphi),
// embedded in the library, and built from it at run time. The form holds the IDE's own
// controls as stand-ins for the C++ panel's: when the panel is built each stand-in is
// swapped for the real control, with its name, place and properties -
//
//   Face, PcdUnit, OutUnit             TJucePanel   -> TPcfFace (drawFace)
//   Drive, Shape, Tone, Feedback,      TJuceKnob    -> TPcfKnob (Look::drawRotarySlider, the
//   DriveAmount, ToneAmount,                           C++ Knob's drag, wheel and bubble)
//   FeedbackAmount, Decay, Mix, Level
//   PatternNumber                      TJuceDisplay -> TPcfLedNumber (LedNumber), on "pattern"
//   PatternDisplay                     TJuceDisplay -> TPcfPatternDisplay (PatternDisplay),
//                                                      with its push meter
//   Rate                               TJuceButton  -> TPcfSwitch (Switch)
//   LevelsGroup, PushesGroup           TJuceLabel   -> TPcdGroupLabel (the groups named
//                                                      over the knobs, in paint())
//
// and every hover hint is set from the parameter table (MzPcdParams), as the C++ sets them
// from params::spec. The pattern's picture follows the pattern parameter, the step and the
// push the plug-in publishes (MzPcdPlugin.MeterStep, MeterPush) on the editor's 30 Hz
// timer, as the C++ timerCallback does. A fixed 966 x 186, as the C++ editor.
unit MzPcdEditor;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ENDIF}

interface

uses
  JucePlugin, JuceUI, JuceControls, PcfControls, PcdControls, MzPcdParams;

type
  TMzPcdEditor = class(TJuceEditor)
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
  PatternDisplayHint = 'The pattern: on each step it pushes the drive, the tone and the feedback by that much, ' +
    'and the push dies away by DEC. The step playing is lit while your DAW plays; the meter ' +
    'at the right is the push now.';

  // The knobs, in the C++ editor's order (levels, the pattern's pushes, output), and the
  // names of their stand-ins in the form.
  KnobSpecs: array[0..9] of Integer = (PDrive, PShape, PTone, PFeedback,
    PDriveAmount, PToneAmount, PFeedbackAmount, PDecay, PMix, PLevel);
  KnobNames: array[0..9] of string = ('Drive', 'Shape', 'Tone', 'Feedback',
    'DriveAmount', 'ToneAmount', 'FeedbackAmount', 'Decay', 'Mix', 'Level');

implementation

uses
  JuceLayout, MzPcdPlugin;

// The designed panel, compiled into an RCDATA resource named after the form's class
// (TMZPCDEDITORFORM).
{$IFDEF FPC}
  {$R MzPcdEditorForm.lfm}
{$ELSE}
  {$R MzPcdEditorForm.dfm}
{$ENDIF}

function TMzPcdEditor.Swap(const Name: string; NewClass: TJuceControlClass): TJuceControl;
begin
  Result := FindControl(Name);
  if Result <> nil then
    Result := PcfReplaceControl(Result, NewClass);
end;

constructor TMzPcdEditor.Create(APlugin: TJucePlugin);
var
  I: Integer;
  C: TJuceControl;
begin
  inherited Create(APlugin);
  // Size, theme and every control come from the form.
  JuceLoadLayoutResource(Self, 'TMzPcdEditorForm');

  // the faces of the panel and its two units, and the two groups of knobs named
  Swap('Face', TPcfFace);
  Swap('PcdUnit', TPcfFace);
  Swap('OutUnit', TPcfFace);
  Swap('LevelsGroup', TPcdGroupLabel);
  Swap('PushesGroup', TPcdGroupLabel);

  // the knobs, the C++ Knob: the name in capitals and what it does
  for I := 0 to High(KnobSpecs) do
  begin
    C := Swap(KnobNames[I], TPcfKnob);
    if C is TJuceParamControl then
      FSpecControl[KnobSpecs[I]] := TJuceParamControl(C);
  end;

  // the pattern number, its picture with the push beside it, and RATE
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
    FDisplay.ShowPush := True;
    FDisplay.PushMeterIndex := MeterPush;
    FDisplay.Caption := '';
    FDisplay.Hint := PatternDisplayHint;
  end;
  C := Swap('Rate', TPcfSwitch);
  if C is TJuceParamControl then
    FSpecControl[PRate] := TJuceParamControl(C);

  for I := 0 to NumSpecs - 1 do
    if FSpecControl[I] <> nil then
      FSpecControl[I].Hint := HintFor(I);
end;

function TMzPcdEditor.SpecControl(Index: Integer): TJuceParamControl;
begin
  if (Index >= 0) and (Index < NumSpecs) then
    Result := FSpecControl[Index]
  else
    Result := nil;
end;

end.
