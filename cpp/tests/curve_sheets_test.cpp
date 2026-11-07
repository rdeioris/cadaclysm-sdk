// Sheets from curves -- loft_curves, sweep_rail, sweep_two_rails, edge_surface, network_surface,
// continuity, matched, blend_sides, n_sided_patch, fillet_surfaces, the varying-radius fillet,
// split_by_curve, trim_by_curve, join_sheets, flange and extrude_to, with the Continuity,
// PatchReport and JoinReport records -- at parity with the Python reference's tests of the same names in
// test_cadaclysm_blacksmith.py. The kernel's own correctness is the kernel's tests' job. Needs the
// kernel library and a license; the exit code is the verdict.
//
//     cadaclysm_curve_sheets_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <optional>
#include <string>
#include <utility>
#include <vector>

using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;
using bs::Continuity;
using bs::Frame;
using bs::JoinedSheets;
using bs::NurbsCurve;
using bs::PatchBoundary;
using bs::Profile;
using bs::Recessed;
using bs::Solid;
using bs::Solids;
using bs::SurfaceFillet;
using bs::Vec3;

static int failures = 0;
static const double PI = 3.14159265358979323846;

static void check(bool ok, const std::string& what) {
    if (ok) return;
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
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

// A refusal check that fails when nothing was refused: the call must have returned an error
// whose text starts with `prefix` and, if given, contains `inside`.
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

static std::string num(double v) { return std::to_string(v); }

static NurbsCurve line(const Vec3& a, const Vec3& b) { return must(NurbsCurve::make({a, b}, 1), "line"); }

// The curves as a vector, moved in.
template <class... C>
static std::vector<NurbsCurve> many(C... curves) {
    std::vector<NurbsCurve> out;
    out.reserve(sizeof...(curves));
    (out.push_back(std::move(curves)), ...);
    return out;
}

static double area_of(const Solid& s) { return must(s.mass(), "mass").area; }

static Vec3 cross(const Vec3& a, const Vec3& b) {
    return {a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]};
}

// A `w` by `h` rectangle centred at `origin` in the plane of `x`, `y`, facing `x cross y`.
static Solid rect_sheet(const Vec3& origin, const Vec3& x, const Vec3& y, double w, double h) {
    Frame frame = must(Frame::make(origin, x, y, cross(x, y)), "frame");
    return must(Solid::face(must(Profile::rect(w, h), "rect"), frame), "rect sheet");
}

// The circle of radius `r` about `centre` in its z plane: nine rational quadratic points.
static NurbsCurve exact_circle(const Vec3& centre, double r) {
    double h = std::sqrt(0.5);
    const double ab[9][2] = {{1, 0}, {1, 1}, {0, 1}, {-1, 1}, {-1, 0}, {-1, -1}, {0, -1}, {1, -1}, {1, 0}};
    std::vector<Vec3> points;
    for (int i = 0; i < 9; ++i) points.push_back({centre[0] + r * ab[i][0], centre[1] + r * ab[i][1], centre[2]});
    return must(NurbsCurve::make(points, 2, std::vector<double>{1, h, 1, h, 1, h, 1, h, 1},
                                 std::vector<double>{0, 0, 0, 0.25, 0.25, 0.5, 0.5, 0.75, 0.75, 1, 1, 1}),
                "exact circle");
}

static double first_point(const NurbsCurve& c, int axis) {
    std::pair<double, double> d = must(c.domain(), "domain");
    return must(c.point(d.first), "point")[static_cast<std::size_t>(axis)];
}

