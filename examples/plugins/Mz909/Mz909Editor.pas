// Mz909 - an emulation of the TR-909 Rhythm Composer
// Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// The panel: the Object Pascal counterpart of Source/PluginEditor.cpp, on PascalJUCE's
// controls. No LCL or VCL here: the panel is designed as a form (Mz909EditorForm.lfm, in
// Lazarus with Mz909Design.lpi, or Mz909EditorForm.dfm in Delphi), embedded in the library,
// and built from it at run time. This unit adds what a form cannot say:
//
//   - MIDI learn. Right-click a knob for its menu - the CC it answers to now, MIDI Learn
//     (or Cancel), Forget CC, Restore default, Reset all - as the C++ midiLearn menu.
//     While a knob waits for its CC it has a red outline and LEARN, round the knob and its
//     legend as the C++ PanelKnob, and every knob's hover hint names its CC as it is now.
//   - The pads. Each plays its sound on the press, as a drum should, not the release:
//     accented with shift held or with ACCENT lit (the button in the ACCENT column), as the
//     C++ Pad. Each pad's light comes on for 110 ms whenever its sound is struck - from the
//     pad, the host or a controller - from the hit counts Process publishes as meters.
//   - The panel scales as the C++ one does: half to twice its size, the aspect kept, a
//     corner to drag.
//
// Everything here runs on the message thread and reaches the audio thread only through
// TMz909's atomics (the CC map, the pad queue) and the host (parameters).
unit Mz909Editor;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ENDIF}

interface

uses
  JuceCanvas, JucePlugin, JuceUI, JuceControls, Tr909Engine, Mz909Params, Mz909Plugin;

const
  // How long a pad stays lit after a hit (the C++ Pad::light).
  PadLightMs = 110;

type
  TMz909Editor = class(TJuceEditor)
  private
    FSpecControl: array[0..NumSpecs - 1] of TJuceControl;   // by index in Specs
    FPads: array[0..VoiceCount - 1] of TJuceButton;         // by voice (VoiceBD ..)
    FPadLeds: array[0..VoiceCount - 1] of TJuceLed;
    FLitUntil: array[0..VoiceCount - 1] of Int64;           // milliseconds
    FSeenHits: array[0..VoiceCount - 1] of Integer;         // -1: not read yet
    FMarker: TJuceControl;
    FAccent: TJuceButton;           // ACCENT lit: the pads play accented
    FShiftDown: Boolean;            // shift was held for the last mouse press
    FMenuIndex: Integer;            // the control the open menu is for, -1 none
    FMenuLearning: Boolean;         // it was learning when the menu opened
    FSeenLearning, FSeenVersion: Integer;
    function Drums: TMz909;
    function SpecIndexOf(Control: TJuceControl): Integer;
    procedure ControlMenu(Sender: TJuceControl; X, Y: Single; var Handled: Boolean);
    procedure MenuChosen(Sender: TJuceEditor; MenuId, ItemId: Integer);
    procedure PadChange(Sender: TObject);
    function MeterInt(Index: Integer): Integer;
    procedure UpdateLearning;
    procedure UpdateLights;
  protected
    procedure Opened; override;
    procedure MouseEvent(const E: TJcpMouseEvent); override;
  public
    constructor Create(APlugin: TJucePlugin); override;
    // Every timer tick (and after a menu choice): learning, hints, the pads' lights.
    procedure Poll;
    // The control of a panel parameter (index in Specs), or nil.
    function SpecControl(Index: Integer): TJuceControl;
    // A sound's pad (VoiceBD ..), and its light; nil if the layout has none.
    function Pad(Voice: Integer): TJuceButton;
    function PadLed(Voice: Integer): TJuceLed;
    // Whether the pads play accented now (ACCENT lit).
    function AccentLit: Boolean;
    // The outline shown around a knob while it learns.
    property LearnMarker: TJuceControl read FMarker;
  end;

  // MIDI learn's red outline and LEARN: over the knob that waits for its CC;
  // transparent to the mouse. Its timer tick polls the editor.
  TLearnMarker = class(TJuceControl)
  private
    FPanel: TMz909Editor;
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
    function NeedsTimer: Boolean; override;
    procedure Tick; override;
  public
    function HitTest(X, Y: Single): Boolean; override;
  end;

