// Collider::swept_clash, the one-shot swept_clash(), the SweptClash row, and Assembly::parts and
// Assembly::swept_clash -- at parity with the Python reference's test_swept_clash_* tests and its
// test_assembly_* swept tests in test_cadaclysm_blacksmith.py, trimmed to what
// proves the marshalling: every field read, the intervals in order, `first` a working Clash past
// the collider, the poses flattened pose by pose, every refusal's prefix (the kernel's verbatim
// and the wrapper's own). The kernel's own correctness is the kernel's tests' job. Needs the
// kernel library; the exit code is the verdict.
//
//     cadaclysm_swept_clash_test [cadaclysm.lic]
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

// The frame at (x, y, 0) with the world's axes.
static bs::Frame at(double x, double y = 0.0) {
    return must(bs::Frame::make({x, y, 0}, {1, 0, 0}, {0, 1, 0}, {0, 0, 1}), "Frame::make");
}

static const double TOL = 1e-3;
static const double RES = 1e-3;

static std::string described(const std::vector<bs::SweptClash>& rows) {
    std::string out = std::to_string(rows.size()) + " rows";
    for (const bs::SweptClash& r : rows) {
        out += " (" + std::to_string(r.a) + ", " + std::to_string(r.b) + ", t " + std::to_string(r.first_time) + ", " + r.first.kind +
               ", first (" + std::to_string(r.first.a) + ", " + std::to_string(r.first.b) + "), intervals";
        for (const std::pair<double, double>& span : r.intervals) {
            out += " [" + std::to_string(span.first) + ", " + std::to_string(span.second) + "]";
        }
        out += ")";
    }
    return out;
}

// An interval that starts at `start` (within the first time's tolerance) and ends at `end`
// (within the resolution).
static bool spans(const std::pair<double, double>& span, double start, double end) {
    return within(span.first, start, TOL / 10 + 1e-9) && within(span.second, end, RES + TOL / 10);
}

// 1. A 2-cube through a 2-cube: one row, first at 0.3, one interval to 0.7; `first` a touching
// Clash that still rebuilds the contact after the collider is gone.
static void cube_through_cube() {
    bs::Solid a = must(bs::Solid::cuboid(2, 2, 2), "cuboid");
    bs::Solid b = must(bs::Solid::cuboid(2, 2, 2), "cuboid");
    std::vector<bs::SweptClash> rows;
    {
        bs::Collider collider = must(bs::Collider::make({a, b}, TOL), "Collider::make");
        bs::Frame left = at(-5);
        bs::Frame right = at(5);
        bs::Frame still = at(0);
        rows = must(collider.swept_clash(bs::Poses{{left, still}, {right, still}}), "Collider::swept_clash");
        collider.close();
    }
    check(rows.size() == 1, "the cube through the cube read " + described(rows));
    if (rows.size() != 1) return;
    const bs::SweptClash& r = rows[0];
    check(r.a == 0 && r.b == 1, "the row's pair is " + described(rows));
    check(within(r.first_time, 0.3, TOL / 10 + 1e-9), "the first time is " + std::to_string(r.first_time));
    check(r.intervals.size() == 1, "the cube through the cube has " + std::to_string(r.intervals.size()) + " intervals");
    if (!r.intervals.empty()) {
        check(r.intervals[0].first == r.first_time, "the interval starts at " + std::to_string(r.intervals[0].first) + ", not the first time");
        check(within(r.intervals[0].second, 0.7, RES + TOL / 10), "the interval ends at " + std::to_string(r.intervals[0].second));
    }
    check(r.first.a == 0 && r.first.b == 1 && r.first.kind == "touching", "first reads " + described(rows));
    refused(r.first.solid(), "clashes_solid: pair (0, 1) is not penetrating", "a touching first's solid()");
    bs::Intersection contact = must(r.first.intersect(), "Clash::intersect after the collider closed");
    check(contact.overlaps.size() == 1, "first intersects as " + std::to_string(contact.overlaps.size()) + " overlaps");
    if (contact.overlaps.size() != 1) return;
    std::size_t points = 0;
    for (const std::vector<Vec3>& loop : contact.overlaps[0].loops) {
        for (const Vec3& p : loop) {
            ++points;
            check(within(p[0], -1.0, 2 * TOL), "first's contact leaves x = -1: " + std::to_string(p[0]));
        }
    }
    check(points > 0, "first's contact has no points");
}

