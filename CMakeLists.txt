cmake_minimum_required(VERSION 3.22)

# Static MSVC runtime: the DLL is self-contained (no VC++ redistributable),
# which is what Pascal hosts expect. Must be set before any target exists.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

project(juce_c_audio VERSION 0.4.0 LANGUAGES C CXX)

# AddressSanitizer build for the test suites: -DPASCALJUCE_SANITIZE=address
set(PASCALJUCE_SANITIZE "" CACHE STRING "Sanitizer for test builds (empty or 'address')")
if(PASCALJUCE_SANITIZE STREQUAL "address")
    if(MSVC)
        add_compile_options(/fsanitize=address /Zi)
        add_link_options(/INCREMENTAL:NO /DEBUG)
        # clang-cl's ASan runtime lives next to the compiler; tests need its DLL on PATH.
        get_filename_component(_llvm_bin "${CMAKE_CXX_COMPILER}" DIRECTORY)
        file(GLOB _asan_dirs "${_llvm_bin}/../lib/clang/*/lib/windows" "${_llvm_bin}/../lib")
        foreach(_dir IN LISTS _asan_dirs)
            if(EXISTS "${_dir}/clang_rt.asan_dynamic-x86_64.lib")
                get_filename_component(PASCALJUCE_ASAN_DIR "${_dir}" ABSOLUTE)
            endif()
        endforeach()
        if(NOT PASCALJUCE_ASAN_DIR)
            message(FATAL_ERROR "AddressSanitizer runtime not found next to ${CMAKE_CXX_COMPILER}")
        endif()
        link_directories("${PASCALJUCE_ASAN_DIR}")
        add_link_options(clang_rt.asan_dynamic-x86_64.lib /WHOLEARCHIVE:clang_rt.asan_static_runtime_thunk-x86_64.lib)
        message(STATUS "AddressSanitizer runtime: ${PASCALJUCE_ASAN_DIR}")
    else()
        add_compile_options(-fsanitize=address -fno-omit-frame-pointer -g)
        add_link_options(-fsanitize=address)
    endif()
endif()

include(FetchContent)

set(JUCE_BUILD_EXTRAS OFF CACHE BOOL "" FORCE)
set(JUCE_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)

# Use a local checkout in external/JUCE if present; otherwise download it.
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/external/JUCE/CMakeLists.txt" AND NOT FETCHCONTENT_SOURCE_DIR_JUCE)
    set(FETCHCONTENT_SOURCE_DIR_JUCE "${CMAKE_CURRENT_SOURCE_DIR}/external/JUCE")
endif()

# Pinned to the exact commit of JUCE 8.0.17-security (tags can be moved; commits can't).
FetchContent_Declare(
    JUCE
    GIT_REPOSITORY https://github.com/juce-framework/JUCE.git
    GIT_TAG dabd5ad13cd869cba41046947fffc8e5ce5cd662 # 8.0.17-security
)
FetchContent_MakeAvailable(JUCE)

# Optional hardening patch for JUCE itself (see SECURITY.md).
# When the file exists it is applied once, idempotently, to the local or
# downloaded checkout, and the build stops if it is not fully applied.
set(PASCALJUCE_JUCE_PATCH "${CMAKE_CURRENT_SOURCE_DIR}/patches/juce-8.0.17-pascaljuce-security.patch"
    CACHE FILEPATH "Patch applied to the JUCE checkout, if it exists")
