# Mz101 - Created by Simon Moscrop
# Free software under the GNU AGPL v3; see LICENSE.
#
# mz101_host_check, on its own: not part of the PascalJUCE build. Uses the JUCE checkout
# in PascalJUCE/external/JUCE (or -DJUCE_DIR=...). See ../build_host_check.cmd.
cmake_minimum_required(VERSION 3.22)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
project(mz101_host_check VERSION 0.3.0 LANGUAGES C CXX)

set(JUCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../external/JUCE" CACHE PATH "JUCE checkout")
add_subdirectory("${JUCE_DIR}" JUCE)

juce_add_console_app(mz101_host_check PRODUCT_NAME "mz101_host_check")
target_sources(mz101_host_check PRIVATE ../host_check.cpp)
target_compile_features(mz101_host_check PRIVATE cxx_std_17)
target_compile_definitions(mz101_host_check PRIVATE
    JUCE_PLUGINHOST_VST3=1 JUCE_PLUGINHOST_LV2=1 JUCE_MODAL_LOOPS_PERMITTED=1
    JUCE_WEB_BROWSER=0 JUCE_USE_CURL=0)
target_link_libraries(mz101_host_check PRIVATE
    juce::juce_audio_processors juce::juce_recommended_config_flags)
