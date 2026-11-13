#define _CRT_SECURE_NO_WARNINGS  // std::fopen under MSVC /W4 /WX and Windows clang -Werror
// view_loader.h on its own: the search and its messages, the camera maths, the PNG
// writer, a refused non-library, the ABI 1.25 the table needs (a 1.24 stand-in refused), and -- over a table of fakes -- the order and the
// refusals of cvl_draw_object, cvl_pick and cvl_snap. Needs no view library and no GPU; the exit
// code is the verdict.
#include <cadaclysm/view_loader.h>

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <filesystem>
#include <vector>

static int failures = 0;
#define CHECK(cond, ...)                                     \
    do {                                                     \
        if (!(cond)) {                                       \
            std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
            std::fprintf(stderr, __VA_ARGS__);               \
            std::fprintf(stderr, "\n");                      \
            ++failures;                                      \
        }                                                    \
    } while (0)

static bool starts(const std::string& s, const char* p) { return s.rfind(p, 0) == 0; }
static bool ends(const std::string& s, const char* p) {
    std::size_t n = std::strlen(p);
    return s.size() >= n && s.compare(s.size() - n, n, p) == 0;
}

// ---- a view library of fakes: each call is logged; `refuse` names the one that fails --

namespace fake {
std::string log;         // "name arg;" per call
std::string error;       // what last_error answers
std::string refuse;      // the call that fails
std::string refusal;     // its message ("" tests the fallback)
std::string hint_seen;   // CADACLYSM_TERMINAL_GRAPHICS while create ran ("-" unset)
std::string flush_path;  // a file whose buffered bytes create looks for
long flushed = -1;       // its size on disk while create ran
int pick_waits = 0;      // pick_result answers `wait_message` this many times first
std::string wait_message;
std::string pick_refusal;  // pick_result's message after the waits ("": it lands)
int snap_waits = 0;        // snap_result answers `snap_wait_message` this many times first
std::string snap_wait_message;
std::string snap_refusal;  // snap_result's message after the waits ("": it lands)
CadaclysmViewOptions options;
int view_object = 0;

void reset() {
    log.clear();
    error.clear();
    refuse.clear();
    refusal.clear();
    hint_seen.clear();
    flush_path.clear();
    flushed = -1;
    pick_waits = 0;
    wait_message = "cadaclysm_view_pick_result: no pick result";
    pick_refusal.clear();
    snap_waits = 0;
    snap_wait_message = "cadaclysm_view_snap_result: no snap result";
    snap_refusal.clear();
    std::memset(&options, 0, sizeof options);
}

void note(const std::string& call) { log += call + ";"; }

// true when `call` is the refused one, setting the error as the library would.
bool refused(const char* call) {
    if (refuse == call) {
        error = refusal;
        return true;
    }
    error.clear();
    return false;
}

CadaclysmView* view() { return reinterpret_cast<CadaclysmView*>(&view_object); }
}  // namespace fake

extern "C" {
static const char* fake_last_error(void) { return fake::error.c_str(); }
static CadaclysmView* fake_create(const CadaclysmViewWindow*, const CadaclysmViewOptions* o) {
    char value[256];
    fake::note("create");
    fake::options = *o;
    fake::hint_seen = cvl_getenv("CADACLYSM_TERMINAL_GRAPHICS", value, sizeof value) ? value : "-";
    if (!fake::flush_path.empty()) {
        std::FILE* f = std::fopen(fake::flush_path.c_str(), "rb");
        if (f) {
            std::fseek(f, 0, SEEK_END);
            fake::flushed = std::ftell(f);
            std::fclose(f);
        }
    }
    return fake::refused("create") ? nullptr : fake::view();
}
static void fake_destroy(CadaclysmView*) { fake::note("destroy"); }
static bool fake_run(CadaclysmView*, CadaclysmViewCamera*, CadaclysmViewPick*) {
    fake::note("run");
    return !fake::refused("run");
}
static bool fake_draw(CadaclysmView*) {
    fake::note("draw");
    return !fake::refused("draw");
}
static uint32_t fake_show(CadaclysmView*, const CadaclysmScene*) {
    fake::note("show");
    return fake::refused("show") ? 0u : 7u;
}
static uint32_t fake_show_solid(CadaclysmView*, const CadaclysmBlacksmithSolid*, double, const float*) {
    fake::note("show_solid");
    return fake::refused("show_solid") ? 0u : 7u;
}
static bool fake_set_node_transforms(CadaclysmView*, uint32_t item, const double* m, uint32_t count) {
    fake::note("transforms " + std::to_string(item) + " " + std::to_string(count) + (m ? "" : " NULL"));
    return !fake::refused("transforms");
}
static bool fake_set_node_visible(CadaclysmView*, uint32_t item, uint32_t node, bool visible) {
    fake::note("visible " + std::to_string(item) + " " + std::to_string(node) + (visible ? " on" : " off"));
    return !fake::refused("visible");
}
static bool fake_set_layer(CadaclysmView*, uint32_t layer, bool on) {
    fake::note("layer " + std::to_string(layer) + (on ? " on" : " off"));
    return !fake::refused("layer");
}
static bool fake_standard(CadaclysmView*, uint32_t which) {
    fake::note("standard " + std::to_string(which));
    return !fake::refused("standard");
}
static void fake_orbit(CadaclysmView*, float dx, float dy) {
    char text[64];
    std::snprintf(text, sizeof text, "orbit %.2f %.2f", dx, dy);
    fake::note(text);
    fake::refused("orbit");
}
static bool fake_frame(CadaclysmView*, uint32_t item) {
    fake::note("frame " + std::to_string(item));
    return !fake::refused("frame");
}
static bool fake_frame_node(CadaclysmView*, uint32_t item, uint32_t node) {
    fake::note("frame_node " + std::to_string(item) + " " + std::to_string(node));
    return !fake::refused("frame_node");
}
static void fake_zoom(CadaclysmView*, float steps) {
    char text[64];
    std::snprintf(text, sizeof text, "zoom %.2f", steps);
    fake::note(text);
    fake::refused("zoom");
}
static void fake_request_pick_in(CadaclysmView*, uint32_t viewport, uint32_t x, uint32_t y) {
    fake::note("request_pick_in " + std::to_string(viewport) + " " + std::to_string(x) + " " + std::to_string(y));
    fake::refused("request_pick_in");
}
static bool fake_pick_result(CadaclysmView*, CadaclysmViewPick* out) {
    fake::note("pick_result");
    if (fake::pick_waits > 0) {
        --fake::pick_waits;
        fake::error = fake::wait_message;
        return false;
    }
    if (!fake::pick_refusal.empty()) {
        fake::error = fake::pick_refusal;
        return false;
    }
    fake::error.clear();
    out->item = 7;
    out->node = 3;
    out->face = 11;
    out->clicks = 2;
    out->has_point = 1;
    out->point[0] = 1.5f;
    out->point[1] = -2.0f;
    out->point[2] = 0.25f;
    out->overlay = 1;
    return true;
}
static void fake_request_snap_in(CadaclysmView*, uint32_t viewport, uint32_t x, uint32_t y) {
    fake::note("request_snap_in " + std::to_string(viewport) + " " + std::to_string(x) + " " + std::to_string(y));
    fake::refused("request_snap_in");
}
static bool fake_snap_result(CadaclysmView*, CadaclysmViewSnap* out) {
    fake::note("snap_result");
    if (fake::snap_waits > 0) {
        --fake::snap_waits;
        fake::error = fake::snap_wait_message;
        return false;
    }
    if (!fake::snap_refusal.empty()) {
        fake::error = fake::snap_refusal;
        return false;
    }
    fake::error.clear();
    out->kind = CADACLYSM_VIEW_SNAP_VERTEX;
    out->point[0] = -1.0;
    out->point[1] = 1.0;
    out->point[2] = 0.0;
    out->item = 7;
    out->node = 3;
    out->face = 11;
    out->edge = 2;
    out->tangent[1] = 1.0f;
    out->radius = 0.5;
    out->distance_px = 2.5f;
    out->clicks = 1;
    return true;
}
}

