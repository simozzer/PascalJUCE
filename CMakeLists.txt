cmake_minimum_required(VERSION 3.22)

# Static MSVC runtime: the DLL is self-contained (no VC++ redistributable),
# which is what Pascal hosts expect. Must be set before any target exists.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

project(juce_c_audio VERSION 0.4.0 LANGUAGES C CXX)

# Sanitizer builds for the test suites: -DPASCALJUCE_SANITIZE=address (every
# platform) or =undefined (UBSan: GCC and Clang on Linux and macOS).
set(PASCALJUCE_SANITIZE "" CACHE STRING "Sanitizer for test builds (empty, 'address' or 'undefined')")
if(PASCALJUCE_SANITIZE STREQUAL "undefined")
    if(MSVC)
        message(FATAL_ERROR "PASCALJUCE_SANITIZE=undefined needs GCC or Clang (Linux, macOS)")
    endif()
    add_compile_options(-fsanitize=undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer -g)
    add_link_options(-fsanitize=undefined)
elseif(PASCALJUCE_SANITIZE STREQUAL "address")
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
        # Programs Free Pascal links (the Pascal test suites) are not instrumented
        # but load the instrumented libjuce_c_audio: the runtime has to be loaded
        # first, so those tests preload it (LD_PRELOAD / DYLD_INSERT_LIBRARIES).
        if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
            execute_process(COMMAND "${CMAKE_CXX_COMPILER}" -print-file-name=libasan.so
                            OUTPUT_VARIABLE PASCALJUCE_ASAN_RUNTIME OUTPUT_STRIP_TRAILING_WHITESPACE)
        else()
            execute_process(COMMAND "${CMAKE_CXX_COMPILER}" -print-runtime-dir
                            OUTPUT_VARIABLE _rt_dir OUTPUT_STRIP_TRAILING_WHITESPACE)
            file(GLOB PASCALJUCE_ASAN_RUNTIME "${_rt_dir}/libclang_rt.asan_osx_dynamic.dylib"
                 "${_rt_dir}/libclang_rt.asan.so" "${_rt_dir}/libclang_rt.asan-${CMAKE_SYSTEM_PROCESSOR}.so")
            list(GET PASCALJUCE_ASAN_RUNTIME 0 PASCALJUCE_ASAN_RUNTIME)
        endif()
        if(NOT EXISTS "${PASCALJUCE_ASAN_RUNTIME}")
            message(WARNING "AddressSanitizer runtime not found; the Pascal test suites will fail to start")
        else()
            message(STATUS "AddressSanitizer runtime: ${PASCALJUCE_ASAN_RUNTIME}")
        endif()
    endif()
elseif(PASCALJUCE_SANITIZE)
    message(FATAL_ERROR "PASCALJUCE_SANITIZE must be empty, 'address' or 'undefined'")
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
)
# juce_c_audio.dll on Windows; libjuce_c_audio.so / libjuce_c_audio.dylib elsewhere,
# the names Unix linkers look for (Free Pascal links it as -ljuce_c_audio).
if(WIN32)
    set_target_properties(juce_c_audio PROPERTIES PREFIX "")
endif()
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
if(APPLE) # Intel linkers do not sign by default; Apple Silicon needs at least an ad-hoc signature
    add_custom_command(TARGET juce_c_audio POST_BUILD
        COMMAND "${PASCALJUCE_CODESIGN}" --force --sign "${PASCALJUCE_CODESIGN_IDENTITY}" ${PASCALJUCE_CODESIGN_FLAGS}
                "$<TARGET_FILE:juce_c_audio>"
        VERBATIM)
endif()

include(CTest)

# Tests that cannot run on this platform or machine stay visible: ctest lists
# them as "Not Run (Disabled)", and configure prints the reason.
function(pascaljuce_skip_tests reason)
    foreach(t IN LISTS ARGN)
        add_test(NAME ${t} COMMAND "${CMAKE_COMMAND}" -E echo "skipped: ${reason}")
        set_tests_properties(${t} PROPERTIES DISABLED TRUE LABELS skipped)
    endforeach()
    list(JOIN ARGN ", " names)
    message(STATUS "Skipped tests (${reason}): ${names}")
endfunction()

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
if(UNIX AND NOT APPLE)
    target_link_libraries(c_api_test PRIVATE m) # glibc keeps sin/cos in libm
