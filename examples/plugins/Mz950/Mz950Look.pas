// Mz950 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// How the window looks, in one place: the Object Pascal counterpart of Plugin/Source/Look.h
// and Look.cpp (namespace look, and Mz950LookAndFeel's drawing).
//
// The same three ideas:
//   - every group of controls sits in a PANEL, a card with a small uppercase title;
//   - one knob everywhere: a dark disc, a bright arc that shows the value, the value as plain
//     text under it and the name under that;
//   - colour MEANS something: amber is what is on the disk, cyan an offset laid on top of it
//     while you play, violet one of the extras the S950 never had.
//
// PascalJUCE has no LookAndFeel to override, so what Mz950LookAndFeel draws for JUCE's own
// components (drawRotarySlider, drawButtonBackground, drawToggleButton, drawComboBox,
// drawTabButton) is here as plain procedures on a TJuceCanvas, which the controls in
// Mz950Controls call from their Paint. The numbers are the C++'s.
unit Mz950Look;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  JuceCanvas;

const
  // ------------------------------------------------------------------ the palette
  ColWindow     = TJuceColor($FF1A1D22);
  ColPanel      = TJuceColor($FF22262C);
  ColPanelEdge  = TJuceColor($FF2E333B);
  ColRaised     = TJuceColor($FF2B3038);   // knob bodies, buttons, boxes
  ColRaisedEdge = TJuceColor($FF3A404A);
  ColTrack      = TJuceColor($FF353B45);   // the unlit part of a knob's arc

  ColText       = TJuceColor($FFD6DDE8);
  ColDim        = TJuceColor($FF8A93A3);
  ColFaint      = TJuceColor($FF5C6472);

  ColProgram    = TJuceColor($FFE9A33A);   // amber: on the disk
  ColPerform    = TJuceColor($FF45C8DC);   // cyan: an offset on top of it
  ColExtra      = TJuceColor($FFA78BFA);   // violet: not on the S950
  ColNeutral    = TJuceColor($FFC9D1DC);   // gain, and anything that is none of those

  ColLink       = TJuceColor($FF6AB0FF);   // the project link's blue

  // Segoe UI is on every Windows since Vista; elsewhere JUCE falls back to its own sans.
  FontFace = 'Segoe UI';

  // The panel's header and padding (look::Panel).
  PanelHeaderHeight = 24;
  PanelPad = 8;

  // JUCE's default rotary sweep: from 1.2 pi to 2.8 pi, clockwise from 12 o'clock.
  KnobStartAngle = 1.2 * Pi;
  KnobEndAngle = 2.8 * Pi;

// look::font and look::bold.
procedure UseFont(Canvas: TJuceCanvas; Size: Single; Bold: Boolean = False);

// juce::Colour::brighter and darker (not a blend by the amount: 1 - 1 / (1 + amount)).
function JBrighter(C: TJuceColor; Amount: Single): TJuceColor;
function JDarker(C: TJuceColor; Amount: Single): TJuceColor;
// juce::Colour::withMultipliedAlpha.
function JMulAlpha(C: TJuceColor; Factor: Single): TJuceColor;

// look::Panel::paint: the card, and its title with a short rule under it in its colour; the
// note at the right only where it fits beside the title.
procedure PaintPanelCard(Canvas: TJuceCanvas; W, H: Single; const Title, Note: string;
  Accent: TJuceColor);

// Mz950LookAndFeel::drawRotarySlider, in the area (X, Y, W, H) the slider leaves above its
// value box. Pos 0..1 along the sweep.
procedure PaintRotary(Canvas: TJuceCanvas; X, Y, W, H, Pos: Single; Bipolar: Boolean;
  Fill: TJuceColor; Enabled: Boolean);

// Mz950LookAndFeel::drawButtonBackground: a rounded box, lit in the button's colour when on.
procedure PaintButtonBackground(Canvas: TJuceCanvas; W, H: Single; IsOn: Boolean; Lit: TJuceColor;
  Highlighted, Down: Boolean);
// LookAndFeel_V2::drawButtonText, in the C++'s 12.5 font.
procedure PaintButtonText(Canvas: TJuceCanvas; W, H: Single; const Text: string; Color: TJuceColor;
  Enabled: Boolean);

// Mz950LookAndFeel::drawToggleButton: a pill with a thumb, and the switch's name beside it.
procedure PaintToggle(Canvas: TJuceCanvas; W, H: Single; IsOn: Boolean; Lit: TJuceColor;
  Highlighted, Enabled: Boolean; const Text: string);

