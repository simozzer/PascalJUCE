// Mz101 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Tests/DspCheck.cpp.
//
// The engine, checked on its own: pitch, the sub dividers, filter self-oscillation and
// tracking, the envelope letting go, the arpeggiator's order, and that no setting of any
// control makes it blow up. Links no JUCE.
//
//     DspCheck                 run the checks
//
// (The C++ version's --wav demo renders are not ported.)
program DspCheck;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}
{$APPTYPE CONSOLE}

uses
  Windows, SysUtils, Math,
  Sh101Dsp, Sh101Settings, Sh101Sync, Sh101Engine;

type
  TSamples = array of Single;

const
  Rate = 48000.0;
  Rare: Single = 0.15;
  Seventy: Single = 0.7;

var
  Failures: Integer = 0;

procedure Check(Ok: Boolean; const What, Detail: string);
const
  Verdict: array[Boolean] of string = ('FAIL', 'ok  ');
begin
  Writeln(Format('  %s  %-44s %s', [Verdict[Ok], What, Detail]));
  if not Ok then
    Inc(Failures);
end;

function Clock: Double;
var
  C, F: Int64;
begin
  QueryPerformanceCounter(C);
  QueryPerformanceFrequency(F);
  Result := C / F;
end;

function Render(E: TEngine; Seconds: Double): TSamples;
begin
  Result := nil;
  SetLength(Result, Trunc(Seconds * Rate));
  if Length(Result) > 0 then
    E.Render(@Result[0], Length(Result));
end;

function Slice(const V: TSamples; FromSec, ToSec: Double): TSamples;
var
  A, B: Integer;
begin
  A := Trunc(FromSec * Rate);
  B := Trunc(ToSec * Rate);
  Result := Copy(V, A, B - A);
end;

// Frequency from rising zero crossings, interpolated, over the second half of the buffer.
function Frequency(const V: TSamples): Double;
var
  First, Last, T, A, B: Double;
  Count, I: Integer;
begin
  First := -1;
  Last := -1;
  Count := 0;
  for I := Length(V) div 2 + 1 to High(V) do
    if (V[I - 1] < 0) and (V[I] >= 0) then
    begin
      A := V[I - 1];
      B := V[I];
      T := (I - 1) + A / (A - B);
      if First < 0 then
        First := T
      else
        Inc(Count);
      Last := T;
    end;
  if Count > 0 then
    Result := Count * Rate / (Last - First)
  else
    Result := 0;
end;

function Peak(const V: TSamples; From: Integer = 0): Double;
var
  I: Integer;
begin
  Result := 0;
  for I := From to High(V) do
    Result := Max(Result, Abs(V[I]));
end;

function Rms(const V: TSamples; From: Integer = 0): Double;
var
  I: Integer;
  S, X: Double;
begin
  S := 0;
  for I := From to High(V) do
  begin
    X := V[I];
    S := S + X * X;
  end;
  Result := Sqrt(S / Max(1, Length(V) - From));
end;

// An open, plain patch: one source, filter wide open, no envelope on the filter, held.
function Plain: TSettings;
begin
  Result := TSettings.Defaults;
  Result.Saw := 10; Result.Pulse := 0; Result.Sub := 0; Result.Noise := 0;
  Result.Cutoff := 10; Result.Res := 0; Result.VcfEnv := 0; Result.VcfKybd := 0;
  Result.Attack := 0; Result.Decay := 0; Result.Sustain := 10; Result.Release := 0;
end;

function NewEngine(const S: TSettings; ARate: Double = Rate): TEngine;
begin
  Result := TEngine.Create;
  Result.Prepare(ARate);
  Result.SetSettings(S);
end;

function PitchOf(const S: TSettings; Note: Integer): Double;
var
  E: TEngine;
begin
  E := NewEngine(S);
  try
    E.NoteOn(Note);
    Result := Frequency(Render(E, 1.0));
  finally
    E.Free;
  end;
end;

procedure PitchCase(const What: string; Expect: Double; Note: Integer; const S: TSettings);
var
  F, Cents: Double;
  Sign: string;
