##############################################################################
# cmake/HostTools.cmake
#
# Builds minilua and buildvm using the HOST (native) compiler.
# Works on Windows (MSVC/clang-cl), Linux (GCC/Clang), macOS, and as the
# host-tools stage of an Emscripten cross-build.
#
# Key design decisions:
#   - Both tools are built at CMake CONFIGURE time (execute_process), not at
#     build time, so all generated headers exist before any .c file compiles.
#   - Sub-builds always use "NMake Makefiles" on Windows or "Unix Makefiles"
#     elsewhere — never the parent generator — so they only need cl.exe/gcc
#     on PATH, not Ninja/MSBuild.
#   - Error output is captured and printed on failure so you can see exactly
#     what went wrong.
##############################################################################

# ── Helper: pick a simple, always-available generator for sub-builds ─────────
# We deliberately avoid the parent generator here. Ninja might not be on PATH
# inside the sub-process on Windows; MSBuild multi-config adds complexity.
# NMake / Unix Make are always present when the corresponding toolchain is.
if(WIN32)
    set(_HOST_GENERATOR "NMake Makefiles")
else()
    set(_HOST_GENERATOR "Unix Makefiles")
endif()

# ── Helper macro: run a sub-cmake configure+build, die with output on error ──
macro(_host_subbuild NAME BUILD_DIR)
    execute_process(
        COMMAND "${CMAKE_COMMAND}"
            -G "${_HOST_GENERATOR}"
            ${ARGN}                           # caller passes -DVAR=val ... SRC_DIR
        WORKING_DIRECTORY "${BUILD_DIR}"
        RESULT_VARIABLE   _sub_cfg_result
        OUTPUT_VARIABLE   _sub_cfg_out
        ERROR_VARIABLE    _sub_cfg_err
    )
    if(NOT _sub_cfg_result EQUAL 0)
        message(FATAL_ERROR
            "${NAME} configure failed (exit ${_sub_cfg_result})\n"
            "stdout:\n${_sub_cfg_out}\n"
            "stderr:\n${_sub_cfg_err}")
    endif()

    execute_process(
        COMMAND "${CMAKE_COMMAND}" --build "${BUILD_DIR}" --config Release
        RESULT_VARIABLE  _sub_build_result
        OUTPUT_VARIABLE  _sub_build_out
        ERROR_VARIABLE   _sub_build_err
    )
    if(NOT _sub_build_result EQUAL 0)
        message(FATAL_ERROR
            "${NAME} build failed (exit ${_sub_build_result})\n"
            "stdout:\n${_sub_build_out}\n"
            "stderr:\n${_sub_build_err}")
    endif()
endmacro()

##############################################################################
# Step A: Build minilua
##############################################################################
set(MINILUA_SRC "${LUAJIT_SOURCE_DIR}/host/minilua.c")

# Executable suffix for the HOST (build machine), not the target.
# On Windows this is ".exe"; elsewhere "".
if(WIN32)
    set(_host_exe_suffix ".exe")
else()
    set(_host_exe_suffix "")
endif()

set(MINILUA_BIN
    "${CMAKE_CURRENT_BINARY_DIR}/host/minilua${_host_exe_suffix}")

set(_minilua_build_dir "${CMAKE_CURRENT_BINARY_DIR}/host/minilua_build")
file(MAKE_DIRECTORY "${_minilua_build_dir}")
file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/host")

# Write the sub-project CMakeLists. Key differences from the old version:
#   - math library linked only on non-Windows (libm doesn't exist on Windows)
#   - OUTPUT_DIRECTORY set for all configs so Release/Debug both land in host/
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
    message(FATAL_ERROR
        "minilua binary expected at:\n  ${MINILUA_BIN}\nbut was not found "
        "after a successful build. Check RUNTIME_OUTPUT_DIRECTORY logic.")
endif()
message(STATUS "LuaJIT: minilua → ${MINILUA_BIN}")

##############################################################################
# Step B: Probe target architecture via preprocessor
##############################################################################
set(DYNASM "${LUAJIT_DYNASM_DIR}/dynasm.lua")

set(_arch_probe_src "${CMAKE_CURRENT_BINARY_DIR}/host/_arch_probe.c")
file(WRITE "${_arch_probe_src}" "#include \"lj_arch.h\"\n")

# MSVC uses /EP /P for preprocessing; GCC/Clang use -E -dM.
if(MSVC)
    # /EP: preprocess to stdout, no line markers
    # /D_BUILDVM_H: suppress the target-arch checks that require a target link
    execute_process(
        COMMAND "${CMAKE_C_COMPILER}"
            /nologo /EP
            "/I${LUAJIT_SOURCE_DIR}"
            /D_BUILDVM_H
            "${_arch_probe_src}"
        OUTPUT_VARIABLE _arch_defines
        ERROR_QUIET
        RESULT_VARIABLE _probe_result
    )
