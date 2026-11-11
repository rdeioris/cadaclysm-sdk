// Closest point from a point -- at parity with the Python reference's tests in
// test_cadaclysm_blacksmith.py (test_closest_point_* .. test_a_nurbs_curve_closest_point_and_its_axis),
// every figure a closed form written out here: the cube's face, edge and vertex feet, the sphere,
// max_distance on both sides of the answer, the projector against the one-shot, one face and one
// edge alone, a NURBS circle, and the refusals. Needs the kernel library and a license; the exit
// code is the verdict.
//
//     cadaclysm_closest_point_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

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

static int failures = 0;
static const double SQRT_HALF = 0.7071067811865476;
static const double INV_SQRT3 = 0.5773502691896258;
static const double NAN_VALUE = std::numeric_limits<double>::quiet_NaN();
static const double INF_VALUE = std::numeric_limits<double>::infinity();

static void check(bool ok, const std::string& what) {
    if (ok) return;
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
}

static bool within(double a, double b, double tolerance) { return std::fabs(a - b) <= tolerance; }

static bool near3(const Vec3& a, const Vec3& b, double tolerance) {
    return within(a[0], b[0], tolerance) && within(a[1], b[1], tolerance) && within(a[2], b[2], tolerance);
}

template <class T>
static T must(Result<T> r, const std::string& what) {
    if (!r.ok()) {
        std::fprintf(stderr, "FAIL: %s: %s\n", what.c_str(), r.error().message.c_str());
        std::exit(1);
    }
    return std::move(r).value();
}

// A foot that must be there.
static bs::PointFoot found(Result<std::optional<bs::PointFoot>> r, const std::string& what) {
    std::optional<bs::PointFoot> foot = must(std::move(r), what);
    if (!foot) {
        std::fprintf(stderr, "FAIL: %s: no foot\n", what.c_str());
        std::exit(1);
    }
    return *foot;
}

// The call must have been refused with exactly `want`, or with a text starting `want` where it
// ends in ": ".
template <class T>
static void refused(const Result<T>& r, const std::string& want, const std::string& what) {
    if (r.ok()) {
        check(false, what + ": expected a refusal, but the call succeeded");
        return;
    }
    const std::string& got = r.error().message;
    bool prefix = want.size() >= 2 && want.compare(want.size() - 2, 2, ": ") == 0;
    check(prefix ? got.compare(0, want.size(), want) == 0 : got == want, what + ": refused with \"" + got + "\", wanted \"" + want + "\"");
}

static std::string show(const bs::PointFoot& f) {
    return "PointFoot(" + std::to_string(f.distance) + ", " + f.kind + "#" + std::to_string(f.index) + ", (" + std::to_string(f.point[0]) + ", " +
           std::to_string(f.point[1]) + ", " + std::to_string(f.point[2]) + "), normal (" + std::to_string(f.normal[0]) + ", " +
           std::to_string(f.normal[1]) + ", " + std::to_string(f.normal[2]) + "))";
}

static bool same(const bs::PointFoot& a, const bs::PointFoot& b) {
    return a.point == b.point && a.distance == b.distance && a.kind == b.kind && a.index == b.index && a.edge == b.edge && a.uv == b.uv &&
           a.normal == b.normal && a.refined == b.refined;
}

// 1. the 10-cube centred on the origin: outside a face, past an edge, past a corner, inside, on
static Result<void> a_cube_names_face_edge_and_vertex() {
    bs::Solid cube = must(bs::Solid::cuboid(10, 10, 10), "cube");
    bs::PointFoot face = found(cube.closest_point(Vec3{20, 0, 0}), "the face foot");
    check(within(face.distance, 15, 1e-9) && near3(face.point, Vec3{5, 0, 0}, 1e-9), "the face foot reads " + show(face));
    check(face.kind == "face" && !face.edge && face.refined && face.uv.has_value() && near3(face.normal, Vec3{1, 0, 0}, 1e-9),
          "the face foot's feature reads " + show(face));
    bs::PointFoot edge = found(cube.closest_point(Vec3{8, 8, 0}), "the edge foot");
    check(within(edge.distance, 4.242640687119285, 1e-9) && near3(edge.point, Vec3{5, 5, 0}, 1e-9), "the edge foot reads " + show(edge));
    check(edge.kind == "edge" && edge.edge.has_value() && !edge.uv && near3(edge.normal, Vec3{SQRT_HALF, SQRT_HALF, 0}, 1e-9),
          "the edge foot's feature reads " + show(edge));
    bs::PointFoot corner = found(cube.closest_point(Vec3{8, 8, 8}), "the corner foot");
    check(within(corner.distance, 5.196152422706632, 1e-9) && near3(corner.point, Vec3{5, 5, 5}, 1e-9), "the corner foot reads " + show(corner));
    check(corner.kind == "vertex" && !corner.edge && !corner.uv && near3(corner.normal, Vec3{INV_SQRT3, INV_SQRT3, INV_SQRT3}, 1e-9),
          "the corner foot's feature reads " + show(corner));
    bs::PointFoot inside = found(cube.closest_point(Vec3{1, 0, 0}), "the inside foot");
    check(within(inside.distance, 4, 1e-9) && near3(inside.point, Vec3{5, 0, 0}, 1e-9), "the inside foot reads " + show(inside));
    bs::PointFoot on = found(cube.closest_point(Vec3{5, 1, 2}), "the on foot");
    check(within(on.distance, 0, 1e-9) && near3(on.normal, Vec3{1, 0, 0}, 1e-9), "the on foot reads " + show(on));
    return {};
}

