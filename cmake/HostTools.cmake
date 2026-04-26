##############################################################################
# cmake/HostTools.cmake
#
# Builds minilua and buildvm using the HOST (native) compiler.
# This must happen even during cross-compilation or Emscripten builds,
# because these tools run on the build machine to generate headers.
#
# Outputs (added to LUAJIT_GENERATED_HEADERS):
#   host/buildvm_arch.h
#   lj_bcdef.h  lj_ffdef.h  lj_libdef.h  lj_recdef.h  lj_folddef.h
#   luajit.h    jit/vmdef.lua
#   lj_vm.S  (or lj_vm.obj on Windows — the assembled VM for native builds)
##############################################################################

# ── Locate a suitable host Lua or fall back to building minilua ─────────────
# We always build minilua from source. It's small and guaranteed compatible.
# (An existing Lua 5.1/5.2 + BitOp on PATH could be used, but this is simpler.)

set(MINILUA_SRC "${LUAJIT_SOURCE_DIR}/host/minilua.c")
set(MINILUA_BIN "${CMAKE_CURRENT_BINARY_DIR}/host/minilua${CMAKE_HOST_EXECUTABLE_SUFFIX}")

# Build minilua with the native C compiler via a sub-build so we get a true
# host executable even when cross-compiling.
set(_minilua_build_dir "${CMAKE_CURRENT_BINARY_DIR}/host/minilua_build")

file(MAKE_DIRECTORY "${_minilua_build_dir}")

# We write a tiny standalone CMakeLists for minilua so it uses
# CMAKE_HOST_C_COMPILER, not the cross compiler.
file(WRITE "${_minilua_build_dir}/CMakeLists.txt" [=[
cmake_minimum_required(VERSION 3.20)
project(minilua C)
add_executable(minilua "${MINILUA_SRC}")
target_link_libraries(minilua m)
set_target_properties(minilua PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${OUT_DIR}"
    RUNTIME_OUTPUT_DIRECTORY_DEBUG "${OUT_DIR}"
    RUNTIME_OUTPUT_DIRECTORY_RELEASE "${OUT_DIR}"
    RUNTIME_OUTPUT_DIRECTORY_MINSIZEREL "${OUT_DIR}"
    RUNTIME_OUTPUT_DIRECTORY_RELWITHDEBINFO "${OUT_DIR}"
)
]=])

# Configure and build minilua at CMake configure time so the binary is
# available immediately for the subsequent add_custom_command calls.
execute_process(
    COMMAND "${CMAKE_COMMAND}"
        -G "${CMAKE_GENERATOR}"
        "-DMINILUA_SRC=${MINILUA_SRC}"
        "-DOUT_DIR=${CMAKE_CURRENT_BINARY_DIR}/host"
        "${_minilua_build_dir}"
    WORKING_DIRECTORY "${_minilua_build_dir}"
    RESULT_VARIABLE _cfg_result
    OUTPUT_QUIET ERROR_QUIET
)
if(NOT _cfg_result EQUAL 0)
    message(FATAL_ERROR "minilua configure step failed (exit ${_cfg_result})")
endif()

execute_process(
    COMMAND "${CMAKE_COMMAND}" --build "${_minilua_build_dir}" --config Release
    RESULT_VARIABLE _build_result
    OUTPUT_QUIET ERROR_QUIET
)
if(NOT _build_result EQUAL 0)
    message(FATAL_ERROR "minilua build step failed (exit ${_build_result})")
endif()

if(NOT EXISTS "${MINILUA_BIN}")
    message(FATAL_ERROR "minilua binary not found at ${MINILUA_BIN}")
endif()
message(STATUS "LuaJIT: minilua built at ${MINILUA_BIN}")

# ── DynASM invocation helper ─────────────────────────────────────────────────
set(DYNASM "${LUAJIT_DYNASM_DIR}/dynasm.lua")

# Probe the TARGET architecture by running the preprocessor on lj_arch.h.
# We collect the #define output and match against known LJ_TARGET_* tokens.
# This mirrors exactly what src/Makefile does with $(TARGET_TESTARCH).
#
# When cross-compiling, CMAKE_C_COMPILER is the cross compiler, so the probe
# runs against the target headers. That is correct.

