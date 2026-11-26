// Mz101 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/SH101/Lfo.h.

unit Sh101Lfo;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  Sh101Dsp;

type
  TLfoTick = record
    Value: Single;
    CycleStart: Boolean;
    HalfCycle: Boolean;
  end;

  //
  // THE MODULATOR
  //
  // Triangle (the 101 has no sine) and square from one oscillator; NOISE is the noise
  // generator itself, lowpassed only by the modulation path.
  //
  // RANDOM is NOT a sample-and-hold of the noise. The service manual's CPU program has the
  // CPU generate random data each time it sees the clock go high (step 6a) and write it out
  // through the D/A converter (step 7) - so the engine supplies it, via SetRandom.
  //
  // It is also the instrument's clock: the CPU watches its square (ClockHigh) to step the
  // arpeggiator and sequencer, and the envelope's LFO trigger takes it directly, so this
  // also reports where each cycle starts.
  //
  TLfo = record
  private
    FPhase: Single;
    FHeld: Single;
    FNoiseLp: Single;
    FNoiseCoef: Single;
    FPendingStart: Boolean;
    function Output(const T: TLfoTick; Wave: Integer; var Rng: TRandom): TLfoTick;
  public
    procedure Init;
    procedure SetSampleRate(R: Single);
    procedure Reset;

    // The CPU's Clock Reset: start a cycle on the very next sample.
    procedure Restart;

    // The square, as the CPU's clock input sees it.
    function ClockHigh: Boolean; inline;

    // The CPU's random data, for the RANDOM waveform.
    procedure SetRandom(V: Single); inline;

    // Free running: advance by an increment, as the hardware oscillator does.
    function Process(Increment: Single; Wave: Integer; var Rng: TRandom): TLfoTick;

    // Synced: put at a phase worked out from the host's timeline. Going backwards - the
    // cycle wrapping, or the host jumping back - is a new cycle.
    function ProcessAt(Target: Single; Wave: Integer; var Rng: TRandom): TLfoTick;
  end;

implementation

uses
  Sh101Settings;

const
  DefaultNoiseCoef: Single = 0.05;

procedure TLfo.Init;
begin
  FPhase := 0;
  FHeld := 0;
  FNoiseLp := 0;
  FNoiseCoef := DefaultNoiseCoef;
  FPendingStart := False;
end;

procedure TLfo.SetSampleRate(R: Single);
begin
  FNoiseCoef := OnePoleCoef(1 / (2 * PiF * 400), R);
end;

procedure TLfo.Reset;
begin
  FPhase := 0;
  FHeld := 0;
  FNoiseLp := 0;
  FPendingStart := False;
end;

procedure TLfo.Restart;
begin
  FPhase := 0;
  FPendingStart := True;
end;

function TLfo.ClockHigh: Boolean;
begin
  Result := FPhase < 0.5;
end;

procedure TLfo.SetRandom(V: Single);
begin
  FHeld := V;
end;

function TLfo.Process(Increment: Single; Wave: Integer; var Rng: TRandom): TLfoTick;
var
  T: TLfoTick;
  Was: Single;
begin
  T.Value := 0;
  T.CycleStart := False;
  T.HalfCycle := False;

  if FPendingStart then
  begin
    FPendingStart := False;
    T.CycleStart := True;
  end
  else
  begin
    Was := FPhase;
    FPhase := FPhase + Increment;

    if FPhase >= 1 then
    begin
      FPhase := FPhase - 1;
      T.CycleStart := True;
    end
    else if (Was < 0.5) and (FPhase >= 0.5) then
      T.HalfCycle := True;
  end;

  Result := Output(T, Wave, Rng);
end;

function TLfo.ProcessAt(Target: Single; Wave: Integer; var Rng: TRandom): TLfoTick;
var
  T: TLfoTick;
begin
  T.Value := 0;
  T.CycleStart := False;
  T.HalfCycle := False;
  FPendingStart := False;

  if Target < FPhase then
    T.CycleStart := True
  else if (FPhase < 0.5) and (Target >= 0.5) then
    T.HalfCycle := True;

  FPhase := Target;
  Result := Output(T, Wave, Rng);
end;

function TLfo.Output(const T: TLfoTick; Wave: Integer; var Rng: TRandom): TLfoTick;
begin
  Result := T;
  FNoiseLp := FNoiseLp + (Rng.Noise - FNoiseLp) * FNoiseCoef;

  case Wave of
    LfoWaveSquare:
      if FPhase < 0.5 then
        Result.Value := 1
      else
        Result.Value := -1;
    LfoWaveRandom:
      Result.Value := FHeld;
    LfoWaveNoise:
      Result.Value := Clamp(FNoiseLp * 6, -1, 1);
  else
    if FPhase < 0.5 then
      Result.Value := 4 * FPhase - 1
    else
      Result.Value := 3 - 4 * FPhase;
  end;
end;

end.
