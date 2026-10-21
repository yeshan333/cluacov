/* Check the VM's frame/GC64 mode using only the public API, before reading
 * internal pointers. Installed luajit.h does not expose this build option. */
#ifndef CLUACOV_LJLAYOUT_H
#define CLUACOV_LJLAYOUT_H
#include <string.h>

typedef struct {
    unsigned char bytes[5];
    size_t used;
} cluacov_dump_header;

static int capture_dump_header(lua_State *L, const void *data, size_t size,
                               void *ud) {
    cluacov_dump_header *header = (cluacov_dump_header *)ud;
    size_t remaining = sizeof(header->bytes) - header->used;
    (void)L;
    if (size > remaining) size = remaining;
    memcpy(header->bytes + header->used, data, size);
    header->used += size;
    return 0;
}

static void check_luajit_layout(lua_State *L) {
    cluacov_dump_header header = {{0}, 0};
    const char source[] = "return 1";
    if (luaL_loadbuffer(L, source, sizeof(source) - 1, "=cluacov layout") != 0)
        lua_error(L);
    if (lua_dump(L, capture_dump_header, &header) != 0 || header.used != 5 ||
        header.bytes[0] != 0x1b || header.bytes[1] != 'L' ||
        header.bytes[2] != 'J' ||
        !!(header.bytes[4] & 0x08) != LJ_FR2) {
        luaL_error(L, "cluacov: incompatible LuaJIT frame/GC64 layout; "
                   "rebuild cluacov with matching LuaJIT build flags");
    }
    lua_pop(L, 1);
}
#endif
