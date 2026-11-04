// Collider::clash, the one-shot clash() and the Clash row -- at parity with the Python
// reference's test_clash_* tests in test_cadaclysm_blacksmith.py, trimmed to what proves the
// marshalling: every field read, every refusal's prefix, the answer kept alive past the
// collider and the other rows, plus the edge row (an edge feature on either side, and an edge
// against a face). The kernel's own correctness is the kernel's tests' job. Needs the kernel
// library; the exit code is the verdict.
//
//     cadaclysm_clash_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <optional>
#include <string>
#include <utility>
#include <vector>

using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;
using bs::Vec3;

static int failures = 0;

static void check(bool ok, const std::string& what) {
    if (ok) return;
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
}

// The value of a call the test cannot go on without; anything else ends the run.
template <class T>
static T must(Result<T> r, const char* what) {
    if (!r) {
        std::fprintf(stderr, "FAIL: %s: %s\n", what, r.error().message.c_str());
        std::exit(1);
    }
    return std::move(r).value();
}

static bool within(double a, double b, double tolerance) { return std::fabs(a - b) <= tolerance; }

static bool near3(const Vec3& a, const Vec3& b, double tolerance) {
    return within(a[0], b[0], tolerance) && within(a[1], b[1], tolerance) && within(a[2], b[2], tolerance);
}

// A refusal check that fails when nothing was refused: the call must have returned an error
// whose text starts with `prefix`.
template <class T>
static void refused(const Result<T>& r, const std::string& prefix, const std::string& what) {
    if (r.ok()) {
        check(false, what + ": expected a refusal, but the call succeeded");
        return;
    }
    const std::string& got = r.error().message;
    check(got.compare(0, prefix.size(), prefix) == 0, what + ": refused with \"" + got + "\", wanted it to start \"" + prefix + "\"");
}

// The frame at (x, y, z) with the world's axes.
static bs::Frame at(double x, double y = 0.0, double z = 0.0) {
    return must(bs::Frame::make({x, y, z}, {1, 0, 0}, {0, 1, 0}, {0, 0, 1}), "Frame::make");
}

using Frames = std::vector<std::reference_wrapper<const bs::Frame>>;

static std::string described(const std::vector<bs::Clash>& rows) {
    std::string out = std::to_string(rows.size()) + " rows";
    for (const bs::Clash& r : rows) {
        out += " (" + std::to_string(r.a) + ", " + std::to_string(r.b) + ", " + r.kind + ", " + std::to_string(r.distance) + ")";
    }
    return out;
}

static std::string feature(const std::string& kind, const std::optional<std::uint32_t>& index, const std::optional<std::uint32_t>& edge) {
    return kind + "#" + (index ? std::to_string(*index) : std::string("none")) + "/" + (edge ? std::to_string(*edge) : std::string("none"));
}

// 1. Two balls 0.5 apart: too close at clearance 1, every field read; nothing at 0.25.
static void balls_within_the_clearance_are_too_close() {
    bs::Solid a = must(bs::Solid::sphere(1), "sphere");
    bs::Solid b = must(bs::Solid::sphere(1), "sphere");
    bs::Collider collider = must(bs::Collider::make({a, b}, 1e-3), "Collider::make");
    bs::Frame f0 = at(0);
    bs::Frame f1 = at(2.5);
    std::vector<bs::Clash> rows = must(collider.clash(Frames{f0, f1}, 1.0), "Collider::clash");
    check(rows.size() == 1, "the balls read " + described(rows));
    if (rows.size() != 1) return;
    const bs::Clash& r = rows[0];
    check(r.a == 0 && r.b == 1 && r.kind == "too_close", "the balls' row is " + described(rows));
    check(within(r.distance, 0.5, 1e-3), "the balls' distance is " + std::to_string(r.distance));
    check(r.kind_a == "face" && r.kind_b == "face" && r.index_a.has_value() && r.index_b.has_value() && !r.edge_a && !r.edge_b,
          "the balls' features read " + feature(r.kind_a, r.index_a, r.edge_a) + ", " + feature(r.kind_b, r.index_b, r.edge_b));
    check(within(r.on_a[0], 1.0, 2e-3) && within(r.on_b[0], 1.5, 2e-3),
          "the balls' points read x " + std::to_string(r.on_a[0]) + ", " + std::to_string(r.on_b[0]));
    check(r.text.empty() && r.depth == 0.0, "the balls' text or depth read '" + r.text + "', " + std::to_string(r.depth));
    std::printf("     balls: refined %s\n", r.refined ? "true" : "false");
    std::vector<bs::Clash> none = must(collider.clash(Frames{f0, f1}, 0.25), "Collider::clash at 0.25");
    check(none.empty(), "clearance 0.25 still found the balls: " + described(none));
}

