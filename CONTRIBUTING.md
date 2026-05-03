# Contributing to cluacov

## Prerequisites

- [mise](https://mise.jdx.dev/) -- manages the Lua toolchain
- A C compiler (gcc / clang)

Install the default Lua version and a second version for dual-version testing:

```sh
mise install              # installs Lua 5.4.8 (from mise.toml)
mise install lua@5.5.0    # install Lua 5.5 as secondary
```

## Build

```sh
luarocks make                          # build C extensions + install Lua modules
luarocks install busted busted-htest   # test runner + CI formatter
```

## Running Tests

### Single-version (default Lua 5.4)

```sh
busted                    # all unit tests
busted spec/pchook_spec.lua   # single spec file
```

### Dual-version testing

CI tests Lua 5.1 through 5.5 and LuaJIT. Before pushing, verify at
least the two PC-hook-capable versions (5.4 and 5.5) locally:

**Lua 5.4 (default)**

```sh
luarocks make cluacov-dev-1.rockspec
busted
```

**Lua 5.5**

```sh
MISE_LUA_VERSION=5.5.0 mise exec -- luarocks make cluacov-dev-1.rockspec
MISE_LUA_VERSION=5.5.0 mise exec -- busted
```

`MISE_LUA_VERSION` temporarily overrides the Lua binary, luarocks tree,
and PATH so that the child `lua` processes spawned by runner_spec also
use the correct version.

### End-to-end tests

E2E scripts auto-detect the current Lua version; no `--lua-version`
flag is needed:

```sh
# Lua 5.4
luarocks make cluacov-dev-1.rockspec --tree=.
./e2e/run_all.sh

# Lua 5.5
MISE_LUA_VERSION=5.5.0 mise exec -- luarocks make cluacov-dev-1.rockspec --tree=.
MISE_LUA_VERSION=5.5.0 mise exec -- ./e2e/run_all.sh
```

### Quick checklist before pushing

1. `busted` -- 109+ tests pass on Lua 5.4
2. `MISE_LUA_VERSION=5.5.0 mise exec -- busted` -- same tests pass on 5.5
3. `./e2e/run_all.sh` -- 7/7 E2E scenarios pass on at least one version

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
