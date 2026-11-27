// Mz950 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Plugin/Source/S950/Voice.h and Voice.cpp. Renders the same samples
// as the C++, bit for bit (verify\build_verify.cmd checks it); see S950Math for how.

unit S950Voice;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$MINFPCONSTPREC 64}   // a real literal is a double, as in C++ (1.0 would otherwise be a Single)
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  S950Math, S950Cal, S950Filter, S950Patch;

type
  TSampleBuffer = array[0..MaxInt div SizeOf(Single) - 1] of Single;
  PSampleBuffer = ^TSampleBuffer;

  //
  // The player's controls, sitting on top of whatever the programme says.
  //
  // Every one is an OFFSET in the panel's own units, and every one is zero by default, so
  // a programme plays exactly as the disk describes it until something is moved. That is
  // the whole point of an instrument built around a floppy: an absolute control would
  // flatten a programme's keygroups to one value the moment it was touched, where an
  // offset moves the shape and keeps it.
  //
  // The times and sustains are added to a stored 0..99 and clamped back into it; the
  // filter amount is added to a signed -50..+50.
  //
  //
  TTrims = record
    Cutoff, Amount: Double;
    VcaAttack, VcaDecay, VcaSustain, VcaRelease: Double;
    VcfAttack, VcfDecay, VcfSustain, VcfRelease: Double;
    LfoRate, LfoDepth, LfoDelay: Double;
    VelToFilter, VelToLoudness: Double;

    // 0..100, and not an offset: the S950's filter has no resonance for it to be offset
    // from. See Butterworth::setCutoff.
    Resonance: Double;

    // The LFO's wave, an lfo::Shape as a number. Sine is the S950's; the rest are not.
    LfoShape: Double;

    // 0..99: how far the LFO moves the cutoff, up to lfo::FilterOctaves. Not the S950's -
    // its LFO reaches the pitch and nothing else.
    LfoToFilter: Double;

    // Tempo sync: on (>= 0.5) or off, and which lfo::Divisions entry. While on, every
    // voice rides the engine's shared LFO, which the engine locks to the host's grid.
    LfoSync, LfoSyncDiv: Double;     // lfo::DefaultDivision, 1/8

    // The C++'s default member initialisers: all zero, bar LfoSyncDiv.
    procedure Init;
  end;

// ------------------------------------------------------------------- namespace lfo

type
  //
  // The LFO's shapes. The S950's LFO is a sine and nothing else; the other three are
  // additions, and sine stays the default so a programme plays as the machine would.
  //
  TLfoShape = (lfoSine = 0, lfoSaw, lfoSquare, lfoSampleHold);

const
  LfoNumShapes = 4;

//
// The wave at a phase, -1..+1.
//
// Every shape starts where the sine does - at zero phase, heading up - so switching
// shape does not throw a held note to the far side of its pitch: the saw rises from
// the centre to the top, jumps to the bottom and rises back; the square sits high for
// the first half. S&H holds one random level a cycle, drawn from `seed` and `cycle`
// rather than a running generator, so every voice riding the programme's shared LFO
// lands on the same level at the same moment - which is what a shared LFO means.
//
function LfoWave(Shape: Integer; Phase: Double; Seed, Cycle: UInt32): Double;

//
// THE PERFORM TAB'S LFO REACHES PAST THE MACHINE'S
//
// Each of these is the S950's own measured curve over the S950's own range, and an
// addition beyond it - so a programme with the trims at zero plays exactly as the
// disk has it, and turning a knob a little moves it exactly as the machine's panel
// would. Only past the machine's end does the Perform tab carry on.
//

const
  // How far the Rate trim reaches, in octaves either way from the programme's own rate,
  // and the limits the result is held to.
  LfoRateOctavesDown = 6.0;
  LfoRateOctavesUp   = 8.0;
  LfoRateMinHz       = 0.02;
  LfoRateMaxHz       = 500.0;

//
// Rate in hertz, from the keygroup's 0..99 and the Perform trim's -99..+99.
//
// The keygroup's value is the machine's, measured: 1.785 Hz and 0.089 Hz a unit, up
// to 10.6. The trim is not an addition to it but a multiplier - OCTAVES, evenly
// spread across the knob - so every notch moves the rate by the same musical amount
// wherever it is. That is what makes a slow rate easy to set where a linear knob
// crowds it into the first few degrees, and a doubling or a halving is a fixed turn
// when a stepped LFO wants lining up with a beat.
//
// Down six octaves at -99: from the S950's slowest, 1.8 Hz, to a 36-second cycle.
// Up eight at +99, into the audio range, where a square or S&H on pitch or filter
// turns from a wobble into a buzz and then a scream. Held to 0.02 Hz..500 Hz. At a
// trim of 0 this is the S950's rate exactly.
//
function LfoRateHz(DiskUnits, TrimUnits: Double): Double;

//
// Pitch depth in cents, from the keygroup's 0..99 and the trim's 0..99.
//
// The keygroup's is the machine's, 1.527 cents a unit. So is the trim's, as far as
// +50 (76 cents); past that it grows exponentially to a whole octave at +99, so S&H
// and square become pitch jumps you cannot miss. Below +50 the two add exactly as
// they always did, bar the old clamp at a combined 99.
//
function LfoPitchCents(DiskUnits, TrimUnits: Double): Double;

//
// How long the depth takes to fade in, for the programme's 0..99 plus the trim.
//
// 0..99 is measured (cal::LfoDelayFadeConstant): 83 ms at 0, seven and a half seconds
// at 99. Below zero is not the S950's, and shortens the fade in a straight line to
// nothing at -99 - so a trim can take a programme's slow fade-in away entirely.
//
function LfoFadeSeconds(Units: Double): Double;

const
  // How far the LFO takes the cutoff at the top of the To Filter knob, either way.
  LfoFilterOctaves = 3.0;

type
  //
  // TEMPO SYNC - the divisions the LFO can lock to, one cycle each.
  //
  // In quarter notes, except the bar lengths, which follow the host's time signature:
  // a bar of 6/8 is three quarters, not four. Slowest first, so the knob turns the same
  // way the Rate knob does.
  //
  TLfoDivision = record
    Name: string;
    Quarters: Double;
    Bars: Boolean;
  end;

const
  LfoNumDivisions = 15;
  LfoDivisions: array[0..LfoNumDivisions - 1] of TLfoDivision =
  (
    (Name: '4 bars'; Quarters: 4.0;         Bars: True ),
    (Name: '2 bars'; Quarters: 2.0;         Bars: True ),
    (Name: '1 bar';  Quarters: 1.0;         Bars: True ),
    (Name: '1/2';    Quarters: 2.0;         Bars: False),
    (Name: '1/4.';   Quarters: 1.5;         Bars: False),
    (Name: '1/4';    Quarters: 1.0;         Bars: False),
    (Name: '1/4T';   Quarters: 2.0 / 3.0;   Bars: False),
    (Name: '1/8.';   Quarters: 0.75;        Bars: False),
    (Name: '1/8';    Quarters: 0.5;         Bars: False),
    (Name: '1/8T';   Quarters: 1.0 / 3.0;   Bars: False),
    (Name: '1/16.';  Quarters: 0.375;       Bars: False),
    (Name: '1/16';   Quarters: 0.25;        Bars: False),
    (Name: '1/16T';  Quarters: 1.0 / 6.0;   Bars: False),
    (Name: '1/32';   Quarters: 0.125;       Bars: False),
    (Name: '1/64';   Quarters: 0.0625;      Bars: False)
  );

  LfoDefaultDivision = 8;       // 1/8

// One cycle of division `index`, in quarter notes, for a bar of `quartersPerBar`.
function LfoDivisionQuarters(Index: Integer; QuartersPerBar: Double): Double;

// ------------------------------------------------------------------------ the voice