// Mz950LookAndFeel::drawComboBox and the box's text (LookAndFeel_V4::positionComboBoxText).
procedure PaintComboBox(Canvas: TJuceCanvas; W, H: Single; Outline: TJuceColor; const Text: string;
  Placeholder, Enabled: Boolean);

// A juce::Label's text: inside its 1/5 px border, squeezed to fit as drawFittedText does.
procedure PaintLabelText(Canvas: TJuceCanvas; W, H: Single; const Text: string; Size: Single;
  Bold: Boolean; Color: TJuceColor; Align: TJuceAlign; Enabled: Boolean);

// A 1 px line, as juce::Graphics::drawHorizontalLine / drawVerticalLine.
procedure HLine(Canvas: TJuceCanvas; Y, X1, X2: Single);
procedure VLine(Canvas: TJuceCanvas; X, Y1, Y2: Single);

implementation

uses
  Math;

procedure UseFont(Canvas: TJuceCanvas; Size: Single; Bold: Boolean);
begin
  if Bold then
    Canvas.SetFont(FontFace, Size, [jfsBold])
  else
    Canvas.SetFont(FontFace, Size, []);
end;

function Chan(C: TJuceColor; Shift: Integer): Integer;
begin
  Result := Integer((C shr Shift) and $FF);
end;

function ToByte(V: Single): Cardinal;
begin
  if not (V > 0) then
    Result := 0
  else if V >= 255 then
    Result := 255
  else
    Result := Cardinal(Round(V));
end;

function JBrighter(C: TJuceColor; Amount: Single): TJuceColor;
var
  F: Single;
begin
  F := 1.0 / (1.0 + Amount);
  Result := (C and $FF000000)
    or (ToByte(255 - F * (255 - Chan(C, 16))) shl 16)
    or (ToByte(255 - F * (255 - Chan(C, 8))) shl 8)
    or ToByte(255 - F * (255 - Chan(C, 0)));
end;

function JDarker(C: TJuceColor; Amount: Single): TJuceColor;
var
  F: Single;
begin
  F := 1.0 / (1.0 + Amount);
  Result := (C and $FF000000)
    or (ToByte(F * Chan(C, 16)) shl 16)
    or (ToByte(F * Chan(C, 8)) shl 8)
    or ToByte(F * Chan(C, 0));
end;

function JMulAlpha(C: TJuceColor; Factor: Single): TJuceColor;
begin
  Result := (C and $00FFFFFF) or (ToByte(Chan(C, 24) * Factor) shl 24);
end;

procedure HLine(Canvas: TJuceCanvas; Y, X1, X2: Single);
begin
  if X2 > X1 then
    Canvas.FillRect(JuceRect(X1, Y, X2 - X1, 1));
end;

procedure VLine(Canvas: TJuceCanvas; X, Y1, Y2: Single);
begin
  if Y2 > Y1 then
    Canvas.FillRect(JuceRect(X, Y1, 1, Y2 - Y1));
end;

procedure PaintPanelCard(Canvas: TJuceCanvas; W, H: Single; const Title, Note: string;
  Accent: TJuceColor);
var
  HeadX, HeadW, Wide, NoteWide: Single;
begin
  Canvas.SetColor(ColPanel);
  Canvas.FillRoundRect(JuceRect(0, 0, W, H), 6);
  Canvas.SetColor(ColPanelEdge);
  Canvas.DrawRoundRect(JuceRect(0.5, 0.5, W - 1, H - 1), 6, 1);

  if (Title = '') and (Note = '') then
    Exit;

  HeadX := PanelPad + 2;
  HeadW := W - 2 * HeadX;

  UseFont(Canvas, 11, True);
  Canvas.SetColor(Accent);
  Canvas.DrawText(Title, JuceRect(HeadX, 0, HeadW, PanelHeaderHeight), jaLeft, jvaCenter);

  Wide := Round(Canvas.TextWidth(Title));      // getStringWidthInt rounds
  Canvas.SetColor(JuceWithAlpha(Accent, 0.55));
  Canvas.FillRect(JuceRect(HeadX, PanelHeaderHeight - 3, Max(Wide, 24), 2));

  if Note <> '' then
  begin
    UseFont(Canvas, 10);
    NoteWide := Round(Canvas.TextWidth(Note));
    if Wide + 16 + NoteWide <= HeadW then
    begin
      Canvas.SetColor(ColDim);
      Canvas.DrawText(Note, JuceRect(HeadX, 0, HeadW, PanelHeaderHeight), jaRight, jvaCenter);
    end;
  end;
