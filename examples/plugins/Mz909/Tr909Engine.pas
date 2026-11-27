// Mz909 - an emulation of the TR-909 Rhythm Composer
// Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/TR909/Engine.h and Engine.cpp. It renders the same samples
// as the C++ engine, bit for bit (verify/build_verify.cmd checks it); see Tr909Dsp for how.

unit Tr909Engine;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  Tr909Dsp, Tr909Settings, Tr909BassDrum, Tr909SnareDrum, Tr909Toms, Tr909RimShot,
  Tr909HandClap, Tr909HiHat, Tr909Cymbal;

const
  // The eleven sounds, in the order of the 909's instrument selector.
  VoiceBD = 0; VoiceSD = 1; VoiceLT = 2; VoiceMT = 3; VoiceHT = 4; VoiceRS = 5;
  VoiceCP = 6; VoiceCH = 7; VoiceOH = 8; VoiceCC = 9; VoiceRC = 10;
  VoiceCount = 11;

  // A note whose velocity is at least this is accented: anything over 100.
  AccentVelocity = 101;

type
  TVoiceInfo = record
    Code: string;    // as printed on the panel
    Name: string;
    Note: Integer;   // the MIDI note that plays it, from the General MIDI drum map
  end;

  TSampleArray = array[0..MaxInt div SizeOf(Single) - 1] of Single;
  PSampleArray = ^TSampleArray;

function VoiceInfo(Voice: Integer): TVoiceInfo;

// The voice a MIDI note plays, or -1. The GM drum map, with its near neighbours folded on
// to the nearest 909 sound (kick 1 and 2, both snares, the six toms in pairs, the crashes,
// the rides and the ride bell).
function VoiceForNote(Note: Integer): Integer;

type
  TGain = record
    Target, Now: Single;
    function Next(Coef: Single): Single; inline;
  end;

const
  // the circuits; the two hihats share one
  BdC = 0; SdC = 1; LtC = 2; MtC = 3; HtC = 4; RimC = 5; ClapC = 6; HatC = 7;
  CrashC = 8; RideC = 9;
  NumCircuits = 10;

type
  //
  // One TR-909's sound circuits, from the trigger to the master volume. Struck from MIDI:
  // a note fires its instrument's trigger, and a velocity of AccentVelocity or more makes it
  // an accented one. There is nothing to release - every sound runs out on its own, as on
  // the hardware - so note-offs are ignored.
  //
  // Everything is called from the audio thread, except construction (which builds the ROMs).
  // The plug-in publishes HitCount, for the panel's lights, as meters.
  //
  TEngine = class
  private
    FFs: Single;
    FSettings: TSettings;
    FRng: TRandom;

    FBd: TBassDrum;
    FSd: TSnareDrum;
    FLt, FMt, FHt: TTom;
    FRim: TRimShot;
    FClap: THandClap;
    FHat: THiHat;
    FCrash, FRide: TCymbal;

    FAwake: array[0..NumCircuits - 1] of Boolean;
    FLevel: array[0..NumCircuits - 1] of TGain;
    FMaster: TGain;
    FGainCoef: Single;

    FDcX1, FDcY1, FDcCoef: Single;

    FHits: array[0..VoiceCount - 1] of Cardinal;
  public
    constructor Create;
    procedure Prepare(SampleRate: Double);
    procedure SetSettings(const S: TSettings);

    procedure NoteOn(Note, Velocity: Integer);
    procedure Trigger(Voice: Integer; Accented: Boolean);
    procedure AllSoundOff;   // not something a 909 can do, but MIDI expects it

    procedure Render(Output: PSingle; NumSamples: Integer);

    // bumped on every hit, for the panel's lights
    function HitCount(Voice: Integer): Cardinal;
    // For the checks: whether a circuit is running (BdC .. RideC).
    function Awake(Circuit: Integer): Boolean;
  end;

implementation

uses
  Tr909Trigger, Tr909Roms;

const
  GainTau: Single = 0.005;
  MasterCurve: Single = 1.4;
  DcCorner = 8;

  Infos: array[0..VoiceCount - 1] of TVoiceInfo = (
    (Code: 'BD'; Name: 'Bass Drum';    Note: 36),
    (Code: 'SD'; Name: 'Snare Drum';   Note: 38),
    (Code: 'LT'; Name: 'Low Tom';      Note: 43),
    (Code: 'MT'; Name: 'Mid Tom';      Note: 47),
    (Code: 'HT'; Name: 'Hi Tom';       Note: 50),
    (Code: 'RS'; Name: 'Rim Shot';     Note: 37),
    (Code: 'CP'; Name: 'Hand Clap';    Note: 39),
    (Code: 'CH'; Name: 'Closed Hihat'; Note: 42),
    (Code: 'OH'; Name: 'Open Hihat';   Note: 46),
    (Code: 'CC'; Name: 'Crash Cymbal'; Note: 49),
    (Code: 'RC'; Name: 'Ride Cymbal';  Note: 51)
  );