type
  TVoiceStage = (vsIdle, vsAttack, vsDecay, vsSustain, vsRelease);

  //
  // One sounding note.
  //
  // Everything a voice does happens in render(), a block at a time, and nothing in here
  // allocates once the voice exists. That is the whole reason this half is separate from
  // the editor: an allocation in the middle of an audio callback is a click, and a click
  // in a plugin is someone else's ruined take.
  //
  // The signal path follows the machine: the sample is read out at whatever rate the pitch
  // asks for, and the filter runs AFTER that, at the rate the audio leaves at. So the
  // cutoff is a fixed number of hertz whichever key is held, rather than being dragged up
  // and down by the varispeed.
  //
  // A straight port of AkaiS950Engine/Voice.cs.
  //
  // A record, as the C++'s Voice is held by value in the engine's array. Init sets the
  // C++'s default member values and Done gives back the sound it holds; the engine calls
  // both.
  //
  TS950Voice = record
  private
    FFilter: TButterworth;

    //
    // The keygroup this voice is playing.
    //
    // A pointer into the patch, which the engine keeps alive for as long as any voice
    // refers to it - see Engine::setPatch. The sound is held by value as a shared_ptr
    // instead, because that is the one thing a voice reads every single sample.
    //
    //
    // BY VALUE, NOT BY POINTER INTO THE PATCH.
    //
    // It was a pointer, and the patch it pointed into is retired and freed the moment a
    // new programme arrives - a programme change, or the Synth tab re-rendering. A
    // voice still sounding through that, playing a sample the new programme did not
    // have, kept its pointer and read its envelope, filter and warp out of freed
    // memory for the rest of the note: clicks at best. Now every voice owns a copy,
    // and adopt() copies the new settings in when they apply.
    //
    // (The C++'s `kg` only ever points at `own`, or is null before the first note: here
    // that is FHasKg, and FOwn is read directly.)
    //
    FOwn: TKeygroupPatch;
    FHasKg: Boolean;
    FSound: TS950Sound;          // a reference held, as the C++'s shared_ptr

    FNote, FVelocity: Integer;
    FKeygroupIndex: Integer;
    FStartedAt: Int64;

    FSampleRate: Double;
    FPos: Double;                // where we are in the sample, in frames
    FDir: Integer;               // +1 forwards, -1 back; only an alternating loop flips it

    // The pitch wheel as a rate multiplier, set by the engine once per stretch. 1.0 at
    // rest. Named for the wheel rather than "bend", because the LFO's own multiplier
    // inside render() is already called that and one shadowing the other would be a bug
    // waiting to be written.
    FWheelBend: Double;
    FStep: Double;               // frames per output sample, before the LFO

    // amplitude envelope, all in gain except the times
    FStage: TVoiceStage;
    FT: Double;                  // seconds since the stage began
    FAttack, FDecay, FReleaseTime: Double;
    FPeak, FSustain: Double;

    //
    // The positional crossfade, worked out once when the note started.
    //
    // Kept rather than recomputed, and adopt() keeps it too: the fade depends on the key
    // ranges of the OTHER keygroups answering this note, which a repatch may have moved
    // under the voice. A voice belongs to the keygroup that started it, and it belongs
    // to the balance it started in for the same reason.
    //
    FCrossfade: Double;
    FGain, FReleaseFrom: Double;

    // filter envelope
    FVcfAttack, FVcfDecay, FVcfSustain, FVcfRelease: Double;
    FCutoffShift, FCeiling, FFloorHz: Double;

    //
    // The filter envelope's own clock, counting from the note on.
    //
    // NOT `t`, which is how far the AMPLITUDE envelope has got into its current stage and
    // is reset to zero every time that stage changes. Driving the filter from it made the
    // filter envelope restart whenever the amplitude one moved attack -> decay and again
    // decay -> sustain, so a programme with a slow amplitude decay swept its filter two or
    // three times over. It went unnoticed because most of the library has an instant
    // attack and decay, which resets a clock that has barely started.
    //
    FVcfT: Double;

    //
    // The filter's release, separate from the amplitude's.
    //
    // The envelope falls from wherever it had reached back to nothing - and nothing means
    // the keygroup's own cutoff, the envelope's contribution decaying away rather than the
    // filter slamming shut. Kept apart from `stage` because a one-shot keygroup ignores
    // note-off completely and then neither envelope releases.
    //
    FVcfReleasing: Boolean;
    FVcfReleaseFrom, FVcfReleaseT: Double;

    //
    // The base cutoff and the envelope depth are NOT cached here, where everything else
    // about the note is. They come off the keygroup afresh in cutoffNow(), because the
    // trims move under a held note and a cached pair would freeze the control until the
    // next key was struck.
    //
    // The trims are taken as they arrive, NOT smoothed, and that is a decision rather
    // than an oversight.
    //
    // Measured, by stepping the trim mid-note and comparing the output's slew at the
    // change with the slew the waveform reaches anyway:
    //
    //     one CC step (1.56 units)   1.09x   - lost in the signal
    //     a fast drag (25 units)     2.84x   - a click
    //     slammed shut (-60 units)   0.05x   - closing is always safe
    //
    // So the only thing that clicks is a large jump applied in one lump: a preset
    // recall, a typed value, a double-click back to zero, or a step in an automation
    // lane. Continuous moves - a controller sweep, a dragged knob, smoothed automation -
    // arrive in steps around the size of the first row, and those are inaudible.
    //
    // A glide was tried and taken out again. It cost 15 ms of lag on every move, which
    // is felt on a filter sweep played to a beat, and the machine itself had no such
    // thing. Where a slow move is wanted, the host can ramp the parameter, which is the
    // right place for it: the plugin should not decide how fast a player's hand moves.
    //
    FTrims: TTrims;

    // the LFO
    FLfoCents, FLfoPhase, FLfoStep: Double;

    // Whole cycles of this voice's own LFO so far, and its own S&H seed - see lfo::wave.
    FLfoCycle, FLfoSeed: UInt32;

    // The LFO this block, faded in, -1..+1; and how many octaves of cutoff that is worth.
    FLfoNow, FLfoFilterOctaves: Double;
    FFadeSeconds, FFadeT: Double;

    // Seconds since the key went down. Warp's bend is measured from there, and `t` cannot
    // serve because it restarts at every envelope stage.
    FSinceOn: Double;

    // Where the keygroup's output port puts this voice. See cal::outputGains.
    FOutL, FOutR: Double;
    FWheelCents: Double;         // kept so adopt() can add it back to a new depth
    FOwnLfo: Boolean;

    //
    // Portamento: semitones still to travel, and how fast, in semitones a second.
    //
    // The offset walks to zero in a straight line in SEMITONES - an exponential in hertz -
    // so an octave glide spends as long on its bottom half as its top, which is what
    // every synth with a portamento knob does and what an ear hears as even.
    //
    // The speed is set at the strike from the distance and the time, so every glide takes
    // the same time however far it goes. Constant-rate is the other school; constant-time
    // is the one where a knob reading 200 ms means 200 ms.
    //
    FGlideOffset, FGlidePerSecond: Double;

    // Handed over to a glide: the release is held to HandOverRelease. See handOver().
    FHandedOver: Boolean;

    // The key has gone up; `pendingRelease` samples remain before the envelope releases.
    FKeyUp: Boolean;
    FPendingRelease: Integer;

    //
    // Wide: which half of a pair this is (0 for not one), its twin, and what the detune
    // and the spread come to as a rate multiplier and two channel gains.
    //
    // The gains are an equal-power pan with both halves at -3 dB. Centred, each half is
    // 0.707 in both channels, and two copies that are not in phase add up in power to
    // one note's worth. Fully spread, each half is at 1.0 on its own side - so a wide
    // note is as loud as a plain one wherever the Spread control sits.
    //
    FWideSign, FPartner: Integer;
    FWideRatio, FWideGainL, FWideGainR: Double;

    function CutoffNow: Double;

    // The filter envelope while the key is still down: attack, decay, then sustain.
    function VcfEnvelopeHeld(At: Double): Double;
    function EnvelopeAfter(Ahead: Double): Double;
    procedure AdvanceStage;

    //
    // Work the envelope times and levels out from the keygroup plus the trims.
    //
    // Called at the top of every control block, not once when the note starts, so that
    // moving a control is heard on notes already sounding. That is what a control is;
    // a value only read at note-on would be a setting.
    //
    procedure ApplyTrims;

    //
    // The three LFO values the trims can move, derived from the keygroup and the trims.
    //
    // Separate from applyTrims only because the note's own LFO state - its phase, and how
    // far into the fade it is - is set once at the strike and must survive every later
    // call, while these three are recomputed from scratch each control block.
    //
    procedure ApplyLfo;

    // Take another reference on a sound and give back the one held.
    procedure HoldSound(S: TS950Sound);

    // A stored 0..99 panel value with its trim added, back inside 0..99.
    class function Trimmed(Stored: Integer; By: Double): Double; static; inline;

    // A straight line in decibels from one gain to another.
    class function Fall(From, To_, U: Double): Double; static;

    class function Clamp01(V: Double): Double; static; inline;
  public
    // The C++'s default member values. Before anything else.
    procedure Init;

    // Give back the sound this voice holds. The C++'s destructor.
    procedure Done;

    function IsActive: Boolean; inline;
    // The KEY is down. False from the note-off on, even while the envelope is still
    // waiting out cal::NoteOffLatencySeconds before it releases.
    function IsHeld: Boolean; inline;
    function GetNote: Integer; inline;
    function GetVelocity: Integer; inline;
    function GetStartedAt: Int64; inline;

    // Which keygroup of the programme this voice came from, or -1.
    function GetKeygroupIndex: Integer; inline;

    // The audio this voice is reading, so a caller can ask what is really sounding.
    function GetSound: TS950Sound; inline;

    // Start this voice. Nothing here allocates.
    //
    // `crossfade` is the positional crossfade's gain for this keygroup at this key,
    // worked out once by the engine from every keygroup answering the note. See
    // cal::crossfadeGain.
    //
    // `glideSemis` is how far from this note the pitch starts, in semitones, and
    // `glideSeconds` how long it takes to arrive. Zero for either is no glide. See
    // Engine::glide - it is not something the S950 had.
    procedure Start(const Group: TKeygroupPatch; N, Vel: Integer;
                    Rate, Wheel: Double; Sequence: Int64;
                    Fade: Double = 1.0;
                    GlideSemis: Double = 0.0; GlideSeconds: Double = 0.0);

    //
    // The pitch this voice is sounding at, as a note number with a fraction.
    //
    // The key it was struck on plus however much glide it has left to cover, so a note
    // struck in the middle of a glide can start from where the last one had got to rather
    // than from where it was going. Ignores the wheel, the LFO and warp: those move every
    // note alike and a glide should not inherit them.
    //
    function GetPitchNow: Double; inline;

    // Still sliding towards its note. False once it arrives, or once release() stops it.
    function IsGliding: Boolean; inline;

    //
    // Take up new settings without restarting the note.
    //
    // For a value changed while the note is sounding - a filter dragged, an envelope
    // reshaped, a programme edited under a held loop. Everything that describes the note
    // is recomputed; everything that says where the note has got to is left exactly as
    // it is. So the sample goes on from where it was, the envelope stays in its stage,
    // the LFO keeps its phase and the filter keeps its state - the last of those
    // matters, because resetting a filter mid-note is a click.
    //
    // A keygroup now naming a different sample is not a change to this note, it is a
    // different note; the position we are at would not mean the same thing in other
    // audio. That waits for the next trigger.
    //
    procedure Adopt(const Group: TKeygroupPatch);

    //
    // Move a sounding note to another key without striking it again - mono legato.
    //
    // The sample carries on from where it is and the envelope stays in its stage; only
    // the pitch moves, gliding there if `glideSemis` and `glideSeconds` say so, exactly
    // as start() would have. Velocity is the first strike's: the note was never struck
    // again. Same keygroup and same sample only - Engine::startNote checks.
    //
    procedure LegatoTo(N: Integer; GlideSemis, GlideSeconds: Double);

    //
    // The player's own trims, on top of whatever the keygroup says.
    //
    // Both are in the panel's own units, because that is where they mean something: the
    // cutoff curve is a measured table against the stored 0..99, so adding to the stored
    // value bends the filter the way the machine's own knob would. Adding octaves instead
    // would be a different, straighter control that the S950 does not have.
    //
    // Set by the engine before every stretch it renders, so moving the control is heard
    // on notes that are already sounding rather than only on the next one.
    //
    procedure SetTrims(const Value: TTrims); inline;

    // The pitch wheel as a rate multiplier. Reaches a note already sounding, unlike velocity.
    procedure SetBend(Ratio: Double); inline;

    // Let go of the key. The note falls at its own release rate. Immediate: this is what
    // all-notes-off and the internals call. A note-off from a player goes via letGo().
    procedure Release;

    //
    // A note-off, as the machine takes one: the key is up now, and the release begins
    // cal::NoteOffLatencySeconds later. See that constant for how it was measured.
    //
    procedure LetGo;

    procedure Kill; inline;

    //
    // A released note that a glide is taking over: fade it out fast.
    //
    // Without this, a glide from a note whose key is already up started a SECOND voice at
    // that note's pitch while the first was still in its release - two copies of one
    // sample at nearly one pitch, drifting apart, which is a unison. It was heard as the
    // sound thickening on a line of single notes, and only with polyphony above one,
    // because mono takes its one voice over anyway. The glide is the old note carrying
    // on; the old note's own tail should go.
    //
    // Ten milliseconds rather than cut dead, which would click. Only for a voice already
    // in its release: a key still held is being played, and is left alone.
    //
    procedure HandOver;

    //
    // WIDE - one half of a detuned pair. Not an S950 feature; see Engine::wide.
    //
    // `sign` is -1 for the flat half, which leans left, and +1 for the sharp half, which
    // leans right. Called straight after start(). With `offset` the sharp half starts a
    // few milliseconds into the sample, so the two are not in phase at the attack - two
    // copies starting together flange until they drift apart.
    //
    procedure MakeWide(Sign, PartnerIndex: Integer; Offset: Boolean);

    // The other half of this voice's pair, or -1. Only to be trusted if it points back.
    function GetPartner: Integer; inline;

    //
    // How far apart the pair sits and how wide, set by the engine before each stretch
    // so turning either control is heard on notes already sounding. Ignored by a voice
    // that is not half of a pair.
    //
    procedure SetWide(Cents, Spread: Double);

    //
    // Add this voice into the buffer.
    //
    // `sharedPhase` is the programme's own LFO, which voices with the desync bit CLEAR
    // ride instead of their own. That was measured rather than assumed: with the bit
    // clear two voices held their phase to within 3 degrees over six seconds, and with
    // it set they ran at rates 3.5% apart and drifted a whole turn in the same six.
    //
    // Mono, as it always was: full gain into one buffer - pass Right = nil.
    //
    //
    // Stereo, with the keygroup's output port deciding which side it lands on.
    //
    // A null `right` is the mono path and is bit-identical to what it always did - the pan
    // gains are ignored and the sample goes into `left` at full level. Only a caller with
    // two channels pays for the second write.
    //
    //
    // `sharedStep` is how far the shared LFO moves a sample, so a voice riding it can
    // follow it through the stretch rather than holding the phase it started at - which,
    // once the Rate trim reaches the audio range, is the difference between a buzz and
    // one fixed value for a whole host buffer.
    //
    procedure Render(Left, Right: PSampleBuffer; Count: Integer; SharedPhase: Double;
                     SharedCycle: UInt32 = 0; SharedStep: Double = 0.0);
  end;

  PS950Voice = ^TS950Voice;

