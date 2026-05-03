#include "lua.h"
#include "lauxlib.h"

#if LUA_VERSION_NUM > 501 || defined(LUAI_BITSINT)
#define PUCRIOLUA
#endif

#if defined(PUCRIOLUA) && LUA_VERSION_NUM >= 504

#if LUA_VERSION_NUM == 504
#include "lua54/lobject.h"
#include "lua54/lstate_min.h"
#elif LUA_VERSION_NUM == 505
#include "lua55/lobject.h"
#include "lua55/lstate_min.h"
#else
#error "pchook: unsupported Lua version (need 5.4+)"
#endif

/*
 * Registry keys.
 *
 *   PCHOOK_KEY        : array-style table, keyed by 1-based entry id.
 *                       Each entry is a Lua table with the materialized
 *                       per-Proto metadata + per-PC hit counts:
 *                         { source       = string,   -- copy of getstr(proto->source)
 *                           linedefined  = integer,
 *                           sizecode     = integer,
 *                           lines        = { [pc] = line, ... }, -- 0-based pc
 *                           hits         = { [pc] = count, ... } } -- 0-based pc
 *
 *                       NOTE: PC keys are 0-based, matching the historical
 *                       wire format used by deepbranches and branchcov.
 *                       Do NOT change to 1-based without auditing every
 *                       reader (cluacov.branchcov, runner.lua, tests).
 *                       After build, this table no longer references any
 *                       Proto* pointer, so it remains safe to read even
 *                       inside __gc finalizers.
 *
 *   PROTO_INDEX_KEY   : weak-ish lookup table (Proto* lightuserdata -> entry id).
 *                       Used by the runtime hook to amortize the metadata
 *                       materialization to once per Proto. Cleared by
 *                       l_reset / l_start so stale entries from a previous
 *                       run cannot leak into a fresh collection.
 *
 *   TICK_KEY          : optional tick-mode config table.
 *
 *   SNAPSHOT_*_KEY    : caches built by l_stop (or first call to a getter
 *                       after stop), so subsequent calls are O(1).
 */
static char PCHOOK_KEY;
static char PROTO_INDEX_KEY;
static char TICK_KEY;
static char SNAPSHOT_LINE_HITS_KEY;
static char SNAPSHOT_ALL_HITS_KEY;

static Proto *get_proto(lua_State *L, int idx) {
    return ((Closure *) lua_topointer(L, idx))->l.p;
}

#define ABSLINEINFO (-0x80)

#if !defined(MAXIWTHABS)
#define MAXIWTHABS 128
#endif

static int getbaseline(const Proto *f, int pc, int *basepc) {
    if (f->sizeabslineinfo == 0 || pc < f->abslineinfo[0].pc) {
        *basepc = -1;
        return f->linedefined;
    } else {
        int i = cast_uint(pc) / MAXIWTHABS - 1;
        while (i + 1 < f->sizeabslineinfo && pc >= f->abslineinfo[i + 1].pc) {
            i++;
        }
        *basepc = f->abslineinfo[i].pc;
        return f->abslineinfo[i].line;
    }
}

static int luaG_getfuncline(const Proto *f, int pc) {
    if (f->lineinfo == NULL) {
        return -1;
    } else {
        int basepc;
        int baseline = getbaseline(f, pc, &basepc);
        while (basepc++ < pc) {
            baseline += f->lineinfo[basepc];
        }
        return baseline;
    }
}

static int get_pc_line(const Proto *proto, int pc) {
    if (pc < 0 || pc >= proto->sizecode) {
        return 0;
    }
    return luaG_getfuncline(proto, pc);
}

static const char *get_source_name(const Proto *proto) {
    if (proto->source == NULL) return NULL;
    return getstr(proto->source);
}

/*
 * Materialize per-Proto metadata into a fresh Lua table on top of the stack.
 *
 * Layout of the returned table (top of stack on return):
 *   { source       = string,    -- copy of getstr(proto->source) (or "?")
 *     linedefined  = integer,
 *     sizecode     = integer,
 *     lines        = { [pc] = line, ... },  -- pre-resolved 0-based PC -> line
 *     hits         = {},                    -- 0-based PC -> count, populated by hook
 *   }
 *
 * After this call, the entry table holds NO Proto* references and is therefore
 * safe to read from any context, including __gc finalizers run during
 * lua_close()/luaC_freeallobjects.
 */
