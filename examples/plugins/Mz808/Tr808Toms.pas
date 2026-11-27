// Mz808 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/TR808/Toms.h.

unit Tr808Toms;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  Tr808Dsp, Tr808Trigger, Tr808BridgedT;

// TomSize
const
  TomLow = 0;
  TomMid = 1;
  TomHigh = 2;

type
  //
  // LOW, MID and HI TOM / CONGA: LEVEL and TUNING for each pair.
  //
  // Each pair is one circuit: on the hardware a switch changes the bridged-T's values and
  // drops the noise to turn the tom into the conga. So the two cannot sound at once - a
  // conga cuts off its tom - and here, played from MIDI, the note chooses which the circuit
  // is when it is struck.
  //
  //  - A bridged-T, kicked by the shaped trigger, whose centre starts high and sweeps down
  //    as the attack's charge drains away: the 808 tom's pitch drop.
  //  - Toms only: a touch of pink noise on a short envelope, which smears the attack into
  //    something like a drum shell.
  //  - TUNING moves the centre about a quarter of an octave either way of nominal.
  //
  // Nominal centres are published estimates: toms 90, 135, 185 Hz; congas 185, 250, 400 Hz.
  // Ring times, sweep depth and the noise layer are reasoned, not measured.
  //
  TTomPair = record
  private
    FSize: Integer;
    FFs: Single;
    FPulse: TTriggerPulse;
    FShaper: TPulseShaper;
    FRes: TBridgedT;
    FNoiseEnv: TEnvelope;
    FNoiseLp: TOnePole;
    FNoiseLpCoef: Single;

    FConga: Boolean;
    FTune, FCentre, FSweep, FSweepDepth, FSweepFall: Single;
    FB0, FB1, FB2: Single;
    procedure Configure(AsConga: Boolean);
  public
    // The C++ constructor: TomLow, TomMid or TomHigh.
    procedure Init(Size: Integer);
    procedure Prepare(SampleRate: Single);
    procedure SetKnobs(TuningPanel: Single);
    procedure Trigger(Height: Single; AsConga: Boolean);
    function Process(var Rng: TRandom): Single;
    function Quiet: Boolean;
    procedure Reset;
  end;

implementation

const
  Drive = 1;
  ShellGain = 0.5;

  // a kick rings louder the higher the circuit is tuned; the mixer evens them out
  TomGain: array[0..2] of Single = (1.0, 0.72, 0.62);
  CongaGain: array[0..2] of Single = (1.15, 0.95, 0.75);

  TomHz: array[0..2] of Single = (90.0, 135.0, 185.0);
  CongaHz: array[0..2] of Single = (185.0, 250.0, 400.0);
  TomTau: array[0..2] of Single = (0.20, 0.16, 0.13);
  CongaTau: array[0..2] of Single = (0.09, 0.075, 0.06);

  // Single literals the C++ writes with an f (see Tr808Dsp)
  ShaperTau: Single = 0.0003;
  NoiseDecay: Single = 0.05;
  CongaSweepDepth: Single = 0.12;
  TomSweepDepth = 0.25;
  CongaSweepTau: Single = 0.008;
  TomSweepTau: Single = 0.03;
  Silence: Single = 1.0e-6;
  EnvSilence: Single = 1.0e-5;

  // Paul Kellet's economy pink filter
  PinkA0: Single = 0.99765;
  PinkB0: Single = 0.0990460;
  PinkA1: Single = 0.96300;
  PinkB1: Single = 0.2965164;
  PinkA2: Single = 0.57000;
  PinkB2: Single = 1.0526913;
  PinkW: Single = 0.1848;

{ TTomPair }

procedure TTomPair.Init(Size: Integer);
begin
  FSize := Size;
  FFs := 48000;
  FPulse.Init;
  FShaper.Init;
  FRes.Init;
  FNoiseEnv.Init;
  FNoiseLp.Init;
  FNoiseLpCoef := 1;
  FConga := False;
  FTune := 1;
  FCentre := 100;
  FSweep := 0;
  FSweepDepth := 0.25;
  FSweepFall := 0;
  FB0 := 0;
  FB1 := 0;
  FB2 := 0;
end;

procedure TTomPair.Prepare(SampleRate: Single);
begin
  FFs := SampleRate;
  FRes.Prepare(FFs);
  FShaper.Prepare(FFs, ShaperTau);
  FNoiseEnv.Prepare(FFs);
  FNoiseEnv.SetDecay(NoiseDecay);
  FNoiseLpCoef := OnePoleCoef(TauOf(1800), FFs);
  SetKnobs(5);
  Reset;
  Configure(False);
end;

procedure TTomPair.SetKnobs(TuningPanel: Single);
var
  X: Single;
begin
  X := (Clamp(TuningPanel, 0, 10) - 5) / 5 * 0.25;
  FTune := PowF(2, X);
  Configure(FConga);
end;

procedure TTomPair.Trigger(Height: Single; AsConga: Boolean);
begin
  if AsConga <> FConga then
    Configure(AsConga);
  FPulse.Fire(Height, FFs);
  FSweep := Height;
end;

function TTomPair.Process(var Rng: TRandom): Single;
var
  P, S, Y, Shell, W, Pink, Lp, E: Single;
begin
  P := FPulse.Next;
  S := FShaper.Process(P);

  FSweep := FSweep * FSweepFall;
  Y := FRes.Process(Drive * S, FCentre * (1 + FSweepDepth * FSweep));

  Shell := 0;
  if not FConga then
  begin
    // Paul Kellet's economy pink filter on the white noise
    W := Rng.White;
    FB0 := PinkA0 * FB0 + W * PinkB0;
    FB1 := PinkA1 * FB1 + W * PinkB1;
    FB2 := PinkA2 * FB2 + W * PinkB2;
    Pink := (FB0 + FB1 + FB2 + W * PinkW) * 0.25;
    Lp := FNoiseLp.LowPass(Pink, FNoiseLpCoef);
    E := FNoiseEnv.Process(P);
    Shell := Lp * E * ShellGain;
  end;

  if FConga then
    Result := (Y + Shell) * CongaGain[FSize]
  else
    Result := (Y + Shell) * TomGain[FSize];
end;

function TTomPair.Quiet: Boolean;
begin
  Result := not FPulse.High and (FRes.Energy < Silence) and (FNoiseEnv.Value < EnvSilence);
end;

procedure TTomPair.Reset;
begin
  FRes.Reset;
  FShaper.Reset;
  FNoiseEnv.Reset;
  FNoiseLp.Reset;
  FB0 := 0;
  FB1 := 0;
  FB2 := 0;
  FSweep := 0;
end;

procedure TTomPair.Configure(AsConga: Boolean);
begin
  FConga := AsConga;
  if FConga then
  begin
    FCentre := CongaHz[FSize] * FTune;
    FRes.SetTo(FCentre, CongaTau[FSize]);
    FSweepDepth := CongaSweepDepth;
    FSweepFall := DecayCoef(CongaSweepTau, FFs);
  end
  else
  begin
    FCentre := TomHz[FSize] * FTune;
    FRes.SetTo(FCentre, TomTau[FSize]);
    FSweepDepth := TomSweepDepth;
    FSweepFall := DecayCoef(TomSweepTau, FFs);
  end;
end;

end.