function VoiceInfo(Voice: Integer): TVoiceInfo;
begin
  if (Voice < 0) or (Voice >= VoiceCount) then
    Voice := 0;
  Result := Infos[Voice];
end;

function VoiceForNote(Note: Integer): Integer;
begin
  case Note of
    35, 36:         Result := VoiceBD;
    37:             Result := VoiceRS;
    38, 40:         Result := VoiceSD;
    39:             Result := VoiceCP;
    41, 43:         Result := VoiceLT;
    45, 47:         Result := VoiceMT;
    48, 50:         Result := VoiceHT;
    42, 44:         Result := VoiceCH;
    46:             Result := VoiceOH;
    49, 52, 55, 57: Result := VoiceCC;
    51, 53, 59:     Result := VoiceRC;
  else
    Result := -1;
  end;
end;

{ TGain }

function TGain.Next(Coef: Single): Single;
begin
  Now := Now + (Target - Now) * Coef;
  Result := Now;
end;

{ TEngine }

constructor TEngine.Create;
var
  C: Integer;
begin
  inherited Create;
  FFs := 48000;
  FSettings := TSettings.Defaults;
  FRng.Init;
  FBd.Init;
  FSd.Init;
  FLt.Init(tsLow);
  FMt.Init(tsMid);
  FHt.Init(tsHigh);
  FRim.Init;
  FClap.Init;
  FHat.Init;
  FCrash.Init(CrashRom);
  FRide.Init(RideRom);
  for C := 0 to NumCircuits - 1 do
  begin
    FAwake[C] := False;
    FLevel[C].Target := 0;
    FLevel[C].Now := 0;
  end;
  FMaster.Target := 0;
  FMaster.Now := 0;
  FGainCoef := 0.01;
  FDcX1 := 0;
  FDcY1 := 0;
  FDcCoef := 0.999;
  FillChar(FHits, SizeOf(FHits), 0);

  // Build the ROMs here, off the audio thread, rather than on the first hit.
  ClosedHatRom;
  OpenHatRom;
  CrashRom;
  RideRom;
end;

function TEngine.HitCount(Voice: Integer): Cardinal;
begin
  if (Voice >= 0) and (Voice < VoiceCount) then
    Result := FHits[Voice]
  else
    Result := 0;
end;

function TEngine.Awake(Circuit: Integer): Boolean;
begin
  Result := (Circuit >= 0) and (Circuit < NumCircuits) and FAwake[Circuit];
end;

procedure TEngine.Prepare(SampleRate: Double);
var
  C: Integer;
  T: Single;
begin
  FFs := SampleRate;

  FBd.Prepare(FFs);
  FSd.Prepare(FFs);
  FLt.Prepare(FFs);
  FMt.Prepare(FFs);
  FHt.Prepare(FFs);
  FRim.Prepare(FFs);
  FClap.Prepare(FFs);
  FHat.Prepare(FFs);
  FCrash.Prepare(FFs);
  FRide.Prepare(FFs);

  for C := 0 to NumCircuits - 1 do
    FAwake[C] := False;

  FGainCoef := OnePoleCoef(GainTau, FFs);
  T := 2 * PiF * DcCorner / FFs;   // 2.0f * (float) pi * 8.0f / fs, in float
  FDcCoef := 1 - T;
  FDcX1 := 0;
  FDcY1 := 0;

  SetSettings(FSettings);
  for C := 0 to NumCircuits - 1 do
    FLevel[C].Now := FLevel[C].Target;
  FMaster.Now := FMaster.Target;
end;

procedure TEngine.SetSettings(const S: TSettings);
begin
  FSettings := S;

  FBd.SetPanel(S.BdTune, S.BdAttack, S.BdDecay);
  FSd.SetPanel(S.SdTune, S.SdTone, S.SdSnappy);
  FLt.SetPanel(S.LtTune, S.LtDecay);
  FMt.SetPanel(S.MtTune, S.MtDecay);
  FHt.SetPanel(S.HtTune, S.HtDecay);
  FHat.SetPanel(S.ChDecay, S.OhDecay);
  FCrash.SetPanel(S.CrTune);
  FRide.SetPanel(S.RdTune);

  FLevel[BdC].Target := Taper(S.BdLevel);
  FLevel[SdC].Target := Taper(S.SdLevel);
  FLevel[LtC].Target := Taper(S.LtLevel);
  FLevel[MtC].Target := Taper(S.MtLevel);
  FLevel[HtC].Target := Taper(S.HtLevel);
  FLevel[RimC].Target := Taper(S.RsLevel);
  FLevel[ClapC].Target := Taper(S.CpLevel);
  FLevel[HatC].Target := Taper(S.HhLevel);
  FLevel[CrashC].Target := Taper(S.CrLevel);
  FLevel[RideC].Target := Taper(S.RdLevel);

  FMaster.Target := MasterCurve * Taper(S.Volume);
end;

procedure TEngine.NoteOn(Note, Velocity: Integer);
var
  V: Integer;