static void materialize_proto_entry(lua_State *L, const Proto *proto) {
    const char *source;
    int pc;

    lua_createtable(L, 0, 5);

    source = get_source_name(proto);
    if (source == NULL) {
        lua_pushliteral(L, "?");
    } else {
        lua_pushstring(L, source);   /* makes a Lua-managed copy */
    }
    lua_setfield(L, -2, "source");

    lua_pushinteger(L, proto->linedefined);
    lua_setfield(L, -2, "linedefined");

    lua_pushinteger(L, proto->lastlinedefined);
    lua_setfield(L, -2, "lastlinedefined");

    lua_pushinteger(L, proto->sizecode);
    lua_setfield(L, -2, "sizecode");

    /* Pre-resolve PC -> line. PC keys are 0-based to match deepbranches /
       branchcov, which key off the raw bytecode PC. */
    lua_createtable(L, proto->sizecode, 0);
    for (pc = 0; pc < proto->sizecode; pc++) {
        int line = get_pc_line(proto, pc);
        if (line > 0) {
            lua_pushinteger(L, line);
            lua_rawseti(L, -2, pc);
        }
    }
    lua_setfield(L, -2, "lines");

    lua_createtable(L, 0, 0);
    lua_setfield(L, -2, "hits");
}

/*
 * Look up (or create) the entry-id for the given Proto* in PROTO_INDEX_KEY,
 * also ensuring PCHOOK_KEY[entry_id] holds the materialized entry table.
 *
 * On return: pushes the entry's `hits` subtable on the stack (top), and
 * returns nothing. Caller is responsible for popping the hits table.
 *
 * Returns 0 on success, non-zero if PCHOOK_KEY/PROTO_INDEX_KEY are missing
 * (in which case nothing extra is pushed).
 */
static int push_hits_for_proto(lua_State *L, const Proto *proto) {
    lua_Integer entry_id;
    int pchook_idx, index_idx;

    lua_rawgetp(L, LUA_REGISTRYINDEX, &PCHOOK_KEY);
    if (lua_isnil(L, -1)) { lua_pop(L, 1); return 1; }
    pchook_idx = lua_gettop(L);

    lua_rawgetp(L, LUA_REGISTRYINDEX, &PROTO_INDEX_KEY);
    if (lua_isnil(L, -1)) { lua_pop(L, 2); return 1; }
    index_idx = lua_gettop(L);

    /* PROTO_INDEX_KEY[Proto*] -> entry_id (or nil if first time). */
    lua_rawgetp(L, index_idx, (const void *)proto);
    entry_id = lua_tointeger(L, -1);
    lua_pop(L, 1);

    if (entry_id == 0) {
        /* First time we see this Proto: append a fresh entry. */
        entry_id = (lua_Integer)lua_rawlen(L, pchook_idx) + 1;
        materialize_proto_entry(L, proto);            /* push entry table */
        lua_rawseti(L, pchook_idx, entry_id);          /* PCHOOK[entry_id] = entry */

        lua_pushinteger(L, entry_id);
        lua_rawsetp(L, index_idx, (const void *)proto); /* INDEX[Proto*] = entry_id */
    }

    /* Fetch entry, then its hits subtable. */
    lua_rawgeti(L, pchook_idx, entry_id);              /* push entry */
    lua_getfield(L, -1, "hits");                       /* push hits */
    lua_remove(L, -2);                                 /* drop entry, keep hits */

    lua_remove(L, index_idx);                          /* drop PROTO_INDEX_KEY */
    lua_remove(L, pchook_idx);                         /* drop PCHOOK_KEY */
    return 0;
}

