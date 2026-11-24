// The 2D constraint sketcher, part 2 -- smooth, translated and rotated constraints,
// add_polygon, chamfer, chamfer_angle, pattern_rectangular, pattern_circular and
// auto_constrain -- at parity with the Python reference's test_sketch_smooth_translated_rotated,
// test_sketch_polygon_and_chamfer, test_sketch_patterns and test_sketch_auto_constrain, the same
// values. Every type is spelled out (no `auto`). Needs the kernel library and a license; the
// exit code is the verdict.
//
//     cadaclysm_sketch2_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <utility>
#include <vector>

using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;
using bs::Vec2;

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

static bool near(double a, double b, double tol) { return std::fabs(a - b) <= tol; }

static bs::Sketch fresh() { return take(bs::Sketch::create(), "Sketch::create"); }

static Vec2 point_of(const bs::Sketch& s, std::uint32_t id) { return take(s.point(id), "point"); }

static std::uint32_t pt(bs::Sketch& s, double x, double y) { return take(s.add_point(x, y), "add_point"); }

static void check_at(const bs::Sketch& s, std::uint32_t id, double x, double y, const std::string& what) {
    Vec2 p = point_of(s, id);
    check(near(p[0], x, 1e-9) && near(p[1], y, 1e-9),
          what + ": at (" + std::to_string(p[0]) + ", " + std::to_string(p[1]) + "), wanted (" + std::to_string(x) + ", " +
              std::to_string(y) + ")");
}

static void smooth_translated_rotated() {
    bs::Sketch s = fresh();
    std::uint32_t c = pt(s, 0, 0);
    std::uint32_t a0 = pt(s, 5, 0);
    std::uint32_t a1 = pt(s, 0, 5);
    std::uint32_t arc = take(s.add_arc(c, a0, a1), "add_arc");
    std::uint32_t bezier = take(s.add_bezier(a1, {-2, 5.3}, {-4, 4}, {-6, 1}), "add_bezier");
    take(s.fix(arc), "fix arc");
    std::uint32_t id = take(s.smooth(arc, bezier), "smooth");
    check(take(s.constraint_kind(id), "constraint_kind") == "smooth", "smooth: kind reads smooth");

    bs::Sketch t = fresh();
    std::uint32_t p = pt(t, 1, 1);
    std::uint32_t q = pt(t, 0, 0);
    std::uint32_t f = pt(t, 0, 0);
    std::uint32_t to = pt(t, 3, 4);
    take(t.fix(p), "fix p");
    take(t.fix(f), "fix f");
    take(t.fix(to), "fix t");
    std::uint32_t tid = take(t.translated(p, q, f, to), "translated");
    check(take(t.constraint_kind(tid), "constraint_kind") == "translated", "translated: kind");
    check_at(t, q, 4, 5, "translated q");

    bs::Sketch r = fresh();
    std::uint32_t rc = pt(r, 0, 0);
    std::uint32_t rf = pt(r, 2, 0);
    std::uint32_t rt = pt(r, 0, 7);
    std::uint32_t rp = pt(r, 3, 1);
    std::uint32_t rq = pt(r, 0, 0.5);
    take(r.fix(rc), "fix c");
    take(r.fix(rf), "fix f");
    take(r.fix(rt), "fix t");
    take(r.fix(rp), "fix p");
    std::uint32_t rid = take(r.rotated(rp, rq, rc, rf, rt), "rotated");
    check(take(r.constraint_kind(rid), "constraint_kind") == "rotated", "rotated: kind");
    check_at(r, rq, -1, 3, "rotated q");
}

static void polygon_and_chamfer() {
    bs::Sketch s = fresh();
    bs::SketchPolygon hex = take(s.add_polygon({0, 0}, {5, 0}, 6), "add_polygon");
    check(hex.corners.size() == 6 && hex.sides.size() == 6, "polygon: 6 corners and 6 sides");
    for (std::size_t i = 0; i < hex.corners.size() && i < 6; ++i) {
        Vec2 a = point_of(s, hex.corners[i]);
        Vec2 b = point_of(s, hex.corners[(i + 1) % 6]);
        check(near(std::hypot(a[0] - b[0], a[1] - b[1]), 5.0, 1e-9), "polygon: side " + std::to_string(i) + " is 5");
    }
    check(take(s.diagnose(), "diagnose").free == 4, "polygon: free is 4");

    bs::Sketch c = fresh();
    bs::SketchRect rect = take(c.add_rect({0, 0}, {10, 10}), "add_rect");
    bs::SketchChamfer ch = take(c.chamfer(rect.sides[0], rect.sides[1], 2, 3), "chamfer");
    check_at(c, ch.points[0], 8, 0, "chamfer point a");
    check_at(c, ch.points[1], 10, 3, "chamfer point b");
    check(ch.corner == rect.corners[1], "chamfer: the corner is rect corner 1");
    std::vector<bs::Profile> profiles = take(c.profiles(1e-9), "profiles");
    check(profiles.size() == 1, "chamfer: one loop");
    if (profiles.size() == 1) {
        check(near(take(profiles[0].area_properties(), "area_properties").area, 97.0, 1e-9), "chamfer: area 97");
    }

    bs::Sketch d = fresh();
    bs::SketchRect rect2 = take(d.add_rect({0, 0}, {10, 10}), "add_rect");
    bs::SketchChamfer ang = take(d.chamfer_angle(rect2.sides[0], rect2.sides[1], 2, 0.7853981633974483), "chamfer_angle");
    check(take(d.constraint_kind(ang.dimensions[1]), "constraint_kind") == "angle", "chamfer_angle: the second dimension is an angle");

    // A refusal carries the call's name.
    bs::Sketch e = fresh();
    bs::SketchRect rect3 = take(e.add_rect({0, 0}, {10, 10}), "add_rect");
    Result<bs::SketchChamfer> bad = e.chamfer(rect3.sides[0], rect3.sides[1], 20, 3);
    check(!bad.ok(), "chamfer 20: refused");
    if (!bad.ok()) {
        check(bad.error().message.compare(0, 16, "sketch_chamfer: ") == 0,
              "chamfer 20: refusal starts sketch_chamfer: -- " + bad.error().message);
    }
}

