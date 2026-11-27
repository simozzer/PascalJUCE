// Mz303 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of source/TB303/Vcf.h.

unit Tb303Vcf;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

type
  //
  // THE VCF: the 303's diode ladder
  //
  // Where a Moog ladder is four transistor stages each buffered from the next, the 303's is a
  // stack of diode pairs with a capacitor across each rung and a differential pair at the
  // bottom driving it. A conducting diode is a resistor whose value the cutoff current sets,
  // so the ladder is four RC sections in a chain - and nothing buffers one from the next: each
  // capacitor is charged by the rung below and drained by the rung above. That loading is
  // what gives the 303 its sound. The poles spread out instead of sitting together, so the
  // slope is gentler than a 24 dB filter's just past cutoff, and the resonant peak is broader
  // and sits lower than the cutoff frequency.
  //
  // The top capacitor is half the size of the others, which is the usual reading of the
  // circuit (and the reason it is often mistaken for an 18 dB filter). Each rung's current is
  // tanh of the voltage across it, the bottom pair's most of all - the filter saturates on the
  // difference between what comes in and what the ladder has got to.
  //
  // Resonance feeds the top of the ladder back to the other side of the bottom pair through a
  // coupling capacitor, so the feedback is highpassed: the lowest notes get little of it, and
  // keep their level as resonance rises where a plain ladder would lose it. Together with the
  // spread poles, it is also why the 303 squelches but barely whistles on its own.
  //
  // Solved as one zero-delay system, trapezoidally: the rungs are a tridiagonal system, solved
  // for the input and the feedback separately so the loop can be closed exactly - no unit
  // delay anywhere, so cutoff and resonance stay where they are put to the top of the range.
  // The nonlinearities are linearised around the previous sample's operating point, which at
  // 4x oversampling is indistinguishable from iterating to convergence.
  //
  TVcf = record
  private
    FS: array[0..3] of Single;
    FDiff: array[0..3] of Single;
    FHpS, FHpG: Single;
  public
    procedure Init;
    procedure SetSampleRate(Rate: Single);
    procedure Reset;
    // G = tan(pi * fc / fs) for the rungs' RC; K = feedback.
    function Process(X, G, K: Single): Single;
  end;

implementation

uses
  Tb303Dsp;

const
  // How hard the bottom pair and the diode rungs saturate, for a signal at the level the
  // engine drives them; the top capacitor as a fraction of the others, inverted (its RC
  // runs twice as fast); the feedback's coupling corner. Reasoned from the circuit, not
  // measured.
  BottomDrive = 1;
  RungDrive = 0.5;
  TopCap = 2;
  FeedbackHighpassHz = 90;
  InitialHpG: Single = 0.01;

procedure TVcf.Init;
begin
  Reset;
  FHpG := InitialHpG;
end;

procedure TVcf.SetSampleRate(Rate: Single);
var
  A: Single;
begin
  A := PiF * FeedbackHighpassHz;   // (float) pi * 90.0f, in float
  FHpG := TanF(A / Rate);
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
  FHpS := 0;
end;

function TVcf.Process(X, G, K: Single): Single;
var
  C: array[0..3] of Single;
  Lower, Main, Upper, Rs, Ru, Up, Y: array[0..3] of Single;
  C4, M, HpA, HpB, U, Hp, Lp: Single;
  I: Integer;
begin
  // each rung's conductance, at the point it is working
  C[0] := G * SoftClipGain(FDiff[0] * BottomDrive);
  for I := 1 to 3 do
    C[I] := G * SoftClipGain(FDiff[I] * RungDrive);
  C4 := C[3] * TopCap;

  // the tridiagonal system: lower, main, upper, and the right-hand side as a part fixed by
  // the state plus a part per unit of the bottom pair's input u
  Lower[0] := 0;       Lower[1] := -C[1];        Lower[2] := -C[2];        Lower[3] := -C4;
  Main[0] := 1 + C[0] + C[1];
  Main[1] := 1 + C[1] + C[2];
  Main[2] := 1 + C[2] + C[3];
  Main[3] := 1 + C4;
  Upper[0] := -C[1];   Upper[1] := -C[2];        Upper[2] := -C[3];        Upper[3] := 0;
  for I := 0 to 3 do
    Rs[I] := FS[I];
  Ru[0] := C[0];
  Ru[1] := 0;
  Ru[2] := 0;
  Ru[3] := 0;

  // Thomas, forward
  Up[0] := Upper[0] / Main[0];
  Rs[0] := Rs[0] / Main[0];
  Ru[0] := Ru[0] / Main[0];
  for I := 1 to 3 do
  begin
    M := 1 / (Main[I] - Lower[I] * Up[I - 1]);
    Up[I] := Upper[I] * M;
    Rs[I] := (Rs[I] - Lower[I] * Rs[I - 1]) * M;
    Ru[I] := (Ru[I] - Lower[I] * Ru[I - 1]) * M;
  end;

  // and back
  for I := 2 downto 0 do
  begin
    Rs[I] := Rs[I] - Up[I] * Rs[I + 1];
    Ru[I] := Ru[I] - Up[I] * Ru[I + 1];
  end;

  // y4 = rs[3] + ru[3] * u, and u = x - k * highpass(y4): close the loop
  HpA := 1 / (1 + FHpG);
  HpB := -FHpS / (1 + FHpG);
  U := (X - K * (HpA * Rs[3] + HpB)) / (1 + K * HpA * Ru[3]);

  for I := 0 to 3 do
    Y[I] := Rs[I] + Ru[I] * U;

  FDiff[0] := U - Y[0];
  for I := 1 to 3 do
    FDiff[I] := Y[I - 1] - Y[I];

  for I := 0 to 3 do
    FS[I] := 2 * Y[I] - FS[I];

  // the feedback's coupling capacitor: a one-pole highpass, as the lowpass it leaves
  Hp := HpA * Y[3] + HpB;
  Lp := Y[3] - Hp;
  FHpS := 2 * Lp - FHpS;

  Result := Y[3];
end;

end.
