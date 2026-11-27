// Mz950 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// The panel's controls, drawn as the C++ window's JUCE components are drawn by its
// Mz950LookAndFeel (Look.cpp, through Mz950Look): PascalJUCE's own knobs, buttons and boxes
// have their own look, so these are the C++'s, on TJuceControl.
//
//   TMzPanel    look::Panel - a titled card, decoration only (the mouse goes through it)
//   TMzLabel    a juce::Label: text in a 1/5 px border, squeezed to fit; a tooltip if it has one
//   TMzKnob     a juce::Slider, RotaryHorizontalVerticalDrag with its value box below: bound to
//               a parameter (with the C++'s skew for gain and glide time), or unbound with an
//               integer range of its own (the Program and Synth pages)
//   TMzButton   a juce::TextButton (and a toggled one, for the drum pads)
//   TMzToggle   a juce::ToggleButton, drawn as a switch: bound to a switch parameter, or not
//   TMzCombo    a juce::ComboBox: its own items, or a choice parameter's
//   TMzTabBar   a juce::TabbedButtonBar along the top, each tab in its own colour
//
// The mouse behaves as JUCE's does where the hand notices: a knob follows the mouse up and to
// the right, 250 px for its whole range, from where it was (no jump), in one host gesture; a
// double-click puts back the value the C++ gives it (if it gives one); the wheel moves it by
// 0.15 of its range. A button acts on the release, over it; a box opens its list on the press.
unit Mz950Controls;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  Classes, SysUtils, JuceCanvas, JucePlugin, JuceUI, Mz950Look;

