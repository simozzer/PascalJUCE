// MzPCG - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// PcgEngine - the Object Pascal port of pcg::Settings (Source/PCG/Settings.h) and pcg::Pcg
// (Source/PCG/Pcg.h, Pcg.cpp): the whole pattern-controlled gain, as the plug-in plays it.
// It plays MzPCF's patterns on MzPCF's step clock (the shared units in ../MzPCF/PCF, as the
// C++ MzPCG compiles MzPCF's Source/PCF), and depends on nothing of the plug-in's: the
// plug-in (MzPcgPlugin), the panel's picture (PcgControls) and the equivalence check
// (verify/render_pas.dpr) drive it the same way.
//
// Single and Double exactly where the C++ has float and double, the C library's maths (see
// PcfMath for the rules), so it renders the C++'s samples bit for bit.

unit PcgEngine;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  PcfMath, PcfPatterns, PcfStepClock;

const
  // pcg::Mode
  PcgModeGate = 0;   // a step opens the sound
  PcgModeDuck = 1;   // a step pushes it down

  // pcg::Rate
  PcgRateEighth = 0;
  PcgRateSixteenth = 1;
  PcgRateThirtySecond = 2;

  PcgPatternCount = PcfPatternCount;   // pcg::patterns
  PcgStepCount = PcfStepCount;         // pcg::steps

type
  //
  // The front panel, in panel units: 0 to 1 unless it says otherwise.
  //
  TPcgSettings = record
    Pattern: Integer;   // 0 to 31, MzPCF's patterns
    Mode: Integer;      // PcgModeGate or PcgModeDuck
    Rate: Integer;      // PcgRateEighth, PcgRateSixteenth or PcgRateThirtySecond
    Depth: Single;      // how far: 0 leaves the sound alone, 1 gates it to silence
    Attack: Single;     // how fast a step takes hold, 0.5 to 50 ms
    Hold: Single;       // how much of the step it holds there, none to all of it
    Decay: Single;      // then how fast it lets go, 5 ms to 1.5 s
    Mix: Single;        // 0 dry to 1 all through the gain
    Level: Single;      // output, dB, -24 to +12
    // The C++ defaults (the member initialisers).
    class function Defaults: TPcgSettings; static;
  end;

  //
  // The pattern-controlled gain. The PCF's idea, on the volume instead of a filter: on every
  // step of the host's timeline - at RATE - an envelope is struck to that step's level in
  // the pattern, holds for HOLD of the step, and lets go by DECAY, rounded by ATTACK so it
  // never clicks. In GATE mode the envelope opens the sound, as a trance gate; in DUCK mode
  // it pushes the sound down, and the sound comes back as it lets go, as a sidechain pump.
  // DEPTH says how far either goes.
  //
  // With the transport stopped nothing is struck, and the sound passes untouched.
  //
  // A record: call Init once (the C++ member initialisers), then Prepare.
  //
  TPcg = record
  private
    FFs: Double;
    FTarget: TPcgSettings;
    FClock: TPcfStepClock;
    FLastStruck: Integer;
    FGainNow: Single;

    // the envelope: struck to a level, held, let go; and rounded by the attack
    FRaw, FShaped: Single;
    FHoldLeft: Double;

    // the knobs, smoothed, so turning one does not zip
    FDepth, FWet, FOut: Single;
    FSmoothCoef: Single;
    FSettled: Boolean;
  public
    procedure Init;
    procedure Prepare(SampleRate: Double);
    procedure Reset;

    procedure SetSettings(const S: TPcgSettings);

    // Where the host's timeline is at the top of the next block.
    procedure SetHostClock(Playing: Boolean; Ppq, Bpm: Double);

    // In place. Right may be nil, for a mono channel.
    procedure Process(Left, Right: PPcfSamples; N: Integer);

    // The step last struck, 0 to 15, for the panel's lights; -1 stopped.
    function Step: Integer; inline;
    // The gain as it stands, before MIX and LEVEL - for the panel's meter, and the checks.
    function Gain: Single; inline;
    property Settings: TPcgSettings read FTarget;
  end;

  TPcgCurve = array of Single;

