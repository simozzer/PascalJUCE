// Mz950 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Plugin/Source/S950/Filter.h. Renders the same doubles as the C++,
// bit for bit; see S950Math for how.

unit S950Filter;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$MINFPCONSTPREC 64}   // a real literal is a double, as in C++ (1.0 would otherwise be a Single)
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  S950Math;

const
  FilterBiquads = 2;

type
  //
  // The S950's low-pass: 6th-order Butterworth, 36 dB per octave - and, turned up, a
  // resonance the machine never had, up to and past self-oscillation.
  //
  // Three second-order sections in cascade, at the three Q values that make six poles
  // Butterworth rather than three identical resonant sections. Those are exact rather than
  // measured: only where the cutoff sits in hertz had to be found by recording (see Cal).
  //
  // Two of the sections, Q 0.52 and 0.71, are RBJ biquads, a straight port of
  // AkaiS950Engine/Filter.cs. The third, Q 1.93 - the one that already peaks - is a
  // state-variable filter instead (Zavalishin's topology-preserving form), because that is
  // the one resonance works on, and a biquad can only ring, never sustain. The SVF's
  // response is the same bilinear, prewarped second-order low-pass as the biquad it
  // replaced, so at zero resonance the whole filter is the S950's to within rounding.
  //
  // It runs FIRST in the cascade. For a linear filter the order is immaterial; with the
  // resonant stage's level control at work, whatever little it adds above the cutoff gets
  // the two sections after it, 24 dB an octave more, before it leaves.
  //
  // The coefficients are recomputed every few dozen samples, far finer than the ear
  // resolves, and the state is kept across a retune so a moving cutoff does not click.
  //
  TButterworth = record
  private
    B0, B1, B2: array[0..FilterBiquads - 1] of Double;
    A1, A2: array[0..FilterBiquads - 1] of Double;
    X1, X2: array[0..FilterBiquads - 1] of Double;
    Y1, Y2: array[0..FilterBiquads - 1] of Double;

    // the resonant stage: its coefficient, damping, level control, input trim, and state
    G, K0, Beta, Drive, Follow: Double;
    Ic1, Ic2, Band, Power: Double;

    //
    // The Q of each section, which is what makes the cascade Butterworth: 0.52, 0.71 and
    // 1.93 for k = 0, 1, 2.
    //
    // Worked out on the spot rather than held in a static table: three cosines, only
    // when a cutoff changes, is nothing beside the filtering itself - and a function
    // needs no thought about when a static gets initialised.
    //
    class function Q(K: Integer): Double; static;
  public
    // The C++'s default member initialisers.
    procedure Init;

    // Forget the past - called when a voice starts, so no note begins mid-tail.
    procedure Reset;

    //
    // Retune to a cutoff in hertz. State is kept, so there is no click.
    //
    // `resonance`, 0..1, is not the S950's - its filter has none - and 0 is exactly the
    // machine. Up to Threshold it raises the resonant stage's Q from its Butterworth 1.93
    // to QTop, exponentially so the knob's travel is even to the ear. Past it the damping
    // keeps falling, through zero to KMin, and the filter oscillates on its own: a sine at
    // the cutoff, so it follows the Filter knob, the envelope and velocity.
    //
    // What holds that oscillation at a level rather than letting it grow without end is
    // damping that rises with the stage's own band-pass power - see process(). The same
    // term tames loud peaks below the threshold, so a hot sample through a sharp
    // resonance is squeezed back rather than left to clip.
    //
    procedure SetCutoff(Fc, Fs: Double; Resonance: Double = 0.0);

    // One sample through all three sections.
    function Process(X: Double): Double;

    // Where on the 0..1 knob the filter starts to sing by itself - k0 crossing zero.
    class function OscillationStarts: Double; static;
  end;

implementation

const
  // How far up the knob is resonance, and the Q it has reached there. Past it is
  // self-oscillation.
  Threshold = 0.9;
  QTop      = 40.0;

  // The damping at full resonance: how hard the oscillation is driven.
  KMin = -0.1;

  // A ceiling on the saturating damping, so a huge transient cannot ask for more
  // than the stage can be solved for in one step.
  KMax = 4.0;

  //
  // How loud a full-resonance oscillation is at the filter's output, before the VCA:
  // -14 dB, so eight voices of it at the default gain stay short of clipping.
  //
  // The two plain sections pass q(0) * q(1) = 0.366 at the cutoff, so the resonant
  // stage has to oscillate at OscLevel / 0.366, and Beta follows from the balance in
  // process() with k0 at KMin.
  //
  OscLevel  = 0.2;
  PlainGain = 0.51763809020504 * 0.70710678118655;
  StageAmp  = OscLevel / PlainGain;
  BetaFull  = 2.0 * (-KMin) / (StageAmp * StageAmp);   // the C++'s Beta

  // How many cycles of the cutoff the level follower averages over.
  FollowCycles = 2.0;
  FollowMin    = 0.01;

{ TButterworth }

class function TButterworth.Q(K: Integer): Double;
begin
  Result := 1.0 / (2.0 * CosD(Pi64 * (2 * K + 1) / 12.0));
end;

procedure TButterworth.Init;
begin
  FillChar(Self, SizeOf(Self), 0);
  K0 := 1.0;
  Beta := 0.0;
  Drive := 1.0;
  Follow := 0.0;
