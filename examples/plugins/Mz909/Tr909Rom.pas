// Mz909 - an emulation of the TR-909 Rhythm Composer
// Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/TR909/Rom.h. The ROMs' contents (Roms.cpp) are in
// Tr909Roms.

unit Tr909Rom;

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
  // The 909's hihats and cymbals are not circuits but recordings: 6-bit samples in ROM, read
  // out by a counter on its own clock into a 6-bit DAC. Sixty-four levels is coarse - the
  // quiet end of a cymbal's decay is only a few steps tall - and that grain is a large part
  // of the 909's metal.
  //
  // Roland's recordings are Roland's, so these ROMs hold stand-ins, synthesized here once and
  // then stored exactly as the 909 stores its own: 6-bit, at a fixed clock. Everything after
  // the ROM - the clock, the DAC, the VCAs - is the 909's way of playing them.
  //
  TRom = record
    Data: array of ShortInt;   // -32 to 31
    Clock: Single;             // hertz, at TUNE's centre
  end;
  PRom = ^TRom;

const
  //
  // A DAC step as the host can carry it: the step through a low pass just under the host's
  // Nyquist (a Kaiser-windowed sinc, integrated), less the step itself. Added round each step,
  // it turns a staircase into the band-limited one an ideal converter and a good recorder
  // would give: flat to about 0.42 of the host's rate, little folding back from above.
  //
  StepHalf = 16;          // taps either side of the step; the latency
  StepPerSample = 64;     // the table's resolution
  StepTableSize = 2 * StepHalf * StepPerSample + 1;
  StepSpan = 2 * StepHalf;

// The step residual at t samples from the step, -StepHalf to StepHalf (StepResidual::at).
// The table is built once, when this unit initialises.
function StepResidualAt(T: Single): Single;

type
  //
  // A ROM's counter and DAC. The DAC holds each sample until the next, so its output is a
  // staircase whose steps fall at the ROM's clock, not the host's. Each step is placed at
  // its exact sub-sample time and band-limited there, so the stairs are kept but nothing
  // above the host's Nyquist folds back. That costs StepHalf samples of latency.
  //
  TRomPlayer = record
  private
    FRom: PRom;
    FFs, FSpeed: Single;
    FInc, FPos: Double;
    FIndex: Integer;
    FPlaying: Boolean;
    FHeld: Single;
    FHead, FDrain: Integer;
    FCorrections: array[0..StepSpan - 1] of Single;
    FStairs: array[0..StepSpan - 1] of Single;
  public
    procedure Init;
    procedure Prepare(SampleRate: Single);
    // the clock, as a ratio of the ROM's own; from the next Start
    procedure SetSpeed(Ratio: Single); inline;
    // From the top of a ROM. A new one takes over the DAC from wherever it was, so one
    // player switching ROMs is one DAC, as the hihats share.
    procedure Start(Rom: PRom);
    procedure Stop;
    function Next: Single;
    function Finished: Boolean; inline;
  end;

implementation

var
  StepTable: array[0..StepTableSize - 1] of Single;

procedure BuildStepResidual;
const
  Cutoff = 0.47;   // cycles per sample
  Beta = 6.0;      // the window's shape
var
  Step: array[0..StepTableSize - 1] of Double;
  I: Integer;
  Total, T, R, Sinc, Q, B0Beta, Sub: Double;

  function Bessel0(X: Double): Double;
  var
    K: Integer;
    Sum, Term, H: Double;
  begin
    Sum := 1;
    Term := 1;
    for K := 1 to 29 do
    begin
      H := X / (2 * K);
      Term := Term * (H * H);
      Sum := Sum + Term;
    end;
    Result := Sum;
  end;

