// Mz950 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Audio equivalence harness, Pascal side: renders scenarios.txt through the Pascal engine,
// the same way render_cpp.cpp renders it through the C++ one, and compares the two.
//
//     render_pas <scenarios.txt> <disks dir> <outdir>
//     render_pas --compare <scenarios.txt> <cppdir> <pasdir>
//
// The disks are read by S950Disk and the synth disks made by S950SynthPatch, so the whole
// path from an image to the samples is the port's.
program render_pas;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$MINFPCONSTPREC 64}
{$ENDIF}
{$APPTYPE CONSOLE}

uses
  SysUtils, Classes,
  S950Math, S950Patch, S950Disk, S950Voice, S950Engine, S950SynthPatch;

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

// The rest of the line after the first word, for a recipe's text.
function RestOf(const Line: string): string;
var
  I: Integer;
begin
  I := 1;
  while (I <= Length(Line)) and (Line[I] <= ' ') do Inc(I);
  while (I <= Length(Line)) and (Line[I] > ' ') do Inc(I);
  while (I <= Length(Line)) and (Line[I] <= ' ') do Inc(I);
  Result := Copy(Line, I, MaxInt);
end;

// Only whole numbers and dyadic fractions are used in scenarios.txt, so this and strtod
// agree exactly.
function ToFloat(const S: string): Double;
var
  Code: Integer;
begin
  Val(S, Result, Code);
  if Code <> 0 then
    raise Exception.Create('not a number: ' + S);
end;

function ToInt(const S: string): Integer;
begin
  Result := StrToIntDef(S, 0);
end;

function Arg(const W: TWords; I: Integer): string;
begin
  if I <= High(W) then Result := W[I] else Result := '';
end;

function AtArg(const W: TWords; I: Integer): Integer;
begin
  if I <= High(W) then Result := ToInt(W[I]) else Result := 0;
end;

function DiskPath(const Dir, Name: string): string;
begin
  if Pos(':', Name) > 0 then Result := Name else Result := IncludeTrailingPathDelimiter(Dir) + Name;
end;

function TrimNamed(E: TS950Engine; const N: string): PInteger;
begin
  Result := nil;
  with E.Trims do
  begin
    if N = 'cutoff' then Result := @Cutoff;          if N = 'amount' then Result := @Amount;
    if N = 'vcaAttack' then Result := @VcaAttack;    if N = 'vcaDecay' then Result := @VcaDecay;
    if N = 'vcaSustain' then Result := @VcaSustain;  if N = 'vcaRelease' then Result := @VcaRelease;
    if N = 'vcfAttack' then Result := @VcfAttack;    if N = 'vcfDecay' then Result := @VcfDecay;
    if N = 'vcfSustain' then Result := @VcfSustain;  if N = 'vcfRelease' then Result := @VcfRelease;
    if N = 'lfoRate' then Result := @LfoRate;        if N = 'lfoDepth' then Result := @LfoDepth;
    if N = 'lfoDelay' then Result := @LfoDelay;      if N = 'velToFilter' then Result := @VelToFilter;
    if N = 'velToLoudness' then Result := @VelToLoudness;
    if N = 'resonance' then Result := @Resonance;    if N = 'lfoShape' then Result := @LfoShape;
    if N = 'lfoToFilter' then Result := @LfoToFilter; if N = 'lfoSync' then Result := @LfoSync;
    if N = 'lfoSyncDiv' then Result := @LfoSyncDiv;
  end;
  if N = 'gain' then Result := @E.Gain;
end;

type
  TRun = class
    Name: string;
    Engine: TS950Engine;
    Disk: TS950Disk;
    HaveDisk: Boolean;
    Patch: TS950Patch;
    Prog: PDiskEntry;
    ProgramIndex: Integer;
    Cache: TWaveCache;
    Output: TSingles;
    OutCount: Integer;
    Bpm, Ppq, Qpb: Double;
    Playing, Transport, Failed: Boolean;
    XFade: Integer;               // the crossfade command: -1 leaves the disk's byte 21 alone
    constructor Create(const AName: string; Rate: Double);
    destructor Destroy; override;
    procedure Push(V: Single);
  end;

constructor TRun.Create(const AName: string; Rate: Double);
begin
  inherited Create;
  Name := AName;
  Engine := TS950Engine.Create(Rate);
  Disk := TS950Disk.Create;
  Cache := TWaveCache.Create;
  ProgramIndex := -1;
  XFade := -1;
  Bpm := 120.0; Ppq := 0.0; Qpb := 4.0;