// 1: surfaces_from_curves_are_sheets
static Result<void> surfaces_from_curves_are_sheets() {
    std::vector<Vec3> c = {{-1, -1, 1}, {1, -1, -1}, {1, 1, 1}, {-1, 1, -1}};
    Solid coons = must(Solid::edge_surface(many(line(c[0], c[1]), line(c[1], c[2]), line(c[2], c[3]), line(c[3], c[0])), 1e-9), "coons");
    check(coons.faces() == 1 && coons.sheet_error() && *coons.sheet_error() == 0.0, "edge_surface: one face, sheet_error 0");
    Solid loft = must(Solid::loft_curves(many(line({0, 0, 0}, {2, 0, 0}), line({0, 1, 1}, {2, 1, -1}))), "loft");
    check(loft.faces() == 1 && !loft.sheet_error(), "loft_curves: one face, no sheet_error");
    check(!loft.patch_report(), "loft_curves: no patch_report");
    std::vector<Vec3> ring;
    for (int i = 0; i < 8; ++i) {
        double t = 2 * PI * i / 8;
        ring.push_back({std::cos(t), std::sin(t), 0});
    }
    NurbsCurve circle = must(NurbsCurve::through(ring, 3, true), "circle");
    NurbsCurve rail = line({0, 0, 0}, {0, 0, 4});
    Solid tube = must(Solid::sweep_rail(rail, many(circle), "rmf", std::nullopt, 1e-5), "sweep_rail");
    check(tube.faces() == 1 && tube.sheet_error() && *tube.sheet_error() >= 0 && *tube.sheet_error() <= 1e-5,
          "sweep_rail: one face, sheet_error within the tolerance");
    Solid upright = must(Solid::sweep_rail(rail, many(circle), "fixed", Vec3{0, 1, 0}, 1e-5), "sweep_rail fixed");
    check(upright.faces() == 1, "sweep_rail fixed: one face");
    Solid band = must(Solid::sweep_two_rails(line({-1, 0, 0}, {-1, 5, 0}), line({1, 0, 0}, {1, 5, 0}), many(line({-1, 0, 0}, {1, 0, 0})), 1e-6),
                      "sweep_two_rails");
    check(band.faces() == 1 && band.sheet_error().has_value(), "sweep_two_rails: one face, sheet_error set");
    std::vector<NurbsCurve> us, vs;
    for (double y : {-1.0, 0.2, 1.0}) us.push_back(line({-1, y, -y}, {1, y, y}));
    for (double x : {-1.0, 0.3, 1.0}) vs.push_back(line({x, -1, -x}, {x, 1, x}));
    Solid net = must(Solid::network_surface(us, vs, 1e-9), "network_surface");
    check(net.faces() == 1 && net.sheet_error() && *net.sheet_error() <= 1e-9, "network_surface: one face, sheet_error within the tolerance");
    // the sheet_error stays through a move
    Solid moved = std::move(net);
    check(moved.sheet_error().has_value(), "sheet_error survives a move");
    // On a rail that bends out of its first plane the rotation-minimising frame and the upright one part.
    NurbsCurve bent = must(NurbsCurve::through({{0, 0, 0}, {0, 1, 2}, {2, 2, 3}, {4, 2, 3.5}}, 3), "bent rail");
    Solid rmf = must(Solid::sweep_rail(bent, many(line({-1, 0, 0}, {1, 0, 0})), "rmf", std::nullopt, 1e-4), "rmf");
    Solid fixed = must(Solid::sweep_rail(bent, many(line({-1, 0, 0}, {1, 0, 0})), "fixed", Vec3{0, 0, 1}, 1e-4), "fixed");
    check(std::fabs(area_of(rmf) - area_of(fixed)) > 0.1, "rmf and fixed part on a bent rail: " + num(area_of(rmf)) + " vs " + num(area_of(fixed)));
    refused(Solid::loft_curves(many(circle)), "loft_curves: ", "", "loft of one section");
    refused(Solid::edge_surface(many(line({0, 0, 0}, {1, 0, 0}))), "edge_surface: ", "", "edge_surface of one curve");
    refused(Solid::network_surface(many(line({0, 0, 0}, {1, 0, 0})), many(line({0, 0, 0}, {0, 1, 0}))), "network_surface: ", "",
            "network_surface of one pair");
    refused(Solid::sweep_rail(rail, many(circle), "twisty"), "sweep_rail: frame is 'rmf' or 'fixed', not 'twisty'", "", "sweep_rail frame");
    refused(Solid::loft_curves({}), "loft_curves: ", "", "loft of no sections");
    return {};
}

// 2: a_curve_trims_a_hole_and_an_island_and_they_join_back
static Result<void> a_curve_trims_a_hole_and_an_island_and_they_join_back() {
    Solid sheet = rect_sheet({0, 0, 0}, {1, 0, 0}, {0, 1, 0}, 20, 20);
    NurbsCurve ring = exact_circle({1, -2, 0}, 5);
    Solid holed = must(sheet.trim_by_curve(ring, "outside", Vec3{0, 0, -1}, 0.01), "hole");
    Solid island = must(sheet.trim_by_curve(ring, "inside", std::nullopt, 0.01), "island");
    check(std::fabs(area_of(island) - 25 * PI) < 1e-6, "island area " + num(area_of(island)));
    check(std::fabs(area_of(holed) - (400 - 25 * PI)) < 1e-6, "holed area " + num(area_of(holed)));
    Solid split = must(sheet.split_by_curve(ring, std::nullopt, 0.01), "split");
    check(split.faces() == 2, "split_by_curve: two faces");
    JoinedSheets back = must(Solid::join_sheets(Solids{holed, island}), "join back");
    const bs::JoinReport& r = back.report;
    check(r.sewn >= 1 && r.naked_after == r.naked_before - 2 * r.sewn && !r.closed, "join back: report");
    check(back.solid.faces() == 2, "join back: two faces");
    check(!holed.sheet_error() && !holed.patch_report(), "trim_by_curve: no sheet_error, no patch_report");
    return {};
}

// 3: an_open_curve_keeps_its_left_or_right
static Result<void> an_open_curve_keeps_its_left_or_right() {
    Solid sheet = rect_sheet({0, 0, 0}, {1, 0, 0}, {0, 1, 0}, 20, 20);
    NurbsCurve open = must(NurbsCurve::through({{-5, 1, 0}, {5, 1, 0}}, 1), "open curve");
    Solid left = must(sheet.trim_by_curve(open, "left", Vec3{0, 0, 1}, 0.01), "left");
    Solid right = must(sheet.trim_by_curve(open, "right", Vec3{0, 0, 1}, 0.01), "right");
    check(std::fabs(area_of(left) - 180) < 1e-9 && std::fabs(area_of(right) - 220) < 1e-9,
          "left " + num(area_of(left)) + ", right " + num(area_of(right)));
    Solid inside = must(sheet.trim_by_curve(open, "inside", Vec3{0, 0, -1}, 0.01), "inside");
    check(std::fabs(area_of(inside) - 220) < 1e-9, "inside, direction down, is the right side: " + num(area_of(inside)));
    Solid outside = must(sheet.trim_by_curve(open, "outside", Vec3{0, 0, 1}, 0.01), "outside");
    check(std::fabs(area_of(outside) - 220) < 1e-9, "outside is the right side: " + num(area_of(outside)));
    return {};
}

