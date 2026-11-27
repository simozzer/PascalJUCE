// Mz909 - an emulation of the TR-909 Rhythm Composer
// Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/Params.h and Params.cpp.

unit Mz909Params;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  Tr909Settings;

type
  //
  // One row per front-panel knob: its parameter ID, the name a host shows, and the field of
  // TSettings it drives (see GetSettingValue / SetSettingValue). The parameter declarations,
  // the CC map, the reader and the presets all work from this, so a control cannot exist in
  // one and be missing from another.
  //
  // IDs are saved in every host project. Never rename one. They are the C++ plug-in's IDs.
  //
  // Every knob is 0..10, as printed round it.
  //
  TSpec = record
    Id: string;
    Name: string;
    Cc: Integer;          // the MIDI CC that moves it
    Hint: string;         // what it does, for the hover hint
  end;

const
  // Index of each control, which is also its parameter index in the plug-in.
  PAccent = 0;
  PBdLevel = 1; PBdTune = 2; PBdAttack = 3; PBdDecay = 4;
  PSdLevel = 5; PSdTune = 6; PSdTone = 7; PSdSnappy = 8;
  PLtLevel = 9; PLtTune = 10; PLtDecay = 11;
  PMtLevel = 12; PMtTune = 13; PMtDecay = 14;
  PHtLevel = 15; PHtTune = 16; PHtDecay = 17;
  PRsLevel = 18; PCpLevel = 19;
  PHhLevel = 20; PChDecay = 21; POhDecay = 22;
  PCrLevel = 23; PCrTune = 24; PRdLevel = 25; PRdTune = 26;
  PVolume = 27;

  NumSpecs = 28;

  KnobMin = 0;
  KnobMax = 10;

  //
  // CCs use the numbers MIDI leaves undefined, 14-31 and 102-119, in panel order, left
  // to right and top to bottom - so a controller's row of knobs lands on them in order.
  // VOLUME is General MIDI's, 7.
  //
  Specs: array[0..NumSpecs - 1] of TSpec = (
    (Id: 'accent'; Name: 'Accent'; Cc: 14;
     Hint: 'How much harder an accented hit strikes: velocity above 100 is an accent. It does not just turn the sound up - an accented kick sweeps from higher, and the drums push their output stages harder.'),

    (Id: 'bdLevel'; Name: 'Bass Drum Level'; Cc: 15; Hint: 'Level of the bass drum.'),
    (Id: 'bdTune'; Name: 'Bass Drum Tune'; Cc: 16;
     Hint: 'How far and how long the kick''s pitch falls: a short, tight drop at 0, a long, deep sweep at 10.'),
    (Id: 'bdAttack'; Name: 'Bass Drum Attack'; Cc: 17; Hint: 'The beater: how much click and noise is on the front of the kick.'),
    (Id: 'bdDecay'; Name: 'Bass Drum Decay'; Cc: 18; Hint: 'How long the bass drum rings: a short thump at 0, a long boom at 10.'),

    (Id: 'sdLevel'; Name: 'Snare Drum Level'; Cc: 19; Hint: 'Level of the snare drum.'),
    (Id: 'sdTune'; Name: 'Snare Drum Tune'; Cc: 20; Hint: 'Pitch of the drum head, a little over a quarter-octave either way.'),
    (Id: 'sdTone'; Name: 'Snare Drum Tone'; Cc: 21; Hint: 'How bright the snares are: dark at 0, crisp at 10.'),
    (Id: 'sdSnappy'; Name: 'Snare Drum Snappy'; Cc: 22; Hint: 'How much of the snares - the noise - goes in.'),

    (Id: 'ltLevel'; Name: 'Low Tom Level'; Cc: 23; Hint: 'Level of the low tom.'),
    (Id: 'ltTune'; Name: 'Low Tom Tune'; Cc: 24; Hint: 'Pitch of the low tom, half an octave either way.'),
    (Id: 'ltDecay'; Name: 'Low Tom Decay'; Cc: 25; Hint: 'How long the low tom rings.'),
    (Id: 'mtLevel'; Name: 'Mid Tom Level'; Cc: 26; Hint: 'Level of the mid tom.'),
    (Id: 'mtTune'; Name: 'Mid Tom Tune'; Cc: 27; Hint: 'Pitch of the mid tom, half an octave either way.'),
    (Id: 'mtDecay'; Name: 'Mid Tom Decay'; Cc: 28; Hint: 'How long the mid tom rings.'),
    (Id: 'htLevel'; Name: 'Hi Tom Level'; Cc: 29; Hint: 'Level of the hi tom.'),
    (Id: 'htTune'; Name: 'Hi Tom Tune'; Cc: 30; Hint: 'Pitch of the hi tom, half an octave either way.'),
    (Id: 'htDecay'; Name: 'Hi Tom Decay'; Cc: 31; Hint: 'How long the hi tom rings.'),

    (Id: 'rsLevel'; Name: 'Rim Shot Level'; Cc: 102; Hint: 'Level of the rim shot.'),
    (Id: 'cpLevel'; Name: 'Hand Clap Level'; Cc: 103; Hint: 'Level of the hand clap.'),

    (Id: 'hhLevel'; Name: 'Hihat Level'; Cc: 104; Hint: 'Level of both hihats, which share one DAC and one VCA.'),
    (Id: 'chDecay'; Name: 'Closed Hihat Decay'; Cc: 105;
     Hint: 'How long the closed hihat rings before its VCA shuts. 5 is the measured hat.'),
    (Id: 'ohDecay'; Name: 'Open Hihat Decay'; Cc: 106;
     Hint: 'How long the open hihat rings before its VCA shuts; 10 is the measured hat. A closed hihat cuts it off.'),

    (Id: 'crLevel'; Name: 'Crash Level'; Cc: 107; Hint: 'Level of the crash cymbal.'),
    (Id: 'crTune'; Name: 'Crash Tune'; Cc: 108;
     Hint: 'The speed the crash''s sample plays at: lower and longer at 0, higher and shorter at 10.'),
    (Id: 'rdLevel'; Name: 'Ride Level'; Cc: 109; Hint: 'Level of the ride cymbal.'),
    (Id: 'rdTune'; Name: 'Ride Tune'; Cc: 110;
     Hint: 'The speed the ride''s sample plays at: lower and longer at 0, higher and shorter at 10.'),

    (Id: 'volume'; Name: 'Volume'; Cc: 7; Hint: 'Master output level.')
  );

