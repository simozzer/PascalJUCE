(*
  Unit tests for the run-time layout loader (pascal/JuceLayout.pas): form
  files designed in Lazarus (.lfm) or Delphi (.dfm) turned into editor
  controls, without LCL or VCL.

    - the PascalSynth form, embedded with {$R} exactly as the plug-in does,
      gives the same control tree as the code-built panel it replaced, and
      the .dfm gives the same tree as the .lfm;
    - every control class and every published property round-trips
      text -> binary -> controls, events bind to published editor methods;
    - form properties: size, background, hint, DesignTimePPI/PixelsPerInch
      scaling, IDE-only properties ignored;
    - strict and lenient handling of unknown classes and properties;
    - malformed streams: every truncation, random mutations, huge length
      fields, oversized input, deep nesting, too many objects/properties,
      duplicate names, both meanings of value type 21; loading is atomic.

  Run with the repository root as the first argument (for the .dfm file).
  Build with checks on: fpc -Mdelphi -Cr -Co -Ct -CR -gl -gh ...
*)
program test_layout_unit;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ENDIF}
{$APPTYPE CONSOLE}

uses
  SysUtils, Classes, TypInfo, Math, JuceTypes, JucePlugin, JuceCanvas, JuceUI, JuceControls, JuceLayout,
  TestFramework;

{ The same resource the plug-in embeds (named TSYNTHEDITORFORM). }
{$R ../../examples/plugins/PascalSynth/SynthEditorForm.lfm}

type
  { An editor with a published event handler and a fake image decoder. }
  TTestEditor = class(TJuceEditor)
  public
    function CreateCanvasImage(const Data: TBytes): TJuceImage; override;
  public
    Changes: Integer;
  published
    procedure KnobChanged(Sender: TObject);
    procedure MenuHandler(Sender: TJuceControl; X, Y: Single; var Handled: Boolean);
  end;

  TFakeImage = class(TJuceImage)
  public
    function Width: Integer; override;
    function Height: Integer; override;
  end;

  { A user control registered with JuceRegisterLayoutClass. }
  TMyDial = class(TJuceKnob)
  private
    FNotches: Integer;
  published
    property Notches: Integer read FNotches write FNotches;
  end;

var
  RootDir: string;

function TFakeImage.Width: Integer;
begin
  Result := 64;
end;

function TFakeImage.Height: Integer;
begin
  Result := 640;
end;

function TTestEditor.CreateCanvasImage(const Data: TBytes): TJuceImage;
begin
  if (Length(Data) >= 4) and (Data[0] = $89) and (Data[1] = Ord('P')) then
    Result := TFakeImage.Create
  else
    Result := nil;
end;

procedure TTestEditor.KnobChanged(Sender: TObject);
begin
  Inc(Changes);
end;

procedure TTestEditor.MenuHandler(Sender: TJuceControl; X, Y: Single; var Handled: Boolean);
begin
  Handled := True;
end;

function NewEditor: TTestEditor;
begin
  Result := TTestEditor.Create(nil);
end;

function Bytes(const S: UTF8String): TBytes;
begin
  SetLength(Result, Length(S));
  if Length(S) > 0 then
    Move(S[1], Result[0], Length(S));
end;

function FileBytes(const FileName: string): TBytes;
var
  F: TFileStream;
begin
  F := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, F.Size);
    if F.Size > 0 then
      F.ReadBuffer(Result[0], F.Size);
  finally
    F.Free;
  end;
end;

function ResourceBytes(const Name: string): TBytes;
var
  R: TResourceStream;
begin
  R := TResourceStream.Create(HInstance, Name, PChar(10));
  try
    SetLength(Result, R.Size);
    R.ReadBuffer(Result[0], R.Size);
  finally
    R.Free;
  end;
end;

{ Loads; returns '' or the error message (and the class of other exceptions). }
function TryLoad(Ed: TJuceEditor; const Data: TBytes; StrictMode: Boolean; Warnings: TStrings = nil): string;
var
  L: TJuceLayoutLoader;
begin
  Result := '';
  L := TJuceLayoutLoader.Create(Ed);
  try
    L.StrictMode := StrictMode;
    try
      L.LoadFromBytes(Data);
    except
      on E: EJuceLayoutError do
        Result := E.Message;
      on E: Exception do
        Result := 'UNEXPECTED ' + E.ClassName + ': ' + E.Message;
    end;
    if Warnings <> nil then
      Warnings.Assign(L.Warnings);
  finally
    L.Free;
  end;
end;

function TryLoadText(Ed: TJuceEditor; const Text: UTF8String; StrictMode: Boolean; Warnings: TStrings = nil): string;
begin
  Result := TryLoad(Ed, Bytes(Text), StrictMode, Warnings);
end;

{ ---------------------------------------------------------------------------- }
{ Tree comparison through RTTI                                                 }
{ ---------------------------------------------------------------------------- }

function PropText(Obj: TObject; Info: PPropInfo): string;
var
  TI: PTypeInfo;
begin
  {$IFDEF FPC}
  TI := Info^.PropType;
  {$ELSE}
  TI := Info^.PropType^;
  {$ENDIF}
  case TI^.Kind of
    tkInteger, tkEnumeration {$IFDEF FPC}, tkBool{$ENDIF}: Result := IntToStr(GetOrdProp(Obj, Info));
    tkFloat: Result := FloatToStr(GetFloatProp(Obj, Info));
    tkMethod: Result := IntToHex(PtrUInt(GetMethodProp(Obj, Info).Code), 16);
  else
    Result := GetStrProp(Obj, Info);
  end;
end;

