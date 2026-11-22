# Security

PascalJUCE puts a native C/C++ layer (JUCE) between Pascal code and audio
hardware, plug-in hosts and files. This document describes what that layer
defends against, how, how to verify it, and where its responsibility ends.

## Threat model

| Input | Who controls it | Where it enters |
|---|---|---|
| Audio files | anyone who can hand the user a file | `TJuceAudioFileReader`, `JuceLoadAudioFile` → JUCE's WAV/AIFF/FLAC/Ogg (and OS) decoders |
| Plug-in state | whoever made the DAW project (downloaded projects, presets) | host → wrapper `setStateInformation` → `TJucePlugin.LoadState` |
| MIDI bytes | devices, other software, the host | MIDI inputs, `OnAudio` MIDI, plug-in `Ctx.MidiEvent` |
| Plug-in binaries on disk | anyone with write access to a plug-in folder | the wrapper loading `<target>_pascal.dll` |
| API arguments | the program using the library (bugs, not malice) | every C function |

Out of scope: a malicious *host* process (it already runs your code), the
operating system and its drivers, and the plug-in author's own Pascal code.

## Defences

### Memory safety at the C boundary
- Every C function checks its handles for NULL, and its indices, ranges and
  sizes, and returns an error instead of reading or writing out of bounds.
  Handles are not otherwise validated: a destroyed or wrong-type handle is
  undefined behaviour, as in any C API. Text is returned
  only through caller-sized buffers, always NUL-terminated and never cut
  inside a UTF-8 character. Fixed-size struct strings are read with explicit
  lengths (`strnlen`), never by scanning for a terminator.
- **All incoming text is strictly validated UTF-8** before it becomes a
  JUCE string: complete sequences only, no overlong forms, no surrogates and
  no embedded NULs, so JUCE's UTF-8 decoder only ever sees well-formed text.
- Structs carry a `struct_size` field: neither side reads or writes past the
  other side's idea of the struct, so a newer and an older binary cannot
  overrun each other.
- Size limits are enforced before JUCE sees a request:
  - audio buffers: at most 1024 channels, 2^29 - 1 samples per channel and
    2^30 samples in total;
  - audio files: 1 to 256 channels for reading, 255 for writing; writer
    sample rates 1 Hz to 10 MHz;
  - MIDI messages: at most 65529 bytes, and
    at most 256 MB of events in one caller-built MIDI buffer (queued device
    and `add_midi_message` traffic is bounded by JUCE dropping what is not
    taken within about one second);
  - `send_block`: at most 8192 events, a sample rate of 1 Hz to 10 MHz, and
    a start time at most a day ahead.
- **Audio files whose header describes an impossible format are rejected
  before any samples are read.** That covers 0 or more than 256 channels,
  more than 64 bits per sample, non-standard WAV/AIFF sample widths and
  implausible sample rates. Whole-file loads of WAV/AIFF are capped at what
  the file's size can hold, and compressed formats at 1024 samples per byte
  of file, so a tiny file cannot force a huge allocation.
- **JUCE never parses WAV/AIFF metadata.** The library walks the chunk list
  itself (`src/pascaljuce_riff.h`) and gives JUCE a synthesized file with
  only the format and audio chunks, so none of JUCE's metadata parsers run
  on untrusted input. A chunk that claims more bytes than the file has is rejected;
  only a truncated audio chunk is clamped, so cut-short recordings still open.
- Reads never ask JUCE for frames past the end of a file; the library
  zero-fills those itself.
- MIDI data must be exactly one complete message: a status byte plus the
  right number of data bytes, or a terminated SysEx. Anything else is
  rejected, so a truncated message can never be sent with garbage bytes.
- Iterating a MIDI buffer locks it against changes from the visitor, which
  would otherwise invalidate the live iterator.

### Untrusted plug-in state
The wrapper treats project state as hostile, and **JUCE's XML and base64
parsers never see it**. Plug-in state uses a small fixed format
(`plugin/pascaljuce_state.h`): JUCE's usual binary header, then one exact
XML layout that the wrapper writes and parses itself. The parser accepts
only what the writer produces. It never recurses, allocates no more than
the limits allow, and rejects anything else, even XML that means the same
thing. An earlier version pre-scanned the XML and then handed it to JUCE;
review found ways past the scan, so that design was dropped.
- total size is limited (64 MB, custom data included);
- at most 2 x the declared parameter count of entries; ids are 1-128
  characters of `A-Z a-z 0-9 _ - .`; values must be finite numbers and are
  clamped to each parameter's range; the first entry for an id wins;
- missing parameters are reset to their defaults;
- the custom blob must be strict RFC 4648 base64 and is decoded with a size
  limit;
- numbers are written and read in the "C" locale whatever the host has set,
  so state saved under one locale loads under any other.

