// Mz950 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Plugin/Source/S950/SynthPatch.h and SynthPatch.cpp.
//
// The C++'s std::map WaveCache is TWaveCache, a sorted list under the same keys. render's
// `Disk& out` is a TS950Disk the caller owns, which a successful render Assigns the new disk
// to (the C++'s `out = std::move (d)`); `error`, as there, is written only on failure. The
// words a cache holds are S950Disk's TSmallIntArray, ready for TNewSample.Words12.

unit S950SynthPatch;

{$IFDEF FPC}
  {$MODE DELPHI}
  // A real literal is a Double here even where a Single holds it exactly (1.0, 99.0, ...):
  // otherwise FPC types it Single, and 1.0 / n or n / 99.0 would be worked in single.
  {$MINFPCONSTPREC 64}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  SysUtils, S950Math, S950Disk, S950Synth;

//
// A sound designed on the Synth page, and how it becomes a disk.
//
// The recipe is a handful of numbers a window can show as knobs. Rendering it is:
//
//   - one SAMPLE holding every oscillator that is on, mixed into a single loop drawn from
//     harmonics (Synth.h) - long enough that a detune's two pitches both join, see
//     planMix - and one per drum that is on, a one-shot;
//   - one PROGRAMME, with one keygroup for the oscillators across the keyboard, so a note
//     is one voice, and a keygroup per drum on its General MIDI note, constant pitch and
//     one-shot. (It was a keygroup per oscillator until v0.6.1, which made a three-oscillator
//     note three voices and left mono sounding only the first.)
//   - all of it on a blank disk, built by Disk::addSample / addProgram, so the result is
//     an S950 disk like any other: the Program tab edits it, the set saves it, and it goes
//     to a real machine.
//
// WHAT A KNOB ON THE SYNTH PAGE OWNS, AND WHAT THE PROGRAM TAB OWNS
//
// Re-rendering rewrites the disk. If that reset every keygroup setting, the Program tab
// would be a place edits went to die. So render() takes the disk it is replacing and
// copies each keygroup's settings across from the keygroup playing the same sample - the
// envelopes, the filter, the LFO, everything - and writes only what the recipe's own knobs
// own: the zone's tune and level, and for a drum its decay, tone and level. A sound built
// up over both tabs survives a change to either.
//

type
  TOscKind = (
    okOff,
    okSine, okTriangle, okSaw, okSquare, okPulse, okOrgan, okGlass, okBuzz, okHollow,
    okFm1, okFm2, okFmBell,          // FM at ratios 1, 2 and 7
    okRing2, okRing3,                // a saw ring-modulated at 2 and 3
    okBent, okPhaseDistort,          // an oscillator wound up; the Casio trick
    okNoiseWhite, okNoisePink, okNoiseBrown,
    okCount);

function OscKindName(K: TOscKind): string;

type
  /// What the two shaping knobs mean for a kind, for the window's labels.
  TOscKindLabels = record
    Intensity: string;
    Sweep: string;
    HasIntensity: Boolean;
    HasSweep: Boolean;
  end;

function OscKindLabels(K: TOscKind): TOscKindLabels;

type
  TOscSettings = record
    Kind: TOscKind;       // = off
    Level: Integer;       // 0..99, into the zone's loudness trim; = 99
    Octave: Integer;      // -2..2
    Fine: Integer;        // cents, -50..50
    Phase: Integer;       // 0..99, where in the cycle the wave starts
    Intensity: Integer;   // 0..99: pulse width, FM index, bend, skew, or a morph toward a sine; = 50
    Sweep: Integer;       // 0..99: how much of the intensity travels across the loop and back
    procedure Init;       // the C++'s member initialisers
  end;

  /// The nine drums the page offers, in this order, on General MIDI's notes.
  TDrumSlot = (dsKick, dsSnare, dsClap, dsHatClosed, dsHatOpen, dsRide, dsTomLo, dsTomMid, dsTomHi, dsCount);

const
  DrumSlotCount = Ord(dsCount);

function DrumSlotName(D: TDrumSlot): string;
function DrumSlotNote(D: TDrumSlot): Integer;

type
  TDrumSettings = record
    On_: Boolean;        // = true
    Tune: Integer;       // semitones, -12..12, as a change of the sample's rate
    Decay: Integer;      // the keygroup's VCA decay; 99 plays the whole one-shot
    Tone: Integer;       // the zone's filter; = 99
    Level: Integer;      // -50..50 on top of the kit's own balance
    procedure Init;
  end;

const
  /// Where the synth starts when the drums are on: E2, the first key above the ride,
  /// the drums taking C1 to D#2 (36 to 51) below it. Without drums, C0: the bottom
  /// of the machine's keyboard. (Recipe::SynthLowKeyWithDrums and Recipe::SynthLowKey.)
  SynthLowKeyWithDrums = 52;
  SynthLowKey          = 24;

type
  TRecipe = record
    Name: string;                                    // = "SYNTH"
    Osc: array[0..2] of TOscSettings;
    DrumsOn: Boolean;
    Drums: array[0..DrumSlotCount - 1] of TDrumSettings;

    //
    // The keygroup settings a fresh render starts from - what a preset carries. Once
    // rendered these belong to the Program tab, and render() keeps whatever it finds.
    //
    Filter, KeyTrack, VelFilter: Integer;            // 78, 50, 40
    A, D, S, R: Integer;                             // 0, 30, 88, 28
    VcfA, VcfD, VcfS, VcfR, VcfAmount: Integer;      // 0, 45, 40, 0, 12
    VelLoudness: Integer;                            // 30
    LfoRate, LfoDepth, LfoDelay: Integer;            // 45, 4, 70

    procedure Init;      // the C++'s member initialisers
    function AnyOscillator: Boolean;
  end;

/// A recipe as the C++'s `Recipe r;` makes it.
function NewRecipe: TRecipe;

type
  /// Named starting points.
  TPreset = record
    Name: string;
    Recipe: TRecipe;
  end;
  TPresetArray = array of TPreset;

function Presets: TPresetArray;

type
  //
  // Rendered waves, kept between renders so a knob that does not change a wave - a
  // level, an octave, a drum's decay - costs a repack of the disk and not a resynthesis.
  // Keyed by everything that goes into the wave.
  //
  // (std::map<std::string, std::vector<short>>: keys kept sorted, byte for byte.)
  //
  TWaveCache = class
  private
    FKeys: array of string;
    FWaves: array of TSmallIntArray;
    FCount: Integer;
    function Search(const Key: string; out Index: Integer): Boolean;
  public
    function Count: Integer;
    function Key(Index: Integer): string;
    function Words(Index: Integer): TSmallIntArray;
    function TryGet(const Key: string; out Words: TSmallIntArray): Boolean;
    /// emplace: keeps what is there if the key is taken. Returns the words now held.
    function Put(const Key: string; const Words: TSmallIntArray): TSmallIntArray;
    procedure Clear;
  end;

/// The words for one oscillator, cached.
function OscillatorWave(const O: TOscSettings; Cache: TWaveCache): TSmallIntArray;

