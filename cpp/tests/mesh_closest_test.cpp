// Closest points against a triangle mesh -- at parity with the Python reference's tests in
// test_cadaclysm_blacksmith.py (test_a_triangle_mesh_names_its_face_edge_and_vertex_feet_in_closed_form
// .. test_the_nearest_object_to_a_curve_takes_a_triangle_mesh), every figure a closed form written
// out here, at the origin and shifted far out: a face, a shared edge, an outer edge and a vertex
// foot on the unit square, the max distance on both sides, a line through a tetrahedron, a solid's
// measuring mesh, the nearest object of a list holding a mesh, and the refusals. Needs the kernel
// library and a license; the exit code is the verdict.
//
//     cadaclysm_mesh_closest_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <optional>
#include <string>
#include <utility>
#include <vector>

using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;
using bs::Vec3;
using Triangles = std::vector<std::array<std::uint32_t, 3>>;
using Indices = std::vector<std::uint32_t>;

static int failures = 0;
static const double NAN_VALUE = std::numeric_limits<double>::quiet_NaN();
static const double INF_VALUE = std::numeric_limits<double>::infinity();
static const std::array<Vec3, 3> SHIFTS = {Vec3{0, 0, 0}, Vec3{1e4, -1e4, 5e3}, Vec3{1e6, -1e6, 5e5}};

// The unit square, its two triangles sharing the diagonal 0-2.
static const std::vector<Vec3> SQUARE = {Vec3{0, 0, 0}, Vec3{1, 0, 0}, Vec3{1, 1, 0}, Vec3{0, 1, 0}};
static const Triangles SQUARE_TRIANGLES = {{0, 1, 2}, {0, 2, 3}};
// The unit tetrahedron, triangle 0 its z = 0 floor.
static const std::vector<Vec3> TETRA = {Vec3{0, 0, 0}, Vec3{1, 0, 0}, Vec3{0, 1, 0}, Vec3{0, 0, 1}};
static const Triangles TETRA_TRIANGLES = {{0, 2, 1}, {0, 1, 3}, {0, 3, 2}, {1, 2, 3}};

static void check(bool ok, const std::string& what) {
    if (ok) return;
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
}

static bool within(double a, double b, double tolerance) { return std::fabs(a - b) <= tolerance; }

static bool near3(const std::array<double, 3>& a, const std::array<double, 3>& b, double tolerance) {
    return within(a[0], b[0], tolerance) && within(a[1], b[1], tolerance) && within(a[2], b[2], tolerance);
}

static Vec3 shifted(const Vec3& p, const Vec3& s) { return Vec3{p[0] + s[0], p[1] + s[1], p[2] + s[2]}; }

static double shift_tol(const Vec3& s, double unit) {
    return unit * (1 + std::max(std::fabs(s[0]), std::max(std::fabs(s[1]), std::fabs(s[2]))));
}

template <class T>
static T must(Result<T> r, const std::string& what) {
    if (!r.ok()) {
        std::fprintf(stderr, "FAIL: %s: %s\n", what.c_str(), r.error().message.c_str());
        std::exit(1);
    }
    return std::move(r).value();
}

// An answer that must be there.
template <class T>
static T found(Result<std::optional<T>> r, const std::string& what) {
    std::optional<T> answer = must(std::move(r), what);
    if (!answer) {
        std::fprintf(stderr, "FAIL: %s: nothing found\n", what.c_str());
        std::exit(1);
    }
    return *answer;
}

// The call must have answered nothing (beyond its limit).
template <class T>
static void nothing(Result<std::optional<T>> r, const std::string& what) {
    std::optional<T> answer = must(std::move(r), what);
    check(!answer.has_value(), what + ": found something");
}

// The call must have been refused with exactly `want`.
template <class T>
static void refused(const Result<T>& r, const std::string& want, const std::string& what) {
    if (r.ok()) {
        check(false, what + ": expected a refusal, but the call succeeded");
        return;
    }
    const std::string& got = r.error().message;
    check(got == want, what + ": refused with \"" + got + "\", wanted \"" + want + "\"");
}

// The straight curve from `a` to `b`, `t` running 0 to 1.
static bs::NurbsCurve segment(const Vec3& a, const Vec3& b) { return must(bs::NurbsCurve::make({a, b}, 1), "segment"); }

// The mesh of `points` shifted by `s`.
static bs::TriangleMesh mesh_of(const std::vector<Vec3>& points, const Triangles& triangles, const Vec3& s) {
    std::vector<Vec3> moved;
    for (const Vec3& p : points) moved.push_back(shifted(p, s));
    return must(bs::TriangleMesh::make(moved, triangles), "mesh");
}

