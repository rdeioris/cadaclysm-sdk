#define _CRT_SECURE_NO_WARNINGS  // std::getenv/std::fopen under MSVC /W4 /WX and Windows clang -Werror
// cadaclysm/view.hpp: the missing-library message; the terminal library loaded, refusing an
// offscreen view and printing show()'s stills (with the tolerance, up and view refusals); a
// library that answers nothing (the loader test's stand-in) refused in Python's fallback
// words; then, on wgpu offscreen, a solid by handle kept alive by its item, drawn, picked,
// saved, lod/wake_ms, text (a label picked on its lines, set_text, the text layer, glyph and
// box colours, world text, the bundled font from bytes and path, the refusals), colour text drawing its numbers' pixels in every colour argument and
// refused text refused in the library's words, the length checks, empty lists, another
// thread refused; through the
// table rigged (windows forced offscreen, run faked) the void calls' refusals, show()/view()'s
// titles, up axes and camera, and run()'s camera Y up; an item removed; a scene posed and back at rest, an empty pose refused, a nested node with its
// siblings hidden, Scene::close releasing what shows it (and refused while another thread's
// view shows it); and a closed view's refusals; 1.22's snapping (rigged: the kinds' bits, the answer whole, the work plane; on the GPU: the square's corner). The terminal half skips without
// cadaclysm_terminal unless CADACLYSM_REQUIRE_TERMINAL=1; the GPU half without cadaclysm_view
// or an adapter unless CADACLYSM_REQUIRE_WGPU is set.
//
// cadaclysm_view_test <scratch dir> [samples/mechanism-solid.stp] [the stand-in library] [the bundled font]
#include <cadaclysm/view.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <type_traits>
#include <vector>

namespace bs = cadaclysm::blacksmith;
using cadaclysm::ShowOptions;
using cadaclysm::View;
using cadaclysm::ViewImage;

// Made in main, destroyed at exit after every function-local static (see the end of main).
static std::optional<View> g_view;
static std::optional<cadaclysm::Scene> g_scene;  // shown whole: its item keeps it
static std::optional<cadaclysm::Scene> g_other;  // a node of it shown: closed first, released at exit

static int failures = 0;
#define CHECK(cond, ...)                                              \
    do {                                                              \
        if (!(cond)) {                                                \
            std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
            std::fprintf(stderr, __VA_ARGS__);                        \
            std::fprintf(stderr, "\n");                               \
            ++failures;                                               \
        }                                                             \
    } while (0)

static bool required() {
    const char* v = std::getenv("CADACLYSM_REQUIRE_WGPU");
    return v && *v;
}

static bool terminal_required() {
    const char* v = std::getenv("CADACLYSM_REQUIRE_TERMINAL");
    return v && std::string(v) == "1";
}

static bool starts(const std::string& s, const char* p) { return s.rfind(p, 0) == 0; }
static bool has(const std::string& s, const char* p) { return s.find(p) != std::string::npos; }

// The message of a refused call, or "<accepted>".
template <class R>
static std::string refused(const R& r) {
    return r ? std::string("<accepted>") : r.error().message;
}

static std::array<std::uint8_t, 4> at(const ViewImage& image, std::uint32_t x, std::uint32_t y) {
    std::size_t i = (static_cast<std::size_t>(y) * image.width + x) * 4;
    return {image.rgba[i], image.rgba[i + 1], image.rgba[i + 2], image.rgba[i + 3]};
}

// How many pixels differ between two frames of the same size.
static std::size_t changed(const ViewImage& a, const ViewImage& b) {
    if (a.rgba.size() != b.rgba.size()) return static_cast<std::size_t>(-1);
    std::size_t n = 0;
    for (std::size_t i = 0; i < a.rgba.size(); i += 4) {
        if (a.rgba[i] != b.rgba[i] || a.rgba[i + 1] != b.rgba[i + 1] || a.rgba[i + 2] != b.rgba[i + 2] ||
            a.rgba[i + 3] != b.rgba[i + 3])
            ++n;
    }
    return n;
}

static ViewImage frame_of(View& view) {
    auto image = view.image();
    CHECK(image, "image: %s", refused(image).c_str());
    return image ? *image : ViewImage{};
}

// A leaf below a root, with geometry: the node every node test draws.
static std::optional<cadaclysm::Node> nested_leaf(const cadaclysm::Scene& scene) {
    for (const cadaclysm::Node& n : scene.nodes())
        if (n.parent() && n.children().empty() && n.can_mesh()) return n;
    return std::nullopt;
}

// ---- the wgpu library's table, rigged: windows of its own forced offscreen, run faked ------

namespace spy {
CadaclysmView* (*real_create)(const CadaclysmViewWindow*, const CadaclysmViewOptions*) = nullptr;
std::string title;
std::uint32_t y_up = 9;
int runs = 0;
std::array<float, 3> eye{10, 0, 0}, up{0, 0, 1};
const char* said = nullptr;

CadaclysmView* create(const CadaclysmViewWindow* window, const CadaclysmViewOptions* o) {
    title = o->title ? o->title : "";
    y_up = o->y_up;
    CadaclysmViewOptions copy = *o;
    copy.offscreen = 1;
    if (!copy.width || !copy.height) {
        copy.width = 64;
        copy.height = 48;
    }
    return real_create(window, &copy);
}
// The pick answer run and pick_result hand back (item 0: nothing).
CadaclysmViewPick picked{};
// The window "closed" at once: the camera on `eye`, looking at the origin; the pick `picked`.
bool run(CadaclysmView*, CadaclysmViewCamera* camera, CadaclysmViewPick* pick) {
    ++runs;
    for (int i = 0; i < 3; ++i) {
        camera->eye[i] = eye[static_cast<std::size_t>(i)];
        camera->target[i] = 0;
        camera->up[i] = up[static_cast<std::size_t>(i)];
    }
    camera->orthographic = 0;
    *pick = picked;
    pick->size = sizeof *pick;
    return true;
}
const char* last_error() { return said; }
void request_pick_in(CadaclysmView*, std::uint32_t, std::uint32_t, std::uint32_t) {}
// pick_result: `picked` while `pick_landed`, else false with `said` ("no pick result" or a
// refusal of the library's own).
bool pick_landed = true;
bool pick_result(CadaclysmView*, CadaclysmViewPick* out) {
    if (!pick_landed) return false;
    *out = picked;
    out->size = sizeof *out;
    return true;
}
// What set_double_click_frames, focus and navigation were called with; navigation's answer.
std::string calls;
std::uint32_t navigation_answer = CADACLYSM_VIEW_NAVIGATION_ORBIT;
void set_double_click_frames(CadaclysmView*, bool on) { calls += on ? "frames on;" : "frames off;"; }
bool focus(CadaclysmView*, const float* p) {
    char text[96];
    std::snprintf(text, sizeof text, "focus %g %g %g;", p[0], p[1], p[2]);
    calls += text;
    if (!std::isfinite(p[0]) || !std::isfinite(p[1]) || !std::isfinite(p[2])) {
        said = "cadaclysm_view_focus: the point is not finite";
        return false;
    }
    said = nullptr;
    return true;
}
std::uint32_t navigation(CadaclysmView*) {
    calls += "navigation;";
    return navigation_answer;
}

bool refuse(CadaclysmView*, std::uint32_t) { return false; }
// pump: each call's wait, and the answers in call order (0: a failure saying "pump broke";
// past the list: open).
std::vector<std::uint32_t> pump_ms, pump_answers;
std::uint32_t pump(CadaclysmView*, std::uint32_t ms) {
    std::size_t call = pump_ms.size();
    pump_ms.push_back(ms);
    std::uint32_t answer = call < pump_answers.size() ? pump_answers[call] : CADACLYSM_VIEW_OPEN;
    said = answer == 0 ? "pump broke" : nullptr;
    return answer;
}
std::uint32_t input_answer = 0;
std::uint32_t input(CadaclysmView*, const CadaclysmViewEvent*) { return input_answer; }
// show: the first scene shown for real, every later one answered with that item's id (a
// library that reuses an id).
std::uint32_t (*real_show)(CadaclysmView*, const CadaclysmScene*) = nullptr;
std::uint32_t same_id = 0;
std::uint32_t show_same(CadaclysmView* v, const CadaclysmScene* scene) {
    if (!same_id) same_id = real_show(v, scene);
    return same_id;
}
}  // namespace spy

// ---- view ABI 1.11's points, on the stand-in's table: what show_points hands the library ----

namespace points {
int view_stand_in;  // the stand-in view's address
CadaclysmView* create(const CadaclysmViewWindow*, const CadaclysmViewOptions*) {
    return reinterpret_cast<CadaclysmView*>(&view_stand_in);
}
// Enough of the library's colour text: "red".
bool parse_colour(const char* text, float* rgb) {
    if (std::string(text) != "red") return false;
    rgb[0] = 1;
    rgb[1] = 0;
    rgb[2] = 0;
    return true;
}
// What the last show_points was handed, and how many calls reached it.
std::vector<float> positions;
std::uint32_t count = 0;
int calls = 0;
bool rgb_null = true;
std::array<float, 3> rgb{};
float size = 0;
std::uint32_t show_points(CadaclysmView*, const float* p, std::uint32_t n, const float* c, float size_px) {
    ++calls;
    positions.assign(p, p + 3 * static_cast<std::size_t>(n));
    count = n;
    rgb_null = c == nullptr;
    rgb = c ? std::array<float, 3>{c[0], c[1], c[2]} : std::array<float, 3>{};
    size = size_px;
    return 17;
}
}  // namespace points

// ---- view ABI 1.22's snapping, on the wgpu table rigged: what set_snap and the work plane get --

namespace snapspy {
CadaclysmViewSnapSettings settings{};
int sets = 0;
std::string calls;  // request_snap_in, clear_snap and the work plane calls, in order
CadaclysmViewSnap answer{};
bool landed = true;  // snap_result answers `answer`; else false, spy::said saying why
bool set_snap(CadaclysmView*, const CadaclysmViewSnapSettings* s) {
    settings = *s;
    ++sets;
    return true;
}
void request_snap_in(CadaclysmView*, std::uint32_t viewport, std::uint32_t x, std::uint32_t y) {
    calls += "snap " + std::to_string(viewport) + " " + std::to_string(x) + " " + std::to_string(y) + ";";
}
// `answer`, up to the caller's size as the library writes it.
bool snap_result(CadaclysmView*, CadaclysmViewSnap* out) {
    if (!landed) return false;
    CadaclysmViewSnap a = answer;
    a.size = out->size;
    std::memcpy(out, &a, out->size < sizeof a ? out->size : sizeof a);
    return true;
}
void clear_snap(CadaclysmView*) { calls += "clear;"; }
bool set_work_plane(CadaclysmView*, const double* o, const double* x, const double* n, double step) {
    char text[192];
    std::snprintf(text, sizeof text, "plane %g %g %g, %g %g %g, %g %g %g, %g;", o[0], o[1], o[2], x[0], x[1], x[2], n[0],
                  n[1], n[2], step);
    calls += text;
    return true;
}
bool clear_work_plane(CadaclysmView*) {
    calls += "ground;";
    return true;
}
}  // namespace snapspy

// A colour is three or four numbers or text: two numbers do not compile.
static_assert(!std::is_constructible<cadaclysm::Colour, float, float>::value, "Colour(r, g) compiles");

// The points facts: (0,0,0) and (1,2,3) in "red" at 12 reach the library as six floats, a
// count of 2, rgb (1,0,0) and 12.0, and an item comes back; one point with no colour and no
// size is rgb NULL and 8.0; four numbers are refused before the library.
static void points_case(const cadaclysm::ViewLibrary& stand_in) {
    CvlTable& t = const_cast<CvlTable&>(cadaclysm::detail::ViewAccess::table(stand_in));
    const CvlTable saved = t;
    t.create = &points::create;
    t.parse_colour = &points::parse_colour;
    t.show_points = &points::show_points;
    {
        auto made = View::offscreen(8, 8);
        CHECK(made, "a view on the stand-in: %s", refused(made).c_str());
        if (made) {
            auto item = made->show_points({0, 0, 0, 1, 2, 3}, std::string("red"), 12.0f);
            CHECK(item && item->id() == 17, "show_points: %s", refused(item).c_str());
            CHECK(points::calls == 1 && (points::positions == std::vector<float>{0, 0, 0, 1, 2, 3}) && points::count == 2,
                  "the library got %d calls, %u points", points::calls, points::count);
            CHECK(!points::rgb_null && points::rgb == (std::array<float, 3>{1, 0, 0}) && points::size == 12.0f,
                  "red at 12 reached the library as rgb %s(%g, %g, %g), size %g", points::rgb_null ? "NULL " : "",
                  points::rgb[0], points::rgb[1], points::rgb[2], points::size);
            auto plain = made->show_points({1, 2, 3});
            CHECK(plain && plain->id() == 17, "one point: %s", refused(plain).c_str());
            CHECK(points::calls == 2 && (points::positions == std::vector<float>{1, 2, 3}) && points::count == 1 &&
                      points::rgb_null && points::size == 8.0f,
                  "no colour and no size reached the library as rgb %s, size %g", points::rgb_null ? "NULL" : "given",
                  points::size);
            auto four = made->show_points({1, 2, 3, 4});
            CHECK(!four && refused(four) == "show_points: three numbers a point, not 4", "four numbers: %s",
                  four ? "accepted" : refused(four).c_str());
            CHECK(points::calls == 2, "a refused show_points reached the library");
            CHECK(made->close(), "close the stand-in's view");
        }
    }
    t = saved;
}

// ---- view ABI 1.7's machining view and timeline, on the stand-in's table -------------------

namespace mach {
int view_stand_in;  // the stand-in view's address
CadaclysmView* create(const CadaclysmViewWindow*, const CadaclysmViewOptions*) {
    return reinterpret_cast<CadaclysmView*>(&view_stand_in);
}
const char* said = nullptr;
const char* last_error() { return said; }
// What the last show_machining was handed (copied: the arrays are the caller's), and how many
// calls reached it.
int shows = 0;
std::uint32_t show_id = 7;  // 0 refuses
std::uint32_t program_count = 0, struct_size = 0;
struct Program {
    std::uint32_t size, number, shape;
    double diameter, flute, angle, corner;
    std::string gcode;
};
std::vector<Program> programs;
std::array<double, 6> stock{};
std::uint32_t part_vertices = 0, part_indices = 0;
std::vector<float> part_positions;
std::vector<std::uint32_t> part_index_values;
double cell = -1, tolerance = -1, skin = -1, rapid_rate = -1;
std::uint32_t skin_set = 9;
std::uint32_t show_machining(CadaclysmView*, const CadaclysmViewMachining* m) {
    ++shows;
    struct_size = m->size;
    program_count = m->program_count;
    programs.clear();
    for (std::uint32_t k = 0; k < m->program_count; ++k) {
        const CadaclysmViewProgram& p = m->programs[k];
        programs.push_back({p.size, p.tool_number, p.tool_shape, p.tool_diameter, p.tool_flute_length, p.tool_angle,
                            p.tool_corner_radius, p.gcode});
    }
    stock = {m->stock_min[0], m->stock_min[1], m->stock_min[2], m->stock_max[0], m->stock_max[1], m->stock_max[2]};
    part_vertices = m->part_vertex_count;
    part_indices = m->part_index_count;
    part_positions.assign(m->part_positions, m->part_positions + 3 * static_cast<std::size_t>(m->part_vertex_count));
    part_index_values.assign(m->part_indices, m->part_indices + m->part_index_count);
    cell = m->cell;
    tolerance = m->tolerance;
    skin = m->skin;
    skin_set = m->skin_set;
    rapid_rate = m->rapid_rate;
    return show_id;
}
// Every other call: noted, answering true (false while `answer` is false).
std::string calls;
bool answer = true;
bool seek(CadaclysmView*, std::uint32_t id, std::uint32_t to) {
    calls += "seek " + std::to_string(id) + " " + std::to_string(to) + ";";
    return answer;
}
bool colour_by(CadaclysmView*, std::uint32_t id, std::uint32_t mode) {
    calls += "colour_by " + std::to_string(id) + " " + std::to_string(mode) + ";";
    return answer;
}
bool overlays(CadaclysmView*, std::uint32_t id, bool path, bool tool) {
    calls += "overlays " + std::to_string(id) + (path ? " on" : " off") + (tool ? " on;" : " off;");
    return answer;
}
bool info(CadaclysmView*, std::uint32_t, CadaclysmViewMachiningInfo* out) {
    calls += "info;";
    out->moves = 9;
    out->move = 3;
    out->nx = 4;
    out->ny = 2;
    out->cell = 0.5f;
    out->min[0] = -1;
    out->min[1] = -2;
    out->cycle_time = 12.5;
    return answer;
}
std::size_t heights_capacity = 0;
bool heights(CadaclysmView*, std::uint32_t, float* z, std::size_t capacity) {
    heights_capacity = capacity;
    for (std::size_t k = 0; k < capacity; ++k) z[k] = static_cast<float>(k);
    return answer;
}
bool play(CadaclysmView*, double speed) {
    calls += "play " + std::to_string(speed) + ";";
    return answer;
}
bool pause(CadaclysmView*) {
    calls += "pause;";
    return answer;
}
bool seek_time(CadaclysmView*, double seconds) {
    calls += "seek_time " + std::to_string(seconds) + ";";
    return answer;
}
bool set_loop(CadaclysmView*, bool on) {
    calls += on ? "loop on;" : "loop off;";
    return answer;
}
double time(const CadaclysmView*) { return 1.5; }
double duration(const CadaclysmView*) { return 12.5; }
bool playing(const CadaclysmView*) { return true; }
// status: line `asked` (clamped to the last) of `lines`, its length answered, and as much of it as fits copied.
std::vector<std::string> lines;
std::size_t asked = 0;
std::size_t status(const CadaclysmView*, char* text, std::size_t capacity) {
    const std::string& line = lines[std::min(asked, lines.size() - 1)];
    ++asked;
    if (text && capacity > 0) {
        std::size_t room = std::min(line.size(), capacity - 1);
        std::memcpy(text, line.data(), room);
        text[room] = '\0';
    }
    return line.size();
}
bool remove(CadaclysmView*, std::uint32_t) { return true; }
}  // namespace mach

