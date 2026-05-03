#include "lua.h"
#include "lauxlib.h"

#if LUA_VERSION_NUM > 501 || defined(LUAI_BITSINT)
#define PUCRIOLUA
#endif

#ifndef lua_absindex
#define lua_absindex(L, idx) \
    ((idx) > 0 || (idx) <= LUA_REGISTRYINDEX ? (idx) : lua_gettop(L) + (idx) + 1)
#endif

#ifdef PUCRIOLUA
#if LUA_VERSION_NUM == 501
#include "lua51/lobject.h"
#include "lua51/lopcodes.h"
#elif LUA_VERSION_NUM == 502
#include "lua52/lobject.h"
#include "lua52/lopcodes.h"
#elif LUA_VERSION_NUM == 503
#include "lua53/lobject.h"
#include "lua53/lopcodes.h"
#elif LUA_VERSION_NUM == 504
#include "lua54/lobject.h"
#include "lua54/lopcodes.h"
#elif LUA_VERSION_NUM == 505
#include "lua55/lobject.h"
#include "lua55/lopcodes.h"
#else
#error unsupported Lua version
#endif
#else /* LuaJIT */
#include "luajit.h"
#if LUAJIT_VERSION_NUM == 20199
#include "lj2/lua_assert.h"
#include "lj2/lj_obj.h"
#elif LUAJIT_VERSION_NUM == 20100
#include "luajit-2.1.0-beta3/lua_assert.h"
#include "luajit-2.1.0-beta3/lj_obj.h"
#else
#error unsupported LuaJIT version
#endif
#endif

#ifdef PUCRIOLUA

static Proto *get_proto(lua_State *L) {
    return ((Closure *) lua_topointer(L, 1))->l.p;
}

#if LUA_VERSION_NUM >= 504

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
        lua_assert(i < 0 ||
            (i < f->sizeabslineinfo && f->abslineinfo[i].pc <= pc));
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

#else

static int luaG_getfuncline(const Proto *f, int pc) {
    if (f->lineinfo == NULL) {
        return -1;
    }

    return f->lineinfo[pc];
}

#endif

static int get_pc_line(const Proto *proto, int pc) {
    if (pc < 0 || pc >= proto->sizecode) {
        return 0;
    }

    return luaG_getfuncline(proto, pc);
}

static int get_jump_target_pc(int pc, Instruction instruction) {
#if LUA_VERSION_NUM >= 504
    return pc + 1 + GETARG_sJ(instruction);
#else
    return pc + 1 + GETARG_sBx(instruction);
#endif
}

static void push_target(lua_State *L, const Proto *proto, int pc) {
    lua_newtable(L);

    lua_pushinteger(L, pc + 1);
    lua_setfield(L, -2, "pc");

    lua_pushinteger(L, get_pc_line(proto, pc));
    lua_setfield(L, -2, "line");
}

static void add_branch_site(
    lua_State *L,
    const Proto *proto,
    int result_index,
    int *count,
    int pc,
    const char *kind,
    int first_target_pc,
    int second_target_pc
) {
    int line = get_pc_line(proto, pc);

    if (line <= 0) {
        return;
    }

    if (first_target_pc < 0 || second_target_pc < 0 ||
        first_target_pc >= proto->sizecode ||
        second_target_pc >= proto->sizecode) {
        return;
    }

    if (second_target_pc < first_target_pc) {
        int swap = first_target_pc;
        first_target_pc = second_target_pc;
        second_target_pc = swap;
    }

    lua_newtable(L);

    lua_pushinteger(L, line);
    lua_setfield(L, -2, "line");

    lua_pushinteger(L, proto->linedefined);
    lua_setfield(L, -2, "linedefined");

    lua_pushinteger(L, proto->lastlinedefined);
    lua_setfield(L, -2, "lastlinedefined");

    lua_pushinteger(L, proto->sizecode);
    lua_setfield(L, -2, "sizecode");

    lua_pushinteger(L, pc + 1);
    lua_setfield(L, -2, "pc");

    lua_pushstring(L, kind);
    lua_setfield(L, -2, "kind");

    lua_newtable(L);
    push_target(L, proto, first_target_pc);
    lua_rawseti(L, -2, 1);
    push_target(L, proto, second_target_pc);
    lua_rawseti(L, -2, 2);
    lua_setfield(L, -2, "targets");

    lua_rawseti(L, result_index, ++(*count));
}

