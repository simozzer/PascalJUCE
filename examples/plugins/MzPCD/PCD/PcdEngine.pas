// MzPCD - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// PcdEngine - the Object Pascal port of pcd::Settings (Source/PCD/Settings.h) and pcd::Pcd
// (Source/PCD/Pcd.h, Pcd.cpp): the whole pattern-controlled distortion, as the plug-in
// plays it. It plays MzPCF's patterns, step clock and envelope - the shared units in
// ../MzPCF/PCF, as the C++ compiles MzPCF's Source/PCF - so a pattern number means the
// same in both. No dependency on the plug-in layer: the plug-in (MzPcdPlugin) and the
// equivalence check (verify/render_pas.dpr) drive it the same way.
//
// Double and Single exactly where the C++ has double and float, the C library's maths
// (PcfMath, PcdMath), so it renders the C++'s samples bit for bit.

unit PcdEngine;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$MINFPCONSTPREC 64}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  PcfMath, PcfPatterns, PcfStepClock, PcfEnvelope, PcdRebirthDist, PcdOversampler;

const
  PcdPatterns = PcfPatternCount;   // pcd::patterns
  PcdSteps = PcfStepCount;         // pcd::steps

  // pcd::Rate
  PcdRateEighth = 0;
  PcdRateSixteenth = 1;
  PcdRateThirtySecond = 2;

  // the delay the oversampling makes, in samples; the dry signal is delayed to match it
  PcdLatency = PcdOsLatency;

// the steps to a beat at each RATE
function PcdStepsPerQuarter(Rate: Integer): Integer;

type
  //
  // The front panel, in panel units: 0 to 1 unless it says otherwise.
  //
  // DRIVE, TONE and FEEDBACK set where each sits; the pattern pushes each of them from
  // there by its own amount, on every step it strikes.
  //
  TPcdSettings = record
    Pattern: Integer;        // 0 to 31, MzPCF's patterns
    Rate: Integer;           // PcdRateEighth .. PcdRateThirtySecond

    Drive: Single;           // ReBirth's AMOUNT, 0 to 127: 70 as ReBirth starts
    Shape: Single;           // ReBirth's SHAPE, 0 to 127: 0 its hard clip, then its waveshaper
    Tone: Single;            // dark to bright: the cutoff after it, 500 Hz to 12 kHz
    Feedback: Single;        // how much of the output comes round again, as an amp's does

    DriveAmount: Single;     // how far a full step pushes the AMOUNT up, by up to 127
    ToneAmount: Single;      // -1 to +1: how far it moves the tone, down or up
    FeedbackAmount: Single;  // how far it pushes the feedback up
    Decay: Single;           // how fast a step's push dies away, 15 ms to 1.5 s

    Mix: Single;             // 0 dry to 1 all through the distortion
    Level: Single;           // output, dB, -24 to +12
    // The C++ defaults (the member initialisers).
    class function Defaults: TPcdSettings; static;
  end;

  TPcdChannel = record
    Os: TPcdOversampler;
    DcX, DcY: Double;
    Lp1, Lp2: Double;        // the tone: a two-pole low-pass
    Bp1, Bp2: Double;        // the speaker's resonance, in the loop
    Loop: array of Single;   // the acoustic path back to the input
    Dry: array[0..PcdLatency - 1] of Single;   // a ring as long as the delay it makes
    LoopPos, DryPos: Integer;
    ComingBack: Double;      // what the loop brings to the next sample
  end;

  //
  // The pattern-controlled distortion. ReBirth's distortion (PcdRebirthDist), run at twice
  // the sample rate so its harmonics do not alias, with a tone control after it and a
  // feedback loop round it - and the PCF's idea playing all three: on every step of the
  // host's timeline an envelope is struck to that step's level in the pattern, and pushes
  // the drive, the tone and the feedback each by its own amount, dying away by DECAY.
  //
  // The feedback is an amplifier's: the output comes back round a short acoustic path and
  // a speaker's resonance into the input. Turned up it sustains, and past a point it howls,
  // at a pitch that follows TONE. The distortion bounds the loop, as the amp's does, so it
  // can never run away.
  //
  // A record: call Init once (the C++ constructor), then Prepare.
  //
  TPcd = record
  private
    FFs: Double;
    FTarget: TPcdSettings;
    FClock: TPcfStepClock;
    FEnv: TPcfEnvelope;
    FLastStruck: Integer;
    FEnvNow: Single;

    FChannels: array[0..1] of TPcdChannel;
    FLoopLength: Integer;
    FDcCoef: Double;

    // the knobs, smoothed, so turning one does not zip; the envelope's push is added after
    FDrive, FToneOct, FFeedback, FWet, FOut: Double;
    FSmoothCoef: Double;
    FSettled: Boolean;
  public
    procedure Init;
    procedure Prepare(SampleRate: Double);
    procedure Reset;

    procedure SetSettings(const S: TPcdSettings);

    // Where the host's timeline is at the top of the next block.
    procedure SetHostClock(Playing: Boolean; Ppq, Bpm: Double);

    // In place. Right may be nil, for a mono channel.
    procedure Process(Left, Right: PPcfSamples; N: Integer);

    // The step last struck, 0 to 15, for the panel's lights; -1 stopped.
    function Step: Integer; inline;
    // The envelope as it stands, 0 to 1 - for the panel, and the checks.
    function Envelope: Single; inline;
    property Settings: TPcdSettings read FTarget;

    // the frequency the feedback howls at, for a TONE, in Hz
    class function HowlFrequency(ToneHz: Double): Double; static;
  end;

