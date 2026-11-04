// cadaclysm_blacksmith.hpp -- the kernel's C ABI (cadaclysm_blacksmith.h) as C++17, on
// the object model cadaclysm_blacksmith.py has: Profile, Path, SweepPath, Frame, Solid,
// Workplane. Every call that can fail returns a Result; nothing throws. Solids are
// immutable: every operation returns a new one. Includes the reader, for
// Solid::from_node and Solid::to_scene.
#ifndef CADACLYSM_BLACKSMITH_HPP
#define CADACLYSM_BLACKSMITH_HPP

#include <cadaclysm_blacksmith.h>

#include "cadaclysm.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <functional>
#include <initializer_list>
#include <limits>
#include <map>
#include <memory>
#include <optional>
#include <variant>

namespace cadaclysm {
inline namespace CADACLYSM_ABI {
namespace blacksmith {

inline constexpr std::uint32_t NONE = CADACLYSM_BLACKSMITH_NONE;
// The tessellation tolerance every tolerance-taking call defaults to.
inline constexpr double DEFAULT_TOLERANCE = 0.05;
// ThicknessGauge, thickness() and Solid::thickness_at_face mesh at this tolerance unless told otherwise.
inline constexpr double THICKNESS_TOLERANCE = 0.01;
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

/// The tightest box aligned with a solid's principal axes of inertia (not a minimal box: where two
/// moments are equal the axes are a free choice). `axes` is three rows of three, row `i` the
/// direction of the extent `half[i]`; `centre` is the middle of the box, not the centroid.
struct OrientedBox {
    Vec3 centre = {};
    std::array<Vec3, 3> axes = {};
    Vec3 half = {};
};

/// A measured length beside an estimate of its error. Where `accuracy_met` is false the refinement
/// stopped before the accuracy asked for; `from_polyline` marks a sampled polyline, exact for its
/// points and not for what they were sampled from.
struct Length {
    double length = 0.0;
    double error = 0.0;
    bool accuracy_met = false;
    bool from_polyline = false;
};

/// The closest points between two solids' boundaries and what each lies on. `kind_a` and `kind_b`
/// are "face", "edge" or "vertex"; `index_*` is the kernel id of that face, edge or vertex; `edge_*`
/// is the index Solid::edges() and fillet use, present only for an edge that has a row there.
/// `refined` is true when the points were refined onto the exact geometry.
struct Closest {
    double distance = 0.0;
    Vec3 on_a = {};
    Vec3 on_b = {};
    std::string kind_a;
    std::uint32_t index_a = 0;
    std::optional<std::uint32_t> edge_a;
    std::string kind_b;
    std::uint32_t index_b = 0;
    std::optional<std::uint32_t> edge_b;
    bool refined = false;
};

/// A point a length of arc along an edge or a profile's outer loop, beside the unit tangent there.
/// `parameter` is the curve's own parameter on an edge; on a profile it is the side's own (a line's
/// 0..1, an arc's angle, a spline's parameter). `segment` is empty on a solid's edge; on a profile
/// it is the side the point lies on (the segment count for the implicit closing side). `error` is
/// an estimate of the arc length's error; `from_polyline` marks a sampled polyline.
struct At {
    Vec3 point = {};
    Vec3 tangent = {};
    double parameter = 0.0;
    std::optional<std::uint32_t> segment;
    double error = 0.0;
    bool from_polyline = false;
};

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
class RTree;
class Assembly;
class Workplane;
class CollisionHit;
class Collider;
class ThicknessGauge;
struct FaceThickness;
class Subd;
class Sketch;
class Tool;
class Stock;
class Job;
using Profiles = std::vector<std::reference_wrapper<const Profile>>;
using Solids = std::vector<std::reference_wrapper<const Solid>>;
// A profile on its frame: one section of Solid::loft_through, borrowed for the call.
using Section = std::pair<std::reference_wrapper<const Profile>, std::reference_wrapper<const Frame>>;
using Sections = std::vector<Section>;
// A path of poses for Collider::swept_clash and swept_clash(): each pose the frames clash()
// takes there, borrowed for the call.
using Poses = std::vector<std::vector<std::reference_wrapper<const Frame>>>;

namespace detail {
using cadaclysm::detail::text;

inline Error kernel_error(const char* fallback) {
    std::string message = text(::cadaclysm_blacksmith_last_error());
    if (message.empty()) message = fallback;
    return Error{std::move(message), Origin::kernel};
}

// A refusal that may name ids (a constraint, remove_entity, set_value, set_driving,
// update_reference, drag): the library's reason first -- under the wasm shims the next
// call clears it -- then a copy of report_ids. Every other refusal carries no ids: use
// kernel_error.
inline Error sketch_refusal(const CadaclysmBlacksmithSketch* handle, const char* what) {
    Error refusal = kernel_error(what);
    std::size_t n = 0;
    const std::uint32_t* p = ::cadaclysm_blacksmith_sketch_report_ids(handle, &n);
    if (p && n) refusal.ids.assign(p, p + n);
    return refusal;
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

inline Length length_of(const CadaclysmBlacksmithLength& raw) {
    return Length{raw.length, raw.error, raw.accuracy_met != 0, raw.from_polyline != 0};
}

inline At at_of(const CadaclysmBlacksmithAt& raw) {
    At a;
    a.point = {raw.point[0], raw.point[1], raw.point[2]};
    a.tangent = {raw.tangent[0], raw.tangent[1], raw.tangent[2]};
    a.parameter = raw.parameter;
    if (raw.segment != CADACLYSM_BLACKSMITH_NONE) a.segment = raw.segment;
    a.error = raw.error;
    a.from_polyline = raw.from_polyline != 0;
    return a;
}

// The samples of a divide, read into a vector. A null list is the call's failure, read from
// last_error under `call`; the list is freed on every path out, a failing read included, and
// the error is built before the free.
inline Result<std::vector<At>> samples_of(CadaclysmBlacksmithSamples* list, const char* call) {
    if (!list) return kernel_error(call);
    struct Free {
        void operator()(CadaclysmBlacksmithSamples* p) const noexcept { ::cadaclysm_blacksmith_samples_free(p); }
    };
    std::unique_ptr<CadaclysmBlacksmithSamples, Free> owned(list);
    std::uint32_t count = ::cadaclysm_blacksmith_samples_count(owned.get());
    std::vector<At> out;
    out.reserve(count);
    for (std::uint32_t i = 0; i < count; ++i) {
        CadaclysmBlacksmithAt raw{};
        if (!::cadaclysm_blacksmith_samples_at(owned.get(), i, &raw)) return kernel_error("samples_at");
        out.push_back(at_of(raw));
    }
    return out;
}

// The name of a containment code; any other answer is the library breaking its contract.
inline Result<std::string> containment_of(std::uint32_t code, const char* call) {
    switch (code) {
        case CADACLYSM_BLACKSMITH_OUTSIDE: return std::string("outside");
        case CADACLYSM_BLACKSMITH_INSIDE: return std::string("inside");
        case CADACLYSM_BLACKSMITH_ON: return std::string("on");
        default: break;
    }
    return refuse(std::string(call) + ": the library answered " + std::to_string(code) + ", not a containment code");
}

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

    // The same plane facing the other way: x and y swapped, z reversed.
    Frame flipped() const noexcept {
        Vec3 n = z();
        return Frame(origin(), y(), x(), {-n[0], -n[1], -n[2]});
    }
    // This frame turned `radians` about `axis` through its origin, right-handed
    // (Transform::rotation). A zero axis is refused.
    Result<Frame> rotated(double radians, const Vec3& axis) const;
    // The point `p` in this frame's coordinates.
    Vec3 to_local(const Vec3& p) const noexcept {
        Vec3 o = origin();
        Vec3 d{p[0] - o[0], p[1] - o[1], p[2] - o[2]};
        return {detail::dot(d, x()), detail::dot(d, y()), detail::dot(d, z())};
    }
    // How far `p` lies above the frame's plane, along its z: negative below.
    double distance_to(const Vec3& p) const noexcept {
        Vec3 o = origin();
        return detail::dot({p[0] - o[0], p[1] - o[1], p[2] - o[2]}, z());
    }
    // The point `p` dropped onto the frame's plane along its z.
    Vec3 closest_point(const Vec3& p) const noexcept {
        double d = distance_to(p);
        Vec3 n = z();
        return {p[0] - d * n[0], p[1] - d * n[1], p[2] - d * n[2]};
    }
    // The least-squares plane through `points` (three or more, not all on one line) as a
    // frame, and the largest distance any point lies off it. Fewer points, or points on one
    // line, are refused.
    static Result<std::pair<Frame, double>> fit(const std::vector<Vec3>& points) {
        std::vector<double> xyz;
        xyz.reserve(3 * points.size());
        for (const Vec3& p : points) xyz.insert(xyz.end(), p.begin(), p.end());
        std::array<double, 12> out{};
        double deviation = 0.0;
        // Never a null pointer, so no points are the library's "needs three points".
        const double none[1] = {0.0};
        if (!::cadaclysm_blacksmith_frame_fit(xyz.empty() ? none : xyz.data(), points.size(), out.data(), &deviation)) {
            return detail::kernel_error("frame_fit");
        }
        Result<Frame> frame = of(out);
        if (!frame) return frame.error();
        return std::pair<Frame, double>(std::move(frame).value(), deviation);
    }

    // The twelve numbers every call taking a frame reads.
    const std::array<double, 12>& raw() const noexcept { return v_; }

    bool operator==(const Frame& other) const noexcept { return v_ == other.v_; }
    bool operator!=(const Frame& other) const noexcept { return v_ != other.v_; }

private:
    friend class Solid;
    friend class Workplane;
    friend class GeometryValue;
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

// ---- transforms ---------------------------------------------------------------------

// How far from rigid, or from a similarity, a map may be and still be told one, by default.
inline constexpr double MAP_TOLERANCE = 1e-9;

// Which surfaces Solid::convert_to_nurbs rewrites as their exact NURBS.
enum class NurbsLevel : std::uint32_t {
    // The revolutions, extrusions and sums.
    procedural = CADACLYSM_BLACKSMITH_NURBS_PROCEDURAL,
    // Those and the cylinders, cones, spheres and tori: every curved face.
    analytic = CADACLYSM_BLACKSMITH_NURBS_ANALYTIC,
    // Everything, planes and edge curves too: a body made only of NURBS.
    all = CADACLYSM_BLACKSMITH_NURBS_ALL,
};

struct RigidParts;
struct SimilarityParts;
struct AffineParts;

// An affine map of space: a 4x4 matrix, row-major, its bottom row 0 0 0 1. An immutable
// value with nothing to free. `a * b` (and a.compose(b)) is `a` after `b`.
//
// The constructors and the decompositions are the library's own, so every wrapper computes
// them alike. A frame argument is a Frame or its twelve raw numbers (origin, x, y, z); the
// library squares up one within 1e-6 of right-handed and orthonormal and refuses any other.
class Transform {
public:
    // The identity.
    Transform() noexcept : m_{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1} {}
    static Transform identity() noexcept { return Transform(); }

    // The map 16 numbers state, row-major. Refuses a count other than 16, a number that is
    // not finite, and a bottom row other than 0 0 0 1.
    static Result<Transform> from_rows(std::initializer_list<double> rows) { return checked(rows.begin(), rows.size()); }
    static Result<Transform> from_rows(const std::vector<double>& rows) { return checked(rows.data(), rows.size()); }
    static Result<Transform> from_rows(const std::array<double, 16>& rows) { return checked(rows.data(), rows.size()); }
    // Four rows of four -- the reader's Matrix4 (Node::transform) among them.
    static Result<Transform> from_rows(const Matrix4& rows) {
        std::array<double, 16> flat{};
        for (std::size_t r = 0; r < 4; ++r) {
            for (std::size_t c = 0; c < 4; ++c) flat[4 * r + c] = rows[r][c];
        }
        return checked(flat.data(), flat.size());
    }

    // p + v.
    static Result<Transform> translation(const Vec3& v) {
        return made("transform_translation", [&](double* out) -> bool { return ::cadaclysm_blacksmith_transform_translation(v.data(), out); });
    }
    // A turn of `radians` about the line through `point` along `direction`, right-handed.
    static Result<Transform> rotation(const Vec3& point, const Vec3& direction, double radians) {
        const double axis[6] = {point[0], point[1], point[2], direction[0], direction[1], direction[2]};
        return made("transform_rotation", [&](double* out) -> bool { return ::cadaclysm_blacksmith_transform_rotation(axis, radians, out); });
    }
    // rotation about an AxisLine, as Solid::rotate takes it.
    static Result<Transform> rotation(const AxisLine& axis, double radians) { return rotation(axis[0], axis[1], radians); }
    // The reflection across `plane`, its z the normal.
    static Result<Transform> mirror(const Frame& plane) { return mirror(plane.raw()); }
    static Result<Transform> mirror(const std::array<double, 12>& plane) {
        return made("transform_mirror", [&](double* out) -> bool { return ::cadaclysm_blacksmith_transform_mirror(plane.data(), out); });
    }
    // A uniform scale by `k` about `centre`.
    static Result<Transform> scale(const Vec3& centre, double k) {
        return made("transform_scale", [&](double* out) -> bool { return ::cadaclysm_blacksmith_transform_scale(centre.data(), k, out); });
    }
    // A scale by `sx`, `sy`, `sz` along `frame`'s axes, about its origin.
    static Result<Transform> scale_xyz(const Frame& frame, double sx, double sy, double sz) {
        return scale_xyz(frame.raw(), sx, sy, sz);
    }
    static Result<Transform> scale_xyz(const std::array<double, 12>& frame, double sx, double sy, double sz) {
        return made("transform_scale_xyz",
                    [&](double* out) -> bool { return ::cadaclysm_blacksmith_transform_scale_xyz(frame.data(), sx, sy, sz, out); });
    }
    // Every point slid along `direction` by `factor` times its height above `plane`.
    // `direction` is normalised -- `factor` alone sets the slide -- and must lie in the plane.
    static Result<Transform> shear(const Frame& plane, const Vec3& direction, double factor) {
        return shear(plane.raw(), direction, factor);
    }
    static Result<Transform> shear(const std::array<double, 12>& plane, const Vec3& direction, double factor) {
        return made("transform_shear", [&](double* out) -> bool {
            return ::cadaclysm_blacksmith_transform_shear(plane.data(), direction.data(), factor, out);
        });
    }
    // The rigid map sending frame `a` onto frame `b`.
    static Result<Transform> plane_to_plane(const Frame& a, const Frame& b) { return plane_to_plane(a.raw(), b.raw()); }
    static Result<Transform> plane_to_plane(const std::array<double, 12>& a, const std::array<double, 12>& b) {
        return made("transform_plane_to_plane",
                    [&](double* out) -> bool { return ::cadaclysm_blacksmith_transform_plane_to_plane(a.data(), b.data(), out); });
    }
    // Coordinates in frame `from` to coordinates in frame `to`: a change of basis.
    static Result<Transform> change_basis(const Frame& from, const Frame& to) { return change_basis(from.raw(), to.raw()); }
    static Result<Transform> change_basis(const std::array<double, 12>& from, const std::array<double, 12>& to) {
        return made("transform_change_basis",
                    [&](double* out) -> bool { return ::cadaclysm_blacksmith_transform_change_basis(from.data(), to.data(), out); });
    }
    // The orthogonal projection onto `plane` -- singular by design.
    static Result<Transform> planar_projection(const Frame& plane) { return planar_projection(plane.raw()); }
    static Result<Transform> planar_projection(const std::array<double, 12>& plane) {
        return made("transform_planar_projection",
                    [&](double* out) -> bool { return ::cadaclysm_blacksmith_transform_planar_projection(plane.data(), out); });
    }
    // The parallel projection onto `plane` along `direction`, which must not lie in it.
    static Result<Transform> project_along(const Frame& plane, const Vec3& direction) { return project_along(plane.raw(), direction); }
    static Result<Transform> project_along(const std::array<double, 12>& plane, const Vec3& direction) {
        return made("transform_project_along", [&](double* out) -> bool {
            return ::cadaclysm_blacksmith_transform_project_along(plane.data(), direction.data(), out);
        });
    }

    // The 16 numbers, row-major.
    const std::array<double, 16>& rows() const noexcept { return m_; }

    // Where the map takes the point `p`.
    Vec3 point(const Vec3& p) const noexcept {
        const std::array<double, 16>& r = m_;
        return {r[0] * p[0] + r[1] * p[1] + r[2] * p[2] + r[3], r[4] * p[0] + r[5] * p[1] + r[6] * p[2] + r[7],
                r[8] * p[0] + r[9] * p[1] + r[10] * p[2] + r[11]};
    }

    // This map after `other`: other first, then this.
    Result<Transform> compose(const Transform& other) const {
        return made("transform_compose",
                    [&](double* out) -> bool { return ::cadaclysm_blacksmith_transform_compose(m_.data(), other.m_.data(), out); });
    }
    // compose: `a * b` is `a` after `b`, through the library, so a Result.
    Result<Transform> operator*(const Transform& other) const { return compose(other); }

    // The map undoing this one; refused for a singular map.
    Result<Transform> inverse() const {
        return made("transform_inverse", [&](double* out) -> bool { return ::cadaclysm_blacksmith_transform_inverse(m_.data(), out); });
    }

    // Whether the linear part is orthogonal (A^T A = I to `tolerance`): a rotation or a mirror.
    // Solid::transform is looser: it applies a map within 1e-6 of a similarity as that
    // similarity. Refused for a tolerance not finite or negative.
    Result<bool> is_rigid(double tolerance = MAP_TOLERANCE) const {
        std::uint32_t r = ::cadaclysm_blacksmith_transform_is_rigid(m_.data(), tolerance);
        if (r == NONE) return detail::kernel_error("transform_is_rigid");
        return r == 1;
    }
    // The scale k where the linear part is k times an orthogonal one (A^T A = k^2I to
    // `tolerance`, relative to k^2), else nullopt. Refused for a tolerance not finite or
    // negative.
    Result<std::optional<double>> is_similarity(double tolerance = MAP_TOLERANCE) const {
        double k = ::cadaclysm_blacksmith_transform_is_similarity(m_.data(), tolerance);
        if (std::isnan(k)) return detail::kernel_error("transform_is_similarity");
        if (k > 0) return std::optional<double>(k);
        return std::optional<double>();
    }
    // The translation and the orthogonal part of a rigid map, else nullopt.
    Result<std::optional<RigidParts>> decompose_rigid(double tolerance = MAP_TOLERANCE) const;
    // The translation, the orthogonal part and k of a similarity, else nullopt.
    Result<std::optional<SimilarityParts>> decompose_similarity(double tolerance = MAP_TOLERANCE) const;
    // The polar split: the linear part is rotation * axes * diag(stretch) * axes^T, `rotation`
    // carrying the mirror, `axes` a proper rotation whose columns are the stretch directions,
    // the stretches largest first. nullopt for a singular map or one stretched past 1e7:1,
    // which has no unique split.
    std::optional<AffineParts> decompose_affine() const;

    bool operator==(const Transform& other) const noexcept { return m_ == other.m_; }
    bool operator!=(const Transform& other) const noexcept { return m_ != other.m_; }

private:
    friend class Quaternion;
    // Sixteen numbers the library wrote: affine by construction.
    explicit Transform(const double* rows) noexcept {
        for (std::size_t i = 0; i < 16; ++i) m_[i] = rows[i] + 0.0;  // no -0.0 to print or compare
    }

    static Result<Transform> checked(const double* rows, std::size_t count) {
        if (count != 16) return detail::refuse("Transform: a matrix is 16 numbers, got " + std::to_string(count));
        for (std::size_t i = 0; i < 16; ++i) {
            if (!std::isfinite(rows[i])) return detail::refuse("Transform: not finite");
        }
        if (rows[12] != 0.0 || rows[13] != 0.0 || rows[14] != 0.0 || rows[15] != 1.0) {
            return detail::refuse("Transform: the bottom row must be 0 0 0 1 (a projective map is not affine)");
        }
        return Transform(rows);
    }

    template <class F>
    static Result<Transform> made(const char* what, F call) {
        std::array<double, 16> out{};
        if (!call(out.data())) return detail::kernel_error(what);
        return Transform(out.data());
    }

    std::array<double, 16> m_;
};

// Transform::decompose_rigid's answer.
struct RigidParts {
    Vec3 translation;
    Transform orthogonal;
};
// Transform::decompose_similarity's answer: the linear part is k times `orthogonal`.
struct SimilarityParts {
    Vec3 translation;
    Transform orthogonal;
    double k;
};
// Transform::decompose_affine's answer.
struct AffineParts {
    Vec3 translation;
    Transform rotation;
    Transform axes;
    Vec3 stretch;
};

inline Result<std::optional<RigidParts>> Transform::decompose_rigid(double tolerance) const {
    Result<bool> rigid = is_rigid(tolerance);
    if (!rigid) return rigid.error();
    if (!*rigid) return std::optional<RigidParts>();
    double out[19] = {};
    if (!::cadaclysm_blacksmith_transform_decompose_rigid(m_.data(), tolerance, out)) {
        return detail::kernel_error("transform_decompose_rigid");
    }
    return std::optional<RigidParts>(RigidParts{{out[0], out[1], out[2]}, Transform(out + 3)});
}

inline Result<std::optional<SimilarityParts>> Transform::decompose_similarity(double tolerance) const {
    Result<std::optional<double>> k = is_similarity(tolerance);
    if (!k) return k.error();
    if (!*k) return std::optional<SimilarityParts>();
    double out[20] = {};
    if (!::cadaclysm_blacksmith_transform_decompose_similarity(m_.data(), tolerance, out)) {
        return detail::kernel_error("transform_decompose_similarity");
    }
    return std::optional<SimilarityParts>(SimilarityParts{{out[0], out[1], out[2]}, Transform(out + 3), out[19]});
}

inline std::optional<AffineParts> Transform::decompose_affine() const {
    double out[38] = {};
    if (!::cadaclysm_blacksmith_transform_decompose_affine(m_.data(), out)) return std::nullopt;
    return AffineParts{{out[0], out[1], out[2]}, Transform(out + 3), Transform(out + 19), {out[35], out[36], out[37]}};
}

inline Result<Frame> Frame::rotated(double radians, const Vec3& axis) const {
    Result<Transform> turn = Transform::rotation(origin(), axis, radians);
    if (!turn) return turn.error();
    const std::array<double, 16>& r = turn->rows();
    std::function<Vec3(const Vec3&)> apply = [&r](const Vec3& d) -> Vec3 {
        return {r[0] * d[0] + r[1] * d[1] + r[2] * d[2], r[4] * d[0] + r[5] * d[1] + r[6] * d[2], r[8] * d[0] + r[9] * d[1] + r[10] * d[2]};
    };
    return make(origin(), apply(x()), apply(y()), apply(z()));
}

// A rotation as w + xi + yj + zk: an immutable value. q and -q are the same rotation; a
// non-unit one is normalised wherever it becomes a rotation, and a zero one is refused there.
// `a * b` turns by `b`, then `a`. Equality is by components, so q != -q although the two turn
// alike: to ask whether two do, compare their to_transform() rows to a tolerance.
class Quaternion {
public:
    // The identity, (1, 0, 0, 0).
    Quaternion() noexcept : q_{1, 0, 0, 0} {}
    // w + xi + yj + zk; refused unless all four are finite.
    static Result<Quaternion> make(double w, double x, double y, double z) {
        if (!std::isfinite(w) || !std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z)) {
            return detail::refuse("Quaternion: not finite");
        }
        const double q[4] = {w, x, y, z};
        return Quaternion(q);
    }

    // A turn of `radians` about `direction`.
    static Result<Quaternion> from_axis_angle(const Vec3& direction, double radians) {
        return made("quaternion_from_axis_angle", [&](double* out) -> bool {
            return ::cadaclysm_blacksmith_quaternion_from_axis_angle(direction.data(), radians, out);
        });
    }
    // The rotation in `t`'s linear part (its translation ignored); refused unless that is a
    // proper rotation, orthogonal to 1e-9. Take t.decompose_affine()->rotation first for a
    // rotation rounded to float32.
    static Result<Quaternion> from_transform(const Transform& t) {
        return made("quaternion_from_transform",
                    [&](double* out) -> bool { return ::cadaclysm_blacksmith_quaternion_from_transform(t.rows().data(), out); });
    }
    // From `a` (s = 0) to `b` (s = 1) the shorter way.
    static Result<Quaternion> slerp(const Quaternion& a, const Quaternion& b, double s) {
        return made("quaternion_slerp",
                    [&](double* out) -> bool { return ::cadaclysm_blacksmith_quaternion_slerp(a.q_.data(), b.q_.data(), s, out); });
    }

    // This rotation as a Transform fixing `centre`; refused for a zero quaternion.
    Result<Transform> to_transform(const Vec3& centre = {0, 0, 0}) const {
        return Transform::made("quaternion_to_transform", [&](double* out) -> bool {
            return ::cadaclysm_blacksmith_quaternion_to_transform(q_.data(), centre.data(), out);
        });
    }

    double w() const noexcept { return q_[0]; }
    double x() const noexcept { return q_[1]; }
    double y() const noexcept { return q_[2]; }
    double z() const noexcept { return q_[3]; }
    // w, x, y, z.
    const std::array<double, 4>& components() const noexcept { return q_; }

    // The length, scaled by the largest component first: squaring 1e200 overflows and 1e-170
    // underflows.
    double length() const noexcept { return norm(q_.data(), 4); }
    // The turn, in [0, 2pi].
    double angle() const noexcept { return 2.0 * std::atan2(norm(q_.data() + 1, 3), q_[0]); }
    // The turn's axis, nullopt for the identity.
    std::optional<Vec3> axis() const {
        double big = (std::max)({std::fabs(q_[1]), std::fabs(q_[2]), std::fabs(q_[3])});
        if (big == 0) return std::nullopt;
        Vec3 v = {q_[1] / big, q_[2] / big, q_[3] / big};
        double n = std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
        return Vec3{v[0] / n, v[1] / n, v[2] / n};
    }
    Quaternion conjugate() const noexcept {
        const double q[4] = {q_[0], -q_[1], -q_[2], -q_[3]};
        return Quaternion(q);
    }
    // The same rotation at unit length, scaled by its largest component before the square
    // root, so 1e200 and 1e-170 normalise. Refused for a zero quaternion.
    Result<Quaternion> normalized() const {
        double big = (std::max)({std::fabs(q_[0]), std::fabs(q_[1]), std::fabs(q_[2]), std::fabs(q_[3])});
        if (big == 0) return detail::refuse("Quaternion.normalized: the quaternion is zero");
        double v[4] = {q_[0] / big, q_[1] / big, q_[2] / big, q_[3] / big};
        double n = std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2] + v[3] * v[3]);
        const double q[4] = {v[0] / n, v[1] / n, v[2] / n, v[3] / n};
        return Quaternion(q);
    }
    // The Hamilton product: `a * b` turns by `b`, then `a`. A Result because a product of
    // huge components can overflow, which make refuses.
    Result<Quaternion> operator*(const Quaternion& o) const {
        const std::array<double, 4>& a = q_;
        const std::array<double, 4>& b = o.q_;
        return make(a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3], a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2],
                    a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1], a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0]);
    }

    bool operator==(const Quaternion& other) const noexcept { return q_ == other.q_; }
    bool operator!=(const Quaternion& other) const noexcept { return q_ != other.q_; }

