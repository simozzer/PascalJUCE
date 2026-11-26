# Tutorial: build a simple synth with Lazarus

In this tutorial you write a small software synthesizer in Free Pascal, design
its control panel in the Lazarus form designer, and build it as a **VST3**,
**LV2** and **Standalone** plug-in you can play in a DAW.

The finished plug-in, **Tiny Synth**, has:

- 8 voices (8 notes at once)
- a saw or square-wave oscillator
- a resonant low-pass filter (**Cutoff** and **Resonance**)
- an envelope with **Attack** and **Release**
- a **Volume** control in dB
- a panel of knobs, a switch and an output level meter, all drawn by the
  plug-in itself in any host

It takes about an hour. You need to know Pascal, but not how plug-ins or
digital audio work. Everything new is explained as it comes up.

The finished project is in
[`examples/plugins/TinySynth`](../examples/plugins/TinySynth) if you want to
compare or get stuck. Its Pascal code and form are exactly the ones below.
Only its `CMakeLists.txt` differs (it builds as *Tiny Synth Example*), so it
doesn't clash with the copy you make in `plugins\TinySynth`.

> **Building the finished example instead of your own copy?** Its target
> names say `TinySynthExample`, not `TinySynth`, and its bundles go to a
> different folder:
>
> ```powershell
> cmake --build --preset windows-x64-clang-release --target TinySynthExample_All TinySynthExample_ParameterList
> ```
>
> Look for the bundles in
> `build\x64-clang\examples\plugins\TinySynth\TinySynthExample_artefacts\Release\`
> (for example `VST3\Tiny Synth Example.vst3`). The `TinySynth_*` targets and
> paths in the steps below only exist once you've made `plugins\TinySynth`
> yourself.

The tutorial is written for **Windows** and the 64-bit Lazarus. On Linux or
macOS the Pascal code is the same; only the build commands differ (see
[Building on Linux or macOS](#building-on-linux-or-macos)).

## How the pieces fit

A PascalJUCE plug-in has two halves:

```
DAW ──VST3/LV2──>  wrapper (C++, made for you by CMake)  ──>  your library (Pascal)
                                                              TinySynth.lpr + units
