// MzPCF - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// PcfEnvelope - the Object Pascal port of pcf::Envelope (Source/PCF/Pcf.h, Pcf.cpp), and
// of the one-pole coefficient its attack and the filter's smoothing use (follow). MzPCD
// plays its distortion with the same envelope.
//
// Single and Double exactly where the C++ has float and double (see PcfMath).

unit PcfEnvelope;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

type
  //
  // The envelope that plays the filter: struck to a step's level, dying away by DECAY, and
  // rounded by a third of a millisecond's attack so a strike opens the filter without a
  // click.
  //
  // A record: call Init once (the C++ member initialisers), then Prepare.
  //
  TPcfEnvelope = record
  private
    FFs: Double;
    FEnv, FShaped: Single;
    FAttackCoef, FDecayCoef: Single;
  public
    procedure Init;
    procedure Prepare(SampleRate: Double);
    procedure Reset; inline;

    procedure SetDecay(Decay: Single);   // 0 to 1: 15 ms to 1.5 s
    procedure Strike(Level: Single); inline;

    function Next: Single; inline;
    function Value: Single; inline;
  end;

// The one-pole coefficient that gets 63% of the way in Seconds (Pcf.cpp's follow).
function PcfFollow(Seconds: Single; Rate: Double): Single;

implementation

uses
  PcfMath;

const
  AttackSeconds: Single = 0.0003;    // 0.0003f
  DefaultDecay: Single = 0.35;       // 0.35f
  ShortestDecay: Single = 0.015;     // 0.015f: 15 ms ...
  DecayRange = 100;                  // ... to 1.5 s

function PcfFollow(Seconds: Single; Rate: Double): Single;
var
  D: Double;
  E: Single;
begin
  D := Seconds;
  D := D * Rate;
  E := ExpD(-1.0 / D);               // (float) std::exp(-1.0 / (seconds * rate))
  Result := 1 - E;
end;

procedure TPcfEnvelope.Init;
begin
  FFs := 48000.0;
  FEnv := 0;
  FShaped := 0;
  FAttackCoef := 0;
  FDecayCoef := 0;
end;

procedure TPcfEnvelope.Prepare(SampleRate: Double);
begin
  if SampleRate > 0.0 then
    FFs := SampleRate
  else
    FFs := 48000.0;
  FAttackCoef := PcfFollow(AttackSeconds, FFs);
  SetDecay(DefaultDecay);
  Reset;
end;

procedure TPcfEnvelope.Reset;
begin
  FEnv := 0;
  FShaped := 0;
end;

procedure TPcfEnvelope.SetDecay(Decay: Single);
var
  Seconds: Single;
  D: Double;
begin
  Seconds := ShortestDecay * PowF(DecayRange, ClampF(Decay, 0, 1));   // 15 ms to 1.5 s
  D := Seconds;
  D := D * FFs;
  FDecayCoef := ExpD(-1.0 / D);
end;

procedure TPcfEnvelope.Strike(Level: Single);
begin
  FEnv := Level;
end;

function TPcfEnvelope.Next: Single;
begin
  FShaped := FShaped + (FEnv - FShaped) * FAttackCoef;
  FEnv := FEnv * FDecayCoef;
  Result := FShaped;
end;

function TPcfEnvelope.Value: Single;
begin
  Result := FShaped;
end;

end.
