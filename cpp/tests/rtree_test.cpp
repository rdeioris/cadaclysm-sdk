// The R-tree -- at parity with the Python reference's test_rtree_*,
// test_closest_points_and_k_neighbors_match_brute_force and
// test_k_neighbors_reports_a_bad_point_before_a_bad_k in test_cadaclysm_blacksmith.py, trimmed to
// what proves the marshalling: every field read, every refusal's prefix, the lists' length and
// order, the handle's lifetime. The kernel's own correctness is the kernel's tests' job. Needs the
// kernel library; the exit code is the verdict.
//
//     cadaclysm_rtree_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <functional>
#include <limits>
#include <numeric>
#include <optional>
#include <string>
#include <utility>
#include <vector>

using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;
using bs::Box;
using bs::RTree;
using bs::RTreeHit;
using bs::RTreePair;
using bs::Vec3;

static int failures = 0;
static const double NAN_VALUE = std::numeric_limits<double>::quiet_NaN();
static const double INF_VALUE = std::numeric_limits<double>::infinity();

static void check(bool ok, const std::string& what) {
    if (ok) return;
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
}

// A refusal check that fails when nothing was refused: the call must have returned an error
// whose text starts with `prefix` and, if given, ends with `suffix`.
template <class T>
static void refused(const Result<T>& r, const std::string& prefix, const std::string& suffix, const std::string& what) {
    if (r.ok()) {
        check(false, what + ": expected a refusal, but the call succeeded");
        return;
    }
    const std::string& got = r.error().message;
    check(got.compare(0, prefix.size(), prefix) == 0, what + ": refused with \"" + got + "\", wanted it to start \"" + prefix + "\"");
    check(suffix.empty() || (got.size() >= suffix.size() && got.compare(got.size() - suffix.size(), suffix.size(), suffix) == 0),
          what + ": refused with \"" + got + "\", wanted it to end \"" + suffix + "\"");
}

// The same, for a refusal whose whole text is known.
template <class T>
static void refused_with(const Result<T>& r, const std::string& message, const std::string& what) {
    if (r.ok()) {
        check(false, what + ": expected a refusal, but the call succeeded");
        return;
    }
    check(r.error().message == message, what + ": refused with \"" + r.error().message + "\", wanted \"" + message + "\"");
}

static Box cell(double x0, double y0, double z0, double x1, double y1, double z1) {
    return Box(Vec3{x0, y0, z0}, Vec3{x1, y1, z1});
}

static double distance(const Vec3& a, const Vec3& b) {
    return std::sqrt((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]) + (a[2] - b[2]) * (a[2] - b[2]));
}

// The 10 x 10 x 10 grid of unit boxes, id 100 i + 10 j + k.
static std::vector<std::pair<std::uint32_t, Box>> grid() {
    std::vector<std::pair<std::uint32_t, Box>> cells;
    for (std::uint32_t i = 0; i < 10; ++i) {
        for (std::uint32_t j = 0; j < 10; ++j) {
            for (std::uint32_t k = 0; k < 10; ++k) {
                double x = i, y = j, z = k;
                cells.emplace_back(100 * i + 10 * j + k, cell(x, y, z, x + 1, y + 1, z + 1));
            }
        }
    }
    return cells;
}

static bool ascending(const std::vector<RTreePair>& pairs) {
    for (std::size_t i = 1; i < pairs.size(); ++i) {
        if (std::make_pair(pairs[i - 1].a, pairs[i - 1].b) > std::make_pair(pairs[i].a, pairs[i].b)) return false;
    }
    return true;
}

static std::vector<std::uint32_t> ids_of(const std::vector<RTreeHit>& hits) {
    std::vector<std::uint32_t> ids;
    for (const RTreeHit& h : hits) ids.push_back(h.id);
    return ids;
}

