// NurbsCurve, Curvature and to_nurbs() on the curve values -- at parity with the Python
// reference's NurbsCurve tests in test_cadaclysm_blacksmith.py: what a curve reads back, the
// builders and edits, joined, tween, the edge/face/plane verbs, every refusal's prefix, the
// maps and values, and a curve outliving what it came from. The kernel's own correctness is
// the kernel's tests' job. Needs the kernel library and a license; the exit code is the verdict.
//
//     cadaclysm_nurbs_curve_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <optional>
#include <string>
#include <utility>
#include <vector>

using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;
using bs::At;
using bs::NurbsCurve;
using bs::Vec3;

static int failures = 0;
static const double PI = 3.14159265358979323846;

static void check(bool ok, const std::string& what) {
    if (ok) return;
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
}

static bool within(double a, double b, double tolerance) { return std::fabs(a - b) <= tolerance; }

static double distance(const Vec3& a, const Vec3& b) {
    return std::sqrt((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]) + (a[2] - b[2]) * (a[2] - b[2]));
}

// A value the test cannot go on without: a refusal here is a failure of the test, not of a check.
template <class T>
static T must(Result<T> r, const std::string& what) {
    if (!r.ok()) {
        std::fprintf(stderr, "FAIL: %s: %s\n", what.c_str(), r.error().message.c_str());
        std::exit(1);
    }
    return std::move(r).value();
}

// A refusal check that fails when nothing was refused: the call must have returned an error
// whose text starts with `prefix` and, if given, contains `inside`.
template <class T>
static void refused(const Result<T>& r, const std::string& prefix, const std::string& inside, const std::string& what) {
    if (r.ok()) {
        check(false, what + ": expected a refusal, but the call succeeded");
        return;
    }
    const std::string& got = r.error().message;
    check(got.compare(0, prefix.size(), prefix) == 0, what + ": refused with \"" + got + "\", wanted it to start \"" + prefix + "\"");
    check(inside.empty() || got.find(inside) != std::string::npos,
          what + ": refused with \"" + got + "\", wanted it to contain \"" + inside + "\"");
}

// The quarter of the circle of radius `r` in the xy plane, exact (rational quadratic).
static NurbsCurve quarter_circle(double r = 2.0) {
    return must(NurbsCurve::make({{r, 0, 0}, {r, r, 0}, {0, r, 0}}, 2, std::vector<double>{1.0, std::sqrt(0.5), 1.0}), "quarter circle");
}

// The whole circle of radius `r` about the z axis at height `z`, exact (nine-point rational
// quadratic).
static NurbsCurve whole_circle(double r, double z = 0.0) {
    double h = std::sqrt(0.5);
    std::vector<Vec3> points = {{r, 0, z}, {r, r, z}, {0, r, z}, {-r, r, z}, {-r, 0, z}, {-r, -r, z}, {0, -r, z}, {r, -r, z}, {r, 0, z}};
    return must(NurbsCurve::make(points, 2, std::vector<double>{1, h, 1, h, 1, h, 1, h, 1},
                                 std::vector<double>{0, 0, 0, 0.25, 0.25, 0.5, 0.5, 0.75, 0.75, 1, 1, 1}),
                "whole circle");
}

static Vec3 end_of(const NurbsCurve& c, bool last) {
    std::pair<double, double> d = must(c.domain(), "domain");
    return must(c.point(last ? d.second : d.first), "end point");
}

