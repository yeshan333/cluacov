#include "lua.h"
#include "lauxlib.h"
#include <string.h>

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

#include "protoinfo.h"

/* Materialized entries contain only Lua data. The private weak-key index
 * uses collectable Proto values, not lightuserdata addresses: GC removes a
 * dead Proto's mapping before its address can be reused. It survives stop /
 * start and does not retain closures, upvalues, or coroutines. */
static char PCHOOK_KEY;
static char PROTO_INDEX_KEY;
static char FRAMES_KEY;
static char TICK_KEY;
static char SNAPSHOT_LINE_HITS_KEY;
static char SNAPSHOT_ALL_HITS_KEY;
static char HOOK_ACTIVE_KEY;

/* Check the new state prefixes before exposing any API that traverses allgc.
 * Public API values validate the allocator/registry offsets. A freshly created
 * thread is the allgc head in stock Lua 5.4/5.5, so the head can be checked
 * without following an unvalidated GC pointer. The probe is stack-anchored;
 * it becomes ordinary collectible garbage afterwards.
 *
 * This is a sanity check, not an ABI sandbox: reading l_G itself still assumes
 * the stock lua_State prefix. Custom Lua builds must use matching headers.
 */
static void check_state_layout(lua_State *L) {
    void *ud;
    lua_Alloc alloc = lua_getallocf(L, &ud);
    global_State *g = L->l_G;
    lua_State *probe;

    if (g == NULL || g->frealloc != alloc || g->ud != ud ||
        !ttistable(&g->l_registry) ||
        (const void *)val_(&g->l_registry).gc != lua_topointer(L, LUA_REGISTRYINDEX)) {
        luaL_error(L, "cluacov.pchook: incompatible Lua state layout (allocator/registry)");
    }

    probe = lua_newthread(L);
    if (g->allgc != (GCObject *)probe || probe->tt != LUA_VTHREAD || probe->l_G != g) {
        luaL_error(L, "cluacov.pchook: incompatible Lua state layout (thread/allgc)");
    }
    lua_pop(L, 1);
}

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

static const char *normalize_source_name(const Proto *proto) {
    const char *source = get_source_name(proto);
    return source == NULL ? "?" : source;
}

/* Lua's GC knows Proto values even though the public API cannot push them.
 * This private key never escapes to Lua. The caller holds the Proto alive via
 * an executing closure or a function argument. lua_rawset supplies the table
 * write barrier, and weak keys avoid retaining any executable object. */
static void push_proto_key(lua_State *L, const Proto *proto) {
    lua_pushnil(L);
    setgcovalue(L, s2v(L->top.p - 1), (GCObject *)proto);
}

static void new_weak_keys(lua_State *L, void *key) {
    lua_newtable(L);
    lua_newtable(L);
    lua_pushliteral(L, "k");
    lua_setfield(L, -2, "__mode");
    lua_setmetatable(L, -2);
    lua_rawsetp(L, LUA_REGISTRYINDEX, key);
}

static lua_Integer find_entry_id_for_proto(lua_State *L, const Proto *proto) {
    lua_Integer id = 0;
    lua_rawgetp(L, LUA_REGISTRYINDEX, &PROTO_INDEX_KEY);
    if (lua_istable(L, -1)) {
        push_proto_key(L, proto);
        lua_rawget(L, -2);
        id = lua_tointeger(L, -1);
        lua_pop(L, 1);
    }
    lua_pop(L, 1);
    return id;
}

static void materialize_proto_entry(lua_State *L, const Proto *proto,
                                    const char *path) {
    int pc;
    lua_createtable(L, 0, 10);
    set_proto_metadata(L, proto, path);
    /* Only per-function queries expose a live identity. Stored records must
       remain usable after the Proto is collected, including at lua_close. */
    lua_pushnil(L);
    lua_setfield(L, -2, "proto_id");
    lua_pushstring(L, normalize_source_name(proto));
    lua_setfield(L, -2, "source");
    lua_createtable(L, proto->sizecode, 0);
    for (pc = 0; pc < proto->sizecode; pc++) {
        int line = get_pc_line(proto, pc);
        if (line > 0) {
            lua_pushinteger(L, line);
            lua_rawseti(L, -2, pc);
        }
    }
    lua_setfield(L, -2, "lines");
    lua_newtable(L);
    lua_setfield(L, -2, "hits");
    lua_newtable(L);
    lua_setfield(L, -2, "edges");
    lua_pushinteger(L, 0);
    lua_setfield(L, -2, "calls");
}