static_assert(std::is_base_of<cadaclysm::Item, cadaclysm::Machining>::value, "a Machining is an Item");

static cadaclysm::MachiningTool tool_of(std::uint32_t number, const char* shape, double diameter, double flute = 0,
                                        double angle = 0) {
    cadaclysm::MachiningTool tool;
    tool.number = number;
    tool.shape = shape;
    tool.diameter = diameter;
    tool.flute_length = flute;
    tool.angle = angle;
    return tool;
}

// The machining facts (F1-F6) on the stand-in's table, rigged and put back: the struct that
// reaches the library; the defaults a bare call leaves it; what is refused before it; the
// transport and the machining's own calls; status asking again when the line grew; the
// library's words for a refusal.
static void machining_case(const cadaclysm::ViewLibrary& stand_in) {
    CvlTable& t = const_cast<CvlTable&>(cadaclysm::detail::ViewAccess::table(stand_in));
    const CvlTable saved = t;
    t.create = &mach::create;
    t.last_error = &mach::last_error;
    t.show_machining = &mach::show_machining;
    t.machining_seek = &mach::seek;
    t.machining_colour_by = &mach::colour_by;
    t.machining_overlays = &mach::overlays;
    t.machining_info = &mach::info;
    t.machining_heights = &mach::heights;
    t.timeline_play = &mach::play;
    t.timeline_pause = &mach::pause;
    t.timeline_seek = &mach::seek_time;
    t.timeline_set_loop = &mach::set_loop;
    t.timeline_time = &mach::time;
    t.timeline_duration = &mach::duration;
    t.timeline_playing = &mach::playing;
    t.timeline_status = &mach::status;
    t.remove = &mach::remove;
    {
        cadaclysm::Result<View> made = View::offscreen(8, 8);
        CHECK(made, "a view on the stand-in: %s", refused(made).c_str());
        if (made) {
            cadaclysm::MachiningStock box;
            box.min = {-1, -2, 0};
            box.max = {1, 2, 3};
            std::vector<cadaclysm::MachiningProgram> two = {{tool_of(1, "flat", 6, 20), "G0 X0\n"},
                                                           {tool_of(3, "vbit", 6, 0, 60), "G0 X1\n"}};

            // F1: the struct reaches the library.
            cadaclysm::MachiningPart part;
            part.positions = {0, 0, 0, 1, 0, 0, 0, 1, 0};
            part.indices = {0, 1, 2};
            cadaclysm::MachiningOptions options;
            options.cell = 0.25;
            options.skin = 0.0;
            cadaclysm::Result<cadaclysm::Machining> m = made->show_machining(two, box, part, options);
            CHECK(m && m->id() == 7, "show_machining: %s", refused(m).c_str());
            CHECK(mach::shows == 1 && mach::program_count == 2 && mach::struct_size == 128, "F1: %d calls, %u programs, size %u",
                  mach::shows, mach::program_count, mach::struct_size);
            if (mach::programs.size() == 2) {
                const mach::Program& a = mach::programs[0];
                const mach::Program& b = mach::programs[1];
                CHECK(a.size == 56 && a.number == 1 && a.shape == 0 && a.diameter == 6 && a.flute == 20 && a.angle == 0 &&
                          a.corner == 0 && a.gcode == "G0 X0\n",
                      "F1 program 0");
                CHECK(b.size == 56 && b.number == 3 && b.shape == 3 && b.diameter == 6 && b.flute == 0 && b.angle == 60 &&
                          b.corner == 0 && b.gcode == "G0 X1\n",
                      "F1 program 1");
            }
            CHECK((mach::stock == std::array<double, 6>{-1, -2, 0, 1, 2, 3}), "F1 stock");
            CHECK(mach::part_vertices == 3 && mach::part_indices == 3 &&
                      mach::part_positions == std::vector<float>({0, 0, 0, 1, 0, 0, 0, 1, 0}) &&
                      mach::part_index_values == std::vector<std::uint32_t>({0, 1, 2}),
                  "F1 part");
            CHECK(mach::cell == 0.25 && mach::tolerance == 0 && mach::skin_set == 1 && mach::skin == 0 && mach::rapid_rate == 0,
                  "F1 options: cell %g tolerance %g skin_set %u skin %g rapid %g", mach::cell, mach::tolerance,
                  mach::skin_set, mach::skin, mach::rapid_rate);

            // F2: a bare call leaves every default to the library.
            cadaclysm::Result<cadaclysm::Machining> bare = made->show_machining({{tool_of(1, "flat", 6), "G0"}}, box);
            CHECK(bare, "bare show_machining: %s", refused(bare).c_str());
            CHECK(mach::skin_set == 0 && mach::part_vertices == 0 && mach::part_indices == 0 && mach::cell == 0 &&
                      mach::tolerance == 0 && mach::rapid_rate == 0,
                  "F2: skin_set %u, part %u/%u, cell %g", mach::skin_set, mach::part_vertices, mach::part_indices, mach::cell);

            // F3: refused before the library.
            int shows = mach::shows;
            std::string spade = refused(made->show_machining({{tool_of(1, "spade", 6), "G0"}}, box));
            CHECK(spade == "shape 'spade': one of flat, ball, drill, vbit, bullnose", "shape: %s", spade.c_str());
            cadaclysm::MachiningPart four;
            four.positions = {0, 0, 0, 1};
            CHECK(refused(made->show_machining({{tool_of(1, "flat", 6), "G0"}}, box, four)) ==
                      "part positions: 4 numbers is not a whole number of x y z triples",
                  "positions: %s", refused(made->show_machining({{tool_of(1, "flat", 6), "G0"}}, box, four)).c_str());
            cadaclysm::MachiningPart two_indices;
            two_indices.positions = {0, 0, 0};
            two_indices.indices = {0, 0};
            CHECK(refused(made->show_machining({{tool_of(1, "flat", 6), "G0"}}, box, two_indices)) ==
                      "part indices: 2 is not a whole number of triangles",
                  "indices: %s", refused(made->show_machining({{tool_of(1, "flat", 6), "G0"}}, box, two_indices)).c_str());
            cadaclysm::MachiningPart past;
            past.positions = {0, 0, 0, 1, 0, 0, 0, 1, 0};
            past.indices = {0, 1, 3};
            CHECK(refused(made->show_machining({{tool_of(1, "flat", 6), "G0"}}, box, past)) ==
                      "part indices: 3 is past the last of 3 vertices",
                  "past: %s", refused(made->show_machining({{tool_of(1, "flat", 6), "G0"}}, box, past)).c_str());
            cadaclysm::MachiningPart nan_part;
            nan_part.positions = {0, 0, std::nanf("")};
            CHECK(!made->show_machining({{tool_of(1, "flat", 6), "G0"}}, box, nan_part), "a NaN position was accepted");
            cadaclysm::MachiningOptions nan_options;
            nan_options.cell = std::nan("");
            CHECK(!made->show_machining({{tool_of(1, "flat", 6), "G0"}}, box, std::nullopt, nan_options),
                  "a NaN cell was accepted");
            cadaclysm::MachiningStock nan_box = box;
            nan_box.max[2] = std::nan("");
            CHECK(!made->show_machining({{tool_of(1, "flat", 6), "G0"}}, nan_box), "a NaN stock was accepted");
            CHECK(!made->show_machining({{tool_of(1, "flat", std::nan("")), "G0"}}, box), "a NaN diameter was accepted");
            CHECK(!made->play(std::nan("")) && !made->seek(INFINITY), "a non-finite speed or time was accepted");
            CHECK(mach::shows == shows, "a refused show_machining reached the library");

            // F4: the machining's own calls and the transport.
            if (m) {
                mach::calls.clear();
                CHECK(made->play(4), "play");
                CHECK(made->pause(), "pause");
                CHECK(made->seek(2.0), "seek");
                CHECK(made->loop(), "loop");
                CHECK(made->loop(false), "loop off");
                CHECK(m->seek_move(3), "seek_move");
                CHECK(m->colour_by("tool"), "colour_by tool");
                CHECK(m->colour_by("deviation"), "colour_by deviation");
                CHECK(m->overlays(false), "overlays");
                CHECK(mach::calls == "play 4.000000;pause;seek_time 2.000000;loop on;loop off;seek 7 3;colour_by 7 1;"
                                     "colour_by 7 2;overlays 7 off on;",
                      "the calls: %s", mach::calls.c_str());
                CHECK(refused(m->colour_by("rainbow")) == "mode 'rainbow': one of height, tool, deviation", "mode: %s",
                      refused(m->colour_by("rainbow")).c_str());
                cadaclysm::Result<double> time = made->time();
                cadaclysm::Result<double> duration = made->duration();
                cadaclysm::Result<bool> playing = made->playing();
                CHECK(time && *time == 1.5 && duration && *duration == 12.5 && playing && *playing, "time, duration, playing");
                mach::lines = {"move 3 of 9 \xC2\xB7 T1 flat 6 mm"};
                mach::asked = 0;
                cadaclysm::Result<std::vector<std::string>> status = made->status();
                CHECK(status && status->size() == 1 && (*status)[0] == mach::lines[0], "status: %s",
                      status ? (*status)[0].c_str() : refused(status).c_str());
                cadaclysm::Result<cadaclysm::MachiningInfo> info = m->info();
                CHECK(info && info->moves == 9 && info->move == 3 && info->nx == 4 && info->ny == 2 && info->cell == 0.5f &&
                          info->min[0] == -1 && info->min[1] == -2 && info->cycle_time == 12.5,
                      "info: %s", refused(info).c_str());
                cadaclysm::Result<std::vector<float>> z = m->heights();
                CHECK(z && z->size() == 8 && mach::heights_capacity == 8 && (*z)[1 * 4 + 0] == 4.0f, "heights: %s",
                      refused(z).c_str());

                // F5: status asks again when the line grew, and is empty with no tracks.
                mach::lines = {"move 9 of 9", "move 10 of 10 \xC2\xB7 longer"};
                mach::asked = 0;
                cadaclysm::Result<std::vector<std::string>> grown = made->status();
                CHECK(grown && grown->size() == 1 && (*grown)[0] == mach::lines[1] && mach::asked == 3,
                      "F5: asked %zu times", mach::asked);
                mach::lines = {""};
                mach::asked = 0;
                cadaclysm::Result<std::vector<std::string>> none = made->status();
                CHECK(none && none->empty(), "an empty status");
                mach::lines = {"move 9 of 9", ""};  // the line emptied between the two calls
                mach::asked = 0;
                cadaclysm::Result<std::vector<std::string>> emptied = made->status();
                CHECK(emptied && emptied->empty() && mach::asked == 2, "an emptied status: %zu lines, asked %zu",
                      emptied ? emptied->size() : 0, mach::asked);

                // F6: a library refusal is the library's words.
                mach::answer = false;
                mach::said = "cadaclysm_view_machining_seek: no machining 9 is shown";
                CHECK(refused(m->seek_move(3)) == mach::said, "seek_move refusal: %s", refused(m->seek_move(3)).c_str());
                mach::answer = true;
                CHECK(m->remove(), "remove");
            }
            mach::show_id = 0;
            mach::said = "cadaclysm_view_show_machining: a machining needs at least one program (program_count is 0)";
            CHECK(refused(made->show_machining({}, box)) == mach::said, "show_machining refusal: %s",
                  refused(made->show_machining({}, box)).c_str());
            mach::show_id = 7;
            mach::said = nullptr;
            CHECK(made->close(), "close the stand-in's view");
            CHECK(refused(made->play()) == "cadaclysm_view_timeline_play: the view is closed", "closed: %s",
                  refused(made->play()).c_str());
        }
    }
    t = saved;
}

