// Mz950 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// What every S950* unit shares and the C++ takes from its standard library: the C library's
// maths functions, the rounding functions, and the atomics.
//
// A NOTE ON PRECISION, for every S950* unit. The C++ engine works in double, with float
// buffers and a few float sections; this port uses Double and Single in exactly the same
// places, so that it renders the same samples. Three things would otherwise get in the way:
//
//   - The maths functions. Pascal's Exp, Sin, Power and the rest are not the C library's,
//     and differ from it in the last bit now and then. The wrappers below call the C
//     library's own (see S950_CRT_MATH), as the C++ does.
//   - What the C++ compiler makes of a call. clang turns std::pow (2.0, x) into exp2 (x),
//     so every pow (2.0, ...) in the C++ is Exp2D here, not PowD. (Checked in the
//     compiler's assembly: see verify\build_verify.cmd.) Every other pow stays pow.
//   - Float arithmetic. A real literal a Single cannot hold exactly (0.7, 0.1, ...) is a
//     Double constant and drags a Single expression into double, so where the C++ has a
//     float literal this has a typed Single constant. A Single result is assigned to a
//     Single variable rather than cast with Single(): FPC's cast of a Double does not
//     always round. And the C++'s evaluation order is kept, one rounding at a time.
//
// Delphi: {$EXCESSPRECISION OFF} keeps Single arithmetic in single precision on Win64.

unit S950Math;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$MINFPCONSTPREC 64}   // a real literal is a double, as in C++ (1.0 would otherwise be a Single)
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

// Take the maths functions from the platform's C library, as the C++ engine does, so the
// port renders bit-identical samples. Undefine for pure Pascal maths (within an ulp:
// inaudible, but no longer bit-identical).
{$DEFINE S950_CRT_MATH}

interface

const
  Pi64 = 3.14159265358979323846;   // the C++ `pi`, a double

// ---------------------------------------------------------------- the C library, double

function PowD(X, Y: Double): Double;      // std::pow (x, y) for any x but 2.0
function Exp2D(X: Double): Double;        // std::pow (2.0, x), and std::exp2
function ExpD(X: Double): Double;
function LogD(X: Double): Double;
function Log2D(X: Double): Double;
function Log10D(X: Double): Double;
function SinD(X: Double): Double;
function CosD(X: Double): Double;
function TanD(X: Double): Double;
function AtanD(X: Double): Double;
function Atan2D(Y, X: Double): Double;
function TanhD(X: Double): Double;
function FmodD(X, Y: Double): Double;

// ----------------------------------------------------------------- the C library, float

function PowF(X, Y: Single): Single;
function ExpF(X: Single): Single;
function SinF(X: Single): Single;
function CosF(X: Single): Single;

// -------------------------------------------------------------------------- rounding

// std::floor and std::ceil for doubles of any size (Math.Floor returns an Integer).
function FloorD(X: Double): Double; inline;
function CeilD(X: Double): Double; inline;
// std::round: to nearest, halves away from zero, as a double.
function RoundD(X: Double): Double;
// std::lround: the same, as an integer.
function LRound(X: Double): Integer;
function LRoundF(X: Single): Integer;
// static_cast<int> of a double: towards zero.
function TruncI(X: Double): Integer; inline;

function MinD(A, B: Double): Double; inline;      // std::min - the first if they tie
function MaxD(A, B: Double): Double; inline;      // std::max - the first if they tie
function MinI(A, B: Integer): Integer; inline;
function MaxI(A, B: Integer): Integer; inline;

// ------------------------------------------------------------------------- atomics
//
// The C++'s std::atomic, as interlocked operations. A compare-exchange that changes nothing
// is a load with a full barrier, and an exchange is a store with one - stronger than the
// relaxed and acquire/release orders the C++ asks for, and never weaker.

function AtomicLoad(var Target: Integer): Integer; inline;
procedure AtomicStore(var Target: Integer; Value: Integer); inline;
function AtomicIncrement32(var Target: Integer): Integer; inline;   // the new value
function AtomicDecrement32(var Target: Integer): Integer; inline;   // the new value
function AtomicLoad64(var Target: Int64): Int64; inline;
procedure AtomicStore64(var Target: Int64; Value: Int64); inline;

type
  // std::atomic<float>
  TAtomicSingle = record
  private
    FBits: Integer;
  public
    function Load: Single; inline;
    procedure Store(Value: Single); inline;
  end;

  // std::atomic<double>
  TAtomicDouble = record
  private
    FBits: Int64;
  public
    function Load: Double; inline;
    procedure Store(Value: Double); inline;
  end;

  // std::atomic<bool>
  TAtomicBool = record
  private
    FValue: Integer;
  public
    function Load: Boolean; inline;
    procedure Store(Value: Boolean); inline;
  end;

  // std::atomic<int>, and std::atomic<unsigned> as its bits
  TAtomicInt = record
  private
    FValue: Integer;
  public
    function Load: Integer; inline;
    procedure Store(Value: Integer); inline;
    procedure Add(By: Integer); inline;
  end;

