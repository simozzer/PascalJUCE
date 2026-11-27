// MzPCF - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// PcfControls - the look of the rack's effects units (MzDebirth), as the C++ MzPCF draws it
// (Source/Look.h, Look.cpp, PluginEditor.cpp), on PascalJUCE's controls. MzPCG and MzPCD
// look the same, so they can use these too. Depends on the framework's UI units only
// (JuceCanvas, JuceUI, JuceControls) and on PcfPatterns - not on any plug-in.
//
//   TPcfFace            a panel's bevelled face (drawFace)
//   TPcfKnob            a knob with its legend above it: a scale of eleven marks, a skirt,
//                       a cap lit from above, an orange pointer (Look::drawRotarySlider);
//                       dragged up or to the right, wheel, double-click for the default,
//                       its value in a bubble while dragged and on hover
//   TPcfLedNumber       a red seven-segment style readout of a whole-number parameter,
//                       dragged up and down or wheeled; double-click for its default
//   TPcfSwitch          a pad that steps through a choice parameter's positions, named on it
//   TPcfPatternDisplay  the pattern, drawn: a bar a step, the step playing lit
//
// A designed form (the IDE knows only the ready-made controls) holds a stand-in for each
// of these - a TJucePanel, TJuceKnob, TJuceDisplay, TJuceButton - and PcfReplaceControl
// swaps the stand-in for the real one when the panel is built, with the same name, place
// and properties. See MzPcfEditor.

unit PcfControls;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  Classes, JuceCanvas, JuceUI;

const
  // namespace colours (Look.h)
  PcfRail = $FF26272B;
  PcfScrew = $FF8D8F93;
  PcfMixer = $FF3C4F63;
  PcfMixerEdge = $FF22303E;
  PcfDisplay = $FF160606;
  PcfLedRed = $FFFF3B22;
  PcfLedOff = $FF4A1712;
  PcfPad = $FF1B1B1D;
  PcfLight = $FFE9E9E6;
  PcfKnobCap = $FF15181D;
  PcfPointer = $FFEF7D22;
  PcfStepRed = $FFD8321F;

  // fonts::digits: JUCE's default monospaced face
  PcfDigitsFont = '<Monospaced>';

// juce::Colour::brighter, darker and withAlpha, exactly as JUCE works them out (the
// framework's JuceBrighter / JuceDarker blend another way).
function PcfBrighter(C: TJuceColor; Amount: Single): TJuceColor;
function PcfDarker(C: TJuceColor; Amount: Single): TJuceColor;
function PcfWithAlpha(C: TJuceColor; Alpha: Single): TJuceColor;

// drawFace: a panel's bevelled face in colour C.
procedure PcfDrawFace(Canvas: TJuceCanvas; const R: TJuceRect; C: TJuceColor);

