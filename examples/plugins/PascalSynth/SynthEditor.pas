{
  SynthEditor - the template's custom editor: a panel designed in the form
  designer, loaded at run time.
  SPDX-License-Identifier: MIT-0 (a template: copy it freely, no notice needed).

  The panel lives in SynthEditorForm.lfm (Lazarus) / SynthEditorForm.dfm
  (Delphi). Design it visually with the PascalJUCE design-time package
  (open PascalSynthDesign.lpi in Lazarus), then rebuild the plug-in: the
  form file is embedded as a resource and JuceLoadLayoutResource builds the
  same controls from it here. No LCL or VCL is linked into the plug-in.

  Controls find their parameter by id when the window opens; dragging one
  tells the host (with undo gestures), and host automation moves it. The
  meter shows the peak SimpleSynth publishes from Process with SetMeter.
  Building the panel in code instead works just as well; see "Building a
  panel in code" in docs/PLUGINS.md.
  Delete CreateEditor in SimpleSynth.pas to get the host's generic editor.
}
unit SynthEditor;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8} { string literals in this file are UTF-8 }
{$ENDIF}

interface

uses
  JucePlugin, JuceUI;

type
  TSynthEditor = class(TJuceEditor)
  private
    FMenuControl: TJuceParamControl;  { the control a right-click menu is for }
    procedure ControlMenu(Sender: TJuceControl; X, Y: Single; var Handled: Boolean);
    procedure ControlMenuChosen(Sender: TJuceEditor; MenuId, ItemId: Integer);
  public
    constructor Create(APlugin: TJucePlugin); override;
  end;

const
  MeterOutput = 0; { the meter slot SimpleSynth publishes its output peak in (OutMeter.MeterIndex) }

implementation

uses
  JuceControls, JuceLayout;

{ The designed panel, compiled into an RCDATA resource named after the
  form's class (TSYNTHEDITORFORM). }
{$IFDEF FPC}
  {$R SynthEditorForm.lfm}
{$ELSE}
  {$R SynthEditorForm.dfm}
{$ENDIF}

constructor TSynthEditor.Create(APlugin: TJucePlugin);
const
  Knobs: array[0..2] of string = ('Attack', 'Release', 'Gain');
var
  I: Integer;
  Knob: TJuceControl;
begin
  inherited Create(APlugin);
  { Size, background and every control come from the form. }
  JuceLoadLayoutResource(Self, 'TSynthEditorForm');
  { The host and the user may resize the window from 75% to 200%, keeping its
    shape; the panel is drawn at that size (not stretched) and laid out at
    the form's size, as before. }
  SetScalable(0.75, 2.0, False);

  { Event handlers are attached in code, by the names given in the designer. }
  for I := Low(Knobs) to High(Knobs) do
  begin
    Knob := FindControl(Knobs[I]);
    if Knob <> nil then
      Knob.OnContextMenu := ControlMenu;
  end;
end;

{ Right-click on a knob: a small menu. The answer arrives later, in
  ControlMenuChosen (menus never block the host). }
procedure TSynthEditor.ControlMenu(Sender: TJuceControl; X, Y: Single; var Handled: Boolean);
begin
  if not (Sender is TJuceParamControl) then
    Exit;
  FMenuControl := TJuceParamControl(Sender);
  PopupMenu([JuceMenuItem(1, 'Reset to default')], Sender.AbsoluteX + X, Sender.AbsoluteY + Y, ControlMenuChosen);
  Handled := True;
end;

procedure TSynthEditor.ControlMenuChosen(Sender: TJuceEditor; MenuId, ItemId: Integer);
begin
  if (ItemId = 1) and (FMenuControl <> nil) then
    FMenuControl.Value := FMenuControl.DefaultValue;
  FMenuControl := nil;
end;

end.