type
  //
  // THE OSCILLATORS, MIXED INTO ONE LOOP - ONE VOICE A NOTE
  //
  // The oscillators are summed into a single looped sample, so a note is one voice
  // whatever the patch: eight notes of polyphony stay eight, mono and glide move the whole
  // sound, and nothing is stolen out from under a chord.
  //
  // A loop plays at one pitch, so every oscillator has to complete a whole number of
  // cycles in it. Octaves do that in a loop of a few cycles; a detune does not - two saws
  // five cents apart only line up again after hundreds of cycles, which is why the first
  // design gave each oscillator its own keygroup. So the loop is as long as it needs to
  // be: the shortest, up to about two and a half seconds, in which every oscillator lands
  // within a cent of its setting (the S950 itself tunes in 6.25-cent steps). The beating
  // of a detune is then baked into the loop, as it would be in a sample of the real thing.
  //
  // A sweep keeps its speed as nearly as whole round trips allow.
  //
  TMixPlan = record
    Rate: Integer;                   // the sample rate the mix is drawn at
    Words: Integer;                  // the loop's length
    RootCycles: Integer;             // cycles of middle C in it - the sample's pitch
    Oscs: TIntegerArray;             // which oscillators are in it, 0..2
    Cycles: TIntegerArray;           // each one's whole cycles in the loop
    SweepTrips: TIntegerArray;       // each one's sweep round trips in the loop
    ErrorCents: TDoubleArray;        // how far each one lands from its setting
    procedure Init;
  end;

function PlanMix(const Recipe: TRecipe): TMixPlan;

/// The oscillators as one looped sample, cached; `plan` says how it was drawn.
function MixedWave(const Recipe: TRecipe; Cache: TWaveCache; var Plan: TMixPlan): TSmallIntArray;

const
  /// The name the mix is written under.
  MixSampleName = 'OSC MIX';

/// Whether `disk` holds the recipe's programme in the old layout, one keygroup per
/// oscillator - a disk from before the mix, which a load renders again.
function HasSeparateOscillators(const Recipe: TRecipe; Disk: TS950Disk): Boolean;

/// The recipe as a disk. `previous` is the disk this replaces, for the settings it keeps.
/// (Previous may be nil. Out_ is the caller's, and is changed only on success.)
function Render(const Recipe: TRecipe; Cache: TWaveCache; Previous: TS950Disk; Out_: TS950Disk;
                var Error: string): Boolean;

//
// Whether `disk` was rendered from `recipe` before v0.5.0 fixed how a zone's tuning is
// written: some oscillator's transpose and fine hold exactly what the old writer put
// there (whole semitones plus 256ths) for a setting where that differs from the right
// bytes (sixteenths) - and none holds anything else. Such a disk plays detuned, and
// rendering it again from the recipe corrects it without touching the settings a render
// keeps. A tuning set by hand on the Program tab matches neither, so it is left alone.
//
function HasOldTuning(const Recipe: TRecipe; Disk: TS950Disk): Boolean;

/// The recipe as text and back, for the plugin's saved state. One line, key=value pairs.
function ToText(const R: TRecipe): string;
function FromText(const Text: string): TRecipe;

implementation

uses
  S950Cal;

// ------------------------------------------------------------------ the kinds

function OscKindName(K: TOscKind): string;
begin
  case K of
    okOff:          Result := 'Off';
    okSine:         Result := 'Sine';
    okTriangle:     Result := 'Triangle';
    okSaw:          Result := 'Saw';
    okSquare:       Result := 'Square';
    okPulse:        Result := 'Pulse';
    okOrgan:        Result := 'Organ';
    okGlass:        Result := 'Glass';
    okBuzz:         Result := 'Buzz';
    okHollow:       Result := 'Hollow';
    okFm1:          Result := 'FM 1:1';
    okFm2:          Result := 'FM 1:2';
    okFmBell:       Result := 'FM bell';
    okRing2:        Result := 'Ring x2';
    okRing3:        Result := 'Ring x3';
    okBent:         Result := 'Bent';
    okPhaseDistort: Result := 'Phase dist';
    okNoiseWhite:   Result := 'White noise';
    okNoisePink:    Result := 'Pink noise';
    okNoiseBrown:   Result := 'Brown noise';
  else
    Result := '?';
  end;
end;

function Labels(const Intensity, Sweep: string; HasIntensity, HasSweep: Boolean): TOscKindLabels;
begin
  Result.Intensity := Intensity;
  Result.Sweep := Sweep;
  Result.HasIntensity := HasIntensity;
  Result.HasSweep := HasSweep;
end;

function OscKindLabels(K: TOscKind): TOscKindLabels;
begin
  case K of
    okOff:          Result := Labels('', '', False, False);
    okPulse:        Result := Labels('Width',  'PWM',   True, True);
    okFm1,
    okFm2,
    okFmBell:       Result := Labels('Index',  'Sweep', True, True);
    okRing2,
    okRing3:        Result := Labels('Ring',   'Sweep', True, True);
    okBent:         Result := Labels('Bend',   'Sweep', True, True);
    okPhaseDistort: Result := Labels('Skew',   'Sweep', True, True);
    okNoiseWhite,
    okNoisePink,
    okNoiseBrown:   Result := Labels('', '', False, False);
  else
    Result := Labels('Soften', 'Sweep', True, True);   // a morph toward a sine
  end;
end;

// ------------------------------------------------------------------ the drums

type
  TDrumRow = record
    KitName: string;
    Note: Integer;
    Label_: string;
  end;

const
  // Which drum of the kit each slot plays, on General MIDI's note for it.
  DrumRows: array[0..DrumSlotCount - 1] of TDrumRow =
  (
    (KitName: 'KICK 1';     Note: 36; Label_: 'Kick'),
    (KitName: 'SNARE 1';    Note: 38; Label_: 'Snare'),
    (KitName: 'CLAP';       Note: 39; Label_: 'Clap'),
    (KitName: 'HAT CLOSED'; Note: 42; Label_: 'Hat cl'),
    (KitName: 'HAT OPEN';   Note: 46; Label_: 'Hat op'),
    (KitName: 'RIDE';       Note: 51; Label_: 'Ride'),
    (KitName: 'TOM LO';     Note: 41; Label_: 'Tom lo'),
    (KitName: 'TOM MID';    Note: 43; Label_: 'Tom mid'),
    (KitName: 'TOM HI';     Note: 45; Label_: 'Tom hi')
  );