// The steps to a beat at each RATE (pcg::stepsPerQuarter).
function PcgStepsPerQuarter(Rate: Integer): Integer;

// A pattern's level on a step, 0 to 1: the PCF's (pcg::level).
function PcgLevel(Pattern, Step: Integer): Single; inline;

// The one-pole coefficient that gets 63% of the way in Seconds (Pcg.cpp's follow - in
// double, where the PCF's takes a float).
function PcgFollow(Seconds, Rate: Double): Single;

//
// What the gain does over the pattern's sixteen steps with these knobs: the C++ panel's
// GainDisplay::simulate. The engine itself, played twice round the pattern at 120 bpm and
// 4 kHz on a signal of ones, MIX full and LEVEL 0 dB, so the first step shows what the last
// left it; the second time round is returned.
//
function PcgGainCurve(const S: TPcgSettings): TPcgCurve;

implementation

const
  SmoothSeconds: Double = 0.010;
  AttackShortest: Double = 0.0005;   // 0.5 ms ...
  AttackRange: Double = 100.0;       // ... to 50 ms
  DecayShortest: Double = 0.005;     // 5 ms ...
  DecayRange: Double = 300.0;        // ... to 1.5 s
  DefaultAttack: Single = 0.2;       // 0.2f
  DefaultDecay: Single = 0.2;        // 0.2f

{ TPcgSettings }

class function TPcgSettings.Defaults: TPcgSettings;
begin
  Result.Pattern := 0;
  Result.Mode := PcgModeGate;
  Result.Rate := PcgRateSixteenth;
  Result.Depth := 1;
  Result.Attack := DefaultAttack;
  Result.Hold := 0.5;
  Result.Decay := DefaultDecay;
  Result.Mix := 1;
  Result.Level := 0;
end;

function PcgStepsPerQuarter(Rate: Integer): Integer;
begin
  if Rate = PcgRateEighth then
    Result := 2
  else if Rate = PcgRateThirtySecond then
    Result := 8
  else
    Result := 4;
end;

function PcgLevel(Pattern, Step: Integer): Single;
begin
  Result := PcfLevel(Pattern, Step);
end;

function PcgFollow(Seconds, Rate: Double): Single;
var
  E: Single;
begin
  E := ExpD(-1.0 / (Seconds * Rate));   // (float) std::exp(-1.0 / (seconds * rate))
  Result := 1 - E;
end;

{ TPcg }

procedure TPcg.Init;
begin
  FFs := 48000.0;
  FTarget := TPcgSettings.Defaults;
  FClock.Init;
  FLastStruck := -1;
  FGainNow := 1;
  FRaw := 0;
  FShaped := 0;
  FHoldLeft := 0.0;
  FDepth := 1;
  FWet := 1;
  FOut := 1;
  FSmoothCoef := 0;
  FSettled := False;
end;

procedure TPcg.Prepare(SampleRate: Double);
begin
  if SampleRate > 0.0 then
    FFs := SampleRate
  else
    FFs := 48000.0;
  FClock.Prepare(FFs);
  FSmoothCoef := PcgFollow(SmoothSeconds, FFs);
  Reset;
end;

procedure TPcg.Reset;
begin
  FClock.Reset;
  FLastStruck := -1;
  FHoldLeft := 0.0;
  FSettled := False;

  // at rest the sound passes: the gate open, nothing ducked
  if FTarget.Mode = PcgModeGate then
    FRaw := 1
  else
    FRaw := 0;
  FShaped := FRaw;
end;

procedure TPcg.SetSettings(const S: TPcgSettings);
begin
  FTarget := S;
end;

procedure TPcg.SetHostClock(Playing: Boolean; Ppq, Bpm: Double);
begin
  FClock.SetClock(Playing, Ppq, Bpm, PcgStepsPerQuarter(FTarget.Rate));
  if not FClock.IsPlaying then
    FLastStruck := -1;
end;

procedure TPcg.Process(Left, Right: PPcfSamples; N: Integer);
var
  Gate: Boolean;
  AttackCoef, DecayCoef, Rest, DepthT, WetT, OutT, G, K, E: Single;
  HoldFor, D: Double;
  Sides: array[0..1] of PPcfSamples;
  I, C, Struck: Integer;
  St: Int64;