set(_arch_probe_src "${CMAKE_CURRENT_BINARY_DIR}/host/_arch_probe.c")
file(WRITE "${_arch_probe_src}" "#include \"lj_arch.h\"\n")

execute_process(
    COMMAND "${CMAKE_C_COMPILER}" -E -dM
        -I "${LUAJIT_SOURCE_DIR}"
        "${_arch_probe_src}"
    OUTPUT_VARIABLE _arch_defines
    ERROR_QUIET
    RESULT_VARIABLE _probe_result
)
if(NOT _probe_result EQUAL 0)
    # Emscripten needs extra help — retry without -dM using compile flags
    execute_process(
        COMMAND "${CMAKE_C_COMPILER}" -E
            -I "${LUAJIT_SOURCE_DIR}"
            "${_arch_probe_src}"
        OUTPUT_VARIABLE _arch_defines
        ERROR_QUIET
    )
endif()

# ── Determine DASM arch and flags from probe output ──────────────────────────
set(DASM_AFLAGS "")
set(DASM_ARCH "")

if(LUAJIT_TARGET_WASM)
    # WASM: we use the x86 .dasc file to generate the bcdef/ffdef/etc headers
    # (the VM asm itself won't be linked — lj_vm_wasm.c takes its place).
    # We must tell DynASM to generate with JIT and FFI enabled so all the
    # header enumerations are populated.
    set(DASM_ARCH "x86")
    list(APPEND DASM_AFLAGS -D P64 -D JIT -D FFI -D FPU -D HFABI -D ENDIAN_LE -D VER=0)
    set(LUAJIT_DASM_ARCH_NAME "wasm32")
else()
    # Native: detect from probe
    if(_arch_defines MATCHES "LJ_TARGET_X64 1")
        set(DASM_ARCH "x64")
        set(LUAJIT_DASM_ARCH_NAME "x64")
        if(NOT _arch_defines MATCHES "LJ_FR2 1")
            set(DASM_ARCH "x86")  # x64 without GC64 uses vm_x86.dasc
        endif()
    elseif(_arch_defines MATCHES "LJ_TARGET_X86 1")
        set(DASM_ARCH "x86")
        set(LUAJIT_DASM_ARCH_NAME "x86")
    elseif(_arch_defines MATCHES "LJ_TARGET_ARM64 1")
        set(DASM_ARCH "arm64")
        set(LUAJIT_DASM_ARCH_NAME "arm64")
        if(_arch_defines MATCHES "__AARCH64EB__")
            list(APPEND DASM_AFLAGS -D ENDIAN_BE)
        else()
            list(APPEND DASM_AFLAGS -D ENDIAN_LE)
        endif()
    elseif(_arch_defines MATCHES "LJ_TARGET_ARM 1")
        set(DASM_ARCH "arm")
        set(LUAJIT_DASM_ARCH_NAME "arm")
        list(APPEND DASM_AFLAGS -D ENDIAN_LE)
    elseif(_arch_defines MATCHES "LJ_TARGET_PPC 1")
        set(DASM_ARCH "ppc")
        set(LUAJIT_DASM_ARCH_NAME "ppc")
    elseif(_arch_defines MATCHES "LJ_TARGET_MIPS64 1")
        set(DASM_ARCH "mips64")
        set(LUAJIT_DASM_ARCH_NAME "mips64")
    elseif(_arch_defines MATCHES "LJ_TARGET_MIPS 1")
        set(DASM_ARCH "mips")
        set(LUAJIT_DASM_ARCH_NAME "mips")
    else()
        message(FATAL_ERROR
            "LuaJIT: could not detect target architecture from preprocessor output.\n"
            "If cross-compiling, make sure CMAKE_C_COMPILER is set to the cross compiler.")
    endif()

    # Common DASM flags derived from arch probe
    if(_arch_defines MATCHES "LJ_LE 1")
        list(APPEND DASM_AFLAGS -D ENDIAN_LE)
    else()
        list(APPEND DASM_AFLAGS -D ENDIAN_BE)
    endif()
    if(_arch_defines MATCHES "LJ_ARCH_BITS 64")
        list(APPEND DASM_AFLAGS -D P64)
    endif()
    if(_arch_defines MATCHES "LJ_HASJIT 1")
        list(APPEND DASM_AFLAGS -D JIT)
    endif()
    if(_arch_defines MATCHES "LJ_HASFFI 1")
        list(APPEND DASM_AFLAGS -D FFI)
    endif()
    if(_arch_defines MATCHES "LJ_DUALNUM 1")
        list(APPEND DASM_AFLAGS -D DUALNUM)
    endif()
    if(_arch_defines MATCHES "LJ_ARCH_HASFPU 1")
        list(APPEND DASM_AFLAGS -D FPU)
    endif()
    if(NOT _arch_defines MATCHES "LJ_ABI_SOFTFP 1")
        list(APPEND DASM_AFLAGS -D HFABI)
    endif()
    if(_arch_defines MATCHES "LJ_TARGET_MIPSR6 1")
        list(APPEND DASM_AFLAGS -D MIPSR6)
    endif()
    if(WIN32 OR _arch_defines MATCHES "LJ_TARGET_WINDOWS 1")
        list(APPEND DASM_AFLAGS -D WIN)
    endif()
    if(_arch_defines MATCHES "LJ_ABI_PAUTH 1")
        list(APPEND DASM_AFLAGS -D PAUTH)
    endif()
    if(_arch_defines MATCHES "LJ_ABI_BRANCH_TRACK 1")
        list(APPEND DASM_AFLAGS -D BRANCH_TRACK)
    endif()
    if(_arch_defines MATCHES "LJ_ABI_SHADOW_STACK 1")
        list(APPEND DASM_AFLAGS -D SHADOW_STACK)
    endif()

    # Arch version
    string(REGEX MATCH "LJ_ARCH_VERSION ([0-9]+)" _ver_match "${_arch_defines}")
    if(_ver_match)
        list(APPEND DASM_AFLAGS -D "VER=${CMAKE_MATCH_1}")
    else()
        list(APPEND DASM_AFLAGS -D VER=0)
    endif()

    # ARM iOS
    if(DASM_ARCH STREQUAL "arm" AND APPLE AND IOS)
        list(APPEND DASM_AFLAGS -D IOS)
    endif()
