{
  Mz909 - an emulation of the TR-909 Rhythm Composer
  Created by Simon Moscrop
  Free software under the GNU AGPL v3; see LICENSE.

  Mz909Design - the Lazarus project for designing the Mz909_Pascal panel.

  Open Mz909Design.lpi in Lazarus (with pascaljuce_design installed), then open
  Mz909EditorForm.pas and press F12 to see the form. Running this project shows a
  preview window of the form; the plug-in itself is built with CMake and never uses
  this program or the LCL.
}
program Mz909Design;

{$MODE DELPHI}

uses
  Interfaces, SysUtils, Forms, JuceDesignControls, Mz909EditorForm;

begin
  { parameter list (Mz909.params) and images are looked up next to the form }
  JuceDesignFormDirectory := ExpandFileName(ExtractFilePath(ParamStr(0)) + '..' + PathDelim + '..' + PathDelim);
  RequireDerivedFormResource := True;
  Application.Initialize;
  Application.CreateForm(TMz909EditorForm, Mz909EditorFormInstance);
  Application.Run;
end.
