# Cardinal Client Application
add_executable(CardinalClient
    src/main.c
)

target_link_libraries(CardinalClient PRIVATE cardinal_engine)

if(MSVC)
    target_compile_options(CardinalClient PRIVATE /W4)
else()
    target_compile_options(CardinalClient PRIVATE -Wall -Wextra -Wpedantic)
endif()