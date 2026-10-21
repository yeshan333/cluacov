/* LuaJIT 2.1 adapters. Runtime identity is a GC-managed prototype, while
 * signatures only match records against a reloaded source file. */
#ifndef CLUACOV_LJPROTO_H
#define CLUACOV_LJPROTO_H

#include "luajit.h"
#if LUAJIT_VERSION_NUM == 20199
#include "lj2/lua_assert.h"
#include "lj2/lj_obj.h"
#include "lj2/lj_bc.h"
#include "lj2/lj_frame.h"
#elif LUAJIT_VERSION_NUM == 20100
#include "luajit-2.1.0-beta3/lua_assert.h"
#include "luajit-2.1.0-beta3/lj_obj.h"
#include "luajit-2.1.0-beta3/lj_bc.h"
#include "luajit-2.1.0-beta3/lj_frame.h"
#else
#error unsupported LuaJIT version
#endif

typedef GCproto Proto;
#define proto_code_count(p) ((int)(p)->sizebc - 1)
#define proto_firstline(p) ((p)->firstline)
#define proto_child_slots(p) ((int)(p)->sizekgc)

static Proto *proto_child(const Proto *p, int i) {
    GCobj *gc = proto_kgc(p, -i - 1);
    return gc->gch.gct == (uint8_t)~LJ_TPROTO ? (Proto *)gc : NULL;
}

/* Public PC keys are 1-based executable instructions. LuaJIT reserves
 * bytecode slot zero for the function header (which has no count event). */
static int get_pc_line(const Proto *p, int pc) {
    const void *lines = proto_lineinfo(p);
    if (!lines || pc < 0 || pc >= proto_code_count(p)) return 0;
    return p->firstline + (p->numline < 256 ? ((const uint8_t *)lines)[pc] :
        p->numline < 65536 ? ((const uint16_t *)lines)[pc] :
        ((const uint32_t *)lines)[pc]);
}

static int proto_has_trace(const Proto *p) {
    int i;
    if (p->trace) return 1;
    for (i = 0; i < proto_child_slots(p); i++) {
        Proto *child = proto_child(p, i);
        if (child && proto_has_trace(child)) return 1;
    }
    return 0;
}

static BCIns canonical_instruction(BCIns ins) {
    BCOp op = bc_op(ins);
    /* Interpreter blacklisting and next() specialization mutate bytecode
     * without changing the source. Normalize both for file matching. */
    if (op == BC_IFORL) op = BC_FORL;
    if (op == BC_IITERL) op = BC_ITERL;
    if (op == BC_ILOOP) op = BC_LOOP;
    if (op == BC_ITERN) op = BC_ITERC;
    if (op == BC_ISNEXT) op = BC_JMP;
    return (ins & ~255u) | op;
}

static void push_proto_signature(lua_State *L, const Proto *p) {
    luaL_Buffer buffer;
    int i;
    luaL_buffinit(L, &buffer);
    for (i = 1; i < (int)p->sizebc; i++) {
        BCIns ins = canonical_instruction(proto_bc(p)[i]);
        luaL_addlstring(&buffer, (const char *)&ins, sizeof(ins));
    }
    for (i = 0; i < (int)p->sizekn; i++) {
        /* Normalize integer/number tags to numeric values. */
        lua_Number n = numberVnum(proto_knumtv(p, i));
        luaL_addlstring(&buffer, (const char *)&n, sizeof(n));
    }
    for (i = 0; i < (int)p->sizekgc; i++) {
        GCobj *gc = proto_kgc(p, -i - 1);
        luaL_addchar(&buffer, gc->gch.gct);
        if (gc->gch.gct == (uint8_t)~LJ_TSTR) {
            GCstr *str = &gc->str;
            luaL_addlstring(&buffer, (const char *)&str->len, sizeof(str->len));
            luaL_addlstring(&buffer, strdata(str), str->len);
        }
    }
    luaL_pushresult(&buffer);
}

static void set_proto_metadata(lua_State *L, const Proto *p, const char *path) {
    lua_pushinteger(L, p->firstline);
    lua_setfield(L, -2, "linedefined");
    lua_pushinteger(L, p->firstline + p->numline);
    lua_setfield(L, -2, "lastlinedefined");
    lua_pushinteger(L, proto_code_count(p));
    lua_setfield(L, -2, "sizecode");
    lua_pushlightuserdata(L, (void *)p);
    lua_setfield(L, -2, "proto_id");
    if (path) {
        lua_pushstring(L, path);
        lua_setfield(L, -2, "proto_path");
    }
    push_proto_signature(L, p);
    lua_setfield(L, -2, "signature");
}

#endif
