# The C++ wrapper's own tests. Not needed to *use* the headers -- a customer links
# cadaclysm::reader / cadaclysm::blacksmith from cmake/cadaclysmConfig.cmake instead.
cmake_minimum_required(VERSION 3.16)
project(cadaclysm_cpp LANGUAGES CXX)

if(NOT DEFINED CMAKE_CXX_STANDARD)
  set(CMAKE_CXX_STANDARD 17)
endif()
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
option(CADACLYSM_NO_EXCEPTIONS "Build everything here with exceptions off" OFF)

if(MSVC)
  add_compile_options(/W4 /WX /permissive- /utf-8)
  if(CADACLYSM_NO_EXCEPTIONS)
    add_compile_options(/EHs-c-)
    add_compile_definitions(_HAS_EXCEPTIONS=0)
  else()
    add_compile_options(/EHsc)
  endif()
else()
  add_compile_options(-Wall -Wextra -Wpedantic -Werror)
  if(CADACLYSM_NO_EXCEPTIONS)
    add_compile_options(-fno-exceptions)
  endif()
endif()

enable_testing()
set(CADACLYSM_CPP_INCLUDE "${CMAKE_CURRENT_SOURCE_DIR}/include")

add_executable(cadaclysm_result_test tests/result_test.cpp)
target_include_directories(cadaclysm_result_test PRIVATE "${CADACLYSM_CPP_INCLUDE}")
add_test(NAME result COMMAND cadaclysm_result_test)

# Each header compiles on its own, in its own translation unit.
add_library(cadaclysm_header_result OBJECT tests/include_result.cpp)
target_include_directories(cadaclysm_header_result PRIVATE "${CADACLYSM_CPP_INCLUDE}")

# ---- against the built libraries ------------------------------------------------------
set(CADACLYSM_LIBRARY_DIR "" CACHE PATH
    "A cargo target directory holding cadaclysm_capi and cadaclysm_blacksmith (e.g. target/release)")
set(_cadaclysm_sample "${CMAKE_CURRENT_SOURCE_DIR}/../../../../samples/cube.scad")
if(NOT EXISTS "${_cadaclysm_sample}")
  set(_cadaclysm_sample "")
endif()
set(CADACLYSM_SAMPLE "${_cadaclysm_sample}" CACHE FILEPATH "The file the smoke opens")
set(CADACLYSM_LICENSE "" CACHE FILEPATH "A license file for the smoke, or empty")

if(CADACLYSM_LIBRARY_DIR)
  if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../../include/cadaclysm.h")
    set(_cadaclysm_c_headers "${CMAKE_CURRENT_SOURCE_DIR}/../../include"
                             "${CMAKE_CURRENT_SOURCE_DIR}/../../../cadaclysm-blacksmith-capi/include")
  else()  # the SDK repository: cpp/ sits beside include/
    set(_cadaclysm_c_headers "${CMAKE_CURRENT_SOURCE_DIR}/../include")
  endif()
  set(CADACLYSM_INCLUDE_DIRS "${CADACLYSM_CPP_INCLUDE}" ${_cadaclysm_c_headers})
  include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/cadaclysmConfig.cmake")
  find_package(Threads REQUIRED)

  # The smoke twice: checked (the stale-view traps run) and unchecked (the release
  # layout of every class compiles and passes the same scenario).
  function(cadaclysm_smoke name checked)
    add_executable(${name} smoke.cpp)
    target_compile_definitions(${name} PRIVATE CADACLYSM_CHECKED=${checked})
    target_link_libraries(${name} PRIVATE cadaclysm::blacksmith Threads::Threads)
    # Windows finds a DLL beside the executable; elsewhere this is harmless.
    add_custom_command(TARGET ${name} POST_BUILD
      COMMAND "${CMAKE_COMMAND}" -E copy_if_different
              "$<TARGET_FILE:cadaclysm::reader>" "$<TARGET_FILE:cadaclysm::blacksmith>"
              "$<TARGET_FILE_DIR:${name}>")
    if(CADACLYSM_SAMPLE)
      add_test(NAME ${name} COMMAND ${name} "${CADACLYSM_SAMPLE}" ${CADACLYSM_LICENSE})
    endif()
  endfunction()
  cadaclysm_smoke(cadaclysm_smoke 1)
  cadaclysm_smoke(cadaclysm_smoke_fast 0)

  add_library(cadaclysm_header_reader OBJECT tests/include_reader.cpp)
  target_link_libraries(cadaclysm_header_reader PRIVATE cadaclysm::reader)

  add_library(cadaclysm_header_kernel OBJECT tests/include_kernel.cpp)
  target_link_libraries(cadaclysm_header_kernel PRIVATE cadaclysm::blacksmith)

  # What a user's code compiles, with the default hook: Release builds catch the
  # optimiser-only warnings in it.
  add_library(cadaclysm_user_calls OBJECT tests/user_calls.cpp)
  target_link_libraries(cadaclysm_user_calls PRIVATE cadaclysm::blacksmith)
endif()
