// Mz808 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/TR808/BassDrum.h.

unit Tr808BassDrum;

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
  // BASS DRUM: LEVEL, TONE, DECAY.
  //
  // After Werner, Abel and Smith's analysis of the circuit (DAFx-14):
  //
  //  - The 1 ms trigger goes through the pulse shaper into a bridged-T whose centre, with the
  //    attack circuit idle, is Roland's typical 56 Hz.
  //  - The trigger also fires an envelope generator (Q41, Q42), which for the length of the
  //    pulse and about 5 ms after it grounds part of the bridged-T (Q43), raising its centre
  //    by more than an octave and its Q with it. That is too brief to hear as pitch - under
  //    one cycle at the higher frequency - but it is the punch and crispness of the attack.
  //  - As that envelope falls, C39, R161 and D52 high-pass it into a retriggering pulse that
  //    kicks the bridged-T again at its normal centre, so the note does not drop in level
  //    when the centre comes down.
  //  - Leakage through R161 holds the centre a little high for a while after: the 808's pitch
  //    "sigh", which a long DECAY lets you hear.
  //  - DECAY is the resistance in the feedback buffer that keeps the bridged-T ringing. Its
  //    diodes clip the feedback when the ring is large, so a loud (accented) hit loses its
  //    top faster and settles into the same tail - the bloom of an accented 808 kick.
  //  - TONE is a passive low pass on the way out: the click, not the boom.
  //
  TBassDrum = record
  private
    FFs: Single;
    FPulse: TTriggerPulse;
    FShaper: TPulseShaper;
    FRes: TBridgedT;
    FOut: TOnePole;

    FEnvUp, FEnvDown, FRpCoef, FSighFall, FToneCoef: Single;
    FKHeld, FKShort: Single;
    FEnv, FRpLag, FSigh: Single;
  public
    procedure Init;
    procedure Prepare(SampleRate: Single);
    procedure SetKnobs(DecayPanel, TonePanel: Single);
    procedure Trigger(Height: Single);
    function Process: Single;
    function Quiet: Boolean;
    procedure Reset;
  end;

implementation

const
  Centre = 56;                          // Roland's typical tuning
  AttackShift: Single = 1.3;            // 2.3x the centre at the top of the attack
  AttackQ: Single = 0.4;                // and less damping with it
  SighDepth: Single = 0.045;            // per unit of trigger: under a semitone
  FeedbackKnee = 2;
  Drive: Single = 2.2;
  Retrigger = 2;
  ClickLeak: Single = 0.3;
  Gain = 1.75;

  // Single literals the C++ writes with an f (see Tr808Dsp)
  EnvUpTau: Single = 0.0001;
  EnvDownTau: Single = 0.0017;          // back to ground ~5 ms after the pulse
  RpTau: Single = 0.002;
  SighTau: Single = 0.11;
  DecayShortest: Single = 0.05;
  DecayLongest: Single = 0.75;
  ShortRing: Single = 0.03;
  ToneLowest = 180;
  ToneHighest = 6000;
  Silence: Single = 1.0e-6;

{ TBassDrum }

procedure TBassDrum.Init;
begin
  FFs := 48000;
  FPulse.Init;
  FShaper.Init;
  FRes.Init;
  FOut.Init;
  FEnvUp := 1;
  FEnvDown := 1;
  FRpCoef := 1;
  FSighFall := 0;
  FToneCoef := 1;
  FKHeld := 0.01;
  FKShort := 0.2;
  FEnv := 0;
  FRpLag := 0;
  FSigh := 0;
end;

procedure TBassDrum.Prepare(SampleRate: Single);
begin
  FFs := SampleRate;
  FRes.Prepare(FFs);
  FShaper.Prepare(FFs);
  FEnvUp := OnePoleCoef(EnvUpTau, FFs);
  FEnvDown := OnePoleCoef(EnvDownTau, FFs);
  FRpCoef := OnePoleCoef(RpTau, FFs);
  FSighFall := DecayCoef(SighTau, FFs);
  SetKnobs(5, 5);
  Reset;
end;

procedure TBassDrum.SetKnobs(DecayPanel, TonePanel: Single);
var
  Tau: Single;
begin
  Tau := ExpLaw(DecayPanel / 10, DecayShortest, DecayLongest);
  FRes.SetTo(Centre, Tau);
  FKHeld := FRes.Damping;
  FKShort := 1 / (PiF * Centre * ShortRing);
  FToneCoef := OnePoleCoef(TauOf(ExpLaw(TonePanel / 10, ToneLowest, ToneHighest)), FFs);
end;

procedure TBassDrum.Trigger(Height: Single);
begin
  FPulse.Fire(Height, FFs);
  FSigh := Height;
end;

function TBassDrum.Process: Single;
var
  P, S, Rp, Shift, Hz, Clipped, K, Y: Single;
begin
  P := FPulse.Next;
  S := FShaper.Process(P);

  // Q41/Q42, up with the pulse and back down a few milliseconds after it
  if P > FEnv then
    FEnv := FEnv + (P - FEnv) * FEnvUp
  else
    FEnv := FEnv + (P - FEnv) * FEnvDown;

  // C39/R161/D52: the retriggering pulse, while the envelope falls
  FRpLag := FRpLag + (FEnv - FRpLag) * FRpCoef;
  if FRpLag > FEnv then
    Rp := FRpLag - FEnv
  else
    Rp := 0;

  FSigh := FSigh * FSighFall;

  Shift := Clamp(FEnv, 0, 1);
  Hz := Centre * (1 + AttackShift * Shift) * (1 + SighDepth * FSigh);

  // the feedback buffer's diodes: a big ring is fed back less, so it decays faster
  Clipped := 1 - SoftClipGain(FRes.Svf.Bp / FeedbackKnee);
  K := FKHeld + (FKShort - FKHeld) * Clipped;
  K := K * (1 - AttackQ * Shift);

  FRes.Svf.Tune(Hz, K);
  Y := FRes.Process(Drive * S + Retrigger * Rp);

  Result := FOut.LowPass(Y + ClickLeak * S, FToneCoef) * Gain;
end;

function TBassDrum.Quiet: Boolean;
begin
  Result := not FPulse.High and (FRes.Energy < Silence) and (FEnv < Silence) and (Abs(FOut.Z) < Silence);
end;

procedure TBassDrum.Reset;
begin
  FRes.Reset;
  FShaper.Reset;
  FOut.Reset;
  FEnv := 0;
  FRpLag := 0;
  FSigh := 0;
end;

end.
