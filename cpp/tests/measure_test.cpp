// The oriented box, edge and profile lengths, point containment (one-shot and the
// Classifier handle) and closest points -- at parity with the Python reference's tests in
// test_cadaclysm_blacksmith.py ("oriented box, lengths, containment, closest"), trimmed to
// what proves the marshalling: every field read, every error path's prefix, the
// classifier's lifetime. The kernel's own correctness is the kernel's tests' job. Needs the
// kernel library and a license; the exit code is the verdict.
//
//     cadaclysm_measure_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <algorithm>
#include <array>
#include <cmath>
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

static void check(bool ok, const std::string& what) {
    if (ok) return;
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
}

static bool within(double a, double b, double tolerance) { return std::fabs(a - b) <= tolerance; }

static bool near3(const Vec3& a, const Vec3& b, double tolerance) {
    return within(a[0], b[0], tolerance) && within(a[1], b[1], tolerance) && within(a[2], b[2], tolerance);
}

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

static bool same_box(const bs::OrientedBox& a, const bs::OrientedBox& b) {
    return a.centre == b.centre && a.axes == b.axes && a.half == b.half;
}

static const bs::AxisLine Z_AXIS = {Vec3{0, 0, 0}, Vec3{0, 0, 1}};
static const double NAN_VALUE = std::numeric_limits<double>::quiet_NaN();

// 1
static Result<void> oriented_box_of_a_turned_cuboid() {
    CADACLYSM_TRY(cuboid, bs::Solid::cuboid(2, 3, 4));
    CADACLYSM_TRY(turned, cuboid.rotate(Z_AXIS, 30.0 * PI / 180.0));
    CADACLYSM_TRY(box, turned.oriented_box(1e-9));
    Vec3 half = box.half;
    std::sort(half.begin(), half.end());
    const Vec3 want = {1.0, 1.5, 2.0};
    for (std::size_t i = 0; i < 3; ++i) {
        check(half[i] >= want[i] - 1e-9 && half[i] <= want[i] + 1e-3,
              "half[" + std::to_string(i) + "] = " + std::to_string(half[i]));
        check(within(box.centre[i], 0.0, 1e-3), "centre[" + std::to_string(i) + "] = " + std::to_string(box.centre[i]));
    }
    for (std::size_t i = 0; i < 3; ++i) {
        for (std::size_t j = 0; j < 3; ++j) {
            double dot = box.axes[i][0] * box.axes[j][0] + box.axes[i][1] * box.axes[j][1] + box.axes[i][2] * box.axes[j][2];
            check(within(dot, i == j ? 1.0 : 0.0, 1e-9), "axes " + std::to_string(i) + "." + std::to_string(j) + " = " + std::to_string(dot));
        }
    }
    return {};
}

// 2
static Result<void> oriented_box_defaults_and_errors() {
    CADACLYSM_TRY(cylinder, bs::Solid::cylinder(1, 2));
    CADACLYSM_TRY(by_default, cylinder.oriented_box(0));
    CADACLYSM_TRY(negative, cylinder.oriented_box(-1));
    CADACLYSM_TRY(explicit_default, cylinder.oriented_box(1e-5));
    check(same_box(by_default, explicit_default), "oriented_box(0) is oriented_box(1e-5)");
    check(same_box(negative, explicit_default), "oriented_box(-1) is oriented_box(1e-5)");
    const double grown = 1.0 + 3.125e-5 * std::sqrt(12.0);
    for (std::size_t i = 0; i < 3; ++i) {
        check(within(by_default.half[i], grown, 1e-12),
              "half[" + std::to_string(i) + "] = " + std::to_string(by_default.half[i]));
    }
    refused(cylinder.oriented_box(NAN_VALUE), "oriented_box: ", "is not an accuracy", "oriented_box(NaN)");
    CADACLYSM_TRY(cuboid, bs::Solid::cuboid(1, 2, 3));
    CADACLYSM_TRY(sheet, cuboid.face_sheet(0));
    refused(sheet.oriented_box(), "oriented_box: ", "", "oriented_box of a sheet");
    return {};
}

// 3
static Result<void> edge_length_of_the_circles() {
    CADACLYSM_TRY(cylinder, bs::Solid::cylinder(2.5, 4));
    CADACLYSM_TRY(edges, cylinder.edges());
    int circles = 0;
    for (const bs::Edge& e : edges) {
        if (e.kind != "circle") continue;
        ++circles;
        CADACLYSM_TRY(length, cylinder.edge_length(e.index, 1e-9));
        check(within(length.length, 5.0 * PI, std::max(length.error, 1e-9)) && length.error >= 0 && length.error <= 1e-6 * length.length,
              "circle edge " + std::to_string(e.index) + " is " + std::to_string(length.length));
        check(length.accuracy_met, "circle edge accuracy met");
        check(!length.from_polyline, "circle edge is not a polyline");
    }
    check(circles >= 1, "the cylinder has a circle edge");
    CADACLYSM_TRY(cuboid, bs::Solid::cuboid(1, 1, 1));
    CADACLYSM_TRY(count, cuboid.edges());
    refused(cuboid.edge_length(static_cast<std::uint32_t>(count.size())), "edge_length: ", "", "edge_length past the last edge");
    return {};
}

