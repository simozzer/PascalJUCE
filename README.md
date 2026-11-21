# PascalJUCE — JUCE audio, MIDI and plug-ins for Free Pascal / Delphi

There are two parts:

1. **Audio apps:** a plain C ABI (`juce_c_audio.dll`) over JUCE 8's audio, MIDI
   and audio-file modules, plus Pascal units for Free Pascal/Lazarus and Delphi.
2. **Plug-ins:** write **VST3 / LV2 / Standalone** (and, on macOS, **AU**)
   instruments and effects in Pascal. JUCE handles the plug-in formats; your
   code subclasses `TJucePlugin`. See **[docs/PLUGINS.md](docs/PLUGINS.md)**.

```
include/juce_c_audio.h        C API for apps (the contract)
src/juce_c_audio.cpp          C++ implementation over JUCE
pascal/juce_c_audio.pas       raw 1:1 Pascal imports (cdecl)
pascal/JuceAudio.pas          app object layer: devices, MIDI, files
pascal/JucePlugin.pas         plug-in base class (no DLL dependencies)
pascal/JuceTypes.pas          shared sample/channel array types
plugin/                       C++ plug-in wrapper + its C ABI (juce_c_plugin.h)
cmake/PascalJUCE.cmake        pascaljuce_add_plugin()
examples/console_demo/        device listing + MIDI-controlled sine demo
examples/plugins/PascalSynth/ template instrument (VST3/LV2/Standalone)
plugins/                      your plug-ins go here (built automatically)
tests/                        C, Pascal and plug-in-hosting tests
external/JUCE                 JUCE 8.0.6 checkout (downloaded if missing)
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

### Tests

`ctest` runs:

| Test | What it covers |
|---|---|
| `c_api_test` | every C function: arguments, errors, threads, strings, buffers, MIDI validation, files, and the virtual audio device (plus a real device if present) |
| `test_app_units` | `JuceAudio.pas`, built with range/overflow checks and `heaptrc` (leaks fail), on the virtual device |
| `test_plugin_unit` | `JucePlugin.pas` through its exported entry point with a fake host, plus ABI layout checks |
| `fuzz_midi`, `fuzz_audio_files`, `fuzz_plugin_state` | reproducible fuzzing of the attacker-controlled inputs |
| `plugin_host_*` | the built VST3/LV2 bundles loaded through JUCE's hosting: instrument, effect, MIDI out, state, missing and tampered libraries |

For an AddressSanitizer run (overflows and use-after-free abort the tests):

```powershell
cmake --preset windows-x64-clang-asan
cmake --build --preset windows-x64-clang-asan
ctest --preset windows-x64-clang-asan
```

See **[SECURITY.md](SECURITY.md)** for the threat model and defences.

## Using it from Pascal

1. Put `juce_c_audio.dll` next to your executable. The bitness must match:
   a 64-bit program needs the 64-bit DLL.
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

- **ASIO**: set `JUCE_ASIO=1` in `CMakeLists.txt` and add the Steinberg ASIO SDK
  include path.
- **Linux/macOS**: the code and Pascal units are written to be cross-platform
  (library name `juce_c_audio.so` / `.dylib`), but they have only been built and
  tested on Windows x64 so far.
- **Delphi**: the units are written for Delphi too, but have only been compiled
  with Free Pascal in Delphi mode so far. Command-line `dcc64` builds need the unit scope
  names (`-NSSystem;Winapi`), because the units use `SysUtils`, `Types` and
  `Math` unqualified; IDE projects have them by default.
