// MzPCG - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Equivalence harness, Pascal side: renders scenarios.txt through the Pascal engine
// (PCG/PcgEngine, on MzPCF's PCF/ units), the same way render_cpp.cpp renders it through
// the original C++ one, and compares the two - bit for bit.
//
//     render_pas <scenarios.txt> <outdir>
//     render_pas --compare <scenarios.txt> <cppdir> <pasdir>
//
// Parameters go through the plug-in's own reader (MzPcgParams.SettingsFromValues), so it is
// checked too.
program render_pas;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}
{$APPTYPE CONSOLE}

uses
  Windows, SysUtils, Classes, Math,
  PcfMath, PcfPatterns, PcgEngine, MzPcgParams;

type
  TWords = array of string;
  TSingles = array of Single;

  // What goes through the gain: one generator a channel (render_cpp's Source).
  TSource = record
    Kind: string;
    Inc, Phase, Value, Gain: Single;
    State: UInt32;
    Period, Count: Integer;
    Negative: Boolean;
    procedure Start(const K: string; Arg, Rate: Double; Channel: Integer);
    function Next: Single;
  end;

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

// std::nan(""), bit for bit: a positive quiet NaN (FPC's NaN is negative, and a NaN's sign
// and payload go through the arithmetic into the output).
function QuietNaN: Double;
const
  Bits: UInt64 = $7FF8000000000000;
begin
  Move(Bits, Result, SizeOf(Result));
end;

function ToFloat(const S: string): Double;
var
  Code: Integer;
begin
  if S = 'nan' then
    Exit(QuietNaN);
  if S = 'inf' then
    Exit(Infinity);
  if S = '-inf' then
    Exit(NegInfinity);
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

function FromBits(B: UInt32): Single;
begin
  Move(B, Result, SizeOf(Result));
end;

procedure TSource.Start(const K: string; Arg, Rate: Double; Channel: Integer);
var
  M: Double;
begin
  Kind := K;
  if Channel = 0 then
  begin
    Phase := 0;
    State := $2545F491;
    M := 1.0;
  end
  else
  begin
    Phase := 0.5;
    State := $9E3779B9;
    M := 1.5;
  end;
  Count := 0;
  Negative := False;
  if Kind = 'saw' then
    Inc := Arg * M / Rate
  else if Kind = 'impulse' then
  begin
    if Arg >= 1.0 then
      Period := Trunc(Arg)
    else
      Period := 1;
  end
  else if Kind = 'dc' then
    Value := Arg;
end;

function TSource.Next: Single;
const
  Scale: Single = 1 / 2147483648.0;
var
  X, F: Single;
begin
  X := 0;
  if Kind = 'saw' then
  begin
    X := 2 * Phase - 1;
    Phase := Phase + Inc;
    if Phase >= 1 then
      Phase := Phase - 1;
  end
  else if Kind = 'noise' then
  begin
    State := State xor (State shl 13);
    State := State xor (State shr 17);
    State := State xor (State shl 5);
    F := Int32(State);
    X := F * Scale;
  end
  else if Kind = 'impulse' then
  begin
    if Count = 0 then
      X := 1
    else
      X := 0;
    System.Inc(Count);
    if Count >= Period then
      Count := 0;
  end
  else if Kind = 'dc' then
    X := Value
  else if Kind = 'tiny' then
  begin
    // a denormal, alternating in sign
    if Negative then
      X := FromBits($800AE398)
    else
      X := FromBits($000AE398);
    Negative := not Negative;
    Exit(X);
  end;
  Result := X * Gain;
end;

procedure SetFtz(On: Boolean);
const
  Bits = $8040;   // FTZ | DAZ, as juce::ScopedNoDenormals sets them
