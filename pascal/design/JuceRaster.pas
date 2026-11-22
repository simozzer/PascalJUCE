{
  JuceRaster.pas - a TJuceCanvas that renders into a 32-bit pixel buffer.

  This is the engine behind the design-time TCanvas back end (JuceTCanvas):
  the IDE's TCanvas (GDI on Windows) has no anti-aliasing, gradients or
  alpha, so drawing control graphics straight onto it would look nothing
  like the plug-in. Instead shapes are rasterised here, in plain Pascal,
  with the same semantics as JUCE's software renderer:

    - anti-aliased polygons by exact area coverage (signed-area
      accumulation), non-zero winding;
    - strokes with round / mitre / bevel joins and butt / square / round caps;
    - linear and radial two-colour gradients, premultiplied alpha;
    - JUCE's shape definitions (rounded rectangles with 0.45 cubic corners,
      circle outlines as a ring centred on the edge, drawLine as a filled
      rectangle, clip regions snapped to whole pixels);
    - images (bilinear) and text, where text comes from a TJuceTextRenderer
      (the LCL or VCL font engine; see JuceTCanvas).

  Coordinates are scaled by Scale (the designer's PPI / 96), so a layout
  designed at 144 dpi is drawn at 1.5x like the IDE shows it.

  No LCL or VCL: works with Delphi and Free Pascal (Delphi mode).
}
unit JuceRaster;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  SysUtils, Math, JuceCanvas;

