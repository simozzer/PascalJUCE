// Mz950 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// The plug-in's parameters: the Object Pascal counterpart of
// VirtualS950Processor::describeParameters (Plugin/Source/PluginProcessor.cpp).
//
// One row per parameter, in the C++'s declaration order, which is also each one's parameter
// index here: the same ids (saved in every host project - never rename one), names, ranges,
// defaults and value texts. Each row also carries the MIDI CC the C++ hard-wires to it (its
// trimControls table and the special cases in processBlock), so the parameter list, the CC
// map, MIDI learn and the reader all work from one table.
//
// What the framework cannot say: a skewed range. JUCE's gain (skew 0.5) and glideTime (skew
// 0.4) knobs move along a curve; a PascalJUCE float parameter is linear in the host's
// normalised value. The skew is kept here all the same (Skew, NormalisedToPlain), so a CC
// reaches exactly the value the C++'s does - CC 5 at 64 is the same 0.54 s - and a panel may
// draw its knob on the same curve.

unit Mz950Params;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$MINFPCONSTPREC 64}   // a real literal is a double, as in C++
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

type
  TMz950ParamKind = (mkFloat, mkInt, mkBool, mkChoice);

  // How a value reads (the C++'s withStringFromValueFunction lambdas).
  TMz950TextStyle = (
    tsDefault,    // the host's own: a switch's On/Off, a choice's name
    tsGain,       // "0.70"
    tsSemitones,  // "1 semitone", "7 semitones"
    tsOffset,     // "+12", "-40", "+0"
    tsRate,       // a multiplier on the programme's rate: "x0.25" .. "x256"
    tsPercent,    // "70%"
    tsGlide,      // "no glide", "120 ms", "1.50 s"
    tsVoices,     // "mono", "8"
    tsCents);     // "+-10.0 ct"

  TMz950ParamSpec = record
    Id: string;
    Name: string;
    Kind: TMz950ParamKind;
    Lo, Hi, Def: Single;       // plain values; a bool is 0..1, a choice 0..count - 1
    Skew: Single;              // JUCE's NormalisableRange skew; 1 = linear
    Cc: Integer;               // the CC the C++ hard-wires to it, -1 for none
    Text: TMz950TextStyle;
  end;

