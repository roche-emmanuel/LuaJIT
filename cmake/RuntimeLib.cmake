##############################################################################
# cmake/RuntimeLib.cmake
#
# Defines luajit_static, luajit_shared (native), and luajit_wasm targets.
##############################################################################

# ── Helper: apply common settings to any library/exe target ──────────────────
# IS_DLL: pass TRUE only for the shared-library target so that
# LUA_BUILD_AS_DLL (-> __declspec(dllexport)) is set only when building
# the DLL, not the static library or executable.
function(_luajit_configure_target TGT IS_DLL)
    target_include_directories("${TGT}" PUBLIC
        "$<BUILD_INTERFACE:${LUAJIT_SOURCE_DIR}>"
        "$<BUILD_INTERFACE:${CMAKE_CURRENT_BINARY_DIR}>"
        "$<BUILD_INTERFACE:${CMAKE_CURRENT_BINARY_DIR}/host>"
        "$<INSTALL_INTERFACE:include/luajit>"
    )
    target_compile_definitions("${TGT}" PRIVATE LUA_CORE ${LUAJIT_TARGET_DEFS})
    target_compile_options("${TGT}"     PRIVATE ${LUAJIT_COMPILE_OPTIONS})
    target_link_libraries("${TGT}"      PUBLIC  ${LUAJIT_LINK_LIBS})
    add_dependencies("${TGT}" luajit_headers)

    if(IS_DLL AND WIN32 AND NOT LUAJIT_TARGET_WASM)
        target_compile_definitions("${TGT}" PRIVATE LUA_BUILD_AS_DLL)
    endif()

    if(MSVC)
        set_property(TARGET "${TGT}" PROPERTY
            MSVC_RUNTIME_LIBRARY
            "MultiThreaded$<$<CONFIG:Debug>:Debug>")
    endif()
endfunction()

# ── Static library ────────────────────────────────────────────────────────────
if(LUAJIT_BUILD_STATIC)
    if(WIN32 AND NOT LUAJIT_TARGET_WASM AND LUAJIT_VM_SOURCE MATCHES "\\.obj$")
        # On Windows the VM is a pre-built .obj (peobj mode).
        # Build all C sources into the .lib first, then merge lj_vm.obj in
        # via a lib.exe post-build step.
        add_library(luajit_static STATIC ${LUAJIT_CORE_C_SOURCES})
        _luajit_configure_target(luajit_static FALSE)

        add_custom_command(TARGET luajit_static POST_BUILD
            COMMAND lib.exe /nologo
                "$<TARGET_FILE:luajit_static>"
                "${LUAJIT_VM_SOURCE}"
                /OUT:"$<TARGET_FILE:luajit_static>"
            COMMENT "LuaJIT: merging lj_vm.obj into static lib"
        )
    else()
        add_library(luajit_static STATIC
            ${LUAJIT_VM_SOURCES}
            ${LUAJIT_CORE_C_SOURCES}
        )
        _luajit_configure_target(luajit_static FALSE)
    endif()

    set_target_properties(luajit_static PROPERTIES
        OUTPUT_NAME "lua51"
        PREFIX      "lib"
        POSITION_INDEPENDENT_CODE ON
    )
    add_library(luajit::static ALIAS luajit_static)
endif()

# ── Shared library (native only) ──────────────────────────────────────────────
if(LUAJIT_BUILD_SHARED AND NOT LUAJIT_TARGET_WASM)
    if(WIN32 AND LUAJIT_VM_SOURCE MATCHES "\\.obj$")
        # Mark lj_vm.obj as a pre-built object so CMake passes it straight to
        # the linker without trying to recompile it.
        set_source_files_properties("${LUAJIT_VM_SOURCE}" PROPERTIES
            EXTERNAL_OBJECT TRUE
            GENERATED TRUE)
        add_library(luajit_shared SHARED
            ${LUAJIT_CORE_C_SOURCES}
            "${LUAJIT_VM_SOURCE}"
        )
    else()
        add_library(luajit_shared SHARED
            ${LUAJIT_VM_SOURCES}
            ${LUAJIT_CORE_C_SOURCES}
        )
    endif()
    _luajit_configure_target(luajit_shared TRUE)

    set_target_properties(luajit_shared PROPERTIES
        OUTPUT_NAME "lua51"
        PREFIX      "lib"
        SOVERSION   "1"
        VERSION     "${PROJECT_VERSION}"
    )
    if(NOT WIN32 AND NOT APPLE AND LUAJIT_SHARED_LINKER_FLAGS)
        set_target_properties(luajit_shared PROPERTIES
            LINK_FLAGS "${LUAJIT_SHARED_LINKER_FLAGS}")
    endif()
    add_library(luajit::shared ALIAS luajit_shared)
endif()

# ── Emscripten WASM output ────────────────────────────────────────────────────
if(LUAJIT_TARGET_WASM)
    add_executable(luajit_wasm
        "${LUAJIT_SOURCE_DIR}/luajit_wasm_entry.c"
    )
    if(LUAJIT_BUILD_STATIC)
        target_link_libraries(luajit_wasm PRIVATE luajit_static)
    else()
        target_sources(luajit_wasm PRIVATE
            ${LUAJIT_VM_SOURCES}
            ${LUAJIT_CORE_C_SOURCES}
        )
        _luajit_configure_target(luajit_wasm FALSE)
    endif()
    set_target_properties(luajit_wasm PROPERTIES
        OUTPUT_NAME "luajit"
        SUFFIX      ".js"
    )
    foreach(_flag ${LUAJIT_EMSCRIPTEN_LINK_FLAGS})
        target_link_options(luajit_wasm PRIVATE "${_flag}")
    endforeach()
endif()

# ── Default alias ─────────────────────────────────────────────────────────────
if(LUAJIT_BUILD_STATIC)
    add_library(luajit::luajit ALIAS luajit_static)
elseif(LUAJIT_BUILD_SHARED AND NOT LUAJIT_TARGET_WASM)
    add_library(luajit::luajit ALIAS luajit_shared)
endif()
