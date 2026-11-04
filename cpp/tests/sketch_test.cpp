// The 2D constraint sketcher -- Sketch, SketchRect, SolveReport, Dof and PartDof over the
// cadaclysm_blacksmith_sketch_* calls -- at parity with the Python reference's test_a_sketch_*
// tests in test_cadaclysm_blacksmith.py: facts S1-S8 and S10-S12 of the sketch-constraints
// plan, the same values. Every type is spelled out (no `auto`). Needs the kernel library and a
// license; the exit code is the verdict.
//
//     cadaclysm_sketch_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <map>
#include <optional>
#include <string>
#include <utility>
#include <vector>

using cadaclysm::Error;
using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;
using bs::Vec2;

typedef std::vector<std::uint32_t> Ids;

static int failures = 0;

static void check(bool ok, const std::string& what) {
    if (ok) return;
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
}

// A value the test cannot go on without: a refusal ends the run.
template <class T>
static T take(Result<T> r, const std::string& what) {
    if (!r) {
        std::fprintf(stderr, "FAIL: %s: %s\n", what.c_str(), r.error().message.c_str());
        std::exit(1);
    }
    return std::move(r).value();
}

static void take_void(const Result<void>& r, const std::string& what) {
    if (!r) {
        std::fprintf(stderr, "FAIL: %s: %s\n", what.c_str(), r.error().message.c_str());
        std::exit(1);
    }
}

// Error stays an aggregate: it brace-initialises with and without `ids`, from a return
// statement too, and ids start empty. (Designated initialisers are C++20; checked separately.)
static Error aggregate_error() { return {"x", cadaclysm::Origin::kernel}; }
static void error_is_an_aggregate() {
    Error one{"one"};
    Error two{"two", cadaclysm::Origin::view};
    Error three{"three", cadaclysm::Origin::kernel, Ids({1, 2})};
    check(one.ids.empty() && two.ids.empty() && aggregate_error().ids.empty(), "Error ids start empty");
    check(two.origin == cadaclysm::Origin::view && three.ids == Ids({1, 2}), "Error brace-init keeps its fields");
}

static Ids sorted(Ids ids) {
    std::sort(ids.begin(), ids.end());
    return ids;
}

static bool near(double got, double want, double tol) { return std::fabs(got - want) <= tol; }

enum class Match { starts, contains };

// A refusal check that fails when nothing was refused: the call must have returned an error
// whose text matches. Returns the ids the refusal carried.
template <class T>
static Ids refused(const Result<T>& r, Match how, const std::string& want, const std::string& what) {
    if (r.ok()) {
        check(false, what + ": expected a refusal, but the call succeeded");
        return Ids{};
    }
    const std::string& got = r.error().message;
    bool ok = how == Match::starts ? got.compare(0, want.size(), want) == 0 : got.find(want) != std::string::npos;
    check(ok, what + ": refused with \"" + got + "\", wanted \"" + want + "\"");
    return r.error().ids;
}

static bs::Sketch fresh() { return take(bs::Sketch::create(), "Sketch::create"); }

static Vec2 point_of(const bs::Sketch& s, std::uint32_t id) { return take(s.point(id), "point"); }

// S1
static void dimensions_a_plate_and_extrudes_it() {
    bs::Sketch s = fresh();
    bs::SketchRect rect = take(s.add_rect({0, 0}, {40, 30}), "add_rect");
    check(rect.corners.size() == 4 && rect.sides.size() == 4, "S1: a rect has 4 corners and 4 sides");
    take(s.fix(rect.corners[0]), "fix");
    std::uint32_t width = take(s.length(rect.sides[0], 60), "length width");
    take(s.length(rect.sides[1], 30), "length height");
    std::uint32_t centre = take(s.add_point(30, 15), "add_point");
    std::uint32_t hole = take(s.add_circle(centre, 5), "add_circle");
    take(s.radius_of(hole, 5), "radius_of");
    bs::SolveReport report = take(s.solve(), "solve");
    check(report.converged() && report.status == "converged", "S1: solve converged");
    check(report.ids.empty(), "S1: a converged solve names no ids");
    Vec2 corner = point_of(s, rect.corners[1]);
    check(near(corner[0], 60.0, 1e-9) && near(corner[1], 0.0, 1e-9), "S1: corner 1 is at (60, 0)");
    check(take(s.constraint_kind(width), "constraint_kind") == "length", "S1: the width is a length");
    std::optional<double> value = take(s.constraint_value(width), "constraint_value");
    check(value.has_value() && *value == 60.0, "S1: the width reads 60");
    bs::Dof dof = take(s.diagnose(), "diagnose");
    check(dof.free == 2 && dof.state == "under", "S1: free 2, under");
    std::vector<bs::Profile> profiles = take(s.profiles(1e-9), "profiles");
    check(profiles.size() == 1, "S1: one profile");
    if (profiles.size() != 1) return;
    bs::Solid body = take(bs::Solid::extrude(profiles[0], take(bs::Frame::xy(), "Frame::xy"), 10), "extrude");
    check(take(body.mass(), "mass").volume > 0.0, "S1: the extrusion has volume");
}

