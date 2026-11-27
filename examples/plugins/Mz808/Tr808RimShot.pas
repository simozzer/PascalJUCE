// Mz808 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/TR808/RimShot.h.

unit Tr808RimShot;

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
  // RIM SHOT / CLAVES: one LEVEL.
  //
  // One circuit, switched, so each cuts the other off.
  //
  //  - CLAVES: a single bridged-T at about 2.5 kHz, kicked and left to ring, and passed to
  //    the output unchanged.
  //  - RIM SHOT: two bridged-Ts, about 455 Hz and 1667 Hz, kicked together. Their sum goes
  //    through a transistor VCA on a very short envelope, overdriven, then a high pass. The
  //    hard edge where the VCA clips is the crack.
  //
  // The three centres are published estimates; ring times, the VCA's drive and the high
  // pass are reasoned.
  //
  TRimShot = record
  private
    FFs: Single;
    FClaves: Boolean;
    FPulse: TTriggerPulse;
    FShaper: TPulseShaper;
    FRimLow, FRimHigh, FClave: TBridgedT;
    FVcaEnv: TEnvelope;
    FHp: TSvf;
  public
    procedure Init;
    procedure Prepare(SampleRate: Single);
    procedure Trigger(Height: Single; AsClaves: Boolean);
    function Process: Single;
    function Quiet: Boolean;
    procedure Reset;
  end;

implementation

const
  RimDrive = 2.5;
  RimGain = 0.75;
  ClaveDrive = 1;
  ClaveGain: Single = 0.85;

  // Single literals the C++ writes with an f (see Tr808Dsp)
  ShaperTau: Single = 0.0002;
  RimLowTau: Single = 0.008;
  RimHighTau: Single = 0.005;
  ClaveTau: Single = 0.011;
  VcaDecay: Single = 0.0045;
  HpQ: Single = 0.7;
  RimHighMix: Single = 1.4;
  Silence: Single = 1.0e-6;
  EnvSilence: Single = 1.0e-5;

{ TRimShot }

procedure TRimShot.Init;
begin
  FFs := 48000;
  FClaves := False;
  FPulse.Init;
  FShaper.Init;
  FRimLow.Init;
  FRimHigh.Init;
  FClave.Init;
  FVcaEnv.Init;
  FHp.Init;
end;

procedure TRimShot.Prepare(SampleRate: Single);
begin
  FFs := SampleRate;
  FShaper.Prepare(FFs, ShaperTau);
  FRimLow.Prepare(FFs);
  FRimHigh.Prepare(FFs);
  FClave.Prepare(FFs);
  FRimLow.SetTo(455, RimLowTau);
  FRimHigh.SetTo(1667, RimHighTau);
  FClave.SetTo(2500, ClaveTau);
  FVcaEnv.Prepare(FFs);
  FVcaEnv.SetDecay(VcaDecay);
  FHp.Prepare(FFs);
  FHp.Setup(320, HpQ);
  Reset;
end;

procedure TRimShot.Trigger(Height: Single; AsClaves: Boolean);
begin
  FClaves := AsClaves;
  FPulse.Fire(Height, FFs);
end;

function TRimShot.Process: Single;
var
  P, S, Lo, Hi, Ring, E, Cracked: Single;
begin
  P := FPulse.Next;
  S := FShaper.Process(P);

  if FClaves then
  begin
    FRimLow.Process(0);
    FRimHigh.Process(0);
    Exit(FClave.Process(ClaveDrive * S) * ClaveGain);
  end;

  FClave.Process(0);
  Lo := FRimLow.Process(S);
  Hi := FRimHigh.Process(S);
  Ring := Lo + RimHighMix * Hi;
  E := FVcaEnv.Process(P);
  Cracked := E * SoftClip(Ring * RimDrive);
  FHp.Process(Cracked);
  Result := FHp.Hp * RimGain;
end;

function TRimShot.Quiet: Boolean;
begin
  Result := not FPulse.High and (FRimLow.Energy + FRimHigh.Energy + FClave.Energy < Silence)
    and (FVcaEnv.Value < EnvSilence);
end;

procedure TRimShot.Reset;
begin
  FShaper.Reset;
  FRimLow.Reset;
  FRimHigh.Reset;
  FClave.Reset;
  FVcaEnv.Reset;
  FHp.Reset;
end;

end.