static void pc_hook(lua_State *L, lua_Debug *ar) {
    /* Handle tick on line events. */
    if (ar->event == LUA_HOOKLINE) {
        lua_rawgetp(L, LUA_REGISTRYINDEX, &TICK_KEY);
        if (!lua_isnil(L, -1)) {
            lua_Integer steps, savestepsize;

            lua_getfield(L, -1, "savestepsize");
            savestepsize = lua_tointeger(L, -1);
            lua_pop(L, 1);

            lua_getfield(L, -1, "steps");
            steps = lua_tointeger(L, -1) + 1;
            lua_pop(L, 1);

            if (steps >= savestepsize) {
                steps = 0;
                lua_getfield(L, -1, "save_stats");
                lua_call(L, 0, 0);
            }

            lua_pushinteger(L, steps);
            lua_setfield(L, -2, "steps");
        }
        lua_pop(L, 1);
        return;
    }

    /* Handle PC tracking on count events. */
    Proto *proto;
    CallInfo *ci;
    int pc;
    lua_Integer count;

    lua_getinfo(L, "f", ar);

    if (lua_iscfunction(L, -1)) {
        lua_pop(L, 1);
        return;
    }

    proto = get_proto(L, -1);
    lua_pop(L, 1);

    ci = (CallInfo *)ar->i_ci;
    pc = (int)(ci->u.l.savedpc - proto->code);

    if (push_hits_for_proto(L, proto) != 0) {
        return;
    }

    /* Stack top: hits subtable. 0-based PC keys match deepbranches/branchcov. */
    lua_rawgeti(L, -1, pc);
    count = lua_tointeger(L, -1) + 1;
    lua_pop(L, 1);
    lua_pushinteger(L, count);
    lua_rawseti(L, -2, pc);

    lua_pop(L, 1);
}

static int l_get_all_line_hits(lua_State *L);
static int l_get_all_hits(lua_State *L);
static void aggregate_all_hits(lua_State *L, int result_idx);
static void aggregate_all_line_hits(lua_State *L, int result_idx);

static int l_start(lua_State *L) {
    int mask;

    /* Clear stale snapshots from previous stop(). */
    lua_pushnil(L);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &SNAPSHOT_LINE_HITS_KEY);
    lua_pushnil(L);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &SNAPSHOT_ALL_HITS_KEY);

    /* Ensure PCHOOK_KEY (array of entries) exists. */
    lua_rawgetp(L, LUA_REGISTRYINDEX, &PCHOOK_KEY);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_rawsetp(L, LUA_REGISTRYINDEX, &PCHOOK_KEY);
    } else {
        lua_pop(L, 1);
    }

    /* PROTO_INDEX_KEY (Proto* lightuserdata -> entry id) MUST be re-created
       on every start(): light-userdata identity is meaningful only while the
       Proto is alive, and Lua may reuse the same address for a fresh Proto
       across collections. Stale mappings would lead the hook to attribute
       hits to the wrong entry. */
    lua_newtable(L);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &PROTO_INDEX_KEY);

    mask = LUA_MASKCOUNT;

    if (!lua_isnoneornil(L, 1)) {
        luaL_checktype(L, 1, LUA_TTABLE);

        /* Validate savestepsize. */
        lua_getfield(L, 1, "savestepsize");
        if (lua_isnil(L, -1) || lua_tointeger(L, -1) < 1) {
            lua_pop(L, 1);
            return luaL_error(L,
                "tick config requires savestepsize >= 1");
        }
        lua_pop(L, 1);

        /* Validate save_stats is a function. */
        lua_getfield(L, 1, "save_stats");
        if (!lua_isfunction(L, -1)) {
            lua_pop(L, 1);
            return luaL_error(L,
                "tick config requires save_stats to be a function");
        }
        lua_pop(L, 1);

        /* Initialize steps counter if not set. */
        lua_getfield(L, 1, "steps");
        if (lua_isnil(L, -1)) {
            lua_pop(L, 1);
            lua_pushinteger(L, 0);
            lua_setfield(L, 1, "steps");
        } else {
            lua_pop(L, 1);
        }
        lua_pushvalue(L, 1);
        lua_rawsetp(L, LUA_REGISTRYINDEX, &TICK_KEY);
        mask |= LUA_MASKLINE;
    } else {
        lua_pushnil(L);
        lua_rawsetp(L, LUA_REGISTRYINDEX, &TICK_KEY);
    }

    lua_sethook(L, pc_hook, mask, 1);
    return 0;
}

