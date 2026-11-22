{
  JuceDesignRegVcl.pas - registers the PascalJUCE controls in the Delphi IDE
  (palette page "PascalJUCE") with their property editors. The Delphi
  counterpart of packages/lazarus/JuceDesignRegLaz.pas.

    ParameterId               a drop-down of the plug-in's parameter ids, from
                              the parameter list next to the form (a .params
                              file the build exports, or else the
                              JuceAdd...Parameter calls in the sources there);
                              any text can still be typed
    FilmstripImage,
    BackgroundImage           a drop-down of the TJuceImageResource names on
                              the form
    colours (TJuceColor)      shown as $AARRGGBB or "(theme)" for 0; "..."
                              opens a colour dialog
    TJuceImageResource.
      FileName                a file dialog; the image is embedded in the form

  Part of PascalJUCE_Design.dpk (design-time only). Written for Delphi 10.x
  and later; it has not been compiled here (no Delphi was available), see
  packages/delphi/README.md.
}
unit JuceDesignRegVcl;

interface

procedure Register;

implementation

uses
  System.Classes, System.SysUtils, System.TypInfo, Vcl.Dialogs, Vcl.Graphics, DesignIntf, DesignEditors,
  ToolsAPI, JuceCanvas, JuceDesignControls;

type
  TJuceParameterIdProperty = class(TStringProperty)
  public
    function GetAttributes: TPropertyAttributes; override;
    procedure GetValues(Proc: TGetStrProc); override;
  end;

  TJuceImageNameProperty = class(TStringProperty)
  public
    function GetAttributes: TPropertyAttributes; override;
    procedure GetValues(Proc: TGetStrProc); override;
  end;

  TJuceColorProperty = class(TIntegerProperty)
  public
    function GetAttributes: TPropertyAttributes; override;
    function GetValue: string; override;
    procedure SetValue(const Value: string); override;
    procedure Edit; override;
  end;

  TJuceImageFileProperty = class(TStringProperty)
  public
    function GetAttributes: TPropertyAttributes; override;
    procedure Edit; override;
  end;

{ The unit file of the module whose form is Root (for the parameter list and
  relative image paths). }
function RootFileName(Root: TComponent): string;
var
  Modules: IOTAModuleServices;
  Module: IOTAModule;
  FormEditor: IOTAFormEditor;
  NC: INTAComponent;
  I, J: Integer;
begin
  Result := '';
  if (Root = nil) or not Supports(BorlandIDEServices, IOTAModuleServices, Modules) then
    Exit;
  for I := 0 to Modules.ModuleCount - 1 do
  begin
    Module := Modules.Modules[I];
    for J := 0 to Module.ModuleFileCount - 1 do
      if Supports(Module.ModuleFileEditors[J], IOTAFormEditor, FormEditor) then
        if Supports(FormEditor.GetRootComponent, INTAComponent, NC) and (NC.GetComponent = Root) then
          Exit(Module.FileName);
  end;
end;

function FirstDesignControl(Editor: TPropertyEditor): TJuceDesignControl;
var
  P: TPersistent;
begin
  Result := nil;
  if Editor.PropCount < 1 then
    Exit;
  P := Editor.GetComponent(0);
  if P is TJuceDesignControl then
    Result := TJuceDesignControl(P);
end;

{ TJuceParameterIdProperty }

function TJuceParameterIdProperty.GetAttributes: TPropertyAttributes;
begin
  { a value list, but not read-only: any id can still be typed }
  Result := inherited GetAttributes + [paValueList, paSortList, paMultiSelect];
end;

procedure TJuceParameterIdProperty.GetValues(Proc: TGetStrProc);
var
  C: TJuceDesignControl;
  Ed: TJuceDesignEditor;
  I: Integer;
begin
  C := FirstDesignControl(Self);
  if C = nil then
    Exit;
  Ed := C.DesignEditor;
  Ed.Refresh;
  for I := 0 to Ed.Params.Count - 1 do
    Proc(Ed.Params.Item(I).Id);
end;

{ TJuceImageNameProperty }

function TJuceImageNameProperty.GetAttributes: TPropertyAttributes;
begin
  Result := inherited GetAttributes + [paValueList, paSortList, paMultiSelect];
end;

procedure TJuceImageNameProperty.GetValues(Proc: TGetStrProc);
var
  C: TJuceDesignControl;
  Root: TComponent;
  I: Integer;
begin
  C := FirstDesignControl(Self);
  if C = nil then
    Exit;
  Root := C.DesignEditor.FormRoot;
  if Root = nil then
    Exit;
  for I := 0 to Root.ComponentCount - 1 do
    if Root.Components[I] is TJuceImageResource then
      Proc(Root.Components[I].Name);
