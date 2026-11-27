// Mz303 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of source/TB303/Settings.h.

unit Tb303Settings;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

// The WAVEFORM switch's positions, counted from the bottom.
const
  WaveSaw = 0;
  WaveSquare = 1;

type
  //
  // The front panel: the six knobs along the top of the original, its WAVEFORM switch, and
  // VOLUME. Every knob but TUNING is in panel units, 0 to 10; the switch is its position.
  // The engine turns these into volts, hertz and seconds itself, so the plugin layer never has
  // to know the curves.
  //
  // The ACCENT knob sets how strong accents are, not which notes have one. On the original,
  // accent and slide are written into each step of the pattern; played from MIDI, a note's
  // velocity is its accent and overlapping the note before is its slide.
  //
  TSettings = record
    Tune: Single;      // cents, -100 to +100
    Cutoff: Single;
    Res: Single;
    EnvMod: Single;
    Decay: Single;
    Accent: Single;
    Wave: Integer;
    Volume: Single;
    // The C++ member initialisers.
    class function Defaults: TSettings; static;
  end;

implementation

class function TSettings.Defaults: TSettings;
begin
  Result.Tune := 0;
  Result.Cutoff := 4;
  Result.Res := 5;
  Result.EnvMod := 5;
  Result.Decay := 5;
  Result.Accent := 5;
  Result.Wave := WaveSaw;
  Result.Volume := 7;
end;

end.
