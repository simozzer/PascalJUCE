// Mz101 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// The panel: the Object Pascal counterpart of Source/PluginEditor.cpp, on PascalJUCE's
// controls. No LCL or VCL here: the panel is designed as a form (Mz101EditorForm.lfm, in
// Lazarus with Mz101Design.lpi), embedded in the library, and built from it at run time.
// This unit adds what a form cannot say:
//
//   - MIDI learn. Right-click a control for its menu - the CC it answers to now, MIDI
//     Learn (or Cancel), Forget CC, Restore default, Reset all - as the C++ midiLearn
//     menu. While a control waits for its CC it has a red outline and LEARN, and every
//     control's hover hint names its CC as it is now.
//   - KEY TRANSPOSE (REST in LOAD) and LEGATO press the engine's buttons, and their LEDs
//     show what the engine is waiting for (meters published from Process).
//   - The step readout: "12/100" while loading, the step playing while it plays.
//   - The keyboard plays through the plug-in's key queue, and lights the keys held,
//     from the host as well.
//   - The panel scales as the C++ one does (half to twice its size, aspect kept, a corner
//     to drag), RATE reads as a note length while SYNC is on HOST, and the buttons and
//     keys predict the engine's answer (PredictMeter) so that the LEDs and the readout
//     follow at once, also while the host plays no audio. The faders' click-to-jump and
//     value bubble, the project link and the tooltip / menu colours are in the form.
//
// Everything here runs on the message thread and reaches the audio thread only through
// TMz101's atomics (the CC map, the presses, the key queue) and the host (parameters).
unit Mz101Editor;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ENDIF}

interface

uses
  JuceCanvas, JucePlugin, JuceUI, JuceControls, Mz101Params, Mz101Plugin;

type
  TMz101Editor = class(TJuceEditor)
  private
    FSpecControl: array[0..NumSpecs - 1] of TJuceControl;   // by index in Specs
    FMarker: TJuceControl;
    FReadout: TJuceControl;
    FKeyboard: TJuceKeyboard;
    FSeqMode: Integer;              // the seqMode parameter's index
    FLfoSync: Integer;              // the lfoSync parameter's index
    FMenuIndex: Integer;            // the control the open menu is for, -1 none
    FMenuLearning: Boolean;         // it was learning when the menu opened
    FSeenLearning, FSeenVersion: Integer;
    FKeysShown: array[0..NumKeyMeters - 1] of Integer;
    function Synth: TMz101;
    function SpecIndexOf(Control: TJuceControl): Integer;
    procedure ControlMenu(Sender: TJuceControl; X, Y: Single; var Handled: Boolean);
    procedure MenuChosen(Sender: TJuceEditor; MenuId, ItemId: Integer);
    procedure TransposeClick(Sender: TObject);
    procedure LegatoClick(Sender: TObject);
    procedure KeyDown(Sender: TJuceControl; Note: Integer; Velocity: Single);
    procedure KeyUp(Sender: TJuceControl; Note: Integer; Velocity: Single);
    procedure RateText(Sender: TJuceParamControl; Normalised: Single; var Text: string);
    function SeqModeNow: Integer;
    // A meter as a whole number (clamped: a meter is any float).
    function MeterInt(Index: Integer): Integer;
    procedure PredictKey(Note: Integer; Down: Boolean);
    procedure UpdateLearning;
    procedure UpdateReadout;
    procedure UpdateKeys;
  protected
    procedure Opened; override;
  public
    constructor Create(APlugin: TJucePlugin); override;
    // Every timer tick (and after a menu choice): learning, hints, the readout, the keys.
    procedure Poll;
    // The control of a panel parameter (index in Specs), or nil.
    function SpecControl(Index: Integer): TJuceControl;
    // The outline shown around a control while it learns.
    property LearnMarker: TJuceControl read FMarker;
  end;

  // MIDI learn's red outline (and LEARN, for a fader or switch): over the control that
  // waits for its CC; transparent to the mouse. Its timer tick polls the editor.
  TLearnMarker = class(TJuceControl)
  private
    FPanel: TMz101Editor;
    FAroundButton: Boolean;
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
  SysUtils, Math, JuceLayout, Sh101Settings, Sh101Engine, Sh101Sync;