// 4: six_sheets_join_into_a_box_the_kernel_measures_cuts_and_writes
static Result<void> six_sheets_join_into_a_box() {
    Vec3 x = {1, 0, 0}, y = {0, 1, 0}, z = {0, 0, 1};
    std::vector<Solid> faces;
    faces.push_back(rect_sheet({5, 10, 0}, x, y, 10, 20));
    faces.push_back(rect_sheet({5, 10, 30}, x, y, 10, 20));
    faces.push_back(rect_sheet({0, 10, 15}, y, z, 20, 30));
    faces.push_back(rect_sheet({10, 10, 15}, y, z, 20, 30));
    faces.push_back(rect_sheet({5, 0, 15}, z, x, 30, 10));
    faces.push_back(rect_sheet({5, 20, 15}, x, z, 10, 30));
    Solids all;
    for (const Solid& f : faces) all.push_back(f);
    JoinedSheets joined = must(Solid::join_sheets(all), "join the box");
    const bs::JoinReport& r = joined.report;
    check(r.sewn == 12 && r.naked_before == 24 && r.naked_after == 0 && r.turned == 4 && r.closed,
          "box report: sewn " + std::to_string(r.sewn) + ", naked " + std::to_string(r.naked_before) + " -> " +
              std::to_string(r.naked_after) + ", turned " + std::to_string(r.turned));
    Solid& box = joined.solid;
    bs::Mass m = must(box.mass(), "mass");
    check(m.closed && std::fabs(m.volume - 6000) < 1e-6, "box volume " + num(m.volume));
    Solid drill = must(must(Solid::cylinder(2, 50), "cylinder").translate(5, 10, -10), "translate");
    Solid bored = must(box.cut(drill, 0.01), "cut");
    check(std::fabs(must(bored.mass(), "bored mass").volume - (6000 - PI * 4 * 30)) < 0.05, "bored volume");
    std::string step = must(box.step_text(), "step_text");
    check(step.find("CLOSED_SHELL") != std::string::npos, "the box writes a CLOSED_SHELL");
    // Two of the faces, one moved a thousandth away: sewn only at a tolerance that covers it.
    Solid moved = must(faces[3].translate(0, 0, 1e-3), "moved");
    JoinedSheets apart = must(Solid::join_sheets(Solids{faces[1], moved}), "apart");
    JoinedSheets loose = must(Solid::join_sheets(Solids{faces[1], moved}, 2e-3), "loose");
    check(apart.report.sewn == 0 && loose.report.sewn == 1 && std::fabs(loose.report.worst_gap - 1e-3) < 1e-9,
          "a thousandth apart: sewn only at 2e-3, worst_gap " + num(loose.report.worst_gap));
    return {};
}

static Solid rect_of_lines(double x0, double y0, double x1, double y1) {
    std::vector<Vec3> c = {{x0, y0, 0}, {x1, y0, 0}, {x1, y1, 0}, {x0, y1, 0}};
    return must(Solid::edge_surface(many(line(c[0], c[1]), line(c[1], c[2]), line(c[2], c[3]), line(c[3], c[0]))), "rect of lines");
}

// 5: join_sheets_sews_a_t_junction
static Result<void> join_sheets_sews_a_t_junction() {
    // Two unit squares on a 2 x 1 rectangle's long edge: it is cut where they meet on it.
    Solid big = rect_of_lines(0, 0, 2, 1), a = rect_of_lines(0, 1, 1, 2), b = rect_of_lines(1, 1, 2, 2);
    JoinedSheets exact = must(Solid::join_sheets(Solids{big, a, b}), "exact");
    check(exact.report.sewn == 1, "exact: one edge sewn");
    JoinedSheets shell = must(Solid::join_sheets(Solids{big, a, b}, 1e-3), "t junction");
    const bs::JoinReport& r = shell.report;
    check(r.sewn == 3 && r.naked_before == 13 && r.naked_after == 7 && !r.closed,
          "t junction report: sewn " + std::to_string(r.sewn) + ", naked " + std::to_string(r.naked_before) + " -> " +
              std::to_string(r.naked_after));
    check(shell.solid.faces() == 3, "t junction: three faces");
    return {};
}

// 6: trim_by_curve_and_join_refuse_by_name
static Result<void> trim_by_curve_and_join_refuse_by_name() {
    Solid sheet = rect_sheet({0, 0, 0}, {1, 0, 0}, {0, 1, 0}, 20, 20);
    NurbsCurve ring = exact_circle({0, 0, 0}, 5);
    refused(sheet.trim_by_curve(ring, "middle"), "trim_by_curve: keep must be 'outside', 'inside', 'left' or 'right', not 'middle'", "",
            "trim keep");
    refused(sheet.trim_by_curve(exact_circle({100, 0, 0}, 5), "inside"), "trim_by_curve: ", "nothing of the sheet lies inside",
            "trim nothing inside");
    refused(sheet.split_by_curve(ring, Vec3{0, 0, 0}), "split_by_curve: ", "direction is zero", "split zero direction");
    refused(Solid::join_sheets(Solids{}), "join_sheets: no sheets", "", "join none");
    refused(Solid::join_sheets(Solids{sheet}, -1.0), "join_sheets: ", "tolerance", "join negative tolerance");
    return {};
}