// S2
static void refuses_a_conflict_with_ids() {
    bs::Sketch s = fresh();
    bs::SketchRect rect = take(s.add_rect({0, 0}, {40, 30}), "add_rect");
    take(s.fix(rect.corners[0]), "fix");
    take(s.length(rect.sides[0], 40), "length");
    take(s.length(rect.sides[1], 30), "length");
    Ids over = refused(s.distance(rect.corners[0], rect.corners[2], 10), Match::starts, "sketch_constrain: over-constrained",
                       "S2 distance");
    check(over == Ids({0, 1, 5, 6}), "S2: the conflict names constraints 0, 1, 5, 6");
    check(take(s.constraints(), "constraints").size() == 7, "S2: a refused constraint leaves 7");
    Ids holders =
        refused(s.remove_entity(rect.corners[0]), Match::starts, "sketch_remove_entity: point", "S2 remove_entity");
    check(sorted(holders) == sorted(Ids({rect.sides[0], rect.sides[3]})), "S2: the sides holding the corner are named");
    Ids none = refused(s.kind(9999), Match::contains, "sketch_kind", "S2 kind(9999)");
    check(none.empty(), "S2: kind(9999) carries no ids");
    s.close();
    refused(s.solve(), Match::starts, "sketch: closed", "S2 solve after close");
    check(s.closed(), "S2: closed() after close()");
    s.close();  // a second close is a no-op
}

// S3
static void drag_moves_the_point_it_holds() {
    bs::Sketch s = fresh();
    bs::SketchRect rect = take(s.add_rect({0, 0}, {40, 30}), "add_rect");
    std::vector<std::pair<std::uint32_t, Vec2>> moves;
    moves.push_back(std::make_pair(rect.corners[0], Vec2{5.0, 5.0}));
    bs::SolveReport r = take(s.drag(moves), "drag");
    check(r.converged() && r.ids.empty(), "S3: the drag converged with no ids");
    Vec2 p = point_of(s, rect.corners[0]);
    check(near(p[0], 5.0, 1e-9) && near(p[1], 5.0, 1e-9), "S3: the corner is at (5, 5)");
    check(near(point_of(s, rect.corners[1])[1], 5.0, 1e-9), "S3: the side stays level");
}

// S4
static void reference_follows_its_source() {
    bs::Sketch plate = fresh();
    bs::Sketch boss = fresh();
    bs::SketchRect rect = take(plate.add_rect({0, 0}, {40, 30}), "add_rect");
    take(plate.fix(rect.corners[0]), "fix");
    std::uint32_t width = take(plate.length(rect.sides[0], 40), "length");
    take(plate.length(rect.sides[1], 30), "length");
    std::uint32_t edge = take(boss.reference(plate, rect.sides[1]), "reference");
    check(take(boss.is_reference(edge), "is_reference") && take(boss.is_construction(edge), "is_construction"),
          "S4: the edge is a reference and construction");
    std::uint32_t o = take(boss.add_point(130, 15), "add_point");
    std::uint32_t hole = take(boss.add_circle(o, 12), "add_circle");
    take(boss.radius_of(hole, 12), "radius_of");
    take(boss.point_line_distance(o, edge, 100), "point_line_distance");
    check(near(point_of(boss, o)[0], 140.0, 1e-9), "S4: o.x is 140");
    check(take(boss.profiles(1e-9), "profiles").size() == 1, "S4: the reference is not part of a profile");
    check(take(plate.set_value(width, 60), "set_value").converged(), "S4: the plate re-solves");
    bs::SolveReport r = take(boss.update_reference(edge, plate), "update_reference");
    check(r.converged() && r.ids.empty(), "S4: update_reference converged with no ids");
    check(near(point_of(boss, o)[0], 160.0, 1e-9), "S4: o.x follows the plate to 160");
    Ids none = refused(boss.update_reference(o, plate), Match::starts, "sketch_update_reference: entity",
                       "S4 update_reference(o)");
    check(none.empty(), "S4: that refusal carries no ids");
    refused(boss.reference(boss, o), Match::contains, "cannot reference itself", "S4 reference(self)");
}

// S5
static void comes_from_a_profile_and_keeps_its_tangents() {
    bs::Profile slot = take(bs::Profile::slot({0, 0}, 60, 8), "Profile::slot");
    bs::Sketch s = take(bs::Sketch::from_profile(slot, true, 1e-9), "from_profile");
    int tangents = 0;
    bool joints = true;
    for (std::uint32_t c : take(s.constraints(), "constraints")) {
        if (take(s.constraint_kind(c), "constraint_kind") != "tangent") continue;
        ++tangents;
        joints = joints && take(s.is_joint_tangent(c), "is_joint_tangent");
    }
    check(tangents == 4 && joints, "S5: four tangent constraints, all joints");
    check(take(s.diagnose(), "diagnose").free == 4, "S5: free is 4");
}

