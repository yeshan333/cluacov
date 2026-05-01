# SEGV on `__gc` finalizer when reading per-PC stats after `lua_close`

- **Component**: `src/cluacov/pchook.c` (per-PC instruction-level branch coverage, Lua 5.4+)
- **Affected versions**: `dev-1` (since the per-PC mode landed in #2)
- **Reporter**: `examples/` integration with `busted` + `luacov` runner on
  macOS (Apple Silicon) / Lua 5.4.8
- **Status**: Fixed
- **Severity**: Crash (SIGBUS / SIGSEGV at process exit)

---

## 1. Symptom

Any program that loads `cluacov.runner` and lets the Lua state shut down
naturally crashes with a SIGBUS / SIGSEGV at process teardown:

```sh
$ lua -e 'require("cluacov.runner"); print(require("mylib").inc(1))'
2
zsh: segmentation fault  lua -e ...
$ echo $?
139
```

Same crash when running tests through `busted`, because `busted` exits via
the natural end of the main chunk (no explicit `os.exit`):

```text
==> [2/4] 运行 busted 单元测试
run_test.sh: line 40: 41814 Segmentation fault: 11     busted busted_demo.spec.lua
```

Adding `os.exit(0)` at the end of the script avoids the crash, which already
narrows the trigger to **VM teardown**, not normal execution.

---

## 2. Reproducer

Smallest possible reproducer (no busted needed):

```lua
-- repro.lua
require("cluacov.runner")
local m = require("mylib")     -- any pure-Lua module
print(m.inc(1))
```

```sh
lua repro.lua && echo OK || echo "exit=$?"
# => exit=139
```

`lldb` backtrace at the crash site (before the fix):

```text
* thread #1, queue = 'com.apple.main-thread',
  stop reason = EXC_BAD_ACCESS (code=1, address=0x...)
  * frame #0: lua`lua_rawgetp + ...
    frame #1: pchook.so`l_get_all_line_hits + ...
    frame #2: lua`luaD_precall + ...
    frame #3: lua`GCTM + ...                     <-- finalizer
    frame #4: lua`luaC_freeallobjects + ...      <-- close phase
    frame #5: lua`close_state + ...
    frame #6: lua`main + ...
```

The crash always happens **inside `luaC_freeallobjects`**, in a `__gc`
metamethod, calling back into `pchook.so`.

---

## 3. Root Cause

`cluacov.runner` registers an exit hook through the classic Lua idiom of
attaching a `__gc` metamethod to a sentinel userdata (e.g. via `newproxy`
in 5.1 or `setmetatable({}, { __gc = on_exit })` in 5.2+):

```lua
-- pseudo-code, abridged from runner.lua
local sentinel = newproxy(true)
getmetatable(sentinel).__gc = function() pchook.stop(); luacov.save() end
```

Lua runs that finalizer during **`luaC_freeallobjects`** — i.e. *after*
`lua_close` has already started tearing the state down. By the time the
finalizer fires:

1. All `Proto` objects (function prototypes) have been freed or are on the
   verge of being freed.
2. `TString` objects backing `proto->source` may already be invalid.
3. The arrays `proto->code` / `proto->lineinfo` / `proto->abslineinfo` are
   no longer guaranteed to be live.

The original implementation of `pchook.c` stored hits keyed by `Proto*`
light userdata:

```c
// before fix
PCHOOK[(void*)proto] = { [pc1based] = count, ... }
```

…and **derived everything else on demand** from the live Proto in the
report-time helpers:

- `get_source_name(proto)` → `getstr(proto->source)`
- `proto->linedefined`, `proto->sizecode`
- `luaG_getfuncline(proto, pc)` (which reads `proto->lineinfo`)

When `l_stop` / `l_get_all_*` was invoked **from inside the `__gc`
finalizer**, every one of those reads was a use-after-free → SIGBUS on
Apple Silicon, SIGSEGV on x86_64.

The bug had been latent for any caller that always ended the process via
`os.exit`, but it became reliable as soon as a real test runner (busted)
let the main chunk return.

---

## 4. Fix — Materialize all Proto metadata up front

The structural fix is to **stop relying on `Proto*` after the hook fires**.
Instead of using `Proto*` as the table key, we now use a Lua-managed
auto-incrementing **entry id**, and each entry carries a **deep copy of
everything we will ever need at report time**:

```c
// new layout, registry table PCHOOK_KEY:
//
//   PCHOOK[entry_id] = {
//     source       = "<copy of getstr(proto->source) as a Lua string>",
//     linedefined  = <int>,
//     sizecode     = <int>,
//     lines        = { [pc1based] = line, ... },  -- pre-resolved PC->line
//     hits         = { [pc1based] = count, ... }, -- written by the hook
//   }
//
// PROTO_INDEX[(void*)proto] = entry_id        -- only used while hook is live
```

Key properties of the new design:

- **The PCHOOK entries are 100 % Lua-managed data.** They contain only
  Lua strings, integers and tables. Once an entry exists, reading it is
  safe at any time — including inside `__gc` finalizers.
- **`PROTO_INDEX` is dropped at `l_stop`.** It is the only structure that
  ever held a `Proto*`, and we explicitly `nil` it out as the very first
  thing `l_stop` does, so nothing in the codebase can dereference a
  Proto after the hook is gone.
- **Per-PC `lines` is pre-resolved.** We call `luaG_getfuncline` for every
  PC at materialization time (which is the very first time the hook sees
  the Proto, *while it is still alive*). Report time then becomes a pure
  table lookup.
- **Aggregators use absolute stack indices.** `l_get_all_hits` and
  `l_get_all_line_hits` were rewritten to walk `PCHOOK[1..n]` with
  absolute indices throughout, eliminating a class of bugs where inner
  pushes/pops invalidate relative indices.
- **Snapshot caches.** `l_get_all_*` cache their results in
  `SNAPSHOT_*_KEY`, so repeated calls during shutdown are O(1).

### Hook fast-path

```c
// pc_hook on LUA_HOOKCOUNT, abridged
proto = get_proto(L, ...);
push_hits_for_proto(L, proto);     // creates entry on first sight
hits[pc1based] += 1;
```

`push_hits_for_proto` either reuses an existing `entry_id` from
`PROTO_INDEX`, or calls `materialize_proto_entry` exactly once per Proto.
This keeps the hot path at O(1) amortized while paying the
materialization cost lazily.

### Report path

`l_get_all_hits` / `l_get_all_line_hits` walk `PCHOOK[1..n]` and read
`source` / `linedefined` / `sizecode` / `lines` / `hits` as plain Lua
values. They never touch any `Proto*` — guaranteed safe from `__gc`.

### Per-function `l_get_hits` / `l_get_line_hits`

These take a Lua function as an argument, so by definition the caller
holds a live reference to the Proto chain. They still walk `proto->p[]`
recursively for nested protos, but look up hits via
`find_entry_id_for_proto(L, proto)` → `PCHOOK[entry_id].hits`. If the
Proto was never seen by the hook, an empty `hits` table is returned (no
crash).

---

## 5. Verification

### 5.1 Smallest reproducer no longer crashes

```sh
$ lua -e 'require("cluacov.runner"); print(require("mylib").inc(1))' \
   && echo OK || echo "exit=$?"
2
OK
```

### 5.2 End-to-end `busted` run produces lcov with branch coverage

From `aone-ci-component/lua-busted/examples/`:

```text
==> [2/4] 运行 busted 单元测试
        - 通过 .busted 中的 helper=spec_helper.lua 预加载 cluacov.runner
        - 启用 cluacov per-PC 指令级分支覆盖（Lua 5.4+）

Summary coverage rate:
  source files: 2
  lines.......: 84.9% (62 of 73 lines)
  functions...: 84.6% (11 of 13 functions)
  branches....: 34.4% (11 of 32 branches)
```

`lcov.info` contains the expected `BRDA`/`BRF`/`BRH` records and
`genhtml` renders branches correctly.

### 5.3 Tested on

| OS              | Arch    | Lua    | Outcome  |
|-----------------|---------|--------|----------|
| macOS 14 (Sonoma) | arm64 | 5.4.8 | ✅ pass |

`focal` Docker images (Lua 5.4.6 / 5.4.7, x86_64) are expected to behave
identically because the codepath is platform-independent — the Apple
Silicon `__gc`-during-shutdown ordering only made the bug *reliably*
reproducible, but the use-after-free was always present.

---

## 6. Lessons & Guidelines

1. **Never store raw `Proto*` (or any other GC-managed pointer) in C
   code that may be read from finalizers.** Light userdata pointers are
   not roots; they do not keep their target alive, and the target may
   already be gone when the finalizer runs.
2. **Materialize at write time, not at read time.** The hook always runs
   while the Proto is alive. Pay the small cost of copying once into Lua
   tables; any future reader (including GC finalizers) is then trivially
   safe.
3. **Drop pointer-keyed lookups as early as possible.** `l_stop` now
   `nil`s `PROTO_INDEX_KEY` immediately after `lua_sethook(NULL)`, so
   any later code path that would have tried to use a Proto* simply
   can't.
4. **Prefer absolute stack indices in non-trivial Lua C glue.** Relative
   indices like `-3` are a footgun whenever inner calls push/pop. The
   first attempt at the rewrite crashed exactly because of this, even
   though the underlying data was already safe.
5. **Test the shutdown path explicitly.** A missing `os.exit(0)` was the
   only difference between “works” and “SEGV”. CI should exercise the
   natural-exit path (e.g. via a real test runner like `busted`) and not
   only direct script invocations that happen to call `os.exit`.

---

## 7. Related Files

- `src/cluacov/pchook.c` — implementation of all of the above
- `src/cluacov/runner.lua` — the `__gc` finalizer that originally
  exposed the bug (left unchanged; the fix is structural in C)
- `examples/` in [aone-ci-component/lua-busted](https://code.alibaba-inc.com/aone-ci-component/lua-busted)
  — end-to-end reproducer with `busted` and `lcov` reports
