{
  JuceCanvas.pas - the drawing surface PascalJUCE controls paint on.

  TJuceCanvas is abstract and knows nothing about JUCE: JuceUI implements it
  on the wrapper's drawing API (run time, inside the plug-in window), and a
  design-time package can implement it on a TCanvas, so the same control code
  paints in both places. Control code must only use this unit's types.

  Conventions:
    - coordinates are Single pixels, relative to the current origin
      (Translate) and clipped by ClipRect; SaveState / RestoreState nest;
    - colours are Cardinal $AARRGGBB (TJuceColor), alpha $FF = opaque;
    - angles are radians, clockwise from 12 o'clock (so a knob's minimum at
      -135 degrees is at about 7:30);
    - one current path (BeginPath ... FillPath / StrokePath).

  Works with Delphi and Free Pascal (Delphi mode).
}
unit JuceCanvas;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

type
  TJuceColor = Cardinal;

  TJuceRect = record
    X, Y, W, H: Single;
  end;

  TJuceFontStyle = (jfsBold, jfsItalic, jfsUnderline);
  TJuceFontStyles = set of TJuceFontStyle;
  TJuceAlign = (jaLeft, jaCenter, jaRight);
  TJuceVAlign = (jvaTop, jvaCenter, jvaBottom);
  TJuceLineJoin = (jljMiter, jljRound, jljBevel);
  TJuceLineCap = (jlcButt, jlcSquare, jlcRound);

  { A bitmap the canvas can draw. Created by the canvas back end (see
    TJuceEditor.AddImage); controls refer to images by name. }
  TJuceImage = class
  public
    function Width: Integer; virtual; abstract;
    function Height: Integer; virtual; abstract;
  end;

  TJuceCanvas = class
  public
    { Fill style for everything that follows (until the next Set...). }
    procedure SetColor(Color: TJuceColor); virtual; abstract;
    procedure SetLinearGradient(Color1: TJuceColor; X1, Y1: Single; Color2: TJuceColor; X2, Y2: Single); virtual; abstract;
    { Color1 at the centre, Color2 at the distance of (EdgeX, EdgeY). }
    procedure SetRadialGradient(Color1: TJuceColor; CX, CY: Single; Color2: TJuceColor; EdgeX, EdgeY: Single); virtual; abstract;

    procedure FillAll; virtual; abstract;
    procedure FillRect(const R: TJuceRect); virtual; abstract;
    procedure DrawRect(const R: TJuceRect; Thickness: Single); virtual; abstract;
    procedure FillRoundRect(const R: TJuceRect; Radius: Single); virtual; abstract;
    procedure DrawRoundRect(const R: TJuceRect; Radius, Thickness: Single); virtual; abstract;
    procedure FillEllipse(const R: TJuceRect); virtual; abstract;
    procedure DrawEllipse(const R: TJuceRect; Thickness: Single); virtual; abstract;
    procedure DrawLine(X1, Y1, X2, Y2, Thickness: Single); virtual; abstract;

    procedure BeginPath; virtual; abstract;
    procedure MoveTo(X, Y: Single); virtual; abstract;
    procedure LineTo(X, Y: Single); virtual; abstract;
    procedure QuadTo(CX, CY, X, Y: Single); virtual; abstract;
    procedure CubicTo(C1X, C1Y, C2X, C2Y, X, Y: Single); virtual; abstract;
    { An elliptical arc around (CX, CY); continues the current sub-path unless
      StartNewSubPath. }
    procedure AddArc(CX, CY, RX, RY, FromAngle, ToAngle: Single; StartNewSubPath: Boolean); virtual; abstract;
    procedure ClosePath; virtual; abstract;
    procedure FillPath; virtual; abstract;
    procedure StrokePath(Thickness: Single; Join: TJuceLineJoin; Cap: TJuceLineCap); virtual; abstract;

    { Name '' = the default sans-serif face. }
    procedure SetFont(const Name: string; Height: Single; Style: TJuceFontStyles); virtual; abstract;
    { One line, aligned in R, shortened with an ellipsis if it does not fit. }
    procedure DrawText(const Text: string; const R: TJuceRect; Align: TJuceAlign; VAlign: TJuceVAlign); virtual; abstract;
    { One line that is squeezed sideways (to 70% at most) before it is
      shortened, like JUCE's drawFittedText - for a caption in a narrow
      column. The default (for canvases that cannot squeeze) is DrawText. }
    procedure DrawFittedText(const Text: string; const R: TJuceRect; Align: TJuceAlign; VAlign: TJuceVAlign); virtual;
    { Width of one line of Text in the current font. }
    function TextWidth(const Text: string): Single; virtual; abstract;

    { Draws the Source rectangle of Image into Dest. }
    procedure DrawImage(Image: TJuceImage; const Dest, Source: TJuceRect; Opacity: Single); virtual; abstract;

    procedure SaveState; virtual; abstract;
    procedure RestoreState; virtual; abstract;
    { Intersects the clip region with R; False if nothing remains visible. }
    function ClipRect(const R: TJuceRect): Boolean; virtual; abstract;
    procedure Translate(DX, DY: Single); virtual; abstract;
  end;