const
  // The right-click menu's items.
  MenuLearn = 1;
  MenuForget = 2;
  MenuRestore = 3;
  MenuResetAll = 4;

  // The knob's part of the C++ PanelKnob: the knob is 66 px wide, centred in the 84 px
  // component, with its 18 px legend beneath. The outline goes round all of it.
  KnobInsetX = 9;
  LegendHeight = 18;

implementation

uses
  Classes, SysUtils, Math, JuceLayout;

// The designed panel, compiled into an RCDATA resource named after the form's class
// (TMZ909EDITORFORM).
{$IFDEF FPC}
  {$R Mz909EditorForm.lfm}
{$ELSE}
  {$R Mz909EditorForm.dfm}
{$ENDIF}

// The pads in the form, by voice: PadBD .. PadRC, their lights LedBD .. LedRC.
const
  PadNames: array[0..VoiceCount - 1] of string = (
    'BD', 'SD', 'LT', 'MT', 'HT', 'RS', 'CP', 'CH', 'OH', 'CC', 'RC');

function Milliseconds: Int64;
begin
  {$IFDEF FPC}
  Result := GetTickCount64;
  {$ELSE}
  Result := TThread.GetTickCount64;
  {$ENDIF}
end;

{ TLearnMarker }

function TLearnMarker.HitTest(X, Y: Single): Boolean;
begin
  Result := False;
end;

function TLearnMarker.NeedsTimer: Boolean;
begin
  Result := True;
end;

procedure TLearnMarker.Tick;
begin
  if FPanel <> nil then
    FPanel.Poll;
end;

procedure TLearnMarker.Paint(Canvas: TJuceCanvas);
var
  R: TJuceRect;
begin
  // midiLearn::drawLearning: a red outline, LEARN along the top
  R := BoundsRect;
  Canvas.SetColor(Theme.Accent);
  Canvas.DrawRoundRect(JuceInset(R, 1), 4, 2);
  Canvas.SetFont(Theme.FontName, 9, [jfsBold]);
  Canvas.DrawText('LEARN', JuceRect(0, 0, R.W, 12), jaCenter, jvaCenter);
end;

{ TMz909Editor }

// The bound control of a parameter id below Parent.
function FindBound(Parent: TJuceControl; const Id: string): TJuceControl;
var
  I: Integer;
  C: TJuceControl;
begin
  Result := nil;
  for I := 0 to Parent.ControlCount - 1 do
  begin
    C := Parent.Controls[I];
    if (C is TJuceParamControl) and (TJuceParamControl(C).ParameterId = Id) then
      Exit(C);
    Result := FindBound(C, Id);
    if Result <> nil then
      Exit;
  end;
end;

constructor TMz909Editor.Create(APlugin: TJucePlugin);
var
  I: Integer;
  C: TJuceControl;
begin
  inherited Create(APlugin);
  // Size, theme and every control come from the form.
  JuceLoadLayoutResource(Self, 'TMz909EditorForm');
  // As the C++ editor: the panel at its design size, scaled from half to twice that, the
  // aspect ratio kept, with a resize handle in the corner.
  SetScalable(0.5, 2.0, True);

  FMenuIndex := -1;
  FSeenLearning := -2;
  FSeenVersion := -1;

  // Every knob has the MIDI learn menu (the C++ PanelKnob); they are found by the
  // parameter they are bound to.
  for I := 0 to NumSpecs - 1 do
  begin
    FSpecControl[I] := FindBound(Root, Specs[I].Id);
    if FSpecControl[I] <> nil then
      FSpecControl[I].OnContextMenu := ControlMenu;
  end;

  // The rest by the names given in the designer.
  C := FindControl('AccentButton');
  if C is TJuceButton then
    FAccent := TJuceButton(C);
  for I := 0 to VoiceCount - 1 do
  begin
    FSeenHits[I] := -1;
    FLitUntil[I] := 0;
    C := FindControl('Pad' + PadNames[I]);
    if C is TJuceButton then
    begin
      FPads[I] := TJuceButton(C);
      FPads[I].OnChange := PadChange;
    end;
    C := FindControl('Led' + PadNames[I]);
    if C is TJuceLed then
      FPadLeds[I] := TJuceLed(C);
  end;

  // On top of everything, hidden until a knob learns.
  FMarker := TLearnMarker.Create(Root);
  TLearnMarker(FMarker).FPanel := Self;
  FMarker.Visible := False;
