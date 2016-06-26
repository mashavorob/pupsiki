#include <c_ext.h>

#if USE_WIN32

#include <windows.h>
#define DLLEXPORT __declspec(dllexport)

#else
#define DLLEXPORT
#endif

#include <time.h>
#include <lua5.1/lua.h>
#include <lua5.1/lauxlib.h>

#if USE_WIN32

static const double SEC_TO_UNIX_EPOCH = 11644473600.0;

static int l_gettime(lua_State *L)
{
#if 0
    union {
        FILETIME ft;
        ULONGLONG ull;
    } u = {0};
    const double scale = 1.0e9;
    GetSystemTimePreciseAsFileTime(&u.ft);
#elif 0
    union {
        LARGE_INTEGER li;
        ULONGLONG ull;
    } u = {0};
    const double scale = 1.0e7;
    NtQuerySystemTime(&u.li);
#else
    union {
        FILETIME ft;
        ULONGLONG ull;
    } u = {0};
    const double scale = 1.0e7;

    SYSTEMTIME st = {0};
    GetSystemTime(&st);
    SystemTimeToFileTime(&st, &u.ft);

#endif

    const double win32Epoch = ((double)u.ull)/scale;
    const double unixEpoch = win32Epoch - SEC_TO_UNIX_EPOCH;

    lua_pushnumber(L, (lua_Number)(unixEpoch));
    return 1;
}

#else

static int l_gettime(lua_State *L)
{
    struct timespec t;
    clock_gettime(CLOCK_REALTIME, &t);
    lua_pushnumber(L, (lua_Number)t.tv_sec + (lua_Number)(((double)t.tv_nsec)/1.0e9));
    return 1;
}

#endif

static const struct luaL_reg mylib [2] = 
    { {"gettime", l_gettime}
    , {NULL, NULL}  /* sentinel */
    };

DLLEXPORT int luaopen_quik_ext(lua_State *L)
{
    luaL_openlib(L, "quik_ext", mylib, 0);
    return 1;
}
