// Mz101 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/SH101/Engine.h and Engine.cpp.

unit Sh101Engine;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  Sh101Dsp, Sh101Settings, Sh101Sync, Sh101Decimator, Sh101Envelope, Sh101Lfo, Sh101Vcf,
  Sh101Vco;

const
  MaxSteps = 100;

  // A sequencer step, packed: note in the low seven bits, then REST, then TIE - this step
  // is entered legato from the one before, with no new envelope.
  StepRest = UInt32(1) shl 7;
  StepTie  = UInt32(1) shl 8;
  StepNoteMask = $7F;

type
  TEngineMode = (emKeyboard, emArpeggio, emSequence);

  TEventType = (evOn, evOff, evKeyTranspose, evLegato);

  TEngineEvent = record
    Kind: TEventType;
    Note: Byte;
  end;

  TTargets = record
    CutoffLog, K, Pw: Single;
    Pulse, Saw, Sub, Noise: Single;
    EnvOct, VcfModOct, Kybd: Single;
    VcoModOct, ModDepthOct, BendOct, BendVcfOct: Single;
    Volume: Single;
  end;

  //
  // One SH-101: the CPU's key assigner, arpeggiator and sequencer, then modulator, VCO,
  // mixer, VCF, VCA and envelope, oversampled.
  //
  // THE CPU
  //
  // Keys, buttons and the clock do not reach the analog circuits directly. An 80C49 runs a
  // loop (service manual, "CPU PROGRAM", steps 3-13) every 1.5 to 3.5 ms: read the keyboard,
  // check the clock, read the buttons, then write the KCV, gate and LED outputs. So a key
  // pressed lands up to a few milliseconds late, and an arpeggio or sequence step lands on the
  // first pass after the clock edge rather than on the edge. That small, uneven latency is part
  // of how the 101 feels, so it is modelled: notes and buttons are queued, and acted on only
  // when the simulated CPU next comes round.
  //
  // Monophonic with last-note priority. No velocity - the 101 has none.
  //
  // Everything is called from the audio thread, between Render calls. (The C++ makes the
  // sequencer and KEY TRANSPOSE state atomic for its editor's readout; there is no custom
  // editor here, so they are plain fields.)
  //
  TEngine = class
  private
    FSettings: TSettings;
    FMode: TEngineMode;
    FTgt, FCur: TTargets;
    FPrimed: Boolean;

    FHostRate, FRateInt: Single;
    FFactor: Integer;

    FVco: TVco;
    FVcf: TVcf;
    FEnv: TEnvelope;
    FLfo: TLfo;
    FDecimator: TDecimator;
    FRng: TRandom;

    // the CPU's inbox and its loop
    FQueue: array[0..255] of TEngineEvent;
    FQueued: Integer;
    FCpuCountdown: Integer;
    FClockWasHigh: Boolean;

    // the host clock
    FHostAvailable, FHostPlaying: Boolean;
    FHostPpq, FHostPpqPerTick: Double;

    // The synced modulator's own copy of the timeline. It follows the host while the
    // transport runs, and keeps going at the last tempo while it is stopped, so the sound
    // does not freeze.
    FLfoPpq, FLfoPpqPerTick, FLastBpm: Double;
    FSyncQuarters: Double;

    // keyboard
    FHeld: array[0..127] of Integer;
    FNumHeld: Integer;
    FKey: Integer;
    FGate: Boolean;
    FGlide: Boolean;
    FKeyTarget, FKeyCv: Single;

    // KEY TRANSPOSE: a shift added to the RANGE data, so it moves the VCO but not the
    // filter's keyboard tracking
    FTransposeArmed: Boolean;
    FShift: Integer;

    // arpeggio: the notes it cycles through, low to high
    FArpNotes: array[0..127] of Integer;
    FArpCount, FArpIdx, FArpDir: Integer;

    // sequencer
    FSteps: array[0..MaxSteps - 1] of UInt32;
    FLength, FPosition: Integer;
    FLegatoArmed: Boolean;
    FSeqRunning: Boolean;
    FSeqResting: Boolean;
    FSeqTranspose: Integer;

    // controllers
    FBend, FModLever: Single;

    // derived per block
    FLfoInc, FPortaCoef, FSmoothCoef, FGateCoef: Single;
    FRange: Integer;
    FTransposeOct, FTuneOct, FMaxFc: Single;

    // the analog around the edges
    FGateLevel: Single;
    FDrift, FDriftTarget, FDriftCoef: Single;
    FDriftCountdown: Integer;
    FJitter, FJitterCoef: Single;
    FSag, FSagCoef, FRegulated, FRegulatorCoef: Single;
    FRipplePhase, FRippleInc: Single;

    FMixX1, FMixY1, FMixCoef: Single;
    FDcX1, FDcY1, FDcCoef: Single;
    FVolume, FVolumeCoef: Single;

    function ModeFor(const S: TSettings): TEngineMode;
    procedure EnterMode(M: TEngineMode);
    procedure UpdateTargets;

    // the CPU
    procedure Push(T: TEventType; Note: Integer);
    procedure CpuPass;
    procedure KeyDown(Note: Integer);
    procedure KeyUp(Note: Integer);
    procedure ClockRise;
    procedure ClockFall;
    procedure ClockReset;
    function UsingHostClock: Boolean;
    function LfoSynced: Boolean;
    function ClockHigh: Boolean;

    function Tick: Single;

    procedure PlayKey(Note: Integer; IsLegato, Retrigger: Boolean);
    procedure GateOn(Retrigger: Boolean);
    procedure GateOff;
    procedure TriggerEnvelope;

    procedure RemoveHeld(Note: Integer);
    procedure AddArp(Note: Integer);
    procedure RemoveArp(Note: Integer);
    procedure RebuildArp;
    function ArpNext: Integer;

    procedure RecordStep(Step: UInt32);
  public
    constructor Create;

    procedure Prepare(HostSampleRate: Double);
    procedure SetSettings(const S: TSettings);

    // the keyboard and the function buttons - queued for the CPU
    procedure NoteOn(Note: Integer);
    procedure NoteOff(Note: Integer);
    procedure KeyTranspose;   // REST while in LOAD
    procedure Legato;
    procedure AllNotesOff;

    // The EXT CLK input, fed from the host: where it is on the timeline (in quarter notes)
    // at the start of the next render, its tempo, and whether the transport is running.
    // Available = False when there is no host timeline at all (the standalone app); the
    // CLOCK switch's HOST position then falls back to the modulator.
    procedure SetHostClock(Available, Playing: Boolean; Ppq, Bpm: Double);

    procedure SetPitchBend(V: Single);   // the lever, side to side
    procedure SetModLever(V: Single);    // the lever, pushed

    function SeqLength: Integer;
    function SeqPosition: Integer;
    function SeqLegatoArmed: Boolean;
    function KeyTransposeArmed: Boolean;
    function KeyShift: Integer;
    function SeqStep(I: Integer): UInt32;
    procedure LoadSequence(const Data: array of UInt32; Count: Integer);

    // Dest points at NumSamples Singles.
    procedure Render(Dest: PSingle; NumSamples: Integer);

    function CurrentKey: Integer;
    function GateIsOn: Boolean;
    function Oversampling: Integer;
  end;

