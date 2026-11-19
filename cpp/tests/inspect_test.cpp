// Point, edge and face queries -- at parity with the Python reference's tests in
// test_cadaclysm_blacksmith.py (test_a_point_on_a_face_reads_inside_boundary_or_off ..
// test_area_properties_of_a_plate_with_a_hole), every figure a closed form written out here: a
// cube's faces and edges, a bored cube's hole and wall, a pocketed block's concave edges, a
// filleted cube's one tangent group, angles between faces, edges and points, and a plate's area
// properties, with the refusals. Needs the kernel library and a license; the exit code is the
// verdict.
//
//     cadaclysm_inspect_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <string>
#include <utility>
#include <vector>

using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;
using bs::Vec3;
using Indices = std::vector<std::uint32_t>;

static int failures = 0;
static const double PI = 3.14159265358979323846;
static const double HALF_PI = PI / 2.0;
static const double INF_VALUE = std::numeric_limits<double>::infinity();

static void check(bool ok, const std::string& what) {
    if (ok) return;
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
}

static bool within(double a, double b, double tolerance) { return std::fabs(a - b) <= tolerance; }

template <class T>
static T must(Result<T> r, const std::string& what) {
    if (!r.ok()) {
        std::fprintf(stderr, "FAIL: %s: %s\n", what.c_str(), r.error().message.c_str());
        std::exit(1);
    }
    return std::move(r).value();
}

// The call must have been refused with a message that starts with `want`.
template <class T>
static void refused(const Result<T>& r, const std::string& want, const std::string& what) {
    if (r.ok()) {
        check(false, what + ": expected a refusal, but the call succeeded");
        return;
    }
    const std::string& got = r.error().message;
    check(got.compare(0, want.size(), want) == 0, what + ": refused with \"" + got + "\", wanted \"" + want + "...\"");
}

static std::string show(const bs::FacePoint& f) {
    return "FacePoint(" + std::to_string(f.point[0]) + ", " + std::to_string(f.point[1]) + ", " + std::to_string(f.point[2]) + ", distance " +
           std::to_string(f.distance) + ", " + f.where + ")";
}

static std::string list(const Indices& v) {
    std::string out;
    for (std::uint32_t i : v) out += (out.empty() ? "" : ", ") + std::to_string(i);
    return "[" + out + "]";
}

static bs::Solid cube() { return must(bs::Solid::cuboid(2, 2, 2), "cuboid"); }

// The face of `solid` whose inner point is highest.
static std::uint32_t top_face(const bs::Solid& solid) {
    std::uint32_t best = 0;
    double highest = -INF_VALUE;
    for (std::uint32_t f = 0; f < solid.faces(); ++f) {
        double z = must(solid.face_inner_point(f), "face_inner_point").point[2];
        if (z > highest) {
            highest = z;
            best = f;
        }
    }
    return best;
}

// The 2 x 2 x 2 cube about the origin with a bore of radius 0.5 along z through it.
static bs::Solid bored_cube() {
    bs::Solid rod = must(must(bs::Solid::cylinder(0.5, 4), "cylinder").translate(0, 0, -2), "translate");
    return must(cube().cut(rod, std::nullopt), "cut");
}

// The first face whose smallest radius is finite.
static std::uint32_t curved_face(const bs::Solid& solid) {
    for (std::uint32_t f = 0; f < solid.faces(); ++f) {
        if (must(solid.face_minimum_radius(f), "face_minimum_radius").radius < INF_VALUE) return f;
    }
    std::fprintf(stderr, "FAIL: no curved face\n");
    std::exit(1);
}

