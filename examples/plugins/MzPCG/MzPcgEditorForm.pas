// MzPCG - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// The MzPCG panel as a form, for designing only: the counterpart of the C++ MzPcgEditor
// (Source/PluginEditor.cpp), laid out as it lays itself out - the same places, sizes,
// colours (Look.h, and the TJuceThemeResource "Theme") and wording.
//
// The IDE knows only PascalJUCE's ready-made controls, so the C++ panel's own - the faces,
// the knobs, the pattern number, the gain's picture, the MODE and RATE pads - are stand-ins
// here: a TJucePanel, TJuceKnob, TJuceDisplay or TJuceButton of the same name, place and
// colours. MzPcgEditor.pas swaps each for the real control (MzPCF's PCF/PcfControls.pas,
// and PCG/PcgControls.pas for the gain's picture) when the panel is built; move or recolour
// a stand-in here and the real control follows.
//
// Open MzPcgDesign.lpi in Lazarus with the PascalJUCE design-time package installed and
// edit the panel visually (or this unit in Delphi, with the PascalJUCE design package).
// The plug-in never compiles this unit (it would pull in the LCL/VCL): it embeds
// MzPcgEditorForm.lfm (Free Pascal) or MzPcgEditorForm.dfm (Delphi) and builds the same
// controls from it at run time (MzPcgEditor.pas, JuceLayout.pas). The .lfm is the one
// built and tested; the .dfm describes the same panel for Delphi.
unit MzPcgEditorForm;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  Classes, Forms, JuceDesignControls;

type
  TMzPcgEditorForm = class(TForm)
    Face: TJucePanel;
    Title: TJuceLabel;
    Subtitle: TJuceLabel;
    ProjectLink: TJuceLink;
    PcgUnit: TJucePanel;
    OutUnit: TJucePanel;
    PcgTag: TJucePanel;
    PcgTagText: TJuceLabel;
    OutTag: TJucePanel;
    OutTagText: TJuceLabel;
    PatternLegend: TJuceLabel;
    PatternNumber: TJuceDisplay;
    GainDisplay: TJuceDisplay;
    Mode: TJuceButton;
    Rate: TJuceButton;
    Depth: TJuceKnob;
    Attack: TJuceKnob;
    Hold: TJuceKnob;
    Decay: TJuceKnob;
    Mix: TJuceKnob;
    Level: TJuceKnob;
    Theme: TJuceThemeResource;
  end;

var
  MzPcgEditorFormInstance: TMzPcgEditorForm;

implementation

{$IFDEF FPC}
  {$R *.lfm}
{$ELSE}
  {$R *.dfm}
{$ENDIF}

end.
