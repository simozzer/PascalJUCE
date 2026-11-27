// Mz909 - an emulation of the TR-909 Rhythm Composer
// Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Equivalence harness, Pascal side: renders scenarios.txt through the Pascal engine, the
// same way render_cpp.cpp renders it through the C++ one, and compares the two.
//
//     render_pas <scenarios.txt> <outdir>
//     render_pas --compare <scenarios.txt> <cppdir> <pasdir>
//
// Settings go through the plug-in's own path (Mz909Params values -> SettingsFromValues),
// and patches through its own preset table (Mz909Presets), so both are checked too.
program render_pas;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}
{$APPTYPE CONSOLE}

uses
  Windows, SysUtils, Classes, Math,
  Tr909Settings, Tr909Rom, Tr909Roms, Tr909Engine, Mz909Params, Mz909Presets;

type
  TWords = array of string;
  TSingles = array of Single;

function Words(const Line: string): TWords;
var
  I, Start: Integer;
begin
  Result := nil;
  I := 1;
  while I <= Length(Line) do
  begin
    while (I <= Length(Line)) and (Line[I] <= ' ') do
      Inc(I);
    Start := I;
    while (I <= Length(Line)) and (Line[I] > ' ') do
      Inc(I);
    if I > Start then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Copy(Line, Start, I - Start);
    end;
  end;
end;

function ToFloat(const S: string): Double;
var
  Code: Integer;
begin
  Val(S, Result, Code);
  if Code <> 0 then
    raise Exception.Create('not a number: ' + S);
end;

function Arg(const W: TWords; I: Integer): string;
begin
  if I <= High(W) then
    Result := W[I]
  else
    Result := '';
end;

function Clock: Double;
var
  C, F: Int64;
begin
  QueryPerformanceCounter(C);
  QueryPerformanceFrequency(F);
  Result := C / F;
end;

procedure WriteFloats(const Path: string; const Data: array of Single; Count: Integer);
var
  S: TFileStream;
begin
  S := TFileStream.Create(Path, fmCreate);
  try
    if Count > 0 then
      S.WriteBuffer(Data[0], Count * SizeOf(Single));
  finally
    S.Free;
  end;
end;

function ReadFloats(const Path: string): TSingles;
var
  S: TFileStream;
begin
  Result := nil;
  S := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, S.Size div SizeOf(Single));
    if Length(Result) > 0 then
      S.ReadBuffer(Result[0], Length(Result) * SizeOf(Single));
  finally
    S.Free;
  end;
end;

procedure RenderScenarios(const ScriptPath, OutDir: string);
var
  Script: TWords;
  Lines: TStringList;
  L, I, Block, Scenarios, Idx, Preset, Vel, Acc: Integer;
  Cmd, Name, PName: string;
  Engine: TEngine;
  Values: array[0..NumSpecs - 1] of Single;
  Rate, TotalRendered, TotalSeconds, T0: Double;
  Output: array of Single;
  OutCount: Integer;
  Roms: array[0..3] of PRom;
  R: PRom;

  procedure Grow(Count: Integer);
  begin
    if OutCount + Count > Length(Output) then
      SetLength(Output, Max(2 * Length(Output), OutCount + Count));
  end;

  procedure Push(V: Single);
  begin
    Grow(1);
    Output[OutCount] := V;
    Inc(OutCount);
  end;

  procedure Render(Count, BlockSize: Integer);
  var
    D, M: Integer;
  begin
    if BlockSize <= 0 then
      BlockSize := Count;
    Grow(Count);
    T0 := Clock;
    D := 0;
    while D < Count do
    begin
      M := Min(BlockSize, Count - D);
      Engine.Render(@Output[OutCount], M);
      Inc(OutCount, M);
      Inc(D, M);
    end;
    TotalSeconds := TotalSeconds + (Clock - T0);
    TotalRendered := TotalRendered + Count / Rate;
  end;

