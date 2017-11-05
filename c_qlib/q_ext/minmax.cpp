#include "minmax.h"

#include <defs.h>

#include <lauxlib.h>
#include <cstdio>


void Minmax::add(const double t, const double v)
{
    value val = { t, v };
    minmax_iterator iter = minmax.insert(val);
    history.push_back(iter);

    while ( history.size() > 1 && t - history.front()->time > limit )
    {
        minmax.erase( history.front() );
        history.erase( history.begin() );
    }
}

double Minmax::getMin() const
{
    if ( minmax.empty() )
    {
        return 0.;
    }
    return minmax.begin()->value;
}

double Minmax::getMax() const
{
    if ( minmax.empty() )
    {
        return 0.;
    }
    return minmax.rbegin()->value;
}

namespace {

int l_add(lua_State *L);
int l_getmin(lua_State *L);
int l_getmax(lua_State *L);
int l_tostring(lua_State *L);
int l_gc(lua_State *L);

const char* MINMAX_M = "q_ext.Minmax";

const struct luaL_Reg minmax_m [] = 
    { {"add", l_add }
    , {"getmin", l_getmin }
    , {"getmax", l_getmax }
    , {"getmax", l_getmax }
    , {"__tostring", l_tostring }
    , {"__gc", l_gc }
    , {NULL, NULL}
    };

Minmax* check_minmax(lua_State *L)
{
    void *p = luaL_checkudata(L, 1, MINMAX_M);
    return reinterpret_cast<Minmax*>(p);
}

int l_add(lua_State *L)
{
    Minmax* p = check_minmax(L);
    const double t = luaL_checknumber(L, 2);
    const double v = luaL_checknumber(L, 3);
    p->add(t, v);
    return 0;
}

int l_getmin(lua_State *L)
{
    Minmax* p = check_minmax(L);
    const double v = p->getMin();
    lua_pushnumber(L, v);
    return 1;
}

int l_getmax(lua_State *L)
{
    Minmax* p = check_minmax(L);
    const double v = p->getMax();
    lua_pushnumber(L, v);
    return 1;
}

int l_tostring(lua_State *L)
{
    Minmax* p = check_minmax(L);
    char buff[64] = { 0 };
    snprintf(buff, sizeof(buff), "%s: 0x%p", MINMAX_M, p);
    lua_pushstring(L, buff);
    return 1;
}

int l_gc(lua_State *L)
{
    Minmax* p = check_minmax(L);
    p->~Minmax();
    return 0;
}

}

void open_minmax(lua_State* L)
{
    luaL_newmetatable(L, MINMAX_M);
    /* metatable.__index = metatable */
    lua_pushvalue(L, -1); /* duplicates the metatable */
    lua_setfield(L, -2, "__index");
#if LUA_VERSION_NUMBER >= 5002000
    luaL_setfuncs(L, minmax_m, 0);
#else
    luaL_register(L, NULL, minmax_m);
#endif
}

int l_newminmax(lua_State *L)
{
    const double limit = luaL_checknumber(L, 1);
    void* p = lua_newuserdata(L, sizeof(Minmax));
    
    luaL_getmetatable(L, MINMAX_M);
    lua_setmetatable(L, -2);
    
    new (p) Minmax(limit);
    return 1;
}