const
  // The seed S&H draws from on the shared LFO, the same for every voice.
  SharedLfoSeed = $5EED;

implementation

const
  //
  // How often the modulators are recomputed. 32 at 48 kHz is 0.67 ms.
  //
  //
  // How often the modulators are recomputed. 32 at 48 kHz is 0.67 ms.
  //
  // This is also how often the filter is retuned, and that is the tighter constraint.
  // The fastest release the machine has drops the cutoff five and a half octaves in
  // about a millisecond, and a sixth-order cascade moved that far in ONE step - while
  // keeping the state the old coefficients left behind - rings instead of closing.
  // Stepping this cascade from 17760 Hz to 311 Hz against a signal peaking at 1.0:
  //
  //     block    64     32     16      8      4      1
  //     peak   17.85   1.24   2.49   2.29   1.83   1.57
  //
  // The cliff is between 64 and 32; below that the numbers are one realisation of a
  // sweep that overshoots a little whatever the step, and the scatter is the sawtooth
  // landing differently against each retune. So 32 is already on the right side of it
  // and going finer buys nothing for four times the modulator work.
  //
  // The web build bakes its filter with a 64-sample block and DID ring, at nine times
  // full scale; its release renderer uses 8 for that reason.
  //
  ControlBlock = 32;

  // A release time that falls the whole way (-74 dB, where render() stops a voice) in
  // 10 ms, given that a release time is the time to fall cal::VcaReleaseDb.
  HandOverRelease = 0.010 * VcaReleaseDb / 74.0;

  TwoPi = 2.0 * Pi64;

  // The C++'s float literals 0.70710678f and 1.0f.
  HalfPowerF: Single = 0.70710678;
  OneF: Single = 1.0;
  ZeroF: Single = 0.0;

