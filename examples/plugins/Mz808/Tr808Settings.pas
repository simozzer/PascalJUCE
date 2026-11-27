// Mz808 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/TR808/Settings.h.

unit Tr808Settings;

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
  // Pairs sharing one circuit - the toms and congas, rim shot and claves, hand clap and
  // maracas - share their knobs, as on the hardware.
  //
  TSettings = record
    Accent: Single;

    BdLevel: Single;
    BdTone: Single;
    BdDecay: Single;

    SdLevel: Single;
    SdTone: Single;
    SdSnappy: Single;

    LtLevel: Single;
    LtTuning: Single;
    MtLevel: Single;
    MtTuning: Single;
    HtLevel: Single;
    HtTuning: Single;

    RsLevel: Single;
    CpLevel: Single;
    CbLevel: Single;

    CyLevel: Single;
    CyTone: Single;
    CyDecay: Single;

    OhLevel: Single;
    OhDecay: Single;
    ChLevel: Single;

    Volume: Single;
    // The C++ member initialisers.
    class function Defaults: TSettings; static;
  end;

implementation

class function TSettings.Defaults: TSettings;
begin
  Result.Accent := 5;

  Result.BdLevel := 8;
  Result.BdTone := 5;
  Result.BdDecay := 5;

  Result.SdLevel := 7;
  Result.SdTone := 5;
  Result.SdSnappy := 5;

  Result.LtLevel := 7;
  Result.LtTuning := 5;
  Result.MtLevel := 7;
  Result.MtTuning := 5;
  Result.HtLevel := 7;
  Result.HtTuning := 5;

  Result.RsLevel := 6;
  Result.CpLevel := 7;
  Result.CbLevel := 6;

  Result.CyLevel := 6;
  Result.CyTone := 5;
  Result.CyDecay := 5;

  Result.OhLevel := 6;
  Result.OhDecay := 4;
  Result.ChLevel := 6;

  Result.Volume := 7;
end;

end.
