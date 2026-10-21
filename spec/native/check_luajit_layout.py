#!/usr/bin/env python3
"""Reject real GC64 header mismatches before accessing any VM internals."""
import argparse
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--lua", default="lua")
parser.add_argument("--include", required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
out = root / "e2e/output/luajit-layout"
compiler = shlex.split(os.environ.get("CC", "cc"))
flags = shlex.split(os.environ.get("CFLAGS", ""))
link = ["-bundle", "-undefined", "dynamic_lookup"] if sys.platform == "darwin" else ["-shared", "-fPIC"]
probe = 'assert(jit); local f=assert(loadstring("return 1")); io.write(string.byte(string.dump(f),5)%16>=8 and "1" or "0")'
gc64 = int(subprocess.check_output([args.lua, "-e", probe], text=True))
script = r'''
local path, name, mismatch = arg[1], arg[2], arg[3] == "mismatch"
local jit_on = jit.status()
local external = function() end
debug.sethook(external, "l")
local open = assert(package.loadlib(path, "luaopen_cluacov_" .. name))
local ok, result = pcall(open)
assert(debug.gethook() == external, "module load replaced the debug hook")
assert(jit.status() == jit_on, "module load changed JIT state")
debug.sethook()
if mismatch then
   assert(not ok, "incompatible GC64 layout was accepted")
   assert(tostring(result):find("incompatible LuaJIT frame/GC64 layout", 1, true), tostring(result))
else
   assert(ok, tostring(result))
   local f = assert(loadstring("return function(x) if x then return 1 end return 2 end"))()
   if name == "pchook" then
      result.start(); assert(f(true) == 1); result.stop()
      assert(result.get_hits(f)[1].calls == 1)
   else assert(next(result.get(f)) ~= nil) end
end
'''
for case_name in ("matching", "mismatch"):
    case = out / case_name
    shutil.copytree(root / "src/cluacov", case, dirs_exist_ok=True)
    if case_name == "mismatch":
        for dirname in ("lj2", "luajit-2.1.0-beta3"):
            header = case / dirname / "lj_arch.h"
            text, count = re.subn(r"(#define LJ_GC64\s+)[01]", lambda m: m[1] + str(1 - gc64), header.read_text())
            assert count == 2
            header.write_text(text)
    test = case / "check.lua"
    test.write_text(script)
    for name in ("pchook", "deepbranches", "deepactivelines"):
        module = case / (name + ".so")
        subprocess.run(compiler + flags + link + ["-I" + args.include, str(case / (name + ".c")), "-o", str(module)], check=True)
        subprocess.run([args.lua, str(test), str(module), name, case_name], check=True)
        print(name + " " + case_name + ": passed", flush=True)

# A minimal host can load/analyze without opening the optional jit library.
# Starting must fail explicitly without guessing the initial engine state;
# opening the library afterwards allows the same collector to start normally.
minimal = r'''
local library = package.loaded.jit
package.loaded.jit = nil
local p = require "cluacov.pchook"
local b = require "cluacov.branchcov"
local f = assert(loadstring("return function(x) if x then return 1 end end"))()
assert(b.analyze(f).total > 0)
local enabled = library.status()
local ok, err = pcall(p.start)
assert(not ok and err:find("requires the jit library", 1, true), tostring(err))
assert(library.status() == enabled)
package.loaded.jit = library
p.start(); f(true); p.stop()
assert(p.get_hits(f)[1].calls == 1)
assert(library.status() == enabled)
'''
subprocess.run([args.lua, "-e", minimal], check=True)
print("load without jit library, then collect after opening it: passed", flush=True)
