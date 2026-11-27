// MzPCG - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/Params.h and Params.cpp.

unit MzPcgParams;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  PcgEngine;

type
  // What a control is: a knob (min to max), a switch with choices, or a number (min to max).
  TSpecKind = (skKnob, skChoice, skNumber);

  // How a knob's value reads (params::Unit).
  TSpecUnit = (suPlain, suPercent, suDecibels, suAttack, suDecay);

  //
  // One row per front-panel control: its parameter ID, the name a host shows, and the
  // field of TPcgSettings it drives (see SettingsFromValues). The declarations, the reader
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
  PMode = 1;
  PRate = 2;
  PDepth = 3;
  PAttack = 4;
  PHold = 5;
  PDecay = 6;
  PMix = 7;
  PLevel = 8;

  NumSpecs = 9;
  NumParams = NumSpecs;

  Specs: array[0..NumSpecs - 1] of TSpec = (
    (Id: 'pattern'; Name: 'Pattern'; Legend: 'PATTERN';
     Hint: 'Which of the 32 patterns plays the gain - the PCF''s: on each step the gain is struck to that step''s level. Drag up or down, or use the wheel.';
     Kind: skNumber; Choices: ''; Min: 1; Max: 32; Units: suPlain),
    (Id: 'mode'; Name: 'Mode'; Legend: 'MODE';
     Hint: 'GATE: each step opens the sound, as a trance gate. DUCK: each step pushes the sound down and it comes back, as a sidechain pump.';
     Kind: skChoice; Choices: 'GATE|DUCK'; Min: 0; Max: 1; Units: suPlain),
    (Id: 'rate'; Name: 'Rate'; Legend: 'RATE';
     Hint: 'How long a step is: an eighth, a sixteenth or a thirty-second note. The pattern''s sixteen steps run that fast.';
     Kind: skChoice; Choices: '1/8|1/16|1/32'; Min: 0; Max: 2; Units: suPlain),
    (Id: 'depth'; Name: 'Depth'; Legend: 'DEPTH';
     Hint: 'How far the gain goes: at 0 the sound is left alone, at 100 a gate shuts to silence and a duck pushes all the way down.';
     Kind: skKnob; Choices: ''; Min: 0; Max: 1; Units: suPlain),
    (Id: 'attack'; Name: 'Attack'; Legend: 'ATK';
     Hint: 'How fast a step takes hold, 0.5 to 50 ms. Never so fast it clicks; slow, it swells.';
     Kind: skKnob; Choices: ''; Min: 0; Max: 1; Units: suAttack),
    (Id: 'hold'; Name: 'Hold'; Legend: 'HOLD';
     Hint: 'How much of the step the gain holds where the step put it, before letting go: none of it, a pluck; all of it, a square gate.';
     Kind: skKnob; Choices: ''; Min: 0; Max: 1; Units: suPercent),
    (Id: 'decay'; Name: 'Decay'; Legend: 'DEC';
     Hint: 'Then how fast it lets go, 5 ms to 1.5 s.';
     Kind: skKnob; Choices: ''; Min: 0; Max: 1; Units: suDecay),
    (Id: 'mix'; Name: 'Mix'; Legend: 'MIX';
     Hint: 'How much of the sound goes through the gain: 0% is dry, 100% all of it.';
     Kind: skKnob; Choices: ''; Min: 0; Max: 1; Units: suPercent),
    (Id: 'level'; Name: 'Level'; Legend: 'LEVEL';
     Hint: 'Output level, -24 to +12 dB, to make up what the gating takes away.';
     Kind: skKnob; Choices: ''; Min: -24; Max: 12; Units: suDecibels)
  );

// -1 if none
function IndexOfId(const Id: string): Integer;

// A control's default as its parameter holds it (the pattern 1 to 32, as the C++
// AudioParameterInt shows it from min; a switch's position).
function DefaultValue(Index: Integer): Single;

// juce::roundToInt: to nearest, halves to even.
function RoundToInt(V: Single): Integer;

// Every control's parameter value into settings, as the C++ params::Reader does it.
// Values holds at least NumSpecs entries.
function SettingsFromValues(const Values: array of Single): TPcgSettings;