// The drum of the kit with this name, as an index into it, or -1 (the C++'s nullptr).
function KitDrum(const Kit: TDrumArray; const Name: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(Kit) do
    if Kit[I].Name = Name then
      Exit(I);
  Result := -1;
end;

function DrumSlotName(D: TDrumSlot): string;
begin
  Result := DrumRows[Ord(D)].Label_;
end;

function DrumSlotNote(D: TDrumSlot): Integer;
begin
  Result := DrumRows[Ord(D)].Note;
end;

procedure TOscSettings.Init;
begin
  Kind      := okOff;
  Level     := 99;
  Octave    := 0;
  Fine      := 0;
  Phase     := 0;
  Intensity := 50;
  Sweep     := 0;
end;

procedure TDrumSettings.Init;
begin
  On_   := True;
  Tune  := 0;
  Decay := 99;
  Tone  := 99;
  Level := 0;
end;

procedure TRecipe.Init;
var
  I: Integer;
begin
  Name := 'SYNTH';
  for I := 0 to 2 do Osc[I].Init;
  DrumsOn := False;
  for I := 0 to DrumSlotCount - 1 do Drums[I].Init;
  Filter := 78; KeyTrack := 50; VelFilter := 40;
  A := 0; D := 30; S := 88; R := 28;
  VcfA := 0; VcfD := 45; VcfS := 40; VcfR := 0; VcfAmount := 12;
  VelLoudness := 30;
  LfoRate := 45; LfoDepth := 4; LfoDelay := 70;
end;

function TRecipe.AnyOscillator: Boolean;
var
  I: Integer;
begin
  for I := 0 to 2 do
    if Osc[I].Kind <> okOff then
      Exit(True);
  Result := False;
end;

function NewRecipe: TRecipe;
begin
  Result.Init;
end;

procedure TMixPlan.Init;
begin
  Rate := 0;
  Words := 0;
  RootCycles := 0;
  Oscs := nil;
  Cycles := nil;
  SweepTrips := nil;
  ErrorCents := nil;
end;

// ------------------------------------------------------------------ the cache

function TWaveCache.Search(const Key: string; out Index: Integer): Boolean;
var
  Lo, Hi, Mid, C: Integer;
begin
  Lo := 0;
  Hi := FCount - 1;
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) div 2;
    C := CompareStr(FKeys[Mid], Key);
    if C = 0 then
    begin
      Index := Mid;
      Exit(True);
    end;
    if C < 0 then Lo := Mid + 1 else Hi := Mid - 1;
  end;
  Index := Lo;
  Result := False;
end;

function TWaveCache.Count: Integer;
begin
  Result := FCount;
end;

function TWaveCache.Key(Index: Integer): string;
begin
  Result := FKeys[Index];
end;

function TWaveCache.Words(Index: Integer): TSmallIntArray;
begin
  Result := FWaves[Index];
end;

function TWaveCache.TryGet(const Key: string; out Words: TSmallIntArray): Boolean;
var
  I: Integer;
begin
  Result := Search(Key, I);
  if Result then Words := FWaves[I] else Words := nil;
end;

function TWaveCache.Put(const Key: string; const Words: TSmallIntArray): TSmallIntArray;
var
  I, J: Integer;
begin
  if Search(Key, I) then
    Exit(FWaves[I]);
  if FCount = Length(FKeys) then
  begin
    SetLength(FKeys, FCount * 2 + 16);
    SetLength(FWaves, FCount * 2 + 16);
  end;
  for J := FCount downto I + 1 do
  begin
    FKeys[J] := FKeys[J - 1];
    FWaves[J] := FWaves[J - 1];
  end;
  FKeys[I] := Key;
  FWaves[I] := Words;
  Inc(FCount);
  Result := Words;
end;

procedure TWaveCache.Clear;
begin
  FKeys := nil;
  FWaves := nil;
  FCount := 0;
end;

function ToSmallInts(const W: TWords12): TSmallIntArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(W));
  for I := 0 to High(W) do Result[I] := W[I];
end;

// ------------------------------------------------------------------ the waves

function PlainShape(K: TOscKind): IHarmonic;
begin
  case K of
    okSine:     Result := ShapeSine;
    okTriangle: Result := ShapeTriangle;
    okSquare:   Result := ShapeSquare;
    okOrgan:    Result := ShapeOrgan;
    okGlass:    Result := ShapeGlass;
    okBuzz:     Result := ShapeBuzz;
    okHollow:   Result := ShapeHollow;
  else
    Result := ShapeSaw;
  end;
end;

//
// One spectrum of a kind at an intensity 0..1. The sweep is a table of these at
// intensities from `full` down toward nothing and back, so "sweep" means the same
// thing whatever the kind: how far the wave travels from what the intensity knob set.
//
function SpectrumFor(K: TOscKind; X: Double; H: Integer): TSpectrum;
begin
  case K of
    okPulse:        Result := ModPulse(0.5 - 0.45 * X, H);
    okFm1:          Result := ModFm(1, 8.0 * X, H);
    okFm2:          Result := ModFm(2, 6.0 * X, H);
    okFmBell:       Result := ModFm(7, 5.0 * X, H);
    okRing2:        Result := SpectrumBlend(SpectrumFromShape(ShapeSaw, H),
                                            ModRing(ShapeSaw, 24, 2, H), X);
    okRing3:        Result := SpectrumBlend(SpectrumFromShape(ShapeSaw, H),
                                            ModRing(ShapeSaw, 24, 3, H), X);
    okBent:         Result := ModBent(ShapeSaw, 24, 2.5 * X, H);
    okPhaseDistort: Result := ModPhaseDistort(ShapeSine, 1, 0.5 - 0.44 * X, H);
  else
    // the plain shapes soften toward a sine as the intensity rises
    Result := SpectrumBlend(SpectrumFromShape(PlainShape(K), H),
                            SpectrumFromShape(ShapeSine, H), X);
  end;
end;

function IsNoise(K: TOscKind): Boolean;
begin
  Result := (K = okNoiseWhite) or (K = okNoisePink) or (K = okNoiseBrown);
end;

/// The rate a kind is drawn at: the plain shapes at 40 kHz, anything that sweeps or
/// is analysed at 20 kHz over more cycles, as the C# tool's library does.
function RateFor(K: TOscKind; Sweeping: Boolean): Integer;
begin
  if IsNoise(K) then Exit(20000);
  if Sweeping then Exit(20000);
  case K of
    okPulse, okFm1, okFm2, okFmBell,
    okRing2, okRing3, okBent, okPhaseDistort:
      Result := 20000;
  else
    Result := 40000;
  end;
end;

function Sweeps(const O: TOscSettings): Boolean;
begin
  Result := (O.Sweep > 0) and OscKindLabels(O.Kind).HasSweep;
end;

type
  // The lambda tableFor hands waveforms::steps.
  TSweepStep = class(TInterfacedObject, ISpectrumAt)
    FKind: TOscKind;
    FX, FDepth: Double;
    FH: Integer;
    function At(T: Double): TSpectrum;
  end;

function TSweepStep.At(T: Double): TSpectrum;
begin
  Result := SpectrumFor(FKind, FX * (1.0 - FDepth * T), FH);
end;

//
// What an oscillator is made of, as a table of spectra up to harmonic `h`: one for a
// still wave, a round trip through five for one that sweeps. Shared by the single
// wave below and the mix, so the two cannot come to mean different things.
//
function TableFor(const O: TOscSettings; H: Integer): TSpectrumArray;
var
  X: Double;
  Colour: TNoiseColour;
  Step: TSweepStep;
  Hold: ISpectrumAt;  // the reference that counts: a const interface parameter takes none
begin
  X := O.Intensity / 99.0;
  Result := nil;

  if IsNoise(O.Kind) then
  begin
    if O.Kind = okNoiseWhite then Colour := ncWhite
    else if O.Kind = okNoisePink then Colour := ncPink
    else Colour := ncBrown;
    SetLength(Result, 1);
    Result[0] := NoiseSpectrum(Colour, 101, H);
    Exit;
  end;

  if Sweeps(O) then
  begin
    // From the intensity set down toward nothing, by the sweep amount, and back.
    Step := TSweepStep.Create;
    Step.FKind := O.Kind;
    Step.FX := X;
    Step.FDepth := O.Sweep / 99.0;
    Step.FH := H;
    Hold := Step;
    Result := Mirror(Steps(5, Hold));
    Exit;
  end;

  SetLength(Result, 1);
  Result[0] := SpectrumFor(O.Kind, X, H);
end;

