// The SubD cage -- Subd, SubdMesh and SubdReport over the cadaclysm_blacksmith_subd_*
// calls -- at parity with the Python reference's test_subd_* tests in
// test_cadaclysm_blacksmith.py (The Kiln, plan 2b): the same sixteen facts, the same exact
// values. Needs the kernel library (and the reader, for the STEP read-back) and a license;
// the exit code is the verdict.
//
//     cadaclysm_subd_test [cadaclysm.lic]
#include <csetjmp>
#include <cstdio>
#include <cstdlib>
#include <string>

#if defined(_MSC_VER)
#pragma warning(disable : 4611)  // setjmp and C++ destruction: only trivially destructible locals cross it
#endif

// A closed cage is a bad access, as a closed Collider is. The hook below turns it into a
// longjmp back to `trips`, so the test can see it (the default aborts).
namespace trap {
inline std::jmp_buf* where = nullptr;
inline std::string message;
}  // namespace trap
#define CADACLYSM_BAD_ACCESS(text) \
    (::trap::message = (text), ::trap::where ? std::longjmp(*::trap::where, 1) : std::abort())

#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <optional>
#include <vector>

using cadaclysm::Error;
using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;
using bs::SubdAxis;
using bs::SubdEdge;
using bs::SubdElements;
using bs::SubdSelection;
using bs::Vec3;

static int failures = 0;

