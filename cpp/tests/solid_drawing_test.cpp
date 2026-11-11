// A face's round radius and chamfer distance, the edges and isocurves as Beziers, and mesh_file,
// at parity with the Python reference's
// test_a_face_tells_its_round_radius_and_chamfer_distance,
// test_edges_and_isocurves_come_as_beziers and
// test_mesh_file_writes_several_solids_in_each_format.
//
//     cadaclysm_solid_drawing_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <optional>
#include <set>
#include <string>
#include <vector>

using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;

static int failures = 0;

static bool check(bool ok, const std::string& what) {
    if (ok) return true;
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
    return false;
}

template <class T>
static T must(Result<T> r, const std::string& what) {
    if (!r.ok()) {
        std::fprintf(stderr, "FAIL: %s: %s\n", what.c_str(), r.error().message.c_str());
        std::exit(1);
    }
    return std::move(r).value();
}

// `r` refused, its message starting with `prefix` (or holding `inside` when that is given).
template <class T>
static void refused(const Result<T>& r, const std::string& prefix, const std::string& inside, const std::string& what) {
    if (r.ok()) {
        check(false, what + ": expected a refusal, but the call succeeded");
        return;
    }
    const std::string& got = r.error().message;
    check(got.rfind(prefix, 0) == 0 && got.find(inside) != std::string::npos,
          what + ": refused with \"" + got + "\", wanted \"" + prefix + "...\"" + (inside.empty() ? "" : " holding \"" + inside + "\""));
}

static std::string text_of(const std::vector<std::uint8_t>& bytes) { return std::string(bytes.begin(), bytes.end()); }

static std::size_t count_of(const std::string& haystack, const std::string& needle) {
    std::size_t n = 0;
    for (std::size_t at = haystack.find(needle); at != std::string::npos; at = haystack.find(needle, at + needle.size())) ++n;
    return n;
}

static void a_face_tells_its_round_radius_and_chamfer_distance() {
    bs::Solid cube = must(bs::Solid::cuboid(10, 10, 10), "cuboid");
    std::vector<std::uint32_t> vertical;
    for (const bs::Edge& e : must(cube.edges(), "edges")) {
        std::optional<bs::Vec3> d = e.direction();
        if (e.is_line() && d && std::fabs((*d)[2]) > 0.99) vertical.push_back(e.index);
    }
    check(vertical.size() == 4, "four vertical edges, got " + std::to_string(vertical.size()));
    bs::Solid rounded = must(cube.fillet(vertical, 1.5), "fillet");
    std::set<double> distinct;
    int round_faces = 0;
    for (std::uint32_t f = 0; f < rounded.faces(); ++f) {
        double r = must(rounded.face_round_radius(f), "face_round_radius");
        distinct.insert(std::round(r * 1e9) / 1e9);
        if (r != 0) ++round_faces;
        check(must(rounded.face_chamfer_distance(f), "face_chamfer_distance") == 0, "a round face is no chamfer");
    }
    check(distinct == std::set<double>{0.0, 1.5}, "the radii are 0 and 1.5");
    check(round_faces == 4, "one round a vertical edge, got " + std::to_string(round_faces));
    bs::Solid bevelled = must(cube.chamfer(vertical, 2.0), "chamfer");
    int bevels = 0;
    for (std::uint32_t f = 0; f < bevelled.faces(); ++f) {
        if (std::fabs(must(bevelled.face_chamfer_distance(f), "face_chamfer_distance") - 2.0) < 1e-9) ++bevels;
        check(must(bevelled.face_round_radius(f), "face_round_radius") == 0, "a bevel is no round");
    }
    check(bevels == 4, "four bevels of 2, got " + std::to_string(bevels));
    refused(cube.face_round_radius(6), "face_round_radius: face 6 of 6", "", "face_round_radius(6)");
    refused(cube.face_chamfer_distance(6), "face_chamfer_distance: face 6 of 6", "", "face_chamfer_distance(6)");
}

