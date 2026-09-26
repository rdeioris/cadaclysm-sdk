// Open one file through the C++ wrapper and check what comes back, then build a part
// through the kernel, write it as STEP and read it back through the reader -- the
// scenario every other wrapper's smoke runs. The exit code is the verdict; the
// release pipeline runs this against every library it ships.
//
//     cadaclysm_smoke samples/cube.scad [cadaclysm.lic]
#include <csetjmp>
#include <cstdio>
#include <cstdlib>
#include <string>

#if defined(_MSC_VER)
#pragma warning(disable : 4611)  // setjmp and C++ destruction: see trips()
#endif

// A bad access records its message and jumps back to trips() instead of aborting,
// so the smoke can prove a stale read *is* caught. A longjmp out of the hook is only
// safe from the plain view, node and placement accessors -- other calls hold objects
// with destructors on the way to it -- so trips() only ever wraps one of those.
namespace trap {
inline std::jmp_buf* where = nullptr;
inline std::string message;
}  // namespace trap
#define CADACLYSM_BAD_ACCESS(text) \
    (::trap::message = (text), ::trap::where ? std::longjmp(*::trap::where, 1) : std::abort())

#include <cadaclysm/cadaclysm.hpp>
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <limits>
#include <optional>
#include <thread>
#include <vector>

using cadaclysm::Error;
using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;

// Whether `f` reached CADACLYSM_BAD_ACCESS. `f` must hold nothing with a destructor
// at the point it trips.
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

static Result<void> check(bool ok, std::string message) {
    if (ok) return {};
    return Error{std::move(message)};
}
#define EXPECT(cond, message) CADACLYSM_TRY_VOID(check((cond), (message)))

static std::string utf8(const std::filesystem::path& path) {
#if defined(__cpp_char8_t)
    std::u8string s = path.u8string();
    return std::string(s.begin(), s.end());
#else
    return path.u8string();
#endif
}

static std::string temp_file(const char* name) {
    std::error_code ec;
    std::filesystem::path dir = std::filesystem::temp_directory_path(ec);
    if (ec) dir = ".";
    return utf8(dir / name);
}

