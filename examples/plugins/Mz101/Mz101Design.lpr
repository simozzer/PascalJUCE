{
  Mz101 - Created by Simon Moscrop
  Free software under the GNU AGPL v3; see LICENSE.

  Mz101Design - the Lazarus project for designing the Mz101 Pascal panel.

  Open Mz101Design.lpi in Lazarus (with pascaljuce_design installed), then open
  Mz101EditorForm.pas and press F12 to see the form. Running this project shows a
  preview window of the form; the plug-in itself is built with CMake and never uses
  this program or the LCL.
}
program Mz101Design;

{$MODE DELPHI}

uses
  Interfaces, SysUtils, Forms, JuceDesignControls, Mz101EditorForm;

begin
  { parameter list (Mz101.params) and images are looked up next to the form }
  JuceDesignFormDirectory := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' + PathDelim + '..' + PathDelim);
  RequireDerivedFormResource := True;
  Application.Initialize;
  Application.CreateForm(TMz101EditorForm, Mz101EditorFormInstance);
  Application.Run;
end.
