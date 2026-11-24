// Sheets from curves -- loft_curves, sweep_rail, sweep_two_rails, edge_surface, network_surface,
// continuity, matched, blend_sides, n_sided_patch, fillet_surfaces, the varying-radius fillet,
// split_by_curve, trim_by_curve, join_sheets, flange, extrude_to, faired, curvature_turns and
// highlight_kink, with the Continuity, PatchReport, JoinReport, CurvatureTurns and HighlightKink records -- at parity with the Python reference's tests of the same names in
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
using bs::Drilled;
using bs::FeatureOp;
using bs::Frame;
using bs::HoleReport;
using bs::JoinedSheets;
using bs::Mirrored;
using bs::NurbsCurve;
using bs::NurbsSurface;
using bs::PatchBoundary;
using bs::Pattern;
using bs::Patterned;
using bs::Profile;
using bs::Panels;
using bs::Recessed;
using bs::RibSide;
using bs::Solid;
using bs::Solids;
using bs::SurfaceFillet;
using bs::SymmetryReport;
using bs::Transform;
using bs::Vec3;
using bs::WebSide;

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

// 6b': half a roof domed both ways, lofted out from the centre plane y = 0, leaning as it leaves
// the plane: mirrored as it is, the seam is a crease; squared first, it is smooth
static Result<void> mirror_join_squares_a_half_roof_to_its_mirror() {
    std::vector<NurbsCurve> sections;
    for (double y : {0.0, 10.0, 20.0, 30.0}) {
        std::vector<Vec3> row;
        for (int i = 0; i <= 8; ++i) {
            double x = 10.0 * i;
            row.push_back({x, y, 20 * std::sin(PI * x / 80) - 0.01 * y * y + 0.05 * y + 0.002 * x * y});
        }
        sections.push_back(must(NurbsCurve::through(row), "section"));
    }
    Solid half = must(Solid::loft_curves(sections), "half");
    Frame plane = must(Frame::make({0, 0, 0}, {1, 0, 0}, {0, 0, -1}, {0, 1, 0}), "plane");
    Mirrored creased = must(half.mirror_join(plane, 0, 0.01), "mirror_join as it is");
    SymmetryReport r = creased.report;
    check(creased.solid.faces() == 2 && r.seams == 1 && r.squared == 0 && r.moved == 0,
          "mirror_join as it is: seams " + std::to_string(r.seams) + ", squared " + std::to_string(r.squared) + ", moved " + num(r.moved));
    check(r.gap < 1e-9 && r.angle > 5 * PI / 180 && r.curvature > 1e-4,
          "mirror_join crease: gap " + num(r.gap) + ", angle " + num(r.angle) + ", curvature " + num(r.curvature));
    Mirrored smooth = must(half.mirror_join(plane, 0.5, 0.01), "mirror_join squared");
    r = smooth.report;
    check(smooth.solid.faces() == 2 && r.seams == 1 && r.squared == 1 && r.naked == 6,
          "mirror_join squared: seams " + std::to_string(r.seams) + ", squared " + std::to_string(r.squared) + ", naked " + std::to_string(r.naked));
    check(r.moved > 0 && r.gap < 1e-9 && r.angle < 1e-9 && r.curvature < 1e-9,
          "mirror_join smooth: moved " + num(r.moved) + ", gap " + num(r.gap) + ", angle " + num(r.angle) + ", curvature " + num(r.curvature));
    double body = area_of(smooth.solid), one = area_of(half);
    check(std::abs(body - 2 * one) < 0.01 * one, "mirror_join: area " + num(body) + " against " + num(one));
    refused(smooth.solid.mirror_join(plane), "mirror_join: the half lies on both sides of the plane", "", "mirror_join a whole body");
    return {};
}

static double volume_of(const Solid& s) { return must(s.mass(), "mass").volume; }

static bool near(double got, double want, double rel) { return std::abs(got - want) <= rel * std::abs(want); }

// A `w` by `d` by `h` block centred at (x, y, z).
static Solid block(double w, double d, double h, double x, double y, double z) {
    return must(must(Solid::cuboid(w, d, h), "cuboid").translate(x, y, z), "translate");
}

