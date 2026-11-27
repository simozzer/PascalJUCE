// MzPCF - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// PcfStepClock - the Object Pascal port of pcf::StepClock (Source/PCF/StepClock.h), the
// host's timeline as steps. MzPCG and MzPCD run theirs on it too, at 2, 4 or 8 steps to
// the beat.
//
// In double precision throughout, as the C++ (see PcfMath for the precision rules).

unit PcfStepClock;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

type
  //
  // The host's timeline, as steps: told where the timeline is at the top of each block, it
  // says on which samples of the block a step begins. The clock is run forward sample by
  // sample from there, and put right again every block, so a loop or a tempo change is
  // followed within one block.
  //
  // A step lands on its first sample. Arriving in the middle of one - starting playback
  // there, or a jump - waits for the next, as a step sequencer would; arriving on its first
  // sample, as a loop back to the bar does, strikes it. Steps are counted from the top of
  // the song, so step 0 of a pattern is always the first of a bar.
  //
  // A record: call Init once (the C++ member initialisers), then Prepare.
  //
  TPcfStepClock = record
  private
    FFs: Double;
    FPlaying: Boolean;
    FStepsPerQuarter: Integer;
    FPosition, FPerSample: Double;
    FCurrent: Int64;          // the step the last sample fell in (negative in a pre-roll)
    FHaveCurrent: Boolean;    // false until the first sample after starting
  public
    procedure Init;
    procedure Prepare(SampleRate: Double);
    procedure Reset;

    // Where the timeline is at the top of the next block; PerQuarter steps to the beat.
    procedure SetClock(IsPlaying: Boolean; Ppq, Bpm: Double; PerQuarter: Integer = 4);

    function IsPlaying: Boolean; inline;
    function SamplesPerStep: Double;

    // Whether a step begins on sample I of this block, and which.
    function StepAt(I: Integer; out Step: Int64): Boolean;
  end;

implementation

uses
  PcfMath;

const
  // due on this sample, give or take rounding
  Rounding: Double = 1.0e-9;

procedure TPcfStepClock.Init;
begin
  FFs := 48000.0;
  FPlaying := False;
  FStepsPerQuarter := 4;
  FPosition := 0.0;
  FPerSample := 0.0;
  FCurrent := 0;
  FHaveCurrent := False;
end;

procedure TPcfStepClock.Prepare(SampleRate: Double);
begin
  if SampleRate > 0.0 then
    FFs := SampleRate
  else
    FFs := 48000.0;
  Reset;
end;

procedure TPcfStepClock.Reset;
begin
  FHaveCurrent := False;
end;

procedure TPcfStepClock.SetClock(IsPlaying: Boolean; Ppq, Bpm: Double; PerQuarter: Integer);
var
  Q: Double;
begin
  FPlaying := IsPlaying and (Bpm > 0.0) and IsFiniteD(Ppq) and (PerQuarter > 0);
  if not FPlaying then
  begin
    FHaveCurrent := False;
    Exit;
  end;

  if PerQuarter <> FStepsPerQuarter then
    FHaveCurrent := False;   // a new grid: start it afresh
  FStepsPerQuarter := PerQuarter;
  Q := PerQuarter;
  FPosition := Ppq * Q;
  FPerSample := Bpm / 60.0 * Q / FFs;
end;

function TPcfStepClock.IsPlaying: Boolean;
begin
  Result := FPlaying;
end;

function TPcfStepClock.SamplesPerStep: Double;
begin
  if FPerSample > 0.0 then
    Result := 1.0 / FPerSample
  else
    Result := FFs;
end;

function TPcfStepClock.StepAt(I: Integer; out Step: Int64): Boolean;
var
  At, D: Double;
  S: Int64;
  Next, OnTheStep: Boolean;
begin
  Result := False;
  if not FPlaying then
    Exit;

  D := I;
  At := FPosition + D * FPerSample;
  S := Trunc(FloorD(At + Rounding));
  if FHaveCurrent and (S = FCurrent) then
    Exit;

  Next := FHaveCurrent and (S = FCurrent + 1);
  D := S;
  OnTheStep := At - D < FPerSample;
  FCurrent := S;
  FHaveCurrent := True;
  Step := S;
  Result := Next or OnTheStep;
end;

end.
