(*
  test_design_lcl - the design-time controls (pascal/design, LCL) outside the
  IDE: what the Lazarus form designer shows, and what it saves.

    1. WYSIWYG: loads examples/plugins/PascalSynth/SynthEditorForm.lfm into
       real LCL design-time controls, renders every control the way the
       designer paints it (RenderTo: the run-time Paint code on the TCanvas
       back end) and compares the picture with tests/data/ui/
       pascalsynth_default.png, which JUCE rendered from the same layout in
       editor_test. Reports the differences inside and outside text. The
       same for the Mz101 Pascal panel (examples/plugins/Mz101: faders,
       slide switches, LED buttons, a combo box, a readout, a keyboard and a
       theme resource) against mz101_editor_test's verify/ui/mz101_default.png.
    2. Designer output -> run-time loader: streams the design form the way
       the IDE saves it (LCL TWriter, text .lfm), loads that with
       JuceLayout in strict mode, and compares every published property of
       every run-time control with the design-time control's own instance.
       The same for a form with every class and every property changed.
    3. Image and theme resources, parameter lists (.params file and the
       source scan), the colour of the form as the theme background.

  Usage: test_design_lcl <repository root> [output dir for PNGs]
  Build: lazbuild tests/lcl/test_design_lcl.lpi (needs packages/lazarus).
*)
program test_design_lcl;

{$MODE DELPHI}
{$CODEPAGE UTF8}
{$APPTYPE CONSOLE}

