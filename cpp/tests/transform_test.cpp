// Transform, Quaternion, Solid::transform / convert_to_nurbs / inexact_trims and
// Profile::rotate / scale / mirror / transform2d -- at parity with the Python reference's
// transform tests in test_cadaclysm_blacksmith.py, from
// test_a_transform_is_sixteen_numbers_row_major_and_composes_right_to_left to
// test_a_profile_turns_scales_mirrors_and_maps, plus the quaternion product's own figures. The
// kernel's own correctness is the kernel's tests' job. Needs the kernel library; the exit code
// is the verdict.
//
//     cadaclysm_transform_test [cadaclysm.lic]
#include <cadaclysm/cadaclysm_blacksmith.hpp>

#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>

using cadaclysm::Result;
namespace bs = cadaclysm::blacksmith;
using bs::Quaternion;
using bs::Transform;
using bs::Vec2;
using bs::Vec3;

static const double PI = 3.14159265358979323846;
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

static std::string text3(const Vec3& v) {
    return "(" + std::to_string(v[0]) + ", " + std::to_string(v[1]) + ", " + std::to_string(v[2]) + ")";
}

static void near3(const Vec3& got, const Vec3& want, double tolerance, const std::string& what) {
    bool ok = within(got[0], want[0], tolerance) && within(got[1], want[1], tolerance) && within(got[2], want[2], tolerance);
    check(ok, what + ": got " + text3(got) + ", wanted " + text3(want));
}

static void near4(const Quaternion& got, const std::array<double, 4>& want, double tolerance, const std::string& what) {
    bool ok = within(got.w(), want[0], tolerance) && within(got.x(), want[1], tolerance) && within(got.y(), want[2], tolerance) &&
              within(got.z(), want[3], tolerance);
    check(ok, what + ": got (" + std::to_string(got.w()) + ", " + std::to_string(got.x()) + ", " + std::to_string(got.y()) + ", " +
                  std::to_string(got.z()) + ")");
}

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

static bs::Frame fxy() { return must(bs::Frame::xy(), "Frame::xy"); }
static bs::Frame at(double x, double y, double z) { return must(bs::Frame::xy({x, y, z}), "Frame::xy"); }
static Quaternion quat(double w, double x, double y, double z) { return must(Quaternion::make(w, x, y, z), "Quaternion::make"); }

static double det(const Transform& t) {
    const std::array<double, 16>& r = t.rows();
    return r[0] * (r[5] * r[10] - r[6] * r[9]) - r[1] * (r[4] * r[10] - r[6] * r[8]) + r[2] * (r[4] * r[9] - r[5] * r[8]);
}

// 1. Sixteen numbers, row-major, composing right to left; the wrapper's own refusals.
static void a_transform_is_sixteen_numbers() {
    Transform t = must(Transform::translation({1, 2, 3}), "translation");
    const std::array<double, 16> want = {1, 0, 0, 1, 0, 1, 0, 2, 0, 0, 1, 3, 0, 0, 0, 1};
    check(t.rows() == want, "translation's rows");
    Transform s = must(Transform::scale({0, 0, 0}, 2), "scale");
    Transform ts = must(t.compose(s), "compose");
    Transform st = must(s.compose(t), "compose");
    near3(ts.point({1, 1, 1}), {3, 4, 5}, 1e-12, "t.compose(s).point");
    near3(st.point({1, 1, 1}), {4, 6, 8}, 1e-12, "s.compose(t).point");
    near3(must(t * s, "t * s").point({1, 1, 1}), {3, 4, 5}, 1e-12, "(t * s).point");
    near3(must(s * t, "s * t").point({1, 1, 1}), {4, 6, 8}, 1e-12, "(s * t).point");
    Transform undo = must(ts.inverse(), "inverse");
    near3(must(undo * ts, "inverse * ts").point({3, -4, 5}), {3, -4, 5}, 1e-12, "the inverse undoes");
    check(must(Transform::from_rows(t.rows()), "from_rows") == t, "from_rows(t.rows()) == t");
    check(Transform() == Transform::identity(), "Transform() == identity()");
    const cadaclysm::Matrix4 nested = {{{1, 0, 0, 1}, {0, 1, 0, 2}, {0, 0, 1, 3}, {0, 0, 0, 1}}};
    check(must(Transform::from_rows(nested), "from_rows(four rows)") == t, "four rows of four == t");
    refused(Transform::from_rows({1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1}),
            "Transform: the bottom row must be 0 0 0 1 (a projective map is not affine)", "a projective bottom row");
    refused(Transform::from_rows({0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14}), "Transform: a matrix is 16 numbers, got 15",
            "15 numbers");
    const double nan = std::numeric_limits<double>::quiet_NaN();
    refused(Transform::from_rows({1, 0, 0, nan, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}), "Transform: not finite", "a NaN");
    refused(must(Transform::scale_xyz(fxy(), 1, 1, 0), "scale_xyz").inverse(), "transform_inverse: the map is singular",
            "a flat map's inverse");
}