else()
    execute_process(
        COMMAND "${CMAKE_C_COMPILER}" -E -dM
            "-I${LUAJIT_SOURCE_DIR}"
            "${_arch_probe_src}"
        OUTPUT_VARIABLE _arch_defines
        ERROR_QUIET
        RESULT_VARIABLE _probe_result
    )
    if(NOT _probe_result EQUAL 0)
        # Some cross-compilers don't support -dM; fall back to plain -E
        execute_process(
            COMMAND "${CMAKE_C_COMPILER}" -E
                "-I${LUAJIT_SOURCE_DIR}"
                "${_arch_probe_src}"
            OUTPUT_VARIABLE _arch_defines
            ERROR_QUIET
            RESULT_VARIABLE _probe_result
        )
    endif()
endif()

##############################################################################
# Step C: Determine DASM arch + flags from probe output
##############################################################################
set(DASM_AFLAGS "")
set(DASM_ARCH   "")

if(LUAJIT_TARGET_WASM)
    # WASM: use x86 .dasc just to generate the header enumerations.
    # The assembled VM itself is replaced by lj_vm_wasm.c.
    set(DASM_ARCH "x86")
    set(LUAJIT_DASM_ARCH_NAME "wasm32")
    list(APPEND DASM_AFLAGS -D P64 -D JIT -D FFI -D FPU -D HFABI -D ENDIAN_LE -D VER=0)
else()
    # x86 must be checked BEFORE x64 because x64 probe also defines
    # LJ_TARGET_X86 on some compilers — check the more specific one first.
    if(_arch_defines MATCHES "LJ_TARGET_X64 1")
        set(LUAJIT_DASM_ARCH_NAME "x64")
        # GC64 mode uses vm_x64.dasc; legacy (non-GC64) uses vm_x86.dasc
        if(_arch_defines MATCHES "LJ_FR2 1")
            set(DASM_ARCH "x64")
        else()
            set(DASM_ARCH "x86")
        endif()
    elseif(_arch_defines MATCHES "LJ_TARGET_X86 1")
        set(DASM_ARCH "x86")
        set(LUAJIT_DASM_ARCH_NAME "x86")
    elseif(_arch_defines MATCHES "LJ_TARGET_ARM64 1")
        set(DASM_ARCH "arm64")
        set(LUAJIT_DASM_ARCH_NAME "arm64")
    elseif(_arch_defines MATCHES "LJ_TARGET_ARM 1")
        set(DASM_ARCH "arm")
        set(LUAJIT_DASM_ARCH_NAME "arm")
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
            "LuaJIT: cannot detect target architecture.\n"
            "Preprocessor output was:\n${_arch_defines}\n"
            "If cross-compiling ensure CMAKE_C_COMPILER is the cross compiler.")
    endif()

    # Endianness
    if(_arch_defines MATCHES "LJ_LE 1")
        list(APPEND DASM_AFLAGS -D ENDIAN_LE)
    else()
        list(APPEND DASM_AFLAGS -D ENDIAN_BE)
    endif()
    # Pointer size
    if(_arch_defines MATCHES "LJ_ARCH_BITS 64")
        list(APPEND DASM_AFLAGS -D P64)
    endif()
    # Feature flags
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
    # Platform
    if(WIN32 OR _arch_defines MATCHES "LJ_TARGET_WINDOWS 1")
        list(APPEND DASM_AFLAGS -D WIN)
    endif()
    # ABI flags
    if(_arch_defines MATCHES "LJ_ABI_PAUTH 1")
        list(APPEND DASM_AFLAGS -D PAUTH)
    endif()
    if(_arch_defines MATCHES "LJ_ABI_BRANCH_TRACK 1")
        list(APPEND DASM_AFLAGS -D BRANCH_TRACK)
    endif()
    if(_arch_defines MATCHES "LJ_ABI_SHADOW_STACK 1")
        list(APPEND DASM_AFLAGS -D SHADOW_STACK)
    endif()
    # MIPS R6
    if(_arch_defines MATCHES "LJ_TARGET_MIPSR6 1")
        list(APPEND DASM_AFLAGS -D MIPSR6)
    endif()
    # ARM iOS
    if(DASM_ARCH STREQUAL "arm" AND APPLE AND IOS)
        list(APPEND DASM_AFLAGS -D IOS)
    endif()
    # PPC extras
    if(DASM_ARCH STREQUAL "ppc")
        if(_arch_defines MATCHES "LJ_ARCH_SQRT 1")
            list(APPEND DASM_AFLAGS -D SQRT)
        endif()
        if(_arch_defines MATCHES "LJ_ARCH_ROUND 1")
            list(APPEND DASM_AFLAGS -D ROUND)
        endif()
        if(_arch_defines MATCHES "LJ_ARCH_PPC32ON64 1")
            list(APPEND DASM_AFLAGS -D GPR64)
        endif()
    endif()
    # Arch version number
    string(REGEX MATCH "#define LJ_ARCH_VERSION ([0-9]+)" _ver_match "${_arch_defines}")
    if(CMAKE_MATCH_1)
        list(APPEND DASM_AFLAGS -D "VER=${CMAKE_MATCH_1}")
    else()
        list(APPEND DASM_AFLAGS -D VER=0)
    endif()
