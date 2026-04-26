##############################################################################
# cmake/HostTools.cmake
#
# Builds minilua and buildvm using the HOST native compiler (even when the
# parent build is cross-compiling for Emscripten, ARM, etc.), then generates
# all required headers for the LuaJIT build.
#
# Build steps (all at cmake configure time):
#   A. Compile minilua
#   B. Generate luajit_relver.txt (git) + luajit.h (genversion.lua)
#   C. Probe target arch via preprocessor #pragma message
#   D. Determine DynASM arch + flags
#   E. Run DynASM → host/buildvm_arch.h
#   F. Compile buildvm
#   G. Run buildvm to generate lj_bcdef.h, lj_ffdef.h, …
#   H. Run buildvm → lj_vm.S / lj_vm.obj (skipped for WASM)
##############################################################################

# ── Find the host C compiler ─────────────────────────────────────────────────
# IMPORTANT: use CMAKE_HOST_WIN32 (not WIN32) throughout this file.
# When cross-compiling to Emscripten/WASM, the target is wasm32 so WIN32 is
# FALSE even though we are running on a Windows host.
if(DEFINED ENV{CC_FOR_BUILD})
    set(_HOST_CC "$ENV{CC_FOR_BUILD}")
elseif(NOT CMAKE_CROSSCOMPILING)
    # Native build: the target compiler IS the host compiler.
    set(_HOST_CC "${CMAKE_C_COMPILER}")
else()
    # Cross-compiling: search for a native host compiler.
    if(CMAKE_HOST_WIN32)
        # Prefer cl.exe; check VS env-var path first, then PATH.
        set(_vc_hints "")
        if(DEFINED ENV{VCToolsInstallDir})
            file(TO_CMAKE_PATH "$ENV{VCToolsInstallDir}" _vc_dir)
            list(APPEND _vc_hints
                "${_vc_dir}/bin/HostX64/x64"
                "${_vc_dir}/bin/HostX86/x86")
        endif()
        find_program(_HOST_CC_FOUND NAMES cl clang-cl gcc cc
            HINTS ${_vc_hints})
    else()
        find_program(_HOST_CC_FOUND NAMES gcc clang cc)
    endif()
    if(NOT _HOST_CC_FOUND)
        message(FATAL_ERROR
            "LuaJIT: cannot find a host C compiler for building minilua/buildvm.\n"
            "Set the CC_FOR_BUILD environment variable to the host compiler path.")
    endif()
    set(_HOST_CC "${_HOST_CC_FOUND}")
endif()
message(STATUS "LuaJIT: host compiler: ${_HOST_CC}")

# Detect whether the host compiler is MSVC-style (cl.exe / clang-cl).
get_filename_component(_HOST_CC_BASENAME "${_HOST_CC}" NAME_WE)
string(TOLOWER "${_HOST_CC_BASENAME}" _HOST_CC_BASENAME)
if(_HOST_CC_BASENAME STREQUAL "cl" OR _HOST_CC_BASENAME STREQUAL "clang-cl")
    set(_HOST_CC_IS_MSVC TRUE)
else()
    set(_HOST_CC_IS_MSVC FALSE)
endif()

# ── Common paths ─────────────────────────────────────────────────────────────
if(CMAKE_HOST_WIN32)
    set(_host_exe_suffix ".exe")
else()
    set(_host_exe_suffix "")
endif()

set(MINILUA_BIN "${CMAKE_CURRENT_BINARY_DIR}/host/minilua${_host_exe_suffix}")
set(BUILDVM_BIN "${CMAKE_CURRENT_BINARY_DIR}/host/buildvm${_host_exe_suffix}")
set(DYNASM      "${LUAJIT_DYNASM_DIR}/dynasm.lua")

file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/host")

##############################################################################
# Step A: Compile minilua directly (no sub-CMake; avoids generator issues)
##############################################################################
set(MINILUA_SRC "${LUAJIT_SOURCE_DIR}/host/minilua.c")
message(STATUS "LuaJIT: compiling minilua...")

if(_HOST_CC_IS_MSVC)
    execute_process(
        COMMAND "${_HOST_CC}" /nologo /O2 /D_CRT_SECURE_NO_DEPRECATE
                "${MINILUA_SRC}" "/Fe${MINILUA_BIN}"
        WORKING_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/host"
        RESULT_VARIABLE _mlu_result
        OUTPUT_VARIABLE _mlu_out
        ERROR_VARIABLE  _mlu_err
    )