begin
  if On then
    SetMXCSR(GetMXCSR or Bits)
  else
    SetMXCSR(GetMXCSR and not Cardinal(Bits));
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
  L, I, C, Idx, Scenarios, Samples, BlockSize, Blocks, K, Done, N, P, S: Integer;
  Cmd, Name: string;
  Engine: TPcg;
  HaveEngine: Boolean;
  Values: array[0..NumParams - 1] of Single;
  Rate, Ppq, Bpm, TotalRendered, TotalSeconds, T0, From, Too, V: Double;
  Mono, Playing: Boolean;
  Src: array[0..1] of TSource;
  Output: array of Single;
  OutCount: Integer;
  Left, Right: array of Single;
  Curve: TPcgCurve;
  G: Single;

  procedure Grow(Count: Integer);
  begin
    if OutCount + Count > Length(Output) then
      SetLength(Output, Max(2 * Length(Output), OutCount + Count));
  end;

  procedure Push(X: Single);
  begin
    Grow(1);
    Output[OutCount] := X;
    Inc(OutCount);
  end;

  procedure Block(Count: Integer);
  var
    J: Integer;
    R: PPcfSamples;
  begin
    if Length(Left) < Count then
    begin
      SetLength(Left, Count);
      SetLength(Right, Count);
    end;
    for J := 0 to Count - 1 do
    begin
      Left[J] := Src[0].Next;
      Right[J] := Src[1].Next;
    end;
    T0 := Clock;
    Engine.SetHostClock(Playing, Ppq, Bpm);
    if Mono then
      R := nil
    else
      R := @Right[0];
    if Count > 0 then
      Engine.Process(@Left[0], R, Count)
    else
      Engine.Process(nil, nil, 0);
    TotalSeconds := TotalSeconds + (Clock - T0);
    TotalRendered := TotalRendered + Count / Rate;
    if Playing then
      Ppq := Ppq + Count * Bpm / (60.0 * Rate);
    Grow(2 * Count + 2);
    for J := 0 to Count - 1 do
      Push(Left[J]);
    if not Mono then
      for J := 0 to Count - 1 do
        Push(Right[J]);
    Push(Engine.Step);
    Push(Engine.Gain);
  end;

  procedure Render(Count, Size: Integer);
  var
    D, M: Integer;
  begin
    if Size <= 0 then
      Size := Count;
    D := 0;
    while D < Count do
    begin
      M := Min(Size, Count - D);
      Block(M);
      Inc(D, M);
    end;
  end;

  procedure SetValue(const Id: string; X: Double);
  begin
    Idx := IndexOfId(Id);
    if Idx < 0 then
      raise Exception.CreateFmt('line %d: unknown id %s', [L + 1, Id]);
    Values[Idx] := X;   // (float) v
  end;

begin
  Lines := TStringList.Create;
  HaveEngine := False;
  Rate := 48000;
  Mono := False;
  Playing := False;
  Ppq := 0;
  Bpm := 120;
  TotalRendered := 0;
  TotalSeconds := 0;
  Scenarios := 0;
  OutCount := 0;
  Left := nil;
  Right := nil;
  SetFtz(True);
  try
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
        Mono := Arg(Script, 3) = 'mono';
        Engine.Init;
        Engine.Prepare(Rate);
        HaveEngine := True;
        for I := 0 to NumParams - 1 do
          Values[I] := DefaultValue(I);
        Playing := False;
        Ppq := 0;
        Bpm := 120;
        for C := 0 to 1 do
        begin
          Src[C].Gain := 1;
          Src[C].Start('saw', 110.0, Rate, C);
        end;
        OutCount := 0;
      end
      else if not HaveEngine then
        raise Exception.CreateFmt('line %d: no scenario', [L + 1])
      else if Cmd = 'set' then
        SetValue(Script[1], ToFloat(Script[2]))
      else if Cmd = 'apply' then
        Engine.SetSettings(SettingsFromValues(Values))
      else if Cmd = 'input' then
      begin
        if Arg(Script, 2) <> '' then
          V := ToFloat(Script[2])
        else
          V := 0;
        for C := 0 to 1 do
          Src[C].Start(Script[1], V, Rate, C);
      end
      else if Cmd = 'gain' then
      begin
        G := ToFloat(Script[1]);
        Src[0].Gain := G;
        Src[1].Gain := G;
      end
      else if Cmd = 'transport' then
      begin
        Playing := Script[1] = '1';
        Ppq := ToFloat(Script[2]);
        Bpm := ToFloat(Script[3]);
      end
      else if Cmd = 'tempo' then
        Bpm := ToFloat(Script[1])
      else if Cmd = 'seek' then
        Ppq := ToFloat(Script[1])
      else if Cmd = 'notimeline' then
      begin
        Playing := False;
        Ppq := 0;
        Bpm := 120;
      end
      else if Cmd = 'render' then
      begin
        BlockSize := 0;
        if Arg(Script, 2) <> '' then
          BlockSize := StrToInt(Script[2]);
        Render(StrToInt(Script[1]), BlockSize);
      end
      else if Cmd = 'sweep' then
      begin
        From := ToFloat(Script[2]);
        Too := ToFloat(Script[3]);
        Samples := StrToInt(Script[4]);
        BlockSize := StrToInt(Script[5]);
        Blocks := (Samples + BlockSize - 1) div BlockSize;
        Done := 0;
        for K := 0 to Blocks - 1 do
        begin
          if Blocks > 1 then
            V := From + (Too - From) * K / (Blocks - 1)
          else
            V := Too;
          SetValue(Script[1], V);
          Engine.SetSettings(SettingsFromValues(Values));
          N := Min(BlockSize, Samples - Done);
          Block(N);
          Inc(Done, N);
        end;
      end
      else if Cmd = 'prepare' then
      begin
        Engine.Prepare(ToFloat(Script[1]));
        Rate := ToFloat(Script[1]);
        if not (Rate > 0.0) then
          Rate := 48000.0;   // the rate the engine falls back to
      end
      else if Cmd = 'reset' then
        Engine.Reset
      else if Cmd = 'ftz' then
        SetFtz(Script[1] <> '0')
      else if Cmd = 'levels' then
      begin
        for P := -2 to PcgPatternCount + 1 do
          for S := -40 to 40 do
            Push(PcgLevel(P, S));
        for P := -2 to 4 do
          Push(PcgStepsPerQuarter(P));
      end
      else if Cmd = 'curve' then
      begin
        // the panel's picture of the gain, from the pending settings
        Curve := PcgGainCurve(SettingsFromValues(Values));
        Push(Length(Curve));
        for I := 0 to High(Curve) do
          Push(Curve[I]);
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
    Lines.Free;
  end;

  if TotalSeconds > 0 then
    Writeln(Format('Pascal engine: %d scenarios, %.1f s of audio rendered in %.3f s (%.0fx realtime)',
      [Scenarios, TotalRendered, TotalSeconds, TotalRendered / TotalSeconds]));
