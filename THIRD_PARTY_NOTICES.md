# Third-party software and licences

PascalJUCE's own code is under the MIT licence (see `LICENSE`). Everything it
builds also contains JUCE and code that JUCE bundles. Those keep their own
licences, listed below.

The build copies every licence text listed here into a `licenses` folder next
to each binary it produces:
- `<Name>.vst3/Contents/Resources/licenses`
- `<Name>.lv2/licenses`
- `licenses` beside the Standalone app and beside `juce_c_audio`

Ship that folder with your binaries.

## JUCE 8.0.17-security

JUCE's modules are dual-licensed: under the **GNU AGPLv3**
(`AGPL-3.0.txt`), or under the commercial **JUCE 8 licence**
(https://juce.com/legal/juce-8-licence/). See `JUCE-LICENSE.md`.

Every binary PascalJUCE builds contains JUCE. That includes `juce_c_audio`,
each plug-in wrapper and each Standalone app.

**If you use JUCE under the AGPLv3**, the whole plug-in is one work covered by
the AGPLv3: the wrapper, JUCE and your Pascal library together. When you
distribute it, you must:
- license your plug-in, including your Pascal code, under the AGPLv3 or a
  compatible licence;
- give recipients the Corresponding Source. That means your Pascal code,
  PascalJUCE including any patch you applied to JUCE, JUCE itself, and the
  build scripts. It can be a link to a public repository at the exact version
  you built;
- include `AGPL-3.0.txt` and the notices below;
- keep the notices that mark files you modified, dated, if you changed JUCE
  or its bundled code. This applies to any patch applied by
  `PASCALJUCE_JUCE_PATCH`.

**If you hold a commercial JUCE licence**, its terms replace the AGPLv3 for
JUCE, and your own code can stay closed. PascalJUCE's MIT licence allows
that. You still need the other notices below.

## VST3 SDK 3.8.0 (Steinberg)

Compiled into the VST3 wrapper. From version 3.8.0, which JUCE bundles since
8.0.11, the SDK is under the **MIT licence** only (`VST3_SDK-LICENSE.txt`).
The former choice between the GPLv3 and a proprietary Steinberg licence no
longer exists.
- No agreement with Steinberg is needed to publish a VST3, open or closed
  source. Keep the SDK's copyright notice and licence text with the binaries
  (the build copies them into `licenses`).
- The MIT licence is compatible with the AGPLv3, so it also works with JUCE
  under the AGPLv3.

VST is a registered trademark of Steinberg Media Technologies GmbH. Using the
"VST" name or the VST Compatible logo is optional. If you use either, follow
Steinberg's VST Usage Guidelines (`VST3_Usage_Guidelines.pdf` in JUCE's copy
of the SDK, `modules/juce_audio_processors_headless/format_types/VST3_SDK`).
"VST" may not be used in company or product names.

## Bundled libraries compiled into the binaries

| Component | Where it ends up | Licence | File in `licenses` |
|---|---|---|---|
| zlib 1.3.1 | every binary (juce_core) | zlib | `zlib-LICENSE.txt` |
| FLAC (libFLAC) | `juce_c_audio`, plug-ins (juce_audio_formats) | BSD 3-clause | `FLAC-LICENSE.txt` |
| Ogg Vorbis (libogg, libvorbis) | `juce_c_audio`, plug-ins (juce_audio_formats) | BSD 3-clause | `OggVorbis-LICENSE.txt` |
| libpng | plug-ins and Standalone (juce_graphics) | libpng/zlib | `libpng-LICENSE.txt` |
| Independent JPEG Group's jpeglib | plug-ins and Standalone (juce_graphics) | IJG | `jpeglib-README.txt` |
| HarfBuzz | plug-ins and Standalone (juce_graphics) | Old MIT | `HarfBuzz-COPYING.txt` |
| SheenBidi | plug-ins and Standalone (juce_graphics) | Apache 2.0 | `SheenBidi-LICENSE.txt` |
| LV2 headers | LV2 wrapper | ISC | `LV2-COPYING.txt` |
| AudioUnitSDK (macOS) | AU wrapper | Apache 2.0 | `AudioUnitSDK-LICENSE.txt` |

The Independent JPEG Group's licence asks for this statement:

> This software is based in part on the work of the Independent JPEG Group.

Not compiled into anything PascalJUCE ships, so not copied: Oboe (Android),
GLEW/Mesa/Khronos (juce_opengl), CHOC/QuickJS (juce_javascript), Box2D, AAX,
and the LV2 hosting libraries (lilv, serd, sord, sratom), which only the
`plugin_host_test` test program uses. JUCE also bundles the Steinberg ASIO
SDK (`juce_audio_devices/native/asio`, GPLv3 or Steinberg's proprietary ASIO
licence); PascalJUCE builds with `JUCE_ASIO=0`, so it is not compiled in. If
you enable ASIO, that licence applies to your binaries and you must ship its
`LICENSE.txt`.

## Tools and run-time libraries

- **Free Pascal run-time library:** LGPL with a static-linking exception.
  Compiled Pascal libraries may be distributed under any licence.
- **Delphi run-time library:** under your Embarcadero licence, which allows
  you to redistribute compiled programs.
- **Microsoft C run-time** (`ucrtbase.dll`, part of Windows 10 and later):
  not shipped.
- **Clang AddressSanitizer run-time:** used only by the `-asan` test builds.
  Never ship those.
