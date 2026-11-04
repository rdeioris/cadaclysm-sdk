// Interpolator, Profile::circumscribed_polygon and Solid::merge / regions / region_solid -- at
// parity with the Python reference's test_interpolator_*, test_circumscribed_polygon_touches_its_circle,
// test_merge_* and test_a_merged_body_is_refused_* in test_cadaclysm_blacksmith.py, trimmed to what
// proves the marshalling: every field read, every refusal's prefix, the lists' length and order,
// the handle's lifetime. The kernel's own correctness is the kernel's tests' job. Needs the kernel
// library; the exit code is the verdict.
//
//     cadaclysm_interpolator_merge_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <map>
#include <set>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;
using bs::Box;
using bs::FaceSide;
using bs::Interpolator;
using bs::InterpolatorMode;
using bs::Profile;
using bs::Region;
using bs::Solid;
using bs::Vec2;
using bs::Vec3;

static int failures = 0;
static const double NAN_VALUE = std::numeric_limits<double>::quiet_NaN();
static const double INF_VALUE = std::numeric_limits<double>::infinity();
static const double PI = 3.14159265358979323846;
static const double MERGE_TOL = 1e-6;
static const std::vector<double> SQUARES = {0.0, 1.0, 4.0, 9.0, 16.0};
static const InterpolatorMode MODES[] = {InterpolatorMode::nearest, InterpolatorMode::linear, InterpolatorMode::cosine,
                                         InterpolatorMode::cubic, InterpolatorMode::catmull_rom};

static void check(bool ok, const std::string& what) {
    if (ok) return;
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
}

static bool close_to(double a, double b, double tolerance) { return std::fabs(a - b) <= tolerance; }

static std::string mode_name(InterpolatorMode mode) { return std::to_string(static_cast<std::uint32_t>(mode)); }

// One number out of a dimension-1 answer, checked to be exactly one.
static double scalar(const std::vector<double>& v, const std::string& what) {
    check(v.size() == 1, what + ": " + std::to_string(v.size()) + " numbers, wanted 1");
    return v.empty() ? NAN_VALUE : v[0];
}

static bool close_to_all(const std::vector<double>& a, const std::vector<double>& b, double tolerance) {
    if (a.size() != b.size()) return false;
    for (std::size_t i = 0; i < a.size(); ++i) {
        if (!close_to(a[i], b[i], tolerance)) return false;
    }
    return true;
}

// A refusal check that fails when nothing was refused: the call must have returned an error whose
// text starts with `prefix`.
template <class T>
static void refused(const Result<T>& r, const std::string& prefix, const std::string& what) {
    if (r.ok()) {
        check(false, what + ": expected a refusal, but the call succeeded");
        return;
    }
    const std::string& got = r.error().message;
    check(got.compare(0, prefix.size(), prefix) == 0, what + ": refused with \"" + got + "\", wanted it to start \"" + prefix + "\"");
}

// The same, for a refusal whose whole text is known.
template <class T>
static void refused_with(const Result<T>& r, const std::string& message, const std::string& what) {
    if (r.ok()) {
        check(false, what + ": expected a refusal, but the call succeeded");
        return;
    }
    check(r.error().message == message, what + ": refused with \"" + r.error().message + "\", wanted \"" + message + "\"");
}

