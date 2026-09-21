# cadaclysmConfig.cmake -- imported targets cadaclysm::reader and cadaclysm::blacksmith.
#
# In a release archive this file sits at lib/cmake/cadaclysm/ and finds lib/ and
# include/ from there:  cmake -DCMAKE_PREFIX_PATH=<unzipped archive>  then
#   find_package(cadaclysm CONFIG REQUIRED)
#   target_link_libraries(app PRIVATE cadaclysm::blacksmith)   # or cadaclysm::reader
#
# Against a cargo target directory instead, set CADACLYSM_LIBRARY_DIR (the directory
# holding the built libraries) and CADACLYSM_INCLUDE_DIRS before including this file,
# as examples/cpp/CMakeLists.txt does. Neither is set or changed here: what this file
# works with is private (_cadaclysm_*) and unset again at the end.
if(TARGET cadaclysm::reader)
  return()
endif()

get_filename_component(_cadaclysm_prefix "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
if(CADACLYSM_LIBRARY_DIR)
  set(_cadaclysm_library_dir "${CADACLYSM_LIBRARY_DIR}")
else()
  set(_cadaclysm_library_dir "${_cadaclysm_prefix}/lib")
endif()
if(CADACLYSM_INCLUDE_DIRS)
  set(_cadaclysm_include_dirs "${CADACLYSM_INCLUDE_DIRS}")
else()
  set(_cadaclysm_include_dirs "${_cadaclysm_prefix}/include")
endif()

function(_cadaclysm_import target stem)
  if(WIN32)
    set(_library "${_cadaclysm_library_dir}/${stem}.dll")
    # cargo names the import library <stem>.dll.lib and writes a *static* <stem>.lib
    # beside it; the release archive renames the import library to <stem>.lib and
    # ships no static one. Prefer .dll.lib wherever it exists.
    if(EXISTS "${_cadaclysm_library_dir}/${stem}.dll.lib")
      set(_implib "${_cadaclysm_library_dir}/${stem}.dll.lib")
    else()
      set(_implib "${_cadaclysm_library_dir}/${stem}.lib")
    endif()
  elseif(APPLE)
    set(_library "${_cadaclysm_library_dir}/lib${stem}.dylib")
  else()
    set(_library "${_cadaclysm_library_dir}/lib${stem}.so")
  endif()
  if(NOT EXISTS "${_library}")
    message(FATAL_ERROR "cadaclysm: ${_library} not found -- set CADACLYSM_LIBRARY_DIR or CMAKE_PREFIX_PATH")
  endif()
  add_library(${target} SHARED IMPORTED GLOBAL)
  set_target_properties(${target} PROPERTIES
    IMPORTED_LOCATION "${_library}"
    INTERFACE_INCLUDE_DIRECTORIES "${_cadaclysm_include_dirs}"
    INTERFACE_COMPILE_FEATURES cxx_std_17)
  if(WIN32)
    set_target_properties(${target} PROPERTIES IMPORTED_IMPLIB "${_implib}")
  elseif(NOT APPLE)
    # The libraries carry no SONAME: link by name, so the executable records
    # libcadaclysm_capi.so rather than the absolute path it was linked from.
    set_target_properties(${target} PROPERTIES IMPORTED_NO_SONAME TRUE)
  endif()
endfunction()

_cadaclysm_import(cadaclysm::reader cadaclysm_capi)
_cadaclysm_import(cadaclysm::blacksmith cadaclysm_blacksmith)
set_property(TARGET cadaclysm::blacksmith APPEND PROPERTY INTERFACE_LINK_LIBRARIES cadaclysm::reader)
set(cadaclysm_FOUND TRUE)
unset(_cadaclysm_prefix)
unset(_cadaclysm_library_dir)
unset(_cadaclysm_include_dirs)
