# PascalJUCE — JUCE audio, MIDI and plug-ins for Free Pascal / Delphi

There are two parts:

1. **Audio apps:** a plain C ABI (`juce_c_audio.dll`) over JUCE 8's audio, MIDI
   and audio-file modules, plus Pascal units for Free Pascal/Lazarus and Delphi.
2. **Plug-ins:** write **VST3 / LV2 / Standalone** (and, on macOS, **AU**)
   instruments and effects in Pascal. JUCE handles the plug-in formats; your
   code subclasses `TJucePlugin`, and can draw its own editor with Pascal
   controls (knobs, sliders, switches, buttons, meters), built in code or
   **designed visually in the Lazarus or Delphi form designer** and loaded
   from the embedded .lfm/.dfm at run time. See
   **[docs/PLUGINS.md](docs/PLUGINS.md)**, or start with the step-by-step
   **[tutorial: build a simple synth with Lazarus](docs/TUTORIAL_LAZARUS_SYNTH.md)**.

```
include/juce_c_audio.h        C API for apps (the contract)
src/juce_c_audio.cpp          C++ implementation over JUCE
pascal/juce_c_audio.pas       raw 1:1 Pascal imports (cdecl)
pascal/JuceAudio.pas          app object layer: devices, MIDI, files
pascal/JucePlugin.pas         plug-in base class (no DLL dependencies)
pascal/JuceUI.pas, JuceControls.pas, JuceCanvas.pas
                              custom plug-in editors: controls drawn by JUCE
pascal/JuceLayout.pas         builds an editor from a designed .lfm/.dfm (no LCL/VCL)
pascal/design/                design-time controls + TCanvas back end (LCL/VCL only)
packages/lazarus/, delphi/    IDE packages: "PascalJUCE" palette, ParameterId editor
pascal/JuceTypes.pas          shared sample/channel array types
plugin/                       C++ plug-in wrapper + its C ABI (juce_c_plugin.h)
cmake/PascalJUCE.cmake        pascaljuce_add_plugin()
examples/console_demo/        device listing + MIDI-controlled sine demo
examples/plugins/PascalSynth/ template instrument (VST3/LV2/Standalone)
examples/plugins/TinySynth/   the finished synth of docs/TUTORIAL_LAZARUS_SYNTH.md
examples/plugins/Scope/       oscilloscope effect: the track's audio as one trace
examples/plugins/Mz101/       Mz101_Pascal: the Mz101 SH-101 emulation, ported (GNU AGPL v3)
examples/plugins/Mz303/       Mz303_Pascal: the Mz303 TB-303 emulation, ported (GNU AGPL v3)
examples/plugins/Mz808/       Mz808_Pascal: the Mz808 TR-808 emulation, ported (GNU AGPL v3)
examples/plugins/Mz909/       Mz909_Pascal: the Mz909 TR-909 emulation, ported (GNU AGPL v3)
plugins/                      your plug-ins go here (built automatically)
tests/                        C, Pascal and plug-in-hosting tests
external/JUCE                 JUCE 8.0.17-security checkout (downloaded if missing)
```

## What's wrapped

