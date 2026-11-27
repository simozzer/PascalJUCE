// MzPCD - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/Params.h and Params.cpp.

unit MzPcdParams;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  PcdEngine;

type
  // What a control is: a knob (min to max), a switch with choices, or a number (min to max).
  TSpecKind = (skKnob, skChoice, skNumber);

  // How a knob's value reads (params::Unit).
  TSpecUnit = (suPlain, suPercent, suDecibels, suDrive, suPush, suTone, suBipolar, suDecay);

  //
  // One row per front-panel control: its parameter ID, the name a host shows, and the
  // field of TPcdSettings it drives (see SettingsFromValues). The declarations, the reader
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
    Units: TSpecUnit;
  end;

const
  // Index of each control, which is also its parameter index in the plug-in.
  PPattern = 0;
  PRate = 1;
  PDrive = 2;
  PShape = 3;
  PTone = 4;
  PFeedback = 5;
  PDriveAmount = 6;
  PToneAmount = 7;
  PFeedbackAmount = 8;
  PDecay = 9;
  PMix = 10;
  PLevel = 11;

  NumSpecs = 12;
  NumParams = NumSpecs;

  Specs: array[0..NumSpecs - 1] of TSpec = (
    (Id: 'pattern'; Name: 'Pattern'; Legend: 'PATTERN';
     Hint: 'Which of the 32 patterns plays the distortion - the PCF''s: on each step it pushes the drive, the tone and the feedback, by that step''s level. Drag up or down, or use the wheel.';
     Kind: skNumber; Choices: ''; Min: 1; Max: 32; Units: suPlain),
    (Id: 'rate'; Name: 'Rate'; Legend: 'RATE';
     Hint: 'How long a step is: an eighth, a sixteenth or a thirty-second note. The pattern''s sixteen steps run that fast.';
     Kind: skChoice; Choices: '1/8|1/16|1/32'; Min: 0; Max: 2; Units: suPlain),

    (Id: 'drive'; Name: 'Drive'; Legend: 'DRIVE';
     Hint: 'How hard the sound is driven into the distortion - ReBirth''s, and its AMOUNT, 0 to 127: it starts at 70, as ReBirth''s did.';
     Kind: skKnob; Choices: ''; Min: 0; Max: 1; Units: suDrive),
    (Id: 'shape'; Name: 'Shape'; Legend: 'SHAPE';
     Hint: 'The distortion''s curve - ReBirth''s SHAPE, 0 to 127: 0 a hard clip, as ReBirth 1.5''s, and up from there ever further round its waveshaper.';
     Kind: skKnob; Choices: ''; Min: 0; Max: 1; Units: suDrive),
    (Id: 'tone'; Name: 'Tone'; Legend: 'TONE';
     Hint: 'Dark to bright: the cutoff after the clipper, 500 Hz to 12 kHz. It also sets the pitch the feedback howls at.';
     Kind: skKnob; Choices: ''; Min: 0; Max: 1; Units: suTone),
    (Id: 'feedback'; Name: 'Feedback'; Legend: 'FDBK';
     Hint: 'How much of the output comes round again, as a guitar amp''s does through the speaker and back into the pickup. Up high it sustains, then howls - but never runs away.';
     Kind: skKnob; Choices: ''; Min: 0; Max: 1; Units: suPlain),

    (Id: 'driveAmount'; Name: 'Pattern Drive'; Legend: 'DRIVE';
     Hint: 'How far a full-level step pushes the drive up, on top of DRIVE: by up to 127 more, as far as ReBirth''s AMOUNT goes.';
     Kind: skKnob; Choices: ''; Min: 0; Max: 1; Units: suPush),
    (Id: 'toneAmount'; Name: 'Pattern Tone'; Legend: 'TONE';
     Hint: 'How far a full-level step moves the tone: up to three octaves brighter, or - turned left - darker.';
     Kind: skKnob; Choices: ''; Min: -1; Max: 1; Units: suBipolar),
    (Id: 'feedbackAmount'; Name: 'Pattern Feedback'; Legend: 'FDBK';
     Hint: 'How far a full-level step pushes the feedback up, on top of FDBK - so the howl swells on the steps the pattern strikes.';
     Kind: skKnob; Choices: ''; Min: 0; Max: 1; Units: suPlain),
    (Id: 'decay'; Name: 'Pattern Decay'; Legend: 'DEC';
     Hint: 'How fast each step''s push dies away, 15 ms to 1.5 s.';
     Kind: skKnob; Choices: ''; Min: 0; Max: 1; Units: suDecay),

    (Id: 'mix'; Name: 'Mix'; Legend: 'MIX';
     Hint: 'How much of the sound goes through the distortion: 0% is dry, 100% all of it. The dry side is delayed to line up with the wet.';
     Kind: skKnob; Choices: ''; Min: 0; Max: 1; Units: suPercent),
    (Id: 'level'; Name: 'Level'; Legend: 'LEVEL';
     Hint: 'Output level, -24 to +12 dB.';
     Kind: skKnob; Choices: ''; Min: -24; Max: 12; Units: suDecibels)
  );