// 1
static Result<void> closed_forms_on_the_squares() {
    CADACLYSM_TRY(sq, Interpolator::make(SQUARES));
    check(sq.size() == 5, "size " + std::to_string(sq.size()));
    check(sq.dimension() == 1, "dimension " + std::to_string(sq.dimension()));
    check(!sq.cyclic(), "open");
    for (InterpolatorMode mode : MODES) {
        const std::string name = "mode " + mode_name(mode);
        for (std::size_t k = 0; k < SQUARES.size(); ++k) {
            CADACLYSM_TRY(v, sq.at(static_cast<double>(k), mode));
            double got = scalar(v, name);
            check(close_to(got, SQUARES[k], 1e-12), name + ": sample " + std::to_string(k) + " read " + std::to_string(got));
        }
        CADACLYSM_TRY(below, sq.at(-2.0, mode));
        CADACLYSM_TRY(above, sq.at(7.0, mode));
        check(close_to(scalar(below, name), 0.0, 1e-12), name + ": clamped below");
        check(close_to(scalar(above, name), 16.0, 1e-12), name + ": clamped above");
    }
    CADACLYSM_TRY(n15, sq.nearest(1.5));
    CADACLYSM_TRY(n149, sq.nearest(1.49));
    check(scalar(n15, "nearest") == 4.0, "nearest(1.5) is 4");
    check(scalar(n149, "nearest") == 1.0, "nearest(1.49) is 1");
    CADACLYSM_TRY(l15, sq.linear(1.5));
    check(close_to(scalar(l15, "linear"), 2.5, 1e-12), "linear(1.5)");
    CADACLYSM_TRY(c15, sq.cosine(1.5));
    check(close_to(scalar(c15, "cosine"), 2.5, 1e-12), "cosine(1.5)");
    CADACLYSM_TRY(c125, sq.cosine(1.25));
    check(close_to(scalar(c125, "cosine"), 1.0 + 3.0 * (1.0 - std::cos(PI / 4.0)) / 2.0, 1e-12), "cosine(1.25)");
    CADACLYSM_TRY(cu15, sq.cubic(1.5));
    check(close_to(scalar(cu15, "cubic"), 2.0, 1e-12), "cubic(1.5) " + std::to_string(cu15[0]));
    CADACLYSM_TRY(cr15, sq.catmull_rom(1.5));
    check(close_to(scalar(cr15, "catmull_rom"), 2.25, 1e-12), "catmull_rom(1.5) " + std::to_string(cr15[0]));
    CADACLYSM_TRY(d15, sq.at(1.5));
    check(d15 == l15, "linear by default");

    CADACLYSM_TRY(ring, Interpolator::make(SQUARES, true));
    check(ring.cyclic(), "cyclic");
    CADACLYSM_TRY(r5, ring.catmull_rom(5.0));
    CADACLYSM_TRY(r0, ring.catmull_rom(0.0));
    check(close_to_all(r5, r0, 1e-12), "catmull_rom(5) is catmull_rom(0) on a ring");
    CADACLYSM_TRY(back, ring.linear(-0.5));
    check(close_to(scalar(back, "ring"), 8.0, 1e-12), "halfway from the last sample back to the first");
    return {};
}

// 2
static Result<void> points_and_sample() {
    std::vector<std::vector<double>> helix;
    for (int k = 0; k < 9; ++k) helix.push_back({std::cos(0.7 * k), std::sin(0.7 * k), 0.3 * k});
    CADACLYSM_TRY(h, Interpolator::from_rows(helix));
    check(h.size() == 9, "helix size " + std::to_string(h.size()));
    check(h.dimension() == 3, "helix dimension " + std::to_string(h.dimension()));
    CADACLYSM_TRY(at2, h.at(2.0));
    check(close_to_all(at2, helix[2], 1e-12), "at(2) is sample 2");
    CADACLYSM_TRY(cr, h.catmull_rom(2.5));
    check(cr.size() == 3, "catmull_rom(2.5) answers 3 numbers");
    std::vector<double> ts;
    for (int k = 0; k < 50; ++k) ts.push_back(-1.0 + 10.0 * k / 49.0);
    for (InterpolatorMode mode : MODES) {
        CADACLYSM_TRY(all, h.sample(ts, mode));
        check(all.size() == ts.size(), "mode " + mode_name(mode) + ": " + std::to_string(all.size()) + " values");
        for (std::size_t k = 0; k < ts.size() && k < all.size(); ++k) {
            CADACLYSM_TRY(one, h.at(ts[k], mode));
            check(all[k] == one, "mode " + mode_name(mode) + ": sample " + std::to_string(k) + " is at()");
        }
    }
    CADACLYSM_TRY(none, h.sample({}));
    check(none.empty(), "sample of nothing is empty");

    const std::vector<std::vector<double>> corners = {{0.0, 0.0}, {1.0, 0.0}, {1.0, 1.0}, {0.0, 1.0}};
    CADACLYSM_TRY(square, Interpolator::from_rows(corners, true));
    CADACLYSM_TRY(back, square.linear(-0.5));
    check(close_to_all(back, {0.0, 0.5}, 1e-12), "the square's linear(-0.5)");
    CADACLYSM_TRY(two, square.sample({0.5, 1.5}));
    check(two.size() == 2 && close_to_all(two[0], {0.5, 0.0}, 1e-12) && close_to_all(two[1], {1.0, 0.5}, 1e-12),
          "the square sampled at 0.5 and 1.5");
    return {};
}