// 2. There and back: one row, two intervals in time order.
static void there_and_back() {
    bs::Solid a = must(bs::Solid::cuboid(2, 2, 2), "cuboid");
    bs::Solid b = must(bs::Solid::cuboid(2, 2, 2), "cuboid");
    bs::Collider collider = must(bs::Collider::make({a, b}, TOL), "Collider::make");
    bs::Frame left = at(-5);
    bs::Frame right = at(5);
    bs::Frame still = at(0);
    std::vector<bs::SweptClash> rows =
        must(collider.swept_clash(bs::Poses{{left, still}, {right, still}, {left, still}}), "Collider::swept_clash");
    check(rows.size() == 1 && rows[0].intervals.size() == 2, "there and back read " + described(rows));
    if (rows.size() != 1 || rows[0].intervals.size() != 2) return;
    check(spans(rows[0].intervals[0], 0.3, 0.7) && spans(rows[0].intervals[1], 1.3, 1.7), "there and back read " + described(rows));
}

// 3. A pass 0.5 off: nothing at clearance 0.4, one too-close row at 0.6.
static void a_miss_within_the_clearance() {
    bs::Solid a = must(bs::Solid::cuboid(2, 2, 2), "cuboid");
    bs::Solid b = must(bs::Solid::cuboid(2, 2, 2), "cuboid");
    bs::Collider collider = must(bs::Collider::make({a, b}, TOL), "Collider::make");
    bs::Frame left = at(-5, 2.5);
    bs::Frame right = at(5, 2.5);
    bs::Frame still = at(0);
    bs::Poses poses{{left, still}, {right, still}};
    std::vector<bs::SweptClash> none = must(collider.swept_clash(poses, 0.4), "Collider::swept_clash at 0.4");
    check(none.empty(), "clearance 0.4 found " + described(none));
    std::vector<bs::SweptClash> rows = must(collider.swept_clash(poses, 0.6), "Collider::swept_clash at 0.6");
    check(rows.size() == 1, "clearance 0.6 found " + described(rows));
    if (rows.size() != 1) return;
    const bs::Clash& first = rows[0].first;
    check(first.kind == "too_close" && first.distance >= 0.5 - TOL && first.distance <= 0.6,
          "the miss's first is " + first.kind + " at " + std::to_string(first.distance));
}

// 4. Starting inside: first at time 0, penetrating, its shared volume 1.
static void starting_inside() {
    bs::Solid a = must(bs::Solid::cuboid(2, 2, 2), "cuboid");
    bs::Solid b = must(bs::Solid::cuboid(2, 2, 2), "cuboid");
    bs::Collider collider = must(bs::Collider::make({a, b}, TOL), "Collider::make");
    bs::Frame inside = at(1.75);
    bs::Frame away = at(5);
    bs::Frame still = at(0);
    std::vector<bs::SweptClash> rows = must(collider.swept_clash(bs::Poses{{inside, still}, {away, still}}), "Collider::swept_clash");
    check(rows.size() == 1, "starting inside read " + described(rows));
    if (rows.size() != 1) return;
    check(rows[0].first_time == 0.0 && rows[0].first.kind == "penetrating", "starting inside read " + described(rows));
    bs::Solid common = must(rows[0].first.solid(), "Clash::solid");
    bs::Mass mass = must(common.mass(), "mass");
    check(within(mass.volume, 1.0, 1e-6), "the shared volume at time 0 is " + std::to_string(mass.volume));
}

