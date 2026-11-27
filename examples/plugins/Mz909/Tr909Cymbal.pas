// Mz909 - an emulation of the TR-909 Rhythm Composer
// Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/TR909/Cymbal.h.

unit Tr909Cymbal;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  Tr909Dsp, Tr909Trigger, Tr909Rom;

type
  TRomFunction = function: PRom;

  //
  // CRASH CYMBAL and RIDE CYMBAL: LEVEL, TUNE each.
  //
  // Each its own 6-bit recording, played to its end: the cymbal's decay is in the ROM, not
  // a VCA, so there is no DECAY. TUNE is the ROM's clock, a little over half an octave
  // either way - faster is higher and shorter, slower lower and longer, as a sample played
  // at another speed is. An accent is a louder hit through the VCA after the DAC.
  //
  // The structure is the 909's. The TUNE range is reasoned from the sound.
  //
  TCymbal = record
  private
    FRomOf: TRomFunction;
    FFs: Single;
    FDac: TRomPlayer;
    FDc: TOnePole;
    FDcCoef, FLevel: Single;
  public
    // The C++ constructor, Cymbal(whichRom).
    procedure Init(WhichRom: TRomFunction);
    procedure Prepare(SampleRate: Single);
    procedure SetPanel(TunePanel: Single);
    procedure Trigger(Height: Single);
    function Process: Single;
    function Quiet: Boolean;
    procedure Reset;
  end;

implementation

const
  Gain = 0.5;

  DcCorner = 30;
  SpeedLo: Single = 0.68;
  SpeedHi: Single = 1.47;
  Rung: Single = 1.0e-6;

procedure TCymbal.Init(WhichRom: TRomFunction);
begin
  FRomOf := WhichRom;
  FFs := 48000;
  FDac.Init;
  FDc.Z := 0;
  FDcCoef := 0;
  FLevel := 1;
end;

procedure TCymbal.Prepare(SampleRate: Single);
begin
  FFs := SampleRate;
  FDac.Prepare(FFs);
  FDcCoef := OnePoleCoef(TauOf(DcCorner), FFs);
  SetPanel(5);
  Reset;
end;

procedure TCymbal.SetPanel(TunePanel: Single);
begin
  FDac.SetSpeed(ExpLaw(TunePanel / 10, SpeedLo, SpeedHi));
end;

procedure TCymbal.Trigger(Height: Single);
begin
  FLevel := SampleAccent(Height);
  FDac.Start(FRomOf());
end;

function TCymbal.Process: Single;
begin
  Result := FDc.HighPass(FDac.Next * FLevel, FDcCoef) * Gain;
end;

function TCymbal.Quiet: Boolean;
begin
  Result := FDac.Finished and (Abs(FDc.Z) < Rung);
end;

procedure TCymbal.Reset;
begin
  FDac.Stop;
  FDc.Reset;
end;

end.
