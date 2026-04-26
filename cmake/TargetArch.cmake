##############################################################################
# cmake/TargetArch.cmake
#
# Translates the detected architecture + user options into compiler flags,
# compile definitions, and link settings for the target library/executable.
##############################################################################

# ── Feature-flag compile definitions ─────────────────────────────────────────
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

if(MSVC)
    list(APPEND LUAJIT_COMPILE_OPTIONS
        /O2
        /W3
        /D_CRT_SECURE_NO_DEPRECATE
        /D_CRT_STDIO_INLINE
        # Suppress a few noisy MSVC warnings that LuaJIT intentionally triggers
        /wd4244   # conversion, possible loss of data
        /wd4267   # size_t → int conversion
        /wd4146   # unary minus on unsigned
        /wd4334   # 32-bit shift result implicitly converted to 64 bits
    )
elseif(LUAJIT_TARGET_WASM)
    list(APPEND LUAJIT_COMPILE_OPTIONS -O2)
else()
    list(APPEND LUAJIT_COMPILE_OPTIONS
        -O2
        -fomit-frame-pointer
        -Wall
    )
    # -fno-stack-protector only if the compiler supports it
    include(CheckCCompilerFlag)
    check_c_compiler_flag(-fno-stack-protector _has_no_sp)
    if(_has_no_sp)
        list(APPEND LUAJIT_COMPILE_OPTIONS -fno-stack-protector)
    endif()
    if(LUAJIT_DASM_ARCH_NAME STREQUAL "x86")
        list(APPEND LUAJIT_COMPILE_OPTIONS
            -march=i686 -msse -msse2 -mfpmath=sse)
    endif()
endif()

# ── Link libraries ────────────────────────────────────────────────────────────
set(LUAJIT_LINK_LIBS "")
if(NOT WIN32 AND NOT LUAJIT_TARGET_WASM)
    list(APPEND LUAJIT_LINK_LIBS m)
    if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
        list(APPEND LUAJIT_LINK_LIBS dl)
    endif()
endif()

# ── Linker flags ──────────────────────────────────────────────────────────────
set(LUAJIT_EXE_LINKER_FLAGS    "")
set(LUAJIT_SHARED_LINKER_FLAGS "")

if(LUAJIT_TARGET_WASM)
    set(LUAJIT_EMSCRIPTEN_LINK_FLAGS
        "SHELL:-sALLOW_MEMORY_GROWTH=1"
        "SHELL:-sEXPORTED_FUNCTIONS=['_lua_newstate','_lua_close','_luaL_newstate','_luaL_openlibs','_lua_pcall','_luaL_loadbuffer','_lua_tolstring','_lua_settop','_lua_gettop','_lua_pushstring','_lua_pushnumber','_lua_pushinteger','_lua_pushboolean','_lua_pushnil','_luaL_dostring']"
        "SHELL:-sEXPORTED_RUNTIME_METHODS=['ccall','cwrap','UTF8ToString','allocate','ALLOC_NORMAL']"
        "SHELL:-sMODULARIZE=1"
        "SHELL:-sEXPORT_NAME=LuaJIT"
        "SHELL:-sASSERTIONS=1"
    )
elseif(APPLE)
    set(LUAJIT_SHARED_LINKER_FLAGS
        "-dynamiclib -undefined dynamic_lookup -fPIC")
elseif(NOT WIN32)
    set(LUAJIT_EXE_LINKER_FLAGS "-Wl,-E")
endif()

message(STATUS "LuaJIT: compile defs:  ${LUAJIT_TARGET_DEFS}")
message(STATUS "LuaJIT: link libs:     ${LUAJIT_LINK_LIBS}")