function DrawWave(const O: TOscSettings): TSmallIntArray;
var
  Sweeping: Boolean;
  Rate, H, Cycles, By, Size, I: Integer;
  Table: TSpectrumArray;
  Words: TWords12;
begin
  Sweeping := Sweeps(O);
  Rate     := RateFor(O.Kind, Sweeping);
  H        := HighestHarmonic(Rate, RootHz);
  Table    := TableFor(O, H);

  if IsNoise(O.Kind) then Cycles := 32
  else if Sweeping or (Rate <> 40000) then Cycles := 96
  else Cycles := PlainCycles;

  Words := WaveRender(Table, Cycles, Rate, RootHz);
  Size := Length(Words);
  Result := nil;
  SetLength(Result, Size);

  // The start phase: a looped wave rotated is the same wave started elsewhere.
  if (O.Phase > 0) and (Size > 0) then
  begin
    By := LRound(O.Phase / 99.0 * Size) mod Size;
    for I := 0 to Size - 1 do Result[I] := Words[(I + By) mod Size];
  end
  else
    for I := 0 to Size - 1 do Result[I] := Words[I];
end;

function WaveKey(const O: TOscSettings): string;
begin
  Result := IntToStr(Ord(O.Kind)) + '|' + IntToStr(O.Intensity) + '|'
          + IntToStr(O.Sweep) + '|' + IntToStr(O.Phase);
end;

function DrumKey(const KitName: string): string;
begin
  Result := 'drum|' + KitName;
end;

function OscillatorWave(const O: TOscSettings; Cache: TWaveCache): TSmallIntArray;
var
  Key: string;
begin
  Key := WaveKey(O);
  if not Cache.TryGet(Key, Result) then
    Result := Cache.Put(Key, DrawWave(O));
end;

// ------------------------------------------------------------------ the mix

/// How far above middle C an oscillator sounds: its octave and its fine tune.
function RatioOf(const O: TOscSettings): Double;
begin
  // std::pow (2.0, ...), which clang makes exp2
  Result := Exp2D(O.Octave + MaxI(-50, MinI(50, O.Fine)) / 1200.0);
end;

const
  /// A sweep's round trip, in cycles of the oscillator - what the single wave used.
  SweepCycles = 96;

  /// The longest loop the mix may take, in cycles of middle C: about 2.5 seconds.
  MaxRootCycles = 654;

  /// How close to its setting an oscillator must land, in cents.
  CentsTolerance = 1.0;

procedure PushInt(var A: TIntegerArray; V: Integer);
begin
  SetLength(A, Length(A) + 1);
  A[High(A)] := V;
end;

procedure PushDouble(var A: TDoubleArray; V: Double);
begin
  SetLength(A, Length(A) + 1);
  A[High(A)] := V;
end;

function PlanMix(const Recipe: TRecipe): TMixPlan;
var
  Shortest, I, K, N, Best, Got: Integer;
  BestWorst, Worst, Want, GotD, SweepD: Double;
begin
  Result.Init;
  Result.Rate := 40000;

  Shortest := 1;
  for I := 0 to 2 do
  begin
    if Recipe.Osc[I].Kind = okOff then Continue;

    PushInt(Result.Oscs, I);
    Result.Rate := MinI(Result.Rate, RateFor(Recipe.Osc[I].Kind, Sweeps(Recipe.Osc[I])));

    // A sweeping oscillator needs the loop to hold at least one round trip of it.
    if Sweeps(Recipe.Osc[I]) then
      Shortest := MaxI(Shortest, Trunc(CeilD(SweepCycles / RatioOf(Recipe.Osc[I]))));
  end;

  if Length(Result.Oscs) = 0 then Exit;

  //
  // The shortest loop in which every oscillator's cycles come out whole and within the
  // tolerance - or, if none does within the limit, the one that comes closest. Four
  // cycles of middle C at least, which is where the two octaves down land whole.
  //
  Best := -1;
  BestWorst := 1e9;

  for N := MaxI(4, Shortest) to MaxRootCycles do
  begin
    Worst := 0.0;
    for K := 0 to High(Result.Oscs) do
    begin
      Want := N * RatioOf(Recipe.Osc[Result.Oscs[K]]);
      GotD := MaxD(1.0, RoundD(Want));
      Worst := MaxD(Worst, Abs(1200.0 * Log2D(GotD / Want)));
    end;

    if Worst < BestWorst then begin BestWorst := Worst; Best := N; end;
    if Worst <= CentsTolerance then Break;
  end;

  Result.RootCycles := Best;
  Result.Words      := WordsFor(Best, Result.Rate, RootHz);

  for K := 0 to High(Result.Oscs) do
  begin
    I := Result.Oscs[K];
    Want := Best * RatioOf(Recipe.Osc[I]);
    Got  := MaxI(1, LRound(Want));

    PushInt(Result.Cycles, Got);
    PushDouble(Result.ErrorCents, 1200.0 * Log2D(Got / Want));
    if Sweeps(Recipe.Osc[I]) then
    begin
      SweepD := SweepCycles;
      PushInt(Result.SweepTrips, MaxI(1, LRound(Got / SweepD)));
    end
    else
      PushInt(Result.SweepTrips, 0);
  end;
end;

/// Harmonic n of a table at position t (0..1 around the round trip), as the single
/// wave's renderer reads it: smoothstep between neighbouring spectra, wrapping.
procedure HarmonicAt(const Table: TSpectrumArray; N: Integer; T: Double; out C, S: Double);

  procedure Coef(const Sp: TSpectrum; out CC, SS: Double);
  begin
    if N <= Sp.Harmonics then CC := Sp.Cos[N] else CC := 0.0;
    if N <= Sp.Harmonics then SS := Sp.Sin[N] else SS := 0.0;
  end;

var
  Pos, Frac, M, Ac, As_, Bc, Bs: Double;
  Ix, Size: Integer;
begin
  if Length(Table) = 1 then
  begin
    Coef(Table[0], C, S);
    Exit;
  end;

  Size := Length(Table);
  Pos  := T * Size;
  Ix   := Trunc(Pos);
  Frac := Pos - Ix;
  M    := Frac * Frac * (3.0 - 2.0 * Frac);

  Coef(Table[Ix mod Size], Ac, As_);
  Coef(Table[(Ix + 1) mod Size], Bc, Bs);
  C := Ac * (1 - M) + Bc * M;
  S := As_ * (1 - M) + Bs * M;
end;

//
// One oscillator across the whole loop, additively: harmonic by harmonic, each turned
// by a rotating phasor rather than a cosine a sample - a loop of seconds times dozens
// of harmonics is millions of samples, and a rotation is a multiply. Renormalised
// every so often so rounding cannot shrink or swell it over the length.
//
function DrawInMix(const O: TOscSettings; Cycles, Trips, Words, Rate: Integer): TDoubleArray;
const
  Pi = 3.14159265358979323846;
var
  Hz, Start, Step, Rc, Rs, Pc, Ps, C, S, T, Nc, Len, Peak, DWords, DRate: Double;
  H, N, I, K: Integer;
  Table: TSpectrumArray;
  Used: Boolean;