// 2. a foot's edge is the public edge number: that edge answers the same point
static Result<void> the_edge_is_the_public_edge_number() {
    bs::Solid cube = must(bs::Solid::cuboid(10, 10, 10), "cube");
    const Vec3 p = {8, 8, 1};
    bs::PointFoot foot = found(cube.closest_point(p), "the edge foot");
    if (!foot.edge) return bs::detail::refuse("no edge on " + show(foot));
    std::uint32_t edge = *foot.edge;
    bs::EdgeFoot at = must(cube.edge_closest_point(edge, p), "edge_closest_point");
    check(near3(at.point, Vec3{5, 5, 1}, 1e-9) && within(at.distance, 4.242640687119285, 1e-9),
          "edge " + std::to_string(edge) + " reads (" + std::to_string(at.point[0]) + ", " + std::to_string(at.point[1]) + ", " +
              std::to_string(at.point[2]) + ")");
    Vec3 start = must(cube.edge_point_at_length(edge, 0), "the edge's start").point;  // a straight edge: arc length is the chord
    double s = std::sqrt((start[0] - at.point[0]) * (start[0] - at.point[0]) + (start[1] - at.point[1]) * (start[1] - at.point[1]) +
                         (start[2] - at.point[2]) * (start[2] - at.point[2]));
    bs::At along = must(cube.edge_point_at_length(edge, s), "the point at that arc length");
    check(near3(along.point, at.point, 1e-9) && within(along.parameter, at.t, 1e-9), "t " + std::to_string(at.t) + " is not the edge's own parameter");
    refused(cube.edge_closest_point(99, p), "edge_closest_point: edge 99 of 12", "edge 99");
    return {};
}

// 3. a sphere of radius 2, outside and inside
static Result<void> a_sphere_in_closed_form() {
    bs::Solid sphere = must(bs::Solid::sphere(2), "sphere");
    bs::PointFoot foot = found(sphere.closest_point(Vec3{0, 3, 4}), "the sphere's foot");
    check(within(foot.distance, 3, 1e-9) && near3(foot.point, Vec3{0, 1.2, 1.6}, 1e-9) && near3(foot.normal, Vec3{0, 0.6, 0.8}, 1e-9) &&
              foot.kind == "face",
          "the sphere reads " + show(foot));
    bs::PointFoot inside = found(sphere.closest_point(Vec3{0, 0, 0.5}), "inside the sphere");
    check(within(inside.distance, 1.5, 1e-9) && near3(inside.point, Vec3{0, 0, 2}, 1e-9), "inside the sphere reads " + show(inside));
    return {};
}

// 4. max distance on both sides of the answer, and the one-shot's refusals
static Result<void> max_distance_on_both_sides() {
    bs::Solid cube = must(bs::Solid::cuboid(10, 10, 10), "cube");
    const Vec3 far = {20, 0, 0};
    check(!must(cube.closest_point(far, 14.9), "14.9"), "14.9 found a point 15 away");
    std::optional<bs::PointFoot> within_limit = must(cube.closest_point(far, 15.1), "15.1");
    check(within_limit && within(within_limit->distance, 15, 1e-9), "15.1 missed a point 15 away");
    check(must(cube.closest_point(far, INF_VALUE), "+inf").has_value() && must(cube.closest_point(far, NAN_VALUE), "NaN").has_value(),
          "+inf or NaN is a limit");
    check(must(cube.closest_point(Vec3{5, 1, 2}, 0.0), "on, 0").has_value(), "0 drops a point on the body");
    check(!must(cube.closest_point(Vec3{5.5, 1, 2}, 0.0), "off, 0"), "0 keeps a point off the body");
    refused(cube.closest_point(Vec3{0, 0, 0}, -1.0), "closest_point: the max distance must not be negative", "max distance -1");
    refused(cube.closest_point(Vec3{0, 0, 0}, std::nullopt, -1.0), "closest_point: ", "tolerance -1");
    refused(cube.closest_point(Vec3{0, 0, 0}, std::nullopt, INF_VALUE), "closest_point: ", "tolerance +inf");
    refused(cube.closest_point(Vec3{NAN_VALUE, 0, 0}), "closest_point: ", "a NaN point");
    return {};
}

