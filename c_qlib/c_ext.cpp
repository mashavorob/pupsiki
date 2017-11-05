#include "defs.h"
#include "gettime.h"
#include "minmax.h"

#include <lua.h>
#include <lauxlib.h>


namespace {

int l_gettransid(lua_State *L)
{
    static volatile unsigned transId = 0;
    lua_pushnumber(L, (lua_Number)(++transId));
    return 1;
}

const struct luaL_Reg mylib [] =
    { {"gettime", l_gettime }
    , {"gettransid", l_gettransid }
    , {"newminmax", l_newminmax }
    , {NULL, NULL}  /* sentinel */
    };

}

DLLEXPORT int luaopen_quik_ext(lua_State *L)
{
    std::cout <<"luaopen_quik_ext" << std::endl;
    open_minmax(L);
#if LUA_VERSION_NUMBER >= 5002000
    luaL_newlib(L, mylib);
#else
    luaL_register(L, "quik_ext", mylib);
#endif
    return 1;
}