// 3
static Result<void> interpolator_refusals() {
    refused(Interpolator::make({}), "interpolator_new: no samples", "no numbers");
    refused(Interpolator::from_rows({}), "interpolator_new: no samples", "no rows");
    refused(Interpolator::make({0.0, 1.0, NAN_VALUE}), "interpolator_new: sample 2 is not finite", "a NaN sample");
    refused(Interpolator::from_rows({{0.0, 1.0}, {2.0, 3.0, 4.0}}), "interpolator: samples differ in length", "unequal rows");
    CADACLYSM_TRY(sq, Interpolator::make(SQUARES));
    refused(sq.linear(NAN_VALUE), "interpolator_at: t NaN is not finite", "a NaN t");
    refused(sq.sample({0.0, INF_VALUE}), "interpolator_sample: t 1 (inf) is not finite", "an infinite t");
    Interpolator moved = std::move(sq);
    check(sq.closed() && !moved.closed(), "a move hands the handle over");
    refused_with(sq.at(1.0), "interpolator: closed", "a moved-from interpolator");
    moved.close();
    moved.close();
    check(moved.closed(), "close() twice");
    refused_with(moved.linear(1.0), "interpolator: closed", "linear after close");
    refused_with(moved.sample({1.0}), "interpolator: closed", "sample after close");
    refused_with(moved.sample({}), "interpolator: closed", "an empty sample after close");
    return {};
}

// 4
static Result<void> circumscribed_polygon_touches_its_circle() {
    const Vec2 centre = {2.0, -1.0};
    const double r = 5.0;
    const std::uint32_t n = 6;
    CADACLYSM_TRY(hex, Profile::circumscribed_polygon(centre, r, n, 0.3));
    CADACLYSM_TRY(lines, hex.polylines());
    check(lines.size() == 1, "one loop");
    if (lines.size() == 1) {
        std::vector<std::vector<float>> rows = lines.copy();
        const std::vector<float>& loop = rows[0];
        std::size_t points = loop.size() / 3;
        check(points == n + 1, std::to_string(points) + " points, wanted the corners and the first again");
        std::vector<Vec2> corners;
        for (std::size_t k = 0; k + 1 < points; ++k) corners.push_back({loop[3 * k], loop[3 * k + 1]});
        for (std::size_t k = 0; k < corners.size(); ++k) {
            const Vec2& a = corners[k];
            const Vec2& b = corners[(k + 1) % corners.size()];
            double mid = std::hypot((a[0] + b[0]) / 2.0 - centre[0], (a[1] + b[1]) / 2.0 - centre[1]);
            check(close_to(mid, r, 1e-6 * r), "side " + std::to_string(k) + "'s midpoint at " + std::to_string(mid));
            double corner = std::hypot(a[0] - centre[0], a[1] - centre[1]);
            double circumradius = r / std::cos(PI / n);
            check(close_to(corner, circumradius, 1e-6 * circumradius), "corner " + std::to_string(k) + " at " + std::to_string(corner));
        }
    }
    CADACLYSM_TRY(length, hex.length());
    double perimeter = 2.0 * n * r * std::tan(PI / n);
    check(close_to(length.length, perimeter, 1e-9 * perimeter), "perimeter " + std::to_string(length.length));
    refused(Profile::circumscribed_polygon({0.0, 0.0}, 10.0, 2), "profile_circumscribed_polygon: a polygon has at least 3 sides, not 2",
            "two sides");
    return {};
}