static CvlTable fake_table(const char* label) {
    CvlTable t;
    std::memset(&t, 0, sizeof t);
    std::snprintf(t.label, sizeof t.label, "%s", label);
    t.last_error = fake_last_error;
    t.create = fake_create;
    t.destroy = fake_destroy;
    t.run = fake_run;
    t.draw = fake_draw;
    t.show = fake_show;
    t.show_solid = fake_show_solid;
    t.set_node_transforms = fake_set_node_transforms;
    t.set_node_visible = fake_set_node_visible;
    t.set_layer = fake_set_layer;
    t.standard = fake_standard;
    t.orbit = fake_orbit;
    t.frame = fake_frame;
    t.frame_node = fake_frame_node;
    t.zoom = fake_zoom;
    t.request_pick_in = fake_request_pick_in;
    t.pick_result = fake_pick_result;
    t.request_snap_in = fake_request_snap_in;
    t.snap_result = fake_snap_result;
    return t;
}

static CvlShow plain_show() {
    CvlShow o;
    std::memset(&o, 0, sizeof o);
    o.azimuth = NAN;
    o.elevation = NAN;
    o.edges = 1;
    return o;
}

// One cvl_draw_object of a solid (or, `scene`, a scene) under the fakes.
static int draw(const CvlTable& t, int interactive, const CvlShow& o, std::vector<char>& err,
                const double* transforms = nullptr, uint32_t transform_count = 0, const uint32_t* hide = nullptr,
                uint32_t hide_count = 0, uint32_t node = CVL_NO_NODE, bool scene = false) {
    int solid_object = 0;
    const CadaclysmBlacksmithSolid* solid =
        scene ? nullptr : reinterpret_cast<const CadaclysmBlacksmithSolid*>(&solid_object);
    const CadaclysmScene* the_scene = scene ? reinterpret_cast<const CadaclysmScene*>(&solid_object) : nullptr;
    err[0] = 0;
    return cvl_draw_object(&t, interactive, "iso", solid, 0.05, the_scene, transforms, transform_count, hide,
                           hide_count, node, &o, nullptr, nullptr, err.data(), err.size());
}