function SameTree(A, B: TJuceControl; const Path: string; out Why: string): Boolean;
var
  List: PPropList;
  N, I: Integer;
  VA, VB: string;
begin
  Result := False;
  if A.ClassType <> B.ClassType then
  begin
    Why := Path + ': class ' + A.ClassName + ' vs ' + B.ClassName;
    Exit;
  end;
  N := GetPropList(A, List);
  try
    for I := 0 to N - 1 do
    begin
      VA := PropText(A, List^[I]);
      VB := PropText(B, List^[I]);
      if VA <> VB then
      begin
        Why := Format('%s.%s: %s vs %s', [Path, string(List^[I]^.Name), VA, VB]);
        Exit;
      end;
    end;
  finally
    FreeMem(List);
  end;
  if A.ControlCount <> B.ControlCount then
  begin
    Why := Format('%s: %d vs %d children', [Path, A.ControlCount, B.ControlCount]);
    Exit;
  end;
  for I := 0 to A.ControlCount - 1 do
    if not SameTree(A.Controls[I], B.Controls[I], Path + '/' + A.Controls[I].Name, Why) then
      Exit;
  Result := True;
end;

procedure CheckTree(A, B: TJuceControl; const What: string);var  Why: string;  Same: Boolean;begin  Why := '';  Same := SameTree(A, B, 'Root', Why);  if Same then    Check(True, What)  else    Check(False, What + ': ' + Why);end;
{ The PascalSynth panel as SynthEditor.pas built it in code before Phase 2. }
procedure BuildSynthInCode(Ed: TJuceEditor);
var
  Panel: TJucePanel;
  Wave: TJuceSwitch;
  Meter: TJuceMeter;
  Caption: TJuceLabel;

  procedure AddKnob(const Name, Id, Title, Tip: string; X: Integer);
  var
    Knob: TJuceKnob;
  begin
    Knob := TJuceKnob.Create(Panel);
    Knob.Name := Name;
    Knob.SetBounds(X, 44, 76, 104);
    Knob.Caption := Title;
    Knob.ParameterId := Id;
    Knob.Hint := Tip;
  end;

begin
  Ed.SetSize(480, 210);
  Ed.Root.SetBounds(0, 0, Ed.Width, Ed.Height);
  Panel := TJucePanel.Create(Ed.Root);
  Panel.Name := 'MainPanel';
  Panel.SetBounds(6, 6, 468, 198);
  Panel.Caption := 'PASCAL SYNTH';
  Panel.Color := $FF30343B;
  Panel.GradientColor := $FF23262B;
  Wave := TJuceSwitch.Create(Panel);
  Wave.Name := 'Wave';
  Wave.SetBounds(16, 60, 150, 64);
  Wave.Caption := 'WAVE';
  Wave.Positions := 3;
  Wave.Labels := 'Sine|Saw|Square';
  Wave.ParameterId := 'wave';
  Wave.Hint := 'Oscillator waveform';
  AddKnob('Attack', 'attack', 'ATTACK', 'Attack time', 180);
  AddKnob('Release', 'release', 'RELEASE', 'Release time', 262);
  AddKnob('Gain', 'gain', 'GAIN', 'Output level', 344);
  Meter := TJuceMeter.Create(Panel);
  Meter.Name := 'OutMeter';
  Meter.SetBounds(436, 36, 14, 132);
  Meter.MeterIndex := 0;
  Meter.Hint := 'Output peak';
  Caption := TJuceLabel.Create(Panel);
  Caption.Name := 'OutLabel';
  Caption.SetBounds(416, 170, 54, 18);
  Caption.Caption := 'OUT';
  Caption.FontSize := 11;
  Caption.Color := Ed.Theme.TextDim;
  Caption := TJuceLabel.Create(Panel);
  Caption.Name := 'HelpLabel';
  Caption.SetBounds(16, 170, 300, 18);
  Caption.Caption := 'Drag: change   Shift: fine   Double-click: default';
  Caption.FontSize := 11;
  Caption.Alignment := jaLeft;
  Caption.Color := Ed.Theme.TextDim;
end;

{ ---------------------------------------------------------------------------- }
{ The PascalSynth form                                                         }
{ ---------------------------------------------------------------------------- }

procedure TestSynthForm;
var
  Code, FromRes, FromDfm: TTestEditor;
  Why: string;
  Knob: TJuceControl;
  Dfm: string;
begin
  Suite('PascalSynth form');
  Code := NewEditor;
  FromRes := NewEditor;
  FromDfm := NewEditor;
  try
    BuildSynthInCode(Code);
    JuceLoadLayoutResource(FromRes, 'TSynthEditorForm');
    CheckEquals(480, FromRes.Width, 'ClientWidth sets the editor width');
    CheckEquals(210, FromRes.Height, 'ClientHeight sets the editor height');
    CheckEquals(480, FromRes.Root.Width, 'root follows the editor size');
    Check(FromRes.Theme.Background = $FF1E2024, 'form Color ($0024201E) is the theme background');
    CheckEquals(1, FromRes.Root.ControlCount, 'one top-level control');
    CheckTree(Code.Root, FromRes.Root, 'resource tree equals the code-built panel');
    Knob := FromRes.FindControl('gain');
    Check((Knob is TJuceKnob) and (TJuceKnob(Knob).ParameterId = 'gain'), 'FindControl is case-insensitive and finds nested controls');
    Check(FromRes.FindControl('Nope') = nil, 'FindControl gives nil for an unknown name');
    Check(FromRes.Root.Controls[0].Controls[0].Name = 'Wave', 'creation order is the form''s order');

    Dfm := RootDir + 'examples' + PathDelim + 'plugins' + PathDelim + 'PascalSynth' + PathDelim + 'SynthEditorForm.dfm';
    if FileExists(Dfm) then
    begin
      CheckEquals('', TryLoad(FromDfm, FileBytes(Dfm), True), 'the .dfm loads in strict mode');
      CheckTree(FromRes.Root, FromDfm.Root, 'the .dfm gives the same tree as the .lfm');
      CheckEquals(480, FromDfm.Width, '.dfm ClientWidth');
    end
    else
      Skip('.dfm', 'repository root not given (' + Dfm + ')');
  finally
    Code.Free;
    FromRes.Free;
    FromDfm.Free;
  end;
