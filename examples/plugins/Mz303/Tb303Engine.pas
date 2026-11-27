// Mz303 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of source/TB303/Engine.h and Engine.cpp. It renders the same samples as
// the C++ engine, bit for bit (verify/build_verify.cmd checks it); see Tb303Dsp for how.

unit Tb303Engine;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  Tb303Dsp, Tb303Settings, Tb303Vco, Tb303Vcf, Tb303Envelopes, Tb303Decimator;

const
  // A note whose velocity is at least this is accented.
  AccentVelocity = 100;

type
  TSampleArray = array[0..MaxInt div SizeOf(Single) - 1] of Single;
  PSampleArray = ^TSampleArray;

  TTargets = record
    CutoffLog, K, EnvOct, AccentOct, AccentGain, ResPot: Single;
    Volume: Single;
  end;

  //
  // One TB-303 voice, played from MIDI: VCO, diode-ladder VCF, VCA, the two envelopes and the
  // accent circuit, oversampled.
  //
  // On the original, ACCENT and SLIDE are written into each step of a pattern, along with the
  // note. Here they come with each note instead:
  //
  //   accent   a note whose velocity is at least AccentVelocity
  //   slide    a note played while the one before is still held. The pitch glides to it,
  //            and neither envelope restarts - the 303's slide is a legato, as much as a
  //            portamento. Letting go of a slid-to note while the first is still held slides
  //            back.
  //
  // Monophonic with last-note priority. Everything is called from the audio thread; the
  // plug-in publishes what the panel shows (AccentLit, SlideLit) as meters.
  //
  TEngine = class
  private
    FSettings: TSettings;
    FTgt, FCur: TTargets;
    FPrimed: Boolean;

    FHostRate, FRateInt: Single;
    FFactor: Integer;

    FVco: TVco;
    FVcf: TVcf;
    FMeg: TMeg;
    FVeg: TVeg;
    FSweep: TAccentSweep;
    FDecimator: TDecimator;
    FRng: TRandom;

    // keyboard
    FHeld: array[0..127] of Integer;
    FNumHeld: Integer;
    FKey: Integer;
    FGate: Boolean;
    FAccent: Boolean;
    FSliding: Boolean;
    FKeyTarget, FKeyCv: Single;

    FAccentLight, FSlideLight: Boolean;

    FBend: Single;

    // derived per block
    FSlideCoef, FSmoothCoef, FAccentDecayCoef: Single;
    FTuneOct, FMaxFc: Single;
    FLastFc: Single;

    // the analog around the edges
    FDrift, FDriftTarget, FDriftCoef: Single;
    FDriftCountdown: Integer;
    FJitter, FJitterCoef: Single;

    FInX1, FInY1, FInCoef: Single;
    FDcX1, FDcY1, FDcCoef: Single;
    FVolume, FVolumeCoef: Single;

    procedure UpdateTargets;
    function Tick: Single;
    procedure Play(Note: Integer; Slide: Boolean);
    procedure RemoveHeld(Note: Integer);
  public
    constructor Create;
    procedure Prepare(HostSampleRate: Double);
    procedure SetSettings(const S: TSettings);

    procedure NoteOn(Note, Velocity: Integer);
    procedure NoteOff(Note: Integer);
    procedure AllNotesOff;

    procedure SetPitchBend(V: Single);   // two semitones either way

    procedure Render(Output: PSingle; NumSamples: Integer);

    // the panel's ACCENT and SLIDE lights
    property AccentLit: Boolean read FAccentLight;
    property SlideLit: Boolean read FSlideLight;

    property CurrentKey: Integer read FKey;
    property GateIsOn: Boolean read FGate;
    property Accented: Boolean read FAccent;
    property Oversampling: Integer read FFactor;

    // For the checks: what the filter and accent circuit are doing now.
    property CutoffHz: Single read FLastFc;
    function AccentCharge: Single;
  end;

implementation

