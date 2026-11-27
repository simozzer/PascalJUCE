{
  Unit tests for the custom-editor units (pascal/JuceUI.pas, JuceControls.pas,
  JuceCanvas.pas and the editor part of JucePlugin.pas), driven through the
  real exported entry point and editor vtable with a fake host written in
  Pascal: no JUCE, no DLLs. Covers the ABI records, editor creation and
  fallback, binding, painting, mouse handling and gestures, host automation,
  meters, menus, tooltips, lifetime (controls and editors freed mid-gesture),
  the published properties a form loader will use, and 1000 editors.

  Build with checks on: fpc -Mdelphi -Cr -Co -Ct -CR -gl -gh ...
}
program test_ui_unit;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}
{$APPTYPE CONSOLE}

uses
{$IFDEF FPC}{$IFDEF UNIX}
  cthreads, { first: the units below may start the RTL's threading in their initialisation }
{$ENDIF}{$ENDIF}
  SysUtils, Classes, TypInfo, Math, JuceTypes, JucePlugin, JuceCanvas, JuceUI, JuceControls, TestFramework;

{ ---------------------------------------------------------------------------- }
{ Fake editor host                                                             }
{ ---------------------------------------------------------------------------- }

const
  EditorToken = Pointer($5150);
  GraphicsToken = Pointer($6160);
  NumTestParams = 4;

type
  TFakeEditorHost = record
    BadHandles: Integer;
    Repaints, SetSizes, LastW, LastH: Integer;
    TimerStarts, TimerStops, TimerHz: Integer;
    Tooltip: string;
    TooltipCalls: Integer;
    MenusShown, LastMenuId, LastMenuCount: Integer;
    LastMenuText: string;
    RefuseMenu: Boolean;
    Params: array[0..NumTestParams - 1] of Single;
    Defaults: array[0..NumTestParams - 1] of Single;
    Begins, Ends, Sets, LastSetIndex: Integer;
    LastSet: Single;
    Meters: array[0..3] of Single;
    ImagesCreated, ImagesDestroyed, NextImage: Integer;
    Saves, Restores, Ops: Integer;
    LastImageSY, LastImageSH: Single;
    LastText: string;
    Arcs: Integer;
    DesignCalls, DesignW, DesignH, ScaleFlags, UrlCalls, LookCalls: Integer;
    MinScale, MaxScale, Scale: Single;
    LastUrl, LastLookFont: string;
    LastLook: TJcpEditorLook;
    FileCalls, LastFileRequest, LastFileMode: Integer;
    LastFileTitle, LastFilePatterns, LastFileInitial: string;
    RefuseFile: Boolean;
  end;

var
  FE: TFakeEditorHost;
  FakeApi: TJcpEditorApi;
  HostApi: TJcpHostApi;
  Factory: TJcpPluginFactory;
  PlugVT: TJcpPluginVTable;
  Inst: Pointer;

procedure CheckEd(E: PJcpEditor);
begin
  if E <> EditorToken then
    Inc(FE.BadHandles);
end;

procedure CheckG(G: PJcpGraphics);
begin
  if G <> GraphicsToken then
    Inc(FE.BadHandles);
  Inc(FE.Ops);
end;

procedure FRepaint(E: PJcpEditor; X, Y, W, H: Single); cdecl;
begin
  CheckEd(E);
  Inc(FE.Repaints);
end;

procedure FSetSize(E: PJcpEditor; W, H: Int32); cdecl;
begin
  CheckEd(E);
  Inc(FE.SetSizes);
  FE.LastW := W;
  FE.LastH := H;
end;

procedure FSetResizeLimits(E: PJcpEditor; A, B, C, D: Int32); cdecl;
begin
  CheckEd(E);
end;

procedure FStartTimer(E: PJcpEditor; Hz: Int32); cdecl;
begin
  CheckEd(E);
  Inc(FE.TimerStarts);
  FE.TimerHz := Hz;
end;

procedure FStopTimer(E: PJcpEditor); cdecl;
begin
  CheckEd(E);
  Inc(FE.TimerStops);
end;

function FromUtf8(P: PAnsiChar): string;
var
  U: UTF8String;
begin
  if P = nil then
    Result := ''
  else
  begin
    SetString(U, P, StrLen(P));
    Result := string(U);
  end;
end;

procedure FSetTooltip(E: PJcpEditor; Text: PAnsiChar); cdecl;
begin
  CheckEd(E);
  Inc(FE.TooltipCalls);
  FE.Tooltip := FromUtf8(Text);
end;

function FShowPopupMenu(E: PJcpEditor; Items: PJcpMenuItem; Count, ItemSize, MenuId: Int32; X, Y: Single): Int32; cdecl;
begin
  CheckEd(E);
  Result := 0;
  if FE.RefuseMenu or (Items = nil) or (ItemSize <> SizeOf(TJcpMenuItem)) then
    Exit;
  Inc(FE.MenusShown);
  FE.LastMenuId := MenuId;
  FE.LastMenuCount := Count;
  FE.LastMenuText := FromUtf8(Items^.Text);
  Result := 1;
end;

function FGetParameterCount(E: PJcpEditor): Int32; cdecl;
begin
  CheckEd(E);
  Result := NumTestParams;
end;

function FFindParameter(E: PJcpEditor; Id: PAnsiChar): Int32; cdecl;
var
  I: Integer;
  PId, PName, PUnits: string;
begin
  CheckEd(E);
  Result := -1;
  for I := 0 to JuceParameterCount - 1 do
    if JuceParameterInfo(I, PId, PName, PUnits) and (PId = FromUtf8(Id)) then
      Result := I;
end;

function ValidIndex(I: Int32): Boolean;
begin
  Result := (I >= 0) and (I < NumTestParams);
end;

function FGetParameterNormalised(E: PJcpEditor; Index: Int32): Single; cdecl;
begin
  CheckEd(E);
  if ValidIndex(Index) then Result := FE.Params[Index] else Result := 0;
end;

function FGetParameterDefault(E: PJcpEditor; Index: Int32): Single; cdecl;
begin
  CheckEd(E);
  if ValidIndex(Index) then Result := FE.Defaults[Index] else Result := 0;
end;

function FNormalisedToPlain(E: PJcpEditor; Index: Int32; V: Single): Single; cdecl;
begin
  CheckEd(E);
  Result := V * 100;
end;

function FPlainToNormalised(E: PJcpEditor; Index: Int32; V: Single): Single; cdecl;
begin
  CheckEd(E);
  Result := V / 100;
end;

function FGetParameterText(E: PJcpEditor; Index: Int32; V: Single; Buffer: PAnsiChar; Size: Int32): Int32; cdecl;
var
  U: UTF8String;
begin
  CheckEd(E);
  U := UTF8String(Format('%d%%', [Round(V * 100)]));
  Result := Min(Length(U), Size - 1);
  if Result > 0 then
    Move(PAnsiChar(U)^, Buffer^, Result);
  if Size > 0 then
    Buffer[Max(0, Result)] := #0;
end;

procedure FBeginGesture(E: PJcpEditor; Index: Int32); cdecl;
begin
  CheckEd(E);
  Inc(FE.Begins);
end;

procedure FSetParameterNormalised(E: PJcpEditor; Index: Int32; V: Single); cdecl;
begin
  CheckEd(E);
  Inc(FE.Sets);
  FE.LastSetIndex := Index;
  FE.LastSet := V;
  if ValidIndex(Index) then
    FE.Params[Index] := V;
end;

procedure FEndGesture(E: PJcpEditor; Index: Int32); cdecl;
begin
  CheckEd(E);
  Inc(FE.Ends);
end;

function FGetMeter(E: PJcpEditor; Index: Int32): Single; cdecl;
begin
  CheckEd(E);
  if (Index >= 0) and (Index <= High(FE.Meters)) then Result := FE.Meters[Index] else Result := 0;
end;

function FCreateImage(E: PJcpEditor; Data: Pointer; Size: Int32): Int32; cdecl;
begin
  CheckEd(E);
  if (Data = nil) or (Size < 4) or (PAnsiChar(Data)[0] <> 'I') then
    Exit(0);
  Inc(FE.ImagesCreated);
  Inc(FE.NextImage);
  Result := FE.NextImage;
end;

procedure FDestroyImage(E: PJcpEditor; Image: Int32); cdecl;
begin
  CheckEd(E);
  Inc(FE.ImagesDestroyed);
end;

function FGetImageSize(E: PJcpEditor; Image: Int32; var W, H: Int32): Int32; cdecl;
begin
  CheckEd(E);
  W := 64;
  H := 640; { a 10-frame vertical filmstrip }
  Result := 1;
end;

function FGetTextWidth(E: PJcpEditor; Text, FontName: PAnsiChar; Height: Single; Style: Int32): Single; cdecl;
begin
  CheckEd(E);
  Result := StrLen(Text) * Height * 0.5;
end;

procedure GSetColour(G: PJcpGraphics; C: Cardinal); cdecl; begin CheckG(G); end;
procedure GSetGradient(G: PJcpGraphics; C1: Cardinal; X1, Y1: Single; C2: Cardinal; X2, Y2: Single; R: Int32); cdecl; begin CheckG(G); end;
procedure GFillAll(G: PJcpGraphics); cdecl; begin CheckG(G); end;
procedure GRect(G: PJcpGraphics; X, Y, W, H: Single); cdecl; begin CheckG(G); end;
procedure GRectT(G: PJcpGraphics; X, Y, W, H, T: Single); cdecl; begin CheckG(G); end;
procedure GRectRT(G: PJcpGraphics; X, Y, W, H, R, T: Single); cdecl; begin CheckG(G); end;
procedure GLine(G: PJcpGraphics; X1, Y1, X2, Y2, T: Single); cdecl; begin CheckG(G); end;
procedure GPath(G: PJcpGraphics); cdecl; begin CheckG(G); end;
procedure GPoint(G: PJcpGraphics; X, Y: Single); cdecl; begin CheckG(G); end;
procedure GQuad(G: PJcpGraphics; A, B, C, D: Single); cdecl; begin CheckG(G); end;
procedure GCubic(G: PJcpGraphics; A, B, C, D, E, F: Single); cdecl; begin CheckG(G); end;
procedure GArc(G: PJcpGraphics; CX, CY, RX, RY, A0, A1: Single; S: Int32); cdecl; begin CheckG(G); Inc(FE.Arcs); end;
procedure GStroke(G: PJcpGraphics; T: Single; J, C: Int32); cdecl; begin CheckG(G); end;
procedure GFont(G: PJcpGraphics; Name: PAnsiChar; H: Single; S: Int32); cdecl; begin CheckG(G); end;
procedure GText(G: PJcpGraphics; Text: PAnsiChar; X, Y, W, H: Single; J, E: Int32); cdecl;
begin
  CheckG(G);
  FE.LastText := FromUtf8(Text);
end;
procedure GImage(G: PJcpGraphics; Img: Int32; DX, DY, DW, DH, SX, SY, SW, SH, O: Single); cdecl;
begin
  CheckG(G);
  FE.LastImageSY := SY;
  FE.LastImageSH := SH;
end;
procedure GSave(G: PJcpGraphics); cdecl; begin CheckG(G); Inc(FE.Saves); end;
procedure GRestore(G: PJcpGraphics); cdecl; begin CheckG(G); Inc(FE.Restores); end;
function GClip(G: PJcpGraphics; X, Y, W, H: Single): Int32; cdecl; begin CheckG(G); Result := Ord((W > 0) and (H > 0)); end;
procedure GTranslate(G: PJcpGraphics; DX, DY: Single); cdecl; begin CheckG(G); end;

procedure FSetDesignSize(E: PJcpEditor; W, H: Int32; MinS, MaxS: Single; Flags: Int32); cdecl;
begin
  CheckEd(E);
  Inc(FE.DesignCalls);
  FE.DesignW := W;
  FE.DesignH := H;
  FE.MinScale := MinS;
  FE.MaxScale := MaxS;
  FE.ScaleFlags := Flags;
end;

function FGetScale(E: PJcpEditor): Single; cdecl;
begin
  CheckEd(E);
  Result := FE.Scale;
end;

function FOpenUrl(E: PJcpEditor; Url: PAnsiChar): Int32; cdecl;
begin
  CheckEd(E);
  Inc(FE.UrlCalls);
  FE.LastUrl := FromUtf8(Url);
  Result := 1;
end;

function FChooseFile(E: PJcpEditor; RequestId, Mode: Int32; Title, Patterns, Initial: PAnsiChar): Int32; cdecl;
begin
  CheckEd(E);
  Inc(FE.FileCalls);
  FE.LastFileRequest := RequestId;
  FE.LastFileMode := Mode;
  FE.LastFileTitle := FromUtf8(Title);
  FE.LastFilePatterns := FromUtf8(Patterns);
  FE.LastFileInitial := FromUtf8(Initial);
  if FE.RefuseFile then
    Result := 0
  else
    Result := 1;
end;

procedure FSetLook(E: PJcpEditor; Look: PJcpEditorLook); cdecl;
begin
  CheckEd(E);
  Inc(FE.LookCalls);
  if Look = nil then
    Exit;
  if Look^.StructSize <> SizeOf(TJcpEditorLook) then
    Inc(FE.BadHandles);
  FE.LastLook := Look^;
  FE.LastLookFont := FromUtf8(Look^.FontName);
  FE.LastLook.FontName := nil;
end;

procedure ResetFake;
var
  I: Integer;
begin
  FE.Tooltip := '';
  FE.LastMenuText := '';
  FE.LastText := '';
  FE.LastUrl := '';
  FE.LastLookFont := '';
  FE.LastFileTitle := '';
  FE.LastFilePatterns := '';
  FE.LastFileInitial := '';
  FillChar(FE, SizeOf(FE), 0);
  for I := 0 to NumTestParams - 1 do
  begin
    FE.Params[I] := 0.5;
    FE.Defaults[I] := 0.5;
  end;
  FE.Params[1] := 0; { mode }
  FE.Defaults[1] := 0;
  FillChar(FakeApi, SizeOf(FakeApi), 0);
  FakeApi.StructSize := SizeOf(FakeApi);
  FakeApi.Repaint := FRepaint;
  FakeApi.SetSize := FSetSize;
  FakeApi.SetResizeLimits := FSetResizeLimits;
  FakeApi.StartTimer := FStartTimer;
  FakeApi.StopTimer := FStopTimer;
  FakeApi.SetTooltip := FSetTooltip;
  FakeApi.ShowPopupMenu := FShowPopupMenu;
  FakeApi.GetParameterCount := FGetParameterCount;
  FakeApi.FindParameter := FFindParameter;
  FakeApi.GetParameterNormalised := FGetParameterNormalised;
  FakeApi.GetParameterDefault := FGetParameterDefault;
  FakeApi.NormalisedToPlain := FNormalisedToPlain;
  FakeApi.PlainToNormalised := FPlainToNormalised;
  FakeApi.GetParameterText := FGetParameterText;
  FakeApi.BeginGesture := FBeginGesture;
  FakeApi.SetParameterNormalised := FSetParameterNormalised;
  FakeApi.EndGesture := FEndGesture;
  FakeApi.GetMeter := FGetMeter;
  FakeApi.CreateImage := FCreateImage;
  FakeApi.DestroyImage := FDestroyImage;
  FakeApi.GetImageSize := FGetImageSize;
  FakeApi.GetTextWidth := FGetTextWidth;
  FakeApi.SetColour := GSetColour;
  FakeApi.SetGradient := GSetGradient;
  FakeApi.FillAll := GFillAll;
  FakeApi.FillRect := GRect;
  FakeApi.DrawRect := GRectT;
  FakeApi.FillRoundedRect := GRectT;
  FakeApi.DrawRoundedRect := GRectRT;
  FakeApi.FillEllipse := GRect;
  FakeApi.DrawEllipse := GRectT;
  FakeApi.DrawLine := GLine;
  FakeApi.PathBegin := GPath;
  FakeApi.PathMoveTo := GPoint;
  FakeApi.PathLineTo := GPoint;
  FakeApi.PathQuadTo := GQuad;
  FakeApi.PathCubicTo := GCubic;
  FakeApi.PathArc := GArc;
  FakeApi.PathClose := GPath;
  FakeApi.FillPath := GPath;
  FakeApi.StrokePath := GStroke;
  FakeApi.SetFont := GFont;
  FakeApi.DrawText := GText;
  FakeApi.DrawImage := GImage;
  FakeApi.SaveState := GSave;
  FakeApi.RestoreState := GRestore;
  FakeApi.ClipRect := GClip;
  FakeApi.Translate := GTranslate;
  FakeApi.SetDesignSize := FSetDesignSize;
  FakeApi.GetScale := FGetScale;
  FakeApi.OpenUrl := FOpenUrl;
  FakeApi.SetLook := FSetLook;
  FakeApi.ChooseFile := FChooseFile;
  FE.Scale := 1;
end;

{ ---------------------------------------------------------------------------- }
{ Test plug-in and editor                                                      }
{ ---------------------------------------------------------------------------- }

type
  TBrokenControl = class(TJuceControl)
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
  end;

  TTestEditor = class(TJuceEditor)
  public
    Knob: TJuceKnob;
    Slider: TJuceSlider;
    Switch3: TJuceSwitch;
    Toggle: TJuceButton;
    Momentary: TJuceButton;
    Led: TJuceLed;
    Meter: TJuceMeter;
    Panel: TJucePanel;
    Inner: TJuceKnob;
    Broken: TBrokenControl;
    Film: TJuceKnob;
    ContextMenus, Clicks, Changes, MenuAnswers, LastAnswer, LinkClicks: Integer;
    FileAnswers: Integer;
    FileChosenOk: Boolean;
    FilePath: string;
    procedure OnFile(Sender: TJuceEditor; Chosen: Boolean; const Path: string);

    constructor Create(APlugin: TJucePlugin); override;
    procedure OnMenu(Sender: TJuceControl; X, Y: Single; var Handled: Boolean);
    procedure OnClicked(Sender: TObject);
    procedure OnChanged(Sender: TObject);
    procedure OnAnswer(Sender: TJuceEditor; MenuId, ItemId: Integer);
    procedure OnNoteOn(Sender: TJuceControl; Note: Integer; Velocity: Single);
    procedure OnNoteOff(Sender: TJuceControl; Note: Integer; Velocity: Single);
    procedure OnValText(Sender: TJuceParamControl; Normalised: Single; var Text: string);
    procedure OnLinkClick(Sender: TObject);
  end;

  TUiPlugin = class(TJucePlugin)
  public
    procedure Process(const Ctx: TJuceProcessContext); override;
    function CreateEditor: TJuceEditorBase; override;
  end;

var
  CreateMode: Integer; { 0 editor, 1 nil (generic), 2 raise }
  NaNValue: Single;
  PGain, PMode, POn, PCutoff: Integer;
  GNoteLog: string; { what keyboards played, as +note / -note }

procedure TBrokenControl.Paint(Canvas: TJuceCanvas);
begin
  raise Exception.Create('broken paint');
end;

constructor TTestEditor.Create(APlugin: TJucePlugin);
var
  Img: TBytes;
begin
  inherited Create(APlugin);
  SetSize(400, 260);
  Knob := TJuceKnob.Create(Root);
  Knob.SetBounds(10, 10, 72, 96);
  Knob.Caption := 'GAIN';
  Knob.ParameterId := 'gain';
  Knob.Hint := 'Gain knob';
  Knob.OnContextMenu := OnMenu;
  Slider := TJuceSlider.Create(Root);
  Slider.SetBounds(100, 10, 48, 160);
  Slider.ParameterId := 'cutoff';
  Switch3 := TJuceSwitch.Create(Root);
  Switch3.SetBounds(160, 10, 120, 56);
  Switch3.Positions := 3;
  Switch3.Labels := 'A|B|C';
  Switch3.ParameterId := 'mode';
  Toggle := TJuceButton.Create(Root);
  Toggle.SetBounds(160, 80, 72, 28);
  Toggle.ParameterId := 'on';
  Toggle.Caption := 'ON';
  Momentary := TJuceButton.Create(Root);
  Momentary.SetBounds(160, 120, 72, 28);
  Momentary.Mode := jbmMomentary;
  Momentary.OnClick := OnClicked;
  Momentary.OnChange := OnChanged;
  Led := TJuceLed.Create(Root);
  Led.SetBounds(250, 80, 16, 16);
  Led.MeterIndex := 1;
  Meter := TJuceMeter.Create(Root);
  Meter.SetBounds(300, 10, 16, 120);
  Meter.MeterIndex := 0;
  Panel := TJucePanel.Create(Root);
  Panel.SetBounds(10, 180, 200, 70);
  Panel.Caption := 'Panel';
  Inner := TJuceKnob.Create(Panel);
  Inner.SetBounds(120, 4, 60, 60);
  Inner.ShowValue := False;
  Broken := TBrokenControl.Create(Root);
  Broken.SetBounds(330, 10, 20, 20);
  Film := TJuceKnob.Create(Root);
  Film.SetBounds(330, 150, 64, 64);
  Film.ShowValue := False;
  Film.Style := jksFilmstrip;
  Film.FilmstripImage := 'strip';
  Film.FilmstripFrames := 10;
  SetLength(Img, 8);
  FillChar(Img[0], 8, Ord('I'));
  AddImage('strip', Img);
end;

procedure TTestEditor.OnMenu(Sender: TJuceControl; X, Y: Single; var Handled: Boolean);
begin
  Inc(ContextMenus);
  Handled := True;
end;

procedure TTestEditor.OnNoteOn(Sender: TJuceControl; Note: Integer; Velocity: Single);
begin
  GNoteLog := GNoteLog + ' +' + IntToStr(Note);
end;

procedure TTestEditor.OnNoteOff(Sender: TJuceControl; Note: Integer; Velocity: Single);
begin
  GNoteLog := GNoteLog + ' -' + IntToStr(Note);
end;

procedure TTestEditor.OnClicked(Sender: TObject);
begin
  Inc(Clicks);
end;

procedure TTestEditor.OnChanged(Sender: TObject);
begin
  Inc(Changes);
end;

procedure TTestEditor.OnFile(Sender: TJuceEditor; Chosen: Boolean; const Path: string);
begin
  Inc(FileAnswers);
  FileChosenOk := Chosen;
  FilePath := Path;
end;

procedure TTestEditor.OnAnswer(Sender: TJuceEditor; MenuId, ItemId: Integer);
begin
  Inc(MenuAnswers);
  LastAnswer := ItemId;
end;

procedure TTestEditor.OnValText(Sender: TJuceParamControl; Normalised: Single; var Text: string);
begin
  Text := Text + ' [' + FormatFloat('0.00', Normalised) + ']';
end;

procedure TTestEditor.OnLinkClick(Sender: TObject);
begin
  Inc(LinkClicks);
end;

procedure TUiPlugin.Process(const Ctx: TJuceProcessContext);
begin
end;

function TUiPlugin.CreateEditor: TJuceEditorBase;
begin
  case CreateMode of
    1: Result := nil;
    2: raise Exception.Create('editor construction failed');
  else
    Result := TTestEditor.Create(Self);
  end;
end;

{ ---------------------------------------------------------------------------- }
{ Helpers                                                                      }
{ ---------------------------------------------------------------------------- }

var
  EdVT: TJcpEditorVTable;
  Ed: Pointer;

function OpenEditor: TTestEditor;
var
  W, H: Int32;
begin
  FillChar(EdVT, SizeOf(EdVT), 0);
  EdVT.StructSize := SizeOf(EdVT);
  W := 400;
  H := 300;
  Ed := PlugVT.CreateEditor(Inst, @FakeApi, EditorToken, @EdVT, W, H);
  Result := TTestEditor(Ed);
end;

procedure CloseEditor;
begin
  if Ed <> nil then
    EdVT.Destroy(Ed);
  Ed := nil;
end;

procedure Mouse(Kind: Integer; X, Y: Single; Mods: Integer; DY: Single = 0);
var
  E: TJcpMouseEvent;
begin
  FillChar(E, SizeOf(E), 0);
  E.StructSize := SizeOf(E);
  E.Kind := Kind;
  E.X := X;
  E.Y := Y;
  E.Modifiers := Mods;
  E.ClickCount := 1;
  E.WheelDY := DY;
  EdVT.Mouse(Ed, @E);
end;

procedure Drag(X, Y, DX, DY: Single; Mods: Integer);
begin
  Mouse(JCP_MOUSE_DOWN, X, Y, JCP_MOD_LEFT or Mods);
  Mouse(JCP_MOUSE_DRAG, X + DX / 2, Y + DY / 2, JCP_MOD_LEFT or Mods);
  Mouse(JCP_MOUSE_DRAG, X + DX, Y + DY, JCP_MOD_LEFT or Mods);
  Mouse(JCP_MOUSE_UP, X + DX, Y + DY, Mods);
end;

procedure PaintOnce;
begin
  EdVT.Paint(Ed, GraphicsToken);
end;

{ ---------------------------------------------------------------------------- }
{ Tests                                                                        }
{ ---------------------------------------------------------------------------- }

function OffsetOf(Base, Field: Pointer): Integer;
begin
  Result := Integer(PAnsiChar(Field) - PAnsiChar(Base));
end;

procedure TestLayout;
var
  A: TJcpEditorApi;
  V: TJcpPluginVTable;
  H: TJcpHostApi;
  M: TJcpMouseEvent;
  EV: TJcpEditorVTable;
  L: TJcpEditorLook;
begin
  Suite('Editor ABI layout (= static_asserts in pascaljuce_plugin_processor.cpp)');
  CheckEquals(96, SizeOf(TJcpHostApi), 'jcp_host_api size');
  CheckEquals(80, OffsetOf(@H, @@H.SetMeter), 'set_meter offset');
  CheckEquals(88, OffsetOf(@H, @@H.ProgramsChanged), 'programs_changed offset');
  CheckEquals(128, SizeOf(TJcpPluginVTable), 'jcp_plugin_vtable size');
  CheckEquals(88, OffsetOf(@V, @@V.CreateEditor), 'create_editor offset');
  CheckEquals(96, OffsetOf(@V, @@V.GetProgramCount), 'get_program_count offset');
  CheckEquals(120, OffsetOf(@V, @@V.GetProgramName), 'get_program_name offset');
  CheckEquals(32, SizeOf(TJcpMouseEvent), 'jcp_mouse_event size');
  CheckEquals(28, OffsetOf(@M, @M.WheelDY), 'wheel_dy offset');
  CheckEquals(72, SizeOf(TJcpEditorVTable), 'jcp_editor_vtable size');
  CheckEquals(56, OffsetOf(@EV, @@EV.PopupResult), 'popup_result offset');
  CheckEquals(64, OffsetOf(@EV, @@EV.FileChosen), 'file_chosen offset');
  CheckEquals(16, SizeOf(TJcpMenuItem), 'jcp_menu_item size');
  CheckEquals(432, SizeOf(TJcpEditorApi), 'jcp_editor_api size');
  CheckEquals(424, OffsetOf(@A, @@A.ChooseFile), 'choose_file offset');
  CheckEquals(144, OffsetOf(@A, @@A.GetMeter), 'get_meter offset');
  CheckEquals(184, OffsetOf(@A, @@A.SetColour), 'set_colour offset');
  CheckEquals(384, OffsetOf(@A, @@A.Translate), 'translate offset');
  CheckEquals(392, OffsetOf(@A, @@A.SetDesignSize), 'set_design_size offset');
  CheckEquals(416, OffsetOf(@A, @@A.SetLook), 'set_look offset');
  CheckEquals(56, SizeOf(TJcpEditorLook), 'jcp_editor_look size');
  CheckEquals(40, OffsetOf(@L, @L.TooltipFontHeight), 'tooltip_font_height offset');
  CheckEquals(48, OffsetOf(@L, @L.FontName), 'font_name offset');
end;

procedure TestCreation;
var
  W, H: Int32;
  SmallApi: TJcpEditorApi;
begin
  Suite('Editor creation and the generic fallback');
  Check(Assigned(PlugVT.CreateEditor), 'create_editor handed to the wrapper');
  CreateMode := 1;
  Check(OpenEditor = nil, 'CreateEditor returning nil -> generic editor');
  CreateMode := 2;
  Check(OpenEditor = nil, 'exception in CreateEditor -> generic editor, nothing escapes');
  CreateMode := 0;
  SmallApi := FakeApi;
  SmallApi.StructSize := 100;
  FillChar(EdVT, SizeOf(EdVT), 0);
  EdVT.StructSize := SizeOf(EdVT);
  W := 0;
  H := 0;
  Check(PlugVT.CreateEditor(Inst, @SmallApi, EditorToken, @EdVT, W, H) = nil,
    'an older wrapper''s smaller editor API -> no custom editor');
  EdVT.StructSize := 8;
  Check(PlugVT.CreateEditor(Inst, @FakeApi, EditorToken, @EdVT, W, H) = nil, 'vtable without room for destroy -> refused');
  Check(PlugVT.CreateEditor(Inst, nil, EditorToken, @EdVT, W, H) = nil, 'NULL api -> refused');

  ResetFake;
  OpenEditor;
  Check(Ed <> nil, 'editor created');
  Check(Assigned(EdVT.Destroy) and Assigned(EdVT.Paint) and Assigned(EdVT.Mouse) and Assigned(EdVT.Timer)
    and Assigned(EdVT.ParameterChanged) and Assigned(EdVT.Resized) and Assigned(EdVT.PopupResult), 'editor vtable filled');
  CheckEquals(1, FE.SetSizes, 'SetSize in the constructor reached the host');
  CheckEquals(400, FE.LastW, 'width');
  CheckEquals(260, FE.LastH, 'height');
  CheckEquals(1, FE.TimerStarts, 'timer started for the meter and LED');
  CheckEquals(30, FE.TimerHz, 'at 30 Hz');
  CheckEquals(PGain, TTestEditor(Ed).Knob.ParamIndex, 'knob bound by id');
  CheckEquals(PCutoff, TTestEditor(Ed).Slider.ParamIndex, 'slider bound by id');
  CheckEquals(-1, TTestEditor(Ed).Inner.ParamIndex, 'control without ParameterId unbound');
  CheckEquals(0.5, TTestEditor(Ed).Knob.Value, 1e-6, 'bound value read from the host');
  CheckEquals(1, FE.ImagesCreated, 'image registered in the constructor');
  CloseEditor;
  CheckEquals(1, FE.ImagesDestroyed, 'image destroyed with the editor');
  CheckEquals(0, FE.BadHandles, 'every call used the editor handle it was given');
end;

procedure TestPaint;
var
  E: TTestEditor;
begin
  Suite('Painting');
  ResetFake;
  E := OpenEditor;
  PaintOnce;
  Check(FE.Ops > 50, Format('controls painted (%d drawing calls)', [FE.Ops]));
  CheckEquals(FE.Saves, FE.Restores, 'save / restore balanced');
  Check(FE.Arcs >= 3, 'knob arcs drawn (track and value; no value arc at 0)');
  CheckEquals(0, FE.BadHandles, 'drawing used only the graphics token of this paint');
  { the broken control raised, the controls after it still painted }
  Check(FE.LastImageSH > 0, 'filmstrip painted after a control that raised');
  CheckEquals(64.0, FE.LastImageSH, 1e-3, 'one filmstrip frame (640 / 10)');
  E.Film.Value := 1;
  PaintOnce;
  CheckEquals(576.0, FE.LastImageSY, 1e-3, 'last frame for value 1');
  E.Film.Value := 0.5;
  PaintOnce;
  CheckEquals(256.0, FE.LastImageSY, 1e-3, 'frame 4 for value 0.5 (Round(4.5) = 4)');
  CloseEditor;
end;

procedure TestKnob;
var
  E: TTestEditor;
  CX, CY, V: Single;
begin
  Suite('Knob');
  ResetFake;
  E := OpenEditor;
  CX := 10 + 6 + 30;  { knob rect: 60 px square at (6, 18) inside the control }
  CY := 10 + 18 + 30;
  Drag(CX, CY, 0, -50, 0);
  CheckEquals(0.75, FE.Params[PGain], 1e-4, '50 px up of 200 -> +0.25');
  CheckEquals(1, FE.Begins, 'one gesture begun');
  CheckEquals(1, FE.Ends, 'and ended');
  Check(FE.LastSetIndex = PGain, 'set the bound parameter');
  CheckEquals(0.75, E.Knob.Value, 1e-4, 'control shows the new value');
  Drag(CX, CY, 0, -100, JCP_MOD_SHIFT);
  CheckEquals(0.80, FE.Params[PGain], 1e-4, 'Shift: ten times finer');
  { Shift pressed mid-drag: no jump }
  Mouse(JCP_MOUSE_DOWN, CX, CY, JCP_MOD_LEFT);
  Mouse(JCP_MOUSE_DRAG, CX, CY - 20, JCP_MOD_LEFT);
  V := FE.Params[PGain];
  CheckEquals(0.90, V, 1e-4, '20 px -> +0.1');
  Mouse(JCP_MOUSE_DRAG, CX, CY - 20, JCP_MOD_LEFT or JCP_MOD_SHIFT);
  CheckEquals(V, FE.Params[PGain], 1e-6, 'pressing Shift does not jump');
  Mouse(JCP_MOUSE_DRAG, CX, CY - 40, JCP_MOD_LEFT or JCP_MOD_SHIFT);
  CheckEquals(0.91, FE.Params[PGain], 1e-4, 'then continues finely');
  Mouse(JCP_MOUSE_DRAG, CX, CY - 40, JCP_MOD_LEFT); { Shift released: re-anchor }
  Mouse(JCP_MOUSE_DRAG, CX, CY - 400, JCP_MOD_LEFT);
  CheckEquals(1.0, FE.Params[PGain], 1e-6, 'clamped at 1');
  Mouse(JCP_MOUSE_UP, CX, CY - 400, 0);
  CheckEquals(FE.Begins, FE.Ends, 'gestures balanced');
  Mouse(JCP_MOUSE_DOUBLE_CLICK, CX, CY, 0);
  CheckEquals(0.5, FE.Params[PGain], 1e-6, 'double-click -> default');
  Mouse(JCP_MOUSE_WHEEL, CX, CY, 0, 0.25);
  CheckEquals(0.55, FE.Params[PGain], 1e-4, 'wheel up');
  Mouse(JCP_MOUSE_WHEEL, CX, CY, JCP_MOD_SHIFT, -0.25);
  CheckEquals(0.545, FE.Params[PGain], 1e-4, 'Shift + wheel: finer');
  CheckEquals(FE.Begins, FE.Ends, 'every edit is one balanced gesture');
  { right click }
  Mouse(JCP_MOUSE_DOWN, CX, CY, JCP_MOD_RIGHT or JCP_MOD_POPUP);
  Mouse(JCP_MOUSE_UP, CX, CY, 0);
  CheckEquals(1, E.ContextMenus, 'right click raises OnContextMenu');
  CheckEquals(FE.Begins, FE.Ends, 'and no gesture');
  { value text }
  CheckEquals('50% Hz', E.Slider.ValueText, 'value text: ParameterToText (host) + units');
  { host automation }
  FE.Repaints := 0;
  EdVT.ParameterChanged(Ed, PGain, 0.2);
  CheckEquals(0.2, E.Knob.Value, 1e-6, 'automation moves the knob');
  Check(FE.Repaints > 0, 'and repaints it');
  EdVT.ParameterChanged(Ed, 99, 0.7);
  EdVT.ParameterChanged(Ed, -1, 0.7);
  CheckEquals(0.2, E.Knob.Value, 1e-6, 'unknown indices ignored');
  CloseEditor;
end;

procedure TestOtherControls;
var
  E: TTestEditor;
  Before: Integer;
begin
  Suite('Slider, switch, buttons, LED, meter');
  ResetFake;
  E := OpenEditor;
  Drag(124, 100, 0, -(E.Slider.TrackRect.H / 4), 0);
  CheckEquals(0.75, FE.Params[PCutoff], 1e-3, 'slider: a quarter of the track -> +0.25');
  Drag(124, 100, 0, -(E.Slider.TrackRect.H / 4), JCP_MOD_SHIFT);
  CheckEquals(0.775, FE.Params[PCutoff], 1e-3, 'slider: Shift is finer');
  Mouse(JCP_MOUSE_DOUBLE_CLICK, 124, 100, 0);
  CheckEquals(0.5, FE.Params[PCutoff], 1e-6, 'slider: double-click -> default');

  { switch slot: (8, 2, 104, 18) inside the control at (160, 10) }
  Mouse(JCP_MOUSE_DOWN, 160 + 8 + 95, 10 + 2 + 9, JCP_MOD_LEFT);
  Mouse(JCP_MOUSE_UP, 160 + 8 + 95, 10 + 2 + 9, 0);
  CheckEquals(1.0, FE.Params[PMode], 1e-6, 'switch: click on the third position');
  CheckEquals(2, E.Switch3.Position, 'position 2');
  Mouse(JCP_MOUSE_WHEEL, 200, 30, 0, -0.25);
  CheckEquals(0.5, FE.Params[PMode], 1e-6, 'switch: wheel down one position');
  Mouse(JCP_MOUSE_DOWN, 200, 60, JCP_MOD_LEFT); { on the labels: steps }
  CheckEquals(1.0, FE.Params[PMode], 1e-6, 'switch: click on the labels steps through');
  Mouse(JCP_MOUSE_UP, 200, 60, 0);

  FE.Params[POn] := 0;
  EdVT.ParameterChanged(Ed, POn, 0);
  Mouse(JCP_MOUSE_DOWN, 190, 90, JCP_MOD_LEFT);
  Mouse(JCP_MOUSE_UP, 190, 90, 0);
  CheckEquals(1.0, FE.Params[POn], 1e-6, 'toggle: click turns on');
  Mouse(JCP_MOUSE_DOWN, 190, 90, JCP_MOD_LEFT);
  Mouse(JCP_MOUSE_UP, 190, 300, 0);
  CheckEquals(1.0, FE.Params[POn], 1e-6, 'toggle: released outside -> no change');
  Before := FE.Sets;
  Mouse(JCP_MOUSE_DOWN, 190, 130, JCP_MOD_LEFT);
  Check(E.Momentary.IsOn, 'momentary: on while held');
  Mouse(JCP_MOUSE_UP, 190, 130, 0);
  Check(not E.Momentary.IsOn, 'momentary: off when released');
  CheckEquals(1, E.Clicks, 'OnClick');
  CheckEquals(2, E.Changes, 'OnChange for an unbound control (on, off)');
  CheckEquals(Before, FE.Sets, 'an unbound control never touches parameters');
  CheckEquals(FE.Begins, FE.Ends, 'gestures balanced');

  FE.Meters[1] := 0.8;
  EdVT.Timer(Ed);
  Check(E.Led.IsOn, 'LED lit by its meter');
  FE.Meters[1] := 0.1;
  EdVT.Timer(Ed);
  Check(not E.Led.IsOn, 'LED off below the threshold');
  FE.Meters[0] := 1.0;
  EdVT.Timer(Ed);
  CheckEquals(0.0, E.Meter.LevelDb, 1e-3, 'meter: full scale = 0 dB');
  CheckEquals(1.0, E.Meter.Fraction, 1e-6, 'meter: full bar');
  FE.Meters[0] := 0;
  EdVT.Timer(Ed);
  CheckEquals(-1.5, E.Meter.LevelDb, 1e-3, 'meter: falls by DecayDb per tick');
  FE.Meters[0] := NaNValue;
  EdVT.Timer(Ed);
  CheckEquals(-3.0, E.Meter.LevelDb, 1e-3, 'meter: NaN treated as silence');
  CloseEditor;
end;

procedure TestHoverMenusLifetime;
var
  E: TTestEditor;
  Id, Id2: Integer;
begin
  Suite('Tooltips, menus, lifetime');
  ResetFake;
  E := OpenEditor;
  Mouse(JCP_MOUSE_MOVE, 40, 50, 0);
  CheckEquals('Gain knob', FE.Tooltip, 'tooltip from the control under the mouse');
  Check(E.Knob.Hovered, 'knob hovered');
  Mouse(JCP_MOUSE_MOVE, 380, 250, 0);
  CheckEquals('', FE.Tooltip, 'no tooltip over the background');
  Mouse(JCP_MOUSE_MOVE, 40, 50, 0);
  Mouse(JCP_MOUSE_EXIT, 40, 50, 0);
  Check(not E.Knob.Hovered and (FE.Tooltip = ''), 'mouse exit clears hover and tooltip');

  Id := E.PopupMenu([JuceMenuItem(1, 'One'), JuceMenuItem(0, '', JCP_MENU_SEPARATOR), JuceMenuItem(2, 'Two')], 5, 5, E.OnAnswer);
  Check(Id > 0, 'menu shown');
  CheckEquals(3, FE.LastMenuCount, 'all items passed');
  CheckEquals('One', FE.LastMenuText, 'item text passed as UTF-8');
  Id2 := E.PopupMenu([JuceMenuItem(1, 'Again')], 5, 5, E.OnAnswer);
  CheckEquals(0, Id2, 'second menu while one is open: refused');
  EdVT.PopupResult(Ed, Id + 100, 1);
  CheckEquals(0, E.MenuAnswers, 'answer for another menu ignored');
  EdVT.PopupResult(Ed, Id, 2);
  CheckEquals(1, E.MenuAnswers, 'answer delivered');
  CheckEquals(2, E.LastAnswer, 'with the chosen id');
  EdVT.PopupResult(Ed, Id, 1);
  CheckEquals(1, E.MenuAnswers, 'a second answer for the same menu is ignored');
  { file dialogs }
  Check(E.OpenFile('Open a disk', '*.hfe;*.img', 'C:\Disks', E.OnFile), 'OpenFile shown');
  Check((FE.FileCalls = 1) and (FE.LastFileMode = JCP_FILE_OPEN) and (FE.LastFileTitle = 'Open a disk')
    and (FE.LastFilePatterns = '*.hfe;*.img') and (FE.LastFileInitial = 'C:\Disks') and (FE.LastFileRequest > 0),
    'its mode, title, patterns and folder reach the wrapper');
  Check(E.FileDialogOpen, 'a dialog is waiting');
  Check(not E.SaveFile('Save', '', '', E.OnFile) and (FE.FileCalls = 1), 'one dialog at a time');
  EdVT.FileChosen(Ed, FE.LastFileRequest + 1, 'C:\x.img');
  CheckEquals(0, E.FileAnswers, 'an answer to another request is ignored');
  EdVT.FileChosen(Ed, FE.LastFileRequest, PAnsiChar(UTF8String('C:\Disks\caf' + #$C3#$A9 + '.hfe')));
  Check((E.FileAnswers = 1) and E.FileChosenOk and (Length(E.FilePath) > 0) and not E.FileDialogOpen,
    'the answer reaches the handler, and the dialog is done');
  EdVT.FileChosen(Ed, FE.LastFileRequest, 'C:\again.hfe');
  CheckEquals(1, E.FileAnswers, 'a second answer to the same request is ignored');
  Check(E.SaveFile('Save as', '*.img', '', E.OnFile) and (FE.LastFileMode = JCP_FILE_SAVE), 'SaveFile: save mode');
  EdVT.FileChosen(Ed, FE.LastFileRequest, nil);
  Check((E.FileAnswers = 2) and not E.FileChosenOk and (E.FilePath = ''), 'Cancel: not chosen, no path');
  FE.RefuseFile := True;
  Check(not E.OpenFile('x', '', '', E.OnFile) and not E.FileDialogOpen, 'refused by the wrapper: False, nothing waiting');
  FE.RefuseFile := False;

  FE.RefuseMenu := True;
  CheckEquals(0, E.PopupMenu([JuceMenuItem(1, 'x')], 0, 0, E.OnAnswer), 'host refused the menu -> 0');
  FE.RefuseMenu := False;
  Check(E.PopupMenu([JuceMenuItem(1, 'x')], 0, 0, E.OnAnswer) > 0, 'a new menu after the answer');

  { a control freed while it is being dragged }
  Mouse(JCP_MOUSE_DOWN, 46, 58, JCP_MOD_LEFT);
  Mouse(JCP_MOUSE_DRAG, 46, 40, JCP_MOD_LEFT);
  Check(E.Knob.GestureOpen, 'gesture open during the drag');
  E.Knob.Free;
  E.Knob := nil;
  CheckEquals(FE.Begins, FE.Ends, 'freeing the control ended its gesture');
  Check(E.Captured = nil, 'capture released');
  Mouse(JCP_MOUSE_DRAG, 46, 20, JCP_MOD_LEFT);
  Mouse(JCP_MOUSE_UP, 46, 20, 0);
  Mouse(JCP_MOUSE_MOVE, 46, 58, 0);
  PaintOnce;
  Check(True, 'events after the control went are harmless');

  { the editor closed mid-drag }
  Mouse(JCP_MOUSE_DOWN, 124, 100, JCP_MOD_LEFT);
  Mouse(JCP_MOUSE_DRAG, 124, 80, JCP_MOD_LEFT);
  Check(FE.Begins = FE.Ends + 1, 'slider gesture open');
  CloseEditor;
  CheckEquals(FE.Begins, FE.Ends, 'closing the editor ends the gesture');
  CheckEquals(0, FE.BadHandles, 'no stray handles');
end;

procedure TestHardwareControls;
var
  E: TTestEditor;
  Slide: TJuceSwitch;
  Fader: TJuceSlider;
  Btn: TJuceButton;
  Box, Free_: TJuceComboBox;
  Keys: TJuceKeyboard;
  Readout: TJuceDisplay;
  Begins: Integer;
begin
  Suite('Fader and slide styles, LED from a meter, combo box, keyboard, readout, hints');
  ResetFake;
  E := OpenEditor;

  { a vertical slide switch, 3 positions, no caption: travel 9 .. 200 - 4 - 9 }
  Slide := TJuceSwitch.Create(E.Root);
  Slide.SetBounds(220, 0, 66, 200);
  Slide.Style := jswSlide;
  Slide.Orientation := joVertical;
  Slide.Positions := 3;
  Slide.Labels := 'A|B|C';
  Slide.ParameterId := 'mode';
  CheckEquals(178.0, Slide.SlideRect.H, 1e-6, 'slide: the travel');
  Mouse(JCP_MOUSE_DOWN, 220 + 18, 9, JCP_MOD_LEFT);
  Mouse(JCP_MOUSE_UP, 220 + 18, 9, 0);
  CheckEquals(1.0, FE.Params[PMode], 1e-6, 'slide: a click at the top is the last position');
  Begins := FE.Begins;
  Drag(220 + 18, 9, 0, 85, 0);
  CheckEquals(0.5, FE.Params[PMode], 1e-6, 'slide: dragged down to the middle position');
  CheckEquals(Begins + 1, FE.Begins, 'slide: one gesture for the drag');
  Mouse(JCP_MOUSE_DOWN, 220 + 50, 187, JCP_MOD_LEFT);   { on the name of the first position }
  Mouse(JCP_MOUSE_UP, 220 + 50, 187, 0);
  CheckEquals(0.0, FE.Params[PMode], 1e-6, 'slide: a click on a name selects it');
  Slide.Positions := 40;
  CheckEquals(16, Slide.Positions, 'slide: at most 16 positions');
  Slide.Positions := 3;
  PaintOnce;

  { a fader with a caption: travel 30 + 9 .. 200 - 4 - 9 }
  Fader := TJuceSlider.Create(E.Root);
  Fader.SetBounds(300, 0, 42, 200);
  Fader.Style := jslFader;
  Fader.ShowValue := False;
  Fader.Caption := 'GAIN';
  Fader.ParameterId := 'gain';
  CheckEquals(148.0, Fader.TrackRect.H, 1e-6, 'fader: the travel');
  Drag(321, 100, 0, -37, 0);
  CheckEquals(0.75, FE.Params[PGain], 1e-3, 'fader: a quarter of the travel up -> +0.25');
  Fader.Ticks := 500;
  CheckEquals(100, Fader.Ticks, 'fader: at most 100 divisions');
  Fader.Ticks := 10;
  PaintOnce;

  { a button whose LED shows a meter, not its value }
  Btn := TJuceButton.Create(E.Root);
  Btn.SetBounds(350, 200, 48, 40);
  Btn.Mode := jbmMomentary;
  Btn.LedPosition := jlpTop;
  Btn.Flat := True;
  Btn.LedMeterIndex := 2;
  E.UpdateTimer;
  FE.Meters[2] := 1;
  EdVT.Timer(Ed);
  Check(Btn.LedLit and not Btn.IsOn, 'button: the LED follows its meter');
  FE.Meters[2] := 0;
  EdVT.Timer(Ed);
  Check(not Btn.LedLit, 'button: and goes out with it');
  PaintOnce;

  { a combo box on a choice parameter, and one with its own items }
  Box := TJuceComboBox.Create(E.Root);
  Box.SetBounds(220, 210, 120, 24);
  Box.ParameterId := 'mode';
  CheckEquals('A|B|C', Box.Choices, 'combo: the parameter''s choices');
  Mouse(JCP_MOUSE_DOWN, 230, 220, JCP_MOD_LEFT);
  Mouse(JCP_MOUSE_UP, 230, 220, 0);
  CheckEquals(3, FE.LastMenuCount, 'combo: a click shows a menu of them');
  CheckEquals('A', FE.LastMenuText, 'combo: in order');
  EdVT.PopupResult(Ed, FE.LastMenuId, 3);
  CheckEquals(1.0, FE.Params[PMode], 1e-6, 'combo: choosing C sets the parameter');
  CheckEquals(FE.Begins, FE.Ends, 'combo: in a gesture');
  Free_ := TJuceComboBox.Create(E.Root);
  Free_.SetBounds(220, 236, 120, 24);
  Free_.Items := 'one|two|three';
  Mouse(JCP_MOUSE_WHEEL, 230, 245, 0, -1);
  CheckEquals('two', Free_.Text, 'combo: unbound, the wheel steps through its items');
  PaintOnce;

  { a keyboard, C3..C5 over the whole width: 15 white keys }
  Keys := TJuceKeyboard.Create(E.Root);
  Keys.SetBounds(0, 0, 150, 100);
  Keys.FirstNote := 48;
  Keys.LastNote := 72;
  Keys.OnNoteOn := E.OnNoteOn;
  Keys.OnNoteOff := E.OnNoteOff;
  CheckEquals(10.0, Keys.KeyWidth, 1e-6, 'keyboard: 15 white keys');
  CheckEquals(49, Keys.NoteAt(8, 20), 'keyboard: a black key lies over the white ones');
  CheckEquals(48, Keys.NoteAt(3, 90), 'keyboard: and below it, the white key');
  CheckEquals(-1, Keys.NoteAt(3, 120), 'keyboard: off the keys, none');
  Mouse(JCP_MOUSE_DOWN, 25, 90, JCP_MOD_LEFT);
  Mouse(JCP_MOUSE_DRAG, 35, 90, JCP_MOD_LEFT);
  Mouse(JCP_MOUSE_UP, 35, 90, 0);
  CheckEquals('+52 -52 +53 -53', Trim(GNoteLog), 'keyboard: click, glissando, release');
  Keys.SetNoteLit(60, True);
  Check(Keys.NoteDown(60) and not Keys.NoteDown(61), 'keyboard: keys lit from code');
  PaintOnce;
  GNoteLog := '';
  Mouse(JCP_MOUSE_DOWN, 25, 90, JCP_MOD_LEFT);

  { a readout }
  Readout := TJuceDisplay.Create(E.Root);
  Readout.SetBounds(150, 230, 72, 28);
  Readout.Caption := '12/100';
  Readout.FontName := 'Lucida Console';
  PaintOnce;

  { hints that change under the mouse }
  Mouse(JCP_MOUSE_MOVE, 360, 210, 0);
  Btn.Hint := 'first';
  CheckEquals('first', FE.Tooltip, 'a new hint of the control under the mouse shows at once');
  Btn.Hint := 'second';
  CheckEquals('second', FE.Tooltip, 'and again');
  Box.Hint := 'elsewhere';
  CheckEquals('second', FE.Tooltip, 'another control''s hint does not');

  CloseEditor;
  CheckEquals('+52 -52', Trim(GNoteLog), 'keyboard: closing the window lets a held key go');
  CheckEquals(FE.Begins, FE.Ends, 'gestures balanced');
end;

procedure TestTree;
var
  A, B, C: TJuceControl;
  K: TJuceKnob;
begin
  Suite('Control tree and published properties');
  A := TJuceControl.Create(nil);
  try
    B := TJuceControl.Create(A);
    C := TJuceControl.Create(B);
    A.SetBounds(0, 0, 200, 200);
    B.SetBounds(10, 20, 100, 100);
    C.SetBounds(5, 5, 20, 20);
    CheckEquals(2, Integer(Ord(C.Parent = B)) + Integer(Ord(B.Parent = A)), 'parents from the owner');
    CheckEquals(15.0, C.AbsoluteX, 1e-6, 'absolute X');
    Check(A.ControlAt(20, 30) = C, 'hit test finds the deepest control');
    Check(A.ControlAt(60, 90) = B, 'and its parent elsewhere');
    C.Visible := False;
    Check(A.ControlAt(20, 30) = B, 'invisible controls are not hit');
    LastExceptionMessage := '';
    try
      A.Parent := C;
      Check(False, 'cycle refused');
    except
      on E: EArgumentException do Check(True, 'a control cannot become its own descendant');
    end;
    C.Parent := A;
    CheckEquals(2, A.ControlCount, 'reparented');
    CheckEquals(0, B.ControlCount, 'old parent forgets it');
    B.Free;
    CheckEquals(0, A.ControlCount, 'freeing B also freed C, which B owned (VCL rules), and both left their parents');
  finally
    A.Free;
  end;

  JuceRegisterControls;
  Check(FindClass('TJuceKnob') = TJuceKnob, 'controls registered by class name');
  K := TJuceKnob(TJuceControlClass(FindClass('TJuceKnob')).Create(nil));
  try
    Check(GetPropInfo(K, 'ParameterId') <> nil, 'ParameterId is published');
    SetStrProp(K, 'ParameterId', 'gain');
    SetStrProp(K, 'Caption', 'Drive');
    SetOrdProp(K, 'Left', 12);
    SetOrdProp(K, 'Width', 80);
    SetOrdProp(K, 'ArcColor', Int64($FF00FF00));
    SetEnumProp(K, 'Style', 'jksFilmstrip');
    SetFloatProp(K, 'StartAngle', -120);
    SetOrdProp(K, 'Visible', 0);
    CheckEquals('gain', K.ParameterId, 'string property set by name');
    CheckEquals('Drive', K.Caption, 'caption');
    CheckEquals(12, K.Left, 'Left');
    CheckEquals(80, K.Width, 'Width');
    Check(K.ArcColor = $FF00FF00, 'colour (Cardinal ARGB)');
    Check(K.Style = jksFilmstrip, 'enum by name');
    CheckEquals(-120.0, K.StartAngle, 1e-6, 'Single');
    Check(not K.Visible, 'Boolean');
    CheckEquals('jksFilmstrip', GetEnumProp(K, 'Style'), 'enum reads back by name');
    Check(GetPropInfo(TJucePanel, 'BackgroundImage') <> nil, 'panel image name published');
    Check(GetPropInfo(TJuceSwitch, 'Labels') <> nil, 'switch labels published');
    Check(GetPropInfo(TJuceMeter, 'MeterIndex') <> nil, 'meter index published');
    Check(GetPropInfo(TJuceKnob, 'OnContextMenu') <> nil, 'events published');
  finally
    K.Free;
  end;

  Suite('Colours');
  Check(JuceWithAlpha($FF102030, 0.5) = $80102030, 'with alpha');
  Check(JuceBlend($FF000000, $FFFFFFFF, 0.5) = $FF808080, 'blend');
  Check(JuceBlend($FF000000, $FFFFFFFF, NaNValue) = $FF000000, 'blend with NaN -> first colour');
  Check(JuceRgb(1, 2, 3) = $FF010203, 'rgb');
end;

procedure ProcessBlock;
var
  Ctx: TJuceProcessContext;
begin
  FillChar(Ctx, SizeOf(Ctx), 0);
  Ctx.StructSize := SizeOf(Ctx);
  PlugVT.Process(Inst, @Ctx);
end;

procedure TestScalingLookLinks;
var
  E: TTestEditor;
  Link: TJuceLink;
  SmallApi: TJcpEditorApi;
  W, H: Int32;
  Before: Integer;
  T: string;
begin
  Suite('Scaling, look, value bubble, jump to click, links, predicted meters');

  { an older wrapper (editor API up to translate): the editor still opens, the new calls are no-ops }
  ResetFake;
  SmallApi := FakeApi;
  SmallApi.StructSize := 392;
  FillChar(EdVT, SizeOf(EdVT), 0);
  EdVT.StructSize := SizeOf(EdVT);
  W := 0;
  H := 0;
  Ed := PlugVT.CreateEditor(Inst, @SmallApi, EditorToken, @EdVT, W, H);
  Check(Ed <> nil, 'an older wrapper without set_design_size still gets the custom editor');
  E := TTestEditor(Ed);
  Check(not E.SetScalable(0.5, 2), 'SetScalable: False without the wrapper function');
  CheckEquals(0, FE.DesignCalls, 'set_design_size not called past the API''s size');
  Check(not E.OpenUrl('https://example.com/'), 'OpenUrl: False without the wrapper function');
  CheckEquals(0, FE.UrlCalls + FE.LookCalls, 'nor open_url / set_look');
  CheckEquals(1.0, E.Scale, 1e-6, 'Scale 1 without get_scale');
  CloseEditor;

  ResetFake;
  E := OpenEditor;
  CheckEquals(1, FE.LookCalls, 'the theme''s look sent when the editor opens');
  CheckEquals(0, Integer(FE.LastLook.MenuBackground), 'default theme: JUCE''s menu colours (0)');
  E.Theme.MenuBackground := $FF112233;
  E.Theme.TooltipBorder := $FFAA0000;
  E.Theme.TooltipFontSize := 15;
  E.Theme.FontName := 'Lucida Console';
  E.ThemeChanged;
  CheckEquals(2, FE.LookCalls, 'ThemeChanged sends it again');
  Check(FE.LastLook.MenuBackground = $FF112233, 'menu background from the theme');
  Check(FE.LastLook.TooltipOutline = $FFAA0000, 'tooltip outline from the theme');
  CheckEquals(15.0, FE.LastLook.TooltipFontHeight, 1e-6, 'tooltip font size from the theme');
  CheckEquals('Lucida Console', FE.LastLookFont, 'font name from the theme');
  E.Theme.MenuFontSize := NaNValue;
  E.PopupMenu([JuceMenuItem(1, 'x')], 10, 10, E.OnAnswer);
  CheckEquals(3, FE.LookCalls, 'and before every popup menu');
  CheckEquals(0.0, FE.LastLook.MenuFontHeight, 1e-6, 'a NaN font size goes as 0 (JUCE''s)');
  EdVT.PopupResult(Ed, FE.LastMenuId, 0);

  { scaling }
  FE.Scale := 1.5;
  Check(E.SetScalable(0.5, 2, True), 'SetScalable');
  CheckEquals(1, FE.DesignCalls, 'set_design_size called once');
  CheckEquals(400, FE.DesignW, 'design width = the editor''s size');
  CheckEquals(260, FE.DesignH, 'design height');
  CheckEquals(0.5, FE.MinScale, 1e-6, 'min scale');
  CheckEquals(2.0, FE.MaxScale, 1e-6, 'max scale');
  CheckEquals(JCP_SCALE_CORNER_RESIZER, FE.ScaleFlags, 'corner resizer flag');
  Check(E.Scaled and (E.Width = 400) and (E.Height = 260), 'Width / Height stay the design size');
  CheckEquals(1.5, E.Scale, 1e-6, 'Scale from the wrapper');
  FE.Scale := NaNValue;
  CheckEquals(1.0, E.Scale, 1e-6, 'a NaN scale reads as 1');
  Check(not E.SetDesignSize(400, 260, NaNValue, 2), 'NaN scale limits refused');
  CheckEquals(1, FE.DesignCalls, '(not passed on)');
  E.SetResizeLimits(0, 0, 0, 0);
  Check(not E.Scaled, 'SetResizeLimits ends scaling');

  { jump to click: the slider's track is (0, 9, 48, 126) inside (100, 10) }
  Mouse(JCP_MOUSE_DOWN, 124, 10 + 9 + 126 * 0.25, JCP_MOD_LEFT);
  Mouse(JCP_MOUSE_UP, 124, 10 + 9 + 126 * 0.25, 0);
  CheckEquals(0.5, FE.Params[PCutoff], 1e-6, 'JumpToClick off: a click on the track moves nothing');
  E.Slider.JumpToClick := True;
  Before := FE.Begins;
  Mouse(JCP_MOUSE_DOWN, 124, 10 + 9 + 126 * 0.25, JCP_MOD_LEFT);
  CheckEquals(0.75, FE.Params[PCutoff], 1e-4, 'JumpToClick: the thumb jumps to the click');
  Mouse(JCP_MOUSE_DRAG, 124, 10 + 9 + 126 * 0.25 - 126 * 0.125, JCP_MOD_LEFT);
  CheckEquals(0.875, FE.Params[PCutoff], 1e-4, '... then drags from there');
  Mouse(JCP_MOUSE_UP, 124, 10 + 9, 0);
  CheckEquals(Before + 1, FE.Begins, 'jump and drag: one gesture');
  { on the thumb (at 0.875: y = 9 + 126 * 0.125 local) it is just picked up }
  Mouse(JCP_MOUSE_DOWN, 124, 10 + 9 + 126 * 0.125 + 4, JCP_MOD_LEFT);
  CheckEquals(0.875, FE.Params[PCutoff], 1e-4, 'a click on the thumb does not jump');
  Mouse(JCP_MOUSE_UP, 124, 10 + 9 + 126 * 0.125 + 4, 0);

  { the knob's ring: knob rect (6, 18, 60, 60) inside (10, 10), centre (46, 58), radius 28 }
  E.Knob.JumpToClick := True;
  Mouse(JCP_MOUSE_DOWN, 46, 58 - 26, JCP_MOD_LEFT);
  Mouse(JCP_MOUSE_UP, 46, 58 - 26, 0);
  CheckEquals(0.5, FE.Params[PGain], 1e-4, 'knob: 12 o''clock on the ring -> the middle');
  Mouse(JCP_MOUSE_DOWN, 46 + 26, 58, JCP_MOD_LEFT);
  Mouse(JCP_MOUSE_UP, 46 + 26, 58, 0);
  CheckEquals(225 / 270, FE.Params[PGain], 1e-4, 'knob: 3 o''clock -> 225 of 270 degrees');
  Mouse(JCP_MOUSE_DOWN, 46, 58 + 26, JCP_MOD_LEFT);
  Mouse(JCP_MOUSE_UP, 46, 58 + 26, 0);
  CheckEquals(225 / 270, FE.Params[PGain], 1e-4, 'knob: 6 o''clock is in the gap: no jump');
  Mouse(JCP_MOUSE_DOWN, 46, 58, JCP_MOD_LEFT);
  Mouse(JCP_MOUSE_UP, 46, 58, 0);
  CheckEquals(225 / 270, FE.Params[PGain], 1e-4, 'knob: a click on the body does not jump');
  E.Knob.StartAngle := 1e30;
  CheckEquals(-1.0, E.Knob.ValueAtPoint(36, 21), 1e-6, 'knob: absurd angles never jump (and never loop)');
  E.Knob.StartAngle := -135;

  { the value bubble }
  E.Slider.ValueBubble := jvbDrag;
  Mouse(JCP_MOUSE_DOWN, 124, 10 + 9 + 126 * 0.125, JCP_MOD_LEFT);
  Check(E.ValueBubbleOwner = E.Slider, 'bubble shown while the slider is dragged');
  CheckEquals(E.Slider.ValueText, E.ValueBubbleText, 'with the slider''s value text');
  Check((E.ValueBubbleRect.W > 0) and (E.ValueBubbleRect.Y > 10 + 9 + 126 * 0.125 + 7),
    'below the thumb (more room there than above)');
  Mouse(JCP_MOUSE_DRAG, 124, 10 + 9 + 126 * 0.5, JCP_MOD_LEFT);
  CheckEquals(E.Slider.ValueText, E.ValueBubbleText, 'the bubble follows the value');
  FE.Saves := 0;
  FE.Restores := 0;
  PaintOnce;
  CheckEquals(FE.Saves, FE.Restores, 'painted with the bubble: save / restore balanced');
  Check(Pos(E.Slider.ValueText, FE.LastText) > 0, 'the bubble is drawn last, over every control');
  Mouse(JCP_MOUSE_UP, 124, 10 + 9 + 126 * 0.5, 0);
  Check(E.ValueBubbleOwner = nil, 'and hidden when released');
  E.Slider.ValueBubble := jvbDragAndHover;
  Mouse(JCP_MOUSE_MOVE, 124, 100, 0);
  Check(E.ValueBubbleOwner = E.Slider, 'hover: shown when the mouse comes over');
  for Before := 1 to 59 do
    EdVT.Timer(Ed);
  Check(E.ValueBubbleOwner = E.Slider, 'still there after 59 ticks');
  EdVT.Timer(Ed);
  Check(E.ValueBubbleOwner = nil, 'gone after two seconds of ticks');
  Mouse(JCP_MOUSE_MOVE, 380, 250, 0);
  E.Knob.ValueBubble := jvbDrag;
  Mouse(JCP_MOUSE_DOWN, 46, 58, JCP_MOD_LEFT);
  Check(E.ValueBubbleOwner = E.Knob, 'knobs have it too');
  E.Knob.OnValueText := E.OnValText;
  Mouse(JCP_MOUSE_DRAG, 46, 50, JCP_MOD_LEFT);
  T := E.ValueBubbleText;
  Check(Copy(T, Length(T) - 6, 7) = ' [' + FormatFloat('0.00', E.Knob.Value) + ']', 'OnValueText: ' + T);
  Mouse(JCP_MOUSE_UP, 46, 50, 0);
  CheckEquals(E.Knob.ValueText, E.Knob.ValueTextFor(E.Knob.Value), 'ValueText = ValueTextFor(Value)');
  E.Knob.ValueBubble := jvbDrag;
  Mouse(JCP_MOUSE_DOWN, 46, 58, JCP_MOD_LEFT);
  E.Knob.Free; { freed mid-drag with its bubble up }
  E.Knob := nil;
  Check(E.ValueBubbleOwner = nil, 'a control freed with its bubble up takes the bubble along');
  Mouse(JCP_MOUSE_UP, 46, 58, 0);
  PaintOnce;

  { links }
  Link := TJuceLink.Create(E.Root);
  Link.SetBounds(200, 200, 100, 20);
  Link.Caption := 'example.com';
  Link.Url := 'https://example.com/page';
  Link.OnClick := E.OnLinkClick;
  Check(Link.HitTest(5, 5), 'a link takes clicks (a label does not)');
  PaintOnce;
  CheckEquals(0, FE.UrlCalls, 'never opened by painting');
  Mouse(JCP_MOUSE_DOWN, 250, 210, JCP_MOD_LEFT);
  CheckEquals(0, FE.UrlCalls, 'not on the press');
  Mouse(JCP_MOUSE_UP, 250, 210, 0);
  CheckEquals(1, FE.UrlCalls, 'opened on the click');
  CheckEquals('https://example.com/page', FE.LastUrl, 'its URL');
  CheckEquals(1, E.LinkClicks, 'OnClick');
  Mouse(JCP_MOUSE_DOWN, 250, 210, JCP_MOD_LEFT);
  Mouse(JCP_MOUSE_UP, 250, 300, 0);
  CheckEquals(1, FE.UrlCalls, 'released elsewhere: not opened');
  Link.Url := '';
  Mouse(JCP_MOUSE_DOWN, 250, 210, JCP_MOD_LEFT);
  Mouse(JCP_MOUSE_UP, 250, 210, 0);
  CheckEquals(1, FE.UrlCalls, 'no URL: only OnClick');
  CheckEquals(2, E.LinkClicks, '(OnClick again)');

  { predicted meters: until Process has run twice after it }
  E.PredictMeter(1, 1);
  E.PredictMeter(2, 0.75);
  E.PredictMeter(-1, 1);
  E.PredictMeter(JCP_MAX_METERS, 1);
  E.PredictMeter(3, NaNValue);
  CheckEquals(0.75, TJuceEditor(E).Meter(2), 1e-6, 'a predicted meter reads as predicted');
  CheckEquals(0.0, TJuceEditor(E).Meter(3), 1e-6, 'a NaN prediction is ignored');
  EdVT.Timer(Ed);
  Check(E.Led.IsOn, 'the LED follows the prediction without audio');
  ProcessBlock;
  CheckEquals(0.75, TJuceEditor(E).Meter(2), 1e-6, 'still after one block (it may have started before the press)');
  ProcessBlock;
  CheckEquals(0.0, TJuceEditor(E).Meter(2), 1e-6, 'the DSP''s own value after the next');
  EdVT.Timer(Ed);
  Check(not E.Led.IsOn, 'and the LED follows that');
  CloseEditor;
  CheckEquals(FE.Begins, FE.Ends, 'gestures balanced');
  CheckEquals(0, FE.BadHandles, 'no stray handles');
end;

{ One block of Count samples through the plug-in's Process (which leaves
  them alone), so the glue captures them for scopes. }
procedure ProcessAudio(const L, R: array of Single; Count, Outputs: Integer);
var
  Ctx: TJuceProcessContext;
  Chans: array[0..1] of PJuceSampleArray;
begin
  Chans[0] := PJuceSampleArray(@L[0]);
  Chans[1] := PJuceSampleArray(@R[0]);
  FillChar(Ctx, SizeOf(Ctx), 0);
  Ctx.StructSize := SizeOf(Ctx);
  Ctx.NumSamples := Count;
  Ctx.Channels := PJuceChannelArray(@Chans[0]);
  Ctx.NumChannels := Outputs;
  Ctx.NumOutputChannels := Outputs;
  PlugVT.Process(Inst, @Ctx);
end;

procedure TestScope;
const
  Big = JUCE_SCOPE_CAPACITY + 5000;
var
  S: TJuceScope;
  E: TTestEditor;
  P: TJucePlugin;
  Wave, Flat, L, R, Got: array of Single;
  I, N, Stamp, Stamp2: Integer;
  Ok: Boolean;
begin
  Suite('Oscilloscope');
  P := TJucePlugin(Inst);

  { the trigger, on samples given directly: a sine of period 100 }
  SetLength(Wave, 1000);
  for I := 0 to High(Wave) do
    Wave[I] := Sin(2 * Pi * (I + 0.3) / 100);
  S := TJuceScope.Create(nil);
  try
    S.ShowSamples(Wave, Length(Wave), 200);
    Check(S.Triggered, 'rising trigger found');
    CheckEquals(201, S.SampleCount, 'a sweep and the sample before the crossing');
    Check((S.Sample(0) < 0) and (S.Sample(1) >= 0), 'the sweep starts at a rising zero crossing');
    Ok := True;
    for I := 0 to S.SampleCount - 1 do
      if Abs(S.Sample(I) - Wave[799 + I]) > 1e-6 then
        Ok := False; { crossings at 100, 200, ...: 800 is the latest that leaves 200 after it }
    Check(Ok, 'the latest crossing with a whole sweep after it');
    S.Trigger := jstFalling;
    S.ShowSamples(Wave, Length(Wave), 200);
    Check(S.Triggered and (S.Sample(0) > 0) and (S.Sample(1) <= 0), 'falling trigger');
    S.Trigger := jstFree;
    S.ShowSamples(Wave, Length(Wave), 200);
    Check(not S.Triggered, 'free-running: no trigger');
    CheckEquals(200, S.SampleCount, 'free-running: the newest 200');
    CheckEquals(Wave[999], S.Sample(199), 1e-6, 'newest last');
    S.Trigger := jstRising;
    SetLength(Flat, 300);
    for I := 0 to High(Flat) do
      Flat[I] := 0.5;
    Flat[10] := NaNValue;
    S.ShowSamples(Flat, Length(Flat), 100);
    Check(not S.Triggered, 'no crossing: free-running');
    CheckEquals(100, S.SampleCount, '(the newest samples)');
    S.ShowSamples(Flat, 20, 100);
    CheckEquals(19, S.SampleCount, 'a span longer than the samples: all but one (kept for the trigger search)');
    S.ShowSamples(Flat, 1, 100);
    CheckEquals(0, S.SampleCount, 'one sample: nothing to draw');
    for I := 0 to 30 do
      Flat[I] := NaNValue;
    S.ShowSamples(Flat, 40, 39);
    CheckEquals(0.0, S.Sample(0), 0, 'NaN shown as silence');
    S.TimeMs := 10;
    CheckEquals(480, S.SweepLength, '10 ms at 48 kHz (no editor: the default rate)');
    S.TimeMs := 0;
    CheckEquals(960, S.SweepLength, 'no time: 20 ms');
    S.TimeMs := 1E9;
    CheckEquals(JUCE_SCOPE_MAX_READ div 2 - 1, S.SweepLength, 'capped');
    { a TIME control: logarithmic over 1..170 ms }
    CheckEquals(1.0, JuceScopeTimeFromValue(0), 1e-4, 'TIME 0: 1 ms');
    CheckEquals(170.0, JuceScopeTimeFromValue(1), 1e-2, 'TIME 1: 170 ms');
    CheckEquals(Sqrt(170.0), JuceScopeTimeFromValue(0.5), 1e-3, 'TIME 0.5: halfway on a log scale');
    CheckEquals(20.0, JuceScopeTimeFromValue(JuceScopeValueFromTime(20)), 1e-3, 'there and back');
    CheckEquals(0.0, JuceScopeValueFromTime(0.1), 0, 'below the range: 0');
    CheckEquals(1.0, JuceScopeValueFromTime(1000), 0, 'above: 1');
    CheckEquals(0.0, JuceScopeValueFromTime(NaNValue), 0, 'NaN: 0');
    CheckEquals(1.0, JuceScopeTimeFromValue(NaNValue), 1e-4, 'NaN value: 1 ms');
    CheckEquals('2.5 ms', StringReplace(JuceScopeTimeText(2.5), ',', '.', []), 'readout under 10 ms: one decimal');
    CheckEquals('40 ms', JuceScopeTimeText(40.2), 'readout from 10 ms: whole ms');
    { an unbound control starts at its DefaultValue (a form sets it), until set }
    with TJuceKnob.Create(nil) do
      try
        DefaultValue := 0.3;
        CheckEquals(0.3, Value, 1e-6, 'an unbound knob starts at its default');
        Value := 0.6;
        DefaultValue := 0.1;
        CheckEquals(0.6, Value, 1e-6, 'once set, a new default leaves the value alone');
        CheckEquals(0.1, DefaultValue, 1e-6, '(the default is still taken)');
      finally
        Free;
      end;
  finally
    S.Free;
  end;

  { the plug-in's output, end to end }
  ResetFake;
  Check(not P.ScopeActive, 'no scope open: nothing captured');
  E := OpenEditor;
  S := TJuceScope.Create(E.Root);
  S.SetBounds(10, 150, 200, 80);
  S.Channel := jscLeft;
  S.TimeMs := 2; { 96 samples at 48 kHz }
  Check(P.ScopeActive, 'a scope in an open editor turns capture on');
  SetLength(L, 512);
  SetLength(R, 512);
  for I := 0 to 511 do
  begin
    L[I] := 0.8 * Sin(2 * Pi * (I + 0.5) / 48);
    R[I] := -L[I];
  end;
  ProcessAudio(L, R, 512, 2);
  EdVT.Timer(Ed);
  CheckEquals(97, S.SampleCount, 'the output arrives in the scope');
  Check(S.Triggered and (S.Sample(0) < 0) and (S.Sample(1) >= 0), 'triggered on the left channel');
  { it reads the newest 2 * 96 + 2 samples (318..511); the latest rising crossing
    with 96 after it is at 384, so the sweep starts at 383 }
  CheckEquals(L[383 + 50], S.Sample(50), 1e-6, 'the left samples');
  S.Channel := jscRight;
  EdVT.Timer(Ed);
  CheckEquals(L[383 + 50], S.Sample(50), 1e-6, 'no new audio: the last sweep is held');
  ProcessAudio(L, R, 512, 2);
  EdVT.Timer(Ed);
  Check(S.Triggered and (S.Sample(0) < 0) and (S.Sample(1) >= 0), 'the right channel, triggered');
  S.Channel := jscMix;
  ProcessAudio(L, R, 512, 2);
  EdVT.Timer(Ed);
  CheckEquals(0.0, S.Sample(50), 1e-6, 'mix of +x and -x is silence');
  PaintOnce;

  { a mono output feeds both channels }
  S.Channel := jscRight;
  ProcessAudio(L, R, 512, 1);
  EdVT.Timer(Ed);
  Check(S.Triggered and (Abs(S.Sample(50) - L[383 + 50]) < 1e-6), 'mono: right = left');

  { ScopeRead directly: the newest samples, oldest first; a block bigger than the ring keeps the newest }
  SetLength(Got, 100);
  CheckEquals(100, E.ScopeRead(JUCE_SCOPE_LEFT, Got, 100, Stamp), 'ScopeRead returns what was asked');
  CheckEquals(L[511], Got[99], 1e-6, 'newest last');
  CheckEquals(L[412], Got[0], 1e-6, 'oldest first');
  SetLength(L, Big);
  SetLength(R, Big);
  for I := 0 to Big - 1 do
  begin
    L[I] := I / Big;
    R[I] := 0;
  end;
  ProcessAudio(L, R, Big, 2);
  CheckEquals(100, E.ScopeRead(JUCE_SCOPE_LEFT, Got, 100, Stamp2), 'after a huge block');
  Check(Stamp2 <> Stamp, 'the stamp moves with new audio');
  CheckEquals(L[Big - 1], Got[99], 1e-6, 'a huge block: its newest samples kept');
  CheckEquals(L[Big - 100], Got[0], 1e-6, '(in order)');
  N := E.ScopeRead(JUCE_SCOPE_LEFT, Got, JUCE_SCOPE_MAX_READ * 2, Stamp);
  CheckEquals(100, N, 'never more than Dest holds');

  { ScopeManual: the glue leaves the feed to Process }
  P.ScopeManual := True;
  ProcessAudio(L, R, 512, 2);
  E.ScopeRead(JUCE_SCOPE_LEFT, Got, 10, Stamp);
  CheckEquals(Stamp2, Stamp, 'manual: the output is not captured');
  P.ScopeWrite(PJuceSampleArray(@R[0]), nil, 10);
  E.ScopeRead(JUCE_SCOPE_LEFT, Got, 10, Stamp);
  Check(Stamp <> Stamp2, 'manual: ScopeWrite feeds it');
  CheckEquals(0.0, Got[9], 0, '(what was written)');
  P.ScopeManual := False;

  { closing: capture stops; a scope removed from the editor detaches once }
  S.Free;
  Check(not P.ScopeActive, 'the scope freed: capture off');
  S := TJuceScope.Create(E.Root);
  S.SetBounds(10, 150, 200, 80);
  Check(P.ScopeActive, 'a second scope on');
  CloseEditor;
  Check(not P.ScopeActive, 'editor closed: capture off');
end;

procedure TestManyEditors;
var
  I: Integer;
begin
  Suite('1000 editors');
  ResetFake;
  for I := 1 to 1000 do
  begin
    OpenEditor;
    if I mod 10 = 0 then
      PaintOnce;
    if I mod 50 = 0 then
      Drag(46, 58, 0, -10, 0);
    CloseEditor;
  end;
  CheckEquals(FE.ImagesCreated, FE.ImagesDestroyed, 'every image released');
  CheckEquals(FE.Begins, FE.Ends, 'gestures balanced');
  CheckEquals(0, FE.BadHandles, 'no stray handles');
  Check(True, '1000 editors created and freed (heaptrc reports any leak)');
end;

begin
  { The wrapper masks FP exceptions around every call into the library. }
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  NaNValue := NaN;
  PGain := JuceAddFloatParameter('gain', 'Gain', 0, 1, 0.5);
  PMode := JuceAddChoiceParameter('mode', 'Mode', ['A', 'B', 'C'], 0);
  POn := JuceAddBoolParameter('on', 'On', False);
  PCutoff := JuceAddFloatParameter('cutoff', 'Cutoff', 20, 20000, 1000, 'Hz');
  JuceRegisterPlugin(TUiPlugin, jkInstrument);

  FillChar(Factory, SizeOf(Factory), 0);
  Factory.StructSize := SizeOf(Factory);
  if pascaljuce_plugin_entry(JCP_ABI_VERSION, @Factory) <> 0 then
  begin
    WriteLn('entry point refused: ', JuceDeclarationError);
    Halt(1);
  end;
  FillChar(HostApi, SizeOf(HostApi), 0);
  HostApi.StructSize := SizeOf(HostApi);
  HostApi.AbiVersion := JCP_ABI_VERSION;
  FillChar(PlugVT, SizeOf(PlugVT), 0);
  PlugVT.StructSize := SizeOf(PlugVT);
  ResetFake;
  Inst := Factory.Create(@HostApi, nil, @PlugVT);
  if Inst = nil then
  begin
    WriteLn('no instance');
    Halt(1);
  end;

  TestLayout;
  TestCreation;
  TestPaint;
  TestKnob;
  TestOtherControls;
  TestHardwareControls;
  TestHoverMenusLifetime;
  TestTree;
  TestScalingLookLinks;
  TestScope;
  TestManyEditors;

  PlugVT.Destroy(Inst);
  FE.Tooltip := '';
  FE.LastMenuText := '';
  FE.LastText := '';
  FE.LastUrl := '';
  FE.LastLookFont := '';
  FE.LastFileTitle := '';
  FE.LastFilePatterns := '';
  FE.LastFileInitial := '';
  Halt(TestSummary);
end.