static void check(bool ok, const std::string& what) {
    if (ok) return;
    std::fprintf(stderr, "FAIL: %s\n", what.c_str());
    ++failures;
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

enum class Match { exact, contains, starts, between };

// A refusal check that fails when nothing was refused: the call must have returned an
// error, and its text must match.
template <class T>
static void refused(const Result<T>& r, Match how, const std::string& want, const std::string& what,
                    const std::string& then = "") {
    if (r.ok()) {
        check(false, what + ": expected a refusal, but the call succeeded");
        return;
    }
    const std::string& got = r.error().message;
    bool ok = false;
    switch (how) {
        case Match::exact: ok = got == want; break;
        case Match::contains: ok = got.find(want) != std::string::npos; break;
        case Match::starts: ok = got.compare(0, want.size(), want) == 0; break;
        case Match::between: {
            std::size_t first = got.find(want);
            ok = first != std::string::npos && got.find(then, first) != std::string::npos;
            break;
        }
    }
    check(ok, what + ": refused with \"" + got + "\", wanted " + (how == Match::exact ? "exactly " : "") + "\"" + want + "\"");
}

static Result<bs::Subd> cube() { return bs::Subd::cuboid(); }

static std::vector<std::uint32_t> ids(std::initializer_list<std::uint32_t> list) { return std::vector<std::uint32_t>(list); }

// 1
static Result<void> round_trips_through_parts() {
    CADACLYSM_TRY(c, cube());
    std::vector<Vec3> positions = c.positions();
    auto faces = c.faces();
    check(positions.size() == 8, "cuboid() has 8 positions");
    check(faces.size() == 6, "cuboid() has 6 faces");
    for (const auto& f : faces) check(f.size() == 4, "every cuboid() face has 4 vertices");
    check(c.creases().empty() && c.pins().empty(), "cuboid() has no creases or pins");
    check(!c.symmetry().has_value(), "cuboid() has no symmetry");
    check(!c.selection().has_value(), "cuboid() has no selection");
    double was = positions[0][0];
    positions[0][0] = 99.0;  // a copy: writing to it changes nothing
    check(c.positions()[0][0] == was, "writing to the returned positions changed the next read");
    CADACLYSM_TRY(again, bs::Subd::from_parts(c.positions(), c.faces()));
    check(again.positions() == c.positions(), "from_parts positions differ");
    check(again.faces() == c.faces(), "from_parts faces differ");
    return {};
}

// 2
static Result<void> edits_return_new_cages_with_their_selection() {
    CADACLYSM_TRY(c, cube());
    CADACLYSM_TRY(out, c.extrude(ids({1}), 1.0));
    check(out.positions().size() == 12, "extrude has 12 positions");
    auto selection = out.selection();
    check(selection.has_value() && *selection == SubdSelection::of_faces({1}), "extrude selects faces [1]");
    check(c.positions().size() == 8, "the input is untouched");
    return {};
}

// 3
static Result<void> crease_and_pin_round_trip() {
    CADACLYSM_TRY(c, cube());
    CADACLYSM_TRY(creased, c.crease({SubdEdge{0, 1}}));
    auto selected = creased.selection();
    check(selected.has_value() && *selected == SubdSelection::of_edges({SubdEdge{0, 1}}), "crease selects edges [(0,1)]");
    CADACLYSM_TRY(pinned, creased.pin(ids({6})));
    check(pinned.creases() == std::vector<SubdEdge>{SubdEdge{0, 1}}, "pinned creases");
    check(pinned.pins() == ids({6}), "pinned pins");
    auto after = pinned.selection();
    check(after.has_value() && *after == SubdSelection::of_vertices({6}), "pin selects vertices [6]");
    CADACLYSM_TRY(again, bs::Subd::from_parts(pinned.positions(), pinned.faces(), pinned.creases(), pinned.pins()));
    check(again.creases() == pinned.creases() && again.pins() == pinned.pins(), "from_parts keeps creases and pins");
    CADACLYSM_TRY(plain, pinned.crease({SubdEdge{0, 1}}, false));
    CADACLYSM_TRY(free_, pinned.pin(ids({6}), false));
    check(plain.creases().empty(), "crease(on=false) empties the creases");
    check(free_.pins().empty(), "pin(on=false) empties the pins");
    return {};
}

// 4
static Result<void> mirror_round_trip() {
    CADACLYSM_TRY(whole, bs::Subd::cuboid({2, 2, 2}, {2, 1, 1}));
    CADACLYSM_TRY(half, whole.mirror_on(SubdAxis::x));
    auto symmetry = half.symmetry();
    check(symmetry.has_value() && symmetry->axis == SubdAxis::x && symmetry->tolerance > 0, "mirror_on(x) symmetry");
    check(!half.selection().has_value(), "mirror_on selects nothing");
    check(half.positions().size() < whole.positions().size(), "a half has fewer positions than the whole");
    CADACLYSM_TRY(again, bs::Subd::from_parts(half.positions(), half.faces(), half.creases(), half.pins(), half.symmetry()));
    check(again.positions() == half.positions(), "from_parts keeps a half's positions");
    check(again.symmetry() == half.symmetry(), "from_parts keeps the symmetry");
    CADACLYSM_TRY(full, half.full());
    CADACLYSM_TRY(off, half.mirror_off());
    check(full.positions().size() == whole.positions().size(), "full() has as many positions as the whole");
    check(!off.symmetry().has_value(), "mirror_off() has no symmetry");
    return {};
}

// 5
static Result<void> edge_loops() {
    {
        CADACLYSM_TRY(c, bs::Subd::cuboid({2, 2, 2}, {2, 2, 2}));
        auto face0 = c.faces()[0];
        std::uint32_t a = face0[0], b = face0[1];
        CADACLYSM_TRY(loop, c.edge_loop(SubdEdge{a, b}));
        check(loop.size() >= 4, "an edge loop of a 2x2x2 cuboid has at least 4 edges, got " + std::to_string(loop.size()));
        check(!loop.empty() && loop[0] == SubdEdge{std::min(a, b), std::max(a, b)}, "the picked edge first");
    }
    CADACLYSM_TRY(c, cube());
    auto f = c.faces()[0];
    CADACLYSM_TRY(diagonal, c.edge_loop(SubdEdge{f[0], f[2]}));
    check(diagonal.empty(), "a face's diagonal is no edge");
    CADACLYSM_TRY(nowhere, c.edge_loop(SubdEdge{0, 99}));
    check(nowhere.empty(), "a pair naming no vertex is no edge");
    return {};
}

// 6, 7
static Result<void> transform_inset_and_insert_loop() {
    CADACLYSM_TRY(c, cube());
    const std::vector<double> rotate = {0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};  // column-major
    std::vector<Vec3> before = c.positions();
    std::vector<std::uint32_t> every;
    for (std::uint32_t v = 0; v < before.size(); ++v) every.push_back(v);
    {
        CADACLYSM_TRY(turned, c.transform(SubdSelection::of_vertices(every), rotate));
        std::vector<Vec3> now = turned.positions();
        check(now.size() == before.size(), "transform keeps the vertex count");
        for (std::size_t v = 0; v < now.size() && v < before.size(); ++v) {
            check(std::fabs(now[v][0] + before[v][1]) <= 1e-12 && std::fabs(now[v][1] - before[v][0]) <= 1e-12 &&
                      std::fabs(now[v][2] - before[v][2]) <= 1e-12,
                  "vertex " + std::to_string(v) + " is not (-y, x, z)");
        }
    }
    {
        CADACLYSM_TRY(one, c.transform(SubdSelection::of_vertices({0}), rotate));
        std::vector<Vec3> now = one.positions();
        check(std::fabs(now[0][0] + before[0][1]) <= 1e-12 && std::fabs(now[0][1] - before[0][0]) <= 1e-12,
              "vertex 0 did not turn");
        bool others = true;
        for (std::size_t v = 1; v < now.size(); ++v) others = others && now[v] == before[v];
        check(others, "a rotation of vertex 0 alone moved another vertex");
    }
    const std::vector<double> translate = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 3, 0, 0, 1};  // column-major
    {
        CADACLYSM_TRY(moved, c.transform(SubdSelection::of_edges({SubdEdge{0, 1}}), translate));
        check(moved.positions()[0][0] == before[0][0] + 3.0, "the edge transform did not add exactly 3 to vertex 0's x");
        auto selected = moved.selection();
        check(selected.has_value() && *selected == SubdSelection::of_edges({SubdEdge{0, 1}}), "transform keeps the selection");
    }
    refused(c.transform(SubdSelection::of_vertices({0}), {1, 2, 3}), Match::contains, "matrix", "a 3-number matrix");
    {
        CADACLYSM_TRY(inset, c.inset(ids({1}), 0.25));
        check(inset.faces().size() == 6 + 4, "inset([1], 0.25) has 10 faces");
    }
    {
        CADACLYSM_TRY(looped, c.insert_loop(SubdEdge{0, 1}));
        check(looped.positions().size() == 8 + 4, "insert_loop has 12 positions");
        auto selected = looped.selection();
        check(selected.has_value() && selected->kind == SubdElements::edges, "insert_loop selects edges");
    }
    refused(c.insert_loop(SubdEdge{0, 1}, 1.5), Match::starts, "bad selection: ", "insert_loop at 1.5");
    return {};
}

