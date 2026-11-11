// view.hpp -- draw through a view library (cadaclysm_view.h), opened at run time: the
// terminal (cadaclysm_terminal) by default, the GPU window (cadaclysm_view, on wgpu) after
// view::use_wgpu(), any other with view::use(path). Python's cadaclysm.view, in C++: View,
// Item, the library choice, pump, text (show_text, set_text, load_font), and show()/view()
// on Solid, Scene, Node and Pose.
//
// Header-only; nothing of the view is linked. CMake: link cadaclysm::view_loader (the
// include directories, the library directory compiled in as CADACLYSM_VIEW_LIBRARY_DIR,
// dlopen) and cadaclysm::blacksmith (this header includes cadaclysm_blacksmith.hpp).
// cadaclysm::view is the linked C library instead, for hosts calling cadaclysm_view.h
// directly. On Windows this header includes <windows.h>, through view_loader.h, with
// WIN32_LEAN_AND_MEAN and NOMINMAX (wingdi's macros, ERROR among them, remain).
//
// Every call that can fail returns a Result (Origin::view); nothing throws. A View belongs
// to the thread that made it (on macOS the main thread): another thread's call is refused.
// Lifetimes: an item of a Solid or a Scene keeps it alive, and Scene::close() first removes
// the items of this thread's views that show it; an item of a Node borrows from the Node's
// Scene, as everything in cadaclysm.hpp does -- keep the Scene while it is shown. show() and
// view() draw in a view of their own that Scene::close() does not see while they run: do not
// close the Scene they draw (a Node's or a Pose's included) from another thread meanwhile.
//
// show() flushes C stdio (fflush(NULL)) before a terminal still; std::cout shares that
// buffer unless std::ios::sync_with_stdio(false), which needs its own std::cout.flush().
// view_loader.h's functions are static inline (CVL_API), called from this header's inline
// functions: each translation unit has its own copies, which is harmless (they keep no state).
#ifndef CADACLYSM_VIEW_HPP
#define CADACLYSM_VIEW_HPP

#include "cadaclysm_blacksmith.hpp"
#include "view_loader.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <fstream>
#include <iterator>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

#ifndef CADACLYSM_VIEW_LIBRARY_DIR
#define CADACLYSM_VIEW_LIBRARY_DIR ""
#endif

// The level-of-detail struct as the library reads it: three u32, 12 bytes.
static_assert(sizeof(CadaclysmViewLod) == 12, "CadaclysmViewLod is size, min_triangles, motion: 12 bytes");
static_assert(offsetof(CadaclysmViewLod, min_triangles) == 4 && offsetof(CadaclysmViewLod, motion) == 8,
              "CadaclysmViewLod's fields are at 0, 4 and 8");
// The pick answer as 1.8 writes it: size, item, node, face, clicks, has_point, point[3].
static_assert(sizeof(CadaclysmViewPick) == 36, "CadaclysmViewPick (1.8) is 36 bytes");
static_assert(offsetof(CadaclysmViewPick, clicks) == 16 && offsetof(CadaclysmViewPick, has_point) == 20 &&
                  offsetof(CadaclysmViewPick, point) == 24,
              "CadaclysmViewPick's 1.8 fields are at 16, 20 and 24");
// The snap structs as 1.22 reads and writes them: settings size, kinds, aperture_px, marker
// (16 bytes); the answer size, kind, point[3] (doubles), item, node, face, edge, tangent[3],
// axis[3], radius, distance_px, clicks (88 bytes).
static_assert(sizeof(CadaclysmViewSnapSettings) == 16 && offsetof(CadaclysmViewSnapSettings, aperture_px) == 8 &&
                  offsetof(CadaclysmViewSnapSettings, marker) == 12,
              "CadaclysmViewSnapSettings (1.22) is 16 bytes, aperture_px at 8, marker at 12");
static_assert(sizeof(CadaclysmViewSnap) == 88 && offsetof(CadaclysmViewSnap, point) == 8 &&
                  offsetof(CadaclysmViewSnap, item) == 32 && offsetof(CadaclysmViewSnap, tangent) == 48 &&
                  offsetof(CadaclysmViewSnap, radius) == 72 && offsetof(CadaclysmViewSnap, clicks) == 84,
              "CadaclysmViewSnap (1.22) is 88 bytes, point at 8, item at 32, tangent at 48, radius at 72, clicks at 84");

