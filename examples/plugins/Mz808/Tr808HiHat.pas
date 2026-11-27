// Mz808 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/TR808/HiHat.h.

unit Tr808HiHat;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  Tr808Dsp, Tr808Trigger, Tr808Metal;

type
  //
  // OPEN HIHAT: LEVEL, DECAY. CLOSED HIHAT: LEVEL.
  //
  // The six oscillators again, through a band pass high in the cymbal's range, a swing-type
  // VCA and a high pass. Open and closed share the metal and the VCA, and differ in how fast
  // the VCA's envelope is let go: the open hat's through DECAY, the closed hat's through a
  // short fixed resistor. So a closed hat on top of an open one chokes it, as on the
  // hardware - one envelope, discharged the fast way.
  //
  // Each has its own LEVEL after the VCA; the closed hat's sets the level of the whole sound
  // from the moment it chokes. The structure is the circuit's; the filters and times are
  // reasoned.
  //
  THiHat = record
  private
    FFs: Single;
    FPulse: TTriggerPulse;
    FBp, FHp: TSvf;
    FEnv: TEnvelope;
    FOpenTau: Single;
    FOpen: Boolean;
  public
    procedure Init;
    procedure Prepare(SampleRate: Single);
    procedure SetKnobs(OpenDecayPanel: Single);
    procedure Trigger(Height: Single; AsOpen: Boolean);
    function IsOpen: Boolean; inline;
    function Process(const Bank: TMetalBank): Single;
    function Quiet: Boolean;
    procedure Reset;
  end;

implementation

const
  ClosedTau: Single = 0.013;
  Gain: Single = 1.3;

  // Single literals the C++ writes with an f (see Tr808Dsp)
  BpQ: Single = 1.4;
  HpQ: Single = 0.9;
  VcaDrive: Single = 1.8;
  DecayShortest: Single = 0.045;
  DecayLongest: Single = 0.45;
  FirstOpenTau: Single = 0.15;
  EnvSilence: Single = 1.0e-5;

{ THiHat }

procedure THiHat.Init;
begin
  FFs := 48000;
  FPulse.Init;
  FBp.Init;
  FHp.Init;
  FEnv.Init;
  FOpenTau := FirstOpenTau;
  FOpen := False;
end;

procedure THiHat.Prepare(SampleRate: Single);
begin
  FFs := SampleRate;
  FBp.Prepare(FFs);
  FBp.Setup(7100, BpQ);
  FHp.Prepare(FFs);
  FHp.Setup(7000, HpQ);
  FEnv.Prepare(FFs);
  SetKnobs(4);
  Reset;
end;

procedure THiHat.SetKnobs(OpenDecayPanel: Single);
begin
  FOpenTau := ExpLaw(OpenDecayPanel / 10, DecayShortest, DecayLongest);
  if FOpen then
    FEnv.SetDecay(FOpenTau);
end;

procedure THiHat.Trigger(Height: Single; AsOpen: Boolean);
begin
  FOpen := AsOpen;
  if FOpen then
    FEnv.SetDecay(FOpenTau)
  else
    FEnv.SetDecay(ClosedTau);
  FPulse.Fire(Height, FFs);
end;

function THiHat.IsOpen: Boolean;
begin
  Result := FOpen;
end;

function THiHat.Process(const Bank: TMetalBank): Single;
var
  P, E: Single;
begin
  P := FPulse.Next;
  FBp.Process(Bank.Sum);
  E := FEnv.Process(P);
  FHp.Process(SwingVca(FBp.BandNorm, E, VcaDrive));
  Result := FHp.Hp * Gain;
end;

function THiHat.Quiet: Boolean;
begin
  Result := not FPulse.High and (FEnv.Value < EnvSilence);
end;

procedure THiHat.Reset;
begin
  FBp.Reset;
  FHp.Reset;
  FEnv.Reset;
end;

end.
