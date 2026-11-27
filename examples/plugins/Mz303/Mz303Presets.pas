// Mz303 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of source/Presets.h and Presets.cpp.

unit Mz303Presets;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  Mz303Params;

const
  NumPresets = 8;

  PresetNames: array[0..NumPresets - 1] of string = (
    'Init', 'Acid Squelch', 'Rubber Bass', 'Square Reed', 'Accent Wow', 'Long Sweep',
    'Deep Sub', 'Bright Pluck');

type
  // A factory patch is only the controls that differ from the panel's defaults. Choices are
  // the switch position as an index. One row per control changed.
  TPresetValue = record
    Preset: Integer;
    Param: Integer;
    Value: Single;
  end;

const
  NumPresetValues = 37;

  PresetValues: array[0..NumPresetValues - 1] of TPresetValue = (
    // 'Init' changes nothing

    // 'Acid Squelch'
    (Preset: 1; Param: PCutoff; Value: 2.5), (Preset: 1; Param: PRes; Value: 8.5),
    (Preset: 1; Param: PEnvMod; Value: 6.5), (Preset: 1; Param: PDecay; Value: 4),
    (Preset: 1; Param: PAccent; Value: 8),

    // 'Rubber Bass'
    (Preset: 2; Param: PCutoff; Value: 3), (Preset: 2; Param: PRes; Value: 3),
    (Preset: 2; Param: PEnvMod; Value: 4), (Preset: 2; Param: PDecay; Value: 3),
    (Preset: 2; Param: PAccent; Value: 4),

    // 'Square Reed'
    (Preset: 3; Param: PWave; Value: 1), (Preset: 3; Param: PCutoff; Value: 4),
    (Preset: 3; Param: PRes; Value: 5), (Preset: 3; Param: PEnvMod; Value: 4),
    (Preset: 3; Param: PDecay; Value: 5), (Preset: 3; Param: PAccent; Value: 6),

    // 'Accent Wow'
    (Preset: 4; Param: PCutoff; Value: 1.5), (Preset: 4; Param: PRes; Value: 10),
    (Preset: 4; Param: PEnvMod; Value: 3), (Preset: 4; Param: PDecay; Value: 3),
    (Preset: 4; Param: PAccent; Value: 10),

    // 'Long Sweep'
    (Preset: 5; Param: PCutoff; Value: 1.5), (Preset: 5; Param: PRes; Value: 7),
    (Preset: 5; Param: PEnvMod; Value: 9), (Preset: 5; Param: PDecay; Value: 10),
    (Preset: 5; Param: PAccent; Value: 5),

    // 'Deep Sub'
    (Preset: 6; Param: PWave; Value: 1), (Preset: 6; Param: PCutoff; Value: 1),
    (Preset: 6; Param: PRes; Value: 1), (Preset: 6; Param: PEnvMod; Value: 2),
    (Preset: 6; Param: PDecay; Value: 2), (Preset: 6; Param: PAccent; Value: 3),

    // 'Bright Pluck'
    (Preset: 7; Param: PCutoff; Value: 6), (Preset: 7; Param: PRes; Value: 4),
    (Preset: 7; Param: PEnvMod; Value: 7), (Preset: 7; Param: PDecay; Value: 0),
    (Preset: 7; Param: PAccent; Value: 7)
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