{ TTrims }

procedure TTrims.Init;
begin
  FillChar(Self, SizeOf(Self), 0);
  LfoSyncDiv := 8.0;
end;

{ lfo }

function LfoWave(Shape: Integer; Phase: Double; Seed, Cycle: UInt32): Double;
var
  H: UInt32;
begin
  case Shape of
    Ord(lfoSaw):
      if Phase < Pi64 then Result := Phase / Pi64 else Result := Phase / Pi64 - 2.0;
    Ord(lfoSquare):
      if Phase < Pi64 then Result := 1.0 else Result := -1.0;
    Ord(lfoSampleHold):
      begin
        // a 32-bit integer hash (Chris Wellons' "lowbias32") of seed and cycle
        // (the products in 64 bits and masked, which is uint32_t's wrapping without an
        // overflow for -Co to see)
        H := Seed xor UInt32((UInt64(Cycle) * UInt64($9E3779B9)) and $FFFFFFFF);
        H := H xor (H shr 16); H := UInt32((UInt64(H) * UInt64($7FEB352D)) and $FFFFFFFF);
        H := H xor (H shr 15); H := UInt32((UInt64(H) * UInt64($846CA68B)) and $FFFFFFFF);
        H := H xor (H shr 16);
        Result := H / 2147483647.5 - 1.0;
      end;
  else
    Result := SinD(Phase);
  end;
end;

function LfoRateHz(DiskUnits, TrimUnits: Double): Double;
var
  Base, T, Octaves: Double;
begin
  Base := LfoRateHzAtZero + Clamp(DiskUnits, 0.0, 99.0) * LfoRateHzPerUnit;
  T    := Clamp(TrimUnits, -99.0, 99.0);
  if T = 0.0 then
  begin
    Result := Base;
    Exit;
  end;

  if T > 0.0 then
    Octaves := T / 99.0 * LfoRateOctavesUp
  else
    Octaves := T / 99.0 * LfoRateOctavesDown;
  Result := Clamp(Base * Exp2D(Octaves), LfoRateMinHz, LfoRateMaxHz);
end;

function LfoPitchCents(DiskUnits, TrimUnits: Double): Double;
var
  T, Knee, Trim: Double;
begin
  T    := Clamp(TrimUnits, 0.0, 99.0);
  Knee := 50.0 * LfoDepthCentsPerUnit;
  if T <= 50.0 then
    Trim := T * LfoDepthCentsPerUnit
  else
    Trim := Knee * PowD(1200.0 / Knee, (T - 50.0) / 49.0);

  Result := Clamp(DiskUnits, 0.0, 99.0) * LfoDepthCentsPerUnit + Trim;
end;

function LfoFadeSeconds(Units: Double): Double;
var
  U: Double;
begin
  U := Clamp(Units, -99.0, 99.0);
  if U >= 0.0 then
    Result := LfoDelayFadeConstant / MaxD(1.0, 100.0 - U)
  else
    Result := (LfoDelayFadeConstant / 100.0) * (1.0 + U / 99.0);
end;

function LfoDivisionQuarters(Index: Integer; QuartersPerBar: Double): Double;
var
  I: Integer;
begin
  if Index < 0 then
    I := 0
  else if Index >= LfoNumDivisions then
    I := LfoNumDivisions - 1
  else
    I := Index;

  if LfoDivisions[I].Bars then
  begin
    if QuartersPerBar > 0.0 then
      Result := LfoDivisions[I].Quarters * QuartersPerBar
    else
      Result := LfoDivisions[I].Quarters * 4.0;
  end
  else
    Result := LfoDivisions[I].Quarters;
end;

{ TS950Voice }

procedure TS950Voice.Init;
begin
  FillChar(Self, SizeOf(Self), 0);
  FFilter.Init;
  FOwn.Init;
  FHasKg := False;
  FSound := nil;
  FKeygroupIndex := -1;
  FSampleRate := 48000.0;
  FDir := 1;
  FWheelBend := 1.0;
  FStep := 1.0;
  FStage := vsIdle;
  FPeak := 1.0;
  FSustain := 1.0;
  FCrossfade := 1.0;
  FVcfSustain := 1.0;
  FCeiling := 16000.0;
  FFloorHz := 311.0;
  FTrims.Init;
  FOutL := 1.0;
  FOutR := 1.0;
  FOwnLfo := True;
  FPartner := -1;
  FWideRatio := 1.0;
  FWideGainL := 1.0;
  FWideGainR := 1.0;
end;

procedure TS950Voice.Done;
begin
  ReleaseSound(FSound);
end;

procedure TS950Voice.HoldSound(S: TS950Sound);
begin
  if S = FSound then
    Exit;
  if S <> nil then
    S.Retain;
  ReleaseSound(FSound);
  FSound := S;
end;

class function TS950Voice.Trimmed(Stored: Integer; By: Double): Double;
begin
  Result := Clamp(Stored + By, 0.0, 99.0);
end;

class function TS950Voice.Fall(From, To_, U: Double): Double;
var
  Lo: Double;
begin
  if From <= 1e-6 then
  begin
    Result := 0.0;
    Exit;
  end;
  Lo := MaxD(To_, 1e-6);
  Result := From * PowD(Lo / From, U);
end;

class function TS950Voice.Clamp01(V: Double): Double;
begin
  Result := Clamp(V, 0.0, 1.0);
end;

function TS950Voice.IsActive: Boolean;
begin
  Result := FStage <> vsIdle;
end;

function TS950Voice.IsHeld: Boolean;
begin
  Result := (FStage <> vsIdle) and (FStage <> vsRelease) and not FKeyUp;
end;

function TS950Voice.GetNote: Integer;
begin
  Result := FNote;
end;

function TS950Voice.GetVelocity: Integer;
begin
  Result := FVelocity;
end;

function TS950Voice.GetStartedAt: Int64;
begin
  Result := FStartedAt;
end;

function TS950Voice.GetKeygroupIndex: Integer;
begin
  Result := FKeygroupIndex;
end;

function TS950Voice.GetSound: TS950Sound;
begin
  Result := FSound;
end;

function TS950Voice.GetPitchNow: Double;
begin
  Result := FNote + FGlideOffset;
end;

function TS950Voice.IsGliding: Boolean;
begin
  Result := (FGlidePerSecond > 0.0) and (FGlideOffset <> 0.0);
end;

procedure TS950Voice.SetTrims(const Value: TTrims);
begin
  FTrims := Value;
end;

procedure TS950Voice.SetBend(Ratio: Double);
begin
  FWheelBend := Ratio;
end;

procedure TS950Voice.Kill;
begin
  FStage := vsIdle;
end;

function TS950Voice.GetPartner: Integer;
begin
  Result := FPartner;
end;

procedure TS950Voice.Start(const Group: TKeygroupPatch; N, Vel: Integer;
                           Rate, Wheel: Double; Sequence: Int64; Fade: Double;
                           GlideSemis, GlideSeconds: Double);