// 2. Two boxes face to face: touching; no solid; the shared face is one overlap region.
static void boxes_face_to_face_touch() {
    bs::Solid a = must(bs::Solid::cuboid(2, 2, 2), "cuboid");
    bs::Solid b = must(bs::Solid::cuboid(2, 2, 2), "cuboid");
    bs::Collider collider = must(bs::Collider::make({a, b}, 1e-3), "Collider::make");
    bs::Frame f0 = at(0);
    bs::Frame f1 = at(2);
    std::vector<bs::Clash> rows = must(collider.clash(Frames{f0, f1}), "Collider::clash");
    check(rows.size() == 1 && rows[0].kind == "touching" && rows[0].distance <= 1e-3, "the boxes face to face read " + described(rows));
    if (rows.size() != 1) return;
    const bs::Clash& r = rows[0];
    refused(r.solid(), "clashes_solid: pair (0, 1) is not penetrating", "a touching pair's solid()");
    bs::Intersection face = must(r.intersect(), "Clash::intersect");
    check(face.overlaps.size() == 1 && !face.overlaps[0].loops.empty(),
          "the touching pair intersects as " + std::to_string(face.overlaps.size()) + " overlaps");
    if (face.overlaps.size() != 1 || face.overlaps[0].loops.empty()) return;
    const std::vector<Vec3>& ring = face.overlaps[0].loops[0];
    double twice = 0.0;
    for (std::size_t i = 0; i < ring.size(); ++i) {
        const Vec3& p = ring[i];
        const Vec3& q = ring[(i + 1) % ring.size()];
        check(within(p[0], 1.0, 1e-3), "the touching ring leaves x = 1: " + std::to_string(p[0]));
        twice += p[1] * q[2] - q[1] * p[2];
    }
    check(within(std::fabs(twice) / 2.0, 4.0, 1e-6), "the touching ring's area is " + std::to_string(std::fabs(twice) / 2.0));
}

// 3. Two boxes overlapping by 0.25: penetrating, features none; the row kept past the collider
// and its list still rebuilds the overlap.
static void boxes_interpenetrating_outlive_the_collider() {
    bs::Solid a = must(bs::Solid::cuboid(2, 2, 2), "cuboid");
    bs::Solid b = must(bs::Solid::cuboid(2, 2, 2), "cuboid");
    bs::Clash kept;
    {
        bs::Collider collider = must(bs::Collider::make({a, b}, 1e-3), "Collider::make");
        bs::Frame f0 = at(0);
        bs::Frame f1 = at(1.75);
        std::vector<bs::Clash> rows = must(collider.clash(Frames{f0, f1}), "Collider::clash");
        check(rows.size() == 1, "the boxes overlapping read " + described(rows));
        if (rows.size() != 1) return;
        kept = rows[0];
        collider.close();
        check(collider.closed(), "the collider is closed");
    }  // the list of rows dropped here; `kept` alone holds the answer
    check(kept.kind == "penetrating" && std::fabs(kept.depth - 0.25) < 1e-9 && kept.distance == 0.0,
          "the overlapping row is " + kept.kind + ", depth " + std::to_string(kept.depth) + ", distance " + std::to_string(kept.distance));
    check(kept.kind_a == "none" && !kept.index_a && !kept.edge_a && kept.kind_b == "none" && !kept.index_b && !kept.edge_b,
          "a penetrating row's features read " + feature(kept.kind_a, kept.index_a, kept.edge_a) + ", " +
              feature(kept.kind_b, kept.index_b, kept.edge_b));
    Result<bs::Solid> common = kept.solid();
    check(common.ok(), "the kept row's solid(): " + (common ? std::string("ok") : common.error().message));
    if (common) {
        bs::Mass mass = must(common.value().mass(), "mass");
        check(within(mass.volume, 1.0, 1e-6), "the overlap's volume is " + std::to_string(mass.volume));
    }
    Result<bs::Intersection> crossing = kept.intersect();
    check(crossing.ok(), "the kept row's intersect(): " + (crossing ? std::string("ok") : crossing.error().message));
}

