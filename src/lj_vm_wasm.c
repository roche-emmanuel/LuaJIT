/*
** lj_vm_wasm.c
**
** WASM/C replacement for the DynASM-generated lj_vm.S.
** Phase 0: stubs only — satisfies the linker so the build completes.
** Phase 1: replace lj_vm_call() with a full bytecode dispatch loop.
**
** Copy this into the LuaJIT src/ directory.
*/

#define lj_vm_c
#define LUA_CORE

#include "lj_obj.h"
#include "lj_vm.h"
#include "lj_err.h"
#include "lj_state.h"
#include "lj_frame.h"
#include "lj_dispatch.h"

/* ── VM entry points ─────────────────────────────────────────────────────── */

/* Execute a Lua function. Phase 1 will put the dispatch loop here. */
void LJ_FASTCALL lj_vm_call(lua_State *L, TValue *base, int nres1)
{
  UNUSED(base); UNUSED(nres1);
  lj_err_throw(L, LUA_ERRERR);   /* Phase 0 stub */
}

int LJ_FASTCALL lj_vm_pcall(lua_State *L, TValue *base, int nres1, ptrdiff_t ef)
{
  UNUSED(base); UNUSED(nres1); UNUSED(ef);
  return LUA_ERRERR;              /* Phase 0 stub */
}

int LJ_FASTCALL lj_vm_cpcall(lua_State *L, lua_CFunction f, void *ud,
                              lua_CPFunction cp)
{
  UNUSED(f); UNUSED(ud);
  return cp(L);
}

int LJ_FASTCALL lj_vm_resume(lua_State *L, TValue *base, int nres1,
                              ptrdiff_t ef)
{
  UNUSED(base); UNUSED(nres1); UNUSED(ef);
  return LUA_ERRERR;              /* Phase 0 stub */
}

/* ── Unwind helpers ──────────────────────────────────────────────────────── */

void LJ_FASTCALL lj_vm_unwind_c(void *cframe, int errcode)
{
  UNUSED(cframe); UNUSED(errcode);
}

void LJ_FASTCALL lj_vm_unwind_ff(void *cframe)
{
  UNUSED(cframe);
}

void LJ_FASTCALL lj_vm_unwind_c_eh(void)  {}
void LJ_FASTCALL lj_vm_unwind_ff_eh(void) {}
void LJ_FASTCALL lj_vm_unwind_rethrow(void) {}

/* ── Math helpers ────────────────────────────────────────────────────────── */

double lj_vm_foldarith(double x, double y, int op)
{
  UNUSED(op); return x + y;       /* Phase 0 stub */
}

double lj_vm_foldfpm(double x, int op)
{
  UNUSED(op); return x;           /* Phase 0 stub */
}

/* ── Cache sync (no-op on WASM) ─────────────────────────────────────────── */
void lj_vm_cachesync(void *start, void *end)
{
  UNUSED(start); UNUSED(end);
}
