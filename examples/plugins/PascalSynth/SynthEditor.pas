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
    FScope: TJuceControl;             { OutScope (a TJuceScope) }
    FScopeTime: TJuceParamControl;    { its TIME knob: not bound to a parameter }
    FShownTimeMs: Single;             { the plug-in's ScopeTimeMs the knob shows }
    procedure ControlMenu(Sender: TJuceControl; X, Y: Single; var Handled: Boolean);
    procedure ControlMenuChosen(Sender: TJuceEditor; MenuId, ItemId: Integer);
    procedure ScopeTimeChanged(Sender: TObject);
    procedure ScopeTimeText(Sender: TJuceParamControl; Normalised: Single; var Text: string);
    procedure ShowScopeTime;
  protected
    procedure TimerTick; override;
  public
    constructor Create(APlugin: TJucePlugin); override;
  end;

const
  MeterOutput = 0; { the meter slot SimpleSynth publishes its output peak in (OutMeter.MeterIndex) }

implementation

uses
  Classes, JuceControls, JuceLayout, SimpleSynth;

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

  { The scope's TIME knob is not bound to a parameter (it changes the view,
    not the sound): it keeps its own value, logarithmic over 1..170 ms, and
    the plug-in keeps the time so the project saves it. }
  FScope := FindControl('OutScope');
  Knob := FindControl('ScopeTime');
  if (FScope is TJuceScope) and (Knob is TJuceParamControl) then
  begin
    FScopeTime := TJuceParamControl(Knob);
    FScopeTime.DefaultValue := JuceScopeValueFromTime(20);
    FScopeTime.OnValueText := ScopeTimeText;
    ShowScopeTime;
    FScopeTime.OnChange := ScopeTimeChanged;
  end;
end;

{ The knob and the scope from the plug-in's time (also after a project load). }
procedure TSynthEditor.ShowScopeTime;
var
  Handler: TNotifyEvent;
begin
  FShownTimeMs := TSimpleSynth(Plugin).ScopeTimeMs;
  Handler := FScopeTime.OnChange;
  FScopeTime.OnChange := nil; { showing the time, not choosing one }
  FScopeTime.Value := JuceScopeValueFromTime(FShownTimeMs);
  FScopeTime.OnChange := Handler;
  TJuceScope(FScope).TimeMs := FShownTimeMs;
end;

procedure TSynthEditor.ScopeTimeChanged(Sender: TObject);
begin
  FShownTimeMs := JuceScopeTimeFromValue(FScopeTime.Value);
  TSimpleSynth(Plugin).ScopeTimeMs := FShownTimeMs;
  TJuceScope(FScope).TimeMs := FShownTimeMs;
end;

procedure TSynthEditor.ScopeTimeText(Sender: TJuceParamControl; Normalised: Single; var Text: string);
begin
  Text := JuceScopeTimeText(JuceScopeTimeFromValue(Normalised));
end;

procedure TSynthEditor.TimerTick;
begin
  { a project or preset loaded while the window is open }
  if (FScopeTime <> nil) and (TSimpleSynth(Plugin).ScopeTimeMs <> FShownTimeMs) then
    ShowScopeTime;
  inherited TimerTick;
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