// 5. The one-shot over two sets (a pose-major flattening is what pairs b0 with a0 and b1 with
// a1), over one set, and over one set with the pair allowed.
static void the_one_shot() {
    bs::Solid a0 = must(bs::Solid::cuboid(2, 2, 2), "cuboid");
    bs::Solid a1 = must(a0.translate(0, 20, 0), "translate");
    bs::Solid b0 = must(bs::Solid::cuboid(2, 2, 2), "cuboid");
    bs::Solid b1 = must(bs::Solid::cuboid(2, 2, 2), "cuboid");
    bs::Frame origin = at(0);
    bs::Frame left = at(-5);
    bs::Frame right = at(5);
    bs::Frame far_left = at(-5, 20);
    bs::Frame far_right = at(5, 20);
    bs::Poses still{{origin, origin}, {origin, origin}};
    bs::Poses moving{{left, far_left}, {right, far_right}};
    std::vector<bs::SweptClash> two =
        must(bs::swept_clash(bs::Solids{a0, a1}, still, bs::Solids{b0, b1}, moving, 0.0, TOL), "swept_clash over two sets");
    check(two.size() == 2 && two[0].a == 0 && two[0].b == 0 && two[1].a == 1 && two[1].b == 1, "two sets read " + described(two));
    if (two.size() == 2) {
        check(two[0].first.a == 0 && two[0].first.b == 0 && two[1].first.a == 1 && two[1].first.b == 1,
              "two sets' firsts read " + described(two));
    }
    bs::Poses through{{origin, left}, {origin, right}};
    std::vector<bs::SweptClash> one = must(bs::swept_clash(bs::Solids{a0, b0}, through, std::nullopt, std::nullopt, 0.0, TOL),
                                           "swept_clash over one set");
    check(one.size() == 1 && one[0].a == 0 && one[0].b == 1, "one set reads " + described(one));
    std::vector<std::pair<std::uint32_t, std::uint32_t>> allowed{{0, 1}};
    std::vector<bs::SweptClash> skipped =
        must(bs::swept_clash(bs::Solids{a0, b0}, through, std::nullopt, std::nullopt, 0.0, TOL, RES, 100000, allowed),
             "swept_clash with an allowed pair");
    check(skipped.empty(), "an allowed pair was still tested: " + described(skipped));
}

// 6. The refusals, by prefix: the kernel's verbatim, and the wrapper's own (a ragged pose,
// `others` without `other_poses`, poses that do not match, an empty `others`). `allowed` is
// pairs of uint32 here, as clash() takes it, so it carries no odd length and no number that is
// not an index.
static void the_refusals() {
    bs::Solid a = must(bs::Solid::cuboid(2, 2, 2), "cuboid");
    bs::Solid b = must(bs::Solid::cuboid(2, 2, 2), "cuboid");
    bs::Collider collider = must(bs::Collider::make({a, b}, TOL), "Collider::make");
    bs::Frame left = at(-5);
    bs::Frame right = at(5);
    bs::Frame origin = at(0);
    bs::Poses through{{left, origin}, {right, origin}};
    bs::Poses one_pose{{left, origin}};
    refused(collider.swept_clash(one_pose), "collider_swept_clash: 1 poses, at least 2 are needed", "one pose");
    refused(collider.swept_clash(bs::Poses{{origin}, {origin}}), "collider_swept_clash: 1 frames for 2 groups", "one frame for two groups");
    refused(collider.swept_clash(bs::Poses{{origin, origin}, {origin}}), "collider_swept_clash: 1 frames for 2 groups", "a ragged pose");
    refused(collider.swept_clash(through, 0.0, 0.0), "collider_swept_clash: resolution 0", "resolution 0");
    refused(collider.swept_clash(through, 0.0, RES, 0), "collider_swept_clash: max_steps must be at least 1", "max_steps 0");
    refused(collider.swept_clash(through, -1.0), "collider_swept_clash: clearance -1", "a negative clearance");
    refused(collider.swept_clash(through, 0.0, RES, 100000, std::make_pair(2u, 2u)), "collider_swept_clash: share (2, 2)", "share (2, 2)");

    bs::Solids one{a};
    bs::Solids other{b};
    bs::Poses still{{origin}, {origin}};
    refused(bs::swept_clash(one, still, other, std::nullopt), "swept_clash: others and other_poses go together", "others alone");
    refused(bs::swept_clash(one, still, std::nullopt, still), "swept_clash: others and other_poses go together", "other_poses alone");
    refused(bs::swept_clash(one, still, other, bs::Poses{{origin}}), "swept_clash: 2 poses for set a, 1 for set b", "poses that differ");
    refused(bs::swept_clash(one, still, other, bs::Poses{{origin}, {origin, origin}}), "swept_clash: pose 1 of set b has 2 frames for 1 parts",
            "a pose of set b off");
    refused(bs::swept_clash(one, bs::Poses{{origin, origin}, {origin}}, other, still), "swept_clash: pose 0 of set a has 2 frames for 1 parts",
            "a pose of set a off");
    refused(bs::swept_clash(one, still, bs::Solids{}, bs::Poses{{}, {}}), "swept_clash: an empty set", "an empty others");
    std::vector<std::pair<std::uint32_t, std::uint32_t>> out_of_range{{5, 0}};
    refused(bs::swept_clash(bs::Solids{a, b}, through, std::nullopt, std::nullopt, 0.0, TOL, RES, 100000, out_of_range),
            "swept_clash: allowed pair (5, 0) names a part out of range", "an allowed pair out of range");
    refused(bs::swept_clash(bs::Solids{a, b}, through, std::nullopt, std::nullopt, 0.0, TOL, RES, 0), "swept_clash: max_steps must be at least 1", "a one-shot max_steps 0");
    refused(bs::swept_clash(bs::Solids{a, b}, one_pose), "swept_clash: 1 poses, at least 2 are needed", "a one-shot one pose");
}

