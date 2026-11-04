// Health and healing -- Solid::health / healed / edge_tolerance on the kernel and
// Brep::health / healed / edge_tolerance on the reader -- at parity with the Python
// reference's test_health_* / test_healed_* in test_cadaclysm_blacksmith.py and
// test_brep_health_* / test_brep_healed_* in test_cadaclysm.py, with the same figures, plus
// their distinct-rows decoder tests on each header's own decoder. The reader half opens
// st203-bapl.stp's body 1 (the 188-free-edge one; body 0 takes minutes) and is skipped
// when the path is "-" or missing. The exit code is the verdict.
//
//     cadaclysm_healing_test <st203-bapl.stp | -> [cadaclysm.lic]
#include <csetjmp>
#include <cstdio>
#include <cstdlib>
#include <string>

#if defined(_MSC_VER)
#pragma warning(disable : 4611)  // setjmp and C++ destruction: only trivially destructible locals cross it
#endif

// A closed solid is a bad access. The hook below turns it into a longjmp back to `trips`,
// so the test can see it (the default aborts).
namespace trap {
inline std::jmp_buf* where = nullptr;
inline std::string message;
}  // namespace trap
#define CADACLYSM_BAD_ACCESS(text) \
    (::trap::message = (text), ::trap::where ? std::longjmp(*::trap::where, 1) : std::abort())

#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <limits>
#include <optional>
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

// The value of a call the test cannot go on without; anything else ends the run.
template <class T>
static T must(Result<T> r, const char* what) {
    if (!r) {
        std::fprintf(stderr, "FAIL: %s: %s\n", what, r.error().message.c_str());
        std::exit(1);
    }
    return std::move(r).value();
}

// Whether `f` reached CADACLYSM_BAD_ACCESS.
template <class F>
static bool trips(F&& f) {
    std::jmp_buf buffer;
    trap::where = &buffer;
    trap::message.clear();
    if (setjmp(buffer) == 0) {
        f();
        trap::where = nullptr;
        return false;
    }
    trap::where = nullptr;
    return true;
}

static bool rel(double a, double b, double r) { return std::fabs(a - b) <= r * std::fabs(b); }
// pytest.approx's default: rel 1e-6.
static bool approx(double a, double b) { return rel(a, b, 1e-6); }

static const std::uint32_t NONE = 0xFFFFFFFFu;
static const double INF = std::numeric_limits<double>::infinity();

static std::string opt(const std::optional<std::uint32_t>& v) { return v ? std::to_string(*v) : std::string("none"); }

// ---- kernel: Solid ------------------------------------------------------------------

static void a_closed_cuboid_has_nothing_free_and_cracks_only_on_request() {
    bs::Solid box = must(bs::Solid::cuboid(10, 10, 10), "cuboid");
    bs::HealthReport report = must(box.health(), "health");
    check(report.free_edges.empty() && report.wires.empty() && report.small.empty(), "a closed cuboid has nothing free or small");
    check(!report.cracks.has_value(), "no cracks without the mesh");
    double extent = 10.0 * std::sqrt(3.0);
    check(rel(report.extent, extent, 1e-12), "extent " + std::to_string(report.extent));
    check(rel(report.rounding, 1e-7 * report.extent, 1e-12), "rounding " + std::to_string(report.rounding));
    check(rel(report.tolerance, 1e-4 * report.extent, 1e-12), "tolerance " + std::to_string(report.tolerance));
    check(report.loose_edges == 0 && report.worst_loose == 0.0 && report.sew_pairs == 0 && report.sew_refused == 0 &&
              report.sew_worst_gap == 0.0,
          "nothing loose and nothing to sew on a closed box");
    bs::HealthReport meshed = must(box.health(std::nullopt, true), "health(mesh)");
    check(meshed.cracks.has_value() && meshed.cracks->watertight, "the meshed cuboid is watertight");
    if (meshed.cracks) {
        check(meshed.cracks->open == 0 && meshed.cracks->folded == 0 && meshed.cracks->crossings == 0,
              "nothing open, folded or crossing");
        check(meshed.cracks->edges.empty(), "no crack edges");
    }
    check(must(box.health(0.5), "health(0.5)").tolerance == 0.5, "health(0.5) judges at 0.5");
    check(must(box.health(-1.0), "health(-1)").tolerance == report.tolerance, "health(-1) takes the default");
}

