/*
** Minimal CallInfo definition for cluacov.pchook.
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

#endif
