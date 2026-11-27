// Mz950 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Plugin/Source/S950/Synth.h and Synth.cpp.
//
// The C++'s std::function values are reference-counted interfaces here, since FPC 3.2.2 has
// no closures: a Harmonic is an IHarmonic, whose Amp (n) is the lambda's call, and the
// composable shapes (mix, partials, lift, plus) are objects holding what the lambdas
// captured. Spectrum::analyse's cycle is an ICycle, waveforms::steps' generator an
// ISpectrumAt, and a drum's voice a plain function pointer (every one is a capture-free
// lambda in the C++). The C++ namespaces are prefixes: shapes::saw is ShapeSaw,
// modulation::fm is ModFm, noise::wander is NoiseWander, waveforms::render is WaveRender,
// drums::kit is DrumKit.
//
// Every libm call is the C library's (S950Math), and every sum and product is in the C++'s
// order: a wave is rounded to 12-bit words, and one ulp can flip a word. See the note on
// precision at the top of S950Math.pas.

unit S950Synth;

{$IFDEF FPC}
  {$MODE DELPHI}
  // A real literal is a Double here even where a Single holds it exactly (1.0, 99.0, ...):
  // otherwise FPC types it Single, and 1.0 / n or n / 99.0 would be worked in single.
  {$MINFPCONSTPREC 64}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  S950Math;

//
// Sounds drawn rather than recorded: AkaiS950Synth, the C# workshop tool, ported.
//
// Nothing in here plays. It makes 12-bit WORDS - the audio a sample file holds - and hands
// them to Disk::addSample, so a sound designed on the plugin's Synth page is a sample on a
// disk and goes through the S950's voice like any other, and can go to the real machine.
//
// Two kinds of thing come out:
//
//   - WAVES: a few cycles of a periodic waveform, looped. Built from harmonics, so they are
//     band-limited by construction; and where the harmonics change across the sample the
//     loop is a wavetable, which is how a sampler does pulse-width modulation, FM sweeps and
//     the rest without a modulator.
//   - DRUMS: one-shots with the whole envelope baked in, from the recipes the analogue
//     machines used.
//
// Held to the C# number for number, which is why System.Random is ported rather than
// replaced: a drum seeded from its name comes out the same words here as there.
//

type
  TDoubleArray = array of Double;
  TIntegerArray = array of Integer;
  TWords12 = array of SmallInt;   // std::vector<short>

  // -------------------------------------------------------------- .NET's Random

  /// The .NET Framework's System.Random, exactly: Knuth's subtractive generator. Seeds
  /// mean the same here as in the C# tool, so its disks and ours are the same disks.
  TNetRandom = record
  private
    SeedArray: array[0..55] of Integer;
    INext, INextP: Integer;
    function InternalSample: Integer;
  public
    procedure Init(Seed: Integer);   // the constructor
    function NextDouble: Double;
  end;

/// Round half to even, as .NET's Math.Round does.
function NetRound(V: Double): Double;

// ------------------------------------------------------------------ the shapes

type
  /// The amplitude of harmonic n. Zero means absent.
  IHarmonic = interface
    function Amp(N: Integer): Double;
  end;

// namespace shapes
function ShapeSaw: IHarmonic;
function ShapeSquare: IHarmonic;
function ShapeTriangle: IHarmonic;
function ShapeSine: IHarmonic;
function ShapePulse(Duty: Double): IHarmonic;
function ShapeOrgan: IHarmonic;
function ShapeHollow: IHarmonic;
function ShapeGlass: IHarmonic;
function ShapeBuzz: IHarmonic;

function ShapeMix(const A, B: IHarmonic; Amount: Double): IHarmonic;
function ShapePartials(const Levels: array of Double): IHarmonic;
function ShapeLift(const Shape: IHarmonic; Amount: Double; const Which: array of Integer): IHarmonic;
function ShapePlus(const A, B: IHarmonic; Level: Double): IHarmonic;

// ---------------------------------------------------------------- the spectrum

type
  /// One waveform, as what is in it: cosine and sine coefficients per harmonic. Index 0
  /// is unused; harmonic n is at n.
  ///
  /// The arrays are written only while a spectrum is made, and shared after: a copy of a
  /// TSpectrum shares its arrays, where the C++'s copies them, so nothing writes to one
  /// that has been copied.
  TSpectrum = record
    Cos, Sin: TDoubleArray;
    function Harmonics: Integer;
  end;
  TSpectrumArray = array of TSpectrum;

  /// A cycle of a waveform for Spectrum::analyse: a phase 0..1 in, the sample out.
  ICycle = interface
    function At(Phase: Double): Double;
  end;

  /// waveforms::steps' generator: a position 0..1 through a sweep in, a spectrum out.
  ISpectrumAt = interface
    function At(T: Double): TSpectrum;
  end;

// Spectrum (int harmonics = 0)
function NewSpectrum(Harmonics: Integer = 0): TSpectrum;

function SpectrumFromShape(const Shape: IHarmonic; Harmonics: Integer): TSpectrum;

/// Measure one cycle of a waveform: `cycle` takes a phase 0..1 and returns the sample.
function SpectrumAnalyse(const Cycle: ICycle; Harmonics: Integer): TSpectrum;

function SpectrumBlend(const A, B: TSpectrum; Amount: Double): TSpectrum;
function SpectrumLimitedTo(const S: TSpectrum; Highest: Integer): TSpectrum;

// namespace modulation
function ModRing(const Carrier: IHarmonic; CarrierPartials: Integer; Ratio: Double; Harmonics: Integer): TSpectrum;
function ModFm(Ratio, Index: Double; Harmonics: Integer): TSpectrum;
function ModFm2(RatioA, IndexA, RatioB, IndexB: Double; Harmonics: Integer): TSpectrum;
function ModPulse(Duty: Double; Harmonics: Integer): TSpectrum;
function ModBent(const Shape: IHarmonic; ShapePartials: Integer; Amount: Double; Harmonics: Integer): TSpectrum;
function ModPhaseDistort(const Shape: IHarmonic; ShapePartials: Integer; Skew: Double; Harmonics: Integer): TSpectrum;

// --------------------------------------------------------------------- noise

type
  TNoiseColour = (ncWhite, ncPink, ncBrown);

// namespace noise
function NoiseSpectrum(Colour: TNoiseColour; Seed, Harmonics: Integer): TSpectrum;
function NoiseDusted(const Shape: IHarmonic; Colour: TNoiseColour; Amount: Double; Seed, Harmonics: Integer): TSpectrum;
function NoiseWander(Seed, Points: Integer; Colour: TNoiseColour; Length: Integer): TDoubleArray;

type
  /// How a wave is shaken as it is rendered: level, pitch, or both, by a wandering line
  /// that returns to its start so the loop still joins.
  TShake = record
    AmDepth: Double;      // 0.0
    PitchDepth: Double;   // 0.0
    Points: Integer;      // 24
    Colour: TNoiseColour; // pink
    Seed: Integer;        // 1

    procedure Init;       // the C++'s member initialisers
    function Any: Boolean;
  end;
  PShake = ^TShake;

// --------------------------------------------------------------------- waves

const
  RootHz   = 261.6255653;   // middle C, where every wave is written
  RootNote = 60;

// namespace waveforms
const
  PlainCycles = 8;