// 4. The one-shot over two sets, over one set, and over one set with the pair allowed.
static void the_one_shot_over_two_sets_and_one() {
    bs::Solid a0 = must(bs::Solid::sphere(1), "sphere");
    bs::Solid ball = must(bs::Solid::sphere(1), "sphere");
    bs::Solid a1 = must(ball.translate(2.05, 0, 0), "translate");
    bs::Solid b0 = must(ball.translate(0, 2.5, 0), "translate");
    bs::Solid b1 = must(ball.translate(10, 0, 0), "translate");
    bs::Solids parts{a0, a1};
    bs::Solids others{b0, b1};
    std::vector<bs::Clash> two = must(bs::clash(parts, others, 1.0, 1e-3), "clash over two sets");
    check(two.size() == 1 && two[0].a == 0 && two[0].b == 0 && two[0].kind == "too_close" && within(two[0].distance, 0.5, 1e-3),
          "two sets read " + described(two));
    std::vector<bs::Clash> one = must(bs::clash(parts, std::nullopt, 1.0, 1e-3), "clash over one set");
    check(one.size() == 1 && one[0].a == 0 && one[0].b == 1, "one set reads " + described(one));
    std::vector<std::pair<std::uint32_t, std::uint32_t>> allowed{{0, 1}};
    std::vector<bs::Clash> skipped = must(bs::clash(parts, std::nullopt, 1.0, 1e-3, allowed), "clash with an allowed pair");
    check(skipped.empty(), "an allowed pair was still tested: " + described(skipped));
}

// 5. The refusals, by prefix: the kernel's verbatim, and the wrapper's own empty `others`.
// `allowed` is pairs of uint32 here, as Collider::make takes it, so it carries no odd length and
// no number that is not an index.
static void the_refusals() {
    bs::Solid a = must(bs::Solid::cuboid(2, 2, 2), "cuboid");
    bs::Solid b = must(bs::Solid::cuboid(2, 2, 2), "cuboid");
    bs::Collider collider = must(bs::Collider::make({a, b}), "Collider::make");
    bs::Frame f0 = at(0);
    bs::Frame f1 = at(1.75);
    refused(collider.clash(Frames{f0, f1}, -1.0), "collider_clash: clearance -1", "a negative clearance");
    refused(collider.clash(Frames{f0}), "collider_clash: 1 frames for 2 groups", "one frame for two groups");
    refused(collider.clash(Frames{f0, f1}, 0.0, std::make_pair(2u, 2u)), "collider_clash: share (2, 2)", "share (2, 2)");
    bs::Solids parts{a, b};
    refused(bs::clash(parts, std::nullopt, -1.0), "clash: clearance -1", "a one-shot negative clearance");
    std::vector<std::pair<std::uint32_t, std::uint32_t>> out_of_range{{5, 0}};
    refused(bs::clash(parts, std::nullopt, 0.0, bs::DEFAULT_TOLERANCE, out_of_range),
            "clash: allowed pair (5, 0) names a part out of range", "an allowed pair out of range");
    refused(bs::clash(parts, bs::Solids{}), "clash: an empty set", "an empty others");
}

