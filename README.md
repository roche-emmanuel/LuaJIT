# LuaJIT CMake Build System

Drop-in CMake overlay for the [LuaJIT v2.1](https://github.com/LuaJIT/LuaJIT) source tree.

## Layout

```
<luajit-repo>/
├── CMakeLists.txt          ← copy from here
├── cmake/
│   ├── HostTools.cmake
│   ├── TargetArch.cmake
│   ├── Sources.cmake
│   ├── RuntimeLib.cmake
│   ├── Executable.cmake
│   ├── Install.cmake
│   ├── luajit.pc.in
│   └── LuaJITConfig.cmake.in
└── src/
    ├── lj_vm_wasm.c        ← copy from src_extras/ (WASM only)
    └── luajit_wasm_entry.c ← copy from src_extras/ (WASM only)
```

## Native build (Linux / macOS)

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(nproc)
cmake --install build --prefix /usr/local
```

## Native build (Windows, MSVC)

```cmd
cmake -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Release
cmake --install build --prefix C:/luajit
```

## Native build (Windows, clang-cl)

```cmd
cmake -B build -G Ninja -DCMAKE_C_COMPILER=clang-cl
cmake --build build
```

## Emscripten / WASM build

```bash
# With emcmake (recommended — sets up all env vars automatically):
emcmake cmake -B build-wasm -DCMAKE_BUILD_TYPE=Release
cmake --build build-wasm

# Outputs: build-wasm/luajit.js + build-wasm/luajit.wasm
```

## Key CMake options

| Option | Default | Description |
|---|---|---|
| `LUAJIT_ENABLE_LUA52COMPAT` | `ON` | Enable Lua 5.2 compat features |
| `LUAJIT_DISABLE_FFI` | `OFF` | Disable FFI extension |
| `LUAJIT_DISABLE_JIT` | `OFF` (WASM: `ON`) | Disable JIT compiler |
| `LUAJIT_DISABLE_GC64` | `OFF` | Disable GC64 on x64 |
| `LUAJIT_USE_SYSMALLOC` | `OFF` | Use system malloc |
| `LUAJIT_BUILD_STATIC` | `ON` | Build static library |
| `LUAJIT_BUILD_SHARED` | `ON` (WASM: `OFF`) | Build shared library |
| `LUAJIT_BUILD_EXECUTABLE` | `ON` (WASM: `OFF`) | Build luajit CLI |

## Consuming in another CMake project

```cmake
find_package(LuaJIT REQUIRED)
target_link_libraries(myapp PRIVATE luajit::luajit)
```
