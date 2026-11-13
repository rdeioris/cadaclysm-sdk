# The C++ wrapper's own tests. Not needed to *use* the headers -- a customer links
# cadaclysm::reader / cadaclysm::blacksmith from cmake/cadaclysmConfig.cmake instead.
# CADACLYSM_FLAVOUR (full, kernel-reader, reader or separate) picks the library they link, as
# that file says; under reader only the tests that need no kernel are built, and under
# kernel-reader the tests that call a kernel writer it leaves out are not built. The kernel
# flavour has no reader, which most of these tests open files through: it is not built here.
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
    "A cargo target directory holding the library CADACLYSM_FLAVOUR names (e.g. target/release)")
set(_cadaclysm_sample "${CMAKE_CURRENT_SOURCE_DIR}/../../../../samples/cube.scad")
if(NOT EXISTS "${_cadaclysm_sample}")  # the SDK layout: cpp/ sits beside samples/
  set(_cadaclysm_sample "${CMAKE_CURRENT_SOURCE_DIR}/../samples/cube.scad")
endif()
if(NOT EXISTS "${_cadaclysm_sample}")
  set(_cadaclysm_sample "")
endif()
set(CADACLYSM_SAMPLE "${_cadaclysm_sample}" CACHE FILEPATH "The file the smoke opens")
set(CADACLYSM_LICENSE "" CACHE FILEPATH "A license file for the smoke, or empty")

