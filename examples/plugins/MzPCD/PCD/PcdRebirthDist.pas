// MzPCD - Created by Simon Moscrop
//
// THE REBIRTH DISTORTION, as OpenRB-338 decoded it: the Object Pascal port of MzPCD's
// Source/PCD/RebirthDist.h, itself a C++ port of orb-engine's Distortion
// (crates/orb-engine/src/dist.rs) and the two tables it reads (tables/mod.rs: the level curve
// and the waveshaper). Copyright (C) 2026 the OpenRB-338 authors, and these ports Simon
// Moscrop. This file is under the GNU GPL v3 (OpenRB-338's licence); the program it is
// compiled into is under the GNU AGPL v3, which section 13 of each allows.
//
// https://github.com/pingw33n/openrb-338
//
// Double and Single exactly where the C++ has double and float, the C library's sin
// (PcdMath), so it gives the C++'s numbers bit for bit (verify/build_verify.cmd).

unit PcdRebirthDist;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$MINFPCONSTPREC 64}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  PcfMath;

type
  TRbRow = array[0..255] of Single;
  PRbRow = ^TRbRow;

  //
  // The tables, built once (when the unit is initialised), as the original built them - in
  // doubles, each stored as a float.
  //
  //   Level[i]       a level or amount knob 0..127 as a gain: Level[127] = 1, each step down
  //                  1/24 less, Level[0] = 0
  //   Shaper[t][e]   the waveshaper, a row for every fourth SHAPE: a sine's first part
  //                  bending into a straight line, the row's number how far round the sine
  //                  goes
  //
  TRbTables = record
    Level: array[0..127] of Single;
    Shaper: array[0..31] of TRbRow;
  end;
  PRbTables = ^TRbTables;

// rbdist::Tables::get()
function RbTables: PRbTables; inline;

// The output gain's grid, GRID[shape][amount] at 0, 1, .. 4 of x/127 * 3.999.
function RbGrid(Shape, Amount: Double): Double;

// The level curve between its steps, for an amount that moves smoothly.
function RbLevel(Amount: Double): Double;

// The gain into the shaper, and out of it.
function RbInGain(Amount: Double): Double;
function RbOutGain(Shape, Amount: Double): Double;

// SHAPE 0: a hard clip instead of the shaper - the gain in, and where it clips, which stops
// coming down from amount 90.
function RbClipGain(Amount: Double): Double;
function RbClipThreshold(Amount: Double): Double;

// The shaper's row for a SHAPE 1..127.
function RbRow(Shape: Integer): PRbRow;

// A row looked up at V = gain * x + 128: its first entry below 0, entry 254 above 254, and
// between, the two entries either side.
function RbShape(W: PRbRow; V: Double): Double;

type
  //
  // The unit as ReBirth ran it, on one side of one channel (rbdist::Distortion). ReBirth
  // worked in blocks of 64 samples at 44.1 kHz: on every block the gains move a tenth of the
  // way to where AMOUNT and SHAPE put them, and every 16 blocks it looks at the knobs again.
  // Here a block is as long in time at any rate, so the knobs answer as slowly as they did.
  // Switching it in brings the gains up from where they were left, as ReBirth's did - from
  // nothing, the first time.
  //
  // AMOUNT and SHAPE are ReBirth's, 0 to 127; SHAPE 0 is ReBirth 1.5's hard clip.
  //
  // MzPCD's own distortion does not use it (it moves AMOUNT smoothly, through the functions
  // above); it is here as the C++ header has it, and checked against it.
  //
  // A record: call Init once (the C++ member initialisers), then Prepare.
  //
  TRbDistortion = record
  private
    FBlockLength, FAt: Integer;
    FCounter: Word;
    FClip: Boolean;
    FRow: Integer;
    FGainIn, FGainOut, FTargetIn, FTargetOut: Single;
    FCg, FTh: Double;
    procedure StartBlock(Amount, ShapeKnob: Integer);
  public
    procedure Init;
    procedure Prepare(Rate: Double);
    procedure Reset;
    procedure Process(X: PPcfSamples; N, Amount, ShapeKnob: Integer);
  end;

