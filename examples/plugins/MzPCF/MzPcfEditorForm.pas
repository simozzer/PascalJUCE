// MzPCF - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// The MzPCF panel as a form, for designing only: the counterpart of the C++ MzPcfEditor
// (Source/PluginEditor.cpp), laid out as it lays itself out - the same places, sizes,
// colours (Look.h, and the TJuceThemeResource "Theme") and wording.
//
// The IDE knows only PascalJUCE's ready-made controls, so the C++ panel's own - the faces,
// the knobs, the pattern number and its picture, the MODE pad - are stand-ins here: a
// TJucePanel, TJuceKnob, TJuceDisplay or TJuceButton of the same name, place and colours.
// MzPcfEditor.pas swaps each for the real control (PCF/PcfControls.pas) when the panel is
// built; move or recolour a stand-in here and the real control follows.
//
// Open MzPcfDesign.lpi in Lazarus with the PascalJUCE design-time package installed and
// edit the panel visually (or this unit in Delphi, with the PascalJUCE design package).
// The plug-in never compiles this unit (it would pull in the LCL/VCL): it embeds
// MzPcfEditorForm.lfm (Free Pascal) or MzPcfEditorForm.dfm (Delphi) and builds the same
// controls from it at run time (MzPcfEditor.pas, JuceLayout.pas). The .lfm is the one
// built and tested; the .dfm describes the same panel for Delphi.
unit MzPcfEditorForm;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  Classes, Forms, JuceDesignControls;

type
  TMzPcfEditorForm = class(TForm)
    Face: TJucePanel;
    Title: TJuceLabel;
    Subtitle: TJuceLabel;
    ProjectLink: TJuceLink;
    PcfUnit: TJucePanel;
    OutUnit: TJucePanel;
    PcfTag: TJucePanel;
    PcfTagText: TJuceLabel;
    OutTag: TJucePanel;
    OutTagText: TJuceLabel;
    PatternLegend: TJuceLabel;
    PatternNumber: TJuceDisplay;
    PatternDisplay: TJuceDisplay;
    Mode: TJuceButton;
    Freq: TJuceKnob;
    Q: TJuceKnob;
    Amount: TJuceKnob;
    Decay: TJuceKnob;
    Mix: TJuceKnob;
    Level: TJuceKnob;
    Theme: TJuceThemeResource;
  end;

var
  MzPcfEditorFormInstance: TMzPcfEditorForm;

implementation

{$IFDEF FPC}
  {$R *.lfm}
{$ELSE}
  {$R *.dfm}
{$ENDIF}

end.