// S6 and S7
static void reads_back_what_it_holds() {
    bs::Sketch s = fresh();
    std::uint32_t a = take(s.add_point(0, 0), "add_point a");
    std::uint32_t b = take(s.add_point(10, 0), "add_point b");
    std::uint32_t line = take(s.add_line(a, b), "add_line");
    check(take(s.kind(a), "kind") == "point" && take(s.kind(line), "kind") == "line", "S6: point and line kinds");
    check(take(s.entities(), "entities") == sorted(Ids({a, b, line})), "S6: entities are sorted a, b, line");
    check(take(s.ends(line), "ends") == Ids({a, b}), "S6: the line's ends are a, b");
    std::uint32_t c = take(s.add_circle(take(s.add_point(0, 20), "add_point"), 3), "add_circle");
    check(take(s.kind(c), "kind") == "circle", "S6: circle kind");
    check(take(s.radius(c), "radius") == 3.0, "S6: radius 3");
    check(take(s.kind(take(s.centre(c), "centre")), "kind") == "point", "S6: the centre is a point");
    take_void(s.set_radius(c, 4), "set_radius");
    check(take(s.radius(c), "radius") == 4.0, "S6: radius 4");
    take_void(s.set_point(b, 12, 0), "set_point");
    check(point_of(s, b) == Vec2({12.0, 0.0}), "S6: b is (12, 0)");
    take_void(s.set_construction(c), "set_construction");
    check(take(s.is_construction(c), "is_construction") && !take(s.is_reference(c), "is_reference"),
          "S6: c is construction, not a reference");
    std::uint32_t h = take(s.horizontal(a, b), "horizontal");
    check(take(s.constraint_kind(h), "constraint_kind") == "horizontal", "S6: horizontal kind");
    check(take(s.constraint_refs(h), "constraint_refs") == Ids({a, b}), "S6: horizontal refs a, b");
    check(!take(s.constraint_value(h), "constraint_value").has_value(), "S6: horizontal has no value");
    check(!take(s.constraint_driving(h), "constraint_driving"), "S6: horizontal is not driving");
    check(take(s.constraint_sense(h), "constraint_sense") == "auto", "S6: sense auto");
    std::uint32_t d = take(s.distance(a, b, 15, false), "distance");
    std::optional<double> dv = take(s.constraint_value(d), "constraint_value");
    check(dv.has_value() && *dv == 15.0 && !take(s.constraint_driving(d), "constraint_driving"),
          "S6: a reporting distance reads 15, not driving");
    check(near(take(s.measure(d), "measure"), 12.0, 1e-12), "S6: it measures 12");
    bs::SolveReport r = take(s.set_driving(d, true), "set_driving");
    dv = take(s.constraint_value(d), "constraint_value");
    check(r.converged() && take(s.constraint_driving(d), "constraint_driving") && dv.has_value() && *dv == 12.0,
          "S6: a distance made driving takes what it measures");
    r = take(s.set_value(d, 20), "set_value");
    check(r.converged() && near(take(s.measure(d), "measure"), 20.0, 1e-9), "S6: set_value 20 measures 20");
    std::vector<std::pair<std::uint32_t, Vec2>> moves;
    moves.push_back(std::make_pair(b, Vec2{25.0, 5.0}));
    r = take(s.drag(moves), "drag");
    check(r.status == "converged" || r.status == "conflicting" || r.status == "diverged", "S6: drag returns a report");
    check(take(s.constraints(), "constraints") == sorted(Ids({h, d})), "S6: constraints are h, d");
    take_void(s.remove(h), "remove");
    check(take(s.constraints(), "constraints") == Ids({d}), "S6: only d remains");
    check(take(s.remove_entity(line), "remove_entity") == Ids({d}), "S6: removing the line removes d");
    std::vector<std::uint32_t> left = take(s.entities(), "entities");
    check(std::find(left.begin(), left.end(), a) == left.end(), "S6: a went with the line");
    check(take(s.constraints(), "constraints").empty(), "S6: no constraints left");
    std::uint32_t bez = take(s.add_bezier(take(s.add_point(0, 0), "add_point"), {1, 1}, {2, 1}, {3, 0}), "add_bezier");
    check(take(s.kind(bez), "kind") == "free_curve" && take(s.ends(bez), "ends").size() == 4,
          "S6: a bezier is a free curve with 4 ends");
    check(take(s.open_chains(1e-9), "open_chains").size() == 1, "S6: one open chain");
    refused(s.kind(9999), Match::contains, "sketch_kind", "S6 kind(9999)");
    refused(s.tangent(bez, c, "sideways"), Match::contains, "sense", "S6 tangent sideways");
    Result<std::uint32_t> bad = s.tangent(bez, c, "sideways");
    check(!bad && bad.error().message ==
                      "tangent: sense must be one of 'auto', 'positive', 'negative', not 'sideways'",
          "S6: the sense text names the call, the parameter and the choices");
    refused(s.tangent_at_end(bez, c, "middle"), Match::contains, "end must be one of 'start', 'end'",
            "S6 tangent_at_end middle");

    // S7: tangent_at_end reads back its end
    std::uint32_t p = take(s.add_point(0, 0), "add_point");
    std::uint32_t q = take(s.add_point(4, 0), "add_point");
    std::uint32_t seg = take(s.add_line(p, q), "add_line");
    std::uint32_t curve = take(s.add_bezier(q, {5, 0}, {6, 1}, {7, 1}), "add_bezier");
    std::uint32_t at_end = take(s.tangent_at_end(curve, seg, "end"), "tangent_at_end");
    check(take(s.constraint_end(at_end), "constraint_end") == "end", "S7: end reads back end");
    check(take(s.constraint_end(take(s.tangent_at_end(curve, seg), "tangent_at_end")), "constraint_end") == "start",
          "S7: the default reads start");
    check(take(s.constraint_end(take(s.length(seg, 4), "length")), "constraint_end") == "start",
          "S7: a kind without an end reads start");
    refused(s.constraint_end(999), Match::starts, "sketch_constraint_end: no constraint 999", "S7 constraint_end(999)");
}