end;

procedure TButterworth.Reset;
var
  S: Integer;
begin
  for S := 0 to FilterBiquads - 1 do
  begin
    X1[S] := 0.0; X2[S] := 0.0; Y1[S] := 0.0; Y2[S] := 0.0;
  end;

  Ic1 := 0.0; Ic2 := 0.0; Band := 0.0; Power := 0.0;
end;

procedure TButterworth.SetCutoff(Fc, Fs: Double; Resonance: Double);
var
  Nyq, F, W, Cw, Sw, Al, A0, Res, Q2, QNow, Seconds: Double;
  S: Integer;
begin
  Nyq := Fs * 0.5;
  if Fc < 10 then
    F := 10
  else if Fc > Nyq * 0.995 then
    F := Nyq * 0.995
  else
    F := Fc;

  W  := 2.0 * Pi64 * F / Fs;
  Cw := CosD(W);
  Sw := SinD(W);

  // --- the two plain sections
  for S := 0 to FilterBiquads - 1 do
  begin
    Al := Sw / (2.0 * Q(S));
    A0 := 1.0 + Al;

    B0[S] := (1.0 - Cw) / 2.0 / A0;
    B1[S] := (1.0 - Cw) / A0;
    B2[S] := B0[S];
    A1[S] := -2.0 * Cw / A0;
    A2[S] := (1.0 - Al) / A0;
  end;

  // --- the resonant one
  if Resonance < 0 then
    Res := 0
  else if Resonance > 1 then
    Res := 1
  else
    Res := Resonance;
  Q2 := Q(FilterBiquads);

  G := TanD(Pi64 * F / Fs);

  QNow := Q2 * PowD(QTop / Q2, MinD(Res, Threshold) / Threshold);

  if Res <= Threshold then
    K0 := 1.0 / QNow
  else
    K0 := 1.0 / QTop + (KMin - 1.0 / QTop) * (Res - Threshold) / (1.0 - Threshold);

  // The level control grows with the knob, from nothing at 0 - so 0 stays linear,
  // and stays the S950 - to the amount that holds a full-resonance oscillation at
  // OscLevel. See process() for where that figure comes from.
  Beta := BetaFull * Res;

  //
  // The input eased down as the resonance rises, to about -6 dB at the threshold.
  //
  // A peak of nearly +19 dB on a full-scale sample is past anything the engine's
  // output can carry, and analogue resonant filters lose passband the same way.
  // (q2 / Q)^0.25 is exactly 1 at zero resonance, so the S950 is untouched.
  //
  Drive := PowD(Q2 / QNow, 0.25);

  // The level follower's speed: two cycles of the cutoff, but never under FollowMin
  // - two cycles at 16 kHz is six samples, fast enough to bend the sine again.
  Seconds := MaxD(FollowCycles / F, FollowMin);
  Follow := 1.0 - ExpD(-1.0 / (Seconds * Fs));
end;

function TButterworth.Process(X: Double): Double;
var
  K, D1, D2, D3, V1, V2, V3, Y: Double;
  S: Integer;
begin
  //
  // The resonant stage: a TPT state-variable low-pass whose damping k rises with
  // the smoothed power of its own band-pass output, k = k0 + beta * power.
  //
  // An automatic gain control. With k0 below zero, small signals grow and large
  // ones are damped, so an oscillation settles where the two balance - where the
  // power is -k0 / beta, a band-pass amplitude of sqrt (-2 k0 / beta). At the
  // cutoff this stage's low-pass output is as large as its band-pass.
  //
  // Smoothed rather than instantaneous on purpose. Damping driven by band^2 sample
  // by sample (Rayleigh's oscillator) holds the level just as well, but it swings
  // twice a cycle and so bends the sine: at a 16 kHz cutoff its third harmonic
  // folded back to a few hundred hertz at -16 dB. A follower two cycles long moves
  // the damping far too slowly to bend a cycle, and the oscillation is a sine.
  //
  Power := Power + Follow * (Band * Band - Power);

  K  := MinD(K0 + Beta * Power, KMax);
  D1 := 1.0 / (1.0 + G * (G + K));
  D2 := G * D1;
  D3 := G * D2;

  V3 := X * Drive - Ic2;
  V1 := D1 * Ic1 + D2 * V3;
  V2 := Ic2 + D2 * Ic1 + D3 * V3;

  Ic1  := 2.0 * V1 - Ic1;
  Ic2  := 2.0 * V2 - Ic2;
  Band := V1;

  // A voice left sounding in silence decays into denormals, which are slow.
  if Abs(Ic1) < 1e-20 then Ic1 := 0.0;
  if Abs(Ic2) < 1e-20 then Ic2 := 0.0;

  X := V2;

  // --- then the two plain sections
  for S := 0 to FilterBiquads - 1 do
  begin
    Y := B0[S] * X + B1[S] * X1[S] + B2[S] * X2[S]
                   - A1[S] * Y1[S] - A2[S] * Y2[S];
    X2[S] := X1[S]; X1[S] := X;
    Y2[S] := Y1[S]; Y1[S] := Y;
    X := Y;
  end;
  Result := X;
end;

class function TButterworth.OscillationStarts: Double;
begin
  Result := Threshold + (1.0 - Threshold) * (1.0 / QTop) / (1.0 / QTop - KMin);
end;

end.
