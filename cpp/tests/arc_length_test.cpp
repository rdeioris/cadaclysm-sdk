// Point at length, divide by count and divide by length on a solid's edges and a profile's
// outer loop -- at parity with the Python reference's arc-length tests in
// test_cadaclysm_blacksmith.py, trimmed to what proves the marshalling: every field read, every
// refusal's prefix, the list's length and order. The kernel's own correctness is the kernel's
// tests' job. Needs the kernel library and a license; the exit code is the verdict.
//
//     cadaclysm_arc_length_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <optional>
#include <string>
#include <vector>

using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;
using bs::Vec2;
using bs::Vec3;

static int failures = 0;
static const double PI = 3.14159265358979323846;
static const double NAN_VALUE = std::numeric_limits<double>::quiet_NaN();

static void check(bool ok, const std::string& what) {
    if (ok) return;
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
}

static bool within(double a, double b, double tolerance) { return std::fabs(a - b) <= tolerance; }

static bool near3(const Vec3& a, const Vec3& b, double tolerance) {
    return within(a[0], b[0], tolerance) && within(a[1], b[1], tolerance) && within(a[2], b[2], tolerance);
}

static double distance(const Vec3& a, const Vec3& b) {
    return std::sqrt((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]) + (a[2] - b[2]) * (a[2] - b[2]));
}

static double norm(const Vec3& a) { return std::sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]); }

// A refusal check that fails when nothing was refused: the call must have returned an
// error whose text starts with `prefix` and, if given, contains `inside`.
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

static bool same_at(const bs::At& a, const bs::At& b) {
    return a.point == b.point && a.tangent == b.tangent && a.parameter == b.parameter && a.segment == b.segment &&
           a.error == b.error && a.from_polyline == b.from_polyline;
}

// 1
static Result<void> a_quarter_of_a_rim() {
    CADACLYSM_TRY(cylinder, bs::Solid::cylinder(2.5, 4));
    CADACLYSM_TRY(edges, cylinder.edges());
    int circles = 0;
    for (const bs::Edge& e : edges) {
        if (!e.curve || e.curve->kind != "circle") continue;
        ++circles;
        const bs::Curve& curve = *e.curve;
        const std::string name = "circle edge " + std::to_string(e.index);
        CADACLYSM_TRY(start, cylinder.edge_point_at_length(e.index, 0.0));
        check(start.parameter == curve.t0, name + ": start parameter " + std::to_string(start.parameter));
        CADACLYSM_TRY(quarter, cylinder.edge_point_at_length(e.index, 2.5 * PI / 2.0));
        check(within(quarter.parameter, curve.t0 + PI / 2.0, 1e-9), name + ": quarter parameter " + std::to_string(quarter.parameter));
        check(within(distance(quarter.point, curve.origin), 2.5, 1e-9), name + ": quarter point is on the circle");
        check(within(norm(quarter.tangent), 1.0, 1e-12), name + ": the tangent is a unit");
        check(!quarter.segment.has_value(), name + ": a solid's edge has no segment");
        check(!quarter.from_polyline, name + ": not from a polyline");
        check(std::isfinite(quarter.error) && quarter.error >= 0.0, name + ": error " + std::to_string(quarter.error));

        CADACLYSM_TRY(counted, cylinder.edge_divide_by_count(e.index, 4));
        check(counted.size() == 4, name + ": four samples by count, got " + std::to_string(counted.size()));
        for (std::size_t k = 0; k < counted.size(); ++k) {
            const bs::At& next = counted[(k + 1) % counted.size()];
            check(within(distance(counted[k].point, next.point), 2.5 * std::sqrt(2.0), 1e-9),
                  name + ": chord " + std::to_string(k));
        }
        check(!counted.empty() && near3(counted[0].point, start.point, 1e-9), name + ": the first sample is the start");
        CADACLYSM_TRY(stepped, cylinder.edge_divide_by_length(e.index, 2.5 * PI / 2.0));
        check(stepped.size() == 4, name + ": four samples by length, got " + std::to_string(stepped.size()));
    }
    check(circles >= 2, "the cylinder has two circle edges");
    return {};
}

