// cadaclysm_blacksmith.hpp -- the kernel's C ABI (cadaclysm_blacksmith.h) as C++17, on
// the object model cadaclysm_blacksmith.py has: Profile, Path, SweepPath, Frame, Solid,
// Workplane. Every call that can fail returns a Result; nothing throws. Solids are
// immutable: every operation returns a new one. Includes the reader, for
// Solid::from_node and Solid::to_scene.
#ifndef CADACLYSM_BLACKSMITH_HPP
#define CADACLYSM_BLACKSMITH_HPP

#include <cadaclysm_blacksmith.h>

#include "cadaclysm.hpp"

#include <cmath>
#include <functional>
#include <limits>

namespace cadaclysm {
inline namespace CADACLYSM_ABI {
namespace blacksmith {

inline constexpr std::uint32_t NONE = CADACLYSM_BLACKSMITH_NONE;
// The tessellation tolerance every tolerance-taking call defaults to.
inline constexpr double DEFAULT_TOLERANCE = 0.05;
// fillet, chamfer, refillet and shell's default: a geometric tolerance, not a mesh one.
inline constexpr double FILLET_TOLERANCE = 1e-6;
// Profile::hits' default: how close two curves must come to meet, or to merge two points.
inline constexpr double HIT_TOLERANCE = 1e-6;

using BuildError = Error;
using Vec2 = std::array<double, 2>;
using Vec3 = cadaclysm::Vec3;
// A point and a direction.
using AxisLine = std::array<Vec3, 2>;
using Manifold = cadaclysm::Manifold;
using MeshData = cadaclysm::MeshData;
using MeshData64 = cadaclysm::MeshData64;
// Called with a phase name and progress through it; for the long operations.
using Progress = std::function<void(std::string_view phase, std::size_t done, std::size_t total)>;

enum class Axis : std::uint32_t { x = 0, y = 1, z = 2 };
// Which side of the tool Solid::trim keeps.
enum class Keep { outside, inside };
// The length unit a STEP file is written in.
enum class Unit : std::uint32_t { metre = 0, millimetre = 1, inch = 2 };

// One of the seven camera angles SvgOptions::view understands -- the same table the
// reader's own SvgView gives, kept separate because this file is the kernel's own
// (see SvgOptions below).
enum class SvgView { front, back, left, right, top, bottom, iso };

namespace detail {
// This view's (azimuth, elevation) in degrees.
inline std::pair<double, double> svg_view_angles(SvgView view) {
    switch (view) {
        case SvgView::front: return {-90.0, 0.0};
        case SvgView::back: return {90.0, 0.0};
        case SvgView::left: return {180.0, 0.0};
        case SvgView::right: return {0.0, 0.0};
        case SvgView::top: return {-90.0, 90.0};
        case SvgView::bottom: return {-90.0, -90.0};
        case SvgView::iso: return {-50.0, 28.0};
    }
    return {-50.0, 28.0};  // unreachable; every enumerator above returns
}
}  // namespace detail

// How an SVG drawing is made -- the camera in the viewer's words, the page, the pen
// and which line sets. Mirrors CadaclysmBlacksmithSvgOptions, defaulted the way
// cadaclysm_blacksmith_svg_options_init defaults the struct, with `view` supplying
// azimuth/elevation unless they are set directly (non-nullopt).
//
// Passed to write_svg_text, write_svg and Solid::svg_text/Solid::svg. Kept separate
// from the reader's cadaclysm::SvgOptions (as this file's other types are from
// cadaclysm.hpp's): there is no scene here to default `up` from, so it defaults to
// "z" -- a solid carries no convention of its own. A refused option (an
// out-of-range fov, say) is an Error naming the field, worded by the library itself.
struct SvgOptions {
    // front back left right top bottom iso -- fills azimuth/elevation unless they are
    // set directly. Default iso.
    SvgView view = SvgView::iso;
    // Degrees about the up axis from +X, overriding view's: -90 looks from -Y, the
    // front. nullopt keeps view's own.
    std::optional<double> azimuth;
    // Degrees above the horizon, overriding view's. nullopt keeps view's own.
    std::optional<double> elevation;
    // "y" or "z"; nullopt is "z", a solid carrying no convention of its own.
    std::optional<std::string> up;
    // Vertical field of view in degrees; 0 (the default) is orthographic.
    double fov = 0.0;
    // The page's viewBox width and height, page units. Default 1000 each.
    double width = 1000.0;
    double height = 1000.0;
    // Fraction of the content's extent left each side. Default 0.05.
    double margin = 0.05;
    // How far a written curve may stray, in page units. Default 0.1.
    double tolerance = 0.1;
    // 0xRRGGBB. Default black.
    std::uint32_t stroke = 0x000000;
    // The pen's width, page units. Default 1.
    double stroke_width = 1.0;
    // 0xRRGGBB, or nullopt (the default) for no <rect> behind the drawing -- the page
    // left to whatever the viewer composites it onto.
    std::optional<std::uint32_t> background;
    // Each solid's feature edges. Default true.
    bool edges = true;
    // A solid has no free curves of its own; ignored. Default false.
    bool curves = false;
    // A solid has no isocurves of its own; ignored. Default false.
    bool isocurves = false;
    // Write every line as straight segments within tolerance, instead of being fitted
    // back to cubic Beziers. Default false.
    bool polylines = false;
};

class Profile;
class Path;
class SweepPath;
class Frame;
class Solid;
class Workplane;
using Profiles = std::vector<std::reference_wrapper<const Profile>>;
using Solids = std::vector<std::reference_wrapper<const Solid>>;
// A profile on its frame: one section of Solid::loft_through, borrowed for the call.
using Section = std::pair<std::reference_wrapper<const Profile>, std::reference_wrapper<const Frame>>;
using Sections = std::vector<Section>;

namespace detail {
using cadaclysm::detail::text;

inline Error kernel_error(const char* fallback) {
    std::string message = text(::cadaclysm_blacksmith_last_error());
    if (message.empty()) message = fallback;
    return Error{std::move(message), Origin::kernel};
}

inline Error refuse(std::string message) { return Error{std::move(message), Origin::kernel}; }

// `options` packed into a CadaclysmBlacksmithSvgOptions: `view` fills
// azimuth/elevation unless they are set directly, `up` falls back to "z" -- a solid
// carries no convention of its own. cadaclysm_blacksmith_svg_options_init fills the
// struct first -- size included -- so a field this function never sets still carries
// the library's own default rather than a zeroed struct's.
inline CadaclysmBlacksmithSvgOptions build_svg_options(const SvgOptions& options) {
    CadaclysmBlacksmithSvgOptions raw;
    ::cadaclysm_blacksmith_svg_options_init(&raw);
    auto [base_azimuth, base_elevation] = svg_view_angles(options.view);
    const std::string& up = options.up ? *options.up : std::string("z");
    raw.up = (!up.empty() && (up.front() == 'y' || up.front() == 'Y')) ? 1u : 0u;
    raw.azimuth = options.azimuth.value_or(base_azimuth);
    raw.elevation = options.elevation.value_or(base_elevation);
    raw.fov = options.fov;
    raw.width = options.width;
    raw.height = options.height;
    raw.margin = options.margin;
    raw.tolerance = options.tolerance;
    raw.stroke_width = options.stroke_width;
    raw.stroke = options.stroke;
    raw.background = options.background.value_or(CADACLYSM_BLACKSMITH_SVG_TRANSPARENT);
    raw.flags = (options.edges ? CADACLYSM_BLACKSMITH_SVG_EDGES : 0u) | (options.curves ? CADACLYSM_BLACKSMITH_SVG_CURVES : 0u) |
                (options.isocurves ? CADACLYSM_BLACKSMITH_SVG_ISOCURVES : 0u) |
                (options.polylines ? CADACLYSM_BLACKSMITH_SVG_POLYLINES : 0u);
    return raw;
}

// noexcept: a callback that throws terminates here rather than unwinding through the
// library's Rust frames.
inline void progress_trampoline(const char* phase, std::size_t done, std::size_t total, void* user) noexcept {
    (*static_cast<const Progress*>(user))(phase ? std::string_view(phase) : std::string_view(), done, total);
}
inline CadaclysmBlacksmithProgress progress_fn(const Progress& progress) {
    return progress ? &progress_trampoline : nullptr;
}
inline void* progress_user(const Progress& progress) {
    return progress ? const_cast<Progress*>(&progress) : nullptr;
}

inline std::optional<std::string> env(const char* name) {
#if defined(_MSC_VER)
    char* value = nullptr;
    std::size_t size = 0;
    if (_dupenv_s(&value, &size, name) != 0 || value == nullptr) return std::nullopt;
    std::string out(value);
    std::free(value);
    return out;
#else
    const char* value = std::getenv(name);
    if (!value) return std::nullopt;
    return std::string(value);
#endif
}

inline double dot(const Vec3& a, const Vec3& b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
inline Vec3 cross(const Vec3& a, const Vec3& b) {
    return {a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]};
}
inline Result<Vec3> unit(const Vec3& v, const std::string& what) {
    double n = std::sqrt(dot(v, v));
    if (!(n > 1e-12 && n < (std::numeric_limits<double>::max)())) return refuse(what + " has no direction");
    return Vec3{v[0] / n, v[1] / n, v[2] / n};
}
// How far from square a frame's axes may be (the cosine between two of them).
inline constexpr double SQUARE = 1e-6;
}  // namespace detail

// ---- the library ------------------------------------------------------------------

inline std::string version() { return detail::text(::cadaclysm_blacksmith_version()); }
inline std::string build_date() { return detail::text(::cadaclysm_blacksmith_build_date()); }
inline Result<void> license(const std::string& text_or_path) {
    if (!::cadaclysm_blacksmith_license_set(text_or_path.c_str())) return detail::kernel_error("license refused");
    return {};
}
inline std::string license_info() { return detail::text(::cadaclysm_blacksmith_license_info()); }
inline std::uint64_t license_notice_count() { return ::cadaclysm_blacksmith_license_notice_count(); }
// Solid::from_node works only where this equals cadaclysm::Brep::layout_id().
inline std::string brep_layout_id() { return detail::text(::cadaclysm_blacksmith_brep_layout_id()); }

// ap203.exp: CADACLYSM_SCHEMAS/ap203.exp if set, else schemas/ap203.exp in the working
// directory or any ancestor, nearest first. No longer needed to write STEP (the kernel
// carries AP203); kept for compatibility with the other wrappers.
inline Result<std::string> default_schema() {
    namespace fs = std::filesystem;
    std::error_code ignored;
    if (auto dir = detail::env("CADACLYSM_SCHEMAS")) {
        fs::path candidate = cadaclysm::detail::fs_path(*dir) / "ap203.exp";
        if (fs::exists(candidate, ignored)) return cadaclysm::detail::utf8(candidate);
    }
    fs::path here = fs::current_path(ignored);
    for (fs::path dir = here; !dir.empty(); dir = dir.parent_path()) {
        fs::path candidate = dir / "schemas" / "ap203.exp";
        if (fs::exists(candidate, ignored)) return cadaclysm::detail::utf8(candidate);
        if (dir == dir.parent_path()) break;
    }
    return detail::refuse(
        "ap203.exp not found (none is needed to write STEP: leave schema out for the built-in AP203, "
        "or pass a schema name, a .exp path or EXPRESS text)");
}

// "#rgb" or "#rrggbb" (the # optional) as three numbers in 0..1.
inline Result<Vec3> rgb(std::string_view hex) {
    std::string h(hex);
    const char* space = " \t\r\n\f\v";
    std::size_t first = h.find_first_not_of(space);
    h = first == std::string::npos ? std::string() : h.substr(first, h.find_last_not_of(space) - first + 1);
    if (!h.empty() && h[0] == '#') h.erase(0, 1);
    bool digits = !h.empty();
    for (char c : h) digits = digits && std::isxdigit(static_cast<unsigned char>(c));
    if (digits && (h.size() == 3 || h.size() == 6)) {
        if (h.size() == 3) h = std::string{h[0], h[0], h[1], h[1], h[2], h[2]};
        Vec3 out{};
        for (int i = 0; i < 3; ++i) out[i] = std::strtol(h.substr(2 * i, 2).c_str(), nullptr, 16) / 255.0;
        return out;
    }
    return detail::refuse("coloured: a colour is \"#rgb\", \"#rrggbb\" or (r, g, b) in 0..1, not '" + std::string(hex) + "'");
}

// ---- frames and planes --------------------------------------------------------------

// An origin and three unit axes, square and right-handed (z = x x y): the plane a
// profile is drawn on (its x/y) and the direction it is built along (its z).
class Frame {
public:
    // Normalises the axes; refuses axes not square or left-handed.
    static Result<Frame> make(const Vec3& o, const Vec3& xa, const Vec3& ya, const Vec3& za) {
        for (double c : o) {
            if (!std::isfinite(c)) return detail::refuse("Frame: origin must be three finite numbers");
        }
        CADACLYSM_TRY(ux, detail::unit(xa, "Frame: x"));
        CADACLYSM_TRY(uy, detail::unit(ya, "Frame: y"));
        CADACLYSM_TRY(uz, detail::unit(za, "Frame: z"));
        double worst = (std::max)({std::fabs(detail::dot(ux, uy)), std::fabs(detail::dot(uy, uz)), std::fabs(detail::dot(uz, ux))});
        if (worst > detail::SQUARE) return detail::refuse("Frame: the axes are not square to each other");
        if (detail::dot(detail::cross(ux, uy), uz) < 0) {
            return detail::refuse("Frame: the axes are left-handed (z must be x \xc3\x97 y)");
        }
        return Frame(o, ux, uy, uz);
    }

    // Twelve numbers -- what Solid::face_frame and Workplane::frame hand back.
    static Result<Frame> of(const std::array<double, 12>& raw) {
        return make({raw[0], raw[1], raw[2]}, {raw[3], raw[4], raw[5]}, {raw[6], raw[7], raw[8]}, {raw[9], raw[10], raw[11]});
    }

    // The world XY plane through `origin`: z up. Every way to a frame refuses an origin
    // that is not three finite numbers, as make does.
    static Result<Frame> xy(const Vec3& o = {0, 0, 0}) { return placed(o, world_xy()); }
    // The world XZ plane: x along X, y along Z, so z is -Y.
    static Result<Frame> xz(const Vec3& o = {0, 0, 0}) { return placed(o, world_xz()); }
    // The world YZ plane: x along Y, y along Z, so z is +X.
    static Result<Frame> yz(const Vec3& o = {0, 0, 0}) { return placed(o, world_yz()); }

    // The plane through `origin` square to `normal`. Its x is `x` laid onto the plane;
    // with none, world X laid onto it, or world Y when the normal is within ~25 deg of X.
    static Result<Frame> at(const Vec3& o, const Vec3& normal, const std::optional<Vec3>& x_hint = std::nullopt) {
        CADACLYSM_TRY(n, detail::unit(normal, "Frame.at: normal"));
        Vec3 hint_raw = x_hint ? *x_hint : (std::fabs(n[0]) <= 0.9 ? Vec3{1, 0, 0} : Vec3{0, 1, 0});
        CADACLYSM_TRY(hint, detail::unit(hint_raw, "Frame.at: x"));
        double d = detail::dot(hint, n);
        if (std::fabs(d) > 1 - detail::SQUARE) return detail::refuse("Frame.at: x lies along the normal");
        CADACLYSM_TRY(ux, detail::unit({hint[0] - d * n[0], hint[1] - d * n[1], hint[2] - d * n[2]}, "Frame.at: x"));
        return placed(o, Frame({0, 0, 0}, ux, detail::cross(n, ux), n));
    }

    // Construction planes. The plane midway between the planes of frames a and b: for parallel planes the one halfway between, on a's axes; for
    // planes that meet, the plane bisecting them through the line they meet on, its x
    // along that line.
    static Result<Frame> midplane(const Frame& a, const Frame& b) {
        std::array<double, 12> out{};
        if (!::cadaclysm_blacksmith_frame_midplane(a.v_.data(), b.v_.data(), out.data())) {
            return detail::kernel_error("frame_midplane");
        }
        return of(out);
    }
    // The plane through three points: its origin p, its x towards q, its z the normal
    // they turn about counter-clockwise. Refused for three points on one line.
    static Result<Frame> through(const Vec3& p, const Vec3& q, const Vec3& r) {
        std::array<double, 12> out{};
        if (!::cadaclysm_blacksmith_frame_through(p.data(), q.data(), r.data(), out.data())) {
            return detail::kernel_error("frame_through");
        }
        return of(out);
    }

    Vec3 origin() const noexcept { return {v_[0], v_[1], v_[2]}; }
    Vec3 x() const noexcept { return {v_[3], v_[4], v_[5]}; }
    Vec3 y() const noexcept { return {v_[6], v_[7], v_[8]}; }
    Vec3 z() const noexcept { return {v_[9], v_[10], v_[11]}; }

    // This frame moved by (dx, dy, dz) in world coordinates.
    Result<Frame> translate(double dx, double dy, double dz) const {
        Vec3 o = origin();
        return placed({o[0] + dx, o[1] + dy, o[2] + dz}, *this);
    }
    // This frame moved `distance` along its own z.
    Result<Frame> offset(double distance) const {
        Vec3 n = z();
        return translate(distance * n[0], distance * n[1], distance * n[2]);
    }

    // The twelve numbers every call taking a frame reads.
    const std::array<double, 12>& raw() const noexcept { return v_; }

    bool operator==(const Frame& other) const noexcept { return v_ == other.v_; }
    bool operator!=(const Frame& other) const noexcept { return v_ != other.v_; }

private:
    friend class Solid;
    friend class Workplane;
    // The world planes through the origin: nothing to check.
    static Frame world_xy() { return Frame({0, 0, 0}, {1, 0, 0}, {0, 1, 0}, {0, 0, 1}); }
    static Frame world_xz() { return Frame({0, 0, 0}, {1, 0, 0}, {0, 0, 1}, {0, -1, 0}); }
    static Frame world_yz() { return Frame({0, 0, 0}, {0, 1, 0}, {0, 0, 1}, {1, 0, 0}); }
    // `axes`' axes through `o`, refused unless `o` is three finite numbers.
    static Result<Frame> placed(const Vec3& o, const Frame& axes) {
        for (double c : o) {
            if (!std::isfinite(c)) return detail::refuse("Frame: origin must be three finite numbers");
        }
        return Frame(o, axes.x(), axes.y(), axes.z());
    }
    Frame(const Vec3& o, const Vec3& xa, const Vec3& ya, const Vec3& za)
        : v_{o[0], o[1], o[2], xa[0], xa[1], xa[2], ya[0], ya[1], ya[2], za[0], za[1], za[2]} {
        for (double& c : v_) c += 0.0;  // no -0.0 to print or compare
    }
    std::array<double, 12> v_;
};

// A plane a sweep starts or ends on, read as a height over the sketch plane:
// at + grad . p. A bare number converts to a flat one, as in Python.
struct Slant {
    double at = 0.0;
    Vec2 grad{0.0, 0.0};

    Slant(double height) : at(height) {}
    Slant(double height, const Vec2& gradient) : at(height), grad(gradient) {}

    static Slant flat(double height) { return Slant(height); }

    // The plane through `point` square to `normal`, as heights over `frame`.
    static Result<Slant> of_plane(const Frame& frame, const Vec3& point, const Vec3& normal) {
        double out[3] = {};
        if (!::cadaclysm_blacksmith_slant_of_plane(frame.raw().data(), point.data(), normal.data(), out)) {
            return detail::kernel_error("slant_of_plane");
        }
        return Slant(out[0], {out[1], out[2]});
    }
};

// Which face: furthest along an axis, furthest against it, by outward normal, or by
// index. `max`/`min` are declared parenthesised so windows.h's macros cannot reach
// them; call them as (Selector::max)(Axis::z) where windows.h is included.
class Selector {
public:
    static Selector (max)(Axis axis) { return Selector(0, static_cast<std::uint32_t>(axis)); }
    static Selector (min)(Axis axis) { return Selector(1, static_cast<std::uint32_t>(axis)); }
    static Selector normal(const Vec3& direction) {
        Selector s(2, 0);
        s.v_ = direction;
        s.has_v_ = true;
        return s;
    }
    static Selector index(std::uint32_t i) { return Selector(3, i); }

private:
    friend class Solid;
    Selector(std::uint32_t kind, std::uint32_t which) : kind_(kind), index_(which) {}

    std::uint32_t kind_;
    Vec3 v_{};
    bool has_v_ = false;
    std::uint32_t index_;
};

// One edge's, or one intersection chain's, exact curve as plain data copied out
// (Edge::curve, Chain::curve): `kind` is "line", "circle", "ellipse", "parabola", "hyperbola" or "nurbs".
//
// `t0..t1` is the edge's parameter range on its own curve: a line's fraction (0..1 over
// `origin -> origin + x`, where `x` is the full `to - from`, NOT unit -- so
// `point(t) = origin + x*t`); a circle's or ellipse's angle in radians about `origin` in
// the `x, y` plane (`point(t) = origin + x*radius*cos(t) + y*radius2*sin(t)`,
// `radius2 = radius` for a circle); a NURBS's knot parameter
// (`knots[degree] <= t0 < t1 <= knots[n]`). Frame vectors `x, y, z` are unit for conics;
// for a line `x` is the direction with length = the line's length and `y, z` are zero.
//
// For a NURBS the frame is zero and so are the radii; for a conic or a line `degree` is 0
// and `knots`, `poles` are empty. `knots.size() == poles.size() + degree + 1`; `weights`
// is one per pole, or nothing for a non-rational (plain B-spline) curve, a conic or a line.
struct Curve {
    std::string kind;
    Vec3 origin{};
    Vec3 x{};
    Vec3 y{};
    Vec3 z{};
    double radius = 0.0;
    double radius2 = 0.0;
    double t0 = 0.0;
    double t1 = 0.0;
    std::uint32_t degree = 0;
    std::vector<double> knots;
    std::vector<Vec3> poles;
    std::optional<std::vector<double>> weights;
};

namespace detail {

inline Curve curve_of(const CadaclysmBlacksmithCurve& raw) {
    auto point = [](const CadaclysmBlacksmithPoint& p) { return Vec3{p.x, p.y, p.z}; };
    Curve c;
    c.kind = text(raw.kind);
    c.origin = point(raw.origin);
    c.x = point(raw.x);
    c.y = point(raw.y);
    c.z = point(raw.z);
    c.radius = raw.radius;
    c.radius2 = raw.radius2;
    c.t0 = raw.t0;
    c.t1 = raw.t1;
    c.degree = raw.degree;
    if (raw.knots && raw.knot_count) c.knots.assign(raw.knots, raw.knots + raw.knot_count);
    if (raw.poles) {
        c.poles.reserve(raw.pole_count);
        for (std::uint32_t k = 0; k < raw.pole_count; ++k) {
            const double* q = raw.poles + 3 * k;
            c.poles.push_back(Vec3{q[0], q[1], q[2]});
        }
    }
    if (raw.weights) c.weights = std::vector<double>(raw.weights, raw.weights + raw.pole_count);
    return c;
}

}  // namespace detail

// One branch of one face pair's crossing (Intersection::chains): `points` in walk order
// (a closed chain does not repeat its first point), `closed`, the faces (`face_a` in the
// first solid, `face_b` in the second), `tangent` (the surfaces near-tangent along it, or
// the snap unsettled -- the points their best estimate) and `curve`, its exact curve over
// the chain's own `t0..t1`, or nothing where the kernel found none. A chain may stop at a
// face boundary or a closed curve's seam and continue as another: join chains by matching
// ends.
struct Chain {
    std::vector<Vec3> points;
    bool closed = false;
    std::uint32_t face_a = 0;
    std::uint32_t face_b = 0;
    bool tangent = false;
    std::optional<Curve> curve;
};

// A face of the first solid and a face of the second that coincide
// (Intersection::overlaps): the faces (`face_a`, `face_b`) and `loops`, the shared
// region's rings (outer first, holes after; each ring closed without repeating its first
// point) -- empty for a partial overlap whose outlines cross.
struct Overlap {
    std::uint32_t face_a = 0;
    std::uint32_t face_b = 0;
    std::vector<std::vector<Vec3>> loops;
};

// What Solid::intersect found, copied out: `chains` (one per face pair per branch) and
// `overlaps` (one per coincident face pair). Both empty where the solids do not meet.
struct Intersection {
    std::vector<Chain> chains;
    std::vector<Overlap> overlaps;
};

namespace detail {

// `count` xyz triples at `at`, copied out as points.
inline std::vector<Vec3> points_at(const double* at, std::uint32_t count) {
    std::vector<Vec3> out;
    if (!at) return out;
    out.reserve(count);
    for (std::uint32_t k = 0; k < count; ++k) out.push_back(Vec3{at[3 * k], at[3 * k + 1], at[3 * k + 2]});
    return out;
}

inline Chain chain_of(const CadaclysmBlacksmithChain& raw, std::optional<Curve> curve) {
    Chain c;
    c.points = points_at(raw.points, raw.point_count);
    c.closed = raw.closed;
    c.face_a = raw.face_a;
    c.face_b = raw.face_b;
    c.tangent = raw.tangent;
    c.curve = std::move(curve);
    return c;
}

// Ring `r` runs from `loop_offsets[r]` to the next start, the last to `point_count`.
inline Overlap overlap_of(const CadaclysmBlacksmithOverlap& raw) {
    Overlap o;
    o.face_a = raw.face_a;
    o.face_b = raw.face_b;
    std::vector<Vec3> points = points_at(raw.points, raw.point_count);
    if (raw.loop_offsets) {
        o.loops.reserve(raw.loop_count);
        for (std::uint32_t r = 0; r < raw.loop_count; ++r) {
            std::uint32_t first = raw.loop_offsets[r];
            std::uint32_t last = r + 1 < raw.loop_count ? raw.loop_offsets[r + 1] : raw.point_count;
            o.loops.emplace_back(points.begin() + first, points.begin() + last);
        }
    }
    return o;
}

}  // namespace detail

// One edge of a solid as plain data: its index (what fillet takes), the curve kind,
// the faces meeting on it, its segments' ends, and its exact Curve (nothing for an edge
// with no exact curve, kind "other").
struct Edge {
    std::uint32_t index = 0;
    std::string kind;
    std::vector<std::uint32_t> faces;
    std::vector<std::array<Vec3, 2>> segments;
    std::optional<Curve> curve;

    bool is_line() const { return kind == "line"; }
    // The unit direction of a line edge (from its first segment); nothing otherwise.
    std::optional<Vec3> direction() const {
        if (!is_line() || segments.empty()) return std::nullopt;
        const Vec3& a = segments[0][0];
        const Vec3& b = segments[0][1];
        Vec3 d{b[0] - a[0], b[1] - a[1], b[2] - a[2]};
        double n = std::sqrt(detail::dot(d, d));
        if (!(n > 0)) return std::nullopt;
        return Vec3{d[0] / n, d[1] / n, d[2] / n};
    }
};

// Where a hit lands on one side. On a profile: `loop_index` (0 the boundary or the open
// chain, then the holes in the order they were added), `segment`, and `t` from 0 to 1
// along it, with `face` NONE. On a solid's face: `face` and its (`u`, `v`), with
// `loop_index` and `segment` NONE.
struct Spot {
    std::uint32_t loop_index = NONE;
    std::uint32_t segment = NONE;
    double t = 0.0;
    std::uint32_t face = NONE;
    double u = 0.0;
    double v = 0.0;
};

// One place two curves meet, copied out: what Profile::hits lists. A point (`run` false):
// `start` equals `end`, and `touch` is true where the curves are tangent rather than
// crossing (where a side ends there: true if the two continue each other smoothly, false
// at a corner or an end resting at an angle). A run (`run` true): the two curves coincide
// from `start` to `end`. A point at the join of two segments is reported once, on
// either: as segment k at `t` 1 or as segment k + 1 at `t` 0.
struct Hit {
    bool run = false;
    bool touch = false;
    Vec3 start{};
    Vec3 end{};
    Spot a_start;
    Spot a_end;
    Spot b_start;
    Spot b_end;
};

namespace detail {

inline Spot spot_of(const CadaclysmBlacksmithSpot& raw) {
    Spot s;
    s.loop_index = raw.loop_index;
    s.segment = raw.segment;
    s.t = raw.t;
    s.face = raw.face;
    s.u = raw.u;
    s.v = raw.v;
    return s;
}

inline Hit hit_of(const CadaclysmBlacksmithHit& raw) {
    Hit h;
    h.run = raw.run;
    h.touch = raw.touch;
    h.start = Vec3{raw.start.x, raw.start.y, raw.start.z};
    h.end = Vec3{raw.end.x, raw.end.y, raw.end.z};
    h.a_start = spot_of(raw.a_start);
    h.a_end = spot_of(raw.a_end);
    h.b_start = spot_of(raw.b_start);
    h.b_end = spot_of(raw.b_end);
    return h;
}

}  // namespace detail

// ---- profiles -------------------------------------------------------------------------

namespace detail {

// What a Profile owns. The library keeps one set of outline polylines per profile and
// replaces it whenever polylines is asked for a different tolerance; each replacement
// bumps the generation, so a view into the old one knows it is stale.
struct ProfileState {
    CadaclysmBlacksmithProfile* handle = nullptr;
    std::uint64_t generation = 0;
    std::optional<double> cache_tolerance;

    explicit ProfileState(CadaclysmBlacksmithProfile* owned) noexcept : handle(owned) {}
    bool live() const noexcept { return handle != nullptr; }
    // A call just drew the outline at `tolerance`: a new filling if it differs from the last.
    void filled(double tolerance) noexcept {
        if (!cache_tolerance || *cache_tolerance != tolerance) {
            cache_tolerance = tolerance;
            ++generation;
        }
    }
    ProfileState(const ProfileState&) = delete;
    ProfileState& operator=(const ProfileState&) = delete;
    ~ProfileState() {
        if (handle) ::cadaclysm_blacksmith_profile_free(handle);
    }
};

using ProfileRef = cadaclysm::detail::Ref<ProfileState>;

}  // namespace detail

// A profile's outline, then each hole, as polylines at z = 0, borrowed from the
// profile's cache: valid until the profile is destroyed or asked for its polylines at
// another tolerance. Row i is 3 floats a point; copy() for rows that must outlive that.
class ProfilePolylines {
public:
    std::size_t size() const { return raw().polyline_count; }
    bool empty() const { return raw().polyline_count == 0; }
    Span<const float> operator[](std::size_t i) const {
        const CadaclysmBlacksmithPolylines& r = raw();
        std::size_t first = r.offsets[i];
        std::size_t last = r.offsets[i + 1];
        return Span<const float>(r.points + 3 * first, 3 * (last - first));
    }
    std::vector<Span<const float>> rows() const {
        std::vector<Span<const float>> out;
        for (std::size_t i = 0; i < size(); ++i) out.push_back((*this)[i]);
        return out;
    }
    std::vector<std::vector<float>> copy() const {
        std::vector<std::vector<float>> out;
        for (std::size_t i = 0; i < size(); ++i) {
            Span<const float> row = (*this)[i];
            out.emplace_back(row.begin(), row.end());
        }
        return out;
    }

private:
    friend class Profile;
    ProfilePolylines(detail::ProfileRef profile, const CadaclysmBlacksmithPolylines& data)
        : profile_(std::move(profile)), raw_(data) {}
    const CadaclysmBlacksmithPolylines& raw() const {
        profile_.get("blacksmith::ProfilePolylines");
        return raw_;
    }

    detail::ProfileRef profile_;
    CadaclysmBlacksmithPolylines raw_;
};

// A closed outline with holes (or an open chain), in its own x/y. Immutable and
// move-only; every method returns a new one.
class Profile {
public:
    Profile(Profile&&) noexcept = default;
    Profile& operator=(Profile&&) noexcept = default;

    static Result<Profile> rect(double w, double h) { return wrap(::cadaclysm_blacksmith_profile_rect(w, h)); }
    static Result<Profile> circle(double r) { return wrap(::cadaclysm_blacksmith_profile_circle(r)); }
    static Result<Profile> slot(const Vec2& centre, double length, double r) {
        return wrap(::cadaclysm_blacksmith_profile_slot(centre[0], centre[1], length, r));
    }
    static Result<Profile> polygon(const std::vector<Vec2>& points) {
        std::vector<double> flat = flatten(points);
        return wrap(::cadaclysm_blacksmith_profile_polygon(flat.data(), points.size()));
    }
    static Result<Profile> regular_polygon(const Vec2& centre, double radius, std::uint32_t sides, double angle = 0.0) {
        return wrap(::cadaclysm_blacksmith_profile_regular_polygon(centre[0], centre[1], radius, sides, angle));
    }
    // A star of `points` tips on the circle of `outer` about `centre`, its inner corners on the circle
    // of `inner` (under `outer`), the first tip at `angle` radians from the sketch's x axis.
    static Result<Profile> star(const Vec2& centre, double outer, double inner, std::uint32_t points, double angle = 0.0) {
        return wrap(::cadaclysm_blacksmith_profile_star(centre[0], centre[1], outer, inner, points, angle));
    }
    // A spline of `degree` through the control polygon `points`; `weights` one a point.
    static Result<Profile> spline(const std::vector<Vec2>& points, std::uint32_t degree = 3,
                                  const std::optional<std::vector<double>>& weights = std::nullopt, bool closed = false) {
        // The library reads exactly one weight per point, whatever the vector holds.
        if (weights && weights->size() != points.size()) {
            return detail::refuse("spline: " + std::to_string(weights->size()) + " weights for " +
                                  std::to_string(points.size()) + " points; give one per point");
        }
        std::vector<double> flat = flatten(points);
        return wrap(::cadaclysm_blacksmith_profile_spline(flat.data(), points.size(), degree,
                                                          weights ? weights->data() : nullptr, closed));
    }
    // An outline drawn a segment at a time.
    static Path path(const Vec2& start);
    // Start drawing on the arc of the parabola with `vertex`, axis direction `axis` and
    // focal length `focal`, over the across-axis coordinates `from`..`to`: the path
    // begins at the arc's first point and holds the arc -- a reflector from rim to rim,
    // `Profile::parabola({0, 0}, {0, 1}, 20, -50, 50)` a dish 100 wide opening up. A
    // refusal is latched, as a step's is.
    static Path parabola(const Vec2& vertex, const Vec2& axis, double focal, double from, double to);

    // Open profiles joined end to end into one, in any order and either way round.
    static Result<Profile> chain(const Profiles& pieces, double tolerance = 1e-6) {
        std::vector<const CadaclysmBlacksmithProfile*> handles = handles_of(pieces);
        return wrap(::cadaclysm_blacksmith_profile_chain(handles.data(), handles.size(), tolerance));
    }
    // Closed loops as one profile: the loop enclosing the most area is the boundary.
    static Result<Profile> from_loops(const Profiles& loops) {
        std::vector<const CadaclysmBlacksmithProfile*> handles = handles_of(loops);
        return wrap(::cadaclysm_blacksmith_profile_from_loops(handles.data(), handles.size()));
    }

    Result<Profile> close_loop() const { return wrap(::cadaclysm_blacksmith_profile_close_loop(ptr())); }
    // This curve cut where the cutters cross, touch or run along it -- the sketch trim's
    // pieces, in order along the curve: portions of its own segments, exactly.
    Result<std::vector<Profile>> pieces(const Profiles& cutters, double tolerance = 1e-6) const {
        std::vector<const CadaclysmBlacksmithProfile*> handles = handles_of(cutters);
        std::uint32_t n = ::cadaclysm_blacksmith_profile_piece_count(ptr(), handles.data(), handles.size(), tolerance);
        if (n == 0) return detail::kernel_error("profile_piece_count");
        std::vector<Profile> out;
        out.reserve(n);
        for (std::uint32_t i = 0; i < n; ++i) {
            CADACLYSM_TRY(piece, wrap(::cadaclysm_blacksmith_profile_piece(ptr(), handles.data(), handles.size(), i, tolerance), "profile_piece"));
            out.push_back(std::move(piece));
        }
        return out;
    }
    // This curve with piece `piece` of `pieces` taken away -- the sketch trim: what is left
    // as open chains (one for a closed curve, up to two for an open one, none for the whole).
    Result<std::vector<Profile>> trim(const Profiles& cutters, std::uint32_t piece, double tolerance = 1e-6) const {
        std::vector<const CadaclysmBlacksmithProfile*> handles = handles_of(cutters);
        std::uint32_t n = ::cadaclysm_blacksmith_profile_trim_count(ptr(), handles.data(), handles.size(), piece, tolerance);
        if (n == 0 && !detail::text(::cadaclysm_blacksmith_last_error()).empty()) return detail::kernel_error("profile_trim_count");
        std::vector<Profile> out;
        out.reserve(n);
        for (std::uint32_t i = 0; i < n; ++i) {
            CADACLYSM_TRY(chain, wrap(::cadaclysm_blacksmith_profile_trim_chain(ptr(), handles.data(), handles.size(), piece, i, tolerance), "profile_trim_chain"));
            out.push_back(std::move(chain));
        }
        return out;
    }
    Result<Profile> with_hole(const Profile& hole) const {
        return wrap(::cadaclysm_blacksmith_profile_with_hole(ptr(), hole.ptr()));
    }
    Result<Profile> translate(double dx, double dy) const {
        return wrap(::cadaclysm_blacksmith_translate_profile(ptr(), dx, dy));
    }
    // This outline coloured `rgb_value` in 0..1 (rgb("#rrggbb") reads hex): how it is
    // drawn. The verbs that make a profile from one carry it; a solid made from it takes nothing.
    Result<Profile> coloured(const Vec3& rgb_value) const {
        return wrap(::cadaclysm_blacksmith_profile_coloured(ptr(), rgb_value[0], rgb_value[1], rgb_value[2]));
    }
    // The outline's colour, or nullopt.
    Result<std::optional<Vec3>> colour() const {
        Vec3 out{};
        if (::cadaclysm_blacksmith_profile_colour(ptr(), out.data())) return std::optional<Vec3>(out);
        if (!detail::text(::cadaclysm_blacksmith_last_error()).empty()) return detail::kernel_error("profile_colour");
        return std::optional<Vec3>();
    }
    // Corners between two straight segments rounded by `radius`: all of them, or the
    // boundary's `corners` (corner k is where segment k ends). `open` reads the profile
    // as an open chain whose two ends stay square.
    Result<Profile> round(double radius, const std::optional<std::vector<std::uint32_t>>& corners = std::nullopt,
                          bool as_open = false) const {
        return wrap(::cadaclysm_blacksmith_profile_round(ptr(), radius, corners ? corners->data() : nullptr,
                                                         corners ? corners->size() : 0, as_open));
    }

    // Where this profile's curves cross, touch or run along `other`'s, both read in one
    // plane, as Hits ordered along this profile. Points closer than `tolerance` merge;
    // two curves within `tolerance` of each other for longer than it, parting only where
    // one ends, are one run. A loop that stops short of its start is an open chain.
    Result<std::vector<Hit>> hits(const Profile& other, double tolerance = HIT_TOLERANCE) const {
        CadaclysmBlacksmithHits* found = ::cadaclysm_blacksmith_profile_hits(ptr(), other.ptr(), tolerance);
        if (!found) return detail::kernel_error("profile_hits");
        std::uint32_t n = ::cadaclysm_blacksmith_hit_count(found);
        std::vector<Hit> out;
        out.reserve(n);
        for (std::uint32_t i = 0; i < n; ++i) {
            CadaclysmBlacksmithHit raw{};
            if (!::cadaclysm_blacksmith_hit(found, i, &raw)) {
                ::cadaclysm_blacksmith_hits_free(found);
                return detail::kernel_error("hit");
            }
            out.push_back(detail::hit_of(raw));
        }
        ::cadaclysm_blacksmith_hits_free(found);
        return out;
    }

    // The region this profile and `other` share, both read in one plane, as zero or more
    // profiles -- each boundary counter-clockwise, each hole clockwise, arcs and splines
    // kept exact. Two loops of a result may touch at a point (two holes whose corners
    // meet, one from each input): a right point set that the verbs needing simple loops
    // -- extrude, a boolean taking it as an input -- refuse. Both must be closed and
    // simple. No shared area is an empty vector. Fails for a `tolerance` not positive and
    // finite, a profile open or crossing itself, a `tolerance` too fine for these profiles
    // (following their arcs and splines to a tenth of it would take more than 8 million
    // points, about 128 MB), and, as a defect rather than an outcome, a result that fails
    // to close.
    Result<std::vector<Profile>> common(const Profile& other, double tolerance = HIT_TOLERANCE) const {
        return list(::cadaclysm_blacksmith_profile_common(ptr(), other.ptr(), tolerance), "profile_common");
    }

    // `text` set in a font, one profile per closed shape -- a letter with its counters as
    // holes (`o` one, `8` two; `i` is two profiles) -- on the sketch plane, the baseline along
    // x from the origin, each outline counter-clockwise and its holes clockwise, a curved side
    // the font's own cubic Bezier kept exactly: an extruded `O` has curved walls. `size` is
    // roughly the height of a capital. `font` is a family, optionally with a style
    // ("Liberation Sans:style=Bold"), a font file's path, or empty for the bundled Liberation
    // Sans Regular -- which also serves when the family is not found; `font_bytes` a font
    // file's bytes, used instead of `font` when given. `halign` is "left", "center" or
    // "right"; `valign` "baseline", "bottom", "center" or "top"; `spacing` multiplies the gap
    // between glyphs; `direction` "ltr" or "rtl". Empty text is an empty vector. An error for
    // a size or spacing not positive and finite, an alignment or direction not one of those
    // words, font bytes that are not a font.
    static Result<std::vector<Profile>> text(const std::string& text, double size = 10.0, const std::string& font = "",
                                             const std::string& halign = "left", const std::string& valign = "baseline",
                                             double spacing = 1.0, const std::string& direction = "ltr",
                                             const std::optional<std::vector<std::uint8_t>>& font_bytes = std::nullopt) {
        const std::uint8_t* bytes = font_bytes ? font_bytes->data() : nullptr;
        std::size_t len = font_bytes ? font_bytes->size() : 0;
        if (font_bytes && font_bytes->empty()) {
            // An empty vector is bytes that are no font, not "no bytes": give the C side
            // something to refuse rather than a null it would read as the default.
            static const std::uint8_t none = 0;
            bytes = &none;
        }
        return list(::cadaclysm_blacksmith_profile_text(text.c_str(), size, font.c_str(), bytes, len, halign.c_str(),
                                                        valign.c_str(), spacing, direction.c_str()),
                    "profile_text");
    }

private:
    // The profiles of a list the library handed back (null: the last error). Each profile
    // is a handle of its own; the list goes on every path once read, a failed read's too
    // (the profiles read so far are destroyed with `out`).
    static Result<std::vector<Profile>> list(CadaclysmBlacksmithProfileList* list, const char* what) {
        if (!list) return detail::kernel_error(what);
        std::uint32_t n = ::cadaclysm_blacksmith_profile_list_count(list);
        std::vector<Profile> out;
        out.reserve(n);
        for (std::uint32_t i = 0; i < n; ++i) {
            Result<Profile> piece = wrap(::cadaclysm_blacksmith_profile_list_get(list, i), "profile_list_get");
            if (!piece) {
                ::cadaclysm_blacksmith_profile_list_free(list);
                return piece.error();
            }
            out.push_back(std::move(piece).value());
        }
        ::cadaclysm_blacksmith_profile_list_free(list);
        return out;
    }

public:
    // The outline, then each hole, as polylines at z = 0 within `tolerance` of its arcs
    // and splines -- what a viewer draws it with. A closed loop repeats its first point
    // at the end; an open chain (from end_open) stays open. Views into the profile's
    // cache, valid until the profile is destroyed or asked again at another tolerance.
    Result<ProfilePolylines> polylines(double tolerance = DEFAULT_TOLERANCE) const {
        CadaclysmBlacksmithPolylines data = ::cadaclysm_blacksmith_profile_polylines(ptr(), tolerance);
        if (!data.offsets) return detail::kernel_error("profile_polylines");
        state_->filled(tolerance);
        return ProfilePolylines(detail::ProfileRef(state_), data);
    }

    // The C handle, for code that calls the C ABI directly. Owned by this Profile.
    const CadaclysmBlacksmithProfile* handle() const noexcept { return state_ ? state_->handle : nullptr; }

    // This profile's own loops as SVG text, from directly above by default -- a sketch
    // lies in z = 0, so its own plane already is the page, unlike a solid's Solid::svg_text
    // (SvgView::iso), which has no plane of its own to prefer. Passing `options` at all --
    // even one left at its own defaults -- opts out of the top default and uses its `view`
    // as given, the same way a caller of SvgOptions controls a solid's. Defined below
    // write_svg_text, which it calls with no solids. See write_svg_text.
    Result<std::string> svg_text(const SvgOptions& options = SvgOptions{SvgView::top}) const;
    // svg_text() written to `path` by the library itself; see svg_text for the top default.
    Result<void> svg(const std::string& path, const SvgOptions& options = SvgOptions{SvgView::top}) const;

private:
    friend class Path;
    friend class SweepPath;
    friend class Solid;

    explicit Profile(CadaclysmBlacksmithProfile* raw) : state_(std::make_shared<detail::ProfileState>(raw)) {}

    static Result<Profile> wrap(CadaclysmBlacksmithProfile* raw, const char* what = "profile") {
        if (!raw) return detail::kernel_error(what);
        return Profile(raw);
    }
    static std::vector<double> flatten(const std::vector<Vec2>& points) {
        std::vector<double> flat;
        flat.reserve(points.size() * 2);
        for (const Vec2& p : points) {
            flat.push_back(p[0]);
            flat.push_back(p[1]);
        }
        return flat;
    }
    static std::vector<const CadaclysmBlacksmithProfile*> handles_of(const Profiles& profiles) {
        std::vector<const CadaclysmBlacksmithProfile*> out;
        out.reserve(profiles.size());
        for (const Profile& p : profiles) out.push_back(p.ptr());
        return out;
    }
    const CadaclysmBlacksmithProfile* ptr() const {
        if (!state_) cadaclysm::detail::bad_access("Profile", "the profile is empty (moved from)");
        return state_->handle;
    }

    // Shared only so ProfilePolylines can see it go: a Profile is still move-only.
    std::shared_ptr<detail::ProfileState> state_;
};

// An outline drawn a segment at a time. The first refused step is kept and the
// rest skipped; end() or end_open() reports it. Consumed by end()/end_open().
class Path {
public:
    explicit Path(const Vec2& start) : ptr_(::cadaclysm_blacksmith_path_begin(start[0], start[1])) {
        if (!ptr_) error_ = detail::kernel_error("path_begin");
    }
    Path(Path&&) noexcept = default;
    Path& operator=(Path&&) noexcept = default;

    Path& line_to(double x, double y) & {
        step("path_line_to", [&](CadaclysmBlacksmithPath* p) { return ::cadaclysm_blacksmith_path_line_to(p, x, y); });
        return *this;
    }
    Path&& line_to(double x, double y) && { return std::move(line_to(x, y)); }

    Path& arc_to(double x, double y, const Vec2& centre, bool ccw = true) & {
        step("path_arc_to", [&](CadaclysmBlacksmithPath* p) {
            return ::cadaclysm_blacksmith_path_arc_to(p, x, y, centre[0], centre[1], ccw);
        });
        return *this;
    }
    Path&& arc_to(double x, double y, const Vec2& centre, bool ccw = true) && {
        return std::move(arc_to(x, y, centre, ccw));
    }

    Path& bezier_to(const Vec2& c1, const Vec2& c2, const Vec2& to) & {
        step("path_bezier_to", [&](CadaclysmBlacksmithPath* p) {
            return ::cadaclysm_blacksmith_path_bezier_to(p, c1[0], c1[1], c2[0], c2[1], to[0], to[1]);
        });
        return *this;
    }
    Path&& bezier_to(const Vec2& c1, const Vec2& c2, const Vec2& to) && { return std::move(bezier_to(c1, c2, to)); }

    // A conic arc to `to` through the control point `control` with middle weight
    // `weight`: under 1 an elliptical arc, 1 a parabola, over 1 a hyperbola -- the
    // rational quadratic Bezier, kept exact.
    Path& conic_to(const Vec2& to, const Vec2& control, double weight) & {
        step("path_conic_to", [&](CadaclysmBlacksmithPath* p) {
            return ::cadaclysm_blacksmith_path_conic_to(p, to[0], to[1], control[0], control[1], weight);
        });
        return *this;
    }
    Path&& conic_to(const Vec2& to, const Vec2& control, double weight) && {
        return std::move(conic_to(to, control, weight));
    }

    // A parabolic arc to `to` whose end tangents meet at `control`: conic_to with weight 1.
    Path& parabola_to(const Vec2& to, const Vec2& control) & { return conic_to(to, control, 1.0); }
    Path&& parabola_to(const Vec2& to, const Vec2& control) && { return std::move(parabola_to(to, control)); }

    // A hyperbolic arc to `to` through `control` with middle `weight` over 1.
    Path& hyperbola_to(const Vec2& to, const Vec2& control, double weight) & {
        // Checked here, latched like a refused step (after any earlier one, which wins).
        if (!error_ && ptr_ && !(weight > 1.0)) {
            error_ = detail::refuse("hyperbola_to: the weight must be over 1 (1 is a parabola, under 1 an ellipse)");
            return *this;
        }
        return conic_to(to, control, weight);
    }
    Path&& hyperbola_to(const Vec2& to, const Vec2& control, double weight) && {
        return std::move(hyperbola_to(to, control, weight));
    }

    // The parabolic arc to `to` with `vertex`: its axis and focal length solved from the
    // two ends. Refused when no parabola with that vertex passes through both.
    Path& parabola_by_vertex(const Vec2& to, const Vec2& vertex) & {
        step("path_parabola_by_vertex", [&](CadaclysmBlacksmithPath* p) {
            return ::cadaclysm_blacksmith_path_parabola_by_vertex(p, to[0], to[1], vertex[0], vertex[1]);
        });
        return *this;
    }
    Path&& parabola_by_vertex(const Vec2& to, const Vec2& vertex) && { return std::move(parabola_by_vertex(to, vertex)); }

    // The parabolic arc to `to` with `focus`: of the two through the ends, the one whose
    // vertex lies between the ends' projections, then the one whose arc cups the focus
    // (the focus between the arc and its chord), then the more symmetric; with the focus
    // beyond the chord that is the arch over the ends, not the shallow dish -- draw that
    // one with `Profile::parabola`.
    Path& parabola_by_focus(const Vec2& to, const Vec2& focus) & {
        step("path_parabola_by_focus", [&](CadaclysmBlacksmithPath* p) {
            return ::cadaclysm_blacksmith_path_parabola_by_focus(p, to[0], to[1], focus[0], focus[1]);
        });
        return *this;
    }
    Path&& parabola_by_focus(const Vec2& to, const Vec2& focus) && { return std::move(parabola_by_focus(to, focus)); }

    // `control`: every control point after the current one, the endpoint last;
    // `weights`: one per control point including the current one; `knots`: the full
    // repeated knot vector.
    Path& nurbs_to(const std::vector<Vec2>& control, const std::vector<double>& knots, std::uint32_t degree,
                   const std::optional<std::vector<double>>& weights = std::nullopt) & {
        // The library reads one weight per control point plus the current point's: a
        // wrong count is latched like a refused step (after any earlier one, which wins).
        if (!error_ && ptr_ && weights && weights->size() != control.size() + 1) {
            error_ = detail::refuse("nurbs_to: " + std::to_string(weights->size()) + " weights for " +
                                    std::to_string(control.size() + 1) + " control points (the current point and " +
                                    std::to_string(control.size()) + " given); give one per point");
            return *this;
        }
        std::vector<double> flat = Profile::flatten(control);
        step("path_nurbs_to", [&](CadaclysmBlacksmithPath* p) {
            return ::cadaclysm_blacksmith_path_nurbs_to(p, flat.data(), control.size(), weights ? weights->data() : nullptr,
                                                        knots.data(), knots.size(), degree);
        });
        return *this;
    }
    Path&& nurbs_to(const std::vector<Vec2>& control, const std::vector<double>& knots, std::uint32_t degree,
                    const std::optional<std::vector<double>>& weights = std::nullopt) && {
        return std::move(nurbs_to(control, knots, degree, weights));
    }

    // The error a step latched, or null.
    const Error* err() const noexcept { return error_ ? &*error_ : nullptr; }

    // Close the outline into a profile. Consumes the path, whether or not it succeeds.
    Result<Profile> end() {
        return finish([](CadaclysmBlacksmithPath* p) { return ::cadaclysm_blacksmith_path_end(p); }, "path_end");
    }
    // The path as it stands, open: for extrude_open, sweep_open, loft_open, chain.
    Result<Profile> end_open() {
        return finish([](CadaclysmBlacksmithPath* p) { return ::cadaclysm_blacksmith_path_end_open(p); }, "path_end_open");
    }

private:
    friend class Profile;

    struct Free {
        void operator()(CadaclysmBlacksmithPath* p) const noexcept { ::cadaclysm_blacksmith_path_free(p); }
    };

    // Wraps the handle another entry point (`path_parabola`) returned, latching its refusal.
    Path(CadaclysmBlacksmithPath* raw, const char* what) : ptr_(raw) {
        if (!ptr_) error_ = detail::kernel_error(what);
    }

    template <class Call>
    void step(const char* what, Call&& call) {
        if (error_) return;
        if (!ptr_) {
            error_ = detail::refuse("path: already ended");
            return;
        }
        if (!call(ptr_.get())) error_ = detail::kernel_error(what);
    }

    template <class End>
    Result<Profile> finish(End end, const char* what) {
        if (error_) return *error_;
        if (!ptr_) return detail::refuse("path: already ended");
        CadaclysmBlacksmithPath* raw = ptr_.release();  // the C call takes it over
        return Profile::wrap(end(raw), what);
    }

    std::unique_ptr<CadaclysmBlacksmithPath, Free> ptr_;
    std::optional<Error> error_;
};

inline Path Profile::path(const Vec2& start) { return Path(start); }
inline Path Profile::parabola(const Vec2& vertex, const Vec2& axis, double focal, double from, double to) {
    return Path(::cadaclysm_blacksmith_path_parabola(vertex[0], vertex[1], axis[0], axis[1], focal, from, to), "path_parabola");
}

// A 3D path a profile is carried along -- lines and arcs -- for Solid::sweep and
// Solid::pipe, which only borrow it. Latches its first refused step, like Path.
class SweepPath {
public:
    SweepPath(SweepPath&&) noexcept = default;
    SweepPath& operator=(SweepPath&&) noexcept = default;

    static SweepPath at(const Vec3& point) {
        SweepPath s(::cadaclysm_blacksmith_sweep_path_begin(point[0], point[1], point[2]));
        if (!s.ptr_) s.error_ = detail::kernel_error("sweep_path_begin");
        return s;
    }

    // The path the 2D chain `curve` draws on `frame`, splines fitted with biarcs to
    // within `tolerance`. `open` false closes it back to its start.
    static SweepPath along(const Profile& curve, const Frame& frame, double tolerance = DEFAULT_TOLERANCE,
                           bool leave_open = true) {
        SweepPath s(::cadaclysm_blacksmith_sweep_path_along(curve.ptr(), frame.raw().data(), tolerance, leave_open));
        if (!s.ptr_) s.error_ = detail::kernel_error("sweep_path_along");
        return s;
    }

    SweepPath& line_to(const Vec3& point) & {
        step("sweep_path_line_to", [&](CadaclysmBlacksmithSweepPath* p) {
            return ::cadaclysm_blacksmith_sweep_path_line_to(p, point[0], point[1], point[2]);
        });
        return *this;
    }
    SweepPath&& line_to(const Vec3& point) && { return std::move(line_to(point)); }

    // Turn `angle` radians (0, 2 pi] about the axis through `centre` along `axis`.
    SweepPath& arc(const Vec3& centre, const Vec3& axis, double angle) & {
        step("sweep_path_arc", [&](CadaclysmBlacksmithSweepPath* p) {
            return ::cadaclysm_blacksmith_sweep_path_arc(p, centre[0], centre[1], centre[2], axis[0], axis[1], axis[2], angle);
        });
        return *this;
    }
    SweepPath&& arc(const Vec3& centre, const Vec3& axis, double angle) && { return std::move(arc(centre, axis, angle)); }

    const Error* err() const noexcept { return error_ ? &*error_ : nullptr; }

    // Free it now rather than at destruction.
    void close() noexcept { ptr_.reset(); }

private:
    friend class Solid;
    struct Free {
        void operator()(CadaclysmBlacksmithSweepPath* p) const noexcept { ::cadaclysm_blacksmith_sweep_path_free(p); }
    };
    explicit SweepPath(CadaclysmBlacksmithSweepPath* data) : ptr_(data) {}

    template <class Call>
    void step(const char* what, Call&& call) {
        if (error_) return;
        if (!ptr_) {
            error_ = detail::refuse("sweep_path: closed");
            return;
        }
        if (!call(ptr_.get())) error_ = detail::kernel_error(what);
    }

    // The handle for a sweep, or the reason there is none.
    Result<const CadaclysmBlacksmithSweepPath*> live() const {
        if (error_) return *error_;
        if (!ptr_) return detail::refuse("sweep_path: closed");
        return static_cast<const CadaclysmBlacksmithSweepPath*>(ptr_.get());
    }

    std::unique_ptr<CadaclysmBlacksmithSweepPath, Free> ptr_;
    std::optional<Error> error_;
};

// One stretch of a profile loop between two cuts (SolidHits::pieces): `inside` (by its
// middle's winding number over the body; a piece lying on the surface is inside),
// `start`/`end` (profile spots -- a segment join reads as the next segment's start
// (k + 1, 0), an open chain runs from (0, 0) to (n - 1, 1); a loop no hit cuts is one
// closed piece) and `profile`, the piece's own open chain (what SweepPath::along with
// `open` sweeps).
struct Piece {
    bool inside = false;
    Spot start;
    Spot end;
    Profile profile;
};

// What Solid::hits found, copied out: `hits` (ordered along the profile; `a_start`/`a_end`
// on the profile, `b_start`/`b_end` on the solid's faces: a `face` at (`u`, `v`)) and
// `pieces` (empty for an open body).
struct SolidHits {
    std::vector<Hit> hits;
    std::vector<Piece> pieces;
};

// ---- solids -------------------------------------------------------------------------

namespace detail {

// What a Solid owns. The library keeps one tessellation per solid and replaces it
// whenever mesh, edge_polylines or bounds_at is asked for a different tolerance; each
// replacement bumps the generation, so a view into the old one knows it is stale.
struct SolidState {
    CadaclysmBlacksmithSolid* handle = nullptr;
    std::uint64_t generation = 0;
    std::optional<double> cache_tolerance;

    bool live() const noexcept { return handle != nullptr; }
    void close() noexcept {
        if (handle) {
            ::cadaclysm_blacksmith_solid_free(handle);
            handle = nullptr;
            ++generation;
        }
    }
    // A call just tessellated at `tolerance`: a new filling if it differs from the last.
    void filled(double tolerance) noexcept {
        if (!cache_tolerance || *cache_tolerance != tolerance) {
            cache_tolerance = tolerance;
            ++generation;
        }
    }
    SolidState() = default;
    SolidState(const SolidState&) = delete;
    SolidState& operator=(const SolidState&) = delete;
    ~SolidState() { close(); }
};

using SolidRef = cadaclysm::detail::Ref<SolidState>;

inline void slant_raw(const Slant& slant, double (&out)[3]) {
    out[0] = slant.at;
    out[1] = slant.grad[0];
    out[2] = slant.grad[1];
}

inline void axis_raw(const AxisLine& axis, double (&out)[6]) {
    for (int i = 0; i < 3; ++i) {
        out[i] = axis[0][i];
        out[3 + i] = axis[1][i];
    }
}

}  // namespace detail

// A solid's triangles, borrowed from its tessellation cache: valid until the solid is
// closed or meshed at another tolerance. copy() for arrays that must outlive that.
class Mesh {
public:
    Span<const float> positions() const {
        const CadaclysmBlacksmithMesh& r = raw();
        return r.positions ? Span<const float>(r.positions, static_cast<std::size_t>(r.vertex_count) * 3) : Span<const float>();
    }
    Span<const float> normals() const {
        const CadaclysmBlacksmithMesh& r = raw();
        return r.normals ? Span<const float>(r.normals, static_cast<std::size_t>(r.vertex_count) * 3) : Span<const float>();
    }
    Span<const std::uint32_t> indices() const {
        const CadaclysmBlacksmithMesh& r = raw();
        return r.indices ? Span<const std::uint32_t>(r.indices, r.index_count) : Span<const std::uint32_t>();
    }
    std::uint32_t vertex_count() const { return raw().vertex_count; }
    std::uint32_t index_count() const { return raw().index_count; }
    std::uint32_t triangle_count() const { return raw().index_count / 3; }
    bool empty() const { return raw().index_count == 0; }

    MeshData copy() const {
        MeshData out;
        Span<const float> p = positions();
        Span<const float> n = normals();
        Span<const std::uint32_t> i = indices();
        out.positions.assign(p.begin(), p.end());
        out.normals.assign(n.begin(), n.end());
        out.indices.assign(i.begin(), i.end());
        return out;
    }

private:
    friend class Solid;
    Mesh(detail::SolidRef solid, const CadaclysmBlacksmithMesh& data) : solid_(std::move(solid)), raw_(data) {}
    const CadaclysmBlacksmithMesh& raw() const {
        solid_.get("blacksmith::Mesh");
        return raw_;
    }

    detail::SolidRef solid_;
    CadaclysmBlacksmithMesh raw_;
};

// Mesh in `double`, from the same tessellation cache -- the same triangles and
// indices, Mesh's `float` positions and normals being exactly these narrowed. Borrowed
// like Mesh, under the same rule: valid until the solid is closed or meshed again at a
// different tolerance (checked the same way Mesh is, through the solid's generation).
class Mesh64 {
public:
    Span<const double> positions() const {
        const CadaclysmBlacksmithMesh64& r = raw();
        return r.positions ? Span<const double>(r.positions, static_cast<std::size_t>(r.vertex_count) * 3) : Span<const double>();
    }
    Span<const double> normals() const {
        const CadaclysmBlacksmithMesh64& r = raw();
        return r.normals ? Span<const double>(r.normals, static_cast<std::size_t>(r.vertex_count) * 3) : Span<const double>();
    }
    Span<const std::uint32_t> indices() const {
        const CadaclysmBlacksmithMesh64& r = raw();
        return r.indices ? Span<const std::uint32_t>(r.indices, r.index_count) : Span<const std::uint32_t>();
    }
    std::uint32_t vertex_count() const { return raw().vertex_count; }
    std::uint32_t index_count() const { return raw().index_count; }
    std::uint32_t triangle_count() const { return raw().index_count / 3; }
    bool empty() const { return raw().index_count == 0; }

    MeshData64 copy() const {
        MeshData64 out;
        Span<const double> p = positions();
        Span<const double> n = normals();
        Span<const std::uint32_t> i = indices();
        out.positions.assign(p.begin(), p.end());
        out.normals.assign(n.begin(), n.end());
        out.indices.assign(i.begin(), i.end());
        return out;
    }

private:
    friend class Solid;
    Mesh64(detail::SolidRef solid, const CadaclysmBlacksmithMesh64& data) : solid_(std::move(solid)), raw_(data) {}
    const CadaclysmBlacksmithMesh64& raw() const {
        solid_.get("blacksmith::Mesh64");
        return raw_;
    }

    detail::SolidRef solid_;
    CadaclysmBlacksmithMesh64 raw_;
};

// A solid's feature edges as polylines, borrowed like Mesh: row i is 3 floats a point.
class EdgePolylines {
public:
    std::size_t size() const { return raw().polyline_count; }
    bool empty() const { return raw().polyline_count == 0; }
    Span<const float> operator[](std::size_t i) const {
        const CadaclysmBlacksmithPolylines& r = raw();
        std::size_t first = r.offsets[i];
        std::size_t last = r.offsets[i + 1];
        return Span<const float>(r.points + 3 * first, 3 * (last - first));
    }
    std::vector<Span<const float>> rows() const {
        std::vector<Span<const float>> out;
        for (std::size_t i = 0; i < size(); ++i) out.push_back((*this)[i]);
        return out;
    }
    std::vector<std::vector<float>> copy() const {
        std::vector<std::vector<float>> out;
        for (std::size_t i = 0; i < size(); ++i) {
            Span<const float> row = (*this)[i];
            out.emplace_back(row.begin(), row.end());
        }
        return out;
    }

private:
    friend class Solid;
    EdgePolylines(detail::SolidRef solid, const CadaclysmBlacksmithPolylines& data) : solid_(std::move(solid)), raw_(data) {}
    const CadaclysmBlacksmithPolylines& raw() const {
        solid_.get("blacksmith::EdgePolylines");
        return raw_;
    }

    detail::SolidRef solid_;
    CadaclysmBlacksmithPolylines raw_;
};

// How many triangles each face contributed to the mesh at the same tolerance, one count
// per face in face order: the mesh's triangles run face by face, so face f's are the
// counts[f] after the first sum(counts[0..f]), and the counts sum to the mesh's
// triangle count. Borrowed like Mesh.
class FaceTriangles {
public:
    Span<const std::uint32_t> counts() const {
        const CadaclysmBlacksmithFaceTriangles& r = raw();
        return r.counts ? Span<const std::uint32_t>(r.counts, r.face_count) : Span<const std::uint32_t>();
    }
    std::size_t size() const { return raw().face_count; }
    bool empty() const { return raw().face_count == 0; }
    std::uint32_t operator[](std::size_t f) const { return raw().counts[f]; }

    std::vector<std::uint32_t> copy() const {
        Span<const std::uint32_t> c = counts();
        return std::vector<std::uint32_t>(c.begin(), c.end());
    }

private:
    friend class Solid;
    FaceTriangles(detail::SolidRef solid, const CadaclysmBlacksmithFaceTriangles& data) : solid_(std::move(solid)), raw_(data) {}
    const CadaclysmBlacksmithFaceTriangles& raw() const {
        solid_.get("blacksmith::FaceTriangles");
        return raw_;
    }

    detail::SolidRef solid_;
    CadaclysmBlacksmithFaceTriangles raw_;
};

inline Result<std::string> write_step_text(const Solids& solids, const std::optional<std::string>& schema, Unit unit);
inline Result<std::string> write_sat_text(const Solids& solids, Unit unit);
inline Result<void> write_sat(const std::string& path, const Solids& solids, Unit unit);
inline Result<std::string> write_brep_text(const Solids& solids);
inline Result<void> write_brep(const std::string& path, const Solids& solids);
inline Result<std::string> write_svg_text(const Solids& solids, const SvgOptions& options);
inline Result<void> write_svg(const std::string& path, const Solids& solids, const SvgOptions& options);
// The drawing pair widens write_svg_text/write_svg to profiles as well as solids: a
// `<g id="solid-N">` per solid then a `<g id="profile-N">` per profile, on one page.
// Either list may be empty; both empty is refused. Every refusal is worded exactly as
// the solids-only pair's always has, so a solids-only drawing through this overload
// (an empty Profiles) reads the same text either pair would give. The overloads above
// still call the solids-only pair directly rather than delegating to these, though --
// see their own comments for why.
inline Result<std::string> write_svg_text(const Solids& solids, const Profiles& profiles, const SvgOptions& options);
inline Result<void> write_svg(const std::string& path, const Solids& solids, const Profiles& profiles,
                              const SvgOptions& options);

// An exact B-rep solid (or open sheet). Immutable and move-only: every operation
// returns a new one. Freed when destroyed or on close(); a call on a closed or
// moved-from solid is a bad access.
class Solid {
public:
    Solid(Solid&&) noexcept = default;
    Solid& operator=(Solid&&) noexcept = default;
    Solid(const Solid&) = delete;
    Solid& operator=(const Solid&) = delete;

    void close() noexcept {
        if (state_) state_->close();
    }
    bool closed() const noexcept { return !state_ || !state_->live(); }

    // -- primitives
    static Result<Solid> cuboid(double x, double y, double z) { return wrap(::cadaclysm_blacksmith_cuboid(x, y, z)); }
    static Result<Solid> cylinder(double r, double h) { return wrap(::cadaclysm_blacksmith_cylinder(r, h)); }
    static Result<Solid> cone(double r, double h) { return wrap(::cadaclysm_blacksmith_cone(r, h)); }
    static Result<Solid> sphere(double r) { return wrap(::cadaclysm_blacksmith_sphere(r)); }
    static Result<Solid> torus(double major, double minor) { return wrap(::cadaclysm_blacksmith_torus(major, minor)); }
    static Result<Solid> wedge(double x, double y, double z, double top_x) {
        return wrap(::cadaclysm_blacksmith_wedge(x, y, z, top_x));
    }

    // -- from profiles
    static Result<Solid> extrude(const Profile& profile, const Frame& frame, double height) {
        return wrap(::cadaclysm_blacksmith_extrude(profile.ptr(), frame.raw().data(), height));
    }
    static Result<Solid> extrude_open(const Profile& profile, const Frame& frame, double height) {
        return wrap(::cadaclysm_blacksmith_extrude_open(profile.ptr(), frame.raw().data(), height));
    }
    static Result<Solid> extrude_tapered(const Profile& profile, const Frame& frame, double height, double taper) {
        return wrap(::cadaclysm_blacksmith_extrude_tapered(profile.ptr(), frame.raw().data(), height, taper));
    }
    static Result<Solid> extrude_open_tapered(const Profile& profile, const Frame& frame, double height, double taper) {
        return wrap(::cadaclysm_blacksmith_extrude_open_tapered(profile.ptr(), frame.raw().data(), height, taper));
    }
    // Between two planes rather than two heights; a number is a flat plane at that height.
    static Result<Solid> extrude_between(const Profile& profile, const Frame& frame, const Slant& bottom, const Slant& top) {
        double b[3], t[3];
        detail::slant_raw(bottom, b);
        detail::slant_raw(top, t);
        return wrap(::cadaclysm_blacksmith_extrude_between(profile.ptr(), frame.raw().data(), b, t));
    }
    static Result<Solid> extrude_open_between(const Profile& profile, const Frame& frame, const Slant& bottom,
                                              const Slant& top) {
        double b[3], t[3];
        detail::slant_raw(bottom, b);
        detail::slant_raw(top, t);
        return wrap(::cadaclysm_blacksmith_extrude_open_between(profile.ptr(), frame.raw().data(), b, t));
    }
    static Result<Solid> loft(const Profile& a, const Frame& frame_a, const Profile& b, const Frame& frame_b) {
        return wrap(::cadaclysm_blacksmith_loft(a.ptr(), frame_a.raw().data(), b.ptr(), frame_b.raw().data()));
    }
    static Result<Solid> loft_open(const Profile& a, const Frame& frame_a, const Profile& b, const Frame& frame_b) {
        return wrap(::cadaclysm_blacksmith_loft_open(a.ptr(), frame_a.raw().data(), b.ptr(), frame_b.raw().data()));
    }
    // The solid smooth through every section -- a profile on its frame, in order: each
    // wall interpolates its side across all the profiles (cubic through four or more,
    // quadratic through three, loft through two), capped by the first and the last. The
    // profiles must have the same number of sides and no holes.
    static Result<Solid> loft_through(const Sections& sections) { return lofted_through(sections, true); }
    // loft_through without the caps: the sheet through the curves.
    static Result<Solid> loft_through_open(const Sections& sections) { return lofted_through(sections, false); }
    static Result<Solid> revolve(const Profile& profile, const AxisLine& axis, double angle) {
        double raw_axis[6];
        detail::axis_raw(axis, raw_axis);
        return wrap(::cadaclysm_blacksmith_revolve(profile.ptr(), raw_axis, angle));
    }
    static Result<Solid> revolve_open(const Profile& profile, const AxisLine& axis, double angle) {
        double raw_axis[6];
        detail::axis_raw(axis, raw_axis);
        return wrap(::cadaclysm_blacksmith_revolve_open(profile.ptr(), raw_axis, angle));
    }
    // About the axis from `a` to `b` in the profile's own plane.
    static Result<Solid> revolve_in_plane(const Profile& profile, const Frame& frame, const Vec2& a, const Vec2& b,
                                          double angle) {
        double raw_axis[4] = {a[0], a[1], b[0], b[1]};
        return wrap(::cadaclysm_blacksmith_revolve_in_plane(profile.ptr(), frame.raw().data(), raw_axis, angle));
    }
    static Result<Solid> revolve_open_in_plane(const Profile& profile, const Frame& frame, const Vec2& a, const Vec2& b,
                                               double angle) {
        double raw_axis[4] = {a[0], a[1], b[0], b[1]};
        return wrap(::cadaclysm_blacksmith_revolve_open_in_plane(profile.ptr(), frame.raw().data(), raw_axis, angle));
    }
    // `path` is borrowed, not consumed: sweep it again as often as needed.
    static Result<Solid> sweep(const Profile& profile, const Frame& frame, const SweepPath& path) {
        CADACLYSM_TRY(p, path.live());
        return wrap(::cadaclysm_blacksmith_sweep(profile.ptr(), frame.raw().data(), p));
    }
    static Result<Solid> sweep_open(const Profile& profile, const Frame& frame, const SweepPath& path) {
        CADACLYSM_TRY(p, path.live());
        return wrap(::cadaclysm_blacksmith_sweep_open(profile.ptr(), frame.raw().data(), p));
    }
    static Result<Solid> coil(const Profile& profile, const AxisLine& axis, double pitch, double turns) {
        double raw_axis[6];
        detail::axis_raw(axis, raw_axis);
        return wrap(::cadaclysm_blacksmith_coil(profile.ptr(), raw_axis, pitch, turns));
    }
    static Result<Solid> pipe(const SweepPath& path, double radius, double thickness = 0.0) {
        CADACLYSM_TRY(p, path.live());
        return wrap(::cadaclysm_blacksmith_pipe(p, radius, thickness));
    }
    // The flat sheet `profile` bounds on `frame`: one planar face.
    static Result<Solid> face(const Profile& profile, const Frame& frame) {
        return wrap(::cadaclysm_blacksmith_face(profile.ptr(), frame.raw().data()));
    }

    // -- from files
    // The body `node` draws, sharing the reader's brep (not copying it); the scene can
    // close first. `placed` moves it where the node's transform draws it (the scene must
    // then be open NATIVE unless that transform is the identity).
    static Result<Solid> from_node(const cadaclysm::Node& node, bool placed = true);
    // The body a CAD file holds (STEP, ACIS, Rhino, OCCT .brep, IGES, IFC); a file
    // drawing several needs `body` (0-based, in drawing order) or open_all.
    static Result<Solid> open(const std::string& path, std::optional<std::size_t> body = std::nullopt);
    // Every body a CAD file draws, one per placement.
    static Result<std::vector<Solid>> open_all(const std::string& path);
    // This solid as a reader Scene, through STEP in memory -- the door to the tree walk.
    Result<cadaclysm::Scene> to_scene(const std::optional<std::string>& schema = std::nullopt) const;

    // -- face surgery and moves
    Result<Solid> face_sheet(std::uint32_t f) const { return wrap(::cadaclysm_blacksmith_face_sheet(raw_handle("face_sheet"), f)); }
    Result<Solid> drop_faces(const std::vector<std::uint32_t>& which) const {
        return wrap(::cadaclysm_blacksmith_drop_faces(raw_handle("drop_faces"), which.data(), which.size()));
    }
    Result<Solid> extrude_faces(double height) const {
        return wrap(::cadaclysm_blacksmith_extrude_faces(raw_handle("extrude_faces"), height));
    }
    Result<Solid> place(const Frame& frame) const { return place_raw(frame.raw().data()); }
    Result<Solid> translate(double dx, double dy, double dz) const {
        return wrap(::cadaclysm_blacksmith_translate(raw_handle("translate"), dx, dy, dz));
    }
    Result<Solid> rotate(const AxisLine& axis, double radians) const {
        double raw_axis[6];
        detail::axis_raw(axis, raw_axis);
        return wrap(::cadaclysm_blacksmith_rotate(raw_handle("rotate"), raw_axis, radians));
    }
    Result<Solid> mirror(const Frame& plane) const {
        return wrap(::cadaclysm_blacksmith_mirror(raw_handle("mirror"), plane.raw().data()));
    }

    // -- combining. `merge` merges the flush faces a join leaves (merge_flush).
    Result<Solid> join(const Solid& other, double tolerance = DEFAULT_TOLERANCE, const Progress& progress = {},
                       bool merge = false) const {
        return merged(wrap(::cadaclysm_blacksmith_join(raw_handle("join"), other.raw_handle("join"), tolerance,
                                                       detail::progress_fn(progress), detail::progress_user(progress))),
                      merge);
    }
    Result<Solid> cut(const Solid& other, double tolerance = DEFAULT_TOLERANCE, const Progress& progress = {},
                      bool merge = false) const {
        return merged(wrap(::cadaclysm_blacksmith_cut(raw_handle("cut"), other.raw_handle("cut"), tolerance,
                                                      detail::progress_fn(progress), detail::progress_user(progress))),
                      merge);
    }
    Result<Solid> common(const Solid& other, double tolerance = DEFAULT_TOLERANCE, const Progress& progress = {},
                         bool merge = false) const {
        return merged(wrap(::cadaclysm_blacksmith_common(raw_handle("common"), other.raw_handle("common"), tolerance,
                                                         detail::progress_fn(progress), detail::progress_user(progress))),
                      merge);
    }
    // Cut along the closed `tool`'s boundary, keeping one side.
    Result<Solid> trim(const Solid& tool, Keep keep = Keep::outside, double tolerance = DEFAULT_TOLERANCE,
                       const Progress& progress = {}) const {
        return wrap(::cadaclysm_blacksmith_trim(raw_handle("trim"), tool.raw_handle("trim"), keep == Keep::inside, tolerance,
                                                detail::progress_fn(progress), detail::progress_user(progress)));
    }
    // Cut along `tool`'s boundary, nothing removed: each face's outside pieces, then inside.
    Result<Solid> split_sheet(const Solid& tool, double tolerance = DEFAULT_TOLERANCE, const Progress& progress = {}) const {
        return wrap(::cadaclysm_blacksmith_split_sheet(raw_handle("split_sheet"), tool.raw_handle("split_sheet"), tolerance,
                                                       detail::progress_fn(progress), detail::progress_user(progress)));
    }

    // Where this solid's faces cross or coincide with `other`'s, at `tolerance`, as an
    // Intersection: `chains` along the curves the faces meet on and `overlaps` where a
    // face pair coincides. Neither solid is changed; either may be an open sheet. No
    // crossing is an empty result, never an error.
    //
    // Each Chain's points are within `tolerance` of both faces' exact surfaces; there is
    // one chain per face pair per branch -- chains are not joined across a face boundary
    // or a closed curve's seam, so join them by matching ends. A chain's `curve` is its
    // exact curve where the kernel found one every point lies within `tolerance` of, else
    // nothing; `tangent` is set where the surfaces are near-tangent along the chain or the
    // snap did not settle (the points are then the best estimate) -- a closed chain that
    // does not go once round its own curve (a sliver where two surfaces barely cross) has
    // no curve, `tangent` still true. An Overlap is a coincident face pair with the shared
    // region's rings (outer first, holes after), which may be empty for a partial overlap
    // whose outlines cross. Known limit: a crossing narrower than `tolerance` -- two
    // surfaces passing within it without their meshes crossing -- can be missed;
    // near-tangent contact is where this bites.
    //
    // `progress(phase, done, total)` hears "mesh", "cull", "cross", "snap" and "curve".
    // Fails for a `tolerance` not positive and finite, a solid with no faces, or one that
    // meshes to nothing.
    Result<Intersection> intersect(const Solid& other, double tolerance = DEFAULT_TOLERANCE, const Progress& progress = {}) const {
        CadaclysmBlacksmithIntersection* found =
            ::cadaclysm_blacksmith_intersect(raw_handle("intersect"), other.raw_handle("intersect"), tolerance,
                                             detail::progress_fn(progress), detail::progress_user(progress));
        if (!found) return detail::kernel_error("intersect");
        struct Free {
            CadaclysmBlacksmithIntersection* p;
            ~Free() { ::cadaclysm_blacksmith_intersection_free(p); }
        } release{found};
        Intersection out;
        std::uint32_t n = ::cadaclysm_blacksmith_intersection_chain_count(found);
        out.chains.reserve(n);
        for (std::uint32_t i = 0; i < n; ++i) {
            CadaclysmBlacksmithChain raw{};
            if (!::cadaclysm_blacksmith_intersection_chain(found, i, &raw)) return detail::kernel_error("intersection_chain");
            std::optional<Curve> curve;
            if (raw.has_curve) {
                CadaclysmBlacksmithCurve raw_curve{};
                if (!::cadaclysm_blacksmith_intersection_curve(found, i, &raw_curve)) return detail::kernel_error("intersection_curve");
                curve = detail::curve_of(raw_curve);
            }
            out.chains.push_back(detail::chain_of(raw, std::move(curve)));
        }
        n = ::cadaclysm_blacksmith_intersection_overlap_count(found);
        out.overlaps.reserve(n);
        for (std::uint32_t i = 0; i < n; ++i) {
            CadaclysmBlacksmithOverlap raw{};
            if (!::cadaclysm_blacksmith_intersection_overlap(found, i, &raw)) return detail::kernel_error("intersection_overlap");
            out.overlaps.push_back(detail::overlap_of(raw));
        }
        return out;
    }

    // Where `profile`, placed on `frame`, pierces this solid's faces, and the pieces its
    // loops cut into, as a SolidHits. Neither is changed.
    //
    // A point hit lies within `tolerance` of the segment's exact curve and of the face's
    // exact surface, inside the face's trim; its profile spot (`a_start`: loop, segment, t)
    // and face spot (`b_start`: face, u, v) evaluate to the point within `tolerance`;
    // `touch` where the curve's tangent lies within 1e-3 (sine) of the surface's tangent
    // plane there (a graze), false at a crossing. A run is a stretch of one segment lying
    // within `tolerance` of one face and inside it, longer than `tolerance`. Hits within
    // `tolerance` of each other merge (a hit at a segment join reported once, as
    // (k, t = 1); a closed loop's closing join reads (0, 0)). Every point is in world
    // space (the frame applied).
    //
    // Pieces only for a closed body -- an open body has none -- in loop order, covering
    // every loop exactly; a piece's spots read a segment join as the next segment's start
    // (k + 1, 0), and an open chain runs from (0, 0) to (n - 1, 1); a loop no hit cuts is
    // one closed piece. `inside` by the piece middle's winding number over the body's mesh;
    // a piece lying on the surface is inside. Known limit: a segment passing within
    // `tolerance` of a face without crossing its mesh can be missed (near-tangent grazes).
    //
    // `progress` hears "mesh", "cull", "hits" and "pieces". An error for a `tolerance` not
    // positive and finite, a solid with no faces or that meshes to nothing, a profile with
    // no segments, or a free-form segment that is not an evaluable NURBS curve.
    Result<SolidHits> hits(const Profile& profile, const Frame& frame, double tolerance = DEFAULT_TOLERANCE,
                           const Progress& progress = {}) const {
        CadaclysmBlacksmithHits* found =
            ::cadaclysm_blacksmith_solid_profile_hits(raw_handle("hits"), profile.ptr(), frame.raw().data(), tolerance,
                                                      detail::progress_fn(progress), detail::progress_user(progress));
        if (!found) return detail::kernel_error("solid_profile_hits");
        struct Free {
            CadaclysmBlacksmithHits* p;
            ~Free() { ::cadaclysm_blacksmith_hits_free(p); }
        } release{found};
        SolidHits out;
        std::uint32_t n = ::cadaclysm_blacksmith_hit_count(found);
        out.hits.reserve(n);
        for (std::uint32_t i = 0; i < n; ++i) {
            CadaclysmBlacksmithHit raw{};
            if (!::cadaclysm_blacksmith_hit(found, i, &raw)) return detail::kernel_error("hit");
            out.hits.push_back(detail::hit_of(raw));
        }
        n = ::cadaclysm_blacksmith_hits_piece_count(found);
        out.pieces.reserve(n);
        for (std::uint32_t i = 0; i < n; ++i) {
            bool inside = false;
            CadaclysmBlacksmithSpot start{}, end{};
            if (!::cadaclysm_blacksmith_hits_piece(found, i, &inside, &start, &end)) return detail::kernel_error("hits_piece");
            Result<Profile> own = Profile::wrap(::cadaclysm_blacksmith_hits_piece_profile(found, i), "hits_piece_profile");
            if (!own) return own.error();
            out.pieces.push_back(Piece{inside, detail::spot_of(start), detail::spot_of(end), std::move(own).value()});
        }
        return out;
    }

    // -- asking
    std::uint32_t faces() const { return ::cadaclysm_blacksmith_face_count(raw_handle("faces")); }
    Result<std::string> face_kind(std::uint32_t f) const {
        const char* kind = ::cadaclysm_blacksmith_face_kind(raw_handle("face_kind"), f);
        if (!kind) return detail::kernel_error("face_kind");
        return std::string(kind);
    }
    // bounds_at(DEFAULT_TOLERANCE).
    Result<std::pair<Vec3, Vec3>> bounds() const { return bounds_at(DEFAULT_TOLERANCE); }
    // Axis-aligned (min, max) over the cached tessellation at `tolerance`.
    Result<std::pair<Vec3, Vec3>> bounds_at(double tolerance) const {
        Vec3 lo{}, hi{};
        if (!::cadaclysm_blacksmith_bounds(raw_handle("bounds"), tolerance, lo.data(), hi.data())) {
            return detail::kernel_error("bounds");
        }
        state_->filled(tolerance);
        return std::make_pair(lo, hi);
    }
    // bounds_at(tolerance), taken from the tessellation cache's own unnarrowed
    // `double` positions rather than bounds_at's widened `float` ones: exact far from
    // the origin.
    Result<std::pair<Vec3, Vec3>> bounds64(double tolerance = DEFAULT_TOLERANCE) const {
        Vec3 lo{}, hi{};
        if (!::cadaclysm_blacksmith_bounds64(raw_handle("bounds64"), tolerance, lo.data(), hi.data())) {
            return detail::kernel_error("bounds64");
        }
        state_->filled(tolerance);
        return std::make_pair(lo, hi);
    }
    // Edges of a mesh at `tolerance` not bound by exactly two triangles; 0 when closed.
    Result<std::uint32_t> leaked_edges(double tolerance = DEFAULT_TOLERANCE) const {
        std::uint32_t n = ::cadaclysm_blacksmith_leaked_edges(raw_handle("leaked_edges"), tolerance);
        if (n == NONE) return detail::kernel_error("leaked_edges");
        return n;
    }
    // Edges whose triangle uses do not cancel out; 0 when closed and consistently oriented.
    Result<std::uint32_t> unpaired_edges(double tolerance = DEFAULT_TOLERANCE) const {
        std::uint32_t n = ::cadaclysm_blacksmith_unpaired_edges(raw_handle("unpaired_edges"), tolerance);
        if (n == NONE) return detail::kernel_error("unpaired_edges");
        return n;
    }
    Result<bool> is_watertight(double tolerance = DEFAULT_TOLERANCE) const {
        return leaked_edges(tolerance).map([](std::uint32_t n) { return n == 0; });
    }
    Result<Manifold> manifold() const {
        std::uint32_t row[8] = {};
        if (!::cadaclysm_blacksmith_manifold(raw_handle("manifold"), row)) return detail::kernel_error("manifold");
        return cadaclysm::detail::manifold_of(row);
    }

    // -- out
    Result<Mesh> mesh(double tolerance = DEFAULT_TOLERANCE) const {
        CadaclysmBlacksmithMesh data = ::cadaclysm_blacksmith_mesh(raw_handle("mesh"), tolerance);
        if (!data.positions) return detail::kernel_error("mesh");
        state_->filled(tolerance);
        return Mesh(detail::SolidRef(state_), data);
    }
    // mesh(tolerance), from the same cache, unnarrowed: the same triangles and
    // indices, mesh()'s `float` positions and normals being exactly these narrowed.
    Result<Mesh64> mesh64(double tolerance = DEFAULT_TOLERANCE) const {
        CadaclysmBlacksmithMesh64 data = ::cadaclysm_blacksmith_mesh64(raw_handle("mesh64"), tolerance);
        if (!data.positions) return detail::kernel_error("mesh64");
        state_->filled(tolerance);
        return Mesh64(detail::SolidRef(state_), data);
    }
    Result<EdgePolylines> edge_polylines(double tolerance = DEFAULT_TOLERANCE) const {
        CadaclysmBlacksmithPolylines data = ::cadaclysm_blacksmith_edge_polylines(raw_handle("edge_polylines"), tolerance);
        if (!data.offsets) return detail::kernel_error("edge_polylines");
        state_->filled(tolerance);
        return EdgePolylines(detail::SolidRef(state_), data);
    }
    // A colour per polyline of edge_polylines() at the same tolerance, as drawn: nullopt
    // for a polyline on no coloured edge; empty where the solid has no edge paint at all.
    // Copied out.
    Result<std::vector<std::optional<Vec3>>> edge_polyline_colours(double tolerance = DEFAULT_TOLERANCE) const {
        CadaclysmBlacksmithColours data = ::cadaclysm_blacksmith_edge_polyline_colours(raw_handle("edge_polyline_colours"), tolerance);
        if (!data.rgb && !detail::text(::cadaclysm_blacksmith_last_error()).empty()) return detail::kernel_error("edge_polyline_colours");
        // This call tessellates like every other cache reader, even to report "no paint": it
        // can replace the cache a view taken earlier is still borrowing, so it must bump the
        // generation those views check, even though this method copies its own result out and
        // keeps nothing borrowed itself.
        state_->filled(tolerance);
        std::vector<std::optional<Vec3>> out;
        if (!data.rgb) return out;
        out.reserve(data.count);
        for (std::uint32_t i = 0; i < data.count; ++i) {
            const double* c = data.rgb + 3 * i;
            if (c[0] < 0) out.emplace_back(std::nullopt); else out.emplace_back(Vec3{c[0], c[1], c[2]});
        }
        return out;
    }
    // How many triangles each face meshed to at `tolerance`, one count per face in face
    // order; what a viewer colours a face by. Same cache and lifetime as mesh().
    Result<FaceTriangles> face_triangles(double tolerance = DEFAULT_TOLERANCE) const {
        CadaclysmBlacksmithFaceTriangles data = ::cadaclysm_blacksmith_mesh_face_triangles(raw_handle("face_triangles"), tolerance);
        if (!data.counts) return detail::kernel_error("mesh_face_triangles");
        state_->filled(tolerance);
        return FaceTriangles(detail::SolidRef(state_), data);
    }
    // `schema`: none (the built-in AP203), a schema file's path, a built-in schema's
    // name, or a custom schema's EXPRESS text.
    Result<std::string> step_text(const std::optional<std::string>& schema = std::nullopt,
                                  Unit unit = Unit::millimetre) const {
        return write_step_text({*this}, schema, unit);
    }
    Result<void> step(const std::string& path, const std::optional<std::string>& schema = std::nullopt,
                      Unit unit = Unit::millimetre) const;
    // This solid as ACIS SAT text: the analytic surfaces as their own records, splines
    // and swept surfaces as exact NURBS, in the layout Rhino's own exporter writes.
    Result<std::string> sat_text(Unit unit = Unit::millimetre) const { return write_sat_text({*this}, unit); }
    // This solid written to a SAT file at `path`, by the library itself.
    Result<void> sat(const std::string& path, Unit unit = Unit::millimetre) const;
    // This solid as OCCT `.brep` text: the exact surfaces and curves, with a curve in
    // each face's own parameters for every edge, so OCCT's `BRepTools::Read` gives a
    // shape `BRepCheck_Analyzer` finds valid. No unit is declared -- a `.brep`
    // carries none -- so the numbers are the numbers.
    Result<std::string> brep_text() const { return write_brep_text({*this}); }
    // This solid written to a `.brep` file at `path`, by the library itself.
    Result<void> brep(const std::string& path) const;
    // This solid's own wireframe as SVG text, from the camera `options` describes --
    // the library's own camera, not a viewer. See SvgOptions.
    Result<std::string> svg_text(const SvgOptions& options = SvgOptions()) const { return write_svg_text({*this}, options); }
    // svg_text() written to `path` by the library itself.
    Result<void> svg(const std::string& path, const SvgOptions& options = SvgOptions()) const;

    // -- selecting and edges
    Result<std::uint32_t> select_face(const Selector& selector) const {
        std::uint32_t i = ::cadaclysm_blacksmith_select_face(raw_handle("select_face"), selector.kind_,
                                                             selector.has_v_ ? selector.v_.data() : nullptr, selector.index_);
        if (i == NONE) return detail::kernel_error("select_face");
        return i;
    }
    // The face's frame: its origin, world X laid onto it, and its outward normal.
    Result<Frame> face_frame(std::uint32_t f) const {
        std::array<double, 12> out{};
        if (!::cadaclysm_blacksmith_face_frame(raw_handle("face_frame"), f, out.data())) {
            return detail::kernel_error("face_frame");
        }
        return Frame({out[0], out[1], out[2]}, {out[3], out[4], out[5]}, {out[6], out[7], out[8]}, {out[9], out[10], out[11]});
    }
    // Face f by what it is, eight doubles: the surface's kind (plane 0, cylinder 1, cone 2,
    // sphere 3, torus 4, NURBS 5, revolution 6, extrusion 7, sum 8), a point on the surface at
    // the face's middle (x y z), the outward normal there (x y z), and the face's extent --
    // what a feature made on the face keeps, to find the face again with find_face when the
    // solid has been rebuilt with its faces moved, split or renumbered. Take it before any
    // move you apply to the solid, and look it up on the unmoved one.
    Result<std::array<double, 8>> face_ref(std::uint32_t f) const {
        std::array<double, 8> out{};
        if (!::cadaclysm_blacksmith_face_ref(raw_handle("face_ref"), f, out.data())) {
            return detail::kernel_error("face_ref");
        }
        return out;
    }
    // The face ref (from face_ref) refers to: among the faces of that kind whose surface
    // passes through the point, facing the same way, the one the point lies in -- or, where it
    // lies in none, the one whose boundary comes nearest. hint is the index the face had,
    // preferred among faces that fit equally well; tolerance how far the point may sit off a
    // surface to still be on it. nullopt where the face is gone.
    Result<std::optional<std::uint32_t>> find_face(const std::array<double, 8>& ref, std::optional<std::uint32_t> hint = std::nullopt, double tolerance = 1e-3) const {
        const std::int32_t h = hint && *hint <= static_cast<std::uint32_t>(std::numeric_limits<std::int32_t>::max()) ? static_cast<std::int32_t>(*hint) : -1;
        const std::int32_t found = ::cadaclysm_blacksmith_find_face(raw_handle("find_face"), ref.data(), h, tolerance);
        if (found == -2) return detail::kernel_error("find_face");
        if (found < 0) return std::optional<std::uint32_t>{};
        return std::optional<std::uint32_t>{static_cast<std::uint32_t>(found)};
    }
    Result<std::vector<Edge>> edges() const {
        const CadaclysmBlacksmithSolid* s = raw_handle("edges");
        std::uint32_t n = ::cadaclysm_blacksmith_edge_count(s);
        if (n == 0 && !detail::text(::cadaclysm_blacksmith_last_error()).empty()) return detail::kernel_error("edge_count");
        std::vector<Edge> out;
        out.reserve(n);
        for (std::uint32_t i = 0; i < n; ++i) {
            CadaclysmBlacksmithEdge data{};
            if (!::cadaclysm_blacksmith_edge(s, i, &data)) return detail::kernel_error("edge");
            Edge e;
            e.index = i;
            e.kind = detail::text(data.kind);
            e.faces.assign(data.faces, data.faces + data.face_count);
            for (std::uint32_t k = 0; k < data.segment_count; ++k) {
                const double* q = data.segments + 6 * k;
                e.segments.push_back({Vec3{q[0], q[1], q[2]}, Vec3{q[3], q[4], q[5]}});
            }
            // The exact curve: nothing for an edge with none (the library's "has no
            // exact curve"); any other refusal is the error.
            CadaclysmBlacksmithCurve curve{};
            if (::cadaclysm_blacksmith_edge_curve(s, i, &curve)) {
                e.curve = detail::curve_of(curve);
            } else if (detail::text(::cadaclysm_blacksmith_last_error()).find("has no exact curve") == std::string::npos) {
                return detail::kernel_error("edge_curve");
            }
            out.push_back(std::move(e));
        }
        return out;
    }

    // -- colour
    // This solid painted `rgb` (0..1), or with `f` just that face, which then wins.
    Result<Solid> coloured(const Vec3& rgb_value, std::optional<std::uint32_t> f = std::nullopt) const {
        CADACLYSM_TRY(which, face_or_none(f, "coloured"));
        return wrap(::cadaclysm_blacksmith_coloured(raw_handle("coloured"), which, rgb_value[0], rgb_value[1], rgb_value[2]));
    }
    Result<std::optional<Vec3>> colour() const { return colour_of(NONE); }
    Result<std::optional<Vec3>> face_colour(std::uint32_t f) const {
        CADACLYSM_TRY(which, face_or_none(f, "colour"));
        return colour_of(which);
    }
    // This solid with its edges coloured `rgb_value`: every edge, or with `edge_indices`
    // just those (as fillet takes them), whose colour then wins over the all-edges one; an
    // empty vector colours none. Inherited as face colours are.
    Result<Solid> edges_coloured(const Vec3& rgb_value, std::optional<std::vector<std::uint32_t>> edge_indices = std::nullopt) const {
        if (!edge_indices) return wrap(::cadaclysm_blacksmith_edges_coloured(raw_handle("edges_coloured"), nullptr, 0, rgb_value[0], rgb_value[1], rgb_value[2]));
        // An empty vector's data() may be null: a non-null pointer with count 0 colours none.
        static const std::uint32_t none = 0;
        const std::uint32_t* list = edge_indices->empty() ? &none : edge_indices->data();
        return wrap(::cadaclysm_blacksmith_edges_coloured(raw_handle("edges_coloured"), list, edge_indices->size(), rgb_value[0], rgb_value[1], rgb_value[2]));
    }
    // Edge `e`'s colour as drawn -- its own, else the solid's edge colour -- or nullopt.
    Result<std::optional<Vec3>> edge_colour(std::uint32_t e) const {
        Vec3 out{};
        if (::cadaclysm_blacksmith_edge_colour(raw_handle("edge_colour"), e, out.data())) return std::optional<Vec3>(out);
        if (!detail::text(::cadaclysm_blacksmith_last_error()).empty()) return detail::kernel_error("edge_colour");
        return std::optional<Vec3>();
    }

    // -- editing
    Result<Solid> fillet(const std::vector<std::uint32_t>& edge_indices, double radius, double tolerance = FILLET_TOLERANCE,
                         const Progress& progress = {}) const {
        return wrap(::cadaclysm_blacksmith_fillet(raw_handle("fillet"), edge_indices.data(), edge_indices.size(), radius,
                                                  tolerance, detail::progress_fn(progress), detail::progress_user(progress)));
    }
    Result<Solid> chamfer(const std::vector<std::uint32_t>& edge_indices, double distance,
                          double tolerance = FILLET_TOLERANCE) const {
        return wrap(::cadaclysm_blacksmith_chamfer(raw_handle("chamfer"), edge_indices.data(), edge_indices.size(), distance,
                                                   tolerance));
    }
    // A face moved `distance` along its normal, as a face extrude does it.
    Result<Solid> push_pull(std::uint32_t f, double distance, double tolerance = DEFAULT_TOLERANCE,
                            const Progress& progress = {}) const {
        return wrap(::cadaclysm_blacksmith_push_pull(raw_handle("push_pull"), f, distance, tolerance,
                                                     detail::progress_fn(progress), detail::progress_user(progress)));
    }
    // Several faces pushed together, as a press-pull on a selection: each by its
    // own rule, one after another, each found again after the pushes before it
    // renumbered the faces. A box's top and a side pushed 5 is the box 5 taller and 5
    // wider; a face on the same curved surface as one before it, and joined to it, moved
    // with that one and is not pushed twice.
    Result<Solid> push_pull(const std::vector<std::uint32_t>& which, double distance, double tolerance = DEFAULT_TOLERANCE,
                            const Progress& progress = {}) const {
        return wrap(::cadaclysm_blacksmith_push_pull_faces(raw_handle("push_pull"), which.data(), which.size(), distance,
                                                           tolerance, detail::progress_fn(progress),
                                                           detail::progress_user(progress)));
    }
    // A braced list, including `{}`, goes the vector way: an empty braced list is
    // otherwise an identity conversion to the scalar overload's std::uint32_t, which
    // would push face 0 instead of reaching the kernel's own refusal of no faces.
    Result<Solid> push_pull(std::initializer_list<std::uint32_t> which, double distance,
                            double tolerance = DEFAULT_TOLERANCE, const Progress& progress = {}) const {
        return push_pull(std::vector<std::uint32_t>(which), distance, tolerance, progress);
    }
    // The bodies `tool` cuts this into: outside it first, then inside.
    Result<std::vector<Solid>> split(const Solid& tool, double tolerance = DEFAULT_TOLERANCE,
                                     const Progress& progress = {}) const {
        CADACLYSM_TRY(whole, wrap(::cadaclysm_blacksmith_split(raw_handle("split"), tool.raw_handle("split"), tolerance,
                                                               detail::progress_fn(progress), detail::progress_user(progress))));
        return whole.lumps();
    }
    // The bodies on either side of `plane`: those on its z side first.
    Result<std::vector<Solid>> split_by_plane(const Frame& plane, double tolerance = DEFAULT_TOLERANCE,
                                              const Progress& progress = {}) const {
        CADACLYSM_TRY(whole, wrap(::cadaclysm_blacksmith_split_by_plane(raw_handle("split_by_plane"), plane.raw().data(),
                                                                        tolerance, detail::progress_fn(progress),
                                                                        detail::progress_user(progress))));
        return whole.lumps();
    }
    // Each connected body on its own, in the order of their first faces.
    Result<std::vector<Solid>> lumps() const {
        const CadaclysmBlacksmithSolid* s = raw_handle("lumps");
        std::uint32_t n = ::cadaclysm_blacksmith_lump_count(s);
        if (n == 0) return detail::kernel_error("lump_count");
        std::vector<Solid> out;
        out.reserve(n);
        for (std::uint32_t i = 0; i < n; ++i) {
            CADACLYSM_TRY(lump, wrap(::cadaclysm_blacksmith_lump(s, i), "lump"));
            out.push_back(std::move(lump));
        }
        return out;
    }
    // The round a fillet face belongs to, made again at `radius`.
    Result<Solid> refillet(std::uint32_t f, double radius, double tolerance = FILLET_TOLERANCE) const {
        return wrap(::cadaclysm_blacksmith_refillet(raw_handle("refillet"), f, radius, tolerance));
    }
    // The round a fillet face belongs to, taken back to its sharp edges.
    Result<Solid> unfillet(std::uint32_t f) const { return wrap(::cadaclysm_blacksmith_unfillet(raw_handle("unfillet"), f)); }
    // The chamfer a face belongs to, cut again at `distance`.
    Result<Solid> rechamfer(std::uint32_t f, double distance, double tolerance = FILLET_TOLERANCE) const {
        return wrap(::cadaclysm_blacksmith_rechamfer(raw_handle("rechamfer"), f, distance, tolerance));
    }
    // The chamfer a face belongs to, taken back to its sharp edges.
    Result<Solid> unchamfer(std::uint32_t f) const {
        return wrap(::cadaclysm_blacksmith_unchamfer(raw_handle("unchamfer"), f));
    }
    Result<Solid> merge_flush() const { return wrap(::cadaclysm_blacksmith_merge_flush(raw_handle("merge_flush"))); }
    // Hollowed to walls `thickness` thick, the faces in `open_faces` left open.
    Result<Solid> shell(double thickness, const std::vector<std::uint32_t>& open_faces = {},
                        double tolerance = FILLET_TOLERANCE, const Progress& progress = {}) const {
        return wrap(::cadaclysm_blacksmith_shell(raw_handle("shell"), thickness, open_faces.data(), open_faces.size(),
                                                 tolerance, detail::progress_fn(progress), detail::progress_user(progress)));
    }
    // This sheet made a solid `thickness` thick: its faces, their twins moved `thickness`
    // along the faces' normals, and a wall round every open edge. A closed sheet thickens
    // to a hollow.
    Result<Solid> thicken(double thickness, double tolerance = FILLET_TOLERANCE, const Progress& progress = {}) const {
        return wrap(::cadaclysm_blacksmith_thicken(raw_handle("thicken"), thickness, tolerance,
                                                    detail::progress_fn(progress), detail::progress_user(progress)));
    }

    // The C handle, for code that calls the C ABI directly. Owned by this Solid.
    const CadaclysmBlacksmithSolid* handle() const noexcept { return state_ ? state_->handle : nullptr; }

private:
    friend class Workplane;
    friend Result<std::string> write_step_text(const Solids&, const std::optional<std::string>&, Unit);
    friend Result<std::string> write_sat_text(const Solids&, Unit);
    friend Result<void> write_sat(const std::string&, const Solids&, Unit);
    friend Result<std::string> write_brep_text(const Solids&);
    friend Result<void> write_brep(const std::string&, const Solids&);
    friend Result<std::string> write_svg_text(const Solids&, const SvgOptions&);
    friend Result<void> write_svg(const std::string&, const Solids&, const SvgOptions&);
    friend Result<std::string> write_svg_text(const Solids&, const Profiles&, const SvgOptions&);
    friend Result<void> write_svg(const std::string&, const Solids&, const Profiles&, const SvgOptions&);

    explicit Solid(std::shared_ptr<detail::SolidState> owned) : state_(std::move(owned)) {}

    static Result<Solid> wrap(CadaclysmBlacksmithSolid* data, const char* what = "solid") {
        if (!data) return detail::kernel_error(what);
        auto owned = std::make_shared<detail::SolidState>();
        owned->handle = data;
        return Solid(std::move(owned));
    }

    static Result<Solid> lofted_through(const Sections& sections, bool capped) {
        // Every profile checked before anything with a destructor is held, so a bad
        // access unwinds nothing.
        for (const Section& s : sections) (void)s.first.get().ptr();
        std::vector<const CadaclysmBlacksmithProfile*> handles;
        std::vector<double> frames12;
        handles.reserve(sections.size());
        frames12.reserve(sections.size() * 12);
        for (const Section& s : sections) {
            handles.push_back(s.first.get().handle());
            const std::array<double, 12>& v = s.second.get().raw();
            frames12.insert(frames12.end(), v.begin(), v.end());
        }
        if (capped) {
            return wrap(::cadaclysm_blacksmith_loft_through(handles.data(), frames12.data(), handles.size()), "loft_through");
        }
        return wrap(::cadaclysm_blacksmith_loft_through_open(handles.data(), frames12.data(), handles.size()),
                    "loft_through_open");
    }

    static Result<Solid> merged(Result<Solid> made, bool merge) {
        if (!merge || !made) return made;
        return made->merge_flush();
    }

    // A move by twelve numbers, unchecked: a placement's mirror is a left-handed frame,
    // which Frame::make refuses and the kernel takes.
    Result<Solid> place_raw(const double* frame12) const {
        return wrap(::cadaclysm_blacksmith_place(raw_handle("place"), frame12));
    }

    // Each returns its Result<Solid> as made, never by moving a Solid out of an optional
    // or a Result: GCC -O2 reports -Wmaybe-uninitialized on such a move, in every
    // translation unit calling from_node.
    static Result<Solid> share(const cadaclysm::Brep& brep);
    static Result<Solid> share_placed(const cadaclysm::Brep& brep, const Matrix4& m, const std::string& what);

    Result<std::uint32_t> face_or_none(std::optional<std::uint32_t> f, const char* what) const {
        if (!f) return NONE;
        if (*f == NONE) {
            return detail::refuse(std::string(what) + ": face " + std::to_string(*f) + " is not one of the solid's " +
                                  std::to_string(faces()));
        }
        return *f;
    }

    Result<std::optional<Vec3>> colour_of(std::uint32_t f) const {
        Vec3 out{};
        if (::cadaclysm_blacksmith_colour(raw_handle("colour"), f, out.data())) return std::optional<Vec3>(out);
        if (!detail::text(::cadaclysm_blacksmith_last_error()).empty()) return detail::kernel_error("colour");
        return std::optional<Vec3>();
    }

    const CadaclysmBlacksmithSolid* raw_handle(const char* what) const {
        if (!state_) cadaclysm::detail::bad_access(what, "the solid is empty (moved from)");
        if (!state_->live()) cadaclysm::detail::bad_access(what, "the solid is closed");
        return state_->handle;
    }

    std::shared_ptr<detail::SolidState> state_;
};

// One STEP text, each solid its own body.
inline Result<std::string> write_step_text(const Solids& solids, const std::optional<std::string>& schema = std::nullopt,
                                           Unit unit = Unit::millimetre) {
    std::vector<const CadaclysmBlacksmithSolid*> handles;
    handles.reserve(solids.size());
    for (const Solid& s : solids) handles.push_back(s.raw_handle("write_step_text"));
    // A schema is a file's path (no newline, names a regular file), else sent as it is:
    // a built-in schema's name or EXPRESS text.
    std::optional<std::string> schema_text;
    if (schema) {
        std::error_code ignored;
        std::filesystem::path as_path = schema->find('\n') == std::string::npos ? cadaclysm::detail::fs_path(*schema)
                                                                                : std::filesystem::path();
        if (!as_path.empty() && std::filesystem::is_regular_file(as_path, ignored)) {
            std::ifstream in(as_path, std::ios::binary);
            schema_text = std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
        } else {
            schema_text = *schema;
        }
    }
    char* text = ::cadaclysm_blacksmith_step(handles.data(), handles.size(), schema_text ? schema_text->c_str() : nullptr,
                                             static_cast<std::uint32_t>(unit));
    if (!text) return detail::kernel_error("step");
    std::string out(text);
    ::cadaclysm_blacksmith_string_free(text);
    return out;
}

// One STEP file, each solid its own body.
inline Result<void> write_step(const std::string& path, const Solids& solids,
                               const std::optional<std::string>& schema = std::nullopt, Unit unit = Unit::millimetre) {
    CADACLYSM_TRY(text, write_step_text(solids, schema, unit));
    std::ofstream out(cadaclysm::detail::fs_path(path), std::ios::binary);
    if (!out) return detail::refuse("step: cannot write " + path);
    out.write(text.data(), static_cast<std::streamsize>(text.size()));
    if (!out) return detail::refuse("step: cannot write " + path);
    return {};
}

inline Result<void> Solid::step(const std::string& path, const std::optional<std::string>& schema, Unit unit) const {
    return write_step(path, {*this}, schema, unit);
}

// One ACIS SAT text, each solid its own body. `unit` goes into the header as
// millimetres per unit.
inline Result<std::string> write_sat_text(const Solids& solids, Unit unit) {
    std::vector<const CadaclysmBlacksmithSolid*> handles;
    handles.reserve(solids.size());
    for (const Solid& s : solids) handles.push_back(s.raw_handle("write_sat_text"));
    char* text = ::cadaclysm_blacksmith_sat_text(handles.data(), handles.size(), static_cast<std::uint32_t>(unit));
    if (!text) return detail::kernel_error("sat_text");
    std::string out(text);
    ::cadaclysm_blacksmith_string_free(text);
    return out;
}

// `write_sat_text` written to `path` by the library itself, which names the file in
// its refusal when it cannot.
inline Result<void> write_sat(const std::string& path, const Solids& solids, Unit unit) {
    std::vector<const CadaclysmBlacksmithSolid*> handles;
    handles.reserve(solids.size());
    for (const Solid& s : solids) handles.push_back(s.raw_handle("write_sat"));
    if (!::cadaclysm_blacksmith_sat(handles.data(), handles.size(), path.c_str(), static_cast<std::uint32_t>(unit))) {
        return detail::kernel_error("sat");
    }
    return {};
}

inline Result<void> Solid::sat(const std::string& path, Unit unit) const { return write_sat(path, {*this}, unit); }

// One OCCT `.brep` text, each solid its own solid under one compound (one solid is
// the file's root).
inline Result<std::string> write_brep_text(const Solids& solids) {
    std::vector<const CadaclysmBlacksmithSolid*> handles;
    handles.reserve(solids.size());
    for (const Solid& s : solids) handles.push_back(s.raw_handle("write_brep_text"));
    char* text = ::cadaclysm_blacksmith_brep_text(handles.data(), handles.size());
    if (!text) return detail::kernel_error("brep_text");
    std::string out(text);
    ::cadaclysm_blacksmith_string_free(text);
    return out;
}

// Several solids' and profiles' wireframes as one SVG, from the camera `options`
// describes. Owned by the library: decoded and released before this returns.
inline Result<std::string> write_svg_text(const Solids& solids, const Profiles& profiles, const SvgOptions& options) {
    std::vector<const CadaclysmBlacksmithSolid*> solid_handles;
    solid_handles.reserve(solids.size());
    for (const Solid& s : solids) solid_handles.push_back(s.raw_handle("write_svg_text"));
    std::vector<const CadaclysmBlacksmithProfile*> profile_handles;
    profile_handles.reserve(profiles.size());
    for (const Profile& p : profiles) profile_handles.push_back(p.handle());
    CadaclysmBlacksmithSvgOptions raw = detail::build_svg_options(options);
    char* text = ::cadaclysm_blacksmith_drawing_svg_text(solid_handles.data(), solid_handles.size(),
                                                          profile_handles.data(), profile_handles.size(), &raw);
    if (!text) return detail::kernel_error("svg_text");
    std::string out(text);
    ::cadaclysm_blacksmith_string_free(text);
    return out;
}

// Several solids' wireframes as one SVG, from the camera `options` describes. Owned
// by the library: decoded and released before this returns. Kept calling the
// solids-only pair rather than delegating to the overload above with an empty
// Profiles: this file's own coverage test (`tests/bindings.rs`) reads an entry
// point as declared only where it is actually called `::`-qualified, so `svg_text`
// must keep a real call of its own here, not just a mention -- unlike Python and
// Node, which declare every entry point in a string table independent of whether
// it is still called. The two pairs refuse in identical words either way.
inline Result<std::string> write_svg_text(const Solids& solids, const SvgOptions& options) {
    std::vector<const CadaclysmBlacksmithSolid*> handles;
    handles.reserve(solids.size());
    for (const Solid& s : solids) handles.push_back(s.raw_handle("write_svg_text"));
    CadaclysmBlacksmithSvgOptions raw = detail::build_svg_options(options);
    char* text = ::cadaclysm_blacksmith_svg_text(handles.data(), handles.size(), &raw);
    if (!text) return detail::kernel_error("svg_text");
    std::string out(text);
    ::cadaclysm_blacksmith_string_free(text);
    return out;
}

// `write_brep_text` written to `path` by the library itself, which names the file in
// its refusal when it cannot.
inline Result<void> write_brep(const std::string& path, const Solids& solids) {
    std::vector<const CadaclysmBlacksmithSolid*> handles;
    handles.reserve(solids.size());
    for (const Solid& s : solids) handles.push_back(s.raw_handle("write_brep"));
    if (!::cadaclysm_blacksmith_brep(handles.data(), handles.size(), path.c_str())) {
        return detail::kernel_error("brep");
    }
    return {};
}

// `write_svg_text` written to `path` by the library itself, which names the file in
// its refusal when it cannot.
inline Result<void> write_svg(const std::string& path, const Solids& solids, const Profiles& profiles,
                              const SvgOptions& options) {
    std::vector<const CadaclysmBlacksmithSolid*> solid_handles;
    solid_handles.reserve(solids.size());
    for (const Solid& s : solids) solid_handles.push_back(s.raw_handle("write_svg"));
    std::vector<const CadaclysmBlacksmithProfile*> profile_handles;
    profile_handles.reserve(profiles.size());
    for (const Profile& p : profiles) profile_handles.push_back(p.handle());
    CadaclysmBlacksmithSvgOptions raw = detail::build_svg_options(options);
    if (!::cadaclysm_blacksmith_drawing_svg(solid_handles.data(), solid_handles.size(), profile_handles.data(),
                                            profile_handles.size(), path.c_str(), &raw)) {
        return detail::kernel_error("svg");
    }
    return {};
}

// `write_svg_text` written to `path` by the library itself, which names the file in
// its refusal when it cannot. Kept calling the solids-only pair, for the same reason
// `write_svg_text` above does -- see its comment.
inline Result<void> write_svg(const std::string& path, const Solids& solids, const SvgOptions& options) {
    std::vector<const CadaclysmBlacksmithSolid*> handles;
    handles.reserve(solids.size());
    for (const Solid& s : solids) handles.push_back(s.raw_handle("write_svg"));
    CadaclysmBlacksmithSvgOptions raw = detail::build_svg_options(options);
    if (!::cadaclysm_blacksmith_svg(handles.data(), handles.size(), path.c_str(), &raw)) {
        return detail::kernel_error("svg");
    }
    return {};
}

inline Result<void> Solid::brep(const std::string& path) const { return write_brep(path, {*this}); }

inline Result<void> Solid::svg(const std::string& path, const SvgOptions& options) const {
    return write_svg(path, {*this}, options);
}

inline Result<std::string> Profile::svg_text(const SvgOptions& options) const {
    return write_svg_text(Solids{}, {*this}, options);
}

inline Result<void> Profile::svg(const std::string& path, const SvgOptions& options) const {
    return write_svg(path, Solids{}, {*this}, options);
}

namespace detail {
inline bool is_identity(const Matrix4& m) {
    for (int i = 0; i < 4; ++i)
        for (int j = 0; j < 4; ++j)
            if (m[i][j] != (i == j ? 1.0 : 0.0)) return false;
    return true;
}
// `schema` as a path, if it has no newline and names a regular file.
inline std::optional<std::string> schema_file(const std::optional<std::string>& schema) {
    if (!schema || schema->find('\n') != std::string::npos) return std::nullopt;
    std::error_code ignored;
    if (std::filesystem::is_regular_file(cadaclysm::detail::fs_path(*schema), ignored)) return schema;
    return std::nullopt;
}
}  // namespace detail

// The brep as a solid, shared: the reader's reference handed across and given
// straight back, the solid holding one of its own (the Brep can then be released).
inline Result<Solid> Solid::share(const cadaclysm::Brep& brep) {
    std::string layout = cadaclysm::Brep::layout_id();
    return wrap(::cadaclysm_blacksmith_from_brep(brep.pointer(), layout.c_str()));
}

// The brep shared at the identity, a moved copy for a rigid move (a mirror included),
// refused for a scale or shear, which a brep cannot follow exactly.
inline Result<Solid> Solid::share_placed(const cadaclysm::Brep& brep, const Matrix4& m, const std::string& what) {
    Result<Solid> shared = share(brep);
    if (!shared || detail::is_identity(m)) return shared;
    for (int a = 0; a < 3; ++a) {
        for (int b = 0; b < 3; ++b) {
            double d = 0;
            for (int k = 0; k < 3; ++k) d += m[k][a] * m[k][b];  // (axes^T axes)[a][b]
            if (std::fabs(d - (a == b ? 1.0 : 0.0)) > 1e-9) {
                return detail::refuse(what + ": the placement scales or shears, which a brep cannot follow");
            }
        }
    }
    double frame12[12] = {m[0][3], m[1][3], m[2][3], m[0][0], m[1][0], m[2][0],
                          m[0][1], m[1][1], m[2][1], m[0][2], m[1][2], m[2][2]};
    return shared->place_raw(frame12);
}

inline Result<Solid> Solid::from_node(const cadaclysm::Node& node, bool placed) {
    std::string label = node.name();
    if (label.empty()) label = node.kind();
    if (label.empty()) label = "?";
    std::string what = "from_node: node " + std::to_string(node.index()) + " (" + label + ")";
    std::optional<cadaclysm::Brep> brep = node.brep();
    if (!brep) {
        return detail::refuse(what +
                              " has no brep: only a B-rep body has one (STEP, ACIS, Rhino, OCCT .brep, IGES, IFC), "
                              "not a mesh, a curve or a CSG body");
    }
    if (!placed) return share(*brep);
    Matrix4 m = node.transform();
    if (cadaclysm::detail::Access::convention(node) != static_cast<std::uint32_t>(Convention::native) &&
        !detail::is_identity(m)) {
        // Python's order: a brep the kernel will not take is reported before the convention.
        Result<Solid> shared = share(*brep);
        if (!shared) return shared.error();
        return detail::refuse(
            "from_node: placed=True needs the scene opened with Convention.NATIVE -- the brep is in the file's own "
            "axes and the node's transform is not; open NATIVE, or pass placed=False");
    }
    return share_placed(*brep, m, "from_node");
}

inline Result<std::vector<Solid>> Solid::open_all(const std::string& path) {
    std::string name = cadaclysm::detail::file_name(path);
    std::size_t dot = name.find_last_of('.');
    std::string extension = dot == std::string::npos ? std::string() : name.substr(dot + 1);
    for (char& c : extension) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    auto opened = cadaclysm::open(path);
    if (!opened) return detail::refuse("open: " + opened.error().message);
    cadaclysm::Scene scene = std::move(opened).value();
    std::vector<Solid> solids;
    for (const cadaclysm::Placement& placement : scene.placements()) {
        cadaclysm::Node node = placement.geometry();
        std::string label = node.name();
        if (label.empty()) label = node.kind();
        if (label.empty()) label = std::to_string(node.index());
        std::string what = "open: " + label;
        std::optional<cadaclysm::Brep> brep = node.brep();
        if (!brep) continue;
        Result<Solid> placed_solid = share_placed(*brep, placement.transform(), what);
        if (!placed_solid) return placed_solid.error();
        solids.push_back(std::move(*placed_solid));
    }
    scene.close();
    if (solids.empty()) {
        return detail::refuse("open: the ." + extension +
                              " file draws no B-rep body -- only a STEP, ACIS, Rhino, OCCT .brep, IGES or IFC body can be "
                              "a solid, not a mesh, a curve or a CSG body");
    }
    return solids;
}

inline Result<Solid> Solid::open(const std::string& path, std::optional<std::size_t> body) {
    CADACLYSM_TRY(solids, open_all(path));
    std::string name = cadaclysm::detail::file_name(path);
    if (!body && solids.size() == 1) return std::move(solids[0]);
    if (!body) {
        return detail::refuse("open: " + name + " holds " + std::to_string(solids.size()) + " bodies: pass body= (0 to " +
                              std::to_string(solids.size() - 1) + "), or use Solid.open_all");
    }
    if (*body >= solids.size()) {
        return detail::refuse("open: " + name + " has no body " + std::to_string(*body) + ": it holds " +
                              std::to_string(solids.size()));
    }
    return std::move(solids[*body]);  // the rest are freed as `solids` goes
}

inline Result<cadaclysm::Scene> Solid::to_scene(const std::optional<std::string>& schema) const {
    CADACLYSM_TRY(text, step_text(schema));
    cadaclysm::OpenOptions options;
    options.schema = detail::schema_file(schema);
    return cadaclysm::open_memory(text.data(), text.size(), "stp", options);
}

// ---- the chain --------------------------------------------------------------------------

// The fluent chain: a frame, the solid built so far, and the face last picked. A build
// step replaces the solid; combine solids with Solid::join. The first refused step is
// kept and the rest skipped; solid() reports it. from_solid borrows its solid: keep it
// alive while the chain runs.
class Workplane {
public:
    static Workplane xy() { return Workplane(Frame::world_xy()); }
    static Workplane xz() { return Workplane(Frame::world_xz()); }
    static Workplane yz() { return Workplane(Frame::world_yz()); }
    static Workplane on(const Frame& f) { return Workplane(f); }
    static Workplane from_solid(const Solid& source) {
        Workplane w(Frame::world_xy());
        w.borrowed_ = &source;
        return w;
    }

    Workplane& cuboid(double x, double y, double z) & {
        return set([&] { return Solid::cuboid(x, y, z).and_then([&](Solid s) { return s.place(frame_); }); });
    }
    Workplane&& cuboid(double x, double y, double z) && { return std::move(cuboid(x, y, z)); }

    Workplane& cylinder(double r, double height) & {
        return set([&] { return Solid::cylinder(r, height).and_then([&](Solid s) { return s.place(frame_); }); });
    }
    Workplane&& cylinder(double r, double height) && { return std::move(cylinder(r, height)); }

    Workplane& extrude(const Profile& profile, double height) & {
        return set([&] { return Solid::extrude(profile, frame_, height); });
    }
    Workplane&& extrude(const Profile& profile, double height) && { return std::move(extrude(profile, height)); }

    Workplane& face(const Profile& profile) & { return set([&] { return Solid::face(profile, frame_); }); }
    Workplane&& face(const Profile& profile) && { return std::move(face(profile)); }

    // About this workplane's own y axis through its origin.
    Workplane& revolve(const Profile& profile, double angle) & {
        return set([&] { return Solid::revolve(profile, AxisLine{frame_.origin(), frame_.y()}, angle); });
    }
    Workplane&& revolve(const Profile& profile, double angle) && { return std::move(revolve(profile, angle)); }

    // Slide the current solid, keeping the face selection (a translation moves every
    // face at the same index).
    Workplane& translate(double dx, double dy, double dz) & {
        if (error_) return *this;
        const Solid* now = current();
        if (!now) {
            error_ = detail::refuse("translate: the workplane holds no solid (BuildError::Empty)");
            return *this;
        }
        Result<Solid> moved = now->translate(dx, dy, dz);
        if (!moved) {
            error_ = moved.error();
            return *this;
        }
        owned_.emplace(std::move(moved).value());
        borrowed_ = nullptr;
        return *this;
    }
    Workplane&& translate(double dx, double dy, double dz) && { return std::move(translate(dx, dy, dz)); }

    Workplane& faces(const Selector& selector) & {
        if (error_) return *this;
        const Solid* now = current();
        if (!now) {
            error_ = detail::refuse("faces: the workplane holds no solid (BuildError::Empty)");
            return *this;
        }
        Result<std::uint32_t> picked = now->select_face(selector);
        if (!picked) {
            error_ = picked.error();
            return *this;
        }
        selected_ = *picked;
        return *this;
    }
    Workplane&& faces(const Selector& selector) && { return std::move(faces(selector)); }

    // Adopt the frame on the face last picked; a no-op if none is.
    Workplane& workplane() & {
        if (error_) return *this;
        const Solid* now = current();
        if (!now || !selected_) return *this;
        Result<Frame> adopted = now->face_frame(*selected_);
        if (!adopted) {
            error_ = adopted.error();
            return *this;
        }
        frame_ = *adopted;
        return *this;
    }
    Workplane&& workplane() && { return std::move(workplane()); }

    Frame frame() const { return frame_; }
    const Error* err() const noexcept { return error_ ? &*error_ : nullptr; }

    // Hand over the solid built (a copy of a borrowed one); the workplane holds none after.
    Result<Solid> solid() {
        if (error_) return *error_;
        if (owned_) {
            Solid out = std::move(*owned_);
            owned_.reset();
            return out;
        }
        if (borrowed_) {
            const Solid* b = borrowed_;
            borrowed_ = nullptr;
            return b->translate(0, 0, 0);
        }
        return detail::refuse("solid: nothing was built (BuildError::Empty)");
    }

private:
    explicit Workplane(const Frame& f) : frame_(f) {}

    const Solid* current() const { return owned_ ? &*owned_ : borrowed_; }

    template <class Build>
    Workplane& set(Build&& build) {
        if (error_) return *this;
        Result<Solid> made = build();
        if (!made) {
            error_ = made.error();
            return *this;
        }
        owned_.emplace(std::move(made).value());
        borrowed_ = nullptr;
        selected_.reset();
        return *this;
    }

    Frame frame_;
    std::optional<Solid> owned_;
    const Solid* borrowed_ = nullptr;
    std::optional<std::uint32_t> selected_;
    std::optional<Error> error_;
};

}  // namespace blacksmith
}  // namespace CADACLYSM_ABI
}  // namespace cadaclysm

#endif  // CADACLYSM_BLACKSMITH_HPP
