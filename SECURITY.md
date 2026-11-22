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
| Editor calls and images | the plug-in library's UI code (bugs); image files it loads (e.g. downloaded skins) | `jcp_editor_api`, `create_image` → JUCE's PNG/JPEG decoders |
| Window lifetime | the host, which may close, resize or recreate the editor at any moment, including inside a callback, and may destroy the plug-in on any thread | the editor component, editor callbacks |

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

### Custom editors
A plug-in library can draw its own editor through `jcp_editor_api`
(`juce_c_plugin.h`). JUCE owns the window; the library paints with drawing
calls and reacts to mouse, timer, parameter and menu callbacks. The editor
API is treated like the rest of the C boundary: every argument is checked
before JUCE sees it, and the window's lifetime belongs to the host, not the
library.

- **One thread.** Every editor function runs on the message thread only. A
  call from any other thread is ignored (getters return 0 or -1) before any
  lock is taken, so a library thread can neither race the window nor
  deadlock against it. Library editor callbacks are made only on the message
  thread.
- **Handles are tokens, never pointers.** A `jcp_editor` is a value from a
  counter that is never reused, looked up in a registry under a lock; a
  closed editor's handle is refused. A `jcp_graphics` is valid only while its
  own `paint()` call runs: it is compared with the paint in progress, so a
  token kept for later, a forged one, or one passed to another editor draws
  nothing. Images are small integers owned by one editor and freed with it.
- **Arguments.** Coordinates must be finite and are clamped to ±100,000
  (sizes to 0-200,000, line widths to 0-1000, font heights to 1-1000); a call
  with NaN or infinity does nothing. An arc's sweep is limited to two turns
  (JUCE walks arcs in small steps), a path to 65,536 elements, and
  `save_state` nesting to 64; unbalanced saves are undone when the paint
  ends. A gradient whose two points coincide is drawn as a plain colour
  (JUCE divides by their distance). Editor sizes are clamped to 16-4096,
  timers to 1-120 Hz, justification flags masked.
- **Text** is strict UTF-8, at most 4096 bytes (ids 256, menu items 1024,
  font names 256); anything else is not used. Parameter text is copied into
  the caller's buffer, always NUL-terminated and never cut inside a
  character. Menus have at most 512 items, and `item_size` must be at least
  `sizeof(jcp_menu_item)`.
- **Images.** Only PNG and JPEG, and only after the wrapper has checked the
  whole file structure itself (`plugin/pascaljuce_image_check.h`), and only
  in a conservative subset; JUCE's automatic format detection, which also
  tries GIF, is not used:
  - PNG: signature, `IHDR` first with valid fields, every chunk inside the
    data with a correct CRC, consecutive `IDAT`s, `IEND` present;
  - JPEG: sequential Huffman only (SOF0/SOF1, 8-bit, 3 components with
    integral sampling ratios, one scan holding all of them). Every
    DQT, DHT (a valid canonical code), DRI, SOF and SOS segment is validated,
    every table a scan uses must be defined, and the data
    must reach an `EOI`. Progressive, multi-scan, grayscale and CMYK JPEGs
    are refused: a multi-scan file makes libjpeg replay the whole image once
    per scan, so a few bytes per scan header could hold the UI thread for
    hours.

  The size is taken from the header before any decoder runs: at most 8192
  pixels a side and 16 M pixels, encoded data at most 32 MB, and at most 256
  images and 64 M pixels per editor. The decoded image must have the
  header's size; it is converted to a plain software ARGB image.