// Each tween's ends are a's and b's blended at (i + 1) / (count + 1).
static void ends_blended(const NurbsCurve& a, const NurbsCurve& b, const std::vector<NurbsCurve>& tweens, double tolerance,
                         const std::string& what) {
    Vec3 a0 = end_of(a, false), a1 = end_of(a, true), b0 = end_of(b, false), b1 = end_of(b, true);
    for (std::size_t i = 0; i < tweens.size(); ++i) {
        double f = static_cast<double>(i + 1) / static_cast<double>(tweens.size() + 1);
        Vec3 m0 = {a0[0] + f * (b0[0] - a0[0]), a0[1] + f * (b0[1] - a0[1]), a0[2] + f * (b0[2] - a0[2])};
        Vec3 m1 = {a1[0] + f * (b1[0] - a1[0]), a1[1] + f * (b1[1] - a1[1]), a1[2] + f * (b1[2] - a1[2])};
        check(distance(end_of(tweens[i], false), m0) < tolerance && distance(end_of(tweens[i], true), m1) < tolerance,
              what + ": tween " + std::to_string(i) + " ends are the blended ends");
    }
}

// 1
static Result<void> reads_back_what_it_was_built_from() {
    NurbsCurve q = quarter_circle();
    check(q.degree() == 2 && q.is_rational() && !q.is_closed(), "Q is a rational open quadratic");
    check(must(q.control_points(), "control points") == std::vector<Vec3>({{2, 0, 0}, {2, 2, 0}, {0, 2, 0}}),
          "the control points are as given");
    std::vector<double> weights = must(q.weights(), "weights");
    check(weights.size() == 3 && weights[0] == 1.0 && weights[1] == std::sqrt(0.5) && weights[2] == 1.0, "the weights are as given");
    check(must(q.knots(), "knots") == std::vector<double>({0, 0, 0, 1, 1, 1}), "the knots are clamped");
    check(must(q.domain(), "domain") == std::make_pair(0.0, 1.0), "the domain is 0..1");
    check(!q.fit_error().has_value(), "a built curve has no fit_error");
    check(within(distance(must(q.point(0.37), "point"), Vec3{0, 0, 0}), 2.0, 1e-12), "the point is on the circle");
    bs::Curvature k = must(q.curvature(0.5), "curvature");
    check(within(k.kappa, 0.5, 1e-12), "kappa is 1 / radius");
    check(k.centre.has_value() && distance(*k.centre, Vec3{0, 0, 0}) < 1e-12, "the centre is the origin");
    check(within(must(q.length(), "length").length, PI, 1e-9), "the length is pi");
    At at = must(q.point_at_length(PI / 2), "point_at_length");
    check(distance(at.point, Vec3{std::sqrt(2.0), std::sqrt(2.0), 0}) < 1e-9 && !at.segment.has_value(), "the point at half the length");
    check(must(q.divide_by_count(4), "divide_by_count").size() == 5, "divide_by_count(4) gives 5");
    check(must(q.divide_by_length(1.0), "divide_by_length").size() == 4, "divide_by_length(1) gives 4");
    std::vector<Vec3> d = must(q.derivatives(0.0, 2), "derivatives");
    check(d.size() == 3 && d[0] == Vec3({2, 0, 0}) && std::fabs(d[1][0]) < 1e-12 && d[1][1] > 0, "derivatives(0, 2)");
    NurbsCurve line = must(NurbsCurve::make({{0, 0, 0}, {1, 0, 0}}, 1), "line");
    bs::Curvature straight = must(line.curvature(0.5), "straight curvature");
    check(!straight.centre.has_value() && straight.kappa == 0.0, "a straight piece has no centre and no curvature");
    check(!line.is_rational(), "a curve given no weights is a plain B-spline");
    check(must(line.weights(), "plain weights") == std::vector<double>({1.0, 1.0}), "a plain curve weighs 1 everywhere");
    return {};
}