set(PASCALJUCE_JUCE_PATCHED OFF)
if(EXISTS "${PASCALJUCE_JUCE_PATCH}")
    find_package(Git REQUIRED)
    # GIT_CEILING_DIRECTORIES: a JUCE tree without its own .git inside some other
    # repository would otherwise make git resolve paths against that repository,
    # skip every hunk and still report success.
    get_filename_component(_juce_parent "${juce_SOURCE_DIR}" DIRECTORY)
    set(_juce_git "${CMAKE_COMMAND}" -E env "GIT_CEILING_DIRECTORIES=${_juce_parent}" "${GIT_EXECUTABLE}")
    execute_process(COMMAND ${_juce_git} apply --reverse --check "${PASCALJUCE_JUCE_PATCH}"
                    WORKING_DIRECTORY "${juce_SOURCE_DIR}" RESULT_VARIABLE _juce_patched OUTPUT_QUIET ERROR_QUIET)
    if(NOT _juce_patched EQUAL 0)
        execute_process(COMMAND ${_juce_git} apply "${PASCALJUCE_JUCE_PATCH}"
                        WORKING_DIRECTORY "${juce_SOURCE_DIR}" RESULT_VARIABLE _juce_apply ERROR_VARIABLE _juce_err)
        if(NOT _juce_apply EQUAL 0)
            message(FATAL_ERROR "Could not apply ${PASCALJUCE_JUCE_PATCH} to ${juce_SOURCE_DIR}:\n${_juce_err}\n"
                                "The patch needs JUCE 8.0.17-security (commit dabd5ad1).")
        endif()
        # Never build on a partly patched tree, whatever git said.
        execute_process(COMMAND ${_juce_git} apply --reverse --check "${PASCALJUCE_JUCE_PATCH}"
                        WORKING_DIRECTORY "${juce_SOURCE_DIR}" RESULT_VARIABLE _juce_patched OUTPUT_QUIET ERROR_QUIET)
        if(NOT _juce_patched EQUAL 0)
            message(FATAL_ERROR "${PASCALJUCE_JUCE_PATCH} did not apply cleanly to ${juce_SOURCE_DIR}")
        endif()
        message(STATUS "Applied JUCE patch")
    endif()
    set(PASCALJUCE_JUCE_PATCHED ON)
else()
    message(WARNING "Building with unpatched JUCE 8.0.17-security. See SECURITY.md.")
endif()

include(cmake/PascalJUCE.cmake)

# Put the DLL, import lib and test executables side by side.
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)

add_library(juce_c_audio SHARED
    src/juce_c_audio.cpp
)
add_library(juce_c_audio::juce_c_audio ALIAS juce_c_audio)

target_compile_features(juce_c_audio PUBLIC cxx_std_17)
set_target_properties(juce_c_audio PROPERTIES
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
    PREFIX ""                      # juce_c_audio.dll / juce_c_audio.so / juce_c_audio.dylib
)
target_compile_definitions(juce_c_audio
    PRIVATE
        JUCE_C_AUDIO_BUILD
        JUCE_GLOBAL_MODULE_SETTINGS_INCLUDED=1
        JUCE_STANDALONE_APPLICATION=0
        JUCE_MODAL_LOOPS_PERMITTED=1
        JUCE_WEB_BROWSER=0
        JUCE_USE_CURL=0
        JUCE_ASIO=0                # JUCE bundles the ASIO SDK (GPLv3/Steinberg licence): see THIRD_PARTY_NOTICES.md before enabling
)
target_include_directories(juce_c_audio
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
        $<INSTALL_INTERFACE:include>
)
target_link_libraries(juce_c_audio
    PRIVATE
        juce::juce_audio_devices
        juce::juce_audio_formats
        juce::juce_audio_basics
        juce::juce_events
        juce::juce_core
        juce::juce_recommended_config_flags
)

# Licence texts beside the DLL (THIRD_PARTY_NOTICES.md): ship them with it.
pascaljuce_stage_licences("${CMAKE_BINARY_DIR}/juce_c_audio_licenses")
add_custom_command(TARGET juce_c_audio POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_directory "${CMAKE_BINARY_DIR}/juce_c_audio_licenses"
            "$<TARGET_FILE_DIR:juce_c_audio>/licenses"
    VERBATIM)
pascaljuce_harden(juce_c_audio)

include(CTest)

# Plug-ins: every folder under examples/plugins/ and plugins/ with a CMakeLists.txt.
option(PASCALJUCE_BUILD_PLUGINS "Build Pascal plug-ins (examples/plugins, plugins)" ON)
if(PASCALJUCE_BUILD_PLUGINS)
    pascaljuce_add_plugin_directories("${CMAKE_CURRENT_SOURCE_DIR}/examples/plugins")
    pascaljuce_add_plugin_directories("${CMAKE_CURRENT_SOURCE_DIR}/plugins")
    if(BUILD_TESTING)
        pascaljuce_add_plugin_directories("${CMAKE_CURRENT_SOURCE_DIR}/tests/plugins")
    endif()