// subdivide: whole, one face, a bad face
static Result<void> subdivide_whole_one_face_and_a_bad_face() {
    CADACLYSM_TRY(kiln, bs::Subd::cuboid({2.0, 2.0, 2.0}, {2, 2, 2}));
    {
        CADACLYSM_TRY(whole, kiln.subdivide());
        check(whole.faces().size() == 96, "subdivide() has 96 faces");
    }
    {
        CADACLYSM_TRY(one, kiln.subdivide(ids({1})));
        check(one.faces().size() == 27, "subdivide({1}) has 27 faces");
        std::optional<SubdSelection> selected = one.selection();
        check(selected.has_value() && selected->kind == SubdElements::faces && selected->ids.size() == 4,
              "subdivide({1}) selects 4 faces");
    }
    refused(kiln.subdivide(ids({999})), Match::contains, "subdivide: face 999 is not in the cage", "subdivide face 999");
    return {};
}

// 8
// Two point lists the same length and equal to within `tolerance` in every coordinate.
static bool within(const std::vector<Vec3>& a, const std::vector<Vec3>& b, double tolerance) {
    if (a.size() != b.size()) return false;
    for (std::size_t i = 0; i < a.size(); ++i) {
        for (int k = 0; k < 3; ++k) {
            if (std::fabs(a[i][k] - b[i][k]) > tolerance) return false;
        }
    }
    return true;
}

