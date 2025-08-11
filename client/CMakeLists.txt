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

# Copy assets to output directory
add_custom_command(TARGET CardinalClient POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory
    ${CMAKE_SOURCE_DIR}/assets
    $<TARGET_FILE_DIR:CardinalClient>/assets
    COMMENT "Copying assets to client output directory"
)