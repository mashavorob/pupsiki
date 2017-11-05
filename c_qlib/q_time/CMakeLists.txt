project(q_time)


# platform specific configuration
if(${CMAKE_SYSTEM_NAME} MATCHES "Windows")
    set(PALTFORM_LIBRARIES ntdll.dll)
else()
    set(PALTFORM_LIBRARIES "")
endif()

include_directories (
    ${LUA_INCLUDE_DIR}
    ${CMAKE_BINARY_DIR}
    ${CMAKE_SOURCE_DIR}
    )

add_library(
    q_time SHARED
    q_time.cpp
    gettime.cpp
    )

target_link_libraries(
    q_time
    ${PALTFORM_LIBRARIES}
    ${LUA_LIBRARIES}
    )

install(TARGETS
    q_time
    DESTINATION "${CMAKE_SOURCE_DIR}/.."
    )
