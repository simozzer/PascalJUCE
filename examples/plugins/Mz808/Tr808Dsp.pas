// Mz808 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/TR808/Dsp.h.
//
// A NOTE ON PRECISION, for every Tr808* unit. The C++ engine works in float, with a few
// double sections; this port uses Single and Double in exactly the same places, so that
// it renders the same samples. Two things in Pascal would otherwise widen a float
// expression to double behind your back:
//
//   - A real literal that a Single cannot hold exactly (0.1, 1.3, ...) is a Double
//     constant, and drags the whole expression into double. Such literals are therefore
//     declared as typed Single constants (C++'s 0.1f). Exact ones (0.5, 3, 27) are fine.
//   - The maths functions (Exp, Tan, Power, ...) take and return Double. The F-suffixed
//     wrappers below are the float versions instead: by default the C library's own
//     expf, tanf, ... (see TR808_CRT_MATH), as the C++ calls them.
//
// And two that Pascal leaves open where C++ does not: the order in which the operands of
// one expression are evaluated (so anything with a side effect - a draw from the noise, a
// filter's step - is its own statement, in the C++ order), and Single(...) of a Double,
// which FPC refuses (the value is assigned to a Single instead, which rounds it the same).
//
// Delphi: {$EXCESSPRECISION OFF} keeps Single arithmetic in single precision on Win64.

unit Tr808Dsp;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

// Take expf, powf and tanf from the platform's C library, as the C++ engine does, so the
// port renders bit-identical samples. Undefine for pure Pascal maths (within an ulp:
// inaudible, but no longer bit-identical).
{$DEFINE TR808_CRT_MATH}

interface

const
  Pi64 = 3.14159265358979323846;   // the C++ `pi`, a double

var
  // (float) pi. A typed constant would do in FPC; a variable set once is the same in
  // every compiler.
  PiF: Single;

function Clamp(X, Lo, Hi: Single): Single; inline;

// A linear pot setting an RC time or a frequency through an exponential law: equal travel,
// equal ratio.
function ExpLaw(X, Lo, Hi: Single): Single;

// A level pot, audio taper as the 808's are: half way round is about -12 dB.
function Taper(Panel: Single): Single;

// One-pole RC coefficient for a time constant in seconds.
function OnePoleCoef(TauSeconds, SampleRate: Single): Single;

// The per-sample multiplier of an RC discharge.
function DecayCoef(TauSeconds, SampleRate: Single): Single;

// The time constant of an RC low pass with its corner at f.
function TauOf(Hz: Single): Single;

// tanh, close enough for a transistor and a good deal cheaper. Exact at 0, within a percent
// to |x| = 3, and saturating to +-1 beyond.
function SoftClip(X: Single): Single; inline;

// softClip(x) / x: the small-signal gain of a saturating stage where it is working.
function SoftClipGain(X: Single): Single; inline;

// The C library's float functions: computed in double, rounded to Single.
function ExpF(X: Single): Single; inline;
function PowF(X, Y: Single): Single; inline;
function TanF(X: Single): Single; inline;

// std::lround: to nearest, halves away from zero.
function LRound(X: Single): Integer;

type
  // xorshift32, exactly as the C++ one, so the noise and the metal's phases run the same
  // course.
  TRandom = record
  private
    FState: UInt32;
  public
    procedure Init(Seed: UInt32 = $2545F491);
    function Next: UInt32; inline;
    function Uniform: Single; inline;   // [0, 1)
    function Bipolar: Single; inline;   // [-1, 1)
    // White noise at unit deviation. Uniform rather than gaussian: it is filtered before
    // anyone hears it, and the ear cannot tell.
    function White: Single; inline;
  end;

  //
  // A state-variable filter, solved with zero-delay feedback (the topology-preserving form),
  // so it stays in tune to the top of the band and does not blow up when its frequency is
  // moved every sample - which the bass drum and toms do on every hit.
  //
  // The band-pass output, Bp, is the unnormalised one: a step of height h into it rings at
  // amplitude h, and its gain at the centre is Q. BandNorm is the same output at unity gain
  // at the centre, for when it is a filter rather than a resonator.
  //
  TSvf = record
  private
    FPiOverFs, FNyquistish: Single;
    FG, FK, FA1, FA2, FA3: Single;
    FIc1, FIc2: Single;
  public
    Lp, Bp, Hp: Single;
    procedure Init;   // the C++ member initialisers
    procedure Prepare(SampleRate: Single);
    procedure Setup(Hz, Q: Single);
    // k = 1/Q. Together with Setup's frequency, without the tan when only k moves.
    procedure SetDamping(Damping: Single);
    procedure Tune(Hz, Damping: Single);
    function Process(X: Single): Single;
    function BandNorm: Single; inline;
    procedure Reset;
    // how much is still ringing, for deciding a voice has gone quiet
    function Energy: Single; inline;
  end;

  // An RC low pass, with the high pass as what it leaves.
  TOnePole = record
    Z: Single;
    procedure Init; inline;
    function LowPass(X, Coef: Single): Single; inline;
    function HighPass(X, Coef: Single): Single; inline;
    procedure Reset; inline;
  end;