end;

destructor TRun.Destroy;
begin
  Engine.Free;
  ReleasePatch(Patch);
  Disk.Free;
  Cache.Free;
  inherited Destroy;
end;

procedure TRun.Push(V: Single);
begin
  if OutCount = Length(Output) then
    SetLength(Output, 2 * OutCount + 65536);
  Output[OutCount] := V;
  Inc(OutCount);
end;

// The patch to the engine, and taken by the audio side at once: a render of nothing takes
// the pending patch, and the retired one is collected straight after.
procedure Send(R: TRun);
var
  None: array[0..0] of Single;
begin
  if (R.Patch <> nil) and (R.XFade >= 0) then
    R.Patch.PositionalCrossfade := R.XFade <> 0;
  if not R.Engine.TrySetPatch(R.Patch) then
  begin
    WriteLn(R.Name, ': trySetPatch refused');
    R.Failed := True;
  end;
  R.Engine.Render(@None[0], nil, 0);
  R.Engine.CollectRetiredPatch;
end;

function NthProgram(D: TS950Disk; N: Integer): PDiskEntry;
var
  I, K: Integer;
begin
  Result := nil;
  K := 0;
  for I := 0 to High(D.Entries) do
    if D.Entries[I].EntryType = 'P' then
    begin
      if K = N then
      begin
        Result := @D.Entries[I];
        Exit;
      end;
      Inc(K);
    end;
end;

procedure SelectProgram(R: TRun; N: Integer);
var
  Fresh: TS950Patch;
begin
  R.Prog := NthProgram(R.Disk, N);
  R.ProgramIndex := N;
  if R.Prog = nil then
  begin
    WriteLn(R.Name, ': no programme ', N);
    R.Failed := True;
    Exit;
  end;
  Fresh := R.Disk.BuildPatch(R.Prog^, R.Patch);
  ReleasePatch(R.Patch);
  R.Patch := Fresh;
  Send(R);
end;

procedure WriteFloats(const Path: string; const V: TSingles; Count: Integer);
var
  F: TFileStream;
begin
  F := TFileStream.Create(Path, fmCreate);
  try
    if Count > 0 then
      F.WriteBuffer(V[0], Count * SizeOf(Single));
  finally
    F.Free;
  end;
end;

function ReadFloats(const Path: string): TSingles;
var
  F: TFileStream;
begin
  Result := nil;
  if not FileExists(Path) then Exit;
  F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, F.Size div SizeOf(Single));
    if Length(Result) > 0 then
      F.ReadBuffer(Result[0], Length(Result) * SizeOf(Single));
  finally
    F.Free;
  end;
end;

function Render(const ScenarioPath, DisksDir, OutDir: string): Integer;
var
  Lines: TStringList;
  W: TWords;
  C, Line, Err: string;
  R: TRun;
  L, Scenarios, Failures, Total, Block, Done_, N, I: Integer;
  Mono: Boolean;
  Left, Right: TSingles;
  T: PInteger;
  V: Single;
  Recipe: TRecipe;
  OutDisk: TS950Disk;
  Fresh: TS950Patch;
  Prev: TS950Disk;