endif()
add_test(NAME c_api_test COMMAND c_api_test)
# Tests that drive the shared loopback MIDI device must not run at the same time.
set_tests_properties(c_api_test PROPERTIES RESOURCE_LOCK midi_loopback)

#-------------------------------------------------------------------------------
# Pascal suites, compiled with run-time checks and heaptrc (a leak fails the test).
_pascaljuce_find_fpc(_fpc)
if(_fpc)
    message(STATUS "Pascal tests will use ${_fpc}")
    set(_pascal_check_flags -B -Mdelphi -FcUTF8 -Cr -Co -Ct -CR -gl -gh -vewn)
    _pascaljuce_fpc_arch_flags(_fpc_arch "Pascal tests")
    list(APPEND _pascal_check_flags ${_fpc_arch})
    # Unix: link libjuce_c_audio from the build folder and find it there at run
    # time. Linux: an rpath (the executable's own folder). macOS: the tests are
    # given DYLD_LIBRARY_PATH.
    # Windows finds the DLL beside the .exe.
    set(_pascal_link_flags)
    set(_pascal_run_env)
    if(APPLE)
        set(_pascal_link_flags "-Fl$<TARGET_FILE_DIR:juce_c_audio>")
        list(APPEND _pascal_run_env "DYLD_LIBRARY_PATH=$<TARGET_FILE_DIR:juce_c_audio>")
    elseif(UNIX)
        set(_pascal_link_flags "-Fl$<TARGET_FILE_DIR:juce_c_audio>" "-k-rpath=$ORIGIN")
    endif()
    # Sanitizer builds: the uninstrumented Pascal programs load the instrumented library.
    if(PASCALJUCE_ASAN_RUNTIME AND APPLE)
        list(APPEND _pascal_run_env "DYLD_INSERT_LIBRARIES=${PASCALJUCE_ASAN_RUNTIME}")
    elseif(PASCALJUCE_ASAN_RUNTIME)
        list(APPEND _pascal_run_env "LD_PRELOAD=${PASCALJUCE_ASAN_RUNTIME}")
    endif()
    foreach(suite test_app_units test_plugin_unit test_ui_unit test_layout_unit)
        set(_units "${CMAKE_BINARY_DIR}/pascal-units/${suite}")
        file(MAKE_DIRECTORY ${_units})
        add_test(NAME ${suite}_build
            COMMAND ${_fpc} ${_pascal_check_flags} ${_pascal_link_flags}
                    -Fu${CMAKE_CURRENT_SOURCE_DIR}/pascal -Fu${CMAKE_CURRENT_SOURCE_DIR}/tests/pascal
                    -FU${_units} -FE$<TARGET_FILE_DIR:juce_c_audio>
                    ${CMAKE_CURRENT_SOURCE_DIR}/tests/pascal/${suite}.dpr)
        set_tests_properties(${suite}_build PROPERTIES FIXTURES_SETUP ${suite}_binary
            RESOURCE_LOCK pascal_test_link) # all four link through one script in the output folder (macOS: ppaslink.sh)
        add_test(NAME ${suite}
            COMMAND $<TARGET_FILE_DIR:juce_c_audio>/${suite}${CMAKE_EXECUTABLE_SUFFIX} "${CMAKE_CURRENT_SOURCE_DIR}")
        set_tests_properties(${suite} PROPERTIES
            FIXTURES_REQUIRED ${suite}_binary
            RESOURCE_LOCK midi_loopback
            FAIL_REGULAR_EXPRESSION "[1-9][0-9]* unfreed memory blocks")
        if(_pascal_run_env)
            set_tests_properties(${suite} PROPERTIES ENVIRONMENT "${_pascal_run_env}")
        endif()
    endforeach()

    # The design-time property lists are generated from the run-time controls:
    # fail if someone changed a control without re-running the generator.
    set(_gen_dir "${CMAKE_BINARY_DIR}/pascal-units/gen_design_props")
    file(MAKE_DIRECTORY ${_gen_dir})
    add_test(NAME gen_design_props_build
        COMMAND ${_fpc} -B -Mdelphi -FcUTF8 -vewn ${_fpc_arch} -Fu${CMAKE_CURRENT_SOURCE_DIR}/pascal
                -FU${_gen_dir} -FE${_gen_dir} ${CMAKE_CURRENT_SOURCE_DIR}/tools/gen_design_props.dpr)
    set_tests_properties(gen_design_props_build PROPERTIES FIXTURES_SETUP gen_design_props_binary)
    add_test(NAME design_props_current
        COMMAND ${_gen_dir}/gen_design_props${CMAKE_EXECUTABLE_SUFFIX} "${CMAKE_CURRENT_SOURCE_DIR}" --check)
    set_tests_properties(design_props_current PROPERTIES FIXTURES_REQUIRED gen_design_props_binary)

    # Lazarus: the design-time packages (built as packages only, with a private
    # config directory: nothing is installed into the IDE) and the LCL test of
    # the design-time controls (WYSIWYG against the JUCE reference rendering).
    # Windows: lazbuild from the Lazarus that holds this fpc. Linux: also on PATH
    # (Debian/Ubuntu "lazarus" package). macOS: only if LAZBUILD_EXECUTABLE is
    # given - the CI does not install Lazarus there (see docs/PLUGINS.md).
    cmake_path(GET _fpc PARENT_PATH _fpc_bin)
    find_program(LAZBUILD_EXECUTABLE lazbuild HINTS "${_fpc_bin}/../../../.." NO_DEFAULT_PATH)
    if(UNIX AND NOT APPLE)
        find_program(LAZBUILD_EXECUTABLE lazbuild)
    endif()
    set(_lazarus_tests lazarus_package_lcl lazarus_package_design lcl_design_test_build lcl_design_test)
    if(LAZBUILD_EXECUTABLE)
        message(STATUS "Lazarus tests will use ${LAZBUILD_EXECUTABLE}")
        # The Lazarus directory holds lazbuild itself (/usr/bin/lazbuild is a link into it on Debian).
        file(REAL_PATH "${LAZBUILD_EXECUTABLE}" _lazbuild_real)
        cmake_path(GET _lazbuild_real PARENT_PATH _lazarus_dir)
        set(_lazbuild "${LAZBUILD_EXECUTABLE}" "--pcp=${CMAKE_BINARY_DIR}/lazarus-config"
                      "--lazarusdir=${_lazarus_dir}" "--compiler=${_fpc}")
        _pascaljuce_fpc_target("${_fpc}" _fpc_cpu _fpc_os)
        if(_fpc_arch)
            list(APPEND _lazbuild "--cpu=${_fpc_cpu}")
        endif()
        add_test(NAME lazarus_package_lcl
            COMMAND ${_lazbuild} --build-all "${CMAKE_CURRENT_SOURCE_DIR}/packages/lazarus/pascaljuce_lcl.lpk")
        add_test(NAME lazarus_package_design
            COMMAND ${_lazbuild} --build-all "${CMAKE_CURRENT_SOURCE_DIR}/packages/lazarus/pascaljuce_design.lpk")
        add_test(NAME lcl_design_test_build
            COMMAND ${_lazbuild} --build-all "${CMAKE_CURRENT_SOURCE_DIR}/tests/lcl/test_design_lcl.lpi")
        set_tests_properties(lazarus_package_design PROPERTIES DEPENDS lazarus_package_lcl)
        set_tests_properties(lcl_design_test_build PROPERTIES DEPENDS lazarus_package_design
                             FIXTURES_SETUP lcl_design_binary)
        set_tests_properties(lazarus_package_lcl lazarus_package_design lcl_design_test_build PROPERTIES
                             RESOURCE_LOCK lazbuild TIMEOUT 900)
        # Lazarus' output folder: lib/$(TargetCPU)-$(TargetOS), e.g. x86_64-win64, aarch64-linux.
        add_test(NAME lcl_design_test
            COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/tests/lcl/lib/${_fpc_cpu}-${_fpc_os}/test_design_lcl${CMAKE_EXECUTABLE_SUFFIX}"
                    "${CMAKE_CURRENT_SOURCE_DIR}" "${CMAKE_BINARY_DIR}")
        # Linux: an LCL (GTK2) program needs an X display; run ctest under xvfb-run on a headless machine.
        set_tests_properties(lcl_design_test PROPERTIES FIXTURES_REQUIRED lcl_design_binary RESOURCE_LOCK lazbuild
                             FAIL_REGULAR_EXPRESSION "[1-9][0-9]* unfreed memory blocks")
    elseif(APPLE)
        pascaljuce_skip_tests("Lazarus is not set up on macOS here: set LAZBUILD_EXECUTABLE to run them" ${_lazarus_tests})
    else()
        pascaljuce_skip_tests("lazbuild not found (install Lazarus or set LAZBUILD_EXECUTABLE)" ${_lazarus_tests})
    endif()
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
# Custom editors. Both executables link the real wrapper source, as the
# fuzz_plugin_state target does, so the test can reach the editor component.
#
# fuzz_editor: the wrapper loads EditorProbe, a plug-in library written in C++
# against juce_c_plugin.h that calls the editor API with hostile arguments
# (scripted checks, then a random-call fuzzer).
set(_editor_wrapper_defs
    JucePlugin_WantsMidiInput=1 JucePlugin_ProducesMidiOutput=0 JucePlugin_IsMidiEffect=0
    PASCALJUCE_PLUGIN_KIND=0 PASCALJUCE_EDITOR_TEST_HOOKS=1 JUCE_MODAL_LOOPS_PERMITTED=1
    JUCE_WEB_BROWSER=0 JUCE_USE_CURL=0)