static int l_stop(lua_State *L) {
    int result_idx;

    /* Drop the hook first so no further pc_hook callback can fire. After
       this, PCHOOK entries are guaranteed to be immutable. */
    lua_sethook(L, NULL, 0, 0);

    /* Pre-build snapshots while we still hold the GIL on a healthy state
       (i.e. before any __gc finalizer might run). l_get_all_* will then
       serve these in O(1) — that path is what runs during lua_close /
       luaC_freeallobjects. */

    /* SNAPSHOT_ALL_HITS_KEY */
    lua_newtable(L);
    result_idx = lua_gettop(L);
    aggregate_all_hits(L, result_idx);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &SNAPSHOT_ALL_HITS_KEY);

    /* SNAPSHOT_LINE_HITS_KEY */
    lua_newtable(L);
    result_idx = lua_gettop(L);
    aggregate_all_line_hits(L, result_idx);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &SNAPSHOT_LINE_HITS_KEY);

    /* IMPORTANT: do NOT drop PROTO_INDEX_KEY here. l_get_hits /
       l_get_line_hits accept a Lua function argument; while that function
       is alive (caller holds a reference) the corresponding Proto* is
       guaranteed to remain valid, and we still need PROTO_INDEX_KEY to
       map it back to the entry id.
       PROTO_INDEX_KEY is reset by l_start (every fresh run) and by
       l_reset (explicit teardown). The shutdown-safety property relied
       on by GC finalizers comes entirely from PCHOOK_KEY entries being
       pure Lua data — they never touch Proto* and are read by
       l_get_all_*. */

    lua_pushnil(L);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &TICK_KEY);
    return 0;
}

/*
 * Build a (Proto* -> entry_id) index from the live PROTO_INDEX_KEY (when the
 * hook is active) so that l_get_hits / l_get_line_hits can look up the entry
 * for a user-passed function. When the hook is no longer active, this returns
 * 0 (no entry found) and the caller emits an empty result.
 *
 * Returns the entry id (>= 1) on success, or 0 when the proto was never seen.
 */
static lua_Integer find_entry_id_for_proto(lua_State *L, const Proto *proto) {
    lua_Integer entry_id;

    lua_rawgetp(L, LUA_REGISTRYINDEX, &PROTO_INDEX_KEY);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return 0;
    }
    lua_rawgetp(L, -1, (const void *)proto);
    entry_id = lua_tointeger(L, -1);
    lua_pop(L, 2);
    return entry_id;
}

static int l_reset(lua_State *L) {
    /* Drop everything: collected entries, Proto* lookup, and snapshot caches. */
    lua_newtable(L);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &PCHOOK_KEY);

    lua_newtable(L);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &PROTO_INDEX_KEY);

    lua_pushnil(L);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &SNAPSHOT_LINE_HITS_KEY);
    lua_pushnil(L);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &SNAPSHOT_ALL_HITS_KEY);
    return 0;
}

/*
 * ---------------------------------------------------------------------------
 * Aggregators that read PCHOOK_KEY (array of materialized entries) and write
 * the final result tables. They use ABSOLUTE stack indices throughout to
 * avoid the pitfalls of relative indices when local pushes/pops happen
 * during inner loops.
 *
 * Both aggregators are self-contained: they touch only Lua-managed data
 * (source strings, integer arrays/tables) and never dereference Proto*,
 * so they are safe to call from any context, including __gc finalizers.
 * ---------------------------------------------------------------------------
 */

static void aggregate_all_hits(lua_State *L, int result_idx) {
    int pchook_idx;
    int n, i;

    lua_rawgetp(L, LUA_REGISTRYINDEX, &PCHOOK_KEY);
    if (lua_isnil(L, -1)) { lua_pop(L, 1); return; }
    pchook_idx = lua_gettop(L);

    n = (int)lua_rawlen(L, pchook_idx);
    for (i = 1; i <= n; i++) {
        int entry_idx;
        int list_idx;
        int rec_idx;
        int list_len;
        const char *source;

        lua_rawgeti(L, pchook_idx, i);
        if (!lua_istable(L, -1)) { lua_pop(L, 1); continue; }
        entry_idx = lua_gettop(L);

        lua_getfield(L, entry_idx, "source");
        source = lua_tostring(L, -1);
        if (source == NULL) { lua_pop(L, 2); continue; }

        /* result[source] : list of per-proto records */
        lua_getfield(L, result_idx, source);
        if (lua_isnil(L, -1)) {
            lua_pop(L, 1);
            lua_newtable(L);
            lua_pushvalue(L, -1);
            lua_setfield(L, result_idx, source);
        }
        list_idx = lua_gettop(L);
        list_len = (int)lua_rawlen(L, list_idx);

        /* Build { linedefined, sizecode, hits } using absolute entry_idx. */
        lua_createtable(L, 0, 3);
        rec_idx = lua_gettop(L);

        lua_getfield(L, entry_idx, "linedefined");
        lua_setfield(L, rec_idx, "linedefined");
        lua_getfield(L, entry_idx, "lastlinedefined");
        lua_setfield(L, rec_idx, "lastlinedefined");
        lua_getfield(L, entry_idx, "sizecode");
        lua_setfield(L, rec_idx, "sizecode");
        lua_getfield(L, entry_idx, "hits");
        lua_setfield(L, rec_idx, "hits");

        lua_rawseti(L, list_idx, list_len + 1);
        /* Pop list, source string, entry. */
        lua_pop(L, 3);
    }

    lua_pop(L, 1);  /* PCHOOK_KEY */
}