implementation

const
  MiddleC: Single = 261.6255653;
  PanelScale: Single = 0.1;

  // An audio-taper ("A") pot used as a variable resistor: 10% of its resistance at half
  // travel, the rest packed into the top half.
  TaperK: Single = 4.4;   // exp(k/2) - 1 = 10% of exp(k) - 1

  // The engine's other float constants, by where they are used.
  ResonanceScale: Single = 4.4;
  NoiseScale: Single = 0.7;
  VolumeScale: Single = 1.4;
  AttackShortest: Single = 0.0015;
  DecayShortest: Single = 0.002;
  LfoSlowest: Single = 0.1;
  PortaShortestTau: Single = 0.0005;
  SliderTau: Single = 0.004;
  GateTau: Single = 0.0005;
  SagTau: Single = 0.04;
  VolumeTau: Single = 0.01;
  MaxFcRatio: Single = 0.35;
  CpuShortest: Single = 0.0015;
  CpuSpread: Single = 0.002;
  DriftShortest: Single = 0.3;
  DriftSpread: Single = 0.9;
  DriftDepth: Single = 0.0012;
  JitterDepth: Single = 0.004;
  EdgeLoad: Single = 0.01;
  RippleDepth: Single = 0.05;
  RailToPitch: Single = 0.0015;
  RailToCutoff: Single = 0.03;
  MaxDt: Single = 0.45;
  ThermalNoise: Single = 1.0e-5;
  DefaultMixCoef: Single = 0.9995;
  DefaultDcCoef: Single = 0.999;
  DefaultVolumeCoef: Single = 0.01;

  StepsPerBeat: array[0..5] of Double = (1, 2, 3, 4, 6, 8);

function Panel(V: Single): Single; inline;   // 0..10 -> 0..1
begin
  Result := Clamp(V * PanelScale, 0, 1);
end;

function AudioTaper(X: Single): Single;
begin
  Result := (ExpF(TaperK * X) - 1) / (ExpF(TaperK) - 1);
end;

// An RC time set by an audio-taper pot in series with a fixed resistor: the fixed part
// sets the shortest time, pot plus fixed the longest.
function TaperedTime(X, Shortest, Longest: Single): Single;
begin
  Result := Shortest + (Longest - Shortest) * AudioTaper(X);
end;

function MinI(A, B: Integer): Integer; inline;
begin
  if A < B then Result := A else Result := B;
end;

function MaxI(A, B: Integer): Integer; inline;
begin
  if A > B then Result := A else Result := B;
end;

{ TEngine }

