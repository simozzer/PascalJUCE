// Mz909 - an emulation of the TR-909 Rhythm Composer
// Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/TR909/BassDrum.h.

unit Tr909BassDrum;

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
  // BASS DRUM: LEVEL, TUNE, ATTACK, DECAY.
  //
  //  - The body is the drum VCO, restarted by each hit, through a VCA whose envelope DECAY
  //    sets.
  //  - A pitch envelope, charged by the trigger, starts the VCO several times higher and lets
  //    it fall exponentially to the body's pitch, about 50 Hz. That fall is the 909 kick's
  //    "dooo". TUNE sets how far and how long the pitch falls: a short, tight drop at 0, a
  //    long, deep sweep at 10. The body's own pitch moves little.
  //  - ATTACK is the beater: the trigger's edge, differentiated into a click, and a burst
  //    of low-passed noise, mixed in at the level ATTACK sets.
  //  - The output stage is driven into soft saturation. An accent's taller trigger charges
  //    the pitch envelope higher - a deeper sweep - and pushes the VCA harder, so an accented
  //    kick punches rather than just getting louder.
  //
  // The structure is the circuit's. The pitches, times and levels are reasoned from the sound
  // and from the circuit, not measured from a unit.
  //
  TBassDrum = record
  private
    FFs: Single;
    FPulse: TTriggerPulse;
    FVco: TDrumVco;
    FAmp: TEnvelope;
    FEdgeHp, FNoiseLp: TOnePole;

    FSweepDepth, FPitchFall, FHz, FClick: Single;
    FEdgeCoef, FNoiseLpCoef, FNoiseFall: Single;
    FPitch, FNoise: Single;
  public
    procedure Init;
    procedure Prepare(SampleRate: Single);
    procedure SetPanel(TunePanel, AttackPanel, DecayPanel: Single);
    procedure Trigger(Height: Single);
    function Process(var Rng: TRandom): Single;
    function Quiet: Boolean;
    procedure Reset;
  end;

implementation

const
  Base = 50;
  ClickEdge: Single = 0.9;
  ClickNoise: Single = 0.6;
  Drive: Single = 0.8;
  Gain: Single = 1.35;

  EdgeTau: Single = 0.00025;
  NoiseCorner = 4500;
  NoiseTau: Single = 0.003;
  SweepLo = 1.5;
  SweepHi = 5;
  FallLo: Single = 0.008;
  FallHi: Single = 0.045;
  PitchLo: Single = 0.97;
  PitchSpan: Single = 0.06;
  DecayLo: Single = 0.06;
  DecayHi: Single = 0.42;
  Silent: Single = 1.0e-5;

procedure TBassDrum.Init;
begin
  FFs := 48000;
  FPulse.Init;
  FVco.Init;
  FAmp.Init;
  FEdgeHp.Z := 0;
  FNoiseLp.Z := 0;
  FSweepDepth := 3;
  FPitchFall := 0;
  FHz := Base;
  FClick := 0.5;
  FEdgeCoef := 1;
  FNoiseLpCoef := 1;
  FNoiseFall := 0;
  FPitch := 0;
  FNoise := 0;
end;

procedure TBassDrum.Prepare(SampleRate: Single);
begin
  FFs := SampleRate;
  FVco.Prepare(FFs);
  FAmp.Prepare(FFs);
  FEdgeCoef := OnePoleCoef(EdgeTau, FFs);
  FNoiseLpCoef := OnePoleCoef(TauOf(NoiseCorner), FFs);
  FNoiseFall := DecayCoef(NoiseTau, FFs);
  SetPanel(5, 5, 5);
  Reset;
end;

procedure TBassDrum.SetPanel(TunePanel, AttackPanel, DecayPanel: Single);
var
  T: Single;
begin
  T := TunePanel / 10;
  FSweepDepth := ExpLaw(T, SweepLo, SweepHi);
  FPitchFall := DecayCoef(ExpLaw(T, FallLo, FallHi), FFs);
  FHz := Base * (PitchLo + PitchSpan * Clamp(T, 0, 1));
  FClick := Clamp(AttackPanel / 10, 0, 1);
  FAmp.SetDecay(ExpLaw(DecayPanel / 10, DecayLo, DecayHi));
end;

procedure TBassDrum.Trigger(Height: Single);
begin
  FPulse.Fire(Height, FFs);
  FPitch := Height;
  FNoise := Height;
  FVco.Restart;
end;

function TBassDrum.Process(var Rng: TRandom): Single;
var
  P, Body, Edge, Puff, Beater, W: Single;
begin
  P := FPulse.Next;

  FPitch := FPitch * FPitchFall;
  Body := FVco.Process(FHz * (1 + FSweepDepth * FPitch)) * FAmp.Process(P);

  // the beater: the pulse's edges, and a puff of noise
  Edge := FEdgeHp.HighPass(P, FEdgeCoef);
  FNoise := FNoise * FNoiseFall;
  W := Rng.White;
  Puff := FNoiseLp.LowPass(W, FNoiseLpCoef) * FNoise;
  Beater := FClick * (ClickEdge * Edge + ClickNoise * Puff);

  Result := SoftClip(Drive * (Body + Beater)) * Gain;
end;

function TBassDrum.Quiet: Boolean;
begin
  Result := (not FPulse.High) and (FAmp.Value < Silent) and (FNoise < Silent) and (Abs(FEdgeHp.Z) < Silent);
end;

procedure TBassDrum.Reset;
begin
  FAmp.Reset;
  FEdgeHp.Reset;
  FNoiseLp.Reset;
  FPitch := 0;
  FNoise := 0;
end;

end.
