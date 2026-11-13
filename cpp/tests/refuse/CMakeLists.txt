# A project linking cadaclysm::blacksmith under CADACLYSM_FLAVOUR (the flavour_refusal
# tests): the reader flavour has no kernel, so generating this must fail with the
# configuration's own message, and an unknown flavour must stop at the include.
cmake_minimum_required(VERSION 3.16)
project(cadaclysm_refuse LANGUAGES CXX)
include("${CMAKE_CURRENT_SOURCE_DIR}/../../cmake/cadaclysmConfig.cmake")
add_library(cadaclysm_refuse OBJECT ../include_kernel.cpp)
target_link_libraries(cadaclysm_refuse PRIVATE cadaclysm::blacksmith)
