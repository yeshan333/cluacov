# Changelog

## Unreleased

### Added

- `cluacov.pchook` and `cluacov.branchcov` now support per-PC,
  instruction-level branch coverage on PUC-Rio Lua 5.4 and 5.5.
- Added runtime coverage / branch metadata tests plus end-to-end
  scenarios for branch coverage, line-hook coverage, runner shutdown,
  coroutine execution, multi-source aggregation, and tick-mode stats
  flushing.

### Bug fixes

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