function WordsFor(Cycles: Integer; Rate, Hz: Double): Integer;
function HighestHarmonic(Rate, Hz: Double): Integer;

/// A wavetable swept through across the sample, as a round trip, so the loop joins.
function WaveRender(const Table: TSpectrumArray; Cycles: Integer; Rate, Hz: Double;
                    Shake: PShake = nil): TWords12; overload;

/// A plain wave: one shape, eight cycles, no movement.
function WaveRender(const Shape: IHarmonic; Rate, Hz: Double): TWords12; overload;

function WaveHiss(Words, Seed: Integer): TWords12;

/// Scale to fill the 12 bits and round.
function Quantise(const Wave: TDoubleArray): TWords12;

/// A table and its reverse, so a sweep returns to where it started.
function Mirror(const S: TSpectrumArray): TSpectrumArray;

/// `count` spectra at positions 0..1 through a sweep.
function Steps(Count: Integer; const At: ISpectrumAt): TSpectrumArray;

// --------------------------------------------------------------------- drums

type
  // namespace drums

  /// words, rate, generator -> the wave, before quantising
  TDrumVoice = function(N, Rate: Integer; var Rng: TNetRandom): TDoubleArray;

  TDrum = record
    Name: string;
    Key: Integer;          // the note it answers to, C3 = 60
    Rate: Integer;         // its own sample rate
    Seconds: Double;
    Loudness: Integer;     // the keygroup trim that balances the kit
    Vel: Integer;          // velocity -> loudness

    Voice: TDrumVoice;
  end;
  TDrumArray = array of TDrum;

/// The kit, laid out close to General MIDI.
function DrumKit: TDrumArray;

/// One drum, as the 12-bit words the disk carries. Seeded from its name.
function DrumRender(const Drum: TDrum): TWords12;

function DrumSeed(const Name: string): Integer;

implementation

// std::nearbyint: the C library's, as the C++ calls it. Half to even under the default
// rounding mode, for every double.
function crt_nearbyint(X: Double): Double; cdecl; external 'ucrtbase.dll' name 'nearbyint';

const
  Pi = 3.14159265358979323846;

// -------------------------------------------------------------- .NET's Random

//
// System.Random as the .NET Framework implements it: Knuth's subtractive generator with
// a 56-entry table. NextDouble() is InternalSample() / Int32.MaxValue. Written from the
// reference source, and checked by the synth cross-check: a drum rendered here hashes
// the same as the one the C# renders from the same seed.
//

// The generator relies on Int32 arithmetic wrapping, as .NET's unchecked context does.
{$IFOPT Q+}{$DEFINE S950SYNTH_Q}{$ENDIF}
{$IFOPT R+}{$DEFINE S950SYNTH_R}{$ENDIF}
{$Q-}{$R-}

procedure TNetRandom.Init(Seed: Integer);
const
  MBIG  = 2147483647;
  MSEED = 161803398;
var
  Subtraction, Mj, Mk, I, Ii, K: Integer;
begin
  FillChar(SeedArray, SizeOf(SeedArray), 0);

  if Seed = (-2147483647 - 1) then
    Subtraction := 2147483647
  else
    Subtraction := Abs(Seed);
  Mj := MSEED - Subtraction;
  SeedArray[55] := Mj;
  Mk := 1;

  for I := 1 to 54 do
  begin
    Ii := (21 * I) mod 55;
    SeedArray[Ii] := Mk;
    Mk := Mj - Mk;
    if Mk < 0 then Mk := Mk + MBIG;
    Mj := SeedArray[Ii];
  end;

  for K := 1 to 4 do
    for I := 1 to 55 do
    begin
      SeedArray[I] := SeedArray[I] - SeedArray[1 + (I + 30) mod 55];
      if SeedArray[I] < 0 then SeedArray[I] := SeedArray[I] + MBIG;
    end;

  INext  := 0;
  INextP := 21;
end;

function TNetRandom.InternalSample: Integer;
const
  MBIG = 2147483647;
var
  LocINext, LocINextP, RetVal: Integer;
begin
  LocINext := INext;
  LocINextP := INextP;
  Inc(LocINext);
  if LocINext >= 56 then LocINext := 1;
  Inc(LocINextP);
  if LocINextP >= 56 then LocINextP := 1;

  RetVal := SeedArray[LocINext] - SeedArray[LocINextP];
  if RetVal = MBIG then Dec(RetVal);
  if RetVal < 0 then RetVal := RetVal + MBIG;

  SeedArray[LocINext] := RetVal;
  INext  := LocINext;
  INextP := LocINextP;
  Result := RetVal;
end;

{$IFDEF S950SYNTH_Q}{$Q+}{$ENDIF}
{$IFDEF S950SYNTH_R}{$R+}{$ENDIF}

function TNetRandom.NextDouble: Double;
const
  Scale = 1.0 / 2147483647.0;
var
  Sample: Double;
begin
  Sample := InternalSample;
  Result := Sample * Scale;
end;

function NetRound(V: Double): Double;
begin
  // nearbyint rounds half to even under the default rounding mode, as Math.Round does.
  Result := crt_nearbyint(V);
end;

// ------------------------------------------------------------------ the shapes

type
  TSawShape = class(TInterfacedObject, IHarmonic)
    function Amp(N: Integer): Double;
  end;
  TSquareShape = class(TInterfacedObject, IHarmonic)
    function Amp(N: Integer): Double;
  end;
  TTriangleShape = class(TInterfacedObject, IHarmonic)
    function Amp(N: Integer): Double;
  end;
  TSineShape = class(TInterfacedObject, IHarmonic)
    function Amp(N: Integer): Double;
  end;
  TPulseShape = class(TInterfacedObject, IHarmonic)
    FDuty: Double;
    function Amp(N: Integer): Double;
  end;
  TOrganShape = class(TInterfacedObject, IHarmonic)
    function Amp(N: Integer): Double;
  end;
  THollowShape = class(TInterfacedObject, IHarmonic)
    function Amp(N: Integer): Double;
  end;
  TGlassShape = class(TInterfacedObject, IHarmonic)
    function Amp(N: Integer): Double;
  end;
  TBuzzShape = class(TInterfacedObject, IHarmonic)
    function Amp(N: Integer): Double;
  end;
  TMixShape = class(TInterfacedObject, IHarmonic)
    FA, FB: IHarmonic;
    FAmount: Double;
    function Amp(N: Integer): Double;
  end;
  TPartialsShape = class(TInterfacedObject, IHarmonic)
    FLevels: TDoubleArray;
    function Amp(N: Integer): Double;
  end;
  TLiftShape = class(TInterfacedObject, IHarmonic)
    FShape: IHarmonic;
    FAmount: Double;
    FWhich: TIntegerArray;
    function Amp(N: Integer): Double;
  end;
  TPlusShape = class(TInterfacedObject, IHarmonic)
    FA, FB: IHarmonic;
    FLevel: Double;
    function Amp(N: Integer): Double;
  end;

function TSawShape.Amp(N: Integer): Double;
begin
  Result := 1.0 / N;
end;

function TSquareShape.Amp(N: Integer): Double;
begin
  if N mod 2 = 1 then Result := 1.0 / N else Result := 0.0;
end;

function TTriangleShape.Amp(N: Integer): Double;
var
  Sign, NN: Double;