static void test_draw_object(const char* empty) {
    std::vector<char> err(CVL_ERROR, 0);
    CvlTable wgpu = fake_table("cadaclysm-view 0.9.0");
    CvlTable terminal = fake_table("cadaclysm-terminal 0.9.0");
    CvlTable mine = fake_table("my-view 1.0");

    CHECK(cvl_is_wgpu(&wgpu) && !cvl_is_terminal(&wgpu), "wgpu label");
    CHECK(cvl_is_terminal(&terminal) && !cvl_is_wgpu(&terminal), "terminal label");
    CHECK(!cvl_is_terminal(&mine) && !cvl_is_wgpu(&mine), "a library of one's own");

    // cvl_error: the library's message, else Python's fallback.
    fake::reset();
    fake::error = "it broke";
    CHECK(std::strcmp(cvl_error(&wgpu), "it broke") == 0, "%s", cvl_error(&wgpu));
    fake::error.clear();
    CHECK(std::strcmp(cvl_error(&wgpu), "the view library failed") == 0, "%s", cvl_error(&wgpu));

    // present()'s order: show, transforms, the hidden siblings, the edges layer, the aim
    // (standard, orbit, frame 0), the node framed, the zoom; then run, then destroy.
    fake::reset();
    CvlShow o = plain_show();
    o.zoom = 2.0;
    o.y_up = 1;
    o.width = 640;
    o.height = 480;
    o.title = "part.step";
    const double pose[32] = {0};
    const uint32_t hide[2] = {3, 5};
    CHECK(draw(wgpu, 1, o, err, pose, 2, hide, 2, 9, true), "%s", err.data());
    CHECK(fake::log ==
              "create;show;transforms 7 2;visible 7 3 off;visible 7 5 off;layer 1 on;standard 1;orbit -69.81 48.87;"
              "frame 0;frame_node 7 9;zoom 6.58;run;destroy;",
          "order: %s", fake::log.c_str());
    CHECK(fake::options.size == sizeof(CadaclysmViewOptions) && fake::options.y_up == 1 &&
              fake::options.width == 640 && fake::options.height == 480 && fake::options.offscreen == 0 &&
              fake::options.surfaces == CADACLYSM_VIEW_SURFACES_EXACT && fake::options.title &&
              std::strcmp(fake::options.title, "part.step") == 0,
          "create's options");

    // The top view looks straight down (no orbit); no zoom, no node, no edges.
    fake::reset();
    o = plain_show();
    o.view = "top";
    o.edges = 0;
    CHECK(draw(wgpu, 1, o, err), "%s", err.data());
    CHECK(fake::log == "create;show_solid;layer 1 off;standard 0;frame 0;run;destroy;", "top: %s", fake::log.c_str());
    CHECK(fake::options.title == nullptr, "an untitled view passes NULL (the library's \"Cadaclysm\")");

    // An explicit az/el replaces the view's own: az -90, el 0 is the front, no orbit.
    fake::reset();
    o = plain_show();
    o.azimuth = -90.0;
    o.elevation = 0.0;
    CHECK(draw(wgpu, 1, o, err), "%s", err.data());
    CHECK(fake::log == "create;show_solid;layer 1 on;standard 1;frame 0;run;destroy;", "front: %s", fake::log.c_str());

    // An empty pose reaches the library (a non-NULL pointer, count 0), which refuses it.
    fake::reset();
    fake::refuse = "transforms";
    fake::refusal = "cadaclysm_view_set_node_transforms: 0 transforms were given for a scene of 4 nodes";
    o = plain_show();
    CHECK(!draw(wgpu, 1, o, err, pose, 0, nullptr, 0, CVL_NO_NODE, true), "an empty pose was accepted");
    CHECK(fake::log == "create;show;transforms 7 0;destroy;", "empty pose: %s", fake::log.c_str());
    CHECK(std::string(err.data()) == fake::refusal, "%s", err.data());

    // A still everywhere but wgpu's show(): the terminal and a library of one's own draw
    // once, wgpu's show() and every view() run.
    struct {
        CvlTable* table;
        int interactive;
        const char* last;
    } stills[] = {{&terminal, 0, "draw;destroy;"}, {&mine, 0, "draw;destroy;"},   {&wgpu, 0, "run;destroy;"},
                  {&terminal, 1, "run;destroy;"},  {&mine, 1, "run;destroy;"},     {&wgpu, 1, "run;destroy;"}};
    for (const auto& s : stills) {
        fake::reset();
        o = plain_show();
        CHECK(draw(*s.table, s.interactive, o, err), "%s", err.data());
        CHECK(ends(fake::log, s.last), "%s interactive %d: %s", s.table->label, s.interactive, fake::log.c_str());
    }

    // Refusals of the hide, the layer and frame_node fail the call (the library's message,
    // or the fallback) and still destroy the view; nothing after them runs.
    struct {
        const char* call;
        const char* log;
    } refusals[] = {
        {"visible", "create;show;visible 7 3 off;destroy;"},
        {"layer", "create;show;visible 7 3 off;visible 7 5 off;layer 1 on;destroy;"},
        {"frame_node",
         "create;show;visible 7 3 off;visible 7 5 off;layer 1 on;standard 1;orbit -69.81 48.87;frame 0;"
         "frame_node 7 9;destroy;"},
        {"show", "create;show;destroy;"},
        {"run",
         "create;show;visible 7 3 off;visible 7 5 off;layer 1 on;standard 1;orbit -69.81 48.87;frame 0;"
         "frame_node 7 9;run;destroy;"},
    };
    for (const auto& r : refusals) {
        for (int fallback = 0; fallback < 2; ++fallback) {
            fake::reset();
            fake::refuse = r.call;
            fake::refusal = fallback ? "" : std::string("cadaclysm_view_") + r.call + ": refused";
            o = plain_show();
            CHECK(!draw(wgpu, 1, o, err, nullptr, 0, hide, 2, 9, true), "%s refused but the call succeeded", r.call);
            CHECK(fake::log == r.log, "%s refused: %s", r.call, fake::log.c_str());
            std::string want = fallback ? "the view library failed" : fake::refusal;
            CHECK(std::string(err.data()) == want, "%s refused: '%s'", r.call, err.data());
        }
    }

    // The aim's own calls stay unchecked (Python's _aim and _zoom): a refused standard,
    // orbit, frame(0) or zoom does not stop the draw.
    for (const char* call : {"standard", "orbit", "frame", "zoom"}) {
        fake::reset();
        fake::refuse = call;
        fake::refusal = "ignored";
        o = plain_show();
        o.zoom = 2.0;
        CHECK(draw(wgpu, 1, o, err), "a refused %s failed the draw: %s", call, err.data());
    }

    // A failed create: the bare message, the skin's hint appended only for "no display";
    // nothing to destroy.
    const char* hint = " -- draw without a display with View::offscreen(width, height), or the terminal";
    struct {
        const char* refusal;
        const char* want;
    } creates[] = {
        {"cadaclysm_view_create: no display (WAYLAND_DISPLAY and DISPLAY are unset)",
         "cadaclysm_view_create: no display (WAYLAND_DISPLAY and DISPLAY are unset) -- draw without a display with "
         "View::offscreen(width, height), or the terminal"},
        {"cadaclysm_view_create: no adapter", "cadaclysm_view_create: no adapter"},
        {"", "the view library failed"},
    };
    for (const auto& c : creates) {
        fake::reset();
        fake::refuse = "create";
        fake::refusal = c.refusal;
        o = plain_show();
        o.no_display = hint;
        CHECK(!draw(wgpu, 1, o, err), "a failed create succeeded");
        CHECK(std::string(err.data()) == c.want, "create: '%s'", err.data());
        CHECK(fake::log == "create;", "create: %s", fake::log.c_str());
    }
    fake::reset();
    fake::refuse = "create";
    fake::refusal = "cadaclysm_view_create: no display";
    o = plain_show();
    CHECK(!draw(wgpu, 1, o, err) && std::string(err.data()) == "cadaclysm_view_create: no display",
          "no hint given: '%s'", err.data());

    // An unknown view name: Python's message, before any create.
    fake::reset();
    o = plain_show();
    o.view = "sideways";
    CHECK(!draw(wgpu, 1, o, err), "sideways drew");
    CHECK(std::string(err.data()) == "view 'sideways': one of front, back, left, right, top, bottom, iso", "%s",
          err.data());
    CHECK(fake::log.empty(), "sideways: %s", fake::log.c_str());

    // The hint is CADACLYSM_TERMINAL_GRAPHICS around the create only: set while it runs,
    // then restored -- unset again, or the value it had.
    cvl_setenv("CADACLYSM_TERMINAL_GRAPHICS", nullptr);
    fake::reset();
    o = plain_show();
    o.hint = "sixel";
    CHECK(draw(terminal, 0, o, err), "%s", err.data());
    char value[256];
    CHECK(fake::hint_seen == "sixel", "create saw '%s'", fake::hint_seen.c_str());
    CHECK(!cvl_getenv("CADACLYSM_TERMINAL_GRAPHICS", value, sizeof value), "left set to %s", value);
    cvl_setenv("CADACLYSM_TERMINAL_GRAPHICS", "blocks");
    fake::reset();
    o.hint = "kitty";
    CHECK(draw(terminal, 0, o, err), "%s", err.data());
    CHECK(fake::hint_seen == "kitty", "create saw '%s'", fake::hint_seen.c_str());
    CHECK(cvl_getenv("CADACLYSM_TERMINAL_GRAPHICS", value, sizeof value) && std::string(value) == "blocks",
          "not restored to blocks");
    fake::reset();
    o.hint = nullptr;
    CHECK(draw(terminal, 0, o, err), "%s", err.data());
    CHECK(fake::hint_seen == "blocks", "no hint, yet create saw '%s'", fake::hint_seen.c_str());
    cvl_setenv("CADACLYSM_TERMINAL_GRAPHICS", nullptr);

    // Buffered output is flushed before the view is made (Python flushes before a still):
    // bytes a fully buffered stream holds are on disk by the time create runs.
    std::string flush_path = std::string(empty) + "/view_loader_flush.txt";
    std::FILE* pending = std::fopen(flush_path.c_str(), "wb");
    CHECK(pending != nullptr, "could not write %s", flush_path.c_str());
    if (pending) {
        static char buffer[4096];
        std::setvbuf(pending, buffer, _IOFBF, sizeof buffer);
        std::fputs("pending", pending);
        fake::reset();
        fake::flush_path = flush_path;
        o = plain_show();
        CHECK(draw(terminal, 0, o, err), "%s", err.data());
        CHECK(fake::flushed == 7, "create saw %ld bytes of 7 on disk", fake::flushed);
        std::fclose(pending);
    }
}

