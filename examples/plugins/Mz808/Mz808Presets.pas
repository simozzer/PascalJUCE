// Mz808 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/Presets.h and Presets.cpp.

unit Mz808Presets;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  Mz808Params;

const
  NumPresets = 9;

  PresetNames: array[0..NumPresets - 1] of string = (
    'Init', 'Long Boom', 'Tight', 'Electro', 'Deep Toms', 'Latin', 'Bright Metal',
    'Soft Accents', 'Hard Accents');

type
  // A factory kit is only the knobs that differ from the panel's defaults, in panel units.
  // One row per knob changed.
  TPresetValue = record
    Preset: Integer;
    Param: Integer;
    Value: Single;
  end;

const
  NumPresetValues = 51;

  PresetValues: array[0..NumPresetValues - 1] of TPresetValue = (
    // 'Init' changes nothing

    // 'Long Boom'
    (Preset: 1; Param: PBdDecay; Value: 10), (Preset: 1; Param: PBdTone; Value: 3),
    (Preset: 1; Param: PBdLevel; Value: 9), (Preset: 1; Param: PSdTone; Value: 4),
    (Preset: 1; Param: PSdSnappy; Value: 6), (Preset: 1; Param: PCpLevel; Value: 8),
    (Preset: 1; Param: POhDecay; Value: 3),

    // 'Tight'
    (Preset: 2; Param: PBdDecay; Value: 2.5), (Preset: 2; Param: PBdTone; Value: 7),
    (Preset: 2; Param: PSdTone; Value: 7), (Preset: 2; Param: PSdSnappy; Value: 7),
    (Preset: 2; Param: POhDecay; Value: 1.5), (Preset: 2; Param: PCyDecay; Value: 2),
    (Preset: 2; Param: PAccent; Value: 6),

    // 'Electro'
    (Preset: 3; Param: PBdDecay; Value: 6.5), (Preset: 3; Param: PBdTone; Value: 8),
    (Preset: 3; Param: PSdTone; Value: 8), (Preset: 3; Param: PSdSnappy; Value: 8),
    (Preset: 3; Param: PRsLevel; Value: 8), (Preset: 3; Param: PCbLevel; Value: 7),
    (Preset: 3; Param: PChLevel; Value: 7), (Preset: 3; Param: PAccent; Value: 8),

    // 'Deep Toms'
    (Preset: 4; Param: PLtTuning; Value: 1), (Preset: 4; Param: PMtTuning; Value: 2),
    (Preset: 4; Param: PHtTuning; Value: 3), (Preset: 4; Param: PLtLevel; Value: 8),
    (Preset: 4; Param: PMtLevel; Value: 8), (Preset: 4; Param: PHtLevel; Value: 8),
    (Preset: 4; Param: PBdDecay; Value: 7), (Preset: 4; Param: PBdTone; Value: 2),

    // 'Latin'
    (Preset: 5; Param: PLtTuning; Value: 6), (Preset: 5; Param: PMtTuning; Value: 6),
    (Preset: 5; Param: PHtTuning; Value: 6), (Preset: 5; Param: PRsLevel; Value: 7),
    (Preset: 5; Param: PCpLevel; Value: 6), (Preset: 5; Param: PCbLevel; Value: 7),
    (Preset: 5; Param: PBdDecay; Value: 4), (Preset: 5; Param: PBdLevel; Value: 7),

    // 'Bright Metal'
    (Preset: 6; Param: PCyTone; Value: 9), (Preset: 6; Param: PCyDecay; Value: 8),
    (Preset: 6; Param: PCyLevel; Value: 7), (Preset: 6; Param: POhDecay; Value: 6),
    (Preset: 6; Param: POhLevel; Value: 7), (Preset: 6; Param: PChLevel; Value: 7),

    // 'Soft Accents'
    (Preset: 7; Param: PAccent; Value: 2), (Preset: 7; Param: PBdDecay; Value: 5.5),
    (Preset: 7; Param: PSdSnappy; Value: 4), (Preset: 7; Param: PVolume; Value: 7.5),

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