// What show()/view() hand the library (the title, the up axis), what view() and run()
// answer, and the void calls' refusals -- through the loaded table, rigged and put back.
static void rigged_half(View& view, const cadaclysm::ViewLibrary& wgpu, const std::string& mechanism) {
    CvlTable& t = const_cast<CvlTable&>(cadaclysm::detail::ViewAccess::table(wgpu));
    const CvlTable saved = t;
    spy::real_create = saved.create;
    t.create = &spy::create;
    t.run = &spy::run;

    // A void call that left a last error refused with it; a silent refusal in Python's words.
    t.last_error = &spy::last_error;
    spy::said = "boom from the library";
    CHECK(refused(view.orbit(1, 1)) == "boom from the library", "orbit: %s", refused(view.orbit(1, 1)).c_str());
    CHECK(refused(view.pan(1, 1)) == "boom from the library", "pan");
    CHECK(refused(view.zoom(1)) == "boom from the library", "zoom");
    CHECK(refused(view.look(1, 1)) == "boom from the library", "look");
    CHECK(refused(view.dolly(1)) == "boom from the library", "dolly");
    CHECK(refused(view.orthographic(false)) == "boom from the library", "orthographic");
    CHECK(refused(view.background({0, 0, 0})) == "boom from the library", "background");
    spy::said = nullptr;
    CHECK(view.orbit(0, 0), "a void call with no last error was refused");
    t.frame = &spy::refuse;
    CHECK(refused(view.frame()) == "the view library failed", "a silent refusal: %s", refused(view.frame()).c_str());
    t.frame = saved.frame;

    // Windows of their own (forced offscreen): pump's waits, its failures and its count; input.
    t.pump = &spy::pump;
    t.input = &spy::input;
    {
        auto a = View::create();
        auto b = View::create();
        CHECK(a && b, "two windows of their own: %s / %s", refused(a).c_str(), refused(b).c_str());
        if (a && b) {
            spy::pump_ms.clear();
            spy::pump_answers = {0, CADACLYSM_VIEW_CLOSED};
            auto failed = cadaclysm::view::pump(1.0);
            CHECK(refused(failed) == "pump broke", "a failed pump: %s", refused(failed).c_str());
            CHECK(spy::pump_ms.size() == 2 && spy::pump_ms[0] == 1000 && spy::pump_ms[1] == 0,
                  "every window pumped, the wait on the first: %zu calls", spy::pump_ms.size());
            CHECK(b->closed() && !a->closed(), "CLOSED did not close the second, or the failure closed the first");
            spy::pump_answers.clear();
            const double waits[] = {-1.0, 1e12, std::nan("")};
            const std::uint32_t expected[] = {0u, 0xFFFFFFFFu, 0u};
            // With no window of this thread's own pump would sleep the wait: not with these.
            for (int i = 0; i < 3 && !a->closed(); ++i) {
                spy::pump_ms.clear();
                auto open = cadaclysm::view::pump(waits[i]);
                CHECK(open && *open == 1, "the failed window is still open and counted: %s",
                      open ? std::to_string(*open).c_str() : refused(open).c_str());
                CHECK(spy::pump_ms.size() == 1 && spy::pump_ms[0] == expected[i], "pump(%g) waited %u ms", waits[i],
                      spy::pump_ms.empty() ? 0u : spy::pump_ms[0]);
            }
            cadaclysm::ViewEvent key;
            key.kind = CADACLYSM_VIEW_EVENT_KEY;
            key.key = "Escape";
            spy::input_answer = 0;
            spy::said = "input broke";
            CHECK(refused(a->input(key)) == "input broke", "input's refusal: %s", refused(a->input(key)).c_str());
            spy::said = nullptr;
            spy::input_answer = CADACLYSM_VIEW_INPUT_CLOSE;
            auto bits = a->input(key);
            CHECK(bits && *bits == CADACLYSM_VIEW_INPUT_CLOSE && a->closed(), "Escape did not close a window of its own");
            CHECK(a->close() && b->close(), "close both");
            CHECK(refused(a->needs_draw()) == "cadaclysm_view_needs_draw: the view is closed", "%s",
                  refused(a->needs_draw()).c_str());
            CHECK(refused(a->input(key)) == "cadaclysm_view_input: the view is closed", "%s", refused(a->input(key)).c_str());
        }
    }
    t.pump = saved.pump;
    t.input = saved.input;
    t.last_error = saved.last_error;

    // An id the library hands out again replaces what that item kept: the scene it lets go of
    // (its last owner) closes, and its close comes back for the views' lock -- after the
    // replacement has let go of it, not under it (else this deadlocks).
    t.show = &spy::show_same;
    spy::real_show = saved.show;
    spy::same_id = 0;
    {
        std::weak_ptr<const void> first;
        cadaclysm::Result<cadaclysm::Item> a = cadaclysm::Error{"not shown"};
        cadaclysm::Result<cadaclysm::Item> b = cadaclysm::Error{"not shown"};
        {
            auto doc = cadaclysm::open(mechanism);
            if (doc) {
                first = cadaclysm::detail::ViewAccess::keep(*doc);
                a = view.show(*doc);
            }
        }
        {
            auto doc = cadaclysm::open(mechanism);
            if (doc) b = view.show(*doc);
        }
        CHECK(a && b && a->id() == b->id(), "the same id twice: %s / %s", refused(a).c_str(), refused(b).c_str());
        CHECK(first.expired(), "the replaced item's scene is still kept");
        if (b) CHECK(b->remove(), "remove the reused id");
    }
    t.show = saved.show;

    // 1.8: a pick and run's pick carry clicks, and the point only where the library set one;
    // set_double_click_frames, focus and navigation reach the library with their arguments.
    t.request_pick_in = &spy::request_pick_in;
    t.pick_result = &spy::pick_result;
    t.set_double_click_frames = &spy::set_double_click_frames;
    t.focus = &spy::focus;
    t.navigation = &spy::navigation;
    t.last_error = &spy::last_error;
    spy::said = nullptr;
    {
        spy::picked = CadaclysmViewPick{};
        spy::picked.item = 3;
        spy::picked.node = 4;
        spy::picked.face = 5;
        spy::picked.clicks = 2;
        spy::picked.has_point = 1;
        spy::picked.point[0] = 1.5f;
        spy::picked.point[1] = -2.0f;
        spy::picked.point[2] = 0.25f;
        auto hit = view.pick(1, 1);
        CHECK(hit && hit->item == 3 && hit->node == 4 && hit->face == 5 && hit->clicks == 2 && hit->point &&
                  *hit->point == (std::array<float, 3>{1.5f, -2.0f, 0.25f}),
              "a double click's hit: %s", refused(hit).c_str());
        spy::picked.clicks = 1;
        spy::picked.has_point = 0;
        auto flat = view.pick(1, 1);
        CHECK(flat && flat->clicks == 1 && !flat->point, "has_point 0: the point bytes mean nothing");

        // last_pick: what landed, as pick_result wrote it; nothing yet; a click on nothing;
        // the library's own refusal.
        spy::picked.clicks = 2;
        spy::picked.has_point = 1;
        cadaclysm::Result<std::optional<cadaclysm::ViewPick>> landed = view.last_pick();
        CHECK(landed && *landed && (*landed)->item == 3 && (*landed)->node == 4 && (*landed)->face == 5 &&
                  (*landed)->clicks == 2 && (*landed)->point &&
                  *(*landed)->point == (std::array<float, 3>{1.5f, -2.0f, 0.25f}),
              "last_pick, landed: %s", refused(landed).c_str());
        spy::pick_landed = false;
        spy::said = "cadaclysm_view_pick_result: no pick result";
        cadaclysm::Result<std::optional<cadaclysm::ViewPick>> waiting = view.last_pick();
        CHECK(waiting && !*waiting, "last_pick, nothing landed yet: %s", refused(waiting).c_str());
        spy::said = nullptr;
        cadaclysm::Result<std::optional<cadaclysm::ViewPick>> quiet = view.last_pick();
        CHECK(quiet && !*quiet, "last_pick, nothing landed and nothing said: %s", refused(quiet).c_str());
        spy::said = "boom from pick_result";
        cadaclysm::Result<std::optional<cadaclysm::ViewPick>> broke = view.last_pick();
        CHECK(refused(broke) == "boom from pick_result", "last_pick, a refusal: %s", refused(broke).c_str());
        spy::said = nullptr;
        spy::pick_landed = true;
        spy::picked = CadaclysmViewPick{};
        spy::picked.clicks = 1;
        cadaclysm::Result<std::optional<cadaclysm::ViewPick>> miss = view.last_pick();
        CHECK(miss && *miss && (*miss)->item == 0 && (*miss)->clicks == 1 && !(*miss)->point,
              "last_pick, a click on nothing: %s", refused(miss).c_str());
        spy::picked.item = 3;
        spy::picked.node = 4;
        spy::picked.face = 5;
        spy::picked.item = 7;
        spy::picked.clicks = 2;
        auto own = View::offscreen(32, 32);
        CHECK(own, "offscreen: %s", refused(own).c_str());
        if (own) {
            auto camera = own->run();
            CHECK(camera && camera->pick && camera->pick->item == 7 && camera->pick->clicks == 2 && !camera->pick->point,
                  "run's pick: %s", refused(camera).c_str());
        }
        spy::picked = CadaclysmViewPick{};

        spy::calls.clear();
        CHECK(view.set_double_click_frames(true) && view.set_double_click_frames(false), "set_double_click_frames");
        CHECK(view.focus({1.0f, -2.0f, 3.5f}), "focus");
        auto orbit = view.navigation();
        spy::navigation_answer = CADACLYSM_VIEW_NAVIGATION_FLY;
        auto fly = view.navigation();
        spy::navigation_answer = CADACLYSM_VIEW_NAVIGATION_ORBIT;
        CHECK(orbit && *orbit == cadaclysm::Navigation::orbit && fly && *fly == cadaclysm::Navigation::fly,
              "navigation: orbit then fly");
        CHECK(spy::calls == "frames on;frames off;focus 1 -2 3.5;navigation;navigation;", "the library saw %s",
              spy::calls.c_str());
        const std::string not_finite = refused(view.focus({std::nanf(""), 0.0f, 0.0f}));
        CHECK(not_finite == "cadaclysm_view_focus: the point is not finite", "a point not finite: %s",
              not_finite.c_str());
        spy::said = nullptr;
    }
    t.request_pick_in = saved.request_pick_in;
    t.pick_result = saved.pick_result;
    t.set_double_click_frames = saved.set_double_click_frames;
    t.focus = saved.focus;
    t.navigation = saved.navigation;
    t.last_error = saved.last_error;
    // 1.22's snapping, rigged: set_snap's bits, aperture and marker (an unknown kind refused
    // before the library); snap's request and its answer whole (no edge for a face snap, kind ""
    // for nothing); last_snap; clear_snap and the work plane's arrays, and the ground plane back.
    t.last_error = &spy::last_error;
    t.set_snap = &snapspy::set_snap;
    t.request_snap_in = &snapspy::request_snap_in;
    t.snap_result = &snapspy::snap_result;
    t.clear_snap = &snapspy::clear_snap;
    t.set_work_plane = &snapspy::set_work_plane;
    t.clear_work_plane = &snapspy::clear_work_plane;
    {
        spy::said = nullptr;
        cadaclysm::Result<void> all = view.set_snap();
        CHECK(all && snapspy::settings.size == 16 && snapspy::settings.kinds == 0xFFu &&
                  snapspy::settings.aperture_px == 0.0f && snapspy::settings.marker == 1u,
              "set_snap(): %s, kinds 0x%x marker %u", refused(all).c_str(), snapspy::settings.kinds,
              snapspy::settings.marker);
        cadaclysm::Result<void> two = view.set_snap(std::vector<std::string>{"vertex", "edge"}, 6.0f, false);
        CHECK(two && snapspy::settings.kinds == 0x11u && snapspy::settings.aperture_px == 6.0f &&
                  snapspy::settings.marker == 0u,
              "set_snap(vertex, edge): %s, kinds 0x%x", refused(two).c_str(), snapspy::settings.kinds);
        CHECK(view.set_snap(std::vector<std::string>{"face"}) && snapspy::settings.kinds == 32u, "one kind alone");
        CHECK(view.set_snap(std::nullopt) && snapspy::settings.kinds == 0u, "nullopt switches snapping off");
        const int before = snapspy::sets;
        const std::string corner = refused(view.set_snap(std::vector<std::string>{"vertex", "corner"}));
        CHECK(corner == "snap kind 'corner': one of vertex, midpoint, centre, quadrant, edge, face, grid, plane" &&
                  snapspy::sets == before,
              "an unknown kind: %s", corner.c_str());

        snapspy::calls.clear();
        snapspy::answer = CadaclysmViewSnap{};
        snapspy::answer.kind = CADACLYSM_VIEW_SNAP_VERTEX;
        snapspy::answer.point[0] = -1.0;
        snapspy::answer.point[1] = 1.0;
        snapspy::answer.item = 3;
        snapspy::answer.node = 4;
        snapspy::answer.face = 5;
        snapspy::answer.edge = 2;
        snapspy::answer.tangent[0] = 1.0f;
        snapspy::answer.distance_px = 2.5f;
        cadaclysm::Result<cadaclysm::ViewSnap> vertex = view.snap(10, 20, 1);
        const bool whole = vertex && vertex->kind == "vertex" && vertex->point[0] == -1.0 && vertex->point[1] == 1.0 &&
                           vertex->point[2] == 0.0 && vertex->item == 3 && vertex->node == 4 && vertex->face == 5 &&
                           vertex->edge && *vertex->edge == 2 && vertex->tangent[0] == 1.0f &&
                           vertex->distance_px == 2.5f && vertex->clicks == 0;
        CHECK(whole, "the vertex snap: %s", vertex ? vertex->kind.c_str() : refused(vertex).c_str());
        CHECK(snapspy::calls == "snap 1 10 20;", "snap asked %s", snapspy::calls.c_str());
        snapspy::answer = CadaclysmViewSnap{};
        snapspy::answer.kind = CADACLYSM_VIEW_SNAP_CENTRE;
        snapspy::answer.axis[2] = 1.0f;
        snapspy::answer.radius = 2.5;
        cadaclysm::Result<cadaclysm::ViewSnap> centre = view.snap(1, 1);
        CHECK(centre && centre->kind == "centre" && centre->axis[2] == 1.0f && centre->radius == 2.5,
              "the centre snap: %s", centre ? centre->kind.c_str() : refused(centre).c_str());
        snapspy::answer = CadaclysmViewSnap{};
        snapspy::answer.kind = CADACLYSM_VIEW_SNAP_FACE;
        snapspy::answer.item = 3;
        snapspy::answer.edge = 0xFFFFFFFFu;
        cadaclysm::Result<cadaclysm::ViewSnap> face = view.snap(1, 1);
        CHECK(face && face->kind == "face" && !face->edge, "a face snap has no edge: %s",
              face ? face->kind.c_str() : refused(face).c_str());
        snapspy::answer = CadaclysmViewSnap{};
        cadaclysm::Result<cadaclysm::ViewSnap> nothing = view.snap(1, 1);
        CHECK(nothing && nothing->kind.empty(), "kind 0 is nothing snapped: %s",
              nothing ? nothing->kind.c_str() : refused(nothing).c_str());

        snapspy::answer.kind = CADACLYSM_VIEW_SNAP_EDGE;
        snapspy::answer.clicks = 1;
        cadaclysm::Result<std::optional<cadaclysm::ViewSnap>> landed = view.last_snap();
        CHECK(landed && *landed && (*landed)->kind == "edge" && (*landed)->clicks == 1, "last_snap, landed: %s",
              refused(landed).c_str());
        snapspy::landed = false;
        spy::said = "cadaclysm_view_snap_result: no snap result";
        cadaclysm::Result<std::optional<cadaclysm::ViewSnap>> waiting = view.last_snap();
        CHECK(waiting && !*waiting, "last_snap, nothing landed yet: %s", refused(waiting).c_str());
        spy::said = "boom from snap_result";
        cadaclysm::Result<std::optional<cadaclysm::ViewSnap>> broke = view.last_snap();
        CHECK(refused(broke) == "boom from snap_result", "last_snap, a refusal: %s", refused(broke).c_str());
        spy::said = nullptr;
        snapspy::landed = true;

        CHECK(view.clear_snap(), "clear_snap");
        CHECK(view.set_work_plane(std::array<double, 3>{1, 2, 3}, {1, 0, 0}, {0, 0, 1}, 0.5), "set_work_plane");
        CHECK(view.set_work_plane(std::nullopt), "the ground plane back");
        const std::string tail = "clear;plane 1 2 3, 1 0 0, 0 0 1, 0.5;ground;";
        CHECK(snapspy::calls.size() >= tail.size() &&
                  snapspy::calls.compare(snapspy::calls.size() - tail.size(), tail.size(), tail) == 0,
              "the library saw %s", snapspy::calls.c_str());
    }
    t.set_snap = saved.set_snap;
    t.request_snap_in = saved.request_snap_in;
    t.snap_result = saved.snap_result;
    t.clear_snap = saved.clear_snap;
    t.set_work_plane = saved.set_work_plane;
    t.clear_work_plane = saved.clear_work_plane;
    t.last_error = saved.last_error;

    // show() on the wgpu library runs its window, a solid titled "Solid", Z up; view() answers
    // the camera it was left at.
    auto cube = bs::Solid::cuboid(5, 5, 5);
    if (cube) {
        spy::runs = 0;
        CHECK(cube->show(), "a solid's show: %s", refused(cube->show()).c_str());
        CHECK(spy::runs == 1 && spy::title == "Solid" && spy::y_up == 0, "a solid: runs %d, title %s, y_up %u",
              spy::runs, spy::title.c_str(), spy::y_up);
        auto camera = cube->view();
        CHECK(camera && camera->eye[0] == 10 && std::abs(camera->azimuth) < 1e-9 && std::abs(camera->elevation) < 1e-9 &&
                  !camera->pick,
              "view() did not answer the camera: %s", refused(camera).c_str());
    }

    // View::run reads the camera in the view's own up axis: an eye on +Y is the horizon Z up
    // and the pole Y up.
    spy::eye = {0, 10, 0};
    spy::up = {0, 0, -1};
    for (bool y_up : {false, true}) {
        cadaclysm::ViewOptions o;
        o.y_up = y_up;
        auto own = View::offscreen(32, 32, o);
        CHECK(own, "offscreen: %s", refused(own).c_str());
        if (!own) continue;
        auto camera = own->run();
        CHECK(camera && std::abs(camera->elevation - (y_up ? 90.0 : 0.0)) < 1e-6, "run, y_up %d: elevation %f",
              y_up ? 1 : 0, camera ? camera->elevation : -1.0);
        CHECK(own->closed() && refused(own->draw()) == "cadaclysm_view_draw: the window is closed",
              "after run: %s", refused(own->draw()).c_str());
    }
    spy::eye = {10, 0, 0};
    spy::up = {0, 0, 1};

    if (!mechanism.empty()) {
        // A scene, a node and a pose: the scene's file name, the scene's own up axis.
        auto scene = cadaclysm::open(mechanism);
        cadaclysm::OpenOptions y;
        y.convention = static_cast<std::uint32_t>(cadaclysm::Convention::y_up);
        auto upright = cadaclysm::open(mechanism, y);
        CHECK(scene && upright, "open the mechanism twice");
        if (scene && upright) {
            CHECK(scene->show(), "scene show");
            CHECK(spy::title == "mechanism-solid.stp" && spy::y_up == 0, "a scene: title %s, y_up %u",
                  spy::title.c_str(), spy::y_up);
            ShowOptions mine;
            mine.title = "mine";
            CHECK(scene->show(mine) && spy::title == "mine", "an explicit title: %s", spy::title.c_str());
            CHECK(upright->show() && spy::y_up == 1, "the scene's own up axis (Y) was not passed through");
            ShowOptions z;
            z.up = "z";
            CHECK(upright->show(z) && spy::y_up == 0, "an explicit up did not win");
            std::optional<cadaclysm::Node> leaf = nested_leaf(*upright);
            if (leaf) {
                spy::title.clear();
                CHECK(leaf->show() && spy::y_up == 1 && spy::title == "mechanism-solid.stp",
                      "a node of a Y-up scene: y_up %u, title %s", spy::y_up, spy::title.c_str());
            }
            std::vector<cadaclysm::State> states = upright->states();
            if (!states.empty()) {
                auto pose = upright->pose_state(states[0]);
                spy::title.clear();
                CHECK(pose && pose->show() && spy::y_up == 1 && spy::title == "mechanism-solid.stp",
                      "a pose of a Y-up scene: y_up %u, title %s", spy::y_up, spy::title.c_str());
            }
        }
    }
    t = saved;
}

