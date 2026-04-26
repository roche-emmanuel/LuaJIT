##############################################################################
# LuaJIT CMake Build System
#
# Supports:
#   - Native builds: Linux (GCC/Clang), Windows (MSVC/Clang-CL), macOS
#   - Cross-compilation via standard CMake toolchain files
#   - Emscripten/WASM (use emcmake cmake ...)
#
# Usage (native):
#   cmake -B build -DCMAKE_BUILD_TYPE=Release
#   cmake --build build
#
# Usage (Emscripten):
#   emcmake cmake -B build-wasm -DCMAKE_BUILD_TYPE=Release
#   cmake --build build-wasm
#
# Key options:
#   LUAJIT_ENABLE_LUA52COMPAT  (default ON)
#   LUAJIT_DISABLE_FFI         (default OFF)
#   LUAJIT_DISABLE_JIT         (default OFF, auto-ON for WASM Phase 0)
#   LUAJIT_DISABLE_GC64        (default OFF)
#   LUAJIT_NUMMODE             (0=default, 1=single, 2=dual)
#   LUAJIT_USE_SYSMALLOC       (default OFF)
#   LUAJIT_BUILD_EXECUTABLE    (default ON, OFF for WASM)
#   LUAJIT_BUILD_STATIC        (default ON)
#   LUAJIT_BUILD_SHARED        (default ON, OFF for WASM)
##############################################################################

cmake_minimum_required(VERSION 3.20)

# Version — keep in sync with upstream
project(LuaJIT
    VERSION 2.1.0
    LANGUAGES C ASM
)

##############################################################################
# Detect Emscripten early — before any option defaults are set
##############################################################################
if(CMAKE_C_COMPILER MATCHES "emcc" OR EMSCRIPTEN OR
   CMAKE_TOOLCHAIN_FILE MATCHES "[Ee]mscripten")
    set(LUAJIT_TARGET_WASM TRUE)
else()
    set(LUAJIT_TARGET_WASM FALSE)
endif()

##############################################################################
# Options
##############################################################################
option(LUAJIT_ENABLE_LUA52COMPAT "Enable Lua 5.2 compatibility features" ON)
option(LUAJIT_DISABLE_FFI        "Disable the FFI extension"              OFF)
option(LUAJIT_DISABLE_GC64       "Disable GC64 mode on x64"               OFF)
option(LUAJIT_USE_SYSMALLOC      "Use system allocator instead of bundled" OFF)
option(LUAJIT_USE_APICHECK       "Enable Lua/C API assertions (slow)"      OFF)
option(LUAJIT_USE_ASSERT         "Enable full VM assertions (very slow)"    OFF)

# JIT: auto-disable for WASM Phase 0, can be forced off elsewhere
if(LUAJIT_TARGET_WASM)
    option(LUAJIT_DISABLE_JIT "Disable the JIT compiler" ON)
else()
    option(LUAJIT_DISABLE_JIT "Disable the JIT compiler" OFF)
endif()

# Build artifact options
if(LUAJIT_TARGET_WASM)
    option(LUAJIT_BUILD_EXECUTABLE "Build the luajit CLI executable" OFF)
    option(LUAJIT_BUILD_SHARED     "Build shared library"            OFF)
else()
    option(LUAJIT_BUILD_EXECUTABLE "Build the luajit CLI executable" ON)
    option(LUAJIT_BUILD_SHARED     "Build shared library"            ON)
endif()
option(LUAJIT_BUILD_STATIC "Build static library" ON)

set(LUAJIT_NUMMODE "0" CACHE STRING "Number mode: 0=default 1=single 2=dual")

##############################################################################
# Paths
##############################################################################
set(LUAJIT_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/src")
set(LUAJIT_DYNASM_DIR "${CMAKE_CURRENT_SOURCE_DIR}/dynasm")

##############################################################################
# Host tools build (always with the host native compiler)
# These must run on the build machine regardless of cross-compilation target.
##############################################################################
include(cmake/HostTools.cmake)

##############################################################################
# Determine target architecture and configure compiler flags
##############################################################################
include(cmake/TargetArch.cmake)

##############################################################################
# Collect source files for the runtime library
##############################################################################
include(cmake/Sources.cmake)

##############################################################################
# Build the runtime library (static and/or shared)
##############################################################################
include(cmake/RuntimeLib.cmake)

##############################################################################
# Build the executable (skipped for WASM)
##############################################################################
if(LUAJIT_BUILD_EXECUTABLE AND NOT LUAJIT_TARGET_WASM)
    include(cmake/Executable.cmake)
endif()

##############################################################################
# Installation rules
##############################################################################
include(cmake/Install.cmake)
