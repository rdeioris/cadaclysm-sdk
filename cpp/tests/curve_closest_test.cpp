// Closest points from a curve -- at parity with the Python reference's tests in
// test_cadaclysm_blacksmith.py (test_a_nurbs_curve_closest_point_within_reach ..
// test_the_nearest_object_to_a_curve_names_its_item), every figure a closed form written out here,
// at the origin and shifted far out: a point within reach of a line, two skew lines, a line past a
// cube's edge, a line through a cube, the projector against the one-shot, the nearest object of a
// mixed list, and the refusals. Needs the kernel library and a license; the exit code is the
// verdict.
//
//     cadaclysm_curve_closest_test [cadaclysm.lic]
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

static int failures = 0;
static const double NAN_VALUE = std::numeric_limits<double>::quiet_NaN();
static const double INF_VALUE = std::numeric_limits<double>::infinity();
static const std::array<Vec3, 3> SHIFTS = {Vec3{0, 0, 0}, Vec3{1e4, -1e4, 5e3}, Vec3{1e6, -1e6, 5e5}};

static void check(bool ok, const std::string& what) {
    if (ok) return;
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
}

static bool within(double a, double b, double tolerance) { return std::fabs(a - b) <= tolerance; }

static bool near3(const Vec3& a, const Vec3& b, double tolerance) {
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

// The straight curve from `a` to `b`, `t` running 0 to 1.
static bs::NurbsCurve segment(const Vec3& a, const Vec3& b) { return must(bs::NurbsCurve::make({a, b}, 1), "segment"); }

// Every field of two curve-body answers, exactly.
static bool same(const bs::CurveBodyFoot& a, const bs::CurveBodyFoot& b) {
    return a.distance == b.distance && a.t == b.t && a.point_on_curve == b.point_on_curve && a.point_on_body == b.point_on_body && a.kind == b.kind &&
           a.index == b.index && a.edge == b.edge && a.uv == b.uv && a.normal == b.normal && a.refined == b.refined && a.crossing == b.crossing;
}

static bool same(const std::optional<bs::CurveBodyFoot>& a, const std::optional<bs::CurveBodyFoot>& b) { return a && b && same(*a, *b); }

// Every field of two curve pairs, exactly.
static bool same(const bs::CurvePair& a, const bs::CurvePair& b) {
    return a.distance == b.distance && a.t_a == b.t_a && a.point_a == b.point_a && a.t_b == b.t_b && a.point_b == b.point_b;
}

static std::string show(const bs::CurveBodyFoot& f) {
    return "CurveBodyFoot(" + std::to_string(f.distance) + ", t " + std::to_string(f.t) + ", " + f.kind + "#" + std::to_string(f.index) +
           ", crossing " + std::to_string(f.crossing) + ")";
}

// 1. a point 4 off a line at t 0.3: found within 4.1, empty within 3.9, no limit as none
static Result<void> a_point_within_reach() {
    for (const Vec3& s : SHIFTS) {
        bs::NurbsCurve line = segment(shifted(Vec3{0, 0, 0}, s), shifted(Vec3{10, 0, 0}, s));
        Vec3 p = shifted(Vec3{3, 4, 0}, s);
        bs::CurveFoot foot = found(line.closest_point(p, 4.1), "within 4.1");
        check(within(foot.t, 0.3, 1e-12) && near3(foot.point, shifted(Vec3{3, 0, 0}, s), shift_tol(s, 1e-12)) && foot.unique, "within 4.1 reads");
        nothing(line.closest_point(p, 3.9), "within 3.9");
        bs::CurveFoot unlimited = must(line.closest_point(p), "no limit");
        for (std::optional<double> limit : {std::optional<double>(), std::optional<double>(NAN_VALUE), std::optional<double>(INF_VALUE)}) {
            bs::CurveFoot got = found(line.closest_point(p, limit), "an open limit");
            check(got.t == unlimited.t && got.point == unlimited.point && got.unique == unlimited.unique, "an open limit is a limit");
        }
    }
    return {};
}

// 2. two skew lines: 2 apart at t_a 0.3, t_b 0.5; the sides swap with the arguments
static Result<void> two_skew_lines() {
    for (const Vec3& s : SHIFTS) {
        double tol = shift_tol(s, 1e-12);
        bs::NurbsCurve a = segment(shifted(Vec3{0, 0, 0}, s), shifted(Vec3{10, 0, 0}, s));
        bs::NurbsCurve b = segment(shifted(Vec3{3, -5, 2}, s), shifted(Vec3{3, 5, 2}, s));
        for (std::optional<double> limit : {std::optional<double>(2.1), std::optional<double>(), std::optional<double>(NAN_VALUE), std::optional<double>(INF_VALUE)}) {
            bs::CurvePair pair = found(a.closest_points(b, limit), "skew lines");
            check(within(pair.distance, 2, 1e-9) && within(pair.t_a, 0.3, 1e-12) && near3(pair.point_a, shifted(Vec3{3, 0, 0}, s), tol) &&
                      within(pair.t_b, 0.5, 1e-12) && near3(pair.point_b, shifted(Vec3{3, 0, 2}, s), tol),
                  "skew lines read distance " + std::to_string(pair.distance) + " t_a " + std::to_string(pair.t_a) + " t_b " + std::to_string(pair.t_b));
        }
        bs::CurvePair swapped = found(b.closest_points(a), "swapped");
        check(within(swapped.t_a, 0.5, 1e-12) && within(swapped.t_b, 0.3, 1e-12) && near3(swapped.point_a, shifted(Vec3{3, 0, 2}, s), tol), "swapped");
        nothing(a.closest_points(b, 1.9), "skew lines within 1.9");
        refused(a.closest_points(b, -1.0), "nurbs_curve_closest_points: the max distance must not be negative", "closest_points -1");
    }
    return {};
}

// 3. a line whose start lies sqrt(2) off the 2-cube's (1, y, 1) edge: an edge foot; the limit on
// both sides; a projector answers as the one-shot, field for field
static Result<void> a_line_past_an_edge() {
    for (const Vec3& s : SHIFTS) {
        double tol = shift_tol(s, 1e-9);
        bs::Solid cube = must(must(bs::Solid::cuboid(2, 2, 2), "cube").translate(s[0], s[1], s[2]), "shifted cube");
        bs::NurbsCurve line = segment(shifted(Vec3{2, -0.5, 2}, s), shifted(Vec3{2.5, 0.5, 2.5}, s));
        bs::Projector projector = must(cube.projector(), "projector");
        bs::CurveBodyFoot foot = found(cube.curve_closest_points(line, 1.5), "past the edge");
        check(!foot.crossing && foot.kind == "edge" && !foot.uv && foot.edge.has_value() && within(foot.distance, std::sqrt(2.0), tol) &&
                  within(foot.t, 0, 1e-9) && near3(foot.point_on_curve, shifted(Vec3{2, -0.5, 2}, s), tol) &&
                  near3(foot.point_on_body, shifted(Vec3{1, -0.5, 1}, s), tol),
              "past the edge reads " + show(foot));
        if (foot.edge) {
            bs::EdgeFoot at = must(cube.edge_closest_point(*foot.edge, foot.point_on_curve), "edge_closest_point");
            check(near3(at.point, foot.point_on_body, tol) && within(at.distance, foot.distance, tol), "the edge is the public edge");
        }
        nothing(cube.curve_closest_points(line, 1.4), "within 1.4");
        nothing(projector.curve_closest_points(line, 1.4), "the projector within 1.4");
        check(same(must(projector.curve_closest_points(line, 1.5), "projector 1.5"), std::optional<bs::CurveBodyFoot>(foot)), "the projector against the one-shot");
        check(same(must(projector.curve_closest_points(line), "projector"), must(cube.curve_closest_points(line), "one-shot")), "the projector with no limit");
        check(same(must(cube.curve_closest_points(line, NAN_VALUE), "NaN"), must(cube.curve_closest_points(line, INF_VALUE), "inf")), "NaN and +inf differ");
    }
    return {};
}

// 4. a line through the 2-cube crosses its -x face first, at t 1/3, distance 0
static Result<void> a_line_through_a_box() {
    bs::Solid cube = must(bs::Solid::cuboid(2, 2, 2), "cube");
    bs::NurbsCurve through = segment(Vec3{-3, 0.1, 0.2}, Vec3{3, 0.1, 0.2});
    bs::Projector projector = must(cube.projector(), "projector");
    bs::CurveBodyFoot foot = found(cube.curve_closest_points(through), "through the cube");
    check(foot.crossing && foot.distance == 0 && within(foot.t, 1.0 / 3, 1e-9) && near3(foot.point_on_curve, Vec3{-1, 0.1, 0.2}, 1e-9) &&
              near3(foot.point_on_body, Vec3{-1, 0.1, 0.2}, 1e-9) && foot.kind == "face" && !foot.edge && foot.uv.has_value() &&
              near3(foot.normal, Vec3{-1, 0, 0}, 1e-9),
          "through the cube reads " + show(foot));
    check(same(must(projector.curve_closest_points(through), "projector"), std::optional<bs::CurveBodyFoot>(foot)), "the projector through the cube");
    for (double bad : {-1.0, INF_VALUE}) {
        refused(cube.curve_closest_points(through, std::nullopt, bad), "curve_closest_points: tolerance must be positive and finite", "a bad tolerance");
    }
    check(must(cube.curve_closest_points(through, std::nullopt, 0.0), "tolerance 0").has_value(), "0 is an unset tolerance");
    refused(cube.curve_closest_points(through, -1.0), "curve_closest_points: the max distance must not be negative", "curve_closest_points -1");
    refused(projector.curve_closest_points(through, -1.0), "projector_curve_closest_points: the max distance must not be negative", "projector -1");
    return {};
}

// 5. the nearest object: a curve wins (answer kind 1), a point wins (2), a solid or a projector
// alone (0); the limit, an empty list and the refusals
static Result<void> the_nearest_object() {
    bs::Solid cube = must(bs::Solid::cuboid(2, 2, 2), "cube");
    bs::NurbsCurve line = segment(Vec3{2, -0.5, 2}, Vec3{2.5, 0.5, 2.5});
    bs::NurbsCurve other = segment(Vec3{2, -0.5, 2.3}, Vec3{2, 5, 2.3});  // sqrt(0.045) off `line`, at t 0.3
    bs::Projector projector = must(cube.projector(), "projector");
    std::vector<bs::NearItem> items = {bs::NearItem(Vec3{0, 0, 10}), bs::NearItem(cube), bs::NearItem(other), bs::NearItem(projector),
                                       bs::NearItem(Vec3{9, 9, 9})};
    bs::NearestObject nearest = found(line.closest_object(items), "the curve's win");
    bs::CurvePair pair = found(line.closest_points(other), "the pair");
    check(nearest.which == 2 && !nearest.body && nearest.pair && same(*nearest.pair, pair), "the curve's win names item " + std::to_string(nearest.which));
    check(within(nearest.distance, std::sqrt(0.045), 1e-9) && within(nearest.t, 0.3, 1e-9), "the curve's win's distance");
    check(nearest.distance == pair.distance && nearest.t == pair.t_a && nearest.point_on_curve == pair.point_a && nearest.point_on_item == pair.point_b,
          "the curve's win is its pair");
    bs::NearestObject point = found(line.closest_object({bs::NearItem(cube), bs::NearItem(Vec3{2.5, 0.6, 2.5})}), "the point's win");
    check(point.which == 1 && !point.body && !point.pair && within(point.distance, 0.1, 1e-9) && within(point.t, 1, 1e-9) &&
              point.point_on_item == Vec3{2.5, 0.6, 2.5} && near3(point.point_on_curve, Vec3{2.5, 0.5, 2.5}, 1e-9),
          "the point's win names item " + std::to_string(point.which));
    bs::NearestObject solid = found(line.closest_object({bs::NearItem(cube)}), "the solid alone");
    check(solid.which == 0 && !solid.pair && same(solid.body, must(cube.curve_closest_points(line), "one-shot")) && solid.body && solid.body->edge &&
              solid.point_on_item == solid.body->point_on_body,
          "the solid alone");
    bs::NearestObject prepared = found(line.closest_object({bs::NearItem(projector)}, std::nullopt, std::nullopt), "the projector alone");
    check(prepared.which == 0 && same(prepared.body, must(projector.curve_closest_points(line), "projector")), "the projector alone");
    std::vector<bs::NearItem> two = {bs::NearItem(cube), bs::NearItem(other)};
    nothing(line.closest_object(two, 0.2), "within 0.2");
    check(found(line.closest_object(two, 0.25), "within 0.25").which == 1, "within 0.25");
    nothing(line.closest_object({}), "an empty list");
    refused(line.closest_object(two, -1.0), "nurbs_curve_closest_object: the max distance must not be negative", "closest_object -1");
    refused(line.closest_object({bs::NearItem(Vec3{NAN_VALUE, 0, 0})}), "nurbs_curve_closest_object: ", "a NaN point");
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
        {"a_point_within_reach", a_point_within_reach},
        {"two_skew_lines", two_skew_lines},
        {"a_line_past_an_edge", a_line_past_an_edge},
        {"a_line_through_a_box", a_line_through_a_box},
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
    std::printf("curve closest points: ok\n");
    return 0;
}