The wrapper also sanitises what hosts send while playing. Parameter values
reach Pascal finite and within their declared range: a host's NaN becomes the
default. Transport data is checked too: tempo must be finite and 0-1000 BPM,
positions finite, and the time signature 1-64 over a power of two up to 64.
A zero denominator would otherwise be an integer division fault in Pascal.
`Process` never gets more samples than the `MaxBlockSize` given to `Prepare`:
larger host blocks are split, with MIDI re-based to each part. `Prepare`,
`Release`, `Reset`, state calls and instance destruction never overlap
`Process`. Output samples that are NaN or infinite are replaced with 0
before the host mixes them.
Hosts may react synchronously to some notifications, so a library calling
`SetLatencySamples` from `Prepare` or `Process` could otherwise have
`Release`, `Prepare` or state calls run inside its own callback.
So the wrapper never notifies the host from inside a library call or from any
thread but the message thread. Each parameter's latest value and wanted
gesture state are recorded and delivered on the message thread, coalesced, so
nothing is lost and gestures stay balanced; latency set in `Prepare` is
delivered as soon as `Prepare` has returned. Lifecycle calls re-entering from
inside a library call on the same thread (tracked per thread, so several
instances and threads cannot confuse it) are ignored. Destruction waits for a
delivery in progress on the message thread, so a host that destroys the
plug-in on another thread cannot free it mid-delivery.

Bypassed blocks never reach the library, but their MIDI is validated, clamped
to the block and capped exactly like normal output. Each chunk of a split
block gets a transport advanced to its own start.

The Pascal side gets a bounds-safe `TBytes`; `LoadState` must still validate
its contents (the docs and template show how).

### Untrusted MIDI inside plug-ins
Every incoming event is checked before the Pascal `Process` sees it:
truncated, meta (`FF`) and malformed SysEx events are dropped and counted
in `MidiEventsDropped`. Outgoing MIDI is validated and capped at 64 KB per
block, so a plug-in cannot grow memory on the audio thread.

### Plug-in library loading
- The wrapper loads its Pascal library by full path from its own bundle
  folder. It resolves the library's dependencies **only from System32**
  (`LOAD_LIBRARY_SEARCH_SYSTEM32`), never from the bundle folder, the current
  directory or `PATH`.
- **Integrity check** (on by default): CMake records the library's SHA-256 in
  the wrapper at build time. Before loading, the wrapper:
  1. opens the file with writers and deleters denied, and hashes it;
  2. loads it through the handle's final path, with junctions and symlinks
     resolved;
  3. confirms afterwards that the mapped image is the same file object
     (same volume and file ID) as the one it hashed.

  On Linux it loads the very descriptor it hashed (`/proc/self/fd/N`, kept
  open until loading is done). On
  macOS it checks the device and inode after loading. A modified or replaced
  library is refused, and the plug-in reports the problem.
- **What this check does and doesn't protect against.** It detects a Pascal
  library that was modified, corrupted or swapped after the build, and a
  library from a different build. It does **not** stop an attacker who can
  write to the bundle folder from replacing the *wrapper* too, since the
  wrapper carries the expected hash. Only code signing covers the whole
  bundle: Authenticode on Windows, a Developer ID with notarisation on macOS.
  Sign your releases.
- Residual risk: on Windows and macOS the identity check runs after the
  library is mapped. An attacker able to rename directories on the bundle's
  path during that window could get a different file's initialisation code
  to run, although it would then be refused. That attacker can already
  replace the wrapper, as above.
- On Linux the library is loaded from the very file descriptor that was
  hashed, so renames cannot swap it, but an attacker who can write to the
  file in place during loading still could. On macOS the identity check runs
  after `dlopen`, so it detects a swap but cannot stop the swapped library's
  initialisers. On both, code signing (library validation on macOS) is the
  real protection; Windows holds a deny-write handle throughout.
- If the library cannot be loaded, the plug-in stays silent, shows an error
  window, and hands the host back the project's state unchanged, so saving
  a project in that state does not destroy the user's settings.

### Containment
- No C++ exception crosses into Pascal and no Pascal exception crosses into
  C++: every boundary function catches everything.
- A Pascal exception in an audio callback silences that whole block, both in
  plug-ins and in `TJuceAudioDeviceManager.OnAudio`, and is counted. The
  host keeps running.
- Floating-point exceptions are masked around every call that does FP work
  or calls into JUCE or a driver, in either direction, and the caller's FP
  state is restored afterwards. That includes the x87 control word on 32-bit
  x86.
- Device state is only read on the message thread, or for the open device
  of a manager inside that same manager's callback. Device lists and MIDI
  enablement are message-thread-only, because JUCE changes them while the
  device keeps running. Getters called from elsewhere return their
  documented fallback values. Destroying a device manager from another thread is
  refused rather than allowed to race JUCE's message delivery.
- Re-entry is refused. Every call that changes or destroys a device manager,
  and its start, stop and change callbacks on the message thread (including
  restarts JUCE does on its own, e.g. when a device is unplugged), mark it
  busy until they return. Changing or destroying a busy manager returns
  `JUCE_C_INVALID_STATE`, even when the attempt comes from another manager's
  callback nested inside it; in Pascal it raises, and `Free` keeps the object
  alive. The same applies from inside the manager's own change callback. Message
  dispatch is refused inside such calls. Without this an outer call could
  keep using a freed device.