// -1 if none
function IndexOfId(const Id: string): Integer;

// CCs that can be learned: not bank select (0, 32), not the channel mode messages (120 up).
// Every default CC passes. (Unlike the Mz303, the mod wheel, 1, can be learned.)
function Learnable(Cc: Integer): Boolean;

// A control's value in Settings.
function GetSettingValue(const S: TSettings; Index: Integer): Single;
// ... and back, as the C++ Reader does it.
procedure SetSettingValue(var S: TSettings; Index: Integer; V: Single);

// The panel's own default for a control.
function DefaultValue(Index: Integer): Single;

// Every control's parameter value into Settings. Values holds at least NumSpecs entries.
function SettingsFromValues(const Values: array of Single): TSettings;

// What a mapped CC (0..127) sets a control to: 0-127 spans the knob's whole travel. The
// same arithmetic as the C++ setValueNotifyingHost(cc / 127) through JUCE's 0..10 range.
function CcToValue(Index, CcValue: Integer): Single;

// A knob's value as the C++ shows it: to one decimal place.
function FormatKnobValue(Index: Integer; V: Single): string;

// The hover hint (params::hintFor): name, what it does, and the CC it answers to now -
// which MIDI learn may have changed from the default in the table (Cc < 0 for none).
function HintFor(Index, Cc: Integer; Learning: Boolean): string;

implementation

uses
  SysUtils;

function IndexOfId(const Id: string): Integer;
var
  I: Integer;
begin
  for I := 0 to NumSpecs - 1 do
    if Specs[I].Id = Id then
    begin
      Result := I;
      Exit;
    end;
  Result := -1;
end;

function Learnable(Cc: Integer): Boolean;
begin
  Result := (Cc >= 1) and (Cc < 120) and (Cc <> 32);
end;

