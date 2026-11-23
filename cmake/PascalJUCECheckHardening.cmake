# cmake -DFILE=<binary> -DKIND=native|pascal [-DFORTIFY=ON|OFF] [-DTOOL=<readelf|otool>] [-DNM=<nm>]
#       -P PascalJUCECheckHardening.cmake
#
# Checks that a built ELF (Linux) or Mach-O (macOS) binary carries the
# exploit mitigations SECURITY.md lists - the counterpart of tools/pe_flags
# on Windows. Fails (and prints what is missing) if any is absent.
#
#   ELF, every binary:   position-independent (ET_DYN), non-executable stack
#                        (PT_GNU_STACK without X), full RELRO (PT_GNU_RELRO +
#                        BIND_NOW), no text relocations
#   Mach-O, every binary: position-independent (MH_PIE for executables;
#                        dylibs and bundles always are), no
#                        MH_ALLOW_STACK_EXECUTION, a code signature
#   KIND native (C/C++): also the stack protector (__stack_chk_*) and, with
#                        FORTIFY=ON, fortified libc calls (__*_chk; ELF only - on
#                        Mach-O it is reported, not required)
#   KIND pascal (FPC):   Free Pascal has neither; see SECURITY.md
cmake_minimum_required(VERSION 3.22)

if(NOT EXISTS "${FILE}")
    message(FATAL_ERROR "hardening: ${FILE} does not exist")
endif()
if(NOT KIND)
    set(KIND native)
endif()

set(failures)
set(passes)
macro(_expect condition what)
    if(${condition})
        list(APPEND passes "${what}")
    else()
        list(APPEND failures "${what}")
    endif()
endmacro()

function(_run out_var)
    execute_process(COMMAND ${ARGN} OUTPUT_VARIABLE out ERROR_VARIABLE err RESULT_VARIABLE rc)
    if(NOT rc EQUAL 0)
        message(FATAL_ERROR "hardening: '${ARGN}' failed (${rc}): ${err}")
    endif()
    set(${out_var} "${out}" PARENT_SCOPE)
endfunction()

file(READ "${FILE}" magic LIMIT 4 HEX)

if(magic STREQUAL "7f454c46") # ELF
    if(NOT TOOL)
        find_program(TOOL readelf REQUIRED)
    endif()
    _run(header "${TOOL}" -W -h "${FILE}")
    _run(segments "${TOOL}" -W -l "${FILE}")
    _run(dynamic "${TOOL}" -W -d "${FILE}")
    _run(symbols "${TOOL}" -W --dyn-syms "${FILE}")

    string(REGEX MATCH "Type:[ \t]+DYN" is_dyn "${header}")
    _expect(is_dyn "position-independent (ELF type DYN)")

    string(REGEX MATCH "GNU_STACK[^\n]*" stack_line "${segments}")
    set(stack_nx FALSE)
    if(stack_line AND NOT stack_line MATCHES "RWE")
        set(stack_nx TRUE)
    endif()
    _expect(stack_nx "non-executable stack (PT_GNU_STACK: ${stack_line})")

    string(FIND "${segments}" "GNU_RELRO" relro_at)
    set(relro FALSE)
    if(relro_at GREATER -1)
        set(relro TRUE)
    endif()
    _expect(relro "RELRO segment (PT_GNU_RELRO)")

    set(now FALSE)
    if(dynamic MATCHES "\\(BIND_NOW\\)" OR dynamic MATCHES "\\(FLAGS\\)[^\n]*BIND_NOW" OR dynamic MATCHES "\\(FLAGS_1\\)[^\n]*NOW")
        set(now TRUE)
    endif()
    _expect(now "immediate binding (BIND_NOW: full RELRO)")

    set(no_textrel TRUE)
    if(dynamic MATCHES "\\(TEXTREL\\)" OR dynamic MATCHES "\\(FLAGS\\)[^\n]*TEXTREL")
        set(no_textrel FALSE)
    endif()
    _expect(no_textrel "no text relocations")

    # A shipped binary must not search fixed directories (such as the build
    # tree) for libraries: only $ORIGIN-relative RPATH/RUNPATH entries.
    set(rpath_ok TRUE)
    set(rpath_entries "")
    string(REGEX MATCHALL "\\((RPATH|RUNPATH)\\)[^\n]*\\[[^]\n]*\\]" rpath_lines "${dynamic}")
    foreach(line IN LISTS rpath_lines)
        string(REGEX REPLACE ".*\\[([^]\n]*)\\].*" "\\1" value "${line}")
        string(REPLACE ":" ";" entries "${value}")
        foreach(entry IN LISTS entries)
            list(APPEND rpath_entries "${entry}")
            if(NOT entry MATCHES "^\\$(ORIGIN|\\{ORIGIN\\})(/|$)")
                set(rpath_ok FALSE)
            endif()
        endforeach()
    endforeach()
    _expect(rpath_ok "no fixed RPATH/RUNPATH directories (${rpath_entries})")

    if(KIND STREQUAL "native")
        set(canary FALSE)
        if(symbols MATCHES "__stack_chk_(fail|guard)")
            set(canary TRUE)
        endif()
        _expect(canary "stack protector (__stack_chk_fail)")
        if(FORTIFY)
            set(fortify FALSE)
            if(symbols MATCHES "__[a-z0-9_]+_chk[@ \n]")
                set(fortify TRUE)
            endif()
            _expect(fortify "FORTIFY_SOURCE (__*_chk calls)")
        endif()
    endif()