static void a_cuboid_without_a_face_is_one_open_rim_of_four_edges() {
    bs::Solid hole = must(must(bs::Solid::cuboid(10, 10, 10), "cuboid").drop_faces({0}), "drop_faces");
    bs::HealthReport report = must(hole.health(), "health");
    check(report.free_edges.size() == 4 && report.wires.size() == 1,
          "4 free edges and one wire, not " + std::to_string(report.free_edges.size()) + " and " + std::to_string(report.wires.size()));
    if (report.free_edges.size() != 4 || report.wires.size() != 1) return;
    const bs::FreeWire& wire = report.wires[0];
    check(wire.first == 0 && wire.count == 4 && wire.closed, "the wire is (0, 4, closed)");
    check(approx(wire.length, 40.0), "the wire is 40 long");
    const std::uint32_t want[4][4] = {{4, 3, 1, 2}, {16, 2, 4, 3}, {11, 1, 2, 0}, {15, 0, 3, 1}};
    for (std::size_t i = 0; i < 4; ++i) {
        const bs::FreeEdge& e = report.free_edges[i];
        check(e.trim == want[i][0] && e.edge == std::optional<std::uint32_t>(want[i][1]) && e.face == want[i][2] &&
                  e.partner == std::optional<std::uint32_t>(want[i][3]),
              "free edge " + std::to_string(i) + " reads (" + std::to_string(e.trim) + ", " + opt(e.edge) + ", " +
                  std::to_string(e.face) + ", " + opt(e.partner) + ")");
        check(e.wire == 0 && e.shared_ends == 0, "free edge " + std::to_string(i) + " is on wire 0, sharing no end");
        check(approx(e.length, 10.0) && approx(e.gap, 10.0), "free edge " + std::to_string(i) + " is 10 long, 10 from its partner");
    }
    check(approx(report.worst_gap, 10.0), "worst_gap " + std::to_string(report.worst_gap));
    std::vector<bs::FreeEdge> edges = must(report.wire_edges(0), "wire_edges");
    check(edges.size() == 4, "wire 0 holds the four rows");
    for (std::size_t i = 0; i < edges.size() && i < 4; ++i) {
        check(edges[i].trim == report.free_edges[i].trim, "wire 0's row " + std::to_string(i));
    }
    check(!report.wire_edges(1).ok(), "wire_edges(1) is refused: there is one wire");
    check(report.sew_pairs == 0 && report.sew_refused == 0 && report.sew_worst_gap == 0.0 && report.loose_edges == 0,
          "nothing to sew on the rim");
    std::optional<bs::Cracks> cracks = must(hole.health(std::nullopt, true), "health(mesh)").cracks;
    check(cracks.has_value() && !cracks->watertight, "a sheet is not watertight");
    if (cracks) {
        check(cracks->open == 0 && cracks->folded == 0 && cracks->crossings == 0 && cracks->edges.empty(),
              "an open body's crack census is empty");
    }
}

static const char* const PLATE_KINDS[8] = {"short_edge",  "short_edge",  "short_edge",  "short_edge",
                                           "sliver_face", "sliver_face", "sliver_face", "sliver_face"};
static const std::uint32_t PLATE_INDICES[8] = {8, 9, 10, 11, 2, 3, 4, 5};

static void a_thin_plate_lists_its_small_features_by_kind_index_and_size() {
    bs::Solid plate = must(bs::Solid::cuboid(10, 10, 0.001), "cuboid");
    bs::HealthReport report = must(plate.health(0.01), "health(0.01)");
    check(report.small.size() == 8, std::to_string(report.small.size()) + " small features, not 8");
    for (std::size_t i = 0; i < report.small.size() && i < 8; ++i) {
        const bs::SmallFeature& s = report.small[i];
        check(s.kind == PLATE_KINDS[i] && s.index == PLATE_INDICES[i],
              "small " + std::to_string(i) + " reads " + s.kind + " " + std::to_string(s.index));
        if (i < 4) check(approx(s.size, 0.001), "short edge size " + std::to_string(s.size));
        else check(rel(s.size, 0.0009999, 1e-3), "sliver size " + std::to_string(s.size));
    }
}