end;

{ ---------------------------------------------------------------------------- }
{ Every class, every property                                                  }
{ ---------------------------------------------------------------------------- }

function TypeOf(Info: PPropInfo): PTypeInfo;
begin
  {$IFDEF FPC}
  Result := Info^.PropType;
  {$ELSE}
  Result := Info^.PropType^;
  {$ENDIF}
end;

function IsBaseOrEvent(Info: PPropInfo): Boolean;
begin
  Result := TypeOf(Info)^.Kind = tkMethod;
end;

function Quote(const S: string): string;
begin
  Result := '''' + StringReplace(S, '''', '''''', [rfReplaceAll]) + '''';
end;

{ Sets a non-default value on Ctl and returns its lfm text. }
function TestValue(Ctl: TJuceControl; Info: PPropInfo; Seed: Integer): string;
var
  TI: PTypeInfo;
  TD: PTypeData;
  FS: TFormatSettings;
  E: Integer;
  F: Double;
  S: string;
  C: Cardinal;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  TI := TypeOf(Info);
  TD := GetTypeData(TI);
  case TI^.Kind of
    tkInteger:
      if TD^.OrdType = otULong then
      begin
        C := $80000000 or Cardinal(Seed * 7919);
        SetOrdProp(Ctl, Info, C);
        if Seed mod 2 = 0 then
          Result := IntToStr(C)
        else
          Result := '$' + IntToHex(C, 8);
      end
      else
      begin
        E := (GetOrdProp(Ctl, Info) + 3 + Seed) mod 1000;
        if string(Info^.Name) = 'Positions' then
          E := 3;
        SetOrdProp(Ctl, Info, E);
        Result := IntToStr(GetOrdProp(Ctl, Info)); { the setter may clamp }
      end;
    tkInt64:
      begin
        SetInt64Prop(Ctl, Info, 1000 + Seed);
        Result := IntToStr(1000 + Seed);
      end;
    tkEnumeration {$IFDEF FPC}, tkBool{$ENDIF}:
      begin
        E := (GetOrdProp(Ctl, Info) + 1);
        if E > TD^.MaxValue then
          E := TD^.MinValue;
        SetOrdProp(Ctl, Info, E);
        Result := GetEnumName(TI, E);
      end;
    tkFloat:
      begin
        F := -135.25 + Seed * 0.5;
        SetFloatProp(Ctl, Info, F);
        Result := FloatToStr(F, FS);
      end;
  else
    begin
      S := Format('Text %d: it''s "%s" Ünïcödé €', [Seed, string(Info^.Name)]);
      SetStrProp(Ctl, Info, S);
      Result := Quote(S);
    end;
  end;
end;

procedure TestEveryProperty;
var
  Expected, Loaded: TTestEditor;
  Panel, Ctl: TJuceControl;
  I, J, N, Seed: Integer;
  List: PPropList;
  Text, Why, Err: string;
  Cls: TJuceControlClass;
  Bin: TBytes;
  M: TMethod;
begin
  Suite('every class and property: text -> binary -> controls');
  Expected := NewEditor;
  Loaded := NewEditor;
  try
    Expected.SetSize(640, 400);
    Expected.Root.SetBounds(0, 0, 640, 400);
    Panel := TJucePanel.Create(Expected.Root);
    Panel.Name := 'Holder';
    Text := 'object TestForm: TTestForm' + LineEnding + '  ClientWidth = 640' + LineEnding +
      '  ClientHeight = 400' + LineEnding + '  object Holder: TJucePanel' + LineEnding;
    { the panel itself keeps its defaults, except bounds }
    Panel.SetBounds(1, 2, 300, 200);
    Text := Text + '    Left = 1' + LineEnding + '    Top = 2' + LineEnding + '    Width = 300' + LineEnding +
      '    Height = 200' + LineEnding;
    Seed := 1;
    for I := Low(JuceControlClasses) to High(JuceControlClasses) do
    begin
      Cls := JuceControlClasses[I];
      Ctl := Cls.Create(Panel);
      Ctl.Name := 'C' + IntToStr(I);
      Text := Text + '    object C' + IntToStr(I) + ': ' + Cls.ClassName + LineEnding;
      N := GetPropList(Ctl, List);
      try
        for J := 0 to N - 1 do
        begin
          if IsBaseOrEvent(List^[J]) or (string(List^[J]^.Name) = 'Name') then
            Continue;
          Inc(Seed);
          Text := Text + '      ' + string(List^[J]^.Name) + ' = ' + TestValue(Ctl, List^[J], Seed) + LineEnding;
        end;
      finally
        FreeMem(List);
      end;
      if Ctl is TJuceParamControl then
      begin
        Text := Text + '      OnChange = KnobChanged' + LineEnding;
        TJuceParamControl(Ctl).OnChange := Expected.KnobChanged;
      end;
      Text := Text + '      OnContextMenu = MenuHandler' + LineEnding;
      Ctl.OnContextMenu := Expected.MenuHandler;
      Text := Text + '    end' + LineEnding;
    end;
    Text := Text + '  end' + LineEnding + 'end' + LineEnding;

    Bin := JuceLayoutTextToBinary(Bytes(UTF8String(Text)));
    Check((Length(Bin) > 4) and (Bin[0] = Ord('T')) and (Bin[3] = Ord('0')), 'text converts to a TPF0 stream');
    Err := TryLoad(Loaded, Bin, True);
    CheckEquals('', Err, 'the binary stream loads in strict mode');
    CheckTree(Expected.Root, Loaded.Root, 'every published property of every class round-trips');
    Ctl := Loaded.FindControl('C0');
    if Ctl <> nil then
    begin
      M := TMethod(TJuceParamControl(Ctl).OnChange);
      Check((M.Data = Pointer(Loaded)) and (M.Code = Loaded.MethodAddress('KnobChanged')),
        'OnChange binds to the editor''s published method');
      M := TMethod(Ctl.OnContextMenu);
      Check((M.Data = Pointer(Loaded)) and (M.Code = Loaded.MethodAddress('MenuHandler')),
        'OnContextMenu binds to the editor''s published method');
    end;
    Check((Loaded.FindControl('Holder') <> nil) and (Loaded.FindControl('Holder').ControlCount = Length(JuceControlClasses)), 'one control per class');
  finally
    Expected.Free;
    Loaded.Free;
  end;