end;

procedure StrokeArc(Canvas: TJuceCanvas; CX, CY, R, A1, A2, Width: Single);
begin
  Canvas.BeginPath;
  Canvas.AddArc(CX, CY, R, R, A1, A2, True);
  Canvas.StrokePath(Width, jljRound, jlcRound);
end;

procedure PaintRotary(Canvas: TJuceCanvas; X, Y, W, H, Pos: Single; Bipolar: Boolean;
  Fill: TJuceColor; Enabled: Boolean);
var
  Radius, CX, CY, Angle, ArcW, From, TickR, PX, PY, BodyR, X1, Y1, X2, Y2: Single;
begin
  Radius := Min(W, H) / 2 - 3;
  CX := X + W / 2;
  CY := Y + H / 2;
  if Radius < 6 then
    Exit;
  if not (Pos > 0) then Pos := 0;
  if Pos > 1 then Pos := 1;

  Angle := KnobStartAngle + Pos * (KnobEndAngle - KnobStartAngle);
  ArcW := Max(2.0, Min(3.5, Radius * 0.11));

  // the whole sweep, unlit
  Canvas.SetColor(ColTrack);
  StrokeArc(Canvas, CX, CY, Radius, KnobStartAngle, KnobEndAngle, ArcW);

  // lit from the start - or, for an offset, from the top, where it does nothing
  if Bipolar then
    From := (KnobStartAngle + KnobEndAngle) / 2
  else
    From := KnobStartAngle;

  if Abs(Angle - From) > 0.01 then
  begin
    if Enabled then
      Canvas.SetColor(Fill)
    else
      Canvas.SetColor(JuceWithAlpha(Fill, 0.35));
    StrokeArc(Canvas, CX, CY, Radius, Min(From, Angle), Max(From, Angle), ArcW);
  end;

  // a bipolar knob keeps a tick at its rest position, so zero is a place, not a guess
  if Bipolar then
  begin
    TickR := Radius + ArcW * 0.5 + 2.5;
    JucePointOnCircle(CX, CY, TickR, From, PX, PY);
    Canvas.SetColor(ColDim);
    Canvas.FillEllipse(JuceRect(PX - 1.5, PY - 1.5, 3, 3));
  end;

  BodyR := Radius - ArcW - 3;
  Canvas.SetColor(ColRaised);
  Canvas.FillEllipse(JuceRect(CX - BodyR, CY - BodyR, BodyR * 2, BodyR * 2));
  Canvas.SetColor(ColRaisedEdge);
  Canvas.DrawEllipse(JuceRect(CX - BodyR, CY - BodyR, BodyR * 2, BodyR * 2), 1);

  JucePointOnCircle(CX, CY, BodyR * 0.45, Angle, X1, Y1);
  JucePointOnCircle(CX, CY, BodyR * 0.88, Angle, X2, Y2);
  if Enabled then
    Canvas.SetColor(ColText)
  else
    Canvas.SetColor(ColDim);
  Canvas.BeginPath;
  Canvas.MoveTo(X1, Y1);
  Canvas.LineTo(X2, Y2);
  Canvas.StrokePath(2.2, jljRound, jlcRound);
end;

procedure PaintButtonBackground(Canvas: TJuceCanvas; W, H: Single; IsOn: Boolean; Lit: TJuceColor;
  Highlighted, Down: Boolean);
var
  Fill: TJuceColor;
  R: TJuceRect;
begin
  R := JuceRect(0.5, 0.5, W - 1, H - 1);
  if IsOn then
    Fill := JuceWithAlpha(Lit, 0.22)
  else
    Fill := ColRaised;
  if Down then
    Fill := JBrighter(Fill, 0.15)
  else if Highlighted then
    Fill := JBrighter(Fill, 0.07);
  Canvas.SetColor(Fill);
  Canvas.FillRoundRect(R, 4);
  if IsOn then
    Canvas.SetColor(JuceWithAlpha(Lit, 0.8))
  else
    Canvas.SetColor(ColRaisedEdge);
  Canvas.DrawRoundRect(R, 4, 1);
end;

procedure PaintButtonText(Canvas: TJuceCanvas; W, H: Single; const Text: string; Color: TJuceColor;
  Enabled: Boolean);
var
  YIndent, Corner, FontH, Indent: Integer;
