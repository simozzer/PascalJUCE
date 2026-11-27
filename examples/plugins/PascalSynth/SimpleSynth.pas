{
  SimpleSynth - a minimal template instrument for PascalJUCE.
  8 voices, sine/saw/square, linear attack/release, gain, and a custom editor
  (SynthEditor.pas) with an output meter.
  Deliberately small: copy this folder and make it your own.
  SPDX-License-Identifier: MIT-0 (no attribution needed). The plug-in you build
  from it contains JUCE: see THIRD_PARTY_NOTICES.md before you distribute it.
}
unit SimpleSynth;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8} { string literals in this file are UTF-8 }
{$ENDIF}

interface

uses
  SysUtils, JucePlugin, JuceTypes;

var
  { Parameter indices - assigned in the library's begin..end block. }
  ParamWave, ParamAttack, ParamRelease, ParamGain: Integer;

type
  TVoice = record
    Note: Integer;          { -1 = free }
    Phase: Double;          { 0..1 }
    PhaseInc: Double;
    Level: Double;          { envelope 0..1 }
    Releasing: Boolean;
    Velocity: Single;
  end;

  TSimpleSynth = class(TJucePlugin)
  private
    FVoices: array[0..7] of TVoice;
    FTuning: Single;        { A4 in Hz: extra state, saved with SaveState }
    FPeak: Single;          { loudest output sample of the block, for the meter }
    FScopeTimeMs: Single;   { the scope's TIME knob: a view setting, saved with SaveState }
    procedure NoteOn(Note, Velocity: Integer);
    procedure NoteOff(Note: Integer);
    procedure HandleMidi(const Event: TJuceMidiEvent);
    procedure Render(const Ctx: TJuceProcessContext; StartSample, EndSample: Integer);
  public
    constructor Create; override;
    procedure Prepare(ASampleRate: Double; AMaxBlockSize: Integer); override;
    procedure Reset; override;
    procedure Process(const Ctx: TJuceProcessContext); override;
    function TailSeconds: Double; override;
    { The window: return nil (or delete this) for the host's generic editor. }
    function CreateEditor: TJuceEditorBase; override;
    { Anything beyond the parameters goes here. LoadState data comes from project
      files, i.e. strangers: check the size, the version and every value. }
    function SaveState: TBytes; override;
    procedure LoadState(const Data: TBytes); override;
    { How much the scope shows, in ms: set by the editor's TIME knob (message
      thread). Not a parameter, so the host doesn't automate it or record it
      for undo; it is saved with the project all the same. }
    property ScopeTimeMs: Single read FScopeTimeMs write FScopeTimeMs;
  end;

implementation

uses
  Math, SynthEditor;

function TSimpleSynth.CreateEditor: TJuceEditorBase;
begin
  Result := TSynthEditor.Create(Self);
end;

constructor TSimpleSynth.Create;
begin
  inherited Create;
  FTuning := 440;
  FScopeTimeMs := 20;
  Reset;
end;

procedure TSimpleSynth.Prepare(ASampleRate: Double; AMaxBlockSize: Integer);
begin
  Reset;
end;

procedure TSimpleSynth.Reset;
var
  I: Integer;
begin
  for I := Low(FVoices) to High(FVoices) do
  begin
    FVoices[I].Note := -1;
    FVoices[I].Level := 0;
  end;
end;

const
  StateVersion = 2;

{ Layout: version byte, then the tuning as a little-endian Single, then (from
  version 2) the scope's time in ms, the same way. Version 1 (no scope time)
  still loads. }
function TSimpleSynth.SaveState: TBytes;
begin
  Result := nil;
  SetLength(Result, 1 + 2 * SizeOf(Single));
  Result[0] := StateVersion;
  Move(FTuning, Result[1], SizeOf(Single));
  Move(FScopeTimeMs, Result[1 + SizeOf(Single)], SizeOf(Single));
end;

procedure TSimpleSynth.LoadState(const Data: TBytes);
var
  Tuning, ScopeTime: Single;
begin
  { Never trust the length, the version or the values. }
  if (Length(Data) = 1 + SizeOf(Single)) and (Data[0] = 1) then
    ScopeTime := FScopeTimeMs { version 1: keep the scope as it is }
  else if (Length(Data) = 1 + 2 * SizeOf(Single)) and (Data[0] = 2) then
    Move(Data[1 + SizeOf(Single)], ScopeTime, SizeOf(Single))
  else
    Exit; { unknown or damaged: keep the defaults }
  Move(Data[1], Tuning, SizeOf(Single));
  if (Tuning >= 400) and (Tuning <= 480) then { also false for NaN }
    FTuning := Tuning;
  if (ScopeTime >= 1) and (ScopeTime <= 1000) then
    FScopeTimeMs := ScopeTime;
end;

function TSimpleSynth.TailSeconds: Double;
begin
  Result := 2.0; { longest release }
end;

procedure TSimpleSynth.NoteOn(Note, Velocity: Integer);
var
  I, Best: Integer;
begin
  { Reuse a free voice, else steal the quietest. }
  Best := 0;
  for I := Low(FVoices) to High(FVoices) do
  begin
    if FVoices[I].Note < 0 then
    begin
      Best := I;
      Break;
    end;
    if FVoices[I].Level < FVoices[Best].Level then
      Best := I;
  end;

  FVoices[Best].Note := Note;
  { At most half a cycle per sample (Nyquist): at low sample rates a high note
    would otherwise make Phase grow faster than it wraps. }
  FVoices[Best].PhaseInc := Min(0.5, FTuning * Power(2, (Note - 69) / 12) / SampleRate);
  FVoices[Best].Releasing := False;
  FVoices[Best].Velocity := Velocity / 127;
end;

procedure TSimpleSynth.NoteOff(Note: Integer);
var
  I: Integer;
begin
  for I := Low(FVoices) to High(FVoices) do
    if (FVoices[I].Note = Note) and not FVoices[I].Releasing then
      FVoices[I].Releasing := True;
end;

procedure TSimpleSynth.HandleMidi(const Event: TJuceMidiEvent);
var
  Status, Data1, Data2: Integer;
begin
  if Event.Size < 3 then
    Exit;
  Status := Event.Data[0] and $F0;
  Data1 := Event.Data[1];
  Data2 := Event.Data[2];
  if (Status = $90) and (Data2 > 0) then
    NoteOn(Data1, Data2)
  else if (Status = $80) or ((Status = $90) and (Data2 = 0)) then
    NoteOff(Data1)
  else if (Status = $B0) and (Data1 = 123) then { all notes off }
    Reset;
end;

procedure TSimpleSynth.Render(const Ctx: TJuceProcessContext; StartSample, EndSample: Integer);
var
  V, I, Ch, Wave: Integer;
  Buf: PJuceSampleArray;
  AttackStep, ReleaseStep, Gain, S, Sample: Double;
begin
  Wave := Round(Ctx.Param(ParamWave));
  AttackStep := 1 / Max(1, Ctx.Param(ParamAttack) * 0.001 * SampleRate);
  ReleaseStep := 1 / Max(1, Ctx.Param(ParamRelease) * 0.001 * SampleRate);
  Gain := Ctx.Param(ParamGain) * 0.25;

  for I := StartSample to EndSample - 1 do
  begin
    Sample := 0;
    for V := Low(FVoices) to High(FVoices) do
      with FVoices[V] do
        if Note >= 0 then
        begin
          if Releasing then
          begin
            Level := Level - ReleaseStep;
            if Level <= 0 then
            begin
              Level := 0;
              Note := -1;
              Continue;
            end;
          end
          else if Level < 1 then
            Level := Min(1, Level + AttackStep);

          case Wave of
            1: S := 2 * Phase - 1;                     { saw }
            2: if Phase < 0.5 then S := 1 else S := -1; { square }
          else
            S := Sin(2 * Pi * Phase);                  { sine }
          end;
          Sample := Sample + S * Level * Velocity;

          Phase := Phase + PhaseInc;
          if Phase >= 1 then
            Phase := Phase - Int(Phase); { wraps any increment, also after pitch changes }
        end;

    { Ctx.Channel is bounds-checked and returns nil for a missing channel. }
    for Ch := 0 to Ctx.NumOutputChannels - 1 do
    begin
      Buf := Ctx.Channel(Ch);
      if Buf <> nil then
        Buf^[I] := Sample * Gain;
    end;
    if Abs(Sample * Gain) > FPeak then
      FPeak := Abs(Sample * Gain);
  end;
end;

procedure TSimpleSynth.Process(const Ctx: TJuceProcessContext);
var
  E, Pos, EventPos: Integer;
  Event: PJuceMidiEvent;
begin
  { Render up to each MIDI event so notes start sample-accurately. }
  FPeak := 0;
  Pos := 0;
  for E := 0 to Ctx.NumMidiEvents - 1 do
  begin
    Event := Ctx.MidiEvent(E);
    if Event = nil then
      Continue;
    { Clamp: never trust positions, even though the wrapper already does. }
    EventPos := EnsureRange(Event^.SamplePosition, Pos, Ctx.NumSamples);
    Render(Ctx, Pos, EventPos);
    Pos := EventPos;
    HandleMidi(Event^);
  end;
  Render(Ctx, Pos, Ctx.NumSamples);
  { For the editor's meter: one atomic store, safe on the audio thread. }
  SetMeter(MeterOutput, FPeak);
end;

end.
