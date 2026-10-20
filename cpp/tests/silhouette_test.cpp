// Both silhouette queries -- the curves where a body's surfaces turn away from the eye:
// the kernel's Solid::silhouette_beziers and the reader's Node::silhouette_beziers.
//
// The assertions are on values that pin the layout, not only on lengths: a stride-16
// unpack that reads a weight as a coordinate, or control points shifted by one slice, still
// give vectors of the right length.
//
//     cadaclysm_silhouette_test <rhino-fixtures-dir | -> [cadaclysm.lic]
//
// The reader half opens sphere.sat and box-chamfer-all.blacksmith.stp from the first
// argument's directory (the repository's own acis fixtures); "-" skips it, as an SDK
// checkout, which carries no fixtures, must.
#include <cadaclysm/cadaclysm.hpp>
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <limits>
#include <string>
#include <vector>

using cadaclysm::BeziersData64;
using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;

static int failures = 0;

// True when it held, so a caller can stop at a failed length check instead of indexing past the end
// of the vector the check has just said is too short.
static bool check(bool ok, const std::string& what) {
    if (ok) return true;
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
    return false;
}

static void check_close(double got, double want, double tolerance, const std::string& what) {
    check(std::fabs(got - want) <= tolerance,
          what + ": got " + std::to_string(got) + ", want " + std::to_string(want) + " +- " + std::to_string(tolerance));
}

// The layout: three doubles a control point, four control points and four weights a curve. The
// points and the weights are compared with each other, not with count(): BeziersData64::count() is
// weights.size() / 4, so "weights.size() == count() * 4" holds whatever the weights are and would
// pin nothing. This pins the 12-and-4 widths against each other. Only that half has been
// exercised (a mutant reading weights as count * 3 fails it); the `% 4` half cannot fail with this
// wrapper, whose weights are copied four at a time, and has no mutation behind it. False when it
// does not hold.
static bool well_shaped(const BeziersData64& rim, const std::string& what) {
    return check(rim.weights.size() % 4 == 0 && rim.points.size() == rim.weights.size() * 3,
                 what + ": points is " + std::to_string(rim.points.size()) + " doubles for " + std::to_string(rim.weights.size()) +
                     " weights, not three a control point, four a curve");
}

// Control point `k` of a silhouette's flat points: three doubles each.
static double coordinate(const BeziersData64& rim, std::size_t k, std::size_t axis) { return rim.points[k * 3 + axis]; }

// ---- the kernel ---------------------------------------------------------------------

static Result<void> sphere_rim() {
    CADACLYSM_TRY(sphere, bs::Solid::sphere(2.0));
    CADACLYSM_TRY(rim, sphere.silhouette_beziers());
    if (!check(rim.count() > 0, "a sphere gave no rim") || !well_shaped(rim, "a sphere's rim")) return {};
    for (std::size_t c = 0; c < rim.count(); ++c) {
        // Control points 0 and 3 are the arc's ends: on the sphere to 1e-9, with the
        // end weights exactly 1. The interior control points are not checked, and the
        // interior weights only to lie in (0, 1): both move with how the rim is subdivided.
        const std::string arc = "arc " + std::to_string(c);
        for (std::size_t end = 0; end < 2; ++end) {
            std::size_t k = c * 4 + (end == 0 ? 0 : 3);
            double x = coordinate(rim, k, 0), y = coordinate(rim, k, 1), z = coordinate(rim, k, 2);
            check_close(std::sqrt(x * x + y * y + z * z), 2.0, 1e-9,
                        arc + (end == 0 ? ": first" : ": last") + " control point's radius");
        }
        const double* w = rim.weights.data() + c * 4;
        check(w[0] == 1.0 && w[3] == 1.0, arc + ": an end weight is not exactly 1");
        check(w[1] > 0.0 && w[1] < 1.0 && w[2] > 0.0 && w[2] < 1.0,
              arc + ": weights are not 1, then two weights in (0, 1), then 1");
    }
    return {};
}