end;

{ ---------------------------------------------------------------------------- }
{ Form properties, scaling, strictness                                         }
{ ---------------------------------------------------------------------------- }

const
  NL = #10;

procedure TestFormProperties;
var
  Ed: TTestEditor;
  W: TStringList;
  Err: string;
  K: TJuceControl;
begin
  Suite('form properties and scaling');
  W := TStringList.Create;
  Ed := NewEditor;
  try
    Err := TryLoadText(Ed, 'object F: TForm' + NL + '  Left = 1' + NL + '  Top = 2' + NL + '  Position = poScreenCenter' + NL +
      '  LCLVersion = ''4.8.0.0''' + NL + '  Font.Name = ''Segoe UI''' + NL + '  Font.Style = [fsBold]' + NL +
      '  Font.Charset = DEFAULT_CHARSET' + NL + '  OldCreateOrder = False' + NL + '  TextHeight = 15' + NL +
      '  Constraints.MinWidth = 100' + NL + '  Hint = ''root tip''' + NL +
      '  Color = $00332211' + NL + '  DesignTimePPI = 192' + NL + '  ClientWidth = 800' + NL + '  ClientHeight = 600' + NL +
      '  object K: TJuceKnob' + NL + '    Left = 20' + NL + '    Top = 41' + NL + '    Width = 100' + NL + '    Height = 150' + NL +
      '    Cursor = crHandPoint' + NL + '    HelpContext = 3' + NL + '    TabOrder = 0' + NL + '  end' + NL + 'end', True);
    CheckEquals('', Err, 'IDE-only form and control properties are ignored in strict mode');
    CheckEquals(400, Ed.Width, 'DesignTimePPI 192: ClientWidth scaled to 96 dpi');
    CheckEquals(300, Ed.Height, 'DesignTimePPI 192: ClientHeight scaled');
    K := Ed.FindControl('K');
    Check((K <> nil) and (K.Left = 10) and (K.Top = 21) and (K.Width = 50) and (K.Height = 75), 'control bounds scaled (rounded)');
    Check(Ed.Theme.Background = $FF112233, 'Color $00BBGGRR becomes $FFRRGGBB');
    CheckEquals('root tip', Ed.Root.Hint, 'form Hint goes to the root');
  finally
    Ed.Free;
  end;

  Ed := NewEditor;
  try
    Err := TryLoadText(Ed, 'object F: TForm' + NL + '  PixelsPerInch = 144' + NL + '  Color = clBtnFace' + NL +
      '  ClientWidth = 300' + NL + '  ClientHeight = 150' + NL + 'end', True);
    CheckEquals('', Err, 'Delphi-style form loads');
    CheckEquals(200, Ed.Width, 'PixelsPerInch 144 scales too');
    Check(Ed.Theme.Background = JuceDefaultTheme.Background, 'a system colour keeps the theme background');
  finally
    Ed.Free;
  end;

  Ed := NewEditor;
  try
    Err := TryLoadText(Ed, 'object F: TForm' + NL + '  Color = clRed' + NL + '  Width = 333' + NL + '  Height = 222' + NL + 'end', True);
    CheckEquals('', Err, 'form without ClientWidth loads');
    CheckEquals(333, Ed.Width, 'Width is the fallback for ClientWidth');
    Check(Ed.Theme.Background = $FFFF0000, 'named colour clRed');
  finally
    Ed.Free;
  end;

  { unknown things }
  Ed := NewEditor;
  try
    Err := TryLoadText(Ed, 'object F: TForm' + NL + '  Wibble = 3' + NL + 'end', True);
    Check(Pos('unknown form property Wibble', Err) > 0, 'strict: unknown form property is an error (' + Err + ')');
    Err := TryLoadText(Ed, 'object F: TForm' + NL + '  object B: TButton' + NL + '    Left = 1' + NL + '  end' + NL + 'end', True);
    Check(Pos('unknown control class TButton', Err) > 0, 'strict: unknown class is an error (' + Err + ')');
    Err := TryLoadText(Ed, 'object F: TForm' + NL + '  object K: TJuceKnob' + NL + '    Spin = 1' + NL + '  end' + NL + 'end', True);
    Check(Pos('unknown property Spin of TJuceKnob', Err) > 0, 'strict: unknown property is an error (' + Err + ')');
    Err := TryLoadText(Ed, 'object F: TForm' + NL + '  object K: TJuceKnob' + NL + '    Style = jksBanana' + NL + '  end' + NL + 'end', True);
    Check(Pos('unknown value jksBanana', Err) > 0, 'strict: unknown enum value is an error');
    Err := TryLoadText(Ed, 'object F: TForm' + NL + '  object K: TJuceKnob' + NL + '    Width = ''wide''' + NL + '  end' + NL + 'end', True);
    Check(Err <> '', 'a string where an integer belongs is an error');
    Err := TryLoadText(Ed, 'object F: TForm' + NL + '  object K: TJuceKnob' + NL + '    Sensitivity = 99999999999' + NL + '  end' + NL + 'end', True);
    Check(Pos('out of range', Err) > 0, 'an Integer out of range is an error');
    Err := TryLoadText(Ed, 'object F: TForm' + NL + '  object K: TJuceKnob' + NL + '    OnChange = NoSuchMethod' + NL + '  end' + NL + 'end', True);
    Check(Pos('no published method NoSuchMethod', Err) > 0, 'strict: an event without a method is an error');
    Err := TryLoadText(Ed, 'object F: TForm' + NL + '  object K: TJuceKnob' + NL + '  end' + NL + '  object k: TJuceLed' + NL + '  end' + NL + 'end', True);
    Check(Pos('duplicate name', Err) > 0, 'duplicate names are an error (case-insensitive)');
    CheckEquals(0, Ed.Root.ControlCount, 'nothing was added by any failed load');

    Err := TryLoadText(Ed, 'object F: TForm' + NL + '  Wibble = 3' + NL +
      '  object B: TButton' + NL + '    object Inner: TJuceKnob' + NL + '    end' + NL + '  end' + NL +
      '  object K: TJuceKnob' + NL + '    Spin = 1' + NL + '    Caption = ''ok''' + NL + '  end' + NL + 'end', False, W);
    CheckEquals('', Err, 'lenient: loads despite unknown things');
    CheckEquals(3, W.Count, 'lenient: three warnings');
    Check(Ed.FindControl('B') = nil, 'lenient: the unknown class is skipped');
    Check(Ed.FindControl('Inner') = nil, 'lenient: and so is everything inside it');
    Check((Ed.FindControl('K') <> nil) and (Ed.FindControl('K').Caption = 'ok'), 'lenient: the rest is loaded');
  finally
    Ed.Free;
    W.Free;
  end;

  { a registered user class }
  JuceRegisterLayoutClass(TMyDial);
  Ed := NewEditor;
  try
    Err := TryLoadText(Ed, 'object F: TForm' + NL + '  object D: TMyDial' + NL + '    Notches = 11' + NL + '  end' + NL + 'end', True);
    CheckEquals('', Err, 'JuceRegisterLayoutClass: a user class loads');
    Check((Ed.FindControl('D') is TMyDial) and (TMyDial(Ed.FindControl('D')).Notches = 11), 'with its own property');
  finally
    Ed.Free;
  end;

  { embedded images }
  Ed := NewEditor;
  try
    Err := TryLoadText(Ed, 'object F: TForm' + NL + '  object Strip: TJuceImageResource' + NL +
      '    FileName = ''knob.png''' + NL + '    ImageData = {' + NL + '      89504E470D0A1A0A}' + NL + '    Left = 8' + NL + '  end' + NL +
      '  object K: TJuceKnob' + NL + '    Style = jksFilmstrip' + NL + '    FilmstripImage = ''Strip''' + NL + '  end' + NL + 'end', True);
    CheckEquals('', Err, 'TJuceImageResource loads');
    Check(Ed.FindImage('Strip') <> nil, 'its ImageData is added as an editor image under its name');
    Err := TryLoadText(Ed, 'object F: TForm' + NL + '  object Bad: TJuceImageResource' + NL +
      '    ImageData = {' + NL + '      00112233}' + NL + '  end' + NL + 'end', True);
    Check(Pos('could not be decoded', Err) > 0, 'undecodable image data is an error in strict mode');
  finally
    Ed.Free;
  end;

  { the theme }
  Ed := NewEditor;
  try
    Err := TryLoadText(Ed, 'object F: TForm' + NL + '  Color = $00332211' + NL + '  object Look: TJuceThemeResource' + NL +
      '    Background = -1' + NL + '    Accent = -3000273' + NL + '    TextDim = $FF9A9CA1' + NL + '    FontName = ''Lucida Console''' + NL +
      '    FontSize = 11.5' + NL + '    Left = 8' + NL + '    Top = 8' + NL + '  end' + NL + 'end', True);
    CheckEquals('', Err, 'TJuceThemeResource loads');
    Check((Ed.Theme.Accent = $FFD2382F) and (Ed.Theme.TextDim = $FF9A9CA1), 'its colours become the editor''s theme (Delphi''s negative numbers too)');
    Check((Ed.Theme.FontName = 'Lucida Console') and (Abs(Ed.Theme.FontSize - 11.5) < 1E-6), 'and its font');
    Check(Ed.Theme.Background = $FF112233, 'the form''s own colour is the background, over the theme''s');
    Check(Ed.Theme.Panel = JuceDefaultTheme.Panel, 'what it does not give keeps the default');
    Err := TryLoadText(Ed, 'object F: TForm' + NL + '  object Look: TJuceThemeResource' + NL +
      '    TooltipBackground = -15658476' + NL + '    MenuHighlight = -3000273' + NL + '    MenuFontSize = 15' + NL +
      '    BubbleBorder = -12829117' + NL + '    BubbleFontSize = 14.5' + NL + '    Link = -9785089' + NL +
      '  end' + NL + 'end', True);
    CheckEquals('', Err, 'the tooltip, menu, bubble and link colours load');
    Check((Ed.Theme.TooltipBackground = $FF111214) and (Ed.Theme.MenuHighlight = $FFD2382F)
      and (Ed.Theme.BubbleBorder = $FF3C3E43) and (Ed.Theme.Link = $FF6AB0FF), 'into the theme');
    Check((Abs(Ed.Theme.MenuFontSize - 15) < 1E-6) and (Abs(Ed.Theme.BubbleFontSize - 14.5) < 1E-6), 'with their sizes');
    Check((Ed.Theme.MenuText = 0) and (Ed.Theme.TooltipFontSize = 0), 'unset: 0 (JUCE''s own)');
    Err := TryLoadText(Ed, 'object F: TForm' + NL + '  object Look: TJuceThemeResource' + NL +
      '    Glow = 1' + NL + '  end' + NL + 'end', True);
    Check(Pos('unknown property Glow', Err) > 0, 'an unknown theme property is an error in strict mode: ' + Err);
    Err := TryLoadText(Ed, 'object F: TForm' + NL + '  object Look: TJuceThemeResource' + NL +
      '    object K: TJuceKnob' + NL + '    end' + NL + '  end' + NL + 'end', True);
    Check(Pos('cannot contain objects', Err) > 0, 'a theme cannot contain controls: ' + Err);
  finally
    Ed.Free;
  end;