// S8
static void nurbs_and_finite() {
    bs::Sketch s = fresh();
    std::uint32_t start = take(s.add_point(0, 0), "add_point");
    std::vector<Vec2> points;
    points.push_back(Vec2{1, 2});
    points.push_back(Vec2{3, 2});
    points.push_back(Vec2{4, 0});
    std::vector<double> knots;
    for (double k : {0.0, 0.0, 0.0, 0.5, 1.0, 1.0, 1.0}) knots.push_back(k);
    std::vector<double> few;
    for (double w : {1.0, 1.0, 1.0}) few.push_back(w);
    refused(s.add_nurbs(start, points, knots, 2, few), Match::contains, "sketch_add_nurbs", "S8 one weight too few");
    Result<std::uint32_t> short_list = s.add_nurbs(start, points, knots, 2, few);
    check(!short_list && short_list.error().message ==
                                 "sketch_add_nurbs: 3 weights for 4 control points (the start and 3 given); give one per point",
          "S8: the weight text matches Python's");
    std::vector<double> weights;
    for (double w : {1.0, 0.5, 0.5, 1.0}) weights.push_back(w);
    std::uint32_t curve = take(s.add_nurbs(start, points, knots, 2, weights), "add_nurbs");
    Ids ends = take(s.ends(curve), "ends");
    check(take(s.kind(curve), "kind") == "free_curve" && ends.size() == 4 && ends[0] == start,
          "S8: a free curve with 4 ends, the first the start");
    std::uint32_t plain = take(s.add_nurbs(start, points, knots, 2), "add_nurbs without weights");
    check(take(s.kind(plain), "kind") == "free_curve", "S8: a plain B-spline is a free curve");

    bs::Sketch t = fresh();
    refused(t.add_point(std::numeric_limits<double>::quiet_NaN(), 0), Match::starts,
            "sketch_add_point: the coordinates must be finite", "S8 add_point(NaN)");
    check(take(t.entities(), "entities").empty(), "S8: entities() still empty");
}

// S10
static void sense_sides_and_unknown_reads() {
    const std::array<std::string, 2> senses = {"positive", "negative"};
    const std::array<double, 2> sides = {3.0, -3.0};
    for (std::size_t i = 0; i < senses.size(); ++i) {
        bs::Sketch s = fresh();
        std::uint32_t a = take(s.add_point(0, 0), "add_point");
        std::uint32_t b = take(s.add_point(10, 0), "add_point");
        std::uint32_t line = take(s.add_line(a, b), "add_line");
        take(s.fix(a), "fix");
        take(s.fix(b), "fix");
        std::uint32_t p = take(s.add_point(4, sides[i] > 0 ? 1.0 : -1.0), "add_point");
        std::uint32_t d = take(s.point_line_distance(p, line, 3, true, senses[i]), "point_line_distance");
        check(take(s.solve(), "solve").converged(), "S10: " + senses[i] + " converged");
        check(near(point_of(s, p)[1], sides[i], 1e-6), "S10: " + senses[i] + " puts the point on its side");
        check(take(s.constraint_sense(d), "constraint_sense") == senses[i], "S10: the sense reads back " + senses[i]);
    }
    bs::Sketch s = fresh();
    refused(s.constraint_value(999), Match::contains, "999", "S10 constraint_value(999)");
    refused(s.constraint_driving(999), Match::contains, "999", "S10 constraint_driving(999)");
    refused(s.radius(999), Match::contains, "sketch_radius", "S10 radius(999)");
    refused(s.measure(999), Match::contains, "sketch_measure", "S10 measure(999)");
}