end;

procedure TMz909Editor.Opened;
begin
  inherited Opened;
  Poll;
end;

procedure TMz909Editor.MouseEvent(const E: TJcpMouseEvent);
var
  Hit: TJuceControl;
  V: Integer;
begin
  // A pad reads shift from here: its press arrives as a value change, without the keys.
  if E.Kind = JCP_MOUSE_DOWN then
  begin
    FShiftDown := (E.Modifiers and JCP_MOD_SHIFT) <> 0;
    // The light above a key is part of its pad, as in the C++ Pad: a press on it plays too.
    if (E.Modifiers and JCP_MOD_POPUP = 0) and (E.Modifiers and JCP_MOD_LEFT <> 0) and (Drums <> nil) then
    begin
      Hit := Root.ControlAt(E.X, E.Y);
      for V := 0 to VoiceCount - 1 do
        if (Hit <> nil) and (Hit = FPadLeds[V]) then
        begin
          Drums.Strike(V, FShiftDown or AccentLit);
          Exit;
        end;
    end;
  end;
  inherited MouseEvent(E);
end;

function TMz909Editor.Drums: TMz909;
begin
  if Plugin is TMz909 then
    Result := TMz909(Plugin)
  else
    Result := nil;
end;

function TMz909Editor.SpecControl(Index: Integer): TJuceControl;
begin
  if (Index >= 0) and (Index < NumSpecs) then
    Result := FSpecControl[Index]
  else
    Result := nil;
end;

function TMz909Editor.Pad(Voice: Integer): TJuceButton;
begin
  if (Voice >= 0) and (Voice < VoiceCount) then
    Result := FPads[Voice]
  else
    Result := nil;
end;

function TMz909Editor.PadLed(Voice: Integer): TJuceLed;
begin
  if (Voice >= 0) and (Voice < VoiceCount) then
    Result := FPadLeds[Voice]
  else
    Result := nil;
end;

function TMz909Editor.SpecIndexOf(Control: TJuceControl): Integer;
var
  I: Integer;
begin
  for I := 0 to NumSpecs - 1 do
    if (Control <> nil) and (FSpecControl[I] = Control) then
      Exit(I);
  Result := -1;
end;

function TMz909Editor.AccentLit: Boolean;
begin
  Result := (FAccent <> nil) and FAccent.IsOn;
end;

// A pad pressed (its momentary value going to 1): strike its sound, accented with shift or
// ACCENT. The release (the value going back to 0) does nothing.
procedure TMz909Editor.PadChange(Sender: TObject);
var
  V: Integer;
begin
  if (Drums = nil) or not (Sender is TJuceButton) or (TJuceButton(Sender).Value < 0.5) then
    Exit;
  for V := 0 to VoiceCount - 1 do
    if FPads[V] = Sender then
    begin
      Drums.Strike(V, FShiftDown or AccentLit);
      Exit;
    end;
end;

procedure TMz909Editor.Poll;
begin
  if Drums = nil then
    Exit;
  UpdateLearning;
  UpdateLights;
end;

// A knob learning, or a CC changing (which may come from the audio thread): the hints
// say so, and the outline moves.
procedure TMz909Editor.UpdateLearning;
var
  L, V, I: Integer;
  T: TJuceControl;