begin
  F := PitchOf(S, Note);
  Cents := 1200.0 * Log2(F / Expect);
  // FPC's Format has no '+' flag
  if Cents >= 0 then Sign := '+' else Sign := '';
  Check(Abs(Cents) < 6.0, What, Format('%.2f Hz (%s%.1f cents)', [F, Sign, Cents]));
end;

procedure PitchChecks;
var
  S: TSettings;
begin
  Writeln;
  Writeln('the VCO');

  PitchCase('saw, A4 at 8''', 440.0, 69, Plain);
  S := Plain; S.Range := RangeFeet16;
  PitchCase('saw, A4 at 16''', 220.0, 69, S);
  S := Plain; S.Range := RangeFeet4;
  PitchCase('saw, A4 at 4''', 880.0, 69, S);
  S := Plain; S.Range := RangeFeet2;
  PitchCase('saw, A4 at 2''', 1760.0, 69, S);
  S := Plain; S.Saw := 0; S.Pulse := 10;
  PitchCase('pulse 50%, A4', 440.0, 69, S);
  S := Plain; S.Saw := 0; S.Pulse := 10; S.Pw := 9;
  PitchCase('pulse 5% (PW 9), A4', 440.0, 69, S);
  S := Plain; S.Saw := 0; S.Sub := 10;
  PitchCase('sub -1 oct square, A4', 220.0, 69, S);
  S := Plain; S.Saw := 0; S.Sub := 10; S.SubType := SubTypeOctDown2;
  PitchCase('sub -2 oct square, A4', 110.0, 69, S);
  S := Plain; S.Saw := 0; S.Sub := 10; S.SubType := SubTypePulse2;
  PitchCase('sub -2 oct pulse, A4', 110.0, 69, S);
  S := Plain; S.Transpose := TransposeHigh;
  PitchCase('transpose high, A4', 880.0, 69, S);
  S := Plain; S.Tune := 50;
  PitchCase('tune +50 cents, A4', 440.0 * Power(2.0, 50.0 / 1200.0), 69, S);
  S := Plain; S.Range := RangeFeet4;
  PitchCase('saw, C8 at 4'' (8.4 kHz)', 4186.0 * 2, 108, S);
end;

procedure Osc(Note: Integer; out F, Level: Double);
var
  S: TSettings;
  E: TEngine;
  V: TSamples;
begin
  // Self-oscillation, from nothing but the filter's own noise, tracking the keyboard.
  S := Plain;
  S.Saw := 0; S.Res := 10; S.Cutoff := 5; S.VcfKybd := 10;
  S.VcaMode := VcaModeGate;
  E := NewEngine(S);
  try
    E.NoteOn(Note);
    V := Render(E, 1.5);
    F := Frequency(V);
    Level := Rms(V, Length(V) div 2);
  finally
    E.Free;
  end;
end;

function FilterLevel(Cutoff: Single): Double;
var
  S: TSettings;
  E: TEngine;
  V: TSamples;
begin
  S := Plain;
  S.Cutoff := Cutoff;
  E := NewEngine(S);
  try
    E.NoteOn(57);
    V := Render(E, 0.5);
    Result := Rms(V, Length(V) div 2);
  finally
    E.Free;
  end;
end;

function Bass(Res: Single): Double;
var
  S: TSettings;
  E: TEngine;
  V: TSamples;
begin
  S := Plain;
  S.Saw := 0; S.Sub := 10; S.SubType := SubTypeOctDown2;
  S.Cutoff := 6; S.Res := Res;
  E := NewEngine(S);
  try
    E.NoteOn(36);
    V := Render(E, 1.0);
    Result := Rms(V, Length(V) div 2);
  finally
    E.Free;
  end;
end;

procedure FilterChecks;
var
  F1, L1, F2, L2, Open, Shut, Dry, Wet, LossDb: Double;
