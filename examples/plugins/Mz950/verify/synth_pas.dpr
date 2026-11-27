// Mz950 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Equivalence check, Pascal side: runs S950Synth and S950SynthPatch through the same list
// of cases synth_cpp.cpp runs the original C++ through, case for case and draw for draw,
// and compares the two outputs line by line.
//
//     synth_pas <cpp.txt> <pas.txt>
//
// Exit code 0 only if every line is identical.
program synth_pas;

{$IFDEF FPC}
  {$MODE DELPHI}
  // A real literal is a Double here even where a Single holds it exactly (1.0, 99.0, ...):
  // otherwise FPC types it Single, and 1.0 / n or n / 99.0 would be worked in single.
  {$MINFPCONSTPREC 64}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}
{$APPTYPE CONSOLE}

uses
  SysUtils, Classes, S950Math, S950Disk, S950Synth, S950SynthPatch;

var
  Lines: TStringList;

{$IFOPT Q+}{$DEFINE SYNTHPAS_Q}{$ENDIF}
{$IFOPT R+}{$DEFINE SYNTHPAS_R}{$ENDIF}
{$Q-}{$R-}

type
  TLcg = record
    S: Cardinal;
    function Next: Cardinal;
    function Range(Lo, Hi: Integer): Integer;
  end;

  TFnv = record
    H: UInt64;
    procedure Init;
    procedure Byte_(B: Byte);
    procedure Dbl(D: Double);
    procedure Word_(W: SmallInt);
  end;

function TLcg.Next: Cardinal;
begin
  S := S * Cardinal(1664525) + Cardinal(1013904223);
  Result := S shr 8;
end;

function TLcg.Range(Lo, Hi: Integer): Integer;
var
  N: Cardinal;
begin
  N := Next;
  Result := Lo + Integer(N mod Cardinal(Hi - Lo + 1));
end;

procedure TFnv.Init;
begin
  H := UInt64(14695981039346656037);
end;

procedure TFnv.Byte_(B: Byte);
begin
  H := H xor B;
  H := H * UInt64(1099511628211);
end;

procedure TFnv.Dbl(D: Double);
var
  U: UInt64;
  I: Integer;
begin
  Move(D, U, 8);
  for I := 0 to 7 do Byte_(Byte(U shr (8 * I)));
end;

procedure TFnv.Word_(W: SmallInt);
begin
  Byte_(Byte(W and $FF));
  Byte_(Byte((W shr 8) and $FF));
end;

function Hex64(V: UInt64): string;
begin
  Result := IntToHex(Int64(V), 16);
end;

function Bits(D: Double): string;
var
  U: UInt64;
begin
  Move(D, U, 8);
  Result := Hex64(U);
end;

{$IFDEF SYNTHPAS_Q}{$Q+}{$ENDIF}
{$IFDEF SYNTHPAS_R}{$R+}{$ENDIF}

procedure Line(const Section, Label_, Payload: string);
begin
  Lines.Add(Section + '|' + Label_ + '|' + Payload);
end;

function I2S(V: Integer): string;
begin
  Result := IntToStr(V);
end;

function WordsText(const W: array of SmallInt): string;
var
  F: TFnv;
  I: Integer;
begin
  F.Init;
  for I := 0 to High(W) do F.Word_(W[I]);
  Result := I2S(Length(W)) + ' ' + Hex64(F.H);
  I := 0;
  while (I < 4) and (I < Length(W)) do
  begin
    Result := Result + ' ' + I2S(W[I]);
    Inc(I);
  end;
end;

function SpectrumText(const Sp: TSpectrum): string;
var
  F: TFnv;
  N: Integer;
begin
  F.Init;
  for N := 0 to Sp.Harmonics do
  begin
    F.Dbl(Sp.Cos[N]);
    F.Dbl(Sp.Sin[N]);
  end;
  Result := I2S(Sp.Harmonics) + ' ' + Hex64(F.H);
end;

function DoublesText(const V: TDoubleArray): string;
var
  F: TFnv;
  I: Integer;
begin
  F.Init;
  for I := 0 to High(V) do F.Dbl(V[I]);
  Result := I2S(Length(V)) + ' ' + Hex64(F.H);
end;

function ImageText(D: TS950Disk): string;
var
  F: TFnv;
  Img: TBytes;
  I: Integer;
begin
  F.Init;
  Img := D.Image;
  for I := 0 to High(Img) do F.Byte_(Img[I]);
  Result := I2S(Length(Img)) + ' ' + Hex64(F.H);
end;

function ShapeText(const H: IHarmonic): string;
var
  F: TFnv;
  N: Integer;
begin
  F.Init;
  for N := 1 to 200 do F.Dbl(H.Amp(N));
  Result := Hex64(F.H) + ' ' + Bits(H.Amp(1)) + ' ' + Bits(H.Amp(7));
end;

function ProgramOf(D: TS950Disk; out P: TDiskEntry): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(D.Entries) do
    if D.Entries[I].EntryType = 'P' then
    begin
      P := D.Entries[I];
      Result := True;
    end;
end;

function B01(B: Boolean): string;
begin
  if B then Result := '1' else Result := '0';
end;

// ------------------------------------------------------------- Synth.h