static void edges_and_isocurves_come_as_beziers() {
    bs::Solid cube = must(bs::Solid::cuboid(2, 2, 2), "cuboid");
    std::vector<double> edges = must(cube.edge_beziers(), "edge_beziers");
    check(edges.size() == 12 * 16, "one straight Bezier an edge, got " + std::to_string(edges.size()));
    bool unit = true;
    for (std::size_t k = 3; k < edges.size(); k += 4) unit = unit && edges[k] == 1.0;
    check(unit, "a line's weights are one");
    check(must(cube.isocurve_beziers(4), "isocurve_beziers").empty(), "a flat face draws no isocurve");
    bs::Solid cylinder = must(bs::Solid::cylinder(1, 3), "cylinder");
    std::vector<double> rings = must(cylinder.isocurve_beziers(3), "isocurve_beziers(3)");
    check(!rings.empty() && rings.size() % 16 == 0, "the rings are whole Beziers");
    check(must(cylinder.isocurve_beziers(6), "isocurve_beziers(6)").size() > rings.size(), "a denser grid draws more lines");
    // A circle's Beziers are exact conics: some weight below one.
    std::vector<double> circles = must(cylinder.edge_beziers(), "edge_beziers");
    bool conic = false;
    for (std::size_t k = 3; k < circles.size(); k += 4) conic = conic || circles[k] < 0.99;
    check(conic, "a circle's weights dip below one");
    refused(cube.edge_beziers(-1.0), "", "tolerance must be positive and finite", "edge_beziers(-1)");
}

static void mesh_file_writes_several_solids_in_each_format() {
    bs::Solid a = must(bs::Solid::cuboid(2, 2, 2), "a");
    bs::Solid b = must(must(bs::Solid::cuboid(1, 1, 1), "b").translate(5, 0, 0), "translate");
    bs::Solids both{a, b};
    std::vector<std::uint8_t> stl = must(bs::mesh_file(both, "stl"), "stl");
    if (check(stl.size() >= 84, "an STL header")) {
        std::uint32_t triangles = static_cast<std::uint32_t>(stl[80]) | (static_cast<std::uint32_t>(stl[81]) << 8) |
                                  (static_cast<std::uint32_t>(stl[82]) << 16) | (static_cast<std::uint32_t>(stl[83]) << 24);
        check(triangles == 24, "two boxes, twelve triangles each, got " + std::to_string(triangles));
    }
    check(stl.size() == 84 + 50 * 24, "the STL's length");
    std::vector<std::string> names{"plate", "pin"};
    std::string text = text_of(must(bs::mesh_file(both, "stl-ascii", names), "stl-ascii"));
    check(text.rfind("solid plate", 0) == 0 && count_of(text, "facet normal") == 24, "the ASCII STL");
    std::string obj = text_of(must(bs::mesh_file(both, "obj", names), "obj"));
    check(obj.find("o plate") != std::string::npos && obj.find("o pin") != std::string::npos, "the OBJ's objects");
    std::vector<std::array<double, 6>> looks{{1, 0, 0, 1, 0, 0.5}, {0, 0, 1, 0.5, 1, 0.2}};
    std::vector<std::uint8_t> glb = must(bs::mesh_file(both, "glb", std::nullopt, looks), "glb");
    check(glb.size() >= 4 && text_of(std::vector<std::uint8_t>(glb.begin(), glb.begin() + 4)) == "glTF", "the GLB's magic");
    std::string gltf = text_of(must(bs::mesh_file(both, "gltf"), "gltf"));
    check(gltf.find("\"Solid 1\"") != std::string::npos && gltf.find("\"Solid 2\"") != std::string::npos, "the glTF's nodes are named");
    refused(bs::mesh_file({a}, "step"), "mesh_file: format \"step\" is not one of", "", "mesh_file step");
    refused(bs::mesh_file({}, "stl"), "mesh_file: no solids", "", "mesh_file no solids");
    refused(bs::mesh_file({a}, "obj", std::vector<std::string>{"a", "b"}), "", "2 names for 1 solids", "mesh_file names");
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
        void (*run)();
    };
    const Test tests[] = {
        {"a_face_tells_its_round_radius_and_chamfer_distance", a_face_tells_its_round_radius_and_chamfer_distance},
        {"edges_and_isocurves_come_as_beziers", edges_and_isocurves_come_as_beziers},
        {"mesh_file_writes_several_solids_in_each_format", mesh_file_writes_several_solids_in_each_format},
    };
    for (const Test& t : tests) {
        int before = failures;
        t.run();
        std::printf("%s %s\n", failures == before ? "ok  " : "FAIL", t.name);
    }
    if (failures) {
        std::fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    std::printf("solid_drawing: ok\n");
    return 0;
}