begin
  Writeln;
  Writeln('the VCF');

  Osc(48, F1, L1);
  Osc(60, F2, L2);

  Check((L1 > 0.02) and (L2 > 0.02), 'self-oscillates at full resonance', Format('rms %.3f, %.3f', [L1, L2]));
  Check((F1 > 0) and (Abs(F2 / F1 - 2.0) < 0.1), 'KYBD 10 tracks an octave as an octave',
    Format('%.1f Hz -> %.1f Hz', [F1, F2]));

  // Closing the filter takes the level down.
  Open := FilterLevel(10);
  Shut := FilterLevel(1);
  Check(Shut < Open * 0.1, 'closing the filter takes the saw away', Format('rms %.3f open, %.4f at 1', [Open, Shut]));

  // Resonance thins the bottom: a low sub well under the cutoff loses level as resonance
  // goes up - less than a plain four-pole would, because of the phase splitter's forward
  // half, but it does lose it.
  Dry := Bass(0);
  Wet := Bass(8);
  LossDb := 20 * Log10(Wet / Dry);
  Check((LossDb < -1.5) and (LossDb > -10.0), 'resonance thins the bass', Format('%.1f dB at RES 8', [LossDb]));
end;

procedure EnvelopeChecks;
var
  S, D: TSettings;
  E: TEngine;
  Tail, Rise, V: TSamples;
  At1, At4, P: Double;
begin
  Writeln;
  Writeln('the envelope and VCA');

  S := Plain;
  E := NewEngine(S);
  try
    E.NoteOn(57);
    Render(E, 0.3);
    E.NoteOff(57);
    Tail := Render(E, 0.1);
    Check(Peak(Tail, Trunc(0.05 * Rate)) < 1.0e-3, 'release at 0 lets go within 50 ms',
      Format('peak after 50 ms %.2e', [Peak(Tail, Trunc(0.05 * Rate))]));

    // attack at 10 is four seconds to the top: one second in, still well short
    S.Attack := 10;
    E.Prepare(Rate);
    E.SetSettings(S);
    E.NoteOn(57);
    Rise := Render(E, 4.5);
    At1 := Rms(Slice(Rise, 0.9, 1.0));
    At4 := Rms(Slice(Rise, 4.3, 4.4));
    Check((At1 < At4 * 0.5) and (At4 > 0.05), 'attack at 10 takes seconds',
      Format('rms %.3f at 1 s, %.3f at 4.3 s', [At1, At4]));

    // the default patch should sit at a sensible level
    D := TSettings.Defaults;
    E.Prepare(Rate);
    E.SetSettings(D);
    E.NoteOn(48);
    V := Render(E, 1.0);
    P := Peak(V);
    Check((P > 0.1) and (P < 1.0), 'default patch peaks below full scale',
      Format('peak %.2f (%.1f dBFS)', [P, 20 * Log10(P)]));
  finally
    E.Free;
  end;
end;

function ArpRun(Mode: Integer): string;
var
  S: TSettings;
  E: TEngine;
  Buf: array[0..15] of Single;
  I: Integer;
  WasGate: Boolean;
begin
  S := Plain;
  S.ArpMode := Mode;
  S.LfoRate := 8;
  E := NewEngine(S);
  try
    E.NoteOn(60); E.NoteOn(67); E.NoteOn(64);
    Result := '';
    WasGate := False;
    for I := 0 to Trunc(Rate * 1.2) div 16 - 1 do
    begin
      E.Render(@Buf[0], 16);
      if E.GateIsOn and not WasGate then
        if Length(Result) < 40 then
          Result := Result + IntToStr(E.CurrentKey) + ' ';
      WasGate := E.GateIsOn;
    end;
  finally
    E.Free;
  end;
end;

function StartsWith(const S, Prefix: string): Boolean;
begin
  Result := Copy(S, 1, Length(Prefix)) = Prefix;
end;

procedure ArpChecks;
var
  Up, Ud, Down: string;
begin
  Writeln;
  Writeln('the arpeggiator');

  Up := ArpRun(ArpUp);
  Ud := ArpRun(ArpUpDown);
  Down := ArpRun(ArpDown);
  Check(StartsWith(Up, '60 64 67 60 64 67'), 'UP', Up);
  Check(StartsWith(Ud, '60 64 67 64 60 64 67'), 'UP & DOWN', Ud);
  Check(StartsWith(Down, '67 64 60 67 64 60'), 'DOWN', Down);
