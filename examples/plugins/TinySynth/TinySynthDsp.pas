unit TinySynthDsp;

{$MODE DELPHI}

interface

uses
  SysUtils, Math, JucePlugin, JuceTypes;

var
  ParamWave, ParamCutoff, ParamResonance,
  ParamAttack, ParamRelease, ParamVolume: Integer;

const
  MeterOutput = 0;   // the meter slot the editor's level meter reads

type
  TVoice = record
    Note: Integer;          // -1 = free
    Velocity: Single;       // 0..1
    Phase, PhaseInc: Double;
    Level: Double;          // envelope, 0..1
    Releasing: Boolean;
    Ic1, Ic2: Double;       // filter state
  end;

  TTinySynth = class(TJucePlugin)
  private
    FVoices: array[0..7] of TVoice;
    FPeak: Single;
    procedure NoteOn(Note, Velocity: Integer);
    procedure NoteOff(Note: Integer);
    procedure HandleMidi(const Event: TJuceMidiEvent);
    procedure Render(const Ctx: TJuceProcessContext; First, Last: Integer);
  public
    constructor Create; override;
    procedure Prepare(ASampleRate: Double; AMaxBlockSize: Integer); override;
    procedure Reset; override;
    procedure Process(const Ctx: TJuceProcessContext); override;
    function TailSeconds: Double; override;
    function ParameterToText(Index: Integer; Value: Single;
      out Text: string): Boolean; override;
    function CreateEditor: TJuceEditorBase; override;
  end;

implementation

uses
  TinySynthEditor;

function TTinySynth.CreateEditor: TJuceEditorBase;
begin
  Result := TTinySynthEditor.Create(Self);
end;

