program TinySynthDesign;

{ The design-only project for the Tiny Synth panel (TinySynthForm). Running it
  shows a preview of the panel; it is never part of the plug-in. }

{$mode delphi}

uses
  Interfaces, Forms, TinySynthForm;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TTinySynthForm, TinySynthForm.TinySynthForm);
  Application.Run;
end.