// 2
static Result<void> through_and_edits() {
    std::vector<Vec3> ring;
    for (int i = 0; i < 10; ++i) {
        double a = 2 * PI * i / 10;
        ring.push_back(Vec3{std::cos(a), std::sin(a), 0.2 * std::sin(3 * a)});
    }
    NurbsCurve closed = must(NurbsCurve::through(ring, 3, true), "closed ring");
    check(closed.is_closed() && must(closed.divide_by_count(6), "ring divide").size() == 6, "a closed ring");
    std::vector<Vec3> pts = {{0, 0, 0}, {1, 2, 0.5}, {3, 1, -0.5}, {4, 3, 1}, {6, 2, 0}};
    NurbsCurve c = must(NurbsCurve::through(pts, 3, false, Vec3{0, 0, 5}), "through with a start tangent");
    std::pair<double, double> dom = must(c.domain(), "domain");
    std::vector<Vec3> d = must(c.derivatives(dom.first, 1), "start derivative");
    check(std::fabs(d[1][0]) < 1e-9 && std::fabs(d[1][1]) < 1e-9 && d[1][2] > 0, "it leaves along the start tangent");
    std::vector<Vec3> wave;
    for (int t = 0; t < 200; ++t) wave.push_back(Vec3{t / 50.0, std::sin(t / 50.0), 0});
    NurbsCurve fit = must(NurbsCurve::fit(wave, 3, 1e-4), "fit");
    check(fit.fit_error().has_value() && *fit.fit_error() >= 0 && *fit.fit_error() <= 1e-4, "fit lands within its tolerance");
    NurbsCurve back = must(c.reversed(), "reversed");
    check(distance(must(back.point(dom.first), "reversed start"), must(c.point(dom.second), "end")) < 1e-12, "reversed starts where it ended");
    double mid = 0.5 * (dom.first + dom.second);
    check(must(must(c.trimmed(dom.first, mid), "trimmed").domain(), "trimmed domain") == std::make_pair(dom.first, mid), "trimmed to the first half");
    NurbsCurve longer = must(c.extended(0.5), "extended");
    check(must(longer.domain(), "extended domain").second > dom.second &&
              distance(must(longer.point(dom.second), "kept point"), must(c.point(dom.second), "old point")) < 1e-9,
          "extended keeps every old parameter");
    NurbsCurve before = must(c.extended(0.5, true), "extended at the start");
    check(must(before.domain(), "start-extended domain").first < dom.first, "extended at the start grows downward");
    check(must(c.elevated(2), "elevated").degree() == 5, "elevated by 2");
    return {};
}

// 3
static Result<void> joined() {
    NurbsCurve lead = must(NurbsCurve::make({{2, -3, 0}, {2, 0, 0}}, 1), "lead");
    NurbsCurve arc = quarter_circle();
    NurbsCurve tail = must(NurbsCurve::make({{0, 2, 0}, {-1, 2.5, 0}, {-2, 2, 1}, {-3, 3, 0}, {-4, 2, 0}, {-5, 2, 2}}, 5), "tail");
    std::vector<NurbsCurve> parts;
    parts.push_back(lead);
    parts.push_back(must(arc.reversed(), "arc reversed"));
    parts.push_back(tail);
    NurbsCurve j = must(NurbsCurve::joined(parts), "joined");
    check(j.degree() == 5 && must(j.domain(), "joined domain") == std::make_pair(0.0, 3.0), "joined is a quintic over 0..3");
    const std::pair<double, Vec3> joints[] = {{0, {2, -3, 0}}, {1, {2, 0, 0}}, {2, {0, 2, 0}}, {3, {-5, 2, 2}}};
    for (const std::pair<double, Vec3>& want : joints) {
        check(distance(must(j.point(want.first), "joint"), want.second) < 1e-12, "joint at " + std::to_string(want.first));
    }
    bool on_circle = true, on_tail = true;
    for (int i = 0; i <= 20; ++i) {
        on_circle = on_circle && std::fabs(distance(must(j.point(1 + i / 20.0), "arc part"), Vec3{0, 0, 0}) - 2) < 1e-12;
        on_tail = on_tail && distance(must(j.point(2 + i / 20.0), "tail part"), must(tail.point(i / 20.0), "tail")) < 1e-12;
    }
    check(on_circle, "the middle third stays on the circle");
    check(on_tail, "the last third is the tail");
    std::vector<NurbsCurve> one;
    one.push_back(arc);
    check(must(NurbsCurve::joined(one), "joined one").control_points().value() == arc.control_points().value(), "one curve gives a copy");
    std::vector<NurbsCurve> gap;
    gap.push_back(lead);
    gap.push_back(tail);
    refused(NurbsCurve::joined(gap), "nurbs_curve_joined: curve 1 ", "curve 0", "a gap");
    refused(NurbsCurve::joined(std::vector<NurbsCurve>()), "nurbs_curve_joined: ", "", "no curves");
    return {};
}