// 6b'': holes, ribs and webs, patterns -- the literals Python's suite pins
static Result<void> holes_ribs_webs_and_patterns() {
    Solid blk = block(40, 30, 20, 20, 15, 10);
    Drilled drilled = must(blk.hole({{10, 15, 20}}, 4), "hole");
    check(near(volume_of(drilled.solid), 24000 - 80 * PI, 1e-6) && drilled.solid.faces() == 7,
          "hole: volume " + num(volume_of(drilled.solid)) + ", faces " + std::to_string(drilled.solid.faces()));
    HoleReport hr = drilled.report;
    check(hr.holes == 1 && hr.faces_added == 1 && hr.bottoms.size() == 1 && std::abs(hr.bottoms[0] - 20) < 1e-9,
          "hole report: holes " + std::to_string(hr.holes) + ", faces_added " + std::to_string(hr.faces_added));
    refused(blk.hole({{10, 15, 20}}, 0), "hole: diameter 0 is not positive and finite", "", "hole of diameter 0");
    Solid bit = must(blk.hole_tool({{10, 15, 20}}, 4), "hole_tool");
    check(volume_of(bit) > 80 * PI, "hole_tool volume " + num(volume_of(bit)));

    Solid plate = block(100, 60, 10, 50, 30, 5);
    Solid tool = must(must(Solid::cylinder(3, 30), "cylinder").translate(10, 10, -10), "tool");
    std::vector<Transform> grid = must(Pattern::rectangular({1, 0, 0}, 4, 20, Vec3{0, 1, 0}, 3, 20), "grid");
    check(grid.size() == 12, "pattern_rectangular: " + std::to_string(grid.size()) + " placements");
    Patterned holed = must(plate.pattern_feature(tool, FeatureOp::cut, grid), "pattern_feature");
    check(near(volume_of(holed.solid), 60000 - 1080 * PI, 1e-6), "pattern_feature volume " + num(volume_of(holed.solid)));
    check(holed.report.instances == 12 && holed.report.booleans == 1 && holed.report.missed == 0,
          "pattern_feature report: " + std::to_string(holed.report.instances) + ", " + std::to_string(holed.report.booleans) + ", " +
              std::to_string(holed.report.missed));

    std::vector<Transform> row = must(Pattern::rectangular({1, 0, 0}, 3, 10), "row");
    const std::array<double, 16> identity = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
    const std::array<double, 16> step = {1, 0, 0, 10, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
    check(row.size() == 3 && row[0].rows() == identity && row[1].rows() == step, "pattern_rectangular row");
    refused(Pattern::rectangular({1, 0, 0}, 0, 10), "pattern_rectangular: count1 is 0", "", "pattern_rectangular of none");
    std::vector<Transform> pair = must(Pattern::rectangular({1, 0, 0}, 2, 8), "pair");
    Patterned bodies = must(blk.pattern({pair[0], pair[1]}), "pattern");
    check(bodies.report.instances == 2 && bodies.report.booleans == 1 && near(volume_of(bodies.solid), 28800, 1e-6),
          "pattern: instances " + std::to_string(bodies.report.instances) + ", volume " + num(volume_of(bodies.solid)));

    std::vector<Transform> ring = must(Pattern::circular({0, 0, 0}, {0, 0, 1}, 6), "circular");
    check(ring.size() == 6 && std::abs(ring[1].rows()[0] - 0.5) < 1e-12, "pattern_circular: " + std::to_string(ring.size()));
    std::vector<Transform> along = must(Pattern::along(line({0, 0, 0}, {30, 0, 0}), 4), "along");
    check(along.size() == 4 && std::abs(along[3].rows()[3] - 30) < 1e-9, "pattern_along: " + std::to_string(along.size()));
    Frame at5 = must(Frame::make({5, 0, 0}, {0, 1, 0}, {0, 0, 1}, {1, 0, 0}), "YZ plane at x = 5");
    std::vector<Transform> mirrored = must(Pattern::mirror(at5), "pattern_mirror");
    check(mirrored.size() == 2 && mirrored[0].rows() == identity, "pattern_mirror: " + std::to_string(mirrored.size()) + ", the identity first");
    if (mirrored.size() == 2) {
        Vec3 image = mirrored[1].point({7, 1, 2});
        check(std::abs(image[0] - 3) < 1e-12 && std::abs(image[1] - 1) < 1e-12 && std::abs(image[2] - 2) < 1e-12,
              "pattern_mirror maps (7, 1, 2) to (" + num(image[0]) + ", " + num(image[1]) + ", " + num(image[2]) + ")");
    }
    const std::array<double, 12> flat = {0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0};
    refused(Pattern::mirror(flat), "pattern_mirror: the plane's normal is zero", "", "pattern_mirror of a zero normal");

    Solid l = must(block(40, 30, 5, 20, 15, 2.5).join(block(5, 30, 40, 2.5, 15, 20)), "L");
    check(near(volume_of(l), 11250, 1e-6), "L volume " + num(volume_of(l)));
    NurbsCurve diag = line({30, 15, 5}, {5, 15, 30});
    Frame side = must(Frame::make({0, 15, 0}, {1, 0, 0}, {0, 0, 1}, {0, -1, 0}), "rib plane");
    Solid ribbed = must(l.rib(diag, side, 4), "rib");
    check(near(volume_of(ribbed), 11250 + 1250, 1e-6), "rib volume " + num(volume_of(ribbed)));
    Solid slab = must(l.rib_tool(diag, side, 4, RibSide::front), "rib_tool");
    check(near(volume_of(slab), 1250, 1e-6), "rib_tool volume " + num(volume_of(slab)));

    Solid hub = must(must(Solid::cylinder(20, 10), "flange").join(must(Solid::cylinder(5, 30), "boss")), "hub");
    NurbsCurve flank = line({15, 0, 10}, {5, 0, 25});
    const double gusset = 75 * 25.0 / 3 * PI / 6;
    Solid swung = must(hub.rib_revolved(flank, {0, 0, 0}, {0, 0, 1}, PI / 6), "rib_revolved");
    check(near(volume_of(swung) - volume_of(hub), gusset, 1e-3), "rib_revolved added " + num(volume_of(swung) - volume_of(hub)));
    Solid wedge = must(hub.rib_revolved_tool(flank, {0, 0, 0}, {0, 0, 1}, PI / 6), "rib_revolved_tool");
    check(near(volume_of(wedge), gusset, 1e-3), "rib_revolved_tool volume " + num(volume_of(wedge)));
    refused(hub.rib_revolved(flank, {0, 0, 0}, {0, 0, 1}, 0), "rib_revolved: angle 0 is not in (0, 2 pi)", "", "rib_revolved of angle 0");

    Solid tray = must(block(60, 40, 20, 30, 20, 10).cut(block(56, 36, 18, 30, 20, 11)), "tray");
    Frame top = must(Frame::make({0, 0, 10}, {1, 0, 0}, {0, -1, 0}, {0, 0, -1}), "web plane");
    Solid webbed = must(tray.web(many(line({10, 20, 10}, {50, 20, 10})), top, 3), "web");
    check(near(volume_of(webbed) - volume_of(tray), 1344, 1e-6), "web added " + num(volume_of(webbed) - volume_of(tray)));
    Solid walls = must(tray.web_tool(many(line({10, 20, 10}, {50, 20, 10})), top, 3, WebSide::both, 6.0), "web_tool");
    check(volume_of(walls) > 0, "web_tool volume " + num(volume_of(walls)));
    return {};
}

// 6c: a ring on a square offset along it, split along it, parted by a panel gap
static Result<void> a_ring_on_a_square_offsets_splits_and_parts_with_a_panel_gap() {
    Solid sq = rect_sheet({0, 0, 0}, {1, 0, 0}, {0, 1, 0}, 40, 40);
    std::vector<Vec3> pts;
    for (int i = 0; i < 48; ++i) {
        double a = 2 * 3.14159265358979323846 * i / 48;
        pts.push_back({8 * std::cos(a), 8 * std::sin(a), 0});
    }
    NurbsCurve ring = must(NurbsCurve::through(pts, 3, true), "ring");
    NurbsCurve inner = must(ring.offset_on_sheet(sq, 2.0, 1e-3), "offset_on_sheet");
    std::pair<double, double> domain = must(inner.domain(), "domain");
    Vec3 p0 = must(inner.point(domain.first), "point");
    check(inner.fit_error() && *inner.fit_error() <= 1e-3 && std::abs(std::hypot(p0[0], p0[1]) - 6) < 1e-3, "offset_on_sheet");
    Solid halves = must(sq.split_along_curve(ring, 1e-3), "split_along_curve");
    check(halves.faces() == 2, "split_along_curve: " + std::to_string(halves.faces()) + " faces");
    Panels panels = must(sq.panel_gap(ring, 4.0, -10.0, 1e-3), "panel_gap");
    check(panels.left.faces() == 3 && panels.right.faces() == 3,
          "panel_gap: " + std::to_string(panels.left.faces()) + "/" + std::to_string(panels.right.faces()) + " faces");
    return {};
}

// 6d: curves on a surface -- a uv curve pushed up onto a sphere of radius 3 and pulled back, the
// shortest path between two uv points a great-circle arc
static double dist3(const Vec3& a, const Vec3& b) {
    return std::sqrt((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]) + (a[2] - b[2]) * (a[2] - b[2]));
}

