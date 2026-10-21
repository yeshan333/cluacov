/* Shared, process-local bytecode signature for matching a reloaded source.
 * Runtime identity is always the actual Proto, never this signature. */
#ifndef CLUACOV_PROTOINFO_H
#define CLUACOV_PROTOINFO_H

static void push_proto_signature(lua_State *L, const Proto *proto) {
    luaL_Buffer buffer;
    int i;
    luaL_buffinit(L, &buffer);
    luaL_addlstring(&buffer, (const char *)proto->code,
                   (size_t)proto->sizecode * sizeof(Instruction));
    for (i = 0; i < proto->sizek; i++) {
        const TValue *value = &proto->k[i];
        luaL_addchar(&buffer, (char)rawtt(value));
        if (ttisstring(value)) {
            const TString *str = (const TString *)val_(value).gc;
            size_t length = tsslen(str);
            luaL_addlstring(&buffer, (const char *)&length, sizeof(length));
            luaL_addlstring(&buffer, getstr(str), length);
        } else if (ttisinteger(value)) {
            lua_Integer number = ivalue(value);
            luaL_addlstring(&buffer, (const char *)&number, sizeof(number));
        } else if (ttisfloat(value)) {
            lua_Number number = fltvalue(value);
            luaL_addlstring(&buffer, (const char *)&number, sizeof(number));
        }
    }
    luaL_pushresult(&buffer);
}

static void set_proto_metadata(lua_State *L, const Proto *proto, const char *path) {
    lua_pushinteger(L, proto->linedefined);
    lua_setfield(L, -2, "linedefined");
    lua_pushinteger(L, proto->lastlinedefined);
    lua_setfield(L, -2, "lastlinedefined");
    lua_pushinteger(L, proto->sizecode);
    lua_setfield(L, -2, "sizecode");
    lua_pushlightuserdata(L, (void *)proto);
    lua_setfield(L, -2, "proto_id");
    if (path != NULL) {
        lua_pushstring(L, path);
        lua_setfield(L, -2, "proto_path");
    }
    push_proto_signature(L, proto);
    lua_setfield(L, -2, "signature");
}

#endif