// ---- an assembly's swept clash: Assembly::parts and Assembly::swept_clash, at parity with the
// Python reference's test_assembly_* swept tests (swept clash plan 3c), trimmed to the
// marshalling. The rig: a `base` plate on link `ground`; an `arm`, cuboid(3, 0.2, 0.2) from the
// hinge out along x, on link `arm`, turning on `hinge` (revolute about z through the origin); a
// `carriage` far out on `slide` (cylindrical, two values); and two cubes in no link, held fixed:
// `chord` below the hinge, which the chord between the arm's end poses crosses and its arc never
// does, and `circle` on the arm's circle at 90 degrees.

// A call returning nothing the test cannot go on without.
static void done(const Result<void>& r, const char* what) {
    if (!r) {
        std::fprintf(stderr, "FAIL: %s: %s\n", what, r.error().message.c_str());
        std::exit(1);
    }
}

// A refusal check on the whole text: the call must have returned exactly `message`.
template <class T>
static void refused_exactly(const Result<T>& r, const std::string& message, const std::string& what) {
    if (r.ok()) {
        check(false, what + ": expected a refusal, but the call succeeded");
        return;
    }
    check(r.error().message == message, what + ": refused with \"" + r.error().message + "\", wanted \"" + message + "\"");
}

// The frame at (x, y, z) with the world's axes.
static bs::Frame at3(double x, double y, double z) {
    return must(bs::Frame::make({x, y, z}, {1, 0, 0}, {0, 1, 0}, {0, 0, 1}), "Frame::make");
}

static const double PI = 3.14159265358979323846;

// Python's _hand(): a `tip` cube on link `body`, and a `nub` well above it on `nubs`, turning on
// `turn`.
static bs::Assembly hand() {
    bs::Assembly h = must(bs::Assembly::create("hand"), "Assembly::create");
    must(h.place_solid(must(bs::Solid::cuboid(0.4, 0.4, 0.4), "cuboid"), at3(0, 0, 0), "tip"), "place tip");
    must(h.place_solid(must(bs::Solid::cuboid(0.2, 0.2, 0.2), "cuboid"), at3(0, 0, 2), "nub"), "place nub");
    done(h.link("body", {"tip"}), "link body");
    done(h.link("nubs", {"nub"}), "link nubs");
    done(h.joint("turn", "body", "nubs"), "joint turn");
    done(h.pair("turn", "revolute", at3(0, 0, 0)), "pair turn");
    return h;
}