static Result<std::vector<char>> read_file(const std::string& path) {
    std::ifstream in(cadaclysm::detail::fs_path(path), std::ios::binary);
    if (!in) return Error{path + ": cannot read"};
    return std::vector<char>(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
}

// ---- the FEM surface mesh ------------------------------------------------------------

// A placement carrying **both a rotation and a translation**: a quarter turn about z,
// then 100 along x, as the reader's sixteen column-major doubles.
//
//     [ 0 -1  0 100 ]        so (x, y, z) -> (100 - y, x, z)
//     [ 1  0  0   0 ]
//     [ 0  0  1   0 ]
//     [ 0  0  0   1 ]
//
// A translation alone cannot catch a composition-order bug: translate-then-rotate and
// rotate-then-translate agree on every pure translation, and the transpose of the
// identity is the identity. With the turn in it they disagree loudly -- this sends the
// origin to (100, 0, 0) where the other order sends it to (0, 100, 0), and a transposed
// 3x3 block sends what should be +y to -y.
//
// **A rotation only says something about a body that is not symmetric under it.**
// Transposing the 3x3 block composes this transform with a 180-degree turn about z
// through the placement's own origin, so a body centred on *its* own origin -- which
// every `Solid::cuboid` is -- maps onto itself: the same corners, the same span, the same
// printed line. So both halves below put the body off that axis **in the plane the turn
// acts in** (a non-zero x or y): an offset purely along z, off the origin but on the
// axis, leaves a transposed placement passing. `fem_kernel` is where that bites, and
// `fem_reader`'s cube needs no care only because `cube.scad` spans 0..20 in x and y
// rather than straddling the origin.
static constexpr double TURNED[16] = {
    0,   1, 0, 0,  // column 0: where x goes
    -1,  0, 0, 0,  // column 1: where y goes
    0,   0, 1, 0,  // column 2: where z goes
    100, 0, 0, 1,  // column 3: the translation
};

// Where TURNED puts a point. `turned_frame` is the same transform written the kernel's
// way -- twelve numbers rather than sixteen -- so both sides of the ABI are asserted
// against this one map.
static cadaclysm::Vec3 turned(const cadaclysm::Vec3& p) { return {100.0 - p[1], p[0], p[2]}; }

// TURNED as the kernel's **twelve** numbers: an origin and where x, y and z go.
// `Frame::of` checks them, so a left-handed or skewed slip here never reaches the mesher.
static Result<bs::Frame> turned_frame() {
    return bs::Frame::of({100, 0, 0, /* x -> */ 0, 1, 0, /* y -> */ -1, 0, 0, /* z -> */ 0, 0, 1});
}

static bool near_to(const cadaclysm::Vec3& a, const cadaclysm::Vec3& b) {
    return std::fabs(a[0] - b[0]) < 1e-6 && std::fabs(a[1] - b[1]) < 1e-6 && std::fabs(a[2] - b[2]) < 1e-6;
}

// The box the nodes fill, for the placement checks.
static std::pair<cadaclysm::Vec3, cadaclysm::Vec3> node_span(cadaclysm::Span<const double> nodes) {
    cadaclysm::Vec3 lo{0, 0, 0}, hi{0, 0, 0};
    for (std::size_t i = 0; i + 2 < nodes.size(); i += 3) {
        for (std::size_t k = 0; k < 3; ++k) {
            double v = nodes[i + k];
            lo[k] = i == 0 ? v : std::min(lo[k], v);
            hi[k] = i == 0 ? v : std::max(hi[k], v);
        }
    }
    return {lo, hi};
}

static bool has_node(cadaclysm::Span<const double> nodes, const cadaclysm::Vec3& want) {
    for (std::size_t i = 0; i + 2 < nodes.size(); i += 3) {
        if (near_to({nodes[i], nodes[i + 1], nodes[i + 2]}, want)) return true;
    }
    return false;
}

// The eight corners of a box: every one is a B-rep vertex of a cuboid, and so a node.
static std::vector<cadaclysm::Vec3> corners(const cadaclysm::Vec3& lo, const cadaclysm::Vec3& hi) {
    std::vector<cadaclysm::Vec3> out;
    for (double x : {lo[0], hi[0]}) {
        for (double y : {lo[1], hi[1]}) {
            for (double z : {lo[2], hi[2]}) out.push_back({x, y, z});
        }
    }
    return out;
}

static std::string where(const cadaclysm::Vec3& p) {
    char buffer[96];
    std::snprintf(buffer, sizeof buffer, "(%g, %g, %g)", p[0], p[1], p[2]);
    return buffer;
}

// Checks that hold of any FEM mesh, whichever side of the ABI built it -- a template, so
// a member missing from one of the two classes is a compile error rather than an untested
// half. The five flat arrays agree with each other and with the counts, every index is in
// range, and every `node_entity` is bounded by the list its own `node_kind` names, which
// is what tells those two arrays apart if they were ever filled from one pointer.
template <class Fem>
static Result<void> fem_arrays(const Fem& mesh, std::size_t edge_count, std::size_t vertex_count, const std::string& what) {
    cadaclysm::Span<const double> nodes = mesh.nodes();
    cadaclysm::Span<const std::uint32_t> triangles = mesh.triangles();
    EXPECT(!nodes.empty() && !triangles.empty(), what + ": an empty mesh came back as success");
    EXPECT(nodes.size() % 3 == 0 && triangles.size() % 3 == 0, what + ": the nodes or the triangles are not triples");
    std::size_t node_count = nodes.size() / 3, triangle_count = triangles.size() / 3;
    EXPECT(mesh.triangle_face().size() == triangle_count && mesh.node_kind().size() == node_count &&
               mesh.node_entity().size() == node_count,
           what + ": the arrays disagree -- " + std::to_string(node_count) + " nodes, " + std::to_string(triangle_count) +
               " triangles, " + std::to_string(mesh.triangle_face().size()) + " triangle_face, " +
               std::to_string(mesh.node_kind().size()) + " node_kind, " + std::to_string(mesh.node_entity().size()) + " node_entity");
    for (std::uint32_t i : triangles) EXPECT(i < node_count, what + ": a triangle index points past the nodes");
    for (std::uint32_t f : mesh.triangle_face()) {
        EXPECT(f < mesh.face_count(), what + ": a triangle_face is not one of the body's " + std::to_string(mesh.face_count()) + " faces");
    }
    cadaclysm::Span<const std::uint32_t> kinds = mesh.node_kind(), entities = mesh.node_entity();
    for (std::size_t i = 0; i < kinds.size(); ++i) {
        std::size_t bound = 0;
        switch (kinds[i]) {
            case 0: bound = vertex_count; break;
            case 1: bound = edge_count; break;
            case 2: bound = mesh.face_count(); break;
            default:
                return Error{what + ": node " + std::to_string(i) + " has kind " + std::to_string(kinds[i]) +
                             ", which is neither vertex, edge nor face"};
        }
        EXPECT(entities[i] < bound, what + ": node " + std::to_string(i) + " is on entity " + std::to_string(entities[i]) +
                                        " of kind " + std::to_string(kinds[i]) + ", which has only " + std::to_string(bound));
    }
    return {};
}

// The `.msh` text and the file, on either side: the same bytes from the same writer, and
// two asks giving two equal strings -- which on the reader's side means the wrapper copied
// the library's borrowed slot out, and on the kernel's that it freed the owned string
// without handing back a dangling one.
template <class Fem>
static Result<void> fem_msh(const Fem& mesh, const char* file, const std::string& what) {
    CADACLYSM_TRY(text, mesh.msh_text());
    CADACLYSM_TRY(again, mesh.msh_text());
    EXPECT(text.rfind("$MeshFormat\n4.1 0 8\n", 0) == 0,
           what + ": the .msh text does not open as Gmsh 4.1 ASCII: " + text.substr(0, std::min<std::size_t>(40, text.size())));
    EXPECT(again == text, what + ": two asks for the same mesh's .msh text disagree");
    std::string path = temp_file(file);
    CADACLYSM_TRY_VOID(mesh.save_msh(path));
    std::error_code size_error;
    auto written = std::filesystem::file_size(cadaclysm::detail::fs_path(path), size_error);
    EXPECT(!size_error && written >= text.size() / 2,
           what + ": save_msh wrote " + std::to_string(written) + " bytes against " + std::to_string(text.size()) + " of text");
    return {};
}

// # **Which count feeds which entry point** -- the census *wiring*, which nothing else here
// pins. Every other FEM check proves a row is extracted correctly; none proves `open_edges()`
// reads `open_edge_count` rows through `cadaclysm_fem_mesh_open_edge` rather than the folded
// count or the folded call.
//
// `samples/open-sheet.scad` is the only body in this repository where both censuses are
// non-empty and of different lengths: the B-rep path computes no census unless the topology is
// closed (the documented "not asked" pair) and every closed body has none, while the mesh path
// always computes one -- so a `polyhedron` with a flap over one of its own directed edges is
// the way in. Six cracks, one fold, and the fold is not the first crack.
static Result<void> fem_census_wiring(const std::string& sheet) {
    CADACLYSM_TRY(scene, cadaclysm::open(sheet));
    std::vector<cadaclysm::Node> bodies = scene.walk();
    auto body = std::find_if(bodies.begin(), bodies.end(), [](const cadaclysm::Node& n) { return n.can_mesh(); });
    EXPECT(body != bodies.end(), "fem census: open-sheet.scad has no meshable node");
    CADACLYSM_TRY(mesh, body->fem_mesh());
    EXPECT(mesh.nodes().size() == 5 * 3 && mesh.triangles().size() == 3 * 3 && mesh.from_mesh() && !mesh.watertight(),
           "fem census: open-sheet.scad read " + std::to_string(mesh.nodes().size() / 3) + " nodes, " +
               std::to_string(mesh.triangles().size() / 3) + " triangles, watertight " +
               std::to_string(mesh.watertight() ? 1 : 0));
    CADACLYSM_TRY(cracks, mesh.open_edges());
    CADACLYSM_TRY(folds, mesh.folded_edges());
    // The counts are what separate the two lists: a swapped count reads 1 where 6 belongs, and a
    // swapped call cannot read row 1 of a one-row table at all.
    EXPECT(cracks.size() == 6 && folds.size() == 1,
           "fem census: " + std::to_string(cracks.size()) + " cracks and " + std::to_string(folds.size()) +
               " folds, not 6 and 1");
    // And the contents, which separates a wrapper that swapped both consistently.
    EXPECT(folds[0] == (std::array<std::uint32_t, 3>{2, 0, cadaclysm::NONE}),
           "fem census: the fold reads (" + std::to_string(folds[0][0]) + "," + std::to_string(folds[0][1]) + "," +
               std::to_string(folds[0][2]) + "), not (2,0,NONE)");
    EXPECT(cracks[0][0] == 1 && cracks[0][1] == 2,
           "fem census: the first crack reads (" + std::to_string(cracks[0][0]) + "," +
               std::to_string(cracks[0][1]) + "), not (1,2)");
    std::printf("fem census: open-sheet.scad reads %zu cracks and %zu fold at (%u,%u)\n", cracks.size(), folds.size(),
                folds[0][0], folds[0][1]);
    return {};
}

// The reader's FEM mesh over a node with no B-rep: the **mesh-only** path, where
// `from_mesh` is true, there are no edges and no vertices, and -- the trap the plan names
// -- `fem_mesh_of_mesh` reads no options at all, so a tolerance or a size the B-rep path
// refuses still comes back as a mesh.
static Result<void> fem_reader(const cadaclysm::Scene& scene, bool is_cube) {
    std::vector<cadaclysm::Node> bodies = scene.walk();
    auto body = std::find_if(bodies.begin(), bodies.end(), [](const cadaclysm::Node& n) { return n.can_mesh(); });
    EXPECT(body != bodies.end(), "fem: no meshable node");
    CADACLYSM_TRY(mesh, body->fem_mesh());
    CADACLYSM_TRY(edges, mesh.edges());
    CADACLYSM_TRY(vertices, mesh.vertices());
    CADACLYSM_TRY_VOID(fem_arrays(mesh, edges.size(), vertices.size(), "fem reader"));

    // A mesh-only body: one face, every node on it, no topology at all -- and its census
    // does run over the welded triangles, so an empty one here means "nothing found".
    EXPECT(mesh.from_mesh(), "fem: a node with no brep did not report from_mesh");
    cadaclysm::Span<const std::uint32_t> kinds = mesh.node_kind();
    EXPECT(mesh.face_count() == 1 && edges.empty() && vertices.empty() &&
               std::all_of(kinds.begin(), kinds.end(), [](std::uint32_t k) { return k == 2; }),
           "fem: a from_mesh body has edges, vertices or a node off face 0");
    CADACLYSM_TRY(open, mesh.open_edges());
    CADACLYSM_TRY(folded, mesh.folded_edges());
    EXPECT(mesh.watertight() && open.empty() && folded.empty(),
           "fem: the cube's own mesh is not watertight with both censuses empty");
    EXPECT(mesh.min_angle() > 0.0 && mesh.min_angle() <= 60.0 && mesh.worst_triangle() < mesh.triangles().size() / 3 &&
               mesh.longest_edge() > 0.0,
           "fem: the quality figures read " + std::to_string(mesh.min_angle()) + " deg, triangle " +
               std::to_string(mesh.worst_triangle()) + ", longest " + std::to_string(mesh.longest_edge()));
    if (is_cube) {
        EXPECT(mesh.nodes().size() == 8 * 3 && mesh.triangles().size() == 12 * 3,
               "fem: the cube meshed to " + std::to_string(mesh.nodes().size() / 3) + " nodes, " +
                   std::to_string(mesh.triangles().size() / 3) + " triangles");
    }
    CADACLYSM_TRY_VOID(fem_msh(mesh, "cadaclysm-smoke-cpp-fem.msh", "fem"));
    std::printf("fem reader: %zu nodes, %zu triangles, from_mesh=%d\n", mesh.nodes().size() / 3,
                mesh.triangles().size() / 3, mesh.from_mesh() ? 1 : 0);

    // The default tolerance is pinned in `fem_brep`, not here: **this body cannot see it.**
    // A mesh-only body's mesher reads no options at all, so the cube meshes to the same 8
    // nodes at 0.01 and at 0.05 alike -- which is exactly how one wrapper's wrong default
    // survived seventy-five other tests. A defaults pin needs a body with curvature.

    // The placement reaches the library, and in the right order. Catches: a placement
    // dropped (the nodes stay where the body is), applied twice, transposed (+y for -y),
    // or composed the other way round (the origin at (0, 100, 0), not (100, 0, 0)).
    // Every node is checked, not one convenient point: a transpose leaves the corner at
    // the origin correct.
    std::array<double, 16> turn{};
    for (std::size_t i = 0; i < 16; ++i) turn[i] = TURNED[i];
    CADACLYSM_TRY(placed, body->fem_mesh(0.01, 0.0, turn));
    CADACLYSM_TRY(plain, body->fem_mesh(0.01, 0.0));
    EXPECT(placed.nodes().size() == plain.nodes().size(), "fem: the placement changed the node count");
    std::pair<cadaclysm::Vec3, cadaclysm::Vec3> placed_box = node_span(placed.nodes());
    cadaclysm::Span<const double> unplaced = plain.nodes();
    for (std::size_t i = 0; i + 2 < unplaced.size(); i += 3) {
        cadaclysm::Vec3 p{unplaced[i], unplaced[i + 1], unplaced[i + 2]};
        EXPECT(has_node(placed.nodes(), turned(p)),
               "fem: the placement did not send " + where(p) + " to " + where(turned(p)) + " -- the placed nodes span " +
                   where(placed_box.first) + ".." + where(placed_box.second));
    }
    std::pair<cadaclysm::Vec3, cadaclysm::Vec3> plain_box = node_span(unplaced);
    EXPECT(near_to(placed_box.first, turned({plain_box.first[0], plain_box.second[1], plain_box.first[2]})) &&
               near_to(placed_box.second, turned({plain_box.second[0], plain_box.first[1], plain_box.second[2]})),
           "fem: the placed nodes span " + where(placed_box.first) + ".." + where(placed_box.second) + ", not the turn of " +
               where(plain_box.first) + ".." + where(plain_box.second));
    std::printf("fem reader: the placement turns and moves %s..%s into %s..%s\n", where(plain_box.first).c_str(),
                where(plain_box.second).c_str(), where(placed_box.first).c_str(), where(placed_box.second).c_str());

    // **Neither `tolerance` nor `max_size` is checked by this wrapper**, and the mesh-only
    // path reads neither: `fem_mesh_of_mesh` takes no options at all. Catches a wrapper
    // that validated either field itself -- which passes every Python-shaped test and is
    // wrong. The B-rep half of this contract is in `fem_brep`, where each *is* refused.
    const double nan = std::numeric_limits<double>::quiet_NaN();
    const double inf = std::numeric_limits<double>::infinity();
    const std::pair<double, double> waved[] = {{0.0, 0.0}, {-1.0, 0.0}, {nan, 0.0}, {0.01, -1.0}, {0.01, nan}, {0.01, inf}};
    for (const std::pair<double, double>& pair : waved) {
        auto anyway = body->fem_mesh(pair.first, pair.second);
        EXPECT(anyway.ok(), "fem: tolerance " + std::to_string(pair.first) + " max_size " + std::to_string(pair.second) +
                           " was refused on the mesh-only path: " + (anyway ? std::string() : anyway.error().message));
        EXPECT(!anyway->nodes().empty(), "fem: tolerance " + std::to_string(pair.first) + " max_size " +
                                             std::to_string(pair.second) + " came back as an empty mesh");
    }
    std::puts("fem reader: tolerance 0/-1/NaN and max_size -1/NaN/+Inf all mesh on the mesh-only path");
    return {};
}

// The FEM mesh is its **own** handle: `Scene::close` neither frees it nor stales it, so
// every array still reads after the scene it was built through is gone. Catches a wrapper
// that hung the mesh off the scene's state -- which every other view here does, and which
// would make this read a freed block or trip the stale-view check.
static Result<void> fem_outlives_its_scene(const std::string& path) {
    std::vector<double> kept;
    std::size_t triangles = 0;
    {
        CADACLYSM_TRY(scene, cadaclysm::open(path));
        std::vector<cadaclysm::Node> bodies = scene.walk();
        auto body = std::find_if(bodies.begin(), bodies.end(), [](const cadaclysm::Node& n) { return n.can_mesh(); });
        EXPECT(body != bodies.end(), "fem: no meshable node");
        CADACLYSM_TRY(mesh, body->fem_mesh());
        scene.close();
        EXPECT(!trips([&] { (void)mesh.nodes(); }),
               "fem: a FEM mesh read after Scene::close tripped -- the mesh owns its arrays, so it must not borrow the "
               "scene's state the way every other view here does");
        cadaclysm::Span<const double> nodes = mesh.nodes();
        EXPECT(!nodes.empty(), "fem: the nodes are empty after the scene closed");
        kept.assign(nodes.begin(), nodes.end());
        triangles = mesh.triangles().size() / 3;
        CADACLYSM_TRY(edges, mesh.edges());
        EXPECT(edges.empty(), "fem: the mesh-only body grew edges after the scene closed");
        CADACLYSM_TRY(text, mesh.msh_text());
        EXPECT(!text.empty(), "fem: the .msh text is empty after the scene closed");
        EXPECT(!mesh.freed(), "fem: closing the scene freed the FEM mesh");
    }
    EXPECT(kept.size() % 3 == 0 && triangles > 0, "fem: the copy taken after the close is not a mesh");
    std::printf("fem reader: %zu nodes and %zu triangles still read after Scene::close\n", kept.size() / 3, triangles);
    return {};
}

// samples/edge-colours.stp sits beside the given sample and paints one edge teal
// (0.1, 0.6, 0.55) on the body -- everything else, edge and surface-edge alike, stays
// unstyled.
static Result<void> edge_colours_check(const std::string& path) {
    std::filesystem::path sibling = std::filesystem::path(path).parent_path() / "edge-colours.stp";
    CADACLYSM_TRY(scene, cadaclysm::open(utf8(sibling)));
    std::vector<cadaclysm::Node> bodies = scene.walk();
    auto body = std::find_if(bodies.begin(), bodies.end(), [](const cadaclysm::Node& n) { return !n.edges().empty(); });
    EXPECT(body != bodies.end(), "edge colours: no node with edges");
    struct Row {
        std::size_t count;
        std::vector<std::optional<std::array<float, 4>>> colours;
    };
    std::vector<Row> rows{{body->edges().polyline_count(), body->edge_colours()},
                           {body->surface_edges().polyline_count(), body->surface_edge_colours()}};
    for (const Row& row : rows) {
        EXPECT(row.colours.size() == row.count, "edge colours: entry count does not equal the polyline count");
        std::size_t styled_count = 0;
        std::optional<std::array<float, 4>> styled;
        for (const auto& c : row.colours) {
            if (c) {
                ++styled_count;
                styled = c;
            }
        }
        EXPECT(styled_count == 1, "edge colours: not exactly one styled entry");
        EXPECT(styled.has_value() && std::abs((*styled)[0] - 0.1f) <= 1e-6f && std::abs((*styled)[1] - 0.6f) <= 1e-6f &&
                   std::abs((*styled)[2] - 0.55f) <= 1e-6f && std::abs((*styled)[3] - 1.0f) <= 1e-6f,
               "edge colours: the styled entry is not (0.1, 0.6, 0.55, 1.0)");
    }
    std::printf("edge colours: one edge teal on %zu/%zu polylines\n", rows[0].count, rows[1].count);
    return {};
}

// The reader's FEM mesh over a node **with** a B-rep: the path that carries topology, and
// the one that refuses a bad tolerance.
static Result<void> fem_brep(const cadaclysm::Scene& back) {
    std::optional<cadaclysm::Node> body;
    for (const cadaclysm::Placement& placement : back.placements()) {
        cadaclysm::Node geometry = placement.geometry();
        if (geometry.brep()) {
            body = geometry;
            break;
        }
    }
    EXPECT(body.has_value(), "fem brep: no placement of the read-back STEP has a brep");
    CADACLYSM_TRY(mesh, body->fem_mesh(0.05));
    CADACLYSM_TRY(edges, mesh.edges());
    CADACLYSM_TRY(vertices, mesh.vertices());
    CADACLYSM_TRY_VOID(fem_arrays(mesh, edges.size(), vertices.size(), "fem brep"));

    // The other half of the from_mesh proof: this body has a brep, and `watertight` is
    // true for both bodies, so it is that flag which tells them apart rather than luck.
    EXPECT(!mesh.from_mesh(), "fem brep: a body with a brep reported from_mesh");
    EXPECT(mesh.face_count() == 15, "fem brep: the filleted part read back as " + std::to_string(mesh.face_count()) + " faces, not 15");
    EXPECT(!edges.empty() && !vertices.empty(), "fem brep: a brep body has no edges or no vertices");
    cadaclysm::Span<const std::uint32_t> kinds = mesh.node_kind();
    for (std::uint32_t k = 0; k < 3; ++k) {
        EXPECT(std::find(kinds.begin(), kinds.end(), k) != kinds.end(),
               "fem brep: no node lies on an entity of kind " + std::to_string(k));
    }

    // `id` is the **body's own** edge id, not the index: the ids ascend, and at least one
    // is not its own index -- which is what catches an id filled from the loop counter.
    bool ascending = true, some_id_is_not_its_index = false;
    for (std::size_t i = 0; i < edges.size(); ++i) {
        if (i > 0) ascending = ascending && edges[i - 1].id < edges[i].id;
        some_id_is_not_its_index = some_id_is_not_its_index || edges[i].id != static_cast<std::uint32_t>(i);
    }
    EXPECT(ascending, "fem brep: the edge ids do not ascend");
    EXPECT(some_id_is_not_its_index, "fem brep: every edge id equals its own index -- id is the index, not the body's id");
    std::size_t node_count = mesh.nodes().size() / 3;
    for (std::size_t i = 0; i < edges.size(); ++i) {
        const cadaclysm::FemEdge& edge = edges[i];
        std::string which = "fem brep: edge " + std::to_string(i);
        EXPECT(!edge.runs.empty() && edge.runs[0] == 0, which + "'s first run does not start at 0");
        bool runs_ascend = true;
        for (std::size_t r = 0; r < edge.runs.size(); ++r) {
            runs_ascend = runs_ascend && edge.runs[r] < edge.nodes.size() && (r == 0 || edge.runs[r - 1] < edge.runs[r]);
        }
        EXPECT(runs_ascend, which + "'s runs do not ascend inside its " + std::to_string(edge.nodes.size()) + " nodes");
        EXPECT(edge.chains().size() == edge.runs.size(), which + "'s chains() does not give one polyline per run");
        std::size_t chained = 0;
        for (cadaclysm::Span<const std::uint32_t> chain : edge.chains()) chained += chain.size();
        EXPECT(chained == edge.nodes.size(), which + "'s chains() cover " + std::to_string(chained) + " of its " +
                                                 std::to_string(edge.nodes.size()) + " nodes");
        for (std::uint32_t n : edge.nodes) EXPECT(n < node_count, which + " names a node past the mesh");
        // A closed body: every edge has two real faces, and neither is a sentinel.
        EXPECT(edge.faces.first < mesh.face_count() && edge.faces.second < mesh.face_count(),
               which + " bounds faces (" + std::to_string(edge.faces.first) + ", " + std::to_string(edge.faces.second) + ") of " +
                   std::to_string(mesh.face_count()));
        EXPECT(!edge.closed || edge.runs.size() == 1, which + " is closed with " + std::to_string(edge.runs.size()) + " runs");
        if (edge.seam) EXPECT(edge.faces.first == edge.faces.second, which + " is a seam but bounds two different faces");
        // The ends resolve through `vertices` to the chain's own first or last node --
        // which is what tells `ends` from `faces`, both a pair a swap leaves in range.
        for (std::uint32_t v : {edge.ends.first, edge.ends.second}) {
            if (v == cadaclysm::NONE) continue;
            EXPECT(v < vertices.size(), which + " ends at vertex " + std::to_string(v) + " of " + std::to_string(vertices.size()));
            std::uint32_t at = vertices[v].node;
            if (at == cadaclysm::NONE) continue;
            EXPECT(!edge.nodes.empty() && (at == edge.nodes[0] || at == edge.nodes[edge.nodes.size() - 1]),
                   which + "'s end vertex " + std::to_string(v) + " is node " + std::to_string(at) +
                       ", which is neither end of its chain");
        }
    }
    bool some_position = false, zeroed_without_one = true;
    for (const cadaclysm::FemVertex& vertex : vertices) {
        some_position = some_position || vertex.has_position;
        zeroed_without_one = zeroed_without_one &&
                             (vertex.has_position || vertex.point == (cadaclysm::Vec3{0, 0, 0}));
    }
    EXPECT(some_position, "fem brep: no vertex has a position");
    EXPECT(zeroed_without_one, "fem brep: a vertex with no position carries a point that is not zeroed");
    CADACLYSM_TRY(open, mesh.open_edges());
    CADACLYSM_TRY(folded, mesh.folded_edges());
    EXPECT(mesh.watertight() && open.empty() && folded.empty(),
           "fem brep: the closed filleted part is not watertight with both censuses empty");
    std::printf("fem brep: %zu nodes, %zu edges (edge 0 id=%u), %zu vertices, %u faces\n", mesh.nodes().size() / 3,
                edges.size(), edges[0].id, vertices.size(), mesh.face_count());

    // **The default tolerance is the library's own 0.01, not the 0.05 that `mesh` and its
    // neighbours default to.** Pinned on this body because it is curved and exact: the
    // mesh-only cube above meshes to 8 nodes at either figure, so a pin there would pass
    // whatever the default was. All three assertions are needed -- the default must equal
    // 0.01's count and must *not* equal 0.05's, which is what catches a wrapper that
    // reached for the neighbouring default and handed a caller a five-times coarser mesh.
    CADACLYSM_TRY(defaulted, body->fem_mesh());
    CADACLYSM_TRY(at_hundredth, body->fem_mesh(0.01));
    EXPECT(defaulted.nodes().size() == at_hundredth.nodes().size(),
           "fem brep: fem_mesh() with no arguments is not fem_mesh(0.01) -- the default tolerance is not FemOptions::default()'s 0.01");
    EXPECT(defaulted.nodes().size() != mesh.nodes().size(),
           "fem brep: fem_mesh() and fem_mesh(0.05) agree on a curved body, so the default may be the neighbours' 0.05");
    std::printf("fem brep: %zu nodes at the default tolerance, %zu at 0.05\n", defaulted.nodes().size() / 3,
                mesh.nodes().size() / 3);

    // The B-rep path **does** read the options, and refuses a bad tolerance in the
    // library's own words -- which is what proves the wrapper surfaces the library's
    // message rather than one of its own.
    auto refused = body->fem_mesh(0.0);
    EXPECT(!refused, "fem brep: tolerance 0 was accepted on the B-rep path");
    EXPECT(refused.error().message.find("tolerance must be finite and > 0") != std::string::npos,
           "fem brep: tolerance 0 was refused in other words: " + refused.error().message);
    return {};
}

// The kernel's FEM mesh: the same surface over the kernel's own ABI, with the three
// deliberate asymmetries -- an **owned** `.msh` string, a **twelve**-number placement,
// and the licence notice on the writers rather than on the builder.
static Result<void> fem_kernel(const bs::Solid& rounded, const bs::Solid& sheet) {
    CADACLYSM_TRY(mesh, rounded.fem_mesh(0.05));
    CADACLYSM_TRY(edges, mesh.edges());
    CADACLYSM_TRY(vertices, mesh.vertices());
    CADACLYSM_TRY_VOID(fem_arrays(mesh, edges.size(), vertices.size(), "kernel fem"));
    EXPECT(!mesh.from_mesh(), "kernel fem: a solid reported from_mesh -- the kernel has no mesh path");
    EXPECT(mesh.face_count() == 15, "kernel fem: the filleted part has " + std::to_string(mesh.face_count()) + " faces, not 15");
    CADACLYSM_TRY(open, mesh.open_edges());
    CADACLYSM_TRY(folded, mesh.folded_edges());
    EXPECT(mesh.watertight() && open.empty() && folded.empty(),
           "kernel fem: the filleted part is not watertight with both censuses empty");
    CADACLYSM_TRY_VOID(fem_msh(mesh, "cadaclysm-smoke-cpp-kernel-fem.msh", "kernel fem"));
    std::size_t node_count = mesh.nodes().size() / 3;
    double longest = mesh.longest_edge();

    // A progress callback reaches the library through the noexcept trampoline, and hears
    // the two phases the ABI names.
    std::size_t reports = 0;
    bool meshing = false, welding = false;
    CADACLYSM_TRY(watched, rounded.fem_mesh(0.05, 0.0, std::nullopt,
                                            [&](std::string_view phase, std::size_t, std::size_t) {
                                                ++reports;
                                                meshing = meshing || phase == "meshing";
                                                welding = welding || phase == "welding";
                                            }));
    EXPECT(reports > 0 && meshing && welding, "kernel fem: the progress callback did not hear both meshing and welding");
    EXPECT(watched.nodes().size() == mesh.nodes().size(), "kernel fem: the watched mesh is not the same mesh");

    // **The default tolerance is 0.01, `FemOptions::default()`'s -- not the kernel's own
    // `DEFAULT_TOLERANCE` of 0.05 that every neighbouring method takes.** A wrapper that
    // copied the neighbour gives a caller a five-times coarser solver mesh unasked.
    CADACLYSM_TRY(defaulted, rounded.fem_mesh());
    CADACLYSM_TRY(at_hundredth, rounded.fem_mesh(0.01));
    EXPECT(defaulted.nodes().size() == at_hundredth.nodes().size(),
           "kernel fem: fem_mesh() with no arguments is not fem_mesh(0.01) -- the default is not FemOptions::default()'s 0.01");
    EXPECT(defaulted.nodes().size() != node_count,
           "kernel fem: fem_mesh() and fem_mesh(0.05) agree, so the default may be the neighbours' 0.05");

    // **A FEM mesh is not in the solid's tessellation cache**, so re-meshing the solid at
    // another tolerance must not stale it: `Solid::fem_mesh` is the one array product here
    // whose views carry no generation check. Catches that guard wired in by reflex from
    // `Mesh`, where it belongs.
    CADACLYSM_TRY(coarse, rounded.mesh(0.5));
    std::uint32_t coarse_triangles = coarse.triangle_count();
    CADACLYSM_TRY(kept, rounded.fem_mesh(0.05));
    CADACLYSM_TRY(fine, rounded.mesh(0.05));
    EXPECT(fine.triangle_count() != coarse_triangles,
           "kernel fem: the two tolerances meshed the same -- the re-mesh did not happen");
    EXPECT(!trips([&] { (void)kept.nodes(); }),
           "kernel fem: a FEM mesh read after the solid was meshed again tripped -- a FEM mesh is its own handle, not a "
           "product of the tessellation cache, so it must not carry Mesh's generation guard");
    EXPECT(kept.nodes().size() / 3 == node_count, "kernel fem: a FEM mesh taken before a re-mesh reads a different node count after it");
    CADACLYSM_TRY(kept_edges, kept.edges());
    EXPECT(kept_edges.size() == edges.size(), "kernel fem: a FEM mesh's edges do not read after the solid was meshed again");
    std::printf("kernel fem: %zu nodes, %zu edges, still readable across a re-mesh at another tolerance\n", node_count, edges.size());

    // `max_size` adds nodes and shortens the longest edge -- but it **bounds the boundary
    // and only targets the interior**, so the ceiling is checked loosely on purpose: a
    // tighter pin would assert what the ABI does not promise (measured at 1.03x).
    CADACLYSM_TRY(finer, rounded.fem_mesh(0.05, 3.0));
    EXPECT(finer.nodes().size() > mesh.nodes().size() && finer.longest_edge() < longest,
           "kernel fem: max_size 3 gave " + std::to_string(finer.nodes().size() / 3) + " nodes (was " + std::to_string(node_count) +
               ") and a longest edge of " + std::to_string(finer.longest_edge()) + " (was " + std::to_string(longest) + ")");
    EXPECT(finer.longest_edge() <= 3.0 * 1.05,
           "kernel fem: max_size 3 left a " + std::to_string(finer.longest_edge()) + " edge, past even the 1.03x the spec measured");
    std::printf("kernel fem: longest edge %g at max_size 0, %g at 3.0\n", longest, finer.longest_edge());

    // The open sheet -- one face with a hole, so its rim is both the outer and the inner
    // loop. `watertight` false with **both censuses empty** is the "not asked" trio, and
    // every rim edge has a real face and the NONE sentinel for its second. Catches a
    // wrapper that filled `face_b` with 0 where the ABI said NONE: 0 is a real face.
    CADACLYSM_TRY(rim, sheet.fem_mesh(0.05));
    CADACLYSM_TRY(rim_open, rim.open_edges());
    CADACLYSM_TRY(rim_folded, rim.folded_edges());
    EXPECT(!rim.watertight() && rim_open.empty() && rim_folded.empty(),
           "kernel fem: the open sheet reads watertight=" + std::to_string(rim.watertight() ? 1 : 0) + " with " +
               std::to_string(rim_open.size()) + " open and " + std::to_string(rim_folded.size()) +
               " folded rows -- the 'not asked' trio is all three");
    CADACLYSM_TRY(rim_edges, rim.edges());
    EXPECT(!rim_edges.empty(), "kernel fem: the sheet has no edges");
    for (std::size_t i = 0; i < rim_edges.size(); ++i) {
        EXPECT(rim_edges[i].faces.first == 0 && rim_edges[i].faces.second == bs::NONE,
               "kernel fem: the sheet's rim edge " + std::to_string(i) + " reads faces (" +
                   std::to_string(rim_edges[i].faces.first) + ", " + std::to_string(rim_edges[i].faces.second) + "), not (0, NONE)");
    }
    std::printf("kernel fem: the sheet's %zu rim edges each bound face 0 and nothing else\n", rim_edges.size());

    // The placement: **twelve** numbers as a Frame, where the reader takes sixteen
    // column-major -- the same transform, asserted against the same expected map. A
    // cuboid, because all eight of its corners are B-rep vertices and so certainly nodes,
    // and **moved off the rotation's axis in the plane the turn acts in**: centred on its
    // own origin the check is mathematically blind (see TURNED).
    const cadaclysm::Vec3 size{20, 10, 4};
    const cadaclysm::Vec3 off{30, 7, 5};
    const cadaclysm::Vec3 box_lo{off[0] - size[0] / 2, off[1] - size[1] / 2, off[2] - size[2] / 2};
    const cadaclysm::Vec3 box_hi{off[0] + size[0] / 2, off[1] + size[1] / 2, off[2] + size[2] / 2};
    CADACLYSM_TRY(built, bs::Solid::cuboid(size[0], size[1], size[2]));
    CADACLYSM_TRY(cuboid, built.translate(off[0], off[1], off[2]));
    CADACLYSM_TRY(frame, turned_frame());
    CADACLYSM_TRY(placed, cuboid.fem_mesh(0.05, 0.0, frame));
    std::pair<cadaclysm::Vec3, cadaclysm::Vec3> placed_box = node_span(placed.nodes());
    for (const cadaclysm::Vec3& corner : corners(box_lo, box_hi)) {
        EXPECT(has_node(placed.nodes(), turned(corner)),
               "kernel fem: the frame did not send the corner " + where(corner) + " to " + where(turned(corner)) +
                   " -- the nodes span " + where(placed_box.first) + ".." + where(placed_box.second));
    }
    EXPECT(near_to(placed_box.first, turned({box_lo[0], box_hi[1], box_lo[2]})) &&
               near_to(placed_box.second, turned({box_hi[0], box_lo[1], box_hi[2]})),
           "kernel fem: the placed cuboid spans " + where(placed_box.first) + ".." + where(placed_box.second) + ", not the turn of " +
               where(box_lo) + ".." + where(box_hi));
    std::printf("kernel fem: the frame turns and moves the cuboid into %s..%s\n", where(placed_box.first).c_str(),
                where(placed_box.second).c_str());

    // A tolerance the mesher refuses, in its own words: the kernel has no mesh-only path,
    // so unlike the reader every solid goes through the options.
    auto refused = rounded.fem_mesh(0.0);
    EXPECT(!refused, "kernel fem: tolerance 0 was accepted");
    EXPECT(refused.error().message.find("tolerance must be finite and > 0") != std::string::npos,
           "kernel fem: tolerance 0 was refused in other words: " + refused.error().message);
    EXPECT(refused.error().origin == cadaclysm::Origin::kernel, "kernel fem: the refusal did not come from the kernel");

    // Freed by hand, and the handle check holds in both modes -- it guards a pointer
    // handed to C, as Meshlets' does, not a view, so it is not CADACLYSM_CHECKED's to
    // switch off. A second free is a no-op.
    CADACLYSM_TRY(doomed, rounded.fem_mesh(0.05));
    doomed.free();
    EXPECT(doomed.freed(), "kernel fem: free() did not free");
    doomed.free();
    EXPECT(trips([&] { (void)doomed.nodes(); }), "kernel fem: a read after free() did not trip");
    EXPECT(trap::message.find("freed") != std::string::npos, "kernel fem: the trip does not say the mesh is freed");
    return {};
}

static Result<void> save_checks(const cadaclysm::Scene& scene) {
    std::vector<cadaclysm::MeshFormat> formats = cadaclysm::mesh_formats();
    EXPECT(std::any_of(formats.begin(), formats.end(), [](const cadaclysm::MeshFormat& f) { return f.name == "stl"; }),
           "stl is not among the mesh formats");

    std::string stl = temp_file("cadaclysm-smoke-cpp.stl");
    std::vector<cadaclysm::Node> roots = scene.roots();
    EXPECT(!roots.empty(), "the scene has no root nodes to save a mesh from");
    CADACLYSM_TRY_VOID(roots.front().save_mesh(stl, "stl"));
    std::error_code size_error;
    auto written = std::filesystem::file_size(cadaclysm::detail::fs_path(stl), size_error);
    EXPECT(!size_error && written >= 84, "save_mesh wrote no triangles");
    EXPECT(!roots.front().save_mesh(stl, "no-such-format"), "save_mesh accepted an unknown format");

    std::string glb = temp_file("cadaclysm-smoke-cpp.glb");
    CADACLYSM_TRY_VOID(scene.save(glb, "glb"));
    CADACLYSM_TRY(head, read_file(glb));
    EXPECT(head.size() >= 4 && std::string(head.data(), 4) == "glTF", "save wrote something that is not a binary glTF");

    // The scene's SVG, the same two ways; a node's own, in its own frame; and a
    // refusal (an out-of-range fov) surfacing as an Error rather than a crash.
    cadaclysm::SvgOptions options;
    CADACLYSM_TRY(svg_text, scene.svg_text(options));
    EXPECT(svg_text.rfind("<svg", 0) == 0, "svg_text does not start with <svg");
    EXPECT(svg_text.find("<path") != std::string::npos, "svg_text has no <path");
    std::string svg = temp_file("cadaclysm-smoke-cpp.svg");
    CADACLYSM_TRY_VOID(scene.svg(svg, options));
    CADACLYSM_TRY(svg_head, read_file(svg));
    EXPECT(!svg_head.empty() && std::string(svg_head.data(), 4) == "<svg", "svg wrote something that does not start with <svg");
    EXPECT(std::string(svg_head.begin(), svg_head.end()) == svg_text, "svg's file does not match svg_text's own text");

    cadaclysm::SvgOptions node_options;
    node_options.view = cadaclysm::SvgView::front;
    CADACLYSM_TRY(node_svg_text, roots.front().svg_text(node_options));
    EXPECT(node_svg_text.rfind("<svg", 0) == 0 && node_svg_text.find("<path") != std::string::npos,
           "a node's own svg_text is not a drawing");

    cadaclysm::SvgOptions refused;
    refused.fov = 200;
    Result<std::string> bad_fov = scene.svg_text(refused);
    EXPECT(!bad_fov, "fov = 200 was accepted");
    EXPECT(bad_fov.error().message.find("fov") != std::string::npos, "the fov refusal does not name the field");
    return {};
}

static Result<void> reader(const std::string& path) {
    CADACLYSM_TRY(scene, cadaclysm::open(path));
    cadaclysm::Bounds bounds = scene.bounds();
    std::printf("bounds min=(%g, %g, %g) max=(%g, %g, %g)\n", bounds.min[0], bounds.min[1], bounds.min[2],
                bounds.max[0], bounds.max[1], bounds.max[2]);

    std::size_t triangles = 0;
    for (const cadaclysm::Node& node : scene.walk()) {
        if (node.can_mesh()) triangles += node.mesh().triangle_count();
    }
    std::printf("triangles=%zu\n", triangles);

    bool is_cube = cadaclysm::detail::file_name(path) == "cube.scad";
    if (is_cube) {
        // All six values: a bug that only flips Y still passes the X and Z checks.
        EXPECT(bounds.min == (std::array<float, 3>{0, 0, 0}) && bounds.max == (std::array<float, 3>{20, 20, 20}),
               "the cube's bounds are not 0..20 on every axis");
        EXPECT(!bounds.is_empty() && bounds.centre() == (std::array<float, 3>{10, 10, 10}),
               "Bounds::centre is not the cube's middle");
    }

    // The reader's own extras: a query, the diagnostics, the placements, the tree.
    CADACLYSM_TRY(matched, scene.query("class == solid"));
    std::printf("query: %zu node(s)\n", matched.size());
    EXPECT(!scene.query("class =="), "a filter that does not parse was accepted");
    std::printf("diagnostics: %zu\n", scene.diagnostics().size());
    std::vector<cadaclysm::Format> readers = cadaclysm::formats();
    EXPECT(std::any_of(readers.begin(), readers.end(), [](const cadaclysm::Format& f) {
               return f.name == "IGES" && f.extensions == std::vector<std::string>{"iges", "igs"};
           }),
           "formats() lacks IGES iges;igs");
    std::vector<cadaclysm::MeshFormat> labelled = cadaclysm::mesh_formats();
    EXPECT(std::any_of(labelled.begin(), labelled.end(), [](const cadaclysm::MeshFormat& f) { return f.name == "stl" && f.label == "STL (binary)"; }),
           "mesh format label is not the library's");
    std::printf("geometry diagnostics: %zu\n", scene.geometry_diagnostics().size());

    // Kinematics: a file with no mechanism carries no links or joints; mechanism.stp,
    // beside whatever sample this smoke was given, carries the fixed two-link one-joint
    // mechanism.
    if (is_cube) EXPECT(scene.links().empty() && scene.joints().empty(), "the cube has links or joints");
    std::filesystem::path mechanism_path = cadaclysm::detail::fs_path(path).parent_path() / "mechanism.stp";
    CADACLYSM_TRY(mechanism, cadaclysm::open(utf8(mechanism_path)));
    std::vector<cadaclysm::Link> links = mechanism.links();
    EXPECT(links.size() == 2 && links[0].name() == "base" && links[1].name() == "arm", "mechanism links are not [base, arm]");
    for (const cadaclysm::Link& link : links) {
        std::vector<cadaclysm::Node> link_nodes = link.nodes();
        EXPECT(link_nodes.size() == 1 && link_nodes[0].name() == link.name(),
               "link " + link.name() + " does not name exactly one node of its own name");
    }
    std::vector<cadaclysm::Joint> joints = mechanism.joints();
    EXPECT(joints.size() == 1 && joints[0].name() == "hinge", "mechanism does not carry exactly one joint named hinge");
    cadaclysm::Joint hinge = joints[0];
    cadaclysm::Link hinge_start = hinge.start();
    cadaclysm::Link hinge_end = hinge.end();
    // The file's order, (arm, base): a swap into (parent, child) would fail here.
    EXPECT(hinge_start.name() == "arm" && hinge_start.index() == 1 && hinge_end.name() == "base" && hinge_end.index() == 0,
           "joint hinge reads start=" + hinge_start.name() + "#" + std::to_string(hinge_start.index()) +
               " end=" + hinge_end.name() + "#" + std::to_string(hinge_end.index()));
    std::printf("kinematics: links %zu, joints %zu, hinge %s->%s\n", links.size(), joints.size(), hinge_start.name().c_str(),
                hinge_end.name().c_str());

    scene.forget_meshes();
    std::size_t rebuilt = 0;
    for (const cadaclysm::Node& node : scene.walk()) {
        if (node.can_mesh()) rebuilt += node.mesh().triangle_count();
    }
    EXPECT(rebuilt == triangles, "forget_meshes did not rebuild");
    EXPECT(cadaclysm::lod_levels() == 3, "lod_levels is not 3");
    {
        std::vector<cadaclysm::Node> bodies = scene.walk();
        auto first = std::find_if(bodies.begin(), bodies.end(), [](const cadaclysm::Node& n) { return n.can_mesh(); });
        EXPECT(first != bodies.end(), "no meshable node");
        EXPECT(first->mesh_lod(0).triangle_count() == first->mesh().triangle_count(), "LOD 0 is not the mesh");
        EXPECT(first->lod_error(0) == 0.0f && first->mesh_lod(4).triangle_count() == 0, "LOD errors or levels are off");
        if (is_cube) {
            cadaclysm::Beziers beziers = first->edge_beziers();
            EXPECT(first->mesh_lod(1).triangle_count() == 3 && beziers.count() == 12 && beziers.points().size() == 12 * 12,
                   "the cube's LOD 1 or Béziers are off");
            EXPECT(first->curve_beziers().empty() && first->isocurve_beziers().count() == 12, "the cube's curve/isocurve Béziers are off");
        }
    }
    {
        std::vector<cadaclysm::Node> bodies = scene.walk();
        auto first = std::find_if(bodies.begin(), bodies.end(), [](const cadaclysm::Node& n) { return n.can_mesh(); });
        EXPECT(first != bodies.end(), "no meshable node");
        std::optional<cadaclysm::Collision> fit = first->collision();
        EXPECT(fit && fit->error == 0.0 && fit->hull_vertex_count == 8 && !fit->shape_name().empty(), "the collision fit is off");
        cadaclysm::CollisionHull hull = first->collision_hull();
        EXPECT(hull.vertex_count() == 8 && hull.index_count() == 36, "the collision hull is off");
        if (is_cube) EXPECT(fit->shape_name() == "hull" || fit->shape_name() == "box", "the cube's collision shape is off");
    }
    {
        std::vector<cadaclysm::Node> bodies = scene.walk();
        auto first = std::find_if(bodies.begin(), bodies.end(), [](const cadaclysm::Node& n) { return n.can_mesh(); });
        EXPECT(first != bodies.end(), "no meshable node");
        cadaclysm::Mesh m = first->mesh();
        CADACLYSM_TRY(meshlets, cadaclysm::Meshlets::build(m.positions(), m.normals(), m.indices(), 124, 64));
        EXPECT(meshlets.count() >= 1, "no meshlets");
        cadaclysm::Meshlet one = meshlets.meshlet(0);
        EXPECT(one.positions.size() == one.vertex_count() * 3 && one.indices.size() == one.triangle_count() * 3 && one.level == 0, "meshlet 0 is off");
        if (is_cube) EXPECT(meshlets.count() == 1 && one.triangle_count() == 12 && one.vertex_count() == 36, "the cube's meshlets are off");
        meshlets.free();
        EXPECT(meshlets.freed(), "free() did not free");
        meshlets.free();
        EXPECT(!cadaclysm::Meshlets::build(m.positions(), cadaclysm::Span<const float>(), m.indices(), 0, 64), "a zero budget was accepted");
    }
    {
        std::vector<cadaclysm::Node> bodies = scene.walk();
        auto first = std::find_if(bodies.begin(), bodies.end(), [](const cadaclysm::Node& n) { return n.can_mesh(); });
        EXPECT(first != bodies.end(), "no meshable node");
        std::int64_t estimate = first->triangle_estimate();
        EXPECT(estimate == -1 || estimate > 0, "triangle estimate is neither a count nor -1");
        std::array<double, 16> identity{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
        EXPECT(first->bounds_placed(identity) == first->bounds_placed(), "the identity placement moved the surface bounds");
        EXPECT(first->bounds_placed64(identity) == first->bounds_placed64(), "the identity placement moved the f64 surface bounds");
        if (is_cube) {
            EXPECT(estimate == 12, "the cube's estimate is not 12");
            EXPECT(first->surface_edges().empty() && first->surface_isocurves().empty(), "the cube has surface curves");
            EXPECT(first->surface_proxy_mesh(4).empty(), "the cube has a surface proxy");
            EXPECT(!first->surface_pick({10, 10, 100}, {10, 10, -100}), "the cube picks through surfaces");
            EXPECT(first->bounds_placed().is_empty(), "the cube has surface bounds");
            EXPECT(first->bounds_placed64().is_empty(), "the cube has f64 surface bounds");
            EXPECT(first->surface_edge_beziers().empty(), "the cube hands exact edges to the surface path");
            EXPECT(first->edge_colours().empty() && first->surface_edge_colours().empty(), "the unpainted cube has edge colours");
        }
        EXPECT(first->is_meshed(), "the mesh asked for above is not held");
        CADACLYSM_TRY(fresh, cadaclysm::open(path));
        std::vector<cadaclysm::Node> fresh_bodies = fresh.walk();
        auto body = std::find_if(fresh_bodies.begin(), fresh_bodies.end(), [](const cadaclysm::Node& n) { return n.can_mesh(); });
        EXPECT(body != fresh_bodies.end() && !body->is_meshed(), "a fresh scene is already meshed");
        std::uint32_t built = fresh.realize_meshes(false);
        EXPECT(built > 0 && body->is_meshed(), "realize_meshes(false) did not build");
    }
    {
        // A Rhino extrusion hands its exact edges to the surface path without meshing, in
        // both conventions: unreal goes through the decorator that maps every getter into
        // the caller's space. The fixture is the repository's, not an SDK checkout's, so
        // this runs where found.
        std::filesystem::path extrusions = cadaclysm::detail::fs_path(path).parent_path().parent_path() /
                                           "crates" / "cadaclysm-acis" / "tests" / "fixtures" / "rhino" / "extrusion-objects.3dm";
        std::error_code missing;
        if (std::filesystem::exists(extrusions, missing)) {
            for (cadaclysm::Convention convention : {cadaclysm::Convention::native, cadaclysm::Convention::unreal}) {
                cadaclysm::OpenOptions options;
                options.convention = static_cast<std::uint32_t>(convention);
                CADACLYSM_TRY(surfaced, cadaclysm::open(utf8(extrusions), options));
                int found = 0;
                for (const cadaclysm::Node& n : surfaced.walk()) {
                    if (!n.can_mesh() || n.surface_edges().empty()) continue;
                    std::uint32_t exact = n.surface_edge_beziers().count();
                    EXPECT(exact > 0 && !n.is_meshed(), "an extrusion's exact edges are not free");
                    EXPECT(exact == n.edge_beziers().count(), "surface_edge_beziers is not edge_beziers' segments");
                    ++found;
                }
                EXPECT(found > 0, "extrusion-objects.3dm has no surfaced extrusion");
                std::printf("surface_edge_beziers (convention %u): %d extrusions, exact and unmeshed\n",
                            static_cast<unsigned>(convention), found);
            }
        }
    }
    {
        // f64 twins: mesh64's counts and first position agree with mesh's, and
        // bounds64's max widens to bounds's, on both the node and the scene. Catches:
        // mesh64/bounds64 returning zeros, garbage, or the wrong node's data.
        std::vector<cadaclysm::Node> bodies = scene.walk();
        auto first = std::find_if(bodies.begin(), bodies.end(), [](const cadaclysm::Node& n) { return n.can_mesh(); });
        EXPECT(first != bodies.end(), "no meshable node");
        cadaclysm::Mesh mesh = first->mesh();
        cadaclysm::Mesh64 mesh64 = first->mesh64();
        EXPECT(mesh64.vertex_count() == mesh.vertex_count() && mesh64.index_count() == mesh.index_count(),
               "mesh64's vertex/index counts do not equal mesh's");
        cadaclysm::Span<const double> p64 = mesh64.positions();
        cadaclysm::Span<const float> p32 = mesh.positions();
        EXPECT(p64.size() >= 3 && p32.size() >= 3 && static_cast<float>(p64[0]) == p32[0] &&
                   static_cast<float>(p64[1]) == p32[1] && static_cast<float>(p64[2]) == p32[2],
               "mesh64's first position narrowed to float does not equal mesh's first position");
        cadaclysm::Bounds node_bounds = first->bounds();
        cadaclysm::Bounds64 node_bounds64 = first->bounds64();
        EXPECT(static_cast<float>(node_bounds64.max[0]) == node_bounds.max[0] &&
                   static_cast<float>(node_bounds64.max[1]) == node_bounds.max[1] &&
                   static_cast<float>(node_bounds64.max[2]) == node_bounds.max[2],
               "bounds64's max does not equal bounds's max widened");
        cadaclysm::Bounds64 scene_bounds64 = scene.bounds64();
        EXPECT(static_cast<float>(scene_bounds64.max[0]) == bounds.max[0] &&
                   static_cast<float>(scene_bounds64.max[1]) == bounds.max[1] &&
                   static_cast<float>(scene_bounds64.max[2]) == bounds.max[2],
               "scene bounds64's max does not equal bounds's max widened");
        std::printf("reader f64 twins: mesh64 %u triangles, bounds64 max=(%g, %g, %g)\n", mesh64.triangle_count(),
                    scene_bounds64.max[0], scene_bounds64.max[1], scene_bounds64.max[2]);
    }
    std::printf("placements: %zu\n", scene.placements().size());
    std::vector<cadaclysm::Node> walked = scene.walk();
    EXPECT(!walked.empty() && walked.size() <= scene.size(), "walk visited nothing, or more than the scene holds");
    for (const cadaclysm::Node& node : walked) {
        EXPECT(node.label().size() > 0, "a node has an empty label");
        if (auto parent = node.parent()) EXPECT(parent->depth() + 1 == node.depth(), "a child is not one deeper than its parent");
    }
    if (is_cube) {
        EXPECT(triangles == 12, "the cube did not come back as 12 triangles");
        EXPECT(!matched.empty(), "class == solid matched nothing in the cube");
        std::optional<cadaclysm::Node> solid = scene.node(matched[0]);
        EXPECT(solid.has_value(), "the query named a node past the end");
        cadaclysm::Mesh mesh = solid->mesh();
        EXPECT(mesh.vertex_count() > 0 && mesh.normals().size() == mesh.positions().size(),
               "the cube's mesh has no vertices or no normals");
        cadaclysm::Span<const std::uint32_t> indices = mesh.indices();
        EXPECT(std::all_of(indices.begin(), indices.end(), [&](std::uint32_t i) { return i < mesh.vertex_count(); }),
               "an index points past the vertices");
        cadaclysm::MeshData kept = mesh.copy();
        EXPECT(kept.triangle_count() == mesh.triangle_count() && kept.positions.size() == mesh.positions().size(),
               "Mesh::copy lost data");
        cadaclysm::Polylines edges = solid->edges();
        EXPECT(edges.segment_indices().size() % 2 == 0 && edges.segments().size() == 3 * edges.segment_indices().size(),
               "the edge segments do not pair up");
    }
    EXPECT(!scene.node(scene.size()).has_value(), "a node past the end was handed out");

    // The same bytes in memory, the format given since there is no file name.
    CADACLYSM_TRY(bytes, read_file(path));
    std::string extension = path.substr(path.find_last_of('.') + 1);
    cadaclysm::OpenOptions named;
    named.name = "cube-bytes";
    CADACLYSM_TRY(again, cadaclysm::open_memory(bytes.data(), bytes.size(), extension, named));
    EXPECT(again.bounds() == bounds, "open_memory disagrees with open");
    EXPECT(again.path() == "cube-bytes", "open_memory's path is not the name it was given");
    again.close();
    EXPECT(again.closed(), "close() did not close");
    EXPECT(!cadaclysm::open_memory(bytes.data(), bytes.size(), "no-such-format"), "an unknown format opened");

    // A convention converts on the way out: a Y-up metres read of the same file.
    cadaclysm::OpenOptions y_up;
    y_up.convention = static_cast<std::uint32_t>(cadaclysm::Convention::y_up);
    CADACLYSM_TRY(yup, cadaclysm::open(path, y_up));
    EXPECT(yup.convention() == 3, "the scene forgot its convention");
    cadaclysm::Bounds yb = yup.bounds();
    std::printf("y-up bounds min=(%g, %g, %g) max=(%g, %g, %g)\n", yb.min[0], yb.min[1], yb.min[2], yb.max[0],
                yb.max[1], yb.max[2]);

    // Threads: realize on one, read progress on another.
    std::uint32_t realized = 0;
    std::thread worker([&] { realized = yup.realize_all(); });
    (void)yup.realized();
    worker.join();
    std::printf("realize_all: %u of %u\n", realized, yup.realize_total());
    EXPECT(yup.realized() == yup.realize_total(), "realize_all stopped short");

    CADACLYSM_TRY_VOID(save_checks(scene));
    CADACLYSM_TRY_VOID(fem_reader(scene, is_cube));
    if (is_cube) {
        std::string sheet = path.substr(0, path.size() - std::string("cube.scad").size()) + "open-sheet.scad";
        CADACLYSM_TRY_VOID(fem_census_wiring(sheet));
    }
    CADACLYSM_TRY_VOID(fem_outlives_its_scene(path));
    CADACLYSM_TRY_VOID(edge_colours_check(path));

    CADACLYSM_TRY(unreal, cadaclysm::parse_convention(" Unreal+file-units "));
    EXPECT(unreal == (cadaclysm::Convention::unreal | cadaclysm::FILE_UNITS), "parse_convention misread unreal+file-units");
    EXPECT(!cadaclysm::parse_convention("sideways"), "parse_convention accepted a preset that does not exist");
    EXPECT(!cadaclysm::parse_convention("unity+inches"), "parse_convention accepted a flag that does not exist");

    EXPECT(!cadaclysm::open("no/such/file.stp"), "a missing file opened");

#if CADACLYSM_CHECKED
    // C++ only: a node outliving its scene's close() is caught, not read.
    {
        CADACLYSM_TRY(doomed, cadaclysm::open(path));
        std::vector<cadaclysm::Node> roots = doomed.roots();
        EXPECT(!roots.empty(), "the scene has no roots");
        cadaclysm::Node root = roots.front();
        doomed.close();
        EXPECT(trips([&] { (void)root.name(); }), "a node read after its scene closed did not trip");
        EXPECT(trap::message.find("closed") != std::string::npos, "the trip does not say the scene is closed");
    }
    {
        CADACLYSM_TRY(doomed, cadaclysm::open(path));
        std::vector<cadaclysm::Node> walked_doomed = doomed.walk();
        cadaclysm::Mesh held = walked_doomed.back().mesh();
        doomed.close();
        EXPECT(trips([&] { (void)held.positions(); }), "a mesh read after its scene closed did not trip");
    }
#endif
    return {};
}

// C++ only: the builders latch their first error, the factories refuse with the
// library's message, and the value types check what Python's check.
static Result<void> kernel_values() {
    auto negative = bs::Profile::rect(-1, 2);
    EXPECT(!negative && !negative.error().message.empty() && negative.error().origin == cadaclysm::Origin::kernel,
           "a negative rectangle was not refused with the kernel's message");

    bs::Path broken = bs::Profile::path({0, 0});
    broken.nurbs_to({{1, 1}}, {}, 3).line_to(5, 5);  // no knots: refused, and the line_to skipped
    EXPECT(broken.err() != nullptr, "a refused nurbs_to did not latch");
    std::string latched = broken.err()->message;
    auto ended = broken.end();
    EXPECT(!ended && ended.error().message == latched, "end() did not report the latched error");

    CADACLYSM_TRY(triangle, bs::Profile::path({0, 0}).line_to(10, 0).line_to(0, 10).line_to(0, 0).end());
    CADACLYSM_TRY(moved, triangle.translate(5, 5));
    (void)moved;

    CADACLYSM_TRY(slanted, bs::Frame::at({0, 0, 0}, {0, 0, 1}));
    CADACLYSM_TRY(world_xy, bs::Frame::xy());
    CADACLYSM_TRY(world_xz, bs::Frame::xz());
    EXPECT(slanted == world_xy, "Frame::at with a +Z normal is not xy");
    CADACLYSM_TRY(minus_y, bs::Frame::at({0, 0, 0}, {0, -1, 0}));
    EXPECT(minus_y == world_xz, "Frame::at with a -Y normal is not xz");
    EXPECT(!bs::Frame::make({0, 0, 0}, {1, 0, 0}, {0, 1, 0}, {0, 0, -1}), "a left-handed frame was accepted");
    EXPECT(!bs::Frame::make({0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 0, 1}), "a frame whose axes are not square was accepted");
    CADACLYSM_TRY(raised_xy, bs::Frame::xy({0, 0, 2}));
    CADACLYSM_TRY(lifted, raised_xy.offset(3));
    EXPECT(lifted.origin() == (bs::Vec3{0, 0, 5}), "Frame::offset did not move along z");
    // Every way to a frame checks its origin, as Python's constructor does.
    const double inf = std::numeric_limits<double>::infinity();
    const std::string not_finite = "Frame: origin must be three finite numbers";
    auto far_at = bs::Frame::at({inf, 0, 0}, {0, 0, 1});
    EXPECT(!far_at && far_at.error().message == not_finite,
           "Frame::at with an infinite origin: " + (far_at ? std::string("accepted") : far_at.error().message));
    const std::vector<std::pair<const char*, Result<bs::Frame>>> far = {
        {"xy", bs::Frame::xy({0, inf, 0})},
        {"xz", bs::Frame::xz({0, 0, -inf})},
        {"yz", bs::Frame::yz({std::nan(""), 0, 0})},
        {"translate", world_xy.translate(inf, 0, 0)},
        {"offset", world_xy.offset(inf)},
    };
    for (const auto& [how, made] : far) {
        EXPECT(!made && made.error().message == not_finite,
               std::string("Frame::") + how + " with an infinite origin: " + (made ? std::string("accepted") : made.error().message));
    }

    CADACLYSM_TRY(blue, bs::rgb("#36f"));
    EXPECT(blue == (bs::Vec3{0x33 / 255.0, 0x66 / 255.0, 1.0}), "rgb(#36f) is not #3366ff");
    EXPECT(!bs::rgb("teal"), "rgb accepted a colour name");

    bs::SweepPath bend = bs::SweepPath::at({0, 0, 0});
    bend.line_to({0, 0, 10}).arc({5, 0, 10}, {0, 1, 0}, 1.5707963267948966);
    EXPECT(bend.err() == nullptr, "a line and a quarter turn did not build a sweep path");
    return {};
}

static Result<void> sheet_verbs(const bs::Solid& plate) {
    CADACLYSM_TRY(xy, bs::Frame::xy());
    CADACLYSM_TRY(square, bs::Profile::rect(20, 20));
    CADACLYSM_TRY(sheet, bs::Solid::face(square, xy));
    CADACLYSM_TRY(peg_outline, bs::Profile::circle(4));
    CADACLYSM_TRY(below, bs::Frame::xy({0, 0, -6}));
    CADACLYSM_TRY(peg, bs::Solid::extrude(peg_outline, below, 12));
    CADACLYSM_TRY(holed, sheet.trim(peg, bs::Keep::outside));
    CADACLYSM_TRY(disc, sheet.trim(peg, bs::Keep::inside));
    CADACLYSM_TRY(top, plate.select_face((bs::Selector::max)(bs::Axis::z)));
    CADACLYSM_TRY(lid, plate.face_sheet(top));
    CADACLYSM_TRY(walls, plate.drop_faces({0, 1}));
    CADACLYSM_TRY(rounded_square, square.round(2.0));
    CADACLYSM_TRY(slab, bs::Solid::extrude(rounded_square, xy, 1));
    CADACLYSM_TRY(wave, bs::Profile::path({0, 0}).bezier_to({20, 0}, {20, 20}, {40, 10}).end_open());
    bs::SweepPath along = bs::SweepPath::along(wave, xy, 0.01, true);
    CADACLYSM_TRY(tube_outline, bs::Profile::circle(1));
    CADACLYSM_TRY(yz, bs::Frame::yz());
    CADACLYSM_TRY(tube, bs::Solid::sweep(tube_outline, yz, along));
    CADACLYSM_TRY(tube_closed, tube.is_watertight());
    CADACLYSM_TRY(on_plane, bs::Workplane::xy().face(square).solid());
    EXPECT(sheet.faces() == 1 && holed.faces() >= 1 && disc.faces() >= 1 && lid.faces() == 1 &&
               walls.faces() == plate.faces() - 2 && slab.faces() == 10 && tube_closed && on_plane.faces() == 1,
           "sheet verbs: a count is wrong");
    CADACLYSM_TRY(away, peg.translate(100, 0, 0));
    auto refused = sheet.trim(away, bs::Keep::inside);
    EXPECT(!refused && refused.error().message.find("trim: nothing of the sheet lies inside the tool") != std::string::npos,
           "a trim with nothing inside was not refused with the kernel's message");

    {
        CADACLYSM_TRY(box, bs::Solid::cuboid(1, 2, 3));
        CADACLYSM_TRY(big, box.scaled(2));
        CADACLYSM_TRY(bb, big.bounds());
        EXPECT(std::abs(bb.second[0] - bb.first[0] - 2.0) < 1e-9 && std::abs(bb.second[2] - bb.first[2] - 6.0) < 1e-9, "scaled bounds");
        auto zero = box.scaled(0);
        EXPECT(!zero && zero.error().message.rfind("scaled:", 0) == 0, "scaled(0) not refused");
    }

    // Chain: an L's two sides, the second drawn back to front -- open, two walls;
    // closed, a triangle's three.
    CADACLYSM_TRY(side_a, bs::Profile::path({0, 0}).line_to(10, 0).end_open());
    CADACLYSM_TRY(side_b, bs::Profile::path({10, 8}).line_to(10, 0).end_open());
    CADACLYSM_TRY(ell, bs::Profile::chain({side_a, side_b}));
    CADACLYSM_TRY(ell_walls, bs::Solid::extrude_open(ell, xy, 2));
    EXPECT(ell_walls.faces() == 2, "chain: an L extruded open is not two walls");
    CADACLYSM_TRY(triangle, ell.close_loop());
    CADACLYSM_TRY(triangle_walls, bs::Solid::extrude_open(triangle, xy, 2));
    EXPECT(triangle_walls.faces() == 3, "close_loop: not three walls");

    // Press-pull: a cube's top pushed 5 is still six faces; its top and a side pushed
    // together, a 15 x 10 x 15 box; no faces at all is refused by the kernel.
    CADACLYSM_TRY(cube, bs::Solid::cuboid(10, 10, 10));
    CADACLYSM_TRY(cube_top, cube.select_face((bs::Selector::max)(bs::Axis::z)));
    CADACLYSM_TRY(cube_side, cube.select_face((bs::Selector::max)(bs::Axis::x)));
    CADACLYSM_TRY(raised, cube.push_pull(cube_top, 5));
    CADACLYSM_TRY(raised_closed, raised.is_watertight());
    EXPECT(raised.faces() == 6 && raised_closed, "push_pull: the raised cube has " + std::to_string(raised.faces()) + " faces, not 6");
    CADACLYSM_TRY(grown, cube.push_pull(std::vector<std::uint32_t>{cube_top, cube_side}, 5));
    CADACLYSM_TRY(grown_closed, grown.is_watertight());
    CADACLYSM_TRY(grown_box, grown.bounds());
    EXPECT(grown.faces() == 6 && grown_closed, "push_pull: the cube grown two ways has " + std::to_string(grown.faces()) + " faces, not 6");
    EXPECT(std::fabs(grown_box.second[0] - grown_box.first[0] - 15) < 1e-6 &&
               std::fabs(grown_box.second[1] - grown_box.first[1] - 10) < 1e-6 &&
               std::fabs(grown_box.second[2] - grown_box.first[2] - 15) < 1e-6,
           "push_pull: the cube grown two ways is not 15 x 10 x 15");
    auto no_faces = cube.push_pull(std::vector<std::uint32_t>{}, 5);
    EXPECT(!no_faces && !no_faces.error().message.empty() && no_faces.error().origin == cadaclysm::Origin::kernel,
           "push_pull on no faces was not refused with the kernel's message");
    // A braced empty list must bind the vector overload too (not the scalar one,
    // which would push face 0 instead of being refused).
    auto brace_no_faces = cube.push_pull({}, 5);
    EXPECT(!brace_no_faces && !brace_no_faces.error().message.empty() &&
               brace_no_faces.error().origin == cadaclysm::Origin::kernel,
           "push_pull({}, d) was not refused with the kernel's message");
    CADACLYSM_TRY(brace_grown, cube.push_pull({cube_top, cube_side}, 5));
    CADACLYSM_TRY(brace_grown_closed, brace_grown.is_watertight());
    EXPECT(brace_grown.faces() == 6 && brace_grown_closed,
           "push_pull({i, j}, d) did not grow the cube two ways");

    // A pipe along a line and a quarter turn: one watertight tube.
    bs::SweepPath bend = bs::SweepPath::at({0, 0, 0});
    bend.line_to({0, 0, 10}).arc({5, 0, 10}, {0, 1, 0}, 1.5707963267948966);
    CADACLYSM_TRY(pipe, bs::Solid::pipe(bend, 1.0, 0.2));
    CADACLYSM_TRY(pipe_closed, pipe.is_watertight());
    EXPECT(pipe_closed, "the pipe leaks");

    // A five-pointed star: ten walls and two caps.
    CADACLYSM_TRY(star, bs::Profile::star({0, 0}, 10, 4, 5));
    CADACLYSM_TRY(star_prism, bs::Solid::extrude(star, xy, 2));
    CADACLYSM_TRY(star_closed, star_prism.is_watertight());
    EXPECT(star_prism.faces() == 12 && star_closed, "star: not twelve watertight faces");

    // Text: an `i` is two shapes and an `o` one; the `o` extrudes to a watertight ring with spline edges.
    CADACLYSM_TRY(word, bs::Profile::text("io", 10));
    CADACLYSM_TRY(text_ring, bs::Solid::extrude(word.at(2), xy, 2));
    CADACLYSM_TRY(text_edges, text_ring.edges());
    bool text_spline = false;
    for (const auto& edge : text_edges) text_spline = text_spline || edge.kind == "nurbs";
    EXPECT(word.size() == 3 && text_spline, "text: not three shapes with a spline-edged ring");
    auto no_font = bs::Profile::text("x", 10, "", "left", "baseline", 1, "ltr", std::vector<std::uint8_t>{1, 2, 3});
    EXPECT(!no_font && no_font.error().message == "profile_text: the font bytes are not a font", "text: bad bytes not refused");

    // A reflector: the parabola from rim to rim, closed and revolved -- watertight.
    const double kPi = std::acos(-1.0);
    CADACLYSM_TRY(dish, bs::Profile::parabola({0, 0}, {0, 1}, 20, 0, 50).line_to(0, 31.25).line_to(0, 0).end());
    CADACLYSM_TRY(bowl, bs::Solid::revolve_in_plane(dish, xy, {0, 0}, {0, 1}, 2 * kPi));
    CADACLYSM_TRY(bowl_closed, bowl.is_watertight());
    EXPECT(bowl_closed, "parabola: the bowl leaks");
    // A conic with a quarter circle's weight; a control point on the chord and a
    // hyperbola's weight not over 1 are refused (the latter here, before the library).
    CADACLYSM_TRY(quarter, bs::Profile::path({10, 0}).conic_to({0, 10}, {10, 10}, std::cos(kPi / 4)).line_to(0, 0).line_to(10, 0).end());
    CADACLYSM_TRY(quarter_box, bs::Solid::extrude(quarter, xy, 2));
    EXPECT(quarter_box.faces() == 5, "conic_to: a quarter circle's box is not five faces");
    // The dish's own arc by vertex, closed by a second parabola through the same rim points
    // with a focus beyond the chord -- the arch over the top, not the dish again (a focus at
    // (0, 20) would rebuild the identical arc and retrace it).
    CADACLYSM_TRY(arch, bs::Profile::path({-50, 31.25}).parabola_by_vertex({50, 31.25}, {0, 0}).parabola_by_focus({-50, 31.25}, {0, 40}).end());
    CADACLYSM_TRY(arch_slab, bs::Solid::extrude(arch, xy, 2));
    CADACLYSM_TRY(arch_closed, arch_slab.is_watertight());
    EXPECT(arch_closed, "parabola_by_vertex/focus: the arch leaks");
    // A parabola by its end tangents, and a hyperbola at weight 2: one wall and a floor each.
    CADACLYSM_TRY(bump, bs::Profile::path({0, 0}).parabola_to({10, 0}, {5, 5}).line_to(0, 0).end());
    CADACLYSM_TRY(bump_slab, bs::Solid::extrude(bump, xy, 2));
    EXPECT(bump_slab.faces() == 4, "parabola_to: a bump is not four faces");
    CADACLYSM_TRY(hump, bs::Profile::path({0, 0}).hyperbola_to({10, 0}, {5, 5}, 2).line_to(0, 0).end());
    CADACLYSM_TRY(hump_slab, bs::Solid::extrude(hump, xy, 2));
    EXPECT(hump_slab.faces() == 4, "hyperbola_to: a hump is not four faces");
    auto flat = bs::Profile::path({0, 0}).conic_to({2, 0}, {1, 0}, 1).end_open();
    EXPECT(!flat && flat.error().message == "path_conic_to: the control point lies on the chord",
           "a conic through its chord: " + (flat ? std::string("accepted") : flat.error().message));
    auto low = bs::Profile::path({0, 0}).hyperbola_to({2, 0}, {1, 1}, 1).line_to(0, 0).end_open();
    EXPECT(!low && low.error().message == "hyperbola_to: the weight must be over 1 (1 is a parabola, under 1 an ellipse)",
           "a hyperbola at weight 1: " + (low ? std::string("accepted") : low.error().message));
    auto no_axis = bs::Profile::parabola({0, 0}, {0, 0}, 1, -1, 1).end_open();
    EXPECT(!no_axis && no_axis.error().message == "path_parabola: the axis direction is zero",
           "a parabola without an axis: " + (no_axis ? std::string("accepted") : no_axis.error().message));

    // The library reads a fixed count of weights: a wrong count is refused, not read past.
    // An empty list is a count (zero), as in Python; a refused nurbs_to latches like any step.
    const std::vector<bs::Vec2> corners = {{0, 0}, {10, 0}, {10, 10}, {0, 10}};
    const std::vector<bs::Vec2> control = {{5, 5}, {10, 0}};
    const std::vector<double> knots = {0, 0, 0, 1, 1, 1};
    CADACLYSM_TRY(weighted, bs::Profile::spline(corners, 3, std::vector<double>{1, 2, 1, 1}, true));
    CADACLYSM_TRY(rational, bs::Profile::path({0, 0}).nurbs_to(control, knots, 2, std::vector<double>{1, 0.5, 1}).end_open());
    (void)weighted;
    (void)rational;
    auto short_spline = bs::Profile::spline(corners, 3, std::vector<double>{1, 1}, true);
    EXPECT(!short_spline && short_spline.error().message == "spline: 2 weights for 4 points; give one per point",
           "a short weight list: " + (short_spline ? std::string("accepted") : short_spline.error().message));
    auto empty_spline = bs::Profile::spline(corners, 3, std::vector<double>{}, true);
    EXPECT(!empty_spline && empty_spline.error().message == "spline: 0 weights for 4 points; give one per point",
           "an empty weight list: " + (empty_spline ? std::string("accepted") : empty_spline.error().message));
    auto short_nurbs =
        bs::Profile::path({0, 0}).nurbs_to(control, knots, 2, std::vector<double>{1, 1}).line_to(20, 20).end_open();
    EXPECT(!short_nurbs && short_nurbs.error().message ==
                               "nurbs_to: 2 weights for 3 control points (the current point and 2 given); give one per point",
           "a short weight list: " + (short_nurbs ? std::string("accepted") : short_nurbs.error().message));
    return {};
}

static Result<void> frames() {
    CADACLYSM_TRY(lid_outline, bs::Profile::rect(30, 30));
    CADACLYSM_TRY(lid_plane, bs::Frame::xy({0, 0, 20}));
    CADACLYSM_TRY(lid, bs::Solid::extrude(lid_outline, lid_plane, 2));
    CADACLYSM_TRY(lid_box, lid.bounds());
    EXPECT(std::fabs(lid_box.first[2] - 20) < 1e-9 && std::fabs(lid_box.second[2] - 22) < 1e-9,
           "Frame::xy did not lift the lid to z = 20");
    CADACLYSM_TRY(slanted, bs::Frame::at({10, 0, 0}, {1, 1, 0}));
    CADACLYSM_TRY(boss_outline, bs::Profile::circle(6));
    CADACLYSM_TRY(boss, bs::Solid::extrude(boss_outline, slanted, 4));
    CADACLYSM_TRY(boss_closed, boss.is_watertight());
    EXPECT(boss_closed, "a boss on a slanted frame leaks");
    CADACLYSM_TRY(top, lid.select_face((bs::Selector::max)(bs::Axis::z)));
    CADACLYSM_TRY(on_top, lid.face_frame(top));
    EXPECT(on_top.z() == (bs::Vec3{0, 0, 1}) && std::fabs(on_top.origin()[2] - 22) < 1e-9, "the lid's top frame is wrong");

    // Construction planes, as Python's and Node's tests check them: halfway between two
    // parallel planes; the 45-degree bisector of a floor and a wall; the plane through
    // three points; three points on one line refused with the kernel's message.
    auto close_to = [](const bs::Vec3& a, const bs::Vec3& b) {
        return std::fabs(a[0] - b[0]) < 1e-9 && std::fabs(a[1] - b[1]) < 1e-9 && std::fabs(a[2] - b[2]) < 1e-9;
    };
    CADACLYSM_TRY(ground, bs::Frame::xy());
    CADACLYSM_TRY(ceiling, bs::Frame::xy({0, 0, 10}));
    CADACLYSM_TRY(mid, bs::Frame::midplane(ground, ceiling));
    EXPECT(close_to(mid.z(), {0, 0, 1}) && close_to(mid.origin(), {0, 0, 5}), "Frame::midplane of two parallel planes is not halfway between");
    CADACLYSM_TRY(wall, bs::Frame::yz());
    CADACLYSM_TRY(bisector, bs::Frame::midplane(ground, wall));
    bs::Vec3 bz = bisector.z();
    EXPECT(std::fabs(std::fabs(bz[0]) - std::fabs(bz[2])) < 1e-9 && std::fabs(bz[1]) < 1e-9,
           "Frame::midplane of a floor and a wall is not their bisector");
    CADACLYSM_TRY(slope, bs::Frame::through({1, 0, 0}, {0, 1, 0}, {0, 0, 1}));
    const double k = 1 / std::sqrt(3.0);
    EXPECT(close_to(slope.z(), {k, k, k}) && close_to(slope.origin(), {1, 0, 0}), "Frame::through's plane is not x + y + z = 1 from p");
    auto on_a_line = bs::Frame::through({0, 0, 0}, {1, 1, 1}, {2, 2, 2});
    EXPECT(!on_a_line && on_a_line.error().message.rfind("frame_through: ", 0) == 0 &&
               on_a_line.error().origin == cadaclysm::Origin::kernel,
           "Frame::through three points on one line: " + (on_a_line ? std::string("accepted") : on_a_line.error().message));
    // Like every way to a frame, never a frame with an origin that is not finite (the
    // kernel refuses it first, "frame_through: not finite").
    const double inf = std::numeric_limits<double>::infinity();
    auto far_through = bs::Frame::through({inf, 0, 0}, {0, 1, 0}, {0, 0, 1});
    EXPECT(!far_through && !far_through.error().message.empty(), "Frame::through from an infinite point was accepted");
    return {};
}

// A mesh's enclosed volume, as Python's test measures it.
static Result<double> volume(const bs::Solid& solid) {
    CADACLYSM_TRY(mesh, solid.mesh());
    cadaclysm::Span<const float> p = mesh.positions();
    cadaclysm::Span<const std::uint32_t> t = mesh.indices();
    double sum = 0;
    for (std::size_t i = 0; i + 2 < t.size(); i += 3) {
        const float* a = &p[3 * t[i]];
        const float* b = &p[3 * t[i + 1]];
        const float* c = &p[3 * t[i + 2]];
        sum += double(a[0]) * (double(b[1]) * c[2] - double(b[2]) * c[1]) + double(a[1]) * (double(b[2]) * c[0] - double(b[0]) * c[2]) +
               double(a[2]) * (double(b[0]) * c[1] - double(b[1]) * c[0]);
    }
    return sum / 6;
}

// A loft smooth through three circles, wide, narrow, wide -- a closed waist narrower than
// the cylinder round it -- the sheet through the same curves, open, and one section
// refused: what Python's and Node's tests check.
static Result<void> lofts() {
    CADACLYSM_TRY(wide, bs::Profile::circle(10));
    CADACLYSM_TRY(narrow, bs::Profile::circle(6));
    CADACLYSM_TRY(bottom, bs::Frame::xy());
    CADACLYSM_TRY(middle, bs::Frame::xy({0, 0, 10}));
    CADACLYSM_TRY(top, bs::Frame::xy({0, 0, 20}));
    const bs::Sections rings = {{wide, bottom}, {narrow, middle}, {wide, top}};
    CADACLYSM_TRY(waist, bs::Solid::loft_through(rings));
    CADACLYSM_TRY(waist_closed, waist.is_watertight());
    CADACLYSM_TRY(waist_volume, volume(waist));
    CADACLYSM_TRY(drum, bs::Solid::extrude(wide, bottom, 20));
    CADACLYSM_TRY(drum_volume, volume(drum));
    std::printf("loft_through: waist %.1f inside a drum of %.1f\n", waist_volume, drum_volume);
    EXPECT(waist_closed && waist_volume > 0 && waist_volume < drum_volume, "loft_through: the waist is not a closed solid inside the drum");
    CADACLYSM_TRY(sheet, bs::Solid::loft_through_open(rings));
    CADACLYSM_TRY(sheet_closed, sheet.is_watertight());
    EXPECT(!sheet_closed, "loft_through_open closed the sheet");
    auto alone = bs::Solid::loft_through({{wide, bottom}});
    EXPECT(!alone && alone.error().message.rfind("loft_through: ", 0) == 0 && alone.error().origin == cadaclysm::Origin::kernel,
           "loft_through one section: " + (alone ? std::string("accepted") : alone.error().message));
    // C++ only: no sections at all reaches the library as a null array and a zero count.
    auto none = bs::Solid::loft_through_open({});
    EXPECT(!none && none.error().message.rfind("loft_through_open: ", 0) == 0,
           "loft_through_open with no sections: " + (none ? std::string("accepted") : none.error().message));
    return {};
}

// A profile's outline then its holes as polylines at z = 0 -- a closed loop ends on its
// first point, an open chain does not -- and a zero tolerance refused: what Python's test
// and the C ABI's check.
static Result<void> outlines() {
    CADACLYSM_TRY(rect, bs::Profile::rect(4, 2));
    CADACLYSM_TRY(disc, bs::Profile::circle(0.5));
    CADACLYSM_TRY(holed, rect.with_hole(disc));
    CADACLYSM_TRY(rings, holed.polylines(0.01));
    EXPECT(rings.size() == 2, "Profile::polylines gave " + std::to_string(rings.size()) + " polylines, not the outline and its hole");
    cadaclysm::Span<const float> outline = rings[0];
    cadaclysm::Span<const float> hole = rings[1];
    std::printf("profile polylines: outline %zu points, hole %zu\n", outline.size() / 3, hole.size() / 3);
    EXPECT(outline.size() == 15, "the rectangle's outline is not five points");
    bool flat = true;
    for (std::size_t i = 2; i < outline.size(); i += 3) flat = flat && outline[i] == 0.0f;
    for (std::size_t i = 2; i < hole.size(); i += 3) flat = flat && hole[i] == 0.0f;
    EXPECT(flat, "a profile polyline is off z = 0");
    bool corners = true;
    for (std::size_t k = 0; k < 4; ++k) {
        corners = corners && std::fabs(std::fabs(outline[3 * k]) - 2.0f) < 1e-6f && std::fabs(std::fabs(outline[3 * k + 1]) - 1.0f) < 1e-6f;
    }
    EXPECT(corners, "the outline's points are not the rectangle's corners");
    EXPECT(hole.size() >= 12, "the hole's polyline is too short to be a loop");
    bool closes = true;
    for (int i = 0; i < 3; ++i) {
        closes = closes && outline[i] == outline[outline.size() - 3 + i] && hole[i] == hole[hole.size() - 3 + i];
    }
    EXPECT(closes, "a closed loop does not end on its first point");
    bool on_circle = true;
    for (std::size_t i = 0; i + 2 < hole.size(); i += 3) on_circle = on_circle && std::fabs(std::hypot(double(hole[i]), double(hole[i + 1])) - 0.5) < 1e-6;
    EXPECT(on_circle, "the hole's points are not on its circle");
    std::vector<std::vector<float>> owned = rings.copy();
    EXPECT(owned.size() == 2 && owned[0].size() == outline.size() && std::equal(owned[1].begin(), owned[1].end(), hole.begin()),
           "copy() is not the rows it copied");
    auto refused = holed.polylines(0);
    EXPECT(!refused && refused.error().message.find("profile_polylines") != std::string::npos &&
               refused.error().origin == cadaclysm::Origin::kernel,
           "Profile::polylines at a zero tolerance: " + (refused ? std::string("accepted") : refused.error().message));
    // An open chain stays open: its start, one point per line, and no way back.
    CADACLYSM_TRY(elbow, bs::Profile::path({0, 0}).line_to(10, 0).line_to(10, 5).end_open());
    CADACLYSM_TRY(chain, elbow.polylines(0.01));
    EXPECT(chain.size() == 1 && chain[0].size() == 9 && chain[0][6] == 10.0f && chain[0][7] == 5.0f,
           "an open chain's polyline is not its three points, open");

    // Hits: two circles cross twice at x = 3; a tangent line touches once; a square
    // overlapping a shifted copy runs along it twice; apart, nothing; zero refused.
    CADACLYSM_TRY(circle_a, bs::Profile::circle(5));
    CADACLYSM_TRY(circle_off, bs::Profile::circle(5));
    CADACLYSM_TRY(circle_b, circle_off.translate(6, 0));
    CADACLYSM_TRY(crossings, circle_a.hits(circle_b));
    EXPECT(crossings.size() == 2, "two crossing circles gave " + std::to_string(crossings.size()) + " hits, not 2");
    bool points = true;
    for (const bs::Hit& h : crossings) {
        points = points && !h.run && !h.touch && std::fabs(h.start[0] - 3.0) < 1e-9 && std::fabs(std::fabs(h.start[1]) - 4.0) < 1e-9 &&
                 h.start == h.end && h.a_start.face == bs::NONE && h.a_start.loop_index == 0 && h.a_start.t >= 0.0 && h.a_start.t <= 1.0;
    }
    EXPECT(points, "the circles' crossings are not two points at (3, +-4) on loop 0");
    CADACLYSM_TRY(tangent, bs::Profile::path({-10, 5}).line_to(10, 5).end_open());
    CADACLYSM_TRY(touches, circle_a.hits(tangent));
    EXPECT(touches.size() == 1 && touches[0].touch && !touches[0].run, "a tangent line did not touch the circle once");
    CADACLYSM_TRY(square, bs::Profile::rect(10, 10));
    CADACLYSM_TRY(square_again, bs::Profile::rect(10, 10));
    CADACLYSM_TRY(shifted, square_again.translate(5, 0));
    CADACLYSM_TRY(overlaps, square.hits(shifted));
    std::size_t runs = 0;
    for (const bs::Hit& h : overlaps) runs += h.run && !(h.start == h.end) ? 1 : 0;
    EXPECT(runs == 2, "a square over its shifted copy gave " + std::to_string(runs) + " runs, not 2");
    CADACLYSM_TRY(far, circle_b.translate(100, 0));
    CADACLYSM_TRY(none, circle_a.hits(far));
    EXPECT(none.empty(), "two circles apart still hit");
    auto bad_tolerance = circle_a.hits(circle_b, 0);
    EXPECT(!bad_tolerance && bad_tolerance.error().message.find("profile_hits: tolerance must be positive and finite") != std::string::npos,
           "Profile::hits at a zero tolerance: " + (bad_tolerance ? std::string("accepted") : bad_tolerance.error().message));

    // Edge curves: a cylinder's rims are circles of its radius about a cap centre in a
    // unit frame, a whole turn each; a cuboid's edges are lines whose origin + x is the far
    // end; an extruded closed spline keeps a nurbs edge with knots = poles + degree + 1.
    {
        auto norm = [](const bs::Vec3& v) { return std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]); };
        auto sub = [](const bs::Vec3& a, const bs::Vec3& b) { return bs::Vec3{a[0] - b[0], a[1] - b[1], a[2] - b[2]}; };
        CADACLYSM_TRY(cyl, bs::Solid::cylinder(5, 3));
        CADACLYSM_TRY(cyl_edges, cyl.edges());
        std::size_t rims = 0;
        bool rims_ok = true;
        for (const bs::Edge& e : cyl_edges) {
            if (e.kind != "circle") continue;
            ++rims;
            if (!e.curve) { rims_ok = false; continue; }
            const bs::Curve& c = *e.curve;
            bool unit = std::fabs(norm(c.x) - 1) < 1e-9 && std::fabs(norm(c.y) - 1) < 1e-9 && std::fabs(bs::detail::dot(c.x, c.y)) < 1e-9;
            bool centred = std::fabs(c.origin[0]) < 1e-9 && std::fabs(c.origin[1]) < 1e-9 &&
                           std::min(std::fabs(c.origin[2]), std::fabs(c.origin[2] - 3)) < 1e-9;
            rims_ok = rims_ok && c.kind == "circle" && std::fabs(c.radius - 5) < 1e-9 && unit && centred &&
                      std::fabs(std::fabs(c.t1 - c.t0) - 2 * 3.14159265358979323846) < 1e-9 && c.degree == 0 && c.knots.empty() &&
                      !c.weights;
        }
        EXPECT(rims >= 2 && rims_ok, "the cylinder's rims are not radius-5 circles about a cap centre, a whole turn each");
        CADACLYSM_TRY(box, bs::Solid::cuboid(2, 4, 6));
        CADACLYSM_TRY(box_edges, box.edges());
        bool lines_ok = !box_edges.empty();
        for (const bs::Edge& e : box_edges) {
            if (!e.curve || e.curve->kind != "line" || e.curve->t0 != 0.0 || e.curve->t1 != 1.0) { lines_ok = false; continue; }
            const bs::Curve& c = *e.curve;
            bs::Vec3 far_end{c.origin[0] + c.x[0], c.origin[1] + c.x[1], c.origin[2] + c.x[2]};
            bool at_origin = false, at_far = false;
            for (const auto& s : e.segments) {
                for (const bs::Vec3& p : s) {
                    at_origin = at_origin || norm(sub(p, c.origin)) < 1e-9;
                    at_far = at_far || norm(sub(p, far_end)) < 1e-9;
                }
            }
            lines_ok = lines_ok && at_origin && at_far;
        }
        EXPECT(lines_ok, "a cuboid edge's line does not run from its own vertex to origin + x");
        CADACLYSM_TRY(spline_square, bs::Profile::spline({{0, 0}, {10, 0}, {10, 10}, {0, 10}}, 3, std::nullopt, true));
        CADACLYSM_TRY(spline_loop, bs::Workplane::xy().extrude(spline_square, 2.0).solid());
        CADACLYSM_TRY(loop_edges, spline_loop.edges());
        std::size_t splines = 0;
        bool splines_ok = true;
        for (const bs::Edge& e : loop_edges) {
            if (e.kind != "nurbs") continue;
            ++splines;
            splines_ok = splines_ok && e.curve && e.curve->kind == "nurbs" && e.curve->degree == 3 &&
                         e.curve->knots.size() == e.curve->poles.size() + e.curve->degree + 1 && !e.curve->weights;
        }
        EXPECT(splines > 0 && splines_ok, "the extruded spline's nurbs edge does not read as a degree-3 B-spline");
    }

    // Intersect: two equal pipes crossing at right angles meet on ellipse chains whose
    // points lie on both pipes; apart, nothing; a zero tolerance refused in the kernel's
    // words. Two coaxial pipes overlapping in height share a wall band: an overlap whose
    // rings lie on that wall.
    {
        const double tol = 1e-3;
        auto off_a = [](const bs::Vec3& p) { return std::fabs(std::sqrt(p[0] * p[0] + p[1] * p[1]) - 1); };
        auto off_b = [](const bs::Vec3& p) { return std::fabs(std::sqrt(p[0] * p[0] + (p[2] - 3) * (p[2] - 3)) - 1); };
        CADACLYSM_TRY(pipe_a, bs::Solid::cylinder(1, 6));
        CADACLYSM_TRY(upright, bs::Solid::cylinder(1, 6));
        CADACLYSM_TRY(pipe_b, upright.rotate({bs::Vec3{0, 0, 3}, bs::Vec3{1, 0, 0}}, 3.14159265358979323846 / 2));
        CADACLYSM_TRY(found, pipe_a.intersect(pipe_b, tol));
        EXPECT(found.chains.size() >= 2 && found.overlaps.empty(), "the crossed pipes do not meet on chains alone");
        std::size_t ellipses = 0;
        bool chains_ok = true;
        for (const bs::Chain& c : found.chains) {
            chains_ok = chains_ok && c.face_a < pipe_a.faces() && c.face_b < pipe_b.faces() && c.points.size() >= 2;
            for (const bs::Vec3& p : c.points) chains_ok = chains_ok && off_a(p) < 50 * tol && off_b(p) < 50 * tol;
            if (!c.curve) continue;
            chains_ok = chains_ok && (c.curve->kind == "ellipse" || c.curve->kind == "nurbs");
            if (c.curve->kind != "ellipse") continue;
            ++ellipses;
            double t = (c.curve->t0 + c.curve->t1) / 2;
            bs::Vec3 q{};
            for (int k = 0; k < 3; ++k)
                q[k] = c.curve->origin[k] + c.curve->x[k] * c.curve->radius * std::cos(t) + c.curve->y[k] * c.curve->radius2 * std::sin(t);
            chains_ok = chains_ok && off_a(q) < 50 * tol && off_b(q) < 50 * tol;
        }
        EXPECT(chains_ok && ellipses > 0, "the crossed pipes' chains do not read as ellipses on both pipes");
        CADACLYSM_TRY(far_pipe, pipe_b.translate(10, 0, 0));
        CADACLYSM_TRY(apart, pipe_a.intersect(far_pipe));
        EXPECT(apart.chains.empty() && apart.overlaps.empty(), "pipes apart still meet");
        auto zero = pipe_a.intersect(pipe_b, 0.0);
        EXPECT(!zero && zero.error().message.find("intersect: tolerance must be positive and finite") != std::string::npos,
               "Solid::intersect at a zero tolerance: " + (zero ? std::string("accepted") : zero.error().message));
        CADACLYSM_TRY(lower, bs::Solid::cylinder(1, 4));
        CADACLYSM_TRY(base, bs::Solid::cylinder(1, 4));
        CADACLYSM_TRY(upper, base.translate(0, 0, 2));
        CADACLYSM_TRY(shared, lower.intersect(upper, tol));
        EXPECT(!shared.overlaps.empty() && !shared.overlaps[0].loops.empty(), "the coaxial pipes share no wall band");
        bool rings_ok = true;
        for (const auto& ring : shared.overlaps[0].loops) {
            rings_ok = rings_ok && ring.size() >= 3;
            for (const bs::Vec3& p : ring) rings_ok = rings_ok && off_a(p) < 50 * tol && p[2] >= 2 - 50 * tol && p[2] <= 4 + 50 * tol;
        }
        EXPECT(rings_ok, "an overlap ring leaves the shared band");
    }

    // Solid x profile hits: a line through a cuboid pierces two faces and is cut into three
    // pieces, outside/inside/outside, the middle one spanning the box and sweeping; a loop no
    // hit cuts is one piece; an open sheet has no pieces; a zero tolerance refused verbatim.
    {
        CADACLYSM_TRY(xy0, bs::Frame::xy());
        CADACLYSM_TRY(box, bs::Solid::cuboid(10, 20, 30));
        CADACLYSM_TRY(line, bs::Profile::path({-20, 0}).line_to(20, 0).end_open());
        std::vector<std::string> phases;
        CADACLYSM_TRY(found, box.hits(line, xy0, bs::DEFAULT_TOLERANCE,
                                      [&](std::string_view phase, std::size_t, std::size_t) { phases.push_back(std::string(phase)); }));
        EXPECT(found.hits.size() == 2 && found.pieces.size() == 3,
               "a line through a cuboid reads " + std::to_string(found.hits.size()) + " hits, " + std::to_string(found.pieces.size()) + " pieces");
        EXPECT(std::find(phases.begin(), phases.end(), "pieces") != phases.end(), "Solid::hits reported no \"pieces\" phase");
        for (std::size_t k = 0; k < 2; ++k) {
            const bs::Hit& h = found.hits[k];
            EXPECT(!h.run && !h.touch && std::fabs(h.start[0] - (k == 0 ? -5.0 : 5.0)) < 0.05 && h.a_start.segment == 0 &&
                       h.a_start.face == bs::NONE && h.b_start.face != bs::NONE && std::isfinite(h.b_start.u) && std::isfinite(h.b_start.v),
                   "solid hit " + std::to_string(k) + " is not a crossing of a face at x = +-5");
        }
        const std::vector<bs::Piece>& p = found.pieces;
        EXPECT(!p[0].inside && p[1].inside && !p[2].inside, "the pieces are not outside, inside, outside");
        EXPECT(p[0].start.t == 0 && p[2].end.t == 1 && p[0].end.t == p[1].start.t && p[1].end.t == p[2].start.t,
               "the pieces do not run head to tail");
        CADACLYSM_TRY(middle, bs::Solid::extrude_open(p[1].profile, xy0, 1));
        CADACLYSM_TRY(span, middle.bounds());
        EXPECT(std::fabs(span.first[0] + 5) < 0.05 && std::fabs(span.second[0] - 5) < 0.05,
               "the middle piece spans x " + std::to_string(span.first[0]) + " .. " + std::to_string(span.second[0]) + ", not the box");
        bs::SweepPath piece_path = bs::SweepPath::along(p[1].profile, xy0, bs::DEFAULT_TOLERANCE, true);
        CADACLYSM_TRY(ring, bs::Profile::circle(1));
        CADACLYSM_TRY(start_frame, bs::Frame::yz({-5, 0, 0}));
        CADACLYSM_TRY(rod, bs::Solid::sweep(ring, start_frame, piece_path));
        EXPECT(rod.faces() >= 1, "the middle piece does not sweep");
        CADACLYSM_TRY(circle, bs::Profile::circle(1));
        CADACLYSM_TRY(far_frame, bs::Frame::xy({100, 0, 0}));
        CADACLYSM_TRY(far_hits, box.hits(circle, far_frame));
        EXPECT(far_hits.hits.empty() && far_hits.pieces.size() == 1 && !far_hits.pieces[0].inside, "a circle far off is not one outside piece");
        CADACLYSM_TRY(square20, bs::Profile::rect(20, 20));
        CADACLYSM_TRY(sheet20, bs::Solid::face(square20, xy0));
        CADACLYSM_TRY(upright_line, bs::Profile::path({0, -20}).line_to(0, 20).end_open());
        CADACLYSM_TRY(xz0, bs::Frame::xz());
        CADACLYSM_TRY(across, sheet20.hits(upright_line, xz0));
        EXPECT(!across.hits.empty() && across.pieces.empty(), "a line across a sheet does not read hits and no pieces");
        auto zero = box.hits(line, xy0, 0.0);
        EXPECT(!zero && zero.error().message == "solid_profile_hits: tolerance must be positive and finite",
               "Solid::hits at a zero tolerance: " + (zero ? std::string("accepted") : zero.error().message));
    }

    // Common: the two circles share one lens (a 4-arc profile that extrudes to a solid);
    // apart, nothing; zero refused in the kernel's words.
    CADACLYSM_TRY(lenses, circle_a.common(circle_b));
    EXPECT(lenses.size() == 1, "two crossing circles share " + std::to_string(lenses.size()) + " regions, not 1");
    CADACLYSM_TRY(lens_solid, bs::Workplane::xy().extrude(lenses[0], 1.0).solid());
    EXPECT(lens_solid.faces() == 6, "the lens extrudes to " + std::to_string(lens_solid.faces()) + " faces, not 6");
    CADACLYSM_TRY(no_share, circle_a.common(far));
    EXPECT(no_share.empty(), "two circles 100 apart share a region");
    auto bad_common = circle_a.common(circle_b, 0);
    EXPECT(!bad_common && bad_common.error().message.find("profile_common: tolerance must be positive and finite") != std::string::npos,
           "Profile::common at a zero tolerance: " + (bad_common ? std::string("accepted") : bad_common.error().message));
#if CADACLYSM_CHECKED
    // C++ only: the rows borrow the profile's cache. Asking again at another tolerance
    // replaces it; moving the profile keeps it; destroying the profile ends it.
    CADACLYSM_TRY(coarse, holed.polylines(0.1));
    EXPECT(trips([&] { (void)rings[0]; }), "a profile polyline read after a re-ask at a new tolerance did not trip");
    EXPECT(trap::message.find("stale view") != std::string::npos, "the trip does not say the profile's view is stale");
    EXPECT(!trips([&] { (void)coarse[0]; }), "a current profile view tripped");
    std::optional<bs::Profile> moved(std::move(holed));
    EXPECT(!trips([&] { (void)coarse.size(); }), "a move invalidated the profile's views");
    moved.reset();
    EXPECT(trips([&] { (void)coarse.size(); }), "a profile view read after its profile was destroyed did not trip");
#endif
    return {};
}

