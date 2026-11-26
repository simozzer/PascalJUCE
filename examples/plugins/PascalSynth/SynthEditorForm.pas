{
  SynthEditorForm - the PascalSynth panel as a form, for designing only.
  SPDX-License-Identifier: MIT-0 (a template: copy it freely, no notice needed).

  Open this unit in Lazarus (PascalSynthDesign.lpi) or Delphi with the
  PascalJUCE design-time package installed, and edit the panel visually.
  The plug-in never compiles this unit (it would pull in the LCL/VCL): it
  only embeds the form file, SynthEditorForm.lfm or .dfm, and builds the same
  controls from it at run time (see SynthEditor.pas and JuceLayout.pas).

  The .lfm (Lazarus) and .dfm (Delphi) describe the same panel. Edit the one
  for your IDE; the plug-in embeds the .lfm when built with Free Pascal and
  the .dfm when built with Delphi.
}
unit SynthEditorForm;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  Classes, Forms, JuceDesignControls;

type
  TSynthEditorForm = class(TForm)
    MainPanel: TJucePanel;
    Wave: TJuceSwitch;
    Attack: TJuceKnob;
    Release: TJuceKnob;
    Gain: TJuceKnob;
    OutMeter: TJuceMeter;
    OutLabel: TJuceLabel;
    OutScope: TJuceScope;
    HelpLabel: TJuceLabel;
  end;

var
  SynthEditorFormInstance: TSynthEditorForm;

implementation

{$IFDEF FPC}
  {$R *.lfm}
{$ELSE}
  {$R *.dfm}
{$ENDIF}

end.
