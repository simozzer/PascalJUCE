{
  ProbeEffect - a test plug-in that makes every part of the wrapper
  observable from a host. Not an example to copy; see examples/plugins.

    gain      out = in * gain (in-place effect processing)
    throw     raise in Process (exception containment -> silence)
    latency   reported to the host in Prepare
    restored  non-automatable parameter (flag pass-through test)
    state     SaveState stores the block count; after LoadState the first
              output sample of each block is that count / 1e6 (an audio
              marker, so it is observable in every format)

    MIDI      each note-on is echoed one octave up at the same position
    tail      1.5 s
}
unit ProbeEffectUnit;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8} { string literals in this file are UTF-8 }
{$ENDIF}

interface

uses
  SysUtils, JucePlugin, JuceTypes;

var
  ParamGain, ParamThrow, ParamLatency, ParamRestored: Integer;

type
  TProbeEffect = class(TJucePlugin)
  private
    FBlocks: Int64;
    FRestored: Int64; { 0 = no state loaded }
  public
    procedure Prepare(ASampleRate: Double; AMaxBlockSize: Integer); override;
    procedure Process(const Ctx: TJuceProcessContext); override;
    function SaveState: TBytes; override;
    procedure LoadState(const Data: TBytes); override;
    function TailSeconds: Double; override;
    function ParameterToText(Index: Integer; Value: Single; out Text: string): Boolean; override;
  end;

implementation

function TProbeEffect.ParameterToText(Index: Integer; Value: Single; out Text: string): Boolean;
begin
  { "Nan x" here would mean a host NaN reached Pascal (review round 5). }
  Result := Index = ParamGain;
  if Result then
    Text := FloatToStrF(Value, ffFixed, 15, 3) + ' x';
end;

procedure TProbeEffect.Prepare(ASampleRate: Double; AMaxBlockSize: Integer);
begin
  SetLatencySamples(Round(GetParameter(ParamLatency)));
end;

procedure TProbeEffect.Process(const Ctx: TJuceProcessContext);
var
  Ch, I, E: Integer;
  Gain: Single;
  Ev: PJuceMidiEvent;
begin
  if Ctx.Param(ParamThrow) >= 0.5 then
    raise Exception.Create('probe: throw requested');

  Inc(FBlocks);
  Gain := Ctx.Param(ParamGain);
  for Ch := 0 to Ctx.NumOutputChannels - 1 do
    for I := 0 to Ctx.NumSamples - 1 do
      Ctx.Channels^[Ch]^[I] := Ctx.Channels^[Ch]^[I] * Gain;

  for E := 0 to Ctx.NumMidiEvents - 1 do
  begin
    Ev := Ctx.MidiEvent(E);
    if Ev = nil then
      Continue;
    if (Ev^.Size = 3) and ((Ev^.Data[0] and $F0) = $90) and (Ev^.Data[2] > 0) then
      SendMidi([Ev^.Data[0], (Ev^.Data[1] + 12) and $7F, Ev^.Data[2]], Ev^.SamplePosition);
  end;

  if (FRestored > 0) and (Ctx.Channel(0) <> nil) and (Ctx.NumSamples > 0) then
    Ctx.Channel(0)^[0] := FRestored / 1e6;
end;

function TProbeEffect.SaveState: TBytes;
begin
  Result := nil;
  SetLength(Result, SizeOf(FBlocks));
  Move(FBlocks, Result[0], SizeOf(FBlocks));
end;

procedure TProbeEffect.LoadState(const Data: TBytes);
var
  Stored: Int64;
begin
  if Length(Data) <> SizeOf(Stored) then
    Exit;
  Move(Data[0], Stored, SizeOf(Stored));
  { Untrusted input: accept only plausible values. }
  if (Stored > 0) and (Stored < 1000000) then
  begin
    FRestored := Stored;
    FBlocks := Stored; { SaveState must reproduce what was loaded: hosts round-trip state }
  end;
end;

function TProbeEffect.TailSeconds: Double;
begin
  Result := 1.5;
end;

end.