// Every field of two mesh points, exactly.
static bool same(const bs::MeshPoint& a, const bs::MeshPoint& b) {
    return a.point == b.point && a.distance == b.distance && a.triangle == b.triangle && a.barycentric == b.barycentric && a.kind == b.kind &&
           a.vertices == b.vertices;
}

// Every field of two curve-mesh answers, exactly.
static bool same(const bs::CurveMeshFoot& a, const bs::CurveMeshFoot& b) {
    return a.distance == b.distance && a.t == b.t && a.point_on_curve == b.point_on_curve && a.point_on_mesh == b.point_on_mesh &&
           a.triangle == b.triangle && a.barycentric == b.barycentric && a.kind == b.kind && a.vertices == b.vertices && a.crossing == b.crossing;
}

static std::string show(const bs::MeshPoint& m) {
    std::string vertices;
    for (std::uint32_t v : m.vertices) vertices += (vertices.empty() ? "" : ", ") + std::to_string(v);
    return "MeshPoint(" + std::to_string(m.distance) + ", triangle " + std::to_string(m.triangle) + ", " + m.kind + " [" + vertices + "])";
}

static std::string show(const bs::CurveMeshFoot& f) {
    std::string vertices;
    for (std::uint32_t v : f.vertices) vertices += (vertices.empty() ? "" : ", ") + std::to_string(v);
    return "CurveMeshFoot(" + std::to_string(f.distance) + ", t " + std::to_string(f.t) + ", triangle " + std::to_string(f.triangle) + ", " + f.kind +
           " [" + vertices + "], crossing " + std::to_string(f.crossing) + ")";
}

// 1. the unit square: a face foot, the shared diagonal (the lower triangle, vertices [0, 2]), an
// outer edge and a corner vertex; its counts and bounds
static Result<void> face_edge_and_vertex_feet() {
    for (const Vec3& s : SHIFTS) {
        double tol = shift_tol(s, 1e-12);
        bs::TriangleMesh mesh = mesh_of(SQUARE, SQUARE_TRIANGLES, s);
        check(must(mesh.vertex_count(), "vertex_count") == 4 && must(mesh.triangle_count(), "triangle_count") == 2, "the counts");
        cadaclysm::Bounds64 box = must(mesh.bounds(), "bounds");
        check(box.min == s && box.max == shifted(Vec3{1, 1, 0}, s), "the bounds");
        bs::MeshPoint face = found(mesh.closest_point(shifted(Vec3{0.75, 0.25, 2}, s)), "the face");
        check(face.triangle == 0 && face.kind == "face" && face.vertices.empty() && near3(face.point, shifted(Vec3{0.75, 0.25, 0}, s), tol) &&
                  within(face.distance, 2, 1e-9) && near3(face.barycentric, {0.25, 0.5, 0.25}, 1e-9),
              "the face foot reads " + show(face));
        bs::MeshPoint diagonal = found(mesh.closest_point(shifted(Vec3{0.5, 0.5, 1}, s)), "the shared edge");
        check(diagonal.triangle == 0 && diagonal.kind == "edge" && diagonal.vertices == Indices{0, 2} && within(diagonal.distance, 1, 1e-9) &&
                  near3(diagonal.barycentric, {0.5, 0, 0.5}, 1e-9),
              "the shared edge reads " + show(diagonal));
        bs::MeshPoint outer = found(mesh.closest_point(shifted(Vec3{0.5, -1, 0}, s)), "the outer edge");
        check(outer.triangle == 0 && outer.kind == "edge" && outer.vertices == Indices{0, 1} && near3(outer.barycentric, {0.5, 0.5, 0}, 1e-9),
              "the outer edge reads " + show(outer));
        bs::MeshPoint corner = found(mesh.closest_point(shifted(Vec3{2, 2, 0}, s)), "the corner");
        check(corner.triangle == 0 && corner.kind == "vertex" && corner.vertices == Indices{2} && near3(corner.point, shifted(Vec3{1, 1, 0}, s), tol) &&
                  within(corner.distance, std::sqrt(2.0), 1e-9) && near3(corner.barycentric, {0, 0, 1}, 1e-9),
              "the corner reads " + show(corner));
    }
    return {};
}

