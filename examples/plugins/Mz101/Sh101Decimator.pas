// Mz101 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/SH101/Decimator.h.

unit Sh101Decimator;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

const
  MaxOversampling = 4;
  MaxTaps = 64 * MaxOversampling;

type
  //
  // Back down from the oversampled rate to the host's.
  //
  // The voice runs at 2x or 4x so the filter's and VCA's saturation, and the oscillator's
  // audio-rate FM from the noise LFO, have room above the audio band to put their harmonics.
  // This removes them: a Kaiser-windowed sinc, computed only at the output samples.
  //
  // The stopband begins not at the output's Nyquist but where anything left would alias down
  // to above 20 kHz - a little aliasing into the last two kilohertz before Nyquist is
  // inaudible, and it buys a flat response to well above 18 kHz from a filter of modest length.
  //
  // Fixed-size arrays rather than the C++ vectors: nothing is allocated, ever.
  //
  TDecimator = record
  private
    FFactor, FTaps, FPos: Integer;
    FH: array[0..MaxTaps - 1] of Single;
    FBuf: array[0..2 * MaxTaps - 1] of Single;   // each sample twice, so a window never wraps
    class function BesselI0(X: Double): Double; static;
  public
    procedure Init;
    procedure Prepare(Oversampling: Integer; HostRate: Single);
    procedure Push(X: Single); inline;
    function Output: Single;
  end;

implementation

uses
  Sh101Dsp;

procedure TDecimator.Init;
begin
  FFactor := 1;
  FTaps := 1;
  FPos := 0;
  FillChar(FH, SizeOf(FH), 0);
  FillChar(FBuf, SizeOf(FBuf), 0);
  FH[0] := 1;
end;

procedure TDecimator.Prepare(Oversampling: Integer; HostRate: Single);
var
  N: Integer;
  Rate, StopEdge, Beta, Transition, Fc, Mid, T, Sinc, R, W, Sum, Nd, Taper: Double;
begin
  if Oversampling < 1 then
    Oversampling := 1;
  if Oversampling > MaxOversampling then
    Oversampling := MaxOversampling;

  FFactor := Oversampling;
  if FFactor = 1 then
    FTaps := 1
  else
    FTaps := 64 * FFactor;

  FillChar(FH, SizeOf(FH), 0);
  FillChar(FBuf, SizeOf(FBuf), 0);
  FPos := 0;

  if FFactor = 1 then
  begin
    FH[0] := 1;
    Exit;
  end;

  // Double from here, as in the C++: Rate makes the divisions double ones.
  Rate := HostRate;
  StopEdge := 1.0 - 20000.0 / Rate;
  if StopEdge < 0.5 then
    StopEdge := 0.5;
  StopEdge := StopEdge / FFactor;
  Beta := 9.0;                                       // about 90 dB
  Transition := (90.0 - 7.95) / (14.36 * FTaps);
  Fc := StopEdge - Transition * 0.5;
  Mid := FTaps - 1;
  Mid := Mid * 0.5;

  Sum := 0;
  for N := 0 to FTaps - 1 do
  begin
    Nd := N;
    T := Nd - Mid;
    if T = 0 then
      Sinc := 2 * Fc
    else
      Sinc := Sin(2 * Pi64 * Fc * T) / (Pi64 * T);
    R := 2.0 * Nd / (FTaps - 1) - 1.0;
    Taper := 1.0 - R * R;
    if Taper < 0 then
      Taper := 0;
    W := BesselI0(Beta * Sqrt(Taper)) / BesselI0(Beta);
    FH[N] := Sinc * W;
    Sum := Sum + Sinc * W;
  end;

  for N := 0 to FTaps - 1 do
    FH[N] := FH[N] / Sum;
end;

procedure TDecimator.Push(X: Single);
begin
  FBuf[FPos] := X;
  FBuf[FPos + FTaps] := X;
  Inc(FPos);
  if FPos = FTaps then
    FPos := 0;
end;

function TDecimator.Output: Single;
var
  I: Integer;
  Acc: Single;
begin
  Acc := 0;
  for I := 0 to FTaps - 1 do
    Acc := Acc + FH[I] * FBuf[FPos + I];
  Result := Acc;
end;

class function TDecimator.BesselI0(X: Double): Double;
var
  K: Integer;
  Sum, Term, Q: Double;
begin
  Sum := 1;
  Term := 1;
  for K := 1 to 63 do
  begin
    Q := X / (2.0 * K);
    Term := Term * (Q * Q);
    Sum := Sum + Term;
    if Term < 1e-14 * Sum then
      Break;
  end;
  Result := Sum;
end;

end.