static void test_pick() {
    std::vector<char> err(CVL_ERROR, 0);
    CvlTable t = fake_table("cadaclysm-view 0.9.0");
    CadaclysmViewPick out;

    // Never drawn: drawn first; then asked; then drawn until the answer lands.
    fake::reset();
    fake::pick_waits = 2;
    int drawn = 0;
    CHECK(cvl_pick(&t, fake::view(), &drawn, 1, 10, 20, &out, err.data(), err.size()), "%s", err.data());
    CHECK(drawn == 1, "drawn not set");
    CHECK(out.size == sizeof out && out.item == 7 && out.node == 3 && out.face == 11, "the pick %u %u %u", out.item,
          out.node, out.face);
    // 1.8's and 1.24's fields come through whole: a 40-byte answer, the clicks, the point and
    // the overlay flag.
    CHECK(sizeof out == 40 && out.clicks == 2 && out.has_point == 1 && out.point[0] == 1.5f && out.point[1] == -2.0f &&
              out.point[2] == 0.25f && out.overlay == 1,
          "the pick's fields: size %u, clicks %u, has_point %u, overlay %u", static_cast<unsigned>(sizeof out), out.clicks,
          out.has_point, out.overlay);
    CHECK(fake::log == "draw;request_pick_in 1 10 20;draw;pick_result;draw;pick_result;draw;pick_result;", "%s",
          fake::log.c_str());

    // Drawn already: asked at once.
    fake::reset();
    CHECK(cvl_pick(&t, fake::view(), &drawn, 0, 1, 2, &out, err.data(), err.size()), "%s", err.data());
    CHECK(fake::log == "request_pick_in 0 1 2;draw;pick_result;", "%s", fake::log.c_str());

    // A refused request: its message, at once.
    fake::reset();
    fake::refuse = "request_pick_in";
    fake::refusal = "cadaclysm_view_request_pick_in: viewport 4 of 1";
    CHECK(!cvl_pick(&t, fake::view(), &drawn, 4, 1, 2, &out, err.data(), err.size()), "a refused request picked");
    CHECK(std::string(err.data()) == fake::refusal, "%s", err.data());
    CHECK(fake::log == "request_pick_in 4 1 2;", "%s", fake::log.c_str());

    // A failure other than "no pick result": its message, no more waiting.
    fake::reset();
    fake::pick_waits = 1;
    fake::pick_refusal = "cadaclysm_view_pick_result: the window is closed";
    CHECK(!cvl_pick(&t, fake::view(), &drawn, 0, 1, 2, &out, err.data(), err.size()), "a failed pick picked");
    CHECK(std::string(err.data()) == fake::pick_refusal, "%s", err.data());
    CHECK(fake::log == "request_pick_in 0 1 2;draw;pick_result;draw;pick_result;", "%s", fake::log.c_str());

    // A refused draw with no message: the fallback; a first draw refused leaves `drawn` 0.
    fake::reset();
    fake::refuse = "draw";
    drawn = 0;
    CHECK(!cvl_pick(&t, fake::view(), &drawn, 0, 1, 2, &out, err.data(), err.size()), "a refused draw picked");
    CHECK(std::string(err.data()) == "the view library failed" && drawn == 0, "%s (drawn %d)", err.data(), drawn);

    // Never landing: 200 draws, then Python's message with the last wait.
    fake::reset();
    fake::pick_waits = 1000;
    drawn = 1;
    CHECK(!cvl_pick(&t, fake::view(), &drawn, 0, 1, 2, &out, err.data(), err.size()), "an endless wait picked");
    CHECK(std::string(err.data()) == "pick: the answer never landed (cadaclysm_view_pick_result: no pick result)", "%s",
          err.data());
    CHECK(fake::pick_waits == 800, "%d waits answered, not 200", 1000 - fake::pick_waits);

    // A wait whose message is longer than the copy kept of it: still read as a wait (the
    // suffix is checked on the whole message), so the pick lands.
    fake::reset();
    fake::pick_waits = 1;
    fake::wait_message = "cadaclysm_view_pick_result: " + std::string(1500, 'x') + ": no pick result";
    CHECK(cvl_pick(&t, fake::view(), &drawn, 0, 1, 2, &out, err.data(), err.size()), "a long wait failed: %.80s",
          err.data());
}

// ---- the search: found paths, first hit wins, the variable as a file or a directory ----

static void write_file(const std::string& path, const char* text) {
    std::FILE* f = std::fopen(path.c_str(), "wb");
    CHECK(f != nullptr, "could not write %s", path.c_str());
    if (f) {
        std::fputs(text, f);
        std::fclose(f);
    }
}

