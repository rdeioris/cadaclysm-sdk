// 2D polygon sets -- at parity with the Python reference's test_polygon_set_* in
// test_cadaclysm_blacksmith.py (_POLYGON_SET): the same worked figures, value for value, every
// refusal's text, the handle's lifetime. Needs the kernel library; the exit code is the verdict.
//
//     cadaclysm_polygon_set_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <limits>
#include <optional>
#include <string>
#include <utility>
#include <vector>

using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;
using bs::PolygonSet;
using bs::PolygonSetPolygon;
using bs::PolygonSets;
using bs::Vec2;

using Ring = std::vector<Vec2>;
using Bounds = std::array<double, 4>;

static int failures = 0;
static const double PI = 3.14159265358979323846;

static void check(bool ok, const std::string& what) {
    if (ok) return;
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
}

// pytest.approx's default: within 1e-6 of `want`, relatively, or `abs` where that is larger.
static bool approx(double got, double want, double abs) {
    return std::fabs(got - want) <= std::max(abs, 1e-6 * std::fabs(want));
}

static std::string num(double v) {
    char buf[64];
    std::snprintf(buf, sizeof buf, "%.17g", v);
    return buf;
}

// The call must have been refused with a message containing `part`.
template <class T>
static void refused(const Result<T>& r, const std::string& part, const std::string& what) {
    if (r.ok()) {
        check(false, what + ": expected a refusal, but the call succeeded");
        return;
    }
    const std::string& got = r.error().message;
    check(got.find(part) != std::string::npos, what + ": refused with \"" + got + "\", wanted \"" + part + "\" in it");
}

// The rectangle [x0, x1] x [y0, y1] as one counter-clockwise ring.
static Result<PolygonSet> box(double x0, double y0, double x1, double y1) {
    return PolygonSet::from_rings(Ring{Vec2{x0, y0}, Vec2{x1, y0}, Vec2{x1, y1}, Vec2{x0, y1}});
}

static Result<void> booleans_and_measures() {
    CADACLYSM_TRY(a, box(0, 0, 2, 2));
    CADACLYSM_TRY(b, box(1, 1, 3, 3));
    CADACLYSM_TRY(u, a.union_(b));
    CADACLYSM_TRY(i, a.intersection(b));
    CADACLYSM_TRY(d, a.difference(b));
    CADACLYSM_TRY(x, a.symmetric_difference(b));
    CADACLYSM_TRY(ua, u.area());
    CADACLYSM_TRY(ia, i.area());
    CADACLYSM_TRY(da, d.area());
    CADACLYSM_TRY(xa, x.area());
    check(ua == 7.0 && ia == 1.0 && da == 3.0 && xa == 6.0,
          "boolean areas " + num(ua) + " " + num(ia) + " " + num(da) + " " + num(xa));
    CADACLYSM_TRY(ia2, a.intersection_area(b));
    CADACLYSM_TRY(da2, a.difference_area(b));
    check(ia2 == 1.0 && da2 == 3.0, "intersection_area " + num(ia2) + ", difference_area " + num(da2));

    std::vector<PolygonSet> tiles;
    for (int ti = 0; ti < 4; ++ti) {
        for (int tj = 0; tj < 3; ++tj) {
            CADACLYSM_TRY(tile, box(ti, tj, ti + 1, tj + 1));
            tiles.push_back(std::move(tile));
        }
    }
    PolygonSets borrowed(tiles.begin(), tiles.end());
    CADACLYSM_TRY(all, PolygonSet::union_all(borrowed));
    CADACLYSM_TRY(polys, all.polygons());
    CADACLYSM_TRY(area, all.area());
    CADACLYSM_TRY(perimeter, all.perimeter());
    check(polys.size() == 1 && area == 12.0 && perimeter == 14.0,
          "union_all: " + std::to_string(polys.size()) + " polygons, area " + num(area) + ", perimeter " + num(perimeter));
    CADACLYSM_TRY(bounds, all.bounds());
    check(bounds.has_value() && *bounds == Bounds{0.0, 0.0, 4.0, 3.0}, "union_all bounds");
    CADACLYSM_TRY(centre, all.centroid());
    check(centre.has_value() && approx((*centre)[0], 2.0, 1e-12) && approx((*centre)[1], 1.5, 1e-12), "union_all centroid");

    CADACLYSM_TRY(empty, PolygonSet::make());
    CADACLYSM_TRY(is_empty, empty.is_empty());
    CADACLYSM_TRY(no_bounds, empty.bounds());
    CADACLYSM_TRY(no_centre, empty.centroid());
    CADACLYSM_TRY(none, empty.size());
    check(is_empty && !no_bounds.has_value() && !no_centre.has_value() && none == 0, "the empty set");
    CADACLYSM_TRY(nothing, PolygonSet::union_all(PolygonSets()));
    CADACLYSM_TRY(nothing_empty, nothing.is_empty());
    check(nothing_empty, "union_all of nothing is empty");
    return {};
}