- **Parameters.** Values from the library are clamped to 0..1, and NaN or
  infinity is ignored. Changes and gestures from the editor are queued and
  delivered to the host after the library's callback returns, never from
  inside it, so a host reacting synchronously cannot re-enter the library.
  Delivery itself is not re-entrant: a host that closes the editor from
  inside a parameter notification (which ends the editor's gestures) makes
  the delivery loop go round again rather than nest. That case ended a
  gesture twice before the tests caught it. Gestures an editor leaves open
  are ended when it closes. Host automation reaches the editor as coalesced
  per-parameter flags, delivered on the message thread.
- **Meters** (`set_meter`, any thread including audio) are a fixed array of
  64 atomic floats in the wrapper: the index is checked, non-finite values
  are stored as 0.
- **Opening web pages** (`open_url`). A plug-in may ask the host OS to open a
  page in the browser (a project link), so a library - or a preset or project
  value a library passes on - must not be able to run anything, open local
  files or act behind the user's back:
  - *only as the answer to a click*: accepted only while the library's own
    mouse callback for a press, release or double click, or its
    `popup_result` for a chosen item, is running (the flag is set around that
    call alone, not while the host is notified afterwards), at call depth 1,
    with no paint in progress; never from `create_editor`, `destroy`, paint,
    timers, parameter or resize callbacks, a dismissed menu, another thread or
    another editor's handle; once per click and at most once a second in the
    process;
  - *only https pages*: `https://` (scheme case-insensitive), a DNS host name
    (letters, digits and '-' labels, at least two, a top-level domain of
    letters or `xn--`; no IP address, no `localhost`, no user name, no '%'),
    an optional port 1-65535, then only `A-Z a-z 0-9 - . _ ~ : / ? # @ & + , =
    %`; '%' only before two hex digits that are not a control character; at
    most 2048 bytes. No spaces, quotes, backslashes, `$`, `` ` ``, `;`, `|`,
    `<`, `>`, `(`, `)`, `*`, `!`, `'`, braces or non-ASCII bytes;
  - *opened outside the callback*, from the message loop, never under the
    editor lock;
  - opened with the platform's URL launcher (ShellExecute, LSOpenCFURLRef,
    xdg-open);
  - test builds record the URL instead of starting a browser.
- **Scaled editors** (`set_design_size`, `get_scale`). Design sizes are
  clamped to 16-4096, scale limits to 0.25-4 and then to what keeps the window
  within 16-4096; non-finite limits refuse the call. The scale applied to the
  drawing is the window over the design size (a window whose shape is off by
  more than 1%, from a host ignoring the limits, is drawn at the smaller scale
  and the rest filled black); mouse positions are divided by it and repaint
  rectangles multiplied, still clamped. Applying a new size is several JUCE
  calls, each of which may make the host close the window: every step checks
  that the window still exists (found by the review below). A `resized`
  notification refused because the library is inside another callback is
  retried from the message loop, never lost. The remembered scale is clamped
  to the editor's limits before it is stored; read back from untrusted state
  it must be finite and is clamped to 0.25-4 (and to the editor's limits when
  used). A library parameter with the reserved id `pascaljuce.editor.scale`
  wins, and older wrappers ignore it as an unknown parameter.
- **Tooltip and menu look** (`set_look`). `struct_size` is checked before any
  other field; a non-finite font height or a font name that is not strict
  UTF-8 of at most 256 bytes refuses the whole look; heights are clamped to
  6-72; colours are plain values. The LookAndFeel is shared: an open menu's
  callback holds a reference, so a menu outliving its editor never uses a
  freed look, and the editor detaches it before it goes.