// 4
static Result<void> profile_length_of_a_slot() {
    CADACLYSM_TRY(slot, bs::Profile::slot(Vec2{0, 0}, 8, 1));
    CADACLYSM_TRY(length, slot.length(1e-9));
    check(within(length.length, 12.0 + 2.0 * PI, std::max(length.error, 1e-9)) && length.error >= 0 && length.error <= 1e-6 * length.length, "slot length " + std::to_string(length.length));
    check(length.accuracy_met, "slot accuracy met");
    refused(slot.length(NAN_VALUE), "profile_length: ", "", "length(NaN)");
    return {};
}

// 5
static Result<void> containment_one_shot_and_classifier() {
    CADACLYSM_TRY(box, bs::Solid::cuboid(2, 3, 4));
    CADACLYSM_TRY(inside, box.contains(Vec3{0, 0, 0}));
    CADACLYSM_TRY(outside, box.contains(Vec3{5, 0, 0}));
    CADACLYSM_TRY(on, box.contains(Vec3{0, 0, 2}));
    check(inside == "inside", "the centre is " + inside);
    check(outside == "outside", "(5,0,0) is " + outside);
    check(on == "on", "(0,0,2) is " + on);
    CADACLYSM_TRY(classifier, box.classifier());
    const std::vector<Vec3> points = {Vec3{0, 0, 0}, Vec3{0.99, 0, 0}, Vec3{1, 0, 0},
                                      Vec3{1.2, 0, 0}, Vec3{0, 1.6, 0}, Vec3{0, 0, -2}};
    for (const Vec3& p : points) {
        CADACLYSM_TRY(one_shot, box.contains(p));
        CADACLYSM_TRY(handle, classifier.contains(p));
        check(one_shot == handle, "classifier and one-shot agree at (" + std::to_string(p[0]) + "," + std::to_string(p[1]) + "," +
                                      std::to_string(p[2]) + "): " + handle + " vs " + one_shot);
    }
    CADACLYSM_TRY(sphere, bs::Solid::sphere(1.5));
    CADACLYSM_TRY(ball, sphere.classifier(1e-3));
    const double xs[] = {-2, -1.4, -0.5, 0, 0.5, 1.4, 2};
    const char* want[] = {"outside", "inside", "inside", "inside", "inside", "inside", "outside"};
    for (std::size_t i = 0; i < 7; ++i) {
        CADACLYSM_TRY(got, ball.contains(Vec3{xs[i], 0, 0}));
        check(got == want[i], "sphere at x=" + std::to_string(xs[i]) + " is " + got);
    }
    CADACLYSM_TRY(rim_x, ball.contains(Vec3{1.5, 0, 0}));
    CADACLYSM_TRY(rim_z, ball.contains(Vec3{0, 0, -1.5}));
    check(rim_x == "on" && rim_z == "on", "the rim is on: " + rim_x + ", " + rim_z);
    return {};
}

// 6
static Result<void> the_classifier_outlives_its_solid() {
    CADACLYSM_TRY(sphere, bs::Solid::sphere(1.0));
    CADACLYSM_TRY(classifier, sphere.classifier(1e-3));
    sphere.close();
    check(sphere.closed(), "the solid is closed");
    CADACLYSM_TRY(centre, classifier.contains(Vec3{0, 0, 0}));
    CADACLYSM_TRY(far, classifier.contains(Vec3{2, 0, 0}));
    CADACLYSM_TRY(rim, classifier.contains(Vec3{1, 0, 0}));
    check(centre == "inside", "centre after the solid closed: " + centre);
    check(far == "outside", "(2,0,0) after the solid closed: " + far);
    check(rim == "on", "(1,0,0) after the solid closed: " + rim);
    // A move hands the handle over; the source is closed.
    bs::Classifier moved = std::move(classifier);
    check(classifier.closed() && !moved.closed(), "a move leaves the source closed");  // NOLINT(bugprone-use-after-move)
    CADACLYSM_TRY(again, moved.contains(Vec3{0, 0, 0}));
    check(again == "inside", "the moved classifier answers: " + again);
    return {};
}