static void test_search(const char* empty) {
    const char* variable = "CADACLYSM_VIEW_ABSENT_LIBRARY";
    char file[256];
    char out[CVL_PATH];
    std::vector<char> err(CVL_ERROR, 0);
    cvl_file_name("cadaclysm_view_absent", file, sizeof file);
    std::string first = std::string(empty) + "/view_loader_first";
    std::string second = std::string(empty) + "/view_loader_second";
    std::string bare = std::string(empty) + "/view_loader_bare";
    std::error_code ec;
    for (const std::string& d : {first, second, bare}) std::filesystem::create_directories(d, ec);
    write_file(first + "/" + file, "first");
    write_file(second + "/" + file, "second");

    // The given dirs in order: the first that holds the file wins.
    const char* dirs[] = {empty, first.c_str(), second.c_str()};
    cvl_setenv(variable, nullptr);
    out[0] = 0;
    CHECK(cvl_find("cadaclysm_view_absent", variable, "wgpu", dirs, 3, out, sizeof out, err.data(), err.size()), "%s",
          err.data());
    CHECK(std::string(out) == first + "/" + file, "found %s", out);
    const char* reversed[] = {second.c_str(), first.c_str()};
    CHECK(cvl_find("cadaclysm_view_absent", variable, "wgpu", reversed, 2, out, sizeof out, err.data(), err.size()),
          "%s", err.data());
    CHECK(std::string(out) == second + "/" + file, "found %s", out);

    // The variable naming the library itself, or its directory, wins over the dirs.
    std::string named = second + "/" + file;
    cvl_setenv(variable, named.c_str());
    CHECK(cvl_find("cadaclysm_view_absent", variable, "wgpu", dirs, 3, out, sizeof out, err.data(), err.size()) &&
              std::string(out) == named,
          "variable as the file: %s %s", out, err.data());
    cvl_setenv(variable, second.c_str());
    CHECK(cvl_find("cadaclysm_view_absent", variable, "wgpu", dirs, 3, out, sizeof out, err.data(), err.size()) &&
              std::string(out) == named,
          "variable as the directory: %s %s", out, err.data());

    // The variable naming nothing, or a directory without the library: Python's messages
    // (the terminal's names the missing file, cadaclysm_view.py's does not).
    std::string missing = std::string(empty) + "/view_loader_missing";
    cvl_setenv(variable, missing.c_str());
    CHECK(!cvl_find("cadaclysm_view_absent", variable, "terminal", dirs, 3, out, sizeof out, err.data(), err.size()),
          "a missing path was found");
    CHECK(std::string(err.data()) == std::string(variable) + "=" + missing + " names nothing that exists", "%s",
          err.data());
    cvl_setenv(variable, bare.c_str());
    CHECK(!cvl_find("cadaclysm_view_absent", variable, "terminal", dirs, 3, out, sizeof out, err.data(), err.size()),
          "an empty directory was found");
    CHECK(std::string(err.data()) == std::string(variable) + "=" + bare + " names nothing that exists (no " + file +
                                         " in that directory)",
          "%s", err.data());
    CHECK(!cvl_find("cadaclysm_view_absent", variable, "wgpu", dirs, 3, out, sizeof out, err.data(), err.size()),
          "an empty directory was found");
    CHECK(std::string(err.data()) == std::string(variable) + "=" + bare + " names nothing that exists", "%s",
          err.data());
    cvl_setenv(variable, nullptr);
}

// ---- the PNG, decoded: chunks and CRCs, the zlib header, stored blocks, Adler-32 ----------

static std::uint32_t be32(const unsigned char* p) {
    return (std::uint32_t(p[0]) << 24) | (std::uint32_t(p[1]) << 16) | (std::uint32_t(p[2]) << 8) | p[3];
}

static std::vector<unsigned char> read_file(const std::string& path) {
    std::vector<unsigned char> bytes;
    std::FILE* p = std::fopen(path.c_str(), "rb");
    if (p) {
        int c;
        while ((c = std::fgetc(p)) != EOF) bytes.push_back(static_cast<unsigned char>(c));
        std::fclose(p);
    }
    return bytes;
}

// Decodes what cvl_write_png wrote and compares it with `rgba`; `blocks` is the number of
// stored blocks the size asks for.
static void check_png(const char* empty, std::uint32_t w, std::uint32_t h, std::size_t blocks) {
    std::vector<std::uint8_t> rgba(std::size_t(w) * h * 4);
    std::uint32_t seed = 12345u + w * 7u + h;
    for (auto& b : rgba) {
        seed = seed * 1103515245u + 12345u;
        b = static_cast<std::uint8_t>(seed >> 16);
    }
    std::vector<char> err(CVL_ERROR, 0);
    std::string path = std::string(empty) + "/view_loader_" + std::to_string(w) + "x" + std::to_string(h) + ".png";
    CHECK(cvl_write_png(path.c_str(), rgba.data(), w, h, err.data(), err.size()), "%s", err.data());
    std::vector<unsigned char> png = read_file(path);
    const unsigned char sig[8] = {137, 80, 78, 71, 13, 10, 26, 10};
    if (png.size() < 8 || std::memcmp(png.data(), sig, 8) != 0) {
        CHECK(false, "%ux%u: no PNG signature", w, h);
        return;
    }
    std::vector<std::string> types;
    std::vector<unsigned char> z;
    std::size_t at = 8;
    while (at + 12 <= png.size()) {
        std::uint32_t len = be32(&png[at]);
        if (at + 12 + len > png.size()) break;
        std::string type(reinterpret_cast<const char*>(&png[at + 4]), 4);
        std::uint32_t crc = be32(&png[at + 8 + len]);
        CHECK(crc == cvl_crc32(0, &png[at + 4], len + 4), "%ux%u: %s's CRC is wrong", w, h, type.c_str());
        if (type == "IHDR") {
            CHECK(len == 13 && be32(&png[at + 8]) == w && be32(&png[at + 12]) == h && png[at + 16] == 8 &&
                      png[at + 17] == 6 && png[at + 18] == 0 && png[at + 19] == 0 && png[at + 20] == 0,
                  "%ux%u: IHDR", w, h);
        }
        if (type == "IDAT") z.insert(z.end(), png.begin() + at + 8, png.begin() + at + 8 + len);
        types.push_back(type);
        at += 12 + len;
    }
    CHECK(at == png.size(), "%ux%u: %zu bytes left after the chunks", w, h, png.size() - at);
    CHECK(types.size() == 3 && types[0] == "IHDR" && types[1] == "IDAT" && types[2] == "IEND", "%ux%u: %zu chunks", w,
          h, types.size());
    if (z.size() < 6) {
        CHECK(false, "%ux%u: IDAT is %zu bytes", w, h, z.size());
        return;
    }
    // zlib: deflate, a 32K window, FCHECK making the pair a multiple of 31, no dictionary.
    CHECK(z[0] == 0x78 && (z[0] * 256u + z[1]) % 31u == 0 && (z[1] & 0x20) == 0, "%ux%u: zlib header %02x %02x", w,
          h, z[0], z[1]);
    std::vector<unsigned char> inflated;
    std::size_t p = 2, found = 0;
    bool last = false;
    while (!last && p + 5 <= z.size() - 4) {
        unsigned char head = z[p];
        last = (head & 1) != 0;
        CHECK((head >> 1) == 0, "%ux%u: block %zu is not stored (%02x)", w, h, found, head);
        unsigned len = z[p + 1] | (z[p + 2] << 8);
        unsigned nlen = z[p + 3] | (z[p + 4] << 8);
        CHECK(len == (~nlen & 0xFFFFu), "%ux%u: block %zu LEN %u NLEN %u", w, h, found, len, nlen);
        p += 5;
        if (p + len > z.size() - 4) break;
        inflated.insert(inflated.end(), z.begin() + p, z.begin() + p + len);
        p += len;
        ++found;
        CHECK(last == (found == blocks), "%ux%u: BFINAL on block %zu of %zu", w, h, found, blocks);
    }
    CHECK(last && found == blocks && p == z.size() - 4, "%ux%u: %zu blocks (want %zu), ended at %zu of %zu", w, h,
          found, blocks, p, z.size() - 4);
    std::vector<unsigned char> filtered;
    for (std::uint32_t y = 0; y < h; ++y) {
        filtered.push_back(0);
        filtered.insert(filtered.end(), rgba.begin() + std::size_t(y) * w * 4, rgba.begin() + std::size_t(y + 1) * w * 4);
    }
    CHECK(inflated == filtered, "%ux%u: the stored bytes are not the filtered image", w, h);
    std::uint32_t a = 1, b = 0;
    for (unsigned char c : filtered) {
        a = (a + c) % 65521u;
        b = (b + a) % 65521u;
    }
    CHECK(be32(&z[z.size() - 4]) == ((b << 16) | a), "%ux%u: Adler-32", w, h);
}