begin
  Gate := FTarget.Mode = PcgModeGate;

  D := ClampF(FTarget.Attack, 0, 1);
  AttackCoef := PcgFollow(AttackShortest * PowD(AttackRange, D), FFs);   // 0.5 to 50 ms
  D := ClampF(FTarget.Decay, 0, 1);
  E := ExpD(-1.0 / (DecayShortest * PowD(DecayRange, D) * FFs));        // 5 ms to 1.5 s
  DecayCoef := E;
  D := ClampF(FTarget.Hold, 0, 1);
  HoldFor := D * FClock.SamplesPerStep;
  if Gate then
    Rest := 1
  else
    Rest := 0;

  DepthT := ClampF(FTarget.Depth, 0, 1);
  WetT := ClampF(FTarget.Mix, 0, 1);
  OutT := PowF(10, ClampF(FTarget.Level, -24, 12) / 20);
  if not FSettled then
  begin
    FDepth := DepthT;
    FWet := WetT;
    FOut := OutT;
    FSettled := True;
  end;

  Sides[0] := Left;
  Sides[1] := Right;
  G := 1;

  for I := 0 to N - 1 do
  begin
    St := 0;
    if FClock.StepAt(I, St) then
    begin
      Struck := Integer(((St mod PcgStepCount) + PcgStepCount) mod PcgStepCount);
      FRaw := PcgLevel(FTarget.Pattern, Struck);
      FHoldLeft := HoldFor;
      FLastStruck := Struck;
    end;

    if not FClock.IsPlaying then
      FRaw := Rest                              // stopped: the sound passes
    else if FHoldLeft > 0.0 then
      FHoldLeft := FHoldLeft - 1.0
    else
      FRaw := FRaw * DecayCoef;

    FShaped := FShaped + (FRaw - FShaped) * AttackCoef;

    FDepth := FDepth + (DepthT - FDepth) * FSmoothCoef;
    FWet := FWet + (WetT - FWet) * FSmoothCoef;
    FOut := FOut + (OutT - FOut) * FSmoothCoef;

    // GATE: the envelope is how open the sound is; DUCK: how far down it is pushed
    if Gate then
      G := 1 - FDepth * (1 - FShaped)
    else
      G := 1 - FDepth * FShaped;
    K := (1 - FWet + FWet * G) * FOut;

    for C := 0 to 1 do
      if Sides[C] <> nil then
        Sides[C]^[I] := Sides[C]^[I] * K;
  end;

  FGainNow := G;
end;

function TPcg.Step: Integer;
begin
  Result := FLastStruck;
end;

function TPcg.Gain: Single;
begin
  Result := FGainNow;
end;

function PcgGainCurve(const S: TPcgSettings): TPcgCurve;
const
  Rate = 4000.0;
  Bpm = 120.0;
  Chunk = 64;
var
  Engine: TPcg;
  T: TPcgSettings;
  PerStep, Total, At, N, I: Integer;
  X: array of Single;
  Ppq, A: Double;
begin
  Result := nil;
  Engine.Init;
  Engine.Prepare(Rate);
  T := S;
  T.Mix := 1;
  T.Level := 0;
  Engine.SetSettings(T);

  PerStep := Trunc(Rate * 60.0 / Bpm / PcgStepsPerQuarter(T.Rate));
  Total := PerStep * PcgStepCount * 2;
  SetLength(X, Total);
  for I := 0 to Total - 1 do
    X[I] := 1;
  At := 0;
  while At < Total do
  begin
    N := Total - At;
    if N > Chunk then
      N := Chunk;
    A := At;
    Ppq := A / Rate * Bpm / 60.0;
    Engine.SetHostClock(True, Ppq, Bpm);
    Engine.Process(@X[At], nil, N);
    Inc(At, Chunk);
  end;

  SetLength(Result, Total - Total div 2);
  for I := 0 to High(Result) do
    Result[I] := X[Total div 2 + I];
end;

end.