begin
  Lines := TStringList.Create;
  Lines.LoadFromFile(ScenarioPath);
  R := nil;
  Scenarios := 0;
  Failures := 0;
  Result := 0;
  try
    for L := 0 to Lines.Count - 1 do
    begin
      Line := Lines[L];
      W := Words(Line);
      if (Length(W) = 0) or (W[0][1] = '#') then Continue;
      C := W[0];

      if C = 'scenario' then
      begin
        R.Free;
        R := TRun.Create(Arg(W, 1), ToFloat(Arg(W, 2)));
        Continue;
      end;
      if R = nil then Continue;

      if C = 'disk' then
      begin
        if not R.Disk.LoadFile(DiskPath(DisksDir, Arg(W, 1)), Err) then
        begin
          WriteLn(R.Name, ': ', Err);
          R.Failed := True;
        end;
        R.HaveDisk := True;
      end
      else if (C = 'synth') or (C = 'synthtext') then
      begin
        if C = 'synth' then
          Recipe := Presets[ToInt(Arg(W, 1))].Recipe
        else
          Recipe := FromText(RestOf(Line));
        OutDisk := TS950Disk.Create;
        try
          Err := '';
          if R.HaveDisk then Prev := R.Disk else Prev := nil;
          if not S950SynthPatch.Render(Recipe, R.Cache, Prev, OutDisk, Err) then
          begin
            WriteLn(R.Name, ': ', Err);
            R.Failed := True;
          end;
          R.Disk.Assign(OutDisk);
        finally
          OutDisk.Free;
        end;
        R.HaveDisk := True;
        if R.ProgramIndex >= 0 then SelectProgram(R, R.ProgramIndex);
      end
      else if C = 'program' then SelectProgram(R, ToInt(Arg(W, 1)))
      else if C = 'edit' then
      begin
        if R.Prog = nil then begin R.Failed := True; Continue; end;
        R.Disk.SetKeygroupParam(R.Prog^, ToInt(Arg(W, 1)), TKeygroupParam(ToInt(Arg(W, 2))), ToInt(Arg(W, 3)));
        Fresh := R.Disk.BuildPatch(R.Prog^, R.Patch);
        ReleasePatch(R.Patch);
        R.Patch := Fresh;
        Send(R);
      end
      else if C = 'crossfade' then
      begin
        R.XFade := ToInt(Arg(W, 1));
        if R.Patch <> nil then Send(R);
      end
      else if C = 'nopatch' then begin ReleasePatch(R.Patch); Send(R); end
      else if C = 'trim' then
      begin
        T := TrimNamed(R.Engine, Arg(W, 1));
        if T = nil then begin WriteLn('unknown trim ', Arg(W, 1)); R.Failed := True; Continue; end;
        V := ToFloat(Arg(W, 2));
        TAtomicSingle(Pointer(T)^).Store(V);
      end
      else if C = 'bendrange' then  R.Engine.BendRange.Store(ToFloat(Arg(W, 1)))
      else if C = 'glidetime' then  R.Engine.GlideSeconds.Store(ToFloat(Arg(W, 1)))
      else if C = 'widecents' then  R.Engine.WideCents.Store(ToFloat(Arg(W, 1)))
      else if C = 'widespread' then R.Engine.WideSpread.Store(ToFloat(Arg(W, 1)))
      else if C = 'wideoffset' then R.Engine.WideOffset.Store(ToInt(Arg(W, 1)) <> 0)
      else if C = 'on' then         R.Engine.NoteOn(ToInt(Arg(W, 1)), ToInt(Arg(W, 2)), AtArg(W, 3))
      else if C = 'off' then        R.Engine.NoteOff(ToInt(Arg(W, 1)), AtArg(W, 2))
      else if C = 'wheel' then      R.Engine.Modwheel(ToInt(Arg(W, 1)), AtArg(W, 2))
      else if C = 'pressure' then   R.Engine.Aftertouch(ToInt(Arg(W, 1)), AtArg(W, 2))
      else if C = 'bend' then       R.Engine.PitchBend(ToInt(Arg(W, 1)), AtArg(W, 2))
      else if C = 'glide' then      R.Engine.Glide(ToInt(Arg(W, 1)) <> 0, AtArg(W, 2))
      else if C = 'voices' then     R.Engine.SetVoiceLimit(ToInt(Arg(W, 1)), AtArg(W, 2))
      else if C = 'wide' then       R.Engine.Wide(ToInt(Arg(W, 1)) <> 0, AtArg(W, 2))
      else if C = 'alloff' then     R.Engine.AllNotesOff(AtArg(W, 1))
      else if C = 'transport' then
      begin
        R.Transport := True;
        R.Bpm := ToFloat(Arg(W, 1)); R.Ppq := ToFloat(Arg(W, 2));
        R.Playing := ToInt(Arg(W, 3)) <> 0; R.Qpb := ToFloat(Arg(W, 4));
      end
      else if C = 'render' then
      begin
        Total := ToInt(Arg(W, 1));
        if Length(W) > 2 then Block := ToInt(Arg(W, 2)) else Block := Total;
        Mono := Arg(W, 3) = 'mono';
        if Block > 0 then N := Block else N := 1;
        SetLength(Left, N);
        SetLength(Right, N);

        Done_ := 0;
        while Done_ < Total do
        begin
          N := MinI(Block, Total - Done_);
          if R.Transport then
          begin
            R.Engine.SetTransport(R.Bpm, R.Ppq, R.Playing, R.Qpb);
            if R.Playing then R.Ppq := R.Ppq + N / R.Engine.GetSampleRate * R.Bpm / 60.0;
          end;
          if Mono then
            R.Engine.Render(@Left[0], nil, N)
          else
            R.Engine.Render(@Left[0], @Right[0], N);
          for I := 0 to N - 1 do
          begin
            R.Push(Left[I]);
            if not Mono then R.Push(Right[I]);
          end;
          R.Engine.CollectRetiredPatch;
          Done_ := Done_ + Block;
        end;
      end
      else if C = 'end' then
      begin
        Inc(Scenarios);
        WriteFloats(IncludeTrailingPathDelimiter(OutDir) + R.Name + '.f32', R.Output, R.OutCount);
        Write(Format('%-28s %9d floats  active %d', [R.Name, R.OutCount, R.Engine.GetActiveVoices]));
        if R.Failed then begin Write('  FAILED'); Inc(Failures); end;
        WriteLn;
        FreeAndNil(R);
      end
      else
      begin
        WriteLn('unknown command: ', C);
        Result := 2;
        Exit;
      end;
    end;
  finally
    R.Free;
    Lines.Free;
  end;

  WriteLn(Format('render_pas: %d scenarios, %d failed', [Scenarios, Failures]));
  if Failures > 0 then Result := 1;