begin
  if N mod 2 = 1 then
  begin
    if ((N - 1) div 2) mod 2 = 0 then Sign := 1.0 else Sign := -1.0;
    NN := N;
    NN := N * NN;          // n * (double) n
    Result := Sign / NN;
  end
  else
    Result := 0.0;
end;

function TSineShape.Amp(N: Integer): Double;
begin
  if N = 1 then Result := 1.0 else Result := 0.0;
end;

function TPulseShape.Amp(N: Integer): Double;
begin
  Result := SinD(Pi * N * FDuty) / N;
end;

function TOrganShape.Amp(N: Integer): Double;
begin
  case N of
    1:  Result := 1.00;
    2:  Result := 0.60;
    3:  Result := 0.35;
    4:  Result := 0.45;
    6:  Result := 0.20;
    8:  Result := 0.25;
    12: Result := 0.12;
    16: Result := 0.10;
  else
    Result := 0.0;
  end;
end;

function THollowShape.Amp(N: Integer): Double;
var
  D: Double;
begin
  if N mod 2 = 1 then
  begin
    D := N;
    Result := 1.0 / (N * Sqrt(D));
  end
  else
    Result := 0.0;
end;

function TGlassShape.Amp(N: Integer): Double;
var
  D: Double;
begin
  if (N and (N - 1)) = 0 then
  begin
    D := N;
    Result := 1.0 / Sqrt(D);
  end
  else
    Result := 0.0;
end;

function TBuzzShape.Amp(N: Integer): Double;
var
  D: Double;
begin
  D := N;
  Result := 1.0 / Sqrt(D);
end;

function TMixShape.Amp(N: Integer): Double;
var
  A, B: Double;
begin
  A := FA.Amp(N);
  B := FB.Amp(N);
  Result := A * (1.0 - FAmount) + B * FAmount;
end;

function TPartialsShape.Amp(N: Integer): Double;
begin
  if (N >= 1) and (N <= Length(FLevels)) then Result := FLevels[N - 1] else Result := 0.0;
end;

function TLiftShape.Amp(N: Integer): Double;
var
  V: Double;
  W: Integer;
begin
  V := FShape.Amp(N);
  for W := 0 to High(FWhich) do
    if FWhich[W] = N then
    begin
      V := V + FAmount;
      Break;
    end;
  Result := V;
end;

function TPlusShape.Amp(N: Integer): Double;
var
  A, B: Double;
begin
  A := FA.Amp(N);
  B := FB.Amp(N);
  Result := A + B * FLevel;
end;

function ShapeSaw: IHarmonic;      begin Result := TSawShape.Create; end;
function ShapeSquare: IHarmonic;   begin Result := TSquareShape.Create; end;
function ShapeTriangle: IHarmonic; begin Result := TTriangleShape.Create; end;
function ShapeSine: IHarmonic;     begin Result := TSineShape.Create; end;

function ShapePulse(Duty: Double): IHarmonic;
var
  S: TPulseShape;
begin
  S := TPulseShape.Create;
  S.FDuty := Duty;
  Result := S;
end;

function ShapeOrgan: IHarmonic;  begin Result := TOrganShape.Create; end;
function ShapeHollow: IHarmonic; begin Result := THollowShape.Create; end;
function ShapeGlass: IHarmonic;  begin Result := TGlassShape.Create; end;
function ShapeBuzz: IHarmonic;   begin Result := TBuzzShape.Create; end;

function ShapeMix(const A, B: IHarmonic; Amount: Double): IHarmonic;
var
  S: TMixShape;
begin
  S := TMixShape.Create;
  S.FA := A;
  S.FB := B;
  S.FAmount := Amount;
  Result := S;
end;

function ShapePartials(const Levels: array of Double): IHarmonic;
var
  S: TPartialsShape;
  I: Integer;
begin
  S := TPartialsShape.Create;
  SetLength(S.FLevels, Length(Levels));
  for I := 0 to High(Levels) do S.FLevels[I] := Levels[I];
  Result := S;
end;

function ShapeLift(const Shape: IHarmonic; Amount: Double; const Which: array of Integer): IHarmonic;
var
  S: TLiftShape;
  I: Integer;
begin
  S := TLiftShape.Create;
  S.FShape := Shape;
  S.FAmount := Amount;
  SetLength(S.FWhich, Length(Which));
  for I := 0 to High(Which) do S.FWhich[I] := Which[I];
  Result := S;
end;

function ShapePlus(const A, B: IHarmonic; Level: Double): IHarmonic;
var
  S: TPlusShape;
begin
  S := TPlusShape.Create;
  S.FA := A;
  S.FB := B;
  S.FLevel := Level;
  Result := S;
end;

// ---------------------------------------------------------------- the spectrum

function TSpectrum.Harmonics: Integer;
begin
  Result := Length(Cos) - 1;
end;

function NewSpectrum(Harmonics: Integer): TSpectrum;
var
  I: Integer;
begin
  Result.Cos := nil;
  Result.Sin := nil;
  SetLength(Result.Cos, Harmonics + 1);
  SetLength(Result.Sin, Harmonics + 1);
  for I := 0 to Harmonics do
  begin
    Result.Cos[I] := 0.0;
    Result.Sin[I] := 0.0;
  end;
end;

function SpectrumFromShape(const Shape: IHarmonic; Harmonics: Integer): TSpectrum;
var
  N: Integer;
begin
  Result := NewSpectrum(Harmonics);
  for N := 1 to Harmonics do Result.Sin[N] := Shape.Amp(N);
end;

//
// Exact rather than approximate, because the signal is periodic and the window is a
// whole number of periods: the correlation over one period IS the Fourier coefficient.
// Oversampled sixteen points per harmonic, as the C# does.
//
function SpectrumAnalyse(const Cycle: ICycle; Harmonics: Integer): TSpectrum;
var
  StepCount, I, N: Integer;
  Sample: TDoubleArray;
  C, Sn, W, DSteps: Double;
begin
  StepCount := MaxI(2048, Harmonics * 16);
  Result := NewSpectrum(Harmonics);
  DSteps := StepCount;

  SetLength(Sample, StepCount);
  for I := 0 to StepCount - 1 do Sample[I] := Cycle.At(I / DSteps);

  for N := 1 to Harmonics do
  begin
    C := 0;
    Sn := 0;
    W := 2.0 * Pi * N / DSteps;

    for I := 0 to StepCount - 1 do
    begin
      C  := C + Sample[I] * CosD(W * I);
      Sn := Sn + Sample[I] * SinD(W * I);
    end;

    Result.Cos[N] := 2.0 * C / DSteps;
    Result.Sin[N] := 2.0 * Sn / DSteps;
  end;
end;

function SpectrumBlend(const A, B: TSpectrum; Amount: Double): TSpectrum;
var
  N, I: Integer;
  Ac, As_, Bc, Bs: Double;
begin
  N := MaxI(A.Harmonics, B.Harmonics);
  Result := NewSpectrum(N);

  for I := 1 to N do
  begin
    if I <= A.Harmonics then begin Ac := A.Cos[I]; As_ := A.Sin[I]; end else begin Ac := 0; As_ := 0; end;
    if I <= B.Harmonics then begin Bc := B.Cos[I]; Bs := B.Sin[I]; end else begin Bc := 0; Bs := 0; end;
    Result.Cos[I] := Ac * (1 - Amount) + Bc * Amount;
    Result.Sin[I] := As_ * (1 - Amount) + Bs * Amount;
  end;
