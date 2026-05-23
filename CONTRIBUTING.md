# Contributing to cluacov

## Prerequisites

- [mise](https://mise.jdx.dev/) -- manages the Lua toolchain
- A C compiler (gcc / clang)

Install both Lua versions (declared in `mise.toml`):

```sh
mise install    # installs Lua 5.4.8 + 5.5.0
```

## Build

```sh
luarocks make                          # build C extensions + install Lua modules
luarocks install busted busted-htest   # test runner + CI formatter
```

## Running Tests

### mise tasks (recommended)

`mise.toml` defines tasks for dual-version build, test, and E2E:

```sh
mise run test:54    # build + unit tests on Lua 5.4
mise run test:55    # build + unit tests on Lua 5.5
mise run test:all   # both versions

mise run e2e:54     # build local tree + E2E on Lua 5.4
mise run e2e:55     # build local tree + E2E on Lua 5.5
mise run e2e:all    # both versions

mise run check      # full: unit + E2E on both versions

mise run asan:54    # build + unit + E2E under ASan/UBSan/LSan on Lua 5.4
mise run asan:55    # build + unit + E2E under ASan/UBSan/LSan on Lua 5.5
mise run asan:all   # both versions
```

### Manual commands

If you prefer running commands directly:

```sh
# Lua 5.4 (default)
busted                        # unit tests
busted spec/pchook_spec.lua   # single spec file

# Lua 5.5
MISE_LUA_VERSION=5.5.0 mise exec -- busted
```

### End-to-end tests

E2E scripts auto-detect the current Lua version:

```sh
# Lua 5.4
luarocks make cluacov-dev-1.rockspec --tree=.
./e2e/run_all.sh

# Lua 5.5
MISE_LUA_VERSION=5.5.0 mise exec -- luarocks make cluacov-dev-1.rockspec --tree=.
MISE_LUA_VERSION=5.5.0 mise exec -- ./e2e/run_all.sh
```

### AddressSanitizer / LeakSanitizer (Linux + gcc only)

`mise run asan:54` / `asan:55` rebuild the C extensions with
`-fsanitize=address,undefined`, `LD_PRELOAD` libasan, and run the full
unit + E2E suite under ASan/UBSan/LSan. Use these to catch
use-after-free, out-of-bounds reads/writes, UB, and leaks in the C
code (`pchook.c`, `hook.c`, `deepbranches.c`, `deepactivelines.c`).

```sh
mise run asan:54    # one Lua version
mise run asan:all   # both 5.4 and 5.5
```

What runs:
1. `spec/asan_lsan_canary.sh` — a 64-byte deliberate-leak canary that
   asserts LSan is actually live in this environment (a clean cluacov
   run with broken LSan would be a silent false negative).
2. `luarocks make ... --tree=.` — rebuild C extensions with sanitizer
   flags into the local tree.
3. `busted` — full unit test suite under ASan.
4. `./e2e/run_all.sh` — all E2E scenarios under ASan.

Subprocess noise: `LD_PRELOAD` propagates to children spawned via
`io.popen` / `os.execute` (gcc, bash, sort). Their own at-exit leaks
are filtered by `spec/asan_lsan_suppressions.txt`, which uses path-
and frame-based patterns that never match cluacov code.

Platform: requires Linux + gcc (the rules use `gcc -print-file-name=libasan.so`
to locate the runtime). Set `ASAN_LIB=...` to override.

ASan options: `halt_on_error=1` (default) is REQUIRED — with
`halt_on_error=0`, ASan and LSan print error reports but the process
still exits 0, so a real leak in `pchook.c` would print stderr noise
while the suite reports green. The mise tasks set
`abort_on_error=0` (orderly exit, no SIGABRT) but leave
`halt_on_error` at its default 1.

Footgun: after an ASan run, the local-tree `.so` files in
`./lib/lua/<ver>/cluacov/` are sanitizer-instrumented. Loading them
without `LD_PRELOAD=libasan.so` aborts with
`==N==ASan runtime does not come first in initial library list`.
Re-run any of the `mise run e2e:54` / `e2e:55` / `test:54` / `test:55`
tasks to overwrite the local tree with non-instrumented builds.

CI: `.github/workflows/asan.yml` runs the equivalent of `mise run asan:55`
on every push/PR (canary + sanitized build + busted + e2e on Lua 5.5).
This is the regression guard against memory-safety bugs in the C
extensions. If you change ASan flags / options / suppressions in
`mise.toml`, mirror the change in that workflow.

### Quick checklist before pushing

1. `mise run test:all` -- 109+ tests pass on both 5.4 and 5.5
2. `mise run e2e:54` or `mise run e2e:55` -- 7/7 E2E scenarios pass
3. `mise run asan:54` (Linux + gcc) -- canary passes and the suite
   runs clean under ASan/UBSan/LSan

## Coding Style

- Lua: 3-space indentation, Busted `describe`/`it` blocks
- C: stay compatible with Lua versions in the rockspec; isolate
  version-specific code near existing `#if` guards
- Spec files: name as `*_spec.lua`, start with `-- luacheck: std +busted`

## Commit Messages

Use Conventional Commit-style subjects:

```
fix(pchook): correct DA aggregation across proto instances
test(e2e): add tick-mode branch coverage scenario
docs(branch-coverage): update LCOV format notes
feat(runner): add BRDA ghost-hit suppression
```

Use `[skip ci]` only for documentation-only changes.
