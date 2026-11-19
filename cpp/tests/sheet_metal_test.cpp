// Sheet metal and unroll -- SheetRule, sheet_base, sheet_flange, is_sheet_metal, sheet_info,
// sheet_bend_faces, flat_pattern with its FlatPattern (bends, body, dxf, Page::add_flat_pattern),
// fold_flat and unroll with its Unrolled, sheet_rip_points, sheet_rip_face, sheet_join, sheet_fillet
// and sheet_chamfer -- at parity with the Python reference's tests test_sheet_metal_* and
// test_unroll_* in test_cadaclysm_blacksmith.py, every figure a closed
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

// 3: sheet_metal_refusals_are_named
static Result<void> sheet_metal_refusals_are_named() {
    bs::SheetRule rule(1.0);
    Solid cube = must(Solid::cuboid(10, 10, 10), "cuboid");
    refused(cube.sheet_info(), "sheet_info: ", "sheet_info of a cube");
    refused(cube.flat_pattern(0, rule), "flat_pattern: ", "flat_pattern of a cube");
    refused(Solid::sheet_base(must(bs::Profile::rect(10, 10), "rect"), bs::SheetRule(-1.0)), "sheet_base: ", "a sheet -1 thick");
    refused(must(Solid::sphere(5), "sphere").unroll(), "unroll: ", "a sphere unrolled");
    return {};
}

// 4: sheet_metal_rips_joins_and_corner_breaks
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
        {"sheet_metal_refusals_are_named", sheet_metal_refusals_are_named},
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