static void a_tiny_body_and_its_tiny_faces() {
    bs::Solid tiny = must(bs::Solid::cuboid(0.0005, 0.0005, 0.0005), "cuboid");
    bs::HealthReport report = must(tiny.health(0.01), "health(0.01)");
    std::vector<bs::SmallFeature> shorts;
    std::vector<bs::SmallFeature> faces;
    std::vector<bs::SmallFeature> bodies;
    for (const bs::SmallFeature& s : report.small) {
        if (s.kind == "short_edge") shorts.push_back(s);
        else if (s.kind == "tiny_face") faces.push_back(s);
        else if (s.kind == "tiny_body") bodies.push_back(s);
        else check(false, "an unexpected kind " + s.kind);
    }
    check(shorts.size() == 12 && faces.size() == 6 && bodies.size() == 1,
          "12 short edges, 6 tiny faces, 1 tiny body; got " + std::to_string(shorts.size()) + ", " + std::to_string(faces.size()) +
              ", " + std::to_string(bodies.size()));
    for (std::size_t i = 0; i < faces.size(); ++i) {
        check(faces[i].index == i, "tiny face " + std::to_string(i) + " is face " + std::to_string(faces[i].index));
        check(approx(faces[i].size, 2.5e-7), "tiny face size " + std::to_string(faces[i].size));
    }
    if (bodies.size() == 1) {
        check(bodies[0].index == 0 && rel(bodies[0].size, 0.0005 * std::sqrt(3.0), 1e-9), "the tiny body is body 0, 0.0005 sqrt 3 across");
    }
}

static void a_healed_cuboid_heals_to_itself_as_a_new_solid() {
    bs::Solid box = must(bs::Solid::cuboid(10, 10, 10), "cuboid");
    std::pair<bs::Solid, bs::HealReport> out = must(box.healed(), "healed");
    const bs::Solid& healed = out.first;
    const bs::HealReport& report = out.second;
    check(healed.handle() != box.handle(), "the healed solid is a new one");
    check(report.fixes.empty() && report.refused.empty() && !report.guarded, "nothing fixed, refused or guarded");
    check(report.small_before == 0 && report.small_after == 0 && report.free_before == 0 && report.free_after == 0,
          "no small or free before or after");
    check(report.closed_before && report.closed_after, "closed before and after");
    check(report.nonmanifold_before == 0 && report.nonmanifold_after == 0, "no non-manifold edges");
    check(rel(report.tolerance, must(box.health(), "health").tolerance, 1e-12) && report.moved == 0.0,
          "healed at health's tolerance, nothing moved");
    check(healed.faces() == 6 && box.faces() == 6, "six faces");
    check(approx(must(healed.mass(), "mass").volume, 1000.0), "volume 1000");
    check(must(box.healed(0.5), "healed(0.5)").second.tolerance == 0.5, "healed(0.5) heals at 0.5");
    for (std::uint32_t e = 0; e < 12; ++e) {
        std::optional<double> t = must(healed.edge_tolerance(e), "edge_tolerance");
        check(t == std::optional<double>(0.0), "edge " + std::to_string(e) + " is exact");
    }
    check(!must(healed.edge_tolerance(0xFFFFFFF0u), "edge_tolerance").has_value(), "an id no trim names has no tolerance");
}

static void healed_with_every_kind_off_refuses_each_small_feature_as_toggled() {
    bs::Solid plate = must(bs::Solid::cuboid(10, 10, 0.001), "cuboid");
    bs::HealReport report = must(plate.healed(0.01, false, false, false), "healed(off)").second;
    check(report.fixes.empty() && report.small_before == 8 && report.small_after == 8,
          "nothing fixed, 8 small before and after; got " + std::to_string(report.small_before) + " and " +
              std::to_string(report.small_after));
    check(report.refused.size() == 8, std::to_string(report.refused.size()) + " refused, not 8");
    for (std::size_t i = 0; i < report.refused.size() && i < 8; ++i) {
        const bs::HealRefusal& r = report.refused[i];
        check(r.kind == PLATE_KINDS[i] && r.index == PLATE_INDICES[i] && r.why == "toggled" && r.figure == 0.0,
              "refusal " + std::to_string(i) + " reads (" + r.kind + ", " + std::to_string(r.index) + ", " + r.why + ", " +
                  std::to_string(r.figure) + ")");
    }
    bs::HealReport on = must(plate.healed(0.01), "healed(on)").second;
    check(on.small_before == 8, "8 small before with every kind on");
    for (const bs::HealRefusal& r : on.refused) {
        check(r.why != "toggled", "nothing toggled with every kind on");
        if (on.guarded) check(r.why == "body_guard", "a guarded heal refuses as body_guard");
    }
}