/* Register an entire tree when first encountered. A chunk's lexical child
 * paths distinguish identical same-line siblings and survive file reloads.
 * A preloaded child whose root was never observed has no absolute path; the
 * reporter may match it by signature only when that match is unambiguous. */
static lua_Integer register_proto(lua_State *L, const Proto *proto,
                                  const char *path) {
    lua_Integer id;
    int entries, i;
    luaL_checkstack(L, 12, "cluacov prototype nesting too deep");
    id = find_entry_id_for_proto(L, proto);
    lua_rawgetp(L, LUA_REGISTRYINDEX, &PCHOOK_KEY);
    entries = lua_gettop(L);
    if (id == 0) {
        id = (lua_Integer)lua_rawlen(L, entries) + 1;
        materialize_proto_entry(L, proto, path);
        lua_rawseti(L, entries, id);
        lua_rawgetp(L, LUA_REGISTRYINDEX, &PROTO_INDEX_KEY);
        push_proto_key(L, proto);
        lua_pushinteger(L, id);
        lua_rawset(L, -3);
        lua_pop(L, 1);
    } else if (path != NULL) {
        lua_rawgeti(L, entries, id);
        lua_pushstring(L, path);
        lua_setfield(L, -2, "proto_path");
        lua_pop(L, 1);
    }
    lua_pop(L, 1);
    for (i = 0; i < proto->sizep; i++) {
        if (path != NULL) {
            const char *child = lua_pushfstring(L, "%s.%d", path, i + 1);
            register_proto(L, proto->p[i], child);
            lua_pop(L, 1);
        } else {
            register_proto(L, proto->p[i], NULL);
        }
    }
    return id;
}

static void push_entry(lua_State *L, const Proto *proto) {
    lua_Integer id = find_entry_id_for_proto(L, proto);
    if (id == 0) {
        id = register_proto(L, proto, proto->linedefined == 0 ? "0" : NULL);
    }
    lua_rawgetp(L, LUA_REGISTRYINDEX, &PCHOOK_KEY);
    lua_rawgeti(L, -1, id);
    lua_remove(L, -2);
}

static void increment_field(lua_State *L, int table, const char *field) {
    lua_Integer count;
    lua_getfield(L, table, field);
    count = lua_tointeger(L, -1);
    lua_pop(L, 1);
    lua_pushinteger(L, count + 1);
    lua_setfield(L, table, field);
}

/* Each thread owns a map from CallInfo to the previous observed PC. Call and
 * return events clear reused frames, including tail calls; error unwinding is
 * handled by the next call event. Values never reference the thread itself. */
static void push_frames(lua_State *L) {
    lua_rawgetp(L, LUA_REGISTRYINDEX, &FRAMES_KEY);
    lua_pushthread(L);
    lua_rawget(L, -2);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_pushthread(L);
        lua_pushvalue(L, -2);
        lua_rawset(L, -4);
    }
    lua_remove(L, -2);
}

