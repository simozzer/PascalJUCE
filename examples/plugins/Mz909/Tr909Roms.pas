// Mz909 - an emulation of the TR-909 Rhythm Composer
// Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/TR909/Roms.cpp (and the ROM accessors of Rom.h).
//
// The ROMs' contents: stand-ins for the 909's recordings of its hihats, crash and ride,
// generated here and stored as the 909 stores its own, 6-bit.
//
// Each is made from nothing but white noise and sine waves, then shaped to a measured
// description of the sound (Tr909RomProfiles):
//
//  1. The source: white noise, with a sine at each of the profile's steady pitches, each as
//     far above the noise as the profile says, early, middle and late.
//  2. Shaping: a short-time Fourier transform, frames of 512 a quarter-frame apart. In each
//     frame the energy in each of 18 bands is set to the profile's level at that moment,
//     with the gain eased between band centres so no band edge is heard. Peaks and noise in
//     a band are scaled together, so each pitch keeps its standing above the noise.
//  3. The onset, a millisecond at a time over the first 40 ms, set to the profile's.
//  4. The last stretch faded to nothing, then 6 bits.
//
// The noise is seeded, so every build makes the same ROMs, as a ROM should be - and this
// port makes the same ROMs as the C++, byte for byte: the same float arithmetic in the
// same order, the same C library functions (see Tr909Dsp), and the FFT's complex products
// written out as the C++ standard library's std::complex<float> computes them.

unit Tr909Roms;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  Tr909Rom;

// Built on first use, the same on every run - a ROM does not change between hits. The
// first call builds all four (the C++ Engine's constructor asks for them all at once); it
// is safe from any thread, and does it once.
function ClosedHatRom: PRom;
function OpenHatRom: PRom;
function CrashRom: PRom;
function RideRom: PRom;

implementation

uses
  SyncObjs, Tr909Dsp, Tr909RomProfiles;

type
  TComplex = record
    Re, Im: Single;
  end;
  TBins = array of TComplex;
  TFloats = array of Single;

const
  RomClock = 48000;   // 48000.0f: exact

  BandEdges: array[0..RomBandCount] of Single = (0, 200, 400, 630, 1000, 1250, 1600, 2000,
    2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000, 24000);

  // the three moments a partial's standing above the noise is given at
  PartialTimes: array[0..2] of Single = (0.09, 0.375, 0.7);

  Frame = 512;
  Hop = Frame div 4;

  Ln2Median: Single = 0.6931;
  OneThousandth: Single = 1.0e-3;
  Tiny: Single = 1.0e-12;
  TinyRms: Single = 1.0e-9;
  Shrink = 1.5;   // 1.5f: exact

// std::complex<float> multiplication, as the C++ library does it (no fused multiply-add).
procedure MulInPlace(var A: TComplex; const B: TComplex); inline;
var
  T: Single;
begin
  T := A.Re * B.Re - A.Im * B.Im;
  A.Im := A.Re * B.Im + A.Im * B.Re;
  A.Re := T;
end;

procedure Fft(var A: TBins; Inverse: Boolean);
var
  N, I, J, Bit, Len, K, Half: Integer;
  Angle, LenF, NF: Single;
  Step, W, U, V: TComplex;
  Tmp: TComplex;
begin
  N := Length(A);
  J := 0;
  for I := 1 to N - 1 do
  begin
    Bit := N shr 1;
    while (J and Bit) <> 0 do
    begin
      J := J xor Bit;
      Bit := Bit shr 1;
    end;
    J := J xor Bit;
    if I < J then
    begin
      Tmp := A[I];
      A[I] := A[J];
      A[J] := Tmp;
    end;
  end;
  Len := 2;
  while Len <= N do
  begin
    LenF := Len;
    if Inverse then
      Angle := 2 * PiF / LenF
    else
      Angle := -2 * PiF / LenF;
    Step.Re := CosF(Angle);
    Step.Im := SinF(Angle);
    Half := Len div 2;
    I := 0;
    while I < N do
    begin
      W.Re := 1;
      W.Im := 0;
      for K := 0 to Half - 1 do
      begin
        U := A[I + K];
        V := A[I + K + Half];
        MulInPlace(V, W);
        A[I + K].Re := U.Re + V.Re;
        A[I + K].Im := U.Im + V.Im;
        A[I + K + Half].Re := U.Re - V.Re;
        A[I + K + Half].Im := U.Im - V.Im;
        MulInPlace(W, Step);
      end;
      Inc(I, Len);
    end;
    Len := Len shl 1;
  end;
  if Inverse then
  begin
    NF := N;
    for I := 0 to N - 1 do
    begin
      A[I].Re := A[I].Re / NF;
      A[I].Im := A[I].Im / NF;
    end;
  end;