// 1
static Result<void> a_grid_packed_or_grown() {
    std::vector<std::pair<std::uint32_t, Box>> cells = grid();
    CADACLYSM_TRY(packed, RTree::from_boxes(cells));
    CADACLYSM_TRY(grown, RTree::make());
    for (std::size_t n = cells.size(); n-- > 0;) CADACLYSM_TRY_VOID(grown.insert(cells[n].first, cells[n].second));
    std::vector<std::uint32_t> corner;
    for (const std::pair<std::uint32_t, Box>& c : cells) {
        std::uint32_t id = c.first;
        if (id / 100 <= 2 && id / 10 % 10 <= 2 && id % 10 <= 2) corner.push_back(id);
    }
    check(corner.size() == 27, "27 corner cells");
    std::vector<std::vector<RTreePair>> answers;
    const std::pair<const char*, const RTree*> trees[] = {{"from_boxes", &packed}, {"insert", &grown}};
    for (const std::pair<const char*, const RTree*>& named : trees) {
        const std::string name = named.first;
        const RTree& tree = *named.second;
        check(tree.size() == 1000, name + ": size " + std::to_string(tree.size()));
        check(!tree.empty(), name + ": not empty");
        CADACLYSM_TRY(bounds, tree.bounds());
        check(bounds.has_value() && *bounds == cell(0, 0, 0, 10, 10, 10), name + ": bounds");
        CADACLYSM_TRY(found, tree.search(cell(0, 0, 0, 2, 2, 2)));
        check(found == corner, name + ": search the corner");
        CADACLYSM_TRY(near1, tree.nearest(Vec3{-1, -1, -1}, 1));
        check(near1.size() == 1 && near1[0].id == 0 && std::fabs(near1[0].distance - std::sqrt(3.0)) <= 1e-12,
              name + ": nearest the corner");
        CADACLYSM_TRY(at0, tree.within(Vec3{0, 0, 0}, 0.0));
        check(at0 == std::vector<RTreeHit>{RTreeHit{0, 0.0}}, name + ": within 0 of the origin");
        CADACLYSM_TRY(four, tree.within(Vec3{-1, -1, -1}, 2.5));
        check(ids_of(four) == std::vector<std::uint32_t>{0, 1, 10, 100}, name + ": within 2.5, by distance then id");
        CADACLYSM_TRY(pairs, tree.self_overlaps());
        check(pairs.size() == (28 * 28 * 28 - 1000) / 2, name + ": " + std::to_string(pairs.size()) + " self pairs");
        bool smaller_first = std::all_of(pairs.begin(), pairs.end(), [](const RTreePair& p) { return p.a < p.b; });
        check(smaller_first && ascending(pairs), name + ": a pair out of order");
        CADACLYSM_TRY(slack, tree.self_overlaps(0.5));
        check(slack == pairs, name + ": unit gaps paired at slack 0.5");
        answers.push_back(pairs);
    }
    check(answers[0] == answers[1], "the packed and the grown trees disagree");
    return {};
}

// 2
static Result<void> two_trees_and_one_twice() {
    CADACLYSM_TRY(packed, RTree::from_boxes(grid()));
    CADACLYSM_TRY(one, RTree::from_boxes({{7, cell(4.5, 4.5, 4.5, 5.5, 5.5, 5.5)}}));
    const std::uint32_t ids[] = {444, 445, 454, 455, 544, 545, 554, 555};
    std::vector<RTreePair> want;
    std::vector<RTreePair> back;
    for (std::uint32_t id : ids) {
        want.push_back(RTreePair{id, 7});
        back.push_back(RTreePair{7, id});
    }
    CADACLYSM_TRY(there, packed.overlaps(one));
    check(there == want, "the grid against one box");
    CADACLYSM_TRY(again, one.overlaps(packed, 0.0));
    check(again == back, "one box against the grid");
    CADACLYSM_TRY(twice, packed.overlaps(packed));
    check(twice.size() == 1000 + 2 * 10476, "the grid against itself: " + std::to_string(twice.size()));
    check(ascending(twice), "the grid against itself, ascending");
    return {};
}