uses
{$IFDEF FPC}{$IFDEF UNIX}
  cthreads, { first: the units below may start the RTL's threading in their initialisation }
{$ENDIF}{$ENDIF}
  Interfaces, Classes, SysUtils, TypInfo, Math, Forms, Controls, Graphics, LResources, IntfGraphics, GraphType,
  FPImage, FPReadPNG, FPWritePNG,
  JuceCanvas, JucePlugin, JuceUI, JuceControls, JuceLayout, JuceRaster, JuceTCanvas, JuceDesignControls;

type
  TClassFinder = class
    class procedure Find(Reader: TReader; const AClassName: string; var ComponentClass: TComponentClass);
  end;

  TSynthEditorForm = class(TForm)
  end;

  TMz101EditorForm = class(TForm)
  end;

  { A run-time editor that decodes images itself (no wrapper here). }
  TTestRuntimeEditor = class(TJuceEditor)
  public
    function CreateCanvasImage(const Data: TBytes): TJuceImage; override;
    procedure FreeCanvasImage(Image: TJuceImage); override;
  end;

  { Measures like the real renderer but draws nothing (to find text pixels). }
  TNoTextRenderer = class(TJuceTextRenderer)
  public
    function TextWidth(const Text, FontName: string; HeightPx: Single; Style: TJuceFontStyles): Single; override;
    procedure RenderMask(const Text, FontName: string; HeightPx: Single; Style: TJuceFontStyles;
      out Mask: TBytes; out W, H, Pad: Integer); override;
    procedure Metrics(const FontName: string; HeightPx: Single; Style: TJuceFontStyles;
      out Ascent: Single; out MaskBaseline: Integer); override;
  end;

var
  RootDir, OutDir: string;
  Passed, Failed: Integer;

class procedure TClassFinder.Find(Reader: TReader; const AClassName: string; var ComponentClass: TComponentClass);
begin
  ComponentClass := TComponentClass(GetClass(AClassName));
end;

function TTestRuntimeEditor.CreateCanvasImage(const Data: TBytes): TJuceImage;
begin
  Result := JuceDecodeImage(Data);
end;

procedure TTestRuntimeEditor.FreeCanvasImage(Image: TJuceImage);
begin
  Image.Free;
end;

function TNoTextRenderer.TextWidth(const Text, FontName: string; HeightPx: Single; Style: TJuceFontStyles): Single;
begin
  Result := JuceCanvasTextRenderer.TextWidth(Text, FontName, HeightPx, Style);
end;

procedure TNoTextRenderer.RenderMask(const Text, FontName: string; HeightPx: Single; Style: TJuceFontStyles;
  out Mask: TBytes; out W, H, Pad: Integer);
begin
  JuceCanvasTextRenderer.RenderMask(Text, FontName, HeightPx, Style, Mask, W, H, Pad);
  if Length(Mask) > 0 then
    FillChar(Mask[0], Length(Mask), 0);
end;

procedure TNoTextRenderer.Metrics(const FontName: string; HeightPx: Single; Style: TJuceFontStyles;
  out Ascent: Single; out MaskBaseline: Integer);
begin
  JuceCanvasTextRenderer.Metrics(FontName, HeightPx, Style, Ascent, MaskBaseline);
end;

procedure Check(Condition: Boolean; const What: string);
begin
  if Condition then
  begin
    Inc(Passed);
    WriteLn('  ok    ', What);
  end
  else
  begin
    Inc(Failed);
    WriteLn('  FAIL  ', What);
  end;
end;

procedure Section(const Name: string);
begin
  WriteLn(Name);
end;

function SynthDir: string;
begin
  Result := RootDir + 'examples' + PathDelim + 'plugins' + PathDelim + 'PascalSynth' + PathDelim;
end;

{ ---------------------------------------------------------------------------- }
{ Forms                                                                        }
{ ---------------------------------------------------------------------------- }

function LoadDesignForm(const LfmFile: string; FormClass: TFormClass = nil): TForm;
var
  Text: TFileStream;
  Bin: TMemoryStream;
  C: TComponent;
begin
  if FormClass = nil then
    FormClass := TSynthEditorForm;
  Result := FormClass.CreateNew(nil);
  Text := TFileStream.Create(LfmFile, fmOpenRead or fmShareDenyWrite);
  Bin := TMemoryStream.Create;
  try
    LRSObjectTextToBinary(Text, Bin);
    Bin.Position := 0;
    C := Result;
    ReadComponentFromBinaryStream(Bin, C, TClassFinder.Find, nil);
  finally
    Text.Free;
    Bin.Free;
  end;
end;

function FormAsText(Form: TComponent): string;
var
  S: TStringStream;
begin
  S := TStringStream.Create('');
  try
    WriteComponentAsTextToStream(S, Form);
    Result := S.DataString;
  finally
    S.Free;
  end;
end;

{ What the designer shows: every design-time control painted by RenderTo,
  in z-order, on the form's colour. }
function RenderForm(Form: TForm): TBitmap;

  procedure Walk(Parent: TWinControl; OX, OY: Integer);
  var
    I: Integer;
    C: TControl;
  begin
    for I := 0 to Parent.ControlCount - 1 do
    begin
      C := Parent.Controls[I];
      if C is TJuceDesignControl then
        TJuceDesignControl(C).RenderTo(Result.Canvas, OX + C.Left, OY + C.Top);
      if C is TWinControl then
        Walk(TWinControl(C), OX + C.Left, OY + C.Top);
    end;
  end;

begin
  Result := TBitmap.Create;
  { GTK2 creates bitmaps only in the display's own pixel format }
  Result.PixelFormat := {$IFDEF WINDOWS}pf24bit{$ELSE}pfDevice{$ENDIF};
  Result.SetSize(Form.ClientWidth, Form.ClientHeight);
  Result.Canvas.Brush.Color := Form.Color;
  Result.Canvas.FillRect(Rect(0, 0, Form.ClientWidth, Form.ClientHeight));
  Walk(Form, 0, 0);
end;

function LoadPng(const FileName: string): TFPMemoryImage;
var
  R: TFPReaderPNG;
begin
  Result := TFPMemoryImage.Create(0, 0);
  R := TFPReaderPNG.Create;
  try
    Result.LoadFromFile(FileName, R);
  finally
    R.Free;
  end;
end;

procedure SavePng(Img: TFPCustomImage; const FileName: string);
var
  W: TFPWriterPNG;
begin
  W := TFPWriterPNG.Create;
  try
    W.UseAlpha := False;
    Img.SaveToFile(FileName, W);
  finally
    W.Free;
  end;
end;

{ ---------------------------------------------------------------------------- }
{ 1. WYSIWYG                                                                   }
{ ---------------------------------------------------------------------------- }

type
  TDiffStats = record
    Pixels, Bad, Worst: Integer;
    SumAbs: Double;
  end;

procedure AddDiff(var S: TDiffStats; D, SumChannels: Integer);
begin
  Inc(S.Pixels);
  S.SumAbs := S.SumAbs + SumChannels / 3;
  if D > S.Worst then
    S.Worst := D;
  if D > 24 then
    Inc(S.Bad);
end;

function Pct(N, Of_: Integer): string;
begin
  if Of_ = 0 then
    Result := '0'
  else
    Result := FormatFloat('0.00', 100 * N / Of_);
end;

{ A designed form, rendered as the designer shows it, against the picture JUCE
  rendered of the plug-in's editor built from the same form. }
procedure CompareWysiwyg(const What, FormDir, LfmName, RefFile, OutName: string; FormClass: TFormClass;
  W, H: Integer);
var
  Form: TForm;
  Bmp, NoTextBmp: TBitmap;
  Actual, NoText: TLazIntfImage;
  Ref, DiffImg: TFPMemoryImage;
  X, Y, D, DX, DY, Sum: Integer;
  A, E, N: TFPColor;
  TextMask, LiveMask: array of Boolean;
  Live: TJuceControl;
  I: Integer;
  InText, OutText, All: TDiffStats;
  IsText: Boolean;
  Saved: TJuceTextRenderer;
  NullText: TNoTextRenderer;

  function Ch(C: Word): Integer;
  begin
    Result := C shr 8;
  end;

  function MaxDiff(const P, Q: TFPColor; out S: Integer): Integer;
  begin
    S := Abs(Ch(P.Red) - Ch(Q.Red)) + Abs(Ch(P.Green) - Ch(Q.Green)) + Abs(Ch(P.Blue) - Ch(Q.Blue));
    Result := Max(Abs(Ch(P.Red) - Ch(Q.Red)), Max(Abs(Ch(P.Green) - Ch(Q.Green)), Abs(Ch(P.Blue) - Ch(Q.Blue))));
  end;

begin
  Section('WYSIWYG: ' + What + ': designer rendering (TCanvas back end) vs JUCE');
  JuceDesignFormDirectory := FormDir;
  Form := LoadDesignForm(FormDir + LfmName, FormClass);
  Ref := LoadPng(RefFile);
  NullText := TNoTextRenderer.Create;
  Bmp := nil;
  NoTextBmp := nil;
  Actual := nil;
  NoText := nil;
  DiffImg := nil;
  try
    Check((Form.ClientWidth = W) and (Form.ClientHeight = H), Format('the designed form is %d x %d', [W, H]));
    Bmp := RenderForm(Form);
    { the same without glyphs: where they differ is text }
    Saved := JuceCanvasTextRenderer;
    JuceTCanvasTextOverride := NullText;
    try
      NoTextBmp := RenderForm(Form);
    finally
      JuceTCanvasTextOverride := nil;
    end;
    Actual := Bmp.CreateIntfImage;
    NoText := NoTextBmp.CreateIntfImage;
    Check((Ref.Width = Actual.Width) and (Ref.Height = Actual.Height), 'same size as the JUCE reference');
    if (Ref.Width <> Actual.Width) or (Ref.Height <> Actual.Height) then
      Exit;
    SetLength(TextMask, Actual.Width * Actual.Height);
    for Y := 0 to Actual.Height - 1 do
      for X := 0 to Actual.Width - 1 do
        if MaxDiff(Actual.Colors[X, Y], NoText.Colors[X, Y], Sum) > 0 then
          for DY := -2 to 2 do
            for DX := -2 to 2 do
              if (X + DX >= 0) and (Y + DY >= 0) and (X + DX < Actual.Width) and (Y + DY < Actual.Height) then
                TextMask[(Y + DY) * Actual.Width + X + DX] := True;
    { a scope's screen shows a sample wave in the designer and the live signal
      (silence here) in the plug-in: it is not compared, only its frame }
    SetLength(LiveMask, Actual.Width * Actual.Height);
    for I := 0 to Form.ComponentCount - 1 do
      if (Form.Components[I] is TJuceDesignControl)
        and (TJuceDesignControl(Form.Components[I]).Runtime is JuceControls.TJuceScope) then
      begin
        Live := TJuceDesignControl(Form.Components[I]).Runtime;
        for Y := Round(Live.AbsoluteY) + 2 to Round(Live.AbsoluteY) + Live.Height - 3 do
          for X := Round(Live.AbsoluteX) + 2 to Round(Live.AbsoluteX) + Live.Width - 3 do
            if (X >= 0) and (Y >= 0) and (X < Actual.Width) and (Y < Actual.Height) then
              LiveMask[Y * Actual.Width + X] := True;
      end;
    FillChar(InText, SizeOf(InText), 0);
    FillChar(OutText, SizeOf(OutText), 0);
    FillChar(All, SizeOf(All), 0);
    DiffImg := TFPMemoryImage.Create(Actual.Width, Actual.Height);
    for Y := 0 to Actual.Height - 1 do
      for X := 0 to Actual.Width - 1 do
      begin
        A := Actual.Colors[X, Y];
        E := Ref.Colors[X, Y];
        N.Alpha := $FFFF;
        if LiveMask[Y * Actual.Width + X] then
        begin
          N.Red := 0; N.Green := 0; N.Blue := E.Blue div 2; { shown blue in the diff: not compared }
          DiffImg.Colors[X, Y] := N;
          Continue;
        end;
        D := MaxDiff(A, E, Sum);
        IsText := TextMask[Y * Actual.Width + X];
        AddDiff(All, D, Sum);
        if IsText then
          AddDiff(InText, D, Sum)
        else
          AddDiff(OutText, D, Sum);
        N.Alpha := $FFFF;
        if D > 24 then
        begin
          N.Red := $FFFF; N.Green := 0; N.Blue := 0;
        end
        else
        begin
          N.Red := E.Red div 3; N.Green := E.Green div 3; N.Blue := E.Blue div 3;
        end;
        DiffImg.Colors[X, Y] := N;
      end;
    SavePng(Actual, OutDir + OutName + '.png');
    SavePng(DiffImg, OutDir + OutName + '.diff.png');
    WriteLn(Format('    all pixels:  %d, %d (%s%%) differ by more than 24 in a channel, worst %d, mean |diff| %.2f',
      [All.Pixels, All.Bad, Pct(All.Bad, All.Pixels), All.Worst, All.SumAbs / Max(1, All.Pixels)]));
    WriteLn(Format('    outside text: %d, %d (%s%%) over 24, worst %d, mean |diff| %.2f',
      [OutText.Pixels, OutText.Bad, Pct(OutText.Bad, OutText.Pixels), OutText.Worst, OutText.SumAbs / Max(1, OutText.Pixels)]));
    WriteLn(Format('    text areas:  %d, %d (%s%%) over 24, worst %d, mean |diff| %.2f',
      [InText.Pixels, InText.Bad, Pct(InText.Bad, InText.Pixels), InText.Worst, InText.SumAbs / Max(1, InText.Pixels)]));
    WriteLn('    images: ', OutDir, OutName, '.png, ', OutName, '.diff.png');
    { tolerances: shapes, gradients and anti-aliasing match JUCE closely;
      glyphs come from the platform (GDI, hinted, on Windows; GTK2 and its
      fonts on Linux) instead of JUCE's own rasteriser. Linux text is wider,
      so the text areas, and with them the whole panel, are larger there:
      measured 4.37% over the whole panel on Ubuntu 22.04 (2.96% on Windows). }
    Check(OutText.Bad <= OutText.Pixels div 500, What + Format(': outside text: at most 0.2%% of pixels off by more than 24 (%d)', [OutText.Bad]));
    Check(OutText.SumAbs / Max(1, OutText.Pixels) <= 1.0, What + ': outside text: mean difference at most 1 level');
    Check(InText.Bad <= InText.Pixels * 45 div 100, What + Format(': text areas: at most 45%% of pixels off by more than 24 (%d; glyph shapes, placement is optimal)', [InText.Bad]));
    Check(All.Bad <= All.Pixels * {$IFDEF WINDOWS}4{$ELSE}6{$ENDIF} div 100, What + Format(': whole panel: at most %d%% of pixels off by more than 24 (%d)',
      [{$IFDEF WINDOWS}4{$ELSE}6{$ENDIF}, All.Bad]));
  finally
    DiffImg.Free;
    Actual.Free;
    NoText.Free;
    Bmp.Free;
    NoTextBmp.Free;
    Ref.Free;
    NullText.Free;
    Form.Free;
  end;
end;

procedure TestWysiwyg;
begin
  CompareWysiwyg('PascalSynth', SynthDir, 'SynthEditorForm.lfm',
    RootDir + 'tests' + PathDelim + 'data' + PathDelim + 'ui' + PathDelim + 'pascalsynth_default.png',
    'pascalsynth_designer', TSynthEditorForm, 480, 300);
end;

function Mz101Dir: string;
begin
  Result := RootDir + 'examples' + PathDelim + 'plugins' + PathDelim + 'Mz101' + PathDelim;
end;

{ The Mz101 Pascal panel: a big form with every new control (faders, slide
  switches, LED buttons, a combo box, a readout, a keyboard) and a theme
  resource, against mz101_editor_test's JUCE rendering of the plug-in. }
procedure TestMz101Wysiwyg;
begin
  if not FileExists(Mz101Dir + 'Mz101EditorForm.lfm') then
  begin
    WriteLn('  skip  Mz101 example not present');
    Exit;
  end;
  CompareWysiwyg('Mz101', Mz101Dir, 'Mz101EditorForm.lfm',
    Mz101Dir + 'verify' + PathDelim + 'ui' + PathDelim + 'mz101_default.png',
    'mz101_designer', TMz101EditorForm, 1490, 610);
end;

{ ---------------------------------------------------------------------------- }
{ 2. Designer output -> run-time loader                                        }
{ ---------------------------------------------------------------------------- }

function PropText(Obj: TObject; Info: PPropInfo): string;
begin
  case Info^.PropType^.Kind of
    tkInteger, tkEnumeration, tkBool, tkInt64: Result := IntToStr(GetOrdProp(Obj, Info));
    tkFloat: Result := FloatToStr(GetFloatProp(Obj, Info));
  else
    Result := GetStrProp(Obj, Info);
  end;
end;

{ Every published (non-event) property of the design-time control's run-time
  instance equals that of the loaded control. }
function SameRuntime(D: TJuceDesignControl; R: TJuceControl; out Why: string): Boolean;
var
  List: PPropList;
  N, I: Integer;
  Name, VD, VR: string;
begin
  Result := False;
  if D.Runtime.ClassType <> R.ClassType then
  begin
    Why := D.Name + ': class ' + R.ClassName;
    Exit;
  end;
  N := GetPropList(R, List);
  try
    for I := 0 to N - 1 do
    begin
      Name := string(List^[I]^.Name);
      if (List^[I]^.PropType^.Kind = tkMethod) or (Name = 'Name') then
        Continue;
      VD := PropText(D.Runtime, List^[I]);
      VR := PropText(R, List^[I]);
      if VD <> VR then
      begin
        Why := Format('%s.%s: designer %s, loaded %s', [D.Name, Name, VD, VR]);
        Exit;
      end;
    end;
  finally
    FreeMem(List);
  end;
  if (D.Parent is TJuceDesignControl) <> (R.Parent is JuceControls.TJucePanel) then
  begin
    Why := D.Name + ': parent differs';
    Exit;
  end;
  Result := True;
end;

{ Every published property of the theme equal (the background aside: the
  form's colour sets that). }
function SameTheme(Designed, Loaded: TJuceTheme; out Why: string): Boolean;
var
  List: PPropList;
  N, I: Integer;
begin
  Result := True;
  Why := '';
  N := GetPropList(Designed, List);
  try
    for I := 0 to N - 1 do
      if (string(List^[I]^.Name) <> 'Background') and (PropText(Designed, List^[I]) <> PropText(Loaded, List^[I])) then
      begin
        Why := Format('(%s: designer %s, loaded %s)', [string(List^[I]^.Name), PropText(Designed, List^[I]),
          PropText(Loaded, List^[I])]);
        Exit(False);
      end;
  finally
    FreeMem(List);
  end;
end;

procedure CompareWithLoaded(Form: TForm; const What: string);
var
  Text: string;
  Ed: TTestRuntimeEditor;
  L: TJuceLayoutLoader;
  I, Count: Integer;
  Why, Err: string;
  R: TJuceControl;
  AllSame: Boolean;
  B: TBytes;
  U: UTF8String;

  procedure Visit(Parent: TWinControl);
  var
    K: Integer;
    C: TControl;
  begin
    for K := 0 to Parent.ControlCount - 1 do
    begin
      C := Parent.Controls[K];
      if C is TJuceDesignControl then
      begin
        Inc(Count);
        R := Ed.FindControl(C.Name);
        if R = nil then
        begin
          AllSame := False;
          Why := C.Name + ' missing';
        end
        else if AllSame and not SameRuntime(TJuceDesignControl(C), R, Why) then
          AllSame := False;
      end;
      if C is TWinControl then
        Visit(TWinControl(C));
    end;
  end;

begin
  { the run-time instances are synced on paint, as in the designer }
  RenderForm(Form).Free;
  Text := FormAsText(Form);
  U := Text;
  SetLength(B, Length(U));
  Move(U[1], B[0], Length(U));
  Ed := TTestRuntimeEditor.Create(nil);
  L := TJuceLayoutLoader.Create(Ed);
  try
    L.StrictMode := True;
    Err := '';
    try
      L.LoadFromBytes(B);
    except
      on E: Exception do
        Err := E.Message;
    end;
    Check(Err = '', What + ': the designer''s .lfm loads in strict mode ' + Err);
    if Err <> '' then
    begin
      WriteLn(Text);
      Exit;
    end;
    Check((Ed.Width = Form.ClientWidth) and (Ed.Height = Form.ClientHeight), What + ': editor size = form client size');
    Count := 0;
    AllSame := True;
    Why := '';
    Visit(Form);
    Check(AllSame and (Count > 0), Format('%s: %d controls, every published property equal %s', [What, Count, Why]));
    for I := 0 to Form.ComponentCount - 1 do
      if Form.Components[I] is TJuceImageResource then
        Check(Ed.FindImage(Form.Components[I].Name) <> nil, What + ': image ' + Form.Components[I].Name + ' loaded')
      else if Form.Components[I] is TJuceThemeResource then
      begin
        AllSame := SameTheme(TJuceThemeResource(Form.Components[I]).Theme, Ed.Theme, Why);
        Check(AllSame, What + ': the theme resource is the editor''s theme ' + Why);
      end;
  finally
    L.Free;
    Ed.Free;
  end;
end;

procedure TestMz101Form;
var
  Form: TForm;
  Ed: TJuceDesignEditor;
  I: Integer;
  C: TComponent;
begin
  Section('the Mz101 form in the designer');
  JuceDesignFormDirectory := Mz101Dir;
  Form := LoadDesignForm(Mz101Dir + 'Mz101EditorForm.lfm', TMz101EditorForm);
  try
    CompareWithLoaded(Form, 'Mz101 form');
    C := Form.FindComponent('PatchBox');
    Check(C is TJuceDesignControl, 'the patch box is a design-time control');
    if C is TJuceDesignControl then
    begin
      Ed := TJuceDesignControl(C).DesignEditor;
      Ed.Refresh;
      Check(Ed.Params.Source <> '', 'the parameter list next to the form: ' + Ed.Params.Source);
      I := Ed.FindParameter('patch');
      Check((I >= 0) and (Pos('Init|Rubber Bass|Acid Line', Ed.ParamChoices(I)) = 1),
        'the designer knows the patch names (the combo box''s choices)');
      Check((Ed.Theme.FontSize = 11) and (Ed.Theme.Accent = $FFD2382F) and (Ed.Theme.Background = $FF1F2023),
        'the designer paints with the form''s theme resource and colour');
      Check(JuceControls.TJuceComboBox(TJuceDesignControl(C).Runtime).Text = 'Init', 'the combo box shows the default patch');
    end;
  finally
    Form.Free;
  end;
end;

procedure TestSynthRoundTrip;
var
  Form: TForm;
  Text: string;
begin
  Section('designer output -> run-time loader');
  Form := LoadDesignForm(SynthDir + 'SynthEditorForm.lfm');
  try
    CompareWithLoaded(Form, 'PascalSynth form');
    Text := FormAsText(Form);
    Check(Pos('ParameterId = ''attack''', Text) > 0, 'the designer writes ParameterId');
    Check(Pos('TJuceKnob', Text) > 0, 'controls are saved under the run-time class names');
  finally
    Form.Free;
  end;
end;

{ A non-default value for every published property of a design-time control,
  set through the design-time property (generated accessors). }
procedure SetAll(C: TJuceDesignControl; Seed: Integer);
var
  List: PPropList;
  N, I, E: Integer;
  Info: PPropInfo;
  TD: PTypeData;
  Name: string;
begin
  N := GetPropList(C, List);
  try
    for I := 0 to N - 1 do
    begin
      Info := List^[I];
      Name := string(Info^.Name);
      if (Info^.SetProc = nil) or (Info^.PropType^.Kind = tkMethod) then
        Continue;
      if (Name = 'Name') or (Name = 'Left') or (Name = 'Top') or (Name = 'Width') or (Name = 'Height')
        or (Name = 'Tag') or (Name = 'Cursor') or (Name = 'HelpType') or (Name = 'HelpKeyword')
        or (Name = 'HelpContext') or (Pos('AnchorSide', Name) = 1) or (Name = 'Visible') then
        Continue;
      Inc(Seed);
      TD := GetTypeData(Info^.PropType);
      case Info^.PropType^.Kind of
        tkInteger:
          if TD^.OrdType = otULong then
            SetOrdProp(C, Info, $80000000 or Cardinal(Seed * 7919))
          else if Name = 'Positions' then
            SetOrdProp(C, Info, 3)
          else
            SetOrdProp(C, Info, Seed);
        tkEnumeration, tkBool:
          begin
            E := GetOrdProp(C, Info) + 1;
            if E > TD^.MaxValue then
              E := TD^.MinValue;
            SetOrdProp(C, Info, E);
          end;
        tkFloat:
          SetFloatProp(C, Info, -12.5 + Seed);
        tkAString, tkLString, tkString, tkUString:
          SetStrProp(C, Info, Format('%s %d: Ünïcödé ''q''', [Name, Seed]));
      end;
    end;
  finally
    FreeMem(List);
  end;
end;

procedure TestEveryProperty;
var
  Form: TForm;
  Panel: TJuceDesignControl;
  C: TJuceDesignControl;
  Classes_: TArray<TJuceDesignControlClass>;
  I: Integer;
  Img: TJuceImageResource;
  Png: TBytes;
  MS: TMemoryStream;
  Pic: TFPMemoryImage;
  W: TFPWriterPNG;
  X, Y: Integer;
  Col: TFPColor;
  Ok: Boolean;
  List: PPropList;
  N, K: Integer;
  Name: string;
begin
  Section('every class and property through the designer');
  Form := TSynthEditorForm.CreateNew(nil);
  try
    Form.Name := 'AllForm';
    Form.ClientWidth := 900;
    Form.ClientHeight := 600;
    Form.Color := $00302010;
    { an embedded image, as the image property editor makes it }
    Pic := TFPMemoryImage.Create(8, 32);
    MS := TMemoryStream.Create;
    W := TFPWriterPNG.Create;
    try
      for Y := 0 to 31 do
        for X := 0 to 7 do
        begin
          Col.Red := (Y * 8) shl 8; Col.Green := $8000; Col.Blue := (X * 32) shl 8; Col.Alpha := $FFFF;
          Pic.Colors[X, Y] := Col;
        end;
      W.UseAlpha := True;
      Pic.SaveToStream(MS, W);
      SetLength(Png, MS.Size);
      MS.Position := 0;
      MS.ReadBuffer(Png[0], MS.Size);
    finally
      W.Free;
      MS.Free;
      Pic.Free;
    end;
    Img := TJuceImageResource.Create(Form);
    Img.Name := 'Strip';
    Img.SetData(Png);
    { a theme with every property changed }
    with TJuceThemeResource.Create(Form) do
    begin
      Name := 'AllTheme';
      Accent := $FF123456;
      TextDim := $80FEDCBA;
      FontName := 'Ünïcödé Sans';
      FontSize := 17.5;
      MeterBack := $FF010203;
    end;

    Classes_ := JuceDesignClasses;
    Panel := nil;
    for I := 0 to High(Classes_) do
      if Classes_[I].ClassName = 'TJucePanel' then
      begin
        Panel := Classes_[I].Create(Form);
        Panel.Name := 'Holder';
        Panel.Parent := Form;
        Panel.SetBounds(5, 5, 880, 580);
      end;
    for I := 0 to High(Classes_) do
    begin
      C := Classes_[I].Create(Form);
      C.Name := 'C' + IntToStr(I);
      C.Parent := Panel;
      C.SetBounds(10 + I * 100, 30, 90, 120);
      SetAll(C, I * 100);
      { the generated accessors reach the run-time instance }
      Ok := True;
      N := GetPropList(C.Runtime, List);
      try
        for K := 0 to N - 1 do
        begin
          Name := string(List^[K]^.Name);
          if (List^[K]^.PropType^.Kind = tkMethod) or (Name = 'Name') or (Name = 'Tag') or (Name = 'Left')
            or (Name = 'Top') or (Name = 'Width') or (Name = 'Height') or (Name = 'Visible') or (Name = 'Enabled')
            or (Name = 'Hint') or (Name = 'Caption') then
            Continue;
          if GetPropInfo(C, Name) = nil then
          begin
            Ok := False;
            WriteLn('    ', C.ClassName, ' has no design-time property ', Name);
          end
          else if PropText(C, GetPropInfo(C, Name)) <> PropText(C.Runtime, List^[K]) then
          begin
            Ok := False;
            WriteLn('    ', C.ClassName, '.', Name, ': ', PropText(C, GetPropInfo(C, Name)), ' vs ', PropText(C.Runtime, List^[K]));
          end;
        end;
      finally
        FreeMem(List);
      end;
      Check(Ok, C.ClassName + ': every run-time property is a design-time property and reads back through it');
      if C.Runtime is JuceControls.TJuceKnob then
      begin
        TJuceKnob(C).Style := jksFilmstrip;
        TJuceKnob(C).FilmstripImage := 'Strip';
        TJuceKnob(C).FilmstripFrames := 4;
      end;
    end;
    CompareWithLoaded(Form, 'all classes');
  finally
    Form.Free;
  end;
end;

{ ---------------------------------------------------------------------------- }
{ 3. Parameters, images, colours                                               }
{ ---------------------------------------------------------------------------- }

procedure TestParams;
var
  L: TJuceParamList;
  I: Integer;
  F: TStringList;
  Tmp: string;
begin
  Section('parameter lists (the ParameterId drop-down and the preview values)');
  L := TJuceParamList.Create;
  F := TStringList.Create;
  try
    Check(L.ScanSources(SynthDir), 'source scan of examples/plugins/PascalSynth finds declarations');
    Check(L.Count = 4, Format('four parameters (%d)', [L.Count]));
    I := L.IndexOf('attack');
    Check((I >= 0) and L.Item(I).Known and (L.Item(I).Units = 'ms'), 'attack: range, default and units from the literals');
    if I >= 0 then
      Check(L.Text(I, L.NormalisedDefault(I)) = '10.00', 'attack default text 10.00 (as the wrapper shows it): ' + L.Text(I, L.NormalisedDefault(I)));
    I := L.IndexOf('wave');
    Check((I >= 0) and (L.Item(I).Choices = 'Sine|Saw|Square'), 'wave: choices from the array literal');
    if I >= 0 then
      Check((Abs(L.NormalisedDefault(I) - 0.5) < 1E-6) and (L.Text(I, 0.5) = 'Saw'), 'wave default Saw');

    Tmp := OutDir + 'test.params';
    F.Add('# PascalJUCE parameter list 1');
    F.Add('# id' + #9 + 'kind' + #9 + 'name' + #9 + 'units' + #9 + 'min' + #9 + 'max' + #9 + 'default' + #9 + 'step' + #9 + 'choices');
    F.Add('cutoff' + #9 + 'float' + #9 + 'Cutoff' + #9 + 'Hz' + #9 + '20' + #9 + '20000' + #9 + '1000' + #9 + '0' + #9);
    F.Add('mode' + #9 + 'choice' + #9 + 'Mode' + #9 + #9 + '0' + #9 + '2' + #9 + '2' + #9 + '0' + #9 + 'A|B|C');
    F.Add('on' + #9 + 'bool' + #9 + 'On' + #9 + #9 + '0' + #9 + '1' + #9 + '1' + #9 + '0' + #9);
    F.Add('steps' + #9 + 'int' + #9 + 'Steps' + #9 + #9 + '1' + #9 + '16' + #9 + '4' + #9 + '0' + #9);
    F.Add('broken line');
    F.SaveToFile(Tmp);
    Check(L.LoadFromFile(Tmp) and (L.Count = 4), 'a .params file (malformed lines skipped)');
    Check(L.Text(L.IndexOf('cutoff'), L.NormalisedDefault(L.IndexOf('cutoff'))) = '1000.00', 'float text');
    Check(L.Text(L.IndexOf('mode'), L.NormalisedDefault(L.IndexOf('mode'))) = 'C', 'choice text');
    Check(L.Text(L.IndexOf('on'), L.NormalisedDefault(L.IndexOf('on'))) = 'On', 'bool text');
    Check(L.Text(L.IndexOf('steps'), L.NormalisedDefault(L.IndexOf('steps'))) = '4', 'int text');
    DeleteFile(Tmp);
  finally
    L.Free;
    F.Free;
  end;
end;

procedure ReadArgs;
begin
  RootDir := IncludeTrailingPathDelimiter(ParamStr(1));
  if ParamCount >= 2 then
    OutDir := IncludeTrailingPathDelimiter(ParamStr(2))
  else
    OutDir := IncludeTrailingPathDelimiter(GetCurrentDir);
end;

begin
  if ParamCount < 1 then
  begin
    WriteLn('usage: test_design_lcl <repository root> [output dir]');
    Halt(2);
  end;
  ReadArgs;
  Application.Initialize;
  JuceDesignRegisterClasses;
  RegisterClass(TSynthEditorForm);
  RegisterClass(TMz101EditorForm);
  try
    TestParams;
    TestWysiwyg;
    TestSynthRoundTrip;
    TestEveryProperty;
    if FileExists(Mz101Dir + 'Mz101EditorForm.lfm') then
    begin
      TestMz101Wysiwyg;
      TestMz101Form;
    end
    else
      WriteLn('  skip  Mz101 example not present');
  except
    on E: Exception do
    begin
      Inc(Failed);
      WriteLn('  FAIL  unexpected ', E.ClassName, ': ', E.Message);
    end;
  end;
  WriteLn;
  WriteLn(Passed, ' passed, ', Failed, ' failed');
  if Failed > 0 then
    Halt(1);
end.
