// MzPCD - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// PcdMath - the C library's double functions the C++ MzPCD engine calls beyond those in
// PcfMath (MzPCF's, shared, and left as it is): sin, cos, tan, log2, exp2, lround and
// lroundf, and std::clamp / min / max on doubles.
//
// The PCD works almost entirely in double - the knobs, the clipper, the filters, the
// oversampler - where the PCF works in float. The precision rules are PcfMath's: Single
// and Double exactly where the C++ has float and double, the same evaluation order, and
// the C library's own functions, so the port renders the same samples bit for bit
// (verify/build_verify.cmd checks it against the original). The PCD units are compiled
// with {$MINFPCONSTPREC 64}, so a literal such as 127.0 is a double, as in C++, and does
// not make a Single expression of `X * 127.0`; the C++'s float literals (127.0f) are typed
// Single constants.

unit PcdMath;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$MINFPCONSTPREC 64}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

// Take the functions from the platform's C library, as the C++ engine does (PcfMath's
// PCF_CRT_MATH, for the PCD's own). Undefine for FPC's own maths: within an ulp, but no
// longer bit-identical.
{$DEFINE PCD_CRT_MATH}

interface

// The C library's sin, cos, tan, log2 and exp2 (double).
function SinD(X: Double): Double; inline;
function CosD(X: Double): Double; inline;
function TanD(X: Double): Double; inline;
function Log2D(X: Double): Double; inline;
function Exp2D(X: Double): Double; inline;
// std::lround (double) and std::lround (float): to nearest, halves away from zero.
function LRoundD(X: Double): Integer; inline;
function LRoundF(X: Single): Integer; inline;

// std::clamp(v, lo, hi): lo if v < lo, hi if hi < v, else v.
function ClampD(V, Lo, Hi: Double): Double; inline;
// std::min(a, b) and std::max(a, b): b only if it is less (greater).
function MinD(A, B: Double): Double; inline;
function MaxI(A, B: Integer): Integer; inline;

implementation

{$IFDEF PCD_CRT_MATH}

{$IFDEF FPC}
uses
  ctypes;   // clong: C's long, 32 bits on Windows, 64 on 64-bit Linux and macOS
{$ELSE}
type
  clong = LongInt;   // Delphi's LongInt is C's long on every platform
{$ENDIF}

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

function crt_sin(X: Double): Double; cdecl; external LibM name 'sin';
function crt_cos(X: Double): Double; cdecl; external LibM name 'cos';
function crt_tan(X: Double): Double; cdecl; external LibM name 'tan';
function crt_log2(X: Double): Double; cdecl; external LibM name 'log2';
function crt_exp2(X: Double): Double; cdecl; external LibM name 'exp2';
function crt_lround(X: Double): clong; cdecl; external LibM name 'lround';
function crt_lroundf(X: Single): clong; cdecl; external LibM name 'lroundf';

function SinD(X: Double): Double;
begin
  Result := crt_sin(X);
end;

function CosD(X: Double): Double;
begin
  Result := crt_cos(X);
end;

function TanD(X: Double): Double;
begin
  Result := crt_tan(X);
end;

function Log2D(X: Double): Double;
begin
  Result := crt_log2(X);
end;

function Exp2D(X: Double): Double;
begin
  Result := crt_exp2(X);
end;

function LRoundD(X: Double): Integer;
begin
  Result := Integer(crt_lround(X));
end;

function LRoundF(X: Single): Integer;
begin
  Result := Integer(crt_lroundf(X));
end;

{$ELSE}

uses
  Math;

// FPC's maths, in double. Within an ulp of the C library.
function SinD(X: Double): Double;
begin
  Result := Sin(X);
end;

function CosD(X: Double): Double;
begin
  Result := Cos(X);
end;

function TanD(X: Double): Double;
begin
  Result := Tan(X);
end;

function Log2D(X: Double): Double;
begin
  Result := Log2(X);
end;

function Exp2D(X: Double): Double;
begin
  Result := Power(2.0, X);
end;

function LRoundD(X: Double): Integer;
begin
  if X < 0 then
    Result := -Trunc(0.5 - X)
  else
    Result := Trunc(X + 0.5);
end;

function LRoundF(X: Single): Integer;
var
  D: Double;
begin
  D := X;   // exact; and so is D + 0.5 for any float that is not already whole
  Result := LRoundD(D);
end;

{$ENDIF}

function ClampD(V, Lo, Hi: Double): Double;
begin
  if V < Lo then
    Result := Lo
  else if Hi < V then
    Result := Hi
  else
    Result := V;
end;

function MinD(A, B: Double): Double;
begin
  if B < A then
    Result := B
  else
    Result := A;
end;

function MaxI(A, B: Integer): Integer;
begin
  if A < B then
    Result := B
  else
    Result := A;
end;

end.
