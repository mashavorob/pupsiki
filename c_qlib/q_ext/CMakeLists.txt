project(q_alg)


include_directories (
    ${LUA_INCLUDE_DIR}
    ${CMAKE_BINARY_DIR}
    ${CMAKE_SOURCE_DIR}
    )

add_library(
    q_ext SHARED
    minmax.cpp
    gettransid.cpp
    )

target_link_libraries(
    q_ext
    ${LUA_LIBRARIES}
    )

install(TARGETS
    q_ext
    DESTINATION "${CMAKE_SOURCE_DIR}/.."
    )