implementation

{$IFNDEF S950_CRT_MATH}
uses
  Math;
{$ENDIF}

{$IFDEF S950_CRT_MATH}

// The C library's own functions, which the C++ engine calls. They are accurate to about an
// ulp but not always correctly rounded, so anything else would differ from the C++ in the
// last bit now and then. Calling the same library renders the same samples, bit for bit.
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

function crt_pow(X, Y: Double): Double; cdecl; external LibM name 'pow';
function crt_exp2(X: Double): Double; cdecl; external LibM name 'exp2';
function crt_exp(X: Double): Double; cdecl; external LibM name 'exp';
function crt_log(X: Double): Double; cdecl; external LibM name 'log';
function crt_log2(X: Double): Double; cdecl; external LibM name 'log2';
function crt_log10(X: Double): Double; cdecl; external LibM name 'log10';
function crt_sin(X: Double): Double; cdecl; external LibM name 'sin';
function crt_cos(X: Double): Double; cdecl; external LibM name 'cos';
function crt_tan(X: Double): Double; cdecl; external LibM name 'tan';
function crt_atan(X: Double): Double; cdecl; external LibM name 'atan';
function crt_atan2(Y, X: Double): Double; cdecl; external LibM name 'atan2';
function crt_tanh(X: Double): Double; cdecl; external LibM name 'tanh';
function crt_fmod(X, Y: Double): Double; cdecl; external LibM name 'fmod';
function crt_powf(X, Y: Single): Single; cdecl; external LibM name 'powf';
function crt_expf(X: Single): Single; cdecl; external LibM name 'expf';
function crt_sinf(X: Single): Single; cdecl; external LibM name 'sinf';
function crt_cosf(X: Single): Single; cdecl; external LibM name 'cosf';

function PowD(X, Y: Double): Double;
begin
  Result := crt_pow(X, Y);
end;

function Exp2D(X: Double): Double;
begin
  Result := crt_exp2(X);
end;

function ExpD(X: Double): Double;
begin
  Result := crt_exp(X);
end;

function LogD(X: Double): Double;
begin
  Result := crt_log(X);
end;

function Log2D(X: Double): Double;
begin
  Result := crt_log2(X);
end;

function Log10D(X: Double): Double;
begin
  Result := crt_log10(X);
end;

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

function AtanD(X: Double): Double;
begin
  Result := crt_atan(X);
end;

function Atan2D(Y, X: Double): Double;
begin
  Result := crt_atan2(Y, X);
end;

function TanhD(X: Double): Double;
begin
  Result := crt_tanh(X);
end;

function FmodD(X, Y: Double): Double;
begin
  Result := crt_fmod(X, Y);
end;

function PowF(X, Y: Single): Single;
begin
  Result := crt_powf(X, Y);
end;

function ExpF(X: Single): Single;
begin
  Result := crt_expf(X);
end;

function SinF(X: Single): Single;
begin
  Result := crt_sinf(X);
end;

function CosF(X: Single): Single;
begin
  Result := crt_cosf(X);
end;

{$ELSE}

// Pure Pascal: within an ulp of the C library.
function PowD(X, Y: Double): Double;
begin
  Result := Math.Power(X, Y);
end;

function Exp2D(X: Double): Double;
begin
  Result := Math.Power(2.0, X);
end;

function ExpD(X: Double): Double;
begin
  Result := Exp(X);
end;

function LogD(X: Double): Double;
begin
  Result := Ln(X);
end;

function Log2D(X: Double): Double;
begin
  Result := Math.Log2(X);
end;

function Log10D(X: Double): Double;
begin
  Result := Math.Log10(X);
end;

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
  Result := Math.Tan(X);
end;

function AtanD(X: Double): Double;
begin
  Result := ArcTan(X);
end;

function Atan2D(Y, X: Double): Double;
begin
  Result := Math.ArcTan2(Y, X);
end;

function TanhD(X: Double): Double;
begin
  Result := Math.Tanh(X);
end;

function FmodD(X, Y: Double): Double;
begin
  Result := X - Y * Int(X / Y);
end;

function PowF(X, Y: Single): Single;
begin
  Result := Math.Power(X, Y);
end;

function ExpF(X: Single): Single;
begin
  Result := Exp(X);
end;

function SinF(X: Single): Single;
begin
  Result := Sin(X);
end;

