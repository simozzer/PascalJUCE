// MzPCF - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/Params.h and Params.cpp.

unit MzPcfParams;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  PcfEngine;

type
  // What a control is: a knob (min to max), a switch with choices, or a number (min to max).
  TSpecKind = (skKnob, skChoice, skNumber);

  //
  // One row per front-panel control: its parameter ID, the name a host shows, and the
  // field of TPcfSettings it drives (see SettingsFromValues). The declarations, the reader
  // and the panel all work from this, so a control cannot exist in one and be missing from
  // another.
  //
  // IDs are saved in every host project. Never rename one. They are the C++ plug-in's IDs.
  //
  TSpec = record
    Id: string;
    Name: string;
    Legend: string;     // as printed on the panel
    Hint: string;       // what it does, for the hover hint
    Kind: TSpecKind;
    Choices: string;    // a switch's positions, '|' separated
    Min, Max: Single;
    Units: string;      // how a knob's value reads: '' for 0 to 100, '%' or 'dB'
  end;

const
  // Index of each control, which is also its parameter index in the plug-in.
  PPattern = 0;
  PFreq = 1;
  PQ = 2;
  PAmount = 3;
  PDecay = 4;
  PMode = 5;
  PMix = 6;
  PLevel = 7;

  NumSpecs = 8;
  NumParams = NumSpecs;

  Specs: array[0..NumSpecs - 1] of TSpec = (
    (Id: 'pattern'; Name: 'Pattern'; Legend: 'PATTERN';
     Hint: 'Which of the 32 patterns plays the filter: on each sixteenth it is opened by that step''s level. Drag up or down, or use the wheel.';
     Kind: skNumber; Choices: ''; Min: 1; Max: 32; Units: ''),
    (Id: 'freq'; Name: 'Frequency'; Legend: 'FREQ';
     Hint: 'Where the filter rests between strikes, 40 Hz to 10 kHz.';
     Kind: skKnob; Choices: ''; Min: 0; Max: 1; Units: ''),
    (Id: 'q'; Name: 'Resonance'; Legend: 'Q';
     Hint: 'Resonance: a peak at the cutoff, up to a whistle as the pattern sweeps it.';
     Kind: skKnob; Choices: ''; Min: 0; Max: 1; Units: ''),
    (Id: 'amount'; Name: 'Amount'; Legend: 'AMT';
     Hint: 'How far a full-level step opens the filter above FREQ, up to seven octaves.';
     Kind: skKnob; Choices: ''; Min: 0; Max: 1; Units: ''),
    (Id: 'decay'; Name: 'Decay'; Legend: 'DEC';
     Hint: 'How fast the filter closes again after each strike, 15 ms to 1.5 s.';
     Kind: skKnob; Choices: ''; Min: 0; Max: 1; Units: ''),
    (Id: 'mode'; Name: 'Mode'; Legend: 'MODE';
     Hint: 'Low-pass (LP), or band-pass (BP) for a thinner, wah-like sweep.';
     Kind: skChoice; Choices: 'LP|BP'; Min: 0; Max: 1; Units: ''),
    (Id: 'mix'; Name: 'Mix'; Legend: 'MIX';
     Hint: 'How much of the sound goes through the filter: 0% is dry, 100% all filtered. Not on the original.';
     Kind: skKnob; Choices: ''; Min: 0; Max: 1; Units: '%'),
    (Id: 'level'; Name: 'Level'; Legend: 'LEVEL';
     Hint: 'Output level, -24 to +12 dB, to make up what the filter takes away. Not on the original.';
     Kind: skKnob; Choices: ''; Min: -24; Max: 12; Units: 'dB')
  );

// -1 if none
function IndexOfId(const Id: string): Integer;

// A control's default as its parameter holds it (the pattern 1 to 32, as the C++
// AudioParameterInt shows it from min).
function DefaultValue(Index: Integer): Single;

// juce::roundToInt: to nearest, halves to even.
function RoundToInt(V: Single): Integer;

// Every control's parameter value into settings, as the C++ params::Reader does it.
// Values holds at least NumSpecs entries.
function SettingsFromValues(const Values: array of Single): TPcfSettings;

// A knob's value text, as the C++ parameter shows it: '35', '100%', '+1.5 dB'. '' for a
// switch or a number (the host's own text: the choice's name, the number).
function FormatValue(Index: Integer; V: Single): string;

// The hover hint: the name in capitals, then what it does.
function HintFor(Index: Integer): string;

implementation

uses
  SysUtils;

function IndexOfId(const Id: string): Integer;
var
  I: Integer;
begin
  for I := 0 to NumSpecs - 1 do
    if Specs[I].Id = Id then
      Exit(I);
  Result := -1;
end;

function DefaultValue(Index: Integer): Single;
var
  D: TPcfSettings;
begin
  D := TPcfSettings.Defaults;
  case Index of
    PPattern: Result := D.Pattern + Specs[PPattern].Min;
    PFreq: Result := D.Freq;
    PQ: Result := D.Q;
    PAmount: Result := D.Amount;
    PDecay: Result := D.Decay;
    PMode: Result := D.Mode;
    PMix: Result := D.Mix;
    PLevel: Result := D.Level;
  else
    Result := 0;
  end;
end;

function RoundToInt(V: Single): Integer;
var
  D: Double;
begin
  D := V;
  Result := Round(D);   // the SSE conversion: to nearest, halves to even, as JUCE's
end;

function SettingsFromValues(const Values: array of Single): TPcfSettings;

  function V(I: Integer): Single;
  begin
    if I <= High(Values) then
      Result := Values[I]
    else
      Result := DefaultValue(I);
  end;

begin
  Result := TPcfSettings.Defaults;
  Result.Pattern := RoundToInt(V(PPattern)) - Round(Specs[PPattern].Min);
  Result.Freq := V(PFreq);
  Result.Q := V(PQ);
  Result.Amount := V(PAmount);
  Result.Decay := V(PDecay);
  Result.Mode := RoundToInt(V(PMode));
  Result.Mix := V(PMix);
  Result.Level := V(PLevel);
end;

function FormatValue(Index: Integer; V: Single): string;
var
  Hundred: Single;
  Text: string;
begin
  Result := '';
  if (Index < 0) or (Index >= NumSpecs) or (Specs[Index].Kind <> skKnob) then
    Exit;
  if Specs[Index].Units = 'dB' then
  begin
    // juce::String(v, 1): always a point; Str is locale-independent
    Str(V:0:1, Text);
    if V > 0 then
      Text := '+' + Text;
    Result := Text + ' dB';
  end
  else
  begin
    Hundred := V * 100;
    Result := IntToStr(RoundToInt(Hundred));
    if Specs[Index].Units = '%' then
      Result := Result + '%';
  end;
end;

function HintFor(Index: Integer): string;
begin
  if (Index < 0) or (Index >= NumSpecs) then
    Result := ''
  else
    Result := UpperCase(Specs[Index].Name) + #10 + Specs[Index].Hint;
end;

end.