// 2. Every constructor against its closed form, and the library's refusals.
static void the_constructors_match_their_closed_forms() {
    near3(must(Transform::rotation({1, 0, 0}, {0, 0, 1}, PI / 2), "rotation").point({2, 0, 0}), {1, 1, 0}, 1e-12, "rotation");
    near3(must(Transform::mirror(at(0, 0, 5)), "mirror").point({1, 2, 3}), {1, 2, 7}, 1e-12, "mirror");
    near3(must(Transform::scale_xyz(fxy(), 2, 3, 4), "scale_xyz").point({1, 1, 1}), {2, 3, 4}, 1e-12, "scale_xyz");
    Transform about = must(Transform::scale({1, 2, 3}, 2), "scale");
    near3(about.point({2, 2, 3}), {3, 2, 3}, 1e-12, "scale about (1, 2, 3)");
    near3(about.point({1, 2, 3}), {1, 2, 3}, 1e-12, "scale fixes its centre");
    near3(must(Transform::shear(fxy(), {5, 0, 0}, 0.5), "shear").point({0, 0, 2}), {1, 0, 2}, 1e-12, "shear");
    near3(must(Transform::planar_projection(fxy()), "planar_projection").point({1, 2, 3}), {1, 2, 0}, 1e-12, "planar_projection");
    near3(must(Transform::project_along(fxy(), {1, 0, 1}), "project_along").point({0, 0, 2}), {-2, 0, 0}, 1e-12, "project_along");
    near3(must(Transform::plane_to_plane(fxy(), at(1, 2, 3)), "plane_to_plane").point({0, 0, 0}), {1, 2, 3}, 1e-12,
          "plane_to_plane");
    near3(must(Transform::change_basis(at(1, 2, 3), fxy()), "change_basis").point({0, 0, 0}), {1, 2, 3}, 1e-12, "change_basis");
    refused(Transform::shear(fxy(), {0, 0, 1}, 0.5), "transform_shear: the shear direction must lie in the plane",
            "a shear out of its plane");
    // Through the raw twelve numbers: Frame::of would refuse the skew frame first, in this
    // header's words.
    const std::array<double, 12> skew = {0, 0, 0, 1, 1e-3, 0, 0, 1, 0, 0, 0, 1};
    refused(Transform::mirror(skew), "transform_mirror: the frame is not right-handed and orthonormal", "a skew mirror");
}

