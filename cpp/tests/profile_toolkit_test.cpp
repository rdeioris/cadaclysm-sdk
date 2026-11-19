// The 2D profile toolkit -- Profile::union_, difference, regions, contains, relationship,
// deviation, offset with a corner style, offset_open, reduce_segments, merge_colinear,
// break_at_kinks, is_convex, make_closed and with_seam -- at parity with the Python
// reference's tests test_profile_union_difference_and_regions_are_exact,
// test_profile_contains_relationship_and_deviation, test_profile_offset_corner_and_end_styles
// and test_profile_polyline_tools in test_cadaclysm_blacksmith.py, every figure a closed form
// written out here. The kernel's own correctness is the kernel's tests' job. Needs the kernel
// library and a license; the exit code is the verdict.
//
//     cadaclysm_profile_toolkit_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <string>
#include <utility>
#include <vector>

using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;
using bs::Profile;
using bs::Vec2;

static int failures = 0;
static const double PI = 3.14159265358979323846;

static void check(bool ok, const std::string& what) {
    if (ok) return;
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
}

static std::string num(double v) {
    char buf[64];
    std::snprintf(buf, sizeof buf, "%.17g", v);
    return buf;
}

static void near(double got, double want, double tol, const std::string& what) {
    check(std::fabs(got - want) <= tol, what + ": got " + num(got) + ", want " + num(want));
}

template <class T>
static T must(Result<T> r, const std::string& what) {
    if (!r.ok()) {
        std::fprintf(stderr, "FAIL: %s: %s\n", what.c_str(), r.error().message.c_str());
        std::exit(1);
    }
    return std::move(r).value();
}

// The call must have been refused with a message starting `prefix`.
template <class T>
static void refused(const Result<T>& r, const std::string& prefix, const std::string& what) {
    if (r.ok()) {
        check(false, what + ": expected a refusal, but the call succeeded");
        return;
    }
    const std::string& got = r.error().message;
    check(got.compare(0, prefix.size(), prefix) == 0, what + ": refused with \"" + got + "\", wanted \"" + prefix + "...\"");
}

static double area(const Profile& p) { return must(p.area_properties(), "area_properties").area; }

// A straight-sided profile's side count: one Bezier (16 numbers) a side.
static std::size_t sides(const Profile& p) { return must(p.beziers(), "beziers").size() / 16; }

// The one profile a list must hold.
static Profile only(Result<std::vector<Profile>> r, const std::string& what) {
    std::vector<Profile> ps = must(std::move(r), what);
    if (ps.size() != 1) {
        std::fprintf(stderr, "FAIL: %s: %zu profiles, want 1\n", what.c_str(), ps.size());
        std::exit(1);
    }
    return std::move(ps[0]);
}

static void union_difference_and_regions() {
    Profile a = must(Profile::rect(10, 10), "rect");
    Profile b = must(a.translate(5, 5), "translate");
    near(area(only(a.union_(b), "union")), 175, 1e-9, "union area");
    near(area(only(a.difference(b), "difference")), 75, 1e-9, "difference area");
    Profile outer = must(Profile::circle(5), "circle 5");
    Profile inner = must(Profile::circle(2), "circle 2");
    near(area(only(outer.difference(inner), "ring")), 21 * PI, 1e-9 * 21 * PI, "ring area");
    std::vector<Profile> regions = must(Profile::regions({a, b}), "regions");
    std::vector<double> areas;
    for (const Profile& r : regions) areas.push_back(area(r));
    std::sort(areas.begin(), areas.end());
    check(areas.size() == 3, "regions: " + std::to_string(areas.size()) + ", want 3");
    if (areas.size() == 3) {
        near(areas[0], 25, 1e-9, "region 0");
        near(areas[1], 75, 1e-9, "region 1");
        near(areas[2], 75, 1e-9, "region 2");
    }
}

static void contains_and_relationship() {
    Profile sq = must(Profile::rect(10, 10), "rect");
    check(must(sq.contains(Vec2{0, 0}), "contains") == bs::Containment::inside, "(0, 0) inside");
    check(must(sq.contains(Vec2{5, 0}), "contains") == bs::Containment::on, "(5, 0) on");
    check(must(sq.contains(Vec2{6, 0}), "contains") == bs::Containment::outside, "(6, 0) outside");
    Profile far = must(sq.translate(20, 0), "translate");
    Profile edge = must(sq.translate(10, 0), "translate");
    Profile half = must(sq.translate(5, 0), "translate");
    Profile small = must(Profile::circle(2), "circle");
    Profile same = must(Profile::rect(10, 10), "rect");
    check(must(sq.relationship(far), "relationship") == bs::Relation::disjoint, "disjoint");
    check(must(sq.relationship(edge), "relationship") == bs::Relation::touching, "touching");
    check(must(sq.relationship(half), "relationship") == bs::Relation::overlapping, "overlapping");
    check(must(small.relationship(sq), "relationship") == bs::Relation::a_inside_b, "a_inside_b");
    check(must(sq.relationship(small), "relationship") == bs::Relation::b_inside_a, "b_inside_a");
    check(must(sq.relationship(same), "relationship") == bs::Relation::equal, "equal");
    refused(sq.contains(Vec2{std::numeric_limits<double>::quiet_NaN(), 0}), "profile_contains: ", "contains NaN");
}

