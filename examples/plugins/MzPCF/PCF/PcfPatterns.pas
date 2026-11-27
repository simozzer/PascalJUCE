// MzPCF - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// PcfPatterns - the PCF's 32 patterns: the Object Pascal port of pcf::level, pcf::patterns
// and pcf::steps (Source/PCF/Pcf.h, Pcf.cpp). MzPCG and MzPCD play the same patterns, so a
// pattern number means the same in all three.

unit PcfPatterns;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

const
  PcfPatternCount = 32;   // pcf::patterns
  PcfStepCount = 16;      // pcf::steps

// A pattern's level on a step, 0 to 1. The pattern is clamped to 0..31; the step wraps
// round the 16, negative ones too.
function PcfLevel(Pattern, Step: Integer): Single;

// A pattern as the C++ table spells it, a hex digit a step ('' outside 0..31).
function PcfPatternText(Pattern: Integer): string;

implementation

const
  //
  // Thirty-two rhythms for the filter, a hex digit a step, 0 to f: the plain ones first -
  // every beat, every off-beat, every step - then ramps, then broken ones. The same as the
  // rack's (MzDebirth), so a pattern number means the same in both.
  //
  Table: array[0..PcfPatternCount - 1] of string[PcfStepCount] = (
    'f000f000f000f000', 'f0f0f0f0f0f0f0f0', 'ffffffffffffffff', '0f0f0f0f0f0f0f0f',
    '00f000f000f000f0', 'f8f8f8f8f8f8f8f8', 'ff00ff00ff00ff00', 'f00ff00ff00ff00f',
    'fc84fc84fc84fc84', '48cf48cf48cf48cf', 'fedcba9876543210', '0123456789abcdef',
    'fdb97531fdb97531', '13579bdf13579bdf', 'f0e0d0c0b0a09080', 'fa50fa50fa50fa50',
    'f00f00f00f00f0f0', 'f0080f008f00f080', 'f000000080000000', 'f0a0f0a0f0a0f05f',
    'f0c0f080f0c0f040', '8f8f8f8f8f8f8f8f', 'f000f000f0f0f0ff', 'fff0fff0fff0fff0',
    'f08cf08cf08cf08c', '0f800f800f800f80', 'f9e2f9e2f9e2f9e2', 'f0f00ff0f0f00f0f',
    'f00000f000f00000', 'f000f0f0f000f00f', 'c0f0c0f0c0f0c0ff', 'f0f0f0f0ffffffff'
  );

function PcfLevel(Pattern, Step: Integer): Single;
var
  P, S, V: Integer;
  C: AnsiChar;
  F: Single;
begin
  P := Pattern;                         // std::clamp(pattern, 0, patterns - 1)
  if P < 0 then
    P := 0
  else if P > PcfPatternCount - 1 then
    P := PcfPatternCount - 1;
  S := ((Step mod PcfStepCount) + PcfStepCount) mod PcfStepCount;
  C := Table[P][S + 1];
  if C >= 'a' then
    V := Ord(C) - Ord('a') + 10
  else
    V := Ord(C) - Ord('0');
  F := V;                               // (float) v
  Result := F / 15;
end;

function PcfPatternText(Pattern: Integer): string;
begin
  if (Pattern >= 0) and (Pattern < PcfPatternCount) then
    Result := string(Table[Pattern])
  else
    Result := '';
end;

end.
