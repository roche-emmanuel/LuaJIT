##############################################################################
# cmake/RuntimeLib.cmake
#
# Defines the luajit_static and/or luajit_shared targets.
# Both targets share the same compile flags / includes / defines.
# A WASM build produces a single .js+.wasm pair instead of a .so.
##############################################################################

# ── Helper: apply common settings to any library target ──────────────────────
function(_luajit_configure_target TGT)
    # Include dirs: source tree + binary dir (for generated headers)
    target_include_directories("${TGT}" PUBLIC
        "${LUAJIT_SOURCE_DIR}"
        "${CMAKE_CURRENT_BINARY_DIR}"
        "${CMAKE_CURRENT_BINARY_DIR}/host"   # for buildvm_arch.h during build
    )

    # Compile definitions
    target_compile_definitions("${TGT}" PRIVATE ${LUAJIT_TARGET_DEFS})
    # LUA_CORE needed by most source files
    target_compile_definitions("${TGT}" PRIVATE LUA_CORE)

    # Compiler options
    target_compile_options("${TGT}" PRIVATE ${LUAJIT_COMPILE_OPTIONS})

    # Link libraries
    target_link_libraries("${TGT}" PUBLIC ${LUAJIT_LINK_LIBS})

    # Generated headers must exist before any source compiles
    add_dependencies("${TGT}" luajit_headers)

    # Windows: export Lua API symbols from the DLL
    if(WIN32 AND NOT LUAJIT_TARGET_WASM)
        target_compile_definitions("${TGT}" PRIVATE LUA_BUILD_AS_DLL)
    endif()

    # MSVC runtime: static by default (matches your Python builder's /MT)
    if(MSVC)
        set_property(TARGET "${TGT}" PROPERTY
            MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
    endif()
endfunction()

# ── Static library ────────────────────────────────────────────────────────────
if(LUAJIT_BUILD_STATIC)
    add_library(luajit_static STATIC ${LUAJIT_ALL_SOURCES})
    _luajit_configure_target(luajit_static)

    set_target_properties(luajit_static PROPERTIES
        OUTPUT_NAME "luajit"
        PREFIX      "lib"
        POSITION_INDEPENDENT_CODE ON    # safe to link into shared libs too
    )

    # Alias for clean consumer syntax: target_link_libraries(myapp luajit::static)
    add_library(luajit::static ALIAS luajit_static)
endif()

# ── Shared library (native only) ──────────────────────────────────────────────
if(LUAJIT_BUILD_SHARED AND NOT LUAJIT_TARGET_WASM)
    add_library(luajit_shared SHARED ${LUAJIT_ALL_SOURCES})
    _luajit_configure_target(luajit_shared)

    set_target_properties(luajit_shared PROPERTIES
        OUTPUT_NAME "luajit"
        PREFIX      "lib"
        SOVERSION   "1"
        VERSION     "${PROJECT_VERSION}"
    )

    if(NOT WIN32 AND NOT APPLE)
        set_target_properties(luajit_shared PROPERTIES
            LINK_FLAGS "${LUAJIT_SHARED_LINKER_FLAGS}")
    endif()

    add_library(luajit::shared ALIAS luajit_shared)
endif()

# ── Emscripten WASM "executable" (produces luajit.js + luajit.wasm) ──────────
if(LUAJIT_TARGET_WASM)
    # Build an EXECUTABLE target — emcc treats this as the link step that
    # produces .js + .wasm. We link the static library into it.
    if(LUAJIT_BUILD_STATIC)
        add_executable(luajit_wasm "${LUAJIT_SOURCE_DIR}/luajit_wasm_entry.c")
        target_link_libraries(luajit_wasm PRIVATE luajit_static)
    else()
        # If someone disabled static, compile everything directly
        add_executable(luajit_wasm ${LUAJIT_ALL_SOURCES})
        _luajit_configure_target(luajit_wasm)
    endif()

    set_target_properties(luajit_wasm PROPERTIES
        OUTPUT_NAME "luajit"
        SUFFIX      ".js"
    )

    # Emscripten link flags
    foreach(_flag ${LUAJIT_EMSCRIPTEN_LINK_FLAGS})
        target_link_options(luajit_wasm PRIVATE "${_flag}")
    endforeach()
endif()

# ── Default alias (picks static or shared, preferring static) ────────────────
if(LUAJIT_BUILD_STATIC)
    add_library(luajit::luajit ALIAS luajit_static)
elseif(LUAJIT_BUILD_SHARED)
    add_library(luajit::luajit ALIAS luajit_shared)
endif()