const
  // The parameters, by index (declaration order).
  PGain          = 0;
  PBendRange     = 1;
  PVcfCutoff     = 2;     // "VCF Filter"
  PVcfAmount     = 3;
  PVcaAttack     = 4;
  PVcaDecay      = 5;
  PVcaSustain    = 6;
  PVcaRelease    = 7;
  PVcfAttack     = 8;
  PVcfDecay      = 9;
  PVcfSustain    = 10;
  PVcfRelease    = 11;
  PLfoRate       = 12;
  PLfoDepth      = 13;    // "LFO Pitch Depth"
  PLfoDelay      = 14;
  PLfoToFilter   = 15;    // "LFO Filter Depth"
  PLfoSync       = 16;
  PLfoSyncDiv    = 17;
  PLfoShape      = 18;
  PVelToFilter   = 19;    // "Vel Freq"
  PVelToLoudness = 20;
  PResonance     = 21;
  PGlide         = 22;
  PGlideTime     = 23;
  PVoices        = 24;    // "Polyphony"
  PWide          = 25;
  PWideDetune    = 26;
  PWideSpread    = 27;
  PWideOffset    = 28;

  NumParams = 29;

  // The C++'s trimControls: the parameters that land in the engine's trims, every block.
  NumTrims = 20;
  TrimParams: array[0..NumTrims - 1] of Integer = (
    PVcfCutoff, PVcfAmount, PVcaAttack, PVcaDecay, PVcaSustain, PVcaRelease,
    PVcfAttack, PVcfDecay, PVcfSustain, PVcfRelease,
    PLfoRate, PLfoDepth, PLfoDelay, PVelToFilter, PVelToLoudness,
    PResonance, PLfoShape, PLfoToFilter, PLfoSync, PLfoSyncDiv);

  LfoShapeNames: array[0..3] of string = ('Sine', 'Saw', 'Square', 'S&H');

  Specs: array[0..NumParams - 1] of TMz950ParamSpec = (
    (Id: 'gain';          Name: 'Gain';              Kind: mkFloat;  Lo: 0;   Hi: 2;    Def: 0.7; Skew: 0.5; Cc: -1;  Text: tsGain),
    (Id: 'bendRange';     Name: 'Bend Range';        Kind: mkInt;    Lo: 1;   Hi: 12;   Def: 2;   Skew: 1;   Cc: -1;  Text: tsSemitones),
    (Id: 'vcfCutoff';     Name: 'VCF Filter';        Kind: mkFloat;  Lo: -99; Hi: 99;   Def: 0;   Skew: 1;   Cc: 74;  Text: tsOffset),
    (Id: 'vcfAmount';     Name: 'VCF Amnt';          Kind: mkFloat;  Lo: -50; Hi: 50;   Def: 0;   Skew: 1;   Cc: 70;  Text: tsOffset),
    (Id: 'vcaAttack';     Name: 'VCA Attack';        Kind: mkFloat;  Lo: -99; Hi: 99;   Def: 0;   Skew: 1;   Cc: 73;  Text: tsOffset),
    (Id: 'vcaDecay';      Name: 'VCA Decay';         Kind: mkFloat;  Lo: -99; Hi: 99;   Def: 0;   Skew: 1;   Cc: 75;  Text: tsOffset),
    (Id: 'vcaSustain';    Name: 'VCA Sustain';       Kind: mkFloat;  Lo: -99; Hi: 99;   Def: 0;   Skew: 1;   Cc: 79;  Text: tsOffset),
    (Id: 'vcaRelease';    Name: 'VCA Release';       Kind: mkFloat;  Lo: -99; Hi: 99;   Def: 0;   Skew: 1;   Cc: 72;  Text: tsOffset),
    (Id: 'vcfAttack';     Name: 'VCF Attack';        Kind: mkFloat;  Lo: -99; Hi: 99;   Def: 0;   Skew: 1;   Cc: 102; Text: tsOffset),
    (Id: 'vcfDecay';      Name: 'VCF Decay';         Kind: mkFloat;  Lo: -99; Hi: 99;   Def: 0;   Skew: 1;   Cc: 103; Text: tsOffset),
    (Id: 'vcfSustain';    Name: 'VCF Sustain';       Kind: mkFloat;  Lo: -99; Hi: 99;   Def: 0;   Skew: 1;   Cc: 104; Text: tsOffset),
    (Id: 'vcfRelease';    Name: 'VCF Release';       Kind: mkFloat;  Lo: -99; Hi: 99;   Def: 0;   Skew: 1;   Cc: 105; Text: tsOffset),
    (Id: 'lfoRate';       Name: 'LFO Rate';          Kind: mkFloat;  Lo: -99; Hi: 99;   Def: 0;   Skew: 1;   Cc: 76;  Text: tsRate),
    (Id: 'lfoDepth';      Name: 'LFO Pitch Depth';   Kind: mkFloat;  Lo: 0;   Hi: 99;   Def: 0;   Skew: 1;   Cc: 77;  Text: tsOffset),
    (Id: 'lfoDelay';      Name: 'LFO Delay';         Kind: mkFloat;  Lo: -99; Hi: 99;   Def: 0;   Skew: 1;   Cc: 78;  Text: tsOffset),
    (Id: 'lfoToFilter';   Name: 'LFO Filter Depth';  Kind: mkFloat;  Lo: 0;   Hi: 99;   Def: 0;   Skew: 1;   Cc: 114; Text: tsOffset),
    (Id: 'lfoSync';       Name: 'LFO Sync';          Kind: mkBool;   Lo: 0;   Hi: 1;    Def: 0;   Skew: 1;   Cc: 115; Text: tsDefault),
    (Id: 'lfoSyncDiv';    Name: 'LFO Sync Division'; Kind: mkChoice; Lo: 0;   Hi: 14;   Def: 8;   Skew: 1;   Cc: 116; Text: tsDefault),
    (Id: 'lfoShape';      Name: 'LFO Shape';         Kind: mkChoice; Lo: 0;   Hi: 3;    Def: 0;   Skew: 1;   Cc: 113; Text: tsDefault),
    (Id: 'velToFilter';   Name: 'Vel Freq';          Kind: mkFloat;  Lo: 0;   Hi: 99;   Def: 0;   Skew: 1;   Cc: 109; Text: tsOffset),
    (Id: 'velToLoudness'; Name: 'Vel Loudness';      Kind: mkFloat;  Lo: 0;   Hi: 99;   Def: 0;   Skew: 1;   Cc: 112; Text: tsOffset),
    (Id: 'resonance';     Name: 'VCF Resonance';     Kind: mkFloat;  Lo: 0;   Hi: 100;  Def: 0;   Skew: 1;   Cc: 71;  Text: tsPercent),
    (Id: 'glide';         Name: 'Glide';             Kind: mkBool;   Lo: 0;   Hi: 1;    Def: 0;   Skew: 1;   Cc: 65;  Text: tsDefault),
    (Id: 'glideTime';     Name: 'Glide Time';        Kind: mkFloat;  Lo: 0;   Hi: 3000; Def: 120; Skew: 0.4; Cc: 5;   Text: tsGlide),
    (Id: 'voices';        Name: 'Polyphony';         Kind: mkInt;    Lo: 1;   Hi: 8;    Def: 8;   Skew: 1;   Cc: 106; Text: tsVoices),
    (Id: 'wide';          Name: 'Wide';              Kind: mkBool;   Lo: 0;   Hi: 1;    Def: 0;   Skew: 1;   Cc: 107; Text: tsDefault),
    (Id: 'wideDetune';    Name: 'Wide Detune';       Kind: mkFloat;  Lo: 0;   Hi: 50;   Def: 10;  Skew: 1;   Cc: 108; Text: tsCents),
    (Id: 'wideSpread';    Name: 'Wide Spread';       Kind: mkFloat;  Lo: 0;   Hi: 100;  Def: 70;  Skew: 1;   Cc: 110; Text: tsPercent),
    (Id: 'wideOffset';    Name: 'Wide Offset';       Kind: mkBool;   Lo: 0;   Hi: 1;    Def: 1;   Skew: 1;   Cc: 111; Text: tsDefault)
  );