static void record_transition(lua_State *L, int entry, CallInfo *ci, int pc) {
    int previous;
    push_frames(L);
    lua_rawgetp(L, -1, ci);
    previous = (int)lua_tointeger(L, -1);
    lua_pop(L, 1);
    lua_pushinteger(L, pc);
    lua_rawsetp(L, -2, ci);
    lua_pop(L, 1);
    if (previous > 0) {
        lua_Integer count;
        lua_getfield(L, entry, "edges");
        lua_rawgeti(L, -1, previous);
        if (lua_isnil(L, -1)) {
            lua_pop(L, 1);
            lua_newtable(L);
            lua_pushvalue(L, -1);
            lua_rawseti(L, -3, previous);
        }
        lua_rawgeti(L, -1, pc);
        count = lua_tointeger(L, -1);
        lua_pop(L, 1);
        lua_pushinteger(L, count + 1);
        lua_rawseti(L, -2, pc);
        lua_pop(L, 2);
    }
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

    {
        Proto *proto;
        CallInfo *ci = (CallInfo *)ar->i_ci;
        int entry, pc;
        lua_Integer count;

        if (ar->event == LUA_HOOKRET || ar->event == LUA_HOOKCALL ||
            ar->event == LUA_HOOKTAILCALL) {
            push_frames(L);
            lua_pushnil(L);
            lua_rawsetp(L, -2, ci);
            lua_pop(L, 1);
            if (ar->event == LUA_HOOKRET) return;
        }

        lua_getinfo(L, "f", ar);
        if (lua_iscfunction(L, -1)) {
            lua_pop(L, 1);
            return;
        }
        proto = get_proto(L, -1);
        push_entry(L, proto);
        entry = lua_gettop(L);
        if (ar->event == LUA_HOOKCALL || ar->event == LUA_HOOKTAILCALL) {
            increment_field(L, entry, "calls");
        } else {
            pc = (int)(ci->u.l.savedpc - proto->code);
            record_transition(L, entry, ci, pc);
            lua_getfield(L, entry, "hits");
            lua_rawgeti(L, -1, pc);
            count = lua_tointeger(L, -1);
            lua_pop(L, 1);
            lua_pushinteger(L, count + 1);
            lua_rawseti(L, -2, pc);
            lua_pop(L, 1);
        }
        lua_pop(L, 2);  /* entry and executing closure */
    }
}

static int l_get_all_line_hits(lua_State *L);
static int l_get_all_hits(lua_State *L);
static void aggregate_all_hits(lua_State *L, int result_idx);
static void aggregate_all_line_hits(lua_State *L, int result_idx);

/*
 * Hosts such as ltask lua_resume the main thread, which makes it yieldable.
 * Closed while it is suspended with a count/line hook, Lua 5.4 aborts every
 * finalizer, so there such a main thread is hooked only when it calls start.
 * Lua 5.5 runs finalizers normally and keeps the hook.
 */
static int skip_main_thread(lua_State *L, lua_State *thread) {
#if LUA_VERSION_NUM == 504
    lua_State *main_thread;

    lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_MAINTHREAD);
    main_thread = lua_tothread(L, -1);
    lua_pop(L, 1);
    return thread == main_thread && thread != L && lua_isyieldable(thread);
#else
    (void)L;
    (void)thread;
    return 0;
#endif
}

/*
 * Install/remove the hook on every existing thread (see skip_main_thread),
 * including coroutine.wrap threads hidden in C closures and threads resumed
 * through cached/C APIs.
 * New threads inherit the hook from their creator (lua_newthread).
 *
 * This pass only reads the GC list and calls lua_gethook/lua_sethook, which
 * do not allocate or run Lua/GC. Never keep these raw pointers after the pass.
 * In particular, do not retain threads and prevent their normal collection.
 */
static void set_thread_hooks(lua_State *L, int mask) {
    GCObject *object;
    for (object = L->l_G->allgc; object != NULL; object = object->next) {
        if (object->tt == LUA_VTHREAD) {
            lua_State *thread = (lua_State *)object;
            if (mask != 0) {
                if (skip_main_thread(L, thread)) {
                    continue;
                }
                lua_sethook(thread, pc_hook, mask, 1);
            } else if (lua_gethook(thread) == pc_hook) {
                /* Leave hooks installed by somebody else after start alone. */
                lua_sethook(thread, NULL, 0, 0);
            }
        }
    }
}

static int l_start(lua_State *L) {
    int mask;

    lua_rawgetp(L, LUA_REGISTRYINDEX, &HOOK_ACTIVE_KEY);
    if (!lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return 0;
    }
    lua_pop(L, 1);

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

    lua_rawgetp(L, LUA_REGISTRYINDEX, &PROTO_INDEX_KEY);
    if (lua_isnil(L, -1)) new_weak_keys(L, &PROTO_INDEX_KEY);
    lua_pop(L, 1);
    new_weak_keys(L, &FRAMES_KEY);

    mask = LUA_MASKCOUNT | LUA_MASKCALL | LUA_MASKRET;

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

    lua_pushboolean(L, 1);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &HOOK_ACTIVE_KEY);
    set_thread_hooks(L, mask);
    return 0;
}

