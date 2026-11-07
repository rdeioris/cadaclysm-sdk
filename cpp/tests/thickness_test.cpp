// ThicknessGauge, its readings, thickness(), mesh_thickness() and Solid::thickness_at_face -- at
// parity with the Python reference's test_thickness_* and test_mesh_thickness_* tests in
// test_cadaclysm_blacksmith.py, trimmed to what proves the marshalling: every field read, the
// none mappings, every refusal's prefix. The closed forms are the kernel's thickness_abi tests':
// a 10 x 10 x 2 plate reads 2, a right wedge's rule 5/sqrt 2 under its inscribed ball of 4.1421,
// two triangles 1 apart read 1. The kernel's own correctness is the kernel's tests' job. Needs
// the kernel library; the exit code is the verdict.
//
//     cadaclysm_thickness_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <optional>
#include <string>
#include <tuple>
#include <utility>
#include <vector>

using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;
using bs::Vec3;

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

static bool within(double a, double b, double tolerance) { return std::fabs(a - b) <= tolerance; }

// A refusal check that fails when nothing was refused: the call must have returned an error
// whose text starts with `prefix`.
template <class T>
static void refused(const Result<T>& r, const std::string& prefix, const std::string& what) {
    if (r.ok()) {
        check(false, what + ": expected a refusal, but the call succeeded");
        return;
    }
    const std::string& got = r.error().message;
    check(got.compare(0, prefix.size(), prefix) == 0, what + ": refused with \"" + got + "\", wanted it to start \"" + prefix + "\"");
}

static std::string text(double v) { return std::to_string(v); }

// The face of body `body` whose reading at `p` lies at `p`.
static std::uint32_t face_holding(const bs::ThicknessGauge& gauge, const bs::Solid& solid, std::uint32_t body, const Vec3& p) {
    for (std::uint32_t f = 0; f < solid.faces(); ++f) {
        Result<std::optional<bs::Thickness>> r = gauge.thickness_at(body, f, p, 100.0, 0.5);
        if (!r || !r.value()) continue;
        const Vec3& q = r.value()->point;
        if (within(q[0], p[0], 1e-9) && within(q[1], p[1], 1e-9) && within(q[2], p[2], 1e-9)) return f;
    }
    check(false, "no face holds the probe");
    return 0;
}

static bs::Solid plate() { return must(bs::Solid::cuboid(10, 10, 2), "cuboid"); }

static bs::Solid tube() {
    bs::Profile outer = must(bs::Profile::circle(5.0), "circle");
    bs::Profile inner = must(bs::Profile::circle(4.0), "circle");
    bs::Profile ring = must(outer.with_hole(inner), "with_hole");
    bs::Frame xy = must(bs::Frame::xy(), "Frame::xy");
    return must(bs::Solid::extrude(ring, xy, 10.0), "extrude");
}

static bs::Solid wedge() {
    bs::Profile triangle = must(bs::Profile::polygon({{0, 0}, {10, 0}, {0, 10}}), "polygon");
    bs::Frame xy = must(bs::Frame::xy(), "Frame::xy");
    return must(bs::Solid::extrude(triangle, xy, 20.0), "extrude");
}