var
  Semis, Ratio, Depth, VelDb, ZoneDb: Double;
  Glides: Boolean;
begin
  FCrossfade     := Fade;
  FHandedOver    := False;
  FKeyUp         := False;
  FPendingRelease := 0;
  FWideSign      := 0;              // a plain voice until makeWide says otherwise
  FPartner       := -1;
  FWideRatio     := 1.0;
  FWideGainL     := 1.0;
  FWideGainR     := 1.0;
  FOwn           := Group;
  FHasKg         := True;
  HoldSound(Group.Sound);
  FNote          := N;
  if Vel < 0 then FVelocity := 0 else if Vel > 127 then FVelocity := 127 else FVelocity := Vel;
  FKeygroupIndex := Group.KeygroupIndex;
  FStartedAt     := Sequence;
  FSampleRate    := Rate;

  // --- pitch. Constant pitch means the keygroup ignores which key was struck.
  Semis := Group.ZoneTranspose;
  if not Group.ConstantPitch then
    Semis := Semis + (FNote - FSound.RootPitch);

  // past the machine's fastest playback the note drops by octaves - cal::MaxPlaybackHz
  Ratio := FoldedRatio(FSound.SourceRate, Exp2D(Semis / 12.0));
  FStep := FSound.SourceRate / FSampleRate * Ratio;
  FPos  := 0.0;
  FDir  := 1;               // forwards until an alternating loop turns it round

  // --- glide. The target pitch above is untouched; render() multiplies the offset on
  // top, as it does the wheel, so arriving is simply the offset reaching zero.
  Glides := (GlideSeconds > 0.0005) and (GlideSemis <> 0.0);
  if Glides then
  begin
    FGlideOffset    := GlideSemis;
    FGlidePerSecond := Abs(GlideSemis) / GlideSeconds;
  end
  else
  begin
    FGlideOffset    := 0.0;
    FGlidePerSecond := 0.0;
  end;

  // --- amplitude envelope. Only the peak is fixed at the strike: it is what the
  // velocity and the zone trim decided, and no control moves it afterwards.
  //
  // The velocity-to-loudness trim lands here, at the strike, and nowhere else.
  //
  // It decides how much softer a soft note is, which is a question about the strike -
  // so like the peak it sets, it is answered once and not revisited. Turning the knob
  // changes how the NEXT note answers the keyboard, not how loud a note already
  // sounding turns out to have been.
  //
  Depth  := Clamp01(Trimmed(Group.VelToLoudness, FTrims.VelToLoudness) / 99.0);
  VelDb  := -(127.0 - FVelocity) * VelDbPerStep * Depth;
  ZoneDb := Group.ZoneLoudness * LoudnessDbPerUnit;

  FPeak := MinD(DbToGain(VelDb + ZoneDb), 4.0) * FCrossfade;

  // the times and the sustains come from the keygroup and the trims together
  ApplyTrims;

  if FAttack > 0.0005 then FStage := vsAttack else FStage := vsDecay;
  FT := 0.0;
  if FAttack > 0.0005 then FGain := 0.0 else FGain := FPeak;

  //
  // --- filter. The top of the filter's travel is a fixed frequency, however fast or
  // slow the sample plays - measured, see cal::TopHz - held under what the device rate
  // can represent.
  //
  FCeiling := MinD(TopHz, FSampleRate * 0.45);
  FFloorHz := MinD(FloorHz, FCeiling);

  // cutoffShift is worked out in applyTrims, which has already run, so that the
  // velocity-to-filter trim can move it while the note sounds.

  FVcfT         := 0.0;
  FVcfReleasing := False;
  FVcfReleaseT  := 0.0;

  FFilter.Reset;
  FFilter.SetCutoff(CutoffNow, FSampleRate, FTrims.Resonance / 100.0);

  // --- the LFO. Phase and fade start here; rate, depth and delay come from applyLfo,
  // which the trims can move while the note sounds.
  FWheelCents := Wheel;
  FOwnLfo     := Group.LfoDesync;
  FLfoPhase   := 0.0;
  FLfoCycle   := 0;
  FLfoNow     := 0.0;
  // each note its own S&H (static_cast<unsigned> (sequence) * 2654435761u, wrapping)
  FLfoSeed    := UInt32((UInt64(Sequence and $FFFFFFFF) * UInt64(2654435761)) and $FFFFFFFF);
  FFadeT      := 0.0;
  FSinceOn    := 0.0;

  // Which output the keygroup goes to. Settled at the strike, like the peak: nothing
  // moves a sounding note from one socket to another on the machine either.
  OutputGains(Group.OutputPort, FOutL, FOutR);
  ApplyLfo;
end;

procedure TS950Voice.Adopt(const Group: TKeygroupPatch);
var
  Semis, Ratio, Depth, VelDb, ZoneDb: Double;
begin
  if FStage = vsIdle then Exit;
  if Group.Sound <> FSound then Exit;   // a different sample is a different note

  FOwn   := Group;
  FHasKg := True;

  // --- pitch. Changing transpose moves the playback rate under the position we
  // already hold, which is what transposing a sounding note means.
  Semis := Group.ZoneTranspose;
  if not Group.ConstantPitch then
    Semis := Semis + (FNote - FSound.RootPitch);

  // past the machine's fastest playback the note drops by octaves - cal::MaxPlaybackHz
  Ratio := FoldedRatio(FSound.SourceRate, Exp2D(Semis / 12.0));
  FStep := FSound.SourceRate / FSampleRate * Ratio;

  // --- amplitude. The targets move; the gain walks to them from where it is.
  Depth  := Clamp01(Group.VelToLoudness / 99.0);
  VelDb  := -(127.0 - FVelocity) * VelDbPerStep * Depth;
  ZoneDb := Group.ZoneLoudness * LoudnessDbPerUnit;

  FPeak := MinD(DbToGain(VelDb + ZoneDb), 4.0) * FCrossfade;
  ApplyTrims;

  // --- filter
  FCeiling := MinD(TopHz, FSampleRate * 0.45);
  FFloorHz := MinD(FloorHz, FCeiling);

  // cutoffShift is worked out in applyTrims, which has already run, so that the
  // velocity-to-filter trim can move it while the note sounds.

  // deliberately no filter.reset() - see the note on adopt()

  // --- the LFO keeps its phase and its place in the fade-in
  FOwnLfo := Group.LfoDesync;
  ApplyLfo;
end;

procedure TS950Voice.LegatoTo(N: Integer; GlideSemis, GlideSeconds: Double);
var
  Semis, Ratio: Double;
  Glides: Boolean;
begin
  if (FStage = vsIdle) or not FHasKg then
    Exit;

  FNote := N;

  // --- pitch, as start() works it out, under the position we already hold
  Semis := FOwn.ZoneTranspose;
  if not FOwn.ConstantPitch then
    Semis := Semis + (FNote - FSound.RootPitch);

  // past the machine's fastest playback the note drops by octaves - cal::MaxPlaybackHz
  Ratio := FoldedRatio(FSound.SourceRate, Exp2D(Semis / 12.0));
  FStep     := FSound.SourceRate / FSampleRate * Ratio;
  FCeiling  := MinD(TopHz, FSampleRate * 0.45);
  FFloorHz  := MinD(FloorHz, FCeiling);

  // --- glide, as start() does it. Key tracking follows by itself: applyTrims reads
  // `note` at the top of every control block.
  Glides := (GlideSeconds > 0.0005) and (GlideSemis <> 0.0);
  if Glides then
  begin
    FGlideOffset    := GlideSemis;
    FGlidePerSecond := Abs(GlideSemis) / GlideSeconds;
  end
  else
  begin
    FGlideOffset    := 0.0;
    FGlidePerSecond := 0.0;
  end;
end;

