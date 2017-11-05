#include "gettransid.h"

int l_gettransid(lua_State *L)
{
    static volatile unsigned transId = 0;
    lua_pushnumber(L, (lua_Number)(++transId));
    return 1;
}