juce_add_console_app(fuzz_editor PRODUCT_NAME "fuzz_editor")
target_sources(fuzz_editor PRIVATE tests/fuzz/fuzz_editor.cpp plugin/pascaljuce_plugin_processor.cpp)
target_include_directories(fuzz_editor PRIVATE plugin/include)
target_compile_definitions(fuzz_editor PRIVATE ${_editor_wrapper_defs}
    JucePlugin_Name="Editor Probe" PASCALJUCE_PLUGIN_LIBRARY="EditorProbe_pascal${CMAKE_SHARED_LIBRARY_SUFFIX}")
target_link_libraries(fuzz_editor PRIVATE
    juce::juce_audio_utils juce::juce_audio_processors juce::juce_cryptography juce::juce_recommended_config_flags)

add_library(EditorProbe_pascal SHARED tests/plugins/EditorProbe/editor_probe.cpp)
target_compile_features(EditorProbe_pascal PRIVATE cxx_std_17)
target_include_directories(EditorProbe_pascal PRIVATE plugin/include)
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/tests/private/probe_extra.inc")
    target_compile_definitions(EditorProbe_pascal PRIVATE PASCALJUCE_PRIVATE_TESTS=1)
endif()
set_target_properties(EditorProbe_pascal PROPERTIES
    PREFIX ""
    # Next to fuzz_editor: the wrapper loads its library from beside its own binary.
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/fuzz_editor_artefacts/$<CONFIG>"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/fuzz_editor_artefacts/$<CONFIG>")
add_dependencies(fuzz_editor EditorProbe_pascal)
target_include_directories(fuzz_editor PRIVATE tests/plugins/EditorProbe)
add_test(NAME fuzz_editor_scenario COMMAND fuzz_editor scenario)
add_test(NAME fuzz_editor COMMAND fuzz_editor fuzz 3000 11)
set_tests_properties(fuzz_editor_scenario fuzz_editor PROPERTIES RESOURCE_LOCK desktop_ui TIMEOUT 600)