begin
  L := Drums.LearningIndex;
  V := Drums.MidiMapVersion;
  if (L = FSeenLearning) and (V = FSeenVersion) then
    Exit;
  FSeenLearning := L;
  FSeenVersion := V;
  for I := 0 to NumSpecs - 1 do
    if FSpecControl[I] <> nil then
      FSpecControl[I].Hint := HintFor(I, Drums.CcFor(I), L = I);
  T := SpecControl(L);
  if T <> nil then
  begin
    FMarker.SetBounds(Round(T.AbsoluteX) - KnobInsetX, Round(T.AbsoluteY), T.Width + 2 * KnobInsetX,
      T.Height + LegendHeight);
    FMarker.Visible := True;
    FMarker.Invalidate;
  end
  else
    FMarker.Visible := False;
end;

// The pads' lights: each comes on when its sound's hit count changes, and goes out
// PadLightMs later.
procedure TMz909Editor.UpdateLights;
var
  V, H: Integer;
  Now_: Int64;
begin
  Now_ := Milliseconds;
  for V := 0 to VoiceCount - 1 do
  begin
    H := MeterInt(MeterHits + V);
    if FSeenHits[V] < 0 then
      FSeenHits[V] := H   // from where the engine is, so opening the panel does not flash
    else if H <> FSeenHits[V] then
    begin
      FSeenHits[V] := H;
      FLitUntil[V] := Now_ + PadLightMs;
    end;
    if FPadLeds[V] <> nil then
      FPadLeds[V].Lit := Now_ < FLitUntil[V];
  end;
end;

// The C++ midiLearn::showMenu. The answer comes later, in MenuChosen.
procedure TMz909Editor.ControlMenu(Sender: TJuceControl; X, Y: Single; var Handled: Boolean);
var
  I, Cc, Def: Integer;
  Head, LearnText: string;
  ForgetFlags, RestoreFlags: Integer;
begin
  I := SpecIndexOf(Sender);
  if (I < 0) or (Drums = nil) then
    Exit;
  Handled := True;
  Cc := Drums.CcFor(I);
  Def := Specs[I].Cc;
  FMenuLearning := Drums.LearningIndex = I;
  if Cc >= 0 then
    Head := Specs[I].Name + '  -  CC ' + IntToStr(Cc)
  else
    Head := Specs[I].Name + '  -  no CC';
  if FMenuLearning then
    LearnText := 'Cancel MIDI Learn'
  else
    LearnText := 'MIDI Learn';
  ForgetFlags := 0;
  if Cc < 0 then
    ForgetFlags := JCP_MENU_DISABLED;
  RestoreFlags := 0;
  if Cc = Def then
    RestoreFlags := JCP_MENU_DISABLED;
  if PopupMenu([JuceMenuItem(100, Head, JCP_MENU_HEADER),
                JuceMenuItem(MenuLearn, LearnText),
                JuceMenuItem(MenuForget, 'Forget CC', ForgetFlags),
                JuceMenuItem(MenuRestore, 'Restore default (CC ' + IntToStr(Def) + ')', RestoreFlags),
                JuceMenuItem(101, '', JCP_MENU_SEPARATOR),
                JuceMenuItem(MenuResetAll, 'Reset all CCs to defaults')],
               Sender.AbsoluteX + X, Sender.AbsoluteY + Y, MenuChosen) <> 0 then
    FMenuIndex := I;
end;

procedure TMz909Editor.MenuChosen(Sender: TJuceEditor; MenuId, ItemId: Integer);
var
  I: Integer;
begin
  I := FMenuIndex;
  FMenuIndex := -1;
  if (I < 0) or (Drums = nil) then
    Exit;
  case ItemId of
    MenuLearn:
      if FMenuLearning then
        Drums.Learn(-1)
      else
        Drums.Learn(I);
    MenuForget:
      Drums.ForgetCc(I);
    MenuRestore:
      Drums.RestoreDefaultCc(I);
    MenuResetAll:
      Drums.ResetAllCcs;
  end;
  Poll;
end;

function TMz909Editor.MeterInt(Index: Integer): Integer;
var
  V: Single;
begin
  V := Meter(Index);
  if IsNan(V) then
    Result := 0
  else
    Result := Round(Max(-1.0e8, Min(V, 1.0e8)));
end;

end.