private:
    explicit Quaternion(const double* q) noexcept : q_{q[0] + 0.0, q[1] + 0.0, q[2] + 0.0, q[3] + 0.0} {}

    static double norm(const double* v, std::size_t n) noexcept {
        double big = 0;
        for (std::size_t i = 0; i < n; ++i) big = (std::max)(big, std::fabs(v[i]));
        if (big == 0) return 0.0;
        double sum = 0;
        for (std::size_t i = 0; i < n; ++i) sum += (v[i] / big) * (v[i] / big);
        return big * std::sqrt(sum);
    }

    template <class F>
    static Result<Quaternion> made(const char* what, F call) {
        double out[4] = {};
        if (!call(out)) return detail::kernel_error(what);
        return Quaternion(out);
    }

    std::array<double, 4> q_;
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

// ---- value geometry -----------------------------------------------------------------

// A parameter range t0..t1, in either order: length() and swapped() keep the order, the set
// operations (grown, union_with, intersect) answer increasing. An immutable value, equal by
// its two numbers and hashable (std::hash). The values' angle and height ranges and the
// surfaces' domains are intervals.
class Interval {
public:
    // The range t0..t1; refused unless both are finite.
    static Result<Interval> make(double t0, double t1) {
        if (!std::isfinite(t0) || !std::isfinite(t1)) return detail::refuse("Interval: not finite");
        return Interval(Raw{}, t0, t1);
    }
    // An Interval, or two numbers, as an Interval; any other count is refused.
    static Result<Interval> of(const Interval& value) { return value; }
    static Result<Interval> of(const std::vector<double>& values) {
        if (values.size() != 2) return detail::refuse("Interval: an interval is 2 numbers, got " + std::to_string(values.size()));
        return make(values[0], values[1]);
    }

    // The two ends, as given.
    double t0() const noexcept { return t_[0]; }
    double t1() const noexcept { return t_[1]; }
    // t1 - t0: negative for a decreasing interval.
    double length() const noexcept { return t_[1] - t_[0]; }
    // The middle, (t0 + t1) / 2.
    double mid() const noexcept { return 0.5 * (t_[0] + t_[1]); }
    // The smaller and the larger end.
    double (min)() const noexcept { return t_[1] < t_[0] ? t_[1] : t_[0]; }
    double (max)() const noexcept { return t_[0] < t_[1] ? t_[1] : t_[0]; }
    // Whether t0 < t1.
    bool is_increasing() const noexcept { return t_[0] < t_[1]; }
    // Whether t0 == t1.
    bool is_singleton() const noexcept { return t_[0] == t_[1]; }
    // The interval t1..t0.
    Interval swapped() const noexcept { return Interval(Raw{}, t_[1], t_[0]); }
    // The increasing interval holding this one and `t`; refused for a `t` not finite.
    Result<Interval> grown(double t) const { return make(t < (min)() ? t : (min)(), (max)() < t ? t : (max)()); }
    // The increasing interval holding this one and `o` (Python's `union`, a C++ keyword).
    Interval union_with(const Interval& o) const noexcept {
        return Interval(Raw{}, o.min() < (min)() ? o.min() : (min)(), (max)() < o.max() ? o.max() : (max)());
    }
    // The increasing overlap with `o`; nothing where the two are apart. Two that touch give a
    // singleton.
    std::optional<Interval> intersect(const Interval& o) const noexcept {
        double a = (min)() < o.min() ? o.min() : (min)();
        double b = o.max() < (max)() ? o.max() : (max)();
        if (a <= b) return Interval(Raw{}, a, b);
        return std::nullopt;
    }
    // Whether `t` lies in the closed range, in either order.
    bool contains(double t) const noexcept { return (min)() <= t && t <= (max)(); }
    // t0 + s (t1 - t0): the fraction `s` of the way from t0; outside 0..1 extrapolates.
    double parameter_at(double s) const noexcept { return t_[0] + s * (t_[1] - t_[0]); }
    // The fraction of the way `t` lies from t0 toward t1; nothing for a singleton.
    std::optional<double> normalized_parameter_at(double t) const noexcept {
        double span = length();
        if (span != 0.0) return (t - t_[0]) / span;
        return std::nullopt;
    }

    // The hash std::hash<Interval> answers: equal intervals hash alike.
    std::size_t hash() const noexcept {
        std::size_t h = std::hash<double>()(t_[0]);
        return h ^ (std::hash<double>()(t_[1]) + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2));
    }

    bool operator==(const Interval& other) const noexcept { return t_ == other.t_; }
    bool operator!=(const Interval& other) const noexcept { return t_ != other.t_; }

private:
    friend class GeometryValue;
    // Two numbers known finite: no check.
    struct Raw {};
    Interval(Raw, double t0, double t1) noexcept : t_{t0 + 0.0, t1 + 0.0} {}  // + 0.0: no -0.0 to print or compare
    std::array<double, 2> t_;
};

// What a value's frame argument takes: a Frame, or its twelve raw numbers (origin, x, y, z),
// which the library squares up within 1e-6 of right-handed and orthonormal, or refuses.
struct FrameLike {
    FrameLike(const Frame& frame) : raw(frame.raw()) {}
    FrameLike(const std::array<double, 12>& numbers) : raw(numbers) {}
    std::array<double, 12> raw;
};

// What a value's range argument takes: an Interval, or two numbers -- `{0, 1}`.
struct IntervalLike {
    IntervalLike(const Interval& range) : t0(range.t0()), t1(range.t1()) {}
    IntervalLike(double start, double end) : t0(start), t1(end) {}
    double t0;
    double t1;
};

// The closest point of a curve value: its parameter `t`, the `point`, and `unique` -- false
// where several points lie equally near and `point` is a fixed pick among them (a point on
// a circle's axis, one equidistant from an arc's ends).
struct CurveFoot {
    double t = 0.0;
    Vec3 point{};
    bool unique = true;
};
inline bool operator==(const CurveFoot& l, const CurveFoot& r) { return l.t == r.t && l.point == r.point && l.unique == r.unique; }
inline bool operator!=(const CurveFoot& l, const CurveFoot& r) { return !(l == r); }

// The closest point of a surface value: its parameters `u`, `v`, the `point`, and `unique`
// -- false where several points lie equally near and `point` is a fixed pick among them (a
// sphere's centre, a point on an axis).
struct SurfaceFoot {
    double u = 0.0;
    double v = 0.0;
    Vec3 point{};
    bool unique = true;
};
inline bool operator==(const SurfaceFoot& l, const SurfaceFoot& r) {
    return l.u == r.u && l.v == r.v && l.point == r.point && l.unique == r.unique;
}
inline bool operator!=(const SurfaceFoot& l, const SurfaceFoot& r) { return !(l == r); }

// CADACLYSM_BLACKSMITH_VALUE_*: the kind each value's array is tagged with.
inline constexpr std::uint32_t VALUE_LINE = CADACLYSM_BLACKSMITH_VALUE_LINE;
inline constexpr std::uint32_t VALUE_CIRCLE = CADACLYSM_BLACKSMITH_VALUE_CIRCLE;
inline constexpr std::uint32_t VALUE_ARC = CADACLYSM_BLACKSMITH_VALUE_ARC;
inline constexpr std::uint32_t VALUE_ELLIPSE = CADACLYSM_BLACKSMITH_VALUE_ELLIPSE;
inline constexpr std::uint32_t VALUE_SPHERE = CADACLYSM_BLACKSMITH_VALUE_SPHERE;
inline constexpr std::uint32_t VALUE_CYLINDER = CADACLYSM_BLACKSMITH_VALUE_CYLINDER;
inline constexpr std::uint32_t VALUE_CONE = CADACLYSM_BLACKSMITH_VALUE_CONE;
inline constexpr std::uint32_t VALUE_TORUS = CADACLYSM_BLACKSMITH_VALUE_TORUS;
inline constexpr std::uint32_t VALUE_CUBOID = CADACLYSM_BLACKSMITH_VALUE_CUBOID;

namespace detail {
// The lower-case name of a value kind, for the wrapper's count refusal.
inline const char* value_name(std::uint32_t kind) {
    static const char* const names[9] = {"line", "circle", "arc", "ellipse", "sphere", "cylinder", "cone", "torus", "cuboid"};
    return kind < 9 ? names[kind] : "value";
}
// `values` checked and canonical (the frame squared up) by the library's value_check, a
// count other than value_size(kind) refused first in the library's own sentence.
inline Result<std::vector<double>> value_checked(std::uint32_t kind, const std::vector<double>& values) {
    std::uint32_t size = ::cadaclysm_blacksmith_value_size(kind);
    if (values.size() != size) {
        return refuse(std::string("value_check: a ") + value_name(kind) + " is " + std::to_string(size) + " numbers, got " +
                      std::to_string(values.size()));
    }
    std::vector<double> out(size);
    if (!::cadaclysm_blacksmith_value_check(kind, values.data(), out.data())) return kernel_error("value_check");
    return out;
}
// A frame's twelve numbers then `rest`.
inline std::vector<double> value_array(const FrameLike& frame, std::initializer_list<double> rest) {
    std::vector<double> v(frame.raw.begin(), frame.raw.end());
    v.insert(v.end(), rest.begin(), rest.end());
    return v;
}
// `points` as one flat xyz array.
inline std::vector<double> flat_points(const std::vector<Vec3>& points) {
    std::vector<double> xyz;
    xyz.reserve(3 * points.size());
    for (const Vec3& p : points) xyz.insert(xyz.end(), p.begin(), p.end());
    return xyz;
}
inline double distance(const Vec3& a, const Vec3& b) {
    Vec3 d{a[0] - b[0], a[1] - b[1], a[2] - b[2]};
    return std::sqrt(dot(d, d));
}
}  // namespace detail

// What every value shares: its kind, its canonical array (squared up by the library's
// value_check when it was made), its world box, and equality by kind and array -- a circle
// never equals a sphere with the same numbers. Immutable, with nothing to free.
class GeometryValue {
public:
    // The CADACLYSM_BLACKSMITH_VALUE_* kind.
    std::uint32_t kind() const noexcept { return kind_; }
    // The canonical numbers, in the C ABI's layout for the kind.
    const std::vector<double>& values() const noexcept { return v_; }
    // The exact world box, (min, max), from the closed form rather than from samples.
    Result<std::pair<Vec3, Vec3>> bounds() const {
        std::array<double, 6> out{};
        if (!::cadaclysm_blacksmith_value_bounds(kind_, v_.data(), out.data())) return detail::kernel_error("value_bounds");
        return std::pair<Vec3, Vec3>(Vec3{out[0], out[1], out[2]}, Vec3{out[3], out[4], out[5]});
    }
    // The hash std::hash answers for every value class: equal values hash alike.
    std::size_t hash() const noexcept {
        std::size_t h = std::hash<std::uint32_t>()(kind_);
        for (double c : v_) h ^= std::hash<double>()(c) + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2);
        return h;
    }

    friend bool operator==(const GeometryValue& a, const GeometryValue& b) noexcept { return a.kind_ == b.kind_ && a.v_ == b.v_; }
    friend bool operator!=(const GeometryValue& a, const GeometryValue& b) noexcept { return !(a == b); }

protected:
    GeometryValue(std::uint32_t kind, std::vector<double> values) : kind_(kind), v_(std::move(values)) {}

    // A T from `values`, checked by the library.
    template <class T>
    static Result<T> checked(const std::vector<double>& values) {
        Result<std::vector<double>> v = detail::value_checked(T::KIND, values);
        if (!v) return v.error();
        return T(std::move(v).value());
    }
    // A T from an array the library wrote: canonical already.
    template <class T>
    static Result<T> written(const char* what, bool ok, std::vector<double> out) {
        if (!ok) return detail::kernel_error(what);
        return T(std::move(out));
    }
    // This value under `t`, the same type.
    template <class T>
    Result<T> transformed(const Transform& t) const {
        std::vector<double> out(v_.size());
        bool ok = ::cadaclysm_blacksmith_value_transform(kind_, v_.data(), t.rows().data(), out.data());
        return written<T>("value_transform", ok, std::move(out));
    }
    // `n` numbers a call writes, or its refusal.
    template <std::size_t N, class F>
    static Result<std::array<double, N>> out(const char* what, F call) {
        std::array<double, N> o{};
        if (!call(o.data())) return detail::kernel_error(what);
        return o;
    }
    template <class F>
    static Result<Vec3> point_out(const char* what, F call) {
        Result<std::array<double, 3>> o = out<3>(what, call);
        if (!o) return o.error();
        return Vec3{(*o)[0], (*o)[1], (*o)[2]};
    }
    template <class F>
    static Result<double> number_out(const char* what, F call) {
        Result<std::array<double, 1>> o = out<1>(what, call);
        if (!o) return o.error();
        return (*o)[0];
    }
    // The frame in the first twelve numbers, exact as stored.
    Frame frame_of() const noexcept {
        return Frame({v_[0], v_[1], v_[2]}, {v_[3], v_[4], v_[5]}, {v_[6], v_[7], v_[8]}, {v_[9], v_[10], v_[11]});
    }
    // The interval in numbers `i` and `i + 1`, finite as checked.
    Interval interval_of(std::size_t i) const noexcept { return Interval(Interval::Raw{}, v_[i], v_[i + 1]); }

    std::uint32_t kind_;
    std::vector<double> v_;
};

// What every curve value (Line, Circle, Arc, Ellipse) shares.
class CurveValueBase : public GeometryValue {
public:
    // The point at `t`: a line's fraction of the way from start to end, a circle's and an
    // arc's angle from the frame's x toward its y, an ellipse's eccentric angle.
    Result<Vec3> point_at(double t) const {
        return point_out("curve_value_point_at",
                         [&](double* o) -> bool { return ::cadaclysm_blacksmith_curve_value_point_at(kind_, v_.data(), t, o); });
    }
    // The unit tangent at `t`, the way `t` grows.
    Result<Vec3> tangent_at(double t) const {
        return point_out("curve_value_tangent_at",
                         [&](double* o) -> bool { return ::cadaclysm_blacksmith_curve_value_tangent_at(kind_, v_.data(), t, o); });
    }
    // The length (an ellipse's perimeter, in closed form).
    Result<double> length() const {
        return number_out("curve_value_length",
                          [&](double* o) -> bool { return ::cadaclysm_blacksmith_curve_value_length(kind_, v_.data(), o); });
    }
    // The CurveFoot nearest `p`, exact for every kind, in closed form.
    Result<CurveFoot> closest_point(const Vec3& p) const {
        Result<std::array<double, 5>> f = out<5>("curve_value_closest_point", [&](double* o) -> bool {
            return ::cadaclysm_blacksmith_curve_value_closest_point(kind_, v_.data(), p.data(), o);
        });
        if (!f) return f.error();
        const std::array<double, 5>& a = *f;
        return CurveFoot{a[0], {a[1], a[2], a[3]}, a[4] != 0.0};
    }
    // How far `p` lies from the curve: the distance to its closest_point.
    Result<double> distance_to(const Vec3& p) const {
        Result<CurveFoot> foot = closest_point(p);
        if (!foot) return foot.error();
        return detail::distance(foot->point, p);
    }

protected:
    using GeometryValue::GeometryValue;
};

// What every shape with a volume (Sphere, Cylinder, Cone, Torus, Cuboid) shares.
class SolidValue : public GeometryValue {
public:
    // The Frame the value is placed on.
    Frame frame() const noexcept { return frame_of(); }
    // Whether `p` lies inside the closed shape or within `tolerance` of it. A tolerance not
    // finite or negative is refused.
    Result<bool> contains(const Vec3& p, double tolerance = 1e-9) const {
        std::uint32_t r = ::cadaclysm_blacksmith_solid_value_contains(kind_, v_.data(), p.data(), tolerance);
        if (r == NONE) return detail::kernel_error("solid_value_contains");
        return r == 1;
    }
    // The boundary's area, in closed form: a cylinder's and a cone's caps included.
    Result<double> area() const {
        return number_out("solid_value_area", [&](double* o) -> bool { return ::cadaclysm_blacksmith_solid_value_area(kind_, v_.data(), o); });
    }
    // The volume enclosed, in closed form.
    Result<double> volume() const {
        return number_out("solid_value_volume",
                          [&](double* o) -> bool { return ::cadaclysm_blacksmith_solid_value_volume(kind_, v_.data(), o); });
    }
    // The shape as a closed exact B-rep Solid, to join, cut and write.
    Result<Solid> to_solid() const;

protected:
    using GeometryValue::GeometryValue;
};

// What every surface value (Sphere, Cylinder, Cone, Torus) shares.
class SurfaceValue : public SolidValue {
public:
    // The point at (u, v), in the ranges domain() gives.
    Result<Vec3> point_at(double u, double v) const {
        return point_out("surface_value_point_at",
                         [&](double* o) -> bool { return ::cadaclysm_blacksmith_surface_value_point_at(kind_, v_.data(), u, v, o); });
    }
    // The outward unit normal at (u, v).
    Result<Vec3> normal_at(double u, double v) const {
        return point_out("surface_value_normal_at",
                         [&](double* o) -> bool { return ::cadaclysm_blacksmith_surface_value_normal_at(kind_, v_.data(), u, v, o); });
    }
    // The SurfaceFoot nearest `p` on the surface (a cylinder's and a cone's side, not their
    // caps), exact for every kind, in closed form.
    Result<SurfaceFoot> closest_point(const Vec3& p) const {
        Result<std::array<double, 6>> f = out<6>("surface_value_closest_point", [&](double* o) -> bool {
            return ::cadaclysm_blacksmith_surface_value_closest_point(kind_, v_.data(), p.data(), o);
        });
        if (!f) return f.error();
        const std::array<double, 6>& a = *f;
        return SurfaceFoot{a[0], a[1], {a[2], a[3], a[4]}, a[5] != 0.0};
    }
    // How far `p` lies from the surface: the distance to its closest_point.
    Result<double> distance_to(const Vec3& p) const {
        Result<SurfaceFoot> foot = closest_point(p);
        if (!foot) return foot.error();
        return detail::distance(foot->point, p);
    }
    // The u and v ranges, as two Intervals.
    Result<std::pair<Interval, Interval>> domain() const {
        Result<std::array<double, 4>> d = out<4>(
            "surface_value_domain", [&](double* o) -> bool { return ::cadaclysm_blacksmith_surface_value_domain(kind_, v_.data(), o); });
        if (!d) return d.error();
        Result<Interval> u = Interval::make((*d)[0], (*d)[1]);
        if (!u) return u.error();
        Result<Interval> w = Interval::make((*d)[2], (*d)[3]);
        if (!w) return w.error();
        return std::pair<Interval, Interval>(*u, *w);
    }
    // The surface alone, as an open sheet on its exact NURBS form.
    Result<Solid> to_nurbs_sheet() const;

protected:
    using SolidValue::SolidValue;
};

// The segment from `start` to `end`, as a value: construction geometry to measure, to project
// onto and to map, without building a solid. Its parameter runs 0..1.
class Line final : public CurveValueBase {
public:
    static constexpr std::uint32_t KIND = VALUE_LINE;
    // The segment from `start` to `end`; ends that coincide are refused.
    static Result<Line> make(const Vec3& start, const Vec3& end) {
        return checked<Line>({start[0], start[1], start[2], end[0], end[1], end[2]});
    }
    // The value from its 6 raw numbers, checked.
    static Result<Line> from_array(const std::vector<double>& values) { return checked<Line>(values); }

    // The two ends.
    Vec3 start() const noexcept { return {v_[0], v_[1], v_[2]}; }
    Vec3 end() const noexcept { return {v_[3], v_[4], v_[5]}; }
    // This line under `t`: any map that keeps its ends apart.
    Result<Line> transform(const Transform& t) const { return transformed<Line>(t); }

private:
    friend class GeometryValue;
    explicit Line(std::vector<double> values) : CurveValueBase(KIND, std::move(values)) {}
};

// The circle of `radius` about the frame's origin in its x-y plane, running counter-clockwise
// about its z from its x, as a value. Curve::value gives an edge's circle.
class Circle final : public CurveValueBase {
public:
    static constexpr std::uint32_t KIND = VALUE_CIRCLE;
    static Result<Circle> make(const FrameLike& frame, double radius) { return checked<Circle>(detail::value_array(frame, {radius})); }
    // The value from its 13 raw numbers, checked.
    static Result<Circle> from_array(const std::vector<double>& values) { return checked<Circle>(values); }
    // The circle through the points `a`, `b` and `c`: its x toward `a`, turning `a`, `b`, `c`
    // counter-clockwise. Three points on one line are refused.
    static Result<Circle> through(const Vec3& a, const Vec3& b, const Vec3& c) {
        std::vector<double> out(13);
        bool ok = ::cadaclysm_blacksmith_circle_through(a.data(), b.data(), c.data(), out.data());
        return written<Circle>("circle_through", ok, std::move(out));
    }

    // The Frame the circle lies on: its centre, the x its angles start from, its normal.
    Frame frame() const noexcept { return frame_of(); }
    // The radius.
    double radius() const noexcept { return v_[12]; }
    // This circle under `t`: a similarity only (Ellipse::from_circle first for any other map).
    Result<Circle> transform(const Transform& t) const { return transformed<Circle>(t); }

private:
    friend class GeometryValue;
    explicit Circle(std::vector<double> values) : CurveValueBase(KIND, std::move(values)) {}
};

// The part of a circle over `angle` (an Interval or two numbers, increasing, by at most a
// full turn), as a value: the circle's frame and radius, its angles measured from the frame's
// x toward its y. Curve::value gives an edge's arc.
class Arc final : public CurveValueBase {
public:
    static constexpr std::uint32_t KIND = VALUE_ARC;
    static Result<Arc> make(const FrameLike& frame, double radius, const IntervalLike& angle) {
        Result<Interval> a = Interval::make(angle.t0, angle.t1);
        if (!a) return a.error();
        return checked<Arc>(detail::value_array(frame, {radius, a->t0(), a->t1()}));
    }
    // The value from its 15 raw numbers, checked.
    static Result<Arc> from_array(const std::vector<double>& values) { return checked<Arc>(values); }
    // The arc from `a` through `b` to `c`. Three points on one line are refused.
    static Result<Arc> through(const Vec3& a, const Vec3& b, const Vec3& c) {
        std::vector<double> out(15);
        bool ok = ::cadaclysm_blacksmith_arc_through(a.data(), b.data(), c.data(), out.data());
        return written<Arc>("arc_through", ok, std::move(out));
    }
    // The arc leaving `a` along `tangent` and ending at `c`. A zero tangent, or a `c` on the
    // tangent's line, is refused.
    static Result<Arc> from_start_tangent_end(const Vec3& a, const Vec3& tangent, const Vec3& c) {
        std::vector<double> out(15);
        bool ok = ::cadaclysm_blacksmith_arc_from_start_tangent_end(a.data(), tangent.data(), c.data(), out.data());
        return written<Arc>("arc_from_start_tangent_end", ok, std::move(out));
    }

    // The Frame the arc's circle lies on.
    Frame frame() const noexcept { return frame_of(); }
    // The radius.
    double radius() const noexcept { return v_[12]; }
    // The angle range, an Interval.
    Interval angle() const noexcept { return interval_of(13); }
    // The points at the start, the end and halfway along.
    Result<Vec3> start() const { return point_at(v_[13]); }
    Result<Vec3> end() const { return point_at(v_[14]); }
    Result<Vec3> mid() const { return point_at(0.5 * (v_[13] + v_[14])); }
    // This arc under `t`: a similarity only.
    Result<Arc> transform(const Transform& t) const { return transformed<Arc>(t); }

private:
    friend class GeometryValue;
    explicit Arc(std::vector<double> values) : CurveValueBase(KIND, std::move(values)) {}
};

// The ellipse of radius `r1` along the frame's x and `r2` along its y, as a value. Unlike a
// circle it takes any affine map that keeps it an ellipse. Curve::value gives an edge's whole
// ellipse (an elliptical arc's range stays on the Curve).
class Ellipse final : public CurveValueBase {
public:
    static constexpr std::uint32_t KIND = VALUE_ELLIPSE;
    static Result<Ellipse> make(const FrameLike& frame, double r1, double r2) {
        return checked<Ellipse>(detail::value_array(frame, {r1, r2}));
    }
    // The value from its 14 raw numbers, checked.
    static Result<Ellipse> from_array(const std::vector<double>& values) { return checked<Ellipse>(values); }
    // `circle` as an ellipse of two equal radii, to map by a non-uniform scale or a shear.
    static Result<Ellipse> from_circle(const Circle& circle) {
        std::vector<double> out(14);
        bool ok = ::cadaclysm_blacksmith_ellipse_from_circle(circle.values().data(), out.data());
        return written<Ellipse>("ellipse_from_circle", ok, std::move(out));
    }

    // The Frame the ellipse lies on.
    Frame frame() const noexcept { return frame_of(); }
    // The radii along the frame's x and y.
    double r1() const noexcept { return v_[12]; }
    double r2() const noexcept { return v_[13]; }
    // This ellipse under `t`: any map that keeps it an ellipse.
    Result<Ellipse> transform(const Transform& t) const { return transformed<Ellipse>(t); }

private:
    friend class GeometryValue;
    explicit Ellipse(std::vector<double> values) : CurveValueBase(KIND, std::move(values)) {}
};

// A curve value, as Curve::value gives one.
using CurveValue = std::variant<Line, Circle, Arc, Ellipse>;

// The sphere of `radius` about the frame's origin, as a value: `u` the longitude from the
// frame's x, `v` the latitude toward its z.
class Sphere final : public SurfaceValue {
public:
    static constexpr std::uint32_t KIND = VALUE_SPHERE;
    static Result<Sphere> make(const FrameLike& frame, double radius) { return checked<Sphere>(detail::value_array(frame, {radius})); }
    // The value from its 13 raw numbers, checked.
    static Result<Sphere> from_array(const std::vector<double>& values) { return checked<Sphere>(values); }

    // The radius.
    double radius() const noexcept { return v_[12]; }
    // This sphere under `t`: a similarity only.
    Result<Sphere> transform(const Transform& t) const { return transformed<Sphere>(t); }

private:
    friend class GeometryValue;
    explicit Sphere(std::vector<double> values) : SurfaceValue(KIND, std::move(values)) {}
};

