#!/usr/bin/env python3
"""Compile real layout mismatches and require pchook in isolated Lua processes.

Artifacts stay in e2e/output/. Requires a C compiler and Lua 5.4/5.5 headers.
The negative cases change only cluacov's header, never the running VM's data.
"""
import argparse
import os
from pathlib import Path
import shlex
import shutil
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
    raise SystemExit("layout tests require Lua 5.4 or 5.5")
header_dir = "lua" + version[-3:].replace(".", "")
out = root / "e2e/output/state-layout" / header_dir

# Each mismatch must be rejected by the indicated check, not merely crash.
cases = {
    "matching": (None, None, ""),
    "allocator-offset": (
        "    lua_Alloc frealloc;\n    void *ud;",
        "    void *ud;\n    lua_Alloc frealloc;", "allocator/registry"),
    "registry-offset": (
        "    TValue l_registry;\n    TValue nilvalue;",
        "    TValue nilvalue;\n    TValue l_registry;", "allocator/registry"),
    "allgc-offset": (
        "    GCObject *allgc;",
        "    void *wrong_offset;\n    GCObject *allgc;", "thread/allgc"),
}
script = r'''local path, expected = arg[1], arg[2]
local calls = 0
local external = function() calls = calls + 1 end
local body = function() coroutine.yield(42); return 43 end
local co = coroutine.create(body)
debug.sethook(external, "l")
debug.sethook(co, external, "l")
local open = assert(package.loadlib(path, "luaopen_cluacov_pchook"))
local ok, result = pcall(open)
-- Module loading, including failure, must not take ownership of any hooks.
assert(debug.gethook() == external)
assert(debug.gethook(co) == external)
debug.sethook()
if expected ~= "" then
   assert(not ok, "mismatched header unexpectedly accepted")
   assert(tostring(result):find("incompatible Lua state layout", 1, true), tostring(result))
   assert(tostring(result):find(expected, 1, true), tostring(result))
   local before = calls
   assert(select(2, coroutine.resume(co)) == 42)
   assert(calls > before, "failed load damaged the coroutine hook")
else
   assert(ok, tostring(result))
   result.start()
   assert(select(2, coroutine.resume(co)) == 42)
   result.stop()
   local line = debug.getinfo(body, "S").linedefined
   assert((result.get_line_hits(body)[line] or 0) > 0, "matching layout did not collect coroutine hits")
   assert(debug.gethook(co) == nil)
end
debug.sethook(co)
assert(select(2, coroutine.resume(co)) == 43)
'''
compiler = shlex.split(os.environ.get("CC", "cc"))
flags = shlex.split(os.environ.get("CFLAGS", ""))
link = ["-bundle", "-undefined", "dynamic_lookup"] if sys.platform == "darwin" else ["-shared", "-fPIC"]
for name, (old, new, expected) in cases.items():
    case = out / name
    shutil.copytree(root / "src/cluacov", case, dirs_exist_ok=True)
    header = case / header_dir / "lstate_min.h"
    if old is not None:
        text = header.read_text()
        assert text.count(old) == 1, (name, "mutation target must be unique")
        header.write_text(text.replace(old, new))
    module = case / "pchook.so"
    subprocess.run(compiler + flags + link + ["-I" + args.include,
                   str(case / "pchook.c"), "-o", str(module)], check=True)
    test = case / "check.lua"
    test.write_text(script)
    subprocess.run([args.lua, str(test), str(module), expected], check=True)
    print(version + " " + name + ": passed", flush=True)
