// Mz303 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of source/TB303/Dsp.h.
//
// A NOTE ON PRECISION, for every Tb303* unit. The C++ engine works in float, with a few
// double sections; this port uses Single and Double in exactly the same places, so that
// it renders the same samples. Two things in Pascal would otherwise widen a float
// expression to double behind your back:
//
//   - A real literal that a Single cannot hold exactly (0.1, 1.3, ...) is a Double
//     constant, and drags the whole expression into double. Such literals are therefore
//     declared as typed Single constants (C++'s 0.1f). Exact ones (0.5, 3, 27) are fine.
//   - The maths functions (Exp, Tan, Power, ...) take and return Double. The F-suffixed
//     wrappers below are the float versions instead: by default the C library's own
//     expf, tanf, ... (see TB303_CRT_MATH), as the C++ calls them.
//
// Delphi: {$EXCESSPRECISION OFF} keeps Single arithmetic in single precision on Win64.

unit Tb303Dsp;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

// Take expf, exp2f, powf, tanf, sinf and log2f from the platform's C library, as the C++
// engine does, so the port renders bit-identical samples. Undefine for pure Pascal maths
// (within an ulp: inaudible, but no longer bit-identical).
{$DEFINE TB303_CRT_MATH}

interface

const
  Pi64 = 3.14159265358979323846;   // the C++ `pi`, a double

var
  // (float) pi. A typed constant would do in FPC; a variable set once is the same in
  // every compiler.
  PiF: Single;

function Clamp(X, Lo, Hi: Single): Single; inline;

// A linear pot feeding an exponential converter, which is what almost every time and rate
// control on the TB-303 is: equal knob travel, equal ratio.
function ExpLaw(X, Lo, Hi: Single): Single;

// One-pole RC coefficient for a time constant in seconds.
function OnePoleCoef(TauSeconds, SampleRate: Single): Single;

// tanh, close enough for a transistor pair and a good deal cheaper. Exact at 0, within a
// percent to |x| = 3, and saturating to +-1 beyond.
function SoftClip(X: Single): Single; inline;

// softClip(x) / x - the small-signal gain of a saturating stage at the point it is working,
// which is what the filter linearises around.
function SoftClipGain(X: Single): Single; inline;

// The C library's float functions: computed in double, rounded to Single.
function ExpF(X: Single): Single; inline;
function Exp2F(X: Single): Single; inline;
function PowF(X, Y: Single): Single; inline;
function TanF(X: Single): Single; inline;
function SinF(X: Single): Single; inline;
function Log2F(X: Single): Single; inline;

// std::floor for doubles of any size (Math.Floor returns an Integer).
function FloorD(X: Double): Double; inline;
// std::lround: to nearest, halves away from zero.
function LRound(X: Single): Integer;

type
  // xorshift32, exactly as the C++ one, so drift and the noise run the same course.
  TRandom = record
  private
    FState: UInt32;
  public
    procedure Init(Seed: UInt32 = $2545F491);
    function Next: UInt32; inline;
    function Uniform: Single; inline;   // [0, 1)
    function Bipolar: Single; inline;   // [-1, 1)
    // Four uniforms summed: near enough gaussian for noise that is filtered before anyone
    // hears it, and scaled to unit deviation.
    function Noise: Single;
  end;

implementation

uses
  Math;

const
  SmallSignal: Single = 1.0e-4;
  UnitDeviation: Single = 1.7320508;
  Ln2 = 0.69314718055994530942;

function Clamp(X, Lo, Hi: Single): Single;
begin
  if X < Lo then
    Result := Lo
  else if X > Hi then
    Result := Hi
  else
    Result := X;
end;

{$IFDEF TB303_CRT_MATH}

// The C library's own float functions, which the C++ engine calls. They are accurate to
// about an ulp but not always correctly rounded, so computing in double here instead
// would differ from the C++ in the last bit now and then (about one call in a thousand
// for sinf). Calling the same library renders the same samples, bit for bit.
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
function crt_sinf(X: Single): Single; cdecl; external LibM name 'sinf';
function crt_log2f(X: Single): Single; cdecl; external LibM name 'log2f';

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

function SinF(X: Single): Single;
begin
  Result := crt_sinf(X);
end;

function Log2F(X: Single): Single;
begin
  Result := crt_log2f(X);
end;

{$ELSE}

// Pure Pascal: in double, rounded to Single. Within an ulp of the C library.
function ExpF(X: Single): Single;
begin
  Result := Exp(X);
end;

function Exp2F(X: Single): Single;
var
  D: Double;
begin
  D := X;
  Result := Exp(D * Ln2);
end;

function PowF(X, Y: Single): Single;
begin
  Result := Power(X, Y);
end;

function TanF(X: Single): Single;
begin
  Result := Tan(X);
end;

function SinF(X: Single): Single;
begin
  Result := Sin(X);
end;

function Log2F(X: Single): Single;
begin
  Result := Log2(X);
end;

{$ENDIF}

function FloorD(X: Double): Double;
begin
  Result := Int(X);
  if Result > X then
    Result := Result - 1;
end;

function LRound(X: Single): Integer;
var
  D: Double;
begin
  D := X;   // exact, and so is adding a half in double
  if D >= 0 then
    Result := Trunc(D + 0.5)
  else
    Result := -Trunc(-D + 0.5);
end;

function ExpLaw(X, Lo, Hi: Single): Single;
begin
  Result := Lo * PowF(Hi / Lo, X);
end;

function OnePoleCoef(TauSeconds, SampleRate: Single): Single;
begin
  if TauSeconds <= 0 then
    Result := 1
  else
    Result := 1 - ExpF(-1 / (TauSeconds * SampleRate));
end;

function SoftClip(X: Single): Single;
var
  X2: Single;
begin
  if X > 3 then
    Result := 1
  else if X < -3 then
    Result := -1
  else
  begin
    X2 := X * X;
    Result := X * (27 + X2) / (27 + 9 * X2);
  end;
end;

function SoftClipGain(X: Single): Single;
begin
  if Abs(X) < SmallSignal then
    Result := 1
  else
    Result := SoftClip(X) / X;
end;

{ TRandom }

procedure TRandom.Init(Seed: UInt32);
begin
  if Seed <> 0 then
    FState := Seed
  else
    FState := 1;
end;

function TRandom.Next: UInt32;
begin
  // UInt32() keeps the shifted value in 32 bits, as uint32_t arithmetic does.
  FState := FState xor UInt32(FState shl 13);
  FState := FState xor (FState shr 17);
  FState := FState xor UInt32(FState shl 5);
  Result := FState;
end;

function TRandom.Uniform: Single;
begin
  Result := (Next shr 8) * (1.0 / 16777216.0);
end;

function TRandom.Bipolar: Single;
begin
  Result := Uniform * 2 - 1;
end;

function TRandom.Noise: Single;
var
  A, B, C, D: Single;
begin
  // One call per statement: Pascal does not promise left-to-right evaluation of operands,
  // and the order the draws are summed in changes the rounding.
  A := Uniform;
  B := Uniform;
  C := Uniform;
  D := Uniform;
  Result := (A + B + C + D - 2) * UnitDeviation;
end;

initialization
  PiF := Pi64;
end.
