{
  PascalSynthDesign - the Lazarus project for designing the PascalSynth panel.
  SPDX-License-Identifier: MIT-0 (a template: copy it freely, no notice needed).

  Open PascalSynthDesign.lpi in Lazarus (with pascaljuce_design installed),
  then open SynthEditorForm.pas and press F12 to see the form. Running this
  project shows a preview window of the form; the plug-in itself is built
  with CMake and never uses this program or the LCL.
}
program PascalSynthDesign;

{$MODE DELPHI}

uses
  Interfaces, SysUtils, Forms, JuceDesignControls, SynthEditorForm;

begin
  { parameter list and images are looked up next to the form }
  JuceDesignFormDirectory := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' + PathDelim + '..' + PathDelim);
  RequireDerivedFormResource := True;
  Application.Initialize;
  Application.CreateForm(TSynthEditorForm, SynthEditorFormInstance);
  Application.Run;
end.