begin
  // LookAndFeel_V2::drawButtonText's indents
  YIndent := Min(4, Round(H * 0.3));
  Corner := Trunc(Min(H, W)) div 2;
  FontH := Round(12.5 * 0.6);
  Indent := Min(FontH, 2 + Corner div 2);
  UseFont(Canvas, 12.5);
  if Enabled then
    Canvas.SetColor(Color)
  else
    Canvas.SetColor(JMulAlpha(Color, 0.5));
  Canvas.DrawFittedText(Text, JuceRect(Indent, YIndent, W - 2 * Indent, H - 2 * YIndent), jaCenter, jvaCenter);
end;

procedure PaintToggle(Canvas: TJuceCanvas; W, H: Single; IsOn: Boolean; Lit: TJuceColor;
  Highlighted, Enabled: Boolean; const Text: string);
const
  PillW = 30;
  PillH = 16;
var
  Pill: TJuceRect;
  Fill: TJuceColor;
  ThumbR, ThumbX, PY: Single;
begin
  PY := Trunc(H / 2) - PillH / 2;   // r.getCentreY() is an int
  Pill := JuceRect(0, PY, PillW, PillH);

  if IsOn then
    Fill := Lit
  else
    Fill := ColRaisedEdge;
  if Highlighted then
    Fill := JBrighter(Fill, 0.1);
  if Enabled then
    Canvas.SetColor(Fill)
  else
    Canvas.SetColor(JuceWithAlpha(Fill, 0.4));
  Canvas.FillRoundRect(Pill, PillH / 2);

  ThumbR := PillH / 2 - 2.5;
  if IsOn then
  begin
    ThumbX := Pill.X + Pill.W - 2.5 - ThumbR;
    Canvas.SetColor(ColWindow);
  end
  else
  begin
    ThumbX := Pill.X + 2.5 + ThumbR;
    Canvas.SetColor(ColDim);
  end;
  Canvas.FillEllipse(JuceRect(ThumbX - ThumbR, Pill.Y + PillH / 2 - ThumbR, ThumbR * 2, ThumbR * 2));

  if Enabled then
    Canvas.SetColor(ColText)
  else
    Canvas.SetColor(ColDim);
  UseFont(Canvas, 12);
  Canvas.DrawText(Text, JuceRect(PillW + 8, 0, Max(0, W - PillW - 8), H), jaLeft, jvaCenter);
end;

procedure PaintComboBox(Canvas: TJuceCanvas; W, H: Single; Outline: TJuceColor; const Text: string;
  Placeholder, Enabled: Boolean);
var
  R: TJuceRect;
  CX, CY: Single;
  TextColor: TJuceColor;
begin
  R := JuceRect(0.5, 0.5, W - 1, H - 1);
  Canvas.SetColor(ColRaised);
  Canvas.FillRoundRect(R, 4);
  Canvas.SetColor(Outline);
  Canvas.DrawRoundRect(R, 4, 1);

  // a small chevron, not an arrow in a box
  CX := W - 22 + 3 + 4;
  CY := H / 2;
  Canvas.SetColor(ColDim);
  Canvas.BeginPath;
  Canvas.MoveTo(CX - 4, CY - 2);
  Canvas.LineTo(CX, CY + 2.5);
  Canvas.LineTo(CX + 4, CY - 2);
  Canvas.StrokePath(1.6, jljRound, jlcRound);

  // the box's label: (1, 1, w - 30, h - 2), inside a label's 1/5 px border
  TextColor := ColText;
  if Placeholder then
    TextColor := JMulAlpha(TextColor, 0.5);
  if not Enabled then
    TextColor := JMulAlpha(TextColor, 0.5);
  UseFont(Canvas, 13);
  Canvas.SetColor(TextColor);
  Canvas.DrawFittedText(Text, JuceRect(1 + 5, 1 + 1, Max(0, W - 30 - 10), Max(0, H - 2 - 2)), jaLeft, jvaCenter);
end;

procedure PaintLabelText(Canvas: TJuceCanvas; W, H: Single; const Text: string; Size: Single;
  Bold: Boolean; Color: TJuceColor; Align: TJuceAlign; Enabled: Boolean);
begin
  if Text = '' then
    Exit;
  UseFont(Canvas, Size, Bold);
  if Enabled then
    Canvas.SetColor(Color)
  else
    Canvas.SetColor(JMulAlpha(Color, 0.5));
  Canvas.DrawFittedText(Text, JuceRect(5, 1, Max(0, W - 10), Max(0, H - 2)), Align, jvaCenter);
end;

end.
