// MzPCD - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// The MzPCD panel as a form, for designing only: the counterpart of the C++ MzPcdEditor
// (Source/PluginEditor.cpp), laid out as it lays itself out - the same places, sizes,
// colours (Look.h, and the TJuceThemeResource "Theme") and wording.
//
// The IDE knows only PascalJUCE's ready-made controls, so the C++ panel's own - the faces,
// the knobs, the pattern number and its picture, the RATE pad, the groups named over the
// knobs - are stand-ins here: a TJucePanel, TJuceKnob, TJuceDisplay, TJuceButton or
// TJuceLabel of the same name, place and colours. MzPcdEditor.pas swaps each for the real
// control (MzPCF's ../MzPCF/PCF/PcfControls.pas, and PCD/PcdControls.pas) when the panel
// is built; move or recolour a stand-in here and the real control follows.
//
// Open MzPcdDesign.lpi in Lazarus with the PascalJUCE design-time package installed and
// edit the panel visually (or this unit in Delphi, with the PascalJUCE design package).
// The plug-in never compiles this unit (it would pull in the LCL/VCL): it embeds
// MzPcdEditorForm.lfm (Free Pascal) or MzPcdEditorForm.dfm (Delphi) and builds the same
// controls from it at run time (MzPcdEditor.pas, JuceLayout.pas). The .lfm is the one
// built and tested; the .dfm describes the same panel for Delphi.
unit MzPcdEditorForm;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  Classes, Forms, JuceDesignControls;

type
  TMzPcdEditorForm = class(TForm)
    Face: TJucePanel;
    Title: TJuceLabel;
    Subtitle: TJuceLabel;
    ProjectLink: TJuceLink;
    PcdUnit: TJucePanel;
    OutUnit: TJucePanel;
    PcdTag: TJucePanel;
    PcdTagText: TJuceLabel;
    OutTag: TJucePanel;
    OutTagText: TJuceLabel;
    LevelsGroup: TJuceLabel;
    PushesGroup: TJuceLabel;
    PatternLegend: TJuceLabel;
    PatternNumber: TJuceDisplay;
    PatternDisplay: TJuceDisplay;
    Rate: TJuceButton;
    Drive: TJuceKnob;
    Shape: TJuceKnob;
    Tone: TJuceKnob;
    Feedback: TJuceKnob;
    DriveAmount: TJuceKnob;
    ToneAmount: TJuceKnob;
    FeedbackAmount: TJuceKnob;
    Decay: TJuceKnob;
    Mix: TJuceKnob;
    Level: TJuceKnob;
    Theme: TJuceThemeResource;
  end;

var
  MzPcdEditorFormInstance: TMzPcdEditorForm;

implementation

{$IFDEF FPC}
  {$R *.lfm}
{$ELSE}
  {$R *.dfm}
{$ENDIF}

end.
