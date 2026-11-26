// Mz101 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/SH101/Envelope.h.

unit Sh101Envelope;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

type
  TEnvelopeStage = (esIdle, esAttack, esDecay, esRelease);

  //
  // THE ENVELOPE
  //
  // An analog ADSR: a capacitor charged and discharged through resistors, so every segment
  // is an exponential approach rather than a line.
  //
  // The attack charges toward a voltage ABOVE the peak and is cut off by a comparator when it
  // gets there, so it arrives still moving fast - the attack is closer to a straight line than
  // an RC curve, and the turn into the decay is sharp. That corner is a good part of why the
  // 101's envelopes sound snappy. Decay and release are plain RC towards the sustain level
  // and towards zero.
  //
  // A retrigger starts the attack from wherever the capacitor is, not from zero. There is
  // nothing in the circuit to discharge it first.
  //
  TEnvelope = record
  private
    FRate: Single;
    FStage: TEnvelopeStage;
    FLevel: Single;
    FSustain: Single;
    FACoef, FDCoef, FRCoef: Single;
  public
    procedure Init;
    procedure SetSampleRate(R: Single);

    // Times as printed in the spec: attack to the peak, decay and release to within a few
    // percent of where they are heading.
    procedure SetTimes(AttackSeconds, DecaySeconds, SustainLevel, ReleaseSeconds: Single);

    procedure Trigger; inline;
    procedure Release; inline;
    procedure Reset;

    function Value: Single; inline;
    function Process: Single; inline;
  end;

implementation

uses
  Sh101Dsp;

const
  // The attack's target, as a multiple of the peak; AttackLog is how many time constants
  // it takes to get from 0 to 1 heading there.
  Overshoot: Single = 1.3;
  AttackLog: Single = 1.4663371;   // ln(1.3 / 0.3)
  Silent: Single = 1.0e-6;

procedure TEnvelope.Init;
begin
  FRate := 44100;
  FStage := esIdle;
  FLevel := 0;
  FSustain := 0.5;
  FACoef := 1;
  FDCoef := 1;
  FRCoef := 1;
end;

procedure TEnvelope.SetSampleRate(R: Single);
begin
  FRate := R;
end;

procedure TEnvelope.SetTimes(AttackSeconds, DecaySeconds, SustainLevel, ReleaseSeconds: Single);
begin
  FACoef := OnePoleCoef(AttackSeconds / AttackLog, FRate);
  FDCoef := OnePoleCoef(DecaySeconds / 3, FRate);
  FRCoef := OnePoleCoef(ReleaseSeconds / 3, FRate);
  FSustain := SustainLevel;
end;

procedure TEnvelope.Trigger;
begin
  FStage := esAttack;
end;

procedure TEnvelope.Release;
begin
  if FStage <> esIdle then
    FStage := esRelease;
end;

procedure TEnvelope.Reset;
begin
  FStage := esIdle;
  FLevel := 0;
end;

function TEnvelope.Value: Single;
begin
  Result := FLevel;
end;

function TEnvelope.Process: Single;
begin
  case FStage of
    esAttack:
      begin
        FLevel := FLevel + (Overshoot - FLevel) * FACoef;
        if FLevel >= 1 then
        begin
          FLevel := 1;
          FStage := esDecay;
        end;
      end;

    esDecay:
      FLevel := FLevel + (FSustain - FLevel) * FDCoef;

    esRelease:
      begin
        FLevel := FLevel - FLevel * FRCoef;
        if FLevel < Silent then
        begin
          FLevel := 0;
          FStage := esIdle;
        end;
      end;
  end;

  Result := FLevel;
end;

end.
