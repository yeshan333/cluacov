/* LuaJIT tests consume the following JMP inside the VM. ITERN similarly
 * consumes ITERL. Model the outgoing edges visible to count hooks. */
#ifndef CLUACOV_LJBRANCHES_H
#define CLUACOV_LJBRANCHES_H

static void lj_add_branch(lua_State *L, Proto *p, const char *path,
                          int result, int *count, int pc, const char *kind,
                          int first, int second, int alternate) {
    int line = get_pc_line(p, pc - 1), i;
    int targets[2];
    /* An empty conditional may have both outcomes folded to the same PC.
     * There is no distinct control-flow edge to measure in that bytecode. */
    if (line <= 0 || first == second ||
        first >= (int)p->sizebc || second >= (int)p->sizebc)
        return;
    targets[0] = first < second ? first : second;
    targets[1] = first < second ? second : first;
    lua_newtable(L);
    set_proto_metadata(L, p, path);
    lua_pushinteger(L, line);
    lua_setfield(L, -2, "line");
    lua_pushinteger(L, pc);
    lua_setfield(L, -2, "pc");
    lua_pushstring(L, kind);
    lua_setfield(L, -2, "kind");
    if (alternate) {
        lua_pushinteger(L, alternate);
        lua_setfield(L, -2, "entry_pc");
    }
    lua_newtable(L);
    for (i = 0; i < 2; i++) {
        lua_newtable(L);
        lua_pushinteger(L, targets[i]);
        lua_setfield(L, -2, "pc");
        lua_pushinteger(L, targets[i] > 0 ? get_pc_line(p, targets[i] - 1) : line);
        lua_setfield(L, -2, "line");
        lua_rawseti(L, -2, i + 1);
    }
    lua_setfield(L, -2, "targets");
    lua_rawseti(L, result, ++(*count));
}

static int lj_assert_call(const Proto *p, int pc, BCReg reg) {
    int i;
    for (i = pc - 1; i > 0; i--) {
        BCIns ins = proto_bc(p)[i];
        BCOp op = bc_op(ins);
        if (bc_a(ins) != reg) continue;
        if (op == BC_MOV) { reg = bc_d(ins); continue; }
        if (op == BC_GGET) {
            GCobj *gc = proto_kgc(p, -(int)bc_d(ins) - 1);
            return gc->gch.gct == (uint8_t)~LJ_TSTR &&
                strcmp(strdata(&gc->str), "assert") == 0;
        }
        if (op == BC_UGET && proto_uvinfo(p)) {
            const char *name = (const char *)proto_uvinfo(p);
            BCReg uv;
            for (uv = 0; uv < bc_d(ins); uv++) name += strlen(name) + 1;
            return strcmp(name, "assert") == 0;
        }
        return 0;
    }
    return 0;
}

static void add_branches(lua_State *L, Proto *p, int result, int *count,
                          const char *path) {
    int pc, i;
    luaL_checkstack(L, 12, "cluacov prototype nesting too deep");
    for (pc = 1; pc < (int)p->sizebc; pc++) {
        BCIns ins = proto_bc(p)[pc];
        BCOp op = bc_op(ins);
        if (op <= BC_ISF && pc + 1 < (int)p->sizebc &&
            bc_op(proto_bc(p)[pc + 1]) == BC_JMP) {
            lj_add_branch(L, p, path, result, count, pc, "test", pc + 2,
                pc + 2 + (int)bc_j(proto_bc(p)[pc + 1]), 0);
        } else if (op == BC_FORI || op == BC_JFORI) {
            lj_add_branch(L, p, path, result, count, pc, "loop-entry",
                pc + 1, pc + 1 + (int)bc_j(ins), 0);
        } else if (op == BC_FORL || op == BC_IFORL) {
            lj_add_branch(L, p, path, result, count, pc, "loop",
                pc + 1, pc + 1 + (int)bc_j(ins), 0);
        } else if (op == BC_ITERL || op == BC_IITERL) {
            /* Both specialized next() and ordinary Lua/C iterators use one
             * site. The former bypasses ITERL, the latter executes it. */
            lj_add_branch(L, p, path, result, count, pc, "iterator",
                pc + 1, pc + 1 + (int)bc_j(ins), pc - 1);
        } else if ((op == BC_CALL || op == BC_CALLM) &&
                   lj_assert_call(p, pc, bc_a(ins))) {
            lj_add_branch(L, p, path, result, count, pc, "assert",
                -pc, pc + 1, 0);
        }
    }
    for (i = 0; i < proto_child_slots(p); i++) {
        Proto *child = proto_child(p, i);
        if (child) {
            const char *childpath = lua_pushfstring(L, "%s.%d", path, i + 1);
            add_branches(L, child, result, count, childpath);
            lua_pop(L, 1);
        }
    }
}
#endif
