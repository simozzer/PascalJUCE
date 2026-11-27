// Mz808 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/TR808/Cymbal.h.

unit Tr808Cymbal;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  Tr808Dsp, Tr808Trigger, Tr808Metal;

type
  //
  // CYMBAL: LEVEL, TONE, DECAY.
  //
  // After Werner, Abel and Smith's analysis (ICMC 2014):
  //
  //  - The six oscillators, summed, into two band passes, centred near 3440 Hz and 7100 Hz.
  //    Both throw away the fundamentals and keep the clangorous upper partials.
  //  - Three bands, each through a swing-type VCA on its own envelope, then a high pass:
  //    the low band rings longest, and DECAY sets how long; the middle band is medium; the
  //    top band is a short splash, through a resonant third-order high pass near 10.5 kHz.
  //  - TONE is a passive network whose main effect is how much of the top band gets
  //    through; it also leans a little on the other two.
  //
  // Band-pass centres, the top band's high pass, the attack smoother and the structure are
  // from the analysis. The envelope times, the other two high-pass corners, Qs and the band
  // levels are reasoned from it and from the sound.
  //
  TCymbal = record
  private
    FFs: Single;
    FPulse: TTriggerPulse;
    FBp1, FBp2, FHp1, FHp2, FHp3: TSvf;
    FHp3Pole: TOnePole;
    FHp3PoleCoef: Single;
    FEnv1, FEnv2, FEnv3: TEnvelope;
    FLow, FMid, FTop: Single;
  public
    procedure Init;
    procedure Prepare(SampleRate: Single);
    procedure SetKnobs(TonePanel, DecayPanel: Single);
    procedure Trigger(Height: Single); inline;
    function Process(const Bank: TMetalBank): Single;
    function Quiet: Boolean;
    procedure Reset;
  end;

implementation

const
  Drive: Single = 1.6;
  Gain = 0.75;

  // Single literals the C++ writes with an f (see Tr808Dsp)
  BandQ: Single = 1.3;
  HpQ: Single = 0.7;
  SplashQ: Single = 1.6;
  MidDecay: Single = 0.085;
  TopDecay: Single = 0.028;
  LowTone: Single = 0.55;
  MidBase: Single = 0.9;
  MidTone: Single = 0.2;
  TopBase: Single = 0.05;
  TopTone: Single = 2.6;
  DecayShortest: Single = 0.12;
  DecayLongest = 0.75;
  EnvSilence: Single = 1.0e-5;

{ TCymbal }

procedure TCymbal.Init;
begin
  FFs := 48000;
  FPulse.Init;
  FBp1.Init;
  FBp2.Init;
  FHp1.Init;
  FHp2.Init;
  FHp3.Init;
  FHp3Pole.Init;
  FHp3PoleCoef := 1;
  FEnv1.Init;
  FEnv2.Init;
  FEnv3.Init;
  FLow := 1;
  FMid := 1;
  FTop := 1;
end;

procedure TCymbal.Prepare(SampleRate: Single);
begin
  FFs := SampleRate;
  FBp1.Prepare(FFs);
  FBp1.Setup(3440, BandQ);
  FBp2.Prepare(FFs);
  FBp2.Setup(7100, BandQ);
  FHp1.Prepare(FFs);
  FHp1.Setup(2200, HpQ);
  FHp2.Prepare(FFs);
  FHp2.Setup(4600, HpQ);
  FHp3.Prepare(FFs);
  FHp3.Setup(10500, SplashQ);
  FHp3PoleCoef := OnePoleCoef(TauOf(10500), FFs);
  FEnv1.Prepare(FFs);
  FEnv2.Prepare(FFs);
  FEnv2.SetDecay(MidDecay);
  FEnv3.Prepare(FFs);
  FEnv3.SetDecay(TopDecay);
  SetKnobs(5, 5);
  Reset;
end;

procedure TCymbal.SetKnobs(TonePanel, DecayPanel: Single);
var
  T: Single;
begin
  T := Clamp(TonePanel / 10, 0, 1);
  FLow := 1 - LowTone * T;
  FMid := MidBase - MidTone * T;
  FTop := TopBase + TopTone * T;
  FEnv1.SetDecay(ExpLaw(DecayPanel / 10, DecayShortest, DecayLongest));
end;

procedure TCymbal.Trigger(Height: Single);
begin
  FPulse.Fire(Height, FFs);
end;

function TCymbal.Process(const Bank: TMetalBank): Single;
var
  P, X, A, B, E, Splash: Single;
begin
  P := FPulse.Next;
  X := Bank.Sum;

  FBp1.Process(X);
  FBp2.Process(X);
  A := FBp1.BandNorm;
  B := FBp2.BandNorm;

  E := FEnv1.Process(P);
  FHp1.Process(SwingVca(A, E, Drive));
  E := FEnv2.Process(P);
  FHp2.Process(SwingVca(B, E, Drive));
  E := FEnv3.Process(P);
  FHp3.Process(SwingVca(B, E, Drive));
  Splash := FHp3Pole.HighPass(FHp3.Hp, FHp3PoleCoef);

  Result := (FLow * FHp1.Hp + FMid * FHp2.Hp + FTop * Splash) * Gain;
end;

function TCymbal.Quiet: Boolean;
begin
  Result := not FPulse.High and (FEnv1.Value + FEnv2.Value + FEnv3.Value < EnvSilence);
end;

procedure TCymbal.Reset;
begin
  FEnv1.Reset;
  FEnv2.Reset;
  FEnv3.Reset;
  FHp1.Reset;
  FHp2.Reset;
  FHp3.Reset;
  FHp3Pole.Reset;
end;

end.