elseif(magic MATCHES "^(cffaedfe|cefaedfe|cafebabe|bebafeca)$") # Mach-O, 64/32-bit or universal
    if(NOT TOOL)
        find_program(TOOL otool REQUIRED)
    endif()
    if(NOT NM)
        find_program(NM nm REQUIRED)
    endif()
    _run(header "${TOOL}" -hv "${FILE}")
    _run(commands "${TOOL}" -l "${FILE}")

    set(pic FALSE)
    if(header MATCHES "DYLIB|BUNDLE" OR header MATCHES "EXECUTE[^\n]*PIE")
        set(pic TRUE)
    endif()
    _expect(pic "position-independent (MH_PIE, or a dylib/bundle)")

    set(stack_nx TRUE)
    if(header MATCHES "ALLOW_STACK_EXECUTION")
        set(stack_nx FALSE)
    endif()
    _expect(stack_nx "non-executable stack (no MH_ALLOW_STACK_EXECUTION)")

    set(signed FALSE)
    if(commands MATCHES "LC_CODE_SIGNATURE")
        set(signed TRUE)
    endif()
    _expect(signed "code signature (LC_CODE_SIGNATURE)")

    # Only bundle-relative run-path entries (no build-tree or other fixed directories).
    set(rpath_ok TRUE)
    set(rpath_entries "")
    string(REGEX MATCHALL "cmd LC_RPATH[^\n]*\n[^\n]*\n[ \t]*path [^\n]*" rpath_cmds "${commands}")
    foreach(cmd IN LISTS rpath_cmds)
        string(REGEX REPLACE ".*path ([^\n]*) \\(offset[^\n]*" "\\1" value "${cmd}")
        list(APPEND rpath_entries "${value}")
        if(NOT value MATCHES "^@(loader_path|executable_path)(/|$)")
            set(rpath_ok FALSE)
        endif()
    endforeach()
    _expect(rpath_ok "no fixed LC_RPATH directories (${rpath_entries})")

    if(KIND STREQUAL "native")
        _run(undefined "${NM}" -u "${FILE}")
        set(canary FALSE)
        if(undefined MATCHES "___stack_chk_(fail|guard)")
            set(canary TRUE)
        endif()
        _expect(canary "stack protector (___stack_chk_fail)")
        # FORTIFY_SOURCE is passed, but with Apple's headers the checks become
        # compiler built-ins that mostly leave no ___*_chk import behind, so
        # their absence proves nothing here: reported, not required.
        if(FORTIFY)
            if(undefined MATCHES "___[a-z0-9_]+_chk\n")
                list(APPEND passes "FORTIFY_SOURCE (___*_chk calls present)")
            else()
                list(APPEND passes "FORTIFY_SOURCE: no ___*_chk imports (not checkable on Mach-O; informational)")
            endif()
        endif()
    endif()
else()
    message(FATAL_ERROR "hardening: ${FILE} is neither ELF nor Mach-O (magic ${magic})")
endif()

foreach(p IN LISTS passes)
    message(STATUS "ok    ${p}")
endforeach()
foreach(f IN LISTS failures)
    message(STATUS "FAIL  ${f}")
endforeach()
list(LENGTH failures n)
if(n GREATER 0)
    message(FATAL_ERROR "hardening: ${n} check(s) failed for ${FILE}")
endif()
message(STATUS "hardening: all checks passed for ${FILE}")