begin
  V := VoiceForNote(Note);
  if (V >= 0) and (Velocity > 0) then
    Trigger(V, Velocity >= AccentVelocity);
end;

procedure TEngine.Trigger(Voice: Integer; Accented: Boolean);
var
  H: Single;
begin
  H := TriggerHeight(Accented, FSettings.Accent);

  case Voice of
    VoiceBD: begin FBd.Trigger(H);          FAwake[BdC] := True;    end;
    VoiceSD: begin FSd.Trigger(H);          FAwake[SdC] := True;    end;
    VoiceLT: begin FLt.Trigger(H);          FAwake[LtC] := True;    end;
    VoiceMT: begin FMt.Trigger(H);          FAwake[MtC] := True;    end;
    VoiceHT: begin FHt.Trigger(H);          FAwake[HtC] := True;    end;
    VoiceRS: begin FRim.Trigger(H);         FAwake[RimC] := True;   end;
    VoiceCP: begin FClap.Trigger(H);        FAwake[ClapC] := True;  end;
    VoiceCH: begin FHat.Trigger(H, False);  FAwake[HatC] := True;   end;   // and chokes OH
    VoiceOH: begin FHat.Trigger(H, True);   FAwake[HatC] := True;   end;
    VoiceCC: begin FCrash.Trigger(H);       FAwake[CrashC] := True; end;
    VoiceRC: begin FRide.Trigger(H);        FAwake[RideC] := True;  end;
  else
    Exit;
  end;

  Inc(FHits[Voice]);
end;

procedure TEngine.AllSoundOff;
var
  C: Integer;
begin
  FBd.Reset; FSd.Reset; FLt.Reset; FMt.Reset; FHt.Reset;
  FRim.Reset; FClap.Reset; FHat.Reset; FCrash.Reset; FRide.Reset;
  for C := 0 to NumCircuits - 1 do
    FAwake[C] := False;
end;

procedure TEngine.Render(Output: PSingle; NumSamples: Integer);
var
  Out_: PSampleArray;
  N, C: Integer;
  G: array[0..NumCircuits - 1] of Single;
  Sum, Y: Single;
begin
  Out_ := PSampleArray(Output);
  for N := 0 to NumSamples - 1 do
  begin
    for C := 0 to NumCircuits - 1 do
      G[C] := FLevel[C].Next(FGainCoef);

    Sum := 0;
    if FAwake[BdC] then    Sum := Sum + G[BdC] * FBd.Process(FRng);
    if FAwake[SdC] then    Sum := Sum + G[SdC] * FSd.Process(FRng);
    if FAwake[LtC] then    Sum := Sum + G[LtC] * FLt.Process(FRng);
    if FAwake[MtC] then    Sum := Sum + G[MtC] * FMt.Process(FRng);
    if FAwake[HtC] then    Sum := Sum + G[HtC] * FHt.Process(FRng);
    if FAwake[RimC] then   Sum := Sum + G[RimC] * FRim.Process;
    if FAwake[ClapC] then  Sum := Sum + G[ClapC] * FClap.Process(FRng);
    if FAwake[HatC] then   Sum := Sum + G[HatC] * FHat.Process;
    if FAwake[CrashC] then Sum := Sum + G[CrashC] * FCrash.Process;
    if FAwake[RideC] then  Sum := Sum + G[RideC] * FRide.Process;

    // Every so often, put to sleep whatever has rung out - from rest, so a sleeping
    // circuit wakes exactly as a fresh one would.
    if (N and 31) = 0 then
    begin
      if FAwake[BdC] and FBd.Quiet then       begin FBd.Reset;    FAwake[BdC] := False;    end;
      if FAwake[SdC] and FSd.Quiet then       begin FSd.Reset;    FAwake[SdC] := False;    end;
      if FAwake[LtC] and FLt.Quiet then       begin FLt.Reset;    FAwake[LtC] := False;    end;
      if FAwake[MtC] and FMt.Quiet then       begin FMt.Reset;    FAwake[MtC] := False;    end;
      if FAwake[HtC] and FHt.Quiet then       begin FHt.Reset;    FAwake[HtC] := False;    end;
      if FAwake[RimC] and FRim.Quiet then     begin FRim.Reset;   FAwake[RimC] := False;   end;
      if FAwake[ClapC] and FClap.Quiet then   begin FClap.Reset;  FAwake[ClapC] := False;  end;
      if FAwake[HatC] and FHat.Quiet then     begin FHat.Reset;   FAwake[HatC] := False;   end;
      if FAwake[CrashC] and FCrash.Quiet then begin FCrash.Reset; FAwake[CrashC] := False; end;
      if FAwake[RideC] and FRide.Quiet then   begin FRide.Reset;  FAwake[RideC] := False;  end;
    end;

    // the mixer's coupling capacitor
    Y := Sum - FDcX1 + FDcCoef * FDcY1;
    FDcX1 := Sum;
    FDcY1 := Y;

    Out_^[N] := Y * FMaster.Next(FGainCoef);
  end;
end;

end.
