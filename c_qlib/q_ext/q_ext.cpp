#include "defs.h"
#include "getransid.h"
#include "minmax.h"

#include <lua.h>
#include <lauxlib.h>


namespace {

const struct luaL_Reg mylib [] =
    , {"gettransid", l_gettransid }
    , {"Minmax",  l_newminmax }
    , {NULL, NULL}
    };

}

DLLEXPORT int luaopen_q_alg(lua_State *L)
{
    open_minmax(L);
#if LUA_VERSION_NUMBER >= 5002000
    luaL_newlib(L, mylib);
#else
    luaL_register(L, "q_ext", mylib);
#endif
    return 1;
}