// S11
static void diagnosis_lists_name_redundant_and_conflicting() {
    bs::Sketch s = fresh();
    bs::SketchRect rect = take(s.add_rect({0, 0}, {40, 30}), "add_rect");
    take(s.fix(rect.corners[0]), "fix");
    take(s.length(rect.sides[0], 40), "length");
    take(s.length(rect.sides[1], 30), "length");
    std::uint32_t h = take(s.horizontal(rect.corners[3], rect.corners[2]), "horizontal");
    check(h == 7, "S11: the extra horizontal is constraint 7");
    bs::Dof dof = take(s.diagnose(), "diagnose");
    check(dof.free == 0 && dof.state == "full", "S11: free 0, full");
    check(dof.redundant == Ids({7}), "S11: redundant [7]");
    check(dof.conflicting.empty(), "S11: conflicting []");
    check(dof.parts.size() == 1, "S11: one part");
    if (dof.parts.size() != 1) return;
    const bs::PartDof& part = dof.parts[0];
    check(part.free == 0 && part.state == "full", "S11: the part is full, free 0");
    check(part.redundant == Ids({7}), "S11: part redundant [7]");
    check(part.conflicting.empty(), "S11: part conflicting []");
    check(part.constraints == Ids({0, 1, 2, 3, 5, 6, 7}), "S11: part constraints 0, 1, 2, 3, 5, 6, 7");
}

// S12
static void a_set_value_that_cannot_converge_is_refused_with_its_ids() {
    bs::Sketch s = fresh();
    std::uint32_t a = take(s.add_point(0, 0), "add_point");
    std::uint32_t b = take(s.add_point(1, 0), "add_point");
    std::uint32_t c = take(s.add_point(0, 1), "add_point");
    take(s.distance(a, b, 1), "distance");
    take(s.distance(b, c, 1), "distance");
    std::uint32_t d3 = take(s.distance(a, c, 1), "distance");
    Ids ids = refused(s.set_value(d3, 10), Match::starts, "sketch_set_value: the solve did not converge", "S12 set_value");
    check(ids == Ids({2, 0, 1}), "S12: the refusal names constraints 2, 0, 1 in the library's order");
    check(take(s.solve(), "solve").converged(), "S12: the refused edit was reverted");
}

// One place per constraint along x, so none fights another and none is refused.
struct Bench {
    bs::Sketch& s;
    double ox = 0;
    void place() { ox += 100; }
    std::uint32_t pt(double x, double y) { return take(s.add_point(ox + x, y), "add_point"); }
    std::uint32_t line(double x0, double y0, double x1, double y1) {
        std::uint32_t a = pt(x0, y0);
        std::uint32_t b = pt(x1, y1);
        return take(s.add_line(a, b), "add_line");
    }
    std::uint32_t circle(double x, double y, double r) { return take(s.add_circle(pt(x, y), r), "add_circle"); }
    // Reads the constraint `id` made on `refs` back: its kind, refs in order, value, sense and a clean solve.
    void read_back(const std::string& kind, const Ids& refs, std::uint32_t id, const std::optional<double>& value,
                   const std::string& sense = "") {
        check(take(s.constraint_kind(id), "constraint_kind") == kind, kind + ": kind reads back");
        check(take(s.constraint_refs(id), "constraint_refs") == refs, kind + ": refs read back in order");
        std::optional<double> got = take(s.constraint_value(id), "constraint_value");
        check(got.has_value() == value.has_value() && (!value || *got == *value), kind + ": value reads back");
        if (!sense.empty()) check(take(s.constraint_sense(id), "constraint_sense") == sense, kind + ": sense reads back");
        check(take(s.solve(), "solve").converged(), kind + ": solves");
    }
};