// 3
static Result<void> points_insert_and_remove() {
    CADACLYSM_TRY(points, RTree::from_points({Vec3{0, 0, 0}, Vec3{5, 0, 0}, Vec3{1, 0, 0}, Vec3{0, 3, 0}}));
    check(points.size() == 4, "four points");
    CADACLYSM_TRY(two, points.search(cell(0.9, -0.1, -0.1, 1.1, 0.1, 0.1)));
    check(two == std::vector<std::uint32_t>{2}, "ids are the indices");
    CADACLYSM_TRY(near2, points.nearest(Vec3{4, 0, 0}, 2));
    check(near2 == std::vector<RTreeHit>{RTreeHit{1, 1.0}, RTreeHit{2, 3.0}}, "the two nearest points");

    CADACLYSM_TRY(tree, RTree::make());
    const Box unit = cell(3, 3, 3, 4, 4, 4);
    CADACLYSM_TRY_VOID(tree.insert(7, unit));
    CADACLYSM_TRY_VOID(tree.insert(7, unit));
    CADACLYSM_TRY(sevens, tree.search(unit));
    check(sevens == std::vector<std::uint32_t>{7, 7}, "one (id, box) twice is two entries");
    CADACLYSM_TRY(first, tree.remove(7, unit));
    CADACLYSM_TRY(second, tree.remove(7, unit));
    CADACLYSM_TRY(third, tree.remove(7, unit));
    check(first && second && !third, "remove: true, true, then false");
    CADACLYSM_TRY_VOID(tree.insert(7, unit));
    CADACLYSM_TRY(other_id, tree.remove(8, unit));
    check(!other_id, "another id took the entry out");
    CADACLYSM_TRY(other_box, tree.remove(7, cell(3, 3, 3, 4, 4, 4.5)));
    check(!other_box, "another box took the entry out");
    const Vec3 point{1, 2, 3};
    CADACLYSM_TRY_VOID(tree.insert(9, point));
    check(tree.size() == 2, "a point and a box");
    CADACLYSM_TRY(both, tree.bounds());
    check(both.has_value() && *both == Box(point, Vec3{4, 4, 4}), "the bounds of a point and a box");
    CADACLYSM_TRY(point_gone, tree.remove(9, point));
    CADACLYSM_TRY(box_gone, tree.remove(7, unit));
    check(point_gone && box_gone, "the point or the box stayed");
    CADACLYSM_TRY(none, tree.bounds());
    check(tree.size() == 0 && tree.empty() && !none.has_value(), "emptied");
    const std::uint32_t largest = std::numeric_limits<std::uint32_t>::max();
    CADACLYSM_TRY_VOID(tree.insert(largest, point));
    CADACLYSM_TRY(whole, tree.search(cell(0, 0, 0, 5, 5, 5)));
    check(whole == std::vector<std::uint32_t>{largest}, "the largest id came back whole");
    CADACLYSM_TRY(largest_gone, tree.remove(largest, point));
    check(largest_gone, "the largest id removed");
    return {};
}

// 4
static Result<void> point_neighbours() {
    std::uint64_t state = 5;
    std::function<double()> next = [&state]() {
        state = state * 6364136223846793005ULL + 1442695040888963407ULL;
        return static_cast<double>(state >> 11) / static_cast<double>(std::uint64_t(1) << 53);
    };
    std::vector<Vec3> hay;
    for (int i = 0; i < 30; ++i) {
        double x = 10 * next(), y = 10 * next(), z = 10 * next();
        hay.push_back(Vec3{x, y, z});
    }
    std::vector<Vec3> needles;
    for (int i = 0; i < 5; ++i) {
        double x = 10 * next(), y = 10 * next(), z = 10 * next();
        needles.push_back(Vec3{x, y, z});
    }
    std::function<std::vector<std::size_t>(const Vec3&)> by_distance = [&hay](const Vec3& q) {
        std::vector<std::size_t> order(hay.size());
        std::iota(order.begin(), order.end(), std::size_t(0));
        std::sort(order.begin(), order.end(), [&](std::size_t x, std::size_t y) {
            double dx = distance(hay[x], q), dy = distance(hay[y], q);
            return dx != dy ? dx < dy : x < y;
        });
        return order;
    };
    CADACLYSM_TRY(closest, bs::closest_points(hay, needles, 3.0));
    CADACLYSM_TRY(knn, bs::k_neighbors(hay, needles, 4));
    check(closest.size() == 5 && knn.size() == 5, "one answer per needle");
    bool some = false, all = true;
    for (std::size_t n = 0; n < needles.size() && n < closest.size() && n < knn.size(); ++n) {
        std::vector<std::size_t> order = by_distance(needles[n]);
        std::vector<std::size_t> in_limit;
        for (std::size_t i : order) {
            if (distance(hay[i], needles[n]) <= 3.0) in_limit.push_back(i);
        }
        check(closest[n] == in_limit, "closest points, needle " + std::to_string(n));
        check(knn[n] == std::vector<std::size_t>(order.begin(), order.begin() + 4), "k neighbors, needle " + std::to_string(n));
        some = some || !in_limit.empty();
        all = all && in_limit.size() == hay.size();
    }
    check(some && !all, "the limit chose nothing or everything");
    std::vector<Vec3> first_two(needles.begin(), needles.begin() + 2);
    CADACLYSM_TRY(every, bs::k_neighbors(hay, first_two, 500));
    check(every.size() == 2 && every[1] == by_distance(needles[1]), "k over the hay count is every point");
    CADACLYSM_TRY(empty_hay, bs::k_neighbors({}, first_two, 3));
    check(empty_hay == std::vector<std::vector<std::size_t>>(2), "an empty hay");
    return {};
}