// -1 if none
function IndexOfId(const Id: string): Integer;

// A control's default as its parameter holds it (the pattern 1 to 32, as the C++
// AudioParameterInt shows it from min; the rate as its choice's index).
function DefaultValue(Index: Integer): Single;

// juce::roundToInt: to nearest, halves to even.
function RoundToInt(V: Double): Integer;

// Every control's parameter value into settings, as the C++ params::Reader does it.
// Values holds at least NumSpecs entries.
function SettingsFromValues(const Values: array of Single): TPcdSettings;

// A value as a unit shows it (Params.cpp's text): '70', '+64', '1.2 kHz', '-35', '350 ms',
// '100%', '+1.5 dB'.
function UnitText(AUnit: TSpecUnit; V: Single): string;

// A knob's value text, as the C++ parameter shows it. '' for a switch or a number (the
// host's own text: the choice's name, the number).
function FormatValue(Index: Integer; V: Single): string;

// The hover hint: the name in capitals, then what it does.
function HintFor(Index: Integer): string;

implementation

uses
  SysUtils, PcfMath;

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
  D: TPcdSettings;
begin
  D := TPcdSettings.Defaults;
  case Index of
    PPattern: Result := D.Pattern + Specs[PPattern].Min;
    PRate: Result := D.Rate;
    PDrive: Result := D.Drive;
    PShape: Result := D.Shape;
    PTone: Result := D.Tone;
    PFeedback: Result := D.Feedback;
    PDriveAmount: Result := D.DriveAmount;
    PToneAmount: Result := D.ToneAmount;
    PFeedbackAmount: Result := D.FeedbackAmount;
    PDecay: Result := D.Decay;
    PMix: Result := D.Mix;
    PLevel: Result := D.Level;
  else
    Result := 0;
  end;
end;

function RoundToInt(V: Double): Integer;
begin
  Result := Round(V);   // the SSE conversion: to nearest, halves to even, as JUCE's
end;

function SettingsFromValues(const Values: array of Single): TPcdSettings;

  function V(I: Integer): Single;
  begin
    if I <= High(Values) then
      Result := Values[I]
    else
      Result := DefaultValue(I);
  end;

begin
  Result := TPcdSettings.Defaults;
  Result.Pattern := RoundToInt(V(PPattern)) - Round(Specs[PPattern].Min);
  Result.Rate := RoundToInt(V(PRate));
  Result.Drive := V(PDrive);
  Result.Shape := V(PShape);
  Result.Tone := V(PTone);
  Result.Feedback := V(PFeedback);
  Result.DriveAmount := V(PDriveAmount);
  Result.ToneAmount := V(PToneAmount);
  Result.FeedbackAmount := V(PFeedbackAmount);
  Result.Decay := V(PDecay);
  Result.Mix := V(PMix);
  Result.Level := V(PLevel);
