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
#include <map>
#include <memory>

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

/// What a solid measures, per unit density, each figure beside a bound on its own error.
///
/// Per unit density is the primitive: a body's weight is `density * volume` and its inertia scales
/// the same way, so `m.weight(7850)` is a steel part in kilograms where the model is in metres.
/// Nothing here multiplies by a density on your behalf -- an assembly of two materials would have
/// to undo it.
///
/// `volume`, `centroid`, `inertia` and `principal_moments` mean something only where `closed`.
/// Where `accuracy_met` is false the refinement stopped before the accuracy asked for: the figures
/// are honest, they are simply less certain, and the errors say by how much.
struct Mass {
    bool closed = false;
    bool inverted = false;
    bool accuracy_met = false;
    bool from_mesh = false;
    double area = 0.0;
    double area_error = 0.0;
    double volume = 0.0;
    double volume_error = 0.0;
    Vec3 centroid = {};
    double centroid_error = 0.0;
    /// Three rows of three, about the centroid, products of inertia negated.
    std::array<Vec3, 3> inertia = {};
    double inertia_error = 0.0;
    /// Ascending.
    Vec3 principal_moments = {};
    /// Unit, orthogonal, right-handed; row `i` belongs to moment `i`.
    std::array<Vec3, 3> principal_axes = {};

    /// `density * volume`, in whatever units the model and the density agree on.
    double weight(double density) const { return density * volume; }
};
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
    // The pen colour: "#rgb", "#rrggbb", a CSS colour name or a packed 0xRRGGBB (an
    // SvgColour) -- `stroke = "navy"` or `stroke = 0x000080`. Default black.
    SvgColour stroke = 0x000000;
    // The pen's width, page units. Default 1.
    double stroke_width = 1.0;
    // 0xRRGGBB, or nullopt (the default) for no <rect> behind the drawing -- the page
    // left to whatever the viewer composites it onto. "#rgb", "#rrggbb", a CSS colour
    // name or a packed 0xRRGGBB (an SvgColour), e.g. `background = "navy"`.
    std::optional<SvgColour> background;
    // Each solid's feature edges. Default true.
    bool edges = true;
    // A solid has no free curves of its own; ignored. Default false.
    bool curves = false;
    // A solid has no isocurves of its own; ignored. Default false.
    bool isocurves = false;
    // Write every line as straight segments within tolerance, instead of being fitted
    // back to cubic Beziers. Default false.
    bool polylines = false;
    // Also draw where each solid's surfaces turn away from the eye -- the outline a
    // sphere has no edge for. One group per solid, after that solid's lines. Default
    // true: a sphere's and a torus's only curves are the seams where their one face
    // meets itself, which are not edges of the body and are never drawn, so without
    // this those two draw a blank page. A line set in its own right -- set it with
    // edges false for the outline alone, or clear it for the lines alone.
    bool silhouettes = true;
};

class Profile;
class Path;
class SweepPath;
class Frame;
class Solid;
class Assembly;
class Workplane;
class CollisionHit;
class Collider;
class Subd;
class Tool;
class Stock;
class Job;
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

// kernel_error for a call routed through cadaclysm_blacksmith_tessellation: that entry
// point fails with a leading "tessellation:" naming itself, not the caller, so this
// rewrites that prefix back to `name` -- the C-level name the caller reported before it
// held a tessellation of its own -- leaving the rest of the library's message untouched.
inline Error tessellation_error(const char* name) {
    std::string message = text(::cadaclysm_blacksmith_last_error());
    static const std::string prefix = "tessellation:";
    if (message.compare(0, prefix.size(), prefix) == 0) {
        message = std::string(name) + ":" + message.substr(prefix.size());
    }
    if (message.empty()) message = name;
    return Error{std::move(message), Origin::kernel};
}

inline Error refuse(std::string message) { return Error{std::move(message), Origin::kernel}; }

// A silhouette block the kernel handed over, released when this goes out of scope -- on
// every path out of the call that took it, the early returns included. The block carries no
// length of its own, so the guard holds the count the call wrote and gives the same one back.
class SilhouetteBlock {
public:
    SilhouetteBlock(double* data, std::uint32_t count) noexcept : data_(data), count_(count) {}
    SilhouetteBlock(const SilhouetteBlock&) = delete;
    SilhouetteBlock& operator=(const SilhouetteBlock&) = delete;
    ~SilhouetteBlock() { ::cadaclysm_blacksmith_silhouette_beziers_free(data_, count_); }
    const double* data() const noexcept { return data_; }

private:
    double* data_;
    std::uint32_t count_;
};

// Colour text -- "#rgb", "#rrggbb" or a CSS colour name -- as r, g, b in 0..1, through the
// library's own parser. Shared by rgb() and packed() so neither duplicates the parsing.
inline bool try_parse_colour(std::string_view colour, Vec3& out) {
    std::string text(colour);
    return ::cadaclysm_blacksmith_parse_colour(text.c_str(), out.data());
}