// Python's _rig(hand=None): the arm, or `held` placed as "hand" where the arm would be.
static bs::Assembly rig(const bs::Assembly* held = nullptr) {
    bs::Assembly r = must(bs::Assembly::create("rig"), "Assembly::create");
    must(r.place_solid(must(bs::Solid::cuboid(1, 1, 0.4), "cuboid"), at3(0, 0, -1), "base"), "place base");
    if (held) {
        must(r.place_assembly(*held, at3(1.5, 0, 0), "hand"), "place hand");
    } else {
        must(r.place_solid(must(bs::Solid::cuboid(3, 0.2, 0.2), "cuboid"), at3(1.5, 0, 0), "arm"), "place arm");
    }
    must(r.place_solid(must(bs::Solid::cuboid(0.4, 0.4, 0.4), "cuboid"), at3(0, -1.2, 0), "chord"), "place chord");
    must(r.place_solid(must(bs::Solid::cuboid(0.4, 0.4, 0.4), "cuboid"), at3(0, 1.5, 0), "circle"), "place circle");
    must(r.place_solid(must(bs::Solid::cuboid(0.4, 0.4, 0.4), "cuboid"), at3(20, 0, 0), "carriage"), "place carriage");
    done(r.link("ground", {"base"}), "link ground");
    done(r.link("arm", {held ? "hand" : "arm"}), "link arm");
    done(r.link("carriage", {"carriage"}), "link carriage");
    done(r.joint("hinge", "ground", "arm"), "joint hinge");
    done(r.pair("hinge", "revolute", at3(0, 0, 0)), "pair hinge");
    done(r.joint("slide", "ground", "carriage"), "joint slide");
    done(r.pair("slide", "cylindrical", at3(0, 0, 0)), "pair slide");
    done(r.base("ground"), "base");
    return r;
}

// Python's _SWING: the hinge at 0, 90 and 180 degrees, the carriage sliding 0, 0.5, 1 unturned.
static std::vector<std::vector<bs::StateRow>> swing() {
    return {
        {bs::StateRow{"hinge", {0.0}}, bs::StateRow{"slide", {0.0, 0.0}}},
        {bs::StateRow{"hinge", {PI / 2}}, bs::StateRow{"slide", {0.5, 0.0}}},
        {bs::StateRow{"hinge", {PI}}, bs::StateRow{"slide", {1.0, 0.0}}},
    };
}

// Python's _circle_time(gap): the time the arm's leading face (y = 0.1 in its own frame) is
// `gap` from the circle cube's corner (0.2, 1.3), the first point it meets, in the first segment.
static double circle_time(double gap) {
    double r = std::hypot(1.3, 0.2);
    double phi = std::atan2(0.2, 1.3);
    return (std::acos((0.1 + gap) / r) - phi) / (PI / 2);
}

static std::string listed(const std::vector<std::string>& names) {
    std::string out = "[";
    for (std::size_t i = 0; i < names.size(); ++i) out += (i ? ", \"" : "\"") + names[i] + "\"";
    return out + "]";
}

// 7. Parts: depth first, placements in order, a "/" inside a name escaped; none for an empty
// assembly.
static void assembly_parts() {
    bs::Assembly sub = must(bs::Assembly::create("pair"), "Assembly::create");
    must(sub.place_solid(must(bs::Solid::cuboid(1, 1, 1), "cuboid"), at3(0, 0, 0), "x"), "place x");
    must(sub.place_solid(must(bs::Solid::cuboid(1, 1, 1), "cuboid"), at3(2, 0, 0), "y"), "place y");
    bs::Assembly top = must(bs::Assembly::create("top"), "Assembly::create");
    must(top.place_solid(must(bs::Solid::cuboid(1, 1, 1), "cuboid"), at3(0, 5, 0), "p"), "place p");
    must(top.place_assembly(sub, at3(0, 0, 0), "a/b"), "place a/b");
    must(top.place_solid(must(bs::Solid::cuboid(1, 1, 1), "cuboid"), at3(0, 9, 0), "q"), "place q");
    std::vector<std::string> names = must(top.parts(), "Assembly::parts");
    std::vector<std::string> want{"p", "a\\/b/x", "a\\/b/y", "q"};
    check(names == want, "the parts are " + listed(names));
    bs::Assembly empty = must(bs::Assembly::create("empty"), "Assembly::create");
    std::vector<std::string> none = must(empty.parts(), "Assembly::parts of an empty assembly");
    check(none.empty(), "an empty assembly's parts are " + listed(none));
}