static void a_closed_solid_is_refused() {
    bs::Solid box = must(bs::Solid::cuboid(1, 1, 1), "cuboid");
    box.close();
    check(trips([&] { (void)box.health(); }) && trap::message.find("closed") != std::string::npos,
          "health on a closed solid: " + trap::message);
    check(trips([&] { (void)box.healed(); }) && trap::message.find("closed") != std::string::npos,
          "healed on a closed solid: " + trap::message);
    check(trips([&] { (void)box.edge_tolerance(0); }) && trap::message.find("closed") != std::string::npos,
          "edge_tolerance on a closed solid: " + trap::message);
}

// ---- the decoders, over Python's distinct rows ----------------------------------------

template <class Report, class Edge>
static void check_health_rows(const Report& r, const char* who) {
    std::string w(who);
    check(r.tolerance == 0.5 && r.rounding == 0.25 && r.extent == 9.0 && r.worst_gap == 7.5, w + ": the sizes");
    check(r.loose_edges == 3 && r.worst_loose == 6.5 && r.sew_pairs == 4 && r.sew_refused == 5 && r.sew_worst_gap == 5.5,
          w + ": the loose and sew figures");
    check(r.free_edges.size() == 2, w + ": two free edges");
    if (r.free_edges.size() == 2) {
        const Edge& a = r.free_edges[0];
        const Edge& b = r.free_edges[1];
        check(a.trim == 10 && a.edge == std::optional<std::uint32_t>(20) && a.face == 30 && a.wire == 40 &&
                  a.partner == std::optional<std::uint32_t>(1) && a.shared_ends == 2 && a.length == 1.5 && a.gap == 2.5,
              w + ": free edge 0 reads (" + std::to_string(a.trim) + ", " + opt(a.edge) + ", " + std::to_string(a.face) + ", " +
                  std::to_string(a.wire) + ", " + opt(a.partner) + ", " + std::to_string(a.shared_ends) + ")");
        check(b.trim == 11 && !b.edge && b.face == 31 && b.wire == 41 && !b.partner && b.shared_ends == 0 && b.length == 3.5 &&
                  b.gap == INF,
              w + ": free edge 1 reads (" + std::to_string(b.trim) + ", " + opt(b.edge) + ", " + std::to_string(b.face) + ", " +
                  std::to_string(b.wire) + ", " + opt(b.partner) + ", " + std::to_string(b.shared_ends) + ")");
    }
    check(r.wires.size() == 1 && r.wires[0].first == 0 && r.wires[0].count == 2 && r.wires[0].closed && r.wires[0].length == 8.5 &&
              r.wires[0].widest_gap == 2.5,
          w + ": the wire");
    check(r.small.size() == 2 && r.small[0].kind == "collapsed_edge" && r.small[0].index == 77 && r.small[0].size == 0.125 &&
              r.small[1].kind == "tiny_body" && r.small[1].index == 99 && r.small[1].size == 0.0625,
          w + ": the small features");
    check(r.cracks.has_value() && !r.cracks->watertight && r.cracks->open == 11 && r.cracks->folded == 12 &&
              r.cracks->crossings == 13 && r.cracks->edges == std::vector<std::uint32_t>{5, 6},
          w + ": the cracks");
}

template <class Report>
static void check_heal_rows(const Report& r, const char* who) {
    std::string w(who);
    check(r.tolerance == 0.5 && r.moved == 0.25 && r.guarded, w + ": tolerance, moved, guarded");
    check(r.small_before == 9 && r.small_after == 8 && r.free_before == 7 && r.free_after == 6,
          w + ": small " + std::to_string(r.small_before) + "/" + std::to_string(r.small_after) + ", free " +
              std::to_string(r.free_before) + "/" + std::to_string(r.free_after));
    check(r.closed_before && !r.closed_after && r.nonmanifold_before == 5 && r.nonmanifold_after == 4, w + ": closed and non-manifold");
    check(r.fixes.size() == 2 && r.fixes[0].kind == "small_hole" && r.fixes[0].index == 11 && r.fixes[0].size == 1.5 &&
              r.fixes[0].moved == 0.125 && r.fixes[1].kind == "short_edge" && r.fixes[1].index == 12 && r.fixes[1].size == 2.5 &&
              r.fixes[1].moved == 0.0625,
          w + ": the fixes");
    check(r.refused.size() == 3 && r.refused[0].kind == "tiny_face" && r.refused[0].index == 21 && r.refused[0].why == "toggled" &&
              r.refused[0].figure == 0.0 && r.refused[1].kind == "tiny_body" && r.refused[1].index == 22 &&
              r.refused[1].why == "chain" && r.refused[1].figure == 7.5 && r.refused[2].kind == "sliver_face" &&
              r.refused[2].index == 23 && r.refused[2].why == "unsupported" && r.refused[2].figure == 0.0,
          w + ": the refusals");
}

