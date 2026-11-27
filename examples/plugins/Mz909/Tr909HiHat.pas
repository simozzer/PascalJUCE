// Mz909 - an emulation of the TR-909 Rhythm Composer
// Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/TR909/HiHat.h.

unit Tr909HiHat;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  Tr909Dsp, Tr909Trigger, Tr909Rom;

type
  //
  // HI HAT: LEVEL, CLOSED DECAY, OPEN DECAY.
  //
  // Two 6-bit recordings, one for each hat, through one DAC and one VCA. Each hit starts its
  // hat's recording from the top, and the VCA's envelope is let go through CLOSED DECAY or
  // OPEN DECAY by which hat was struck. So a closed hat on top of an open one chokes it: the
  // DAC switches to the closed recording and the VCA closes the fast way.
  //
  // The VCA has a threshold. Its envelope falls as an RC curve, but the gain is what is left
  // above the threshold, so a hat holds, then falls faster and faster, and stops dead. That
  // is the shape measured on a 909-style machine, for both hats - a closed hat dropping 41 dB
  // in its last 50 ms, an open one gone at a stroke near half a second. The knobs' ranges put
  // that machine's sounds at CLOSED DECAY 5 and OPEN DECAY 10.
  //
  THiHat = record
  private
    FFs: Single;
    FPulse: TTriggerPulse;
    FDac: TRomPlayer;
    FEnv: TEnvelope;
    FDc: TOnePole;
    FDcCoef, FClosedTau, FOpenTau, FLevel: Single;
    FOpen: Boolean;
  public
    procedure Init;
    procedure Prepare(SampleRate: Single);
    procedure SetPanel(ClosedDecayPanel, OpenDecayPanel: Single);
    procedure Trigger(Height: Single; AsOpen: Boolean);
    function Process: Single;
    function Quiet: Boolean;
    procedure Reset;
  end;

implementation

uses
  Tr909Roms;

const
  Threshold: Single = 0.3;
  Gain = 0.5;

  DcCorner = 30;
  ClosedLo: Single = 0.04;
  ClosedHi: Single = 0.36;
  OpenLo: Single = 0.06;
  OpenHi: Single = 0.40;
  Rung: Single = 1.0e-6;

procedure THiHat.Init;
begin
  FFs := 48000;
  FPulse.Init;
  FDac.Init;
  FEnv.Init;
  FDc.Z := 0;
  FDcCoef := 0;
  FClosedTau := 0.12;
  FOpenTau := 0.4;
  FLevel := 1;
  FOpen := False;
end;

procedure THiHat.Prepare(SampleRate: Single);
begin
  FFs := SampleRate;
  FDac.Prepare(FFs);
  FEnv.Prepare(FFs);
  FDcCoef := OnePoleCoef(TauOf(DcCorner), FFs);
  SetPanel(5, 10);
  Reset;
end;

procedure THiHat.SetPanel(ClosedDecayPanel, OpenDecayPanel: Single);
begin
  FClosedTau := ExpLaw(ClosedDecayPanel / 10, ClosedLo, ClosedHi);
  FOpenTau := ExpLaw(OpenDecayPanel / 10, OpenLo, OpenHi);
  if FOpen then
    FEnv.SetDecay(FOpenTau)
  else
    FEnv.SetDecay(FClosedTau);
end;

procedure THiHat.Trigger(Height: Single; AsOpen: Boolean);
begin
  FOpen := AsOpen;
  if FOpen then
    FEnv.SetDecay(FOpenTau)
  else
    FEnv.SetDecay(FClosedTau);
  FPulse.Fire(1, FFs);
  FLevel := SampleAccent(Height);
  if FOpen then
    FDac.Start(OpenHatRom)
  else
    FDac.Start(ClosedHatRom);
end;

function THiHat.Process: Single;
var
  E, G, Span: Single;
begin
  E := FEnv.Process(FPulse.Next);
  if E > Threshold then
  begin
    Span := 1 - Threshold;   // (1.0f - threshold), in float
    G := (E - Threshold) / Span;
  end
  else
    G := 0;
  Result := FDc.HighPass(FDac.Next * G * FLevel, FDcCoef) * Gain;
end;

function THiHat.Quiet: Boolean;
begin
  Result := (not FPulse.High) and ((FEnv.Value <= Threshold) or FDac.Finished) and (Abs(FDc.Z) < Rung);
end;

procedure THiHat.Reset;
begin
  FDac.Stop;
  FEnv.Reset;
  FDc.Reset;
end;

end.
