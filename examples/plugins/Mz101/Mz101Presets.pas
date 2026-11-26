// Mz101 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/Presets.h and Presets.cpp.

unit Mz101Presets;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  Mz101Params;

const
  NumPresets = 10;

  PresetNames: array[0..NumPresets - 1] of string = (
    'Init', 'Rubber Bass', 'Acid Line', 'Sub Thump', 'PWM Lead', 'Arp Bleeps',
    'Noise Snare', 'Siren', 'Random Filter', 'Resonance Whistle');

type
  // A factory patch is only the controls that differ from the panel's defaults. Choices
  // are the switch position as an index, buttons 0 or 1. One row per control changed.
  TPresetValue = record
    Preset: Integer;
    Param: Integer;
    Value: Single;
  end;

const
  NumPresetValues = 87;

  PresetValues: array[0..NumPresetValues - 1] of TPresetValue = (
    // 'Init' changes nothing

    // 'Rubber Bass'
    (Preset: 1; Param: PRange; Value: 0), (Preset: 1; Param: PSaw; Value: 0),
    (Preset: 1; Param: PPulse; Value: 10), (Preset: 1; Param: PSub; Value: 10),
    (Preset: 1; Param: PCutoff; Value: 3.5), (Preset: 1; Param: PRes; Value: 3),
    (Preset: 1; Param: PVcfEnv; Value: 5), (Preset: 1; Param: PVcfKybd; Value: 5),
    (Preset: 1; Param: PDecay; Value: 3.5), (Preset: 1; Param: PSustain; Value: 0),
    (Preset: 1; Param: PRelease; Value: 1.5),

    // 'Acid Line'
    (Preset: 2; Param: PSaw; Value: 10), (Preset: 2; Param: PCutoff; Value: 2.5),
    (Preset: 2; Param: PRes; Value: 8), (Preset: 2; Param: PVcfEnv; Value: 6),
    (Preset: 2; Param: PVcfKybd; Value: 3), (Preset: 2; Param: PDecay; Value: 3),
    (Preset: 2; Param: PSustain; Value: 0), (Preset: 2; Param: PRelease; Value: 1),
    (Preset: 2; Param: PPortaMode; Value: 1), (Preset: 2; Param: PPortaTime; Value: 2.5),

    // 'Sub Thump'
    (Preset: 3; Param: PSaw; Value: 3), (Preset: 3; Param: PSub; Value: 10),
    (Preset: 3; Param: PSubType; Value: 2), (Preset: 3; Param: PCutoff; Value: 2),
    (Preset: 3; Param: PVcfEnv; Value: 3), (Preset: 3; Param: PDecay; Value: 5),
    (Preset: 3; Param: PSustain; Value: 6), (Preset: 3; Param: PRelease; Value: 2),

    // 'PWM Lead'
    (Preset: 4; Param: PRange; Value: 2), (Preset: 4; Param: PSaw; Value: 0),
    (Preset: 4; Param: PPulse; Value: 10), (Preset: 4; Param: PPw; Value: 6),
    (Preset: 4; Param: PPwmSource; Value: 0), (Preset: 4; Param: PLfoRate; Value: 4),
    (Preset: 4; Param: PCutoff; Value: 5.5), (Preset: 4; Param: PRes; Value: 4),
    (Preset: 4; Param: PVcfEnv; Value: 3), (Preset: 4; Param: PSustain; Value: 7),
    (Preset: 4; Param: PRelease; Value: 4), (Preset: 4; Param: PPortaMode; Value: 1),
    (Preset: 4; Param: PPortaTime; Value: 3),

    // 'Arp Bleeps'
    (Preset: 5; Param: PArpMode; Value: 1), (Preset: 5; Param: PArpHold; Value: 1),
    (Preset: 5; Param: PLfoRate; Value: 6.5), (Preset: 5; Param: PRange; Value: 2),
    (Preset: 5; Param: PSaw; Value: 0), (Preset: 5; Param: PPulse; Value: 10),
    (Preset: 5; Param: PPw; Value: 3), (Preset: 5; Param: PCutoff; Value: 4),
    (Preset: 5; Param: PRes; Value: 6), (Preset: 5; Param: PVcfEnv; Value: 6),
    (Preset: 5; Param: PDecay; Value: 2.5), (Preset: 5; Param: PSustain; Value: 0),

    // 'Noise Snare'
    (Preset: 6; Param: PSaw; Value: 0), (Preset: 6; Param: PNoise; Value: 10),
    (Preset: 6; Param: PCutoff; Value: 7), (Preset: 6; Param: PRes; Value: 2),
    (Preset: 6; Param: PVcfEnv; Value: 2), (Preset: 6; Param: PVcfKybd; Value: 0),
    (Preset: 6; Param: PDecay; Value: 2.5), (Preset: 6; Param: PSustain; Value: 0),
    (Preset: 6; Param: PRelease; Value: 2.5),

    // 'Siren'
    (Preset: 7; Param: PVcoMod; Value: 6), (Preset: 7; Param: PLfoRate; Value: 3),
    (Preset: 7; Param: PSaw; Value: 10), (Preset: 7; Param: PCutoff; Value: 7),
    (Preset: 7; Param: PVcfEnv; Value: 0), (Preset: 7; Param: PSustain; Value: 10),
    (Preset: 7; Param: PVcaMode; Value: 1),

    // 'Random Filter'
    (Preset: 8; Param: PLfoWave; Value: 2), (Preset: 8; Param: PLfoRate; Value: 6),
    (Preset: 8; Param: PSaw; Value: 0), (Preset: 8; Param: PPulse; Value: 10),
    (Preset: 8; Param: PCutoff; Value: 4), (Preset: 8; Param: PRes; Value: 7),
    (Preset: 8; Param: PVcfMod; Value: 5), (Preset: 8; Param: PVcfEnv; Value: 0),
    (Preset: 8; Param: PVcaMode; Value: 1),

    // 'Resonance Whistle'
    (Preset: 9; Param: PSaw; Value: 0), (Preset: 9; Param: PRes; Value: 10),
    (Preset: 9; Param: PCutoff; Value: 5), (Preset: 9; Param: PVcfKybd; Value: 10),
    (Preset: 9; Param: PVcfEnv; Value: 0), (Preset: 9; Param: PVcaMode; Value: 1),
    (Preset: 9; Param: PPortaMode; Value: 2), (Preset: 9; Param: PPortaTime; Value: 4)
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