// 6b: a square window recessed into a flat sheet
static Result<void> recess_sets_a_square_window_into_a_flat_sheet() {
    Solid sheet = rect_sheet({0, 0, 0}, {1, 0, 0}, {0, 1, 0}, 20, 20);
    NurbsCurve square = must(NurbsCurve::through({{-5, -5, 0}, {5, -5, 0}, {5, 5, 0}, {-5, 5, 0}, {-5, -5, 0}}, 1), "square");
    Recessed r = must(sheet.recess(square, 3, 0, 0, true, 0.01), "recess");
    check(r.sheet == 1 && r.fillet == 0 && r.walls == 4 && r.pane == 1 && r.solid.faces() == 6,
          "recess: faces " + std::to_string(r.sheet) + "/" + std::to_string(r.fillet) + "/" + std::to_string(r.walls) + "/" +
              std::to_string(r.pane) + ", " + std::to_string(r.solid.faces()) + " in all");
    return {};
}

// 7: continuity_match_and_blend
static Result<void> continuity_match_and_blend() {
    Solid a = must(Solid::loft_curves(many(line({-1, 0, 0}, {0, 0, 0}), line({-1, 1, 0}, {0, 1, 0})), 1), "a");
    Solid b = must(Solid::loft_curves(many(line({0, 0, 0}, {0, 0, 1}), line({0, 1, 0}, {0, 1, 1})), 1), "b");
    Continuity r = must(a.continuity("u1", b, "u0", 0, 0, 32), "continuity");
    check(r.gap <= 1e-12 && std::fabs(r.angle - PI / 2) <= 1e-9 && r.samples >= 33, "a meets b square: angle " + num(r.angle));
    Solid m = must(a.matched("u1", b, "u0", 1), "matched");
    r = must(m.continuity("u1", b, "u0"), "matched continuity");
    check(r.gap <= 1e-10 && r.angle <= 1e-8, "matched at G1: gap " + num(r.gap) + ", angle " + num(r.angle));
    Solid blend = must(Solid::blend_sides(a, "u0", b, "u1", 2), "blend_sides");
    r = must(blend.continuity("v0", a, "u0"), "blend continuity");
    check(r.gap <= 1e-10 && r.angle <= 1e-8 && r.curvature <= 1e-6, "blend at G2: " + num(r.gap) + ", " + num(r.angle) + ", " + num(r.curvature));
    refused(a.continuity("w2", b, "u0"), "a side is 'u0', 'u1', 'v0' or 'v1', not 'w2'", "", "continuity side");
    refused(a.matched("u1", b, "u0", 3), "match_side: ", "", "match_side level 3");
    return {};
}

