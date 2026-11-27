// MzPCF - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// PcfEngine - the Object Pascal port of pcf::Settings (Source/PCF/Settings.h), pcf::Filter
// and pcf::Pcf (Source/PCF/Pcf.h, Pcf.cpp): the whole pattern-controlled filter, as the
// plug-in plays it. No dependency on the plug-in layer: the plug-in (MzPcfPlugin) and the
// equivalence check (verify/render_pas.dpr) drive it the same way.
//
// Single and Double exactly where the C++ has float and double, the C library's maths
// (see PcfMath), so it renders the C++'s samples bit for bit.

unit PcfEngine;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  PcfMath, PcfPatterns, PcfStepClock, PcfEnvelope;

const
  // pcf::Mode
  PcfModeLP = 0;
  PcfModeBP = 1;

type
  //
  // The front panel, in panel units. The PCF's own five controls run 0 to 1 as on the
  // rack (MzDebirth); MIX and LEVEL are not on ReBirth's panel - a DAW insert wants them.
  //
  TPcfSettings = record
    Pattern: Integer;   // 0 to 31
    Freq: Single;       // where the filter rests, 40 Hz to 10 kHz
    Q: Single;          // resonance, Q 0.5 to 20
    Amount: Single;     // how far a full-level step opens it, up to seven octaves
    Decay: Single;      // how fast it closes again, 15 ms to 1.5 s
    Mode: Integer;      // PcfModeLP or PcfModeBP
    Mix: Single;        // 0 dry to 1 all through the filter
    Level: Single;      // output, dB, -24 to +12
    // The C++ defaults (the member initialisers).
    class function Defaults: TPcfSettings; static;
  end;

  TPcfSvf = record
    Ic1, Ic2: Single;
  end;

  //
  // The filter: a state-variable filter whose cutoff the envelope opens, by AMT octaves
  // above FREQ at full level. Its knobs are smoothed here, so turning one does not zip.
  // One envelope can play any number of these - the rack has one per channel.
  //
  TPcfFilter = record
  private
    FFs: Double;
    FOctaves, FReach, FDamping, FWet, FGain: Single;
    FSmoothCoef: Single;
    FSettled: Boolean;
    FState: array[0..1] of TPcfSvf;
  public
    procedure Init;
    procedure Prepare(SampleRate: Double);
    procedure Reset;
    // In place. Env: the envelope, a value a sample. Right may be nil, for a mono channel.
    procedure Process(Left, Right: PPcfSamples; Env: PPcfSamples; N: Integer; const S: TPcfSettings);
  end;

  //
  // The whole PCF, as the plug-in plays it: the envelope struck on every sixteenth of the
  // host's timeline at that step's level in the pattern, playing the filter - so the
  // filter plays a rhythm of its own over whatever goes through it.
  //
  // It follows the host's transport, as ReBirth's PCF followed its own: stopped, nothing is
  // struck and the filter settles back to FREQ.
  //
  // A record: call Init once (the C++ constructor), then Prepare.
  //
  TPcf = record
  private
    FTarget: TPcfSettings;
    FClock: TPcfStepClock;    // in sixteenths
    FLastStruck: Integer;
    FEnv: TPcfEnvelope;
    FFilter: TPcfFilter;
    procedure Strike(Sixteenth: Int64);
  public
    procedure Init;
    procedure Prepare(SampleRate: Double);
    procedure Reset;

    procedure SetSettings(const S: TPcfSettings);

    // Where the host's timeline is at the top of the next block. The clock is run forward
    // sample by sample from there, and put right again every block, so a loop or a tempo
    // change is followed within one block.
    procedure SetHostClock(Playing: Boolean; Ppq, Bpm: Double);

    // In place. Right may be nil, for a mono channel.
    procedure Process(Left, Right: PPcfSamples; N: Integer);

    // The step last struck, for the panel's lights; -1 stopped.
    function Step: Integer; inline;
    // The envelope as it stands, 0 to 1 - for the checks.
    function Envelope: Single; inline;
    property Settings: TPcfSettings read FTarget;
  end;

implementation

const
  PiF: Single = 3.14159265358979;   // pcf's pi, a float
  SmoothSeconds: Single = 0.010;     // 0.010f
  CeilingRatio: Single = 0.45;       // 0.45f
  DefaultFreq: Single = 0.35;
  DefaultQ: Single = 0.4;
  DefaultAmount: Single = 0.6;
  DefaultDecay: Single = 0.35;
  Chunk = 64;

{ TPcfSettings }

class function TPcfSettings.Defaults: TPcfSettings;
begin
  Result.Pattern := 0;
  Result.Freq := DefaultFreq;
  Result.Q := DefaultQ;
  Result.Amount := DefaultAmount;
  Result.Decay := DefaultDecay;
  Result.Mode := PcfModeLP;
  Result.Mix := 1;
  Result.Level := 0;
end;

{ TPcfFilter }

procedure TPcfFilter.Init;
begin
  FFs := 48000.0;
  FOctaves := 0;
  FReach := 0;
  FDamping := 1;
  FWet := 1;
  FGain := 1;
  FSmoothCoef := 0;
  FSettled := False;
  FState[0].Ic1 := 0;
  FState[0].Ic2 := 0;
  FState[1].Ic1 := 0;
  FState[1].Ic2 := 0;
end;

procedure TPcfFilter.Prepare(SampleRate: Double);
begin
  if SampleRate > 0.0 then
    FFs := SampleRate
  else
    FFs := 48000.0;
  FSmoothCoef := PcfFollow(SmoothSeconds, FFs);
  Reset;
end;

procedure TPcfFilter.Reset;
var
  C: Integer;