// 8. The arc, not the chord: one row, (arm, circle) by parts() names, first in the window.
// Catches the values flattened joint-major (the hinge would read the carriage's values and never
// reach the circle cube).
static void assembly_sweeps_the_arc_not_the_chord() {
    bs::Assembly r = rig();
    std::vector<std::string> names = must(r.parts(), "Assembly::parts");
    std::vector<std::string> want{"base", "arm", "chord", "circle", "carriage"};
    check(names == want, "the rig's parts are " + listed(names));
    std::vector<bs::SweptClash> rows = must(r.swept_clash(swing(), 0.0, TOL), "Assembly::swept_clash");
    check(rows.size() == 1, "the swing read " + described(rows));
    if (rows.size() != 1 || names.size() != 5) return;
    check(names[rows[0].a] == "arm" && names[rows[0].b] == "circle", "the swing read " + described(rows));
    double lo = circle_time(TOL);
    double hi = circle_time(0.0);
    check(lo - 1e-9 <= rows[0].first_time && rows[0].first_time <= hi + 1e-9,
          "the first time " + std::to_string(rows[0].first_time) + " is outside [" + std::to_string(lo) + ", " + std::to_string(hi) + "]");
    check(rows[0].first.a == rows[0].a && rows[0].first.b == rows[0].b, "first reads " + described(rows));
}

// 9. First at the posed frames: the arm starts at 1.5 rad, already through the circle cube, so
// the row is (1, 3, 0.0), and the overlap first rebuilds lies inside the arm's box turned 1.5
// about z.
static void assembly_first_is_at_the_posed_frames() {
    bs::Assembly r = rig();
    std::vector<std::vector<bs::StateRow>> keys{
        {bs::StateRow{"hinge", {1.5}}, bs::StateRow{"slide", {0.0, 0.0}}},
        {bs::StateRow{"hinge", {PI}}, bs::StateRow{"slide", {0.0, 0.0}}},
    };
    std::vector<bs::SweptClash> rows = must(r.swept_clash(keys, 0.0, TOL), "Assembly::swept_clash");
    check(rows.size() == 1 && rows[0].a == 1 && rows[0].b == 3 && rows[0].first_time == 0.0, "from 1.5 rad read " + described(rows));
    if (rows.size() != 1) return;
    bs::Solid common = must(rows[0].first.solid(), "Clash::solid");
    bs::Box got = must(common.bounds_box(TOL), "bounds_box");
    double co = std::cos(1.5);
    double si = std::sin(1.5);
    bs::Solid arm = must(must(bs::Solid::cuboid(3, 0.2, 0.2), "cuboid").translate(1.5, 0, 0), "translate");
    bs::Frame turned = must(bs::Frame::make({0, 0, 0}, {co, si, 0}, {-si, co, 0}, {0, 0, 1}), "Frame::make");
    bs::Box want = must(must(arm.bounds_box(TOL), "bounds_box").moved(turned), "Box::moved");
    for (int k = 0; k < 3; ++k) {
        check(want.lo[k] - 1e-6 <= got.lo[k] && got.hi[k] <= want.hi[k] + 1e-6,
              "axis " + std::to_string(k) + ": the overlap's box [" + std::to_string(got.lo[k]) + ", " + std::to_string(got.hi[k]) +
                  "] is outside the turned arm's [" + std::to_string(want.lo[k]) + ", " + std::to_string(want.hi[k]) + "]");
    }
    check(got.lo[1] >= 1.3 - 4 * TOL && got.hi[1] <= 1.7 + 4 * TOL && got.hi[0] > got.lo[0],
          "the overlap's box is y [" + std::to_string(got.lo[1]) + ", " + std::to_string(got.hi[1]) + "], x [" + std::to_string(got.lo[0]) +
              ", " + std::to_string(got.hi[0]) + "]");
}