```

- **Your library** is an ordinary Pascal `library`. It holds the sound
  engine (a `TJucePlugin` subclass) and, optionally, the panel (a
  `TJuceEditor` subclass). This is the part you write.
- **The wrapper** is a C++ program built from JUCE. It speaks VST3, LV2 and
  the other formats to the host, loads your library and calls it. You never
  edit it.

You use two tools:

| Tool | What you do with it |
|---|---|
| **Lazarus** | write and check the Pascal code; draw the panel in the form designer |
| **CMake** | compile your library with Free Pascal, build the wrapper, and put both into plug-in bundles |

Lazarus cannot produce the finished plug-in by itself, because the wrapper is
C++. Its **Build** command is still useful: it checks that your code
compiles, with Lazarus's code completion and error navigation.

## 0. Before you start

You need, once:

1. **PascalJUCE built once**, as described in the [README](../README.md#build-windows-x64-clang):
   Visual Studio 2026 with *Desktop development with C++* and *C++ Clang
   tools for Windows*, then from the PascalJUCE folder:

   ```powershell
   cmake --preset windows-x64-clang
   cmake --build --preset windows-x64-clang-release
   ```

   The first build compiles JUCE and takes a while. Later builds of your
   plug-in are much quicker. Use a *Developer PowerShell for VS* window if
   `cmake` isn't found.

2. **A 64-bit Lazarus** (tested with 4.8). CMake finds its Free Pascal
   compiler by itself if Lazarus is installed in a folder named
   `C:\lazarus...`. Otherwise add `-DFPC_EXECUTABLE=<path to fpc.exe>` to the
   first `cmake` command.

3. **The PascalJUCE design package installed in Lazarus**, which puts the
   plug-in controls on the component palette:
   - *Package ▸ Open Package File (.lpk)…* and open
     `packages\lazarus\pascaljuce_design.lpk`.
   - In the package window click *Use ▸ Install* and agree to rebuild the IDE.
   - Lazarus restarts with a new **PascalJUCE** palette page.

4. Something to play it with: a **MIDI keyboard**, or a DAW with a virtual
   keyboard or piano roll (for example Reaper, Bitwig or Ableton Live).

In the steps below, `PascalJUCE\` means the folder you cloned PascalJUCE into.

## 1. Make the plug-in folder

Every folder under `PascalJUCE\plugins\` that contains a `CMakeLists.txt` is
built automatically. Create `PascalJUCE\plugins\TinySynth\` and, in it, a
file `CMakeLists.txt`:

```cmake
pascaljuce_add_plugin(TinySynth
    PRODUCT_NAME      "Tiny Synth"
    COMPANY_NAME      "Me"
    COMPANY_WEBSITE   "https://example.com"
    MANUFACTURER_CODE Mine            # 4 chars, at least one capital: the same for all your plug-ins
    PLUGIN_CODE       Tny1            # 4 chars, unique for each plug-in
    BUNDLE_ID         com.example.tinysynth
    KIND              instrument
    VERSION           0.1.0
    PASCAL_SOURCE     TinySynth.lpr
    PARAMETER_LIST    TinySynth.params
)
```

What the lines mean:

- `TinySynth` is the build target's name. The build calls your compiled
  library `TinySynth_pascal.dll`.
- `PRODUCT_NAME` is the name the DAW shows in its plug-in list.
- `MANUFACTURER_CODE` and `PLUGIN_CODE` identify the plug-in to hosts. Pick
  your own manufacturer code and keep it for all your plug-ins; give every
  plug-in a different plug-in code. Don't change them after you've shared a
  plug-in, or projects that use it won't find it.
- `KIND instrument` means: MIDI in, stereo audio out.
- `PASCAL_SOURCE` is the Lazarus project's main file, which you create next.
- `PARAMETER_LIST` asks the build to write the plug-in's parameters into
  `TinySynth.params`. The form designer reads it in step 6.

## 2. Create the library project in Lazarus

1. *Project ▸ New Project…*, choose **Library**, *OK*.
2. *Project ▸ Save Project As…*: go to `PascalJUCE\plugins\TinySynth\` and
   save as `TinySynth.lpi`. Lazarus names the main file `TinySynth.lpr`.
3. *Project ▸ Project Options…*:
   - *Compiler Options ▸ Paths ▸ Other unit files (-Fu)*: `..\..\pascal`
     (where the PascalJUCE units are).
   - *Compiler Options ▸ Custom Options*: `-FcUTF8` (source files are UTF-8;
     the CMake build uses the same switch).

   Click *OK*.

## 3. Declare the parameters

**Parameters** are the values a user (or the DAW's automation) can change:
every knob and switch on the panel is bound to one. The library declares
them when it loads, before the host creates the synth.

Replace everything in `TinySynth.lpr` with:

```pascal
library TinySynth;

{$MODE DELPHI}

uses
  JucePlugin,     // keep this first
  TinySynthDsp;

exports
  pascaljuce_plugin_entry;

begin
  ParamWave      := JuceAddChoiceParameter('wave', 'Waveform', ['Saw', 'Square'], 0);
  ParamCutoff    := JuceAddFloatParameter('cutoff', 'Cutoff', 0, 100, 60);
  ParamResonance := JuceAddFloatParameter('resonance', 'Resonance', 0, 100, 20, '%');
  ParamAttack    := JuceAddFloatParameter('attack', 'Attack', 1, 2000, 5, 'ms');
  ParamRelease   := JuceAddFloatParameter('release', 'Release', 1, 3000, 300, 'ms');
  ParamVolume    := JuceAddFloatParameter('volume', 'Volume', -48, 0, -12, 'dB');
  JuceRegisterPlugin(TTinySynth, jkInstrument);
end.
```

- `exports pascaljuce_plugin_entry` is the one function the wrapper calls
  to find your plug-in. Every PascalJUCE library has this line.
- `JuceAddFloatParameter(Id, Name, Min, Max, Default, Units)` declares a
  continuous value; `JuceAddChoiceParameter` a list of options. Each returns
  the parameter's **index**, which you keep in a variable to read the value
  later.
- The **id** (`'cutoff'`) is how hosts save the value in projects and how
  panel controls find their parameter. Never change an id once others use
  your plug-in.
- `JuceRegisterPlugin` tells the wrapper which class to create.
  `jkInstrument` must match `KIND instrument` in `CMakeLists.txt`.

Cutoff runs from 0 to 100 rather than in Hz, on purpose. Hearing is
logarithmic: the step from 100 Hz to 200 Hz sounds as big as the step from
5 kHz to 10 kHz. A knob that went straight from 20 to 20,000 Hz would spend
almost all its travel on the top few octaves. The synth turns the 0..100
into Hz itself, and shows Hz on screen (step 4).

## 4. Write the sound engine

*File ▸ New Unit*, then *File ▸ Save As…* `TinySynthDsp.pas` in the same
folder. Replace its contents with the code below, then read the explanation
after it.

```pascal
unit TinySynthDsp;