static void terminal_half(const std::string& mechanism) {
    auto terminal = cadaclysm::view::use_terminal();
    if (!terminal) {
        std::printf("view: terminal skipped, %s\n", terminal.error().message.c_str());
        if (terminal_required()) ++failures;
        return;
    }
    CHECK((*terminal)->terminal() && !(*terminal)->wgpu(), "the terminal library is %s", (*terminal)->name().c_str());
    auto offscreen = View::offscreen(64, 64);
    CHECK(!offscreen, "the terminal made an offscreen view");

    // show() prints a still on the terminal; the refusals before any drawing.
    ShowOptions small;
    small.width = 16;
    small.height = 8;
    auto cube = bs::Solid::cuboid(5, 5, 5);
    CHECK(cube, "cuboid: %s", refused(cube).c_str());
    if (!cube) return;
    auto still = cube->show(small);
    CHECK(still, "a solid's still: %s", refused(still).c_str());
    ShowOptions tolerant = small;
    tolerant.tolerance = 0.1;
    auto took = cube->show(tolerant);
    CHECK(took, "a solid takes a tolerance: %s", refused(took).c_str());
    ShowOptions sideways = small;
    sideways.up = "x";
    CHECK(refused(cube->show(sideways)) == "up 'x': 'y' or 'z'", "%s", refused(cube->show(sideways)).c_str());
    sideways = small;
    sideways.view = "sideways";
    CHECK(starts(refused(cube->show(sideways)), "view 'sideways': one of front"), "%s",
          refused(cube->show(sideways)).c_str());
    if (mechanism.empty()) return;

    auto scene = cadaclysm::open(mechanism);
    CHECK(scene, "open %s: %s", mechanism.c_str(), refused(scene).c_str());
    if (!scene) return;
    auto drawn = scene->show(small);
    CHECK(drawn, "a scene's still: %s", refused(drawn).c_str());
    CHECK(refused(scene->show(tolerant)) ==
              "Scene.show takes no tolerance: a document is drawn at the tolerance it was read with",
          "%s", refused(scene->show(tolerant)).c_str());
    std::optional<cadaclysm::Node> leaf = nested_leaf(*scene);
    CHECK(leaf.has_value(), "mechanism-solid.stp has no leaf below a root with geometry");
    if (leaf) {
        auto node = leaf->show(small);
        CHECK(node, "a node's still: %s", refused(node).c_str());
        CHECK(starts(refused(leaf->view(tolerant)), "Node.view takes no tolerance"), "%s",
              refused(leaf->view(tolerant)).c_str());
    }
    std::vector<cadaclysm::State> states = scene->states();
    CHECK(!states.empty(), "mechanism-solid.stp records no state");
    if (!states.empty()) {
        auto pose = scene->pose_state(states[0]);
        CHECK(pose, "pose_state: %s", refused(pose).c_str());
        if (pose) {
            auto posed = pose->show(small);
            CHECK(posed, "a pose's still: %s", refused(posed).c_str());
            CHECK(starts(refused(pose->show(tolerant)), "Pose.show takes no tolerance"), "%s",
                  refused(pose->show(tolerant)).c_str());
        }
    }
}

// ---- colour text (1.5): every colour argument, through the library's parse_colour -----------

// One picture of everything that takes a colour, each given as text or as the numbers the
// text names: the background, a mesh, a solid and its face colours, an item recoloured,
// lines, curves; with a scene, a node's colour and highlight.
static ViewImage colours_drawn(bool text, const cadaclysm::Scene* scene) {
    using cadaclysm::Colour;
    auto made = View::offscreen(160, 120);
    CHECK(made, "a view for the colours: %s", refused(made).c_str());
    if (!made) return {};
    View& v = *made;
    auto pick = [&](const char* words, Colour numbers) { return text ? Colour(words) : numbers; };
    CHECK(v.layer(CADACLYSM_VIEW_LAYER_GRID, false), "grid off");
    CHECK(v.background(pick("#ff0", {1, 1, 0})), "background");
    const std::vector<float> square{-4, -1, 0, -2, -1, 0, -2, 1, 0, -4, 1, 0};
    const std::vector<std::uint32_t> triangles{0, 1, 2, 0, 2, 3};
    auto red = v.show_mesh(square, triangles, {}, {}, pick("Red", {1, 0, 0}));
    CHECK(red, "show_mesh: %s", refused(red).c_str());
    std::vector<float> lifted(square);
    for (std::size_t i = 1; i < lifted.size(); i += 3) lifted[i] += 2.5f;
    auto recoloured = v.show_mesh(lifted, triangles);
    CHECK(recoloured && recoloured->colour(pick("#00f", {0, 0, 1})), "colour");
    auto cube = bs::Solid::cuboid(2, 2, 2);
    CHECK(cube, "cuboid");
    if (cube) {
        auto shown = v.show(*cube, 0.05, pick("LIME", {0, 1, 0}));
        CHECK(shown, "show a solid: %s", refused(shown).c_str());
        // Numbers as a std::vector<std::array<float, 4>>, the form before Colour.
        const std::vector<std::array<float, 4>> numbers{{0, 1, 128.0f / 255.0f, 1}, {0, 0, 0, 1}};
        if (shown)
            CHECK(text ? shown->face_colours({0, 1}, {"00ff80", "black"}) : shown->face_colours({0, 1}, numbers),
                  "face_colours");
    }
    CHECK(v.show_lines({3, 0, 0, 5, 2, 2}, pick("#ffffff", {1, 1, 1})), "show_lines");
    CHECK(v.show_curves({3, -2, 0, 1, 4, -1, 0, 1, 5, -2, 1, 1, 6, -1, 0, 1}, pick("purple", {128.0f / 255.0f, 0, 128.0f / 255.0f})),
          "show_curves");
    if (scene) {
        auto whole = v.show(*scene);
        CHECK(whole, "show the scene: %s", refused(whole).c_str());
        if (whole) {
            CHECK(whole->node_colour(0, pick("white", {1, 1, 1})), "node_colour");
            CHECK(whole->node_highlight(0, pick("#f00", {1, 0, 0, 1})), "node_highlight");
        }
    }
    CHECK(v.standard("iso") && v.frame(), "iso, framed");
    return frame_of(v);
}

// A null pointer is no colour text: it does not compile (no colour is std::nullopt).
static_assert(!std::is_constructible<cadaclysm::Colour, std::nullptr_t>::value, "Colour(nullptr) compiles");
static_assert(!std::is_convertible<std::nullptr_t, cadaclysm::Colour>::value, "nullptr converts to a Colour");
static_assert(std::is_constructible<cadaclysm::Colour, const char*>::value, "Colour(const char*)");

static void colour_text(const std::string& mechanism) {
    std::optional<cadaclysm::Scene> scene;
    if (!mechanism.empty()) {
        auto opened = cadaclysm::open(mechanism);
        CHECK(opened, "open %s: %s", mechanism.c_str(), refused(opened).c_str());
        if (opened) scene.emplace(std::move(*opened));
    }
    std::vector<const cadaclysm::Scene*> withs{nullptr};
    if (scene) withs.push_back(&*scene);
    for (const cadaclysm::Scene* with : withs) {
        ViewImage numbers = colours_drawn(false, with), text = colours_drawn(true, with);
        CHECK(!numbers.rgba.empty() && changed(numbers, text) == 0, "colour text drew %zu pixels unlike its numbers%s",
              changed(numbers, text), with ? " (with a scene)" : "");
    }

    // Text the library refuses: its own message, and nothing reaches the view.
    auto made = View::offscreen(64, 48);
    CHECK(made, "a view for the refusals: %s", refused(made).c_str());
    if (!made) return;
    View& v = *made;
    auto square = v.show_mesh({-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0}, {0, 1, 2, 0, 2, 3}, {}, {}, "gray");
    CHECK(square, "show_mesh gray: %s", refused(square).c_str());
    if (!square) return;
    CHECK(v.standard("top") && v.frame(), "top, framed");
    ViewImage before = frame_of(v);
    for (const char* bad : {"blurple", "transparent", "rgb(1, 2, 3)", "#f00a", ""}) {
        std::string want = std::string("cadaclysm_view_parse_colour: colour: \"#rgb\", \"#rrggbb\" or a CSS colour name, not '") +
                           bad + "'";
        CHECK(refused(square->colour(bad)) == want, "colour(\"%s\"): %s", bad, refused(square->colour(bad)).c_str());
    }
    const char* tail = "not 'nope'";
    auto ends_nope = [&](const std::string& m) { return m.size() > 10 && m.compare(m.size() - 10, 10, tail) == 0; };
    CHECK(ends_nope(refused(v.background("nope"))), "background: %s", refused(v.background("nope")).c_str());
    CHECK(ends_nope(refused(v.show_lines({0, 0, 0, 1, 1, 1}, std::string("nope")))), "show_lines");
    CHECK(ends_nope(refused(v.show_curves(std::vector<float>(16, 1.0f), std::string_view("nope")))), "show_curves");
    CHECK(ends_nope(refused(v.show_mesh({0, 0, 0, 1, 0, 0, 0, 1, 0}, {0, 1, 2}, {}, {}, "nope"))), "show_mesh");
    CHECK(ends_nope(refused(square->face_colours({0}, {"nope"}))), "face_colours");
    CHECK(ends_nope(refused(square->node_colour(0, "nope"))), "node_colour");
    CHECK(ends_nope(refused(square->node_highlight(0, "nope"))), "node_highlight");
    auto cube = bs::Solid::cuboid(1, 1, 1);
    if (cube) CHECK(ends_nope(refused(v.show(*cube, 0.05, "nope"))), "show a solid");
    CHECK(changed(before, frame_of(v)) == 0, "a refused colour reached the view");
}

// Pixels of `image` near `rgb` (each channel within 60), and the sum of their x.
static std::size_t count_near(const ViewImage& image, std::array<int, 3> rgb, double* sum_x = nullptr) {
    std::size_t n = 0;
    for (std::size_t i = 0; i + 3 < image.rgba.size(); i += 4) {
        bool alike = true;
        for (std::size_t k = 0; k < 3; ++k) alike = alike && std::abs(int(image.rgba[i + k]) - rgb[k]) < 60;
        if (!alike) continue;
        ++n;
        if (sum_x) *sum_x += double((i / 4) % image.width);
    }
    return n;
}

// Text (view ABI 1.6), as Python's real-library case: a label shown, picked on its line,
// set_text giving it a second line, the text layer, the colours of glyphs and box, the
// bundled font loaded from its bytes and its path, and the refusals in Python's words.
static void text_case(const std::string& font_path) {
    auto made = View::offscreen(96, 96);
    CHECK(made, "a view for text: %s", refused(made).c_str());
    if (!made) return;
    View& v = *made;
    CHECK(v.layer(CADACLYSM_VIEW_LAYER_GRID, false), "grid off");
    auto blank_made = View::offscreen(96, 96);
    CHECK(blank_made, "a blank view: %s", refused(blank_made).c_str());
    if (!blank_made) return;
    CHECK(blank_made->layer(CADACLYSM_VIEW_LAYER_GRID, false), "grid off (blank)");
    ViewImage blank = frame_of(*blank_made);

    // Top left at the anchor, the picture's centre (48, 48): line 0 runs y 48..68, line 1 68..88.
    cadaclysm::TextOptions one;
    one.size = 20;
    one.colour = "red";
    one.align = "top-left";
    one.on_top = true;
    auto item = v.show_text("one", {0, 0, 0}, one);
    CHECK(item, "show_text: %s", refused(item).c_str());
    if (!item) return;
    auto hit = v.pick(52, 58);
    CHECK(hit && hit->item == item->id() && hit->face == 0, "the label's line 0 picks: %s",
          hit ? (std::to_string(hit->item) + "/" + std::to_string(hit->face)).c_str() : refused(hit).c_str());
    auto below = v.pick(52, 78);
    CHECK(below && below->item == 0, "one line: nothing below it, got item %u", below ? below->item : 999u);
    ViewImage one_line = frame_of(v);
    CHECK(count_near(one_line, {255, 0, 0}) > 30, "the label draws red: %zu", count_near(one_line, {255, 0, 0}));
    CHECK(item->set_text("one\ntwo"), "set_text");
    auto second = v.pick(52, 78);
    CHECK(second && second->item == item->id() && second->face == 1, "the second line after set_text: item %u face %u",
          second ? second->item : 0u, second ? second->face : 0u);
    ViewImage two_lines = frame_of(v);
    CHECK(changed(one_line, two_lines) > 0, "set_text changed nothing drawn");

    // The text layer hides every text item, and shows it again.
    CHECK(v.layer(CADACLYSM_VIEW_LAYER_TEXT, false), "text layer off");
    CHECK(changed(frame_of(v), blank) == 0, "the text layer off left text drawn");
    CHECK(v.layer(CADACLYSM_VIEW_LAYER_TEXT, true), "text layer on");
    CHECK(changed(frame_of(v), two_lines) == 0, "the text layer on did not bring it back");

    // Lime glyphs on a red box, centred on the anchor: swapped colours would draw the other way.
    {
        auto boxed = View::offscreen(64, 64);
        CHECK(boxed, "a view for the box: %s", refused(boxed).c_str());
        if (boxed) {
            CHECK(boxed->layer(CADACLYSM_VIEW_LAYER_GRID, false) && boxed->background("black"), "grid off, black");
            cadaclysm::TextOptions o;
            o.colour = "lime";
            o.size = 24;
            o.align = "centre";
            o.box = cadaclysm::Colour("red");
            o.on_top = true;
            CHECK(boxed->show_text("HH", {0, 0, 0}, o), "a boxed label");
            ViewImage img = frame_of(*boxed);
            double sum_x = 0;
            std::size_t lime = count_near(img, {0, 255, 0}, &sum_x), red = count_near(img, {255, 0, 0}, &sum_x);
            CHECK(lime > 20, "the glyphs are lime: %zu", lime);
            CHECK(red > 50 && red > lime, "the box is red and larger than the glyphs: %zu red, %zu lime", red, lime);
            double mean_x = lime + red ? sum_x / double(lime + red) : -1.0;
            CHECK(std::abs(mean_x - 32.0) < 4.0, "centre puts the label on its anchor: mean x %f", mean_x);
            // Four numbers: the box's own alpha; 0 is no box at all.
            o.box = cadaclysm::Colour(1.0f, 0.0f, 0.0f, 0.0f);
            auto clear = View::offscreen(64, 64);
            if (clear && clear->layer(CADACLYSM_VIEW_LAYER_GRID, false) && clear->background("black")) {
                CHECK(clear->show_text("HH", {0, 0, 0}, o), "a label with an alpha-0 box");
                ViewImage none = frame_of(*clear);
                CHECK(count_near(none, {255, 0, 0}) == 0 && count_near(none, {0, 255, 0}) > 20,
                      "an alpha-0 box draws no red: %zu red", count_near(none, {255, 0, 0}));
            }
        }
    }

    // World text lies in the scene along right and up.
    cadaclysm::TextOptions world;
    world.mode = "world";
    world.size = 0.5f;
    world.right = std::array<float, 3>{1, 0, 0};
    world.up = std::array<float, 3>{0, 1, 0};
    auto in_world = v.show_text("W", {0, 0, 0}, world);
    CHECK(in_world && in_world->id() > item->id(), "world text: %s", refused(in_world).c_str());

    // Refusals: Python's words before the library, then the library's reasons.
    cadaclysm::TextOptions bad_mode;
    bad_mode.mode = "screen";
    CHECK(refused(v.show_text("x", {0, 0, 0}, bad_mode)) == "mode 'screen': one of label, world", "%s",
          refused(v.show_text("x", {0, 0, 0}, bad_mode)).c_str());
    cadaclysm::TextOptions bad_align;
    bad_align.align = "middle";
    CHECK(refused(v.show_text("x", {0, 0, 0}, bad_align)) ==
              "align 'middle': one of top-left, top, top-right, left, centre, center, right, bottom-left, bottom, "
              "bottom-right",
          "%s", refused(v.show_text("x", {0, 0, 0}, bad_align)).c_str());
    const std::string nul("a\0b", 3);
    const char* nul_said = "text 'a\\x00b': a NUL character cannot be shown (the C string ends there)";
    CHECK(refused(v.show_text(nul, {0, 0, 0})) == nul_said, "%s", refused(v.show_text(nul, {0, 0, 0})).c_str());
    CHECK(refused(item->set_text(nul)) == nul_said, "%s", refused(item->set_text(nul)).c_str());
    auto still_two = v.pick(52, 78);
    CHECK(still_two && still_two->item == item->id() && still_two->face == 1, "a refused set_text reached the view");
    cadaclysm::TextOptions centred;
    centred.align = "center";
    CHECK(v.show_text("c", {0, 0, 0}, centred), "\"center\" is \"centre\"");
    cadaclysm::TextOptions zero;
    zero.size = 0;
    CHECK(has(refused(v.show_text("x", {0, 0, 0}, zero)), "height"), "a zero size: %s",
          refused(v.show_text("x", {0, 0, 0}, zero)).c_str());
    cadaclysm::TextOptions bad_colour;
    bad_colour.colour = "nope";
    CHECK(has(refused(v.show_text("x", {0, 0, 0}, bad_colour)), "not 'nope'"), "%s",
          refused(v.show_text("x", {0, 0, 0}, bad_colour)).c_str());
    cadaclysm::TextOptions bad_box;
    bad_box.box = cadaclysm::Colour("nope");
    CHECK(has(refused(v.show_text("x", {0, 0, 0}, bad_box)), "not 'nope'"), "%s",
          refused(v.show_text("x", {0, 0, 0}, bad_box)).c_str());
    cadaclysm::TextOptions no_font;
    no_font.font = 9999;
    CHECK(has(refused(v.show_text("x", {0, 0, 0}, no_font)), "font"), "an unknown font: %s",
          refused(v.show_text("x", {0, 0, 0}, no_font)).c_str());
    auto lines = v.show_lines({0, 0, 0, 1, 1, 1});
    CHECK(lines && !lines->set_text("x"), "set_text on lines was accepted");

    // Fonts: garbage refused with the library's reason, an unreadable path naming it.
    auto garbage = cadaclysm::view::load_font(std::vector<std::uint8_t>{1, 2, 3});
    CHECK(!garbage && has(refused(garbage), "cadaclysm_view_load_font"), "garbage font bytes: %s",
          refused(garbage).c_str());
    CHECK(refused(cadaclysm::view::load_font(std::string("no-such-font.ttf"))) ==
              "no-such-font.ttf: the font could not be read",
          "%s", refused(cadaclysm::view::load_font(std::string("no-such-font.ttf"))).c_str());
    CHECK(refused(cadaclysm::view::load_font(static_cast<const char*>(nullptr))) == "load_font: a font path, not null",
          "a null path");
    std::vector<std::uint8_t> bytes;
    if (std::FILE* f = font_path.empty() ? nullptr : std::fopen(font_path.c_str(), "rb")) {
        unsigned char chunk[4096];
        std::size_t got = 0;
        while ((got = std::fread(chunk, 1, sizeof chunk, f)) > 0) bytes.insert(bytes.end(), chunk, chunk + got);
        std::fclose(f);
    }
    if (bytes.empty()) {
        std::printf("view: the bundled font's checks skipped, no font at '%s'\n", font_path.c_str());
        return;
    }
    // Spec section 5: the bundled font loads, from its bytes and its path, and draws.
    auto font = cadaclysm::view::load_font(bytes);
    CHECK(font && *font >= 1, "the bundled font's bytes: %s", refused(font).c_str());
    auto from_path = cadaclysm::view::load_font(font_path);
    CHECK(from_path && *from_path >= 1, "the bundled font's path: %s", refused(from_path).c_str());
    if (!font) return;
    auto lone = View::offscreen(64, 64);
    if (!lone || !lone->layer(CADACLYSM_VIEW_LAYER_GRID, false)) return;
    ViewImage before = frame_of(*lone);
    cadaclysm::TextOptions loaded;
    loaded.size = 24;
    loaded.colour = "lime";
    loaded.on_top = true;
    loaded.align = "centre";
    loaded.font = *font;
    auto drawn = lone->show_text("W", {0, 0, 0}, loaded);
    CHECK(drawn, "text in the loaded font: %s", refused(drawn).c_str());
    CHECK(changed(before, frame_of(*lone)) > 0, "text in the loaded font drew nothing");
}

