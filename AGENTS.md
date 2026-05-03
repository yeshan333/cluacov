# Repository Guidelines

## Project Structure & Module Organization

`src/cluacov/` contains the shipped Lua modules and C extensions. Core modules include `deepbranches.c`, `deepactivelines.c`, `hook.c`, `pchook.c`, `branchcov.lua`, `branchfilter.lua`, and `runner.lua`. Version-specific Lua and LuaJIT headers live under `src/cluacov/lua5*/` and `src/cluacov/lj*/`.

Unit tests are in `spec/*_spec.lua`. End-to-end coverage scenarios are in `e2e/`, with generated reports under `e2e/output/`. Documentation and diagrams live in `docs/`; benchmark tooling is in `bench/`. LuaRocks packaging is defined by `cluacov-dev-1.rockspec` and release rockspecs in `rockspecs/`.

## Build, Test, and Development Commands

- `mise install`: installs Lua 5.4.8 and 5.5.0 from `mise.toml`.
- `luarocks make`: builds the local rock and native C modules.
- `luarocks install busted busted-htest`: installs the test runner and CI formatter.
- `busted -o htest`: runs the unit test suite in the same format used by CI.
- `busted spec/pchook_spec.lua`: runs one focused spec file.
- `mise run test:all`: builds and runs unit tests on both Lua 5.4 and 5.5.
- `mise run e2e:54` / `mise run e2e:55`: builds into the repo-local tree and runs all e2e scenarios. The scripts auto-detect the current Lua version.
- `mise run check`: full build + unit + E2E on both versions.

Agents should follow the local instruction in `@/Users/yeshan333/.codex/RTK.md`: prefix shell commands with `rtk`, for example `rtk busted -o htest`.

## Coding Style & Naming Conventions

Lua code uses 3-space indentation and Busted-style `describe`/`it` blocks. Spec files are named `*_spec.lua` and usually start with `-- luacheck: std +busted`. Prefer module names under `cluacov.*` that match their file path, for example `src/cluacov/branchcov.lua` exposes `cluacov.branchcov`.

C sources should stay compatible with the Lua versions declared in the rockspec. Keep version-specific behavior isolated near the existing header/version checks.

## Testing Guidelines

Add or update Busted specs for Lua module and C extension behavior. Use focused e2e scripts when behavior depends on hook lifecycle, Lua VM instruction coverage, LCOV output, coroutine behavior, or shutdown/finalizer paths. CI tests Lua 5.1, 5.2, 5.3, 5.4, 5.5, and LuaJIT on Linux, macOS, and Windows, so avoid platform-specific assumptions.

## Commit & Pull Request Guidelines

Recent history uses Conventional Commit-style subjects such as `fix(pchook): ...`, `test(e2e): ...`, `docs(branch-coverage): ...`, and `feat(e2e): ...`. Keep commits scoped and mention `[skip ci]` only for documentation-only changes when appropriate.

Pull requests should describe the behavior change, list the Lua versions or scenarios tested, link related issues, and include screenshots or report paths when changing generated coverage HTML or diagrams.