implementation

uses
  PcdMath;

const
  PiD: Double = 3.14159265358979323846;

  ToneLow = 500.0;          // TONE's travel
  ToneHigh = 12000.0;
  MaxLoopGain: Double = 1.2;          // FEEDBACK at full
  LoopSeconds: Double = 0.0025;       // the speaker to the pickup, about a metre
  ResonanceQ = 4.0;

  SmoothSeconds: Double = 0.010;
  CeilingRatio: Double = 0.45;
  ToneDamping: Double = 1.4142;
  HowlRatio = 0.25;
  HowlLow = 150.0;
  HowlHigh = 2500.0;

  // float literals of the C++
  DefaultDecay: Single = 0.35;
  SevenTenths: Single = 70.0;
  Full: Single = 127.0;

function PcdStepsPerQuarter(Rate: Integer): Integer;
begin
  if Rate = PcdRateEighth then
    Result := 2
  else if Rate = PcdRateThirtySecond then
    Result := 8
  else
    Result := 4;
end;

{ TPcdSettings }

class function TPcdSettings.Defaults: TPcdSettings;
begin
  Result.Pattern := 0;
  Result.Rate := PcdRateSixteenth;
  Result.Drive := SevenTenths / Full;   // 70.0f / 127.0f
  Result.Shape := 0;
  Result.Tone := 0.5;
  Result.Feedback := 0;
  Result.DriveAmount := 0.5;
  Result.ToneAmount := 0;
  Result.FeedbackAmount := 0;
  Result.Decay := DefaultDecay;
  Result.Mix := 1;
  Result.Level := 0;
end;

type
  //
  // The distortion itself is ReBirth's, as OpenRB-338 decoded it (PcdRebirthDist): at an
  // AMOUNT, 0 to 127, and a SHAPE - 0 its hard clip, 1 to 127 a row of its waveshaper -
  // with ReBirth's own gains in and out. Here AMOUNT moves smoothly, as the pattern pushes
  // it, where ReBirth's moved in whole steps.
  //
  TCurve = record
    Clip: Boolean;
    Row: PRbRow;
    InG, OutG, Threshold: Double;
    procedure Make(Amount: Double; Shape: Integer); inline;
    function Run(U: Double): Double; inline;
  end;

  // A trapezoidal state-variable filter's coefficients, at a frequency and damping.
  TSvf = record
    A1, A2, A3: Double;
    procedure Make(Hz, Fs, K: Double); inline;
    // one sample through: returns the band output, and the low-pass in Low
    function Run(X: Double; var Ic1, Ic2: Double; out Low: Double): Double; inline;
  end;

procedure TCurve.Make(Amount: Double; Shape: Integer);
begin
  Clip := Shape = 0;
  Row := RbRow(Shape);
  if Clip then
    InG := RbClipGain(Amount)
  else
    InG := RbInGain(Amount);
  OutG := RbOutGain(Shape, Amount);
  Threshold := RbClipThreshold(Amount);
end;

function TCurve.Run(U: Double): Double;
begin
  if Clip then
    Result := ClampD(InG * U, -Threshold, Threshold)
  else
    Result := RbShape(Row, InG * U + 128.0) * OutG;
end;

procedure TSvf.Make(Hz, Fs, K: Double);
var
  G: Double;
begin
  G := TanD(PiD * MinD(Hz, Fs * CeilingRatio) / Fs);
  A1 := 1.0 / (1.0 + G * (G + K));
  A2 := G * A1;
  A3 := G * A2;