static Result<void> curves_on_a_sphere_push_up_pull_back_and_take_the_short_path() {
    Solid sphere = must(Solid::sphere(3.0), "sphere");
    NurbsCurve uv = must(NurbsCurve::make({{0.1, 0.2, 0}, {0.7, 0.5, 0}, {1.3, 0.1, 0}, {1.9, -0.3, 0}}, 3), "uv curve");
    NurbsCurve up = must(uv.push_up(sphere, 0, 1e-4), "push_up");
    NurbsCurve back = must(up.pull_back(sphere, 0, 1e-4), "pull_back");
    // the C ABI's own figures, read through the raw calls: the wrapper must hand back the same
    // nonzero errors, not the zeros it held before the calls wrote them
    double raw_up_error = 0.0;
    CadaclysmBlacksmithNurbsCurve* raw_up = ::cadaclysm_blacksmith_nurbs_curve_pushed_up(uv.handle(), sphere.handle(), 0, 1e-4, &raw_up_error);
    check(raw_up != nullptr && raw_up_error > 0, "push_up: the raw call reports a nonzero error");
    ::cadaclysm_blacksmith_nurbs_curve_free(raw_up);
    check(up.fit_error().has_value() && *up.fit_error() == raw_up_error, "push_up: fit_error is the C ABI's own error");
    double raw_back_error = 0.0;
    CadaclysmBlacksmithNurbsCurve* raw_back = ::cadaclysm_blacksmith_nurbs_curve_pulled_back(up.handle(), sphere.handle(), 0, 1e-4, &raw_back_error);
    check(raw_back != nullptr && raw_back_error > 0, "pull_back: the raw call reports a nonzero error");
    ::cadaclysm_blacksmith_nurbs_curve_free(raw_back);
    check(back.fit_error().has_value() && *back.fit_error() == raw_back_error, "pull_back: fit_error is the C ABI's own error");
    std::pair<double, double> domain = must(up.domain(), "domain");
    const Vec3 origin = {0, 0, 0};
    for (int k = 0; k <= 20; ++k) {
        double t = domain.first + (domain.second - domain.first) * k / 20.0;
        check(std::abs(dist3(must(up.point(t), "point"), origin) - 3) <= 1e-4, "push_up: off the sphere at " + std::to_string(t));
        Vec3 p = must(back.point(t), "point");
        Vec3 q = must(uv.point(t), "point");
        check(dist3(p, q) <= 1e-3 && p[2] == 0, "pull_back: the uv curve strays at " + std::to_string(t));
    }
    // the sphere's point at (u, v) is 3 (cos v cos u, cos v sin u, sin v)
    const Vec3 pa = {3 * std::cos(0.3), 0, 3 * std::sin(0.3)};
    const Vec3 pb = {3 * std::cos(-0.4) * std::cos(1.2), 3 * std::cos(-0.4) * std::sin(1.2), 3 * std::sin(-0.4)};
    NurbsCurve path = must(NurbsCurve::short_path(sphere, 0, bs::Vec2{0, 0.3}, bs::Vec2{1.2, -0.4}, 1e-4), "short_path");
    std::pair<double, double> pd = must(path.domain(), "domain");
    double length = 0;
    Vec3 prev = must(path.point(pd.first), "point");
    for (int k = 1; k <= 2000; ++k) {
        Vec3 next = must(path.point(pd.first + (pd.second - pd.first) * k / 2000.0), "point");
        length += dist3(prev, next);
        prev = next;
    }
    double angle = std::acos(std::cos(0.3) * std::cos(-0.4) * std::cos(1.2) + std::sin(0.3) * std::sin(-0.4));
    check(dist3(must(path.point(pd.first), "point"), pa) <= 1e-4 && dist3(must(path.point(pd.second), "point"), pb) <= 1e-4,
          "short_path: the ends are not the two uv points");
    check(std::abs(length - 3 * angle) <= 1e-4, "short_path: length " + std::to_string(length) + " vs " + std::to_string(3 * angle));
    refused(NurbsCurve::short_path(sphere, 0, bs::Vec2{0, 0.3}, bs::Vec2{0, 0.3}, 1e-4), "nurbs_curve_short_path_on_face: ", "",
            "short_path with a == b");
    return {};
}

// 6e: a curve fitted to a face's own parameter -- a slanted line projected across a cylinder of
// radius 3 along -x, parametrised by the side's height
static Result<void> a_curve_fits_to_a_faces_own_parameter() {
    Solid cyl = must(Solid::cylinder(3.0, 5.0), "cylinder");
    NurbsCurve line = must(NurbsCurve::make({{4, 1, 5}, {4, -1, 0}}, 1), "line");
    std::uint32_t side = 0;
    std::optional<NurbsCurve> found;
    for (std::uint32_t f = 0; f < 3 && !found; ++f) {
        Result<NurbsCurve> tried = line.fit_to_face(cyl, f, Vec3{-1, 0, 0}, std::vector<double>{1.25, 2.5}, 1e-4);
        if (tried.ok()) {
            found.emplace(std::move(tried).value());
            side = f;
        }
    }
    if (!found) {
        check(false, "fit_to_face: no face of the cylinder took the line");
        return {};
    }
    const NurbsCurve& fit = *found;
    check(fit.fit_error() && *fit.fit_error() <= 1e-4, "fit_to_face: fit error");
    std::pair<double, double> domain = must(fit.domain(), "domain");
    check(domain.first == 0.0 && domain.second == 5.0, "fit_to_face: domain " + num(domain.first) + ".." + num(domain.second));
    std::vector<double> knots = must(fit.knots(), "knots");
    check(std::find(knots.begin(), knots.end(), 1.25) != knots.end() && std::find(knots.begin(), knots.end(), 2.5) != knots.end(),
          "fit_to_face: the knots miss 1.25 or 2.5");
    for (double t : {0.0, 1.3, 3.7, 5.0}) {
        double y = -1 + 2 * t / 5;
        check(dist3(must(fit.point(t), "point"), Vec3{std::sqrt(9 - y * y), y, t}) <= 1e-4, "fit_to_face: off the trace at " + num(t));
    }
    NurbsCurve short_line = must(NurbsCurve::make({{3, 0, 1}, {3, 0, 4}}, 1), "short line");
    refused(short_line.fit_to_face(cyl, side), "nurbs_curve_fitted_to_face: ", "has to cross the face", "fit_to_face of a short line");
    return {};
}