static void patterns() {
    bs::Sketch s = fresh();
    std::uint32_t centre = pt(s, 0, 0);
    std::uint32_t mid = pt(s, 10, 0);
    std::uint32_t circle = take(s.add_circle(mid, 1), "add_circle");
    bs::SketchPattern ring = take(s.pattern_circular({circle}, centre, 6, 3.141592653589793 / 3), "pattern_circular");
    check(ring.copies.size() == 5, "circular: 5 copies");
    check(ring.steps.size() == 2, "circular: 2 steps");
    check(ring.dimensions.size() == 1, "circular: 1 dimension");
    if (ring.copies.size() == 5 && ring.copies[1].size() == 1) {
        // The library gives the circle's id; the centre it turned is a point, found by position.
        std::uint32_t copy_circle = ring.copies[1][0];
        check(take(s.kind(copy_circle), "kind") == "circle", "circular: the copy is a circle");
        std::vector<std::uint32_t> all = take(s.entities(), "entities");
        bool found = false;
        for (std::uint32_t id : all) {
            if (take(s.kind(id), "kind") != "point") continue;
            Vec2 p = point_of(s, id);
            if (near(p[0], 5.0, 1e-9) && near(p[1], 8.660254037844386, 1e-9)) found = true;
        }
        check(found, "circular: copy 1's circle centre is at (5, 8.660254037844386)");
    }

    bs::Sketch g = fresh();
    std::uint32_t p = pt(g, 0, 0);
    bs::SketchPattern row = take(g.pattern_rectangular({p}, {2, 0}, 3, {0, 0}, 1), "pattern_rectangular");
    check(row.copies.size() == 2, "rectangular: 2 copies");
    check(row.dimensions.size() == 2, "rectangular: 2 dimensions");
    if (row.copies.size() == 2) {
        check_at(g, row.copies[0][0], 2, 0, "rectangular copy 0");
        check_at(g, row.copies[1][0], 4, 0, "rectangular copy 1");
    }
}

// A triangle with side a-b on the vertical construction line x = 0: the free point c and the
// sides b-c and c-a go in `ents`, the line in `line`.
static void triangle_on_a_line(bs::Sketch& s, std::vector<std::uint32_t>& ents, std::uint32_t& line) {
    line = take(s.add_line(pt(s, 0, 0), pt(s, 0, 10)), "add_line");
    take(s.set_construction(line), "set_construction");
    std::uint32_t a = pt(s, 0, 2);
    std::uint32_t b = pt(s, 0, 8);
    std::uint32_t c = pt(s, 5, 5);
    take(s.add_line(a, b), "add_line");
    ents = {c, take(s.add_line(b, c), "add_line"), take(s.add_line(c, a), "add_line")};
}

static void mirror() {
    bs::Sketch s = fresh();
    std::vector<std::uint32_t> ents;
    std::uint32_t line = 0;
    triangle_on_a_line(s, ents, line);
    bs::SketchMirror m = take(s.mirror(ents, line), "mirror");
    check(m.copies.size() == 3, "mirror: 3 copies, got " + std::to_string(m.copies.size()));
    if (m.copies.size() == 3) {
        check(take(s.kind(m.copies[0]), "kind") == "point", "mirror: copy 0 is a point");
        check(take(s.kind(m.copies[1]), "kind") == "line", "mirror: copy 1 is a line");
        check(take(s.kind(m.copies[2]), "kind") == "line", "mirror: copy 2 is a line");
        check_at(s, m.copies[0], -5, 5, "mirror: the free point's copy");
    }
    check(!m.constraints.empty(), "mirror: constraints");
    for (std::uint32_t id : m.constraints) {
        std::string kind = take(s.constraint_kind(id), "constraint_kind");
        check(kind == "symmetric" || kind == "equal_radius" || kind == "point_on_line", "mirror: constraint kind " + kind);
    }

    bs::Sketch r = fresh();
    std::vector<std::uint32_t> ents2;
    std::uint32_t line2 = 0;
    triangle_on_a_line(r, ents2, line2);
    std::size_t before = take(r.entities(), "entities").size();
    ents2.push_back(line2);
    Result<bs::SketchMirror> bad = r.mirror(ents2, line2);
    check(!bad.ok(), "mirror with the line: refused");
    if (!bad.ok()) {
        check(bad.error().message.find("mirror line must not be among") != std::string::npos,
              "mirror with the line: refusal -- " + bad.error().message);
    }
    check(take(r.entities(), "entities").size() == before, "mirror refused: the sketch is unchanged");
}

static void auto_constrain() {
    bs::Profile outline = take(bs::Profile::rect(10, 6), "Profile::rect");
    bs::Sketch s = take(bs::Sketch::from_profile(outline, false), "from_profile");
    std::vector<std::uint32_t> made = take(s.auto_constrain(0, true), "auto_constrain");
    check(!made.empty(), "auto_constrain: returned ids");
    check(take(s.diagnose(), "diagnose").free == 0, "auto_constrain: free is 0");
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
        {"smooth_translated_rotated", smooth_translated_rotated},
        {"polygon_and_chamfer", polygon_and_chamfer},
        {"patterns", patterns},
        {"mirror", mirror},
        {"auto_constrain", auto_constrain},
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
    std::printf("sketch2: ok\n");
    return 0;
}