// ---- view ABI 1.8 on the real library: a double click, the opt-in, navigation, focus -------

// A red square seen from the top, zoomed out so a framing visibly changes the picture, on a
// 64 x 48 offscreen view; nullopt (a failure recorded) when it could not be made.
static std::optional<View> framed_square(std::uint32_t* item_id = nullptr) {
    auto made = View::offscreen(64, 48);
    CHECK(made, "offscreen: %s", refused(made).c_str());
    if (!made) return std::nullopt;
    View v = std::move(*made);
    CHECK(v.layer(CADACLYSM_VIEW_LAYER_GRID, false), "grid off");
    auto item = v.show_mesh({-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0}, {0, 1, 2, 0, 2, 3}, {}, {},
                            std::array<float, 3>{1, 0, 0});
    CHECK(item, "show_mesh: %s", refused(item).c_str());
    if (item && item_id) *item_id = item->id();
    CHECK(v.standard("top") && v.frame() && v.zoom(-3) && v.draw(), "the square from the top");
    return v;
}

// Down, up, down, up of the left button at one pixel within the double-click time.
static void double_click(View& v, float x, float y) {
    const double at[] = {0, 10, 60, 70};
    for (int i = 0; i < 4; ++i) {
        cadaclysm::ViewEvent e;
        e.kind = i % 2 ? CADACLYSM_VIEW_EVENT_UP : CADACLYSM_VIEW_EVENT_DOWN;
        e.pointer = CADACLYSM_VIEW_POINTER_MOUSE;
        e.button = CADACLYSM_VIEW_BUTTON_LEFT;
        e.x = x;
        e.y = y;
        e.time_ms = 1000 + at[i];
        auto bits = v.input(e);
        CHECK(bits, "input: %s", refused(bits).c_str());
    }
}