endif()

message(STATUS "LuaJIT: DASM_ARCH=${DASM_ARCH}, DASM_AFLAGS=${DASM_AFLAGS}")

set(DASM_DASC "${LUAJIT_SOURCE_DIR}/vm_${DASM_ARCH}.dasc")

# ── Step 1: generate host/buildvm_arch.h via DynASM ─────────────────────────
set(BUILDVM_ARCH_H "${CMAKE_CURRENT_BINARY_DIR}/host/buildvm_arch.h")
file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/host")

add_custom_command(
    OUTPUT  "${BUILDVM_ARCH_H}"
    COMMAND "${MINILUA_BIN}" "${DYNASM}" ${DASM_AFLAGS}
            -o "${BUILDVM_ARCH_H}"
            "${DASM_DASC}"
    DEPENDS "${DASM_DASC}" "${DYNASM}"
    COMMENT "LuaJIT: DynASM → buildvm_arch.h"
)

# ── Step 2: build buildvm (host native, reads buildvm_arch.h) ────────────────
set(BUILDVM_SRCS
    "${LUAJIT_SOURCE_DIR}/host/buildvm.c"
    "${LUAJIT_SOURCE_DIR}/host/buildvm_asm.c"
    "${LUAJIT_SOURCE_DIR}/host/buildvm_peobj.c"
    "${LUAJIT_SOURCE_DIR}/host/buildvm_lib.c"
    "${LUAJIT_SOURCE_DIR}/host/buildvm_fold.c"
)
set(BUILDVM_BIN "${CMAKE_CURRENT_BINARY_DIR}/host/buildvm${CMAKE_HOST_EXECUTABLE_SUFFIX}")

set(_buildvm_build_dir "${CMAKE_CURRENT_BINARY_DIR}/host/buildvm_build")
file(MAKE_DIRECTORY "${_buildvm_build_dir}")

