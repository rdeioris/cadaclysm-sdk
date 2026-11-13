# cadaclysmConfig.cmake -- imported targets cadaclysm::cadaclysm, cadaclysm::reader, cadaclysm::blacksmith, cadaclysm::view_loader and,
# where the library is there, cadaclysm::view.
#
# In a release archive this file sits at lib/cmake/cadaclysm/ and finds lib/ and
# include/ from there:  cmake -DCMAKE_PREFIX_PATH=<unzipped archive>  then
#   find_package(cadaclysm CONFIG REQUIRED)
#   target_link_libraries(app PRIVATE cadaclysm::blacksmith)   # or cadaclysm::reader
#   target_link_libraries(app PRIVATE cadaclysm::view)       # the viewer; brings the reader
#   target_link_libraries(app PRIVATE cadaclysm::view_loader)  # cadaclysm/view.hpp: opens the view library at run time
#
# Against a cargo target directory instead, set CADACLYSM_LIBRARY_DIR (the directory
# holding the built libraries) and CADACLYSM_INCLUDE_DIRS before including this file,
# as examples/cpp/CMakeLists.txt does. Neither is set or changed here: what this file
# works with is private (_cadaclysm_*) and unset again at the end.
#
# CADACLYSM_FLAVOUR picks the library every target links:
#   full      (the default) cadaclysm, the reader and the kernel in one library: cadaclysm::reader,
#             cadaclysm::blacksmith and cadaclysm::cadaclysm all name it;
#   reader    cadaclysm_reader, the reader alone: cadaclysm::reader and cadaclysm::cadaclysm name
#             it, and linking cadaclysm::blacksmith fails to generate;
#   kernel-reader  cadaclysm_kernel_reader, under the same three names as full; a kernel
#             writer or parts call the flavour leaves out fails to link;
#   kernel    cadaclysm_kernel: cadaclysm::blacksmith and cadaclysm::cadaclysm name it, and
#             linking cadaclysm::reader (or cadaclysm::view, which needs the reader) fails;
#   separate  cadaclysm_capi and cadaclysm_blacksmith, the two libraries of earlier releases;
#             cadaclysm::cadaclysm links both.
# The default is full, or in a release archive that archive's own flavour (archive.py stamps
# _cadaclysm_default_flavour below). cadaclysm_FLAVOUR is set to the one in use.
if(TARGET cadaclysm::reader)
  return()
endif()

set(_cadaclysm_default_flavour full)
if(NOT CADACLYSM_FLAVOUR)
  set(_cadaclysm_flavour "${_cadaclysm_default_flavour}")
elseif(CADACLYSM_FLAVOUR MATCHES "^(full|kernel-reader|kernel|reader|separate)$")
  set(_cadaclysm_flavour "${CADACLYSM_FLAVOUR}")
else()
  message(FATAL_ERROR "cadaclysm: CADACLYSM_FLAVOUR=${CADACLYSM_FLAVOUR}: use full, kernel-reader, kernel, reader or separate (default ${_cadaclysm_default_flavour})")
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

function(_cadaclysm_paths stem out_library out_implib)
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
    set(_implib "")
  else()
    set(_library "${_cadaclysm_library_dir}/lib${stem}.so")
    set(_implib "")
  endif()
  set(${out_library} "${_library}" PARENT_SCOPE)
  set(${out_implib} "${_implib}" PARENT_SCOPE)
endfunction()

function(_cadaclysm_add target library implib)
  add_library(${target} SHARED IMPORTED GLOBAL)
  set_target_properties(${target} PROPERTIES
    IMPORTED_LOCATION "${library}"
    INTERFACE_INCLUDE_DIRECTORIES "${_cadaclysm_include_dirs}"
    INTERFACE_COMPILE_FEATURES cxx_std_17)
  if(WIN32)
    set_target_properties(${target} PROPERTIES IMPORTED_IMPLIB "${implib}")
  elseif(NOT APPLE)
    # The libraries carry no SONAME: link by name, so the executable records
    # libcadaclysm_capi.so rather than the absolute path it was linked from.
    set_target_properties(${target} PROPERTIES IMPORTED_NO_SONAME TRUE)
  endif()
endfunction()

# A library every archive has: missing is an error.
function(_cadaclysm_import target stem)
  _cadaclysm_paths(${stem} _library _implib)
  if(NOT EXISTS "${_library}")
    message(FATAL_ERROR "cadaclysm: ${_library} not found -- set CADACLYSM_LIBRARY_DIR or CMAKE_PREFIX_PATH")
  endif()
  _cadaclysm_add(${target} "${_library}" "${_implib}")
endfunction()

# A library a cargo target folder may not have built (the view): imported where it is.
function(_cadaclysm_import_optional target stem)
  _cadaclysm_paths(${stem} _library _implib)
  if(EXISTS "${_library}")
    _cadaclysm_add(${target} "${_library}" "${_implib}")
  endif()