static void test_png(const char* empty) {
    // The CRC the chunks are checked with is CRC-32 itself: the standard check value.
    const unsigned char digits[] = {'1', '2', '3', '4', '5', '6', '7', '8', '9'};
    CHECK(cvl_crc32(0, digits, sizeof digits) == 0xCBF43926u, "crc32(\"123456789\") is %08x",
          static_cast<unsigned>(cvl_crc32(0, digits, sizeof digits)));
    check_png(empty, 64, 510, 2);   // (64*4+1)*510 = 131070: exactly two full blocks
    check_png(empty, 100, 700, 5);  // 280700: four full blocks and a short one
    check_png(empty, 3, 2, 1);
    // An image no single IDAT can hold is refused before any allocation.
    std::vector<char> err(CVL_ERROR, 0);
    std::uint8_t pixel[4] = {0, 0, 0, 0};
    CHECK(!cvl_write_png("never.png", pixel, 0x40000000u, 0x40000000u, err.data(), err.size()), "a 2^60 image written");
    CHECK(std::string(err.data()) == "never.png: a 1073741824x1073741824 image is too large for a PNG of one IDAT chunk",
          "%s", err.data());
    // A row that fits, rows that do not.
    CHECK(!cvl_write_png("never.png", pixel, 0x1FFFFFFFu, 0xFFFFFFFFu, err.data(), err.size()), "a 2^63 image written");
    CHECK(std::string(err.data()) == "never.png: a 536870911x4294967295 image is too large for a PNG of one IDAT chunk",
          "%s", err.data());
}

// cvl_snap, Python's View.snap, as cvl_pick: a never-drawn view drawn first, the request, then
// draws until the answer lands -- every field of the 88-byte answer through; the library's own
// refusal at once; "snap: the answer never landed (...)" after 200 draws.
static void test_snap() {
    std::vector<char> err(CVL_ERROR, 0);
    CvlTable t = fake_table("cadaclysm-view 0.9.0");
    CadaclysmViewSnap out;

    fake::reset();
    fake::snap_waits = 2;
    int drawn = 0;
    CHECK(cvl_snap(&t, fake::view(), &drawn, 1, 10, 20, &out, err.data(), err.size()), "%s", err.data());
    CHECK(drawn == 1, "drawn not set");
    CHECK(out.size == 88 && out.kind == CADACLYSM_VIEW_SNAP_VERTEX && out.point[0] == -1.0 && out.point[1] == 1.0 &&
              out.point[2] == 0.0 && out.item == 7 && out.node == 3 && out.face == 11 && out.edge == 2 &&
              out.tangent[1] == 1.0f && out.radius == 0.5 && out.distance_px == 2.5f && out.clicks == 1,
          "the snap: size %u kind %u item %u edge %u clicks %u", out.size, out.kind, out.item, out.edge, out.clicks);
    CHECK(fake::log == "draw;request_snap_in 1 10 20;draw;snap_result;draw;snap_result;draw;snap_result;", "%s",
          fake::log.c_str());

    // Drawn already: asked at once.
    fake::reset();
    CHECK(cvl_snap(&t, fake::view(), &drawn, 0, 1, 2, &out, err.data(), err.size()), "%s", err.data());
    CHECK(fake::log == "request_snap_in 0 1 2;draw;snap_result;", "%s", fake::log.c_str());

    // A refused request: its message, at once.
    fake::reset();
    fake::refuse = "request_snap_in";
    fake::refusal = "cadaclysm_view_request_snap_in: snapping needs the wgpu view library";
    CHECK(!cvl_snap(&t, fake::view(), &drawn, 4, 1, 2, &out, err.data(), err.size()), "a refused request snapped");
    CHECK(std::string(err.data()) == fake::refusal, "%s", err.data());
    CHECK(fake::log == "request_snap_in 4 1 2;", "%s", fake::log.c_str());

    // A failure other than "no snap result": its message, no more waiting.
    fake::reset();
    fake::snap_waits = 1;
    fake::snap_refusal = "cadaclysm_view_snap_result: the device was lost";
    CHECK(!cvl_snap(&t, fake::view(), &drawn, 0, 1, 2, &out, err.data(), err.size()), "a failed snap snapped");
    CHECK(std::string(err.data()) == fake::snap_refusal, "%s", err.data());
    CHECK(fake::log == "request_snap_in 0 1 2;draw;snap_result;draw;snap_result;", "%s", fake::log.c_str());

    // Never landing: 200 draws, then Python's message with the last wait.
    fake::reset();
    fake::snap_waits = 1000;
    drawn = 1;
    CHECK(!cvl_snap(&t, fake::view(), &drawn, 0, 1, 2, &out, err.data(), err.size()), "an endless wait snapped");
    CHECK(std::string(err.data()) == "snap: the answer never landed (cadaclysm_view_snap_result: no snap result)", "%s",
          err.data());
    CHECK(fake::snap_waits == 800, "%d waits answered, not 200", 1000 - fake::snap_waits);
}

// ---- the ABI the table needs: 1.25 (parse_colour 1.5; load_font, show_text, set_text 1.6; set_double_click_frames,
// focus, navigation 1.8; set_lighting, lighting 1.9; the viewport cameras 1.10; show_points 1.11; set_occluded 1.13;
// set_finish 1.18; set_occluded_style, occluded_style 1.20; show_solid_faces 1.21; the six snap calls 1.22;
// set_line_colour, line_colour, set_item_line_colour 1.23; show_overlay, show_overlay_image, move_overlay 1.24; stats 1.25) ---

static void test_abi() {
    std::vector<char> err(CVL_ERROR, 0);
    CHECK(cvl_check_abi(0x10019u, "lib", err.data(), err.size()), "1.25 refused: %s", err.data());
    CHECK(cvl_check_abi(0x1001Au, "lib", err.data(), err.size()), "1.26 refused: %s", err.data());
    CHECK(!cvl_check_abi(0x10018u, "lib", err.data(), err.size()), "1.24 accepted");
    CHECK(std::string(err.data()) == "lib: view ABI 1.24, this SDK needs 1.25 or a later 1.x", "%s", err.data());
    CHECK(!cvl_check_abi(0x20019u, "lib", err.data(), err.size()), "2.25 accepted");
    CHECK(std::string(err.data()) == "lib: view ABI 2.25, this SDK needs 1.25 or a later 1.x", "%s", err.data());
}

