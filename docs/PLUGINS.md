# Writing plug-ins in Pascal

PascalJUCE builds **VST3**, **LV2**, **Standalone** and, on macOS, **AU**
plug-ins. Your DSP lives in a Pascal library. JUCE provides the plug-in formats,
host communication, parameter automation, state saving and a generic editor.

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
3. Write your DSP in a `TJucePlugin` subclass (see `SimpleSynth.pas`).
4. Build:

```powershell
cmake --preset windows-x64-clang
cmake --build --preset windows-x64-clang-release
```

The output is in `build/x64-clang/plugins/MySynth/MySynth_artefacts/Release/`:

| Format | Output | Install by copying to |
|---|---|---|
| VST3 | `VST3/My Synth.vst3` (folder) | `C:\Program Files\Common Files\VST3` |
| LV2 | `LV2/My Synth.lv2` (folder) | `%APPDATA%\LV2` |
| Standalone | `Standalone/My Synth.exe` | anywhere; good for debugging |
| AU (macOS) | `AU/My Synth.component` | `~/Library/Audio/Plug-Ins/Components` |

Copy the whole bundle folder. It contains `<target>_pascal.dll` next to the
wrapper binary.

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

## Free Pascal notes

- On Unix, `JucePlugin` pulls in `cthreads` itself: hosts call in from many
  threads.
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
- **macOS / AU:** needs a Mac with Xcode, FPC for `aarch64-darwin` and/or
  `x86_64-darwin`, and Developer ID signing and notarisation before
  distribution. The CMake function adds `AU`, places
  `<target>_pascal.dylib` in `Contents/MacOS` and ad-hoc-signs it. **This
  path has not been built or tested yet.** For a universal binary, build the
  library for each architecture, combine them with `lipo`, and pass the result
  as `PASCAL_LIBRARY`.

## Limitations (current)

- The editor is JUCE's generic one: one control per parameter. A custom UI
  drawn by Pascal code is not wired up yet.
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
  - Use the VST3 SDK under the GPLv3.
- **Closed source:**
  - Buy a commercial JUCE licence.
  - Sign Steinberg's VST3 licence agreement.

Either way, ship the `licenses` folder that the build puts in every bundle
and beside every Standalone app. If you pass `LICENSE_FILE`, your own licence
goes in that folder too:

```cmake
pascaljuce_add_plugin(MySynth
    ...
    LICENSE_FILE LICENSE)
```

VST is a trademark of Steinberg Media Technologies GmbH.