end;

function SpectrumLimitedTo(const S: TSpectrum; Highest: Integer): TSpectrum;
var
  N: Integer;
begin
  Result := NewSpectrum(MinI(Highest, S.Harmonics));
  for N := 1 to Result.Harmonics do
  begin
    Result.Cos[N] := S.Cos[N];
    Result.Sin[N] := S.Sin[N];
  end;
end;

// namespace modulation

function Partial(Phase, Ratio: Double): Double;
begin
  Result := SinD(2.0 * Pi * Ratio * Phase);
end;

type
  TRingCycle = class(TInterfacedObject, ICycle)
    FCarrier: IHarmonic;
    FCarrierPartials: Integer;
    FRatio: Double;
    function At(Phase: Double): Double;
  end;
  TFmCycle = class(TInterfacedObject, ICycle)
    FRatio, FIndex: Double;
    function At(Phase: Double): Double;
  end;
  TFm2Cycle = class(TInterfacedObject, ICycle)
    FRatioA, FIndexA, FRatioB, FIndexB: Double;
    function At(Phase: Double): Double;
  end;
  TPulseCycle = class(TInterfacedObject, ICycle)
    FDuty: Double;
    function At(Phase: Double): Double;
  end;
  TBentCycle = class(TInterfacedObject, ICycle)
    FShape: IHarmonic;
    FShapePartials: Integer;
    FPower: Double;
    function At(Phase: Double): Double;
  end;
  TPhaseDistortCycle = class(TInterfacedObject, ICycle)
    FShape: IHarmonic;
    FShapePartials: Integer;
    FD: Double;
    function At(Phase: Double): Double;
  end;

function TRingCycle.At(Phase: Double): Double;
var
  C, Amp: Double;
  N: Integer;
begin
  C := 0;
  for N := 1 to FCarrierPartials do
  begin
    Amp := FCarrier.Amp(N);
    if Amp <> 0 then C := C + Amp * Partial(Phase, N);
  end;
  Result := C * Partial(Phase, FRatio);
end;

function TFmCycle.At(Phase: Double): Double;
begin
  Result := SinD(2.0 * Pi * Phase + FIndex * Partial(Phase, FRatio));
end;

function TFm2Cycle.At(Phase: Double): Double;
var
  A, B: Double;
begin
  A := Partial(Phase, FRatioA);
  B := Partial(Phase, FRatioB);
  Result := SinD(2.0 * Pi * Phase + FIndexA * A + FIndexB * B);
end;

function TPulseCycle.At(Phase: Double): Double;
begin
  if Phase < FDuty then Result := 1.0 else Result := -1.0;
end;

function TBentCycle.At(Phase: Double): Double;
var
  B, V, Amp: Double;
  N: Integer;
begin
  B := PowD(Phase, FPower);
  V := 0;
  for N := 1 to FShapePartials do
  begin
    Amp := FShape.Amp(N);
    if Amp <> 0 then V := V + Amp * Partial(B, N);
  end;
  Result := V;
end;

function TPhaseDistortCycle.At(Phase: Double): Double;
var
  P, V, Amp: Double;
  N: Integer;
begin
  if Phase < FD then P := 0.5 * (Phase / FD) else P := 0.5 + 0.5 * ((Phase - FD) / (1.0 - FD));
  V := 0;
  for N := 1 to FShapePartials do
  begin
    Amp := FShape.Amp(N);
    if Amp <> 0 then V := V + Amp * Partial(P, N);
  end;
  Result := V;
end;

function ModRing(const Carrier: IHarmonic; CarrierPartials: Integer; Ratio: Double; Harmonics: Integer): TSpectrum;
var
  C: TRingCycle;
  Hold: ICycle;       // the reference that counts: a const interface parameter takes none
begin
  C := TRingCycle.Create;
  C.FCarrier := Carrier;
  C.FCarrierPartials := CarrierPartials;
  C.FRatio := Ratio;
  Hold := C;
  Result := SpectrumAnalyse(Hold, Harmonics);
end;

function ModFm(Ratio, Index: Double; Harmonics: Integer): TSpectrum;
var
  C: TFmCycle;
  Hold: ICycle;       // the reference that counts: a const interface parameter takes none
begin
  C := TFmCycle.Create;
  C.FRatio := Ratio;
  C.FIndex := Index;
  Hold := C;
  Result := SpectrumAnalyse(Hold, Harmonics);
end;

function ModFm2(RatioA, IndexA, RatioB, IndexB: Double; Harmonics: Integer): TSpectrum;
var
  C: TFm2Cycle;
  Hold: ICycle;       // the reference that counts: a const interface parameter takes none
begin
  C := TFm2Cycle.Create;
  C.FRatioA := RatioA;
  C.FIndexA := IndexA;
  C.FRatioB := RatioB;
  C.FIndexB := IndexB;
  Hold := C;
  Result := SpectrumAnalyse(Hold, Harmonics);
end;

function ModPulse(Duty: Double; Harmonics: Integer): TSpectrum;
var
  C: TPulseCycle;
  Hold: ICycle;       // the reference that counts: a const interface parameter takes none
begin
  C := TPulseCycle.Create;
  C.FDuty := Duty;
  Hold := C;
  Result := SpectrumAnalyse(Hold, Harmonics);
end;

function ModBent(const Shape: IHarmonic; ShapePartials: Integer; Amount: Double; Harmonics: Integer): TSpectrum;
var
  C: TBentCycle;
  Hold: ICycle;       // the reference that counts: a const interface parameter takes none
begin
  C := TBentCycle.Create;
  C.FShape := Shape;
  C.FShapePartials := ShapePartials;
  C.FPower := Exp2D(Amount);    // std::pow (2.0, amount), which clang makes exp2
  Hold := C;
  Result := SpectrumAnalyse(Hold, Harmonics);
end;

function ModPhaseDistort(const Shape: IHarmonic; ShapePartials: Integer; Skew: Double; Harmonics: Integer): TSpectrum;
var
  C: TPhaseDistortCycle;
  Hold: ICycle;       // the reference that counts: a const interface parameter takes none
begin
  C := TPhaseDistortCycle.Create;
  C.FShape := Shape;
  C.FShapePartials := ShapePartials;
  if Skew < 0.04 then C.FD := 0.04
  else if Skew > 0.96 then C.FD := 0.96
  else C.FD := Skew;
  Hold := C;
  Result := SpectrumAnalyse(Hold, Harmonics);
end;

// --------------------------------------------------------------------- noise

function Slope(C: TNoiseColour; N: Integer): Double;
var
  D: Double;
begin
  case C of
    ncPink:
      begin
        D := N;
        Result := 1.0 / Sqrt(D);
      end;
    ncBrown: Result := 1.0 / N;
  else
    Result := 1.0;
  end;
end;

function NoiseSpectrum(Colour: TNoiseColour; Seed, Harmonics: Integer): TSpectrum;
var
  Rng: TNetRandom;
  N: Integer;
  Amp, Phase: Double;