begin
  // this oscillator's own pitch, with the sample at its root: its cycles in the loop
  // over the loop's length - which sets how many harmonics fit below the Nyquist
  DRate := Rate;
  DWords := Words;
  Hz := Cycles * DRate / Words;
  H  := HighestHarmonic(Rate, Hz);
  Table := TableFor(O, H);

  Start := O.Phase / 99.0 * 2.0 * Pi;    // where in its cycle it begins

  Result := nil;
  SetLength(Result, Words);
  for I := 0 to Words - 1 do Result[I] := 0.0;

  for N := 1 to H do
  begin
    Used := False;
    for K := 0 to High(Table) do
      if (N <= Table[K].Harmonics) and ((Table[K].Cos[N] <> 0.0) or (Table[K].Sin[N] <> 0.0)) then
      begin
        Used := True;
        Break;
      end;
    if not Used then Continue;

    Step := 2.0 * Pi * N * Cycles / DWords;
    Rc := CosD(Step);
    Rs := SinD(Step);
    Pc := CosD(N * Start);
    Ps := SinD(N * Start);

    C := 0.0;
    S := 0.0;
    if Length(Table) = 1 then HarmonicAt(Table, N, 0.0, C, S);

    for I := 0 to Words - 1 do
    begin
      if Length(Table) > 1 then
      begin
        T := Trips * (I / DWords);
        T := T - FloorD(T);
        HarmonicAt(Table, N, T, C, S);
      end;

      Result[I] := Result[I] + (C * Pc + S * Ps);

      Nc := Pc * Rc - Ps * Rs;
      Ps := Pc * Rs + Ps * Rc;
      Pc := Nc;

      if (I and 1023) = 1023 then
      begin
        Len := Sqrt(Pc * Pc + Ps * Ps);
        Pc := Pc / Len;
        Ps := Ps / Len;
      end;
    end;
  end;

  // Each oscillator at full scale before its level, as each one's own sample was.
  Peak := 0.0;
  for I := 0 to Words - 1 do Peak := MaxD(Peak, Abs(Result[I]));
  if Peak > 0.0 then for I := 0 to Words - 1 do Result[I] := Result[I] / Peak;
end;

function MixKey(const R: TRecipe): string;
var
  I: Integer;
begin
  Result := 'mix';
  for I := 0 to 2 do
  begin
    if R.Osc[I].Kind = okOff then Continue;
    Result := Result + '|' + IntToStr(I) + ':' + WaveKey(R.Osc[I]) + ':' + IntToStr(R.Osc[I].Octave)
            + ':' + IntToStr(R.Osc[I].Fine) + ':' + IntToStr(R.Osc[I].Level);
  end;
end;

function MixedWave(const Recipe: TRecipe; Cache: TWaveCache; var Plan: TMixPlan): TSmallIntArray;
var
  Key: string;
  Mix, One: TDoubleArray;
  K, I, Units: Integer;
  Gain: Double;
begin
  Plan := PlanMix(Recipe);

  Key := MixKey(Recipe);
  if Cache.TryGet(Key, Result) then Exit;

  SetLength(Mix, MaxI(0, Plan.Words));
  for I := 0 to High(Mix) do Mix[I] := 0.0;

  for K := 0 to High(Plan.Oscs) do
  begin
    // The level knob as it always sounded: the zone loudness it used to write, in
    // the machine's own decibels a unit - 99 is full, 0 is twenty decibels down.
    Units := -50 + (MaxI(0, MinI(99, Recipe.Osc[Plan.Oscs[K]].Level)) * 50) div 99;
    Gain  := PowD(10.0, Units * LoudnessDbPerUnit / 20.0);

    One := DrawInMix(Recipe.Osc[Plan.Oscs[K]], Plan.Cycles[K], Plan.SweepTrips[K], Plan.Words, Plan.Rate);
    for I := 0 to High(Mix) do Mix[I] := Mix[I] + One[I] * Gain;
  end;

  Result := Cache.Put(Key, ToSmallInts(Quantise(Mix)));
end;

// ----------------------------------------------------------------- rendering

function RateForTune(Rate, Tune: Integer): Integer;
var
  Scaled: Double;
begin
  Scaled := Rate * Exp2D(Tune / 12.0);     // std::pow (2.0, ...), which clang makes exp2
  Result := LRound(MinD(48000.0, MaxD(4000.0, Scaled)));
end;

/// The keygroup of `program` whose soft zone plays `sample`, or -1.
function KeygroupPlaying(D: TS950Disk; const Prog: TDiskEntry; const Sample: string): Integer;
var
  Groups: TDiskKeygroupArray;
  K: Integer;
begin
  Groups := D.Keygroups(Prog);
  for K := 0 to High(Groups) do
    if Groups[K].Zone1.Name = Sample then
      Exit(K);
  Result := -1;
end;

procedure Put(D: TS950Disk; const P: TDiskEntry; K: Integer; Param: TKeygroupParam; Value: Integer);
begin
  D.SetKeygroupParam(P, K, Param, Value);
end;

type
  TLayer = record
    Sample: string;
    Drum: Boolean;
    Osc: Integer;
    Slot: Integer;
  end;

const
  Kept: array[0..26] of TKeygroupParam = (
    kpVelocitySwitch, kpVcaAttack, kpVcaDecay, kpVcaSustain, kpVcaRelease,
    kpVelToFilter, kpKeyToFilter, kpVelToAttack, kpVelToRelease, kpVelToLoudness,
    kpWarpVelocity, kpWarpDepth, kpWarpTime,
    kpLfoDelay, kpLfoRate, kpLfoDepth, kpLfoAftertouch, kpLfoModwheel,
    kpOutputPort, kpVcfAmount, kpVcfAttack, kpVcfDecay, kpVcfSustain, kpVcfRelease,
    kpZone1Filter, kpLfoDesync, kpVelocityReleaseOn
  );

  OldOscNames: array[0..2] of string = ('OSC1', 'OSC2', 'OSC3');

function Render(const Recipe: TRecipe; Cache: TWaveCache; Previous: TS950Disk; Out_: TS950Disk;
                var Error: string): Boolean;
var
  D: TS950Disk;
  Kit: TDrumArray;
  Layers: array of TLayer;
  Plan: TMixPlan;
  S: TNewSample;
  E, WantName: string;
  Slot, Drum, K, From, I, Note: Integer;
  Words: TSmallIntArray;
  Prog, WasEntry: TDiskEntry;
  HaveProg, HaveWas: Boolean;
  SynthLow: Integer;
  Layer: TLayer;

  procedure AddLayer(const ASample: string; ADrum: Boolean; AOsc, ASlot: Integer);
  begin
    SetLength(Layers, Length(Layers) + 1);
    Layers[High(Layers)].Sample := ASample;
    Layers[High(Layers)].Drum := ADrum;
    Layers[High(Layers)].Osc := AOsc;
    Layers[High(Layers)].Slot := ASlot;
  end;