// 6f: offsets (spec section 8) -- a line and an arc exactly, a wavy bicubic within its
// tolerance, an arc on a quarter wall along and across it, a cube and its top face
static Result<void> offsets_of_curves_surfaces_and_solids() {
    const Vec3 z{0, 0, 1};
    NurbsCurve ten = line({0, 0, 0}, {10, 0, 0});
    NurbsCurve moved = must(ten.offset(2, z), "offset of the line");
    std::pair<double, double> span = must(moved.domain(), "domain");
    check(moved.fit_error() && *moved.fit_error() == 0.0, "offset: the line's fit error");
    check(dist3(must(moved.point(span.first), "point"), Vec3{0, -2, 0}) <= 1e-12 &&
              dist3(must(moved.point(span.second), "point"), Vec3{10, -2, 0}) <= 1e-12,
          "offset: the line's ends");
    const double h = std::sqrt(0.5);
    NurbsCurve arc = must(NurbsCurve::make({{2, 0, 0}, {2, 2, 0}, {0, 2, 0}}, 2, std::vector<double>{1, h, 1}), "arc");
    NurbsCurve out = must(arc.offset(1, z, 1e-6), "offset of the arc");
    check(out.fit_error() && *out.fit_error() == 0.0, "offset: the arc's fit error");
    check(std::abs(dist3(must(out.point(0.5), "point"), Vec3{0, 0, 0}) - 3) <= 1e-12, "offset: the arc's mid point is not at r 3");
    refused(arc.offset(-2, z, 1e-6), "nurbs_curve_offset: ", "", "offset of an arc used up");

    std::vector<Vec3> wavy;
    for (int i = 0; i < 4; ++i) {
        for (int j = 0; j < 4; ++j) wavy.push_back(Vec3{double(i), double(j), std::sin(double(i)) * std::cos(double(j)) / 4});
    }
    const std::vector<double> k{0, 0, 0, 0, 3, 3, 3, 3};
    NurbsSurface s = must(NurbsSurface::make(wavy, {4, 4}, 3, 3, std::nullopt, k, k), "bicubic");
    check(!s.fit_error(), "offset: a built surface carries a fit error");
    NurbsSurface so = must(s.offset(0.2, 1e-6), "offset of the bicubic");
    check(so.fit_error() && *so.fit_error() >= 0.0 && *so.fit_error() <= 1e-6, "offset: the bicubic's fit error");
    Vec3 p = must(s.point_at(1.5, 1.5), "point_at");
    Vec3 n = must(s.normal_at(1.5, 1.5), "normal_at");
    check(dist3(must(so.point_at(1.5, 1.5), "point_at"), Vec3{p[0] + 0.2 * n[0], p[1] + 0.2 * n[1], p[2] + 0.2 * n[2]}) <= 1e-6,
          "offset: the bicubic at (1.5, 1.5)");

    NurbsSurface quarter = must(NurbsSurface::make({{2, 0, 0}, {2, 0, 5}, {2, 2, 0}, {2, 2, 5}, {0, 2, 0}, {0, 2, 5}}, {3, 2}, 2, 1,
                                                   std::vector<double>{1, 1, h, h, 1, 1}, std::vector<double>{0, 0, 0, 1, 1, 1},
                                                   std::vector<double>{0, 0, 1, 1}),
                                "quarter wall");
    Solid wall = must(quarter.to_sheet(), "to_sheet");
    NurbsCurve on_wall = must(NurbsCurve::make({{2, 0, 2}, {2, 2, 2}, {0, 2, 2}}, 2, std::vector<double>{1, h, 1}), "arc on the wall");
    NurbsCurve up = must(on_wall.offset_normal_to_sheet(wall, 1, 1e-6), "offset_normal_to_sheet");
    NurbsCurve along = must(on_wall.offset_tangent_to_sheet(wall, 1, 1e-6), "offset_tangent_to_sheet");
    check(up.fit_error() && *up.fit_error() <= 1e-6 && along.fit_error() && *along.fit_error() <= 1e-6, "offset: the wall's fit errors");
    std::pair<double, double> up_span = must(up.domain(), "domain");
    std::pair<double, double> along_span = must(along.domain(), "domain");
    for (int i = 0; i <= 20; ++i) {
        Vec3 q = must(up.point(up_span.first + (up_span.second - up_span.first) * i / 20), "point");
        check(std::abs(std::hypot(q[0], q[1]) - 3) <= 2e-6 && std::abs(q[2] - 2) <= 2e-6, "offset_normal_to_sheet: off r 3, z 2 at " + num(i));
        q = must(along.point(along_span.first + (along_span.second - along_span.first) * i / 20), "point");
        check(std::abs(std::hypot(q[0], q[1]) - 2) <= 2e-6 && std::abs(q[2] - 3) <= 2e-6, "offset_tangent_to_sheet: off r 2, z 3 at " + num(i));
    }

    Solid cube = must(Solid::cuboid(10, 10, 10), "cuboid");
    double grown = must(must(cube.offset(1, 1e-6), "offset +1").mass(), "mass").volume;
    double shrunk = must(must(cube.offset(-1, 1e-6), "offset -1").mass(), "mass").volume;
    check(std::abs(grown - 1728) <= 1e-6, "offset: the grown cube's volume " + num(grown));
    check(std::abs(shrunk - 512) <= 1e-6, "offset: the shrunk cube's volume " + num(shrunk));
    Solid top = must(cube.offset_face(1, 1, 1e-6), "offset_face");
    std::pair<Vec3, Vec3> box = must(top.bounds64(), "bounds64");
    check(top.faces() == 1 && std::abs(area_of(top) - 100) <= 1e-6, "offset_face: area " + num(area_of(top)));
    check(std::abs(box.first[2] - 6) <= 1e-9 && std::abs(box.second[2] - 6) <= 1e-9, "offset_face: z " + num(box.first[2]) + ".." + num(box.second[2]));
    refused(cube.offset(0), "solid_offset: ", "", "offset by 0");
    refused(cube.offset_face(1, 0), "solid_offset_face: ", "", "offset_face by 0");
    return {};
}

