{
  JuceDesignControls.pas - the PascalJUCE controls for the Lazarus (LCL) and
  Delphi (VCL) form designers.

  Each class here has the same name as its run-time class in JuceControls
  (TJuceKnob, TJuceSlider, ...), so a form designed with them streams
  straight into the run-time loader (JuceLayout). They are thin:

    - every design-time control owns an instance of its run-time class
      (Runtime) and its published properties read and write that instance
      through RTTI. The property lists are generated from the run-time
      classes (tools/gen_design_props.dpr -> JuceDesignGen.inc), so there is
      one source of truth for names, types and defaults;
    - painting calls the run-time control's own Paint on a TJuceTCanvas (the
      TCanvas back end), so the designer shows exactly what the plug-in
      draws. Run-time instances are kept in a tree that mirrors the design
      form, under a TJuceDesignEditor, so theme, parameters and images
      resolve as they do in the plug-in;
    - parameters: the design editor reads the plug-in's parameter list
      (a .params file the build exports next to the form, or failing that the
      JuceAdd...Parameter calls in the Pascal sources there), so bound
      controls show their default value and text, and the ParameterId
      property editor can offer the ids;
    - TJuceImageResource is a non-visual component that embeds a PNG/JPEG in
      the form (ImageData); FilmstripImage / BackgroundImage refer to it by
      name. The loader turns it into an editor image of the same name.
    - TJuceThemeResource is a non-visual component holding the editor's
      theme (TJuceTheme: the colours controls use where theirs is 0, the font
      name and size). The designer paints with it and the loader applies it
      to the editor.

  This unit is the run-time part of the design packages (pascaljuce_lcl.lpk,
  PascalJUCE_VCL.dpk): no IDE code here. The IDE part (registration,
  property editors) is in packages/lazarus/JuceDesignRegLaz.pas and
  packages/delphi/JuceDesignRegVcl.pas.

  Never use this unit in a plug-in: it pulls in the LCL/VCL.
}
unit JuceDesignControls;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
{$IFDEF FPC}
  Classes, SysUtils, Controls, Graphics, Forms, LCLType,
{$ELSE}
  System.Classes, System.SysUtils, System.Types, Vcl.Controls, Vcl.Graphics, Vcl.Forms, Winapi.Windows, Winapi.Messages,
{$ENDIF}
  TypInfo, JuceCanvas, JucePlugin, JuceUI, JuceControls, JuceRaster, JuceTCanvas;