const
  A4 = 440;

  //
  // The voice's ranges. None is printed in the owner's manual the way the SH-101's are in
  // its spec, so these are reasoned from the circuit and from how the instrument is played,
  // and each is a single number to fit to a real unit.
  //

  // CUTOFF: the rungs' own RC frequency across the knob. The resonant peak sits a little
  // above it - the loaded ladder's poles spread both ways - so this is about 200 Hz to
  // 5 kHz of peak.
  CutoffLo: Single = 150;
  CutoffHi: Single = 3500;

  // ENV MOD: how far the MEG sweeps the cutoff at full; and how far turning it up pulls
  // the resting cutoff DOWN, since on the 303 the knob shifts the envelope's whole range
  // rather than only adding to it.
  EnvOctaves = 4;
  EnvDip = 1;

  // ACCENT: how far an accent sweeps the cutoff, and how much it lifts the VCA, at full.
  AccentOctaves = 2.5;
  AccentVca = 1;

  // DECAY: the MEG's time to fall to 5%, across the knob; an accent's, whatever the knob.
  DecayShortest: Single = 0.2;
  DecayLongest = 2.5;

  // RESONANCE: the loop gain at full, just short of where the ladder whistles on its own
  // (about 18; more for low cutoffs, where the coupling capacitor takes the feedback away).
  KMax = 17;

  // Feedback costs the ladder 1 / (1 + k) of its passband. The output makes up part of
  // that, so RESONANCE thins the sound rather than doubling as a volume control: a
  // departure from the strict circuit. Without it full resonance takes 17 dB off a bass
  // line, far more than a 303 is heard to lose; with it, about 6.
  Makeup: Single = 0.15;

  // SLIDE: an RC on the pitch CV - most of the way in about a sixteenth at 120 BPM.
  SlideTau: Single = 0.04;

  // how hard the oscillator drives the filter's bottom pair
  Drive: Single = 0.6;

  // Single literals the C++ writes with an f (see Tb303Dsp)
  Tenth: Single = 0.1;
  VolumeCurve: Single = 1.4;
  KnobSmoothTau: Single = 0.004;
  DriftTau: Single = 1.5;
  VolumeTau: Single = 0.01;
  MaxFcFraction: Single = 0.3;
  DriftMin: Single = 0.3;
  DriftSpread: Single = 0.9;
  DriftDepth: Single = 0.0012;
  JitterDepth: Single = 0.004;
  InputNoise: Single = 1.0e-5;
  MaxDt: Single = 0.45;
  MinFc = 10;

var
  BendOctaves: Single;   // 2.0f / 12.0f, rounded once as the C++ constant is

// 0..10 -> 0..1
function Panel(V: Single): Single; inline;
begin
  Result := Clamp(V * Tenth, 0, 1);
end;

function MinF(A, B: Single): Single; inline;
begin
  // std::min(a, b): b only if it is less
  if B < A then
    Result := B
  else
    Result := A;
end;

constructor TEngine.Create;
begin
  inherited Create;
  FSettings := TSettings.Defaults;
  FHostRate := 44100;
  FRateInt := 176400;
  FFactor := 4;
  FVco.Init;
  FVcf.Init;
  FMeg.Init;
  FVeg.Init;
  FSweep.Init;
  FDecimator.Init;
  FRng.Init;
  FKey := 48;
  FSlideCoef := 1;
  FSmoothCoef := 1;
  FAccentDecayCoef := 1;
  FMaxFc := 20000;
  FInCoef := 0.9995;
  FDcCoef := 0.999;
  FVolumeCoef := 0.01;
end;

function TEngine.AccentCharge: Single;
begin
  Result := FSweep.Charge;
end;

procedure TEngine.SetPitchBend(V: Single);
begin
  FBend := Clamp(V, -1, 1);
end;

procedure TEngine.Prepare(HostSampleRate: Double);
var
  T: Single;
