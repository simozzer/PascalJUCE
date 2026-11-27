// Mz808 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// The panel: the Object Pascal counterpart of Source/PluginEditor.cpp, on PascalJUCE's
// controls. No LCL or VCL here: the panel is designed as a form (Mz808EditorForm.lfm, in
// Lazarus with Mz808Design.lpi, or Mz808EditorForm.dfm in Delphi), embedded in the library,
// and built from it at run time. This unit adds what a form cannot say:
//
//   - MIDI learn. Right-click a knob for its menu - the CC it answers to now, MIDI Learn
//     (or Cancel), Forget CC, Restore default, Reset all - as the C++ midiLearn menu.
//     While a knob waits for its CC it has a red outline and LEARN, and every knob's hover
//     hint names its CC as it is now.
//   - The pads play through the plug-in's queue, on the press as a drum should: plainly,
//     or accented with shift held or ACCENT lit. A pad lights whenever its sound is struck
//     - from the pad, the host or a controller - from the hit counts Process publishes.
//   - The panel scales as the C++ one does: half to twice its size, the aspect kept, a
//     corner to drag.
//
// Everything here runs on the message thread and reaches the audio thread only through
// TMz808's atomics (the CC map, the pad queue) and the host (parameters).
unit Mz808Editor;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ENDIF}

interface

uses
  JuceCanvas, JucePlugin, JuceUI, JuceControls, Tr808Engine, Mz808Params, Mz808Plugin;

const
  // How long a pad stays lit after a hit, as the C++ Pad::light.
  PadLightMs = 110;

type
  TMz808Editor = class(TJuceEditor)
  private
    FSpecControl: array[0..NumSpecs - 1] of TJuceControl;   // by index in Specs
    FMarker: TJuceControl;
    FAccentButton: TJuceButton;     // ACCENT: lit, the pads play accented
    FPad: array[0..VoiceCount - 1] of TJuceButton;          // by voice (Tr808Engine)
    FPadLed: array[0..VoiceCount - 1] of TJuceLed;
    FPadFace: array[0..VoiceCount - 1] of TJuceColor;       // as designed (unlit)
    FLitUntil: array[0..VoiceCount - 1] of Int64;           // ms; 0 = not lit
    FSeenHits: array[0..VoiceCount - 1] of Integer;         // -1: not seen yet
    FShiftDown: Boolean;            // shift was held at the last mouse press
    FMenuIndex: Integer;            // the control the open menu is for, -1 none
    FMenuLearning: Boolean;         // it was learning when the menu opened
    FSeenLearning, FSeenVersion: Integer;
    function Drums: TMz808;
    function SpecIndexOf(Control: TJuceControl): Integer;
    function PadVoice(Control: TObject): Integer;
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
    // A sound's pad and its light (Voice* of Tr808Engine), or nil.
    function Pad(Voice: Integer): TJuceButton;
    function PadLight(Voice: Integer): TJuceLed;
    // Whether a press on a pad now plays an accented hit (ACCENT lit).
    function AccentLit: Boolean;
    // The outline shown around a knob while it learns.
    property LearnMarker: TJuceControl read FMarker;
  end;

  // MIDI learn's red outline and LEARN: over the knob that waits for its CC, and its legend;
  // transparent to the mouse. Its timer tick polls the editor.
  TLearnMarker = class(TJuceControl)
  private
    FPanel: TMz808Editor;
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

  // The outline covers the knob and its legend beneath, as the C++ PanelKnob's bounds: the
  // knob (66 wide) is centred in a component 84 x 84.
  MarkerSide = 9;
  MarkerBelow = 18;

implementation

uses
  Classes, SysUtils, Math, JuceLayout;

// The designed panel, compiled into an RCDATA resource named after the form's class
// (TMZ808EDITORFORM).
{$IFDEF FPC}
  {$R Mz808EditorForm.lfm}
{$ELSE}
  {$R Mz808EditorForm.dfm}
{$ENDIF}

// Milliseconds from some fixed point.
function NowMs: Int64;
begin
  {$IFDEF FPC}
  Result := Int64(GetTickCount64);
  {$ELSE}
  Result := Int64(TThread.GetTickCount64);
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
  // midiLearn::drawLearning: a red outline, and LEARN along the top
  R := BoundsRect;
  Canvas.SetColor(Theme.Accent);
  Canvas.DrawRoundRect(JuceInset(R, 1), 4, 2);
  Canvas.SetFont(Theme.FontName, 9, [jfsBold]);
  Canvas.DrawText('LEARN', JuceRect(0, 0, R.W, 12), jaCenter, jvaCenter);
end;

{ TMz808Editor }

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

constructor TMz808Editor.Create(APlugin: TJucePlugin);
var
  I: Integer;
  C: TJuceControl;
