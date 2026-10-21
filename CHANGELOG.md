# Changelog

## Unreleased

### Added

- Add LuaJIT 2.1 instruction-level branch, function, and line coverage via
  `cluacov.runner`, including compiled-before-start code, specialized iterators,
  recursive calls, and coroutines. Collection pauses JIT and restores its prior
  state on stop; finalizer shutdown still writes reports.
- Run the shared regression contracts and LuaJIT-specific scenarios in CI,
  including the sanitizer workflow.

- `cluacov.pchook` and `cluacov.branchcov` now support per-PC,
  instruction-level branch coverage on PUC-Rio Lua 5.4 and 5.5.
- Added runtime coverage / branch metadata tests plus end-to-end
  scenarios for branch coverage, line-hook coverage, runner shutdown,
  coroutine execution, multi-source aggregation, and tick-mode stats
  flushing.

### Bug fixes

- Keep independent same-line functions separate with a GC-managed Proto index;
  stripped bytecode reuses its records, and stop/start preserves per-function
  queries without another call. Function entries are counted with call events.
- Track branch edges within each invocation, including generic iterators' fused
  first iteration; shared targets no longer give skipped paths false coverage.
- Build LCOV function records from the full Proto tree, include assigned,
  indented, method and anonymous functions, and ignore function-like comments
  and strings. Preserve uncovered lines after late collection starts.
- Flush tick-mode reports on normal exit, including runs shorter than one tick.

- `cluacov.pchook`: on Lua 5.4, `start()` called from a coroutine no longer
  hooks a main thread driven by `lua_resume` (for example under ltask). When the
  state was closed while that thread was suspended, Lua 5.4 aborted every
  `__gc` finalizer, so the runner never wrote its stats or LCOV report.
- `cluacov.pchook`: validate allocator, registry, and GC-list head layout at
  module load and reject detected mismatches before traversing threads.

- `cluacov.pchook`: collect execution in coroutines created or suspended
  before `start()`, including existing `coroutine.wrap` closures and their
  child coroutines. Stop collection on all threads before caching reports,
  so resuming a coroutine after `stop()` cannot change recorded hits.
- `cluacov.pchook`: avoid a shutdown-time segmentation fault by
  materializing `Proto` metadata into Lua tables instead of keeping
  raw C pointers alive into `__gc` finalization paths.
- `.luacov` parsing now supports bare-assignment config files and
  merges user `include` / `exclude` patterns with the default
  exclusions instead of replacing them.
- `cluacov.pchook`: function-body first executable line now reports
  correct hit counts in `pchook.get_line_hits` (and therefore in any
  LCOV report built from it). Previously, statements like
  `local t = obj.field` at the top of a function — and the first
  statement inside an `if`-block, and the closing `end` of `for`
  loops — consistently showed `hits = 0` while the next line absorbed
  the missing hits. Root cause: `collect_line_hits_recursive` was
  reading the hits-table key as the executed instruction's PC, but
  by Lua's interpreter convention the key is the **next**
  instruction's PC. Affects PUC-Rio Lua 5.4 and 5.5. Per-PC branch
  coverage (`branchcov.lua`, `pchook.get_hits`) is intentionally left
  unchanged: it correctly relies on the next-instruction-PC contract.
  See `docs/bugs/2026-05-02-savedpc-off-by-one.md` for the full
  post-mortem.

### Documentation

- Clarify that `pchook.start()` overwrites existing debug hooks and `stop()`
  does not restore them; concurrent hook-based tools can cause missed coverage.

- Expanded the branch-coverage guide, benchmark documentation, and
  contributor-facing repository guidance.
- README installation now documents building from a local checkout via
  `luarocks make`.

## Releasing new versions

- update changelog below
- verify copyright years in `LICENSE`, and when adding new Lua versions, update the license details
- create a new rockspec file
- update version constant in `src/cluacov/version.lua`
- push updates to a new branche `release/x.x.x` and create a PR
- after merging, tag the commit with the new version and push the tag
- upload to LuaRocks should be automatic through the deploy workflow, after the tag is pushed

## 1.0.0 (2026-02-06)

Added Lua 5.5 compatibility.

## 0.1.4 (2024-08-27)

Updated LuaJIT embedded header to luajit-2.1 rolling release code
and Lua 5.4 embedded source to Lua 5.4.7.

## 0.1.3 (2024-05-14)

Updated LuaJIT and Lua 5.4 embedded sources.

## 0.1.2 (2020-08-20)

Lua 5.4 support.

## 0.1.1 (2018-05-05)

Updated dependency on luacov to 0.13.0.

## 0.1.0 (2016-06-29)

Initial release.