implementation

uses
  Math;

const
  SmallSignal: Single = 1.0e-4;
  UnitDeviation: Single = 1.7320508;
  NyquistFraction: Single = 0.49;

function Clamp(X, Lo, Hi: Single): Single;
begin
  if X < Lo then
    Result := Lo
  else if X > Hi then
    Result := Hi
  else
    Result := X;
end;

{$IFDEF TR808_CRT_MATH}

// The C library's own float functions, which the C++ engine calls. They are accurate to
// about an ulp but not always correctly rounded, so computing in double here instead
// would differ from the C++ in the last bit now and then. Calling the same library renders
// the same samples, bit for bit.
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
function crt_powf(X, Y: Single): Single; cdecl; external LibM name 'powf';
function crt_tanf(X: Single): Single; cdecl; external LibM name 'tanf';

function ExpF(X: Single): Single;
begin
  Result := crt_expf(X);
end;

function PowF(X, Y: Single): Single;
begin
  Result := crt_powf(X, Y);
end;

function TanF(X: Single): Single;
begin
  Result := crt_tanf(X);
end;

{$ELSE}

// Pure Pascal: in double, rounded to Single. Within an ulp of the C library.
function ExpF(X: Single): Single;
begin
  Result := Exp(X);
end;

function PowF(X, Y: Single): Single;
begin
  Result := Power(X, Y);
end;

function TanF(X: Single): Single;
begin
  Result := Tan(X);
end;

{$ENDIF}

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
  Result := Lo * PowF(Hi / Lo, Clamp(X, 0, 1));
end;

function Taper(Panel: Single): Single;
var
  X: Single;
begin
  X := Clamp(Panel / 10, 0, 1);
  Result := X * X;
end;

function OnePoleCoef(TauSeconds, SampleRate: Single): Single;
begin
  if TauSeconds <= 0 then
    Result := 1
  else
    Result := 1 - ExpF(-1 / (TauSeconds * SampleRate));
end;

function DecayCoef(TauSeconds, SampleRate: Single): Single;
begin
  if TauSeconds <= 0 then
    Result := 0
  else
    Result := ExpF(-1 / (TauSeconds * SampleRate));
end;

function TauOf(Hz: Single): Single;
begin
  Result := 1 / (2 * PiF * Hz);
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

function TRandom.White: Single;
begin
  Result := Bipolar * UnitDeviation;
end;

{ TSvf }

procedure TSvf.Init;
begin
  Lp := 0;
  Bp := 0;
  Hp := 0;
  FPiOverFs := 0;
  FNyquistish := 20000;
  FG := 0;
  FK := 1;
  FA1 := 0;
  FA2 := 0;
  FA3 := 0;
  FIc1 := 0;
  FIc2 := 0;
end;

procedure TSvf.Prepare(SampleRate: Single);
begin
  FPiOverFs := PiF / SampleRate;
  FNyquistish := NyquistFraction * SampleRate;
end;

procedure TSvf.Setup(Hz, Q: Single);
begin
  FG := TanF(FPiOverFs * Clamp(Hz, 1, FNyquistish));
  SetDamping(1 / Q);
end;

procedure TSvf.SetDamping(Damping: Single);
begin
  FK := Damping;
  FA1 := 1 / (1 + FG * (FG + FK));
  FA2 := FG * FA1;
  FA3 := FG * FA2;
end;

procedure TSvf.Tune(Hz, Damping: Single);
begin
  FG := TanF(FPiOverFs * Clamp(Hz, 1, FNyquistish));
  SetDamping(Damping);
end;

function TSvf.Process(X: Single): Single;
var
  V1, V2, V3: Single;
begin
  V3 := X - FIc2;
  V1 := FA1 * FIc1 + FA2 * V3;
  V2 := FIc2 + FA2 * FIc1 + FA3 * V3;
  FIc1 := 2 * V1 - FIc1;
  FIc2 := 2 * V2 - FIc2;
  Lp := V2;
  Bp := V1;
  Hp := X - FK * V1 - V2;
  Result := V1;
end;

function TSvf.BandNorm: Single;
begin
  Result := FK * Bp;
end;

procedure TSvf.Reset;
begin
  FIc1 := 0;
  FIc2 := 0;
  Lp := 0;
  Bp := 0;
  Hp := 0;
end;

function TSvf.Energy: Single;
begin
  Result := Abs(FIc1) + Abs(FIc2);
end;

{ TOnePole }

procedure TOnePole.Init;
begin
  Z := 0;
end;

function TOnePole.LowPass(X, Coef: Single): Single;
begin
  Z := Z + (X - Z) * Coef;
  Result := Z;
end;

function TOnePole.HighPass(X, Coef: Single): Single;
begin
  Result := X - LowPass(X, Coef);
end;

procedure TOnePole.Reset;
begin
  Z := 0;
end;

initialization
  PiF := Pi64;
end.