begin
  Total := 0;
  B0Beta := Bessel0(Beta);
  for I := 0 to StepTableSize - 1 do
  begin
    T := I - StepHalf * StepPerSample;
    T := T / StepPerSample;
    R := T / StepHalf;
    if T = 0 then
      Sinc := 2 * Cutoff
    else
      Sinc := SinD(2 * Pi64 * Cutoff * T) / (Pi64 * T);
    Q := 1 - R * R;
    if Q < 0.0 then   // std::max(0.0, q)
      Q := 0.0;
    Total := Total + Sinc * Bessel0(Beta * Sqrt(Q)) / B0Beta;
    Step[I] := Total;
  end;
  for I := 0 to StepTableSize - 1 do
  begin
    if I >= StepHalf * StepPerSample then
      Sub := 1.0
    else
      Sub := 0.0;
    StepTable[I] := Step[I] / Total - Sub;
  end;
end;

function StepResidualAt(T: Single): Single;
var
  U, F, Hs, Ps: Single;
  I: Integer;
begin
  Hs := StepHalf;
  Ps := StepPerSample;
  U := (T + Hs) * Ps;
  I := Trunc(U);   // (int) u: toward zero
  if (I < 0) or (I + 1 >= StepTableSize) then
    Exit(0);
  F := I;
  F := U - F;
  Result := StepTable[I] + F * (StepTable[I + 1] - StepTable[I]);
end;

{ TRomPlayer }

procedure TRomPlayer.Init;
begin
  FRom := nil;
  FFs := 48000;
  FSpeed := 1;
  FInc := 0;
  FPos := 0;
  FIndex := -1;
  FPlaying := False;
  FHeld := 0;
  FHead := 0;
  FDrain := 0;
  FillChar(FCorrections, SizeOf(FCorrections), 0);
  FillChar(FStairs, SizeOf(FStairs), 0);
end;

procedure TRomPlayer.Prepare(SampleRate: Single);
begin
  FFs := SampleRate;
  Stop;
end;

procedure TRomPlayer.SetSpeed(Ratio: Single);
begin
  FSpeed := Ratio;
end;

procedure TRomPlayer.Start(Rom: PRom);
var
  C, S: Double;
begin
  FRom := Rom;
  C := FRom^.Clock;
  S := FSpeed;
  FInc := C * S / FFs;   // (double) clock * speed / fs, in double
  FPos := 0.0;
  FIndex := -1;
  FPlaying := True;
end;

procedure TRomPlayer.Stop;
var
  I: Integer;
begin
  FPlaying := False;
  FIndex := -1;
  FHeld := 0;
  FDrain := 0;
  for I := 0 to StepSpan - 1 do
    FCorrections[I] := 0;
  for I := 0 to StepSpan - 1 do
    FStairs[I] := 0;
end;

function TRomPlayer.Next: Single;
const
  DacStep = 1.0 / 32.0;   // 1.0f / 32.0f: exact
var
  Size, J, Slot: Integer;
  V, H, X, T: Single;
  XD: Double;
begin
  // ring slot FHead is the moment going out now, StepHalf samples ago
  if FPlaying then
  begin
    FPos := FPos + FInc;
    Size := Length(FRom^.Data);

    while (FIndex + 1) <= FPos do
    begin
      Inc(FIndex);
      if FIndex < Size then
      begin
        V := FRom^.Data[FIndex];
        V := V * DacStep;
      end
      else
        V := 0;
      H := V - FHeld;
      FHeld := V;

      if H <> 0 then
      begin
        // the step fell x samples before now; spread it over the moments round it
        XD := (FPos - FIndex) / FInc;
        X := XD;
        for J := 0 to StepSpan - 1 do
        begin
          Slot := (FHead + J) mod StepSpan;
          T := J - StepHalf;
          T := T + X;
          FCorrections[Slot] := FCorrections[Slot] + H * StepResidualAt(T);
        end;
      end;

      if FIndex >= Size then
      begin
        FPlaying := False;
        FDrain := StepSpan;
        Break;
      end;
    end;
  end
  else if FDrain > 0 then
    Dec(FDrain);

  FStairs[(FHead + StepHalf) mod StepSpan] := FHeld;
  Result := FStairs[FHead] + FCorrections[FHead];
  FCorrections[FHead] := 0;
  FHead := (FHead + 1) mod StepSpan;
end;

function TRomPlayer.Finished: Boolean;
begin
  Result := (not FPlaying) and (FDrain = 0);
end;

initialization
  BuildStepResidual;
end.