endif()

if(NOT BUILD_TESTING)
    return()
endif()

#-------------------------------------------------------------------------------
# C API suite
add_executable(c_api_test tests/c_api_test.c)
target_compile_features(c_api_test PRIVATE c_std_11)
target_compile_definitions(c_api_test PRIVATE _CRT_SECURE_NO_WARNINGS
    PASCALJUCE_TEST_DATA="${CMAKE_CURRENT_SOURCE_DIR}/tests/data")
# Local-only tests (tests/private) run only on a patched tree.
if(PASCALJUCE_JUCE_PATCHED AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/tests/private/c_api.inc")
    target_compile_definitions(c_api_test PRIVATE PASCALJUCE_PRIVATE_TESTS=1
        PASCALJUCE_PRIVATE_DATA="${CMAKE_CURRENT_SOURCE_DIR}/tests/private/data")
endif()
target_link_libraries(c_api_test PRIVATE juce_c_audio::juce_c_audio)
add_test(NAME c_api_test COMMAND c_api_test)
# Tests that drive the shared loopback MIDI device must not run at the same time.
set_tests_properties(c_api_test PROPERTIES RESOURCE_LOCK midi_loopback)

#-------------------------------------------------------------------------------
# Pascal suites, compiled with run-time checks and heaptrc (a leak fails the test).
_pascaljuce_find_fpc(_fpc)
if(_fpc)
    message(STATUS "Pascal tests will use ${_fpc}")
    set(_pascal_check_flags -B -Mdelphi -FcUTF8 -Cr -Co -Ct -CR -gl -gh -vewn)
    foreach(suite test_app_units test_plugin_unit)
        set(_units "${CMAKE_BINARY_DIR}/pascal-units/${suite}")
        file(MAKE_DIRECTORY ${_units})
        add_test(NAME ${suite}_build
            COMMAND ${_fpc} ${_pascal_check_flags}
                    -Fu${CMAKE_CURRENT_SOURCE_DIR}/pascal -Fu${CMAKE_CURRENT_SOURCE_DIR}/tests/pascal
                    -FU${_units} -FE$<TARGET_FILE_DIR:juce_c_audio>
                    ${CMAKE_CURRENT_SOURCE_DIR}/tests/pascal/${suite}.dpr)
        set_tests_properties(${suite}_build PROPERTIES FIXTURES_SETUP ${suite}_binary)
        add_test(NAME ${suite}
            COMMAND $<TARGET_FILE_DIR:juce_c_audio>/${suite}${CMAKE_EXECUTABLE_SUFFIX})
        set_tests_properties(${suite} PROPERTIES
            FIXTURES_REQUIRED ${suite}_binary
            RESOURCE_LOCK midi_loopback
            FAIL_REGULAR_EXPRESSION "[1-9][0-9]* unfreed memory blocks")
    endforeach()
else()
    message(STATUS "fpc not found - Pascal tests disabled (set FPC_EXECUTABLE)")
endif()

#-------------------------------------------------------------------------------
# Fuzzing (attacker-controlled inputs). The built-in driver runs a fixed,
# reproducible budget in ctest; run longer by hand, e.g. `fuzz_c_api file <iterations> <seed>`.
# Most useful in the AddressSanitizer build (-DPASCALJUCE_SANITIZE=address).
add_executable(fuzz_c_api tests/fuzz/fuzz_c_api.cpp)
target_compile_features(fuzz_c_api PRIVATE cxx_std_17)
target_compile_definitions(fuzz_c_api PRIVATE _CRT_SECURE_NO_WARNINGS)
target_link_libraries(fuzz_c_api PRIVATE juce_c_audio::juce_c_audio)
add_test(NAME fuzz_midi COMMAND fuzz_c_api midi 20000 1)
add_test(NAME fuzz_audio_files COMMAND fuzz_c_api file 1500 2)

if(TARGET ProbeEffect)
    # The real wrapper source, configured as the ProbeEffect plug-in, in a console app.
    juce_add_console_app(fuzz_plugin_state PRODUCT_NAME "fuzz_plugin_state")
    target_sources(fuzz_plugin_state PRIVATE
        tests/fuzz/fuzz_plugin_state.cpp
        plugin/pascaljuce_plugin_processor.cpp)
    target_include_directories(fuzz_plugin_state PRIVATE
        plugin/include
        "${CMAKE_BINARY_DIR}/tests/plugins/ProbeEffect/ProbeEffect_pascal/hash/$<CONFIG>")
    target_compile_definitions(fuzz_plugin_state PRIVATE
        JucePlugin_Name="Probe Effect" JucePlugin_WantsMidiInput=1 JucePlugin_ProducesMidiOutput=1
        JucePlugin_IsMidiEffect=0 PASCALJUCE_PLUGIN_KIND=1
        PASCALJUCE_PLUGIN_LIBRARY="ProbeEffect_pascal${CMAKE_SHARED_LIBRARY_SUFFIX}"
        PASCALJUCE_HAS_LIBRARY_HASH=1 JUCE_WEB_BROWSER=0 JUCE_USE_CURL=0)
    target_link_libraries(fuzz_plugin_state PRIVATE
        juce::juce_audio_utils juce::juce_audio_processors juce::juce_cryptography
        juce::juce_recommended_config_flags)
    add_dependencies(fuzz_plugin_state ProbeEffect_PascalLibrary ProbeEffect_PascalHash)
    # The wrapper loads its Pascal library from next to its own binary - here, the fuzzer.
    add_custom_command(TARGET fuzz_plugin_state POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different
                "${CMAKE_BINARY_DIR}/tests/plugins/ProbeEffect/ProbeEffect_pascal/$<CONFIG>/ProbeEffect_pascal${CMAKE_SHARED_LIBRARY_SUFFIX}"
                "$<TARGET_FILE_DIR:fuzz_plugin_state>"
        VERBATIM)
    add_test(NAME fuzz_plugin_state COMMAND fuzz_plugin_state 2000 3)
endif()

#-------------------------------------------------------------------------------
# Plug-in hosting tests: load the built bundles through JUCE's VST3/LV2 hosts.
if(TARGET PascalSynth AND TARGET ProbeEffect)
    juce_add_console_app(plugin_host_test PRODUCT_NAME "plugin_host_test")
    target_sources(plugin_host_test PRIVATE tests/plugin_host_test.cpp)
    if(PASCALJUCE_JUCE_PATCHED AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/tests/private/host_1.inc")
        target_compile_definitions(plugin_host_test PRIVATE PASCALJUCE_PRIVATE_TESTS=1)
    endif()
    target_compile_definitions(plugin_host_test PRIVATE
        JUCE_PLUGINHOST_VST3=1 JUCE_PLUGINHOST_LV2=1 JUCE_PLUGINHOST_AU=1 JUCE_MODAL_LOOPS_PERMITTED=1
        JUCE_WEB_BROWSER=0 JUCE_USE_CURL=0)
    target_link_libraries(plugin_host_test PRIVATE
        juce::juce_audio_processors juce::juce_recommended_config_flags)

    set(_synth "${CMAKE_BINARY_DIR}/examples/plugins/PascalSynth/PascalSynth_artefacts/$<CONFIG>")
    set(_probe "${CMAKE_BINARY_DIR}/tests/plugins/ProbeEffect/ProbeEffect_artefacts/$<CONFIG>")
    add_dependencies(plugin_host_test PascalSynth_VST3 ProbeEffect_VST3)
    add_test(NAME plugin_host_synth_vst3 COMMAND plugin_host_test synth VST3 "${_synth}/VST3/Pascal Synth.vst3")
    add_test(NAME plugin_host_probe_vst3 COMMAND plugin_host_test probe VST3 "${_probe}/VST3/Probe Effect.vst3")
    add_test(NAME plugin_host_missing_library COMMAND plugin_host_test missing VST3 "${_probe}/VST3/Probe Effect.vst3")
    add_test(NAME plugin_host_tampered_library COMMAND plugin_host_test tampered VST3 "${_probe}/VST3/Probe Effect.vst3")
    if(TARGET PascalSynth_LV2_Manifest AND TARGET ProbeEffect_LV2_Manifest)
        add_dependencies(plugin_host_test PascalSynth_LV2_Manifest ProbeEffect_LV2_Manifest)
        add_test(NAME plugin_host_synth_lv2 COMMAND plugin_host_test synth LV2 "${_synth}/LV2/Pascal Synth.lv2")
        add_test(NAME plugin_host_probe_lv2 COMMAND plugin_host_test probe LV2 "${_probe}/LV2/Probe Effect.lv2")
    endif()
endif()

# ASan build: tests need the sanitizer runtime DLL on PATH.
if(PASCALJUCE_ASAN_DIR)
    get_property(_tests DIRECTORY PROPERTY TESTS)
    file(TO_NATIVE_PATH "${PASCALJUCE_ASAN_DIR}" _asan_native)
    foreach(_t IN LISTS _tests)
        set_property(TEST ${_t} APPEND PROPERTY ENVIRONMENT_MODIFICATION "PATH=path_list_prepend:${_asan_native}")
    endforeach()
endif()

# ASan build: put clang's sanitizer runtime next to every executable that
# runs during or after the build (JUCE's VST3/LV2 helpers load the plug-ins
# at build time). Placing it beside the .exe also beats a same-named MSVC
# ASan runtime that may be on PATH.
if(PASCALJUCE_ASAN_DIR)
    set(_configs ${CMAKE_CONFIGURATION_TYPES})
    if(NOT _configs)
        set(_configs ${CMAKE_BUILD_TYPE})
    endif()
    foreach(_cfg IN LISTS _configs)
        foreach(_dir "bin/${_cfg}" "plugin_host_test_artefacts/${_cfg}" "fuzz_plugin_state_artefacts/${_cfg}"
                     "examples/plugins/PascalSynth/PascalSynth_artefacts/${_cfg}/Standalone")
            file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/${_dir}")
            file(COPY "${PASCALJUCE_ASAN_DIR}/clang_rt.asan_dynamic-x86_64.dll" DESTINATION "${CMAKE_BINARY_DIR}/${_dir}")
        endforeach()
    endforeach()
endif()

# Regression corpus: every input that ever crashed or hung a file reader.
if(BUILD_TESTING AND TARGET fuzz_c_api)
    file(GLOB _corpus "${CMAKE_CURRENT_SOURCE_DIR}/tests/data/fuzz_file/*.bin"
                      "${CMAKE_CURRENT_SOURCE_DIR}/tests/private/fuzz_file/*.bin")
    foreach(_input IN LISTS _corpus)
        get_filename_component(_name "${_input}" NAME_WE)
        add_test(NAME corpus_${_name} COMMAND fuzz_c_api replay "${_input}")
        set_tests_properties(corpus_${_name} PROPERTIES TIMEOUT 30)
    endforeach()
endif()

# The shipped binaries must carry ASLR/DEP (Pascal libraries get them from tools/pe_flags).
if(BUILD_TESTING AND TARGET pascaljuce_pe_flags)
    add_test(NAME pe_flags_juce_c_audio COMMAND pascaljuce_pe_flags check "$<TARGET_FILE:juce_c_audio>")
    foreach(_plugin PascalSynth ProbeEffect)
        if(TARGET ${_plugin}_PascalBuild)
            get_target_property(_dir ${_plugin} SOURCE_DIR)
            file(RELATIVE_PATH _rel "${CMAKE_CURRENT_SOURCE_DIR}" "${_dir}")
            add_test(NAME pe_flags_${_plugin}_pascal COMMAND pascaljuce_pe_flags check
                "${CMAKE_BINARY_DIR}/${_rel}/${_plugin}_pascal/$<CONFIG>/${_plugin}_pascal${CMAKE_SHARED_LIBRARY_SUFFIX}")
        endif()
    endforeach()
endif()