// 6g: face split (docs/superpowers/specs/2026-11-20-face-split-design.md) -- a box's top split by
// a line across it, on its face and on every face it lies on; a sphere along its silhouette
static Result<void> faces_split_along_curves_and_silhouettes() {
    Solid cube = must(Solid::cuboid(10, 10, 10), "cuboid");
    const std::vector<NurbsCurve> across = many(line({-8, -2, 5}, {8, 3, 5}));
    for (const std::vector<std::optional<std::uint32_t>>& faces :
         {std::vector<std::optional<std::uint32_t>>{}, std::vector<std::optional<std::uint32_t>>{1u},
          std::vector<std::optional<std::uint32_t>>{std::nullopt}}) {
        Solid out = must(cube.split_faces(across, faces), "split_faces");
        check(out.faces() == 7, "split_faces: " + num(out.faces()) + " faces");
        bs::Mass m = must(out.mass(), "mass");
        check(m.closed && std::abs(m.volume - 1000) <= 1e-6 && std::abs(m.area - 600) <= 1e-6, "split_faces: volume " + num(m.volume));
        int tops = 0;
        for (std::uint32_t f = 0; f < out.faces(); ++f) {
            if (std::abs(must(out.face_inner_point(f), "face_inner_point").point[2] - 5) <= 1e-9) ++tops;
        }
        check(tops == 2, "split_faces: " + num(tops) + " faces on the top");
    }
    refused(cube.split_faces(std::vector<NurbsCurve>{}), "split_faces: ", "", "split_faces with no curves");
    refused(cube.split_faces(across, {1u, 2u}), "split_faces: ", "", "split_faces with two faces for one curve");
    const double r = 5;
    Solid ball = must(must(Solid::sphere(r), "sphere").split_along_silhouette({0, 0, 1}), "split_along_silhouette");
    bs::Mass m = must(ball.mass(), "mass");
    check(ball.faces() == 2 && m.closed, "split_along_silhouette: " + num(ball.faces()) + " faces");
    check(std::abs(m.area - 4 * 3.14159265358979323846 * r * r) <= 1e-6 * m.area, "split_along_silhouette: area " + num(m.area));
    refused(cube.split_along_silhouette({0, 0, 1}), "split_along_silhouette: ", "", "a box seen along an axis");
    return {};
}

// 6h: surface edits (docs/superpowers/specs/2026-11-22-surface-edits-design.md) -- untrim,
// unstitch, ruled faces off edges, a seam moved, sheets and surfaces merged, and tweens; paint
// and ids follow the face each result face comes from
static NurbsSurface patch(double x0, double x1, double z = 0.0) {
    return must(NurbsSurface::make({{x0, 0, z}, {x0, 1, z}, {x1, 0, z}, {x1, 1, z}}, {2, 2}, 1, 1), "patch");
}