// 4
static Result<void> tweens() {
    NurbsCurve a = must(NurbsCurve::make({{0, 0, 0}, {3, 2, 0}, {6, -1, 0}, {10, 0, 0}}, 3), "a");
    NurbsCurve b = must(NurbsCurve::make({{0, 1, 5}, {4, 4, 5}, {7, -3, 6}, {10, 1, 5}}, 3), "b");
    std::vector<NurbsCurve> plain = must(a.tween(b, 3, "plain"), "plain");
    check(plain.size() == 3, "three plain tweens");
    ends_blended(a, b, plain, 1e-12, "plain");
    check(distance(must(plain[1].control_points(), "plain controls")[1], Vec3{3.5, 3, 2.5}) < 1e-12, "the middle plain tween's second control point");
    std::vector<NurbsCurve> matching = must(a.tween(b, 2), "matching");
    check(matching.size() == 2, "two matching tweens");
    ends_blended(a, b, matching, 1e-12, "matching");
    std::vector<NurbsCurve> sampled = must(a.tween(b, 4, "sampling", 20u), "sampling");
    bool cubics = true;
    for (const NurbsCurve& t : sampled) cubics = cubics && t.degree() == 3;
    check(sampled.size() == 4 && cubics, "four sampled cubics");
    ends_blended(a, b, sampled, 1e-9, "sampling");
    check(must(a.tween(b, 1, "matching", std::nullopt, true, 0.0), "tolerance 0").size() == 1, "tolerance 0 asks for the default");
    NurbsCurve q = must(NurbsCurve::make({{0, 1, 5}, {5, 4, 5}, {10, 1, 5}}, 2), "quadratic");
    refused(a.tween(q, 2, "plain"), "nurbs_curve_tween: ", "compatible", "plain on a quadratic");
    std::vector<NurbsCurve> mixed = must(a.tween(q, 2), "mixed");
    check(mixed[0].degree() == 3, "matching makes a cubic of the pair");
    ends_blended(a, q, mixed, 1e-12, "mixed");
    refused(a.tween(b, 0), "nurbs_curve_tween: ", "", "count 0");
    // The wrapper's own refusals, before the call.
    refused(a.tween(b, 2, "sampling"), "nurbs_curve_tween: sampling needs samples", "", "sampling without samples");
    refused(a.tween(b, 2, "matching", 10u), "nurbs_curve_tween: samples is read only by sampling, not matching", "", "matching with samples");
    refused(a.tween(b, 2, "loft"), "nurbs_curve_tween: method must be one of plain, matching, sampling, not 'loft'", "", "an unknown method");
    refused(a.tween(b, 2, "sampling", 1u), "nurbs_curve_tween: sampling needs at least", "", "one sample");
    // Two circles: the tweens are closed circles.
    NurbsCurve small = whole_circle(2), big = whole_circle(4, 6);
    const std::pair<const char*, std::optional<std::uint32_t>> methods[] = {{"matching", std::nullopt}};
    for (const std::pair<const char*, std::optional<std::uint32_t>>& m : methods) {
        std::vector<NurbsCurve> rings = must(small.tween(big, 3, m.first, m.second), "circle tweens");
        check(rings.size() == 3, "three circle tweens");
        for (std::size_t i = 0; i < rings.size(); ++i) {
            double f = static_cast<double>(i + 1) / 4.0;
            check(rings[i].is_closed(), "tween " + std::to_string(i) + " is closed");
            std::pair<double, double> dom = must(rings[i].domain(), "ring domain");
            for (int k = 0; k < 24; ++k) {
                Vec3 p = must(rings[i].point(dom.first + (dom.second - dom.first) * k / 24), "ring point");
                check(std::fabs(std::hypot(p[0], p[1]) - (2 + 2 * f)) < 1e-12 && std::fabs(p[2] - 6 * f) < 1e-12,
                      "tween " + std::to_string(i) + " point " + std::to_string(k) + " is on its circle");
            }
        }
    }
    return {};
}

