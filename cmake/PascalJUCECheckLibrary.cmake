# cmake -DHEADER=<pascaljuce_library_hash.h> -DSTAGED=<staged library> -DBUNDLES=<artefacts dir>
#       [-DCODESIGN=<codesign>] -P PascalJUCECheckLibrary.cmake
#
# The integrity check end to end, after a build: the SHA-256 compiled into
# the wrapper (HEADER) must be that of the staged Pascal library and of every
# copy of it in the bundles under BUNDLES. On macOS (CODESIGN given) every
# copy must also carry a valid signature: the library is signed before it is
# hashed, so signing must not have changed it afterwards, and the bundle
# signing step must not have re-signed it.
cmake_minimum_required(VERSION 3.22)

foreach(v HEADER STAGED BUNDLES)
    if(NOT ${v})
        message(FATAL_ERROR "library check: ${v} not given")
    endif()
endforeach()
if(NOT EXISTS "${HEADER}")
    message(FATAL_ERROR "library check: ${HEADER} missing (INTEGRITY_CHECK off?)")
endif()

file(READ "${HEADER}" header)
string(REGEX MATCH "PASCALJUCE_PLUGIN_SHA256 \"([0-9a-fA-F]+)\"" _ "${header}")
set(expected "${CMAKE_MATCH_1}")
string(LENGTH "${expected}" len)
if(NOT len EQUAL 64)
    message(FATAL_ERROR "library check: no SHA-256 in ${HEADER}")
endif()

get_filename_component(name "${STAGED}" NAME)
file(GLOB_RECURSE everything LIST_DIRECTORIES FALSE "${BUNDLES}/*")
set(copies)
foreach(f IN LISTS everything)
    get_filename_component(n "${f}" NAME)
    if(n STREQUAL name)
        list(APPEND copies "${f}")
    endif()
endforeach()
set(files "${STAGED}" ${copies})
list(LENGTH copies n_copies)
if(n_copies EQUAL 0)
    message(FATAL_ERROR "library check: no copy of ${name} under ${BUNDLES}")
endif()

set(failed 0)
foreach(f IN LISTS files)
    file(SHA256 "${f}" actual)
    if(actual STREQUAL expected)
        message(STATUS "ok    hash    ${f}")
    else()
        message(STATUS "FAIL  hash    ${f}: ${actual}, the wrapper expects ${expected}")
        math(EXPR failed "${failed} + 1")
    endif()
    if(CODESIGN)
        execute_process(COMMAND "${CODESIGN}" --verify --strict --verbose=2 "${f}"
                        RESULT_VARIABLE rc OUTPUT_VARIABLE out ERROR_VARIABLE err)
        if(rc EQUAL 0)
            message(STATUS "ok    signed  ${f}")
        else()
            message(STATUS "FAIL  signed  ${f}: ${err}")
            math(EXPR failed "${failed} + 1")
        endif()
    endif()
endforeach()

if(failed GREATER 0)
    message(FATAL_ERROR "library check: ${failed} problem(s)")
endif()
message(STATUS "library check: ${n_copies} bundle cop(ies) of ${name} match the recorded hash")