// 10. Joined: a pin on the arm's link inside a bore on the ground link, the hinge joining them;
// no row by default, (0, 1, 0.0) with `joined`, none again with the pair allowed. Catches
// `joined` dropped on its way to the kernel.
static void assembly_tests_joined_links_only_when_asked() {
    bs::Assembly pinned = must(bs::Assembly::create("pinned"), "Assembly::create");
    must(pinned.place_solid(must(bs::Solid::cuboid(0.6, 0.6, 0.6), "cuboid"), at3(0, 0, 0), "bore"), "place bore");
    must(pinned.place_solid(must(bs::Solid::cuboid(0.2, 0.2, 0.2), "cuboid"), at3(0, 0, 0), "pin"), "place pin");
    done(pinned.link("ground", {"bore"}), "link ground");
    done(pinned.link("arm", {"pin"}), "link arm");
    done(pinned.joint("hinge", "ground", "arm"), "joint hinge");
    done(pinned.pair("hinge", "revolute", at3(0, 0, 0)), "pair hinge");
    std::vector<std::vector<bs::StateRow>> keys{{bs::StateRow{"hinge", {0.0}}}, {bs::StateRow{"hinge", {1.0}}}};
    std::vector<bs::SweptClash> apart = must(pinned.swept_clash(keys, 0.0, TOL), "Assembly::swept_clash");
    check(apart.empty(), "joined links were tested by default: " + described(apart));
    std::vector<bs::SweptClash> rows =
        must(pinned.swept_clash(keys, 0.0, TOL, 1e-3, 100000, {}, std::nullopt, true), "Assembly::swept_clash joined");
    check(rows.size() == 1 && rows[0].a == 0 && rows[0].b == 1 && rows[0].first_time == 0.0, "joined read " + described(rows));
    std::vector<std::pair<std::uint32_t, std::uint32_t>> allowed{{0, 1}};
    std::vector<bs::SweptClash> skipped =
        must(pinned.swept_clash(keys, 0.0, TOL, 1e-3, 100000, allowed, std::nullopt, true), "Assembly::swept_clash joined, allowed");
    check(skipped.empty(), "an allowed joined pair was still tested: " + described(skipped));
}

// 11. A sub-assembly rides its placement's link: the hand's tip meets the circle cube.
static void assembly_sub_assembly_rides_its_placements_link() {
    bs::Assembly held = hand();
    bs::Assembly r = rig(&held);
    std::vector<std::string> names = must(r.parts(), "Assembly::parts");
    std::vector<std::string> want{"base", "hand/tip", "hand/nub", "chord", "circle", "carriage"};
    check(names == want, "the rig with a hand lists " + listed(names));
    std::vector<bs::SweptClash> rows = must(r.swept_clash(swing(), 0.0, TOL), "Assembly::swept_clash");
    check(rows.size() == 1, "the hand's swing read " + described(rows));
    if (rows.size() != 1 || names.size() != 6) return;
    check(names[rows[0].a] == "hand/tip" && names[rows[0].b] == "circle", "the hand's swing read " + described(rows));
}

