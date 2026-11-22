(*
  JuceLayout.pas - builds a TJuceEditor's controls from a form file designed
  in Lazarus (.lfm) or Delphi (.dfm).

  Design the panel visually with the PascalJUCE design-time package (see
  docs/PLUGINS.md, "Designing a panel in Lazarus or Delphi"), embed the form
  in the plug-in library, and load it in the editor's constructor:

    {$R SynthEditorForm.lfm}   // Lazarus/FPC: compiled to binary RCDATA
                               // Delphi: {$R SynthEditorForm.dfm}

    constructor TMyEditor.Create(APlugin: TJucePlugin);
    begin
      inherited Create(APlugin);
      JuceLoadLayoutResource(Self, 'TSynthEditorForm');   // the form's class name
      (FindControl('Cutoff') as TJuceKnob).OnContextMenu := KnobMenu;
    end;

  Both compilers turn {$R form-file} into an RCDATA resource named after the
  form's class (upper case), in the binary 'TPF0' component-stream format.
  Text form files (lfm/dfm text, e.g. read from disk while developing) work
  too: they are converted with Classes.ObjectTextToBinary first.

  What is read
    - The root object is the IDE's form. ClientWidth/ClientHeight set the
      editor size, Color (if it is a plain RGB colour) the theme background,
      Hint the root hint; DesignTimePPI (Lazarus) or PixelsPerInch (Delphi)
      scales positions and sizes to 96-dpi logical pixels. Other form
      properties (Left, Position, LCLVersion, Font.*, ...) are IDE-only and
      ignored; see IgnoredFormProperty below.
    - Every nested object becomes a control of a registered class (the
      ready-made ones from JuceControls plus JuceRegisterLayoutClass), named
      as in the designer. Published properties are set through RTTI.
      TJuceImageResource objects become editor images (AddImage) under their
      name. A TJuceThemeResource sets the editor's Theme (its published
      properties, applied before the form's Color).
    - Event properties (OnChange = KnobChange) bind to a published method of
      that name on your editor class, if there is one.

  Strictness
    In strict mode an unknown class, unknown property or unusable value is
    an error. Otherwise it is skipped and noted in Warnings (and logged to
    the plug-in log). Strict is on in debug builds (DEBUG defined, or range
    checks on) and can be changed with JuceLayoutStrict. A stream that is
    malformed is an error in both modes.

  Robustness
    The layout is the plug-in's own resource, so it is trusted, but the
    reader is still bounded: sizes, counts, nesting depth and every length
    field are checked against JuceLayoutMax*, so a truncated or corrupt
    stream gives EJuceLayoutError (with the byte offset), never a crash or a
    huge allocation. Loading is all-or-nothing: on error no control is
    added to the editor.

  Works with Delphi and Free Pascal (Delphi mode). No LCL or VCL.
*)
unit JuceLayout;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  Classes, SysUtils, TypInfo, JuceCanvas, JuceUI;

const
  JuceLayoutMaxBinaryBytes = 16 * 1024 * 1024;  { a binary stream }
  JuceLayoutMaxTextBytes = 32 * 1024 * 1024;    { a text form (images double in hex) }
  JuceLayoutMaxObjects = 4096;                  { controls and images }
  JuceLayoutMaxDepth = 32;                      { nesting of objects and lists }
  JuceLayoutMaxProperties = 512;                { per object }
  JuceLayoutMaxStringBytes = 64 * 1024;         { one string value }
  JuceLayoutMaxBinaryValue = 8 * 1024 * 1024;   { one binary value (an embedded image) }
  JuceLayoutMaxValues = 1000000;                { every value read, lists included }

