##############################################################################
# cmake/Executable.cmake
#
# Builds the luajit CLI executable (native builds only).
##############################################################################

add_executable(luajit_exe "${LUAJIT_SOURCE_DIR}/luajit.c")

set_target_properties(luajit_exe PROPERTIES
    OUTPUT_NAME "luajit"
)

if(LUAJIT_BUILD_STATIC)
    target_link_libraries(luajit_exe PRIVATE luajit_static)
elseif(LUAJIT_BUILD_SHARED)
    target_link_libraries(luajit_exe PRIVATE luajit_shared)
endif()

target_include_directories(luajit_exe PRIVATE
    "${LUAJIT_SOURCE_DIR}"
    "${CMAKE_CURRENT_BINARY_DIR}"
)

if(MSVC)
    set_property(TARGET luajit_exe PROPERTY
        MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()

if(NOT WIN32 AND NOT APPLE AND LUAJIT_EXE_LINKER_FLAGS)
    set_target_properties(luajit_exe PROPERTIES
        LINK_FLAGS "${LUAJIT_EXE_LINKER_FLAGS}")
endif()
