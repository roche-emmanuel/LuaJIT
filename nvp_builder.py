"""This module provides the builder for the LuaJIT library."""

import logging
import os

from nvp.core.build_manager import BuildManager
from nvp.nvp_builder import NVPBuilder

logger = logging.getLogger(__name__)


def register_builder(bman: BuildManager):
    """Register the build function"""
    bman.register_builder("LuaJIT", LuaJITBuilder(bman))


class LuaJITBuilder(NVPBuilder):
    """LuaJIT builder class — CMake-based for all platforms."""

    # Extra source files that live outside the upstream src/ tree and must be
    # copied in before CMake runs. Keys are source paths (relative to this
    # script's directory), values are destination paths relative to build_dir.
    _EXTRA_SOURCES = {
        "src_extras/lj_vm_wasm.c":        "src/lj_vm_wasm.c",
        "src_extras/luajit_wasm_entry.c": "src/luajit_wasm_entry.c",
    }

    # CMakeLists.txt + cmake/ directory to overlay onto the repo root.
    _CMAKE_ROOT = "."  # same directory as this script

    def _copy_cmake_overlay(self, build_dir):
        """Copy CMakeLists.txt and cmake/ into the build (repo) directory."""
        script_dir = os.path.dirname(os.path.abspath(__file__))

        # Root CMakeLists.txt
        src_cmake = os.path.join(script_dir, "CMakeLists.txt")
        dst_cmake = os.path.join(build_dir, "CMakeLists.txt")
        self.copy_file(src_cmake, dst_cmake)

        # cmake/ sub-directory
        src_cmake_dir = os.path.join(script_dir, "cmake")
        dst_cmake_dir = os.path.join(build_dir, "cmake")
        self.make_folder(dst_cmake_dir)
        for fname in os.listdir(src_cmake_dir):
            self.copy_file(
                os.path.join(src_cmake_dir, fname),
                os.path.join(dst_cmake_dir, fname),
            )

        # Extra source files (WASM stubs etc.)
        for rel_src, rel_dst in self._EXTRA_SOURCES.items():
            self.copy_file(
                os.path.join(script_dir, rel_src),
                os.path.join(build_dir, rel_dst),
            )

    def _run_cmake(self, build_dir, prefix, extra_defs=None, build_type="Release"):
        """Configure + build + install via CMake."""
        cmake_build_dir = os.path.join(build_dir, "_cmake_build")
        self.make_folder(cmake_build_dir)

        configure_cmd = [
            "cmake",
            "-B", cmake_build_dir,
            "-S", build_dir,
            f"-DCMAKE_BUILD_TYPE={build_type}",
            f"-DCMAKE_INSTALL_PREFIX={prefix}",
            "-DLUAJIT_ENABLE_LUA52COMPAT=ON",
        ]

        if extra_defs:
            configure_cmd += [f"-D{k}={v}" for k, v in extra_defs.items()]

        self.execute(configure_cmd, cwd=build_dir, env=self.env)
        self.execute(
            ["cmake", "--build", cmake_build_dir,
             "--config", build_type, "-j", str(os.cpu_count() or 4)],
            cwd=build_dir, env=self.env,
        )
        self.execute(
            ["cmake", "--install", cmake_build_dir, "--config", build_type],
            cwd=build_dir, env=self.env,
        )

    # ── Windows ──────────────────────────────────────────────────────────────
    def build_on_windows(self, build_dir, prefix, desc):
        """Build LuaJIT on Windows using CMake."""
        logger.debug("LuaJIT: building on Windows via CMake")

        self._copy_cmake_overlay(build_dir)

        extra = {}

        if self.compiler.is_clang():
            extra["CMAKE_C_COMPILER"] = "clang-cl"
            extra["CMAKE_LINKER"]     = "lld-link"

        # Static-only build mirrors the old msvcbuild.bat 'static' step.
        # If you also want the DLL, set LUAJIT_BUILD_SHARED=ON.
        extra["LUAJIT_BUILD_STATIC"]     = "ON"
        extra["LUAJIT_BUILD_SHARED"]     = "ON"
        extra["LUAJIT_BUILD_EXECUTABLE"] = "ON"

        self._run_cmake(build_dir, prefix, extra_defs=extra)

    # ── Linux ─────────────────────────────────────────────────────────────────
    def build_on_linux(self, build_dir, prefix, desc):
        """Build LuaJIT on Linux using CMake."""
        logger.debug("LuaJIT: building on Linux via CMake")

        self._copy_cmake_overlay(build_dir)

        extra = {}

        if self.compiler.is_emcc():
            logger.debug("LuaJIT: Emscripten target — WASM build")
            # emcmake wraps the cmake call; here we do it manually by pointing
            # at the Emscripten toolchain file.
            emscripten_root = os.environ.get("EMSDK", "")
            toolchain = os.path.join(
                emscripten_root, "upstream/emscripten/cmake/Modules/Platform/Emscripten.cmake"
            )
            if not os.path.exists(toolchain):
                # Fall back: let the user set CMAKE_TOOLCHAIN_FILE themselves
                logger.warning(
                    "EMSDK env var not set or Emscripten.cmake not found. "
                    "Set EMSDK or pass CMAKE_TOOLCHAIN_FILE manually."
                )
            else:
                extra["CMAKE_TOOLCHAIN_FILE"] = toolchain

            extra["LUAJIT_BUILD_EXECUTABLE"] = "OFF"
            extra["LUAJIT_BUILD_SHARED"]     = "OFF"
            extra["LUAJIT_DISABLE_FFI"]      = "ON"
            # LUAJIT_DISABLE_JIT defaults to ON for WASM in CMakeLists.txt

        elif self.compiler.is_clang():
            extra["CMAKE_C_COMPILER"]    = "clang"
            extra["CMAKE_CXX_COMPILER"]  = "clang++"
        else:
            # GCC or default
            pass

        self._run_cmake(build_dir, prefix, extra_defs=extra)

    # ── macOS ─────────────────────────────────────────────────────────────────
    def build_on_macos(self, build_dir, prefix, desc):
        """Build LuaJIT on macOS using CMake."""
        logger.debug("LuaJIT: building on macOS via CMake")

        self._copy_cmake_overlay(build_dir)

        min_ver = os.environ.get("MACOSX_DEPLOYMENT_TARGET", "11.0")
        extra = {
            "CMAKE_OSX_DEPLOYMENT_TARGET": min_ver,
        }
        if self.compiler.is_clang():
            extra["CMAKE_C_COMPILER"] = "clang"

        self._run_cmake(build_dir, prefix, extra_defs=extra)
