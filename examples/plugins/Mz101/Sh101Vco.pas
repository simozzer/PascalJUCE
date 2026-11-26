// Mz101 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/SH101/Vco.h.

unit Sh101Vco;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  Sh101Settings;

type
  TVcoLevels = record
    Pulse, Saw, Sub: Single;
    SubType: Integer;
  end;

  //
  // THE VCO
  //
  // One sawtooth core (a CEM3340-style exponential current into a capacitor, dumped by a
  // comparator at the top of each cycle) from which everything else is derived in hardware:
  //
  //   saw     the core itself
  //   pulse   a comparator between the saw and the PW voltage - so pulse width is a
  //           threshold on the ramp, and moves continuously under PWM
  //   sub     flip-flops clocked by the core's reset: one divides by two (square, one octave
  //           down), a second divides that again (square, two down), and the two ANDed give
  //           the 25% pulse two octaves down
  //
  // Because the sub is clocked by the core, it is phase-locked to it - no beating, ever, and
  // its edges land exactly on the saw's reset. That is why the 101's sub sounds welded to the
  // main oscillator rather than layered under it.
  //
  // Every edge is band-limited with a polyBLEP, placed at its exact fractional position. The
  // correction straddles the edge - half before it, half after - so the output runs one sample
  // late: FPending holds the previous sample until the next one says whether an edge landed
  // between them.
  //
  TVco = record
  private
    FPhase: Single;
    FPulseHigh: Boolean;
    FQ1, FQ2: Boolean;
    FPending: Single;
    FBefore, FAfter: Single;
    FEdgeEnergy: Single;
    // A step of height H, D samples (0..1) before now: the polyBLEP residual, split between
    // the previous sample and this one.
    procedure Edge(H, D: Single); inline;
    function SubValue(SubType: Integer): Single; inline;
  public
    procedure Reset;

    // Dt is frequency / sample rate; Width is the pulse's duty, 0.05 to 0.5.
    function Process(Dt, Width: Single; const L: TVcoLevels): Single;

    // How much the outputs jumped this sample, all edges together - the current the mixer
    // and the sub's flip-flops pull from the rail when they switch.
    function LastEdgeEnergy: Single; inline;
  end;

implementation

procedure TVco.Reset;
begin
  FPhase := 0;
  FPulseHigh := True;
  FQ1 := False;
  FQ2 := False;
  FPending := 0;
end;

procedure TVco.Edge(H, D: Single);
begin
  FEdgeEnergy := FEdgeEnergy + Abs(H);
  FBefore := FBefore + 0.5 * H * D * D;
  FAfter := FAfter - 0.5 * H * (1 - D) * (1 - D);
end;

function TVco.SubValue(SubType: Integer): Single;
var
  IsHigh: Boolean;
begin
  case SubType of
    SubTypeOctDown2: IsHigh := FQ2;
    SubTypePulse2:   IsHigh := FQ1 and FQ2;
  else
    IsHigh := FQ1;
  end;
  if IsHigh then
    Result := 1
  else
    Result := -1;
end;

function TVco.Process(Dt, Width: Single; const L: TVcoLevels): Single;
var
  OldSub, P, D, Naive, PulseValue: Single;
  Q1Fell: Boolean;
begin
  FBefore := 0;
  FAfter := 0;
  FEdgeEnergy := 0;

  OldSub := SubValue(L.SubType);

  // If PWM moved the threshold across the ramp since the last sample, the comparator
  // has already flipped. Put the edge in the middle of the interval - it is a tiny
  // step in any case, since PWM is slow next to the ramp.
  if FPulseHigh <> (FPhase < Width) then
  begin
    FPulseHigh := not FPulseHigh;
    if FPulseHigh then
      Edge(L.Pulse * 2, 0.5)
    else
      Edge(L.Pulse * -2, 0.5);
  end;

  P := FPhase + Dt;

  // falling edge of the pulse before the reset
  if FPulseHigh and (FPhase < Width) and (P >= Width) then
  begin
    FPulseHigh := False;
    Edge(-2 * L.Pulse, (P - Width) / Dt);
  end;

  if P >= 1 then
  begin
    P := P - 1;
    D := P / Dt;   // samples since the reset

    Edge(-2 * L.Saw, D);

    if not FPulseHigh then
    begin
      FPulseHigh := True;
      Edge(2 * L.Pulse, D);
    end;

    // the dividers
    Q1Fell := FQ1;
    FQ1 := not FQ1;
    if Q1Fell then
      FQ2 := not FQ2;

    Edge(L.Sub * (SubValue(L.SubType) - OldSub), D);

    // and the pulse may fall again in the same sample, at very high pitches
    if P >= Width then
    begin
      FPulseHigh := False;
      Edge(-2 * L.Pulse, (P - Width) / Dt);
    end;
  end;

  FPhase := P;

  if FPulseHigh then
    PulseValue := 1
  else
    PulseValue := -1;
  Naive := L.Saw * (2 * FPhase - 1) + L.Pulse * PulseValue + L.Sub * SubValue(L.SubType);

  Result := FPending + FBefore;
  FPending := Naive + FAfter;
end;

function TVco.LastEdgeEnergy: Single;
begin
  Result := FEdgeEnergy;
end;

end.
