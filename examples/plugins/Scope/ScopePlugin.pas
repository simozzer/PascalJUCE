{
  ScopePlugin - the effect: the audio passes through, untouched. The
  wrapper's Pascal side copies the output for the window's scope while it is
  open (see TJucePlugin.ScopeWrite), so Process has nothing to do.
  SPDX-License-Identifier: MIT-0 (an example: copy it freely, no notice needed).
}
unit ScopePlugin;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  SysUtils, JucePlugin, JuceTypes;

const
  { TriggerMode: where a sweep starts (= JuceControls.TJuceScopeTrigger). }
  TriggerRise = 0;
  TriggerFall = 1;
  TriggerFree = 2;

type
  TScopePlugin = class(TJucePlugin)
  private
    FTimeMs: Single;
    FTriggerMode: Integer;
  public
    constructor Create; override;
    procedure Process(const Ctx: TJuceProcessContext); override;
    function CreateEditor: TJuceEditorBase; override;
    { TIME and the trigger. Data from a project file is checked. }
    function SaveState: TBytes; override;
    procedure LoadState(const Data: TBytes); override;
    { The view, set by the window (message thread) and saved with the project.
      Not parameters: they change what you see, not what you hear. }
    property TimeMs: Single read FTimeMs write FTimeMs;
    property TriggerMode: Integer read FTriggerMode write FTriggerMode;
  end;

implementation

uses
  ScopeEditor;

const
  { Layout: version byte, TIME as a little-endian Single, trigger byte. }
  StateVersion = 1;
  StateSize = 1 + SizeOf(Single) + 1;

constructor TScopePlugin.Create;
begin
  inherited Create;
  FTimeMs := 20;
  FTriggerMode := TriggerRise;
end;

procedure TScopePlugin.Process(const Ctx: TJuceProcessContext);
begin
  { Audio is processed in place: leaving the channels alone passes it through. }
end;

function TScopePlugin.CreateEditor: TJuceEditorBase;
begin
  Result := TScopeEditor.Create(Self);
end;

function TScopePlugin.SaveState: TBytes;
var
  Time: Single;
begin
  Result := nil;
  SetLength(Result, StateSize);
  Result[0] := StateVersion;
  Time := FTimeMs;
  Move(Time, Result[1], SizeOf(Single));
  Result[1 + SizeOf(Single)] := FTriggerMode;
end;

procedure TScopePlugin.LoadState(const Data: TBytes);
var
  Time: Single;
  Mode: Integer;
begin
  { Never trust the length, the version or the values: all or nothing. }
  if (Length(Data) <> StateSize) or (Data[0] <> StateVersion) then
    Exit;
  Move(Data[1], Time, SizeOf(Single));
  Mode := Data[1 + SizeOf(Single)];
  if not ((Time >= 1) and (Time <= 1000)) or (Mode > TriggerFree) then { the first is also true for NaN }
    Exit;
  FTimeMs := Time;
  FTriggerMode := Mode;
end;

end.
