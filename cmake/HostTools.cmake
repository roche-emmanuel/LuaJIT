##############################################################################
# cmake/HostTools.cmake
#
# Builds minilua and buildvm using the HOST native compiler, even when the
# parent build is cross-compiling (Emscripten, ARM, etc.).
##############################################################################

# ── Find the host C compiler ──────────────────────────────────────────────────
# When cross-compiling, CMAKE_C_COMPILER is the cross compiler (e.g. emcc).
# We need a native host compiler for minilua and buildvm.
# Search order: env CC_FOR_BUILD, then common names.
if(DEFINED ENV{CC_FOR_BUILD})
    set(_HOST_CC "$ENV{CC_FOR_BUILD}")
elseif(WIN32)
    # On Windows find cl.exe via the VS environment (already initialised by
    # the parent CMake run) or fall back to clang-cl / gcc.
    find_program(_HOST_CC_FOUND NAMES cl clang-cl gcc cc)
    set(_HOST_CC "${_HOST_CC_FOUND}")
else()
    find_program(_HOST_CC_FOUND NAMES gcc clang cc)
    set(_HOST_CC "${_HOST_CC_FOUND}")
endif()

if(NOT _HOST_CC)
    message(FATAL_ERROR
        "LuaJIT: cannot find a host C compiler for building minilua/buildvm.\n"
        "Set the CC_FOR_BUILD environment variable to the host compiler path.")
endif()
message(STATUS "LuaJIT: host compiler for build tools: ${_HOST_CC}")

# ── Simple generator for sub-builds (no Ninja dependency) ────────────────────
if(WIN32)
    set(_HOST_GENERATOR "NMake Makefiles")
else()
    set(_HOST_GENERATOR "Unix Makefiles")
endif()

# ── Helper: configure+build a sub-project with the HOST compiler ──────────────
macro(_host_subbuild NAME BUILD_DIR)
    execute_process(
        COMMAND "${CMAKE_COMMAND}" -G "${_HOST_GENERATOR}"
            "-DCMAKE_C_COMPILER=${_HOST_CC}"
            "-DCMAKE_BUILD_TYPE=Release"
            ${ARGN}
        WORKING_DIRECTORY "${BUILD_DIR}"
        RESULT_VARIABLE _sub_cfg_result
        OUTPUT_VARIABLE _sub_cfg_out
        ERROR_VARIABLE  _sub_cfg_err
    )
    if(NOT _sub_cfg_result EQUAL 0)
        message(FATAL_ERROR
            "${NAME} configure failed (exit ${_sub_cfg_result})\n"
            "stdout:\n${_sub_cfg_out}\nstderr:\n${_sub_cfg_err}")
    endif()
    execute_process(
        COMMAND "${CMAKE_COMMAND}" --build "${BUILD_DIR}" --config Release
        RESULT_VARIABLE _sub_build_result
        OUTPUT_VARIABLE _sub_build_out
        ERROR_VARIABLE  _sub_build_err
    )
    if(NOT _sub_build_result EQUAL 0)
        message(FATAL_ERROR
            "${NAME} build failed (exit ${_sub_build_result})\n"
            "stdout:\n${_sub_build_out}\nstderr:\n${_sub_build_err}")
    endif()
endmacro()

##############################################################################
# Step A: Build minilua
##############################################################################
set(MINILUA_SRC "${LUAJIT_SOURCE_DIR}/host/minilua.c")

if(WIN32)
    set(_host_exe_suffix ".exe")
else()
    set(_host_exe_suffix "")
endif()

set(MINILUA_BIN "${CMAKE_CURRENT_BINARY_DIR}/host/minilua${_host_exe_suffix}")
set(_minilua_build_dir "${CMAKE_CURRENT_BINARY_DIR}/host/minilua_build")
file(REMOVE_RECURSE "${_minilua_build_dir}")
file(MAKE_DIRECTORY "${_minilua_build_dir}")
file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/host")

file(WRITE "${_minilua_build_dir}/CMakeLists.txt" [=[
cmake_minimum_required(VERSION 3.20)
project(minilua C)
add_executable(minilua "${MINILUA_SRC}")
if(NOT WIN32)
    target_link_libraries(minilua PRIVATE m)
endif()
foreach(_cfg "" "_DEBUG" "_RELEASE" "_MINSIZEREL" "_RELWITHDEBINFO")
    set_target_properties(minilua PROPERTIES
        "RUNTIME_OUTPUT_DIRECTORY${_cfg}" "${OUT_DIR}")
endforeach()
]=])

message(STATUS "LuaJIT: configuring minilua...")
_host_subbuild("minilua" "${_minilua_build_dir}"
    "-DMINILUA_SRC=${MINILUA_SRC}"
    "-DOUT_DIR=${CMAKE_CURRENT_BINARY_DIR}/host"
    "${_minilua_build_dir}"
)
if(NOT EXISTS "${MINILUA_BIN}")
    message(FATAL_ERROR "minilua binary not found at ${MINILUA_BIN}")
endif()
message(STATUS "LuaJIT: minilua -> ${MINILUA_BIN}")

##############################################################################
# Step B: Generate luajit.h FIRST (buildvm #includes it)
##############################################################################
set(DYNASM    "${LUAJIT_DYNASM_DIR}/dynasm.lua")
set(LJ_LUAJIT_H "${CMAKE_CURRENT_BINARY_DIR}/luajit.h")

