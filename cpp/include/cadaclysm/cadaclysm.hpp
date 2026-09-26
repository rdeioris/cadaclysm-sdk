// cadaclysm.hpp -- the reader's C ABI (cadaclysm.h) as C++17, on the object model
// cadaclysm.py has: Scene, Node, Placement and the values they hand back. Every call
// that can fail returns a Result; nothing throws. Strings are copies; arrays borrow
// from their Scene and die with it (README.md, "Lifetimes").
//
// FemMesh is the one borrowed view whose owner is not the Scene: it is a handle of your
// own (Node::fem_mesh), and its spans belong to that handle, so closing the scene neither
// frees nor stales one, and only FemMesh::free() -- or its destructor -- does.
#ifndef CADACLYSM_HPP
#define CADACLYSM_HPP

#include <cadaclysm.h>

#include "result.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <system_error>
#include <utility>
#include <variant>
#include <vector>

namespace cadaclysm {
inline namespace CADACLYSM_ABI {

// ---- constants and enums ----------------------------------------------------------

// Returned where a part has no parent, and by any lookup that found nothing.
inline constexpr std::uint32_t NONE = CADACLYSM_NONE;
// OR into a convention: keep the preset's axes but the file's own units.
inline constexpr std::uint32_t FILE_UNITS = 0x100;
// OR into a convention: ask for Mesh::uvs, one world unit per unit of u.
inline constexpr std::uint32_t UV_WORLD = 0x200;

using Vec3 = std::array<double, 3>;
// A 4x4 matrix as rows: m[row][column].
using Matrix4 = std::array<std::array<double, 4>, 4>;

// The coordinate space to open a file into (CadaclysmConvention).
enum class Convention : std::uint32_t { native = 0, unreal = 1, unity = 2, y_up = 3, blender = 4 };

constexpr std::uint32_t operator|(Convention convention, std::uint32_t flags) noexcept {
    return static_cast<std::uint32_t>(convention) | flags;
}

// Which field of an attribute holds its value; one-based, none meaning "not there".
enum class ValueKind : std::uint32_t { none = 0, text = 1, integer = 2, real = 3, boolean = 4, list = 5, reference = 6 };

class Node;
class Placement;
class Link;
class Joint;
class Scene;

namespace detail {

inline std::string text(const char* raw) { return raw ? std::string(raw) : std::string(); }

// The library's reason for the last failure on this thread, or `fallback`.
inline Error reader_error(const char* fallback) {
    std::string message = text(::cadaclysm_last_error());
    if (message.empty()) message = fallback;
    return Error{std::move(message), Origin::reader};
}

// "<name>: <the library's reason>", as open() and query() word it.
inline Error named_error(const std::string& name) {
    return Error{name + ": " + text(::cadaclysm_last_error()), Origin::reader};
}

inline std::string file_name(const std::string& path) {
    std::size_t cut = path.find_last_of("/\\");
    return cut == std::string::npos ? path : path.substr(cut + 1);
}

// The library takes and gives UTF-8 paths on every platform.
inline std::filesystem::path fs_path(const std::string& utf8_text) {
#if defined(__cpp_char8_t)
    return std::filesystem::path(
        std::u8string(reinterpret_cast<const char8_t*>(utf8_text.data()), utf8_text.size()));
#else
    return std::filesystem::u8path(utf8_text);
#endif
}

inline std::string utf8(const std::filesystem::path& path) {
#if defined(__cpp_char8_t)
    std::u8string s = path.u8string();
    return std::string(s.begin(), s.end());
#else
    return path.u8string();
#endif
}

// A double as Rust's Display writes it (the library's own rendering, and what
// cadaclysm.py's Attribute.text reproduces): the fewest digits that read back
// exactly, never an exponent.
inline std::string real_text(double value) {
    if (std::isnan(value)) return "NaN";
    if (std::isinf(value)) return value < 0 ? "-inf" : "inf";
    if (value == 0.0) return std::signbit(value) ? "-0" : "0";
    char buffer[64];
    for (int precision = 0; precision <= 16; ++precision) {
        std::snprintf(buffer, sizeof buffer, "%.*e", precision, value);
        if (std::strtod(buffer, nullptr) == value) break;
    }
    const char* p = buffer;
    bool negative = *p == '-';
    if (negative) ++p;
    std::string digits;
    for (; *p && *p != 'e' && *p != 'E'; ++p) {
        if (std::isdigit(static_cast<unsigned char>(*p))) digits += *p;
    }
    int exponent = *p ? std::atoi(p + 1) : 0;
    while (digits.size() > 1 && digits.back() == '0') digits.pop_back();
    int point = exponent + 1;  // how many digits stand before the decimal point
    std::string out;
    if (point <= 0) {
        out = "0." + std::string(static_cast<std::size_t>(-point), '0') + digits;
    } else if (static_cast<std::size_t>(point) >= digits.size()) {
        out = digits + std::string(static_cast<std::size_t>(point) - digits.size(), '0');
    } else {
        out = digits.substr(0, static_cast<std::size_t>(point)) + "." + digits.substr(static_cast<std::size_t>(point));
    }
    return negative ? "-" + out : out;
}

// What a Scene owns; its borrowers reach it through Ref. Closing bumps the
// generation, so a borrower made before a close can tell.
struct SceneState {
    CadaclysmScene* handle = nullptr;
    std::uint64_t generation = 0;
    std::string path;
    std::optional<std::string> schema_path;
    std::uint32_t convention = 0;

    bool live() const noexcept { return handle != nullptr; }
    void close() noexcept {
        if (handle) {
            ::cadaclysm_close(handle);
            handle = nullptr;
            ++generation;
        }
    }
    SceneState() = default;
    SceneState(const SceneState&) = delete;
    SceneState& operator=(const SceneState&) = delete;
    ~SceneState() { close(); }
};

// A borrower's way back to its owner's state. Checked: a weak reference plus the
// generation it was made at, verified on every read. Unchecked: a bare pointer.
template <class State>
class Ref {
public:
    Ref() = default;
#if CADACLYSM_CHECKED
    explicit Ref(const std::shared_ptr<State>& state) noexcept : weak_(state), generation_(state->generation) {}
#else
    explicit Ref(const std::shared_ptr<State>& state) noexcept : state_(state.get()) {}
#endif

    // The owner's state, or a bad access naming `what`. The shared_ptr is gone before
    // any report, so a longjmp hook skips no destructor.
    State& get(const char* what) const {
#if CADACLYSM_CHECKED
        State* state = nullptr;
        {
            std::shared_ptr<State> held = weak_.lock();
            state = held.get();
        }
        if (!state) bad_access(what, "its owner has been destroyed");
        if (!state->live()) bad_access(what, "its owner has been closed");
        if (state->generation != generation_) {
            bad_access(what, "stale view: the memory it read has been replaced since (meshed again at another tolerance)");
        }
        return *state;
#else
        (void)what;
        return *state_;
#endif
    }

    // Which owner this borrows from, for equality.
    const void* identity() const noexcept {
#if CADACLYSM_CHECKED
        std::shared_ptr<State> held = weak_.lock();
        return held.get();
#else
        return state_;
#endif
    }

private:
#if CADACLYSM_CHECKED
    std::weak_ptr<State> weak_;
    std::uint64_t generation_ = 0;
#else
    State* state_ = nullptr;
#endif
};

// Lets cadaclysm_blacksmith.hpp read what a Node knows of its scene.
struct Access;

}  // namespace detail

// ---- the library ------------------------------------------------------------------

// The version of the library actually loaded.
inline std::string version() { return detail::text(::cadaclysm_version()); }

// When the loaded library was built, YYYY-MM-DD.
inline std::string build_date() { return detail::text(::cadaclysm_build_date()); }

// Load a license: the certificate text, or the path of a file holding it.
inline Result<void> license(const std::string& text_or_path) {
    if (!::cadaclysm_license_set(text_or_path.c_str())) return detail::reader_error("license refused");
    return {};
}

// One line about the license in use; never empty ("unlicensed" without one).
inline std::string license_info() { return detail::text(::cadaclysm_license_info()); }

// How many unlicensed notices this library has printed to stderr in this process.
inline std::uint64_t license_notice_count() { return ::cadaclysm_license_notice_count(); }

// How many coarser levels Node::mesh_lod offers above the mesh itself (level 0).
inline std::uint32_t lod_levels() { return ::cadaclysm_lod_levels(); }

// A format Node::save_mesh writes, the extension it writes it with (not derivable:
// "stl-ascii" writes a .stl), and a label for a save menu ("STL (binary)").
struct MeshFormat {
    std::string name;
    std::string extension;
    std::string label;
};

inline std::vector<MeshFormat> mesh_formats() {
    std::uint32_t count = ::cadaclysm_mesh_format_count();
    std::vector<MeshFormat> out;
    out.reserve(count);
    for (std::uint32_t i = 0; i < count; ++i) {
        out.push_back({detail::text(::cadaclysm_mesh_format(i)), detail::text(::cadaclysm_mesh_format_extension(i)),
                       detail::text(::cadaclysm_mesh_format_label(i))});
    }
    return out;
}

// A format this build reads, and the extensions its files take -- what an open
// dialog's filter is built from. The library hands the extensions over
// semicolon-separated; they are split here.
struct Format {
    std::string name;
    std::vector<std::string> extensions;
};

inline std::vector<Format> formats() {
    std::uint32_t count = ::cadaclysm_format_count();
    std::vector<Format> out;
    out.reserve(count);
    for (std::uint32_t i = 0; i < count; ++i) {
        Format f{detail::text(::cadaclysm_format_name(i)), {}};
        std::string joined = detail::text(::cadaclysm_format_extensions(i));
        std::size_t start = 0;
        while (start <= joined.size()) {
            std::size_t end = joined.find(';', start);
            if (end == std::string::npos) end = joined.size();
            if (end > start) f.extensions.push_back(joined.substr(start, end - start));
            start = end + 1;
        }
        out.push_back(std::move(f));
    }
    return out;
}

// Ask the user for a file through the library's own dialog. Nothing if they
// cancelled or no dialog was available. Blocks; on macOS call it from the main thread.
inline std::optional<std::string> pick_file() {
    const char* raw = ::cadaclysm_pick_file(nullptr);
    if (!raw) return std::nullopt;
    return std::string(raw);  // borrowed only until the next picker call: copied now
}

// Ask the user where to save, through the library's own dialog, with the suggested
// name prefilled. Nothing if they cancelled or no dialog was available. Blocks; on
// macOS call it from the main thread.
inline std::optional<std::string> pick_save(std::optional<std::string_view> suggested_name = std::nullopt) {
    std::string name;
    if (suggested_name) name.assign(suggested_name->data(), suggested_name->size());
    const char* raw = ::cadaclysm_pick_save(nullptr, suggested_name ? name.c_str() : nullptr);
    if (!raw) return std::nullopt;
    return std::string(raw);  // borrowed only until the next picker call: copied now
}

// A packed convention from a name a user typed: "unreal", or "unreal+file-units".
inline Result<std::uint32_t> parse_convention(std::string_view text) {
    std::string lowered;
    for (char c : text) lowered += static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    const char* space = " \t\r\n\f\v";
    std::size_t first = lowered.find_first_not_of(space);
    lowered = first == std::string::npos ? std::string()
                                         : lowered.substr(first, lowered.find_last_not_of(space) - first + 1);
    std::size_t plus = lowered.find('+');
    std::string preset = lowered.substr(0, plus);
    std::string rest = plus == std::string::npos ? std::string() : lowered.substr(plus + 1);
    std::uint32_t packed = 0;
    if (preset == "native") packed = 0;
    else if (preset == "unreal") packed = 1;
    else if (preset == "unity") packed = 2;
    else if (preset == "y-up") packed = 3;
    else if (preset == "blender") packed = 4;
    else return Error{"no convention called '" + preset + "': native, unreal, unity, y-up or blender"};
    std::size_t start = 0;
    while (start <= rest.size()) {
        std::size_t end = rest.find('+', start);
        if (end == std::string::npos) end = rest.size();
        std::string flag = rest.substr(start, end - start);
        if (!flag.empty()) {
            if (flag != "file-units") return Error{"no convention flag called '" + flag + "': file-units"};
            packed |= FILE_UNITS;
        }
        start = end + 1;
    }
    return packed;
}

// ---- values -----------------------------------------------------------------------

// An axis-aligned box, or all zeros where there was nothing to bound.
struct Bounds {
    std::array<float, 3> min{};
    std::array<float, 3> max{};

    // Whether this is the all-zero box the ABI uses for "nothing here".
    bool is_empty() const noexcept {
        return min == std::array<float, 3>{} && max == std::array<float, 3>{};
    }
    std::array<float, 3> size() const noexcept { return {max[0] - min[0], max[1] - min[1], max[2] - min[2]}; }
    std::array<float, 3> centre() const noexcept {
        return {(min[0] + max[0]) / 2, (min[1] + max[1]) / 2, (min[2] + max[2]) / 2};
    }
    bool operator==(const Bounds& other) const noexcept { return min == other.min && max == other.max; }
    bool operator!=(const Bounds& other) const noexcept { return !(*this == other); }
};

// Bounds in `double`: the same box, unnarrowed. All zeros where there was nothing to
// bound.
struct Bounds64 {
    std::array<double, 3> min{};
    std::array<double, 3> max{};

    bool is_empty() const noexcept {
        return min == std::array<double, 3>{} && max == std::array<double, 3>{};
    }
    std::array<double, 3> size() const noexcept { return {max[0] - min[0], max[1] - min[1], max[2] - min[2]}; }
    std::array<double, 3> centre() const noexcept {
        return {(min[0] + max[0]) / 2, (min[1] + max[1]) / 2, (min[2] + max[2]) / 2};
    }
    bool operator==(const Bounds64& other) const noexcept { return min == other.min && max == other.max; }
    bool operator!=(const Bounds64& other) const noexcept { return !(*this == other); }
};

// One thing the file said about a node. `value` holds the alternative `kind` names:
// a string for text, list and reference; int64 for integer; double for real; bool
// for boolean; monostate for none.
struct Attribute {
    std::string name;
    ValueKind kind = ValueKind::none;
    std::variant<std::monostate, std::string, std::int64_t, double, bool> value;

    // The value rendered for display, as the library's own Rust Display does.
    std::string text() const {
        if (const auto* s = std::get_if<std::string>(&value)) return *s;
        if (const auto* i = std::get_if<std::int64_t>(&value)) return std::to_string(*i);
        if (const auto* d = std::get_if<double>(&value)) return detail::real_text(*d);
        if (const auto* b = std::get_if<bool>(&value)) return *b ? "true" : "false";
        return "";
    }
};

// How open() and open_memory() read a file. `convention` is a Convention, optionally
// OR'd with FILE_UNITS and UV_WORLD. `schema` names an EXPRESS schema (.exp file or a
// directory of them) beyond the built-in ones. `name` is what open_memory calls the
// scene (Scene::path).
struct OpenOptions {
    std::optional<std::string> schema;
    std::uint32_t convention = 0;
    bool colors = false;
    double source_metres_per_unit = 0.0;
    std::string name = "<memory>";
};

inline Result<Scene> open(const std::string& path, const OpenOptions& options = OpenOptions());
inline Result<Scene> open_memory(const void* data, std::size_t size, const std::string& format,
                                 const OpenOptions& options = OpenOptions());

// ---- borrowed views -----------------------------------------------------------------

// Triangles in memory of our own: what Mesh::copy() returns, safe to outlive anything.
struct MeshData {
    std::vector<float> positions;  // 3 a vertex
    std::vector<float> normals;    // 3 a vertex, or empty
    std::vector<float> uvs;        // 2 a vertex, or empty
    std::vector<float> colors;     // 4 a vertex (RGBA 0..1), or empty
    std::vector<std::uint32_t> indices;

    std::size_t vertex_count() const noexcept { return positions.size() / 3; }
    std::size_t triangle_count() const noexcept { return indices.size() / 3; }
};

// A node's triangles, in its own frame, borrowed from the scene: valid until the
// scene closes. copy() for arrays that must outlive it.
class Mesh {
public:
    Span<const float> positions() const { return floats(raw().positions, 3); }
    Span<const float> normals() const { return floats(raw().normals, 3); }
    // Only with UV_WORLD in the convention, and only where the reader made some.
    Span<const float> uvs() const { return floats(raw().uvs, 2); }
    // Only with OpenOptions::colors, on a body painted in more than one colour.
    Span<const float> colors() const { return floats(raw().colors, 4); }
    Span<const std::uint32_t> indices() const {
        const CadaclysmMesh& r = raw();
        return r.indices ? Span<const std::uint32_t>(r.indices, r.index_count) : Span<const std::uint32_t>();
    }
    std::uint32_t vertex_count() const { return raw().vertex_count; }
    std::uint32_t index_count() const { return raw().index_count; }
    std::uint32_t triangle_count() const { return raw().index_count / 3; }
    bool empty() const { return raw().index_count == 0; }

    MeshData copy() const {
        MeshData out;
        auto take = [](std::vector<float>& to, Span<const float> from) { to.assign(from.begin(), from.end()); };
        take(out.positions, positions());
        take(out.normals, normals());
        take(out.uvs, uvs());
        take(out.colors, colors());
        Span<const std::uint32_t> i = indices();
        out.indices.assign(i.begin(), i.end());
        return out;
    }

private:
    friend class Node;
    Mesh(detail::Ref<detail::SceneState> scene, const CadaclysmMesh& data) : scene_(std::move(scene)), raw_(data) {}
    const CadaclysmMesh& raw() const {
        scene_.get("Mesh");
        return raw_;
    }
    Span<const float> floats(const float* p, std::size_t per_vertex) const {
        return p ? Span<const float>(p, static_cast<std::size_t>(raw_.vertex_count) * per_vertex) : Span<const float>();
    }

    detail::Ref<detail::SceneState> scene_;
    CadaclysmMesh raw_;
};

// Triangles in `double`, in memory of our own: what Mesh64::copy() returns, safe to
// outlive anything. Colours stay `float` (RGBA in 0..1 needs no more).
struct MeshData64 {
    std::vector<double> positions;  // 3 a vertex
    std::vector<double> normals;    // 3 a vertex, or empty
    std::vector<double> uvs;        // 2 a vertex, or empty
    std::vector<float> colors;      // 4 a vertex (RGBA 0..1), or empty
    std::vector<std::uint32_t> indices;

    std::size_t vertex_count() const noexcept { return positions.size() / 3; }
    std::size_t triangle_count() const noexcept { return indices.size() / 3; }
};

// Mesh in `double`: the node's own mesh, **lent as it is** rather than narrowed the
// way Mesh is -- the same triangles and indices, Mesh's `float` positions being
// exactly these narrowed. For a caller that uses the mesh as geometry (an exporter, a
// measurement, a solver) and wants the file's own coordinates, which `float` cannot
// hold far from the origin. Colours stay `float`.
//
// **A forget drops it.** Scene::forget_meshes frees the document's own mesh these
// pointers borrow: read none of them after a forget; ask again and the mesh is built
// again. Mesh's pointers survive a forget, its `float` copy being kept separately.
// raw() checks the scene is still open, the same check Mesh makes, but a forget is not
// a close and is not tracked: reading a Mesh64 after a forget (without an intervening
// close) is undefined behaviour, exactly as the C ABI documents.
class Mesh64 {
public:
    Span<const double> positions() const { return doubles(raw().positions, 3); }
    Span<const double> normals() const { return doubles(raw().normals, 3); }
    Span<const double> uvs() const { return doubles(raw().uvs, 2); }
    // Four floats a vertex, RGBA -- still `float`: CadaclysmMesh64::colors says RGBA
    // in 0..1 needs no more precision.
    Span<const float> colors() const {
        const CadaclysmMesh64& r = raw();
        return r.colors ? Span<const float>(r.colors, static_cast<std::size_t>(r.vertex_count) * 4) : Span<const float>();
    }
    Span<const std::uint32_t> indices() const {
        const CadaclysmMesh64& r = raw();
        return r.indices ? Span<const std::uint32_t>(r.indices, r.index_count) : Span<const std::uint32_t>();
    }
    std::uint32_t vertex_count() const { return raw().vertex_count; }
    std::uint32_t index_count() const { return raw().index_count; }
    std::uint32_t triangle_count() const { return raw().index_count / 3; }
    bool empty() const { return raw().index_count == 0; }

    MeshData64 copy() const {
        MeshData64 out;
        auto take_d = [](std::vector<double>& to, Span<const double> from) { to.assign(from.begin(), from.end()); };
        take_d(out.positions, positions());
        take_d(out.normals, normals());
        take_d(out.uvs, uvs());
        Span<const float> c = colors();
        out.colors.assign(c.begin(), c.end());
        Span<const std::uint32_t> i = indices();
        out.indices.assign(i.begin(), i.end());
        return out;
    }

private:
    friend class Node;
    Mesh64(detail::Ref<detail::SceneState> scene, const CadaclysmMesh64& data) : scene_(std::move(scene)), raw_(data) {}
    const CadaclysmMesh64& raw() const {
        scene_.get("Mesh64");
        return raw_;
    }
    Span<const double> doubles(const double* p, std::size_t per_vertex) const {
        return p ? Span<const double>(p, static_cast<std::size_t>(raw_.vertex_count) * per_vertex) : Span<const double>();
    }

    detail::Ref<detail::SceneState> scene_;
    CadaclysmMesh64 raw_;
};

// A node's feature edges or free curves as runs of points, borrowed from the scene.
class Polylines {
public:
    Span<const float> positions() const {  // 3 a point
        const CadaclysmPolylines& r = raw();
        return r.positions ? Span<const float>(r.positions, static_cast<std::size_t>(r.vertex_count) * 3)
                           : Span<const float>();
    }
    Span<const std::uint32_t> counts() const {  // points in each run
        const CadaclysmPolylines& r = raw();
        return r.counts ? Span<const std::uint32_t>(r.counts, r.polyline_count) : Span<const std::uint32_t>();
    }
    std::uint32_t polyline_count() const { return raw().polyline_count; }
    std::uint32_t vertex_count() const { return raw().vertex_count; }
    bool empty() const { return raw().polyline_count == 0; }

    // Indices into positions() making line-segment endpoint pairs: a run of n points
    // is n - 1 segments; a one-point run is a point and gives none.
    std::vector<std::uint32_t> segment_indices() const {
        std::vector<std::uint32_t> out;
        std::uint32_t start = 0;
        for (std::uint32_t n : counts()) {
            for (std::uint32_t k = 1; k < n; ++k) {
                out.push_back(start + k - 1);
                out.push_back(start + k);
            }
            start += n;
        }
        return out;
    }

    // The endpoint pairs themselves, 3 floats a point.
    std::vector<float> segments() const {
        Span<const float> p = positions();
        std::vector<float> out;
        for (std::uint32_t i : segment_indices()) out.insert(out.end(), p.begin() + 3 * i, p.begin() + 3 * i + 3);
        return out;
    }

private:
    friend class Node;
    Polylines(detail::Ref<detail::SceneState> scene, const CadaclysmPolylines& data) : scene_(std::move(scene)), raw_(data) {}
    const CadaclysmPolylines& raw() const {
        scene_.get("Polylines");
        return raw_;
    }

    detail::Ref<detail::SceneState> scene_;
    CadaclysmPolylines raw_;
};

// A Beziers in memory of your own, safe to outlive the scene: what Beziers::copy() returns.
struct BeziersData {
    std::vector<float> points;   // 3 a control point, 4 a curve
    std::vector<float> weights;  // 1 a control point, 4 a curve

    std::uint32_t count() const noexcept { return static_cast<std::uint32_t>(weights.size() / 4); }
};

// Edges, curves or isocurves as cubic Bézier curves, exact where the file's curves
// were, where Polylines are their chords: points() is four control points a curve,
// three floats each (count * 12); weights() one a control point (count * 4), all ones
// for a polynomial curve and the weights that make a circular arc exact for a rational
// one. Views into the scene, like Polylines.
class Beziers {
public:
    Span<const float> points() const {
        const CadaclysmBeziers& r = raw();
        return r.points ? Span<const float>(r.points, static_cast<std::size_t>(r.count) * 12) : Span<const float>();
    }
    Span<const float> weights() const {
        const CadaclysmBeziers& r = raw();
        return r.weights ? Span<const float>(r.weights, static_cast<std::size_t>(r.count) * 4) : Span<const float>();
    }
    std::uint32_t count() const { return raw().count; }
    bool empty() const { return raw().count == 0; }

    // The same arrays in memory of your own, safe to keep after the scene closes.
    BeziersData copy() const {
        BeziersData out;
        Span<const float> p = points();
        Span<const float> w = weights();
        out.points.assign(p.begin(), p.end());
        out.weights.assign(w.begin(), w.end());
        return out;
    }

private:
    friend class Node;
    Beziers(detail::Ref<detail::SceneState> scene, const CadaclysmBeziers& data) : scene_(std::move(scene)), raw_(data) {}
    const CadaclysmBeziers& raw() const {
        scene_.get("Beziers");
        return raw_;
    }

    detail::Ref<detail::SceneState> scene_;
    CadaclysmBeziers raw_;
};

// A Beziers64 in memory of your own, safe to outlive the scene: what Beziers64::copy()
// returns.
struct BeziersData64 {
    std::vector<double> points;   // 3 a control point, 4 a curve
    std::vector<double> weights;  // 1 a control point, 4 a curve

    std::uint32_t count() const noexcept { return static_cast<std::uint32_t>(weights.size() / 4); }
};

// Beziers in `double`: the same segments, in the same order -- Beziers' `float`
// points and weights being exactly these narrowed. Borrowed from the scene until it
// closes, like Beziers; unlike Mesh64, unaffected by a forget (the beziers are not
// part of the document's mesh cache).
class Beziers64 {
public:
    Span<const double> points() const {
        const CadaclysmBeziers64& r = raw();
        return r.points ? Span<const double>(r.points, static_cast<std::size_t>(r.count) * 12) : Span<const double>();
    }
    Span<const double> weights() const {
        const CadaclysmBeziers64& r = raw();
        return r.weights ? Span<const double>(r.weights, static_cast<std::size_t>(r.count) * 4) : Span<const double>();
    }
    std::uint32_t count() const { return raw().count; }
    bool empty() const { return raw().count == 0; }

    // The same arrays in memory of your own, safe to keep after the scene closes.
    BeziersData64 copy() const {
        BeziersData64 out;
        Span<const double> p = points();
        Span<const double> w = weights();
        out.points.assign(p.begin(), p.end());
        out.weights.assign(w.begin(), w.end());
        return out;
    }

private:
    friend class Node;
    Beziers64(detail::Ref<detail::SceneState> scene, const CadaclysmBeziers64& data) : scene_(std::move(scene)), raw_(data) {}
    const CadaclysmBeziers64& raw() const {
        scene_.get("Beziers64");
        return raw_;
    }

    detail::Ref<detail::SceneState> scene_;
    CadaclysmBeziers64 raw_;
};

// What a node turned out to be for a physics engine: a box, sphere, capsule or
// cylinder where one fits within error, else a convex hull. frame (column-major)
// and half_extent are always the true oriented box. Plain data, copied out.
struct Collision {
    std::uint32_t shape = 0;  // 0 none, 1 box, 2 sphere, 3 capsule, 4 cylinder, 5 hull
    std::uint32_t confidence = 0;
    std::uint32_t axis = 0;
    std::array<double, 16> frame{};
    std::array<double, 3> half_extent{};
    double radius = 0;
    double height = 0;
    double error = 0;
    std::uint32_t hull_vertex_count = 0;
    std::uint32_t hull_index_count = 0;

    // "none", "box", "sphere", "capsule", "cylinder" or "hull".
    std::string_view shape_name() const noexcept {
        static constexpr std::string_view names[] = {"none", "box", "sphere", "capsule", "cylinder", "hull"};
        return shape < 6 ? names[shape] : std::string_view("?");
    }
};

// A node's convex hull for a physics engine, as triangles. A view into the scene,
// like Polylines.
class CollisionHull {
public:
    Span<const float> positions() const {  // 3 a vertex
        const CadaclysmCollisionHull& r = raw();
        return r.positions ? Span<const float>(r.positions, static_cast<std::size_t>(r.vertex_count) * 3) : Span<const float>();
    }
    Span<const std::uint32_t> indices() const {  // 3 a triangle
        const CadaclysmCollisionHull& r = raw();
        return r.indices ? Span<const std::uint32_t>(r.indices, r.index_count) : Span<const std::uint32_t>();
    }
    std::uint32_t vertex_count() const { return raw().vertex_count; }
    std::uint32_t index_count() const { return raw().index_count; }
    bool empty() const { return raw().vertex_count == 0; }

private:
    friend class Node;
    CollisionHull(detail::Ref<detail::SceneState> scene, const CadaclysmCollisionHull& data) : scene_(std::move(scene)), raw_(data) {}
    const CadaclysmCollisionHull& raw() const {
        scene_.get("CollisionHull");
        return raw_;
    }

    detail::Ref<detail::SceneState> scene_;
    CadaclysmCollisionHull raw_;
};

// One trimmed face: its surface (kind, frame, domain, kind-dependent scalars) and the
// loops that cut it. The spans borrow from the scene, as Surfaces does.
struct Face {
    std::uint32_t kind = 0;  // see CadaclysmFace in cadaclysm.h
    bool reversed = false;
    bool transposed = false;
    std::array<float, 3> origin{}, ax{}, ay{}, az{};
    std::array<float, 4> domain{}, scalars{};
    std::vector<Span<const float>> loops;  // each ring: 2 floats (u, v) a point
    Span<const float> profile;             // 4 floats a row
    Span<const float> profile2;            // 4 floats a row
    Span<const float> nurbs;
};

// A part's faces as surfaces and trims, borrowed from the scene.
class Surfaces {
public:
    const std::vector<Face>& faces() const {
        scene_.get("Surfaces");
        return faces_;
    }
    std::size_t size() const { return faces().size(); }
    bool empty() const { return faces().empty(); }

private:
    friend class Node;
    Surfaces(detail::Ref<detail::SceneState> scene, std::vector<Face> built)
        : scene_(std::move(scene)), faces_(std::move(built)) {}

    detail::Ref<detail::SceneState> scene_;
    std::vector<Face> faces_;
};

// Whether a B-rep's faces make a manifold, and whether it is closed.
struct Manifold {
    std::uint32_t faces = 0;
    std::uint32_t edges = 0;
    std::uint32_t vertices = 0;
    std::uint32_t boundary_edges = 0;
    std::uint32_t non_manifold_edges = 0;
    std::uint32_t non_manifold_vertices = 0;
    bool is_manifold = false;
    bool is_closed = false;
};

namespace detail {
inline Manifold manifold_of(const std::uint32_t (&row)[8]) {
    Manifold m;
    m.faces = row[0];
    m.edges = row[1];
    m.vertices = row[2];
    m.boundary_edges = row[3];
    m.non_manifold_edges = row[4];
    m.non_manifold_vertices = row[5];
    m.is_manifold = row[6] != 0;
    m.is_closed = row[7] != 0;
    return m;
}
}  // namespace detail

// A node's exact B-rep, shared with the scene (not copied), for
// blacksmith::Solid::from_node. Holds a reference of its own, so it outlives the
// scene; released when destroyed or on release().
class Brep {
public:
    Brep(Brep&&) noexcept = default;
    Brep& operator=(Brep&&) noexcept = default;

    const CadaclysmBrep* pointer() const noexcept { return ptr_.get(); }

    // Which layout this library's breps have; the kernel shares only with its own.
    static std::string layout_id() { return detail::text(::cadaclysm_brep_layout_id()); }

    Result<Manifold> manifold() const {
        if (!ptr_) return Error{"brep: released", Origin::reader};
        std::uint32_t row[8] = {};
        if (!::cadaclysm_brep_manifold(ptr_.get(), row)) return detail::reader_error("manifold");
        return detail::manifold_of(row);
    }

    void release() noexcept { ptr_.reset(); }

private:
    friend class Node;
    struct Release {
        void operator()(const CadaclysmBrep* brep) const noexcept { ::cadaclysm_brep_release(brep); }
    };
    explicit Brep(const CadaclysmBrep* brep) : ptr_(brep) {}

    std::unique_ptr<const CadaclysmBrep, Release> ptr_;
};

// One meshlet, copied out: the vectors are yours.
struct Meshlet {
    std::uint32_t index = 0;
    std::uint32_t level = 0;   // 0 for a leaf over the mesh itself, higher for a simplified level above it
    std::uint32_t group = 0;
    float error = 0;           // how far this meshlet's level moved the surface; zero at level 0
    std::vector<float> positions;         // 3 a vertex
    std::vector<float> normals;           // 3 a vertex; zeros where the mesh had none
    std::vector<std::uint32_t> indices;   // 3 a triangle, into this meshlet's own vertices
    std::vector<std::uint32_t> children;  // the finer meshlets below this one, for a levelled build

    std::uint32_t vertex_count() const noexcept { return static_cast<std::uint32_t>(positions.size() / 3); }
    std::uint32_t triangle_count() const noexcept { return static_cast<std::uint32_t>(indices.size() / 3); }
};

// A mesh split into meshlets, optionally with coarser levels above them, for a
// mesh-shader or meshlet-based renderer. Built from any mesh -- a Node's or arrays of
// your own -- and owned by you: freed when destroyed, or on free().
class Meshlets {
public:
    Meshlets(Meshlets&&) noexcept = default;
    Meshlets& operator=(Meshlets&&) noexcept = default;

    // Split positions (3 floats a vertex), normals (the same, or an empty span for
    // none) and indices (3 a triangle) into meshlets of at most max_triangles and
    // max_vertices each -- the consumer's own limits, with no default: Nanite takes
    // 128/256, a mesh-shader pipeline 124/64. levels above 0 groups and simplifies
    // each level into the next until one meshlet is left.
    static Result<Meshlets> build(Span<const float> positions, Span<const float> normals, Span<const std::uint32_t> indices,
                                  std::uint32_t max_triangles, std::uint32_t max_vertices, std::int32_t levels = 0) {
        if (max_triangles == 0 || max_vertices == 0) return Error{"meshlets: max_triangles and max_vertices are required", Origin::reader};
        if (positions.size() % 3 != 0 || indices.size() % 3 != 0) {
            return Error{"meshlets: positions must hold three floats a vertex and indices three a triangle", Origin::reader};
        }
        if (!normals.empty() && normals.size() != positions.size()) {
            return Error{"meshlets: normals must hold one per vertex, three floats each", Origin::reader};
        }
        CadaclysmMeshlets* handle = ::cadaclysm_meshlets_build(positions.data(), normals.empty() ? nullptr : normals.data(), positions.size() / 3,
                                                               indices.data(), indices.size(), max_triangles, max_vertices, levels);
        if (!handle) return detail::reader_error("meshlets: build failed");
        return Meshlets(handle);
    }

    bool freed() const noexcept { return !ptr_; }
    // Give the meshlets back now. Idempotent.
    void free() noexcept { ptr_.reset(); }

    // How many meshlets, every level counted.
    std::uint32_t count() const { return ::cadaclysm_meshlets_count(live()); }
    std::uint32_t triangle_count(std::uint32_t i) const { return ::cadaclysm_meshlet_triangle_count(live(), i); }
    std::uint32_t vertex_count(std::uint32_t i) const { return ::cadaclysm_meshlet_vertex_count(live(), i); }
    std::uint32_t level(std::uint32_t i) const { return ::cadaclysm_meshlet_level(live(), i); }
    std::uint32_t group(std::uint32_t i) const { return ::cadaclysm_meshlet_group(live(), i); }
    float error(std::uint32_t i) const { return ::cadaclysm_meshlet_error(live(), i); }
    std::uint32_t child_count(std::uint32_t i) const { return ::cadaclysm_meshlet_child_count(live(), i); }

    // One meshlet's arrays and numbers, copied out.
    Meshlet meshlet(std::uint32_t i) const {
        const CadaclysmMeshlets* h = live();
        Meshlet out;
        out.index = i;
        out.level = ::cadaclysm_meshlet_level(h, i);
        out.group = ::cadaclysm_meshlet_group(h, i);
        out.error = ::cadaclysm_meshlet_error(h, i);
        std::uint32_t vertices = ::cadaclysm_meshlet_vertex_count(h, i);
        std::uint32_t triangles = ::cadaclysm_meshlet_triangle_count(h, i);
        std::uint32_t kids = ::cadaclysm_meshlet_child_count(h, i);
        out.positions.assign(static_cast<std::size_t>(vertices) * 3, 0.0f);
        out.normals.assign(static_cast<std::size_t>(vertices) * 3, 0.0f);
        out.indices.assign(static_cast<std::size_t>(triangles) * 3, 0u);
        out.children.assign(kids, 0u);
        if (vertices) {
            ::cadaclysm_meshlet_positions(h, i, out.positions.data());
            ::cadaclysm_meshlet_normals(h, i, out.normals.data());
        }
        if (triangles) ::cadaclysm_meshlet_indices(h, i, out.indices.data());
        if (kids) ::cadaclysm_meshlet_children(h, i, out.children.data());
        return out;
    }

private:
    struct Free {
        void operator()(CadaclysmMeshlets* handle) const noexcept { ::cadaclysm_meshlets_free(handle); }
    };
    explicit Meshlets(CadaclysmMeshlets* handle) : ptr_(handle) {}
    // Traps on a freed handle the way the other views trap on a closed scene: a
    // read after free() is a bug in the caller, not a recoverable state.
    const CadaclysmMeshlets* live() const {
        if (!ptr_) detail::bad_access("Meshlets", "freed");
        return ptr_.get();
    }

    std::unique_ptr<CadaclysmMeshlets, Free> ptr_;
};

// ---- the FEM surface mesh -------------------------------------------------------------

// One B-rep edge of a FEM mesh: the chain of nodes along it, and where that chain breaks.
//
// The two arrays are spans into the FemMesh's own memory, as Face's are into the scene's,
// and they die with it: FemMesh::edges() checks the handle before it hands the list over,
// and a span already in hand is a pointer and a length from then on. Copy anything that
// must outlive the mesh.
struct FemEdge {
    // The **body's own** B-rep edge id -- `LoopTrim::edge` on the brep Node::brep hands
    // over, the number the file gave the edge.
    //
    // **Not this mesh's edge index, and on a read body rarely equal to it.**
    // FemMesh::edges() is a densely renumbered *subset* of the body's edges -- ascending
    // by id, with every edge collapsed to a point left out -- so edge 0 of a STEP body's
    // mesh routinely reports an id in the hundreds. Everything else here that names an
    // edge means the *index*: a FemMesh::node_kind() of 1 read through
    // FemMesh::node_entity(), the third number of an open or folded census row, and the
    // `edge_<i>` physical group of FemMesh::msh_text(). This is the one way back from any
    // of them to the topology the file wrote.
    std::uint32_t id = 0;
    // This mesh's node indices in order along the edge, its end vertices included; a
    // closed edge repeats no node.
    Span<const std::uint32_t> nodes;
    // Where each connected run of `nodes` begins; `[0]` for one chain along the whole
    // edge. **Read nodes[runs[i] .. runs[i + 1]] (the last run to the end) as one
    // polyline and join nothing across a boundary** -- chains() does that walk. The two
    // ends either side of one are two points of the edge with no mesh edge between them:
    // a crack along the edge, or a stretch of it the mesher sampled on one face only.
    Span<const std::uint32_t> runs;
    // The two faces it bounds, the second NONE on an open body's rim. **`0` is a real
    // face, not a sentinel.** A non-manifold edge's third and further faces are not here;
    // Brep::manifold() is where the whole list of them is read.
    std::pair<std::uint32_t, std::uint32_t> faces{NONE, NONE};
    // The two B-rep vertices its chain ends at, as FemMesh::vertices() indexes them, the
    // second NONE where both ends are one vertex -- a closed edge, a circle's rim, a
    // full-turn seam. **`0` is a real vertex, not a sentinel.** Which end comes first is
    // the first trim's direction and means nothing else: the pair bounds the edge, it
    // does not orient it.
    std::pair<std::uint32_t, std::uint32_t> ends{NONE, NONE};
    // The nodes make one loop. False wherever `runs` is longer than one.
    bool closed = false;
    // Bounded twice by one face: a closed surface's seam rather than a real boundary.
    // Both `faces` are then that same face.
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
    // The mesh node at this vertex, or NONE where the mesh has none there.
    //
    // **A sentinel here is ordinary, not a fault.** The analysis rebuilds a vertex
    // wherever two trims meet, and a pole's polyline runs give a sphere 48 of them where
    // the mesh has 2 points; a caller walking these skips the sentinel rather than
    // treating it as a gap.
    std::uint32_t node = NONE;
    // Where the vertex is, in the same space and under the same placement as
    // FemMesh::nodes(). The file's own vertex rather than a mesh node, so the two can
    // differ by the reader's rounding. **Meaningless unless has_position**: it is zeroed
    // then, a point no geometry has and one a solver would take for a node at the origin.
    Vec3 point{};
    // `point` was placed. False where every trim meeting at this vertex is a curve with
    // no geometry to read an end off -- then there is **no position at all**, reported as
    // this flag rather than as a plausible-looking (0, 0, 0).
    bool has_position = false;
};

namespace detail {

// One CadaclysmFemEdge as a FemEdge: the two arrays lent as spans, the pairs paired.
// Tested over rows built by hand in tests/fem_test.cpp, because no fixture in this repo
// has an edge whose chain breaks, or a closed or seam edge.
inline FemEdge fem_edge_of(const CadaclysmFemEdge& raw) {
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

// One CadaclysmFemVertex as a FemVertex: the three doubles copied, the flag carried.
inline FemVertex fem_vertex_of(const CadaclysmFemVertex& raw) {
    FemVertex out;
    out.node = raw.node;
    for (int k = 0; k < 3; ++k) out.point[k] = raw.point[k];
    out.has_position = raw.has_position;
    return out;
}

// One crack or fold census, row by row: `row(i, &a, &b, &brep_edge)` fills row i and says
// whether it could, and `fail(i)` words the refusal. The shape open_edges() and
// folded_edges() share -- on both sides of the ABI -- so the four cannot drift. Tested
// over a synthetic `row` in tests/fem_test.cpp: every fixture in this repo is either
// closed and clean, where both censuses are empty, or an open sheet, where they are not
// asked, so nothing else here reaches this arithmetic at all.
template <class Row, class Fail>
Result<std::vector<std::array<std::uint32_t, 3>>> census_rows(std::uint32_t count, Row row, Fail fail) {
    std::vector<std::array<std::uint32_t, 3>> out;
    out.reserve(count);
    for (std::uint32_t i = 0; i < count; ++i) {
        std::array<std::uint32_t, 3> at{};
        if (!row(i, &at[0], &at[1], &at[2])) return fail(i);
        out.push_back(at);
    }
    return out;
}

}  // namespace detail

// One body meshed for a solver: nodes welded by bits, triangles wound outward, every node
// tagged with the lowest-dimension B-rep entity it lies on, and every crack reported
// rather than closed. What Node::fem_mesh() returns, and **owned by you**: freed when
// destroyed, or on free(). Move-only, as Meshlets is.
//
// A handle rather than a snapshot, and its big arrays are Spans into the library's own
// memory, exactly as Mesh's are and for the same reason: a solver mesh is megabytes, and
// copying it to hand it over would cost that twice.
//
// **The owner of those spans is this object, not the scene.** That is the one thing this
// class does differently from every other view in this header: Scene::close() neither
// frees a FEM mesh nor stales one, and meshing the body again does not either -- only
// free() (or the destructor) does. There is no generation check here as the kernel's mesh
// views have: a FEM view's pointers are built with the handle and never move.
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

    // Every node's position, three doubles each -- placed, and in the space
    // Node::fem_mesh() and from_mesh() describe. Every node is used by a triangle.
    Span<const double> nodes() const {
        const CadaclysmFemMeshView& r = view("FemMesh::nodes");
        return r.nodes ? Span<const double>(r.nodes, static_cast<std::size_t>(r.node_count) * 3) : Span<const double>();
    }
    // Three node indices a triangle, wound outward -- a mirroring placement is wound back.
    Span<const std::uint32_t> triangles() const {
        const CadaclysmFemMeshView& r = view("FemMesh::triangles");
        return r.triangles ? Span<const std::uint32_t>(r.triangles, static_cast<std::size_t>(r.triangle_count) * 3)
                           : Span<const std::uint32_t>();
    }
    // The B-rep face each triangle lies on, one per triangle, into face_count() faces.
    Span<const std::uint32_t> triangle_face() const {
        const CadaclysmFemMeshView& r = view("FemMesh::triangle_face");
        return r.triangle_face ? Span<const std::uint32_t>(r.triangle_face, r.triangle_count) : Span<const std::uint32_t>();
    }
    // What each node lies on -- `0` a B-rep vertex, `1` an edge, `2` a face -- one per
    // node: the lowest-dimension entity it lies on, which is the `.msh` format's own
    // classification rule. node_entity() says which entity of that kind.
    Span<const std::uint32_t> node_kind() const {
        const CadaclysmFemMeshView& r = view("FemMesh::node_kind");
        return r.node_kind ? Span<const std::uint32_t>(r.node_kind, r.node_count) : Span<const std::uint32_t>();
    }
    // Which vertex, edge or face each node lies on, read by the matching node_kind(): an
    // index into vertices(), into edges(), or into the body's faces. One per node.
    Span<const std::uint32_t> node_entity() const {
        const CadaclysmFemMeshView& r = view("FemMesh::node_entity");
        return r.node_entity ? Span<const std::uint32_t>(r.node_entity, r.node_count) : Span<const std::uint32_t>();
    }

    // The body's faces; triangle_face() and a node_kind() of `2` index them. The same
    // faces Node::surfaces() hands over, in the same order.
    std::uint32_t face_count() const { return view("FemMesh::face_count").face_count; }

    // One FemEdge per B-rep edge, in the order a node_kind() of `1` indexes them. Empty
    // for a from_mesh() body, which has no B-rep edges at all. **This list's own
    // numbering, not the body's**: each FemEdge::id carries the body's own edge id.
    Result<std::vector<FemEdge>> edges() const {
        const CadaclysmFemMesh* handle = live("FemMesh::edges");
        std::vector<FemEdge> out;
        out.reserve(view_.edge_count);
        for (std::uint32_t i = 0; i < view_.edge_count; ++i) {
            CadaclysmFemEdge raw{};
            if (!::cadaclysm_fem_mesh_edge(handle, i, &raw)) return detail::reader_error("fem mesh edge");
            out.push_back(detail::fem_edge_of(raw));
        }
        return out;
    }

    // One FemVertex per B-rep vertex, in the order a node_kind() of `0` indexes them.
    // Empty for a from_mesh() body.
    Result<std::vector<FemVertex>> vertices() const {
        const CadaclysmFemMesh* handle = live("FemMesh::vertices");
        std::vector<FemVertex> out;
        out.reserve(view_.vertex_count);
        for (std::uint32_t i = 0; i < view_.vertex_count; ++i) {
            CadaclysmFemVertex raw{};
            if (!::cadaclysm_fem_mesh_vertex(handle, i, &raw)) return detail::reader_error("fem mesh vertex");
            out.push_back(detail::fem_vertex_of(raw));
        }
        return out;
    }

    // Every crack, as `{a, b, brep_edge}`: a directed mesh edge (a, b) with no (b, a), and
    // the B-rep edge both nodes lie on -- by FemEdge's own index, not its id -- or NONE
    // where they share none.
    //
    // **Empty unless the body's topology is closed, for a B-rep body**, whose mesh is
    // otherwise not asked about at all: such a body reports watertight() false with this
    // and folded_edges() *both* empty, and that trio together says "not asked", not
    // "nothing found".
    //
    // **A from_mesh() body is the other case, and the opposite one.** A bare mesh carries
    // no topology to say whether it ought to close, so its census always runs over the
    // welded triangles: an open render mesh reports its cracks here with watertight()
    // false, a closed one reports it true, and an empty census there really does mean
    // "nothing found".
    Result<std::vector<std::array<std::uint32_t, 3>>> open_edges() const {
        const CadaclysmFemMesh* handle = live("FemMesh::open_edges");
        return detail::census_rows(
            view_.open_edge_count,
            [handle](std::uint32_t i, std::uint32_t* a, std::uint32_t* b, std::uint32_t* edge) {
                return ::cadaclysm_fem_mesh_open_edge(handle, i, a, b, edge);
            },
            [](std::uint32_t i) { return detail::reader_error(("fem mesh open edge " + std::to_string(i)).c_str()); });
    }

    // Every fold, as open_edges() reports a crack: a directed mesh edge used by more than
    // one triangle. **A body can be folded without being open** -- a solid no thicker than
    // a line leaves no hole for an open edge to find, and the closure census's own
    // known-bad bodies are folds rather than open cracks, so a caller that checks
    // open_edges() alone calls such a body sound. Empty under the same rule.
    Result<std::vector<std::array<std::uint32_t, 3>>> folded_edges() const {
        const CadaclysmFemMesh* handle = live("FemMesh::folded_edges");
        return detail::census_rows(
            view_.folded_edge_count,
            [handle](std::uint32_t i, std::uint32_t* a, std::uint32_t* b, std::uint32_t* edge) {
                return ::cadaclysm_fem_mesh_folded_edge(handle, i, a, b, edge);
            },
            [](std::uint32_t i) { return detail::reader_error(("fem mesh folded edge " + std::to_string(i)).c_str()); });
    }

    // The welded mesh closes -- and, for a B-rep body, so does the topology behind it.
    // **False for every B-rep body whose topology is not closed**, whose mesh is then not
    // asked about at all; read open_edges() for what an empty census beside a false here
    // does and does not mean. A from_mesh() body has no topology to ask of, so this says
    // only that its triangles close.
    bool watertight() const { return view("FemMesh::watertight").watertight; }

    // This came from the scene's own mesh rather than from a brep: one face, every node on
    // face `0`, no edges and no vertices.
    //
    // **It is also which space the mesh is in.** A B-rep body's FEM mesh is in the file's
    // own units and axes, whatever Convention the scene was opened with, because it is
    // taken off the brep. A node with no brep falls back to the scene's mesh, which *is*
    // converted, so it comes back in the scene's convention, wound counter-clockwise about
    // the outward normal even where the convention winds the other way. Under a non-native
    // convention those are two different spaces. It is also which contract watertight()
    // and the two censuses are reporting under: read open_edges().
    bool from_mesh() const { return view("FemMesh::from_mesh").from_mesh; }

    // The smallest interior angle of any triangle, in degrees. There is always one: a body
    // that meshed to no triangles is a refusal, not a mesh.
    double min_angle() const { return view("FemMesh::min_angle").min_angle; }
    // The triangle with that angle, as an index into triangles() by triple.
    std::uint32_t worst_triangle() const { return view("FemMesh::worst_triangle").worst_triangle; }
    // The longest triangle edge, placed.
    //
    // **The figure to check against Node::fem_mesh()'s max_size, and the only one that
    // says what the mesh actually is**: max_size bounds the boundary segments and merely
    // *targets* the interior -- measured at 1.03 x max_size on a face whose parameters run
    // unevenly -- and one small enough beside the body to reach the mesher's own piece and
    // station ceilings is not honoured at all.
    double longest_edge() const { return view("FemMesh::longest_edge").longest_edge; }

    // The mesh as Gmsh 4.1 ASCII `.msh` text: an entity per B-rep vertex, edge and face, a
    // volume where the body closes, and a physical group naming each.
    //
    // **The library's text is borrowed from this handle** and replaced by the next call on
    // it -- this ABI's convention, and the opposite of the kernel library's, where
    // blacksmith::FemMesh::msh_text() is handed an owned string to free. Nothing here has
    // to free anything either way: the `char *` is copied into a std::string on the way
    // out, which outlives the handle.
    //
    // **No unlicensed notice is printed here.** Node::fem_mesh() gave it once when the
    // mesh was built, and this ABI deliberately does not repeat it on either `.msh` call --
    // where the kernel library notices on both of its writers and *not* on its builder.
    // Each matches its own siblings, so moving the call to look like the other side breaks
    // a convention.
    //
    // An Error for a mesh the writer refuses, naming the field it cannot honour.
    Result<std::string> msh_text() const {
        const char* text = ::cadaclysm_fem_mesh_msh_text(live("FemMesh::msh_text"));
        if (!text) return detail::reader_error("msh text");
        return std::string(text);
    }

    // msh_text() written to `path` by the library itself: the same bytes from the same
    // writer, straight to the file rather than through the borrowed slot, so a msh_text()
    // call on this handle from another thread cannot free the text under the write. No
    // notice here either; see msh_text().
    Result<void> save_msh(const std::string& path) const {
        if (!::cadaclysm_fem_mesh_save_msh(live("FemMesh::save_msh"), path.c_str())) {
            return detail::reader_error(("could not write " + path).c_str());
        }
        return {};
    }

private:
    friend class Node;
    struct Free {
        void operator()(CadaclysmFemMesh* mesh) const noexcept { ::cadaclysm_fem_mesh_free(mesh); }
    };
    FemMesh(CadaclysmFemMesh* handle, const CadaclysmFemMeshView& read) : ptr_(handle), view_(read) {}

    // The handle, refusing a freed (or moved-from) one: a read after free() is a bug in
    // the caller, not a recoverable state, exactly as Meshlets has it.
    const CadaclysmFemMesh* live(const char* what) const {
        if (!ptr_) detail::bad_access(what, "the FEM mesh is freed");
        return ptr_.get();
    }
    // The view, read once when the handle was made: every pointer in it is built with the
    // handle and good until it is freed -- nothing in this ABI is built lazily -- so asking
    // again per accessor would be one C call per array for the same answer.
    const CadaclysmFemMeshView& view(const char* what) const {
        live(what);
        return view_;
    }

    std::unique_ptr<CadaclysmFemMesh, Free> ptr_;
    CadaclysmFemMeshView view_{};
};

namespace detail {
inline bool truthy(const Attribute& attribute) {
    if (const auto* s = std::get_if<std::string>(&attribute.value)) return !s->empty();
    if (const auto* i = std::get_if<std::int64_t>(&attribute.value)) return *i != 0;
    if (const auto* d = std::get_if<double>(&attribute.value)) return *d != 0.0;
    if (const auto* b = std::get_if<bool>(&attribute.value)) return *b;
    return false;
}

// Column-major 16 (as the ABI hands matrices over) to rows.
template <class Number>
Matrix4 rows_of(const Number* column_major) {
    Matrix4 m{};
    for (int i = 0; i < 4; ++i)
        for (int j = 0; j < 4; ++j) m[i][j] = static_cast<double>(column_major[j * 4 + i]);
    return m;
}
}  // namespace detail

// ---- svg ----------------------------------------------------------------------------

// One of the seven camera angles SvgOptions::view understands -- the same table
// cadaclysm_viewer.VIEWS gives Python's show() and svg() both.
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
// and which line sets. Mirrors CadaclysmSvgOptions, defaulted the way
// cadaclysm_svg_options_init defaults the struct, with `view` supplying
// azimuth/elevation unless they are set directly (non-nullopt).
//
// Passed to Scene::svg_text, Scene::svg, Node::svg_text and Node::svg. A refused
// option (an out-of-range fov, say) is an Error naming the field, worded by the
// library itself.
struct SvgOptions {
    // front back left right top bottom iso -- fills azimuth/elevation unless they are
    // set directly. Default iso.
    SvgView view = SvgView::iso;
    // Degrees about the up axis from +X, overriding view's: -90 looks from -Y, the
    // front. nullopt keeps view's own.
    std::optional<double> azimuth;
    // Degrees above the horizon, overriding view's. nullopt keeps view's own.
    std::optional<double> elevation;
    // "y" or "z"; nullopt keeps the scene's own convention -- Convention::unity and
    // Convention::y_up give "y", every other convention "z".
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
    // Each shape's feature edges -- the exact curves the flattened polylines are drawn
    // from. Default true.
    bool edges = true;
    // Each shape's free curves -- the ones that are not the edge of any face. Default
    // false.
    bool curves = false;
    // Each shape's isocurves -- the constant-parameter lines across a curved face.
    // Default false.
    bool isocurves = false;
    // Write every line as straight segments within tolerance, instead of being fitted
    // back to cubic Beziers. Default false.
    bool polylines = false;
};

namespace detail {
// `options` packed into a CadaclysmSvgOptions: `view` fills azimuth/elevation unless
// they are set directly, `up` falls back to `default_up` ("y" or "z").
// cadaclysm_svg_options_init fills the struct first -- size included -- so a field
// this function never sets still carries the library's own default rather than a
// zeroed struct's.
inline CadaclysmSvgOptions build_svg_options(const SvgOptions& options, const std::string& default_up) {
    CadaclysmSvgOptions raw;
    ::cadaclysm_svg_options_init(&raw);
    auto [base_azimuth, base_elevation] = svg_view_angles(options.view);
    const std::string& up = options.up ? *options.up : default_up;
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
    raw.background = options.background.value_or(CADACLYSM_SVG_TRANSPARENT);
    raw.flags = (options.edges ? CADACLYSM_SVG_EDGES : 0u) | (options.curves ? CADACLYSM_SVG_CURVES : 0u) |
                (options.isocurves ? CADACLYSM_SVG_ISOCURVES : 0u) | (options.polylines ? CADACLYSM_SVG_POLYLINES : 0u);
    return raw;
}

// "y" or "z": what SvgOptions::up falls back to when left nullopt --
// Convention::unity and Convention::y_up give "y", every other convention "z".
// FILE_UNITS/UV_WORLD are masked out first, since they OR into the packed
// convention a scene carries.
inline std::string default_up_of(std::uint32_t convention) {
    std::uint32_t base = convention & ~(FILE_UNITS | UV_WORLD);
    bool y_up = base == static_cast<std::uint32_t>(Convention::unity) || base == static_cast<std::uint32_t>(Convention::y_up);
    return y_up ? "y" : "z";
}
}  // namespace detail

// ---- nodes ------------------------------------------------------------------------

// One node of an open scene: a cheap handle (scene + index), copied freely. Valid
// while its Scene is open; in checked mode a read after close() is a bad access.
class Node {
public:
    std::uint32_t index() const noexcept { return index_; }

    std::string name() const { return detail::text(::cadaclysm_node_name(h(), index_)); }
    std::string id() const { return detail::text(::cadaclysm_node_id(h(), index_)); }
    std::string kind() const { return detail::text(::cadaclysm_node_kind(h(), index_)); }
    bool visible() const { return ::cadaclysm_node_visible(h(), index_); }

    // Visible, and so is every ancestor.
    bool visible_now() const {
        std::optional<Node> node = *this;
        while (node) {
            if (!node->visible()) return false;
            node = node->parent();
        }
        return true;
    }

    // The "Locked" attribute, read as Python's bool() reads it; false without one.
    bool locked() const {
        for (const Attribute& attribute : attributes()) {
            if (attribute.name == "Locked") return detail::truthy(attribute);
        }
        return false;
    }

    // The name, else the kind, else "#<index>".
    std::string label() const {
        std::string n = name();
        if (!n.empty()) return n;
        std::string k = kind();
        if (!k.empty()) return k;
        return "#" + std::to_string(index_);
    }

    std::uint32_t depth() const { return ::cadaclysm_node_depth(h(), index_); }
    std::string generator() const { return detail::text(::cadaclysm_node_generator(h(), index_)); }
    std::optional<Node> parent() const { return or_none(::cadaclysm_node_parent(h(), index_)); }

    std::vector<Node> children() const {
        const CadaclysmScene* scene = h();
        std::uint32_t count = ::cadaclysm_node_child_count(scene, index_);
        std::vector<Node> out;
        out.reserve(count);
        for (std::uint32_t i = 0; i < count; ++i) out.push_back(Node(scene_, ::cadaclysm_node_child(scene, index_, i)));
        return out;
    }

    std::optional<Node> instance_of() const { return or_none(::cadaclysm_node_instance_of(h(), index_)); }

    // What a click on this node should select: itself unless the file says otherwise.
    Node select_as() const {
        std::uint32_t chosen = ::cadaclysm_node_select_as(h(), index_);
        return chosen == NONE ? *this : Node(scene_, chosen);
    }

    std::vector<Attribute> attributes() const {
        const CadaclysmScene* scene = h();
        std::uint32_t count = ::cadaclysm_node_attribute_count(scene, index_);
        std::vector<Attribute> out;
        for (std::uint32_t i = 0; i < count; ++i) {
            CadaclysmAttribute raw = ::cadaclysm_node_attribute(scene, index_, i);
            if (raw.name == nullptr) continue;  // one past the end; a real "" name is kept
            Attribute a;
            a.name = raw.name;
            std::uint32_t raw_kind = static_cast<std::uint32_t>(raw.kind);
            a.kind = raw_kind <= 6 ? static_cast<ValueKind>(raw_kind) : ValueKind::none;
            switch (a.kind) {
                case ValueKind::text:
                case ValueKind::list:
                case ValueKind::reference: a.value = detail::text(raw.text); break;
                case ValueKind::integer: a.value = static_cast<std::int64_t>(raw.integer); break;
                case ValueKind::real: a.value = raw.real; break;
                case ValueKind::boolean: a.value = static_cast<bool>(raw.boolean); break;
                case ValueKind::none: break;
            }
            out.push_back(std::move(a));
        }
        return out;
    }

    bool can_mesh() const { return ::cadaclysm_node_can_mesh(h(), index_); }

    // Write this node's mesh alone: "stl", "stl-ascii", "obj", ... (see mesh_formats()).
    Result<void> save_mesh(const std::string& path, const std::string& format = "stl") const {
        if (!::cadaclysm_node_save_mesh(h(), index_, path.c_str(), format.c_str())) {
            return detail::reader_error(("could not write " + path).c_str());
        }
        return {};
    }

    // This node's own wireframe as SVG text, in its own frame -- Scene::svg_text's
    // `options`, read from just this node rather than every placement.
    Result<std::string> svg_text(const SvgOptions& options = SvgOptions()) const {
        CadaclysmSvgOptions raw = detail::build_svg_options(options, detail::default_up_of(scene_.get("Node").convention));
        const char* text = ::cadaclysm_node_svg_text(h(), index_, &raw);
        if (!text) return detail::reader_error("svg");
        return std::string(text);
    }
    // svg_text() written to `path` by the library itself.
    Result<void> svg(const std::string& path, const SvgOptions& options = SvgOptions()) const {
        CadaclysmSvgOptions raw = detail::build_svg_options(options, detail::default_up_of(scene_.get("Node").convention));
        if (!::cadaclysm_node_svg(h(), index_, path.c_str(), &raw)) {
            return detail::reader_error(("could not write " + path).c_str());
        }
        return {};
    }

    // Its triangles, in its own frame, built now if they have not been.
    Mesh mesh() const { return Mesh(scene_, ::cadaclysm_node_mesh(h(), index_)); }

    // mesh()'s own mesh, in `double`, lent rather than narrowed -- see Mesh64. All-null
    // (empty()) for a node with nothing to mesh.
    Mesh64 mesh64() const { return Mesh64(scene_, ::cadaclysm_node_mesh64(h(), index_)); }

    // Its triangles at a coarser level of detail: 0 is mesh() itself, 1 up to
    // lod_levels() each about a quarter of the triangles of the one before, and past
    // that empty. Every level shares the level-0 vertices -- the same positions, only
    // the indices differ -- so upload the vertices once and switch level by index range.
    Mesh mesh_lod(std::uint32_t level) const { return Mesh(scene_, ::cadaclysm_node_mesh_lod(h(), index_, level)); }
    // How far mesh_lod(level) moved the surface, in the scene's units; zero at level 0.
    float lod_error(std::uint32_t level) const { return ::cadaclysm_node_lod_error(h(), index_, level); }

    // This node's body meshed for a solver, as a FemMesh: nodes welded by bits, triangles
    // wound outward, each node tagged with the lowest-dimension B-rep entity it lies on,
    // and every crack reported rather than closed. **Owned by the caller** -- it outlives
    // the scene, and nothing but free() or its destructor gives it back.
    //
    // `tolerance` is the chordal tolerance in model units, finite and above zero, and **it
    // alone governs how closely the mesh follows the geometry**. `max_size` is a size
    // ceiling, finite and zero or more, `0` being no ceiling (curvature alone): **it bounds
    // the boundary segments and merely targets the interior**, which is not a
    // longest-element-edge guarantee -- it adds boundary nodes without refining boundary
    // geometry, and FemMesh::longest_edge() is what the mesh actually came to, the figure
    // to check against this.
    //
    // **Those two defaults are FemOptions::default()'s own**, restated here so that the
    // signature says what a caller gets -- and 0.01 is not the 0.05 that mesh() and its
    // neighbours default to. The library's struct is still filled by
    // `cadaclysm_fem_options_init` first, so a field added to it later defaults without
    // this line being touched; only these two are overwritten.
    //
    // `placement` is 16 numbers, column-major, as bounds_placed() takes them (nothing for
    // the identity), applied in `double` throughout. The kernel library's
    // blacksmith::Solid::fem_mesh takes **twelve** instead -- origin, x, y, z -- so a
    // caller moving between the two reformats the placement.
    //
    // **The space is the body's, not the scene's, for a B-rep -- and the scene's for a
    // mesh**, which FemMesh::from_mesh() is the flag for; read it there, because under a
    // non-native Convention the two are different spaces. Meshed in the part's own frame
    // and following the hop from an instance to the shape it draws that mesh() follows, so
    // a node instanced six times meshes once.
    //
    // **A cracked body is not a failure**: it comes back with FemMesh::watertight() false
    // and its cracks in FemMesh::open_edges() and FemMesh::folded_edges() -- *both* -- and
    // nothing is welded shut to make it look sound. An Error for a tolerance or size the
    // mesher refuses, a placement that is not finite and invertible, a node with neither a
    // brep nor a mesh (an assembly, a storey, a layer, an empty definition, a curve), and a
    // body that meshes to no triangles at all, carrying the library's own words for it.
    // Neither `tolerance` nor `max_size` is checked here: the mesh-only path reads neither
    // (its mesher takes no options at all), so a wrapper that refused either would refuse
    // calls the library answers.
    //
    // Prints the unlicensed notice once, here, and not again on either of the mesh's
    // `.msh` calls.
    Result<FemMesh> fem_mesh(double tolerance = 0.01, double max_size = 0.0,
                             const std::optional<std::array<double, 16>>& placement = std::nullopt) const {
        CadaclysmFemOptions options{};
        // `init` writes `sizeof(CadaclysmFemOptions)` bytes as the *library* knows that
        // type; `size` is then set to this header's own sizeof, which is what the growth
        // rule asks of a caller. Nothing is transcribed here -- this wrapper compiles
        // against the library's own header -- so there is no layout to pin.
        ::cadaclysm_fem_options_init(&options);
        options.size = sizeof(CadaclysmFemOptions);
        options.tolerance = tolerance;
        options.max_size = max_size;
        CadaclysmFemMesh* handle =
            ::cadaclysm_node_fem_mesh(h(), index_, placement ? placement->data() : nullptr, &options);
        if (!handle) return detail::reader_error("fem_mesh");
        CadaclysmFemMeshView read{};
        if (!::cadaclysm_fem_mesh_view(handle, &read)) {
            Error why = detail::reader_error("fem mesh view");
            ::cadaclysm_fem_mesh_free(handle);
            return why;
        }
        return FemMesh(handle, read);
    }

    Polylines edges() const { return Polylines(scene_, ::cadaclysm_node_edges(h(), index_)); }
    // One RGBA per polyline of edges(), empty optional for an edge the file does not
    // style; empty vector when nothing is styled.
    std::vector<std::optional<std::array<float, 4>>> edge_colours() const { return colours_of(::cadaclysm_node_edge_colors(h(), index_)); }
    Polylines curves() const { return Polylines(scene_, ::cadaclysm_node_curves(h(), index_)); }
    // Isocurves across the faces, so a curved face reads as curved.
    Polylines isocurves() const { return Polylines(scene_, ::cadaclysm_node_isocurves(h(), index_)); }

    // Its feature edges as cubic Bézier curves -- exact where the file's curves were,
    // where edges() are their chords. Builds the geometry if needed.
    Beziers edge_beziers() const { return Beziers(scene_, ::cadaclysm_node_edge_beziers(h(), index_)); }
    Beziers curve_beziers() const { return Beziers(scene_, ::cadaclysm_node_curve_beziers(h(), index_)); }
    Beziers isocurve_beziers() const { return Beziers(scene_, ::cadaclysm_node_isocurve_beziers(h(), index_)); }

    // The same three, unnarrowed -- see Beziers64.
    Beziers64 edge_beziers64() const { return Beziers64(scene_, ::cadaclysm_node_edge_beziers64(h(), index_)); }
    Beziers64 curve_beziers64() const { return Beziers64(scene_, ::cadaclysm_node_curve_beziers64(h(), index_)); }
    Beziers64 isocurve_beziers64() const {
        return Beziers64(scene_, ::cadaclysm_node_isocurve_beziers64(h(), index_));
    }

    // The collision body for what this node draws, building its mesh if it is not
    // built. hull_budget is the most triangles a hull may have; 0 asks for the Unity
    // limit (255) and is not clamped to it. Nothing for a node that draws nothing.
    // Cached per node and budget.
    std::optional<Collision> collision(std::uint32_t hull_budget = 0) const {
        CadaclysmCollision raw{};
        raw.size = sizeof(CadaclysmCollision);
        if (!::cadaclysm_node_collision(h(), index_, hull_budget, &raw)) return std::nullopt;
        Collision out;
        out.shape = raw.shape;
        out.confidence = raw.confidence;
        out.axis = raw.axis;
        for (int i = 0; i < 16; ++i) out.frame[i] = raw.frame[i];
        for (int i = 0; i < 3; ++i) out.half_extent[i] = raw.half_extent[i];
        out.radius = raw.radius;
        out.height = raw.height;
        out.error = raw.error;
        out.hull_vertex_count = raw.hull_vertex_count;
        out.hull_index_count = raw.hull_index_count;
        return out;
    }

    // The convex hull collision() counted, as triangles. Empty for a node that draws
    // nothing. A view into the scene, good until it closes or this node is asked for a
    // different hull_budget, which refits and frees it.
    CollisionHull collision_hull(std::uint32_t hull_budget = 0) const {
        return CollisionHull(scene_, ::cadaclysm_node_collision_hull(h(), index_, hull_budget));
    }

    Surfaces surfaces() const {
        CadaclysmSurfaces raw = ::cadaclysm_node_surfaces(h(), index_);
        std::vector<Face> faces;
        faces.reserve(raw.face_count);
        for (std::uint32_t i = 0; i < raw.face_count; ++i) {
            const CadaclysmFace& f = raw.faces[i];
            Face face;
            face.kind = f.kind;
            face.reversed = f.reversed != 0;
            face.transposed = f.transposed != 0;
            for (int k = 0; k < 3; ++k) {
                face.origin[k] = f.origin[k];
                face.ax[k] = f.ax[k];
                face.ay[k] = f.ay[k];
                face.az[k] = f.az[k];
            }
            for (int k = 0; k < 4; ++k) {
                face.domain[k] = f.domain[k];
                face.scalars[k] = f.scalars[k];
            }
            for (std::uint32_t l = 0; l < f.loop_count; ++l) {
                std::uint32_t start = raw.loops[2 * (f.loop_start + l)];
                std::uint32_t length = raw.loops[2 * (f.loop_start + l) + 1];
                face.loops.push_back(Span<const float>(raw.points + 2 * static_cast<std::size_t>(start), 2 * static_cast<std::size_t>(length)));
            }
            face.profile = Span<const float>(raw.profiles + 4 * static_cast<std::size_t>(f.profile_start), 4 * static_cast<std::size_t>(f.profile_count));
            face.profile2 = Span<const float>(raw.profiles + 4 * static_cast<std::size_t>(f.profile2_start), 4 * static_cast<std::size_t>(f.profile2_count));
            face.nurbs = Span<const float>(raw.nurbs + f.nurbs_start, f.nurbs_count);
            faces.push_back(std::move(face));
        }
        return Surfaces(scene_, std::move(faces));
    }

    // Its exact B-rep, or nothing (a mesh, a curve, a CSG body, a JT or OpenSCAD part).
    std::optional<Brep> brep() const {
        const CadaclysmBrep* pointer = ::cadaclysm_node_brep(h(), index_);
        if (!pointer) return std::nullopt;
        return Brep(pointer);
    }

    // RGBA in 0..1, or nothing where the file gave the node no colour.
    std::optional<std::array<float, 4>> colour() const {
        std::array<float, 4> rgba{};
        if (!::cadaclysm_node_color(h(), index_, rgba.data())) return std::nullopt;
        return rgba;
    }

    // Where to draw it, as rows.
    Matrix4 transform() const {
        std::array<double, 16> raw = raw_transform();
        return detail::rows_of(raw.data());
    }

    // The sixteen numbers as the ABI hands them over: column-major.
    std::array<double, 16> raw_transform() const {
        std::array<double, 16> out{};
        ::cadaclysm_node_transform(h(), index_, out.data());
        return out;
    }

    // The box of the node's exact surfaces carried through the convention and
    // placement (sixteen column-major doubles, as raw_transform() gives them) --
    // without meshing. The all-zero box for a node that has no surfaces.
    Bounds bounds_placed(const std::array<double, 16>& placement) const {
        return bounds_of(::cadaclysm_node_bounds_placed(h(), index_, placement.data()));
    }
    // The same in the node's own frame.
    Bounds bounds_placed() const { return bounds_of(::cadaclysm_node_bounds_placed(h(), index_, nullptr)); }

    // bounds_placed(placement), in `double`.
    Bounds64 bounds_placed64(const std::array<double, 16>& placement) const {
        return bounds64_of(::cadaclysm_node_bounds_placed64(h(), index_, placement.data()));
    }
    // bounds_placed(), in `double`.
    Bounds64 bounds_placed64() const { return bounds64_of(::cadaclysm_node_bounds_placed64(h(), index_, nullptr)); }

    // Whether the triangles are built and held. Asking for surface products
    // (surface_edges, surface_pick, ...) leaves this false.
    bool is_meshed() const { return ::cadaclysm_node_is_meshed(h(), index_); }

    // The node's edges from its trim loops, without meshing, in the surfaces' frame
    // (Scene::surface_matrix). Empty for a node without surfaces.
    Polylines surface_edges() const { return Polylines(scene_, ::cadaclysm_node_surface_edges(h(), index_)); }
    // edge_colours() for surface_edges().
    std::vector<std::optional<std::array<float, 4>>> surface_edge_colours() const { return colours_of(::cadaclysm_node_surface_edge_colors(h(), index_)); }

    // Its edges as the exact curves, where the reader has them without meshing -- a Rhino
    // extrusion's rims are its profile -- and empty everywhere else, so a caller drawing
    // from surfaces tries this before surface_edges(), whose trims are thinned to the mesh
    // tolerance. The same segments as edge_beziers(), in the same space: not the surfaces'
    // frame, so no Scene::surface_matrix.
    Beziers surface_edge_beziers() const { return Beziers(scene_, ::cadaclysm_node_surface_edge_beziers(h(), index_)); }
    // Isocurves the same way.
    Polylines surface_isocurves() const { return Polylines(scene_, ::cadaclysm_node_surface_isocurves(h(), index_)); }

    // Where the segment from -> to (in the surfaces' frame) first hits the node's
    // exact surfaces, without meshing. Nothing where it misses, or without surfaces.
    std::optional<Vec3> surface_pick(const Vec3& from, const Vec3& to) const {
        Vec3 out{};
        if (!::cadaclysm_node_surface_pick(h(), index_, from.data(), to.data(), out.data())) return std::nullopt;
        return out;
    }

    // A coarse stand-in for the mesh: each face gridded cells x cells, in the
    // scene's space like mesh(). Built once per node at the first cells asked.
    // Empty without surfaces or for cells == 0.
    Mesh surface_proxy_mesh(std::uint32_t cells) const {
        return Mesh(scene_, ::cadaclysm_node_surface_proxy_mesh(h(), index_, cells));
    }

    // How many triangles mesh() would hold, if the reader can say without meshing;
    // -1 where it cannot.
    std::int64_t triangle_estimate() const { return ::cadaclysm_node_triangle_estimate(h(), index_); }

    // In the node's own frame. Meshes the node to find out.
    Bounds bounds() const { return bounds_of(::cadaclysm_node_bounds(h(), index_)); }

    // bounds(), in `double`.
    Bounds64 bounds64() const { return bounds64_of(::cadaclysm_node_bounds64(h(), index_)); }

    // This node and every node under it, parents before children.
    std::vector<Node> walk() const {
        std::vector<Node> out;
        std::vector<Node> stack{*this};
        while (!stack.empty()) {
            Node node = stack.back();
            stack.pop_back();
            out.push_back(node);
            std::vector<Node> kids = node.children();
            for (auto it = kids.rbegin(); it != kids.rend(); ++it) stack.push_back(*it);
        }
        return out;
    }

    bool operator==(const Node& other) const noexcept {
        return index_ == other.index_ && scene_.identity() == other.scene_.identity();
    }
    bool operator!=(const Node& other) const noexcept { return !(*this == other); }

private:
    friend class Placement;
    friend class Link;
    friend class Scene;
    friend struct detail::Access;

    Node(detail::Ref<detail::SceneState> scene, std::uint32_t which) : scene_(std::move(scene)), index_(which) {}

    const CadaclysmScene* h() const { return scene_.get("Node").handle; }
    std::optional<Node> or_none(std::uint32_t which) const {
        if (which == NONE) return std::nullopt;
        return Node(scene_, which);
    }

    static Bounds bounds_of(const CadaclysmBounds& raw) {
        Bounds b;
        for (int i = 0; i < 3; ++i) {
            b.min[i] = raw.min[i];
            b.max[i] = raw.max[i];
        }
        return b;
    }

    static Bounds64 bounds64_of(const CadaclysmBounds64& raw) {
        Bounds64 b;
        for (int i = 0; i < 3; ++i) {
            b.min[i] = raw.min[i];
            b.max[i] = raw.max[i];
        }
        return b;
    }

    // One RGBA per polyline, copied out; an edge the file does not style comes back as
    // an empty optional rather than a zeroed colour, so "no style" and "styled black"
    // stay distinct. Empty vector for {nullptr, 0} -- nothing styled -- not one entry a
    // polyline.
    static std::vector<std::optional<std::array<float, 4>>> colours_of(const CadaclysmEdgeColors& raw) {
        std::vector<std::optional<std::array<float, 4>>> out;
        if (!raw.rgba || raw.count == 0) return out;
        out.reserve(raw.count);
        for (std::uint32_t i = 0; i < raw.count; ++i) {
            const float* c = raw.rgba + 4 * static_cast<std::size_t>(i);
            if (c[3] < 0) {
                out.emplace_back(std::nullopt);
            } else {
                out.push_back(std::array<float, 4>{c[0], c[1], c[2], c[3]});
            }
        }
        return out;
    }

    detail::Ref<detail::SceneState> scene_;
    std::uint32_t index_ = 0;
};

namespace detail {
struct Access {
    // The packed convention the node's scene was opened with.
    static std::uint32_t convention(const Node& node) { return node.scene_.get("Node").convention; }
};
}  // namespace detail

// One drawing of one node's geometry, at one place -- the list to iterate to draw.
class Placement {
public:
    std::uint32_t index() const noexcept { return index_; }

    // The node whose mesh, edges and curves this draws.
    Node geometry() const { return Node(scene_, ::cadaclysm_placement_geometry(h(), index_)); }

    // What a click on this drawing should select.
    Node select() const { return Node(scene_, ::cadaclysm_placement_select(h(), index_)); }

    Matrix4 transform() const {
        std::array<double, 16> raw = raw_transform();
        return detail::rows_of(raw.data());
    }

    std::array<double, 16> raw_transform() const {
        std::array<double, 16> out{};
        ::cadaclysm_placement_transform(h(), index_, out.data());
        return out;
    }

private:
    friend class Scene;
    Placement(detail::Ref<detail::SceneState> scene, std::uint32_t which) : scene_(std::move(scene)), index_(which) {}
    const CadaclysmScene* h() const { return scene_.get("Placement").handle; }

    detail::Ref<detail::SceneState> scene_;
    std::uint32_t index_ = 0;
};

// A rigid body of the file's mechanism: the nodes that move together when a joint
// moves it. From Scene::links; borrows from the scene like Node.
class Link {
public:
    std::uint32_t index() const noexcept { return index_; }

    // The link's name as the file gives it.
    std::string name() const { return detail::text(::cadaclysm_link_name(h(), index_)); }

    // The topmost node of each subtree this link moves, in node order: moving these
    // moves everything under them.
    std::vector<Node> nodes() const {
        const CadaclysmScene* scene = h();
        std::uint32_t count = ::cadaclysm_link_node_count(scene, index_);
        std::vector<Node> out;
        out.reserve(count);
        for (std::uint32_t i = 0; i < count; ++i) out.push_back(Node(scene_, ::cadaclysm_link_node(scene, index_, i)));
        return out;
    }

    bool operator==(const Link& other) const noexcept {
        return index_ == other.index_ && scene_.identity() == other.scene_.identity();
    }
    bool operator!=(const Link& other) const noexcept { return !(*this == other); }

private:
    friend class Scene;
    friend class Joint;
    Link(detail::Ref<detail::SceneState> scene, std::uint32_t which) : scene_(std::move(scene)), index_(which) {}
    const CadaclysmScene* h() const { return scene_.get("Link").handle; }

    detail::Ref<detail::SceneState> scene_;
    std::uint32_t index_ = 0;
};

// A connection between two links of the file's mechanism. Topology only: how it
// moves is not read yet. From Scene::joints.
class Joint {
public:
    std::uint32_t index() const noexcept { return index_; }

    // The joint's name as the file gives it.
    std::string name() const { return detail::text(::cadaclysm_joint_name(h(), index_)); }

    // The link this joint starts at, in the file's order -- not a parent: a
    // mechanism may be a network with loops.
    Link start() const { return Link(scene_, ::cadaclysm_joint_start(h(), index_)); }

    // The link this joint ends at, in the file's order.
    Link end() const { return Link(scene_, ::cadaclysm_joint_end(h(), index_)); }

    bool operator==(const Joint& other) const noexcept {
        return index_ == other.index_ && scene_.identity() == other.scene_.identity();
    }
    bool operator!=(const Joint& other) const noexcept { return !(*this == other); }

private:
    friend class Scene;
    Joint(detail::Ref<detail::SceneState> scene, std::uint32_t which) : scene_(std::move(scene)), index_(which) {}
    const CadaclysmScene* h() const { return scene_.get("Joint").handle; }

    detail::Ref<detail::SceneState> scene_;
    std::uint32_t index_ = 0;
};

// ---- the scene ----------------------------------------------------------------------

// An open document. Move-only; closes when destroyed or on close(). Everything it
// hands back borrows from it.
class Scene {
public:
    Scene(Scene&&) noexcept = default;
    Scene& operator=(Scene&&) noexcept = default;
    Scene(const Scene&) = delete;
    Scene& operator=(const Scene&) = delete;
    ~Scene() = default;

    // The file this was read from (open_memory: the name it was given).
    const std::string& path() const { return state("path").path; }
    // The schema passed to open, if any.
    const std::optional<std::string>& schema_path() const { return state("schema_path").schema_path; }
    // The packed convention this was opened with.
    std::uint32_t convention() const { return state("convention").convention; }

    bool closed() const noexcept { return !state_ || !state_->live(); }
    // Give the scene back. Idempotent. Every borrowed view is invalid afterwards.
    void close() noexcept {
        if (state_) state_->close();
    }

    std::string version() const { return cadaclysm::version(); }
    std::string schema() const { return detail::text(::cadaclysm_schema(h())); }
    std::string schema_read() const { return detail::text(::cadaclysm_schema_read(h())); }

    // Whether the file was read under a schema other than the one it declared.
    bool substituted() const {
        std::string read = schema_read();
        if (read.empty()) return false;
        auto bare = [](std::string entry) {
            entry = entry.substr(0, entry.find('{'));
            const char* trim = " \t\r\n\f\v.";
            std::size_t first = entry.find_first_not_of(trim);
            if (first == std::string::npos) return std::string();
            entry = entry.substr(first, entry.find_last_not_of(trim) - first + 1);
            for (char& c : entry) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
            return entry;
        };
        std::string wanted = bare(read);
        std::string declared = schema();
        std::size_t start = 0;
        while (start <= declared.size()) {
            std::size_t end = declared.find(',', start);
            if (end == std::string::npos) end = declared.size();
            if (bare(declared.substr(start, end - start)) == wanted) return false;
            start = end + 1;
        }
        return true;
    }

    double metres_per_unit() const { return ::cadaclysm_metres_per_unit(h()); }

    // The whole scene's bounds. Meshes all of it to find out.
    Bounds bounds() const {
        CadaclysmBounds raw = ::cadaclysm_bounds(h());
        Bounds b;
        for (int i = 0; i < 3; ++i) {
            b.min[i] = raw.min[i];
            b.max[i] = raw.max[i];
        }
        return b;
    }

    // bounds(), in `double`. This meshes all of it too, being the only way to know how
    // far it reaches.
    Bounds64 bounds64() const {
        CadaclysmBounds64 raw = ::cadaclysm_bounds64(h());
        Bounds64 b;
        for (int i = 0; i < 3; ++i) {
            b.min[i] = raw.min[i];
            b.max[i] = raw.max[i];
        }
        return b;
    }

    std::vector<std::string> diagnostics() const {
        const CadaclysmScene* scene = h();
        std::uint32_t count = ::cadaclysm_diagnostic_count(scene);
        std::vector<std::string> out;
        out.reserve(count);
        for (std::uint32_t i = 0; i < count; ++i) out.push_back(detail::text(::cadaclysm_diagnostic(scene, i)));
        return out;
    }

    // What the reader built but the geometry stage could not finish -- a face that
    // would not trim, a surface that would not mesh. diagnostics() is what the file
    // held that could not be read; this is what the geometry did.
    std::vector<std::string> geometry_diagnostics() const {
        const CadaclysmScene* scene = h();
        std::uint32_t count = ::cadaclysm_geometry_diagnostic_count(scene);
        std::vector<std::string> out;
        out.reserve(count);
        for (std::uint32_t i = 0; i < count; ++i) out.push_back(detail::text(::cadaclysm_geometry_diagnostic(scene, i)));
        return out;
    }

    // The member a .zip was opened through, or nothing.
    std::optional<std::string> source_name() const {
        const char* raw = ::cadaclysm_source_name(h());
        if (!raw) return std::nullopt;
        return std::string(raw);
    }

    // The 4x4 (rows) that puts Node surfaces in the space everything else is in.
    Matrix4 surface_matrix() const {
        std::array<float, 16> out{};
        ::cadaclysm_surface_matrix(h(), out.data());
        return detail::rows_of(out.data());
    }

    std::uint32_t size() const { return ::cadaclysm_node_count(h()); }

    std::optional<Node> node(std::uint32_t index) const {
        if (index >= size()) return std::nullopt;
        return Node(ref(), index);
    }

    std::vector<Node> nodes() const {
        std::uint32_t count = size();
        std::vector<Node> out;
        out.reserve(count);
        detail::Ref<detail::SceneState> r = ref();
        for (std::uint32_t i = 0; i < count; ++i) out.push_back(Node(r, i));
        return out;
    }

    // The indices of the nodes a filter matches -- `class == solid and name == Wall`.
    // An error carries the parser's own message; an empty result is not an error.
    Result<std::vector<std::uint32_t>> query(const std::string& filter) const {
        const CadaclysmScene* scene = h();
        std::uint32_t total = ::cadaclysm_query(scene, filter.c_str(), nullptr, 0);
        if (total == 0) {
            std::string reason = detail::text(::cadaclysm_last_error());
            if (!reason.empty()) return Error{detail::file_name(path()) + ": " + reason, Origin::reader};
            return std::vector<std::uint32_t>();
        }
        std::vector<std::uint32_t> out(total);
        std::uint32_t written = ::cadaclysm_query(scene, filter.c_str(), out.data(), total);
        out.resize(written < total ? written : total);
        return out;
    }

    std::vector<Placement> placements() const {
        std::uint32_t count = ::cadaclysm_placement_count(h());
        std::vector<Placement> out;
        out.reserve(count);
        detail::Ref<detail::SceneState> r = ref();
        for (std::uint32_t i = 0; i < count; ++i) out.push_back(Placement(r, i));
        return out;
    }

    // The file's mechanism: rigid bodies and the joints between them. Empty when the
    // file names no mechanism.
    std::vector<Link> links() const {
        std::uint32_t count = ::cadaclysm_link_count(h());
        std::vector<Link> out;
        out.reserve(count);
        detail::Ref<detail::SceneState> r = ref();
        for (std::uint32_t i = 0; i < count; ++i) out.push_back(Link(r, i));
        return out;
    }

    std::vector<Joint> joints() const {
        std::uint32_t count = ::cadaclysm_joint_count(h());
        std::vector<Joint> out;
        out.reserve(count);
        detail::Ref<detail::SceneState> r = ref();
        for (std::uint32_t i = 0; i < count; ++i) out.push_back(Joint(r, i));
        return out;
    }

    std::vector<Node> roots() const {
        const CadaclysmScene* scene = h();
        std::uint32_t count = ::cadaclysm_root_count(scene);
        std::vector<Node> out;
        detail::Ref<detail::SceneState> r = ref();
        for (std::uint32_t i = 0; i < count; ++i) {
            std::uint32_t index = ::cadaclysm_root(scene, i);
            if (index != NONE) out.push_back(Node(r, index));
        }
        return out;
    }

    // Every node under every root, parents before children.
    std::vector<Node> walk() const {
        std::vector<Node> out;
        for (const Node& root : roots()) {
            std::vector<Node> below = root.walk();
            out.insert(out.end(), below.begin(), below.end());
        }
        return out;
    }

    // Mesh every node now, over every core. Safe to watch from another thread.
    std::uint32_t realize_all() const { return ::cadaclysm_realize_all(h()); }
    // realize_all, leaving the parts that carry exact surfaces alone when
    // skip_surfaced (the surface path draws those without triangles). How many it
    // meshed.
    std::uint32_t realize_meshes(bool skip_surfaced = true) const {
        return ::cadaclysm_realize_meshes(h(), skip_surfaced ? 1u : 0u);
    }
    std::uint32_t realized() const { return ::cadaclysm_realized(h()); }
    std::uint32_t realize_total() const { return ::cadaclysm_realize_total(h()); }
    // Stop realize_all, for the life of the scene.
    void cancel() const { ::cadaclysm_cancel(h()); }

    // Drop every mesh the scene has built; the next ask rebuilds. Every Mesh and
    // Polylines handed out before this is over freed memory.
    void forget_meshes() const { ::cadaclysm_forget_meshes(h()); }

    // Every placement of every shape as one file: "glb", "gltf" or "obj".
    Result<void> save(const std::string& path, const std::string& format = "glb") const {
        if (!::cadaclysm_scene_save(h(), path.c_str(), format.c_str())) {
            return detail::reader_error(("could not write " + path).c_str());
        }
        return {};
    }

    // Every visible placement's wireframe as SVG text, from the camera `options`
    // describes -- the library's own camera, not a viewer. See SvgOptions.
    Result<std::string> svg_text(const SvgOptions& options = SvgOptions()) const {
        CadaclysmSvgOptions raw = detail::build_svg_options(options, detail::default_up_of(convention()));
        const char* text = ::cadaclysm_scene_svg_text(h(), &raw);
        if (!text) return detail::reader_error("svg");
        return std::string(text);
    }
    // svg_text() written to `path` by the library itself.
    Result<void> svg(const std::string& path, const SvgOptions& options = SvgOptions()) const {
        CadaclysmSvgOptions raw = detail::build_svg_options(options, detail::default_up_of(convention()));
        if (!::cadaclysm_scene_svg(h(), path.c_str(), &raw)) {
            return detail::reader_error(("could not write " + path).c_str());
        }
        return {};
    }

private:
    friend Result<Scene> open(const std::string&, const OpenOptions&);
    friend Result<Scene> open_memory(const void*, std::size_t, const std::string&, const OpenOptions&);

    explicit Scene(std::shared_ptr<detail::SceneState> owned) : state_(std::move(owned)) {}

    detail::SceneState& state(const char* what) const {
        if (!state_) detail::bad_access(what, "the scene is empty (moved from)");
        if (!state_->live()) detail::bad_access(what, "the scene is closed");
        return *state_;
    }
    CadaclysmScene* h(const char* what = "Scene") const { return state(what).handle; }
    detail::Ref<detail::SceneState> ref() const {
        state("Scene");
        return detail::Ref<detail::SceneState>(state_);
    }

    std::shared_ptr<detail::SceneState> state_;
};

// ---- schemas --------------------------------------------------------------------------

// The schema a STEP or IFC file says it speaks, from its FILE_SCHEMA line.
inline Result<std::string> declared_schema(const std::string& model) {
    std::ifstream in(detail::fs_path(model), std::ios::binary);
    if (!in) return Error{model + ": cannot read", Origin::reader};
    std::string head(8192, '\0');
    in.read(&head[0], static_cast<std::streamsize>(head.size()));
    head.resize(static_cast<std::size_t>(in.gcount()));
    std::string upper = head;
    for (char& c : upper) c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
    std::size_t at = upper.find("FILE_SCHEMA");
    if (at == std::string::npos) return std::string();
    // FILE_SCHEMA \s* ( \s* ( \s* '<name>'
    std::size_t i = at + 11;
    auto skip_space = [&] { while (i < head.size() && std::isspace(static_cast<unsigned char>(head[i]))) ++i; };
    for (char expected : {'(', '('}) {
        skip_space();
        if (i >= head.size() || head[i] != expected) return std::string();
        ++i;
    }
    skip_space();
    if (i >= head.size() || head[i] != '\'') return std::string();
    std::size_t end = head.find('\'', i + 1);
    if (end == std::string::npos || end == i + 1) return std::string();
    return head.substr(i + 1, end - i - 1);
}

// `schema` resolved against `model`: one .exp to use, or a list of fallbacks to try.
struct SchemaChoice {
    std::optional<std::string> chosen;
    std::vector<std::string> fallbacks;
};

inline Result<SchemaChoice> resolve_schema(const std::string& model, const std::optional<std::string>& schema) {
    namespace fs = std::filesystem;
    if (!schema) return SchemaChoice{};
    std::error_code ignored;
    fs::path dir = detail::fs_path(*schema);
    if (fs::is_regular_file(dir, ignored)) return SchemaChoice{*schema, {}};
    if (!fs::is_directory(dir, ignored)) {
        return Error{"schema " + *schema + " is neither a file nor a directory", Origin::reader};
    }
    std::vector<fs::path> available;
    // A range-for's implicit operator++ throws on an OS error advancing the scan;
    // only increment(error_code&) does not. Walk it by hand so a bad entry (an
    // unreadable directory, a broken symlink) reports through Result instead.
    std::error_code scan;
    fs::directory_iterator it(dir, scan);
    fs::directory_iterator end;
    while (!scan && it != end) {
        if (it->path().extension() == ".exp") available.push_back(it->path());
        it.increment(scan);
    }
    if (scan) return Error{"schema " + *schema + ": " + scan.message(), Origin::reader};
    std::sort(available.begin(), available.end());
    if (available.empty()) return Error{"no .exp schemas in " + *schema, Origin::reader};
    auto plain = [](const std::string& name) {
        std::string out;
        for (char c : name) {
            if (std::isalnum(static_cast<unsigned char>(c))) out += static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
        }
        return out;
    };
    CADACLYSM_TRY(declared_text, declared_schema(model));
    std::string declared = plain(declared_text);
    const fs::path* best = nullptr;
    std::size_t best_length = 0;
    for (const fs::path& exp : available) {
        std::string stem = plain(detail::utf8(exp.stem()));
        bool matches = !declared.empty() && (declared.rfind(stem, 0) == 0 || stem.rfind(declared, 0) == 0);
        if (matches && (!best || stem.size() > best_length)) {  // the most specific match wins
            best = &exp;
            best_length = stem.size();
        }
    }
    if (best) return SchemaChoice{detail::utf8(*best), {}};
    SchemaChoice choice;
    for (const fs::path& exp : available) choice.fallbacks.push_back(detail::utf8(exp));
    return choice;
}

// ---- opening --------------------------------------------------------------------------

namespace detail {
inline void fill_options(CadaclysmOpenOptions& raw, const OpenOptions& options) {
    ::cadaclysm_open_options_init(&raw);
    raw.convention = options.convention & ~(FILE_UNITS | UV_WORLD);
    raw.file_units = (options.convention & FILE_UNITS) != 0;
    raw.uvs = (options.convention & UV_WORLD) ? CADACLYSM_UV_WORLD_SCALE : CADACLYSM_UV_NONE;
    raw.colors = options.colors ? CADACLYSM_COLORS_PER_FACE : CADACLYSM_COLORS_NONE;
    raw.source_meters_per_unit = options.source_metres_per_unit;
}

inline Result<void> check_schema(const OpenOptions& options) {
    std::error_code ignored;
    if (options.schema && !std::filesystem::exists(fs_path(*options.schema), ignored)) {
        return Error{"schema " + *options.schema + " is neither a file nor a directory", Origin::reader};
    }
    return {};
}
}  // namespace detail

// Open a CAD file. The library converts into `options.convention` on the way out.
inline Result<Scene> open(const std::string& path, const OpenOptions& options) {
    std::error_code ignored;
    if (!std::filesystem::exists(detail::fs_path(path), ignored)) {
        return Error{path + ": no such file", Origin::reader};
    }
    CADACLYSM_TRY_VOID(detail::check_schema(options));
    CadaclysmOpenOptions raw;
    detail::fill_options(raw, options);
    const char* schemas[1] = {options.schema ? options.schema->c_str() : nullptr};
    if (options.schema) {
        raw.schemas = schemas;
        raw.schema_count = 1;
    }
    CadaclysmScene* handle = ::cadaclysm_open(path.c_str(), &raw);
    if (!handle) return detail::named_error(detail::file_name(path));
    auto state = std::make_shared<detail::SceneState>();
    state->handle = handle;
    state->path = path;
    state->schema_path = options.schema;
    state->convention = options.convention;
    return Scene(std::move(state));
}

// Open a CAD file already in memory. `format` names the kind as an extension would:
// "step", "ifc", "igs", "brep", "3dm", "scad" (a leading dot is ignored).
inline Result<Scene> open_memory(const void* data, std::size_t size, const std::string& format,
                                 const OpenOptions& options) {
    CADACLYSM_TRY_VOID(detail::check_schema(options));
    CadaclysmOpenOptions raw;
    detail::fill_options(raw, options);
    const char* schemas[1] = {options.schema ? options.schema->c_str() : nullptr};
    if (options.schema) {
        raw.schemas = schemas;
        raw.schema_count = 1;
    }
    CadaclysmScene* handle =
        ::cadaclysm_open_memory(static_cast<const std::uint8_t*>(data), size, format.c_str(), &raw);
    if (!handle) return detail::named_error(options.name);
    auto state = std::make_shared<detail::SceneState>();
    state->handle = handle;
    state->path = options.name;
    state->schema_path = options.schema;
    state->convention = options.convention;
    return Scene(std::move(state));
}

}  // namespace CADACLYSM_ABI
}  // namespace cadaclysm

#endif  // CADACLYSM_HPP