static int l_stop(lua_State *L) {
    int result_idx;

    /* Stop all threads before caching snapshots: a suspended coroutine
       resumed after stop must not mutate the underlying hit tables. */
    set_thread_hooks(L, 0);
    lua_pushnil(L);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &HOOK_ACTIVE_KEY);

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

    /* Keep the GC-managed Proto index across sessions; reset alone discards
       cumulative data. Clear frame PCs so no edge crosses a stopped interval. */
    new_weak_keys(L, &FRAMES_KEY);
    lua_pushnil(L);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &TICK_KEY);
    return 0;
}

static int l_reset(lua_State *L) {
    lua_newtable(L);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &PCHOOK_KEY);
    new_weak_keys(L, &PROTO_INDEX_KEY);
    new_weak_keys(L, &FRAMES_KEY);
    lua_pushnil(L);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &SNAPSHOT_LINE_HITS_KEY);
    lua_pushnil(L);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &SNAPSHOT_ALL_HITS_KEY);
    /* reset clears data, not the active session or its tick configuration. */
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

static void copy_field(lua_State *L, int from, int to, const char *name) {
    lua_getfield(L, from, name);
    lua_setfield(L, to, name);
}

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

        lua_createtable(L, 0, 8);
        rec_idx = lua_gettop(L);
        copy_field(L, entry_idx, rec_idx, "linedefined");
        copy_field(L, entry_idx, rec_idx, "lastlinedefined");
        copy_field(L, entry_idx, rec_idx, "sizecode");
        copy_field(L, entry_idx, rec_idx, "proto_path");
        copy_field(L, entry_idx, rec_idx, "signature");
        copy_field(L, entry_idx, rec_idx, "hits");
        copy_field(L, entry_idx, rec_idx, "edges");
        copy_field(L, entry_idx, rec_idx, "calls");

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

/* Per-function queries use a live Proto tree and expose its opaque identity
 * for joining with deepbranches. No structural metadata can stand in for it. */
static void collect_proto_hits_recursive(
    lua_State *L, Proto *proto, int result_idx, int *count
) {
    lua_Integer entry_id;
    int i, record;
    luaL_checkstack(L, 12, "cluacov prototype nesting too deep");
    lua_createtable(L, 0, 9);
    record = lua_gettop(L);
    set_proto_metadata(L, proto, NULL);
    entry_id = find_entry_id_for_proto(L, proto);
    if (entry_id > 0) {
        lua_rawgetp(L, LUA_REGISTRYINDEX, &PCHOOK_KEY);
        lua_rawgeti(L, -1, entry_id);
        copy_field(L, lua_gettop(L), record, "hits");
        copy_field(L, lua_gettop(L), record, "edges");
        copy_field(L, lua_gettop(L), record, "calls");
        copy_field(L, lua_gettop(L), record, "proto_path");
        lua_pop(L, 2);
    } else {
        lua_newtable(L);
        lua_setfield(L, record, "hits");
        lua_newtable(L);
        lua_setfield(L, record, "edges");
        lua_pushinteger(L, 0);
        lua_setfield(L, record, "calls");
    }
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
    lua_State *L, Proto *proto, int result_idx, int *count, const char *path
) {
    int i;
    luaL_checkstack(L, 12, "cluacov prototype nesting too deep");
    if (proto->linedefined > 0) {
        lua_createtable(L, 0, 6);
        set_proto_metadata(L, proto, path);
        lua_rawseti(L, result_idx, ++(*count));
    }
    for (i = 0; i < proto->sizep; i++) {
        const char *child = lua_pushfstring(L, "%s.%d", path, i + 1);
        collect_func_defs_recursive(L, proto->p[i], result_idx, count, child);
        lua_pop(L, 1);
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

    collect_func_defs_recursive(L, proto, result_idx, &count, "0");
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
#if defined(PUCRIOLUA) && LUA_VERSION_NUM >= 504
    check_state_layout(L);
#endif
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