constructor TEngine.Create;
begin
  inherited Create;
  // Fields start at zero; these are the C++ member initialisers that are not.
  FSettings := TSettings.Defaults;
  FMode := emKeyboard;
  FHostRate := 44100;
  FRateInt := 176400;
  FFactor := 4;

  FVco.Reset;
  FVcf.Reset;
  FEnv.Init;
  FLfo.Init;
  FDecimator.Init;
  FRng.Init;

  FLastBpm := 120;
  FSyncQuarters := 1;
  FKey := 60;
  FArpIdx := -1;
  FArpDir := 1;
  FPosition := -1;
  FPortaCoef := 1;
  FSmoothCoef := 1;
  FGateCoef := 1;
  FRange := RangeFeet8;
  FMaxFc := 20000;
  FMixCoef := DefaultMixCoef;
  FDcCoef := DefaultDcCoef;
  FVolumeCoef := DefaultVolumeCoef;
end;

procedure TEngine.Prepare(HostSampleRate: Double);
var
  D: Double;
begin
  FHostRate := HostSampleRate;
  if FHostRate <= 50000 then
    FFactor := 4
  else if FHostRate <= 100000 then
    FFactor := 2
  else
    FFactor := 1;
  FRateInt := FHostRate * FFactor;

  FDecimator.Prepare(FFactor, FHostRate);
  FEnv.SetSampleRate(FRateInt);
  FLfo.SetSampleRate(FRateInt);

  FVco.Reset;
  FVcf.Reset;
  FEnv.Reset;
  FLfo.Reset;

  FSmoothCoef := OnePoleCoef(SliderTau, FRateInt);   // a slider cannot move faster than a hand
  FGateCoef := OnePoleCoef(GateTau, FRateInt);       // the VCA's control input, in GATE mode
  FDriftCoef := OnePoleCoef(1.5, FRateInt);
  FJitterCoef := OnePoleCoef(1 / (2 * PiF * 25), FRateInt);
  FSagCoef := OnePoleCoef(SagTau, FRateInt);         // the load's own recovery
  FRegulatorCoef := OnePoleCoef(0.25, FRateInt);     // the regulator catching up
  FVolumeCoef := OnePoleCoef(VolumeTau, FHostRate);

  // full-wave rectified 50 Hz mains, what is left of it after the regulators
  FRippleInc := 100 / FRateInt;

  // the mixer's coupling capacitor into the filter, and the output's (in double, as the
  // C++ has it)
  D := FRateInt;
  D := 2.0 * Pi64 * 5.0 / D;
  FMixCoef := D;
  FMixCoef := 1 - FMixCoef;
  D := FHostRate;
  D := 2.0 * Pi64 * 8.0 / D;
  FDcCoef := D;
  FDcCoef := 1 - FDcCoef;

  FMaxFc := MaxFcRatio * FRateInt;
  if FMaxFc > 40000 then
    FMaxFc := 40000;

  FMixX1 := 0;
  FMixY1 := 0;
  FDcX1 := 0;
  FDcY1 := 0;
  FGateLevel := 0;
  FSag := 0;
  FRegulated := 0;
  FJitter := 0;
  FGate := False;
  FNumHeld := 0;
  FArpCount := 0;
  FQueued := 0;
  FCpuCountdown := 0;
  FClockWasHigh := False;
  FSeqRunning := False;
  FPosition := -1;
  FPrimed := False;

  UpdateTargets;
end;

//------------------------------------------------------------------------------ modes

function TEngine.ModeFor(const S: TSettings): TEngineMode;
begin
  // The CPU checks LOAD, then PLAY, then ARPEGGIO (flow chart, steps 9-11). In LOAD the
  // keyboard plays straight, so what goes in can be heard going in.
  if S.SeqMode = SeqLoad then
    Result := emKeyboard
  else if S.SeqMode = SeqPlay then
    Result := emSequence
  else if S.ArpMode <> ArpOff then
    Result := emArpeggio
  else
    Result := emKeyboard;
end;

procedure TEngine.SetSettings(const S: TSettings);
var
  WasHold, EnteringLoad: Boolean;
  Next: TEngineMode;
begin
  WasHold := FSettings.ArpHold;
  EnteringLoad := (S.SeqMode = SeqLoad) and (FSettings.SeqMode <> SeqLoad);
  Next := ModeFor(S);

  FSettings := S;

  // Pressing LOAD starts a new sequence from the first step.
  if EnteringLoad then
  begin
    FLength := 0;
    FLegatoArmed := False;
  end;

  if Next <> FMode then
    EnterMode(Next)
  else if WasHold and not S.ArpHold and (FNumHeld = 0) then
  begin
    // Releasing HOLD lets go of anything no longer under a finger.
    if FMode = emArpeggio then
    begin
      FArpCount := 0;
      GateOff;
    end;
    if FMode = emSequence then
    begin
      FSeqRunning := False;
      FPosition := -1;
      GateOff;
    end;
  end;

  UpdateTargets;
end;

procedure TEngine.EnterMode(M: TEngineMode);
begin
  FMode := M;
  FArpCount := 0;
  FSeqRunning := False;
  FPosition := -1;

  case M of
    emKeyboard:
      // whatever is still held plays, as if just pressed
      if FNumHeld > 0 then
        PlayKey(FHeld[FNumHeld - 1], False, True)
      else
        GateOff;

    emArpeggio:
      begin
        RebuildArp;
        if FArpCount > 0 then
        begin
          FArpIdx := -1;
          FArpDir := 1;
          ClockReset;
        end
        else
          GateOff;
      end;

    emSequence:
      begin
        GateOff;
        if (FNumHeld > 0) and (FLength > 0) then
        begin
          FSeqTranspose := FHeld[FNumHeld - 1] - 60;
          FSeqRunning := True;
          FSeqResting := False;
        end;
      end;
  end;
