// Sketch curves as profiles -- Profile::polyline, arc, arc_through, ellipse, from_beziers,
// beziers, loops and chain_order -- at parity with the Python reference's
// test_sketch_curves_are_profiles_that_draw_as_beziers and test_open_sketch_curves_close_into_loops,
// the same numbers. Every type is spelled out (no `auto`). Needs the kernel library and a
// license; the exit code is the verdict.
//
//     cadaclysm_curves_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <utility>
#include <vector>

using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;

static int failures = 0;

static void check(bool ok, const std::string& what) {
    if (ok) return;
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
}

template <class T>
static T take(Result<T> r, const std::string& what) {
    if (!r) {
        std::fprintf(stderr, "FAIL: %s: %s\n", what.c_str(), r.error().message.c_str());
        std::exit(1);
    }
    return std::move(r).value();
}

static bool near(double a, double b, double tol = 1e-9) { return std::fabs(a - b) <= tol; }

static bool all_near(const std::vector<double>& got, const std::vector<double>& want, double tol = 1e-9) {
    if (got.size() != want.size()) return false;
    for (std::size_t i = 0; i < got.size(); ++i) {
        if (!near(got[i], want[i], tol)) return false;
    }
    return true;
}

static void refused_starting(const std::string& got, const std::string& want, const std::string& what) {
    check(got.compare(0, want.size(), want) == 0, what + ": refused with \"" + got + "\", wanted \"" + want + "\"");
}

static double volume_of(const bs::Profile& p, const bs::Frame& xy) {
    return take(take(bs::Solid::extrude(p, xy, 1), "extrude").mass(), "mass").volume;
}

static void sketch_curves_are_profiles_that_draw_as_beziers() {
    const double PI = 3.14159265358979323846;
    bs::Frame xy = take(bs::Frame::xy(), "Frame::xy");
    bs::Profile line = take(bs::Profile::polyline({{1, 2}, {4, 6}}), "polyline");
    check(all_near(take(line.beziers(), "beziers"), {1, 2, 0, 1, 2, 10.0 / 3, 0, 1, 3, 14.0 / 3, 0, 1, 4, 6, 0, 1}),
          "a line is one straight Bezier with its thirds on the chord");
    check(take(take(bs::Profile::polyline({{0, 0}, {4, 0}, {4, 3}}, true), "closed polyline").beziers(), "beziers").size() == 3 * 16,
          "a closed polyline is a Bezier a side");
    bs::Profile circle = take(bs::Profile::arc({1, 2}, 3, 0, 0), "arc");
    std::vector<double> flat = take(circle.beziers(), "circle beziers");
    check(flat.size() == 4 * 16, "a full circle is four Beziers");
    for (std::size_t k = 0; k + 16 <= flat.size(); k += 16) {
        check(near(std::hypot(flat[k] - 1, flat[k + 1] - 2), 3), "a Bezier starts on the circle");
        check(near(flat[k + 3], 1) && near(flat[k + 7], std::sqrt(0.5) * 2 / 3 + 1.0 / 3), "quarter-turn conic weights");
    }
    bs::Profile reference = take(bs::Profile::circle(3), "circle");
    check(std::fabs(volume_of(circle, xy) - volume_of(reference, xy)) <= 1e-6 * volume_of(reference, xy),
          "the arc circle extrudes to the circle's volume");
    std::vector<double> quarter = take(take(bs::Profile::arc({0, 0}, 2, 0, PI / 2), "quarter").beziers(), "quarter beziers");
    check(near(quarter[12], 0, 1e-12) && near(quarter[13], 2, 1e-12), "a quarter arc ends at (0, 2)");
    bs::Profile ellipse = take(bs::Profile::ellipse({0, 0}, 3, 1), "ellipse");
    check(take(ellipse.beziers(), "ellipse beziers").size() == 4 * 16, "an ellipse is four Beziers");
    check(std::fabs(volume_of(ellipse, xy) - PI * 3) <= 1e-2 * PI * 3, "the ellipse extrudes to pi*a*b");
    // Through a middle point: the arc that passes it, whichever side it is on.
    std::vector<double> up = take(take(bs::Profile::arc_through({0, 0}, {2, 2}, {4, 0}), "up").beziers(), "up beziers");
    std::vector<double> down = take(take(bs::Profile::arc_through({0, 0}, {2, -2}, {4, 0}), "down").beziers(), "down beziers");
    double top = -1e300;
    double bottom = 1e300;
    for (std::size_t i = 1; i < up.size(); i += 4) top = std::fmax(top, up[i]);
    for (std::size_t i = 1; i < down.size(); i += 4) bottom = std::fmin(bottom, down[i]);
    check(near(top, 2) && near(bottom, -2), "arc_through passes its middle point on either side");
    // Carried onto a plane: the Front plane five along -y.
    std::array<double, 12> front = {0, -5, 0, 1, 0, 0, 0, 0, 1, 0, -1, 0};
    std::vector<double> on_front = take(line.beziers(front), "beziers on front");
    check(near(on_front[0], 1) && near(on_front[1], -5) && near(on_front[2], 2) && near(on_front[12], 4) &&
              near(on_front[13], -5) && near(on_front[14], 6),
          "the line carried onto the Front plane");
    // And back: kept exact, they round-trip to the same numbers; recognised, a circle is arcs again.
    check(all_near(take(take(bs::Profile::from_beziers(flat, false), "from_beziers exact").beziers(), "beziers"), flat),
          "exact Beziers round-trip");
    bs::Solid again = take(bs::Solid::extrude(take(bs::Profile::from_beziers(flat), "from_beziers"), xy, 1), "extrude");
    bool kinds = true;
    for (std::uint32_t i = 0; i < again.faces(); ++i) {
        std::string k = take(again.face_kind(i), "face_kind");
        kinds = kinds && (k == "cylinder" || k == "plane");
    }
    check(kinds, "a recognised circle extrudes to a cylinder");
    refused_starting(bs::Profile::arc_through({0, 0}, {1, 1}, {2, 2}).error().message,
                     "profile_arc_through: the arc's three points are in a line", "arc_through collinear");
    refused_starting(bs::Profile::polyline({{0, 0}}).error().message, "profile_polyline: a polyline needs at least two points",
                     "polyline of one point");
    refused_starting(bs::Profile::from_beziers({}).error().message, "profile_from_beziers: ", "from_beziers of none");
}