{$MODE DELPHI}

interface

uses
  SysUtils, Math, JucePlugin, JuceTypes;

var
  ParamWave, ParamCutoff, ParamResonance,
  ParamAttack, ParamRelease, ParamVolume: Integer;

const
  MeterOutput = 0;   // the meter slot the editor's level meter reads

type
  TVoice = record
    Note: Integer;          // -1 = free
    Velocity: Single;       // 0..1
    Phase, PhaseInc: Double;
    Level: Double;          // envelope, 0..1
    Releasing: Boolean;
    Ic1, Ic2: Double;       // filter state
  end;

  TTinySynth = class(TJucePlugin)
  private
    FVoices: array[0..7] of TVoice;
    FPeak: Single;
    procedure NoteOn(Note, Velocity: Integer);
    procedure NoteOff(Note: Integer);
    procedure HandleMidi(const Event: TJuceMidiEvent);
    procedure Render(const Ctx: TJuceProcessContext; First, Last: Integer);
  public
    constructor Create; override;
    procedure Prepare(ASampleRate: Double; AMaxBlockSize: Integer); override;
    procedure Reset; override;
    procedure Process(const Ctx: TJuceProcessContext); override;
    function TailSeconds: Double; override;
    function ParameterToText(Index: Integer; Value: Single;
      out Text: string): Boolean; override;
  end;

implementation

