// Closest points against an untrimmed NURBS surface -- at parity with the Python reference's tests
// in test_cadaclysm_blacksmith.py (test_a_nurbs_surface_holds_its_net_and_reads_back ..
// test_the_nearest_object_to_a_curve_takes_a_nurbs_surface), every figure a closed form written
// out here, at the origin and shifted far out: the flat sheet's interior, edge and corner feet,
// the max distance on both sides, a line through it and a line beside its edge, a solid's face
// surface and a surface's sheet, the nearest object of a list holding a surface, and the
// refusals. Needs the kernel library and a license; the exit code is the verdict.
//
//     cadaclysm_surface_closest_test [cadaclysm.lic]
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
using Range = std::pair<double, double>;
using Domain = std::pair<Range, Range>;
using Counts = std::pair<std::uint32_t, std::uint32_t>;

static int failures = 0;
static const double NAN_VALUE = std::numeric_limits<double>::quiet_NaN();
static const double INF_VALUE = std::numeric_limits<double>::infinity();
static const std::array<Vec3, 3> SHIFTS = {Vec3{0, 0, 0}, Vec3{1e4, -1e4, 5e3}, Vec3{1e6, -1e6, 5e5}};

// 2 x 2 points of degree 1: S(u, v) = (u, v, 0) over [0, 1]^2, its normal +z.
static const std::vector<Vec3> SHEET = {Vec3{0, 0, 0}, Vec3{0, 1, 0}, Vec3{1, 0, 0}, Vec3{1, 1, 0}};

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

// The call must have been refused with a message starting `prefix`.
template <class T>
static void refused_as(const Result<T>& r, const std::string& prefix, const std::string& what) {
    check(!r.ok() && r.error().message.rfind(prefix, 0) == 0, what + ": not refused as \"" + prefix + "...\"");
}

// The straight curve from `a` to `b`, `t` running 0 to 1.
static bs::NurbsCurve segment(const Vec3& a, const Vec3& b) { return must(bs::NurbsCurve::make({a, b}, 1), "segment"); }

// The sheet shifted by `s`.
static bs::NurbsSurface sheet_of(const Vec3& s) {
    std::vector<Vec3> moved;
    for (const Vec3& p : SHEET) moved.push_back(shifted(p, s));
    return must(bs::NurbsSurface::make(moved, Counts{2, 2}, 1, 1), "sheet");
}

// Every field of two surface points, exactly.
static bool same(const bs::SurfacePoint& a, const bs::SurfacePoint& b) {
    return a.point == b.point && a.distance == b.distance && a.u == b.u && a.v == b.v && a.normal == b.normal && a.boundary == b.boundary;
}

// Every field of two curve-surface answers, exactly.
static bool same(const bs::CurveSurfaceFoot& a, const bs::CurveSurfaceFoot& b) {
    return a.distance == b.distance && a.t == b.t && a.point_on_curve == b.point_on_curve && a.point_on_surface == b.point_on_surface &&
           a.u == b.u && a.v == b.v && a.normal == b.normal && a.boundary == b.boundary && a.crossing == b.crossing;
}

static Result<void> the_net_reads_back() {
    for (const Vec3& s : SHIFTS) {
        bs::NurbsSurface sheet = sheet_of(s);
        std::uint32_t du = must(sheet.degree_u(), "degree_u");
        std::uint32_t dv = must(sheet.degree_v(), "degree_v");
        Counts counts = must(sheet.counts(), "counts");
        Domain domain = must(sheet.domain(), "domain");
        check(du == 1 && dv == 1 && counts == Counts{2, 2} && domain == Domain{Range{0, 1}, Range{0, 1}}, "the sheet reads back");
        check(near3(must(sheet.point_at(0.25, 0.75), "point_at"), shifted(Vec3{0.25, 0.75, 0}, s), shift_tol(s, 1e-12)), "point_at");
        check(near3(must(sheet.normal_at(0.25, 0.75), "normal_at"), Vec3{0, 0, 1}, 1e-12), "normal_at");
    }
    // weights and knots reach the surface: a 3 x 2 net over u in [2, 6], v in [-1, 1]
    std::vector<Vec3> net = {Vec3{0, 0, 0}, Vec3{0, 1, 0}, Vec3{1, 0, 1}, Vec3{1, 1, 1}, Vec3{2, 0, 0}, Vec3{2, 1, 0}};
    bs::NurbsSurface w = must(bs::NurbsSurface::make(net, Counts{3, 2}, 2, 1, std::vector<double>{1, 1, 2, 2, 1, 1},
                                                     std::vector<double>{2, 2, 2, 6, 6, 6}, std::vector<double>{-1, -1, 1, 1}),
                              "weighted");
    check(must(w.counts(), "counts") == Counts{3, 2} && must(w.degree_u(), "degree_u") == 2 &&
              must(w.domain(), "domain") == Domain{Range{2, 6}, Range{-1, 1}},
          "the weighted net reads back");
    check(near3(must(w.point_at(4, -1), "point_at"), Vec3{1, 0, 2.0 / 3}, 1e-12), "the weights reach the surface");
    refused_as(w.point_at(1, 0), "nurbs_surface_point_at: ", "point_at outside the domain");
    return {};
}

