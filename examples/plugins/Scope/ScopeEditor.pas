{
  ScopeEditor - the Scope window, built in code: the scope, and beside it
  TIME and TRIGGER. Neither is bound to a parameter (they change the view,
  not the sound); the plug-in keeps their settings for the project.
  SPDX-License-Identifier: MIT-0 (an example: copy it freely, no notice needed).
}
unit ScopeEditor;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8} { string literals in this file are UTF-8 }
{$ENDIF}

interface

uses
  JucePlugin, JuceUI, JuceControls;

type
  TScopeEditor = class(TJuceEditor)
  private
    FScope: TJuceScope;
    FTime: TJuceKnob;
    FTrigger: TJuceSwitch;
    FShownTimeMs: Single;     { the plug-in's settings the controls show }
    FShownTrigger: Integer;
    procedure TimeChanged(Sender: TObject);
    procedure TriggerChanged(Sender: TObject);
    procedure TimeText(Sender: TJuceParamControl; Normalised: Single; var Text: string);
    procedure ShowSettings;
  protected
    procedure TimerTick; override;
  public
    constructor Create(APlugin: TJucePlugin); override;
  end;

implementation

uses
  Classes, Math, ScopePlugin;

const
  EditorW = 640;
  EditorH = 360;

constructor TScopeEditor.Create(APlugin: TJucePlugin);
var
  Panel: TJucePanel;
begin
  inherited Create(APlugin);
  SetSize(EditorW, EditorH);

  Panel := TJucePanel.Create(Root);
  Panel.SetBounds(6, 6, EditorW - 12, EditorH - 12);
  Panel.Caption := 'SCOPE';

  FScope := TJuceScope.Create(Panel);
  FScope.SetBounds(12, 30, 512, EditorH - 12 - 42);
  FScope.Channel := jscMix; { one trace: left and right mixed }

  FTime := TJuceKnob.Create(Panel);
  FTime.SetBounds(536, 36, 80, 104);
  FTime.Caption := 'TIME';
  FTime.Hint := 'How much the scope shows: 1 to 170 ms';
  FTime.DefaultValue := JuceScopeValueFromTime(20);
  FTime.OnValueText := TimeText;

  FTrigger := TJuceSwitch.Create(Panel);
  FTrigger.SetBounds(536, 160, 80, 120);
  FTrigger.Caption := 'TRIGGER';
  FTrigger.Positions := 3;
  FTrigger.Labels := 'Rise|Fall|Free';
  FTrigger.Orientation := joVertical;
  FTrigger.Style := jswSlide;
  FTrigger.Hint := 'Where each sweep starts: the signal rising or falling through zero, or free-running';

  FShownTimeMs := -1;
  FShownTrigger := -1;
  ShowSettings;
  FTime.OnChange := TimeChanged;
  FTrigger.OnChange := TriggerChanged;
  SetScalable(0.6, 2.5);
end;

function Plugin_(E: TJuceEditor): TScopePlugin;
begin
  Result := TScopePlugin(E.Plugin);
end;

{ The controls and the scope from the plug-in's settings: at the start, and
  after a project loads while the window is open. }
procedure TScopeEditor.ShowSettings;
var
  P: TScopePlugin;
  OnTime, OnTrigger: TNotifyEvent;
  Mode: Integer;
begin
  P := Plugin_(Self);
  if (P.TimeMs = FShownTimeMs) and (P.TriggerMode = FShownTrigger) then
    Exit;
  FShownTimeMs := P.TimeMs;
  Mode := EnsureRange(P.TriggerMode, TriggerRise, TriggerFree);
  FShownTrigger := P.TriggerMode;
  OnTime := FTime.OnChange;
  OnTrigger := FTrigger.OnChange;
  FTime.OnChange := nil;     { showing the settings, not choosing them }
  FTrigger.OnChange := nil;
  FTime.Value := JuceScopeValueFromTime(FShownTimeMs);
  FTrigger.SetPosition(Mode);
  FTime.OnChange := OnTime;
  FTrigger.OnChange := OnTrigger;
  FScope.TimeMs := FShownTimeMs;
  FScope.Trigger := TJuceScopeTrigger(Mode);
end;

procedure TScopeEditor.TimeChanged(Sender: TObject);
begin
  FShownTimeMs := JuceScopeTimeFromValue(FTime.Value);
  Plugin_(Self).TimeMs := FShownTimeMs;
  FScope.TimeMs := FShownTimeMs;
end;

procedure TScopeEditor.TriggerChanged(Sender: TObject);
begin
  FShownTrigger := EnsureRange(FTrigger.Position, TriggerRise, TriggerFree);
  Plugin_(Self).TriggerMode := FShownTrigger;
  FScope.Trigger := TJuceScopeTrigger(FShownTrigger);
end;

procedure TScopeEditor.TimeText(Sender: TJuceParamControl; Normalised: Single; var Text: string);
begin
  Text := JuceScopeTimeText(JuceScopeTimeFromValue(Normalised));
end;

procedure TScopeEditor.TimerTick;
begin
  ShowSettings; { a project loaded while the window is open }
  inherited TimerTick;
end;

end.