{ The Cutoff knob runs 0..100; this turns it into 20 Hz..20 kHz, so that
  every bit of the knob's travel is the same musical step. }
function CutoffToHz(Percent: Double): Double;
begin
  Result := 20 * Power(1000, Percent / 100);
end;

constructor TTinySynth.Create;
begin
  inherited Create;
  Reset;
end;

procedure TTinySynth.Prepare(ASampleRate: Double; AMaxBlockSize: Integer);
begin
  Reset;
end;

procedure TTinySynth.Reset;
var
  I: Integer;
begin
  for I := Low(FVoices) to High(FVoices) do
  begin
    FVoices[I].Note := -1;
    FVoices[I].Level := 0;
  end;
end;

function TTinySynth.TailSeconds: Double;
begin
  Result := 3.0;   // the longest release
end;

function TTinySynth.ParameterToText(Index: Integer; Value: Single;
  out Text: string): Boolean;
var
  Hz: Double;
begin
  Text := '';
  Result := Index = ParamCutoff;
  if Result then
  begin
    Hz := CutoffToHz(Value);
    if Hz < 1000 then
      Text := IntToStr(Round(Hz)) + ' Hz'
    else
      Text := FloatToStrF(Hz / 1000, ffFixed, 4, 1) + ' kHz';
  end;
end;

procedure TTinySynth.NoteOn(Note, Velocity: Integer);
var
  I, Best: Integer;
begin
  // A free voice if there is one, else steal the quietest.
  Best := 0;
  for I := Low(FVoices) to High(FVoices) do
  begin
    if FVoices[I].Note < 0 then
    begin
      Best := I;
      Break;
    end;
    if FVoices[I].Level < FVoices[Best].Level then
      Best := I;
  end;

  if FVoices[Best].Note < 0 then
  begin
    // a silent voice: start its filter from rest
    FVoices[Best].Ic1 := 0;
    FVoices[Best].Ic2 := 0;
  end;
  FVoices[Best].Note := Note;
  FVoices[Best].Velocity := Velocity / 127;
  FVoices[Best].PhaseInc := Min(0.5, 440 * Power(2, (Note - 69) / 12) / SampleRate);
  FVoices[Best].Releasing := False;
end;

procedure TTinySynth.NoteOff(Note: Integer);
var
  I: Integer;
begin
  for I := Low(FVoices) to High(FVoices) do
    if FVoices[I].Note = Note then
      FVoices[I].Releasing := True;
end;

procedure TTinySynth.HandleMidi(const Event: TJuceMidiEvent);
var
  Status, Data1, Data2: Integer;
begin
  if Event.Size < 3 then
    Exit;   // the messages we use all have 3 bytes
  Status := Event.Data[0] and $F0;
  Data1 := Event.Data[1];
  Data2 := Event.Data[2];
  if (Status = $90) and (Data2 > 0) then
    NoteOn(Data1, Data2)
  else if (Status = $80) or (Status = $90) then   // note on with velocity 0 = note off
    NoteOff(Data1)
  else if (Status = $B0) and (Data1 = 123) then
    Reset;   // All Notes Off
end;

procedure TTinySynth.Render(const Ctx: TJuceProcessContext; First, Last: Integer);
var
  I, V, Ch: Integer;
  Square: Boolean;
  AttackStep, ReleaseStep, Gain: Double;
  G, K, A1, A2, A3: Double;
  Osc, V1, V2, V3, Mix: Double;
  Buf: PJuceSampleArray;
begin
  // Read the parameters once per stretch of samples, not for every sample.
  Square := Round(Ctx.Param(ParamWave)) = 1;
  AttackStep := 1 / Max(1, Ctx.Param(ParamAttack) * 0.001 * SampleRate);
  ReleaseStep := 1 / Max(1, Ctx.Param(ParamRelease) * 0.001 * SampleRate);
  Gain := Power(10, Ctx.Param(ParamVolume) / 20) * 0.3;

  // Low-pass filter coefficients (a state-variable filter).
  G := Tan(Pi * Min(CutoffToHz(Ctx.Param(ParamCutoff)), 0.45 * SampleRate) / SampleRate);
  K := 2 - 1.9 * Ctx.Param(ParamResonance) / 100;
  A1 := 1 / (1 + G * (G + K));
  A2 := G * A1;
  A3 := G * A2;

  for I := First to Last - 1 do
  begin
    Mix := 0;
    for V := Low(FVoices) to High(FVoices) do
      with FVoices[V] do
        if Note >= 0 then
        begin
          // envelope: rise to 1, hold while the key is down, fall after
          if Releasing then
          begin
            Level := Level - ReleaseStep;
            if Level <= 0 then
            begin
              Level := 0;
              Note := -1;   // the voice is free again
              Continue;
            end;
          end
          else if Level < 1 then
            Level := Min(1, Level + AttackStep);

          // oscillator
          if Square then
          begin
            if Phase < 0.5 then Osc := 1 else Osc := -1;
          end
          else
            Osc := 2 * Phase - 1;
          Phase := Phase + PhaseInc;
          if Phase >= 1 then
            Phase := Phase - 1;

          // filter
          V3 := Osc - Ic2;
          V1 := A1 * Ic1 + A2 * V3;
          V2 := Ic2 + A2 * Ic1 + A3 * V3;
          Ic1 := 2 * V1 - Ic1;
          Ic2 := 2 * V2 - Ic2;

          Mix := Mix + V2 * Level * Velocity;
        end;

    Mix := Mix * Gain;
    for Ch := 0 to Ctx.NumOutputChannels - 1 do
    begin
      Buf := Ctx.Channel(Ch);
      if Buf <> nil then
        Buf^[I] := Mix;
    end;
    if Abs(Mix) > FPeak then
      FPeak := Abs(Mix);
  end;
end;

procedure TTinySynth.Process(const Ctx: TJuceProcessContext);
var
  E, Pos, EventPos: Integer;
  Event: PJuceMidiEvent;
begin
  FPeak := 0;
  Pos := 0;
  // Render up to each MIDI event, then apply it, so notes start on time.
  for E := 0 to Ctx.NumMidiEvents - 1 do
  begin
    Event := Ctx.MidiEvent(E);
    if Event = nil then
      Continue;
    EventPos := EnsureRange(Event^.SamplePosition, Pos, Ctx.NumSamples);
    Render(Ctx, Pos, EventPos);
    Pos := EventPos;
    HandleMidi(Event^);
  end;
  Render(Ctx, Pos, Ctx.NumSamples);
  SetMeter(MeterOutput, FPeak);   // for the editor's level meter
end;

end.
```

Press **Shift+F9** (*Run ▸ Build*). It should compile with no errors. (The
`TinySynth.dll` Lazarus writes is only a compile check. It isn't a plug-in
yet, so don't install it anywhere.) You can't *Run* (F9) a library;
you'll play the synth in step 5.

### How the sound engine works

**Blocks of samples.** Digital audio is a stream of numbers, called
*samples*, typically 44,100 or 48,000 per second (the *sample rate*). The
host doesn't ask for one sample at a time. It calls `Process` with a
*block* of a few hundred samples and expects every one of them filled in,
quickly, before the sound card needs them. `Ctx.NumSamples` is the block's
length, and `Ctx.Channel(0)^[i]` / `Ctx.Channel(1)^[i]` are the left and
right outputs.

**The methods the host calls:**

| Method | When | Here it… |
|---|---|---|
| `Create` | once, when the plug-in is created | silences all voices |
| `Prepare` | before playback, and whenever the sample rate changes | silences all voices (`SampleRate` is now valid) |
| `Process` | for every block, on the audio thread | handles MIDI and renders sound |
| `Reset` | when the host stops or jumps | silences all voices |
| `TailSeconds` | any time | says how long the sound can ring on after the last note |
| `ParameterToText` | any time | turns Cutoff's 0..100 into "1.3 kHz" for the screen |

**MIDI.** A key press arrives as a *Note On* message of 3 bytes: a status
byte (`$90`, plus the channel in its low 4 bits), the note number (60 is
middle C) and the velocity (how hard the key was struck, 1..127). Letting go
sends *Note Off* (`$80`), or a Note On with velocity 0. `HandleMidi` reads
just those, and CC 123 (*All Notes Off*). It checks `Event.Size` before
reading the bytes, because MIDI comes from outside the plug-in and can be
shorter than expected.

**Sample-accurate timing.** Each MIDI event carries the position in the
block where it happens (`SamplePosition`). `Process` renders up to that
position, applies the event, then carries on, so a note starts on the exact
sample rather than at the start of the next block.

**Voices.** Each `TVoice` plays one note. `NoteOn` takes a free voice, or,
when all 8 are busy, steals the quietest one. A voice is free again when its
release has faded to silence.

**The oscillator.** `Phase` goes from 0 to 1 once per cycle of the note.
Each sample it moves on by `PhaseInc`, the note's frequency divided by the
sample rate (note 69 is A at 440 Hz; each semitone multiplies the frequency
by the twelfth root of 2). A saw wave is just the phase scaled to -1..1; a
square wave is +1 for the first half of the cycle and -1 for the second.

**The envelope.** `Level` rises from 0 to 1 over the attack time while the
key is held, and falls back to 0 over the release time after it is let go.
Multiplying the oscillator by it makes notes fade in and out instead of
clicking.

**The filter.** Saw and square waves are bright and buzzy. The low-pass
filter removes the frequencies above the cutoff, which makes the sound darker
as you turn Cutoff down. Resonance boosts the frequencies right at the
cutoff, which gives the classic "wah" synth sound. This is a
*state-variable filter* (in Andrew Simper's
[trapezoidal form](https://cytomic.com/files/dsp/SvfLinearTrapOptimised2.pdf)):
the coefficients `G`, `A1..A3` come from the cutoff and resonance once per
stretch of samples, and each voice keeps its own filter memory in `Ic1` and
`Ic2`. The cutoff is limited to 45% of the sample rate, the highest
frequency the filter can handle.

**Volume.** The Volume parameter is in decibels; `Power(10, dB / 20)` turns
it into a multiplier (-6 dB is about half). The extra `0.3` leaves headroom
so that 8 loud notes together don't go past full scale.

**The meter.** `SetMeter(MeterOutput, FPeak)` publishes the loudest sample
of the block. The panel's level meter reads it (step 6). It is the only way
`Process` talks to the panel.

### Rules for code in `Process`

`Process` runs on the host's **audio thread**. If it takes too long, the
audio drops out with a click, and it must never wait for anything. So
inside `Process` (and everything it calls):

- **Don't allocate memory**: no `GetMem`, `New`, string building or
  `SetLength`. Allocate in `Create` or `Prepare` instead. (Tiny Synth's voices are a
  fixed array inside the object.)
- **Don't** touch files, the UI, `WriteLn`, locks, or `TThread.Synchronize`.
- Read parameters with `Ctx.Param(Index)`. Values are always inside the
  range you declared.

`ParameterToText` builds a string, which is fine, because it doesn't run inside
`Process`. It may run on any thread, though, so it only reads things that
never change (the parameter index variables).

More detail is in [PLUGINS.md, Rules](PLUGINS.md#rules).

## 5. Build and play it

From the PascalJUCE folder:

```powershell
cmake --preset windows-x64-clang
cmake --build --preset windows-x64-clang-release --target TinySynth_All TinySynth_ParameterList
```

Run the first command again whenever you add a new plug-in folder, so
CMake finds it. After that, the second command is all you need after each
change. It compiles `TinySynth.lpr` with Free Pascal, builds the wrapper,
assembles the bundles (`TinySynth_All`) and writes the parameter list
(`TinySynth_ParameterList`). The first time takes a few minutes; after a
change to your Pascal code, a few seconds. (A plain `cmake --build --preset
windows-x64-clang-release` builds everything in PascalJUCE, your plug-in
included.)

If the build stops with `MSB1009: Project file does not exist` and
`TinySynth_All.vcxproj`, CMake has no `TinySynth` target. Either
`plugins\TinySynth` doesn't exist yet, or you ran only the second command.
Create the folder (steps 1 to 4), then run both commands again. If you wanted
the finished example, use the `TinySynthExample_*` targets shown
[at the top](#tutorial-build-a-simple-synth-with-lazarus).

You'll find them in
`build\x64-clang\plugins\TinySynth\TinySynth_artefacts\Release\`:

| Folder | What it is |
|---|---|
| `Standalone\Tiny Synth.exe` | a program that runs the synth on its own |
| `VST3\Tiny Synth.vst3` | the VST3 plug-in (a folder) |
| `LV2\Tiny Synth.lv2` | the LV2 plug-in (a folder) |

You'll also find a new file `TinySynth.params` next to your sources. It lists the
parameters for the form designer.

**Try the Standalone first.** Start `Tiny Synth.exe`, click *Options*, pick
your audio device and tick your MIDI keyboard under *Active MIDI inputs*.
Play: you hear a saw wave. With no panel of your own yet, JUCE shows a
*generic editor* with a slider for each parameter. Turn Cutoff down and
Resonance up to hear the filter.

**In a DAW:** copy the whole `Tiny Synth.vst3` folder to
`C:\Program Files\Common Files\VST3` (this needs administrator rights), let
the DAW rescan its plug-ins, and add *Tiny Synth* to an instrument track.
Close the DAW before you copy a new build over the old one, because Windows
won't replace a plug-in file that is in use.

Always copy the whole bundle folder. Inside it, next to the wrapper, is
`TinySynth_pascal.dll`. The wrapper checks that DLL's fingerprint
(SHA-256) and refuses to load a DLL that was swapped in by hand, so
replacing just the DLL doesn't work.

## 6. Design the panel in Lazarus

Now give Tiny Synth its own panel. You draw it in the form designer like any
Lazarus form. The plug-in doesn't contain the form or the LCL; it embeds only
the `.lfm` file, and builds the same controls from it when the window opens.

### Create the design project

The panel needs a project of its own, because the form unit uses the LCL,
which must never end up in the plug-in.

1. *Project ▸ New Project…*, **Application**, *OK*.
2. *Project ▸ Save Project As…*: in `plugins\TinySynth\`, save the project as
   `TinySynthDesign.lpi`, and the unit as `TinySynthForm.pas`.
3. In the Object Inspector set the form's **Name** to `TinySynthForm`. Lazarus
   renames its class to `TTinySynthForm`; the plug-in will look the form up by
   that class name.

To go back to the library later, use *Project ▸ Open Recent Project*.

### Set up the form

The form itself becomes the plug-in window:

| Property | Value | Why |
|---|---|---|
| `ClientWidth` | `620` | the window's width |
| `ClientHeight` | `220` | the window's height |
| `Color` | `$00241F1E` | the window background (a very dark grey) |

### Add the controls

From the **PascalJUCE** palette page, drop a **TJucePanel** on the form, then
the other controls *inside* the panel. Set these properties in the Object
Inspector (colours on PascalJUCE controls are written `$AARRGGBB`: alpha,
red, green, blue):

| Control | Name | Left, Top, Width, Height | Other properties |
|---|---|---|---|
| TJucePanel | `MainPanel` | 6, 6, 608, 208 | Caption `TINY SYNTH`, Color `$FF30343B`, GradientColor `$FF23262B` |
| TJuceSwitch | `Wave` | 16, 60, 110, 64 | Caption `WAVE`, ParameterId `wave`, Positions `2`, Labels `Saw\|Square` |
| TJuceKnob | `Cutoff` | 136, 44, 76, 104 | Caption `CUTOFF`, ParameterId `cutoff` |
| TJuceKnob | `Resonance` | 218, 44, 76, 104 | Caption `RES`, ParameterId `resonance` |
| TJuceKnob | `Attack` | 300, 44, 76, 104 | Caption `ATTACK`, ParameterId `attack` |
| TJuceKnob | `Release` | 382, 44, 76, 104 | Caption `RELEASE`, ParameterId `release` |
| TJuceKnob | `Volume` | 464, 44, 76, 104 | Caption `VOLUME`, ParameterId `volume` |
| TJuceMeter | `OutMeter` | 566, 36, 14, 132 | MeterIndex `0` (the default) |

Positions are relative to the panel. Give each control a **Hint** too (for
example *Filter cutoff*); it becomes the tooltip.

What you see as you go:

- **ParameterId** has a drop-down listing the ids from `TinySynth.params`,
  and a bound control shows its parameter's default value. (Cutoff shows
  `60` here. The *1.3 kHz* from `ParameterToText` only appears in the
  plug-in, because the designer can't run your code.) If the drop-down is
  empty, build the plug-in once (step 5) to create the `.params` file, or
  type the id by hand. A control with a wrong id simply stays unbound, so
  check the spelling.
- The meter's **MeterIndex** `0` is the slot `Process` publishes to with
  `SetMeter(MeterOutput, ...)`.
- The designer draws the controls with the plug-in's own drawing code, so
  what you see is what the plug-in shows.

Save (*Ctrl+S*). You can press **F9** to open the form as a preview window;
it's only a picture of the panel, and doesn't make sound.

## 7. Load the panel in the plug-in

Switch back to the library project (*Project ▸ Open Recent Project ▸
TinySynth.lpi*).

*File ▸ New Unit*, save it as `TinySynthEditor.pas`, and replace its
contents with:

```pascal
unit TinySynthEditor;

{$MODE DELPHI}

interface

uses
  JucePlugin, JuceUI;

type
  TTinySynthEditor = class(TJuceEditor)
  public
    constructor Create(APlugin: TJucePlugin); override;
  end;

implementation

uses
  JuceControls, JuceLayout;

{$R TinySynthForm.lfm}   // the form file only: not the form unit

constructor TTinySynthEditor.Create(APlugin: TJucePlugin);
begin
  inherited Create(APlugin);
  JuceLoadLayoutResource(Self, 'TTinySynthForm');   // size, colours, every control
  SetScalable(0.75, 2.0, True);                     // resizable from 75% to 200%
end;

end.
```

- `{$R TinySynthForm.lfm}` compiles the form file into the library as a
  resource named after the form's class.
- `JuceLoadLayoutResource` reads that resource and creates the same controls,
  bound to the same parameters.
- `SetScalable` lets the user resize the window. Everything is drawn at the
  new size (not stretched), and a resize handle appears in the corner.
- **Never** add `TinySynthForm` (the form unit) to any `uses` clause of the
  library. It would pull the LCL into the plug-in. Only the `.lfm` file goes
  in.

Now tell the synth to use this editor. In `TinySynthDsp.pas`, add to the
class's `public` section:

```pascal
    function CreateEditor: TJuceEditorBase; override;
```

and right after `implementation`:

```pascal
uses
  TinySynthEditor;

function TTinySynth.CreateEditor: TJuceEditorBase;
begin
  Result := TTinySynthEditor.Create(Self);
end;
```

`CreateEditor` runs each time the window opens; closing the window frees the
editor again. (Without `CreateEditor`, or if it returns `nil`, you get the
generic editor.)

Check it with **Shift+F9**, then rebuild:

```powershell
cmake --build --preset windows-x64-clang-release --target TinySynth_All TinySynth_ParameterList
```

Start the Standalone again: there is your panel. Turn the knobs while you
play. The value under Cutoff is now in Hz and kHz. Double-click a knob to
reset it, and hold Shift while dragging for fine changes. The meter shows the output
level. In a DAW, automation moves the knobs too.

From now on, whenever you change the panel in the designer, save and run the
`cmake --build` command; the build notices the changed `.lfm` and rebuilds
the library.

### Your folder now

```
plugins\TinySynth\
  CMakeLists.txt          build settings
  TinySynth.lpi/.lpr      the library: parameters and registration
  TinySynthDsp.pas        the sound engine
  TinySynthEditor.pas     loads the panel
  TinySynthDesign.lpi/.lpr   design-only project (never part of the plug-in)
  TinySynthForm.pas/.lfm  the panel; only the .lfm goes into the plug-in
  TinySynth.params        written by the build, read by the designer
```

## When something goes wrong

| What you see | What to do |
|---|---|
| `Can't find unit JucePlugin` in Lazarus | set *Other unit files* to `..\..\pascal` (step 2) |
| CMake doesn't build TinySynth / no `TinySynth_All` target / `MSB1009: Project file does not exist` | check `plugins\TinySynth` exists, then run `cmake --preset windows-x64-clang` again so it finds the new folder. The finished example in `examples\plugins\TinySynth` is a different target: `TinySynthExample_All` and `TinySynthExample_ParameterList` |
| Can't find the `.vst3` you built | your copy: `build\x64-clang\plugins\TinySynth\TinySynth_artefacts\Release\VST3\`; the finished example: `build\x64-clang\examples\plugins\TinySynth\TinySynthExample_artefacts\Release\VST3\` |
| `Free Pascal (fpc) not found` | point CMake at it: `cmake --preset windows-x64-clang -DFPC_EXECUTABLE=C:\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe` (your path) |
| The window says *refused to load: parameter "…"* | a parameter declaration is wrong: a duplicate id, min ≥ max, or a default outside the range |
| No sound in the Standalone | *Options*: check the output device, and tick your keyboard under *Active MIDI inputs* |
| The DAW doesn't list the plug-in | copy the whole `.vst3` folder, then rescan plug-ins in the DAW |
| The DAW still plays the old version | close the DAW, copy the new bundle, reopen |
| `Can't find unit JuceDesignControls` in the design project | *Project ▸ Project Inspector ▸ Add ▸ New Requirement*: `pascaljuce_lcl` (Lazarus normally adds it when you drop the first control) |
| No `TinySynth.params` file | build the `TinySynth_ParameterList` target as shown in step 5 |
| A knob doesn't move anything | its `ParameterId` doesn't match an id in `TinySynth.lpr` |
| A control is missing from the panel | in a Release build, the loader skips properties and classes it doesn't know and logs a warning; check the control's class is from the PascalJUCE palette |

## Next steps

- **More controls:** add a parameter in `TinySynth.lpr`, use it in
  `Render`, rebuild once (so `TinySynth.params` lists it), then add a knob
  for it in the designer. Good first ones: a *Decay*/*Sustain* stage for
  the envelope, an envelope amount for the cutoff, a detune for a second
  oscillator.
- **Less aliasing:** the plain saw and square waves have harsh, metallic
  overtones on high notes, called *aliasing*. Look up *PolyBLEP* for a cheap
  fix of a few lines.
- **Presets and saved state:** parameters are saved with the DAW project
  automatically. For anything else, override `SaveState`/`LoadState` (see
  `examples\plugins\PascalSynth\SimpleSynth.pas`, which also shows how to
  check the loaded data).
- **An on-screen keyboard, MIDI learn, a theme, images:** the larger example
  `examples\plugins\Mz101` does all of these.
- The full reference for plug-ins, controls and the designer is
  [PLUGINS.md](PLUGINS.md).

## Building on Linux or macOS

The Pascal code, the form and the Lazarus steps are the same. Use the
platform's preset instead of `windows-x64-clang`:

```sh
cmake --preset linux-x64                                  # or linux-arm64, macos
cmake --build --preset linux-x64 --target TinySynth_All TinySynth_ParameterList
```

The bundles are in `build/linux-x64/plugins/TinySynth/TinySynth_artefacts/Release/`
(or `build/macos/...`, where there is an AU too). Where to install them is
in [PLUGINS.md, Where to install](PLUGINS.md#where-to-install). In Lazarus,
write the unit path as `../../pascal`. Keep `JucePlugin` first in the
library's `uses` clause: on Linux and macOS it starts the thread support the
host needs.

## Licence

Tiny Synth contains JUCE, so before you give your plug-in to anyone else,
read [Licensing your plug-in](PLUGINS.md#licensing-your-plug-in): either
publish it as open source under the AGPLv3, or buy a commercial JUCE
licence.