// 5
static Result<void> edge_faces_planes_blend_comb() {
    bs::Solid cyl = must(bs::Solid::cylinder(2.5, 4), "cylinder");
    std::vector<NurbsCurve> rims;
    for (const bs::Edge& e : must(cyl.edges(), "edges")) {
        if (e.kind == "circle") rims.push_back(must(NurbsCurve::from_edge(cyl, e), "from_edge"));
    }
    check(rims.size() >= 2, "a cylinder has two circle rims");
    for (const NurbsCurve& rim : rims) {
        std::pair<double, double> dom = must(rim.domain(), "rim domain");
        const double ts[3] = {dom.first, 0.5 * (dom.first + dom.second), dom.second};
        for (double t : ts) {
            Vec3 p = must(rim.point(t), "rim point");
            check(std::fabs(std::hypot(p[0], p[1]) - 2.5) < 1e-12, "a rim point is on the radius");
        }
    }
    bs::Solid sphere = must(bs::Solid::sphere(3), "sphere");
    NurbsCurve line = must(NurbsCurve::make({{-2, 0.5, 10}, {2, -0.5, 10}}, 1), "line");
    NurbsCurve on = must(line.projected_to_face(sphere, 0, Vec3{0, 0, -1}, 1e-4), "projected_to_face");
    check(on.fit_error().has_value() && *on.fit_error() <= 1e-4, "the projection reports its fit error");
    std::pair<double, double> dom = must(on.domain(), "projected domain");
    check(std::fabs(distance(must(on.point(0.5 * (dom.first + dom.second)), "projected mid"), Vec3{0, 0, 0}) - 3) < 1e-4,
          "the projection lies on the sphere");
    NurbsCurve pulled = must(line.pulled_to_face(sphere, 0, 1e-4), "pulled_to_face");
    check(pulled.fit_error().has_value(), "the pull reports its fit error");
    check(std::fabs(distance(must(pulled.point(must(pulled.domain(), "pulled domain").first), "pulled start"), Vec3{0, 0, 0}) - 3) < 1e-4,
          "the pull lies on the sphere");
    NurbsCurve through = must(NurbsCurve::make({{-5, 1, 1}, {5, 1, 1}}, 1), "through");
    std::vector<At> hits = must(through.face_hits(sphere, 0, 1e-6), "face_hits");
    check(hits.size() == 2 && std::fabs(hits[0].point[0] + std::sqrt(7.0)) < 1e-6, "the line crosses the sphere twice");
    std::vector<At> crossing = must(through.plane_hits(Vec3{0, 0, 0}, Vec3{1, 0, 0}), "plane_hits");
    check(crossing.size() == 1 && distance(crossing[0].point, Vec3{0, 1, 1}) < 1e-12, "the line crosses the plane once");
    NurbsCurve flat = must(line.projected_to_plane(Vec3{0, 0, 1}, Vec3{0, 0, 1}), "projected_to_plane");
    check(must(flat.point(0), "flat start") == Vec3({-2, 0.5, 1}), "projected onto the plane z = 1");
    NurbsCurve blend = must(NurbsCurve::blend(quarter_circle(), true, through, false, 2), "blend");
    check(blend.degree() == 5 && std::fabs(must(blend.curvature(0), "blend curvature").kappa - 0.5) < 1e-9, "a quintic matching the curvature");
    std::vector<std::pair<Vec3, Vec3>> teeth = must(quarter_circle().comb(8), "comb");
    bool half = true;
    for (const std::pair<Vec3, Vec3>& tooth : teeth) half = half && std::fabs(distance(tooth.first, tooth.second) - 0.5) < 1e-9;
    check(teeth.size() == 9 && half, "nine teeth of 0.5");
    return {};
}

