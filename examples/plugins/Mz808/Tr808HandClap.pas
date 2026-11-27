// Mz808 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/TR808/HandClap.h.

unit Tr808HandClap;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  Tr808Dsp, Tr808Trigger;

type
  //
  // HAND CLAP / MARACAS: one LEVEL.
  //
  // One circuit, switched, so each cuts the other off.
  //
  //  - HAND CLAP: white noise through a band pass near 1 kHz, into a VCA driven by two
  //    envelopes at once. A sawtooth generator gives a burst of quick decays a few
  //    milliseconds apart - several hands, not quite together - and a slower envelope gives
  //    the tail after them, the "reverb".
  //  - MARACAS: white noise, high-passed, with an envelope that rises over a couple of
  //    milliseconds before it falls - a shake rather than a hit.
  //
  // The structure is the circuit's; the number of claps, their spacing, the filter and the
  // times are reasoned from the sound, not measured.
  //
  THandClap = record
  private
    FFs: Single;
    FMaracas: Boolean;
    FClapBp, FMaracasHp: TSvf;

    FH: Single;
    FTooth, FToothFall: Single;
    FTeethLeft, FTimer, FSpacing: Integer;
    FFast, FSlow: Single;
    FTailRise, FTailFall, FShakeRise, FShakeFall: Single;
  public
    procedure Init;
    procedure Prepare(SampleRate: Single);
    procedure Trigger(Height: Single; AsMaracas: Boolean);
    function Process(var Rng: TRandom): Single;
    function Quiet: Boolean;
    procedure Reset;
  end;

implementation

const
  Claps = 4;                  // three quick, and the one the tail grows from
  TailLevel = 0.75;
  ClapDrive: Single = 1.1;
  ClapGain = 1.25;
  MaracasGain: Single = 0.45;

  // Single literals the C++ writes with an f (see Tr808Dsp)
  ClapQ: Single = 2.2;
  MaracasQ: Single = 0.7;
  ToothTau: Single = 0.0028;
  TailRiseTau: Single = 0.006;
  TailFallTau: Single = 0.075;
  ShakeRiseTau: Single = 0.0015;
  ShakeFallTau: Single = 0.012;
  SpacingSeconds: Single = 0.0105;
  EnvSilence: Single = 1.0e-5;

{ THandClap }

procedure THandClap.Init;
begin
  FFs := 48000;
  FMaracas := False;
  FClapBp.Init;
  FMaracasHp.Init;
  FH := 1;
  FTooth := 0;
  FToothFall := 0;
  FTeethLeft := 0;
  FTimer := 0;
  FSpacing := 500;
  FFast := 0;
  FSlow := 0;
  FTailRise := 0;
  FTailFall := 0;
  FShakeRise := 0;
  FShakeFall := 0;
end;

procedure THandClap.Prepare(SampleRate: Single);
var
  Samples: Single;
begin
  FFs := SampleRate;
  FClapBp.Prepare(FFs);
  FClapBp.Setup(1000, ClapQ);
  FMaracasHp.Prepare(FFs);
  FMaracasHp.Setup(5000, MaracasQ);
  FToothFall := DecayCoef(ToothTau, FFs);
  FTailRise := DecayCoef(TailRiseTau, FFs);
  FTailFall := DecayCoef(TailFallTau, FFs);
  FShakeRise := DecayCoef(ShakeRiseTau, FFs);
  FShakeFall := DecayCoef(ShakeFallTau, FFs);
  Samples := SpacingSeconds * FFs;
  FSpacing := LRound(Samples);
  Reset;
end;

procedure THandClap.Trigger(Height: Single; AsMaracas: Boolean);
begin
  FMaracas := AsMaracas;
  FH := Height;
  if FMaracas then
  begin
    FFast := Height;
    FSlow := Height;
    FTooth := 0;
    FTeethLeft := 0;
  end
  else
  begin
    FTooth := Height;
    FTeethLeft := Claps - 1;
    FTimer := FSpacing;
    FFast := Height;
    FSlow := Height;
  end;
end;

function THandClap.Process(var Rng: TRandom): Single;
var
  W, Tail: Single;
begin
  W := Rng.White;

  if FMaracas then
  begin
    FFast := FFast * FShakeRise;
    FSlow := FSlow * FShakeFall;
    FMaracasHp.Process(W);
    FClapBp.Process(0);
    Exit(FMaracasHp.Hp * (FSlow - FFast) * MaracasGain);
  end;

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

  FClapBp.Process(W);
  FMaracasHp.Process(0);
  Result := SoftClip(FClapBp.BandNorm * (FTooth + Tail) * ClapDrive) * ClapGain;
end;

function THandClap.Quiet: Boolean;
begin
  Result := (FTeethLeft = 0) and (FTooth < EnvSilence) and (FSlow < EnvSilence);
end;

procedure THandClap.Reset;
begin
  FClapBp.Reset;
  FMaracasHp.Reset;
  FTooth := 0;
  FFast := 0;
  FSlow := 0;
  FTeethLeft := 0;
end;

end.