if(CADACLYSM_LIBRARY_DIR)
  if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../../include/cadaclysm.h")
    set(_cadaclysm_c_headers "${CMAKE_CURRENT_SOURCE_DIR}/../../include"
                             "${CMAKE_CURRENT_SOURCE_DIR}/../../../cadaclysm-lib/include"
                             "${CMAKE_CURRENT_SOURCE_DIR}/../../../cadaclysm-blacksmith-capi/include"
                             "${CMAKE_CURRENT_SOURCE_DIR}/../../../cadaclysm-view-capi/include")
  else()  # the SDK repository: cpp/ sits beside include/, which holds cadaclysm_view.h and
          # cadaclysm_flavour.h too
    set(_cadaclysm_c_headers "${CMAKE_CURRENT_SOURCE_DIR}/../include")
  endif()
  set(CADACLYSM_INCLUDE_DIRS "${CADACLYSM_CPP_INCLUDE}" ${_cadaclysm_c_headers})
  include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/cadaclysmConfig.cmake")
  find_package(Threads REQUIRED)

  add_library(cadaclysm_header_reader OBJECT tests/include_reader.cpp)
  target_link_libraries(cadaclysm_header_reader PRIVATE cadaclysm::reader)

  # Scene::links() / joints(): the mechanism facts against samples/mechanism.stp,
  # found beside whichever sample CADACLYSM_SAMPLE names.
  if(CADACLYSM_SAMPLE)
    add_executable(cadaclysm_kinematics_test tests/kinematics_test.cpp)
    target_link_libraries(cadaclysm_kinematics_test PRIVATE cadaclysm::reader)
    add_custom_command(TARGET cadaclysm_kinematics_test POST_BUILD
      COMMAND "${CMAKE_COMMAND}" -E copy_if_different
              "$<TARGET_FILE:cadaclysm::reader>" "$<TARGET_FILE_DIR:cadaclysm_kinematics_test>")
    add_test(NAME kinematics COMMAND cadaclysm_kinematics_test "${CADACLYSM_SAMPLE}")
  endif()

  # view_loader.h alone: the search, its messages, the camera maths and the PNG writer,
  # and cvl_draw_object/cvl_pick over a table of fakes; cvl_open over a stand-in library
  # that answers zero. No view library and no GPU; the build directory is the empty place
  # it searches.
  add_library(cadaclysm_view_loader_fake SHARED tests/view_loader_fake.cpp)
  target_include_directories(cadaclysm_view_loader_fake PRIVATE ${CADACLYSM_INCLUDE_DIRS})
  add_executable(cadaclysm_view_loader_test tests/view_loader_test.cpp)
  target_include_directories(cadaclysm_view_loader_test PRIVATE ${CADACLYSM_INCLUDE_DIRS})
  target_link_libraries(cadaclysm_view_loader_test PRIVATE ${CMAKE_DL_LIBS})
  add_dependencies(cadaclysm_view_loader_test cadaclysm_view_loader_fake)
  add_test(NAME view_loader COMMAND cadaclysm_view_loader_test "${CMAKE_CURRENT_BINARY_DIR}"
                                    "$<TARGET_FILE:cadaclysm_view_loader_fake>")

  # cadaclysm::flavour()/features() and blacksmith::flavour()/features(): the linked library
  # answers for itself, the separate pair as "reader"/"kernel" with no features.
  add_executable(cadaclysm_flavour_test tests/flavour_test.cpp)
  set(_cadaclysm_flavour_files "$<TARGET_FILE:cadaclysm::reader>")
  if(cadaclysm_FLAVOUR STREQUAL "reader")
    target_link_libraries(cadaclysm_flavour_test PRIVATE cadaclysm::reader)
    target_compile_definitions(cadaclysm_flavour_test PRIVATE CADACLYSM_FLAVOUR_TEST_READER)
  else()
    target_link_libraries(cadaclysm_flavour_test PRIVATE cadaclysm::blacksmith)
    list(APPEND _cadaclysm_flavour_files "$<TARGET_FILE:cadaclysm::blacksmith>")
  endif()
  add_custom_command(TARGET cadaclysm_flavour_test POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            ${_cadaclysm_flavour_files} "$<TARGET_FILE_DIR:cadaclysm_flavour_test>")
  add_test(NAME flavour COMMAND cadaclysm_flavour_test ${cadaclysm_FLAVOUR})

  # The configuration's refusals, generated in a project of their own (tests/refuse): an
  # unknown flavour stops at the include; under reader, linking cadaclysm::blacksmith fails
  # to generate, naming the missing kernel.
  set(_cadaclysm_refuse
    "${CMAKE_COMMAND}" -S "${CMAKE_CURRENT_SOURCE_DIR}/tests/refuse" -G "${CMAKE_GENERATOR}"
    "-DCMAKE_CXX_COMPILER=${CMAKE_CXX_COMPILER}" "-DCADACLYSM_LIBRARY_DIR=${CADACLYSM_LIBRARY_DIR}")
  add_test(NAME flavour_unknown COMMAND ${_cadaclysm_refuse}
           -B "${CMAKE_CURRENT_BINARY_DIR}/refuse-unknown" -DCADACLYSM_FLAVOUR=bogus)
  set_tests_properties(flavour_unknown PROPERTIES PASS_REGULAR_EXPRESSION
    "CADACLYSM_FLAVOUR=bogus: use full, kernel-reader, kernel")
  if(cadaclysm_FLAVOUR STREQUAL "reader")
    add_test(NAME flavour_reader_has_no_kernel COMMAND ${_cadaclysm_refuse}
             -B "${CMAKE_CURRENT_BINARY_DIR}/refuse-reader" -DCADACLYSM_FLAVOUR=reader)
    set_tests_properties(flavour_reader_has_no_kernel PROPERTIES PASS_REGULAR_EXPRESSION
      "cadaclysm::the_reader_flavour_has_no_kernel__configure_with_CADACLYSM_FLAVOUR_full")
  endif()

  # Everything below links the kernel, which the reader flavour does not have.
  if(cadaclysm_FLAVOUR STREQUAL "reader")
    return()
  endif()

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

  # The FEM records over rows built by hand: the branches no fixture in this repo
  # reaches. It calls nothing in either library, but it includes both headers, so it
  # links them as the header tests do and takes the DLLs beside it.
  add_executable(cadaclysm_fem_test tests/fem_test.cpp)
  target_link_libraries(cadaclysm_fem_test PRIVATE cadaclysm::blacksmith)
  add_custom_command(TARGET cadaclysm_fem_test POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "$<TARGET_FILE:cadaclysm::reader>" "$<TARGET_FILE:cadaclysm::blacksmith>"
            "$<TARGET_FILE_DIR:cadaclysm_fem_test>")
  add_test(NAME fem_records COMMAND cadaclysm_fem_test)

  # Assembly, Solid::named and Solid::name, over _shared_assembly()'s shape -- needs a
  # license, as the smoke does, but no sample file.
  add_executable(cadaclysm_assembly_test tests/assembly_test.cpp)
  target_link_libraries(cadaclysm_assembly_test PRIVATE cadaclysm::blacksmith Threads::Threads)
  add_custom_command(TARGET cadaclysm_assembly_test POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "$<TARGET_FILE:cadaclysm::reader>" "$<TARGET_FILE:cadaclysm::blacksmith>"
            "$<TARGET_FILE_DIR:cadaclysm_assembly_test>")
  add_test(NAME assembly COMMAND cadaclysm_assembly_test ${CADACLYSM_LICENSE})

  # Assembly::link/Assembly::joint, at parity with the Python reference's _mechanism()
  # and its two mechanism tests -- see Node's blacksmith.test.js and Rust's mod tests for
  # the same facts worked out. Needs a license, no sample file.
  add_executable(cadaclysm_mechanism_test tests/mechanism_test.cpp)
  target_link_libraries(cadaclysm_mechanism_test PRIVATE cadaclysm::blacksmith Threads::Threads)
  add_custom_command(TARGET cadaclysm_mechanism_test POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "$<TARGET_FILE:cadaclysm::reader>" "$<TARGET_FILE:cadaclysm::blacksmith>"
            "$<TARGET_FILE_DIR:cadaclysm_mechanism_test>")
  add_test(NAME mechanism COMMAND cadaclysm_mechanism_test ${CADACLYSM_LICENSE})

  # Assembly::pair/state/base and pair_freedom_count, at parity with the Python
  # reference's _paired() and its tests -- see Node's blacksmith.test.js and Rust's mod
  # tests for the same facts worked out. Needs a license, no sample file.
  add_executable(cadaclysm_pair_test tests/pair_test.cpp)
  target_link_libraries(cadaclysm_pair_test PRIVATE cadaclysm::blacksmith Threads::Threads)
  add_custom_command(TARGET cadaclysm_pair_test POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "$<TARGET_FILE:cadaclysm::reader>" "$<TARGET_FILE:cadaclysm::blacksmith>"
            "$<TARGET_FILE_DIR:cadaclysm_pair_test>")
  add_test(NAME pair COMMAND cadaclysm_pair_test ${CADACLYSM_LICENSE})

  # Subd, SubdMesh and SubdReport over the cadaclysm_blacksmith_subd_* calls, at parity with the
  # Python reference's test_subd_* tests (The Kiln, plan 2b). Needs a license, no sample file;
  # the STEP read-back opens the reader, which the copy step below stages beside it.
  add_executable(cadaclysm_subd_test tests/subd_test.cpp)
  target_link_libraries(cadaclysm_subd_test PRIVATE cadaclysm::blacksmith Threads::Threads)
  add_custom_command(TARGET cadaclysm_subd_test POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "$<TARGET_FILE:cadaclysm::reader>" "$<TARGET_FILE:cadaclysm::blacksmith>"
            "$<TARGET_FILE_DIR:cadaclysm_subd_test>")
  add_test(NAME subd COMMAND cadaclysm_subd_test ${CADACLYSM_LICENSE})

  # Sketch, SolveReport, Dof and PartDof over the cadaclysm_blacksmith_sketch_* calls, at parity
  # with the Python reference's test_a_sketch_* tests (sketch-constraints plan 4). Needs a license,
  # no sample file.
  add_executable(cadaclysm_sketch_test tests/sketch_test.cpp)
  target_link_libraries(cadaclysm_sketch_test PRIVATE cadaclysm::blacksmith Threads::Threads)
  add_custom_command(TARGET cadaclysm_sketch_test POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "$<TARGET_FILE:cadaclysm::reader>" "$<TARGET_FILE:cadaclysm::blacksmith>"
            "$<TARGET_FILE_DIR:cadaclysm_sketch_test>")
  add_test(NAME sketch COMMAND cadaclysm_sketch_test ${CADACLYSM_LICENSE})

  # Solid::face_round_radius/face_chamfer_distance/edge_beziers/isocurve_beziers and mesh_file, at
  # parity with the Python reference's tests. Needs a license, no sample file.
  add_executable(cadaclysm_solid_drawing_test tests/solid_drawing_test.cpp)
  target_link_libraries(cadaclysm_solid_drawing_test PRIVATE cadaclysm::blacksmith Threads::Threads)
  add_custom_command(TARGET cadaclysm_solid_drawing_test POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "$<TARGET_FILE:cadaclysm::reader>" "$<TARGET_FILE:cadaclysm::blacksmith>"
            "$<TARGET_FILE_DIR:cadaclysm_solid_drawing_test>")
  add_test(NAME solid_drawing COMMAND cadaclysm_solid_drawing_test ${CADACLYSM_LICENSE})
  # Profile::polyline/arc/arc_through/ellipse/from_beziers/beziers/loops/chain_order, at parity
  # with the Python reference's sketch-curve tests. Needs a license, no sample file.
  add_executable(cadaclysm_curves_test tests/curves_test.cpp)
  target_link_libraries(cadaclysm_curves_test PRIVATE cadaclysm::blacksmith Threads::Threads)
  add_custom_command(TARGET cadaclysm_curves_test POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "$<TARGET_FILE:cadaclysm::reader>" "$<TARGET_FILE:cadaclysm::blacksmith>"
            "$<TARGET_FILE_DIR:cadaclysm_curves_test>")
  add_test(NAME curves COMMAND cadaclysm_curves_test ${CADACLYSM_LICENSE})

  # The oriented box, edge and profile lengths, containment (one-shot and Classifier) and
  # closest points, at parity with the Python reference's measure tests. Needs a license, no
  # sample file.
  add_executable(cadaclysm_measure_test tests/measure_test.cpp)
  target_link_libraries(cadaclysm_measure_test PRIVATE cadaclysm::blacksmith Threads::Threads)
  add_custom_command(TARGET cadaclysm_measure_test POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "$<TARGET_FILE:cadaclysm::reader>" "$<TARGET_FILE:cadaclysm::blacksmith>"
            "$<TARGET_FILE_DIR:cadaclysm_measure_test>")
  add_test(NAME measure COMMAND cadaclysm_measure_test ${CADACLYSM_LICENSE})

  # Closest point from a point: a solid's, a projector's, one face's, one edge's and a NURBS
  # curve's, at parity with the Python reference's tests. Needs a license, no sample file.
  add_executable(cadaclysm_closest_point_test tests/closest_point_test.cpp)
  target_link_libraries(cadaclysm_closest_point_test PRIVATE cadaclysm::blacksmith Threads::Threads)
  add_custom_command(TARGET cadaclysm_closest_point_test POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "$<TARGET_FILE:cadaclysm::reader>" "$<TARGET_FILE:cadaclysm::blacksmith>"
            "$<TARGET_FILE_DIR:cadaclysm_closest_point_test>")
  add_test(NAME closest_point COMMAND cadaclysm_closest_point_test ${CADACLYSM_LICENSE})

  # Closest points from a curve: to a point within reach, to another curve, to a solid and a
  # projector, and the nearest object of a mixed list, at parity with the Python reference's tests.
  # Needs a license, no sample file.
  add_executable(cadaclysm_curve_closest_test tests/curve_closest_test.cpp)
  target_link_libraries(cadaclysm_curve_closest_test PRIVATE cadaclysm::blacksmith Threads::Threads)
  add_custom_command(TARGET cadaclysm_curve_closest_test POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "$<TARGET_FILE:cadaclysm::reader>" "$<TARGET_FILE:cadaclysm::blacksmith>"
            "$<TARGET_FILE_DIR:cadaclysm_curve_closest_test>")
  add_test(NAME curve_closest COMMAND cadaclysm_curve_closest_test ${CADACLYSM_LICENSE})

  # Closest points against a triangle mesh: a face, a shared edge and a vertex foot in closed form,
  # a line through a tetrahedron, the max distance, a solid's measuring mesh and the nearest object,
  # at parity with the Python reference's tests. Needs a license, no sample file.
  add_executable(cadaclysm_mesh_closest_test tests/mesh_closest_test.cpp)
  target_link_libraries(cadaclysm_mesh_closest_test PRIVATE cadaclysm::blacksmith Threads::Threads)
  add_custom_command(TARGET cadaclysm_mesh_closest_test POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "$<TARGET_FILE:cadaclysm::reader>" "$<TARGET_FILE:cadaclysm::blacksmith>"
            "$<TARGET_FILE_DIR:cadaclysm_mesh_closest_test>")
  add_test(NAME mesh_closest COMMAND cadaclysm_mesh_closest_test ${CADACLYSM_LICENSE})

  # Point at length, divide by count and divide by length on edges and a profile's outer loop,
  # at parity with the Python reference's arc-length tests. Needs a license, no sample file.
  add_executable(cadaclysm_arc_length_test tests/arc_length_test.cpp)
  target_link_libraries(cadaclysm_arc_length_test PRIVATE cadaclysm::blacksmith Threads::Threads)
  add_custom_command(TARGET cadaclysm_arc_length_test POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "$<TARGET_FILE:cadaclysm::reader>" "$<TARGET_FILE:cadaclysm::blacksmith>"
            "$<TARGET_FILE_DIR:cadaclysm_arc_length_test>")
  add_test(NAME arc_length COMMAND cadaclysm_arc_length_test ${CADACLYSM_LICENSE})

  # NurbsCurve, Curvature and to_nurbs() on the curve values, at parity with the Python reference's
  # NurbsCurve tests. No sample file.
  add_executable(cadaclysm_nurbs_curve_test tests/nurbs_curve_test.cpp)
  target_link_libraries(cadaclysm_nurbs_curve_test PRIVATE cadaclysm::blacksmith Threads::Threads)
  add_custom_command(TARGET cadaclysm_nurbs_curve_test POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "$<TARGET_FILE:cadaclysm::reader>" "$<TARGET_FILE:cadaclysm::blacksmith>"
            "$<TARGET_FILE_DIR:cadaclysm_nurbs_curve_test>")
  add_test(NAME nurbs_curve COMMAND cadaclysm_nurbs_curve_test ${CADACLYSM_LICENSE})

  # Sheets from curves (loft_curves ... join_sheets) and their records, at parity with the Python
  # reference's tests. No sample file.
  add_executable(cadaclysm_curve_sheets_test tests/curve_sheets_test.cpp)
  target_link_libraries(cadaclysm_curve_sheets_test PRIVATE cadaclysm::blacksmith Threads::Threads)
  add_custom_command(TARGET cadaclysm_curve_sheets_test POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "$<TARGET_FILE:cadaclysm::reader>" "$<TARGET_FILE:cadaclysm::blacksmith>"
            "$<TARGET_FILE_DIR:cadaclysm_curve_sheets_test>")
  add_test(NAME curve_sheets COMMAND cadaclysm_curve_sheets_test ${CADACLYSM_LICENSE})

  # RTree, closest_points and k_neighbors, at parity with the Python reference's R-tree tests.
  # No sample file.
  add_executable(cadaclysm_rtree_test tests/rtree_test.cpp)
  target_link_libraries(cadaclysm_rtree_test PRIVATE cadaclysm::blacksmith Threads::Threads)
  add_custom_command(TARGET cadaclysm_rtree_test POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "$<TARGET_FILE:cadaclysm::reader>" "$<TARGET_FILE:cadaclysm::blacksmith>"
            "$<TARGET_FILE_DIR:cadaclysm_rtree_test>")
  add_test(NAME rtree COMMAND cadaclysm_rtree_test ${CADACLYSM_LICENSE})

  # Collider::clash, the one-shot clash() and the Clash row, at parity with the Python reference's
  # clash tests (clash plan 3). No sample file.
  add_executable(cadaclysm_clash_test tests/clash_test.cpp)
  target_link_libraries(cadaclysm_clash_test PRIVATE cadaclysm::blacksmith Threads::Threads)
  add_custom_command(TARGET cadaclysm_clash_test POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "$<TARGET_FILE:cadaclysm::reader>" "$<TARGET_FILE:cadaclysm::blacksmith>"
            "$<TARGET_FILE_DIR:cadaclysm_clash_test>")
  add_test(NAME clash COMMAND cadaclysm_clash_test ${CADACLYSM_LICENSE})

  # Collider::swept_clash, the one-shot swept_clash() and the SweptClash row, at parity with the
  # Python reference's test_swept_clash_* tests (swept clash plan 2b), and Assembly::parts and
  # Assembly::swept_clash, at parity with its test_assembly_* swept tests (plan 3c). No sample file.
  add_executable(cadaclysm_swept_clash_test tests/swept_clash_test.cpp)
  target_link_libraries(cadaclysm_swept_clash_test PRIVATE cadaclysm::blacksmith Threads::Threads)
  add_custom_command(TARGET cadaclysm_swept_clash_test POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "$<TARGET_FILE:cadaclysm::reader>" "$<TARGET_FILE:cadaclysm::blacksmith>"
            "$<TARGET_FILE_DIR:cadaclysm_swept_clash_test>")
  add_test(NAME swept_clash COMMAND cadaclysm_swept_clash_test ${CADACLYSM_LICENSE})

  # Face and edge ids, origins, History, attributes and the edge and vertex references, at
  # parity with the Python reference's TestIdentity tests (identity plan C3). No sample file.
  add_executable(cadaclysm_identity_test tests/identity_test.cpp)
  target_link_libraries(cadaclysm_identity_test PRIVATE cadaclysm::blacksmith Threads::Threads)
  add_custom_command(TARGET cadaclysm_identity_test POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "$<TARGET_FILE:cadaclysm::reader>" "$<TARGET_FILE:cadaclysm::blacksmith>"
            "$<TARGET_FILE_DIR:cadaclysm_identity_test>")
  add_test(NAME identity COMMAND cadaclysm_identity_test ${CADACLYSM_LICENSE})

  # ThicknessGauge, the Thickness rows, thickness(), mesh_thickness() and Solid::thickness_at_face,
  # at parity with the Python reference's test_thickness_* and test_mesh_thickness_* tests (wall
  # thickness plan 2b). No sample file.
  add_executable(cadaclysm_thickness_test tests/thickness_test.cpp)
  target_link_libraries(cadaclysm_thickness_test PRIVATE cadaclysm::blacksmith Threads::Threads)
  add_custom_command(TARGET cadaclysm_thickness_test POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "$<TARGET_FILE:cadaclysm::reader>" "$<TARGET_FILE:cadaclysm::blacksmith>"
            "$<TARGET_FILE_DIR:cadaclysm_thickness_test>")
  add_test(NAME thickness COMMAND cadaclysm_thickness_test ${CADACLYSM_LICENSE})

  # Transform, Quaternion, Solid::transform / convert_to_nurbs / inexact_trims and the Profile
  # maps, at parity with the Python reference's transform tests (transforms plan A4). No sample
  # file.
  add_executable(cadaclysm_transform_test tests/transform_test.cpp)
  target_link_libraries(cadaclysm_transform_test PRIVATE cadaclysm::blacksmith Threads::Threads)
  add_custom_command(TARGET cadaclysm_transform_test POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "$<TARGET_FILE:cadaclysm::reader>" "$<TARGET_FILE:cadaclysm::blacksmith>"
            "$<TARGET_FILE_DIR:cadaclysm_transform_test>")
  add_test(NAME transform COMMAND cadaclysm_transform_test ${CADACLYSM_LICENSE})

  # Interval, the Frame verbs, the nine values and Curve::value, at parity with the Python
  # reference's value tests (value geometry plan B3). The Rhino records live in the repository,
  # which the SDK does not carry: the test reads both paths at run time, failing on a missing
  # file where the manifest beside it says this is a checkout, skipping with the reason where not.
  add_executable(cadaclysm_values_test tests/values_test.cpp)
  target_link_libraries(cadaclysm_values_test PRIVATE cadaclysm::blacksmith Threads::Threads)
  target_compile_definitions(cadaclysm_values_test PRIVATE
    CADACLYSM_VALUE_VECTORS="${CMAKE_CURRENT_SOURCE_DIR}/../../../cadaclysm/tests/fixtures/rhino/value_vectors.txt"
    CADACLYSM_REPO_MANIFEST="${CMAKE_CURRENT_SOURCE_DIR}/../../../cadaclysm/Cargo.toml")
  add_custom_command(TARGET cadaclysm_values_test POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "$<TARGET_FILE:cadaclysm::reader>" "$<TARGET_FILE:cadaclysm::blacksmith>"
            "$<TARGET_FILE_DIR:cadaclysm_values_test>")
  add_test(NAME values COMMAND cadaclysm_values_test ${CADACLYSM_LICENSE})

  # Solid::health / healed / edge_tolerance and Brep::health / healed / edge_tolerance, at parity
  # with the Python reference's health and healing tests and their two decoder tests. The reader
  # half opens st203-bapl.stp at the repository root, which an SDK checkout does not carry: "-"
  # skips it there.
  set(_cadaclysm_st203 "${CMAKE_CURRENT_SOURCE_DIR}/../../../../st203-bapl.stp")
  if(NOT EXISTS "${_cadaclysm_st203}")
    set(_cadaclysm_st203 "-")
  endif()
  add_executable(cadaclysm_healing_test tests/healing_test.cpp)
  target_link_libraries(cadaclysm_healing_test PRIVATE cadaclysm::blacksmith Threads::Threads)
  add_custom_command(TARGET cadaclysm_healing_test POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "$<TARGET_FILE:cadaclysm::reader>" "$<TARGET_FILE:cadaclysm::blacksmith>"
            "$<TARGET_FILE_DIR:cadaclysm_healing_test>")
  add_test(NAME healing COMMAND cadaclysm_healing_test "${_cadaclysm_st203}" ${CADACLYSM_LICENSE})

  # Interpolator, Profile::circumscribed_polygon and Solid::merge / regions / region_solid, at
  # parity with the Python reference's interpolator, circumscribed-polygon and merge tests. No
  # sample file.
  add_executable(cadaclysm_interpolator_merge_test tests/interpolator_merge_test.cpp)
  target_link_libraries(cadaclysm_interpolator_merge_test PRIVATE cadaclysm::blacksmith Threads::Threads)
  add_custom_command(TARGET cadaclysm_interpolator_merge_test POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "$<TARGET_FILE:cadaclysm::reader>" "$<TARGET_FILE:cadaclysm::blacksmith>"
            "$<TARGET_FILE_DIR:cadaclysm_interpolator_merge_test>")
  add_test(NAME interpolator_merge COMMAND cadaclysm_interpolator_merge_test ${CADACLYSM_LICENSE})

  # Assembly::posed over the paired arm, two copies of a bracket and plan 4's gears.
  add_executable(cadaclysm_posed_test tests/posed_test.cpp)
  target_link_libraries(cadaclysm_posed_test PRIVATE cadaclysm::blacksmith Threads::Threads)
  add_custom_command(TARGET cadaclysm_posed_test POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "$<TARGET_FILE:cadaclysm::reader>" "$<TARGET_FILE:cadaclysm::blacksmith>"
            "$<TARGET_FILE_DIR:cadaclysm_posed_test>")
  add_test(NAME posed COMMAND cadaclysm_posed_test ${CADACLYSM_LICENSE})

  # Document over the cadaclysm_blacksmith_document_* and cadaclysm_bim_* calls, at parity with the
  # Python reference's document tests (document plan, 2026-11-06), on the JSON-text shape. Writes
  # two small files in its working directory (the build directory) and removes them.
  add_executable(cadaclysm_document_test tests/document_test.cpp)
  target_link_libraries(cadaclysm_document_test PRIVATE cadaclysm::blacksmith Threads::Threads)
  add_custom_command(TARGET cadaclysm_document_test POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "$<TARGET_FILE:cadaclysm::reader>" "$<TARGET_FILE:cadaclysm::blacksmith>"
            "$<TARGET_FILE_DIR:cadaclysm_document_test>")
  add_test(NAME document COMMAND cadaclysm_document_test ${CADACLYSM_LICENSE})
  # to_arcs, offset, section, Tool, Stock and Job over the pocketed block and the plate
  # fixtures, plus face/contour/pocket/drill driven by hand and a closed job's refusal.
  # Needs a license, as assembly does; no sample file.
  add_executable(cadaclysm_blacksmith_cam_test tests/blacksmith_cam_test.cpp)
  target_link_libraries(cadaclysm_blacksmith_cam_test PRIVATE cadaclysm::blacksmith Threads::Threads)
  add_custom_command(TARGET cadaclysm_blacksmith_cam_test POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "$<TARGET_FILE:cadaclysm::reader>" "$<TARGET_FILE:cadaclysm::blacksmith>"
            "$<TARGET_FILE_DIR:cadaclysm_blacksmith_cam_test>")
  add_test(NAME blacksmith_cam COMMAND cadaclysm_blacksmith_cam_test ${CADACLYSM_LICENSE})

  # Both silhouette queries, kernel and reader. The reader half opens the acis crate's own
  # Rhino fixtures, which an SDK checkout does not carry: "-" skips it there.
  set(_cadaclysm_rhino "${CMAKE_CURRENT_SOURCE_DIR}/../../../cadaclysm-acis/tests/fixtures/rhino")
  if(NOT EXISTS "${_cadaclysm_rhino}/sphere.sat")
    set(_cadaclysm_rhino "-")
  endif()
  add_executable(cadaclysm_silhouette_test tests/silhouette_test.cpp)
  target_link_libraries(cadaclysm_silhouette_test PRIVATE cadaclysm::blacksmith Threads::Threads)
  add_custom_command(TARGET cadaclysm_silhouette_test POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "$<TARGET_FILE:cadaclysm::reader>" "$<TARGET_FILE:cadaclysm::blacksmith>"
            "$<TARGET_FILE_DIR:cadaclysm_silhouette_test>")
  add_test(NAME silhouette COMMAND cadaclysm_silhouette_test "${_cadaclysm_rhino}" ${CADACLYSM_LICENSE})

  add_library(cadaclysm_header_kernel OBJECT tests/include_kernel.cpp)
  target_link_libraries(cadaclysm_header_kernel PRIVATE cadaclysm::blacksmith)

  # cadaclysm/view.hpp: View offscreen over a solid, a scene, a pose and a node, the
  # refusals, the release on Scene::close, show() on the terminal, and the missing-library
  # message. The GPU half skips without cadaclysm_view or an adapter unless
  # CADACLYSM_REQUIRE_WGPU is set, the terminal half without cadaclysm_terminal unless
  # CADACLYSM_REQUIRE_TERMINAL=1 (the Linux box and the Windows gate set both).
  add_executable(cadaclysm_view_test tests/view_test.cpp)
  target_link_libraries(cadaclysm_view_test PRIVATE cadaclysm::blacksmith cadaclysm::view_loader Threads::Threads)
  add_dependencies(cadaclysm_view_test cadaclysm_view_loader_fake)
  add_custom_command(TARGET cadaclysm_view_test POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
            "$<TARGET_FILE:cadaclysm::reader>" "$<TARGET_FILE:cadaclysm::blacksmith>"
            "$<TARGET_FILE_DIR:cadaclysm_view_test>")
  # samples/mechanism-solid.stp, found beside whichever sample CADACLYSM_SAMPLE names (as
  # the kinematics test finds it); without one the scene, pose and node checks are skipped.
  set(_cadaclysm_mechanism "")
  if(CADACLYSM_SAMPLE)
    get_filename_component(_cadaclysm_samples "${CADACLYSM_SAMPLE}" DIRECTORY)
    set(_cadaclysm_mechanism "${_cadaclysm_samples}/mechanism-solid.stp")
  endif()
  # The bundled font (crates/cadaclysm-text/fonts), for load_font's checks; absent in the
  # SDK's layout, where they are skipped.
  set(_cadaclysm_font "${CMAKE_CURRENT_SOURCE_DIR}/../../../cadaclysm-text/fonts/LiberationSans-Regular.ttf")
  if(NOT EXISTS "${_cadaclysm_font}")
    set(_cadaclysm_font "")
  endif()
  add_test(NAME view COMMAND cadaclysm_view_test "${CMAKE_CURRENT_BINARY_DIR}" "${_cadaclysm_mechanism}"
                             "$<TARGET_FILE:cadaclysm_view_loader_fake>" "${_cadaclysm_font}")
  # A pump that sleeps instead of answering hangs: fail it.
  set_tests_properties(view PROPERTIES TIMEOUT 600)

  # The header compiles with nothing included before it.
  add_library(cadaclysm_header_view OBJECT tests/include_view.cpp)
  target_link_libraries(cadaclysm_header_view PRIVATE cadaclysm::blacksmith cadaclysm::view_loader)

  # What a user's code compiles, with the default hook: Release builds catch the
  # optimiser-only warnings in it.
  add_library(cadaclysm_user_calls OBJECT tests/user_calls.cpp)
  target_link_libraries(cadaclysm_user_calls PRIVATE cadaclysm::blacksmith)

  # The kernel-reader flavour leaves out the kernel's B-rep writers: these tests call
  # Solid::step or Assembly::step, which then fail to link, so they are neither built nor run.
  if(cadaclysm_FLAVOUR STREQUAL "kernel-reader")
    foreach(_cadaclysm_test smoke smoke_fast assembly mechanism pair subd curve_sheets identity
                            posed document view)
      set(_cadaclysm_target cadaclysm_${_cadaclysm_test})
      if(NOT _cadaclysm_test MATCHES "^smoke")
        set(_cadaclysm_target cadaclysm_${_cadaclysm_test}_test)
      endif()
      set_target_properties(${_cadaclysm_target} PROPERTIES EXCLUDE_FROM_ALL TRUE)
    endforeach()
    set_tests_properties(assembly mechanism pair subd curve_sheets identity posed document view
                         PROPERTIES DISABLED TRUE)
    if(CADACLYSM_SAMPLE)
      set_tests_properties(cadaclysm_smoke cadaclysm_smoke_fast PROPERTIES DISABLED TRUE)
    endif()
  endif()
endif()
