// Mz909 - an emulation of the TR-909 Rhythm Composer
// Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/TR909/HandClap.h.

unit Tr909HandClap;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  Tr909Dsp;

type
  //
  // HAND CLAP: LEVEL.
  //
  // White noise through a band pass a little above 1 kHz, into a VCA driven by two envelopes
  // at once. A sawtooth generator gives a burst of quick decays a few milliseconds apart -
  // several hands, not quite together - and a slower envelope gives the tail after them, the
  // "reverb". The 909's is brighter and its tail longer than the 808's.
  //
  // The structure is the circuit's; the number of claps, their spacing, the filter and the
  // times are reasoned from the sound, not measured.
  //
  THandClap = record
  private
    FFs: Single;
    FBp: TSvf;

    FH: Single;
    FTooth, FToothFall: Single;
    FTeethLeft, FTimer, FSpacing: Integer;
    FFast, FSlow, FTailRise, FTailFall: Single;
  public
    procedure Init;
    procedure Prepare(SampleRate: Single);
    procedure Trigger(Height: Single);
    function Process(var Rng: TRandom): Single;
    function Quiet: Boolean;
    procedure Reset;
  end;

implementation

const
  Claps = 4;           // three quick, and the one the tail grows from
  TailLevel: Single = 0.8;
  Drive: Single = 1.1;
  Gain = 1.25;

  BpHz = 1150;
  BpQ: Single = 1.8;
  ToothTau: Single = 0.0025;
  TailRiseTau: Single = 0.007;
  TailFallTau: Single = 0.11;
  SpacingSeconds: Single = 0.009;
  Silent: Single = 1.0e-5;

procedure THandClap.Init;
begin
  FFs := 48000;
  FBp.Init;
  FH := 1;
  FTooth := 0;
  FToothFall := 0;
  FTeethLeft := 0;
  FTimer := 0;
  FSpacing := 400;
  FFast := 0;
  FSlow := 0;
  FTailRise := 0;
  FTailFall := 0;
end;

procedure THandClap.Prepare(SampleRate: Single);
begin
  FFs := SampleRate;
  FBp.Prepare(FFs);
  FBp.Setup(BpHz, BpQ);
  FToothFall := DecayCoef(ToothTau, FFs);
  FTailRise := DecayCoef(TailRiseTau, FFs);
  FTailFall := DecayCoef(TailFallTau, FFs);
  FSpacing := LRound(SpacingSeconds * FFs);
  Reset;
end;

procedure THandClap.Trigger(Height: Single);
begin
  FH := Height;
  FTooth := Height;
  FTeethLeft := Claps - 1;
  FTimer := FSpacing;
  FFast := Height;
  FSlow := Height;
end;

function THandClap.Process(var Rng: TRandom): Single;
var
  Tail, W: Single;
begin
  FTooth := FTooth * FToothFall;
  if FTeethLeft > 0 then
  begin
    Dec(FTimer);
    if FTimer <= 0 then
    begin
      FTooth := FH;
      Dec(FTeethLeft);
      FTimer := FSpacing;
    end;
  end;

  FFast := FFast * FTailRise;
  FSlow := FSlow * FTailFall;
  Tail := (FSlow - FFast) * TailLevel;

  W := Rng.White;
  FBp.Process(W);
  Result := SoftClip(FBp.BandNorm * (FTooth + Tail) * Drive) * Gain;
end;

function THandClap.Quiet: Boolean;
begin
  Result := (FTeethLeft = 0) and (FTooth < Silent) and (FSlow < Silent);
end;

procedure THandClap.Reset;
begin
  FBp.Reset;
  FTooth := 0;
  FFast := 0;
  FSlow := 0;
  FTeethLeft := 0;
end;

end.