// 8: n_sided_patch_fills_a_pentagon_of_strips
static Result<void> n_sided_patch_fills_a_pentagon_of_strips() {
    // Five flat strips round a pentagon in z = 0, each lofted from a side outward: the hole's
    // side is each loft's "v0". Given every way the wrapper takes a boundary.
    std::vector<Vec3> corners;
    for (int k = 0; k < 5; ++k) {
        double a = 2 * PI * k / 5 + 0.1 * std::sin(3.0 * k);
        corners.push_back({std::cos(a), std::sin(a), 0.0});
    }
    std::vector<Vec3> outer;
    for (const Vec3& p : corners) outer.push_back({1.6 * p[0], 1.6 * p[1], 0.0});
    std::vector<Solid> strips;
    for (std::size_t i = 0; i < 5; ++i) {
        std::size_t j = (i + 1) % 5;
        strips.push_back(must(Solid::loft_curves(many(line(corners[i], corners[j]), line(outer[i], outer[j])), 1), "strip"));
    }
    NurbsCurve edge = line(corners[3], corners[4]);
    std::vector<PatchBoundary> boundaries = {PatchBoundary(strips[0], "v0"), PatchBoundary(strips[1], "v0", 1),
                                             PatchBoundary(strips[2], "v0", 2, 0, 1.0, 0.0), PatchBoundary(edge),
                                             PatchBoundary(strips[4], "v0", 2, 0)};
    Solid fill = must(Solid::n_sided_patch(boundaries, 1.0, 1e-6), "n_sided_patch");
    check(fill.patch_report().has_value() && !fill.sheet_error(), "the patch has a patch_report and no sheet_error");
    if (!fill.patch_report()) return {};
    const bs::PatchReport& r = *fill.patch_report();
    check(fill.faces() == 5 && r.faces == 5, "pentagon patch faces " + std::to_string(r.faces));
    check(r.boundary.gap <= 1e-9 && r.boundary.angle <= 1e-6 && r.internal.angle <= 1e-6 && r.corner_angle <= 1e-9,
          "patch report: gap " + num(r.boundary.gap) + ", angle " + num(r.boundary.angle) + ", internal " + num(r.internal.angle) +
              ", corner " + num(r.corner_angle));
    // Face 0 meets strip 0's second half along its v0 side, face 4 the first half along u1.
    const std::pair<std::uint32_t, const char*> sides[2] = {{0, "v0"}, {4, "u1"}};
    for (const std::pair<std::uint32_t, const char*>& fs : sides) {
        Continuity k = must(fill.continuity(fs.second, strips[0], "v0", fs.first), "patch continuity");
        check(k.gap <= 1e-9 && k.angle <= 1e-6, "patch face " + std::to_string(fs.first) + " meets strip 0: gap " + num(k.gap) + ", angle " + num(k.angle));
    }
    // Into the ring: watertight round the hole but where the curve stood in for strip 3.
    JoinedSheets joined = must(Solid::join_sheets(Solids{strips[0], strips[1], strips[2], strips[4], fill}, 1e-6), "ring");
    check(joined.report.refused == 0 && joined.report.naked_after == 4 + 2 + 2,
          "ring: refused " + std::to_string(joined.report.refused) + ", naked_after " + std::to_string(joined.report.naked_after));
    // Every boundary a sheet's side: the curve's place taken by strip 3, the same five faces.
    std::vector<PatchBoundary> whole;
    for (const Solid& s : strips) whole.push_back(PatchBoundary(s, "v0"));
    Solid all = must(Solid::n_sided_patch(whole, 1.0, 1e-6), "whole");
    check(all.faces() == 5 && all.patch_report() && all.patch_report()->boundary.angle <= 1e-6, "patch of five sheet sides");
    check(r.boundary.samples > 0 && r.internal.samples > 0, "the reports carry their samples");
    // A level is honoured: strips rising off the hole's plane are met with a kink at G0, tangent at G1.
    std::vector<Solid> raised;
    for (std::size_t i = 0; i < 5; ++i) {
        std::size_t j = (i + 1) % 5;
        raised.push_back(must(Solid::loft_curves(many(line(corners[i], corners[j]), line({outer[i][0], outer[i][1], 0.8}, {outer[j][0], outer[j][1], 0.8})), 1),
                              "raised strip"));
    }
    double cap_area[2] = {0.0, 0.0};
    const std::uint32_t levels[2] = {0, 1};
    for (int k = 0; k < 2; ++k) {
        std::vector<PatchBoundary> ring;
        for (const Solid& s : raised) ring.push_back(PatchBoundary(s, "v0", levels[k]));
        Solid cap = must(Solid::n_sided_patch(ring, 1.0, 1e-6), "raised patch");
        cap_area[k] = area_of(cap);
    }
    check(cap_area[1] - cap_area[0] > 0.1, "G0 leaves the cap flat (" + num(cap_area[0]) + "), G1 lifts it with the strips (" + num(cap_area[1]) + ")");
    refused(Solid::n_sided_patch(std::vector<PatchBoundary>(boundaries.begin(), boundaries.begin() + 2)), "n_sided_patch: ", "",
            "two boundaries");
    refused(Solid::n_sided_patch({PatchBoundary(strips[0], "x0"), PatchBoundary(strips[1], "v0"), PatchBoundary(strips[2], "v0")}),
            "a side is 'u0', 'u1', 'v0' or 'v1', not 'x0'", "", "patch side");
    refused(Solid::n_sided_patch({PatchBoundary(strips[0], "v0", 3), PatchBoundary(strips[1], "v0", 3), PatchBoundary(strips[2], "v0", 3)}),
            "n_sided_patch: ", "", "patch level 3");
    return {};
}

// 9: fillet_surfaces_rolls_a_ball_between_two_sheets
static Result<void> fillet_surfaces_rolls_a_ball_between_two_sheets() {
    std::optional<NurbsCurve> rail_a, rail_b;
    double error = -1.0;
    std::size_t sheet_faces = 0;
    {
        Solid floor = must(Solid::loft_curves(many(line({0, 0, 0}, {4, 0, 0}), line({0, 3, 0}, {4, 3, 0})), 1), "floor");
        Solid wall = must(Solid::loft_curves(many(line({0, 0, 0}, {0, 3, 0}), line({0, 0, 4}, {0, 3, 4})), 1), "wall");
        bool found = false;
        const bool flips[4][2] = {{false, false}, {true, false}, {false, true}, {true, true}};
        for (int i = 0; i < 4; ++i) {
            const bool* f = flips[i];
            Result<SurfaceFillet> got = Solid::fillet_surfaces(floor, wall, 1.0, std::nullopt, f[0], f[1], 1e-4);
            if (!got) continue;
            SurfaceFillet fil = std::move(got).value();
            double px = first_point(fil.rail_a, 0);
            double pz = first_point(fil.rail_a, 2);
            if (px > 0 && std::fabs(pz) <= 1e-9) {
                found = true;
                check(fil.sheet.sheet_error().has_value(), "fillet_surfaces: sheet_error set");
                error = fil.sheet.sheet_error().value_or(-1.0);
                sheet_faces = fil.sheet.faces();
                rail_a = std::move(fil.rail_a);
                rail_b = std::move(fil.rail_b);
                break;
            }
        }
        check(found, "a flip choice rolls the ball inside the corner");
        refused(Solid::fillet_surfaces(floor, wall, 0.0), "fillet_surfaces: ", "", "fillet_surfaces radius 0");
    }
    // The two sheets are gone; the rails are the caller's.
    if (!rail_a || !rail_b) return {};
    check(sheet_faces == 1 && error >= 0 && error <= 1e-4, "fillet sheet: one face, error " + num(error));
    check(std::fabs(first_point(*rail_a, 0) - 1.0) <= 1e-4, "rail on the floor starts at x = 1");
    check(std::fabs(first_point(*rail_b, 2) - 1.0) <= 1e-4, "rail on the wall starts at z = 1");
    return {};
}

