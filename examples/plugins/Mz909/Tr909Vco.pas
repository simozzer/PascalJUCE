// Mz909 - an emulation of the TR-909 Rhythm Composer
// Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/TR909/Vco.h.

unit Tr909Vco;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

type
  //
  // The 909's drum oscillator. Where the 808 rings a resonator, the 909's bass drum, snare
  // and toms each run a voltage-controlled oscillator, whose triangle a transistor shaper
  // rounds off into a near-sine - near, not pure: the corners stay a little pointed, which
  // is part of why a 909 kick cuts through where an 808's booms.
  //
  // Because it is an oscillator rather than a ring, its pitch can be swept as far as the
  // envelope likes, and every hit restarts it from the same point in its cycle, so every hit
  // starts the same way.
  //
  // The harmonics of a triangle fall away as 1/n^2, so at drum pitches it needs no
  // band-limiting.
  //
  TDrumVco = record
  private
    FNorm: Single;
    FInvFs, FPhase: Single;
  public
    procedure Init;
    procedure Prepare(SampleRate: Single);
    // from the zero crossing, rising
    procedure Restart; inline;
    function Process(Hz: Single): Single;
  end;

implementation

uses
  Tr909Dsp;

const
  Rounding: Single = 1.7;

procedure TDrumVco.Init;
begin
  FNorm := 1 / SoftClip(Rounding);
  FInvFs := 48000;
  FInvFs := 1 / FInvFs;   // 1.0f / 48000.0f, divided in float
  FPhase := 0;
end;

procedure TDrumVco.Prepare(SampleRate: Single);
begin
  FInvFs := 1 / SampleRate;
end;

procedure TDrumVco.Restart;
begin
  FPhase := 0;
end;

function TDrumVco.Process(Hz: Single): Single;
var
  Tri: Single;
begin
  FPhase := FPhase + Hz * FInvFs;
  if FPhase >= 1 then
    FPhase := FPhase - FloorF(FPhase);

  if FPhase < 0.25 then
    Tri := 4 * FPhase
  else if FPhase < 0.75 then
    Tri := 2 - 4 * FPhase
  else
    Tri := 4 * FPhase - 4;
  Result := SoftClip(Rounding * Tri) * FNorm;
end;

end.