// 3. Told rigid or a similarity, and split.
static void maps_are_told_and_split() {
    Transform turn = must(Transform::rotation({1, 2, 3}, {1, 1, 0}, 0.7), "rotation");
    check(must(turn.is_rigid(), "is_rigid"), "a turn is rigid");
    std::optional<double> one = must(turn.is_similarity(), "is_similarity");
    check(one.has_value() && within(*one, 1, 1e-9), "a turn is a similarity of 1");
    Transform big = must(must(Transform::scale({0, 0, 0}, 2.5), "scale") * turn, "compose");
    check(!must(big.is_rigid(), "is_rigid"), "a scaled turn is not rigid");
    std::optional<double> k = must(big.is_similarity(), "is_similarity");
    check(k.has_value() && within(*k, 2.5, 1e-9), "a scaled turn is a similarity of 2.5");
    std::optional<bs::SimilarityParts> split = must(big.decompose_similarity(), "decompose_similarity");
    check(split.has_value(), "a scaled turn splits as a similarity");
    if (split) {
        check(within(split->k, 2.5, 1e-9), "its k is " + std::to_string(split->k));
        check(must(split->orthogonal.is_rigid(), "is_rigid"), "its orthogonal part is rigid");
    }
    std::optional<bs::SimilarityParts> scaled =
        must(must(Transform::scale({1, 2, 3}, 2), "scale").decompose_similarity(), "decompose_similarity");
    check(scaled.has_value(), "a scale splits as a similarity");
    if (scaled) {
        near3(scaled->translation, {-1, -2, -3}, 1e-12, "a scale's translation");
        check(within(scaled->k, 2, 1e-12), "a scale's k is " + std::to_string(scaled->k));
        check(scaled->orthogonal == Transform::identity(), "a scale's orthogonal part is the identity");
    }
    std::optional<bs::RigidParts> rigid = must(turn.decompose_rigid(), "decompose_rigid");
    check(rigid.has_value(), "a turn splits as rigid");
    if (rigid) {
        const std::array<double, 16>& r = turn.rows();
        near3(rigid->translation, {r[3], r[7], r[11]}, 1e-12, "a turn's translation");
        check(must(rigid->orthogonal.is_rigid(), "is_rigid"), "a turn's rotation is rigid");
    }
    Transform stretch = must(Transform::scale_xyz(fxy(), 1, 2, 3), "scale_xyz");
    check(!must(stretch.is_similarity(), "is_similarity").has_value(), "a stretch is no similarity");
    check(!must(stretch.decompose_rigid(), "decompose_rigid").has_value(), "a stretch has no rigid split");
    check(!must(stretch.decompose_similarity(), "decompose_similarity").has_value(), "a stretch has no similarity split");
    Transform flipped = must(must(Transform::mirror(fxy()), "mirror") * stretch, "compose");
    std::optional<bs::AffineParts> polar = flipped.decompose_affine();
    check(polar.has_value(), "a mirrored stretch splits");
    if (polar) {
        near3(polar->stretch, {3, 2, 1}, 1e-9, "the stretches, largest first");
        // Only `rotation` carries the mirror; `axes` is a proper rotation -- which pins the order.
        check(within(det(polar->rotation), -1, 1e-9), "det(rotation) is " + std::to_string(det(polar->rotation)));
        check(within(det(polar->axes), 1, 1e-9), "det(axes) is " + std::to_string(det(polar->axes)));
    }
    check(!must(Transform::planar_projection(fxy()), "planar_projection").decompose_affine().has_value(),
          "a projection has no polar split");
    refused(turn.is_rigid(-1), "transform_is_rigid: the tolerance must be finite and not negative", "is_rigid(-1)");
    refused(turn.is_similarity(-1), "transform_is_similarity: the tolerance must be finite and not negative", "is_similarity(-1)");
}