// 5
static Result<void> refusals() {
    CADACLYSM_TRY(tree, RTree::make());
    refused(tree.insert(1, cell(0, 0, 0, NAN_VALUE, 1, 1)), "rtree_insert: ", "is not a box", "insert a NaN box");
    refused(tree.insert(1, cell(1, 0, 0, 0, 1, 1)), "rtree_insert: ", "is not a box", "insert an inverted box");
    refused(tree.insert(1, Vec3{INF_VALUE, 0, 0}), "rtree_insert_point: ", "is not finite", "insert an infinite point");
    check(tree.size() == 0, "a refused insert changed the tree");
    refused(tree.remove(1, cell(1, 0, 0, 0, 1, 1)), "rtree_remove: ", "", "remove an inverted box");
    CADACLYSM_TRY(absent, tree.remove(1, cell(0, 0, 0, 1, 1, 1)));
    check(!absent, "absent right after a refusal");
    refused(tree.search(cell(0, 0, 0, NAN_VALUE, 1, 1)), "rtree_search: ", "", "search a NaN box");
    refused(tree.within(Vec3{NAN_VALUE, 0, 0}, 1.0), "rtree_within: ", "is not finite", "within a NaN point");
    refused(tree.nearest(Vec3{NAN_VALUE, 0, 0}, 1), "rtree_nearest: ", "is not finite", "nearest a NaN point");
    refused_with(tree.within(Vec3{0, 0, 0}, -1.0), "rtree_within: radius -1 is not a distance", "within -1");
    refused_with(tree.self_overlaps(NAN_VALUE), "rtree_self_overlaps: slack NaN is not a distance", "self overlaps at NaN");
    refused(tree.overlaps(tree, -0.5), "rtree_overlaps: ", "", "overlaps at -0.5");
    refused_with(tree.nearest(Vec3{0, 0, 0}, 1000001), "rtree_nearest: k 1000001 is not at most 1000000", "nearest k 1000001");
    refused(RTree::from_boxes({{1, cell(0, 0, 0, 1, 1, 1)}, {2, cell(2, 0, 0, 1, 1, 1)}}), "rtree_from_boxes: entry 1", "",
            "from_boxes, entry 1 bad");
    refused_with(RTree::from_points({Vec3{0, 0, 0}, Vec3{0, NAN_VALUE, 0}}), "rtree_from_points: point 1 is not finite",
                 "from_points, point 1 bad");

    const std::vector<Vec3> origin{Vec3{0, 0, 0}};
    refused_with(bs::closest_points(origin, origin, -1.0), "closest_points: limit -1 is not a distance", "closest points, limit -1");
    refused_with(bs::closest_points({Vec3{0, 0, 0}, Vec3{NAN_VALUE, 0, 0}}, {Vec3{INF_VALUE, 0, 0}}, -1.0),
                 "closest_points: limit -1 is not a distance", "the limit first");
    refused_with(bs::closest_points(origin, {Vec3{NAN_VALUE, 0, 0}}, 1.0), "closest_points: needle point 0 is not finite",
                 "closest points, a NaN needle");
    refused_with(bs::closest_points({Vec3{0, 0, 0}, Vec3{0, 0, NAN_VALUE}}, {Vec3{NAN_VALUE, 0, 0}}, 1.0),
                 "closest_points: hay point 1 is not finite", "the hay before the needles");
    refused_with(bs::k_neighbors({Vec3{0, 0, 0}, Vec3{INF_VALUE, 0, 0}}, origin, 1000001), "k_neighbors: hay point 1 is not finite",
                 "the points before k");
    refused_with(bs::k_neighbors(origin, origin, 1000001), "k_neighbors: k 1000001 is not at most 1000000", "k neighbors, k 1000001");

    // A number in a message prints as Rust's {} prints an f64: the shortest round-trip digits,
    // never an exponent.
    const std::pair<double, std::string> numbers[] = {
        {1e20, "100000000000000000000"}, {-1e-7, "-0.0000001"}, {1.5, "1.5"}, {-1.0, "-1"},
        {0.1 + 0.2, "0.30000000000000004"}, {-0.0, "-0"}, {NAN_VALUE, "NaN"}, {INF_VALUE, "inf"},
        {-INF_VALUE, "-inf"}, {5e-324, "0." + std::string(323, '0') + "5"}, {1e-323, "0." + std::string(322, '0') + "1"},
        {1e16, "10000000000000000"}, {-1.2345678901234568e17, "-123456789012345680"}, {1e21, "1000000000000000000000"},
        {0.000123, "0.000123"}, {-2.5e-5, "-0.000025"},
    };
    for (const std::pair<double, std::string>& n : numbers) {
        const std::string shown = bs::detail::rust_number(n.first);
        check(shown == n.second, "rust_number printed \"" + shown + "\", wanted \"" + n.second + "\"");
    }
    refused_with(bs::closest_points(origin, origin, -1e-7), "closest_points: limit -0.0000001 is not a distance", "limit -1e-7");
    refused_with(bs::closest_points(origin, origin, -1e20), "closest_points: limit -100000000000000000000 is not a distance",
                 "limit -1e20");
    return {};
}