// ---- a real (stand-in) library through cvl_open --------------------------------------------

static void test_fake_library(const char* path) {
    std::vector<char> err(CVL_ERROR, 0);
    static CvlTable t;
    // A library whose name() is NULL: opened, its label empty.
    CHECK(cvl_open(&t, path, err.data(), err.size()), "%s", err.data());
    CHECK(t.label[0] == 0 && !cvl_is_terminal(&t) && !cvl_is_wgpu(&t), "label '%s'", t.label);
    CHECK(t.show_solid != nullptr && t.parse_colour != nullptr && t.set_text != nullptr && t.standard_in != nullptr &&
          t.abi_version() == 0x10019u,
          "the table is not bound");
    CHECK(t.set_double_click_frames != nullptr && t.focus != nullptr && t.navigation != nullptr,
          "1.8's calls are not bound");
    CHECK(t.show_machining != nullptr && t.machining_seek != nullptr && t.machining_colour_by != nullptr &&
              t.machining_overlays != nullptr && t.machining_info != nullptr && t.machining_heights != nullptr &&
              t.timeline_play != nullptr && t.timeline_pause != nullptr && t.timeline_seek != nullptr &&
              t.timeline_set_loop != nullptr && t.timeline_time != nullptr && t.timeline_duration != nullptr &&
              t.timeline_playing != nullptr && t.timeline_status != nullptr,
          "1.7's calls are not bound");
    CHECK(t.set_lighting != nullptr && t.lighting != nullptr, "1.9's calls are not bound");
    CHECK(t.show_points != nullptr, "1.11's show_points is not bound");
    CHECK(t.set_occluded != nullptr, "1.13's set_occluded is not bound");
    CHECK(t.set_item_layer != nullptr && t.set_user_layer != nullptr, "1.16's user layers are not bound");
    CHECK(t.set_finish != nullptr, "1.18's set_finish is not bound");
    CHECK(t.set_occluded_style != nullptr && t.occluded_style != nullptr, "1.20's occluded style is not bound");
    CHECK(t.show_solid_faces != nullptr, "1.21's show_solid_faces is not bound");
    CHECK(t.set_snap != nullptr && t.request_snap_in != nullptr && t.snap_result != nullptr && t.clear_snap != nullptr &&
              t.set_work_plane != nullptr && t.clear_work_plane != nullptr,
          "1.22's snapping is not bound");
    CHECK(t.set_line_colour != nullptr && t.line_colour != nullptr && t.set_item_line_colour != nullptr,
          "1.23's line colours are not bound");
    CHECK(t.show_overlay != nullptr && t.show_overlay_image != nullptr && t.move_overlay != nullptr,
          "1.24's overlays are not bound");
    CHECK(t.stats != nullptr, "1.25's stats is not bound");
    // A library older than the table (1.24: no stats) is refused before any call is
    // bound, in Python's words.
    static CvlTable old;
    cvl_setenv("CVL_FAKE_ABI_MINOR", "24");
    int opened = cvl_open(&old, path, err.data(), err.size());
    cvl_setenv("CVL_FAKE_ABI_MINOR", nullptr);
    CHECK(!opened, "a view library of ABI 1.24 was opened");
    CHECK(std::string(err.data()) == std::string(path) + ": view ABI 1.24, this SDK needs 1.25 or a later 1.x", "%s",
          err.data());
    CHECK(old.library == nullptr && old.show_solid == nullptr, "a refused library filled the table");
    CHECK(std::strcmp(cvl_error(&t), "the view library failed") == 0, "NULL last_error: %s", cvl_error(&t));
    // A relative path with a directory part (Windows: made absolute before
    // LOAD_WITH_ALTERED_SEARCH_PATH).
    std::filesystem::path full(path);
    std::error_code ec;
    std::filesystem::path before = std::filesystem::current_path(ec);
    std::filesystem::current_path(full.parent_path(), ec);
    std::string relative = "./" + full.filename().string();
    static CvlTable r;
    CHECK(!ec && cvl_open(&r, relative.c_str(), err.data(), err.size()), "%s: %s", relative.c_str(), err.data());
    std::filesystem::current_path(before, ec);
}