type
  // A panel's bevelled face: a soft vertical gradient, a highlight along the top, a dark
  // edge (drawFace). Clicks pass through.
  TPcfFace = class(TJuceControl)
  private
    FColor: TJuceColor;
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
  public
    constructor Create(AOwner: TComponent); override;
    function HitTest(X, Y: Single): Boolean; override;
  published
    property Color: TJuceColor read FColor write FColor;
  end;

  //
  // A knob with its legend (Caption) above it, on a parameter: the C++ Knob, a JUCE
  // rotary slider (RotaryHorizontalVerticalDrag, 180 pixels for the whole turn, 7:30 to
  // 4:30) drawn by Look::drawRotarySlider.
  //
  TPcfKnob = class(TJuceParamControl)
  private
    FBodyColor, FPointerColor, FTrackColor, FTextColor: TJuceColor;
    FSensitivity: Integer;
    FValueBubble: TJuceValueBubble;
    FDragging: Boolean;
    FDownX, FDownY, FDownValue: Single;
    function HoverTicks: Integer;
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
    procedure MouseDown(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseDrag(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseUp(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseDoubleClick(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseEnter; override;
    procedure MouseLeave; override;
    function MouseWheel(X, Y, DX, DY: Single; Shift: TJuceShiftState): Boolean; override;
    function BubbleAnchor: TJuceRect; override;
  public
    constructor Create(AOwner: TComponent); override;
    // The slider's square, under the legend (Knob::resized), in local coordinates.
    function SliderRect: TJuceRect;
    property Dragging: Boolean read FDragging;
  published
    // the cap (rotarySliderFillColourId)
    property BodyColor: TJuceColor read FBodyColor write FBodyColor;
    // the pointer (thumbColourId)
    property PointerColor: TJuceColor read FPointerColor write FPointerColor;
    // the scale round it (rotarySliderOutlineColourId)
    property TrackColor: TJuceColor read FTrackColor write FTrackColor;
    // the legend
    property TextColor: TJuceColor read FTextColor write FTextColor;
    // pixels of drag for the whole turn
    property Sensitivity: Integer read FSensitivity write FSensitivity default 180;
    property ValueBubble: TJuceValueBubble read FValueBubble write FValueBubble default jvbDragAndHover;
  end;

  //
  // A red seven-segment style readout of a whole-number parameter, set by dragging up and
  // down (four pixels a step) or the mouse wheel; double-click for its default (LedNumber).
  //
  TPcfLedNumber = class(TJuceParamControl)
  private
    FDigits: Integer;
    FColor, FTextColor, FUnlitColor, FBorderColor: TJuceColor;
    FDragFrom: Integer;
    FDownY: Single;
    FWheel: Single;
    FDown: Boolean;
    procedure Put(V: Integer);
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
    procedure MouseDown(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseDrag(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseUp(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseDoubleClick(X, Y: Single; Shift: TJuceShiftState); override;
    function MouseWheel(X, Y, DX, DY: Single; Shift: TJuceShiftState): Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
    // The number shown: the parameter's value (its plain value, rounded).
    function Number: Integer;
    // The parameter's range (1..32 for the pattern; the normalised 0..1 if unbound).
    function MinNumber: Integer;
    function MaxNumber: Integer;
  published
    property Digits: Integer read FDigits write FDigits default 2;
    // the plate
    property Color: TJuceColor read FColor write FColor;
    // the lit segments
    property TextColor: TJuceColor read FTextColor write FTextColor;
    // the unlit ones (the C++ draws ledOff at 40%)
    property UnlitColor: TJuceColor read FUnlitColor write FUnlitColor;
    property BorderColor: TJuceColor read FBorderColor write FBorderColor;
  end;

  //
  // A switch, as a pad that steps through its positions, named on it, its legend (Caption)
  // above it (the C++ Switch). A click moves it on one position, round to the first.
  //
  TPcfSwitch = class(TJuceParamControl)
  private
    FFaceColor, FTextColor: TJuceColor;
    FPressed: Boolean;
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
    procedure MouseDown(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseUp(X, Y: Single; Shift: TJuceShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    // The parameter's positions (its choices; 2 if unbound).
    function Positions: Integer;
    function Position: Integer;
    property Pressed: Boolean read FPressed;
  published
    property FaceColor: TJuceColor read FFaceColor write FFaceColor;
    property TextColor: TJuceColor read FTextColor write FTextColor;
  end;

  //
  // The pattern, drawn: a bar a step, as tall as the level the filter is struck at, the
  // step playing lit (PatternDisplay). It follows the pattern parameter (PatternParameterId,
  // its plain value 1..32) and the step the plug-in publishes as a meter (MeterIndex; -1
  // or less: none lit), on the editor's timer - or set them from code with Show.
  //
  // With ShowPush (MzPCD's display), a meter strip at the right shows a value 0..1 too -
  // the push the pattern gives now - from PushMeterIndex, or Show's APush.
  //
  TPcfPatternDisplay = class(TJuceControl)
  private
    FPattern, FStep: Integer;
    FPatternParameterId: string;
    FMeterIndex: Integer;
    FColor, FTextColor, FBorderColor: TJuceColor;
    FAutoFollow: Boolean;
    FPush: Single;
    FShowPush: Boolean;
    FPushMeterIndex: Integer;
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
    function NeedsTimer: Boolean; override;
    procedure Tick; override;
  public
    constructor Create(AOwner: TComponent); override;
    // Pattern 0..31, Step 0..15 or -1. Repaints only on a change.
    procedure Show(APattern, AStep: Integer); overload;
    // ... and the push (0..1), for ShowPush; a change under 0.002 is not repainted.
    procedure Show(APattern, AStep: Integer; APush: Single); overload;
    // Where the parameter and the meter are now (what Tick shows).
    procedure Follow;
    property Pattern: Integer read FPattern;
    property Step: Integer read FStep;
    property Push: Single read FPush;
  published
    property PatternParameterId: string read FPatternParameterId write FPatternParameterId;
    property MeterIndex: Integer read FMeterIndex write FMeterIndex default 0;
    // False: only Show moves it.
    property AutoFollow: Boolean read FAutoFollow write FAutoFollow default True;
    // the push meter at the right (MzPCD), and the meter slot it follows (-1: Show only)
    property ShowPush: Boolean read FShowPush write FShowPush default False;
    property PushMeterIndex: Integer read FPushMeterIndex write FPushMeterIndex default -1;
    // the plate
    property Color: TJuceColor read FColor write FColor;
    // the bars
    property TextColor: TJuceColor read FTextColor write FTextColor;
    property BorderColor: TJuceColor read FBorderColor write FBorderColor;
  end;

// Swaps a stand-in from a designed form for a control of NewClass: the same parent, the
// same place among its siblings (so the same drawing order), the same name, and every
// published property the two share (bounds, caption, hint, parameter, colours, events).
// The stand-in is freed; it must have no children. Returns the new control.
function PcfReplaceControl(Old: TJuceControl; NewClass: TJuceControlClass): TJuceControl;

implementation

uses
  SysUtils, Math, TypInfo, PcfPatterns;

const
  // MathConstants<float>::pi * 1.25f and * 2.75f: 7:30 to 4:30, clockwise from 12
  RotaryStart = Pi * 1.25;
  RotaryEnd = Pi * 2.75;
  LegendHeight = 12;

{ ---- colours ---- }

function Channel(C: TJuceColor; Shift: Integer): Integer; inline;
begin
  Result := (C shr Shift) and $FF;
end;

function Argb(A, R, G, B: Integer): TJuceColor; inline;
begin
  Result := (Cardinal(A) shl 24) or (Cardinal(R) shl 16) or (Cardinal(G) shl 8) or Cardinal(B);
end;

// (uint8) of a float: truncated, as the C++ cast (the values are always 0..255 here).
function ToByte(F: Single): Integer;
begin
  if not (F > 0) then
    Result := 0
  else if F >= 255 then
    Result := 255
  else
    Result := Trunc(F);
end;

function PcfBrighter(C: TJuceColor; Amount: Single): TJuceColor;
var
  A, F: Single;
  Ch: array[0..2] of Integer;
  I: Integer;
begin
  A := 1 / (1 + Amount);
  for I := 0 to 2 do
  begin
    F := 255 - Channel(C, 16 - 8 * I);
    F := 255 - A * F;
    Ch[I] := ToByte(F);
  end;
  Result := Argb(Channel(C, 24), Ch[0], Ch[1], Ch[2]);
end;

function PcfDarker(C: TJuceColor; Amount: Single): TJuceColor;
var
  A, F: Single;
  Ch: array[0..2] of Integer;
  I: Integer;
begin
  A := 1 / (1 + Amount);
  for I := 0 to 2 do
  begin
    F := Channel(C, 16 - 8 * I);
    Ch[I] := ToByte(A * F);
  end;
  Result := Argb(Channel(C, 24), Ch[0], Ch[1], Ch[2]);
end;

function PcfWithAlpha(C: TJuceColor; Alpha: Single): TJuceColor;
var
  F: Single;
  A: Integer;
begin
  F := Alpha * 255;
  A := Round(F);   // roundToInt
  if A < 0 then
    A := 0
  else if A > 255 then
    A := 255;
  Result := (C and $00FFFFFF) or (Cardinal(A) shl 24);
end;

procedure PcfDrawFace(Canvas: TJuceCanvas; const R: TJuceRect; C: TJuceColor);
begin
  Canvas.SetLinearGradient(PcfBrighter(C, 0.08), R.X, R.Y, PcfDarker(C, 0.12), R.X, R.Y + R.H);
  Canvas.FillRoundRect(R, 3);
  Canvas.SetColor(PcfWithAlpha(PcfBrighter(C, 0.35), 0.6));
  Canvas.DrawLine(R.X + 3, R.Y + 0.5, R.X + R.W - 3, R.Y + 0.5, 1);
  Canvas.SetColor(PcfWithAlpha($FF000000, 0.6));
  Canvas.DrawRoundRect(JuceInset(R, 0.5), 3, 1);
end;

procedure DrawLegend(Canvas: TJuceCanvas; const Text: string; const R: TJuceRect; Color: TJuceColor);
begin
  Canvas.SetColor(Color);
  Canvas.SetFont('', 9.5, [jfsBold]);
  Canvas.DrawText(Text, R, jaCenter, jvaCenter);
end;

function Pick(C, Default: TJuceColor): TJuceColor; inline;
begin
  if C = 0 then
    Result := Default
  else
    Result := C;
end;

{ ---- TPcfFace ---- }

constructor TPcfFace.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FColor := PcfMixer;
end;

function TPcfFace.HitTest(X, Y: Single): Boolean;
begin
  Result := False;
end;

procedure TPcfFace.Paint(Canvas: TJuceCanvas);
begin
  PcfDrawFace(Canvas, BoundsRect, Pick(FColor, PcfMixer));
end;

{ ---- TPcfKnob ---- }

constructor TPcfKnob.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 54;
  Height := 74;
  FSensitivity := 180;
  FValueBubble := jvbDragAndHover;
end;

function TPcfKnob.SliderRect: TJuceRect;
var
  RW, RH, Side: Integer;
begin
  // r = bounds without the legend; a square as wide as it fits, centred across, at the top
  RW := Width;
  RH := Height - LegendHeight;
  Side := Max(0, Min(RW, RH));
  Result := JuceRect((RW - Side) div 2, LegendHeight, Side, Side);
end;

function TPcfKnob.BubbleAnchor: TJuceRect;
begin
  Result := SliderRect;
end;

procedure TPcfKnob.Paint(Canvas: TJuceCanvas);
var
  S, Skirt, Top: TJuceRect;
  Radius, CX, CY, A, DX, DY, Outer, Pos: Single;
  I: Integer;
  Major: Boolean;
  Cap: TJuceColor;
begin
  DrawLegend(Canvas, Caption, JuceRect(0, 0, Width, LegendHeight), Pick(FTextColor, PcfLight));

  S := SliderRect;
  Radius := Min(S.W, S.H) * 0.5 - 5;
  if Radius <= 0 then
    Exit;
  CX := S.X + S.W * 0.5;
  CY := S.Y + S.H * 0.5;

  // the scale: eleven marks
  Canvas.SetColor(Pick(FTrackColor, PcfLight));
  for I := 0 to 10 do
  begin
    A := RotaryStart + (RotaryEnd - RotaryStart) * I / 10;
    DX := Sin(A);
    DY := -Cos(A);
    Major := I mod 5 = 0;
    if Major then
      Outer := Radius + 5
    else
      Outer := Radius + 3.5;
    if Major then
      Canvas.DrawLine(CX + DX * (Radius + 1.5), CY + DY * (Radius + 1.5), CX + DX * Outer, CY + DY * Outer, 1.3)
    else
      Canvas.DrawLine(CX + DX * (Radius + 1.5), CY + DY * (Radius + 1.5), CX + DX * Outer, CY + DY * Outer, 0.8);
  end;

  // a skirt, then the cap, lit from above
  Cap := Pick(FBodyColor, PcfKnobCap);
  Skirt := JuceRect(CX - Radius, CY - Radius, Radius * 2, Radius * 2);
  Canvas.SetColor(PcfDarker(Cap, 0.7));
  Canvas.FillEllipse(Skirt);

  Top := JuceInset(Skirt, Radius * 0.18);
  Canvas.SetLinearGradient(PcfBrighter(Cap, 0.25), Top.X + Top.W * 0.5, Top.Y,
    PcfDarker(Cap, 0.35), Top.X + Top.W * 0.5, Top.Y + Top.H);
  Canvas.FillEllipse(Top);
  Canvas.SetColor(PcfWithAlpha($FF000000, 0.7));
  Canvas.DrawEllipse(Top, 0.8);

  // the pointer
  Pos := Value;
  if IsNan(Pos) or (Pos < 0) then
    Pos := 0
  else if Pos > 1 then
    Pos := 1;
  A := RotaryStart + (RotaryEnd - RotaryStart) * Pos;
  DX := Sin(A);
  DY := -Cos(A);
  Canvas.SetColor(Pick(FPointerColor, PcfPointer));
  Canvas.DrawLine(CX + DX * (Radius * 0.2), CY + DY * (Radius * 0.2), CX + DX * (Radius * 0.9),
    CY + DY * (Radius * 0.9), 2);

  if not Enabled then
  begin
    Canvas.SetColor(JuceWithAlpha(Theme.Background, 0.5));
    Canvas.FillRect(BoundsRect);
  end;
end;

function TPcfKnob.HoverTicks: Integer;
var
  Ed: TJuceEditor;
begin
  // two seconds of editor timer ticks (JUCE's popup display hides after 2000 ms)
  Ed := Editor;
  if (Ed <> nil) and (Ed.TimerHz > 0) then
    Result := Max(1, Min(240, Ed.TimerHz)) * 2
  else
    Result := 60;
end;

procedure TPcfKnob.MouseDown(X, Y: Single; Shift: TJuceShiftState);
begin
  if not (jssLeft in Shift) then
    Exit;
  BeginEdit;
  FDragging := True;
  FDownX := X;
  FDownY := Y;
  FDownValue := Value;
  if FValueBubble <> jvbNone then
    ShowBubble;
end;

procedure TPcfKnob.MouseDrag(X, Y: Single; Shift: TJuceShiftState);
var
  V: Single;
begin
  if not FDragging then
    Exit;
  // RotaryHorizontalVerticalDrag: right and up both turn it up
  V := FDownValue + ((X - FDownX) + (FDownY - Y)) / Max(1, FSensitivity);
  if IsNan(V) or (V < 0) then
    V := 0
  else if V > 1 then
    V := 1;
  SetValueFromUser(V);
end;

procedure TPcfKnob.MouseUp(X, Y: Single; Shift: TJuceShiftState);
begin
  if not FDragging then
    Exit;
  FDragging := False;
  EndEdit;
  if (FValueBubble = jvbDragAndHover) and Hovered then
    ShowBubble(HoverTicks)
  else
    HideBubble;
end;

procedure TPcfKnob.MouseDoubleClick(X, Y: Single; Shift: TJuceShiftState);
begin
  ResetToDefault;
end;

procedure TPcfKnob.MouseEnter;
begin
  if (FValueBubble = jvbDragAndHover) and not FDragging then
    ShowBubble(HoverTicks);
end;

procedure TPcfKnob.MouseLeave;
begin
  if not FDragging then
    HideBubble;
end;

function TPcfKnob.MouseWheel(X, Y, DX, DY: Single; Shift: TJuceShiftState): Boolean;
var
  Delta, V: Single;
begin
  // JUCE's slider: 0.15 of the travel a unit of wheel, sideways scrolling the other way
  Result := True;
  if Abs(DX) > Abs(DY) then
    Delta := -DX
  else
    Delta := DY;
  if Delta = 0 then
    Exit;
  V := Value + Delta * 0.15;
  if IsNan(V) or (V < 0) then
    V := 0
  else if V > 1 then
    V := 1;
  Value := V;
end;

{ ---- TPcfLedNumber ---- }

constructor TPcfLedNumber.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 44;
  Height := 32;
  FDigits := 2;
end;

function TPcfLedNumber.MinNumber: Integer;
var
  Ed: TJuceEditor;
begin
  Ed := Editor;
  if (Ed <> nil) and IsBound then
    Result := Round(Ed.ParamToPlain(ParamIndex, 0))
  else
    Result := 0;
end;

function TPcfLedNumber.MaxNumber: Integer;
var
  Ed: TJuceEditor;
begin
  Ed := Editor;
  if (Ed <> nil) and IsBound then
    Result := Round(Ed.ParamToPlain(ParamIndex, 1))
  else
    Result := 1;
end;

function TPcfLedNumber.Number: Integer;
var
  Ed: TJuceEditor;
  P: Single;
begin
  Ed := Editor;
  if (Ed <> nil) and IsBound then
    P := Ed.ParamToPlain(ParamIndex, Value)
  else
    P := Value;
  if IsNan(P) then
    Result := 0
  else
    Result := Round(Max(-1.0e9, Min(1.0e9, P)));
end;

procedure TPcfLedNumber.Put(V: Integer);
var
  Ed: TJuceEditor;
begin
  V := Max(MinNumber, Min(MaxNumber, V));
  Ed := Editor;
  if (V <> Number) and (Ed <> nil) and IsBound then
    SetValueFromUser(Ed.ParamFromPlain(ParamIndex, V));
  Invalidate;
end;

procedure TPcfLedNumber.MouseDown(X, Y: Single; Shift: TJuceShiftState);
begin
  FDown := True;
  FDownY := Y;
  FDragFrom := Number;
  BeginEdit;
end;

procedure TPcfLedNumber.MouseDrag(X, Y: Single; Shift: TJuceShiftState);
var
  Distance: Integer;
begin
  if not FDown then
    Exit;
  // getDistanceFromDragStartY() / 4: whole pixels, then an integer division
  Distance := Round(Y) - Round(FDownY);
  Put(FDragFrom - Distance div 4);
end;

procedure TPcfLedNumber.MouseUp(X, Y: Single; Shift: TJuceShiftState);
begin
  FDown := False;
  EndEdit;
end;

procedure TPcfLedNumber.MouseDoubleClick(X, Y: Single; Shift: TJuceShiftState);
var
  Ed: TJuceEditor;
begin
  Ed := Editor;
  if (Ed = nil) or not IsBound then
    Exit;
  BeginEdit;
  Put(Round(Ed.ParamToPlain(ParamIndex, DefaultValue)));
  EndEdit;
end;

function TPcfLedNumber.MouseWheel(X, Y, DX, DY: Single; Shift: TJuceShiftState): Boolean;
var
  Whole: Integer;
begin
  Result := True;
  if IsNan(DY) or (Abs(DY) > 1000) then
    Exit;
  FWheel := FWheel + DY * 8;
  Whole := Trunc(FWheel);
  if Whole = 0 then
    Exit;
  FWheel := FWheel - Whole;
  BeginEdit;
  Put(Number + Whole);
  EndEdit;
end;

procedure TPcfLedNumber.Paint(Canvas: TJuceCanvas);
var
  R, T: TJuceRect;
  Eights: string;
  I: Integer;
begin
  R := BoundsRect;
  Canvas.SetColor(Pick(FColor, PcfDisplay));
  Canvas.FillRoundRect(R, 2);
  Canvas.SetColor(Pick(FBorderColor, $FF000000));
  Canvas.DrawRoundRect(JuceInset(R, 0.5), 2, 1);

  Canvas.SetFont(PcfDigitsFont, R.H * 0.78, [jfsBold]);
  T := JuceRect(R.X + 4, R.Y, Max(0, R.W - 8), R.H);
  Eights := '';
  for I := 1 to Max(1, Min(16, FDigits)) do
    Eights := Eights + '8';
  Canvas.SetColor(Pick(FUnlitColor, PcfWithAlpha(PcfLedOff, 0.4)));   // the unlit segments, there but not read
  Canvas.DrawText(Eights, T, jaRight, jvaCenter);
  Canvas.SetColor(Pick(FTextColor, PcfLedRed));
  Canvas.DrawText(IntToStr(Number), T, jaRight, jvaCenter);
end;

{ ---- TPcfSwitch ---- }

constructor TPcfSwitch.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 50;
  Height := 46;
end;

function TPcfSwitch.Positions: Integer;
var
  Ed: TJuceEditor;
  Choices: string;
  I: Integer;
begin
  Result := 2;
  Ed := Editor;
  if (Ed = nil) or not IsBound then
    Exit;
  Choices := Ed.ParamChoices(ParamIndex);
  if Choices = '' then
    Exit;
  Result := 1;
  for I := 1 to Length(Choices) do
    if Choices[I] = '|' then
      Inc(Result);
  Result := Max(2, Result);
end;

function TPcfSwitch.Position: Integer;
var
  P: Single;
begin
  P := Value * (Positions - 1);
  if IsNan(P) then
    Result := 0
  else
    Result := Round(P);
end;

procedure TPcfSwitch.MouseDown(X, Y: Single; Shift: TJuceShiftState);
var
  N: Integer;
begin
  FPressed := True;
  N := Positions;
  BeginEdit;
  SetValueFromUser(((Position + 1) mod N) / (N - 1));
  EndEdit;
  Invalidate;
end;

procedure TPcfSwitch.MouseUp(X, Y: Single; Shift: TJuceShiftState);
begin
  FPressed := False;
  Invalidate;
end;

procedure TPcfSwitch.Paint(Canvas: TJuceCanvas);
var
  Area, R: TJuceRect;
  W, H, X, Y: Integer;
  Face: TJuceColor;
begin
  DrawLegend(Canvas, Caption, JuceRect(0, 0, Width, LegendHeight), Pick(FTextColor, PcfLight));

  // the pad: up to 46 x 26, centred under the legend, a pixel in from its edges
  Area := JuceRect(0, LegendHeight + 2, Width, Max(0, Height - LegendHeight - 2));
  W := Min(Width, 46);
  H := 26;
  X := (Width - W) div 2;
  Y := Round(Area.Y) + (Round(Area.H) - H) div 2;
  R := JuceInset(JuceRect(X, Y, W, H), 1);
  if FPressed then
    R.Y := R.Y + 1;

  Face := Pick(FFaceColor, PcfPad);
  if FPressed then
    Canvas.SetLinearGradient(PcfBrighter(Face, 0), R.X, R.Y, PcfDarker(Face, 0.3), R.X, R.Y + R.H)
  else
    Canvas.SetLinearGradient(PcfBrighter(Face, 0.15), R.X, R.Y, PcfDarker(Face, 0.3), R.X, R.Y + R.H);
  Canvas.FillRoundRect(R, 3);
  Canvas.SetColor(PcfWithAlpha($FF000000, 0.7));
  Canvas.DrawRoundRect(R, 3, 1);

  Canvas.SetColor(Pick(FTextColor, PcfLight));
  Canvas.SetFont('', 11, [jfsBold]);
  // r.toNearestInt()
  Canvas.DrawText(ValueText, JuceRect(Round(R.X), Round(R.Y), Round(R.W), Round(R.H)), jaCenter, jvaCenter);
end;

{ ---- TPcfPatternDisplay ---- }

constructor TPcfPatternDisplay.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 150;
  Height := 66;
  FStep := -1;
  FPatternParameterId := 'pattern';
  FAutoFollow := True;
  FPushMeterIndex := -1;
end;

procedure TPcfPatternDisplay.Show(APattern, AStep: Integer);
begin
  if (APattern = FPattern) and (AStep = FStep) then
    Exit;
  FPattern := APattern;
  FStep := AStep;
  Invalidate;
end;

procedure TPcfPatternDisplay.Show(APattern, AStep: Integer; APush: Single);
begin
  if IsNan(APush) then
    APush := 0;
  if (APattern = FPattern) and (AStep = FStep) and (Abs(APush - FPush) < 0.002) then
    Exit;
  FPattern := APattern;
  FStep := AStep;
  FPush := APush;
  Invalidate;
end;

function TPcfPatternDisplay.NeedsTimer: Boolean;
begin
  Result := FAutoFollow;
end;

procedure TPcfPatternDisplay.Tick;
begin
  if FAutoFollow then
    Follow;
end;

procedure TPcfPatternDisplay.Follow;
var
  Ed: TJuceEditor;
  Index, P, S: Integer;
  V: Single;
begin
  Ed := Editor;
  if Ed = nil then
    Exit;
  P := FPattern;
  if FPatternParameterId <> '' then
  begin
    Index := Ed.FindParameter(FPatternParameterId);
    if Index >= 0 then
    begin
      // the number shown (1..32) less its minimum: 0..31
      V := Ed.ParamToPlain(Index, Ed.ParamNormalised(Index)) - Ed.ParamToPlain(Index, 0);
      if not IsNan(V) then
        P := Round(Max(-1.0e6, Min(1.0e6, V)));
    end;
  end;
  S := -1;
  if FMeterIndex >= 0 then
  begin
    V := Ed.Meter(FMeterIndex);
    if not IsNan(V) and (V >= 0) and (V < PcfStepCount) then
      S := Round(V);
  end;
  if FShowPush and (FPushMeterIndex >= 0) then
    Show(P, S, Ed.Meter(FPushMeterIndex))
  else
    Show(P, S);
end;

procedure TPcfPatternDisplay.Paint(Canvas: TJuceCanvas);
var
  R, Inner, Meter: TJuceRect;
  W, L, H, M: Single;
  S: Integer;
  Bar: TJuceColor;
begin
  R := BoundsRect;
  Canvas.SetColor(Pick(FColor, PcfDisplay));
  Canvas.FillRoundRect(R, 2);
  Canvas.SetColor(Pick(FBorderColor, $FF000000));
  Canvas.DrawRoundRect(JuceInset(R, 0.5), 2, 1);

  Inner := JuceInset(R, 5);
  Meter := Inner;
  if FShowPush then
  begin
    // a strip 8 wide at the right, 5 from the bars
    Meter := JuceRect(Inner.X + Inner.W - 8, Inner.Y, 8, Inner.H);
    Inner.W := Max(0, Inner.W - 13);
  end;
  W := Inner.W / PcfStepCount;
  Bar := Pick(FTextColor, PcfLedRed);
  for S := 0 to PcfStepCount - 1 do
  begin
    L := PcfLevel(FPattern, S);
    H := Max(1.5, Inner.H * L);
    if S = FStep then
      Canvas.SetColor(PcfBrighter(Bar, 0.3))
    else if S mod 4 = 0 then
      Canvas.SetColor(PcfWithAlpha(Bar, 0.75))
    else
      Canvas.SetColor(PcfWithAlpha(Bar, 0.5));
    Canvas.FillRect(JuceRect(Inner.X + W * S + 1, Inner.Y + Inner.H - H, W - 2, H));
  end;

  if FShowPush then
  begin
    Canvas.SetColor($FF000000);
    Canvas.FillRect(Meter);
    M := FPush;
    if IsNan(M) or (M < 0) then
      M := 0
    else if M > 1 then
      M := 1;
    M := Meter.H * M;
    Canvas.SetColor(PcfPointer);
    Canvas.FillRect(JuceRect(Meter.X, Meter.Y + Meter.H - M, Meter.W, M));
  end;
end;

{ ---- replacing a stand-in ---- }

procedure CopyProperties(Source, Dest: TObject);
var
  Count, I: Integer;
  List: PPropList;
  Info, DestInfo: PPropInfo;
  Kind: TTypeKind;
  Name: string;
begin
  Count := GetPropList(Source.ClassInfo, tkProperties, nil);
  if Count <= 0 then
    Exit;
  GetMem(List, Count * SizeOf(PPropInfo));
  try
    GetPropList(Source.ClassInfo, tkProperties, List);
    for I := 0 to Count - 1 do
    begin
      Info := List^[I];
      Name := string(Info^.Name);
      // the name is set by the caller; the value comes from the parameter when bound
      if SameText(Name, 'Name') or SameText(Name, 'Value') then
        Continue;
      DestInfo := GetPropInfo(Dest, Name);
      if (DestInfo = nil) or (DestInfo^.SetProc = nil) or (DestInfo^.PropType <> Info^.PropType) then
        Continue;
      {$IFDEF FPC}
      Kind := Info^.PropType^.Kind;
      {$ELSE}
      Kind := Info^.PropType^^.Kind;
      {$ENDIF}
      case Kind of
        tkInteger, tkChar, tkWChar, tkEnumeration, {$IFDEF FPC} tkBool, tkQWord, {$ENDIF} tkSet, tkInt64:
          SetOrdProp(Dest, DestInfo, GetOrdProp(Source, Info));
        tkFloat:
          SetFloatProp(Dest, DestInfo, GetFloatProp(Source, Info));
        tkString, tkLString, tkWString, tkUString {$IFDEF FPC}, tkAString {$ENDIF}:
          SetStrProp(Dest, DestInfo, GetStrProp(Source, Info));
        tkMethod:
          SetMethodProp(Dest, DestInfo, GetMethodProp(Source, Info));
      end;
    end;
  finally
    FreeMem(List);
  end;
end;

function PcfReplaceControl(Old: TJuceControl; NewClass: TJuceControlClass): TJuceControl;
var
  Parent: TJuceControl;
  After: array of TJuceControl;
  I, At, N: Integer;
  OldName: string;
begin
  Result := nil;
  if (Old = nil) or (NewClass = nil) or (Old.ControlCount > 0) then
    Exit;
  Parent := Old.Parent;
  if Parent = nil then
    Exit;
  At := -1;
  for I := 0 to Parent.ControlCount - 1 do
    if Parent.Controls[I] = Old then
      At := I;
  // the controls drawn after the stand-in, which must stay after it
  N := 0;
  SetLength(After, Parent.ControlCount);
  for I := At + 1 to Parent.ControlCount - 1 do
  begin
    After[N] := Parent.Controls[I];
    Inc(N);
  end;

  Result := NewClass.Create(Parent);   // added last
  CopyProperties(Old, Result);
  OldName := Old.Name;
  Old.Free;
  Result.Name := OldName;

  for I := 0 to N - 1 do
  begin
    After[I].Parent := nil;
    After[I].Parent := Parent;
  end;
end;

end.