end;

{ ---------------------------------------------------------------------------- }
{ Malformed and oversized input                                                }
{ ---------------------------------------------------------------------------- }

procedure CheckRejected(const Data: TBytes; const What: string; const Expect: string = '');
var
  Ed: TTestEditor;
  Err: string;
begin
  Ed := NewEditor;
  try
    Err := TryLoad(Ed, Data, False);
    Check((Err <> '') and (Pos('UNEXPECTED', Err) = 0) and ((Expect = '') or (Pos(Expect, Err) > 0)),
      What + ' -> ' + Err);
    CheckEquals(0, Ed.Root.ControlCount, What + ': no control added');
  finally
    Ed.Free;
  end;
end;

function Concat(const Parts: array of TBytes): TBytes;
var
  I, N: Integer;
begin
  N := 0;
  for I := 0 to High(Parts) do
    Inc(N, Length(Parts[I]));
  SetLength(Result, N);
  N := 0;
  for I := 0 to High(Parts) do
    if Length(Parts[I]) > 0 then
    begin
      Move(Parts[I][0], Result[N], Length(Parts[I]));
      Inc(N, Length(Parts[I]));
    end;
end;

function B(const Values: array of Byte): TBytes;
var
  I: Integer;
begin
  SetLength(Result, Length(Values));
  for I := 0 to High(Values) do
    Result[I] := Values[I];