static const std::uint32_t COUNTS[18] = {2, 1, 1, 2, 1, 0, 0, 1, 0, 3, 4, 5, 1, 0, 11, 12, 13, 2};
static const double SIZES[8] = {0.5, 0.25, 9.0, 7.5, 6.5, 5.5, 4.5, 3.5};
static const std::uint32_t UNMESHED[18] = {2, 1, 1, 2, 1, 0, 0, 1, 0, 3, 4, 5, 0, 0, 11, 12, 13, 2};
static const std::uint32_t HEAL_COUNTS[11] = {2, 3, 1, 9, 8, 7, 6, 1, 0, 5, 4};
static const double HEAL_SIZES[2] = {0.5, 0.25};

static std::vector<std::uint32_t> free_ids() { return {10, 20, 30, 40, 1, 2, 11, NONE, 31, 41, NONE, 0}; }
static std::vector<double> free_sizes() { return {1.5, 2.5, 3.5, INF}; }

static void the_kernel_decoders_read_every_column_of_distinct_rows() {
    bs::HealthReport r = must(bs::detail::health_report(COUNTS, SIZES, free_ids(), free_sizes(), {0, 2, 1}, {8.5, 2.5}, {1, 77, 4, 99},
                                                        {0.125, 0.0625}, {5, 6}),
                              "health_report");
    check_health_rows<bs::HealthReport, bs::FreeEdge>(r, "health decoder (kernel)");
    bs::HealReport h = must(bs::detail::heal_report(HEAL_COUNTS, HEAL_SIZES, {5, 11, 0, 12}, {1.5, 0.125, 2.5, 0.0625},
                                                    {3, 21, 9, 4, 22, 3, 2, 23, 10}, {0.0, 7.5, 0.0}),
                            "heal_report");
    check_heal_rows(h, "heal decoder (kernel)");
    // without the mesh (counts[12] 0) there are no cracks, whatever counts[13..16] hold
    check(!must(bs::detail::health_report(UNMESHED, SIZES, {}, {}, {}, {}, {}, {}, {5, 6}), "health_report").cracks,
          "health decoder (kernel): no cracks unless meshed");
    check(!bs::detail::health_report(COUNTS, SIZES, {}, {}, {}, {}, {6, 0}, {0.5}, {}).ok(), "health decoder (kernel): kind 6 is refused");
    check(bs::detail::heal_flags(true, false, false) == 1 && bs::detail::heal_flags(false, true, false) == 2 &&
              bs::detail::heal_flags(false, false, true) == 4 && bs::detail::heal_flags(true, true, true) == 7,
          "healed (kernel): the switches are the flag bits 1, 2, 4");
}

static void the_reader_decoders_read_every_column_of_distinct_rows() {
    cadaclysm::HealthReport r = must(cadaclysm::detail::health_report(COUNTS, SIZES, free_ids(), free_sizes(), {0, 2, 1}, {8.5, 2.5},
                                                                      {1, 77, 4, 99}, {0.125, 0.0625}, {5, 6}),
                                     "health_report");
    check_health_rows<cadaclysm::HealthReport, cadaclysm::FreeEdge>(r, "health decoder (reader)");
    cadaclysm::HealReport h = must(cadaclysm::detail::heal_report(HEAL_COUNTS, HEAL_SIZES, {5, 11, 0, 12}, {1.5, 0.125, 2.5, 0.0625},
                                                                  {3, 21, 9, 4, 22, 3, 2, 23, 10}, {0.0, 7.5, 0.0}),
                                   "heal_report");
    check_heal_rows(h, "heal decoder (reader)");
    check(!must(cadaclysm::detail::health_report(UNMESHED, SIZES, {}, {}, {}, {}, {}, {}, {5, 6}), "health_report").cracks,
          "health decoder (reader): no cracks unless meshed");
    check(!cadaclysm::detail::health_report(COUNTS, SIZES, {}, {}, {}, {}, {6, 0}, {0.5}, {}).ok(),
          "health decoder (reader): kind 6 is refused");
    check(cadaclysm::detail::heal_flags(true, false, false) == 1 && cadaclysm::detail::heal_flags(false, true, false) == 2 &&
              cadaclysm::detail::heal_flags(false, false, true) == 4 && cadaclysm::detail::heal_flags(true, true, true) == 7,
          "healed (reader): the switches are the flag bits 1, 2, 4");
}