static Result<void> cylinder_rulings() {
    const double radius = 1.0;
    const double height = 3.0;
    CADACLYSM_TRY(cylinder, bs::Solid::cylinder(radius, height));
    bs::SvgOptions front;
    front.view = bs::SvgView::front;
    CADACLYSM_TRY(rulings, cylinder.silhouette_beziers(front));
    if (!check(rulings.count() > 0, "a cylinder gave no rulings") || !well_shaped(rulings, "a cylinder's rulings")) return {};
    for (std::size_t k = 0; k < rulings.weights.size(); ++k) {
        check(rulings.weights[k] == 1.0, "weight " + std::to_string(k) + " of a ruling is not 1");
    }
    double low = std::numeric_limits<double>::max();
    double high = std::numeric_limits<double>::lowest();
    for (std::size_t k = 0; k < rulings.weights.size(); ++k) {
        double x = coordinate(rulings, k, 0), y = coordinate(rulings, k, 1), z = coordinate(rulings, k, 2);
        const std::string where = "control point " + std::to_string(k);
        check_close(std::hypot(x, y), radius, 1e-6, where + " is off the cylinder's wall");
        // hypot(x, y) is symmetric in x and y, so it cannot tell them apart. The front view
        // looks along y and the silhouette of the cylinder sits on the x axis, at y = 0: that
        // is what pins x against y. Only |x| and |y| are asserted, not the sign of x and not
        // how many rulings there are.
        check_close(std::fabs(x), radius, 1e-6, where + " is not at |x| = radius");
        check(std::fabs(y) <= 1e-6, where + " is not at y = 0 (y = " + std::to_string(y) + ")");
        low = std::min(low, z);
        high = std::max(high, z);
    }
    // The rulings run cap to cap, so their z extent is the height: that pins z against x and y.
    check_close(high - low, height, 1e-6, "the rulings' z extent");
    return {};
}

static Result<void> refusal_then_empty_answer() {
    CADACLYSM_TRY(sphere, bs::Solid::sphere(2.0));
    // Built BEFORE the refusal, not between it and the empty answer: every call that builds, reads or writes
    // geometry in the library runs under its `guard` and clears the thread's error as its first act, so
    // building the cuboid in between would have wiped the reason this test exists to leave behind. The frees
    // do not clear (they only drop a box, outside the library's guard) and neither does reading the error, so
    // a finalizer or destructor running between the refusal and the empty answer cannot wipe the slot either:
    // the ordering holds even under a collection at the worst moment.
    CADACLYSM_TRY(cuboid, bs::Solid::cuboid(10.0, 10.0, 10.0));
    bs::SvgOptions infinite;
    infinite.tolerance = std::numeric_limits<double>::infinity();
    Result<BeziersData64> refused = sphere.silhouette_beziers(infinite);
    check(!refused.ok(), "an infinite tolerance was not refused");
    if (!refused.ok()) {
        check(refused.error().message.find("silhouette: ") != std::string::npos,
              "the refusal does not say 'silhouette: ': " + refused.error().message);
    }
    // The refusal above left its reason in the thread's error slot; the empty answer must not
    // read it as its own. Nothing clears the slot between the refusal and the native call: this
    // wrapper's default stroke is a packed number (`SvgColour stroke = 0x000000`), so packing the
    // options never reaches the colour parser (`cadaclysm_blacksmith_parse_colour`, a `guard`, which
    // would clear it), and `cadaclysm_blacksmith_svg_options_init` is a bare struct fill. So this
    // pins the library's own clearing at the call's entry as well as the wrapper's not reading the
    // slot early. Do not narrow it to the wording of the wrappers whose default stroke is colour
    // text, where packing does clear the slot: that is not true here.
    Result<BeziersData64> none = cuboid.silhouette_beziers();
    check(none.ok(), "an empty silhouette is an answer, not an error" + (none.ok() ? std::string() : ": " + none.error().message));
    if (none.ok()) {
        check(none->count() == 0, "a cuboid has a silhouette");
        check(none->points.empty() && none->weights.empty(), "the empty answer carries numbers");
    }
    return {};
}

// ---- the reader ---------------------------------------------------------------------

// The body node above the lump holds no shape of its own; the first node with extent is the part.
static Result<cadaclysm::Node> silhouette_part(const cadaclysm::Scene& scene) {
    for (const cadaclysm::Node& node : scene.nodes()) {
        std::array<double, 3> size = node.bounds64().size();
        if (size[0] > 0 || size[1] > 0 || size[2] > 0) return node;
    }
    return cadaclysm::Error{"the fixture has no part with extent"};
}

