#!/usr/bin/env python3
"""Coverage regression contracts for the collector and LCOV runner.

Build with `luarocks make --tree=.` for the selected Lua, then run this file
with that interpreter on PATH. Each case uses a fresh process and temporary
directory. Also runs against a globally installed rock in CI.
"""

import argparse
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
PREAMBLE = """
local load = loadstring or load
local pchook = require('cluacov.pchook')
local branchcov = require('cluacov.branchcov')
"""

LUA_CASES = [
    (
        "control_distinct_lines",
        "Functions on distinct lines retain their separate branch hits",
        """
local chunk = assert(load([[return function(x)
   if x then return 1 else return 2 end
end, function(x)
   if x then return 3 else return 4 end
end]], '@distinct.lua'))
local first, second = chunk()
pchook.start()
first(true)
second(false)
pchook.stop()
assert(branchcov.analyze(first).branches[1].status == 'partial')
assert(branchcov.analyze(second).branches[1].status == 'partial')
""",
    ),
    (
        "same_line_closures",
        "Independent functions on the same line retain separate branch hits",
        """
local chunk = assert(load('return function(x) if x then return 1 else return 2 end end, function(x) if x then return 3 else return 4 end end', '@same.lua'))
local first, second = chunk()
pchook.start()
first(true)
second(false)
pchook.stop()
local a = branchcov.analyze(first).branches[1]
local b = branchcov.analyze(second).branches[1]
assert(a.status == 'partial' and b.status == 'partial',
   'expected partial/partial; got ' .. a.status .. '/' .. b.status)
""",
    ),
    (
        "unreached_loop_branch",
        "A zero-iteration numeric loop leaves its unexecuted loop-back branch uncovered",
        """
local f = assert(load('return function(n) local sum=0; for i=1,n do sum=sum+i end; return sum end', '@loop.lua'))()
pchook.start()
assert(f(0) == 0)
pchook.stop()
local found = false
for _, branch in ipairs(branchcov.analyze(f).branches) do
   if branch.kind == 'loop' then
      found = true
      assert(branch.status == 'uncovered', 'expected uncovered; got ' .. branch.status)
   end
end
assert(found, 'fixture must contain a loop-back branch')
""",
    ),
    (
        "restart_retains_function_hits",
        "Restarting collection preserves earlier hits for a function not called again",
        """
local f = assert(load('return function(x) return x+1 end', '@restart.lua'))()
pchook.start()
f(1)
pchook.stop()
assert(pchook.get_hits(f)[1].hits[1] == 1)
pchook.start()
pchook.stop()
local count = pchook.get_hits(f)[1].hits[1] or 0
assert(count == 1, 'expected cumulative entry hits=1; got ' .. count)
""",
    ),
    (
        "stripped_bytecode_records",
        "Repeated calls to one stripped function reuse one coverage record",
        """
local f = assert(load('return function(x) return x+1 end'))()
local stripped = assert(load(string.dump(f, true)))
pchook.start()
for i=1,100 do stripped(i) end
pchook.stop()
-- The collector normalizes a stripped Proto's NULL source to "?".
local entries = pchook.get_all_hits()['?'] or {}
assert(#entries == 1, 'expected one record for one Proto; got ' .. #entries)
""",
    ),
    (
        "shared_target_edge_contract",
        "Taking only the true arm of an if without else does not cover the false edge",
        """
local f = assert(load('return function(x) local n=0; if x then n=1 end; return n end', '@merge.lua'))()
pchook.start()
f(true)
pchook.stop()
local branch = branchcov.analyze(f).branches[1]
assert(branch.status == 'partial', 'expected edge coverage partial; got ' .. branch.status)
""",
    ),
]

FORMS_SOURCE = """local M = {}
do
   function M.indented() return 1 end
end
M.assigned = function() return 2 end
function M:method() return 3 end
function M.normal() return 4 end
return M
"""