begin
  Rng.Init(Seed);
  Result := NewSpectrum(Harmonics);

  for N := 1 to Harmonics do
  begin
    Amp   := Slope(Colour, N);
    Phase := Rng.NextDouble * 2.0 * Pi;
    Result.Cos[N] := Amp * CosD(Phase);
    Result.Sin[N] := Amp * SinD(Phase);
  end;
end;

function NoiseDusted(const Shape: IHarmonic; Colour: TNoiseColour; Amount: Double; Seed, Harmonics: Integer): TSpectrum;
var
  Clean, Dirt: TSpectrum;
  Reference: Double;
  N: Integer;
begin
  Clean := SpectrumFromShape(Shape, Harmonics);
  Dirt  := NoiseSpectrum(Colour, Seed, Harmonics);

  Reference := Abs(Clean.Sin[1]) + Abs(Clean.Cos[1]);
  if Reference <= 0 then Reference := 1;

  Result := NewSpectrum(Harmonics);
  for N := 1 to Harmonics do
  begin
    Result.Cos[N] := Clean.Cos[N] + Dirt.Cos[N] * Amount * Reference;
    Result.Sin[N] := Clean.Sin[N] + Dirt.Sin[N] * Amount * Reference;
  end;
end;

function NoiseWander(Seed, Points: Integer; Colour: TNoiseColour; Length: Integer): TDoubleArray;
var
  Rng: TNetRandom;
  Control: TDoubleArray;
  Walk, R, Peak, Pos, Frac, A, B, M, DLength: Double;
  I, At: Integer;
begin
  Rng.Init(Seed);
  SetLength(Control, Points);

  Walk := 0;
  for I := 0 to Points - 1 do
  begin
    R := Rng.NextDouble * 2.0 - 1.0;
    if Colour = ncBrown then begin Walk := Walk * 0.75 + R * 0.25; Control[I] := Walk; end
    else if Colour = ncPink then begin Walk := Walk * 0.45 + R * 0.55; Control[I] := Walk; end
    else Control[I] := R;
  end;

  Control[Points - 1] := Control[0];        // come home, or the loop steps

  Peak := 0;
  for I := 0 to Points - 1 do Peak := MaxD(Peak, Abs(Control[I]));
  if Peak > 0 then for I := 0 to Points - 1 do Control[I] := Control[I] / Peak;

  DLength := Length;
  Result := nil;
  SetLength(Result, Length);
  for I := 0 to Length - 1 do
  begin
    Pos := I / DLength * (Points - 1);
    At := Trunc(Pos);
    Frac := Pos - At;
    A := Control[At];
    B := Control[MinI(At + 1, Points - 1)];
    M := (1.0 - CosD(Frac * Pi)) * 0.5;
    Result[I] := A * (1.0 - M) + B * M;
  end;
end;

procedure TShake.Init;
begin
  AmDepth    := 0.0;
  PitchDepth := 0.0;
  Points     := 24;
  Colour     := ncPink;
  Seed       := 1;
end;

function TShake.Any: Boolean;
begin
  Result := (AmDepth > 0) or (PitchDepth > 0);
end;

// --------------------------------------------------------------------- waves

// namespace waveforms

function WordsFor(Cycles: Integer; Rate, Hz: Double): Integer;
begin
  Result := Trunc(NetRound(Cycles * Rate / Hz));
end;

function HighestHarmonic(Rate, Hz: Double): Integer;
var
  H: Integer;
begin
  H := Trunc((Rate / 2.0) / Hz);
  if H < 1 then Result := 1 else Result := H;
end;

/// Harmonic n at position t through the table, with wraparound and smoothstep legs.
procedure TableAt(const Table: TSpectrumArray; N: Integer; T: Double; out C, S: Double);
var
  Pos, Frac, M, Ac, As_, Bc, Bs: Double;
  Ix, Size: Integer;
begin
  if Length(Table) = 1 then
  begin
    if N <= Table[0].Harmonics then begin C := Table[0].Cos[N]; S := Table[0].Sin[N]; end
    else begin C := 0; S := 0; end;
    Exit;
  end;

  Size := Length(Table);
  Pos  := T * Size;
  Ix   := Trunc(Pos);
  Frac := Pos - Ix;

  // a = table[ix % size], b = table[(ix + 1) % size]
  M := Frac * Frac * (3.0 - 2.0 * Frac);

  with Table[Ix mod Size] do
    if N <= Harmonics then begin Ac := Cos[N]; As_ := Sin[N]; end else begin Ac := 0; As_ := 0; end;
  with Table[(Ix + 1) mod Size] do
    if N <= Harmonics then begin Bc := Cos[N]; Bs := Sin[N]; end else begin Bc := 0; Bs := 0; end;

  C := Ac * (1 - M) + Bc * M;
  S := As_ * (1 - M) + Bs * M;
end;

function WaveRender(const Table: TSpectrumArray; Cycles: Integer; Rate, Hz: Double;
                    Shake: PShake): TWords12;
var
  Words, Highest, N, I, K: Integer;
  Drift, Level, Wave: TDoubleArray;
  BaseStep, C, S, Phase, Angle, G, DWords: Double;
  Used: Boolean;
begin
  Words   := WordsFor(Cycles, Rate, Hz);
  Highest := HighestHarmonic(Rate, Hz);

  Drift := nil;
  Level := nil;
  if (Shake <> nil) and (Shake^.PitchDepth > 0) then Drift := NoiseWander(Shake^.Seed, Shake^.Points, Shake^.Colour, Words);
  if (Shake <> nil) and (Shake^.AmDepth > 0)    then Level := NoiseWander(Shake^.Seed + 7919, Shake^.Points, Shake^.Colour, Words);

  SetLength(Wave, Words);
  for I := 0 to Words - 1 do Wave[I] := 0.0;
  DWords := Words;
  BaseStep := 2.0 * Pi * Cycles / DWords;

  for N := 1 to Highest do
  begin
    Used := False;
    for K := 0 to High(Table) do
      if (N <= Table[K].Harmonics) and ((Table[K].Cos[N] <> 0.0) or (Table[K].Sin[N] <> 0.0)) then
      begin
        Used := True;
        Break;
      end;
    if not Used then Continue;

    for I := 0 to Words - 1 do
    begin
      TableAt(Table, N, I / DWords, C, S);
      if (C = 0.0) and (S = 0.0) then Continue;

      Phase := BaseStep * I;
      if Drift <> nil then Phase := Phase + Shake^.PitchDepth * Drift[I];

      Angle := N * Phase;
      Wave[I] := Wave[I] + (C * CosD(Angle) + S * SinD(Angle));
    end;
  end;

  if Level <> nil then
    for I := 0 to Words - 1 do
    begin
      G := 1.0 + Shake^.AmDepth * Level[I];
      if G < 0 then Wave[I] := Wave[I] * 0 else Wave[I] := Wave[I] * G;
    end;

  Result := Quantise(Wave);
end;

function WaveRender(const Shape: IHarmonic; Rate, Hz: Double): TWords12;
var
  One: TSpectrumArray;
begin
  SetLength(One, 1);
  One[0] := SpectrumFromShape(Shape, HighestHarmonic(Rate, Hz));
  Result := WaveRender(One, PlainCycles, Rate, Hz);
end;

function WaveHiss(Words, Seed: Integer): TWords12;
var
  Rng: TNetRandom;
  Wave: TDoubleArray;
  Last, White, T, DFade: Double;
  I, Fade: Integer;