static Result<void> rings_come_back_as_shapelys() {
    // Kept as written; a verb's result as shapely (GEOS 3.13) gives it, corner for corner.
    CADACLYSM_TRY(room, PolygonSet::from_rings(Ring{Vec2{0, 0}, Vec2{4, 0}, Vec2{4, 3}, Vec2{0, 3}, Vec2{0, 0}}));
    CADACLYSM_TRY(polys, room.polygons());
    const std::vector<PolygonSetPolygon> written = {PolygonSetPolygon{Ring{Vec2{0, 0}, Vec2{4, 0}, Vec2{4, 3}, Vec2{0, 3}}, {}}};
    check(polys == written, "the room as written");
    CADACLYSM_TRY(cleaned, room.cleaned());
    CADACLYSM_TRY(cleaned_polys, cleaned.polygons());
    check(cleaned_polys[0].outer == Ring{Vec2{0, 0}, Vec2{0, 3}, Vec2{4, 3}, Vec2{4, 0}}, "the room cleaned");
    CADACLYSM_TRY(slab, box(1, -1, 2, 4));
    CADACLYSM_TRY(cut, room.difference(slab));
    CADACLYSM_TRY(cut_polys, cut.polygons());
    std::vector<Ring> outers;
    for (const PolygonSetPolygon& p : cut_polys) outers.push_back(p.outer);
    const std::vector<Ring> want = {Ring{Vec2{0, 0}, Vec2{0, 3}, Vec2{1, 3}, Vec2{1, 0}},
                                    Ring{Vec2{4, 3}, Vec2{4, 0}, Vec2{2, 0}, Vec2{2, 3}}};
    check(outers == want, "the room cut in two");
    CADACLYSM_TRY(big, box(0, 0, 10, 10));
    CADACLYSM_TRY(small, box(4, 4, 6, 6));
    CADACLYSM_TRY(holed, big.difference(small));
    CADACLYSM_TRY(holed_polys, holed.polygons());
    check(holed_polys.size() == 1 && holed_polys[0].holes.size() == 1, "one polygon, one hole");
    if (holed_polys.size() == 1 && holed_polys[0].holes.size() == 1) {
        const Ring& outer = holed_polys[0].outer;
        const Ring& hole = holed_polys[0].holes[0];
        check(Ring(outer.begin(), outer.begin() + 2) == Ring{Vec2{0, 10}, Vec2{10, 10}}, "the holed outer's start");
        check(Ring(hole.begin(), hole.begin() + 2) == Ring{Vec2{6, 4}, Vec2{6, 6}}, "the hole's start");
    }
    CADACLYSM_TRY(holed_area, holed.area());
    check(holed_area == 96.0, "holed area " + num(holed_area));
    return {};
}