// 1. A plate reads 2 at every cap vertex; every row's vertex indexes the mesh at its point;
// below the wall nothing reads; the sharp angle defaults to 0.
static void a_plate_reads_two_at_every_cap_vertex() {
    bs::Solid p = plate();
    bs::ThicknessGauge gauge = must(bs::ThicknessGauge::make({p}), "ThicknessGauge::make");
    check(gauge.body_count() == 1 && gauge.tolerance() == 0.01, "the gauge reads " + std::to_string(gauge.body_count()) + " bodies at " + text(gauge.tolerance()));
    std::vector<bs::Thickness> rows = must(gauge.thickness(10.0, 0.5), "thickness");
    bs::ThicknessMesh mesh = must(gauge.mesh(0), "mesh");
    int caps = 0;
    for (const bs::Thickness& r : rows) {
        bool cap = within(std::fabs(r.point[2]), 1.0, 1e-9) && within(r.opposite[2], -r.point[2], 1e-9);
        if (cap) {
            ++caps;
            check(within(r.thickness, 2.0, 1e-9) && within(r.exact_thickness, 2.0, 1e-9), "a cap row reads " + text(r.thickness) + " / " + text(r.exact_thickness));
            check(within(r.exact_opposite[2], -r.point[2], 1e-9), "a cap row's exact opposite is at z " + text(r.exact_opposite[2]));
            check(!r.knife && r.opposite_body == 0, "a cap row is a knife or reads another body");
        }
        check(r.body == 0 && r.vertex.has_value(), "a row has body " + std::to_string(r.body) + " and no vertex");
        if (!r.vertex || *r.vertex >= mesh.positions.size()) continue;
        check(mesh.positions[*r.vertex] == r.point, "a row's vertex does not index its point in the mesh");
        check(!r.sphere || std::isfinite(*r.sphere), "a row's sphere is not finite");
    }
    check(caps >= 8, "only " + std::to_string(caps) + " cap rows of " + std::to_string(rows.size()));
    // below the wall nothing reads; the sharp angle defaults to 0
    bs::ThicknessGauge again = must(bs::ThicknessGauge::make({p}, 0.01), "ThicknessGauge::make");
    check(must(again.thickness(1.0), "thickness at 1").empty(), "maximum 1 still read a wall");
    check(must(again.thickness(10.0), "thickness at 10").size() == rows.size(), "the default sharp angle read another number of rows");
}

// 2. The mesh is a copy that matches the readings and outlives the gauge; a body past the end is
// refused.
static void the_gauge_mesh_is_a_copy_that_matches_the_readings() {
    bs::Solid p = plate();
    bs::ThicknessGauge gauge = must(bs::ThicknessGauge::make({p}), "ThicknessGauge::make");
    bs::ThicknessMesh m = must(gauge.mesh(0), "mesh");
    check(m.faces.size() == m.triangles.size() && m.triangles.size() >= 12, "the mesh has " + std::to_string(m.triangles.size()) + " triangles, " + std::to_string(m.faces.size()) + " faces");
    check(m.normals.size() == m.positions.size() && !m.positions.empty(), "the mesh has " + std::to_string(m.normals.size()) + " normals for " + std::to_string(m.positions.size()) + " points");
    for (const Vec3& n : m.normals) {
        check(within(std::sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]), 1.0, 1e-9), "a normal is not unit");
    }
    for (std::uint32_t f : m.faces) check(f < p.faces(), "a triangle's face " + std::to_string(f) + " is past the solid");
    for (const std::array<std::uint32_t, 3>& t : m.triangles) {
        for (std::uint32_t k : t) check(k < m.positions.size(), "a triangle names point " + std::to_string(k));
    }
    std::vector<bs::Thickness> rows = must(gauge.thickness(100.0, 0.5), "thickness");
    check(rows.size() == m.positions.size(), "the readings are " + std::to_string(rows.size()) + " for " + std::to_string(m.positions.size()) + " vertices");
    for (const bs::Thickness& r : rows) {
        if (!r.vertex) continue;
        for (std::size_t t = 0; t < m.triangles.size(); ++t) {
            const std::array<std::uint32_t, 3>& tri = m.triangles[t];
            if (tri[0] == *r.vertex || tri[1] == *r.vertex || tri[2] == *r.vertex) {
                check(m.faces[t] == r.face, "a vertex's triangle lies on face " + std::to_string(m.faces[t]) + ", its row says " + std::to_string(r.face));
                break;
            }
        }
    }
    refused(gauge.mesh(1), "thickness_gauge_mesh: no body 1 -- there are 1", "mesh past the end");
    gauge.close();
    check(gauge.closed(), "the gauge is closed");
    check(m.positions.size() == rows.size(), "the copy changed once the gauge closed");
    refused(gauge.mesh(0), "thickness_gauge: closed", "mesh on a closed gauge");
}