// 7
static Result<void> containment_errors() {
    CADACLYSM_TRY(box, bs::Solid::cuboid(2, 3, 4));
    const Vec3 bad = {NAN_VALUE, 0, 0};
    refused(box.contains(bad), "contains: ", "not finite", "contains(NaN)");
    CADACLYSM_TRY(classifier, box.classifier());
    refused(classifier.contains(bad), "classifier_contains: ", "not finite", "classifier.contains(NaN)");
    refused(box.contains(Vec3{0, 0, 0}, 0.0), "contains: ", "positive and finite", "contains with tolerance 0");
    refused(box.classifier(0.0), "classifier_new: ", "positive and finite", "classifier with tolerance 0");
    classifier.close();
    check(classifier.closed(), "the classifier is closed");
    refused(classifier.contains(Vec3{0, 0, 0}), "classifier: closed", "", "contains after close");
    classifier.close();  // closing twice is a no-op
    check(classifier.closed(), "closing twice leaves it closed");
    // A code the library should never answer is a refusal naming the call.
    Result<std::string> odd = bs::detail::containment_of(7, "contains");
    refused(odd, "contains: the library answered 7, not a containment code", "", "containment code 7");
    Result<std::string> odd_handle = bs::detail::containment_of(3, "classifier_contains");
    refused(odd_handle, "classifier_contains: the library answered 3, not a containment code", "", "containment code 3");
    return {};
}

// 8
static Result<void> closest_of_two_spheres() {
    CADACLYSM_TRY(a, bs::Solid::sphere(1));
    CADACLYSM_TRY(b0, bs::Solid::sphere(1));
    CADACLYSM_TRY(b, b0.translate(5, 0, 0));
    CADACLYSM_TRY(c, a.closest(b, 1e-3));
    check(within(c.distance, 3.0, 6e-9), "distance " + std::to_string(c.distance));
    check(c.refined, "refined");
    check(c.kind_a == "face" && c.kind_b == "face", "kinds " + c.kind_a + ", " + c.kind_b);
    check(!c.edge_a.has_value() && !c.edge_b.has_value(), "no edges");
    check(near3(c.on_a, Vec3{1, 0, 0}, 1e-6), "on_a (" + std::to_string(c.on_a[0]) + ")");
    check(near3(c.on_b, Vec3{4, 0, 0}, 1e-6), "on_b (" + std::to_string(c.on_b[0]) + ")");
    CADACLYSM_TRY(swapped, b.closest(a, 1e-3));
    check(near3(swapped.on_a, c.on_b, 1e-9) && near3(swapped.on_b, c.on_a, 1e-9), "swapping swaps the points");
    check(within(swapped.distance, c.distance, 1e-12), "swapping keeps the distance");
    return {};
}

// 9
static Result<void> closest_names_a_filletable_edge() {
    CADACLYSM_TRY(box, bs::Solid::cuboid(2, 3, 4));
    CADACLYSM_TRY(ball0, bs::Solid::sphere(1));
    CADACLYSM_TRY(ball, ball0.translate(3, 0, 4));
    CADACLYSM_TRY(c, box.closest(ball, 1e-3));
    check(within(c.distance, 2.0 * std::sqrt(2.0) - 1.0, 2e-3), "distance " + std::to_string(c.distance));
    check(c.kind_a == "edge", "kind_a " + c.kind_a);
    check(c.edge_a.has_value(), "edge_a is present");
    check(c.kind_b == "face" && !c.edge_b.has_value(), "kind_b " + c.kind_b);
    if (c.edge_a) {
        CADACLYSM_TRY(rounded, box.fillet(std::vector<std::uint32_t>{*c.edge_a}, 0.2));
        check(rounded.faces() == box.faces() + 1, "the fillet adds one face");
    }
    return {};
}

// 10
static Result<void> closest_errors_and_progress() {
    CADACLYSM_TRY(a, bs::Solid::sphere(1));
    CADACLYSM_TRY(b0, bs::Solid::sphere(1));
    CADACLYSM_TRY(b, b0.translate(5, 0, 0));
    refused(a.closest(b, 0.0), "closest: ", "", "closest with tolerance 0");
    std::vector<std::string> phases;
    bs::Progress hear = [&phases](std::string_view phase, std::size_t, std::size_t) { phases.emplace_back(phase); };
    CADACLYSM_TRY(c, a.closest(b, 1e-3, hear));
    check(std::find(phases.begin(), phases.end(), "meshing") != phases.end(), "the call heard a \"meshing\" phase");
    check(within(c.distance, 3.0, 6e-9), "distance with progress " + std::to_string(c.distance));
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
        {"oriented_box_of_a_turned_cuboid", oriented_box_of_a_turned_cuboid},
        {"oriented_box_defaults_and_errors", oriented_box_defaults_and_errors},
        {"edge_length_of_the_circles", edge_length_of_the_circles},
        {"profile_length_of_a_slot", profile_length_of_a_slot},
        {"containment_one_shot_and_classifier", containment_one_shot_and_classifier},
        {"the_classifier_outlives_its_solid", the_classifier_outlives_its_solid},
        {"containment_errors", containment_errors},
        {"closest_of_two_spheres", closest_of_two_spheres},
        {"closest_names_a_filletable_edge", closest_names_a_filletable_edge},
        {"closest_errors_and_progress", closest_errors_and_progress},
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
    std::printf("measure: ok\n");
    return 0;
}
