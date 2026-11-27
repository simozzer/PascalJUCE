// Mz808 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/TR808/Engine.h and Engine.cpp. It renders the same samples
// as the C++ engine, bit for bit (verify/build_verify.cmd checks it); see Tr808Dsp for how.

unit Tr808Engine;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  Tr808Dsp, Tr808Settings, Tr808Trigger, Tr808BassDrum, Tr808SnareDrum, Tr808Toms,
  Tr808RimShot, Tr808HandClap, Tr808Metal, Tr808Cowbell, Tr808Cymbal, Tr808HiHat;

// The sixteen sounds, in the order of the 808's instrument selector (the C++ Voice::).
const
  VoiceBD = 0; VoiceSD = 1; VoiceLT = 2; VoiceLC = 3; VoiceMT = 4; VoiceMC = 5;
  VoiceHT = 6; VoiceHC = 7; VoiceRS = 8; VoiceCL = 9; VoiceCP = 10; VoiceMA = 11;
  VoiceCB = 12; VoiceCY = 13; VoiceOH = 14; VoiceCH = 15;
  VoiceCount = 16;

  // anything over 100 is accented
  AccentVelocity = 101;

type
  TVoiceInfo = record
    Code: string;        // as printed on the panel
    Name: string;
    Note: Integer;       // the MIDI note that plays it, from the General MIDI drum map
  end;

  TSampleArray = array[0..MaxInt div SizeOf(Single) - 1] of Single;
  PSampleArray = ^TSampleArray;

// The C++ voiceInfo(); a voice out of range is the bass drum.
function VoiceInfo(Voice: Integer): TVoiceInfo;

// The voice a MIDI note plays, or -1. The GM drum map, with its near neighbours folded on
// to the nearest 808 sound (kick 1 and 2, both snares, the floor toms, both crashes).
function VoiceForNote(Note: Integer): Integer;

type
  // the circuits, and the sounds that share them
  TCircuit = (BdC, SdC, LowC, MidC, HighC, RimC, ClapC, BellC, CymC, HatC);

  TGain = record
    Target, Now: Single;
    function Next(Coef: Single): Single; inline;
  end;

  //
  // One TR-808's sound circuits, from the trigger to the master volume. Struck from MIDI:
  // a note fires its instrument's trigger, and a velocity of AccentVelocity or more makes it
  // an accented one. There is nothing to release - every sound runs out on its own, as on
  // the hardware - so note-offs are ignored.
  //
  // Everything is called from the audio thread; the plug-in publishes what the panel shows
  // (HitCount, for the pads' lights) as meters.
  //
  TEngine = class
  private
    FFs: Single;
    FSettings: TSettings;
    FRng: TRandom;
    FMetal: TMetalBank;

    FBd: TBassDrum;
    FSd: TSnareDrum;
    FLow, FMid, FHigh: TTomPair;
    FRim: TRimShot;
    FClap: THandClap;
    FBell: TCowbell;
    FCym: TCymbal;
    FHat: THiHat;

    FAwake: array[TCircuit] of Boolean;
    FLevel: array[TCircuit] of TGain;
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
    procedure AllSoundOff;   // not something an 808 can do, but MIDI expects it

    procedure Render(Output: PSingle; NumSamples: Integer);

    // bumped on every hit, for the panel's lights
    function HitCount(Voice: Integer): Cardinal;
    // For the checks: whether a circuit is running.
    function Awake(Circuit: TCircuit): Boolean;
  end;

implementation

const
  VoiceTable: array[0..VoiceCount - 1] of TVoiceInfo = (
    (Code: 'BD'; Name: 'Bass Drum';    Note: 36),
    (Code: 'SD'; Name: 'Snare Drum';   Note: 38),
    (Code: 'LT'; Name: 'Low Tom';      Note: 43),
    (Code: 'LC'; Name: 'Low Conga';    Note: 64),
    (Code: 'MT'; Name: 'Mid Tom';      Note: 47),
    (Code: 'MC'; Name: 'Mid Conga';    Note: 63),
    (Code: 'HT'; Name: 'Hi Tom';       Note: 50),
    (Code: 'HC'; Name: 'Hi Conga';     Note: 62),
    (Code: 'RS'; Name: 'Rim Shot';     Note: 37),
    (Code: 'CL'; Name: 'Claves';       Note: 75),
    (Code: 'CP'; Name: 'Hand Clap';    Note: 39),
    (Code: 'MA'; Name: 'Maracas';      Note: 70),
    (Code: 'CB'; Name: 'Cow Bell';     Note: 56),
    (Code: 'CY'; Name: 'Cymbal';       Note: 49),
    (Code: 'OH'; Name: 'Open Hihat';   Note: 46),
    (Code: 'CH'; Name: 'Closed Hihat'; Note: 42)
  );

  // Single literals the C++ writes with an f (see Tr808Dsp)
  GainTau: Single = 0.005;
  MasterCurve: Single = 1.4;
  FirstGainCoef: Single = 0.01;
  FirstDcCoef: Single = 0.999;