// Every constraint method on geometry of its own: none is refused, each reads back its kind and refs.
static void every_constraint_method_adds_its_kind() {
    // The name round-trips through the wrapper's own table, so pin the table to the header's codes.
    const std::pair<std::uint32_t, const char*> header_codes[27] = {
        {CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_COINCIDENT, "coincident"},
        {CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_POINT_ON_LINE, "point_on_line"},
        {CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_POINT_ON_CIRCLE, "point_on_circle"},
        {CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_HORIZONTAL, "horizontal"},
        {CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_VERTICAL, "vertical"},
        {CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_PARALLEL, "parallel"},
        {CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_PERPENDICULAR, "perpendicular"},
        {CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_COLLINEAR, "collinear"},
        {CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_TANGENT, "tangent"},
        {CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_TANGENT_AT_END, "tangent_at_end"},
        {CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_CONCENTRIC, "concentric"},
        {CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_EQUAL_LENGTH, "equal_length"},
        {CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_EQUAL_RADIUS, "equal_radius"},
        {CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_MIDPOINT, "midpoint"},
        {CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_SYMMETRIC, "symmetric"},
        {CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_FIX, "fix"},
        {CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_DISTANCE, "distance"},
        {CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_POINT_LINE_DISTANCE, "point_line_distance"},
        {CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_LINE_DISTANCE, "line_distance"},
        {CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_CIRCLE_LINE_DISTANCE, "circle_line_distance"},
        {CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_CIRCLE_DISTANCE, "circle_distance"},
        {CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_HORIZONTAL_DISTANCE, "horizontal_distance"},
        {CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_VERTICAL_DISTANCE, "vertical_distance"},
        {CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_LENGTH, "length"},
        {CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_ANGLE, "angle"},
        {CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_RADIUS, "radius"},
        {CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_DIAMETER, "diameter"},
    };
    for (const std::pair<std::uint32_t, const char*>& entry : header_codes) {
        check(entry.first < 27 && std::string(bs::detail::SKETCH_CONSTRAINT_KINDS[entry.first]) == entry.second,
              std::string("the wrapper's table puts ") + entry.second + " at the header's code");
    }

    bs::Sketch s = fresh();
    Bench w{s};
    typedef std::optional<double> Val;
    w.place();
    {
        Ids r = {w.pt(0, 0), w.pt(1, 1)};
        w.read_back("coincident", r, take(s.coincident(r[0], r[1]), "coincident"), Val());
    }
    w.place();
    {
        Ids r = {w.pt(3, 2), w.line(0, 0, 10, 0)};
        w.read_back("point_on_line", r, take(s.point_on_line(r[0], r[1]), "point_on_line"), Val());
    }
    w.place();
    {
        Ids r = {w.pt(6, 1), w.circle(0, 0, 5)};
        w.read_back("point_on_circle", r, take(s.point_on_circle(r[0], r[1]), "point_on_circle"), Val());
    }
    w.place();
    {
        Ids r = {w.pt(0, 0), w.pt(5, 1)};
        w.read_back("horizontal", r, take(s.horizontal(r[0], r[1]), "horizontal"), Val());
        check(near(point_of(s, r[0])[1], point_of(s, r[1])[1], 1e-9), "horizontal levels the points");
    }
    w.place();
    {
        Ids r = {w.pt(0, 0), w.pt(1, 5)};
        w.read_back("vertical", r, take(s.vertical(r[0], r[1]), "vertical"), Val());
        check(near(point_of(s, r[0])[0], point_of(s, r[1])[0], 1e-9), "vertical stacks the points");
    }
    w.place();
    {
        Ids r = {w.line(0, 0, 10, 0), w.line(0, 5, 10, 7)};
        w.read_back("parallel", r, take(s.parallel(r[0], r[1]), "parallel"), Val());
    }
    w.place();
    {
        Ids r = {w.line(0, 0, 10, 0), w.line(3, 5, 4, 15)};
        w.read_back("perpendicular", r, take(s.perpendicular(r[0], r[1]), "perpendicular"), Val());
    }
    w.place();
    {
        Ids r = {w.line(0, 0, 10, 0), w.line(12, 1, 20, 2)};
        w.read_back("collinear", r, take(s.collinear(r[0], r[1]), "collinear"), Val());
    }
    w.place();
    {
        Ids r = {w.circle(0, 5, 3), w.line(-10, 0, 10, 0)};
        w.read_back("tangent", r, take(s.tangent(r[0], r[1]), "tangent"), Val());
    }
    w.place();
    {
        Ids r = {w.circle(0, 0, 3), w.circle(7, 0, 3)};
        w.read_back("tangent", r, take(s.tangent(r[0], r[1], "positive"), "tangent positive"), Val(), "positive");
    }
    w.place();
    {
        std::uint32_t ln = w.line(0, 0, 4, 0);
        std::uint32_t end = take(s.ends(ln), "ends")[1];
        std::uint32_t bez = take(s.add_bezier(end, {w.ox + 5, 0}, {w.ox + 6, 1}, {w.ox + 7, 1}), "add_bezier");
        Ids r = {bez, ln};
        std::uint32_t id = take(s.tangent_at_end(bez, ln, "end"), "tangent_at_end");
        w.read_back("tangent_at_end", r, id, Val());
        check(take(s.constraint_end(id), "constraint_end") == "end", "tangent_at_end reads back its end");
    }
    w.place();
    {
        Ids r = {w.circle(0, 0, 3), w.circle(1, 1, 5)};
        w.read_back("concentric", r, take(s.concentric(r[0], r[1]), "concentric"), Val());
    }
    w.place();
    {
        Ids r = {w.line(0, 0, 10, 0), w.line(0, 5, 7, 5)};
        w.read_back("equal_length", r, take(s.equal_length(r[0], r[1]), "equal_length"), Val());
    }
    w.place();
    {
        Ids r = {w.circle(0, 0, 3), w.circle(9, 0, 5)};
        w.read_back("equal_radius", r, take(s.equal_radius(r[0], r[1]), "equal_radius"), Val());
    }
    w.place();
    {
        Ids r = {w.pt(4, 1), w.line(0, 0, 10, 0)};
        w.read_back("midpoint", r, take(s.midpoint(r[0], r[1]), "midpoint"), Val());
    }
    w.place();
    {
        Ids r = {w.pt(-3, 2), w.pt(4, 3), w.line(0, 0, 0, 10)};
        w.read_back("symmetric", r, take(s.symmetric(r[0], r[1], r[2]), "symmetric"), Val());
    }
    w.place();
    {
        Ids r = {w.pt(2, 2)};
        w.read_back("fix", r, take(s.fix(r[0]), "fix"), Val());
    }
    w.place();
    {
        Ids r = {w.pt(0, 0), w.pt(5, 1)};
        w.read_back("distance", r, take(s.distance(r[0], r[1], 7), "distance"), Val(7.0));
    }
    w.place();
    {
        Ids r = {w.pt(3, 2), w.line(0, 0, 10, 0)};
        w.read_back("point_line_distance", r, take(s.point_line_distance(r[0], r[1], 3), "point_line_distance"), Val(3.0));
    }
    w.place();
    {
        Ids r = {w.line(0, 0, 10, 0), w.line(0, 5, 10, 5)};
        w.read_back("line_distance", r, take(s.line_distance(r[0], r[1], 4), "line_distance"), Val(4.0));
    }
    w.place();
    {
        Ids r = {w.circle(0, 10, 2), w.line(-10, 0, 10, 0)};
        w.read_back("circle_line_distance", r, take(s.circle_line_distance(r[0], r[1], 3), "circle_line_distance"),
                    Val(3.0));
    }
    w.place();
    {
        Ids r = {w.circle(0, 0, 2), w.circle(10, 0, 3)};
        w.read_back("circle_distance", r, take(s.circle_distance(r[0], r[1], 3), "circle_distance"), Val(3.0));
    }
    w.place();
    {
        Ids r = {w.pt(0, 0), w.pt(5, 1)};
        w.read_back("horizontal_distance", r, take(s.horizontal_distance(r[0], r[1], 6), "horizontal_distance"), Val(6.0));
        check(near(point_of(s, r[1])[0] - point_of(s, r[0])[0], 6, 1e-9), "horizontal_distance moves x");
    }
    w.place();
    {
        Ids r = {w.pt(0, 0), w.pt(5, 1)};
        w.read_back("vertical_distance", r, take(s.vertical_distance(r[0], r[1], 6), "vertical_distance"), Val(6.0));
        check(near(point_of(s, r[1])[1] - point_of(s, r[0])[1], 6, 1e-9), "vertical_distance moves y");
    }
    w.place();
    {
        Ids r = {w.line(0, 0, 10, 0)};
        w.read_back("length", r, take(s.length(r[0], 12), "length"), Val(12.0));
    }
    w.place();
    {
        Ids r = {w.line(0, 0, 10, 0), w.line(0, 5, 10, 7)};
        w.read_back("angle", r, take(s.angle(r[0], r[1], 0.5), "angle"), Val(0.5));
    }
    w.place();
    {
        Ids r = {w.circle(0, 0, 3)};
        std::uint32_t id = take(s.radius_of(r[0], 4), "radius_of");
        w.read_back("radius", r, id, Val(4.0));
        check(near(take(s.radius(r[0]), "radius"), 4, 1e-9), "radius_of sizes the circle");
    }
    w.place();
    {
        Ids r = {w.circle(0, 0, 3)};
        std::uint32_t id = take(s.diameter(r[0], 9), "diameter");
        w.read_back("diameter", r, id, Val(9.0));
        check(near(take(s.radius(r[0]), "radius"), 4.5, 1e-9), "diameter sizes the circle");
    }
    check(take(s.constraints(), "constraints").size() == 28, "28 constraints, none refused");
    std::uint32_t arc_centre = take(s.add_point(0, -30), "add_point");
    std::uint32_t arc_start = take(s.add_point(5, -30), "add_point");
    std::uint32_t arc_end = take(s.add_point(0, -25), "add_point");
    std::uint32_t arc = take(s.add_arc(arc_centre, arc_start, arc_end), "add_arc");
    std::uint32_t conic = take(s.add_conic(take(s.add_point(0, -60), "add_point"), {1, -58}, {3, -60}, 0.7), "add_conic");
    check(take(s.kind(arc), "kind") == "arc", "an arc is an arc");
    check(take(s.kind(conic), "kind") == "free_curve", "a conic is a free curve");
}

