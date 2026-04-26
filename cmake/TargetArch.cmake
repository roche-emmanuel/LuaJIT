##############################################################################
# cmake/TargetArch.cmake
#
# Sets up compiler flags and definitions for the target platform.
# Reads DASM_ARCH / _arch_defines from HostTools.cmake (already included).
##############################################################################

# ── Feature flags → compile definitions ──────────────────────────────────────
set(LUAJIT_TARGET_DEFS "")

if(LUAJIT_ENABLE_LUA52COMPAT)
    list(APPEND LUAJIT_TARGET_DEFS LUAJIT_ENABLE_LUA52COMPAT)
endif()
if(LUAJIT_DISABLE_FFI)
    list(APPEND LUAJIT_TARGET_DEFS LUAJIT_DISABLE_FFI)
endif()
if(LUAJIT_DISABLE_JIT)
    list(APPEND LUAJIT_TARGET_DEFS LUAJIT_DISABLE_JIT)
endif()
if(LUAJIT_DISABLE_GC64)
    list(APPEND LUAJIT_TARGET_DEFS LUAJIT_DISABLE_GC64)
endif()
if(LUAJIT_USE_SYSMALLOC)
    list(APPEND LUAJIT_TARGET_DEFS LUAJIT_USE_SYSMALLOC)
endif()
if(LUAJIT_USE_APICHECK)
    list(APPEND LUAJIT_TARGET_DEFS LUA_USE_APICHECK)
endif()
if(LUAJIT_USE_ASSERT)
    list(APPEND LUAJIT_TARGET_DEFS LUA_USE_ASSERT)
endif()
if(LUAJIT_NUMMODE STREQUAL "1")
    list(APPEND LUAJIT_TARGET_DEFS LUAJIT_NUMMODE=1)
elseif(LUAJIT_NUMMODE STREQUAL "2")
    list(APPEND LUAJIT_TARGET_DEFS LUAJIT_NUMMODE=2)
endif()

# WASM-specific
if(LUAJIT_TARGET_WASM)
    list(APPEND LUAJIT_TARGET_DEFS
        LUAJIT_TARGET=LUAJIT_ARCH_WASM
        LUAJIT_OS=LUAJIT_OS_OTHER
        LJ_ARCH_HASFPU=1
        LJ_ABI_SOFTFP=0
    )
endif()

# ── Compiler flags ────────────────────────────────────────────────────────────
set(LUAJIT_COMPILE_OPTIONS "")

if(LUAJIT_TARGET_WASM)
    # Emscripten: disable frame pointer omission warnings, use -O2
    list(APPEND LUAJIT_COMPILE_OPTIONS -O2)
elseif(MSVC)
    list(APPEND LUAJIT_COMPILE_OPTIONS
        /O2 /W3
        /D_CRT_SECURE_NO_DEPRECATE
        /D_CRT_STDIO_INLINE
    )
    if(CMAKE_C_COMPILER_ID STREQUAL "Clang")
        # clang-cl: nothing extra needed
    else()
        # MSVC: use /MT or /MD based on standard CMake mechanism
        # (CMAKE_MSVC_RUNTIME_LIBRARY handles this in CMake 3.15+)
    endif()
else()
    list(APPEND LUAJIT_COMPILE_OPTIONS
        -O2
        -fomit-frame-pointer
        -Wall
        -fno-stack-protector
    )
    # Arch-specific
    if(LUAJIT_DASM_ARCH_NAME STREQUAL "x86")
        list(APPEND LUAJIT_COMPILE_OPTIONS
            -march=i686 -msse -msse2 -mfpmath=sse)
    endif()
endif()

# ── Link libraries ────────────────────────────────────────────────────────────
set(LUAJIT_LINK_LIBS "")
if(NOT LUAJIT_TARGET_WASM AND NOT WIN32)
    list(APPEND LUAJIT_LINK_LIBS m)
    if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
        list(APPEND LUAJIT_LINK_LIBS dl)
    endif()
endif()

# ── Platform-specific linker flags ────────────────────────────────────────────
set(LUAJIT_EXE_LINKER_FLAGS "")
set(LUAJIT_SHARED_LINKER_FLAGS "")

if(LUAJIT_TARGET_WASM)
    # These get set on the target in RuntimeLib.cmake
    set(LUAJIT_EMSCRIPTEN_LINK_FLAGS
        -sALLOW_MEMORY_GROWTH=1
        -sEXPORTED_FUNCTIONS=['_lua_newstate','_lua_close','_luaL_newstate','_luaL_openlibs','_lua_pcall','_luaL_loadbuffer','_lua_tolstring','_lua_settop','_lua_gettop','_lua_pushstring','_lua_pushnumber','_lua_pushinteger','_lua_pushboolean','_lua_pushnil','_luaL_dostring']
        -sEXPORTED_RUNTIME_METHODS=['ccall','cwrap','UTF8ToString','allocate','ALLOC_NORMAL']
        -sMODULARIZE=1
        -sEXPORT_NAME=LuaJIT
        -sASSERTIONS=1
        -sNODERAWFS=0
    )
elseif(APPLE)
    set(LUAJIT_SHARED_LINKER_FLAGS
        "-dynamiclib -undefined dynamic_lookup -fPIC")
elseif(NOT WIN32)
    set(LUAJIT_EXE_LINKER_FLAGS "-Wl,-E")
endif()

message(STATUS "LuaJIT: target defs: ${LUAJIT_TARGET_DEFS}")
message(STATUS "LuaJIT: link libs:   ${LUAJIT_LINK_LIBS}")
