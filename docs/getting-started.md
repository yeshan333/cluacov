# Getting Started with cluacov

A practical guide to adding cluacov coverage to your Lua project.

## Installation

```sh
luarocks install cluacov
```

cluacov depends on [LuaCov](https://github.com/lunarmodules/luacov), so a
single command installs both.

## Two Modes of Operation

cluacov offers two coverage collection modes. Choose based on your Lua version
and coverage needs:

| Mode | Lua version | Granularity | Setup effort |
|---|---|---|---|
| **Line-level** (classic) | 5.1–5.5, LuaJIT | Per source line | Minimal |
| **Per-instruction** (new) | 5.4+ only | Per bytecode instruction | Minimal |

---

## Mode 1: Line-Level Coverage (All Lua Versions)

This is the simplest approach and works everywhere cluacov runs.

### Step 1: Run your code under LuaCov

```sh
lua -lluacov your_program.lua
```

Or add `require("luacov")` as the first line of your entry script.

This produces `luacov.stats.out` in the current directory.

### Step 2: Generate line coverage report

```sh
luacov
genhtml luacov.info --output-directory html-coverage
```

### Step 3: Add branch coverage (optional)

If you want branch coverage in your LCOV reports:

```lua
-- generate_lcov.lua
local deepbranches = require("cluacov.deepbranches")
local deepactivelines = require("cluacov.deepactivelines")
local branchfilter = require("cluacov.branchfilter")
local deepanalyze = require("cluacov.deepanalyze")

local stats = require("luacov.stats")
local data = stats.loadstats()
local lcov_fd = assert(io.open("coverage.lcov", "w"))

for filename, filedata in pairs(data) do
   local func = loadfile(filename)
   if func then
      local branches = deepbranches.get(func)
      local active_lines = deepactivelines.get(func)
      branches = branchfilter.filter(branches, filename, filedata)

      lcov_fd:write("SF:", filename, "\n")
      -- ... write DA, BRDA records using deepanalyze.write_lcov_branch_data
   end
end

lcov_fd:close()
```

See [branch-coverage.md](branch-coverage.md) for the full API reference and a
complete working example in `e2e/e2e_branch_coverage.lua`.

---

## Mode 2: Per-Instruction Coverage (Lua 5.4+ Only)

This mode uses `cluacov.pchook` to count every bytecode instruction, giving
true per-PC branch coverage. No filtering is needed — `if a or b or c` shows
all 3 TEST instructions independently.

### Quick Start

The easiest way is to use `cluacov.runner`, which handles everything:

```sh
# Run your program with the runner preloaded
lua -lcluacov.runner your_program.lua
```

That's it. When your program exits, `cluacov.runner` automatically writes:

- `luacov.stats.out` — line hit data (LuaCov-compatible)
- `lcov.info` — LCOV with line + branch records

### Configuration

Create a `.luacov` file in your project root:

```lua
return {
   statsfile = "luacov.stats.out",   -- LuaCov stats output
   lcovfile = "luacov.info",         -- LCOV output
   tick = false,                      -- set true for periodic saves
   savestepsize = 100,                -- save every N steps when tick=true
   include = { "myproject$" },        -- only track these patterns
   exclude = {
      "luacov$", "luacov%.",
      "cluacov%.", "cluacov/",
      "test$", "test%.",
      "spec$", "spec%.",
   },
}
```

### Tick Mode for Long-Running Processes

When `tick = true`, stats are saved periodically (every `savestepsize` line
events). This is useful for long-running services or when you want intermediate
snapshots:

```lua
return {
   tick = true,
   savestepsize = 1000,
   -- optional: custom save function
   save_stats = function()
      -- called every savestepsize line events
   end,
}
```

Note: with tick mode, no GC finalizer anchor is created. Use `pchook.stop()`
explicitly to trigger the final save.

### Generate HTML Report

```sh
genhtml lcov.info --output-directory html-coverage --branch-coverage
```

### Manual API Usage

If you prefer to control the lifecycle yourself:

```lua
local pchook = require("cluacov.pchook")
local branchcov = require("cluacov.branchcov")

-- Start collecting per-instruction hits
pchook.start()

-- ... run your code under test ...

local func = loadfile("your_module.lua")
pchook.stop()

-- Get per-PC hit data
local all_hits = pchook.get_hits(func)

-- Get branch coverage analysis
local branch_result = branchcov.analyze(func)
for _, branch in ipairs(branch_result.branches) do
   print(string.format("Line %d [%s]:", branch.line, branch.status))
   for _, target in ipairs(branch.targets) do
      print(string.format("  PC %d (line %d): %d hits",
         target.pc, target.line, target.hits))
   end
end

-- Get line hits (derived from PC data)
local line_hits = pchook.get_line_hits(func)

-- Reset and collect again (hook keeps running)
pchook.reset()
```

See [branch-coverage.md](branch-coverage.md) for the full `pchook` and
`branchcov` API reference.

---

## Integration Patterns

### With Busted

```sh
# Option 1: preload runner
busted --lua 'lua -lcluacov.runner'

# Option 2: require in spec helper
# spec/spec_helper.lua
require("cluacov.runner")

# Then run normally
busted
```

### With a Custom Test Runner

```lua
-- run_tests.lua
require("cluacov.runner")

-- load and run your test suite
require("test_suite")

-- runner handles cleanup on exit automatically
```

### CI Integration (GitHub Actions)

```yaml
- name: Install cluacov
  run: luarocks install cluacov

- name: Run tests with coverage
  run: lua -lcluacov.runner run_tests.lua

- name: Generate HTML report
  run: |
    sudo apt-get install -y lcov
    genhtml lcov.info --output-directory coverage-html --branch-coverage

- name: Upload coverage
  uses: actions/upload-artifact@v4
  with:
    name: coverage-report
    path: coverage-html/
```

---

## Troubleshooting

### "pchook requires PUC-Rio Lua 5.4 or later"

You're running Lua 5.1–5.3 or LuaJIT. Use Mode 1 (line-level) instead, or
upgrade to Lua 5.4+.

### No branch data in LCOV report

Make sure you're using Lua 5.4+ and the runner is preloaded (`-lcluacov.runner`)
or `cluacov.runner` is required before your code runs.

### Coverage shows 0% for some files

Check your `.luacov` `include`/`exclude` patterns. The default excludes
`luacov`, `cluacov`, `busted`, `luassert`, `say`, and `pl` modules.

### Slow test execution

Per-instruction hooks fire on every VM instruction, which is significantly
slower than line-level hooks. This is expected. For CI, the overhead is usually
acceptable. For local iteration, you may prefer to run without coverage and
only enable it for CI.

### `get_hits` returns empty data

The function passed to `pchook.get_hits(func)` must be the **same object**
that was executed while the hook was active. The hook keys data by `Proto*`
pointer, so a different `loadfile` call will produce a different pointer.

---

## Further Reading

- [Branch Coverage Guide](branch-coverage.md) — detailed API reference and
  LCOV format specification
- [Architecture Overview](../README.md#architecture) — how the two modes differ
  internally
- `e2e/e2e_branch_coverage.lua` — a complete working example
