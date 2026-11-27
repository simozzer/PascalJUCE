// Mz303 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of source/TB303/Vco.h.

unit Tb303Vco;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

type
  //
  // THE VCO
  //
  // One sawtooth core: an exponential current charging a capacitor, dumped at the top of each
  // cycle. The 303 has no second waveform generator - its square is the saw put through a
  // one-transistor waveshaper, so it is never quite square. The transistor switches as the
  // ramp crosses its threshold, near the middle, but does not switch hard: the ramp still
  // shows through, so each half of the wave leans the way the saw does. That lean is a good
  // part of why the 303's square sounds hollow and reedy rather than like a clean pulse.
  //
  // Every edge is band-limited with a polyBLEP, placed at its exact fractional position. The
  // correction straddles the edge - half before it, half after - so the output runs one sample
  // late: FPending holds the previous sample until the next one says whether an edge landed
  // between them.
  //
  TVco = record
  private
    FPhase: Single;
    FHigh: Boolean;
    FPending: Single;
    FBefore, FAfter: Single;
    procedure Edge(H, D: Single); inline;
  public
    procedure Init;
    procedure Reset;
    // Dt is frequency / sample rate.
    function Process(Dt: Single; Wave: Integer): Single;
  end;

implementation

uses
  Tb303Settings;

const
  // Where on the ramp the waveshaper switches - a little under half way, so the square's
  // high half is the shorter - and how much of the ramp it lets through. Reasoned from the
  // circuit, not measured: each is the single number to fit to a real unit.
  Threshold: Single = 0.46;
  Lean: Single = 0.3;
  SquareLevel: Single = 0.8;

procedure TVco.Init;
begin
  FPhase := 0;
  FHigh := True;
  FPending := 0;
  FBefore := 0;
  FAfter := 0;
end;

procedure TVco.Reset;
begin
  FPhase := 0;
  FHigh := True;
  FPending := 0;
end;

// A step of height H, D samples (0..1) before now: the polyBLEP residual, split between
// the previous sample and this one.
procedure TVco.Edge(H, D: Single);
begin
  FBefore := FBefore + 0.5 * H * D * D;
  FAfter := FAfter - 0.5 * H * (1 - D) * (1 - D);
end;

function TVco.Process(Dt: Single; Wave: Integer): Single;
var
  Square: Boolean;
  SawLevel, PulseLevel, P, D, Naive, HighLevel: Single;
begin
  FBefore := 0;
  FAfter := 0;

  Square := Wave = WaveSquare;
  if Square then
  begin
    SawLevel := Lean;
    PulseLevel := SquareLevel;
  end
  else
  begin
    SawLevel := 1;
    PulseLevel := 0;
  end;

  P := FPhase + Dt;

  // the waveshaper switching low, partway up the ramp
  if FHigh and (FPhase < Threshold) and (P >= Threshold) then
  begin
    FHigh := False;
    Edge(-2 * PulseLevel, (P - Threshold) / Dt);
  end;

  if P >= 1 then
  begin
    P := P - 1;
    D := P / Dt;   // samples since the reset

    Edge(-2 * SawLevel, D);

    if not FHigh then
    begin
      FHigh := True;
      Edge(2 * PulseLevel, D);
    end;

    // and low again in the same sample, at very high pitches
    if P >= Threshold then
    begin
      FHigh := False;
      Edge(-2 * PulseLevel, (P - Threshold) / Dt);
    end;
  end;

  FPhase := P;

  if FHigh then
    HighLevel := 1
  else
    HighLevel := -1;
  Naive := SawLevel * (2 * FPhase - 1) + PulseLevel * HighLevel;

  Result := FPending + FBefore;
  FPending := Naive + FAfter;
end;

end.