type
  { Premultiplied $AARRGGBB, row-major. }
  TJucePixelArray = array of Cardinal;

  { An image the raster canvas can draw. }
  TJuceRasterImage = class(TJuceImage)
  private
    FW, FH: Integer;
    FPixels: TJucePixelArray;
  public
    constructor Create(AWidth, AHeight: Integer);
    function Width: Integer; override;
    function Height: Integer; override;
    { Straight (not premultiplied) $AARRGGBB. }
    procedure SetPixel(X, Y: Integer; Argb: Cardinal);
    function GetPixel(X, Y: Integer): Cardinal;
    property Pixels: TJucePixelArray read FPixels;
  end;

  { Text for the raster canvas, from a real font engine. Heights are in
    device pixels and mean what JUCE means: ascent + descent. }
  TJuceTextRenderer = class
  public
    function TextWidth(const Text, FontName: string; HeightPx: Single; Style: TJuceFontStyles): Single; virtual; abstract;
    { A coverage mask (0..255, row-major, W x H) of one line of Text whose
      line box (top of the ascent) starts at (Pad, Pad). }
    procedure RenderMask(const Text, FontName: string; HeightPx: Single; Style: TJuceFontStyles;
      out Mask: TBytes; out W, H, Pad: Integer); virtual; abstract;
    { Ascent: the font's exact ascent at HeightPx (what JUCE lays out with).
      MaskBaseline: the row of RenderMask's baseline, or -1 if unknown (the
      mask's line box is then placed at its top). }
    procedure Metrics(const FontName: string; HeightPx: Single; Style: TJuceFontStyles;
      out Ascent: Single; out MaskBaseline: Integer); virtual;
  end;

  TJucePointD = record
    X, Y: Double;
  end;
  TJucePolygon = array of TJucePointD;

  TJuceFillKind = (jfkSolid, jfkLinear, jfkRadial);

  TJuceRasterState = record
    TX, TY: Double;                 { user translation }
    ClipX0, ClipY0, ClipX1, ClipY1: Integer; { device, end exclusive }
    FillKind: TJuceFillKind;
    Color1, Color2: Cardinal;       { premultiplied }
    GX1, GY1, GX2, GY2: Double;     { gradient points, device }
    FontName: string;
    FontHeight: Single;
    FontStyle: TJuceFontStyles;
  end;

  TJuceRasterCanvas = class(TJuceCanvas)
  private
    FW, FH: Integer;
    FScale: Double;
    FPixels: TJucePixelArray;
    FState: TJuceRasterState;
    FStack: array of TJuceRasterState;
    FDepth: Integer;
    FPath: array of TJucePolygon;   { device coordinates }
    FPathClosed: array of Boolean;
    FText: TJuceTextRenderer;
    FAcc: array of Single;
    procedure DevPoint(X, Y: Double; out DX, DY: Double);
    function CurrentSub: Integer;
    procedure AddPathPoint(DX, DY: Double);
    procedure FillPolygons(const Polys: array of TJucePolygon);
    procedure AccumulateLine(X0, Y0, X1, Y1: Double; W, H: Integer);
    procedure AccumulateEdge(X0, Y0, X1, Y1: Double; W, H: Integer);
    function ColorAt(PX, PY: Integer): Cardinal;
    procedure BlendPixel(PX, PY: Integer; Color: Cardinal; Coverage: Single);
    procedure StrokePolyline(const P: TJucePolygon; Closed: Boolean; HalfWidth: Double;
      Join: TJuceLineJoin; Cap: TJuceLineCap);
    function RectPolygon(const R: TJuceRect): TJucePolygon;
    function EllipsePolygon(CX, CY, RX, RY: Double; Reverse: Boolean): TJucePolygon;
    function RoundRectPolygon(const R: TJuceRect; Radius: Single): TJucePolygon;
    procedure PaintText(const Text: string; const R: TJuceRect; Align: TJuceAlign; VAlign: TJuceVAlign; Fit: Boolean);
  public
    constructor Create(AWidth, AHeight: Integer; AScale: Single = 1);
    { Fill the whole buffer (ignores clip and translation). }
    procedure Clear(Color: TJuceColor);
    { Straight $AARRGGBB of a device pixel. }
    function PixelAt(X, Y: Integer): Cardinal;
    property Width: Integer read FW;
    property Height: Integer read FH;
    property Scale: Double read FScale;
    property Pixels: TJucePixelArray read FPixels;
    { Not owned. Without one, text is not drawn and widths are estimated. }
    property TextRenderer: TJuceTextRenderer read FText write FText;

    procedure SetColor(Color: TJuceColor); override;
    procedure SetLinearGradient(Color1: TJuceColor; X1, Y1: Single; Color2: TJuceColor; X2, Y2: Single); override;
    procedure SetRadialGradient(Color1: TJuceColor; CX, CY: Single; Color2: TJuceColor; EdgeX, EdgeY: Single); override;
    procedure FillAll; override;
    procedure FillRect(const R: TJuceRect); override;
    procedure DrawRect(const R: TJuceRect; Thickness: Single); override;
    procedure FillRoundRect(const R: TJuceRect; Radius: Single); override;
    procedure DrawRoundRect(const R: TJuceRect; Radius, Thickness: Single); override;
    procedure FillEllipse(const R: TJuceRect); override;
    procedure DrawEllipse(const R: TJuceRect; Thickness: Single); override;
    procedure DrawLine(X1, Y1, X2, Y2, Thickness: Single); override;
    procedure BeginPath; override;
    procedure MoveTo(X, Y: Single); override;
    procedure LineTo(X, Y: Single); override;
    procedure QuadTo(CX, CY, X, Y: Single); override;
    procedure CubicTo(C1X, C1Y, C2X, C2Y, X, Y: Single); override;
    procedure AddArc(CX, CY, RX, RY, FromAngle, ToAngle: Single; StartNewSubPath: Boolean); override;
    procedure ClosePath; override;
    procedure FillPath; override;
    procedure StrokePath(Thickness: Single; Join: TJuceLineJoin; Cap: TJuceLineCap); override;
    procedure SetFont(const Name: string; Height: Single; Style: TJuceFontStyles); override;
    procedure DrawText(const Text: string; const R: TJuceRect; Align: TJuceAlign; VAlign: TJuceVAlign); override;
    procedure DrawFittedText(const Text: string; const R: TJuceRect; Align: TJuceAlign; VAlign: TJuceVAlign); override;
    function TextWidth(const Text: string): Single; override;
    procedure DrawImage(Image: TJuceImage; const Dest, Source: TJuceRect; Opacity: Single); override;
    procedure SaveState; override;
    procedure RestoreState; override;
    function ClipRect(const R: TJuceRect): Boolean; override;
    procedure Translate(DX, DY: Single); override;
  end;

{ Straight $AARRGGBB to premultiplied, and back. }
function JucePremultiply(C: Cardinal): Cardinal;
function JuceUnpremultiply(C: Cardinal): Cardinal;

implementation

const
  MaxSaveDepth = 256;
  MaxPathPoints = 200000;
  CurveTolerance = 0.1; { device pixels }

function JucePremultiply(C: Cardinal): Cardinal;
var
  A: Cardinal;
begin
  A := C shr 24;
  if A = 255 then
    Exit(C);
  if A = 0 then
    Exit(0);
  Result := (A shl 24) or ((((C shr 16) and $FF) * A + 127) div 255 shl 16) or
    ((((C shr 8) and $FF) * A + 127) div 255 shl 8) or (((C and $FF) * A + 127) div 255);
end;

function JuceUnpremultiply(C: Cardinal): Cardinal;
var
  A: Cardinal;
begin
  A := C shr 24;
  if (A = 255) or (A = 0) then
    Exit(C);
  Result := (A shl 24) or (Min(255, (((C shr 16) and $FF) * 255 + A div 2) div A) shl 16) or
    (Min(255, (((C shr 8) and $FF) * 255 + A div 2) div A) shl 8) or Min(255, ((C and $FF) * 255 + A div 2) div A);
end;

{ Premultiplied colours mixed: T = 0 gives A. }
function MixPremul(A, B: Cardinal; T: Double): Cardinal;
var
  K: Integer;
  S: Cardinal;
  CA, CB: Integer;
begin
  if T <= 0 then
    Exit(A);
  if T >= 1 then
    Exit(B);
  Result := 0;
  for K := 0 to 3 do
  begin
    S := K * 8;
    CA := (A shr S) and $FF;
    CB := (B shr S) and $FF;
    Result := Result or (Cardinal(Round(CA + (CB - CA) * T)) shl S);
  end;
end;

function Pt(X, Y: Double): TJucePointD;
begin
  Result.X := X;
  Result.Y := Y;
end;

function SignedArea(const P: TJucePolygon): Double;
var
  I, J: Integer;
begin
  Result := 0;
  for I := 0 to High(P) do
  begin
    J := (I + 1) mod Length(P);
    Result := Result + P[I].X * P[J].Y - P[J].X * P[I].Y;
  end;
  Result := Result / 2;
end;

procedure Reverse(var P: TJucePolygon);
var
  I: Integer;
  T: TJucePointD;
begin
  for I := 0 to Length(P) div 2 - 1 do
  begin
    T := P[I];
    P[I] := P[High(P) - I];
    P[High(P) - I] := T;
  end;
end;

{ Makes the polygon's orientation match Sign (> 0 or < 0). }
procedure Orient(var P: TJucePolygon; Sign: Double);
var
  A: Double;
begin
  A := SignedArea(P);
  if ((A < 0) and (Sign > 0)) or ((A > 0) and (Sign < 0)) then
    Reverse(P);
end;

procedure TJuceTextRenderer.Metrics(const FontName: string; HeightPx: Single; Style: TJuceFontStyles;
  out Ascent: Single; out MaskBaseline: Integer);
begin
  Ascent := HeightPx * 0.8;
  MaskBaseline := -1;
end;

{ ---------------------------------------------------------------------------- }
{ TJuceRasterImage                                                             }
{ ---------------------------------------------------------------------------- }

constructor TJuceRasterImage.Create(AWidth, AHeight: Integer);
begin
  inherited Create;
  FW := Max(0, Min(AWidth, 16384));
  FH := Max(0, Min(AHeight, 16384));
  SetLength(FPixels, FW * FH);
end;

function TJuceRasterImage.Width: Integer;
begin
  Result := FW;
end;

function TJuceRasterImage.Height: Integer;
begin
  Result := FH;
end;

procedure TJuceRasterImage.SetPixel(X, Y: Integer; Argb: Cardinal);
begin
  if (X >= 0) and (Y >= 0) and (X < FW) and (Y < FH) then
    FPixels[Y * FW + X] := JucePremultiply(Argb);
end;

function TJuceRasterImage.GetPixel(X, Y: Integer): Cardinal;
begin
  if (X >= 0) and (Y >= 0) and (X < FW) and (Y < FH) then
    Result := JuceUnpremultiply(FPixels[Y * FW + X])
  else
    Result := 0;
end;

{ ---------------------------------------------------------------------------- }
{ TJuceRasterCanvas                                                            }
{ ---------------------------------------------------------------------------- }

constructor TJuceRasterCanvas.Create(AWidth, AHeight: Integer; AScale: Single);
begin
  inherited Create;
  FW := Max(0, Min(AWidth, 16384));
  FH := Max(0, Min(AHeight, 16384));
  if IsNan(AScale) or (AScale <= 0.1) or (AScale > 10) then
    AScale := 1;
  FScale := AScale;
  SetLength(FPixels, FW * FH);
  FState.ClipX1 := FW;
  FState.ClipY1 := FH;
  FState.FillKind := jfkSolid;
  FState.Color1 := $FF000000;
  FState.FontHeight := 14;
  SetLength(FStack, 0);
end;

procedure TJuceRasterCanvas.Clear(Color: TJuceColor);
var
  I: Integer;
  C: Cardinal;
begin
  C := JucePremultiply(Color);
  for I := 0 to High(FPixels) do
    FPixels[I] := C;
end;

function TJuceRasterCanvas.PixelAt(X, Y: Integer): Cardinal;
begin
  if (X >= 0) and (Y >= 0) and (X < FW) and (Y < FH) then
    Result := JuceUnpremultiply(FPixels[Y * FW + X])
  else
    Result := 0;
end;

procedure TJuceRasterCanvas.DevPoint(X, Y: Double; out DX, DY: Double);
begin
  DX := (X + FState.TX) * FScale;
  DY := (Y + FState.TY) * FScale;
end;

{ --- fill style ---------------------------------------------------------- }

procedure TJuceRasterCanvas.SetColor(Color: TJuceColor);
begin
  FState.FillKind := jfkSolid;
  FState.Color1 := JucePremultiply(Color);
end;

procedure TJuceRasterCanvas.SetLinearGradient(Color1: TJuceColor; X1, Y1: Single; Color2: TJuceColor; X2, Y2: Single);
begin
  { like the wrapper: a degenerate gradient is the end colour }
  if Sqrt(Sqr(X2 - X1) + Sqr(Y2 - Y1)) < 0.5 then
  begin
    SetColor(Color2);
    Exit;
  end;
  FState.FillKind := jfkLinear;
  FState.Color1 := JucePremultiply(Color1);
  FState.Color2 := JucePremultiply(Color2);
  DevPoint(X1, Y1, FState.GX1, FState.GY1);
  DevPoint(X2, Y2, FState.GX2, FState.GY2);
end;

procedure TJuceRasterCanvas.SetRadialGradient(Color1: TJuceColor; CX, CY: Single; Color2: TJuceColor; EdgeX, EdgeY: Single);
begin
  if Sqrt(Sqr(EdgeX - CX) + Sqr(EdgeY - CY)) < 0.5 then
  begin
    SetColor(Color2);
    Exit;
  end;
  FState.FillKind := jfkRadial;
  FState.Color1 := JucePremultiply(Color1);
  FState.Color2 := JucePremultiply(Color2);
  DevPoint(CX, CY, FState.GX1, FState.GY1);
  DevPoint(EdgeX, EdgeY, FState.GX2, FState.GY2);
end;

function TJuceRasterCanvas.ColorAt(PX, PY: Integer): Cardinal;
var
  X, Y, DX, DY, L2, T: Double;
begin
  case FState.FillKind of
    jfkLinear:
      begin
        X := PX;
        Y := PY;
        DX := FState.GX2 - FState.GX1;
        DY := FState.GY2 - FState.GY1;
        L2 := DX * DX + DY * DY;
        T := ((X - FState.GX1) * DX + (Y - FState.GY1) * DY) / L2;
        Result := MixPremul(FState.Color1, FState.Color2, T);
      end;
    jfkRadial:
      begin
        X := PX;
        Y := PY;
        L2 := Sqrt(Sqr(FState.GX2 - FState.GX1) + Sqr(FState.GY2 - FState.GY1));
        T := Sqrt(Sqr(X - FState.GX1) + Sqr(Y - FState.GY1)) / L2;
        Result := MixPremul(FState.Color1, FState.Color2, T);
      end;
  else
    Result := FState.Color1;
  end;
end;

procedure TJuceRasterCanvas.BlendPixel(PX, PY: Integer; Color: Cardinal; Coverage: Single);
var
  P: ^Cardinal;
  A, Inv, K: Cardinal;
  D, S, R: Cardinal;
  Shift: Integer;
begin
  if Coverage <= 0 then
    Exit;
  if Coverage < 1 then
    Color := MixPremul(0, Color, Coverage);
  A := Color shr 24;
  if A = 0 then
    Exit;
  P := @FPixels[PY * FW + PX];
  if A = 255 then
  begin
    P^ := Color;
    Exit;
  end;
  Inv := 255 - A;
  D := P^;
  R := 0;
  for K := 0 to 3 do
  begin
    Shift := K * 8;
    S := (Color shr Shift) and $FF;
    R := R or (Min(255, S + (((D shr Shift) and $FF) * Inv + 127) div 255) shl Shift);
  end;
  P^ := R;
end;

{ --- polygon fill ---------------------------------------------------------- }

{ One edge into the accumulation buffer (local coordinates, 0 <= x <= W).
  Area-coverage accumulation after font-rs / stb_truetype. }
procedure TJuceRasterCanvas.AccumulateLine(X0, Y0, X1, Y1: Double; W, H: Integer);
var
  Dir, DXDY, X, XNext, DY, D, XA, XB, XAFloor, XBCeil, XMF, S, X0F, X1F, A0, AM, A1, A2: Double;
  T: Double;
  Y, XAI, XBI, XI, Row, Stride, YStart, YEnd: Integer;
begin
  if Y0 = Y1 then
    Exit;
  Dir := 1;
  if Y0 > Y1 then
  begin
    Dir := -1;
    T := X0; X0 := X1; X1 := T;
    T := Y0; Y0 := Y1; Y1 := T;
  end;
  if (Y1 <= 0) or (Y0 >= H) then
    Exit;
  DXDY := (X1 - X0) / (Y1 - Y0);
  if Y0 < 0 then
  begin
    X0 := X0 - Y0 * DXDY;
    Y0 := 0;
  end;
  if Y1 > H then
  begin
    X1 := X0 + (H - Y0) * DXDY;
    Y1 := H;
  end;
  Stride := W + 2;
  X := X0;
  YStart := Floor(Y0);
  YEnd := Min(H, Ceil(Y1));
  for Y := YStart to YEnd - 1 do
  begin
    DY := Min(Y + 1.0, Y1) - Max(Y * 1.0, Y0);
    XNext := X + DXDY * DY;
    D := DY * Dir;
    if X < XNext then
    begin
      XA := X; XB := XNext;
    end
    else
    begin
      XA := XNext; XB := X;
    end;
    XA := Max(0, Min(W, XA));
    XB := Max(0, Min(W, XB));
    XAFloor := Floor(XA);
    XAI := Trunc(XAFloor);
    XBCeil := Ceil(XB);
    XBI := Trunc(XBCeil);
    Row := Y * Stride;
    if XBI <= XAI + 1 then
    begin
      XMF := 0.5 * (XA + XB) - XAFloor;
      FAcc[Row + XAI] := FAcc[Row + XAI] + D - D * XMF;
      FAcc[Row + XAI + 1] := FAcc[Row + XAI + 1] + D * XMF;
    end
    else
    begin
      S := 1 / (XB - XA);
      X0F := XA - XAFloor;
      A0 := 0.5 * S * (1 - X0F) * (1 - X0F);
      X1F := XB - XBCeil + 1;
      AM := 0.5 * S * X1F * X1F;
      FAcc[Row + XAI] := FAcc[Row + XAI] + D * A0;
      if XBI = XAI + 2 then
        FAcc[Row + XAI + 1] := FAcc[Row + XAI + 1] + D * (1 - A0 - AM)
      else
      begin
        A1 := S * (1.5 - X0F);
        FAcc[Row + XAI + 1] := FAcc[Row + XAI + 1] + D * (A1 - A0);
        for XI := XAI + 2 to XBI - 2 do
          FAcc[Row + XI] := FAcc[Row + XI] + D * S;
        A2 := A1 + (XBI - XAI - 3) * S;
        FAcc[Row + XBI - 1] := FAcc[Row + XBI - 1] + D * (1 - A2 - AM);
      end;
      FAcc[Row + XBI] := FAcc[Row + XBI] + D * AM;
    end;
    X := XNext;
  end;
end;

{ Splits an edge where it crosses x = 0 and x = W; outside parts become
  vertical edges on the boundary (they still carry their winding). }
procedure TJuceRasterCanvas.AccumulateEdge(X0, Y0, X1, Y1: Double; W, H: Integer);
var
  Ts: array[0..3] of Double;
  N, I, J: Integer;
  T, TA, TB, XA, YA, XB, YB, XM: Double;
begin
  N := 0;
  Ts[N] := 0; Inc(N);
  if X0 <> X1 then
  begin
    T := (0 - X0) / (X1 - X0);
    if (T > 0) and (T < 1) then begin Ts[N] := T; Inc(N); end;
    T := (W - X0) / (X1 - X0);
    if (T > 0) and (T < 1) then begin Ts[N] := T; Inc(N); end;
  end;
  Ts[N] := 1; Inc(N);
  for I := 1 to N - 2 do
    for J := I + 1 to N - 2 do
      if Ts[J] < Ts[I] then
      begin
        T := Ts[I]; Ts[I] := Ts[J]; Ts[J] := T;
      end;
  for I := 0 to N - 2 do
  begin
    TA := Ts[I];
    TB := Ts[I + 1];
    XA := X0 + (X1 - X0) * TA;
    YA := Y0 + (Y1 - Y0) * TA;
    XB := X0 + (X1 - X0) * TB;
    YB := Y0 + (Y1 - Y0) * TB;
    XM := (XA + XB) / 2;
    if XM <= 0 then
    begin
      XA := 0; XB := 0;
    end
    else if XM >= W then
    begin
      XA := W; XB := W;
    end;
    AccumulateLine(XA, YA, XB, YB, W, H);
  end;
end;

procedure TJuceRasterCanvas.FillPolygons(const Polys: array of TJucePolygon);
var
  MinX, MinY, MaxX, MaxY: Double;
  BX0, BY0, BX1, BY1, W, H, I, J, K, X, Y, Stride: Integer;
  P: TJucePolygon;
  Acc, Cov: Double;
  Solid: Boolean;
  Color: Cardinal;
begin
  MinX := 1E30; MinY := 1E30; MaxX := -1E30; MaxY := -1E30;
  for I := 0 to High(Polys) do
    for J := 0 to High(Polys[I]) do
    begin
      MinX := Min(MinX, Polys[I][J].X);
      MaxX := Max(MaxX, Polys[I][J].X);
      MinY := Min(MinY, Polys[I][J].Y);
      MaxY := Max(MaxY, Polys[I][J].Y);
    end;
  if MinX > MaxX then
    Exit;
  if (MaxX < -1E6) or (MinX > 1E6) or (MaxY < -1E6) or (MinY > 1E6) then
    Exit;
  BX0 := Max(FState.ClipX0, Floor(Max(MinX, -1E6)));
  BY0 := Max(FState.ClipY0, Floor(Max(MinY, -1E6)));
  BX1 := Min(FState.ClipX1, Ceil(Min(MaxX, 1E6)) + 1);
  BY1 := Min(FState.ClipY1, Ceil(Min(MaxY, 1E6)) + 1);
  W := BX1 - BX0;
  H := BY1 - BY0;
  if (W <= 0) or (H <= 0) then
    Exit;
  Stride := W + 2;
  SetLength(FAcc, 0);
  SetLength(FAcc, Stride * H);
  for I := 0 to High(Polys) do
  begin
    P := Polys[I];
    if Length(P) < 3 then
      Continue;
    for J := 0 to High(P) do
    begin
      K := (J + 1) mod Length(P);
      AccumulateEdge(P[J].X - BX0, P[J].Y - BY0, P[K].X - BX0, P[K].Y - BY0, W, H);
    end;
  end;
  Solid := FState.FillKind = jfkSolid;
  Color := FState.Color1;
  for Y := 0 to H - 1 do
  begin
    Acc := 0;
    for X := 0 to W - 1 do
    begin
      Acc := Acc + FAcc[Y * Stride + X];
      Cov := Min(1, Abs(Acc));
      if Cov > 1 / 1024 then
      begin
        if not Solid then
          Color := ColorAt(BX0 + X, BY0 + Y);
        BlendPixel(BX0 + X, BY0 + Y, Color, Cov);
      end;
    end;
  end;
end;

{ --- shapes ----------------------------------------------------------------- }

function TJuceRasterCanvas.RectPolygon(const R: TJuceRect): TJucePolygon;
var
  X0, Y0, X1, Y1: Double;
begin
  DevPoint(R.X, R.Y, X0, Y0);
  DevPoint(R.X + R.W, R.Y + R.H, X1, Y1);
  Result := nil;
  SetLength(Result, 4);
  Result[0] := Pt(X0, Y0);
  Result[1] := Pt(X1, Y0);
  Result[2] := Pt(X1, Y1);
  Result[3] := Pt(X0, Y1);
end;

function TJuceRasterCanvas.EllipsePolygon(CX, CY, RX, RY: Double; Reverse: Boolean): TJucePolygon;
var
  N, I: Integer;
  A, DX, DY, R: Double;
begin
  R := Max(Abs(RX), Abs(RY)) * FScale;
  if R < 0.01 then
    N := 4
  else
    N := Max(8, Min(720, Ceil(2 * Pi / (2 * ArcCos(Max(-1, 1 - CurveTolerance / Max(R, CurveTolerance)))))));
  Result := nil;
  SetLength(Result, N);
  for I := 0 to N - 1 do
  begin
    if Reverse then
      A := -2 * Pi * I / N
    else
      A := 2 * Pi * I / N;
    DevPoint(CX + RX * Sin(A), CY - RY * Cos(A), DX, DY);
    Result[I] := Pt(DX, DY);
  end;
end;

procedure AppendPoint(var P: TJucePolygon; X, Y: Double);
begin
  if (Length(P) > 0) and (Abs(P[High(P)].X - X) < 1E-9) and (Abs(P[High(P)].Y - Y) < 1E-9) then
    Exit;
  SetLength(P, Length(P) + 1);
  P[High(P)] := Pt(X, Y);
end;

procedure AppendCubic(var P: TJucePolygon; X0, Y0, C1X, C1Y, C2X, C2Y, X1, Y1: Double);
var
  N, I: Integer;
  T, U, L: Double;
begin
  L := Sqrt(Sqr(C1X - X0) + Sqr(C1Y - Y0)) + Sqrt(Sqr(C2X - C1X) + Sqr(C2Y - C1Y)) + Sqrt(Sqr(X1 - C2X) + Sqr(Y1 - C2Y));
  N := Max(2, Min(200, Ceil(Sqrt(L / CurveTolerance) * 0.75)));
  for I := 1 to N do
  begin
    T := I / N;
    U := 1 - T;
    AppendPoint(P, U * U * U * X0 + 3 * U * U * T * C1X + 3 * U * T * T * C2X + T * T * T * X1,
      U * U * U * Y0 + 3 * U * U * T * C1Y + 3 * U * T * T * C2Y + T * T * T * Y1);
  end;
end;

{ JUCE's Path::addRoundedRectangle: corners are cubics with handles at 0.45. }
function TJuceRasterCanvas.RoundRectPolygon(const R: TJuceRect; Radius: Single): TJucePolygon;
var
  X, Y, X2, Y2, CS, C45: Double;
begin
  X := (R.X + FState.TX) * FScale;
  Y := (R.Y + FState.TY) * FScale;
  X2 := X + R.W * FScale;
  Y2 := Y + R.H * FScale;
  CS := Max(0, Min(Radius * FScale, Min(R.W * FScale / 2, R.H * FScale / 2)));
  C45 := CS * 0.45;
  Result := nil;
  AppendPoint(Result, X, Y + CS);
  if CS > 0 then
    AppendCubic(Result, X, Y + CS, X, Y + C45, X + C45, Y, X + CS, Y);
  AppendPoint(Result, X2 - CS, Y);
  if CS > 0 then
    AppendCubic(Result, X2 - CS, Y, X2 - C45, Y, X2, Y + C45, X2, Y + CS);
  AppendPoint(Result, X2, Y2 - CS);
  if CS > 0 then
    AppendCubic(Result, X2, Y2 - CS, X2, Y2 - C45, X2 - C45, Y2, X2 - CS, Y2);
  AppendPoint(Result, X + CS, Y2);
  if CS > 0 then
    AppendCubic(Result, X + CS, Y2, X + C45, Y2, X, Y2 - C45, X, Y2 - CS);
  if (Length(Result) > 1) and (Abs(Result[0].X - Result[High(Result)].X) < 1E-9)
    and (Abs(Result[0].Y - Result[High(Result)].Y) < 1E-9) then
    SetLength(Result, Length(Result) - 1);
end;

procedure TJuceRasterCanvas.FillAll;
var
  X, Y: Integer;
  Solid: Boolean;
begin
  Solid := FState.FillKind = jfkSolid;
  for Y := FState.ClipY0 to FState.ClipY1 - 1 do
    for X := FState.ClipX0 to FState.ClipX1 - 1 do
      if Solid then
        BlendPixel(X, Y, FState.Color1, 1)
      else
        BlendPixel(X, Y, ColorAt(X, Y), 1);
end;

procedure TJuceRasterCanvas.FillRect(const R: TJuceRect);
begin
  if (R.W <= 0) or (R.H <= 0) then
    Exit;
  FillPolygons([RectPolygon(R)]);
end;

{ JUCE: four strips inside the rectangle. }
procedure TJuceRasterCanvas.DrawRect(const R: TJuceRect; Thickness: Single);
var
  T: Single;
begin
  if (R.W <= 0) or (R.H <= 0) or (Thickness <= 0) then
    Exit;
  T := Min(Thickness, Min(R.W, R.H) / 2);
  FillPolygons([RectPolygon(JuceRect(R.X, R.Y, R.W, T)), RectPolygon(JuceRect(R.X, R.Y + R.H - T, R.W, T)),
    RectPolygon(JuceRect(R.X, R.Y + T, T, R.H - 2 * T)), RectPolygon(JuceRect(R.X + R.W - T, R.Y + T, T, R.H - 2 * T))]);
end;

procedure TJuceRasterCanvas.FillRoundRect(const R: TJuceRect; Radius: Single);
begin
  if (R.W <= 0) or (R.H <= 0) then
    Exit;
  FillPolygons([RoundRectPolygon(R, Radius)]);
end;

procedure TJuceRasterCanvas.DrawRoundRect(const R: TJuceRect; Radius, Thickness: Single);
begin
  if (R.W <= 0) or (R.H <= 0) or (Thickness <= 0) then
    Exit;
  StrokePolyline(RoundRectPolygon(R, Radius), True, Thickness * FScale / 2, jljMiter, jlcButt);
end;

procedure TJuceRasterCanvas.FillEllipse(const R: TJuceRect);
begin
  if (R.W <= 0) or (R.H <= 0) then
    Exit;
  FillPolygons([EllipsePolygon(R.X + R.W / 2, R.Y + R.H / 2, R.W / 2, R.H / 2, False)]);
end;

{ JUCE: a circle outline is a ring from r - t/2 to r + t/2 (even-odd fill). }
procedure TJuceRasterCanvas.DrawEllipse(const R: TJuceRect; Thickness: Single);
var
  CX, CY: Double;
  Outer, Inner: TJucePolygon;
begin
  if (R.W <= 0) or (R.H <= 0) or (Thickness <= 0) then
    Exit;
  CX := R.X + R.W / 2;
  CY := R.Y + R.H / 2;
  if Abs(R.W - R.H) < 1E-4 then
  begin
    Outer := EllipsePolygon(CX, CY, R.W / 2 + Thickness / 2, R.H / 2 + Thickness / 2, False);
    if R.W / 2 - Thickness / 2 > 0 then
    begin
      Inner := EllipsePolygon(CX, CY, R.W / 2 - Thickness / 2, R.H / 2 - Thickness / 2, True);
      FillPolygons([Outer, Inner]);
    end
    else
      FillPolygons([Outer]);
  end
  else
    StrokePolyline(EllipsePolygon(CX, CY, R.W / 2, R.H / 2, False), True, Thickness * FScale / 2, jljMiter, jlcButt);
end;

{ JUCE: Path::addLineSegment, a filled rectangle around the line (butt ends). }
procedure TJuceRasterCanvas.DrawLine(X1, Y1, X2, Y2, Thickness: Single);
var
  P: TJucePolygon;
  AX, AY, BX, BY: Double;
begin
  if Thickness <= 0 then
    Exit;
  DevPoint(X1, Y1, AX, AY);
  DevPoint(X2, Y2, BX, BY);
  SetLength(P, 2);
  P[0] := Pt(AX, AY);
  P[1] := Pt(BX, BY);
  StrokePolyline(P, False, Thickness * FScale / 2, jljMiter, jlcButt);
end;

{ --- strokes ---------------------------------------------------------------- }

procedure TJuceRasterCanvas.StrokePolyline(const P: TJucePolygon; Closed: Boolean; HalfWidth: Double;
  Join: TJuceLineJoin; Cap: TJuceLineCap);
var
  Q: TJucePolygon;
  N, I, J, K, Prev, Next: Integer;
  NX, NY: array of Double; { segment normals }
  Smooth: Boolean;
  Polys: array of TJucePolygon;
  Outline, L, R: TJucePolygon;
  DX, DY, Len, MX, MY, MLen, Scale, Cross, Dot, Sign: Double;
  SX, SY, EX, EY: Double;
  Seg: TJucePolygon;
  Segs: Integer;

  procedure AddPoly(const Poly: TJucePolygon; S: Double);
  var
    Copy1: TJucePolygon;
  begin
    if Length(Poly) < 3 then
      Exit;
    Copy1 := System.Copy(Poly);
    Orient(Copy1, S);
    SetLength(Polys, Length(Polys) + 1);
    Polys[High(Polys)] := Copy1;
  end;

  procedure AddDisc(X, Y: Double; S: Double);
  var
    D: TJucePolygon;
    M, Z: Integer;
    A: Double;
  begin
    M := Max(8, Min(360, Ceil(2 * Pi / (2 * ArcCos(Max(-1, 1 - CurveTolerance / Max(HalfWidth, CurveTolerance)))))));
    SetLength(D, M);
    for Z := 0 to M - 1 do
    begin
      A := 2 * Pi * Z / M;
      D[Z] := Pt(X + HalfWidth * Cos(A), Y + HalfWidth * Sin(A));
    end;
    AddPoly(D, S);
  end;

begin
  if HalfWidth <= 0 then
    Exit;
  { drop repeated points }
  SetLength(Q, 0);
  for I := 0 to High(P) do
    AppendPoint(Q, P[I].X, P[I].Y);
  if Closed and (Length(Q) > 2) and (Abs(Q[0].X - Q[High(Q)].X) < 1E-9) and (Abs(Q[0].Y - Q[High(Q)].Y) < 1E-9) then
    SetLength(Q, Length(Q) - 1);
  N := Length(Q);
  if N < 2 then
  begin
    if (N = 1) and (Cap = jlcRound) then
    begin
      SetLength(Polys, 0);
      AddDisc(Q[0].X, Q[0].Y, 1);
      FillPolygons(Polys);
    end;
    Exit;
  end;
  if Closed and (N < 3) then
    Closed := False;
  { square caps: extend the ends }
  if not Closed and (Cap = jlcSquare) then
  begin
    DX := Q[1].X - Q[0].X; DY := Q[1].Y - Q[0].Y; Len := Sqrt(DX * DX + DY * DY);
    Q[0] := Pt(Q[0].X - DX / Len * HalfWidth, Q[0].Y - DY / Len * HalfWidth);
    DX := Q[N - 1].X - Q[N - 2].X; DY := Q[N - 1].Y - Q[N - 2].Y; Len := Sqrt(DX * DX + DY * DY);
    Q[N - 1] := Pt(Q[N - 1].X + DX / Len * HalfWidth, Q[N - 1].Y + DY / Len * HalfWidth);
  end;
  if Closed then
    Segs := N
  else
    Segs := N - 1;
  SetLength(NX, Segs);
  SetLength(NY, Segs);
  for I := 0 to Segs - 1 do
  begin
    J := (I + 1) mod N;
    DX := Q[J].X - Q[I].X;
    DY := Q[J].Y - Q[I].Y;
    Len := Max(1E-12, Sqrt(DX * DX + DY * DY));
    NX[I] := -DY / Len;
    NY[I] := DX / Len;
  end;
  { smooth: every turn under ~35 degrees, so offset outlines do not fold }
  Smooth := True;
  for I := 0 to Segs - 1 do
  begin
    if not Closed and (I = 0) then
      Continue;
    Prev := (I - 1 + Segs) mod Segs;
    if NX[Prev] * NX[I] + NY[Prev] * NY[I] < 0.82 then
    begin
      Smooth := False;
      Break;
    end;
  end;
  SetLength(Polys, 0);

  if Smooth then
  begin
    SetLength(L, N);
    SetLength(R, N);
    for I := 0 to N - 1 do
    begin
      if Closed then
      begin
        Prev := (I - 1 + Segs) mod Segs;
        Next := I mod Segs;
      end
      else
      begin
        Prev := Max(0, I - 1);
        Next := Min(Segs - 1, I);
      end;
      MX := NX[Prev] + NX[Next];
      MY := NY[Prev] + NY[Next];
      MLen := Sqrt(MX * MX + MY * MY);
      if MLen < 1E-9 then
      begin
        MX := NX[Next]; MY := NY[Next];
      end
      else
      begin
        MX := MX / MLen; MY := MY / MLen;
      end;
      Dot := Max(0.5, MX * NX[Next] + MY * NY[Next]);
      Scale := HalfWidth / Dot;
      L[I] := Pt(Q[I].X + MX * Scale, Q[I].Y + MY * Scale);
      R[I] := Pt(Q[I].X - MX * Scale, Q[I].Y - MY * Scale);
    end;
    if Closed then
    begin
      { two loops with opposite orientation: the ring between them }
      Sign := SignedArea(L);
      if Sign = 0 then
        Sign := 1;
      SetLength(Polys, 2);
      Polys[0] := L;
      Reverse(R);
      Polys[1] := R;
      if Abs(SignedArea(Polys[0])) < Abs(SignedArea(Polys[1])) then
      begin
        { L was the inner loop: flip both so the outer one is positive }
        Reverse(Polys[0]);
        Reverse(Polys[1]);
      end;
      Orient(Polys[0], 1);
      Orient(Polys[1], -1);
      FillPolygons(Polys);
      Exit;
    end;
    SetLength(Outline, 2 * N);
    for I := 0 to N - 1 do
    begin
      Outline[I] := L[I];
      Outline[2 * N - 1 - I] := R[I];
    end;
    AddPoly(Outline, 1);
    if Cap = jlcRound then
    begin
      AddDisc(Q[0].X, Q[0].Y, 1);
      AddDisc(Q[N - 1].X, Q[N - 1].Y, 1);
    end;
    FillPolygons(Polys);
    Exit;
  end;

  { general case: one quad per segment plus joins and caps, all oriented alike }
  for I := 0 to Segs - 1 do
  begin
    J := (I + 1) mod N;
    SetLength(Seg, 4);
    Seg[0] := Pt(Q[I].X + NX[I] * HalfWidth, Q[I].Y + NY[I] * HalfWidth);
    Seg[1] := Pt(Q[J].X + NX[I] * HalfWidth, Q[J].Y + NY[I] * HalfWidth);
    Seg[2] := Pt(Q[J].X - NX[I] * HalfWidth, Q[J].Y - NY[I] * HalfWidth);
    Seg[3] := Pt(Q[I].X - NX[I] * HalfWidth, Q[I].Y - NY[I] * HalfWidth);
    AddPoly(Seg, 1);
  end;
  for K := 0 to N - 1 do
  begin
    if not Closed and ((K = 0) or (K = N - 1)) then
      Continue;
    Prev := (K - 1 + Segs) mod Segs;
    Next := K mod Segs;
    if Join = jljRound then
    begin
      AddDisc(Q[K].X, Q[K].Y, 1);
      Continue;
    end;
    { the outer side of the turn }
    Cross := NX[Prev] * NY[Next] - NY[Prev] * NX[Next];
    if Abs(Cross) < 1E-9 then
      Continue;
    if Cross > 0 then
      Sign := -1
    else
      Sign := 1;
    SX := Q[K].X + Sign * NX[Prev] * HalfWidth;
    SY := Q[K].Y + Sign * NY[Prev] * HalfWidth;
    EX := Q[K].X + Sign * NX[Next] * HalfWidth;
    EY := Q[K].Y + Sign * NY[Next] * HalfWidth;
    MX := NX[Prev] + NX[Next];
    MY := NY[Prev] + NY[Next];
    MLen := Sqrt(MX * MX + MY * MY);
    Dot := 0;
    if MLen > 1E-9 then
      Dot := (MX / MLen) * NX[Next] + (MY / MLen) * NY[Next];
    if (Join = jljMiter) and (Dot > 0.25) then { miter limit 4 x half width }
    begin
      SetLength(Seg, 4);
      Seg[0] := Pt(Q[K].X, Q[K].Y);
      Seg[1] := Pt(SX, SY);
      Seg[2] := Pt(Q[K].X + Sign * MX / MLen * HalfWidth / Dot, Q[K].Y + Sign * MY / MLen * HalfWidth / Dot);
      Seg[3] := Pt(EX, EY);
    end
    else
    begin
      SetLength(Seg, 3);
      Seg[0] := Pt(Q[K].X, Q[K].Y);
      Seg[1] := Pt(SX, SY);
      Seg[2] := Pt(EX, EY);
    end;
    AddPoly(Seg, 1);
  end;
  if not Closed and (Cap = jlcRound) then
  begin
    AddDisc(Q[0].X, Q[0].Y, 1);
    AddDisc(Q[N - 1].X, Q[N - 1].Y, 1);
  end;
  FillPolygons(Polys);
end;

{ --- paths ------------------------------------------------------------------- }

function TJuceRasterCanvas.CurrentSub: Integer;
begin
  Result := High(FPath);
end;

procedure TJuceRasterCanvas.AddPathPoint(DX, DY: Double);
var
  I, Total: Integer;
begin
  Total := 0;
  for I := 0 to High(FPath) do
    Inc(Total, Length(FPath[I]));
  if Total >= MaxPathPoints then
    Exit;
  if Length(FPath) = 0 then
  begin
    SetLength(FPath, 1);
    SetLength(FPathClosed, 1);
  end;
  AppendPoint(FPath[High(FPath)], DX, DY);
end;

procedure TJuceRasterCanvas.BeginPath;
begin
  SetLength(FPath, 0);
  SetLength(FPathClosed, 0);
end;

procedure TJuceRasterCanvas.MoveTo(X, Y: Single);
var
  DX, DY: Double;
begin
  DevPoint(X, Y, DX, DY);
  SetLength(FPath, Length(FPath) + 1);
  SetLength(FPathClosed, Length(FPath));
  FPathClosed[High(FPathClosed)] := False;
  AddPathPoint(DX, DY);
end;

procedure TJuceRasterCanvas.LineTo(X, Y: Single);
var
  DX, DY: Double;
begin
  DevPoint(X, Y, DX, DY);
  AddPathPoint(DX, DY);
end;

procedure TJuceRasterCanvas.QuadTo(CX, CY, X, Y: Single);
var
  X0, Y0, C1X, C1Y, X1, Y1: Double;
  Sub: Integer;
begin
  Sub := CurrentSub;
  if (Sub < 0) or (Length(FPath[Sub]) = 0) then
  begin
    MoveTo(X, Y);
    Exit;
  end;
  X0 := FPath[Sub][High(FPath[Sub])].X;
  Y0 := FPath[Sub][High(FPath[Sub])].Y;
  DevPoint(CX, CY, C1X, C1Y);
  DevPoint(X, Y, X1, Y1);
  { a quadratic as a cubic }
  AppendCubic(FPath[Sub], X0, Y0, X0 + 2 / 3 * (C1X - X0), Y0 + 2 / 3 * (C1Y - Y0),
    X1 + 2 / 3 * (C1X - X1), Y1 + 2 / 3 * (C1Y - Y1), X1, Y1);
end;

procedure TJuceRasterCanvas.CubicTo(C1X, C1Y, C2X, C2Y, X, Y: Single);
var
  X0, Y0, A1, B1, A2, B2, X1, Y1: Double;
  Sub: Integer;
begin
  Sub := CurrentSub;
  if (Sub < 0) or (Length(FPath[Sub]) = 0) then
  begin
    MoveTo(X, Y);
    Exit;
  end;
  X0 := FPath[Sub][High(FPath[Sub])].X;
  Y0 := FPath[Sub][High(FPath[Sub])].Y;
  DevPoint(C1X, C1Y, A1, B1);
  DevPoint(C2X, C2Y, A2, B2);
  DevPoint(X, Y, X1, Y1);
  AppendCubic(FPath[Sub], X0, Y0, A1, B1, A2, B2, X1, Y1);
end;

procedure TJuceRasterCanvas.AddArc(CX, CY, RX, RY, FromAngle, ToAngle: Single; StartNewSubPath: Boolean);
var
  N, I: Integer;
  A, R, Sweep, DX, DY: Double;
begin
  if IsNan(FromAngle) or IsNan(ToAngle) then
    Exit;
  Sweep := ToAngle - FromAngle;
  if Abs(Sweep) > 4 * Pi then
    Sweep := 4 * Pi * Sign(Sweep);
  R := Max(Abs(RX), Abs(RY)) * FScale;
  if R < CurveTolerance then
    N := 1
  else
    N := Max(1, Min(2000, Ceil(Abs(Sweep) / (2 * ArcCos(Max(-1, 1 - CurveTolerance / R))))));
  for I := 0 to N do
  begin
    A := FromAngle + Sweep * I / N;
    DevPoint(CX + RX * Sin(A), CY - RY * Cos(A), DX, DY);
    if (I = 0) and (StartNewSubPath or (Length(FPath) = 0)) then
    begin
      SetLength(FPath, Length(FPath) + 1);
      SetLength(FPathClosed, Length(FPath));
      FPathClosed[High(FPathClosed)] := False;
    end;
    AddPathPoint(DX, DY);
  end;
end;

procedure TJuceRasterCanvas.ClosePath;
begin
  if Length(FPath) > 0 then
    FPathClosed[High(FPathClosed)] := True;
end;

procedure TJuceRasterCanvas.FillPath;
begin
  FillPolygons(FPath);
end;

procedure TJuceRasterCanvas.StrokePath(Thickness: Single; Join: TJuceLineJoin; Cap: TJuceLineCap);
var
  I: Integer;
begin
  if Thickness <= 0 then
    Exit;
  for I := 0 to High(FPath) do
    StrokePolyline(FPath[I], FPathClosed[I], Thickness * FScale / 2, Join, Cap);
end;

{ --- text ------------------------------------------------------------------- }

procedure TJuceRasterCanvas.SetFont(const Name: string; Height: Single; Style: TJuceFontStyles);
begin
  FState.FontName := Name;
  if IsNan(Height) or (Height < 1) then
    Height := 1
  else if Height > 1000 then
    Height := 1000;
  FState.FontHeight := Height;
  FState.FontStyle := Style;
end;

function TJuceRasterCanvas.TextWidth(const Text: string): Single;
begin
  if FText <> nil then
    Result := FText.TextWidth(Text, FState.FontName, FState.FontHeight * FScale, FState.FontStyle) / FScale
  else
    Result := Length(Text) * FState.FontHeight * 0.55;
end;

procedure TJuceRasterCanvas.DrawText(const Text: string; const R: TJuceRect; Align: TJuceAlign; VAlign: TJuceVAlign);
begin
  PaintText(Text, R, Align, VAlign, False);
end;

procedure TJuceRasterCanvas.DrawFittedText(const Text: string; const R: TJuceRect; Align: TJuceAlign; VAlign: TJuceVAlign);
begin
  PaintText(Text, R, Align, VAlign, True);
end;

{ One line of text. Fit: too wide, it is first squeezed sideways (down to 70%,
  as JUCE's drawFittedText) and only then shortened with an ellipsis. }
procedure TJuceRasterCanvas.PaintText(const Text: string; const R: TJuceRect; Align: TJuceAlign; VAlign: TJuceVAlign;
  Fit: Boolean);
const
  MinSqueeze = 0.7;
var
  S: string;
  HPx, BoxX, BoxY, BoxW, BoxH, TW, X, Y, Squeeze, OXf, S0, S1, Acc, Wt, A: Double;
  Mask: TBytes;
  MW, MH, Pad, MX, MY, PX, PY, OX, OY, Baseline, PX0, PX1, K: Integer;
  Ascent: Single;
  Color: Cardinal;
  Solid: Boolean;
begin
  if (FText = nil) or (Text = '') or (R.W <= 0) or (R.H <= 0) then
    Exit;
  HPx := FState.FontHeight * FScale;
  BoxX := (R.X + FState.TX) * FScale;
  BoxY := (R.Y + FState.TY) * FScale;
  BoxW := R.W * FScale;
  BoxH := R.H * FScale;
  S := Text;
  Squeeze := 1;
  TW := FText.TextWidth(S, FState.FontName, HPx, FState.FontStyle);
  if Fit and (TW > BoxW + 0.01) then
    Squeeze := Max(MinSqueeze, BoxW / TW);
  if TW * Squeeze > BoxW + 0.01 then
  begin
    { shorten with an ellipsis, like JUCE's drawText(..., true) }
    while (Length(S) > 0) and (FText.TextWidth(S + '...', FState.FontName, HPx, FState.FontStyle) * Squeeze > BoxW + 0.01) do
      Delete(S, Length(S), 1);
    S := S + '...';
    TW := FText.TextWidth(S, FState.FontName, HPx, FState.FontStyle);
  end;
  TW := TW * Squeeze;
  case Align of
    jaLeft: X := BoxX;
    jaRight: X := BoxX + BoxW - TW;
  else
    X := BoxX + (BoxW - TW) / 2;
  end;
  case VAlign of
    jvaTop: Y := BoxY;
    jvaBottom: Y := BoxY + BoxH - HPx;
  else
    Y := BoxY + (BoxH - HPx) / 2;
  end;
  FText.RenderMask(S, FState.FontName, HPx, FState.FontStyle, Mask, MW, MH, Pad);
  if (MW <= 0) or (MH <= 0) or (Length(Mask) < MW * MH) then
    Exit;
  FText.Metrics(FState.FontName, HPx, FState.FontStyle, Ascent, Baseline);
  OX := Round(X) - Pad;
  if Baseline >= 0 then
    OY := Round(Y + Ascent) - Baseline { JUCE's baseline, on the nearest row }
  else
    OY := Round(Y) - Pad;
  Solid := FState.FillKind = jfkSolid;
  Color := FState.Color1;
  if Squeeze < 1 then
  begin
    { the mask resampled to Squeeze of its width (a box filter) }
    OXf := X - Pad * Squeeze;
    PX0 := Max(FState.ClipX0, Floor(OXf));
    PX1 := Min(FState.ClipX1 - 1, Ceil(OXf + MW * Squeeze));
    for MY := 0 to MH - 1 do
    begin
      PY := OY + MY;
      if (PY < FState.ClipY0) or (PY >= FState.ClipY1) then
        Continue;
      for PX := PX0 to PX1 do
      begin
        S0 := (PX - OXf) / Squeeze;
        S1 := (PX + 1 - OXf) / Squeeze;
        Acc := 0;
        for K := Max(0, Floor(S0)) to Min(MW - 1, Ceil(S1) - 1) do
        begin
          Wt := Min(S1, K + 1.0) - Max(S0, K * 1.0);
          if Wt > 0 then
            Acc := Acc + Wt * Mask[MY * MW + K];
        end;
        A := Acc / (S1 - S0) / 255;
        if A <= 0 then
          Continue;
        if not Solid then
          Color := ColorAt(PX, PY);
        BlendPixel(PX, PY, Color, Min(1, A));
      end;
    end;
    Exit;
  end;
  for MY := 0 to MH - 1 do
  begin
    PY := OY + MY;
    if (PY < FState.ClipY0) or (PY >= FState.ClipY1) then
      Continue;
    for MX := 0 to MW - 1 do
    begin
      PX := OX + MX;
      if (PX < FState.ClipX0) or (PX >= FState.ClipX1) or (Mask[MY * MW + MX] = 0) then
        Continue;
      if not Solid then
        Color := ColorAt(PX, PY);
      BlendPixel(PX, PY, Color, Mask[MY * MW + MX] / 255);
    end;
  end;
end;

{ --- images ------------------------------------------------------------------ }

procedure TJuceRasterCanvas.DrawImage(Image: TJuceImage; const Dest, Source: TJuceRect; Opacity: Single);
var
  Img: TJuceRasterImage;
  DX0, DY0, DX1, DY1, SX, SY, FX, FY, U, V, CovX, CovY: Double;
  X0, Y0, X1, Y1, PX, PY, IX, IY, IX1, IY1: Integer;
  C00, C10, C01, C11, C: Cardinal;
  SrcX, SrcY, SrcW, SrcH: Double;
begin
  if not (Image is TJuceRasterImage) or (Dest.W <= 0) or (Dest.H <= 0) or (Source.W <= 0) or (Source.H <= 0) then
    Exit;
  Img := TJuceRasterImage(Image);
  if (Img.FW = 0) or (Img.FH = 0) then
    Exit;
  if IsNan(Opacity) or (Opacity <= 0) then
    Exit;
  Opacity := Min(1, Opacity);
  { like the wrapper: the source rectangle snapped out to whole pixels, inside the image }
  SrcX := Max(0, Floor(Source.X));
  SrcY := Max(0, Floor(Source.Y));
  SrcW := Min(Img.FW, Ceil(Source.X + Source.W)) - SrcX;
  SrcH := Min(Img.FH, Ceil(Source.Y + Source.H)) - SrcY;
  if (SrcW <= 0) or (SrcH <= 0) then
    Exit;
  DevPoint(Dest.X, Dest.Y, DX0, DY0);
  DevPoint(Dest.X + Dest.W, Dest.Y + Dest.H, DX1, DY1);
  X0 := Max(FState.ClipX0, Floor(DX0));
  Y0 := Max(FState.ClipY0, Floor(DY0));
  X1 := Min(FState.ClipX1, Ceil(DX1));
  Y1 := Min(FState.ClipY1, Ceil(DY1));
  for PY := Y0 to Y1 - 1 do
  begin
    CovY := Min(PY + 1.0, DY1) - Max(PY * 1.0, DY0);
    if CovY <= 0 then
      Continue;
    SY := SrcY + (PY + 0.5 - DY0) / (DY1 - DY0) * SrcH - 0.5;
    for PX := X0 to X1 - 1 do
    begin
      CovX := Min(PX + 1.0, DX1) - Max(PX * 1.0, DX0);
      if CovX <= 0 then
        Continue;
      SX := SrcX + (PX + 0.5 - DX0) / (DX1 - DX0) * SrcW - 0.5;
      FX := Floor(SX);
      FY := Floor(SY);
      U := SX - FX;
      V := SY - FY;
      IX := Max(Trunc(SrcX), Min(Trunc(SrcX + SrcW) - 1, Trunc(FX)));
      IY := Max(Trunc(SrcY), Min(Trunc(SrcY + SrcH) - 1, Trunc(FY)));
      IX1 := Max(Trunc(SrcX), Min(Trunc(SrcX + SrcW) - 1, Trunc(FX) + 1));
      IY1 := Max(Trunc(SrcY), Min(Trunc(SrcY + SrcH) - 1, Trunc(FY) + 1));
      C00 := Img.FPixels[IY * Img.FW + IX];
      C10 := Img.FPixels[IY * Img.FW + IX1];
      C01 := Img.FPixels[IY1 * Img.FW + IX];
      C11 := Img.FPixels[IY1 * Img.FW + IX1];
      C := MixPremul(MixPremul(C00, C10, U), MixPremul(C01, C11, U), V);
      BlendPixel(PX, PY, C, Opacity * Min(1, CovX) * Min(1, CovY));
    end;
  end;
end;

{ --- state ------------------------------------------------------------------- }

procedure TJuceRasterCanvas.SaveState;
begin
  if FDepth >= MaxSaveDepth then
  begin
    Inc(FDepth); { keep Save/Restore balanced, but stop storing }
    Exit;
  end;
  if Length(FStack) <= FDepth then
    SetLength(FStack, FDepth + 8);
  FStack[FDepth] := FState;
  Inc(FDepth);
end;

procedure TJuceRasterCanvas.RestoreState;
begin
  if FDepth = 0 then
    Exit;
  Dec(FDepth);
  if FDepth < MaxSaveDepth then
    FState := FStack[FDepth];
end;

function TJuceRasterCanvas.ClipRect(const R: TJuceRect): Boolean;
var
  X0, Y0, X1, Y1: Double;
begin
  DevPoint(R.X, R.Y, X0, Y0);
  DevPoint(R.X + Max(0, R.W), R.Y + Max(0, R.H), X1, Y1);
  { the wrapper snaps the clip out to whole pixels }
  FState.ClipX0 := Max(FState.ClipX0, Floor(X0 + 1E-6));
  FState.ClipY0 := Max(FState.ClipY0, Floor(Y0 + 1E-6));
  FState.ClipX1 := Min(FState.ClipX1, Ceil(X1 - 1E-6));
  FState.ClipY1 := Min(FState.ClipY1, Ceil(Y1 - 1E-6));
  Result := (FState.ClipX1 > FState.ClipX0) and (FState.ClipY1 > FState.ClipY0);
  if not Result then
  begin
    FState.ClipX1 := FState.ClipX0;
    FState.ClipY1 := FState.ClipY0;
  end;
end;

procedure TJuceRasterCanvas.Translate(DX, DY: Single);
begin
  if IsNan(DX) or IsNan(DY) then
    Exit;
  FState.TX := FState.TX + DX;
  FState.TY := FState.TY + DY;
end;

end.