static void aggregate_all_line_hits(lua_State *L, int result_idx) {
    int pchook_idx;
    int n, i;

    lua_rawgetp(L, LUA_REGISTRYINDEX, &PCHOOK_KEY);
    if (lua_isnil(L, -1)) { lua_pop(L, 1); return; }
    pchook_idx = lua_gettop(L);

    n = (int)lua_rawlen(L, pchook_idx);
    for (i = 1; i <= n; i++) {
        int entry_idx;
        int file_idx;
        int lines_idx;
        int hits_idx;
        int temp_idx;
        int max_line;
        int lines_len;
        int j;
        const char *source;

        lua_rawgeti(L, pchook_idx, i);
        if (!lua_istable(L, -1)) { lua_pop(L, 1); continue; }
        entry_idx = lua_gettop(L);

        lua_getfield(L, entry_idx, "source");
        source = lua_tostring(L, -1);
        if (source == NULL) { lua_pop(L, 2); continue; }

        /* result[source] : { [line]=max_count, max=N } */
        lua_getfield(L, result_idx, source);
        if (lua_isnil(L, -1)) {
            lua_pop(L, 1);
            lua_createtable(L, 0, 1);
            lua_pushinteger(L, 0);
            lua_setfield(L, -2, "max");
            lua_pushvalue(L, -1);
            lua_setfield(L, result_idx, source);
        }
        file_idx = lua_gettop(L);

        lua_getfield(L, file_idx, "max");
        max_line = (int)lua_tointeger(L, -1);
        lua_pop(L, 1);

        /* Walk entry.lines (0-based pc -> line) to mark active lines as 0.
           lua_rawlen on a 0-keyed array reports n only for keys 1..n, so we
           iterate via lua_next to cover the full sparse range including pc=0. */
        lua_getfield(L, entry_idx, "lines");
        lines_idx = lua_gettop(L);
        (void)lines_len;  /* unused: switched to lua_next-based iteration */
        lua_pushnil(L);
        while (lua_next(L, lines_idx) != 0) {
            int line = (int)lua_tointeger(L, -1);
            lua_pop(L, 1);  /* value */
            if (line <= 0) continue;

            lua_rawgeti(L, file_idx, line);
            if (lua_isnil(L, -1)) {
                lua_pop(L, 1);
                lua_pushinteger(L, 0);
                lua_rawseti(L, file_idx, line);
            } else {
                lua_pop(L, 1);
            }
            if (line > max_line) max_line = line;
        }

        /* Walk entry.hits — two-pass approach:
         *
         * Pass 1: Build per-proto per-line MAX in a temporary table.
         *   Multiple PCs within the same proto may map to the same line
         *   (e.g. a loop test + body on one line); take the maximum to
         *   represent "line execution count" for this single proto.
         *
         * Pass 2: SUM the per-proto maxima into the file accumulator.
         *   When the same file is loaded multiple times (e.g. busted
         *   clearing package.loaded between spec files), each load
         *   creates separate Proto objects. Their line hits must be
         *   summed to give the total execution count.
         *
         * The hits-table key is `savedpc - proto->code` (next-instruction
         * PC). To get the correct source line we look up lines[pc - 1].
         * Keys <= 0 are skipped (no "previous instruction" in this Proto).
         */
        lua_getfield(L, entry_idx, "hits");
        hits_idx = lua_gettop(L);

        /* Pass 1: per-proto per-line MAX into temp table */
        lua_newtable(L);
        temp_idx = lua_gettop(L);

        lua_pushnil(L);
        while (lua_next(L, hits_idx) != 0) {
            int pc = (int)lua_tointeger(L, -2);
            lua_Integer count = lua_tointeger(L, -1);
            int line;
            lua_pop(L, 1);  /* value */

            if (pc <= 0) continue;

            /* line = entry.lines[pc - 1]  (the instruction that ran) */
            lua_rawgeti(L, lines_idx, pc - 1);
            line = (int)lua_tointeger(L, -1);
            lua_pop(L, 1);
            if (line <= 0) continue;

            lua_rawgeti(L, temp_idx, line);
            {
                lua_Integer existing = lua_tointeger(L, -1);
                lua_pop(L, 1);
                if (count > existing) {
                    lua_pushinteger(L, count);
                    lua_rawseti(L, temp_idx, line);
                }
            }
            if (line > max_line) max_line = line;
        }

        /* Pass 2: SUM per-proto maxima into file accumulator */
        lua_pushnil(L);
        while (lua_next(L, temp_idx) != 0) {
            int line = (int)lua_tointeger(L, -2);
            lua_Integer proto_max = lua_tointeger(L, -1);
            lua_pop(L, 1);  /* value */

            lua_rawgeti(L, file_idx, line);
            {
                lua_Integer existing = lua_tointeger(L, -1);
                lua_pop(L, 1);
                lua_pushinteger(L, existing + proto_max);
                lua_rawseti(L, file_idx, line);
            }
        }

        lua_pushinteger(L, max_line);
        lua_setfield(L, file_idx, "max");

        /* Pop temp, hits, lines, file, source, entry. */
        lua_pop(L, 6);
    }

    lua_pop(L, 1);  /* PCHOOK_KEY */
}

