# Writing plug-ins in Pascal

PascalJUCE builds **VST3**, **LV2**, **Standalone** and, on macOS, **AU**
plug-ins. Your DSP lives in a Pascal library. JUCE provides the plug-in formats,
host communication, parameter automation, state saving and the editor window,
which shows JUCE's generic editor or a panel of your own Pascal controls (see
[Editor](#editor)).

```
DAW ──VST3/AU/LV2──> wrapper (C++/JUCE, generic)  ──C ABI──>  your library (Pascal)
                     plugin/pascaljuce_plugin_processor.cpp     TJucePlugin subclass
```

The wrapper is compiled once per plug-in, because VST3, AU and LV2 bake the
name, IDs and type into the binary. It loads your library from the folder its
own binary is in, after checking the library's SHA-256 against the value
recorded at build time. That check catches a tampered or mismatched library;
to protect the whole bundle, sign your releases (see
[SECURITY.md](../SECURITY.md)). CMake handles the
compiling, hashing and copying.

## Quick start

New to plug-ins? [Tutorial: build a simple synth with
Lazarus](TUTORIAL_LAZARUS_SYNTH.md) walks through one from an empty folder,
with the designed panel.

1. Copy `examples/plugins/PascalSynth` to `plugins/MySynth`. Everything under
   `plugins/` is built automatically.
2. In `plugins/MySynth/CMakeLists.txt`, rename the target and set:
   - `PRODUCT_NAME`
   - `PLUGIN_CODE`: 4 characters, unique per plug-in
   - `MANUFACTURER_CODE`: 4 characters, at least one capital, the same for
     all your plug-ins
   - `BUNDLE_ID` (e.g. `com.yourname.mysynth`) and `COMPANY_WEBSITE`: unique
     to you
   - `LV2URI` if you don't want the default `<COMPANY_WEBSITE>/plugins/<name>`
   - `KIND`, which must match the kind you pass to `JuceRegisterPlugin`
3. Write your DSP in a `TJucePlugin` subclass (see `SimpleSynth.pas`) and
   your panel in a `TJuceEditor` subclass (see `SynthEditor.pas`), or delete
   `CreateEditor` to get the generic editor.
4. Build:

```sh
cmake --preset windows-x64-clang     # Linux: linux-x64 / linux-arm64; macOS: macos
cmake --build --preset windows-x64-clang-release   # or: --preset linux-x64 / macos
```

(README.md lists what each platform needs installed.) The output is in
`build/<preset folder>/plugins/MySynth/MySynth_artefacts/Release/`, e.g.
`build/x64-clang/...` on Windows or `build/linux-x64/...`.

### Where to install

Copy the whole bundle folder: it contains `<target>_pascal.dll` / `.so` /
`.dylib` next to the wrapper binary, and the `licenses` folder.

| Format | Output | Windows | Linux | macOS |
|---|---|---|---|---|
| VST3 | `VST3/My Synth.vst3` (folder) | `C:\Program Files\Common Files\VST3` | `~/.vst3` (you), `/usr/lib/vst3` or `/usr/local/lib/vst3` (everyone) | `~/Library/Audio/Plug-Ins/VST3` (you), `/Library/Audio/Plug-Ins/VST3` |
| LV2 | `LV2/My Synth.lv2` (folder) | `%APPDATA%\LV2` | `~/.lv2`, `/usr/lib/lv2` or `/usr/local/lib/lv2` | `~/Library/Audio/Plug-Ins/LV2` |
| AU | `AU/My Synth.component` | - | - | `~/Library/Audio/Plug-Ins/Components` (you), `/Library/Audio/Plug-Ins/Components` |
| Standalone | `Standalone/My Synth[.exe/.app]` | anywhere | anywhere (with its `.so` beside it) | `/Applications` or anywhere |

On Debian-based distributions (Ubuntu, Raspberry Pi OS) the system folders
are `/usr/lib/vst3` and `/usr/lib/lv2`, or the `/usr/local/lib/...` ones for
software you install by hand; hosts also search `~/.vst3` and `~/.lv2`.
Install with `cp -r`, which keeps the files' execute bits; on macOS use
`ditto` (or the Finder), which keeps the signatures. After installing an AU,
`killall -9 AudioComponentRegistrar` makes macOS notice it without a log-out,
and `auval -v aumu <PLUGIN_CODE> <MANUFACTURER_CODE>` validates it (use
`aufx` for an effect, `aumi` for a MIDI effect).

## The library

```pascal
library MySynth;

uses JucePlugin, MySynthUnit;

exports pascaljuce_plugin_entry;   // required

begin
  // The order of declaration = the index into Ctx.Parameters.
  ParamCutoff := JuceAddFloatParameter('cutoff', 'Cutoff', 20, 20000, 2000, 'Hz');
  ParamWave   := JuceAddChoiceParameter('wave', 'Waveform', ['Sine', 'Saw'], 0);
  ParamMono   := JuceAddBoolParameter('mono', 'Mono', False);
  ParamVoices := JuceAddIntParameter('voices', 'Voices', 1, 16, 8);
  JuceRegisterPlugin(TMySynth, jkInstrument);   // jkInstrument | jkEffect | jkMidiEffect
end.
```

**Parameter ids** are 1–128 characters of `A–Z a–z 0–9 _ - .`, unique, and
saved by hosts. Never change or reuse an id once you have shipped. When you
add a parameter in a later release, give it a higher `VersionHint`; AU
requires this.

**Declaration mistakes don't raise**, because raising inside a DLL's start-up
code would crash the host's plug-in scanner. Mistakes include duplicate ids,
min ≥ max, a default outside the range, or a choice with fewer than 2 options.
Each declaration function returns `-1` instead. The plug-in then refuses to
load and shows the first error in its window and the host's log, for example
`refused to load: parameter "gain": duplicate id`. `JuceDeclarationError`
returns the same text.

```pascal
type
  TMySynth = class(TJucePlugin)
  public
    constructor Create; override;                       // allocate here
    procedure Prepare(ASampleRate: Double; AMaxBlockSize: Integer); override;
    procedure Reset; override;                          // kill voices / tails
    procedure Process(const Ctx: TJuceProcessContext); override;
    function SaveState: TBytes; override;               // optional extra state
    procedure LoadState(const Data: TBytes); override;
    function TailSeconds: Double; override;
    function ParameterToText(Index: Integer; Value: Single;
      out Text: string): Boolean; override;             // optional, e.g. '-6.0 dB'
  end;
```

What `Process` gets in `TJuceProcessContext`:

| Member | Meaning |
|---|---|
| `Channel(ch)^[i]` | audio, in place: effects read input here and overwrite it with output. `nil` for an invalid channel |
| `NumSamples`, `NumInputChannels`, `NumOutputChannels` | block geometry; `NumSamples` can change every block |
| `MidiEvent(n)^` (`Data`, `Size`, `SamplePosition`) | incoming MIDI for `0..NumMidiEvents-1`, time-ordered, one complete message each. `nil` for an invalid index |
| `Param(index)` | current parameter value in plain units (Hz, ms, choice index, 0/1); 0 for an invalid index |
| `Transport^` | `Bpm`, `PpqPosition`, `IsPlaying`, time signature, … (`HasInfo = 0` if the host gave none) |
| `IsNonRealtime` | 1 while the host renders offline |
| `MidiEventsDropped` | events dropped this block: malformed (truncated, meta, bad SysEx) or beyond the per-block limit (16,384) |

The raw `Channels^`, `MidiEvents^` and `Parameters^` arrays are also there for
speed, but they're unchecked. The bounds-checked accessors cost a comparison
each.

Host services on `TJucePlugin`:

- `SampleRate`
- `SendMidi`: inside `Process` only; needs `KIND midi_effect` or
  `MIDI_OUTPUT ON`; invalid messages are dropped
- `SetParameter` / `GetParameter`, with `BeginGesture` / `EndGesture` around
  continuous changes
- `SetLatencySamples`
- `SetMeter`: publish a level for the editor; any thread, real-time safe
- `ScopeWrite`: send samples to the editor's oscilloscopes (`TJuceScope`)
  instead of the output; see [Oscilloscopes](#oscilloscopes)
- `Log`

Called from inside `Prepare`, `Process`, `Reset` or the state methods,
`SetParameter`, the gestures and `SetLatencySamples` reach the host shortly
afterwards, from the host's message thread. Changes are coalesced: the host
gets each parameter's latest value and balanced gestures, never a flood.
Latency set in `Prepare` is delivered before activation completes.
Hosts react to these synchronously (VST3 hosts restart the plug-in on a
latency change), which would otherwise re-enter your library from inside its
own callback. `GetParameter` still returns the value the host last delivered.

### Rules

- **Real-time:** `Process` runs on the host's audio thread. No `GetMem`, string
  or dynamic-array work, locks, file I/O or UI there. Allocate in `Create` or
  `Prepare`. `NumSamples` never exceeds the `MaxBlockSize` given to `Prepare`:
  the wrapper splits larger host blocks (MIDI positions re-based), so buffers
  of `MaxBlockSize` samples are always enough. `NumSamples` can be 0 (hosts
  flush parameters that way); then any MIDI event has position 0.
- **State must round-trip.** Hosts save and restore your state whenever they
  like. JUCE's LV2 host and Reaper do it around every sample-rate change, by
  saving, destroying and recreating the plug-in, then restoring. So `SaveState`
  must return everything that `LoadState` needs, including data you only
  received through `LoadState`. Parameters are saved and restored by the
  wrapper; use `SaveState`/`LoadState` only for anything extra.
- **`LoadState` data is untrusted**, because it comes from project files that
  users download. Check lengths and ranges before using anything, as the
  template does. `LoadState` never runs at the same time as `Process`.
- **MIDI is untrusted:** the wrapper drops malformed events, but still check
  `Size` before reading `Data[n]`.
- **Threads beyond `Process`:** some hosts call `Reset` on the audio thread,
  so keep it real-time safe. `Prepare`, `Reset`, `LoadState` and `SaveState`
  never run at the same time as `Process`, and `Process` never runs before
  `Prepare`. `ParameterToText` and `TailSeconds` may run on any thread at any
  time, so read only data that doesn't change.
- **Values you can rely on:** `Prepare` gets a sample rate of 1 Hz-10 MHz and
  a block size of 1-1,048,576. Parameter values (in `Process`, `GetParameter`
  and `ParameterToText`) are always finite and inside their declared range.
  Transport tempo is 1-1000 BPM, positions are finite and within +-2^40, and
  the time signature is 1-64 over a power of two up to 64.
- **Exceptions:** each boundary catches them. An exception in `Process`
  silences that block and increments `ProcessErrors`, so the host doesn't
  crash. Non-finite output samples (NaN, Inf) are replaced with 0 before the
  host sees them. FPC's Debug stack check (`-Ct`) does not cover host threads,
  so unbounded recursion in `Process` still crashes the host.
- **Latency:** report it from `Prepare`, or whenever it changes. VST3 hosts
  pick up a change asynchronously, through their message loop.
- **Floating point:** the wrapper masks FP exceptions around every call. Don't
  unmask them yourself.

## Editor

By default a plug-in shows JUCE's generic editor: one control per
parameter. To draw your own, override `CreateEditor` and build a panel of
Pascal controls. JUCE owns the window, so the same code works in every host
on Windows, macOS and Linux; no LCL or VCL is involved.

```pascal
uses JucePlugin, JuceUI, JuceControls;

type
  TMyEditor = class(TJuceEditor)
  public
    constructor Create(APlugin: TJucePlugin); override;
  end;

constructor TMyEditor.Create(APlugin: TJucePlugin);
var
  Knob: TJuceKnob;
begin
  inherited Create(APlugin);
  SetSize(300, 200);                   // 16..4096 pixels
  Knob := TJuceKnob.Create(Root);      // Root: the editor's top control
  Knob.SetBounds(20, 20, 76, 104);
  Knob.Caption := 'CUTOFF';
  Knob.ParameterId := 'cutoff';        // bound when the window opens
  Knob.Hint := 'Filter cutoff';        // tooltip
end;

function TMySynth.CreateEditor: TJuceEditorBase;
begin
  Result := TMyEditor.Create(Self);    // nil (the default): the generic editor
end;
```

That is a panel built in code. You can instead design it visually in the
Lazarus or Delphi form designer and load it with one call; the result is the
same controls (see "Designing a panel in Lazarus or Delphi" below). The
template (`examples/plugins/PascalSynth/SynthEditor.pas`) does that: its
panel (a waveform switch, three knobs, an output meter) lives in
`SynthEditorForm.lfm`, and the constructor only loads it and attaches a
right-click menu to the knobs.

<a name="building-a-panel-in-code"></a>The code-built version of the template
panel, for comparison (it gives exactly the same controls; the layout test
checks this):

```pascal
constructor TSynthEditor.Create(APlugin: TJucePlugin);
var
  Panel: TJucePanel;
  Wave: TJuceSwitch;
  Meter: TJuceMeter;
  Caption: TJuceLabel;

  procedure AddKnob(const Id, Title, Tip: string; X: Integer);
  var
    Knob: TJuceKnob;
  begin
    Knob := TJuceKnob.Create(Panel);
    Knob.SetBounds(X, 44, 76, 104);
    Knob.Caption := Title;
    Knob.ParameterId := Id;
    Knob.Hint := Tip;
    Knob.OnContextMenu := ControlMenu;
  end;

begin
  inherited Create(APlugin);
  SetSize(480, 300);
  Panel := TJucePanel.Create(Root);
  Panel.SetBounds(6, 6, 468, 288);
  Panel.Caption := 'PASCAL SYNTH';
  Panel.Color := $FF30343B;
  Panel.GradientColor := $FF23262B;
  Wave := TJuceSwitch.Create(Panel);
  Wave.SetBounds(16, 60, 150, 64);
  Wave.Caption := 'WAVE';
  Wave.Positions := 3;
  Wave.Labels := 'Sine|Saw|Square';
  Wave.ParameterId := 'wave';
  AddKnob('attack', 'ATTACK', 'Attack time', 180);
  AddKnob('release', 'RELEASE', 'Release time', 262);
  AddKnob('gain', 'GAIN', 'Output level', 344);
  Meter := TJuceMeter.Create(Panel);
  Meter.SetBounds(436, 36, 14, 132);
  Meter.MeterIndex := MeterOutput;
  Caption := TJuceLabel.Create(Panel);
  Caption.SetBounds(416, 170, 54, 18);
  Caption.Caption := 'OUT';
  Caption.FontSize := 11;
  Caption.Color := Theme.TextDim;
  TJuceScope.Create(Panel).SetBounds(16, 196, 436, 80); { the output }
  { ... and the help line, a second TJuceLabel }
end;
```

Code and forms mix freely: load a form, then add or change controls in code.

### Controls

| Control | Use | Interaction |
|---|---|---|
| `TJuceKnob` | rotary; `Style` `jksVector` (value arc, `Bipolar`, `StartAngle`/`EndAngle` in degrees) or `jksFilmstrip` (`FilmstripImage`, `FilmstripFrames`) | vertical drag (`Sensitivity` pixels for the full range), Shift = `FineFactor`, double-click = default, wheel; `JumpToClick`, `ValueBubble` |
| `TJuceSlider` | fader, `Orientation` vertical or horizontal; `Style` `jslClassic` or `jslFader` (a long-throw hardware fader: a narrow slot, a scale of `Ticks` divisions with a long mark every `MajorTicks`, a flat cap in `ThumbColor`) | drag along the track, Shift = fine, double-click, wheel; `JumpToClick` (click on the track), `ValueBubble` |
| `TJuceSwitch` | 2 to 16 `Positions`, `Labels` such as `'Sine\|Saw\|Square'`; `Style` `jswLever` or `jswSlide` (a hardware slide switch: a mark per position, a small cap in `LeverColor`, the names level with the marks, the current one lit) | lever: click a position (the labels step through); slide: click or drag to a position (one gesture); wheel |
| `TJuceButton` | `Mode` `jbmToggle` or `jbmMomentary`, optional LED (`LedPosition` beside or above the caption; `LedMeterIndex` lights it from a meter instead of the value), `Flat`, `CornerRadius`, `BorderColor` | click; `OnClick` |
| `TJuceLed` | lit by a parameter (≥ 0.5), a meter (`MeterIndex`, `Threshold`) or `Lit` | none |
| `TJuceLabel` | text (`FontSize`, `Bold`, `Alignment`) | clicks pass through |
| `TJuceLink` | a label that is a link: `Url` (https only), `Underline`, colour from the theme's `Link` | click: `OnClick`, and the host opens `Url` in the browser |
| `TJuceMeter` | level bar fed by `SetMeter` (linear peak; `MinDb`, `DecayDb`, peak hold) | none |
| `TJucePanel` | fill or gradient, border, title (`HeaderHeight`, `CaptionAlign` and `CaptionSeparator` for a centred title over a line), `BackgroundImage` | container |
| `TJuceDisplay` | a text readout: `Caption` on a plate, in its own `FontName` (e.g. `'Lucida Console'`), `FontSize`, `Bold` and colours; set `Caption` from code | none |
| `TJuceComboBox` | a drop-down: bound to a choice parameter it lists the parameter's choices (a patch menu); unbound, its `Items` | click for the menu (the current choice ticked), wheel |
| `TJuceKeyboard` | a piano keyboard, `FirstNote`..`LastNote`, the C keys labelled (`OctaveForMiddleC`); `SetNoteLit` lights keys from code (e.g. notes the host plays, published as meters) | click and drag to play: `OnNoteOn` / `OnNoteOff` |
| `TJuceScope` | an oscilloscope of the plug-in's output, no code needed: `Channel` (`jscLeft`, `jscRight`, `jscMix`), `TimeMs` across the width, `Gain`, `Trigger` (`jstRising`, `jstFalling` at `TriggerLevel`, or `jstFree`), `ShowGrid` with `GridX` × `GridY` divisions, `LineWidth`, `LineColor`, `GridColor`; see [Oscilloscopes](#oscilloscopes) | none |

Every control has `Left`, `Top`, `Width`, `Height`, `Visible`, `Enabled`,
`Caption`, `Hint` (tooltip) and `OnContextMenu`. Controls that hold a value
(`TJuceParamControl`) add `ParameterId`, `Value` (normalised 0..1),
`DefaultValue` and `OnChange`. These properties are published, with plain
types (strings, `Integer`, `Single`, enums, colours as `Cardinal`
`$AARRGGBB`), so a form file can describe a panel. A colour of `0`
(`clJuceDefault`) uses the editor's `Theme` (`TJuceTheme`: background, panel,
text, accent, track, knob, LED and meter colours, font name and size). A
designed form carries its theme in a `TJuceThemeResource` (see below); in
code, set `Theme` in the editor's constructor. Setting a control's `Hint`
while the mouse is over it updates the tooltip at once (for hints that
change, such as the CC a control answers to).

A control created with `TJuceKnob.Create(Parent)` sits on `Parent`, which owns
and frees it. Write your own control by subclassing `TJuceControl` (or
`TJuceParamControl` for one with a value) and overriding `Paint(Canvas)` and
the mouse methods. Draw only through `TJuceCanvas` (`JuceCanvas.pas`): fills
and gradients, rectangles, rounded rectangles, ellipses, lines, paths and
arcs, text, images, clipping, save/restore and translation. It knows nothing
about JUCE, so the same control can later be drawn on other surfaces.

### Parameters, gestures and threads

- A bound control finds its parameter by id when the window opens. Dragging
  it opens a host gesture, sets the parameter and closes the gesture on
  release, so hosts record one undo step and automation writes correctly.
  Double-click, the wheel and switch clicks are one gesture each.
- Host automation and presets move the controls: the wrapper reports
  changes on the message thread, coalesced.
- Value text comes from your `ParameterToText` (else JUCE's), plus the units
  you declared.
- **The editor never touches DSP state.** Everything in it runs on the host's
  message thread, while `Process` runs on the audio thread. Read parameters
  through the editor (bound controls do this for you). To show levels,
  publish them from `Process` with `SetMeter(Index, Value)` (one atomic store,
  real-time safe, 64 slots) and point a `TJuceMeter` or `TJuceLed` at the
  slot. The editor polls meters on a 30 Hz timer while it has any.
- Changes made from the editor reach the host after your callback returns,
  never from inside it, so a host reacting synchronously cannot re-enter your
  code.

### Menus, images, size

- `PopupMenu(Items, X, Y, Handler)` shows a menu and returns at once; the
  handler gets the chosen id later (0 if dismissed). One menu at a time per
  editor. A right click on a control raises its `OnContextMenu`, the hook for
  MIDI learn and similar.
- `AddImage('knob', Bytes)` registers a PNG or a baseline (sequential,
  single-scan, colour) JPEG (at most 32 MB encoded,
  8192 pixels a side, 16 M pixels, 256 images per editor); controls refer to
  it by name. Images belong to the editor and are freed with it.
- `SetResizeLimits(MinW, MinH, MaxW, MaxH)` lets the host resize the window;
  override `Resized` to lay out again.
- `SetScalable(MinScale, MaxScale, CornerResizer)` (or
  `SetDesignSize(W, H, MinScale, MaxScale, CornerResizer)`) makes the editor
  *scalable*: it keeps laying out and drawing at its design size (its current
  `Width` x `Height`), and the wrapper scales the whole drawing to the window,
  which the host and the user may resize with the aspect ratio kept, from
  `MinScale` to `MaxScale` (0.25..4, and 16..4096 pixels). The graphics
  context is scaled, not a bitmap: text, paths and images are rendered at the
  window's resolution and stay sharp. Mouse coordinates, `Repaint` and menu
  positions stay in design units, so controls need no change; `Scale` says how
  big it is now. The scale is remembered per plug-in instance, saved with its
  state (as one more value under the reserved id `pascaljuce.editor.scale`,
  which older wrappers ignore) and an editor opened again starts at it.
  `CornerResizer` adds JUCE's resize handle (a host may also offer its own).
  `SetResizeLimits` ends scaling. Both templates use it: PascalSynth from 75%
  to 200% (no corner), Mz101 from 50% to 200% with the corner, as the C++
  Mz101.

### Faders, knobs, value text

- `JumpToClick` (faders and knobs): a click on the track (a knob: on the ring
  of its value arc, within the sweep) moves the value there, then the drag
  continues from it, in one gesture; a click on the thumb only picks it up.
- `ValueBubble`: `jvbDrag` shows the value in a small bubble pointing at the
  thumb while dragging; `jvbDragAndHover` also for two seconds when the mouse
  comes over (as JUCE's slider popup display). It is drawn over every
  control, above or below the thumb, in the theme's `BubbleBackground`,
  `BubbleText`, `BubbleBorder` and `BubbleFontSize` (0 = the tooltip's
  colours, then the panel's; FontSize + 2).
- `OnValueText(Sender, Normalised, var Text)` on every bound control changes
  its value text (`ValueText`, the bubble): Mz101's RATE fader shows a note
  length ("1/8.") while SYNC is on HOST.

### Links, tooltips, menus

- `TJuceLink` is a clickable `TJuceLabel` (underlined, in the theme's `Link`
  colour, darker under the mouse): a click raises `OnClick` and, with `Url`
  set, asks the host to open the page. `TJuceEditorBase.OpenUrl` does the same
  from code. The wrapper opens a URL only while it delivers a user's click (a
  mouse press, release or double click, or a chosen menu item) - never while
  loading or painting - once per click and once a second, and only
  `https://` pages on a DNS host name in plain printable ASCII (see
  `open_url` in `juce_c_plugin.h`). Don't pass URLs from presets or project
  files to it: they are the user's data, not yours.
- The theme's `TooltipBackground`, `TooltipText`, `TooltipBorder`,
  `TooltipFontSize`, `MenuBackground`, `MenuText`, `MenuHighlight`,
  `MenuHighlightText`, `MenuHeader`, `MenuFontSize` (and `FontName`) style
  the wrapper's tooltip and popup-menu windows through its LookAndFeel (0 =
  JUCE's own). They are sent when the editor opens and before every menu;
  after changing the theme later, call `ThemeChanged`.

### Oscilloscopes

Put a `TJuceScope` on the panel and it shows the plug-in's output. While a
scope is open, the Pascal side of the wrapper copies the output channels
into a ring buffer after every `Process` call (32768 samples per channel,
allocated when the first scope opens, written lock-free). The scope reads
the newest samples on the editor's timer. With nothing open, the cost is
one interlocked read per block.

`Trigger` makes a steady wave stand still. Each sweep starts at the latest
point where the signal rises (or falls) through `TriggerLevel` and still
has `TimeMs` of samples after it, placed to a fraction of a sample so the
trace doesn't jitter. With no crossing (silence, a DC offset) or with
`jstFree`, it shows the newest samples. When the host stops processing, the
last sweep stays on screen. When the sweep holds more samples than the
scope is wide in pixels, each pixel column is drawn from its lowest to its
highest sample, so nothing is lost at long `TimeMs`. `TimeMs` is limited
to 8191 samples (about 170 ms at 48 kHz).

To show another signal, such as one oscillator or the signal before the
filter, set `ScopeManual := True` in the plug-in's constructor and call
`ScopeWrite(Left, Right, Count)` from `Process`. `Right = nil` sends `Left`
to both channels. Skip the work when `ScopeActive` is `False`:

```pascal
procedure TMySynth.Process(const Ctx: TJuceProcessContext);
begin
  ...
  if ScopeActive then
    ScopeWrite(PJuceSampleArray(@FOscBuffer[0]), nil, Ctx.NumSamples);
end;
```

In code, `ShowSamples(Samples, Count, Span)` puts samples of your own on a
scope, with the same triggering. In the form designer, a scope shows a
sample wave (a 220 Hz tone), so you can judge `TimeMs`, `Gain` and the
colours while you lay out the panel.

### Meters the editor predicts

Meters come from `Process`, so a panel that shows DSP state through them
(LEDs, a step readout, keys held) only follows while the host processes
audio. Where a change starts in the editor - a button the DSP reacts to, a
key - `PredictMeter(Index, Value)` shows the expected value at once; `Meter`
returns it until `Process` has run twice after it (two block ends: the DSP
has taken the input and published its own answer), then the real value
again. Mz101 does this for KEY TRANSPOSE / REST, LEGATO, the step count in
LOAD, KEY TRANSPOSE's shift and the keys it plays. What still needs audio:
notes and CCs from the host or a MIDI device, the sequencer and arpeggio
running, the step playing, and the DSP's own confirmation of a prediction.

### Lifetime

One `TJuceEditor` exists per open window, and closing the window frees it, so
don't keep references to it in the plug-in object. If the host closes the
window while your code is running (for example in reaction to a parameter
change), the editor is freed only after your callback returns. Open gestures
are always closed for the host when a control or the editor goes away.

Don't free a control from inside its own handlers (`OnChange`, `OnClick`,
`OnContextMenu`, its mouse methods): hide or disable it there, and free it
later (for example from the menu answer or a timer tick). Freeing other
controls from a handler is fine.

### The C ABI

The units wrap the "Custom editors" part of `plugin/include/juce_c_plugin.h`.
A library written in C can use it directly:

- `jcp_plugin_vtable.create_editor`: returns the library's editor object,
  fills a `jcp_editor_vtable` (`destroy`, `paint`, `mouse`, `timer`,
  `parameter_changed`, `resized`, `popup_result`) and sets the initial size.
  NULL keeps the generic editor.
- `jcp_editor_api`, passed to `create_editor`: window services (`repaint`,
  `set_size`, `set_resize_limits`, `start_timer`, `stop_timer`, `set_tooltip`,
  `show_popup_menu`); parameters (`get_parameter_count`, `find_parameter`,
  `get_parameter_normalised`, `get_parameter_default`, `normalised_to_plain`,
  `plain_to_normalised`, `get_parameter_text`, `begin_gesture`,
  `set_parameter_normalised`, `end_gesture`); `get_meter`; images
  (`create_image`, `destroy_image`, `get_image_size`); `get_text_width`; and
  the drawing functions, which take the `jcp_graphics` handle of the paint in
  progress (`draw_text`'s last argument: `JCP_TEXT_CLIP`, `JCP_TEXT_ELLIPSIS`,
  or `JCP_TEXT_FIT`, which squeezes a line to 70% before shortening it, as
  `TJuceCanvas.DrawFittedText`; older wrappers treat it as an ellipsis).
- Added later (check `struct_size`; a Pascal library uses them only if the
  wrapper has them, and still opens on an older one): `set_design_size` and
  `get_scale` (scaled editors), `open_url` (only during a user's click, https
  only), `set_look` (a `jcp_editor_look`: tooltip and menu colours and fonts).
- `jcp_host_api.set_meter`: publish a value from any thread.

All of them run on the message thread only (calls from other threads are
ignored), validate every handle, index, size, coordinate and string, and
never let an exception through. See "Custom editors" in
[SECURITY.md](../SECURITY.md).

## Designing a panel in Lazarus or Delphi

Instead of placing controls in code you can draw the panel in the IDE's form
designer. The designer shows the controls exactly as the plug-in will draw
them; you save the form as usual (.lfm or .dfm), embed that file in the
plug-in library, and `JuceLoadLayoutResource` builds the same controls at run
time. The plug-in still contains no LCL or VCL: only the form *file* goes in.

How it fits together:

- The IDE packages (`packages/lazarus`, `packages/delphi`) put a
  **PascalJUCE** page on the component palette with `TJuceKnob`,
  `TJuceSlider`, `TJuceSwitch`, `TJuceButton`, `TJuceLed`, `TJuceLabel`,
  `TJuceMeter`, `TJucePanel`, `TJuceDisplay`, `TJuceComboBox`,
  `TJuceKeyboard`, `TJuceLink`, `TJuceScope`, `TJuceImageResource` and `TJuceThemeResource`. They have the same
  class names as the run-time controls, so the saved form names the run-time
  classes directly.
- Each designer control owns an instance of the real run-time control and
  edits *its* properties; the property lists are generated from the run-time
  classes (`tools/gen_design_props.dpr`), so names, types and defaults cannot
  drift apart. Painting calls the run-time control's own `Paint` on a
  `TCanvas` back end (`pascal/design/JuceTCanvas.pas`), which rasterises
  shapes like JUCE (anti-aliased, gradients, alpha) and uses the IDE's font
  engine for text. Shapes match the plug-in to within a level or so; text is
  placed by JUCE's metrics but the glyphs come from GDI, so they differ
  slightly in shape.
- Bound controls show the parameter's default value and text in the
  designer, and the `ParameterId` property has a drop-down of the plug-in's
  parameter ids (any id can still be typed). Both come from the plug-in's
  **parameter list** next to the form (see step 3).

### 1. Install the package

**Lazarus** (tested with 4.8; use the IDE whose bitness matches your FPC):

1. *Package ▸ Open Package File (.lpk)…* and open
   `packages/lazarus/pascaljuce_design.lpk`. It finds
   `pascaljuce_lcl.lpk` (the controls) next to it.
2. In the package window: *Use ▸ Install*, and confirm rebuilding the IDE.
   Lazarus rebuilds and restarts with a **PascalJUCE** palette page.
3. To remove it later: *Package ▸ Install/Uninstall Packages…*, move
   `pascaljuce_design` to the right-hand list, *Save and rebuild IDE*.

Both packages also build without the IDE (this is what ctest does; nothing
is installed):
`lazbuild --build-all packages/lazarus/pascaljuce_design.lpk`.

**Delphi** (10.x or later; *not compiled or tested here, as no Delphi was
available: see `packages/delphi/README.md`*):

1. Open `packages/delphi/PascalJUCE_VCL.dpk` and build it for **Win32** (the
   IDE is a 32-bit process; this package is only used by the IDE, never by
   your Win64 plug-in). If a unit such as `Classes` is not found, add
   `System;Vcl;Vcl.Imaging;Winapi` to *Project ▸ Options ▸ Delphi Compiler ▸
   Unit scope names*.
2. Open `packages/delphi/PascalJUCE_Design.dpk`, build it, then right-click
   it in the Projects window and choose *Install*.

### 2. Create the form

A form for a panel is an ordinary form unit used only for designing:

1. Make a small design project next to your plug-in sources (Lazarus: a
   new *Application* saved there; the template has one,
   `examples/plugins/PascalSynth/PascalSynthDesign.lpi`, which also runs as
   a preview window). Add a new form and name it, for example
   `TSynthEditorForm` in `SynthEditorForm.pas`.
2. Set the form's **ClientWidth/ClientHeight** to the editor size and its
   **Color** to the panel background (it becomes the theme background; a
   system colour such as `clBtnFace` keeps the theme's).
3. Drop controls from the **PascalJUCE** page. `TJucePanel` holds other
   controls. Give the controls you want to reach from code a **Name**.
4. Set **ParameterId** from the drop-down. Colours are `$AARRGGBB`
   (`(theme)` = the theme colour; `...` opens a colour dialog).
5. Images: drop a `TJuceImageResource`, set its **FileName** to a PNG or
   JPEG (it is embedded in the form, up to 8 MB), and put its Name into a
   knob's `FilmstripImage` (with `Style = jksFilmstrip`, `FilmstripFrames`)
   or a panel's `BackgroundImage`.
6. Theme: drop a `TJuceThemeResource` and set its colours (text, dimmed
   text, accent, panel, border, track, button face, LEDs, meters, and the
   tooltip, menu, value-bubble and link colours) and
   **FontName**/**FontSize**. Every control whose own colour is `(theme)`
   uses them, in the designer and in the plug-in; the form's **Color**
   still sets the background.

A bigger example: `examples/plugins/Mz101` (`Mz101EditorForm.lfm`, designed
with `Mz101Design.lpi`) is a whole hardware-style synth panel - long-throw
faders, slide switches, LED buttons, a patch menu, a step readout, a
keyboard and a theme - with MIDI learn added in code (`Mz101Editor.pas`).

Never add the form unit to the plug-in's `uses`: it pulls in the LCL/VCL.
The template's `SynthEditorForm.pas` is such a unit; `SynthEditorForm.lfm`
and `SynthEditorForm.dfm` describe the same panel for Lazarus and Delphi.

### 3. The parameter list

The designer cannot run your plug-in, so it reads the parameters from a
file. Add `PARAMETER_LIST` to `pascaljuce_add_plugin` and every build writes
it (only when it changes):

```cmake
pascaljuce_add_plugin(PascalSynth
    ...
    PARAMETER_LIST    PascalSynth.params   # next to the form
)
```

The build tool `pascaljuce_params` loads the built library, asks it for its
parameters (only the declarations run; no instance is created) and writes
one tab-separated line per parameter: id, kind, name, units, range, default,
step, choices. The designer uses the first `*.params` file in the form's
folder and reloads it when it changes. You can also run it by hand, for a
library built in Delphi:
`build/x64-clang/bin/Release/pascaljuce_params MySynth.dll MySynth.params`.

Without a `.params` file the designer scans the `.dpr`/`.lpr`/`.pas` files in
the form's folder for `JuceAdd...Parameter('id', 'Name', ...)` calls with
literal arguments. That finds simple declarations (and their ranges and
defaults); ids computed at run time need the exported list. Either way the
property remains a plain text field.

### 4. Embed and load it

Both compilers turn a form file into an RCDATA resource named after the
form's class, in upper case, in binary form. Embed it in the editor unit and
load it in the constructor:

```pascal
implementation

uses JuceControls, JuceLayout;

{$IFDEF FPC}
  {$R SynthEditorForm.lfm}   // FPC converts the .lfm with fpcres
{$ELSE}
  {$R SynthEditorForm.dfm}   // Delphi compiles the .dfm into RCDATA
{$ENDIF}

constructor TSynthEditor.Create(APlugin: TJucePlugin);
var
  Knob: TJuceControl;
begin
  inherited Create(APlugin);
  JuceLoadLayoutResource(Self, 'TSynthEditorForm');  // size, background, controls
  Knob := FindControl('Attack');                     // the Name from the designer
  if Knob <> nil then
    Knob.OnContextMenu := ControlMenu;
end;
```

Events can be attached in code as above, by name. Or set them in the form
file: an event property such as `OnChange = KnobChanged` binds to a
**published** method `KnobChanged` of your editor class, which must have the
event's signature (`TNotifyEvent` for `OnChange`/`OnClick`,
`TJuceContextMenuEvent` for `OnContextMenu`; the loader cannot check this) (the design-time
controls do not show events, because the form unit's own handlers would
never run in the plug-in).

`pascaljuce_add_plugin` rebuilds the library when a `.lfm` or `.dfm` in the
source folders changes. With a Delphi-built library, rebuild in Delphi.
Other ways in: `JuceLoadLayout(Editor, Bytes)` (binary or text form data),
`JuceLoadLayoutText(Editor, Text)`, and `TJuceLayoutLoader` for options and
warnings. Several forms can be loaded into one editor (each adds its
controls to `Root`).

### 5. Build

Build the plug-in as usual (`cmake --build ...`). The form is part of the
library; nothing is read from disk at run time.

### What the loader accepts

- **Formats**: the binary component stream (`TPF0`, what `{$R}` produces in
  both compilers) and text forms (converted with `ObjectTextToBinary`).
  Lazarus and Delphi value encodings are both read, including Delphi's
  `vaDouble` and FPC's `vaUString` (value type 21, told apart by the
  property's type).
- **The form** (root object) gives `ClientWidth`/`ClientHeight` (else
  `Width`/`Height`), `Color` (plain RGB only), `Hint`, and the design DPI
  (`DesignTimePPI` in Lazarus, else `PixelsPerInch`): positions and sizes are
  scaled to 96-dpi logical pixels, so a form designed on a high-DPI screen
  gives the same editor. IDE-only form properties (`Left`, `Position`,
  `LCLVersion`, `Font.*`, `OldCreateOrder`, `TextHeight`, ...) are ignored;
  `IgnoredFormProperty` has the list. Control properties the IDE writes
  (`Cursor`, `TabOrder`, `Explicit*`, ...) are ignored too.
- **Controls**: the ready-made classes, plus your own `TJuceControl`
  descendants after `JuceRegisterLayoutClass(TMyControl)`. Properties are set
  through RTTI: integers (range-checked), `Cardinal` colours (also as
  Delphi's negative numbers), `Single`, booleans, enums, strings, events.
- **Resources**: a `TJuceImageResource` becomes an editor image of its name;
  a `TJuceThemeResource` sets the editor's `Theme` (its published
  properties, then the form's `Color` as the background). Neither may
  contain controls.
- **Strict mode** (default in debug builds: `DEBUG` defined or range checks
  on; or set `JuceLayoutStrict`): an unknown class, an unknown property or a
  value of the wrong type is an `EJuceLayoutError` naming the control and
  property. Otherwise these are skipped (an unknown class with everything
  inside it) and listed in `TJuceLayoutLoader.Warnings` and the plug-in log.
- **Limits** (the form is your own resource, but the reader is bounded
  anyway): 16 MB binary / 32 MB text, 4096 objects, nesting 32 deep, 512
  properties per object, strings 64 KB, one binary value (image) 8 MB,
  1,000,000 values in all. A malformed or truncated stream is always an
  `EJuceLayoutError` with the byte offset, never a crash; loading is
  all-or-nothing (on error no control is added).

Not supported (yet): anchors and `Align` (positions are absolute), frames and
form inheritance, collections, and palette icons and stock filmstrip images
in the packages.

## Free Pascal notes

- On Unix, `JucePlugin` pulls in `cthreads` itself: hosts call in from many
  threads. Keep `JucePlugin` first in your library's `uses` clause (or list
  `{$IFDEF UNIX}cthreads,{$ENDIF}` first): a unit initialised before the
  thread manager that starts the RTL's threading stops the program with
  "Threading has been used before cthreads was initialized". The same goes
  for programs (tests, tools) that use the units.
- `JucePlugin` makes `string` UTF-8 inside your library
  (`DefaultSystemCodePage` and the RTL's file-name code page). Only your DLL is
  affected, not the host. Locale separators that Windows reports as non-ASCII
  bytes (e.g. the French thousands separator) are replaced with ASCII ones.
  Text that still isn't valid UTF-8 reaches the host with `?` for the bad
  bytes. `ParamStr` and `GetEnvironmentVariable(AnsiString)` use ANSI APIs
  and stay lossy outside the system code page; use the `UnicodeString`/W
  versions for paths.
- Source files are read as UTF-8: the CMake build passes `-FcUTF8`. If you
  compile by hand, pass it too or put `{$CODEPAGE UTF8}` in every unit with
  non-ASCII string literals, otherwise names such as `µs` reach the host
  double-encoded (`Âµs`).
- Parameter declarations must be whole numbers within ±2^24 for `Int` and
  `Choice` parameters; values are validated when the library loads.

## Using Delphi instead of Free Pascal

The units are plain Delphi-dialect Object Pascal. Record alignment and enum
size are fixed in the units themselves, so project settings can't break the
ABI. Build the library as a **Win64** DLL in the Delphi IDE (add `pascal/` to
the search path), then point CMake at it instead of `PASCAL_SOURCE`:

```cmake
PASCAL_LIBRARY  "C:/Projects/MySynth/Win64/Release/MySynth.dll"
```

Each `cmake --build` re-hashes the DLL and copies it into the bundles, so
after rebuilding in Delphi just re-run the build. If you replace the DLL in an
installed bundle without rebuilding, the integrity check will refuse it. That
is intentional; set `INTEGRITY_CHECK OFF` only for local experiments. Delphi
compilation has not been tested in this repo yet; Free Pascal in Delphi mode
has.

## Plug-in kinds

| `KIND` | Audio | MIDI in | MIDI out | VST3 category |
|---|---|---|---|---|
| `instrument` (default) | stereo out | yes | no | Instrument\|Synth |
| `effect` | stereo in → out (mono→mono also allowed) | no (`MIDI_INPUT ON` to enable) | no (`MIDI_OUTPUT ON`) | Fx |
| `midi_effect` | none | yes | yes | Fx |

In a `midi_effect`, incoming MIDI is not passed through automatically:
`SendMidi` what you want to keep.

## Format notes

- **VST3:** instruments show many hidden extra parameters. JUCE uses them to
  carry MIDI CCs and pitch bend, which VST3 has no other way to deliver.
- **LV2:** there is no "not automatable" flag; JUCE reports every parameter as
  automatable. Parameter changes from the host reach the plug-in inside
  `Process`.
- **macOS / AU:** needs the Xcode command line tools and FPC for
  `aarch64-darwin` and/or `x86_64-darwin` (Homebrew's `fpc`). The CMake
  function adds `AU`, places `<target>_pascal.dylib` in `Contents/MacOS`,
  signs it before hashing it, and signs every product (see below). CI builds
  and tests it on Apple Silicon and Intel and runs `auval` on the AU; it has
  not been tried in Logic or other DAWs yet.

## Universal macOS binaries

Free Pascal compiles one architecture at a time, so a universal plug-in is
built in three steps: build the Pascal library once per architecture,
combine the two with `lipo`, and build the plug-in universal with that
library as `PASCAL_LIBRARY`:

```sh
cmake --preset macos-arm64  && cmake --build --preset macos-arm64
cmake --preset macos-x86_64 && cmake --build --preset macos-x86_64   # needs an x86_64-darwin FPC
lipo -create build/macos-arm64/plugins/MySynth/MySynth_pascal/Release/MySynth_pascal.dylib \
             build/macos-x86_64/plugins/MySynth/MySynth_pascal/Release/MySynth_pascal.dylib \
     -output MySynth_pascal-universal.dylib
# now point MySynth at it: PASCAL_LIBRARY MySynth_pascal-universal.dylib (instead of PASCAL_SOURCE)
cmake -S . -B build/macos-universal -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
      "-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64" -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0
cmake --build build/macos-universal
```

A universal configure stops with an error if any plug-in it builds still
uses `PASCAL_SOURCE` (so move or point the example plug-in too), and the test
suites are single-architecture (hence `BUILD_TESTING=OFF`): run the tests in
the per-architecture builds. The universal build re-signs the staged
library and hashes it, as for any prebuilt library. Homebrew's `fpc` is a
native compiler: on Apple Silicon, the x86_64 half needs the official FPC
installer (which has both compilers) or an Intel Mac. CI builds each
architecture natively instead.

## macOS: signing, notarisation and Gatekeeper

By default every product is signed **ad hoc** (`codesign --sign -`): enough
for Apple Silicon to run it on the Mac that built it, not enough for other
people's Macs. A downloaded ad-hoc-signed plug-in is quarantined, and
Gatekeeper refuses it ("cannot be opened because the developer cannot be
verified"). For your own copies, or testers who accept that, remove the
quarantine attribute after installing. Do this only for builds you made
yourself (or got directly from someone you trust): quarantine is what makes
macOS check a downloaded plug-in at all.

```sh
xattr -dr com.apple.quarantine ~/Library/Audio/Plug-Ins/VST3/"My Synth.vst3"
```

For distribution, sign with a **Developer ID Application** certificate and
the hardened runtime, then notarise:

```sh
cmake --preset macos \
  "-DPASCALJUCE_CODESIGN_IDENTITY=Developer ID Application: Your Name (TEAMID)" \
  "-DPASCALJUCE_CODESIGN_FLAGS=--options=runtime;--timestamp"
cmake --build --preset macos

# zip each bundle (ditto keeps signatures and symlinks), notarise, staple
ditto -c -k --keepParent "My Synth.vst3" "My Synth-vst3.zip"
xcrun notarytool submit "My Synth-vst3.zip" --keychain-profile <profile> --wait
xcrun stapler staple "My Synth.vst3"
spctl --assess --type install -vv "My Synth.vst3"   # or --type execute for the .app
```

(`xcrun notarytool store-credentials <profile>` stores your Apple ID or API
key once.) The build signs the Pascal library **before** it hashes it, then
signs each bundle as a whole. **Never re-sign a bundle with
`codesign --deep`**: that re-signs the Pascal library inside, changes its
bytes, and the integrity check then refuses it (the plug-in loads but stays
silent with an error editor). If you must re-sign by hand, sign the bundle
without `--deep`; the library inside is already signed with the same
identity. `ctest` (`library_integrity_*`) checks that every bundle copy still
matches its hash and has a valid signature.

Hardened runtime and library validation: a host with library validation
only loads code signed by Apple or by its own team, so it loads no
third-party plug-ins at all; DAWs that load plug-ins either carry the
`com.apple.security.cs.disable-library-validation` entitlement or host
plug-ins in a separate process (Logic and GarageBand do this for AUs). Your
Standalone app, signed with `--options=runtime`, validates the libraries it
loads: the Pascal library is signed with the same Developer ID, so it
passes. With an ad-hoc identity and the hardened runtime, the Standalone app
would refuse its own library: keep the hardened runtime for Developer ID
builds.

## Raspberry Pi

The `linux-arm64` preset is the build for a **Raspberry Pi 5** (or 4) with
**64-bit Raspberry Pi OS Bookworm**; the 32-bit OS is not supported. CI
builds and tests it on Ubuntu 22.04 for Arm (an older glibc than Bookworm's,
so its builds run on the Pi too), but it has not been run on a real Pi.

Building natively on the Pi: install the packages from README.md (Bookworm
has CMake 3.25, GCC 12 and FPC 3.2.2 in its own repositories), then

```sh
cmake --preset linux-arm64
cmake --build --preset linux-arm64 --parallel 2   # -j2 on a 4 GB Pi; 4 on 8 GB
ctest --preset linux-arm64
```

As an estimate (not measured yet), expect 25 to 45 minutes for a first build on a Pi 5 (JUCE is
compiled several times: the library, each plug-in, the test programs), and
a few minutes after that. Each compiler process can take around 1 GB, so
with 4 GB use `--parallel 2`, or add swap (`sudo dphys-swapfile`). Use
`-DPASCALJUCE_BUILD_PLUGINS=OFF -DBUILD_TESTING=OFF` to build only the
library. Cross-compiling from a PC is not set up.

Hosts that load arm64 Linux plug-ins on the Pi: **Reaper** (its
"Linux aarch64" build: VST3 and LV2), **Ardour** (LV2 and VST3; the
official binaries are x86_64 only, use the distribution's package or build
it), **Carla** (LV2 and VST3, also as a host inside other hosts), **Zrythm**
and **Qtractor** (LV2, VST3). Bitwig Studio and most commercial DAWs have no
Linux arm64 build. Install into `~/.vst3` and `~/.lv2`. Audio on the Pi goes
through ALSA (JACK and PipeWire's JACK layer through the host); the
plug-ins themselves don't care which.

## Limitations (current)

- Custom editors are built in code or designed in the Lazarus/Delphi form
  designer (absolute positions; no anchors or `Align`). The Delphi packages
  have not been compiled yet. Keyboard input to controls is not supported.
- One main bus only (no sidechain or multi-out).

## Licensing your plug-in

PascalJUCE is MIT, but every plug-in you build with it contains JUCE and the
VST3 SDK. Before you distribute one, pick a route (details in
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)):

- **Open source (JUCE under the AGPLv3):**
  - License your plug-in, Pascal code included, under the AGPLv3 or a
    compatible licence.
  - Publish its Corresponding Source: your code, PascalJUCE at the version
    you built (any JUCE patch included) and JUCE.
- **Closed source:**
  - Buy a commercial JUCE licence.

The VST3 SDK is MIT-licensed (since 3.8.0), so neither route needs an
agreement with Steinberg.

Either way, ship the `licenses` folder that the build puts in every bundle
and beside every Standalone app. If you pass `LICENSE_FILE`, your own licence
goes in that folder too:

```cmake
pascaljuce_add_plugin(MySynth
    ...
    LICENSE_FILE LICENSE)
```

VST is a trademark of Steinberg Media Technologies GmbH.