- Opening, starting, stopping or destroying any MIDI input from inside any
  MIDI-input callback is refused, because on Windows all inputs on a device
  share one client list that JUCE walks while delivering. A Pascal `TJuceMidiInput` closes its device before any
  subclass destructor runs, so the handler never sees half-destroyed fields.
- WAV and AIFF files are opened through one handle and never reopened by
  path, so a file rewritten while it is being opened cannot reach JUCE's
  chunk parsers.
- A final `juce_c_shutdown` and a MIDI device being opened on another thread
  are serialised by a handshake, so no handle can be created while JUCE shuts
  down.

### Build hardening
- C/C++ binaries on Windows: stack cookies (`/GS`), Control Flow Guard
  (`/guard:cf`), ASLR, DEP and CET shadow-stack compatibility (`/CETCOMPAT`).
  On Linux/macOS: `-fstack-protector-strong` and `_FORTIFY_SOURCE=2`, plus
  full RELRO and a non-executable stack on Linux.
- Pascal plug-in libraries: built with relocations, then given ASLR,
  high-entropy ASLR and DEP by `tools/pe_flags` (FPC cannot set these from a
  unit). This applies to prebuilt Delphi libraries too. Control Flow Guard is
  not available for FPC/Delphi code.
- `ctest` checks that every shipped binary carries these flags.
- JUCE is pinned to an exact commit, not a movable tag. A reviewable patch
  to JUCE itself is applied when present (see "Fixes to JUCE").
- Debug builds of Pascal plug-in libraries enable FPC's range, overflow,
  stack and object checks.
- On macOS, the Pascal library is signed before it is hashed, so signing
  cannot invalidate the recorded hash.

## Fixes to JUCE

Fuzzing and review through this framework also found security problems in
JUCE itself and in code it bundles (found in 8.0.6; most are still present in
8.0.17-security). They have been
reported privately to the JUCE team, and the details are withheld here until
fixes are released or the 90-day disclosure window ends. The fixes are a
patch to JUCE, which will be published here at the same time.

Until then, this repository builds against stock JUCE 8.0.17-security, and CMake warns
that it is doing so. The library's own checks described above still apply.
Some of the problems lie inside JUCE code that this library cannot guard
from outside.

To build with the patch once you have it, place it at
`patches/juce-8.0.17-pascaljuce-security.patch`, or pass its path with
`-DPASCALJUCE_JUCE_PATCH=<file>`. CMake applies it to the JUCE checkout
idempotently and stops if it does not apply cleanly.

## Verification

```powershell
# Normal build + all tests
cmake --preset windows-x64-clang
cmake --build --preset windows-x64-clang-release
ctest --preset windows-x64-clang-release

# AddressSanitizer build: every test and fuzz run aborts on any overflow,
# use-after-free or invalid free
cmake --preset windows-x64-clang-asan
cmake --build --preset windows-x64-clang-asan
ctest --preset windows-x64-clang-asan

# Longer fuzzing campaigns (ASan build)
build\x64-clang-asan\bin\Release\fuzz_c_api.exe file <iterations> <seed>
build\x64-clang-asan\bin\Release\fuzz_c_api.exe midi <iterations> <seed>
build\x64-clang-asan\fuzz_plugin_state_artefacts\Release\fuzz_plugin_state.exe <iterations> <seed>
```

What the suites cover:

| Suite | Checks |
|---|---|
| `c_api_test` | every C function, including NULL handles, out-of-range indices, the buffer-size protocol, thread misuse, MIDI validation and file-writer bounds |
| `test_app_units`, `test_plugin_unit` | the Pascal units, compiled with range/overflow/object checks and `heaptrc` (any leak fails the test), including concurrent heap use from JUCE threads and ABI struct-size handling |
| `fuzz_midi`, `fuzz_audio_files`, `fuzz_plugin_state` | deterministic mutation fuzzing of the three attacker-controlled inputs (run longer by hand) |
| `plugin_host_*` | the built VST3/LV2 bundles under JUCE's own hosting, including hostile state, a missing library and a tampered library |

## Limits

- **JUCE and its bundled codecs (libFLAC, libvorbis) decode untrusted files.**
  We fuzz them through this API, but we do not own them. WAV and AIFF are
  re-framed before JUCE parses them. MP3/WMA (Windows Media) and Core Audio
  formats are not offered at all: their readers were not part of the review,
  and they decode through operating-system code. Decode those with a library
  you trust and pass the samples in a buffer.
- **Integrity checking proves the library is the one built with this wrapper**,
  not that it is benign. Sign your releases (Authenticode on Windows, a
  Developer ID with notarisation on macOS); signing also covers the wrapper.
- **The macOS/AU path is not yet tested**, including bundle signing.
- **Pascal code is the author's responsibility.** The fake-huge sample array
  types are unchecked by design (speed); use `Ctx.Channel`, `Ctx.MidiEvent`
  and `Ctx.Param`, which are bounds-checked, and always honour `NumSamples`.

## Reporting a vulnerability

Please report security problems privately to the maintainer rather than in a
public issue, with steps to reproduce (an input file or state blob is ideal).