static Result<void> buffer_is_shapelys() {
    // shapely 2.1 / GEOS 3.13: these areas, to the last few bits.
    CADACLYSM_TRY(sq, box(0, 0, 10, 10));
    CADACLYSM_TRY(in2, sq.buffer(-2));
    CADACLYSM_TRY(in2_area, in2.area());
    check(approx(in2_area, 36.0, 1e-12), "shrunk by 2: " + num(in2_area));
    CADACLYSM_TRY(in6, sq.buffer(-6));
    CADACLYSM_TRY(in6_empty, in6.is_empty());
    check(in6_empty, "shrunk by 6 is empty");
    CADACLYSM_TRY(left, box(0, 0, 4, 4));
    CADACLYSM_TRY(bar, box(4, 1.5, 8, 2.5));
    CADACLYSM_TRY(right, box(8, 0, 12, 4));
    CADACLYSM_TRY(dumbbell, PolygonSet::union_all(PolygonSets{left, bar, right}));
    CADACLYSM_TRY(shrunk, dumbbell.buffer(-1));
    CADACLYSM_TRY(shrunk_n, shrunk.size());
    CADACLYSM_TRY(shrunk_area, shrunk.area());
    check(shrunk_n == 2 && approx(shrunk_area, 8.088436436788012, 1e-9),
          "the dumbbell shrunk: " + std::to_string(shrunk_n) + " polygons, area " + num(shrunk_area));
    CADACLYSM_TRY(g0, box(0, 0, 1, 1));
    CADACLYSM_TRY(g1, box(1.5, 0, 2.5, 1));
    CADACLYSM_TRY(gap, PolygonSet::union_all(PolygonSets{g0, g1}));
    CADACLYSM_TRY(grown, gap.buffer(0.3));
    CADACLYSM_TRY(closed, grown.buffer(-0.3));
    CADACLYSM_TRY(closed_area, closed.area());
    check(approx(closed_area, 2.4057536390037235, 1e-9), "the gap closed: " + num(closed_area));
    CADACLYSM_TRY(room, box(0, 0, 4, 3));
    CADACLYSM_TRY(mitred, room.buffer(1, 16, "mitre"));
    CADACLYSM_TRY(mitred_area, mitred.area());
    check(approx(mitred_area, 30.0, 0.0), "mitred: " + num(mitred_area));
    CADACLYSM_TRY(flat, PolygonSet::buffer_polyline(Ring{Vec2{0, 0}, Vec2{4, 0}}, 0.5, 16, "round", 5.0, "flat"));
    CADACLYSM_TRY(flat_bounds, flat.bounds());
    check(flat_bounds.has_value() && *flat_bounds == Bounds{0.0, -0.5, 4.0, 0.5}, "a flat-capped line's bounds");
    Result<PolygonSet> wobbly = sq.buffer(1, 16, "wobbly");
    check(!wobbly.ok() && wobbly.error().message == "polygon_set_buffer: join must be one of 'round', 'mitre', 'miter', 'bevel', not 'wobbly'",
          "a wobbly join: " + (wobbly.ok() ? std::string("accepted") : wobbly.error().message));
    Result<PolygonSet> butt = PolygonSet::buffer_polyline(Ring{Vec2{0, 0}}, 1, 16, "round", 5.0, "butt");
    check(!butt.ok() && butt.error().message == "polygon_set_buffer_polyline: cap must be one of 'round', 'flat', 'square', not 'butt'",
          "a butt cap: " + (butt.ok() ? std::string("accepted") : butt.error().message));
    CADACLYSM_TRY(disc, PolygonSet::buffer_polyline(Ring{Vec2{0, 0}}, 1));
    CADACLYSM_TRY(disc_area, disc.area());
    check(disc_area > 3.1 && disc_area < PI, "a point's round buffer: " + num(disc_area));
    return {};
}