static Result<void> a_point_on_a_face_reads_inside_boundary_or_off() {
    bs::Solid box = cube();
    std::uint32_t top = top_face(box);
    CADACLYSM_TRY(inner, box.face_inner_point(top));
    check(inner.where == "inside" && inner.distance < 1e-12, "inner point: " + show(inner));
    CADACLYSM_TRY(in, box.face_point(top, Vec3{0.2, 0.1, 1.0}));
    check(in.where == "inside", "on the top face: " + show(in));
    CADACLYSM_TRY(rim, box.face_point(top, Vec3{1.0, 0.1, 1.0}, 1e-6));
    check(rim.where == "boundary", "on its edge: " + show(rim));
    CADACLYSM_TRY(off, box.face_point(top, Vec3{0.2, 0.1, 1.5}));
    check(off.where == "off" && within(off.distance, 0.5, 1e-12) && within(off.point[2], 1.0, 1e-12), "above it: " + show(off));
    // 1e-3 above the face: off at 1e-4, on at 1e-2.
    CADACLYSM_TRY(tight, box.face_point(top, Vec3{0.2, 0.1, 1.001}, 1e-4));
    check(tight.where == "off", "1e-3 above at 1e-4: " + show(tight));
    CADACLYSM_TRY(loose, box.face_point(top, Vec3{0.2, 0.1, 1.001}, 1e-2));
    check(loose.where == "inside", "1e-3 above at 1e-2: " + show(loose));
    CADACLYSM_TRY(size, box.face_size(top));
    check(within(size[0], 2, 1e-9) && within(size[1], 2, 1e-9), "face_size " + std::to_string(size[0]) + " x " + std::to_string(size[1]));
    // The bored cube's top face: a point in the hole is on the plane but off the face.
    bs::Solid bored = bored_cube();
    std::uint32_t lid = top_face(bored);
    CADACLYSM_TRY(hole, bored.face_point(lid, Vec3{0.0, 0.0, 1.0}));
    check(hole.where == "off", "in the hole: " + show(hole));
    CADACLYSM_TRY(lip, bored.face_point(lid, Vec3{0.5, 0.0, 1.0}, 1e-6));
    check(lip.where == "boundary", "on the hole's rim: " + show(lip));
    refused(box.face_point(99, Vec3{0, 0, 0}), "face_point: face 99 of ", "face_point past the end");
    refused(box.face_point(0, Vec3{0, 0, 0}, -1.0), "face_point: tolerance must be positive and finite", "face_point at -1");
    refused(box.face_inner_point(6), "face_inner_point: face 6 of 6", "face_inner_point past the end");
    refused(box.face_size(6), "face_size: face 6 of 6", "face_size past the end");
    return {};
}

static Result<void> a_point_on_an_edge_and_its_parameter() {
    bs::Solid box = cube();
    CADACLYSM_TRY(mid, box.edge_inner_point(0));
    check(mid.on && mid.distance == 0.0, "edge_inner_point on, at 0");
    CADACLYSM_TRY(again, box.edge_point(0, mid.point));
    check(again.on, "the inner point is on its edge");
    Vec3 far = {3 * mid.point[0] + 1, 3 * mid.point[1] + 1, 3 * mid.point[2] + 1};
    CADACLYSM_TRY(e, box.edge_point(0, far));
    check(!e.on && e.distance > 0.5, "a far point is off the edge");
    CADACLYSM_TRY(foot, box.edge_closest_point(0, far));
    check(e.t == foot.t && e.point == foot.point && e.distance == foot.distance, "edge_point agrees with edge_closest_point");
    refused(box.edge_point(12, far), "edge_point: edge 12 of 12", "edge_point past the end");
    refused(box.edge_inner_point(12), "edge_inner_point: edge 12 of 12", "edge_inner_point past the end");
    return {};
}

static Result<void> edge_convexity_on_a_box_and_a_pocket() {
    bs::Solid box = cube();
    CADACLYSM_TRY(kinds, box.edges_convexity());
    check(kinds == std::vector<std::string>(12, "convex"), "a cube's 12 edges are convex");
    CADACLYSM_TRY(convex, box.convex_edges());
    Indices all;
    for (std::uint32_t i = 0; i < 12; ++i) all.push_back(i);
    check(convex == all, "convex_edges " + list(convex));
    CADACLYSM_TRY(concave, box.concave_edges());
    check(concave.empty(), "concave_edges " + list(concave));
    CADACLYSM_TRY(c, box.edge_convexity(3, 0.0));
    check(c.kind == "convex" && c.samples == 16, "edge 3: " + c.kind + " at " + std::to_string(c.samples));
    check(within(c.angle_min, HALF_PI, 1e-12) && within(c.angle_max, HALF_PI, 1e-12),
          "edge 3 turns " + std::to_string(c.angle_min) + " .. " + std::to_string(c.angle_max));
    // A pocket's floor edges and its inside corners are concave: four and four.
    bs::Solid block = must(must(bs::Solid::cuboid(40, 30, 10), "block").translate(0, 0, 5), "translate");
    bs::Solid pocket = must(must(bs::Solid::cuboid(20, 10, 8), "pocket").translate(0, 0, 6), "translate");
    bs::Solid pocketed = must(block.cut(pocket, std::nullopt), "cut");
    CADACLYSM_TRY(inside, pocketed.concave_edges());
    check(inside.size() == 8, "a pocket's concave edges " + list(inside));
    refused(box.edges_convexity(-0.1), "edges_convexity: the angular tolerance -0.1 is not in [0, pi/2)", "edges_convexity at -0.1");
    refused(box.edge_convexity(12), "edge_convexity: edge 12 of 12", "edge_convexity past the end");
    return {};
}