- **Lifetime.** The library's editor object is held by a shared session that
  outlives the window, the registry entry and every call in progress:
  - the library's `destroy()` runs exactly once;
  - if the host closes the window during a library callback, `destroy()`
    waits until that callback has returned, and the window is never touched
    again;
  - a menu answer arriving after the window closed is dropped, and one menu
    per editor can be open at a time;
  - editor callbacks never nest: one at a time per editor, none while the
    instance is inside another library call on the same thread (a paint
    asked for during a callback is deferred);
  - a plug-in destroyed while its editor is still open (a host bug) destroys
    the library's editor first, or abandons it unused if that is not safe
    from the current thread. The processor's destructor and every editor
    callback share a lock, so a host destroying the plug-in on another thread
    waits for a callback in progress;
  - an instance destroyed from inside one of its own library calls is now
    leaked rather than freed under the code still running on that stack;
  - a host may destroy the processor from inside a notification we send it
    (or on another thread just after an editor callback). The delivery lock
    and an "alive" flag live in a small shared object that outlives the
    processor: delivery re-checks the flag after every host call and stops
    touching the processor once it is cleared, and the destructor clears it
    and then waits on the lock;
  - notifications caused by `paint()` go out from the message loop, never
    inside JUCE's paint of the window, and the wrapper never calls the host
    while it holds its editor lock, except that a library resizing its
    window inside a callback reaches the host from there (see Limits).

  An adversarial review of this code (November 2026) found the
  destroyed-during-delivery and cross-thread cases above, notifications
  inside paint, a gesture begun inside `destroy()` left open, the JPEG
  multi-scan cost, an unbounded total translation and a dropped menu answer
  during a nested callback; all are fixed and the scenario test covers the
  main ones.

  A second review (November 2026) of scaling, `open_url` and `set_look`
  found: a use of the freed

  window when the host closes it during the several steps of a scaled resize
  (every step now checks); the click flag still set while the host was
  notified after the callback (now set around the library call only); a
  `resized` notification lost when refused; scale limits lost on `set_size`;
  unclamped remembered scales; and a per-editor URL rate limit (now
  process-wide). All are fixed; the scenario test covers the closed-window
  resize, the click-only rule and the validator. Still open: the set_size
  case below (the host may be called under the editor lock when the library
  resizes its window inside a callback), which predates these functions.
- **Containment.** Every editor function is `noexcept` and catches
  everything; FP exceptions are masked around every library callback,
  drawing call and image decode. The Pascal trampolines catch every
  exception, and a control whose `Paint` raises is skipped for that frame.
- **Pascal side.** Free Pascal compiles `not (X > Y)` as `X <= Y`, which is
  false for NaN, so the units test with `IsNan` explicitly. Bound controls
  read and write parameters only through the editor API, never DSP state.
- **Designed layouts** (`JuceLayout.pas`). A form file embedded with `{$R}`
  is part of the plug-in's own signed/hashed library, so it is trusted input
  (an attacker who can change it can change the code). The loader is
  bounded anyway, so a corrupt or hand-edited form cannot crash the host:
  its own reader of the component-stream format checks every length field
  against the remaining data and fixed limits (16 MB binary, 32 MB text,
  4096 objects, depth 32, 512 properties per object, 64 KB strings, 8 MB
  per embedded image, 10^6 values) before allocating; text forms are
  pre-scanned token by token (as the RTL parser reads them, newlines
  ignored) for nesting depth and unterminated strings before the RTL's
  recursive `ObjectTextToBinary` sees them; classes come only from a fixed
  registry of `TJuceControl` descendants (no `FindClass`/`GetClass`, so no
  arbitrary class can be instantiated); properties are set through RTTI
  with range checks, `Name` only from the object header; events bind only
  to published methods declared in the plug-in's own editor class (not the
  framework's base classes). Their signature cannot be checked (FPC has no
  RTTI for it), which is acceptable because the form is the plug-in's own.
  Lenient-mode warnings are capped (100). Failure raises `EJuceLayoutError`
  and adds nothing: embedded images are all decoded (through the wrapper's
  checked decoder) before any is added. Tested with every truncation and
  3000 random mutations of a real form (`test_layout_unit`). An adversarial
  review of the loader (Nov 2026) found a one-line nesting bypass of the
  text pre-scan, unbounded warnings, a non-atomic image commit, events
  bindable to base-class methods, `Name` settable as a property, and a
  speculative double load in the value-type-21 path; all are fixed and
  covered by tests.