function JuceRect(X, Y, W, H: Single): TJuceRect;
{ R shrunk by D on every side (never below zero size). }
function JuceInset(const R: TJuceRect; D: Single): TJuceRect;
function JuceRectContains(const R: TJuceRect; X, Y: Single): Boolean;

function JuceArgb(A, R, G, B: Byte): TJuceColor;
function JuceRgb(R, G, B: Byte): TJuceColor;
{ Alpha 0..1 replaces the colour's alpha. }
function JuceWithAlpha(Color: TJuceColor; Alpha: Single): TJuceColor;
{ Mix: T = 0 gives A, T = 1 gives B (alpha too). }
function JuceBlend(A, B: TJuceColor; T: Single): TJuceColor;
function JuceBrighter(Color: TJuceColor; Amount: Single): TJuceColor;
function JuceDarker(Color: TJuceColor; Amount: Single): TJuceColor;

{ Degrees to the canvas's angle convention (radians, clockwise from 12). }
function JuceDegToAngle(Degrees: Single): Single;
{ Point on a circle at a canvas angle. }
procedure JucePointOnCircle(CX, CY, Radius, Angle: Single; out X, Y: Single);

implementation

uses
  Math;

procedure TJuceCanvas.DrawFittedText(const Text: string; const R: TJuceRect; Align: TJuceAlign; VAlign: TJuceVAlign);
begin
  DrawText(Text, R, Align, VAlign);
end;

function JuceRect(X, Y, W, H: Single): TJuceRect;
begin
  Result.X := X;
  Result.Y := Y;
  Result.W := W;
  Result.H := H;
end;

function JuceInset(const R: TJuceRect; D: Single): TJuceRect;
begin
  Result.X := R.X + D;
  Result.Y := R.Y + D;
  Result.W := Max(0, R.W - 2 * D);
  Result.H := Max(0, R.H - 2 * D);
end;

function JuceRectContains(const R: TJuceRect; X, Y: Single): Boolean;
begin
  Result := (X >= R.X) and (Y >= R.Y) and (X < R.X + R.W) and (Y < R.Y + R.H);
end;

function JuceArgb(A, R, G, B: Byte): TJuceColor;
begin
  Result := (Cardinal(A) shl 24) or (Cardinal(R) shl 16) or (Cardinal(G) shl 8) or Cardinal(B);
end;

function JuceRgb(R, G, B: Byte): TJuceColor;
begin
  Result := JuceArgb($FF, R, G, B);
end;

function Channel(C: TJuceColor; Shift: Integer): Integer;
begin
  Result := Integer((C shr Shift) and $FF);
end;

function ClampByte(V: Single): Byte;
begin
  if IsNan(V) or (V <= 0) then
    Result := 0
  else if V >= 255 then
    Result := 255
  else
    Result := Byte(Round(V));
end;

function JuceWithAlpha(Color: TJuceColor; Alpha: Single): TJuceColor;
begin
  Result := (Color and $00FFFFFF) or (Cardinal(ClampByte(Alpha * 255)) shl 24);
end;

function JuceBlend(A, B: TJuceColor; T: Single): TJuceColor;
begin
  if IsNan(T) or (T <= 0) then
    T := 0
  else if T > 1 then
    T := 1;
  Result := JuceArgb(ClampByte(Channel(A, 24) + (Channel(B, 24) - Channel(A, 24)) * T),
                     ClampByte(Channel(A, 16) + (Channel(B, 16) - Channel(A, 16)) * T),
                     ClampByte(Channel(A, 8) + (Channel(B, 8) - Channel(A, 8)) * T),
                     ClampByte(Channel(A, 0) + (Channel(B, 0) - Channel(A, 0)) * T));
end;

function JuceBrighter(Color: TJuceColor; Amount: Single): TJuceColor;
begin
  Result := JuceBlend(Color, (Color and $FF000000) or $FFFFFF, Amount);
end;

function JuceDarker(Color: TJuceColor; Amount: Single): TJuceColor;
begin
  Result := JuceBlend(Color, Color and $FF000000, Amount);
end;

function JuceDegToAngle(Degrees: Single): Single;
begin
  Result := Degrees * Pi / 180;
end;

procedure JucePointOnCircle(CX, CY, Radius, Angle: Single; out X, Y: Single);
begin
  X := CX + Radius * Sin(Angle);
  Y := CY - Radius * Cos(Angle);
end;

end.
