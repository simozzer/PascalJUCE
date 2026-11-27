{
  Mz303 - Created by Simon Moscrop
  Free software under the GNU AGPL v3; see LICENSE.

  Mz303Design - the Lazarus project for designing the Mz303_Pascal panel.

  Open Mz303Design.lpi in Lazarus (with pascaljuce_design installed), then open
  Mz303EditorForm.pas and press F12 to see the form. Running this project shows a
  preview window of the form; the plug-in itself is built with CMake and never uses
  this program or the LCL.
}
program Mz303Design;

{$MODE DELPHI}

uses
  Interfaces, SysUtils, Forms, JuceDesignControls, Mz303EditorForm;

begin
  { parameter list (Mz303.params) and images are looked up next to the form }
  JuceDesignFormDirectory := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' + PathDelim + '..' + PathDelim);
  RequireDerivedFormResource := True;
  Application.Initialize;
  Application.CreateForm(TMz303EditorForm, Mz303EditorFormInstance);
  Application.Run;
end.
