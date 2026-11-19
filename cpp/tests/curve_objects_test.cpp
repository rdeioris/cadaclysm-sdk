// Curves as objects -- at parity with the Python reference's tests in
// test_cadaclysm_blacksmith.py: a helix and its fit error, a line's lengths by fraction and over
// a sub-range, equidistant and as-contour division, its length mass, a box face's trimmed
// isocurve read back as isoparametric, a box's section and contour curves, and a refusal's
// prefix. The kernel's own correctness is the kernel's tests' job. Needs the kernel library and
// a license; the exit code is the verdict.
//
//     cadaclysm_curve_objects_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <cmath>
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
using bs::SectionCurve;
using bs::Vec3;

static int failures = 0;

static void check(bool ok, const std::string& what) {
    if (ok) return;
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
}

static bool within(double a, double b, double tolerance) { return std::fabs(a - b) <= tolerance; }

static bool close(const Vec3& a, const Vec3& b, double tolerance) {
    return within(a[0], b[0], tolerance) && within(a[1], b[1], tolerance) && within(a[2], b[2], tolerance);
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

template <class T>
static void refused(const Result<T>& r, const std::string& prefix, const std::string& what) {
    if (r.ok()) {
        check(false, what + ": expected a refusal, but the call succeeded");
        return;
    }
    const std::string& got = r.error().message;
    check(got.compare(0, prefix.size(), prefix) == 0, what + ": refused with \"" + got + "\", wanted it to start \"" + prefix + "\"");
}

// The whole length of a curve over its domain.
static double length_of(const NurbsCurve& c) {
    std::pair<double, double> dom = must(c.domain(), "domain");
    return must(c.length_between(dom.first, dom.second, 1e-12), "length_between").length;
}

// The straight line from the origin to (10, 0, 0) over [0, 1].
static NurbsCurve line() { return must(NurbsCurve::make({{0, 0, 0}, {10, 0, 0}}, 1), "line"); }

static Result<void> helix() {
    NurbsCurve h = must(NurbsCurve::spiral(bs::AxisLine{Vec3{0, 0, 0}, Vec3{0, 0, 1}}, Vec3{2, 0, 0}, 1.0, 2.0), "spiral");
    check(h.fit_error().has_value() && *h.fit_error() > 0.0 && *h.fit_error() <= 1e-6,
          "the helix reports a small fit error, got " + (h.fit_error() ? std::to_string(*h.fit_error()) : std::string("none")));
    std::pair<double, double> dom = must(h.domain(), "helix domain");
    check(close(must(h.point(dom.first), "helix start"), Vec3{2, 0, 0}, 1e-12), "the helix starts at its start");
    check(close(must(h.point(dom.second), "helix end"), Vec3{2, 0, 2}, 1e-12), "two turns of pitch 1 end at (2, 0, 2)");
    NurbsCurve out = must(NurbsCurve::spiral(bs::AxisLine{Vec3{0, 0, 0}, Vec3{0, 0, 1}}, Vec3{2, 0, 0}, 0.0, 1.0, 4.0), "spiral out");
    check(close(must(out.point(must(out.domain(), "spiral domain").second), "spiral end"), Vec3{4, 0, 0}, 1e-12),
          "a flat spiral ends at its end radius");
    return {};
}

static Result<void> lengths_and_divisions() {
    NurbsCurve c = line();
    bs::Length l = must(c.length_between(0.2, 0.5), "length_between");
    check(within(l.length, 3.0, 1e-12) && l.accuracy_met, "the length over [0.2, 0.5] is 3");
    At quarter = must(c.point_at_normalized_length(0.25), "point_at_normalized_length");
    check(within(quarter.point[0], 2.5, 1e-12) && within(quarter.parameter, 0.25, 1e-12), "a quarter of the way is x = 2.5");
    std::vector<At> fs = must(c.points_at_normalized_lengths({1.0, 0.0, 0.5}), "points_at_normalized_lengths");
    check(fs.size() == 3 && fs[0].point[0] == 10.0 && fs[1].point[0] == 0.0 && within(fs[2].point[0], 5.0, 1e-12),
          "the fractions in the order given, the ends exactly");
    check(must(c.points_at_normalized_lengths({}), "no fractions").empty(), "no fractions give no points");
    std::vector<At> every3 = must(c.divide_equidistant(3.0), "divide_equidistant");
    check(every3.size() == 4, "every 3 along 10 is 4 points, got " + std::to_string(every3.size()));
    for (std::size_t k = 0; k < every3.size(); ++k) check(within(every3[k].point[0], 3.0 * k, 1e-9), "equidistant point " + std::to_string(k));
    std::vector<At> contours = must(c.divide_as_contour(Vec3{0, 0, 0}, Vec3{10, 0, 0}, 2.5), "divide_as_contour");
    check(contours.size() == 5, "planes every 2.5 from 0 to 10 cross it 5 times, got " + std::to_string(contours.size()));
    for (std::size_t k = 0; k < contours.size(); ++k) check(within(contours[k].point[0], 2.5 * k, 1e-12), "contour point " + std::to_string(k));
    check(!contours.empty() && within(contours.back().point[0], 10.0, 1e-12), "the last contour point is x = 10");
    return {};
}

static Result<void> length_mass() {
    bs::LengthMass m = must(line().mass(), "mass");
    const double i = 1000.0 / 12.0;
    check(within(m.length, 10.0, 1e-12) && m.accuracy_met && !m.from_polyline, "the line's mass length is 10");
    check(close(m.centroid, Vec3{5, 0, 0}, 1e-12), "the centroid is the middle");
    check(within(m.principal_moments[0], 0.0, 1e-9) && within(m.principal_moments[1], i, 1e-9) && within(m.principal_moments[2], i, 1e-9),
          "the principal moments are 0, L^3/12, L^3/12");
    check(within(m.inertia[1][1], i, 1e-9) && within(m.inertia[2][2], i, 1e-9) && within(m.inertia[0][0], 0.0, 1e-9), "the inertia diagonal");
    check(within(std::fabs(m.principal_axes[0][0]), 1.0, 1e-12), "the first principal axis is the line's own");
    check(within(m.radii[2], std::sqrt(i / 10.0), 1e-9), "the radius of gyration");
    return {};
}

static Result<void> face_isocurves() {
    bs::Solid cube = must(bs::Solid::cuboid(1, 1, 1), "cuboid");
    std::vector<std::pair<double, double>> intervals = must(cube.face_iso_intervals(0, true, 0.0), "face_iso_intervals");
    check(!intervals.empty() && intervals.back().second > intervals.front().first, "face 0 has an interval along u at 0");
    std::vector<NurbsCurve> pieces = must(NurbsCurve::face_isocurves(cube, 0, true, 0.0, 0.0), "face_isocurves");
    check(pieces.size() == 1, "one piece, got " + std::to_string(pieces.size()));
    if (pieces.size() == 1) {
        check(pieces[0].fit_error().has_value() && *pieces[0].fit_error() <= 1e-12, "the piece is exact");
        check(within(length_of(pieces[0]), 1.0, 1e-12), "the piece is 1 long");
        std::optional<std::pair<std::string, double>> iso = must(pieces[0].is_isoparametric(cube, 0, 0.0), "is_isoparametric");
        check(iso.has_value() && iso->first == "u" && within(iso->second, 0.0, 1e-9), "the piece runs along u at 0");
    }
    check(must(NurbsCurve::face_isocurves(cube, 0, true, 1e6), "face_isocurves far").empty(), "an at the face never reaches gives none");
    std::optional<std::pair<std::string, double>> off = must(line().is_isoparametric(cube, 0), "is_isoparametric off");
    check(!off.has_value(), "a line off the face is not isoparametric");
    return {};
}

static Result<void> sections_and_contours() {
    bs::Solid box = must(bs::Solid::cuboid(40, 30, 20), "box");
    std::vector<SectionCurve> section = must(box.section_curves(Vec3{0, 0, 3}, Vec3{0, 0, 1}), "section_curves");
    check(section.size() == 1, "one section curve, got " + std::to_string(section.size()));
    if (section.size() == 1) {
        check(section[0].closed && section[0].exact && section[0].error == 0.0 && section[0].plane == 0, "a closed exact rectangle");
        check(within(length_of(section[0].curve), 140.0, 1e-9), "its length is 140");
    }
    check(must(box.section_curves(Vec3{0, 0, 50}, Vec3{0, 0, 1}), "section far").empty(), "a plane past the box gives none");
    std::vector<SectionCurve> contours = must(box.contour_curves(Vec3{0, 0, -10}, Vec3{0, 0, 10}, 5.0), "contour_curves");
    check(contours.size() == 5, "five contour curves, got " + std::to_string(contours.size()));
    for (std::size_t k = 0; k < contours.size(); ++k) {
        const SectionCurve& c = contours[k];
        check(c.plane == k && c.closed && c.exact, "contour " + std::to_string(k) + " on plane " + std::to_string(c.plane));
        Vec3 start = must(c.curve.point(must(c.curve.domain(), "contour domain").first), "contour start");
        check(within(start[2], -10.0 + 5.0 * k, 1e-12), "contour " + std::to_string(k) + " lies at its plane's height");
    }
    return {};
}

static Result<void> refusals() {
    NurbsCurve c = line();
    bs::Solid box = must(bs::Solid::cuboid(1, 1, 1), "cuboid");
    refused(NurbsCurve::spiral(bs::AxisLine{Vec3{0, 0, 0}, Vec3{0, 0, 1}}, Vec3{2, 0, 0}, 1.0, 0.0), "nurbs_curve_spiral: ", "no turns");
    refused(c.length_between(0.5, 0.2), "nurbs_curve_length_between: ", "a range running backwards");
    refused(c.point_at_normalized_length(1.5), "nurbs_curve_point_at_normalized_length: ", "a fraction past 1");
    refused(c.divide_equidistant(0.0), "nurbs_curve_divide_equidistant: ", "a distance of 0");
    refused(c.divide_as_contour(Vec3{0, 0, 0}, Vec3{0, 0, 0}, 1.0), "nurbs_curve_divide_as_contour: ", "no direction");
    refused(c.mass(std::nan("")), "nurbs_curve_mass: ", "a NaN accuracy");
    refused(NurbsCurve::face_isocurves(box, 99, true, 0.0), "nurbs_curve_face_isocurves: ", "face 99");
    refused(box.face_iso_intervals(99, true, 0.0), "face_iso_intervals: ", "face 99");
    refused(c.is_isoparametric(box, 99), "nurbs_curve_is_isoparametric: ", "face 99");
    refused(box.section_curves(Vec3{0, 0, 0}, Vec3{0, 0, 0}), "solid_section_curves: ", "a zero normal");
    refused(box.contour_curves(Vec3{0, 0, 0}, Vec3{0, 0, 1}, 0.0), "solid_contour_curves: ", "an interval of 0");
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
        {"helix", helix},
        {"lengths_and_divisions", lengths_and_divisions},
        {"length_mass", length_mass},
        {"face_isocurves", face_isocurves},
        {"sections_and_contours", sections_and_contours},
        {"refusals", refusals},
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
    std::printf("curve_objects: ok\n");
    return 0;
}
