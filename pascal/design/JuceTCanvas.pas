{
  JuceTCanvas.pas - the TCanvas back end of TJuceCanvas, for the Lazarus
  (LCL) and Delphi (VCL) design-time packages.

    TJuceTCanvas      a TJuceCanvas that draws onto a TCanvas: shapes,
                      gradients and images are rasterised by JuceRaster
                      (anti-aliased, like JUCE), text by the LCL/VCL font
                      engine, then the result is copied to the TCanvas
    JuceDecodeImage   PNG/JPEG/BMP bytes as an image the canvas can draw

  Text: JUCE's default sans-serif face is used for '' (Verdana on Windows),
  and a font height means what it means in JUCE (ascent + descent = a
  positive TFont.Height). Glyphs are rasterised with grey-scale
  anti-aliasing, so they come out close to, but not exactly like, JUCE's
  own glyph renderer; see the WYSIWYG test (tests/lcl) for the numbers.

  Free Pascal: needs the LCL. Delphi: needs the VCL (Delphi 10.x or later).
}
unit JuceTCanvas;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
{$IFDEF FPC}
  Classes, SysUtils, Graphics, GraphType, IntfGraphics, FPImage, FPReadPNG, FPReadJPEG, FPReadBMP,
{$ELSE}
  System.Classes, System.SysUtils, System.Types, Winapi.Windows, Vcl.Graphics, Vcl.Imaging.pngimage, Vcl.Imaging.jpeg,
{$ENDIF}
  JuceCanvas, JuceRaster;

