// Mz303 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of source/TB303/Envelopes.h.

unit Tb303Envelopes;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

type
  //
  // THE ENVELOPES
  //
  // The 303 has two, and neither is an ADSR.
  //
  // The MEG, the filter's envelope, is a decay and nothing else: a note charges its capacitor
  // almost at once and it drains away through the DECAY pot, whatever the gate does. An
  // accented note drains it through a fixed resistor instead, at the pot's fastest - so
  // accents are always short, sharp blips, however long DECAY is set.
  //
  // The VEG, the VCA's, has no knob at all. It rises in a few milliseconds, decays slowly
  // over seconds while the gate is held - a long held note fades away - and when the gate
  // closes it falls in a few milliseconds more. Both its times are fixed in the circuit.
  //
  // Both are RC: every segment an exponential approach, and a new note restarts them from
  // wherever they are.
  //
  TMeg = record
  private
    FRate: Single;
    FAttacking: Boolean;
    FLevel: Single;
    FAttackCoef, FDecayCoef: Single;
  public
    procedure Init;
    procedure SetSampleRate(R: Single);
    // seconds for the envelope to fall to 5% - about three time constants
    procedure SetDecay(Seconds: Single);
    procedure Trigger; inline;
    procedure Reset;
    function Process(AccentDecayCoef: Single; Accented: Boolean): Single;
    property Value: Single read FLevel;
  end;

  TVegStage = (vsIdle, vsAttack, vsDecay, vsRelease);

  TVeg = record
  private
    FStage: TVegStage;
    FLevel: Single;
    FAttackCoef, FDecayCoef, FReleaseCoef: Single;
  public
    procedure Init;
    procedure SetSampleRate(R: Single);
    procedure Trigger; inline;
    procedure Release; inline;
    procedure Reset;
    function Process: Single;
    function Idle: Boolean; inline;
  end;

  //
  // THE ACCENT CIRCUIT
  //
  // An accented note sends the MEG, scaled by the ACCENT knob, to the filter's cutoff and to
  // the VCA - on top of what ENV MOD sends. But on its way to the filter it passes a capacitor,
  // and the second half of the RESONANCE pot, ganged with the first, decides how much of it
  // goes through the capacitor rather than round it.
  //
  // At low resonance it goes round: each accent is a sharp blip on the cutoff, the same every
  // time. At high resonance most of it is smoothed by the capacitor, which charges more slowly
  // than the blip and drains more slowly still. So an accent swells rather than spikes, its
  // peak arriving late; and accents close together find the capacitor still charged from the
  // last one and climb higher each time. That climbing, resonant "wow" on a run of accents is
  // the most recognisable sound the 303 makes.
  //
  TAccentSweep = record
  private
    FCap: Single;
    FChargeCoef, FDrainCoef: Single;
  public
    procedure Init;
    procedure SetSampleRate(R: Single);
    procedure Reset;
    // AIn: the MEG times ACCENT, on accented notes, else 0; Res: the RESONANCE knob, 0..1.
    function Process(AIn, Res: Single): Single;
    property Charge: Single read FCap;
  end;

implementation

uses
  Tb303Dsp;

const
  // MEG: a fraction of a millisecond to the top, heading for a little past it
  MegAttackTau: Single = 0.0003;
  MegOvershoot: Single = 1.2;

  // VEG: reasoned from the circuit rather than measured - a few milliseconds up, an e-fold
  // every couple of seconds held, a few milliseconds down.
  VegAttackTau: Single = 0.0015;
  VegOvershoot: Single = 1.3;
  VegDecayTau = 2;
  VegReleaseTau: Single = 0.0025;
  VegFloor: Single = 1.0e-6;

  // The accent capacitor charges in tens of milliseconds and drains over a few hundred, so a
  // run of sixteenths at 120 BPM (125 ms apart) stacks up. CapGain makes up the level the
  // smoothing loses, so a lone accent sweeps about as far either way.
  ChargeTau: Single = 0.04;
  DrainTau: Single = 0.3;
  CapGain: Single = 1.6;

{ TMeg }

procedure TMeg.Init;
begin
  FRate := 44100;
  FAttacking := False;
  FLevel := 0;
  FAttackCoef := 1;
  FDecayCoef := 1;
end;

procedure TMeg.SetSampleRate(R: Single);
begin
  FRate := R;
  FAttackCoef := OnePoleCoef(MegAttackTau, R);
end;

procedure TMeg.SetDecay(Seconds: Single);
begin
  FDecayCoef := OnePoleCoef(Seconds / 3, FRate);
end;

procedure TMeg.Trigger;
begin
  FAttacking := True;
end;

procedure TMeg.Reset;
begin
  FAttacking := False;
  FLevel := 0;
end;

function TMeg.Process(AccentDecayCoef: Single; Accented: Boolean): Single;
begin
  if FAttacking then
  begin
    FLevel := FLevel + (MegOvershoot - FLevel) * FAttackCoef;
    if FLevel >= 1 then
    begin
      FLevel := 1;
      FAttacking := False;
    end;
  end
  else if Accented then
    FLevel := FLevel - FLevel * AccentDecayCoef
  else
    FLevel := FLevel - FLevel * FDecayCoef;
  Result := FLevel;
end;

{ TVeg }

procedure TVeg.Init;
begin
  FStage := vsIdle;
  FLevel := 0;
  FAttackCoef := 1;
  FDecayCoef := 1;
  FReleaseCoef := 1;
end;

procedure TVeg.SetSampleRate(R: Single);
begin
  FAttackCoef := OnePoleCoef(VegAttackTau, R);
  FDecayCoef := OnePoleCoef(VegDecayTau, R);
  FReleaseCoef := OnePoleCoef(VegReleaseTau, R);
end;

procedure TVeg.Trigger;
begin
  FStage := vsAttack;
end;

procedure TVeg.Release;
begin
  if FStage <> vsIdle then
    FStage := vsRelease;
end;

procedure TVeg.Reset;
begin
  FStage := vsIdle;
  FLevel := 0;
end;

function TVeg.Process: Single;
begin
  case FStage of
    vsAttack:
      begin
        FLevel := FLevel + (VegOvershoot - FLevel) * FAttackCoef;
        if FLevel >= 1 then
        begin
          FLevel := 1;
          FStage := vsDecay;
        end;
      end;
    vsDecay:
      FLevel := FLevel - FLevel * FDecayCoef;
    vsRelease:
      begin
        FLevel := FLevel - FLevel * FReleaseCoef;
        if FLevel < VegFloor then
        begin
          FLevel := 0;
          FStage := vsIdle;
        end;
      end;
  end;
  Result := FLevel;
end;

function TVeg.Idle: Boolean;
begin
  Result := FStage = vsIdle;
end;

{ TAccentSweep }

procedure TAccentSweep.Init;
begin
  FCap := 0;
  FChargeCoef := 1;
  FDrainCoef := 1;
end;

procedure TAccentSweep.SetSampleRate(R: Single);
begin
  FChargeCoef := OnePoleCoef(ChargeTau, R);
  FDrainCoef := OnePoleCoef(DrainTau, R);
end;

procedure TAccentSweep.Reset;
begin
  FCap := 0;
end;

function TAccentSweep.Process(AIn, Res: Single): Single;
begin
  if AIn > FCap then
    FCap := FCap + (AIn - FCap) * FChargeCoef
  else
    FCap := FCap + (AIn - FCap) * FDrainCoef;
  Result := (1 - Res) * AIn + Res * CapGain * FCap;
end;

end.
