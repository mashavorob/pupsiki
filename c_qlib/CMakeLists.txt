cmake_minimum_required(VERSION 2.8)
project( quik_ext C )

include_directories (
    ${CMAKE_CURRENT_BINARY_DIR} 
    )

if(${CMAKE_SYSTEM_NAME} MATCHES "Windows")
    set(USE_WIN32 1)
    include_directories (
        ${CMAKE_CURRENT_SOURCE_DIR}/../win32-toolchain/include
        )
    link_directories(
        ${CMAKE_CURRENT_SOURCE_DIR}/../win32-toolchain/lib
        )
else()
    set(USE_WIN32 0)
endif()

configure_file("${CMAKE_CURRENT_SOURCE_DIR}/c_ext.h.in" "${CMAKE_CURRENT_BINARY_DIR}/c_ext.h")

add_library( quik_ext SHARED 
    c_ext.c
    )

if(${CMAKE_SYSTEM_NAME} MATCHES "Windows")
    target_link_libraries(
        quik_ext
        ntdll.dll
        lua5.1.dll
        )
endif()

get_property(quik_ext_location TARGET quik_ext PROPERTY LOCATION)

install(FILES
    "${quik_ext_location}" 
    DESTINATION "${CMAKE_CURRENT_SOURCE_DIR}/.."
    )


