// Mz909 - an emulation of the TR-909 Rhythm Composer
// Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/TR909/Settings.h.

unit Tr909Settings;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

type
  //
  // The front panel. Every knob is in panel units, 0 to 10, as printed round it on the
  // original. The engine turns these into times, frequencies and levels itself, so the
  // plugin layer never has to know the curves.
  //
  // The two hihats share one LEVEL, one DAC and one VCA after their ROMs; each
  // has its own DECAY.
  //
  TSettings = record
    Accent: Single;

    BdLevel: Single;
    BdTune: Single;
    BdAttack: Single;
    BdDecay: Single;

    SdLevel: Single;
    SdTune: Single;
    SdTone: Single;
    SdSnappy: Single;

    LtLevel: Single;
    LtTune: Single;
    LtDecay: Single;
    MtLevel: Single;
    MtTune: Single;
    MtDecay: Single;
    HtLevel: Single;
    HtTune: Single;
    HtDecay: Single;

    RsLevel: Single;
    CpLevel: Single;

    HhLevel: Single;
    ChDecay: Single;
    OhDecay: Single;

    CrLevel: Single;
    CrTune: Single;
    RdLevel: Single;
    RdTune: Single;

    Volume: Single;
    // The C++ member initialisers.
    class function Defaults: TSettings; static;
  end;

implementation

class function TSettings.Defaults: TSettings;
begin
  Result.Accent := 5;

  Result.BdLevel := 8;
  Result.BdTune := 5;
  Result.BdAttack := 5;
  Result.BdDecay := 5;

  Result.SdLevel := 7;
  Result.SdTune := 5;
  Result.SdTone := 5;
  Result.SdSnappy := 5;

  Result.LtLevel := 7;
  Result.LtTune := 5;
  Result.LtDecay := 5;
  Result.MtLevel := 7;
  Result.MtTune := 5;
  Result.MtDecay := 5;
  Result.HtLevel := 7;
  Result.HtTune := 5;
  Result.HtDecay := 5;

  Result.RsLevel := 6;
  Result.CpLevel := 7;

  Result.HhLevel := 6;
  Result.ChDecay := 5;
  Result.OhDecay := 10;

  Result.CrLevel := 6;
  Result.CrTune := 5;
  Result.RdLevel := 6;
  Result.RdTune := 5;

  Result.Volume := 7;
end;

end.