# editor_test: the PascalSynth template's Pascal editor, offscreen.
if(TARGET PascalSynth)
    juce_add_console_app(editor_test PRODUCT_NAME "editor_test")
    target_sources(editor_test PRIVATE tests/editor_test.cpp plugin/pascaljuce_plugin_processor.cpp)
    target_include_directories(editor_test PRIVATE plugin/include
        "${CMAKE_BINARY_DIR}/examples/plugins/PascalSynth/PascalSynth_pascal/hash/$<CONFIG>")
    target_compile_definitions(editor_test PRIVATE ${_editor_wrapper_defs}
        JucePlugin_Name="Pascal Synth" PASCALJUCE_PLUGIN_LIBRARY="PascalSynth_pascal${CMAKE_SHARED_LIBRARY_SUFFIX}"
        PASCALJUCE_HAS_LIBRARY_HASH=1 PASCALJUCE_TEST_DATA="${CMAKE_CURRENT_SOURCE_DIR}/tests/data")
    target_link_libraries(editor_test PRIVATE
        juce::juce_audio_utils juce::juce_audio_processors juce::juce_cryptography juce::juce_recommended_config_flags)
    if(WIN32)
        target_link_libraries(editor_test PRIVATE psapi)
    endif()
    add_dependencies(editor_test PascalSynth_PascalLibrary PascalSynth_PascalHash)
    add_custom_command(TARGET editor_test POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different
                "${CMAKE_BINARY_DIR}/examples/plugins/PascalSynth/PascalSynth_pascal/$<CONFIG>/PascalSynth_pascal${CMAKE_SHARED_LIBRARY_SUFFIX}"
                "$<TARGET_FILE_DIR:editor_test>"
        VERBATIM)
    add_test(NAME editor_test COMMAND editor_test WORKING_DIRECTORY "${CMAKE_BINARY_DIR}")
    set_tests_properties(editor_test PROPERTIES RESOURCE_LOCK desktop_ui TIMEOUT 600)