// 4. A quaternion turns as its transform does; the product's own figures.
static void a_quaternion_turns_as_its_transform_does() {
    Quaternion q = must(Quaternion::from_axis_angle({0, 0, 2}, PI / 2), "from_axis_angle");
    near4(q, {std::cos(PI / 4), 0, 0, std::sin(PI / 4)}, 1e-12, "a quarter turn about z");
    check(within(q.angle(), PI / 2, 1e-12), "its angle is " + std::to_string(q.angle()));
    std::optional<Vec3> axis = q.axis();
    check(axis.has_value(), "a quarter turn has an axis");
    if (axis) near3(*axis, {0, 0, 1}, 1e-12, "its axis");
    check(!Quaternion().axis().has_value(), "the identity has no axis");
    near3(must(q.to_transform({1, 0, 0}), "to_transform").point({2, 0, 0}), {1, 1, 0}, 1e-12, "about (1, 0, 0)");
    Quaternion twice = quat(2 * q.w(), 2 * q.x(), 2 * q.y(), 2 * q.z());
    near3(must(twice.to_transform(), "to_transform").point({1, 0, 0}), {0, 1, 0}, 1e-12, "a non-unit quaternion");
    Quaternion back = must(Quaternion::from_transform(must(q.to_transform(), "to_transform")), "from_transform");
    near4(back, q.components(), 1e-12, "from_transform(to_transform)");
    Quaternion part = must(Quaternion::slerp(Quaternion(), q, 0.25), "slerp");
    check(within(part.angle(), PI / 8, 1e-12), "a quarter of the way turns " + std::to_string(part.angle()));
    near4(must(q * q.conjugate(), "q * conjugate"), {1, 0, 0, 0}, 1e-12, "q * q.conjugate()");
    check(must(quat(0, 0, 0, 2).normalized(), "normalized") == quat(0, 0, 0, 1), "(0, 0, 0, 2).normalized()");
    // Python's figures alone miss a sign flip in the product: every component pinned.
    check(must(quat(1, 2, 3, 4) * quat(5, 6, 7, 8), "product") == quat(-60, 12, 30, 24), "(1, 2, 3, 4) * (5, 6, 7, 8)");
    // Two general rotations: the product turns as the composed transforms do.
    Quaternion a = must(Quaternion::from_axis_angle({1, 2, 3}, 0.7), "from_axis_angle");
    Quaternion b = must(Quaternion::from_axis_angle({-2, 1, 0.5}, 1.9), "from_axis_angle");
    Transform ab = must(must(a * b, "a * b").to_transform(), "to_transform");
    Transform composed = must(must(a.to_transform(), "to_transform") * must(b.to_transform(), "to_transform"), "compose");
    bool same = true;
    for (std::size_t i = 0; i < 16; ++i) same = same && within(ab.rows()[i], composed.rows()[i], 1e-12);
    check(same, "(a * b).to_transform() matches a.to_transform() * b.to_transform()");
    refused(quat(0, 0, 0, 0).to_transform(), "quaternion_to_transform: the quaternion is zero", "a zero quaternion's transform");
    refused(Quaternion::from_transform(must(Transform::mirror(fxy()), "mirror")), "quaternion_from_transform: ",
            "a mirror's quaternion");
    Quaternion xy = must(must(Quaternion::from_axis_angle({1, 0, 0}, PI / 2), "from_axis_angle") *
                             must(Quaternion::from_axis_angle({0, 1, 0}, PI / 2), "from_axis_angle"),
                         "product");
    near4(xy, {0.5, 0.5, 0.5, 0.5}, 1e-12, "x quarter turn * y quarter turn");
    refused(Quaternion::make(1, std::numeric_limits<double>::infinity(), 0, 0), "Quaternion: not finite", "an infinite quaternion");
}

// 5. Far from unit length: scaled by the largest component first, as the ABI does.
static void a_quaternion_far_from_unit_length_normalises() {
    const double half = std::sqrt(0.5);
    for (double k : {1e200, 1e-170}) {
        std::string at_k = " at k = " + std::to_string(k);
        check(must(quat(k, 0, 0, 0).normalized(), "normalized") == quat(1, 0, 0, 0), "(k, 0, 0, 0).normalized()" + at_k);
        check(must(quat(0, 0, 0, -k).normalized(), "normalized") == quat(0, 0, 0, -1), "(0, 0, 0, -k).normalized()" + at_k);
        Quaternion kk = quat(k, k, 0, 0);
        near4(must(kk.normalized(), "normalized"), {half, half, 0, 0}, 1e-12, "(k, k, 0, 0).normalized()" + at_k);
        check(std::fabs(kk.length() - k * std::sqrt(2.0)) <= 1e-15 * k * std::sqrt(2.0), "(k, k, 0, 0).length" + at_k);
        check(within(kk.angle(), PI / 2, 1e-12), "(k, k, 0, 0).angle" + at_k);
        std::optional<Vec3> axis = quat(0, k, k, 0).axis();
        check(axis.has_value(), "(0, k, k, 0) has an axis" + at_k);
        if (axis) near3(*axis, {half, half, 0}, 1e-12, "(0, k, k, 0).axis" + at_k);
    }
    refused(quat(0, 0, 0, 0).normalized(), "Quaternion.normalized: the quaternion is zero", "a zero quaternion normalised");
}

