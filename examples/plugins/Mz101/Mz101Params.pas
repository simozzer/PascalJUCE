// Mz101 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/Params.h and Params.cpp.

unit Mz101Params;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  Sh101Settings;

type
  TSpecKind = (skSlider, skSwitch, skButton);

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
    Hint: string;         // what it does (the C++ editor's hover hint)
  end;

  TChoiceList = array of string;

const
  // Index of each control, which is also its parameter index in the plug-in.
  PLfoRate = 0; PLfoSync = 1; PLfoWave = 2; PClockSource = 3; PClockDiv = 4;
  PVcoMod = 5; PRange = 6; PPw = 7; PPwmSource = 8;
  PPulse = 9; PSaw = 10; PSub = 11; PSubType = 12; PNoise = 13;
  PCutoff = 14; PRes = 15; PVcfEnv = 16; PVcfMod = 17; PVcfKybd = 18;
  PVcaMode = 19;
  PAttack = 20; PDecay = 21; PSustain = 22; PRelease = 23; PEnvTrig = 24;
  PPortaMode = 25; PPortaTime = 26;
  PBendVco = 27; PBendVcf = 28; PModDepth = 29;
  PArpMode = 30; PSeqMode = 31; PArpHold = 32; PTranspose = 33;
  PTune = 34; PVolume = 35;

  NumSpecs = 36;

  //
  // CCs follow General MIDI 2's sound controllers where one fits - cutoff 74, resonance 71,
  // attack 73, decay 75, release 72, vibrato rate and depth 76 and 77, portamento 5 and 65,
  // volume 7 - and HOLD is the sustain pedal, 64, as the 101 has a HOLD pedal jack. The rest
  // use CCs MIDI leaves undefined: 14-31 and 102-119. CC 1 is the bender's MOD lever.
  //
  Specs: array[0..NumSpecs - 1] of TSpec = (
    // MODULATOR
    (Id: 'lfoRate'; Name: 'Mod Rate'; Cc: 76; Kind: skSlider; Choices: ''; MinValue: 0; MaxValue: 10;
     Hint: 'Speed of the modulator (LFO): 0.1 to 30 Hz, or with SYNC on HOST a note length from 4 bars to 1/32. With CLOCK on INT it is also the arpeggio and sequencer''s tempo: one step per cycle.'),
    (Id: 'lfoSync'; Name: 'Mod Sync'; Cc: 108; Kind: skSwitch; Choices: 'Free|Host'; MinValue: 0; MaxValue: 1;
     Hint: 'FREE: the modulator runs at RATE in hertz, as on the original. HOST: it locks to your DAW''s tempo and timeline, and RATE picks a note length. In the standalone app HOST falls back to FREE.'),
    (Id: 'lfoWave'; Name: 'Mod Waveform'; Cc: 14; Kind: skSwitch; Choices: 'Triangle|Square|Random|Noise'; MinValue: 0; MaxValue: 3;
     Hint: 'The modulator''s shape. RANDOM is a new random level on each clock; NOISE is the noise generator.'),
    (Id: 'clockSource'; Name: 'Clock'; Cc: 106; Kind: skSwitch; Choices: 'Int|Host'; MinValue: 0; MaxValue: 1;
     Hint: 'What steps the arpeggio and sequencer: the modulator (INT), or your DAW''s tempo and transport (HOST) - the EXT CLK jack. In the standalone app HOST falls back to INT.'),
    (Id: 'clockDiv'; Name: 'Clock Division'; Cc: 107; Kind: skSwitch; Choices: '1/4|1/8|1/8T|1/16|1/16T|1/32'; MinValue: 0; MaxValue: 5;
     Hint: 'With the clock on HOST: the length of each step, from quarter notes to 32nds (T = triplets).'),

    // VCO
    (Id: 'vcoMod'; Name: 'VCO Mod'; Cc: 77; Kind: skSlider; Choices: ''; MinValue: 0; MaxValue: 10;
     Hint: 'How much the modulator moves the oscillator''s pitch: vibrato, trills, sirens.'),
    (Id: 'range'; Name: 'VCO Range'; Cc: 15; Kind: skSwitch; Choices: '16''|8''|4''|2'''; MinValue: 0; MaxValue: 3;
     Hint: 'Oscillator octave, as organ footage: 16'' is lowest, 2'' highest.'),
    (Id: 'pw'; Name: 'Pulse Width'; Cc: 16; Kind: skSlider; Choices: ''; MinValue: 0; MaxValue: 10;
     Hint: 'Pulse width - or how far PWM moves it. 0 is a square (50%); 10 narrows it to nothing.'),
    (Id: 'pwmSource'; Name: 'PWM Source'; Cc: 17; Kind: skSwitch; Choices: 'LFO|Man|Env'; MinValue: 0; MaxValue: 2;
     Hint: 'What sets the pulse width: the modulator (LFO), the PW slider alone (MAN), or the envelope (ENV).'),

    // SOURCE MIXER
    (Id: 'pulse'; Name: 'Pulse Level'; Cc: 18; Kind: skSlider; Choices: ''; MinValue: 0; MaxValue: 10;
     Hint: 'Level of the pulse wave into the filter.'),
    (Id: 'saw'; Name: 'Saw Level'; Cc: 19; Kind: skSlider; Choices: ''; MinValue: 0; MaxValue: 10;
     Hint: 'Level of the sawtooth into the filter.'),
    (Id: 'sub'; Name: 'Sub Level'; Cc: 20; Kind: skSlider; Choices: ''; MinValue: 0; MaxValue: 10;
     Hint: 'Level of the sub oscillator, locked to the main one below it.'),
    (Id: 'subType'; Name: 'Sub Waveform'; Cc: 21; Kind: skSwitch; Choices: '-1 Oct|-2 Oct|-2 Pulse'; MinValue: 0; MaxValue: 2;
     Hint: 'Sub oscillator: square one octave down, square two down, or narrow pulse two down.'),
    (Id: 'noise'; Name: 'Noise Level'; Cc: 22; Kind: skSlider; Choices: ''; MinValue: 0; MaxValue: 10;
     Hint: 'Level of white noise into the filter.'),

    // VCF
    (Id: 'cutoff'; Name: 'VCF Freq'; Cc: 74; Kind: skSlider; Choices: ''; MinValue: 0; MaxValue: 10;
     Hint: 'Filter cutoff, 10 Hz to 20 kHz. Lower is darker.'),
    (Id: 'res'; Name: 'VCF Res'; Cc: 71; Kind: skSlider; Choices: ''; MinValue: 0; MaxValue: 10;
     Hint: 'Filter resonance. Emphasises the cutoff; near the top the filter whistles on its own.'),
    (Id: 'vcfEnv'; Name: 'VCF Env'; Cc: 23; Kind: skSlider; Choices: ''; MinValue: 0; MaxValue: 10;
     Hint: 'How far the envelope opens the filter on each note.'),
    (Id: 'vcfMod'; Name: 'VCF Mod'; Cc: 24; Kind: skSlider; Choices: ''; MinValue: 0; MaxValue: 10;
     Hint: 'How much the modulator moves the filter cutoff.'),
    (Id: 'vcfKybd'; Name: 'VCF Kybd'; Cc: 25; Kind: skSlider; Choices: ''; MinValue: 0; MaxValue: 10;
     Hint: 'How much the cutoff follows the keyboard. 10 tracks it exactly - play a whistling filter in tune.'),

    // VCA
    (Id: 'vcaMode'; Name: 'VCA Mode'; Cc: 26; Kind: skSwitch; Choices: 'Env|Gate'; MinValue: 0; MaxValue: 1;
     Hint: 'What shapes the volume: the envelope (ENV), or simply on while a key is held (GATE).'),

    // ENV
    (Id: 'attack'; Name: 'Env Attack'; Cc: 73; Kind: skSlider; Choices: ''; MinValue: 0; MaxValue: 10;
     Hint: 'Envelope attack time, 1.5 ms to 4 s.'),
    (Id: 'decay'; Name: 'Env Decay'; Cc: 75; Kind: skSlider; Choices: ''; MinValue: 0; MaxValue: 10;
     Hint: 'Envelope decay time down to the sustain level, 2 ms to 10 s.'),
    (Id: 'sustain'; Name: 'Env Sustain'; Cc: 79; Kind: skSlider; Choices: ''; MinValue: 0; MaxValue: 10;
     Hint: 'Level the envelope holds at while a key stays down.'),
    (Id: 'release'; Name: 'Env Release'; Cc: 72; Kind: skSlider; Choices: ''; MinValue: 0; MaxValue: 10;
     Hint: 'Envelope release time after the key is let go, 2 ms to 10 s.'),
    (Id: 'envTrig'; Name: 'Env Trigger'; Cc: 27; Kind: skSwitch; Choices: 'Gate+Trig|Gate|LFO'; MinValue: 0; MaxValue: 2;
     Hint: 'When the envelope restarts: every new key (G+T), only after all keys are up (GATE), or on every modulator cycle (LFO).'),

    // PORTAMENTO
    (Id: 'portaMode'; Name: 'Portamento'; Cc: 65; Kind: skSwitch; Choices: 'Off|Auto|On'; MinValue: 0; MaxValue: 2;
     Hint: 'Glide between notes: never, only when keys overlap (AUTO), or always.'),
    (Id: 'portaTime'; Name: 'Portamento Time'; Cc: 5; Kind: skSlider; Choices: ''; MinValue: 0; MaxValue: 10;
     Hint: 'Glide time, up to 5 s.'),

    // BENDER
    (Id: 'bendVco'; Name: 'Bender VCO'; Cc: 28; Kind: skSlider; Choices: ''; MinValue: 0; MaxValue: 10;
     Hint: 'How far the pitch wheel bends the oscillator, up to an octave.'),
    (Id: 'bendVcf'; Name: 'Bender VCF'; Cc: 29; Kind: skSlider; Choices: ''; MinValue: 0; MaxValue: 10;
     Hint: 'How far the pitch wheel moves the filter cutoff.'),
    (Id: 'modDepth'; Name: 'Bender Mod'; Cc: 30; Kind: skSlider; Choices: ''; MinValue: 0; MaxValue: 10;
     Hint: 'How much vibrato the mod wheel (CC 1) brings in.'),

    // ARPEGGIO / SEQUENCER / TRANSPOSE
    (Id: 'arpMode'; Name: 'Arpeggio'; Cc: 102; Kind: skSwitch; Choices: 'Off|Up|Up&Down|Down'; MinValue: 0; MaxValue: 3;
     Hint: 'Arpeggiator: plays the held keys in turn, at the modulator''s rate.'),
    (Id: 'seqMode'; Name: 'Sequencer'; Cc: 103; Kind: skSwitch; Choices: 'Off|Play|Load'; MinValue: 0; MaxValue: 2;
     Hint: 'PLAY runs the sequence while a key is held (the key transposes it). LOAD records a new one.'),
    (Id: 'arpHold'; Name: 'Hold'; Cc: 64; Kind: skButton; Choices: ''; MinValue: 0; MaxValue: 1;
     Hint: 'Keeps the arpeggio or sequence running after the keys are let go. Also the sustain pedal.'),
    (Id: 'transpose'; Name: 'Transpose'; Cc: 104; Kind: skSwitch; Choices: 'Low|Mid|High'; MinValue: 0; MaxValue: 2;
     Hint: 'Moves the keyboard down an octave (L), or up one (H).'),

    // MASTER
    (Id: 'tune'; Name: 'Tune'; Cc: 105; Kind: skSlider; Choices: ''; MinValue: -50; MaxValue: 50;
     Hint: 'Fine tuning, +-50 cents.'),
    (Id: 'volume'; Name: 'Volume'; Cc: 7; Kind: skSlider; Choices: ''; MinValue: 0; MaxValue: 10;
     Hint: 'Output level.')
  );