// 6
static Result<void> lifetime() {
    CADACLYSM_TRY(other, RTree::from_boxes(grid()));
    CADACLYSM_TRY(empty, RTree::make());
    CADACLYSM_TRY(bounds, empty.bounds());
    check(empty.size() == 0 && empty.empty() && !bounds.has_value(), "an empty tree: size 0, no bounds");
    CADACLYSM_TRY(found, empty.search(cell(0, 0, 0, 1, 1, 1)));
    CADACLYSM_TRY(close_by, empty.within(Vec3{0, 0, 0}, 10.0));
    CADACLYSM_TRY(nearest, empty.nearest(Vec3{0, 0, 0}, 3));
    CADACLYSM_TRY(self_pairs, empty.self_overlaps());
    CADACLYSM_TRY(to_other, empty.overlaps(other));
    CADACLYSM_TRY(from_other, other.overlaps(empty));
    check(found.empty() && close_by.empty() && nearest.empty() && self_pairs.empty() && to_other.empty() && from_other.empty(),
          "an empty tree answers nothing");
    CADACLYSM_TRY(no_boxes, RTree::from_boxes({}));
    CADACLYSM_TRY(no_points, RTree::from_points({}));
    check(no_boxes.empty() && no_points.empty(), "empty from_boxes and from_points");

    RTree moved = std::move(empty);
    check(empty.closed() && !moved.closed(), "a move hands the handle over");
    refused_with(empty.search(cell(0, 0, 0, 1, 1, 1)), "rtree: closed", "a moved-from tree");
    check(!moved.closed(), "open");
    moved.close();
    moved.close();
    check(moved.closed(), "close() twice");
    refused_with(moved.bounds(), "rtree: closed", "bounds after close");
    refused_with(moved.insert(1, Vec3{0, 0, 0}), "rtree: closed", "insert after close");
    refused_with(moved.remove(1, Vec3{0, 0, 0}), "rtree: closed", "remove after close");
    refused_with(moved.within(Vec3{0, 0, 0}, 1.0), "rtree: closed", "within after close");
    refused_with(moved.self_overlaps(), "rtree: closed", "self overlaps after close");
    refused_with(other.overlaps(moved), "rtree: closed", "overlaps against a closed tree");
    check(other.size() == 1000, "the other tree is untouched");
    return {};
}