//
// The envelope times and levels, from the keygroup and the player's trims together.
//
// Everything here is cheap and everything here can move while a note sounds, so it is
// redone at the top of every control block rather than kept from the strike. Changing
// a time under a running envelope is well defined: advanceStage compares where the note
// has got to against the time as it is NOW, so shortening a decay past the point already
// reached simply moves the note on to its sustain.
//
// The peak is not here. That is what the velocity and the zone loudness decided when the
// key went down, and no control reaches back to change how hard a note was struck.
//
procedure TS950Voice.ApplyTrims;
var
  SustainDb, BaseAttack, BaseDecay, BaseSustain, BaseRelease: Double;
  Track, KeyShift, VelShift: Double;
begin
  //
  // The trim first, then velocity on top of it. The trim is the player's offset from
  // what the disk says, so it is part of "the attack this voice is set to" - and byte 9
  // shortens whatever that turns out to be, exactly as it shortens the disk's own value
  // on the hardware. Turning the attack knob therefore moves the velocity response with
  // it rather than fighting it.
  //
  FAttack      := VcaAttackSeconds(
                      VelocityAttackByte(Trimmed(FOwn.VcaAttack, FTrims.VcaAttack),
                                         FOwn.VelToAttack, FVelocity));
  FReleaseTime := EnvSeconds(
                      VelocityReleaseByte(Trimmed(FOwn.VcaRelease, FTrims.VcaRelease),
                                          FOwn.VelToRelease, FVelocity,
                                          FOwn.VelocityReleaseOn));

  if FHandedOver then
    FReleaseTime := MinD(FReleaseTime, HandOverRelease);

  // A stored sustain of ZERO is silence, and is not the bottom of the line the other
  // settings sit on - see cal::VcaSilenceDb. It used to stop 39.6 dB down and hang
  // there, on 723 of the library's keygroups. The decay is a RATE, so how long it
  // takes depends on how far it has to go - see cal::vcaDecaySeconds.
  SustainDb := SustainDbFor(Trimmed(FOwn.VcaSustain, FTrims.VcaSustain));
  FSustain := FPeak * DbToGain(SustainDb);

  FDecay := VcaDecaySeconds(Trimmed(FOwn.VcaDecay, FTrims.VcaDecay), SustainDb);

  //
  // An S900 programme left its four VCF bytes blank: it has no filter envelope at all,
  // rather than one set to whatever a space happens to be as a number.
  //
  // Those keygroups still get the player's controls, they simply start from a flat
  // envelope - no attack, no decay, full sustain - which moves nothing until something
  // is dialled in. Refusing to shape them, which is what this did at first, left a
  // whole class of programmes with four controls that did nothing and no way to tell
  // why. Untrimmed the result is identical either way: an amount of zero is no
  // movement, whatever shape it is applied to.
  //
  if FOwn.VcfWritten then
  begin
    BaseAttack  := FOwn.VcfAttack;
    BaseDecay   := FOwn.VcfDecay;
    BaseSustain := FOwn.VcfSustain;
    BaseRelease := FOwn.VcfRelease;
  end
  else
  begin
    BaseAttack  := 0;
    BaseDecay   := 0;
    BaseSustain := 99;
    BaseRelease := 0;
  end;

  FVcfAttack  := EnvSeconds(Clamp(BaseAttack + FTrims.VcfAttack, 0.0, 99.0))
               * VcfTimeScale;
  FVcfSustain := Clamp(BaseSustain + FTrims.VcfSustain, 0.0, 99.0) / 99.0;
  FVcfDecay   := VcfDecaySeconds(Clamp(BaseDecay + FTrims.VcfDecay, 0.0, 99.0),
                                 FVcfSustain);
  FVcfRelease := EnvSeconds(Clamp(BaseRelease + FTrims.VcfRelease, 0.0, 99.0))
               * VcfTimeScale;

  //
  // How far velocity and the key have moved the cutoff, in octaves.
  //
  // Here rather than at the strike because the velocity-to-filter trim has to reach a
  // note already sounding - a control that only took effect on the next key is not a
  // control anyone can play with. The note and the velocity themselves cannot change,
  // so what this recomputes each block is only how much of them counts.
  //
  // Key tracking is measured to pivot at note 62, not 60, and velocity at 65 - so a
  // note played at exactly 65 is unmoved however much sensitivity is dialled in, and
  // softer strikes go down where harder ones go up.
  //
  Track    := Clamp(FOwn.KeyToFilter, 0, 99) / KeyFull;
  KeyShift := (FNote - KeyPivot) / 12.0 * Track;
  VelShift := ((FVelocity - VelPivot) / 127.0)
              * (Trimmed(FOwn.VelToFilter, FTrims.VelToFilter) / 99.0)
              * VelOctaves;
  FCutoffShift := KeyShift + VelShift;

  ApplyLfo;
end;

//
// Rate, depth and delay, from the keygroup and the player's trims together.
//
// Moving any of them under a sounding note is safe and is the point: the phase carries on
// from where it was, so a rate change bends the wobble rather than restarting it, and the
// fade keeps its place, so reaching for the delay does not re-trigger a fade-in that has
// already finished.
//
// The depth the trim moves is the keygroup's own. Whatever the mod wheel is asking for is
// added on top and is not trimmed - the wheel is the player's hand already, and putting a
// second control on it would only fight the first.
//
procedure TS950Voice.ApplyLfo;
begin
  // The machine's curves over the machine's range, and the Perform tab's reach past
  // them - see the lfo namespace in Voice.h.
  FLfoCents    := LfoPitchCents(FOwn.LfoDepth, FTrims.LfoDepth) + FWheelCents;
  FLfoStep     := 2.0 * Pi64
                  * LfoRateHz(FOwn.LfoRate, FTrims.LfoRate) / FSampleRate;
  FFadeSeconds := LfoFadeSeconds(FOwn.LfoDelay + FTrims.LfoDelay);

  FLfoFilterOctaves := Clamp(FTrims.LfoToFilter, 0.0, 99.0) / 99.0 * LfoFilterOctaves;
end;

procedure TS950Voice.LetGo;
begin
  if (FStage = vsIdle) or (FStage = vsRelease) or FKeyUp then
    Exit;

  FKeyUp          := True;
  FPendingRelease := MaxI(1, LRound(NoteOffLatencySeconds * FSampleRate));

  // Letting go mid-glide stops the glide - a rule about the KEY, so it takes effect
  // now, not when the envelope gets round to releasing. See release().
  FGlidePerSecond := 0.0;
end;

procedure TS950Voice.Release;
begin
  FKeyUp          := True;
  FPendingRelease := 0;

  if (FStage = vsIdle) or (FStage = vsRelease) then
    Exit;

  //
  // Letting go mid-glide stops the glide where it stands: the tail fades at the pitch
  // the note had reached rather than sliding on through the release. Ahead of the
  // one-shot test, because the KEY was let go even if the sample plays on - and a
  // glide belongs to the key. Engine::stopNote makes sure the next note does not slide
  // from here either.
  //
  FGlidePerSecond := 0.0;

  // A one-shot keygroup is a drum: it plays through whatever the key does.
  if FHasKg and FOwn.OneShot and not FSound.Loops then
    Exit;

  FReleaseFrom := FGain;
  FStage       := vsRelease;
  FT           := 0.0;

  // The filter lets go at the same moment, from wherever its own envelope had reached -
  // which is why that is taken here rather than assumed to be the sustain level.
  FVcfReleaseFrom := VcfEnvelopeHeld(FVcfT);
  FVcfReleasing   := True;
  FVcfReleaseT    := 0.0;
end;

procedure TS950Voice.HandOver;
begin
  // A key already up but still inside the note-off latency is released now: a glide
  // taking it over is no reason to let it ring its extra 15 ms as a unison.
  if FKeyUp and (FStage <> vsIdle) and (FStage <> vsRelease) then
    Release;

  if (FStage <> vsRelease) or FHandedOver then
    Exit;

  // The release is a rate measured from where it starts, so restart it from here -
  // otherwise the shorter time would be applied to all the time already spent, and
  // the gain would drop in one step, which is the click this is meant to avoid.
  FHandedOver  := True;
  FReleaseFrom := FGain;
  FT           := 0.0;
  FReleaseTime := MinD(FReleaseTime, HandOverRelease);
end;