| Area | API |
|---|---|
| Lifecycle | initialise/shutdown (creates JUCE's message thread), message pumping, hi-res clock |
| Audio devices | device types & devices, open/close/restart, get/set setup (device, rate, block size, 256-channel sets), sample rates, buffer sizes, latency, bit depth, channel names, CPU load, xruns, change notifications, test tone |
| Virtual device | a built-in software device (8 in / 8 out, real-time or as-fast-as-possible; inputs silent, a test tone, or loopback of the outputs) for tests, CI, headless and offline rendering |
| Audio callback | process / about-to-start / stopped callbacks; MIDI from enabled inputs (or injected from the UI) delivered sample-accurately with each block |
| MIDI devices | enumerate inputs/outputs, default device, open input with callback, open output, send now, send timed block |
| Buffers | `AudioBuffer<float>` (gain, ramps, copy/add, magnitude, RMS), `MidiBuffer` (add, iterate) |
| MIDI helpers | message description, note names, note→Hz; Pascal builders for note on/off, CC, program change, pitch bend |
| Audio files | read and write WAV/AIFF/FLAC/Ogg on every platform, streaming or whole-file load (MP3/WMA and Core Audio formats are left out for security, see SECURITY.md) |

## Licence

PascalJUCE's own code is under the [MIT licence](LICENSE). Anything built with it
contains JUCE (AGPLv3 or a commercial JUCE licence), the VST3 SDK (MIT) and the
libraries JUCE bundles. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for what that means when you
distribute a plug-in. The build copies every required licence text into a
`licenses` folder in each bundle.

## Build (Windows x64, clang)

Requirements: Visual Studio 2026 with **Desktop development with C++** and
**C++ Clang tools for Windows** (ClangCL). The CMake bundled with Visual Studio
is fine. Pascal tests and plug-ins need a 64-bit Free Pascal: CMake looks in
`C:\lazarus*\fpc\*\bin\x86_64-win64` and on `PATH`; otherwise pass
`-DFPC_EXECUTABLE=...`.

```powershell
cmake --preset windows-x64-clang
cmake --build --preset windows-x64-clang-release
ctest --preset windows-x64-clang-release
```

Output: `build/x64-clang/bin/Release/juce_c_audio.dll`. It links the C runtime
statically, so it only depends on Windows system DLLs. The same build
produces the example plug-in
(`build/x64-clang/examples/plugins/PascalSynth/PascalSynth_artefacts/Release/`).

## Build (Linux x86_64 and arm64)

Tested on Ubuntu 22.04 (x86_64 and arm64, GCC 11) in CI. The arm64 build is
also the one for a **Raspberry Pi 5** running 64-bit Raspberry Pi OS
(Bookworm); see [Raspberry Pi](docs/PLUGINS.md#raspberry-pi). On Debian or
Ubuntu:

```sh
sudo apt-get install g++ cmake ninja-build pkg-config \
  libasound2-dev libfreetype-dev libfontconfig1-dev \
  libx11-dev libxcomposite-dev libxcursor-dev libxext-dev libxi-dev \
  libxinerama-dev libxrandr-dev libxrender-dev \
  fpc            # Free Pascal 3.2.2: Pascal tests and plug-ins
  # optional: lazarus (design-time packages and their tests), xvfb (headless test runs)

cmake --preset linux-x64          # or linux-arm64 (the same build, its own folder)
cmake --build --preset linux-x64
ctest --preset linux-x64          # headless: xvfb-run -a ctest --preset linux-x64
```

CMake 3.25 or newer is needed for the presets (3.22 without them). Output:
`build/linux-x64/bin/libjuce_c_audio.so`, and the plug-ins under
`build/linux-x64/examples/plugins/PascalSynth/PascalSynth_artefacts/Release/`.
The library needs only glibc, libstdc++, ALSA and (for GUI code) the X11
libraries, which JUCE loads at run time. JACK is off, as in JUCE's
defaults.

## Build (macOS, Apple Silicon and Intel)

Tested on macOS 15 (arm64 and x86_64) in CI. Needs the Xcode
command line tools (`xcode-select --install`), and [Homebrew](https://brew.sh)
for the rest:

```sh
brew install cmake ninja fpc
cmake --preset macos               # this Mac's architecture, macOS 11 or later
cmake --build --preset macos
ctest --preset macos
```

Output: `build/macos/bin/libjuce_c_audio.dylib` and the VST3, AU, LV2 and
Standalone builds of the example plug-in. Every product is signed ad hoc
(see [Distributing on macOS](docs/PLUGINS.md#macos-signing-notarisation-and-gatekeeper)
for Developer ID signing). Free Pascal compiles one architecture per build:
for universal binaries, build `macos-arm64` and `macos-x86_64` and combine
them with `lipo` (docs/PLUGINS.md). The Lazarus package tests are skipped on
macOS unless `LAZBUILD_EXECUTABLE` points at a Lazarus installation.

### Sanitizers

Every platform has an AddressSanitizer preset (`windows-x64-clang-asan`,
`linux-x64-asan`, `linux-arm64-asan`, `macos-asan`); Linux and macOS also
have UndefinedBehaviorSanitizer presets (`*-ubsan`). Configure, build and
test them like the release presets. CI runs the Linux x86_64 ASan build on
every push, with longer fuzz runs.

### Tests

`ctest` runs:

| Test | What it covers |
|---|---|
| `c_api_test` | every C function: arguments, errors, threads, strings, buffers, MIDI validation, files, and the virtual audio device (plus a real device if present) |
| `test_app_units` | `JuceAudio.pas`, built with range/overflow checks and `heaptrc` (leaks fail), on the virtual device |
| `test_plugin_unit` | `JucePlugin.pas` through its exported entry point with a fake host, plus ABI layout checks |
| `fuzz_midi`, `fuzz_audio_files`, `fuzz_plugin_state` | reproducible fuzzing of the attacker-controlled inputs |
| `test_ui_unit` | `JuceUI.pas` / `JuceControls.pas` through the editor ABI with a fake host: binding, mouse, gestures, menus, lifetime, published properties, 1000 editors (`heaptrc`) |
| `editor_test` | the PascalSynth editor (loaded from its designed form) offscreen: rendering against `tests/data/ui` reference PNGs, simulated mouse, host automation, popup menu, window closed mid-edit, 1000 editors |
| `test_layout_unit` | `JuceLayout.pas`: the embedded PascalSynth form against the code-built panel, .dfm vs .lfm, every class and property text -> binary -> controls, strict/lenient, scaling, every truncation and 3000 mutations of a form, oversized and deeply nested input (`heaptrc`) |
| `design_props_current` | the design-time property lists (`pascal/design/JuceDesignGen.inc`) match the run-time controls |
| `lazarus_package_*`, `lcl_design_test` | the Lazarus packages build (with `lazbuild`, private config, nothing installed); the design-time controls render the PascalSynth form like JUCE does (pixel comparison), and what the designer saves loads back with every property intact |
| `fuzz_editor_scenario`, `fuzz_editor` | the editor API against a C++ library that calls it with hostile arguments, wrong threads and stale handles; then random calls in every callback |
| `plugin_host_*` | the built VST3/LV2 bundles loaded through JUCE's hosting: instrument, effect, MIDI out, state, missing, tampered and replaced libraries |
| `mz101_editor_test`, `mz303_editor_test`, `mz808_editor_test`, `mz909_editor_test` | the Mz*_Pascal panels (designed forms) offscreen: rendering against reference PNGs, knobs and faders by mouse, MIDI learn end to end, lights, the keyboard, scaling. Each example's `verify/build_verify.cmd` also checks its engine sample for sample against the original C++ one |
| `scope_test` | the Scope example's window offscreen: audio passed through, the trace, TIME and TRIGGER set with the mouse and saved, damaged state ignored |
| `library_integrity_*` | every copy of each Pascal library in the bundles has the SHA-256 the wrapper records (and, on macOS, a valid signature) |
| `pe_flags_*` (Windows), `hardening_*` (Linux, macOS) | the shipped binaries carry the exploit mitigations in SECURITY.md (checked with the PE header, `readelf` or `otool`) |

Tests that cannot run somewhere are listed by ctest as *Not Run (Disabled)*,
with the reason printed at configure time: `pe_flags_*` outside Windows, and
the Lazarus tests where `lazbuild` is not found (macOS by default). Tests that
need hardware skip those parts at run time and say so: a real audio device
(none on CI machines) and the Windows MIDI Services loopback ports (Windows
only; there is no portable loopback MIDI device). On Linux the GUI tests need
an X display: on a headless machine run ctest under `xvfb-run` with a window
manager (see `.github/scripts/headless.sh`).

The reference images in `tests/data/ui` were rendered on Windows; text is
what differs elsewhere (another default font and rasteriser). `editor_test`
therefore finds the text pixels and holds everything else to the same limit
on every platform (at most 0.2% of pixels off by more than 24 levels;
measured 0% on Windows and Linux arm64, 0.05% on Linux x86_64, 0.02% on
macOS); text areas may differ in up to 35% of their pixels off Windows
(measured 24-29%). The LCL test allows 6% of the whole panel off Windows
(measured 4.4% on Linux, 3.0% on Windows, where the limit stays 4%).


For an AddressSanitizer run (overflows and use-after-free abort the tests):

```powershell
cmake --preset windows-x64-clang-asan
cmake --build --preset windows-x64-clang-asan
ctest --preset windows-x64-clang-asan
```

See **[SECURITY.md](SECURITY.md)** for the threat model and defences.

## Using it from Pascal

1. Put `juce_c_audio.dll` next to your executable. The bitness must match:
   a 64-bit program needs the 64-bit DLL. On Linux and macOS, Free Pascal
   links `libjuce_c_audio.so` / `libjuce_c_audio.dylib` by name: pass its
   folder with `-Fl<dir>` and give the program an rpath so it finds the
   library beside itself (`-k-rpath=$ORIGIN` on Linux, quoted in a shell,
   on macOS `install_name_tool -add_rpath @executable_path <program>` after
   linking), or install it in a library folder.
2. Add `pascal/` to the unit search path (Lazarus: *Project Options →
   Paths → Other unit files*; Delphi: *Search path*).
3. `uses JuceAudio;`. That single unit is enough.

```pascal
procedure TForm1.FormCreate(Sender: TObject);
begin
  JuceInitialise;                              // once, on the main thread
  FDevices := TJuceAudioDeviceManager.Create;
  FDevices.OnAudio := HandleAudio;             // set handlers while no device is open
  FDevices.Initialise(0, 2);                   // 0 inputs, 2 outputs
  if JuceDefaultMidiInput <> '' then
    FDevices.SetMidiInputEnabled(JuceDefaultMidiInput, True);
end;

procedure TForm1.HandleAudio(Sender: TJuceAudioDeviceManager;
  Inputs: PJuceChannelArray; NumInputs: Integer;
  Outputs: PJuceChannelArray; NumOutputs: Integer;
  NumSamples: Integer; const Midi: TJuceMidiView);
begin
  // audio thread: Outputs^[channel]^[sample] := ...  (sample < NumSamples)
  Midi.Enumerate(HandleMidiEvent);
end;

procedure TForm1.FormDestroy(Sender: TObject);
begin
  FDevices.Free;                               // free every Juce object first
  JuceShutdown;
end;
```

Device settings use a plain Pascal record with real strings and channel sets:

```pascal
Setup := FDevices.Setup;
Setup.SampleRate := 48000;
Setup.OutputChannels := [0, 1];
Setup.UseDefaultOutputChannels := False;
FDevices.Setup := Setup;
```

Command-line build of the demo with FPC 64-bit:

```powershell
C:\lazarus64\fpc\3.2.2\bin\x86_64-win64\fpc.exe -Mdelphi -Fupascal -FEbuild\x64-clang\bin\Release examples\console_demo\JuceConsoleDemo.dpr
build\x64-clang\bin\Release\JuceConsoleDemo.exe --seconds 5 --midi
```

On Linux (on macOS: drop the `-k` option, use `build/macos/bin`, then run
`install_name_tool -add_rpath @executable_path build/macos/bin/JuceConsoleDemo`):

```sh
fpc -Mdelphi -Fupascal -Flbuild/linux-x64/bin '-k-rpath=$ORIGIN' \
    -FEbuild/linux-x64/bin examples/console_demo/JuceConsoleDemo.dpr
build/linux-x64/bin/JuceConsoleDemo --seconds 5 --midi
```

### Rules worth knowing

- **Threads.** `OnAudio` runs on the audio thread and `TJuceMidiInput`
  handlers on a MIDI thread. Don't allocate, lock, touch the UI, `WriteLn` or
  `TThread.Synchronize` there: `Close` and `Free` wait for a running callback,
  so a callback that waits for the main thread deadlocks. `OnAudioStart` and
  `OnAudioStop` run on the thread that opens or restarts the device, normally
  the main thread. `OnChange` runs on the main thread. Call everything else
  from the main thread: device functions that return a result fail with an
  error elsewhere, and plain getters (`SampleRate`, `IsDeviceOpen`, ...)
  return 0 / False off the main thread. Inside a manager's own `OnAudio`,
  that manager's open-device getters (`SampleRate`, `BlockSize`, channels,
  CPU, xruns) also work; device lists and MIDI-input enablement do not.
- **Open devices after construction.** `Initialise`, `SetSetup`, `Restart`
  and `TJuceMidiInput.Start` raise inside a constructor: if the constructor
  raised later, Pascal would run the destructor without stopping the device
  first. Open them after `Create` returns, or override `AfterConstruction`
  (call `inherited` first).
- **Never write `Obj.Create;`** on an existing object (instead of
  `Obj := TClass.Create;`). It is made harmless (a manager closes its device,
  a MIDI input stops), but under Free Pascal `AfterConstruction` runs again and
  an exception in a subclass constructor frees the object behind your variable.
- **Creating and freeing** a device manager happens on the main thread.
  Freeing one elsewhere raises `EJuceError` and leaves the
  object alive (so with `FreeAndNil` the variable is already `nil`: keep a
  second reference if you need to retry).
- **Handlers** can only be assigned on the main thread while no device is
  open, because changing a method pointer that the audio thread is reading is
  a race. Free (or `Close`) the manager *before* freeing objects its handlers
  use: closing runs `OnAudioStop`, and in-flight `OnAudio` calls finish first.
- **Exceptions.** The Pascal trampolines catch every exception, so none can
  unwind into C++. Exceptions raised in callbacks, including in MIDI handlers
  called from `OnAudio`, are counted; read the count with
  `ConsumeCallbackErrorCount`.
- **FPU.** `JuceInitialise` masks floating-point exceptions on the main thread,
  because JUCE code run from your message loop assumes C/C++ defaults. The
  previous mask is restored by the last `JuceShutdown`; use
  `JuceInitialise(False)` to leave it alone. Calls into the library are safe
  either way, because the library masks and restores the FP state around
  every call.
- **Shutdown.** `JuceShutdown` raises if device managers or MIDI devices are
  still alive, if other threads are still inside library calls, or if it is
  the last call and runs inside `JuceDispatchMessages` (e.g. from a timer).
  Free everything first. A manager you forget to free is closed when the
  program exits; if its `OnAudio` is blocked waiting for the main thread at
  that moment (`TThread.Synchronize`), the program hangs on exit.
- **Message loop.** VCL and LCL apps on Windows and macOS need nothing extra.
  Console apps, and Linux GUI apps, must call `JuceDispatchMessages`
  periodically (from a `TTimer` in a Linux GUI).
- **Strings.** Everything crossing the C boundary is UTF-8, and malformed UTF-8
  is rejected. The Pascal layer converts to and from `string` in both FPC and
  Delphi. In Free Pascal, `string` uses the system code page unless told
  otherwise: set `DefaultSystemCodePage := CP_UTF8` (Lazarus apps already
  do, via LazUTF8) to handle file names outside that code page, and use
  `{$CODEPAGE UTF8}` in sources with non-ASCII literals. A device name
  longer than 255 UTF-8 bytes raises instead of being silently truncated.
  A string containing `#0` raises `EJuceError` (`JUCE_C_INVALID_ARGUMENT`)
  rather than being cut short at the C boundary.
- **Free Pascal on Unix:** the units pull in `cthreads` themselves (JUCE
  calls back on its own threads, which FPC cannot handle without a thread
  manager). Plug-in libraries leave thread start-up to the host process,
  since doing it inside library initialisation could deadlock the loader.

## Options

- **ASIO**: set `JUCE_ASIO=1` in `CMakeLists.txt`. JUCE bundles the Steinberg
  ASIO SDK (GPLv3 or Steinberg's ASIO licence); read THIRD_PARTY_NOTICES.md
  first.
- **Platforms**: Windows x64, Linux x86_64 and arm64, macOS arm64 and x86_64,
  each built and tested in CI (`.github/workflows/ci.yml`). 32-bit targets
  are not built or tested.
  The builds CI keeps (its workflow artifacts) are test builds, not release
  binaries: they are signed ad hoc at most and built from whatever was pushed.
- **Delphi**: the units are written for Delphi too, but have only been compiled
  with Free Pascal in Delphi mode so far. Command-line `dcc64` builds need the unit scope
  names (`-NSSystem;Winapi`), because the units use `SysUtils`, `Types` and
  `Math` unqualified; IDE projects have them by default.