// -1 if none.
function IndexOfId(const Id: string): Integer;

// A parameter's default, plain.
function DefaultValue(Index: Integer): Single;

// A choice parameter's choices, in order (empty for the other kinds).
function ChoiceNames(Index: Integer): TArray<string>;

// CCs MIDI learn will take: not bank select (0, 32), not the mod wheel (1, which plays the
// engine's LFO), not the channel mode messages (120 up, of which 120 and 123 silence the
// engine). Every default CC in Specs passes.
function Learnable(Cc: Integer): Boolean;

// JUCE's NormalisableRange<float>::convertFrom0to1, with the C++ range's skew and the
// whole-number snap of an int, bool or choice parameter: what a parameter becomes when
// set to Normalised (0..1). And back (convertTo0to1).
function NormalisedToPlain(Index: Integer; Normalised: Single): Single;
function PlainToNormalised(Index: Integer; Plain: Single): Single;

// What a CC value (0..127) sets a parameter to, exactly as the C++ does it: applyController's
// jlimit (0, 1, value / 127) through the parameter's range, applySwitch's 64-and-up for a
// switch, and CC 106's eight equal bands of sixteen for the voice count.
function CcToValue(Index, CcValue: Integer): Single;

// A value as the C++ shows it. False for a switch or a choice, which read as the host
// shows them (On/Off, the choice's name).
function FormatValue(Index: Integer; V: Single; out Text: string): Boolean;

implementation

uses
  SysUtils, S950Math, S950Voice;

function IndexOfId(const Id: string): Integer;
var
  I: Integer;
begin
  for I := 0 to NumParams - 1 do
    if Specs[I].Id = Id then
    begin
      Result := I;
      Exit;
    end;
  Result := -1;
end;

function DefaultValue(Index: Integer): Single;
begin
  if (Index >= 0) and (Index < NumParams) then
    Result := Specs[Index].Def
  else
    Result := 0;
end;

function ChoiceNames(Index: Integer): TArray<string>;
var
  I: Integer;
begin
  Result := nil;
  case Index of
    PLfoSyncDiv:
      begin
        SetLength(Result, LfoNumDivisions);
        for I := 0 to LfoNumDivisions - 1 do
          Result[I] := LfoDivisions[I].Name;
      end;
    PLfoShape:
      begin
        SetLength(Result, Length(LfoShapeNames));
        for I := 0 to High(LfoShapeNames) do
          Result[I] := LfoShapeNames[I];
      end;
  end;
end;

function Learnable(Cc: Integer): Boolean;
begin
  Result := (Cc >= 2) and (Cc < 120) and (Cc <> 32);
end;

function NormalisedToPlain(Index: Integer; Normalised: Single): Single;
var
  P, Span, V: Single;
