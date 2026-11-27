// Mz808 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/TR808/Cowbell.h.

unit Tr808Cowbell;

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
  // COW BELL: LEVEL.
  //
  // The bank's 540 Hz and 800 Hz squares, mixed, through a VCA and a band pass. The
  // envelope has two parts: a short, loud strike, and a longer, quieter ring after it.
  //
  // The pair of frequencies is the circuit's; the band pass and the two decays are reasoned.
  //
  TCowbell = record
  private
    FFs: Single;
    FPulse: TTriggerPulse;
    FStrike, FRing: TEnvelope;
    FBp: TSvf;
  public
    procedure Init;
    procedure Prepare(SampleRate: Single);
    procedure Trigger(Height: Single); inline;
    function Process(const Bank: TMetalBank): Single;
    function Quiet: Boolean;
    procedure Reset;
  end;

implementation

const
  Gain: Single = 1.3;

  // Single literals the C++ writes with an f (see Tr808Dsp)
  StrikeDecay: Single = 0.009;
  RingDecay: Single = 0.11;
  BpQ: Single = 0.9;
  VcaDrive: Single = 1.6;
  Silence: Single = 1.0e-6;
  EnvSilence: Single = 1.0e-5;

{ TCowbell }

procedure TCowbell.Init;
begin
  FFs := 48000;
  FPulse.Init;
  FStrike.Init;
  FRing.Init;
  FBp.Init;
end;

procedure TCowbell.Prepare(SampleRate: Single);
begin
  FFs := SampleRate;
  FStrike.Prepare(FFs);
  FStrike.SetDecay(StrikeDecay);
  FRing.Prepare(FFs);
  FRing.SetDecay(RingDecay);
  FBp.Prepare(FFs);
  FBp.Setup(2000, BpQ);
  Reset;
end;

procedure TCowbell.Trigger(Height: Single);
begin
  FPulse.Fire(Height, FFs);
end;

function TCowbell.Process(const Bank: TMetalBank): Single;
var
  P, A, B, E, X: Single;
begin
  P := FPulse.Next;
  A := FStrike.Process(P);
  B := FRing.Process(P);
  E := 0.75 * A + 0.25 * B;
  X := 0.5 * (Bank.Out_[4] + Bank.Out_[5]);
  FBp.Process(SwingVca(X, E, VcaDrive));
  Result := FBp.BandNorm * Gain;
end;

function TCowbell.Quiet: Boolean;
begin
  Result := not FPulse.High and (FRing.Value < EnvSilence) and (FBp.Energy < Silence);
end;

procedure TCowbell.Reset;
begin
  FStrike.Reset;
  FRing.Reset;
  FBp.Reset;
end;

end.