static Result<double> volume_of(const Solid& body, std::uint32_t region) {
    CADACLYSM_TRY(cell, body.region_solid(region));
    CADACLYSM_TRY(m, cell.mass());
    return m.volume;
}

// 5
static Result<void> two_cubes_at_a_corner() {
    CADACLYSM_TRY(a, Solid::cuboid(1, 1, 1));
    CADACLYSM_TRY(b, a.translate(0.5, 0.5, 0.5));
    std::set<std::string> phases;
    bs::Progress progress = [&phases](std::string_view phase, std::size_t, std::size_t) { phases.insert(std::string(phase)); };
    CADACLYSM_TRY(m, a.merge(b, MERGE_TOL, progress));
    for (const char* phase : {"imprint", "select", "check"}) check(phases.count(phase) == 1, std::string("phase ") + phase);
    check(m.faces() == 18, "faces " + std::to_string(m.faces()));
    CADACLYSM_TRY(regions, m.regions());
    check(regions.size() == 4, std::to_string(regions.size()) + " regions");
    if (regions.size() != 4) return {};
    std::size_t total = 0;
    std::set<std::uint32_t> faces;
    for (std::size_t i = 0; i < regions.size(); ++i) {
        const Region& region = regions[i];
        const std::string name = "region " + std::to_string(i);
        check(region.index == i, name + ": index " + std::to_string(region.index));
        check(region.finite == (i != 0), name + ": finite");
        check(region.shells == 1, name + ": shells " + std::to_string(region.shells));
        total += region.sides.size();
        for (std::size_t k = 0; k < region.sides.size(); ++k) {
            const FaceSide& side = region.sides[k];
            check(side.sense == 1 || side.sense == -1, name + ": sense " + std::to_string(side.sense));
            if (i != 0) faces.insert(side.face);
            if (k > 0) {
                const FaceSide& before = region.sides[k - 1];
                check(std::make_pair(before.face, before.sense) < std::make_pair(side.face, side.sense), name + ": sides ascending");
            }
        }
    }
    check(total == 2 * m.faces(), "each face's two sides: " + std::to_string(total));
    check(faces.size() == m.faces() && *faces.begin() == 0 && *faces.rbegin() == m.faces() - 1,
          "the finite regions' faces cover every face");
    std::map<std::uint32_t, double> volumes;
    for (std::uint32_t i = 1; i < 4; ++i) {
        CADACLYSM_TRY(v, volume_of(m, i));
        volumes[i] = v;
    }
    std::vector<double> sorted;
    for (const std::pair<const std::uint32_t, double>& v : volumes) sorted.push_back(v.second);
    std::sort(sorted.begin(), sorted.end());
    check(close_to(sorted[0], 0.125, 1e-6) && close_to(sorted[1], 0.875, 1e-6) && close_to(sorted[2], 0.875, 1e-6), "cells 1/8, 7/8, 7/8");
    std::uint32_t small = 0;
    for (const std::pair<const std::uint32_t, double>& v : volumes) {
        if (close_to(v.second, 0.125, 1e-6)) small = v.first;
    }
    check(small != 0, "a cell of 1/8");
    if (small != 0) {
        const Region& overlap = regions[small];
        bool behind = overlap.sides.size() == 6;
        for (const FaceSide& side : overlap.sides) behind = behind && side.sense == -1;
        check(behind, "inside both, behind its six walls");
        const Box& box = overlap.box;
        check(close_to(box.lo[0], 0, 1e-6) && close_to(box.lo[1], 0, 1e-6) && close_to(box.lo[2], 0, 1e-6), "the overlap's low corner");
        check(close_to(box.hi[0], 0.5, 1e-6) && close_to(box.hi[1], 0.5, 1e-6) && close_to(box.hi[2], 0.5, 1e-6), "the overlap's high corner");
    }
    CADACLYSM_TRY(again, m.regions());
    check(again == regions, "regions() twice: equal values");
    return {};
}

