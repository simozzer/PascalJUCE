// Mz808 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/TR808/Metal.h.

unit Tr808Metal;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  Tr808Dsp;

const
  MetalCount = 6;

type
  //
  // The six square-wave oscillators the cowbell, cymbal and both hi-hats share: one HD14584
  // hex Schmitt-trigger inverter, each gate an RC astable. Their frequencies are from Werner,
  // Abel and Smith's cymbal analysis (ICMC 2014): 205.3, 304.4, 369.6 and 522.7 Hz fixed by
  // their parts, and two trimmed at the factory to 540 and 800 Hz - the cowbell's pair. The
  // duty cycle comes from the inverter's thresholds alone: 47.98% on 5 V.
  //
  // They never stop. A hit catches them wherever they are, so no two cymbals are the same.
  // Each edge is band-limited (polyBLEP) at its exact sub-sample position.
  //
  TMetalBank = record
  private
    FPhase, FInc: array[0..MetalCount - 1] of Single;
  public
    Out_: array[0..MetalCount - 1] of Single;
    Sum: Single;
    procedure Init;
    procedure Prepare(SampleRate: Single; var Rng: TRandom);
    procedure Tick;
  end;

const
  MetalHz: array[0..MetalCount - 1] of Single = (205.3, 304.4, 369.6, 522.7, 540.0, 800.0);
  MetalDuty: Single = 0.4798;

//
// The "swing-type" VCA of the metal voices: a common-emitter stage with its collector
// supply replaced by the envelope. Its gain follows the envelope, and it is biased so it
// swings hard into clipping - the 808 cymbal's grit, which stays as the sound decays.
//
function SwingVca(X, Envelope, Drive: Single): Single; inline;

implementation

function SwingVca(X, Envelope, Drive: Single): Single;
begin
  Result := Envelope * SoftClip(X * Drive);
end;

// the residual of a unit step at t = 0, spread over the samples either side
function Blep(T, Dt: Single): Single;
var
  X: Single;
begin
  if T < Dt then
  begin
    X := T / Dt;
    Exit(X + X - X * X - 1);
  end;
  if T > 1 - Dt then
  begin
    X := (T - 1) / Dt;
    Exit(X * X + X + X + 1);
  end;
  Result := 0;
end;

{ TMetalBank }

procedure TMetalBank.Init;
var
  I: Integer;
begin
  for I := 0 to MetalCount - 1 do
  begin
    FPhase[I] := 0;
    FInc[I] := 0;
    Out_[I] := 0;
  end;
  Sum := 0;
end;

procedure TMetalBank.Prepare(SampleRate: Single; var Rng: TRandom);
var
  I: Integer;
begin
  for I := 0 to MetalCount - 1 do
  begin
    FInc[I] := MetalHz[I] / SampleRate;
    FPhase[I] := Rng.Uniform;
  end;
end;

procedure TMetalBank.Tick;
var
  I: Integer;
  Total, T, Dt, V, Tf: Single;
begin
  Total := 0;
  for I := 0 to MetalCount - 1 do
  begin
    T := FPhase[I] + FInc[I];
    if T >= 1 then
      T := T - 1;
    FPhase[I] := T;

    Dt := FInc[I];
    if T < MetalDuty then
      V := 0.5
    else
      V := -0.5;
    V := V + 0.5 * Blep(T, Dt);
    Tf := T - MetalDuty;
    if Tf < 0 then
      Tf := Tf + 1;
    V := V - 0.5 * Blep(Tf, Dt);

    Out_[I] := V;
    Total := Total + V;
  end;
  Sum := Total;
end;

end.