begin
  Result := 0;
  if (Index < 0) or (Index >= NumParams) then
    Exit;
  P := Normalised;
  if not (P > 0) then P := 0;      // NaN too
  if P > 1 then P := 1;
  with Specs[Index] do
  begin
    // convertFrom0to1: the skew, in float, as NormalisableRange<float> has it
    if (Skew <> 1) and (P > 0) then
      P := ExpD(LogD(P) / Skew);
    Span := Hi - Lo;
    V := Lo + Span * P;
    // snapToLegalValue: an interval of 1 for the whole-number kinds
    if Kind <> mkFloat then
      V := Lo + FloorD(V - Lo + 0.5);
    if V < Lo then V := Lo;
    if V > Hi then V := Hi;
  end;
  Result := V;
end;

function PlainToNormalised(Index: Integer; Plain: Single): Single;
var
  P: Double;
begin
  Result := 0;
  if (Index < 0) or (Index >= NumParams) then
    Exit;
  with Specs[Index] do
  begin
    if not (Hi > Lo) then
      Exit;
    P := (Plain - Lo) / (Hi - Lo);
    if not (P > 0) then P := 0;
    if P > 1 then P := 1;
    if (Skew <> 1) and (P > 0) then
      P := ExpD(LogD(P) * Skew);
  end;
  Result := P;
end;

function CcToValue(Index, CcValue: Integer): Single;
var
  Normalised: Single;
begin
  Result := 0;
  if (Index < 0) or (Index >= NumParams) then
    Exit;
  if CcValue < 0 then CcValue := 0;
  if CcValue > 127 then CcValue := 127;

  // CC 106: 1 + value * Polyphony / 128, whole bands rather than the parameter's rounding
  if Index = PVoices then
  begin
    Result := 1 + CcValue * 8 div 128;
    Exit;
  end;

  // applySwitch (glide, wide, wideOffset): 64 and up is on
  if Specs[Index].Kind = mkBool then
  begin
    if CcValue >= 64 then Result := 1 else Result := 0;
    Exit;
  end;

  Normalised := CcValue;
  Normalised := Normalised / 127;
  Result := NormalisedToPlain(Index, Normalised);
end;

function Fixed(V: Double; Places: Integer): string;
begin
  // Str is locale-independent: always a point, as juce::String (v, places) has it.
  Str(V:0:Places, Result);
end;

// The two non-ASCII signs, as UTF-8 (FPC's string is UTF-8 in the plug-in: see JucePlugin).
function TimesSign: string;
begin
  {$IFDEF FPC}
  Result := #$C3#$97;
  {$ELSE}
  Result := #$00D7;
  {$ENDIF}
end;

function PlusMinusSign: string;
begin
  {$IFDEF FPC}
  Result := #$C2#$B1;
  {$ELSE}
  Result := #$00B1;
  {$ENDIF}
end;

function FormatValue(Index: Integer; V: Single; out Text: string): Boolean;
var
  Octaves, Times: Double;
  I: Integer;
  Seconds: Single;
begin
  Text := '';
  Result := False;
  if (Index < 0) or (Index >= NumParams) then
    Exit;
  Result := True;
  case Specs[Index].Text of
    tsGain:
      Text := Fixed(V, 2);
    tsSemitones:
      begin
        I := Round(V);
        if I = 1 then
          Text := IntToStr(I) + ' semitone'
        else
          Text := IntToStr(I) + ' semitones';
      end;
    tsOffset:
      if V >= 0 then
        Text := '+' + IntToStr(Round(V))
      else
        Text := IntToStr(Round(V));
    tsRate:
      begin
        if V > 0 then
          Octaves := V / 99.0 * LfoRateOctavesUp
        else
          Octaves := V / 99.0 * LfoRateOctavesDown;
        Times := Exp2D(Octaves);
        if Times >= 10.0 then
          Text := TimesSign + IntToStr(Round(Times))
        else
          Text := TimesSign + Fixed(Times, 2);
      end;
    tsPercent:
      Text := IntToStr(Round(V)) + '%';
    tsGlide:
      // Under half a millisecond the voice does not glide at all, so say so.
      if V <= 0.5 then
        Text := 'no glide'
      else if V < 1000 then
        Text := IntToStr(Round(V)) + ' ms'
      else
      begin
        Seconds := V / 1000;
        Text := Fixed(Seconds, 2) + ' s';
      end;
    tsVoices:
      if Round(V) = 1 then
        Text := 'mono'
      else
        Text := IntToStr(Round(V));
    tsCents:
      Text := PlusMinusSign + Fixed(V, 1) + ' ct';
  else
    Result := False;
  end;
end;

end.