int main(int argc, char** argv) {
    // argv[1]: an existing directory with no view library in it (CMake passes the build dir).
    const char* empty = argc > 1 ? argv[1] : ".";
    const char* dirs[] = {empty};
    char out[CVL_PATH] = {0};
    std::vector<char> err(CVL_ERROR, 0);

    // A library found nowhere: the contract's "no view library" message, naming where it looked.
    int found = cvl_find("cadaclysm_view_absent", "CADACLYSM_VIEW_ABSENT_LIBRARY", "terminal", dirs, 1, out,
                         sizeof out, err.data(), err.size());
    std::string message(err.data());
    CHECK(!found, "found %s", out);
    CHECK(starts(message, "no view library: the terminal library was not found (searched: "), "%s", message.c_str());
    CHECK(message.find(empty) != std::string::npos, "%s does not name %s", message.c_str(), empty);
    CHECK(message.find(" on the loader's path) -- ") != std::string::npos, "%s", message.c_str());
    CHECK(ends(message, "-- reinstall cadaclysm, set CADACLYSM_VIEW_ABSENT_LIBRARY to the library, or set CADACLYSM_VIEW"),
          "%s", message.c_str());

    // The wgpu wording names the file and the way back to the terminal.
    char file[256];
    cvl_file_name("cadaclysm_view_absent", file, sizeof file);
    found = cvl_find("cadaclysm_view_absent", "CADACLYSM_VIEW_ABSENT_LIBRARY", "wgpu", dirs, 1, out, sizeof out,
                     err.data(), err.size());
    message = err.data();
    CHECK(!found && starts(message, (std::string("no view library: ") + file + " was not found (searched: ").c_str()),
          "%s", message.c_str());
    CHECK(ends(message, "-- reinstall cadaclysm, set CADACLYSM_VIEW_ABSENT_LIBRARY to it, or use the terminal"), "%s",
          message.c_str());

    // A path that is no library: refused with the loader's reason, not "no view library".
    std::string bogus = std::string(empty) + "/view_loader_not_a_library.txt";
    std::FILE* f = std::fopen(bogus.c_str(), "wb");
    CHECK(f != nullptr, "could not write %s", bogus.c_str());
    if (f) {
        std::fputs("not a library", f);
        std::fclose(f);
    }
    CvlTable table;
    std::memset(&table, 0, sizeof table);
    CHECK(!cvl_open(&table, bogus.c_str(), err.data(), err.size()), "opened a text file");
    CHECK(starts(err.data(), (bogus + ": could not load the view library: ").c_str()), "%s", err.data());

    // CadaclysmViewLod as the library reads it: three u32, 12 bytes (set_lod refuses a
    // smaller `size`). Compile-time: a constant CHECK is C4127 under MSVC /W4 /WX.
    static_assert(sizeof(CadaclysmViewLod) == 12, "CadaclysmViewLod is not 12 bytes");
    static_assert(offsetof(CadaclysmViewLod, min_triangles) == 4 && offsetof(CadaclysmViewLod, motion) == 8,
                  "CadaclysmViewLod's fields moved");
    static_assert(CADACLYSM_VIEW_LOD_DETAILED == 0 && CADACLYSM_VIEW_LOD_SMOOTH == 1, "the motion values moved");
    // CadaclysmViewOccludedStyle as 1.20 reads it: size, dash, gap, dim, has_colour, colour[3], 32 bytes.
    static_assert(sizeof(CadaclysmViewOccludedStyle) == 32, "CadaclysmViewOccludedStyle is not 32 bytes");
    static_assert(offsetof(CadaclysmViewOccludedStyle, dim) == 12 && offsetof(CadaclysmViewOccludedStyle, has_colour) == 16 &&
                      offsetof(CadaclysmViewOccludedStyle, colour) == 20,
                  "CadaclysmViewOccludedStyle's fields moved");
    // The snap structs as 1.22 reads and writes them: 16 and 88 bytes, no padding.
    static_assert(sizeof(CadaclysmViewSnapSettings) == 16 && offsetof(CadaclysmViewSnapSettings, aperture_px) == 8 &&
                      offsetof(CadaclysmViewSnapSettings, marker) == 12,
                  "CadaclysmViewSnapSettings's fields moved");
    static_assert(sizeof(CadaclysmViewSnap) == 88, "CadaclysmViewSnap is not 88 bytes");
    static_assert(offsetof(CadaclysmViewSnap, point) == 8 && offsetof(CadaclysmViewSnap, item) == 32 &&
                      offsetof(CadaclysmViewSnap, edge) == 44 && offsetof(CadaclysmViewSnap, tangent) == 48 &&
                      offsetof(CadaclysmViewSnap, axis) == 60 && offsetof(CadaclysmViewSnap, radius) == 72 &&
                      offsetof(CadaclysmViewSnap, distance_px) == 80 && offsetof(CadaclysmViewSnap, clicks) == 84,
                  "CadaclysmViewSnap's fields moved");
    static_assert(CADACLYSM_VIEW_SNAP_VERTEX == 1 && CADACLYSM_VIEW_SNAP_FACE == 32 && CADACLYSM_VIEW_SNAP_PLANE == 128 &&
                      CADACLYSM_VIEW_SNAP_ALL == 255,
                  "the snap kinds moved");

    // The standard views, Python's VIEWS table.
    double az = 0, el = 0;
    CHECK(cvl_standard_angles("iso", &az, &el) && az == -50.0 && el == 28.0, "iso %f %f", az, el);
    CHECK(cvl_standard_angles("top", &az, &el) && az == -90.0 && el == 90.0, "top %f %f", az, el);
    CHECK(!cvl_standard_angles("sideways", &az, &el), "sideways accepted");

    // The camera's angles: an eye on -Y looks from the front (az -90, el 0); an eye straight
    // above reads its azimuth off the up vector (Python's pole rule).
    CadaclysmViewCamera cam;
    std::memset(&cam, 0, sizeof cam);
    cam.size = sizeof cam;
    cam.eye[1] = -10.0f;
    cam.up[2] = 1.0f;
    cvl_angles(&cam, 0, &az, &el);
    CHECK(std::fabs(az + 90.0) < 1e-9 && std::fabs(el) < 1e-9, "front %f %f", az, el);
    std::memset(&cam, 0, sizeof cam);
    cam.eye[2] = 10.0f;
    cam.up[1] = 1.0f;
    cvl_angles(&cam, 0, &az, &el);
    CHECK(std::fabs(az + 90.0) < 1e-9 && std::fabs(el - 90.0) < 1e-9, "top %f %f", az, el);
    // Y up (cadaclysm_view::camera::to_orbit): the eye on +Y is straight above, the eye on +Z
    // is the front (az -90).
    std::memset(&cam, 0, sizeof cam);
    cam.eye[1] = 10.0f;
    cam.up[2] = -1.0f;
    cvl_angles(&cam, 1, &az, &el);
    CHECK(std::fabs(az + 90.0) < 1e-9 && std::fabs(el - 90.0) < 1e-9, "y-up top %f %f", az, el);
    std::memset(&cam, 0, sizeof cam);
    cam.eye[2] = 10.0f;
    cam.up[1] = 1.0f;
    cvl_angles(&cam, 1, &az, &el);
    CHECK(std::fabs(az + 90.0) < 1e-9 && std::fabs(el) < 1e-9, "y-up front %f %f", az, el);

    // The PNG writer: signature, IHDR's size and type, and the IEND trailer.
    std::vector<std::uint8_t> rgba(3 * 2 * 4, 200);
    std::string png = std::string(empty) + "/view_loader_test.png";
    CHECK(cvl_write_png(png.c_str(), rgba.data(), 3, 2, err.data(), err.size()), "%s", err.data());
    std::FILE* p = std::fopen(png.c_str(), "rb");
    std::vector<unsigned char> bytes;
    if (p) {
        int c;
        while ((c = std::fgetc(p)) != EOF) bytes.push_back(static_cast<unsigned char>(c));
        std::fclose(p);
    }
    const unsigned char sig[8] = {137, 80, 78, 71, 13, 10, 26, 10};
    CHECK(bytes.size() > 45 && std::memcmp(bytes.data(), sig, 8) == 0, "no PNG signature (%zu bytes)", bytes.size());
    if (bytes.size() > 45) {
        CHECK(std::memcmp(bytes.data() + 12, "IHDR", 4) == 0, "no IHDR");
        CHECK(bytes[19] == 3 && bytes[23] == 2 && bytes[24] == 8 && bytes[25] == 6, "IHDR says the wrong size or type");
        CHECK(std::memcmp(bytes.data() + bytes.size() - 8, "IEND", 4) == 0, "no IEND");
    }

    test_draw_object(empty);
    test_pick();
    test_snap();
    test_search(empty);
    test_png(empty);
    test_abi();
    // argv[2]: the stand-in library (CMake passes cadaclysm_view_loader_fake).
    CHECK(argc > 2, "no stand-in library given");
    if (argc > 2) test_fake_library(argv[2]);

    if (failures) return 1;
    std::printf("view_loader: ok\n");
    return 0;
}
