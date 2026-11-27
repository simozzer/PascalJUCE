{
  MzPCG - Created by Simon Moscrop
  Free software under the GNU AGPL v3; see LICENSE.

  MzPcgDesign - the Lazarus project for designing the MzPCG_Pascal panel.

  Open MzPcgDesign.lpi in Lazarus (with pascaljuce_design installed), then open
  MzPcgEditorForm.pas and press F12 to see the form. Running this project shows a
  preview window of the form; the plug-in itself is built with CMake and never uses
  this program or the LCL.
}
program MzPcgDesign;

{$MODE DELPHI}

uses
  Interfaces, SysUtils, Forms, JuceDesignControls, MzPcgEditorForm;

begin
  { parameter list (MzPCG.params) and images are looked up next to the form }
  JuceDesignFormDirectory := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' + PathDelim + '..' + PathDelim);
  RequireDerivedFormResource := True;
  Application.Initialize;
  Application.CreateForm(TMzPcgEditorForm, MzPcgEditorFormInstance);
  Application.Run;
end.