static Result<void> and_profile_go_across_and_back() {
    CADACLYSM_TRY(outer, bs::Profile::circle(10));
    CADACLYSM_TRY(inner, bs::Profile::circle(4));
    CADACLYSM_TRY(washer, outer.with_hole(inner));
    CADACLYSM_TRY(s, PolygonSet::from_profile(washer, 1e-3));
    const double exact = PI * (100 - 16);
    CADACLYSM_TRY(s_area, s.area());
    CADACLYSM_TRY(s_polys, s.polygons());
    check(std::fabs(s_area - exact) < exact * 1e-3 && s_polys[0].holes.size() == 1, "the washer flattened: " + num(s_area));
    CADACLYSM_TRY(profiles, s.to_profiles());
    check(profiles.size() == 1, std::to_string(profiles.size()) + " profiles");
    if (profiles.size() == 1) {
        CADACLYSM_TRY(back, PolygonSet::from_profile(profiles[0], 1e-3));
        CADACLYSM_TRY(back_area, back.area());
        check(approx(back_area, s_area, 1e-9), "there and back: " + num(back_area) + " against " + num(s_area));
    }
    // A floor plan grown into walls: the room's outline thickened, then extruded.
    CADACLYSM_TRY(room, box(0, 0, 4, 3));
    CADACLYSM_TRY(thick, room.buffer(0.1, 16, "mitre"));
    CADACLYSM_TRY(walls, thick.difference(room));
    CADACLYSM_TRY(rings, walls.to_profiles());
    check(rings.size() == 1, std::to_string(rings.size()) + " wall profiles");
    if (rings.size() == 1) {
        CADACLYSM_TRY(xy, bs::Frame::xy());
        CADACLYSM_TRY(solid, bs::Solid::extrude(rings[0], xy, 2.5));
        CADACLYSM_TRY(mass, solid.mass());
        CADACLYSM_TRY(walls_area, walls.area());
        check(approx(mass.volume, walls_area * 2.5, 1e-12), "the walls extruded: " + num(mass.volume));
    }
    CADACLYSM_TRY(empty, PolygonSet::make());
    CADACLYSM_TRY(none, empty.to_profiles());
    check(none.empty(), "the empty set's profiles");
    Result<PolygonSet> negative = PolygonSet::from_profile(washer, -1.0);
    check(!negative.ok() && negative.error().message.rfind("profile_polygon_set: tolerance", 0) == 0,
          "a negative tolerance: " + (negative.ok() ? std::string("accepted") : negative.error().message));
    return {};
}