execute_process(
    COMMAND "${MINILUA_BIN}" "${LUAJIT_SOURCE_DIR}/host/genversion.lua"
    WORKING_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}"
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
# Step C: Probe target architecture via #pragma message (stderr)
#
# #pragma message() writes to stderr on GCC and Clang.
# On MSVC it writes to stdout in the form:  filename.c\nmessage-text
# So we capture BOTH streams and search both.
##############################################################################
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

# Use the TARGET compiler for the probe (we want the target arch, not the host).
# For Emscripten CMAKE_C_COMPILER is emcc — that's correct here.
if(MSVC)
    execute_process(
        COMMAND "${CMAKE_C_COMPILER}" /nologo /EP /D_BUILDVM_H
            "/I${LUAJIT_SOURCE_DIR}" "${_arch_probe_src}"
        OUTPUT_VARIABLE _probe_stdout
        ERROR_VARIABLE  _probe_stderr
        RESULT_VARIABLE _probe_result
    )
    # MSVC #pragma message goes to stdout (mixed with expanded source).
    set(_arch_defines "${_probe_stdout}\n${_probe_stderr}")
else()
    execute_process(
        COMMAND "${CMAKE_C_COMPILER}" -E -D_BUILDVM_H
            "-I${LUAJIT_SOURCE_DIR}" "${_arch_probe_src}"
        OUTPUT_VARIABLE _probe_stdout
        ERROR_VARIABLE  _probe_stderr
        RESULT_VARIABLE _probe_result
    )
    # GCC/Clang #pragma message goes to stderr.
    set(_arch_defines "${_probe_stderr}\n${_probe_stdout}")
endif()

if(NOT _probe_result EQUAL 0)
    message(FATAL_ERROR
        "Architecture probe failed (exit ${_probe_result})\n"
        "stderr:\n${_probe_stderr}")
endif()

macro(_probe_has VAR MARKER)
    if(_arch_defines MATCHES "LUAJIT_PROBE: ${MARKER}")
        set(${VAR} TRUE)
    else()
        set(${VAR} FALSE)
    endif()
endmacro()

set(_arch_version 0)
foreach(_v 80 70 61 60 51 50 40 20 10 0)
    if(_arch_defines MATCHES "LUAJIT_PROBE: LJ_ARCH_VERSION_${_v}")
        set(_arch_version "${_v}")
        break()
    endif()
endforeach()

##############################################################################
# Step D: Determine DASM arch + flags
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
# Step E: Run DynASM -> host/buildvm_arch.h
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
# Step F: Build buildvm
# Include both the source dir AND the binary dir so buildvm finds luajit.h
##############################################################################
set(BUILDVM_SRCS
    "${LUAJIT_SOURCE_DIR}/host/buildvm.c"
    "${LUAJIT_SOURCE_DIR}/host/buildvm_asm.c"
    "${LUAJIT_SOURCE_DIR}/host/buildvm_peobj.c"
    "${LUAJIT_SOURCE_DIR}/host/buildvm_lib.c"
    "${LUAJIT_SOURCE_DIR}/host/buildvm_fold.c"
)
set(BUILDVM_BIN "${CMAKE_CURRENT_BINARY_DIR}/host/buildvm${_host_exe_suffix}")
set(_buildvm_build_dir "${CMAKE_CURRENT_BINARY_DIR}/host/buildvm_build")
file(REMOVE_RECURSE "${_buildvm_build_dir}")
file(MAKE_DIRECTORY "${_buildvm_build_dir}")

file(WRITE "${_buildvm_build_dir}/CMakeLists.txt" [=[
cmake_minimum_required(VERSION 3.20)
project(buildvm C)
add_executable(buildvm ${BUILDVM_SRCS})
target_include_directories(buildvm PRIVATE
    "${LUAJIT_SRC_DIR}"
    "${ARCH_H_DIR}"
    "${GENERATED_DIR}")   # <-- for luajit.h
target_compile_definitions(buildvm PRIVATE _BUILDVM_H)
foreach(_cfg "" "_DEBUG" "_RELEASE" "_MINSIZEREL" "_RELWITHDEBINFO")
    set_target_properties(buildvm PROPERTIES
        "RUNTIME_OUTPUT_DIRECTORY${_cfg}" "${OUT_DIR}")
endforeach()
]=])

message(STATUS "LuaJIT: configuring buildvm...")
_host_subbuild("buildvm" "${_buildvm_build_dir}"
    "-DBUILDVM_SRCS=${BUILDVM_SRCS}"
    "-DLUAJIT_SRC_DIR=${LUAJIT_SOURCE_DIR}"
    "-DARCH_H_DIR=${CMAKE_CURRENT_BINARY_DIR}/host"
    "-DGENERATED_DIR=${CMAKE_CURRENT_BINARY_DIR}"
    "-DOUT_DIR=${CMAKE_CURRENT_BINARY_DIR}/host"
    "${_buildvm_build_dir}"
)
if(NOT EXISTS "${BUILDVM_BIN}")
    message(FATAL_ERROR "buildvm binary not found at ${BUILDVM_BIN}")
endif()
message(STATUS "LuaJIT: buildvm -> ${BUILDVM_BIN}")

##############################################################################
# Step G: Generate remaining headers via buildvm
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
        RESULT_VARIABLE _bvm_result
        OUTPUT_VARIABLE _bvm_out
        ERROR_VARIABLE  _bvm_err
    )
    if(NOT _bvm_result EQUAL 0)
        message(FATAL_ERROR
            "buildvm -m ${MODE} failed (exit ${_bvm_result})\n"
            "stdout:\n${_bvm_out}\nstderr:\n${_bvm_err}")
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
# Step H: lj_vm.S / lj_vm.obj
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