static Result<void> interior_edge_and_corner_feet() {
    for (const Vec3& s : SHIFTS) {
        double tol = shift_tol(s, 1e-9);
        bs::NurbsSurface sheet = sheet_of(s);
        bs::SurfacePoint inside = found(sheet.closest_point(shifted(Vec3{0.3, 0.4, 1}, s)), "the interior");
        check(!inside.boundary && near3(inside.point, shifted(Vec3{0.3, 0.4, 0}, s), tol) && within(inside.distance, 1, tol) &&
                  within(inside.u, 0.3, 1e-9) && within(inside.v, 0.4, 1e-9) && near3(inside.normal, Vec3{0, 0, 1}, 1e-9),
              "the interior foot");
        bs::SurfacePoint edge = found(sheet.closest_point(shifted(Vec3{2, 0.5, -1}, s)), "beyond the edge");
        check(edge.boundary && edge.u == 1 && within(edge.v, 0.5, 1e-9) && within(edge.distance, std::sqrt(2.0), tol) &&
                  near3(edge.point, shifted(Vec3{1, 0.5, 0}, s), tol),
              "the edge foot");
        bs::SurfacePoint corner = found(sheet.closest_point(shifted(Vec3{2, 2, 0}, s)), "beyond the corner");
        check(corner.boundary && corner.u == 1 && corner.v == 1 && within(corner.distance, std::sqrt(2.0), tol) &&
                  near3(corner.point, shifted(Vec3{1, 1, 0}, s), tol),
              "the corner foot");
        // the limit on both sides; empty, NaN and +inf are none
        Vec3 p = shifted(Vec3{0.3, 0.4, 1}, s);
        check(same(found(sheet.closest_point(p, 1.1), "within 1.1"), inside), "1.1 finds a point 1 away");
        nothing(sheet.closest_point(p, 0.9), "within 0.9");
        check(same(found(sheet.closest_point(p, NAN_VALUE), "NaN"), inside), "NaN is no limit");
        check(same(found(sheet.closest_point(p, INF_VALUE), "+inf"), inside), "+inf is no limit");
    }
    bs::NurbsSurface sheet = sheet_of(Vec3{0, 0, 0});
    check(must(sheet.closest_point(Vec3{0.5, 0.5, 0}, 0.0), "within 0").has_value(), "a point on the surface is within 0");
    refused(sheet.closest_point(Vec3{0.5, 0.5, 1}, -1.0), "nurbs_surface_closest_point: the max distance must not be negative", "-1");
    refused(sheet.closest_point(Vec3{NAN_VALUE, 0, 0}), "nurbs_surface_closest_point: not finite", "a NaN point");
    return {};
}

static Result<void> a_line_through_and_a_line_beside() {
    for (const Vec3& s : SHIFTS) {
        double tol = shift_tol(s, 1e-9);
        bs::NurbsSurface sheet = sheet_of(s);
        bs::NurbsCurve through = segment(shifted(Vec3{0.25, 0.5, -1}, s), shifted(Vec3{0.25, 0.5, 1}, s));
        bs::CurveSurfaceFoot foot = found(sheet.curve_closest_points(through), "through the sheet");
        check(foot.crossing && foot.distance == 0 && !foot.boundary && within(foot.t, 0.5, 1e-9) && within(foot.u, 0.25, 1e-9) &&
                  within(foot.v, 0.5, 1e-9) && near3(foot.point_on_curve, shifted(Vec3{0.25, 0.5, 0}, s), tol) &&
                  near3(foot.point_on_surface, foot.point_on_curve, tol) && near3(foot.normal, Vec3{0, 0, 1}, 1e-9),
              "the crossing");
        // a line beside the u = 1 edge: the edge answers, boundary true, 1 away at t 0.5
        bs::NurbsCurve beside = segment(shifted(Vec3{2, 0.5, -1}, s), shifted(Vec3{2, 0.5, 1}, s));
        bs::CurveSurfaceFoot side = found(sheet.curve_closest_points(beside, 1.1), "beside the edge");
        check(!side.crossing && side.boundary && within(side.distance, 1, tol) && within(side.t, 0.5, 1e-9) && side.u == 1 &&
                  within(side.v, 0.5, 1e-9) && near3(side.point_on_surface, shifted(Vec3{1, 0.5, 0}, s), tol) &&
                  near3(side.point_on_curve, shifted(Vec3{2, 0.5, 0}, s), tol),
              "the boundary foot of a line beside the edge");
        nothing(sheet.curve_closest_points(beside, 0.9), "beside within 0.9");
        check(same(found(sheet.curve_closest_points(beside), "unlimited"), side), "empty is no limit");
        check(same(found(sheet.curve_closest_points(beside, NAN_VALUE), "NaN"), side), "NaN is no limit");
        check(same(found(sheet.curve_closest_points(beside, INF_VALUE), "+inf"), side), "+inf is no limit");
        refused(sheet.curve_closest_points(beside, -1.0), "nurbs_surface_curve_closest_points: the max distance must not be negative", "-1");
    }
    return {};
}