static Result<void> tangent_chains_split_a_box_and_join_a_filleted_one() {
    bs::Solid box = cube();
    CADACLYSM_TRY(groups, box.tangent_face_groups());
    bool alone = groups.size() == 6;
    for (std::size_t g = 0; alone && g < groups.size(); ++g) alone = groups[g] == Indices{static_cast<std::uint32_t>(g)};
    check(alone, "a cube's six faces are six groups");
    CADACLYSM_TRY(faces, box.tangent_faces(2));
    check(faces == Indices{2}, "tangent_faces(2) " + list(faces));
    CADACLYSM_TRY(edges, box.tangent_edges(4));
    check(edges == Indices{4}, "tangent_edges(4) " + list(edges));
    Indices all;
    for (std::uint32_t i = 0; i < 12; ++i) all.push_back(i);
    CADACLYSM_TRY(rounded, box.fillet(all, 0.3));
    std::uint32_t n = rounded.faces();
    Indices every;
    for (std::uint32_t f = 0; f < n; ++f) every.push_back(f);
    CADACLYSM_TRY(one, rounded.tangent_face_groups());
    check(one.size() == 1 && one[0] == every, "a filleted cube is one group of " + std::to_string(n));
    CADACLYSM_TRY(reached, rounded.tangent_faces(0));
    check(!reached.empty() && reached[0] == 0, "tangent_faces starts at its face");
    std::sort(reached.begin(), reached.end());
    check(reached == every, "tangent_faces(0) reaches every face " + list(reached));
    refused(box.tangent_faces(6), "tangent_faces: face 6 of 6", "tangent_faces past the end");
    refused(box.tangent_edges(12), "tangent_edges: edge 12 of 12", "tangent_edges past the end");
    refused(box.tangent_face_groups(2.0), "tangent_face_groups: the angular tolerance 2 is not in [0, pi/2)", "tangent_face_groups at 2");
    return {};
}

static Result<void> angles_between_faces_edges_and_points() {
    bs::Solid box = cube();
    std::vector<double> angles;
    for (std::uint32_t f = 0; f < 6; ++f) {
        CADACLYSM_TRY(a, box.angle_to("face", 0, box, "face", f));
        angles.push_back(a.angle);
    }
    std::sort(angles.begin(), angles.end());
    const std::array<double, 6> want = {0, HALF_PI, HALF_PI, HALF_PI, HALF_PI, PI};
    for (std::size_t i = 0; i < 6; ++i) check(within(angles[i], want[i], 1e-12), "face 0's angle " + std::to_string(i) + ": " + std::to_string(angles[i]));
    CADACLYSM_TRY(same, box.angle_to("face", 0, box, "face", 0));
    check(same.kind == "planes", "two faces are planes: " + same.kind);
    CADACLYSM_TRY(edge_face, box.angle_to("edge", 0, box, "face", 0));
    check(edge_face.kind == "line_plane", "an edge and a face: " + edge_face.kind);
    // A cylinder's axis to its cap: square.
    bs::Solid rod = must(bs::Solid::cylinder(1, 3), "cylinder");
    std::uint32_t side = curved_face(rod);
    std::uint32_t cap = side == 0 ? 1 : 0;
    CADACLYSM_TRY(square, rod.angle_to("face", side, rod, "face", cap));
    check(square.kind == "line_plane" && within(square.angle, HALF_PI, 1e-12), "a cylinder's axis to its cap: " + std::to_string(square.angle));
    CADACLYSM_TRY(right, bs::angle(Vec3{1, 0, 0}, Vec3{0, 0, 0}, Vec3{0, 3, 0}));
    check(within(right, HALF_PI, 1e-15), "angle of three points, square: " + std::to_string(right));
    CADACLYSM_TRY(straight, bs::angle(Vec3{1, 0, 0}, Vec3{0, 0, 0}, Vec3{-2, 0, 0}));
    check(within(straight, PI, 1e-15), "angle of three points, straight: " + std::to_string(straight));
    refused(bs::angle(Vec3{0, 0, 0}, Vec3{0, 0, 0}, Vec3{1, 0, 0}), "angle_points: ", "an arm of no length");
    refused(box.angle_to("vertex", 0, box, "face", 0), "angle_between: a kind is 'face' or 'edge'", "a vertex");
    bs::Solid ball = must(bs::Solid::sphere(1), "sphere");
    refused(ball.angle_to("face", 0, box, "face", 0), "angle_between: face 0 is neither planar nor has an axis", "a sphere's face");
    return {};
}