- **Build-time tools.** `pascaljuce_params` (the `PARAMETER_LIST` option)
  loads the freshly built plug-in library into a build-time process to read
  its parameter declarations, i.e. it runs the library's initialisation
  code on the build machine, as the hosting tests already do. The design
  packages run inside the IDE and read only the form, the `.params` file
  and Pascal sources next to it.

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
build\x64-clang-asan\fuzz_editor_artefacts\Release\fuzz_editor.exe fuzz <iterations> <seed>
```

What the suites cover:

| Suite | Checks |
|---|---|
| `c_api_test` | every C function, including NULL handles, out-of-range indices, the buffer-size protocol, thread misuse, MIDI validation and file-writer bounds |
| `test_app_units`, `test_plugin_unit` | the Pascal units, compiled with range/overflow/object checks and `heaptrc` (any leak fails the test), including concurrent heap use from JUCE threads and ABI struct-size handling |
| `fuzz_midi`, `fuzz_audio_files`, `fuzz_plugin_state` | deterministic mutation fuzzing of the three attacker-controlled inputs (run longer by hand) |
| `plugin_host_*` | the built VST3/LV2 bundles under JUCE's own hosting, including hostile state, a missing library and a tampered library |
| `fuzz_editor_scenario` | the editor API from a C++ test library: calls from other threads, stale and forged handles, drawing outside paint, image limits (oversized, truncated, bad CRC, GIF), parameter-text truncation, menus (one at a time, answer after close dropped), the host closing the window inside a callback (also inside a scaled resize), a gesture left open, the processor destroyed under an open editor, the URL validator (60+ hostile URLs) and `open_url` only during clicks, scaling (limits, drawing, mouse mapping, remembered and hostile saved scales, letterboxing), `set_look` (hostile looks, a menu outliving its editor), 1000 editors |
| `fuzz_editor` | random host actions (open/close, paint, mouse, wheel, resize, automation from other threads, menus, audio) while the library makes random API calls with hostile arguments in every callback, including `set_design_size`, `open_url` (every URL actually opened must pass the validator) and `set_look` |
| `editor_test`, `test_ui_unit` | the Pascal controls: rendering against reference images, mouse, gestures, automation, menus, lifetime, no leaks over 1000 editors |

## Limits

- **JUCE and its bundled codecs (libFLAC, libvorbis) decode untrusted files.**
  We fuzz them through this API, but we do not own them. WAV and AIFF are
  re-framed before JUCE parses them. MP3/WMA (Windows Media) and Core Audio
  formats are not offered at all: their readers were not part of the review,
  and they decode through operating-system code. Decode those with a library
  you trust and pass the samples in a buffer.
- **Editor images are decoded by JUCE's bundled libpng and libjpeg.** The
  structure checks keep the decoders on well-formed input and bound what they
  allocate, but the decoders still parse the compressed data. For skins from
  untrusted sources, prefer PNG, or decode them elsewhere and ship only
  images you made.
- **Editor teardown and host locks.** Every library editor callback runs
  under one wrapper-wide lock, so that a host destroying a plug-in on
  another thread waits for it. If the library resizes its window inside a
  callback, the host's resize handling runs under that lock. A host that
  destroys another plug-in instance on a second thread while holding a lock
  its resize handler also takes could deadlock. If a host destroys a
  plug-in with its editor still open on another thread (against JUCE's
  rules), the library editor is abandoned and the host may see a gesture
  begin without its end.
- **The editor runs in the host's process and on its UI thread.** A library
  that loops forever in a callback freezes the host's interface; nothing
  here can stop that.
- **Integrity checking proves the library is the one built with this wrapper**,
  not that it is benign. Sign your releases (Authenticode on Windows, a
  Developer ID with notarisation on macOS); signing also covers the wrapper.
- **The macOS/AU path is not yet tested**, including bundle signing and the
  macOS and Linux `open_url` launchers (LSOpenCFURLRef, xdg-open).
- **open_url opens what the URL says.** The checks keep it to an https page,
  not to a page you trust: IDN host names (`xn--`) can look like others.
  Pass only URLs your plug-in ships, never ones from presets or projects.
- **Pascal code is the author's responsibility.** The fake-huge sample array
  types are unchecked by design (speed); use `Ctx.Channel`, `Ctx.MidiEvent`
  and `Ctx.Param`, which are bounds-checked, and always honour `NumSamples`.

## Reporting a vulnerability

Please report security problems privately to the maintainer rather than in a
public issue, with steps to reproduce (an input file or state blob is ideal).