// 6
static Result<void> refusals() {
    NurbsCurve q = quarter_circle();
    bs::Solid box = must(bs::Solid::cuboid(1, 1, 1), "cuboid");
    refused(NurbsCurve::make({{0, 0, 0}, {1, 0, 0}}, 9), "nurbs_curve_new: ", "", "degree 9");
    refused(NurbsCurve::make({{0, 0, 0}, {1, 0, 0}}, 1, std::vector<double>{1, -1}), "nurbs_curve_new: ", "", "a negative weight");
    refused(NurbsCurve::make({{0, 0, 0}, {1, 0, 0}, {2, 0, 0}}, 2, std::vector<double>{1, 1}),
            "nurbs_curve_new: 2 weights for 3 points; give one per point", "", "two weights for three points");
    refused(NurbsCurve::through({{0, 0, 0}, {1, 0, 0}}, 3), "nurbs_curve_through: ", "", "through: too few points");
    refused(NurbsCurve::fit({{0, 0, 0}, {1, 0, 0}}, 1, -1.0), "nurbs_curve_fit: ", "", "a negative fit tolerance");
    refused(NurbsCurve::from_edge(box, 999u), "nurbs_curve_from_edge: ", "", "edge 999");
    refused(NurbsCurve::isocurve(box, 0, true, 0.5), "nurbs_curve_from_face_isocurve: ", "", "an isocurve of a plane");
    refused(NurbsCurve::blend(q, true, q, true, 3), "nurbs_curve_blend: ", "", "continuity 3");
    refused(q.projected_to_plane(Vec3{0, 0, 0}, Vec3{0, 0, 1}, Vec3{1, 0, 0}), "nurbs_curve_projected_to_plane: ", "", "a direction in the plane");
    refused(q.trimmed(0.5, 0.2), "nurbs_curve_trimmed: ", "", "t0 after t1");
    refused(q.extended(0), "nurbs_curve_extended: ", "", "no length");
    refused(q.point(2), "nurbs_curve_point: ", "", "a point past the domain");
    refused(q.derivatives(0.5, 9), "nurbs_curve_derivatives: ", "", "order 9");
    refused(q.divide_by_count(0), "nurbs_curve_divide_by_count: ", "", "divide into 0");
    refused(q.plane_hits(Vec3{0, 0, 0}, Vec3{0, 0, 1}), "nurbs_curve_plane_hits: ", "", "a curve in the plane");
    return {};
}