type
  { Text through a TBitmap's canvas (one per renderer, reused). }
  TJuceCanvasTextRenderer = class(TJuceTextRenderer)
  private
    FBitmap: TBitmap;
    procedure ApplyFont(const FontName: string; HeightPx: Single; Style: TJuceFontStyles);
  public
    constructor Create;
    destructor Destroy; override;
    function TextWidth(const Text, FontName: string; HeightPx: Single; Style: TJuceFontStyles): Single; override;
    procedure RenderMask(const Text, FontName: string; HeightPx: Single; Style: TJuceFontStyles;
      out Mask: TBytes; out W, H, Pad: Integer); override;
    procedure Metrics(const FontName: string; HeightPx: Single; Style: TJuceFontStyles;
      out Ascent: Single; out MaskBaseline: Integer); override;
  end;

  TJuceTCanvas = class(TJuceRasterCanvas)
  public
    { AWidth x AHeight device pixels; AScale = device pixels per logical
      pixel (the designer's PPI / 96). }
    constructor Create(AWidth, AHeight: Integer; AScale: Single = 1);
    { Copy the rendered pixels to Target at (X, Y) (opaque). }
    procedure DrawTo(Target: TCanvas; X, Y: Integer);
    { The pixels as a TBitmap (caller frees). }
    function ToBitmap: TBitmap;
  end;

var
  { Tests: a renderer TJuceTCanvas uses instead of the default one. }
  JuceTCanvasTextOverride: TJuceTextRenderer = nil;

{ The renderer TJuceTCanvas uses (created on first use, freed at exit). }
function JuceCanvasTextRenderer: TJuceCanvasTextRenderer;

{ PNG, JPEG or BMP bytes; nil if they are not a usable image. }
function JuceDecodeImage(const Data: TBytes): TJuceRasterImage;

{ The face JUCE uses for an empty font name on this platform. }
function JuceDefaultSansName: string;

implementation

uses
  Math;

var
  GRenderer: TJuceCanvasTextRenderer;

const
  MaskPad = 2;

function JuceDefaultSansName: string;
begin
{$IFDEF MSWINDOWS}
  Result := 'Verdana';
{$ELSE}
  {$IFDEF DARWIN}
  Result := 'Lucida Grande';
  {$ELSE}
  Result := 'Bitstream Vera Sans';
  {$ENDIF}
{$ENDIF}
end;

function JuceCanvasTextRenderer: TJuceCanvasTextRenderer;
begin
  if GRenderer = nil then
    GRenderer := TJuceCanvasTextRenderer.Create;
  Result := GRenderer;
end;

{ ---------------------------------------------------------------------------- }
{ Text                                                                         }
{ ---------------------------------------------------------------------------- }

constructor TJuceCanvasTextRenderer.Create;
begin
  inherited Create;
  FBitmap := TBitmap.Create;
  FBitmap.PixelFormat := pf24bit;
  FBitmap.SetSize(4, 4);
end;

destructor TJuceCanvasTextRenderer.Destroy;
begin
  FBitmap.Free;
  inherited Destroy;
end;

procedure TJuceCanvasTextRenderer.ApplyFont(const FontName: string; HeightPx: Single; Style: TJuceFontStyles);
var
  S: TFontStyles;
begin
  if FontName = '' then
    FBitmap.Canvas.Font.Name := JuceDefaultSansName
  else
    FBitmap.Canvas.Font.Name := FontName;
  { positive height = cell height (ascent + descent), JUCE's meaning }
  FBitmap.Canvas.Font.Height := Max(1, Round(HeightPx));
  S := [];
  if jfsBold in Style then Include(S, fsBold);
  if jfsItalic in Style then Include(S, fsItalic);
  if jfsUnderline in Style then Include(S, fsUnderline);
  FBitmap.Canvas.Font.Style := S;
  FBitmap.Canvas.Font.Quality := fqAntialiased;
  FBitmap.Canvas.Font.Color := clWhite;
end;

const
  { Widths and ascents are measured at this size and scaled: at small sizes
    the font engine rounds (hints) them, JUCE does not. }
  ReferenceHeight = 512;

function TJuceCanvasTextRenderer.TextWidth(const Text, FontName: string; HeightPx: Single; Style: TJuceFontStyles): Single;
begin
  ApplyFont(FontName, ReferenceHeight, Style);
  Result := FBitmap.Canvas.TextWidth(Text) * HeightPx / ReferenceHeight;
end;

function TextAscent(C: TCanvas): Integer;
{$IFDEF FPC}
var
  TM: TLCLTextMetric;
begin
  if C.GetTextMetrics(TM) then
    Result := TM.Ascender
  else
    Result := C.TextHeight('Hg') * 4 div 5;
end;
{$ELSE}
var
  TM: TTextMetric;
begin
  if GetTextMetrics(C.Handle, TM) then
    Result := TM.tmAscent
  else
    Result := C.TextHeight('Hg') * 4 div 5;
end;
{$ENDIF}

procedure TJuceCanvasTextRenderer.Metrics(const FontName: string; HeightPx: Single; Style: TJuceFontStyles;
  out Ascent: Single; out MaskBaseline: Integer);
begin
  ApplyFont(FontName, ReferenceHeight, Style);
  Ascent := TextAscent(FBitmap.Canvas) * HeightPx / ReferenceHeight;
  ApplyFont(FontName, HeightPx, Style);
  MaskBaseline := MaskPad + TextAscent(FBitmap.Canvas);
end;

procedure TJuceCanvasTextRenderer.RenderMask(const Text, FontName: string; HeightPx: Single; Style: TJuceFontStyles;
  out Mask: TBytes; out W, H, Pad: Integer);
var
  X, Y: Integer;
{$IFDEF FPC}
  Img: TLazIntfImage;
{$ELSE}
  Line: PByteArray;
{$ENDIF}
begin
  Pad := MaskPad;
  ApplyFont(FontName, HeightPx, Style);
  W := Min(8192, FBitmap.Canvas.TextWidth(Text) + 2 * Pad + 2);
  H := Min(2048, Max(FBitmap.Canvas.TextHeight('Hg'), Round(HeightPx)) + 2 * Pad + 2);
  Mask := nil;
  SetLength(Mask, W * H);
  FBitmap.SetSize(W, H);
  FBitmap.Canvas.Brush.Style := bsSolid;
  FBitmap.Canvas.Brush.Color := clBlack;
  FBitmap.Canvas.FillRect(Rect(0, 0, W, H));
  ApplyFont(FontName, HeightPx, Style);
  FBitmap.Canvas.Brush.Style := bsClear;
  FBitmap.Canvas.TextOut(Pad, Pad, Text);
{$IFDEF FPC}
  Img := FBitmap.CreateIntfImage;
  try
    for Y := 0 to H - 1 do
      for X := 0 to W - 1 do
        Mask[Y * W + X] := Img.Colors[X, Y].Green shr 8;
  finally
    Img.Free;
  end;
{$ELSE}
  for Y := 0 to H - 1 do
  begin
    Line := FBitmap.ScanLine[Y];
    for X := 0 to W - 1 do
      Mask[Y * W + X] := Line[X * 3 + 1]; { pf24bit: B G R }
  end;
{$ENDIF}
end;

{ ---------------------------------------------------------------------------- }
{ TJuceTCanvas                                                                 }
{ ---------------------------------------------------------------------------- }

constructor TJuceTCanvas.Create(AWidth, AHeight: Integer; AScale: Single);
begin
  inherited Create(AWidth, AHeight, AScale);
  if JuceTCanvasTextOverride <> nil then
    TextRenderer := JuceTCanvasTextOverride
  else
    TextRenderer := JuceCanvasTextRenderer;
end;

function TJuceTCanvas.ToBitmap: TBitmap;
var
  X, Y: Integer;
  C: Cardinal;
{$IFDEF FPC}
  Img: TLazIntfImage;
  Desc: TRawImageDescription;
  Line: PByte;
{$ELSE}
  Line: PByteArray;
{$ENDIF}
begin
  Result := TBitmap.Create;
  try
{$IFDEF FPC}
    Img := TLazIntfImage.Create(0, 0, [riqfRGB]);
    try
      Desc.Init_BPP24_B8G8R8_BIO_TTB(Width, Height);
      Img.DataDescription := Desc;
      for Y := 0 to Height - 1 do
      begin
        Line := Img.GetDataLineStart(Y);
        for X := 0 to Width - 1 do
        begin
          C := PixelAt(X, Y);
          Line[X * 3] := C and $FF;
          Line[X * 3 + 1] := (C shr 8) and $FF;
          Line[X * 3 + 2] := (C shr 16) and $FF;
        end;
      end;
      Result.LoadFromIntfImage(Img);
    finally
      Img.Free;
    end;
{$ELSE}
    Result.PixelFormat := pf24bit;
    Result.SetSize(Width, Height);
    for Y := 0 to Height - 1 do
    begin
      Line := Result.ScanLine[Y];
      for X := 0 to Width - 1 do
      begin
        C := PixelAt(X, Y);
        Line[X * 3] := C and $FF;
        Line[X * 3 + 1] := (C shr 8) and $FF;
        Line[X * 3 + 2] := (C shr 16) and $FF;
      end;
    end;
{$ENDIF}
  except
    Result.Free;
    raise;
  end;
end;

procedure TJuceTCanvas.DrawTo(Target: TCanvas; X, Y: Integer);
var
  B: TBitmap;
begin
  if (Width <= 0) or (Height <= 0) then
    Exit;
  B := ToBitmap;
  try
    Target.Draw(X, Y, B);
  finally
    B.Free;
  end;
end;

{ ---------------------------------------------------------------------------- }
{ Images                                                                       }
{ ---------------------------------------------------------------------------- }

const
  MaxImageSide = 8192;

{$IFDEF FPC}
function JuceDecodeImage(const Data: TBytes): TJuceRasterImage;
var
  MS: TMemoryStream;
  Img: TFPMemoryImage;
  Reader: TFPCustomImageReader;
  X, Y: Integer;
  C: TFPColor;
begin
  Result := nil;
  if Length(Data) < 8 then
    Exit;
  if (Data[0] = $89) and (Data[1] = Ord('P')) and (Data[2] = Ord('N')) and (Data[3] = Ord('G')) then
    Reader := TFPReaderPNG.Create
  else if (Data[0] = $FF) and (Data[1] = $D8) then
    Reader := TFPReaderJPEG.Create
  else if (Data[0] = Ord('B')) and (Data[1] = Ord('M')) then
    Reader := TFPReaderBMP.Create
  else
    Exit;
  MS := TMemoryStream.Create;
  Img := TFPMemoryImage.Create(0, 0);
  try
    try
      MS.WriteBuffer(Data[0], Length(Data));
      MS.Position := 0;
      Img.LoadFromStream(MS, Reader);
      if (Img.Width <= 0) or (Img.Height <= 0) or (Img.Width > MaxImageSide) or (Img.Height > MaxImageSide) then
        Exit;
      Result := TJuceRasterImage.Create(Img.Width, Img.Height);
      for Y := 0 to Img.Height - 1 do
        for X := 0 to Img.Width - 1 do
        begin
          C := Img.Colors[X, Y];
          Result.SetPixel(X, Y, (Cardinal(C.Alpha shr 8) shl 24) or (Cardinal(C.Red shr 8) shl 16) or
            (Cardinal(C.Green shr 8) shl 8) or Cardinal(C.Blue shr 8));
        end;
    except
      FreeAndNil(Result);
    end;
  finally
    Img.Free;
    MS.Free;
    Reader.Free;
  end;
end;
{$ELSE}
function JuceDecodeImage(const Data: TBytes): TJuceRasterImage;
var
  MS: TMemoryStream;
  Png: TPngImage;
  Jpg: TJPEGImage;
  Bmp: TBitmap;
  X, Y: Integer;
  A: Byte;
  Alpha: PByteArray;
  Line: PByteArray;
  C: TColor;
begin
  Result := nil;
  if Length(Data) < 8 then
    Exit;
  MS := TMemoryStream.Create;
  try
    MS.WriteBuffer(Data[0], Length(Data));
    MS.Position := 0;
    try
      if (Data[0] = $89) and (Data[1] = Ord('P')) and (Data[2] = Ord('N')) and (Data[3] = Ord('G')) then
      begin
        Png := TPngImage.Create;
        try
          Png.LoadFromStream(MS);
          if (Png.Width <= 0) or (Png.Height <= 0) or (Png.Width > MaxImageSide) or (Png.Height > MaxImageSide) then
            Exit;
          Result := TJuceRasterImage.Create(Png.Width, Png.Height);
          for Y := 0 to Png.Height - 1 do
          begin
            Alpha := nil;
            if Png.Header.ColorType in [COLOR_RGBALPHA, COLOR_GRAYSCALEALPHA] then
              Alpha := PByteArray(Png.AlphaScanline[Y]);
            for X := 0 to Png.Width - 1 do
            begin
              C := ColorToRGB(Png.Pixels[X, Y]);
              if Alpha <> nil then
                A := Alpha[X]
              else
                A := 255;
              Result.SetPixel(X, Y, (Cardinal(A) shl 24) or (Cardinal(GetRValue(C)) shl 16) or
                (Cardinal(GetGValue(C)) shl 8) or Cardinal(GetBValue(C)));
            end;
          end;
        finally
          Png.Free;
        end;
      end
      else if ((Data[0] = $FF) and (Data[1] = $D8)) or ((Data[0] = Ord('B')) and (Data[1] = Ord('M'))) then
      begin
        Bmp := TBitmap.Create;
        try
          if Data[0] = $FF then
          begin
            Jpg := TJPEGImage.Create;
            try
              Jpg.LoadFromStream(MS);
              Bmp.Assign(Jpg);
            finally
              Jpg.Free;
            end;
          end
          else
            Bmp.LoadFromStream(MS);
          Bmp.PixelFormat := pf24bit;
          if (Bmp.Width <= 0) or (Bmp.Height <= 0) or (Bmp.Width > MaxImageSide) or (Bmp.Height > MaxImageSide) then
            Exit;
          Result := TJuceRasterImage.Create(Bmp.Width, Bmp.Height);
          for Y := 0 to Bmp.Height - 1 do
          begin
            Line := Bmp.ScanLine[Y];
            for X := 0 to Bmp.Width - 1 do
              Result.SetPixel(X, Y, $FF000000 or (Cardinal(Line[X * 3 + 2]) shl 16) or
                (Cardinal(Line[X * 3 + 1]) shl 8) or Cardinal(Line[X * 3]));
          end;
        finally
          Bmp.Free;
        end;
      end;
    except
      FreeAndNil(Result);
    end;
  finally
    MS.Free;
  end;
end;
{$ENDIF}

initialization

finalization
  FreeAndNil(GRenderer);

end.