type
  // How an unbound knob writes its value under it.
  TMzIntTextEvent = function(Sender: TObject; Value: Integer): string of object;

  TMzPanel = class(TJuceControl)
  private
    FTitle, FNote: string;
    FAccent: TJuceColor;
    procedure SetTitle(const Value: string);
    procedure SetNote(const Value: string);
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
  public
    constructor Create(AOwner: TComponent); override;
    function HitTest(X, Y: Single): Boolean; override;
    // look::Panel::content: the area under the title, in the PARENT's coordinates.
    function ContentLeft: Integer;
    function ContentTop: Integer;
    function ContentWidth: Integer;
    function ContentHeight: Integer;
    property Title: string read FTitle write SetTitle;
    property Note: string read FNote write SetNote;
    property Accent: TJuceColor read FAccent write FAccent;
  end;

  TMzLabel = class(TJuceControl)
  private
    FFontSize: Single;
    FBold: Boolean;
    FColor: TJuceColor;
    FAlign: TJuceAlign;
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
  public
    constructor Create(AOwner: TComponent); override;
    function HitTest(X, Y: Single): Boolean; override;
    // look::styleCaption: 10.5, dim, centred, upper case.
    procedure StyleCaption(const Text: string);
    property FontSize: Single read FFontSize write FFontSize;
    property Bold: Boolean read FBold write FBold;
    property Color: TJuceColor read FColor write FColor;
    property Align: TJuceAlign read FAlign write FAlign;
  end;

  TMzKnob = class(TJuceParamControl)
  private
    FAccent: TJuceColor;
    FLo, FHi: Integer;
    FTextBoxWidth: Integer;
    FResetEnabled: Boolean;
    FResetPlain: Single;
    FDragging: Boolean;
    FDownX, FDownY, FDownPos: Single;
    FSilent: Boolean;
    FOnIntText: TMzIntTextEvent;
    function SkewSpec: Integer;
    function PosOfValue(V: Single): Single;
    function ValueOfPos(P: Single): Single;
    function TextBoxHeight: Integer;
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
    procedure MouseDown(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseDrag(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseUp(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseDoubleClick(X, Y: Single; Shift: TJuceShiftState); override;
    function MouseWheel(X, Y, DX, DY: Single; Shift: TJuceShiftState): Boolean; override;
    procedure DoChange; override;
  public
    constructor Create(AOwner: TComponent); override;
    // Unbound: the whole numbers it steps through.
    procedure SetRange(Lo, Hi: Integer);
    function IntValue: Integer;
    // From code: no OnChange (the C++'s dontSendNotification).
    procedure SetIntValue(V: Integer);
    // setDoubleClickReturnValue (true, Plain).
    procedure SetDoubleClickReset(Plain: Single);
    // An offset: the arc lights from the top, with a tick there.
    function Bipolar: Boolean;
    // Where along the sweep it is drawn, 0..1 (the skewed position for gain and glide time).
    function Position: Single;
    function DisplayText: string;
    property Accent: TJuceColor read FAccent write FAccent;
    property TextBoxWidth: Integer read FTextBoxWidth write FTextBoxWidth;
    property OnIntText: TMzIntTextEvent read FOnIntText write FOnIntText;
    property Dragging: Boolean read FDragging;
  end;

  TMzButton = class(TJuceControl)
  private
    FIsOn: Boolean;
    FLit: TJuceColor;
    FTextOff: TJuceColor;
    FDown: Boolean;
    FOnClick: TNotifyEvent;
    procedure SetIsOn(Value: Boolean);
    procedure SetTextOff(Value: TJuceColor);
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
    procedure MouseDown(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseUp(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseEnter; override;
    procedure MouseLeave; override;
  public
    constructor Create(AOwner: TComponent); override;
    property IsOn: Boolean read FIsOn write SetIsOn;
    property Lit: TJuceColor read FLit write FLit;
    property TextOff: TJuceColor read FTextOff write SetTextOff;
    property OnClick: TNotifyEvent read FOnClick write FOnClick;
  end;

  TMzToggle = class(TJuceParamControl)
  private
    FLit: TJuceColor;
    FDown: Boolean;
    FSilent: Boolean;
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
    procedure MouseDown(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseUp(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseEnter; override;
    procedure MouseLeave; override;
    procedure DoChange; override;
  public
    constructor Create(AOwner: TComponent); override;
    function IsOn: Boolean;
    // From code: no OnChange.
    procedure SetChecked(Value: Boolean);
    property Lit: TJuceColor read FLit write FLit;
  end;

  TMzCombo = class(TJuceParamControl)
  private
    FItems: TArray<string>;
    FIndex: Integer;
    FTextWhenNothing: string;
    FTextWhenEmpty: string;
    FOutline: TJuceColor;
    procedure MenuChosen(Sender: TJuceEditor; MenuId, ItemId: Integer);
    function BoundItems: TArray<string>;
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
    procedure MouseDown(X, Y: Single; Shift: TJuceShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetItems(const AItems: array of string);
    procedure ClearItems;
    function Count: Integer;
    function Items: TArray<string>;
    // -1 for nothing chosen.
    function ItemIndex: Integer;
    // From code: no OnChange.
    procedure SetItemIndex(Index: Integer);
    function Text: string;
    property TextWhenNothingSelected: string read FTextWhenNothing write FTextWhenNothing;
    property TextWhenNoChoices: string read FTextWhenEmpty write FTextWhenEmpty;
    property Outline: TJuceColor read FOutline write FOutline;
  end;

  TMzTabBar = class(TJuceControl)
  private
    FNames: TArray<string>;
    FColors: TArray<TJuceColor>;
    FWidths: TArray<Single>;      // as last measured; 0 until painted
    FIndex: Integer;
    FHover, FDownTab: Integer;
    FOnChange: TNotifyEvent;
    function TabAt(X, Y: Single): Integer;
    procedure TabRect(Index: Integer; out X, W: Single);
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
    procedure MouseDown(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseUp(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseMove(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseLeave; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure AddTab(const Name: string; Color: TJuceColor);
    function TabCount: Integer;
    // From code; OnChange only if Notify.
    procedure SetIndex(Index: Integer; Notify: Boolean);
    property Index: Integer read FIndex;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

implementation

uses
  Math, Mz950Params;

{ ---------------------------------------------------------------------------- TMzPanel }

constructor TMzPanel.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FAccent := ColPerform;
end;

function TMzPanel.HitTest(X, Y: Single): Boolean;
begin
  // Decoration only: the controls in front of it get the mouse.
  Result := False;
end;

procedure TMzPanel.SetTitle(const Value: string);
begin
  if Value <> FTitle then
  begin
    FTitle := Value;
    Invalidate;
  end;
end;

procedure TMzPanel.SetNote(const Value: string);
begin
  if Value <> FNote then
  begin
    FNote := Value;
    Invalidate;
  end;
end;

function TMzPanel.ContentLeft: Integer;
begin
  Result := Left + PanelPad;
end;

function TMzPanel.ContentTop: Integer;
begin
  Result := Top + PanelHeaderHeight + 4;
end;

function TMzPanel.ContentWidth: Integer;
begin
  Result := Max(0, Width - 2 * PanelPad);
end;

function TMzPanel.ContentHeight: Integer;
begin
  Result := Max(0, Height - PanelHeaderHeight - 8);
end;

procedure TMzPanel.Paint(Canvas: TJuceCanvas);
begin
  PaintPanelCard(Canvas, Width, Height, FTitle, FNote, FAccent);
end;

{ ---------------------------------------------------------------------------- TMzLabel }

constructor TMzLabel.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FFontSize := 12.5;
  FColor := ColText;
  FAlign := jaLeft;
end;

function TMzLabel.HitTest(X, Y: Single): Boolean;
begin
  // Only a label with something to say takes the mouse, for its tooltip.
  Result := (Hint <> '') and inherited HitTest(X, Y);
end;

procedure TMzLabel.StyleCaption(const Text: string);
begin
  FFontSize := 10.5;
  FColor := ColDim;
  FAlign := jaCenter;
  Caption := UpperCase(Text);
end;

// As juce::Label: one line if it fits, otherwise as many lines as the label's height holds
// (drawFittedText's maximumLines), broken between words.
procedure TMzLabel.Paint(Canvas: TJuceCanvas);
var
  AreaW, AreaH, LineY: Single;
  MaxLines, N, I, Cut: Integer;
  Rest, Line: string;
  Lines: array of string;
begin
  AreaW := Max(0, Width - 10);
  AreaH := Max(0, Height - 2);
  MaxLines := Max(1, Trunc(AreaH / FFontSize));
  UseFont(Canvas, FFontSize, FBold);
  if (MaxLines = 1) or (Canvas.TextWidth(Caption) <= AreaW) then
  begin
    PaintLabelText(Canvas, Width, Height, Caption, FFontSize, FBold, FColor, FAlign, Enabled);
    Exit;
  end;
  Lines := nil;
  Rest := Trim(Caption);
  while (Rest <> '') and (Length(Lines) < MaxLines) do
  begin
    if (Length(Lines) = MaxLines - 1) or (Canvas.TextWidth(Rest) <= AreaW) then
    begin
      Line := Rest;
      Rest := '';
    end
    else
    begin
      // the longest run of whole words that fits
      Cut := 0;
      for I := 1 to Length(Rest) do
        if (Rest[I] = ' ') and (Canvas.TextWidth(Copy(Rest, 1, I - 1)) <= AreaW) then
          Cut := I;
      if Cut = 0 then
        Cut := Pos(' ', Rest);
      if Cut = 0 then
        Cut := Length(Rest) + 1;
      Line := Copy(Rest, 1, Cut - 1);
      Rest := Trim(Copy(Rest, Cut + 1, MaxInt));
    end;
    N := Length(Lines);
    SetLength(Lines, N + 1);
    Lines[N] := Line;
  end;
  if Enabled then
    Canvas.SetColor(FColor)
  else
    Canvas.SetColor(JMulAlpha(FColor, 0.5));
  LineY := 1 + (AreaH - Length(Lines) * FFontSize) / 2;
  for I := 0 to High(Lines) do
  begin
    Canvas.DrawFittedText(Lines[I], JuceRect(5, LineY, AreaW, FFontSize), FAlign, jvaCenter);
    LineY := LineY + FFontSize;
  end;
end;

{ ----------------------------------------------------------------------------- TMzKnob }

const
  PixelsForFullDrag = 250;    // juce::Slider's default
  WheelStep = 0.15;           // of the range, per wheel notch

constructor TMzKnob.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FAccent := ColPerform;
  FLo := 0;
  FHi := 99;
  FTextBoxWidth := 46;
end;

procedure TMzKnob.SetRange(Lo, Hi: Integer);
begin
  FLo := Lo;
  FHi := Max(Lo + 1, Hi);
  Invalidate;
end;

function TMzKnob.IntValue: Integer;
begin
  Result := FLo + Round(Value * (FHi - FLo));
end;

procedure TMzKnob.SetIntValue(V: Integer);
begin
  if V < FLo then V := FLo;
  if V > FHi then V := FHi;
  FSilent := True;
  try
    SetValueFromUser((V - FLo) / (FHi - FLo));
  finally
    FSilent := False;
  end;
  Invalidate;
end;

procedure TMzKnob.SetDoubleClickReset(Plain: Single);
begin
  FResetEnabled := True;
  FResetPlain := Plain;
end;

procedure TMzKnob.DoChange;
begin
  if not FSilent then
    inherited DoChange;
end;

// The parameter whose C++ range is skewed (gain, glide time), or -1.
function TMzKnob.SkewSpec: Integer;
begin
  Result := -1;
  if IsBound then
  begin
    Result := IndexOfId(ParameterId);
    if (Result >= 0) and (Specs[Result].Skew = 1) then
      Result := -1;
  end;
end;

function TMzKnob.PosOfValue(V: Single): Single;
var
  S: Integer;
begin
  S := SkewSpec;
  if S >= 0 then
    Result := PlainToNormalised(S, Specs[S].Lo + V * (Specs[S].Hi - Specs[S].Lo))
  else
    Result := V;
end;

function TMzKnob.ValueOfPos(P: Single): Single;
var
  S: Integer;
begin
  if P < 0 then P := 0;
  if P > 1 then P := 1;
  if IsBound then
  begin
    S := SkewSpec;
    if S >= 0 then
      Result := (NormalisedToPlain(S, P) - Specs[S].Lo) / (Specs[S].Hi - Specs[S].Lo)
    else
      Result := P;
  end
  else
    // an interval of 1: whole numbers only
    Result := Round(P * (FHi - FLo)) / (FHi - FLo);
end;

function TMzKnob.Position: Single;
begin
  Result := PosOfValue(Value);
end;

function TMzKnob.Bipolar: Boolean;
var
  Ed: TJuceEditor;
begin
  if IsBound then
  begin
    Ed := Editor;
    Result := (Ed <> nil) and (Ed.ParamToPlain(ParamIndex, 0) < 0) and (Ed.ParamToPlain(ParamIndex, 1) > 0);
  end
  else
    Result := (FLo < 0) and (FHi > 0);
end;

function TMzKnob.DisplayText: string;
begin
  if IsBound then
    Result := ValueText
  else if Assigned(FOnIntText) then
    Result := FOnIntText(Self, IntValue)
  else
    Result := IntToStr(IntValue);
end;

function TMzKnob.TextBoxHeight: Integer;
begin
  // LookAndFeel_V2::getSliderLayout: the box leaves the knob at least 15 px
  Result := Max(0, Min(14, Height - 15));
end;

procedure TMzKnob.Paint(Canvas: TJuceCanvas);
var
  TBH, TBW, TBX: Integer;
begin
  TBH := TextBoxHeight;
  PaintRotary(Canvas, 0, 0, Width, Height - TBH, Position, Bipolar, FAccent, Enabled);
  if TBH > 0 then
  begin
    TBW := Max(0, Min(FTextBoxWidth, Width));
    TBX := (Width - TBW) div 2;
    Canvas.SaveState;
    try
      Canvas.Translate(TBX, Height - TBH);
      PaintLabelText(Canvas, TBW, TBH, DisplayText, 11.5, False, ColText, jaCenter, Enabled);
    finally
      Canvas.RestoreState;
    end;
  end;
end;

procedure TMzKnob.MouseDown(X, Y: Single; Shift: TJuceShiftState);
begin
  if not (jssLeft in Shift) then
    Exit;
  BeginEdit;
  FDragging := True;
  FDownX := X;
  FDownY := Y;
  FDownPos := Position;
end;

procedure TMzKnob.MouseDrag(X, Y: Single; Shift: TJuceShiftState);
var
  P: Single;
begin
  if not FDragging then
    Exit;
  P := FDownPos + ((X - FDownX) + (FDownY - Y)) / PixelsForFullDrag;
  SetValueFromUser(ValueOfPos(P));
end;

procedure TMzKnob.MouseUp(X, Y: Single; Shift: TJuceShiftState);
begin
  if not FDragging then
    Exit;
  FDragging := False;
  EndEdit;
end;

procedure TMzKnob.MouseDoubleClick(X, Y: Single; Shift: TJuceShiftState);
var
  Ed: TJuceEditor;
  V: Single;
begin
  if not FResetEnabled then
    Exit;
  if IsBound then
  begin
    Ed := Editor;
    if Ed = nil then
      Exit;
    V := Ed.ParamFromPlain(ParamIndex, FResetPlain);
  end
  else
    V := (FResetPlain - FLo) / (FHi - FLo);
  Value := V;      // one gesture
end;

function TMzKnob.MouseWheel(X, Y, DX, DY: Single; Shift: TJuceShiftState): Boolean;
var
  D, P, V: Single;
begin
  Result := True;
  if DX <> 0 then D := -DX else D := DY;
  if D = 0 then
    Exit;
  P := Position + D * WheelStep;
  V := ValueOfPos(P);
  // a step too small to move a whole number still moves one
  if (not IsBound) and (V = Value) then
  begin
    if D > 0 then
      V := ValueOfPos(Value + 1 / (FHi - FLo))
    else
      V := ValueOfPos(Value - 1 / (FHi - FLo));
  end;
  Value := V;
end;

{ --------------------------------------------------------------------------- TMzButton }

constructor TMzButton.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FLit := ColPerform;
  FTextOff := ColText;
end;

procedure TMzButton.SetIsOn(Value: Boolean);
begin
  if Value <> FIsOn then
  begin
    FIsOn := Value;
    Invalidate;
  end;
end;

procedure TMzButton.SetTextOff(Value: TJuceColor);
begin
  if Value <> FTextOff then
  begin
    FTextOff := Value;
    Invalidate;
  end;
end;

procedure TMzButton.Paint(Canvas: TJuceCanvas);
var
  T: TJuceColor;
begin
  PaintButtonBackground(Canvas, Width, Height, FIsOn, FLit, Hovered and Enabled, FDown and Hovered);
  // a TextButton that is on writes in textColourOnId, which the look makes the window's
  if FIsOn then
    T := ColWindow
  else
    T := FTextOff;
  PaintButtonText(Canvas, Width, Height, Caption, T, Enabled);
end;

procedure TMzButton.MouseDown(X, Y: Single; Shift: TJuceShiftState);
begin
  if not (jssLeft in Shift) then
    Exit;
  FDown := True;
  Invalidate;
end;

procedure TMzButton.MouseUp(X, Y: Single; Shift: TJuceShiftState);
var
  Was: Boolean;
begin
  Was := FDown;
  FDown := False;
  Invalidate;
  if Was and HitTest(X, Y) and Enabled and Assigned(FOnClick) then
    FOnClick(Self);
end;

procedure TMzButton.MouseEnter;
begin
  Invalidate;
end;

procedure TMzButton.MouseLeave;
begin
  Invalidate;
end;

{ --------------------------------------------------------------------------- TMzToggle }

constructor TMzToggle.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FLit := ColPerform;
end;

function TMzToggle.IsOn: Boolean;
begin
  Result := Value >= 0.5;
end;

procedure TMzToggle.SetChecked(Value: Boolean);
begin
  FSilent := True;
  try
    if Value then
      SetValueFromUser(1)
    else
      SetValueFromUser(0);
  finally
    FSilent := False;
  end;
  Invalidate;
end;

procedure TMzToggle.DoChange;
begin
  if not FSilent then
    inherited DoChange;
end;

procedure TMzToggle.Paint(Canvas: TJuceCanvas);
begin
  PaintToggle(Canvas, Width, Height, IsOn, FLit, Hovered and Enabled, Enabled, Caption);
end;

procedure TMzToggle.MouseDown(X, Y: Single; Shift: TJuceShiftState);
begin
  if jssLeft in Shift then
    FDown := True;
end;

procedure TMzToggle.MouseUp(X, Y: Single; Shift: TJuceShiftState);
var
  Was: Boolean;
begin
  Was := FDown;
  FDown := False;
  if not (Was and HitTest(X, Y) and Enabled) then
    Exit;
  // one gesture, as a ButtonAttachment's click
  if IsOn then
    Value := 0
  else
    Value := 1;
end;

procedure TMzToggle.MouseEnter;
begin
  Invalidate;
end;

procedure TMzToggle.MouseLeave;
begin
  Invalidate;
end;

{ ---------------------------------------------------------------------------- TMzCombo }

function SplitBar(const S: string): TArray<string>;
var
  I, Start, N: Integer;
begin
  Result := nil;
  if S = '' then
    Exit;
  N := 0;
  Start := 1;
  for I := 1 to Length(S) + 1 do
    if (I > Length(S)) or (S[I] = '|') then
    begin
      SetLength(Result, N + 1);
      Result[N] := Copy(S, Start, I - Start);
      Inc(N);
      Start := I + 1;
    end;
end;

constructor TMzCombo.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FIndex := -1;
  FOutline := ColRaisedEdge;
end;

function TMzCombo.BoundItems: TArray<string>;
var
  Ed: TJuceEditor;
begin
  Result := nil;
  Ed := Editor;
  if (Ed <> nil) and IsBound then
    Result := SplitBar(Ed.ParamChoices(ParamIndex));
end;

function TMzCombo.Items: TArray<string>;
begin
  if IsBound then
    Result := BoundItems
  else
    Result := FItems;
end;

function TMzCombo.Count: Integer;
begin
  Result := Length(Items);
end;

procedure TMzCombo.SetItems(const AItems: array of string);
var
  I: Integer;
begin
  SetLength(FItems, Length(AItems));
  for I := 0 to High(AItems) do
    FItems[I] := AItems[I];
  if FIndex >= Length(FItems) then
    FIndex := -1;
  Invalidate;
end;

procedure TMzCombo.ClearItems;
begin
  FItems := nil;
  FIndex := -1;
  Invalidate;
end;

function TMzCombo.ItemIndex: Integer;
var
  N: Integer;
begin
  if IsBound then
  begin
    N := Count;
    if N <= 1 then
      Result := 0
    else
      Result := Round(Value * (N - 1));
  end
  else
    Result := FIndex;
end;

procedure TMzCombo.SetItemIndex(Index: Integer);
begin
  if (Index < -1) or (Index >= Length(FItems)) then
    Index := -1;
  if Index <> FIndex then
  begin
    FIndex := Index;
    Invalidate;
  end;
end;

function TMzCombo.Text: string;
var
  A: TArray<string>;
  I: Integer;
begin
  A := Items;
  I := ItemIndex;
  if (I >= 0) and (I < Length(A)) then
    Result := A[I]
  else
    Result := '';
end;

procedure TMzCombo.Paint(Canvas: TJuceCanvas);
var
  T: string;
  Placeholder: Boolean;
begin
  T := Text;
  Placeholder := False;
  if (ItemIndex < 0) or (Count = 0) then
  begin
    Placeholder := True;
    if Count = 0 then
      T := FTextWhenEmpty
    else
      T := FTextWhenNothing;
  end;
  PaintComboBox(Canvas, Width, Height, FOutline, T, Placeholder, Enabled);
end;

procedure TMzCombo.MouseDown(X, Y: Single; Shift: TJuceShiftState);
var
  Ed: TJuceEditor;
  A: TArray<string>;
  Menu: array of TJuceMenuItem;
  I, Current: Integer;
begin
  if not (jssLeft in Shift) then
    Exit;
  Ed := Editor;
  A := Items;
  if (Ed = nil) or (Length(A) = 0) then
    Exit;
  Current := ItemIndex;
  SetLength(Menu, Length(A));
  for I := 0 to High(A) do
  begin
    Menu[I] := JuceMenuItem(I + 1, A[I]);
    if I = Current then
      Menu[I].Flags := JCP_MENU_TICKED;
  end;
  Ed.PopupMenu(Menu, AbsoluteX, AbsoluteY + Height, MenuChosen);
end;

procedure TMzCombo.MenuChosen(Sender: TJuceEditor; MenuId, ItemId: Integer);
var
  N: Integer;
begin
  if ItemId <= 0 then
    Exit;
  if IsBound then
  begin
    N := Count;
    if N > 1 then
      Value := (ItemId - 1) / (N - 1);      // one gesture, as a ComboBoxAttachment
    Exit;
  end;
  if ItemId - 1 >= Length(FItems) then
    Exit;
  FIndex := ItemId - 1;
  Invalidate;
  DoChange;
end;

{ --------------------------------------------------------------------------- TMzTabBar }

constructor TMzTabBar.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FHover := -1;
  FDownTab := -1;
end;

procedure TMzTabBar.AddTab(const Name: string; Color: TJuceColor);
var
  N: Integer;
begin
  N := Length(FNames);
  SetLength(FNames, N + 1);
  SetLength(FColors, N + 1);
  SetLength(FWidths, N + 1);
  FNames[N] := Name;
  FColors[N] := Color;
  FWidths[N] := 0;
  Invalidate;
end;

function TMzTabBar.TabCount: Integer;
begin
  Result := Length(FNames);
end;

procedure TMzTabBar.SetIndex(Index: Integer; Notify: Boolean);
begin
  if (Index < 0) or (Index >= Length(FNames)) or (Index = FIndex) then
    Exit;
  FIndex := Index;
  Invalidate;
  if Notify and Assigned(FOnChange) then
    FOnChange(Self);
end;

// TabbedButtonBar::resized: each tab its best width (getTabButtonBestWidth: the name, bold
// 12, upper case, plus 30), side by side - LookAndFeel_V3, which the C++ look derives from,
// overlaps them by -1 and leaves no space around them - all scaled down together if they do
// not fit.
procedure TMzTabBar.TabRect(Index: Integer; out X, W: Single);
var
  I: Integer;
  Overlap, Total, Scale, Pos, Best: Single;
begin
  Overlap := -1;
  Total := Max(0, Overlap);
  for I := 0 to High(FNames) do
  begin
    if FWidths[I] > 0 then
      Best := FWidths[I]
    else
      Best := Length(FNames[I]) * 8 + 30;   // until painted, an estimate
    Total := Total + Best - Overlap;
  end;
  Scale := 1;
  if Total > Width then
    Scale := Max(0.7, Width / Total);
  Pos := 0;
  X := 0;
  W := 0;
  for I := 0 to High(FNames) do
  begin
    if FWidths[I] > 0 then
      Best := FWidths[I]
    else
      Best := Length(FNames[I]) * 8 + 30;
    Best := Round(Scale * Best);
    if I = Index then
    begin
      X := Pos;
      W := Best;
      Exit;
    end;
    Pos := Pos + Best - Overlap;
  end;
end;

function TMzTabBar.TabAt(X, Y: Single): Integer;
var
  I: Integer;
  TX, TW: Single;
begin
  // the front tab is on top; then the others, the later ones over the earlier
  if (FIndex >= 0) and (FIndex < Length(FNames)) then
  begin
    TabRect(FIndex, TX, TW);
    if (X >= TX) and (X < TX + TW) and (Y >= 0) and (Y < Height) then
      Exit(FIndex);
  end;
  for I := High(FNames) downto 0 do
  begin
    TabRect(I, TX, TW);
    if (X >= TX) and (X < TX + TW) and (Y >= 0) and (Y < Height) then
      Exit(I);
  end;
  Result := -1;
end;

procedure TMzTabBar.Paint(Canvas: TJuceCanvas);
var
  I: Integer;
  TX, TW, AX, AY, AW, AH: Single;
  Name: string;
begin
  UseFont(Canvas, 12, True);
  for I := 0 to High(FNames) do
    FWidths[I] := Round(Canvas.TextWidth(UpperCase(FNames[I]))) + 30;

  // drawTabAreaBehindFrontButton: a rule along the bottom
  Canvas.SetColor(ColPanelEdge);
  Canvas.FillRect(JuceRect(0, Height - 1, Width, 1));

  for I := 0 to High(FNames) do
  begin
    TabRect(I, TX, TW);
    // TabBarButton::getActiveArea: the whole tab (no space around it in V3)
    AX := TX;
    AY := 0;
    AW := TW;
    AH := Height;
    Name := UpperCase(FNames[I]);
    UseFont(Canvas, 12, True);
    if I = FIndex then
      Canvas.SetColor(ColText)
    else if I = FHover then
      Canvas.SetColor(JuceWithAlpha(ColText, 0.8))
    else
      Canvas.SetColor(ColDim);
    Canvas.DrawText(Name, JuceRect(AX, AY, AW, AH), jaCenter, jvaCenter);
    if I = FIndex then
    begin
      Canvas.SetColor(FColors[I]);
      Canvas.FillRect(JuceRect(AX + 6, AY + AH - 3, AW - 12, 2));
    end;
  end;
end;

procedure TMzTabBar.MouseDown(X, Y: Single; Shift: TJuceShiftState);
begin
  if jssLeft in Shift then
    FDownTab := TabAt(X, Y)
  else
    FDownTab := -1;
end;

procedure TMzTabBar.MouseUp(X, Y: Single; Shift: TJuceShiftState);
var
  T: Integer;
begin
  T := TabAt(X, Y);
  if (T >= 0) and (T = FDownTab) then
    SetIndex(T, True);
  FDownTab := -1;
end;

procedure TMzTabBar.MouseMove(X, Y: Single; Shift: TJuceShiftState);
var
  T: Integer;
begin
  T := TabAt(X, Y);
  if T <> FHover then
  begin
    FHover := T;
    Invalidate;
  end;
end;

procedure TMzTabBar.MouseLeave;
begin
  if FHover <> -1 then
  begin
    FHover := -1;
    Invalidate;
  end;
end;

end.