// 6. A solid takes any affine map.
static void a_solid_takes_any_affine_map() {
    bs::Solid box = must(bs::Solid::cuboid(1, 2, 3), "cuboid");
    check(box.inexact_trims() == 0, "a solid no map made has lost nothing");
    bs::Solid stretched = must(box.transform(must(Transform::scale_xyz(fxy(), 2, 3, 0.5), "scale_xyz")), "transform");
    std::pair<Vec3, Vec3> b = must(stretched.bounds_at(0.05), "bounds_at");
    near3({b.second[0] - b.first[0], b.second[1] - b.first[1], b.second[2] - b.first[2]}, {2, 6, 1.5}, 1e-9, "the stretched box");
    check(stretched.inexact_trims() == 0, "a stretched box lost nothing");
    bs::Solid moved = must(box.transform(must(Transform::translation({1, 0, 0}), "translation").rows()), "transform(16 numbers)");
    check(moved.inexact_trims() == 0, "16 numbers lose nothing either");
    std::pair<Vec3, Vec3> mb = must(moved.bounds_at(0.05), "bounds_at");
    near3(mb.first, {0.5, -1, -1.5}, 1e-9, "16 numbers move the centred box 1 along x");
    bs::Solid can = must(bs::Solid::cylinder(1, 2), "cylinder");
    bs::Solid sheared = must(can.transform(must(Transform::shear(fxy(), {1, 0, 0}, 0.5), "shear")), "transform");
    double volume = must(sheared.mass(1e-7), "mass").volume;
    check(std::fabs(volume - 2 * PI) <= 1e-6 * 2 * PI, "the sheared can's volume is " + std::to_string(volume));
    bool nurbs = false;
    for (std::uint32_t i = 0; i < sheared.faces(); ++i) nurbs = nurbs || must(sheared.face_kind(i), "face_kind") == "nurbs";
    check(nurbs, "a sheared cylinder has a nurbs face");
    refused(box.transform(must(Transform::scale_xyz(fxy(), 1, 1, 0), "scale_xyz")), "solid_transform: a singular map flattens the solid",
            "a flattening map");
}

// 7. transform and convert_to_nurbs keep the colours and the name.
static void a_mapped_solid_keeps_its_colours_and_name() {
    bs::Solid plain = must(bs::Solid::cylinder(1, 2), "cylinder");
    bs::Solid grey = must(plain.coloured("#808080"), "coloured");
    bs::Solid painted = must(grey.named("can"), "named");
    std::optional<std::uint32_t> side;
    for (std::uint32_t i = 0; i < painted.faces() && !side; ++i) {
        if (must(painted.face_kind(i), "face_kind") == "cylinder") side = i;
    }
    check(side.has_value(), "a cylinder has a cylinder face");
    if (!side) return;
    const Vec3 blue = {0.2, 0.4, 1.0};
    bs::Solid can = must(painted.coloured(blue, *side), "coloured(face)");
    std::optional<Vec3> whole = must(can.colour(), "colour");
    check(whole.has_value(), "the can has a colour");
    Transform shear = must(Transform::shear(fxy(), {1, 0, 0}, 0.5), "shear");
    std::vector<bs::Solid> outs;
    outs.push_back(must(can.transform(shear), "transform"));
    outs.push_back(must(can.convert_to_nurbs(), "convert_to_nurbs"));
    const char* names[] = {"transform", "convert_to_nurbs"};
    for (std::size_t n = 0; n < outs.size(); ++n) {
        const bs::Solid& out = outs[n];
        std::string what = names[n];
        check(out.faces() == can.faces(), what + " keeps the face count");
        check(must(out.face_colour(*side), "face_colour") == std::optional<Vec3>(blue), what + " keeps the side's colour");
        for (std::uint32_t i = 0; i < out.faces(); ++i) {
            if (i == *side) continue;
            check(must(out.face_colour(i), "face_colour") == whole, what + " keeps face " + std::to_string(i) + " the solid's colour");
        }
        check(out.name() == std::optional<std::string>("can"), what + " keeps the name");
    }
}

// 8. The levels of convert_to_nurbs. The level is an enum here, so there is no bad-level
// string to refuse.
static void a_solid_converts_to_nurbs_at_each_level() {
    bs::Solid can = must(bs::Solid::cylinder(1, 2), "cylinder");
    bs::Solid every = must(can.convert_to_nurbs(), "convert_to_nurbs");
    std::set<std::string> kinds;
    for (std::uint32_t i = 0; i < every.faces(); ++i) kinds.insert(must(every.face_kind(i), "face_kind"));
    check(kinds == std::set<std::string>{"nurbs"}, "every face is nurbs at the default level");
    check(every.inexact_trims() == 0, "converting lost nothing");
    bs::Solid analytic = must(can.convert_to_nurbs(bs::NurbsLevel::analytic), "convert_to_nurbs(analytic)");
    std::set<std::string> some;
    for (std::uint32_t i = 0; i < analytic.faces(); ++i) some.insert(must(analytic.face_kind(i), "face_kind"));
    check(some.count("plane") == 1 && some.count("nurbs") == 1, "analytic keeps the planes and converts the cylinder");
}