endif()

# mz101_editor_test: the Mz101 Pascal panel (a designed form, MIDI learn), offscreen, the
# same way. Its source and reference image live with the example (GNU AGPL v3).
if(TARGET Mz101)
    set(_mz101 "${CMAKE_CURRENT_SOURCE_DIR}/examples/plugins/Mz101")
    juce_add_console_app(mz101_editor_test PRODUCT_NAME "mz101_editor_test")
    target_sources(mz101_editor_test PRIVATE "${_mz101}/verify/editor_check.cpp" plugin/pascaljuce_plugin_processor.cpp)
    target_include_directories(mz101_editor_test PRIVATE plugin/include
        "${CMAKE_BINARY_DIR}/examples/plugins/Mz101/Mz101_pascal/hash/$<CONFIG>")
    target_compile_definitions(mz101_editor_test PRIVATE ${_editor_wrapper_defs}
        JucePlugin_Name="Mz101 Pascal" PASCALJUCE_PLUGIN_LIBRARY="Mz101_pascal${CMAKE_SHARED_LIBRARY_SUFFIX}"
        PASCALJUCE_HAS_LIBRARY_HASH=1 MZ101_VERIFY_DIR="${_mz101}/verify")
    target_link_libraries(mz101_editor_test PRIVATE
        juce::juce_audio_utils juce::juce_audio_processors juce::juce_cryptography juce::juce_recommended_config_flags)
    add_dependencies(mz101_editor_test Mz101_PascalLibrary Mz101_PascalHash)
    add_custom_command(TARGET mz101_editor_test POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different
                "${CMAKE_BINARY_DIR}/examples/plugins/Mz101/Mz101_pascal/$<CONFIG>/Mz101_pascal${CMAKE_SHARED_LIBRARY_SUFFIX}"
                "$<TARGET_FILE_DIR:mz101_editor_test>"
        VERBATIM)
    add_test(NAME mz101_editor_test COMMAND mz101_editor_test WORKING_DIRECTORY "${CMAKE_BINARY_DIR}")
    set_tests_properties(mz101_editor_test PROPERTIES RESOURCE_LOCK desktop_ui TIMEOUT 600)
endif()

