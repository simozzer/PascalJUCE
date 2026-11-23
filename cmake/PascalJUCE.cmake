# PascalJUCE.cmake - build JUCE plug-ins whose DSP lives in a Pascal library.
#
#   pascaljuce_add_plugin(<target>
#       PRODUCT_NAME      "My Synth"
#       COMPANY_NAME      "Me"
#       MANUFACTURER_CODE Abcd           # 4 chars, >= 1 upper-case; same for all your plug-ins
#       PLUGIN_CODE       Ms01           # 4 chars, unique per plug-in
#       BUNDLE_ID         com.me.mysynth # unique per plug-in (macOS / AU)
#       [LV2URI uri]                     # unique per plug-in; default <COMPANY_WEBSITE>/plugins/<name>
#       [KIND instrument|effect|midi_effect]      (default instrument; must match JuceRegisterPlugin)
#       [FORMATS VST3 AU LV2 Standalone]          (default: all available on this platform)
#       [VERSION 1.0.0] [COMPANY_WEBSITE url]
#       [MIDI_INPUT ON|OFF] [MIDI_OUTPUT ON|OFF]  (override KIND defaults)
#       [INTEGRITY_CHECK ON|OFF]                  (default ON, see below)
#       PASCAL_SOURCE  MyPlugin.dpr      # compile with Free Pascal, or
#       PASCAL_LIBRARY path/to/MyPlugin.dll  # use a library you built (e.g. in Delphi)
#       [PASCAL_FLAGS -dSOMETHING ...] [PASCAL_UNIT_PATHS dir ...]
#       [LICENSE_FILE path]              # your plug-in's licence, shipped as licenses/LICENSE.txt
#       [PARAMETER_LIST path])           # write the parameter list there after each build, for the
#                                        # form designer (e.g. next to your .lfm; see docs/PLUGINS.md)
#
# The Pascal library is copied next to the plug-in binary inside every bundle
# (e.g. My Synth.vst3/Contents/x86_64-win/<target>_pascal.dll) and loaded at
# run time by the wrapper in plugin/pascaljuce_plugin_processor.cpp.
#
# INTEGRITY_CHECK records the library's SHA-256 in the wrapper at build time;
# the wrapper refuses to load a library that was modified or replaced
# afterwards (e.g. a planted DLL in a user-writable plug-in folder).

set(PASCALJUCE_ROOT "${CMAKE_CURRENT_LIST_DIR}/.." CACHE INTERNAL "")

# Collects the licence texts every binary must ship with (THIRD_PARTY_NOTICES.md)
# into <out_dir>, at configure time. EXTRA is the plug-in's own licence, if given.
function(pascaljuce_stage_licences out_dir)
    cmake_parse_arguments(ARG "" "EXTRA" "" ${ARGN})
    if(NOT juce_SOURCE_DIR)
        message(FATAL_ERROR "pascaljuce_stage_licences: JUCE must be added first")
    endif()
    set(m "${juce_SOURCE_DIR}/modules")
    set(pairs
        "${PASCALJUCE_ROOT}/LICENSE"                                         PascalJUCE-LICENSE.txt
        "${PASCALJUCE_ROOT}/THIRD_PARTY_NOTICES.md"                          THIRD_PARTY_NOTICES.md
        "${PASCALJUCE_ROOT}/licenses/AGPL-3.0.txt"                           AGPL-3.0.txt
        "${juce_SOURCE_DIR}/LICENSE.md"                                      JUCE-LICENSE.md
        "${m}/juce_audio_processors_headless/format_types/VST3_SDK/LICENSE.txt" VST3_SDK-LICENSE.txt
        "${m}/juce_audio_processors_headless/format_types/LV2_SDK/lv2/COPYING" LV2-COPYING.txt
        "${m}/juce_core/zip/zlib/LICENSE"                                    zlib-LICENSE.txt
        "${m}/juce_audio_formats/codecs/flac/Flac Licence.txt"               FLAC-LICENSE.txt
        "${m}/juce_audio_formats/codecs/oggvorbis/Ogg Vorbis Licence.txt"    OggVorbis-LICENSE.txt
        "${m}/juce_graphics/image_formats/pnglib/LICENSE"                    libpng-LICENSE.txt
        "${m}/juce_graphics/image_formats/jpglib/README"                     jpeglib-README.txt
        "${m}/juce_graphics/fonts/harfbuzz/COPYING"                          HarfBuzz-COPYING.txt
        "${m}/juce_graphics/unicode/sheenbidi/LICENSE"                       SheenBidi-LICENSE.txt)
    if(APPLE)
        list(APPEND pairs "${m}/juce_audio_plugin_client/AU/AudioUnitSDK/LICENSE.txt" AudioUnitSDK-LICENSE.txt)
    endif()
    if(ARG_EXTRA)
        list(APPEND pairs "${ARG_EXTRA}" LICENSE.txt)
    endif()
    list(LENGTH pairs n)
    math(EXPR last "${n} - 1")
    foreach(i RANGE 0 ${last} 2)
        math(EXPR j "${i} + 1")
        list(GET pairs ${i} from)
        list(GET pairs ${j} to)
        if(NOT EXISTS "${from}")
            message(FATAL_ERROR "Licence file missing: ${from}")
        endif()
        configure_file("${from}" "${out_dir}/${to}" COPYONLY)
    endforeach()