static Result<void> surface_edits_keep_paint_and_ids() {
    const Vec3 red{1, 0, 0};
    const Vec3 blue{0, 0, 1};
    Solid cube = must(must(must(must(Solid::cuboid(10, 10, 10), "cuboid").coloured(blue), "coloured").coloured(red, 1u), "coloured top").track(),
                      "track");
    for (bs::Untrim which : {bs::Untrim::holes, bs::Untrim::outer, bs::Untrim::all}) {
        Solid out = must(cube.untrim(1, which), "untrim");
        bs::Mass m = must(out.mass(), "mass");
        check(out.faces() == 6 && m.closed && std::abs(m.volume - 1000) <= 1e-6, "untrim: " + num(out.faces()) + " faces, volume " + num(m.volume));
        check(must(out.face_colour(1), "face_colour") == std::optional<Vec3>(red), "untrim: the top lost its red");
        check(must(out.face_id(1), "face_id") == must(cube.face_id(1), "face_id"), "untrim: the top lost its id");
    }
    Solid bored = must(cube.cut(must(must(Solid::cylinder(2, 20), "cylinder").translate(0, 0, -10), "translate")), "cut");
    std::uint32_t top = 0;
    for (std::uint32_t f = 0; f < bored.faces(); ++f) {
        if (std::abs(must(bored.face_inner_point(f), "face_inner_point").point[2] - 5) < 1e-9) top = f;
    }
    Solid open = must(bored.untrim(top, bs::Untrim::holes), "untrim holes");
    check(open.faces() == bored.faces() && !must(open.mass(), "mass").closed, "untrim holes: " + num(open.faces()) + " faces");
    check(std::abs(area_of(must(open.face_sheet(top), "face_sheet")) - 100) <= 1e-6, "untrim holes: the top is not the whole square");

    std::vector<Solid> sheets = must(cube.unstitch(), "unstitch");
    check(sheets.size() == 6, "unstitch: " + num(static_cast<double>(sheets.size())) + " sheets");
    for (const Solid& s : sheets) check(s.faces() == 1 && std::abs(area_of(s) - 100) <= 1e-6, "unstitch: a sheet not one 10 x 10 face");
    std::vector<Solid> alone = must(cube.unstitch({1u}), "unstitch top");
    check(alone.size() == 2 && alone[0].faces() == 1 && alone[1].faces() == 5, "unstitch top: not the top, then the other five");
    check(must(alone[0].face_colour(0), "face_colour") == std::optional<Vec3>(red), "unstitch top: the top lost its red");
    std::vector<Solid> two = must(cube.unstitch({1u, 2u}, true), "unstitch together");
    check(two.size() == 2 && two[0].faces() == 2 && two[1].faces() == 4, "unstitch together: not two faces, then four");

    std::uint32_t edge = 0;
    for (const bs::Edge& e : must(cube.edges(), "edges")) {
        if (std::find(e.faces.begin(), e.faces.end(), 1u) != e.faces.end()) {
            edge = e.index;
            break;
        }
    }
    Solid ruled = must(cube.ruled_from_edges({edge}, bs::Ruling::normal, 2), "ruled_from_edges");
    check(ruled.faces() == 1 && std::abs(area_of(ruled) - 20) <= 1e-6, "ruled_from_edges: area " + num(area_of(ruled)));
    Solid other = must(cube.ruled_from_edges({edge}, bs::Ruling::normal, 2, 0, std::nullopt, true), "ruled_from_edges alternate");
    check(must(ruled.face_colour(0), "face_colour") != must(other.face_colour(0), "face_colour"),
          "ruled_from_edges: both faces took one colour");
    Solid up = must(cube.ruled_from_edges({edge}, bs::Ruling::direction, 3, 0, Vec3{0, 0, 1}), "ruled_from_edges direction");
    check(std::abs(area_of(up) - 30) <= 1e-6, "ruled_from_edges direction: area " + num(area_of(up)));

    const double r = 2;
    const double h = 5;
    Solid can = must(Solid::cylinder(r, h), "cylinder");
    std::uint32_t wall = 0;
    for (std::uint32_t f = 0; f < can.faces(); ++f) {
        Vec3 p = must(can.face_inner_point(f), "face_inner_point").point;
        if (std::abs(std::hypot(p[0], p[1]) - r) < 1e-9 && p[2] > 0 && p[2] < h) wall = f;
    }
    Solid painted = must(must(can.coloured(red, wall), "coloured").track(), "track");
    Solid reseamed = must(painted.change_seam(wall, 1.0), "change_seam");
    check(reseamed.faces() == can.faces() && std::abs(must(reseamed.mass(), "mass").volume - PI * r * r * h) <= 1e-9 * PI * r * r * h,
          "change_seam: the shape changed");
    check(must(reseamed.face_colour(wall), "face_colour") == std::optional<Vec3>(red), "change_seam: the wall lost its red");
    check(must(reseamed.face_id(wall), "face_id") == must(painted.face_id(wall), "face_id"), "change_seam: the wall lost its id");

    NurbsSurface left = patch(0, 1);
    NurbsSurface right = patch(1, 2);
    NurbsSurface merged = must(left.merge(right), "merge");
    std::pair<std::pair<double, double>, std::pair<double, double>> d = must(merged.domain(), "domain");
    Vec3 corner = must(merged.point_at(d.first.second, d.second.second), "point_at");
    check(std::abs(corner[0] - 2) <= 1e-12 && std::abs(corner[1] - 1) <= 1e-12 && std::abs(corner[2]) <= 1e-12, "merge: the far corner is not (2, 1, 0)");
    Solid sheet = must(must(must(left.to_sheet(), "to_sheet").coloured(red), "coloured")
                           .merge_surfaces(must(must(right.to_sheet(), "to_sheet").coloured(blue), "coloured")),
                       "merge_surfaces");
    check(sheet.faces() == 1 && std::abs(area_of(sheet) - 2) <= 1e-9, "merge_surfaces: area " + num(area_of(sheet)));
    check(must(sheet.face_colour(0), "face_colour") == std::optional<Vec3>(red), "merge_surfaces: not this sheet's red");
    std::vector<NurbsSurface> tweens = must(left.tween(patch(0, 1, 4), 3), "tween");
    check(tweens.size() == 3, "tween: " + num(static_cast<double>(tweens.size())) + " surfaces");
    for (std::size_t i = 0; i < tweens.size(); ++i) {
        double z = must(tweens[i].point_at(0.5, 0.5), "point_at")[2];
        check(std::abs(z - static_cast<double>(i + 1)) <= 1e-12, "tween: surface " + num(static_cast<double>(i)) + " at z " + num(z));
    }

    Solid plain = must(Solid::cuboid(10, 10, 10), "cuboid");
    refused(plain.untrim(99), "untrim: ", "", "untrim a face out of range");
    refused(plain.unstitch({99u}), "unstitch: ", "", "unstitch a face out of range");
    refused(plain.unstitch({1u, 1u}), "unstitch: ", "", "unstitch a face twice");
    refused(plain.ruled_from_edges({}, bs::Ruling::normal), "ruled_from_edges: ", "", "ruled_from_edges with no edges");
    refused(plain.ruled_from_edges({999u}, bs::Ruling::normal), "ruled_from_edges: ", "", "ruled_from_edges an edge out of range");
    refused(plain.ruled_from_edges({0u}, bs::Ruling::normal, 0), "ruled_from_edges: ", "", "ruled_from_edges a distance 0");
    refused(plain.ruled_from_edges({0u}, bs::Ruling::direction, 1, 0, Vec3{0, 0, 0}), "ruled_from_edges: ", "", "a zero direction");
    refused(plain.ruled_from_edges({0u}, bs::Ruling::direction), "ruled_from_edges: ", "", "ruling direction with no direction");
    refused(plain.ruled_from_edges({0u}, bs::Ruling::normal, 1, 0, Vec3{0, 0, 1}), "ruled_from_edges: ", "", "a direction not read");
    refused(plain.change_seam(99, 1.0), "change_seam: ", "", "change_seam a face out of range");
    refused(plain.change_seam(1, 1.0), "change_seam: ", "", "change_seam a plane");
    refused(plain.merge_surfaces(must(patch(0, 1).to_sheet(), "to_sheet")), "merge_surfaces: ", "", "merge_surfaces a box");
    refused(patch(0, 1).merge(patch(5, 6)), "nurbs_surface_merge: ", "", "merge with no side shared");
    refused(patch(0, 1).tween(patch(5, 6), 0), "nurbs_surface_tween: ", "", "tween a count of 0");
    return {};
}

