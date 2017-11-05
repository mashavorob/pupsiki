cmake_minimum_required(VERSION 2.8)
project( quik_ext )

if(${CMAKE_SYSTEM_NAME} MATCHES "Windows")
    set(USE_WIN32 1)
    include_directories (
        ${CMAKE_CURRENT_SOURCE_DIR}/../win32-toolchain/include
        )
    link_directories(
        ${CMAKE_CURRENT_SOURCE_DIR}/../win32-toolchain/lib
        )
    set(WITH_LUA ${CMAKE_CURRENT_SOURCE_DIR}/../win32-toolchain)
    if(NOT DEFINED LUA_INCLUDE_DIR)
        set(LUA_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../win32-toolchain/lua5.1/include")
        set(LUA_LIBRARIES   "${CMAKE_CURRENT_SOURCE_DIR}/../win32-toolchain/lua5.1/lib/lua5.1.lib")
    endif()
else()
    set(USE_WIN32 0)
endif()

find_package(Lua 5.1 EXACT REQUIRED)
math(EXPR LUA_VERSION_NUMBER "${LUA_VERSION_MAJOR}*1000000 + ${LUA_VERSION_MINOR}*1000 + ${LUA_VERSION_PATCH}")

configure_file("${CMAKE_CURRENT_SOURCE_DIR}/c_ext.h.in" "${CMAKE_CURRENT_BINARY_DIR}/c_ext.h")

add_subdirectory(q_time)
add_subdirectory(q_ext)