// The designed panel, compiled into an RCDATA resource named after the form's class
// (TMZ101EDITORFORM).
{$IFDEF FPC}
  {$R Mz101EditorForm.lfm}
{$ELSE}
  {$R Mz101EditorForm.dfm}
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
  if FAroundButton then
    Canvas.DrawRoundRect(JuceInset(R, 1), 3, 2)
  else
  begin
    Canvas.DrawRoundRect(JuceInset(R, 1), 4, 2);
    Canvas.SetFont(Theme.FontName, 9, [jfsBold]);
    Canvas.DrawText('LEARN', JuceRect(0, R.H - 12, R.W, 12), jaCenter, jvaCenter);
  end;
end;

{ TMz101Editor }

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

constructor TMz101Editor.Create(APlugin: TJucePlugin);
var
  I: Integer;
  C: TJuceControl;
begin
  inherited Create(APlugin);
  // Size, theme and every control come from the form.
  JuceLoadLayoutResource(Self, 'TMz101EditorForm');
  // As the C++ editor: the panel at its design size, scaled from half to twice that, the
  // aspect ratio kept, with a resize handle in the corner.
  SetScalable(0.5, 2.0, True);

  FMenuIndex := -1;
  FSeqMode := -1;
  FLfoSync := -1;
  FSeenLearning := -2;
  FSeenVersion := -1;
  for I := 0 to High(FKeysShown) do
    FKeysShown[I] := -1;

  // Every panel parameter's control has the MIDI learn menu (the C++ PanelControl and
  // LearnButton); they are found by the parameter they are bound to.
  for I := 0 to NumSpecs - 1 do
  begin
    FSpecControl[I] := FindBound(Root, Specs[I].Id);
    if FSpecControl[I] <> nil then
      FSpecControl[I].OnContextMenu := ControlMenu;
  end;

  // The rest by the names given in the designer.
  C := FindControl('TransRest');
  if C is TJuceButton then
    TJuceButton(C).OnClick := TransposeClick;
  C := FindControl('Legato');
  if C is TJuceButton then
    TJuceButton(C).OnClick := LegatoClick;
  // RATE reads as a note length while SYNC is on HOST (the C++ textFromValueFunction).
  C := FindControl('LfoRate');
  if C is TJuceParamControl then
    TJuceParamControl(C).OnValueText := RateText;
  FReadout := FindControl('StepReadout');
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

procedure TMz101Editor.Opened;
begin
  inherited Opened;
  FSeqMode := FindParameter(Specs[PSeqMode].Id);
  FLfoSync := FindParameter(Specs[PLfoSync].Id);
  Poll;
end;

function TMz101Editor.Synth: TMz101;
begin
  if Plugin is TMz101 then
    Result := TMz101(Plugin)
  else
    Result := nil;
end;

function TMz101Editor.SpecControl(Index: Integer): TJuceControl;
begin
  if (Index >= 0) and (Index < NumSpecs) then
    Result := FSpecControl[Index]
  else
    Result := nil;
end;

function TMz101Editor.SpecIndexOf(Control: TJuceControl): Integer;
var
  I: Integer;
begin
  for I := 0 to NumSpecs - 1 do
    if (Control <> nil) and (FSpecControl[I] = Control) then
      Exit(I);
  Result := -1;
end;

procedure TMz101Editor.Poll;
begin
  if Synth = nil then
    Exit;
  UpdateLearning;
  UpdateReadout;
  UpdateKeys;
end;

// A control learning, or a CC changing (which may come from the audio thread): the hints
// say so, and the outline moves.
procedure TMz101Editor.UpdateLearning;
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
    TLearnMarker(FMarker).FAroundButton := T is TJuceButton;
    FMarker.SetBounds(Round(T.AbsoluteX), Round(T.AbsoluteY), T.Width, T.Height);
    FMarker.Visible := True;
    FMarker.Invalidate;
  end
  else
    FMarker.Visible := False;
end;

// The C++ SeqButtons::timerCallback.
procedure TMz101Editor.UpdateReadout;
var
  Mode, Len, Position, Shift: Integer;
  Text: string;
begin
  if FReadout = nil then
    Exit;
  Mode := SeqOff;
  if FSeqMode >= 0 then
    Mode := Round(ParamToPlain(FSeqMode, ParamNormalised(FSeqMode)));
  Len := MeterInt(MeterSeqLength);
  Position := MeterInt(MeterSeqPosition);
  Shift := MeterInt(MeterKeyShift);
  if Mode = SeqLoad then
    Text := IntToStr(Len) + '/' + IntToStr(MaxSteps)
  else if (Mode = SeqPlay) and (Position >= 0) then
    Text := IntToStr(Position + 1) + '/' + IntToStr(Len)
  else if Shift > 0 then
    Text := 'KEY +' + IntToStr(Shift)
  else if Shift < 0 then
    Text := 'KEY ' + IntToStr(Shift)
  else
    Text := IntToStr(Len) + ' STEPS';
  if Meter(MeterTransposeArmed) >= 0.5 then
    Text := 'KEY?';
  FReadout.Caption := Text;   // repaints only if it changed
