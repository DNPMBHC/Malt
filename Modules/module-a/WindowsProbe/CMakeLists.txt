cmake_minimum_required(VERSION 3.20)
project(module_a_windows_probe C)

include(CTest)

add_executable(protocol_abi_test tests/protocol_abi_test.c)
set_target_properties(protocol_abi_test PROPERTIES C_STANDARD 11 C_STANDARD_REQUIRED YES)
add_test(NAME protocol_abi COMMAND protocol_abi_test)

if(WIN32)
    add_executable(module_a_probe client/probe.c)
    target_include_directories(module_a_probe PRIVATE shared)
    target_compile_definitions(module_a_probe PRIVATE WIN32_LEAN_AND_MEAN _WIN32_WINNT=0x0A00)
    target_link_libraries(module_a_probe PRIVATE wintrust)
    set_target_properties(module_a_probe PROPERTIES C_STANDARD 11 C_STANDARD_REQUIRED YES)
endif()
