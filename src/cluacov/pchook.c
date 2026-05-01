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

static char PCHOOK_KEY;

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

static void pc_hook(lua_State *L, lua_Debug *ar) {
    Proto *proto;
    const void *proto_key;
    CallInfo *ci;
    int pc;
    lua_Integer count;

    lua_getinfo(L, "f", ar);

    if (lua_iscfunction(L, -1)) {
        lua_pop(L, 1);
        return;
    }

    proto = get_proto(L, -1);
    proto_key = (const void *)proto;
    lua_pop(L, 1);

    ci = (CallInfo *)ar->i_ci;
    pc = (int)(ci->u.l.savedpc - proto->code);

    lua_rawgetp(L, LUA_REGISTRYINDEX, &PCHOOK_KEY);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return;
    }

    lua_rawgetp(L, -1, proto_key);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_pushvalue(L, -1);
        lua_rawsetp(L, -3, proto_key);
    }

    lua_rawgeti(L, -1, pc);
    count = lua_tointeger(L, -1) + 1;
    lua_pop(L, 1);
    lua_pushinteger(L, count);
    lua_rawseti(L, -2, pc);

    lua_pop(L, 2);
}

static int l_start(lua_State *L) {
    lua_rawgetp(L, LUA_REGISTRYINDEX, &PCHOOK_KEY);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_rawsetp(L, LUA_REGISTRYINDEX, &PCHOOK_KEY);
    } else {
        lua_pop(L, 1);
    }

    lua_sethook(L, pc_hook, LUA_MASKCOUNT, 1);
    return 0;
}

static int l_stop(lua_State *L) {
    lua_sethook(L, NULL, 0, 0);
    return 0;
}

static void collect_proto_hits(
    lua_State *L,
    Proto *proto,
    int hits_idx,
    int result_idx,
    int *count
) {
    const void *proto_key = (const void *)proto;
    int i;

    lua_newtable(L);

    lua_pushinteger(L, proto->linedefined);
    lua_setfield(L, -2, "linedefined");

    lua_pushinteger(L, proto->sizecode);
    lua_setfield(L, -2, "sizecode");

    lua_rawgetp(L, hits_idx, proto_key);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
    }
    lua_setfield(L, -2, "hits");

    lua_rawseti(L, result_idx, ++(*count));

    for (i = 0; i < proto->sizep; i++) {
        collect_proto_hits(L, proto->p[i], hits_idx, result_idx, count);
    }
}

static int l_get_hits(lua_State *L) {
    Proto *proto;
    int hits_idx, result_idx;
    int count = 0;

    luaL_checktype(L, 1, LUA_TFUNCTION);
    luaL_argcheck(L, !lua_iscfunction(L, 1), 1,
        "Lua function expected, got C function");

    proto = get_proto(L, 1);

    lua_rawgetp(L, LUA_REGISTRYINDEX, &PCHOOK_KEY);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
    }
    hits_idx = lua_gettop(L);

    lua_newtable(L);
    result_idx = lua_gettop(L);

    collect_proto_hits(L, proto, hits_idx, result_idx, &count);

    return 1;
}

static int l_reset(lua_State *L) {
    lua_pushnil(L);
    lua_rawsetp(L, LUA_REGISTRYINDEX, &PCHOOK_KEY);
    return 0;
}

static void collect_line_hits(
    lua_State *L,
    Proto *proto,
    int hits_idx,
    int result_idx
) {
    const void *proto_key = (const void *)proto;
    int pc, line, max_line;
    lua_Integer existing, count;
    int i;

    for (pc = 0; pc < proto->sizecode; pc++) {
        line = get_pc_line(proto, pc);
        if (line <= 0) continue;

        lua_rawgeti(L, result_idx, line);
        existing = lua_tointeger(L, -1);
        lua_pop(L, 1);
        if (existing == 0) {
            lua_pushinteger(L, 0);
            lua_rawseti(L, result_idx, line);
        }

        lua_getfield(L, result_idx, "max");
        max_line = (int)lua_tointeger(L, -1);
        lua_pop(L, 1);
        if (line > max_line) {
            lua_pushinteger(L, line);
            lua_setfield(L, result_idx, "max");
        }
    }

    lua_rawgetp(L, hits_idx, proto_key);
    if (!lua_isnil(L, -1)) {
        lua_pushnil(L);
        while (lua_next(L, -2) != 0) {
            int pc1based = (int)lua_tointeger(L, -2);
            count = lua_tointeger(L, -1);
            lua_pop(L, 1);

            line = get_pc_line(proto, pc1based - 1);
            if (line <= 0) continue;

            lua_rawgeti(L, result_idx, line);
            existing = lua_tointeger(L, -1);
            lua_pop(L, 1);

            if (count > existing) {
                lua_pushinteger(L, count);
                lua_rawseti(L, result_idx, line);
            }
        }
    }
    lua_pop(L, 1);

    for (i = 0; i < proto->sizep; i++) {
        collect_line_hits(L, proto->p[i], hits_idx, result_idx);
    }
}

static int l_get_line_hits(lua_State *L) {
    Proto *proto;
    int hits_idx, result_idx;

    luaL_checktype(L, 1, LUA_TFUNCTION);
    luaL_argcheck(L, !lua_iscfunction(L, 1), 1,
        "Lua function expected, got C function");

    proto = get_proto(L, 1);

    lua_rawgetp(L, LUA_REGISTRYINDEX, &PCHOOK_KEY);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        lua_newtable(L);
    }
    hits_idx = lua_gettop(L);

    lua_newtable(L);
    result_idx = lua_gettop(L);

    lua_pushinteger(L, 0);
    lua_setfield(L, result_idx, "max");

    collect_line_hits(L, proto, hits_idx, result_idx);

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

    lua_pushliteral(L, "1.0.0");
    lua_setfield(L, -2, "version");

    return 1;
}