/*
 * NOTE on the SNAPSHOT_*_KEY caches:
 *
 * The PCHOOK_KEY entries are mutated in place by pc_hook every time the
 * coverage hook fires. Therefore we MUST NOT serve a cached snapshot while
 * the hook is still active (e.g. tick mode calls save_stats periodically
 * from inside the running process). Doing so would freeze coverage at the
 * value observed during the very first save_stats call.
 *
 * The cache is only populated by l_stop (after lua_sethook(NULL)), and is
 * also invalidated by l_start / l_reset. From that point on the underlying
 * data is immutable, so reads from __gc finalizers can be served instantly
 * without re-aggregation.
 */
static int l_get_all_hits(lua_State *L) {
    int result_idx;

    lua_rawgetp(L, LUA_REGISTRYINDEX, &SNAPSHOT_ALL_HITS_KEY);
    if (!lua_isnil(L, -1)) return 1;
    lua_pop(L, 1);

    lua_newtable(L);
    result_idx = lua_gettop(L);
    aggregate_all_hits(L, result_idx);
    return 1;
}

static int l_get_all_line_hits(lua_State *L) {
    int result_idx;

    lua_rawgetp(L, LUA_REGISTRYINDEX, &SNAPSHOT_LINE_HITS_KEY);
    if (!lua_isnil(L, -1)) return 1;
    lua_pop(L, 1);

    lua_newtable(L);
    result_idx = lua_gettop(L);
    aggregate_all_line_hits(L, result_idx);
    return 1;
}

/*
 * l_get_hits / l_get_line_hits — per-function variants. These are only useful
 * while pchook is still active (the caller passes a live function whose
 * Proto* must still be valid to traverse `proto->p[]`); after stop() they
 * fall back to "empty" because we no longer have a reliable Proto* -> entry
 * mapping for nested protos.
 */