begin
  FHostRate := HostSampleRate;
  if FHostRate <= 50000 then
    FFactor := 4
  else if FHostRate <= 100000 then
    FFactor := 2
  else
    FFactor := 1;
  FRateInt := FHostRate * FFactor;

  FDecimator.Prepare(FFactor, FHostRate);
  FVcf.SetSampleRate(FRateInt);
  FMeg.SetSampleRate(FRateInt);
  FVeg.SetSampleRate(FRateInt);
  FSweep.SetSampleRate(FRateInt);

  FVco.Reset;
  FVcf.Reset;
  FMeg.Reset;
  FVeg.Reset;
  FSweep.Reset;

  FSmoothCoef := OnePoleCoef(KnobSmoothTau, FRateInt);   // a knob cannot move faster than a hand
  FSlideCoef := OnePoleCoef(SlideTau, FRateInt);
  FAccentDecayCoef := OnePoleCoef(DecayShortest / 3, FRateInt);
  FDriftCoef := OnePoleCoef(DriftTau, FRateInt);
  T := 2 * PiF * 25;                                      // 2.0f * (float) pi * 25.0f
  FJitterCoef := OnePoleCoef(1 / T, FRateInt);
  FVolumeCoef := OnePoleCoef(VolumeTau, FHostRate);

  // the coupling capacitor into the filter, and the output's: in double, as the C++
  T := 2.0 * Pi64 * 5.0 / FRateInt;    // (float) of the double
  FInCoef := 1 - T;
  T := 2.0 * Pi64 * 8.0 / FHostRate;
  FDcCoef := 1 - T;

  FMaxFc := MinF(MaxFcFraction * FRateInt, 30000);

  FInX1 := 0;
  FInY1 := 0;
  FDcX1 := 0;
  FDcY1 := 0;
  FGate := False;
  FAccent := False;
  FSliding := False;
  FAccentLight := False;
  FSlideLight := False;
  FNumHeld := 0;

  // The knobs jump to the first settings given after this rather than gliding there from
  // whatever was set before.
  UpdateTargets;
  FPrimed := False;
end;

procedure TEngine.SetSettings(const S: TSettings);
begin
  FSettings := S;
  UpdateTargets;
end;

procedure TEngine.UpdateTargets;
var
  Env, V, Span: Single;
begin
  Env := Panel(FSettings.EnvMod);
  Span := CutoffHi / CutoffLo;                      // cutoffHi / cutoffLo, in float
  FTgt.CutoffLog := Log2F(CutoffLo) + Panel(FSettings.Cutoff) * Log2F(Span) - EnvDip * Env;
  FTgt.EnvOct := EnvOctaves * Env;
  FTgt.K := KMax * Panel(FSettings.Res);
  FTgt.ResPot := Panel(FSettings.Res);
  FTgt.AccentOct := AccentOctaves * Panel(FSettings.Accent);
  FTgt.AccentGain := AccentVca * Panel(FSettings.Accent);

  V := Panel(FSettings.Volume);
  FTgt.Volume := VolumeCurve * V * V;

  FMeg.SetDecay(ExpLaw(Panel(FSettings.Decay), DecayShortest, DecayLongest));

  FTuneOct := FSettings.Tune / 1200;

  if not FPrimed then
  begin
    FCur := FTgt;
    FVolume := FTgt.Volume;
    FPrimed := True;
  end;
end;

{ ---- keyboard ---- }

procedure TEngine.NoteOn(Note, Velocity: Integer);
var
  Slide: Boolean;
begin
  if (Note < 0) or (Note > 127) then
    Exit;
  if Velocity <= 0 then
  begin
    NoteOff(Note);
    Exit;
  end;

  Slide := (FNumHeld > 0) and FGate;
  RemoveHeld(Note);
  FHeld[FNumHeld] := Note;
  Inc(FNumHeld);

  FAccent := Velocity >= AccentVelocity;
  Play(Note, Slide);
end;

procedure TEngine.NoteOff(Note: Integer);
begin
  RemoveHeld(Note);

  if FNumHeld = 0 then
  begin
    FGate := False;
    FVeg.Release;   // the MEG goes on decaying as it was: it never looks at the gate
    FAccentLight := False;
    FSlideLight := False;
  end
  else if Note = FKey then
    Play(FHeld[FNumHeld - 1], True);   // back to the note still held
end;

procedure TEngine.AllNotesOff;
begin
  FNumHeld := 0;
  FGate := False;
  FVeg.Release;
  FAccentLight := False;
  FSlideLight := False;
end;

procedure TEngine.Play(Note: Integer; Slide: Boolean);
begin
  FKey := Note;
  FKeyTarget := Note - 69;
  FKeyTarget := FKeyTarget / 12;
  FSliding := Slide;

  if not Slide then
  begin
    FKeyCv := FKeyTarget;
    FMeg.Trigger;
    FVeg.Trigger;
  end;

  FGate := True;
  FAccentLight := FAccent;
  FSlideLight := Slide;
end;

procedure TEngine.RemoveHeld(Note: Integer);
var
  I, J: Integer;