begin
  for C := 0 to 1 do
  begin
    FState[C].Ic1 := 0;
    FState[C].Ic2 := 0;
  end;
  FSettled := False;   // the knobs jump straight to where they are, the next block
end;

procedure TPcfFilter.Process(Left, Right: PPcfSamples; Env: PPcfSamples; N: Integer; const S: TPcfSettings);
var
  OctT, ReachT, Qv, DampT, WetT, GainT, Ceiling, PiOverFs, FsF: Single;
  Fc, G, K, A1, A2, A3, X, V1, V2, V3, Y: Single;
  BandPass: Boolean;
  Sides: array[0..1] of PPcfSamples;
  I, C: Integer;
begin
  // where the knobs are heading
  OctT := ClampF(S.Freq, 0, 1) * 8;          // 40 Hz to 10 kHz
  ReachT := ClampF(S.Amount, 0, 1) * 7;      // octaves
  Qv := 0.5 + S.Q * S.Q * 19.5;
  DampT := 1 / Qv;
  WetT := ClampF(S.Mix, 0, 1);
  GainT := PowF(10, ClampF(S.Level, -24, 12) / 20);
  BandPass := S.Mode = PcfModeBP;

  if not FSettled then
  begin
    FOctaves := OctT;
    FReach := ReachT;
    FDamping := DampT;
    FWet := WetT;
    FGain := GainT;
    FSettled := True;
  end;

  FsF := FFs;                                // (float) fs
  Ceiling := FsF * CeilingRatio;
  PiOverFs := PiF / FsF;

  Sides[0] := Left;
  Sides[1] := Right;

  for I := 0 to N - 1 do
  begin
    FOctaves := FOctaves + (OctT - FOctaves) * FSmoothCoef;
    FReach := FReach + (ReachT - FReach) * FSmoothCoef;
    FDamping := FDamping + (DampT - FDamping) * FSmoothCoef;
    FWet := FWet + (WetT - FWet) * FSmoothCoef;
    FGain := FGain + (GainT - FGain) * FSmoothCoef;

    Fc := MinF(Ceiling, 40 * Exp2F(FOctaves + FReach * Env^[I]));
    G := TanF(PiOverFs * Fc);
    K := FDamping;
    A1 := 1 / (1 + G * (G + K));
    A2 := G * A1;
    A3 := G * A2;

    // Zavalishin's trapezoidal SVF, which keeps its tuning and stays stable however fast
    // the cutoff moves
    for C := 0 to 1 do
    begin
      if Sides[C] = nil then
        Continue;
      X := Sides[C]^[I];
      V3 := X - FState[C].Ic2;
      V1 := A1 * FState[C].Ic1 + A2 * V3;
      V2 := FState[C].Ic2 + A2 * FState[C].Ic1 + A3 * V3;
      FState[C].Ic1 := 2 * V1 - FState[C].Ic1;
      FState[C].Ic2 := 2 * V2 - FState[C].Ic2;

      // the band output scaled to unity at its peak, whatever the Q, then lifted to sit
      // level with the low-pass
      if BandPass then
        Y := V1 * K * 1.5
      else
        Y := V2;
      Sides[C]^[I] := (X + (Y - X) * FWet) * FGain;
    end;
  end;
end;

{ TPcf }

procedure TPcf.Init;
begin
  FTarget := TPcfSettings.Defaults;
  FClock.Init;
  FLastStruck := -1;
  FEnv.Init;
  FFilter.Init;
end;

procedure TPcf.Prepare(SampleRate: Double);
var
  Fs: Double;
begin
  if SampleRate > 0.0 then
    Fs := SampleRate
  else
    Fs := 48000.0;
  FClock.Prepare(Fs);
  FEnv.Prepare(Fs);
  FFilter.Prepare(Fs);
  Reset;
end;

procedure TPcf.Reset;
begin
  FEnv.Reset;
  FFilter.Reset;
  FClock.Reset;
  FLastStruck := -1;
end;

procedure TPcf.SetSettings(const S: TPcfSettings);
begin
  FTarget := S;
end;

procedure TPcf.SetHostClock(Playing: Boolean; Ppq, Bpm: Double);
begin
  FClock.SetClock(Playing, Ppq, Bpm);
  if not FClock.IsPlaying then
    FLastStruck := -1;
end;

procedure TPcf.Strike(Sixteenth: Int64);
var
  S: Integer;
begin
  S := Integer(((Sixteenth mod PcfStepCount) + PcfStepCount) mod PcfStepCount);
  FEnv.Strike(PcfLevel(FTarget.Pattern, S));
  FLastStruck := S;
end;

procedure TPcf.Process(Left, Right: PPcfSamples; N: Integer);
var
  E: array[0..Chunk - 1] of Single;
  From, Len, I: Integer;
  Sixteenth: Int64;
  R: PPcfSamples;
begin
  FEnv.SetDecay(FTarget.Decay);

  // the envelope a chunk at a time, then the filter over that chunk
  From := 0;
  while From < N do
  begin
    Len := MinI(Chunk, N - From);

    for I := 0 to Len - 1 do
    begin
      // struck on the first sample of each sixteenth
      Sixteenth := 0;
      if FClock.StepAt(From + I, Sixteenth) then
        Strike(Sixteenth);

      E[I] := FEnv.Next;
    end;

    if Right <> nil then
      R := @Right^[From]
    else
      R := nil;
    FFilter.Process(@Left^[From], R, @E[0], Len, FTarget);
    Inc(From, Chunk);
  end;
end;

function TPcf.Step: Integer;
begin
  Result := FLastStruck;
end;

function TPcf.Envelope: Single;
begin
  Result := FEnv.Value;
end;

end.