end;

function TSvf.Run(X: Double; var Ic1, Ic2: Double; out Low: Double): Double;
var
  V1, V2, V3: Double;
begin
  V3 := X - Ic2;
  V1 := A1 * Ic1 + A2 * V3;
  V2 := Ic2 + A2 * Ic1 + A3 * V3;
  Ic1 := 2.0 * V1 - Ic1;
  Ic2 := 2.0 * V2 - Ic2;
  Low := V2;
  Result := V1;
end;

{ TPcd }

class function TPcd.HowlFrequency(ToneHz: Double): Double;
begin
  // a quarter of the tone's cutoff, where a speaker cabinet sings: from 150 Hz to 2.5 kHz
  Result := ClampD(ToneHz * HowlRatio, HowlLow, HowlHigh);
end;

procedure TPcd.Init;
var
  C: Integer;
begin
  FFs := 48000.0;
  FTarget := TPcdSettings.Defaults;
  FClock.Init;
  FEnv.Init;
  FLastStruck := -1;
  FEnvNow := 0;
  for C := 0 to 1 do
  begin
    FChannels[C].Os.Init;
    FChannels[C].DcX := 0.0;
    FChannels[C].DcY := 0.0;
    FChannels[C].Lp1 := 0.0;
    FChannels[C].Lp2 := 0.0;
    FChannels[C].Bp1 := 0.0;
    FChannels[C].Bp2 := 0.0;
    FChannels[C].Loop := nil;
    FillChar(FChannels[C].Dry, SizeOf(FChannels[C].Dry), 0);
    FChannels[C].LoopPos := 0;
    FChannels[C].DryPos := 0;
    FChannels[C].ComingBack := 0.0;
  end;
  FLoopLength := 1;
  FDcCoef := 0.9993;
  FDrive := 0.0;
  FToneOct := 0.0;
  FFeedback := 0.0;
  FWet := 1.0;
  FOut := 1.0;
  FSmoothCoef := 0.0;
  FSettled := False;
end;

procedure TPcd.Prepare(SampleRate: Double);
var
  C: Integer;
begin
  if SampleRate > 0.0 then
    FFs := SampleRate
  else
    FFs := 48000.0;
  FClock.Prepare(FFs);
  FEnv.Prepare(FFs);
  FSmoothCoef := 1.0 - ExpD(-1.0 / (SmoothSeconds * FFs));
  FDcCoef := 1.0 - 2.0 * PiD * 5.0 / FFs;

  FLoopLength := MaxI(1, LRoundD(LoopSeconds * FFs));
  for C := 0 to 1 do
  begin
    FChannels[C].Loop := nil;
    SetLength(FChannels[C].Loop, FLoopLength);   // zeroed
  end;
  Reset;
end;

procedure TPcd.Reset;
var
  C: Integer;
begin
  FClock.Reset;
  FEnv.Reset;
  FLastStruck := -1;
  FSettled := False;
  for C := 0 to 1 do
    with FChannels[C] do
    begin
      Os.Reset;
      DcX := 0.0;
      DcY := 0.0;
      Lp1 := 0.0;
      Lp2 := 0.0;
      Bp1 := 0.0;
      Bp2 := 0.0;
      ComingBack := 0.0;
      if Length(Loop) > 0 then
        FillChar(Loop[0], Length(Loop) * SizeOf(Single), 0);
      FillChar(Dry, SizeOf(Dry), 0);
      LoopPos := 0;
      DryPos := 0;
    end;
end;

procedure TPcd.SetSettings(const S: TPcdSettings);
begin
  FTarget := S;
end;

procedure TPcd.SetHostClock(Playing: Boolean; Ppq, Bpm: Double);
begin
  FClock.SetClock(Playing, Ppq, Bpm, PcdStepsPerQuarter(FTarget.Rate));
  if not FClock.IsPlaying then
    FLastStruck := -1;
end;

function TPcd.Step: Integer;
begin
  Result := FLastStruck;
end;

function TPcd.Envelope: Single;
begin
  Result := FEnvNow;
end;

procedure TPcd.Process(Left, Right: PPcfSamples; N: Integer);
var
  DriveT, ToneT, FeedbackT, WetT, OutT, DriveAmount, ToneAmount, FeedbackAmount: Double;
  ToneHz, LoopGain, Ed, D, A, B, Clipped, Dc, Low, WetSide, Heard, Unused, Sung, DryD: Double;
  LowOct, HighOct: Double;
  F, E, X, DrySample: Single;
  Shape, I, C, K: Integer;
  St: Int64;
  Sides: array[0..1] of PPcfSamples;
  Curve: TCurve;
  Tone, Speaker: TSvf;