// The kernel half of the smoke: the plate with a hole and a pin, filleted, meshed and
// written as STEP. Returns the filleted part and its face count for Task 6's round trip.
static Result<std::pair<bs::Solid, std::uint32_t>> solids() {
    CADACLYSM_TRY(rect, bs::Profile::rect(80, 40));
    CADACLYSM_TRY(hole, bs::Profile::circle(4));
    CADACLYSM_TRY(outline, rect.with_hole(hole));
    CADACLYSM_TRY(plate, bs::Workplane::xy().extrude(outline, 6).solid());
    // The chain borrows the plate, which stays the caller's to join the pin to.
    CADACLYSM_TRY(pin, bs::Workplane::from_solid(plate)
                           .faces((bs::Selector::max)(bs::Axis::z))
                           .workplane()
                           .cylinder(5, 10)
                           .solid());
    // A progress callback reaches the library through the noexcept trampoline.
    std::size_t reports = 0;
    CADACLYSM_TRY(part, plate.join(pin, bs::DEFAULT_TOLERANCE, [&](std::string_view, std::size_t, std::size_t) { ++reports; }));
    EXPECT(reports > 0, "join reported no progress");

    // The plate's own corners: vertical lines between planes.
    std::vector<std::uint32_t> corners;
    CADACLYSM_TRY(part_edges, part.edges());
    for (const bs::Edge& edge : part_edges) {
        std::optional<bs::Vec3> d = edge.direction();
        bool vertical = d && std::fabs((*d)[2]) > 0.99;
        bool planes = true;
        for (std::uint32_t f : edge.faces) {
            CADACLYSM_TRY(kind, part.face_kind(f));
            planes = planes && kind == "plane";
        }
        if (vertical && planes) corners.push_back(edge.index);
    }
    CADACLYSM_TRY(rounded, part.fillet(corners, 1.0));
    std::uint32_t faces = rounded.faces();
    CADACLYSM_TRY(watertight, rounded.is_watertight());
    CADACLYSM_TRY(shape, rounded.manifold());
    std::printf("faces=%u watertight=%d closed=%d\n", faces, watertight ? 1 : 0, shape.is_closed ? 1 : 0);
    EXPECT(watertight, "the filleted part is not watertight");
    EXPECT(shape.is_closed && shape.faces == faces, "the filleted part is not a closed manifold");
    // 6 plate faces, 1 hole, the pin's wall and top, and one face per rounded corner.
    EXPECT(faces == 15, "the filleted part has " + std::to_string(faces) + " faces, not 15");

    CADACLYSM_TRY_VOID(sheet_verbs(plate));
    CADACLYSM_TRY_VOID(frames());
    CADACLYSM_TRY_VOID(lofts());
    CADACLYSM_TRY_VOID(outlines());

    // Colour: a gold plate joined with a blue pin -- gold overall, the pin's top blue.
    CADACLYSM_TRY(blue_rgb, bs::rgb("#3366ff"));
    CADACLYSM_TRY(gold, plate.coloured({0.8, 0.6, 0.4}));
    CADACLYSM_TRY(blue, pin.coloured(blue_rgb));
    CADACLYSM_TRY(coloured, gold.join(blue));
    CADACLYSM_TRY(top, coloured.select_face((bs::Selector::max)(bs::Axis::z)));
    CADACLYSM_TRY(part_colour, coloured.colour());
    CADACLYSM_TRY(top_colour, coloured.face_colour(top));
    EXPECT(part_colour == (bs::Vec3{0.8, 0.6, 0.4}) && top_colour == blue_rgb, "the colours did not carry through the join");
    CADACLYSM_TRY(plain, bs::Solid::cuboid(1, 1, 1));
    CADACLYSM_TRY(plain_colour, plain.colour());
    EXPECT(!plain_colour, "an uncoloured solid has a colour");

    // Profile colour: read back, carried by translate, not carried into a solid, the
    // original left untouched, and an out-of-range triple refused.
    CADACLYSM_TRY(outline_colour_before, outline.colour());
    EXPECT(!outline_colour_before, "outline has a colour before anything coloured it");
    CADACLYSM_TRY(gold_outline, outline.coloured({0.8, 0.6, 0.4}));
    CADACLYSM_TRY(gold_outline_colour, gold_outline.colour());
    EXPECT(gold_outline_colour == (bs::Vec3{0.8, 0.6, 0.4}), "profile coloured did not read back");
    CADACLYSM_TRY(outline_colour_after, outline.colour());
    EXPECT(!outline_colour_after, "coloured() on outline reached back into outline itself");
    CADACLYSM_TRY(moved_outline, gold_outline.translate(1, 1));
    CADACLYSM_TRY(moved_outline_colour, moved_outline.colour());
    EXPECT(moved_outline_colour == gold_outline_colour, "a profile's colour did not carry through translate");
    CADACLYSM_TRY(colour_frame, bs::Frame::xy());
    CADACLYSM_TRY(extruded_from_gold, bs::Solid::extrude(gold_outline, colour_frame, 3));
    CADACLYSM_TRY(extruded_colour, extruded_from_gold.colour());
    EXPECT(!extruded_colour, "a profile's colour reached the solid extruded from it");
    auto bad_profile_colour = outline.coloured({2, 0, 0});
    EXPECT(!bad_profile_colour && bad_profile_colour.error().message == "profile_coloured: r, g and b must be in 0..1",
           "profile coloured did not refuse a component out of 0..1");

    // Edge colour: every edge, an override on some (which wins), an empty list colouring
    // none, and edge_polyline_colours aligned with edge_polylines.
    CADACLYSM_TRY(cube, bs::Solid::cuboid(10, 10, 10));
    CADACLYSM_TRY(no_edge_colour, cube.edge_colour(0));
    EXPECT(!no_edge_colour, "an uncoloured cube edge has a colour");
    CADACLYSM_TRY(no_polyline_colours, cube.edge_polyline_colours());
    EXPECT(no_polyline_colours.empty(), "an uncoloured cube has edge polyline colours");
    CADACLYSM_TRY(all_gold_edges, cube.edges_coloured({0.8, 0.6, 0.4}));
    CADACLYSM_TRY(cube_edges, cube.edges());
    CADACLYSM_TRY(two_edges,
                  all_gold_edges.edges_coloured({0.2, 0.4, 1.0}, std::vector<std::uint32_t>{cube_edges[0].index, 5}));
    CADACLYSM_TRY(edge5_colour, two_edges.edge_colour(5));
    EXPECT(edge5_colour == (bs::Vec3{0.2, 0.4, 1.0}), "edge 5's own colour did not win over the all-edges one");
    CADACLYSM_TRY(edge1_colour, two_edges.edge_colour(1));
    EXPECT(edge1_colour == (bs::Vec3{0.8, 0.6, 0.4}), "edge 1 did not read the all-edges colour");
    CADACLYSM_TRY(moved_two_edges, two_edges.translate(1, 0, 0));
    CADACLYSM_TRY(moved_edge5_colour, moved_two_edges.edge_colour(5));
    EXPECT(moved_edge5_colour == (bs::Vec3{0.2, 0.4, 1.0}), "an edge colour did not carry through translate");
    CADACLYSM_TRY(none_coloured, all_gold_edges.edges_coloured({1, 0, 0}, std::vector<std::uint32_t>{}));
    CADACLYSM_TRY(edge0_after_empty, none_coloured.edge_colour(0));
    EXPECT(edge0_after_empty == (bs::Vec3{0.8, 0.6, 0.4}), "an empty edge list coloured an edge");
    CADACLYSM_TRY(edge_colours, two_edges.edge_polyline_colours());
    CADACLYSM_TRY(two_edges_polylines, two_edges.edge_polylines());
    EXPECT(edge_colours.size() == two_edges_polylines.size(),
           "edge_polyline_colours does not align with edge_polylines");
    bool a_polyline_read_blue = false;
    for (const std::optional<bs::Vec3>& c : edge_colours) {
        if (c && *c == bs::Vec3{0.2, 0.4, 1.0}) a_polyline_read_blue = true;
    }
    EXPECT(a_polyline_read_blue, "no edge polyline read back the edge-specific colour");
    auto bad_edge = cube.edges_coloured({1, 0, 0}, std::vector<std::uint32_t>{12});
    EXPECT(!bad_edge && bad_edge.error().message == "edges_coloured: edge 12 is not one of the solid's 12",
           "edges_coloured did not refuse an edge the cube has not got");
    auto bad_edge_colour = cube.edge_colour(12);
    EXPECT(!bad_edge_colour && bad_edge_colour.error().message == "edge_colour: edge 12 is not one of the solid's 12",
           "edge_colour did not refuse an edge the cube has not got");
    auto bad_tolerance_colours = two_edges.edge_polyline_colours(-1);
    EXPECT(!bad_tolerance_colours &&
               bad_tolerance_colours.error().message == "edge_polyline_colours: tolerance must be positive and finite",
           "edge_polyline_colours did not refuse a negative tolerance");

    // A face: the outline as a sheet, which pushed out is the plate again.
    CADACLYSM_TRY(xy, bs::Frame::xy());
    CADACLYSM_TRY(sheet, bs::Solid::face(outline, xy));
    CADACLYSM_TRY(pushed, sheet.extrude_faces(6));
    CADACLYSM_TRY(pushed_closed, pushed.is_watertight());
    EXPECT(sheet.faces() == 1 && pushed.faces() == plate.faces() && pushed_closed, "the outline's face did not push out to the plate");

    // Meshes borrow the solid's cache: a coarse mesh, then a fine one.
    CADACLYSM_TRY(coarse_view, rounded.mesh(0.5));
    std::uint32_t coarse = coarse_view.triangle_count();
    CADACLYSM_TRY(mesh, rounded.mesh(0.05));
    std::uint32_t fine = mesh.triangle_count();
    EXPECT(mesh.normals().size() == mesh.positions().size(), "the kernel mesh has no normals");
    cadaclysm::Span<const std::uint32_t> indices = mesh.indices();
    EXPECT(std::all_of(indices.begin(), indices.end(), [&](std::uint32_t i) { return i < mesh.vertex_count(); }),
           "a kernel index points past the vertices");
    EXPECT(fine > coarse, "a finer tolerance did not mesh finer");

    // f64 twins: mesh64(0.05) shares mesh(0.05)'s counts and first position narrowed;
    // bounds64(0.05) is the same box as bounds_at(0.05) (both close to the origin
    // here, so an epsilon rather than exact -- the plate is not at nice round numbers
    // the way the reader's cube is). Catches: bounds64 returning bounds' widened
    // float box instead of its own tessellation's unnarrowed one.
    CADACLYSM_TRY(mesh64, rounded.mesh64(0.05));
    EXPECT(mesh64.vertex_count() == mesh.vertex_count() && mesh64.index_count() == mesh.index_count(),
           "blacksmith mesh64(0.05)'s counts do not equal mesh(0.05)'s");
    cadaclysm::Span<const double> mesh64_p = mesh64.positions();
    cadaclysm::Span<const float> mesh_p = mesh.positions();
    EXPECT(mesh64_p.size() >= 3 && mesh_p.size() >= 3 && static_cast<float>(mesh64_p[0]) == mesh_p[0] &&
               static_cast<float>(mesh64_p[1]) == mesh_p[1] && static_cast<float>(mesh64_p[2]) == mesh_p[2],
           "blacksmith mesh64's first position narrowed does not equal mesh's");
    CADACLYSM_TRY(box64, rounded.bounds64(0.05));
    CADACLYSM_TRY(box32, rounded.bounds_at(0.05));
    bool boxes_agree = true;
    for (int i = 0; i < 3; ++i) {
        boxes_agree = boxes_agree && std::fabs(box64.first[i] - box32.first[i]) < 1e-6 &&
                      std::fabs(box64.second[i] - box32.second[i]) < 1e-6;
    }
    EXPECT(boxes_agree, "blacksmith bounds64(0.05) does not equal bounds_at(0.05)");
    std::printf("blacksmith f64 twins: mesh64 %u triangles, bounds64 max=(%g, %g, %g)\n", mesh64.triangle_count(),
                box64.second[0], box64.second[1], box64.second[2]);

    CADACLYSM_TRY(polylines, rounded.edge_polylines(0.05));
    bool every_row_a_line = !polylines.empty();
    for (std::size_t i = 0; i < polylines.size(); ++i) every_row_a_line = every_row_a_line && polylines[i].size() >= 6;
    EXPECT(every_row_a_line, "the edge polylines are empty");
    // One count per face at the same tolerance, summing to the mesh's triangles.
    CADACLYSM_TRY(per_face, rounded.face_triangles(0.05));
    std::uint32_t summed = 0;
    for (std::size_t f = 0; f < per_face.size(); ++f) summed += per_face[f];
    EXPECT(per_face.size() == faces && summed == fine && per_face.copy().size() == faces,
           "face_triangles is not one count per face summing to the mesh's triangles");
    std::printf("mesh: %u triangles at 0.5, %u at 0.05; %zu edge polylines\n", coarse, fine, polylines.size());
#if CADACLYSM_CHECKED
    // C++ only: the coarse view's memory was replaced by the fine mesh; reading it trips.
    EXPECT(trips([&] { (void)coarse_view.positions(); }), "a view read after a re-mesh at a new tolerance did not trip");
    EXPECT(trap::message.find("stale view") != std::string::npos, "the trip does not say the view is stale");
    EXPECT(!trips([&] { (void)mesh.positions(); }), "a current view tripped");
    // Moving a solid keeps its views; closing it does not.
    CADACLYSM_TRY(box, bs::Solid::cuboid(1, 2, 3));
    CADACLYSM_TRY(box_view, box.mesh(0.1));
    bs::Solid moved = std::move(box);
    EXPECT(!trips([&] { (void)box_view.positions(); }) && box_view.vertex_count() > 0, "a move invalidated the solid's views");
    moved.close();
    EXPECT(trips([&] { (void)box_view.positions(); }), "a view read after its solid closed did not trip");
#endif

    // Workplane latches: a step on an empty workplane, and everything after it skipped.
    bs::Workplane empty = bs::Workplane::xy();
    empty.translate(1, 0, 0).cuboid(1, 1, 1);
    EXPECT(empty.err() != nullptr && empty.err()->message.rfind("translate:", 0) == 0,
           "translate on an empty workplane did not latch");
    std::string latched = empty.err()->message;
    auto nothing = empty.solid();
    EXPECT(!nothing && nothing.error().message == latched, "solid() did not report the latched error");

    CADACLYSM_TRY_VOID(fem_kernel(rounded, sheet));

    // No schema: the kernel writes against its built-in AP203.
    CADACLYSM_TRY(text, rounded.step_text());
    EXPECT(text.rfind("ISO-10303-21;", 0) == 0, "step_text with no schema did not write valid STEP");
    EXPECT(!rounded.step_text(std::string("NO_SUCH_SCHEMA")), "an unknown schema name was accepted");

    // Split by a plane across the plate's length: two bodies.
    CADACLYSM_TRY(across, bs::Frame::yz());
    CADACLYSM_TRY(halves, plate.split_by_plane(across));
    EXPECT(halves.size() == 2, "split_by_plane gave " + std::to_string(halves.size()) + " bodies, not 2");

    // A profile draws its own plane, top by default -- unlike a solid, a sketch has no
    // camera-facing convention of its own, so its plane (z = 0) is already the page. The
    // default is pinned against an explicit iso view, not just checked non-empty: a top
    // default silently left at iso would make the two calls identical and this comparison
    // would pass wrongly.
    CADACLYSM_TRY(profile_svg_text, rect.svg_text());
    EXPECT(profile_svg_text.rfind("<svg", 0) == 0, "profile svg_text does not start with <svg");
    EXPECT(profile_svg_text.find("<path") != std::string::npos, "profile svg_text has no <path");
    bs::SvgOptions iso_view;
    iso_view.view = bs::SvgView::iso;
    CADACLYSM_TRY(profile_svg_iso, rect.svg_text(iso_view));
    EXPECT(profile_svg_text != profile_svg_iso, "profile svg: top default did not differ from an explicit iso view");
    std::string profile_svg = temp_file("cadaclysm-smoke-cpp-profile.svg");
    CADACLYSM_TRY_VOID(rect.svg(profile_svg));
    CADACLYSM_TRY(profile_svg_head, read_file(profile_svg));
    EXPECT(!profile_svg_head.empty(), "Profile::svg wrote an empty file");

    // The module writer draws a solid and a profile on one page: one <g> per drawable,
    // an id each -- the overload write_svg_text/write_svg take, widened from the
    // solids-only ones.
    CADACLYSM_TRY(mixed_svg_text, bs::write_svg_text({rounded}, {rect}, bs::SvgOptions()));
    EXPECT(mixed_svg_text.find("<path") != std::string::npos, "mixed solid+profile SVG has no <path");
    EXPECT(mixed_svg_text.find("id=\"solid-0\"") != std::string::npos, "mixed solid+profile SVG has no solid-0 group");
    EXPECT(mixed_svg_text.find("id=\"profile-0\"") != std::string::npos, "mixed solid+profile SVG has no profile-0 group");
    std::string mixed_svg = temp_file("cadaclysm-smoke-cpp-mixed.svg");
    CADACLYSM_TRY_VOID(bs::write_svg(mixed_svg, {rounded}, {rect}, bs::SvgOptions()));
    CADACLYSM_TRY(mixed_svg_head, read_file(mixed_svg));
    EXPECT(!mixed_svg_head.empty(), "write_svg (solids and profiles) wrote an empty file");

    return std::pair<bs::Solid, std::uint32_t>(std::move(rounded), faces);
}

