##############################################################################
# cmake/Sources.cmake
#
# Defines LUAJIT_CORE_SOURCES — the full list of .c and .S files that go
# into libluajit, conditioned on platform and feature flags.
##############################################################################

set(_S "${LUAJIT_SOURCE_DIR}")  # shorthand

# ── VM entry points ───────────────────────────────────────────────────────────
# Native: the assembled lj_vm.S / lj_vm.obj produced by buildvm.
# WASM:   lj_vm_wasm.c (portable C interpreter stub, grows into full interp).
if(LUAJIT_TARGET_WASM)
    set(LUAJIT_VM_SOURCES "${_S}/lj_vm_wasm.c")
else()
    set(LUAJIT_VM_SOURCES "${LUAJIT_VM_SOURCE}")   # set by HostTools.cmake
endif()

# ── Core C sources ────────────────────────────────────────────────────────────
set(LUAJIT_CORE_C_SOURCES
    # Assertions / base
    "${_S}/lj_assert.c"
    # GC
    "${_S}/lj_gc.c"
    # Error handling
    "${_S}/lj_err.c"
    # Char classification
    "${_S}/lj_char.c"
    # Bytecode
    "${_S}/lj_bc.c"
    # Object model
    "${_S}/lj_obj.c"
    # Buffer
    "${_S}/lj_buf.c"
    # Strings
    "${_S}/lj_str.c"
    # Tables
    "${_S}/lj_tab.c"
    # Functions / closures
    "${_S}/lj_func.c"
    # Userdata
    "${_S}/lj_udata.c"
    # Metamethods
    "${_S}/lj_meta.c"
    # Debug
    "${_S}/lj_debug.c"
    # PRNG
    "${_S}/lj_prng.c"
    # State
    "${_S}/lj_state.c"
    # Dispatch table
    "${_S}/lj_dispatch.c"
    # VM events
    "${_S}/lj_vmevent.c"
    # VM math helpers
    "${_S}/lj_vmmath.c"
    # String scanning
    "${_S}/lj_strscan.c"
    # String formatting
    "${_S}/lj_strfmt.c"
    "${_S}/lj_strfmt_num.c"
    # Serialization
    "${_S}/lj_serialize.c"
    # Public API
    "${_S}/lj_api.c"
    # Lexer / parser / bytecode
    "${_S}/lj_lex.c"
    "${_S}/lj_parse.c"
    "${_S}/lj_bcread.c"
    "${_S}/lj_bcwrite.c"
    "${_S}/lj_load.c"
    # IR (always included — used even when JIT is disabled for IR type info)
    "${_S}/lj_ir.c"
    # Optimisers (guarded by LJ_HASJIT inside each file)
    "${_S}/lj_opt_mem.c"
    "${_S}/lj_opt_fold.c"
    "${_S}/lj_opt_narrow.c"
    "${_S}/lj_opt_dce.c"
    "${_S}/lj_opt_loop.c"
    "${_S}/lj_opt_split.c"
    "${_S}/lj_opt_sink.c"
    # MCode management (guarded by LJ_HASJIT)
    "${_S}/lj_mcode.c"
    # Snapshots
    "${_S}/lj_snap.c"
    # Trace recorder
    "${_S}/lj_record.c"
    "${_S}/lj_crecord.c"
    "${_S}/lj_ffrecord.c"
    # Assembler backend (guarded by LJ_HASJIT; picks arch via #include)
    "${_S}/lj_asm.c"
    # Trace management
    "${_S}/lj_trace.c"
    # GDB JIT interface (no-op when LUAJIT_USE_GDBJIT not set)
    "${_S}/lj_gdbjit.c"
    # Allocator
    "${_S}/lj_alloc.c"
    # Library helpers
    "${_S}/lj_lib.c"
    # Standard libraries
    "${_S}/lib_aux.c"
    "${_S}/lib_base.c"
    "${_S}/lib_math.c"
    "${_S}/lib_bit.c"
    "${_S}/lib_string.c"
    "${_S}/lib_table.c"
    "${_S}/lib_io.c"
    "${_S}/lib_os.c"
    "${_S}/lib_package.c"
    "${_S}/lib_debug.c"
    "${_S}/lib_jit.c"
    "${_S}/lib_buffer.c"
    "${_S}/lib_init.c"
)

# ── FFI sources (conditionally included) ─────────────────────────────────────
if(NOT LUAJIT_DISABLE_FFI AND NOT LUAJIT_TARGET_WASM)
    list(APPEND LUAJIT_CORE_C_SOURCES
        "${_S}/lj_ctype.c"
        "${_S}/lj_cdata.c"
        "${_S}/lj_cconv.c"
        "${_S}/lj_ccall.c"
        "${_S}/lj_ccallback.c"
        "${_S}/lj_carith.c"
        "${_S}/lj_clib.c"
        "${_S}/lj_cparse.c"
        "${_S}/lib_ffi.c"
    )
endif()

# ── Profiler (not available on WASM — uses setitimer/SIGPROF) ────────────────
if(NOT LUAJIT_TARGET_WASM)
    list(APPEND LUAJIT_CORE_C_SOURCES "${_S}/lj_profile.c")
endif()

# ── Full source list for the library ─────────────────────────────────────────
set(LUAJIT_ALL_SOURCES
    ${LUAJIT_VM_SOURCES}
    ${LUAJIT_CORE_C_SOURCES}
)
