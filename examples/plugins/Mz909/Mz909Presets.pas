// Mz909 - an emulation of the TR-909 Rhythm Composer
// Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/Presets.h and Presets.cpp.

unit Mz909Presets;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  Mz909Params;

const
  NumPresets = 9;

  PresetNames: array[0..NumPresets - 1] of string = (
    'Init', 'House', 'Techno', 'Long Kick', 'Punchy', 'Deep Toms', 'Bright Metal',
    'Dark Metal', 'Hard Accents');

type
  // A factory kit is only the knobs that differ from the panel's defaults, in panel units.
  // One row per knob changed.
  TPresetValue = record
    Preset: Integer;
    Param: Integer;
    Value: Single;
  end;

const
  NumPresetValues = 52;

  PresetValues: array[0..NumPresetValues - 1] of TPresetValue = (
    // 'Init' changes nothing

    // 'House'
    (Preset: 1; Param: PBdDecay; Value: 6), (Preset: 1; Param: PBdAttack; Value: 6),
    (Preset: 1; Param: PBdLevel; Value: 9), (Preset: 1; Param: PCpLevel; Value: 8),
    (Preset: 1; Param: POhDecay; Value: 3.5), (Preset: 1; Param: PChDecay; Value: 2.5),
    (Preset: 1; Param: PHhLevel; Value: 7),

    // 'Techno'
    (Preset: 2; Param: PBdDecay; Value: 7.5), (Preset: 2; Param: PBdTune; Value: 3),
    (Preset: 2; Param: PBdAttack; Value: 8), (Preset: 2; Param: PBdLevel; Value: 9),
    (Preset: 2; Param: PSdTune; Value: 6), (Preset: 2; Param: PSdSnappy; Value: 7),
    (Preset: 2; Param: PRsLevel; Value: 7), (Preset: 2; Param: POhDecay; Value: 2.5),
    (Preset: 2; Param: PAccent; Value: 7),

    // 'Long Kick'
    (Preset: 3; Param: PBdDecay; Value: 10), (Preset: 3; Param: PBdTune; Value: 7),
    (Preset: 3; Param: PBdAttack; Value: 3), (Preset: 3; Param: PBdLevel; Value: 9),
    (Preset: 3; Param: PVolume; Value: 6.5),

    // 'Punchy'
    (Preset: 4; Param: PBdDecay; Value: 3.5), (Preset: 4; Param: PBdTune; Value: 2),
    (Preset: 4; Param: PBdAttack; Value: 9),
    (Preset: 4; Param: PSdTune; Value: 7), (Preset: 4; Param: PSdTone; Value: 7),
    (Preset: 4; Param: PSdSnappy; Value: 7), (Preset: 4; Param: PChDecay; Value: 1.5),
    (Preset: 4; Param: PAccent; Value: 6),

    // 'Deep Toms'
    (Preset: 5; Param: PLtTune; Value: 1), (Preset: 5; Param: PMtTune; Value: 2),
    (Preset: 5; Param: PHtTune; Value: 3),
    (Preset: 5; Param: PLtDecay; Value: 8), (Preset: 5; Param: PMtDecay; Value: 8),
    (Preset: 5; Param: PHtDecay; Value: 8),
    (Preset: 5; Param: PLtLevel; Value: 8), (Preset: 5; Param: PMtLevel; Value: 8),
    (Preset: 5; Param: PHtLevel; Value: 8),

    // 'Bright Metal'
    (Preset: 6; Param: PHhLevel; Value: 7), (Preset: 6; Param: POhDecay; Value: 7),
    (Preset: 6; Param: PChDecay; Value: 4),
    (Preset: 6; Param: PCrTune; Value: 7), (Preset: 6; Param: PCrLevel; Value: 7),
    (Preset: 6; Param: PRdTune; Value: 6.5), (Preset: 6; Param: PRdLevel; Value: 7),

    // 'Dark Metal'
    (Preset: 7; Param: POhDecay; Value: 6), (Preset: 7; Param: PCrTune; Value: 2),
    (Preset: 7; Param: PRdTune; Value: 3), (Preset: 7; Param: PSdTone; Value: 3),

    // 'Hard Accents'
    (Preset: 8; Param: PAccent; Value: 10), (Preset: 8; Param: PBdDecay; Value: 6),
    (Preset: 8; Param: PSdSnappy; Value: 6)
  );

// Every control to its default, then the preset's own values on top. Values holds at least
// NumSpecs entries. Allocates nothing: safe on the audio thread.
procedure PresetValuesOf(Preset: Integer; var Values: array of Single);

implementation

procedure PresetValuesOf(Preset: Integer; var Values: array of Single);
var
  I: Integer;
begin
  for I := 0 to NumSpecs - 1 do
    if I <= High(Values) then
      Values[I] := DefaultValue(I);

  for I := 0 to NumPresetValues - 1 do
    if (PresetValues[I].Preset = Preset) and (PresetValues[I].Param <= High(Values)) then
      Values[PresetValues[I].Param] := PresetValues[I].Value;
end;

end.