// 2
static Result<void> an_open_edge() {
    CADACLYSM_TRY(cuboid, bs::Solid::cuboid(2, 3, 4));
    CADACLYSM_TRY(edges, cuboid.edges());
    bool found = false;
    for (const bs::Edge& e : edges) {
        if (!e.curve || e.curve->kind != "line") continue;
        CADACLYSM_TRY(length, cuboid.edge_length(e.index));
        if (!within(length.length, 4.0, 1e-9)) continue;
        found = true;
        CADACLYSM_TRY(counted, cuboid.edge_divide_by_count(e.index, 4));
        check(counted.size() == 5, "an open edge by count gives n + 1, got " + std::to_string(counted.size()));
        for (std::size_t k = 0; k < counted.size(); ++k) {
            check(within(distance(counted[k].point, counted[0].point), static_cast<double>(k), 1e-9),
                  "sample " + std::to_string(k) + " is " + std::to_string(k) + " from the first");
        }
        check(counted.front().parameter == e.curve->t0, "the first parameter is t0");
        check(counted.back().parameter == e.curve->t1, "the last parameter is t1");
        CADACLYSM_TRY(stepped, cuboid.edge_divide_by_length(e.index, 1.5));
        check(stepped.size() == 3, "by length 1.5 gives three samples, got " + std::to_string(stepped.size()));
        const double want[3] = {0.0, 1.5, 3.0};
        for (std::size_t k = 0; k < stepped.size() && k < 3; ++k) {
            check(within(distance(stepped[k].point, stepped[0].point), want[k], 1e-9), "stepped sample " + std::to_string(k));
        }
        break;
    }
    check(found, "the cuboid has a line edge of length 4");
    return {};
}

// 3
static Result<void> the_slot() {
    CADACLYSM_TRY(slot, bs::Profile::slot(Vec2{0, 0}, 8, 1));
    CADACLYSM_TRY(at, slot.point_at_length(6.0 + PI / 2.0));
    check(near3(at.point, Vec3{4, 0, 0}, 1e-9), "the slot's far end is (4, 0, 0)");
    check(at.segment == std::optional<std::uint32_t>(1), "the far end lies on side 1");
    CADACLYSM_TRY(counted, slot.divide_by_count(8));
    check(counted.size() == 8, "eight samples by count, got " + std::to_string(counted.size()));
    for (const bs::At& a : counted) check(a.segment.has_value() && *a.segment <= 4, "a sample's side is in 0..4");
    CADACLYSM_TRY(stepped, slot.divide_by_length(3.0));
    const std::size_t want = static_cast<std::size_t>(std::floor((12.0 + 2.0 * PI) / 3.0)) + 1;
    check(stepped.size() == want && want == 7, "by length 3: " + std::to_string(stepped.size()) + " samples");
    for (std::size_t k = 0; k < stepped.size(); ++k) {
        CADACLYSM_TRY(single, slot.point_at_length(3.0 * static_cast<double>(k)));
        check(near3(stepped[k].point, single.point, 1e-12) && stepped[k].segment == single.segment,
              "stepped sample " + std::to_string(k) + " is point_at_length(3k)");
    }
    check(!stepped.empty() && distance(stepped.back().point, stepped.front().point) > 0.1, "the last sample is not the first");
    return {};
}

// 4
static Result<void> refusals() {
    CADACLYSM_TRY(cylinder, bs::Solid::cylinder(2.5, 4));
    CADACLYSM_TRY(edges, cylinder.edges());
    const std::uint32_t i = 0;
    refused(cylinder.edge_point_at_length(i, -1.0), "edge_point_at_length: ", "", "edge point at -1");
    refused(cylinder.edge_point_at_length(i, 100.0), "edge_point_at_length: ", "", "edge point at 100");
    refused(cylinder.edge_point_at_length(static_cast<std::uint32_t>(edges.size()), 1.0), "edge_point_at_length: ", "",
            "edge point on a missing edge");
    refused(cylinder.edge_divide_by_count(i, 0), "edge_divide_by_count: ", "not at least 1", "divide by count 0");
    refused(cylinder.edge_divide_by_count(i, 1000001), "edge_divide_by_count: ", "not at most 1000000", "divide by count 1000001");
    refused(cylinder.edge_divide_by_length(i, 0.0), "edge_divide_by_length: ", "", "divide by length 0");
    refused(cylinder.edge_point_at_length(i, 1.0, NAN_VALUE), "edge_point_at_length: ", "is not an accuracy", "accuracy NaN");
    CADACLYSM_TRY(slot, bs::Profile::slot(Vec2{0, 0}, 8, 1));
    refused(slot.point_at_length(-1.0), "profile_point_at_length: ", "", "profile point at -1");
    refused(slot.divide_by_count(0), "profile_divide_by_count: ", "", "profile divide by count 0");
    refused(slot.divide_by_length(-1.0), "profile_divide_by_length: ", "", "profile divide by length -1");
    return {};
}

// 5
static Result<void> the_default_accuracy() {
    CADACLYSM_TRY(slot, bs::Profile::slot(Vec2{0, 0}, 8, 1));
    CADACLYSM_TRY(plain, slot.point_at_length(5.0));
    CADACLYSM_TRY(zero, slot.point_at_length(5.0, 0.0));
    CADACLYSM_TRY(negative, slot.point_at_length(5.0, -1.0));
    check(same_at(plain, zero), "accuracy 0 is the default");
    check(same_at(plain, negative), "accuracy -1 is the default");
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
        {"a_quarter_of_a_rim", a_quarter_of_a_rim},
        {"an_open_edge", an_open_edge},
        {"the_slot", the_slot},
        {"refusals", refusals},
        {"the_default_accuracy", the_default_accuracy},
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
    std::printf("arc_length: ok\n");
    return 0;
}