begin
  Rng.Init(Seed);
  SetLength(Wave, Words);

  Last := 0;
  for I := 0 to Words - 1 do
  begin
    White := Rng.NextDouble * 2.0 - 1.0;
    Last := 0.65 * White + 0.35 * Last;
    Wave[I] := Last;
  end;

  Fade := MinI(64, Words div 8);
  DFade := Fade;
  for I := 0 to Fade - 1 do
  begin
    T := I / DFade;
    Wave[I] := Wave[I] * T + Wave[Words - Fade + I] * (1 - T);
  end;

  Result := Quantise(Wave);
end;

function Quantise(const Wave: TDoubleArray): TWords12;
var
  Peak, Scale: Double;
  I, V: Integer;
begin
  Peak := 0;
  for I := 0 to High(Wave) do Peak := MaxD(Peak, Abs(Wave[I]));
  if Peak <= 0 then Peak := 1;

  Scale := 2047.0 / Peak;
  Result := nil;
  SetLength(Result, Length(Wave));

  for I := 0 to High(Wave) do
  begin
    V := Trunc(NetRound(Wave[I] * Scale));
    if V > 2047 then V := 2047 else if V < -2048 then V := -2048;
    Result[I] := V;
  end;
end;

function Mirror(const S: TSpectrumArray): TSpectrumArray;
var
  N, I, K: Integer;
begin
  Result := Copy(S);
  if Length(S) < 3 then Exit;
  N := Length(S);
  SetLength(Result, N + (N - 2));
  K := N;
  for I := N - 2 downto 1 do
  begin
    Result[K] := S[I];
    Inc(K);
  end;
end;

function Steps(Count: Integer; const At: ISpectrumAt): TSpectrumArray;
var
  I: Integer;
  D: Double;
begin
  Result := nil;
  SetLength(Result, Count);
  D := Count - 1;
  for I := 0 to Count - 1 do Result[I] := At.At(I / D);
end;

// --------------------------------------------------------------------- drums

// namespace drums

const
  FadeIn = 0.0002;
  Tail   = 0.25;

  Metal808: array[0..5] of Double  = (1, 1.4471, 1.6170, 1.9265, 2.5028, 2.6637);
  MetalWide: array[0..6] of Double = (1, 1.3733, 1.8371, 2.2471, 2.9531, 3.4813, 4.2129);
  MetalBell: array[0..3] of Double = (1, 1.4771, 2.1834, 3.0129);

type
  TWave = TDoubleArray;

function NewWave(N: Integer): TWave;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, N);
  for I := 0 to N - 1 do Result[I] := 0.0;
end;

// ------------------------------------------------------------ the workshop

function Sweep(N, Rate: Integer; StartHz, EndHz, PitchTau, AmpTau: Double): TWave;
var
  Phase, T, Hz, DRate: Double;
  I: Integer;
begin
  Result := NewWave(N);
  DRate := Rate;
  Phase := 0;
  for I := 0 to N - 1 do
  begin
    T  := I / DRate;
    Hz := EndHz + (StartHz - EndHz) * ExpD(-T / PitchTau);
    Phase := Phase + 2 * Pi * Hz / DRate;
    Result[I] := SinD(Phase) * ExpD(-T / AmpTau);
  end;
end;

/// A square summed from its odd harmonics below Nyquist, each at a random phase.
procedure Square(var Wave: TWave; N, Rate: Integer; Hz: Double; var Rng: TNetRandom);
var
  Limit, Amp, Step, Phase, R, DRate: Double;
  K, I: Integer;
begin
  DRate := Rate;
  Limit := DRate * 0.46;
  K := 1;
  while K * Hz < Limit do
  begin
    Amp   := 1.0 / K;
    Step  := 2 * Pi * K * Hz / DRate;
    R     := Rng.NextDouble;
    Phase := Pi * (2 * R - 1);
    for I := 0 to N - 1 do Wave[I] := Wave[I] + Amp * SinD(Step * I + Phase);
    Inc(K, 2);
  end;
end;

function White(N: Integer; var Rng: TNetRandom): TWave;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, N);
  for I := 0 to N - 1 do Result[I] := 2 * Rng.NextDouble - 1;
end;

function HighPass(const X: TWave; Hz: Double; Rate: Integer): TWave;
var
  A, Px, Py, DRate: Double;
  I: Integer;
begin
  DRate := Rate;
  A := ExpD(-2 * Pi * Hz / DRate);
  Result := nil;
  SetLength(Result, Length(X));
  Px := 0;
  Py := 0;
  for I := 0 to High(X) do
  begin
    Py := A * (Py + X[I] - Px);
    Px := X[I];
    Result[I] := Py;
  end;
end;

function LowPass(const X: TWave; Hz: Double; Rate: Integer): TWave;
var
  A, Y, DRate: Double;
  I: Integer;
begin
  DRate := Rate;
  A := 1 - ExpD(-2 * Pi * Hz / DRate);
  Result := nil;
  SetLength(Result, Length(X));
  Y := 0;
  for I := 0 to High(X) do
  begin
    Y := Y + A * (X[I] - Y);
    Result[I] := Y;
  end;
end;

/// The Chamberlin state variable, band output. Cutoff clamped below a sixth of the rate.
function BandPass(const X: TWave; Hz, Q: Double; Rate: Integer): TWave;
var
  F, Damp, Low, Band, High_, DRate: Double;
  I: Integer;
begin
  DRate := Rate;
  F    := 2 * SinD(Pi * MinD(Hz, DRate / 6.0) / DRate);
  Damp := MinD(2.0, 1 / MaxD(0.25, Q));
  Result := nil;
  SetLength(Result, Length(X));
  Low := 0;
  Band := 0;
  for I := 0 to High(X) do
  begin
    High_ := X[I] - Low - Damp * Band;
    Band := Band + F * High_;
    Low  := Low + F * Band;
    Result[I] := Band;
  end;
end;

function Norm(const X: TWave): TWave;
var
  Peak: Double;
  I: Integer;
begin
  Result := Copy(X);
  Peak := 0;
  for I := 0 to High(Result) do Peak := MaxD(Peak, Abs(Result[I]));
  if Peak > 0 then for I := 0 to High(Result) do Result[I] := Result[I] / Peak;
end;

procedure Saturate(var X: TWave; Drive: Double);
var
  K: Double;
  I: Integer;
begin
  K := TanhD(Drive);
  for I := 0 to High(X) do X[I] := TanhD(Drive * X[I]) / K;
end;

// -------------------------------------------------------------- the voices

function Kick(N, Rate: Integer; var Rng: TNetRandom; StartHz, EndHz, PitchTau,
              AmpTau, Click, ClickTau, Drive: Double): TWave;
var
  Hiss: TWave;
  I: Integer;
  DRate: Double;
begin
  Result := Sweep(N, Rate, StartHz, EndHz, PitchTau, AmpTau);
  Saturate(Result, Drive);

  if Click > 0 then
  begin
    DRate := Rate;
    Hiss := Norm(HighPass(White(N, Rng), 2500, Rate));
    for I := 0 to N - 1 do
      Result[I] := Result[I] + Click * Hiss[I] * ExpD(-(I / DRate) / ClickTau);
  end;
end;