// Rays, triangle trees and a solid's face tree (rtree plan 6): Python's test_rtree_ray_*,
// test_rtree_from_triangles_* and test_solid_face_tree_*, trimmed.
static std::vector<RTreeHit> hits(const std::vector<std::pair<std::uint32_t, double>>& rows) {
    std::vector<RTreeHit> out;
    for (const std::pair<std::uint32_t, double>& row : rows) {
        RTreeHit h;
        h.id = row.first;
        h.distance = row.second;
        out.push_back(h);
    }
    return out;
}

// 7
static Result<void> a_ray_through_a_row() {
    std::vector<std::pair<std::uint32_t, Box>> cells;
    std::vector<std::pair<std::uint32_t, double>> every;
    for (std::uint32_t i = 0; i < 10; ++i) {
        double x = i;
        cells.push_back({i, cell(x, 0, 0, x + 1, 1, 1)});
        every.push_back({i, x + 1});
    }
    CADACLYSM_TRY(row, RTree::from_boxes(cells));
    const Vec3 start{-1, 0.5, 0.5};
    const Vec3 x{1, 0, 0};
    CADACLYSM_TRY(along, row.ray(start, x));
    check(along == hits(every), "the whole row, entry t per box");
    CADACLYSM_TRY(scaled, row.ray(start, Vec3{2, 0, 0}, 1.0));
    check(scaled == hits({{0, 0.5}, {1, 1.0}}), "t in units of the direction");
    CADACLYSM_TRY(cut, row.ray(start, x, 3.0));
    check(cut == hits({{0, 1.0}, {1, 2.0}, {2, 3.0}}), "max_t cuts the row");
    CADACLYSM_TRY(inside, row.ray(Vec3{2.5, 0.5, 0.5}, x, 1.0));
    check(inside == hits({{2, 0.0}, {3, 0.5}}), "from inside: 0");
    CADACLYSM_TRY(back, row.ray(Vec3{11, 0.5, 0.5}, Vec3{-1, 0, 0}, 2.0));
    check(back == hits({{9, 1.0}, {8, 2.0}}), "backwards");
    CADACLYSM_TRY(graze, row.ray(Vec3{-1, 1, 0.5}, x));
    check(graze.size() == 10, "grazing the top face counts");
    CADACLYSM_TRY(above, row.ray(Vec3{-1, 1 + 1e-12, 0.5}, x));
    check(above.empty(), "a ray above the row met it");
    CADACLYSM_TRY(empty, RTree::make());
    CADACLYSM_TRY(none, empty.ray(start, x));
    check(none.empty(), "an empty tree");

    refused_with(row.ray(Vec3{0, 0, 0}, Vec3{0, 0, 0}), "rtree_ray: direction (0, 0, 0) is not a direction", "a zero direction");
    refused_with(row.ray(Vec3{0, 0, 0}, x, -1.0), "rtree_ray: max_t -1 is not a distance", "max_t -1");
    refused_with(row.ray(Vec3{0, 0, 0}, x, NAN_VALUE), "rtree_ray: max_t NaN is not a distance", "max_t NaN");
    refused_with(row.ray(Vec3{NAN_VALUE, 0, 0}, x), "rtree_ray: origin (NaN, 0, 0) is not finite", "a NaN origin");
    refused_with(row.ray(Vec3{0, 0, 0}, Vec3{INF_VALUE, 0, 0}), "rtree_ray: direction (inf, 0, 0) is not finite",
                 "an infinite direction");
    row.close();
    refused_with(row.ray(start, x), "rtree: closed", "ray after close");
    return {};
}

