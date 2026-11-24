// Sheet metal and unroll -- SheetRule, sheet_base, sheet_flange, is_sheet_metal, sheet_info,
// sheet_bend_faces, flat_pattern with its FlatPattern (bends, body, dxf, Page::add_flat_pattern),
// fold_flat, unroll with its Unrolled, squish with its Squished, sheet_rip_points, sheet_rip_face, sheet_join, sheet_fillet
// and sheet_chamfer -- at parity with the Python reference's tests test_sheet_metal_*,
// test_unroll_* and test_squish_* in test_cadaclysm_blacksmith.py, every figure a closed
// form written out here: a 60 x 40 plate flanged 15 high on its four edges lays flat to
// 2400 - pi + 2 (58 + 38) (15 - 2 + pi/2 1.44). The kernel's own correctness is the kernel's
// tests' job. Needs the kernel library and a license; the exit code is the verdict.
//
//     cadaclysm_sheet_metal_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <algorithm>
#include <array>
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
using bs::Frame;
using bs::Solid;
using bs::Vec3;

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

static bool near(double got, double want, double rel) { return std::fabs(got - want) <= rel * std::fabs(want); }

template <class T>
static T must(Result<T> r, const std::string& what) {
    if (!r.ok()) {
        std::fprintf(stderr, "FAIL: %s: %s\n", what.c_str(), r.error().message.c_str());
        std::exit(1);
    }
    return std::move(r).value();
}