# Write a self-contained CMakeLists for buildvm
file(WRITE "${_buildvm_build_dir}/CMakeLists.txt" [=[
cmake_minimum_required(VERSION 3.20)
project(buildvm C)
add_executable(buildvm ${BUILDVM_SRCS})
target_include_directories(buildvm PRIVATE "${LUAJIT_SRC_DIR}" "${ARCH_H_DIR}")
target_compile_definitions(buildvm PRIVATE _BUILDVM_H)
set_target_properties(buildvm PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${OUT_DIR}"
    RUNTIME_OUTPUT_DIRECTORY_DEBUG "${OUT_DIR}"
    RUNTIME_OUTPUT_DIRECTORY_RELEASE "${OUT_DIR}"
    RUNTIME_OUTPUT_DIRECTORY_MINSIZEREL "${OUT_DIR}"
    RUNTIME_OUTPUT_DIRECTORY_RELWITHDEBINFO "${OUT_DIR}"
)
]=])

# We regenerate buildvm only when buildvm_arch.h changes.
# Because buildvm depends on the generated header we cannot use
# add_custom_command + add_custom_target alone for this; instead we use
# a second configure-time sub-build triggered by a cmake script that
# checks the timestamp of buildvm_arch.h.

# Instead, we model it as a cmake -P script that runs at build time.
file(WRITE "${_buildvm_build_dir}/build_buildvm.cmake" "
execute_process(
    COMMAND \"\${CMAKE_COMMAND}\"
        -G \"\${GENERATOR}\"
        \"-DBUILDVM_SRCS=${BUILDVM_SRCS}\"
        \"-DLUAJIT_SRC_DIR=${LUAJIT_SOURCE_DIR}\"
        \"-DARCH_H_DIR=${CMAKE_CURRENT_BINARY_DIR}/host\"
        \"-DOUT_DIR=${CMAKE_CURRENT_BINARY_DIR}/host\"
        \"${_buildvm_build_dir}\"
    RESULT_VARIABLE r
)
if(NOT r EQUAL 0)
    message(FATAL_ERROR \"buildvm configure failed\")
endif()
execute_process(
    COMMAND \"\${CMAKE_COMMAND}\" --build \"${_buildvm_build_dir}\" --config Release
    RESULT_VARIABLE r
)
if(NOT r EQUAL 0)
    message(FATAL_ERROR \"buildvm build failed\")
endif()
")

add_custom_command(
    OUTPUT  "${BUILDVM_BIN}"
    COMMAND "${CMAKE_COMMAND}"
            -DCMAKE_COMMAND=${CMAKE_COMMAND}
            -DGENERATOR=${CMAKE_GENERATOR}
            -P "${_buildvm_build_dir}/build_buildvm.cmake"
    DEPENDS "${BUILDVM_ARCH_H}" ${BUILDVM_SRCS}
    COMMENT "LuaJIT: building host buildvm"
)

add_custom_target(luajit_buildvm DEPENDS "${BUILDVM_BIN}")

# ── Step 3: generate C headers via buildvm ───────────────────────────────────
# These are: lj_bcdef.h  lj_ffdef.h  lj_libdef.h  lj_recdef.h  lj_folddef.h
# Plus: jit/vmdef.lua and luajit.h (version header)

set(LJLIB_C
    "${LUAJIT_SOURCE_DIR}/lib_base.c"
    "${LUAJIT_SOURCE_DIR}/lib_math.c"
    "${LUAJIT_SOURCE_DIR}/lib_bit.c"
    "${LUAJIT_SOURCE_DIR}/lib_string.c"
    "${LUAJIT_SOURCE_DIR}/lib_table.c"
    "${LUAJIT_SOURCE_DIR}/lib_io.c"
    "${LUAJIT_SOURCE_DIR}/lib_os.c"
    "${LUAJIT_SOURCE_DIR}/lib_package.c"
    "${LUAJIT_SOURCE_DIR}/lib_debug.c"
    "${LUAJIT_SOURCE_DIR}/lib_jit.c"
    "${LUAJIT_SOURCE_DIR}/lib_ffi.c"
    "${LUAJIT_SOURCE_DIR}/lib_buffer.c"
)

macro(buildvm_generate MODE OUTPUT)
    set(_extra_deps "${ARGN}")
    add_custom_command(
        OUTPUT  "${OUTPUT}"
        COMMAND "${BUILDVM_BIN}" -m "${MODE}" -o "${OUTPUT}" ${_extra_deps}
        DEPENDS "${BUILDVM_BIN}" ${_extra_deps}
        COMMENT "LuaJIT: buildvm -m ${MODE} → ${OUTPUT}"
    )
endmacro()

set(LJ_BCDEF_H    "${CMAKE_CURRENT_BINARY_DIR}/lj_bcdef.h")
set(LJ_FFDEF_H    "${CMAKE_CURRENT_BINARY_DIR}/lj_ffdef.h")
set(LJ_LIBDEF_H   "${CMAKE_CURRENT_BINARY_DIR}/lj_libdef.h")
set(LJ_RECDEF_H   "${CMAKE_CURRENT_BINARY_DIR}/lj_recdef.h")
set(LJ_FOLDDEF_H  "${CMAKE_CURRENT_BINARY_DIR}/lj_folddef.h")
set(LJ_VMDEF_LUA  "${CMAKE_CURRENT_BINARY_DIR}/jit/vmdef.lua")

file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/jit")

buildvm_generate(bcdef   "${LJ_BCDEF_H}"   ${LJLIB_C})
buildvm_generate(ffdef   "${LJ_FFDEF_H}"   ${LJLIB_C})
buildvm_generate(libdef  "${LJ_LIBDEF_H}"  ${LJLIB_C})
buildvm_generate(recdef  "${LJ_RECDEF_H}"  ${LJLIB_C})
buildvm_generate(vmdef   "${LJ_VMDEF_LUA}" ${LJLIB_C})
buildvm_generate(folddef "${LJ_FOLDDEF_H}" "${LUAJIT_SOURCE_DIR}/lj_opt_fold.c")

# ── Step 4: luajit.h (version header) ────────────────────────────────────────
set(LJ_LUAJIT_H "${CMAKE_CURRENT_BINARY_DIR}/luajit.h")

add_custom_command(
    OUTPUT  "${LJ_LUAJIT_H}"
    COMMAND "${MINILUA_BIN}" "${LUAJIT_SOURCE_DIR}/host/genversion.lua"
    WORKING_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}"
    DEPENDS "${LUAJIT_SOURCE_DIR}/host/genversion.lua"
            "${LUAJIT_SOURCE_DIR}/luajit_rolling.h"
    COMMENT "LuaJIT: generating luajit.h"
)

# ── Step 5: lj_vm.S / lj_vm.obj (native builds only) ────────────────────────
# For WASM this step is skipped; lj_vm_wasm.c fills the same role.
if(NOT LUAJIT_TARGET_WASM)
    if(WIN32)
        set(LJVM_MODE "peobj")
        set(LJVM_OUT  "${CMAKE_CURRENT_BINARY_DIR}/lj_vm.obj")
    elseif(APPLE)
        set(LJVM_MODE "machasm")
        set(LJVM_OUT  "${CMAKE_CURRENT_BINARY_DIR}/lj_vm.S")
    else()
        set(LJVM_MODE "elfasm")
        set(LJVM_OUT  "${CMAKE_CURRENT_BINARY_DIR}/lj_vm.S")
    endif()

    add_custom_command(
        OUTPUT  "${LJVM_OUT}"
        COMMAND "${BUILDVM_BIN}" -m "${LJVM_MODE}" -o "${LJVM_OUT}"
        DEPENDS "${BUILDVM_BIN}"
        COMMENT "LuaJIT: buildvm -m ${LJVM_MODE} → lj_vm"
    )
    set(LUAJIT_VM_SOURCE "${LJVM_OUT}")
else()
    # WASM: no assembled VM; lj_vm_wasm.c is listed in the source file set.
    set(LUAJIT_VM_SOURCE "")
endif()

# ── Aggregate all generated headers into one target ──────────────────────────
set(LUAJIT_GENERATED_HEADERS
    "${LJ_BCDEF_H}"
    "${LJ_FFDEF_H}"
    "${LJ_LIBDEF_H}"
    "${LJ_RECDEF_H}"
    "${LJ_FOLDDEF_H}"
    "${LJ_LUAJIT_H}"
    "${BUILDVM_ARCH_H}"
)

add_custom_target(luajit_headers
    DEPENDS ${LUAJIT_GENERATED_HEADERS} "${LJ_VMDEF_LUA}"
)