endfunction()

if(_cadaclysm_flavour STREQUAL "full" OR _cadaclysm_flavour STREQUAL "kernel-reader")
  # One file under every name, so $<TARGET_FILE:...> of any of them is the library to stage.
  if(_cadaclysm_flavour STREQUAL "full")
    set(_cadaclysm_stem cadaclysm)
  else()
    set(_cadaclysm_stem cadaclysm_kernel_reader)
  endif()
  _cadaclysm_import(cadaclysm::cadaclysm ${_cadaclysm_stem})
  _cadaclysm_import(cadaclysm::reader ${_cadaclysm_stem})
  _cadaclysm_import(cadaclysm::blacksmith ${_cadaclysm_stem})
elseif(_cadaclysm_flavour STREQUAL "kernel")
  _cadaclysm_import(cadaclysm::cadaclysm cadaclysm_kernel)
  _cadaclysm_import(cadaclysm::blacksmith cadaclysm_kernel)
  # The refusal: generating anything that links this names the missing target below.
  add_library(cadaclysm::reader INTERFACE IMPORTED GLOBAL)
  set_target_properties(cadaclysm::reader PROPERTIES INTERFACE_LINK_LIBRARIES
    cadaclysm::the_kernel_flavour_has_no_reader__configure_with_CADACLYSM_FLAVOUR_full)
elseif(_cadaclysm_flavour STREQUAL "reader")
  _cadaclysm_import(cadaclysm::cadaclysm cadaclysm_reader)
  _cadaclysm_import(cadaclysm::reader cadaclysm_reader)
  # The refusal: generating anything that links this names the missing target below.
  add_library(cadaclysm::blacksmith INTERFACE IMPORTED GLOBAL)
  set_target_properties(cadaclysm::blacksmith PROPERTIES INTERFACE_LINK_LIBRARIES
    cadaclysm::the_reader_flavour_has_no_kernel__configure_with_CADACLYSM_FLAVOUR_full)
else()
  _cadaclysm_import(cadaclysm::reader cadaclysm_capi)
  _cadaclysm_import(cadaclysm::blacksmith cadaclysm_blacksmith)
  set_property(TARGET cadaclysm::blacksmith APPEND PROPERTY INTERFACE_LINK_LIBRARIES cadaclysm::reader)
  # The separate libraries export no cadaclysm_flavour(): the headers answer for them.
  set_property(TARGET cadaclysm::reader APPEND PROPERTY INTERFACE_COMPILE_DEFINITIONS CADACLYSM_SEPARATE)
  add_library(cadaclysm::cadaclysm INTERFACE IMPORTED GLOBAL)
  set_target_properties(cadaclysm::cadaclysm PROPERTIES INTERFACE_LINK_LIBRARIES cadaclysm::blacksmith)
endif()
set(cadaclysm_FLAVOUR "${_cadaclysm_flavour}")
# The viewer reads scenes through the reader the process has loaded: link both.
_cadaclysm_import_optional(cadaclysm::view cadaclysm_view)
if(TARGET cadaclysm::view)
  set_property(TARGET cadaclysm::view APPEND PROPERTY INTERFACE_LINK_LIBRARIES cadaclysm::reader)
endif()
# cadaclysm/view.hpp, the C++ view wrapper: it opens the view library (the terminal, wgpu,
# any other) at run time, so it links none -- only the platform's dlopen. Where to look is
# compiled in: this package's library directory, after the reader's and the executable's.
# cadaclysm::view above stays the linked C library, for a host that calls cadaclysm_view.h.
# The directory goes into a C string literal: forward slashes, so no backslash escapes.
file(TO_CMAKE_PATH "${_cadaclysm_library_dir}" _cadaclysm_view_dir)
add_library(cadaclysm::view_loader INTERFACE IMPORTED GLOBAL)
set_target_properties(cadaclysm::view_loader PROPERTIES
  INTERFACE_INCLUDE_DIRECTORIES "${_cadaclysm_include_dirs}"
  INTERFACE_COMPILE_FEATURES cxx_std_17
  INTERFACE_COMPILE_DEFINITIONS "CADACLYSM_VIEW_LIBRARY_DIR=\"${_cadaclysm_view_dir}\""
  INTERFACE_LINK_LIBRARIES "${CMAKE_DL_LIBS}")
set(cadaclysm_FOUND TRUE)
unset(_cadaclysm_flavour)
unset(_cadaclysm_prefix)
unset(_cadaclysm_library_dir)
unset(_cadaclysm_view_dir)
unset(_cadaclysm_include_dirs)
unset(_cadaclysm_default_flavour)
unset(_cadaclysm_stem)
