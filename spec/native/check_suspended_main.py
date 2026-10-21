#!/usr/bin/env python3
"""Close a Lua state while its lua_resume-driven main thread is suspended.

Hosts such as ltask resume the main thread of each state. If cluacov hooks
that thread, Lua 5.4 aborts every __gc finalizer at lua_close, so the runner
never writes its report. Artifacts stay in e2e/output/. Requires a C compiler
and Lua 5.4/5.5 headers; the helper takes the Lua API from the interpreter.
"""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--lua", default="lua")
parser.add_argument("--include", required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
version = subprocess.check_output(
    [args.lua, "-e", "io.write(_VERSION)"], text=True
).strip()
if version not in ("Lua 5.4", "Lua 5.5"):
    raise SystemExit("suspended main thread test requires Lua 5.4 or 5.5")
out = root / "e2e/output/suspended-main" / version[-3:]
out.mkdir(parents=True, exist_ok=True)

host = r'''#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

static int finalized;

static int mark(lua_State *L) {
    (void)L;
    finalized++;
    return 0;
}

/* Run a chunk on the main thread of a new state, then close it suspended. */
static int run(lua_State *L) {
    const char *chunk = luaL_checkstring(L, 1);
    const char *pchook = luaL_checkstring(L, 2);
    lua_State *S = luaL_newstate();
    int nres, status;

    luaL_openlibs(S);
    lua_pushcfunction(S, mark);
    lua_setglobal(S, "mark");
    status = luaL_loadfile(S, chunk);
    if (status == LUA_OK) {
        lua_pushstring(S, pchook);
        status = lua_resume(S, NULL, 1, &nres);
    }
    if (status != LUA_YIELD) {
        lua_pushstring(L, lua_tostring(S, -1));
        lua_close(S);
        return lua_error(L);
    }
    lua_pushboolean(L, lua_toboolean(S, -1));
    finalized = 0;
    lua_close(S);
    lua_pushinteger(L, finalized);
    lua_insert(L, -2);
    return 2;
}

int luaopen_suspended_main(lua_State *L) {
    lua_pushcfunction(L, run);
    return 1;
}
'''
chunk = r'''local pchook = assert(package.loadlib(..., "luaopen_cluacov_pchook"))()
-- A Lua finalizer: Lua 5.4 only checks the suspended status while executing Lua code.
local anchor = setmetatable({}, { __gc = function() mark() end })
coroutine.wrap(pchook.start)()
-- Report whether the suspended main thread keeps cluacov's hook.
coroutine.yield(debug.gethook() ~= nil)
'''
check = r'''local helper, chunk = arg[1], arg[2]
local pchook = assert(package.searchpath("cluacov.pchook", package.cpath))
local run = assert(package.loadlib(helper, "luaopen_suspended_main"))()
local finalized, hooked = run(chunk, pchook)
assert(finalized == 1, "finalizers ran: " .. finalized .. ", want 1")
-- Only Lua 5.4 aborts finalizers, so only there the main thread stays unhooked.
assert(hooked == (_VERSION ~= "Lua 5.4"), "main thread hooked: " .. tostring(hooked))
'''
(out / "host.c").write_text(host)
(out / "chunk.lua").write_text(chunk)
(out / "check.lua").write_text(check)
compiler = shlex.split(os.environ.get("CC", "cc"))
flags = shlex.split(os.environ.get("CFLAGS", ""))
link = ["-bundle", "-undefined", "dynamic_lookup"] if sys.platform == "darwin" else ["-shared", "-fPIC"]
module = out / "suspended_main.so"
subprocess.run(compiler + flags + link + ["-I" + args.include,
               str(out / "host.c"), "-o", str(module)], check=True)
subprocess.run([args.lua, str(out / "check.lua"), str(module), str(out / "chunk.lua")], check=True)
print(version + " suspended main thread: passed", flush=True)