RUNNER_CASES = [
    (
        "ambiguous_preloaded_functions",
        "LCOV warns rather than assigning preloaded identical functions to arbitrary declarations",
        "local M={}; function M.first(x) if x then return 1 else return 2 end end; function M.second(x) if x then return 1 else return 2 end end; return M\n",
        "local m=require('sample'); require('cluacov.runner'); m.first(true)",
        "",
        {"report": "FNDA:0,first\nFNDA:0,second\nFNH:0\n", "stderr": "cannot be matched uniquely"},
    ),
    (
        "same_line_function_report",
        "LCOV distinguishes identical same-line functions when only one is called",
        "local M={}; function M.first(x) if x then return 1 else return 2 end end; function M.second(x) if x then return 1 else return 2 end end; return M\n",
        "require('cluacov.runner'); require('sample').first(true)",
        "",
        "FNDA:1,first\nFNDA:0,second\nFNH:1\n",
    ),
    (
        "same_line_branch_report",
        "LCOV keeps opposite outcomes in two same-line functions partially covered",
        "local M={}; function M.first(x) if x then return 1 else return 2 end end; function M.second(x) if x then return 1 else return 2 end end; return M\n",
        "require('cluacov.runner'); local m=require('sample'); m.first(true); m.second(false)",
        "",
        "BRF:4\nBRH:2\n",
    ),
    (
        "reloaded_function_calls",
        "Reloading the same file accumulates actual function calls across all copies",
        "local M={}\nfunction M.spin(n) while n>0 do n=n-1 end end\nreturn M\n",
        "require('cluacov.runner'); for i=1,3 do local m=dofile('sample.lua'); m.spin(4) end",
        "",
        "FNDA:3,spin\n",
    ),
    (
        "long_strings_are_not_functions",
        "Function-like text in quoted and long strings does not add LCOV functions",
        "local a=[==[\nfunction phantom() end\n]==]\nlocal b='function fake() end'\nreturn a..b\n",
        "require('cluacov.runner'); require('sample')",
        "",
        "FNF:0\n",
    ),
    (
        "colon_method_report",
        "Colon methods have distinct names and independent call counts in LCOV",
        "local M={}\nfunction M:first() return 1 end\nfunction M:second() return 2 end\nreturn M\n",
        "require('cluacov.runner'); require('sample'):second()",
        "",
        "FNDA:0,first\nFNDA:1,second\nFNH:1\n",
    ),
    (
        "tick_tail_after_save",
        "Natural exit flushes function calls made after the last tick-mode save",
        "local M={}\nfunction M.last() return 1 end\nreturn M\n",
        "local r=require('cluacov.runner'); local m=require('sample'); r.save_stats(); m.last()",
        "tick=true, savestepsize=1000000,",
        "FNDA:1,last\n",
    ),
    (
        "loop_at_function_entry",
        "A function beginning with a loop reports one call after three iterations",
        "local M={}\nfunction M.spin(n)\n   while n > 0 do\n      n = n - 1\n   end\nend\nreturn M\n",
        "require('cluacov.runner'); require('sample').spin(3)",
        "",
        "FNDA:1,spin\n",
    ),
    (
        "function_declaration_forms",
        "LCOV includes indented declarations, assigned functions, and colon methods",
        FORMS_SOURCE,
        "require('cluacov.runner'); local m=require('sample'); m.indented(); m.assigned(); m:method(); m.normal()",
        "",
        "FNF:4\n",
    ),
    (
        "comment_is_not_function",
        "Function-like text inside a long comment does not create an LCOV function",
        "--[[\nfunction ghost()\nend\n]]\nreturn true\n",
        "require('cluacov.runner'); require('sample')",
        "",
        "FNF:0\n",
    ),
    (
        "late_start_uncalled_lines",
        "Starting after module load still lists the later uncalled function body as DA zero",
        "local M={}\nfunction M.first()\n   return 1\nend\nfunction M.last()\n   return 2\nend\nreturn M\n",
        "local m=require('sample'); require('cluacov.runner'); m.first()",
        "",
        "DA:6,0\n",
    ),
    (
        "tick_natural_exit",
        "Tick mode flushes coverage on normal exit before the first save interval",
        "return function() return 1 end\n",
        "require('cluacov.runner'); require('sample')()",
        "tick=true, savestepsize=1000000,",
        "end_of_record\n",
    ),
]