end;

// The keys held, from the host and from this keyboard, as Process last saw them.
procedure TMz101Editor.UpdateKeys;
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
procedure TMz101Editor.ControlMenu(Sender: TJuceControl; X, Y: Single; var Handled: Boolean);
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

procedure TMz101Editor.MenuChosen(Sender: TJuceEditor; MenuId, ItemId: Integer);
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

function TMz101Editor.MeterInt(Index: Integer): Integer;
var
  V: Single;
begin
  V := Meter(Index);
  if IsNan(V) then
    Result := 0
  else
    Result := Round(Max(-1.0e6, Min(V, 1.0e6)));
end;

function TMz101Editor.SeqModeNow: Integer;
begin
  Result := SeqOff;
  if FSeqMode >= 0 then
    Result := Round(ParamToPlain(FSeqMode, ParamNormalised(FSeqMode)));
end;

// The presses below reach the engine with the next audio block, and the LEDs, the readout
// and the keys show what it did once that block has published its meters. So that the
// panel answers at once - also while the host is not playing audio - each press also
// predicts the engine's answer (as Sh101Engine.CpuPass and KeyDown give it) until then.
procedure TMz101Editor.TransposeClick(Sender: TObject);
begin
  if Synth = nil then
    Exit;
  Synth.PressKeyTranspose;
  if SeqModeNow = SeqLoad then
  begin
    // REST: a step, and no tie pending
    PredictMeter(MeterSeqLength, Min(MaxSteps, MeterInt(MeterSeqLength) + 1));
    PredictMeter(MeterLegatoArmed, 0);
  end
  else if Meter(MeterTransposeArmed) >= 0.5 then
    PredictMeter(MeterTransposeArmed, 0)
  else
    PredictMeter(MeterTransposeArmed, 1);
  Poll;
end;

procedure TMz101Editor.LegatoClick(Sender: TObject);
begin
  if Synth = nil then
    Exit;
  Synth.PressLegato;
  if SeqModeNow = SeqLoad then
  begin
    if Meter(MeterLegatoArmed) >= 0.5 then
      PredictMeter(MeterLegatoArmed, 0)
    else
      PredictMeter(MeterLegatoArmed, 1);
  end;
  Poll;
end;

procedure TMz101Editor.PredictKey(Note: Integer; Down: Boolean);
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
  if not Down then
    Exit;
  if Meter(MeterTransposeArmed) >= 0.5 then
  begin
    // KEY TRANSPOSE then a key: the shift from middle C
    PredictMeter(MeterKeyShift, Note - 60);
    PredictMeter(MeterTransposeArmed, 0);
  end
  else if SeqModeNow = SeqLoad then
  begin
    // LOAD: the key is a step
    PredictMeter(MeterSeqLength, Min(MaxSteps, MeterInt(MeterSeqLength) + 1));
    PredictMeter(MeterLegatoArmed, 0);
  end;
end;

procedure TMz101Editor.KeyDown(Sender: TJuceControl; Note: Integer; Velocity: Single);
begin
  if (Synth <> nil) and Synth.QueueKey(Note, True) then
  begin
    PredictKey(Note, True);
    Poll;
  end;
end;

procedure TMz101Editor.KeyUp(Sender: TJuceControl; Note: Integer; Velocity: Single);
begin
  if (Synth <> nil) and Synth.QueueKey(Note, False) then
  begin
    PredictKey(Note, False);
    Poll;
  end;
end;

// RATE with SYNC on HOST: the note length it locks to, as the C++ slider shows it.
procedure TMz101Editor.RateText(Sender: TJuceParamControl; Normalised: Single; var Text: string);
begin
  if (FLfoSync < 0) or (Round(ParamToPlain(FLfoSync, ParamNormalised(FLfoSync))) <> LfoSyncHost) then
    Exit;
  Text := SyncDivisions[SyncDivisionIndex(ParamToPlain(Sender.ParamIndex, Normalised))].Name;
end;

end.