// 9. A profile turns, scales, mirrors and maps, measured through its polylines.
struct Extent {
    double x_span, y_span, x_mid, y_mid;
};

static Extent extent_of(const bs::Profile& p) {
    bs::ProfilePolylines lines = must(p.polylines(0.01), "polylines");
    double lo_x = 1e300, hi_x = -1e300, lo_y = 1e300, hi_y = -1e300;
    for (std::size_t i = 0; i < lines.size(); ++i) {
        cadaclysm::Span<const float> row = lines[i];
        for (std::size_t j = 0; j + 2 < row.size(); j += 3) {
            lo_x = std::fmin(lo_x, row[j]);
            hi_x = std::fmax(hi_x, row[j]);
            lo_y = std::fmin(lo_y, row[j + 1]);
            hi_y = std::fmax(hi_y, row[j + 1]);
        }
    }
    return Extent{hi_x - lo_x, hi_y - lo_y, (hi_x + lo_x) / 2, (hi_y + lo_y) / 2};
}

static void a_profile_turns_scales_mirrors_and_maps() {
    bs::Profile rect = must(bs::Profile::rect(80, 40), "rect");
    Extent turned = extent_of(must(rect.rotate({0, 0}, PI / 2), "rotate"));
    check(within(turned.x_span, 40, 1e-3) && within(turned.y_span, 80, 1e-3), "a turned rect spans 40 by 80");
    Extent scaled = extent_of(must(rect.scale({0, 0}, 0.5, 2), "scale"));
    check(within(scaled.x_span, 40, 1e-3) && within(scaled.y_span, 80, 1e-3), "a scaled rect spans 40 by 80");
    // Off the origin, so the argument order shows: the centre's x and y, the turn's sense,
    // sx against sy.
    Extent r = extent_of(rect);
    Extent off = extent_of(must(rect.rotate({10, 20}, PI / 2), "rotate"));
    check(within(off.x_mid, 10 - (r.y_mid - 20), 1e-3) && within(off.y_mid, 20 + (r.x_mid - 10), 1e-3),
          "turned about (10, 20): centre (" + std::to_string(off.x_mid) + ", " + std::to_string(off.y_mid) + ")");
    Extent off_scaled = extent_of(must(rect.scale({10, 0}, 0.5, 2), "scale"));
    check(within(off_scaled.x_mid, 10 + 0.5 * (r.x_mid - 10), 1e-3) && within(off_scaled.y_mid, 2 * r.y_mid, 1e-3),
          "scaled about (10, 0): centre (" + std::to_string(off_scaled.x_mid) + ", " + std::to_string(off_scaled.y_mid) + ")");
    Extent mirrored = extent_of(must(rect.mirror({100, 0}, {0, 1}), "mirror"));
    check(within(mirrored.x_mid, 200, 1e-3), "mirrored across x = 100: x-centre " + std::to_string(mirrored.x_mid));
    Extent leaned = extent_of(must(rect.transform2d({1, 0.5, 0, 0, 1, 0}), "transform2d"));
    check(within(leaned.x_span, 100, 1e-3), "a leaned rect spans " + std::to_string(leaned.x_span));
    refused(rect.transform2d({1, 2, 0, 2, 4, 0}), "profile_transform2d: the 2D map is singular", "a singular 2D map");
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
        {"a_transform_is_sixteen_numbers", a_transform_is_sixteen_numbers},
        {"the_constructors_match_their_closed_forms", the_constructors_match_their_closed_forms},
        {"maps_are_told_and_split", maps_are_told_and_split},
        {"a_quaternion_turns_as_its_transform_does", a_quaternion_turns_as_its_transform_does},
        {"a_quaternion_far_from_unit_length_normalises", a_quaternion_far_from_unit_length_normalises},
        {"a_solid_takes_any_affine_map", a_solid_takes_any_affine_map},
        {"a_mapped_solid_keeps_its_colours_and_name", a_mapped_solid_keeps_its_colours_and_name},
        {"a_solid_converts_to_nurbs_at_each_level", a_solid_converts_to_nurbs_at_each_level},
        {"a_profile_turns_scales_mirrors_and_maps", a_profile_turns_scales_mirrors_and_maps},
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
    std::printf("transform: ok\n");
    return 0;
}