implementation

uses
  PcdMath;

var
  Tables: TRbTables;

function RbTables: PRbTables;
begin
  Result := @Tables;
end;

function F32(Bits: Cardinal): Double;
var
  F: Single;
begin
  Move(Bits, F, SizeOf(F));
  Result := F;
end;

procedure BuildTables;
const
  Seven: Double = 0.7;
var
  Step, D, C961, Pi8, Pi1024, Inc_, Ph, Y, Z, S, V: Double;
  I, T, E: Integer;
begin
  Step := F32($3D2AAAAB);   // 0.041666668, a 24th
  Tables.Level[127] := 1;
  for I := 126 downto 1 do
  begin
    D := Tables.Level[I + 1];
    Tables.Level[I] := D - Step * D;
  end;
  Tables.Level[0] := 0;

  // pi/8 and pi/1024 as the original had them, pi cut short
  C961 := F32($3A88642A);
  Pi8 := F32($3EC90FD0);
  Pi1024 := F32($3B490FD0);
  for T := 0 to 31 do
  begin
    D := T * T;
    Inc_ := ((D * C961) * Pi8) + Pi1024;
    Ph := 0.0;
    Y := 0.0;
    Z := 0.0;
    for E := 128 to 255 do
    begin
      S := SinD(Ph) * 256.0;
      V := ((S * (1.0 - Y)) + ((Y * Z) * 256.0)) * Seven;
      Tables.Shaper[T][E] := V;
      Tables.Shaper[T][256 - E] := -V;   // E = 128 makes it -0
      Y := Y + 1.0 / 128.0;
      Z := Z + 1.0 / 128.0;
      Ph := Ph + Inc_;
    end;
    Tables.Shaper[T][0] := -Tables.Shaper[T][255];
  end;
end;

const
  GridTable: array[0..4, 0..4] of Single = (
    (1.2,  0.4,  0.28, 0.2,  0.15),
    (0.35, 0.2,  0.15, 0.14, 0.12),
    (0.2,  0.15, 0.13, 0.12, 0.12),
    (0.15, 0.12, 0.11, 0.1,  0.1 ),
    (0.12, 0.1,  0.08, 0.08, 0.08)
  );
  GridScale: Double = 3.999;

var
  C127: Double;   // (double) (float) (1.0 / 127.0): f32(1/127) as the original, near enough

function G(R, C: Integer): Double; inline;
begin
  Result := GridTable[R, C];
end;

function RbGrid(Shape, Amount: Double): Double;
var
  S, A, Fs, Fa, Top, Bot: Double;
  I, J: Integer;
begin
  S := (ClampD(Shape, 0.0, 127.0) * C127) * GridScale;
  A := (ClampD(Amount, 0.0, 127.0) * C127) * GridScale;
  I := Trunc(S);
  J := Trunc(A);
  Fs := S - I;
  Fa := A - J;
  Top := (G(I + 1, J + 1) - G(I + 1, J)) * Fa + G(I + 1, J);
  Bot := (G(I, J + 1) - G(I, J)) * Fa + G(I, J);
  Result := Fs * (Top - Bot) + Bot;
end;

function RbLevel(Amount: Double): Double;
var
  A, L0, L1: Double;
  I: Integer;
begin
  A := ClampD(Amount, 0.0, 127.0);
  I := Trunc(A);
  if I > 126 then   // std::min(126, (int) a)
    I := 126;
  L0 := Tables.Level[I];
  L1 := Tables.Level[I + 1];
  Result := L0 + (A - I) * (L1 - L0);
end;

function RbInGain(Amount: Double): Double;
begin
  Result := (RbLevel(Amount) + 0.0625) * 2048.0;