function VoiceInfo(Voice: Integer): TVoiceInfo;
begin
  if (Voice < 0) or (Voice >= VoiceCount) then
    Voice := 0;
  Result := VoiceTable[Voice];
end;

function VoiceForNote(Note: Integer): Integer;
begin
  case Note of
    35, 36:         Result := VoiceBD;
    37:             Result := VoiceRS;
    38, 40:         Result := VoiceSD;
    39:             Result := VoiceCP;
    41, 43, 45:     Result := VoiceLT;
    47, 48:         Result := VoiceMT;
    50:             Result := VoiceHT;
    42, 44:         Result := VoiceCH;
    46:             Result := VoiceOH;
    49, 52, 55, 57: Result := VoiceCY;
    56:             Result := VoiceCB;
    62:             Result := VoiceHC;
    63:             Result := VoiceMC;
    64:             Result := VoiceLC;
    70:             Result := VoiceMA;
    75:             Result := VoiceCL;
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
  C: TCircuit;
begin
  inherited Create;
  FFs := 48000;
  FSettings := TSettings.Defaults;
  FRng.Init;
  FMetal.Init;
  FBd.Init;
  FSd.Init;
  FLow.Init(TomLow);
  FMid.Init(TomMid);
  FHigh.Init(TomHigh);
  FRim.Init;
  FClap.Init;
  FBell.Init;
  FCym.Init;
  FHat.Init;
  for C := Low(TCircuit) to High(TCircuit) do
  begin
    FAwake[C] := False;
    FLevel[C].Target := 0;
    FLevel[C].Now := 0;
  end;
  FMaster.Target := 0;
  FMaster.Now := 0;
  FGainCoef := FirstGainCoef;
  FDcCoef := FirstDcCoef;
end;

procedure TEngine.Prepare(SampleRate: Double);
var
  C: TCircuit;
begin
  FFs := SampleRate;   // (float) sampleRate

  FMetal.Prepare(FFs, FRng);
  FBd.Prepare(FFs);
  FSd.Prepare(FFs);
  FLow.Prepare(FFs);
  FMid.Prepare(FFs);
  FHigh.Prepare(FFs);
  FRim.Prepare(FFs);
  FClap.Prepare(FFs);
  FBell.Prepare(FFs);
  FCym.Prepare(FFs);
  FHat.Prepare(FFs);

  for C := Low(TCircuit) to High(TCircuit) do
    FAwake[C] := False;

  FGainCoef := OnePoleCoef(GainTau, FFs);
  FDcCoef := 1 - 2 * PiF * 8 / FFs;
  FDcX1 := 0;
  FDcY1 := 0;

  SetSettings(FSettings);
  for C := Low(TCircuit) to High(TCircuit) do
    FLevel[C].Now := FLevel[C].Target;
  FMaster.Now := FMaster.Target;
end;

procedure TEngine.SetSettings(const S: TSettings);
begin
  FSettings := S;

  FBd.SetKnobs(S.BdDecay, S.BdTone);
  FSd.SetKnobs(S.SdTone, S.SdSnappy);
  FLow.SetKnobs(S.LtTuning);
  FMid.SetKnobs(S.MtTuning);
  FHigh.SetKnobs(S.HtTuning);
  FCym.SetKnobs(S.CyTone, S.CyDecay);
  FHat.SetKnobs(S.OhDecay);

  FLevel[BdC].Target := Taper(S.BdLevel);
  FLevel[SdC].Target := Taper(S.SdLevel);
  FLevel[LowC].Target := Taper(S.LtLevel);
  FLevel[MidC].Target := Taper(S.MtLevel);
  FLevel[HighC].Target := Taper(S.HtLevel);
  FLevel[RimC].Target := Taper(S.RsLevel);
  FLevel[ClapC].Target := Taper(S.CpLevel);
  FLevel[BellC].Target := Taper(S.CbLevel);
  FLevel[CymC].Target := Taper(S.CyLevel);
  if FHat.IsOpen then
    FLevel[HatC].Target := Taper(S.OhLevel)
  else
    FLevel[HatC].Target := Taper(S.ChLevel);

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
    VoiceBD: begin FBd.Trigger(H);           FAwake[BdC] := True;   end;
    VoiceSD: begin FSd.Trigger(H);           FAwake[SdC] := True;   end;
    VoiceLT: begin FLow.Trigger(H, False);   FAwake[LowC] := True;  end;
    VoiceLC: begin FLow.Trigger(H, True);    FAwake[LowC] := True;  end;
    VoiceMT: begin FMid.Trigger(H, False);   FAwake[MidC] := True;  end;
    VoiceMC: begin FMid.Trigger(H, True);    FAwake[MidC] := True;  end;
    VoiceHT: begin FHigh.Trigger(H, False);  FAwake[HighC] := True; end;
    VoiceHC: begin FHigh.Trigger(H, True);   FAwake[HighC] := True; end;
    VoiceRS: begin FRim.Trigger(H, False);   FAwake[RimC] := True;  end;
    VoiceCL: begin FRim.Trigger(H, True);    FAwake[RimC] := True;  end;
    VoiceCP: begin FClap.Trigger(H, False);  FAwake[ClapC] := True; end;
    VoiceMA: begin FClap.Trigger(H, True);   FAwake[ClapC] := True; end;
    VoiceCB: begin FBell.Trigger(H);         FAwake[BellC] := True; end;
    VoiceCY: begin FCym.Trigger(H);          FAwake[CymC] := True;  end;

    // the hats' LEVEL is whichever was struck last: CH chokes OH, and is then the sound
    VoiceOH, VoiceCH:
      begin
        FHat.Trigger(H, Voice = VoiceOH);
        if Voice = VoiceOH then
          FLevel[HatC].Target := Taper(FSettings.OhLevel)
        else
          FLevel[HatC].Target := Taper(FSettings.ChLevel);
        FAwake[HatC] := True;
      end;
  else
    Exit;
  end;

  Inc(FHits[Voice]);