begin
  inherited Create(APlugin);
  // Size, theme and every control come from the form.
  JuceLoadLayoutResource(Self, 'TMz808EditorForm');
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

  // The pads and their lights by the names given in the designer: Pad and Led, then the
  // code printed on the pad (PadBD, LedBD, ...).
  for I := 0 to VoiceCount - 1 do
  begin
    FSeenHits[I] := -1;
    C := FindControl('Pad' + VoiceInfo(I).Code);
    if C is TJuceButton then
    begin
      FPad[I] := TJuceButton(C);
      FPad[I].OnChange := PadChange;
      FPadFace[I] := FPad[I].FaceColor;
    end;
    C := FindControl('Led' + VoiceInfo(I).Code);
    if C is TJuceLed then
      FPadLed[I] := TJuceLed(C);
  end;
  C := FindControl('AccentButton');
  if C is TJuceButton then
    FAccentButton := TJuceButton(C);

  // On top of everything, hidden until a knob learns.
  FMarker := TLearnMarker.Create(Root);
  TLearnMarker(FMarker).FPanel := Self;
  FMarker.Visible := False;
end;

procedure TMz808Editor.Opened;
begin
  inherited Opened;
  Poll;
end;

// The shift key at each press, for the pads (a button's change event does not carry it).
procedure TMz808Editor.MouseEvent(const E: TJcpMouseEvent);
begin
  if E.Kind = JCP_MOUSE_DOWN then
    FShiftDown := E.Modifiers and JCP_MOD_SHIFT <> 0;
  inherited MouseEvent(E);
end;

function TMz808Editor.Drums: TMz808;
begin
  if Plugin is TMz808 then
    Result := TMz808(Plugin)
  else
    Result := nil;
end;

function TMz808Editor.SpecControl(Index: Integer): TJuceControl;
begin
  if (Index >= 0) and (Index < NumSpecs) then
    Result := FSpecControl[Index]
  else
    Result := nil;
end;

function TMz808Editor.Pad(Voice: Integer): TJuceButton;
begin
  if (Voice >= 0) and (Voice < VoiceCount) then
    Result := FPad[Voice]
  else
    Result := nil;
end;

function TMz808Editor.PadLight(Voice: Integer): TJuceLed;
begin
  if (Voice >= 0) and (Voice < VoiceCount) then
    Result := FPadLed[Voice]
  else
    Result := nil;
end;

function TMz808Editor.AccentLit: Boolean;
begin
  Result := (FAccentButton <> nil) and FAccentButton.IsOn;
end;

function TMz808Editor.SpecIndexOf(Control: TJuceControl): Integer;
var
  I: Integer;
begin
  for I := 0 to NumSpecs - 1 do
    if (Control <> nil) and (FSpecControl[I] = Control) then
      Exit(I);
  Result := -1;
end;

function TMz808Editor.PadVoice(Control: TObject): Integer;
var
  I: Integer;
begin
  for I := 0 to VoiceCount - 1 do
    if (Control <> nil) and (FPad[I] = Control) then
      Exit(I);
  Result := -1;
end;

// A pad pressed (its momentary value up): the C++ Pad::mouseDown and Panel::pad's strike.
procedure TMz808Editor.PadChange(Sender: TObject);
var
  V: Integer;
begin
  V := PadVoice(Sender);
  if (V < 0) or (Drums = nil) or (FPad[V].Value < 0.5) then
    Exit;
  Drums.Strike(V, FShiftDown or AccentLit);
end;

procedure TMz808Editor.Poll;
begin
  if Drums = nil then
    Exit;
  UpdateLearning;
  UpdateLights;
end;

// A knob learning, or a CC changing (which may come from the audio thread): the hints
// say so, and the outline moves.
procedure TMz808Editor.UpdateLearning;
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
    FMarker.SetBounds(Round(T.AbsoluteX) - MarkerSide, Round(T.AbsoluteY), T.Width + 2 * MarkerSide,
      T.Height + MarkerBelow);
    FMarker.Visible := True;
    FMarker.Invalidate;
  end
  else
    FMarker.Visible := False;
end;

// The C++ Panel::timerCallback: a sound struck since the last look lights its pad, for
// PadLightMs. The first look only notes the counts, so opening the panel does not flash.
procedure TMz808Editor.UpdateLights;
var
  V, H: Integer;
  Now_: Int64;
  Lit: Boolean;
begin
  Now_ := NowMs;
  for V := 0 to VoiceCount - 1 do
  begin
    H := MeterInt(MeterHits + V);
    if H <> FSeenHits[V] then
    begin
      if FSeenHits[V] >= 0 then
        FLitUntil[V] := Now_ + PadLightMs;
      FSeenHits[V] := H;
    end;
    Lit := (FLitUntil[V] <> 0) and (Now_ < FLitUntil[V]);
    if not Lit then
      FLitUntil[V] := 0;
    if (FPadLed[V] <> nil) and (FPadLed[V].Lit <> Lit) then
    begin
      FPadLed[V].Lit := Lit;
      // the key brightens with its light, as the C++ pad's
      if FPad[V] <> nil then
      begin
        if Lit then
          FPad[V].FaceColor := JuceBrighter(FPadFace[V], 0.3)
        else
          FPad[V].FaceColor := FPadFace[V];
        FPad[V].Invalidate;
      end;
    end;
  end;
end;

// The C++ midiLearn::showMenu. The answer comes later, in MenuChosen.
procedure TMz808Editor.ControlMenu(Sender: TJuceControl; X, Y: Single; var Handled: Boolean);
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

procedure TMz808Editor.MenuChosen(Sender: TJuceEditor; MenuId, ItemId: Integer);
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

function TMz808Editor.MeterInt(Index: Integer): Integer;
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
