(*
  gen_design_props - writes pascal/design/JuceDesignGen.inc, the published
  property lists of the design-time controls, from the RTTI of the run-time
  controls (JuceControls.JuceControlClasses), and those of the design-time
  TJuceThemeResource from the run-time theme (JuceUI.TJuceTheme).

  The run-time classes are the single source of truth: each design-time
  control (a TCustomControl the Lazarus/Delphi form designer can place)
  owns an instance of its run-time class and forwards every property to it
  through RTTI, so the designer edits exactly the values the plug-in will
  load, with the same defaults, and paints with the same Paint code.

    gen_design_props <repo root>          rewrite the include
    gen_design_props <repo root> --check  exit 1 if it is out of date (ctest)

  Build: fpc -Mdelphi -FcUTF8 -Fu<root>/pascal gen_design_props.dpr
*)
program gen_design_props;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}
{$APPTYPE CONSOLE}

uses
{$IFDEF FPC}{$IFDEF UNIX}
  cthreads, { first: the units below may start the RTL's threading in their initialisation }
{$ENDIF}{$ENDIF}
  SysUtils, Classes, TypInfo, JucePlugin, JuceUI, JuceControls;

const
  { Handled by the LCL/VCL control itself (TControl) or by TJuceDesignControl. }
  BaseProps: array[0..9] of string = ('Name', 'Tag', 'Left', 'Top', 'Width', 'Height', 'Visible', 'Enabled',
    'Hint', 'Caption');

var
  Names: TStringList;      { property name -> index (Objects) }
  Kinds: TStringList;      { accessor kinds in use: Integer, Cardinal, Single, Boolean, string, <enum type> }
  Decls, Classes_, Impl: TStringList;
  ThemeNames, ThemeProps: TStringList;

function IsBase(const N: string): Boolean;
var
  I: Integer;
begin
  for I := Low(BaseProps) to High(BaseProps) do
    if SameText(BaseProps[I], N) then
      Exit(True);
  Result := False;
end;

function PropType(Info: PPropInfo): PTypeInfo;
begin
  {$IFDEF FPC}
  Result := Info^.PropType;
  {$ELSE}
  Result := Info^.PropType^;
  {$ENDIF}
end;

{ The accessor kind and the declared type of a property. }
procedure Classify(Owner: TClass; Info: PPropInfo; out Kind, Decl: string);
var
  TI: PTypeInfo;
  TD: PTypeData;
  N: string;
begin
  TI := PropType(Info);
  TD := GetTypeData(TI);
  N := string(Info^.Name);
  case TI^.Kind of
    tkInteger:
      if TD^.OrdType = otULong then
      begin
        Kind := 'Cardinal';
        if Copy(N, Length(N) - 4, 5) = 'Color' then
          Decl := 'TJuceColor'
        else
          Decl := 'Cardinal';
      end
      else if TD^.OrdType = otSLong then
      begin
        Kind := 'Integer';
        Decl := 'Integer';
      end
      else
        raise Exception.CreateFmt('%s.%s: unsupported integer type', [Owner.ClassName, N]);
    tkFloat:
      if TD^.FloatType = ftSingle then
      begin
        Kind := 'Single';
        Decl := 'Single';
      end
      else
        raise Exception.CreateFmt('%s.%s: only Single floats are supported', [Owner.ClassName, N]);
    {$IFDEF FPC}tkBool,{$ENDIF} tkEnumeration:
      if (TI = TypeInfo(Boolean)) {$IFDEF FPC} or (TI^.Kind = tkBool){$ENDIF} then
      begin
        Kind := 'Boolean';
        Decl := 'Boolean';
      end
      else
      begin
        Kind := string(TI^.Name);
        Decl := Kind;
      end;
    tkString, tkLString, tkUString {$IFDEF FPC}, tkAString{$ENDIF}:
      begin
        Kind := 'String';
        Decl := 'string';
      end;
  else
    raise Exception.CreateFmt('%s.%s: property type %s is not supported by the design-time controls',
      [Owner.ClassName, N, string(TI^.Name)]);
  end;
end;

function DefaultClause(Info: PPropInfo; const Kind: string): string;
var
  TI: PTypeInfo;
  D: Int64;
begin
  Result := '';
  TI := PropType(Info);
  if not (TI^.Kind in [tkInteger, tkEnumeration {$IFDEF FPC}, tkBool{$ENDIF}]) then
    Exit;
  D := Info^.Default;
  if D = Int64(Integer($80000000)) then { "nodefault" }
    Exit;
  if Kind = 'Boolean' then
  begin
    if D <> 0 then
      Result := ' default True'
    else
      Result := ' default False';
  end
  else if TI^.Kind = tkEnumeration then
    Result := ' default ' + GetEnumName(TI, D)
  else if Kind = 'Cardinal' then
    Result := ' default ' + IntToStr(Cardinal(D))
  else
    Result := ' default ' + IntToStr(Integer(D));
end;

{ A Single as a literal that reads back as the same Single. }
function SingleText(V: Single): string;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Result := FloatToStrF(V, ffGeneral, 9, 0, FS);
end;

function IndexOfName(const N: string): Integer;
begin
  Result := Names.IndexOf(N);
  if Result < 0 then
    Result := Names.Add(N);
end;

procedure AddKind(const Kind: string);
begin
  if Kinds.IndexOf(Kind) < 0 then
    Kinds.Add(Kind);
end;

function ValueType(const Kind: string): string;
begin
  if Kind = 'String' then
    Result := 'string'
  else
    Result := Kind;
end;

{ The theme's published properties: colours (TJuceColor), strings and Singles. }
procedure GenerateTheme;
var
  J, N: Integer;
  List: PPropList;
  Kind, Decl, Accessor: string;
begin
  N := GetPropList(TJuceTheme.ClassInfo, tkProperties, nil, False);
  GetMem(List, N * SizeOf(PPropInfo));
  try
    GetPropList(TJuceTheme.ClassInfo, tkProperties, List, False);
    for J := 0 to N - 1 do
    begin
      Classify(TJuceTheme, List^[J], Kind, Decl);
      if Kind = 'Cardinal' then
      begin
        Decl := 'TJuceColor';
        Accessor := 'Color';
      end
      else if (Kind = 'String') or (Kind = 'Single') then
        Accessor := Kind
      else
        raise Exception.CreateFmt('TJuceTheme.%s: only colours, strings and Singles are supported',
          [string(List^[J]^.Name)]);
      ThemeProps.Add(Format('    property %s: %s index %d read Get%s write Set%s;',
        [string(List^[J]^.Name), Decl, ThemeNames.Add(string(List^[J]^.Name)), Accessor, Accessor]));
    end;
  finally
    FreeMem(List);
  end;
end;

procedure Generate(const OutFile: string; Check: Boolean);
var
  I, J, N: Integer;
  Instance: TJuceControl;
  List: PPropList;
  Cls: TJuceControlClass;
  Kind, Decl, Text, Old: string;
  Lines: TStringList;
begin
  Names := TStringList.Create;
  Kinds := TStringList.Create;
  Decls := TStringList.Create;
  Classes_ := TStringList.Create;
  Impl := TStringList.Create;
  Lines := TStringList.Create;
  ThemeNames := TStringList.Create;
  ThemeProps := TStringList.Create;
  try
    Instance := nil;
    GenerateTheme;
    { fixed accessor kinds first, so the order is stable }
    Kinds.Add('Integer');
    Kinds.Add('Cardinal');
    Kinds.Add('Single');
    Kinds.Add('Boolean');
    Kinds.Add('String');
    for I := Low(JuceControlClasses) to High(JuceControlClasses) do
    begin
      Cls := JuceControlClasses[I];
      Instance.Free;
      Instance := Cls.Create(nil); { its property values are the defaults }
      Classes_.Add('  ' + Cls.ClassName + ' = class(TJuceDesignControl)');
      Classes_.Add('  protected');
      Classes_.Add('    class function RuntimeClass: TJuceControlClass; override;');
      Classes_.Add('  published');
      N := GetPropList(Cls.ClassInfo, tkProperties, nil, False);
      GetMem(List, N * SizeOf(PPropInfo));
      try
        GetPropList(Cls.ClassInfo, tkProperties, List, False);
        for J := 0 to N - 1 do
        begin
          if PropType(List^[J])^.Kind = tkMethod then
            Continue; { events are attached in code (or bound by the loader) }
          if IsBase(string(List^[J]^.Name)) then
            Continue;
          Classify(Cls, List^[J], Kind, Decl);
          AddKind(Kind);
          { A Single gets the run-time control's own default (what its
            constructor sets) as its default: a form then stores exactly the
            values the loader cannot assume - a BorderWidth of 0 included,
            which without a default the IDE takes for one and leaves out.
            Free Pascal only: Delphi has no defaults for floats. }
          if Kind = 'Single' then
            Classes_.Add(Format('    property %s: %s index %d read Get%s write Set%s {$IFDEF FPC}default %s{$ENDIF};',
              [string(List^[J]^.Name), Decl, IndexOfName(string(List^[J]^.Name)), Kind, Kind,
               SingleText(GetFloatProp(Instance, List^[J]))]))
          else
            Classes_.Add(Format('    property %s: %s index %d read Get%s write Set%s%s;',
              [string(List^[J]^.Name), Decl, IndexOfName(string(List^[J]^.Name)), Kind, Kind,
               DefaultClause(List^[J], Kind)]));
        end;
      finally
        FreeMem(List);
      end;
      Classes_.Add('  end;');
      Classes_.Add('');
      Impl.Add('class function ' + Cls.ClassName + '.RuntimeClass: TJuceControlClass;');
      Impl.Add('begin');
      Impl.Add('  Result := JuceControls.' + Cls.ClassName + ';');
      Impl.Add('end;');
      Impl.Add('');
    end;

    for I := 0 to Kinds.Count - 1 do
    begin
      Decls.Add(Format('    function Get%s(Index: Integer): %s;', [Kinds[I], ValueType(Kinds[I])]));
      if Kinds[I] = 'String' then
        Decls.Add(Format('    procedure Set%s(Index: Integer; const Value: %s);', [Kinds[I], ValueType(Kinds[I])]))
      else
        Decls.Add(Format('    procedure Set%s(Index: Integer; Value: %s);', [Kinds[I], ValueType(Kinds[I])]));
    end;

    Lines.Add('{');
    Lines.Add('  JuceDesignGen.inc - GENERATED by tools/gen_design_props.dpr from the');
    Lines.Add('  published properties of the run-time controls (JuceControls). Do not edit:');
    Lines.Add('  change the run-time control, then run the generator (ctest checks that');
    Lines.Add('  this file is current). Included four times by JuceDesignControls.pas.');
    Lines.Add('}');
    Lines.Add('');
    Lines.Add('{$IFDEF JUCE_DESIGN_ACCESSORS}');
    Lines.AddStrings(Decls);
    Lines.Add('{$ENDIF}');
    Lines.Add('');
    Lines.Add('{$IFDEF JUCE_DESIGN_CLASSES}');
    Lines.AddStrings(Classes_);
    Lines.Add('{$ENDIF}');
    Lines.Add('');
    Lines.Add('{$IFDEF JUCE_DESIGN_THEME}');
    Lines.AddStrings(ThemeProps);
    Lines.Add('{$ENDIF}');
    Lines.Add('');
    Lines.Add('{$IFDEF JUCE_DESIGN_IMPLEMENTATION}');
    Lines.Add('const');
    Text := Format('  JuceDesignPropNames: array[0..%d] of string = (', [Names.Count - 1]);
    for I := 0 to Names.Count - 1 do
    begin
      if I > 0 then
        Text := Text + ', ';
      if Length(Text) > 100 then
      begin
        Lines.Add(TrimRight(Text));
        Text := '    ';
      end;
      Text := Text + '''' + Names[I] + '''';
    end;
    Lines.Add(Text + ');');
    Text := Format('  JuceDesignClassList: array[0..%d] of TJuceDesignControlClass = (', [High(JuceControlClasses)]);
    for I := Low(JuceControlClasses) to High(JuceControlClasses) do
    begin
      if I > 0 then
        Text := Text + ', ';
      Text := Text + JuceControlClasses[I].ClassName;
    end;
    Lines.Add(Text + ');');
    Text := Format('  JuceDesignThemeNames: array[0..%d] of string = (', [ThemeNames.Count - 1]);
    for I := 0 to ThemeNames.Count - 1 do
    begin
      if I > 0 then
        Text := Text + ', ';
      if Length(Text) > 100 then
      begin
        Lines.Add(TrimRight(Text));
        Text := '    ';
      end;
      Text := Text + '''' + ThemeNames[I] + '''';
    end;
    Lines.Add(Text + ');');
    Lines.Add('');
    for I := 0 to Kinds.Count - 1 do
    begin
      Lines.Add(Format('function TJuceDesignControl.Get%s(Index: Integer): %s;', [Kinds[I], ValueType(Kinds[I])]));
      Lines.Add('begin');
      if Kinds[I] = 'Single' then
        Lines.Add('  Result := JuceDesignGetFloat(FCtl, JuceDesignPropNames[Index]);')
      else if Kinds[I] = 'String' then
        Lines.Add('  Result := JuceDesignGetStr(FCtl, JuceDesignPropNames[Index]);')
      else if Kinds[I] = 'Boolean' then
        Lines.Add('  Result := JuceDesignGetOrd(FCtl, JuceDesignPropNames[Index]) <> 0;')
      else
        Lines.Add(Format('  Result := %s(Integer(JuceDesignGetOrd(FCtl, JuceDesignPropNames[Index])));', [Kinds[I]]));
      Lines.Add('end;');
      Lines.Add('');
      if Kinds[I] = 'String' then
        Lines.Add(Format('procedure TJuceDesignControl.Set%s(Index: Integer; const Value: %s);', [Kinds[I], ValueType(Kinds[I])]))
      else
        Lines.Add(Format('procedure TJuceDesignControl.Set%s(Index: Integer; Value: %s);', [Kinds[I], ValueType(Kinds[I])]));
      Lines.Add('begin');
      if Kinds[I] = 'Single' then
        Lines.Add('  JuceDesignSetFloat(FCtl, JuceDesignPropNames[Index], Value);')
      else if Kinds[I] = 'String' then
        Lines.Add('  JuceDesignSetStr(FCtl, JuceDesignPropNames[Index], Value);')
      else
        Lines.Add('  JuceDesignSetOrd(FCtl, JuceDesignPropNames[Index], Ord(Value));');
      Lines.Add('  PropertyChanged;');
      Lines.Add('end;');
      Lines.Add('');
    end;
    Lines.AddStrings(Impl);
    Lines.Add('{$ENDIF}');

    Text := Lines.Text;
    if Check then
    begin
      Old := '';
      if FileExists(OutFile) then
        with TStringList.Create do
        try
          LoadFromFile(OutFile);
          Old := Text;
        finally
          Free;
        end;
      if Old <> Text then
      begin
        WriteLn('FAIL ', OutFile, ' is out of date: run tools/gen_design_props.dpr');
        Halt(1);
      end;
      WriteLn('ok   ', OutFile, ' is current (', Names.Count, ' properties, ', Length(JuceControlClasses), ' classes)');
    end
    else
    begin
      Lines.SaveToFile(OutFile);
      WriteLn('wrote ', OutFile, ' (', Names.Count, ' properties, ', Length(JuceControlClasses), ' classes)');
    end;
  finally
    Names.Free;
    Kinds.Free;
    Decls.Free;
    Classes_.Free;
    Impl.Free;
    Lines.Free;
    ThemeNames.Free;
    ThemeProps.Free;
    Instance.Free;
  end;
end;

procedure Main;
var
  Root: string;
begin
  if ParamCount < 1 then
  begin
    WriteLn('usage: gen_design_props <repository root> [--check]');
    Halt(2);
  end;
  Root := IncludeTrailingPathDelimiter(ParamStr(1));
  try
    Generate(Root + 'pascal' + PathDelim + 'design' + PathDelim + 'JuceDesignGen.inc',
      (ParamCount >= 2) and (ParamStr(2) = '--check'));
  except
    on E: Exception do
    begin
      WriteLn('FAIL ', E.Message);
      Halt(1);
    end;
  end;
end;

begin
  Main;
end.