// 3. A reading at a point is one row with no vertex.
static void a_reading_at_a_point_has_no_vertex() {
    bs::Solid p = plate();
    Vec3 probe = {1.0, 2.0, 1.0};
    bs::ThicknessGauge gauge = must(bs::ThicknessGauge::make({p}), "ThicknessGauge::make");
    std::uint32_t top = face_holding(gauge, p, 0, probe);
    std::optional<bs::Thickness> r = must(gauge.thickness_at(0, top, probe, 100.0, 0.5), "thickness_at");
    check(r.has_value(), "no reading at the probe");
    if (!r) return;
    check(!r->vertex.has_value(), "a reading at a point has a vertex");
    check(r->body == 0 && r->face == top && r->opposite_body == 0, "the reading is on body " + std::to_string(r->body) + " face " + std::to_string(r->face));
    check(r->point == probe, "the reading's point moved");
    check(within(r->thickness, 2.0, 1e-9) && within(r->exact_thickness, 2.0, 1e-9), "the reading is " + text(r->thickness) + " / " + text(r->exact_thickness));
    check(within(r->opposite[2], -1.0, 1e-9) && within(r->exact_opposite[2], -1.0, 1e-9), "the opposite is at z " + text(r->opposite[2]));
    check(r->sphere.has_value() && within(*r->sphere, 2.0, 0.02), "the sphere is " + (r->sphere ? text(*r->sphere) : std::string("none")));
    // thicker than the maximum: nothing
    check(!must(gauge.thickness_at(0, top, probe, 1.0, 0.5), "thickness_at at 1").has_value(), "maximum 1 still read the wall");
    std::optional<bs::Thickness> plain = must(gauge.thickness_at(0, top, probe, 100.0), "thickness_at, default sharp angle");
    check(plain && plain->thickness == r->thickness, "the default sharp angle read another thickness");
}

// 4. A face's thickness, with and without `at`, through the gauge and through the Solid; none
// where nothing is found.
static void a_face_reads_the_plate_and_none_where_nothing_is_found() {
    bs::Solid p = plate();
    bs::ThicknessGauge gauge = must(bs::ThicknessGauge::make({p}), "ThicknessGauge::make");
    std::uint32_t top = face_holding(gauge, p, 0, Vec3{1.0, 2.0, 1.0});
    std::optional<bs::FaceThickness> f = must(gauge.thickness_at_face(0, top, 100.0), "thickness_at_face");
    check(f && within(f->thickness, 2.0, 1e-9) && f->uniform && within(f->min, 2.0, 1e-9) && within(f->max, 2.0, 1e-9), "the face reads wrong");
    std::optional<bs::FaceThickness> a = must(gauge.thickness_at_face(0, top, Vec3{1.0, 2.0, 5.0}, 100.0), "thickness_at_face at");
    check(a && within(a->thickness, 2.0, 1e-9) && a->min == a->max && a->uniform, "the face at a point reads wrong");
    // not found: under the maximum, and off the face
    check(!must(gauge.thickness_at_face(0, top, 1.0), "thickness_at_face at 1").has_value(), "maximum 1 still found a thickness");
    check(!must(gauge.thickness_at_face(0, top, Vec3{50.0, 2.0, 5.0}, 100.0), "thickness_at_face off the face").has_value(),
          "a point off the face still found a thickness");
    // the one-body convenience: a gauge of its own
    std::optional<bs::FaceThickness> s = must(p.thickness_at_face(top, 100.0), "Solid::thickness_at_face");
    check(s && within(s->thickness, 2.0, 1e-9) && s->uniform, "the solid's face reads wrong");
    std::optional<bs::FaceThickness> sa = must(p.thickness_at_face(top, Vec3{1.0, 2.0, 5.0}, 100.0, 0.05), "Solid::thickness_at_face at");
    check(sa && within(sa->thickness, 2.0, 1e-9), "the solid's face at a point reads wrong");
    check(!must(p.thickness_at_face(top, 1.0), "Solid::thickness_at_face at 1").has_value(), "the solid's maximum 1 still found a thickness");
}