// 5. a projector answers as the one-shot, outlives its solid, and refuses once closed
static Result<void> a_projector_answers_as_the_one_shot() {
    const std::vector<Vec3> points = {{20, 0, 0}, {8, 8, 0}, {8, 8, 8}, {1, 0, 0}, {0, -7, 2}};
    std::vector<bs::PointFoot> expected;
    bs::Solid cube = must(bs::Solid::cuboid(10, 10, 10), "cube");
    for (const Vec3& p : points) expected.push_back(found(cube.closest_point(p), "the one-shot"));
    bs::Projector projector = must(cube.projector(), "projector");
    cube.close();
    for (std::size_t i = 0; i < points.size(); ++i) {
        bs::PointFoot got = found(projector.closest_point(points[i]), "the projector");
        check(same(got, expected[i]), "the projector reads " + show(got) + ", the one-shot " + show(expected[i]));
    }
    check(!must(projector.closest_point(points[0], 14.9), "projector 14.9"), "projector: 14.9 found a point 15 away");
    std::optional<bs::PointFoot> at_limit = must(projector.closest_point(points[0], 15.1), "projector 15.1");
    check(at_limit && same(*at_limit, expected[0]), "projector: 15.1 is not the one-shot's answer");
    refused(projector.closest_point(Vec3{0, 0, 0}, -1.0), "projector_closest_point: the max distance must not be negative", "projector -1");
    bs::Projector moved = std::move(projector);
    check(projector.closed() && !moved.closed(), "a move leaves the source closed");  // NOLINT(bugprone-use-after-move)
    moved.close();
    moved.close();  // twice is a no-op
    refused(moved.closest_point(Vec3{0, 0, 0}), "projector: closed", "a closed projector");
    bs::Solid ball = must(bs::Solid::sphere(1), "ball");
    refused(ball.projector(-1.0), "projector_new: ", "projector tolerance -1");
    return {};
}

// 6. one face alone
static Result<void> a_face_alone() {
    bs::Solid cube = must(bs::Solid::cuboid(10, 10, 10), "cube");
    std::uint32_t top = bs::NONE;
    for (std::uint32_t f = 0; f < cube.faces() && top == bs::NONE; ++f) {
        if (must(cube.face_ref(f), "face_ref")[6] > 0.5) top = f;
    }
    bs::PointFoot foot = must(cube.face_closest_point(top, Vec3{20, 0, 0}), "past the face's edge");
    check(near3(foot.point, Vec3{5, 0, 5}, 1e-9) && within(foot.distance, 15.811388300841896, 1e-9) && foot.kind == "edge" && foot.refined,
          "past the face's edge reads " + show(foot));
    bs::PointFoot inner = must(cube.face_closest_point(top, Vec3{1, 2, 9}), "above the face");
    check(near3(inner.point, Vec3{1, 2, 5}, 1e-9) && inner.kind == "face" && inner.index == top && !inner.edge && inner.uv.has_value() &&
              near3(inner.normal, Vec3{0, 0, 1}, 1e-9),
          "above the face reads " + show(inner));
    refused(cube.face_closest_point(99, Vec3{0, 0, 0}), "face_closest_point: face 99 of 6", "face 99");
    return {};
}

// 7. a NURBS circle: the nearest point, and a point on its axis (not unique)
static Result<void> a_nurbs_circle_and_its_axis() {
    const std::array<double, 12> xy = {0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1};
    bs::Circle value = must(bs::Circle::make(xy, 2), "circle value");
    bs::NurbsCurve circle = must(value.to_nurbs(), "circle");
    bs::CurveFoot foot = must(circle.closest_point(Vec3{0, 5, 0}), "the circle's foot");
    check(near3(foot.point, Vec3{0, 2, 0}, 1e-9) && foot.unique, "the circle's foot reads t " + std::to_string(foot.t));
    check(near3(must(circle.point(foot.t), "point at t"), foot.point, 1e-12), "t is not the foot's parameter");
    bs::CurveFoot axis = must(circle.closest_point(Vec3{0, 0, 3}), "the axis foot");
    double r = std::sqrt(axis.point[0] * axis.point[0] + axis.point[1] * axis.point[1] + axis.point[2] * axis.point[2]);
    check(!axis.unique && within(r, 2, 1e-9), "the axis foot reads radius " + std::to_string(r));
    refused(circle.closest_point(Vec3{INF_VALUE, 0, 0}), "nurbs_curve_closest_point: ", "an infinite point");
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
        {"a_cube_names_face_edge_and_vertex", a_cube_names_face_edge_and_vertex},
        {"the_edge_is_the_public_edge_number", the_edge_is_the_public_edge_number},
        {"a_sphere_in_closed_form", a_sphere_in_closed_form},
        {"max_distance_on_both_sides", max_distance_on_both_sides},
        {"a_projector_answers_as_the_one_shot", a_projector_answers_as_the_one_shot},
        {"a_face_alone", a_face_alone},
        {"a_nurbs_circle_and_its_axis", a_nurbs_circle_and_its_axis},
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
    std::printf("closest point: ok\n");
    return 0;
}