begin
  FEnv.SetDecay(FTarget.Decay);

  // where the knobs are heading
  D := ClampF(FTarget.Drive, 0, 1);
  DriveT := D * 127.0;   // ReBirth's AMOUNT
  F := ClampF(FTarget.Shape, 0, 1) * Full;
  Shape := LRoundF(F);
  D := ClampF(FTarget.Tone, 0, 1);
  ToneT := Log2D(ToneLow) + D * Log2D(ToneHigh / ToneLow);
  FeedbackT := ClampF(FTarget.Feedback, 0, 1);
  WetT := ClampF(FTarget.Mix, 0, 1);
  D := ClampF(FTarget.Level, -24, 12);
  OutT := PowD(10.0, D / 20.0);
  if not FSettled then
  begin
    FDrive := DriveT;
    FToneOct := ToneT;
    FFeedback := FeedbackT;
    FWet := WetT;
    FOut := OutT;
    FSettled := True;
  end;

  D := ClampF(FTarget.DriveAmount, 0, 1);
  DriveAmount := D * 127.0;
  D := ClampF(FTarget.ToneAmount, -1, 1);
  ToneAmount := D * 3.0;   // octaves
  FeedbackAmount := ClampF(FTarget.FeedbackAmount, 0, 1);

  Sides[0] := Left;
  Sides[1] := Right;
  E := 0;

  for I := 0 to N - 1 do
  begin
    St := 0;
    if FClock.StepAt(I, St) then
    begin
      K := Integer(((St mod PcdSteps) + PcdSteps) mod PcdSteps);
      FEnv.Strike(PcfLevel(FTarget.Pattern, K));
      FLastStruck := K;
    end;
    E := FEnv.Next;

    FDrive := FDrive + (DriveT - FDrive) * FSmoothCoef;
    FToneOct := FToneOct + (ToneT - FToneOct) * FSmoothCoef;
    FFeedback := FFeedback + (FeedbackT - FFeedback) * FSmoothCoef;
    FWet := FWet + (WetT - FWet) * FSmoothCoef;
    FOut := FOut + (OutT - FOut) * FSmoothCoef;

    // the pattern's push on each, on top of the knob
    Ed := E;
    Curve.Make(ClampD(FDrive + DriveAmount * Ed, 0.0, 127.0), Shape);
    LowOct := Log2D(200.0);
    HighOct := Log2D(16000.0);
    ToneHz := Exp2D(ClampD(FToneOct + ToneAmount * Ed, LowOct, HighOct));
    LoopGain := ClampD(FFeedback + FeedbackAmount * Ed, 0.0, 1.0) * MaxLoopGain;

    Tone.Make(ToneHz, FFs, ToneDamping);
    Speaker.Make(HowlFrequency(ToneHz), FFs, 1.0 / ResonanceQ);

    for C := 0 to 1 do
    begin
      if Sides[C] = nil then
        Continue;
      with FChannels[C] do
      begin
        X := Sides[C]^[I];

        // the clipper, at twice the rate, with what came back round the loop
        D := X;
        Os.Upsample(D + ComingBack, A, B);
        Clipped := Os.Downsample(Curve.Run(A), Curve.Run(B));

        // any DC out, the feedback's; then the tone
        Dc := Clipped - DcX + FDcCoef * DcY;
        DcX := Clipped;
        DcY := Dc;
        Low := 0.0;
        Tone.Run(Dc, Lp1, Lp2, Low);
        WetSide := Low;   // ReBirth's own gain out, no more

        // round the loop: the output, a moment later, through the speaker's resonance
        Heard := Loop[LoopPos];
        Loop[LoopPos] := WetSide;
        Inc(LoopPos);
        if LoopPos >= FLoopLength then
          LoopPos := 0;
        Unused := 0.0;
        Sung := Speaker.Run(Heard, Bp1, Bp2, Unused) / ResonanceQ;   // unity at the peak
        ComingBack := Sung * LoopGain;

        // the dry side, held back by the oversampling's delay, to meet the wet
        DrySample := Dry[DryPos];
        Dry[DryPos] := X;
        Inc(DryPos);
        if DryPos >= PcdLatency then
          DryPos := 0;

        DryD := DrySample;
        Sides[C]^[I] := (DryD * (1.0 - FWet) + WetSide * FWet) * FOut;
      end;
    end;
  end;

  FEnvNow := E;
end;

end.