static Result<void> questions() {
    CADACLYSM_TRY(big, box(0, 0, 10, 10));
    CADACLYSM_TRY(small, box(4, 4, 6, 6));
    CADACLYSM_TRY(room, big.difference(small));
    CADACLYSM_TRY(where, room.locate(Ring{Vec2{1, 1}, Vec2{4, 5}, Vec2{5, 5}}));
    check(where == std::vector<int>{1, 0, -1}, "locate");
    CADACLYSM_TRY(corner, box(0, 0, 1, 1));
    CADACLYSM_TRY(surround, box(3, 3, 7, 7));
    CADACLYSM_TRY(across, box(4, 4, 6, 8));
    CADACLYSM_TRY(above, box(4, 6, 6, 8));
    CADACLYSM_TRY(c0, room.contains(corner));
    CADACLYSM_TRY(c1, room.contains(surround));
    CADACLYSM_TRY(c2, room.contains(across));
    CADACLYSM_TRY(c3, room.contains(above));
    check(c0 && !c1 && !c2 && c3, "contains");
    CADACLYSM_TRY(touching, box(10, 0, 12, 1));
    CADACLYSM_TRY(in_hole, box(4.5, 4.5, 5.5, 5.5));
    CADACLYSM_TRY(i0, room.intersects(touching));
    CADACLYSM_TRY(i1, room.intersects(in_hole));
    check(i0 && !i1, "intersects");
    CADACLYSM_TRY(p0, room.contains_polyline(Ring{Vec2{1, 1}, Vec2{9, 1}}));
    CADACLYSM_TRY(p1, room.contains_polyline(Ring{Vec2{1, 5}, Vec2{9, 5}}));
    CADACLYSM_TRY(p2, room.contains_polyline(Ring{Vec2{0, 0}, Vec2{10, 0}}));
    CADACLYSM_TRY(p3, room.intersects_polyline(Ring{Vec2{-1, 5}, Vec2{11, 5}}));
    check(p0 && !p1 && !p2 && p3, "polyline questions");
    CADACLYSM_TRY(inside, room.contains_point(Vec2{1, 1}));
    CADACLYSM_TRY(on, room.contains_point(Vec2{4, 5}));
    check(inside && !on, "contains_point");
    CADACLYSM_TRY(far, box(12, 0, 13, 1));
    CADACLYSM_TRY(d0, room.distance(far));
    CADACLYSM_TRY(d1, room.distance_to_point(Vec2{5, 5}));
    CADACLYSM_TRY(d2, room.boundary_distance(Vec2{1, 1}));
    CADACLYSM_TRY(d3, room.distance_to_polyline(Ring{Vec2{13, 0}, Vec2{13, 10}}));
    check(d0 == 2.0 && d1 == 1.0 && d2 == 1.0 && d3 == 3.0, "distances " + num(d0) + " " + num(d1) + " " + num(d2) + " " + num(d3));
    CADACLYSM_TRY(clipped, room.clip_polyline(Ring{Vec2{-1, 5}, Vec2{11, 5}}));
    check(clipped == std::vector<Ring>{Ring{Vec2{0, 5}, Vec2{4, 5}}, Ring{Vec2{6, 5}, Vec2{10, 5}}}, "clip_polyline");
    CADACLYSM_TRY(moved, room.transformed(0, -1, 1, 0, 1, 2));
    CADACLYSM_TRY(moved_area, moved.area());
    CADACLYSM_TRY(moved_bounds, moved.bounds());
    check(moved_area == 96.0 && moved_bounds.has_value() && *moved_bounds == Bounds{-9.0, 2.0, 1.0, 12.0}, "transformed");
    refused(PolygonSet::from_rings(Ring{Vec2{0, 0}, Vec2{1, 0}}), "ring 0 has 2 points", "a two-point ring");
    refused(room.locate(Ring{Vec2{0, 0}, Vec2{std::numeric_limits<double>::quiet_NaN(), 0}}), "point 1 is not finite", "a NaN point");
    return {};
}

static Result<void> lifetime() {
    CADACLYSM_TRY(s, box(0, 0, 1, 1));
    CADACLYSM_TRY(other, box(0, 0, 1, 1));
    s.close();
    s.close();
    check(s.closed(), "a closed set is closed");
    Result<double> area = s.area();
    check(!area.ok() && area.error().message == "PolygonSet: closed", "area after close");
    Result<PolygonSet> u = other.union_(s);
    check(!u.ok() && u.error().message == "PolygonSet: closed", "union with a closed set");
    Result<PolygonSet> all = PolygonSet::union_all(PolygonSets{other, s});
    check(!all.ok() && all.error().message == "PolygonSet: closed", "union_all with a closed set");
    PolygonSet moved = std::move(other);
    check(other.closed() && !moved.closed(), "a moved-from set is closed");
    CADACLYSM_TRY(moved_area, moved.area());
    check(moved_area == 1.0, "the moved set's area");
    check(moved.handle() != nullptr, "the moved set's handle");
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
        {"booleans_and_measures", booleans_and_measures},
        {"rings_come_back_as_shapelys", rings_come_back_as_shapelys},
        {"buffer_is_shapelys", buffer_is_shapelys},
        {"and_profile_go_across_and_back", and_profile_go_across_and_back},
        {"questions", questions},
        {"lifetime", lifetime},
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
    std::printf("polygon_set: ok\n");
    return 0;
}