type
  EJuceLayoutError = class(Exception);

  TJuceLayoutLoader = class
  private
    FEditor: TJuceEditor;
    FStrict: Boolean;
    FWarnings: TStringList;
    FRootName, FRootClass: string;
  public
    constructor Create(AEditor: TJuceEditor);
    destructor Destroy; override;
    { Binary ('TPF0') or text form data. Raises EJuceLayoutError. }
    procedure LoadFromBytes(const Data: TBytes);
    procedure LoadFromStream(Stream: TStream);
    { An RCDATA resource of this module (the form file embedded with $R); the name is the
      form's class name, any case. }
    procedure LoadFromResource(const ResourceName: string);
    property StrictMode: Boolean read FStrict write FStrict;
    { What non-strict mode skipped. }
    property Warnings: TStringList read FWarnings;
    { The form's object and class name from the last load. }
    property RootName: string read FRootName;
    property RootClass: string read FRootClass;
  end;

var
  { Default for TJuceLayoutLoader.StrictMode. }
  JuceLayoutStrict: Boolean =
    {$IFDEF DEBUG} True {$ELSE} {$IFDEF PASCALJUCE_STRICT_LAYOUT} True {$ELSE}
    {$IFOPT R+} True {$ELSE} False {$ENDIF} {$ENDIF} {$ENDIF};

{ Convenience wrappers around TJuceLayoutLoader (strictness: JuceLayoutStrict). }
procedure JuceLoadLayoutResource(Editor: TJuceEditor; const ResourceName: string);
procedure JuceLoadLayout(Editor: TJuceEditor; const Data: TBytes); overload;
procedure JuceLoadLayout(Editor: TJuceEditor; Stream: TStream); overload;
procedure JuceLoadLayoutText(Editor: TJuceEditor; const Text: string);
{ False and a message instead of an exception. }
function JuceTryLoadLayout(Editor: TJuceEditor; const Data: TBytes; out Error: string): Boolean;

{ Your own TJuceControl descendants, so layouts can use them by class name.
  The ready-made controls (JuceControls) are always known. }
procedure JuceRegisterLayoutClass(AClass: TJuceControlClass);
function JuceFindLayoutClass(const ClassName: string): TJuceControlClass;

{ A text form as a binary stream (bounded like the loader). }
function JuceLayoutTextToBinary(const Data: TBytes): TBytes;

{ True for form properties the loader ignores (IDE-only). }
function IgnoredFormProperty(const Name: string): Boolean;

const
  { Class name of an embedded image in a layout (see the design packages). }
  JuceImageResourceClass = 'TJuceImageResource';
  { Class name of a layout's theme (colours, font name and size for every
    control that leaves a colour at 0 = the theme's; see TJuceTheme). }
  JuceThemeResourceClass = 'TJuceThemeResource';

implementation

uses
  Math, JuceControls;

const
  { Value type bytes of the component stream format (Classes.TValueType). Not
    the enum itself: FPC and Delphi disagree on 21 (vaUString / vaDouble). }
  vtNull = 0; vtList = 1; vtInt8 = 2; vtInt16 = 3; vtInt32 = 4; vtExtended = 5;
  vtString = 6; vtIdent = 7; vtFalse = 8; vtTrue = 9; vtBinary = 10; vtSet = 11;
  vtLString = 12; vtNil = 13; vtCollection = 14; vtSingle = 15; vtCurrency = 16;
  vtDate = 17; vtWString = 18; vtInt64 = 19; vtUTF8String = 20; vt21 = 21; vtQWord = 22;

  JuceRtRcData = PChar(10);

type
  TLayoutValueKind = (lvInt, lvFloat, lvString, lvIdent, lvBool, lvNil, lvBinary, lvSet, lvList, lvAmbiguous21);

  TLayoutValue = record
    Kind: TLayoutValueKind;
    I: Int64;
    F: Double;
    S: string;          { string, identifier }
    Bin: TBytes;
    Code: Byte;         { the value type byte }
    Offset: Integer;    { where the value starts }
    Raw: UInt64;        { value type 21: the 8 bytes of a possible double }
    RawOK: Boolean;
  end;

  TPendingImage = record
    Name: string;
    Data: TBytes;
  end;

  { One load: reads the bytes, builds controls under a holder, commits. }
  TLayoutReader = class
  private
    FLoader: TJuceLayoutLoader;
    FData: TBytes;
    FPos: Integer;
    FValues, FObjects: Integer;
    FHolder: TJuceControl;
    FNames: TStringList;
    FImages: array of TPendingImage;
    FPath: string;
    { form properties }
    FPPI: Integer;
    FClientW, FClientH, FFormW, FFormH: Integer;
    FHasBackground: Boolean;
    FBackground: TJuceColor;
    FRootHint: string;
    FHasRootHint: Boolean;
    { a TJuceThemeResource: the editor's theme (FTheme is nil without one) }
    FTheme: TJuceTheme;
    procedure Fail(const Msg: string; At: Integer = -1);
    procedure Problem(const Msg: string);
    procedure Need(Count: Integer);
    function ReadByte: Byte;
    function PeekByte: Byte;
    function ReadInt16: SmallInt;
    function ReadInt32: Integer;
    function ReadInt64: Int64;
    function ReadShortStr: string;
    function ReadBytes(Count: Integer): TBytes;
    function ReadExtended: Double;
    function RawDouble(At: Integer): Double;
    procedure ReadValue(out V: TLayoutValue; Depth: Integer);
    procedure SkipCollection(Depth: Integer);
    function Scaled(V: Int64): Integer;
    procedure ReadRoot;
    procedure ReadObject(Parent: TJuceControl; Depth: Integer; Skipping: Boolean);
    procedure ReadRootProperty(const Name: string; const V: TLayoutValue);
    procedure ReadControlProperty(Control: TJuceControl; const Name: string; const V: TLayoutValue);
    procedure SetRtti(Instance: TObject; Info: PPropInfo; const Name: string; const V: TLayoutValue);
    procedure Commit;
  public
    constructor Create(ALoader: TJuceLayoutLoader; const AData: TBytes);
    destructor Destroy; override;
    procedure Run;
  end;

var
  GClasses: TList; { extra TJuceControlClass registrations }

{ ---------------------------------------------------------------------------- }
{ Registry                                                                     }
{ ---------------------------------------------------------------------------- }

procedure JuceRegisterLayoutClass(AClass: TJuceControlClass);
begin
  if AClass = nil then
    Exit;
  if GClasses = nil then
    GClasses := TList.Create;
  if GClasses.IndexOf(Pointer(AClass)) < 0 then
    GClasses.Add(Pointer(AClass));
end;

function JuceFindLayoutClass(const ClassName: string): TJuceControlClass;
var
  I: Integer;
begin
  for I := Low(JuceControlClasses) to High(JuceControlClasses) do
    if SameText(JuceControlClasses[I].ClassName, ClassName) then
      Exit(JuceControlClasses[I]);
  if GClasses <> nil then
    for I := 0 to GClasses.Count - 1 do
      if SameText(TJuceControlClass(GClasses[I]).ClassName, ClassName) then
        Exit(TJuceControlClass(GClasses[I]));
  Result := nil;
end;

{ ---------------------------------------------------------------------------- }
{ Helpers                                                                      }
{ ---------------------------------------------------------------------------- }

const
  IgnoredFormNames: array[0..47] of string = (
    'Left', 'Top', 'Width', 'Height', 'Caption', 'Position', 'LCLVersion', 'OldCreateOrder',
    'TextHeight', 'Scaled', 'ParentFont', 'BorderStyle', 'BorderIcons', 'FormStyle',
    'WindowState', 'Visible', 'ShowHint', 'KeyPreview', 'DefaultMonitor', 'DesignSize',
    'AutoScroll', 'AutoSize', 'SessionProperties', 'PopupMode', 'ShowInTaskBar', 'AlphaBlend',
    'AlphaBlendValue', 'DoubleBuffered', 'Enabled', 'BiDiMode', 'ParentBiDiMode', 'Cursor',
    'HelpType', 'HelpKeyword', 'HelpContext', 'HelpFile', 'UseDockManager', 'DragKind',
    'DragMode', 'DockSite', 'Menu', 'PopupMenu', 'StyleElements', 'StyleName', 'Ctl3D',
    'ParentCustomHint', 'TransparentColor', 'TransparentColorValue');
  IgnoredFormPrefixes: array[0..10] of string = (
    'Font.', 'Constraints.', 'HorzScrollBar.', 'VertScrollBar.', 'ChildSizing.', 'Padding.',
    'Margins.', 'GlassFrame.', 'Icon.', 'CustomTitleBar.', 'Touch.');
  { Properties every LCL/VCL control streams that have no meaning at run time. }
  IgnoredControlNames: array[0..11] of string = (
    'Cursor', 'HelpType', 'HelpKeyword', 'HelpContext', 'ExplicitLeft', 'ExplicitTop',
    'ExplicitWidth', 'ExplicitHeight', 'TabOrder', 'TabStop', 'ParentShowHint', 'ShowHint');

function IgnoredFormProperty(const Name: string): Boolean;
var
  I: Integer;
begin
  for I := Low(IgnoredFormNames) to High(IgnoredFormNames) do
    if SameText(IgnoredFormNames[I], Name) then
      Exit(True);
  for I := Low(IgnoredFormPrefixes) to High(IgnoredFormPrefixes) do
    if SameText(Copy(Name, 1, Length(IgnoredFormPrefixes[I])), IgnoredFormPrefixes[I]) then
      Exit(True);
  Result := False;
end;

function IgnoredControlProperty(const Name: string): Boolean;
var
  I: Integer;
begin
  for I := Low(IgnoredControlNames) to High(IgnoredControlNames) do
    if SameText(IgnoredControlNames[I], Name) then
      Exit(True);
  Result := False;
end;

function IsIdent(const S: string; AllowDots: Boolean): Boolean;
var
  I: Integer;
begin
  Result := False;
  if (S = '') or (Length(S) > 255) then
    Exit;
  for I := 1 to Length(S) do
    case S[I] of
      'A'..'Z', 'a'..'z', '_': ;
      '0'..'9': if I = 1 then Exit;
      '.': if not AllowDots or (I = 1) or (I = Length(S)) then Exit;
    else
      Exit;
    end;
  Result := True;
end;

function Utf8BytesToString(const B: TBytes; Start, Count: Integer): string;
var
  U: UTF8String;
begin
  if Count <= 0 then
    Exit('');
  SetLength(U, Count);
  Move(B[Start], U[1], Count);
  {$IFDEF FPC}
  Result := string(U); { FPC (Delphi mode): string is UTF-8 AnsiString }
  {$ELSE}
  Result := UTF8ToString(U);
  {$ENDIF}
end;

{ $00BBGGRR TColor (non-system) as $FFRRGGBB; False for system/special colours. }
function TColorToJuce(V: Int64; out C: TJuceColor): Boolean;
begin
  Result := (V >= 0) and (V <= $FFFFFF);
  if Result then
    C := $FF000000 or ((V and $FF) shl 16) or (V and $FF00) or ((V shr 16) and $FF);
end;

function NamedColor(const Ident: string; out V: Int64): Boolean;
const
  Names: array[0..15] of string = ('clBlack', 'clMaroon', 'clGreen', 'clOlive', 'clNavy', 'clPurple',
    'clTeal', 'clGray', 'clSilver', 'clRed', 'clLime', 'clYellow', 'clBlue', 'clFuchsia', 'clAqua', 'clWhite');
  Values: array[0..15] of Integer = ($000000, $000080, $008000, $008080, $800000, $800080,
    $808000, $808080, $C0C0C0, $0000FF, $00FF00, $00FFFF, $FF0000, $FF00FF, $FFFF00, $FFFFFF);
var
  I: Integer;
begin
  for I := 0 to High(Names) do
    if SameText(Names[I], Ident) then
    begin
      V := Values[I];
      Exit(True);
    end;
  Result := False;
end;

{ ---------------------------------------------------------------------------- }
{ Text forms                                                                   }
{ ---------------------------------------------------------------------------- }

function StartsWithWord(const B: TBytes; P: Integer; const W: AnsiString): Boolean;
var
  I: Integer;
begin
  Result := False;
  if P + Length(W) > Length(B) then
    Exit;
  for I := 1 to Length(W) do
    if UpCase(AnsiChar(B[P + I - 1])) <> UpCase(W[I]) then
      Exit;
  Result := (P + Length(W) = Length(B)) or (B[P + Length(W)] <= 32);
end;

function FirstContent(const B: TBytes): Integer;
begin
  Result := 0;
  if (Length(B) >= 3) and (B[0] = $EF) and (B[1] = $BB) and (B[2] = $BF) then
    Result := 3;
  while (Result < Length(B)) and (B[Result] <= 32) do
    Inc(Result);
end;

function LooksLikeText(const B: TBytes): Boolean;
var
  P: Integer;
begin
  P := FirstContent(B);
  Result := StartsWithWord(B, P, 'object') or StartsWithWord(B, P, 'inherited') or StartsWithWord(B, P, 'inline');
end;

{ The RTL parser recurses per nested object and list: check the nesting (and
  that strings are closed) before handing it the text. Token based, like the
  parser: newlines mean nothing. Words are counted only where an object can
  start (top level, inside an object, inside a <collection>), not as values
  after "=" or inside ( ) lists. }
procedure PrescanText(const B: TBytes);
var
  P, Q, Depth, Parens, Angles: Integer;
  AfterEquals, NameNext: Boolean;
  C: Byte;
  W: AnsiString;

  procedure TooDeep(const What: string);
  begin
    raise EJuceLayoutError.CreateFmt('layout text: %s nested deeper than %d', [What, JuceLayoutMaxDepth]);
  end;

begin
  Depth := 0;
  Parens := 0;
  Angles := 0;
  AfterEquals := False;
  NameNext := False;
  P := FirstContent(B);
  while P < Length(B) do
  begin
    C := B[P];
    case C of
      Ord(''''):
        begin
          Inc(P);
          while (P < Length(B)) and (B[P] <> Ord('''')) do
          begin
            if (B[P] = 10) or (B[P] = 13) then
              raise EJuceLayoutError.CreateFmt('layout text: unterminated string (byte %d)', [P]);
            Inc(P);
          end;
          if P >= Length(B) then
            raise EJuceLayoutError.Create('layout text: unterminated string at the end');
          Inc(P);
          AfterEquals := False;
          Continue;
        end;
      Ord('{'): { binary data in hex }
        begin
          while (P < Length(B)) and (B[P] <> Ord('}')) do
            Inc(P);
          Inc(P);
          AfterEquals := False;
          Continue;
        end;
      Ord('='):
        AfterEquals := True;
      Ord('('):
        begin
          Inc(Parens);
          if Parens + Angles > JuceLayoutMaxDepth then
            TooDeep('lists');
        end;
      Ord(')'):
        begin
          if Parens > 0 then
            Dec(Parens);
          AfterEquals := False;
        end;
      Ord('<'):
        begin
          Inc(Angles);
          if Parens + Angles > JuceLayoutMaxDepth then
            TooDeep('lists');
          AfterEquals := False;
        end;
      Ord('>'):
        begin
          if Angles > 0 then
            Dec(Angles);
          AfterEquals := False;
        end;
      Ord('A')..Ord('Z'), Ord('a')..Ord('z'), Ord('_'):
        begin
          Q := P;
          while (Q < Length(B)) and (AnsiChar(B[Q]) in ['A'..'Z', 'a'..'z', '_', '0'..'9', '.']) do
            Inc(Q);
          if NameNext then
            NameNext := False { "object end: TX": the name is not a keyword }
          else if (Parens = 0) and not AfterEquals then
          begin
            SetString(W, PAnsiChar(@B[P]), Q - P);
            W := LowerCase(W);
            if (W = 'object') or (W = 'inherited') or (W = 'inline') or (W = 'item') then
            begin
              NameNext := W <> 'item';
              Inc(Depth);
              if Depth + Angles > JuceLayoutMaxDepth then
                TooDeep('objects');
            end
            else if (W = 'end') and (Depth > 0) then
              Dec(Depth);
          end;
          AfterEquals := False;
          P := Q;
          Continue;
        end;
      Ord('0')..Ord('9'), Ord('#'), Ord('$'), Ord('-'), Ord('+'), Ord(']'):
        AfterEquals := False;
    end;
    Inc(P);
  end;
end;

function JuceLayoutTextToBinary(const Data: TBytes): TBytes;
var
  Input: TMemoryStream;
  Output: TMemoryStream;
begin
  if Length(Data) > JuceLayoutMaxTextBytes then
    raise EJuceLayoutError.CreateFmt('layout text: %d bytes, more than the limit of %d', [Length(Data), JuceLayoutMaxTextBytes]);
  if not LooksLikeText(Data) then
    raise EJuceLayoutError.Create('layout text: does not start with "object"');
  PrescanText(Data);
  Input := TMemoryStream.Create;
  Output := TMemoryStream.Create;
  try
    if Length(Data) > 0 then
      Input.WriteBuffer(Data[0], Length(Data));
    Input.Position := 0;
    try
      ObjectTextToBinary(Input, Output);
    except
      on E: EJuceLayoutError do
        raise;
      on E: Exception do
        raise EJuceLayoutError.Create('layout text: ' + E.Message);
    end;
    if Output.Size > JuceLayoutMaxBinaryBytes then
      raise EJuceLayoutError.Create('layout text: the converted stream is larger than the limit');
    Result := nil;
    SetLength(Result, Output.Size);
    if Output.Size > 0 then
    begin
      Output.Position := 0;
      Output.ReadBuffer(Result[0], Output.Size);
    end;
  finally
    Input.Free;
    Output.Free;
  end;
end;

{ ---------------------------------------------------------------------------- }
{ TLayoutReader                                                                }
{ ---------------------------------------------------------------------------- }

constructor TLayoutReader.Create(ALoader: TJuceLayoutLoader; const AData: TBytes);
begin
  inherited Create;
  FLoader := ALoader;
  FData := AData;
  FNames := TStringList.Create;
  FNames.CaseSensitive := False;
  FNames.Sorted := True;
  FPPI := 96;
  FClientW := -1;
  FClientH := -1;
  FFormW := -1;
  FFormH := -1;
end;

destructor TLayoutReader.Destroy;
begin
  FHolder.Free; { anything not committed }
  FNames.Free;
  FTheme.Free;
  inherited Destroy;
end;

procedure TLayoutReader.Fail(const Msg: string; At: Integer);
var
  Where: string;
begin
  if At < 0 then
    At := FPos;
  if FPath <> '' then
    Where := FPath + ': '
  else
    Where := '';
  raise EJuceLayoutError.CreateFmt('layout: %s%s (byte %d)', [Where, Msg, At]);
end;

procedure TLayoutReader.Problem(const Msg: string);
const
  MaxWarnings = 100;
var
  Where: string;
begin
  if FLoader.FStrict then
    Fail(Msg);
  if FLoader.FWarnings.Count > MaxWarnings then
    Exit;
  if FLoader.FWarnings.Count = MaxWarnings then
  begin
    FLoader.FWarnings.Add('(more warnings omitted)');
    Exit;
  end;
  Where := FPath;
  if Length(Where) > 120 then
    Where := '...' + Copy(Where, Length(Where) - 116, 117);
  FLoader.FWarnings.Add(Where + ': ' + Copy(Msg, 1, 300));
end;

procedure TLayoutReader.Need(Count: Integer);
begin
  if (Count < 0) or (Count > Length(FData) - FPos) then
    Fail('unexpected end of data');
end;

function TLayoutReader.ReadByte: Byte;
begin
  Need(1);
  Result := FData[FPos];
  Inc(FPos);
end;

function TLayoutReader.PeekByte: Byte;
begin
  Need(1);
  Result := FData[FPos];
end;

function TLayoutReader.ReadInt16: SmallInt;
begin
  Need(2);
  Result := SmallInt(Word(FData[FPos]) or (Word(FData[FPos + 1]) shl 8));
  Inc(FPos, 2);
end;

function TLayoutReader.ReadInt32: Integer;
begin
  Need(4);
  Result := Integer(Cardinal(FData[FPos]) or (Cardinal(FData[FPos + 1]) shl 8) or
    (Cardinal(FData[FPos + 2]) shl 16) or (Cardinal(FData[FPos + 3]) shl 24));
  Inc(FPos, 4);
end;

function TLayoutReader.ReadInt64: Int64;
var
  Lo, Hi: Cardinal;
begin
  Lo := Cardinal(ReadInt32);
  Hi := Cardinal(ReadInt32);
  Result := Int64((UInt64(Hi) shl 32) or UInt64(Lo));
end;

function TLayoutReader.ReadShortStr: string;
var
  N, I: Integer;
begin
  N := ReadByte;
  Need(N);
  SetLength(Result, N);
  for I := 1 to N do
    Result[I] := Char(FData[FPos + I - 1]);
  Inc(FPos, N);
end;

function TLayoutReader.ReadBytes(Count: Integer): TBytes;
begin
  Need(Count);
  Result := nil;
  SetLength(Result, Count);
  if Count > 0 then
    Move(FData[FPos], Result[0], Count);
  Inc(FPos, Count);
end;

function Bits64ToDouble(Bits: UInt64; out D: Double): Boolean;
begin
  Result := ((Bits shr 52) and $7FF) <> $7FF; { not infinite / NaN: never load those into the FPU }
  if Result then
    Move(Bits, D, 8)
  else
    D := 0;
end;

{ A little-endian IEEE double at At (8 bytes available). }
function TLayoutReader.RawDouble(At: Integer): Double;
var
  Bits: UInt64;
begin
  Need(8);
  Move(FData[At], Bits, 8);
  if not Bits64ToDouble(Bits, Result) then
    Fail('a float that is infinite or NaN', At);
end;

{ An 80-bit x87 extended (what both compilers write for floats). }
function TLayoutReader.ReadExtended: Double;
var
  Mantissa: UInt64;
  SignExp, Exp: Integer;
  I: Integer;
begin
  Need(10);
  Mantissa := 0;
  for I := 7 downto 0 do
    Mantissa := (Mantissa shl 8) or FData[FPos + I];
  SignExp := FData[FPos + 8] or (FData[FPos + 9] shl 8);
  Inc(FPos, 10);
  Exp := SignExp and $7FFF;
  if Exp = $7FFF then
    Fail('a float that is infinite or NaN', FPos - 10);
  if Mantissa = 0 then
    Result := 0
  else
  begin
    Exp := Exp - 16383 - 63;
    if Exp > 960 then { beyond Double: Ldexp would overflow }
      Fail('a float out of range', FPos - 10);
    if Exp < -1200 then
      Result := 0
    else
      Result := Ldexp(Mantissa, Exp);
  end;
  if (SignExp and $8000) <> 0 then
    Result := -Result;
end;

procedure TLayoutReader.SkipCollection(Depth: Integer);
var
  V: TLayoutValue;
  Props: Integer;
begin
  while PeekByte <> vtNull do
  begin
    if PeekByte in [vtInt8, vtInt16, vtInt32] then
      ReadValue(V, Depth + 1);
    if ReadByte <> vtList then
      Fail('malformed collection item');
    Props := 0;
    while PeekByte <> vtNull do
    begin
      Inc(Props);
      if Props > JuceLayoutMaxProperties then
        Fail('too many properties in a collection item');
      ReadShortStr;
      ReadValue(V, Depth + 1);
      if V.Kind = lvAmbiguous21 then
        Fail('value type 21 inside a collection is ambiguous', V.Offset);
    end;
    ReadByte;
  end;
  ReadByte;
end;

procedure TLayoutReader.ReadValue(out V: TLayoutValue; Depth: Integer);
var
  N, Items: Integer;
  Item: TLayoutValue;
  W: WideString;
  I: Integer;
  S: string;
begin
  if Depth > JuceLayoutMaxDepth then
    Fail('values nested too deeply');
  Inc(FValues);
  if FValues > JuceLayoutMaxValues then
    Fail('too many values');
  V.Offset := FPos;
  V.I := 0;
  V.F := 0;
  V.S := '';
  V.Bin := nil;
  V.Code := ReadByte;
  case V.Code of
    vtInt8: begin V.Kind := lvInt; V.I := ShortInt(ReadByte); end;
    vtInt16: begin V.Kind := lvInt; V.I := ReadInt16; end;
    vtInt32: begin V.Kind := lvInt; V.I := ReadInt32; end;
    vtInt64, vtQWord:
      begin
        V.Kind := lvInt;
        V.I := ReadInt64;
        if (V.Code = vtQWord) and (V.I < 0) then
          Fail('an integer out of range', V.Offset);
      end;
    vtExtended: begin V.Kind := lvFloat; V.F := ReadExtended; end;
    vtSingle:
      begin
        V.Kind := lvFloat;
        N := ReadInt32;
        V.F := PSingle(@N)^;
      end;
    vtCurrency: begin V.Kind := lvFloat; V.F := ReadInt64 / 10000; end;
    vtDate: begin V.Kind := lvFloat; Need(8); V.F := RawDouble(FPos); Inc(FPos, 8); end;
    vt21:
      begin
        { Delphi: vaDouble; FPC: vaUString. Resolved by the property's type;
          the double is only converted (and checked) if it is one. }
        V.Kind := lvAmbiguous21;
        V.RawOK := Length(FData) - FPos >= 8;
        if V.RawOK then
          Move(FData[FPos], V.Raw, 8);
        V.I := -1;
        if Length(FData) - FPos >= 4 then
        begin
          N := ReadInt32;
          if (N >= 0) and (N <= JuceLayoutMaxStringBytes div 2) and (N * 2 <= Length(FData) - FPos) then
          begin
            SetLength(W, N);
            for I := 0 to N - 1 do
              W[I + 1] := WideChar(Word(FData[FPos + 2 * I]) or (Word(FData[FPos + 2 * I + 1]) shl 8));
            if N > 0 then
              V.S := string(W)
            else
              V.S := '';
            V.I := N; { remember the string interpretation's length }
          end;
        end;
        if not V.RawOK and (V.I < 0) then
          Fail('unexpected end of data', V.Offset);
        FPos := V.Offset + 1; { consumed later, once the interpretation is known }
      end;
    vtString:
      begin
        V.Kind := lvString;
        N := ReadByte;
        Need(N);
        V.S := Utf8BytesToString(FData, FPos, N);
        Inc(FPos, N);
      end;
    vtLString, vtUTF8String:
      begin
        V.Kind := lvString;
        N := ReadInt32;
        if (N < 0) or (N > JuceLayoutMaxStringBytes) then
          Fail(Format('a string of %d bytes (limit %d)', [N, JuceLayoutMaxStringBytes]), V.Offset);
        Need(N);
        V.S := Utf8BytesToString(FData, FPos, N);
        Inc(FPos, N);
      end;
    vtWString:
      begin
        V.Kind := lvString;
        N := ReadInt32;
        if (N < 0) or (N > JuceLayoutMaxStringBytes div 2) then
          Fail(Format('a string of %d characters (limit %d)', [N, JuceLayoutMaxStringBytes div 2]), V.Offset);
        Need(N * 2);
        SetLength(W, N);
        for I := 0 to N - 1 do
          W[I + 1] := WideChar(Word(FData[FPos + 2 * I]) or (Word(FData[FPos + 2 * I + 1]) shl 8));
        Inc(FPos, N * 2);
        if N > 0 then
          V.S := string(W);
      end;
    vtIdent:
      begin
        V.Kind := lvIdent;
        V.S := ReadShortStr;
      end;
    vtFalse: begin V.Kind := lvBool; V.I := 0; end;
    vtTrue: begin V.Kind := lvBool; V.I := 1; end;
    vtNil, vtNull: V.Kind := lvNil;
    vtBinary:
      begin
        V.Kind := lvBinary;
        N := ReadInt32;
        if (N < 0) or (N > JuceLayoutMaxBinaryValue) then
          Fail(Format('binary data of %d bytes (limit %d)', [N, JuceLayoutMaxBinaryValue]), V.Offset);
        V.Bin := ReadBytes(N);
      end;
    vtSet:
      begin
        V.Kind := lvSet;
        S := '';
        Items := 0;
        repeat
          Item.S := ReadShortStr;
          if Item.S = '' then
            Break;
          Inc(Items);
          if Items > 256 then
            Fail('a set with too many elements', V.Offset);
          if S <> '' then
            S := S + ',';
          S := S + Item.S;
        until False;
        V.S := S;
      end;
    vtList:
      begin
        V.Kind := lvList;
        while PeekByte <> vtNull do
        begin
          ReadValue(Item, Depth + 1);
          if Item.Kind = lvAmbiguous21 then
            Fail('value type 21 inside a list is ambiguous', Item.Offset);
        end;
        ReadByte;
      end;
    vtCollection:
      begin
        V.Kind := lvList;
        SkipCollection(Depth);
      end;
  else
    Fail(Format('unknown value type %d', [V.Code]), V.Offset);
  end;
end;

function TLayoutReader.Scaled(V: Int64): Integer;
begin
  if (V < -65536) or (V > 65536) then
    Fail('a coordinate out of range');
  if FPPI = 96 then
    Result := Integer(V)
  else
    { half away from zero, like the IDEs' MulDiv scaling }
    Result := Integer((Abs(V) * 96 + FPPI div 2) div FPPI) * Sign(V);
end;

procedure TLayoutReader.ReadRootProperty(const Name: string; const V: TLayoutValue);
var
  C: Int64;
begin
  if SameText(Name, 'ClientWidth') or SameText(Name, 'ClientHeight') or SameText(Name, 'Width')
    or SameText(Name, 'Height') then
  begin
    if V.Kind <> lvInt then
      Fail(Name + ' is not an integer', V.Offset);
    if (V.I < 0) or (V.I > 65536) then
      Fail(Name + ' out of range', V.Offset);
    if SameText(Name, 'ClientWidth') then FClientW := V.I
    else if SameText(Name, 'ClientHeight') then FClientH := V.I
    else if SameText(Name, 'Width') then FFormW := V.I
    else FFormH := V.I;
  end
  else if SameText(Name, 'DesignTimePPI') or SameText(Name, 'PixelsPerInch') then
  begin
    if (V.Kind <> lvInt) or (V.I < 24) or (V.I > 960) then
      Fail(Name + ' out of range', V.Offset);
    { DesignTimePPI (Lazarus) wins over PixelsPerInch }
    if SameText(Name, 'DesignTimePPI') or (FPPI = 96) then
      FPPI := V.I;
  end
  else if SameText(Name, 'Color') then
  begin
    C := -1;
    if V.Kind = lvInt then
      C := V.I
    else if (V.Kind = lvIdent) and not NamedColor(V.S, C) then
      C := -1; { clBtnFace, clDefault, ...: keep the theme's background }
    FHasBackground := TColorToJuce(C, FBackground);
  end
  else if SameText(Name, 'Hint') then
  begin
    if V.Kind <> lvString then
      Fail('Hint is not a string', V.Offset);
    FRootHint := V.S;
    FHasRootHint := True;
  end
  else if IgnoredFormProperty(Name) then
    { IDE-only }
  else
    Problem('unknown form property ' + Name);
end;

function PropTypeOf(Info: PPropInfo): PTypeInfo;
begin
  {$IFDEF FPC}
  Result := Info^.PropType;
  {$ELSE}
  Result := Info^.PropType^;
  {$ENDIF}
end;

procedure TLayoutReader.SetRtti(Instance: TObject; Info: PPropInfo; const Name: string; const V: TLayoutValue);
var
  TI: PTypeInfo;
  TD: PTypeData;
  Lo, Hi: Int64;
  E: Integer;
  M: TMethod;
  Value: TLayoutValue;
begin
  TI := PropTypeOf(Info);
  TD := GetTypeData(TI);
  Value := V;
  if Value.Kind = lvAmbiguous21 then
  begin
    if TI^.Kind = tkFloat then
    begin
      if not V.RawOK then
        Fail('unexpected end of data', V.Offset);
      if not Bits64ToDouble(V.Raw, Value.F) then
        Fail('a float that is infinite or NaN', V.Offset);
      Value.Kind := lvFloat;
      FPos := V.Offset + 1 + 8;
    end
    else if (TI^.Kind in [tkString, tkLString, tkWString {$IFDEF FPC}, tkAString{$ENDIF}, tkUString]) and (V.I >= 0) then
    begin
      Value.Kind := lvString;
      FPos := V.Offset + 1 + 4 + 2 * V.I;
    end
    else
      Fail('value type 21 does not fit property ' + Name, V.Offset);
  end;
  if Info^.SetProc = nil then
  begin
    Problem('property ' + Name + ' is read-only');
    Exit;
  end;
  case TI^.Kind of
    tkInteger, tkChar, tkWChar:
      begin
        if Value.Kind <> lvInt then
        begin
          Problem('property ' + Name + ' needs an integer');
          Exit;
        end;
        case TD^.OrdType of
          otSByte: begin Lo := -128; Hi := 127; end;
          otUByte: begin Lo := 0; Hi := 255; end;
          otSWord: begin Lo := -32768; Hi := 32767; end;
          otUWord: begin Lo := 0; Hi := 65535; end;
          otULong: begin Lo := -2147483648; Hi := 4294967295; end; { Delphi writes Cardinal signed }
        else
          begin Lo := -2147483648; Hi := 2147483647; end;
        end;
        if (Value.I < Lo) or (Value.I > Hi) then
        begin
          Problem(Format('property %s: %d is out of range', [Name, Value.I]));
          Exit;
        end;
        if TD^.OrdType = otULong then
          SetOrdProp(Instance, Info, Int64(Cardinal(Value.I and $FFFFFFFF)))
        else
          SetOrdProp(Instance, Info, Value.I);
      end;
    tkInt64 {$IFDEF FPC}, tkQWord{$ENDIF}: { e.g. TComponent.Tag on 64-bit FPC }
      begin
        if Value.Kind <> lvInt then
        begin
          Problem('property ' + Name + ' needs an integer');
          Exit;
        end;
        SetInt64Prop(Instance, Info, Value.I);
      end;
    tkEnumeration {$IFDEF FPC}, tkBool{$ENDIF}:
      begin
        if (TI = TypeInfo(Boolean)) {$IFDEF FPC} or (TI^.Kind = tkBool){$ENDIF} then
        begin
          if Value.Kind = lvBool then
            SetOrdProp(Instance, Info, Value.I)
          else if (Value.Kind = lvIdent) and SameText(Value.S, 'True') then
            SetOrdProp(Instance, Info, 1)
          else if (Value.Kind = lvIdent) and SameText(Value.S, 'False') then
            SetOrdProp(Instance, Info, 0)
          else
            Problem('property ' + Name + ' needs True or False');
          Exit;
        end;
        if Value.Kind <> lvIdent then
        begin
          Problem('property ' + Name + ' needs an identifier');
          Exit;
        end;
        E := GetEnumValue(TI, Value.S);
        if (E < TD^.MinValue) or (E > TD^.MaxValue) then
        begin
          Problem('property ' + Name + ': unknown value ' + Value.S);
          Exit;
        end;
        SetOrdProp(Instance, Info, E);
      end;
    tkFloat:
      begin
        if Value.Kind = lvInt then
          Value.F := Value.I
        else if Value.Kind <> lvFloat then
        begin
          Problem('property ' + Name + ' needs a number');
          Exit;
        end;
        if IsNan(Value.F) or IsInfinite(Value.F) or (Abs(Value.F) > 1E30) then
        begin
          Problem('property ' + Name + ': number out of range');
          Exit;
        end;
        SetFloatProp(Instance, Info, Value.F);
      end;
    tkString, tkLString, tkWString, tkUString {$IFDEF FPC}, tkAString{$ENDIF}:
      begin
        if Value.Kind <> lvString then
        begin
          Problem('property ' + Name + ' needs a string');
          Exit;
        end;
        {$IFDEF FPC}
        if TI^.Kind = tkUString then
          SetUnicodeStrProp(Instance, Info, UnicodeString(Value.S))
        else if TI^.Kind = tkWString then
          SetWideStrProp(Instance, Info, WideString(Value.S))
        else
        {$ENDIF}
          SetStrProp(Instance, Info, Value.S);
      end;
    tkMethod:
      begin
        if Value.Kind = lvNil then
          Exit;
        if Value.Kind <> lvIdent then
        begin
          Problem('event ' + Name + ' needs a method name');
          Exit;
        end;
        M.Data := FLoader.FEditor;
        M.Code := FLoader.FEditor.MethodAddress(Value.S);
        { only methods of your editor class, not of the framework's base
          classes. The signature cannot be checked (FPC has no RTTI for
          it): the method must match the event's type. }
        if TJuceEditor.MethodAddress(Value.S) <> nil then
          M.Code := nil;
        if M.Code = nil then
        begin
          Problem(Format('event %s: %s has no published method %s', [Name, FLoader.FEditor.ClassName, Value.S]));
          Exit;
        end;
        SetMethodProp(Instance, Info, M);
      end;
  else
    Problem('property ' + Name + ' has a type the loader does not support');
  end;
end;

procedure TLayoutReader.ReadControlProperty(Control: TJuceControl; const Name: string; const V: TLayoutValue);
var
  Info: PPropInfo;
begin
  if SameText(Name, 'Left') or SameText(Name, 'Top') or SameText(Name, 'Width') or SameText(Name, 'Height') then
  begin
    if V.Kind <> lvInt then
      Fail(Name + ' is not an integer', V.Offset);
    if SameText(Name, 'Left') then Control.Left := Scaled(V.I)
    else if SameText(Name, 'Top') then Control.Top := Scaled(V.I)
    else if SameText(Name, 'Width') then Control.Width := Scaled(V.I)
    else Control.Height := Scaled(V.I);
    Exit;
  end;
  if IgnoredControlProperty(Name) then
    Exit;
  if SameText(Name, 'Name') then
    Fail('Name is given by the object header, not as a property', V.Offset);
  Info := nil;
  if Pos('.', Name) = 0 then
    Info := GetPropInfo(Control, Name);
  if Info = nil then
  begin
    Problem('unknown property ' + Name + ' of ' + Control.ClassName);
    Exit;
  end;
  SetRtti(Control, Info, Name, V);
end;

procedure TLayoutReader.ReadObject(Parent: TJuceControl; Depth: Integer; Skipping: Boolean);
var
  Flags: Byte;
  ClassName, ObjName, PropName, SavedPath: string;
  Cls: TJuceControlClass;
  Ctl: TJuceControl;
  IsImage, IsTheme, Skip: Boolean;
  Info: PPropInfo;
  V: TLayoutValue;
  Props, Start: Integer;
  ImageData: TBytes;
  HasImage: Boolean;
begin
  if Depth > JuceLayoutMaxDepth then
    Fail(Format('objects nested deeper than %d', [JuceLayoutMaxDepth]));
  Inc(FObjects);
  if FObjects > JuceLayoutMaxObjects then
    Fail(Format('more than %d objects', [JuceLayoutMaxObjects]));
  Start := FPos;
  Flags := PeekByte;
  if (Flags and $F0) = $F0 then
  begin
    ReadByte;
    if (Flags and 2) <> 0 then { ffChildPos }
    begin
      ReadValue(V, Depth);
      if V.Kind <> lvInt then
        Fail('malformed child position');
    end;
  end;
  ClassName := ReadShortStr;
  ObjName := ReadShortStr;
  if not IsIdent(ClassName, False) then
    Fail('malformed class name', Start);
  if (ObjName <> '') and not IsIdent(ObjName, False) then
    Fail('malformed object name', Start);
  SavedPath := FPath;
  if ObjName <> '' then
    FPath := FPath + '.' + ObjName
  else
    FPath := FPath + '.(' + ClassName + ')';

  Ctl := nil;
  IsImage := SameText(ClassName, JuceImageResourceClass) and not Skipping;
  IsTheme := SameText(ClassName, JuceThemeResourceClass) and not Skipping;
  Skip := Skipping;
  HasImage := False;
  if IsTheme then
  begin
    { the theme the editor has now, with this resource's properties on top
      (one theme per form: a second one replaces the first) }
    if FTheme = nil then
      FTheme := TJuceTheme.Create;
    FTheme.Assign(FLoader.FEditor.Theme);
  end;
  if not IsImage and not IsTheme and not Skip then
  begin
    Cls := JuceFindLayoutClass(ClassName);
    if Cls = nil then
    begin
      Problem('unknown control class ' + ClassName + ' (register it with JuceRegisterLayoutClass)');
      Skip := True;
    end
    else
    begin
      Ctl := Cls.Create(nil);
      Ctl.Parent := Parent; { Parent owns and frees it from now on }
    end;
  end;
  if (ObjName <> '') and not Skip then
  begin
    if FNames.IndexOf(ObjName) >= 0 then
      Fail('duplicate name ' + ObjName, Start);
    FNames.Add(ObjName);
    if Ctl <> nil then
      try
        Ctl.Name := ObjName;
      except
        on E: Exception do
          Fail('invalid name ' + ObjName + ': ' + E.Message, Start);
      end;
  end
  else if IsImage and (ObjName = '') then
    Fail('an image resource needs a name', Start);

  Props := 0;
  while PeekByte <> vtNull do
  begin
    Inc(Props);
    if Props > JuceLayoutMaxProperties then
      Fail(Format('more than %d properties', [JuceLayoutMaxProperties]));
    Start := FPos;
    PropName := ReadShortStr;
    if not IsIdent(PropName, True) then
      Fail('malformed property name', Start);
    ReadValue(V, Depth + 1);
    if Skip then
    begin
      if V.Kind = lvAmbiguous21 then
        Fail('value type 21 in a skipped object is ambiguous', V.Offset);
      Continue;
    end;
    try
      if IsImage then
      begin
        if SameText(PropName, 'ImageData') then
        begin
          if V.Kind <> lvBinary then
            Fail('ImageData is not binary data', V.Offset);
          ImageData := V.Bin;
          HasImage := True;
        end
        else if SameText(PropName, 'FileName') or SameText(PropName, 'Left') or SameText(PropName, 'Top') then
          { design-time only }
        else
          Problem('unknown property ' + PropName + ' of ' + JuceImageResourceClass);
      end
      else if IsTheme then
      begin
        if SameText(PropName, 'Left') or SameText(PropName, 'Top') then
          { design-time only }
        else
        begin
          Info := nil;
          if Pos('.', PropName) = 0 then
            Info := GetPropInfo(FTheme, PropName);
          if Info = nil then
            Problem('unknown property ' + PropName + ' of ' + JuceThemeResourceClass)
          else
            SetRtti(FTheme, Info, PropName, V);
        end;
      end
      else
        ReadControlProperty(Ctl, PropName, V);
    except
      on E: EJuceLayoutError do
        raise;
      on E: Exception do
        Fail(Format('property %s: %s', [PropName, E.Message]), Start);
    end;
    if (V.Kind = lvAmbiguous21) and (FPos = V.Offset + 1) then
      Fail('value type 21 was not resolved', V.Offset);
  end;
  ReadByte;

  if IsImage then
  begin
    if not HasImage then
      Problem('image resource ' + ObjName + ' has no ImageData')
    else
    begin
      SetLength(FImages, Length(FImages) + 1);
      FImages[High(FImages)].Name := ObjName;
      FImages[High(FImages)].Data := ImageData;
    end;
  end;

  { children }
  while PeekByte <> vtNull do
  begin
    if (Ctl = nil) and not Skip then
      Fail('a resource cannot contain objects');
    if Skip or (Ctl = nil) then
      ReadObject(nil, Depth + 1, True) { read and drop }
    else
      ReadObject(Ctl, Depth + 1, False);
  end;
  ReadByte;
  FPath := SavedPath;
end;

procedure TLayoutReader.ReadRoot;
var
  Flags: Byte;
  V: TLayoutValue;
  PropName: string;
  Props, Start: Integer;
begin
  Flags := PeekByte;
  if (Flags and $F0) = $F0 then
  begin
    ReadByte;
    if (Flags and 2) <> 0 then
    begin
      ReadValue(V, 0);
      if V.Kind <> lvInt then
        Fail('malformed child position');
    end;
  end;
  FLoader.FRootClass := ReadShortStr;
  FLoader.FRootName := ReadShortStr;
  if not IsIdent(FLoader.FRootClass, False) then
    Fail('malformed form class name');
  FPath := FLoader.FRootName;
  if FPath = '' then
    FPath := FLoader.FRootClass;
  Props := 0;
  while PeekByte <> vtNull do
  begin
    Inc(Props);
    if Props > JuceLayoutMaxProperties then
      Fail(Format('more than %d properties', [JuceLayoutMaxProperties]));
    Start := FPos;
    PropName := ReadShortStr;
    if not IsIdent(PropName, True) then
      Fail('malformed property name', Start);
    ReadValue(V, 1);
    if V.Kind = lvAmbiguous21 then
    begin
      if IgnoredFormProperty(PropName) or (V.I < 0) then
        Fail('value type 21 is ambiguous here', V.Offset);
      FPos := V.Offset + 1 + 4 + 2 * V.I; { a string (FPC vaUString) }
      V.Kind := lvString;
    end;
    ReadRootProperty(PropName, V);
  end;
  ReadByte;
  while PeekByte <> vtNull do
    ReadObject(FHolder, 1, False);
  ReadByte;
end;


procedure TLayoutReader.Commit;
var
  Ed: TJuceEditor;
  W, H, I: Integer;
  Img: TJuceImage;
  Usable: array of Boolean;
begin
  Ed := FLoader.FEditor;
  { decode every image first: a bad one fails the load before the editor changes }
  SetLength(Usable, Length(FImages));
  for I := 0 to High(FImages) do
  begin
    Img := Ed.CreateCanvasImage(FImages[I].Data);
    Usable[I] := Img <> nil;
    if Img <> nil then
      Ed.FreeCanvasImage(Img)
    else
    begin
      FPath := FImages[I].Name;
      Problem('image ' + FImages[I].Name + ' could not be decoded (PNG or JPEG expected)');
    end;
  end;
  for I := 0 to High(FImages) do
    if Usable[I] then
      Ed.AddImage(FImages[I].Name, FImages[I].Data);
  W := FClientW;
  if W < 0 then
    W := FFormW;
  H := FClientH;
  if H < 0 then
    H := FFormH;
  if (W >= 0) and (H >= 0) then
  begin
    Ed.SetSize(Scaled(W), Scaled(H));
    Ed.Root.SetBounds(0, 0, Ed.Width, Ed.Height);
  end;
  if FTheme <> nil then
    Ed.Theme.Assign(FTheme);
  { the form's own colour, if it is a plain one, is the background }
  if FHasBackground then
    Ed.Theme.Background := FBackground;
  if FHasRootHint then
    Ed.Root.Hint := FRootHint;
  while FHolder.ControlCount > 0 do
    FHolder.Controls[0].Parent := Ed.Root;
  if Ed.IsOpen then
    Ed.UpdateTimer;
end;

procedure TLayoutReader.Run;
begin
  if Length(FData) > JuceLayoutMaxBinaryBytes then
    Fail(Format('%d bytes, more than the limit of %d', [Length(FData), JuceLayoutMaxBinaryBytes]), 0);
  if (Length(FData) < 4) or (FData[0] <> Ord('T')) or (FData[1] <> Ord('P')) or (FData[2] <> Ord('F'))
    or (FData[3] <> Ord('0')) then
    Fail('not a form file (no TPF0 signature and not text starting with "object")', 0);
  FPos := 4;
  FHolder := TJuceControl.Create(nil);
  try
    ReadRoot;
  except
    on E: EJuceLayoutError do
      raise;
    on E: Exception do
      Fail(E.ClassName + ': ' + E.Message);
  end;
  if FPos <> Length(FData) then
    Problem(Format('%d bytes after the end of the form', [Length(FData) - FPos]));
  try
    Commit;
  except
    on E: EJuceLayoutError do
      raise;
    on E: Exception do
      Fail('while adding the controls: ' + E.ClassName + ': ' + E.Message);
  end;
end;

{ ---------------------------------------------------------------------------- }
{ TJuceLayoutLoader                                                            }
{ ---------------------------------------------------------------------------- }

constructor TJuceLayoutLoader.Create(AEditor: TJuceEditor);
begin
  inherited Create;
  if AEditor = nil then
    raise EJuceLayoutError.Create('layout: no editor');
  FEditor := AEditor;
  FStrict := JuceLayoutStrict;
  FWarnings := TStringList.Create;
end;

destructor TJuceLayoutLoader.Destroy;
begin
  FWarnings.Free;
  inherited Destroy;
end;

procedure TJuceLayoutLoader.LoadFromBytes(const Data: TBytes);
var
  Bin: TBytes;
  R: TLayoutReader;
  I: Integer;
begin
  FWarnings.Clear;
  if LooksLikeText(Data) then
    Bin := JuceLayoutTextToBinary(Data)
  else
    Bin := Data;
  R := TLayoutReader.Create(Self, Bin);
  try
    R.Run;
  finally
    R.Free;
  end;
  if (FWarnings.Count > 0) and (FEditor.Plugin <> nil) then
    for I := 0 to FWarnings.Count - 1 do
      FEditor.Plugin.Log('layout warning: ' + FWarnings[I]);
end;

procedure TJuceLayoutLoader.LoadFromStream(Stream: TStream);
var
  Data: TBytes;
  N: Int64;
begin
  N := Stream.Size - Stream.Position;
  if (N < 0) or (N > JuceLayoutMaxTextBytes) then
    raise EJuceLayoutError.CreateFmt('layout: %d bytes, more than the limit', [N]);
  SetLength(Data, N);
  if N > 0 then
    Stream.ReadBuffer(Data[0], N);
  LoadFromBytes(Data);
end;

procedure TJuceLayoutLoader.LoadFromResource(const ResourceName: string);
var
  RS: TResourceStream;
begin
  try
    RS := TResourceStream.Create(HInstance, UpperCase(ResourceName), JuceRtRcData);
  except
    on E: Exception do
      raise EJuceLayoutError.CreateFmt('layout: resource %s not found in this library ' +
        '(add {$R YourForm.lfm} or {$R YourForm.dfm}; the name is the form''s class name): %s',
        [UpperCase(ResourceName), E.Message]);
  end;
  try
    LoadFromStream(RS);
  finally
    RS.Free;
  end;
end;

{ ---------------------------------------------------------------------------- }
{ Wrappers                                                                     }
{ ---------------------------------------------------------------------------- }

procedure JuceLoadLayoutResource(Editor: TJuceEditor; const ResourceName: string);
var
  L: TJuceLayoutLoader;
begin
  L := TJuceLayoutLoader.Create(Editor);
  try
    L.LoadFromResource(ResourceName);
  finally
    L.Free;
  end;
end;

procedure JuceLoadLayout(Editor: TJuceEditor; const Data: TBytes);
var
  L: TJuceLayoutLoader;
begin
  L := TJuceLayoutLoader.Create(Editor);
  try
    L.LoadFromBytes(Data);
  finally
    L.Free;
  end;
end;

procedure JuceLoadLayout(Editor: TJuceEditor; Stream: TStream);
var
  L: TJuceLayoutLoader;
begin
  L := TJuceLayoutLoader.Create(Editor);
  try
    L.LoadFromStream(Stream);
  finally
    L.Free;
  end;
end;

procedure JuceLoadLayoutText(Editor: TJuceEditor; const Text: string);
var
  U: UTF8String;
  B: TBytes;
begin
  {$IFDEF FPC}
  U := Text;
  {$ELSE}
  U := UTF8Encode(Text);
  {$ENDIF}
  SetLength(B, Length(U));
  if Length(U) > 0 then
    Move(U[1], B[0], Length(U));
  JuceLoadLayout(Editor, B);
end;

function JuceTryLoadLayout(Editor: TJuceEditor; const Data: TBytes; out Error: string): Boolean;
begin
  Error := '';
  try
    JuceLoadLayout(Editor, Data);
    Result := True;
  except
    on E: Exception do
    begin
      Error := E.Message;
      Result := False;
    end;
  end;
end;

initialization

finalization
  GClasses.Free;
  GClasses := nil;

end.