static Result<void> smooth_mesh_is_consistent_and_kept() {
    bs::SubdMesh mesh;
    std::size_t n = 0;
    {
        CADACLYSM_TRY(c, cube());
        CADACLYSM_TRY(m, c.smooth_mesh(2));
        mesh = m;
        n = mesh.positions.size();
        check(n > 8, "smooth_mesh(2) has more than 8 positions");
        check(mesh.normals.size() == n, "as many normals as positions");
        for (const Vec3& v : mesh.normals) {
            check(std::fabs(std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]) - 1.0) <= 1e-9, "a normal is not unit");
        }
        check(mesh.indices.size() % 3 == 0 && !mesh.indices.empty(), "indices are three a triangle");
        check(!mesh.indices.empty() && *std::max_element(mesh.indices.begin(), mesh.indices.end()) < n, "an index is out of range");
        check(mesh.triangle_face.size() == mesh.indices.size() / 3, "one triangle_face a triangle");
        check(!mesh.triangle_face.empty() && *std::max_element(mesh.triangle_face.begin(), mesh.triangle_face.end()) < 6,
              "a triangle_face is not a face of the cube");
        CADACLYSM_TRY(coarse, c.smooth_mesh(1));
        check(coarse.positions.size() < n, "smooth_mesh(1) has fewer positions");
        CADACLYSM_TRY(again, c.smooth_mesh(2));
        check(again.positions == mesh.positions, "a second smooth_mesh(2) differs");
        refused(c.smooth_mesh(7), Match::contains, "levels", "smooth_mesh(7)");
        c.close();
    }
    // The cage is closed: the mesh is a copy and is still whole.
    check(mesh.positions.size() == n && mesh.normals.size() == n, "the mesh lost its arrays with its cage");
    // A topology met a second time is meshed from kept weights, the same mesh to within
    // rounding (cadaclysm-subd's Cage::smooth_mesh): the fresh cube's points may differ in
    // the last bits, its triangles not at all. The bounds are cadaclysm-subd's own: 1e-12 of the
    // cube's diagonal for a point, 1e-9 for a normal.
    CADACLYSM_TRY(fresh, cube());
    CADACLYSM_TRY(reference, fresh.smooth_mesh(2));
    check(within(mesh.positions, reference.positions, 1e-12 * std::sqrt(12.0)) && within(mesh.normals, reference.normals, 1e-9) &&
              mesh.indices == reference.indices && mesh.triangle_face == reference.triangle_face,
          "the mesh read after its cage closed differs from a fresh one");
    return {};
}

// 9
static Result<void> pick_finds_the_element_or_none() {
    CADACLYSM_TRY(c, cube());
    Vec3 corner = c.positions()[6];
    CADACLYSM_TRY(mesh, c.smooth_mesh(3));
    Vec3 point = mesh.positions[0];
    double best = 1e300;
    for (const Vec3& p : mesh.positions) {
        double d = (p[0] - corner[0]) * (p[0] - corner[0]) + (p[1] - corner[1]) * (p[1] - corner[1]) +
                   (p[2] - corner[2]) * (p[2] - corner[2]);
        if (d < best) {
            best = d;
            point = p;
        }
    }
    CADACLYSM_TRY(vertex, c.pick(point, SubdElements::vertices));
    check(vertex.has_value() && *vertex == SubdSelection::of_vertices({6}), "picking the corner for a vertex gives 6");
    CADACLYSM_TRY(edge, c.pick(point, SubdElements::edges));
    check(edge.has_value() && edge->kind == SubdElements::edges && edge->edges.size() == 1 &&
              (edge->edges[0].a == 6 || edge->edges[0].b == 6),
          "picking the corner for an edge gives an edge containing 6");
    CADACLYSM_TRY(face, c.pick(point, SubdElements::faces));
    check(face.has_value() && face->kind == SubdElements::faces && face->ids.size() == 1 && face->ids[0] < 6,
          "picking the corner for a face gives a face");
    // Nothing near is not an error -- and must not read a stale refusal.
    refused(c.pick(Vec3{std::nan(""), 0, 0}, SubdElements::faces), Match::exact, "bad selection: pick: point is not finite",
            "a NaN point");
    CADACLYSM_TRY(far_away, c.pick(Vec3{100, 100, 100}, SubdElements::vertices));
    check(!far_away.has_value(), "(100,100,100) is nothing near");
    return {};
}

