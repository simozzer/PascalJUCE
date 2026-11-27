// Mz909 - an emulation of the TR-909 Rhythm Composer
// Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/TR909/SnareDrum.h.

unit Tr909SnareDrum;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  Tr909Dsp, Tr909Trigger, Tr909Vco;

type
  //
  // SNARE DRUM: LEVEL, TUNE, TONE, SNAPPY.
  //
  //  - The drum head is two VCOs, a little under an octave apart, each through its own VCA;
  //    the upper one dies sooner. Both start a little sharp and drop as the head settles.
  //    TUNE moves them together.
  //  - The snares are white noise, low-passed and high-passed, through a VCA on an envelope
  //    longer than the head's - the 909 snare's hiss outlasts its body. SNAPPY is how much
  //    of it goes in, and TONE how bright it is.
  //
  // The structure is the circuit's. The pitches, times and filters are reasoned from the
  // sound, not measured.
  //
  TSnareDrum = record
  private
    FFs: Single;
    FPulse: TTriggerPulse;
    FLow, FHigh: TDrumVco;
    FLowAmp, FHighAmp, FNoiseAmp: TEnvelope;
    FNoiseLp1, FNoiseLp2: TOnePole;
    FNoiseHp: TSvf;

    FRatio, FNoiseLpCoef, FSnappy: Single;
    FPitch, FPitchFall: Single;
  public
    procedure Init;
    procedure Prepare(SampleRate: Single);
    procedure SetPanel(TunePanel, TonePanel, SnappyPanel: Single);
    procedure Trigger(Height: Single);
    function Process(var Rng: TRandom): Single;
    function Quiet: Boolean;
    procedure Reset;
  end;

implementation

const
  LowHz = 185;
  HighHz = 330;
  HighMix: Single = 0.6;
  PitchDrop = 0.5;
  HeadGain: Single = 0.45;
  SnareGain: Single = 0.8;
  Gain: Single = 1.6;

  LowDecay: Single = 0.05;
  HighDecay: Single = 0.028;
  PitchTau: Single = 0.012;
  NoiseHpHz = 500;
  NoiseHpQ: Single = 0.7;
  NoiseDecay: Single = 0.075;
  RatioLo: Single = 0.8;
  RatioHi = 1.25;
  ToneLo = 2500;
  ToneHi = 11000;
  Silent: Single = 1.0e-5;

procedure TSnareDrum.Init;
begin
  FFs := 48000;
  FPulse.Init;
  FLow.Init;
  FHigh.Init;
  FLowAmp.Init;
  FHighAmp.Init;
  FNoiseAmp.Init;
  FNoiseLp1.Z := 0;
  FNoiseLp2.Z := 0;
  FNoiseHp.Init;
  FRatio := 1;
  FNoiseLpCoef := 1;
  FSnappy := 0.5;
  FPitch := 0;
  FPitchFall := 0;
end;

procedure TSnareDrum.Prepare(SampleRate: Single);
begin
  FFs := SampleRate;
  FLow.Prepare(FFs);
  FHigh.Prepare(FFs);
  FLowAmp.Prepare(FFs);
  FLowAmp.SetDecay(LowDecay);
  FHighAmp.Prepare(FFs);
  FHighAmp.SetDecay(HighDecay);
  FPitchFall := DecayCoef(PitchTau, FFs);
  FNoiseHp.Prepare(FFs);
  FNoiseHp.Setup(NoiseHpHz, NoiseHpQ);
  FNoiseAmp.Prepare(FFs);
  FNoiseAmp.SetDecay(NoiseDecay);
  SetPanel(5, 5, 5);
  Reset;
end;

procedure TSnareDrum.SetPanel(TunePanel, TonePanel, SnappyPanel: Single);
begin
  FRatio := ExpLaw(TunePanel / 10, RatioLo, RatioHi);
  FNoiseLpCoef := OnePoleCoef(TauOf(ExpLaw(TonePanel / 10, ToneLo, ToneHi)), FFs);
  FSnappy := Clamp(SnappyPanel / 10, 0, 1);
end;

procedure TSnareDrum.Trigger(Height: Single);
begin
  FPulse.Fire(Height, FFs);
  FPitch := 1;
  FLow.Restart;
  FHigh.Restart;
end;

function TSnareDrum.Process(var Rng: TRandom): Single;
var
  P, Bend, Head, W, Hiss, Snares: Single;
begin
  P := FPulse.Next;

  FPitch := FPitch * FPitchFall;
  Bend := FRatio * (1 + PitchDrop * FPitch);
  Head := FLow.Process(LowHz * Bend) * FLowAmp.Process(P)
        + HighMix * FHigh.Process(HighHz * Bend) * FHighAmp.Process(P);

  W := Rng.White;
  Hiss := FNoiseLp2.LowPass(FNoiseLp1.LowPass(W, FNoiseLpCoef), FNoiseLpCoef);
  FNoiseHp.Process(Hiss);
  Snares := FNoiseHp.Hp * FNoiseAmp.Process(P);

  Result := SoftClip(HeadGain * Head + FSnappy * SnareGain * Snares) * Gain;
end;

function TSnareDrum.Quiet: Boolean;
begin
  Result := (not FPulse.High) and (FLowAmp.Value + FHighAmp.Value + FNoiseAmp.Value < Silent);
end;

procedure TSnareDrum.Reset;
begin
  FLowAmp.Reset;
  FHighAmp.Reset;
  FNoiseAmp.Reset;
  FNoiseLp1.Reset;
  FNoiseLp2.Reset;
  FNoiseHp.Reset;
  FPitch := 0;
end;

end.