static void collect_proto_hits_recursive(
    lua_State *L,
    Proto *proto,
    int result_idx,
    int *count
) {
    lua_Integer entry_id;
    int i;

    /* Build a per-Proto record: { linedefined, sizecode, hits }. */
    lua_createtable(L, 0, 3);
    lua_pushinteger(L, proto->linedefined);
    lua_setfield(L, -2, "linedefined");
    lua_pushinteger(L, proto->sizecode);
    lua_setfield(L, -2, "sizecode");

    entry_id = find_entry_id_for_proto(L, proto);
    if (entry_id > 0) {
        lua_rawgetp(L, LUA_REGISTRYINDEX, &PCHOOK_KEY);
        lua_rawgeti(L, -1, entry_id);
        lua_getfield(L, -1, "hits");
        lua_remove(L, -2);  /* entry */
        lua_remove(L, -2);  /* PCHOOK_KEY */
    } else {
        lua_newtable(L);
    }
    lua_setfield(L, -2, "hits");

    lua_rawseti(L, result_idx, ++(*count));

    for (i = 0; i < proto->sizep; i++) {
        collect_proto_hits_recursive(L, proto->p[i], result_idx, count);
    }
}

static int l_get_hits(lua_State *L) {
    Proto *proto;
    int result_idx;
    int count = 0;

    luaL_checktype(L, 1, LUA_TFUNCTION);
    luaL_argcheck(L, !lua_iscfunction(L, 1), 1,
        "Lua function expected, got C function");

    proto = get_proto(L, 1);

    lua_newtable(L);
    result_idx = lua_gettop(L);

    collect_proto_hits_recursive(L, proto, result_idx, &count);
    return 1;
}

static void collect_line_hits_recursive(
    lua_State *L,
    Proto *proto,
    int result_idx
) {
    lua_Integer entry_id;
    int pc, line, max_line;
    int i;

    for (pc = 0; pc < proto->sizecode; pc++) {
        line = get_pc_line(proto, pc);
        if (line <= 0) continue;

        lua_rawgeti(L, result_idx, line);
        if (lua_isnil(L, -1)) {
            lua_pop(L, 1);
            lua_pushinteger(L, 0);
            lua_rawseti(L, result_idx, line);
        } else {
            lua_pop(L, 1);
        }

        lua_getfield(L, result_idx, "max");
        max_line = (int)lua_tointeger(L, -1);
        lua_pop(L, 1);
        if (line > max_line) {
            lua_pushinteger(L, line);
            lua_setfield(L, result_idx, "max");
        }
    }

    entry_id = find_entry_id_for_proto(L, proto);
    if (entry_id > 0) {
        lua_rawgetp(L, LUA_REGISTRYINDEX, &PCHOOK_KEY);
        lua_rawgeti(L, -1, entry_id);
        lua_getfield(L, -1, "hits");
        lua_pushnil(L);
        while (lua_next(L, -2) != 0) {
            int pc = (int)lua_tointeger(L, -2);
            lua_Integer count = lua_tointeger(L, -1);
            lua_pop(L, 1);

            /*
             * Map "next-instruction PC" (the hits-table key) back to the source
             * line of the instruction that ACTUALLY executed.
             *
             * The hits table key is `savedpc - proto->code`, which by Lua's
             * convention (luaG_traceexec in ldebug.c does `pc++; ci->u.l.savedpc = pc;`
             * BEFORE invoking any hook) is the PC of the NEXT instruction to
             * execute, not the one that just ran. This convention is preserved
             * here at the storage layer so that branchcov.lua can keep using
             * `proto_hits[target.pc]` (where target.pc is a jump-target PC,
             * also expressed as a "next-to-execute" PC) without modification.
             *
             * For LINE-level coverage, however, we want the line of the
             * instruction that just ran. This is the same convention Lua
             * itself uses internally - see `pcRel(pc, p)` in src/ldebug.h:
             *
             *     #define pcRel(pc, p)  (cast_int((pc) - (p)->code) - 1)
             *
             * Without this `pc - 1` shift, the first executable line of every
             * function body shows hits = 0 (e.g. `local t = obj.field` at the
             * top of a function), and the line after it gets double-counted.
             *
             * pc == 0 is skipped: there is no "previous" instruction inside
             * this Proto for the hook to credit (the count belongs to the
             * caller's frame).
             */
            if (pc <= 0) continue;
            line = get_pc_line(proto, pc - 1);
            if (line <= 0) continue;

            lua_rawgeti(L, result_idx, line);
            {
                lua_Integer existing = lua_tointeger(L, -1);
                lua_pop(L, 1);
                if (count > existing) {
                    lua_pushinteger(L, count);
                    lua_rawseti(L, result_idx, line);
                }
            }
        }
        lua_pop(L, 3);  /* hits, entry, PCHOOK_KEY */
    }

    for (i = 0; i < proto->sizep; i++) {
        collect_line_hits_recursive(L, proto->p[i], result_idx);
    }
}