type
  TSweepAt = class(TInterfacedObject, ISpectrumAt)
    Kind, H: Integer;
    function At(T: Double): TSpectrum;
  end;

function TSweepAt.At(T: Double): TSpectrum;
begin
  case Kind of
    0: Result := ModPulse(0.5 - 0.4 * T, H);
    1: Result := ModFm(1, 6.0 * T, H);
    2: Result := ModFm(7, 4.0 * T, H);
    3: Result := ModFm2(1, 4.0 * T, 3, 2.0 * T, H);
    4: Result := ModRing(ShapeSaw, 24, 2 + 1 * T, H);
    5: Result := ModBent(ShapeSaw, 24, 2.0 * T, H);
    6: Result := ModPhaseDistort(ShapeSaw, 16, 0.5 - 0.40 * T, H);
    7: Result := NoiseDusted(ShapeSaw, ncPink, 1.2 * T, 404, H);
  else
    Result := ModFm(2, 4.0 * T, H);
  end;
end;

function SweepAt(Kind, H: Integer): ISpectrumAt;
var
  S: TSweepAt;
begin
  S := TSweepAt.Create;
  S.Kind := Kind;
  S.H := H;
  Result := S;
end;

function One(const S: TSpectrum): TSpectrumArray;
begin
  SetLength(Result, 1);
  Result[0] := S;
end;

function Dbls(const A: array of Double): TDoubleArray;
var
  I: Integer;
begin
  SetLength(Result, Length(A));
  for I := 0 to High(A) do Result[I] := A[I];
end;

