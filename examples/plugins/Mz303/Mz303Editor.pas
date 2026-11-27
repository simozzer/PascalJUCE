// Mz303 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// The panel: the Object Pascal counterpart of source/PluginEditor.cpp, on PascalJUCE's
// controls. No LCL or VCL here: the panel is designed as a form (Mz303EditorForm.lfm, in
// Lazarus with Mz303Design.lpi, or Mz303EditorForm.dfm in Delphi), embedded in the library,
// and built from it at run time. This unit adds what a form cannot say:
//
//   - MIDI learn. Right-click a control for its menu - the CC it answers to now, MIDI
//     Learn (or Cancel), Forget CC, Restore default, Reset all - as the C++ midiLearn
//     menu. While a control waits for its CC it has a red outline and LEARN, and every
//     control's hover hint names its CC as it is now.
//   - The keyboard plays through the plug-in's key queue, at a plain velocity or, with
//     ACCENT latched beside it, an accented one; and it lights the keys held, from the
//     host as well.
//   - The panel scales as the C++ one does: half to twice its size, the aspect kept, a
//     corner to drag.
//
// The ACCENT and SLIDE lights are LEDs in the form, lit by the meters Process publishes.
// Everything here runs on the message thread and reaches the audio thread only through
// TMz303's atomics (the CC map, the key queue) and the host (parameters).
unit Mz303Editor;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ENDIF}

interface

uses
  JuceCanvas, JucePlugin, JuceUI, JuceControls, Mz303Params, Mz303Plugin;

type
  TMz303Editor = class(TJuceEditor)
  private
    FSpecControl: array[0..NumSpecs - 1] of TJuceControl;   // by index in Specs
    FMarker: TJuceControl;
    FKeyboard: TJuceKeyboard;
    FAccentKeys: TJuceButton;       // ACCENT beside the keys: latched, the keys play accented
    FMenuIndex: Integer;            // the control the open menu is for, -1 none
    FMenuLearning: Boolean;         // it was learning when the menu opened
    FSeenLearning, FSeenVersion: Integer;
    FKeysShown: array[0..NumKeyMeters - 1] of Integer;
    function Synth: TMz303;
    function SpecIndexOf(Control: TJuceControl): Integer;
    procedure ControlMenu(Sender: TJuceControl; X, Y: Single; var Handled: Boolean);
    procedure MenuChosen(Sender: TJuceEditor; MenuId, ItemId: Integer);
    procedure KeyDown(Sender: TJuceControl; Note: Integer; Velocity: Single);
    procedure KeyUp(Sender: TJuceControl; Note: Integer; Velocity: Single);
    function MeterInt(Index: Integer): Integer;
    procedure PredictKey(Note: Integer; Down: Boolean);
    procedure UpdateLearning;
    procedure UpdateKeys;
  protected
    procedure Opened; override;
  public
    constructor Create(APlugin: TJucePlugin); override;
    // Every timer tick (and after a menu choice): learning, hints, the keys.
    procedure Poll;
    // The control of a panel parameter (index in Specs), or nil.
    function SpecControl(Index: Integer): TJuceControl;
    // The velocity the on-screen keys play at now.
    function KeyVelocity: Integer;
    // The outline shown around a control while it learns.
    property LearnMarker: TJuceControl read FMarker;
  end;

  // MIDI learn's red outline and LEARN: over the control that waits for its CC;
  // transparent to the mouse. Its timer tick polls the editor.
  TLearnMarker = class(TJuceControl)
  private
    FPanel: TMz303Editor;
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

implementation

uses
  Classes, SysUtils, Math, JuceLayout;

// The designed panel, compiled into an RCDATA resource named after the form's class
// (TMZ303EDITORFORM).
{$IFDEF FPC}
  {$R Mz303EditorForm.lfm}
{$ELSE}
  {$R Mz303EditorForm.dfm}
{$ENDIF}

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
  R := BoundsRect;
  Canvas.SetColor(Theme.Accent);
  Canvas.DrawRoundRect(JuceInset(R, 1), 4, 2);
  Canvas.SetFont(Theme.FontName, 9, [jfsBold]);
  Canvas.DrawText('LEARN', JuceRect(0, R.H - 12, R.W, 12), jaCenter, jvaCenter);
end;

{ TMz303Editor }

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

constructor TMz303Editor.Create(APlugin: TJucePlugin);
var
  I: Integer;
  C: TJuceControl;
begin
  inherited Create(APlugin);
  // Size, theme and every control come from the form.
  JuceLoadLayoutResource(Self, 'TMz303EditorForm');
  // As the C++ editor: the panel at its design size, scaled from half to twice that, the
  // aspect ratio kept, with a resize handle in the corner.
  SetScalable(0.5, 2.0, True);

  FMenuIndex := -1;
  FSeenLearning := -2;
  FSeenVersion := -1;
  for I := 0 to High(FKeysShown) do
    FKeysShown[I] := -1;

  // Every panel parameter's control has the MIDI learn menu (the C++ PanelControl); they
  // are found by the parameter they are bound to.
  for I := 0 to NumSpecs - 1 do
  begin
    FSpecControl[I] := FindBound(Root, Specs[I].Id);
    if FSpecControl[I] <> nil then
      FSpecControl[I].OnContextMenu := ControlMenu;
  end;

  // The rest by the names given in the designer.
  C := FindControl('AccentKeys');
  if C is TJuceButton then
    FAccentKeys := TJuceButton(C);
  C := FindControl('Keyboard');
  if C is TJuceKeyboard then
  begin
    FKeyboard := TJuceKeyboard(C);
    FKeyboard.OnNoteOn := KeyDown;
    FKeyboard.OnNoteOff := KeyUp;
  end;

  // On top of everything, hidden until a control learns.
  FMarker := TLearnMarker.Create(Root);
  TLearnMarker(FMarker).FPanel := Self;
  FMarker.Visible := False;
