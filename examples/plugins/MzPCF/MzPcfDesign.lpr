{
  MzPCF - Created by Simon Moscrop
  Free software under the GNU AGPL v3; see LICENSE.

  MzPcfDesign - the Lazarus project for designing the MzPCF_Pascal panel.

  Open MzPcfDesign.lpi in Lazarus (with pascaljuce_design installed), then open
  MzPcfEditorForm.pas and press F12 to see the form. Running this project shows a
  preview window of the form; the plug-in itself is built with CMake and never uses
  this program or the LCL.
}
program MzPcfDesign;

{$MODE DELPHI}

uses
  Interfaces, SysUtils, Forms, JuceDesignControls, MzPcfEditorForm;

begin
  { parameter list (MzPCF.params) and images are looked up next to the form }
  JuceDesignFormDirectory := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' + PathDelim + '..' + PathDelim);
  RequireDerivedFormResource := True;
  Application.Initialize;
  Application.CreateForm(TMzPcfEditorForm, MzPcfEditorFormInstance);
  Application.Run;
end.