static Result<void> minimum_radius_of_a_bore_and_a_plane() {
    bs::Solid bored = bored_cube();
    CADACLYSM_TRY(r, bored.face_minimum_radius(curved_face(bored)));
    check(within(r.radius, 0.5, 1e-9) && within(r.curvature, -2.0, 1e-9),
          "the bore's wall: radius " + std::to_string(r.radius) + ", curvature " + std::to_string(r.curvature));
    double length = std::sqrt(r.direction[0] * r.direction[0] + r.direction[1] * r.direction[1] + r.direction[2] * r.direction[2]);
    check(within(length, 1.0, 1e-9) && within(std::hypot(r.at[0], r.at[1]), 0.5, 1e-9), "the wall's direction is unit, its point on the bore");
    bs::Solid box = cube();
    CADACLYSM_TRY(flat, box.face_minimum_radius(0));
    check(flat.radius == INF_VALUE && flat.curvature == 0.0, "a plane: radius " + std::to_string(flat.radius));
    refused(box.face_minimum_radius(6), "face_minimum_radius: face 6 of 6", "face_minimum_radius past the end");
    return {};
}

static Result<void> area_properties_of_a_plate_with_a_hole() {
    CADACLYSM_TRY(plate, bs::Profile::rect(6, 2));
    CADACLYSM_TRY(rect, plate.area_properties());
    check(rect.accuracy_met && within(rect.area, 12, 1e-12) && within(rect.perimeter, 16, 1e-12),
          "a 6 x 2 rectangle: area " + std::to_string(rect.area) + ", perimeter " + std::to_string(rect.perimeter));
    check(within(rect.second_moments[0], 4, 1e-12) && within(rect.second_moments[1], 36, 1e-12) && within(rect.second_moments[2], 0, 1e-12),
          "its second moments " + std::to_string(rect.second_moments[0]) + ", " + std::to_string(rect.second_moments[1]) + ", " +
              std::to_string(rect.second_moments[2]));
    check(within(rect.principal_moments[0], 4, 1e-12) && within(rect.principal_moments[1], 36, 1e-12), "its principal moments");
    // Ixx (4) is the smaller: its axis is x, the second the first turned +90 degrees.
    const bs::Vec2& x = rect.principal_axes[0];
    const bs::Vec2& y = rect.principal_axes[1];
    check(within(std::fabs(x[0]), 1, 1e-12) && within(y[0], -x[1], 1e-12) && within(y[1], x[0], 1e-12), "its principal axes");
    CADACLYSM_TRY(hole, bs::Profile::circle(0.5));
    CADACLYSM_TRY(holed_plate, plate.with_hole(hole));
    CADACLYSM_TRY(holed, holed_plate.area_properties());
    check(within(holed.area, 12 - PI / 4, 1e-9), "with a hole: area " + std::to_string(holed.area));
    check(within(holed.perimeter, 16 + PI, 1e-9), "with a hole: perimeter " + std::to_string(holed.perimeter));
    check(within(holed.second_moments[0], 4 - PI * std::pow(0.5, 4) / 4, 1e-9), "with a hole: Ixx " + std::to_string(holed.second_moments[0]));
    check(std::fabs(holed.centroid[0]) < 1e-12 && std::fabs(holed.centroid[1]) < 1e-12, "with a hole: the centroid at the origin");
    refused(plate.area_properties(2.0), "profile_area_properties: accuracy 2 is not in (0, 1)", "area_properties at 2");
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
        {"a_point_on_a_face_reads_inside_boundary_or_off", a_point_on_a_face_reads_inside_boundary_or_off},
        {"a_point_on_an_edge_and_its_parameter", a_point_on_an_edge_and_its_parameter},
        {"edge_convexity_on_a_box_and_a_pocket", edge_convexity_on_a_box_and_a_pocket},
        {"tangent_chains_split_a_box_and_join_a_filleted_one", tangent_chains_split_a_box_and_join_a_filleted_one},
        {"angles_between_faces_edges_and_points", angles_between_faces_edges_and_points},
        {"minimum_radius_of_a_bore_and_a_plane", minimum_radius_of_a_bore_and_a_plane},
        {"area_properties_of_a_plate_with_a_hole", area_properties_of_a_plate_with_a_hole},
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
    std::printf("point, edge and face queries: ok\n");
    return 0;
}