// The kernel's part through STEP and back through the reader, then back into the
// kernel: the loop that proves both ABIs from one language.
static Result<void> round_trip(bs::Solid rounded, std::uint32_t faces) {
    std::string step = temp_file("cadaclysm-smoke-cpp.stp");
    CADACLYSM_TRY_VOID(rounded.step(step));
    auto back_opened = cadaclysm::open(step);
    if (!back_opened) return Error{"step read back: " + back_opened.error().message};
    cadaclysm::Scene back = std::move(back_opened).value();
    cadaclysm::Bounds b = back.bounds();
    std::printf("step read back: bounds max=(%g, %g, %g)\n", b.max[0], b.max[1], b.max[2]);
    // The plate is 80 x 40 x 6, centred on the origin, and the pin adds 10.
    EXPECT(std::fabs(b.max[0] - 40) < 0.01 && std::fabs(b.max[1] - 20) < 0.01 && std::fabs(b.max[2] - 16) < 0.01,
           "the STEP did not read back as the plate with its pin");

    // The same solid as SAT, written by the library itself, read back the same way.
    std::string sat = temp_file("cadaclysm-smoke-cpp.sat");
    CADACLYSM_TRY_VOID(rounded.sat(sat));
    CADACLYSM_TRY(sat_text, rounded.sat_text());
    EXPECT(sat_text.rfind("400 0 1 0", 0) == 0, "the SAT text does not open with the record version");
    {
        auto sat_opened = cadaclysm::open(sat);
        if (!sat_opened) return Error{"sat read back: " + sat_opened.error().message};
        cadaclysm::Bounds sb = sat_opened.value().bounds();
        std::printf("sat read back: bounds max=(%g, %g, %g)\n", sb.max[0], sb.max[1], sb.max[2]);
        EXPECT(std::fabs(sb.max[0] - 40) < 0.01 && std::fabs(sb.max[1] - 20) < 0.01 && std::fabs(sb.max[2] - 16) < 0.01,
               "the SAT did not read back as the plate with its pin");
    }

    // And as an OCCT .brep, written by the library itself, read back the same way.
    std::string brep_path = temp_file("cadaclysm-smoke-cpp.brep");
    CADACLYSM_TRY_VOID(rounded.brep(brep_path));
    CADACLYSM_TRY(brep_text, rounded.brep_text());
    EXPECT(brep_text.rfind("DBRep_DrawableShape", 0) == 0, "the .brep text does not open with its header");
    {
        auto brep_opened = cadaclysm::open(brep_path);
        if (!brep_opened) return Error{"brep read back: " + brep_opened.error().message};
        cadaclysm::Bounds bb = brep_opened.value().bounds();
        std::printf("brep read back: bounds max=(%g, %g, %g)\n", bb.max[0], bb.max[1], bb.max[2]);
        EXPECT(std::fabs(bb.max[0] - 40) < 0.01 && std::fabs(bb.max[1] - 20) < 0.01 && std::fabs(bb.max[2] - 16) < 0.01,
               "the .brep did not read back as the plate with its pin");
    }

    // The same solid as SVG, written by the library itself and matching svg_text's
    // own text; a refusal (fov out of range) surfacing as an Error.
    std::string svg = temp_file("cadaclysm-smoke-cpp.svg");
    CADACLYSM_TRY_VOID(rounded.svg(svg));
    CADACLYSM_TRY(svg_text, rounded.svg_text());
    EXPECT(svg_text.rfind("<svg", 0) == 0, "svg_text does not start with <svg");
    EXPECT(svg_text.find("<path") != std::string::npos, "svg_text has no <path");
    CADACLYSM_TRY(svg_head, read_file(svg));
    EXPECT(std::string(svg_head.begin(), svg_head.end()) == svg_text, "svg's file does not match svg_text's own text");
    bs::SvgOptions refused;
    refused.fov = 200;
    Result<std::string> bad_fov = rounded.svg_text(refused);
    EXPECT(!bad_fov, "fov = 200 was accepted");
    EXPECT(bad_fov.error().message.find("fov") != std::string::npos, "the fov refusal does not name the field");

    // And back into the kernel: the read body's brep, shared rather than copied, as a
    // solid that outlives the scene it came from.
    std::optional<cadaclysm::Node> body;
    for (const cadaclysm::Placement& placement : back.placements()) {
        cadaclysm::Node geometry = placement.geometry();
        if (geometry.brep()) {
            body = geometry;
            break;
        }
    }
    EXPECT(body.has_value(), "no placement of the read-back STEP has a brep");
    CADACLYSM_TRY(read, body->brep()->manifold());
    EXPECT(read.is_closed && read.faces == 15, "the read body is not the closed manifold written");
    CADACLYSM_TRY_VOID(fem_brep(back));
    auto imported_made = bs::Solid::from_node(*body);
    if (!imported_made) return Error{"from_node: " + imported_made.error().message};
    bs::Solid imported = std::move(imported_made).value();
    back.close();
    EXPECT(imported.faces() == faces, "from_node lost faces");
    CADACLYSM_TRY(opened, bs::Solid::open(step));
    EXPECT(opened.faces() == faces, "Solid::open lost faces");
    EXPECT(!bs::Solid::open(step, 1), "Solid::open found a second body in a one-body file");
    std::printf("from_node: %u faces after the scene closed; open: the same\n", faces);

    // to_scene is the same round trip in memory.
    CADACLYSM_TRY(own, rounded.bounds());
    CADACLYSM_TRY(scene, rounded.to_scene());
    rounded.close();
    cadaclysm::Bounds seen = scene.bounds();
    bool agrees = true;
    for (int i = 0; i < 3; ++i) agrees = agrees && std::fabs(static_cast<double>(seen.max[i]) - own.second[i]) < 0.05;
    EXPECT(agrees, "to_scene's bounds are not the solid's");
    return {};
}