// Two bicubic patches -- a fender's top and a door's side -- sharing the crease row, joined.
static Solid fender_and_door() {
    double length = 400.0;
    std::vector<NurbsCurve> a_rows, b_rows;
    const double ys[4] = {0.0, length / 3, 2 * length / 3, length};
    for (double y : ys) {
        double s = std::sin(PI * y / length);
        Vec3 c = {150.0 + 8.0 * s, y, 6.0 * s};
        a_rows.push_back(must(NurbsCurve::make({{0.0, y, 10.0}, {50.0, y, 14.0}, {100.0, y, 12.0}, c}, 3), "a row"));
        b_rows.push_back(must(NurbsCurve::make({c, {c[0] + 14, y, c[2] - 60}, {c[0] + 10, y, c[2] - 130}, {c[0] - 4, y, c[2] - 200}}, 3), "b row"));
    }
    Solid a = must(Solid::loft_curves(a_rows, 3, true), "fender");
    Solid b = must(Solid::loft_curves(b_rows, 3, true), "door");
    JoinedSheets joined = must(Solid::join_sheets(Solids{a, b}, 1e-6), "fender and door");
    check(joined.report.sewn == 1, "fender and door: one crease sewn");
    return std::move(joined.solid);
}

// 10: fillet_rounds_a_spline_edge_at_a_constant_and_a_varying_radius
static Result<void> fillet_rounds_a_spline_edge_at_a_constant_and_a_varying_radius() {
    Solid shell = fender_and_door();
    std::vector<std::uint32_t> crease;
    std::string kind;
    for (const bs::Edge& e : must(shell.edges(), "edges")) {
        if (e.faces.size() == 2) {
            crease.push_back(e.index);
            kind = e.kind;
        }
    }
    check(crease.size() == 1 && kind == "nurbs", "one nurbs crease");
    Solid constant = must(shell.fillet(crease, 12.0, 1e-3), "constant");
    Solid varying = must(shell.fillet(crease, 8.0, 1e-3, {}, 20.0), "varying");
    check(constant.faces() == 3 && varying.faces() == 3, "both fillets add a face");
    double sharp = must(shell.mass(1e-6), "mass").area, c = must(constant.mass(1e-6), "mass").area, v = must(varying.mass(1e-6), "mass").area;
    check(v < c && c < sharp, "areas: varying " + num(v) + " < constant " + num(c) + " < sharp " + num(sharp));
    // radius_end equal to the radius is the constant fillet.
    Solid same = must(shell.fillet(crease, 12.0, 1e-3, {}, 12.0), "radius_end = radius");
    check(std::fabs(must(same.mass(1e-6), "mass").area - c) < 1e-6, "radius_end equal to radius is the constant fillet");
    refused(must(Solid::cuboid(10, 10, 10), "cuboid").fillet({0}, 1.0, 1e-6, {}, 2.0), "", "a varying radius rounds only spline edges",
            "varying radius on a box");
    return {};
}

// 11: the sheet_error / patch_report fields and the rest of the wrapper-side refusals
static Result<void> sheet_error_and_patch_report_are_set_where_made() {
    Solid box = must(Solid::cuboid(1, 1, 1), "cuboid");
    check(!box.sheet_error() && !box.patch_report(), "a plain solid has neither");
    Solid copy = must(box.translate(1, 0, 0), "translate");
    check(!copy.sheet_error() && !copy.patch_report(), "a transformed solid has neither");
    Solid net = must(Solid::edge_surface(many(line({0, 0, 0}, {1, 0, 0}), line({1, 0, 0}, {1, 1, 0}), line({1, 1, 0}, {0, 1, 0}),
                                            line({0, 1, 0}, {0, 0, 0}))),
                     "edge_surface");
    check(net.sheet_error().has_value() && !net.patch_report(), "edge_surface sets sheet_error only");
    Solid plain = must(Solid::loft_curves(many(line({0, 0, 0}, {1, 0, 0}), line({0, 1, 0}, {1, 1, 0}))), "loft");
    check(!plain.sheet_error(), "loft_curves leaves sheet_error unset");
    // A closed solid refuses a sheet verb by name, not by crashing.
    refused(box.continuity("u0", box, "u0"), "continuity: ", "", "continuity of a box");
    refused(plain.trim_by_curve(line({0, 0, 0}, {1, 0, 0}), "sideways"), "trim_by_curve: keep must be", "", "keep sideways");
    return {};
}