// 6
static Result<void> a_ball_in_a_box() {
    CADACLYSM_TRY(box, Solid::cuboid(1, 1, 1));
    CADACLYSM_TRY(ball, Solid::sphere(0.3));
    CADACLYSM_TRY(m, box.merge(ball, MERGE_TOL));
    CADACLYSM_TRY(regions, m.regions());
    check(regions.size() == 3, std::to_string(regions.size()) + " regions");
    if (regions.size() != 3) return {};
    double ball_volume = 4.0 / 3.0 * PI * 0.3 * 0.3 * 0.3;
    CADACLYSM_TRY(v1, volume_of(m, 1));
    CADACLYSM_TRY(v2, volume_of(m, 2));
    std::uint32_t outer = v1 > v2 ? 1 : 2;
    std::uint32_t inner = 3 - outer;
    check(close_to(std::max(v1, v2), 1.0 - ball_volume, 1e-6), "the box cell's volume");
    check(close_to(std::min(v1, v2), ball_volume, 1e-6), "the ball's volume");
    check(regions[outer].shells == 2, "the box cell has 2 shells");
    check(regions[inner].shells == 1, "the ball has 1 shell");
    return {};
}

// 7
static Result<void> merge_refusals() {
    CADACLYSM_TRY(a, Solid::cuboid(1, 1, 1));
    CADACLYSM_TRY(b, a.translate(0.5, 0.5, 0.5));
    CADACLYSM_TRY(m, a.merge(b, MERGE_TOL));
    refused(m.join(a, MERGE_TOL), "join: the join needs a manifold solid, and this one has edges of three or more faces",
            "join of a merge");
    refused(m.mass(), "mass_properties: the mass needs a manifold solid", "mass of a merge");
    refused_with(m.region_solid(0), "region_solid: region 0 is the infinite region", "region 0");
    refused_with(m.region_solid(4), "region_solid: region 4 is not below 4", "region 4");
    refused(a.merge(a, 0.0), "merge: tolerance must be positive and finite", "tolerance 0");
    CADACLYSM_TRY(cell, m.region_solid(1));
    CADACLYSM_TRY(joined, cell.join(a, MERGE_TOL));
    check(joined.faces() > 0, "a cell is an ordinary solid again");
    CADACLYSM_TRY(plain, a.regions());
    check(plain.size() == 2, "an ordinary solid has two regions");
    if (plain.size() == 2) {
        bool outside = !plain[0].sides.empty();
        for (const FaceSide& side : plain[0].sides) outside = outside && side.sense == 1;
        bool inside = !plain[1].sides.empty();
        for (const FaceSide& side : plain[1].sides) inside = inside && side.sense == -1;
        check(outside, "the outside is in front of every face");
        check(inside, "the inside is behind every face");
    }
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
        {"closed_forms_on_the_squares", closed_forms_on_the_squares},
        {"points_and_sample", points_and_sample},
        {"interpolator_refusals", interpolator_refusals},
        {"circumscribed_polygon_touches_its_circle", circumscribed_polygon_touches_its_circle},
        {"two_cubes_at_a_corner", two_cubes_at_a_corner},
        {"a_ball_in_a_box", a_ball_in_a_box},
        {"merge_refusals", merge_refusals},
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
    std::printf("interpolator_merge: ok\n");
    return 0;
}