// 5. A ball past the maximum is none while the thickness still reads.
static void a_ball_past_the_maximum_is_none() {
    bs::Solid w = wedge();
    Vec3 probe = {5.0, 0.0, 10.0};
    bs::ThicknessGauge gauge = must(bs::ThicknessGauge::make({w}), "ThicknessGauge::make");
    std::uint32_t f = face_holding(gauge, w, 0, probe);
    std::optional<bs::Thickness> wide = must(gauge.thickness_at(0, f, probe, 100.0, 0.5), "thickness_at wide");
    check(wide && wide->sphere && within(*wide->sphere, 2.0 * 5.0 / (1.0 + std::sqrt(2.0)), 0.01), "the wide sphere reads wrong");
    std::optional<bs::Thickness> narrow = must(gauge.thickness_at(0, f, probe, 4.0, 0.5), "thickness_at narrow");
    check(narrow && within(narrow->thickness, 5.0 / std::sqrt(2.0), 1e-9), "the narrow thickness reads wrong");
    check(narrow && !narrow->sphere.has_value(), "the narrow sphere is not none");
}

// 6. Two bodies read each other, and the one-shot agrees with the gauge.
static void two_bodies_read_each_other_and_the_one_shot_agrees() {
    bs::Profile quad = must(bs::Profile::polygon({{0, 0}, {10, 0}, {10, 3}, {0, 1}}), "polygon");
    bs::Frame xy = must(bs::Frame::xy(), "Frame::xy");
    bs::Solid slab = must(bs::Solid::extrude(quad, xy, 4.0), "extrude");
    bs::Solid t = tube();
    bs::ThicknessGauge gauge = must(bs::ThicknessGauge::make({slab, t}), "ThicknessGauge::make");
    check(gauge.body_count() == 2, "the gauge has " + std::to_string(gauge.body_count()) + " bodies");
    std::vector<bs::Thickness> via = must(gauge.thickness(100.0, 0.5), "thickness");
    std::vector<bs::Thickness> one = must(bs::thickness({slab, t}, 100.0, 0.5), "thickness()");
    check(one.size() == via.size(), "the one-shot read " + std::to_string(one.size()) + " rows, the gauge " + std::to_string(via.size()));
    bool same = one.size() == via.size();
    for (std::size_t i = 0; same && i < one.size(); ++i) {
        same = one[i].body == via[i].body && one[i].vertex == via[i].vertex && one[i].face == via[i].face &&
               one[i].thickness == via[i].thickness && one[i].opposite_body == via[i].opposite_body;
    }
    check(same, "the one-shot's rows differ from the gauge's");
    bool slab_reads_tube = false, tube_reads_slab = false;
    for (const bs::Thickness& r : one) {
        slab_reads_tube = slab_reads_tube || (r.body == 0 && r.opposite_body == 1);
        tube_reads_slab = tube_reads_slab || (r.body == 1 && r.opposite_body == 0);
    }
    check(slab_reads_tube, "the slab reads no tube");
    check(tube_reads_slab, "the tube reads no slab");
    check(must(bs::thickness({slab}, 0.001), "thickness() at 0.001").empty(), "a wall under 0.001 read");
    check(!must(bs::thickness({slab}, 100.0, 0.0, 0.05), "thickness() at 0.05").empty(), "tolerance 0.05 read nothing");
    // an empty gauge is a gauge
    bs::ThicknessGauge empty = must(bs::ThicknessGauge::make({}), "ThicknessGauge::make of nothing");
    check(empty.body_count() == 0 && must(empty.thickness(1.0), "thickness of nothing").empty(), "an empty gauge read something");
}

static bs::ThicknessInputMesh lower() { return bs::ThicknessInputMesh{{{0, 0, 0}, {0, 1, 0}, {1, 0, 0}}, {{0, 1, 2}}}; }
static bs::ThicknessInputMesh upper() { return bs::ThicknessInputMesh{{{0, 0, 1}, {1, 0, 1}, {0, 1, 1}}, {{0, 1, 2}}}; }