procedure TS950Voice.MakeWide(Sign, PartnerIndex: Integer; Offset: Boolean);
var
  EndAt: Double;
begin
  if Sign < 0 then FWideSign := -1 else FWideSign := 1;
  FPartner := PartnerIndex;

  //
  // Seven milliseconds of the source into the sample, for the sharp half only. Long
  // enough that the two halves are well out of phase from the first cycle; short
  // enough that the attack is still the attack. Kept inside the audio, and inside the
  // loop for a sample that loops, so it can never start past where it can play.
  //
  if Offset and (FWideSign > 0) and (FSound <> nil) then
  begin
    if FSound.Loops and (FSound.LoopTo > FSound.LoopFrom) then
      EndAt := FSound.LoopTo
    else
      EndAt := Length(FSound.Audio);

    FPos := MinD(FSound.SourceRate * 0.007, MaxD(0.0, EndAt - 1.0));
  end;
end;

procedure TS950Voice.SetWide(Cents, Spread: Double);
var
  Theta: Double;
begin
  if FWideSign = 0 then
    Exit;

  FWideRatio := Exp2D(FWideSign * Cents / 1200.0);

  // Equal-power: pi/4 is the centre, 0 hard left, pi/2 hard right.
  Theta := Pi64 / 4.0
           * (1.0 + FWideSign * Clamp(Spread, 0.0, 1.0));
  FWideGainL := CosD(Theta);
  FWideGainR := SinD(Theta);
end;

procedure TS950Voice.Render(Left, Right: PSampleBuffer; Count: Integer; SharedPhase: Double;
                            SharedCycle: UInt32; SharedStep: Double);
var
  Stereo, Own, Loops: Boolean;
  PanL, PanR, S, Dif: Single;
  Buffer: PSampleBuffer;
  Audio: PSampleBuffer;
  Last, Done_, Block, N, J, Shape, I0, I1: Integer;
  Dt, StepNow, PerCycle, Fade, Cents, SharedNow, Wave, Bend, Warp, Glide, By, Mid: Double;
  GainNow, GainEnd, GainStep, EndAt, Len, Frac, X: Double;
  SharedCycles: UInt32;
begin
  if FStage = vsIdle then
    Exit;

  // hoisted out of the sample loop: neither changes while a block renders
  Stereo := Right <> nil;
  // A wide half folds into the mono path at -3 dB, the level its pan law gives it at
  // the centre, so the two halves together are one note's worth there too.
  if Stereo then
  begin
    PanL := FOutL * FWideGainL;
    PanR := FOutR * FWideGainR;
  end
  else
  begin
    if FWideSign <> 0 then PanL := HalfPowerF else PanL := OneF;
    PanR := ZeroF;
  end;
  Buffer := Left;

  Audio := PSampleBuffer(Pointer(FSound.Audio));
  Last  := Length(FSound.Audio) - 1;
  Dt    := 1.0 / FSampleRate;

  Done_ := 0;
  while (Done_ < Count) and (FStage <> vsIdle) do
  begin
    //
    // The control block, shortened for a fast LFO: sixteen updates a cycle at least,
    // down to four samples, so an LFO the Rate trim has pushed into the audio range
    // is followed rather than sampled into a few steps. Only when it is fast AND
    // moving something - at the S950's own rates this is the 32 it always was.
    //
    // Tempo sync puts every voice on the shared LFO, which the engine locks to the grid.
    Own := FOwnLfo and (FTrims.LfoSync < 0.5);

    Block := ControlBlock;
    if (FLfoCents <> 0.0) or (FLfoFilterOctaves <> 0.0) then
    begin
      if Own then StepNow := FLfoStep else StepNow := SharedStep;
      if StepNow > 0.0 then
      begin
        PerCycle := 2.0 * Pi64 / StepNow;
        // std::min (ControlBlock, static_cast<int> (perCycle / 16.0)), taken in double
        // first so a vanishing step cannot overflow the integer
        Block := MaxI(4, Trunc(MinD(ControlBlock, PerCycle / 16.0)));
      end;
    end;

    N := MinI(Block, Count - Done_);

    // A note-off waiting out its latency lets go at the block where the wait ends:
    // within one control block, 0.7 ms at 48 kHz, of when the machine would.
    if FPendingRelease > 0 then
    begin
      FPendingRelease := FPendingRelease - N;
      if FPendingRelease <= 0 then
        Release;
    end;

    // --- the modulators, once per block. The envelopes are rebuilt from the trims
    // first, so a control moved under a held note is heard on that note.
    ApplyTrims;

    // The LFO before the filter, because To Filter lets it move the cutoff too.
    if FFadeSeconds > 0.0005 then
    begin
      if FFadeT >= FFadeSeconds then Fade := 1.0 else Fade := FFadeT / FFadeSeconds;
    end
    else
      Fade := 1.0;
    Cents := FLfoCents * Fade;
    Shape := LRound(FTrims.LfoShape);
    // The shared LFO where it has got to by this block, not where the stretch began.
    SharedNow    := SharedPhase + SharedStep * Done_;
    SharedCycles := SharedCycle;
    while SharedNow >= 2.0 * Pi64 do
    begin
      SharedNow := SharedNow - 2.0 * Pi64;
      Inc(SharedCycles);
    end;

    if Own then
      Wave := LfoWave(Shape, FLfoPhase, FLfoSeed, FLfoCycle)
    else
      Wave := LfoWave(Shape, SharedNow, SharedLfoSeed, SharedCycles);
    if Cents = 0.0 then
      Bend := 1.0
    else
      Bend := Exp2D(Cents * Wave / 1200.0);

    FLfoNow := Wave * Fade;
    FFilter.SetCutoff(CutoffNow, FSampleRate, FTrims.Resonance / 100.0);
    //
    // WARP rides on top of the LFO, both as multipliers on the playback rate.
    //
    // Worked out once a block like everything else here. The bend is fastest at the
    // very start - 34 ms at byte 14 = 0 - so a long control block steps down it rather
    // than gliding, which is the trade the LFO already makes and is well under a cent
    // per step at the block sizes a host asks for.
    //
    // Changing the playback rate drags the filter with it for free: the cutoff and the
    // ceiling both derive from the rate the audio leaves at.
    //
    Warp := WarpRatio(FOwn.WarpVelocity, FOwn.WarpDepth, FOwn.WarpTime,
                      FVelocity, FSinceOn);

    //
    // The glide, taken at the MIDDLE of this control block and then moved on by the
    // whole of it. Reading it at the start would leave every block half a block
    // behind, and a fast glide over a wide interval would land a little late.
    //
    // A constant-pitch keygroup ignores the key, so it ignores a glide between keys
    // too - otherwise a drum would swoop every time the line under it moved.
    //
    Glide := 1.0;
    if FGlideOffset <> 0.0 then
    begin
      By := FGlidePerSecond * N * Dt;

      if not FOwn.ConstantPitch then
      begin
        if FGlideOffset > 0.0 then
          Mid := MaxD(0.0, FGlideOffset - By * 0.5)
        else
          Mid := MinD(0.0, FGlideOffset + By * 0.5);
        Glide := Exp2D(Mid / 12.0);
      end;

      if FGlideOffset > 0.0 then
        FGlideOffset := MaxD(0.0, FGlideOffset - By)
      else
        FGlideOffset := MinD(0.0, FGlideOffset + By);
    end;

    StepNow := FStep * Bend * Warp * FWheelBend * Glide * FWideRatio;

    GainNow  := FGain;
    GainEnd  := EnvelopeAfter(N * Dt);
    GainStep := (GainEnd - GainNow) / N;

    Loops := FSound.Loops and (FSound.LoopTo > FSound.LoopFrom);
    if Loops then EndAt := FSound.LoopTo else EndAt := Length(FSound.Audio);

    for J := 0 to N - 1 do
    begin
      //
      // Round the loop, or off the end.
      //
      // The end to test against is the LOOP end, which for a sample whose loop
      // runs to its last word is one frame past the last readable one. Testing
      // against the array instead let the position sit in the gap between them,
      // where it was neither wrapped nor finished, and the voice simply stopped
      // after one pass. In the C# that cost three of the four failures the first
      // run of EngineCheck reported; do not "tidy" it back.
      //
      //
      // An ALTERNATING loop turns round at each end instead of wrapping.
      //
      // Reflecting about the end - pos' = 2*end - pos - is what makes the cycle 2N
      // frames with the end frame played twice, which is what the hardware does:
      // four loop lengths from 20 to 128 all autocorrelated at exactly 2N, never
      // 2N-2. Reflecting about end-1 instead would give 2N-2 and be a tenth of a
      // semitone flat on a short loop.
      //
      if (FDir < 0) and (FPos < FSound.LoopFrom) then
      begin
        FPos := 2.0 * FSound.LoopFrom - FPos;
        FDir := 1;
        if FPos >= EndAt then FPos := EndAt - 1;
      end
      else if (FDir > 0) and (FPos >= EndAt) and Loops and FSound.Alternates then
      begin
        FPos := 2.0 * EndAt - FPos;
        FDir := -1;
        if FPos < FSound.LoopFrom then FPos := FSound.LoopFrom;
      end
      else if FPos >= EndAt then
      begin
        if not Loops then
        begin
          FStage := vsIdle;
          Exit;
        end;

        Len := FSound.LoopTo - FSound.LoopFrom;
        repeat
          FPos := FPos - Len;
        until not (FPos >= EndAt);
        if FPos < 0 then FPos := FSound.LoopFrom;
      end;

      // interpolate towards the next frame, which for the last one is wherever
      // the loop restarts rather than off the end of the array
      I0 := Trunc(FPos);
      if I0 > Last then I0 := Last;

      I1 := I0 + 1;
      if I1 > Last then
      begin
        if Loops then I1 := FSound.LoopFrom else I1 := Last;
      end;

      Frac := FPos - I0;
      Dif  := Audio^[I1] - Audio^[I0];      // in float, as the C++'s audio[i1] - audio[i0]
      X    := Audio^[I0] + Dif * Frac;

      S := FFilter.Process(X) * GainNow;
      Buffer^[Done_ + J] := Buffer^[Done_ + J] + S * PanL;
      if Stereo then Right^[Done_ + J] := Right^[Done_ + J] + S * PanR;
      GainNow := GainNow + GainStep;

      FPos := FPos + StepNow * FDir;
    end;

    FGain    := GainEnd;
    FT       := FT + N * Dt;
    FFadeT   := FFadeT + N * Dt;
    FSinceOn := FSinceOn + N * Dt;

    // the filter's clock, which no amplitude stage change resets
    FVcfT := FVcfT + N * Dt;
    if FVcfReleasing then FVcfReleaseT := FVcfReleaseT + N * Dt;

    FLfoPhase := FLfoPhase + FLfoStep * N;
    if FLfoPhase > 2.0 * Pi64 then
    begin
      FLfoPhase := FLfoPhase - 2.0 * Pi64;
      Inc(FLfoCycle);
    end;

    AdvanceStage;
    Done_ := Done_ + N;
  end;