else()
    execute_process(
        COMMAND "${_HOST_CC}" -O2 -o "${MINILUA_BIN}" "${MINILUA_SRC}" -lm
        RESULT_VARIABLE _mlu_result
        OUTPUT_VARIABLE _mlu_out
        ERROR_VARIABLE  _mlu_err
    )
endif()
if(NOT _mlu_result EQUAL 0)
    message(FATAL_ERROR
        "minilua compile failed (exit ${_mlu_result})\n"
        "stdout:\n${_mlu_out}\nstderr:\n${_mlu_err}")
endif()
if(NOT EXISTS "${MINILUA_BIN}")
    message(FATAL_ERROR "minilua binary not found at ${MINILUA_BIN}")
endif()
message(STATUS "LuaJIT: minilua -> ${MINILUA_BIN}")

##############################################################################
# Step B: Generate luajit.h
#
# genversion.lua opens its input files by relative path from CWD.  Pass
# explicit absolute paths as positional arguments so it works regardless of
# the working directory.
##############################################################################
set(LJ_LUAJIT_H "${CMAKE_CURRENT_BINARY_DIR}/luajit.h")
set(_relver_txt "${CMAKE_CURRENT_BINARY_DIR}/luajit_relver.txt")

# Produce luajit_relver.txt from the git commit timestamp.
find_program(_git_exe git)
if(_git_exe)
    execute_process(
        COMMAND "${_git_exe}" show -s "--format=%ct"
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
        RESULT_VARIABLE  _git_rv
        OUTPUT_VARIABLE  _git_out
        ERROR_QUIET
        OUTPUT_STRIP_TRAILING_WHITESPACE
    )
    if(_git_rv EQUAL 0 AND _git_out MATCHES "^[0-9]+$")
        file(WRITE "${_relver_txt}" "${_git_out}\n")
    endif()
endif()
if(NOT EXISTS "${_relver_txt}")
    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/.relver")
        file(READ "${CMAKE_CURRENT_SOURCE_DIR}/.relver" _relver_content)
        file(WRITE "${_relver_txt}" "${_relver_content}")
    else()
        file(WRITE "${_relver_txt}" "ROLLING\n")
    endif()
endif()

execute_process(
    COMMAND "${MINILUA_BIN}"
            "${LUAJIT_SOURCE_DIR}/host/genversion.lua"
            "${LUAJIT_SOURCE_DIR}/luajit_rolling.h"
            "${_relver_txt}"
            "${LJ_LUAJIT_H}"
    RESULT_VARIABLE _ver_result
    OUTPUT_VARIABLE _ver_out
    ERROR_VARIABLE  _ver_err
)
if(NOT _ver_result EQUAL 0)
    message(FATAL_ERROR
        "genversion.lua failed (exit ${_ver_result})\n"
        "stdout:\n${_ver_out}\nstderr:\n${_ver_err}")
endif()
message(STATUS "LuaJIT: generated luajit.h")