// -1 if none
function IndexOfId(const Id: string): Integer;

// A switch's positions, bottom first.
function SpecChoices(Index: Integer): TChoiceList;

// CCs that can be learned in the C++ plug-in: not bank select (0, 32), not the bender's
// MOD (1), not the channel mode messages (120 up). Every default CC passes.
function Learnable(Cc: Integer): Boolean;

// A control's value in Settings, as a parameter value (a switch's position, a button 0/1).
function GetSettingValue(const S: TSettings; Index: Integer): Single;
// ... and back, as the C++ Reader does it: switches to the nearest position, buttons on
// from a half.
procedure SetSettingValue(var S: TSettings; Index: Integer; V: Single);

// The panel's own default for a control.
function DefaultValue(Index: Integer): Single;

// Every control's parameter value into Settings. Values holds at least NumSpecs entries.
function SettingsFromValues(const Values: array of Single): TSettings;

// What a mapped CC (0..127) sets a control to: 0-127 spans the control's whole travel; a
// switch takes the nearest position; a button is on from 64. The same arithmetic as the
// C++ setValueNotifyingHost(cc / 127) through JUCE's parameter ranges.
function CcToValue(Index, CcValue: Integer): Single;

// A slider's value as the C++ shows it: one decimal place.
function FormatSliderValue(V: Single): string;

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
    PLfoRate:     Result := S.LfoRate;
    PLfoSync:     Result := S.LfoSync;
    PLfoWave:     Result := S.LfoWave;
    PClockSource: Result := S.ClockSource;
    PClockDiv:    Result := S.ClockDiv;
    PVcoMod:      Result := S.VcoMod;
    PRange:       Result := S.Range;
    PPw:          Result := S.Pw;
    PPwmSource:   Result := S.PwmSource;
    PPulse:       Result := S.Pulse;
    PSaw:         Result := S.Saw;
    PSub:         Result := S.Sub;
    PSubType:     Result := S.SubType;
    PNoise:       Result := S.Noise;
    PCutoff:      Result := S.Cutoff;
    PRes:         Result := S.Res;
    PVcfEnv:      Result := S.VcfEnv;
    PVcfMod:      Result := S.VcfMod;
    PVcfKybd:     Result := S.VcfKybd;
    PVcaMode:     Result := S.VcaMode;
    PAttack:      Result := S.Attack;
    PDecay:       Result := S.Decay;
    PSustain:     Result := S.Sustain;
    PRelease:     Result := S.Release;
    PEnvTrig:     Result := S.EnvTrig;
    PPortaMode:   Result := S.PortaMode;
    PPortaTime:   Result := S.PortaTime;
    PBendVco:     Result := S.BendVco;
    PBendVcf:     Result := S.BendVcf;
    PModDepth:    Result := S.ModDepth;
    PArpMode:     Result := S.ArpMode;
    PSeqMode:     Result := S.SeqMode;
    PArpHold:     if S.ArpHold then Result := 1 else Result := 0;
    PTranspose:   Result := S.Transpose;
    PTune:        Result := S.Tune;
    PVolume:      Result := S.Volume;
  else
    Result := 0;
  end;