begin
  J := 0;
  for I := 0 to FNumHeld - 1 do
    if FHeld[I] <> Note then
    begin
      FHeld[J] := FHeld[I];
      Inc(J);
    end;
  FNumHeld := J;
end;

{ ---- audio ---- }

function TEngine.Tick: Single;
var
  U, Pitch, Dt, Osc, Coupled, M, AccentIn, Swept, FLog, Fc, G, Filtered, Amp, Noise, Arg: Single;
begin
  FCur.CutoffLog := FCur.CutoffLog + (FTgt.CutoffLog - FCur.CutoffLog) * FSmoothCoef;
  FCur.EnvOct := FCur.EnvOct + (FTgt.EnvOct - FCur.EnvOct) * FSmoothCoef;
  FCur.K := FCur.K + (FTgt.K - FCur.K) * FSmoothCoef;
  FCur.ResPot := FCur.ResPot + (FTgt.ResPot - FCur.ResPot) * FSmoothCoef;
  FCur.AccentOct := FCur.AccentOct + (FTgt.AccentOct - FCur.AccentOct) * FSmoothCoef;
  FCur.AccentGain := FCur.AccentGain + (FTgt.AccentGain - FCur.AccentGain) * FSmoothCoef;

  // slide: an RC on the pitch CV - fast at first, slowing as it arrives
  if FSliding then
    FKeyCv := FKeyCv + (FKeyTarget - FKeyCv) * FSlideCoef
  else
    FKeyCv := FKeyTarget;

  // ---- the analog
  // Thermal drift: a couple of cents, wandering over seconds; and the expo converter's own
  // noise, a fraction of a cent.
  Dec(FDriftCountdown);
  if FDriftCountdown <= 0 then
  begin
    U := FRng.Uniform;
    U := FRateInt * (DriftMin + DriftSpread * U);
    FDriftCountdown := Trunc(U);
    FDriftTarget := FRng.Noise * DriftDepth;
  end;
  FDrift := FDrift + (FDriftTarget - FDrift) * FDriftCoef;
  Noise := FRng.Noise;
  FJitter := FJitter + (Noise * JitterDepth - FJitter) * FJitterCoef;

  // ---- VCO
  Pitch := FKeyCv + FTuneOct + FBend * BendOctaves + FDrift + FJitter;
  Dt := MinF(A4 * Exp2F(Pitch) / FRateInt, MaxDt);

  Osc := FVco.Process(Dt, FSettings.Wave);

  Coupled := Osc - FInX1 + FInCoef * FInY1;
  FInX1 := Osc;
  FInY1 := Coupled;

  // ---- envelopes and accent
  M := FMeg.Process(FAccentDecayCoef, FAccent);
  if FAccent then
    AccentIn := M
  else
    AccentIn := 0;
  Swept := FSweep.Process(AccentIn, FCur.ResPot);

  // ---- VCF
  FLog := FCur.CutoffLog + M * FCur.EnvOct + Swept * FCur.AccentOct;
  Fc := Clamp(Exp2F(FLog), MinFc, FMaxFc);
  FLastFc := Fc;
  Arg := PiF * Fc;
  G := TanF(Arg / FRateInt);

  // A trace of thermal noise at the input, so the ladder rings from silence as the real
  // one does.
  Noise := FRng.Noise;
  Filtered := FVcf.Process(Drive * Coupled + InputNoise * Noise, G, FCur.K)
            * (1 + Makeup * FCur.K) / Drive;

  // ---- VCA
  Amp := FVeg.Process * (1 + FCur.AccentGain * AccentIn);
  Result := SoftClip(Filtered * Amp);
end;

procedure TEngine.Render(Output: PSingle; NumSamples: Integer);
var
  Out_: PSampleArray;
  I, R: Integer;
  Y, Hp: Single;
begin
  Out_ := PSampleArray(Output);
  for I := 0 to NumSamples - 1 do
  begin
    for R := 1 to FFactor do
      FDecimator.Push(Tick);

    Y := FDecimator.Output;

    Hp := Y - FDcX1 + FDcCoef * FDcY1;
    FDcX1 := Y;
    FDcY1 := Hp;

    FVolume := FVolume + (FTgt.Volume - FVolume) * FVolumeCoef;
    Out_^[I] := Hp * FVolume;
  end;
end;

initialization
  BendOctaves := 2;
  BendOctaves := BendOctaves / 12;
end.
