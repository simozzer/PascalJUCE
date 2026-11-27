// MzPCF - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// PcfMath - the few maths helpers the PCF units share (and MzPCG and MzPCD can use):
// the C library's float and double functions the C++ engine calls, std::clamp / min / max
// as the C++ standard library defines them, and an unchecked sample-array type.
//
// A NOTE ON PRECISION, for every Pcf* unit. The C++ engine works in float, with a few
// double sections (the clock, and the coefficients worked out from the sample rate). The
// port uses Single and Double in exactly the same places, so that it renders the same
// samples, bit for bit (verify/build_verify.cmd checks this against the original):
//
//   - A real literal that a Single cannot hold exactly (0.45, 0.015, ...) is declared as
//     a typed Single constant (C++'s 0.45f), so it does not drag the expression into
//     double. Exact ones (0.5, 8, 19.5) are fine as they are.
//   - The maths functions are the C library's own (expf, exp2f, powf, tanf, exp), called
//     through the wrappers below, as the C++ calls them. FPC's Exp, Power, Tan work in
//     double or extended and would differ from them in the last bit now and then.
//   - An integer on its way into float arithmetic is first assigned to a Single (or a
//     Double), as the C++ (float) / (double) cast; a double result going into float is
//     assigned to a Single (FPC has no Single(double) cast).
//   - C++ evaluates a + b * c + d left to right; so does Pascal, and the operands are kept
//     in the C++ order.
//
// Delphi: {$EXCESSPRECISION OFF} keeps Single arithmetic in single precision on Win64.

unit PcfMath;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

// Take the maths functions from the platform's C library, as the C++ engine does, so the
// port renders bit-identical samples. Undefine for FPC's own maths (within an ulp:
// inaudible, but no longer bit-identical).
{$DEFINE PCF_CRT_MATH}

interface

type
  // A run of samples (left or right), unchecked: the C++'s float*.
  TPcfSamples = array[0..(MaxInt div SizeOf(Single)) - 1] of Single;
  PPcfSamples = ^TPcfSamples;

// The C library's functions: expf, exp2f, powf, tanf (float) and exp, pow (double).
function ExpF(X: Single): Single; inline;
function Exp2F(X: Single): Single; inline;
function PowF(X, Y: Single): Single; inline;
function TanF(X: Single): Single; inline;
function ExpD(X: Double): Double; inline;
function PowD(X, Y: Double): Double; inline;

// std::clamp(v, lo, hi): lo if v < lo, hi if hi < v, else v (so NaN stays NaN).
function ClampF(V, Lo, Hi: Single): Single; inline;
function ClampI(V, Lo, Hi: Integer): Integer; inline;
// std::min(a, b) and std::max(a, b): b only if it is less (greater).
function MinF(A, B: Single): Single; inline;
function MaxF(A, B: Single): Single; inline;
function MinI(A, B: Integer): Integer; inline;
// std::floor of a double, exactly (the integer part, one lower below zero).
function FloorD(X: Double): Double;
// std::isfinite
function IsFiniteD(X: Double): Boolean; inline;

implementation

uses
  Math;

{$IFDEF PCF_CRT_MATH}

const
{$IFDEF MSWINDOWS}
  LibM = 'ucrtbase.dll';   // the Universal CRT: part of Windows 10 and later
{$ELSE}
  {$IFDEF DARWIN}
  LibM = '/usr/lib/libSystem.B.dylib';
  {$ELSE}
    {$IFDEF MACOS}
  LibM = '/usr/lib/libSystem.B.dylib';
    {$ELSE}
  LibM = 'libm.so.6';
    {$ENDIF}
  {$ENDIF}
{$ENDIF}

function crt_expf(X: Single): Single; cdecl; external LibM name 'expf';
function crt_exp2f(X: Single): Single; cdecl; external LibM name 'exp2f';
function crt_powf(X, Y: Single): Single; cdecl; external LibM name 'powf';
function crt_tanf(X: Single): Single; cdecl; external LibM name 'tanf';
function crt_exp(X: Double): Double; cdecl; external LibM name 'exp';
function crt_pow(X, Y: Double): Double; cdecl; external LibM name 'pow';

function ExpF(X: Single): Single;
begin
  Result := crt_expf(X);
end;

function Exp2F(X: Single): Single;
begin
  Result := crt_exp2f(X);
end;

function PowF(X, Y: Single): Single;
begin
  Result := crt_powf(X, Y);
end;

function TanF(X: Single): Single;
begin
  Result := crt_tanf(X);
end;

function ExpD(X: Double): Double;
begin
  Result := crt_exp(X);
end;

function PowD(X, Y: Double): Double;
begin
  Result := crt_pow(X, Y);
end;

{$ELSE}

// FPC's maths: in double (or extended), rounded to Single. Within an ulp of the C library.
function ExpF(X: Single): Single;
begin
  Result := Exp(X);
end;

function Exp2F(X: Single): Single;
begin
  Result := Power(2.0, X);
end;

function PowF(X, Y: Single): Single;
begin
  Result := Power(X, Y);
end;

function TanF(X: Single): Single;
begin
  Result := Tan(X);
end;

function ExpD(X: Double): Double;
begin
  Result := Exp(X);
end;

function PowD(X, Y: Double): Double;
begin
  Result := Power(X, Y);
end;

{$ENDIF}

function ClampF(V, Lo, Hi: Single): Single;
begin
  if V < Lo then
    Result := Lo
  else if Hi < V then
    Result := Hi
  else
    Result := V;
end;

function ClampI(V, Lo, Hi: Integer): Integer;
begin
  if V < Lo then
    Result := Lo
  else if Hi < V then
    Result := Hi
  else
    Result := V;
end;

function MinF(A, B: Single): Single;
begin
  if B < A then
    Result := B
  else
    Result := A;
end;

function MaxF(A, B: Single): Single;
begin
  if A < B then
    Result := B
  else
    Result := A;
end;

function MinI(A, B: Integer): Integer;
begin
  if B < A then
    Result := B
  else
    Result := A;
end;

function FloorD(X: Double): Double;
begin
  Result := Int(X);   // exact
  if Result > X then
    Result := Result - 1;
end;

function IsFiniteD(X: Double): Boolean;
begin
  Result := not IsNan(X) and not IsInfinite(X);
end;

end.