end;

procedure TEngine.UpdateTargets;
var
  Vm, Md, V, Tau: Single;
begin
  // VCF: 10 Hz to 20 kHz across the slider (spec)
  FTgt.CutoffLog := Log2F(10) + Panel(FSettings.Cutoff) * Log2F(2000);
  FTgt.K := ResonanceScale * Panel(FSettings.Res);   // self-oscillation from about 9
  FTgt.EnvOct := 10 * Panel(FSettings.VcfEnv);
  FTgt.VcfModOct := 3 * Panel(FSettings.VcfMod);
  FTgt.Kybd := Panel(FSettings.VcfKybd);             // spec: 0 - 100%

  // VCO and mixer
  FTgt.Pw := Panel(FSettings.Pw);
  FTgt.Pulse := Panel(FSettings.Pulse);
  FTgt.Saw := Panel(FSettings.Saw);
  FTgt.Sub := Panel(FSettings.Sub);
  FTgt.Noise := Panel(FSettings.Noise) * NoiseScale;

  // modulation depths - squared, as a linear pot into a depth that is only useful at the
  // bottom of its range wants spreading out there
  Vm := Panel(FSettings.VcoMod);
  Md := Panel(FSettings.ModDepth);
  FTgt.VcoModOct := Vm * Vm;                          // up to an octave either side
  FTgt.ModDepthOct := Md * Md * 0.5;
  FTgt.BendOct := Panel(FSettings.BendVco);           // up to an octave
  FTgt.BendVcfOct := 4 * Panel(FSettings.BendVcf);

  V := Panel(FSettings.Volume);
  FTgt.Volume := VolumeScale * V * V;

  // Spec: attack 1.5 ms - 4 s, decay and release 2 ms - 10 s. The time sliders are taken
  // to be the 1M audio-taper parts in the parts list, as variable resistors - so most of
  // the range is in the top half of the travel, as on the hardware.
  FEnv.SetTimes(TaperedTime(Panel(FSettings.Attack), AttackShortest, 4),
                TaperedTime(Panel(FSettings.Decay), DecayShortest, 10),
                Panel(FSettings.Sustain),
                TaperedTime(Panel(FSettings.Release), DecayShortest, 10));

  // spec: 0.1 - 30 Hz; or synced, a note length
  FLfoInc := ExpLaw(Panel(FSettings.LfoRate), LfoSlowest, 30) / FRateInt;
  FSyncQuarters := SyncDivisions[SyncDivisionIndex(FSettings.LfoRate)].Quarters;

  // Spec: 0 - 5 s, on a 2M audio-taper pot (the bender board's PORTAMENTO TIME). The RC
  // takes about three time constants to arrive.
  Tau := TaperedTime(Panel(FSettings.PortaTime), 0, 5) / 3;
  if Tau < PortaShortestTau then
    FPortaCoef := 1
  else
    FPortaCoef := OnePoleCoef(Tau, FRateInt);

  FRange := FSettings.Range;
  FTransposeOct := FSettings.Transpose - TransposeMid;
  FTuneOct := FSettings.Tune / 1200;

  if not FPrimed then
  begin
    FCur := FTgt;
    FVolume := FTgt.Volume;
    FPrimed := True;
  end;
end;

//------------------------------------------------------------------------------ the CPU

procedure TEngine.Push(T: TEventType; Note: Integer);
begin
  if (Note < 0) or (Note > 127) or (FQueued >= Length(FQueue)) then
    Exit;
  FQueue[FQueued].Kind := T;
  FQueue[FQueued].Note := Note;
  Inc(FQueued);
end;

procedure TEngine.NoteOn(Note: Integer);
begin
  Push(evOn, Note);
end;

procedure TEngine.NoteOff(Note: Integer);
begin
  Push(evOff, Note);
end;

procedure TEngine.KeyTranspose;
begin
  Push(evKeyTranspose, 0);
end;

procedure TEngine.Legato;
begin
  Push(evLegato, 0);
end;

procedure TEngine.AllNotesOff;
begin
  FQueued := 0;
  FNumHeld := 0;
  FArpCount := 0;
  FSeqRunning := False;
  FPosition := -1;
  FTransposeArmed := False;
  GateOff;
end;

// One pass of the CPU's loop: keyboard and buttons (steps 5 and 8-9), then the clock
// (step 6) and what hangs off it (10-11).
procedure TEngine.CpuPass;
var
  I: Integer;
  IsHigh: Boolean;