end;

// Linear between points, held beyond the ends.
function Between(const Xs, Ys: array of Single; Count: Integer; X: Single): Single;
var
  I: Integer;
begin
  if X <= Xs[0] then
    Exit(Ys[0]);
  for I := 1 to Count - 1 do
    if X < Xs[I] then
      Exit(Ys[I - 1] + (Ys[I] - Ys[I - 1]) * (X - Xs[I - 1]) / (Xs[I] - Xs[I - 1]));
  Result := Ys[Count - 1];
end;

// The profile's level in one band at time t, in dB.
function LevelAt(const P: TRomProfile; Band: Integer; T: Single): Single;
var
  I: Integer;
  A, B: Single;
begin
  if T <= P.Times^[0] then
    Exit(P.Levels^[0][Band]);
  for I := 1 to P.TimeCount - 1 do
    if T < P.Times^[I] then
    begin
      A := P.Levels^[I - 1][Band];
      B := P.Levels^[I][Band];
      Exit(A + (B - A) * (T - P.Times^[I - 1]) / (P.Times^[I] - P.Times^[I - 1]));
    end;
  Result := P.Levels^[P.TimeCount - 1][Band];
end;

// 1. white noise and the partials
function Source(const P: TRomProfile; Length_: Integer; var Rng: TRandom): TFloats;
var
  I, N: Integer;
  IncF, Above, Amp, NF, Tf: Single;
  Inc_, Phase: Double;
begin
  // In a Hann-windowed transform of M points, a sine of amplitude A peaks at A^2 M / 6 times
  // unit white noise's mean bin power, and the median is ln 2 of the mean. The profiles give
  // peak over median, measured with M = 8192.
  Result := nil;
  SetLength(Result, Length_);
  for I := 0 to Length_ - 1 do
    Result[I] := Rng.White;

  for I := 0 to P.PartialCount - 1 do
  begin
    IncF := P.Partials^[I].Hz / RomClock;   // float / float, then widened, as the C++
    Inc_ := IncF;
    Phase := Rng.Uniform;
    for N := 0 to Length_ - 1 do
    begin
      NF := N;
      Tf := NF / RomClock;
      Above := Between(PartialTimes, P.Partials^[I].Above, 3, Tf);
      Amp := Sqrt(6 * Ln2Median * PowF(10, Above / 10) / 8192);
      Tf := SinD(2.0 * Pi64 * Phase);
      Result[N] := Result[N] + Amp * Tf;
      Phase := Phase + Inc_;
      if Phase >= 1.0 then
        Phase := Phase - 1.0;
    end;
  end;
end;

// 2. each frame's bands to the profile's levels
function Shape(const P: TRomProfile; const X: TFloats): TFloats;
var
  Length_, I, B, K, S: Integer;
  Window: array[0..Frame - 1] of Single;
  WindowEnergy, F, T, Inside, Target, Have, Lf, G, IF_, SF: Single;
  Centre, LogGain, Energy, Count: array[0..RomBandCount - 1] of Single;
  BandOf: array[0..Frame div 2] of Integer;
  In_, Out_: TFloats;
  Bins: TBins;