// 7. Two triangles one apart read one across, by mesh then vertex.
static void two_triangles_one_apart_read_one_across() {
    std::vector<bs::ThicknessInputMesh> meshes = {lower(), upper()};
    std::vector<bs::MeshThickness> rows = must(bs::mesh_thickness(meshes, 10.0, 0.5), "mesh_thickness");
    check(rows.size() == 6, "the triangles read " + std::to_string(rows.size()) + " rows");
    if (rows.size() != 6) return;
    for (std::size_t i = 0; i < rows.size(); ++i) {
        const bs::MeshThickness& r = rows[i];
        check(within(r.thickness, 1.0, 1e-12) && !r.knife, "row " + std::to_string(i) + " reads " + text(r.thickness));
        check(r.opposite_mesh == 1 - r.mesh && r.opposite_triangle == 0, "row " + std::to_string(i) + " reads mesh " + std::to_string(r.opposite_mesh) + " triangle " + std::to_string(r.opposite_triangle));
        check(r.mesh < 2 && r.vertex < 3 && r.point == meshes[r.mesh].positions[r.vertex], "row " + std::to_string(i) + "'s point moved");
        check(within(r.opposite[2], 1.0 - r.point[2], 1e-12) && r.opposite[0] == r.point[0] && r.opposite[1] == r.point[1],
              "row " + std::to_string(i) + "'s opposite is not straight across");
        check(r.mesh == i / 3 && r.vertex == i % 3, "row " + std::to_string(i) + " is (" + std::to_string(r.mesh) + ", " + std::to_string(r.vertex) + ")");
    }
    // under the gap nothing; no meshes at all, nothing
    check(must(bs::mesh_thickness(meshes, 0.5, 0.5), "mesh_thickness at 0.5").empty(), "maximum 0.5 read the gap");
    check(must(bs::mesh_thickness({}, 1.0), "mesh_thickness of nothing").empty(), "no meshes read something");
    check(must(bs::mesh_thickness(meshes, 10.0), "mesh_thickness, default sharp angle").size() == 6, "the default sharp angle read another number of rows");
}