end;

//
// Where the cutoff is, `at` seconds into the note.
//
// The base and the depth are worked out here rather than kept from the note's start,
// because the player's two trims sit on top of them and those move while the note is
// held. Both are applied in the panel's own units - the trim is added to the stored
// 0..99 cutoff and to the signed amount, and the measured curve is read afterwards -
// so the control bends the filter the way the machine's own does, steepening as it
// climbs, rather than sliding it a flat number of octaves.
//
// With both trims at zero this is exactly what it was before they existed, which is
// what keeps the conformance numbers honest.
//
function TS950Voice.VcfEnvelopeHeld(At: Double): Double;
begin
  if At < FVcfAttack then
  begin
    if FVcfAttack > 0 then Result := At / FVcfAttack else Result := 1.0;
    Exit;
  end;

  if At < FVcfAttack + FVcfDecay then
  begin
    if FVcfDecay > 0 then
      Result := 1.0 - (1.0 - FVcfSustain) * ((At - FVcfAttack) / FVcfDecay)
    else
      Result := FVcfSustain;
    Exit;
  end;
  Result := FVcfSustain;
end;

function TS950Voice.CutoffNow: Double;
var
  Env, Base, BaseAmount, Depth, Hz: Double;
begin
  //
  // The release runs the envelope's contribution back to nothing in a straight line -
  // the same shape the decay has - so the filter returns to the keygroup's own cutoff
  // as the note dies, rather than holding whatever brightness it happened to have when
  // the key came up.
  //
  if FVcfReleasing then
  begin
    // A fixed RATE, not a fixed time - see cal::ReleaseIsARate. A release from half
    // depth takes half as long, because the release byte sets the speed the envelope
    // falls at rather than when it arrives.
    if FVcfRelease > 0.0005 then
      Env := MaxD(0.0, FVcfReleaseFrom - FVcfReleaseT / FVcfRelease)
    else
      Env := 0.0;
  end
  else
    Env := VcfEnvelopeHeld(FVcfT);

  Base := CutoffHz(FOwn.ZoneFilter + FTrims.Cutoff, FSampleRate);

  //
  // A programme with no filter envelope of its own contributes no amount, so an
  // untrimmed keygroup moves the cutoff by nothing at all - exactly as before these
  // controls existed. Dial an amount in and it has the flat envelope above to apply it
  // to, which is a constant offset until a decay or a sustain is dialled in as well.
  //
  if FOwn.VcfWritten then BaseAmount := FOwn.VcfAmount else BaseAmount := 0;
  Depth :=
      (Clamp(BaseAmount + FTrims.Amount, -50.0, 50.0) / 50.0) * EnvOctaves;

  // The LFO last, if To Filter asks for it: not the S950's, and nothing at zero.
  Hz := Base * Exp2D(FCutoffShift + Env * Depth + FLfoNow * FLfoFilterOctaves);
  if Hz > FCeiling then
    Result := FCeiling
  else if Hz < FFloorHz then
    Result := FFloorHz
  else
    Result := Hz;
end;

//
// Where the amplitude envelope will be in `ahead` seconds.
//
// The decay and the release are straight lines in DECIBELS, not in amplitude. That is
// measured: a stored decay of 80 fell 2.9, 2.7, 3.0, 3.0, 2.7, 2.9 dB per fifth of a
// second, dead constant for two and a half seconds. A line in amplitude hangs near the
// peak and then drops off a cliff, which is audibly another instrument.
//
function TS950Voice.EnvelopeAfter(Ahead: Double): Double;
var
  At: Double;
begin
  At := FT + Ahead;

  case FStage of
    vsAttack:
      if FAttack > 0 then Result := FPeak * MinD(1.0, At / FAttack) else Result := FPeak;

    vsDecay:
      if FDecay <= 0.0005 then
        Result := FSustain
      else
        Result := Fall(FPeak, FSustain, MinD(1.0, At / FDecay));

    vsRelease:
      if FReleaseTime <= 0.0005 then
        Result := 0.0
      else
        //
        // A RATE: cal::VcaReleaseDb in one release time, from wherever the key came up,
        // and it keeps falling. This used to run from releaseFrom to 1e-4 over exactly
        // one release time, which is 80 dB from a note at full level - twice the
        // machine's speed - and made a quiet note fade in the same wall-clock time as a
        // loud one, which is a duration rather than a rate.
        //
        Result := FReleaseFrom
                  * PowD(10.0, -VcaReleaseDb / 20.0 * (At / FReleaseTime));
  else
    Result := FSustain;
  end;
end;

procedure TS950Voice.AdvanceStage;
begin
  case FStage of
    vsAttack:
      if FT >= FAttack then begin FStage := vsDecay; FT := 0.0; end;

    vsDecay:
      if FT >= FDecay then begin FStage := vsSustain; FT := 0.0; FGain := FSustain; end;

    vsRelease:
      // The gain alone decides when the note is over. It used to end at
      // t >= releaseTime as well, which with a RATE cuts the tail off after one
      // release time however loud the note still is - a click on any long release.
      if FGain <= 2e-4 then FStage := vsIdle;
  else
  end;
end;

end.