function Tom(N, Rate: Integer; var Rng: TNetRandom; StartHz, EndHz, PitchTau,
             AmpTau, NoiseAmt: Double): TWave;
var
  Skin: TWave;
  I: Integer;
  T, DRate: Double;
begin
  Result := Sweep(N, Rate, StartHz, EndHz, PitchTau, AmpTau);
  Skin := Norm(LowPass(HighPass(White(N, Rng), 300, Rate), 4000, Rate));

  DRate := Rate;
  for I := 0 to N - 1 do
  begin
    T := I / DRate;
    Result[I] := (1 - NoiseAmt) * Result[I]
               + NoiseAmt * Skin[I] * ExpD(-T / (AmpTau * 0.35));
  end;
end;

function Snare(N, Rate: Integer; var Rng: TNetRandom; Hz1, Hz2, Bend, BodyTau,
               Mix, NoiseHz, NoiseQ, NoiseTau, Crack: Double): TWave;
var
  Body, W, Rattle, Edge: TWave;
  P1, P2, T, Up, DRate: Double;
  I: Integer;
begin
  DRate := Rate;
  SetLength(Body, N);
  P1 := 0;
  P2 := 0;
  for I := 0 to N - 1 do
  begin
    T  := I / DRate;
    Up := 1 + Bend * ExpD(-T / 0.020);
    P1 := P1 + 2 * Pi * Hz1 * Up / DRate;
    P2 := P2 + 2 * Pi * Hz2 * Up / DRate;
    Body[I] := (SinD(P1) + 0.7 * SinD(P2)) * ExpD(-T / BodyTau);
  end;
  Body := Norm(Body);

  W      := White(N, Rng);
  Rattle := Norm(HighPass(BandPass(W, NoiseHz, NoiseQ, Rate), 400, Rate));
  Edge   := Norm(HighPass(W, 3500, Rate));

  Result := nil;
  SetLength(Result, N);
  for I := 0 to N - 1 do
  begin
    T := I / DRate;
    Result[I] := (1 - Mix) * Body[I]
               + Mix * Rattle[I] * ExpD(-T / NoiseTau)
               + Crack * Edge[I] * ExpD(-T / 0.0025);
  end;
end;

function Clap(N, Rate: Integer; var Rng: TNetRandom; TapTau, TailFrom, TailTau,
              TailLevel, Hz, Q: Double): TWave;
const
  Taps: array[0..2] of Double = (0, 0.010, 0.021);
var
  Hiss: TWave;
  I, J: Integer;
  T, Gate, DRate: Double;
begin
  Hiss := Norm(HighPass(BandPass(White(N, Rng), Hz, Q, Rate), 500, Rate));
  Result := nil;
  SetLength(Result, N);

  DRate := Rate;
  for I := 0 to N - 1 do
  begin
    T := I / DRate;
    Gate := 0;
    for J := 0 to High(Taps) do if T >= Taps[J] then Gate := Gate + ExpD(-(T - Taps[J]) / TapTau);
    if T >= TailFrom then Gate := Gate + TailLevel * ExpD(-(T - TailFrom) / TailTau);
    Result[I] := Hiss[I] * Gate;
  end;
end;

function Metal(N, Rate: Integer; var Rng: TNetRandom; Bas: Double; const Ratios: array of Double;
               Hp, Tau, Snap, SnapTau: Double;
               Wash: Double = 0; WashHp: Double = 0; WashTau: Double = 1;
               Ping: Double = 0; PingHz: Double = 0; PingTau: Double = 1; Swell: Double = 0): TWave;
var
  Bank, Air: TWave;
  I, R: Integer;
  T, Opening, Env, DRate: Double;
begin
  Bank := NewWave(N);
  for R := 0 to High(Ratios) do Square(Bank, N, Rate, Bas * Ratios[R], Rng);
  Bank := Norm(HighPass(HighPass(Bank, Hp, Rate), Hp, Rate));

  Air := nil;
  if Wash > 0 then Air := Norm(HighPass(HighPass(White(N, Rng), WashHp, Rate), WashHp, Rate));

  DRate := Rate;
  Result := nil;
  SetLength(Result, N);
  for I := 0 to N - 1 do
  begin
    T := I / DRate;
    if Swell > 0 then Opening := 1 - ExpD(-T / Swell) else Opening := 1;
    Env := ExpD(-T / Tau) + Snap * ExpD(-T / SnapTau);

    Result[I] := Bank[I] * Env * Opening;
    if Air <> nil then Result[I] := Result[I] + Wash * Air[I] * ExpD(-T / WashTau) * Opening;
    if Ping > 0 then
      Result[I] := Result[I] + Ping * SinD(2 * Pi * PingHz * I / DRate) * ExpD(-T / PingTau);
  end;
end;

function Rim(N, Rate: Integer; var Rng: TNetRandom; PingHz, PingTau, ThumpHz,
             ThumpTau, Click: Double): TWave;
var
  Hiss: TWave;
  I: Integer;
  T, DRate: Double;
begin
  DRate := Rate;
  Result := nil;
  SetLength(Result, N);
  for I := 0 to N - 1 do
  begin
    T := I / DRate;
    Result[I] := SinD(2 * Pi * PingHz * I / DRate) * ExpD(-T / PingTau)
               + 0.8 * SinD(2 * Pi * ThumpHz * I / DRate) * ExpD(-T / ThumpTau);
  end;

  Hiss := Norm(HighPass(White(N, Rng), 3000, Rate));
  for I := 0 to N - 1 do
    Result[I] := Result[I] + Click * Hiss[I] * ExpD(-(I / DRate) / 0.0012);
end;

function Clave(N, Rate: Integer; Hz, Tau: Double): TWave;
var
  I: Integer;
  DRate: Double;
begin
  DRate := Rate;
  Result := nil;
  SetLength(Result, N);
  for I := 0 to N - 1 do
    Result[I] := SinD(2 * Pi * Hz * I / DRate) * ExpD(-(I / DRate) / Tau);
end;

// ------------------------------------------------------------------ the kit