begin
  Result := False;
  if (not Recipe.AnyOscillator) and (not Recipe.DrumsOn) then
  begin
    Error := 'nothing to render: every oscillator is off and so are the drums';
    Exit;
  end;

  Layers := nil;
  D := TS950Disk.Blank(Recipe.Name + ' DISK');
  try
    Kit := DrumKit;

    // --- the samples: oscillators, then drums

    // The oscillators, mixed into one looped sample - one keygroup, one voice a note.
    if Recipe.AnyOscillator then
    begin
      Plan.Init;
      S.Init;
      S.Name     := MixSampleName;
      S.Words12  := MixedWave(Recipe, Cache, Plan);
      S.Rate     := Plan.Rate;
      S.RootNote := RootNote;
      S.LoopMode := 'L';

      if not D.AddSample(S, E) then begin Error := E; Exit; end;
      AddLayer(S.Name, False, -1, -1);
    end;

    if Recipe.DrumsOn then
      for Slot := 0 to DrumSlotCount - 1 do
      begin
        if not Recipe.Drums[Slot].On_ then Continue;

        Drum := KitDrum(Kit, DrumRows[Slot].KitName);
        if Drum < 0 then Continue;

        if not Cache.TryGet(DrumKey(Kit[Drum].Name), Words) then
          Words := Cache.Put(DrumKey(Kit[Drum].Name), ToSmallInts(DrumRender(Kit[Drum])));

        S.Init;
        S.Name     := Kit[Drum].Name;
        S.Words12  := Words;
        S.Rate     := RateForTune(Kit[Drum].Rate, Recipe.Drums[Slot].Tune);   // tune is a change of rate: pitch and length together
        S.RootNote := DrumRows[Slot].Note;
        S.LoopMode := 'O';

        if not D.AddSample(S, E) then begin Error := E; Exit; end;
        AddLayer(S.Name, True, -1, Slot);
      end;

    if Length(Layers) = 0 then
    begin
      Error := 'nothing to render';
      Exit;
    end;

    // --- the programme
    if not D.AddProgram(Recipe.Name, Length(Layers), E) then begin Error := E; Exit; end;

    HaveProg := False;
    for I := 0 to High(D.Entries) do
      if D.Entries[I].EntryType = 'P' then
      begin
        Prog := D.Entries[I];
        HaveProg := True;
      end;
    if not HaveProg then begin Error := 'the programme did not read back'; Exit; end;

    HaveWas := False;
    if Previous <> nil then
    begin
      WantName := TS950Disk.NormaliseNameFor(Recipe.Name);
      for I := 0 to High(Previous.Entries) do
        if (Previous.Entries[I].EntryType = 'P') and (Previous.Entries[I].Name = WantName) then
        begin
          WasEntry := Previous.Entries[I];
          HaveWas := True;
        end;
    end;

    if Recipe.DrumsOn then SynthLow := SynthLowKeyWithDrums else SynthLow := SynthLowKey;

    for K := 0 to High(Layers) do
    begin
      Layer := Layers[K];

      // What the recipe starts every keygroup from - then, where the disk being
      // replaced had a keygroup playing this same sample, its settings instead.
      Put(D, Prog, K, kpVcaAttack,  Recipe.A);
      Put(D, Prog, K, kpVcaDecay,   Recipe.D);
      Put(D, Prog, K, kpVcaSustain, Recipe.S);
      Put(D, Prog, K, kpVcaRelease, Recipe.R);
      Put(D, Prog, K, kpVcfAttack,  Recipe.VcfA);
      Put(D, Prog, K, kpVcfDecay,   Recipe.VcfD);
      Put(D, Prog, K, kpVcfSustain, Recipe.VcfS);
      Put(D, Prog, K, kpVcfRelease, Recipe.VcfR);
      Put(D, Prog, K, kpVcfAmount,  Recipe.VcfAmount);
      Put(D, Prog, K, kpKeyToFilter, Recipe.KeyTrack);
      Put(D, Prog, K, kpVelToFilter, Recipe.VelFilter);
      Put(D, Prog, K, kpVelToLoudness, Recipe.VelLoudness);
      Put(D, Prog, K, kpLfoRate,  Recipe.LfoRate);
      Put(D, Prog, K, kpLfoDepth, Recipe.LfoDepth);
      Put(D, Prog, K, kpLfoDelay, Recipe.LfoDelay);
      Put(D, Prog, K, kpLfoModwheel, 50);
      Put(D, Prog, K, kpLfoDesync, 1);
      Put(D, Prog, K, kpZone1Filter, Recipe.Filter);

      if HaveWas then
      begin
        // A disk from before the mix had a keygroup per oscillator: the mix takes its
        // settings from the first of those, so a Program tab edit survives the move.
        From := KeygroupPlaying(Previous, WasEntry, Layer.Sample);
        if (From < 0) and not Layer.Drum then
          for I := 0 to 2 do
          begin
            From := KeygroupPlaying(Previous, WasEntry, OldOscNames[I]);
            if From >= 0 then Break;
          end;

        if From >= 0 then
          for I := 0 to High(Kept) do
            Put(D, Prog, K, Kept[I], Previous.GetKeygroupParam(WasEntry, From, Kept[I]));
      end;

      D.SetZoneSample(Prog, K, 0, Layer.Sample);

      if not Layer.Drum then
      begin
        Put(D, Prog, K, kpLowKey,  SynthLow);
        Put(D, Prog, K, kpHighKey, 127);
        Put(D, Prog, K, kpConstantPitch, 0);
        Put(D, Prog, K, kpOneShot, 0);

        // Octave, fine and level are in the mix itself now - the zone plays it as is.
        Put(D, Prog, K, kpZone1Transpose, 0);
        Put(D, Prog, K, kpZone1Fine,      0);
        Put(D, Prog, K, kpZone1Loudness,  0);
      end
      else
      begin
        Drum := KitDrum(Kit, DrumRows[Layer.Slot].KitName);
        Note := DrumRows[Layer.Slot].Note;

        Put(D, Prog, K, kpLowKey,  Note);
        Put(D, Prog, K, kpHighKey, Note);
        Put(D, Prog, K, kpConstantPitch, 1);
        Put(D, Prog, K, kpOneShot, 1);
        Put(D, Prog, K, kpZone1Transpose, 0);
        Put(D, Prog, K, kpZone1Fine, 0);

        // The recipe's drum knobs own these four, whatever the Program tab said.
        with Recipe.Drums[Layer.Slot] do
        begin
          Put(D, Prog, K, kpVcaAttack,  0);
          if Decay >= 99 then Put(D, Prog, K, kpVcaDecay, 99) else Put(D, Prog, K, kpVcaDecay, Decay);
          if Decay >= 99 then Put(D, Prog, K, kpVcaSustain, 99) else Put(D, Prog, K, kpVcaSustain, 0);
          Put(D, Prog, K, kpZone1Filter, Tone);
          if Drum >= 0 then
            Put(D, Prog, K, kpZone1Loudness, Kit[Drum].Loudness + Level)
          else
            Put(D, Prog, K, kpZone1Loudness, 0 + Level);
        end;
        if (not HaveWas) or (KeygroupPlaying(Previous, WasEntry, Layer.Sample) < 0) then
        begin
          Put(D, Prog, K, kpVcaRelease, 20);
          Put(D, Prog, K, kpKeyToFilter, 0);
          Put(D, Prog, K, kpVelToFilter, 0);
          if Drum >= 0 then Put(D, Prog, K, kpVelToLoudness, Kit[Drum].Vel)
          else Put(D, Prog, K, kpVelToLoudness, 30);
          Put(D, Prog, K, kpVcfAmount, 0);
          Put(D, Prog, K, kpLfoDepth, 0);
        end;
      end;
    end;

    D.RebuildPointers;
    Out_.Assign(D);
    Result := True;
  finally
    D.Free;
  end;
end;

// ------------------------------------------------------------------ presets

function Make(const Name: string; const Oscs: array of TOscSettings): TRecipe;
var
  I: Integer;