end;

// Scenario by scenario, bit for bit: how many floats differ in their bits, the largest
// difference, and the first float that differs.
function Compare(const ScriptPath, CppDir, PasDir: string): Boolean;
var
  Lines: TStringList;
  W: TWords;
  L, I, FirstDiff, Differ, Identical, Total: Integer;
  A, B: TSingles;
  MaxDiff, D, Da, Db, WorstAll: Double;
  Floats: Int64;
begin
  Result := True;
  WorstAll := 0;
  Identical := 0;
  Total := 0;
  Floats := 0;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(ScriptPath);
    Writeln(Format('%-34s %9s %9s %12s %10s', ['scenario', 'floats', 'differ', 'max |diff|', 'first diff']));
    for L := 0 to Lines.Count - 1 do
    begin
      W := Words(Lines[L]);
      if (Length(W) < 2) or (W[0] <> 'scenario') then
        Continue;
      Inc(Total);
      A := ReadFloats(IncludeTrailingPathDelimiter(CppDir) + W[1] + '.f32');
      B := ReadFloats(IncludeTrailingPathDelimiter(PasDir) + W[1] + '.f32');
      if (Length(A) <> Length(B)) or (Length(A) = 0) then
      begin
        Writeln(Format('%-34s LENGTH MISMATCH %d vs %d', [W[1], Length(A), Length(B)]));
        Result := False;
        Continue;
      end;
      MaxDiff := 0;
      FirstDiff := -1;
      Differ := 0;
      for I := 0 to High(A) do
        if PCardinal(@A[I])^ <> PCardinal(@B[I])^ then
        begin
          Inc(Differ);
          if FirstDiff < 0 then
            FirstDiff := I;
          Da := A[I];
          Db := B[I];
          D := Abs(Da - Db);
          if IsNan(D) then
            D := Infinity;
          if D > MaxDiff then
            MaxDiff := D;
        end;
      Inc(Floats, Length(A));
      if MaxDiff > WorstAll then
        WorstAll := MaxDiff;
      if Differ = 0 then
        Inc(Identical)
      else
        Result := False;
      Writeln(Format('%-34s %9d %9d %12.3e %10d', [W[1], Length(A), Differ, MaxDiff, FirstDiff]));
    end;
  finally
    Lines.Free;
  end;
  Writeln(Format('%d floats compared; bit-identical scenarios: %d of %d; worst |diff| %.3e',
    [Floats, Identical, Total, WorstAll]));
  if Result then
    Writeln('equivalence: PASS (every scenario bit-identical)')
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