end;

procedure TMz303Editor.Opened;
begin
  inherited Opened;
  Poll;
end;

function TMz303Editor.Synth: TMz303;
begin
  if Plugin is TMz303 then
    Result := TMz303(Plugin)
  else
    Result := nil;
end;

function TMz303Editor.SpecControl(Index: Integer): TJuceControl;
begin
  if (Index >= 0) and (Index < NumSpecs) then
    Result := FSpecControl[Index]
  else
    Result := nil;
end;

function TMz303Editor.SpecIndexOf(Control: TJuceControl): Integer;
var
  I: Integer;
begin
  for I := 0 to NumSpecs - 1 do
    if (Control <> nil) and (FSpecControl[I] = Control) then
      Exit(I);
  Result := -1;
end;

function TMz303Editor.KeyVelocity: Integer;
begin
  if (FAccentKeys <> nil) and FAccentKeys.IsOn then
    Result := PanelAccentVelocity
  else
    Result := PanelVelocity;
end;

procedure TMz303Editor.Poll;
begin
  if Synth = nil then
    Exit;
  UpdateLearning;
  UpdateKeys;
end;

// A control learning, or a CC changing (which may come from the audio thread): the hints
// say so, and the outline moves.
procedure TMz303Editor.UpdateLearning;
var
  L, V, I: Integer;
  T: TJuceControl;
begin
  L := Synth.LearningIndex;
  V := Synth.MidiMapVersion;
  if (L = FSeenLearning) and (V = FSeenVersion) then
    Exit;
  FSeenLearning := L;
  FSeenVersion := V;
  for I := 0 to NumSpecs - 1 do
    if FSpecControl[I] <> nil then
      FSpecControl[I].Hint := HintFor(I, Synth.CcFor(I), L = I);
  T := SpecControl(L);
  if T <> nil then
  begin
    FMarker.SetBounds(Round(T.AbsoluteX), Round(T.AbsoluteY), T.Width, T.Height);
    FMarker.Visible := True;
    FMarker.Invalidate;
  end
  else
    FMarker.Visible := False;
end;

// The keys held, from the host and from this keyboard, as Process last saw them.
procedure TMz303Editor.UpdateKeys;
var
  Slot, Bits, B: Integer;
begin
  if FKeyboard = nil then
    Exit;
  for Slot := 0 to NumKeyMeters - 1 do
  begin
    Bits := MeterInt(MeterKeysHeld + Slot);
    if Bits = FKeysShown[Slot] then
      Continue;
    FKeysShown[Slot] := Bits;
    for B := 0 to 15 do
      FKeyboard.SetNoteLit(Slot * 16 + B, (Bits shr B) and 1 <> 0);
  end;
end;

// The C++ midiLearn::showMenu. The answer comes later, in MenuChosen.
procedure TMz303Editor.ControlMenu(Sender: TJuceControl; X, Y: Single; var Handled: Boolean);
var
  I, Cc, Def: Integer;
  Head, LearnText: string;
  ForgetFlags, RestoreFlags: Integer;
begin
  I := SpecIndexOf(Sender);
  if (I < 0) or (Synth = nil) then
    Exit;
  Handled := True;
  Cc := Synth.CcFor(I);
  Def := Specs[I].Cc;
  FMenuLearning := Synth.LearningIndex = I;
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

procedure TMz303Editor.MenuChosen(Sender: TJuceEditor; MenuId, ItemId: Integer);
var
  I: Integer;
begin
  I := FMenuIndex;
  FMenuIndex := -1;
  if (I < 0) or (Synth = nil) then
    Exit;
  case ItemId of
    MenuLearn:
      if FMenuLearning then
        Synth.Learn(-1)
      else
        Synth.Learn(I);
    MenuForget:
      Synth.ForgetCc(I);
    MenuRestore:
      Synth.RestoreDefaultCc(I);
    MenuResetAll:
      Synth.ResetAllCcs;
  end;
  Poll;
end;

function TMz303Editor.MeterInt(Index: Integer): Integer;
var
  V: Single;
begin
  V := Meter(Index);
  if IsNan(V) then
    Result := 0
  else
    Result := Round(Max(-1.0e6, Min(V, 1.0e6)));
end;

// A key reaches the engine with the next audio block, and lights once that block has
// published its meters. So that the keyboard answers at once - also while the host is not
// playing audio - the key is predicted lit (or not) until then.
procedure TMz303Editor.PredictKey(Note: Integer; Down: Boolean);
var
  Slot, Bits: Integer;
begin
  if (Note < 0) or (Note > 127) then
    Exit;
  Slot := Note shr 4;
  Bits := MeterInt(MeterKeysHeld + Slot);
  if Down then
    Bits := Bits or (1 shl (Note and 15))
  else
    Bits := Bits and not (1 shl (Note and 15));
  PredictMeter(MeterKeysHeld + Slot, Bits);
end;

procedure TMz303Editor.KeyDown(Sender: TJuceControl; Note: Integer; Velocity: Single);
begin
  if (Synth <> nil) and Synth.QueueKey(Note, KeyVelocity) then
  begin
    PredictKey(Note, True);
    Poll;
  end;
end;

procedure TMz303Editor.KeyUp(Sender: TJuceControl; Note: Integer; Velocity: Single);
begin
  if (Synth <> nil) and Synth.QueueKey(Note, 0) then
  begin
    PredictKey(Note, False);
    Poll;
  end;
end;

end.