begin
  Result.Init;
  Result.Name := Name;
  I := 0;
  while (I < 3) and (I < Length(Oscs)) do
  begin
    Result.Osc[I] := Oscs[I];
    Inc(I);
  end;
end;

function Osc(Kind: TOscKind; Level: Integer = 99; Octave: Integer = 0; Fine: Integer = 0;
             Intensity: Integer = 50; Sweep: Integer = 0; Phase: Integer = 0): TOscSettings;
begin
  Result.Init;
  Result.Kind := Kind; Result.Level := Level; Result.Octave := Octave; Result.Fine := Fine;
  Result.Intensity := Intensity; Result.Sweep := Sweep; Result.Phase := Phase;
end;

var
  GPresets: TPresetArray;

procedure AddPreset(const Name: string; const R: TRecipe);
begin
  SetLength(GPresets, Length(GPresets) + 1);
  GPresets[High(GPresets)].Name := Name;
  GPresets[High(GPresets)].Recipe := R;
end;

procedure BuildPresets;
var
  R: TRecipe;
begin
  GPresets := nil;

  R := Make('INIT', [Osc(okSaw, 99, 0, 0, 0, 0)]);
  AddPreset('Init: one saw', R);

  R := Make('FAT SAW', [Osc(okSaw, 99, 0, -4, 0, 0), Osc(okSaw, 99, 0, 4, 0, 0, 30)]);
  R.Filter := 72; R.A := 2; R.D := 40; R.S := 80; R.R := 35; R.VcfAmount := 10; R.VcfD := 50; R.VcfS := 45; R.VelFilter := 35;
  AddPreset('Fat saw lead', R);

  R := Make('SQ BASS', [Osc(okSquare, 99, 0, 0, 0, 0), Osc(okSine, 70, -1, 0, 0, 0)]);
  R.Filter := 48; R.KeyTrack := 30; R.A := 0; R.D := 38; R.S := 20; R.R := 18;
  R.VcfAmount := 22; R.VcfD := 30; R.VcfS := 10; R.VelFilter := 50; R.VelLoudness := 45; R.LfoDepth := 0;
  AddPreset('Square bass', R);

  R := Make('PWM STRGS', [Osc(okPulse, 99, 0, -5, 40, 70), Osc(okPulse, 99, 0, 5, 40, 70, 50)]);
  R.Filter := 68; R.A := 30; R.D := 55; R.S := 88; R.R := 55; R.VcfAmount := 12; R.VcfA := 25; R.VcfD := 60; R.VcfS := 60;
  R.LfoRate := 38; R.LfoDepth := 6; R.LfoDelay := 75;
  AddPreset('PWM strings', R);

  R := Make('SWEEP PAD', [Osc(okSaw, 99, 0, -4, 70, 90), Osc(okSaw, 85, 1, 5, 70, 90, 40)]);
  R.Filter := 62; R.A := 45; R.D := 60; R.S := 85; R.R := 62; R.VcfAmount := 8; R.VcfA := 50; R.VcfD := 70; R.VcfS := 70;
  R.LfoRate := 30; R.LfoDepth := 5; R.LfoDelay := 80;
  AddPreset('Sweep pad', R);

  R := Make('FM EPIANO', [Osc(okFm1, 99, 0, 0, 55, 60)]);
  R.Filter := 84; R.A := 0; R.D := 48; R.S := 30; R.R := 34; R.VcfAmount := 0; R.VelLoudness := 55; R.VelFilter := 30; R.LfoDepth := 0;
  AddPreset('FM e-piano', R);

  R := Make('FM BELL', [Osc(okFmBell, 99, 0, 0, 60, 70), Osc(okSine, 60, 1, 0, 0, 0)]);
  R.Filter := 88; R.A := 0; R.D := 62; R.S := 0; R.R := 58; R.VcfAmount := 0; R.VelLoudness := 60; R.LfoDepth := 0;
  AddPreset('FM bell', R);

  R := Make('ORGAN', [Osc(okOrgan, 99, 0, 0, 0, 0)]);
  R.Filter := 90; R.KeyTrack := 20; R.A := 0; R.D := 0; R.S := 99; R.R := 8; R.VcfAmount := 0; R.VelLoudness := 10; R.LfoDepth := 0;
  AddPreset('Organ', R);

  R := Make('GLASS BEL', [Osc(okGlass, 99, 0, 0, 0, 0), Osc(okSine, 65, 1, 0, 0, 0)]);
  R.Filter := 86; R.A := 0; R.D := 52; R.S := 0; R.R := 48; R.VcfAmount := 0; R.VelLoudness := 60; R.LfoDepth := 0;
  AddPreset('Glass bell', R);

  R := Make('KIT', [Osc(okSaw, 99, 0, 0, 0, 0)]);
  R.DrumsOn := True;
  R.Filter := 78;
  AddPreset('Drums + saw', R);
end;

function Presets: TPresetArray;
begin
  Result := GPresets;
end;

function HasSeparateOscillators(const Recipe: TRecipe; Disk: TS950Disk): Boolean;
var
  I, K: Integer;
  Groups: TDiskKeygroupArray;
  Want: string;
begin
  Want := TS950Disk.NormaliseNameFor(Recipe.Name);
  for I := 0 to High(Disk.Entries) do
    if (Disk.Entries[I].EntryType = 'P') and (Disk.Entries[I].Name = Want) then
    begin
      Groups := Disk.Keygroups(Disk.Entries[I]);
      for K := 0 to High(Groups) do
        if (Groups[K].Zone1.Name = 'OSC1') or (Groups[K].Zone1.Name = 'OSC2') or (Groups[K].Zone1.Name = 'OSC3') then
          Exit(True);
    end;
  Result := False;
end;

function HasOldTuning(const Recipe: TRecipe; Disk: TS950Disk): Boolean;
var
  Prog: TDiskEntry;
  HaveProg, SawOld: Boolean;
  Want, Name: string;
  Groups: TDiskKeygroupArray;
  I, K, Cents, Fine256, OldHigh, OldLow, Sixteenths, NewHigh, NewLow: Integer;
begin
  HaveProg := False;
  Want := TS950Disk.NormaliseNameFor(Recipe.Name);
  for I := 0 to High(Disk.Entries) do
    if (Disk.Entries[I].EntryType = 'P') and (Disk.Entries[I].Name = Want) then
    begin
      Prog := Disk.Entries[I];
      HaveProg := True;
    end;
  if not HaveProg then Exit(False);

  SawOld := False;

  Groups := Disk.Keygroups(Prog);
  for K := 0 to High(Groups) do
  begin
    Name := Groups[K].Zone1.Name;
    if (Length(Name) <> 4) or (Copy(Name, 1, 3) <> 'OSC') then Continue;
    I := Ord(Name[4]) - Ord('1');
    if (I < 0) or (I > 2) then Continue;

    Cents := MaxI(-50, MinI(50, Recipe.Osc[I].Fine));

    // what the writer put there before v0.5.0: whole semitones, then 256ths upward
    Fine256 := LRound(Abs(Cents) * 2.56);
    if Cents < 0 then OldHigh := Recipe.Osc[I].Octave * 12 - 1 else OldHigh := Recipe.Osc[I].Octave * 12;
    if Cents < 0 then OldLow := 256 - Fine256 else OldLow := Fine256;

    // what it writes now, and what the machine reads: sixteenths, in one number
    Sixteenths := Recipe.Osc[I].Octave * 12 * 16 + LRound(Cents * 16.0 / 100.0);
    if Sixteenths >= 0 then NewHigh := Sixteenths div 256 else NewHigh := -((255 - Sixteenths) div 256);
    NewLow := Sixteenths - NewHigh * 256;

    if (OldHigh = NewHigh) and ((OldLow and $FF) = NewLow) then Continue;     // the same bytes either way

    if (Groups[K].Zone1.Transpose = OldHigh) and (Groups[K].Zone1.Fine = (OldLow and $FF)) then
      SawOld := True
    else if not ((Groups[K].Zone1.Transpose = NewHigh) and (Groups[K].Zone1.Fine = NewLow)) then
      Exit(False);          // tuned by hand: not ours to redo
  end;

  Result := SawOld;