// The drag rule: ascending ids sent whatever order they were given in; a repeated id is refused.
static void drag_sends_ascending_ids_and_refuses_a_repeat() {
    typedef std::pair<std::uint32_t, Vec2> Move;
    std::vector<Move> given = {Move(40, Vec2{1, 2}), Move(7, Vec2{3, 4}), Move(1000, Vec2{5, 6}), Move(0, Vec2{7, 8})};
    Result<std::vector<Move>> ordered = bs::detail::sketch_drag_order(given);
    check(ordered.ok(), "four distinct ids are ordered");
    if (ordered.ok()) {
        Ids ids;
        for (const Move& m : ordered.value()) ids.push_back(m.first);
        check(ids == Ids({0, 7, 40, 1000}), "the ids are sent in ascending order");
        check(ordered.value()[1].second == Vec2({3, 4}), "a target stays with its id");
    }
    std::vector<Move> twice = {Move(5, Vec2{0, 0}), Move(2, Vec2{1, 1}), Move(5, Vec2{2, 2})};
    refused(bs::detail::sketch_drag_order(twice), Match::starts, "sketch_drag: point 5 given twice", "a repeated id");
    bs::Sketch s = fresh();
    bs::SketchRect rect = take(s.add_rect({0, 0}, {40, 30}), "add_rect");
    Ids none = refused(s.drag(twice), Match::starts, "sketch_drag: point 5 given twice", "drag with a repeat");
    check(none.empty(), "the repeat refusal carries no ids");
    std::vector<Move> three = {Move(rect.corners[2], Vec2{41, 31}), Move(rect.corners[0], Vec2{-1, -1}),
                               Move(rect.corners[1], Vec2{41, -1})};
    check(take(s.drag(three), "drag").converged(), "an out-of-order drag solves");
}

