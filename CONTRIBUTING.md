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

### Quick checklist before pushing

1. `mise run test:all` -- 109+ tests pass on both 5.4 and 5.5
2. `mise run e2e:54` or `mise run e2e:55` -- 7/7 E2E scenarios pass

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