begin
  for I := 0 to FQueued - 1 do
  begin
    case FQueue[I].Kind of
      evOn:  KeyDown(FQueue[I].Note);
      evOff: KeyUp(FQueue[I].Note);

      evKeyTranspose:
        // In LOAD, the KEY TRANSPOSE button is REST (step 9).
        if FSettings.SeqMode = SeqLoad then
        begin
          FLegatoArmed := False;
          RecordStep(StepRest);
        end
        else
          FTransposeArmed := not FTransposeArmed;

      evLegato:
        if FSettings.SeqMode = SeqLoad then
          FLegatoArmed := not FLegatoArmed;
    end;
  end;
  FQueued := 0;

  IsHigh := ClockHigh;
  if IsHigh and not FClockWasHigh then
    ClockRise
  else if not IsHigh and FClockWasHigh then
    ClockFall;
  FClockWasHigh := IsHigh;
end;

// Clock Reset (step 13): restart the modulator, and make sure this pass sees it go high.
// An external clock cannot be reset - the arpeggio waits for its next step instead.
procedure TEngine.ClockReset;
begin
  // A modulator locked to the timeline belongs to the timeline: a key cannot restart it.
  if LfoSynced then
    Exit;

  FLfo.Restart;
  if not UsingHostClock then
    FClockWasHigh := False;
end;

procedure TEngine.SetHostClock(Available, Playing: Boolean; Ppq, Bpm: Double);
begin
  FHostAvailable := Available;
  FHostPlaying := Available and Playing and (Bpm > 0);
  FHostPpq := Ppq;
  if FHostPlaying then
    FHostPpqPerTick := Bpm / 60.0 / FRateInt
  else
    FHostPpqPerTick := 0.0;

  if Available and (Bpm > 0) then
    FLastBpm := Bpm;
  if FHostPlaying then
    FLfoPpq := Ppq;
  FLfoPpqPerTick := FLastBpm / 60.0 / FRateInt;
end;

function TEngine.UsingHostClock: Boolean;
begin
  Result := (FSettings.ClockSource = ClockHost) and FHostAvailable;
end;

function TEngine.LfoSynced: Boolean;
begin
  Result := (FSettings.LfoSync = LfoSyncHost) and FHostAvailable;
end;

// The clock as the CPU's input sees it: the modulator's square, or the host's beat grid
// cut into steps - high for the first half of each, low while the transport is stopped.
function TEngine.ClockHigh: Boolean;
var
  X: Double;
begin
  if not UsingHostClock then
    Result := FLfo.ClockHigh
  else if not FHostPlaying then
    Result := False
  else
  begin
    X := FHostPpq * StepsPerBeat[MinI(MaxI(FSettings.ClockDiv, 0), 5)];
    Result := X - FloorD(X) < 0.5;
  end;
end;

procedure TEngine.KeyDown(Note: Integer);
var
  OthersHeld, Tie: Boolean;
  Step: UInt32;
begin
  // KEY TRANSPOSE then a key: that key, relative to the bottom C of the 101's keyboard
  // (middle C), becomes the shift. It is not played.
  if FTransposeArmed then
  begin
    FShift := Note - 60;
    FTransposeArmed := False;
    Exit;
  end;

  OthersHeld := FNumHeld > 0;
  RemoveHeld(Note);
  FHeld[FNumHeld] := Note;
  Inc(FNumHeld);

  case FMode of
    emArpeggio:
      begin
        // With HOLD on, a fresh chord - one played after every key was let go - replaces
        // the latched one rather than adding to it.
        if FSettings.ArpHold and not OthersHeld then
          FArpCount := 0;

        if FArpCount = 0 then
        begin
          FArpIdx := -1;
          FArpDir := 1;
        end;
        AddArp(Note);

        // the CPU resets the clock on every key in ARPEGGIO
        ClockReset;
      end;

    emSequence:
      begin
        // The key transposes the sequence, relative to middle C, and starts it - on the
        // next clock: there is no Clock Reset in PLAY.
        FSeqTranspose := Note - 60;
        if not FSeqRunning and (FLength > 0) then
        begin
          FSeqRunning := True;
          FSeqResting := False;
          FPosition := -1;
        end;
      end;

    emKeyboard:
      begin
        if FSettings.SeqMode = SeqLoad then
        begin
          // Overlapping the previous key enters a tie, the same as LEGATO does.
          Tie := FLegatoArmed or OthersHeld;
          FLegatoArmed := False;
          Step := UInt32(Note);
          if Tie then
            Step := Step or StepTie;
          RecordStep(Step);
        end;

        // ... and resets the clock on every key with the envelope on LFO trigger
        if FSettings.EnvTrig = EnvTrigLfo then
          ClockReset;

        PlayKey(Note, OthersHeld and FGate, True);
      end;
  end;
end;

procedure TEngine.KeyUp(Note: Integer);
begin
  RemoveHeld(Note);

  case FMode of
    emArpeggio:
      if not FSettings.ArpHold then
      begin
        RemoveArp(Note);
        if FArpCount = 0 then
          GateOff;
      end;

    emSequence:
      if FNumHeld > 0 then
        FSeqTranspose := FHeld[FNumHeld - 1] - 60
      else if not FSettings.ArpHold then
      begin
        FSeqRunning := False;
        FPosition := -1;
        GateOff;
      end;

    emKeyboard:
      if FNumHeld = 0 then
        GateOff
      else if Note = FKey then
        PlayKey(FHeld[FNumHeld - 1], True, False);   // back to the note still held, legato
  end;