// ---- reader: Brep, on st203-bapl.stp ----------------------------------------------------

static std::string st203;
static int st203_ran = 0;

static std::vector<cadaclysm::Brep> breps_of(const cadaclysm::Scene& scene) {
    std::vector<cadaclysm::Brep> breps;
    for (const cadaclysm::Node& n : scene.nodes()) {
        std::optional<cadaclysm::Brep> b = n.brep();
        if (b) breps.push_back(std::move(*b));
    }
    return breps;
}

static void st203_health_reports_the_free_edges() {
    if (st203.empty()) return;
    cadaclysm::Scene scene = must(cadaclysm::open(st203), "open st203");
    std::vector<cadaclysm::Brep> breps = breps_of(scene);
    check(breps.size() > 1, "st203 has two bodies");
    if (breps.size() < 2) return;
    const cadaclysm::Brep& body = breps[1];
    check(must(body.manifold(), "manifold").boundary_edges == 188, "body 1 has 188 boundary edges");
    cadaclysm::HealthReport report = must(body.health(), "health");
    check(report.free_edges.size() == 188 && report.wires.size() == 45,
          std::to_string(report.free_edges.size()) + " free edges and " + std::to_string(report.wires.size()) + " wires, not 188 and 45");
    std::uint32_t sum = 0;
    for (const cadaclysm::FreeWire& w : report.wires) sum += w.count;
    check(sum == 188, "the wires' counts sum to " + std::to_string(sum));
    if (!report.wires.empty()) {
        std::vector<cadaclysm::FreeEdge> first_wire = must(report.wire_edges(0), "wire_edges");
        check(first_wire.size() == report.wires[0].count, "wire 0's rows");
        for (const cadaclysm::FreeEdge& e : first_wire) check(e.wire == 0, "wire 0's rows are on wire 0");
    }
    check(report.tolerance > 0 && !report.cracks, "a tolerance and no cracks");
    check(must(body.health(std::nan("")), "health(nan)").tolerance == report.tolerance, "health(NaN) takes the default");
    if (!report.free_edges.empty()) {
        const cadaclysm::FreeEdge& first = report.free_edges[0];
        check(first.trim == 0 && first.edge == std::optional<std::uint32_t>(41363) && first.face == 0 && first.wire == 0 &&
                  first.partner == std::optional<std::uint32_t>(67) && first.shared_ends == 0,
              "free edge 0 reads (" + std::to_string(first.trim) + ", " + opt(first.edge) + ", " + std::to_string(first.face) + ", " +
                  std::to_string(first.wire) + ", " + opt(first.partner) + ", " + std::to_string(first.shared_ends) + ")");
        check(rel(first.gap, 95.01496054, 1e-6), "free edge 0's gap " + std::to_string(first.gap));
    }
    for (const cadaclysm::FreeEdge& e : report.free_edges) {
        if (!e.partner) check(e.gap == INF, "a free edge without a partner is an infinite gap");
    }
    check(rel(report.extent, 253.66439715552204, 1e-12), "extent " + std::to_string(report.extent));
    check(rel(report.rounding, 1e-7 * report.extent, 1e-12), "rounding");
    check(rel(report.tolerance, 1e-4 * report.extent, 1e-12), "tolerance");
    check(report.loose_edges == 0 && report.worst_loose == 0.0, "nothing loose");
    std::pair<cadaclysm::Brep, cadaclysm::SewReport> sewn = must(body.sewed(), "sewed");
    check(report.sew_pairs == sewn.second.pairs, "sew_pairs " + std::to_string(report.sew_pairs) + " is sewed()'s pairs");
    check(report.sew_refused == 4 && sewn.second.refused == 4, "sew_refused 4");
    check(rel(report.sew_worst_gap, sewn.second.worst_gap, 1e-12) && report.sew_worst_gap > 0, "sew_worst_gap");
    std::optional<cadaclysm::Cracks> c = must(body.health(std::nullopt, true), "health(mesh)").cracks;
    check(c.has_value() && !c->watertight && c->open == 0 && c->folded == 0 && c->crossings == 166 && c->edges.empty(),
          "the meshed report is (false, 0, 0, 166, [])");
    cadaclysm::HealthReport wide = must(body.health(5.0), "health(5)");
    check(wide.small.size() == 96, std::to_string(wide.small.size()) + " small at 5, not 96");
    bool found = false;
    for (const cadaclysm::SmallFeature& s : wide.small) {
        check(s.size >= 0, "a small feature's size is not negative");
        if (s.kind == "short_edge") {
            check(s.size < 5.0, "a short edge is below the tolerance");
            if (!found) {
                found = true;
                check(s.index == 41550 && rel(s.size, 3.1622776616321775, 1e-9),
                      "the first short edge reads (" + std::to_string(s.index) + ", " + std::to_string(s.size) + ")");
            }
        }
    }
    check(found, "a short edge at 5");
    ++st203_ran;
}