# scope_test: the Scope example (an effect), its window offscreen, the same way.
if(TARGET Scope)
    juce_add_console_app(scope_test PRODUCT_NAME "scope_test")
    target_sources(scope_test PRIVATE tests/scope_test.cpp plugin/pascaljuce_plugin_processor.cpp)
    target_include_directories(scope_test PRIVATE plugin plugin/include
        "${CMAKE_BINARY_DIR}/examples/plugins/Scope/Scope_pascal/hash/$<CONFIG>")
    target_compile_definitions(scope_test PRIVATE # an effect: _editor_wrapper_defs is for instruments
        JucePlugin_WantsMidiInput=0 JucePlugin_ProducesMidiOutput=0 JucePlugin_IsMidiEffect=0
        PASCALJUCE_PLUGIN_KIND=1 PASCALJUCE_EDITOR_TEST_HOOKS=1 JUCE_MODAL_LOOPS_PERMITTED=1
        JUCE_WEB_BROWSER=0 JUCE_USE_CURL=0
        JucePlugin_Name="Scope" PASCALJUCE_PLUGIN_LIBRARY="Scope_pascal${CMAKE_SHARED_LIBRARY_SUFFIX}"
        PASCALJUCE_HAS_LIBRARY_HASH=1)
    target_link_libraries(scope_test PRIVATE
        juce::juce_audio_utils juce::juce_audio_processors juce::juce_cryptography juce::juce_recommended_config_flags)
    add_dependencies(scope_test Scope_PascalLibrary Scope_PascalHash)
    add_custom_command(TARGET scope_test POST_BUILD
        COMMAND "${CMAKE_COMMAND}" -E copy_if_different
                "${CMAKE_BINARY_DIR}/examples/plugins/Scope/Scope_pascal/$<CONFIG>/Scope_pascal${CMAKE_SHARED_LIBRARY_SUFFIX}"
                "$<TARGET_FILE_DIR:scope_test>"
        VERBATIM)
    add_test(NAME scope_test COMMAND scope_test WORKING_DIRECTORY "${CMAKE_BINARY_DIR}")
    set_tests_properties(scope_test PROPERTIES RESOURCE_LOCK desktop_ui TIMEOUT 600)
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
        juce::juce_audio_processors juce::juce_audio_utils juce::juce_recommended_config_flags) # audio_utils: CoreAudioKit for AU hosting

    set(_synth "${CMAKE_BINARY_DIR}/examples/plugins/PascalSynth/PascalSynth_artefacts/$<CONFIG>")
    set(_probe "${CMAKE_BINARY_DIR}/tests/plugins/ProbeEffect/ProbeEffect_artefacts/$<CONFIG>")
    add_dependencies(plugin_host_test PascalSynth_VST3 ProbeEffect_VST3)
    add_test(NAME plugin_host_synth_vst3 COMMAND plugin_host_test synth VST3 "${_synth}/VST3/Pascal Synth.vst3")
    add_test(NAME plugin_host_probe_vst3 COMMAND plugin_host_test probe VST3 "${_probe}/VST3/Probe Effect.vst3")
    add_test(NAME plugin_host_missing_library COMMAND plugin_host_test missing VST3 "${_probe}/VST3/Probe Effect.vst3")
    add_test(NAME plugin_host_tampered_library COMMAND plugin_host_test tampered VST3 "${_probe}/VST3/Probe Effect.vst3")
    get_target_property(_synth_lib PascalSynth_PascalBuild PASCALJUCE_LIBRARY)
    add_test(NAME plugin_host_replaced_library
             COMMAND plugin_host_test replaced VST3 "${_probe}/VST3/Probe Effect.vst3" "${_synth_lib}")
    if(TARGET PascalSynth_LV2_Manifest AND TARGET ProbeEffect_LV2_Manifest)
        add_dependencies(plugin_host_test PascalSynth_LV2_Manifest ProbeEffect_LV2_Manifest)
        add_test(NAME plugin_host_synth_lv2 COMMAND plugin_host_test synth LV2 "${_synth}/LV2/Pascal Synth.lv2")
        add_test(NAME plugin_host_probe_lv2 COMMAND plugin_host_test probe LV2 "${_probe}/LV2/Probe Effect.lv2")
    endif()
    if(TARGET Scope_VST3)
        set(_scope "${CMAKE_BINARY_DIR}/examples/plugins/Scope/Scope_artefacts/$<CONFIG>")
        add_dependencies(plugin_host_test Scope_VST3)
        add_test(NAME plugin_host_scope_vst3 COMMAND plugin_host_test scope VST3 "${_scope}/VST3/Scope.vst3")
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
                     "fuzz_editor_artefacts/${_cfg}" "editor_test_artefacts/${_cfg}" "mz101_editor_test_artefacts/${_cfg}"
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
if(BUILD_TESTING AND NOT WIN32)
    pascaljuce_skip_tests("PE (Windows) only; the hardening_* tests check ELF and Mach-O binaries"
                          pe_flags_juce_c_audio pe_flags_PascalSynth_pascal pe_flags_ProbeEffect_pascal)
endif()

