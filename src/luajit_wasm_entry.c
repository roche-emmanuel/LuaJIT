/*
** luajit_wasm_entry.c
**
** Emscripten "main" that just exports the Lua C API surface.
** The real entry points are the lua_* / luaL_* symbols exported via
** -sEXPORTED_FUNCTIONS in the CMake link flags.
**
** This file exists solely to give emcc a translation unit to link,
** which it needs to produce the .js + .wasm output pair.
** Copy this into the LuaJIT src/ directory.
*/

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

/* Emscripten calls main() at module load time. We do nothing here —
** the caller initialises a lua_State via luaL_newstate() from JS. */
int main(void) { return 0; }