##############################################################################
# Step C: Probe target architecture via #pragma message (stderr / stdout)
#
# Uses CMAKE_C_COMPILER (the TARGET compiler) so the probe reflects the real
# target ABI.  Skipped for WASM — arch is fixed to x86/wasm32 below.
##############################################################################
if(NOT LUAJIT_TARGET_WASM)
    set(_arch_probe_src "${CMAKE_CURRENT_BINARY_DIR}/host/_arch_probe.c")
    file(WRITE "${_arch_probe_src}" [=[
#include "lj_arch.h"
#if LJ_TARGET_X64
#pragma message("LUAJIT_PROBE: LJ_TARGET_X64")
#endif
#if LJ_TARGET_X86 && !LJ_TARGET_X64
#pragma message("LUAJIT_PROBE: LJ_TARGET_X86")
#endif
#if LJ_TARGET_ARM64
#pragma message("LUAJIT_PROBE: LJ_TARGET_ARM64")
#endif
#if LJ_TARGET_ARM && !LJ_TARGET_ARM64
#pragma message("LUAJIT_PROBE: LJ_TARGET_ARM")
#endif
#if LJ_TARGET_PPC
#pragma message("LUAJIT_PROBE: LJ_TARGET_PPC")
#endif
#if LJ_TARGET_MIPS64
#pragma message("LUAJIT_PROBE: LJ_TARGET_MIPS64")
#endif
#if LJ_TARGET_MIPS && !LJ_TARGET_MIPS64
#pragma message("LUAJIT_PROBE: LJ_TARGET_MIPS")
#endif
#if LJ_TARGET_MIPSR6
#pragma message("LUAJIT_PROBE: LJ_TARGET_MIPSR6")
#endif
#if LJ_LE
#pragma message("LUAJIT_PROBE: LJ_LE")
#endif
#if LJ_ARCH_BITS == 64
#pragma message("LUAJIT_PROBE: LJ_ARCH_BITS_64")
#endif
#if LJ_HASJIT
#pragma message("LUAJIT_PROBE: LJ_HASJIT")
#endif
#if LJ_HASFFI
#pragma message("LUAJIT_PROBE: LJ_HASFFI")
#endif
#if LJ_DUALNUM
#pragma message("LUAJIT_PROBE: LJ_DUALNUM")
#endif
#if LJ_ARCH_HASFPU
#pragma message("LUAJIT_PROBE: LJ_ARCH_HASFPU")
#endif
#if LJ_ABI_SOFTFP
#pragma message("LUAJIT_PROBE: LJ_ABI_SOFTFP")
#endif
#if LJ_FR2
#pragma message("LUAJIT_PROBE: LJ_FR2")
#endif
#if LJ_ABI_PAUTH
#pragma message("LUAJIT_PROBE: LJ_ABI_PAUTH")
#endif
#if LJ_ABI_BRANCH_TRACK
#pragma message("LUAJIT_PROBE: LJ_ABI_BRANCH_TRACK")
#endif
#if LJ_ABI_SHADOW_STACK
#pragma message("LUAJIT_PROBE: LJ_ABI_SHADOW_STACK")
#endif
#if defined(__AARCH64EB__)
#pragma message("LUAJIT_PROBE: AARCH64EB")
#endif
#if LJ_TARGET_WINDOWS
#pragma message("LUAJIT_PROBE: LJ_TARGET_WINDOWS")
#endif
#if LJ_ARCH_SQRT
#pragma message("LUAJIT_PROBE: LJ_ARCH_SQRT")
#endif
#if LJ_ARCH_ROUND
#pragma message("LUAJIT_PROBE: LJ_ARCH_ROUND")
#endif
#if LJ_ARCH_PPC32ON64
#pragma message("LUAJIT_PROBE: LJ_ARCH_PPC32ON64")
#endif
#if LJ_ARCH_VERSION >= 80
#pragma message("LUAJIT_PROBE: LJ_ARCH_VERSION_80")
#elif LJ_ARCH_VERSION >= 70
#pragma message("LUAJIT_PROBE: LJ_ARCH_VERSION_70")
#elif LJ_ARCH_VERSION >= 61
#pragma message("LUAJIT_PROBE: LJ_ARCH_VERSION_61")
#elif LJ_ARCH_VERSION >= 60
#pragma message("LUAJIT_PROBE: LJ_ARCH_VERSION_60")
#elif LJ_ARCH_VERSION >= 51
#pragma message("LUAJIT_PROBE: LJ_ARCH_VERSION_51")
#elif LJ_ARCH_VERSION >= 50
#pragma message("LUAJIT_PROBE: LJ_ARCH_VERSION_50")
#elif LJ_ARCH_VERSION >= 40
#pragma message("LUAJIT_PROBE: LJ_ARCH_VERSION_40")
#elif LJ_ARCH_VERSION >= 20
#pragma message("LUAJIT_PROBE: LJ_ARCH_VERSION_20")
#elif LJ_ARCH_VERSION >= 10
#pragma message("LUAJIT_PROBE: LJ_ARCH_VERSION_10")
#else
#pragma message("LUAJIT_PROBE: LJ_ARCH_VERSION_0")
#endif
]=])

    if(MSVC)
        execute_process(
            COMMAND "${CMAKE_C_COMPILER}" /nologo /EP /D_BUILDVM_H
                    "/I${LUAJIT_SOURCE_DIR}" "${_arch_probe_src}"
            OUTPUT_VARIABLE _probe_stdout
            ERROR_VARIABLE  _probe_stderr
            RESULT_VARIABLE _probe_result
        )
        set(_arch_defines "${_probe_stdout}\n${_probe_stderr}")
    else()
        execute_process(
            COMMAND "${CMAKE_C_COMPILER}" -E -D_BUILDVM_H
                    "-I${LUAJIT_SOURCE_DIR}" "${_arch_probe_src}"
            OUTPUT_VARIABLE _probe_stdout
            ERROR_VARIABLE  _probe_stderr
            RESULT_VARIABLE _probe_result
        )
        set(_arch_defines "${_probe_stderr}\n${_probe_stdout}")
    endif()

    if(NOT _probe_result EQUAL 0)
        message(FATAL_ERROR
            "Architecture probe failed (exit ${_probe_result})\n"
            "stderr:\n${_probe_stderr}")
    endif()