// 10
static Result<void> to_solid_converts_a_cube() {
    CADACLYSM_TRY(c, cube());
    CADACLYSM_TRY(out, c.to_solid());
    const bs::SubdReport& r = out.report;
    check(r.regular == 0 && r.refined == 24, "report regular/refined are 0/24, got " + std::to_string(r.regular) + "/" +
                                                  std::to_string(r.refined));
    check(r.levels >= 2 && r.steps >= 1, "report levels >= 2 and steps >= 1");
    check(r.deviation <= 1e-4 && r.g1_angle_deg <= 0.1, "report deviation and g1 angle within the defaults");
    check(std::isfinite(r.deviation_at[0]) && std::isfinite(r.deviation_at[1]) && std::isfinite(r.deviation_at[2]) &&
              std::isfinite(r.g1_at[0]) && std::isfinite(r.g1_at[1]) && std::isfinite(r.g1_at[2]),
          "deviation_at and g1_at are three numbers each");
    CADACLYSM_TRY(manifold, out.solid.manifold());
    check(manifold.is_closed, "the converted cube is closed");
    CADACLYSM_TRY(mass, out.solid.mass());
    check(mass.volume > 0.0, "the converted cube has volume");
    CADACLYSM_TRY(again, c.to_solid(1e-4, 0.1, 6));
    (void)again;
    return {};
}

// 11
static Result<void> to_solid_refuses_with_figures() {
    CADACLYSM_TRY(cylinder, bs::Subd::cylinder(1.0, 2.0, 8, 1, false));
    refused(cylinder.to_solid(), Match::between, "subd:", "a cylinder without creased rims", "tangent break");
    return {};
}

// 12
static Result<void> default_cylinder_converts() {
    CADACLYSM_TRY(cylinder, bs::Subd::cylinder());
    CADACLYSM_TRY(out, cylinder.to_solid());
    check(out.report.deviation <= 1e-4 && out.report.g1_angle_deg <= 0.1, "the default cylinder is within the defaults");
    CADACLYSM_TRY(manifold, out.solid.manifold());
    check(manifold.is_closed, "the default cylinder is closed");
    CADACLYSM_TRY(mass, out.solid.mass());
    check(mass.volume > 0.0, "the default cylinder has volume");
    return {};
}

// 13
static Result<void> other_primitives_and_bad_ones() {
    {
        CADACLYSM_TRY(a, bs::Subd::cylinder(1.0, 2.0, 8, 2, true));
        check(!a.faces().empty(), "cylinder(1,2,8,2,true) has faces");
        CADACLYSM_TRY(b, bs::Subd::sphere(1.0, 2));
        check(!b.faces().empty(), "sphere(1,2) has faces");
        CADACLYSM_TRY(t, bs::Subd::torus(3.0, 1.0, 12, 8));
        check(!t.faces().empty(), "torus(3,1,12,8) has faces");
    }
    refused(bs::Subd::cuboid({2, 2, 2}, {0, 1, 1}), Match::exact, "bad selection: cuboid: segments >= 1", "cuboid segments 0");
    refused(bs::Subd::sphere(1.0, 2000), Match::contains, "1024", "sphere(1, 2000)");
    return {};
}