endfunction()

# Position-independent executables need the linker flag as well (CMP0083).
if(NOT MSVC)
    include(CheckPIESupported)
    check_pie_supported(OUTPUT_VARIABLE _pascaljuce_pie_output LANGUAGES C CXX)

    # Stack-clash and control-flow protection, where the compiler supports them
    # for the architecture being built (Intel CET on x86_64, PAC/BTI on arm64).
    include(CheckCXXCompilerFlag)
    set(PASCALJUCE_EXTRA_HARDENING_FLAGS "")
    check_cxx_compiler_flag(-fstack-clash-protection PASCALJUCE_HAVE_STACK_CLASH)
    if(PASCALJUCE_HAVE_STACK_CLASH)
        list(APPEND PASCALJUCE_EXTRA_HARDENING_FLAGS -fstack-clash-protection)
    endif()
    if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|AMD64|amd64)$")
        check_cxx_compiler_flag(-fcf-protection=full PASCALJUCE_HAVE_CF_PROTECTION)
        if(PASCALJUCE_HAVE_CF_PROTECTION)
            list(APPEND PASCALJUCE_EXTRA_HARDENING_FLAGS -fcf-protection=full)
        endif()
    elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64|ARM64)$" AND NOT APPLE)
        # Not on Apple: plain arm64 (not arm64e) binaries cannot use return-address
        # signing there, and exceptions fail to unwind through signed frames.
        check_cxx_compiler_flag(-mbranch-protection=standard PASCALJUCE_HAVE_BRANCH_PROTECTION)
        if(PASCALJUCE_HAVE_BRANCH_PROTECTION)
            list(APPEND PASCALJUCE_EXTRA_HARDENING_FLAGS -mbranch-protection=standard)
        endif()
    endif()
endif()

# Compiler/linker hardening for a target the framework builds. Checked after
# the build by the pe_flags_* (Windows) and hardening_* (Linux, macOS) tests.
function(pascaljuce_harden target)
    if(MSVC) # MSVC and clang-cl
        target_compile_options(${target} PRIVATE /GS /guard:cf)
        target_link_options(${target} PRIVATE /guard:cf /DYNAMICBASE /NXCOMPAT)
        if(CMAKE_SIZEOF_VOID_P EQUAL 8 AND CMAKE_SYSTEM_PROCESSOR MATCHES "AMD64|x86_64")
            target_link_options(${target} PRIVATE /CETCOMPAT)
        endif()
    else()
        target_compile_options(${target} PRIVATE -fstack-protector-strong ${PASCALJUCE_EXTRA_HARDENING_FLAGS})
        # FORTIFY_SOURCE needs optimisation, and sanitizer builds replace those
        # libc checks with their own interceptors. -U first: some toolchains
        # (Ubuntu's GCC) already define it, at another level.
        if(NOT PASCALJUCE_SANITIZE)
            target_compile_options(${target} PRIVATE
                "$<$<NOT:$<CONFIG:Debug>>:-U_FORTIFY_SOURCE;-D_FORTIFY_SOURCE=2>")
        endif()
        # PIC for libraries, PIE (-fPIE and -pie) for executables such as Standalone.
        set_target_properties(${target} PROPERTIES POSITION_INDEPENDENT_CODE ON)
        if(NOT APPLE) # macOS: PIE, NX stack and bound stubs are the linker's defaults
            target_link_options(${target} PRIVATE -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack)
        endif()
    endif()