end;

{ TJuceColorProperty: TJuceColor is $AARRGGBB; 0 = the theme's colour }

function TJuceColorProperty.GetAttributes: TPropertyAttributes;
begin
  Result := inherited GetAttributes + [paDialog];
end;

function TJuceColorProperty.GetValue: string;
var
  V: Cardinal;
begin
  V := Cardinal(GetOrdValue);
  if V = 0 then
    Result := '(theme)'
  else
    Result := '$' + IntToHex(V, 8);
end;

procedure TJuceColorProperty.SetValue(const Value: string);
var
  S: string;
  V: Int64;
  Short: Boolean;
begin
  S := Trim(Value);
  Short := (Length(S) = 7) and (S[1] = '#');
  if (S = '') or SameText(S, '(theme)') or SameText(S, 'theme') or SameText(S, 'default') then
    V := 0
  else
  begin
    if (Length(S) in [7, 9]) and (S[1] = '#') then { #RRGGBB / #AARRGGBB }
      S := '$' + Copy(S, 2, MaxInt);
    if not TryStrToInt64(S, V) or (V < 0) or (V > $FFFFFFFF) then
      raise EPropertyError.Create('A colour is $AARRGGBB (e.g. $FFF0A030), #RRGGBB, or (theme)');
    if Short then
      V := V or $FF000000;
  end;
  SetOrdValue(Integer(Cardinal(V)));
end;

procedure TJuceColorProperty.Edit;
var
  D: TColorDialog;
  C: Cardinal;
begin
  D := TColorDialog.Create(nil);
  try
    C := Cardinal(GetOrdValue);
    if C <> 0 then
      D.Color := TColor(((C shr 16) and $FF) or (C and $FF00) or ((C and $FF) shl 16));
    if D.Execute then
    begin
      C := Cardinal(ColorToRGB(D.Color));
      SetOrdValue(Integer($FF000000 or ((C and $FF) shl 16) or (C and $FF00) or ((C shr 16) and $FF)));
    end;
  finally
    D.Free;
  end;
end;

{ TJuceImageFileProperty }

function TJuceImageFileProperty.GetAttributes: TPropertyAttributes;
begin
  Result := inherited GetAttributes + [paDialog];
end;

procedure TJuceImageFileProperty.Edit;
var
  D: TOpenDialog;
  Dir, F: string;
  P: TPersistent;
begin
  Dir := '';
  P := GetComponent(0);
  if (P is TComponent) and (TComponent(P).Owner <> nil) then
    Dir := JuceDesignDirectoryOf(TComponent(P).Owner);
  D := TOpenDialog.Create(nil);
  try
    D.Filter := 'Images (*.png;*.jpg;*.jpeg;*.bmp)|*.png;*.jpg;*.jpeg;*.bmp|All files|*.*';
    D.InitialDir := Dir;
    if D.Execute then
    begin
      F := D.FileName;
      { stored relative to the form's unit when it is below it }
      if (Dir <> '') and SameText(Copy(F, 1, Length(Dir)), Dir) then
        F := Copy(F, Length(Dir) + 1, MaxInt);
      SetValue(F);
    end;
  finally
    D.Free;
  end;
end;

procedure Register;
var
  Classes: TArray<TJuceDesignControlClass>;
  List: array of TComponentClass;
  I: Integer;
begin
  Classes := JuceDesignClasses;
  SetLength(List, Length(Classes) + 2);
  for I := 0 to High(Classes) do
    List[I] := Classes[I];
  List[High(List) - 1] := TJuceImageResource;
  List[High(List)] := TJuceThemeResource;
  RegisterComponents('PascalJUCE', List);
  RegisterPropertyEditor(TypeInfo(string), TJuceDesignControl, 'ParameterId', TJuceParameterIdProperty);
  RegisterPropertyEditor(TypeInfo(string), TJuceDesignControl, 'FilmstripImage', TJuceImageNameProperty);
  RegisterPropertyEditor(TypeInfo(string), TJuceDesignControl, 'BackgroundImage', TJuceImageNameProperty);
  RegisterPropertyEditor(TypeInfo(TJuceColor), TJuceDesignControl, '', TJuceColorProperty);
  RegisterPropertyEditor(TypeInfo(TJuceColor), TJuceThemeResource, '', TJuceColorProperty);
  RegisterPropertyEditor(TypeInfo(string), TJuceImageResource, 'FileName', TJuceImageFileProperty);
  JuceDesignRootFileName := RootFileName;
end;

initialization

finalization
  JuceDesignRootFileName := nil;

end.