static void must_do(Result<void> r, const std::string& what) {
    if (!r.ok()) {
        std::fprintf(stderr, "FAIL: %s: %s\n", what.c_str(), r.error().message.c_str());
        std::exit(1);
    }
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

// The face of `s` whose outward normal is `n` and whose frame origin has z `z`.
static std::uint32_t face_at(const Solid& s, const Vec3& n, double z) {
    for (std::uint32_t f = 0; f < s.faces(); ++f) {
        const std::array<double, 12> fr = must(s.face_frame(f), "face_frame").raw();
        if (std::fabs(fr[9] - n[0]) < 1e-9 && std::fabs(fr[10] - n[1]) < 1e-9 && std::fabs(fr[11] - n[2]) < 1e-9 &&
            std::fabs(fr[2] - z) < 1e-9) {
            return f;
        }
    }
    std::fprintf(stderr, "FAIL: no face facing (%g, %g, %g) at z %g\n", n[0], n[1], n[2], z);
    std::exit(1);
}

static double volume(const Solid& s) { return must(s.mass(), "mass").volume; }

// 1: sheet_metal_a_tray_reads_unfolds_and_folds_back
static Result<void> sheet_metal_a_tray_reads_unfolds_and_folds_back() {
    bs::SheetRule rule(1.0);
    bs::SheetRule full = must(bs::SheetRule::library_default(1.0), "library_default");
    check(full.bend_radius && *full.bend_radius == 1.0 && full.relief_width == 1.0 && full.relief_depth == 0.5 &&
              full.corner_size == 2.0 && near(full.miter_gap, 0.1, 1e-12),
          "the library's default rule writes its sizes out");
    Solid plate = must(Solid::sheet_base(must(bs::Profile::rect(60, 40), "rect"), rule), "sheet_base");
    check(near(volume(plate), 2400, 1e-12), "the plate's volume " + num(volume(plate)) + ", not 2400");
    std::uint32_t top = face_at(plate, {0, 0, 1}, 0);
    std::vector<std::uint32_t> edges;
    for (const bs::Edge& e : must(plate.edges(), "edges")) {
        for (std::uint32_t f : e.faces) {
            if (f == top) edges.push_back(e.index);
        }
    }
    check(edges.size() == 4, "the top has 4 edges, not " + std::to_string(edges.size()));
    Solid tray = must(plate.sheet_flange(edges, PI / 2, 15, rule), "sheet_flange");

    check(tray.is_sheet_metal(), "the tray is sheet metal");
    check(!must(Solid::cuboid(10, 10, 10), "cuboid").is_sheet_metal(), "a cube is not sheet metal");
    bs::SheetInfo info = must(tray.sheet_info(), "sheet_info");
    check(near(info.thickness, 1, 1e-9), "the tray is " + num(info.thickness) + " thick, not 1");
    check(info.bends.size() == 4, "the tray has 4 bends, not " + std::to_string(info.bends.size()));
    for (const bs::BendInfo& b : info.bends) {
        check(near(b.radius, 1, 1e-9) && near(std::fabs(b.angle), PI / 2, 1e-9),
              "a bend of radius " + num(b.radius) + " and angle " + num(b.angle) + ", not 1 and pi/2");
    }
    std::vector<std::uint32_t> bend_faces = must(tray.sheet_bend_faces(), "sheet_bend_faces");
    check(bend_faces.size() == 8, "8 bend faces, not " + std::to_string(bend_faces.size()));

    bs::FlatPattern flat = must(tray.flat_pattern(face_at(tray, {0, 0, 1}, 0), rule), "flat_pattern");
    double allowance = PI / 2 * (1 + 0.44);
    check(flat.bends().size() == 4, "the flat has 4 bend zones, not " + std::to_string(flat.bends().size()));
    for (const bs::FlatBend& b : flat.bends()) {
        check(b.up, "a zone bends up");
        check(near(b.allowance, allowance, 1e-9), "a zone at allowance " + num(b.allowance) + ", not " + num(allowance));
    }
    double want = 2400 - PI + 2 * (58 + 38) * (15 - 2 + allowance);
    double got = volume(must(flat.body(), "flat body"));
    check(near(got, want, 1e-6), "the flat body's volume " + num(got) + ", not " + num(want));

    std::string text = must(flat.dxf(bs::PageUnits::millimetres, true, true, true), "dxf");
    const char* const layers[] = {"OUTLINE", "BEND_UP", "BEND_EXTENT", "BEND_TABLE", "B4 UP 90"};
    for (const char* layer : layers) check(text.find(layer) != std::string::npos, std::string("the DXF holds ") + layer);
    std::string no_table = must(flat.dxf(bs::PageUnits::millimetres, true, false, true), "dxf without a table");
    check(no_table.find("BEND_TABLE") == std::string::npos, "the DXF without a table has no BEND_TABLE");

    bs::Page page = must(bs::Page::make(bs::PageUnits::millimetres), "Page::make");
    must_do(page.add_flat_pattern(flat, {0.0, 0.0}, false, false, false), "add_flat_pattern");
    std::uint32_t plain = must(page.entity_count(), "entity_count");
    check(plain > 0, "a plain flat pattern draws something");
    must_do(page.add_flat_pattern(flat, {200.0, 0.0}, true, false, false), "add_flat_pattern with extents");
    std::uint32_t both = must(page.entity_count(), "entity_count");
    check(both - plain == plain + 8, "extents add two zone edges a bend: " + std::to_string(both - plain) + " added, not " +
                                         std::to_string(plain + 8));
    // The drawing view: a note a bend, a ruled table (6 + 8 rules, 35 cells), two dimensions of six.
    const struct { bool notes, table, dimensions; std::uint32_t more; const char* what; } views[] = {
        {true, false, false, 4, "notes"}, {false, true, false, 6 + 8 + 35, "a ruled table"}, {false, false, true, 12, "dimensions"}};
    for (const auto& v : views) {
        std::uint32_t before = must(page.entity_count(), "entity_count");
        must_do(page.add_flat_pattern(flat, {400.0, 0.0}, false, v.table, false, v.notes, v.dimensions, false), v.what);
        std::uint32_t after = must(page.entity_count(), "entity_count");
        check(after - before == plain + v.more, std::string(v.what) + ": " + std::to_string(after - before) + " added");
    }
    std::string drawn = must(flat.dxf(bs::PageUnits::millimetres, true, true, true, true, true, true), "dxf with the drawing view");
    const char* const drawn_layers[] = {"BEND_NOTE", "DIMENSION", "FOLDED", "K-FACTOR", "DEDUCTION"};
    for (const char* layer : drawn_layers) check(drawn.find(layer) != std::string::npos, std::string("the drawing holds ") + layer);

    Solid again = must(Solid::fold_flat(must(flat.profile(), "flat profile"), flat.fold_bends(), rule, flat.frame()), "fold_flat");
    check(near(volume(again), volume(tray), 1e-6), "folded back to " + num(volume(again)) + ", not the tray's " + num(volume(tray)));
    return {};
}

// 2: unroll_a_cylinder_with_points
static Result<void> unroll_a_cylinder_with_points() {
    Solid can = must(Solid::cylinder(5, 10), "cylinder");
    bs::Unrolled flat = must(can.unroll({}, {}, {Vec3{5, 0, 1}, Vec3{50, 50, 50}}), "unroll");
    std::vector<std::uint32_t> faces = flat.faces;
    std::sort(faces.begin(), faces.end());
    check(faces == std::vector<std::uint32_t>{0, 1, 2}, "the sheet's source faces are 0, 1, 2");
    check(flat.not_developable.empty(), "every face of a cylinder is developable");
    check(!flat.cuts.empty(), "at least one cut");
    check(flat.curves.empty(), "no curves given, none back");
    // The wall a 10 pi x 10 rectangle, the two discs beside it: area kept.
    double want = 2 * PI * 5 * 10 + 2 * PI * 25;
    double got = must(flat.sheet.mass(), "sheet mass").area;
    check(near(got, want, 1e-6), "the flat sheet's area " + num(got) + ", not " + num(want));
    check(flat.points.size() == 2, "two points back");
    check(flat.points[0].has_value() && std::fabs((*flat.points[0])[2]) <= 1e-9, "the point on the wall lands on the flat");
    check(!flat.points[1].has_value(), "the point off the can lands nowhere");
    bs::Unrolled exploded = must(can.unroll({}, {}, {}, true), "unroll exploded");
    check(exploded.cuts.size() >= flat.cuts.size(), "exploded cuts at least as many");
    return {};
}

// A sphere r 5 with the half below z = 0 cut away: a dome and a disk.
static Solid half_ball() {
    Solid ball = must(Solid::sphere(5), "sphere");
    Solid below = must(must(Solid::cuboid(20, 20, 10), "cuboid").translate(0, 0, -5), "translate");
    return must(ball.cut(below, std::nullopt), "cut");
}

// 3: squish_a_half_ball_with_its_distortion_and_a_point
static Result<void> squish_a_half_ball_with_its_distortion_and_a_point() {
    Solid half = half_ball();
    check(half.faces() == 2, "the half ball has 2 faces, not " + std::to_string(half.faces()));
    bs::Squished apart = must(half.squish({}, {}, {}, true), "squish exploded");
    check(apart.faces.size() == 2 && apart.distortion.size() == 2, "two sheet faces, each with its distortion");
    check(apart.exact.size() == 1, "the disk alone is laid exactly, not " + std::to_string(apart.exact.size()) + " faces");
    check(must(apart.sheet.mass(), "sheet mass").area > 0, "the sheet has an area");
    if (apart.faces.size() != 2 || apart.exact.size() != 1) return {};
    std::size_t disk = apart.faces[0] == apart.exact[0] ? 0 : 1;
    std::size_t dome = 1 - disk;
    check(std::fabs(apart.distortion[disk].area_mean - 1) < 1e-6, "the disk's area kept: mean " + num(apart.distortion[disk].area_mean));
    // The dome's rim kept: its area near half the dome's, every triangle the right way up.
    const bs::SquishDistortion& d = apart.distortion[dome];
    check(d.area_min > 0 && d.area_min <= d.area_mean && d.area_mean <= d.area_max,
          "the dome's area min " + num(d.area_min) + " <= mean " + num(d.area_mean) + " <= max " + num(d.area_max));
    check(d.area_mean >= 0.45 && d.area_mean <= 0.7, "the dome's area mean " + num(d.area_mean) + " in [0.45, 0.7]");

    // The dome alone, compress-only: the pole lands, a point far off does not.
    bs::Squished pole = must(half.squish({apart.faces[dome]}, {}, {Vec3{0, 0, 5}, Vec3{50, 50, 50}}, false,
                                         bs::SquishDeformation::compress_only, false),
                             "squish the dome");
    check(pole.distortion.size() == 1 && pole.distortion[0].length_min >= 1,
          "compress only: every length at least its 3D one, min " + num(pole.distortion.empty() ? 0 : pole.distortion[0].length_min));
    check(pole.points.size() == 2, "two points back");
    check(pole.points[0].has_value() && std::fabs((*pole.points[0])[2]) < 1e-9, "the pole lands on the flat");
    check(!pole.points[1].has_value(), "the point off the dome lands nowhere");
    check(pole.curves.empty(), "no curves given, none back");
    return {};
}

// 4: sheet_metal_refusals_are_named
static Result<void> sheet_metal_refusals_are_named() {
    bs::SheetRule rule(1.0);
    Solid cube = must(Solid::cuboid(10, 10, 10), "cuboid");
    refused(cube.sheet_info(), "sheet_info: ", "sheet_info of a cube");
    refused(cube.flat_pattern(0, rule), "flat_pattern: ", "flat_pattern of a cube");
    refused(Solid::sheet_base(must(bs::Profile::rect(10, 10), "rect"), bs::SheetRule(-1.0)), "sheet_base: ", "a sheet -1 thick");
    refused(must(Solid::sphere(5), "sphere").unroll(), "unroll: ", "a sphere unrolled");
    Result<bs::Squished> closed = half_ball().squish();
    refused(closed, "squish: ", "a half ball squished whole");
    check(!closed.ok() && closed.error().message.find("closed") != std::string::npos, "the refusal names the faces closed");
    return {};
}

// 4: sheet_metal_rope_and_double_hems
static Result<void> sheet_metal_rope_and_double_hems() {
    bs::SheetRule rule(1.0);
    Solid plate = must(Solid::sheet_base(must(bs::Profile::rect(60, 40), "rect"), rule), "sheet_base");
    std::uint32_t top = face_at(plate, {0, 0, 1}, 0);
    std::vector<std::uint32_t> edges;
    for (const bs::Edge& e : must(plate.edges(), "edges")) {
        for (std::uint32_t f : e.faces) {
            if (f == top && edges.empty()) edges.push_back(e.index);
        }
    }
    Solid rope = must(plate.sheet_hem(edges, bs::HemKind::rope, 0, rule, 2), "rope hem");
    std::size_t rope_bends = must(rope.sheet_info(), "sheet_info").bends.size();
    check(rope_bends == 2, "a rope hem's curl in two halves, not " + std::to_string(rope_bends) + " bends");
    Solid twice = must(plate.sheet_hem(edges, bs::HemKind::double_, 8, rule), "double hem");
    std::size_t double_bends = must(twice.sheet_info(), "sheet_info").bends.size();
    check(double_bends == 2, "a double hem has 2 bends, not " + std::to_string(double_bends));
    return {};
}

// 5: sheet_metal_a_lofted_flange_unfolds
static Result<void> sheet_metal_a_lofted_flange_unfolds() {
    bs::SheetRule rule(1.0);
    const std::vector<Vec3> bottom = {Vec3{-10, -10, 0}, Vec3{10, -10, 0}, Vec3{10, 10, 0}, Vec3{-10, 10, 0}};
    const std::vector<Vec3> top = {Vec3{-15, -15, 20}, Vec3{15, -15, 20}, Vec3{15, 15, 20}, Vec3{-15, 15, 20}};
    Solid hopper = must(Solid::sheet_lofted_flange(bottom, top, rule), "sheet_lofted_flange");
    bs::SheetInfo info = must(hopper.sheet_info(), "sheet_info");
    check(info.bends.size() == 2, "the hopper has 2 bends, not " + std::to_string(info.bends.size()));
    bs::FlatPattern flat = must(hopper.flat_pattern(info.fixed_face, rule), "flat_pattern");
    Solid again = must(Solid::fold_flat(must(flat.profile(), "flat profile"), flat.fold_bends(), rule, flat.frame()), "fold_flat");
    check(near(volume(again), volume(hopper), 1e-6), "folded back to " + num(volume(again)) + ", not the hopper's " + num(volume(hopper)));
    refused(Solid::sheet_lofted_flange({Vec3{0, 0, 0}}, top, rule), "sheet_lofted_flange: ", "a one-point profile");
    return {};
}

// 6: sheet_metal_rips_joins_and_corner_breaks
static Result<void> sheet_metal_rips_joins_and_corner_breaks() {
    bs::SheetRule rule(1.0);
    Solid plate = must(Solid::sheet_base(must(bs::Profile::rect(60, 40), "rect"), rule), "sheet_base");
    std::uint32_t top = face_at(plate, {0, 0, 1}, 0);
    std::uint32_t bottom = face_at(plate, {0, 0, -1}, -1);
    // A rip across the plate, 0.5 wide: 40 x 0.5 x 1 gone.
    Solid ripped = must(plate.sheet_rip_points(top, Vec3{0, -20, 0}, Vec3{0, 20, 0}, 0.5), "sheet_rip_points");
    check(near(volume(ripped), 2400 - 20, 1e-6), "the ripped plate's volume " + num(volume(ripped)) + ", not 2380");
    refused(must(Solid::cuboid(10, 10, 10), "cuboid").sheet_rip_face(0), "sheet_rip_face: ", "sheet_rip_face of a cube");
    // The thickness edges: on neither broad face.
    std::vector<std::uint32_t> corners;
    for (const bs::Edge& e : must(plate.edges(), "edges")) {
        if (std::find(e.faces.begin(), e.faces.end(), top) == e.faces.end() &&
            std::find(e.faces.begin(), e.faces.end(), bottom) == e.faces.end()) {
            corners.push_back(e.index);
        }
    }
    check(corners.size() == 4, "the plate has 4 thickness edges, not " + std::to_string(corners.size()));
    Solid rounded = must(plate.sheet_fillet(corners, 3, rule), "sheet_fillet");
    double want = 2400 - (4 - PI) * 9;
    check(near(volume(rounded), want, 1e-6), "the rounded plate's volume " + num(volume(rounded)) + ", not " + num(want));
    check(rounded.is_sheet_metal(), "the rounded plate is sheet metal");
    std::vector<std::uint32_t> two(corners.begin(), corners.begin() + 2);
    Solid chamfered = must(plate.sheet_chamfer(two, 2, rule), "sheet_chamfer");
    check(near(volume(chamfered), 2400 - 4, 1e-6), "the chamfered plate's volume " + num(volume(chamfered)) + ", not 2396");
    refused(plate.sheet_join(corners[0], corners[0], rule), "sheet_join: ", "sheet_join of an edge with itself");
    return {};
}

int main(int argc, char** argv) {
    if (argc > 1) {
        Result<void> loaded = bs::license(argv[1]);
        if (!loaded) {
            std::fprintf(stderr, "license: %s\n", loaded.error().message.c_str());
            return 1;
        }
    }
    struct Test {
        const char* name;
        Result<void> (*run)();
    };
    const Test tests[] = {
        {"sheet_metal_a_tray_reads_unfolds_and_folds_back", sheet_metal_a_tray_reads_unfolds_and_folds_back},
        {"unroll_a_cylinder_with_points", unroll_a_cylinder_with_points},
        {"squish_a_half_ball_with_its_distortion_and_a_point", squish_a_half_ball_with_its_distortion_and_a_point},
        {"sheet_metal_refusals_are_named", sheet_metal_refusals_are_named},
        {"sheet_metal_rope_and_double_hems", sheet_metal_rope_and_double_hems},
        {"sheet_metal_a_lofted_flange_unfolds", sheet_metal_a_lofted_flange_unfolds},
        {"sheet_metal_rips_joins_and_corner_breaks", sheet_metal_rips_joins_and_corner_breaks},
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
    std::printf("sheet_metal: ok\n");
    return 0;
}
