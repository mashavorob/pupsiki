#include <lua.h>
#include <lauxlib.h>

#include <defs.h>
#include "gettime.h"


namespace {

const struct luaL_Reg mylib [] =
    { {"gettime", l_gettime }
    , {NULL, NULL}  /* sentinel */
    };

}

DLLEXPORT int luaopen_q_time(lua_State *L)
{
#if LUA_VERSION_NUMBER >= 5002000
    luaL_newlib(L, mylib);
#else
    luaL_register(L, "q_time", mylib);
#endif
    return 1;
}