begin
  Lines := TStringList.Create;
  Engine := nil;
  Rate := 48000;
  TotalRendered := 0;
  TotalSeconds := 0;
  Scenarios := 0;
  OutCount := 0;
  try
    // The ROMs are built by the first engine; time it.
    T0 := Clock;
    Engine := TEngine.Create;
    Writeln(Format('Pascal ROMs built in %.3f s', [Clock - T0]));
    FreeAndNil(Engine);

    Lines.LoadFromFile(ScriptPath);
    for L := 0 to Lines.Count - 1 do
    begin
      Script := Words(Lines[L]);
      if (Length(Script) = 0) or (Script[0][1] = '#') then
        Continue;
      Cmd := Script[0];

      if Cmd = 'scenario' then
      begin
        Name := Script[1];
        Rate := ToFloat(Script[2]);
        Engine.Free;
        Engine := TEngine.Create;
        Engine.Prepare(Rate);
        for I := 0 to NumSpecs - 1 do
          Values[I] := DefaultValue(I);
        OutCount := 0;
      end
      else if Cmd = 'set' then
      begin
        Idx := IndexOfId(Script[1]);
        if Idx < 0 then
          raise Exception.CreateFmt('line %d: unknown id %s', [L + 1, Script[1]]);
        Values[Idx] := ToFloat(Script[2]);
      end
      else if Cmd = 'patch' then
      begin
        PName := Trim(Copy(Lines[L], Pos('patch', Lines[L]) + 5, MaxInt));
        Preset := -1;
        for I := 0 to NumPresets - 1 do
          if PresetNames[I] = PName then
            Preset := I;
        if Preset < 0 then
          raise Exception.CreateFmt('line %d: no preset %s', [L + 1, PName]);
        PresetValuesOf(Preset, Values);
      end
      else if Cmd = 'apply' then
        Engine.SetSettings(SettingsFromValues(Values))
      else if Cmd = 'on' then
      begin
        Vel := 100;
        if Arg(Script, 2) <> '' then
          Vel := StrToInt(Script[2]);
        Engine.NoteOn(StrToInt(Script[1]), Vel);
      end
      else if Cmd = 'hit' then
      begin
        Acc := 0;
        if Arg(Script, 2) <> '' then
          Acc := StrToInt(Script[2]);
        Engine.Trigger(StrToInt(Script[1]), Acc <> 0);
      end
      else if Cmd = 'allsoundoff' then
        Engine.AllSoundOff
      else if Cmd = 'prepare' then
      begin
        Rate := ToFloat(Script[1]);
        Engine.Prepare(Rate);
      end
      else if Cmd = 'render' then
      begin
        Block := 0;
        if Arg(Script, 2) <> '' then
          Block := StrToInt(Script[2]);
        Render(StrToInt(Script[1]), Block);
      end
      else if Cmd = 'roms' then
      begin
        // the four ROMs' bytes, as floats, and each one's clock: compared like audio
        Roms[0] := ClosedHatRom;
        Roms[1] := OpenHatRom;
        Roms[2] := CrashRom;
        Roms[3] := RideRom;
        for R in Roms do
        begin
          Push(R^.Clock);
          Push(Length(R^.Data));
          for I := 0 to High(R^.Data) do
            Push(R^.Data[I]);
        end;
      end
      else if Cmd = 'end' then
      begin
        WriteFloats(IncludeTrailingPathDelimiter(OutDir) + Name + '.f32', Output, OutCount);
        Inc(Scenarios);
      end
      else
        raise Exception.CreateFmt('line %d: unknown command %s', [L + 1, Cmd]);
    end;
  finally
    Engine.Free;
    Lines.Free;
  end;

  Writeln(Format('Pascal engine: %d scenarios, %.1f s of audio rendered in %.3f s (%.0fx realtime)',
    [Scenarios, TotalRendered, TotalSeconds, TotalRendered / TotalSeconds]));
end;

// Scenario by scenario: the largest sample difference, the RMS of the difference against
// the RMS of the signal, and the first sample that differs at all.
function Compare(const ScriptPath, CppDir, PasDir: string): Boolean;
var
  Lines: TStringList;
  W: TWords;
  L, I, FirstDiff, Exact, Identical, Total: Integer;
  A, B: TSingles;
  MaxDiff, SumD, SumA, D, Ad, WorstAll: Double;
begin
  Result := True;
  WorstAll := 0;
  Identical := 0;
  Total := 0;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(ScriptPath);
    Writeln(Format('%-32s %9s %12s %12s %10s %9s', ['scenario', 'samples', 'max |diff|', 'rms diff', 'rms ref', 'first diff']));
    for L := 0 to Lines.Count - 1 do
    begin
      W := Words(Lines[L]);
      if (Length(W) < 2) or (W[0] <> 'scenario') then
        Continue;
      A := ReadFloats(IncludeTrailingPathDelimiter(CppDir) + W[1] + '.f32');
      B := ReadFloats(IncludeTrailingPathDelimiter(PasDir) + W[1] + '.f32');
      if Length(A) <> Length(B) then
      begin
        Writeln(Format('%-32s LENGTH MISMATCH %d vs %d', [W[1], Length(A), Length(B)]));
        Result := False;
        Continue;
      end;
      MaxDiff := 0;
      SumD := 0;
      SumA := 0;
      FirstDiff := -1;
      Exact := 0;
      for I := 0 to High(A) do
      begin
        Ad := A[I];
        D := Abs(Ad - B[I]);
        if D > MaxDiff then
          MaxDiff := D;
        if D = 0 then
          Inc(Exact)
        else if FirstDiff < 0 then
          FirstDiff := I;
        SumD := SumD + D * D;
        SumA := SumA + Ad * Ad;
      end;
      if Length(A) > 0 then
      begin
        SumD := Sqrt(SumD / Length(A));
        SumA := Sqrt(SumA / Length(A));
      end;
      if MaxDiff > WorstAll then
        WorstAll := MaxDiff;
      Inc(Total);
      if MaxDiff = 0 then
        Inc(Identical);
      if MaxDiff > 1e-4 then
        Result := False;
      Writeln(Format('%-32s %9d %12.3e %12.3e %10.4f %9d', [W[1], Length(A), MaxDiff, SumD, SumA, FirstDiff]));
    end;
  finally
    Lines.Free;
  end;
  Writeln(Format('worst max |diff| over all scenarios: %.3e; bit-identical: %d of %d', [WorstAll, Identical, Total]));
  if Result then
    Writeln('equivalence: PASS (every scenario within 1e-4)')
  else
    Writeln('equivalence: FAIL');
end;

begin
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  try
    if (ParamCount >= 4) and (ParamStr(1) = '--compare') then
    begin
      if not Compare(ParamStr(2), ParamStr(3), ParamStr(4)) then
        ExitCode := 1;
    end
    else if ParamCount >= 2 then
      RenderScenarios(ParamStr(1), ParamStr(2))
    else
    begin
      Writeln('usage: render_pas <scenarios.txt> <outdir> | --compare <scenarios.txt> <cppdir> <pasdir>');
      ExitCode := 2;
    end;
  except
    on E: Exception do
    begin
      Writeln('error: ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
