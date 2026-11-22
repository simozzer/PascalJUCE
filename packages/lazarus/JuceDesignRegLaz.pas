{
  JuceDesignRegLaz.pas - registers the PascalJUCE controls in the Lazarus IDE
  (palette page "PascalJUCE") with their property editors.

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

  Part of pascaljuce_design.lpk (design-time only).
}
unit JuceDesignRegLaz;

{$MODE DELPHI}

interface

uses
  Classes, SysUtils, TypInfo, Dialogs, Graphics, PropEdits, LazIDEIntf, ProjectIntf, JuceCanvas, JuceDesignControls;

procedure Register;

implementation

type
  TJuceParameterIdProperty = class(TStringPropertyEditor)
  public
    function GetAttributes: TPropertyAttributes; override;
    procedure GetValues(Proc: TGetStrProc); override;
  end;

  TJuceImageNameProperty = class(TStringPropertyEditor)
  public
    function GetAttributes: TPropertyAttributes; override;
    procedure GetValues(Proc: TGetStrProc); override;
  end;

  TJuceColorProperty = class(TIntegerPropertyEditor)
  public
    function GetAttributes: TPropertyAttributes; override;
    function OrdValueToVisualValue(OrdValue: Longint): string; override;
    procedure SetValue(const NewValue: ansistring); override;
    procedure Edit; override;
  end;

  TJuceImageFileProperty = class(TFileNamePropertyEditor)
  public
    function GetFilter: string; override;
    function GetInitialDirectory: string; override;
    procedure SetFilename(const Filename: string); override;
  end;

{ The unit file of a designed form (for the parameter list and image paths). }
function RootFileName(Root: TComponent): string;
var
  F: TLazProjectFile;
begin
  Result := '';
  if (LazarusIDE = nil) or (Root = nil) then
    Exit;
  F := LazarusIDE.GetProjectFileWithRootComponent(Root);
  if F <> nil then
    Result := F.GetFullFilename;
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
  { a value list, but not paPickList: any id can still be typed }
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

function TJuceColorProperty.OrdValueToVisualValue(OrdValue: Longint): string;
begin
  if OrdValue = 0 then
    Result := '(theme)'
  else
    Result := '$' + IntToHex(Cardinal(OrdValue), 8);
end;

procedure TJuceColorProperty.SetValue(const NewValue: ansistring);
var
  S: string;
  V: Int64;
begin
  S := Trim(NewValue);
  if (S = '') or SameText(S, '(theme)') or SameText(S, 'theme') or SameText(S, 'default') then
    V := 0
  else
  begin
    if (Length(S) in [7, 9]) and (S[1] = '#') then { #RRGGBB / #AARRGGBB }
      S := '$' + Copy(S, 2, MaxInt);
    if not TryStrToInt64(S, V) or (V < 0) or (V > $FFFFFFFF) then
      raise EPropertyError.Create('A colour is $AARRGGBB (e.g. $FFF0A030), #RRGGBB, or (theme)');
    if (Length(NewValue) > 0) and (Trim(NewValue)[1] = '#') and (Length(Trim(NewValue)) = 7) then
      V := V or $FF000000;
  end;
  SetInt64Value(V);
end;

procedure TJuceColorProperty.Edit;
var
  D: TColorDialog;
  C: Cardinal;
begin
  D := TColorDialog.Create(nil);
  try
    C := Cardinal(GetInt64Value);
    if C <> 0 then
      D.Color := TColor(((C shr 16) and $FF) or (C and $FF00) or ((C and $FF) shl 16));
    if D.Execute then
    begin
      C := Cardinal(ColorToRGB(D.Color));
      SetInt64Value($FF000000 or ((C and $FF) shl 16) or (C and $FF00) or ((C shr 16) and $FF));
    end;
  finally
    D.Free;
  end;
end;

{ TJuceImageFileProperty }

function ImageDir(Editor: TPropertyEditor): string;
var
  P: TPersistent;
begin
  Result := '';
  if Editor.PropCount < 1 then
    Exit;
  P := Editor.GetComponent(0);
  if (P is TComponent) and (TComponent(P).Owner <> nil) then
    Result := JuceDesignDirectoryOf(TComponent(P).Owner);
end;

function TJuceImageFileProperty.GetFilter: string;
begin
  Result := 'Images (*.png;*.jpg;*.jpeg;*.bmp)|*.png;*.jpg;*.jpeg;*.bmp|All files|*.*';
end;

function TJuceImageFileProperty.GetInitialDirectory: string;
begin
  Result := ImageDir(Self);
end;

procedure TJuceImageFileProperty.SetFilename(const Filename: string);
var
  Dir: string;
begin
  { stored relative to the form's unit when it is below it }
  Dir := ImageDir(Self);
  if (Dir <> '') and SameText(Copy(Filename, 1, Length(Dir)), Dir) then
    inherited SetFilename(Copy(Filename, Length(Dir) + 1, MaxInt))
  else
    inherited SetFilename(Filename);
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

end.