namespace cadaclysm {
inline namespace CADACLYSM_ABI {

// How a View is made: its own window's title and size (0: the library's), the surfaces
// (exact or triangles), and Y up.
struct ViewOptions {
    std::string title;
    std::uint32_t width = 0, height = 0;
    bool triangles = false;
    bool y_up = false;
};

// show()/view()'s keywords, as Python's: view (front, back, left, right, top, bottom, iso;
// "" the object's default, iso), azimuth/elevation over it, zoom (a multiple of the fit; 0
// the fit), up ("y" or "z"; unset: the scene's own up axis, "z" for a solid), edges, the
// window's size (0: the library's), hint (the terminal's graphics protocol for this draw),
// title ("": the scene's file name, "Solid" for a solid), and a solid's tolerance (unset:
// 0.05; refused for a Scene, Node or Pose, which is drawn at the tolerance it was read with).
struct ShowOptions {
    std::string view;
    std::optional<double> azimuth, elevation;
    double zoom = 0.0;
    std::optional<std::string> up;
    bool edges = true;
    std::uint32_t width = 0, height = 0;
    std::string hint;
    std::string title;
    std::optional<double> tolerance;
};

// What a pick found: the item, the scene node (or the solid's 0) and the face; `clicks` 2
// for a double click's pick, else 1; `point` where the ray met the model, in the coordinates
// the items were shown in -- std::nullopt where the library read no depth (no hit, a
// machining stock, the terminal library).
struct ViewPick {
    std::uint32_t item = 0, node = 0, face = 0;
    std::uint32_t clicks = 0;
    std::optional<std::array<float, 3>> point;
};

// What a snap found, as Python's Snap: its kind ("vertex", "midpoint", "centre", "quadrant",
// "edge", "face", "grid" or "plane"; "" where nothing in the kinds set_snap chose lay within
// the aperture, or snapping is off), the point snapped to, in world coordinates, the item,
// node and face it lies on, its edge (std::nullopt for a face, grid or plane snap), the
// edge's unit tangent there, a circular edge's axis and radius (zeros otherwise), how many
// pixels the cursor was from it, and `clicks`: 0 for snap() and a hover, 1 for a click's
// snap, 2 for a double click's.
struct ViewSnap {
    std::string kind;
    std::array<double, 3> point{};
    std::uint32_t item = 0, node = 0, face = 0;
    std::optional<std::uint32_t> edge;
    std::array<float, 3> tangent{}, axis{};
    double radius = 0.0;
    float distance_px = 0.0f;
    std::uint32_t clicks = 0;
};

// How a left drag moves the camera: about the target (orbit) or turning about the eye (fly).
// A fly key (W, A, S, D, E, Q) through View::input enters fly mode and it stays after the key
// is let go; Tab toggles it; frame(), standard() and focus() leave it.
enum class Navigation : std::uint32_t { orbit = CADACLYSM_VIEW_NAVIGATION_ORBIT, fly = CADACLYSM_VIEW_NAVIGATION_FLY };

namespace detail {
// A library's pick answer as a ViewPick.
inline ViewPick pick_of(const CadaclysmViewPick& raw) {
    ViewPick p;
    p.item = raw.item;
    p.node = raw.node;
    p.face = raw.face;
    p.clicks = raw.clicks;
    if (raw.has_point) p.point = std::array<float, 3>{raw.point[0], raw.point[1], raw.point[2]};
    return p;
}
// The CADACLYSM_VIEW_SNAP_* kinds by the names set_snap takes and ViewSnap::kind reports.
struct SnapKindName {
    const char* name;
    std::uint32_t bit;
};
inline constexpr SnapKindName snap_kinds[] = {
    {"vertex", CADACLYSM_VIEW_SNAP_VERTEX}, {"midpoint", CADACLYSM_VIEW_SNAP_MIDPOINT},
    {"centre", CADACLYSM_VIEW_SNAP_CENTRE}, {"quadrant", CADACLYSM_VIEW_SNAP_QUADRANT},
    {"edge", CADACLYSM_VIEW_SNAP_EDGE},     {"face", CADACLYSM_VIEW_SNAP_FACE},
    {"grid", CADACLYSM_VIEW_SNAP_GRID},     {"plane", CADACLYSM_VIEW_SNAP_PLANE},
};
// A library's snap answer as a ViewSnap.
inline ViewSnap snap_of(const CadaclysmViewSnap& raw) {
    ViewSnap s;
    if (raw.kind) {
        s.kind = std::to_string(raw.kind);
        for (const SnapKindName& k : snap_kinds)
            if (k.bit == raw.kind) s.kind = k.name;
    }
    s.point = {raw.point[0], raw.point[1], raw.point[2]};
    s.item = raw.item;
    s.node = raw.node;
    s.face = raw.face;
    if (raw.edge != 0xFFFFFFFFu) s.edge = raw.edge;
    s.tangent = {raw.tangent[0], raw.tangent[1], raw.tangent[2]};
    s.axis = {raw.axis[0], raw.axis[1], raw.axis[2]};
    s.radius = raw.radius;
    s.distance_px = raw.distance_px;
    s.clicks = raw.clicks;
    return s;
}
}  // namespace detail

// Where run()/view() left the camera (azimuth and elevation as ShowOptions takes them), and
// what was last clicked.
struct Camera {
    std::array<float, 3> eye{}, target{}, up{};
    bool orthographic = false;
    double azimuth = 0.0, elevation = 0.0;
    std::optional<ViewPick> pick;
};

// RGBA8, rows from the top.
struct ViewImage {
    std::uint32_t width = 0, height = 0;
    std::vector<std::uint8_t> rgba;
};

// One pane of View::viewports: its rectangle (x, y, width, height in pixels), its camera's
// column-major view and projection, the eye, and a CADACLYSM_VIEW_GRID_* grid.
struct Viewport {
    std::array<std::uint32_t, 4> rect{};
    std::array<float, 16> view{}, projection{};
    std::array<float, 3> eye{};
    std::uint32_t grid = 0;
};

// A host's event, as CadaclysmViewEvent's fields (kind: CADACLYSM_VIEW_EVENT_*).
struct ViewEvent {
    std::uint32_t kind = 0, pointer_id = 0, pointer = 0, button = 0;
    bool shift = false;
    float x = 0, y = 0, wheel_y = 0;
    std::string key;
    bool key_down = true;
    double time_ms = 0;
};

// A host's native window: CADACLYSM_VIEW_WINDOW_* kind, the handle, an X11/XCB id, the
// display, and its client size in physical pixels.
struct ViewWindow {
    std::uint32_t kind = 0;
    void* handle = nullptr;
    std::uint64_t id = 0;
    void* display = nullptr;
    std::uint32_t width = 0, height = 0;
};

// A colour, as every colour argument takes it (Python's Colour): three numbers in 0..1 --
// {r, g, b} or a std::array<float, 3> -- four where a call takes an alpha, or text: "#rgb",
// "#rrggbb" (the "#" optional) or one of the 148 CSS colour names, any case, read by the
// view library's own cadaclysm_view_parse_colour when the colour is used, so the forms are
// those of every wrapper. Text (or three numbers) where an alpha is taken means an alpha of
// 1; text the library refuses is refused with its message.
class Colour {
public:
    Colour(float r, float g, float b) : values_{r, g, b, 1.0f} {}
    Colour(float r, float g, float b, float a) : values_{r, g, b, a} {}
    Colour(const std::array<float, 3>& rgb) : values_{rgb[0], rgb[1], rgb[2], 1.0f} {}
    Colour(const std::array<float, 4>& rgba) : values_{rgba[0], rgba[1], rgba[2], rgba[3]} {}
    Colour(std::string_view text) : text_(text), is_text_(true) {}
    Colour(const std::string& text) : text_(text), is_text_(true) {}
    Colour(const char* text) : text_(text ? text : ""), is_text_(true) {}
    // No colour is std::nullopt (or the argument left out), not a null pointer.
    Colour(std::nullptr_t) = delete;

    bool is_text() const noexcept { return is_text_; }
    // The text as given ("" for numbers).
    const std::string& text() const noexcept { return text_; }
    // The numbers as given, the alpha 1 where there were three ({0, 0, 0, 1} for text).
    const std::array<float, 4>& numbers() const noexcept { return values_; }

private:
    std::array<float, 4> values_{0.0f, 0.0f, 0.0f, 1.0f};
    std::string text_;
    bool is_text_ = false;
};

// show_text's keywords, as Python's: mode "label" (a screen label: `size` its height in
// pixels, facing the viewer, placed by `align` -- which corner or edge of the text sits on
// the point -- and nudged by `offset` pixels, right and up) or "world" (a quad in the scene:
// `size` the height in model units, laid along `right` and `up`, unset: x and y). `colour`
// is the glyphs' (an alpha is not drawn); `box`, `padding` and `on_top` are a label's alone:
// `box` an optional backing rectangle (alpha 1 unless four numbers say otherwise) `padding`
// pixels larger than the text, `on_top` drawing the label even where its point is hidden.
// `font` is a view::load_font id (0 the bundled font). align: top-left, top, top-right,
// left, centre (or center), right, bottom-left, bottom, bottom-right.
struct TextOptions {
    std::string mode = "label";
    float size = 12.0f;
    Colour colour = "white";
    std::string align = "bottom-left";
    std::array<float, 2> offset{};
    std::optional<Colour> box;
    float padding = 4.0f;
    bool on_top = false;
    std::uint32_t font = 0;
    std::optional<std::array<float, 3>> right, up;
};

// How View::show draws a solid (view ABI 1.21): `material` "default", "plastic", "metal",
// "matte", "paint", "brushed" or "glass" (empty: default); `opacity` 0..1 (1 opaque); `faces`
// the solid's face numbers to show alone, with no edges -- a trim's ghost (none: every face).
// The item's faces are numbered as the solid numbers them, `faces` or not.
struct SolidOptions {
    std::string material;
    std::optional<float> opacity;
    std::optional<std::vector<std::uint32_t>> faces;
};

// A loaded view library. Never unloaded.
class ViewLibrary {
public:
    // cadaclysm_view_name(): "cadaclysm-view <version>", "cadaclysm-terminal <version>", ...
    const std::string& name() const noexcept { return name_; }
    const std::string& path() const noexcept { return path_; }
    bool terminal() const noexcept { return cvl_is_terminal(&table_) != 0; }
    bool wgpu() const noexcept { return cvl_is_wgpu(&table_) != 0; }

private:
    friend struct detail::ViewAccess;
    CvlTable table_{};
    std::string name_, path_;
};

namespace detail {

inline Error view_error(std::string message) { return Error{std::move(message), Origin::view}; }

// What an item shows: the object it keeps alive (a Solid's or a Scene's state; none for a
// Node, which borrows), and the scene it reads in place (for Scene::close's release).
struct ViewShown {
    std::shared_ptr<const void> owner;
    const void* scene = nullptr;
};

struct ViewState;

// The loaded libraries and every live view of every thread. `views` and what each view's
// `handle`, `closed` and `shown` say are read across threads under `views_mutex`; only the
// view's own thread writes them, under it too.
struct ViewRegistry {
    std::mutex mutex;  // the libraries
    std::map<std::string, std::unique_ptr<ViewLibrary>> loaded;
    const ViewLibrary* current = nullptr;
    std::mutex views_mutex;
    std::vector<ViewState*> views;
};
// Immortal: a View, an Item's state or a Scene in static storage may be destroyed after any
// function-local static, and each comes back here (and to a loaded library's table).
inline ViewRegistry& view_registry() {
    static ViewRegistry* registry = new ViewRegistry;
    return *registry;
}

// False once this thread's thread_local destructors have run (a thread's end, or exit():
// on glibc they run before any static's destructor). The view libraries keep thread-local
// state (Rust's), so no view call may be made after that. View::make arms it.
struct ThreadAlive {
    bool* alive;
    ~ThreadAlive() { *alive = false; }
};
inline bool thread_alive() {
    thread_local bool alive = true;  // trivial: still readable after the destructors
    thread_local ThreadAlive sentinel{&alive};
    static_cast<void>(sentinel);
    return alive;
}

struct ViewState {
    const ViewLibrary* library = nullptr;
    const CvlTable* t = nullptr;
    CadaclysmView* handle = nullptr;
    std::thread::id thread = std::this_thread::get_id();
    bool own = false;     // a window of its own
    bool pumped = false;  // a window of its own on the wgpu library: view::pump reaches it
    bool closed = false;  // that window was closed (its button, Escape, the end of run)
    bool y_up = false;
    int drawn = 0;  // drawn once: pick draws a never-drawn view first
    std::map<std::uint32_t, ViewShown> shown;

    ViewState() = default;
    ViewState(const ViewState&) = delete;
    ViewState& operator=(const ViewState&) = delete;
    ~ViewState() {
        {
            ViewRegistry& r = view_registry();
            std::lock_guard<std::mutex> lock(r.views_mutex);
            r.views.erase(std::remove(r.views.begin(), r.views.end(), this), r.views.end());
        }
        // Another thread's view cannot be destroyed from here: it is left, as Python's
        // __del__ leaves it -- and so is what its items keep, which it may still read (leak
        // rather than crash). So is one destroyed after this thread's thread_locals (a View in
        // static storage at exit): the view library's own thread-local state is gone by then,
        // and calling it would abort the process.
        if (thread == std::this_thread::get_id() && thread_alive()) destroy();
        else if (handle && !shown.empty()) static_cast<void>(new std::map<std::uint32_t, ViewShown>(std::move(shown)));
    }
    void enlist() {
        ViewRegistry& r = view_registry();
        std::lock_guard<std::mutex> lock(r.views_mutex);
        r.views.push_back(this);
    }
    void mark_closed() {
        std::lock_guard<std::mutex> lock(view_registry().views_mutex);
        closed = true;
    }
    bool gone() const {
        std::lock_guard<std::mutex> lock(view_registry().views_mutex);
        return !handle || closed;
    }
    // The C view first, then what the items kept (C11).
    void destroy() noexcept {
        CadaclysmView* h = nullptr;
        std::map<std::uint32_t, ViewShown> dropped;
        {
            std::lock_guard<std::mutex> lock(view_registry().views_mutex);
            h = handle;
            handle = nullptr;
            dropped.swap(shown);
        }
        if (h) t->destroy(h);
    }
    // What item `id` keeps; a value it replaces dies after the unlock (as in forget).
    void keep(std::uint32_t id, ViewShown what) {
        std::lock_guard<std::mutex> lock(view_registry().views_mutex);
        std::swap(shown[id], what);
        // `what` (now the old value) is a parameter: it dies after `lock`.
    }
    // Drops what item `id` kept, outside the lock: the last reference to a scene closes it,
    // and its close comes back here for the lock.
    void forget(std::uint32_t id) {
        std::shared_ptr<const void> dropped;
        std::lock_guard<std::mutex> lock(view_registry().views_mutex);
        auto it = shown.find(id);
        if (it == shown.end()) return;
        dropped = std::move(it->second.owner);
        shown.erase(it);
        // `dropped` is declared before `lock`, so it dies after the unlock.
    }
};

// Python's _call: another thread's view, a closed view, a closed window, each refused with
// the C call's name.
inline std::optional<Error> refusal(const ViewState* s, const char* call) {
    if (s && s->thread != std::this_thread::get_id())
        return view_error(std::string(call) + ": a view belongs to the thread that made it");
    if (!s || !s->handle) return view_error(std::string(call) + ": the view is closed");
    if (s->closed) return view_error(std::string(call) + ": the window is closed");
    return std::nullopt;
}

inline Error library_error(const ViewState& s) { return view_error(cvl_error(s.t)); }

// A colour argument as the library takes it: four floats (r, g, b, a; a C call reading three
// reads the first three), or NULL where none was given.
struct Paint {
    std::array<float, 4> values{};
    bool given = false;
    const float* data() const noexcept { return given ? values.data() : nullptr; }
};

// Python's _colour: text through the library's cadaclysm_view_parse_colour (alpha 1), refused
// with the library's message, else Python's "colour '<text>'"; numbers as given.
inline Result<Paint> paint(const CvlTable& t, const std::optional<Colour>& c) {
    Paint p;
    if (!c) return p;
    p.given = true;
    p.values = c->numbers();
    if (!c->is_text()) return p;
    float rgb[3] = {0.0f, 0.0f, 0.0f};
    if (!t.parse_colour(c->text().c_str(), rgb)) {
        const char* said = t.last_error();
        return view_error(said && said[0] ? std::string(said) : "colour '" + c->text() + "'");
    }
    p.values = {rgb[0], rgb[1], rgb[2], 1.0f};
    return p;
}

// The colour of `call` on view `s`: its refusal first (another thread, a closed view or
// window), then the colour's.
inline Result<Paint> paint_for(const ViewState* s, const char* call, const std::optional<Colour>& c) {
    if (auto no = refusal(s, call)) return *no;
    return paint(*s->t, c);
}

// A non-NULL pointer for an empty array (count 0): NULL means "none" to the library.
template <class T>
inline const T stand_in[1] = {};
template <class T>
const T* non_null(const std::vector<T>& v) {
    return v.empty() ? stand_in<T> : v.data();
}

inline Result<std::uint32_t> count_of(std::size_t n, const char* what) {
    if constexpr (sizeof(std::size_t) > 4) {
        if (n > 0xFFFFFFFFu)
            return view_error(std::string(what) + ": " + std::to_string(n) + " is too many for the library");
    }
    return static_cast<std::uint32_t>(n);
}

// `s` as Python's repr writes a str in a message: in single quotes (double where it holds a
// single quote and no double one), backslash, the quote, \n, \r and \t escaped, any other
// control character as \xNN.
inline std::string quoted(std::string_view s) {
    char q = s.find('\'') != std::string_view::npos && s.find('"') == std::string_view::npos ? '"' : '\'';
    std::string out(1, q);
    for (char c : s) {
        unsigned char u = static_cast<unsigned char>(c);
        if (c == '\\' || c == q) {
            out += '\\';
            out += c;
        } else if (c == '\n') {
            out += "\\n";
        } else if (c == '\r') {
            out += "\\r";
        } else if (c == '\t') {
            out += "\\t";
        } else if (u < 0x20 || u == 0x7f) {
            const char* hex = "0123456789abcdef";
            out += "\\x";
            out += hex[u >> 4];
            out += hex[u & 15];
        } else {
            out += c;
        }
    }
    out += q;
    return out;
}

// The text show_text and set_text pass as a C string: a NUL would end it there, silently --
// refused instead, in Python's words.
inline Result<std::string> text_of(std::string_view text) {
    if (text.find('\0') != std::string_view::npos)
        return view_error("text " + quoted(text) + ": a NUL character cannot be shown (the C string ends there)");
    return std::string(text);
}

// width x height RGBA8 in bytes, checked: no product may wrap.
inline Result<std::uint64_t> pixel_bytes(std::uint32_t width, std::uint32_t height, const char* what) {
    std::uint64_t pixels = static_cast<std::uint64_t>(width) * height;  // < 2^64
    if (pixels > (std::numeric_limits<std::size_t>::max)() / 4u)
        return view_error(std::string(what) + ": " + std::to_string(width) + " x " + std::to_string(height) +
                          " pixels is too large");
    return pixels * 4u;
}

inline std::vector<std::string> view_dirs() {
    std::vector<std::string> dirs;
    if (CADACLYSM_VIEW_LIBRARY_DIR[0]) dirs.emplace_back(CADACLYSM_VIEW_LIBRARY_DIR);
    return dirs;
}

// " -- draw without a display ...": appended to a create failure that says "no display".
inline constexpr const char* view_no_display =
    " -- draw without a display with View::offscreen, or the terminal (cadaclysm::view::use_terminal())";

struct ViewAccess {
    static const CvlTable& table(const ViewLibrary& l) { return l.table_; }

    // cvl_find, for the wrapper's own test of the refusal.
    static Result<std::string> find(const char* stem, const char* variable, const char* what,
                                    const std::vector<std::string>& dirs) {
        std::vector<const char*> c;
        for (const std::string& d : dirs) c.push_back(d.c_str());
        std::vector<char> out(CVL_PATH, 0), err(CVL_ERROR, 0);
        if (!cvl_find(stem, variable, what, c.data(), c.size(), out.data(), out.size(), err.data(), err.size()))
            return view_error(err.data());
        return std::string(out.data());
    }

    // `which` "terminal", "wgpu", a path; nullptr: the default. Remembered when `remember`.
    static Result<const ViewLibrary*> choose(const char* which, bool remember) {
        ViewRegistry& r = view_registry();
        std::lock_guard<std::mutex> lock(r.mutex);
        if (!which && r.current) return r.current;
        std::vector<std::string> dirs = view_dirs();
        std::vector<const char*> c;
        for (const std::string& d : dirs) c.push_back(d.c_str());
        auto library = std::make_unique<ViewLibrary>();
        std::vector<char> err(CVL_ERROR, 0);
        int ok = which ? cvl_use(&library->table_, which, c.data(), c.size(), err.data(), err.size())
                       : cvl_default(&library->table_, c.data(), c.size(), err.data(), err.size());
        if (!ok) return view_error(err.data());
        std::string key = library->table_.path;
        auto found = r.loaded.find(key);
        if (found == r.loaded.end()) {
            library->name_ = library->table_.label;
            library->path_ = key;
            found = r.loaded.emplace(key, std::move(library)).first;
        }
        if (remember || !r.current) r.current = found->second.get();
        return found->second.get();
    }

    static const CadaclysmBlacksmithSolid* handle(const blacksmith::Solid& s) { return s.handle(); }
    // What an item of `s` keeps alive; a test reads it through a weak_ptr.
    static std::shared_ptr<const void> keep(const blacksmith::Solid& s) { return s.state_; }
    static CadaclysmScene* handle(const Scene& s) { return s.h("View"); }
    static std::shared_ptr<const void> keep(const Scene& s) { return s.state_; }
    static const void* identity(const Scene& s) { return s.state_.get(); }
    static std::uint32_t convention(const Scene& s) { return s.convention(); }
    // Python's refusal of a closed scene: "<file name>: the scene is closed".
    static Error closed(const Scene& s) {
        return view_error(s.state_ ? file_name(s.state_->path) + ": the scene is closed" : "the scene is closed");
    }
    static std::string title(const Scene& s) { return file_name(s.path()); }

    static const CadaclysmScene* handle(const Node& n) { return n.h(); }
    static const void* identity(const Node& n) { return n.scene_.identity(); }
    static std::uint32_t convention(const Node& n) { return Access::convention(n); }
    static std::string title(const Node& n) { return file_name(n.scene_.get("Node").path); }

    static const CadaclysmScene* handle(const Link& l) { return l.h(); }
    static std::uint32_t convention(const Link& l) { return l.scene_.get("Pose").convention; }
    static std::string title(const Link& l) { return file_name(l.scene_.get("Pose").path); }

    // Node focus, as Python's _show_node: the siblings along the path from the node's root
    // down to the node -- every other root, then every other child at each level. Nothing
    // on the path is hidden, so nothing has to be shown again.
    static std::vector<std::uint32_t> siblings_along_path(const Node& node) {
        std::vector<std::uint32_t> path{node.index()};  // the node .. its root
        for (std::optional<Node> up = node.parent(); up; up = up->parent()) path.push_back(up->index());
        const CadaclysmScene* scene = node.h();
        std::vector<std::uint32_t> hide;
        std::uint32_t roots = ::cadaclysm_root_count(scene);
        for (std::uint32_t i = 0; i < roots; ++i) {
            std::uint32_t r = ::cadaclysm_root(scene, i);
            if (r != path.back() && r != NONE) hide.push_back(r);
        }
        for (std::size_t level = path.size() - 1; level > 0; --level) {
            std::uint32_t parent = path[level], on_path = path[level - 1];
            std::uint32_t count = ::cadaclysm_node_child_count(scene, parent);
            for (std::uint32_t i = 0; i < count; ++i) {
                std::uint32_t child = ::cadaclysm_node_child(scene, parent, i);
                if (child != on_path && child != NONE) hide.push_back(child);
            }
        }
        return hide;
    }

    // Scene::close's hook (detail::release_shown): the items of this thread's views that
    // show `scene` are removed -- a view whose window the user closed is destroyed, the
    // destroy it owed anyway -- and false when a view of another thread still shows it.
    static bool release(const void* scene) noexcept {
        // After this thread's thread_locals (a Scene in static storage at exit) no view may be
        // called: a scene a view still shows then stays open.
        if (!thread_alive()) {
            std::lock_guard<std::mutex> lock(view_registry().views_mutex);
            for (ViewState* v : view_registry().views)
                if (v->handle)
                    for (const auto& entry : v->shown)
                        if (entry.second.scene == scene) return false;
            return true;
        }
        std::thread::id me = std::this_thread::get_id();
        std::vector<std::pair<ViewState*, std::vector<std::uint32_t>>> mine;
        std::size_t foreign = 0;
        {
            ViewRegistry& r = view_registry();
            std::lock_guard<std::mutex> lock(r.views_mutex);
            for (ViewState* v : r.views) {
                if (!v->handle) continue;
                std::vector<std::uint32_t> ids;
                for (const auto& entry : v->shown)
                    if (entry.second.scene == scene) ids.push_back(entry.first);
                if (ids.empty()) continue;
                if (v->thread != me) ++foreign;
                else mine.emplace_back(v, std::move(ids));
            }
        }
        for (auto& entry : mine) {
            ViewState* v = entry.first;
            if (v->closed) {
                v->destroy();
                continue;
            }
            for (std::uint32_t id : entry.second) {
                if (v->handle) v->t->remove(v->handle, id);
                v->forget(id);
            }
        }
        return foreign == 0;
    }
};

// Scene::close reaches the release through this, set before main.
inline const bool view_release_hooked = (release_shown = &ViewAccess::release, true);

}  // namespace detail

namespace view {
// Draw with the bundled terminal library from now on. Returns it.
inline Result<const ViewLibrary*> use_terminal() { return detail::ViewAccess::choose("terminal", true); }
// Draw with the GPU window (cadaclysm_view, on wgpu) from now on.
inline Result<const ViewLibrary*> use_wgpu() { return detail::ViewAccess::choose("wgpu", true); }
// Draw with "terminal", "wgpu" or the view library at `path` from now on.
inline Result<const ViewLibrary*> use(std::string_view which) {
    if (which.empty()) return detail::view_error("use: \"terminal\", \"wgpu\" or a path");
    std::string owned(which);
    return detail::ViewAccess::choose(owned.c_str(), true);
}
// The library in use: the last use_*; else CADACLYSM_VIEW ("terminal", "wgpu" or a file);
// else the terminal. A failure is not remembered.
inline Result<const ViewLibrary*> current() { return detail::ViewAccess::choose(nullptr, false); }
// A font for every view of the library in use, from TTF/OTF bytes (copied in); its id for
// TextOptions::font. 0 is the bundled font and needs no loading. Bytes that are no font
// are refused with the library's reason.
inline Result<std::uint32_t> load_font(const std::vector<std::uint8_t>& bytes) {
    auto lib = current();
    if (!lib) return lib.error();
    const CvlTable& t = detail::ViewAccess::table(**lib);
    std::uint32_t id = t.load_font(detail::non_null(bytes), bytes.size());
    if (!id) return detail::view_error(cvl_error(&t));
    return id;
}
// load_font from the file at `path`; a file that cannot be read is refused naming it.
inline Result<std::uint32_t> load_font(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return detail::view_error(path + ": the font could not be read");
    std::vector<std::uint8_t> bytes{std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
    return load_font(bytes);
}
inline Result<std::uint32_t> load_font(const char* path) {
    if (!path) return detail::view_error("load_font: a font path, not null");
    return load_font(std::string(path));
}
// Handles the events of every open window of this thread's own (on the wgpu library),
// draws what is owed, waits at most `seconds` (negative: none); the number of such windows
// of every thread still open -- for a program's own loop. With none of this thread's own it
// just waits `seconds`, so a loop around it does not spin. A window whose pump failed stays
// open; every window is pumped before the first failure is returned.
inline Result<std::uint32_t> pump(double seconds = 0.0);
}  // namespace view

class View;

// One thing shown in a View. Copyable; it refers to its view, which it does not keep alive.
class Item {
public:
    std::uint32_t id() const noexcept { return id_; }

    Result<void> remove() {
        auto s = view_.lock();
        if (auto no = detail::refusal(s.get(), "cadaclysm_view_remove")) return *no;
        if (!s->t->remove(s->handle, id_)) return detail::library_error(*s);
        s->forget(id_);
        return {};
    }
    // Recolours the item in place: three numbers or text (see Colour).
    Result<void> colour(const Colour& rgb) {
        return ok_paint("cadaclysm_view_set_colour", rgb,
                        [&](detail::ViewState& s, const float* c) { return s.t->set_colour(s.handle, id_, c); });
    }
    // A column-major 4x4; std::nullopt takes it back.
    Result<void> placement(const std::optional<std::array<double, 16>>& m) {
        return ok("cadaclysm_view_set_placement",
                  [&](detail::ViewState& s) { return s.t->set_placement(s.handle, id_, m ? m->data() : nullptr); });
    }
    // `faces` (pick numbers) in `rgba`, one colour a face (see Colour; the alpha is not
    // drawn); both empty: every face's own colour.
    Result<void> face_colours(const std::vector<std::uint32_t>& faces, const std::vector<Colour>& rgba) {
        if (faces.size() != rgba.size())
            return detail::view_error(std::to_string(4 * static_cast<std::uint64_t>(faces.size())) +
                                      " numbers (rgba, 4 a face), not " +
                                      std::to_string(4 * static_cast<std::uint64_t>(rgba.size())));
        auto n = detail::count_of(faces.size(), "face_colours");
        if (!n) return n.error();
        auto s = view_.lock();
        if (auto no = detail::refusal(s.get(), "cadaclysm_view_set_face_colours")) return *no;
        std::vector<float> flat;
        flat.reserve(rgba.size() * 4);
        for (const Colour& c : rgba) {
            auto p = detail::paint(*s->t, c);
            if (!p) return p.error();
            flat.insert(flat.end(), p->values.begin(), p->values.end());
        }
        if (!s->t->set_face_colours(s->handle, id_, detail::non_null(faces), detail::non_null(flat), *n))
            return detail::library_error(*s);
        return {};
    }
    // Numbers only, as before Colour: a std::array<float, 4> (or 3, alpha 1) a face.
    template <std::size_t N>
    Result<void> face_colours(const std::vector<std::uint32_t>& faces, const std::vector<std::array<float, N>>& rgba) {
        return face_colours(faces, std::vector<Colour>(rgba.begin(), rgba.end()));
    }
    Result<void> frame() {
        return ok("cadaclysm_view_frame", [&](detail::ViewState& s) { return s.t->frame(s.handle, id_); });
    }
    // A text item's string replaced, nothing else changed; a NUL in it is refused.
    Result<void> set_text(std::string_view text) {
        auto shown = detail::text_of(text);
        if (!shown) return shown.error();
        return ok("cadaclysm_view_set_text", [&](detail::ViewState& s) { return s.t->set_text(s.handle, id_, shown->c_str()); });
    }
    Result<void> xray(bool on) {
        return ok("cadaclysm_view_set_xray", [&](detail::ViewState& s) { return s.t->set_xray(s.handle, id_, on); });
    }
    // How the item's lines and points draw where a surface hides them: "off" (not drawn, the
    // default), "solid" (drawn through) or "dashed" (dashed and dimmed).
    Result<void> occluded(std::string_view mode) {
        std::uint32_t m = 0;
        if (mode == "off") {
            m = CADACLYSM_VIEW_OCCLUDED_OFF;
        } else if (mode == "solid") {
            m = CADACLYSM_VIEW_OCCLUDED_SOLID;
        } else if (mode == "dashed") {
            m = CADACLYSM_VIEW_OCCLUDED_DASHED;
        } else {
            return detail::view_error("occluded: '" + std::string(mode) + "' is not 'off', 'solid' or 'dashed'");
        }
        return ok("cadaclysm_view_set_occluded", [&](detail::ViewState& s) { return s.t->set_occluded(s.handle, id_, m); });
    }
    // The item's finish: "gloss" (an item shows with this until it is set) -- under the
    // showroom lighting a clear coat mirroring the room, silver at a grazing angle -- "satin"
    // (a weaker, blurred coat) or "matte" (no mirror, a faint sheen: rubber, cloth). Uploads
    // the scene again, as a show does: set it as each item is shown rather than over a
    // finished scene item by item.
    Result<void> finish(std::string_view finish) {
        std::uint32_t f = 0;
        if (finish == "gloss") {
            f = CADACLYSM_VIEW_FINISH_GLOSS;
        } else if (finish == "satin") {
            f = CADACLYSM_VIEW_FINISH_SATIN;
        } else if (finish == "matte") {
            f = CADACLYSM_VIEW_FINISH_MATTE;
        } else {
            return detail::view_error("finish: '" + std::string(finish) + "' is not 'gloss', 'satin' or 'matte'");
        }
        return ok("cadaclysm_view_set_finish", [&](detail::ViewState& s) { return s.t->set_finish(s.handle, id_, f); });
    }
    Result<void> node_visible(std::uint32_t node, bool on) {
        return ok("cadaclysm_view_set_node_visible",
                  [&](detail::ViewState& s) { return s.t->set_node_visible(s.handle, id_, node, on); });
    }
    // Colours `node` and its subtree (see Colour; the alpha is not drawn); std::nullopt: the
    // node's own colour.
    Result<void> node_colour(std::uint32_t node, const std::optional<Colour>& rgba) {
        return ok_paint("cadaclysm_view_set_node_color", rgba, [&](detail::ViewState& s, const float* c) {
            return s.t->set_node_color(s.handle, id_, node, c);
        });
    }
    // Tint `node` toward rgba's colour by its alpha (text: alpha 1); std::nullopt clears.
    Result<void> node_highlight(std::uint32_t node, const std::optional<Colour>& rgba) {
        return ok_paint("cadaclysm_view_set_node_highlight", rgba, [&](detail::ViewState& s, const float* c) {
            return s.t->set_node_highlight(s.handle, id_, node, c);
        });
    }
    Result<void> frame_node(std::uint32_t node) {
        return ok("cadaclysm_view_frame_node", [&](detail::ViewState& s) { return s.t->frame_node(s.handle, id_, node); });
    }
    // Poses a shown scene: one column-major 4x4 per scene node, in index order (Pose's
    // `transforms`, Node::raw_transform's layout), drawn in place of each node's rest
    // transform; std::nullopt restores the rest pose. An empty list reaches the library,
    // which refuses it.
    Result<void> node_transforms(const std::optional<std::vector<std::array<double, 16>>>& transforms) {
        std::vector<double> flat;
        std::uint32_t count = 0;
        if (transforms) {
            auto n = detail::count_of(transforms->size(), "node_transforms");
            if (!n) return n.error();
            count = *n;
            flat.reserve(transforms->size() * 16);
            for (const auto& m : *transforms) flat.insert(flat.end(), m.begin(), m.end());
        }
        return ok("cadaclysm_view_set_node_transforms", [&](detail::ViewState& s) {
            return s.t->set_node_transforms(s.handle, id_, transforms ? detail::non_null(flat) : nullptr, count);
        });
    }

private:
    friend class View;
    Item(std::weak_ptr<detail::ViewState> view, std::uint32_t id) : view_(std::move(view)), id_(id) {}

protected:
    template <class F>
    Result<void> ok(const char* call, F&& f) {
        auto s = view_.lock();
        if (auto no = detail::refusal(s.get(), call)) return *no;
        if (!f(*s)) return detail::library_error(*s);
        return {};
    }
    // ok() with a colour: refused as `call` first, then the colour read (detail::paint).
    template <class F>
    Result<void> ok_paint(const char* call, const std::optional<Colour>& c, F&& f) {
        auto s = view_.lock();
        auto p = detail::paint_for(s.get(), call, c);
        if (!p) return p.error();
        if (!f(*s, p->data())) return detail::library_error(*s);
        return {};
    }
    std::weak_ptr<detail::ViewState> view_;
    std::uint32_t id_ = 0;
};

// A tool as the machining view takes it: shape "flat", "ball", "drill", "vbit" or "bullnose".
struct MachiningTool {
    std::uint32_t number = 0;
    std::string shape;
    double diameter = 0.0;
    double flute_length = 0.0;
    double angle = 0.0;          // a V-bit's
    double corner_radius = 0.0;  // a bull-nose's
};
struct MachiningProgram {
    MachiningTool tool;
    std::string gcode;
};
struct MachiningStock {
    std::array<double, 3> min{};
    std::array<double, 3> max{};
};
struct MachiningPart {
    std::vector<float> positions;       // three a vertex
    std::vector<std::uint32_t> indices; // three a triangle
};
// Absent: the library's own default.
struct MachiningOptions {
    std::optional<double> cell, tolerance, skin, rapid_rate;
};
struct MachiningInfo {
    std::uint32_t moves = 0, move = 0, nx = 0, ny = 0;
    float cell = 0.0f;
    std::array<float, 2> min{};
    double cycle_time = 0.0;
};

// A CAM job shown in a View (View::show_machining): the stock is this item, and the view's
// timeline plays it (View::play, seek, status). Every Item member works on it too.
class Machining : public Item {
public:
    // Jumps the timeline to the end of move `move` (0: the untouched stock).
    Result<void> seek_move(std::uint32_t move) {
        return ok("cadaclysm_view_machining_seek",
                  [&](detail::ViewState& s) { return s.t->machining_seek(s.handle, id_, move); });
    }
    // "height", "tool" or "deviation" (the last needs a part).
    Result<void> colour_by(std::string_view mode) {
        std::uint32_t m = 0;
        if (mode == "height") {
            m = CADACLYSM_VIEW_COLOUR_BY_HEIGHT;
        } else if (mode == "tool") {
            m = CADACLYSM_VIEW_COLOUR_BY_TOOL;
        } else if (mode == "deviation") {
            m = CADACLYSM_VIEW_COLOUR_BY_DEVIATION;
        } else {
            return detail::view_error("mode " + detail::quoted(mode) + ": one of height, tool, deviation");
        }
        return ok("cadaclysm_view_machining_colour_by",
                  [&](detail::ViewState& s) { return s.t->machining_colour_by(s.handle, id_, m); });
    }
    // The toolpath and the tool, on or off.
    Result<void> overlays(bool path = true, bool tool = true) {
        return ok("cadaclysm_view_machining_overlays",
                  [&](detail::ViewState& s) { return s.t->machining_overlays(s.handle, id_, path, tool); });
    }
    // `moves`, `move` (done, as of the last draw), the heights' grid (`nx`, `ny`, `cell`, `min`)
    // and the job's `cycle_time` in seconds.
    Result<MachiningInfo> info() {
        CadaclysmViewMachiningInfo out{};
        out.size = sizeof out;
        Result<void> done = ok("cadaclysm_view_machining_info",
                               [&](detail::ViewState& s) { return s.t->machining_info(s.handle, id_, &out); });
        if (!done) return done.error();
        MachiningInfo i;
        i.moves = out.moves;
        i.move = out.move;
        i.nx = out.nx;
        i.ny = out.ny;
        i.cell = out.cell;
        i.min = {out.min[0], out.min[1]};
        i.cycle_time = out.cycle_time;
        return i;
    }
    // The stock's heights now, nx * ny floats, row y then x; waits for the GPU.
    Result<std::vector<float>> heights() {
        Result<MachiningInfo> i = info();
        if (!i) return i.error();
        std::vector<float> z(static_cast<std::size_t>(i->nx) * i->ny);
        Result<void> done = ok("cadaclysm_view_machining_heights", [&](detail::ViewState& s) {
            float none = 0.0f;  // never NULL, even for an empty grid
            return s.t->machining_heights(s.handle, id_, z.empty() ? &none : z.data(), z.size());
        });
        if (!done) return done.error();
        return z;
    }

private:
    friend class View;
    explicit Machining(const Item& item) : Item(item) {}
};

// How every "dashed" item's hidden lines and points look, as Python's OccludedStyle: a dash
// and a gap in points, the share of coverage kept (above 0, at most 1), and optionally one
// colour (0..1 RGB) for all of them.
struct OccludedStyle {
    float dash = 6.0f;
    float gap = 4.0f;
    float dim = 0.5f;
    std::optional<std::array<float, 3>> colour;
};

class View {
public:
    View(View&&) noexcept = default;
    View& operator=(View&&) noexcept = default;
    View(const View&) = delete;
    View& operator=(const View&) = delete;
    ~View() = default;  // the state's destructor destroys the view, on the thread that made it

    // A window of its own (the terminal: drawn in the terminal).
    static Result<View> create(const ViewOptions& o = {}) { return make(nullptr, o, o.width, o.height, 0); }
    // No window and no display: a GPU adapter is enough. 0 x 0: 1280 x 800.
    static Result<View> offscreen(std::uint32_t width, std::uint32_t height, const ViewOptions& o = {}) {
        return make(nullptr, o, width ? width : 1280, height ? height : 800, 1);
    }
    // In a host's native window; the host forwards input(), resize() and draw().
    static Result<View> in_window(const ViewWindow& w, const ViewOptions& o = {}) {
        CadaclysmViewWindow raw{};
        raw.size = sizeof raw;
        raw.kind = w.kind;
        raw.window = w.handle;
        raw.window_id = w.id;
        raw.display = w.display;
        raw.width = w.width;
        raw.height = w.height;
        return make(&raw, o, w.width, w.height, 0);
    }

    // The library it was made with; nullptr for a moved-from View.
    const ViewLibrary* library() const noexcept { return state_ ? state_->library : nullptr; }
    // Destroyed (close()), or its window closed (run() ended, Escape, its close button).
    bool closed() const { return !state_ || state_->gone(); }
    // Destroys the view and its window; what its items kept is let go. Idempotent. Refused
    // on another thread than the one that made it.
    Result<void> close() {
        if (!state_ || !state_->handle) return {};
        if (state_->thread != std::this_thread::get_id())
            return detail::view_error("close: a view belongs to the thread that made it");
        state_->destroy();
        return {};
    }

    // -- showing: each returns the Item
    // A solid by handle; the item keeps it alive. `options` (1.21): a material, an opacity and
    // the faces to show alone (SolidOptions); without any, the 1.4 call.
    Result<Item> show(const blacksmith::Solid& solid, double tolerance = 0.05,
                      const std::optional<Colour>& rgb = std::nullopt, const SolidOptions& options = {}) {
        if (solid.closed()) return detail::view_error("solid: closed");
        static constexpr std::pair<std::string_view, std::uint32_t> materials[] = {
            {"default", CADACLYSM_VIEW_MATERIAL_DEFAULT}, {"plastic", CADACLYSM_VIEW_MATERIAL_PLASTIC},
            {"metal", CADACLYSM_VIEW_MATERIAL_METAL},     {"matte", CADACLYSM_VIEW_MATERIAL_MATTE},
            {"paint", CADACLYSM_VIEW_MATERIAL_PAINT},     {"brushed", CADACLYSM_VIEW_MATERIAL_BRUSHED},
            {"glass", CADACLYSM_VIEW_MATERIAL_GLASS}};
        std::uint32_t material = CADACLYSM_VIEW_MATERIAL_DEFAULT;
        if (!options.material.empty()) {
            const auto* found = std::find_if(std::begin(materials), std::end(materials),
                                             [&](const auto& m) { return m.first == options.material; });
            if (found == std::end(materials))
                return detail::view_error("material: '" + options.material +
                                          "' is not 'default', 'plastic', 'metal', 'matte', 'paint', 'brushed' or 'glass'");
            material = found->second;
        }
        const bool plain = options.material.empty() && !options.opacity && !options.faces;
        const char* call = plain ? "cadaclysm_view_show_solid" : "cadaclysm_view_show_solid_faces";
        auto c = detail::paint_for(state_.get(), call, rgb);
        if (!c) return c.error();
        return add(call, [&](detail::ViewState& s) {
            if (plain) return s.t->show_solid(s.handle, detail::ViewAccess::handle(solid), tolerance, c->data());
            const std::uint32_t* faces = options.faces ? options.faces->data() : nullptr;
            static const std::uint32_t none = 0;
            if (options.faces && options.faces->empty()) faces = &none;
            return s.t->show_solid_faces(s.handle, detail::ViewAccess::handle(solid), tolerance, c->data(), material,
                                         options.opacity.value_or(1.0f), faces,
                                         options.faces ? static_cast<std::uint32_t>(options.faces->size()) : 0u);
        }, detail::ViewShown{detail::ViewAccess::keep(solid), nullptr});
    }
    // A scene by handle; the item keeps it alive.
    Result<Item> show(const Scene& scene) {
        if (scene.closed()) return detail::ViewAccess::closed(scene);
        return add("cadaclysm_view_show", [&](detail::ViewState& s) { return s.t->show(s.handle, detail::ViewAccess::handle(scene)); },
                   detail::ViewShown{detail::ViewAccess::keep(scene), detail::ViewAccess::identity(scene)});
    }
    // A node: its scene by handle with the siblings along its path hidden (Python's
    // _show_node; framing it is the caller's). The item borrows from the Node's Scene: keep
    // the Scene while it is shown.
    Result<Item> show(const Node& node) {
        const CadaclysmScene* scene = detail::ViewAccess::handle(node);
        auto item = add("cadaclysm_view_show", [&](detail::ViewState& s) { return s.t->show(s.handle, scene); },
                        detail::ViewShown{nullptr, detail::ViewAccess::identity(node)});
        if (!item) return item;
        for (std::uint32_t hidden : detail::ViewAccess::siblings_along_path(node)) {
            auto done = item->node_visible(hidden, false);
            if (!done) return done.error();
        }
        return item;
    }
    // positions: three floats a point; indices: three a triangle; normals (empty: none):
    // one a position; edges (empty: none): two points a segment.
    Result<Item> show_mesh(const std::vector<float>& positions, const std::vector<std::uint32_t>& indices,
                           const std::vector<float>& normals = {}, const std::vector<float>& edges = {},
                           const std::optional<Colour>& rgb = std::nullopt) {
        if (positions.size() % 3)
            return detail::view_error("positions is three numbers a point, not " + std::to_string(positions.size()));
        if (!normals.empty() && normals.size() != positions.size())
            return detail::view_error("a mesh has " + std::to_string(positions.size() / 3) + " positions but " +
                                      std::to_string(normals.size() / 3) + " normals");
        if (edges.size() % 6)
            return detail::view_error("edges is two points a segment (6 numbers), not " + std::to_string(edges.size()));
        auto vertices = detail::count_of(positions.size() / 3, "show_mesh positions");
        if (!vertices) return vertices.error();
        auto index_count = detail::count_of(indices.size(), "show_mesh indices");
        if (!index_count) return index_count.error();
        auto edge_count = detail::count_of(edges.size() / 6, "show_mesh edges");
        if (!edge_count) return edge_count.error();
        auto c = detail::paint_for(state_.get(), "cadaclysm_view_show_mesh", rgb);
        if (!c) return c.error();
        CadaclysmViewMesh m{};
        m.size = sizeof m;
        m.positions = detail::non_null(positions);
        m.vertex_count = *vertices;
        m.normals = normals.empty() ? nullptr : normals.data();
        m.indices = detail::non_null(indices);
        m.index_count = *index_count;
        m.edges = edges.empty() ? nullptr : edges.data();
        m.edge_count = *edge_count;
        m.rgb = c->data();
        return add("cadaclysm_view_show_mesh", [&](detail::ViewState& s) { return s.t->show_mesh(s.handle, &m); }, {});
    }
    // Six floats a segment: two points.
    Result<Item> show_lines(const std::vector<float>& segments, const std::optional<Colour>& rgb = std::nullopt) {
        if (segments.size() % 6)
            return detail::view_error("segments is two points a segment (6 numbers), not " + std::to_string(segments.size()));
        auto n = detail::count_of(segments.size() / 6, "show_lines");
        if (!n) return n.error();
        auto c = detail::paint_for(state_.get(), "cadaclysm_view_show_lines", rgb);
        if (!c) return c.error();
        return add("cadaclysm_view_show_lines", [&](detail::ViewState& s) {
            return s.t->show_lines(s.handle, detail::non_null(segments), *n, c->data());
        }, {});
    }
    // Points, three floats each: a disc of `size_px` device pixels across (1 to 64) at each, in
    // `rgb` (none: the edge colour), as one item. A point does not pick; the item is framed by
    // its points' box. The library refuses a value that is not finite and a size out of range;
    // the terminal library refuses points (it has no way to draw a dot).
    Result<Item> show_points(const std::vector<float>& positions, const std::optional<Colour>& rgb = std::nullopt,
                             float size_px = 8.0f) {
        if (positions.size() % 3)
            return detail::view_error("show_points: three numbers a point, not " + std::to_string(positions.size()));
        auto n = detail::count_of(positions.size() / 3, "show_points");
        if (!n) return n.error();
        auto c = detail::paint_for(state_.get(), "cadaclysm_view_show_points", rgb);
        if (!c) return c.error();
        return add("cadaclysm_view_show_points", [&](detail::ViewState& s) {
            return s.t->show_points(s.handle, detail::non_null(positions), *n, c->data(), size_px);
        }, {});
    }
    // A CAM job on a stock, paused at its start, as Python's View.show_machining: `programs` in
    // run order, `stock` as its min and max corners, `part` (std::nullopt: none) to colour by
    // deviation, `options` where the library's defaults (cell, tolerance 0.05, skin 0.3,
    // rapid_rate 5000 mm/min) are not wanted. Play it with play(). A shape that is none of
    // "flat", "ball", "drill", "vbit" or "bullnose", a number that is not finite, a part that
    // is not whole triangles of x y z triples, or an index past its vertices is refused before
    // the library is called.
    Result<Machining> show_machining(const std::vector<MachiningProgram>& programs, const MachiningStock& stock,
                                     const std::optional<MachiningPart>& part = std::nullopt,
                                     const MachiningOptions& options = MachiningOptions()) {
        Result<std::uint32_t> program_count = detail::count_of(programs.size(), "show_machining");
        if (!program_count) return program_count.error();
        std::vector<CadaclysmViewProgram> raw(programs.size());
        for (std::size_t k = 0; k < programs.size(); ++k) {
            const MachiningTool& tool = programs[k].tool;
            std::uint32_t shape = 0;
            if (tool.shape == "flat") {
                shape = CADACLYSM_VIEW_TOOL_FLAT;
            } else if (tool.shape == "ball") {
                shape = CADACLYSM_VIEW_TOOL_BALL;
            } else if (tool.shape == "drill") {
                shape = CADACLYSM_VIEW_TOOL_DRILL;
            } else if (tool.shape == "vbit") {
                shape = CADACLYSM_VIEW_TOOL_VBIT;
            } else if (tool.shape == "bullnose") {
                shape = CADACLYSM_VIEW_TOOL_BULLNOSE;
            } else {
                return detail::view_error("shape " + detail::quoted(tool.shape) +
                                          ": one of flat, ball, drill, vbit, bullnose");
            }
            if (!std::isfinite(tool.diameter) || !std::isfinite(tool.flute_length) || !std::isfinite(tool.angle) || !std::isfinite(tool.corner_radius))
                return detail::view_error("tool: diameter, flute_length, angle and corner_radius are finite numbers");
            if (programs[k].gcode.find('\0') != std::string::npos)
                return detail::view_error("gcode: a NUL character cannot be sent (the C string ends there)");
            CadaclysmViewProgram& p = raw[k];
            p.size = sizeof p;
            p.tool_number = tool.number;
            p.tool_shape = shape;
            p.tool_diameter = tool.diameter;
            p.tool_flute_length = tool.flute_length;
            p.tool_angle = tool.angle;
            p.tool_corner_radius = tool.corner_radius;
            p.gcode = programs[k].gcode.c_str();
        }
        CadaclysmViewMachining m{};
        m.size = sizeof m;
        m.program_count = *program_count;
        m.programs = detail::non_null(raw);
        for (std::size_t a = 0; a < 3; ++a) {
            if (!std::isfinite(stock.min[a]) || !std::isfinite(stock.max[a]))
                return detail::view_error("stock: min and max are finite numbers");
            m.stock_min[a] = stock.min[a];
            m.stock_max[a] = stock.max[a];
        }
        if (part) {
            for (float x : part->positions)
                if (!std::isfinite(x)) return detail::view_error("part positions: finite numbers");
            if (part->positions.size() % 3)
                return detail::view_error("part positions: " + std::to_string(part->positions.size()) +
                                          " numbers is not a whole number of x y z triples");
            if (part->indices.size() % 3)
                return detail::view_error("part indices: " + std::to_string(part->indices.size()) +
                                          " is not a whole number of triangles");
            std::size_t vertices = part->positions.size() / 3;
            for (std::uint32_t i : part->indices)
                if (i >= vertices)
                    return detail::view_error("part indices: " + std::to_string(i) + " is past the last of " +
                                              std::to_string(vertices) + " vertices");
            Result<std::uint32_t> vertex_count = detail::count_of(vertices, "show_machining part");
            if (!vertex_count) return vertex_count.error();
            Result<std::uint32_t> index_count = detail::count_of(part->indices.size(), "show_machining part");
            if (!index_count) return index_count.error();
            m.part_positions = detail::non_null(part->positions);
            m.part_indices = detail::non_null(part->indices);
            m.part_vertex_count = *vertex_count;
            m.part_index_count = *index_count;
        }
        if ((options.cell && !std::isfinite(*options.cell)) || (options.tolerance && !std::isfinite(*options.tolerance)) ||
            (options.skin && !std::isfinite(*options.skin)) || (options.rapid_rate && !std::isfinite(*options.rapid_rate)))
            return detail::view_error("show_machining options: cell, tolerance, skin and rapid_rate are finite numbers");
        m.cell = options.cell.value_or(0.0);
        m.tolerance = options.tolerance.value_or(0.0);
        m.rapid_rate = options.rapid_rate.value_or(0.0);
        if (options.skin) {
            m.skin = *options.skin;
            m.skin_set = 1;
        }
        Result<Item> item = add("cadaclysm_view_show_machining",
                                [&](detail::ViewState& s) { return s.t->show_machining(s.handle, &m); }, {});
        if (!item) return item.error();
        return Machining(*item);
    }
    // Rational cubics, sixteen floats each (four x, y, z, w control points).
    Result<Item> show_curves(const std::vector<float>& beziers, const std::optional<Colour>& rgb = std::nullopt) {
        if (beziers.size() % 16)
            return detail::view_error("show_curves takes four x, y, z, w control points (16 numbers) a curve, not " +
                                      std::to_string(beziers.size()));
        auto n = detail::count_of(beziers.size() / 16, "show_curves");
        if (!n) return n.error();
        auto c = detail::paint_for(state_.get(), "cadaclysm_view_show_curves", rgb);
        if (!c) return c.error();
        return add("cadaclysm_view_show_curves", [&](detail::ViewState& s) {
            return s.t->show_curves(s.handle, detail::non_null(beziers), *n, c->data());
        }, {});
    }
    // corners: bottom-left, bottom-right, top-right, top-left; rgba (width x height x 4
    // bytes) rows from the top.
    Result<Item> show_image(const std::array<float, 12>& corners, const std::vector<std::uint8_t>& rgba,
                            std::uint32_t width, std::uint32_t height, float opacity = 1.0f) {
        auto need = detail::pixel_bytes(width, height, "show_image");
        if (!need) return need.error();
        if (rgba.size() != *need)
            return detail::view_error("show_image: " + std::to_string(width) + " x " + std::to_string(height) +
                                      " pixels need " + std::to_string(*need) + " bytes (rgba), not " +
                                      std::to_string(rgba.size()));
        CadaclysmViewImage raw{};
        raw.size = sizeof raw;
        for (std::size_t i = 0; i < 12; ++i) raw.corners[i] = corners[i];
        raw.rgba = detail::non_null(rgba);
        raw.width = width;
        raw.height = height;
        raw.opacity = opacity;
        return add("cadaclysm_view_show_image", [&](detail::ViewState& s) { return s.t->show_image(s.handle, &raw); }, {});
    }
    // Text at the point `at`: a label or world text, as TextOptions says (its defaults: a
    // white 12-pixel label, its bottom-left corner on the point). Item::set_text changes the
    // string later. Refused: an unknown mode or align, a NUL in `text`, colour text the
    // library refuses, and what the library refuses (a size not finite and positive, world
    // `right` and `up` parallel, an unknown font), with its reason.
    Result<Item> show_text(std::string_view text, const std::array<float, 3>& at, const TextOptions& o = {}) {
        static const std::pair<const char*, std::uint32_t> modes[] = {{"label", CADACLYSM_VIEW_TEXT_LABEL},
                                                                      {"world", CADACLYSM_VIEW_TEXT_WORLD}};
        static const std::pair<const char*, std::uint32_t> aligns[] = {
            {"top-left", CADACLYSM_VIEW_ALIGN_TOP_LEFT},       {"top", CADACLYSM_VIEW_ALIGN_TOP},
            {"top-right", CADACLYSM_VIEW_ALIGN_TOP_RIGHT},     {"left", CADACLYSM_VIEW_ALIGN_LEFT},
            {"centre", CADACLYSM_VIEW_ALIGN_CENTRE},           {"center", CADACLYSM_VIEW_ALIGN_CENTRE},
            {"right", CADACLYSM_VIEW_ALIGN_RIGHT},             {"bottom-left", CADACLYSM_VIEW_ALIGN_BOTTOM_LEFT},
            {"bottom", CADACLYSM_VIEW_ALIGN_BOTTOM},           {"bottom-right", CADACLYSM_VIEW_ALIGN_BOTTOM_RIGHT}};
        auto named = [](const auto& table, const std::string& value, const char* what) -> Result<std::uint32_t> {
            std::string names;
            for (const auto& entry : table) {
                if (value == entry.first) return entry.second;
                names += (names.empty() ? "" : ", ") + std::string(entry.first);
            }
            return detail::view_error(std::string(what) + " " + detail::quoted(value) + ": one of " + names);
        };
        auto mode = named(modes, o.mode, "mode");
        if (!mode) return mode.error();
        auto align = named(aligns, o.align, "align");
        if (!align) return align.error();
        auto shown = detail::text_of(text);
        if (!shown) return shown.error();
        auto rgb = detail::paint_for(state_.get(), "cadaclysm_view_show_text", o.colour);
        if (!rgb) return rgb.error();
        auto box = detail::paint(*state_->t, o.box);
        if (!box) return box.error();
        CadaclysmViewText raw{};
        raw.size = sizeof raw;
        raw.text = shown->c_str();
        raw.mode = *mode;
        for (std::size_t i = 0; i < 3; ++i) {
            raw.at[i] = at[i];
            raw.right[i] = o.right ? (*o.right)[i] : 0.0f;
            raw.up[i] = o.up ? (*o.up)[i] : 0.0f;
            raw.rgb[i] = rgb->values[i];
        }
        raw.height = o.size;
        raw.align = *align;
        raw.offset[0] = o.offset[0];
        raw.offset[1] = o.offset[1];
        if (box->given)
            for (std::size_t i = 0; i < 4; ++i) raw.box_rgba[i] = box->values[i];
        raw.box_padding = o.padding;
        raw.on_top = o.on_top ? 1u : 0u;
        raw.font = o.font;
        return add("cadaclysm_view_show_text", [&](detail::ViewState& s) { return s.t->show_text(s.handle, &raw); }, {});
    }

    // -- the camera
    Result<void> orbit(float dx, float dy) {
        return act("cadaclysm_view_orbit", [&](detail::ViewState& s) { s.t->orbit(s.handle, dx, dy); });
    }
    Result<void> pan(float dx, float dy) {
        return act("cadaclysm_view_pan", [&](detail::ViewState& s) { s.t->pan(s.handle, dx, dy); });
    }
    Result<void> zoom(float steps) {
        return act("cadaclysm_view_zoom", [&](detail::ViewState& s) { s.t->zoom(s.handle, steps); });
    }
    Result<void> look(float dx, float dy) {
        return act("cadaclysm_view_look", [&](detail::ViewState& s) { s.t->look(s.handle, dx, dy); });
    }
    Result<void> dolly(float ratio) {
        return act("cadaclysm_view_dolly", [&](detail::ViewState& s) { s.t->dolly(s.handle, ratio); });
    }
    // "top", "front", "right" or "iso".
    Result<void> standard(std::string_view name) {
        std::uint32_t which = name == "top"     ? CADACLYSM_VIEW_STANDARD_TOP
                              : name == "front" ? CADACLYSM_VIEW_STANDARD_FRONT
                              : name == "right" ? CADACLYSM_VIEW_STANDARD_RIGHT
                              : name == "iso"   ? CADACLYSM_VIEW_STANDARD_ISO
                                                : 99u;
        if (which == 99u)
            return detail::view_error("standard view '" + std::string(name) + "': one of top, front, right, iso");
        return ok("cadaclysm_view_standard", [&](detail::ViewState& s) { return s.t->standard(s.handle, which); });
    }
    // Fit the camera to everything shown.
    Result<void> frame() {
        return ok("cadaclysm_view_frame", [&](detail::ViewState& s) { return s.t->frame(s.handle, 0); });
    }
    // Whether a double click frames what it hit (off by default: it is a pick answered with
    // `clicks` 2 and the camera stays). Applies where the view takes the pick itself (its own
    // window, pump, run).
    Result<void> set_double_click_frames(bool on) {
        return act("cadaclysm_view_set_double_click_frames",
                   [&](detail::ViewState& s) { s.t->set_double_click_frames(s.handle, on); });
    }
    // Moves the orbit point to `point` (as a pick's point): the eye keeps its direction and
    // distance from it, so the camera moves sideways and does not turn. Leaves fly mode. A
    // point not finite, or one while viewports are set, is the library's refusal.
    Result<void> focus(const std::array<float, 3>& point) {
        return ok("cadaclysm_view_focus", [&](detail::ViewState& s) { return s.t->focus(s.handle, point.data()); });
    }
    // How a left drag moves the camera (see Navigation).
    Result<Navigation> navigation() {
        if (auto no = detail::refusal(state_.get(), "cadaclysm_view_navigation")) return *no;
        return state_->t->navigation(state_->handle) == CADACLYSM_VIEW_NAVIGATION_FLY ? Navigation::fly
                                                                                      : Navigation::orbit;
    }
    Result<void> orthographic(bool on) {
        return act("cadaclysm_view_set_orthographic", [&](detail::ViewState& s) { s.t->set_orthographic(s.handle, on); });
    }
    // Panes of their own cameras; empty: the one camera again.
    Result<void> viewports(const std::vector<Viewport>& list) {
        auto n = detail::count_of(list.size(), "viewports");
        if (!n) return n.error();
        std::vector<CadaclysmViewViewport> raw(list.size());
        for (std::size_t i = 0; i < list.size(); ++i) {
            raw[i] = CadaclysmViewViewport{};
            raw[i].size = sizeof raw[i];
            for (std::size_t k = 0; k < 4; ++k) raw[i].rect[k] = list[i].rect[k];
            for (std::size_t k = 0; k < 16; ++k) {
                raw[i].view[k] = list[i].view[k];
                raw[i].projection[k] = list[i].projection[k];
            }
            for (std::size_t k = 0; k < 3; ++k) raw[i].eye[k] = list[i].eye[k];
            raw[i].grid = list[i].grid;
            raw[i].layer_mask = 0xFFFFFFFFu;  // every user layer
        }
        return ok("cadaclysm_view_set_viewports", [&](detail::ViewState& s) {
            return s.t->set_viewports(s.handle, raw.empty() ? nullptr : raw.data(), *n);
        });
    }
    // Exact surfaces (false) or triangles (true).
    Result<void> surfaces(bool triangles) {
        return ok("cadaclysm_view_set_surfaces",
                  [&](detail::ViewState& s) { return s.t->set_surfaces(s.handle, triangles ? 1u : 0u); });
    }
    // CADACLYSM_VIEW_LAYER_*.
    Result<void> layer(std::uint32_t which, bool on) {
        return ok("cadaclysm_view_set_layer", [&](detail::ViewState& s) { return s.t->set_layer(s.handle, which, on); });
    }
    // The clear colour: three numbers or text (see Colour).
    Result<void> background(const Colour& rgb) {
        auto c = detail::paint_for(state_.get(), "cadaclysm_view_set_background", rgb);
        if (!c) return c.error();
        return act("cadaclysm_view_set_background", [&](detail::ViewState& s) { s.t->set_background(s.handle, c->data()); });
    }
    // How plain parts are lit, as Python's View.lighting: "headlight" (the default) -- whatever
    // faces the camera is bright -- or "studio", a key light fixed above the scene with an
    // ambient and a camera fill. Another name is refused before the library is called.
    Result<void> lighting(const std::string& name) {
        if (name != "headlight" && name != "studio")
            return detail::view_error("lighting '" + name + "': 'headlight' or 'studio'");
        std::uint32_t which = name == "studio" ? CADACLYSM_VIEW_LIGHTING_STUDIO : CADACLYSM_VIEW_LIGHTING_HEADLIGHT;
        return ok("cadaclysm_view_set_lighting", [&](detail::ViewState& s) { return s.t->set_lighting(s.handle, which); });
    }
    // The lighting in use: "headlight" or "studio".
    Result<std::string> lighting() {
        if (auto no = detail::refusal(state_.get(), "cadaclysm_view_lighting")) return *no;
        return std::string(state_->t->lighting(state_->handle) == CADACLYSM_VIEW_LIGHTING_STUDIO ? "studio" : "headlight");
    }
    // The view-wide occluded style (see OccludedStyle); "solid" and "off" items never use it.
    Result<void> occluded_style(const OccludedStyle& style) {
        CadaclysmViewOccludedStyle raw{};
        raw.size = sizeof raw;
        raw.dash = style.dash;
        raw.gap = style.gap;
        raw.dim = style.dim;
        raw.has_colour = style.colour.has_value() ? 1u : 0u;
        if (style.colour) {
            raw.colour[0] = (*style.colour)[0];
            raw.colour[1] = (*style.colour)[1];
            raw.colour[2] = (*style.colour)[2];
        }
        return ok("cadaclysm_view_set_occluded_style",
                  [&](detail::ViewState& s) { return s.t->set_occluded_style(s.handle, &raw); });
    }
    // The style in use, defaults filled in.
    Result<OccludedStyle> occluded_style() {
        CadaclysmViewOccludedStyle raw{};
        raw.size = sizeof raw;
        Result<void> got = ok("cadaclysm_view_occluded_style",
                              [&](detail::ViewState& s) { return s.t->occluded_style(s.handle, &raw); });
        if (!got) return got.error();
        OccludedStyle style;
        style.dash = raw.dash;
        style.gap = raw.gap;
        style.dim = raw.dim;
        if (raw.has_colour) style.colour = std::array<float, 3>{raw.colour[0], raw.colour[1], raw.colour[2]};
        return style;
    }
    // The timeline of machining jobs. play: at `speed` times real time, stopping at its end
    // unless loop() is on (play at the end starts again from 0).
    Result<void> play(double speed = 1.0) {
        if (!std::isfinite(speed)) return detail::view_error("play speed: a finite number");
        return ok("cadaclysm_view_timeline_play", [&](detail::ViewState& s) { return s.t->timeline_play(s.handle, speed); });
    }
    Result<void> pause() {
        return ok("cadaclysm_view_timeline_pause", [&](detail::ViewState& s) { return s.t->timeline_pause(s.handle); });
    }
    // Sets the clock, clamped to [0, duration].
    Result<void> seek(double seconds) {
        if (!std::isfinite(seconds)) return detail::view_error("seek seconds: a finite number");
        return ok("cadaclysm_view_timeline_seek",
                  [&](detail::ViewState& s) { return s.t->timeline_seek(s.handle, seconds); });
    }
    Result<void> loop(bool on = true) {
        return ok("cadaclysm_view_timeline_set_loop",
                  [&](detail::ViewState& s) { return s.t->timeline_set_loop(s.handle, on); });
    }
    Result<double> time() {
        if (std::optional<Error> no = detail::refusal(state_.get(), "cadaclysm_view_timeline_time")) return *no;
        return state_->t->timeline_time(state_->handle);
    }
    Result<double> duration() {
        if (std::optional<Error> no = detail::refusal(state_.get(), "cadaclysm_view_timeline_duration")) return *no;
        return state_->t->timeline_duration(state_->handle);
    }
    Result<bool> playing() {
        if (std::optional<Error> no = detail::refusal(state_.get(), "cadaclysm_view_timeline_playing")) return *no;
        return static_cast<bool>(state_->t->timeline_playing(state_->handle));
    }
    // One line per track at the clock's time, e.g. "move 370 of 638 - T1 flat 6 mm"; none when
    // nothing is on the timeline.
    Result<std::vector<std::string>> status() {
        if (std::optional<Error> no = detail::refusal(state_.get(), "cadaclysm_view_timeline_status")) return *no;
        std::size_t n = state_->t->timeline_status(state_->handle, nullptr, 0);
        std::vector<std::string> lines;
        while (n > 0) {
            std::vector<char> buffer(n + 1, '\0');
            std::size_t got = state_->t->timeline_status(state_->handle, buffer.data(), buffer.size());
            if (got < buffer.size()) {  // else the line grew between the two calls: ask again with room for it
                if (got == 0) return lines;  // the line emptied between the two calls
                std::string text(buffer.data(), got);
                std::size_t from = 0;
                for (;;) {
                    std::size_t at = text.find('\n', from);
                    lines.push_back(text.substr(from, at == std::string::npos ? std::string::npos : at - from));
                    if (at == std::string::npos) break;
                    from = at + 1;
                }
                return lines;
            }
            n = got;
        }
        return lines;
    }
    // Levels of detail, as Python's View.lod: parts of `min_triangles` or more (0: the
    // library's default, 2,048) get coarser levels, and a moving frame draws as `motion`
    // says -- "detailed" or "smooth" (see wake_ms); std::nullopt turns them off (the default).
    Result<void> lod(std::optional<std::string> motion = std::string("detailed"), std::uint32_t min_triangles = 0) {
        if (!motion) return ok("cadaclysm_view_set_lod", [&](detail::ViewState& s) { return s.t->set_lod(s.handle, nullptr); });
        if (*motion != "detailed" && *motion != "smooth")
            return detail::view_error("motion '" + *motion + "': one of detailed, smooth or none");
        CadaclysmViewLod raw{};
        raw.size = sizeof raw;
        raw.min_triangles = min_triangles;
        raw.motion = *motion == "smooth" ? CADACLYSM_VIEW_LOD_SMOOTH : CADACLYSM_VIEW_LOD_DETAILED;
        return ok("cadaclysm_view_set_lod", [&](detail::ViewState& s) { return s.t->set_lod(s.handle, &raw); });
    }
    // Milliseconds until needs_draw() turns true by itself (a resting frame refining the
    // picture); 0 when one is owed now, std::nullopt when none is coming.
    Result<std::optional<std::uint32_t>> wake_ms() {
        if (auto no = detail::refusal(state_.get(), "cadaclysm_view_wake_ms")) return *no;
        std::uint32_t ms = state_->t->wake_ms(state_->handle);
        if (ms == 0xFFFFFFFFu) return std::optional<std::uint32_t>();
        return std::optional<std::uint32_t>(ms);
    }

    // -- the rest
    // What is under (x, y) of `viewport`; item 0 for nothing. Python's pick: a view never
    // drawn is drawn first; the library's own error, or "pick: the answer never landed (...)".
    Result<ViewPick> pick(std::uint32_t x, std::uint32_t y, std::uint32_t viewport = 0) {
        const char* call = state_ && state_->drawn ? "cadaclysm_view_request_pick_in" : "cadaclysm_view_draw";
        if (auto no = detail::refusal(state_.get(), call)) return *no;
        CadaclysmViewPick raw;
        std::vector<char> err(CVL_ERROR, 0);
        if (!cvl_pick(state_->t, state_->handle, &state_->drawn, viewport, x, y, &raw, err.data(), err.size()))
            return detail::view_error(err.data());
        return detail::pick_of(raw);
    }
    // The newest pick answer that has landed, without asking or waiting -- Python's
    // last_pick: a click or tap in the view's own window (pump lands them as it draws), a
    // double click's (`clicks` 2), or one an input() asked for, landed by the draws after it.
    // std::nullopt while none has; a ViewPick with item 0 for a click on nothing. Each answer
    // is read once, and a newer one replaces one not read yet. A failure other than "no answer
    // yet" is the library's own message.
    Result<std::optional<ViewPick>> last_pick() {
        if (auto no = detail::refusal(state_.get(), "cadaclysm_view_pick_result")) return *no;
        CadaclysmViewPick raw{};
        raw.size = sizeof raw;
        if (state_->t->pick_result(state_->handle, &raw)) return std::optional<ViewPick>(detail::pick_of(raw));
        const char* said = state_->t->last_error();
        const std::string waiting = said ? said : "";
        const std::string none = "no pick result";
        if (!waiting.empty() &&
            (waiting.size() < none.size() || waiting.compare(waiting.size() - none.size(), none.size(), none) != 0))
            return detail::view_error(waiting);
        return std::optional<ViewPick>();
    }
    // What a snap may land on, as Python's set_snap: {"all"} (the default), kind names
    // ("vertex", "midpoint", "centre" -- a circular edge's -- "quadrant", "edge", "face", "grid",
    // "plane"), or std::nullopt to switch snapping off, as a view starts. `aperture_px` is how far
    // from the cursor a point kind may lie (0: the library's default, 10 points); `marker`
    // whether the view draws the marker at the snap. Once on, a mouse hovering over a view in
    // its own window snaps, and so does a click (last_snap reads them); snap() asks one at any
    // pixel. Where kinds compete, a corner beats the face it sits on.
    Result<void> set_snap(const std::optional<std::vector<std::string>>& kinds = std::vector<std::string>{"all"},
                          float aperture_px = 0.0f, bool marker = true) {
        std::uint32_t bits = 0;
        if (kinds) {
            for (const std::string& name : *kinds) {
                if (name == "all") {
                    bits |= CADACLYSM_VIEW_SNAP_ALL;
                    continue;
                }
                std::uint32_t bit = 0;
                for (const detail::SnapKindName& k : detail::snap_kinds)
                    if (name == k.name) bit = k.bit;
                if (!bit)
                    return detail::view_error("snap kind '" + name +
                                              "': one of vertex, midpoint, centre, quadrant, edge, face, grid, plane");
                bits |= bit;
            }
        }
        CadaclysmViewSnapSettings raw{};
        raw.size = sizeof raw;
        raw.kinds = bits;
        raw.aperture_px = aperture_px;
        raw.marker = marker ? 1u : 0u;
        return ok("cadaclysm_view_set_snap", [&](detail::ViewState& s) { return s.t->set_snap(s.handle, &raw); });
    }
    // The snap under (x, y) of `viewport` (see ViewSnap); kind "" where nothing in the kinds
    // set_snap chose lies there -- always, while snapping is off. Python's snap: a view never
    // drawn is drawn first, then frames until the answer lands; the library's own error, or
    // "snap: the answer never landed (...)".
    Result<ViewSnap> snap(std::uint32_t x, std::uint32_t y, std::uint32_t viewport = 0) {
        const char* call = state_ && state_->drawn ? "cadaclysm_view_request_snap_in" : "cadaclysm_view_draw";
        if (auto no = detail::refusal(state_.get(), call)) return *no;
        CadaclysmViewSnap raw;
        std::vector<char> err(CVL_ERROR, 0);
        if (!cvl_snap(state_->t, state_->handle, &state_->drawn, viewport, x, y, &raw, err.data(), err.size()))
            return detail::view_error(err.data());
        return detail::snap_of(raw);
    }
    // The newest snap answer that has landed, without asking or waiting -- Python's last_snap:
    // a hover or click in the view's own window (pump lands them as it draws), or one an
    // input() asked for. std::nullopt while none has; a ViewSnap of kind "" for one that found
    // nothing. Each answer is read once; a hover's never replaces a click's not read yet. A
    // failure other than "no answer yet" is the library's own message.
    Result<std::optional<ViewSnap>> last_snap() {
        if (auto no = detail::refusal(state_.get(), "cadaclysm_view_snap_result")) return *no;
        CadaclysmViewSnap raw{};
        raw.size = sizeof raw;
        if (state_->t->snap_result(state_->handle, &raw)) return std::optional<ViewSnap>(detail::snap_of(raw));
        const char* said = state_->t->last_error();
        const std::string waiting = said ? said : "";
        const std::string none = "no snap result";
        if (!waiting.empty() &&
            (waiting.size() < none.size() || waiting.compare(waiting.size() - none.size(), none.size(), none) != 0))
            return detail::view_error(waiting);
        return std::optional<ViewSnap>();
    }
    // Hides the snap marker and drops any snap asked or answered and not yet read.
    Result<void> clear_snap() {
        return act("cadaclysm_view_clear_snap", [&](detail::ViewState& s) { s.t->clear_snap(s.handle); });
    }
    // The plane "grid" and "plane" snaps land on, in place of the ground grid: through
    // `origin`, its grid lines along `x_axis` and across it, `step` apart (0: the ground grid's
    // spacing). The axes need not be unit length, but must not be parallel. std::nullopt as
    // `origin` puts the ground grid back.
    Result<void> set_work_plane(const std::optional<std::array<double, 3>>& origin,
                                const std::array<double, 3>& x_axis = {1.0, 0.0, 0.0},
                                const std::array<double, 3>& normal = {0.0, 0.0, 1.0}, double step = 0.0) {
        if (!origin)
            return ok("cadaclysm_view_clear_work_plane",
                      [&](detail::ViewState& s) { return s.t->clear_work_plane(s.handle); });
        return ok("cadaclysm_view_set_work_plane", [&](detail::ViewState& s) {
            return s.t->set_work_plane(s.handle, origin->data(), x_axis.data(), normal.data(), step);
        });
    }
    Result<void> draw() {
        auto done = ok("cadaclysm_view_draw", [&](detail::ViewState& s) { return s.t->draw(s.handle); });
        if (done) state_->drawn = 1;
        return done;
    }
    // Blocks until the window is closed; the camera it was left at and the last pick. The
    // window is then closed (as Python's run): every call but close() refuses.
    Result<Camera> run() {
        if (auto no = detail::refusal(state_.get(), "cadaclysm_view_run")) return *no;
        CadaclysmViewCamera cam{};
        cam.size = sizeof cam;
        CadaclysmViewPick pk{};
        pk.size = sizeof pk;
        if (!state_->t->run(state_->handle, &cam, &pk)) return detail::library_error(*state_);
        state_->mark_closed();
        return camera_of(cam, pk, state_->y_up);
    }
    // What image() reads, in physical pixels: {width, height}.
    Result<std::array<std::uint32_t, 2>> size() {
        if (auto no = detail::refusal(state_.get(), "cadaclysm_view_size")) return *no;
        std::array<std::uint32_t, 2> wh{};
        if (!state_->t->size(state_->handle, &wh[0], &wh[1])) return detail::library_error(*state_);
        return wh;
    }
    // One frame at the view's current size, read back.
    Result<ViewImage> image() {
        auto wh = size();
        if (!wh) return wh.error();
        auto bytes = detail::pixel_bytes((*wh)[0], (*wh)[1], "image");
        if (!bytes) return bytes.error();
        ViewImage out;
        out.width = (*wh)[0];
        out.height = (*wh)[1];
        out.rgba.assign(static_cast<std::size_t>(*bytes), 0);
        if (auto no = detail::refusal(state_.get(), "cadaclysm_view_image")) return *no;
        std::uint8_t none = 0;
        if (!state_->t->image(state_->handle, out.rgba.empty() ? &none : out.rgba.data(), out.rgba.size()))
            return detail::library_error(*state_);
        return out;
    }
    // The frame as a PNG.
    Result<void> save(const std::string& path) {
        auto pixels = image();
        if (!pixels) return pixels.error();
        std::vector<char> err(CVL_ERROR, 0);
        if (!cvl_write_png(path.c_str(), pixels->rgba.data(), pixels->width, pixels->height, err.data(), err.size()))
            return detail::view_error(err.data());
        return {};
    }
    // One forwarded event; the CADACLYSM_VIEW_INPUT_* bits. On a window of the view's own the
    // close bit (Escape) closes it, as the user closing it does; close() still owes the destroy.
    Result<std::uint32_t> input(const ViewEvent& e) {
        if (auto no = detail::refusal(state_.get(), "cadaclysm_view_input")) return *no;
        CadaclysmViewEvent raw{};
        raw.size = sizeof raw;
        raw.kind = e.kind;
        raw.pointer_id = e.pointer_id;
        raw.pointer = e.pointer;
        raw.button = e.button;
        raw.shift = e.shift ? 1u : 0u;
        raw.x = e.x;
        raw.y = e.y;
        raw.wheel_y = e.wheel_y;
        raw.key = e.key.empty() ? nullptr : e.key.c_str();
        raw.key_down = e.key_down ? 1u : 0u;
        raw.time_ms = e.time_ms;
        std::uint32_t bits = state_->t->input(state_->handle, &raw);
        if (!bits && said(*state_)) return detail::library_error(*state_);
        if ((bits & CADACLYSM_VIEW_INPUT_CLOSE) && state_->own) state_->mark_closed();
        return bits;
    }
    Result<void> resize(std::uint32_t width, std::uint32_t height) {
        return ok("cadaclysm_view_resize", [&](detail::ViewState& s) { return s.t->resize(s.handle, width, height); });
    }
    Result<bool> needs_draw() const {
        if (auto no = detail::refusal(state_.get(), "cadaclysm_view_needs_draw")) return *no;
        return state_->t->needs_draw(state_->handle);
    }

    // -- show()/view() on the objects: what the member templates Solid::show/view,
    // Scene::show/view, Node::show/view and Pose::show/view call (call those). A fresh view;
    // the wgpu library runs its window for both, any other library prints a still for show()
    // (`interactive` false) and runs for view(). The view is destroyed before this returns.
    static Result<Camera> draw(const blacksmith::Solid& solid, const ShowOptions& o, bool interactive) {
        if (solid.closed()) return detail::view_error("solid: closed");
        return object(interactive, "z", "Solid", detail::ViewAccess::handle(solid), o.tolerance.value_or(0.05), nullptr,
                      nullptr, {}, CVL_NO_NODE, o);
    }
    static Result<Camera> draw(const Scene& scene, const ShowOptions& o, bool interactive) {
        if (scene.closed()) return detail::ViewAccess::closed(scene);
        if (auto no = no_tolerance("Scene", o, interactive)) return *no;
        return object(interactive, detail::default_up_of(detail::ViewAccess::convention(scene)),
                      detail::ViewAccess::title(scene), nullptr, 0.0, detail::ViewAccess::handle(scene), nullptr, {},
                      CVL_NO_NODE, o);
    }
    static Result<Camera> draw(const Node& node, const ShowOptions& o, bool interactive) {
        if (auto no = no_tolerance("Node", o, interactive)) return *no;
        return object(interactive, detail::default_up_of(detail::ViewAccess::convention(node)),
                      detail::ViewAccess::title(node), nullptr, 0.0, detail::ViewAccess::handle(node), nullptr,
                      detail::ViewAccess::siblings_along_path(node), node.index(), o);
    }
    // Python's Pose.show: the scene by handle, every node at its posed transform.
    static Result<Camera> draw(const Pose& pose, const ShowOptions& o, bool interactive) {
        if (auto no = no_tolerance("Pose", o, interactive)) return *no;
        return object(interactive, detail::default_up_of(detail::ViewAccess::convention(pose.ground)),
                      detail::ViewAccess::title(pose.ground), nullptr, 0.0, detail::ViewAccess::handle(pose.ground),
                      &pose.transforms, {}, CVL_NO_NODE, o);
    }

private:
    explicit View(std::shared_ptr<detail::ViewState> s) : state_(std::move(s)) {}

    static Result<View> make(const CadaclysmViewWindow* window, const ViewOptions& o, std::uint32_t width,
                             std::uint32_t height, std::uint32_t offscreen) {
        auto lib = view::current();
        if (!lib) return lib.error();
        const CvlTable& t = detail::ViewAccess::table(**lib);
        CadaclysmView* handle = cvl_create(&t, window, o.title.c_str(), width, height, o.triangles ? 1u : 0u,
                                           o.y_up ? 1u : 0u, offscreen);
        if (!handle) {
            std::vector<char> err(CVL_ERROR, 0);
            cvl_create_failed(&t, detail::view_no_display, err.data(), err.size());
            return detail::view_error(err.data());
        }
        auto s = std::make_shared<detail::ViewState>();
        s->library = *lib;
        s->t = &t;
        s->handle = handle;
        s->own = !window && !offscreen;
        s->pumped = s->own && cvl_is_wgpu(&t);
        s->y_up = o.y_up;
        static_cast<void>(detail::thread_alive());  // armed on the thread that will destroy it
        s->enlist();
        return View(std::move(s));
    }

    // A void call refused: the library left a message (Python's _void).
    static bool said(const detail::ViewState& s) {
        const char* text = s.t->last_error();
        return text && text[0];
    }
    template <class F>
    Result<void> ok(const char* call, F&& f) {
        if (auto no = detail::refusal(state_.get(), call)) return *no;
        if (!f(*state_)) return detail::library_error(*state_);
        return {};
    }
    template <class F>
    Result<void> act(const char* call, F&& f) {
        if (auto no = detail::refusal(state_.get(), call)) return *no;
        f(*state_);
        if (said(*state_)) return detail::library_error(*state_);
        return {};
    }
    template <class F>
    Result<Item> add(const char* call, F&& f, detail::ViewShown what) {
        if (auto no = detail::refusal(state_.get(), call)) return *no;
        std::uint32_t id = f(*state_);
        if (!id) return detail::library_error(*state_);
        state_->keep(id, std::move(what));
        return Item(state_, id);
    }
    static std::optional<Error> no_tolerance(const char* kind, const ShowOptions& o, bool interactive) {
        if (!o.tolerance) return std::nullopt;
        return detail::view_error(std::string(kind) + (interactive ? ".view" : ".show") +
                                  " takes no tolerance: a document is drawn at the tolerance it was read with");
    }
    static Camera camera_of(const CadaclysmViewCamera& cam, const CadaclysmViewPick& picked, bool y_up) {
        Camera c;
        for (std::size_t i = 0; i < 3; ++i) {
            c.eye[i] = cam.eye[i];
            c.target[i] = cam.target[i];
            c.up[i] = cam.up[i];
        }
        c.orthographic = cam.orthographic != 0;
        cvl_angles(&cam, y_up ? 1 : 0, &c.azimuth, &c.elevation);
        if (picked.item) c.pick = detail::pick_of(picked);
        return c;
    }
    static Result<Camera> object(bool interactive, const std::string& default_up, const std::string& label,
                                 const CadaclysmBlacksmithSolid* solid, double tolerance, const CadaclysmScene* scene,
                                 const std::vector<std::array<double, 16>>* transforms,
                                 const std::vector<std::uint32_t>& hide, std::uint32_t node, const ShowOptions& o) {
        std::string up = o.up ? *o.up : default_up;
        if (up != "y" && up != "z") return detail::view_error("up '" + up + "': 'y' or 'z'");
        std::uint32_t count = 0;
        std::vector<double> flat;
        if (transforms) {
            auto n = detail::count_of(transforms->size(), "node_transforms");
            if (!n) return n.error();
            count = *n;
            flat.reserve(transforms->size() * 16);
            for (const auto& m : *transforms) flat.insert(flat.end(), m.begin(), m.end());
        }
        auto hidden = detail::count_of(hide.size(), "hide");
        if (!hidden) return hidden.error();
        auto lib = view::current();
        if (!lib) return lib.error();
        std::string title = o.title.empty() ? label : o.title;
        CvlShow how{};
        how.view = o.view.c_str();
        how.title = title.c_str();
        how.hint = o.hint.c_str();
        how.width = o.width;
        how.height = o.height;
        how.y_up = up == "y" ? 1u : 0u;
        how.azimuth = o.azimuth ? *o.azimuth : std::nan("");
        how.elevation = o.elevation ? *o.elevation : std::nan("");
        how.zoom = o.zoom;
        how.edges = o.edges ? 1u : 0u;
        how.no_display = detail::view_no_display;
        CadaclysmViewCamera cam{};
        cam.size = sizeof cam;
        CadaclysmViewPick picked{};
        picked.size = sizeof picked;
        std::vector<char> err(CVL_ERROR, 0);
        if (!cvl_draw_object(&detail::ViewAccess::table(**lib), interactive ? 1 : 0, "iso", solid, tolerance, scene,
                             transforms ? detail::non_null(flat) : nullptr, count, detail::non_null(hide), *hidden, node,
                             &how, &cam, &picked, err.data(), err.size()))
            return detail::view_error(err.data());
        return camera_of(cam, picked, how.y_up != 0);
    }

    std::shared_ptr<detail::ViewState> state_;
};

namespace view {
inline Result<std::uint32_t> pump(double seconds) {
    // [0, UINT32_MAX] ms: a negative (or NaN) wait is none, as Python's.
    std::uint32_t ms = 0;
    if (seconds > 0) ms = seconds * 1000.0 >= 4294967295.0 ? 0xFFFFFFFFu : static_cast<std::uint32_t>(seconds * 1000.0);
    detail::ViewRegistry& r = detail::view_registry();
    std::thread::id me = std::this_thread::get_id();
    std::vector<detail::ViewState*> alive;
    {
        std::lock_guard<std::mutex> lock(r.views_mutex);
        for (detail::ViewState* v : r.views)
            if (v->pumped && v->handle && !v->closed && v->thread == me) alive.push_back(v);
    }
    std::optional<Error> failure;
    if (alive.empty()) {
        if (ms) cvl_sleep_ms(ms);
    } else {
        bool first = true;
        for (detail::ViewState* v : alive) {
            std::uint32_t got = v->t->pump(v->handle, first ? ms : 0u);
            first = false;
            if (got == CADACLYSM_VIEW_CLOSED) v->mark_closed();
            else if (got != CADACLYSM_VIEW_OPEN && !failure) failure = detail::library_error(*v);
        }
    }
    if (failure) return *failure;
    std::uint32_t open = 0;
    std::lock_guard<std::mutex> lock(r.views_mutex);
    for (detail::ViewState* v : r.views)
        if (v->pumped && v->handle && !v->closed) ++open;
    return open;
}
}  // namespace view

}  // namespace CADACLYSM_ABI
}  // namespace cadaclysm

#endif  // CADACLYSM_VIEW_HPP