static Result<void> reader_sphere(const std::string& fixtures) {
    CADACLYSM_TRY(scene, cadaclysm::open(fixtures + "/sphere.sat"));
    CADACLYSM_TRY(node, silhouette_part(scene));
    cadaclysm::SvgOptions iso;
    iso.view = cadaclysm::SvgView::iso;
    CADACLYSM_TRY(rim, node.silhouette_beziers(iso));
    if (!check(rim.count() > 0, "a sphere gave no rim") || !well_shaped(rim, "the reader's sphere rim")) return {};
    for (std::size_t k = 0; k < rim.weights.size(); ++k) {
        check(std::isfinite(rim.weights[k]) && rim.weights[k] > 0.0, "weight " + std::to_string(k) + " is not finite and positive");
    }
    // Every control point lies within the library's fit budget of the sphere, at the bounds radius from the
    // bounds centre. That is NOT because control points lie on the sphere: the silhouette curve does, but a
    // cubic's interior control points do not. Here they stray up to 3.0e-3, while the end points are on it
    // to about 1e-14 -- a Bezier interpolates its first and last control point, so for a curve lying on the
    // sphere those two lie on it exactly. It holds because the arcs are short (half a unit on a radius of
    // 10), and the budget, extent * (tolerance / width) read off the options this call was given, with the
    // node's bounds diagonal standing in for the extent, is the tolerance the library fits the CURVE to,
    // not its control polygon. The margin is narrow: the curve itself uses nearly the whole budget
    // (3.42e-3 against 3.46e-3) since the lattice's spacing became a length in space (44efabc88); before,
    // a lattice ten times too fine left it at 1e-4.
    // So this catches a displaced or scaled result and a wildly mis-strided unpack. It is blind to a
    // one-CONTROL-POINT slip of the unpack: that is a shift of 3 doubles, so every point is replaced by
    // ANOTHER control point, which lies within the same budget, and the worst deviation is the same
    // before and after (3.04e-3 here on iso, against a budget of about 3.5e-3). A one-DOUBLE slip is
    // another matter: it mixes coordinates across neighbouring points, leaves the sphere, and is caught
    // (0.87 on iso, 8.8 on front). The chaining assertion below is what catches the one-control-point
    // slip. The budget also does NOT pin the eye (a silhouette point is a point of the surface, so it is
    // on the sphere from any view), the weights (all 1.0 on this fixture) or the radius separately from
    // the centre.
    cadaclysm::Bounds64 bounds = node.bounds64();
    std::array<double, 3> centre = bounds.centre();
    std::array<double, 3> size = bounds.size();
    const double radius = size[0] / 2.0;
    const double budget = std::sqrt(size[0] * size[0] + size[1] * size[1] + size[2] * size[2]) * (iso.tolerance / iso.width);
    double worst = 0.0;
    for (std::size_t k = 0; k < rim.weights.size(); ++k) {
        double dx = coordinate(rim, k, 0) - centre[0];
        double dy = coordinate(rim, k, 1) - centre[1];
        double dz = coordinate(rim, k, 2) - centre[2];
        worst = std::max(worst, std::fabs(std::sqrt(dx * dx + dy * dy + dz * dz) - radius));
    }
    check(radius > 0.0 && worst <= budget,
          "control points stray " + std::to_string(worst) + " from the bounds centre's radius " + std::to_string(radius) +
              ", past the budget " + std::to_string(budget));
    // Chaining, the assertion that sees an offset slip. The arcs come back in runs, not as one
    // ordered traversal, so "every arc ends where the next begins" is false: on this fixture 232
    // of the 235 consecutive pairs have the last control point of one arc equal to the first of
    // the next, to 1e-9 per coordinate (each of x, y and z is tested, so a passing pair can be up to
    // 1.73e-9 apart): four runs. A read shifted by a double or by a control point leaves none (0 of 235), so a
    // slip takes the count from over two hundred to zero. Every slip quoted here is a wrap-around, so
    // the length and the count are preserved and each denominator stays the unshifted pair count. The count varies with how the sphere is
    // tessellated; what makes a lower bound of 80 safe is not that it cannot drift but that it sits
    // about three times below the count on this fixture. It has drifted once: the bound was 400
    // against 1206 of 1209 until the lattice's spacing became a length in space (44efabc88) and the
    // same four runs came back in arcs five times longer.
    // The front view's figures are a measurement no test chains, kept because they explain the
    // threshold: there the property is much weaker (96 of 173 pairs, 55%, against 98.7% here;
    // 0 after a one-double or a one-control-point slip; 95 of 173 after a whole-curve slip), which
    // is why the bound is 80 and not near 230.
    // Its limit: a shift by a whole CURVE (12 doubles) keeps the chaining (231 of 235 still chain
    // here) and is NOT caught: it survives because the chaining is preserved. A wrap-around slip of
    // that size reads only inside the allocation, so it is reachable and silent.
    std::size_t chained = 0;
    for (std::size_t c = 0; c + 1 < rim.count(); ++c) {
        const double* last = rim.points.data() + c * 12 + 9;
        const double* first = rim.points.data() + (c + 1) * 12;
        if (std::fabs(last[0] - first[0]) <= 1e-9 && std::fabs(last[1] - first[1]) <= 1e-9 && std::fabs(last[2] - first[2]) <= 1e-9) ++chained;
    }
    check(chained >= 80, "only " + std::to_string(chained) + " of " + std::to_string(rim.count() - 1) +
                             " consecutive arcs chain (last control point = the next one's first), want at least 80");
    return {};
}