endif()

macro(_probe_has VAR MARKER)
    if(_arch_defines MATCHES "LUAJIT_PROBE: ${MARKER}")
        set(${VAR} TRUE)
    else()
        set(${VAR} FALSE)
    endif()
endmacro()

##############################################################################
# Step D: Determine DynASM arch + flags
##############################################################################
set(DASM_AFLAGS "")
set(DASM_ARCH   "")

if(LUAJIT_TARGET_WASM)
    set(DASM_ARCH "x86")
    set(LUAJIT_DASM_ARCH_NAME "wasm32")
    list(APPEND DASM_AFLAGS -D P64 -D JIT -D FFI -D FPU -D HFABI -D ENDIAN_LE -D VER=0)
else()
    _probe_has(_is_x64    "LJ_TARGET_X64")
    _probe_has(_is_x86    "LJ_TARGET_X86")
    _probe_has(_is_arm64  "LJ_TARGET_ARM64")
    _probe_has(_is_arm    "LJ_TARGET_ARM")
    _probe_has(_is_ppc    "LJ_TARGET_PPC")
    _probe_has(_is_mips64 "LJ_TARGET_MIPS64")
    _probe_has(_is_mips   "LJ_TARGET_MIPS")

    if(_is_x64)
        set(LUAJIT_DASM_ARCH_NAME "x64")
        _probe_has(_has_fr2 "LJ_FR2")
        if(_has_fr2)
            set(DASM_ARCH "x64")
        else()
            set(DASM_ARCH "x86")
        endif()
    elseif(_is_x86)
        set(DASM_ARCH "x86")
        set(LUAJIT_DASM_ARCH_NAME "x86")
    elseif(_is_arm64)
        set(DASM_ARCH "arm64")
        set(LUAJIT_DASM_ARCH_NAME "arm64")
    elseif(_is_arm)
        set(DASM_ARCH "arm")
        set(LUAJIT_DASM_ARCH_NAME "arm")
    elseif(_is_ppc)
        set(DASM_ARCH "ppc")
        set(LUAJIT_DASM_ARCH_NAME "ppc")
    elseif(_is_mips64)
        set(DASM_ARCH "mips64")
        set(LUAJIT_DASM_ARCH_NAME "mips64")
    elseif(_is_mips)
        set(DASM_ARCH "mips")
        set(LUAJIT_DASM_ARCH_NAME "mips")
    else()
        message(FATAL_ERROR
            "LuaJIT: cannot detect target architecture.\n"
            "Probe output was:\n${_arch_defines}\n"
            "If cross-compiling ensure CMAKE_C_COMPILER is the cross compiler.")
    endif()

    _probe_has(_le        "LJ_LE")
    _probe_has(_p64       "LJ_ARCH_BITS_64")
    _probe_has(_hasjit    "LJ_HASJIT")
    _probe_has(_hasffi    "LJ_HASFFI")
    _probe_has(_dualnum   "LJ_DUALNUM")
    _probe_has(_hasfpu    "LJ_ARCH_HASFPU")
    _probe_has(_softfp    "LJ_ABI_SOFTFP")
    _probe_has(_mipsr6    "LJ_TARGET_MIPSR6")
    _probe_has(_win       "LJ_TARGET_WINDOWS")
    _probe_has(_pauth     "LJ_ABI_PAUTH")
    _probe_has(_btrack    "LJ_ABI_BRANCH_TRACK")
    _probe_has(_sstack    "LJ_ABI_SHADOW_STACK")
    _probe_has(_aarch64eb "AARCH64EB")
    _probe_has(_sqrt      "LJ_ARCH_SQRT")
    _probe_has(_round     "LJ_ARCH_ROUND")
    _probe_has(_ppc32on64 "LJ_ARCH_PPC32ON64")

    set(_arch_version 0)
    foreach(_v 80 70 61 60 51 50 40 20 10 0)
        if(_arch_defines MATCHES "LUAJIT_PROBE: LJ_ARCH_VERSION_${_v}")
            set(_arch_version "${_v}")
            break()
        endif()
    endforeach()

    if(_le)
        list(APPEND DASM_AFLAGS -D ENDIAN_LE)
    else()
        list(APPEND DASM_AFLAGS -D ENDIAN_BE)
    endif()
    if(_p64)
        list(APPEND DASM_AFLAGS -D P64)
    endif()
    if(_hasjit)
        list(APPEND DASM_AFLAGS -D JIT)
    endif()
    if(_hasffi)
        list(APPEND DASM_AFLAGS -D FFI)
    endif()
    if(_dualnum)
        list(APPEND DASM_AFLAGS -D DUALNUM)
    endif()
    if(_hasfpu)
        list(APPEND DASM_AFLAGS -D FPU)
    endif()
    if(NOT _softfp)
        list(APPEND DASM_AFLAGS -D HFABI)
    endif()
    if(_win OR WIN32)
        list(APPEND DASM_AFLAGS -D WIN)
    endif()
    if(_mipsr6)
        list(APPEND DASM_AFLAGS -D MIPSR6)
    endif()
    if(_pauth)
        list(APPEND DASM_AFLAGS -D PAUTH)
    endif()
    if(_btrack)
        list(APPEND DASM_AFLAGS -D BRANCH_TRACK)
    endif()
    if(_sstack)
        list(APPEND DASM_AFLAGS -D SHADOW_STACK)
    endif()
    if(DASM_ARCH STREQUAL "arm" AND APPLE AND IOS)
        list(APPEND DASM_AFLAGS -D IOS)
    endif()
    if(_sqrt)
        list(APPEND DASM_AFLAGS -D SQRT)
    endif()
    if(_round)
        list(APPEND DASM_AFLAGS -D ROUND)
    endif()
    if(_ppc32on64)
        list(APPEND DASM_AFLAGS -D GPR64)
    endif()
    list(APPEND DASM_AFLAGS -D "VER=${_arch_version}")