// 12. The refusals by their exact words: the wrapper's own (keyframes naming different joints,
// both ways round; a joint given twice; a different number of values), then the kernel's,
// passed on. `allowed` is pairs of uint32 here, as the one-shot's, so a malformed pair cannot be
// written.
static void assembly_refusals() {
    bs::Assembly held = hand();
    bs::Assembly r = rig(&held);
    std::vector<std::vector<bs::StateRow>> two{{bs::StateRow{"hinge", {0.0}}}, {bs::StateRow{"hinge", {1.0}}}};
    refused_exactly(r.swept_clash({{bs::StateRow{"hinge", {0.0}}, bs::StateRow{"slide", {0, 0}}},
                                   {bs::StateRow{"hinge", {1.0}}, bs::StateRow{"slide", {0, 0}}},
                                   {bs::StateRow{"hinge", {2.0}}}}),
                    "swept_clash: joint 'slide' is in keyframe 0 and not in keyframe 2", "a joint dropped in keyframe 2");
    refused_exactly(r.swept_clash({{bs::StateRow{"hinge", {0.0}}}, {bs::StateRow{"hinge", {1.0}}, bs::StateRow{"slide", {0, 0}}}}),
                    "swept_clash: joint 'slide' is in keyframe 1 and not in keyframe 0", "a joint added in keyframe 1");
    refused_exactly(r.swept_clash({{bs::StateRow{"hinge", {0.0}}}, {bs::StateRow{"hinge", {1.0}}, bs::StateRow{"hinge", {2.0}}}}),
                    "swept_clash: joint 'hinge' is given twice", "a joint given twice");
    refused_exactly(r.swept_clash({{bs::StateRow{"slide", {0, 0}}}, {bs::StateRow{"slide", {1}}}}),
                    "swept_clash: joint 'slide' has 2 values in keyframe 0 and 1 in keyframe 1", "a value count that changes");
    refused_exactly(r.swept_clash({{bs::StateRow{"hand/turn", {0.0}}}, {bs::StateRow{"hand/turn", {1.0}}}}),
                    "swept_clash: joint 'hand/turn' is in a sub-assembly; a sweep moves this assembly's own joints", "a sub-assembly's joint");
    refused_exactly(r.swept_clash({{bs::StateRow{"elbow", {0.0}}}, {bs::StateRow{"elbow", {1.0}}}}),
                    "swept_clash: no joint named 'elbow' in assembly 'rig' or under it", "an unknown joint");
    refused_exactly(r.swept_clash({{bs::StateRow{"hinge", {0.0, 0.0}}}, {bs::StateRow{"hinge", {1.0, 1.0}}}}),
                    "swept_clash: joint 'hinge' takes 1 values, but 2 were given", "a wrong value count");
    std::vector<std::vector<bs::StateRow>> one(two.begin(), two.begin() + 1);
    refused_exactly(r.swept_clash(one), "swept_clash: 1 poses, at least 2 are needed", "one keyframe");
    refused(r.swept_clash(two, 0.0, bs::DEFAULT_TOLERANCE, 0.0), "swept_clash: resolution 0", "resolution 0");
    refused_exactly(r.swept_clash(two, 0.0, bs::DEFAULT_TOLERANCE, 1e-3, 0), "swept_clash: max_steps must be at least 1", "max_steps 0");
    std::vector<std::pair<std::uint32_t, std::uint32_t>> out_of_range{{9, 0}};
    refused_exactly(r.swept_clash(two, 0.0, bs::DEFAULT_TOLERANCE, 1e-3, 100000, out_of_range),
                    "swept_clash: allowed pair (9, 0) names a part out of range", "an allowed pair out of range");
    refused_exactly(r.swept_clash(two, 0.0, bs::DEFAULT_TOLERANCE, 1e-3, 100000, {}, std::string_view("wheel")),
                    "swept_clash: assembly 'rig' has no link named 'wheel'", "an unknown ground");
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
        {"cube_through_cube", cube_through_cube},
        {"there_and_back", there_and_back},
        {"a_miss_within_the_clearance", a_miss_within_the_clearance},
        {"starting_inside", starting_inside},
        {"the_one_shot", the_one_shot},
        {"the_refusals", the_refusals},
        {"assembly_parts", assembly_parts},
        {"assembly_sweeps_the_arc_not_the_chord", assembly_sweeps_the_arc_not_the_chord},
        {"assembly_first_is_at_the_posed_frames", assembly_first_is_at_the_posed_frames},
        {"assembly_tests_joined_links_only_when_asked", assembly_tests_joined_links_only_when_asked},
        {"assembly_sub_assembly_rides_its_placements_link", assembly_sub_assembly_rides_its_placements_link},
        {"assembly_refusals", assembly_refusals},
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
    std::printf("swept clash: ok\n");
    return 0;
}