// 2. a point 2 off the square: found within 2.1, empty within 1.9, NaN and +inf no limit; a point
// on the mesh is within 0; the refusals
static Result<void> point_max_distance() {
    for (const Vec3& s : SHIFTS) {
        bs::TriangleMesh mesh = mesh_of(SQUARE, SQUARE_TRIANGLES, s);
        Vec3 p = shifted(Vec3{0.75, 0.25, 2}, s);
        bs::MeshPoint unlimited = found(mesh.closest_point(p), "no limit");
        check(same(found(mesh.closest_point(p, 2.1), "within 2.1"), unlimited), "2.1 is the unlimited answer");
        nothing(mesh.closest_point(p, 1.9), "within 1.9");
        check(same(found(mesh.closest_point(p, NAN_VALUE), "NaN"), unlimited), "NaN is a limit");
        check(same(found(mesh.closest_point(p, INF_VALUE), "inf"), unlimited), "+inf is a limit");
    }
    bs::TriangleMesh mesh = mesh_of(SQUARE, SQUARE_TRIANGLES, Vec3{0, 0, 0});
    check(must(mesh.closest_point(Vec3{0.5, 0.5, 0}, 0.0), "within 0").has_value(), "a point on the mesh is not within 0");
    refused(mesh.closest_point(Vec3{0.5, 0.5, 1}, -1.0), "triangle_mesh_closest_point: the max distance must not be negative", "closest_point -1");
    refused(mesh.closest_point(Vec3{NAN_VALUE, 0, 0}), "triangle_mesh_closest_point: not finite", "a NaN point");
    return {};
}

// 3. a line up through the tetrahedron crosses its floor first, at t 1/3; a line beside it is 1
// from vertex 1, found within 1.1 and empty within 0.9
static Result<void> a_line_through_a_tetrahedron() {
    for (const Vec3& s : SHIFTS) {
        double tol = shift_tol(s, 1e-9);
        bs::TriangleMesh mesh = mesh_of(TETRA, TETRA_TRIANGLES, s);
        bs::NurbsCurve line = segment(shifted(Vec3{0.2, 0.2, -1}, s), shifted(Vec3{0.2, 0.2, 2}, s));
        bs::CurveMeshFoot foot = found(mesh.curve_closest_points(line), "through the tetrahedron");
        check(foot.crossing && foot.distance == 0 && foot.triangle == 0 && foot.kind == "face" && foot.vertices.empty() && within(foot.t, 1.0 / 3, 1e-9) &&
                  near3(foot.point_on_curve, shifted(Vec3{0.2, 0.2, 0}, s), tol) && near3(foot.point_on_mesh, shifted(Vec3{0.2, 0.2, 0}, s), tol) &&
                  near3(foot.barycentric, {0.6, 0.2, 0.2}, 1e-9),
              "through the tetrahedron reads " + show(foot));
        bs::NurbsCurve beside = segment(shifted(Vec3{2, 0, 0}, s), shifted(Vec3{3, 0, 0}, s));
        bs::CurveMeshFoot near = found(mesh.curve_closest_points(beside, 1.1), "beside within 1.1");
        check(!near.crossing && near.triangle == 0 && near.kind == "vertex" && near.vertices == Indices{1} && within(near.distance, 1, tol) &&
                  within(near.t, 0, tol) && near3(near.point_on_mesh, shifted(Vec3{1, 0, 0}, s), tol),
              "beside reads " + show(near));
        nothing(mesh.curve_closest_points(beside, 0.9), "beside within 0.9");
        check(same(found(mesh.curve_closest_points(beside, NAN_VALUE), "NaN"), near) && same(found(mesh.curve_closest_points(beside, INF_VALUE), "inf"), near),
              "NaN or +inf is a limit");
        refused(mesh.curve_closest_points(beside, -1.0), "triangle_mesh_curve_closest_points: the max distance must not be negative",
                "curve_closest_points -1");
    }
    return {};
}

// 4. a bad index is refused by name; a closed mesh refuses
static Result<void> a_bad_index_and_a_closed_mesh() {
    refused(bs::TriangleMesh::make(SQUARE, Triangles{{0, 1, 4}}), "triangle_mesh_new: triangle 0 names vertex 4, past the vertex count", "a bad index");
    bs::TriangleMesh mesh = mesh_of(SQUARE, SQUARE_TRIANGLES, Vec3{0, 0, 0});
    mesh.close();
    mesh.close();
    check(mesh.closed(), "a closed mesh says it is open");
    refused(mesh.closest_point(Vec3{0, 0, 1}), "triangle_mesh: closed", "a closed mesh");
    bs::NurbsCurve line = segment(Vec3{0, 0, 1}, Vec3{1, 0, 1});
    refused(line.closest_object({bs::NearItem(mesh)}), "triangle_mesh: closed", "a closed mesh item");
    return {};
}

