// A triangle mesh made a B-rep -- at parity with the Python reference's tests test_from_mesh_* in
// test_cadaclysm_blacksmith.py: a unit cube's 12 triangles made a box (merged into 6 faces and 12
// edges in the prismatic and planes modes, or faceted into 12 and 18), the cube less a triangle an
// open shell with one hole, the refusals by name, a STEP cube's node read back through the
// reader's mesh, and a bored block's mesh coming back with its bore a cylinder. Needs the kernel
// library and a license; the exit code is the verdict.
//
//     cadaclysm_from_mesh_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <limits>
#include <string>
#include <system_error>
#include <utility>
#include <vector>

using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;
using bs::Vec3;
using Triangles = std::vector<std::array<std::uint32_t, 3>>;
using Made = std::pair<bs::Solid, bs::FromMeshReport>;

static int failures = 0;

static const std::vector<Vec3> CUBE = {Vec3{0, 0, 0}, Vec3{1, 0, 0}, Vec3{1, 1, 0}, Vec3{0, 1, 0},
                                       Vec3{0, 0, 1}, Vec3{1, 0, 1}, Vec3{1, 1, 1}, Vec3{0, 1, 1}};
static const Triangles CUBE_TRIANGLES = {{0, 2, 1}, {0, 3, 2}, {4, 5, 6}, {4, 6, 7}, {0, 1, 5}, {0, 5, 4},
                                         {1, 2, 6}, {1, 6, 5}, {2, 3, 7}, {2, 7, 6}, {3, 0, 4}, {3, 4, 7}};

static void check(bool ok, const std::string& what) {
    if (ok) return;
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
}

template <class T>
static T must(Result<T> r, const std::string& what) {
    if (!r.ok()) {
        std::fprintf(stderr, "FAIL: %s: %s\n", what.c_str(), r.error().message.c_str());
        std::exit(1);
    }
    return std::move(r).value();
}

static std::string counts(const bs::FromMeshReport& r) {
    return std::string("closed ") + (r.closed ? "true" : "false") + ", faces " + std::to_string(r.faces) + ", edges " +
           std::to_string(r.edges) + ", vertices " + std::to_string(r.vertices) + ", holes " + std::to_string(r.holes) +
           ", boundary edges " + std::to_string(r.boundary_edges) + ", non-manifold edges " + std::to_string(r.non_manifold_edges) +
           ", flipped " + std::to_string(r.flipped) + ", dropped " + std::to_string(r.dropped) + ", planes " +
           std::to_string(r.planes) + ", cylinders " + std::to_string(r.cylinders) + ", cones " + std::to_string(r.cones) +
           ", spheres " + std::to_string(r.spheres) + ", tori " + std::to_string(r.tori);
}

// The refusal's message starts with `prefix`.
static void refused(Result<Made> r, const std::string& prefix, const std::string& what) {
    if (r.ok()) {
        check(false, what + ": not refused");
        return;
    }
    const std::string& message = r.error().message;
    check(message.compare(0, prefix.size(), prefix) == 0, what + ": refused with '" + message + "'");
}