begin
  Length_ := Length(X);
  Result := nil;

  WindowEnergy := 0;
  for I := 0 to Frame - 1 do
  begin
    IF_ := I;
    Window[I] := 0.5 - 0.5 * CosF(2 * PiF * IF_ / Frame);
    WindowEnergy := WindowEnergy + Window[I] * Window[I];
  end;

  // each bin's place between the band centres, on a log scale
  for B := 0 to RomBandCount - 1 do
    if B = 0 then
      Centre[B] := LogF(100)
    else
      Centre[B] := LogF(Sqrt(BandEdges[B] * BandEdges[B + 1]));
  for K := 0 to Frame div 2 do
  begin
    F := K;
    F := F * RomClock / Frame;
    B := 0;
    while (B + 1 < RomBandCount) and (F >= BandEdges[B + 1]) do
      Inc(B);
    BandOf[K] := B;
  end;

  // padded a frame each side, so the first and last samples are shaped like the rest
  SetLength(In_, Length_ + 2 * Frame);
  SetLength(Out_, Length_ + 2 * Frame);
  for I := 0 to High(In_) do
  begin
    In_[I] := 0;
    Out_[I] := 0;
  end;
  for I := 0 to Length_ - 1 do
    In_[Frame + I] := X[I];

  SetLength(Bins, Frame);
  S := 0;
  while S + Frame <= Length(In_) do
  begin
    for I := 0 to Frame - 1 do
    begin
      Bins[I].Re := In_[S + I] * Window[I];
      Bins[I].Im := 0;
    end;
    Fft(Bins, False);

    for B := 0 to RomBandCount - 1 do
    begin
      Energy[B] := 0;
      Count[B] := 0;
    end;
    for K := 1 to Frame div 2 do
    begin
      // std::norm
      Energy[BandOf[K]] := Energy[BandOf[K]]
        + (Bins[K].Re * Bins[K].Re + Bins[K].Im * Bins[K].Im) / WindowEnergy;
      Count[BandOf[K]] := Count[BandOf[K]] + 1;
    end;

    // A frame reaching back before the hit holds only part of the sound, and is asked for
    // only that part of the level - as the profile's own first frames were measured, half
    // in the silence before the hit. Asked for all of it, the sliver would be boosted.
    SF := S;
    T := (SF + Frame / 2 - Frame) / RomClock;   // frame / 2.0f = 256: exact
    Inside := 0;
    for I := 0 to Frame - 1 do
      if S + I >= Frame then
        Inside := Inside + Window[I] * Window[I];
    Inside := Inside / WindowEnergy;
    if Inside < OneThousandth then
    begin
      Inc(S, Hop);
      Continue;
    end;

    for B := 0 to RomBandCount - 1 do
    begin
      Target := Inside * PowF(10, LevelAt(P, B, T) / 10);
      Have := MaxF(Energy[B] / MaxF(Count[B], 1), Tiny);
      LogGain[B] := 0.5 * LogF(Target / Have);
    end;

    Bins[0].Re := 0;
    Bins[0].Im := 0;
    for K := 1 to Frame div 2 do
    begin
      F := K;
      Lf := LogF(F * RomClock / Frame);
      G := ExpF(Between(Centre, LogGain, RomBandCount, Lf));
      Bins[K].Re := Bins[K].Re * G;
      Bins[K].Im := Bins[K].Im * G;
      if K < Frame div 2 then
      begin
        Bins[Frame - K].Re := Bins[Frame - K].Re * G;
        Bins[Frame - K].Im := Bins[Frame - K].Im * G;
      end;
    end;

    Fft(Bins, True);
    for I := 0 to Frame - 1 do
      Out_[S + I] := Out_[S + I] + Bins[I].Re * Window[I] / Shrink;

    Inc(S, Hop);
  end;

  SetLength(Result, Length_);
  for I := 0 to Length_ - 1 do
    Result[I] := Out_[Frame + I];
end;

// The root mean square of X[A..B-1], summed in double, as the C++ lambda.
function Rms(const X: TFloats; A, B: Integer): Single;
var
  I: Integer;
  S, V, Nd: Double;
