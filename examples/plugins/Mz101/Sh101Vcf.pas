// Mz101 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/SH101/Vcf.h.

unit Sh101Vcf;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

type
  //
  // THE VCF: an IR3109 with the 101's resonance circuit round it
  //
  // The IR3109 is four OTAs, each wired as a buffered integrator with its output fed back to
  // its own inverting input - four identical one-pole lowpasses, sharing one exponential
  // current source for cutoff. An OTA's output current is tanh of its differential input, so
  // each stage is
  //
  //      dy/dt = wc * tanh(in - y)
  //
  // which is NOT the Moog ladder's tanh(in) - tanh(y): the OTA saturates on the DIFFERENCE,
  // so it softens most when the input moves fast against a slow output - bright edges into a
  // low cutoff - and leaves gentle material almost clean.
  //
  // The chip has no resonance of its own. On the 101 a transistor phase splitter takes the
  // fourth stage's output: the inverted side goes back to the input through the resonance
  // pot, and the non-inverted side is added to the OUTPUT. So turning up resonance also
  // raises the level going on to the VCA, which is why a 101 keeps more of its bottom end at
  // high resonance than a plain four-pole would. A pair of diodes to ground limits the
  // feedback, which is what sets the amplitude it self-oscillates at.
  //
  // Solved as four trapezoidal (TPT) one-poles with the feedback loop solved instantaneously -
  // no unit delay in the loop, so cutoff and resonance stay where they are put right up to the
  // top of the range. The nonlinearities are linearised around the previous sample's operating
  // point, which at 4x oversampling is indistinguishable from iterating to convergence.
  //
  TVcf = record
  private
    FS: array[0..3] of Single;
    FDiff: array[0..3] of Single;
    FY4: Single;
  public
    procedure Reset;
    // G = tan(pi * fc / fs); K = feedback, self-oscillation from about 4.
    function Process(X, G, K: Single): Single;
  end;

implementation

uses
  Sh101Dsp;

const
  // The clipping diodes: soft, knee at about the level the feedback runs at near
  // self-oscillation.
  DiodeDrive: Single = 1.6;
  // the phase splitter's forward half
  ForwardHalf = 0.5;

var
  DiodeScale: Single;   // 1 / DiodeDrive, worked out in single precision as the C++ does

function Diode(Y: Single): Single; inline;
begin
  Result := SoftClip(Y * DiodeDrive) * DiodeScale;
end;

function DiodeGain(Y: Single): Single; inline;
begin
  Result := SoftClipGain(Y * DiodeDrive);
end;

procedure TVcf.Reset;
var
  I: Integer;
begin
  for I := 0 to 3 do
  begin
    FS[I] := 0;
    FDiff[I] := 0;
  end;
  FY4 := 0;
end;

function TVcf.Process(X, G, K: Single): Single;
var
  GS, SS: array[0..3] of Single;
  I: Integer;
  Gi, Gt, St, Dg, Est, U, Y: Single;
begin
  for I := 0 to 3 do
  begin
    Gi := G * SoftClipGain(FDiff[I]);
    GS[I] := Gi / (1 + Gi);
    SS[I] := FS[I] / (1 + Gi);
  end;

  // the whole cascade as y4 = Gt * u + St
  Gt := GS[0] * GS[1] * GS[2] * GS[3];
  St := ((SS[0] * GS[1] + SS[1]) * GS[2] + SS[2]) * GS[3] + SS[3];

  // solve the loop u = x - k * diode(y4) for this sample
  Dg := DiodeGain(FY4);
  Est := (Gt * X + St) / (1 + K * Dg * Gt);
  U := X - K * Diode(Est);

  for I := 0 to 3 do
  begin
    Y := GS[I] * U + SS[I];
    FDiff[I] := U - Y;
    FS[I] := 2 * Y - FS[I];
    U := Y;
  end;

  FY4 := U;

  Result := FY4 + ForwardHalf * K * Diode(FY4);
end;

initialization
  DiodeScale := 1 / DiodeDrive;
end.
