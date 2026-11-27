{
  MzPCD - Created by Simon Moscrop
  Free software under the GNU AGPL v3; see LICENSE.

  MzPcdDesign - the Lazarus project for designing the MzPCD_Pascal panel.

  Open MzPcdDesign.lpi in Lazarus (with pascaljuce_design installed), then open
  MzPcdEditorForm.pas and press F12 to see the form. Running this project shows a
  preview window of the form; the plug-in itself is built with CMake and never uses
  this program or the LCL.
}
program MzPcdDesign;

{$MODE DELPHI}

uses
  Interfaces, SysUtils, Forms, JuceDesignControls, MzPcdEditorForm;

begin
  { parameter list (MzPCD.params) and images are looked up next to the form }
  JuceDesignFormDirectory := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' + PathDelim + '..' + PathDelim);
  RequireDerivedFormResource := True;
  Application.Initialize;
  Application.CreateForm(TMzPcdEditorForm, MzPcdEditorFormInstance);
  Application.Run;
end.
