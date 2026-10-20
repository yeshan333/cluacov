/*
** Minimal state definitions for cluacov.pchook, from Lua 5.4 lstate.h.
** Only fields up to u.l.savedpc need correct layout;
** fields after u are omitted (they differ between 5.4 and 5.5
** but do not affect the offset of savedpc).
**
** Requires lobject.h to be included first (for StkIdRel, Instruction).
*/

#ifndef cluacov_lstate_min_h
#define cluacov_lstate_min_h

#include <signal.h>

typedef struct CallInfo {
    StkIdRel func;
    StkIdRel top;
    struct CallInfo *previous, *next;
    union {
        struct {
            const Instruction *savedpc;
            volatile sig_atomic_t trap;
            int nextraargs;
        } l;
        struct {
            lua_KFunction k;
            ptrdiff_t old_errfunc;
            lua_KContext ctx;
        } c;
    } u;
} CallInfo;

/* Only the prefix through allgc is needed. No allocation or Lua execution
** is allowed while traversing this list. Threads cannot have finalizers,
** so all existing threads (including the main thread) belong to allgc.
*/
typedef struct global_State {
    lua_Alloc frealloc;
    void *ud;
    l_mem totalbytes;
    l_mem GCdebt;
    lu_mem GCestimate;
    lu_mem lastatomic;
    struct {
        TString **hash;
        int nuse;
        int size;
    } strt;
    TValue l_registry;
    TValue nilvalue;
    unsigned int seed;
    lu_byte currentwhite;
    lu_byte gcstate;
    lu_byte gckind;
    lu_byte gcstopem;
    lu_byte genminormul;
    lu_byte genmajormul;
    lu_byte gcstp;
    lu_byte gcemergency;
    lu_byte gcpause;
    lu_byte gcstepmul;
    lu_byte gcstepsize;
    GCObject *allgc;
} global_State;

/* Only the prefix through l_G is needed; do not use sizeof(lua_State). */
struct lua_State {
    CommonHeader;
    lu_byte status;
    lu_byte allowhook;
    unsigned short nci;
    StkIdRel top;
    global_State *l_G;
};

#endif