// 14
static Result<void> bad_parts_are_refused() {
    CADACLYSM_TRY(c, cube());
    std::vector<Vec3> positions = c.positions();
    auto faces = c.faces();
    refused(bs::Subd::from_parts(positions, faces, {SubdEdge{0, 6}}), Match::starts, "bad selection: ", "a crease that is no edge");
    refused(bs::Subd::from_parts({}, faces), Match::contains, "vertex_count", "zero positions");
    return {};
}

// 15
static Result<void> pipeline_writes_step() {
    CADACLYSM_TRY(c, cube());
    CADACLYSM_TRY(raised, c.extrude(ids({1}), 0.5));
    CADACLYSM_TRY(inset, raised.inset(ids({1}), 0.25));
    CADACLYSM_TRY(out, inset.to_solid());
    CADACLYSM_TRY(manifold, out.solid.manifold());
    check(manifold.is_closed && out.report.deviation <= 1e-4, "the pipeline's solid is closed and within tolerance");
    CADACLYSM_TRY(text, out.solid.step_text());
    check(text.compare(0, 13, "ISO-10303-21;") == 0, "the STEP text starts ISO-10303-21;");
    check(text.find("ADVANCED_FACE") != std::string::npos, "the STEP text has ADVANCED_FACE");
    CADACLYSM_TRY(scene, cadaclysm::open_memory(text.data(), text.size(), "stp"));
    std::size_t meshed = 0;
    for (const auto& node : scene.nodes()) {
        if (node.can_mesh()) ++meshed;
    }
    check(meshed == 1, "the STEP the cage wrote is one body, got " + std::to_string(meshed) + " meshable nodes");
    return {};
}

// 16
static Result<void> handles_close() {
    CADACLYSM_TRY(c, cube());
    c.close();
    c.close();  // closing twice is fine
    check(c.closed(), "close() did not close");
    const std::vector<std::uint32_t> one = {1};
    const Vec3 origin = {0, 0, 0};
    const char* want = "subd: closed";
    check(trips([&] { (void)c.positions(); }) && trap::message == want, "positions after close: " + trap::message);
    check(trips([&] { (void)c.extrude(one, 1.0); }) && trap::message == want, "extrude after close: " + trap::message);
    check(trips([&] { (void)c.smooth_mesh(1); }) && trap::message == want, "smooth_mesh after close: " + trap::message);
    check(trips([&] { (void)c.pick(origin, SubdElements::faces); }) && trap::message == want,
          "pick after close: " + trap::message);
    check(trips([&] { (void)c.to_solid(); }) && trap::message == want, "to_solid after close: " + trap::message);
    // A moved-from cage is closed too.
    CADACLYSM_TRY(d, cube());
    bs::Subd moved = std::move(d);
    check(d.closed() && !moved.closed(), "a move leaves the source closed and the target open");  // NOLINT(bugprone-use-after-move)
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
        {"round_trips_through_parts", round_trips_through_parts},
        {"edits_return_new_cages_with_their_selection", edits_return_new_cages_with_their_selection},
        {"crease_and_pin_round_trip", crease_and_pin_round_trip},
        {"mirror_round_trip", mirror_round_trip},
        {"edge_loops", edge_loops},
        {"transform_inset_and_insert_loop", transform_inset_and_insert_loop},
        {"subdivide_whole_one_face_and_a_bad_face", subdivide_whole_one_face_and_a_bad_face},
        {"smooth_mesh_is_consistent_and_kept", smooth_mesh_is_consistent_and_kept},
        {"pick_finds_the_element_or_none", pick_finds_the_element_or_none},
        {"to_solid_converts_a_cube", to_solid_converts_a_cube},
        {"to_solid_refuses_with_figures", to_solid_refuses_with_figures},
        {"default_cylinder_converts", default_cylinder_converts},
        {"other_primitives_and_bad_ones", other_primitives_and_bad_ones},
        {"bad_parts_are_refused", bad_parts_are_refused},
        {"pipeline_writes_step", pipeline_writes_step},
        {"handles_close", handles_close},
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
    std::printf("subd: ok\n");
    return 0;
}