endfunction()

# Build-time tool that sets ASLR/DEP flags on Pascal libraries (see tools/pe_flags.cpp).
if(WIN32 AND NOT TARGET pascaljuce_pe_flags)
    add_executable(pascaljuce_pe_flags "${PASCALJUCE_ROOT}/tools/pe_flags.cpp")
    target_compile_features(pascaljuce_pe_flags PRIVATE cxx_std_17)
    target_compile_definitions(pascaljuce_pe_flags PRIVATE _CRT_SECURE_NO_WARNINGS)
    # Next to the other build tools (and, in sanitizer builds, the sanitizer runtime).
    set_target_properties(pascaljuce_pe_flags PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
endif()

# Build-time tool that writes a library's parameter list for the form
# designer (PARAMETER_LIST below; see tools/pascaljuce_params.cpp).
if(NOT CMAKE_CROSSCOMPILING AND NOT TARGET pascaljuce_params)
    add_executable(pascaljuce_params "${PASCALJUCE_ROOT}/tools/pascaljuce_params.cpp")
    target_compile_features(pascaljuce_params PRIVATE cxx_std_17)
    target_include_directories(pascaljuce_params PRIVATE "${PASCALJUCE_ROOT}/plugin/include")
    if(UNIX)
        target_link_libraries(pascaljuce_params PRIVATE ${CMAKE_DL_LIBS})
    endif()
    set_target_properties(pascaljuce_params PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
endif()

function(_pascaljuce_find_fpc out_var)
    if(FPC_EXECUTABLE)
        set(${out_var} "${FPC_EXECUTABLE}" PARENT_SCOPE)
        return()
    endif()
    set(hints)
    if(WIN32)
        if(CMAKE_SIZEOF_VOID_P EQUAL 8)
            file(GLOB hints "C:/lazarus*/fpc/*/bin/x86_64-win64" "C:/FPC/*/bin/x86_64-win64")
        else()
            file(GLOB hints "C:/lazarus*/fpc/*/bin/i386-win32" "C:/FPC/*/bin/i386-win32")
        endif()
    endif()
    find_program(FPC_EXECUTABLE NAMES fpc HINTS ${hints} NO_DEFAULT_PATH)
    find_program(FPC_EXECUTABLE NAMES fpc)
    set(${out_var} "${FPC_EXECUTABLE}" PARENT_SCOPE)
endfunction()

# Free Pascal flags that pick the target: on macOS one architecture per build,
# matching CMAKE_OSX_ARCHITECTURES (for universal binaries, build per
# architecture, lipo the results and pass the result as PASCAL_LIBRARY).
function(_pascaljuce_fpc_arch_flags out_var context)
    set(flags)
    if(APPLE)
        list(LENGTH CMAKE_OSX_ARCHITECTURES n_arch)
        if(n_arch GREATER 1)
            message(FATAL_ERROR "${context}: FPC builds one architecture at a time; "
                                "build per architecture and pass a lipo'd library as PASCAL_LIBRARY")
        elseif(CMAKE_OSX_ARCHITECTURES STREQUAL "arm64")
            set(flags -Paarch64)
        elseif(CMAKE_OSX_ARCHITECTURES STREQUAL "x86_64")
            set(flags -Px86_64)
        endif()
    endif()
    set(${out_var} ${flags} PARENT_SCOPE)
endfunction()

# Free Pascal's target CPU and OS ("x86_64", "linux"), as in Lazarus'
# $(TargetCPU)-$(TargetOS) output folders.
function(_pascaljuce_fpc_target fpc out_cpu out_os)
    _pascaljuce_fpc_arch_flags(arch "FPC target")
    execute_process(COMMAND "${fpc}" ${arch} -iTP OUTPUT_VARIABLE cpu OUTPUT_STRIP_TRAILING_WHITESPACE)
    execute_process(COMMAND "${fpc}" ${arch} -iTO OUTPUT_VARIABLE os OUTPUT_STRIP_TRAILING_WHITESPACE)
    set(${out_cpu} "${cpu}" PARENT_SCOPE)
    set(${out_os} "${os}" PARENT_SCOPE)
endfunction()

# macOS: the identity the Pascal library is signed with before it is hashed.
# "-" is an ad-hoc signature (enough to run on Apple Silicon, not for
# distribution). For distribution give your "Developer ID Application: ..."
# identity and PASCALJUCE_CODESIGN_FLAGS "--options=runtime;--timestamp";
# see docs/PLUGINS.md.
if(APPLE)
    set(PASCALJUCE_CODESIGN_IDENTITY "-" CACHE STRING "codesign identity for Pascal libraries (- = ad hoc)")
    set(PASCALJUCE_CODESIGN_FLAGS "" CACHE STRING "Extra codesign flags for Pascal libraries (a list)")
    find_program(PASCALJUCE_CODESIGN codesign REQUIRED)
endif()

function(pascaljuce_add_plugin target)
    set(one_value PRODUCT_NAME COMPANY_NAME COMPANY_WEBSITE MANUFACTURER_CODE PLUGIN_CODE KIND VERSION
                  BUNDLE_ID LV2URI PASCAL_SOURCE PASCAL_LIBRARY MIDI_INPUT MIDI_OUTPUT INTEGRITY_CHECK
                  LICENSE_FILE PARAMETER_LIST)
    set(multi_value FORMATS PASCAL_FLAGS PASCAL_UNIT_PATHS)
    cmake_parse_arguments(ARG "" "${one_value}" "${multi_value}" ${ARGN})

    foreach(required PRODUCT_NAME COMPANY_NAME MANUFACTURER_CODE PLUGIN_CODE)
        if(NOT ARG_${required})
            message(FATAL_ERROR "pascaljuce_add_plugin(${target}): ${required} is required")
        endif()
    endforeach()
    if(NOT ARG_PASCAL_SOURCE AND NOT ARG_PASCAL_LIBRARY)
        message(FATAL_ERROR "pascaljuce_add_plugin(${target}): give PASCAL_SOURCE or PASCAL_LIBRARY")
    endif()
    foreach(code MANUFACTURER_CODE PLUGIN_CODE)
        string(LENGTH "${ARG_${code}}" len)
        if(NOT len EQUAL 4)
            message(FATAL_ERROR "pascaljuce_add_plugin(${target}): ${code} must be exactly 4 characters")
        endif()
    endforeach()

    if(NOT ARG_KIND)
        set(ARG_KIND instrument)
    endif()
    if(NOT ARG_VERSION)
        set(ARG_VERSION 0.1.0)
    endif()
    if(NOT ARG_COMPANY_WEBSITE)
        set(ARG_COMPANY_WEBSITE "https://example.com")
    endif()
    if(NOT DEFINED ARG_INTEGRITY_CHECK)
        set(ARG_INTEGRITY_CHECK ON)
    endif()
    if(NOT ARG_FORMATS)
        set(ARG_FORMATS VST3 LV2 Standalone)
        if(APPLE)
            list(APPEND ARG_FORMATS AU)
        endif()
    endif()
    if(NOT APPLE)
        list(REMOVE_ITEM ARG_FORMATS AU AUv3)
    endif()

    # Kind -> JUCE flags
    if(ARG_KIND STREQUAL "instrument")
        set(kind_id 0)
        set(is_synth TRUE)
        set(is_midi_effect FALSE)
        set(midi_in TRUE)
        set(midi_out FALSE)
        set(vst3_categories Instrument Synth)
        set(au_type kAudioUnitType_MusicDevice)
    elseif(ARG_KIND STREQUAL "effect")
        set(kind_id 1)
        set(is_synth FALSE)
        set(is_midi_effect FALSE)
        set(midi_in FALSE)
        set(midi_out FALSE)
        set(vst3_categories Fx)
        set(au_type kAudioUnitType_Effect)
    elseif(ARG_KIND STREQUAL "midi_effect")
        set(kind_id 2)
        set(is_synth FALSE)
        set(is_midi_effect TRUE)
        set(midi_in TRUE)
        set(midi_out TRUE)
        set(vst3_categories Fx)
        set(au_type kAudioUnitType_MIDIProcessor)
    else()
        message(FATAL_ERROR "pascaljuce_add_plugin(${target}): KIND must be instrument, effect or midi_effect")
    endif()
    if(DEFINED ARG_MIDI_INPUT)
        set(midi_in ${ARG_MIDI_INPUT})
    endif()
    if(DEFINED ARG_MIDI_OUTPUT)
        set(midi_out ${ARG_MIDI_OUTPUT})
    endif()
    if(ARG_KIND STREQUAL "effect" AND midi_in)
        set(au_type kAudioUnitType_MusicEffect)
    endif()

    set(extra)
    if(ARG_BUNDLE_ID)
        list(APPEND extra BUNDLE_ID "${ARG_BUNDLE_ID}")
    endif()
    if(ARG_LV2URI)
        list(APPEND extra LV2URI "${ARG_LV2URI}")
    endif()

    juce_add_plugin(${target}
        PRODUCT_NAME "${ARG_PRODUCT_NAME}"
        COMPANY_NAME "${ARG_COMPANY_NAME}"
        COMPANY_WEBSITE "${ARG_COMPANY_WEBSITE}"
        VERSION "${ARG_VERSION}"
        PLUGIN_MANUFACTURER_CODE ${ARG_MANUFACTURER_CODE}
        PLUGIN_CODE ${ARG_PLUGIN_CODE}
        FORMATS ${ARG_FORMATS}
        IS_SYNTH ${is_synth}
        IS_MIDI_EFFECT ${is_midi_effect}
        NEEDS_MIDI_INPUT ${midi_in}
        NEEDS_MIDI_OUTPUT ${midi_out}
        EDITOR_WANTS_KEYBOARD_FOCUS FALSE
        VST3_CATEGORIES ${vst3_categories}
        AU_MAIN_TYPE ${au_type}
        COPY_PLUGIN_AFTER_BUILD FALSE
        ${extra})

    set(pascal_lib_name "${target}_pascal${CMAKE_SHARED_LIBRARY_SUFFIX}")
    set(gen_dir "${CMAKE_CURRENT_BINARY_DIR}/${target}_pascal")

    target_sources(${target} PRIVATE "${PASCALJUCE_ROOT}/plugin/pascaljuce_plugin_processor.cpp")
    target_include_directories(${target} PRIVATE "${PASCALJUCE_ROOT}/plugin/include")
    target_compile_definitions(${target}
        PUBLIC
            PASCALJUCE_PLUGIN_KIND=${kind_id}
            PASCALJUCE_PLUGIN_LIBRARY="${pascal_lib_name}"
            JUCE_WEB_BROWSER=0
            JUCE_USE_CURL=0
            JUCE_VST3_CAN_REPLACE_VST2=0)
    target_link_libraries(${target}
        PRIVATE
            juce::juce_audio_utils
            juce::juce_audio_processors
            juce::juce_cryptography
        PUBLIC
            juce::juce_recommended_config_flags
            juce::juce_recommended_warning_flags)
    pascaljuce_harden(${target})
    foreach(format IN LISTS ARG_FORMATS)
        if(TARGET ${target}_${format})
            pascaljuce_harden(${target}_${format})
        endif()
    endforeach()

    # ---- the Pascal library ----------------------------------------------
    # Pipeline: build (FPC) or copy (prebuilt) into a staging folder, set the
    # PE exploit mitigations (Windows), hash it, then copy the staged file into
    # every bundle - so what ships is exactly what was hashed.
    set(stage_dir "${gen_dir}/$<CONFIG>")
    set(pascal_lib "${stage_dir}/${pascal_lib_name}")
    set(harden_commands)
    set(harden_depends)
    if(WIN32)
        set(harden_commands COMMAND "$<TARGET_FILE:pascaljuce_pe_flags>" set "${pascal_lib}")
        set(harden_depends pascaljuce_pe_flags)
    elseif(APPLE)
        # Sign the staged file *before* it is hashed: codesign rewrites the Mach-O,
        # so signing the bundle copy afterwards would break the integrity check
        # (the library_integrity_* tests check every copy). Ad hoc by default;
        # see PASCALJUCE_CODESIGN_IDENTITY for distribution.
        set(harden_commands COMMAND "${PASCALJUCE_CODESIGN}" --force --sign "${PASCALJUCE_CODESIGN_IDENTITY}"
                                    ${PASCALJUCE_CODESIGN_FLAGS} "${pascal_lib}")
    endif()

    if(ARG_PASCAL_LIBRARY)
        cmake_path(ABSOLUTE_PATH ARG_PASCAL_LIBRARY BASE_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
                   OUTPUT_VARIABLE prebuilt)
        add_custom_command(
            OUTPUT "${pascal_lib}"
            COMMAND "${CMAKE_COMMAND}" -E make_directory "${stage_dir}"
            COMMAND "${CMAKE_COMMAND}" -E copy "${prebuilt}" "${pascal_lib}"
            ${harden_commands}
            DEPENDS "${prebuilt}" ${harden_depends}
            COMMENT "Staging prebuilt Pascal library ${prebuilt}"
            VERBATIM)
    else()
        _pascaljuce_find_fpc(fpc)
        if(NOT fpc)
            message(FATAL_ERROR "pascaljuce_add_plugin(${target}): Free Pascal (fpc) not found. "
                                "Set FPC_EXECUTABLE, or use PASCAL_LIBRARY with a prebuilt library.")
        endif()

        cmake_path(ABSOLUTE_PATH ARG_PASCAL_SOURCE BASE_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
                   OUTPUT_VARIABLE pascal_source)
        cmake_path(GET pascal_source PARENT_PATH pascal_source_dir)
        set(out_dir "${stage_dir}")
        set(unit_dir "${gen_dir}/units/$<CONFIG>")

        set(unit_flags "-Fu${PASCALJUCE_ROOT}/pascal" "-Fu${pascal_source_dir}")
        set(dep_dirs "${PASCALJUCE_ROOT}/pascal" "${pascal_source_dir}")
        foreach(path IN LISTS ARG_PASCAL_UNIT_PATHS)
            cmake_path(ABSOLUTE_PATH path BASE_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}" OUTPUT_VARIABLE abs)
            list(APPEND unit_flags "-Fu${abs}" "-Fi${abs}")
            list(APPEND dep_dirs "${abs}")
        endforeach()

        # Every Pascal source the library may use triggers a rebuild.
        set(pascal_sources)
        foreach(dir IN LISTS dep_dirs)
            file(GLOB_RECURSE found CONFIGURE_DEPENDS
                 "${dir}/*.pas" "${dir}/*.pp" "${dir}/*.inc" "${dir}/*.dpr" "${dir}/*.lpr"
                 "${dir}/*.lfm" "${dir}/*.dfm") # form files embedded with {$R}
            list(APPEND pascal_sources ${found})
        endforeach()

        _pascaljuce_fpc_arch_flags(arch_flags "pascaljuce_add_plugin(${target})")

        # Debug: full run-time checks (range, overflow, stack, object) and line info.
        set(config_flags "$<IF:$<CONFIG:Debug>,-gw;-gl;-O-;-Cr;-Co;-Ct;-CR,-O2;-Xs>")
        set(platform_flags)
        if(WIN32)
            set(platform_flags -WR) # base relocations, so ASLR can be enabled
        elseif(NOT APPLE)
            # ELF: position-independent code, full RELRO, non-executable stack
            # (checked by the hardening_* tests).
            set(platform_flags -Cg -k-z -krelro -k-z -know -k-z -knoexecstack)
        endif()

        add_custom_command(
            OUTPUT "${pascal_lib}"
            COMMAND "${CMAKE_COMMAND}" -E make_directory "${out_dir}" "${unit_dir}"
            COMMAND "${fpc}" -B -Mdelphi -FcUTF8 -vewn ${arch_flags} ${platform_flags} "${config_flags}"
                    ${unit_flags} "-FU${unit_dir}" "-FE${out_dir}" "-o${pascal_lib_name}"
                    ${ARG_PASCAL_FLAGS} "${pascal_source}"
            ${harden_commands}
            DEPENDS ${pascal_sources} ${harden_depends}
            COMMENT "Compiling Pascal plug-in library ${pascal_lib_name}"
            COMMAND_EXPAND_LISTS
            VERBATIM)
    endif()

    # One target owns the library rule (VS/Xcode generators would otherwise
    # copy the rule into every target that depends on the file).
    add_custom_target(${target}_PascalBuild DEPENDS "${pascal_lib}")
    set_target_properties(${target}_PascalBuild PROPERTIES PASCALJUCE_LIBRARY "${pascal_lib}")

    # ---- parameter list for the form designer (optional) ------------------
    # Loads the built library and writes its parameters (id, kind, name, units,
    # range, default, choices) to PARAMETER_LIST; the design-time packages read
    # it for the ParameterId drop-down and for the preview values. The file is
    # only rewritten when it changes.
    if(ARG_PARAMETER_LIST)
        if(TARGET pascaljuce_params)
            cmake_path(ABSOLUTE_PATH ARG_PARAMETER_LIST BASE_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
                       OUTPUT_VARIABLE parameter_list)
            add_custom_target(${target}_ParameterList ALL
                COMMAND "$<TARGET_FILE:pascaljuce_params>" "${pascal_lib}" "${parameter_list}"
                COMMENT "Exporting the parameter list of ${target}"
                VERBATIM)
            add_dependencies(${target}_ParameterList ${target}_PascalBuild pascaljuce_params)
        else()
            message(STATUS "pascaljuce_add_plugin(${target}): PARAMETER_LIST ignored (cross-compiling)")
        endif()
    endif()

    # ---- integrity hash compiled into the wrapper ---------------------------
    if(ARG_INTEGRITY_CHECK)
        # Re-hashed on every build (cheap; the header is only rewritten when the
        # hash changes), so a replaced prebuilt library can't leave a stale hash.
        set(hash_header "${gen_dir}/hash/$<CONFIG>/pascaljuce_library_hash.h")
        set_target_properties(${target}_PascalBuild PROPERTIES PASCALJUCE_HASH_HEADER "${hash_header}")
        add_custom_target(${target}_PascalHash
            COMMAND "${CMAKE_COMMAND}" "-DLIBRARY=${pascal_lib}" "-DOUTPUT=${hash_header}"
                    -P "${PASCALJUCE_ROOT}/cmake/PascalJUCEHash.cmake"
            BYPRODUCTS "${hash_header}"
            COMMENT "Recording SHA-256 of ${pascal_lib_name}"
            VERBATIM)
        add_dependencies(${target}_PascalHash ${target}_PascalBuild)
        add_dependencies(${target} ${target}_PascalHash)
        target_include_directories(${target} PRIVATE "${gen_dir}/hash/$<CONFIG>")
        target_compile_definitions(${target} PRIVATE PASCALJUCE_HAS_LIBRARY_HASH=1)
    else()
        message(WARNING "pascaljuce_add_plugin(${target}): INTEGRITY_CHECK is OFF - the wrapper will load "
                        "any file named ${pascal_lib_name}. Use this only for local experiments.")
    endif()

    # ---- copy it into every bundle (runs every build; copy_if_different) ---
    # Licence texts go in too (THIRD_PARTY_NOTICES.md), before any signing step.
    set(licence_stage "${CMAKE_CURRENT_BINARY_DIR}/${target}_licenses")
    if(ARG_LICENSE_FILE)
        cmake_path(ABSOLUTE_PATH ARG_LICENSE_FILE BASE_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
                   OUTPUT_VARIABLE licence_extra)
        pascaljuce_stage_licences("${licence_stage}" EXTRA "${licence_extra}")
    else()
        pascaljuce_stage_licences("${licence_stage}")
    endif()
    set(copy_commands)
    foreach(format IN LISTS ARG_FORMATS)
        set(wrapper "${target}_${format}")
        if(NOT TARGET ${wrapper})
            continue()
        endif()

        if(format STREQUAL "Standalone")
            get_target_property(dest ${wrapper} RUNTIME_OUTPUT_DIRECTORY)
            if(APPLE)
                set(dest "${dest}/${ARG_PRODUCT_NAME}.app/Contents/MacOS")
            endif()
        else()
            get_target_property(dest ${wrapper} LIBRARY_OUTPUT_DIRECTORY)
            if(APPLE AND format STREQUAL "VST3")
                set(dest "${dest}/${ARG_PRODUCT_NAME}.vst3/Contents/MacOS")
            elseif(APPLE AND format STREQUAL "AU")
                set(dest "${dest}/${ARG_PRODUCT_NAME}.component/Contents/MacOS")
            endif()
        endif()

        if(format STREQUAL "LV2")
            set(licence_dest "${dest}/licenses")
        elseif(format STREQUAL "Standalone" AND NOT APPLE)
            set(licence_dest "${dest}/licenses")
        else() # inside a bundle: Contents/<arch> or Contents/MacOS -> Contents/Resources
            set(licence_dest "${dest}/../Resources/licenses")
        endif()
        list(APPEND copy_commands
             COMMAND "${CMAKE_COMMAND}" -E make_directory "${dest}"
             COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${pascal_lib}" "${dest}/${pascal_lib_name}")
        list(APPEND copy_commands
             COMMAND "${CMAKE_COMMAND}" -E copy_directory "${licence_stage}" "${licence_dest}")
    endforeach()

    add_custom_target(${target}_PascalLibrary ALL
        ${copy_commands}
        COMMENT "Placing ${pascal_lib_name} into the ${target} bundles"
        VERBATIM)
    add_dependencies(${target}_PascalLibrary ${target}_PascalBuild)

    foreach(format IN LISTS ARG_FORMATS)
        if(TARGET ${target}_${format})
            add_dependencies(${target}_${format} ${target}_PascalLibrary)
        endif()
    endforeach()

    # LV2 manifests list the parameters, which live in the Pascal library:
    # regenerate them on every build, not only when the wrapper relinks.
    if(TARGET ${target}_LV2 AND TARGET juce_lv2_helper)
        add_custom_target(${target}_LV2_Manifest ALL
            COMMAND juce_lv2_helper "$<TARGET_FILE:${target}_LV2>"
            COMMENT "Refreshing LV2 manifest for ${target}"
            VERBATIM)
        add_dependencies(${target}_LV2_Manifest ${target}_LV2)
    endif()

    # macOS: sign every product with the same identity as the Pascal library.
    # Bundles are signed as a whole but not with --deep, which would re-sign
    # (and so change) the Pascal library inside after it was hashed. Runs after
    # JUCE's own post-build steps (moduleinfo.json), which were added first.
    if(APPLE)
        foreach(format IN LISTS ARG_FORMATS)
            set(wrapper "${target}_${format}")
            if(NOT TARGET ${wrapper})
                continue()
            endif()
            if(format STREQUAL "LV2")
                set(signed "$<TARGET_FILE:${wrapper}>")
            else()
                set(signed "$<TARGET_BUNDLE_DIR:${wrapper}>")
            endif()
            add_custom_command(TARGET ${wrapper} POST_BUILD
                COMMAND "${PASCALJUCE_CODESIGN}" --force --sign "${PASCALJUCE_CODESIGN_IDENTITY}"
                        ${PASCALJUCE_CODESIGN_FLAGS} "${signed}"
                COMMENT "Signing ${wrapper}"
                VERBATIM)
        endforeach()
    endif()
endfunction()

# Adds every sub-directory of <dir> that contains a CMakeLists.txt.
function(pascaljuce_add_plugin_directories dir)
    file(GLOB children LIST_DIRECTORIES TRUE "${dir}/*")
    foreach(child IN LISTS children)
        if(IS_DIRECTORY "${child}" AND EXISTS "${child}/CMakeLists.txt")
            add_subdirectory("${child}")
        endif()
    endforeach()
endfunction()