end;

procedure TEngine.ClockRise;
var
  N, P, Note: Integer;
  Step: UInt32;
  Tied: Boolean;
begin
  // step 6(a): random data for the modulator's RANDOM waveform
  FLfo.SetRandom(FRng.Bipolar);

  if FMode = emArpeggio then
  begin
    if FArpCount > 0 then
      PlayKey(ArpNext, False, True);
    Exit;
  end;

  if (FMode <> emSequence) or not FSeqRunning then
    Exit;

  N := FLength;
  if N = 0 then
  begin
    FSeqRunning := False;
    GateOff;
    Exit;
  end;

  P := (FPosition + 1) mod N;
  FPosition := P;

  Step := FSteps[P];

  if (Step and StepRest) <> 0 then
  begin
    FSeqResting := True;
    GateOff;
    Exit;
  end;

  // A tie only means something coming from a note: after a rest it is a new note.
  Tied := ((Step and StepTie) <> 0) and not FSeqResting and FGate;
  FSeqResting := False;

  Note := MinI(127, MaxI(0, Integer(Step and StepNoteMask) + FSeqTranspose));
  PlayKey(Note, Tied, not Tied);
end;

// The gate closes for the low half of the clock - except into a tied step.
procedure TEngine.ClockFall;
var
  N: Integer;
  NextStep: UInt32;
  NextTied: Boolean;
begin
  if FMode = emArpeggio then
  begin
    GateOff;
    Exit;
  end;

  if (FMode <> emSequence) or not FSeqRunning or FSeqResting then
    Exit;

  N := FLength;
  if N = 0 then
    Exit;

  NextStep := FSteps[(FPosition + 1) mod N];
  NextTied := ((NextStep and StepTie) <> 0) and ((NextStep and StepRest) = 0);
  if not NextTied then
    GateOff;
end;

//------------------------------------------------------------------------------ keyboard

procedure TEngine.PlayKey(Note: Integer; IsLegato, Retrigger: Boolean);
var
  Trig: Boolean;
begin
  FKey := Note;
  FKeyTarget := Note - 60;
  FKeyTarget := FKeyTarget / 12;

  FGlide := (FSettings.PortaMode = PortaOn)
         or ((FSettings.PortaMode = PortaAuto) and IsLegato);

  if not FGlide then
    FKeyCv := FKeyTarget;

  // GATE mode lets a legato note through without restarting the envelope; GATE+TRIG and
  // LFO restart it on every new key.
  Trig := Retrigger and (not IsLegato or (FSettings.EnvTrig <> EnvTrigGate));
  GateOn(Trig);
end;

procedure TEngine.GateOn(Retrigger: Boolean);
begin
  if not FGate or Retrigger then
    TriggerEnvelope;
  FGate := True;
end;

procedure TEngine.GateOff;
begin
  FGate := False;
  FEnv.Release;
end;

procedure TEngine.TriggerEnvelope;
begin
  FEnv.Trigger;

  // The envelope's capacitor charging, and the VCA opening, draw a gulp of current: the
  // rail dips for a few tens of milliseconds, and pitch and cutoff dip with it.
  FSag := FSag + 1;
end;

procedure TEngine.RemoveHeld(Note: Integer);
var
  I, J: Integer;
begin
  J := 0;
  for I := 0 to FNumHeld - 1 do
    if FHeld[I] <> Note then
    begin
      FHeld[J] := FHeld[I];
      Inc(J);
    end;
  FNumHeld := J;
end;

//------------------------------------------------------------------------------ arpeggio

procedure TEngine.AddArp(Note: Integer);
var
  I, J: Integer;
begin
  I := 0;
  while (I < FArpCount) and (FArpNotes[I] < Note) do
    Inc(I);
  if (I < FArpCount) and (FArpNotes[I] = Note) then
    Exit;

  for J := FArpCount downto I + 1 do
    FArpNotes[J] := FArpNotes[J - 1];
  FArpNotes[I] := Note;
  Inc(FArpCount);
end;

procedure TEngine.RemoveArp(Note: Integer);
var
  I, J: Integer;
begin
  J := 0;
  for I := 0 to FArpCount - 1 do
    if FArpNotes[I] <> Note then
    begin
      FArpNotes[J] := FArpNotes[I];
      Inc(J);
    end;
  FArpCount := J;
end;

procedure TEngine.RebuildArp;
var
  I: Integer;
begin
  FArpCount := 0;
  for I := 0 to FNumHeld - 1 do
    AddArp(FHeld[I]);
end;

function TEngine.ArpNext: Integer;
var
  N: Integer;
