// Mz303 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// The Mz303 panel as a form, for designing only: the counterpart of the C++ Panel
// (source/PluginEditor.cpp), laid out as it lays itself out - the same sections, sizes,
// colours (the TJuceThemeResource "Theme") and wording.
//
// Open Mz303Design.lpi in Lazarus with the PascalJUCE design-time package installed and
// edit the panel visually (or this unit in Delphi, with the PascalJUCE design package).
// The plug-in never compiles this unit (it would pull in the LCL/VCL): it embeds
// Mz303EditorForm.lfm (Free Pascal) or Mz303EditorForm.dfm (Delphi) and builds the same
// controls from it at run time (Mz303Editor.pas, JuceLayout.pas). The .lfm is the one
// built and tested; the .dfm describes the same panel for Delphi.
unit Mz303EditorForm;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  Classes, Forms, JuceDesignControls;

type
  TMz303EditorForm = class(TForm)
    Theme: TJuceThemeResource;
    Title: TJuceLabel;
    Subtitle: TJuceLabel;
    ProjectLink: TJuceLink;
    PatchBox: TJuceComboBox;
    KnobSection: TJucePanel;
    Tune: TJuceKnob;
    Cutoff: TJuceKnob;
    Res: TJuceKnob;
    EnvMod: TJuceKnob;
    Decay: TJuceKnob;
    Accent: TJuceKnob;
    Wave: TJuceSwitch;
    Volume: TJuceKnob;
    AccentLight: TJuceLed;
    AccentLabel: TJuceLabel;
    SlideLight: TJuceLed;
    SlideLabel: TJuceLabel;
    KeyboardBox: TJucePanel;
    AccentKeys: TJuceButton;
    Keyboard: TJuceKeyboard;
  end;

var
  Mz303EditorFormInstance: TMz303EditorForm;

implementation

{$IFDEF FPC}
  {$R *.lfm}
{$ELSE}
  {$R *.dfm}
{$ENDIF}

end.