procedure SynthChecks;
const
  Seeds: array[0..16] of Integer = (0, 1, -1, 2, 42, 101, 12345, -12345, 161803398, -161803398, 161803399,
                                    2147483647, -2147483647, -2147483647 - 1, 1000000007, 7919, 404);
  Names: array[0..8] of string = ('', 'a', 'KICK 1', 'SNARE 3', 'HAT CLOSED', 'RIDE BELL', 'CLAVE',
                                  'ZZZZZZZZZZZZZZZZZZZZ', #127#1' x');
  Rates: array[0..4] of Double = (4000.0, 20000.0, 32000.0, 40000.0, 48000.0);
  NoiseSeeds: array[0..3] of Integer = (1, 101, 202, 303);
  PointsList: array[0..3] of Integer = (2, 5, 24, 64);
  Counts: array[0..8] of Integer = (5, 5, 5, 5, 4, 5, 5, 4, 4);
  Cyc: array[0..8] of Integer    = (96, 96, 96, 128, 96, 96, 96, 96, 128);
  HissWords: array[0..4] of Integer = (2, 7, 64, 513, 2000);
var
  Cases: array[0..21] of Double;
  Hzs: array[0..5] of Double;
  R: TNetRandom;
  F: TFnv;
  First, L: string;
  I, J, K, C, Si, Pi_, H: Integer;
  D, X, Hz: Double;
  Colour: TNoiseColour;
  Table, Two: TSpectrumArray;
  Drift, Grit, Unstable, Hard, None: TShake;
  Kit: TDrumArray;
begin
  // NetRandom
  for I := 0 to High(Seeds) do
  begin
    R.Init(Seeds[I]);
    F.Init;
    First := '';
    for J := 0 to 1999 do
    begin
      D := R.NextDouble;
      F.Dbl(D);
      if J < 3 then First := First + ' ' + Bits(D);
    end;
    Line('rng', I2S(Seeds[I]), Hex64(F.H) + First);
  end;

  // netRound
  Cases[0] := 0.0; Cases[1] := -0.0; Cases[2] := 0.5; Cases[3] := 1.5; Cases[4] := 2.5; Cases[5] := 3.5;
  Cases[6] := -0.5; Cases[7] := -1.5; Cases[8] := -2.5; Cases[9] := 0.49999999999999994;
  Cases[10] := -0.49999999999999994; Cases[11] := 2.5000000000000004; Cases[12] := 1e300; Cases[13] := -1e300;
  Cases[14] := 4503599627370495.5; Cases[15] := 4503599627370496.5; Cases[16] := 2047.5; Cases[17] := -2048.5;
  Cases[18] := 2046.5; Cases[19] := 0.1; Cases[20] := -0.9; Cases[21] := 123456.49999;
  // -0.0 as a literal is +0 in Pascal: make the negative zero by hand
  Cases[1] := -Cases[0];
  for I := 0 to High(Cases) do Line('netround', I2S(I), Bits(NetRound(Cases[I])));

  // drums::seed
  for I := 0 to High(Names) do Line('seed', I2S(I), I2S(DrumSeed(Names[I])));

  // shapes
  Line('shape', 'saw', ShapeText(ShapeSaw));
  Line('shape', 'square', ShapeText(ShapeSquare));
  Line('shape', 'triangle', ShapeText(ShapeTriangle));
  Line('shape', 'sine', ShapeText(ShapeSine));
  Line('shape', 'organ', ShapeText(ShapeOrgan));
  Line('shape', 'hollow', ShapeText(ShapeHollow));
  Line('shape', 'glass', ShapeText(ShapeGlass));
  Line('shape', 'buzz', ShapeText(ShapeBuzz));
  for I := 0 to 10 do Line('shape', 'pulse' + I2S(I), ShapeText(ShapePulse(I / 10.0)));
  Line('shape', 'mix', ShapeText(ShapeMix(ShapeSaw, ShapeSquare, 0.3)));
  Line('shape', 'partials', ShapeText(ShapePartials([1.0, 0.5, 0.7, 0.25, 0.3, 0.2, 0.45])));
  Line('shape', 'lift', ShapeText(ShapeLift(ShapeSaw, 0.55, [3, 6])));
  Line('shape', 'plus', ShapeText(ShapePlus(ShapeTriangle, ShapeOrgan, 0.4)));
  Line('shape', 'nest', ShapeText(ShapePlus(ShapeMix(ShapeHollow, ShapeGlass, 0.7),
                                            ShapeLift(ShapeBuzz, -0.2, [1, 2, 9]), 1.3)));

  // spectra
  H := HighestHarmonic(20000, RootHz);
  for I := 0 to 8 do
  begin
    X := I / 8.0;
    Line('spec', 'pulse' + I2S(I), SpectrumText(ModPulse(0.5 - 0.45 * X, H)));
    Line('spec', 'fm' + I2S(I), SpectrumText(ModFm(1 + I mod 3, 8.0 * X, H)));
    Line('spec', 'fm2' + I2S(I), SpectrumText(ModFm2(1, 4.0 * X, 3, 2.0 * X, H)));
    Line('spec', 'ring' + I2S(I), SpectrumText(ModRing(ShapeSaw, 24, 2 + X, H)));
    Line('spec', 'bent' + I2S(I), SpectrumText(ModBent(ShapeSaw, 24, 2.5 * X, H)));
    Line('spec', 'pd' + I2S(I), SpectrumText(ModPhaseDistort(ShapeSine, 1, 0.5 - 0.44 * X - 0.1, H)));
    Line('spec', 'blend' + I2S(I), SpectrumText(SpectrumBlend(SpectrumFromShape(ShapeSaw, H),
                                                              SpectrumFromShape(ShapeSine, 20 + I), X)));
    Line('spec', 'limit' + I2S(I), SpectrumText(SpectrumLimitedTo(SpectrumFromShape(ShapeSquare, H), I * 6)));
  end;
  Line('spec', 'analyse-big', SpectrumText(ModFm(2, 3.0, 200)));
  for C := 0 to 2 do
    for Si := 0 to High(NoiseSeeds) do
    begin
      Colour := TNoiseColour(C);
      L := I2S(C) + '/' + I2S(NoiseSeeds[Si]);
      Line('noise', 'spec' + L, SpectrumText(NoiseSpectrum(Colour, NoiseSeeds[Si], H)));
      Line('noise', 'dust' + L, SpectrumText(NoiseDusted(ShapeSaw, Colour, 0.7, NoiseSeeds[Si], H)));
      for Pi_ := 0 to High(PointsList) do
        Line('noise', 'wander' + L + '/' + I2S(PointsList[Pi_]),
             DoublesText(NoiseWander(NoiseSeeds[Si], PointsList[Pi_], Colour, 1000 + PointsList[Pi_])));
    end;

  // waveforms
  Hzs[0] := 27.5; Hzs[1] := RootHz; Hzs[2] := 440.0; Hzs[3] := 1000.0; Hzs[4] := 9999.0; Hzs[5] := 30000.0;
  for I := 0 to High(Rates) do
    for J := 0 to High(Hzs) do
      Line('wave', 'words ' + Bits(Rates[I]) + ' ' + Bits(Hzs[J]),
           I2S(WordsFor(8, Rates[I], Hzs[J])) + ' ' + I2S(WordsFor(96, Rates[I], Hzs[J]))
           + ' ' + I2S(HighestHarmonic(Rates[I], Hzs[J])));

  Hz := RootHz;
  Line('wave', 'SAW',      WordsText(WaveRender(ShapeSaw, 40000, Hz)));
  Line('wave', 'SQUARE',   WordsText(WaveRender(ShapeSquare, 40000, Hz)));
  Line('wave', 'TRIANGLE', WordsText(WaveRender(ShapeTriangle, 40000, Hz)));
  Line('wave', 'SINE',     WordsText(WaveRender(ShapeSine, 40000, Hz)));
  Line('wave', 'ORGAN',    WordsText(WaveRender(ShapeOrgan, 40000, Hz)));
  Line('wave', 'HOLLOW',   WordsText(WaveRender(ShapeHollow, 40000, Hz)));
  Line('wave', 'GLASS',    WordsText(WaveRender(ShapeGlass, 40000, Hz)));
  Line('wave', 'BUZZ',     WordsText(WaveRender(ShapeBuzz, 40000, Hz)));
  Line('wave', 'PULSE25',  WordsText(WaveRender(ShapePulse(0.25), 40000, Hz)));
  Line('wave', 'FIFTHS',   WordsText(WaveRender(ShapeLift(ShapeSaw, 0.55, [3, 6]), 40000, Hz)));
  Line('wave', 'REED',     WordsText(WaveRender(ShapePartials([1.0, 0.5, 0.7, 0.25, 0.3, 0.2, 0.45]), 40000, Hz)));
  Line('wave', 'SAW 32K 440', WordsText(WaveRender(ShapeSaw, 32000, 440.0)));

  SetLength(Table, 2);
  Table[0] := SpectrumFromShape(ShapeSine, H);
  Table[1] := SpectrumFromShape(ShapeSaw, H);
  Line('wave', 'MORPH SS', WordsText(WaveRender(Table, 96, 20000, Hz)));
  for K := 0 to 8 do
  begin
    Table := Mirror(Steps(Counts[K], SweepAt(K, H)));
    Line('wave', 'sweep' + I2S(K) + ' ' + I2S(Length(Table)), WordsText(WaveRender(Table, Cyc[K], 20000, Hz)));
    Two := Steps(2, SweepAt(K, H));
    Line('wave', 'two' + I2S(K) + ' ' + I2S(Length(Mirror(Two))), WordsText(WaveRender(Mirror(Two), 32, 20000, Hz)));
  end;
  Line('wave', 'WHITE', WordsText(WaveRender(One(NoiseSpectrum(ncWhite, 101, H)), 32, 20000, Hz)));
  Line('wave', 'PINK',  WordsText(WaveRender(One(NoiseSpectrum(ncPink,  202, H)), 32, 20000, Hz)));
  Line('wave', 'BROWN', WordsText(WaveRender(One(NoiseSpectrum(ncBrown, 303, H)), 32, 20000, Hz)));

  Drift.Init; Drift.PitchDepth := 0.06; Drift.Colour := ncBrown; Drift.Points := 18; Drift.Seed := 11;
  Line('wave', 'DRIFT', WordsText(WaveRender(One(SpectrumFromShape(ShapeSaw, H)), 96, 20000, Hz, @Drift)));

  Grit.Init; Grit.AmDepth := 0.45; Grit.Colour := ncWhite; Grit.Points := 64; Grit.Seed := 22;
  Line('wave', 'GRIT', WordsText(WaveRender(One(SpectrumFromShape(ShapeSquare, H)), 96, 20000, Hz, @Grit)));

  Unstable.Init; Unstable.PitchDepth := 0.12; Unstable.AmDepth := 0.35; Unstable.Colour := ncPink; Unstable.Points := 40; Unstable.Seed := 33;
  Line('wave', 'UNSTABLE', WordsText(WaveRender(Mirror(Steps(4, SweepAt(8, H))), 128, 20000, Hz, @Unstable)));

  Hard.Init; Hard.AmDepth := 1.8; Hard.PitchDepth := 0.3; Hard.Colour := ncBrown; Hard.Points := 3; Hard.Seed := 44;
  Line('wave', 'HARD', WordsText(WaveRender(One(SpectrumFromShape(ShapeSaw, H)), 64, 20000, Hz, @Hard)));
  None.Init;
  Line('wave', 'NONE', WordsText(WaveRender(One(SpectrumFromShape(ShapeSaw, H)), 8, 20000, Hz, @None))
                       + ' ' + B01(None.Any) + B01(Hard.Any));

  for I := 0 to High(HissWords) do
    Line('wave', 'HISS ' + I2S(HissWords[I]), WordsText(WaveHiss(HissWords[I], 12345 + HissWords[I])));
  D := -0.0;
  Line('wave', 'QUANT', WordsText(Quantise(Dbls([0.0, 1.0, -1.0, 0.5, -0.5, 0.25 / 2047, 1e-300, -1e300]))));
  Line('wave', 'QUANT0', WordsText(Quantise(Dbls([0.0, 0.0, D]))));

  // drums
  Kit := DrumKit;
  for I := 0 to High(Kit) do
    Line('drum', Kit[I].Name, I2S(Kit[I].Key) + ' ' + I2S(Kit[I].Rate) + ' ' + Bits(Kit[I].Seconds) + ' '
                            + I2S(Kit[I].Loudness) + ' ' + I2S(Kit[I].Vel) + ' ' + WordsText(DrumRender(Kit[I])));
end;

// -------------------------------------------------------- SynthPatch.h

function PlanText(const P: TMixPlan): string;
var
  I: Integer;
begin
  Result := I2S(P.Rate) + ' ' + I2S(P.Words) + ' ' + I2S(P.RootCycles) + ' o';
  for I := 0 to High(P.Oscs) do Result := Result + ' ' + I2S(P.Oscs[I]);
  Result := Result + ' c';
  for I := 0 to High(P.Cycles) do Result := Result + ' ' + I2S(P.Cycles[I]);
  Result := Result + ' t';
  for I := 0 to High(P.SweepTrips) do Result := Result + ' ' + I2S(P.SweepTrips[I]);
  Result := Result + ' e';
  for I := 0 to High(P.ErrorCents) do Result := Result + ' ' + Bits(P.ErrorCents[I]);
end;

procedure RandomOsc(var T: TLcg; var O: TOscSettings; OnPercent: Integer);
var
  On_: Boolean;
  Kind: Integer;
begin
  On_ := T.Range(0, 99) < OnPercent;
  Kind := T.Range(1, 19);
  if On_ then O.Kind := TOscKind(Kind) else O.Kind := okOff;
  O.Level := T.Range(-5, 105);
  O.Octave := T.Range(-2, 2);
  O.Fine := T.Range(-60, 60);
  O.Phase := T.Range(0, 99);
  O.Intensity := T.Range(0, 99);
  if T.Range(0, 99) < 50 then O.Sweep := 0
  else O.Sweep := T.Range(0, 99);
end;

function RandomRecipe(var T: TLcg): TRecipe;
const
  Names: array[0..7] of string = ('SYNTH', 'LEAD', 'PAD 2', 'BASS', 'A', 'LONGER NAME HERE', 'lower', 'X 9');
var
  I: Integer;
begin
  Result.Init;
  Result.Name := Names[T.Range(0, 7)];
  RandomOsc(T, Result.Osc[0], 85);
  RandomOsc(T, Result.Osc[1], 50);
  RandomOsc(T, Result.Osc[2], 35);
  Result.DrumsOn := T.Range(0, 1) <> 0;
  for I := 0 to DrumSlotCount - 1 do
  begin
    Result.Drums[I].On_ := T.Range(0, 3) <> 0;
    Result.Drums[I].Tune := T.Range(-12, 12);
    Result.Drums[I].Decay := T.Range(0, 99);
    Result.Drums[I].Tone := T.Range(0, 99);
    Result.Drums[I].Level := T.Range(-50, 50);
  end;
  Result.Filter := T.Range(0, 99); Result.KeyTrack := T.Range(0, 99); Result.VelFilter := T.Range(0, 99);
  Result.A := T.Range(0, 99); Result.D := T.Range(0, 99); Result.S := T.Range(0, 99); Result.R := T.Range(0, 99);
  Result.VcfA := T.Range(0, 99); Result.VcfD := T.Range(0, 99); Result.VcfS := T.Range(0, 99); Result.VcfR := T.Range(0, 99);
  Result.VcfAmount := T.Range(-60, 60); Result.VelLoudness := T.Range(0, 99);
  Result.LfoRate := T.Range(0, 99); Result.LfoDepth := T.Range(0, 99); Result.LfoDelay := T.Range(0, 99);
end;

procedure EditKeygroups(D: TS950Disk; Salt: Integer);
var
  Prog: TDiskEntry;
  N, K, Q: Integer;
  Param: TKeygroupParam;
begin
  if not ProgramOf(D, Prog) then Exit;
  N := Length(D.Keygroups(Prog));
  for K := 0 to N - 1 do
    for Q := 0 to KeygroupParamCount - 1 do
    begin
      Param := TKeygroupParam(Q);
      if (Param = kpHighKey) or (Param = kpLowKey) then Continue;
      D.SetKeygroupParam(Prog, K, Param, ((K * 31 + Q * 17 + Salt) mod 140) - 20);
    end;
end;

function RenderText(const R: TRecipe; Cache: TWaveCache; Previous: TS950Disk; Keep: TS950Disk = nil): string;
var
  D: TS950Disk;
  Error: string;
begin
  D := TS950Disk.Create;
  try
    Error := 'untouched';
    if not Render(R, Cache, Previous, D, Error) then
      Exit('err ' + Error);
    Result := 'ok ' + Error + ' ' + ImageText(D) + ' sep' + B01(HasSeparateOscillators(R, D))
            + ' old' + B01(HasOldTuning(R, D));
    if Keep <> nil then Keep.Assign(D);
  finally
    D.Free;
  end;
end;

procedure PatchChecks;
const
  Intensities: array[0..3] of Integer = (0, 37, 50, 99);
  SweepsList: array[0..2] of Integer = (0, 45, 99);
  PhasesList: array[0..2] of Integer = (0, 33, 99);
var
  K, S, Ii, Si, Pi_, I, F, O, Kk, Mode, Cents, Fine256, OldHigh, OldLow, Sixteenths, NewHigh, NewLow, Ti: Integer;
  Lb: TOscKindLabels;
  Cache, Mc, Rc: TWaveCache;
  Os, Off: TOscSettings;
  T: TLcg;
  R, R2, R3, None, Other, E: TRecipe;
  Plan: TMixPlan;
  W: TSmallIntArray;
  Ps: TPresetArray;
  First, D: TS950Disk;
  Error: string;
  Used: array of Integer;
  Ns: TNewSample;
  Ok, Okp: Boolean;
  Prog: TDiskEntry;
  Texts: array of string;

  procedure AddText(const S_: string);
  begin
    SetLength(Texts, Length(Texts) + 1);
    Texts[High(Texts)] := S_;
  end;

begin
  for K := 0 to Ord(okCount) do
  begin
    Lb := OscKindLabels(TOscKind(K));
    Line('kind', I2S(K), OscKindName(TOscKind(K)) + '/' + Lb.Intensity + '/' + Lb.Sweep
                       + '/' + B01(Lb.HasIntensity) + B01(Lb.HasSweep));
  end;
  for S := 0 to DrumSlotCount - 1 do
    Line('slot', I2S(S), DrumSlotName(TDrumSlot(S)) + '/' + I2S(DrumSlotNote(TDrumSlot(S))));

  Cache := TWaveCache.Create;
  Mc := TWaveCache.Create;
  Rc := TWaveCache.Create;
  First := TS950Disk.Create;
  try
    // single oscillator waves: every kind across a grid
    for K := 1 to Ord(okCount) - 1 do
      for Ii := 0 to High(Intensities) do
        for Si := 0 to High(SweepsList) do
          for Pi_ := 0 to High(PhasesList) do
          begin
            Os.Init;
            Os.Kind := TOscKind(K); Os.Intensity := Intensities[Ii]; Os.Sweep := SweepsList[Si]; Os.Phase := PhasesList[Pi_];
            Line('osc', I2S(K) + '/' + I2S(Intensities[Ii]) + '/' + I2S(SweepsList[Si]) + '/' + I2S(PhasesList[Pi_]),
                 WordsText(OscillatorWave(Os, Cache)));
          end;

    T.S := 777;
    for I := 0 to 119 do
    begin
      Os.Init;
      RandomOsc(T, Os, 100);
      Line('oscr', I2S(I), WordsText(OscillatorWave(Os, Cache)));
    end;
    Off.Init;
    Line('oscr', 'off', WordsText(OscillatorWave(Off, Cache)));
    Line('oscr', 'cache', I2S(Cache.Count));

    // plans, for many recipes
    T.S := 4242;
    for I := 0 to 1499 do
    begin
      R := RandomRecipe(T);
      Line('plan', I2S(I), PlanText(PlanMix(R)));
    end;
    None.Init;
    Line('plan', 'none', PlanText(PlanMix(None)));
    F := -60;
    while F <= 60 do
    begin
      R.Init;
      R.Osc[0].Kind := okSaw;
      R.Osc[1].Kind := okPulse; R.Osc[1].Fine := F; R.Osc[1].Sweep := (F + 60) mod 100;
      R.Osc[2].Kind := okSine; R.Osc[2].Octave := (F + 60) mod 5 - 2; R.Osc[2].Fine := (-F) div 2;
      Line('plan', 'fine' + I2S(F), PlanText(PlanMix(R)));
      Inc(F);
    end;

    // mixes, small ones on their own
    T.S := 99;
    for I := 0 to 39 do
    begin
      R.Init;
      RandomOsc(T, R.Osc[0], 100);
      RandomOsc(T, R.Osc[1], 50);
      R.Osc[0].Fine := T.Range(-1, 1) * 50;
      R.Osc[1].Fine := 0;
      Plan.Init;
      W := MixedWave(R, Mc, Plan);
      Line('mix', I2S(I), PlanText(Plan) + ' ' + WordsText(W));
    end;

    // presets, rendered and as text
    Ps := Presets;
    for I := 0 to High(Ps) do
    begin
      Line('preset', I2S(I), Ps[I].Name + ' ' + ToText(Ps[I].Recipe));
      Line('preset-render', I2S(I), RenderText(Ps[I].Recipe, Rc, nil));
      if Ps[I].Recipe.AnyOscillator then
      begin
        Plan.Init;
        W := MixedWave(Ps[I].Recipe, Rc, Plan);
        Line('preset-mix', I2S(I), PlanText(Plan) + ' ' + WordsText(W));
      end;
      Line('preset-text', I2S(I), ToText(FromText(ToText(Ps[I].Recipe))));
    end;

    // random recipes, rendered, and again over an edited disk
    T.S := 2026;
    for I := 0 to 299 do
    begin
      R := RandomRecipe(T);
      if I mod 9 = 0 then begin R.Osc[0].Kind := okOff; R.Osc[1].Kind := okOff; R.Osc[2].Kind := okOff; end;
      if I mod 23 = 0 then for S := 0 to DrumSlotCount - 1 do R.Drums[S].On_ := False;
      Line('text', I2S(I), ToText(R));
      Line('text-rt', I2S(I), ToText(FromText(ToText(R))));
      Line('anyosc', I2S(I), B01(R.AnyOscillator));

      First.Free;
      First := TS950Disk.Create;
      Line('render', I2S(I), RenderText(R, Rc, nil, First));

      if (I mod 4 = 0) and (Length(First.Entries) > 0) then
      begin
        EditKeygroups(First, I);
        Line('edited', I2S(I), ImageText(First));

        R2 := R;
        R2.Osc[0].Level := T.Range(0, 99);
        R2.Drums[0].Decay := T.Range(0, 99);
        R2.Drums[1].On_ := T.Range(0, 1) <> 0;
        R2.Drums[3].Level := T.Range(-50, 50);
        R2.A := T.Range(0, 99);
        if T.Range(0, 3) = 0 then R2.DrumsOn := not R2.DrumsOn;
        Line('again', I2S(I), RenderText(R2, Rc, First));

        R3 := R2;
        R3.Name := 'OTHER';
        Line('again-other', I2S(I), RenderText(R3, Rc, First));
      end;
    end;

    // a disk in the old layout: a keygroup per oscillator
    T.S := 31337;
    for I := 0 to 23 do
    begin
      R := RandomRecipe(T);
      R.Osc[0].Kind := TOscKind(T.Range(1, 19));
      R.Osc[1].Fine := T.Range(-50, 50);
      R.Osc[0].Fine := T.Range(-50, 50);

      D := TS950Disk.Blank(R.Name + ' DISK');
      try
        Error := '';
        Used := nil;
        for O := 0 to 2 do
        begin
          if R.Osc[O].Kind = okOff then Continue;
          Ns.Init;
          Ns.Name := 'OSC' + I2S(O + 1);
          Ns.Words12 := OscillatorWave(R.Osc[O], Rc);
          Ns.Rate := 40000; Ns.RootNote := 60; Ns.LoopMode := 'L';
          Ok := D.AddSample(Ns, Error);
          if Ok then Line('old-add', I2S(I) + '/' + I2S(O), 'ok')
          else Line('old-add', I2S(I) + '/' + I2S(O), 'err ' + Error);
          SetLength(Used, Length(Used) + 1);
          Used[High(Used)] := O;
        end;
        if T.Range(0, 3) = 0 then
        begin
          Ns.Init;
          Ns.Name := 'KICK 1';
          SetLength(Ns.Words12, 300);
          for Kk := 0 to 299 do Ns.Words12[Kk] := 5;
          Ns.Rate := 20000; Ns.RootNote := 36; Ns.LoopMode := 'O';
          D.AddSample(Ns, Error);
          SetLength(Used, Length(Used) + 1);
          Used[High(Used)] := 9;
        end;
        Okp := D.AddProgram(R.Name, Length(Used), Error);
        if Okp then Line('old-prog', I2S(I), 'ok') else Line('old-prog', I2S(I), 'err ' + Error);
        if ProgramOf(D, Prog) then
          for Kk := 0 to High(Used) do
          begin
            O := Used[Kk];
            if O = 9 then D.SetZoneSample(Prog, Kk, 0, 'KICK 1')
            else D.SetZoneSample(Prog, Kk, 0, 'OSC' + I2S(O + 1));
            if O = 9 then Continue;
            Cents := MaxI(-50, MinI(50, R.Osc[O].Fine));
            Fine256 := LRound(Abs(Cents) * 2.56);
            if Cents < 0 then OldHigh := R.Osc[O].Octave * 12 - 1 else OldHigh := R.Osc[O].Octave * 12;
            if Cents < 0 then OldLow := 256 - Fine256 else OldLow := Fine256;
            Sixteenths := R.Osc[O].Octave * 12 * 16 + LRound(Cents * 16.0 / 100.0);
            if Sixteenths >= 0 then NewHigh := Sixteenths div 256 else NewHigh := -((255 - Sixteenths) div 256);
            NewLow := Sixteenths - NewHigh * 256;
            Mode := T.Range(0, 3);
            if (Mode = 0) or (Mode = 3) then
            begin
              D.SetKeygroupParam(Prog, Kk, kpZone1Transpose, OldHigh);
              D.SetKeygroupParam(Prog, Kk, kpZone1Fine, OldLow and $FF);
            end
            else if Mode = 1 then
            begin
              D.SetKeygroupParam(Prog, Kk, kpZone1Transpose, NewHigh);
              D.SetKeygroupParam(Prog, Kk, kpZone1Fine, NewLow);
            end
            else
            begin
              D.SetKeygroupParam(Prog, Kk, kpZone1Transpose, T.Range(-30, 30));
              D.SetKeygroupParam(Prog, Kk, kpZone1Fine, T.Range(0, 255));
            end;
            D.SetKeygroupParam(Prog, Kk, kpVcaAttack, T.Range(0, 99));
            D.SetKeygroupParam(Prog, Kk, kpLfoRate, T.Range(0, 99));
            D.SetKeygroupParam(Prog, Kk, kpZone1Filter, T.Range(0, 99));
          end;
        D.RebuildPointers;
        Line('old-disk', I2S(I), ImageText(D) + ' sep' + B01(HasSeparateOscillators(R, D))
                                + ' old' + B01(HasOldTuning(R, D)));
        Other := R;
        Other.Name := 'NOPE';
        Line('old-other', I2S(I), 'sep' + B01(HasSeparateOscillators(Other, D))
                                 + ' old' + B01(HasOldTuning(Other, D)));
        Line('old-render', I2S(I), RenderText(R, Rc, D));
      finally
        D.Free;
      end;
    end;

    // errors
    R.Init;
    R.Osc[0].Kind := okOff;
    Line('error', 'nothing', RenderText(R, Rc, nil));
    R.DrumsOn := True;
    for S := 0 to DrumSlotCount - 1 do R.Drums[S].On_ := False;
    Line('error', 'no drums', RenderText(R, Rc, nil));
    E.Init;
    E.Name := '';
    Line('error', 'empty name', RenderText(E, Rc, nil));
    E.Name := '   ';
    Line('error', 'blank name', RenderText(E, Rc, nil));
    E.Name := 'lower case name';
    E.DrumsOn := True;
    Line('error', 'long name', RenderText(E, Rc, nil));

    // text by hand
    Texts := nil;
    AddText(''); AddText('name=FOO'); AddText('name=MY_PAD o0=5,99,0,0,0,40,70'); AddText('o1=3,1,2,3');
    AddText('o0=99,1,2,3,4,5,6 o3=1,1,1,1,1,1,1 d9=1,1,1,1,1 d0=0,-3,50,60,-7');
    AddText('voice=1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16'); AddText('voice=1,2'); AddText('drums=1'); AddText('drums=x'); AddText('drums=-0');
    AddText(' name=A'#9'drums=2'#10' o2=-4,a,3b,,7,8,9 '); AddText('o0=1,2,3,4,5,6,7,'); AddText('o0=,1,2,3,4,5,6');
    AddText('o0=99999999999,1,2,3,4,5,6'); AddText('o0=-99999999999,1,2,3,4,5,6'); AddText('noequals'); AddText('=5'); AddText('name='); AddText('name==X');
    AddText('o0==1,2,3,4,5,6,7'); AddText('d0=1,2,3,4,5 d0=0,0,0,0,0'); AddText('o0=+5,+1,-0,2,3,4,5'); AddText('oo=1,2,3,4,5,6,7');
    AddText('o00=1,2,3,4,5,6,7'); AddText('d-=1,2,3,4,5'); AddText('o0=1,2,3,4,5,6,7,8,9'); AddText('o0=-1,1,1,1,1,1,1'); AddText('o2=19,1,1,1,1,1,1');
    AddText('o2=20,1,1,1,1,1,1'); AddText('d8=7,1,1,1,1'); AddText('d9=1,1,1,1,1'); AddText('voice=,,,,,,,,,,,,,,,'); AddText('voice=1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17');
    AddText('name=a_b__c_ drums=0x10'); AddText('drums= 1'); AddText('o0=1, 2,3,4,5,6,7'); AddText(#11#12'name=VT'#13#10); AddText('o0=2147483648,-2147483649,1,1,1,1,1');
    AddText('o1=  ,1'); AddText('name=X name=Y'); AddText('drums=12abc'); AddText('o0=0x5,1e3,1.9,-1.9,--2,+-3,4');
    for Ti := 0 to High(Texts) do Line('fromtext', I2S(Ti), ToText(FromText(Texts[Ti])));
  finally
    First.Free;
    Cache.Free;
    Mc.Free;
    Rc.Free;
  end;
end;

// ------------------------------------------------------------------ compare

function Section(const S: string): string;
var
  P: Integer;
begin
  P := Pos('|', S);
  if P > 0 then Result := Copy(S, 1, P - 1) else Result := S;
end;

function Compare(Cpp: TStringList): Integer;
var
  I, N, Shown: Integer;
  Counts, Bad: TStringList;
  Sec: string;
begin
  Result := 0;
  Shown := 0;
  Counts := TStringList.Create;
  Bad := TStringList.Create;
  try
    N := Lines.Count;
    if Cpp.Count > N then N := Cpp.Count;
    for I := 0 to N - 1 do
    begin
      if I < Cpp.Count then Sec := Section(Cpp[I]) else Sec := Section(Lines[I]);
      if Counts.IndexOf(Sec) < 0 then
      begin
        Counts.Add(Sec);
        Bad.Add(Sec);
        Counts.Objects[Counts.Count - 1] := TObject(0);
        Bad.Objects[Bad.Count - 1] := TObject(0);
      end;
      Counts.Objects[Counts.IndexOf(Sec)] := TObject(PtrInt(Counts.Objects[Counts.IndexOf(Sec)]) + 1);
      if (I >= Cpp.Count) or (I >= Lines.Count) or (Cpp[I] <> Lines[I]) then
      begin
        Inc(Result);
        Bad.Objects[Bad.IndexOf(Sec)] := TObject(PtrInt(Bad.Objects[Bad.IndexOf(Sec)]) + 1);
        if Shown < 20 then
        begin
          Inc(Shown);
          if I < Cpp.Count then WriteLn('  C++ : ', Cpp[I]) else WriteLn('  C++ : (none)');
          if I < Lines.Count then WriteLn('  Pas : ', Lines[I]) else WriteLn('  Pas : (none)');
        end;
      end;
    end;
    for I := 0 to Counts.Count - 1 do
      WriteLn(Format('  %-14s %6d compared, %d mismatched', [Counts[I], PtrInt(Counts.Objects[I]), PtrInt(Bad.Objects[I])]));
    WriteLn(Format('synth check: %d lines compared (C++ %d, Pascal %d), mismatches = %d',
                   [N, Cpp.Count, Lines.Count, Result]));
  finally
    Counts.Free;
    Bad.Free;
  end;
end;

var
  Cpp: TStringList;
  Mismatches: Integer;

begin
  if (ParamCount < 2) or ((ParamStr(1) = '--compare') and (ParamCount < 3)) then
  begin
    WriteLn('usage: synth_pas <cpp.txt> <pas.txt>');
    WriteLn('       synth_pas --compare <cpp.txt> <pas.txt>   (compare two outputs, render nothing)');
    Halt(2);
  end;
  Lines := TStringList.Create;
  Cpp := TStringList.Create;
  try
    if ParamStr(1) = '--compare' then
    begin
      Cpp.LoadFromFile(ParamStr(2));
      Lines.LoadFromFile(ParamStr(3));
    end
    else
    begin
      SynthChecks;
      PatchChecks;
      Lines.SaveToFile(ParamStr(2));
      Cpp.LoadFromFile(ParamStr(1));
    end;
    Mismatches := Compare(Cpp);
  finally
    Cpp.Free;
    Lines.Free;
  end;
  if Mismatches <> 0 then Halt(1);
end.
