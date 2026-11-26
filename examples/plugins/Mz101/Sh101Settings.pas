// Mz101 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/SH101/Settings.h.

unit Sh101Settings;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

// Switch positions, counted from the bottom, as the C++ namespaces of enums.
const
  LfoWaveTriangle = 0; LfoWaveSquare = 1; LfoWaveRandom = 2; LfoWaveNoise = 3;
  RangeFeet16 = 0; RangeFeet8 = 1; RangeFeet4 = 2; RangeFeet2 = 3;
  PwmSourceLfo = 0; PwmSourceManual = 1; PwmSourceEnv = 2;
  SubTypeOctDown1 = 0; SubTypeOctDown2 = 1; SubTypePulse2 = 2;
  VcaModeEnv = 0; VcaModeGate = 1;
  EnvTrigGateTrig = 0; EnvTrigGate = 1; EnvTrigLfo = 2;
  PortaOff = 0; PortaAuto = 1; PortaOn = 2;
  ArpOff = 0; ArpUp = 1; ArpUpDown = 2; ArpDown = 3;
  TransposeLow = 0; TransposeMid = 1; TransposeHigh = 2;
  SeqOff = 0; SeqPlay = 1; SeqLoad = 2;
  ClockInternal = 0; ClockHost = 1;
  LfoSyncFree = 0; LfoSyncHost = 1;
  ClockDivQuarter = 0; ClockDivEighth = 1; ClockDivEighthT = 2; ClockDivSixteenth = 3;
  ClockDivSixteenthT = 4; ClockDivThirtySecond = 5;

type
  //
  // The front panel. Every slider is in panel units, 0 to 10, as printed beside it on the
  // original; every switch is its position, counted from the bottom. The engine turns these
  // into volts, hertz and seconds itself, so the plugin layer never has to know the curves.
  //
  TSettings = record
    // MODULATOR
    LfoRate: Single;
    LfoWave: Integer;

    // Not on the original: lock the modulator to the host's timeline, RATE then choosing a
    // note length (Sh101Sync) rather than hertz
    LfoSync: Integer;

    // What clocks the arpeggio and sequencer: the modulator, or - in place of the EXT CLK IN
    // jack - the host's beat grid, at this division
    ClockSource: Integer;
    ClockDiv: Integer;

    // VCO
    VcoMod: Single;
    Range: Integer;
    Pw: Single;
    PwmSource: Integer;

    // SOURCE MIXER
    Pulse: Single;
    Saw: Single;
    Sub: Single;
    SubType: Integer;
    Noise: Single;

    // VCF
    Cutoff: Single;
    Res: Single;
    VcfEnv: Single;
    VcfMod: Single;
    VcfKybd: Single;

    // VCA
    VcaMode: Integer;

    // ENV
    Attack: Single;
    Decay: Single;
    Sustain: Single;
    Release: Single;
    EnvTrig: Integer;

    // PORTAMENTO
    PortaMode: Integer;
    PortaTime: Single;

    // BENDER - how far the lever moves the VCO and the VCF, and how much LFO pushing it
    // forward adds to the VCO
    BendVco: Single;
    BendVcf: Single;
    ModDepth: Single;

    // ARPEGGIO / SEQUENCER / KEY TRANSPOSE. HOLD latches whichever of the two is running.
    ArpMode: Integer;
    SeqMode: Integer;
    ArpHold: Boolean;
    Transpose: Integer;

    // MASTER
    Tune: Single;     // cents, -50 to +50
    Volume: Single;

    // The panel as it comes out of the box (the C++ member initialisers).
    class function Defaults: TSettings; static;
  end;

implementation

class function TSettings.Defaults: TSettings;
begin
  Result.LfoRate := 5;
  Result.LfoWave := LfoWaveTriangle;
  Result.LfoSync := LfoSyncFree;
  Result.ClockSource := ClockInternal;
  Result.ClockDiv := ClockDivSixteenth;

  Result.VcoMod := 0;
  Result.Range := RangeFeet8;
  Result.Pw := 0;
  Result.PwmSource := PwmSourceManual;

  Result.Pulse := 0;
  Result.Saw := 10;
  Result.Sub := 0;
  Result.SubType := SubTypeOctDown1;
  Result.Noise := 0;

  Result.Cutoff := 6;
  Result.Res := 0;
  Result.VcfEnv := 4;
  Result.VcfMod := 0;
  Result.VcfKybd := 5;

  Result.VcaMode := VcaModeEnv;

  Result.Attack := 0;
  Result.Decay := 4;
  Result.Sustain := 5;
  Result.Release := 2;
  Result.EnvTrig := EnvTrigGateTrig;

  Result.PortaMode := PortaOff;
  Result.PortaTime := 3;

  Result.BendVco := 2;
  Result.BendVcf := 0;
  Result.ModDepth := 3;

  Result.ArpMode := ArpOff;
  Result.SeqMode := SeqOff;
  Result.ArpHold := False;
  Result.Transpose := TransposeMid;

  Result.Tune := 0;
  Result.Volume := 7;
end;

end.