type
  TJuceParamKind = (jpkFloat, jpkInt, jpkBool, jpkChoice);

  TJuceParamInfo = record
    Id, Name, Units: string;
    Kind: TJuceParamKind;
    MinValue, MaxValue, DefaultValue, Step: Single;
    Choices: string; { '|' separated }
    Known: Boolean;  { range and default known (not just the id) }
  end;

  { The plug-in's parameters as the designer knows them. }
  TJuceParamList = class
  private
    FItems: array of TJuceParamInfo;
    FSource: string;
    procedure Add(const Info: TJuceParamInfo);
  public
    procedure Clear;
    { A parameter list file written by pascaljuce_params (see PLUGINS.md). }
    function LoadFromFile(const FileName: string): Boolean;
    { JuceAdd*Parameter calls with literal arguments in the .dpr/.lpr/.pas
      files of Dir (a fallback when there is no .params file). }
    function ScanSources(const Dir: string): Boolean;
    function Count: Integer;
    function Item(Index: Integer): TJuceParamInfo;
    function IndexOf(const Id: string): Integer;
    function NormalisedDefault(Index: Integer): Single;
    { What the wrapper shows for a value (no units). }
    function Text(Index: Integer; Normalised: Single): string;
    { Where the list came from (file name, or "sources in <dir>"). }
    property Source: string read FSource;
  end;

  TJuceDesignControl = class;
  TJuceDesignControlClass = class of TJuceDesignControl;

  { The editor behind a form in the designer: owns the run-time tree's root
    and answers parameter and image questions from design-time data. }
  TJuceDesignEditor = class(TJuceEditor)
  private
    FFormRoot: TComponent;
    FParams: TJuceParamList;
    FParamFile: string;
    FParamAge: LongInt;
    FParamDir: string;
    FLastCheck: Cardinal;
    FScale: Single;
    FImageStamps: TStringList;
    procedure RefreshParams;
    procedure RefreshImages;
  public
    function CreateCanvasImage(const Data: TBytes): TJuceImage; override;
    procedure FreeCanvasImage(Image: TJuceImage); override;
  public
    constructor CreateFor(ARoot: TComponent);
    destructor Destroy; override;
    { Theme, scale, parameters and images from the form, before a paint. }
    procedure Refresh;
    function ParameterCount: Integer; override;
    function FindParameter(const Id: string): Integer; override;
    function ParamNormalised(Index: Integer): Single; override;
    function ParamDefault(Index: Integer): Single; override;
    function ParamToPlain(Index: Integer; Normalised: Single): Single; override;
    function ParamFromPlain(Index: Integer; Plain: Single): Single; override;
    function ParamText(Index: Integer; Normalised: Single): string; override;
    function ParamUnits(Index: Integer): string; override;
    function ParamChoices(Index: Integer): string; override;
    property Params: TJuceParamList read FParams;
    property FormRoot: TComponent read FFormRoot;
    { Device pixels per logical pixel (the form's design PPI / 96). }
    property Scale: Single read FScale;
  end;

  TJuceDesignControl = class(TCustomControl)
  private
    FCtl: TJuceControl;
    FPaintError: string;
    {$DEFINE JUCE_DESIGN_ACCESSORS}
    {$I JuceDesignGen.inc}
    {$UNDEF JUCE_DESIGN_ACCESSORS}
    procedure SyncRuntime(Ed: TJuceDesignEditor);
{$IFNDEF FPC}
    procedure WMEraseBkgnd(var Message: TWMEraseBkgnd); message WM_ERASEBKGND;
{$ENDIF}
  protected
    class function RuntimeClass: TJuceControlClass; virtual; abstract;
    procedure Paint; override;
    { After a property change: repaint this control and the ones inside it. }
    procedure PropertyChanged;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { Draw this control as the designer shows it: the run-time Paint of its
      design-time ancestors (backgrounds) and of itself, on a TJuceTCanvas,
      copied to Target at (X, Y). Used by Paint, and by tests and previews. }
    procedure RenderTo(Target: TCanvas; X, Y: Integer);
    { The editor of the form this control is on (created on demand). }
    function DesignEditor: TJuceDesignEditor;
    { The run-time control whose properties this control edits. }
    property Runtime: TJuceControl read FCtl;
  published
    property Caption;
    property Enabled;
    property Visible;
    property Hint;
  end;

  {$DEFINE JUCE_DESIGN_CLASSES}
  {$I JuceDesignGen.inc}
  {$UNDEF JUCE_DESIGN_CLASSES}

  { A PNG or JPEG embedded in the form; controls name it in FilmstripImage
    or BackgroundImage. FileName is where it was loaded from (setting it
    loads the file; relative names are relative to the form's unit). }
  TJuceImageResource = class(TComponent)
  private
    FFileName: string;
    FData: TBytes;
    FStamp: Integer;
    procedure SetFileName(const Value: string);
    procedure ReadData(Stream: TStream);
    procedure WriteData(Stream: TStream);
  protected
    procedure DefineProperties(Filer: TFiler); override;
  public
    procedure LoadFromFile(const AFileName: string);
    procedure SetData(const Data: TBytes);
    property Data: TBytes read FData;
    { Changes whenever Data does. }
    property Stamp: Integer read FStamp;
  published
    property FileName: string read FFileName write SetFileName;
  end;

  { The editor's theme, in the form: the colours every control uses where its
    own colour is 0 ("(theme)"), and the font name and size. One per form;
    the property list is generated from JuceUI.TJuceTheme. }
  TJuceThemeResource = class(TComponent)
  private
    FTheme: TJuceTheme;
    function GetColor(Index: Integer): TJuceColor;
    procedure SetColor(Index: Integer; Value: TJuceColor);
    function GetString(Index: Integer): string;
    procedure SetString(Index: Integer; const Value: string);
    function GetSingle(Index: Integer): Single;
    procedure SetSingle(Index: Integer; Value: Single);
    procedure Changed;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    property Theme: TJuceTheme read FTheme;
  published
    {$DEFINE JUCE_DESIGN_THEME}
    {$I JuceDesignGen.inc}
    {$UNDEF JUCE_DESIGN_THEME}
  end;

const
  JuceImageResourceMaxBytes = 8 * 1024 * 1024; { the loader's limit for one image }

var
  { Set by the IDE package: the file name of the unit a designed form
    belongs to (parameter list and relative image paths are looked up next
    to it). Without it, JuceDesignFormDirectory is used. }
  JuceDesignRootFileName: function(Root: TComponent): string = nil;
  { Fallback directory for the above (tests, previews). }
  JuceDesignFormDirectory: string = '';

{ The design-time classes, in palette order. }
function JuceDesignClasses: TArray<TJuceDesignControlClass>;
{ RegisterClasses for all of them, TJuceImageResource and TJuceThemeResource
  (form streaming). }
procedure JuceDesignRegisterClasses;
{ The directory of a form's unit ('' if unknown). }
function JuceDesignDirectoryOf(Root: TComponent): string;
{ The editor for a form (lookup root), created on demand, freed with it. }
function JuceDesignEditorFor(Root: TComponent): TJuceDesignEditor;

{ RTTI helpers used by the generated accessors. }
function JuceDesignGetOrd(Obj: TObject; const Name: string): Int64;
procedure JuceDesignSetOrd(Obj: TObject; const Name: string; Value: Int64);
function JuceDesignGetFloat(Obj: TObject; const Name: string): Single;
procedure JuceDesignSetFloat(Obj: TObject; const Name: string; Value: Single);
function JuceDesignGetStr(Obj: TObject; const Name: string): string;
procedure JuceDesignSetStr(Obj: TObject; const Name: string; const Value: string);

implementation

uses
  Math;

{ ---------------------------------------------------------------------------- }
{ RTTI helpers                                                                 }
{ ---------------------------------------------------------------------------- }

function JuceDesignGetOrd(Obj: TObject; const Name: string): Int64;
begin
  Result := GetOrdProp(Obj, Name);
end;

procedure JuceDesignSetOrd(Obj: TObject; const Name: string; Value: Int64);
begin
  {$IFDEF FPC}
  SetOrdProp(Obj, Name, Value);
  {$ELSE}
  SetOrdProp(Obj, Name, Integer(Value and $FFFFFFFF)); { Cardinal colours: the bits }
  {$ENDIF}
end;

function JuceDesignGetFloat(Obj: TObject; const Name: string): Single;
begin
  Result := GetFloatProp(Obj, Name);
end;

procedure JuceDesignSetFloat(Obj: TObject; const Name: string; Value: Single);
begin
  if IsNan(Value) or IsInfinite(Value) then
    Exit;
  SetFloatProp(Obj, Name, Value);
end;

function JuceDesignGetStr(Obj: TObject; const Name: string): string;
begin
  Result := GetStrProp(Obj, Name);
end;

procedure JuceDesignSetStr(Obj: TObject; const Name: string; const Value: string);
begin
  SetStrProp(Obj, Name, Value);
end;

{ ---------------------------------------------------------------------------- }
{ TJuceParamList                                                               }
{ ---------------------------------------------------------------------------- }

function InvFS: TFormatSettings;
begin
  {$IFDEF FPC}
  Result := DefaultFormatSettings;
  {$ELSE}
  Result := TFormatSettings.Create;
  {$ENDIF}
  Result.DecimalSeparator := '.';
  Result.ThousandSeparator := ',';
end;

procedure TJuceParamList.Clear;
begin
  SetLength(FItems, 0);
  FSource := '';
end;

procedure TJuceParamList.Add(const Info: TJuceParamInfo);
begin
  if (Info.Id = '') or (IndexOf(Info.Id) >= 0) or (Length(FItems) >= 10000) then
    Exit;
  SetLength(FItems, Length(FItems) + 1);
  FItems[High(FItems)] := Info;
end;

function TJuceParamList.Count: Integer;
begin
  Result := Length(FItems);
end;

function TJuceParamList.Item(Index: Integer): TJuceParamInfo;
begin
  Result := FItems[Index];
end;

function TJuceParamList.IndexOf(const Id: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FItems) do
    if FItems[I].Id = Id then { ids are case-sensitive, like the wrapper's }
      Exit(I);
  Result := -1;
end;

function ChoiceCount(const Choices: string): Integer;
var
  I: Integer;
begin
  if Choices = '' then
    Exit(0);
  Result := 1;
  for I := 1 to Length(Choices) do
    if Choices[I] = '|' then
      Inc(Result);
end;

function ChoiceAt(const Choices: string; Index: Integer): string;
var
  S: string;
  I, P: Integer;
begin
  S := Choices;
  for I := 1 to Index do
  begin
    P := Pos('|', S);
    if P = 0 then
      Exit('');
    Delete(S, 1, P);
  end;
  P := Pos('|', S);
  if P > 0 then
    S := Copy(S, 1, P - 1);
  Result := S;
end;

function TJuceParamList.NormalisedDefault(Index: Integer): Single;
var
  P: TJuceParamInfo;
  N: Integer;
begin
  Result := 0;
  if (Index < 0) or (Index > High(FItems)) then
    Exit;
  P := FItems[Index];
  if not P.Known then
    Exit;
  case P.Kind of
    jpkBool:
      if P.DefaultValue >= 0.5 then
        Result := 1;
    jpkChoice:
      begin
        N := ChoiceCount(P.Choices);
        if N > 1 then
          Result := EnsureRange(Round(P.DefaultValue), 0, N - 1) / (N - 1);
      end;
  else
    if P.MaxValue > P.MinValue then
      Result := EnsureRange((EnsureRange(P.DefaultValue, P.MinValue, P.MaxValue) - P.MinValue) / (P.MaxValue - P.MinValue), 0, 1);
  end;
end;

function TJuceParamList.Text(Index: Integer; Normalised: Single): string;
var
  P: TJuceParamInfo;
  Plain: Double;
  N: Integer;
begin
  Result := '';
  if (Index < 0) or (Index > High(FItems)) then
    Exit;
  P := FItems[Index];
  if not P.Known then
    Exit(FormatFloat('0.00', Normalised, InvFS));
  Normalised := EnsureRange(Normalised, 0, 1);
  case P.Kind of
    jpkBool:
      if Normalised >= 0.5 then Result := 'On' else Result := 'Off';
    jpkChoice:
      begin
        N := ChoiceCount(P.Choices);
        if N > 0 then
          Result := ChoiceAt(P.Choices, EnsureRange(Round(Normalised * (N - 1)), 0, N - 1));
      end;
    jpkInt:
      Result := IntToStr(Round(P.MinValue + Normalised * (P.MaxValue - P.MinValue)));
  else
    begin
      Plain := P.MinValue + Normalised * (P.MaxValue - P.MinValue);
      if P.Step > 0 then
        Plain := P.MinValue + Round((Plain - P.MinValue) / P.Step) * P.Step;
      Result := FormatFloat('0.00', Plain, InvFS); { JUCE: String(value, 2) }
    end;
  end;
end;

function SplitTabs(const Line: string): TArray<string>;
var
  I, Start: Integer;
begin
  Result := nil;
  Start := 1;
  for I := 1 to Length(Line) + 1 do
    if (I > Length(Line)) or (Line[I] = #9) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Copy(Line, Start, I - Start);
      Start := I + 1;
    end;
end;

function TJuceParamList.LoadFromFile(const FileName: string): Boolean;
var
  L: TStringList;
  I: Integer;
  F: TArray<string>;
  P: TJuceParamInfo;
  FS: TFormatSettings;
begin
  Clear;
  Result := False;
  if not FileExists(FileName) then
    Exit;
  FS := InvFS;
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(FileName);
    except
      Exit;
    end;
    for I := 0 to Min(L.Count, 20000) - 1 do
    begin
      if (L[I] = '') or (L[I][1] = '#') then
        Continue;
      F := SplitTabs(L[I]);
      if Length(F) < 9 then
        Continue;
      P.Id := F[0];
      if F[1] = 'int' then P.Kind := jpkInt
      else if F[1] = 'bool' then P.Kind := jpkBool
      else if F[1] = 'choice' then P.Kind := jpkChoice
      else P.Kind := jpkFloat;
      P.Name := F[2];
      P.Units := F[3];
      P.MinValue := StrToFloatDef(F[4], 0, FS);
      P.MaxValue := StrToFloatDef(F[5], 1, FS);
      P.DefaultValue := StrToFloatDef(F[6], 0, FS);
      P.Step := StrToFloatDef(F[7], 0, FS);
      P.Choices := F[8];
      P.Known := True;
      Add(P);
    end;
    FSource := FileName;
    Result := True;
  finally
    L.Free;
  end;
end;

{ --- the source fallback: a tiny Pascal tokenizer -------------------------- }

type
  TArgKind = (akNone, akString, akNumber, akList, akIdent, akOther);
  TArg = record
    Kind: TArgKind;
    S: string;
    N: Double;
  end;

function ParseArgs(const Src: string; var P: Integer; out Args: TArray<TArg>): Boolean;
var
  Depth, Q: Integer;
  Cur: TArg;
  Neg: Boolean;
  Num: string;

  procedure Push;
  begin
    SetLength(Args, Length(Args) + 1);
    Args[High(Args)] := Cur;
    Cur.Kind := akNone;
    Cur.S := '';
    Cur.N := 0;
  end;

  function ReadStr: string;
  begin
    Result := '';
    while P <= Length(Src) do
    begin
      if Src[P] = '''' then
      begin
        Inc(P);
        while (P <= Length(Src)) and (Src[P] <> '''') do
        begin
          Result := Result + Src[P];
          Inc(P);
        end;
        Inc(P);
        if (P <= Length(Src)) and (Src[P] = '''') then
          Result := Result + ''''
        else if (P <= Length(Src)) and (Src[P] = '#') then
          Continue
        else
          Exit;
      end
      else if Src[P] = '#' then
      begin
        Inc(P);
        Q := P;
        while (P <= Length(Src)) and CharInSet(Src[P], ['0'..'9']) do
          Inc(P);
        Result := Result + Chr(StrToIntDef(Copy(Src, Q, P - Q), 32) and $7F);
      end
      else
        Exit;
    end;
  end;

begin
  Result := False;
  SetLength(Args, 0);
  Cur.Kind := akNone;
  Cur.S := '';
  Cur.N := 0;
  Depth := 0;
  Neg := False;
  while P <= Length(Src) do
  begin
    case Src[P] of
      '''', '#':
        if Depth = 0 then
        begin
          Cur.S := ReadStr;
          if Cur.Kind = akNone then
            Cur.Kind := akString
          else
            Cur.Kind := akOther;
          Continue;
        end
        else
        begin
          Cur.S := Cur.S + ReadStr + '|';
          Continue;
        end;
      '[':
        begin
          Inc(Depth);
          if Depth = 1 then
          begin
            Cur.Kind := akList;
            Cur.S := '';
          end;
        end;
      ']':
        begin
          Dec(Depth);
          if (Depth = 0) and (Cur.Kind = akList) and (Cur.S <> '') and (Cur.S[Length(Cur.S)] = '|') then
            Delete(Cur.S, Length(Cur.S), 1);
        end;
      '(':
        Inc(Depth);
      ')':
        if Depth = 0 then
        begin
          if Cur.Kind <> akNone then
            Push;
          Inc(P);
          Exit(True);
        end
        else
          Dec(Depth);
      ',':
        if Depth = 0 then
        begin
          Push;
          Neg := False;
        end;
      '-':
        if (Depth = 0) and (Cur.Kind = akNone) then
          Neg := True;
      '0'..'9', '.':
        if (Depth = 0) and (Cur.Kind = akNone) then
        begin
          Q := P;
          while (P <= Length(Src)) and CharInSet(Src[P], ['0'..'9', '.', 'e', 'E']) do
            Inc(P);
          Num := Copy(Src, Q, P - Q);
          Cur.Kind := akNumber;
          Cur.N := StrToFloatDef(Num, 0, InvFS);
          if Neg then
            Cur.N := -Cur.N;
          Continue;
        end;
      'A'..'Z', 'a'..'z', '_':
        if Depth = 0 then
        begin
          Q := P;
          while (P <= Length(Src)) and CharInSet(Src[P], ['A'..'Z', 'a'..'z', '_', '0'..'9', '.']) do
            Inc(P);
          if Cur.Kind = akNone then
          begin
            Cur.Kind := akIdent;
            Cur.S := Copy(Src, Q, P - Q);
          end
          else
            Cur.Kind := akOther;
          Continue;
        end;
      '+', '*', '/':
        if (Depth = 0) and (Cur.Kind <> akNone) then
          Cur.Kind := akOther; { an expression: not a literal }
    end;
    Inc(P);
  end;
end;

function TJuceParamList.ScanSources(const Dir: string): Boolean;
const
  Kinds: array[TJuceParamKind] of string = ('JuceAddFloatParameter', 'JuceAddIntParameter',
    'JuceAddBoolParameter', 'JuceAddChoiceParameter');
var
  SR: TSearchRec;
  Files: TStringList;
  I, P, Q: Integer;
  Src, Lower: string;
  K: TJuceParamKind;
  Args: TArray<TArg>;
  Info: TJuceParamInfo;
  L: TStringList;

  function Num(Index: Integer; out V: Single): Boolean;
  begin
    Result := (Index <= High(Args)) and (Args[Index].Kind = akNumber);
    if Result then
      V := Args[Index].N;
  end;

begin
  Clear;
  Result := False;
  if (Dir = '') or not DirectoryExists(Dir) then
    Exit;
  Files := TStringList.Create;
  L := TStringList.Create;
  try
    if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*.*', faAnyFile, SR) = 0 then
    try
      repeat
        if ((SR.Attr and faDirectory) = 0) and (SR.Size < 4 * 1024 * 1024) and
          (SameText(ExtractFileExt(SR.Name), '.dpr') or SameText(ExtractFileExt(SR.Name), '.lpr')
           or SameText(ExtractFileExt(SR.Name), '.pas') or SameText(ExtractFileExt(SR.Name), '.pp')) then
          Files.Add(IncludeTrailingPathDelimiter(Dir) + SR.Name);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
    Files.Sort;
    for I := 0 to Min(Files.Count, 200) - 1 do
    begin
      try
        L.LoadFromFile(Files[I]);
      except
        Continue;
      end;
      Src := L.Text;
      Lower := LowerCase(Src);
      for K := Low(TJuceParamKind) to High(TJuceParamKind) do
      begin
        P := 1;
        repeat
          Q := Pos(LowerCase(Kinds[K]), Copy(Lower, P, MaxInt));
          if Q = 0 then
            Break;
          P := P + Q - 1 + Length(Kinds[K]);
          while (P <= Length(Src)) and (Src[P] <= ' ') do
            Inc(P);
          if (P > Length(Src)) or (Src[P] <> '(') then
            Continue;
          Inc(P);
          if not ParseArgs(Src, P, Args) then
            Break;
          if (Length(Args) < 2) or (Args[0].Kind <> akString) then
            Continue; { a declaration of the function itself, or a computed id }
          Info := Default(TJuceParamInfo);
          Info.Id := Args[0].S;
          if Args[1].Kind = akString then
            Info.Name := Args[1].S;
          Info.Kind := K;
          Info.MaxValue := 1;
          case K of
            jpkFloat, jpkInt:
              begin
                Info.Known := Num(2, Info.MinValue) and Num(3, Info.MaxValue) and Num(4, Info.DefaultValue);
                if (Length(Args) > 5) and (Args[5].Kind = akString) then
                  Info.Units := Args[5].S;
                if (K = jpkFloat) and not Num(6, Info.Step) then
                  Info.Step := 0;
              end;
            jpkBool:
              if (Length(Args) > 2) and (Args[2].Kind = akIdent) then
              begin
                Info.Known := True;
                if SameText(Args[2].S, 'True') then
                  Info.DefaultValue := 1;
              end;
            jpkChoice:
              if (Length(Args) > 2) and (Args[2].Kind = akList) then
              begin
                Info.Choices := Args[2].S;
                Info.Known := True;
                if not Num(3, Info.DefaultValue) then
                  Info.DefaultValue := 0;
              end;
          end;
          if not Info.Known then
          begin
            Info.MinValue := 0;
            Info.MaxValue := 1;
          end;
          Add(Info);
        until False;
      end;
    end;
    FSource := 'sources in ' + Dir;
    Result := Count > 0;
  finally
    Files.Free;
    L.Free;
  end;
end;

{ ---------------------------------------------------------------------------- }
{ Editors per form                                                             }
{ ---------------------------------------------------------------------------- }

type
  { Frees a form's design editor when the form goes. }
  TJuceDesignHub = class(TComponent)
  private
    FRoots: TList;
    FEditors: TList;
  protected
    procedure Notification(AComponent: TComponent; Operation: TOperation); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function EditorFor(Root: TComponent): TJuceDesignEditor;
  end;

var
  GHub: TJuceDesignHub;

procedure ReleaseEditor(Ed: TJuceDesignEditor);
begin
  { The run-time controls belong to their design-time controls: take them
    out of the tree first, so freeing the root does not free them. }
  while Ed.Root.ControlCount > 0 do
    Ed.Root.Controls[0].Parent := nil;
  Ed.Free;
end;

constructor TJuceDesignHub.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FRoots := TList.Create;
  FEditors := TList.Create;
end;

destructor TJuceDesignHub.Destroy;
var
  I: Integer;
begin
  for I := 0 to FRoots.Count - 1 do
  begin
    TComponent(FRoots[I]).RemoveFreeNotification(Self);
    ReleaseEditor(TJuceDesignEditor(FEditors[I]));
  end;
  FRoots.Free;
  FEditors.Free;
  inherited Destroy;
end;

procedure TJuceDesignHub.Notification(AComponent: TComponent; Operation: TOperation);
var
  I: Integer;
begin
  inherited Notification(AComponent, Operation);
  if (Operation <> opRemove) or (FRoots = nil) then
    Exit;
  I := FRoots.IndexOf(AComponent);
  if I >= 0 then
  begin
    ReleaseEditor(TJuceDesignEditor(FEditors[I]));
    FRoots.Delete(I);
    FEditors.Delete(I);
  end;
end;

function TJuceDesignHub.EditorFor(Root: TComponent): TJuceDesignEditor;
var
  I: Integer;
begin
  I := FRoots.IndexOf(Root);
  if I >= 0 then
    Exit(TJuceDesignEditor(FEditors[I]));
  Result := TJuceDesignEditor.CreateFor(Root);
  FRoots.Add(Root);
  FEditors.Add(Result);
  Root.FreeNotification(Self);
end;

function JuceDesignEditorFor(Root: TComponent): TJuceDesignEditor;
begin
  if GHub = nil then
    GHub := TJuceDesignHub.Create(nil);
  Result := GHub.EditorFor(Root);
end;

function JuceDesignDirectoryOf(Root: TComponent): string;
var
  F: string;
begin
  Result := '';
  if Assigned(JuceDesignRootFileName) and (Root <> nil) then
  begin
    try
      F := JuceDesignRootFileName(Root);
    except
      F := '';
    end;
    if F <> '' then
      Result := ExtractFilePath(F);
  end;
  if Result = '' then
    Result := JuceDesignFormDirectory;
end;

{ ---------------------------------------------------------------------------- }
{ TJuceDesignEditor                                                            }
{ ---------------------------------------------------------------------------- }

constructor TJuceDesignEditor.CreateFor(ARoot: TComponent);
begin
  inherited Create(nil);
  FFormRoot := ARoot;
  FParams := TJuceParamList.Create;
  FImageStamps := TStringList.Create;
  FScale := 1;
  FParamAge := -2;
end;

destructor TJuceDesignEditor.Destroy;
begin
  inherited Destroy;
  FParams.Free;
  FImageStamps.Free;
end;

function TJuceDesignEditor.CreateCanvasImage(const Data: TBytes): TJuceImage;
begin
  Result := JuceDecodeImage(Data);
end;

procedure TJuceDesignEditor.FreeCanvasImage(Image: TJuceImage);
begin
  Image.Free;
end;

procedure TJuceDesignEditor.RefreshParams;
var
  Dir, Found: string;
  SR: TSearchRec;
  Age: LongInt;
  Now_: Cardinal;
begin
  {$IFDEF FPC}
  Now_ := GetTickCount64 and $FFFFFFFF;
  {$ELSE}
  Now_ := GetTickCount;
  {$ENDIF}
  if (FParamAge <> -2) and (Now_ - FLastCheck < 2000) then
    Exit;
  FLastCheck := Now_;
  Dir := JuceDesignDirectoryOf(FFormRoot);
  Found := '';
  if Dir <> '' then
    if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*.params', faAnyFile, SR) = 0 then
    try
      Found := IncludeTrailingPathDelimiter(Dir) + SR.Name;
    finally
      FindClose(SR);
    end;
  if Found <> '' then
  begin
    Age := FileAge(Found);
    if (Found <> FParamFile) or (Age <> FParamAge) then
    begin
      FParams.LoadFromFile(Found);
      FParamFile := Found;
      FParamAge := Age;
    end;
  end
  else if (FParamFile <> '') or (FParamAge = -2) or (Dir <> FParamDir) then
  begin
    { no list exported: read the declarations from the sources }
    FParams.ScanSources(Dir);
    FParamFile := '';
    FParamAge := -1;
  end;
  FParamDir := Dir;
end;

procedure TJuceDesignEditor.RefreshImages;
var
  I, K: Integer;
  C: TComponent;
  R: TJuceImageResource;
  Stamp: string;
begin
  if FFormRoot = nil then
    Exit;
  for I := 0 to FFormRoot.ComponentCount - 1 do
  begin
    C := FFormRoot.Components[I];
    if not (C is TJuceImageResource) or (C.Name = '') then
      Continue;
    R := TJuceImageResource(C);
    Stamp := IntToStr(R.Stamp) + ':' + IntToStr(Length(R.Data));
    K := FImageStamps.IndexOfName(R.Name);
    if (K >= 0) and (FImageStamps.ValueFromIndex[K] = Stamp) and (FindImage(R.Name) <> nil) then
      Continue;
    if Length(R.Data) > 0 then
      AddImage(R.Name, R.Data);
    if K >= 0 then
      FImageStamps.ValueFromIndex[K] := Stamp
    else
      FImageStamps.Add(R.Name + '=' + Stamp);
  end;
end;

procedure TJuceDesignEditor.Refresh;
var
  C: TColor;
  RGB: Cardinal;
  PPI, I: Integer;
  Base: TJuceTheme;
begin
  FScale := 1;
  { the form's theme resource, as the loader applies it, else the default }
  Base := JuceDefaultTheme;
  if FFormRoot <> nil then
    for I := 0 to FFormRoot.ComponentCount - 1 do
      if FFormRoot.Components[I] is TJuceThemeResource then
        Base := TJuceThemeResource(FFormRoot.Components[I]).Theme;
  Theme.Assign(Base);
  if FFormRoot is TCustomForm then
  begin
    { the loader maps a plain RGB form colour to the theme background }
    C := TCustomForm(FFormRoot).Color;
    if (C >= 0) and (C <= $FFFFFF) then
    begin
      RGB := ColorToRGB(C);
      Theme.Background := $FF000000 or ((RGB and $FF) shl 16) or (RGB and $FF00) or ((RGB shr 16) and $FF);
    end;
    {$IFDEF FPC}
    PPI := TCustomForm(FFormRoot).DesignTimePPI;
    {$ELSE}
    PPI := TCustomForm(FFormRoot).PixelsPerInch;
    {$ENDIF}
    if (PPI >= 24) and (PPI <= 960) then
      FScale := PPI / 96;
  end;
  RefreshParams;
  RefreshImages;
end;

function TJuceDesignEditor.ParameterCount: Integer;
begin
  Result := FParams.Count;
end;

function TJuceDesignEditor.FindParameter(const Id: string): Integer;
begin
  Result := FParams.IndexOf(Id);
end;

function TJuceDesignEditor.ParamNormalised(Index: Integer): Single;
begin
  Result := FParams.NormalisedDefault(Index);
end;

function TJuceDesignEditor.ParamDefault(Index: Integer): Single;
begin
  Result := FParams.NormalisedDefault(Index);
end;

function TJuceDesignEditor.ParamToPlain(Index: Integer; Normalised: Single): Single;
var
  P: TJuceParamInfo;
begin
  Result := Normalised;
  if (Index < 0) or (Index >= FParams.Count) then
    Exit;
  P := FParams.Item(Index);
  Result := P.MinValue + EnsureRange(Normalised, 0, 1) * (P.MaxValue - P.MinValue);
end;

function TJuceDesignEditor.ParamFromPlain(Index: Integer; Plain: Single): Single;
var
  P: TJuceParamInfo;
begin
  Result := 0;
  if (Index < 0) or (Index >= FParams.Count) then
    Exit;
  P := FParams.Item(Index);
  if P.MaxValue > P.MinValue then
    Result := EnsureRange((Plain - P.MinValue) / (P.MaxValue - P.MinValue), 0, 1);
end;

function TJuceDesignEditor.ParamText(Index: Integer; Normalised: Single): string;
begin
  Result := FParams.Text(Index, Normalised);
end;

function TJuceDesignEditor.ParamChoices(Index: Integer): string;
begin
  Result := '';
  if (Index >= 0) and (Index < FParams.Count) and (FParams.Item(Index).Kind = jpkChoice) then
    Result := FParams.Item(Index).Choices;
end;

function TJuceDesignEditor.ParamUnits(Index: Integer): string;
begin
  if (Index >= 0) and (Index < FParams.Count) then
    Result := FParams.Item(Index).Units
  else
    Result := '';
end;

{ ---------------------------------------------------------------------------- }
{ TJuceDesignControl                                                           }
{ ---------------------------------------------------------------------------- }

{$DEFINE JUCE_DESIGN_IMPLEMENTATION}
{$I JuceDesignGen.inc}
{$UNDEF JUCE_DESIGN_IMPLEMENTATION}

constructor TJuceDesignControl.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FCtl := RuntimeClass.Create(nil);
  ControlStyle := ControlStyle - [csSetCaption] + [csOpaque];
  if FCtl is JuceControls.TJucePanel then
    ControlStyle := ControlStyle + [csAcceptsControls];
  { the run-time control's default size }
  SetBounds(Left, Top, FCtl.Width, FCtl.Height);
end;

destructor TJuceDesignControl.Destroy;
begin
  if FCtl <> nil then
  begin
    { run-time children belong to other design-time controls }
    while FCtl.ControlCount > 0 do
      FCtl.Controls[0].Parent := nil;
    FreeAndNil(FCtl);
  end;
  inherited Destroy;
end;

function TJuceDesignControl.DesignEditor: TJuceDesignEditor;
var
  Root: TComponent;
  P: TControl;
begin
  Root := Owner;
  if Root = nil then
  begin
    P := Self;
    while P.Parent <> nil do
      P := P.Parent;
    Root := P;
  end;
  Result := JuceDesignEditorFor(Root);
end;

procedure TJuceDesignControl.SyncRuntime(Ed: TJuceDesignEditor);
var
  S: Single;
  Want: TJuceControl;
begin
  S := Ed.Scale;
  if Parent is TJuceDesignControl then
    Want := TJuceDesignControl(Parent).FCtl
  else
    Want := Ed.Root;
  if FCtl.Parent <> Want then
    FCtl.Parent := Want;
  FCtl.SetBounds(Round(Left / S), Round(Top / S), Round(Width / S), Round(Height / S));
  FCtl.Caption := Caption;
  FCtl.Hint := Hint;
  FCtl.Enabled := Enabled;
  FCtl.Visible := True; { the designer shows invisible controls too }
end;

procedure TJuceDesignControl.PropertyChanged;

  procedure InvalidateTree(C: TWinControl);
  var
    I: Integer;
  begin
    C.Invalidate;
    for I := 0 to C.ControlCount - 1 do
      if C.Controls[I] is TJuceDesignControl then
        InvalidateTree(TJuceDesignControl(C.Controls[I]));
  end;

begin
  InvalidateTree(Self);
end;

procedure TJuceDesignControl.RenderTo(Target: TCanvas; X, Y: Integer);
var
  Ed: TJuceDesignEditor;
  Chain: array of TJuceDesignControl;
  P: TWinControl;
  RC: TJuceTCanvas;
  I: Integer;
  A: TJuceDesignControl;
begin
  if (Width <= 0) or (Height <= 0) then
    Exit;
  Ed := DesignEditor;
  Ed.Refresh;
  { this control and its design-time ancestors, outermost first }
  SetLength(Chain, 0);
  P := Self;
  while P is TJuceDesignControl do
  begin
    SetLength(Chain, Length(Chain) + 1);
    Chain[High(Chain)] := TJuceDesignControl(P);
    P := P.Parent;
  end;
  for I := High(Chain) downto 0 do
    Chain[I].SyncRuntime(Ed);
  FCtl.AttachAll; { bound controls take the parameter's default value }
  RC := TJuceTCanvas.Create(Width, Height, Ed.Scale);
  try
    RC.Clear(Ed.Theme.Background);
    for I := High(Chain) downto 0 do
    begin
      A := Chain[I];
      RC.SaveState;
      try
        RC.Translate(A.FCtl.AbsoluteX - FCtl.AbsoluteX, A.FCtl.AbsoluteY - FCtl.AbsoluteY);
        if RC.ClipRect(A.FCtl.BoundsRect) then
          A.FCtl.PaintControl(RC);
      finally
        RC.RestoreState;
      end;
    end;
    RC.DrawTo(Target, X, Y);
  finally
    RC.Free;
  end;
end;

procedure TJuceDesignControl.Paint;
begin
  try
    RenderTo(Canvas, 0, 0);
    FPaintError := '';
  except
    on E: Exception do
    begin
      FPaintError := E.Message;
      Canvas.Brush.Color := clMaroon;
      Canvas.FillRect(Rect(0, 0, Width, Height));
      Canvas.Font.Color := clWhite;
      Canvas.TextOut(2, 2, E.ClassName);
    end;
  end;
end;

{$IFNDEF FPC}
procedure TJuceDesignControl.WMEraseBkgnd(var Message: TWMEraseBkgnd);
begin
  Message.Result := 1; { Paint covers everything }
end;
{$ENDIF}

{ ---------------------------------------------------------------------------- }
{ TJuceImageResource                                                           }
{ ---------------------------------------------------------------------------- }

procedure TJuceImageResource.SetData(const Data: TBytes);
begin
  if Length(Data) > JuceImageResourceMaxBytes then
    raise EInvalidOperation.CreateFmt('%s: an image of %d bytes is larger than the layout limit (%d)',
      [Name, Length(Data), JuceImageResourceMaxBytes]);
  FData := Copy(Data);
  Inc(FStamp);
end;

procedure TJuceImageResource.LoadFromFile(const AFileName: string);
var
  F: TFileStream;
  D: TBytes;
  Img: TJuceRasterImage;
begin
  F := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    if F.Size > JuceImageResourceMaxBytes then
      raise EInvalidOperation.CreateFmt('%s is larger than the layout limit (%d bytes)', [AFileName, JuceImageResourceMaxBytes]);
    SetLength(D, F.Size);
    if F.Size > 0 then
      F.ReadBuffer(D[0], F.Size);
  finally
    F.Free;
  end;
  Img := JuceDecodeImage(D);
  if Img = nil then
    raise EInvalidOperation.CreateFmt('%s is not a PNG, JPEG or BMP image', [AFileName]);
  Img.Free; { it decodes: keep the original bytes }
  SetData(D);
end;

procedure TJuceImageResource.SetFileName(const Value: string);
var
  Path: string;
begin
  FFileName := Value;
  if (csLoading in ComponentState) or (Value = '') then
    Exit; { the data comes from the form }
  Path := Value;
  if not FileExists(Path) and (Owner <> nil) then
    Path := JuceDesignDirectoryOf(Owner) + Value;
  if FileExists(Path) then
    LoadFromFile(Path);
end;

procedure TJuceImageResource.ReadData(Stream: TStream);
var
  D: TBytes;
begin
  if Stream.Size - Stream.Position > JuceImageResourceMaxBytes then
    raise EReadError.Create('TJuceImageResource: image data too large');
  SetLength(D, Stream.Size - Stream.Position);
  if Length(D) > 0 then
    Stream.ReadBuffer(D[0], Length(D));
  SetData(D);
end;

procedure TJuceImageResource.WriteData(Stream: TStream);
begin
  if Length(FData) > 0 then
    Stream.WriteBuffer(FData[0], Length(FData));
end;

procedure TJuceImageResource.DefineProperties(Filer: TFiler);
begin
  inherited DefineProperties(Filer);
  Filer.DefineBinaryProperty('ImageData', ReadData, WriteData, Length(FData) > 0);
end;

{ ---------------------------------------------------------------------------- }
{ TJuceThemeResource                                                           }
{ ---------------------------------------------------------------------------- }

constructor TJuceThemeResource.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FTheme := TJuceTheme.Create;
end;

destructor TJuceThemeResource.Destroy;
begin
  Changed; { the form goes back to the default theme }
  FreeAndNil(FTheme);
  inherited Destroy;
end;

{ Every design-time control of the form paints with the theme: repaint them. }
procedure TJuceThemeResource.Changed;
var
  I: Integer;
  Root: TComponent;
begin
  Root := Owner;
  if (Root = nil) or (csDestroying in Root.ComponentState) then
    Exit;
  for I := 0 to Root.ComponentCount - 1 do
    if Root.Components[I] is TJuceDesignControl then
      TJuceDesignControl(Root.Components[I]).Invalidate;
end;

function TJuceThemeResource.GetColor(Index: Integer): TJuceColor;
begin
  Result := TJuceColor(JuceDesignGetOrd(FTheme, JuceDesignThemeNames[Index]));
end;

procedure TJuceThemeResource.SetColor(Index: Integer; Value: TJuceColor);
begin
  JuceDesignSetOrd(FTheme, JuceDesignThemeNames[Index], Value);
  Changed;
end;

function TJuceThemeResource.GetString(Index: Integer): string;
begin
  Result := JuceDesignGetStr(FTheme, JuceDesignThemeNames[Index]);
end;

procedure TJuceThemeResource.SetString(Index: Integer; const Value: string);
begin
  JuceDesignSetStr(FTheme, JuceDesignThemeNames[Index], Value);
  Changed;
end;

function TJuceThemeResource.GetSingle(Index: Integer): Single;
begin
  Result := JuceDesignGetFloat(FTheme, JuceDesignThemeNames[Index]);
end;

procedure TJuceThemeResource.SetSingle(Index: Integer; Value: Single);
begin
  JuceDesignSetFloat(FTheme, JuceDesignThemeNames[Index], Value);
  Changed;
end;

{ ---------------------------------------------------------------------------- }
{ Registration helpers                                                         }
{ ---------------------------------------------------------------------------- }

function JuceDesignClasses: TArray<TJuceDesignControlClass>;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(JuceDesignClassList));
  for I := 0 to High(JuceDesignClassList) do
    Result[I] := JuceDesignClassList[I];
end;

procedure JuceDesignRegisterClasses;
var
  I: Integer;
begin
  for I := 0 to High(JuceDesignClassList) do
    RegisterClass(JuceDesignClassList[I]);
  RegisterClass(TJuceImageResource);
  RegisterClass(TJuceThemeResource);
end;

initialization

finalization
  FreeAndNil(GHub);

end.
