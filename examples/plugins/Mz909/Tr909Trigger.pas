// Mz909 - an emulation of the TR-909 Rhythm Composer
// Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/TR909/Trigger.h.

unit Tr909Trigger;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  Tr909Dsp;

//
// How a sound starts on the 909. As on the 808 before it, the CPU strikes each instrument
// with a short trigger pulse, and an accented step is a taller pulse: the panel's ACCENT
// knob sets how much taller. Every voice makes its envelopes - and the analog ones their
// pitch sweeps - from that pulse, so an accent changes how a sound is struck, not just a
// gain at the output.
//
// Heights are in units of the unaccented trigger: an accent is 1x to 2x by the ACCENT knob.
// That range is reasoned from the sound, not measured.
//
function TriggerHeight(Accented: Boolean; AccentPanel: Single): Single;

// The sampled voices' VCA, after the DAC, answers an accent harder than the drums' output
// stages do: at full ACCENT an accented hit is 10 dB up, as measured on a 909-style machine.
function SampleAccent(Height: Single): Single;

type
  TTriggerPulse = record
  private
    FHeight: Single;
    FRemaining: Integer;
  public
    procedure Init;
    procedure Fire(H, SampleRate: Single);
    function Next: Single; inline;
    function High: Boolean; inline;
  end;

  //
  // A trigger-driven envelope generator: a capacitor charged through a diode by the pulse
  // while it is high, then discharged through a resistor. It rises over the pulse's
  // millisecond, falls away as an RC curve, and a new hit charges it from wherever it had
  // fallen to rather than from zero.
  //
  TEnvelope = record
  private
    FFs, FAttackCoef, FFall: Single;
    FSmoothed, FV: Single;
  public
    procedure Init;
    procedure Prepare(SampleRate: Single);
    procedure SetDecay(TauSeconds: Single);
    function Process(Pulse: Single): Single; inline;
    function Value: Single; inline;
    procedure Reset;
  end;

  //
  // The pulse shaper in front of a resonator: a high shelf that passes the pulse's rising
  // edge whole and a fraction of its flat top, then a diode that shaves most of the swing
  // below ground off the falling edge, so that edge does not cancel the rising one's kick.
  //
  TPulseShaper = record
  private
    FRc: TOnePole;
    FCoef: Single;
  public
    procedure Init;
    procedure Prepare(SampleRate: Single); overload;
    procedure Prepare(SampleRate, TauSeconds: Single); overload;
    function Process(P: Single): Single;
    procedure Reset;
  end;

implementation

const
  PulseWidth: Single = 0.001;      // seconds
  AttackTau: Single = 0.0001;
  DefaultDecay: Single = 0.1;
  ShaperTau: Single = 0.0003;
  FlatTop: Single = 0.3;
  DiodeLeak: Single = 0.15;
  AccentExponent: Single = 1.661;

function TriggerHeight(Accented: Boolean; AccentPanel: Single): Single;
begin
  if Accented then
    Result := 1 + Clamp(AccentPanel, 0, 10) / 10
  else
    Result := 1;
end;

function SampleAccent(Height: Single): Single;
begin
  Result := PowF(Height, AccentExponent);
end;

{ TTriggerPulse }

procedure TTriggerPulse.Init;
begin
  FHeight := 0;
  FRemaining := 0;
end;

procedure TTriggerPulse.Fire(H, SampleRate: Single);
begin
  FHeight := H;
  FRemaining := LRound(PulseWidth * SampleRate);
end;

function TTriggerPulse.Next: Single;
begin
  if FRemaining <= 0 then
    Exit(0);
  Dec(FRemaining);
  Result := FHeight;
end;

function TTriggerPulse.High: Boolean;
begin
  Result := FRemaining > 0;
end;

{ TEnvelope }

procedure TEnvelope.Init;
begin
  FFs := 48000;
  FAttackCoef := 1;
  FFall := 0;
  FSmoothed := 0;
  FV := 0;
end;

procedure TEnvelope.Prepare(SampleRate: Single);
begin
  FFs := SampleRate;
  FAttackCoef := OnePoleCoef(AttackTau, FFs);
  SetDecay(DefaultDecay);
end;

procedure TEnvelope.SetDecay(TauSeconds: Single);
begin
  FFall := DecayCoef(TauSeconds, FFs);
end;

function TEnvelope.Process(Pulse: Single): Single;
begin
  FSmoothed := FSmoothed + (Pulse - FSmoothed) * FAttackCoef;
  if FSmoothed > FV then
    FV := FSmoothed
  else
    FV := FV * FFall;
  Result := FV;
end;

function TEnvelope.Value: Single;
begin
  Result := FV;
end;

procedure TEnvelope.Reset;
begin
  FV := 0;
  FSmoothed := 0;
end;

{ TPulseShaper }

procedure TPulseShaper.Init;
begin
  FRc.Z := 0;
  FCoef := 1;
end;

procedure TPulseShaper.Prepare(SampleRate: Single);
begin
  Prepare(SampleRate, ShaperTau);
end;

procedure TPulseShaper.Prepare(SampleRate, TauSeconds: Single);
begin
  FCoef := OnePoleCoef(TauSeconds, SampleRate);
end;

function TPulseShaper.Process(P: Single): Single;
var
  Settled, S: Single;
begin
  Settled := FRc.LowPass(P, FCoef);
  S := (P - Settled) + FlatTop * Settled;
  if S >= 0 then
    Result := S
  else
    Result := S * DiodeLeak;
end;

procedure TPulseShaper.Reset;
begin
  FRc.Reset;
end;

end.