end;

var
  SeqEngine: TEngine;
  SeqBuf: array[0..63] of Single;

procedure SeqWait;   // ~10 ms: past a CPU pass
var
  K: Integer;
begin
  for K := 0 to 7 do
    SeqEngine.Render(@SeqBuf[0], 64);
end;

procedure SeqPress(N: Integer);
begin
  SeqEngine.NoteOn(N);
  SeqWait;
  SeqEngine.NoteOff(N);
  SeqWait;
end;

procedure SequencerChecks;
var
  S: TSettings;
  Loaded, Played: string;
  I, P, LastPos, Triggers: Integer;
  St: UInt32;
  WasGate: Boolean;
  Buf: array[0..15] of Single;
begin
  Writeln;
  Writeln('the sequencer');

  S := Plain;
  S.LfoRate := 8;
  S.SeqMode := SeqLoad;

  SeqEngine := NewEngine(S);
  try
    // C, rest, E, then G tied from E (LEGATO), then C held while D is pressed (overlap ties)
    SeqPress(60);
    SeqEngine.KeyTranspose;   // REST, in LOAD
    SeqPress(64);
    SeqEngine.Legato;
    SeqPress(67);
    SeqEngine.NoteOn(60); SeqWait; SeqEngine.NoteOn(62); SeqWait;
    SeqEngine.NoteOff(60); SeqEngine.NoteOff(62); SeqWait;

    Loaded := '';
    for I := 0 to SeqEngine.SeqLength - 1 do
    begin
      St := SeqEngine.SeqStep(I);
      if (St and StepRest) <> 0 then
        Loaded := Loaded + 'rest'
      else
        Loaded := Loaded + IntToStr(St and StepNoteMask);
      if (St and StepTie) <> 0 then
        Loaded := Loaded + '~';
      Loaded := Loaded + ' ';
    end;
    Check(Loaded = '60 rest 64 67~ 60 62~ ', 'LOAD records notes, rests and ties', Loaded);

    // Play it, transposed up a fourth by holding F.
    S.SeqMode := SeqPlay;
    SeqEngine.SetSettings(S);
    SeqEngine.NoteOn(65);

    Played := '';
    LastPos := -2;
    Triggers := 0;
    WasGate := False;
    I := 0;
    while (I < Trunc(Rate * 1.0) div 16) and (LastPos < 5) do
    begin
      SeqEngine.Render(@Buf[0], 16);
      P := SeqEngine.SeqPosition;
      if P <> LastPos then
      begin
        LastPos := P;
        if P >= 0 then
          if SeqEngine.GateIsOn then
            Played := Played + IntToStr(SeqEngine.CurrentKey) + ' '
          else
            Played := Played + 'rest ';
      end;
      if SeqEngine.GateIsOn and not WasGate then
        Inc(Triggers);
      WasGate := SeqEngine.GateIsOn;
      Inc(I);
    end;
    Check(Played = '65 rest 69 72 65 67 ', 'PLAY transposes by the key held', Played);
    Check(Triggers = 3, 'ties hold the gate open into the next note',
      Format('%d gate openings for 5 notes, 2 tied', [Triggers]));

    SeqEngine.NoteOff(65);
    SeqWait;
    Check(not SeqEngine.GateIsOn, 'letting go stops it (HOLD off)', '');
  finally
    SeqEngine.Free;
  end;
end;

function PulseLevel(Pw: Single): Double;
var
  S: TSettings;
  E: TEngine;
  V: TSamples;
begin
  S := Plain;
  S.Saw := 0; S.Pulse := 10; S.Pw := Pw;
  E := NewEngine(S);
  try
    E.NoteOn(57);
    V := Render(E, 0.5);
    Result := Rms(V, Length(V) div 2);
  finally
    E.Free;
  end;
end;

// What the service manual adds: PW reaching 0%, the CPU's loop, and KEY TRANSPOSE.
procedure ServiceManualChecks;
var
  Half, None, F, Expect, Ms, Lo, Hi: Double;
  E: TEngine;
  SilentKey: Boolean;
  One: Single;
  Trial, N, K: Integer;
