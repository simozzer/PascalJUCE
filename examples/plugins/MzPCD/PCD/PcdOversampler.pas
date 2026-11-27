// MzPCD - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// PcdOversampler - the Object Pascal port of pcd::Oversampler (Source/PCD/Oversampler.h).
// In double throughout, as the C++, the C library's sin and cos (PcdMath).

unit PcdOversampler;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$MINFPCONSTPREC 64}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

const
  PcdOsTaps = 63;
  // how many samples, at the original rate, it delays a signal by going up and back down
  PcdOsLatency = (PcdOsTaps - 1) div 2;

type
  TPcdOsTaps = array[0..PcdOsTaps - 1] of Double;

  // a delay line kept twice over, so the taps read it without wrapping
  TPcdOsLine = record
    V: array[0..PcdOsTaps * 2 - 1] of Double;
    Pos: Integer;
    procedure Reset;
    function Push(X: Double; const H: TPcdOsTaps): Double;
  end;

  //
  // Twice the sample rate, and back, for the clipper: its harmonics would otherwise fold
  // back down as aliases. One 63-tap low-pass at a quarter of the doubled rate - a
  // half-band, Blackman-windowed - does both jobs: going up, it takes away the image the
  // doubling makes; coming down, everything above the original Nyquist.
  //
  // A record: call Init once (the C++ constructor).
  //
  TPcdOversampler = record
  private
    FH: TPcdOsTaps;
    FUp, FDown: TPcdOsLine;
  public
    procedure Init;
    procedure Reset;
    // one sample in, the two at twice the rate out: the sample and a zero, filtered, doubled
    procedure Upsample(X: Double; out A, B: Double);
    // the two samples at twice the rate in, one out
    function Downsample(A, B: Double): Double;
    property Taps: TPcdOsTaps read FH;
  end;

implementation

uses
  PcdMath;

const
  PiD: Double = 3.14159265358979323846;
  W0: Double = 0.42;
  W2: Double = 0.08;

procedure TPcdOsLine.Reset;
begin
  FillChar(V, SizeOf(V), 0);
  Pos := 0;
end;

function TPcdOsLine.Push(X: Double; const H: TPcdOsTaps): Double;
var
  I: Integer;
  Y: Double;
begin
  if Pos = 0 then
    Pos := PcdOsTaps - 1
  else
    Pos := Pos - 1;
  V[Pos] := X;
  V[Pos + PcdOsTaps] := X;
  Y := 0.0;
  for I := 0 to PcdOsTaps - 1 do
    Y := Y + H[I] * V[Pos + I];
  Result := Y;
end;

procedure TPcdOversampler.Init;
var
  Mid, I, K: Integer;
  Sum, Sinc, W, D: Double;
begin
  Mid := PcdOsTaps div 2;
  Sum := 0.0;
  for I := 0 to PcdOsTaps - 1 do
  begin
    K := I - Mid;
    if K = 0 then
      Sinc := 0.5
    else
    begin
      D := K;
      Sinc := SinD(PiD * D * 0.5) / (PiD * D);
    end;
    D := I;
    W := W0 - 0.5 * CosD(2.0 * PiD * D / (PcdOsTaps - 1)) + W2 * CosD(4.0 * PiD * D / (PcdOsTaps - 1));
    FH[I] := Sinc * W;
    Sum := Sum + FH[I];
  end;
  for I := 0 to PcdOsTaps - 1 do
    FH[I] := FH[I] / Sum;   // unity at DC
  Reset;
end;

procedure TPcdOversampler.Reset;
begin
  FUp.Reset;
  FDown.Reset;
end;

procedure TPcdOversampler.Upsample(X: Double; out A, B: Double);
begin
  A := 2.0 * FUp.Push(X, FH);
  B := 2.0 * FUp.Push(0.0, FH);
end;

function TPcdOversampler.Downsample(A, B: Double): Double;
begin
  FDown.Push(A, FH);
  Result := FDown.Push(B, FH);
end;

end.