// Asked larger first, so the second call refills the same slot in place: iso gives more
// curves than front (236 against 174 here), so a view would show the second answer through
// the head of the first. The reverse order can pass with a view. It was front first until the
// lattice's spacing became a length in space (44efabc88): front gave 1248 against iso's 1210 then.
static Result<void> reader_answer_outlives_the_next_call(const std::string& fixtures) {
    CADACLYSM_TRY(scene, cadaclysm::open(fixtures + "/sphere.sat"));
    CADACLYSM_TRY(node, silhouette_part(scene));
    cadaclysm::SvgOptions front;
    front.view = cadaclysm::SvgView::front;
    cadaclysm::SvgOptions iso;
    iso.view = cadaclysm::SvgView::iso;
    CADACLYSM_TRY(first, node.silhouette_beziers(iso));
    const std::vector<double> kept_points = first.points;
    const std::vector<double> kept_weights = first.weights;
    CADACLYSM_TRY(second, node.silhouette_beziers(front));
    if (!check(second.count() > 0, "the second view gave no rim") || !well_shaped(second, "the second answer") ||
        !well_shaped(first, "the first answer")) {
        return {};
    }
    check(second.count() <= first.count(),
          "the larger answer must come first (iso " + std::to_string(first.count()) + ", front " + std::to_string(second.count()) + ")");
    check(second.points != kept_points, "the two views gave the same silhouette, so this cannot tell a copy from a view");
    // The next two are STRUCTURAL and cannot fail: the answer is a by-value vector, so nothing the
    // second call does can reach it, and `kept_*` is a copy of a copy. No mutation of the wrapper
    // can fall to them, short of changing the return type to a view; they are kept as the statement
    // of the property, not as a witness of it. (The LuaJIT reader test, whose answer is a table the
    // wrapper could reuse, is the witnessed twin: with its reader returning the ffi view instead of a
    // copy it fails with "the first answer's point 1 changed under the second call", witnessed in
    // the first round's mutation LR4 (task-6-report.md, commit 8ba464bec).)
    check(first.points == kept_points, "the first answer's points changed under the second call");
    check(first.weights == kept_weights, "the first answer's weights changed under the second call");
    return {};
}

static Result<void> reader_refusal_then_empty_answer(const std::string& fixtures) {
    CADACLYSM_TRY(scene, cadaclysm::open(fixtures + "/box-chamfer-all.blacksmith.stp"));
    CADACLYSM_TRY(node, silhouette_part(scene));
    cadaclysm::SvgOptions infinite;
    infinite.tolerance = std::numeric_limits<double>::infinity();
    Result<BeziersData64> refused = node.silhouette_beziers(infinite);
    check(!refused.ok(), "an infinite tolerance was not refused");
    if (!refused.ok()) {
        check(refused.error().message.find("silhouette: ") != std::string::npos,
              "the refusal does not say 'silhouette: ': " + refused.error().message);
    }
    // The refusal above left its reason in the thread's error slot; the empty answer must not
    // read it as its own. Nothing clears the slot between the refusal and the native call: this
    // wrapper's default stroke is a packed number (`SvgColour stroke = 0x000000`), so packing the
    // options never reaches the colour parser, and `cadaclysm_svg_options_init` is a bare struct
    // fill. So this pins the library's own clearing at the call's entry as well as the wrapper's
    // not reading the slot early.
    Result<BeziersData64> none = node.silhouette_beziers();
    check(none.ok(), "an empty silhouette is an answer, not an error" + (none.ok() ? std::string() : ": " + none.error().message));
    if (none.ok()) {
        check(none->count() == 0, "an all-planar body has a silhouette");
        check(none->points.empty() && none->weights.empty(), "the empty answer carries numbers");
    }
    return {};
}

static void report(const char* name, const Result<void>& outcome) {
    if (outcome) return;
    std::fprintf(stderr, "FAIL: %s: %s\n", name, outcome.error().message.c_str());
    ++failures;
}

int main(int argc, char** argv) {
    const std::string fixtures = argc > 1 ? argv[1] : "-";
    if (argc > 2) {
        Result<void> loaded = bs::license(argv[2]);
        if (!loaded) {
            std::fprintf(stderr, "FAIL: license: %s\n", loaded.error().message.c_str());
            return 1;
        }
    }
    report("sphere rim", sphere_rim());
    report("cylinder rulings", cylinder_rulings());
    report("refusal, then the empty answer", refusal_then_empty_answer());
    if (fixtures != "-") {
        report("reader sphere", reader_sphere(fixtures));
        report("reader answer outlives the next call", reader_answer_outlives_the_next_call(fixtures));
        report("reader refusal, then the empty answer", reader_refusal_then_empty_answer(fixtures));
    } else {
        std::puts("silhouette: reader half skipped (no fixtures directory)");
    }
    if (failures) {
        std::fprintf(stderr, "%d silhouette check(s) failed\n", failures);
        return 1;
    }
    std::puts("silhouette: OK");
    return 0;
}
