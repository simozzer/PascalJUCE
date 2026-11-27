{
  Mz808 - Created by Simon Moscrop
  Free software under the GNU AGPL v3; see LICENSE.

  Mz808Design - the Lazarus project for designing the Mz808_Pascal panel.

  Open Mz808Design.lpi in Lazarus (with pascaljuce_design installed), then open
  Mz808EditorForm.pas and press F12 to see the form. Running this project shows a
  preview window of the form; the plug-in itself is built with CMake and never uses
  this program or the LCL.
}
program Mz808Design;

{$MODE DELPHI}

uses
  Interfaces, SysUtils, Forms, JuceDesignControls, Mz808EditorForm;

begin
  { parameter list (Mz808.params) and images are looked up next to the form }
  JuceDesignFormDirectory := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' + PathDelim + '..' + PathDelim);
  RequireDerivedFormResource := True;
  Application.Initialize;
  Application.CreateForm(TMz808EditorForm, Mz808EditorFormInstance);
  Application.Run;
end.
