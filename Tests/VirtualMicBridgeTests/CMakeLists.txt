cmake_minimum_required(VERSION 3.20)

project(VirtualMicBridgeTests LANGUAGES C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_compile_options(
  -Wall
  -Wextra
  -Wpedantic
  -Werror
)

enable_testing()

add_executable(virtual_mic_bridge_tests
  ../../Sources/VirtualMicBridge/VirtualMicBridge.cpp
  virtual_mic_bridge_tests.cpp
  virtual_mic_bridge_c_smoke.c
)

target_include_directories(virtual_mic_bridge_tests PRIVATE
  ${CMAKE_CURRENT_LIST_DIR}/../../Sources/VirtualMicBridge/include
)

target_compile_definitions(virtual_mic_bridge_tests PRIVATE
  VM_BRIDGE_TESTING
)

add_test(NAME virtual_mic_bridge_tests COMMAND virtual_mic_bridge_tests)