static int l_get_line_hits(lua_State *L) {
    Proto *proto;
    int result_idx;

    luaL_checktype(L, 1, LUA_TFUNCTION);
    luaL_argcheck(L, !lua_iscfunction(L, 1), 1,
        "Lua function expected, got C function");

    proto = get_proto(L, 1);

    lua_newtable(L);
    result_idx = lua_gettop(L);

    lua_pushinteger(L, 0);
    lua_setfield(L, result_idx, "max");

    collect_line_hits_recursive(L, proto, result_idx);

    return 1;
}

/*
 * get_func_defs(func) — returns a list of { linedefined, lastlinedefined }
 * for every child Proto in the function's proto tree (skipping the top-level
 * chunk whose linedefined == 0).  This traverses the raw Proto* hierarchy of
 * the loaded function, so it works regardless of whether pchook was active.
 * Used by runner.lua to discover lastlinedefined for uncalled functions.
 */
static void collect_func_defs_recursive(
    lua_State *L, Proto *proto, int result_idx, int *count
) {
    int i;
    if (proto->linedefined > 0) {
        lua_createtable(L, 0, 2);
        lua_pushinteger(L, proto->linedefined);
        lua_setfield(L, -2, "linedefined");
        lua_pushinteger(L, proto->lastlinedefined);
        lua_setfield(L, -2, "lastlinedefined");
        lua_rawseti(L, result_idx, ++(*count));
    }
    for (i = 0; i < proto->sizep; i++) {
        collect_func_defs_recursive(L, proto->p[i], result_idx, count);
    }
}

static int l_get_func_defs(lua_State *L) {
    Proto *proto;
    int result_idx;
    int count = 0;

    luaL_checktype(L, 1, LUA_TFUNCTION);
    luaL_argcheck(L, !lua_iscfunction(L, 1), 1,
        "Lua function expected, got C function");

    proto = get_proto(L, 1);

    lua_newtable(L);
    result_idx = lua_gettop(L);

    collect_func_defs_recursive(L, proto, result_idx, &count);
    return 1;
}

#else /* Lua < 5.4 or LuaJIT */

static int l_start(lua_State *L) {
    return luaL_error(L, "pchook requires PUC-Rio Lua 5.4 or later");
}

static int l_stop(lua_State *L) {
    (void)L;
    return 0;
}

static int l_get_hits(lua_State *L) {
    lua_newtable(L);
    return 1;
}

static int l_reset(lua_State *L) {
    (void)L;
    return 0;
}

static int l_get_line_hits(lua_State *L) {
    lua_newtable(L);
    return 1;
}

static int l_get_all_hits(lua_State *L) {
    (void)L;
    lua_newtable(L);
    return 1;
}

static int l_get_all_line_hits(lua_State *L) {
    (void)L;
    lua_newtable(L);
    return 1;
}

static int l_get_func_defs(lua_State *L) {
    (void)L;
    lua_newtable(L);
    return 1;
}

#endif

int luaopen_cluacov_pchook(lua_State *L) {
    lua_newtable(L);

    lua_pushcfunction(L, l_start);
    lua_setfield(L, -2, "start");

    lua_pushcfunction(L, l_stop);
    lua_setfield(L, -2, "stop");

    lua_pushcfunction(L, l_get_hits);
    lua_setfield(L, -2, "get_hits");

    lua_pushcfunction(L, l_reset);
    lua_setfield(L, -2, "reset");

    lua_pushcfunction(L, l_get_line_hits);
    lua_setfield(L, -2, "get_line_hits");

    lua_pushcfunction(L, l_get_all_hits);
    lua_setfield(L, -2, "get_all_hits");

    lua_pushcfunction(L, l_get_all_line_hits);
    lua_setfield(L, -2, "get_all_line_hits");

    lua_pushcfunction(L, l_get_func_defs);
    lua_setfield(L, -2, "get_func_defs");

    lua_pushliteral(L, "1.0.0");
    lua_setfield(L, -2, "version");

    return 1;
}