// 6. The edge row: b turned 45 degrees about z and tipped, so its edge passes 0.1 from a's edge
// on x = 1, y = 1 -- an edge on either side.
static void the_edge_row() {
    bs::Solid a = must(bs::Solid::cuboid(2, 2, 2), "cuboid");
    bs::Solid b = must(bs::Solid::cuboid(2, 2, 2), "cuboid");
    bs::Collider collider = must(bs::Collider::make({a, b}, 1e-3), "Collider::make");
    const double c = std::sqrt(0.5);
    const double s = 0.1 * c;
    bs::Frame f0 = at(0);
    bs::Frame tipped = must(bs::Frame::make({2 + s, 2 + s, 0}, {c, -c, 0}, {0.5, 0.5, c}, {-0.5, -0.5, c}), "the tipped frame");
    std::vector<bs::Clash> rows = must(collider.clash(Frames{f0, tipped}, 0.5), "Collider::clash");
    check(rows.size() == 1 && rows[0].kind == "too_close" && within(rows[0].distance, 0.1, 1e-3), "the edge pose reads " + described(rows));
    if (rows.size() != 1) return;
    const bs::Clash& r = rows[0];
    check(near3(r.on_a, Vec3{1, 1, 0}, 2e-3),
          "the edge row's on_a is (" + std::to_string(r.on_a[0]) + ", " + std::to_string(r.on_a[1]) + ", " + std::to_string(r.on_a[2]) + ")");
    check(r.kind_a == "edge" && r.kind_b == "edge" && r.edge_a && r.edge_b,
          "the edge row's features read " + feature(r.kind_a, r.index_a, r.edge_a) + ", " + feature(r.kind_b, r.index_b, r.edge_b));
    if (!r.edge_a || !r.edge_b) return;
    std::vector<bs::Edge> edges_a = must(a.edges(), "edges");
    std::vector<bs::Edge> edges_b = must(b.edges(), "edges");
    check(*r.edge_a < edges_a.size(), "a's edge " + std::to_string(*r.edge_a) + " is past its " + std::to_string(edges_a.size()) + " edges");
    if (*r.edge_a < edges_a.size()) {
        for (const std::array<Vec3, 2>& segment : edges_a[*r.edge_a].segments) {
            for (const Vec3& p : segment) {
                check(within(p[0], 1.0, 2e-3) && within(p[1], 1.0, 2e-3),
                      "a's edge " + std::to_string(*r.edge_a) + " is not the one on x = 1, y = 1");
            }
        }
    }
    check(*r.edge_b < edges_b.size(), "b's edge " + std::to_string(*r.edge_b) + " is past its " + std::to_string(edges_b.size()) + " edges");
    std::printf("     edge row: edge_a %u, edge_b %u of %zu\n", *r.edge_a, *r.edge_b, edges_a.size());
}

// ... and a ball 0.2 off that edge: side a an edge, side b a face, so a swap of the two sides
// shows. Solid::closest of the same two, placed so, is the witness.
static void an_edge_against_a_face() {
    bs::Solid box = must(bs::Solid::cuboid(2, 2, 2), "cuboid");
    bs::Solid ball = must(bs::Solid::sphere(1), "sphere");
    bs::Collider collider = must(bs::Collider::make({box, ball}, 1e-3), "Collider::make");
    const double off = 1 + 1.2 * std::sqrt(0.5);
    bs::Frame f0 = at(0);
    bs::Frame f1 = at(off, off);
    std::vector<bs::Clash> rows = must(collider.clash(Frames{f0, f1}, 0.5), "Collider::clash");
    check(rows.size() == 1 && within(rows[0].distance, 0.2, 1e-3), "the ball by the edge reads " + described(rows));
    if (rows.size() != 1) return;
    const bs::Clash& r = rows[0];
    check(r.kind_a == "edge" && r.edge_a && r.kind_b == "face" && !r.edge_b,
          "the ball by the edge names " + feature(r.kind_a, r.index_a, r.edge_a) + ", " + feature(r.kind_b, r.index_b, r.edge_b));
    bs::Solid placed = must(ball.translate(off, off, 0), "translate");
    bs::Closest witness = must(box.closest(placed, 1e-3), "closest");
    check(r.kind_a == witness.kind_a && r.kind_b == witness.kind_b && r.edge_a == witness.edge_a && r.edge_b == witness.edge_b,
          "the clash row names " + feature(r.kind_a, r.index_a, r.edge_a) + ", " + feature(r.kind_b, r.index_b, r.edge_b) +
              "; closest names " + feature(witness.kind_a, witness.index_a, witness.edge_a) + ", " +
              feature(witness.kind_b, witness.index_b, witness.edge_b));
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
        void (*run)();
    };
    const Test tests[] = {
        {"balls_within_the_clearance_are_too_close", balls_within_the_clearance_are_too_close},
        {"boxes_face_to_face_touch", boxes_face_to_face_touch},
        {"boxes_interpenetrating_outlive_the_collider", boxes_interpenetrating_outlive_the_collider},
        {"the_one_shot_over_two_sets_and_one", the_one_shot_over_two_sets_and_one},
        {"the_refusals", the_refusals},
        {"the_edge_row", the_edge_row},
        {"an_edge_against_a_face", an_edge_against_a_face},
    };
    for (const Test& t : tests) {
        int before = failures;
        t.run();
        std::printf("%s %s\n", failures == before ? "ok  " : "FAIL", t.name);
    }
    if (failures) {
        std::fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    std::printf("clash: ok\n");
    return 0;
}