begin
  Writeln;
  Writeln('from the service manual');

  Half := PulseLevel(0);
  None := PulseLevel(10);
  Check(None < Half * 0.02, 'PW 10 is 0%: the pulse vanishes', Format('rms %.3f at 50%%, %.4f at 0%%', [Half, None]));

  // KEY TRANSPOSE, then G: up a fifth from middle C, and G itself is not played
  E := NewEngine(Plain);
  try
    E.KeyTranspose;
    E.NoteOn(67);
    Render(E, 0.01);
    SilentKey := not E.GateIsOn;
    E.NoteOff(67);
    E.NoteOn(69);
    F := Frequency(Render(E, 1.0));
    Expect := 440.0 * Power(2.0, 7.0 / 12.0);
    Check(SilentKey and (Abs(1200.0 * Log2(F / Expect)) < 6.0), 'KEY TRANSPOSE + G shifts A4 up a fifth',
      Format('%.2f Hz, expected %.2f', [F, Expect]));
  finally
    E.Free;
  end;

  // The CPU's loop: a key reaches the gate 0 - 3.5 ms late, and not always equally late.
  E := NewEngine(Plain);
  try
    Lo := 1e9;
    Hi := 0;
    for Trial := 0 to 39 do
    begin
      E.NoteOn(60);
      N := 0;
      while not E.GateIsOn and (N < 1000) do
      begin
        E.Render(@One, 1);
        Inc(N);
      end;
      Ms := 1000.0 * N / Rate;
      Lo := Min(Lo, Ms);
      Hi := Max(Hi, Ms);
      E.NoteOff(60);
      for K := 0 to 399 do
        E.Render(@One, 1);
    end;
    Check((Hi <= 3.6) and (Hi - Lo > 0.5), 'keys land within one CPU pass, unevenly', Format('%.2f - %.2f ms', [Lo, Hi]));
  finally
    E.Free;
  end;
end;

// Counts arpeggio steps over Seconds, the host feeding its position every 512 samples
// the way a DAW does.
function HostSteps(Available, Playing: Boolean; Bpm: Double; Division: Integer; Seconds: Double;
  FirstMs: PDouble = nil; LfoRate: Single = 2): Integer;
const
  Block = 512;
var
  S: TSettings;
  E: TEngine;
  Buf: array[0..Block - 1] of Single;
  B, I, N: Integer;
  Was: Boolean;
  Ppq: Double;
begin
  S := Plain;
  S.ArpMode := ArpUp;
  S.LfoRate := LfoRate;          // slow by default, so it cannot be what is clocking
  S.ClockSource := ClockHost;
  S.ClockDiv := Division;

  E := NewEngine(S);
  try
    E.NoteOn(60); E.NoteOn(64);
    Result := 0;
    N := 0;
    Was := False;
    Ppq := 0;
    for B := 0 to Trunc(Seconds * Rate) div Block - 1 do
    begin
      E.SetHostClock(Available, Playing, Ppq, Bpm);
      I := 0;
      while I < Block do
      begin
        E.Render(@Buf[0], 16);
        Inc(N, 16);
        if E.GateIsOn and not Was then
        begin
          if (Result = 0) and (FirstMs <> nil) then
            FirstMs^ := 1000.0 * N / Rate;
          Inc(Result);
        end;
        Was := E.GateIsOn;
        Inc(I, 16);
      end;
      if Playing then
        Ppq := Ppq + Bpm / 60.0 * Block / Rate;
    end;
  finally
    E.Free;
  end;
end;

// SYNC on HOST, CLOCK on INT: the modulator itself is on the grid, and the arpeggio
// steps on the modulator - so it lands on the grid too. RATE picks 1/16 here.
function SyncedSteps(Playing: Boolean; Seconds: Double; FirstMs: PDouble): Integer;
const
  Block = 512;
var
  S: TSettings;
  E: TEngine;
  Buf: array[0..Block - 1] of Single;
  B, I, N: Integer;
  Was: Boolean;
  Ppq: Double;
  Sixteenth: Single;