{ The Cutoff knob runs 0..100; this turns it into 20 Hz..20 kHz, so that
  every bit of the knob's travel is the same musical step. }
function CutoffToHz(Percent: Double): Double;
begin
  Result := 20 * Power(1000, Percent / 100);
end;

constructor TTinySynth.Create;
begin
  inherited Create;
  Reset;
end;

procedure TTinySynth.Prepare(ASampleRate: Double; AMaxBlockSize: Integer);
begin
  Reset;
end;

procedure TTinySynth.Reset;
var
  I: Integer;
begin
  for I := Low(FVoices) to High(FVoices) do
  begin
    FVoices[I].Note := -1;
    FVoices[I].Level := 0;
  end;
end;

function TTinySynth.TailSeconds: Double;
begin
  Result := 3.0;   // the longest release
end;

function TTinySynth.ParameterToText(Index: Integer; Value: Single;
  out Text: string): Boolean;
var
  Hz: Double;
begin
  Text := '';
  Result := Index = ParamCutoff;
  if Result then
  begin
    Hz := CutoffToHz(Value);
    if Hz < 1000 then
      Text := IntToStr(Round(Hz)) + ' Hz'
    else
      Text := FloatToStrF(Hz / 1000, ffFixed, 4, 1) + ' kHz';
  end;
end;

procedure TTinySynth.NoteOn(Note, Velocity: Integer);
var
  I, Best: Integer;
begin
  // A free voice if there is one, else steal the quietest.
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

  if FVoices[Best].Note < 0 then
  begin
    // a silent voice: start its filter from rest
    FVoices[Best].Ic1 := 0;
    FVoices[Best].Ic2 := 0;
  end;
  FVoices[Best].Note := Note;
  FVoices[Best].Velocity := Velocity / 127;
  FVoices[Best].PhaseInc := Min(0.5, 440 * Power(2, (Note - 69) / 12) / SampleRate);
  FVoices[Best].Releasing := False;
end;

procedure TTinySynth.NoteOff(Note: Integer);
var
  I: Integer;
begin
  for I := Low(FVoices) to High(FVoices) do
    if FVoices[I].Note = Note then
      FVoices[I].Releasing := True;
end;

procedure TTinySynth.HandleMidi(const Event: TJuceMidiEvent);
var
  Status, Data1, Data2: Integer;
begin
  if Event.Size < 3 then
    Exit;   // the messages we use all have 3 bytes
  Status := Event.Data[0] and $F0;
  Data1 := Event.Data[1];
  Data2 := Event.Data[2];
  if (Status = $90) and (Data2 > 0) then
    NoteOn(Data1, Data2)
  else if (Status = $80) or (Status = $90) then   // note on with velocity 0 = note off
    NoteOff(Data1)
  else if (Status = $B0) and (Data1 = 123) then
    Reset;   // All Notes Off
end;

procedure TTinySynth.Render(const Ctx: TJuceProcessContext; First, Last: Integer);
var
  I, V, Ch: Integer;
  Square: Boolean;
  AttackStep, ReleaseStep, Gain: Double;
  G, K, A1, A2, A3: Double;
  Osc, V1, V2, V3, Mix: Double;
  Buf: PJuceSampleArray;
begin
  // Read the parameters once per stretch of samples, not for every sample.
  Square := Round(Ctx.Param(ParamWave)) = 1;
  AttackStep := 1 / Max(1, Ctx.Param(ParamAttack) * 0.001 * SampleRate);
  ReleaseStep := 1 / Max(1, Ctx.Param(ParamRelease) * 0.001 * SampleRate);
  Gain := Power(10, Ctx.Param(ParamVolume) / 20) * 0.3;

  // Low-pass filter coefficients (a state-variable filter).
  G := Tan(Pi * Min(CutoffToHz(Ctx.Param(ParamCutoff)), 0.45 * SampleRate) / SampleRate);
  K := 2 - 1.9 * Ctx.Param(ParamResonance) / 100;
  A1 := 1 / (1 + G * (G + K));
  A2 := G * A1;
  A3 := G * A2;

  for I := First to Last - 1 do
  begin
    Mix := 0;
    for V := Low(FVoices) to High(FVoices) do
      with FVoices[V] do
        if Note >= 0 then
        begin
          // envelope: rise to 1, hold while the key is down, fall after
          if Releasing then
          begin
            Level := Level - ReleaseStep;
            if Level <= 0 then
            begin
              Level := 0;
              Note := -1;   // the voice is free again
              Continue;
            end;
          end
          else if Level < 1 then
            Level := Min(1, Level + AttackStep);

          // oscillator
          if Square then
          begin
            if Phase < 0.5 then Osc := 1 else Osc := -1;
          end
          else
            Osc := 2 * Phase - 1;
          Phase := Phase + PhaseInc;
          if Phase >= 1 then
            Phase := Phase - 1;

          // filter
          V3 := Osc - Ic2;
          V1 := A1 * Ic1 + A2 * V3;
          V2 := Ic2 + A2 * Ic1 + A3 * V3;
          Ic1 := 2 * V1 - Ic1;
          Ic2 := 2 * V2 - Ic2;

          Mix := Mix + V2 * Level * Velocity;
        end;

    Mix := Mix * Gain;
    for Ch := 0 to Ctx.NumOutputChannels - 1 do
    begin
      Buf := Ctx.Channel(Ch);
      if Buf <> nil then
        Buf^[I] := Mix;
    end;
    if Abs(Mix) > FPeak then
      FPeak := Abs(Mix);
  end;
end;

procedure TTinySynth.Process(const Ctx: TJuceProcessContext);
var
  E, Pos, EventPos: Integer;
  Event: PJuceMidiEvent;
begin
  FPeak := 0;
  Pos := 0;
  // Render up to each MIDI event, then apply it, so notes start on time.
  for E := 0 to Ctx.NumMidiEvents - 1 do
  begin
    Event := Ctx.MidiEvent(E);
    if Event = nil then
      Continue;
    EventPos := EnsureRange(Event^.SamplePosition, Pos, Ctx.NumSamples);
    Render(Ctx, Pos, EventPos);
    Pos := EventPos;
    HandleMidi(Event^);
  end;
  Render(Ctx, Pos, Ctx.NumSamples);
  SetMeter(MeterOutput, FPeak);   // for the editor's level meter
end;

end.