endif()

message(STATUS "LuaJIT: arch=${LUAJIT_DASM_ARCH_NAME}  dasm_arch=${DASM_ARCH}")
message(STATUS "LuaJIT: DASM_AFLAGS=${DASM_AFLAGS}")

set(DASM_DASC "${LUAJIT_SOURCE_DIR}/vm_${DASM_ARCH}.dasc")
if(NOT EXISTS "${DASM_DASC}")
    message(FATAL_ERROR "DynASM source not found: ${DASM_DASC}")
endif()

##############################################################################
# Step E: Run DynASM → host/buildvm_arch.h
##############################################################################
set(BUILDVM_ARCH_H "${CMAKE_CURRENT_BINARY_DIR}/host/buildvm_arch.h")

message(STATUS "LuaJIT: running DynASM -> buildvm_arch.h ...")
execute_process(
    COMMAND "${MINILUA_BIN}" "${DYNASM}" ${DASM_AFLAGS}
            -o "${BUILDVM_ARCH_H}" "${DASM_DASC}"
    RESULT_VARIABLE _dasm_result
    OUTPUT_VARIABLE _dasm_out
    ERROR_VARIABLE  _dasm_err
)
if(NOT _dasm_result EQUAL 0)
    message(FATAL_ERROR
        "DynASM failed (exit ${_dasm_result})\n"
        "stdout:\n${_dasm_out}\nstderr:\n${_dasm_err}")
endif()
message(STATUS "LuaJIT: buildvm_arch.h generated")

##############################################################################
# Step F: Compile buildvm directly
#
# buildvm.c includes luajit.h (from binary dir) and buildvm_arch.h
# (from binary dir/host), so both must be in the include path.
##############################################################################
set(BUILDVM_SRCS
    "${LUAJIT_SOURCE_DIR}/host/buildvm.c"
    "${LUAJIT_SOURCE_DIR}/host/buildvm_asm.c"
    "${LUAJIT_SOURCE_DIR}/host/buildvm_peobj.c"
    "${LUAJIT_SOURCE_DIR}/host/buildvm_lib.c"
    "${LUAJIT_SOURCE_DIR}/host/buildvm_fold.c"
)

message(STATUS "LuaJIT: compiling buildvm...")
if(_HOST_CC_IS_MSVC)
    execute_process(
        COMMAND "${_HOST_CC}" /nologo /O2 /D_CRT_SECURE_NO_DEPRECATE
                /D_BUILDVM_H
                "/I${LUAJIT_SOURCE_DIR}"
                "/I${CMAKE_CURRENT_BINARY_DIR}/host"
                "/I${CMAKE_CURRENT_BINARY_DIR}"
                ${BUILDVM_SRCS}
                "/Fe${BUILDVM_BIN}"
        WORKING_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/host"
        RESULT_VARIABLE _bvm_result
        OUTPUT_VARIABLE _bvm_out
        ERROR_VARIABLE  _bvm_err
    )