// 5. a solid's measuring mesh: the 2-cube's box, 0 an unset tolerance, a bad tolerance refused,
// answering on after the solid is closed
static Result<void> a_solids_triangle_mesh() {
    bs::Solid cube = must(bs::Solid::cuboid(2, 2, 2), "cube");
    bs::TriangleMesh mesh = must(cube.triangle_mesh(), "triangle_mesh");
    std::uint32_t triangles = must(mesh.triangle_count(), "triangle_count");
    check(triangles >= 12, std::to_string(triangles) + " triangles");
    cadaclysm::Bounds64 box = must(mesh.bounds(), "bounds");
    check(near3(box.min, {-1, -1, -1}, 1e-9) && near3(box.max, {1, 1, 1}, 1e-9), "the 2-cube's box");
    check(must(must(cube.triangle_mesh(0.0), "tolerance 0").triangle_count(), "count") == triangles, "0 is not an unset tolerance");
    for (double bad : {-1.0, INF_VALUE}) {
        refused(cube.triangle_mesh(bad), "solid_triangle_mesh: tolerance must be positive and finite", "a bad tolerance");
    }
    cube.close();
    bs::MeshPoint foot = found(mesh.closest_point(Vec3{5, 0.1, 0.2}), "after the solid");
    check(within(foot.distance, 4, 1e-9) && near3(foot.point, {1, 0.1, 0.2}, 1e-9), "after the solid reads " + show(foot));
    return {};
}

// 6. the nearest object: a mesh wins (answer `mesh`, its own answer), a point after a mesh wins,
// a tie goes to the earlier item either way, the limit
static Result<void> the_nearest_object() {
    bs::TriangleMesh mesh = mesh_of(TETRA, TETRA_TRIANGLES, Vec3{0, 0, 0});
    bs::NurbsCurve line = segment(Vec3{0.2, 0.2, -1}, Vec3{0.2, 0.2, 2});
    bs::NearestObject near = found(line.closest_object({bs::NearItem(Vec3{9, 9, 9}), bs::NearItem(mesh)}), "the mesh's win");
    bs::CurveMeshFoot own = found(mesh.curve_closest_points(line), "its own");
    check(near.which == 1 && !near.body && !near.pair && near.mesh && same(*near.mesh, own), "the mesh's win names item " + std::to_string(near.which));
    check(near.distance == own.distance && near.t == own.t && near.point_on_curve == own.point_on_curve && near.point_on_item == own.point_on_mesh,
          "the mesh's win is its own answer");
    bs::NurbsCurve beside = segment(Vec3{2, 0, 0}, Vec3{3, 0, 0});
    bs::NearestObject after = found(beside.closest_object({bs::NearItem(mesh), bs::NearItem(Vec3{2.5, 0.5, 0})}), "the point after a mesh");
    check(after.which == 1 && !after.mesh && within(after.distance, 0.5, 1e-9), "the point after a mesh");
    bs::NurbsCurve short_line = segment(Vec3{-2, 0, 0}, Vec3{-1, 0, 0});  // 1 from vertex 0 and from the point (0, 0, 0) alike
    bs::NearestObject tie = found(short_line.closest_object({bs::NearItem(mesh), bs::NearItem(Vec3{0, 0, 0})}), "the tie");
    check(tie.which == 0 && tie.distance == 1 && tie.mesh && tie.mesh->vertices == Indices{0}, "the tie names item " + std::to_string(tie.which));
    bs::NearestObject second = found(short_line.closest_object({bs::NearItem(Vec3{0, 0, 0}), bs::NearItem(mesh)}), "the tie the other way");
    check(second.which == 0 && !second.mesh, "the tie the other way");
    nothing(beside.closest_object({bs::NearItem(mesh)}, 0.9), "within 0.9");
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
        {"face_edge_and_vertex_feet", face_edge_and_vertex_feet},
        {"point_max_distance", point_max_distance},
        {"a_line_through_a_tetrahedron", a_line_through_a_tetrahedron},
        {"a_bad_index_and_a_closed_mesh", a_bad_index_and_a_closed_mesh},
        {"a_solids_triangle_mesh", a_solids_triangle_mesh},
        {"the_nearest_object", the_nearest_object},
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
    std::printf("mesh closest points: ok\n");
    return 0;
}