// The capped cylinder of `radius` about the frame's z over `height` (an increasing Interval
// along z, or two numbers), as a value: `u` the angle from the frame's x, `v` the height.
class Cylinder final : public SurfaceValue {
public:
    static constexpr std::uint32_t KIND = VALUE_CYLINDER;
    static Result<Cylinder> make(const FrameLike& frame, double radius, const IntervalLike& height) {
        Result<Interval> h = Interval::make(height.t0, height.t1);
        if (!h) return h.error();
        return checked<Cylinder>(detail::value_array(frame, {radius, h->t0(), h->t1()}));
    }
    // The value from its 15 raw numbers, checked.
    static Result<Cylinder> from_array(const std::vector<double>& values) { return checked<Cylinder>(values); }

    // The radius.
    double radius() const noexcept { return v_[12]; }
    // The range along the frame's z, an Interval.
    Interval height() const noexcept { return interval_of(13); }
    // This cylinder under `t`: a similarity only.
    Result<Cylinder> transform(const Transform& t) const { return transformed<Cylinder>(t); }

private:
    friend class GeometryValue;
    explicit Cylinder(std::vector<double> values) : SurfaceValue(KIND, std::move(values)) {}
};

// The capped cone of base `radius` on the frame's x-y plane, its apex `height` up its z, as a
// value: `u` the angle from the frame's x, `v` the height.
class Cone final : public SurfaceValue {
public:
    static constexpr std::uint32_t KIND = VALUE_CONE;
    static Result<Cone> make(const FrameLike& frame, double radius, double height) {
        return checked<Cone>(detail::value_array(frame, {radius, height}));
    }
    // The value from its 14 raw numbers, checked.
    static Result<Cone> from_array(const std::vector<double>& values) { return checked<Cone>(values); }

    // The base radius.
    double radius() const noexcept { return v_[12]; }
    // How far up the frame's z the apex lies.
    double height() const noexcept { return v_[13]; }
    // This cone under `t`: a similarity only.
    Result<Cone> transform(const Transform& t) const { return transformed<Cone>(t); }

private:
    friend class GeometryValue;
    explicit Cone(std::vector<double> values) : SurfaceValue(KIND, std::move(values)) {}
};

// The torus of `major` radius about the frame's z and `minor` radius about that circle, as a
// value: `u` the angle about the z from the frame's x, `v` the angle about the tube.
class Torus final : public SurfaceValue {
public:
    static constexpr std::uint32_t KIND = VALUE_TORUS;
    static Result<Torus> make(const FrameLike& frame, double major, double minor) {
        return checked<Torus>(detail::value_array(frame, {major, minor}));
    }
    // The value from its 14 raw numbers, checked.
    static Result<Torus> from_array(const std::vector<double>& values) { return checked<Torus>(values); }

    // The radius of the tube's centre circle, and the tube's own.
    double major() const noexcept { return v_[12]; }
    double minor() const noexcept { return v_[13]; }
    // This torus under `t`: a similarity only.
    Result<Torus> transform(const Transform& t) const { return transformed<Torus>(t); }

private:
    friend class GeometryValue;
    explicit Torus(std::vector<double> values) : SurfaceValue(KIND, std::move(values)) {}
};

// The box over `x`, `y`, `z` (increasing Intervals, or pairs) along its frame's axes, as a
// value: an oriented bounding box, a region to test points against, a block to make a solid of.
class Cuboid final : public SolidValue {
public:
    static constexpr std::uint32_t KIND = VALUE_CUBOID;
    static Result<Cuboid> make(const FrameLike& frame, const IntervalLike& x, const IntervalLike& y, const IntervalLike& z) {
        Result<Interval> rx = Interval::make(x.t0, x.t1);
        if (!rx) return rx.error();
        Result<Interval> ry = Interval::make(y.t0, y.t1);
        if (!ry) return ry.error();
        Result<Interval> rz = Interval::make(z.t0, z.t1);
        if (!rz) return rz.error();
        return checked<Cuboid>(detail::value_array(frame, {rx->t0(), rx->t1(), ry->t0(), ry->t1(), rz->t0(), rz->t1()}));
    }
    // The value from its 18 raw numbers, checked.
    static Result<Cuboid> from_array(const std::vector<double>& values) { return checked<Cuboid>(values); }
    // The world-aligned box from `min` to `max`; an empty or flat one is refused.
    static Result<Cuboid> from_bounds(const Vec3& lo, const Vec3& hi) {
        std::vector<double> out(18);
        bool ok = ::cadaclysm_blacksmith_cuboid_from_bounds(lo.data(), hi.data(), out.data());
        return written<Cuboid>("cuboid_from_bounds", ok, std::move(out));
    }
    // The tightest box holding `points`, aligned to `frame`. No points, or points flat along
    // one of the frame's axes (a sheet, not a box), are refused.
    static Result<Cuboid> around(const FrameLike& frame, const std::vector<Vec3>& points) {
        std::vector<double> xyz = detail::flat_points(points);
        std::vector<double> out(18);
        const double none[1] = {0.0};  // never a null pointer: no points are the library's "no points"
        bool ok = ::cadaclysm_blacksmith_cuboid_around(frame.raw.data(), xyz.empty() ? none : xyz.data(), points.size(), out.data());
        return written<Cuboid>("cuboid_around", ok, std::move(out));
    }

    // The three ranges along the frame's axes, as Intervals.
    Interval x() const noexcept { return interval_of(12); }
    Interval y() const noexcept { return interval_of(14); }
    Interval z() const noexcept { return interval_of(16); }
    // The eight corners: the z0 face counter-clockwise about the frame's z from (x0, y0),
    // then the z1 face in the same order.
    Result<std::array<Vec3, 8>> corners() const {
        Result<std::array<double, 24>> c =
            out<24>("cuboid_corners", [&](double* o) -> bool { return ::cadaclysm_blacksmith_cuboid_corners(v_.data(), o); });
        if (!c) return c.error();
        std::array<Vec3, 8> points{};
        for (std::size_t k = 0; k < 8; ++k) points[k] = Vec3{(*c)[3 * k], (*c)[3 * k + 1], (*c)[3 * k + 2]};
        return points;
    }
    // The point the fractions `sx`, `sy`, `sz` of the way along each range.
    Result<Vec3> point_at(double sx, double sy, double sz) const {
        return point_out("cuboid_point_at",
                         [&](double* o) -> bool { return ::cadaclysm_blacksmith_cuboid_point_at(v_.data(), sx, sy, sz, o); });
    }
    // The closest point of the solid box: `p` itself inside.
    Result<Vec3> closest_point(const Vec3& p) const {
        return point_out("cuboid_closest_point",
                         [&](double* o) -> bool { return ::cadaclysm_blacksmith_cuboid_closest_point(v_.data(), p.data(), o); });
    }
    // This box under `t`: a similarity only.
    Result<Cuboid> transform(const Transform& t) const { return transformed<Cuboid>(t); }

private:
    friend class GeometryValue;
    explicit Cuboid(std::vector<double> values) : SolidValue(KIND, std::move(values)) {}
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

    // This curve as a value: a line Line(origin, origin + x); a circle a Circle over a full
    // turn, else the Arc over t0..t1; an ellipse its whole Ellipse (the range stays here: there
    // is no elliptical-arc value); any other kind nothing.
    Result<std::optional<CurveValue>> value() const;
};

namespace detail {
template <class T>
inline Result<std::optional<CurveValue>> curve_value_of(Result<T> made) {
    if (!made) return made.error();
    return std::optional<CurveValue>(CurveValue(std::move(made).value()));
}
}  // namespace detail

inline Result<std::optional<CurveValue>> Curve::value() const {
    const std::array<double, 12> frame = {origin[0], origin[1], origin[2], x[0], x[1], x[2], y[0], y[1], y[2], z[0], z[1], z[2]};
    if (kind == "line") return detail::curve_value_of(Line::make(origin, {origin[0] + x[0], origin[1] + x[1], origin[2] + x[2]}));
    if (kind == "circle") {
        if (t1 - t0 >= 2 * 3.14159265358979323846 - 1e-12) return detail::curve_value_of(Circle::make(frame, radius));
        return detail::curve_value_of(Arc::make(frame, radius, {t0, t1}));
    }
    if (kind == "ellipse") return detail::curve_value_of(Ellipse::make(frame, radius, radius2));
    return std::optional<CurveValue>();
}

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
// point) -- empty for a partial overlap of curved faces whose outlines cross.
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