endif()

message(STATUS "LuaJIT: arch=${LUAJIT_DASM_ARCH_NAME}  dasm_arch=${DASM_ARCH}")
message(STATUS "LuaJIT: DASM_AFLAGS=${DASM_AFLAGS}")

set(DASM_DASC "${LUAJIT_SOURCE_DIR}/vm_${DASM_ARCH}.dasc")
if(NOT EXISTS "${DASM_DASC}")
    message(FATAL_ERROR "DynASM source not found: ${DASM_DASC}")
endif()

##############################################################################
# Step D: Run DynASM → host/buildvm_arch.h   (at configure time)
##############################################################################
set(BUILDVM_ARCH_H "${CMAKE_CURRENT_BINARY_DIR}/host/buildvm_arch.h")

message(STATUS "LuaJIT: running DynASM → buildvm_arch.h ...")
execute_process(
    COMMAND "${MINILUA_BIN}" "${DYNASM}"
            ${DASM_AFLAGS}
            -o "${BUILDVM_ARCH_H}"
            "${DASM_DASC}"
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
# Step E: Build buildvm   (at configure time)
##############################################################################
set(BUILDVM_SRCS
    "${LUAJIT_SOURCE_DIR}/host/buildvm.c"
    "${LUAJIT_SOURCE_DIR}/host/buildvm_asm.c"
    "${LUAJIT_SOURCE_DIR}/host/buildvm_peobj.c"
    "${LUAJIT_SOURCE_DIR}/host/buildvm_lib.c"
    "${LUAJIT_SOURCE_DIR}/host/buildvm_fold.c"
)
set(BUILDVM_BIN
    "${CMAKE_CURRENT_BINARY_DIR}/host/buildvm${_host_exe_suffix}")

set(_buildvm_build_dir "${CMAKE_CURRENT_BINARY_DIR}/host/buildvm_build")
file(MAKE_DIRECTORY "${_buildvm_build_dir}")

file(WRITE "${_buildvm_build_dir}/CMakeLists.txt" [=[
cmake_minimum_required(VERSION 3.20)
project(buildvm C)
add_executable(buildvm ${BUILDVM_SRCS})
target_include_directories(buildvm PRIVATE "${LUAJIT_SRC_DIR}" "${ARCH_H_DIR}")
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
    "-DOUT_DIR=${CMAKE_CURRENT_BINARY_DIR}/host"
    "${_buildvm_build_dir}"
)

if(NOT EXISTS "${BUILDVM_BIN}")
    message(FATAL_ERROR
        "buildvm binary expected at:\n  ${BUILDVM_BIN}\nbut was not found.")
endif()
message(STATUS "LuaJIT: buildvm → ${BUILDVM_BIN}")

##############################################################################
# Step F: Run buildvm to generate all headers   (at configure time)
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

# Helper: run buildvm -m MODE -o OUTPUT [extra args], die on error
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
set(LJ_LUAJIT_H  "${CMAKE_CURRENT_BINARY_DIR}/luajit.h")

file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/jit")

_buildvm_run(bcdef   "${LJ_BCDEF_H}"   ${LJLIB_C})
_buildvm_run(ffdef   "${LJ_FFDEF_H}"   ${LJLIB_C})
_buildvm_run(libdef  "${LJ_LIBDEF_H}"  ${LJLIB_C})
_buildvm_run(recdef  "${LJ_RECDEF_H}"  ${LJLIB_C})
_buildvm_run(vmdef   "${LJ_VMDEF_LUA}" ${LJLIB_C})
_buildvm_run(folddef "${LJ_FOLDDEF_H}"
    "${LUAJIT_SOURCE_DIR}/lj_opt_fold.c")

# luajit.h version header
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
# Step G: lj_vm.S / lj_vm.obj (native only, also at configure time)
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
# Expose a dummy target so other targets can depend on "headers done"
##############################################################################
set(LUAJIT_GENERATED_HEADERS
    "${LJ_BCDEF_H}"
    "${LJ_FFDEF_H}"
    "${LJ_LIBDEF_H}"
    "${LJ_RECDEF_H}"
    "${LJ_FOLDDEF_H}"
    "${LJ_LUAJIT_H}"
    "${BUILDVM_ARCH_H}"
)

# All headers already exist on disk at this point (generated above).
# The custom target is kept for add_dependencies() compatibility.
add_custom_target(luajit_headers
    COMMENT "LuaJIT: all generated headers are up to date"
)