static int is_test_opcode(OpCode opcode) {
    switch (opcode) {
#if LUA_VERSION_NUM >= 504
        case OP_EQK:
        case OP_EQI:
        case OP_LTI:
        case OP_LEI:
        case OP_GTI:
        case OP_GEI:
#endif
        case OP_EQ:
        case OP_LT:
        case OP_LE:
        case OP_TEST:
        case OP_TESTSET:
            return 1;
        default:
            return 0;
    }
}

static void add_branches(lua_State *L, Proto *proto, int result_index, int *count) {
    int pc;

    if (proto->lineinfo == NULL) {
        return;
    }

    for (pc = 0; pc < proto->sizecode; pc++) {
        Instruction instruction = proto->code[pc];
        OpCode opcode = GET_OPCODE(instruction);

        if (is_test_opcode(opcode)) {
            int jump_pc = pc + 1;

            if (jump_pc < proto->sizecode &&
                GET_OPCODE(proto->code[jump_pc]) == OP_JMP) {
                add_branch_site(
                    L,
                    proto,
                    result_index,
                    count,
                    pc,
                    "test",
                    pc + 2,
                    get_jump_target_pc(jump_pc, proto->code[jump_pc])
                );
            }
            continue;
        }

#if LUA_VERSION_NUM >= 504
        if (opcode == OP_FORPREP) {
            add_branch_site(
                L,
                proto,
                result_index,
                count,
                pc,
                "loop-entry",
                pc + 1,
                pc + GETARG_Bx(instruction) + 2
            );
            continue;
        }

        if (opcode == OP_FORLOOP) {
            add_branch_site(
                L,
                proto,
                result_index,
                count,
                pc,
                "loop",
                pc + 1,
                pc + 1 - GETARG_Bx(instruction)
            );
            continue;
        }

        if (opcode == OP_TFORLOOP) {
            /* TFORCALL at pc-1 falls through to TFORLOOP via
               `goto l_tforloop`, bypassing vmfetch.  The count hook
               therefore never fires at TFORLOOP's PC.  Use TFORCALL's
               PC (pc-1) as the branch source so that pchook's recorded
               hit data is found during BRDA generation. */
            add_branch_site(
                L,
                proto,
                result_index,
                count,
                pc - 1,
                "iterator",
                pc + 1,
                pc + 1 - GETARG_Bx(instruction)
            );
            continue;
        }
#else
        if (opcode == OP_FORLOOP) {
            add_branch_site(
                L,
                proto,
                result_index,
                count,
                pc,
                "loop",
                pc + 1,
                pc + 1 + GETARG_sBx(instruction)
            );
            continue;
        }

        if (opcode == OP_TFORLOOP) {
#if LUA_VERSION_NUM == 501
            int jump_pc = pc + 1;

            if (jump_pc < proto->sizecode &&
                GET_OPCODE(proto->code[jump_pc]) == OP_JMP) {
                add_branch_site(
                    L,
                    proto,
                    result_index,
                    count,
                    pc,
                    "iterator",
                    pc + 2,
                    get_jump_target_pc(jump_pc, proto->code[jump_pc])
                );
            }
#else
            /* Lua 5.2/5.3: same issue — TFORCALL at pc-1 does
               `goto l_tforloop`, bypassing vmfetch for TFORLOOP. */
            add_branch_site(
                L,
                proto,
                result_index,
                count,
                pc - 1,
                "iterator",
                pc + 1,
                pc + 1 + GETARG_sBx(instruction)
            );
#endif
            continue;
        }
#endif
    }

    for (pc = 0; pc < proto->sizep; pc++) {
        add_branches(L, proto->p[pc], result_index, count);
    }
}

#else /* LuaJIT */

static GCproto *get_proto(lua_State *L) {
    return funcproto(funcV(L->base));
}

#endif

static int l_deepbranches(lua_State *L) {
    int count = 0;
    int result_index;

    luaL_checktype(L, 1, LUA_TFUNCTION);
    luaL_argcheck(L, !lua_iscfunction(L, 1), 1,
        "Lua function expected, got C function");
    lua_settop(L, 1);
    lua_newtable(L);
    result_index = lua_absindex(L, -1);

#ifdef PUCRIOLUA
    add_branches(L, get_proto(L), result_index, &count);
#else
    (void) get_proto(L);
#endif

    return 1;
}

int luaopen_cluacov_deepbranches(lua_State *L) {
    lua_newtable(L);
    lua_pushliteral(L, "1.0.0");
    lua_setfield(L, -2, "version");
    lua_pushcfunction(L, l_deepbranches);
    lua_setfield(L, -2, "get");
    return 1;
}