def run_lua(lua, env, directory, code):
    script = directory / "driver.lua"
    script.write_text(code, encoding="utf-8")
    result = subprocess.run(
        [lua, str(script)], cwd=directory, env=env,
        text=True, capture_output=True, timeout=30,
    )
    if result.returncode != 0:
        raise AssertionError(
            f"Lua exited {result.returncode}:\n{result.stdout}{result.stderr}"
        )
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lua", default="lua", help="Lua executable (5.4, 5.5, or LuaJIT 2.1)")
    parser.add_argument("--module-dir", type=Path, help="Override compiled module directory (e.g. sanitizer build)")
    parser.add_argument("--preload", help="LD_PRELOAD for Lua children, without instrumenting the Python driver")
    parser.add_argument("--case", help="Run just one case by its identifier")
    args = parser.parse_args()
    version = subprocess.check_output(
        [args.lua, "-e", "io.write(jit and 'luajit' or _VERSION:match('%d+%.%d+'))"], text=True,
    )
    if version not in ("5.4", "5.5", "luajit"):
        parser.error("these contracts require Lua 5.4, 5.5, or LuaJIT 2.1")

    # Absolute paths also work in subprocesses whose cwd is a fixture directory.
    env = os.environ.copy()
    if args.preload:
        env["LD_PRELOAD"] = args.preload
    env["LUA_PATH"] = str(ROOT / "src/?.lua") + ";" + env.get("LUA_PATH", ";;")
    native = (args.module_dir or ROOT / "lib/lua" / ("5.1" if version == "luajit" else version)).resolve()
    env["LUA_CPATH"] = (
        str(native / "?.so") + ";" + str(native / "?.dll") + ";"
        + env.get("LUA_CPATH", ";;")
    )
    # Lua's version-specific environment variables override the generic ones.
    suffix = version.replace(".", "_")
    env.pop("LUA_PATH_" + suffix, None)
    env.pop("LUA_CPATH_" + suffix, None)

    cases = [(case, False) for case in LUA_CASES]
    cases += [(case, True) for case in RUNNER_CASES]
    if args.case:
        cases = [(case, runner) for case, runner in cases if case[0] == args.case]
        if not cases:
            parser.error("unknown case: " + args.case)

    failed = 0
    print(f"Coverage contracts on Lua {version}", flush=True)
    for case, runner in cases:
        identifier, title = case[:2]
        try:
            with tempfile.TemporaryDirectory(prefix="coverage_review_") as temp:
                directory = Path(temp)
                if runner:
                    source, driver, config, expected = case[2:]
                    (directory / "sample.lua").write_text(source, encoding="utf-8")
                    configfile = directory / ".luacov"
                    configfile.write_text(
                        "return {include={'sample$'}," + config + "}", encoding="utf-8"
                    )
                    runner_env = dict(env, LUACOV_CONFIG=str(configfile))
                    result = run_lua(args.lua, runner_env, directory, driver)
                    reportfile = directory / "lcov.info"
                    if not reportfile.exists():
                        raise AssertionError("normal exit=0, but lcov.info was not written")
                    report = reportfile.read_text(encoding="utf-8")
                    if isinstance(expected, dict):
                        if expected["stderr"] not in result.stderr:
                            raise AssertionError(f"missing diagnostic {expected['stderr']!r}: {result.stderr}")
                        expected = expected["report"]
                    if expected not in report:
                        raise AssertionError(f"missing {expected.strip()!r}; actual LCOV:\n{report}")
                else:
                    run_lua(args.lua, env, directory, PREAMBLE + case[2])
            print(f"PASS [{identifier}] {title}", flush=True)
        except (AssertionError, subprocess.TimeoutExpired) as error:
            failed += 1
            print(f"FAIL [{identifier}] {title}\n{error}", flush=True)
    print(f"{len(cases) - failed} passed / {failed} unmet contracts", flush=True)
    return int(failed > 0)


if __name__ == "__main__":
    raise SystemExit(main())