// 12: continuity reports where the worst gap and the worst angle are, each its own point
static Result<void> continuity_says_where() {
    Solid a = must(Solid::loft_curves(many(line({-1, 0, 0}, {0, 0, 0}), line({-1, 1, 0}, {0, 1, 0})), 1), "a");
    // b leaves a's edge at one end and drifts 0.3 off it at the other.
    Solid b = must(Solid::loft_curves(many(line({0, 0, 0}, {0, 0, 1}), line({0, 1, 0.3}, {0, 1, 1.3})), 1), "b");
    Continuity r = must(a.continuity("u1", b, "u0", 0, 0, 33), "continuity");
    // The sides run (0, y, 0) for y in 0..1: the gap grows with y, the angle is the same all along.
    check(std::fabs(r.gap - 0.3) < 0.02 && std::fabs(r.gap_at[0]) < 1e-9 && std::fabs(r.gap_at[1] - 1.0) < 1e-9 && std::fabs(r.gap_at[2]) < 1e-9,
          "the worst gap is at the far end: " + num(r.gap) + " at y = " + num(r.gap_at[1]));
    check(std::fabs(r.angle - PI / 2) < 1e-9 && std::fabs(r.angle_at[1]) < 1e-9,
          "the first sample holds the worst angle: " + num(r.angle) + " at y = " + num(r.angle_at[1]));
    check(r.curvature <= 1e-9 && r.samples >= 33, "two planes differ in no curvature");
    return {};
}

// Every segment start of `e` within `tol` of the circle of radius 5 about (1, -2) (and, with
// `flat`, in z = 0).
static bool on_hole_circle(const bs::Edge& e, double tol, bool flat) {
    for (const std::array<Vec3, 2>& seg : e.segments) {
        const Vec3& a = seg[0];
        if (std::fabs(std::hypot(a[0] - 1, a[1] + 2) - 5) >= tol) return false;
        if (flat && std::fabs(a[2]) >= 1e-6) return false;
    }
    return true;
}

// The 20 x 20 square in z = 0 facing +z with a round hole of radius 5 about (1, -2), and the
// hole's rim edges.
static std::pair<Solid, std::vector<std::uint32_t>> holed_sheet() {
    Solid sheet = rect_sheet({0, 0, 0}, {1, 0, 0}, {0, 1, 0}, 20, 20);
    Solid holed = must(sheet.trim_by_curve(exact_circle({1, -2, 0}, 5), "outside", Vec3{0, 0, -1}, 0.01), "hole");
    std::vector<std::uint32_t> rim;
    for (const bs::Edge& e : must(holed.edges(), "edges")) {
        if (e.faces.size() == 1 && on_hole_circle(e, 1e-6, false)) rim.push_back(e.index);
    }
    if (rim.empty()) {
        std::fprintf(stderr, "FAIL: holed sheet: no rim edges\n");
        std::exit(1);
    }
    return {std::move(holed), std::move(rim)};
}

// 13: a_flange_turns_a_hole_under_and_carries_it_inward
static Result<void> a_flange_turns_a_hole_under_and_carries_it_inward() {
    std::pair<Solid, std::vector<std::uint32_t>> h = holed_sheet();
    const Solid& holed = h.first;
    const std::vector<std::uint32_t>& rim = h.second;
    NurbsCurve under = line({0, 0, 0}, {0, -3, 0});
    // Turned under 3 along the face's normal (+z): the hole's own cylinder, 3 deep, below the sheet.
    Solid wall = must(holed.flange(rim, under, 1e-3, false), "flange under");
    check(wall.faces() == rim.size() && wall.sheet_error().has_value() && *wall.sheet_error() <= 1e-3,
          "flange: one face per rim edge, sheet_error within the tolerance");
    check(std::fabs(area_of(wall) - 2 * PI * 5 * 3) < 0.05, "flange area " + num(area_of(wall)));
    std::pair<Vec3, Vec3> b = must(wall.bounds(), "bounds");
    check(std::fabs(b.first[2] + 3) < 1e-3 && std::fabs(b.second[2]) < 1e-3 && std::fabs(b.first[0] - (1 - 5)) < 1e-2 &&
              std::fabs(b.second[0] - (1 + 5)) < 1e-2,
          "flange bounds");
    // Carried on outward from the face 2: into the hole, an annulus from radius 5 in to 3.
    Solid ring = must(holed.flange(rim, line({0, 0, 0}, {2, 0, 0}), 1e-3, false), "flange on");
    check(std::fabs(area_of(ring) - PI * (25 - 9)) < 0.05, "annulus area " + num(area_of(ring)));
    // Joined, the sheet's faces come first and the flange is sewn on.
    Solid joined = must(holed.flange(rim, under), "flange joined");
    check(joined.faces() == holed.faces() + rim.size(), "joined: the sheet's faces and one per rim edge");
    check(std::fabs(area_of(joined) - (area_of(holed) + 2 * PI * 5 * 3)) < 0.05, "joined area " + num(area_of(joined)));
    // The rim is sewn all the way round: every edge on the hole's circle borders the sheet and the flange.
    std::size_t on_rim = 0;
    bool sewn = true;
    for (const bs::Edge& e : must(joined.edges(), "edges")) {
        if (!on_hole_circle(e, 1e-3, true)) continue;
        ++on_rim;
        std::vector<std::uint32_t> f = e.faces;
        std::sort(f.begin(), f.end());
        if (f != std::vector<std::uint32_t>{0, 1}) sewn = false;
    }
    check(on_rim > 0 && sewn, "every rim edge borders faces 0 and 1");
    return {};
}