# Linux and macOS: the same promise for ELF and Mach-O (cmake/PascalJUCECheckHardening.cmake):
# PIE/PIC, non-executable stack, full RELRO (ELF), a signature (Mach-O), and for
# C++ binaries the stack protector and FORTIFY_SOURCE (not in sanitizer builds).
if(BUILD_TESTING AND NOT WIN32)
    if(APPLE)
        find_program(PASCALJUCE_OTOOL otool REQUIRED)
        find_program(PASCALJUCE_NM nm REQUIRED)
        set(_inspect "-DTOOL=${PASCALJUCE_OTOOL}" "-DNM=${PASCALJUCE_NM}")
    else()
        if(CMAKE_READELF)
            set(PASCALJUCE_READELF "${CMAKE_READELF}")
        else()
            find_program(PASCALJUCE_READELF readelf REQUIRED)
        endif()
        set(_inspect "-DTOOL=${PASCALJUCE_READELF}")
    endif()
    if(PASCALJUCE_SANITIZE)
        set(_fortify OFF)
    else()
        set(_fortify "$<IF:$<CONFIG:Debug>,OFF,ON>")
    endif()
    set(_check_hardening "${CMAKE_CURRENT_SOURCE_DIR}/cmake/PascalJUCECheckHardening.cmake")
    add_test(NAME hardening_juce_c_audio
        COMMAND "${CMAKE_COMMAND}" ${_inspect} "-DFILE=$<TARGET_FILE:juce_c_audio>" -DKIND=native
                "-DFORTIFY=${_fortify}" -P "${_check_hardening}")
    foreach(_plugin PascalSynth ProbeEffect)
        if(NOT TARGET ${_plugin}_PascalBuild)
            continue()
        endif()
        foreach(_format VST3 LV2 Standalone AU)
            if(TARGET ${_plugin}_${_format})
                add_test(NAME hardening_${_plugin}_${_format}
                    COMMAND "${CMAKE_COMMAND}" ${_inspect} "-DFILE=$<TARGET_FILE:${_plugin}_${_format}>" -DKIND=native
                            "-DFORTIFY=${_fortify}" -P "${_check_hardening}")
            endif()
        endforeach()
        get_target_property(_lib ${_plugin}_PascalBuild PASCALJUCE_LIBRARY)
        add_test(NAME hardening_${_plugin}_pascal
            COMMAND "${CMAKE_COMMAND}" ${_inspect} "-DFILE=${_lib}" -DKIND=pascal -P "${_check_hardening}")
    endforeach()
endif()

# The integrity check end to end: every copy of each Pascal library in the
# bundles is the file whose SHA-256 the wrapper records (and, on macOS, is
# validly signed: signing happens before hashing, never after).
if(BUILD_TESTING)
    foreach(_plugin PascalSynth ProbeEffect)
        if(NOT TARGET ${_plugin}_PascalBuild)
            continue()
        endif()
        get_target_property(_header ${_plugin}_PascalBuild PASCALJUCE_HASH_HEADER)
        if(NOT _header)
            continue()
        endif()
        get_target_property(_lib ${_plugin}_PascalBuild PASCALJUCE_LIBRARY)
        get_target_property(_dir ${_plugin} BINARY_DIR)
        set(_codesign)
        if(APPLE)
            set(_codesign "-DCODESIGN=${PASCALJUCE_CODESIGN}")
        endif()
        add_test(NAME library_integrity_${_plugin}
            COMMAND "${CMAKE_COMMAND}" "-DHEADER=${_header}" "-DSTAGED=${_lib}"
                    "-DBUNDLES=${_dir}/${_plugin}_artefacts/$<CONFIG>" ${_codesign}
                    -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/PascalJUCECheckLibrary.cmake")
    endforeach()
endif()

# Linux AddressSanitizer builds: LeakSanitizer runs at exit. The suppressions
# (tests/sanitizer/lsan.supp) cover state the X11 client libraries keep for
# the process's lifetime; the GUI test programs link those libraries so that
# they stay loaded (JUCE would load and unload them) and can be named there.
if(BUILD_TESTING AND PASCALJUCE_SANITIZE STREQUAL "address" AND UNIX AND NOT APPLE)
    find_package(X11)
    if(X11_FOUND)
        foreach(_t plugin_host_test editor_test fuzz_editor fuzz_plugin_state)
            if(TARGET ${_t})
                target_link_options(${_t} PRIVATE "LINKER:--no-as-needed")
                target_link_libraries(${_t} PRIVATE ${X11_X11_LIB} ${X11_Xext_LIB})
            endif()
        endforeach()
    endif()
    get_property(_tests DIRECTORY PROPERTY TESTS)
    foreach(_t IN LISTS _tests)
        set_property(TEST ${_t} APPEND PROPERTY ENVIRONMENT
            "LSAN_OPTIONS=suppressions=${CMAKE_CURRENT_SOURCE_DIR}/tests/sanitizer/lsan.supp:print_suppressions=1")
    endforeach()
endif()