// The owner: moves, closes, and answers a closed sketch with the library's wording.
static void handle_closes_and_moves() {
    bs::Sketch s = fresh();
    take(s.add_point(1, 2), "add_point");
    bs::Sketch moved = std::move(s);
    check(s.closed() && !moved.closed(), "a move leaves the source closed and the target open");  // NOLINT
    refused(s.add_point(0, 0), Match::starts, "sketch: closed", "add_point on a moved-from sketch");
    refused(s.entities(), Match::starts, "sketch: closed", "entities on a moved-from sketch");
    refused(s.diagnose(), Match::starts, "sketch: closed", "diagnose on a moved-from sketch");
    refused(s.drag(std::vector<std::pair<std::uint32_t, Vec2>>()), Match::starts, "sketch: closed",
            "drag on a moved-from sketch");
    bs::Sketch other = fresh();
    refused(other.reference(s, 0), Match::starts, "sketch: closed", "reference of a closed sketch");
    refused(other.update_reference(0, s), Match::starts, "sketch: closed", "update_reference from a closed sketch");
    bs::Profile rect = take(bs::Profile::rect(2, 2), "Profile::rect");
    bs::Sketch built = take(bs::Sketch::from_profile(rect), "from_profile with the defaults");
    check(!take(built.entities(), "entities").empty(), "a rect profile makes entities");
    moved.close();
    check(moved.closed(), "close() closes");
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
        {"dimensions_a_plate_and_extrudes_it", dimensions_a_plate_and_extrudes_it},
        {"refuses_a_conflict_with_ids", refuses_a_conflict_with_ids},
        {"drag_moves_the_point_it_holds", drag_moves_the_point_it_holds},
        {"reference_follows_its_source", reference_follows_its_source},
        {"comes_from_a_profile_and_keeps_its_tangents", comes_from_a_profile_and_keeps_its_tangents},
        {"reads_back_what_it_holds", reads_back_what_it_holds},
        {"nurbs_and_finite", nurbs_and_finite},
        {"sense_sides_and_unknown_reads", sense_sides_and_unknown_reads},
        {"diagnosis_lists_name_redundant_and_conflicting", diagnosis_lists_name_redundant_and_conflicting},
        {"a_set_value_that_cannot_converge_is_refused_with_its_ids", a_set_value_that_cannot_converge_is_refused_with_its_ids},
        {"every_constraint_method_adds_its_kind", every_constraint_method_adds_its_kind},
        {"drag_sends_ascending_ids_and_refuses_a_repeat", drag_sends_ascending_ids_and_refuses_a_repeat},
        {"handle_closes_and_moves", handle_closes_and_moves},
        {"error_is_an_aggregate", error_is_an_aggregate},
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
    std::printf("sketch: ok\n");
    return 0;
}