begin
  S := 0;
  for I := A to B - 1 do
  begin
    V := X[I];
    S := S + V * V;
  end;
  Nd := B - A;
  Result := Sqrt(S / Nd);
end;

// 3. the first 40 ms, a millisecond at a time
procedure SetOnset(const P: TRomProfile; var X: TFloats);
var
  Ms, M, N: Integer;
  Ref, Want, G, Blend, MF, MsF, NF: Single;
  Gain, At: array[0..OnsetMs - 1] of Single;
begin
  Ms := 48;   // (size_t) (romClock / 1000.0f)
  MsF := Ms;

  Ref := Rms(X, 30 * Ms, 40 * Ms);
  for M := 0 to OnsetMs - 1 do
  begin
    Want := Ref * PowF(10, P.Onset^[M] / 20);
    Gain[M] := Clamp(Want / MaxF(Rms(X, M * Ms, (M + 1) * Ms), TinyRms), 0, 4);
    MF := M;
    At[M] := (MF + 0.5) * MsF;
  end;
  for N := 0 to OnsetMs * Ms - 1 do
  begin
    // eased into the unchanged sound over the last few milliseconds
    NF := N;
    G := Between(At, Gain, OnsetMs, NF);
    Blend := Clamp((NF - 35 * MsF) / (5 * MsF), 0, 1);
    X[N] := X[N] * (G + (1 - G) * Blend);
  end;
end;

// 4. faded out, then into 6 bits with the loudest moment at full scale
procedure Store(var X: TFloats; var Rom: TRom);
var
  Fade, I, Size, Q: Integer;
  Top, IF_, FadeF: Single;
begin
  Size := Length(X);
  Fade := Size div 20;
  FadeF := Fade;
  for I := 0 to Fade - 1 do
  begin
    IF_ := I;
    X[Size - Fade + I] := X[Size - Fade + I] * (0.5 + 0.5 * CosF(PiF * IF_ / FadeF));
  end;

  Top := 0;
  for I := 0 to Size - 1 do
    Top := MaxF(Top, Abs(X[I]));

  Rom.Clock := RomClock;
  SetLength(Rom.Data, Size);
  for I := 0 to Size - 1 do
  begin
    Q := LRound(X[I] / Top * 31);
    if Q < -32 then
      Q := -32
    else if Q > 31 then
      Q := 31;
    Rom.Data[I] := Q;
  end;
end;

procedure Build(const P: TRomProfile; Seed: UInt32; var Rom: TRom);
var
  Rng: TRandom;
  Len: Integer;
  Secs: Single;
  X, Shaped: TFloats;
begin
  Rng.Init(Seed);
  Secs := P.Seconds * RomClock;
  Len := Trunc(Secs);   // (size_t) (p.seconds * romClock)
  X := Source(P, Len, Rng);
  Shaped := Shape(P, X);
  X := nil;
  SetOnset(P, Shaped);
  Store(Shaped, Rom);
end;

var
  Lock: TCriticalSection;
  Built: Boolean;   // set (under the lock) once all four are
  Roms: array[0..3] of TRom;

procedure EnsureBuilt;
begin
  Lock.Enter;
  try
    if not Built then
    begin
      Build(ClosedHatProfile^, $909A0001, Roms[0]);
      Build(OpenHatProfile^, $909A0004, Roms[1]);
      Build(CrashProfile^, $909A0002, Roms[2]);
      Build(RideProfile^, $909A0003, Roms[3]);
      Built := True;
    end;
  finally
    Lock.Leave;
  end;
end;

function ClosedHatRom: PRom;
begin
  EnsureBuilt;
  Result := @Roms[0];
end;

function OpenHatRom: PRom;
begin
  EnsureBuilt;
  Result := @Roms[1];
end;

function CrashRom: PRom;
begin
  EnsureBuilt;
  Result := @Roms[2];
end;

function RideRom: PRom;
begin
  EnsureBuilt;
  Result := @Roms[3];
end;

initialization
  Lock := TCriticalSection.Create;
finalization
  Lock.Free;
end.