// 14: a_liner_runs_a_hole_down_to_a_tilted_floor
static Result<void> a_liner_runs_a_hole_down_to_a_tilted_floor() {
    std::pair<Solid, std::vector<std::uint32_t>> h = holed_sheet();
    const Solid& holed = h.first;
    const std::vector<std::uint32_t>& rim = h.second;
    // The floor z = -7 + 0.1 x, wide enough to catch every point: the wall is 7 - 0.1 x deep,
    // 6.9 on average round a hole centred at x = 1.
    Solid floor = must(Solid::edge_surface(many(line({-20, -20, -9}, {20, -20, -5}), line({20, -20, -5}, {20, 20, -5}),
                                                line({20, 20, -5}, {-20, 20, -9}), line({-20, 20, -9}, {-20, -20, -9}))),
                       "floor");
    Solid wall = must(holed.extrude_to(rim, {0, 0, -1}, floor, 1e-3, false), "liner");
    check(wall.faces() == rim.size() && wall.sheet_error().has_value() && *wall.sheet_error() <= 1e-3,
          "extrude_to: one face per rim edge, sheet_error within the tolerance");
    check(std::fabs(area_of(wall) - 2 * PI * 5 * 6.9) < 0.05, "liner area " + num(area_of(wall)));
    std::pair<Vec3, Vec3> b = must(wall.bounds(), "bounds");
    check(std::fabs(b.first[2] - (-7 + 0.1 * (1 - 5))) < 1e-2 && std::fabs(b.second[2]) < 1e-6, "liner bounds");
    Solid joined = must(holed.extrude_to(rim, {0, 0, -1}, floor), "liner joined");
    check(joined.faces() == holed.faces() + rim.size(), "joined: the sheet's faces and one per rim edge");
    std::string step = must(joined.step_text(), "step_text");
    check(step.find("SURFACE_OF_LINEAR_EXTRUSION") != std::string::npos, "the liner writes a SURFACE_OF_LINEAR_EXTRUSION");
    return {};
}

// 15: flange_and_extrude_to_refuse_by_name
static Result<void> flange_and_extrude_to_refuse_by_name() {
    std::pair<Solid, std::vector<std::uint32_t>> h = holed_sheet();
    const Solid& holed = h.first;
    const std::vector<std::uint32_t>& rim = h.second;
    NurbsCurve under = line({0, 0, 0}, {0, -3, 0});
    refused(holed.flange(rim, line({1, 0, 0}, {1, -3, 0})), "flange: the section starts at", "", "flange section off the origin");
    refused(holed.flange({}, under), "flange: no edges given", "", "flange of no edges");
    refused(holed.flange({999}, under), "flange: no edge 999", "", "flange of edge 999");
    Solid box = must(Solid::cuboid(10, 10, 10), "cuboid");
    refused(box.flange({0}, under), "flange: edge 0 borders 2 faces", "", "flange of a box edge");
    Solid floor = rect_sheet({0, 0, -7}, {1, 0, 0}, {0, 1, 0}, 40, 40);
    refused(holed.extrude_to(rim, {0, 0, 1}, floor), "extrude_to: edge ", "misses the target", "extrude_to away from the target");
    refused(holed.extrude_to(rim, {0, 0, 0}, floor), "extrude_to: the direction has no length", "", "extrude_to no direction");
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
        {"surfaces_from_curves_are_sheets", surfaces_from_curves_are_sheets},
        {"a_curve_trims_a_hole_and_an_island_and_they_join_back", a_curve_trims_a_hole_and_an_island_and_they_join_back},
        {"an_open_curve_keeps_its_left_or_right", an_open_curve_keeps_its_left_or_right},
        {"six_sheets_join_into_a_box", six_sheets_join_into_a_box},
        {"join_sheets_sews_a_t_junction", join_sheets_sews_a_t_junction},
        {"trim_by_curve_and_join_refuse_by_name", trim_by_curve_and_join_refuse_by_name},
        {"recess_sets_a_square_window_into_a_flat_sheet", recess_sets_a_square_window_into_a_flat_sheet},
        {"continuity_match_and_blend", continuity_match_and_blend},
        {"n_sided_patch_fills_a_pentagon_of_strips", n_sided_patch_fills_a_pentagon_of_strips},
        {"fillet_surfaces_rolls_a_ball_between_two_sheets", fillet_surfaces_rolls_a_ball_between_two_sheets},
        {"fillet_rounds_a_spline_edge_at_a_constant_and_a_varying_radius", fillet_rounds_a_spline_edge_at_a_constant_and_a_varying_radius},
        {"sheet_error_and_patch_report_are_set_where_made", sheet_error_and_patch_report_are_set_where_made},
        {"continuity_says_where", continuity_says_where},
        {"a_flange_turns_a_hole_under_and_carries_it_inward", a_flange_turns_a_hole_under_and_carries_it_inward},
        {"a_liner_runs_a_hole_down_to_a_tilted_floor", a_liner_runs_a_hole_down_to_a_tilted_floor},
        {"flange_and_extrude_to_refuse_by_name", flange_and_extrude_to_refuse_by_name},
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
    std::printf("curve_sheets: ok\n");
    return 0;
}