static Result<void> run(int argc, char** argv) {
    std::string path = argc > 1 ? argv[1] : "samples/cube.scad";
    std::optional<std::string> license;
    if (argc > 2) license = argv[2];
    if (license) {
        auto loaded = cadaclysm::license(*license);
        if (!loaded) return Error{"license: " + loaded.error().message};
    }
    std::printf("cadaclysm %s built %s\n", cadaclysm::version().c_str(), cadaclysm::build_date().c_str());
    std::printf("license: %s\n", cadaclysm::license_info().c_str());
    std::printf("checked: %d\n", CADACLYSM_CHECKED);
    CADACLYSM_TRY_VOID(reader(path));
    if (license) {
        auto loaded = bs::license(*license);
        if (!loaded) return Error{"blacksmith license: " + loaded.error().message};
    }
    std::printf("blacksmith %s built %s\n", bs::version().c_str(), bs::build_date().c_str());
    std::printf("blacksmith license: %s\n", bs::license_info().c_str());
    EXPECT(bs::brep_layout_id() == cadaclysm::Brep::layout_id(), "the reader and the kernel are not from one build");
    CADACLYSM_TRY_VOID(kernel_values());
    CADACLYSM_TRY(built, solids());
    CADACLYSM_TRY_VOID(round_trip(std::move(built.first), built.second));
    std::puts("kernel: OK");
    return {};
}

int main(int argc, char** argv) {
    Result<void> outcome = run(argc, argv);
    if (!outcome) {
        std::fprintf(stderr, "FAIL: %s\n", outcome.error().message.c_str());
        return 1;
    }
    std::puts("OK");
    return 0;
}
