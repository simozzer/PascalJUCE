// Mz909 - an emulation of the TR-909 Rhythm Composer
// Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/TR909/Toms.h.

unit Tr909Toms;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  Tr909Dsp, Tr909Trigger, Tr909Vco;

type
  TTomSize = (tsLow, tsMid, tsHigh);

  //
  // LOW, MID and HI TOM: LEVEL, TUNE, DECAY each.
  //
  // Built like the bass drum, smaller: a drum VCO, restarted by each hit, with a pitch that
  // starts high and falls - the 909 tom's "boww" - through a VCA whose envelope DECAY sets,
  // and a short puff of noise for the stick. Nominal pitches are about 100, 140 and 200 Hz.
  // TUNE moves the whole tom, sweep and all, half an octave either way.
  //
  // The structure is the circuit's. The pitches, the sweep and the times are reasoned from
  // the sound, not measured.
  //
  TTom = record
  private
    FBase, FLength: Single;

    FFs: Single;
    FPulse: TTriggerPulse;
    FVco: TDrumVco;
    FAmp: TEnvelope;
    FNoiseLp: TOnePole;

    FHz, FPitchFall, FNoiseLpCoef, FNoiseFall: Single;
    FPitch, FNoise: Single;
  public
    // The C++ constructor, Tom(TomSize).
    procedure Init(Size: TTomSize);
    procedure Prepare(SampleRate: Single);
    procedure SetPanel(TunePanel, DecayPanel: Single);
    procedure Trigger(Height: Single);
    function Process(var Rng: TRandom): Single;
    function Quiet: Boolean;
    procedure Reset;
  end;

implementation

const
  Sweep: Single = 0.6;
  StickLevel: Single = 0.2;
  Drive: Single = 0.9;
  Gain: Single = 1.2;

  LowLength: Single = 1.2;
  HighLength: Single = 0.85;
  PitchTau: Single = 0.03;
  NoiseCorner = 1800;
  NoiseTau: Single = 0.012;
  TuneLo: Single = 0.70710678;
  TuneHi: Single = 1.41421356;
  DecayLo: Single = 0.06;
  DecayHi: Single = 0.35;
  Silent: Single = 1.0e-5;

procedure TTom.Init(Size: TTomSize);
begin
  case Size of
    tsLow:
      begin
        FBase := 100;
        FLength := LowLength;
      end;
    tsMid:
      begin
        FBase := 140;
        FLength := 1;
      end;
  else
    FBase := 200;
    FLength := HighLength;
  end;
  FFs := 48000;
  FPulse.Init;
  FVco.Init;
  FAmp.Init;
  FNoiseLp.Z := 0;
  FHz := 100;
  FPitchFall := 0;
  FNoiseLpCoef := 1;
  FNoiseFall := 0;
  FPitch := 0;
  FNoise := 0;
end;

procedure TTom.Prepare(SampleRate: Single);
begin
  FFs := SampleRate;
  FVco.Prepare(FFs);
  FAmp.Prepare(FFs);
  FPitchFall := DecayCoef(PitchTau, FFs);
  FNoiseLpCoef := OnePoleCoef(TauOf(NoiseCorner), FFs);
  FNoiseFall := DecayCoef(NoiseTau, FFs);
  SetPanel(5, 5);
  Reset;
end;

procedure TTom.SetPanel(TunePanel, DecayPanel: Single);
begin
  FHz := FBase * ExpLaw(TunePanel / 10, TuneLo, TuneHi);
  FAmp.SetDecay(FLength * ExpLaw(DecayPanel / 10, DecayLo, DecayHi));
end;

procedure TTom.Trigger(Height: Single);
begin
  FPulse.Fire(Height, FFs);
  FPitch := Height;
  FNoise := Height;
  FVco.Restart;
end;

function TTom.Process(var Rng: TRandom): Single;
var
  P, Body, W, Stick: Single;
begin
  P := FPulse.Next;

  FPitch := FPitch * FPitchFall;
  Body := FVco.Process(FHz * (1 + Sweep * FPitch)) * FAmp.Process(P);

  FNoise := FNoise * FNoiseFall;
  W := Rng.White;
  Stick := FNoiseLp.LowPass(W, FNoiseLpCoef) * FNoise;

  Result := SoftClip(Drive * (Body + StickLevel * Stick)) * Gain;
end;

function TTom.Quiet: Boolean;
begin
  Result := (not FPulse.High) and (FAmp.Value < Silent) and (FNoise < Silent);
end;

procedure TTom.Reset;
begin
  FAmp.Reset;
  FNoiseLp.Reset;
  FPitch := 0;
  FNoise := 0;
end;

end.