end;

function Compare(const ScenarioPath, CppDir, PasDir: string): Integer;
var
  Lines: TStringList;
  W: TWords;
  L, I, Diffs, First, Bad, Count, Total: Integer;
  A, B: TSingles;
  Name: string;
  MaxDiff, D, Peak: Double;
  BitsA, BitsB: Cardinal;
begin
  Lines := TStringList.Create;
  Lines.LoadFromFile(ScenarioPath);
  Bad := 0;
  Count := 0;
  Total := 0;
  try
    WriteLn(Format('%-28s %10s %12s %10s %s', ['scenario', 'samples', 'peak', 'differ', 'max |diff|']));
    for L := 0 to Lines.Count - 1 do
    begin
      W := Words(Lines[L]);
      if (Length(W) < 2) or (W[0] <> 'scenario') then Continue;
      Name := W[1];
      A := ReadFloats(IncludeTrailingPathDelimiter(CppDir) + Name + '.f32');
      B := ReadFloats(IncludeTrailingPathDelimiter(PasDir) + Name + '.f32');
      Inc(Count);
      Diffs := 0;
      First := -1;
      MaxDiff := 0;
      Peak := 0;
      if Length(A) <> Length(B) then
      begin
        WriteLn(Format('%-28s length %d (C++) against %d (Pascal)', [Name, Length(A), Length(B)]));
        Inc(Bad);
        Continue;
      end;
      for I := 0 to High(A) do
      begin
        if Abs(A[I]) > Peak then Peak := Abs(A[I]);
        Move(A[I], BitsA, 4);
        Move(B[I], BitsB, 4);
        if BitsA <> BitsB then
        begin
          Inc(Diffs);
          if First < 0 then First := I;
          D := A[I];
          D := Abs(D - B[I]);
          if D > MaxDiff then MaxDiff := D;
        end;
      end;
      Total := Total + Length(A);
      Write(Format('%-28s %10d %12.6f %10d %g', [Name, Length(A), Peak, Diffs, MaxDiff]));
      if Length(A) = 0 then Write('  EMPTY');
      if Peak = 0 then Write('  SILENT');
      if Diffs > 0 then
      begin
        Write(Format('  first at float %d', [First]));
        Inc(Bad);
      end;
      WriteLn;
    end;
  finally
    Lines.Free;
  end;
  WriteLn(Format('compare: %d scenarios, %d floats, %d differ', [Count, Total, Bad]));
  if Bad = 0 then
  begin
    WriteLn('compare: bit-identical');
    Result := 0;
  end
  else
    Result := 1;
end;

begin
  try
    if (ParamCount >= 4) and (ParamStr(1) = '--compare') then
      ExitCode := Compare(ParamStr(2), ParamStr(3), ParamStr(4))
    else if ParamCount >= 3 then
      ExitCode := Render(ParamStr(1), ParamStr(2), ParamStr(3))
    else
    begin
      WriteLn('render_pas <scenarios.txt> <disks dir> <outdir>');
      WriteLn('render_pas --compare <scenarios.txt> <cppdir> <pasdir>');
      ExitCode := 2;
    end;
  except
    on E: Exception do
    begin
      WriteLn('render_pas: ', E.ClassName, ': ', E.Message);
      ExitCode := 3;
    end;
  end;
end.