// 8
static Result<void> from_triangles_boxes_each_triangle() {
    const std::vector<Vec3> positions{Vec3{0, 0, 0}, Vec3{2, 0, 0}, Vec3{0, 3, 0}, Vec3{NAN_VALUE, 0, 0}, Vec3{5, 1, 4}};
    const std::vector<std::array<std::uint32_t, 3>> triangles{{0, 1, 2}, {1, 4, 1}};
    CADACLYSM_TRY(tree, RTree::from_triangles(positions, triangles));
    check(tree.size() == 2, "two triangles");
    CADACLYSM_TRY(bounds, tree.bounds());
    check(bounds.has_value() && *bounds == cell(0, 0, 0, 5, 3, 4), "point 3 is used by no triangle");
    CADACLYSM_TRY(first, tree.search(cell(1, 1, 0, 1, 1, 0)));
    check(first == std::vector<std::uint32_t>{0}, "ids are the triangle indices");
    CADACLYSM_TRY(second, tree.search(cell(4, 0.5, 2, 4, 0.5, 2)));
    check(second == std::vector<std::uint32_t>{1}, "the second triangle");
    CADACLYSM_TRY(through, tree.ray(Vec3{-1, 0.5, 0}, Vec3{1, 0, 0}));
    check(through == hits({{0, 1.0}, {1, 3.0}}), "a ray through both");
    CADACLYSM_TRY(none, RTree::from_triangles({}, {}));
    check(none.empty(), "no triangles");
    const std::vector<Vec3> four(4, Vec3{0, 0, 0});
    refused_with(RTree::from_triangles(four, {{0, 1, 2}, {0, 4, 1}}), "rtree_from_triangles: triangle 1 names point 4 of 4",
                 "an index past the points");
    refused_with(RTree::from_triangles({Vec3{0, 0, 0}, Vec3{0, INF_VALUE, 0}}, {{0, 1, 0}}),
                 "rtree_from_triangles: triangle 0 point 1 is not finite", "an infinite corner");
    return {};
}

// 9
static Result<void> a_cuboids_face_tree() {
    std::optional<RTree> kept;
    {
        CADACLYSM_TRY(cuboid, bs::Solid::cuboid(3, 4, 5));
        CADACLYSM_TRY(faces, cuboid.face_tree());
        check(faces.size() == 6, "six faces");
        const double grow = 5 * 1e-3;
        CADACLYSM_TRY(bounds, faces.bounds());
        check(bounds.has_value(), "a face tree's bounds");
        if (bounds) {
            const Vec3 lo{-1.5 - grow, -2 - grow, -2.5 - grow};
            const Vec3 hi{1.5 + grow, 2 + grow, 2.5 + grow};
            for (std::size_t a = 0; a < 3; ++a) {
                check(std::fabs(bounds->lo[a] - lo[a]) <= 1e-9 && std::fabs(bounds->hi[a] - hi[a]) <= 1e-9,
                      "the face tree's bounds, axis " + std::to_string(a));
            }
        }
        CADACLYSM_TRY(corner, faces.search(cell(1.4, 1.9, 2.4, 1.6, 2.1, 2.6)));
        check(corner.size() == 3, "three faces at a corner");
        CADACLYSM_TRY(shot, faces.ray(Vec3{10, 0, 0}, Vec3{-1, 0, 0}));
        check(shot.size() == 2, "a ray through two faces, got " + std::to_string(shot.size()));
        if (shot.size() == 2) {
            check(std::fabs(shot[0].distance - (8.5 - grow)) <= 1e-9 && std::fabs(shot[1].distance - (11.5 - grow)) <= 1e-9,
                  "the entry t of each face");
            // The +x face is the one the ray met first: a face call by that index agrees.
            CADACLYSM_TRY(frame, cuboid.face_frame(shot[0].id));
            const Vec3 normal = frame.z();
            check(std::fabs(normal[0] - 1) <= 1e-9 && std::fabs(normal[1]) <= 1e-9 && std::fabs(normal[2]) <= 1e-9,
                  "the first face met is the +x face");
        }
        kept.emplace(std::move(faces));
    }
    // The tree is its own: it outlives the solid.
    check(kept->size() == 6, "the face tree outlived its solid");
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
        {"a_grid_packed_or_grown", a_grid_packed_or_grown},
        {"two_trees_and_one_twice", two_trees_and_one_twice},
        {"points_insert_and_remove", points_insert_and_remove},
        {"point_neighbours", point_neighbours},
        {"refusals", refusals},
        {"lifetime", lifetime},
        {"a_ray_through_a_row", a_ray_through_a_row},
        {"from_triangles_boxes_each_triangle", from_triangles_boxes_each_triangle},
        {"a_cuboids_face_tree", a_cuboids_face_tree},
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
    std::printf("rtree: ok\n");
    return 0;
}
