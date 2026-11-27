// Mz909 - an emulation of the TR-909 Rhythm Composer
// Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/TR909/RimShot.h.

unit Tr909RimShot;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  Tr909Dsp, Tr909Trigger;

type
  //
  // RIM SHOT: LEVEL.
  //
  // The 808's rim shot, carried over and sharpened: the shaped trigger kicks two high-Q
  // band passes - resonators, ringing at about 500 Hz and 1.7 kHz - whose sum goes through a
  // VCA overdriven on a very short envelope, then a high pass. The overdrive is the crack.
  //
  // The structure follows the 808's; the 909's pitches, times and filter are reasoned from
  // the sound, not measured.
  //
  TRimShot = record
  private
    FFs: Single;
    FPulse: TTriggerPulse;
    FShaper: TPulseShaper;
    FLow, FHigh, FHp: TSvf;
    FEnv: TEnvelope;
  public
    procedure Init;
    procedure Prepare(SampleRate: Single);
    procedure Trigger(Height: Single); inline;
    function Process: Single;
    function Quiet: Boolean;
    procedure Reset;
  end;

implementation

const
  Overdrive = 4;
  Gain: Single = 0.7;

  LowHz = 500;
  LowTau: Single = 0.010;
  HighHz = 1700;
  HighTau: Single = 0.006;
  EnvDecay: Single = 0.0045;
  HpHz = 350;
  HpQ: Single = 0.7;
  LowMix: Single = 0.7;
  Silent: Single = 1.0e-5;
  Rung: Single = 1.0e-6;

procedure TRimShot.Init;
begin
  FFs := 48000;
  FPulse.Init;
  FShaper.Init;
  FLow.Init;
  FHigh.Init;
  FHp.Init;
  FEnv.Init;
end;

procedure TRimShot.Prepare(SampleRate: Single);
begin
  FFs := SampleRate;
  FShaper.Prepare(FFs);
  FLow.Prepare(FFs);
  FLow.Setup(LowHz, PiF * LowHz * LowTau);      // (float) pi * 500.0f * 0.010f
  FHigh.Prepare(FFs);
  FHigh.Setup(HighHz, PiF * HighHz * HighTau);  // (float) pi * 1700.0f * 0.006f
  FEnv.Prepare(FFs);
  FEnv.SetDecay(EnvDecay);
  FHp.Prepare(FFs);
  FHp.Setup(HpHz, HpQ);
  Reset;
end;

procedure TRimShot.Trigger(Height: Single);
begin
  FPulse.Fire(Height, FFs);
end;

function TRimShot.Process: Single;
var
  P, S, Ring: Single;
begin
  P := FPulse.Next;
  S := FShaper.Process(P);

  Ring := LowMix * FLow.Process(S) + FHigh.Process(S);
  FHp.Process(SoftClip(Ring * FEnv.Process(P) * Overdrive));
  Result := FHp.Hp * Gain;
end;

function TRimShot.Quiet: Boolean;
begin
  Result := (not FPulse.High) and (FEnv.Value < Silent) and (FLow.Energy + FHigh.Energy + FHp.Energy < Rung);
end;

procedure TRimShot.Reset;
begin
  FShaper.Reset;
  FLow.Reset;
  FHigh.Reset;
  FEnv.Reset;
  FHp.Reset;
end;

end.