end;

procedure TEngine.AllSoundOff;
var
  C: TCircuit;
begin
  FBd.Reset; FSd.Reset; FLow.Reset; FMid.Reset; FHigh.Reset;
  FRim.Reset; FClap.Reset; FBell.Reset; FCym.Reset; FHat.Reset;
  for C := Low(TCircuit) to High(TCircuit) do
    FAwake[C] := False;
end;

function TEngine.HitCount(Voice: Integer): Cardinal;
begin
  if (Voice >= 0) and (Voice < VoiceCount) then
    Result := FHits[Voice]
  else
    Result := 0;
end;

function TEngine.Awake(Circuit: TCircuit): Boolean;
begin
  Result := FAwake[Circuit];
end;

procedure TEngine.Render(Output: PSingle; NumSamples: Integer);
var
  Out_: PSampleArray;
  N: Integer;
  C: TCircuit;
  G: array[TCircuit] of Single;
  Sum, Y: Single;
begin
  Out_ := PSampleArray(Output);
  for N := 0 to NumSamples - 1 do
  begin
    FMetal.Tick;

    for C := Low(TCircuit) to High(TCircuit) do
      G[C] := FLevel[C].Next(FGainCoef);

    Sum := 0;
    if FAwake[BdC]   then Sum := Sum + G[BdC]   * FBd.Process;
    if FAwake[SdC]   then Sum := Sum + G[SdC]   * FSd.Process(FRng);
    if FAwake[LowC]  then Sum := Sum + G[LowC]  * FLow.Process(FRng);
    if FAwake[MidC]  then Sum := Sum + G[MidC]  * FMid.Process(FRng);
    if FAwake[HighC] then Sum := Sum + G[HighC] * FHigh.Process(FRng);
    if FAwake[RimC]  then Sum := Sum + G[RimC]  * FRim.Process;
    if FAwake[ClapC] then Sum := Sum + G[ClapC] * FClap.Process(FRng);
    if FAwake[BellC] then Sum := Sum + G[BellC] * FBell.Process(FMetal);
    if FAwake[CymC]  then Sum := Sum + G[CymC]  * FCym.Process(FMetal);
    if FAwake[HatC]  then Sum := Sum + G[HatC]  * FHat.Process(FMetal);

    // Every so often, put to sleep whatever has rung out - from rest, so a sleeping
    // circuit wakes exactly as a fresh one would. (N counts from the start of this call,
    // as the C++ n does, so where the checks fall depends on the block size.)
    if N and 31 = 0 then
    begin
      if FAwake[BdC]   and FBd.Quiet   then begin FBd.Reset;   FAwake[BdC] := False;   end;
      if FAwake[SdC]   and FSd.Quiet   then begin FSd.Reset;   FAwake[SdC] := False;   end;
      if FAwake[LowC]  and FLow.Quiet  then begin FLow.Reset;  FAwake[LowC] := False;  end;
      if FAwake[MidC]  and FMid.Quiet  then begin FMid.Reset;  FAwake[MidC] := False;  end;
      if FAwake[HighC] and FHigh.Quiet then begin FHigh.Reset; FAwake[HighC] := False; end;
      if FAwake[RimC]  and FRim.Quiet  then begin FRim.Reset;  FAwake[RimC] := False;  end;
      if FAwake[ClapC] and FClap.Quiet then begin FClap.Reset; FAwake[ClapC] := False; end;
      if FAwake[BellC] and FBell.Quiet then begin FBell.Reset; FAwake[BellC] := False; end;
      if FAwake[CymC]  and FCym.Quiet  then begin FCym.Reset;  FAwake[CymC] := False;  end;
      if FAwake[HatC]  and FHat.Quiet  then begin FHat.Reset;  FAwake[HatC] := False;  end;
    end;

    // the mixer's coupling capacitor
    Y := Sum - FDcX1 + FDcCoef * FDcY1;
    FDcX1 := Sum;
    FDcY1 := Y;

    Out_^[N] := Y * FMaster.Next(FGainCoef);
  end;
end;

end.