function GetSettingValue(const S: TSettings; Index: Integer): Single;
begin
  case Index of
    PAccent:   Result := S.Accent;
    PBdLevel:  Result := S.BdLevel;
    PBdTune:   Result := S.BdTune;
    PBdAttack: Result := S.BdAttack;
    PBdDecay:  Result := S.BdDecay;
    PSdLevel:  Result := S.SdLevel;
    PSdTune:   Result := S.SdTune;
    PSdTone:   Result := S.SdTone;
    PSdSnappy: Result := S.SdSnappy;
    PLtLevel:  Result := S.LtLevel;
    PLtTune:   Result := S.LtTune;
    PLtDecay:  Result := S.LtDecay;
    PMtLevel:  Result := S.MtLevel;
    PMtTune:   Result := S.MtTune;
    PMtDecay:  Result := S.MtDecay;
    PHtLevel:  Result := S.HtLevel;
    PHtTune:   Result := S.HtTune;
    PHtDecay:  Result := S.HtDecay;
    PRsLevel:  Result := S.RsLevel;
    PCpLevel:  Result := S.CpLevel;
    PHhLevel:  Result := S.HhLevel;
    PChDecay:  Result := S.ChDecay;
    POhDecay:  Result := S.OhDecay;
    PCrLevel:  Result := S.CrLevel;
    PCrTune:   Result := S.CrTune;
    PRdLevel:  Result := S.RdLevel;
    PRdTune:   Result := S.RdTune;
    PVolume:   Result := S.Volume;
  else
    Result := 0;
  end;
end;

procedure SetSettingValue(var S: TSettings; Index: Integer; V: Single);
begin
  case Index of
    PAccent:   S.Accent := V;
    PBdLevel:  S.BdLevel := V;
    PBdTune:   S.BdTune := V;
    PBdAttack: S.BdAttack := V;
    PBdDecay:  S.BdDecay := V;
    PSdLevel:  S.SdLevel := V;
    PSdTune:   S.SdTune := V;
    PSdTone:   S.SdTone := V;
    PSdSnappy: S.SdSnappy := V;
    PLtLevel:  S.LtLevel := V;
    PLtTune:   S.LtTune := V;
    PLtDecay:  S.LtDecay := V;
    PMtLevel:  S.MtLevel := V;
    PMtTune:   S.MtTune := V;
    PMtDecay:  S.MtDecay := V;
    PHtLevel:  S.HtLevel := V;
    PHtTune:   S.HtTune := V;
    PHtDecay:  S.HtDecay := V;
    PRsLevel:  S.RsLevel := V;
    PCpLevel:  S.CpLevel := V;
    PHhLevel:  S.HhLevel := V;
    PChDecay:  S.ChDecay := V;
    POhDecay:  S.OhDecay := V;
    PCrLevel:  S.CrLevel := V;
    PCrTune:   S.CrTune := V;
    PRdLevel:  S.RdLevel := V;
    PRdTune:   S.RdTune := V;
    PVolume:   S.Volume := V;
  end;
end;

function DefaultValue(Index: Integer): Single;
begin
  Result := GetSettingValue(TSettings.Defaults, Index);
end;

function SettingsFromValues(const Values: array of Single): TSettings;
var
  I: Integer;
begin
  Result := TSettings.Defaults;
  for I := 0 to NumSpecs - 1 do
    if I <= High(Values) then
      SetSettingValue(Result, I, Values[I]);
end;

function CcToValue(Index, CcValue: Integer): Single;
var
  Proportion, Span: Single;
begin
  Result := 0;
  if (Index < 0) or (Index >= NumSpecs) then
    Exit;
  if CcValue < 0 then
    CcValue := 0;
  if CcValue > 127 then
    CcValue := 127;

  Proportion := CcValue;
  Proportion := Proportion / 127;
  Span := KnobMax - KnobMin;
  Result := KnobMin + Span * Proportion;
end;

function FormatKnobValue(Index: Integer; V: Single): string;
begin
  // Str is locale-independent: always a point, as juce::String(v, 1) has it.
  Str(V:0:1, Result);
end;

function HintFor(Index, Cc: Integer; Learning: Boolean): string;
var
  Midi: string;
begin
  Result := '';
  if (Index < 0) or (Index >= NumSpecs) then
    Exit;
  if Learning then
    Midi := 'MIDI LEARN: move a knob on your controller. Right-click to cancel.'
  else if Cc < 0 then
    Midi := 'No MIDI CC (default ' + IntToStr(Specs[Index].Cc) + '). Right-click to learn one.'
  else if Cc <> Specs[Index].Cc then
    Midi := 'MIDI CC ' + IntToStr(Cc) + ', learned (default ' + IntToStr(Specs[Index].Cc) + '). Right-click to change.'
  else
    Midi := 'MIDI CC ' + IntToStr(Cc) + '. Right-click to learn another.';
  Result := UpperCase(Specs[Index].Name) + #10 + Specs[Index].Hint + #10 + Midi;
end;

end.