// The answer an input asked for, read through last_pick as the view's draws land it: drawn
// 10 ms apart for at most ten seconds, as Python's pick waits.
static std::optional<cadaclysm::ViewPick> land(View& v) {
    std::chrono::steady_clock::time_point end = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (std::chrono::steady_clock::now() < end) {
        cadaclysm::Result<void> drawn = v.draw();
        CHECK(drawn, "draw: %s", refused(drawn).c_str());
        if (!drawn) break;
        cadaclysm::Result<std::optional<cadaclysm::ViewPick>> landed = v.last_pick();
        CHECK(landed, "last_pick: %s", refused(landed).c_str());
        if (!landed) break;
        if (*landed) return *landed;
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    CHECK(false, "the pick never landed");
    return std::nullopt;
}

static void double_click_case() {
    // A double click answers clicks 2 with the point hit, and the picture stays; last_pick
    // has nothing before it, reads it once, and a click on the background is item 0.
    {
        std::uint32_t id = 0;
        auto v = framed_square(&id);
        if (v) {
            ViewImage before = frame_of(*v);
            cadaclysm::Result<std::optional<cadaclysm::ViewPick>> nothing = v->last_pick();
            CHECK(nothing && !*nothing, "nothing clicked yet, but last_pick: %s",
                  !nothing ? refused(nothing).c_str() : "an answer");
            double_click(*v, 32, 24);
            auto hit = land(*v);
            CHECK(hit && hit->item == id && hit->clicks == 2, "a double click's answer: item %u clicks %u",
                  hit ? hit->item : 0u, hit ? hit->clicks : 0u);
            CHECK(hit && hit->point && std::abs((*hit->point)[2]) < 1e-3f && std::abs((*hit->point)[0]) < 0.2f,
                  "the square's centre, z 0");
            CHECK(changed(before, frame_of(*v)) == 0, "a double click moved the picture by default");
            cadaclysm::Result<std::optional<cadaclysm::ViewPick>> again = v->last_pick();
            CHECK(again && !*again, "each answer is read once, but last_pick: %s",
                  !again ? refused(again).c_str() : "an answer");
            for (int i = 0; i < 2; ++i) {
                cadaclysm::ViewEvent e;
                e.kind = i ? CADACLYSM_VIEW_EVENT_UP : CADACLYSM_VIEW_EVENT_DOWN;
                e.pointer = CADACLYSM_VIEW_POINTER_MOUSE;
                e.button = CADACLYSM_VIEW_BUTTON_LEFT;
                e.x = 1;
                e.y = 1;
                e.time_ms = 5000 + 10 * i;
                cadaclysm::Result<std::uint32_t> bits = v->input(e);
                CHECK(bits, "input: %s", refused(bits).c_str());
            }
            std::optional<cadaclysm::ViewPick> miss = land(*v);
            CHECK(miss && miss->item == 0 && !miss->point && miss->clicks == 1,
                  "a click on the background: item %u clicks %u point %d", miss ? miss->item : 99u,
                  miss ? miss->clicks : 99u, miss && miss->point ? 1 : 0);
        }
    }
    // Opted in, the same double click frames what it hit.
    {
        auto v = framed_square();
        if (v) {
            ViewImage before = frame_of(*v);
            CHECK(v->set_double_click_frames(true), "set_double_click_frames");
            double_click(*v, 32, 24);
            auto hit = land(*v);
            CHECK(hit && hit->clicks == 2, "opted in: still a pick of clicks 2");
            CHECK(changed(before, frame_of(*v)) > 0, "opted in, the double click did not frame what it hit");
        }
    }
    // Fly after a fly key (and after it is let go), orbit after Tab, and after focus.
    {
        auto v = framed_square();
        if (v) {
            auto key = [&](const char* k) {
                for (bool down : {true, false}) {
                    cadaclysm::ViewEvent e;
                    e.kind = CADACLYSM_VIEW_EVENT_KEY;
                    e.key = k;
                    e.key_down = down;
                    CHECK(v->input(e), "input %s", k);
                }
            };
            auto mode = [&] {
                auto n = v->navigation();
                CHECK(n, "navigation: %s", refused(n).c_str());
                return n ? *n : cadaclysm::Navigation::orbit;
            };
            CHECK(mode() == cadaclysm::Navigation::orbit, "a new view is not orbiting");
            key("KeyW");
            CHECK(mode() == cadaclysm::Navigation::fly, "after KeyW (let go): not fly");
            key("Tab");
            CHECK(mode() == cadaclysm::Navigation::orbit, "after Tab: not orbit");
            key("KeyW");
            CHECK(v->focus({1, 2, 3}), "focus");
            CHECK(mode() == cadaclysm::Navigation::orbit, "focus did not leave fly mode");
        }
    }
    // focus moves the orbit point -- the centre then looks at it -- and focus back restores
    // the picture; a point not finite is the library's refusal.
    {
        auto v = framed_square();
        if (v) {
            ViewImage before = frame_of(*v);
            auto centre = v->pick(32, 24);
            CHECK(centre && centre->point && std::abs((*centre->point)[0]) < 0.2f,
                  "the centre looks at the middle of the square: %s", refused(centre).c_str());
            CHECK(v->focus({0.5f, 0, 0}), "focus");
            auto moved = v->pick(32, 24);
            CHECK(moved && moved->point && std::abs((*moved->point)[0] - 0.5f) < 0.1f,
                  "the centre now looks at x = 0.5: %s", refused(moved).c_str());
            CHECK(changed(before, frame_of(*v)) > 0, "focus did not move the picture");
            CHECK(v->focus({0, 0, 0}), "focus back");
            CHECK(changed(before, frame_of(*v)) == 0, "focus back did not restore the picture");
            const std::string not_finite = refused(v->focus({std::numeric_limits<float>::infinity(), 0, 0}));
            CHECK(starts(not_finite, "cadaclysm_view_focus"), "a point not finite: %s", not_finite.c_str());
        }
    }
}

// ---- view ABI 1.22 on the real library: a snap finds the square's corner -------------------

// Python's test_a_snap_on_the_real_library_finds_the_squares_corner and
// test_snapping_is_off_until_set_snap: the red square with its four sides, from the top, on a
// 64 x 48 view. Snapping is off until set_snap; then a snap 3 pixels inside the topmost (then
// leftmost) pixel that is not the background answers that corner, (-1, 1, 0), as a vertex of
// the square's item, on an edge, asked by the host; a face snap lands on the face; off again,
// nothing.
static void snap_case() {
    auto made = View::offscreen(64, 48);
    CHECK(made, "offscreen: %s", refused(made).c_str());
    if (!made) return;
    View v = std::move(*made);
    CHECK(v.layer(CADACLYSM_VIEW_LAYER_GRID, false), "grid off");
    const std::vector<float> square{-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0};
    std::vector<float> outline;
    for (int i = 0; i < 4; ++i)
        for (int k : {i, (i + 1) % 4})
            for (int c = 0; c < 3; ++c) outline.push_back(square[static_cast<std::size_t>(3 * k + c)]);
    auto item = v.show_mesh(square, {0, 1, 2, 0, 2, 3}, {}, outline, std::array<float, 3>{1, 0, 0});
    CHECK(item, "show_mesh: %s", refused(item).c_str());
    if (!item) return;
    CHECK(v.standard("top") && v.frame(), "the square from the top");
    ViewImage img = frame_of(v);
    cadaclysm::Result<cadaclysm::ViewSnap> off = v.snap(32, 24);
    CHECK(off && off->kind.empty(), "a view starts with snapping off: %s",
          off ? off->kind.c_str() : refused(off).c_str());
    CHECK(v.set_snap(), "set_snap");
    if (img.rgba.empty()) return;
    const std::array<std::uint8_t, 4> background = at(img, 0, 0);
    std::uint32_t cx = 0, cy = 0;
    bool found = false;
    for (std::uint32_t y = 0; y < img.height && !found; ++y)
        for (std::uint32_t x = 0; x < img.width && !found; ++x) {
            const std::array<std::uint8_t, 4> p = at(img, x, y);
            if (p[0] != background[0] || p[1] != background[1] || p[2] != background[2]) {
                cx = x;
                cy = y;
                found = true;
            }
        }
    CHECK(found, "the square drew nothing");
    if (!found) return;
    cadaclysm::Result<cadaclysm::ViewSnap> s = v.snap(cx + 3, cy + 3);
    CHECK(s && s->kind == "vertex" && s->item == item->id(), "the corner's snap: %s (item %u)",
          s ? s->kind.c_str() : refused(s).c_str(), s ? s->item : 0u);
    if (s)
        CHECK(std::abs(s->point[0] + 1.0) < 1e-6 && std::abs(s->point[1] - 1.0) < 1e-6 && std::abs(s->point[2]) < 1e-6,
              "the corner is (-1, 1, 0), not (%g, %g, %g)", s->point[0], s->point[1], s->point[2]);
    CHECK(s && s->edge && s->clicks == 0, "a vertex snap lies on an edge, asked by the host");
    CHECK(v.clear_snap(), "clear_snap");
    CHECK(v.set_snap(std::vector<std::string>{"face"}), "set_snap face");
    cadaclysm::Result<cadaclysm::ViewSnap> face = v.snap(32, 24);
    CHECK(face && face->kind == "face" && face->item == item->id() && !face->edge, "the face snap: %s",
          face ? face->kind.c_str() : refused(face).c_str());
    CHECK(v.set_snap(std::nullopt), "snapping off");
    cadaclysm::Result<cadaclysm::ViewSnap> none = v.snap(32, 24);
    CHECK(none && none->kind.empty(), "snapping off answers nothing: %s",
          none ? none->kind.c_str() : refused(none).c_str());
}

// ---- the plate of web/test/fixtures/machining-plate, offscreen on the real library (F7) ------

static std::string read_file(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    std::ostringstream text;
    text << in.rdbuf();
    return text.str();
}

// The directory holding web/test/fixtures/machining-plate/job.json, walking up from `from`
// (a file or directory); empty where there is none (an SDK checkout).
static std::string plate_directory(const std::string& from) {
    if (from.empty()) return "";
    std::error_code ignored;
    std::filesystem::path dir = std::filesystem::absolute(from, ignored);
    if (ignored) return "";
    for (;;) {
        std::filesystem::path candidate = dir / "web" / "test" / "fixtures" / "machining-plate";
        if (std::filesystem::exists(candidate / "job.json", ignored)) return candidate.string();
        if (!dir.has_parent_path() || dir.parent_path() == dir) return "";
        dir = dir.parent_path();
    }
}

// Python's _compare_at_walls (web/test/machining-selftest.js's rule): every cell within 2e-3 mm of
// the oracle, or, at a wall -- the oracle's 3x3 neighbourhood spanning more than 0.5 mm -- within
// 2e-3 of one of its neighbours; those excused number at most max(4, walls / 100).
static bool agrees_at_walls(const std::vector<float>& gpu, const float* oracle, std::uint32_t nx, std::uint32_t ny,
                            std::string& why) {
    std::size_t failed = 0, excused = 0, walls = 0;
    for (std::int64_t j = 0; j < static_cast<std::int64_t>(ny); ++j) {
        for (std::int64_t i = 0; i < static_cast<std::int64_t>(nx); ++i) {
            float lo = INFINITY, hi = -INFINITY;
            for (std::int64_t b = std::max<std::int64_t>(0, j - 1); b <= std::min<std::int64_t>(ny - 1, j + 1); ++b)
                for (std::int64_t a = std::max<std::int64_t>(0, i - 1); a <= std::min<std::int64_t>(nx - 1, i + 1); ++a) {
                    lo = std::min(lo, oracle[b * nx + a]);
                    hi = std::max(hi, oracle[b * nx + a]);
                }
            bool wall = hi - lo > 0.5f;
            if (wall) ++walls;
            float g = gpu[static_cast<std::size_t>(j * nx + i)];
            if (std::fabs(g - oracle[j * nx + i]) <= 2e-3f) continue;
            bool matched = false;
            if (wall)
                for (std::int64_t b = std::max<std::int64_t>(0, j - 1); b <= std::min<std::int64_t>(ny - 1, j + 1); ++b)
                    for (std::int64_t a = std::max<std::int64_t>(0, i - 1); a <= std::min<std::int64_t>(nx - 1, i + 1); ++a)
                        if (std::fabs(oracle[b * nx + a] - g) <= 2e-3f) matched = true;
            if (matched) ++excused; else ++failed;
        }
    }
    why = "failed " + std::to_string(failed) + ", excused " + std::to_string(excused) + ", walls " + std::to_string(walls);
    return failed == 0 && excused <= std::max<std::size_t>(4, walls / 100);
}

// F7 and the rest of the machining calls, run for real: the plate's job plays offscreen to
// the oracle's heights; the transport, the colour modes (deviation refused without a part,
// taken with one) and the overlays run on the library itself.
static void plate_case(const std::string& start, const std::string& cwd_start) {
    std::string dir = plate_directory(start);
    if (dir.empty()) dir = plate_directory(cwd_start);
    if (dir.empty()) {
        if (required()) {
            CHECK(false, "CADACLYSM_REQUIRE_WGPU needs web/test/fixtures/machining-plate above %s", start.c_str());
        } else {
            std::printf("view: the machining plate skipped, no web/test/fixtures/machining-plate\n");
        }
        return;
    }
    // web/test/fixtures/machining-plate/job.json
    std::vector<cadaclysm::MachiningProgram> programs = {
        {tool_of(1, "flat", 6, 20), read_file(dir + "/program-0.gcode")},
        {tool_of(2, "drill", 6, 30), read_file(dir + "/program-1.gcode")},
    };
    cadaclysm::MachiningStock box;
    box.min = {-42, -27, 0};
    box.max = {42, 27, 14};
    cadaclysm::MachiningOptions options;
    options.cell = 0.5;
    options.rapid_rate = 5000;

    cadaclysm::Result<View> made = View::offscreen(64, 48);
    CHECK(made, "the plate's view: %s", refused(made).c_str());
    if (!made) return;
    cadaclysm::Result<cadaclysm::Machining> m = made->show_machining(programs, box, std::nullopt, options);
    CHECK(m, "show_machining: %s", refused(m).c_str());
    if (!m) return;
    cadaclysm::Result<double> duration = made->duration();
    CHECK(duration && std::fabs(*duration - 893.247024) < 1e-3, "duration %g", duration ? *duration : -1.0);
    cadaclysm::Result<cadaclysm::MachiningInfo> info = m->info();
    CHECK(info && info->moves > 0, "info: %s", refused(info).c_str());
    if (!info) return;

    // F7: the last move's heights are the oracle's.
    CHECK(m->seek_move(info->moves), "seek_move: %s", refused(m->seek_move(info->moves)).c_str());
    cadaclysm::Result<std::vector<float>> gpu = m->heights();
    CHECK(gpu, "heights: %s", refused(gpu).c_str());
    std::string heights = read_file(dir + "/heights.bin");
    CHECK(heights.size() >= 28, "heights.bin is %zu bytes", heights.size());
    if (gpu && heights.size() >= 28) {
        std::uint32_t nx = 0, ny = 0;
        std::memcpy(&nx, heights.data() + 8, 4);
        std::memcpy(&ny, heights.data() + 12, 4);
        CHECK(info->nx == nx && info->ny == ny && gpu->size() == static_cast<std::size_t>(nx) * ny,
              "the grid: %u x %u, the fixture's %u x %u, %zu floats", info->nx, info->ny, nx, ny, gpu->size());
        if (heights.size() >= 28 + 4 * static_cast<std::size_t>(nx) * ny && gpu->size() == static_cast<std::size_t>(nx) * ny) {
            std::vector<float> oracle(static_cast<std::size_t>(nx) * ny);
            std::memcpy(oracle.data(), heights.data() + 28, 4 * oracle.size());
            std::string why;
            CHECK(agrees_at_walls(*gpu, oracle.data(), nx, ny, why), "the heights against the oracle: %s", why.c_str());
        }
    }
    CHECK(made->draw(), "draw");
    cadaclysm::Result<std::vector<std::string>> status = made->status();
    std::string want = "move " + std::to_string(info->moves) + " of " + std::to_string(info->moves);
    CHECK(status && !status->empty() && starts((*status)[0], want.c_str()), "status: %s",
          status && !status->empty() ? (*status)[0].c_str() : refused(status).c_str());

    // Every other call, on the library itself.
    CHECK(made->seek(0.0), "seek 0");
    CHECK(made->draw(), "draw at 0");
    cadaclysm::Result<bool> idle = made->playing();
    CHECK(idle && !*idle, "playing before play");
    CHECK(made->play(2), "play");
    cadaclysm::Result<bool> running = made->playing();
    CHECK(running && *running, "playing after play");
    CHECK(made->pause(), "pause");
    cadaclysm::Result<bool> stopped = made->playing();
    CHECK(stopped && !*stopped, "playing after pause");
    CHECK(made->seek(10), "seek 10");
    CHECK(made->draw(), "draw at 10");
    cadaclysm::Result<double> at = made->time();
    CHECK(at && std::fabs(*at - 10) < 1e-6, "time after seek(10): %g", at ? *at : -1.0);
    CHECK(made->seek(*duration + 100), "seek past the end");
    CHECK(made->draw(), "draw at the end");
    cadaclysm::Result<double> clamped = made->time();
    CHECK(clamped && std::fabs(*clamped - *duration) < 1e-6, "time clamped to the duration: %g", clamped ? *clamped : -1.0);
    CHECK(made->loop(true) && made->loop(false), "loop on and off");
    CHECK(m->colour_by("tool") && m->colour_by("height"), "colour_by tool, height");
    std::string deviation = refused(m->colour_by("deviation"));
    CHECK(has(deviation, "cadaclysm_view_machining_colour_by"), "deviation without a part: %s", deviation.c_str());
    CHECK(m->overlays(false, false) && m->overlays(), "overlays");
    CHECK(made->draw(), "draw");
    CHECK(m->remove(), "remove");

    cadaclysm::MachiningPart part;
    part.positions = {-42, -27, 14, 42, -27, 14, 0, 27, 14};
    part.indices = {0, 1, 2};
    cadaclysm::Result<cadaclysm::Machining> with_part = made->show_machining(programs, box, part, options);
    CHECK(with_part, "show_machining with a part: %s", refused(with_part).c_str());
    if (with_part) {
        CHECK(with_part->colour_by("deviation"), "deviation with a part: %s", refused(with_part->colour_by("deviation")).c_str());
        CHECK(made->draw(), "draw by deviation");
        CHECK(with_part->remove(), "remove");
    }
    CHECK(made->close(), "close");
}

// The anchors are the header's ALIGN codes, in its order.
static_assert(static_cast<std::uint32_t>(cadaclysm::Anchor::top_left) == 0 && static_cast<std::uint32_t>(cadaclysm::Anchor::top) == 1 &&
                  static_cast<std::uint32_t>(cadaclysm::Anchor::top_right) == 2 && static_cast<std::uint32_t>(cadaclysm::Anchor::left) == 3 &&
                  static_cast<std::uint32_t>(cadaclysm::Anchor::centre) == 4 && static_cast<std::uint32_t>(cadaclysm::Anchor::right) == 5 &&
                  static_cast<std::uint32_t>(cadaclysm::Anchor::bottom_left) == 6 && static_cast<std::uint32_t>(cadaclysm::Anchor::bottom) == 7 &&
                  static_cast<std::uint32_t>(cadaclysm::Anchor::bottom_right) == 8,
              "Anchor is CADACLYSM_VIEW_ALIGN_*'s 0..8");
static_assert(std::is_base_of<cadaclysm::Item, cadaclysm::Overlay>::value, "an Overlay is an Item");

// 1.25's stats on wgpu offscreen: an offscreen view's frames are its images, each counted once
// with its CPU time, triangles and draw calls; a draw that renders nothing counts none.
static void stats_case() {
    auto made = View::offscreen(64, 48);
    CHECK(made, "a view for stats: %s", refused(made).c_str());
    if (!made) return;
    View& sv = *made;
    cadaclysm::Result<cadaclysm::ViewStats> none = sv.stats();
    CHECK(none && none->frames_drawn == 0 && none->triangles == 0, "a new view drew nothing: %s", refused(none).c_str());
    auto cube = bs::Solid::cuboid(20, 20, 20);
    CHECK(cube, "cuboid");
    if (!cube) return;
    CHECK(sv.show(*cube), "show");
    CHECK(sv.draw(), "draw");
    cadaclysm::Result<cadaclysm::ViewStats> drew = sv.stats();
    CHECK(drew && drew->frames_drawn == 0, "an offscreen draw renders nothing");
    frame_of(sv);
    cadaclysm::Result<cadaclysm::ViewStats> s = sv.stats();
    CHECK(s && s->frames_drawn == 1 && s->last_frame_ms > 0.0f && s->triangles >= 12 && s->draw_calls >= 1,
          "one frame, with its cost: frames %llu, %.3f ms, %llu triangles, %u draw calls", s ? (unsigned long long)s->frames_drawn : 0ull,
          s ? s->last_frame_ms : 0.0f, s ? (unsigned long long)s->triangles : 0ull, s ? s->draw_calls : 0u);
    CHECK(s && (s->last_gpu_ms == -1.0f || (s->last_gpu_ms >= 0.0f && s->last_gpu_ms < 1000.0f)), "the GPU time");
    frame_of(sv);
    cadaclysm::Result<cadaclysm::ViewStats> again = sv.stats();
    CHECK(again && again->frames_drawn == 2, "each image counts");
    std::printf("view: stats checked\n");
}

// 1.24's overlays on wgpu offscreen: a holed panel at the centre (its hole picks the part
// beneath), a stroked crosshair, text at the top right, an image moved from the bottom left to
// the bottom right, order, an outline, a removed overlay, and the refusals.
static void overlay_case() {
    auto made = View::offscreen(200, 120);
    CHECK(made, "a view for overlays: %s", refused(made).c_str());
    if (!made) return;
    View& ov = *made;
    CHECK(ov.background("black"), "background");
    auto cube = bs::Solid::cuboid(80, 80, 20);
    CHECK(cube, "cuboid");
    if (!cube) return;
    auto under = ov.show(*cube, 0.05, cadaclysm::Colour("#808080"));
    CHECK(under, "show: %s", refused(under).c_str());
    CHECK(ov.standard("top") && ov.frame(), "from the top");
    auto is = [](const ViewImage& img, std::uint32_t x, std::uint32_t y, int r, int g, int b) {
        std::array<std::uint8_t, 4> p = at(img, x, y);
        return std::abs(p[0] - r) < 40 && std::abs(p[1] - g) < 40 && std::abs(p[2] - b) < 40;
    };
    auto px = [](const ViewImage& img, std::uint32_t x, std::uint32_t y) {
        std::array<std::uint8_t, 4> p = at(img, x, y);
        return std::to_string(p[0]) + "," + std::to_string(p[1]) + "," + std::to_string(p[2]);
    };
    // A rounded panel with a round hole, red by its own colour, at the window's centre.
    cadaclysm::Result<bs::Profile> plate = bs::Profile::rect(60, 40);
    cadaclysm::Result<bs::Profile> hole = bs::Profile::circle(8);
    CHECK(plate && hole, "profiles");
    if (!plate || !hole) return;
    cadaclysm::Result<bs::Profile> rounded = plate->round(6);
    CHECK(rounded, "round: %s", refused(rounded).c_str());
    if (!rounded) return;
    cadaclysm::Result<bs::Profile> holed = rounded->with_hole(*hole);
    CHECK(holed, "with_hole: %s", refused(holed).c_str());
    if (!holed) return;
    cadaclysm::Result<bs::Profile> panel_shape = holed->coloured("red");
    CHECK(panel_shape, "the panel: %s", refused(panel_shape).c_str());
    if (!panel_shape) return;
    cadaclysm::Result<cadaclysm::Overlay> panel = ov.show_overlay(*panel_shape, cadaclysm::Anchor::centre, 0, 0);
    CHECK(panel, "show_overlay: %s", refused(panel).c_str());
    if (!panel) return;
    ViewImage img = frame_of(ov);
    CHECK(is(img, 120, 60, 255, 0, 0), "the panel red right of its hole: %s", px(img, 120, 60).c_str());
    CHECK(!is(img, 100, 60, 255, 0, 0), "the hole is filled");
    cadaclysm::Result<cadaclysm::ViewPick> on_panel = ov.pick(120, 60);
    CHECK(on_panel && on_panel->overlay && !on_panel->point && on_panel->item == panel->id(), "a pick on the panel: item %u overlay %d",
          on_panel ? on_panel->item : 0u, on_panel ? int(on_panel->overlay) : -1);
    cadaclysm::Result<cadaclysm::ViewPick> in_hole = ov.pick(100, 60);
    CHECK(in_hole && !in_hole->overlay && in_hole->item == under->id(), "a pick in the hole reaches the part: item %u",
          in_hole ? in_hole->item : 0u);
    // A stroked crosshair of two open profiles, 20 px in from the top left.
    auto across = bs::Profile::polyline({{-8.0, 0.0}, {8.0, 0.0}});
    auto down = bs::Profile::polyline({{0.0, -8.0}, {0.0, 8.0}});
    CHECK(across && down, "the crosshair's profiles");
    if (!across || !down) return;
    cadaclysm::OverlayStyle lime;
    lime.stroke = cadaclysm::Colour("lime");
    lime.stroke_width = 2;
    cadaclysm::Result<cadaclysm::Overlay> cross = ov.show_overlay({std::cref(*across), std::cref(*down)}, cadaclysm::Anchor::top_left, 20, 20, lime);
    CHECK(cross, "the crosshair: %s", refused(cross).c_str());
    if (!cross) return;
    img = frame_of(ov);
    CHECK(is(img, 20, 20, 0, 255, 0) && is(img, 26, 20, 0, 255, 0) && is(img, 20, 14, 0, 255, 0), "the crosshair's arms: %s %s %s",
          px(img, 20, 20).c_str(), px(img, 26, 20).c_str(), px(img, 20, 14).c_str());
    CHECK(!is(img, 25, 25, 0, 255, 0), "between the arms");
    cadaclysm::Result<cadaclysm::ViewPick> c = ov.pick(26, 21);
    CHECK(c && c->overlay && c->item == cross->id(), "a pick on the crosshair");
    // Text at the top right, its box's corner 4 px in; set_text changes it.
    cadaclysm::TextOptions fps_options;
    fps_options.colour = "white";
    fps_options.size = 14;
    fps_options.box = cadaclysm::Colour("blue");
    cadaclysm::Result<cadaclysm::Overlay> fps = ov.show_overlay_text("FPS 60", cadaclysm::Anchor::top_right, 4, 4, fps_options);
    CHECK(fps, "show_overlay_text: %s", refused(fps).c_str());
    if (!fps) return;
    img = frame_of(ov);
    CHECK(is(img, 194, 6, 0, 0, 255) && !is(img, 197, 2, 0, 0, 255), "the text's box hangs from the top-right corner: %s %s",
          px(img, 194, 6).c_str(), px(img, 197, 2).c_str());
    CHECK(fps->set_text("FPS 120"), "set_text");
    cadaclysm::Result<cadaclysm::ViewPick> t = ov.pick(194, 6);
    CHECK(t && t->overlay && t->item == fps->id(), "a pick on the text");
    // An image, 2 x 2 yellow pixels drawn 10 x 10, at the bottom left; moved to the bottom right.
    std::vector<std::uint8_t> yellow;
    for (int k = 0; k < 4; ++k) yellow.insert(yellow.end(), {255, 255, 0, 255});
    cadaclysm::Result<cadaclysm::Overlay> pic = ov.show_overlay_image(yellow, 2, 2, cadaclysm::Anchor::bottom_left, 4, 4, 10, 10);
    CHECK(pic, "show_overlay_image: %s", refused(pic).c_str());
    if (!pic) return;
    img = frame_of(ov);
    CHECK(is(img, 8, 110, 255, 255, 0), "the image at the bottom left: %s", px(img, 8, 110).c_str());
    CHECK(pic->move_to(cadaclysm::Anchor::bottom_right, 4, 4), "move_to bottom right");
    img = frame_of(ov);
    CHECK(pic->anchor() == cadaclysm::Anchor::bottom_right && is(img, 190, 110, 255, 255, 0) && !is(img, 8, 110, 255, 255, 0),
          "moved to the bottom right: %s %s", px(img, 190, 110).c_str(), px(img, 8, 110).c_str());
    CHECK(pic->move_to(6, 6), "move_to, the anchor kept");
    img = frame_of(ov);
    CHECK(is(img, 188, 108, 255, 255, 0), "moved, the anchor kept: %s", px(img, 188, 108).c_str());
    // Order: a green square of order 1 shown first stays over a later blue one of order 0.
    auto sq = bs::Profile::rect(20, 20);
    CHECK(sq, "square");
    if (!sq) return;
    cadaclysm::OverlayStyle green;
    green.fill = cadaclysm::Colour("lime");
    green.order = 1;
    cadaclysm::OverlayStyle blue;
    blue.fill = cadaclysm::Colour("blue");
    CHECK(ov.show_overlay(*sq, cadaclysm::Anchor::bottom_left, 60, 30, green) && ov.show_overlay(*sq, cadaclysm::Anchor::bottom_left, 65, 30, blue),
          "the squares");
    img = frame_of(ov);
    CHECK(is(img, 63, 90, 0, 255, 0), "order 1 over order 0: %s", px(img, 63, 90).c_str());
    // An outline only: "none" fills nothing.
    cadaclysm::OverlayStyle outline_style;
    outline_style.fill = cadaclysm::Colour("none");
    outline_style.stroke = cadaclysm::Colour("white");
    outline_style.stroke_width = 2;
    cadaclysm::Result<cadaclysm::Overlay> outline = ov.show_overlay(*sq, cadaclysm::Anchor::top, 0, 30, outline_style);
    CHECK(outline, "the outline: %s", refused(outline).c_str());
    img = frame_of(ov);
    CHECK(is(img, 110, 30, 255, 255, 255) && !is(img, 100, 30, 255, 255, 255), "an outline, its inside not filled: %s %s",
          px(img, 110, 30).c_str(), px(img, 100, 30).c_str());
    // Removed: gone, and the part is picked there again.
    CHECK(panel->remove(), "remove");
    img = frame_of(ov);
    CHECK(!is(img, 120, 60, 255, 0, 0), "a removed overlay draws nothing");
    cadaclysm::Result<cadaclysm::ViewPick> after = ov.pick(120, 60);
    CHECK(after && !after->overlay, "a removed overlay is not picked");
    if (outline) CHECK(outline->remove(), "remove the outline");
    CHECK(starts(refused(ov.show_overlay(std::vector<float>(15), cadaclysm::Anchor::top_left, 0, 0)), "show_overlay: 16 numbers a curve"),
          "%s", refused(ov.show_overlay(std::vector<float>(15), cadaclysm::Anchor::top_left, 0, 0)).c_str());
    CHECK(has(refused(cross->move_to(std::nanf(""), 0)), "finite"), "a NaN move: %s", refused(cross->move_to(std::nanf(""), 0)).c_str());
    CHECK(starts(refused(ov.show_overlay_image(yellow, 3, 2, cadaclysm::Anchor::top_left, 0, 0)), "show_overlay_image: 3 x 2 pixels need 24 bytes"),
          "%s", refused(ov.show_overlay_image(yellow, 3, 2, cadaclysm::Anchor::top_left, 0, 0)).c_str());
    std::printf("view: overlays checked\n");
}

int main(int argc, char** argv) {
    const std::string scratch = argc > 1 ? argv[1] : ".";
    const std::string mechanism = argc > 2 ? argv[2] : "";  // samples/mechanism-solid.stp
    const std::string stand_in = argc > 3 ? argv[3] : "";   // view_loader_fake: answers nothing
    const std::string font_path = argc > 4 ? argv[4] : "";  // crates/cadaclysm-text/fonts/LiberationSans-Regular.ttf

    // A missing library: the contract's message, through the search the wrapper uses.
    auto missing = cadaclysm::detail::ViewAccess::find("cadaclysm_view_absent", "CADACLYSM_VIEW_ABSENT_LIBRARY",
                                                       "terminal", {scratch});
    CHECK(!missing, "found %s", missing ? missing->c_str() : "");
    if (!missing) {
        const std::string& m = missing.error().message;
        CHECK(starts(m, "no view library: the terminal library was not found (searched: "), "%s", m.c_str());
        CHECK(missing.error().origin == cadaclysm::Origin::view, "origin");
    }

    // The library directory CMake compiled in is a directory (a path with backslashes, made
    // into C escapes, would not be).
    for (const std::string& dir : cadaclysm::detail::view_dirs())
        CHECK(cvl_kind(dir.c_str()) == 2, "CADACLYSM_VIEW_LIBRARY_DIR names no directory: %s", dir.c_str());

    terminal_half(mechanism);

    // A library that answers nothing: a create it refuses without a word is Python's fallback.
    if (!stand_in.empty()) {
        auto mine = cadaclysm::view::use(stand_in);
        CHECK(mine, "use %s: %s", stand_in.c_str(), refused(mine).c_str());
        if (mine) {
            CHECK(!(*mine)->terminal() && !(*mine)->wgpu(), "the stand-in is %s", (*mine)->name().c_str());
            CHECK(refused(View::offscreen(8, 8)) == "the view library failed", "%s",
                  refused(View::offscreen(8, 8)).c_str());
            auto cube = bs::Solid::cuboid(1, 1, 1);
            if (cube) CHECK(refused(cube->show()) == "the view library failed", "%s", refused(cube->show()).c_str());
            points_case(**mine);
            machining_case(**mine);
        }
    }

    // An empty name is no library (Go's and Swift's words); the one in use stays.
    auto in_use = cadaclysm::view::current();
    auto empty_name = cadaclysm::view::use("");
    CHECK(!empty_name && empty_name.error().message == "use: \"terminal\", \"wgpu\" or a path" &&
              empty_name.error().origin == cadaclysm::Origin::view,
          "use(\"\"): %s", refused(empty_name).c_str());
    auto still = cadaclysm::view::current();
    CHECK(!in_use || (still && *still == *in_use), "use(\"\") changed the library in use");

    // No window of this thread's own: pump waits (a negative wait is none) and answers 0.
    auto pumped = cadaclysm::view::pump(-1.0);
    CHECK(pumped && *pumped == 0, "pump: %s", pumped ? std::to_string(*pumped).c_str() : refused(pumped).c_str());

    auto wgpu = cadaclysm::view::use_wgpu();
    if (!wgpu) {
        std::printf("view: skipped, %s\n", wgpu.error().message.c_str());
        return required() || failures ? 1 : 0;
    }
    auto made = View::offscreen(320, 240);
    if (!made) {
        std::printf("view: skipped, %s\n", made.error().message.c_str());
        return required() || failures ? 1 : 0;
    }
    View view = std::move(*made);
#if !defined(_WIN32) && !defined(__APPLE__)
    // A window of its own with no display (the Linux box): the library's message and the hint.
    if (!std::getenv("DISPLAY") && !std::getenv("WAYLAND_DISPLAY")) {
        auto windowed = View::create();
        std::string why = refused(windowed);
        CHECK(!windowed, "a window was made with no display");
        const std::string hint =
            " -- draw without a display with View::offscreen, or the terminal (cadaclysm::view::use_terminal())";
        if (has(why, "no display"))
            CHECK(why.size() > hint.size() && why.compare(why.size() - hint.size(), hint.size(), hint) == 0,
                  "no hint: %s", why.c_str());
        else
            std::printf("view: a create with no display said: %s\n", why.c_str());
    }
#endif
    CHECK(view.standard("front"), "standard front");
    CHECK(refused(view.standard("sideways")) == "standard view 'sideways': one of top, front, right, iso", "%s",
          refused(view.standard("sideways")).c_str());
    ViewImage empty = frame_of(view);
    CHECK(empty.width == 320 && empty.height == 240, "empty image: %u x %u", empty.width, empty.height);
    auto blank_view = View::offscreen(320, 240);
    CHECK(blank_view, "a second view: %s", refused(blank_view).c_str());
    ViewImage blank = blank_view ? frame_of(*blank_view) : ViewImage{};
    auto owed = view.needs_draw();
    CHECK(owed, "needs_draw: %s", refused(owed).c_str());
    colour_text(mechanism);
    text_case(font_path);
    double_click_case();
    snap_case();
    overlay_case();
    stats_case();
    plate_case(mechanism, ".");

    // A solid by handle: its item keeps it alive after the Solid is gone.
    cadaclysm::Result<cadaclysm::Item> item = cadaclysm::Error{"not shown", cadaclysm::Origin::view};
    std::weak_ptr<const void> kept;
    {
        auto sphere = bs::Solid::sphere(10);
        CHECK(sphere, "sphere");
        if (sphere) {
            kept = cadaclysm::detail::ViewAccess::keep(*sphere);
            item = view.show(*sphere, 0.05, std::array<float, 3>{0.9f, 0.2f, 0.1f});
        }
        CHECK(item, "show: %s", refused(item).c_str());
    }
    CHECK(!kept.expired(), "the item let go of the solid it shows");
    {
        auto gone = bs::Solid::cuboid(1, 1, 1);
        if (gone) {
            gone->close();
            CHECK(refused(view.show(*gone)) == "solid: closed", "%s", refused(view.show(*gone)).c_str());
            CHECK(refused(gone->show()) == "solid: closed", "%s", refused(gone->show()).c_str());
        }
    }
    CHECK(view.frame(), "frame");
    ViewImage drawn = frame_of(view);
    CHECK(!drawn.rgba.empty() && !empty.rgba.empty() && at(drawn, 160, 120) != at(empty, 160, 120),
          "nothing drawn at the centre");
    CHECK(!drawn.rgba.empty() && at(drawn, 1, 1) == at(empty, 1, 1), "a corner outside the sphere changed");
    auto pick = view.pick(160, 120);
    CHECK(pick && item && pick->item == item->id(), "pick: %s", pick ? "another item" : refused(pick).c_str());
    // 1.16's user layers: the sphere on layer 3, the layer off (the centre no longer the
    // sphere's) and on again (the sphere's again); layer 32 refused, for an item and for the view.
    if (item) {
        CHECK(item->user_layer(3), "user_layer 3");
        CHECK(view.user_layer(3, false), "user layer 3 off");
        ViewImage hidden = frame_of(view);
        CHECK(!hidden.rgba.empty() && at(hidden, 160, 120) != at(drawn, 160, 120), "an item on a layer switched off drew");
        CHECK(view.user_layer(3, true), "user layer 3 on");
        ViewImage shown = frame_of(view);
        CHECK(!shown.rgba.empty() && at(shown, 160, 120) == at(drawn, 160, 120), "an item on a layer switched on again did not draw");
        CHECK(has(refused(item->user_layer(32)), "past 31"), "%s", refused(item->user_layer(32)).c_str());
        CHECK(has(refused(view.user_layer(32, false)), "past 31"), "%s", refused(view.user_layer(32, false)).c_str());
        CHECK(item->user_layer(0), "user_layer 0");
    }
    std::string png = scratch + "/view_test.png";
    CHECK(view.save(png), "save");
    if (std::FILE* f = std::fopen(png.c_str(), "rb")) {
        unsigned char head[8] = {0};
        std::size_t got = std::fread(head, 1, 8, f);
        std::fclose(f);
        CHECK(got == 8 && head[1] == 'P' && head[2] == 'N' && head[3] == 'G', "%s is not a PNG", png.c_str());
    } else {
        CHECK(false, "save wrote no %s", png.c_str());
    }

    // Master's three: levels on and off, the wake answer; node transforms refused on a solid
    // (only a shown scene takes them), with the library's own reason.
    CHECK(view.lod("smooth", 0), "lod smooth");
    auto wake = view.wake_ms();
    CHECK(wake, "wake_ms: %s", refused(wake).c_str());
    CHECK(view.lod(std::nullopt), "lod off");
    CHECK(has(refused(view.lod("sharp")), "one of detailed, smooth"), "%s", refused(view.lod("sharp")).c_str());
    // 1.9's lighting: the headlight by default, studio set and read back, another name refused
    // before C (the lighting unchanged), and the headlight again.
    auto lit = view.lighting();
    CHECK(lit && *lit == "headlight", "lighting at first: %s", lit ? lit->c_str() : refused(lit).c_str());
    CHECK(view.lighting("studio"), "lighting studio");
    lit = view.lighting();
    CHECK(lit && *lit == "studio", "lighting after studio: %s", lit ? lit->c_str() : refused(lit).c_str());
    CHECK(refused(view.lighting("noon")) == "lighting 'noon': 'headlight' or 'studio'", "%s",
          refused(view.lighting("noon")).c_str());
    lit = view.lighting();
    CHECK(lit && *lit == "studio", "a refused lighting changed it: %s", lit ? lit->c_str() : refused(lit).c_str());
    CHECK(view.lighting("headlight"), "lighting headlight");
    lit = view.lighting();
    CHECK(lit && *lit == "headlight", "lighting after headlight: %s", lit ? lit->c_str() : refused(lit).c_str());
    // 1.20's occluded style: the defaults first, a set one (with a colour) read back, a refused
    // one (a negative dash) leaving it as it was, and the defaults again.
    {
        cadaclysm::Result<cadaclysm::OccludedStyle> before = view.occluded_style();
        CHECK(before && before->dash == 6.0f && before->gap == 4.0f && before->dim == 0.5f && !before->colour.has_value(),
              "occluded style at first: %s", before ? "not the defaults" : refused(before).c_str());
        cadaclysm::OccludedStyle style;
        style.dash = 10.0f;
        style.gap = 5.0f;
        style.dim = 0.25f;
        style.colour = std::array<float, 3>{0.5f, 0.25f, 0.75f};
        CHECK(view.occluded_style(style), "occluded style set");
        cadaclysm::Result<cadaclysm::OccludedStyle> back = view.occluded_style();
        CHECK(back && back->dash == 10.0f && back->gap == 5.0f && back->dim == 0.25f && back->colour.has_value() &&
                  (*back->colour)[0] == 0.5f && (*back->colour)[1] == 0.25f && (*back->colour)[2] == 0.75f,
              "occluded style read back: %s", back ? "other values" : refused(back).c_str());
        cadaclysm::OccludedStyle bad = style;
        bad.dash = -1.0f;
        CHECK(!view.occluded_style(bad), "a negative dash accepted");
        back = view.occluded_style();
        CHECK(back && back->dash == 10.0f, "a refused style changed it");
        CHECK(view.occluded_style(cadaclysm::OccludedStyle()), "occluded style defaults");
        back = view.occluded_style();
        CHECK(back && back->dash == 6.0f && !back->colour.has_value(), "the defaults were not restored");
    }
    // 1.23's line colours: a view-wide isocurve colour read back, an item's own edge and
    // curve colours set and cleared.
    {
        CHECK(view.set_isocurve_colour("#00ff00", true), "isocurve colour set");
        cadaclysm::Result<cadaclysm::LineColour> iso = view.isocurve_colour();
        CHECK(iso && iso->from_part && iso->colour[0] == 0.0f && iso->colour[1] == 1.0f && iso->colour[2] == 0.0f,
              "isocurve colour read back: %s", iso ? "other values" : refused(iso).c_str());
        cadaclysm::Result<cadaclysm::LineColour> curves = view.curve_colour();
        CHECK(curves && curves->from_part, "curves do not follow their part by default");
        CHECK(view.set_isocurve_colour(std::array<float, 3>{0.54f, 0.56f, 0.6f}), "isocurve colour back");
        CHECK(view.set_edge_colour("#202020"), "edge colour set");
        if (item) {
            CHECK(item->set_edge_colour(cadaclysm::Colour("red")), "an item's edge colour set");
            CHECK(item->set_edge_colour(std::nullopt), "an item's edge colour cleared");
            CHECK(item->set_curve_colour(cadaclysm::Colour("red")) && item->set_curve_colour(std::nullopt), "an item's curve colour");
        }
    }
    if (item) {
        auto posed = item->node_transforms(std::vector<std::array<double, 16>>{});
        CHECK(!posed && !posed.error().message.empty(), "node transforms on a solid were accepted");
    }

    // Every buffer is length-checked before C, in Python's words; sizes in 64 bits.
    CHECK(refused(view.show_lines(std::vector<float>(7))) == "segments is two points a segment (6 numbers), not 7", "%s",
          refused(view.show_lines(std::vector<float>(7))).c_str());
    CHECK(refused(view.show_mesh(std::vector<float>(3), {0, 0, 0}, std::vector<float>(6))) ==
              "a mesh has 1 positions but 2 normals",
          "%s", refused(view.show_mesh(std::vector<float>(3), {0, 0, 0}, std::vector<float>(6))).c_str());
    CHECK(refused(view.show_mesh(std::vector<float>(9), {0, 1, 2}, {}, std::vector<float>(5))) ==
              "edges is two points a segment (6 numbers), not 5",
          "edges");
    CHECK(starts(refused(view.show_mesh(std::vector<float>(4), {0})), "positions is three numbers a point, not 4"),
          "positions");
    CHECK(starts(refused(view.show_curves(std::vector<float>(15))), "show_curves takes"), "%s",
          refused(view.show_curves(std::vector<float>(15))).c_str());
    std::array<float, 12> corners{};
    CHECK(refused(view.show_image(corners, std::vector<std::uint8_t>(15), 2, 2)) ==
              "show_image: 2 x 2 pixels need 16 bytes (rgba), not 15",
          "%s", refused(view.show_image(corners, std::vector<std::uint8_t>(15), 2, 2)).c_str());
    if constexpr (sizeof(std::size_t) == 8)
        CHECK(has(refused(view.show_image(corners, std::vector<std::uint8_t>(4), 0xFFFFFFFFu, 0xFFFFFFFFu)),
                  "too large"),
              "an image size that wraps was not refused");
    if (item) {
        CHECK(refused(item->face_colours({1, 2}, {std::array<float, 4>{1, 0, 0, 1}})) ==
                  "8 numbers (rgba, 4 a face), not 4",
              "%s", refused(item->face_colours({1, 2}, {std::array<float, 4>{1, 0, 0, 1}})).c_str());
        // An empty list clears: it reaches the library as an empty array, not "none".
        CHECK(item->face_colours({}, {}), "face_colours([]) did not clear");
    }
    // Empty lines and curves are accepted (a non-NULL empty array).
    auto no_lines = view.show_lines({});
    CHECK(no_lines, "an empty show_lines: %s", refused(no_lines).c_str());
    if (no_lines) CHECK(no_lines->remove(), "remove the empty lines");
    auto no_curves = view.show_curves({});
    CHECK(no_curves, "an empty show_curves: %s", refused(no_curves).c_str());
    if (no_curves) CHECK(no_curves->remove(), "remove the empty curves");
    // Two points on the real library: an item.
    auto two_points = view.show_points({0, 0, 0, 1, 1, 1}, std::string("red"));
    CHECK(two_points && two_points->id() != 0, "two points: %s", refused(two_points).c_str());
    if (two_points) CHECK(two_points->remove(), "remove the points");
    // A host's event on a view that is not a window of its own leaves it open.
    cadaclysm::ViewEvent escape;
    escape.kind = CADACLYSM_VIEW_EVENT_KEY;
    escape.key = "Escape";
    auto bits = view.input(escape);
    CHECK(bits, "input: %s", refused(bits).c_str());
    CHECK(!view.closed(), "Escape closed an offscreen view");

    // A view belongs to the thread that made it.
    std::string drew_there, closed_there;
    std::thread([&] {
        drew_there = refused(view.draw());
        closed_there = refused(view.close());
    }).join();
    CHECK(drew_there == "cadaclysm_view_draw: a view belongs to the thread that made it", "%s", drew_there.c_str());
    CHECK(closed_there == "close: a view belongs to the thread that made it", "%s", closed_there.c_str());
    CHECK(view.draw(), "the view stopped working after another thread's refused calls");

    // A view dropped on another thread than its own is left (Python's __del__) -- and so is
    // what its items keep, which the left view may still read.
    {
        std::weak_ptr<const void> left;
        std::optional<View> theirs;
        std::thread([&] {
            auto v = View::offscreen(16, 16);
            auto s = bs::Solid::cuboid(1, 1, 1);
            if (v && s) {
                left = cadaclysm::detail::ViewAccess::keep(*s);
                if (v->show(*s)) theirs.emplace(std::move(*v));
            }
        }).join();
        CHECK(theirs.has_value(), "a view made and shown on another thread");
        theirs.reset();
        CHECK(!left.expired(), "a view dropped off its thread let go of what its items keep");
    }

    if (item) CHECK(item->remove(), "remove");
    CHECK(kept.expired(), "a removed item still holds its solid");
    ViewImage removed = frame_of(view);
    CHECK(!removed.rgba.empty() && !empty.rgba.empty() && at(removed, 160, 120) == at(empty, 160, 120),
          "a removed item is still drawn");

    if (!mechanism.empty()) {
        // A scene shown; a real pose drawn in place of the rest transforms, the rest pose back,
        // an empty list refused by the library (not read as the rest pose).
        auto scene = cadaclysm::open(mechanism);
        CHECK(scene, "open %s: %s", mechanism.c_str(), refused(scene).c_str());
        ViewImage whole;
        if (scene) {
            auto shown = view.show(*scene);
            CHECK(shown, "show the mechanism: %s", refused(shown).c_str());
            CHECK(view.standard("iso"), "iso");
            CHECK(view.frame(), "frame the mechanism");
            whole = frame_of(view);
            CHECK(changed(whole, blank) > 0, "the scene drew nothing");
            std::vector<cadaclysm::State> states = scene->states();
            CHECK(!states.empty(), "mechanism-solid.stp records no state");
            if (shown && !states.empty()) {
                auto pose = scene->pose_state(states[0]);
                CHECK(pose, "pose_state: %s", refused(pose).c_str());
                if (pose) {
                    auto posed = shown->node_transforms(pose->transforms);
                    CHECK(posed, "node_transforms: %s", refused(posed).c_str());
                    CHECK(changed(whole, frame_of(view)) > 0, "the pose moved nothing on screen");
                }
                CHECK(shown->node_transforms(std::nullopt), "the rest pose");
                std::size_t back = changed(whole, frame_of(view));
                CHECK(back < 320 * 240 / 1000, "std::nullopt did not put the rest pose back: %zu pixels", back);
                std::string none = refused(shown->node_transforms(std::vector<std::array<double, 16>>{}));
                CHECK(has(none, "0 transforms were given"), "an empty transform list: %s", none.c_str());
            }
            if (shown) CHECK(shown->remove(), "remove the scene");

            // A nested node: its scene with the siblings along its path hidden, which draws
            // something and less than the whole scene.
            std::optional<cadaclysm::Node> leaf = nested_leaf(*scene);
            CHECK(leaf.has_value(), "mechanism-solid.stp has no leaf below a root with geometry");
            if (leaf) {
                std::vector<cadaclysm::Node> chain;
                for (std::optional<cadaclysm::Node> n = leaf; n; n = n->parent()) chain.insert(chain.begin(), *n);
                std::set<std::uint32_t> expected;
                std::vector<cadaclysm::Node> level = scene->roots();
                for (const cadaclysm::Node& on : chain) {
                    for (const cadaclysm::Node& other : level)
                        if (other.index() != on.index()) expected.insert(other.index());
                    level = on.children();
                }
                CHECK(!expected.empty(), "the leaf has no sibling anywhere on its path: the hiding would prove nothing");
                std::vector<std::uint32_t> hidden = cadaclysm::detail::ViewAccess::siblings_along_path(*leaf);
                CHECK(std::set<std::uint32_t>(hidden.begin(), hidden.end()) == expected && hidden.size() == expected.size(),
                      "the wrong nodes are hidden: %zu of %zu", hidden.size(), expected.size());
                auto one = view.show(*leaf);
                CHECK(one, "show the node: %s", refused(one).c_str());
                CHECK(view.standard("iso"), "iso");
                CHECK(view.frame(), "frame the node");
                ViewImage alone = frame_of(view);
                CHECK(changed(alone, blank) > 0, "the node drew nothing");
                CHECK(changed(alone, blank) < changed(whole, blank), "the siblings still draw: the node is as much as the scene");
                if (one) CHECK(one->remove(), "remove the node");
            }
        }

        // A Scene item keeps the scene alive after the Scene is gone; when the last owner goes,
        // the scene closes and the items showing it (a node's too) are removed first.
        {
            std::weak_ptr<const void> scene_kept;
            cadaclysm::Result<cadaclysm::Item> whole_item = cadaclysm::Error{"not shown"};
            cadaclysm::Result<cadaclysm::Item> node_item = cadaclysm::Error{"not shown"};
            {
                auto doc = cadaclysm::open(mechanism);
                CHECK(doc, "open for the last owner");
                if (doc) {
                    scene_kept = cadaclysm::detail::ViewAccess::keep(*doc);
                    whole_item = view.show(*doc);
                    std::optional<cadaclysm::Node> leaf = nested_leaf(*doc);
                    if (leaf) node_item = view.show(*leaf);
                }
            }
            CHECK(whole_item && node_item, "show the scene and its node");
            CHECK(!scene_kept.expired(), "the item let go of the scene it shows");
            if (node_item) CHECK(node_item->colour({1, 0, 0}), "the node item stopped drawing while its scene is kept");
            if (whole_item) CHECK(whole_item->remove(), "remove the scene item");
            CHECK(scene_kept.expired(), "a removed item still holds its scene");
            if (node_item) CHECK(!node_item->colour({1, 0, 0}), "a node item of a dropped scene is still shown");
            CHECK(view.draw(), "the view no longer draws after its scene was dropped");
        }

        // Two roots: a root's siblings are the other root, and it draws less than both.
        {
            std::string two = scratch + "/view_test_two.stp";
            auto small = bs::Solid::cuboid(1, 1, 1);
            auto big = bs::Solid::cuboid(2, 2, 2);
            auto moved = big ? big->translate(5, 0, 0) : cadaclysm::Result<bs::Solid>(cadaclysm::Error{"no cuboid"});
            CHECK(small && moved, "the two cuboids");
            if (small && moved) {
                auto written = bs::write_step(two, {std::cref(*small), std::cref(*moved)});
                CHECK(written, "write %s: %s", two.c_str(), refused(written).c_str());
                auto doc = cadaclysm::open(two);
                CHECK(doc, "open %s: %s", two.c_str(), refused(doc).c_str());
                if (doc) {
                    std::vector<cadaclysm::Node> roots = doc->roots();
                    CHECK(roots.size() == 2, "%zu roots", roots.size());
                    if (roots.size() == 2) {
                        std::vector<std::uint32_t> hidden = cadaclysm::detail::ViewAccess::siblings_along_path(roots[0]);
                        CHECK(hidden.size() == 1 && hidden[0] == roots[1].index(), "a root's siblings: %zu", hidden.size());
                        auto both = view.show(*doc);
                        CHECK(view.standard("iso") && view.frame(), "frame both");
                        ViewImage both_image = frame_of(view);
                        if (both) CHECK(both->remove(), "remove both");
                        auto one = view.show(roots[0]);
                        CHECK(one, "show a root: %s", refused(one).c_str());
                        ViewImage one_image = frame_of(view);  // the same camera as both
                        CHECK(changed(one_image, blank) > 0 && changed(one_image, blank) < changed(both_image, blank),
                              "a root drew as much as both: %zu vs %zu", changed(one_image, blank),
                              changed(both_image, blank));
                        if (one) CHECK(one->remove(), "remove the root");
                    }
                }
            }
        }

        // Python's words for a closed scene and a closed solid.
        {
            auto doc = cadaclysm::open(mechanism);
            if (doc) {
                doc->close();
                CHECK(refused(view.show(*doc)) == "mechanism-solid.stp: the scene is closed", "%s",
                      refused(view.show(*doc)).c_str());
                CHECK(refused(doc->show()) == "mechanism-solid.stp: the scene is closed", "%s", refused(doc->show()).c_str());
            }
        }

        // Scene::close removes the items of this thread's views that show it, first.
        {
            auto doc = cadaclysm::open(mechanism);
            CHECK(doc, "open again");
            if (doc) {
                auto all = view.show(*doc);
                std::optional<cadaclysm::Node> leaf = nested_leaf(*doc);
                auto part = leaf ? view.show(*leaf) : cadaclysm::Result<cadaclysm::Item>(cadaclysm::Error{"no leaf"});
                CHECK(all && part, "show the scene and its node");
                doc->close();
                CHECK(doc->closed(), "the scene stayed open");
                CHECK(view.draw(), "the view no longer draws after its scene closed");
                if (all) CHECK(!all->colour({1, 0, 0}), "an item of a closed scene is still shown");
                if (part) CHECK(!part->colour({1, 0, 0}), "a node item of a closed scene is still shown");
            }
        }

        // ... and stays open while a view of another thread shows it.
        {
            auto doc = cadaclysm::open(mechanism);
            CHECK(doc, "open a third time");
            if (doc) {
                std::mutex m;
                std::condition_variable cv;
                int stage = 0;
                std::string failed;
                std::thread other([&] {
                    {
                        auto ov = View::offscreen(48, 48);
                        if (!ov) failed = "offscreen: " + refused(ov);
                        auto it = ov ? ov->show(*doc) : cadaclysm::Result<cadaclysm::Item>(cadaclysm::Error{""});
                        if (ov && !it) failed = "show: " + refused(it);
                        {
                            std::lock_guard<std::mutex> lock(m);
                            stage = 1;
                        }
                        cv.notify_all();
                        std::unique_lock<std::mutex> lock(m);
                        cv.wait(lock, [&] { return stage == 2; });
                        if (ov && failed.empty()) {
                            auto again = ov->draw();  // reads the scene: it must still be open
                            if (!again) failed = "draw after the refused close: " + refused(again);
                        }
                    }  // the view is destroyed here, on its own thread
                });
                {
                    std::unique_lock<std::mutex> lock(m);
                    cv.wait(lock, [&] { return stage == 1; });
                }
                doc->close();
                CHECK(!doc->closed(), "the scene was closed under another thread's view");
                {
                    std::lock_guard<std::mutex> lock(m);
                    stage = 2;
                }
                cv.notify_all();
                other.join();
                CHECK(failed.empty(), "the other thread: %s", failed.c_str());
                doc->close();
                CHECK(doc->closed(), "the scene would not close once the other view was gone");
            }
        }
    }

    // Last: the rigged calls really run (the background turns black).
    rigged_half(view, **wgpu, mechanism);

    CHECK(view.close(), "close");
    CHECK(view.close(), "close twice");
    CHECK(view.closed(), "closed");
    auto refused_lines = view.show_lines({0, 0, 0, 1, 1, 1});
    CHECK(refused(refused_lines) == "cadaclysm_view_show_lines: the view is closed", "%s",
          refused(refused_lines).c_str());
    if (item)
        CHECK(refused(item->colour({1, 0, 0})) == "cadaclysm_view_set_colour: the view is closed", "%s",
              refused(item->colour({1, 0, 0})).c_str());

    // A moved-from View names no library and is closed.
    {
        auto from = View::offscreen(8, 8);
        if (from) {
            View to = std::move(*from);
            CHECK(from->library() == nullptr && from->closed(), "a moved-from View");
            CHECK(to.library() == *wgpu && !to.closed(), "the moved-to View");
        }
    }

    // Alive at exit: a View showing two Scenes, all in static storage made before main --
    // their destructors run after every function-local static's (the registry must outlive
    // them) and after this thread's thread_locals (no view call may run then): the scene
    // whose node is shown is released at its destruction, the View's destructor comes last.
    if (!mechanism.empty()) {
        auto doc = cadaclysm::open(mechanism);
        auto other = cadaclysm::open(mechanism);
        auto last = View::offscreen(16, 16);
        if (doc && other && last) {
            g_view.emplace(std::move(*last));
            g_scene.emplace(std::move(*doc));
            g_other.emplace(std::move(*other));
            auto shown = g_view->show(*g_scene);
            std::optional<cadaclysm::Node> leaf = nested_leaf(*g_other);
            auto part = leaf ? g_view->show(*leaf) : cadaclysm::Result<cadaclysm::Item>(cadaclysm::Error{"no leaf"});
            CHECK(shown && part, "the views alive at exit");
        }
    }

    if (failures) return 1;
    std::printf("view: ok\n");
    return 0;
}