static Result<void> a_face_surface_and_a_sheet() {
    std::vector<bs::NurbsSurface> faces;
    {
        bs::Solid cube = must(bs::Solid::cuboid(2, 2, 2), "cuboid");
        for (std::uint32_t f = 0; f < 6; ++f) faces.push_back(must(cube.face_surface(f), "face_surface"));
        refused_as(cube.face_surface(99), "solid_face_surface: ", "face 99");
    }
    for (const bs::NurbsSurface& face : faces) {
        bs::SurfacePoint foot = found(face.closest_point(Vec3{0, 0, 0}), "a face of the 2-cube");
        check(within(foot.distance, 1, 1e-12), "a face of the 2-cube lies 1 from its centre, after the solid");
    }
    bs::NurbsSurface wide = must(bs::NurbsSurface::make({Vec3{0, 0, 0}, Vec3{0, 2, 0}, Vec3{3, 0, 0}, Vec3{3, 2, 0}}, Counts{2, 2}, 1, 1,
                                                        std::nullopt, std::vector<double>{5, 5, 9, 9}, std::vector<double>{-1, -1, 1, 1}),
                                 "wide");
    check(must(wide.domain(), "domain") == Domain{Range{5, 9}, Range{-1, 1}}, "the knots reach the domain");
    bs::Solid sheet = must(wide.to_sheet(), "to_sheet");
    bs::NurbsSurface own = must(sheet.face_surface(0), "the sheet's face");
    check(sheet.faces() == 1 && must(own.domain(), "domain") == Domain{Range{0, 1}, Range{0, 1}}, "the sheet is one face over [0, 1]^2");
    return {};
}

static Result<void> a_bad_grid_count_and_a_closed_surface() {
    refused(bs::NurbsSurface::make(SHEET, Counts{2, 3}, 1, 1), "nurbs_surface_new: 2 x 3 points take 18 numbers, got 12", "a bad grid count");
    refused(bs::NurbsSurface::make(SHEET, Counts{2, 2}, 0, 1), "nurbs_surface_new: u degree 0 is not 1 to 7", "degree 0");
    bs::NurbsSurface sheet = sheet_of(Vec3{0, 0, 0});
    sheet.close();
    sheet.close();
    check(sheet.closed(), "a closed surface says it is open");
    refused(sheet.closest_point(Vec3{0, 0, 1}), "nurbs_surface: closed", "a closed surface");
    return {};
}

static Result<void> the_nearest_object() {
    bs::NurbsSurface sheet = sheet_of(Vec3{0, 0, 0});
    bs::NurbsCurve beside = segment(Vec3{2, 0.5, -1}, Vec3{2, 0.5, 1});
    bs::NearestObject near = found(beside.closest_object({bs::NearItem(Vec3{9, 9, 9}), bs::NearItem(sheet)}), "the surface's win");
    bs::CurveSurfaceFoot own = found(sheet.curve_closest_points(beside), "its own");
    check(near.which == 1 && !near.body && !near.pair && !near.mesh && near.surface && same(*near.surface, own),
          "the surface's win names item " + std::to_string(near.which));
    check(near.distance == own.distance && near.t == own.t && near.point_on_curve == own.point_on_curve && near.point_on_item == own.point_on_surface,
          "the surface's win is its own answer");
    bs::NearestObject after = found(beside.closest_object({bs::NearItem(sheet), bs::NearItem(Vec3{2.5, 0.5, 0})}), "the point after a surface");
    check(after.which == 1 && !after.surface && within(after.distance, 0.5, 1e-9), "the point after a surface");
    nothing(beside.closest_object({bs::NearItem(sheet)}, 0.9), "within 0.9");
    return {};
}

// An answer kind this wrapper does not know is an error, never read as a point; kind 2 is a
// point, every member empty.
static Result<void> an_unknown_answer_kind() {
    CadaclysmBlacksmithNearestObject raw{};
    raw.which = 0;
    raw.distance = 1;
    for (std::int32_t kind : {5, -1, 99}) {
        raw.answer_kind = kind;
        refused(bs::detail::nearest_object_of(raw),
                "nurbs_curve_closest_object: the library answered kind " + std::to_string(kind) + ", not 0 to 4",
                "answer kind " + std::to_string(kind));
    }
    raw.answer_kind = 2;
    bs::NearestObject point = must(bs::detail::nearest_object_of(raw), "answer kind 2");
    check(!point.body && !point.pair && !point.mesh && !point.surface && point.distance == 1, "answer kind 2 is a point");
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
        {"the_net_reads_back", the_net_reads_back},
        {"interior_edge_and_corner_feet", interior_edge_and_corner_feet},
        {"a_line_through_and_a_line_beside", a_line_through_and_a_line_beside},
        {"a_face_surface_and_a_sheet", a_face_surface_and_a_sheet},
        {"a_bad_grid_count_and_a_closed_surface", a_bad_grid_count_and_a_closed_surface},
        {"the_nearest_object", the_nearest_object},
        {"an_unknown_answer_kind", an_unknown_answer_kind},
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
    std::printf("surface closest points: ok\n");
    return 0;
}