begin
  S := Plain;
  S.ArpMode := ArpUp;
  S.ClockSource := ClockInternal;
  S.LfoSync := LfoSyncHost;
  Sixteenth := 13;
  S.LfoRate := 10 * Sixteenth / (NumSyncDivisions - 1);   // "1/16"

  E := NewEngine(S);
  try
    Result := 0;
    N := 0;
    Was := False;
    Ppq := 0;
    for B := 0 to Trunc(Seconds * Rate) div Block - 1 do
    begin
      E.SetHostClock(True, Playing, Ppq, 120);
      if B = 3 then
      begin
        E.NoteOn(60);   // ~32 ms in: mid-step
        E.NoteOn(64);
      end;
      I := 0;
      while I < Block do
      begin
        E.Render(@Buf[0], 16);
        Inc(N, 16);
        if E.GateIsOn and not Was then
        begin
          if (Result = 0) and (FirstMs <> nil) then
            FirstMs^ := 1000.0 * N / Rate;
          Inc(Result);
        end;
        Was := E.GateIsOn;
        Inc(I, 16);
      end;
      if Playing then
        Ppq := Ppq + 120.0 / 60.0 * Block / Rate;
    end;
  finally
    E.Free;
  end;
end;

// CLOCK on HOST: steps follow the host's tempo and transport, not the modulator.
procedure HostClockChecks;
var
  First, SyncedFirst, LfoHz: Double;
  Sixteenths, Triplets, Stopped, LockedSteps, Freewheel, Standalone: Integer;
begin
  Writeln;
  Writeln('the host clock');

  First := 0;
  Sixteenths := HostSteps(True, True, 120, ClockDivSixteenth, 2.0, @First);
  Check((Sixteenths >= 15) and (Sixteenths <= 16), '120 BPM in 16ths: 8 steps a second', Format('%d steps in 2 s', [Sixteenths]));
  Check(First < 4.0, 'the first step lands on the downbeat', Format('%.2f ms after the transport starts', [First]));

  Triplets := HostSteps(True, True, 90, ClockDivEighthT, 2.0);
  Check((Triplets >= 8) and (Triplets <= 9), '90 BPM in 1/8 triplets: 4.5 steps a second', Format('%d steps in 2 s', [Triplets]));

  Stopped := HostSteps(True, False, 120, ClockDivSixteenth, 1.0);
  Check(Stopped = 0, 'transport stopped: no steps', Format('%d steps', [Stopped]));

  SyncedFirst := 0;
  LockedSteps := SyncedSteps(True, 2.0, @SyncedFirst);
  Check((SyncDivisions[13].Quarters = 0.25) and (LockedSteps >= 14) and (LockedSteps <= 16),
    'SYNC HOST at 1/16, 120 BPM: 8 cycles a second', Format('%d steps in 2 s', [LockedSteps]));
  Check(Abs(SyncedFirst - 125.0) < 4.0, 'a key mid-step waits for the grid',
    Format('key at 32 ms, first step at %.2f ms (grid: 125)', [SyncedFirst]));

  Freewheel := SyncedSteps(False, 2.0, nil);
  Check((Freewheel >= 15) and (Freewheel <= 17), 'transport stopped: it keeps going at the last tempo',
    Format('%d steps in 2 s', [Freewheel]));

  // no host timeline at all (the standalone app): the modulator clocks it after all
  Standalone := HostSteps(False, False, 120, ClockDivSixteenth, 2.0, nil, 8.0);
  LfoHz := 0.1 * Power(300.0, 0.8);
  Check(Abs(Standalone - 2.0 * LfoHz) <= 1.5, 'no host: falls back to the modulator',
    Format('%d steps, LFO %.2f Hz', [Standalone, LfoHz]));
end;

var
  FuzzRng: TRandom;

function Pick: Single;
begin
  if FuzzRng.Uniform < Rare then
  begin
    if FuzzRng.Uniform < 0.5 then
      Result := 0
    else
      Result := 10;
  end
  else
    Result := FuzzRng.Uniform * 10;
end;