// A knob's value text, as the C++ parameter shows it: '100', '50%', '+1.5 dB', '1.3 ms',
// '19.9054 ms', '1.50 s'. '' for a switch or a number (the host's own text: the choice's
// name, the number).
function FormatValue(Index: Integer; V: Single): string;

// juce::String(X, Decimals): Decimals > 0, as printf's %.*f (exactly rounded, halves to
// even); 0, as a C++ stream's default (%g, six significant digits).
function JuceNumberText(X: Double; Decimals: Integer): string;

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
  D: TPcgSettings;
begin
  D := TPcgSettings.Defaults;
  case Index of
    PPattern: Result := D.Pattern + Specs[PPattern].Min;
    PMode: Result := D.Mode;
    PRate: Result := D.Rate;
    PDepth: Result := D.Depth;
    PAttack: Result := D.Attack;
    PHold: Result := D.Hold;
    PDecay: Result := D.Decay;
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

function SettingsFromValues(const Values: array of Single): TPcgSettings;

  function V(I: Integer): Single;
  begin
    if I <= High(Values) then
      Result := Values[I]
    else
      Result := DefaultValue(I);
  end;

begin
  Result := TPcgSettings.Defaults;
  Result.Pattern := RoundToInt(V(PPattern)) - Round(Specs[PPattern].Min);
  Result.Mode := RoundToInt(V(PMode));
  Result.Rate := RoundToInt(V(PRate));
  Result.Depth := V(PDepth);
  Result.Attack := V(PAttack);
  Result.Hold := V(PHold);
  Result.Decay := V(PDecay);
  Result.Mix := V(PMix);
  Result.Level := V(PLevel);
end;

{ ---- juce::String of a double ---- }

// |X| to Decimals places, exactly: the double's own binary value, rounded once, halves to
// even (as the Universal CRT's printf). '' if out of the range this needs (|X| >= 2^53).
function FixedDigits(X: Double; Decimals: Integer): string;
var
  Bits: UInt64;
  Exponent, Shift, I: Integer;
  Mantissa, IntPart, Frac, Half, Mask: UInt64;
  Sticky, Up: Boolean;
  Digits: array of Integer;
  S: string;
begin
  Move(X, Bits, SizeOf(Bits));
  Exponent := Integer((Bits shr 52) and $7FF);
  Mantissa := Bits and ((UInt64(1) shl 52) - 1);
  if Exponent = $7FF then
    Exit('');
  if Exponent = 0 then
    Exponent := 1                                  // subnormal
  else
    Mantissa := Mantissa or (UInt64(1) shl 52);
  // |X| = Mantissa * 2^(Exponent - 1075)
  Shift := 1075 - Exponent;                        // the binary places after the point
  Sticky := False;
  if Shift <= 0 then
  begin
    if -Shift > 10 then
      Exit('');
    IntPart := Mantissa shl (-Shift);
    Frac := 0;
    Shift := 0;
  end
  else
  begin
    // keep at most 59 binary places, so that Frac * 10 fits; what falls off only says
    // whether there was more (for the half-way test)
    if Shift > 59 then
    begin
      if Shift - 59 >= 64 then
      begin
        Sticky := Mantissa <> 0;
        Mantissa := 0;
      end
      else
      begin
        Sticky := (Mantissa and ((UInt64(1) shl (Shift - 59)) - 1)) <> 0;
        Mantissa := Mantissa shr (Shift - 59);
      end;
      Shift := 59;
    end;
    IntPart := Mantissa shr Shift;
    Frac := Mantissa and ((UInt64(1) shl Shift) - 1);
  end;

  SetLength(Digits, Decimals);
  if Shift > 0 then
    Mask := (UInt64(1) shl Shift) - 1
  else
    Mask := 0;
  for I := 0 to Decimals - 1 do
  begin
    if Shift > 0 then
    begin
      Frac := Frac * 10;
      Digits[I] := Integer(Frac shr Shift);
      Frac := Frac and Mask;
    end
    else
      Digits[I] := 0;
  end;

  // round what is left: above half up, half (exactly) to even
  if Shift > 0 then
  begin
    Half := UInt64(1) shl (Shift - 1);
    if Frac > Half then
      Up := True
    else if Frac < Half then
      Up := False
    else if Sticky then
      Up := True
    else if Decimals > 0 then
      Up := Odd(Digits[Decimals - 1])
    else
      Up := Odd(IntPart);
  end
  else
    Up := False;

  if Up then
  begin
    I := Decimals - 1;
    while I >= 0 do
    begin
      Inc(Digits[I]);
      if Digits[I] < 10 then
        Break;
      Digits[I] := 0;
      Dec(I);
    end;
    if I < 0 then
      Inc(IntPart);
  end;

  S := IntToStr(IntPart);
  if Decimals > 0 then
  begin
    S := S + '.';
    for I := 0 to Decimals - 1 do
      S := S + Char(Ord('0') + Digits[I]);
  end;
  Result := S;