function CosF(X: Single): Single;
begin
  Result := Cos(X);
end;

{$ENDIF}

function FloorD(X: Double): Double;
begin
  Result := Int(X);
  if Result > X then
    Result := Result - 1;
end;

function CeilD(X: Double): Double;
begin
  Result := Int(X);
  if Result < X then
    Result := Result + 1;
end;

function RoundD(X: Double): Double;
var
  W: Double;
begin
  // X - Int(X) is exact, so the half is judged on the true fraction - adding 0.5 first
  // would round 0.49999999999999994 up.
  W := Int(X);
  if X >= 0 then
  begin
    if X - W >= 0.5 then
      W := W + 1;
  end
  else if W - X >= 0.5 then
    W := W - 1;
  Result := W;
end;

function LRound(X: Double): Integer;
begin
  Result := Trunc(RoundD(X));
end;

function LRoundF(X: Single): Integer;
var
  D: Double;
begin
  D := X;   // exact
  Result := Trunc(RoundD(D));
end;

function TruncI(X: Double): Integer;
begin
  Result := Trunc(X);
end;

function MinD(A, B: Double): Double;
begin
  // std::min (a, b) is (b < a) ? b : a
  if B < A then
    Result := B
  else
    Result := A;
end;

function MaxD(A, B: Double): Double;
begin
  // std::max (a, b) is (a < b) ? b : a
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

function MaxI(A, B: Integer): Integer;
begin
  if A < B then
    Result := B
  else
    Result := A;
end;

// ------------------------------------------------------------------------- atomics

function AtomicLoad(var Target: Integer): Integer;
begin
  {$IFDEF FPC}
  Result := InterlockedCompareExchange(Target, 0, 0);
  {$ELSE}
  Result := AtomicCmpExchange(Target, 0, 0);
  {$ENDIF}
end;

procedure AtomicStore(var Target: Integer; Value: Integer);
begin
  {$IFDEF FPC}
  InterlockedExchange(Target, Value);
  {$ELSE}
  AtomicExchange(Target, Value);
  {$ENDIF}
end;

function AtomicIncrement32(var Target: Integer): Integer;
begin
  {$IFDEF FPC}
  Result := InterlockedIncrement(Target);
  {$ELSE}
  Result := AtomicIncrement(Target);
  {$ENDIF}
end;

function AtomicDecrement32(var Target: Integer): Integer;
begin
  {$IFDEF FPC}
  Result := InterlockedDecrement(Target);
  {$ELSE}
  Result := AtomicDecrement(Target);
  {$ENDIF}
end;

function AtomicLoad64(var Target: Int64): Int64;
begin
  {$IFDEF FPC}
  Result := InterlockedCompareExchange64(Target, 0, 0);
  {$ELSE}
  Result := AtomicCmpExchange(Target, 0, 0);
  {$ENDIF}
end;

procedure AtomicStore64(var Target: Int64; Value: Int64);
begin
  {$IFDEF FPC}
  InterlockedExchange64(Target, Value);
  {$ELSE}
  AtomicExchange(Target, Value);
  {$ENDIF}
end;

{ TAtomicSingle }

function TAtomicSingle.Load: Single;
var
  Bits: Integer;
begin
  Bits := AtomicLoad(FBits);
  Move(Bits, Result, SizeOf(Result));
end;

procedure TAtomicSingle.Store(Value: Single);
var
  Bits: Integer;
begin
  Move(Value, Bits, SizeOf(Bits));
  AtomicStore(FBits, Bits);
end;

{ TAtomicDouble }

function TAtomicDouble.Load: Double;
var
  Bits: Int64;
begin
  Bits := AtomicLoad64(FBits);
  Move(Bits, Result, SizeOf(Result));
end;

procedure TAtomicDouble.Store(Value: Double);
var
  Bits: Int64;
begin
  Move(Value, Bits, SizeOf(Bits));
  AtomicStore64(FBits, Bits);
end;

{ TAtomicBool }

function TAtomicBool.Load: Boolean;
begin
  Result := AtomicLoad(FValue) <> 0;
end;

procedure TAtomicBool.Store(Value: Boolean);
begin
  if Value then
    AtomicStore(FValue, 1)
  else
    AtomicStore(FValue, 0);
end;

{ TAtomicInt }

function TAtomicInt.Load: Integer;
begin
  Result := AtomicLoad(FValue);
end;

procedure TAtomicInt.Store(Value: Integer);
begin
  AtomicStore(FValue, Value);
end;

procedure TAtomicInt.Add(By: Integer);
begin
  {$IFDEF FPC}
  InterlockedExchangeAdd(FValue, By);
  {$ELSE}
  AtomicIncrement(FValue, By);
  {$ENDIF}
end;

end.
