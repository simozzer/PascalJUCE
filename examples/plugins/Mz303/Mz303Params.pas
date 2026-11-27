// Mz303 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of source/Params.h and Params.cpp.

unit Mz303Params;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  Tb303Settings;

type
  TSpecKind = (skKnob, skSwitch);

  //
  // One row per front-panel control: its parameter ID, the name a host shows, and the field
  // of TSettings it drives (see GetSettingValue / SetSettingValue). The parameter
  // declarations, the CC map, the reader and the presets all work from this, so a control
  // cannot exist in one and be missing from another.
  //
  // IDs are saved in every host project. Never rename one. They are the C++ plug-in's IDs.
  //
  TSpec = record
    Id: string;
    Name: string;
    Cc: Integer;          // the MIDI CC that moves it
    Kind: TSpecKind;
    Choices: string;      // a switch's positions, bottom first, separated by '|'
    MinValue, MaxValue: Single;
    Hint: string;         // what it does, for the hover hint
  end;

  TChoiceList = array of string;

const
  // Index of each control, which is also its parameter index in the plug-in.
  PTune = 0; PCutoff = 1; PRes = 2; PEnvMod = 3; PDecay = 4; PAccent = 5; PWave = 6;
  PVolume = 7;

  NumSpecs = 8;

  //
  // CCs follow General MIDI 2's sound controllers where one fits - cutoff 74, resonance
  // 71, decay 75, sound variation 70 for the waveform, volume 7. The rest use CCs MIDI
  // leaves undefined, from 14 up.
  //
  Specs: array[0..NumSpecs - 1] of TSpec = (
    (Id: 'tune'; Name: 'Tuning'; Cc: 14; Kind: skKnob; Choices: ''; MinValue: -100; MaxValue: 100;
     Hint: 'Fine tuning, a semitone either way. Double-click for A = 440 Hz.'),
    (Id: 'cutoff'; Name: 'Cut Off Freq'; Cc: 74; Kind: skKnob; Choices: ''; MinValue: 0; MaxValue: 10;
     Hint: 'Filter cutoff. Lower is darker; the envelope and accents sweep up from here.'),
    (Id: 'res'; Name: 'Resonance'; Cc: 71; Kind: skKnob; Choices: ''; MinValue: 0; MaxValue: 10;
     Hint: 'Filter resonance: the squelch. Also makes accents swell rather than spike, and climb on a run of them.'),
    (Id: 'envMod'; Name: 'Env Mod'; Cc: 15; Kind: skKnob; Choices: ''; MinValue: 0; MaxValue: 10;
     Hint: 'How far the envelope sweeps the filter on each note. Turning it up also lowers where the filter rests.'),
    (Id: 'decay'; Name: 'Decay'; Cc: 75; Kind: skKnob; Choices: ''; MinValue: 0; MaxValue: 10;
     Hint: 'How long the filter''s envelope takes to close, 0.2 to 2.5 s. Accented notes always close at the shortest.'),
    (Id: 'accent'; Name: 'Accent'; Cc: 16; Kind: skKnob; Choices: ''; MinValue: 0; MaxValue: 10;
     Hint: 'How much an accent lifts the filter and the volume. A note is accented when its velocity is 100 or more.'),
    (Id: 'wave'; Name: 'Waveform'; Cc: 70; Kind: skSwitch; Choices: 'Saw|Square'; MinValue: 0; MaxValue: 1;
     Hint: 'SAW, or SQUARE - the saw through a waveshaper, so its halves still lean.'),
    (Id: 'volume'; Name: 'Volume'; Cc: 7; Kind: skKnob; Choices: ''; MinValue: 0; MaxValue: 10;
     Hint: 'Output level.')
  );

// -1 if none
function IndexOfId(const Id: string): Integer;

// A switch's positions, bottom first.
function SpecChoices(Index: Integer): TChoiceList;

// CCs that can be learned: not bank select (0, 32), not the mod wheel (1), not the channel
// mode messages (120 up). Every default CC passes.
function Learnable(Cc: Integer): Boolean;

// A control's value in Settings, as a parameter value (a switch's position).
function GetSettingValue(const S: TSettings; Index: Integer): Single;
// ... and back, as the C++ Reader does it: a switch to the nearest position.
procedure SetSettingValue(var S: TSettings; Index: Integer; V: Single);

// The panel's own default for a control.
function DefaultValue(Index: Integer): Single;

// Every control's parameter value into Settings. Values holds at least NumSpecs entries.
function SettingsFromValues(const Values: array of Single): TSettings;

// What a mapped CC (0..127) sets a control to: 0-127 spans the control's whole travel; a
// switch takes the nearest position. The same arithmetic as the C++
// setValueNotifyingHost(cc / 127) through JUCE's parameter ranges.
function CcToValue(Index, CcValue: Integer): Single;

// A knob's value as the C++ shows it: TUNING in whole cents ("+12 cents"), the rest to one
// decimal place.
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

function SpecChoices(Index: Integer): TChoiceList;
var
  S: string;
  P, N: Integer;
begin
  Result := nil;
  if (Index < 0) or (Index >= NumSpecs) or (Specs[Index].Kind <> skSwitch) then
    Exit;
  S := Specs[Index].Choices;
  N := 0;
  while S <> '' do
  begin
    P := Pos('|', S);
    SetLength(Result, N + 1);
    if P = 0 then
    begin
      Result[N] := S;
      S := '';
    end
    else
    begin
      Result[N] := Copy(S, 1, P - 1);
      Delete(S, 1, P);
    end;
    Inc(N);
  end;
end;

function Learnable(Cc: Integer): Boolean;
begin
  Result := (Cc >= 2) and (Cc < 120) and (Cc <> 32);
end;

function GetSettingValue(const S: TSettings; Index: Integer): Single;
begin
  case Index of
    PTune:   Result := S.Tune;
    PCutoff: Result := S.Cutoff;
    PRes:    Result := S.Res;
    PEnvMod: Result := S.EnvMod;
    PDecay:  Result := S.Decay;
    PAccent: Result := S.Accent;
    PWave:   Result := S.Wave;
    PVolume: Result := S.Volume;
  else
    Result := 0;
  end;
end;

procedure SetSettingValue(var S: TSettings; Index: Integer; V: Single);
begin
  case Index of
    PTune:   S.Tune := V;
    PCutoff: S.Cutoff := V;
    PRes:    S.Res := V;
    PEnvMod: S.EnvMod := V;
    PDecay:  S.Decay := V;
    PAccent: S.Accent := V;
    PWave:   S.Wave := Round(V);   // juce::roundToInt
    PVolume: S.Volume := V;
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
  Span := Specs[Index].MaxValue - Specs[Index].MinValue;
  if Specs[Index].Kind = skSwitch then
    Result := Specs[Index].MinValue + Round(Span * Proportion)
  else
    Result := Specs[Index].MinValue + Span * Proportion;
end;

function FormatKnobValue(Index: Integer; V: Single): string;
var
  Cents: Integer;
begin
  if Index = PTune then
  begin
    // juce::roundToInt, and a plus sign from half a cent up
    Cents := Round(V);
    if V > 0.5 then
      Result := '+' + IntToStr(Cents) + ' cents'
    else
      Result := IntToStr(Cents) + ' cents';
  end
  else
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
