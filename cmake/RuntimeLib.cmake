##############################################################################
# cmake/RuntimeLib.cmake
#
# Defines luajit_static, luajit_shared (native), and luajit_wasm targets.
##############################################################################

# ── Helper: apply common settings to any library/exe target ──────────────────
function(_luajit_configure_target TGT)
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

    if(WIN32 AND NOT LUAJIT_TARGET_WASM)
        target_compile_definitions("${TGT}" PRIVATE LUA_BUILD_AS_DLL)
    endif()

    if(MSVC)
        set_property(TARGET "${TGT}" PROPERTY
            MSVC_RUNTIME_LIBRARY
            "MultiThreaded$<$<CONFIG:Debug>:Debug>")
    endif()
endfunction()

# ── On Windows the VM is a pre-built .obj from buildvm (peobj mode) ──────────
# CMake cannot "compile" a .obj; we must pass it as a linker input.
# We do this by wrapping it in an OBJECT library that just carries the file.
set(_VM_OBJECT_LIB "")
if(WIN32 AND NOT LUAJIT_TARGET_WASM AND LUAJIT_VM_SOURCE MATCHES "\\.obj$")
    # Dummy C file so the OBJECT library has at least one compilable source
    set(_vm_dummy "${CMAKE_CURRENT_BINARY_DIR}/lj_vm_dummy.c")
    file(WRITE "${_vm_dummy}" "/* placeholder */\n")

    add_library(_luajit_vm_obj OBJECT "${_vm_dummy}")
    # Attach the pre-built .obj as an extra link input to anything that links
    # this object library. We'll handle it via target_sources OBJECT form below.
    set(_VM_OBJECT_LIB "$<TARGET_OBJECTS:_luajit_vm_obj>")
    set(_VM_EXTRA_LINK "${LUAJIT_VM_SOURCE}")
else()
    set(_VM_EXTRA_LINK "")
endif()

# ── Static library ────────────────────────────────────────────────────────────
if(LUAJIT_BUILD_STATIC)
    if(WIN32 AND NOT LUAJIT_TARGET_WASM AND LUAJIT_VM_SOURCE MATCHES "\\.obj$")
        # On Windows: compile all C sources into the static lib, then manually
        # add the pre-built lj_vm.obj via a custom post-build step that
        # calls lib.exe to merge it in.
        add_library(luajit_static STATIC ${LUAJIT_CORE_C_SOURCES})
        _luajit_configure_target(luajit_static)

        # Merge lj_vm.obj into the .lib after it is built
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
        _luajit_configure_target(luajit_static)
    endif()

    set_target_properties(luajit_static PROPERTIES
        OUTPUT_NAME "lua51"        # match upstream naming (lua51.lib / libluajit.a)
        PREFIX      "lib"
        POSITION_INDEPENDENT_CODE ON
    )
    add_library(luajit::static ALIAS luajit_static)
endif()

# ── Shared library (native only) ──────────────────────────────────────────────
if(LUAJIT_BUILD_SHARED AND NOT LUAJIT_TARGET_WASM)
    if(WIN32 AND LUAJIT_VM_SOURCE MATCHES "\\.obj$")
        add_library(luajit_shared SHARED ${LUAJIT_CORE_C_SOURCES})
        _luajit_configure_target(luajit_shared)
        # Link lj_vm.obj directly — MSVC linker accepts raw .obj files
        target_link_options(luajit_shared PRIVATE "${LUAJIT_VM_SOURCE}")
    else()
        add_library(luajit_shared SHARED
            ${LUAJIT_VM_SOURCES}
            ${LUAJIT_CORE_C_SOURCES}
        )
        _luajit_configure_target(luajit_shared)
    endif()

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
        # compile everything directly into the executable
        target_sources(luajit_wasm PRIVATE
            ${LUAJIT_VM_SOURCES}
            ${LUAJIT_CORE_C_SOURCES}
        )
        _luajit_configure_target(luajit_wasm)
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