// 1: a_cube_is_a_closed_solid_merged_or_faceted
static Result<void> a_cube_is_a_closed_solid_merged_or_faceted() {
    Made cube = must(bs::Solid::from_mesh(CUBE, CUBE_TRIANGLES), "from_mesh");
    const bs::FromMeshReport& r = cube.second;
    check(r.closed && r.faces == 6 && r.edges == 12 && r.vertices == 8 && r.holes == 0 && r.boundary_edges == 0 &&
              r.non_manifold_edges == 0 && r.flipped == 0 && r.dropped == 0 && r.planes == 6 && r.cylinders == 0 &&
              r.cones == 0 && r.spheres == 0 && r.tori == 0,
          "the cube's report (prismatic by default): " + counts(r));
    check(cube.first.faces() == 6, "the cube has 6 faces, not " + std::to_string(cube.first.faces()));
    check(must(cube.first.edges(), "edges").size() == 12, "the cube has 12 edges");
    double volume = must(cube.first.mass(), "mass").volume;
    check(std::fabs(volume - 1) < 1e-9, "the cube's volume is " + std::to_string(volume));

    bs::FromMeshOptions planes_options;
    planes_options.mode = bs::FromMeshMode::planes;
    Made planes = must(bs::Solid::from_mesh(CUBE, CUBE_TRIANGLES, planes_options), "from_mesh planes");
    const bs::FromMeshReport& p = planes.second;
    check(p.closed && p.faces == 6 && p.edges == 12 && p.vertices == 8 && p.planes == 6 && p.cylinders == 0,
          "planes: " + counts(p));

    bs::FromMeshOptions faceted_options;
    faceted_options.mode = bs::FromMeshMode::faceted;
    faceted_options.angle_tolerance = std::numeric_limits<double>::quiet_NaN();
    Made faceted = must(bs::Solid::from_mesh(CUBE, CUBE_TRIANGLES, faceted_options), "from_mesh faceted");
    const bs::FromMeshReport& f = faceted.second;
    check(f.closed && f.faces == 12 && f.edges == 18 && f.vertices == 8 && f.planes == 0, "faceted: " + counts(f));
    check(faceted.first.faces() == 12, "faceted has 12 faces");
    return {};
}

// 2: a_cube_missing_a_triangle_is_an_open_shell
static Result<void> a_cube_missing_a_triangle_is_an_open_shell() {
    Triangles less(CUBE_TRIANGLES.begin() + 1, CUBE_TRIANGLES.end());
    Made sheet = must(bs::Solid::from_mesh(CUBE, less), "from_mesh less a triangle");
    const bs::FromMeshReport& r = sheet.second;
    check(!r.closed && r.holes == 1 && r.boundary_edges == 3 && r.non_manifold_edges == 0, "less a triangle: " + counts(r));
    check(sheet.first.faces() == 6, "the open bottom is still one plane's face, less a triangle");
    return {};
}

// 3: refused_by_name
static Result<void> refused_by_name() {
    refused(bs::Solid::from_mesh(CUBE, Triangles{}), "from_mesh: no triangles", "no triangles");
    refused(bs::Solid::from_mesh(CUBE, Triangles{{0, 1, 8}}), "from_mesh: a triangle index is out of range", "a stray index");
    bs::FromMeshOptions negative;
    negative.weld_tolerance = -1;
    refused(bs::Solid::from_mesh(CUBE, CUBE_TRIANGLES, negative), "from_mesh: a tolerance is negative", "a negative tolerance");
    return {};
}

// 4: a_step_cube_node_through_the_reader
static Result<void> a_step_cube_node_through_the_reader() {
    std::filesystem::path stp = std::filesystem::temp_directory_path() / "cadaclysm_from_mesh_test_cube.stp";
    {
        bs::Solid unit = must(bs::Solid::cuboid(1, 1, 1), "cuboid");
        Result<void> written = unit.step(stp.string());
        if (!written) return written.error();
    }
    {
        cadaclysm::Scene scene = must(cadaclysm::open(stp.string()), "open the STEP cube");
        bool meshed = false;
        for (const cadaclysm::Node& n : scene.nodes()) {
            if (n.mesh64().empty()) continue;
            meshed = true;
            Made read = must(bs::Solid::from_mesh_node(n), "from_mesh_node");
            check(read.second.closed && read.second.faces == 6 && read.second.edges == 12, "the STEP cube: " + counts(read.second));
            double volume = must(read.first.mass(), "mass").volume;
            check(std::fabs(volume - 1) < 1e-6, "the STEP cube's volume is " + std::to_string(volume));
            bs::FromMeshOptions faceted;
            faceted.mode = bs::FromMeshMode::faceted;
            Made facets = must(bs::Solid::from_mesh_node(n, faceted), "from_mesh_node faceted");
            check(facets.second.closed && facets.second.faces == 12 && facets.second.edges == 18,
                  "the STEP cube faceted: " + counts(facets.second));
            bs::FromMeshOptions planes;
            planes.mode = bs::FromMeshMode::planes;
            Made merged = must(bs::Solid::from_mesh_node(n, planes), "from_mesh_node planes");
            check(merged.second.closed && merged.second.faces == 6 && merged.second.edges == 12 && merged.second.planes == 6,
                  "the STEP cube in planes: " + counts(merged.second));
            break;
        }
        check(meshed, "the STEP cube has a node with triangles");
    }
    std::error_code ignored;
    std::filesystem::remove(stp, ignored);
    return {};
}