// The kit's voices: the C++'s capture-free lambdas, one function each.
function VoiceSnare3(N, R: Integer; var G: TNetRandom): TDoubleArray;    begin Result := Snare(N, R, G, 262, 391, 0.50, 0.055, 0.60, 2700, 1.0, 0.065, 0.68); end;
function VoiceKick3(N, R: Integer; var G: TNetRandom): TDoubleArray;     begin Result := Kick(N, R, G, 240, 62, 0.007, 0.11, 0.28, 0.0015, 3.6); end;
function VoiceKick2(N, R: Integer; var G: TNetRandom): TDoubleArray;     begin Result := Kick(N, R, G, 118, 42, 0.034, 0.60, 0.08, 0.0020, 2.0); end;
function VoiceKick1(N, R: Integer; var G: TNetRandom): TDoubleArray;     begin Result := Kick(N, R, G, 190, 49, 0.014, 0.24, 0.16, 0.0018, 2.8); end;
function VoiceRimshot(N, R: Integer; var G: TNetRandom): TDoubleArray;   begin Result := Rim(N, R, G, 1700, 0.012, 420, 0.020, 0.30); end;
function VoiceSnare1(N, R: Integer; var G: TNetRandom): TDoubleArray;    begin Result := Snare(N, R, G, 188, 278, 0.35, 0.105, 0.48, 1900, 0.9, 0.120, 0.58); end;
function VoiceClap(N, R: Integer; var G: TNetRandom): TDoubleArray;      begin Result := Clap(N, R, G, 0.0035, 0.031, 0.110, 0.62, 1100, 1.1); end;
function VoiceSnare2(N, R: Integer; var G: TNetRandom): TDoubleArray;    begin Result := Snare(N, R, G, 152, 229, 0.30, 0.190, 0.42, 1400, 0.8, 0.170, 0.46); end;
function VoiceTomLo(N, R: Integer; var G: TNetRandom): TDoubleArray;     begin Result := Tom(N, R, G, 140, 88, 0.070, 0.34, 0.09); end;
function VoiceHatClosed(N, R: Integer; var G: TNetRandom): TDoubleArray; begin Result := Metal(N, R, G, 205.3, Metal808, 5600, 0.026, 1.0, 0.0025); end;
function VoiceTomMid(N, R: Integer; var G: TNetRandom): TDoubleArray;    begin Result := Tom(N, R, G, 198, 128, 0.060, 0.28, 0.09); end;
function VoiceHatPedal(N, R: Integer; var G: TNetRandom): TDoubleArray;  begin Result := Metal(N, R, G, 205.3, Metal808, 5000, 0.050, 0.9, 0.0030); end;
function VoiceTomHi(N, R: Integer; var G: TNetRandom): TDoubleArray;     begin Result := Tom(N, R, G, 278, 182, 0.050, 0.22, 0.09); end;
function VoiceHatOpen(N, R: Integer; var G: TNetRandom): TDoubleArray;   begin Result := Metal(N, R, G, 205.3, Metal808, 5400, 0.340, 1.0, 0.0080); end;
function VoiceCrash(N, R: Integer; var G: TNetRandom): TDoubleArray;     begin Result := Metal(N, R, G, 148.0, MetalWide, 3800, 1.10, 0.7, 0.0120, 0.55, 5000, 1.40, 0, 0, 1, 0.006); end;
function VoiceRide(N, R: Integer; var G: TNetRandom): TDoubleArray;      begin Result := Metal(N, R, G, 166.0, MetalWide, 3000, 0.900, 1.3, 0.0050, 0.16, 6000, 0.500, 0.45, 3520, 0.060); end;
function VoiceRideBell(N, R: Integer; var G: TNetRandom): TDoubleArray;  begin Result := Metal(N, R, G, 262.0, MetalBell, 2400, 0.620, 0.9, 0.0040, 0, 0, 1, 0.60, 2620, 0.220); end;
function VoiceClave(N, R: Integer; var G: TNetRandom): TDoubleArray;     begin Result := Clave(N, R, 2500, 0.030); end;

function MakeDrum(const Name: string; Key, Rate: Integer; Seconds: Double; Loudness, Vel: Integer;
                  Voice: TDrumVoice): TDrum;
begin
  Result.Name := Name;
  Result.Key := Key;
  Result.Rate := Rate;
  Result.Seconds := Seconds;
  Result.Loudness := Loudness;
  Result.Vel := Vel;
  Result.Voice := Voice;
end;

function DrumKit: TDrumArray;
begin
  Result := nil;
  SetLength(Result, 18);
  Result[0]  := MakeDrum('SNARE 3', 33, 24000, 0.20, -4, 40, VoiceSnare3);
  Result[1]  := MakeDrum('KICK 3',  34, 20000, 0.25, -1, 25, VoiceKick3);
  Result[2]  := MakeDrum('KICK 2',  35, 20000, 0.90,  0, 20, VoiceKick2);
  Result[3]  := MakeDrum('KICK 1',  36, 20000, 0.45,  0, 25, VoiceKick1);
  Result[4]  := MakeDrum('RIMSHOT', 37, 24000, 0.09, -6, 45, VoiceRimshot);
  Result[5]  := MakeDrum('SNARE 1', 38, 24000, 0.32, -2, 40, VoiceSnare1);
  Result[6]  := MakeDrum('CLAP',    39, 24000, 0.42, -4, 45, VoiceClap);
  Result[7]  := MakeDrum('SNARE 2', 40, 24000, 0.42, -2, 40, VoiceSnare2);
  Result[8]  := MakeDrum('TOM LO',  41, 20000, 0.60, -3, 35, VoiceTomLo);
  Result[9]  := MakeDrum('HAT CLOSED', 42, 32000, 0.08, -9, 55, VoiceHatClosed);
  Result[10] := MakeDrum('TOM MID', 43, 20000, 0.50, -3, 35, VoiceTomMid);
  Result[11] := MakeDrum('HAT PEDAL', 44, 32000, 0.14, -10, 55, VoiceHatPedal);
  Result[12] := MakeDrum('TOM HI',  45, 20000, 0.42, -3, 35, VoiceTomHi);
  Result[13] := MakeDrum('HAT OPEN', 46, 32000, 0.75, -10, 50, VoiceHatOpen);
  Result[14] := MakeDrum('CRASH',   49, 32000, 2.60, -8, 50, VoiceCrash);
  Result[15] := MakeDrum('RIDE',    51, 32000, 1.80, -10, 50, VoiceRide);
  Result[16] := MakeDrum('RIDE BELL', 53, 32000, 1.40, -11, 45, VoiceRideBell);
  Result[17] := MakeDrum('CLAVE',   75, 24000, 0.13, -11, 40, VoiceClave);
end;

{$IFOPT Q+}{$DEFINE S950SYNTH_Q2}{$ENDIF}
{$IFOPT R+}{$DEFINE S950SYNTH_R2}{$ENDIF}
{$Q-}{$R-}

function DrumSeed(const Name: string): Integer;
var
  H: Cardinal;
  I: Integer;
begin
  // FNV-1a over the name's bytes, in unsigned arithmetic that wraps
  H := 2166136261;
  for I := 1 to Length(Name) do
  begin
    H := H xor (Cardinal(Ord(Name[I])) and $FF);
    H := Cardinal(H * Cardinal(16777619));
  end;
  Result := Integer(H and $7FFFFFFF);
end;

{$IFDEF S950SYNTH_Q2}{$Q+}{$ENDIF}
{$IFDEF S950SYNTH_R2}{$R+}{$ENDIF}

function DrumRender(const Drum: TDrum): TWords12;
var
  N, Rise, Fall, I: Integer;
  Rng: TNetRandom;
  Wave: TWave;
  DRise, DFall1: Double;
begin
  N := Trunc(NetRound(Drum.Seconds * Drum.Rate)) and (not 1);
  Rng.Init(DrumSeed(Drum.Name));
  Wave := Drum.Voice(N, Drum.Rate, Rng);

  Rise := MaxI(1, Trunc(NetRound(FadeIn * Drum.Rate)));
  Fall := MaxI(2, Trunc(NetRound(Tail * N)));

  DRise := Rise;
  I := 0;
  while (I < Rise) and (I < N) do
  begin
    Wave[I] := Wave[I] * (I / DRise);
    Inc(I);
  end;
  DFall1 := Fall - 1.0;
  for I := 0 to Fall - 1 do
    Wave[N - Fall + I] := Wave[N - Fall + I] * (0.5 * (1 + CosD(Pi * I / DFall1)));

  Result := Quantise(Wave);
end;

end.