end;

// juce::String (v, places): fixed, a point whatever the locale (Str is locale-independent).
// JUCE writes it through an ostream, that is the C library's printf, which rounds an exact
// tie - -17.25 to one place - to even (-17.2); Str rounds it away from zero (-17.3). So a
// tie is rounded here: V * 10^Places ends in exactly .5 only if V * 2^(Places + 1) is whole
// (and then M * 5^Places, below, is odd).
function Fixed(V: Double; Places: Integer): string;
var
  X: Double;
  M, Q: Int64;
  I: Integer;
  Digits: string;
begin
  Str(V:0:Places, Result);
  X := Abs(V);
  for I := 0 to Places do
    X := X * 2;   // exact
  if (X < 1.0e15) and (Frac(X) = 0) then
  begin
    M := Trunc(X);
    for I := 1 to Places do
      M := M * 5;   // M / 2 = |V| * 10^Places
    if Odd(M) then
    begin
      Q := M div 2;
      if Odd(Q) then
        Inc(Q);     // to even
      Digits := IntToStr(Q);
      while Length(Digits) <= Places do
        Digits := '0' + Digits;
      Result := Copy(Digits, 1, Length(Digits) - Places);
      if Places > 0 then
        Result := Result + '.' + Copy(Digits, Length(Digits) - Places + 1, Places);
      if V < 0 then
        Result := '-' + Result;
    end;
  end;
end;

function UnitText(AUnit: TSpecUnit; V: Single): string;
const
  Hundred: Single = 100;      // 100.0f
  Full: Single = 127;         // 127.0f
  ToneLow: Double = 500.0;
  DecayLow: Double = 0.015;
var
  F: Single;
  D, Hz, S: Double;
  P: Integer;
begin
  case AUnit of
    suDecibels:
      begin
        D := V;
        Result := Fixed(D, 1) + ' dB';
        if V > 0 then
          Result := '+' + Result;
      end;
    suPercent:
      begin
        F := V * Hundred;
        Result := IntToStr(RoundToInt(F)) + '%';
      end;
    suDrive:
      begin
        F := V * Full;   // ReBirth's 0 to 127
        Result := IntToStr(RoundToInt(F));
      end;
    suPush:
      begin
        F := V * Full;
        Result := '+' + IntToStr(RoundToInt(F));
      end;
    suTone:
      begin
        D := V;
        Hz := ToneLow * PowD(24.0, D);
        if Hz < 1000.0 then
          Result := IntToStr(RoundToInt(Hz)) + ' Hz'
        else
          Result := Fixed(Hz / 1000.0, 1) + ' kHz';
      end;
    suBipolar:
      begin
        F := V * Hundred;
        P := RoundToInt(F);
        Result := IntToStr(P);
        if P > 0 then
          Result := '+' + Result;
      end;
    suDecay:
      begin
        D := V;
        S := DecayLow * PowD(100.0, D);
        if S < 1.0 then
          Result := IntToStr(RoundToInt(S * 1000.0)) + ' ms'
        else
          Result := Fixed(S, 2) + ' s';
      end;
  else
    begin
      F := V * Hundred;
      Result := IntToStr(RoundToInt(F));
    end;
  end;
end;

function FormatValue(Index: Integer; V: Single): string;
begin
  Result := '';
  if (Index < 0) or (Index >= NumSpecs) or (Specs[Index].Kind <> skKnob) then
    Exit;
  Result := UnitText(Specs[Index].Units, V);
end;

function HintFor(Index: Integer): string;
begin
  if (Index < 0) or (Index >= NumSpecs) then
    Result := ''
  else
    Result := UpperCase(Specs[Index].Name) + #10 + Specs[Index].Hint;
end;

end.
