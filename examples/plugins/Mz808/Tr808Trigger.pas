// Mz808 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/TR808/Trigger.h.

unit Tr808Trigger;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  Tr808Dsp;

//
// How a sound starts on the 808. The CPU raises a common trigger, whose height is the
// accent - ACCENT sets how much higher an accented step's is - and ANDs it with the
// instrument's own data line. Each voice gets a 1 ms pulse at that height and makes
// everything else from it: its envelope, its kick to the oscillator, its pitch sweep.
// So accent is not a gain at the output. It is a taller pulse into circuits that do not
// answer to it linearly, which is why an accented hit is a different sound, not just a
// louder one.
//
// Heights here are in units of the unaccented trigger. The cymbal analysis gives the
// accented common trigger as 7 to 14 V by the ACCENT pot; taking the unaccented one as the
// bottom of that, an accent is 1x to 2x. That the unaccented height equals the bottom of
// the ACCENT range is inferred, not stated.
//
function TriggerHeight(Accented: Boolean; AccentPanel: Single): Single;

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
    function Level: Single; inline;
  end;

  //
  // The pulse shaper in front of each bridged-T: a high shelf that passes the pulse's
  // rising edge whole and a fraction of its flat top, then a diode that shaves off most of
  // the swing below ground on the falling edge. The edges are what kick the resonator, so
  // shaving the falling one keeps it from cancelling the rising one's kick.
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
    procedure Reset; inline;
  end;

  //
  // A trigger-driven envelope generator: a capacitor charged through a diode by the
  // (slightly smoothed) pulse while it is high, then discharged through a resistor. So it
  // rises over the pulse's millisecond, holds its top, and falls away as an RC curve -
  // and a new hit charges it from wherever it had fallen to rather than from zero.
  //
  TEnvelope = record
  private
    FFs, FAttackCoef, FFall: Single;
    FSmoothed, FV: Single;
  public
    procedure Init;
    procedure Prepare(SampleRate: Single);
    procedure SetDecay(TauSeconds: Single);
    function Process(Pulse: Single): Single;
    function Value: Single; inline;
    procedure Reset; inline;
  end;

implementation

const
  PulseWidth: Single = 0.001;        // seconds
  ShaperTau: Single = 0.0004;
  FlatTop: Single = 0.3;             // how much of the top gets through
  DiodeLeak: Single = 0.15;          // how much below ground does
  AttackTau: Single = 0.0001;        // the attack smoother, ~0.1 ms (cymbal analysis)
  FirstDecay: Single = 0.1;

function TriggerHeight(Accented: Boolean; AccentPanel: Single): Single;
begin
  if Accented then
    Result := 1 + Clamp(AccentPanel, 0, 10) / 10
  else
    Result := 1;
end;

{ TTriggerPulse }

procedure TTriggerPulse.Init;
begin
  FHeight := 0;
  FRemaining := 0;
end;

procedure TTriggerPulse.Fire(H, SampleRate: Single);
var
  Samples: Single;
begin
  FHeight := H;
  Samples := PulseWidth * SampleRate;
  FRemaining := LRound(Samples);
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

function TTriggerPulse.Level: Single;
begin
  Result := FHeight;
end;

{ TPulseShaper }

procedure TPulseShaper.Init;
begin
  FRc.Init;
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
  SetDecay(FirstDecay);
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

end.