// 7
static Result<void> maps_and_values() {
    NurbsCurve c = must(NurbsCurve::make({{0, 0, 0}, {1, 1, 1}, {2, 0, 0}}, 2, std::vector<double>{1, 0.5, 1}), "weighted");
    NurbsCurve moved = must(c.transformed(must(bs::Transform::translation(Vec3{1, 2, 3}), "translation")), "transformed");
    Vec3 was = must(c.point(0.5), "point"), now = must(moved.point(0.5), "moved point");
    check(distance(now, Vec3{was[0] + 1, was[1] + 2, was[2] + 3}) < 1e-12, "the point moves with the map");
    check(must(moved.weights(), "moved weights") == must(c.weights(), "weights"), "the weights are kept");
    check(must(moved.knots(), "moved knots") == must(c.knots(), "knots"), "the knots are kept");
    NurbsCurve by_rows = must(c.transformed(must(bs::Transform::translation(Vec3{1, 2, 3}), "translation").rows()), "transformed by rows");
    check(distance(must(by_rows.point(0.5), "rows point"), now) < 1e-12, "sixteen numbers do the same");

    bs::Line line = must(bs::Line::make(Vec3{0, 0, 0}, Vec3{2, 0, 0}), "line value");
    NurbsCurve ln = must(line.to_nurbs(), "line to_nurbs");
    std::pair<double, double> dom = must(ln.domain(), "line domain");
    check(ln.degree() == 1 && distance(must(ln.point(0.5 * (dom.first + dom.second)), "line mid"), Vec3{1, 0, 0}) < 1e-12, "a line is degree 1");

    bs::Frame at = must(bs::Frame::make(Vec3{1, -2, 0.5}, Vec3{1, 0, 0}, Vec3{0, 1, 0}, Vec3{0, 0, 1}), "frame");
    bs::Circle circle = must(bs::Circle::make(at, 3.0), "circle value");
    NurbsCurve cn = must(circle.to_nurbs(), "circle to_nurbs");
    check(cn.is_rational() && cn.is_closed(), "a circle is rational and closed");
    std::pair<double, double> cd = must(cn.domain(), "circle domain");
    for (int k = 0; k < 16; ++k) {
        Vec3 p = must(cn.point(cd.first + (cd.second - cd.first) * k / 16), "circle point");
        check(std::fabs(distance(p, Vec3{1, -2, 0.5}) - 3) < 1e-12, "circle point " + std::to_string(k) + " is at the radius");
    }
    return {};
}

// 8
static Result<void> lifetime() {
    std::vector<NurbsCurve> kept;
    {
        NurbsCurve a = must(NurbsCurve::make({{0, 0, 0}, {3, 2, 0}, {6, -1, 0}, {10, 0, 0}}, 3), "a");
        NurbsCurve b = must(NurbsCurve::make({{0, 1, 5}, {4, 4, 5}, {7, -3, 6}, {10, 1, 5}}, 3), "b");
        kept = must(a.tween(b, 3, "plain"), "tweens");
    }
    for (const NurbsCurve& t : kept) check(must(t.control_points(), "tween controls").size() == 4, "a tween outlives its parents");
    std::optional<NurbsCurve> rim;
    {
        bs::Solid cyl = must(bs::Solid::cylinder(2.5, 4), "cylinder");
        for (const bs::Edge& e : must(cyl.edges(), "edges")) {
            if (e.kind == "circle") {
                rim = must(NurbsCurve::from_edge(cyl, e), "from_edge");
                break;
            }
        }
    }
    check(rim.has_value(), "a rim was found");
    if (rim) {
        std::pair<double, double> dom = must(rim->domain(), "rim domain");
        Vec3 p = must(rim->point(dom.first), "rim point");
        check(std::fabs(std::hypot(p[0], p[1]) - 2.5) < 1e-12, "an edge curve outlives its solid");
    }
    // Copies are independent; a move leaves its source empty.
    NurbsCurve q = quarter_circle();
    NurbsCurve copy = q;
    NurbsCurve moved = std::move(q);
    check(copy.handle() != moved.handle() && q.handle() == nullptr, "a copy is its own handle and a move empties its source");
    check(must(copy.control_points(), "copy controls") == must(moved.control_points(), "moved controls"), "the copy reads like the original");
    NurbsCurve cloned = must(copy.clone(), "clone");
    check(cloned.handle() != copy.handle() && cloned.degree() == 2, "clone is a new handle");
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
        {"reads_back_what_it_was_built_from", reads_back_what_it_was_built_from},
        {"through_and_edits", through_and_edits},
        {"joined", joined},
        {"tweens", tweens},
        {"edge_faces_planes_blend_comb", edge_faces_planes_blend_comb},
        {"refusals", refusals},
        {"maps_and_values", maps_and_values},
        {"lifetime", lifetime},
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
    std::printf("nurbs_curve: ok\n");
    return 0;
}