end;

function RbOutGain(Shape, Amount: Double): Double;
begin
  Result := RbGrid(Shape, Amount) * 5.0 * (1.0 / 256.0);
end;

function RbClipGain(Amount: Double): Double;
begin
  Result := 16.0 * RbLevel(Amount) + 1.0;
end;

function RbClipThreshold(Amount: Double): Double;
begin
  Result := 1.0 / RbClipGain(MinD(Amount, 90.0));
end;

function RbRow(Shape: Integer): PRbRow;
begin
  Result := @Tables.Shaper[ClampI(Shape, 0, 127) shr 2];
end;

function RbShape(W: PRbRow; V: Double): Double;
var
  I: Integer;
  A, B: Double;
begin
  if V < 0.0 then
    Exit(W^[0]);
  if V > 254.0 then
    Exit(W^[254]);
  I := Trunc(V);
  A := W^[I + 1];
  B := W^[I];
  Result := (V - I) * (A - B) + B;
end;

{ TRbDistortion }

procedure TRbDistortion.Init;
begin
  FBlockLength := 64;
  FAt := 0;
  FCounter := 0;
  FClip := False;
  FRow := 0;
  FGainIn := 0;
  FGainOut := 0;
  FTargetIn := 0;
  FTargetOut := 0;
  FCg := 1.0;
  FTh := 1.0;
end;

procedure TRbDistortion.Prepare(Rate: Double);
begin
  FBlockLength := MaxI(1, LRoundD(64.0 * Rate / 44100.0));
  Reset;
end;

procedure TRbDistortion.Reset;
begin
  FAt := 0;
  FCounter := 0;
  FClip := False;
  FRow := 0;
  FGainIn := 0;
  FGainOut := 0;
  FTargetIn := 0;
  FTargetOut := 0;
end;

procedure TRbDistortion.StartBlock(Amount, ShapeKnob: Integer);
const
  Nine: Double = 0.9;
  One: Double = 0.1;
var
  D, E: Double;
begin
  if (FCounter and 15) = 0 then
  begin
    FClip := ShapeKnob = 0;
    FTargetIn := RbInGain(Amount);
    FRow := ShapeKnob shr 2;
    FTargetOut := RbOutGain(ShapeKnob, Amount);
  end;
  FCounter := Word(FCounter + 1);
  D := FGainIn;
  E := FTargetIn;
  FGainIn := D * Nine + E * One;
  D := FGainOut;
  E := FTargetOut;
  FGainOut := D * Nine + E * One;

  // the clip reads AMOUNT on every block, not just every 16th
  D := Tables.Level[Amount];
  FCg := 16.0 * D + 1.0;
  if Amount < 90 then
    FTh := 1.0 / FCg
  else
  begin
    D := Tables.Level[90];
    FTh := 1.0 / (16.0 * D + 1.0);
  end;
end;

procedure TRbDistortion.Process(X: PPcfSamples; N, Amount, ShapeKnob: Integer);
var
  I: Integer;
  D, Gi, Go: Double;
begin
  Amount := ClampI(Amount, 0, 127);
  ShapeKnob := ClampI(ShapeKnob, 0, 127);

  for I := 0 to N - 1 do
  begin
    if FAt = 0 then
      StartBlock(Amount, ShapeKnob);
    Inc(FAt);
    if FAt >= FBlockLength then
      FAt := 0;

    D := X^[I];
    if FClip then
      X^[I] := ClampD(FCg * D, -FTh, FTh)
    else
    begin
      Gi := FGainIn;
      Go := FGainOut;
      X^[I] := RbShape(@Tables.Shaper[FRow], Gi * D + 128.0) * Go;
    end;
  end;
end;

var
  C127D: Double;
  C127F: Single;

initialization
  BuildTables;
  C127D := 1.0;
  C127D := C127D / 127.0;
  C127F := C127D;   // (float) c127
  C127 := C127F;
end.