// `options` packed into a CadaclysmBlacksmithSvgOptions: `view` fills
// azimuth/elevation unless they are set directly, `up` falls back to "z" -- a solid
// carries no convention of its own. cadaclysm_blacksmith_svg_options_init fills the
// struct first -- size included -- so a field this function never sets still carries
// the library's own default rather than a zeroed struct's. An Error where stroke or
// background is colour text the kernel's parser refuses.
inline Result<CadaclysmBlacksmithSvgOptions> build_svg_options(const SvgOptions& options) {
    CADACLYSM_TRY(stroke, cadaclysm::detail::svg_colour_packed(options.stroke, "svg: stroke",
                                                               ::cadaclysm_blacksmith_parse_colour, Origin::kernel));
    std::uint32_t background = CADACLYSM_BLACKSMITH_SVG_TRANSPARENT;
    if (options.background) {
        CADACLYSM_TRY(packed_background, cadaclysm::detail::svg_colour_packed(*options.background, "svg: background",
                                                                              ::cadaclysm_blacksmith_parse_colour, Origin::kernel));
        background = packed_background;
    }
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
    raw.stroke = stroke;
    raw.background = background;
    raw.flags = (options.edges ? CADACLYSM_BLACKSMITH_SVG_EDGES : 0u) | (options.curves ? CADACLYSM_BLACKSMITH_SVG_CURVES : 0u) |
                (options.isocurves ? CADACLYSM_BLACKSMITH_SVG_ISOCURVES : 0u) |
                (options.polylines ? CADACLYSM_BLACKSMITH_SVG_POLYLINES : 0u) |
                (options.silhouettes ? CADACLYSM_BLACKSMITH_SVG_SILHOUETTES : 0u);
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
// A kernel option, by its name, for the whole process from the next call on:
// "boolean.mesh_budget", "boolean.finest_tolerance", "profile_boolean.point_budget" or
// "measure.default_accuracy". An Error -- and nothing changed -- for a name that is not an
// option or a value it does not take, saying which and what it takes.
inline Result<void> set_option(const std::string& name, double value) {
    if (!::cadaclysm_blacksmith_option_set(name.c_str(), value)) return detail::kernel_error("option refused");
    return {};
}
// A kernel option's value, by its name: what set_option last set, else its default. An
// Error for a name that is not an option, listing the ones there are.
inline Result<double> option(const std::string& name) {
    double out = 0.0;
    if (!::cadaclysm_blacksmith_option_get(name.c_str(), &out)) return detail::kernel_error("no such option");
    return out;
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

// Colour text -- "#rgb", "#rrggbb" or a CSS colour name -- as r, g, b in 0..1, read by the
// library's own parser, so every wrapper takes the same forms.
inline Result<Vec3> rgb(std::string_view colour) {
    Vec3 out{};
    if (detail::try_parse_colour(colour, out)) return out;
    return detail::refuse("coloured: a colour is \"#rgb\", \"#rrggbb\", a CSS colour name or (r, g, b) in 0..1, not '" +
                           std::string(colour) + "'");
}

// A colour as the ABI's packed 0xRRGGBB, from "#rgb", "#rrggbb" or a CSS colour name --
// for a host that wants the number itself (SvgOptions::stroke / background take the text
// directly). Takes no numeric triple of its own, so its refusal lists only the text forms.
inline Result<std::uint32_t> packed(std::string_view colour) {
    Vec3 out{};
    if (!detail::try_parse_colour(colour, out))
        return detail::refuse("colour: a colour is \"#rgb\", \"#rrggbb\" or a CSS colour name, not '" + std::string(colour) + "'");
    auto byte = [](double v) { return static_cast<std::uint32_t>(std::lround(v * 255.0)); };
    return (byte(out[0]) << 16) | (byte(out[1]) << 8) | byte(out[2]);
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

// An axis-aligned box: `lo` and `hi`, three numbers each. The broad phase's own shape
// (Solid::bounds_box, Collider's own boxes): cheap to move and to test against another,
// before anything is meshed.
struct Box {
    Vec3 lo{};
    Vec3 hi{};

    Box() = default;
    Box(const Vec3& lo_, const Vec3& hi_) : lo(lo_), hi(hi_) {}

    // This box moved by `frame` (rigid), boxed again on the world axes -- not this
    // box's corners individually moved, which would not in general be a box at all:
    // the *bounding* box of the moved corners.
    Result<Box> moved(const Frame& frame) const {
        CadaclysmBlacksmithBox raw = words();
        CadaclysmBlacksmithBox out{};
        if (!::cadaclysm_blacksmith_box_moved(&raw, frame.raw().data(), &out)) return detail::kernel_error("box_moved");
        return Box({out.lo[0], out.lo[1], out.lo[2]}, {out.hi[0], out.hi[1], out.hi[2]});
    }

    // Whether this box and `other` share a point (touching counts).
    bool overlaps(const Box& other) const {
        CadaclysmBlacksmithBox a = words();
        CadaclysmBlacksmithBox b = other.words();
        return ::cadaclysm_blacksmith_box_overlaps(&a, &b);
    }

    // This box as the six contiguous doubles the C ABI reads.
    CadaclysmBlacksmithBox words() const {
        CadaclysmBlacksmithBox raw{};
        raw.lo[0] = lo[0];
        raw.lo[1] = lo[1];
        raw.lo[2] = lo[2];
        raw.hi[0] = hi[0];
        raw.hi[1] = hi[1];
        raw.hi[2] = hi[2];
        return raw;
    }

    bool operator==(const Box& other) const noexcept { return lo == other.lo && hi == other.hi; }
    bool operator!=(const Box& other) const noexcept { return !(*this == other); }
};

namespace detail {
inline CadaclysmBlacksmithBox box_words(const Box& box) {
    CadaclysmBlacksmithBox raw{};
    raw.lo[0] = box.lo[0];
    raw.lo[1] = box.lo[1];
    raw.lo[2] = box.lo[2];
    raw.hi[0] = box.hi[0];
    raw.hi[1] = box.hi[1];
    raw.hi[2] = box.hi[2];
    return raw;
}
inline Box box_of(const CadaclysmBlacksmithBox& raw) {
    return Box({raw.lo[0], raw.lo[1], raw.lo[2]}, {raw.hi[0], raw.hi[1], raw.hi[2]});
}
}  // namespace detail

// True only if box `a` at `frame_a` and box `b` at `frame_b` cannot touch -- a
// separating axis among the boxes' face normals and edge-direction crosses; touching
// is not apart. Sharper than moving each box and asking Box::overlaps, which boxes the
// *result* on the world axes again and so can call two oriented boxes overlapping when
// they are not (two unit boxes, the second turned 45 degrees about z and moved 2.3
// along x: their world boxes overlap, but the boxes themselves do not touch).
inline Result<bool> boxes_apart(const Box& a, const Frame& frame_a, const Box& b, const Frame& frame_b) {
    CadaclysmBlacksmithBox ra = detail::box_words(a);
    CadaclysmBlacksmithBox rb = detail::box_words(b);
    bool apart = false;
    if (!::cadaclysm_blacksmith_boxes_apart(&ra, frame_a.raw().data(), &rb, frame_b.raw().data(), &apart)) {
        return detail::kernel_error("boxes_apart");
    }
    return apart;
}

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
    // coloured(const Vec3&) from "#rgb", "#rrggbb" or a CSS colour name.
    Result<Profile> coloured(std::string_view colour) const {
        CADACLYSM_TRY(rgb_value, rgb(colour));
        return coloured(rgb_value);
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

    // This profile with every free-form side (a Bezier, a conic, a NURBS) replaced by
    // lines and arcs within `tolerance` of it -- what a G-code writer can say. Lines and
    // arcs pass through as they are, every loop closes on itself exactly, holes are
    // converted the same way. Fails for a `tolerance` not positive and finite, or a
    // spline that does not evaluate.
    Result<Profile> to_arcs(double tolerance = 0.01) const {
        return wrap(::cadaclysm_blacksmith_profile_to_arcs(ptr(), tolerance), "profile_to_arcs");
    }

    // This profile grown by `distance` (shrunk where it is negative), as zero or more
    // profiles, all lines and arcs: outward corners rounded by `|distance|`, holes
    // moving against the boundary (a hole shrinks as the profile grows). Free-form sides
    // are fitted to `tolerance` first (to_arcs). A shrink that eats the whole profile is
    // an empty vector. Fails for a `distance` not finite, a `tolerance` not positive and
    // finite, a loop with no sides, or loops that cross or touch.
    Result<std::vector<Profile>> offset(double distance, double tolerance = 0.01) const {
        return list(::cadaclysm_blacksmith_profile_offset(ptr(), distance, tolerance), "profile_offset");
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

    // The profiles of a list the library handed back (null: the last error). Each profile
    // is a handle of its own; the list goes on every path once read, a failed read's too
    // (the profiles read so far are destroyed with `out`). Public rather than private
    // (the rest of this class's helpers are): Solid::section and the machining section's
    // report reader share it, over a list the library hands back the same way
    // profile_common's does.
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
    friend class Job;

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

// What a Solid owns: just the handle. The library keeps one tessellation cache per
// solid and replaces it whenever mesh, edge_polylines or bounds_at is asked for a
// different tolerance -- but a tessellation view no longer borrows that cache; it
// holds one of its own (HeldTessellation, below), so nothing here needs a generation
// to track that replacement.
struct SolidState {
    CadaclysmBlacksmithSolid* handle = nullptr;

    bool live() const noexcept { return handle != nullptr; }
    void close() noexcept {
        if (handle) {
            ::cadaclysm_blacksmith_solid_free(handle);
            handle = nullptr;
        }
    }
    SolidState() = default;
    SolidState(const SolidState&) = delete;
    SolidState& operator=(const SolidState&) = delete;
    ~SolidState() { close(); }
};

// A tessellation held by a view: one `CadaclysmBlacksmithTessellation`, freed once,
// outliving any re-mesh of the solid it came from and that solid's own close(). A
// view's `Held` is a shared_ptr so copying a Mesh/Mesh64/EdgePolylines/FaceTriangles
// shares the same handle rather than tessellating again.
struct HeldTessellation {
    CadaclysmBlacksmithTessellation* handle;
    explicit HeldTessellation(CadaclysmBlacksmithTessellation* h) noexcept : handle(h) {}
    ~HeldTessellation() { ::cadaclysm_blacksmith_tessellation_free(handle); }
    HeldTessellation(const HeldTessellation&) = delete;
    HeldTessellation& operator=(const HeldTessellation&) = delete;
};
using Held = std::shared_ptr<const HeldTessellation>;

// Declared, not used: `cadaclysm_blacksmith_mesh`/`_mesh64`/`_mesh_face_triangles`/
// `_edge_polylines` are the raw entry points Solid::mesh() and its three neighbours called
// before each held a tessellation of its own (HeldTessellation, above). Nothing in this
// wrapper calls them any more -- but Python's Pyodide build still does, since there is
// nothing to hold under wasm, its JS arrays being copies anyway
// (cadaclysm_blacksmith.py, the `_WASM` branch) -- and the SDK's cross-language parity
// check requires every wrapper on its PARITY list to declare whatever Python does. Kept
// unreachable, the way the new tessellation entry points stay declared and unused in Node
// and Rust, and the way Node's own `defaultSchema()` stays for the same gate.
[[maybe_unused]] inline void legacy_tessellation_entry_points_for_parity(const CadaclysmBlacksmithSolid* solid,
                                                                          double tolerance) {
    if (solid == nullptr) {
        (void)::cadaclysm_blacksmith_mesh(solid, tolerance);
        (void)::cadaclysm_blacksmith_mesh64(solid, tolerance);
        (void)::cadaclysm_blacksmith_mesh_face_triangles(solid, tolerance);
        (void)::cadaclysm_blacksmith_edge_polylines(solid, tolerance);
    }
}

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

// A solid's triangles, from a tessellation this view owns: outlives any later
// re-mesh of the solid at another tolerance, and the solid's own close(). copy() for
// arrays you would rather own outright than keep this view alive for.
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
    Mesh(detail::Held held, const CadaclysmBlacksmithMesh& data) : held_(std::move(held)), raw_(data) {}
    const CadaclysmBlacksmithMesh& raw() const {
#if CADACLYSM_CHECKED
        if (!held_) cadaclysm::detail::bad_access("blacksmith::Mesh", "the mesh is empty (moved from)");
#endif
        return raw_;
    }

    detail::Held held_;
    CadaclysmBlacksmithMesh raw_;
};

// Mesh in `double`, from the same held tessellation -- the same triangles and
// indices, Mesh's `float` positions and normals being exactly these narrowed. Owns
// its tessellation exactly like Mesh, under the same rule.
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
    Mesh64(detail::Held held, const CadaclysmBlacksmithMesh64& data) : held_(std::move(held)), raw_(data) {}
    const CadaclysmBlacksmithMesh64& raw() const {
#if CADACLYSM_CHECKED
        if (!held_) cadaclysm::detail::bad_access("blacksmith::Mesh64", "the mesh64 is empty (moved from)");
#endif
        return raw_;
    }

    detail::Held held_;
    CadaclysmBlacksmithMesh64 raw_;
};

// A solid's feature edges as polylines, from a tessellation this view owns exactly
// like Mesh: row i is 3 floats a point.
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
    EdgePolylines(detail::Held held, const CadaclysmBlacksmithPolylines& data) : held_(std::move(held)), raw_(data) {}
    const CadaclysmBlacksmithPolylines& raw() const {
#if CADACLYSM_CHECKED
        if (!held_) cadaclysm::detail::bad_access("blacksmith::EdgePolylines", "the edge polylines are empty (moved from)");
#endif
        return raw_;
    }

    detail::Held held_;
    CadaclysmBlacksmithPolylines raw_;
};

// How many triangles each face contributed to the mesh at the same tolerance, one count
// per face in face order: the mesh's triangles run face by face, so face f's are the
// counts[f] after the first sum(counts[0..f]), and the counts sum to the mesh's
// triangle count. Owns a tessellation exactly like Mesh.
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
    FaceTriangles(detail::Held held, const CadaclysmBlacksmithFaceTriangles& data) : held_(std::move(held)), raw_(data) {}
    const CadaclysmBlacksmithFaceTriangles& raw() const {
#if CADACLYSM_CHECKED
        if (!held_) cadaclysm::detail::bad_access("blacksmith::FaceTriangles", "the face triangles are empty (moved from)");
#endif
        return raw_;
    }

    detail::Held held_;
    CadaclysmBlacksmithFaceTriangles raw_;
};

// ---- the FEM surface mesh -------------------------------------------------------------

// One B-rep edge of a FEM mesh: the chain of nodes along it, and where that chain breaks.
// The kernel's own twin of cadaclysm::FemEdge, over this library's own struct.
//
// The two arrays are spans into the FemMesh's own memory and die with it: FemMesh::edges()
// checks the handle before it hands the list over, and a span already in hand is a pointer
// and a length from then on. Copy anything that must outlive the mesh.
struct FemEdge {
    // The **solid's own** B-rep edge id, not this mesh's edge index: FemMesh::edges() is a
    // densely renumbered subset of the solid's edges, ascending by id, with every edge
    // collapsed to a point left out. Everything else here that names an edge means the
    // *index*: a FemMesh::node_kind() of 1 read through FemMesh::node_entity(), the third
    // number of a census row, and the `edge_<i>` physical group of FemMesh::msh_text().
    // This is the one way back from any of them to the solid's own topology -- the numbers
    // Solid::edges() uses.
    std::uint32_t id = 0;
    // This mesh's node indices in order along the edge, its end vertices included; a
    // closed edge repeats no node.
    Span<const std::uint32_t> nodes;
    // Where each connected run of `nodes` begins; `[0]` for one chain along the whole
    // edge. **Read nodes[runs[i] .. runs[i + 1]] (the last run to the end) as one polyline
    // and join nothing across a boundary** -- chains() does that walk. The two ends either
    // side of one are two points of the edge with no mesh edge between them.
    Span<const std::uint32_t> runs;
    // The two faces it bounds, the second NONE on an open sheet's rim. **`0` is a real
    // face, not a sentinel.**
    std::pair<std::uint32_t, std::uint32_t> faces{NONE, NONE};
    // The two B-rep vertices its chain ends at, as FemMesh::vertices() indexes them, the
    // second NONE where both ends are one vertex -- a closed edge, a circle's rim, a
    // full-turn seam. **`0` is a real vertex, not a sentinel.** Which end comes first is
    // the first trim's direction and means nothing else.
    std::pair<std::uint32_t, std::uint32_t> ends{NONE, NONE};
    // The nodes make one loop. False wherever `runs` is longer than one.
    bool closed = false;
    // Bounded twice by one face: a closed surface's seam rather than a real boundary. Both
    // `faces` are then that same face.
    bool seam = false;

    // Each connected run of `nodes` as its own polyline, in order along the edge: what
    // `runs` is for, and one row is the ordinary answer. The last run reaches the end of
    // the chain. A run start past the chain -- which the library does not produce -- is
    // clamped rather than read.
    std::vector<Span<const std::uint32_t>> chains() const {
        std::vector<Span<const std::uint32_t>> out;
        out.reserve(runs.size());
        for (std::size_t i = 0; i < runs.size(); ++i) {
            std::size_t start = std::min(static_cast<std::size_t>(runs[i]), nodes.size());
            std::size_t end = i + 1 < runs.size() ? std::min(static_cast<std::size_t>(runs[i + 1]), nodes.size()) : nodes.size();
            out.push_back(nodes.subspan(start, end > start ? end - start : 0));
        }
        return out;
    }
};

// One B-rep vertex of a FEM mesh: the node the mesh put there, if any, and where the
// topology says it is, if that is known. Plain data, copied out of the handle.
struct FemVertex {
    // The mesh node at this vertex, or NONE where the mesh has none there. **A sentinel
    // here is ordinary, not a fault**: the analysis rebuilds a vertex wherever two trims
    // meet, and a pole's polyline runs give a sphere 48 of them where the mesh has 2
    // points, so a caller walking these skips the sentinel rather than treating it as a gap.
    std::uint32_t node = NONE;
    // Where the vertex is, in the same space and under the same placement as
    // FemMesh::nodes() -- the solid's own vertex rather than a mesh node, so the two can
    // differ by the mesher's rounding. **Meaningless unless has_position**: it is zeroed
    // then, a point no geometry has and one a solver would take for a node at the origin.
    Vec3 point{};
    // `point` was placed. False where every trim meeting at this vertex is a curve with no
    // geometry to read an end off -- then there is **no position at all**.
    bool has_position = false;
};

namespace detail {

// One CadaclysmBlacksmithFemEdge as a FemEdge: the two arrays lent as spans, the pairs
// paired. Tested over rows built by hand in tests/fem_test.cpp, because no fixture in this
// repo has an edge whose chain breaks, or a closed or seam edge.
inline FemEdge fem_edge_of(const CadaclysmBlacksmithFemEdge& raw) {
    FemEdge out;
    out.id = raw.id;
    out.nodes = raw.nodes ? Span<const std::uint32_t>(raw.nodes, raw.node_count) : Span<const std::uint32_t>();
    out.runs = raw.runs ? Span<const std::uint32_t>(raw.runs, raw.run_count) : Span<const std::uint32_t>();
    out.faces = {raw.face_a, raw.face_b};
    out.ends = {raw.end_a, raw.end_b};
    out.closed = raw.closed;
    out.seam = raw.seam;
    return out;
}

// One CadaclysmBlacksmithFemVertex as a FemVertex: the three doubles copied, the flag
// carried.
inline FemVertex fem_vertex_of(const CadaclysmBlacksmithFemVertex& raw) {
    FemVertex out;
    out.node = raw.node;
    for (int k = 0; k < 3; ++k) out.point[k] = raw.point[k];
    out.has_position = raw.has_position;
    return out;
}

}  // namespace detail

// One solid meshed for a solver: nodes welded by bits, triangles wound outward, every node
// tagged with the lowest-dimension B-rep entity it lies on, and every crack reported rather
// than closed. What Solid::fem_mesh() returns, and **owned by you**: freed when destroyed,
// or on free(). Move-only.
//
// A handle rather than a snapshot, and its big arrays are Spans into the library's own
// memory, as Mesh's are and for the same reason: a solver mesh is megabytes, and copying it
// to hand it over would cost that twice.
//
// **The owner of those spans is this object, not the solid, and it carries no generation
// check -- and neither do Mesh, Mesh64, EdgePolylines or FaceTriangles any more.** Those
// four now each hold a tessellation of their own too (HeldTessellation, above), so a
// FEM mesh is no longer the one array product here without a generation guard: it never
// was in the solid's tessellation cache to begin with -- it is a handle of its own, which
// nothing but free() (or the destructor) ends. Closing the solid does not end it either.
//
// Every accessor below checks the handle first, and **in both modes**, not only under
// CADACLYSM_CHECKED: what it guards is a pointer handed to C, as Meshlets::live() guards
// one, rather than a borrowed view's owner. So a *call* on a freed mesh is caught. A span
// already in hand is a pointer and a length from then on, and reading one after the free
// reads freed memory with nothing to say so -- copy anything that must outlive the handle.
class FemMesh {
public:
    FemMesh(FemMesh&&) noexcept = default;
    FemMesh& operator=(FemMesh&&) noexcept = default;

    // Whether free() has run (or this mesh has been moved from).
    bool freed() const noexcept { return !ptr_; }
    // Give the mesh back, and with it every span taken from it. Idempotent.
    void free() noexcept { ptr_.reset(); }

    // Every node's position, three doubles each: placed by Solid::fem_mesh()'s frame, in
    // the solid's own coordinates otherwise. Every node is used by a triangle.
    Span<const double> nodes() const {
        const CadaclysmBlacksmithFemMeshView& r = view("blacksmith::FemMesh::nodes");
        return r.nodes ? Span<const double>(r.nodes, static_cast<std::size_t>(r.node_count) * 3) : Span<const double>();
    }
    // Three node indices a triangle, wound outward -- a mirroring frame is wound back.
    Span<const std::uint32_t> triangles() const {
        const CadaclysmBlacksmithFemMeshView& r = view("blacksmith::FemMesh::triangles");
        return r.triangles ? Span<const std::uint32_t>(r.triangles, static_cast<std::size_t>(r.triangle_count) * 3)
                           : Span<const std::uint32_t>();
    }
    // The B-rep face each triangle lies on, one per triangle, into face_count() faces.
    Span<const std::uint32_t> triangle_face() const {
        const CadaclysmBlacksmithFemMeshView& r = view("blacksmith::FemMesh::triangle_face");
        return r.triangle_face ? Span<const std::uint32_t>(r.triangle_face, r.triangle_count) : Span<const std::uint32_t>();
    }
    // What each node lies on -- `0` a B-rep vertex, `1` an edge, `2` a face -- one per
    // node: the lowest-dimension entity it lies on, which is the `.msh` format's own
    // classification rule. node_entity() says which entity of that kind.
    Span<const std::uint32_t> node_kind() const {
        const CadaclysmBlacksmithFemMeshView& r = view("blacksmith::FemMesh::node_kind");
        return r.node_kind ? Span<const std::uint32_t>(r.node_kind, r.node_count) : Span<const std::uint32_t>();
    }
    // Which vertex, edge or face each node lies on, read by the matching node_kind(): an
    // index into vertices(), into edges(), or into the solid's faces. One per node.
    Span<const std::uint32_t> node_entity() const {
        const CadaclysmBlacksmithFemMeshView& r = view("blacksmith::FemMesh::node_entity");
        return r.node_entity ? Span<const std::uint32_t>(r.node_entity, r.node_count) : Span<const std::uint32_t>();
    }

    // The solid's faces; triangle_face() and a node_kind() of `2` index them -- the same
    // numbering Solid::select_face and Solid::face_kind use.
    std::uint32_t face_count() const { return view("blacksmith::FemMesh::face_count").face_count; }

    // One FemEdge per B-rep edge, in the order a node_kind() of `1` indexes them. **This
    // list's own numbering, not the solid's**: each FemEdge::id carries the solid's own
    // edge id.
    Result<std::vector<FemEdge>> edges() const {
        const CadaclysmBlacksmithFemMesh* handle = live("blacksmith::FemMesh::edges");
        std::vector<FemEdge> out;
        out.reserve(view_.edge_count);
        for (std::uint32_t i = 0; i < view_.edge_count; ++i) {
            CadaclysmBlacksmithFemEdge raw{};
            if (!::cadaclysm_blacksmith_fem_mesh_edge(handle, i, &raw)) return detail::kernel_error("fem mesh edge");
            out.push_back(detail::fem_edge_of(raw));
        }
        return out;
    }

    // One FemVertex per B-rep vertex, in the order a node_kind() of `0` indexes them.
    Result<std::vector<FemVertex>> vertices() const {
        const CadaclysmBlacksmithFemMesh* handle = live("blacksmith::FemMesh::vertices");
        std::vector<FemVertex> out;
        out.reserve(view_.vertex_count);
        for (std::uint32_t i = 0; i < view_.vertex_count; ++i) {
            CadaclysmBlacksmithFemVertex raw{};
            if (!::cadaclysm_blacksmith_fem_mesh_vertex(handle, i, &raw)) return detail::kernel_error("fem mesh vertex");
            out.push_back(detail::fem_vertex_of(raw));
        }
        return out;
    }

    // Every crack, as `{a, b, brep_edge}`: a directed mesh edge (a, b) with no (b, a), and
    // the B-rep edge both nodes lie on -- by FemEdge's own index, not its id -- or NONE
    // where they share none.
    //
    // **Empty unless the solid's topology is closed**, whose mesh is otherwise not asked
    // about at all: an open sheet reports watertight() false with this and folded_edges()
    // *both* empty, and that trio together says "not asked", not "nothing found".
    Result<std::vector<std::array<std::uint32_t, 3>>> open_edges() const {
        const CadaclysmBlacksmithFemMesh* handle = live("blacksmith::FemMesh::open_edges");
        return cadaclysm::detail::census_rows(
            view_.open_edge_count,
            [handle](std::uint32_t i, std::uint32_t* a, std::uint32_t* b, std::uint32_t* edge) {
                return ::cadaclysm_blacksmith_fem_mesh_open_edge(handle, i, a, b, edge);
            },
            [](std::uint32_t i) { return detail::kernel_error(("fem mesh open edge " + std::to_string(i)).c_str()); });
    }

    // Every fold, as open_edges() reports a crack: a directed mesh edge used by more than
    // one triangle. **A solid can be folded without being open** -- one no thicker than a
    // line leaves no hole for an open edge to find, and the closure census's own known-bad
    // bodies are folds rather than open cracks, so a caller that checks open_edges() alone
    // calls such a body sound. Empty under the same rule.
    Result<std::vector<std::array<std::uint32_t, 3>>> folded_edges() const {
        const CadaclysmBlacksmithFemMesh* handle = live("blacksmith::FemMesh::folded_edges");
        return cadaclysm::detail::census_rows(
            view_.folded_edge_count,
            [handle](std::uint32_t i, std::uint32_t* a, std::uint32_t* b, std::uint32_t* edge) {
                return ::cadaclysm_blacksmith_fem_mesh_folded_edge(handle, i, a, b, edge);
            },
            [](std::uint32_t i) { return detail::kernel_error(("fem mesh folded edge " + std::to_string(i)).c_str()); });
    }

    // Every pair of triangles that pass through each other, as {a, b} with a < b,
    // sorted: an edge of one through the other's interior. Their B-rep faces are
    // triangle_face()[a] and [b].
    //
    // **Computed for every solid, open or closed.** The census watertight(), open_edges()
    // and folded_edges() report is topological and cannot see a surface passing through
    // itself; a mesh is ready for a volume mesher when it is watertight() **and** this is
    // empty -- Gmsh refuses one that crosses. A copy.
    Result<std::vector<std::array<std::uint32_t, 2>>> crossings() const {
        const CadaclysmBlacksmithFemMesh* handle = live("blacksmith::FemMesh::crossings");
        return cadaclysm::detail::crossing_rows(
            ::cadaclysm_blacksmith_fem_mesh_crossing_count(handle),
            [handle](std::uint32_t i, std::uint32_t* a, std::uint32_t* b) {
                return ::cadaclysm_blacksmith_fem_mesh_crossing(handle, i, a, b);
            },
            [](std::uint32_t i) { return detail::kernel_error(("fem mesh crossing " + std::to_string(i)).c_str()); });
    }

    // The welded mesh closes -- and so does the topology behind it. **False for every solid
    // whose topology is not closed**, whose mesh is then not asked about at all; read
    // open_edges() for what an empty census beside a false here does and does not mean.
    bool watertight() const { return view("blacksmith::FemMesh::watertight").watertight; }

    // Always false on this side: the kernel has no mesh-only path, every solid being an
    // exact B-rep. The reader's own FemMesh sets it for a node that had no brep, and this
    // is here so that a caller can read the two the same way.
    bool from_mesh() const { return view("blacksmith::FemMesh::from_mesh").from_mesh; }

    // The smallest interior angle of any triangle, in degrees. There is always one: a solid
    // that meshed to no triangles is a refusal, not a mesh.
    double min_angle() const { return view("blacksmith::FemMesh::min_angle").min_angle; }
    // The triangle with that angle, as an index into triangles() by triple.
    std::uint32_t worst_triangle() const { return view("blacksmith::FemMesh::worst_triangle").worst_triangle; }
    // The longest triangle edge, placed.
    //
    // **The figure to check against Solid::fem_mesh()'s max_size, and the only one that
    // says what the mesh actually is**: max_size bounds the boundary segments and merely
    // *targets* the interior -- measured at 1.03 x max_size on a face whose parameters run
    // unevenly -- and one small enough beside the body to reach the mesher's own piece and
    // station ceilings is not honoured at all.
    double longest_edge() const { return view("blacksmith::FemMesh::longest_edge").longest_edge; }

    // The mesh as Gmsh 4.1 ASCII `.msh` text: an entity per B-rep vertex, edge and face, a
    // volume where the solid closes, and a physical group naming each.
    //
    // **On this side the library's text is owned**, released here with
    // `cadaclysm_blacksmith_string_free` as every other text this library hands over, and
    // two asks give two independent texts -- where the reader library's own msh_text()
    // borrows a slot on its handle instead and must not be freed. Nothing here has to free
    // anything either way: what comes back is a std::string of your own.
    //
    // **Prints the unlicensed notice**, as save_msh() does: this library notices on its
    // writers, where the reader library notices in Node::fem_mesh and on neither `.msh`
    // call. Each matches its own siblings, so moving the call to look like the other side
    // breaks a convention.
    //
    // An Error for a mesh the writer refuses, naming the field it cannot honour.
    Result<std::string> msh_text() const {
        char* text = ::cadaclysm_blacksmith_fem_mesh_msh_text(live("blacksmith::FemMesh::msh_text"));
        if (!text) return detail::kernel_error("fem mesh msh_text");
        std::string out(text);
        ::cadaclysm_blacksmith_string_free(text);
        return out;
    }

    // msh_text() written to `path` by the library itself, replacing any file there: the
    // same bytes from the same writer, straight to the file rather than through a string.
    // Prints the notice too; see msh_text().
    Result<void> save_msh(const std::string& path) const {
        if (!::cadaclysm_blacksmith_fem_mesh_save_msh(live("blacksmith::FemMesh::save_msh"), path.c_str())) {
            return detail::kernel_error(("could not write " + path).c_str());
        }
        return {};
    }

private:
    friend class Solid;
    struct Free {
        void operator()(CadaclysmBlacksmithFemMesh* mesh) const noexcept { ::cadaclysm_blacksmith_fem_mesh_free(mesh); }
    };
    FemMesh(CadaclysmBlacksmithFemMesh* handle, const CadaclysmBlacksmithFemMeshView& read) : ptr_(handle), view_(read) {}

    // The handle, refusing a freed (or moved-from) one: a read after free() is a bug in the
    // caller, not a recoverable state, exactly as Meshlets has it.
    const CadaclysmBlacksmithFemMesh* live(const char* what) const {
        if (!ptr_) cadaclysm::detail::bad_access(what, "the FEM mesh is freed");
        return ptr_.get();
    }
    // The view, read once when the handle was made: every pointer in it is built with the
    // handle and good until it is freed -- nothing in this ABI is built lazily -- so asking
    // again per accessor would be one C call per array for the same answer.
    const CadaclysmBlacksmithFemMeshView& view(const char* what) const {
        live(what);
        return view_;
    }

    std::unique_ptr<CadaclysmBlacksmithFemMesh, Free> ptr_;
    CadaclysmBlacksmithFemMeshView view_{};
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

    // Draw this solid through the view library in use, Z up: on a window library show()
    // blocks until the window is closed; the terminal prints a still. view() returns the
    // Camera it was left at. `options.tolerance` (0.05 unset) meshes where exact surfaces do
    // not draw. Include <cadaclysm/view.hpp> to call them.
    template <class V = View, class O = ShowOptions>
    Result<void> show(const O& options = O{}) const {
        auto drawn = V::draw(*this, options, false);
        if (!drawn) return drawn.error();
        return {};
    }
    template <class V = View, class O = ShowOptions>
    auto view(const O& options = O{}) const {
        return V::draw(*this, options, true);
    }

    // -- naming
    // This solid, named `name`. The name rides through an operation with exactly one
    // source solid (place, translate, coloured, fillet, ...) and is dropped by one with
    // two or more (join, cut, common, ...) and by a fresh primitive or sweep -- see
    // name(). It is what Assembly::place_solid defaults a placement's own name to, and
    // the product name a lone named solid gets when written to STEP (step/step_text).
    // Refused for an empty name.
    Result<Solid> named(std::string_view name) const {
        std::string owned(name);
        return wrap(::cadaclysm_blacksmith_named(raw_handle("named"), owned.c_str()));
    }
    // This solid's name, or nullopt if it has none -- what named() set, kept or dropped
    // by whatever built this solid. The C function's pointer is borrowed and null for
    // both "no name" and a failure, so this reads it directly and never consults
    // last_error.
    std::optional<std::string> name() const {
        const char* raw = ::cadaclysm_blacksmith_solid_name(raw_handle("name"));
        if (!raw) return std::nullopt;
        return std::string(raw);
    }

    // -- primitives
    static Result<Solid> cuboid(double x, double y, double z) { return wrap(::cadaclysm_blacksmith_cuboid(x, y, z)); }
    static Result<Solid> cylinder(double r, double h) { return wrap(::cadaclysm_blacksmith_cylinder(r, h)); }
    static Result<Solid> cone(double r, double h) { return wrap(::cadaclysm_blacksmith_cone(r, h)); }
    static Result<Solid> sphere(double r) { return wrap(::cadaclysm_blacksmith_sphere(r)); }
    static Result<Solid> torus(double major, double minor) { return wrap(::cadaclysm_blacksmith_torus(major, minor)); }
    static Result<Solid> wedge(double x, double y, double z, double top_x) {
        return wrap(::cadaclysm_blacksmith_wedge(x, y, z, top_x));
    }
    // A right pyramid of `sides` sides (at least 3): its base the regular polygon of circumradius `r`
    // on z=0, its first corner on +x, its tip at (0, 0, `h`).
    static Result<Solid> pyramid(std::uint32_t sides, double r, double h) {
        return wrap(::cadaclysm_blacksmith_pyramid(sides, r, h));
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
    /// This solid scaled by `factor` about the origin: every length times `factor`, exactly.
    Result<Solid> scaled(double factor) const {
        return wrap(::cadaclysm_blacksmith_scaled(raw_handle("scaled"), factor));
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
    // This solid cut by the plane Z = `z`: its closed outlines there, in XY, nested into
    // profiles with holes (boundaries counter-clockwise, holes clockwise), a line or a
    // circle crossing kept exact and any other curve as lines within `tolerance`. A plane
    // that misses the solid is an empty vector. Fails for a `z` not finite, a `tolerance`
    // not positive and finite, a face lying in the plane (section a little above or below
    // it), or a crossing that does not close.
    Result<std::vector<Profile>> section(double z, double tolerance = 0.05) const {
        return Profile::list(::cadaclysm_blacksmith_solid_section(raw_handle("section"), z, tolerance), "solid_section");
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
    // `progress(phase, done, total)` hears "meet" on the exact route; "mesh", "cull",
    // "cross", "snap" and "curve" where it falls back to the mesh route.
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
    // The solid's axis-aligned box, at the same cost whatever its size: its mesh at a
    // thousandth of its own extent, in `double`, so the box is inside the exact one and
    // short of it by at most that. Worked out once per solid, apart from the tessellation
    // `mesh` caches. `bounds_at` is the box of the mesh at a tolerance you name.
    Result<std::pair<Vec3, Vec3>> bounds() const {
        Vec3 lo{}, hi{};
        if (!::cadaclysm_blacksmith_box(raw_handle("box"), lo.data(), hi.data())) {
            return detail::kernel_error("box");
        }
        return std::make_pair(lo, hi);
    }
    // Axis-aligned (min, max) over the cached tessellation at `tolerance`.
    Result<std::pair<Vec3, Vec3>> bounds_at(double tolerance) const {
        Vec3 lo{}, hi{};
        if (!::cadaclysm_blacksmith_bounds(raw_handle("bounds"), tolerance, lo.data(), hi.data())) {
            return detail::kernel_error("bounds");
        }
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
        return std::make_pair(lo, hi);
    }
    // This solid's box at `tolerance`: its boolean mesh, padded by twice that -- the
    // broad phase's own shape, cheaper to move and test than the solid itself.
    Result<Box> bounds_box(double tolerance = DEFAULT_TOLERANCE) const {
        CadaclysmBlacksmithBox out{};
        if (!::cadaclysm_blacksmith_solid_bounds_box(raw_handle("bounds_box"), tolerance, &out)) {
            return detail::kernel_error("bounds_box");
        }
        return detail::box_of(out);
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
    Result<Mass> mass(double accuracy = 0.0) const {
        CadaclysmBlacksmithMassProperties out = {};
        if (!::cadaclysm_blacksmith_mass_properties(raw_handle("mass"), accuracy, &out)) {
            return detail::kernel_error("mass");
        }
        Mass m;
        m.closed = out.closed != 0;
        m.inverted = out.inverted != 0;
        m.accuracy_met = out.accuracy_met != 0;
        m.from_mesh = out.from_mesh != 0;
        m.area = out.area;
        m.area_error = out.area_error;
        m.volume = out.volume;
        m.volume_error = out.volume_error;
        m.centroid = {out.centroid[0], out.centroid[1], out.centroid[2]};
        m.centroid_error = out.centroid_error;
        for (std::size_t r = 0; r < 3; ++r) {
            m.inertia[r] = {out.inertia[r * 3], out.inertia[r * 3 + 1], out.inertia[r * 3 + 2]};
            m.principal_axes[r] = {out.principal_axes[r * 3], out.principal_axes[r * 3 + 1],
                                   out.principal_axes[r * 3 + 2]};
        }
        m.inertia_error = out.inertia_error;
        m.principal_moments = {out.principal_moments[0], out.principal_moments[1],
                               out.principal_moments[2]};
        return m;
    }

    // -- out
    Result<Mesh> mesh(double tolerance = DEFAULT_TOLERANCE) const {
        CadaclysmBlacksmithTessellation* held = ::cadaclysm_blacksmith_tessellation(raw_handle("mesh"), tolerance);
        if (!held) return detail::tessellation_error("mesh");
        detail::Held owned = std::make_shared<const detail::HeldTessellation>(held);
        return Mesh(std::move(owned), ::cadaclysm_blacksmith_tessellation_mesh(held));
    }
    // mesh(tolerance), from the same held tessellation, unnarrowed: the same triangles
    // and indices, mesh()'s `float` positions and normals being exactly these narrowed.
    Result<Mesh64> mesh64(double tolerance = DEFAULT_TOLERANCE) const {
        CadaclysmBlacksmithTessellation* held = ::cadaclysm_blacksmith_tessellation(raw_handle("mesh64"), tolerance);
        if (!held) return detail::tessellation_error("mesh64");
        detail::Held owned = std::make_shared<const detail::HeldTessellation>(held);
        return Mesh64(std::move(owned), ::cadaclysm_blacksmith_tessellation_mesh64(held));
    }
    // This solid meshed for a solver, as a FemMesh: nodes welded by bits, triangles wound
    // outward, each node tagged with the lowest-dimension B-rep entity it lies on, and every
    // crack reported rather than closed. **Owned by the caller** -- it outlives this solid,
    // and nothing but FemMesh::free() or its destructor gives it back.
    //
    // `tolerance` is the chordal tolerance in model units, finite and above zero, and **it
    // alone governs how closely the mesh follows the geometry**. `max_size` is a size
    // ceiling, finite and zero or more, `0` being no ceiling (curvature alone): **it bounds
    // the boundary segments and merely targets the interior**, which is not a
    // longest-element-edge guarantee -- it adds boundary nodes without refining boundary
    // geometry, and FemMesh::longest_edge() is what the mesh actually came to, the figure to
    // check against it.
    //
    // **`tolerance` defaults to FemOptions::default()'s 0.01, not to this header's own
    // DEFAULT_TOLERANCE of 0.05** that mesh(), edge_polylines() and every other
    // tolerance-taking call here takes: a solver mesh's default is the library's, and a
    // wrapper that reached for the neighbour would hand a caller a five-times coarser mesh
    // unasked. The library's struct is still filled by
    // `cadaclysm_blacksmith_fem_options_init` first, so a field added to it later defaults
    // without this line being touched; only these two are overwritten.
    //
    // `placement` is a Frame -- twelve numbers, origin, x, y, z -- and nothing for the
    // identity. This is the one frame argument here that may be omitted, a solid meshed in
    // its own coordinates being the common case where a sweep without a frame is nothing at
    // all. The reader library's cadaclysm::Node::fem_mesh takes **sixteen** instead,
    // column-major, so a caller moving between the two reformats the placement.
    //
    // `progress` hears the two phases **"meshing"** and **"welding"**, as the booleans'
    // callbacks hear theirs. **An opened phase is not a promise of a closed one**: a call
    // refused for its inputs opens no phase at all, and a solid that meshes to no triangles
    // reports "meshing" through to 1 of 1 and then fails with **no "welding"** -- that close
    // says the mesher finished, not that it produced something.
    //
    // **A cracked solid is not a failure**: it comes back with FemMesh::watertight() false
    // and its cracks in FemMesh::open_edges() and FemMesh::folded_edges() -- *both* -- and
    // nothing is welded shut to make it look sound. An Error for a tolerance or `max_size`
    // the mesher refuses, a placement not invertible, and a solid that meshes to no
    // triangles at all, carrying the library's own words for it. Neither number is checked
    // here: the library checks both and names the field, and a second validator would be a
    // second set of words for one refusal.
    //
    // **No unlicensed notice here**: FemMesh::msh_text() and FemMesh::save_msh() print it,
    // this library noticing on its writers rather than on its builders.
    //
    // **It does not fill the tessellation cache**, so it has nothing to do with a Mesh
    // either way: a Mesh owns a held tessellation of its own now and cannot be staled at
    // all, by fem_mesh or anything else -- read FemMesh.
    Result<FemMesh> fem_mesh(double tolerance = 0.01, double max_size = 0.0,
                             const std::optional<Frame>& placement = std::nullopt, const Progress& progress = {}) const {
        const CadaclysmBlacksmithSolid* solid = raw_handle("fem_mesh");
        CadaclysmBlacksmithFemOptions options{};
        // `init` writes `sizeof(CadaclysmBlacksmithFemOptions)` bytes as the *library* knows
        // that type; `size` is then set to this header's own sizeof, which is what the growth
        // rule asks of a caller. Nothing is transcribed here -- this wrapper compiles against
        // the library's own header -- so there is no layout to pin.
        ::cadaclysm_blacksmith_fem_options_init(&options);
        options.size = sizeof(CadaclysmBlacksmithFemOptions);
        options.tolerance = tolerance;
        options.max_size = max_size;
        CadaclysmBlacksmithFemMesh* handle =
            ::cadaclysm_blacksmith_fem_mesh(solid, placement ? placement->raw().data() : nullptr, &options,
                                            detail::progress_fn(progress), detail::progress_user(progress));
        if (!handle) return detail::kernel_error("fem_mesh");
        CadaclysmBlacksmithFemMeshView read{};
        if (!::cadaclysm_blacksmith_fem_mesh_view(handle, &read)) {
            Error why = detail::kernel_error("fem mesh view");
            ::cadaclysm_blacksmith_fem_mesh_free(handle);
            return why;
        }
        return FemMesh(handle, read);
    }

    Result<EdgePolylines> edge_polylines(double tolerance = DEFAULT_TOLERANCE) const {
        CadaclysmBlacksmithTessellation* held = ::cadaclysm_blacksmith_tessellation(raw_handle("edge_polylines"), tolerance);
        if (!held) return detail::tessellation_error("edge_polylines");
        detail::Held owned = std::make_shared<const detail::HeldTessellation>(held);
        return EdgePolylines(std::move(owned), ::cadaclysm_blacksmith_tessellation_edge_polylines(held));
    }
    // A colour per polyline of edge_polylines() at the same tolerance, as drawn: nullopt
    // for a polyline on no coloured edge; empty where the solid has no edge paint at all.
    // Copied out.
    Result<std::vector<std::optional<Vec3>>> edge_polyline_colours(double tolerance = DEFAULT_TOLERANCE) const {
        CadaclysmBlacksmithColours data = ::cadaclysm_blacksmith_edge_polyline_colours(raw_handle("edge_polyline_colours"), tolerance);
        if (!data.rgb && !detail::text(::cadaclysm_blacksmith_last_error()).empty()) return detail::kernel_error("edge_polyline_colours");
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
    // order; what a viewer colours a face by. From the same held tessellation as mesh().
    Result<FaceTriangles> face_triangles(double tolerance = DEFAULT_TOLERANCE) const {
        CadaclysmBlacksmithTessellation* held = ::cadaclysm_blacksmith_tessellation(raw_handle("face_triangles"), tolerance);
        if (!held) return detail::tessellation_error("mesh_face_triangles");
        detail::Held owned = std::make_shared<const detail::HeldTessellation>(held);
        return FaceTriangles(std::move(owned), ::cadaclysm_blacksmith_tessellation_face_triangles(held));
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

    // This solid's silhouette from the camera `options` describes -- where its surfaces turn
    // away from the eye, which no edge of it lies on. BeziersData64 as the reader's
    // Node::silhouette_beziers returns: points, four control points a curve, three doubles
    // each (count * 12); weights, one a control point (count * 4). The library's block is
    // the caller's to free; it is copied out and freed before this returns, so there is
    // nothing for the caller to release.
    //
    // A body with no silhouette (every face planar) is an empty answer, a BeziersData64
    // with count() == 0, not an Error. An Error, whose message begins "silhouette: ", for a
    // refused option (a tolerance that is not finite and positive, say).
    Result<BeziersData64> silhouette_beziers(const SvgOptions& options = SvgOptions()) const {
        CADACLYSM_TRY(raw, detail::build_svg_options(options));
        std::uint32_t count = 0;
        double* data = ::cadaclysm_blacksmith_silhouette_beziers(raw_handle("silhouette_beziers"), &raw, &count);
        BeziersData64 out;
        if (!data) {
            // All-null with count 0 is both the empty answer and a refusal; the thread's
            // error, cleared on entry, tells them apart.
            if (!detail::text(::cadaclysm_blacksmith_last_error()).empty()) return detail::kernel_error("silhouette_beziers");
            return out;
        }
        detail::SilhouetteBlock block(data, count);
        out.points.reserve(static_cast<std::size_t>(count) * 12);
        out.weights.reserve(static_cast<std::size_t>(count) * 4);
        // Each curve is 16 doubles: four control points (x, y, z), then four weights.
        for (std::uint32_t c = 0; c < count; ++c) {
            const double* curve = block.data() + static_cast<std::size_t>(c) * 16;
            out.points.insert(out.points.end(), curve, curve + 12);
            out.weights.insert(out.weights.end(), curve + 12, curve + 16);
        }
        return out;
    }

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
    // coloured(const Vec3&, ...) from "#rgb", "#rrggbb" or a CSS colour name.
    Result<Solid> coloured(std::string_view colour, std::optional<std::uint32_t> f = std::nullopt) const {
        CADACLYSM_TRY(rgb_value, rgb(colour));
        return coloured(rgb_value, f);
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
    // edges_coloured(const Vec3&, ...) from "#rgb", "#rrggbb" or a CSS colour name.
    Result<Solid> edges_coloured(std::string_view colour, std::optional<std::vector<std::uint32_t>> edge_indices = std::nullopt) const {
        CADACLYSM_TRY(rgb_value, rgb(colour));
        return edges_coloured(rgb_value, std::move(edge_indices));
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
    // The bodies either side of the closed `profile` drawn on `frame`, pushed straight
    // through along the frame's z both ways: those outside it first, then those inside.
    Result<std::vector<Solid>> split_by_profile(const Profile& profile, const Frame& frame,
                                                double tolerance = DEFAULT_TOLERANCE,
                                                const Progress& progress = {}) const {
        CADACLYSM_TRY(whole, wrap(::cadaclysm_blacksmith_split_by_profile(raw_handle("split_by_profile"), profile.ptr(),
                                                                          frame.raw().data(), tolerance,
                                                                          detail::progress_fn(progress),
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
    friend struct ::cadaclysm::detail::ViewAccess;
    friend class Assembly;
    friend class CollisionHit;
    friend class Stock;
    friend class Job;
    friend class Subd;
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

// ---- machining ----------------------------------------------------------------------

// A cutter: Grbl tool `number` (1 to 255, the `T` word), `diameter` and `flute_length`
// in mm, `feed` and `plunge` in mm/min, `rpm` its spindle speed, ramping into its cuts
// at `ramp_angle` degrees. Immutable; a Job keeps its own copy of one it is given, so
// destroying a Tool a job has used changes nothing there. Move-only, freed by its own
// unique_ptr, as Path.
class Tool {
public:
    Tool(Tool&&) noexcept = default;
    Tool& operator=(Tool&&) noexcept = default;
    Tool(const Tool&) = delete;
    Tool& operator=(const Tool&) = delete;

    // A flat end mill: Grbl tool `number` (at least 1), `diameter` and `flute_length` in
    // mm, `feed` and `plunge` in mm/min, `rpm` its spindle speed. It ramps into its cuts
    // at `ramp_angle` degrees (the library's own default is 3). Fails for a `number` of
    // 0 or above 255, a size, feed or speed not positive and finite, or a `ramp_angle`
    // outside (0, 90].
    static Result<Tool> flat(std::uint32_t number, double diameter, double flute_length, double feed, double plunge,
                             double rpm, double ramp_angle = 3.0) {
        return ramped(::cadaclysm_blacksmith_tool_flat(number, diameter, flute_length, feed, plunge, rpm), ramp_angle,
                     "tool_flat");
    }
    // A ball end mill, as flat, its tip a half sphere of the diameter; in 2.5D it cuts
    // where a flat does, `bottom` being the tip.
    static Result<Tool> ball(std::uint32_t number, double diameter, double flute_length, double feed, double plunge,
                             double rpm, double ramp_angle = 3.0) {
        return ramped(::cadaclysm_blacksmith_tool_ball(number, diameter, flute_length, feed, plunge, rpm), ramp_angle,
                     "tool_ball");
    }
    // A drill: as flat, plunging at `feed`. A job takes it for Job::drill (and
    // Job::machine's drills) only.
    static Result<Tool> drill(std::uint32_t number, double diameter, double flute_length, double feed, double rpm) {
        return wrap(::cadaclysm_blacksmith_tool_drill(number, diameter, flute_length, feed, rpm), "tool_drill");
    }
    // A new tool: this one, ramping into its cuts at `degrees` from the horizontal
    // instead. Fails for an angle outside (0, 90].
    Result<Tool> with_ramp_angle(double degrees) const {
        return wrap(::cadaclysm_blacksmith_tool_with_ramp_angle(raw_handle("tool_with_ramp_angle"), degrees),
                    "tool_with_ramp_angle");
    }

    // The C handle, for code that calls the C ABI directly. Owned by this Tool.
    const CadaclysmBlacksmithTool* handle() const noexcept { return ptr_.get(); }

private:
    friend class Job;

    struct Free {
        void operator()(CadaclysmBlacksmithTool* p) const noexcept { ::cadaclysm_blacksmith_tool_free(p); }
    };

    explicit Tool(CadaclysmBlacksmithTool* raw) : ptr_(raw) {}

    static Result<Tool> wrap(CadaclysmBlacksmithTool* raw, const char* what) {
        if (!raw) return detail::kernel_error(what);
        return Tool(raw);
    }
    // `made` wrapped, then turned to `ramp_angle` when it is not the library's own
    // default -- the unramped handle freed at once rather than kept around.
    static Result<Tool> ramped(CadaclysmBlacksmithTool* made, double ramp_angle, const char* what) {
        CADACLYSM_TRY(tool, wrap(made, what));
        if (ramp_angle == 3.0) return tool;
        return tool.with_ramp_angle(ramp_angle);
    }

    const CadaclysmBlacksmithTool* raw_handle(const char* what) const {
        if (!ptr_) cadaclysm::detail::bad_access(what, "the tool is empty (moved from)");
        return ptr_.get();
    }

    std::unique_ptr<CadaclysmBlacksmithTool, Free> ptr_;
};

// The block of material a Job cuts, an axis-aligned box. Immutable; a Job keeps its own
// copy. Move-only, freed by its own unique_ptr, as Tool.
class Stock {
public:
    Stock(Stock&&) noexcept = default;
    Stock& operator=(Stock&&) noexcept = default;
    Stock(const Stock&) = delete;
    Stock& operator=(const Stock&) = delete;

    // The box from (`min_x`, `min_y`, `min_z`) to (`max_x`, `max_y`, `max_z`). Fails
    // unless every min is below its max and all six are finite.
    static Result<Stock> box(const Vec3& min, const Vec3& max) {
        return wrap(::cadaclysm_blacksmith_stock_box(min[0], min[1], min[2], max[0], max[1], max[2]), "stock_box");
    }
    // `solid`'s bounds grown by `margin` in -X, +X, -Y, +Y and +Z; the bottom stays at
    // the solid's lowest Z. Fails for a `margin` negative or not finite.
    static Result<Stock> around(const Solid& solid, double margin = 0.0) {
        return wrap(::cadaclysm_blacksmith_stock_around(solid.raw_handle("stock_around"), margin), "stock_around");
    }

    // The C handle, for code that calls the C ABI directly. Owned by this Stock.
    const CadaclysmBlacksmithStock* handle() const noexcept { return ptr_.get(); }

private:
    friend class Job;

    struct Free {
        void operator()(CadaclysmBlacksmithStock* p) const noexcept { ::cadaclysm_blacksmith_stock_free(p); }
    };

    explicit Stock(CadaclysmBlacksmithStock* raw) : ptr_(raw) {}

    static Result<Stock> wrap(CadaclysmBlacksmithStock* raw, const char* what) {
        if (!raw) return detail::kernel_error(what);
        return Stock(raw);
    }

    const CadaclysmBlacksmithStock* raw_handle(const char* what) const {
        if (!ptr_) cadaclysm::detail::bad_access(what, "the stock is empty (moved from)");
        return ptr_.get();
    }

    std::unique_ptr<CadaclysmBlacksmithStock, Free> ptr_;
};

// One file a Job wrote: a Grbl program (`tool` its `T` number, `name` `<job name>-T<n>`,
// or `<job name>-<k>-T<n>` for a repeated tool) from Job::gcode, or one of
// Job::write_camotics's files (`tool` 0 for the simulation copies and the project).
// Copied out; immutable.
struct Program {
    std::uint32_t tool = 0;
    std::string name;
    std::string text;
};

// One operation of a Job, read back by Job::operations: `kind` (`"face"`, `"contour"`,
// `"pocket"` or `"drill"`), `tool` (its Grbl `T` number) and `params`, the operation's
// own arguments in the library's own numbers -- `side` 0 outside, 1 inside or 2 on its
// line; `climb` and `open` 1 or 0; `points` a count; a `peck` of none reads back as
// nullopt. Copied out; immutable.
struct Operation {
    std::string kind;
    std::uint32_t tool = 0;
    std::map<std::string, std::optional<double>> params;
};

// One thing Job::machine left uncut, one of Report's items. Copied out; immutable.
struct ReportItem {
    // "corner" (material the end mill doesn't reach), "hole" (a round hole no drill
    // matches or a matched drill can't make), "slope" (a face that is neither
    // horizontal nor vertical, cut as steps), "undercut" (material under an overhang)
    // or "too_deep" (a level below the end mill's flute length, cut only that far).
    std::string kind;
    // The item's XYZ location -- a centroid for an area, the axis point at the top for
    // a hole.
    Vec3 at{};
    // An area in mm^2 for corner/undercut, a diameter in mm for hole, and a height in
    // mm (its Z range) for slope and too_deep.
    double size = 0.0;
    // One sentence naming the cause and the tool involved.
    std::string reason;
    // The XY area the item covers.
    std::vector<Profile> region;
};

// What Job::machine could not make: `items`, in order, read once when machine returns,
// and the kernel's own `text` -- one line per item, or "nothing left uncut". Copied
// out; immutable.
struct Report {
    std::vector<ReportItem> items;
    std::string text;

    bool empty() const noexcept { return items.empty(); }
};

namespace detail {

// `side`'s library code, or the refusal for any other side -- checked here so a bad spelling never
// reaches the library.
inline Result<std::uint32_t> job_side(const std::string& side) {
    if (side == "outside") return std::uint32_t(0);
    if (side == "inside") return std::uint32_t(1);
    if (side == "on") return std::uint32_t(2);
    return detail::refuse("side must be 'outside', 'inside' or 'on'");
}

// What the kernel says of a job name with a control character in it -- a NUL, which a C
// string would cut the name short at, is refused with it before the library is asked, as
// the Python SDK does for a `Job` name and a `write_camotics` stem.
inline constexpr const char* job_nul_name_error =
    "job: a name must be non-empty and without brackets, slashes, quotes, control characters, or : * ? < > |";

// The files of one job_gcode/job_camotics call, copied out, the list freed.
inline Result<std::vector<Program>> programs_of(CadaclysmBlacksmithPrograms* raw, const char* what) {
    if (!raw) return detail::kernel_error(what);
    std::uint32_t n = ::cadaclysm_blacksmith_programs_count(raw);
    std::vector<Program> out;
    out.reserve(n);
    for (std::uint32_t i = 0; i < n; ++i) {
        Program p;
        p.tool = ::cadaclysm_blacksmith_programs_tool(raw, i);
        p.name = detail::text(::cadaclysm_blacksmith_programs_name(raw, i));
        p.text = detail::text(::cadaclysm_blacksmith_programs_text(raw, i));
        out.push_back(std::move(p));
    }
    ::cadaclysm_blacksmith_programs_free(raw);
    return out;
}

// A job_machine report, read field by field, the report freed.
inline Result<Report> report_of(CadaclysmBlacksmithReport* raw) {
    if (!raw) return detail::kernel_error("job_machine");
    std::uint32_t n = ::cadaclysm_blacksmith_report_count(raw);
    std::vector<ReportItem> items;
    items.reserve(n);
    for (std::uint32_t i = 0; i < n; ++i) {
        double at[3] = {0, 0, 0};
        if (!::cadaclysm_blacksmith_report_at(raw, i, at)) {
            ::cadaclysm_blacksmith_report_free(raw);
            return detail::kernel_error("report_at");
        }
        Result<std::vector<Profile>> region = Profile::list(::cadaclysm_blacksmith_report_region(raw, i), "report_region");
        if (!region) {
            ::cadaclysm_blacksmith_report_free(raw);
            return region.error();
        }
        ReportItem item;
        item.kind = detail::text(::cadaclysm_blacksmith_report_kind(raw, i));
        item.at = Vec3{at[0], at[1], at[2]};
        item.size = ::cadaclysm_blacksmith_report_size(raw, i);
        item.reason = detail::text(::cadaclysm_blacksmith_report_reason(raw, i));
        item.region = std::move(region).value();
        items.push_back(std::move(item));
    }
    Report out;
    out.items = std::move(items);
    out.text = detail::text(::cadaclysm_blacksmith_report_text(raw));
    ::cadaclysm_blacksmith_report_free(raw);
    return out;
}

// Every operation of one job_operations call, read field by field, the list freed.
inline std::vector<Operation> operations_of(CadaclysmBlacksmithOperations* raw) {
    std::uint32_t n = ::cadaclysm_blacksmith_operations_count(raw);
    std::vector<Operation> out;
    out.reserve(n);
    for (std::uint32_t i = 0; i < n; ++i) {
        Operation op;
        op.kind = detail::text(::cadaclysm_blacksmith_operations_kind(raw, i));
        op.tool = ::cadaclysm_blacksmith_operations_tool(raw, i);
        std::uint32_t param_count = ::cadaclysm_blacksmith_operations_param_count(raw, i);
        for (std::uint32_t k = 0; k < param_count; ++k) {
            std::string name = detail::text(::cadaclysm_blacksmith_operations_param_name(raw, i, k));
            double value = ::cadaclysm_blacksmith_operations_param_value(raw, i, k);
            op.params[name] = std::isnan(value) ? std::optional<double>() : std::optional<double>(value);
        }
        out.push_back(std::move(op));
    }
    ::cadaclysm_blacksmith_operations_free(raw);
    return out;
}

}  // namespace detail

// A machining job on a Stock: operations kept in the order they are added, written as
// one Grbl 1.1 program per run of operations sharing a tool. Mutable -- each operation
// is added in place, and a refused one leaves the job as it was. `safe_z` is the
// absolute Z of rapids between operations and at a program's start and end, above the
// stock's top; `clearance` is how far above an operation's top it enters and leaves its
// passes; `tolerance` fits free-form sides and offsets; `name` names the programs
// (`<name>-T<n>`); `spindle_dwell` is how long every program waits after starting the
// spindle; `resolution` is the CAMotics project's voxel size in mm. Move-only, backed
// by a unique_ptr with a Free, as Assembly; close() frees it now, and every call after
// is refused rather than aborting -- a job's own operations already return a Result the
// same way a refused C call does, so a closed job answers through that same channel.
class Job {
public:
    Job(Job&&) noexcept = default;
    Job& operator=(Job&&) noexcept = default;
    Job(const Job&) = delete;
    Job& operator=(const Job&) = delete;

    // An empty job on `stock`, rapids at `safe_z` (above the stock's top), with the
    // library's own defaults (`clearance` 1, `tolerance` 0.01, `name` "job",
    // `spindle_dwell` 2 s, `resolution` 0.1 mm) until overridden here. Fails for a
    // `safe_z` not above the stock's top, or a setting the job refuses.
    static Result<Job> make(const Stock& stock, double safe_z, double clearance = 1.0, double tolerance = 0.01,
                            const std::string& name = "job", double spindle_dwell = 2.0, double resolution = 0.1) {
        if (name.find('\0') != std::string::npos) return detail::refuse(detail::job_nul_name_error);
        CadaclysmBlacksmithJob* raw = ::cadaclysm_blacksmith_job_new(stock.raw_handle("job_new"), safe_z);
        if (!raw) return detail::kernel_error("job_new");
        Job job(raw);
        if (!::cadaclysm_blacksmith_job_set_clearance(raw, clearance)) return detail::kernel_error("job_set_clearance");
        if (!::cadaclysm_blacksmith_job_set_tolerance(raw, tolerance)) return detail::kernel_error("job_set_tolerance");
        if (!::cadaclysm_blacksmith_job_set_spindle_dwell(raw, spindle_dwell)) {
            return detail::kernel_error("job_set_spindle_dwell");
        }
        if (!::cadaclysm_blacksmith_job_set_resolution(raw, resolution)) return detail::kernel_error("job_set_resolution");
        if (!::cadaclysm_blacksmith_job_set_name(raw, name.c_str())) return detail::kernel_error("job_set_name");
        return job;
    }

    // Free the job now. Idempotent; every call on the job is refused after. Lists it
    // wrote (operations(), gcode(), write_camotics, a Report) are independent copies
    // and outlive it.
    void close() noexcept { ptr_.reset(); }
    bool closed() const noexcept { return !ptr_; }

    // Face the stock's top down to `z`, in zigzag rows along X `stepover` apart and
    // passes at most `stepdown` deep, with `tool`. Fails for a drill, a `z` above the
    // stock's top, a stepover past the tool's diameter, or what the job otherwise
    // refuses.
    Result<void> face(const Tool& tool, double z, double stepover, double stepdown) {
        CADACLYSM_TRY(handle, live());
        if (!::cadaclysm_blacksmith_job_face(handle, tool.raw_handle("job_face"), z, stepover, stepdown)) {
            return detail::kernel_error("job_face");
        }
        return {};
    }
    // Cut along `profile` from `top` to `bottom` in passes at most `stepdown` deep,
    // with `tool`: `side` "outside" the profile, "inside" it, or "on" its line; `climb`
    // for climb milling, else conventional; `open` to cut the outline as an open chain
    // (only "on" its line, and with no holes). Fails for any other `side`, or what the
    // job otherwise refuses.
    Result<void> contour(const Tool& tool, const Profile& profile, double top, double bottom,
                         const std::string& side = "outside", double stepdown = 1.0, bool climb = true,
                         bool open = false) {
        CADACLYSM_TRY(handle, live());
        CADACLYSM_TRY(code, detail::job_side(side));
        if (!::cadaclysm_blacksmith_job_contour(handle, tool.raw_handle("job_contour"), profile.ptr(), top, bottom,
                                                code, stepdown, climb, open)) {
            return detail::kernel_error("job_contour");
        }
        return {};
    }
    // Clear `profile` -- its holes left standing as islands -- from `top` to `bottom`,
    // in rings `stepover` apart (at most the tool's radius) and passes at most
    // `stepdown` deep, with `tool`. Fails for what the job refuses; a pocket too small
    // for the tool is refused by gcode(), naming the operation.
    Result<void> pocket(const Tool& tool, const Profile& profile, double top, double bottom, double stepover,
                        double stepdown) {
        CADACLYSM_TRY(handle, live());
        if (!::cadaclysm_blacksmith_job_pocket(handle, tool.raw_handle("job_pocket"), profile.ptr(), top, bottom,
                                               stepover, stepdown)) {
            return detail::kernel_error("job_pocket");
        }
        return {};
    }
    // A hole at each (x, y) of `points`, from `top` to `bottom` with `tool`, pecking
    // `peck` deep at a time (retracting between pecks), or straight to depth for
    // nullopt. Fails for what the job refuses (a tool that is not a drill, no points,
    // ...).
    Result<void> drill(const Tool& tool, const std::vector<Vec2>& points, double top, double bottom,
                       std::optional<double> peck = std::nullopt) {
        CADACLYSM_TRY(handle, live());
        std::vector<double> flat;
        flat.reserve(points.size() * 2);
        for (const Vec2& p : points) {
            flat.push_back(p[0]);
            flat.push_back(p[1]);
        }
        if (!::cadaclysm_blacksmith_job_drill(handle, tool.raw_handle("job_drill"),
                                              flat.empty() ? nullptr : flat.data(), points.size(), top, bottom,
                                              peck.value_or(std::numeric_limits<double>::quiet_NaN()))) {
            return detail::kernel_error("job_drill");
        }
        return {};
    }
    // Recognise `part` and append the operations that make it: faced, contoured and
    // pocketed with `end_mill`, its holes drilled with whichever of `drills` fits each
    // -- a tool per required diameter. `stepover` and `stepdown` of nullopt are the
    // kernel's own defaults; `skin` (at least 0) is how far above the part's lowest
    // point the outline stops, so the part stays attached to the stock -- 0 cuts
    // through; `peck` of nullopt is none (a drill straight to depth). Returns a Report
    // of what could not be cut. Fails for what the kernel refuses (a drill as
    // `end_mill`, ...); the job changes only on success -- a refusal leaves it exactly
    // as it was.
    Result<Report> machine(const Solid& part, const Tool& end_mill, const std::vector<const Tool*>& drills = {},
                           std::optional<double> stepover = std::nullopt, std::optional<double> stepdown = std::nullopt,
                           double skin = 0.3, std::optional<double> peck = std::nullopt) {
        CADACLYSM_TRY(handle, live());
        std::vector<const CadaclysmBlacksmithTool*> handles;
        handles.reserve(drills.size());
        for (const Tool* d : drills) handles.push_back(d ? d->raw_handle("job_machine") : nullptr);
        double nan = std::numeric_limits<double>::quiet_NaN();
        CadaclysmBlacksmithReport* raw = ::cadaclysm_blacksmith_job_machine(
            handle, part.raw_handle("job_machine"), end_mill.raw_handle("job_machine"),
            handles.empty() ? nullptr : handles.data(), handles.size(), stepover.value_or(nan), stepdown.value_or(nan),
            skin, peck.value_or(nan));
        return detail::report_of(raw);
    }

    // Every operation added to this job so far, in order -- whether added by face,
    // contour, pocket, drill or machine.
    Result<std::vector<Operation>> operations() const {
        CADACLYSM_TRY(handle, live());
        CadaclysmBlacksmithOperations* raw = ::cadaclysm_blacksmith_job_operations(handle);
        if (!raw) return detail::kernel_error("job_operations");
        return detail::operations_of(raw);
    }
    // The job as Grbl 1.1 programs, one per run of consecutive operations sharing a
    // tool (T1, T2, T1 gives three), each named `<name>-T<n>` (or `<name>-<k>-T<n>` for
    // run `k` of a tool that runs more than once); an empty vector for a job with no
    // operations. Fails for an operation whose geometry the tool cannot cut (named by
    // its index and kind).
    Result<std::vector<Program>> gcode() const {
        CADACLYSM_TRY(handle, live());
        return detail::programs_of(::cadaclysm_blacksmith_job_gcode(handle), "job_gcode");
    }
    // A CAMotics project at `path` and its files beside it, named after the project's
    // file stem (`out/part.camotics` writes `out/part-T1.nc`), not the job's name: each
    // program, a simulation copy of it (`.sim.nc`, which the project lists), and the
    // project last. Creates the directory. Returns the paths written, the project
    // last, written here (not by the library) byte for byte, as plain UTF-8 with no
    // byte-order mark. Fails for a path with no file stem, what gcode() refuses, or a
    // file that cannot be written.
    Result<std::vector<std::string>> write_camotics(const std::string& path) const {
        CADACLYSM_TRY(handle, live());
        // the stem is read off the text first: a path with a NUL in it may not survive being a
        // std::filesystem::path, and Python refuses the stem, in the kernel's words
        {
            std::string tail = path.substr(path.find_last_of("/\\") == std::string::npos ? 0 : path.find_last_of("/\\") + 1);
            std::size_t dot = tail.find_last_of('.');
            if (tail.substr(0, dot == std::string::npos || dot == 0 ? tail.size() : dot).find('\0') != std::string::npos) {
                return detail::refuse(detail::job_nul_name_error);
            }
        }
        std::filesystem::path path_fs = cadaclysm::detail::fs_path(path);
        std::string stem = cadaclysm::detail::utf8(path_fs.stem());
        if (stem.empty()) return detail::refuse("job_camotics: " + path + " has no file stem");
        CADACLYSM_TRY(files, detail::programs_of(::cadaclysm_blacksmith_job_camotics(handle, stem.c_str()), "job_camotics"));
        std::filesystem::path dir_fs = path_fs.parent_path();
        if (!dir_fs.empty()) {
            std::error_code ec;
            std::filesystem::create_directories(dir_fs, ec);
            if (ec) return detail::refuse("job_camotics: " + path + ": " + ec.message());
        }
        std::vector<std::string> written;
        written.reserve(files.size());
        for (std::size_t i = 0; i < files.size(); ++i) {
            std::filesystem::path at = (i + 1 == files.size()) ? path_fs : dir_fs / std::filesystem::path(files[i].name);
            std::ofstream out(at, std::ios::binary);
            if (!out) return detail::refuse("job_camotics: " + path + ": cannot write " + cadaclysm::detail::utf8(at));
            out.write(files[i].text.data(), static_cast<std::streamsize>(files[i].text.size()));
            if (!out) return detail::refuse("job_camotics: " + path + ": cannot write " + cadaclysm::detail::utf8(at));
            written.push_back(cadaclysm::detail::utf8(at));
        }
        return written;
    }

    // The C handle, for code that calls the C ABI directly. Owned by this Job.
    const CadaclysmBlacksmithJob* handle() const noexcept { return ptr_.get(); }

private:
    struct Free {
        void operator()(CadaclysmBlacksmithJob* p) const noexcept { ::cadaclysm_blacksmith_job_free(p); }
    };

    explicit Job(CadaclysmBlacksmithJob* raw) : ptr_(raw) {}

    // The handle for a live job, or "job: closed" for one that has been closed (or
    // moved from) already -- as Path's "already ended" and SweepPath's "closed" name
    // their own refusal, not the library's.
    Result<CadaclysmBlacksmithJob*> live() const {
        if (!ptr_) return detail::refuse("job: closed");
        return ptr_.get();
    }

    std::unique_ptr<CadaclysmBlacksmithJob, Free> ptr_;
};

// ---- collider -------------------------------------------------------------------------

namespace detail {

// Keeps one Collider::check answer alive for as long as any CollisionHit of it is: each
// hit holds one of these (shared), and the last one let go frees the handle -- the same
// idiom Solid's own state uses, except a CollisionHit needs the handle itself back for
// solid().
struct CollisionsState {
    CadaclysmBlacksmithCollisions* handle = nullptr;
    CollisionsState() = default;
    CollisionsState(const CollisionsState&) = delete;
    CollisionsState& operator=(const CollisionsState&) = delete;
    ~CollisionsState() {
        if (handle) ::cadaclysm_blacksmith_collisions_free(handle);
    }
};

}  // namespace detail

// Counts of one Collider::check call: the candidate pairs `considered`, how many of
// them the world boxes and the oriented boxes cleared, how many the share left to
// another call, how the rest were answered (`cached`, `closed_form`, `meshed`), and how
// many were `refused`. `confirmed` is the subset of `meshed` that were thin mesh-path
// overlaps sent to Solid::common itself for a final answer.
struct ColliderStats {
    std::uint32_t considered = 0;
    std::uint32_t world_boxes = 0;
    std::uint32_t oriented_boxes = 0;
    std::uint32_t skipped_share = 0;
    std::uint32_t cached = 0;
    std::uint32_t closed_form = 0;
    std::uint32_t meshed = 0;
    std::uint32_t refused = 0;
    std::uint32_t confirmed = 0;
};

// One pair Collider::check found overlapping (`kind == "overlap"`), or could not decide
// (`kind == "refused"`, `text` says why, empty for an overlap). `overlap` is the same
// answer as a bool. `positions`/`normals` are world xyz triples, three per triangle
// (unwelded); `indices` indexes them -- all empty for a refused pair. `depth` is the
// thinnest side of the overlap's world box, 0 for a refused pair.
//
// `solid()` rebuilds the exact overlap now, from the frames `check` found it at; this
// keeps the collisions handle behind every hit of one `check` call alive until the last
// of them is destroyed, freeing it only then.
class CollisionHit {
public:
    std::uint32_t a = 0;
    std::uint32_t b = 0;
    bool overlap = false;
    std::string kind;
    double depth = 0.0;
    std::string text;
    std::vector<Vec3> positions;
    std::vector<Vec3> normals;
    std::vector<std::uint32_t> indices;

    CollisionHit() = default;

    // The exact overlap of this pair at the frames Collider::check found it at, as a
    // new solid. Refused for a refused pair (`overlap` false) or a collisions handle
    // already closed some other way.
    Result<Solid> solid() const {
        if (!keeper_ || !keeper_->handle) return detail::refuse("CollisionHit.solid: the collisions handle is closed");
        return Solid::wrap(::cadaclysm_blacksmith_collisions_solid(keeper_->handle, index_), "collisions_solid");
    }

private:
    friend class Collider;

    // Copied out of the C struct: the pointers are read here and nowhere kept.
    static CollisionHit from_raw(const CadaclysmBlacksmithCollisionHit& raw, std::shared_ptr<detail::CollisionsState> keeper,
                                 std::uint32_t index) {
        CollisionHit hit;
        hit.a = raw.a;
        hit.b = raw.b;
        hit.overlap = raw.overlap;
        hit.kind = raw.overlap ? "overlap" : "refused";
        hit.depth = raw.depth;
        hit.text = detail::text(raw.text);
        hit.positions = detail::points_at(raw.positions, raw.vertex_count);
        hit.normals = detail::points_at(raw.normals, raw.vertex_count);
        if (raw.indices) hit.indices.assign(raw.indices, raw.indices + raw.index_count);
        hit.keeper_ = std::move(keeper);
        hit.index_ = index;
        return hit;
    }

    std::shared_ptr<detail::CollisionsState> keeper_;
    std::uint32_t index_ = 0;
};

// Parts meshed once, asked pose after pose which of them interfere: `solids` at rest,
// meshed at `tolerance`; `groups` one group index per solid (nullopt: each solid its
// own group -- check() then takes one frame per solid), `allowed` pairs of part indices
// never tested (designed contacts, by part index). Move-only; the destructor frees the
// handle, as close() does early.
class Collider {
public:
    // Hand-written, not `= default`: a raw handle's default move copies the pointer
    // without clearing the source, which frees it twice (once from the moved-from
    // temporary, once from here) the moment either goes out of scope.
    Collider(Collider&& other) noexcept : handle_(other.handle_) { other.handle_ = nullptr; }
    Collider& operator=(Collider&& other) noexcept {
        if (this != &other) {
            close();
            handle_ = other.handle_;
            other.handle_ = nullptr;
        }
        return *this;
    }
    Collider(const Collider&) = delete;
    Collider& operator=(const Collider&) = delete;

    ~Collider() { close(); }

    void close() noexcept {
        if (handle_) {
            ::cadaclysm_blacksmith_collider_free(handle_);
            handle_ = nullptr;
        }
    }
    bool closed() const noexcept { return handle_ == nullptr; }

    static Result<Collider> make(const std::vector<std::reference_wrapper<const Solid>>& solids,
                                 double tolerance = DEFAULT_TOLERANCE,
                                 const std::optional<std::vector<std::uint32_t>>& groups = std::nullopt,
                                 const std::vector<std::pair<std::uint32_t, std::uint32_t>>& allowed = {}) {
        if (groups && groups->size() != solids.size()) {
            return detail::refuse("Collider: groups must have one entry per solid (" + std::to_string(solids.size()) +
                                  " solids, " + std::to_string(groups->size()) + " groups)");
        }
        std::vector<const CadaclysmBlacksmithSolid*> handles;
        handles.reserve(solids.size());
        for (const Solid& s : solids) handles.push_back(s.handle());
        std::vector<std::uint32_t> allowed_flat;
        allowed_flat.reserve(allowed.size() * 2);
        for (const auto& pair : allowed) {
            allowed_flat.push_back(pair.first);
            allowed_flat.push_back(pair.second);
        }
        CadaclysmBlacksmithCollider* h = ::cadaclysm_blacksmith_collider_new(
            handles.data(), static_cast<std::uint32_t>(handles.size()), tolerance,
            groups ? groups->data() : nullptr, allowed_flat.empty() ? nullptr : allowed_flat.data(),
            static_cast<std::uint32_t>(allowed.size()));
        if (!h) return detail::kernel_error("collider_new");
        return Collider(h);
    }

    // How many groups this collider has -- the highest group index past the
    // constructor, plus one.
    std::uint32_t group_count() const { return ::cadaclysm_blacksmith_collider_group_count(raw_handle("group_count")); }

    // Counts of the last check() call (all zero before the first one).
    Result<ColliderStats> stats() const {
        CadaclysmBlacksmithColliderStats out{};
        if (!::cadaclysm_blacksmith_collider_stats(raw_handle("stats"), &out)) return detail::kernel_error("collider_stats");
        return ColliderStats{out.considered, out.world_boxes,  out.oriented_boxes, out.skipped_share, out.cached,
                             out.closed_form, out.meshed,      out.refused,        out.confirmed};
    }

    // The pairs that interfere, or could not be decided, with each group placed at its
    // matching frame in `frames` (one per group, in group order). `share`: nullopt,
    // every pair past the box filters is decided now; `(k, n)`, only those whose index
    // is `k` modulo `n` (the shares of one pose are disjoint and cover it -- split one
    // check() across `n` workers).
    Result<std::vector<CollisionHit>> check(const std::vector<std::reference_wrapper<const Frame>>& frames,
                                            const std::optional<std::pair<std::uint32_t, std::uint32_t>>& share =
                                                std::nullopt) const {
        std::vector<double> flat;
        flat.reserve(frames.size() * 12);
        for (const Frame& f : frames) {
            const std::array<double, 12>& v = f.raw();
            flat.insert(flat.end(), v.begin(), v.end());
        }
        std::uint32_t share_k = share ? share->first : 0;
        std::uint32_t share_n = share ? share->second : 0;
        CadaclysmBlacksmithCollisions* h = ::cadaclysm_blacksmith_collider_check(
            raw_handle("check"), flat.data(), static_cast<std::uint32_t>(frames.size()), share_k, share_n);
        if (!h) return detail::kernel_error("collider_check");
        std::uint32_t count = ::cadaclysm_blacksmith_collisions_count(h);
        if (count == 0) {
            ::cadaclysm_blacksmith_collisions_free(h);
            return std::vector<CollisionHit>{};
        }
        auto keeper = std::make_shared<detail::CollisionsState>();
        keeper->handle = h;
        std::vector<CollisionHit> hits;
        hits.reserve(count);
        for (std::uint32_t i = 0; i < count; ++i) {
            CadaclysmBlacksmithCollisionHit raw{};
            if (!::cadaclysm_blacksmith_collisions_hit(h, i, &raw)) return detail::kernel_error("collisions_hit");
            hits.push_back(CollisionHit::from_raw(raw, keeper, i));
        }
        return hits;
    }

    // The C handle, for code that calls the C ABI directly. Owned by this Collider.
    const CadaclysmBlacksmithCollider* handle() const noexcept { return handle_; }

private:
    explicit Collider(CadaclysmBlacksmithCollider* h) : handle_(h) {}

    CadaclysmBlacksmithCollider* raw_handle(const char* what) const {
        if (!handle_) cadaclysm::detail::bad_access(what, "the collider is closed");
        return handle_;
    }

    CadaclysmBlacksmithCollider* handle_ = nullptr;
};

// ---- SubD cage ------------------------------------------------------------------------

// An edge of a cage, as its two vertex ids.
struct SubdEdge {
    std::uint32_t a = 0;
    std::uint32_t b = 0;
};
inline bool operator==(const SubdEdge& l, const SubdEdge& r) { return l.a == r.a && l.b == r.b; }
inline bool operator!=(const SubdEdge& l, const SubdEdge& r) { return !(l == r); }

// A mirror plane's normal.
enum class SubdAxis : std::uint32_t { x = 0, y = 1, z = 2 };
// What a selection, or a pick, is of.
enum class SubdElements : std::uint32_t { vertices = 0, edges = 1, faces = 2 };

// A cage's mirror: the axis and the on-plane distance of a mirrored half.
struct SubdSymmetry {
    SubdAxis axis = SubdAxis::x;
    double tolerance = 0.0;
};
inline bool operator==(const SubdSymmetry& l, const SubdSymmetry& r) {
    return l.axis == r.axis && l.tolerance == r.tolerance;
}
inline bool operator!=(const SubdSymmetry& l, const SubdSymmetry& r) { return !(l == r); }

// Some elements of a cage: vertex or face ids in `ids` (`edges` empty), or edges in
// `edges` (`ids` empty). What an edit leaves selected, what transform moves, and what
// pick answers (one element).
struct SubdSelection {
    SubdElements kind = SubdElements::vertices;
    std::vector<std::uint32_t> ids;
    std::vector<SubdEdge> edges;

    static SubdSelection of_vertices(std::vector<std::uint32_t> vertices) {
        return SubdSelection{SubdElements::vertices, std::move(vertices), {}};
    }
    static SubdSelection of_edges(std::vector<SubdEdge> edges) {
        return SubdSelection{SubdElements::edges, {}, std::move(edges)};
    }
    static SubdSelection of_faces(std::vector<std::uint32_t> faces) {
        return SubdSelection{SubdElements::faces, std::move(faces), {}};
    }
};
inline bool operator==(const SubdSelection& l, const SubdSelection& r) {
    return l.kind == r.kind && l.ids == r.ids && l.edges == r.edges;
}
inline bool operator!=(const SubdSelection& l, const SubdSelection& r) { return !(l == r); }

// A cage's smooth surface at one level, copied out of the cage: it outlives it.
// `indices` is three vertex ids a triangle, `triangle_face` the face of the full cage
// each triangle lies on.
struct SubdMesh {
    std::vector<Vec3> positions;
    std::vector<Vec3> normals;
    std::vector<std::uint32_t> indices;
    std::vector<std::uint32_t> triangle_face;
};

// What Subd::to_solid did and how close it came: `regular` patches exact from their own
// net and `refined` ones from a refined neighbourhood, the Catmull-Clark `steps` taken
// first, `levels` the deepest local refinement. The largest `deviation` from the limit
// surface (a fraction of the cage's diagonal) and the largest tangent break
// `g1_angle_deg` across an uncreased side, with the world points they were measured at.
struct SubdReport {
    std::uint32_t regular = 0;
    std::uint32_t refined = 0;
    std::uint32_t steps = 0;
    std::uint32_t levels = 0;
    double deviation = 0.0;
    double g1_angle_deg = 0.0;
    Vec3 deviation_at = {};
    Vec3 g1_at = {};
};

// What Subd::to_solid returns: the exact solid and its report.
struct SubdSolid {
    Solid solid;
    SubdReport report;
};

// A subdivision-surface cage: control vertices and faces, with creases, pins and a
// mirror. Immutable: every edit returns a new cage, and the input is untouched. Move-
// only; the destructor frees the handle, as close() does early. Every read-back is a
// copy. A call on a closed cage is a bad access, as on a closed Collider.
class Subd {
public:
    // Hand-written, not `= default`: see Collider.
    Subd(Subd&& other) noexcept : handle_(other.handle_) { other.handle_ = nullptr; }
    Subd& operator=(Subd&& other) noexcept {
        if (this != &other) {
            close();
            handle_ = other.handle_;
            other.handle_ = nullptr;
        }
        return *this;
    }
    Subd(const Subd&) = delete;
    Subd& operator=(const Subd&) = delete;

    ~Subd() { close(); }

    void close() noexcept {
        if (handle_) {
            ::cadaclysm_blacksmith_subd_free(handle_);
            handle_ = nullptr;
        }
    }
    bool closed() const noexcept { return handle_ == nullptr; }

    // -- primitives

    static Result<Subd> cuboid(const std::array<double, 3>& size = {2.0, 2.0, 2.0},
                               const std::array<std::uint32_t, 3>& segments = {1, 1, 1}) {
        return wrap(::cadaclysm_blacksmith_subd_cuboid(size[0], size[1], size[2], segments[0], segments[1], segments[2]),
                    "subd_cuboid");
    }
    // The rims are creased by default: the C call has no default of its own.
    static Result<Subd> cylinder(double radius = 1.0, double height = 2.0, std::uint32_t sides = 8,
                                 std::uint32_t rings = 1, bool creased_rims = true) {
        return wrap(::cadaclysm_blacksmith_subd_cylinder(radius, height, sides, rings, creased_rims), "subd_cylinder");
    }
    static Result<Subd> sphere(double radius = 1.0, std::uint32_t segments = 2) {
        return wrap(::cadaclysm_blacksmith_subd_sphere(radius, segments), "subd_sphere");
    }
    static Result<Subd> torus(double major = 3.0, double minor = 1.0, std::uint32_t around = 12, std::uint32_t tube = 8) {
        return wrap(::cadaclysm_blacksmith_subd_torus(major, minor, around, tube), "subd_torus");
    }
    // A cage from its parts, the inverse of the read-backs: a saved cage, a mirrored
    // half included, loads back equal. The new cage selects nothing.
    static Result<Subd> from_parts(const std::vector<Vec3>& positions, const std::vector<std::vector<std::uint32_t>>& faces,
                                   const std::vector<SubdEdge>& creases = {}, const std::vector<std::uint32_t>& pins = {},
                                   const std::optional<SubdSymmetry>& symmetry = std::nullopt) {
        std::vector<double> flat;
        flat.reserve(positions.size() * 3);
        for (const Vec3& p : positions) flat.insert(flat.end(), p.begin(), p.end());
        std::vector<std::uint32_t> sizes;
        std::vector<std::uint32_t> loops;
        sizes.reserve(faces.size());
        for (const std::vector<std::uint32_t>& face : faces) {
            sizes.push_back(static_cast<std::uint32_t>(face.size()));
            loops.insert(loops.end(), face.begin(), face.end());
        }
        std::vector<std::uint32_t> pairs = flatten(creases);
        return wrap(::cadaclysm_blacksmith_subd_from_parts(
                        flat.data(), static_cast<std::uint32_t>(positions.size()), sizes.data(),
                        static_cast<std::uint32_t>(sizes.size()), loops.data(), static_cast<std::uint32_t>(loops.size()),
                        pairs.data(), static_cast<std::uint32_t>(creases.size()), pins.data(),
                        static_cast<std::uint32_t>(pins.size()), symmetry ? static_cast<std::int32_t>(symmetry->axis) : -1,
                        symmetry ? symmetry->tolerance : 0.0),
                    "subd_from_parts");
    }

    // -- read-backs, all copies

    std::vector<Vec3> positions() const {
        CadaclysmBlacksmithSubdParts p = parts("positions");
        return cadaclysm::blacksmith::detail::points_at(p.positions, p.vertex_count);
    }
    std::vector<std::vector<std::uint32_t>> faces() const {
        CadaclysmBlacksmithSubdParts p = parts("faces");
        std::vector<std::vector<std::uint32_t>> out;
        out.reserve(p.face_count);
        std::size_t at = 0;
        for (std::uint32_t f = 0; f < p.face_count; ++f) {
            out.emplace_back(p.face_indices + at, p.face_indices + at + p.face_sizes[f]);
            at += p.face_sizes[f];
        }
        return out;
    }
    std::vector<SubdEdge> creases() const {
        CadaclysmBlacksmithSubdParts p = parts("creases");
        return edges_at(p.creases, p.crease_count);
    }
    std::vector<std::uint32_t> pins() const {
        CadaclysmBlacksmithSubdParts p = parts("pins");
        return p.pin_count ? std::vector<std::uint32_t>(p.pins, p.pins + p.pin_count) : std::vector<std::uint32_t>{};
    }
    // nullopt for none.
    std::optional<SubdSymmetry> symmetry() const {
        CadaclysmBlacksmithSubdParts p = parts("symmetry");
        if (p.symmetry_axis < 0) return std::nullopt;
        return SubdSymmetry{static_cast<SubdAxis>(p.symmetry_axis), p.symmetry_tolerance};
    }
    // What the edit that made this cage selected; nullopt for none.
    std::optional<SubdSelection> selection() const {
        CadaclysmBlacksmithSubdParts p = parts("selection");
        return selection_of(p.selection_kind, p.selection, p.selection_count);
    }

    // -- edits, each a new cage

    // The selected elements moved by `matrix`: sixteen numbers, column-major.
    Result<Subd> transform(const SubdSelection& selection, const std::vector<double>& matrix) const {
        const CadaclysmBlacksmithSubd* h = raw_handle("transform");
        if (matrix.size() != 16) {
            return detail::refuse("transform: matrix must be sixteen numbers (column-major), not " +
                                  std::to_string(matrix.size()));
        }
        std::vector<std::uint32_t> pairs;
        const std::uint32_t* ids = selection.ids.data();
        std::size_t count = selection.ids.size();
        if (selection.kind == SubdElements::edges) {
            pairs = flatten(selection.edges);
            ids = pairs.data();
            count = selection.edges.size();
        }
        return wrap(::cadaclysm_blacksmith_subd_transform(h, static_cast<std::uint32_t>(selection.kind), ids,
                                                          static_cast<std::uint32_t>(count), matrix.data()),
                    "subd_transform");
    }
    Result<Subd> crease(const std::vector<SubdEdge>& edges, bool on = true) const {
        const CadaclysmBlacksmithSubd* h = raw_handle("crease");
        std::vector<std::uint32_t> pairs = flatten(edges);
        return wrap(::cadaclysm_blacksmith_subd_set_crease(h, pairs.data(), static_cast<std::uint32_t>(edges.size()), on),
                    "subd_set_crease");
    }
    Result<Subd> pin(const std::vector<std::uint32_t>& vertices, bool on = true) const {
        const CadaclysmBlacksmithSubd* h = raw_handle("pin");
        return wrap(::cadaclysm_blacksmith_subd_set_pin(h, vertices.data(), static_cast<std::uint32_t>(vertices.size()), on),
                    "subd_set_pin");
    }
    Result<Subd> extrude(const std::vector<std::uint32_t>& faces, double distance) const {
        const CadaclysmBlacksmithSubd* h = raw_handle("extrude");
        return wrap(::cadaclysm_blacksmith_subd_extrude(h, faces.data(), static_cast<std::uint32_t>(faces.size()), distance),
                    "subd_extrude");
    }
    Result<Subd> inset(const std::vector<std::uint32_t>& faces, double amount, bool individual = false) const {
        const CadaclysmBlacksmithSubd* h = raw_handle("inset");
        return wrap(::cadaclysm_blacksmith_subd_inset(h, faces.data(), static_cast<std::uint32_t>(faces.size()), amount,
                                                      individual),
                    "subd_inset");
    }
    // A loop of edges cut across `edge`, `at` (0 to 1) of the way along it.
    Result<Subd> insert_loop(const SubdEdge& edge, double at = 0.5) const {
        const CadaclysmBlacksmithSubd* h = raw_handle("insert_loop");
        return wrap(::cadaclysm_blacksmith_subd_insert_loop(h, edge.a, edge.b, at), "subd_insert_loop");
    }
    Result<Subd> mirror_on(SubdAxis axis) const {
        const CadaclysmBlacksmithSubd* h = raw_handle("mirror_on");
        return wrap(::cadaclysm_blacksmith_subd_mirror_on(h, static_cast<std::uint32_t>(axis)), "subd_mirror_on");
    }
    Result<Subd> mirror_off() const {
        return wrap(::cadaclysm_blacksmith_subd_mirror_off(raw_handle("mirror_off")), "subd_mirror_off");
    }
    Result<Subd> full() const { return wrap(::cadaclysm_blacksmith_subd_full(raw_handle("full")), "subd_full"); }

    // -- other calls

    // The loop of edges through `edge`, the picked edge first; empty where `edge` is no
    // edge of the cage.
    Result<std::vector<SubdEdge>> edge_loop(const SubdEdge& edge) const {
        const CadaclysmBlacksmithSubd* h = raw_handle("edge_loop");
        std::unique_ptr<CadaclysmBlacksmithSubd, decltype(&::cadaclysm_blacksmith_subd_free)> loop(
            ::cadaclysm_blacksmith_subd_edge_loop(h, edge.a, edge.b), &::cadaclysm_blacksmith_subd_free);
        if (!loop) return detail::kernel_error("subd_edge_loop");
        // The loop is the returned handle's selection; read it. The handle is freed on every
        // path, a throw included.
        CadaclysmBlacksmithSubdParts p{};
        bool read = ::cadaclysm_blacksmith_subd_parts(loop.get(), &p);
        Result<std::vector<SubdEdge>> out = std::vector<SubdEdge>{};
        if (!read) {
            out = detail::kernel_error("subd_parts");
        } else if (p.selection_kind == static_cast<std::uint32_t>(SubdElements::edges)) {
            out = edges_at(p.selection, p.selection_count);
        }
        return out;
    }
    // The surface refined `levels` times (1 to 6), copied out of the cage.
    Result<SubdMesh> smooth_mesh(std::uint32_t levels = 3) const {
        const CadaclysmBlacksmithSubd* h = raw_handle("smooth_mesh");
        CadaclysmBlacksmithSubdMesh m{};
        if (!::cadaclysm_blacksmith_subd_smooth_mesh(h, levels, &m)) return detail::kernel_error("subd_smooth_mesh");
        SubdMesh out;
        out.positions = detail::points_at(m.positions, m.vertex_count);
        out.normals = detail::points_at(m.normals, m.vertex_count);
        if (m.indices && m.index_count) out.indices.assign(m.indices, m.indices + m.index_count);
        if (m.triangle_face && m.index_count) out.triangle_face.assign(m.triangle_face, m.triangle_face + m.index_count / 3);
        return out;
    }
    // The cage element of `kind` under `point`, a point on or near the smooth surface;
    // one element (an edge in `edges`, the smaller id first). nullopt where nothing is
    // near, which is not an error.
    Result<std::optional<SubdSelection>> pick(const Vec3& point, SubdElements kind) const {
        const CadaclysmBlacksmithSubd* h = raw_handle("pick");
        std::uint32_t out[2] = {0, 0};
        if (!::cadaclysm_blacksmith_subd_pick(h, point.data(), static_cast<std::uint32_t>(kind), out)) {
            // A refusal's text is never empty; an empty one means nothing is near.
            if (detail::text(::cadaclysm_blacksmith_last_error()).empty()) return std::optional<SubdSelection>{};
            return detail::kernel_error("subd_pick");
        }
        if (kind == SubdElements::edges) return std::optional<SubdSelection>{SubdSelection::of_edges({SubdEdge{out[0], out[1]}})};
        return std::optional<SubdSelection>{SubdSelection{kind, {out[0]}, {}}};
    }
    // The cage as an exact solid and a report of how it was held. A `tolerance` or
    // `g1_angle` of 0 or less, or a `max_levels` of 0, takes the default (1e-4, 0.1, 6).
    Result<SubdSolid> to_solid(double tolerance = 1e-4, double g1_angle = 0.1, std::uint32_t max_levels = 6) const {
        const CadaclysmBlacksmithSubd* h = raw_handle("to_solid");
        CadaclysmBlacksmithSubdReport raw{};
        CADACLYSM_TRY(solid, Solid::wrap(::cadaclysm_blacksmith_subd_to_solid(h, tolerance, g1_angle, max_levels, &raw),
                                         "subd_to_solid"));
        SubdReport report;
        report.regular = raw.regular;
        report.refined = raw.refined;
        report.steps = raw.steps;
        report.levels = raw.levels;
        report.deviation = raw.deviation;
        report.g1_angle_deg = raw.g1_angle_deg;
        report.deviation_at = Vec3{raw.deviation_at[0], raw.deviation_at[1], raw.deviation_at[2]};
        report.g1_at = Vec3{raw.g1_at[0], raw.g1_at[1], raw.g1_at[2]};
        return SubdSolid{std::move(solid), report};
    }

    // The C handle, for code that calls the C ABI directly. Owned by this Subd.
    const CadaclysmBlacksmithSubd* handle() const noexcept { return handle_; }

private:
    explicit Subd(CadaclysmBlacksmithSubd* h) : handle_(h) {}

    static Result<Subd> wrap(CadaclysmBlacksmithSubd* h, const char* what) {
        if (!h) return detail::kernel_error(what);
        return Subd(h);
    }

    // The closed check comes first in every method, before anything with a destructor
    // exists, so a bad-access hook that does not return unwinds nothing.
    CadaclysmBlacksmithSubd* raw_handle(const char* /*what*/) const {
        if (!handle_) cadaclysm::detail::bad_access("subd", "closed");
        return handle_;
    }

    CadaclysmBlacksmithSubdParts parts(const char* what) const {
        CadaclysmBlacksmithSubdParts p{};
        if (!::cadaclysm_blacksmith_subd_parts(raw_handle(what), &p)) cadaclysm::detail::bad_access("subd", "parts unreadable");
        return p;
    }

    static std::vector<std::uint32_t> flatten(const std::vector<SubdEdge>& edges) {
        std::vector<std::uint32_t> out;
        out.reserve(edges.size() * 2);
        for (const SubdEdge& e : edges) {
            out.push_back(e.a);
            out.push_back(e.b);
        }
        return out;
    }
    static std::vector<SubdEdge> edges_at(const std::uint32_t* at, std::uint32_t count) {
        std::vector<SubdEdge> out;
        if (!at) return out;
        out.reserve(count);
        for (std::uint32_t k = 0; k < count; ++k) out.push_back(SubdEdge{at[2 * k], at[2 * k + 1]});
        return out;
    }
    static std::optional<SubdSelection> selection_of(std::uint32_t kind, const std::uint32_t* at, std::uint32_t count) {
        if (kind == 1) return SubdSelection::of_edges(edges_at(at, count));
        if (kind > 2) return std::nullopt;
        std::vector<std::uint32_t> ids;
        if (at && count) ids.assign(at, at + count);
        return SubdSelection{static_cast<SubdElements>(kind), std::move(ids), {}};
    }

    CadaclysmBlacksmithSubd* handle_ = nullptr;
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
    CADACLYSM_TRY(raw, detail::build_svg_options(options));
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
    CADACLYSM_TRY(raw, detail::build_svg_options(options));
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
    CADACLYSM_TRY(raw, detail::build_svg_options(options));
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
    CADACLYSM_TRY(raw, detail::build_svg_options(options));
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

// ---- assemblies -------------------------------------------------------------------------

// One freedom's range for Assembly::pair: either side nullopt for unbounded.
struct Range {
    std::optional<double> lower;
    std::optional<double> upper;
};

// Assembly::pair's optional arguments: the frame the pair reaches at its rest values
// (frame itself, i.e. all-zero rest values, when nullopt), one Range per freedom of the
// pair's kind (nullopt entirely for a kind that allows none), and a pitch (required and
// non-zero for screw, refused for any other kind).
struct PairOptions {
    std::optional<Frame> end_frame;
    std::optional<std::vector<Range>> ranges;
    std::optional<double> pitch;
};

// One row of Assembly::state: a joint name and its values, in its pair's freedom order.
struct StateRow {
    std::string joint;
    std::vector<double> values;
};

// One segment of Assembly::sequence: the state it reaches, at which parameter, and how the
// motion leaves it -- "undefined", "discontinuous", "synchronous" or "linear".
struct SequenceSegment {
    std::string state;
    double t = 0;
    std::string interpolation;
};

// A mutable tree of placements: a name, and zero or more solids or other assemblies
// placed in it at a frame. place_solid/place_assembly return the placement's name so a
// caller can keep it. Unlike Solid, placing shares rather than copies -- placing one
// assembly under another does not snapshot it, so a later placement on the shared one
// shows up wherever it already sits (see place_assembly's own note on cycles). Move-only
// and backed by a unique_ptr with a Free, as Path; but where Path latches its first
// refused step, this returns each call's own Result<>, as Solid does, since nothing here
// chains through an already-refused state. Destroying this frees this handle; it does
// **not** free what was placed in it if that is still reachable from somewhere else.
class Assembly {
public:
    Assembly(Assembly&&) noexcept = default;
    Assembly& operator=(Assembly&&) noexcept = default;
    Assembly(const Assembly&) = delete;
    Assembly& operator=(const Assembly&) = delete;

    // A new, empty assembly called `name`. Refused for an empty name.
    static Result<Assembly> create(std::string_view name) {
        std::string owned(name);
        CadaclysmBlacksmithAssembly* raw = ::cadaclysm_blacksmith_assembly_new(owned.c_str());
        if (!raw) return detail::kernel_error("assembly_new");
        return Assembly(raw);
    }

    void close() noexcept { ptr_.reset(); }
    bool closed() const noexcept { return !ptr_; }

    // This assembly's own name, given when it was made.
    std::string name() const { return detail::text(::cadaclysm_blacksmith_assembly_name(raw_handle("name"))); }

    // Place `s` at `frame` (must be right-handed and orthonormal) in this assembly,
    // called `name` -- or, with `name` nullopt, `s`'s own name (Solid::name, "part" for
    // an unnamed one), numbered past any already taken here ("bolt", "bolt 2", ...). An
    // explicit `name` already taken here is refused. Returns the placement's name --
    // Python's place, split as this wrapper has no type-dispatching overload; see
    // place_assembly for placing another assembly.
    Result<std::string> place_solid(const Solid& s, const Frame& frame,
                                    std::optional<std::string_view> name = std::nullopt) const {
        return place_solid_raw(s, frame.raw().data(), name);
    }
    // place_solid, but placing another assembly, `placed`, rather than a solid --
    // sharing it, not copying it, so a later placement on `placed` (through this
    // assembly or another) shows up wherever it is placed. Placing `placed` as this
    // assembly itself, or anywhere above this assembly in the tree already, is refused,
    // naming the cycle, since writing that out would never terminate.
    Result<std::string> place_assembly(const Assembly& placed, const Frame& frame,
                                       std::optional<std::string_view> name = std::nullopt) const {
        return place_assembly_raw(placed, frame.raw().data(), name);
    }
    // place_solid with a raw, unchecked twelve-number frame: a placement's mirror is a
    // left-handed frame, which Frame::make refuses and the kernel takes -- following
    // Solid::place_raw's own precedent for the same fact.
    Result<std::string> place_solid_raw(const Solid& s, const double* frame12,
                                        std::optional<std::string_view> name = std::nullopt) const {
        std::optional<std::string> owned = name ? std::optional<std::string>(*name) : std::nullopt;
        char* raw = ::cadaclysm_blacksmith_assembly_place_solid(raw_handle("assembly_place_solid"), s.raw_handle("place_solid"),
                                                                 frame12, owned ? owned->c_str() : nullptr);
        return place_result(raw, "assembly_place_solid");
    }
    Result<std::string> place_assembly_raw(const Assembly& placed, const double* frame12,
                                           std::optional<std::string_view> name = std::nullopt) const {
        std::optional<std::string> owned = name ? std::optional<std::string>(*name) : std::nullopt;
        char* raw = ::cadaclysm_blacksmith_assembly_place_assembly(raw_handle("assembly_place_assembly"),
                                                                    placed.raw_handle("place_assembly"), frame12,
                                                                    owned ? owned->c_str() : nullptr);
        return place_result(raw, "assembly_place_assembly");
    }

    // Declare a rigid link called `name` over `placements` -- names of placements of this
    // assembly itself, not of assemblies placed in it. An empty name, a name already
    // taken by a link here, no placements, a placement named twice, one this assembly
    // does not have, or one already in another link is refused and leaves the assembly as
    // it was. Written as an AP242 kinematic link; a mechanism anywhere in the tree makes
    // AP242 the default schema of step_text.
    Result<void> link(std::string_view name, const std::vector<std::string>& placements) const {
        std::string owned_name(name);
        std::vector<const char*> pointers;
        pointers.reserve(placements.size());
        for (const std::string& p : placements) pointers.push_back(p.c_str());
        if (!::cadaclysm_blacksmith_assembly_link(raw_handle("assembly_link"), owned_name.c_str(),
                                                   pointers.empty() ? nullptr : pointers.data(), pointers.size())) {
            return detail::kernel_error("assembly_link");
        }
        return {};
    }
    // Connect this assembly's links `start` and `end`, kept in that order, as a joint
    // called `name`. An empty name, a name taken by another joint here, a link this
    // assembly does not have, a link joined to itself, or a (start, end) pair already
    // joined is refused; the reverse pair is a different joint.
    Result<void> joint(std::string_view name, std::string_view start, std::string_view end) const {
        std::string owned_name(name), owned_start(start), owned_end(end);
        if (!::cadaclysm_blacksmith_assembly_joint(raw_handle("assembly_joint"), owned_name.c_str(), owned_start.c_str(),
                                                    owned_end.c_str())) {
            return detail::kernel_error("assembly_joint");
        }
        return {};
    }

    // Give joint `joint_name` its pair: `kind` (a name of the kind table -- "revolute",
    // "prismatic", "cylindrical", "screw", "spherical", "spherical_with_pin", "planar",
    // "universal", "homokinetic", "fully_constrained" or "unconstrained"), the contact
    // frame at rest, and `options` (end_frame, ranges, pitch -- see PairOptions). Refused,
    // with the kernel's own message and the assembly left unchanged, when a rule refuses
    // it.
    Result<void> pair(std::string_view joint_name, std::string_view kind, const Frame& frame,
                      const PairOptions& options = {}) const {
        std::string owned_joint(joint_name), owned_kind(kind);
        const double* end_frame_ptr = options.end_frame ? options.end_frame->raw().data() : nullptr;

        std::size_t freedom_count = options.ranges ? options.ranges->size() : 0;
        // `ranges` being present -- even an empty vector -- means ranges were GIVEN, and
        // the C ABI must see that as all four pointers non-null with count `freedom_count`
        // (possibly 0), never as "no ranges" (all four null, which only an absent
        // `options.ranges` means). So every buffer below is sized max(freedom_count, 1)
        // whenever `options.ranges` is present, even when it is empty.
        std::vector<double> lower, upper;
        // has_lower/has_upper are a plain bool array on the C ABI side; std::vector<bool>
        // is bit-packed and has no contiguous bool* to hand it, so these are an owning
        // bool[] instead.
        std::unique_ptr<bool[]> has_lower, has_upper;
        if (options.ranges) {
            lower.resize(freedom_count ? freedom_count : 1);
            upper.resize(freedom_count ? freedom_count : 1);
            has_lower = std::make_unique<bool[]>(freedom_count ? freedom_count : 1);
            has_upper = std::make_unique<bool[]>(freedom_count ? freedom_count : 1);
            for (std::size_t i = 0; i < freedom_count; ++i) {
                const Range& r = (*options.ranges)[i];
                lower[i] = r.lower.value_or(0.0);
                upper[i] = r.upper.value_or(0.0);
                has_lower[i] = r.lower.has_value();
                has_upper[i] = r.upper.has_value();
            }
        }
        double pitch = options.pitch.value_or(std::numeric_limits<double>::quiet_NaN());
        bool ok = ::cadaclysm_blacksmith_assembly_pair(
            raw_handle("assembly_pair"), owned_joint.c_str(), owned_kind.c_str(), frame.raw().data(), end_frame_ptr,
            options.ranges ? lower.data() : nullptr, options.ranges ? upper.data() : nullptr,
            options.ranges ? has_lower.get() : nullptr, options.ranges ? has_upper.get() : nullptr,
            freedom_count, pitch);
        if (!ok) return detail::kernel_error("assembly_pair");
        return {};
    }

    // Give joint `joint_name` its pair, like pair() but with the kind's numbers in `params`:
    // screw [pitch]; rack_and_pinion [pinion_radius]; gear [radius_first, radius_second,
    // ratio] or plus [bevel, helical_angle] in radians (ratio = the second link's rotation
    // over the first's, signed); none for the other kinds. `end_frame` and `ranges` are
    // PairOptions' (its pitch is not used). Refused, with the kernel's own message and the
    // assembly left unchanged, when a rule refuses it (a wrong count among them).
    Result<void> pair_with(std::string_view joint_name, std::string_view kind, const Frame& frame,
                           const PairOptions& options = {}, const std::vector<double>& params = {}) const {
        std::string owned_joint(joint_name), owned_kind(kind);
        const double* end_frame_ptr = options.end_frame ? options.end_frame->raw().data() : nullptr;

        std::size_t freedom_count = options.ranges ? options.ranges->size() : 0;
        std::vector<double> lower, upper;
        std::unique_ptr<bool[]> has_lower, has_upper;
        if (options.ranges) {
            lower.resize(freedom_count ? freedom_count : 1);
            upper.resize(freedom_count ? freedom_count : 1);
            has_lower = std::make_unique<bool[]>(freedom_count ? freedom_count : 1);
            has_upper = std::make_unique<bool[]>(freedom_count ? freedom_count : 1);
            for (std::size_t i = 0; i < freedom_count; ++i) {
                const Range& r = (*options.ranges)[i];
                lower[i] = r.lower.value_or(0.0);
                upper[i] = r.upper.value_or(0.0);
                has_lower[i] = r.lower.has_value();
                has_upper[i] = r.upper.has_value();
            }
        }
        bool ok = ::cadaclysm_blacksmith_assembly_pair_with(
            raw_handle("assembly_pair_with"), owned_joint.c_str(), owned_kind.c_str(), frame.raw().data(),
            end_frame_ptr, options.ranges ? lower.data() : nullptr, options.ranges ? upper.data() : nullptr,
            options.ranges ? has_lower.get() : nullptr, options.ranges ? has_upper.get() : nullptr, freedom_count,
            params.empty() ? nullptr : params.data(), params.size());
        if (!ok) return detail::kernel_error("assembly_pair_with");
        return {};
    }

    // Add a named state to this assembly: `rows` gives each joint's values, in its pair's
    // freedom order, in the caller's order. Refused, with the kernel's own message and the
    // assembly left unchanged, when a rule refuses it.
    Result<void> state(std::string_view name, const std::vector<StateRow>& rows) const {
        std::string owned_name(name);
        std::vector<std::string> joint_names;
        joint_names.reserve(rows.size());
        for (const StateRow& row : rows) joint_names.push_back(row.joint);
        std::vector<const char*> joint_pointers;
        joint_pointers.reserve(rows.size());
        for (const std::string& j : joint_names) joint_pointers.push_back(j.c_str());
        std::vector<std::uint32_t> counts;
        counts.reserve(rows.size());
        std::vector<double> flat;
        for (const StateRow& row : rows) {
            counts.push_back(static_cast<std::uint32_t>(row.values.size()));
            flat.insert(flat.end(), row.values.begin(), row.values.end());
        }
        bool ok = ::cadaclysm_blacksmith_assembly_state(
            raw_handle("assembly_state"), owned_name.c_str(), joint_pointers.empty() ? nullptr : joint_pointers.data(),
            counts.empty() ? nullptr : counts.data(), flat.empty() ? nullptr : flat.data(), rows.size());
        if (!ok) return detail::kernel_error("assembly_state");
        return {};
    }

    // This assembly in a pose: a NEW assembly, owned by the caller, with every placement
    // that follows a posed joint moved; this one is unchanged either way. `rows` are
    // StateRow's, but a row's joint is a path -- placement names then the joint name,
    // joined by "/", a "/" or "\" inside a name escaped with "\" -- and may be a bare joint
    // name when only one joint carries it. `state` starts from a named state of this
    // assembly (nullopt: none); `ground` names the link held still (nullopt: the base, else
    // the first). No rows is allowed. Refused, with the kernel's own message, when a rule
    // refuses it -- an ambiguous name, a value out of range, or two sides of a coupling
    // that disagree.
    Result<Assembly> posed(const std::vector<StateRow>& rows,
                           std::optional<std::string_view> state = std::nullopt,
                           std::optional<std::string_view> ground = std::nullopt) const {
        std::vector<const char*> joint_pointers;
        joint_pointers.reserve(rows.size());
        for (const StateRow& row : rows) joint_pointers.push_back(row.joint.c_str());
        std::vector<std::uint32_t> counts;
        counts.reserve(rows.size());
        std::vector<double> flat;
        for (const StateRow& row : rows) {
            counts.push_back(static_cast<std::uint32_t>(row.values.size()));
            flat.insert(flat.end(), row.values.begin(), row.values.end());
        }
        std::optional<std::string> owned_state = state ? std::optional<std::string>(*state) : std::nullopt;
        std::optional<std::string> owned_ground = ground ? std::optional<std::string>(*ground) : std::nullopt;
        CadaclysmBlacksmithAssembly* raw = ::cadaclysm_blacksmith_assembly_posed(
            raw_handle("assembly_posed"), joint_pointers.empty() ? nullptr : joint_pointers.data(),
            counts.empty() ? nullptr : counts.data(), flat.empty() ? nullptr : flat.data(), rows.size(),
            owned_state ? owned_state->c_str() : nullptr, owned_ground ? owned_ground->c_str() : nullptr);
        if (!raw) return detail::kernel_error("assembly_posed");
        return Assembly(raw);
    }

    // Add a named motion sequence over this assembly's states. It is closed unless the last
    // segment is "discontinuous"; `seconds` writes the parameter's unit as the second.
    // Refused, with the kernel's own message and the assembly left unchanged, when a rule
    // refuses it.
    Result<void> sequence(std::string_view name, const std::vector<SequenceSegment>& segments,
                          bool seconds = false) const {
        std::string owned_name(name);
        std::vector<const char*> states;
        std::vector<double> ts;
        std::vector<const char*> words;
        states.reserve(segments.size());
        ts.reserve(segments.size());
        words.reserve(segments.size());
        for (const SequenceSegment& segment : segments) {
            states.push_back(segment.state.c_str());
            ts.push_back(segment.t);
            words.push_back(segment.interpolation.c_str());
        }
        bool ok = ::cadaclysm_blacksmith_assembly_sequence(
            raw_handle("assembly_sequence"), owned_name.c_str(), states.empty() ? nullptr : states.data(),
            ts.empty() ? nullptr : ts.data(), words.empty() ? nullptr : words.data(), segments.size(), seconds);
        if (!ok) return detail::kernel_error("assembly_sequence");
        return {};
    }

    // Declare this assembly's base link. Refused, with the kernel's own message and the
    // assembly left unchanged, when a rule refuses it.
    Result<void> base(std::string_view link) const {
        std::string owned_link(link);
        if (!::cadaclysm_blacksmith_assembly_base(raw_handle("assembly_base"), owned_link.c_str())) {
            return detail::kernel_error("assembly_base");
        }
        return {};
    }

    // This assembly, and everything placed under it, as one STEP file: this assembly the
    // root product, each sub-assembly and each distinct part written once, each
    // placement an occurrence named as it was placed. `schema` and `unit` as
    // Solid::step_text. Refused if this assembly, or a sub-assembly reachable from it,
    // places nothing -- a reader would never show it.
    Result<std::string> step_text(const std::optional<std::string>& schema = std::nullopt,
                                  Unit unit = Unit::millimetre) const {
        std::optional<std::string> schema_text;
        if (schema) {
            std::optional<std::string> file = detail::schema_file(schema);
            if (file) {
                std::ifstream in(cadaclysm::detail::fs_path(*file), std::ios::binary);
                schema_text = std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
            } else {
                schema_text = *schema;
            }
        }
        char* raw = ::cadaclysm_blacksmith_assembly_step(raw_handle("assembly_step"),
                                                          schema_text ? schema_text->c_str() : nullptr,
                                                          static_cast<std::uint32_t>(unit));
        if (!raw) return detail::kernel_error("assembly_step");
        std::string out(raw);
        ::cadaclysm_blacksmith_string_free(raw);
        return out;
    }
    // This assembly written to a STEP file at `path`.
    Result<void> step(const std::string& path, const std::optional<std::string>& schema = std::nullopt,
                      Unit unit = Unit::millimetre) const {
        CADACLYSM_TRY(text, step_text(schema, unit));
        std::ofstream out(cadaclysm::detail::fs_path(path), std::ios::binary);
        if (!out) return detail::refuse("step: cannot write " + path);
        out.write(text.data(), static_cast<std::streamsize>(text.size()));
        if (!out) return detail::refuse("step: cannot write " + path);
        return {};
    }
    // This assembly as a reader Scene, through STEP text -- see Solid::to_scene.
    Result<cadaclysm::Scene> to_scene(const std::optional<std::string>& schema = std::nullopt) const {
        CADACLYSM_TRY(text, step_text(schema));
        cadaclysm::OpenOptions options;
        options.schema = detail::schema_file(schema);
        return cadaclysm::open_memory(text.data(), text.size(), "stp", options);
    }

    // The C handle, for code that calls the C ABI directly. Owned by this Assembly.
    const CadaclysmBlacksmithAssembly* handle() const noexcept { return ptr_.get(); }

private:
    struct Free {
        void operator()(CadaclysmBlacksmithAssembly* p) const noexcept { ::cadaclysm_blacksmith_assembly_free(p); }
    };

    explicit Assembly(CadaclysmBlacksmithAssembly* raw) : ptr_(raw) {}

    static Result<std::string> place_result(char* raw, const char* what) {
        if (!raw) return detail::kernel_error(what);
        std::string out(raw);
        ::cadaclysm_blacksmith_string_free(raw);
        return out;
    }

    CadaclysmBlacksmithAssembly* raw_handle(const char* what) const {
        if (!ptr_) cadaclysm::detail::bad_access(what, "the assembly is empty (moved from or closed)");
        return ptr_.get();
    }

    std::unique_ptr<CadaclysmBlacksmithAssembly, Free> ptr_;
};

// How many freedoms a pair kind has, so a caller can size Assembly::pair's ranges --
// see cadaclysm_blacksmith_pair_freedom_count. 0 for an unknown name, and for
// fully_constrained, which has none.
inline std::uint32_t pair_freedom_count(std::string_view kind) {
    std::string owned(kind);
    return ::cadaclysm_blacksmith_pair_freedom_count(owned.c_str());
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