end;

function Short(const S: AnsiString): TBytes;
begin
  SetLength(Result, Length(S) + 1);
  Result[0] := Length(S);
  if Length(S) > 0 then
    Move(S[1], Result[1], Length(S));
end;

function Int32Bytes(V: Integer): TBytes;
begin
  Result := B([V and $FF, (V shr 8) and $FF, (V shr 16) and $FF, (V shr 24) and $FF]);
end;

{ TPF0, form F: TF with no properties, one child, end. }
function FormWith(const Child: TBytes): TBytes;
begin
  Result := Concat([Bytes('TPF0'), Short('TF'), Short('F'), B([0]), Child, B([0])]);
end;

function KnobWith(const Props: TBytes): TBytes;
begin
  Result := Concat([Short('TJuceKnob'), Short('K'), Props, B([0]), B([0])]);
end;

procedure ReadArgs;begin  if ParamCount >= 1 then    RootDir := IncludeTrailingPathDelimiter(ParamStr(1));end;
procedure TestMalformed;
var
  Valid, Data: TBytes;
  I, J, Accepted, Rejected, Unexpected: Integer;
  Ed: TTestEditor;
  Err, Text: string;
  Big: TBytes;
  RandSeedSaved: Integer;
  W: TStringList;
begin
  Suite('malformed and oversized streams');
  Valid := ResourceBytes('TSYNTHEDITORFORM');
  Check(Length(Valid) > 100, 'reference binary stream from the resource');

  CheckRejected(nil, 'empty input', 'not a form file');
  CheckRejected(Bytes('TPF'), 'three bytes', 'not a form file');
  CheckRejected(Bytes('TPF0'), 'signature only', 'unexpected end');
  CheckRejected(Bytes('PK'#3#4'garbage'), 'not a form', 'not a form file');
  CheckRejected(Bytes('object'), 'the word object only');

  { every truncation }
  Unexpected := 0;
  Accepted := 0;
  for I := 0 to Length(Valid) - 1 do
  begin
    Ed := NewEditor;
    try
      Err := TryLoad(Ed, Copy(Valid, 0, I), False);
      if (Err = '') then
        Inc(Accepted)
      else if Pos('UNEXPECTED', Err) > 0 then
        Inc(Unexpected);
      if (Err <> '') and (Ed.Root.ControlCount <> 0) then
        Inc(Unexpected);
    finally
      Ed.Free;
    end;
  end;
  CheckEquals(0, Accepted, Format('all %d truncations rejected', [Length(Valid)]));
  CheckEquals(0, Unexpected, 'truncations: only EJuceLayoutError, nothing added');

  { random mutations }
  RandSeedSaved := RandSeed;
  RandSeed := 20261122;
  Accepted := 0;
  Rejected := 0;
  Unexpected := 0;
  for I := 1 to 3000 do
  begin
    Data := Copy(Valid);
    for J := 1 to 1 + Random(4) do
      if Length(Data) > 8 then
      case Random(4) of
        0: Data[4 + Random(Length(Data) - 4)] := Random(256);
        1: Data[4 + Random(Length(Data) - 4)] := Data[4 + Random(Length(Data) - 4)] xor (1 shl Random(8));
        2: Data[4 + Random(Length(Data) - 4)] := $FF;
        3: Data := Copy(Data, 0, 4 + Random(Length(Data) - 4));
      end;
    Ed := NewEditor;
    try
      Err := TryLoad(Ed, Data, I mod 2 = 0);
      if Err = '' then
        Inc(Accepted)
      else if Pos('UNEXPECTED', Err) > 0 then
      begin
        Inc(Unexpected);
        if Unexpected < 4 then
          WriteLn('    unexpected: ', Err);
      end
      else
        Inc(Rejected);
    finally
      Ed.Free;
    end;
  end;
  RandSeed := RandSeedSaved;
  CheckEquals(0, Unexpected, Format('3000 mutations: %d loaded, %d rejected with EJuceLayoutError, no other exception',
    [Accepted, Rejected]));

  { length fields }
  CheckRejected(FormWith(KnobWith(Concat([Short('Caption'), B([12]), Int32Bytes($7FFFFFFF)]))), 'vaLString of 2 GB', 'limit');
  CheckRejected(FormWith(KnobWith(Concat([Short('Caption'), B([12]), Int32Bytes(-5)]))), 'negative string length');
  CheckRejected(FormWith(KnobWith(Concat([Short('Caption'), B([12]), Int32Bytes(1000), Bytes('abc')]))), 'string longer than the data', 'unexpected end');
  CheckRejected(FormWith(KnobWith(Concat([Short('Caption'), B([18]), Int32Bytes($40000000)]))), 'vaWString of 1 G characters', 'limit');
  CheckRejected(FormWith(KnobWith(Concat([Short('Caption'), B([10]), Int32Bytes(100 * 1024 * 1024)]))), 'vaBinary of 100 MB', 'limit');
  CheckRejected(FormWith(KnobWith(Concat([Short('Caption'), B([99])]))), 'unknown value type', 'unknown value type 99');
  CheckRejected(FormWith(KnobWith(Concat([Short('StartAngle'), B([5, 0, 0, 0, 0, 0, 0, 0, $C0, $FF, $7F])]))), 'infinite float', 'infinite');
  CheckRejected(FormWith(Concat([Short('TJuceKnob'), Short('1bad'), B([0, 0])])), 'malformed object name', 'malformed object name');
  CheckRejected(FormWith(KnobWith(Concat([Short('Cap tion'), B([8])]))), 'malformed property name', 'malformed property name');

  { value type 21: Delphi vaDouble or FPC vaUString, decided by the property type }
  Ed := NewEditor;
  try
    Err := TryLoad(Ed, FormWith(KnobWith(Concat([Short('StartAngle'), B([21, 0, 0, 0, 0, 0, $E0, $60, $C0])]))), True);
    CheckEquals('', Err, 'value type 21 as a Delphi vaDouble (float property)');
    Check((Ed.FindControl('K') <> nil) and SameValue(TJuceKnob(Ed.FindControl('K')).StartAngle, -135.0), 'vaDouble -135');
  finally
    Ed.Free;
  end;
  Ed := NewEditor;
  try
    Err := TryLoad(Ed, FormWith(KnobWith(Concat([Short('Caption'), B([21]), Int32Bytes(2), B([$48, 0, $E9, 0])]))), True);
    CheckEquals('', Err, 'value type 21 as an FPC vaUString (string property)');
    Check((Ed.FindControl('K') <> nil) and (Ed.FindControl('K').Caption = 'Hé'), 'vaUString text');
  finally
    Ed.Free;
  end;
  CheckRejected(FormWith(KnobWith(Concat([Short('Sensitivity'), B([21]), Int32Bytes(2), B([$48, 0, $E9, 0])]))),
    'value type 21 for an integer property', 'value type 21');
  Ed := NewEditor;
  try
    Err := TryLoad(Ed, FormWith(KnobWith(Concat([Short('StartAngle'), B([15]), Int32Bytes(Integer($C3070000))]))), True);
    Check((Err = '') and SameValue(TJuceKnob(Ed.FindControl('K')).StartAngle, -135.0), 'vaSingle');
  finally
    Ed.Free;
  end;

  { size and count limits }
  SetLength(Big, JuceLayoutMaxBinaryBytes + 1);
  Move(Bytes('TPF0')[0], Big[0], 4);
  CheckRejected(Big, 'binary stream over the size limit', 'limit');
  SetLength(Big, 0);
  SetLength(Big, JuceLayoutMaxTextBytes + 1);
  FillChar(Big[0], Length(Big), 32);
  Move(Bytes('object F: TF')[0], Big[0], 12);
  CheckRejected(Big, 'text over the size limit', 'limit');
  SetLength(Big, 0);

  Text := 'object F: TF' + NL;
  for I := 1 to 40 do
    Text := Text + StringOfChar(' ', 2 * I) + 'object P' + IntToStr(I) + ': TJucePanel' + NL;
  for I := 40 downto 1 do
    Text := Text + StringOfChar(' ', 2 * I) + 'end' + NL;
  Text := Text + 'end' + NL;
  CheckRejected(Bytes(UTF8String(Text)), 'text objects nested 40 deep', 'nested deeper');

  Data := Concat([Bytes('TPF0'), Short('TF'), Short('F'), B([0])]);
  for I := 1 to 40 do
    Data := Concat([Data, Short('TJucePanel'), Short('P' + AnsiString(IntToStr(I))), B([0])]);
  for I := 0 to 40 do
    Data := Concat([Data, B([0])]);
  CheckRejected(Data, 'binary objects nested 40 deep', 'nested deeper');

  Text := 'object F: TF' + NL + '  Hint = ' + StringOfChar('(', 100) + NL + 'end';
  CheckRejected(Bytes(UTF8String(Text)), 'lists nested 100 deep', 'nested deeper');

  Data := Concat([Bytes('TPF0'), Short('TF'), Short('F'), B([0]), Short('TJuceKnob'), Short('K'), Short('Hint')]);
  for I := 1 to 60 do
    Data := Concat([Data, B([1])]);
  Data := Concat([Data, B([0])]);
  CheckRejected(Data, 'binary lists nested 60 deep', 'nested too deeply');

  Text := 'object F: TF' + NL;
  for I := 1 to JuceLayoutMaxObjects + 1 do
    Text := Text + '  object L' + IntToStr(I) + ': TJuceLabel' + NL + '  end' + NL;
  Text := Text + 'end' + NL;
  CheckRejected(Bytes(UTF8String(Text)), Format('%d objects', [JuceLayoutMaxObjects + 1]), 'objects');

  Text := 'object F: TF' + NL + '  object K: TJuceKnob' + NL;
  for I := 1 to JuceLayoutMaxProperties + 1 do
    Text := Text + '    Hint = ''x''' + NL;
  Text := Text + '  end' + NL + 'end' + NL;
  CheckRejected(Bytes(UTF8String(Text)), Format('%d properties on one object', [JuceLayoutMaxProperties + 1]), 'properties');

  { review findings (adversarial review, Nov 2026) }
  Text := '';
  for I := 1 to 5000 do
    Text := Text + 'object a: T ';
  CheckRejected(Bytes(UTF8String(Text)), 'objects nested 5000 deep on one line (pre-scan is token based)', 'nested deeper');
  Text := 'object F: TF' + NL + '  object end: TJuceKnob' + NL + '    Hint = ''object''' + NL +
    '    Caption = (' + NL + 'end end end)' + NL + '  end' + NL + 'end';
  Ed := NewEditor;
  try
    Err := TryLoad(Ed, Bytes(UTF8String(Text)), False);
    Check(Pos('nested', Err) = 0, 'keywords as names, strings and list items do not count as nesting (' + Err + ')');
  finally
    Ed.Free;
  end;
  CheckRejected(Bytes('object F: TF' + NL + '  object A: TJuceKnob' + NL + '    Name = ''B''' + NL + '  end' + NL +
    '  object B: TJuceKnob' + NL + '  end' + NL + 'end'), 'Name as a property', 'Name is given by the object header');
  Ed := NewEditor;
  try
    Err := TryLoadText(Ed, 'object F: TForm' + NL + '  object Good: TJuceImageResource' + NL + '    ImageData = {' + NL +
      '      89504E470D0A1A0A}' + NL + '  end' + NL + '  object Bad: TJuceImageResource' + NL + '    ImageData = {' + NL +
      '      00112233}' + NL + '  end' + NL + 'end', True);
    Check((Err <> '') and (Ed.FindImage('Good') = nil) and (Ed.ImageCount = 0),
      'a bad image fails the load before any image is added');
    Err := TryLoadText(Ed, 'object F: TForm' + NL + '  object K: TJuceKnob' + NL + '    OnChange = KnobChanged' + NL +
      '  end' + NL + 'end', True);
    CheckEquals('', Err, 'an event binds to a method of the editor class');
    Ed.Root.Controls[0].Free;
    Err := TryLoadText(Ed, 'object F: TForm' + NL + '  object K: TJuceKnob' + NL + '    OnChange = UpdateTimer' + NL +
      '  end' + NL + 'end', True);
    Check(Err <> '', 'but not to a method of the framework''s base classes');
  finally
    Ed.Free;
  end;
  W := TStringList.Create;
  Ed := NewEditor;
  try
    Text := 'object F: TF' + NL + '  object K: TJuceKnob' + NL;
    for I := 1 to 500 do
      Text := Text + '    Bogus' + IntToStr(I) + ' = 1' + NL;
    Text := Text + '  end' + NL + 'end';
    Err := TryLoad(Ed, Bytes(UTF8String(Text)), False, W);
    Check((Err = '') and (W.Count = 101), Format('lenient: warnings are capped (%d)', [W.Count]));
  finally
    Ed.Free;
    W.Free;
  end;

  CheckRejected(Bytes('object F: TF' + NL + '  Left = ' + NL + 'end'), 'text with a missing value');
  CheckRejected(Bytes('object F: TF' + NL + '  Caption = ''open' + NL + 'end'), 'text with an unterminated string', 'unterminated');
  CheckRejected(Bytes('object F: TF' + NL + '  object K: TJuceKnob' + NL + 'end'), 'text with a missing end');
end;

begin
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  RootDir := '';
  ReadArgs; { in a procedure: string temporaries of the main block outlive Halt }
  JuceLayoutStrict := True;

  TestSynthForm;
  TestEveryProperty;
  TestFormProperties;
  TestMalformed;

  RootDir := ''; { the program's globals are not finalised before heaptrc reports }
  Halt(TestSummary);
end.