end;

// ---------------------------------------------------------------- as text

function ToText(const R: TRecipe): string;
var
  Name: string;
  I: Integer;
  B: string;
begin
  // Spaces in the name would split the line, so they travel as underscores; an S950
  // name is upper-case letters, digits and spaces, and never had one.
  Name := R.Name;
  for I := 1 to Length(Name) do if Name[I] = ' ' then Name[I] := '_';

  Result := 'name=' + Name;
  for I := 0 to 2 do
    with R.Osc[I] do
      Result := Result + ' o' + IntToStr(I) + '=' + IntToStr(Ord(Kind)) + ',' + IntToStr(Level) + ',' + IntToStr(Octave) + ','
              + IntToStr(Fine) + ',' + IntToStr(Phase) + ',' + IntToStr(Intensity) + ',' + IntToStr(Sweep);
  if R.DrumsOn then Result := Result + ' drums=1' else Result := Result + ' drums=0';
  for I := 0 to DrumSlotCount - 1 do
    with R.Drums[I] do
    begin
      if On_ then B := '1' else B := '0';
      Result := Result + ' d' + IntToStr(I) + '=' + B + ',' + IntToStr(Tune) + ',' + IntToStr(Decay) + ',' + IntToStr(Tone) + ',' + IntToStr(Level);
    end;
  Result := Result + ' voice=' + IntToStr(R.Filter) + ',' + IntToStr(R.KeyTrack) + ',' + IntToStr(R.VelFilter) + ',' + IntToStr(R.A) + ','
          + IntToStr(R.D) + ',' + IntToStr(R.S) + ',' + IntToStr(R.R) + ',' + IntToStr(R.VcfA) + ',' + IntToStr(R.VcfD) + ','
          + IntToStr(R.VcfS) + ',' + IntToStr(R.VcfR) + ',' + IntToStr(R.VcfAmount) + ',' + IntToStr(R.VelLoudness) + ','
          + IntToStr(R.LfoRate) + ',' + IntToStr(R.LfoDepth) + ',' + IntToStr(R.LfoDelay);
end;

// std::isspace in the "C" locale, which is what `in >> item` splits on.
function IsSpace(C: Char): Boolean;
begin
  Result := (C = ' ') or ((C >= #9) and (C <= #13));
end;

// std::atoi as the Universal CRT has it: leading space, a sign, digits, and the first
// thing that is not a digit ends it; out of range saturates, as strtol does.
function AtoI(const S: string): Integer;
var
  I: Integer;
  Neg: Boolean;
  V: Int64;
begin
  I := 1;
  while (I <= Length(S)) and IsSpace(S[I]) do Inc(I);
  Neg := False;
  if (I <= Length(S)) and ((S[I] = '+') or (S[I] = '-')) then
  begin
    Neg := S[I] = '-';
    Inc(I);
  end;
  V := 0;
  while (I <= Length(S)) and (S[I] >= '0') and (S[I] <= '9') do
  begin
    if V <= 4294967296 then V := V * 10 + (Ord(S[I]) - Ord('0'));
    Inc(I);
  end;
  if Neg then V := -V;
  if V > 2147483647 then V := 2147483647;
  if V < -2147483648 then V := -2147483648;
  Result := Integer(V);
end;

// `ints`: the comma-separated numbers std::getline (s, part, ',') reads - no part after
// a trailing comma, none at all from nothing.
function Ints(const V: string): TIntegerArray;
var
  I, Start: Integer;
begin
  Result := nil;
  Start := 1;
  for I := 1 to Length(V) do
    if V[I] = ',' then
    begin
      PushInt(Result, AtoI(Copy(V, Start, I - Start)));
      Start := I + 1;
    end;
  if Start <= Length(V) then PushInt(Result, AtoI(Copy(V, Start, Length(V) - Start + 1)));
end;

function FromText(const Text: string): TRecipe;
var
  P, Start, Eq, I, Kind: Integer;
  Item, Key, Value: string;
  V: TIntegerArray;
begin
  Result.Init;

  P := 1;
  while True do
  begin
    // in >> item
    while (P <= Length(Text)) and IsSpace(Text[P]) do Inc(P);
    if P > Length(Text) then Break;
    Start := P;
    while (P <= Length(Text)) and not IsSpace(Text[P]) do Inc(P);
    Item := Copy(Text, Start, P - Start);

    Eq := Pos('=', Item);
    if Eq = 0 then Continue;
    Key := Copy(Item, 1, Eq - 1);
    Value := Copy(Item, Eq + 1, Length(Item) - Eq);

    if Key = 'name' then
    begin
      Result.Name := Value;
      for I := 1 to Length(Result.Name) do if Result.Name[I] = '_' then Result.Name[I] := ' ';
      Continue;
    end;
    if Key = 'drums' then begin Result.DrumsOn := AtoI(Value) <> 0; Continue; end;

    V := Ints(Value);

    if (Length(Key) = 2) and (Key[1] = 'o') and (Length(V) >= 7) then
    begin
      I := Ord(Key[2]) - Ord('0');
      if (I < 0) or (I > 2) then Continue;
      Kind := MaxI(0, MinI(Ord(okCount) - 1, V[0]));
      Result.Osc[I].Kind := TOscKind(Kind);
      Result.Osc[I].Level := V[1]; Result.Osc[I].Octave := V[2]; Result.Osc[I].Fine := V[3];
      Result.Osc[I].Phase := V[4]; Result.Osc[I].Intensity := V[5]; Result.Osc[I].Sweep := V[6];
    end
    else if (Length(Key) = 2) and (Key[1] = 'd') and (Length(V) >= 5) then
    begin
      I := Ord(Key[2]) - Ord('0');
      if (I < 0) or (I >= DrumSlotCount) then Continue;
      Result.Drums[I].On_ := V[0] <> 0; Result.Drums[I].Tune := V[1]; Result.Drums[I].Decay := V[2];
      Result.Drums[I].Tone := V[3]; Result.Drums[I].Level := V[4];
    end
    else if (Key = 'voice') and (Length(V) >= 16) then
    begin
      Result.Filter := V[0]; Result.KeyTrack := V[1]; Result.VelFilter := V[2]; Result.A := V[3]; Result.D := V[4]; Result.S := V[5]; Result.R := V[6];
      Result.VcfA := V[7]; Result.VcfD := V[8]; Result.VcfS := V[9]; Result.VcfR := V[10]; Result.VcfAmount := V[11];
      Result.VelLoudness := V[12]; Result.LfoRate := V[13]; Result.LfoDepth := V[14]; Result.LfoDelay := V[15];
    end;
  end;
end;

initialization
  BuildPresets;

end.
