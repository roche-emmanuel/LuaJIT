##############################################################################
# cmake/Install.cmake
#
# Standard install rules: headers, libraries, executable, jit/*.lua.
##############################################################################

include(GNUInstallDirs)

# ── Public headers ────────────────────────────────────────────────────────────
set(LUAJIT_PUBLIC_HEADERS
    "${LUAJIT_SOURCE_DIR}/lua.h"
    "${LUAJIT_SOURCE_DIR}/lualib.h"
    "${LUAJIT_SOURCE_DIR}/lauxlib.h"
    "${LUAJIT_SOURCE_DIR}/luaconf.h"
    "${LUAJIT_SOURCE_DIR}/lua.hpp"
    "${CMAKE_CURRENT_BINARY_DIR}/luajit.h"   # generated version header
)

install(FILES ${LUAJIT_PUBLIC_HEADERS}
    DESTINATION "${CMAKE_INSTALL_INCLUDEDIR}/luajit"
)

# ── Libraries ─────────────────────────────────────────────────────────────────
if(LUAJIT_BUILD_STATIC)
    install(TARGETS luajit_static
        ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}"
        LIBRARY DESTINATION "${CMAKE_INSTALL_LIBDIR}"
    )
endif()

if(LUAJIT_BUILD_SHARED AND NOT LUAJIT_TARGET_WASM)
    install(TARGETS luajit_shared
        RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}"    # .dll on Windows
        LIBRARY DESTINATION "${CMAKE_INSTALL_LIBDIR}"    # .so on Linux
        ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}"    # .lib import on Windows
    )
endif()

# ── WASM artifacts ────────────────────────────────────────────────────────────
if(LUAJIT_TARGET_WASM)
    install(FILES
        "${CMAKE_CURRENT_BINARY_DIR}/luajit.js"
        "${CMAKE_CURRENT_BINARY_DIR}/luajit.wasm"
        DESTINATION "${CMAKE_INSTALL_DATADIR}/luajit-wasm"
    )
endif()

# ── Executable ────────────────────────────────────────────────────────────────
if(LUAJIT_BUILD_EXECUTABLE AND NOT LUAJIT_TARGET_WASM)
    install(TARGETS luajit_exe
        RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}"
    )
endif()

# ── JIT Lua files ─────────────────────────────────────────────────────────────
set(LUAJIT_JIT_LUA_FILES
    "${LUAJIT_SOURCE_DIR}/jit/bc.lua"
    "${LUAJIT_SOURCE_DIR}/jit/bcsave.lua"
    "${LUAJIT_SOURCE_DIR}/jit/dump.lua"
    "${LUAJIT_SOURCE_DIR}/jit/p.lua"
    "${LUAJIT_SOURCE_DIR}/jit/v.lua"
    "${LUAJIT_SOURCE_DIR}/jit/zone.lua"
    "${LUAJIT_SOURCE_DIR}/jit/dis_x86.lua"
    "${LUAJIT_SOURCE_DIR}/jit/dis_x64.lua"
    "${LUAJIT_SOURCE_DIR}/jit/dis_arm.lua"
    "${LUAJIT_SOURCE_DIR}/jit/dis_arm64.lua"
    "${LUAJIT_SOURCE_DIR}/jit/dis_arm64be.lua"
    "${LUAJIT_SOURCE_DIR}/jit/dis_ppc.lua"
    "${LUAJIT_SOURCE_DIR}/jit/dis_mips.lua"
    "${LUAJIT_SOURCE_DIR}/jit/dis_mipsel.lua"
    "${LUAJIT_SOURCE_DIR}/jit/dis_mips64.lua"
    "${LUAJIT_SOURCE_DIR}/jit/dis_mips64el.lua"
    "${LUAJIT_SOURCE_DIR}/jit/dis_mips64r6.lua"
    "${LUAJIT_SOURCE_DIR}/jit/dis_mips64r6el.lua"
    "${CMAKE_CURRENT_BINARY_DIR}/jit/vmdef.lua"   # generated
)

install(FILES ${LUAJIT_JIT_LUA_FILES}
    DESTINATION "${CMAKE_INSTALL_DATADIR}/luajit-${PROJECT_VERSION}/jit"
)

# ── pkg-config ────────────────────────────────────────────────────────────────
if(NOT WIN32 AND NOT LUAJIT_TARGET_WASM)
    set(LUAJIT_PC_PREFIX    "${CMAKE_INSTALL_PREFIX}")
    set(LUAJIT_PC_VERSION   "${PROJECT_VERSION}")
    set(LUAJIT_PC_LIBDIR    "${CMAKE_INSTALL_FULL_LIBDIR}")
    set(LUAJIT_PC_INCDIR    "${CMAKE_INSTALL_FULL_INCLUDEDIR}/luajit")

    configure_file(
        "${CMAKE_CURRENT_SOURCE_DIR}/cmake/luajit.pc.in"
        "${CMAKE_CURRENT_BINARY_DIR}/luajit.pc"
        @ONLY
    )
    install(FILES "${CMAKE_CURRENT_BINARY_DIR}/luajit.pc"
        DESTINATION "${CMAKE_INSTALL_LIBDIR}/pkgconfig"
    )
endif()

# ── CMake package config (so find_package(LuaJIT) works) ─────────────────────
include(CMakePackageConfigHelpers)

configure_package_config_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/cmake/LuaJITConfig.cmake.in"
    "${CMAKE_CURRENT_BINARY_DIR}/cmake/LuaJITConfig.cmake"
    INSTALL_DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/LuaJIT"
)

write_basic_package_version_file(
    "${CMAKE_CURRENT_BINARY_DIR}/cmake/LuaJITConfigVersion.cmake"
    VERSION "${PROJECT_VERSION}"
    COMPATIBILITY SameMajorVersion
)

install(FILES
    "${CMAKE_CURRENT_BINARY_DIR}/cmake/LuaJITConfig.cmake"
    "${CMAKE_CURRENT_BINARY_DIR}/cmake/LuaJITConfigVersion.cmake"
    DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/LuaJIT"
)