static void deviation() {
    Profile five = must(Profile::circle(5), "circle 5");
    Profile six = must(Profile::circle(6), "circle 6");
    bs::Deviation d = must(five.deviation(six, 1e-6), "deviation");
    near(d.max_distance, 1, 1e-6, "circles max");
    near(d.min_distance, 1, 1e-6, "circles min");
    Profile sq = must(Profile::rect(10, 10), "rect");
    d = must(sq.deviation(five, 1e-6), "deviation");
    near(d.max_distance, 5 * std::sqrt(2.0) - 5, 1e-6, "square max");
    near(d.min_distance, 0, 1e-6, "square min");
    near(std::hypot(d.max_a[0], d.max_a[1]), 5 * std::sqrt(2.0), 1e-5, "the farthest point is a corner");
}

static void offset_corner_and_end() {
    Profile sq = must(Profile::rect(10, 10), "rect");
    near(area(must(sq.offset(1, 1e-3, bs::OffsetCorner::sharp), "sharp")[0]), 144, 144e-6, "sharp");
    near(area(must(sq.offset(1, 1e-3, bs::OffsetCorner::chamfer), "chamfer")[0]), 142, 142e-6, "chamfer");
    near(area(must(sq.offset(1, 1e-3, bs::OffsetCorner::smooth), "smooth")[0]), 144 - 4.0 / 6, 144e-6, "smooth");
    near(area(must(sq.offset(1, 1e-3, bs::OffsetCorner::round), "round")[0]), 140 + PI, 1e-4 * (140 + PI), "round");
    Profile line = must(Profile::polyline({Vec2{0, 0}, Vec2{10, 0}}), "polyline");
    near(area(must(line.offset_open(1, 1e-3, bs::OffsetCorner::round, bs::OffsetEnd::flat), "flat")[0]), 20, 20e-6,
         "open flat");
    // A style the C ABI does not know is refused by name there.
    refused(sq.offset(1, 0.01, static_cast<bs::OffsetCorner>(7)), "profile_offset_corner", "unknown corner");
}

static void polyline_tools() {
    Profile colinear = must(Profile::polyline({Vec2{0, 0}, Vec2{2, 0}, Vec2{4, 0}, Vec2{4, 4}, Vec2{0, 4}}, true), "polyline");
    check(sides(must(colinear.merge_colinear(1e-9), "merge_colinear")) == 4, "merge_colinear: 4 sides");
    check(must(colinear.is_convex(), "is_convex"), "is_convex");
    check(!must(colinear.is_convex(true), "is_convex strict"), "not is_convex(strict)");
    Profile sq = must(Profile::rect(10, 10), "rect");
    check(must(sq.break_at_kinks(0.1), "break_at_kinks").size() == 4, "break_at_kinks: 4 pieces");
    Profile seamed = must(sq.with_seam(Vec2{0, -5}), "with_seam");
    near(area(seamed), 100, 1e-9, "with_seam area");
    std::vector<double> start = must(seamed.beziers(), "beziers");
    near(start[0], 0, 1e-9, "seam x");
    near(start[1], -5, 1e-9, "seam y");
    Profile zig = must(Profile::polyline({Vec2{0, 0}, Vec2{1, 0.001}, Vec2{2, 0}, Vec2{3, 0.001}, Vec2{4, 0}, Vec2{4, 4}, Vec2{0, 4}}, true),
                       "polyline");
    check(sides(must(zig.reduce_segments(0.01), "reduce_segments")) == 4, "reduce_segments: 4 sides");
    Profile gap = must(Profile::polyline({Vec2{0, 0}, Vec2{4, 0}, Vec2{4, 4}, Vec2{0, 4}, Vec2{0, 0.0005}}), "polyline");
    near(area(must(gap.make_closed(0.001), "make_closed")), 16, 0.01, "make_closed area");
    refused(gap.make_closed(1e-5), "profile_make_closed: the ends are 0.0005 apart", "make_closed gap");
}

int main(int argc, char** argv) {
    if (argc > 1) {
        Result<void> loaded = bs::license(argv[1]);
        if (!loaded) {
            std::fprintf(stderr, "license: %s\n", loaded.error().message.c_str());
            return 1;
        }
    }
    union_difference_and_regions();
    contains_and_relationship();
    deviation();
    offset_corner_and_end();
    polyline_tools();
    if (failures) {
        std::fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    std::printf("profile toolkit: ok\n");
    return 0;
}