// An intersection handle read out into an Intersection and freed on every path out, a failing
// read included -- Solid::intersect's reader, and Clash::intersect's. Null is `call`'s failure,
// read from last_error.
inline Result<Intersection> intersection_of(CadaclysmBlacksmithIntersection* found, const char* call) {
    if (!found) return kernel_error(call);
    struct Free {
        CadaclysmBlacksmithIntersection* p;
        ~Free() { ::cadaclysm_blacksmith_intersection_free(p); }
    } release{found};
    Intersection out;
    std::uint32_t n = ::cadaclysm_blacksmith_intersection_chain_count(found);
    out.chains.reserve(n);
    for (std::uint32_t i = 0; i < n; ++i) {
        CadaclysmBlacksmithChain raw{};
        if (!::cadaclysm_blacksmith_intersection_chain(found, i, &raw)) return kernel_error("intersection_chain");
        std::optional<Curve> curve;
        if (raw.has_curve) {
            CadaclysmBlacksmithCurve raw_curve{};
            if (!::cadaclysm_blacksmith_intersection_curve(found, i, &raw_curve)) return kernel_error("intersection_curve");
            curve = curve_of(raw_curve);
        }
        out.chains.push_back(chain_of(raw, std::move(curve)));
    }
    n = ::cadaclysm_blacksmith_intersection_overlap_count(found);
    out.overlaps.reserve(n);
    for (std::uint32_t i = 0; i < n; ++i) {
        CadaclysmBlacksmithOverlap raw{};
        if (!::cadaclysm_blacksmith_intersection_overlap(found, i, &raw)) return kernel_error("intersection_overlap");
        out.overlaps.push_back(overlap_of(raw));
    }
    return out;
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
    // A regular polygon of `sides` sides (at least 3) whose sides touch the circle of `radius`
    // about `centre` -- the polygon across flats, a nut's hex: its corners on the circle of
    // `radius / cos(pi / sides)`, the first at `angle` radians from the sketch's x axis, the rest
    // counter-clockwise, on the same rays as regular_polygon's corners with the same `angle`; each
    // side's midpoint on the circle of `radius`.
    static Result<Profile> circumscribed_polygon(const Vec2& centre, double radius, std::uint32_t sides, double angle = 0.0) {
        return wrap(::cadaclysm_blacksmith_profile_circumscribed_polygon(centre[0], centre[1], radius, sides, angle),
                    "profile_circumscribed_polygon");
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
    // This outline turned `radians` (counter-clockwise) about `centre`.
    Result<Profile> rotate(const Vec2& centre, double radians) const {
        return wrap(::cadaclysm_blacksmith_profile_rotate(ptr(), centre[0], centre[1], radians), "profile_rotate");
    }
    // This outline scaled by `sx`, `sy` about `centre`: an arc stays an arc where the two are
    // equal in size, and becomes exact conics otherwise. A negative factor mirrors; a zero one
    // is singular and refused.
    Result<Profile> scale(const Vec2& centre, double sx, double sy) const {
        return wrap(::cadaclysm_blacksmith_profile_scale(ptr(), centre[0], centre[1], sx, sy), "profile_scale");
    }
    // This outline reflected across the line through `point` along `direction`; a zero
    // direction is refused.
    Result<Profile> mirror(const Vec2& point, const Vec2& direction) const {
        return wrap(::cadaclysm_blacksmith_profile_mirror(ptr(), point[0], point[1], direction[0], direction[1]), "profile_mirror");
    }
    // This outline under the 2D affine map `m`, six numbers row-major (2x3):
    // x' = m0 x + m1 y + m2, y' = m3 x + m4 y + m5. A singular map is refused.
    Result<Profile> transform2d(const std::array<double, 6>& m) const {
        return wrap(::cadaclysm_blacksmith_profile_transform2d(ptr(), m.data()), "profile_transform2d");
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

    // The perimeter of the outer loop -- holes are not counted -- beside an estimate of its
    // error. `accuracy` 0 or less takes the default.
    Result<Length> length(double accuracy = 0.0) const {
        CadaclysmBlacksmithLength out{};
        if (!::cadaclysm_blacksmith_profile_length(ptr(), accuracy, &out)) return detail::kernel_error("profile_length");
        return detail::length_of(out);
    }

    // The point `s` of arc length along the outer loop from its start, with its unit tangent.
    // `accuracy` 0 or less takes the default.
    Result<At> point_at_length(double s, double accuracy = 0.0) const {
        CadaclysmBlacksmithAt out{};
        if (!::cadaclysm_blacksmith_profile_point_at_length(ptr(), s, accuracy, &out)) {
            return detail::kernel_error("profile_point_at_length");
        }
        return detail::at_of(out);
    }
    // `n` points evenly spaced by arc length round the outer loop from its start (a closed loop
    // gives `n`, an open one `n + 1`); `n` is 1 to 1000000.
    Result<std::vector<At>> divide_by_count(std::uint32_t n, double accuracy = 0.0) const {
        return detail::samples_of(::cadaclysm_blacksmith_profile_divide_by_count(ptr(), n, accuracy),
                                  "profile_divide_by_count");
    }
    // Points every `step` of arc length from the start of the outer loop; the last piece is kept
    // short and a closed start is not repeated.
    Result<std::vector<At>> divide_by_length(double step, double accuracy = 0.0) const {
        return detail::samples_of(::cadaclysm_blacksmith_profile_divide_by_length(ptr(), step, accuracy),
                                  "profile_divide_by_length");
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

// A solid's point-containment test, built once and asked many times (Solid::classifier). It
// keeps its own reference to the body, so it goes on answering after its Solid is closed.
// Move-only; the destructor frees it, as close() does early.
class Classifier {
public:
    Classifier(Classifier&&) noexcept = default;
    Classifier& operator=(Classifier&&) noexcept = default;
    Classifier(const Classifier&) = delete;
    Classifier& operator=(const Classifier&) = delete;

    void close() noexcept { ptr_.reset(); }
    bool closed() const noexcept { return !ptr_; }

    // "outside", "inside" or "on": which side of the solid's boundary `point` lies, "on" being
    // within the tolerance the classifier was built with.
    Result<std::string> contains(const Vec3& point) const {
        if (!ptr_) return detail::refuse("classifier: closed");
        std::uint32_t code = 0;
        if (!::cadaclysm_blacksmith_classifier_contains(ptr_.get(), point.data(), &code)) {
            return detail::kernel_error("classifier_contains");
        }
        return detail::containment_of(code, "classifier_contains");
    }

    // The C handle, for code that calls the C ABI directly. Owned by this Classifier.
    const CadaclysmBlacksmithClassifier* handle() const noexcept { return ptr_.get(); }

private:
    friend class Solid;
    struct Free {
        void operator()(CadaclysmBlacksmithClassifier* p) const noexcept { ::cadaclysm_blacksmith_classifier_free(p); }
    };
    explicit Classifier(CadaclysmBlacksmithClassifier* raw) : ptr_(raw) {}

    std::unique_ptr<CadaclysmBlacksmithClassifier, Free> ptr_;
};

// One side of one face (Solid::regions): `face` the face's index in the solid, `sense` +1 for the
// side its normal points to, -1 for the other. A solid's inside is behind its faces, at -1.
// Python's FaceSide.
struct FaceSide {
    std::uint32_t face = 0;
    std::int32_t sense = 0;
};
inline bool operator==(const FaceSide& l, const FaceSide& r) { return l.face == r.face && l.sense == r.sense; }
inline bool operator!=(const FaceSide& l, const FaceSide& r) { return !(l == r); }

// One region of space a solid's faces bound (Solid::regions): its `index` (0 the infinite region,
// whose `finite` is false), the `box` round the faces bounding it, its `sides` ascending by face
// then sense, and its `shells` -- 1, plus one per void inside it. Solid::region_solid takes a
// finite one as a solid of its own. A value, equal by value. Python's Region.
struct Region {
    std::uint32_t index = 0;
    bool finite = false;
    Box box{};
    std::vector<FaceSide> sides;
    std::uint32_t shells = 0;
};
inline bool operator==(const Region& l, const Region& r) {
    return l.index == r.index && l.finite == r.finite && l.box == r.box && l.sides == r.sides && l.shells == r.shells;
}
inline bool operator!=(const Region& l, const Region& r) { return !(l == r); }

namespace detail {
// A solid's regions, read into a vector. A null list is regions' failure, read from last_error;
// the list is freed on every path out, a failing read included, and the error is built before
// the free.
inline Result<std::vector<Region>> regions_of(CadaclysmBlacksmithRegions* list) {
    if (!list) return kernel_error("regions");
    struct Free {
        void operator()(CadaclysmBlacksmithRegions* p) const noexcept { ::cadaclysm_blacksmith_regions_free(p); }
    };
    std::unique_ptr<CadaclysmBlacksmithRegions, Free> owned(list);
    std::uint32_t count = ::cadaclysm_blacksmith_regions_count(owned.get());
    std::vector<Region> out;
    out.reserve(count);
    for (std::uint32_t i = 0; i < count; ++i) {
        CadaclysmBlacksmithRegion raw{};
        if (!::cadaclysm_blacksmith_regions_at(owned.get(), i, &raw)) return kernel_error("regions_at");
        Region region;
        region.index = i;
        region.finite = raw.finite != 0;
        region.box = Box({raw.min[0], raw.min[1], raw.min[2]}, {raw.max[0], raw.max[1], raw.max[2]});
        region.shells = raw.shells;
        region.sides.reserve(raw.sides);
        for (std::uint32_t k = 0; k < raw.sides; ++k) {
            CadaclysmBlacksmithFaceSide side{};
            if (!::cadaclysm_blacksmith_regions_side_at(owned.get(), i, k, &side)) return kernel_error("regions_side_at");
            region.sides.push_back(FaceSide{side.face, side.sense});
        }
        out.push_back(std::move(region));
    }
    return out;
}
}  // namespace detail


// ---- health and healing: Solid::health and Solid::healed's reports, plain data, the kernel's own
// set (the reader's cadaclysm::HealthReport and friends are the same shapes).
// One free edge (a side only one face bounds), a row of HealthReport::free_edges: its
// `trim` (the face's side), the `edge` it lies on (nullopt for a side with no edge), the
// `face` and free `wire` it is on, its nearest `partner` -- a row of free_edges, nullopt if
// there is none -- how many of its two ends it `shared_ends` with that partner (2 is what
// Solid::join_sheets joins), its `length` and the `gap` to the partner (infinite without one).
struct FreeEdge {
    std::uint32_t trim = 0;
    std::optional<std::uint32_t> edge;
    std::uint32_t face = 0;
    std::uint32_t wire = 0;
    std::optional<std::uint32_t> partner;
    std::uint32_t shared_ends = 0;
    double length = 0.0;
    double gap = 0.0;
};

// A chain of free edges end to end: the rows `first` to `first + count` of
// HealthReport::free_edges, whether it `closed` on itself, its total `length` and the
// `widest_gap` from any of its edges to a partner.
struct FreeWire {
    std::uint32_t first = 0;
    std::uint32_t count = 0;
    bool closed = false;
    double length = 0.0;
    double widest_gap = 0.0;
};

// Something below the tolerance: `kind` is "short_edge", "collapsed_edge", "sliver_face",
// "tiny_face", "tiny_body" or "small_hole"; `index` its edge, face, body or loop number;
// `size` how small.
struct SmallFeature {
    std::string kind;
    std::uint32_t index = 0;
    double size = 0.0;
};

// What a mesh of the body shows (Solid::health with `mesh`): whether it is `watertight`,
// how many mesh edges are `open` or `folded`, how many `crossings`, and the brep `edges`
// it cracks along. Only a closed body is counted: an open one's census is empty by design.
struct Cracks {
    bool watertight = false;
    std::uint32_t open = 0;
    std::uint32_t folded = 0;
    std::uint32_t crossings = 0;
    std::vector<std::uint32_t> edges;
};

// What is wrong with a body, as plain data (Solid::health): the `tolerance` and `rounding`
// it judged at and the body's `extent`; the free edges, their wires, the features below
// the tolerance; the loose edges (`worst_loose` the widest gap); what sewing would do
// (`sew_pairs` joined, `sew_refused`, `sew_worst_gap`); and, if asked for with `mesh`, the
// mesh's `cracks` (nullopt otherwise). `worst_gap` is the widest gap between a free edge
// and its partner.
struct HealthReport {
    double tolerance = 0.0;
    double rounding = 0.0;
    double extent = 0.0;
    std::vector<FreeEdge> free_edges;
    std::vector<FreeWire> wires;
    std::vector<SmallFeature> small;
    std::uint32_t loose_edges = 0;
    double worst_loose = 0.0;
    std::uint32_t sew_pairs = 0;
    std::uint32_t sew_refused = 0;
    double sew_worst_gap = 0.0;
    std::optional<Cracks> cracks;
    double worst_gap = 0.0;

    // The free edges of wire number `wire`, in order; refused for a wire there is not.
    Result<std::vector<FreeEdge>> wire_edges(std::uint32_t wire) const {
        if (wire >= wires.size()) {
            return Error{"wire_edges: wire " + std::to_string(wire) + " is not one of the " + std::to_string(wires.size()),
                         Origin::kernel};
        }
        const FreeWire& w = wires[wire];
        std::size_t first = std::min<std::size_t>(w.first, free_edges.size());
        std::size_t last = std::min<std::size_t>(first + w.count, free_edges.size());
        return std::vector<FreeEdge>(free_edges.begin() + static_cast<std::ptrdiff_t>(first),
                                     free_edges.begin() + static_cast<std::ptrdiff_t>(last));
    }
};

// One small feature Solid::healed removed: its `kind` (as SmallFeature::kind), its `index`
// in the input (the edge, face or loop number health() gave it), its `size`, and how far
// the vertices it merged `moved`.
struct HealFix {
    std::string kind;
    std::uint32_t index = 0;
    double size = 0.0;
    double moved = 0.0;
};

// One small feature Solid::healed left, and why: `kind` and `index` as in HealFix; `why` is
// "would_empty_loop", "closed", "seam", "chain", "neighbours_part", "uneven",
// "non_manifold", "has_holes", "body_guard", "toggled" or "unsupported"; `figure` the
// chain's width or the neighbours' gap, else 0.
struct HealRefusal {
    std::string kind;
    std::uint32_t index = 0;
    std::string why;
    double figure = 0.0;
};

// What Solid::healed did, as plain data: the `tolerance` it healed at, the furthest any
// trim `moved`, whether the body guard refused fixes (`guarded`), the `fixes` made and
// the features `refused`; and the body's health before and after at that tolerance -- its
// small features, free edges, whether it is closed, and its non-manifold edges.
struct HealReport {
    double tolerance = 0.0;
    double moved = 0.0;
    bool guarded = false;
    std::vector<HealFix> fixes;
    std::vector<HealRefusal> refused;
    std::uint32_t small_before = 0;
    std::uint32_t small_after = 0;
    std::uint32_t free_before = 0;
    std::uint32_t free_after = 0;
    bool closed_before = false;
    bool closed_after = false;
    std::uint32_t nonmanifold_before = 0;
    std::uint32_t nonmanifold_after = 0;
};

namespace detail {
// The kinds a SmallFeature, HealFix or HealRefusal names, by the C ABI's number; the
// reasons a HealRefusal gives, likewise.
inline constexpr const char* HEALTH_KINDS[6] = {"short_edge", "collapsed_edge", "sliver_face", "tiny_face", "tiny_body", "small_hole"};
inline constexpr const char* HEAL_WHYS[11] = {"would_empty_loop", "closed",       "seam",       "chain",   "neighbours_part", "uneven",
                                              "non_manifold",     "has_holes",    "body_guard", "toggled", "unsupported"};

// Solid::healed's switches as the C ABI's flag bits: 1 edges, 2 faces, 4 holes.
inline std::uint32_t heal_flags(bool edges, bool faces, bool holes) {
    return (edges ? 1u : 0u) | (faces ? 2u : 0u) | (holes ? 4u : 0u);
}

inline Result<std::string> health_kind(std::uint32_t kind, const char* call) {
    if (kind >= 6) return Error{std::string(call) + ": kind " + std::to_string(kind) + " is not one of the six", Origin::kernel};
    return std::string(HEALTH_KINDS[kind]);
}

// The flat rows of cadaclysm_blacksmith_health_summary and the row readers, in their order:
// counts (18) and sizes (8); free edges 6 ids and 2 sizes a row; wires 3 and 2; small
// features 2 and 1; the crack edges. cracks is read only where counts[12] says meshed.
inline Result<HealthReport> health_report(const std::uint32_t (&counts)[18], const double (&sizes)[8],
                                          const std::vector<std::uint32_t>& free_ids, const std::vector<double>& free_sizes,
                                          const std::vector<std::uint32_t>& wire_runs, const std::vector<double>& wire_sizes,
                                          const std::vector<std::uint32_t>& small_items, const std::vector<double>& small_sizes,
                                          const std::vector<std::uint32_t>& crack_edges) {
    HealthReport r;
    r.tolerance = sizes[0];
    r.rounding = sizes[1];
    r.extent = sizes[2];
    r.worst_gap = sizes[3];
    r.worst_loose = sizes[4];
    r.sew_worst_gap = sizes[5];
    r.loose_edges = counts[9];
    r.sew_pairs = counts[10];
    r.sew_refused = counts[11];
    std::size_t free_count = std::min(free_ids.size() / 6, free_sizes.size() / 2);
    r.free_edges.reserve(free_count);
    for (std::size_t i = 0; i < free_count; ++i) {
        FreeEdge e;
        e.trim = free_ids[6 * i];
        if (free_ids[6 * i + 1] != NONE) e.edge = free_ids[6 * i + 1];
        e.face = free_ids[6 * i + 2];
        e.wire = free_ids[6 * i + 3];
        if (free_ids[6 * i + 4] != NONE) e.partner = free_ids[6 * i + 4];
        e.shared_ends = free_ids[6 * i + 5];
        e.length = free_sizes[2 * i];
        e.gap = free_sizes[2 * i + 1];
        r.free_edges.push_back(e);
    }
    std::size_t wire_count = std::min(wire_runs.size() / 3, wire_sizes.size() / 2);
    r.wires.reserve(wire_count);
    for (std::size_t i = 0; i < wire_count; ++i) {
        FreeWire w;
        w.first = wire_runs[3 * i];
        w.count = wire_runs[3 * i + 1];
        w.closed = wire_runs[3 * i + 2] != 0;
        w.length = wire_sizes[2 * i];
        w.widest_gap = wire_sizes[2 * i + 1];
        r.wires.push_back(w);
    }
    std::size_t small_count = std::min(small_items.size() / 2, small_sizes.size());
    r.small.reserve(small_count);
    for (std::size_t i = 0; i < small_count; ++i) {
        Result<std::string> kind = health_kind(small_items[2 * i], "health");
        if (!kind) return kind.error();
        SmallFeature s;
        s.kind = std::move(kind).value();
        s.index = small_items[2 * i + 1];
        s.size = small_sizes[i];
        r.small.push_back(std::move(s));
    }
    if (counts[12] == 1) {
        Cracks c;
        c.watertight = counts[13] != 0;
        c.open = counts[14];
        c.folded = counts[15];
        c.crossings = counts[16];
        c.edges = crack_edges;
        r.cracks = std::move(c);
    }
    return r;
}

// The flat rows of cadaclysm_blacksmith_heal_summary and the row readers, in their order:
// counts (11) and sizes (2); fixes 2 items and 2 sizes a row; refusals 3 items and 1 size.
inline Result<HealReport> heal_report(const std::uint32_t (&counts)[11], const double (&sizes)[2],
                                      const std::vector<std::uint32_t>& fix_items, const std::vector<double>& fix_sizes,
                                      const std::vector<std::uint32_t>& refused_items, const std::vector<double>& refused_sizes) {
    HealReport r;
    r.tolerance = sizes[0];
    r.moved = sizes[1];
    r.guarded = counts[2] != 0;
    r.small_before = counts[3];
    r.small_after = counts[4];
    r.free_before = counts[5];
    r.free_after = counts[6];
    r.closed_before = counts[7] != 0;
    r.closed_after = counts[8] != 0;
    r.nonmanifold_before = counts[9];
    r.nonmanifold_after = counts[10];
    std::size_t fix_count = std::min(fix_items.size() / 2, fix_sizes.size() / 2);
    r.fixes.reserve(fix_count);
    for (std::size_t i = 0; i < fix_count; ++i) {
        Result<std::string> kind = health_kind(fix_items[2 * i], "healed");
        if (!kind) return kind.error();
        HealFix f;
        f.kind = std::move(kind).value();
        f.index = fix_items[2 * i + 1];
        f.size = fix_sizes[2 * i];
        f.moved = fix_sizes[2 * i + 1];
        r.fixes.push_back(std::move(f));
    }
    std::size_t refused_count = std::min(refused_items.size() / 3, refused_sizes.size());
    r.refused.reserve(refused_count);
    for (std::size_t i = 0; i < refused_count; ++i) {
        Result<std::string> kind = health_kind(refused_items[3 * i], "healed");
        if (!kind) return kind.error();
        std::uint32_t why = refused_items[3 * i + 2];
        if (why >= 11) return Error{"healed: why " + std::to_string(why) + " is not one of the eleven", Origin::kernel};
        HealRefusal f;
        f.kind = std::move(kind).value();
        f.index = refused_items[3 * i + 1];
        f.why = HEAL_WHYS[why];
        f.figure = refused_sizes[i];
        r.refused.push_back(std::move(f));
    }
    return r;
}

// One two-call row reader's rows: the count with null buffers, then `ids_per` ids and
// `sizes_per` sizes a row. A second count that differs is refused.
template <class Handle, class Reader>
inline Result<std::pair<std::vector<std::uint32_t>, std::vector<double>>> health_rows(Reader reader, const Handle* h,
                                                                                    std::size_t ids_per, std::size_t sizes_per,
                                                                                    const char* call) {
    std::uint32_t n = reader(h, nullptr, nullptr);
    std::vector<std::uint32_t> ids(ids_per * n);
    std::vector<double> sizes(sizes_per * n);
    if (n) {
        std::uint32_t written = reader(h, ids.data(), sizes.data());
        if (written != n) {
            return Error{std::string(call) + ": a row reader wrote " + std::to_string(written) + " rows, not " + std::to_string(n),
                         Origin::kernel};
        }
    }
    return std::pair<std::vector<std::uint32_t>, std::vector<double>>(std::move(ids), std::move(sizes));
}
}  // namespace detail

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

    // -- material and look defined outside the file

    // This solid made of `material` -- a name, written to STEP as the product's
    // MATERIAL_DESIGNATION. Kept by every operation as the solid's colour is: a move
    // keeps it, a boolean's result is made of its first solid's. Writing it moves
    // step()'s default schema to AP242; a named schema without the entity drops it, as
    // it drops a colour. Refused when blank.
    Result<Solid> with_material(std::string_view material) const {
        std::string owned(material);
        return wrap(::cadaclysm_blacksmith_with_material(raw_handle("with_material"), owned.c_str()));
    }
    // What this solid is made of, or nullopt -- see with_material(). Borrowed, read as
    // name() reads its own.
    std::optional<std::string> material() const {
        const char* raw = ::cadaclysm_blacksmith_solid_material(raw_handle("material"));
        if (!raw) return std::nullopt;
        return std::string(raw);
    }
    // This solid drawn in a style defined outside the file: `identification` the style's
    // name in the library at `location` -- a MaterialX or MDL file and a material in it,
    // say. Either may be nullopt, not both. Written to STEP as an EXTERNALLY_DEFINED_STYLE
    // beside the solid's colour, which a reader without the library draws instead (AP242
    // or AP214: the default schema moves to AP242). Kept as with_material()'s material is.
    Result<Solid> styled(std::optional<std::string_view> location, std::optional<std::string_view> identification) const {
        std::optional<std::string> l, i;
        if (location) l.emplace(*location);
        if (identification) i.emplace(*identification);
        return wrap(::cadaclysm_blacksmith_styled(raw_handle("styled"), l ? l->c_str() : nullptr, i ? i->c_str() : nullptr));
    }
    // Where this solid's outside style lives (styled()'s `location`), or nullopt.
    std::optional<std::string> style_location() const {
        const char* raw = ::cadaclysm_blacksmith_solid_style_location(raw_handle("style_location"));
        if (!raw) return std::nullopt;
        return std::string(raw);
    }
    // This solid's outside style's name in its library (styled()'s `identification`), or
    // nullopt.
    std::optional<std::string> style_identification() const {
        const char* raw = ::cadaclysm_blacksmith_solid_style_identification(raw_handle("style_identification"));
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
    // This solid through the affine map `t`, exact, its colours and name kept. A rigid map or a
    // similarity keeps every surface's kind, and so does a map within 1e-6 of a similarity (a
    // rotation written in float32 among them), applied as the exact similarity nearest it. Any
    // other map (a non-uniform scale, a shear) turns the curved surfaces into their exact NURBS
    // and maps those. The result's inexact_trims() counts the trims this call lost. Refused for
    // a singular map (it flattens the solid), a non-finite one or a non-affine one.
    Result<Solid> transform(const Transform& t) const { return transform(t.rows()); }
    // transform by 16 numbers, row-major.
    Result<Solid> transform(const std::array<double, 16>& matrix) const {
        std::uint32_t lost = 0;
        Result<Solid> out = wrap(::cadaclysm_blacksmith_solid_transform(raw_handle("solid_transform"), matrix.data(), &lost),
                                 "solid_transform");
        if (out) out->inexact_trims_ = lost;
        return out;
    }
    // This solid with its surfaces rewritten as their exact NURBS, to `level`: colours and
    // name kept; inexact_trims() counts the trims this call lost, as transform's does.
    Result<Solid> convert_to_nurbs(NurbsLevel level = NurbsLevel::all) const {
        std::uint32_t code = CADACLYSM_BLACKSMITH_NURBS_ALL;
        switch (level) {
            case NurbsLevel::procedural: code = CADACLYSM_BLACKSMITH_NURBS_PROCEDURAL; break;
            case NurbsLevel::analytic: code = CADACLYSM_BLACKSMITH_NURBS_ANALYTIC; break;
            case NurbsLevel::all: code = CADACLYSM_BLACKSMITH_NURBS_ALL; break;
        }
        std::uint32_t lost = 0;
        Result<Solid> out = wrap(::cadaclysm_blacksmith_solid_convert_to_nurbs(raw_handle("solid_convert_to_nurbs"), code, &lost),
                                 "solid_convert_to_nurbs");
        if (out) out->inexact_trims_ = lost;
        return out;
    }
    // The trims lost by the transform or convert_to_nurbs call that made this solid: face
    // boundaries that survive only as a polyline lifted through the old surface, where no
    // exact edge curve was left. Per call, not this solid's history; 0 for a solid neither
    // call made.
    std::uint32_t inexact_trims() const noexcept { return inexact_trims_; }

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
    // This solid and `other` as one body that keeps every piece -- a union that keeps the inside
    // pieces: its regions are this solid less `other`, the two together, and `other` less this
    // one (those that are not empty), and the walls between them are faces of both. The body is
    // non-manifold where a wall meets the outside (edges of three or four faces), so the verbs
    // that need a manifold solid -- the booleans, fillet, chamfer, shell, thicken, mass -- refuse
    // it; take its cells with regions() and region_solid(). Built exactly: both solids closed,
    // every face a plane, cylinder, cone, sphere or torus. Walls of the two lying on one another
    // in part are a case it refuses, in words.
    Result<Solid> merge(const Solid& other, double tolerance = DEFAULT_TOLERANCE, const Progress& progress = {}) const {
        return wrap(::cadaclysm_blacksmith_merge(raw_handle("merge"), other.raw_handle("merge"), tolerance,
                                                 detail::progress_fn(progress), detail::progress_user(progress)),
                    "merge");
    }
    // The regions of space this solid's faces bound, region 0 the infinite one: two for an
    // ordinary solid (outside, inside), one per cell for a merge's body, one more per cavity.
    Result<std::vector<Region>> regions() const {
        return detail::regions_of(::cadaclysm_blacksmith_regions(raw_handle("regions")));
    }
    // Finite region `region` (an index into regions()) as a closed solid of its own: the faces
    // bounding it, each turned to point out of it, each keeping its colour. Region 0, the
    // infinite one, is refused.
    Result<Solid> region_solid(std::uint32_t region) const {
        return wrap(::cadaclysm_blacksmith_region_solid(raw_handle("region_solid"), region), "region_solid");
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
    // region's rings (outer first, holes after), which may be empty for a partial overlap of curved faces
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
        return detail::intersection_of(found, "intersect");
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

    // -- health and healing
    // What is wrong with this solid, as a HealthReport: the free edges (the sides one face
    // bounds) and the wires they chain into, with each edge's nearest partner and the gap
    // to it; the features below `tolerance`; the loose edges; and what sewing would join and
    // leave. `tolerance` is the length below which a feature is small and a gap closes --
    // nullopt, or a value that is not finite and positive, takes the default, 1e-4 times the
    // diagonal (the report shows what was used). `mesh` also meshes the solid and reports
    // where the mesh cracks (`cracks`); without it `cracks` is nullopt. Nothing moves.
    Result<HealthReport> health(std::optional<double> tolerance = std::nullopt, bool mesh = false) const {
        const CadaclysmBlacksmithSolid* solid = raw_handle("health");
        struct Free {
            void operator()(CadaclysmBlacksmithHealth* h) const noexcept { ::cadaclysm_blacksmith_health_free(h); }
        };
        std::unique_ptr<CadaclysmBlacksmithHealth, Free> h(
            ::cadaclysm_blacksmith_health(solid, tolerance.value_or(std::nan("")), mesh));
        if (!h) return detail::kernel_error("health");
        std::uint32_t counts[18] = {};
        double sizes[8] = {};
        if (!::cadaclysm_blacksmith_health_summary(h.get(), counts, sizes)) return detail::kernel_error("health");
        Result<std::pair<std::vector<std::uint32_t>, std::vector<double>>> free = detail::health_rows(
            [](const CadaclysmBlacksmithHealth* p, std::uint32_t* ids, double* s) {
                return ::cadaclysm_blacksmith_health_free_edges(p, ids, s);
            },
            h.get(), 6, 2, "health");
        if (!free) return free.error();
        Result<std::pair<std::vector<std::uint32_t>, std::vector<double>>> wires = detail::health_rows(
            [](const CadaclysmBlacksmithHealth* p, std::uint32_t* ids, double* s) {
                return ::cadaclysm_blacksmith_health_wires(p, ids, s);
            },
            h.get(), 3, 2, "health");
        if (!wires) return wires.error();
        Result<std::pair<std::vector<std::uint32_t>, std::vector<double>>> small = detail::health_rows(
            [](const CadaclysmBlacksmithHealth* p, std::uint32_t* ids, double* s) {
                return ::cadaclysm_blacksmith_health_small(p, ids, s);
            },
            h.get(), 2, 1, "health");
        if (!small) return small.error();
        std::uint32_t n = ::cadaclysm_blacksmith_health_crack_edges(h.get(), nullptr);
        std::vector<std::uint32_t> cracks(n);
        if (n && ::cadaclysm_blacksmith_health_crack_edges(h.get(), cracks.data()) != n) {
            return detail::refuse("health: the crack edges changed count between reads");
        }
        return detail::health_report(counts, sizes, free->first, free->second, wires->first, wires->second, small->first,
                                     small->second, cracks);
    }

    // This solid with its small features removed, and what was done, as a new Solid and a
    // HealReport; this one is left as it was. The features are the ones health() lists as
    // small at `tolerance`: short and collapsed edges, sliver and tiny faces, small holes.
    // Every fix is a vertex merge, and an edge it moves records how far as its
    // edge_tolerance(). A guard compares the result's health with this one's and refuses
    // fixes that made it worse (`guarded`). `edges`, `faces` and `holes` switch each kind of
    // fix; a kind switched off is refused as "toggled". `tolerance` nullopt, or a value that
    // is not finite and positive, takes the default (the report shows what was used).
    Result<std::pair<Solid, HealReport>> healed(std::optional<double> tolerance = std::nullopt, bool edges = true,
                                                bool faces = true, bool holes = true) const {
        const CadaclysmBlacksmithSolid* solid = raw_handle("healed");
        struct Free {
            void operator()(CadaclysmBlacksmithHeal* h) const noexcept { ::cadaclysm_blacksmith_heal_free(h); }
        };
        std::unique_ptr<CadaclysmBlacksmithHeal, Free> h(
            ::cadaclysm_blacksmith_healed(solid, tolerance.value_or(std::nan("")), detail::heal_flags(edges, faces, holes)));
        if (!h) return detail::kernel_error("healed");
        std::uint32_t counts[11] = {};
        double sizes[2] = {};
        if (!::cadaclysm_blacksmith_heal_summary(h.get(), counts, sizes)) return detail::kernel_error("healed");
        Result<std::pair<std::vector<std::uint32_t>, std::vector<double>>> fixes = detail::health_rows(
            [](const CadaclysmBlacksmithHeal* p, std::uint32_t* items, double* s) {
                return ::cadaclysm_blacksmith_heal_fixes(p, items, s);
            },
            h.get(), 2, 2, "healed");
        if (!fixes) return fixes.error();
        Result<std::pair<std::vector<std::uint32_t>, std::vector<double>>> refused = detail::health_rows(
            [](const CadaclysmBlacksmithHeal* p, std::uint32_t* items, double* s) {
                return ::cadaclysm_blacksmith_heal_refused(p, items, s);
            },
            h.get(), 3, 1, "healed");
        if (!refused) return refused.error();
        Result<HealReport> report =
            detail::heal_report(counts, sizes, fixes->first, fixes->second, refused->first, refused->second);
        if (!report) return report.error();
        Result<Solid> body = wrap(::cadaclysm_blacksmith_heal_body(h.get()), "healed");
        if (!body) return body.error();
        return std::pair<Solid, HealReport>(std::move(body).value(), std::move(report).value());
    }

    // How far brep edge `edge` (as a HealFix or FreeEdge names one) may lie off its curve: 0
    // for an exact edge, the distance healing (or sewing) moved it where that is recorded,
    // nullopt when no trim names the id (an edge healing removed).
    Result<std::optional<double>> edge_tolerance(std::uint32_t edge) const {
        double t = ::cadaclysm_blacksmith_edge_tolerance(raw_handle("edge_tolerance"), edge);
        if (!std::isnan(t)) return std::optional<double>(t);
        if (!detail::text(::cadaclysm_blacksmith_last_error()).empty()) return detail::kernel_error("edge_tolerance");
        return std::optional<double>();
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
    // An RTree over this solid's faces: one entry per face, its id the face index the other face
    // calls take, its box holding the face (the box the boolean's broad phase pairs faces by,
    // grown by a thousandth of the solid's extent). No faces give an empty tree. The tree is its
    // own and outlives the solid.
    Result<RTree> face_tree() const;
    // One thickness for face `face` of this solid alone, on a ThicknessGauge meshed at `tolerance`
    // (default 0.01), used once and freed -- build the gauge yourself to ask more than once.
    // nullopt where nothing is found; see ThicknessGauge::thickness_at_face. Refused with the
    // gauge call's prefix (`thickness_gauge_face: ...`).
    Result<std::optional<FaceThickness>> thickness_at_face(std::uint32_t face, double maximum,
                                                           double tolerance = THICKNESS_TOLERANCE) const;
    // The same measured at `at`'s foot on the face (nullopt: over the face's vertices).
    Result<std::optional<FaceThickness>> thickness_at_face(std::uint32_t face, const std::optional<Vec3>& at, double maximum,
                                                           double tolerance = THICKNESS_TOLERANCE) const;
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

    // -- measuring
    // The box aligned with the principal axes of inertia. `accuracy` 0 or less takes the default.
    Result<OrientedBox> oriented_box(double accuracy = 0.0) const {
        CadaclysmBlacksmithOrientedBox out{};
        if (!::cadaclysm_blacksmith_oriented_box(raw_handle("oriented_box"), accuracy, &out)) {
            return detail::kernel_error("oriented_box");
        }
        OrientedBox box;
        box.centre = {out.centre[0], out.centre[1], out.centre[2]};
        for (std::size_t r = 0; r < 3; ++r) box.axes[r] = {out.axes[r * 3], out.axes[r * 3 + 1], out.axes[r * 3 + 2]};
        box.half = {out.half[0], out.half[1], out.half[2]};
        return box;
    }
    // The length of edge `edge`, the index edges() and fillet use.
    Result<Length> edge_length(std::uint32_t edge, double accuracy = 0.0) const {
        CadaclysmBlacksmithLength out{};
        if (!::cadaclysm_blacksmith_edge_length(raw_handle("edge_length"), edge, accuracy, &out)) {
            return detail::kernel_error("edge_length");
        }
        return detail::length_of(out);
    }
    // The point `s` of arc length along edge `edge` from the start of its curve, with its unit
    // tangent. `accuracy` 0 or less takes the default.
    Result<At> edge_point_at_length(std::uint32_t edge, double s, double accuracy = 0.0) const {
        CadaclysmBlacksmithAt out{};
        if (!::cadaclysm_blacksmith_edge_point_at_length(raw_handle("edge_point_at_length"), edge, s, accuracy, &out)) {
            return detail::kernel_error("edge_point_at_length");
        }
        return detail::at_of(out);
    }
    // `n` points evenly spaced by arc length along edge `edge` (a closed edge gives `n`, an open
    // one `n + 1`); `n` is 1 to 1000000.
    Result<std::vector<At>> edge_divide_by_count(std::uint32_t edge, std::uint32_t n, double accuracy = 0.0) const {
        return detail::samples_of(
            ::cadaclysm_blacksmith_edge_divide_by_count(raw_handle("edge_divide_by_count"), edge, n, accuracy),
            "edge_divide_by_count");
    }
    // Points every `step` of arc length along edge `edge`; the last piece is kept short and a
    // closed start is not repeated.
    Result<std::vector<At>> edge_divide_by_length(std::uint32_t edge, double step, double accuracy = 0.0) const {
        return detail::samples_of(
            ::cadaclysm_blacksmith_edge_divide_by_length(raw_handle("edge_divide_by_length"), edge, step, accuracy),
            "edge_divide_by_length");
    }
    // "outside", "inside" or "on": where `point` lies against the boundary, "on" being within
    // `tolerance` of it. Many points: build a classifier() once.
    Result<std::string> contains(const Vec3& point, double tolerance = DEFAULT_TOLERANCE) const {
        std::uint32_t code = 0;
        if (!::cadaclysm_blacksmith_contains(raw_handle("contains"), point.data(), tolerance, &code)) {
            return detail::kernel_error("contains");
        }
        return detail::containment_of(code, "contains");
    }
    // A reusable containment test; it outlives this solid.
    Result<Classifier> classifier(double tolerance = DEFAULT_TOLERANCE) const {
        CadaclysmBlacksmithClassifier* raw = ::cadaclysm_blacksmith_classifier_new(raw_handle("classifier"), tolerance);
        if (!raw) return detail::kernel_error("classifier_new");
        return Classifier(raw);
    }
    // The closest points between this solid's boundary and `other`'s.
    Result<Closest> closest(const Solid& other, double tolerance = DEFAULT_TOLERANCE, const Progress& progress = {}) const {
        CadaclysmBlacksmithClosest out{};
        if (!::cadaclysm_blacksmith_closest(raw_handle("closest"), other.raw_handle("closest"), tolerance,
                                            detail::progress_fn(progress), detail::progress_user(progress), &out)) {
            return detail::kernel_error("closest");
        }
        Closest c;
        c.distance = out.distance;
        c.on_a = {out.on_a[0], out.on_a[1], out.on_a[2]};
        c.on_b = {out.on_b[0], out.on_b[1], out.on_b[2]};
        c.kind_a = detail::text(out.kind_a);
        c.index_a = out.index_a;
        if (out.edge_a != NONE) c.edge_a = out.edge_a;
        c.kind_b = detail::text(out.kind_b);
        c.index_b = out.index_b;
        if (out.edge_b != NONE) c.edge_b = out.edge_b;
        c.refined = out.refined != 0;
        return c;
    }

    // The C handle, for code that calls the C ABI directly. Owned by this Solid.
    const CadaclysmBlacksmithSolid* handle() const noexcept { return state_ ? state_->handle : nullptr; }

private:
    friend class Workplane;
    friend struct ::cadaclysm::detail::ViewAccess;
    friend class Assembly;
    friend class CollisionHit;
    friend class Clash;
    friend class Stock;
    friend class Job;
    friend class Subd;
    friend class SolidValue;
    friend class SurfaceValue;
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
    // What inexact_trims() reads: written by transform and convert_to_nurbs.
    std::uint32_t inexact_trims_ = 0;
};

inline Result<Solid> SolidValue::to_solid() const {
    return Solid::wrap(::cadaclysm_blacksmith_solid_value_to_solid(kind_, v_.data()), "solid_value_to_solid");
}
inline Result<Solid> SurfaceValue::to_nurbs_sheet() const {
    return Solid::wrap(::cadaclysm_blacksmith_surface_value_nurbs_sheet(kind_, v_.data()), "surface_value_nurbs_sheet");
}

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
    // The Z range the item covers, in mm: where it starts (`top`) and where it ends
    // (`bottom`). For a corner this is the pocket wall the end mill missed, as in
    // "from z 10 down to z 2".
    double top = 0.0;
    double bottom = 0.0;
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
        item.top = ::cadaclysm_blacksmith_report_top(raw, i);
        item.bottom = ::cadaclysm_blacksmith_report_bottom(raw, i);
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
    // Rest machining: machine() with a list of end mills, tried in order -- what the
    // first leaves uncut the next one cuts, and the Report names what none reached.
    // The list goes largest first, each tool strictly smaller than the one before, or the
    // kernel refuses it. It must hold at least one tool and no null (the refusal names the
    // index of the first null); `drills`, `stepover`, `stepdown`, `skin` and `peck` are as in
    // machine(). The job changes only on success.
    Result<Report> machine_with(const Solid& part, const std::vector<const Tool*>& end_mills,
                                const std::vector<const Tool*>& drills = {}, std::optional<double> stepover = std::nullopt,
                                std::optional<double> stepdown = std::nullopt, double skin = 0.3,
                                std::optional<double> peck = std::nullopt) {
        CADACLYSM_TRY(handle, live());
        std::vector<const CadaclysmBlacksmithTool*> end_mill_handles;
        end_mill_handles.reserve(end_mills.size());
        for (const Tool* e : end_mills) end_mill_handles.push_back(e ? e->raw_handle("job_machine_with") : nullptr);
        std::vector<const CadaclysmBlacksmithTool*> drill_handles;
        drill_handles.reserve(drills.size());
        for (const Tool* d : drills) drill_handles.push_back(d ? d->raw_handle("job_machine_with") : nullptr);
        double nan = std::numeric_limits<double>::quiet_NaN();
        CadaclysmBlacksmithReport* raw = ::cadaclysm_blacksmith_job_machine_with(
            handle, part.raw_handle("job_machine_with"), end_mill_handles.empty() ? nullptr : end_mill_handles.data(),
            end_mill_handles.size(), drill_handles.empty() ? nullptr : drill_handles.data(), drill_handles.size(),
            stepover.value_or(nan), stepdown.value_or(nan), skin, peck.value_or(nan));
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

namespace detail {
struct ClashRows;

// Frees one Collider::clash or clash() answer: the deleter of the std::shared_ptr every Clash
// row of that call holds, so the last row let go frees the handle.
struct ClashesFree {
    void operator()(CadaclysmBlacksmithClashes* p) const noexcept { ::cadaclysm_blacksmith_clashes_free(p); }
};
}  // namespace detail

// One pair Collider::clash or clash() found, as plain data. `a`, `b` are the part indices: for
// one set or a collider `a < b`; for two sets `a` indexes `parts` and `b` indexes `others`.
// `kind` is "penetrating" (the volumes overlap), "touching" (the boundaries within the
// tolerance of each other), "too_close" (apart by more than the tolerance but less than the
// clearance) or "refused" (the pair could not be decided; `text` says why, empty otherwise).
// `distance` is the gap between the two boundaries (0 for a penetrating or refused pair);
// `on_a`/`on_b` the closest world points, for a penetrating pair the centre of the overlap's
// world box, the origin for a refused one.
//
// The feature fields are Closest's, flat: what each point lies on ("face", "edge" or "vertex"),
// the kernel's id, and the Solid::edges() index (empty for a face, a vertex, or an edge with no
// row there). For a penetrating or refused pair there is no closest point: `kind_a` and `kind_b`
// are "none" and `index_*` and `edge_*` empty. `refined` is true where the distance was measured
// on the exact surfaces; `depth` the thinnest side of a penetrating pair's overlap box, 0
// otherwise.
//
// solid() and intersect() are built on demand from the placement the pair was found at: every
// row of one call holds the call's answer alive -- past the collider and the solids -- and the
// last one destroyed frees it.
class Clash {
public:
    std::uint32_t a = 0;
    std::uint32_t b = 0;
    std::string kind;
    double distance = 0.0;
    Vec3 on_a = {};
    Vec3 on_b = {};
    std::string kind_a;
    std::optional<std::uint32_t> index_a;
    std::optional<std::uint32_t> edge_a;
    std::string kind_b;
    std::optional<std::uint32_t> index_b;
    std::optional<std::uint32_t> edge_b;
    bool refined = false;
    double depth = 0.0;
    std::string text;

    Clash() = default;

    // The exact shared volume of this penetrating pair, at the placement it was found at, as a
    // new solid. Refused (`clashes_solid: ...`) for a pair that is not penetrating.
    Result<Solid> solid() const {
        if (!keeper_) return detail::refuse("Clash.solid: the clashes handle is closed");
        return Solid::wrap(::cadaclysm_blacksmith_clashes_solid(keeper_.get(), index_), "clashes_solid");
    }

    // Where this pair's two parts cross or coincide at the placement it was found at, as
    // Solid::intersect reports it: a touching pair's shared face is an Overlap. Refused
    // (`clashes_intersect: ...`) for a refused pair.
    Result<Intersection> intersect() const {
        if (!keeper_) return detail::refuse("Clash.intersect: the clashes handle is closed");
        return detail::intersection_of(::cadaclysm_blacksmith_clashes_intersect(keeper_.get(), index_), "clashes_intersect");
    }

private:
    friend struct detail::ClashRows;

    // Copied out of the C struct: the strings borrow from the handle and are copied here.
    static Clash from_raw(const CadaclysmBlacksmithClash& raw, std::shared_ptr<CadaclysmBlacksmithClashes> keeper,
                          std::uint32_t index) {
        Clash row;
        row.a = raw.a;
        row.b = raw.b;
        row.kind = detail::text(raw.kind);
        row.distance = raw.distance;
        row.on_a = {raw.on_a[0], raw.on_a[1], raw.on_a[2]};
        row.on_b = {raw.on_b[0], raw.on_b[1], raw.on_b[2]};
        row.kind_a = detail::text(raw.kind_a);
        row.kind_b = detail::text(raw.kind_b);
        // A "none" feature (penetrating, refused) has no index and no edge; otherwise the edge
        // is decoded as Closest's is.
        if (row.kind_a != "none") {
            row.index_a = raw.index_a;
            if (raw.edge_a != NONE) row.edge_a = raw.edge_a;
        }
        if (row.kind_b != "none") {
            row.index_b = raw.index_b;
            if (raw.edge_b != NONE) row.edge_b = raw.edge_b;
        }
        row.refined = raw.refined != 0;
        row.depth = raw.depth;
        row.text = detail::text(raw.text);
        row.keeper_ = std::move(keeper);
        row.index_ = index;
        return row;
    }

    std::shared_ptr<CadaclysmBlacksmithClashes> keeper_;
    std::uint32_t index_ = 0;
};

namespace detail {
// A clash call's handle read out into rows, each holding the handle; with no rows it is freed
// at once. Null is `call`'s failure, read from last_error; a failing read frees the handle
// (the rows read so far let it go) and reports `clashes_at: ...`.
struct ClashRows {
    static Result<std::vector<Clash>> read(CadaclysmBlacksmithClashes* h, const char* call) {
        if (!h) return kernel_error(call);
        std::uint32_t count = ::cadaclysm_blacksmith_clashes_count(h);
        if (count == 0) {
            ::cadaclysm_blacksmith_clashes_free(h);
            return std::vector<Clash>{};
        }
        std::shared_ptr<CadaclysmBlacksmithClashes> keeper(h, ClashesFree{});
        std::vector<Clash> rows;
        rows.reserve(count);
        for (std::uint32_t i = 0; i < count; ++i) {
            CadaclysmBlacksmithClash raw{};
            if (!::cadaclysm_blacksmith_clashes_at(h, i, &raw)) return kernel_error("clashes_at");
            rows.push_back(Clash::from_raw(raw, keeper, i));
        }
        return rows;
    }
};
}  // namespace detail

// One pair Collider::swept_clash or swept_clash() found to clash somewhere on the path, as plain
// data. `a`, `b` are the part indices (for one set or a collider `a < b`; for two sets `a`
// indexes `parts` and `b` indexes `others`). `first_time` is the first time the pair came within
// the clearance, in pose units (pose `k` at time `k`; for a refused pair the time it was refused
// at), and `first` the Clash there -- its kind, distance, points, features and depth, at the
// frames the motion places the parts at that time, so first.solid() and first.intersect()
// rebuild the contact there, past the collider and the solids. `intervals` are the time ranges
// the pair stays in clash, (start, end), ascending and disjoint (none for a refused pair).
struct SweptClash {
    std::uint32_t a = 0;
    std::uint32_t b = 0;
    double first_time = 0.0;
    Clash first;
    std::vector<std::pair<double, double>> intervals;
};

namespace detail {
// Frees a swept clash call's handle, which is read out and freed at once.
struct SweptClashesFree {
    void operator()(CadaclysmBlacksmithSweptClashes* p) const noexcept { ::cadaclysm_blacksmith_swept_clashes_free(p); }
};

// A swept clash call's handle read out into rows and freed; each row's `first` a Clash of the
// handle's first rows (read by ClashRows, so they hold their own clashes handle). Null is
// `call`'s failure, read from last_error; a failing read reports `swept_clashes_*: ...`, the
// error built before the handles are freed.
inline Result<std::vector<SweptClash>> swept_clashes_of(CadaclysmBlacksmithSweptClashes* h, const char* call) {
    if (!h) return kernel_error(call);
    std::unique_ptr<CadaclysmBlacksmithSweptClashes, SweptClashesFree> owned(h);
    std::uint32_t count = ::cadaclysm_blacksmith_swept_clashes_count(h);
    if (count == 0) return std::vector<SweptClash>{};
    Result<std::vector<Clash>> read = ClashRows::read(::cadaclysm_blacksmith_swept_clashes_firsts(h), "swept_clashes_firsts");
    if (!read) return read.error();
    std::vector<Clash> firsts = std::move(read).value();
    if (firsts.size() != count) {
        return refuse("swept_clashes_firsts: " + std::to_string(firsts.size()) + " rows for " + std::to_string(count) + " pairs");
    }
    std::vector<SweptClash> rows;
    rows.reserve(count);
    for (std::uint32_t i = 0; i < count; ++i) {
        CadaclysmBlacksmithSweptClash raw{};
        if (!::cadaclysm_blacksmith_swept_clashes_at(h, i, &raw)) return kernel_error("swept_clashes_at");
        SweptClash row;
        row.a = raw.a;
        row.b = raw.b;
        row.first_time = raw.first_time;
        row.first = std::move(firsts[i]);
        row.intervals.reserve(raw.interval_count);
        for (std::uint32_t k = 0; k < raw.interval_count; ++k) {
            double span[2] = {0.0, 0.0};
            if (!::cadaclysm_blacksmith_swept_clashes_interval(h, i, k, span)) return kernel_error("swept_clashes_interval");
            row.intervals.emplace_back(span[0], span[1]);
        }
        rows.push_back(std::move(row));
    }
    return rows;
}

// The poses flattened pose by pose, 12 doubles a frame.
inline std::vector<double> flat_poses(const Poses& poses) {
    std::vector<double> flat;
    for (const std::vector<std::reference_wrapper<const Frame>>& pose : poses) {
        for (const Frame& f : pose) {
            const std::array<double, 12>& v = f.raw();
            flat.insert(flat.end(), v.begin(), v.end());
        }
    }
    return flat;
}
}  // namespace detail

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

    // Every pair of parts that penetrates, touches or lies within `clearance` of the other, as
    // Clash rows in pair order, with each group placed at its matching frame in `frames` (as
    // check() takes them; check() answers overlap alone). `clearance` is zero or more, in model
    // units: a pair apart by more than the collider's tolerance but less than it is "too_close",
    // within the tolerance "touching". `share` as for check(): the rows of the shares of one
    // pose are disjoint and cover it. Once a pair needed one, the collider keeps each part's
    // closest mesh (at a third of its tolerance) for its lifetime. Refused
    // (`collider_clash: ...`) for a negative or non-finite `clearance`, the wrong number of
    // frames or a `share` with `k >= n`.
    Result<std::vector<Clash>> clash(const std::vector<std::reference_wrapper<const Frame>>& frames, double clearance = 0.0,
                                     const std::optional<std::pair<std::uint32_t, std::uint32_t>>& share = std::nullopt) const {
        std::vector<double> flat;
        flat.reserve(frames.size() * 12);
        for (const Frame& f : frames) {
            const std::array<double, 12>& v = f.raw();
            flat.insert(flat.end(), v.begin(), v.end());
        }
        std::uint32_t share_k = share ? share->first : 0;
        std::uint32_t share_n = share ? share->second : 0;
        CadaclysmBlacksmithClashes* h = ::cadaclysm_blacksmith_collider_clash(
            raw_handle("clash"), flat.data(), static_cast<std::uint32_t>(frames.size()), clearance, share_k, share_n);
        return detail::ClashRows::read(h, "collider_clash");
    }

    // Every pair of parts that penetrates, touches or comes within `clearance` of the other
    // anywhere on the path through `poses` -- not only at the poses -- as SweptClash rows in pair
    // order. `poses` is two or more poses, each the frames clash() takes (one frame per group).
    // Between two poses each group moves rigidly about the centre of its rest box: that point on
    // the straight line between its two places, the rotation turning at a steady rate the shorter
    // way round. Time runs in pose units, pose `k` at time `k`.
    //
    // No moment where the true gap is below `clearance` less the collider's tolerance (for
    // clearance 0: no penetration deeper than the tolerance) falls between two steps.
    // `resolution` (in (0, 1], a fraction of a segment) is how closely an interval's end is
    // found; `max_steps` the pose-wise tests one pair may take -- a pair that needs more is a
    // "refused" row. `share` as for check(), over the pairs whose swept boxes meet. The pose
    // caches check() and clash() keep are neither read nor filled. Refused
    // (`collider_swept_clash: ...`) for fewer than two poses, the wrong number of frames in a
    // pose, a bad frame, `clearance`, `resolution` or `share`, or `max_steps` 0.
    Result<std::vector<SweptClash>> swept_clash(const Poses& poses, double clearance = 0.0, double resolution = 1e-3,
                                                std::uint32_t max_steps = 100000,
                                                const std::optional<std::pair<std::uint32_t, std::uint32_t>>& share =
                                                    std::nullopt) const {
        // C reads every pose at one frame count: say the first pose that is off, in the kernel's
        // words
        std::size_t frame_count = poses.empty() ? 0 : poses[0].size();
        for (const std::vector<std::reference_wrapper<const Frame>>& pose : poses) {
            if (pose.size() != frame_count) {
                std::uint32_t groups = group_count();
                for (const std::vector<std::reference_wrapper<const Frame>>& off : poses) {
                    if (off.size() != groups) {
                        return detail::refuse("collider_swept_clash: " + std::to_string(off.size()) + " frames for " +
                                              std::to_string(groups) + " groups");
                    }
                }
            }
        }
        std::vector<double> flat = detail::flat_poses(poses);
        std::uint32_t share_k = share ? share->first : 0;
        std::uint32_t share_n = share ? share->second : 0;
        CadaclysmBlacksmithSweptClashes* h = ::cadaclysm_blacksmith_collider_swept_clash(
            raw_handle("swept_clash"), flat.data(), static_cast<std::uint32_t>(poses.size()), static_cast<std::uint32_t>(frame_count),
            clearance, resolution, max_steps, share_k, share_n);
        return detail::swept_clashes_of(h, "collider_swept_clash");
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

// ---- R-tree ---------------------------------------------------------------------------

// One entry RTree::within or RTree::nearest found: its `id` and the `distance` from the point to
// its box (0 inside it). Python's `(id, distance)`.
struct RTreeHit {
    std::uint32_t id = 0;
    double distance = 0.0;
};
inline bool operator==(const RTreeHit& l, const RTreeHit& r) { return l.id == r.id && l.distance == r.distance; }
inline bool operator!=(const RTreeHit& l, const RTreeHit& r) { return !(l == r); }

// Two entries whose boxes meet: `a` of the tree asked and `b` of the other (RTree::overlaps), or
// `a <= b` (RTree::self_overlaps). Python's `(a, b)`.
struct RTreePair {
    std::uint32_t a = 0;
    std::uint32_t b = 0;
};
inline bool operator==(const RTreePair& l, const RTreePair& r) { return l.a == r.a && l.b == r.b; }
inline bool operator!=(const RTreePair& l, const RTreePair& r) { return !(l == r); }
inline bool operator<(const RTreePair& l, const RTreePair& r) { return l.a != r.a ? l.a < r.a : l.b < r.b; }

namespace detail {
// A box as the C ABI's 6 doubles, [minx, miny, minz, maxx, maxy, maxz].
inline std::array<double, 6> rtree_words(const Box& box) {
    return {box.lo[0], box.lo[1], box.lo[2], box.hi[0], box.hi[1], box.hi[2]};
}

// The hits of a query, read into a vector. A null list is the call's failure, read from
// last_error under `call`; the list is freed on every path out, a failing read included, and the
// error is built before the free.
inline Result<std::vector<RTreeHit>> rtree_hits(CadaclysmBlacksmithRTreeHits* list, const char* call) {
    if (!list) return kernel_error(call);
    struct Free {
        void operator()(CadaclysmBlacksmithRTreeHits* p) const noexcept { ::cadaclysm_blacksmith_rtree_hits_free(p); }
    };
    std::unique_ptr<CadaclysmBlacksmithRTreeHits, Free> owned(list);
    std::uint32_t count = ::cadaclysm_blacksmith_rtree_hits_count(owned.get());
    std::vector<RTreeHit> out;
    out.reserve(count);
    for (std::uint32_t i = 0; i < count; ++i) {
        CadaclysmBlacksmithRTreeHit raw{};
        if (!::cadaclysm_blacksmith_rtree_hits_at(owned.get(), i, &raw)) return kernel_error("rtree_hits_at");
        out.push_back(RTreeHit{raw.id, raw.distance});
    }
    return out;
}

// The pairs of a query, as rtree_hits reads hits.
inline Result<std::vector<RTreePair>> rtree_pairs(CadaclysmBlacksmithRTreePairs* list, const char* call) {
    if (!list) return kernel_error(call);
    struct Free {
        void operator()(CadaclysmBlacksmithRTreePairs* p) const noexcept { ::cadaclysm_blacksmith_rtree_pairs_free(p); }
    };
    std::unique_ptr<CadaclysmBlacksmithRTreePairs, Free> owned(list);
    std::uint32_t count = ::cadaclysm_blacksmith_rtree_pairs_count(owned.get());
    std::vector<RTreePair> out;
    out.reserve(count);
    for (std::uint32_t i = 0; i < count; ++i) {
        CadaclysmBlacksmithRTreePair raw{};
        if (!::cadaclysm_blacksmith_rtree_pairs_at(owned.get(), i, &raw)) return kernel_error("rtree_pairs_at");
        out.push_back(RTreePair{raw.a, raw.b});
    }
    return out;
}

// `x` as Rust's `{}` prints an f64 -- the kernel's refusals quote numbers that way.
inline std::string rust_number(double x) {
    if (std::isnan(x)) return "NaN";
    if (std::isinf(x)) return x > 0 ? "inf" : "-inf";
    // The shortest round-trip digits, as Rust's are (the first precision that reads back), laid
    // out as Rust lays them out: without an exponent.
    const std::string sign = std::signbit(x) ? "-" : "";
    const double a = std::fabs(x);
    char buffer[40];
    for (int precision = 0; precision <= 16; ++precision) {
        std::snprintf(buffer, sizeof buffer, "%.*e", precision, a);
        if (std::strtod(buffer, nullptr) == a) break;
    }
    std::string digits;
    const char* e = buffer;
    for (; *e != '\0' && *e != 'e'; ++e) {
        if (*e >= '0' && *e <= '9') digits += *e;
    }
    long shift = (*e == 'e' ? std::strtol(e + 1, nullptr, 10) : 0) - static_cast<long>(digits.size()) + 1;
    while (!digits.empty() && digits.back() == '0') {
        digits.pop_back();
        ++shift;
    }
    const std::size_t lead = digits.find_first_not_of('0');
    if (lead == std::string::npos) return sign + "0";
    digits.erase(0, lead);
    if (shift >= 0) return sign + digits + std::string(static_cast<std::size_t>(shift), '0');
    const long point = static_cast<long>(digits.size()) + shift;
    if (point > 0) {
        return sign + digits.substr(0, static_cast<std::size_t>(point)) + "." + digits.substr(static_cast<std::size_t>(point));
    }
    return sign + "0." + std::string(static_cast<std::size_t>(-point), '0') + digits;
}

// Refuses, as the kernel's closest_points / k_neighbors do, the first hay point and then the first
// needle that is not finite, by index.
inline Result<void> finite_points(const char* call, const std::vector<Vec3>& hay, const std::vector<Vec3>& needles) {
    const std::pair<const char*, const std::vector<Vec3>*> sets[] = {{"hay", &hay}, {"needle", &needles}};
    for (const std::pair<const char*, const std::vector<Vec3>*>& set : sets) {
        for (std::size_t i = 0; i < set.second->size(); ++i) {
            const Vec3& p = (*set.second)[i];
            if (!std::isfinite(p[0]) || !std::isfinite(p[1]) || !std::isfinite(p[2])) {
                return refuse(std::string(call) + ": " + set.first + " point " + std::to_string(i) + " is not finite");
            }
        }
    }
    return {};
}
}  // namespace detail

// A spatial index over boxes with ids (an R*-tree): search() a box for the entries it meets,
// within() / nearest() a point for the closest, overlaps() / self_overlaps() for every pair of
// boxes that meet. Ids are the caller's own and may repeat; an entry is an id and its Box, and
// the same (id, box) twice is two entries. Touching boxes meet. A point stands for a zero box
// (insert() and remove() take either). Answers come in a fixed order: search ids ascending,
// within / nearest by distance then id, pairs ascending. The tree changes in place; calls on one
// tree must not overlap from two threads. Move-only; the destructor frees it, as close() does
// early. A call on a closed or moved-from tree is refused, "rtree: closed". Python's RTree.
class RTree {
public:
    RTree(RTree&&) noexcept = default;
    RTree& operator=(RTree&&) noexcept = default;
    RTree(const RTree&) = delete;
    RTree& operator=(const RTree&) = delete;

    // An empty tree.
    static Result<RTree> make() { return adopt(::cadaclysm_blacksmith_rtree_new(), "rtree_new"); }

    // A tree over (id, box) entries at once, packed (sort-tile-recursive): fuller and faster to
    // query than the same entries inserted one by one. The first entry whose box is not a box (a
    // NaN, an infinity, `lo` above `hi`) is refused, by index.
    static Result<RTree> from_boxes(const std::vector<std::pair<std::uint32_t, Box>>& entries) {
        if (entries.size() > std::numeric_limits<std::uint32_t>::max()) {
            return detail::refuse("rtree_from_boxes: " + std::to_string(entries.size()) + " entries is more than 4294967295");
        }
        std::vector<std::uint32_t> ids;
        std::vector<double> boxes;
        ids.reserve(entries.size());
        boxes.reserve(entries.size() * 6);
        for (const std::pair<std::uint32_t, Box>& e : entries) {
            ids.push_back(e.first);
            const std::array<double, 6> words = detail::rtree_words(e.second);
            boxes.insert(boxes.end(), words.begin(), words.end());
        }
        return adopt(::cadaclysm_blacksmith_rtree_from_boxes(ids.empty() ? nullptr : ids.data(),
                                                             boxes.empty() ? nullptr : boxes.data(),
                                                             static_cast<std::uint32_t>(ids.size())),
                     "rtree_from_boxes");
    }

    // A tree over `points`, each a zero box whose id is its index. The first point with a NaN or
    // infinite coordinate is refused, by index.
    static Result<RTree> from_points(const std::vector<Vec3>& points) {
        if (points.size() > std::numeric_limits<std::uint32_t>::max()) {
            return detail::refuse("rtree_from_points: " + std::to_string(points.size()) + " points is more than 4294967295");
        }
        std::vector<double> xyz;
        xyz.reserve(points.size() * 3);
        for (const Vec3& p : points) xyz.insert(xyz.end(), p.begin(), p.end());
        return adopt(::cadaclysm_blacksmith_rtree_from_points(xyz.empty() ? nullptr : xyz.data(),
                                                              static_cast<std::uint32_t>(points.size())),
                     "rtree_from_points");
    }

    // A tree over a mesh's triangles -- RhinoCommon's RTree.CreateMeshFaceTree: one entry per
    // triangle of `triangles` (three indices into `positions`), its id the triangle's index, its
    // box its three corners' box. The first corner past the points or at a point with a NaN or
    // infinite coordinate is refused, by triangle and point; points no triangle uses are not
    // checked.
    static Result<RTree> from_triangles(const std::vector<Vec3>& positions,
                                        const std::vector<std::array<std::uint32_t, 3>>& triangles) {
        if (positions.size() > std::numeric_limits<std::uint32_t>::max()) {
            return detail::refuse("rtree_from_triangles: " + std::to_string(positions.size()) + " points is more than 4294967295");
        }
        if (triangles.size() > std::numeric_limits<std::uint32_t>::max()) {
            return detail::refuse("rtree_from_triangles: " + std::to_string(triangles.size()) +
                                  " triangles is more than 4294967295");
        }
        std::vector<double> xyz;
        xyz.reserve(positions.size() * 3);
        for (const Vec3& p : positions) xyz.insert(xyz.end(), p.begin(), p.end());
        std::vector<std::uint32_t> indices;
        indices.reserve(triangles.size() * 3);
        for (const std::array<std::uint32_t, 3>& t : triangles) indices.insert(indices.end(), t.begin(), t.end());
        return adopt(::cadaclysm_blacksmith_rtree_from_triangles(xyz.empty() ? nullptr : xyz.data(),
                                                                 static_cast<std::uint32_t>(positions.size()),
                                                                 indices.empty() ? nullptr : indices.data(),
                                                                 static_cast<std::uint32_t>(triangles.size())),
                     "rtree_from_triangles");
    }

    void close() noexcept { ptr_.reset(); }
    bool closed() const noexcept { return !ptr_; }

    // How many entries the tree holds. On a closed tree, a bad access.
    std::size_t size() const {
        if (!ptr_) cadaclysm::detail::bad_access("rtree", "closed");
        return ::cadaclysm_blacksmith_rtree_count(ptr_.get());
    }
    // Whether the tree holds no entry.
    bool empty() const { return size() == 0; }

    // The union of every entry's box, or nullopt for an empty tree.
    Result<std::optional<Box>> bounds() const {
        if (!ptr_) return closed_error();
        if (::cadaclysm_blacksmith_rtree_count(ptr_.get()) == 0) return std::optional<Box>{};
        std::array<double, 6> out{};
        if (!::cadaclysm_blacksmith_rtree_bounds(ptr_.get(), out.data())) return detail::kernel_error("rtree_bounds");
        return std::optional<Box>(Box({out[0], out[1], out[2]}, {out[3], out[4], out[5]}));
    }

    // Add the entry (id, box). A box that is not a box is refused and leaves the tree as it was.
    Result<void> insert(std::uint32_t id, const Box& box) {
        if (!ptr_) return closed_error();
        const std::array<double, 6> words = detail::rtree_words(box);
        if (!::cadaclysm_blacksmith_rtree_insert(ptr_.get(), id, words.data())) return detail::kernel_error("rtree_insert");
        return {};
    }
    // Add the entry (id, point), the point a zero box. A point not finite is refused and leaves the
    // tree as it was.
    Result<void> insert(std::uint32_t id, const Vec3& point) {
        if (!ptr_) return closed_error();
        if (!::cadaclysm_blacksmith_rtree_insert_point(ptr_.get(), id, point.data())) {
            return detail::kernel_error("rtree_insert_point");
        }
        return {};
    }

    // Take out one entry equal to (id, box) -- the box it was inserted with, compared coordinate
    // by coordinate -- and say whether there was one: false, not an error, when there is none.
    // With duplicates, one goes per call. A box that is not a box is refused.
    Result<bool> remove(std::uint32_t id, const Box& box) { return remove_words(id, detail::rtree_words(box)); }
    // remove() for an entry inserted as a point (its zero box).
    Result<bool> remove(std::uint32_t id, const Vec3& point) {
        return remove_words(id, {point[0], point[1], point[2], point[0], point[1], point[2]});
    }

    // The ids of every entry whose box meets `box` (touching counts), ascending, one per entry. A
    // box that is not a box is refused.
    Result<std::vector<std::uint32_t>> search(const Box& box) const {
        if (!ptr_) return closed_error();
        const std::array<double, 6> words = detail::rtree_words(box);
        CADACLYSM_TRY(hits, detail::rtree_hits(::cadaclysm_blacksmith_rtree_search(ptr_.get(), words.data()), "rtree_search"));
        std::vector<std::uint32_t> ids;
        ids.reserve(hits.size());
        for (const RTreeHit& h : hits) ids.push_back(h.id);
        return ids;
    }

    // Every entry whose box is within `r` of `point` (Euclidean, 0 inside the box; exactly `r`
    // counts), by distance then id. A point not finite or an `r` negative or NaN is refused.
    Result<std::vector<RTreeHit>> within(const Vec3& point, double r) const {
        if (!ptr_) return closed_error();
        return detail::rtree_hits(::cadaclysm_blacksmith_rtree_within(ptr_.get(), point.data(), r), "rtree_within");
    }

    // The `k` entries whose boxes are nearest `point`, by distance then id (the smaller ids win a
    // tie); all of them when `k` is over the count. A point not finite or a `k` above 1000000 is
    // refused.
    Result<std::vector<RTreeHit>> nearest(const Vec3& point, std::uint32_t k) const {
        if (!ptr_) return closed_error();
        return detail::rtree_hits(::cadaclysm_blacksmith_rtree_nearest(ptr_.get(), point.data(), k), "rtree_nearest");
    }

    // Every entry whose box the ray `origin + t * direction`, 0 <= t <= max_t, meets, as hits
    // whose `distance` is the t where the ray enters the box (0 when `origin` is inside it), by t
    // then id. Touching counts. t is in units of `direction`'s length, which is not normalised;
    // `max_t` defaults to infinity. An origin or direction not finite, a zero direction, or a
    // `max_t` negative or NaN is refused.
    Result<std::vector<RTreeHit>> ray(const Vec3& origin, const Vec3& direction,
                                      double max_t = std::numeric_limits<double>::infinity()) const {
        if (!ptr_) return closed_error();
        return detail::rtree_hits(::cadaclysm_blacksmith_rtree_ray(ptr_.get(), origin.data(), direction.data(), max_t),
                                  "rtree_ray");
    }

    // Every pair (a, b), `a` an entry of this tree and `b` one of `other` (which may be this
    // tree), whose boxes are at most `slack` apart on every axis (0: touching), ascending. A
    // `slack` negative or NaN is refused.
    Result<std::vector<RTreePair>> overlaps(const RTree& other, double slack = 0.0) const {
        if (!ptr_ || !other.ptr_) return closed_error();
        return detail::rtree_pairs(::cadaclysm_blacksmith_rtree_overlaps(ptr_.get(), other.ptr_.get(), slack),
                                   "rtree_overlaps");
    }

    // Every unordered pair of distinct entries at most `slack` apart, once each as (smaller id,
    // larger id), ascending -- an id paired with itself only where two entries share it. A
    // `slack` negative or NaN is refused.
    Result<std::vector<RTreePair>> self_overlaps(double slack = 0.0) const {
        if (!ptr_) return closed_error();
        return detail::rtree_pairs(::cadaclysm_blacksmith_rtree_self_overlaps(ptr_.get(), slack), "rtree_self_overlaps");
    }

    // The C handle, for code that calls the C ABI directly. Owned by this RTree.
    const CadaclysmBlacksmithRTree* handle() const noexcept { return ptr_.get(); }

private:
    friend class Solid;
    struct Free {
        void operator()(CadaclysmBlacksmithRTree* p) const noexcept { ::cadaclysm_blacksmith_rtree_free(p); }
    };
    explicit RTree(CadaclysmBlacksmithRTree* raw) : ptr_(raw) {}

    static Result<RTree> adopt(CadaclysmBlacksmithRTree* raw, const char* call) {
        if (!raw) return detail::kernel_error(call);
        return RTree(raw);
    }
    static Error closed_error() { return detail::refuse("rtree: closed"); }

    Result<bool> remove_words(std::uint32_t id, const std::array<double, 6>& words) {
        if (!ptr_) return closed_error();
        if (::cadaclysm_blacksmith_rtree_remove(ptr_.get(), id, words.data())) return true;
        if (!detail::text(::cadaclysm_blacksmith_last_error()).empty()) return detail::kernel_error("rtree_remove");
        return false;
    }

    std::unique_ptr<CadaclysmBlacksmithRTree, Free> ptr_;
};

// For each of `needles`, the indices of the `hay` points within `limit` of it, by distance then
// index -- one RTree over the hay answers every needle. A `limit` negative or NaN, then the first
// hay point and the first needle not finite, by index, are refused.
inline Result<std::vector<std::vector<std::size_t>>> closest_points(const std::vector<Vec3>& hay,
                                                                    const std::vector<Vec3>& needles, double limit) {
    if (!(limit >= 0.0)) return detail::refuse("closest_points: limit " + detail::rust_number(limit) + " is not a distance");
    CADACLYSM_TRY_VOID(detail::finite_points("closest_points", hay, needles));
    CADACLYSM_TRY(tree, RTree::from_points(hay));
    std::vector<std::vector<std::size_t>> out;
    out.reserve(needles.size());
    for (const Vec3& p : needles) {
        CADACLYSM_TRY(hits, tree.within(p, limit));
        std::vector<std::size_t> ids;
        ids.reserve(hits.size());
        for (const RTreeHit& h : hits) ids.push_back(h.id);
        out.push_back(std::move(ids));
    }
    return out;
}

// For each of `needles`, the indices of the `k` nearest `hay` points, by distance then index (all
// of them when `k` is over the hay count). The first hay point and the first needle not finite,
// by index, then a `k` above 1000000, are refused.
inline Result<std::vector<std::vector<std::size_t>>> k_neighbors(const std::vector<Vec3>& hay,
                                                                 const std::vector<Vec3>& needles, std::uint32_t k) {
    CADACLYSM_TRY_VOID(detail::finite_points("k_neighbors", hay, needles));
    if (k > 1000000) return detail::refuse("k_neighbors: k " + std::to_string(k) + " is not at most 1000000");
    CADACLYSM_TRY(tree, RTree::from_points(hay));
    std::vector<std::vector<std::size_t>> out;
    out.reserve(needles.size());
    for (const Vec3& p : needles) {
        CADACLYSM_TRY(hits, tree.nearest(p, k));
        std::vector<std::size_t> ids;
        ids.reserve(hits.size());
        for (const RTreeHit& h : hits) ids.push_back(h.id);
        out.push_back(std::move(ids));
    }
    return out;
}

// Every pair of `parts` -- or, with `others`, every part of `parts` against every part of
// `others` -- that penetrates, touches or lies within `clearance` of the other, as Clash rows in
// pair order, the solids as they stand, meshed at `tolerance` (absolute). `allowed` pairs of
// part indices are never tested (designed contacts); with `others` a pair is (index in `parts`,
// index in `others`). In a row `a` indexes `parts` and `b` indexes `others` (or `parts` again,
// then `a < b`). For the same parts moved pose after pose, build a Collider and ask
// Collider::clash.
//
// Refused for an empty `others` (`clash: an empty set`; pass nothing for one set), and with the
// kernel's words (`clash: ...`) for a negative or non-finite `clearance`, a `tolerance` not
// positive and finite, an `allowed` index out of range or a part that is not a closed solid.
inline Result<std::vector<Clash>> clash(const Solids& parts, const std::optional<Solids>& others = std::nullopt,
                                        double clearance = 0.0, double tolerance = DEFAULT_TOLERANCE,
                                        const std::vector<std::pair<std::uint32_t, std::uint32_t>>& allowed = {}) {
    if (others && others->empty()) return detail::refuse("clash: an empty set");
    std::vector<const CadaclysmBlacksmithSolid*> first;
    first.reserve(parts.size());
    for (const Solid& s : parts) first.push_back(s.handle());
    std::vector<const CadaclysmBlacksmithSolid*> second;
    if (others) {
        second.reserve(others->size());
        for (const Solid& s : *others) second.push_back(s.handle());
    }
    std::vector<std::uint32_t> allowed_flat;
    allowed_flat.reserve(allowed.size() * 2);
    for (const std::pair<std::uint32_t, std::uint32_t>& pair : allowed) {
        allowed_flat.push_back(pair.first);
        allowed_flat.push_back(pair.second);
    }
    CadaclysmBlacksmithClashes* h = ::cadaclysm_blacksmith_clash(
        first.data(), static_cast<std::uint32_t>(first.size()), others ? second.data() : nullptr,
        static_cast<std::uint32_t>(second.size()), tolerance, clearance, allowed_flat.empty() ? nullptr : allowed_flat.data(),
        static_cast<std::uint32_t>(allowed.size()));
    return detail::ClashRows::read(h, "clash");
}

// Every pair of `parts` -- or, with `others`, every part of `parts` against every part of
// `others` -- that penetrates, touches or comes within `clearance` of the other anywhere on a
// path, as SweptClash rows in pair order. Each part is its own group: pose `k` of `poses` is one
// frame per part of `parts`, and pose `k` of `other_poses` one per part of `others` (the two go
// together, and have as many poses). The motion between poses, the guarantee, `resolution` and
// `max_steps` are Collider::swept_clash's. `tolerance` is the meshing tolerance, absolute.
// `allowed` pairs of part indices are never tested; with `others` a pair is (index in `parts`,
// index in `others`). In a row `a` indexes `parts` and `b` indexes `others` (or `parts` again).
//
// Refused for `others` without `other_poses` or the other way round (`swept_clash: others and
// other_poses go together`), a different number of poses in the two, a pose with the wrong
// number of frames, an empty `others` (`swept_clash: an empty set`; pass nothing for one set),
// and with the kernel's words (`swept_clash: ...`) for fewer than two poses, an `allowed` index
// out of range, a part that is not a closed solid, or a bad frame, tolerance, `clearance`,
// `resolution` or `max_steps`.
inline Result<std::vector<SweptClash>> swept_clash(const Solids& parts, const Poses& poses,
                                                   const std::optional<Solids>& others = std::nullopt,
                                                   const std::optional<Poses>& other_poses = std::nullopt, double clearance = 0.0,
                                                   double tolerance = DEFAULT_TOLERANCE, double resolution = 1e-3,
                                                   std::uint32_t max_steps = 100000,
                                                   const std::vector<std::pair<std::uint32_t, std::uint32_t>>& allowed = {}) {
    if (others.has_value() != other_poses.has_value()) return detail::refuse("swept_clash: others and other_poses go together");
    // C reads each set's poses at its part count: the kernel's own checks, in its order
    if (other_poses && other_poses->size() != poses.size()) {
        return detail::refuse("swept_clash: " + std::to_string(poses.size()) + " poses for set a, " +
                              std::to_string(other_poses->size()) + " for set b");
    }
    const std::pair<const char*, std::pair<const Poses*, std::size_t>> sets[] = {
        {"a", {&poses, parts.size()}},
        {"b", {other_poses ? &*other_poses : nullptr, others ? others->size() : 0}},
    };
    for (const std::pair<const char*, std::pair<const Poses*, std::size_t>>& set : sets) {
        if (!set.second.first) continue;
        const Poses& frames = *set.second.first;
        for (std::size_t k = 0; k < frames.size(); ++k) {
            if (frames[k].size() != set.second.second) {
                return detail::refuse("swept_clash: pose " + std::to_string(k) + " of set " + set.first + " has " +
                                      std::to_string(frames[k].size()) + " frames for " + std::to_string(set.second.second) +
                                      " parts");
            }
        }
    }
    if (others && others->empty()) return detail::refuse("swept_clash: an empty set");
    std::vector<const CadaclysmBlacksmithSolid*> first;
    first.reserve(parts.size());
    for (const Solid& s : parts) first.push_back(s.handle());
    std::vector<const CadaclysmBlacksmithSolid*> second;
    if (others) {
        second.reserve(others->size());
        for (const Solid& s : *others) second.push_back(s.handle());
    }
    std::vector<double> flat_a = detail::flat_poses(poses);
    std::vector<double> flat_b = other_poses ? detail::flat_poses(*other_poses) : std::vector<double>{};
    std::vector<std::uint32_t> allowed_flat;
    allowed_flat.reserve(allowed.size() * 2);
    for (const std::pair<std::uint32_t, std::uint32_t>& pair : allowed) {
        allowed_flat.push_back(pair.first);
        allowed_flat.push_back(pair.second);
    }
    CadaclysmBlacksmithSweptClashes* h = ::cadaclysm_blacksmith_swept_clash(
        first.data(), static_cast<std::uint32_t>(first.size()), flat_a.data(), others ? second.data() : nullptr,
        static_cast<std::uint32_t>(second.size()), others ? flat_b.data() : nullptr, static_cast<std::uint32_t>(poses.size()), tolerance,
        clearance, resolution, max_steps, allowed_flat.empty() ? nullptr : allowed_flat.data(), static_cast<std::uint32_t>(allowed.size()));
    return detail::swept_clashes_of(h, "swept_clash");
}

// ---- wall thickness ---------------------------------------------------------------------

// One wall-thickness reading on a solid (ThicknessGauge::thickness / thickness_at, thickness()).
// `point` lies on face `face` of body `body` (the body's index in the gauge): at vertex `vertex`
// of that body's measuring mesh (ThicknessGauge::mesh), or `vertex` nullopt for a reading at a
// point. `thickness` is the nearest-opposing-wall rule (the nearest triangle that faces against
// one of the vertex's own faces, with the vertex behind it) on the measuring mesh, to `opposite`
// on face `opposite_face` of body `opposite_body`; `knife` marks a knife edge (thickness 0,
// `opposite` == `point`). `exact_opposite` is `opposite` moved onto its exact face where its foot
// lies within the tolerance and inside the face's trims, `exact_thickness` the distance to it.
// `sphere` is the diameter of the largest ball tangent at `point` that holds none of the
// surfaces, nullopt where none under the maximum does (0 on a knife edge).
struct Thickness {
    std::uint32_t body = 0;
    std::optional<std::uint32_t> vertex;
    std::uint32_t face = 0;
    Vec3 point = {};
    double thickness = 0.0;
    Vec3 opposite = {};
    std::uint32_t opposite_body = 0;
    std::uint32_t opposite_face = 0;
    bool knife = false;
    double exact_thickness = 0.0;
    Vec3 exact_opposite = {};
    std::optional<double> sphere;
};

// A face's thickness, found (ThicknessGauge::thickness_at_face, Solid::thickness_at_face; where
// nothing is found those answer nullopt): `thickness` the median of the face's vertex readings
// (or the reading at `at`), `min` and `max` their extremes, `uniform` whether `max - min` is
// within the gauge's tolerance.
struct FaceThickness {
    double thickness = 0.0;
    double min = 0.0;
    double max = 0.0;
    bool uniform = false;
};

// A body's measuring mesh (ThicknessGauge::mesh), copied out of the gauge: `positions` and
// `normals` (unit, outward) one point per vertex -- a reading's `vertex` indexes them; no vertex
// is shared between two faces -- `triangles` three vertex indices each, and `faces` the B-rep
// face of each triangle.
struct ThicknessMesh {
    std::vector<Vec3> positions;
    std::vector<Vec3> normals;
    std::vector<std::array<std::uint32_t, 3>> triangles;
    std::vector<std::uint32_t> faces;
};

// One reading on a plain mesh (mesh_thickness): vertex `vertex` of mesh `mesh`, at `point`,
// reads `thickness` to `opposite` on triangle `opposite_triangle` of mesh `opposite_mesh` (both
// indices within that mesh). `knife`: a knife edge, thickness 0 and `opposite` == `point`.
struct MeshThickness {
    std::uint32_t mesh = 0;
    std::uint32_t vertex = 0;
    double thickness = 0.0;
    Vec3 point = {};
    Vec3 opposite = {};
    std::uint32_t opposite_mesh = 0;
    std::uint32_t opposite_triangle = 0;
    bool knife = false;
};

// One mesh for mesh_thickness: its points and its triangles, each three indices into the points.
struct ThicknessInputMesh {
    std::vector<Vec3> positions;
    std::vector<std::array<std::uint32_t, 3>> triangles;
};

namespace detail {
inline Vec3 vec3_of(const double (&p)[3]) { return Vec3{p[0], p[1], p[2]}; }

// A thicknesses handle (null: `call`'s refusal from last_error) read out into rows and freed on
// every path; a failing read frees it and reports `thicknesses_at: ...`.
inline Result<std::vector<Thickness>> thicknesses_of(CadaclysmBlacksmithThicknesses* h, const char* call) {
    if (!h) return kernel_error(call);
    std::vector<Thickness> rows;
    std::uint32_t count = ::cadaclysm_blacksmith_thicknesses_count(h);
    rows.reserve(count);
    for (std::uint32_t i = 0; i < count; ++i) {
        CadaclysmBlacksmithThickness raw{};
        if (!::cadaclysm_blacksmith_thicknesses_at(h, i, &raw)) {
            Error refusal = kernel_error("thicknesses_at");
            ::cadaclysm_blacksmith_thicknesses_free(h);
            return refusal;
        }
        Thickness row;
        row.body = raw.body;
        if (raw.vertex != NONE) row.vertex = raw.vertex;
        row.face = raw.face;
        row.point = vec3_of(raw.point);
        row.thickness = raw.thickness;
        row.opposite = vec3_of(raw.opposite);
        row.opposite_body = raw.opposite_body;
        row.opposite_face = raw.opposite_face;
        row.knife = raw.knife;
        row.exact_thickness = raw.exact_thickness;
        row.exact_opposite = vec3_of(raw.exact_opposite);
        if (!std::isnan(raw.sphere)) row.sphere = raw.sphere;
        rows.push_back(row);
    }
    ::cadaclysm_blacksmith_thicknesses_free(h);
    return rows;
}
}  // namespace detail

// Wall thickness (the nearest-opposing-wall rule: each vertex reads to the nearest triangle that
// faces against one of its own faces, with the vertex behind it) over `solids`, measured
// against each other: each solid meshed once at `tolerance` -- absolute, in model units (default
// 0.01) -- then asked as often as needed. A reading's `body` is the solid's index in `solids`.
// The gauge holds its own reference to the bodies, so it answers on after the Solids are closed.
// Move-only; the destructor frees the handle, as close() does early. A Result-returning call on
// a closed gauge is refused, "thickness_gauge: closed".
class ThicknessGauge {
public:
    // Hand-written for the reason Collider's are: a raw handle's default move frees twice.
    ThicknessGauge(ThicknessGauge&& other) noexcept : handle_(other.handle_) { other.handle_ = nullptr; }
    ThicknessGauge& operator=(ThicknessGauge&& other) noexcept {
        if (this != &other) {
            close();
            handle_ = other.handle_;
            other.handle_ = nullptr;
        }
        return *this;
    }
    ThicknessGauge(const ThicknessGauge&) = delete;
    ThicknessGauge& operator=(const ThicknessGauge&) = delete;

    ~ThicknessGauge() { close(); }

    void close() noexcept {
        if (handle_) {
            ::cadaclysm_blacksmith_thickness_gauge_free(handle_);
            handle_ = nullptr;
        }
    }
    bool closed() const noexcept { return handle_ == nullptr; }

    // Refused (`thickness_gauge_new: ...`) for a `tolerance` not positive and finite.
    static Result<ThicknessGauge> make(const Solids& solids, double tolerance = THICKNESS_TOLERANCE) {
        std::vector<const CadaclysmBlacksmithSolid*> handles;
        handles.reserve(solids.size());
        for (const Solid& s : solids) handles.push_back(s.handle());
        // The array is never null, even for an empty gauge.
        const CadaclysmBlacksmithSolid* empty = nullptr;
        CadaclysmBlacksmithThicknessGauge* h = ::cadaclysm_blacksmith_thickness_gauge_new(
            handles.empty() ? &empty : handles.data(), static_cast<std::uint32_t>(handles.size()), tolerance);
        if (!h) return detail::kernel_error("thickness_gauge_new");
        return ThicknessGauge(h);
    }

    // How many bodies the gauge measures.
    std::uint32_t body_count() const { return ::cadaclysm_blacksmith_thickness_gauge_body_count(raw_handle("body_count")); }

    // The tolerance the gauge meshed its bodies at.
    double tolerance() const { return ::cadaclysm_blacksmith_thickness_gauge_tolerance(raw_handle("tolerance")); }

    // One reading per measuring-mesh vertex that has one within `maximum` (positive and finite),
    // by body then vertex; vertices whose interior angle is under `sharp_angle` radians (zero or
    // more) are knife edges. Refused (`thickness_gauge_measure: ...`) for a bad limit.
    Result<std::vector<Thickness>> thickness(double maximum, double sharp_angle = 0.0) const {
        if (!handle_) return closed_refusal();
        return detail::thicknesses_of(::cadaclysm_blacksmith_thickness_gauge_measure(handle_, maximum, sharp_angle),
                                      "thickness_gauge_measure");
    }

    // The reading at `point`'s foot on face `face` of body `body` (its `vertex` nullopt), or
    // nullopt where the foot lies off the face or the wall is thicker than `maximum`. Refused
    // (`thickness_gauge_at: ...`) for a body or face past the end, a point not finite or a bad
    // limit.
    Result<std::optional<Thickness>> thickness_at(std::uint32_t body, std::uint32_t face, const Vec3& point, double maximum,
                                                  double sharp_angle = 0.0) const {
        if (!handle_) return closed_refusal();
        Result<std::vector<Thickness>> rows = detail::thicknesses_of(
            ::cadaclysm_blacksmith_thickness_gauge_at(handle_, body, face, point.data(), maximum, sharp_angle),
            "thickness_gauge_at");
        if (!rows) return rows.error();
        if (rows.value().empty()) return std::optional<Thickness>();
        return std::optional<Thickness>(rows.value().front());
    }

    // One thickness for face `face` of body `body`: measured over the face's vertices; the other
    // bodies are measured with it. nullopt where nothing is found (nothing reads under
    // `maximum`). `maximum` has no default. Refused (`thickness_gauge_face: ...`) for a body or
    // face past the end or a bad maximum.
    Result<std::optional<FaceThickness>> thickness_at_face(std::uint32_t body, std::uint32_t face, double maximum) const {
        return thickness_at_face(body, face, std::optional<Vec3>(), maximum);
    }

    // The same measured at `at`'s foot on the face (nullopt: over the face's vertices, as above);
    // nullopt also where `at`'s foot lies off the face. Refused (`thickness_gauge_face: ...`) for
    // an `at` not finite too.
    Result<std::optional<FaceThickness>> thickness_at_face(std::uint32_t body, std::uint32_t face, const std::optional<Vec3>& at,
                                                           double maximum) const {
        if (!handle_) return closed_refusal();
        CadaclysmBlacksmithFaceThickness raw{};
        if (!::cadaclysm_blacksmith_thickness_gauge_face(handle_, body, face, at ? at->data() : nullptr, maximum, &raw)) {
            return detail::kernel_error("thickness_gauge_face");
        }
        if (!raw.found) return std::optional<FaceThickness>();
        return std::optional<FaceThickness>(FaceThickness{raw.thickness, raw.min, raw.max, raw.uniform});
    }

    // Body `body`'s measuring mesh, copied out (it outlives the gauge). Refused
    // (`thickness_gauge_mesh: ...`) for a body past the end.
    Result<ThicknessMesh> mesh(std::uint32_t body) const {
        if (!handle_) return closed_refusal();
        CadaclysmBlacksmithThicknessMesh raw{};
        if (!::cadaclysm_blacksmith_thickness_gauge_mesh(handle_, body, &raw)) return detail::kernel_error("thickness_gauge_mesh");
        ThicknessMesh out;
        out.positions.reserve(raw.vertex_count);
        out.normals.reserve(raw.vertex_count);
        for (std::uint32_t i = 0; i < raw.vertex_count; ++i) {
            out.positions.push_back(Vec3{raw.positions[3 * i], raw.positions[3 * i + 1], raw.positions[3 * i + 2]});
            out.normals.push_back(Vec3{raw.normals[3 * i], raw.normals[3 * i + 1], raw.normals[3 * i + 2]});
        }
        out.triangles.reserve(raw.triangle_count);
        out.faces.reserve(raw.triangle_count);
        for (std::uint32_t i = 0; i < raw.triangle_count; ++i) {
            out.triangles.push_back(std::array<std::uint32_t, 3>{raw.indices[3 * i], raw.indices[3 * i + 1], raw.indices[3 * i + 2]});
            out.faces.push_back(raw.faces[i]);
        }
        return out;
    }

    // The C handle, for code that calls the C ABI directly. Owned by this gauge.
    const CadaclysmBlacksmithThicknessGauge* handle() const noexcept { return handle_; }

private:
    explicit ThicknessGauge(CadaclysmBlacksmithThicknessGauge* h) : handle_(h) {}

    static Error closed_refusal() { return detail::refuse("thickness_gauge: closed"); }

    const CadaclysmBlacksmithThicknessGauge* raw_handle(const char* what) const {
        if (!handle_) cadaclysm::detail::bad_access(what, "the thickness gauge is closed");
        return handle_;
    }

    CadaclysmBlacksmithThicknessGauge* handle_ = nullptr;
};

// ThicknessGauge::make(solids, tolerance)->thickness(maximum, sharp_angle) on a gauge used once
// and freed: every reading within `maximum` on the solids, measured against each other. Refused
// with the gauge call's own prefix (`thickness_gauge_new: ...`, `thickness_gauge_measure: ...`).
inline Result<std::vector<Thickness>> thickness(const Solids& solids, double maximum, double sharp_angle = 0.0,
                                                double tolerance = THICKNESS_TOLERANCE) {
    Result<ThicknessGauge> gauge = ThicknessGauge::make(solids, tolerance);
    if (!gauge) return gauge.error();
    return gauge.value().thickness(maximum, sharp_angle);
}

// The nearest-opposing-wall rule on plain meshes measured against each other: one reading per
// vertex that has one within `maximum` (positive and finite), by mesh then vertex; `sharp_angle`
// as for ThicknessGauge::thickness. Refused (`mesh_thickness: ...`) for a triangle past its mesh,
// a position not finite or a bad limit.
inline Result<std::vector<MeshThickness>> mesh_thickness(const std::vector<ThicknessInputMesh>& meshes, double maximum,
                                                         double sharp_angle = 0.0) {
    std::vector<double> positions;
    std::vector<std::uint32_t> indices;
    std::vector<std::uint32_t> vertex_counts;
    std::vector<std::uint32_t> triangle_counts;
    for (const ThicknessInputMesh& mesh : meshes) {
        for (const Vec3& p : mesh.positions) positions.insert(positions.end(), p.begin(), p.end());
        for (const std::array<std::uint32_t, 3>& t : mesh.triangles) indices.insert(indices.end(), t.begin(), t.end());
        vertex_counts.push_back(static_cast<std::uint32_t>(mesh.positions.size()));
        triangle_counts.push_back(static_cast<std::uint32_t>(mesh.triangles.size()));
    }
    // The count arrays are never null, even with no meshes.
    std::uint32_t none = 0;
    CadaclysmBlacksmithMeshThicknesses* h = ::cadaclysm_blacksmith_mesh_thickness(
        positions.data(), vertex_counts.empty() ? &none : vertex_counts.data(), indices.data(),
        triangle_counts.empty() ? &none : triangle_counts.data(), static_cast<std::uint32_t>(meshes.size()), maximum, sharp_angle);
    if (!h) return detail::kernel_error("mesh_thickness");
    std::vector<MeshThickness> rows;
    std::uint32_t count = ::cadaclysm_blacksmith_mesh_thicknesses_count(h);
    rows.reserve(count);
    for (std::uint32_t i = 0; i < count; ++i) {
        CadaclysmBlacksmithMeshThickness raw{};
        if (!::cadaclysm_blacksmith_mesh_thicknesses_at(h, i, &raw)) {
            Error refusal = detail::kernel_error("mesh_thicknesses_at");
            ::cadaclysm_blacksmith_mesh_thicknesses_free(h);
            return refusal;
        }
        MeshThickness row;
        row.mesh = raw.mesh;
        row.vertex = raw.vertex;
        row.thickness = raw.thickness;
        row.point = detail::vec3_of(raw.point);
        row.opposite = detail::vec3_of(raw.opposite);
        row.opposite_mesh = raw.opposite_mesh;
        row.opposite_triangle = raw.opposite_triangle;
        row.knife = raw.knife;
        rows.push_back(row);
    }
    ::cadaclysm_blacksmith_mesh_thicknesses_free(h);
    return rows;
}

inline Result<std::optional<FaceThickness>> Solid::thickness_at_face(std::uint32_t face, double maximum, double tolerance) const {
    return thickness_at_face(face, std::optional<Vec3>(), maximum, tolerance);
}

inline Result<std::optional<FaceThickness>> Solid::thickness_at_face(std::uint32_t face, const std::optional<Vec3>& at, double maximum,
                                                                     double tolerance) const {
    Result<ThicknessGauge> gauge = ThicknessGauge::make(Solids{*this}, tolerance);
    if (!gauge) return gauge.error();
    return gauge.value().thickness_at_face(0, face, at, maximum);
}

// ---- interpolator -----------------------------------------------------------------------

// How Interpolator::at and Interpolator::sample read between samples (Paul Bourke's formulas):
// the C constants CADACLYSM_BLACKSMITH_INTERPOLATE_*, in their order.
enum class InterpolatorMode : std::uint32_t {
    nearest = CADACLYSM_BLACKSMITH_INTERPOLATE_NEAREST,
    linear = CADACLYSM_BLACKSMITH_INTERPOLATE_LINEAR,
    cosine = CADACLYSM_BLACKSMITH_INTERPOLATE_COSINE,
    cubic = CADACLYSM_BLACKSMITH_INTERPOLATE_CUBIC,
    catmull_rom = CADACLYSM_BLACKSMITH_INTERPOLATE_CATMULL_ROM,
};

// A list of samples read at a fractional index, as Rhino's Interpolator: `t = 2` is sample 2,
// `t = 2.5` halfway between samples 2 and 3. Animation keys, a value along a pattern, a smoothed
// profile of measurements. make() takes numbers (dimension 1), from_rows() equal-length rows of
// any dimension; every answer is a std::vector of `dimension` numbers, each component read on its
// own. An open list clamps `t` to [0, size() - 1]; a cyclic one wraps `t` with period size().
// The five modes: `nearest` the sample at floor(t + 1/2); `linear`; `cosine` linear on a cosine
// ease, flat at every sample; `cubic` Bourke's cubic through every sample; `catmull_rom` through
// every sample, C1. Every mode returns the sample itself at a whole `t`. Immutable; move-only; the
// destructor frees it, as close() does early. A call on a closed or moved-from interpolator is
// refused, "interpolator: closed". Python's Interpolator.
class Interpolator {
public:
    Interpolator(Interpolator&&) noexcept = default;
    Interpolator& operator=(Interpolator&&) noexcept = default;
    Interpolator(const Interpolator&) = delete;
    Interpolator& operator=(const Interpolator&) = delete;

    // An interpolator over numbers, dimension 1. No samples, or one NaN or infinite (by its
    // index), is refused.
    static Result<Interpolator> make(const std::vector<double>& samples, bool cyclic = false) {
        if (samples.size() > std::numeric_limits<std::uint32_t>::max()) {
            return detail::refuse("interpolator_new: " + std::to_string(samples.size()) + " samples is more than 4294967295");
        }
        return adopt(::cadaclysm_blacksmith_interpolator_new(samples.empty() ? nullptr : samples.data(),
                                                             static_cast<std::uint32_t>(samples.size()), 1, cyclic));
    }

    // An interpolator over rows of numbers -- 2D or 3D points, or vectors of any dimension, the
    // dimension the rows' length. Rows of unequal length are refused before the call; no rows,
    // rows of no numbers or a number NaN or infinite (by its sample's index) are the kernel's.
    static Result<Interpolator> from_rows(const std::vector<std::vector<double>>& rows, bool cyclic = false) {
        std::size_t dimension = rows.empty() ? 1 : rows[0].size();
        for (const std::vector<double>& row : rows) {
            if (row.size() != dimension) {
                return detail::refuse("interpolator: samples differ in length (" + std::to_string(dimension) + " and " +
                                      std::to_string(row.size()) + ")");
            }
        }
        if (rows.size() > std::numeric_limits<std::uint32_t>::max() || dimension > std::numeric_limits<std::uint32_t>::max() ||
            (dimension > 0 && rows.size() > std::numeric_limits<std::uint32_t>::max() / dimension)) {
            return detail::refuse("interpolator_new: " + std::to_string(rows.size()) + " samples of " +
                                  std::to_string(dimension) + " is too many");
        }
        std::vector<double> flat;
        flat.reserve(rows.size() * dimension);
        for (const std::vector<double>& row : rows) flat.insert(flat.end(), row.begin(), row.end());
        return adopt(::cadaclysm_blacksmith_interpolator_new(flat.empty() ? nullptr : flat.data(),
                                                             static_cast<std::uint32_t>(rows.size()),
                                                             static_cast<std::uint32_t>(dimension), cyclic));
    }

    void close() noexcept { ptr_.reset(); }
    bool closed() const noexcept { return !ptr_; }

    // How many samples. On a closed interpolator, a bad access.
    std::size_t size() const { return ::cadaclysm_blacksmith_interpolator_count(live()); }
    // How many numbers a sample holds, and so every answer. On a closed interpolator, a bad access.
    std::uint32_t dimension() const { return ::cadaclysm_blacksmith_interpolator_dimension(live()); }
    // Whether `t` wraps round the list (else it is clamped to the ends). On a closed
    // interpolator, a bad access.
    bool cyclic() const { return ::cadaclysm_blacksmith_interpolator_cyclic(live()); }

    // The value at the fractional index `t` by `mode`: `dimension()` numbers. A `t` NaN or
    // infinite is refused.
    Result<std::vector<double>> at(double t, InterpolatorMode mode = InterpolatorMode::linear) const {
        if (!ptr_) return closed_error();
        std::uint32_t d = ::cadaclysm_blacksmith_interpolator_dimension(ptr_.get());
        std::vector<double> out(d);
        if (!::cadaclysm_blacksmith_interpolator_at(ptr_.get(), t, static_cast<std::uint32_t>(mode), out.data(), d)) {
            return detail::kernel_error("interpolator_at");
        }
        return out;
    }

    // The values at every `t` of `ts` by `mode`, as at() reads each, in one call. A value of `t`
    // NaN or infinite (by its index), or more than 1000000 of them, is refused; no `ts` answers
    // an empty vector without a call.
    Result<std::vector<std::vector<double>>> sample(const std::vector<double>& ts,
                                                    InterpolatorMode mode = InterpolatorMode::linear) const {
        if (!ptr_) return closed_error();
        if (ts.empty()) return std::vector<std::vector<double>>{};
        if (ts.size() > std::numeric_limits<std::uint32_t>::max()) {
            return detail::refuse("interpolator_sample: " + std::to_string(ts.size()) + " values is more than 4294967295");
        }
        std::size_t d = ::cadaclysm_blacksmith_interpolator_dimension(ptr_.get());
        std::size_t total = ts.size() * d;
        std::vector<double> flat(total);
        std::uint32_t out_len = total > std::numeric_limits<std::uint32_t>::max() ? std::numeric_limits<std::uint32_t>::max()
                                                                                  : static_cast<std::uint32_t>(total);
        if (!::cadaclysm_blacksmith_interpolator_sample(ptr_.get(), ts.data(), static_cast<std::uint32_t>(ts.size()),
                                                        static_cast<std::uint32_t>(mode), flat.data(), out_len)) {
            return detail::kernel_error("interpolator_sample");
        }
        std::vector<std::vector<double>> out;
        out.reserve(ts.size());
        for (std::size_t k = 0; k < ts.size(); ++k) {
            out.emplace_back(flat.begin() + static_cast<std::ptrdiff_t>(k * d),
                             flat.begin() + static_cast<std::ptrdiff_t>((k + 1) * d));
        }
        return out;
    }

    // The sample at floor(t + 1/2) -- a half rounds up -- after the clamp or wrap.
    Result<std::vector<double>> nearest(double t) const { return at(t, InterpolatorMode::nearest); }
    // Straight between the two samples either side of `t`.
    Result<std::vector<double>> linear(double t) const { return at(t, InterpolatorMode::linear); }
    // Between the two samples either side of `t` on a cosine ease, flat at every sample.
    Result<std::vector<double>> cosine(double t) const { return at(t, InterpolatorMode::cosine); }
    // Bourke's cubic over the four samples about `t`, through every sample.
    Result<std::vector<double>> cubic(double t) const { return at(t, InterpolatorMode::cubic); }
    // The Catmull-Rom spline over the four samples about `t`: through every sample, C1.
    Result<std::vector<double>> catmull_rom(double t) const { return at(t, InterpolatorMode::catmull_rom); }

    // The C handle, for code that calls the C ABI directly. Owned by this Interpolator.
    const CadaclysmBlacksmithInterpolator* handle() const noexcept { return ptr_.get(); }

private:
    struct Free {
        void operator()(CadaclysmBlacksmithInterpolator* p) const noexcept { ::cadaclysm_blacksmith_interpolator_free(p); }
    };
    explicit Interpolator(CadaclysmBlacksmithInterpolator* raw) : ptr_(raw) {}

    static Result<Interpolator> adopt(CadaclysmBlacksmithInterpolator* raw) {
        if (!raw) return detail::kernel_error("interpolator_new");
        return Interpolator(raw);
    }
    static Error closed_error() { return detail::refuse("interpolator: closed"); }
    const CadaclysmBlacksmithInterpolator* live() const {
        if (!ptr_) cadaclysm::detail::bad_access("interpolator", "closed");
        return ptr_.get();
    }

    std::unique_ptr<CadaclysmBlacksmithInterpolator, Free> ptr_;
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
    // `faces` subdivided once by the Catmull-Clark rules (the whole cage when empty): each
    // face becomes quads round a new point, and an unpicked face beside them takes the new
    // edge points as corners. The whole cage keeps its smooth surface exactly. The new cage
    // selects the new faces.
    Result<Subd> subdivide(const std::vector<std::uint32_t>& faces = {}) const {
        const CadaclysmBlacksmithSubd* h = raw_handle("subdivide");
        return wrap(::cadaclysm_blacksmith_subd_subdivide(h, faces.data(), static_cast<std::uint32_t>(faces.size())),
                    "subd_subdivide");
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

// ---- the 2D constraint sketcher ------------------------------------------------------

namespace detail {

// The C ABI's codes, by position; the wrapper speaks the names (Python's _SKETCH_* tables).
inline constexpr std::array<const char*, 5> SKETCH_ENTITY_KINDS = {"point", "line", "circle", "arc", "free_curve"};
inline constexpr std::array<const char*, 27> SKETCH_CONSTRAINT_KINDS = {
    "coincident", "point_on_line", "point_on_circle", "horizontal", "vertical", "parallel", "perpendicular",
    "collinear", "tangent", "tangent_at_end", "concentric", "equal_length", "equal_radius", "midpoint",
    "symmetric", "fix", "distance", "point_line_distance", "line_distance", "circle_line_distance",
    "circle_distance", "horizontal_distance", "vertical_distance", "length", "angle", "radius", "diameter"};
inline constexpr std::array<const char*, 3> SKETCH_SENSES = {"auto", "positive", "negative"};
inline constexpr std::array<const char*, 2> SKETCH_ENDS = {"start", "end"};
inline constexpr std::array<const char*, 3> SKETCH_STATUSES = {"converged", "conflicting", "diverged"};
inline constexpr std::array<const char*, 3> SKETCH_STATES = {"under", "full", "over"};
// sketch_dof_list's and sketch_dof_part_list's `which`.
inline constexpr std::uint32_t DOF_REDUNDANT = 0, DOF_CONFLICTING = 1, DOF_FREE_ENTITIES = 2;
inline constexpr std::uint32_t PART_CONSTRAINTS = 0, PART_REDUNDANT = 1, PART_CONFLICTING = 2, PART_FREE_ENTITIES = 3;

// The name of `code` in `table`; NONE or out of range is the library's reason.
template <std::size_t N>
inline Result<std::string> sketch_named(const std::array<const char*, N>& table, std::uint32_t code, const char* what) {
    if (code == NONE || code >= N) return kernel_error(what);
    return std::string(table[code]);
}

// The code of `name` in `table`, or a refusal naming the call and the parameter.
template <std::size_t N>
inline Result<std::uint32_t> sketch_code(const std::array<const char*, N>& table, const std::string& name,
                                         const char* call, const char* param) {
    for (std::size_t i = 0; i < N; ++i) {
        if (name == table[i]) return static_cast<std::uint32_t>(i);
    }
    std::string message = std::string(call) + ": " + param + " must be one of ";
    for (std::size_t i = 0; i < N; ++i) {
        if (i) message += ", ";
        message += std::string("'") + table[i] + "'";
    }
    return refuse(message + ", not '" + name + "'");
}

// A count or code the library sent as a double: whole, in range, or the library broke its
// contract (a NaN would otherwise read as "converged" or "under").
inline Result<std::uint32_t> sketch_whole(double value, const char* what) {
    if (!(value >= 0.0 && value <= 2147483647.0 && value == std::trunc(value))) {
        return refuse(std::string(what) + ": the library answered " + std::to_string(value) +
                      ", not a whole number in range");
    }
    return static_cast<std::uint32_t>(value);
}

// A drag's moves in ascending id order -- the solve must not depend on the order the caller
// listed them in -- or a refusal naming the first id given twice.
inline Result<std::vector<std::pair<std::uint32_t, Vec2>>> sketch_drag_order(
    const std::vector<std::pair<std::uint32_t, Vec2>>& moves) {
    std::vector<std::pair<std::uint32_t, Vec2>> sorted = moves;
    std::stable_sort(sorted.begin(), sorted.end(),
                     [](const std::pair<std::uint32_t, Vec2>& x, const std::pair<std::uint32_t, Vec2>& y) {
                         return x.first < y.first;
                     });
    for (std::size_t i = 1; i < sorted.size(); ++i) {
        if (sorted[i].first == sorted[i - 1].first) {
            return refuse("sketch_drag: point " + std::to_string(sorted[i].first) + " given twice");
        }
    }
    return sorted;
}

// A list the library lends until the next call on the same sketch, copied out. Null is a
// refusal: the library's reason, no ids.
inline Result<std::vector<std::uint32_t>> sketch_lent(const std::uint32_t* p, std::size_t n, const char* what) {
    if (p == nullptr) return kernel_error(what);
    return std::vector<std::uint32_t>(p, p + n);
}

// `v` as a pointer that is never null: an empty list goes as a valid pointer and a count of
// 0, never as the null the library reads as a refusal of its own.
template <class T>
inline const T* sketch_nonnull(const std::vector<T>& v) {
    static const T zero = T();
    return v.empty() ? &zero : v.data();
}

inline Result<void> sketch_done(bool done, const char* what) {
    if (!done) return kernel_error(what);
    return Result<void>();
}

}  // namespace detail

// The first line of every Sketch call: the handle, or the closed error.
#define CADACLYSM_SKETCH_LIVE_(h) CadaclysmBlacksmithSketch* h = handle_; if (!h) return closed_error()

// What a Sketch::solve, drag, set_value, set_driving or update_reference did: `status`
// ("converged", "conflicting" or "diverged"), how many `iterations`, the largest constraint
// residual left (`max_residual`), and `ids`: the constraints a conflict ran into, or the
// worst ones of a diverged solve (empty when it converged). Plain data.
struct SolveReport {
    std::string status;
    int iterations = 0;
    double max_residual = 0.0;
    std::vector<std::uint32_t> ids;

    bool converged() const { return status == "converged"; }
};

// One independent part of a diagnosed sketch: its `params` (unknowns), how many stay `free`,
// its `state` ("under", "full" or "over"), its `constraints`, the `redundant` and
// `conflicting` ones among them, and its `free_entities`. Plain data.
struct PartDof {
    int params = 0;
    int free = 0;
    std::string state;
    std::vector<std::uint32_t> constraints;
    std::vector<std::uint32_t> redundant;
    std::vector<std::uint32_t> conflicting;
    std::vector<std::uint32_t> free_entities;
};

// A sketch's degrees of freedom (Sketch::diagnose): how many are `free`, its `state`
// ("under", "full" or "over"), the `redundant` and `conflicting` constraint ids, the
// `free_entities` (entities that can still move), and the independent `parts` it splits
// into. Plain data.
struct Dof {
    int free = 0;
    std::string state;
    std::vector<std::uint32_t> redundant;
    std::vector<std::uint32_t> conflicting;
    std::vector<std::uint32_t> free_entities;
    std::vector<PartDof> parts;
};

// What Sketch::add_rect made: the four corner points, counter-clockwise from the first
// corner, and the four sides (side `i` from corner `i`).
struct SketchRect {
    std::array<std::uint32_t, 4> corners;
    std::array<std::uint32_t, 4> sides;
};

// A 2D sketch of points, lines, circles, arcs and free curves held by geometric constraints
// and dimensions, solved on request. Entities and constraints are named by integer ids.
// Entity kinds are "point", "line", "circle", "arc" and "free_curve"; a constraint's kind is
// the name of the method that adds it ("point_line_distance", ...) but for radius_of, whose
// kind is "radius": radius(id) reads a circle's radius. Senses are "auto", "positive" or
// "negative"; ends "start" or "end". Move-only; the destructor frees the handle, as close()
// does early.
//
// A refused call returns the library's text and, as `Error::ids`, the ids the refusal names:
// the constraints a new constraint, value or reference clashes with, the entities still
// using a point (empty when it names none). The SolveReports of solve, drag, set_value,
// set_driving and update_reference carry a returned report's ids the same way. A call on a
// closed sketch is the error "sketch: closed".
class Sketch {
public:
    // Hand-written, not `= default`: see Collider.
    Sketch(Sketch&& other) noexcept : handle_(other.handle_) { other.handle_ = nullptr; }
    Sketch& operator=(Sketch&& other) noexcept {
        if (this != &other) {
            close();
            handle_ = other.handle_;
            other.handle_ = nullptr;
        }
        return *this;
    }
    Sketch(const Sketch&) = delete;
    Sketch& operator=(const Sketch&) = delete;

    ~Sketch() { close(); }

    void close() noexcept {
        if (handle_) {
            ::cadaclysm_blacksmith_sketch_free(handle_);
            handle_ = nullptr;
        }
    }
    bool closed() const noexcept { return handle_ == nullptr; }

    // A new, empty sketch.
    static Result<Sketch> create() {
        CadaclysmBlacksmithSketch* raw = ::cadaclysm_blacksmith_sketch_new();
        if (!raw) return detail::kernel_error("sketch_new");
        return Sketch(raw);
    }
    // A sketch of `profile`'s lines, arcs and curves joined end to end, holes included; with
    // `infer` the obvious constraints (horizontal, vertical, tangent joints, ...) too. Ends
    // within `tolerance` count as joined.
    static Result<Sketch> from_profile(const Profile& profile, bool infer = true, double tolerance = 1e-6) {
        CadaclysmBlacksmithSketch* raw = ::cadaclysm_blacksmith_sketch_from_profile(profile.handle(), infer, tolerance);
        if (!raw) return detail::kernel_error("sketch_from_profile");
        return Sketch(raw);
    }

    // -- entities

    // A free point at (x, y); a coordinate that is not finite is refused.
    Result<std::uint32_t> add_point(double x, double y) {
        CADACLYSM_SKETCH_LIVE_(h);
        return got_id(::cadaclysm_blacksmith_sketch_add_point(h, x, y), "sketch_add_point");
    }
    // A line between the points `a` and `b`.
    Result<std::uint32_t> add_line(std::uint32_t a, std::uint32_t b) {
        CADACLYSM_SKETCH_LIVE_(h);
        return got_id(::cadaclysm_blacksmith_sketch_add_line(h, a, b), "sketch_add_line");
    }
    // A circle of radius `r` about the point `centre`.
    Result<std::uint32_t> add_circle(std::uint32_t centre, double r) {
        CADACLYSM_SKETCH_LIVE_(h);
        return got_id(::cadaclysm_blacksmith_sketch_add_circle(h, centre, r), "sketch_add_circle");
    }
    // A counter-clockwise arc about the point `centre` from the point `start` to the point `end`.
    Result<std::uint32_t> add_arc(std::uint32_t centre, std::uint32_t start, std::uint32_t end) {
        CADACLYSM_SKETCH_LIVE_(h);
        return got_id(::cadaclysm_blacksmith_sketch_add_arc(h, centre, start, end), "sketch_add_arc");
    }
    // A cubic Bezier free curve from the point `start` through the controls `c1` and `c2` to
    // a new end point at `to`; the curve owns its control points.
    Result<std::uint32_t> add_bezier(std::uint32_t start, const Vec2& c1, const Vec2& c2, const Vec2& to) {
        CADACLYSM_SKETCH_LIVE_(h);
        return got_id(::cadaclysm_blacksmith_sketch_add_bezier(h, start, c1[0], c1[1], c2[0], c2[1], to[0], to[1]),
                  "sketch_add_bezier");
    }
    // A rational quadratic (conic) free curve from the point `start` with the control
    // `control` of `weight` to a new end point at `to`.
    Result<std::uint32_t> add_conic(std::uint32_t start, const Vec2& control, const Vec2& to, double weight) {
        CADACLYSM_SKETCH_LIVE_(h);
        return got_id(::cadaclysm_blacksmith_sketch_add_conic(h, start, control[0], control[1], to[0], to[1], weight),
                  "sketch_add_conic");
    }
    // A NURBS free curve of `degree` from the point `start` through the control `points`
    // after it, on `knots`; `weights` none for a plain B-spline, or one per control point
    // counting the start (`points.size() + 1`).
    Result<std::uint32_t> add_nurbs(std::uint32_t start, const std::vector<Vec2>& points, const std::vector<double>& knots,
                                    std::uint32_t degree = 3,
                                    const std::optional<std::vector<double>>& weights = std::nullopt) {
        CADACLYSM_SKETCH_LIVE_(h);
        // The library reads exactly points + 1 weights, whatever the vector holds.
        if (weights && weights->size() != points.size() + 1) {
            return detail::refuse("sketch_add_nurbs: " + std::to_string(weights->size()) + " weights for " +
                                  std::to_string(points.size() + 1) + " control points (the start and " +
                                  std::to_string(points.size()) + " given); give one per point");
        }
        std::vector<double> flat;
        flat.reserve(points.size() * 2);
        for (const Vec2& p : points) {
            flat.push_back(p[0]);
            flat.push_back(p[1]);
        }
        return got_id(::cadaclysm_blacksmith_sketch_add_nurbs(h, start, degree, detail::sketch_nonnull(flat), points.size(),
                                                          weights ? weights->data() : nullptr,
                                                          detail::sketch_nonnull(knots), knots.size()),
                  "sketch_add_nurbs");
    }
    // The rectangle with opposite corners `a` and `b`.
    Result<SketchRect> add_rect(const Vec2& a, const Vec2& b) {
        CADACLYSM_SKETCH_LIVE_(h);
        std::size_t n = 0;
        const std::uint32_t* p = ::cadaclysm_blacksmith_sketch_add_rect(h, a[0], a[1], b[0], b[1], &n);
        Result<std::vector<std::uint32_t>> ids = detail::sketch_lent(p, n, "sketch_add_rect");
        if (!ids) return ids.error();
        if (ids->size() != 8) return detail::refuse("sketch_add_rect: the library answered " + std::to_string(ids->size()) + " ids, not 8");
        SketchRect rect;
        std::copy(ids->begin(), ids->begin() + 4, rect.corners.begin());
        std::copy(ids->begin() + 4, ids->end(), rect.sides.begin());
        return rect;
    }
    // The kind of entity `id`: "point", "line", "circle", "arc" or "free_curve".
    Result<std::string> kind(std::uint32_t id) const {
        CADACLYSM_SKETCH_LIVE_(h);
        return detail::sketch_named(detail::SKETCH_ENTITY_KINDS, ::cadaclysm_blacksmith_sketch_kind(h, id), "sketch_kind");
    }
    // The live entity ids, ascending.
    Result<std::vector<std::uint32_t>> entities() const {
        CADACLYSM_SKETCH_LIVE_(h);
        std::size_t n = 0;
        const std::uint32_t* p = ::cadaclysm_blacksmith_sketch_entities(h, &n);
        return detail::sketch_lent(p, n, "sketch_entities");
    }
    // The point `id`'s position.
    Result<Vec2> point(std::uint32_t id) const {
        CADACLYSM_SKETCH_LIVE_(h);
        Vec2 out = {0.0, 0.0};
        if (!::cadaclysm_blacksmith_sketch_point(h, id, out.data())) return detail::kernel_error("sketch_point");
        return out;
    }
    // Moves the point `id` to (x, y) without solving.
    Result<void> set_point(std::uint32_t id, double x, double y) {
        CADACLYSM_SKETCH_LIVE_(h);
        return detail::sketch_done(::cadaclysm_blacksmith_sketch_set_point(h, id, x, y), "sketch_set_point");
    }
    // The radius of the circle or arc `id` (the RADIUS constraint is radius_of).
    Result<double> radius(std::uint32_t id) const {
        CADACLYSM_SKETCH_LIVE_(h);
        double r = ::cadaclysm_blacksmith_sketch_radius(h, id);
        if (std::isnan(r)) return detail::kernel_error("sketch_radius");
        return r;
    }
    // Sets the circle `id`'s radius to `r` without solving.
    Result<void> set_radius(std::uint32_t id, double r) {
        CADACLYSM_SKETCH_LIVE_(h);
        return detail::sketch_done(::cadaclysm_blacksmith_sketch_set_radius(h, id, r), "sketch_set_radius");
    }
    // The centre point of the circle or arc `id`.
    Result<std::uint32_t> centre(std::uint32_t id) const {
        CADACLYSM_SKETCH_LIVE_(h);
        return got_id(::cadaclysm_blacksmith_sketch_centre(h, id), "sketch_centre");
    }
    // The points entity `id` runs between: a line's {a, b}, an arc's {start, end}, a free
    // curve's {start, controls..., end}.
    Result<std::vector<std::uint32_t>> ends(std::uint32_t id) const {
        CADACLYSM_SKETCH_LIVE_(h);
        std::size_t n = 0;
        const std::uint32_t* p = ::cadaclysm_blacksmith_sketch_ends(h, id, &n);
        return detail::sketch_lent(p, n, "sketch_ends");
    }
    // Marks entity `id` as construction geometry (kept out of profiles), or back.
    Result<void> set_construction(std::uint32_t id, bool on = true) {
        CADACLYSM_SKETCH_LIVE_(h);
        return detail::sketch_done(::cadaclysm_blacksmith_sketch_set_construction(h, id, on), "sketch_set_construction");
    }
    // Whether entity `id` is construction geometry (false for an unknown id).
    Result<bool> is_construction(std::uint32_t id) const {
        CADACLYSM_SKETCH_LIVE_(h);
        return ::cadaclysm_blacksmith_sketch_is_construction(h, id);
    }
    // Whether entity `id` is a reference copy of another sketch's (false for an unknown id).
    Result<bool> is_reference(std::uint32_t id) const {
        CADACLYSM_SKETCH_LIVE_(h);
        return ::cadaclysm_blacksmith_sketch_is_reference(h, id);
    }
    // Removes entity `id` and the constraints on it: the removed constraint ids. Refused for a
    // point that lines or circles still use, the refusal naming them in `Error::ids`.
    Result<std::vector<std::uint32_t>> remove_entity(std::uint32_t id) {
        CADACLYSM_SKETCH_LIVE_(h);
        std::size_t n = 0;
        const std::uint32_t* p = ::cadaclysm_blacksmith_sketch_remove_entity(h, id, &n);
        if (p == nullptr) return detail::sketch_refusal(h, "sketch_remove_entity");
        return detail::sketch_lent(p, n, "sketch_remove_entity");
    }
    // A fixed construction copy of `other`'s entity `entity`, kept in step by
    // update_reference. `other` must be another sketch.
    Result<std::uint32_t> reference(const Sketch& other, std::uint32_t entity) {
        CADACLYSM_SKETCH_LIVE_(h);
        CadaclysmBlacksmithSketch* o = other.handle_;
        if (!o) return closed_error();
        return got_id(::cadaclysm_blacksmith_sketch_reference(h, o, entity), "sketch_reference");
    }
    // Refreshes the reference `id` from `other` and re-solves.
    Result<SolveReport> update_reference(std::uint32_t id, const Sketch& other) {
        CADACLYSM_SKETCH_LIVE_(h);
        CadaclysmBlacksmithSketch* o = other.handle_;
        if (!o) return closed_error();
        double report[3] = {0.0, 0.0, 0.0};
        bool done = ::cadaclysm_blacksmith_sketch_update_reference(h, id, o, report);
        return solved(h, done, report, "sketch_update_reference");
    }

    // -- constraints: each returns the new constraint's id

    Result<std::uint32_t> coincident(std::uint32_t a, std::uint32_t b) { return constrain("coincident", {a, b}); }
    Result<std::uint32_t> point_on_line(std::uint32_t point, std::uint32_t line) {
        return constrain("point_on_line", {point, line});
    }
    // `circle` a circle or an arc.
    Result<std::uint32_t> point_on_circle(std::uint32_t point, std::uint32_t circle) {
        return constrain("point_on_circle", {point, circle});
    }
    // The points `a` and `b` level with each other.
    Result<std::uint32_t> horizontal(std::uint32_t a, std::uint32_t b) { return constrain("horizontal", {a, b}); }
    // The points `a` and `b` one above the other.
    Result<std::uint32_t> vertical(std::uint32_t a, std::uint32_t b) { return constrain("vertical", {a, b}); }
    Result<std::uint32_t> parallel(std::uint32_t a, std::uint32_t b) { return constrain("parallel", {a, b}); }
    Result<std::uint32_t> perpendicular(std::uint32_t a, std::uint32_t b) { return constrain("perpendicular", {a, b}); }
    Result<std::uint32_t> collinear(std::uint32_t a, std::uint32_t b) { return constrain("collinear", {a, b}); }
    Result<std::uint32_t> tangent(std::uint32_t a, std::uint32_t b, const std::string& sense = "auto") {
        return constrain("tangent", {a, b}, 0.0, true, sense);
    }
    // The free curve `curve` tangent to `other` at its `end` ("start" or "end").
    Result<std::uint32_t> tangent_at_end(std::uint32_t curve, std::uint32_t other, const std::string& end = "start") {
        return constrain("tangent_at_end", {curve, other}, 0.0, true, "auto", end);
    }
    Result<std::uint32_t> concentric(std::uint32_t a, std::uint32_t b) { return constrain("concentric", {a, b}); }
    Result<std::uint32_t> equal_length(std::uint32_t a, std::uint32_t b) { return constrain("equal_length", {a, b}); }
    Result<std::uint32_t> equal_radius(std::uint32_t a, std::uint32_t b) { return constrain("equal_radius", {a, b}); }
    Result<std::uint32_t> midpoint(std::uint32_t point, std::uint32_t line) { return constrain("midpoint", {point, line}); }
    // The points `a` and `b` mirror images across the line `about`.
    Result<std::uint32_t> symmetric(std::uint32_t a, std::uint32_t b, std::uint32_t about) {
        return constrain("symmetric", {a, b, about});
    }
    Result<std::uint32_t> fix(std::uint32_t entity) { return constrain("fix", {entity}); }
    Result<std::uint32_t> distance(std::uint32_t a, std::uint32_t b, double value, bool driving = true) {
        return constrain("distance", {a, b}, value, driving);
    }
    Result<std::uint32_t> point_line_distance(std::uint32_t point, std::uint32_t line, double value, bool driving = true,
                                              const std::string& sense = "auto") {
        return constrain("point_line_distance", {point, line}, value, driving, sense);
    }
    Result<std::uint32_t> line_distance(std::uint32_t a, std::uint32_t b, double value, bool driving = true,
                                        const std::string& sense = "auto") {
        return constrain("line_distance", {a, b}, value, driving, sense);
    }
    Result<std::uint32_t> circle_line_distance(std::uint32_t circle, std::uint32_t line, double value, bool driving = true,
                                               const std::string& sense = "auto") {
        return constrain("circle_line_distance", {circle, line}, value, driving, sense);
    }
    Result<std::uint32_t> circle_distance(std::uint32_t a, std::uint32_t b, double value, bool driving = true) {
        return constrain("circle_distance", {a, b}, value, driving);
    }
    Result<std::uint32_t> horizontal_distance(std::uint32_t a, std::uint32_t b, double value, bool driving = true) {
        return constrain("horizontal_distance", {a, b}, value, driving);
    }
    Result<std::uint32_t> vertical_distance(std::uint32_t a, std::uint32_t b, double value, bool driving = true) {
        return constrain("vertical_distance", {a, b}, value, driving);
    }
    Result<std::uint32_t> length(std::uint32_t line, double value, bool driving = true) {
        return constrain("length", {line}, value, driving);
    }
    // The angle from line `a` to line `b`, in radians.
    Result<std::uint32_t> angle(std::uint32_t a, std::uint32_t b, double value, bool driving = true) {
        return constrain("angle", {a, b}, value, driving);
    }
    // The RADIUS dimension (kind "radius") -- radius(id) reads a radius instead.
    Result<std::uint32_t> radius_of(std::uint32_t circle, double value, bool driving = true) {
        return constrain("radius", {circle}, value, driving);
    }
    Result<std::uint32_t> diameter(std::uint32_t circle, double value, bool driving = true) {
        return constrain("diameter", {circle}, value, driving);
    }

    // The live constraint ids, ascending.
    Result<std::vector<std::uint32_t>> constraints() const {
        CADACLYSM_SKETCH_LIVE_(h);
        std::size_t n = 0;
        const std::uint32_t* p = ::cadaclysm_blacksmith_sketch_constraints(h, &n);
        return detail::sketch_lent(p, n, "sketch_constraints");
    }
    // The kind of constraint `id`, e.g. "point_line_distance".
    Result<std::string> constraint_kind(std::uint32_t id) const {
        CADACLYSM_SKETCH_LIVE_(h);
        return detail::sketch_named(detail::SKETCH_CONSTRAINT_KINDS, ::cadaclysm_blacksmith_sketch_constraint_kind(h, id),
                                    "sketch_constraint_kind");
    }
    // The entity ids constraint `id` was made on, in the order given.
    Result<std::vector<std::uint32_t>> constraint_refs(std::uint32_t id) const {
        CADACLYSM_SKETCH_LIVE_(h);
        std::size_t n = 0;
        const std::uint32_t* p = ::cadaclysm_blacksmith_sketch_constraint_refs(h, id, &n);
        return detail::sketch_lent(p, n, "sketch_constraint_refs");
    }
    // The value of the dimension `id`; none for a constraint that is not a dimension. An
    // unknown id is a refusal: the reader answers NaN for both, and only the second leaves a reason.
    Result<std::optional<double>> constraint_value(std::uint32_t id) const {
        CADACLYSM_SKETCH_LIVE_(h);
        double v = ::cadaclysm_blacksmith_sketch_constraint_value(h, id);
        if (std::isnan(v)) {
            if (!detail::text(::cadaclysm_blacksmith_last_error()).empty()) return detail::kernel_error("sketch_constraint_value");
            return std::optional<double>();
        }
        return std::optional<double>(v);
    }
    // Whether the dimension `id` drives the geometry (false for a constraint that is not a
    // dimension; an unknown id is a refusal).
    Result<bool> constraint_driving(std::uint32_t id) const {
        CADACLYSM_SKETCH_LIVE_(h);
        bool driving = ::cadaclysm_blacksmith_sketch_constraint_driving(h, id);
        if (!driving && !detail::text(::cadaclysm_blacksmith_last_error()).empty()) {
            return detail::kernel_error("sketch_constraint_driving");
        }
        return driving;
    }
    // The sense of constraint `id`; "auto" for a kind without one.
    Result<std::string> constraint_sense(std::uint32_t id) const {
        CADACLYSM_SKETCH_LIVE_(h);
        return detail::sketch_named(detail::SKETCH_SENSES, ::cadaclysm_blacksmith_sketch_constraint_sense(h, id),
                                    "sketch_constraint_sense");
    }
    // The end ("start" or "end") of the free curve a tangent_at_end constraint `id` holds;
    // "start" for a kind without one.
    Result<std::string> constraint_end(std::uint32_t id) const {
        CADACLYSM_SKETCH_LIVE_(h);
        return detail::sketch_named(detail::SKETCH_ENDS, ::cadaclysm_blacksmith_sketch_constraint_end(h, id),
                                    "sketch_constraint_end");
    }
    // Whether the tangent constraint `id` joins two curves end to end.
    Result<bool> is_joint_tangent(std::uint32_t id) const {
        CADACLYSM_SKETCH_LIVE_(h);
        return ::cadaclysm_blacksmith_sketch_is_joint_tangent(h, id);
    }
    // Removes the constraint `id`.
    Result<void> remove(std::uint32_t id) {
        CADACLYSM_SKETCH_LIVE_(h);
        return detail::sketch_done(::cadaclysm_blacksmith_sketch_remove(h, id), "sketch_remove");
    }
    // Sets the dimension `id` to `value` and re-solves.
    Result<SolveReport> set_value(std::uint32_t id, double value) {
        CADACLYSM_SKETCH_LIVE_(h);
        double report[3] = {0.0, 0.0, 0.0};
        bool done = ::cadaclysm_blacksmith_sketch_set_value(h, id, value, report);
        return solved(h, done, report, "sketch_set_value");
    }
    // Makes the dimension `id` drive the geometry (true) or only report it, and re-solves.
    Result<SolveReport> set_driving(std::uint32_t id, bool driving) {
        CADACLYSM_SKETCH_LIVE_(h);
        double report[3] = {0.0, 0.0, 0.0};
        bool done = ::cadaclysm_blacksmith_sketch_set_driving(h, id, driving, report);
        return solved(h, done, report, "sketch_set_driving");
    }
    // What the geometry measures for the dimension `id` right now.
    Result<double> measure(std::uint32_t id) const {
        CADACLYSM_SKETCH_LIVE_(h);
        double v = ::cadaclysm_blacksmith_sketch_measure(h, id);
        if (std::isnan(v)) return detail::kernel_error("sketch_measure");
        return v;
    }

    // -- solving and diagnosis

    // Solves the sketch. A conflicting or diverged solve is reported, not refused.
    Result<SolveReport> solve() {
        CADACLYSM_SKETCH_LIVE_(h);
        double report[3] = {0.0, 0.0, 0.0};
        bool done = ::cadaclysm_blacksmith_sketch_solve(h, report);
        return solved(h, done, report, "sketch_solve");
    }
    // Drags each point in `moves` (an id and its target) towards its target while the
    // constraints hold, as a live gesture would. The moves are sent in ascending id order; an id
    // given twice is refused ("sketch_drag: point <id> given twice"), as is one that is not a point.
    Result<SolveReport> drag(const std::vector<std::pair<std::uint32_t, Vec2>>& moves) {
        CADACLYSM_SKETCH_LIVE_(h);
        Result<std::vector<std::pair<std::uint32_t, Vec2>>> ordered = detail::sketch_drag_order(moves);
        if (!ordered) return ordered.error();
        std::vector<std::uint32_t> points;
        std::vector<double> xy;
        points.reserve(moves.size());
        xy.reserve(moves.size() * 2);
        for (const std::pair<std::uint32_t, Vec2>& move : *ordered) {
            points.push_back(move.first);
            xy.push_back(move.second[0]);
            xy.push_back(move.second[1]);
        }
        double report[3] = {0.0, 0.0, 0.0};
        bool done = ::cadaclysm_blacksmith_sketch_drag(h, detail::sketch_nonnull(points), detail::sketch_nonnull(xy),
                                                       points.size(), report);
        return solved(h, done, report, "sketch_drag");
    }
    // The sketch's degrees of freedom, whole and per independent part.
    Result<Dof> diagnose() {
        CADACLYSM_SKETCH_LIVE_(h);
        double out[3] = {0.0, 0.0, 0.0};
        if (!::cadaclysm_blacksmith_sketch_diagnose(h, out)) return detail::kernel_error("sketch_diagnose");
        Dof dof;
        Result<std::uint32_t> free_count = detail::sketch_whole(out[0], "sketch_diagnose");
        if (!free_count) return free_count.error();
        Result<std::uint32_t> state_code = detail::sketch_whole(out[1], "sketch_diagnose");
        if (!state_code) return state_code.error();
        Result<std::uint32_t> part_count = detail::sketch_whole(out[2], "sketch_diagnose");
        if (!part_count) return part_count.error();
        Result<std::string> state = detail::sketch_named(detail::SKETCH_STATES, *state_code, "sketch_diagnose");
        if (!state) return state.error();
        dof.free = static_cast<int>(*free_count);
        dof.state = *state;
        Result<std::vector<std::uint32_t>> redundant = dof_list(h, detail::DOF_REDUNDANT);
        if (!redundant) return redundant.error();
        Result<std::vector<std::uint32_t>> conflicting = dof_list(h, detail::DOF_CONFLICTING);
        if (!conflicting) return conflicting.error();
        Result<std::vector<std::uint32_t>> free_entities = dof_list(h, detail::DOF_FREE_ENTITIES);
        if (!free_entities) return free_entities.error();
        dof.redundant = std::move(redundant).value();
        dof.conflicting = std::move(conflicting).value();
        dof.free_entities = std::move(free_entities).value();
        for (std::uint32_t i = 0; i < *part_count; ++i) {
            double raw[3] = {0.0, 0.0, 0.0};
            if (!::cadaclysm_blacksmith_sketch_dof_part(h, i, raw)) return detail::kernel_error("sketch_dof_part");
            PartDof part;
            Result<std::uint32_t> params = detail::sketch_whole(raw[0], "sketch_dof_part");
            if (!params) return params.error();
            Result<std::uint32_t> part_free = detail::sketch_whole(raw[1], "sketch_dof_part");
            if (!part_free) return part_free.error();
            Result<std::uint32_t> part_state_code = detail::sketch_whole(raw[2], "sketch_dof_part");
            if (!part_state_code) return part_state_code.error();
            Result<std::string> part_state = detail::sketch_named(detail::SKETCH_STATES, *part_state_code, "sketch_dof_part");
            if (!part_state) return part_state.error();
            part.params = static_cast<int>(*params);
            part.free = static_cast<int>(*part_free);
            part.state = *part_state;
            std::vector<std::uint32_t>* targets[4] = {&part.constraints, &part.redundant, &part.conflicting, &part.free_entities};
            const std::uint32_t which[4] = {detail::PART_CONSTRAINTS, detail::PART_REDUNDANT, detail::PART_CONFLICTING,
                                            detail::PART_FREE_ENTITIES};
            for (int k = 0; k < 4; ++k) {
                std::size_t n = 0;
                const std::uint32_t* p = ::cadaclysm_blacksmith_sketch_dof_part_list(h, i, which[k], &n);
                Result<std::vector<std::uint32_t>> list = detail::sketch_lent(p, n, "sketch_dof_part_list");
                if (!list) return list.error();
                *targets[k] = std::move(list).value();
            }
            dof.parts.push_back(std::move(part));
        }
        return dof;
    }

    // The closed loops as profiles (nested loops become holes; construction geometry left
    // out); ends within `tolerance` join.
    Result<std::vector<Profile>> profiles(double tolerance = 1e-6) const {
        CADACLYSM_SKETCH_LIVE_(h);
        return Profile::list(::cadaclysm_blacksmith_sketch_profiles(h, tolerance), "sketch_profiles");
    }
    // The chains of curves that do not close, as open profiles -- sweep paths; ends within
    // `tolerance` join.
    Result<std::vector<Profile>> open_chains(double tolerance = 1e-6) const {
        CADACLYSM_SKETCH_LIVE_(h);
        return Profile::list(::cadaclysm_blacksmith_sketch_open_chains(h, tolerance), "sketch_open_chains");
    }

private:
    explicit Sketch(CadaclysmBlacksmithSketch* raw) noexcept : handle_(raw) {}

    static Error closed_error() { return detail::refuse("sketch: closed"); }

    // An id the library handed back (NONE: its reason, no ids).
    static Result<std::uint32_t> got_id(std::uint32_t got, const char* what) {
        if (got == NONE) return detail::kernel_error(what);
        return got;
    }

    // The report a re-solving call filled in (`done` false: refused, with ids).
    static Result<SolveReport> solved(CadaclysmBlacksmithSketch* h, bool done, const double (&report)[3], const char* what) {
        if (!done) return detail::sketch_refusal(h, what);
        std::size_t n = 0;
        const std::uint32_t* p = ::cadaclysm_blacksmith_sketch_report_ids(h, &n);
        Result<std::vector<std::uint32_t>> ids = detail::sketch_lent(p, n, "sketch_report_ids");
        if (!ids) return ids.error();
        Result<std::uint32_t> status_code = detail::sketch_whole(report[0], what);
        if (!status_code) return status_code.error();
        Result<std::string> status = detail::sketch_named(detail::SKETCH_STATUSES, *status_code, what);
        if (!status) return status.error();
        Result<std::uint32_t> iterations = detail::sketch_whole(report[1], what);
        if (!iterations) return iterations.error();
        SolveReport out;
        out.status = *status;
        out.iterations = static_cast<int>(*iterations);
        out.max_residual = report[2];
        out.ids = std::move(ids).value();
        return out;
    }

    static Result<std::vector<std::uint32_t>> dof_list(CadaclysmBlacksmithSketch* h, std::uint32_t which) {
        std::size_t n = 0;
        const std::uint32_t* p = ::cadaclysm_blacksmith_sketch_dof_list(h, which, &n);
        return detail::sketch_lent(p, n, "sketch_dof_list");
    }

    // One constraint of `kind`: the geometric kinds take the fillers (value 0, driving, sense
    // "auto", end "start"), as Python's do. A refusal names the clashing constraints.
    Result<std::uint32_t> constrain(const char* kind, std::initializer_list<std::uint32_t> refs, double value = 0.0,
                                    bool driving = true, const std::string& sense = "auto",
                                    const std::string& end = "start") {
        CADACLYSM_SKETCH_LIVE_(h);
        Result<std::uint32_t> sense_code = detail::sketch_code(detail::SKETCH_SENSES, sense, kind, "sense");
        if (!sense_code) return sense_code.error();
        Result<std::uint32_t> end_code = detail::sketch_code(detail::SKETCH_ENDS, end, kind, "end");
        if (!end_code) return end_code.error();
        Result<std::uint32_t> kind_code = detail::sketch_code(detail::SKETCH_CONSTRAINT_KINDS, kind, kind, "kind");
        if (!kind_code) return kind_code.error();
        std::vector<std::uint32_t> ids(refs);
        std::uint32_t got = ::cadaclysm_blacksmith_sketch_constrain(h, *kind_code, detail::sketch_nonnull(ids), ids.size(),
                                                                    value, driving, *sense_code, *end_code);
        if (got == NONE) return detail::sketch_refusal(h, "sketch_constrain");
        return got;
    }

    CadaclysmBlacksmithSketch* handle_ = nullptr;
};

#undef CADACLYSM_SKETCH_LIVE_

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

inline Result<RTree> Solid::face_tree() const {
    return RTree::adopt(::cadaclysm_blacksmith_solid_face_tree(raw_handle("solid_face_tree")), "solid_face_tree");
}

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

    // The placement path of every solid under this assembly, at any depth: depth first,
    // placements in order, names joined by "/" with a "/" or "\" inside a name escaped with
    // "\" (as posed()'s keys are). The index swept_clash()'s rows use. Empty for an assembly
    // that places no solid.
    Result<std::vector<std::string>> parts() const {
        const CadaclysmBlacksmithAssembly* h = raw_handle("assembly_parts");
        std::uint32_t count = ::cadaclysm_blacksmith_assembly_part_count(h);
        std::vector<std::string> out;
        out.reserve(count);
        for (std::uint32_t i = 0; i < count; ++i) {
            char* raw = ::cadaclysm_blacksmith_assembly_part_path(h, i);
            if (!raw) return detail::kernel_error("assembly_part_path");
            out.emplace_back(raw);
            ::cadaclysm_blacksmith_string_free(raw);
        }
        return out;
    }

    // Every pair of this assembly's solids (indexed as parts() lists them) that penetrates,
    // touches or comes within `clearance` of the other anywhere while this assembly's own
    // mechanism moves through `keyframes`, as SweptClash rows in pair order. Each keyframe is
    // rows as posed() takes them, and every keyframe names the same joints with the same number
    // of values each (the first fixes their order); time runs in keyframe units, keyframe `k`
    // at time `k`. Between two keyframes each joint value moves linearly and each link is posed
    // from those values, so a link swinging about a joint goes round its arc, not along its
    // chord. Only this assembly's own joints move: a sub-assembly rides the link its placement
    // is in. `ground` names one of this assembly's links held fixed (nullopt: its default);
    // solids in no link stay still. Pairs on two links a joint joins are not tested unless
    // `joined`; `allowed` pairs of part indices are never tested. `tolerance` meshes the parts;
    // `resolution` and `max_steps` as Collider::swept_clash. Refused, before C is called, for
    // keyframes naming different joints, a joint given twice or a different number of values
    // for one; and with the kernel's own words (`swept_clash: ...`) for everything else.
    Result<std::vector<SweptClash>> swept_clash(const std::vector<std::vector<StateRow>>& keyframes, double clearance = 0.0,
                                                double tolerance = DEFAULT_TOLERANCE, double resolution = 1e-3,
                                                std::uint32_t max_steps = 100000,
                                                const std::vector<std::pair<std::uint32_t, std::uint32_t>>& allowed = {},
                                                std::optional<std::string_view> ground = std::nullopt, bool joined = false) const {
        static const std::vector<StateRow> none;
        const std::vector<StateRow>& first = keyframes.empty() ? none : keyframes[0];
        std::vector<const char*> joint_pointers;
        joint_pointers.reserve(first.size());
        std::vector<std::uint32_t> counts;
        counts.reserve(first.size());
        std::vector<double> flat;
        for (const StateRow& row : first) {
            joint_pointers.push_back(row.joint.c_str());
            counts.push_back(static_cast<std::uint32_t>(row.values.size()));
            flat.insert(flat.end(), row.values.begin(), row.values.end());
        }
        // C takes one joint set for every keyframe: a later keyframe naming other joints is
        // refused here, in the kernel's words, before C is called
        for (std::size_t k = 1; k < keyframes.size(); ++k) {
            const std::vector<StateRow>& frame = keyframes[k];
            std::string at = std::to_string(k);
            for (const StateRow& j : first) {
                bool named = false;
                for (const StateRow& r : frame) named = named || r.joint == j.joint;
                if (!named) return detail::refuse("swept_clash: joint '" + j.joint + "' is in keyframe 0 and not in keyframe " + at);
            }
            for (const StateRow& j : frame) {
                bool known = false;
                for (const StateRow& r : first) known = known || r.joint == j.joint;
                if (!known) return detail::refuse("swept_clash: joint '" + j.joint + "' is in keyframe " + at + " and not in keyframe 0");
            }
            for (std::size_t i = 0; i < frame.size(); ++i) {
                for (std::size_t e = 0; e < i; ++e) {
                    if (frame[e].joint == frame[i].joint) return detail::refuse("swept_clash: joint '" + frame[i].joint + "' is given twice");
                }
            }
            for (const StateRow& j : first) {
                for (const StateRow& r : frame) {
                    if (r.joint != j.joint) continue;
                    if (r.values.size() != j.values.size()) {
                        return detail::refuse("swept_clash: joint '" + j.joint + "' has " + std::to_string(j.values.size()) +
                                              " values in keyframe 0 and " + std::to_string(r.values.size()) + " in keyframe " + at);
                    }
                    flat.insert(flat.end(), r.values.begin(), r.values.end());
                }
            }
        }
        std::vector<std::uint32_t> allowed_flat;
        allowed_flat.reserve(allowed.size() * 2);
        for (const std::pair<std::uint32_t, std::uint32_t>& pair : allowed) {
            allowed_flat.push_back(pair.first);
            allowed_flat.push_back(pair.second);
        }
        std::optional<std::string> owned_ground = ground ? std::optional<std::string>(*ground) : std::nullopt;
        CadaclysmBlacksmithSweptClashes* h = ::cadaclysm_blacksmith_assembly_swept_clash(
            raw_handle("assembly_swept_clash"), joint_pointers.empty() ? nullptr : joint_pointers.data(),
            counts.empty() ? nullptr : counts.data(), first.size(), flat.empty() ? nullptr : flat.data(),
            static_cast<std::uint32_t>(keyframes.size()), owned_ground ? owned_ground->c_str() : nullptr, tolerance, clearance,
            resolution, max_steps, allowed_flat.empty() ? nullptr : allowed_flat.data(), static_cast<std::uint32_t>(allowed.size()),
            joined);
        return detail::swept_clashes_of(h, "assembly_swept_clash");
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

// Values hash as they compare: by kind and numbers.
namespace std {
template <>
struct hash<cadaclysm::blacksmith::Interval> {
    std::size_t operator()(const cadaclysm::blacksmith::Interval& v) const noexcept { return v.hash(); }
};
template <>
struct hash<cadaclysm::blacksmith::Line> {
    std::size_t operator()(const cadaclysm::blacksmith::Line& v) const noexcept { return v.hash(); }
};
template <>
struct hash<cadaclysm::blacksmith::Circle> {
    std::size_t operator()(const cadaclysm::blacksmith::Circle& v) const noexcept { return v.hash(); }
};
template <>
struct hash<cadaclysm::blacksmith::Arc> {
    std::size_t operator()(const cadaclysm::blacksmith::Arc& v) const noexcept { return v.hash(); }
};
template <>
struct hash<cadaclysm::blacksmith::Ellipse> {
    std::size_t operator()(const cadaclysm::blacksmith::Ellipse& v) const noexcept { return v.hash(); }
};
template <>
struct hash<cadaclysm::blacksmith::Sphere> {
    std::size_t operator()(const cadaclysm::blacksmith::Sphere& v) const noexcept { return v.hash(); }
};
template <>
struct hash<cadaclysm::blacksmith::Cylinder> {
    std::size_t operator()(const cadaclysm::blacksmith::Cylinder& v) const noexcept { return v.hash(); }
};
template <>
struct hash<cadaclysm::blacksmith::Cone> {
    std::size_t operator()(const cadaclysm::blacksmith::Cone& v) const noexcept { return v.hash(); }
};
template <>
struct hash<cadaclysm::blacksmith::Torus> {
    std::size_t operator()(const cadaclysm::blacksmith::Torus& v) const noexcept { return v.hash(); }
};
template <>
struct hash<cadaclysm::blacksmith::Cuboid> {
    std::size_t operator()(const cadaclysm::blacksmith::Cuboid& v) const noexcept { return v.hash(); }
};
}  // namespace std

#endif  // CADACLYSM_BLACKSMITH_HPP
