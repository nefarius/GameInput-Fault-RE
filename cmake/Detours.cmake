include(FetchContent)
# Microsoft Detours v4.0.1, immutable release commit (MIT).
FetchContent_Declare(detours
    GIT_REPOSITORY https://github.com/microsoft/Detours.git
    GIT_TAG e4bfd6b03e50de46b47abfbd1e46b384f0c5f833
    GIT_SHALLOW FALSE)
FetchContent_MakeAvailable(detours)
# Thread/operation records must not use the process CRT heap while target
# threads are suspended. Apply an exact, reviewable allocation-only patch to
# the pinned source in the build tree. The upstream checkout is left intact.
file(READ "${detours_SOURCE_DIR}/src/detours.cpp" detours_core)
string(REPLACE "\r\n" "\n" detours_core "${detours_core}")
set(record_allocator "    static void* operator new(size_t bytes) noexcept { return VirtualAlloc(NULL, bytes, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE); }\n    static void operator delete(void* p) noexcept { if (p) VirtualFree(p, 0, MEM_RELEASE); }\n")
foreach(record IN ITEMS DetourThread DetourOperation)
    set(needle "struct ${record}\n{\n")
    string(FIND "${detours_core}" "${needle}" record_offset)
    if(record_offset EQUAL -1)
        message(FATAL_ERROR "Pinned Detours allocation patch no longer matches ${record}")
    endif()
    string(REPLACE "${needle}" "${needle}${record_allocator}" detours_core "${detours_core}")
endforeach()
file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/detours-patched")
file(WRITE "${CMAKE_BINARY_DIR}/detours-patched/detours.cpp" "${detours_core}")
add_library(detours STATIC
    ${CMAKE_BINARY_DIR}/detours-patched/detours.cpp
    ${detours_SOURCE_DIR}/src/modules.cpp
    ${detours_SOURCE_DIR}/src/disasm.cpp
    ${detours_SOURCE_DIR}/src/image.cpp
    ${detours_SOURCE_DIR}/src/creatwth.cpp)
target_include_directories(detours PUBLIC ${detours_SOURCE_DIR}/src)
target_compile_definitions(detours PRIVATE WIN32_LEAN_AND_MEAN _WIN32_WINNT=0x0A00)
file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/licenses")
configure_file(${detours_SOURCE_DIR}/LICENSE.md ${CMAKE_BINARY_DIR}/licenses/Detours-LICENSE.md COPYONLY)
install(FILES ${detours_SOURCE_DIR}/LICENSE.md DESTINATION licenses RENAME Detours-LICENSE.md)