end;

procedure SetSettingValue(var S: TSettings; Index: Integer; V: Single);
var
  I: Integer;
begin
  I := Round(V);   // the switches: whole numbers already, from the host
  case Index of
    PLfoRate:     S.LfoRate := V;
    PLfoSync:     S.LfoSync := I;
    PLfoWave:     S.LfoWave := I;
    PClockSource: S.ClockSource := I;
    PClockDiv:    S.ClockDiv := I;
    PVcoMod:      S.VcoMod := V;
    PRange:       S.Range := I;
    PPw:          S.Pw := V;
    PPwmSource:   S.PwmSource := I;
    PPulse:       S.Pulse := V;
    PSaw:         S.Saw := V;
    PSub:         S.Sub := V;
    PSubType:     S.SubType := I;
    PNoise:       S.Noise := V;
    PCutoff:      S.Cutoff := V;
    PRes:         S.Res := V;
    PVcfEnv:      S.VcfEnv := V;
    PVcfMod:      S.VcfMod := V;
    PVcfKybd:     S.VcfKybd := V;
    PVcaMode:     S.VcaMode := I;
    PAttack:      S.Attack := V;
    PDecay:       S.Decay := V;
    PSustain:     S.Sustain := V;
    PRelease:     S.Release := V;
    PEnvTrig:     S.EnvTrig := I;
    PPortaMode:   S.PortaMode := I;
    PPortaTime:   S.PortaTime := V;
    PBendVco:     S.BendVco := V;
    PBendVcf:     S.BendVcf := V;
    PModDepth:    S.ModDepth := V;
    PArpMode:     S.ArpMode := I;
    PSeqMode:     S.SeqMode := I;
    PArpHold:     S.ArpHold := V >= 0.5;
    PTranspose:   S.Transpose := I;
    PTune:        S.Tune := V;
    PVolume:      S.Volume := V;
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
  case Specs[Index].Kind of
    skSlider:
      begin
        Span := Specs[Index].MaxValue - Specs[Index].MinValue;
        Result := Specs[Index].MinValue + Span * Proportion;
      end;
    skSwitch:
      begin
        Span := Specs[Index].MaxValue - Specs[Index].MinValue;
        Result := Specs[Index].MinValue + Round(Span * Proportion);
      end;
    skButton:
      if Proportion >= 0.5 then
        Result := 1
      else
        Result := 0;
  end;
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

function FormatSliderValue(V: Single): string;
begin
  // Str is locale-independent: always a point, as juce::String(v, 1) has it.
  Str(V:0:1, Result);
end;

end.