begin
  N := FArpCount;

  case FSettings.ArpMode of
    ArpDown:
      begin
        if (FArpIdx <= 0) or (FArpIdx > N) then
          FArpIdx := N - 1
        else
          FArpIdx := FArpIdx - 1;
      end;

    ArpUpDown:
      if N = 1 then
        FArpIdx := 0
      else
      begin
        FArpIdx := FArpIdx + FArpDir;
        if FArpIdx >= N then
        begin
          FArpIdx := N - 2;
          FArpDir := -1;
        end;
        if FArpIdx < 0 then
        begin
          FArpIdx := 1;
          FArpDir := 1;
        end;
      end;

  else
    FArpIdx := (FArpIdx + 1) mod N;
  end;

  FArpIdx := MinI(MaxI(FArpIdx, 0), N - 1);
  Result := FArpNotes[FArpIdx];
end;

//------------------------------------------------------------------------------ sequencer

procedure TEngine.RecordStep(Step: UInt32);
var
  N: Integer;
begin
  N := FLength;
  if N >= MaxSteps then
    Exit;
  FSteps[N] := Step;
  FLength := N + 1;
end;

procedure TEngine.LoadSequence(const Data: array of UInt32; Count: Integer);
var
  I: Integer;
begin
  if Count > Length(Data) then
    Count := Length(Data);
  Count := MinI(MaxI(Count, 0), MaxSteps);
  FLength := 0;
  for I := 0 to Count - 1 do
    FSteps[I] := Data[I] and (StepNoteMask or StepRest or StepTie);
  FLength := Count;
end;

function TEngine.SeqLength: Integer;
begin
  Result := FLength;
end;

function TEngine.SeqPosition: Integer;
begin
  Result := FPosition;
end;

function TEngine.SeqLegatoArmed: Boolean;
begin
  Result := FLegatoArmed;
end;

function TEngine.KeyTransposeArmed: Boolean;
begin
  Result := FTransposeArmed;
end;

function TEngine.KeyShift: Integer;
begin
  Result := FShift;
end;

function TEngine.SeqStep(I: Integer): UInt32;
begin
  if (I >= 0) and (I < MaxSteps) then
    Result := FSteps[I]
  else
    Result := 0;
end;

//------------------------------------------------------------------------------ controllers

procedure TEngine.SetPitchBend(V: Single);
begin
  FBend := Clamp(V, -1, 1);
end;

procedure TEngine.SetModLever(V: Single);
begin
  FModLever := Clamp(V, 0, 1);
end;

function TEngine.CurrentKey: Integer;
begin
  Result := FKey;
end;

function TEngine.GateIsOn: Boolean;
begin
  Result := FGate;
end;

function TEngine.Oversampling: Integer;
begin
  Result := FFactor;
end;

//------------------------------------------------------------------------------ audio

function TEngine.Tick: Single;
var
  Lt: TLfoTick;
  Cycles: Double;
  E, Dip, Ripple, Rail, RangeV, Keyed, LfoPitch, Pitch, Dt, PwmAmount, Width: Single;
  Mixed, Coupled, FLog, Fc, G, Filtered, Amp, GateTarget, Shift: Single;
  Levels: TVcoLevels;