static void st203_healed_heals_and_leaves_the_original() {
    if (st203.empty()) return;
    cadaclysm::Scene scene = must(cadaclysm::open(st203), "open st203");
    std::vector<cadaclysm::Brep> breps = breps_of(scene);
    if (breps.size() < 2) {
        check(false, "st203 has two bodies");
        return;
    }
    cadaclysm::Brep& body = breps[1];
    std::pair<cadaclysm::Brep, cadaclysm::HealReport> same = must(body.healed(), "healed");
    check(same.first.pointer() != body.pointer(), "a new brep all the same");
    check(same.second.small_before == 0 && same.second.free_before == 188 && same.second.free_after <= 188,
          "nothing small at the default tolerance");
    check(rel(same.second.tolerance, 1e-4 * must(body.health(), "health").extent, 1e-12), "the default tolerance");

    std::pair<cadaclysm::Brep, cadaclysm::HealReport> out = must(body.healed(5.0), "healed(5)");
    const cadaclysm::Brep& healed = out.first;
    const cadaclysm::HealReport& report = out.second;
    check(report.tolerance == 5.0 && report.small_before == 96, "healed at 5 from 96 small");
    check(report.fixes.size() == 28 && report.small_after == 8 && report.free_before == 188 && report.free_after == 88,
          "fixes " + std::to_string(report.fixes.size()) + ", small after " + std::to_string(report.small_after) + ", free " +
              std::to_string(report.free_before) + " -> " + std::to_string(report.free_after));
    check(report.refused.size() == 8, std::to_string(report.refused.size()) + " refused, not 8");
    for (const cadaclysm::HealRefusal& r : report.refused) {
        check(r.kind == "sliver_face" && r.why == "uneven", "a refusal reads (" + r.kind + ", " + r.why + ")");
    }
    check(!report.closed_before && !report.closed_after && report.nonmanifold_before == 0 && report.nonmanifold_after == 0,
          "open before and after, manifold");
    check(report.small_after == must(healed.health(5.0), "healed health").small.size(), "small_after is the result's health");
    check(must(body.health(5.0), "health").small.size() == 96, "the input is left as it was");
    double most = 0.0;
    for (const cadaclysm::HealFix& f : report.fixes) {
        check(f.size >= 0 && f.moved >= 0, "a fix's size and moved are not negative");
        most = std::max(most, f.moved);
    }
    check(rel(most, 1.8248105306211464, 1e-9), "the largest fix moved " + std::to_string(most));
    check(rel(report.moved, 1.581138831332503, 1e-9), "moved " + std::to_string(report.moved));
    std::optional<cadaclysm::HealFix> edge;
    for (const cadaclysm::HealFix& f : report.fixes) {
        if (f.kind == "short_edge") {
            edge = f;
            break;
        }
    }
    check(edge.has_value() && edge->index == 41550 && rel(edge->size, 3.1622776616321775, 1e-9), "the first short-edge fix");
    check(must(body.edge_tolerance(41550), "edge_tolerance") == std::optional<double>(0.0), "the input's edge is exact");
    check(!must(healed.edge_tolerance(41550), "edge_tolerance").has_value(), "the merged edge is gone");
    check(must(healed.edge_tolerance(41363), "edge_tolerance") == std::optional<double>(0.0), "edge 41363 is exact");
    check(!must(healed.edge_tolerance(0xFFFFFFF0u), "edge_tolerance").has_value(), "an id no trim names");

    cadaclysm::HealReport off = must(body.healed(5.0, false, false, false), "healed(off)").second;
    check(off.fixes.empty() && off.refused.size() == 96 && off.free_after == off.free_before, "every kind off: nothing healed, 96 refused");
    std::uint32_t per[3] = {0, 0, 0};
    for (const cadaclysm::HealRefusal& r : off.refused) {
        check(r.why == "toggled" && r.figure == 0.0, "an off refusal is toggled at figure 0");
        if (r.kind == "short_edge") ++per[0];
        else if (r.kind == "sliver_face") ++per[1];
        else if (r.kind == "tiny_face") ++per[2];
    }
    check(per[0] == 64 && per[1] == 26 && per[2] == 6,
          "short/sliver/tiny " + std::to_string(per[0]) + ", " + std::to_string(per[1]) + ", " + std::to_string(per[2]));
    cadaclysm::HealReport edges_only = must(body.healed(5.0, true, false, false), "healed(edges only)").second;
    for (const cadaclysm::HealRefusal& r : edges_only.refused) {
        if (r.kind != "short_edge") check(r.why == "toggled", "with faces and holes off, a face is toggled");
    }
    for (const cadaclysm::HealFix& f : edges_only.fixes) {
        check(f.kind == "short_edge" || f.kind == "collapsed_edge", "with faces and holes off, only edges are fixed");
    }

    body.release();
    Result<std::pair<cadaclysm::Brep, cadaclysm::HealReport>> gone = body.healed();
    check(!gone.ok() && gone.error().message.find("released") != std::string::npos, "healed on a released brep");
    check(!body.health().ok(), "health on a released brep");
    check(!body.edge_tolerance(0).ok(), "edge_tolerance on a released brep");
    ++st203_ran;
}