end;

// The decimal exponent of the first significant digit of a number written out ('0012.5'
// gives 1, '0.0034' gives -3); -999 if it is all zeros.
function LeadingExponent(const S: string): Integer;
var
  I, Point, First: Integer;
begin
  Point := Pos('.', S);
  if Point = 0 then
    Point := Length(S) + 1;
  First := 0;
  for I := 1 to Length(S) do
    if (S[I] >= '1') and (S[I] <= '9') then
    begin
      First := I;
      Break;
    end;
  if First = 0 then
    Result := -999
  else if First < Point then
    Result := Point - First - 1
  else
    Result := Point - First;
end;

function JuceNumberText(X: Double; Decimals: Integer): string;
var
  A, P: Double;
  E: Integer;
  Neg: Boolean;
begin
  if X <> X then
    Exit('nan');
  Neg := (X < 0) or ((X = 0) and (1 / X < 0));
  A := Abs(X);
  Result := '';
  if Decimals > 0 then
    Result := FixedDigits(A, Decimals)
  else if A = 0 then
    Result := '0'
  else if (A >= 1.0e-4) and (A < 1.0e5) then
  begin
    // %g, six significant digits: %f to 5 - E places, E the decimal exponent of the
    // value as rounded to six digits; then no trailing zeros, nor a bare point
    E := 0;
    P := 1;
    while A >= P * 10 do
    begin
      Inc(E);
      P := P * 10;
    end;
    while A < P do
    begin
      Dec(E);
      P := P / 10;
    end;
    Result := FixedDigits(A, 5 - E);
    if LeadingExponent(Result) > E then
      Result := FixedDigits(A, 5 - LeadingExponent(Result));
    if Pos('.', Result) > 0 then
    begin
      while Result[Length(Result)] = '0' do
        SetLength(Result, Length(Result) - 1);
      if Result[Length(Result)] = '.' then
        SetLength(Result, Length(Result) - 1);
    end;
  end;
  if Result = '' then
    Exit(FloatToStrF(X, ffGeneral, 6, 0, DefaultFormatSettings));   // out of the range used here
  if Neg then
    Result := '-' + Result;
end;

function Milliseconds(Seconds: Double): string;
begin
  // seconds < 1.0 ? juce::String(seconds * 1000.0, seconds < 0.01 ? 1 : 0) + " ms"
  //               : juce::String(seconds, 2) + " s"
  if Seconds < 1.0 then
  begin
    if Seconds < 0.01 then
      Result := JuceNumberText(Seconds * 1000.0, 1) + ' ms'
    else
      Result := JuceNumberText(Seconds * 1000.0, 0) + ' ms';
  end
  else
    Result := JuceNumberText(Seconds, 2) + ' s';
end;

function FormatValue(Index: Integer; V: Single): string;
const
  AttackShortest: Double = 0.0005;
  DecayShortest: Double = 0.005;
var
  Hundred: Single;
  D: Double;
begin
  Result := '';
  if (Index < 0) or (Index >= NumSpecs) or (Specs[Index].Kind <> skKnob) then
    Exit;
  D := V;
  case Specs[Index].Units of
    suDecibels:
      begin
        Result := JuceNumberText(D, 1) + ' dB';
        if V > 0 then
          Result := '+' + Result;
      end;
    suPercent:
      begin
        Hundred := V * 100;
        Result := IntToStr(RoundToInt(Hundred)) + '%';
      end;
    suAttack:
      Result := Milliseconds(AttackShortest * PowD(100.0, D));
    suDecay:
      Result := Milliseconds(DecayShortest * PowD(300.0, D));
  else
    begin
      Hundred := V * 100;
      Result := IntToStr(RoundToInt(Hundred));
    end;
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
