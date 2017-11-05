#include <c_ext.h>

#if USE_WIN32

#include <windows.h>
#define DLLEXPORT extern "C" __declspec(dllexport)

#else
#define DLLEXPORT extern "C"
#endif