int main(int argc, char** argv) {
    if (argc > 1 && std::string(argv[1]) != "-") {
        if (std::filesystem::exists(argv[1])) st203 = argv[1];
        else std::printf("healing: %s not to hand, st203 checks SKIPPED\n", argv[1]);
    } else {
        std::printf("healing: no st203-bapl.stp given, st203 checks SKIPPED\n");
    }
    if (argc > 2) {
        Result<void> loaded = bs::license(argv[2]);
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
        {"a_closed_cuboid_has_nothing_free_and_cracks_only_on_request", a_closed_cuboid_has_nothing_free_and_cracks_only_on_request},
        {"a_cuboid_without_a_face_is_one_open_rim_of_four_edges", a_cuboid_without_a_face_is_one_open_rim_of_four_edges},
        {"a_thin_plate_lists_its_small_features_by_kind_index_and_size", a_thin_plate_lists_its_small_features_by_kind_index_and_size},
        {"a_tiny_body_and_its_tiny_faces", a_tiny_body_and_its_tiny_faces},
        {"a_healed_cuboid_heals_to_itself_as_a_new_solid", a_healed_cuboid_heals_to_itself_as_a_new_solid},
        {"healed_with_every_kind_off_refuses_each_small_feature_as_toggled", healed_with_every_kind_off_refuses_each_small_feature_as_toggled},
        {"a_closed_solid_is_refused", a_closed_solid_is_refused},
        {"the_kernel_decoders_read_every_column_of_distinct_rows", the_kernel_decoders_read_every_column_of_distinct_rows},
        {"the_reader_decoders_read_every_column_of_distinct_rows", the_reader_decoders_read_every_column_of_distinct_rows},
        {"st203_health_reports_the_free_edges", st203_health_reports_the_free_edges},
        {"st203_healed_heals_and_leaves_the_original", st203_healed_heals_and_leaves_the_original},
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
    std::printf("healing: ok (st203 %s)\n", st203_ran == 2 ? "ran" : "SKIPPED");
    return 0;
}
