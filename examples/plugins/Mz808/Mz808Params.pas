// Mz808 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/Params.h and Params.cpp.

unit Mz808Params;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  Tr808Settings;

type
  //
  // One row per front-panel knob: its parameter ID, the name a host shows, and the field of
  // TSettings it drives (see GetSettingValue / SetSettingValue). The parameter
  // declarations, the CC map, the reader and the presets all work from this, so a control
  // cannot exist in one and be missing from another.
  //
  // IDs are saved in every host project. Never rename one. They are the C++ plug-in's IDs.
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
  PBdLevel = 1; PBdTone = 2; PBdDecay = 3;
  PSdLevel = 4; PSdTone = 5; PSdSnappy = 6;
  PLtLevel = 7; PLtTuning = 8; PMtLevel = 9; PMtTuning = 10; PHtLevel = 11; PHtTuning = 12;
  PRsLevel = 13; PCpLevel = 14; PCbLevel = 15;
  PCyLevel = 16; PCyTone = 17; PCyDecay = 18;
  POhLevel = 19; POhDecay = 20; PChLevel = 21;
  PVolume = 22;

  NumSpecs = 23;

  // Every knob's travel, as printed round it.
  KnobMin = 0;
  KnobMax = 10;

  //
  // CCs use the numbers MIDI leaves undefined, 14-31 and 102-119, in panel order, left
  // to right and top to bottom - so a controller's row of knobs lands on them in order.
  // VOLUME is General MIDI's, 7.
  //
  Specs: array[0..NumSpecs - 1] of TSpec = (
    (Id: 'accent'; Name: 'Accent'; Cc: 14;
     Hint: 'How much harder an accented hit strikes: velocity above 100 is an accent. It does not just turn the sound up - every circuit answers a taller trigger in its own way, a kick blooming, a snare cracking.'),

    (Id: 'bdLevel'; Name: 'Bass Drum Level'; Cc: 15; Hint: 'Level of the bass drum.'),
    (Id: 'bdTone'; Name: 'Bass Drum Tone'; Cc: 16; Hint: 'The bass drum''s click: dark and round at 0, a sharp attack at 10.'),
    (Id: 'bdDecay'; Name: 'Bass Drum Decay'; Cc: 17; Hint: 'How long the bass drum rings: a short thud at 0, a long, sighing boom at 10.'),

    (Id: 'sdLevel'; Name: 'Snare Drum Level'; Cc: 18; Hint: 'Level of the snare drum.'),
    (Id: 'sdTone'; Name: 'Snare Drum Tone'; Cc: 19; Hint: 'The drum head: crossfades its two oscillators, low and hollow at 0, high and tight at 10.'),
    (Id: 'sdSnappy'; Name: 'Snare Drum Snappy'; Cc: 20; Hint: 'How much of the snares - the noise - goes in.'),

    (Id: 'ltLevel'; Name: 'Low Tom Level'; Cc: 21; Hint: 'Level of the low tom and the low conga, which share a circuit.'),
    (Id: 'ltTuning'; Name: 'Low Tom Tuning'; Cc: 22; Hint: 'Pitch of the low tom and low conga, a quarter-octave either way.'),
    (Id: 'mtLevel'; Name: 'Mid Tom Level'; Cc: 23; Hint: 'Level of the mid tom and the mid conga, which share a circuit.'),
    (Id: 'mtTuning'; Name: 'Mid Tom Tuning'; Cc: 24; Hint: 'Pitch of the mid tom and mid conga, a quarter-octave either way.'),
    (Id: 'htLevel'; Name: 'Hi Tom Level'; Cc: 25; Hint: 'Level of the hi tom and the hi conga, which share a circuit.'),
    (Id: 'htTuning'; Name: 'Hi Tom Tuning'; Cc: 26; Hint: 'Pitch of the hi tom and hi conga, a quarter-octave either way.'),

    (Id: 'rsLevel'; Name: 'Rim Shot Level'; Cc: 27; Hint: 'Level of the rim shot and the claves, which share a circuit.'),
    (Id: 'cpLevel'; Name: 'Hand Clap Level'; Cc: 28; Hint: 'Level of the hand clap and the maracas, which share a circuit.'),
    (Id: 'cbLevel'; Name: 'Cow Bell Level'; Cc: 29; Hint: 'Level of the cow bell.'),

    (Id: 'cyLevel'; Name: 'Cymbal Level'; Cc: 30; Hint: 'Level of the cymbal.'),
    (Id: 'cyTone'; Name: 'Cymbal Tone'; Cc: 31; Hint: 'How much of the cymbal''s top band - the splash - comes through.'),
    (Id: 'cyDecay'; Name: 'Cymbal Decay'; Cc: 102; Hint: 'How long the cymbal''s body rings.'),

    (Id: 'ohLevel'; Name: 'Open Hihat Level'; Cc: 103; Hint: 'Level of the open hihat.'),
    (Id: 'ohDecay'; Name: 'Open Hihat Decay'; Cc: 104; Hint: 'How long the open hihat rings. A closed hihat cuts it off.'),
    (Id: 'chLevel'; Name: 'Closed Hihat Level'; Cc: 105; Hint: 'Level of the closed hihat.'),

    (Id: 'volume'; Name: 'Volume'; Cc: 7; Hint: 'Master output level.')
  );

// -1 if none
function IndexOfId(const Id: string): Integer;

// CCs that can be learned: not bank select (0, 32), not the channel mode messages (120 up).
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
// same arithmetic as the C++ setValueNotifyingHost(cc / 127) through JUCE's parameter range.
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
    PBdTone:   Result := S.BdTone;
    PBdDecay:  Result := S.BdDecay;
    PSdLevel:  Result := S.SdLevel;
    PSdTone:   Result := S.SdTone;
    PSdSnappy: Result := S.SdSnappy;
    PLtLevel:  Result := S.LtLevel;
    PLtTuning: Result := S.LtTuning;
    PMtLevel:  Result := S.MtLevel;
    PMtTuning: Result := S.MtTuning;
    PHtLevel:  Result := S.HtLevel;
    PHtTuning: Result := S.HtTuning;
    PRsLevel:  Result := S.RsLevel;
    PCpLevel:  Result := S.CpLevel;
    PCbLevel:  Result := S.CbLevel;
    PCyLevel:  Result := S.CyLevel;
    PCyTone:   Result := S.CyTone;
    PCyDecay:  Result := S.CyDecay;
    POhLevel:  Result := S.OhLevel;
    POhDecay:  Result := S.OhDecay;
    PChLevel:  Result := S.ChLevel;
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
    PBdTone:   S.BdTone := V;
    PBdDecay:  S.BdDecay := V;
    PSdLevel:  S.SdLevel := V;
    PSdTone:   S.SdTone := V;
    PSdSnappy: S.SdSnappy := V;
    PLtLevel:  S.LtLevel := V;
    PLtTuning: S.LtTuning := V;
    PMtLevel:  S.MtLevel := V;
    PMtTuning: S.MtTuning := V;
    PHtLevel:  S.HtLevel := V;
    PHtTuning: S.HtTuning := V;
    PRsLevel:  S.RsLevel := V;
    PCpLevel:  S.CpLevel := V;
    PCbLevel:  S.CbLevel := V;
    PCyLevel:  S.CyLevel := V;
    PCyTone:   S.CyTone := V;
    PCyDecay:  S.CyDecay := V;
    POhLevel:  S.OhLevel := V;
    POhDecay:  S.OhDecay := V;
    PChLevel:  S.ChLevel := V;
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
  Proportion: Single;
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
  Result := KnobMin + (KnobMax - KnobMin) * Proportion;
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