// 7: continuity_match_and_blend
static Result<void> continuity_match_and_blend() {
    Solid a = must(Solid::loft_curves(many(line({-1, 0, 0}, {0, 0, 0}), line({-1, 1, 0}, {0, 1, 0})), 1), "a");
    Solid b = must(Solid::loft_curves(many(line({0, 0, 0}, {0, 0, 1}), line({0, 1, 0}, {0, 1, 1})), 1), "b");
    Continuity r = must(a.continuity("u1", b, "u0", 0, 0, 32), "continuity");
    check(r.gap <= 1e-12 && std::fabs(r.angle - PI / 2) <= 1e-9 && r.samples >= 33, "a meets b square: angle " + num(r.angle));
    Solid m = must(a.match("u1", b, "u0", 1), "matched");
    r = must(m.continuity("u1", b, "u0"), "matched continuity");
    check(r.gap <= 1e-10 && r.angle <= 1e-8, "matched at G1: gap " + num(r.gap) + ", angle " + num(r.angle));
    Solid blend = must(Solid::blend_sides(a, "u0", b, "u1", 2), "blend_sides");
    r = must(blend.continuity("v0", a, "u0"), "blend continuity");
    check(r.gap <= 1e-10 && r.angle <= 1e-8 && r.curvature <= 1e-6, "blend at G2: " + num(r.gap) + ", " + num(r.angle) + ", " + num(r.curvature));
    refused(a.continuity("w2", b, "u0"), "a side is 'u0', 'u1', 'v0' or 'v1', not 'w2'", "", "continuity side");
    refused(a.match("u1", b, "u0", 3), "match_side: ", "", "match_side level 3");
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

// 10b: fillet_law with stations at the chain's ends is the varying fillet
static Result<void> fillet_law_with_stations_at_the_ends_is_the_varying_fillet() {
    Solid shell = fender_and_door();
    std::vector<std::uint32_t> crease;
    for (const bs::Edge& e : must(shell.edges(), "edges")) {
        if (e.faces.size() == 2) crease.push_back(e.index);
    }
    Solid varying = must(shell.fillet(crease, 8.0, 1e-3, {}, 20.0), "varying");
    Solid lawed = must(shell.fillet_law(crease, {{0.0, 8.0}, {1.0, 20.0}}, 1e-3), "fillet_law");
    double v = must(varying.mass(1e-6), "mass").area, l = must(lawed.mass(1e-6), "mass").area;
    check(lawed.faces() == 3 && std::fabs(l - v) < 1e-3, "fillet_law " + num(l) + " against the varying fillet's " + num(v));
    // A swell in the middle takes more than 8 all along and less than 20 all along.
    double swell = must(must(shell.fillet_law(crease, {{0.0, 8.0}, {0.5, 20.0}, {1.0, 8.0}}, 1e-3), "swell").mass(1e-6), "mass").area;
    double low = must(must(shell.fillet(crease, 8.0, 1e-3), "8").mass(1e-6), "mass").area;
    double high = must(must(shell.fillet(crease, 20.0, 1e-3), "20").mass(1e-6), "mass").area;
    check(swell < low && swell > high, "the swell's area " + num(swell) + " between " + num(low) + " and " + num(high));
    refused(shell.fillet_law(crease, {}, 1e-3), "", "at least one station", "no stations");
    refused(must(Solid::cuboid(10, 10, 10), "cuboid").fillet_law({0}, {{0.0, 1.0}, {1.0, 2.0}}), "", "a radius law rounds only spline edges",
            "radius law on a box");
    return {};
}

// 10c: fillet_chord and fillet_asymmetric round a box edge to their closed forms
static Result<void> fillet_chord_and_fillet_asymmetric_round_a_box_edge() {
    Solid box = must(Solid::cuboid(40, 30, 20), "cuboid");
    std::uint32_t edge = 0, face = 0;
    bool found = false;
    for (const bs::Edge& e : must(box.edges(), "edges")) {
        if (e.kind == "line" && e.faces.size() == 2) {
            edge = e.index;
            face = e.faces[0];
            found = true;
            break;
        }
    }
    check(found, "a box has a line edge");
    double length = must(box.edge_length(edge, 1e-9), "edge_length").length;
    double quarter = 1.0 - std::acos(-1.0) / 4.0, r = 4.0 / std::sqrt(2.0);
    double chorded = volume_of(must(box.fillet_chord({edge}, 4.0), "fillet_chord"));
    double want_chord = 24000.0 - length * r * r * quarter;
    check(std::fabs(chorded - want_chord) <= 1e-6 * want_chord, "fillet_chord's volume " + num(chorded) + " against " + num(want_chord));
    double asym = volume_of(must(box.fillet_asymmetric({edge}, face, 6.0, 2.0), "fillet_asymmetric"));
    double want_asym = 24000.0 - length * 6.0 * 2.0 * quarter;
    check(std::fabs(asym - want_asym) <= 1e-6 * want_asym, "fillet_asymmetric's volume " + num(asym) + " against " + num(want_asym));
    refused(box.fillet_chord({edge}, 0.0), "", "the chord must be positive", "a zero chord");
    refused(box.fillet_asymmetric({edge}, face, 6.0, 0.0), "", "distances must be positive", "a zero distance");
    return {};
}

// 10d: fillet_full_round rounds a box's top into a half cylinder; fillet_rule rounds a plate and
// boss's ridges
static Result<void> fillet_full_round_and_fillet_rule_round_by_faces() {
    Solid box = must(Solid::cuboid(40, 6, 12), "cuboid");
    std::uint32_t top = must(box.select_face(bs::Selector::normal({0, 0, 1})), "top");
    std::uint32_t front = must(box.select_face(bs::Selector::normal({0, -1, 0})), "front");
    std::uint32_t back = must(box.select_face(bs::Selector::normal({0, 1, 0})), "back");
    double rounded = volume_of(must(box.fillet_full_round(front, top, back), "fillet_full_round"));
    double want = 40.0 * 6.0 * 12.0 - 40.0 * 9.0 * (2.0 - std::acos(-1.0) / 2.0);
    check(std::fabs(rounded - want) <= 1e-3 * want, "fillet_full_round's volume " + num(rounded) + " against " + num(want));
    refused(box.fillet_full_round(front, box.faces() + 3, back), "", "no such face", "a face past the last");
    Solid body = must(must(Solid::cuboid(40, 30, 5), "plate").join(must(must(Solid::cylinder(6, 8), "boss").translate(0, 0, 2.5), "translate")),
                      "join");
    std::vector<std::uint32_t> faces;
    for (std::uint32_t f = 0; f < body.faces(); ++f) faces.push_back(f);
    double before = volume_of(body);
    double ridged = volume_of(must(body.fillet_rule(faces, 1.0, {}, bs::EdgeRule::convex, 0.05), "fillet_rule"));
    check(ridged < before, "fillet_rule convex: volume " + num(ridged) + " not below " + num(before));
    refused(box.fillet_rule({0, 1, 2, 3, 4, 5}, 1.0, {}, bs::EdgeRule::concave), "", "no edge between the faces matches the rule",
            "a box has no valley");
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

// 16: a_wobbly_loft_faired_turns_no_curvature_over
static Result<void> a_wobbly_loft_faired_turns_no_curvature_over() {
    // Eleven lines across a shallow arch, each lifted or dropped by 0.4 in turn: a loft through
    // them ripples between every pair.
    std::vector<NurbsCurve> lines;
    for (int k = 0; k < 11; ++k) {
        double x = 10.0 * k;
        double z = -0.01 * (x - 50.0) * (x - 50.0) + (k % 2 == 0 ? 0.4 : -0.4);
        lines.push_back(line({x, 0, z}, {x, 40, z}));
    }
    Solid loft = must(Solid::loft_curves(lines, 3), "loft_curves");
    bs::CurvatureTurns t = must(loft.curvature_turns(0, 32), "curvature_turns");
    check(t.samples == 32 && !t.mean_turns.empty() && t.mean_positive + t.mean_negative > 1,
          "the wobbly loft's mean curvature turns over between several areas");
    for (const bs::At& a : t.mean_turns) {
        double n = std::sqrt(a.tangent[0] * a.tangent[0] + a.tangent[1] * a.tangent[1] + a.tangent[2] * a.tangent[2]);
        check(std::abs(n - 1.0) < 1e-9 && a.point[0] >= 0 && a.point[0] <= 100 && a.point[2] > -26 && a.point[2] < 1,
              "a mean turn is on the sheet with a unit normal");
    }
    // The lines run along u, the loft's v across them: the end lines kept, held along v.
    std::vector<std::optional<std::int32_t>> ends_kept = {std::nullopt, std::nullopt, 0, 0};
    Solid faired = must(loft.faired(1.0, 3, std::nullopt, ends_kept, "v"), "faired");
    check(faired.sheet_error().has_value() && *faired.sheet_error() >= 0 && *faired.sheet_error() <= 1.05,
          "the faired sheet is within its tolerance: " + num(faired.sheet_error().value_or(-1)));
    bs::CurvatureTurns f = must(faired.curvature_turns(0, 32), "faired curvature_turns");
    check(f.mean_turns.empty() && f.mean_positive + f.mean_negative == 1, "the faired sheet's mean curvature keeps one sign");
    Solid coarse = must(loft.faired(1.0, 3, std::make_pair(std::uint32_t(6), std::uint32_t(8)), ends_kept, "v"), "faired on 6 x 8");
    check(*coarse.sheet_error() <= 1.05 && must(coarse.curvature_turns(), "coarse curvature_turns").mean_turns.empty(),
          "the fair on a 6 x 8 net is within its tolerance and turns no curvature over");
    refused(loft.faired(1.0, 2), "surface_faired: ", "degree 2", "faired at degree 2");
    refused(loft.faired(0.01, 3, std::nullopt, ends_kept, "v"), "surface_faired: ", "no fair free of inflections", "faired too tight");
    refused(loft.faired(1.0, 3, std::nullopt, {0, 0}), "keep takes 4 levels (u0, u1, v0, v1), not 2", "", "faired with 2 levels");
    refused(loft.faired(1.0, 3, std::nullopt, {2}, "w"), "no_inflection is 'u', 'v', 'uv' or empty, not 'w'", "", "faired along w");
    refused(loft.curvature_turns(7), "curvature_turns: ", "", "curvature_turns of face 7");
    return {};
}

// 17: highlight_kink_runs_straight_across_planes_and_kinks_at_a_fillet_seam
static Result<void> highlight_kink_runs_straight_across_planes_and_kinks_at_a_fillet_seam() {
    Solid block = must(Solid::cuboid(2, 2, 2), "cuboid");
    bs::HighlightKink k = must(block.highlight_kink(0, 16), "highlight_kink");
    check(k.angle < 1e-9 && k.samples == 17, "the highlight lines run straight across a box's edge, 17 samples");
    Solid rounded = must(block.fillet({0}, 0.5), "fillet");
    std::size_t edges = must(rounded.edges(), "edges").size();
    double worst = 0.0;
    for (std::uint32_t e = 0; e < edges; ++e) {
        Result<bs::HighlightKink> kink = rounded.highlight_kink(e);
        if (!kink) continue;   // an edge of one face
        worst = std::max(worst, kink->angle);
    }
    // Where the fillet's curvature meets a flat face's, the highlight lines break.
    check(worst > PI / 4, "a fillet seam kinks the highlight lines past 45 degrees: " + num(worst));
    refused(block.highlight_kink(999), "highlight_kink: ", "", "highlight_kink of edge 999");
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
        {"mirror_join_squares_a_half_roof_to_its_mirror", mirror_join_squares_a_half_roof_to_its_mirror},
        {"holes_ribs_webs_and_patterns", holes_ribs_webs_and_patterns},
        {"a_ring_on_a_square_offsets_splits_and_parts_with_a_panel_gap", a_ring_on_a_square_offsets_splits_and_parts_with_a_panel_gap},
        {"curves_on_a_sphere_push_up_pull_back_and_take_the_short_path", curves_on_a_sphere_push_up_pull_back_and_take_the_short_path},
        {"a_curve_fits_to_a_faces_own_parameter", a_curve_fits_to_a_faces_own_parameter},
        {"offsets_of_curves_surfaces_and_solids", offsets_of_curves_surfaces_and_solids},
        {"faces_split_along_curves_and_silhouettes", faces_split_along_curves_and_silhouettes},
        {"surface_edits_keep_paint_and_ids", surface_edits_keep_paint_and_ids},
        {"continuity_match_and_blend", continuity_match_and_blend},
        {"n_sided_patch_fills_a_pentagon_of_strips", n_sided_patch_fills_a_pentagon_of_strips},
        {"fillet_surfaces_rolls_a_ball_between_two_sheets", fillet_surfaces_rolls_a_ball_between_two_sheets},
        {"fillet_rounds_a_spline_edge_at_a_constant_and_a_varying_radius", fillet_rounds_a_spline_edge_at_a_constant_and_a_varying_radius},
        {"fillet_law_with_stations_at_the_ends_is_the_varying_fillet", fillet_law_with_stations_at_the_ends_is_the_varying_fillet},
        {"fillet_chord_and_fillet_asymmetric_round_a_box_edge", fillet_chord_and_fillet_asymmetric_round_a_box_edge},
        {"fillet_full_round_and_fillet_rule_round_by_faces", fillet_full_round_and_fillet_rule_round_by_faces},
        {"sheet_error_and_patch_report_are_set_where_made", sheet_error_and_patch_report_are_set_where_made},
        {"continuity_says_where", continuity_says_where},
        {"a_flange_turns_a_hole_under_and_carries_it_inward", a_flange_turns_a_hole_under_and_carries_it_inward},
        {"a_liner_runs_a_hole_down_to_a_tilted_floor", a_liner_runs_a_hole_down_to_a_tilted_floor},
        {"flange_and_extrude_to_refuse_by_name", flange_and_extrude_to_refuse_by_name},
        {"a_wobbly_loft_faired_turns_no_curvature_over", a_wobbly_loft_faired_turns_no_curvature_over},
        {"highlight_kink_runs_straight_across_planes_and_kinks_at_a_fillet_seam",
         highlight_kink_runs_straight_across_planes_and_kinks_at_a_fillet_seam},
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