function PickInt(Count: Integer): Integer;
begin
  Result := Trunc(FuzzRng.Uniform * Count);
end;

procedure Fuzz;
var
  S: TSettings;
  E: TEngine;
  V: array[0..4095] of Single;
  Run, K, I, Note: Integer;
  Worst: Double;
  Finite: Boolean;
begin
  Writeln;
  Writeln('every control, anywhere');

  FuzzRng.Init(1234);
  Worst := 0;
  Finite := True;

  for Run := 0 to 149 do
  begin
    S := TSettings.Defaults;
    S.LfoRate := Pick; S.LfoWave := PickInt(4);
    S.VcoMod := Pick; S.Range := PickInt(4); S.Pw := Pick; S.PwmSource := PickInt(3);
    S.Pulse := Pick; S.Saw := Pick; S.Sub := Pick; S.SubType := PickInt(3); S.Noise := Pick;
    S.Cutoff := Pick; S.Res := Pick; S.VcfEnv := Pick; S.VcfMod := Pick; S.VcfKybd := Pick;
    S.VcaMode := PickInt(2);
    S.Attack := Pick; S.Decay := Pick; S.Sustain := Pick; S.Release := Pick; S.EnvTrig := PickInt(3);
    S.PortaMode := PickInt(3); S.PortaTime := Pick;
    S.BendVco := Pick; S.BendVcf := Pick; S.ModDepth := Pick;
    S.ArpMode := PickInt(4); S.ArpHold := FuzzRng.Uniform < 0.5;
    if FuzzRng.Uniform < Seventy then
      S.SeqMode := SeqOff
    else if FuzzRng.Uniform < 0.5 then
      S.SeqMode := SeqPlay
    else
      S.SeqMode := SeqLoad;
    S.Transpose := PickInt(3); S.Volume := 10;

    E := TEngine.Create;
    try
      if FuzzRng.Uniform < 0.5 then
        E.Prepare(44100.0)
      else
        E.Prepare(96000.0);
      E.SetSettings(S);
      E.SetPitchBend(FuzzRng.Bipolar);
      E.SetModLever(FuzzRng.Uniform);

      for K := 0 to 5 do
      begin
        Note := 24 + PickInt(84);
        E.NoteOn(Note);
        E.Render(@V[0], Length(V));
        for I := 0 to High(V) do
        begin
          if IsNan(V[I]) or IsInfinite(V[I]) then
            Finite := False;
          Worst := Max(Worst, Abs(V[I]));
        end;
        if FuzzRng.Uniform < 0.6 then
          E.NoteOff(Note);
      end;
    finally
      E.Free;
    end;
  end;

  Check(Finite, '150 random patches, always finite', '');
  Check(Worst < 2.0, 'and never runs away', Format('worst peak %.2f at full volume', [Worst]));
end;

procedure Speed;
var
  S: TSettings;
  E: TEngine;
  V: TSamples;
  T0, Secs: Double;
begin
  Writeln;
  Writeln('cost');

  S := TSettings.Defaults;
  S.Res := 7; S.Sub := 6; S.Pulse := 5; S.Noise := 2;
  E := TEngine.Create;
  try
    E.Prepare(44100.0);
    E.SetSettings(S);
    E.NoteOn(48);

    SetLength(V, 44100 * 10);
    T0 := Clock;
    E.Render(@V[0], Length(V));
    Secs := Clock - T0;
  finally
    E.Free;
  end;

  Check(Secs < 10.0, '10 s of audio at 44.1 kHz (4x inside)',
    Format('%.0f ms - %.0fx realtime', [Secs * 1000, 10.0 / Secs]));
end;

begin
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  Writeln('Mz101 engine check (Pascal port)');

  PitchChecks;
  FilterChecks;
  EnvelopeChecks;
  ArpChecks;
  SequencerChecks;
  ServiceManualChecks;
  HostClockChecks;
  Fuzz;
  Speed;

  Writeln;
  if Failures = 0 then
    Writeln('all checks passed')
  else
    Writeln(Failures, ' FAILED');
  if Failures <> 0 then
    ExitCode := 1;
end.