// 8. Every refusal the wrapper's types can carry, with the call's prefix.
static void refusals_carry_the_calls_prefix() {
    bs::Solid p = plate();
    refused(bs::ThicknessGauge::make({p}, -1.0), "thickness_gauge_new: the tolerance must be positive and finite", "tolerance -1");
    bs::ThicknessGauge g = must(bs::ThicknessGauge::make({p}), "ThicknessGauge::make");
    refused(g.thickness(0.0), "thickness_gauge_measure: the maximum must be positive and finite", "maximum 0");
    refused(g.thickness(10.0, -0.1), "thickness_gauge_measure: the sharp angle must be zero or positive and finite", "sharp angle -0.1");
    refused(g.thickness_at(3, 0, Vec3{1, 2, 1}, 10.0), "thickness_gauge_at: no body 3 -- there are 1", "thickness_at body 3");
    refused(g.thickness_at(0, 99, Vec3{1, 2, 1}, 10.0), "thickness_gauge_at: no face 99 -- the solid has 6 (0 to 5)", "thickness_at face 99");
    refused(g.thickness_at(0, 0, Vec3{1, std::nan(""), 1}, 10.0), "thickness_gauge_at: the point must be finite", "thickness_at NaN point");
    refused(g.thickness_at_face(2, 0, 10.0), "thickness_gauge_face: no body 2 -- there are 1", "thickness_at_face body 2");
    refused(g.thickness_at_face(0, 99, 10.0), "thickness_gauge_face: no face 99 -- the solid has 6 (0 to 5)", "thickness_at_face face 99");
    refused(g.thickness_at_face(0, 0, Vec3{HUGE_VAL, 0, 1}, 10.0), "thickness_gauge_face: the point must be finite", "thickness_at_face infinite at");
    refused(g.thickness_at_face(0, 0, 0.0), "thickness_gauge_face: the maximum must be positive and finite", "thickness_at_face maximum 0");
    g.close();
    g.close();  // twice is a no-op
    refused(g.thickness(10.0), "thickness_gauge: closed", "thickness on a closed gauge");
    refused(g.thickness_at(0, 0, Vec3{1, 2, 1}, 10.0), "thickness_gauge: closed", "thickness_at on a closed gauge");
    refused(g.thickness_at_face(0, 0, 10.0), "thickness_gauge: closed", "thickness_at_face on a closed gauge");
    // a gauge moved from is closed
    bs::ThicknessGauge live = must(bs::ThicknessGauge::make({p}), "ThicknessGauge::make");
    bs::ThicknessGauge moved = std::move(live);
    check(live.closed() && !moved.closed(), "a moved-from gauge is not closed, or the target is");
    refused(live.thickness(10.0), "thickness_gauge: closed", "thickness on a moved-from gauge");
    // the conveniences refuse with the gauge call's own prefix
    refused(bs::thickness({p}, -1.0), "thickness_gauge_measure: the maximum must be positive and finite", "thickness() maximum -1");
    refused(bs::thickness({p}, 10.0, 0.0, std::numeric_limits<double>::infinity()), "thickness_gauge_new: the tolerance must be positive and finite", "thickness() infinite tolerance");
    refused(p.thickness_at_face(99, 10.0), "thickness_gauge_face: no face 99", "Solid::thickness_at_face face 99");
    // mesh_thickness: the kernel's refusals (the pair and point shapes cannot be wrong here)
    std::vector<bs::ThicknessInputMesh> meshes = {lower(), upper()};
    refused(bs::mesh_thickness(meshes, 0.0), "mesh_thickness: the maximum must be positive and finite", "mesh_thickness maximum 0");
    refused(bs::mesh_thickness(meshes, 10.0, -0.5), "mesh_thickness: the sharp angle must be zero or positive and finite", "mesh_thickness sharp angle -0.5");
    refused(bs::mesh_thickness({bs::ThicknessInputMesh{{{0, 0, 0}, {1, 0, 0}}, {{0, 1, 2}}}}, 10.0),
            "mesh_thickness: a triangle names a position past the mesh", "mesh_thickness triangle past the mesh");
    refused(bs::mesh_thickness({bs::ThicknessInputMesh{{{0, 0, 0}, {1, std::nan(""), 0}, {0, 1, 0}}, {{0, 1, 2}}}}, 10.0),
            "mesh_thickness: a mesh position is not finite", "mesh_thickness NaN position");
}

int main(int argc, char** argv) {
    if (argc > 1) {
        if (cadaclysm::Result<void> lic = bs::license(argv[1]); !lic) {
            std::fprintf(stderr, "FAIL: license: %s\n", lic.error().message.c_str());
            return 1;
        }
    }
    struct Test {
        const char* name;
        void (*run)();
    };
    const Test tests[] = {
        {"a_plate_reads_two_at_every_cap_vertex", a_plate_reads_two_at_every_cap_vertex},
        {"the_gauge_mesh_is_a_copy_that_matches_the_readings", the_gauge_mesh_is_a_copy_that_matches_the_readings},
        {"a_reading_at_a_point_has_no_vertex", a_reading_at_a_point_has_no_vertex},
        {"a_face_reads_the_plate_and_none_where_nothing_is_found", a_face_reads_the_plate_and_none_where_nothing_is_found},
        {"a_ball_past_the_maximum_is_none", a_ball_past_the_maximum_is_none},
        {"two_bodies_read_each_other_and_the_one_shot_agrees", two_bodies_read_each_other_and_the_one_shot_agrees},
        {"two_triangles_one_apart_read_one_across", two_triangles_one_apart_read_one_across},
        {"refusals_carry_the_calls_prefix", refusals_carry_the_calls_prefix},
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
    std::printf("thickness: ok\n");
    return 0;
}
