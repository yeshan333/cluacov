/* LuaJIT 2.1 adapters. Runtime identity is a GC-managed prototype, while
 * signatures only match records against a reloaded source file. */
#ifndef CLUACOV_LJPROTO_H
#define CLUACOV_LJPROTO_H

#include <stdlib.h>
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
#include "ljlayout.h"

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

/* TDUP constants are literal table templates. Their hash node order is not
 * part of the source, so sort keys before serializing the primitive entries. */
static int compare_template_keys(const void *left, const void *right) {
    const TValue *a = &(*(const Node *const *)left)->key;
    const TValue *b = &(*(const Node *const *)right)->key;
    if (itype(a) != itype(b)) return itype(a) < itype(b) ? -1 : 1;
    if (tvisstr(a)) {
        const GCstr *sa = strV(a), *sb = strV(b);
        size_t n = sa->len < sb->len ? sa->len : sb->len;
        int order = memcmp(strdata(sa), strdata(sb), n);
        return order ? order : (sa->len > sb->len) - (sa->len < sb->len);
    }
    if (tvisnumber(a)) {
        lua_Number na = numberVnum(a), nb = numberVnum(b);
        return (na > nb) - (na < nb);
    }
    return 0;  /* A primitive boolean key is identified by its tag. */
}

static void add_template_value(luaL_Buffer *buffer, const TValue *value) {
    luaL_addchar(buffer, (char)itype(value));
    if (tvisstr(value)) {
        const GCstr *str = strV(value);
        luaL_addlstring(buffer, (const char *)&str->len, sizeof(str->len));
        luaL_addlstring(buffer, strdata(str), str->len);
    } else if (tvisnumber(value)) {
        lua_Number n = numberVnum(value);
        luaL_addlstring(buffer, (const char *)&n, sizeof(n));
    }
}

static void push_template_signature(lua_State *L, const GCtab *table) {
    luaL_Buffer buffer;
    uint32_t i, count = 0;
    int storage = lua_gettop(L) + 1;
    /* Lua owns this temporary workspace, including on allocation errors.
     * The caller's live prototype roots every key and value while sorting. */
    const Node **nodes = (const Node **)lua_newuserdata(L,
        ((size_t)table->hmask + 1) * sizeof(Node *));
    for (i = 0; i <= table->hmask; i++) {
        const Node *node = noderef(table->node) + i;
        if (!tvisnil(&node->val)) nodes[count++] = node;
    }
    qsort(nodes, count, sizeof(Node *), compare_template_keys);
    luaL_buffinit(L, &buffer);
    luaL_addlstring(&buffer, (const char *)&table->asize, sizeof(table->asize));
    for (i = 0; i < table->asize; i++)
        add_template_value(&buffer, &tvref(table->array)[i]);
    luaL_addlstring(&buffer, (const char *)&count, sizeof(count));
    for (i = 0; i < count; i++) {
        add_template_value(&buffer, &nodes[i]->key);
        add_template_value(&buffer, &nodes[i]->val);
    }
    luaL_pushresult(&buffer);
    lua_remove(L, storage);
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
        } else if (gc->gch.gct == (uint8_t)~LJ_TTAB) {
            push_template_signature(L, &gc->tab);
            luaL_addvalue(&buffer);
        } else if (gc->gch.gct == (uint8_t)~LJ_TCDATA) {
            /* LuaJIT bytecode permits only int64, uint64, and complex double
             * cdata literals (lj_bcwrite.c). These predefined CType IDs are
             * 11/12 for integers. Complex double is 16 in beta3/older 2.1,
             * or 18 after INT128/UINT128 were added to lj_ctype.h CTTYDEF.
             * No other cdata type can occur in a stock bytecode constant. */
            const GCcdata *cd = &gc->cd;
            size_t size;
            if (cd->ctypeid == 11 || cd->ctypeid == 12) size = 8;
            else if (cd->ctypeid == 16 || cd->ctypeid == 18) size = 16;
            else {
                luaL_error(L, "cluacov: unsupported LuaJIT cdata constant type");
                return;
            }
            luaL_addlstring(&buffer, (const char *)&cd->ctypeid, sizeof(cd->ctypeid));
            luaL_addlstring(&buffer, (const char *)cdataptr(cd), size);
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