else()
    execute_process(
        COMMAND "${_HOST_CC}" -O2 -D_BUILDVM_H
                "-I${LUAJIT_SOURCE_DIR}"
                "-I${CMAKE_CURRENT_BINARY_DIR}/host"
                "-I${CMAKE_CURRENT_BINARY_DIR}"
                ${BUILDVM_SRCS}
                -o "${BUILDVM_BIN}" -lm
        RESULT_VARIABLE _bvm_result
        OUTPUT_VARIABLE _bvm_out
        ERROR_VARIABLE  _bvm_err
    )
endif()
if(NOT _bvm_result EQUAL 0)
    message(FATAL_ERROR
        "buildvm compile failed (exit ${_bvm_result})\n"
        "stdout:\n${_bvm_out}\nstderr:\n${_bvm_err}")
endif()
if(NOT EXISTS "${BUILDVM_BIN}")
    message(FATAL_ERROR "buildvm binary not found at ${BUILDVM_BIN}")
endif()
message(STATUS "LuaJIT: buildvm -> ${BUILDVM_BIN}")

##############################################################################
# Step G: Generate headers via buildvm
##############################################################################
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

macro(_buildvm_run MODE OUTPUT)
    execute_process(
        COMMAND "${BUILDVM_BIN}" -m "${MODE}" -o "${OUTPUT}" ${ARGN}
        RESULT_VARIABLE _bvm_run_result
        OUTPUT_VARIABLE _bvm_run_out
        ERROR_VARIABLE  _bvm_run_err
    )
    if(NOT _bvm_run_result EQUAL 0)
        message(FATAL_ERROR
            "buildvm -m ${MODE} failed (exit ${_bvm_run_result})\n"
            "stdout:\n${_bvm_run_out}\nstderr:\n${_bvm_run_err}")
    endif()
    message(STATUS "LuaJIT: generated ${OUTPUT}")
endmacro()

set(LJ_BCDEF_H   "${CMAKE_CURRENT_BINARY_DIR}/lj_bcdef.h")
set(LJ_FFDEF_H   "${CMAKE_CURRENT_BINARY_DIR}/lj_ffdef.h")
set(LJ_LIBDEF_H  "${CMAKE_CURRENT_BINARY_DIR}/lj_libdef.h")
set(LJ_RECDEF_H  "${CMAKE_CURRENT_BINARY_DIR}/lj_recdef.h")
set(LJ_FOLDDEF_H "${CMAKE_CURRENT_BINARY_DIR}/lj_folddef.h")
set(LJ_VMDEF_LUA "${CMAKE_CURRENT_BINARY_DIR}/jit/vmdef.lua")

file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/jit")

_buildvm_run(bcdef   "${LJ_BCDEF_H}"   ${LJLIB_C})
_buildvm_run(ffdef   "${LJ_FFDEF_H}"   ${LJLIB_C})
_buildvm_run(libdef  "${LJ_LIBDEF_H}"  ${LJLIB_C})
_buildvm_run(recdef  "${LJ_RECDEF_H}"  ${LJLIB_C})
_buildvm_run(vmdef   "${LJ_VMDEF_LUA}" ${LJLIB_C})
_buildvm_run(folddef "${LJ_FOLDDEF_H}" "${LUAJIT_SOURCE_DIR}/lj_opt_fold.c")

##############################################################################
# Step H: lj_vm.S / lj_vm.obj  (skipped for WASM)
##############################################################################
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
    _buildvm_run("${LJVM_MODE}" "${LJVM_OUT}")
    set(LUAJIT_VM_SOURCE "${LJVM_OUT}")
else()
    set(LUAJIT_VM_SOURCE "")
endif()

##############################################################################
set(LUAJIT_GENERATED_HEADERS
    "${LJ_BCDEF_H}" "${LJ_FFDEF_H}" "${LJ_LIBDEF_H}"
    "${LJ_RECDEF_H}" "${LJ_FOLDDEF_H}" "${LJ_LUAJIT_H}" "${BUILDVM_ARCH_H}"
)
add_custom_target(luajit_headers
    COMMENT "LuaJIT: all generated headers are up to date")