typedef std::vector<std::vector<std::uint32_t>> Loops;
typedef std::vector<std::pair<std::uint32_t, bool>> Order;

static void open_sketch_curves_close_into_loops() {
    bs::Profile d_line = take(bs::Profile::polyline({{0, 0}, {4, 0}}), "d_line");
    bs::Profile d_arc = take(bs::Profile::arc_through({4, 0}, {2, 2}, {0, 0}), "d_arc");
    bs::Profile stray = take(bs::Profile::polyline({{9, 9}, {10, 9}}), "stray");
    bs::Profile ring = take(bs::Profile::arc({20, 0}, 1, 0, 0), "ring");
    check(take(bs::Profile::loops({stray, d_line, ring, d_arc}), "loops") == Loops({{1, 3}, {2}}),
          "a D and a ring close; the stray does not");
    // A corner where three ends meet is ambiguous: no loop through it.
    bs::Profile spur = take(bs::Profile::polyline({{0, 0}, {-3, 0}}), "spur");
    check(take(bs::Profile::loops({d_line, d_arc, spur}), "loops with a spur").empty(), "an ambiguous corner closes no loop");
    // The chain's order: the arc first here, then the line -- neither turned round.
    check(take(bs::Profile::chain_order({d_arc, d_line}), "chain_order") == Order({{0, false}, {1, false}}), "chain order, neither turned");
    bs::Profile back = take(bs::Profile::polyline({{7, 0}, {4, 0}}), "back");
    check(take(bs::Profile::chain_order({d_line, back}), "chain_order turned") == Order({{0, false}, {1, true}}),
          "chain order, the second turned round");
    refused_starting(bs::Profile::chain_order({d_line, stray}).error().message, "chain: piece 1 does not meet the others",
                     "chain_order of a stray");
    bs::Profile holed = take(take(bs::Profile::rect(9, 9), "rect").with_hole(take(bs::Profile::circle(1), "circle")), "with_hole");
    refused_starting(bs::Profile::loops({holed}).error().message, "profile_loops: piece 0 has holes", "loops of a holed piece");
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
        {"sketch_curves_are_profiles_that_draw_as_beziers", sketch_curves_are_profiles_that_draw_as_beziers},
        {"open_sketch_curves_close_into_loops", open_sketch_curves_close_into_loops},
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
    std::printf("curves: ok\n");
    return 0;
}
