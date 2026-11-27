// Mz808 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/TR808/SnareDrum.h.

unit Tr808SnareDrum;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  Tr808Dsp, Tr808Trigger, Tr808BridgedT;

type
  //
  // SNARE DRUM: LEVEL, TONE, SNAPPY.
  //
  // The drum head is two bridged-Ts, about 238 Hz and 476 Hz, kicked together by the shaped
  // trigger; the upper one dies sooner. TONE crossfades between them - low and hollow at 0,
  // higher and tighter at 10. The snares are the machine's white noise, high-passed and
  // through a VCA on its own envelope; SNAPPY is how much of that goes in.
  //
  // The two centres are published estimates; the ring times, the noise filter and its
  // envelope are reasoned from the sound and the circuit's structure, not measured.
  //
  TSnareDrum = record
  private
    FFs: Single;
    FPulse: TTriggerPulse;
    FShaper: TPulseShaper;
    FLow, FHigh: TBridgedT;
    FNoiseHp: TSvf;
    FNoiseLp: TOnePole;
    FNoiseLpCoef: Single;
    FNoiseEnv: TEnvelope;

    FLowMix, FHighMix, FSnappy: Single;
  public
    procedure Init;
    procedure Prepare(SampleRate: Single);
    procedure SetKnobs(TonePanel, SnappyPanel: Single);
    procedure Trigger(Height: Single); inline;
    function Process(var Rng: TRandom): Single;
    function Quiet: Boolean;
    procedure Reset;
  end;

implementation

const
  Drive = 1;
  SnareGain: Single = 0.55;
  Gain: Single = 0.9;

  // Single literals the C++ writes with an f (see Tr808Dsp)
  LowTau: Single = 0.045;
  HighTau: Single = 0.025;
  ShaperTau: Single = 0.0003;
  NoiseQ: Single = 0.7;
  NoiseDecay: Single = 0.055;
  VcaDrive: Single = 0.9;
  Silence: Single = 1.0e-6;
  EnvSilence: Single = 1.0e-5;

{ TSnareDrum }

procedure TSnareDrum.Init;
begin
  FFs := 48000;
  FPulse.Init;
  FShaper.Init;
  FLow.Init;
  FHigh.Init;
  FNoiseHp.Init;
  FNoiseLp.Init;
  FNoiseLpCoef := 1;
  FNoiseEnv.Init;
  FLowMix := 1;
  FHighMix := 0;
  FSnappy := 0.5;
end;

procedure TSnareDrum.Prepare(SampleRate: Single);
begin
  FFs := SampleRate;
  FLow.Prepare(FFs);
  FHigh.Prepare(FFs);
  FLow.SetTo(238, LowTau);
  FHigh.SetTo(476, HighTau);
  FShaper.Prepare(FFs, ShaperTau);
  FNoiseHp.Prepare(FFs);
  FNoiseHp.Setup(1800, NoiseQ);
  FNoiseLpCoef := OnePoleCoef(TauOf(9000), FFs);
  FNoiseEnv.Prepare(FFs);
  FNoiseEnv.SetDecay(NoiseDecay);
  SetKnobs(5, 5);
  Reset;
end;

procedure TSnareDrum.SetKnobs(TonePanel, SnappyPanel: Single);
var
  T: Single;
begin
  T := Clamp(TonePanel / 10, 0, 1);
  FLowMix := 1 - 0.75 * T;
  FHighMix := 0.25 + 0.75 * T;
  FSnappy := Clamp(SnappyPanel / 10, 0, 1);
end;

procedure TSnareDrum.Trigger(Height: Single);
begin
  FPulse.Fire(Height, FFs);
end;

function TSnareDrum.Process(var Rng: TRandom): Single;
var
  P, S, L, H, Head, W, Hiss, E, Snares: Single;
begin
  P := FPulse.Next;
  S := FShaper.Process(P);

  L := FLow.Process(Drive * S);
  H := FHigh.Process(Drive * S);
  Head := FLowMix * L + FHighMix * H;

  W := Rng.White;
  FNoiseHp.Process(W);
  Hiss := FNoiseLp.LowPass(FNoiseHp.Hp, FNoiseLpCoef);
  E := FNoiseEnv.Process(P);
  Snares := SoftClip(Hiss * E * VcaDrive);   // the VCA, pushed by an accent

  Result := (Head + FSnappy * SnareGain * Snares) * Gain;
end;

function TSnareDrum.Quiet: Boolean;
begin
  Result := not FPulse.High and (FLow.Energy + FHigh.Energy < Silence) and (FNoiseEnv.Value < EnvSilence);
end;

procedure TSnareDrum.Reset;
begin
  FLow.Reset;
  FHigh.Reset;
  FShaper.Reset;
  FNoiseHp.Reset;
  FNoiseLp.Reset;
  FNoiseEnv.Reset;
end;

end.