// 5: a_bore_comes_back_a_cylinder -- a 4 x 4 x 2 block less a radius-1 pin through it, meshed at
// 0.01 and converted in the default (prismatic) mode: the bore comes back as cylinder faces, the
// block's 6 sides as planes.
static Result<void> a_bore_comes_back_a_cylinder() {
    bs::Solid block = must(bs::Solid::cuboid(4, 4, 2), "cuboid");
    bs::Solid pin = must(must(bs::Solid::cylinder(1, 4), "cylinder").translate(0, 0, -2), "translate");
    bs::Solid bored = must(block.cut(pin, 1e-4), "cut");
    bs::Mesh64 mesh = must(bored.mesh64(0.01), "mesh64");
    cadaclysm::Span<const double> xyz = mesh.positions();
    cadaclysm::Span<const std::uint32_t> ids = mesh.indices();
    std::vector<Vec3> positions(xyz.size() / 3);
    for (std::size_t i = 0; i < positions.size(); ++i) positions[i] = Vec3{xyz[3 * i], xyz[3 * i + 1], xyz[3 * i + 2]};
    Triangles triangles(ids.size() / 3);
    for (std::size_t i = 0; i < triangles.size(); ++i) triangles[i] = {ids[3 * i], ids[3 * i + 1], ids[3 * i + 2]};
    Made made = must(bs::Solid::from_mesh(positions, triangles), "from_mesh the bored block");
    const bs::FromMeshReport& r = made.second;
    check(r.closed && r.planes == 6 && r.cylinders >= 1 && r.faces == 6 + r.cylinders, "the bored block: " + counts(r));
    double volume = must(made.first.mass(), "mass").volume;
    double exact = 32.0 - 2.0 * 3.14159265358979323846;
    check(std::fabs(volume - exact) < 0.01, "the bored block's volume is " + std::to_string(volume));
    return {};
}

int main(int argc, char** argv) {
    if (argc > 1) {
        Result<void> loaded = bs::license(argv[1]);
        if (!loaded) {
            std::fprintf(stderr, "FAIL: license: %s\n", loaded.error().message.c_str());
            return 1;
        }
    }
    struct Test {
        const char* name;
        Result<void> (*run)();
    };
    const Test tests[] = {
        {"a_cube_is_a_closed_solid_merged_or_faceted", a_cube_is_a_closed_solid_merged_or_faceted},
        {"a_cube_missing_a_triangle_is_an_open_shell", a_cube_missing_a_triangle_is_an_open_shell},
        {"refused_by_name", refused_by_name},
        {"a_step_cube_node_through_the_reader", a_step_cube_node_through_the_reader},
        {"a_bore_comes_back_a_cylinder", a_bore_comes_back_a_cylinder},
    };
    for (const Test& t : tests) {
        int before = failures;
        Result<void> outcome = t.run();
        if (!outcome) {
            std::fprintf(stderr, "FAIL: %s: %s\n", t.name, outcome.error().message.c_str());
            ++failures;
        }
        std::printf("%s %s\n", failures == before ? "ok  " : "FAIL", t.name);
    }
    if (failures) {
        std::fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    std::printf("from mesh: ok\n");
    return 0;
}