begin
  FHostPpq := FHostPpq + FHostPpqPerTick;

  Dec(FCpuCountdown);
  if FCpuCountdown <= 0 then
  begin
    CpuPass;
    FCpuCountdown := Trunc(FRateInt * (CpuShortest + CpuSpread * FRng.Uniform));
  end;

  // The envelope's LFO trigger is wired from the modulator through the trigger
  // generator, not through the CPU, so it is on time.
  if LfoSynced then
  begin
    FLfoPpq := FLfoPpq + FLfoPpqPerTick;
    Cycles := FLfoPpq / FSyncQuarters;
    Lt := FLfo.ProcessAt(Cycles - FloorD(Cycles), FSettings.LfoWave, FRng);
  end
  else
    Lt := FLfo.Process(FLfoInc, FSettings.LfoWave, FRng);
  if (FMode = emKeyboard) and (FSettings.EnvTrig = EnvTrigLfo) and FGate and Lt.CycleStart then
    TriggerEnvelope;

  // portamento: an RC on the keyboard CV - fast at first, slowing as it arrives
  if FGlide then
    FKeyCv := FKeyCv + (FKeyTarget - FKeyCv) * FPortaCoef
  else
    FKeyCv := FKeyTarget;

  // the sliders, smoothed
  FCur.CutoffLog := FCur.CutoffLog + (FTgt.CutoffLog - FCur.CutoffLog) * FSmoothCoef;
  FCur.K := FCur.K + (FTgt.K - FCur.K) * FSmoothCoef;
  FCur.Pw := FCur.Pw + (FTgt.Pw - FCur.Pw) * FSmoothCoef;
  FCur.Pulse := FCur.Pulse + (FTgt.Pulse - FCur.Pulse) * FSmoothCoef;
  FCur.Saw := FCur.Saw + (FTgt.Saw - FCur.Saw) * FSmoothCoef;
  FCur.Sub := FCur.Sub + (FTgt.Sub - FCur.Sub) * FSmoothCoef;
  FCur.Noise := FCur.Noise + (FTgt.Noise - FCur.Noise) * FSmoothCoef;

  E := FEnv.Process;
  if FGate then
    GateTarget := 1
  else
    GateTarget := 0;
  FGateLevel := FGateLevel + (GateTarget - FGateLevel) * FGateCoef;

  //---------------------------------------------------------------- the analog
  // Thermal drift: a couple of cents, wandering over seconds. Enough that two notes are
  // never quite the same; not enough to sound out of tune.
  Dec(FDriftCountdown);
  if FDriftCountdown <= 0 then
  begin
    FDriftCountdown := Trunc(FRateInt * (DriftShortest + DriftSpread * FRng.Uniform));
    FDriftTarget := FRng.Noise * DriftDepth;
  end;
  FDrift := FDrift + (FDriftTarget - FDrift) * FDriftCoef;

  // And faster, much smaller: the expo converter's own noise, a fraction of a cent.
  FJitter := FJitter + (FRng.Noise * JitterDepth - FJitter) * FJitterCoef;

  // The rail: sags on envelope triggers and on the oscillator's edges switching, and
  // carries a trace of mains ripple that grows as it sags. The regulator corrects a STEADY
  // load - so FRegulated, a slow copy of the sag, is taken off it: only changes in load
  // move the rail. Without that a high note, all edges, would sit permanently flat.
  FSag := FSag - FSag * FSagCoef;
  FRegulated := FRegulated + (FSag - FRegulated) * FRegulatorCoef;
  Dip := FSag - FRegulated;

  FRipplePhase := FRipplePhase + FRippleInc;
  if FRipplePhase >= 1 then
    FRipplePhase := FRipplePhase - 1;
  Ripple := SinF(2 * PiF * FRipplePhase) * (1 + Abs(Dip));
  Rail := Dip + RippleDepth * Ripple;

  //---------------------------------------------------------------- VCO
  // The RANGE data the CPU writes: 1 V at 16' to 4 V at 2', plus any KEY TRANSPOSE shift,
  // within the D/A converter's 0 - 5 V. 8' (2 V) is the reference.
  RangeV := FRange + 1;
  Shift := FShift;
  RangeV := Clamp(RangeV + Shift / 12, 0, 5);

  Keyed := FKeyCv + FTransposeOct;
  LfoPitch := Lt.Value * (FTgt.VcoModOct + FModLever * FTgt.ModDepthOct);
  Pitch := Keyed + (RangeV - 2) + FTuneOct + FBend * FTgt.BendOct + LfoPitch
         + FDrift + FJitter - RailToPitch * Rail;
  Dt := MiddleC * Exp2F(Pitch) / FRateInt;
  if Dt > MaxDt then
    Dt := MaxDt;

  PwmAmount := 1;
  if FSettings.PwmSource = PwmSourceLfo then
    PwmAmount := 0.5 * (Lt.Value + 1)
  else if FSettings.PwmSource = PwmSourceEnv then
    PwmAmount := E;

  // spec: 50% down to 0% - at the top the pulse vanishes
  Width := 0.5 * (1 - FCur.Pw * PwmAmount);

  Levels.Pulse := FCur.Pulse;
  Levels.Saw := FCur.Saw;
  Levels.Sub := FCur.Sub;
  Levels.SubType := FSettings.SubType;

  //---------------------------------------------------------------- MIXER
  Mixed := FVco.Process(Dt, Width, Levels);
  Mixed := Mixed + FCur.Noise * FRng.Noise;
  FSag := FSag + EdgeLoad * FVco.LastEdgeEnergy;

  Coupled := Mixed - FMixX1 + FMixCoef * FMixY1;
  FMixX1 := Mixed;
  FMixY1 := Coupled;

  //---------------------------------------------------------------- VCF
  FLog := FCur.CutoffLog
        + E * FTgt.EnvOct
        + Lt.Value * FTgt.VcfModOct
        + Keyed * FTgt.Kybd
        + FBend * FTgt.BendVcfOct
        - RailToCutoff * Rail;

  Fc := Clamp(Exp2F(FLog), 5, FMaxFc);
  G := TanF(PiF * Fc / FRateInt);

  // A trace of thermal noise at the input, so the filter can start to self-oscillate
  // from silence as the real one does.
  Filtered := FVcf.Process(0.5 * Coupled + ThermalNoise * FRng.Noise, G, FCur.K);

  //---------------------------------------------------------------- VCA (BA662A)
  if FSettings.VcaMode = VcaModeGate then
    Amp := FGateLevel
  else
    Amp := E;
  Result := SoftClip(Filtered * Amp);
end;

procedure TEngine.Render(Dest: PSingle; NumSamples: Integer);
var
  I, R: Integer;
  Y, Hp: Single;
begin
  for I := 0 to NumSamples - 1 do
  begin
    for R := 0 to FFactor - 1 do
      FDecimator.Push(Tick);

    Y := FDecimator.Output;

    Hp := Y - FDcX1 + FDcCoef * FDcY1;
    FDcX1 := Y;
    FDcY1 := Hp;

    FVolume := FVolume + (FTgt.Volume - FVolume) * FVolumeCoef;
    Dest^ := Hp * FVolume;
    Inc(Dest);
  end;
end;

end.
