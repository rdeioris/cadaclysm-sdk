// Package viewrig is the view package's test rig: C stand-ins for a view library's calls,
// whose answers a test sets and whose arguments it reads back. Only view's tests import
// it -- cgo is not allowed in a _test.go file -- so no program links it.
//
// Not thread-safe: one test at a time.
package viewrig

/*
#cgo CFLAGS: -I${SRCDIR}/../../../../include -I${SRCDIR}/../../../../../../cadaclysm-view-capi/include
#include <math.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <cadaclysm_view.h>

static char rig_said[1024];
static int rig_view; // the stand-in view's address
static uint32_t rig_answers[16], rig_waits[16], rig_bits;
static int rig_answer_count, rig_pumped, rig_calls, rig_null;
static uint32_t rig_count;

static void rig_saw(const void *p, uint32_t n) {
    rig_null = p == NULL;
    rig_count = n;
    ++rig_calls;
}

static const char *rig_last_error(void) { return rig_said; }
static CadaclysmView *rig_create(const CadaclysmViewWindow *w, const CadaclysmViewOptions *o) {
    (void)w;
    (void)o;
    return (CadaclysmView *)&rig_view;
}
static CadaclysmView *rig_create_fails(const CadaclysmViewWindow *w, const CadaclysmViewOptions *o) {
    (void)w;
    (void)o;
    return NULL;
}
static void rig_destroy(CadaclysmView *v) { (void)v; }
static uint32_t rig_pump(CadaclysmView *v, uint32_t ms) {
    (void)v;
    if (rig_pumped < 16) rig_waits[rig_pumped] = ms;
    return rig_pumped < rig_answer_count ? rig_answers[rig_pumped++] : (++rig_pumped, CADACLYSM_VIEW_OPEN);
}
static uint32_t rig_input(CadaclysmView *v, const CadaclysmViewEvent *e) {
    (void)v;
    (void)e;
    return rig_bits;
}
static bool rig_needs_draw(const CadaclysmView *v) {
    (void)v;
    return true;
}
static void rig_orbit(CadaclysmView *v, float dx, float dy) {
    (void)v;
    (void)dx;
    (void)dy;
}
static bool rig_frame(CadaclysmView *v, uint32_t item) {
    (void)v;
    (void)item;
    return false;
}
// The pick answer pick_result and run hand back (item 0 after a reset: nothing picked).
static CadaclysmViewPick rig_pick;
// What set_double_click_frames, focus and navigation were called with, in order.
static char rig_log[1024];
static uint32_t rig_navigation;

static void rig_note(const char *text) {
    size_t used = strlen(rig_log), n = strlen(text);
    if (used + n + 3 >= sizeof rig_log) return;
    if (used) {
        memcpy(rig_log + used, "; ", 2);
        used += 2;
    }
    memcpy(rig_log + used, text, n + 1);
}
// The rig's pick in `p`, up to `p->size` as the library writes it.
static int rig_old_pick; // a library that writes the pick only up to 1.27's fields
static uint32_t rig_pick_segment_seen; // 1.30: the segment the caller's buffer arrived with
static void rig_fill(CadaclysmViewPick *p) {
    uint32_t size = p->size;
    if (size >= sizeof *p) rig_pick_segment_seen = p->segment;
    CadaclysmViewPick answer = rig_pick;
    size_t n = size < sizeof answer ? size : sizeof answer;
    answer.size = size;
    if (rig_old_pick && n > offsetof(CadaclysmViewPick, viewport_label)) n = offsetof(CadaclysmViewPick, viewport_label);
    memcpy(p, &answer, n);
}
// A window the user closed with the camera straight down the +y axis, the rig's pick.
static bool rig_run(CadaclysmView *v, CadaclysmViewCamera *c, CadaclysmViewPick *p) {
    (void)v;
    c->eye[0] = 0.0f;
    c->eye[1] = 10.0f;
    c->eye[2] = 0.0f;
    c->target[0] = c->target[1] = c->target[2] = 0.0f;
    c->up[0] = 0.0f;
    c->up[1] = 0.0f;
    c->up[2] = -1.0f;
    c->orthographic = 0;
    rig_fill(p);
    return true;
}
static bool rig_draw(CadaclysmView *v) {
    (void)v;
    return true;
}
static void rig_request_pick_in(CadaclysmView *v, uint32_t viewport, uint32_t x, uint32_t y) {
    (void)v;
    (void)viewport;
    (void)x;
    (void)y;
}
static bool rig_pick_result(CadaclysmView *v, CadaclysmViewPick *p) {
    (void)v;
    rig_fill(p);
    return true;
}
static void rig_set_double_click_frames(CadaclysmView *v, bool on) {
    (void)v;
    rig_note(on ? "double click frames on" : "double click frames off");
}
// A point that is not finite is refused, as the library does.
static bool rig_focus(CadaclysmView *v, const float *p) {
    char text[128];
    (void)v;
    snprintf(text, sizeof text, "focus %g %g %g", p[0], p[1], p[2]);
    rig_note(text);
    if (!isfinite(p[0]) || !isfinite(p[1]) || !isfinite(p[2])) {
        strcpy(rig_said, "cadaclysm_view_focus: the point is not finite");
        return false;
    }
    return true;
}
static uint32_t rig_navigation_of(CadaclysmView *v) {
    (void)v;
    rig_note("navigation");
    return rig_navigation;
}
// 1.22's snapping: what set_snap was handed and how often; the answer snap_result hands back
// while rig_snap_landed (else false, rig_said saying why); request_snap_in, clear_snap and the
// work plane calls go to rig_log.
static CadaclysmViewSnapSettings rig_snap_settings;
static int rig_snap_sets;
static CadaclysmViewSnap rig_snap;
static int rig_snap_landed = 1;
static bool rig_set_snap(CadaclysmView *v, const CadaclysmViewSnapSettings *s) {
    (void)v;
    rig_snap_settings = *s;
    ++rig_snap_sets;
    return true;
}
static void rig_request_snap_in(CadaclysmView *v, uint32_t viewport, uint32_t x, uint32_t y) {
    char text[64];
    (void)v;
    snprintf(text, sizeof text, "snap %u %u %u", (unsigned)viewport, (unsigned)x, (unsigned)y);
    rig_note(text);
}
// rig_snap, up to `s->size` as the library writes it.
static bool rig_snap_result(CadaclysmView *v, CadaclysmViewSnap *s) {
    CadaclysmViewSnap answer = rig_snap;
    uint32_t size = s->size;
    (void)v;
    if (!rig_snap_landed) return false;
    answer.size = size;
    memcpy(s, &answer, size < sizeof answer ? size : sizeof answer);
    return true;
}
static void rig_clear_snap(CadaclysmView *v) {
    (void)v;
    rig_note("clear snap");
}
static bool rig_set_work_plane(CadaclysmView *v, const double *o, const double *x, const double *n, double step) {
    char text[256];
    (void)v;
    snprintf(text, sizeof text, "work plane %g %g %g, %g %g %g, %g %g %g, %g", o[0], o[1], o[2], x[0], x[1], x[2], n[0],
             n[1], n[2], step);
    rig_note(text);
    return true;
}
static bool rig_clear_work_plane(CadaclysmView *v) {
    (void)v;
    rig_note("ground plane");
    return true;
}
static const CadaclysmViewSnapSettings *rig_seen_snap_settings(void) { return &rig_snap_settings; }
static int rig_snap_set_calls(void) { return rig_snap_sets; }
static void rig_set_snap_answer(const CadaclysmViewSnap *s) { rig_snap = *s; }
static void rig_set_snap_landed(int on) { rig_snap_landed = on; }
static bool rig_remove(CadaclysmView *v, uint32_t item) {
    (void)v;
    (void)item;
    return true;
}
static uint32_t rig_show_lines(CadaclysmView *v, const float *s, uint32_t n, const float *rgb) {
    (void)v;
    (void)rgb;
    rig_saw(s, n);
    return 7;
}
// What the last show_points was handed: up to 12 of its floats, its count, its rgb (or NULL)
// and its size.
static float rig_points[12], rig_points_rgb[3], rig_points_size;
static uint32_t rig_points_count;
static int rig_points_rgb_null, rig_points_calls;
static uint32_t rig_show_points(CadaclysmView *v, const float *p, uint32_t n, const float *rgb, float size_px) {
    uint32_t i;
    (void)v;
    memset(rig_points, 0, sizeof rig_points);
    for (i = 0; i < 3 * n && i < 12; ++i) rig_points[i] = p[i];
    rig_points_count = n;
    rig_points_rgb_null = rgb == NULL;
    for (i = 0; i < 3; ++i) rig_points_rgb[i] = rgb ? rgb[i] : 0.0f;
    rig_points_size = size_px;
    ++rig_points_calls;
    return 17;
}
static float rig_point(int i) { return rig_points[i]; }
static float rig_point_rgb(int i) { return rig_points_rgb[i]; }
static float rig_point_size(void) { return rig_points_size; }
static uint32_t rig_point_count(void) { return rig_points_count; }
static int rig_point_rgb_null(void) { return rig_points_rgb_null; }
static int rig_point_calls(void) { return rig_points_calls; }
static uint32_t rig_show_mesh(CadaclysmView *v, const CadaclysmViewMesh *m) {
    (void)v;
    rig_null = m->positions == NULL || m->indices == NULL;
    rig_count = m->vertex_count;
    ++rig_calls;
    return 7;
}
static uint32_t rig_show_image(CadaclysmView *v, const CadaclysmViewImage *i) {
    (void)v;
    rig_saw(i->rgba, i->width * i->height);
    return 7;
}
static bool rig_set_face_colours(CadaclysmView *v, uint32_t item, const uint32_t *f, const float *c, uint32_t n) {
    (void)v;
    (void)item;
    rig_saw(f && c ? (const void *)f : NULL, n);
    return true;
}
static bool rig_set_node_transforms(CadaclysmView *v, uint32_t item, const double *m, uint32_t n) {
    (void)v;
    (void)item;
    rig_saw(m, n);
    return true;
}
static bool rig_set_viewports(CadaclysmView *v, const CadaclysmViewViewport *p, uint32_t n) {
    (void)v;
    rig_saw(p, n);
    return true;
}

// ---- view ABI 1.7: the machining and timeline calls ----
// What the last show_machining was handed, copied (the library keeps nothing of the caller's
// memory): the struct's and the first program's size, up to four programs, the stock, the
// part's counts and first twelve numbers, and the options.
typedef struct {
    uint32_t number, shape, size;
    double diameter, flute, angle, corner;
    char gcode[256];
} RigProgram;
typedef struct {
    int calls;
    uint32_t size, program_count, program_size, part_vertices, part_indices, skin_set;
    int part_null;
    RigProgram programs[4];
    double stock_min[3], stock_max[3], cell, tolerance, skin, rapid_rate;
    float part_positions[12];
    uint32_t part_triangles[12];
} RigMachining;
static RigMachining rig_machining_seen;
static const RigMachining *rig_seen_machining(void) { return &rig_machining_seen; }
// What the transport answers, and whether the machining calls refuse (with `rig_said`).
static CadaclysmViewMachiningInfo rig_info_answer;
static double rig_time_answer, rig_duration_answer;
static bool rig_playing_answer, rig_calls_ok = true;
static char rig_status_lines[8][128];
static int rig_status_count, rig_status_calls;
static uint32_t rig_info_size_seen, rig_heights_capacity;

static uint32_t rig_show_machining(CadaclysmView *v, const CadaclysmViewMachining *m) {
    uint32_t i, k;
    (void)v;
    memset(&rig_machining_seen, 0, sizeof rig_machining_seen);
    rig_machining_seen.calls = ++rig_calls;
    rig_machining_seen.size = m->size;
    rig_machining_seen.program_count = m->program_count;
    rig_machining_seen.program_size = m->program_count ? m->programs[0].size : 0;
    for (i = 0; i < m->program_count && i < 4; ++i) {
        const CadaclysmViewProgram *p = &m->programs[i];
        RigProgram *r = &rig_machining_seen.programs[i];
        r->number = p->tool_number;
        r->shape = p->tool_shape;
        r->size = p->size;
        r->diameter = p->tool_diameter;
        r->flute = p->tool_flute_length;
        r->angle = p->tool_angle;
        r->corner = p->tool_corner_radius;
        strncpy(r->gcode, p->gcode, sizeof r->gcode - 1);
    }
    for (k = 0; k < 3; ++k) {
        rig_machining_seen.stock_min[k] = m->stock_min[k];
        rig_machining_seen.stock_max[k] = m->stock_max[k];
    }
    rig_machining_seen.part_null = m->part_positions == NULL || m->part_indices == NULL;
    rig_machining_seen.part_vertices = m->part_vertex_count;
    rig_machining_seen.part_indices = m->part_index_count;
    for (i = 0; i < 3 * m->part_vertex_count && i < 12 && m->part_positions; ++i)
        rig_machining_seen.part_positions[i] = m->part_positions[i];
    for (i = 0; i < m->part_index_count && i < 12 && m->part_indices; ++i)
        rig_machining_seen.part_triangles[i] = m->part_indices[i];
    rig_machining_seen.cell = m->cell;
    rig_machining_seen.tolerance = m->tolerance;
    rig_machining_seen.skin = m->skin;
    rig_machining_seen.skin_set = m->skin_set;
    rig_machining_seen.rapid_rate = m->rapid_rate;
    return m->program_count == 0 ? 0 : 21; // at least one program, as the library
}
static bool rig_refusal(void) {
    if (!rig_calls_ok) strcpy(rig_said, "refused by the rig");
    return rig_calls_ok;
}
static bool rig_machining_seek(CadaclysmView *v, uint32_t item, uint32_t to) {
    char text[64];
    (void)v;
    snprintf(text, sizeof text, "seek %u %u", item, to);
    rig_note(text);
    return rig_refusal();
}
static bool rig_machining_colour_by(CadaclysmView *v, uint32_t item, uint32_t mode) {
    char text[64];
    (void)v;
    snprintf(text, sizeof text, "colour_by %u %u", item, mode);
    rig_note(text);
    return rig_refusal();
}
static bool rig_machining_overlays(CadaclysmView *v, uint32_t item, bool path, bool tool) {
    char text[64];
    (void)v;
    snprintf(text, sizeof text, "overlays %u %d %d", item, (int)path, (int)tool);
    rig_note(text);
    return rig_refusal();
}
static bool rig_machining_info(CadaclysmView *v, uint32_t item, CadaclysmViewMachiningInfo *out) {
    char text[64];
    (void)v;
    snprintf(text, sizeof text, "info %u", item);
    rig_note(text);
    rig_info_size_seen = out->size;
    *out = rig_info_answer;
    out->size = rig_info_size_seen;
    return rig_refusal();
}
// Heights are 0.5 * the cell's number, so an order mix-up shows.
static bool rig_machining_heights(CadaclysmView *v, uint32_t item, float *z, size_t n) {
    char text[64];
    size_t i;
    (void)v;
    snprintf(text, sizeof text, "heights %u %u", item, (unsigned)n);
    rig_note(text);
    rig_heights_capacity = (uint32_t)n;
    for (i = 0; i < n; ++i) z[i] = 0.5f * (float)i;
    return rig_refusal();
}
static bool rig_timeline_play(CadaclysmView *v, double speed) {
    char text[64];
    (void)v;
    snprintf(text, sizeof text, "play %g", speed);
    rig_note(text);
    return rig_refusal();
}
static bool rig_timeline_pause(CadaclysmView *v) {
    (void)v;
    rig_note("pause");
    return rig_refusal();
}
static bool rig_timeline_seek(CadaclysmView *v, double seconds) {
    char text[64];
    (void)v;
    snprintf(text, sizeof text, "timeline_seek %g", seconds);
    rig_note(text);
    return rig_refusal();
}
static bool rig_timeline_set_loop(CadaclysmView *v, bool on) {
    (void)v;
    rig_note(on ? "loop on" : "loop off");
    return rig_refusal();
}
static double rig_timeline_time(const CadaclysmView *v) {
    (void)v;
    return rig_time_answer;
}
static double rig_timeline_duration(const CadaclysmView *v) {
    (void)v;
    return rig_duration_answer;
}
static bool rig_timeline_playing(const CadaclysmView *v) {
    (void)v;
    return rig_playing_answer;
}
// The status line of this call: the nth answer set (the last again after them); a lone
// answer of "" is no tracks. As the library: the full length, the text cut to what fits.
static size_t rig_timeline_status(const CadaclysmView *v, char *s, size_t n) {
    const char *text;
    size_t length, copy;
    (void)v;
    if (rig_status_count == 0) return 0;
    text = rig_status_lines[rig_status_calls < rig_status_count ? rig_status_calls : rig_status_count - 1];
    ++rig_status_calls;
    length = strlen(text);
    if (s != NULL && n > 0) {
        copy = length < n - 1 ? length : n - 1;
        memcpy(s, text, copy);
        s[copy] = 0;
    }
    return length;
}
static void rig_machining_reset(void) {
    memset(&rig_machining_seen, 0, sizeof rig_machining_seen);
    memset(&rig_info_answer, 0, sizeof rig_info_answer);
    rig_time_answer = rig_duration_answer = 0.0;
    rig_playing_answer = false;
    rig_calls_ok = true;
    rig_status_count = rig_status_calls = 0;
    rig_info_size_seen = rig_heights_capacity = 0;
}
static void rig_set_info(uint32_t moves, uint32_t move, uint32_t nx, uint32_t ny, float cell, float x, float y, double cycle) {
    rig_info_answer.moves = moves;
    rig_info_answer.move = move;
    rig_info_answer.nx = nx;
    rig_info_answer.ny = ny;
    rig_info_answer.cell = cell;
    rig_info_answer.min[0] = x;
    rig_info_answer.min[1] = y;
    rig_info_answer.cycle_time = cycle;
}
static void rig_set_timeline(double time, double duration, int playing) {
    rig_time_answer = time;
    rig_duration_answer = duration;
    rig_playing_answer = playing != 0;
}
static void rig_set_calls_ok(int ok) { rig_calls_ok = ok != 0; }
static void rig_add_status(const char *text) {
    if (rig_status_count >= 8) return;
    strncpy(rig_status_lines[rig_status_count], text, 127);
    rig_status_lines[rig_status_count][127] = 0;
    ++rig_status_count;
}
static uint32_t rig_seen_info_size(void) { return rig_info_size_seen; }
static uint32_t rig_seen_heights_capacity(void) { return rig_heights_capacity; }
static int rig_status_calls_made(void) { return rig_status_calls; }

// 1.26's input events: next_event's queue, oldest first; close and a CLOSED pump queue a
// CLOSE event (the camera straight down -y, or `rig_closing`'s).
static CadaclysmViewInputEvent rig_events[32];
static int rig_event_count, rig_event_next, rig_closes, rig_event_calls;
static uint32_t rig_event_size;
static char rig_event_refusal[256];
static CadaclysmViewInputEvent rig_closing;
static int rig_closing_set, rig_pick_landed = 1;
static void rig_queue(const CadaclysmViewInputEvent *e) {
    if (rig_event_count < 32) rig_events[rig_event_count++] = *e;
}
static int32_t rig_event_label_seen; // 1.30: the none values the caller's buffer arrived with
static uint32_t rig_event_segment_seen;
static bool rig_next_event(CadaclysmView *v, CadaclysmViewInputEvent *out) {
    uint32_t size = out->size;
    (void)v;
    rig_event_label_seen = out->pick_viewport_label;
    rig_event_segment_seen = out->pick_segment;
    ++rig_event_calls;
    rig_event_size = size;
    if (rig_event_refusal[0]) {
        strcpy(rig_said, rig_event_refusal);
        return false;
    }
    if (rig_event_next >= rig_event_count) {
        strcpy(rig_said, "cadaclysm_view_next_event: no event");
        return false;
    }
    *out = rig_events[rig_event_next++];
    out->size = size;
    rig_said[0] = 0;
    return true;
}
static bool rig_close(CadaclysmView *v) {
    CadaclysmViewInputEvent e;
    (void)v;
    ++rig_closes;
    memset(&e, 0, sizeof e);
    e.kind = CADACLYSM_VIEW_INPUT_EVENT_CLOSE;
    e.camera.eye[1] = -5.0f;
    e.camera.up[2] = 1.0f;
    rig_queue(&e);
    return true;
}
static uint32_t rig_pump_events(CadaclysmView *v, uint32_t ms) {
    uint32_t answer = rig_pump(v, ms);
    if (answer == CADACLYSM_VIEW_CLOSED && rig_closing_set) {
        rig_queue(&rig_closing); // the window closed by itself: its close event with it
        rig_closing_set = 0;
    }
    if (answer == 0) strcpy(rig_said, "pump: refused");
    return answer;
}
static bool rig_pick_result_or_none(CadaclysmView *v, CadaclysmViewPick *p) {
    if (!rig_pick_landed) {
        strcpy(rig_said, "cadaclysm_view_pick_result: no pick result");
        return false;
    }
    return rig_pick_result(v, p);
}
static void rig_push_event(uint32_t kind, uint32_t modifiers, float x, float y, float wheel_y, uint32_t button,
                           uint32_t pointer, uint32_t pointer_id, uint32_t width, uint32_t height, uint32_t repeat,
                           uint32_t dropped, double time_ms, const char *key, uint32_t pick_item, uint32_t pick_clicks,
                           uint32_t snap_kind, uint32_t snap_edge, float ex, float ey, float ez, float ux, float uy,
                           float uz, int closing, int32_t pick_label) {
    CadaclysmViewInputEvent e;
    memset(&e, 0, sizeof e);
    e.pick_viewport_label = pick_label;
    e.pick_segment = 0xFFFFFFFFu; // 1.30: no wire, as the library writes it
    e.kind = kind;
    e.modifiers = modifiers;
    e.x = x;
    e.y = y;
    e.wheel_y = wheel_y;
    e.button = button;
    e.pointer = pointer;
    e.pointer_id = pointer_id;
    e.width = width;
    e.height = height;
    e.repeat = repeat;
    e.dropped = dropped;
    e.time_ms = time_ms;
    memcpy(e.key, key, strlen(key) < sizeof e.key ? strlen(key) : sizeof e.key);
    e.pick.item = pick_item;
    e.pick.clicks = pick_clicks;
    e.snap.kind = snap_kind;
    e.snap.edge = snap_edge;
    e.camera.eye[0] = ex;
    e.camera.eye[1] = ey;
    e.camera.eye[2] = ez;
    e.camera.up[0] = ux;
    e.camera.up[1] = uy;
    e.camera.up[2] = uz;
    if (closing) {
        rig_closing = e;
        rig_closing_set = 1;
    } else {
        rig_queue(&e);
    }
}
static void rig_refuse_events(const char *text) {
    strncpy(rig_event_refusal, text, sizeof rig_event_refusal - 1);
    rig_event_refusal[sizeof rig_event_refusal - 1] = 0;
}
static void rig_set_pick_landed(int on) { rig_pick_landed = on != 0; }
static int rig_closes_made(void) { return rig_closes; }
static int rig_event_calls_made(void) { return rig_event_calls; }
static uint32_t rig_event_size_seen(void) { return rig_event_size; }
static size_t rig_input_event_layout(int i) {
    static const size_t offsets[] = {
        offsetof(CadaclysmViewInputEvent, size),       offsetof(CadaclysmViewInputEvent, kind),
        offsetof(CadaclysmViewInputEvent, time_ms),    offsetof(CadaclysmViewInputEvent, x),
        offsetof(CadaclysmViewInputEvent, y),          offsetof(CadaclysmViewInputEvent, wheel_y),
        offsetof(CadaclysmViewInputEvent, button),     offsetof(CadaclysmViewInputEvent, modifiers),
        offsetof(CadaclysmViewInputEvent, pointer),    offsetof(CadaclysmViewInputEvent, pointer_id),
        offsetof(CadaclysmViewInputEvent, width),      offsetof(CadaclysmViewInputEvent, height),
        offsetof(CadaclysmViewInputEvent, repeat),     offsetof(CadaclysmViewInputEvent, dropped),
        offsetof(CadaclysmViewInputEvent, pad0),       offsetof(CadaclysmViewInputEvent, key),
        offsetof(CadaclysmViewInputEvent, pick),       offsetof(CadaclysmViewInputEvent, snap),
        offsetof(CadaclysmViewInputEvent, camera),     offsetof(CadaclysmViewInputEvent, pick_viewport_label),
        sizeof(CadaclysmViewInputEvent),
    };
    return offsets[i];
}

// 1.27's animations: what play_animation, timeline_remove, set_item_visible and
// set_node_ghosts were handed, and the track ids play_animation answers (1, 2, ...); a
// refusal text makes all four fail with it.
typedef struct {
    char target[32];
    uint32_t item, node;
} RigBinding;
static RigBinding rig_bindings[8];
static const void *rig_play_anim;
static uint32_t rig_play_count, rig_next_track = 1, rig_removed_track, rig_vis_item, rig_ghost_item, rig_ghost_count;
static uint32_t rig_ghost_nodes[8];
static int rig_play_anim_null, rig_play_array_null, rig_vis_on, rig_ghost_null, rig_anim_calls;
static char rig_anim_refusal[256];
static bool rig_anim_refuses(void) {
    ++rig_anim_calls;
    if (!rig_anim_refusal[0]) return false;
    strcpy(rig_said, rig_anim_refusal);
    return true;
}
static uint32_t rig_play_animation(CadaclysmView *v, const CadaclysmBlacksmithAnimation *a,
                                   const CadaclysmViewAnimationBinding *b, uint32_t n) {
    uint32_t k;
    (void)v;
    rig_play_anim = a;
    rig_play_anim_null = a == NULL;
    rig_play_array_null = b == NULL;
    rig_play_count = n;
    for (k = 0; b != NULL && k < n && k < 8; ++k) {
        strncpy(rig_bindings[k].target, b[k].target ? b[k].target : "(null)", 31);
        rig_bindings[k].target[31] = 0;
        rig_bindings[k].item = b[k].item;
        rig_bindings[k].node = b[k].node;
    }
    if (rig_anim_refuses()) return 0;
    return rig_next_track++;
}
static bool rig_timeline_remove(CadaclysmView *v, uint32_t track) {
    (void)v;
    rig_removed_track = track;
    return !rig_anim_refuses();
}
static bool rig_set_item_visible(CadaclysmView *v, uint32_t item, bool on) {
    (void)v;
    rig_vis_item = item;
    rig_vis_on = on;
    return !rig_anim_refuses();
}
static bool rig_set_node_ghosts(CadaclysmView *v, uint32_t item, const uint32_t *nodes, uint32_t n) {
    uint32_t k;
    (void)v;
    rig_ghost_item = item;
    rig_ghost_null = nodes == NULL;
    rig_ghost_count = n;
    for (k = 0; nodes != NULL && k < n && k < 8; ++k) rig_ghost_nodes[k] = nodes[k];
    return !rig_anim_refuses();
}
static const void *rig_seen_play_anim(void) { return rig_play_anim; }
static int rig_seen_play_anim_null(void) { return rig_play_anim_null; }
static int rig_seen_play_array_null(void) { return rig_play_array_null; }
static uint32_t rig_seen_play_count(void) { return rig_play_count; }
static int rig_seen_anim_calls(void) { return rig_anim_calls; }
static uint32_t rig_seen_removed_track(void) { return rig_removed_track; }
static const char *rig_seen_binding_target(int k) { return rig_bindings[k].target; }
static uint32_t rig_seen_binding_item(int k) { return rig_bindings[k].item; }
static uint32_t rig_seen_binding_node(int k) { return rig_bindings[k].node; }
static uint32_t rig_seen_vis_item(void) { return rig_vis_item; }
static int rig_seen_vis_on(void) { return rig_vis_on; }
static uint32_t rig_seen_ghost_item(void) { return rig_ghost_item; }
static int rig_seen_ghost_null(void) { return rig_ghost_null; }
static uint32_t rig_seen_ghost_count(void) { return rig_ghost_count; }
static uint32_t rig_seen_ghost_node(int k) { return rig_ghost_nodes[k]; }
static size_t rig_binding_layout(int i) {
    static const size_t offsets[] = {
        offsetof(CadaclysmViewAnimationBinding, target),
        offsetof(CadaclysmViewAnimationBinding, item),
        offsetof(CadaclysmViewAnimationBinding, node),
        sizeof(CadaclysmViewAnimationBinding),
    };
    return offsets[i];
}
static void rig_refuse_animations(const char *text) {
    strncpy(rig_anim_refusal, text, sizeof rig_anim_refusal - 1);
    rig_anim_refusal[sizeof rig_anim_refusal - 1] = 0;
}
static void rig_animations_reset(void) {
    memset(rig_bindings, 0, sizeof rig_bindings);
    memset(rig_ghost_nodes, 0, sizeof rig_ghost_nodes);
    rig_play_anim = NULL;
    rig_play_count = rig_removed_track = rig_vis_item = rig_ghost_item = rig_ghost_count = 0;
    rig_next_track = 1;
    rig_play_anim_null = rig_play_array_null = rig_vis_on = rig_ghost_null = rig_anim_calls = 0;
    rig_anim_refusal[0] = 0;
}

// 1.28's drafting calls: each logs the numbers it was handed, as text, in rig_style_log.
static char rig_style_log[1024];
static void rig_style_note(const char *text) {
    size_t used = strlen(rig_style_log), n = strlen(text);
    if (used + n + 3 >= sizeof rig_style_log) return;
    if (used) {
        memcpy(rig_style_log + used, "; ", 2);
        used += 2;
    }
    memcpy(rig_style_log + used, text, n + 1);
}
static void rig_colour_text(char *out, size_t n, const float *c) {
    if (!c)
        snprintf(out, n, "nil");
    else
        snprintf(out, n, "%g,%g,%g", c[0], c[1], c[2]);
}
static bool rig_set_line_style(CadaclysmView *v, uint32_t item, float dash, float gap) {
    char text[128];
    (void)v;
    snprintf(text, sizeof text, "line_style %u %g %g", item, dash, gap);
    rig_style_note(text);
    return true;
}
static bool rig_set_point_style(CadaclysmView *v, uint32_t item, uint32_t shape, bool hollow) {
    char text[128];
    (void)v;
    snprintf(text, sizeof text, "point_style %u %u %d", item, shape, (int)hollow);
    rig_style_note(text);
    return true;
}
static bool rig_set_point_states(CadaclysmView *v, uint32_t item, const uint8_t *states, size_t n) {
    char text[128];
    size_t k, used;
    (void)v;
    used = (size_t)snprintf(text, sizeof text, "point_states %u %zu:", item, n);
    for (k = 0; k < n && used + 8 < sizeof text; ++k) used += (size_t)snprintf(text + used, sizeof text - used, " %u", (unsigned)states[k]);
    rig_style_note(text);
    return true;
}
static void rig_set_point_state_colours(CadaclysmView *v, const float *h, const float *s, const float *f) {
    char a[48], b[48], c[48], text[160];
    (void)v;
    rig_colour_text(a, sizeof a, h);
    rig_colour_text(b, sizeof b, s);
    rig_colour_text(c, sizeof c, f);
    snprintf(text, sizeof text, "state_colours %s %s %s", a, b, c);
    rig_style_note(text);
}
static bool rig_set_viewport_label(CadaclysmView *v, uint32_t viewport, const char *label, const float *c) {
    char col[48], text[160];
    (void)v;
    rig_colour_text(col, sizeof col, c);
    snprintf(text, sizeof text, "label %u %s %s", viewport, label ? label : "nil", col);
    rig_style_note(text);
    return true;
}
static bool rig_set_viewport_border(CadaclysmView *v, uint32_t viewport, const float *c) {
    char col[48], text[160];
    (void)v;
    rig_colour_text(col, sizeof col, c);
    snprintf(text, sizeof text, "border %u %s", viewport, col);
    rig_style_note(text);
    return true;
}
static bool rig_set_on_top(CadaclysmView *v, uint32_t item, bool on) {
    char text[64];
    (void)v;
    snprintf(text, sizeof text, "on_top %u %d", item, (int)on);
    rig_style_note(text);
    return true;
}
// 1.29's live-geometry calls and show_glyphs, logged in the same text log: the counts (in units),
// whether normals and dir were NULL, the kind's number, the size and the colour.
static bool rig_set_lines(CadaclysmView *v, uint32_t item, const float *p, size_t n) {
    char text[96];
    (void)v;
    snprintf(text, sizeof text, "lines %u %zu%s", item, n, p ? "" : " NULL");
    rig_style_note(text);
    return true;
}
static bool rig_set_curves(CadaclysmView *v, uint32_t item, const float *p, size_t n) {
    char text[96];
    (void)v;
    snprintf(text, sizeof text, "curves %u %zu%s", item, n, p ? "" : " NULL");
    rig_style_note(text);
    return true;
}
static bool rig_set_points(CadaclysmView *v, uint32_t item, const float *p, size_t n) {
    char text[96];
    (void)v;
    snprintf(text, sizeof text, "points %u %zu%s", item, n, p ? "" : " NULL");
    rig_style_note(text);
    return true;
}
static bool rig_set_mesh_positions(CadaclysmView *v, uint32_t item, const float *p, const float *normals, size_t n) {
    char text[96];
    (void)v;
    (void)p;
    snprintf(text, sizeof text, "mesh %u %zu %s", item, n, normals ? "normals" : "none");
    rig_style_note(text);
    return true;
}
static uint32_t rig_show_glyphs(CadaclysmView *v, const float *at, const float *dir, size_t n, uint32_t kind, float size_pt, const float *colour) {
    char col[48], text[160];
    (void)v;
    (void)at;
    rig_colour_text(col, sizeof col, colour);
    snprintf(text, sizeof text, "glyphs %zu %u %g dir=%s colour=%s", n, kind, size_pt, dir ? "given" : "nil", col);
    rig_style_note(text);
    return 21;
}
// 1.30's picking and snapping, logged in the same text log: the aperture, the base (NULL or its
// point) and step, the snap points (NULL or given, the count, the label or NULL) and each
// pick_rect's rectangle and capacity. pick_rect answers rig_rect_hits -- the total, at most the
// capacity written -- or 0 while rig_said holds a refusal.
static CadaclysmViewRectHit rig_rect_hits[128];
static size_t rig_rect_count;
static bool rig_set_pick_aperture(CadaclysmView *v, float a) {
    char text[64];
    (void)v;
    snprintf(text, sizeof text, "aperture %g", a);
    rig_style_note(text);
    return true;
}
static bool rig_set_snap_base(CadaclysmView *v, const float *xyz, float step) {
    char text[128];
    (void)v;
    if (xyz)
        snprintf(text, sizeof text, "base %g %g %g %g", xyz[0], xyz[1], xyz[2], step);
    else
        snprintf(text, sizeof text, "base NULL %g", step);
    rig_style_note(text);
    return true;
}
static bool rig_set_snap_points(CadaclysmView *v, uint32_t item, const float *xyz, size_t n, const char *label) {
    char text[160];
    (void)v;
    if (label)
        snprintf(text, sizeof text, "points %u %s %zu '%s'", item, xyz ? "given" : "NULL", n, label);
    else
        snprintf(text, sizeof text, "points %u %s %zu NULL", item, xyz ? "given" : "NULL", n);
    rig_style_note(text);
    return true;
}
static size_t rig_pick_rect(CadaclysmView *v, uint32_t viewport, float x, float y, float w, float h, bool crossing,
                            CadaclysmViewRectHit *out, size_t capacity) {
    char text[160];
    size_t k;
    (void)v;
    snprintf(text, sizeof text, "rect %u %g %g %g %g %s %zu", viewport, x, y, w, h, crossing ? "crossing" : "window", capacity);
    rig_style_note(text);
    if (rig_said[0]) return 0;
    for (k = 0; k < rig_rect_count && k < capacity; ++k) out[k] = rig_rect_hits[k];
    return rig_rect_count;
}
static void rig_set_rect_hit(int k, uint32_t item, uint32_t kind, uint32_t index) {
    if (k < 0 || k >= 128) return;
    rig_rect_hits[k].item = item;
    rig_rect_hits[k].kind = kind;
    rig_rect_hits[k].index = index;
}
static void rig_set_rect_count(size_t n) { rig_rect_count = n < 128 ? n : 128; }
static void rig_set_pick_segment(uint32_t segment, float distance) {
    rig_pick.segment = segment;
    rig_pick.distance_px = distance;
}
static uint32_t rig_seen_pick_segment(void) { return rig_pick_segment_seen; }
static int32_t rig_seen_event_label(void) { return rig_event_label_seen; }
static uint32_t rig_seen_event_segment(void) { return rig_event_segment_seen; }
// The 1.30 tail of a snap answer: label, lock, guide count and twelve guide doubles.
static void rig_set_snap_tail(const char *label, int locked, float angle, uint32_t count, const double *guides) {
    memset(rig_snap.label, 0, sizeof rig_snap.label);
    strncpy(rig_snap.label, label, sizeof rig_snap.label - 1);
    rig_snap.locked = locked ? 1u : 0u;
    rig_snap.locked_angle = angle;
    rig_snap.guide_count = count;
    memcpy(rig_snap.guides, guides, sizeof rig_snap.guides);
}
// The 1.30 tail of the event queued last: the pick's segment and distance, the snap's label,
// lock and guides.
static void rig_tail_last(uint32_t segment, float distance, const char *label, int locked, float angle, uint32_t count,
                          const double *guides) {
    CadaclysmViewInputEvent *e;
    if (rig_event_count == 0) return;
    e = &rig_events[rig_event_count - 1];
    e->pick_segment = segment;
    e->pick_distance_px = distance;
    memset(e->snap_label, 0, sizeof e->snap_label);
    strncpy(e->snap_label, label, sizeof e->snap_label - 1);
    e->snap_locked = locked ? 1u : 0u;
    e->snap_locked_angle = angle;
    e->snap_guide_count = count;
    memcpy(e->snap_guides, guides, sizeof e->snap_guides);
}
// The 1.30 layouts: the pick's size, segment and distance_px; the snap's size, label and guides;
// the event's frozen snap; the event's size, camera, pick_segment and snap_guides; the rect hit.
static size_t rig_layout130(int i) {
    static const size_t at[] = {
        sizeof(CadaclysmViewPick),        offsetof(CadaclysmViewPick, segment),
        offsetof(CadaclysmViewPick, distance_px), sizeof(CadaclysmViewSnap),
        offsetof(CadaclysmViewSnap, label),       offsetof(CadaclysmViewSnap, guides),
        sizeof(CadaclysmViewEventSnap),           sizeof(CadaclysmViewInputEvent),
        offsetof(CadaclysmViewInputEvent, camera), offsetof(CadaclysmViewInputEvent, pick_segment),
        offsetof(CadaclysmViewInputEvent, snap_guides), sizeof(CadaclysmViewRectHit),
    };
    return at[i];
}
static const char *rig_styles_logged(void) { return rig_style_log; }

static void *rig_fn(const char *name) {
    static const struct {
        const char *name;
        void *fn;
    } calls[] = {
        {"last_error", (void *)rig_last_error},
        {"create", (void *)rig_create},
        {"create_fails", (void *)rig_create_fails},
        {"destroy", (void *)rig_destroy},
        {"pump", (void *)rig_pump},
        {"input", (void *)rig_input},
        {"needs_draw", (void *)rig_needs_draw},
        {"orbit", (void *)rig_orbit},
        {"frame", (void *)rig_frame},
        {"remove", (void *)rig_remove},
        {"run", (void *)rig_run},
        {"show_lines", (void *)rig_show_lines},
        {"show_curves", (void *)rig_show_lines},
        {"show_points", (void *)rig_show_points},
        {"show_mesh", (void *)rig_show_mesh},
        {"show_image", (void *)rig_show_image},
        {"set_face_colours", (void *)rig_set_face_colours},
        {"set_node_transforms", (void *)rig_set_node_transforms},
        {"set_viewports", (void *)rig_set_viewports},
        {"draw", (void *)rig_draw},
        {"request_pick_in", (void *)rig_request_pick_in},
        {"pick_result", (void *)rig_pick_result},
        {"set_double_click_frames", (void *)rig_set_double_click_frames},
        {"focus", (void *)rig_focus},
        {"navigation", (void *)rig_navigation_of},
        {"set_snap", (void *)rig_set_snap},
        {"request_snap_in", (void *)rig_request_snap_in},
        {"snap_result", (void *)rig_snap_result},
        {"clear_snap", (void *)rig_clear_snap},
        {"set_work_plane", (void *)rig_set_work_plane},
        {"clear_work_plane", (void *)rig_clear_work_plane},
        {"show_machining", (void *)rig_show_machining},
        {"machining_seek", (void *)rig_machining_seek},
        {"machining_colour_by", (void *)rig_machining_colour_by},
        {"machining_overlays", (void *)rig_machining_overlays},
        {"machining_info", (void *)rig_machining_info},
        {"machining_heights", (void *)rig_machining_heights},
        {"timeline_play", (void *)rig_timeline_play},
        {"timeline_pause", (void *)rig_timeline_pause},
        {"timeline_seek", (void *)rig_timeline_seek},
        {"timeline_set_loop", (void *)rig_timeline_set_loop},
        {"timeline_time", (void *)rig_timeline_time},
        {"timeline_duration", (void *)rig_timeline_duration},
        {"timeline_playing", (void *)rig_timeline_playing},
        {"timeline_status", (void *)rig_timeline_status},
        {"play_animation", (void *)rig_play_animation},
        {"timeline_remove", (void *)rig_timeline_remove},
        {"set_item_visible", (void *)rig_set_item_visible},
        {"set_node_ghosts", (void *)rig_set_node_ghosts},
        {"next_event", (void *)rig_next_event},
        {"set_line_style", (void *)rig_set_line_style},
        {"set_point_style", (void *)rig_set_point_style},
        {"set_point_states", (void *)rig_set_point_states},
        {"set_point_state_colours", (void *)rig_set_point_state_colours},
        {"set_viewport_label", (void *)rig_set_viewport_label},
        {"set_viewport_border", (void *)rig_set_viewport_border},
        {"set_on_top", (void *)rig_set_on_top},
        {"set_lines", (void *)rig_set_lines},
        {"set_curves", (void *)rig_set_curves},
        {"set_points", (void *)rig_set_points},
        {"set_mesh_positions", (void *)rig_set_mesh_positions},
        {"show_glyphs", (void *)rig_show_glyphs},
        {"set_pick_aperture", (void *)rig_set_pick_aperture},
        {"set_snap_base", (void *)rig_set_snap_base},
        {"set_snap_points", (void *)rig_set_snap_points},
        {"pick_rect", (void *)rig_pick_rect},
        {"close", (void *)rig_close},
        {"pump_events", (void *)rig_pump_events},
        {"pick_result_or_none", (void *)rig_pick_result_or_none},
    };
    size_t i;
    for (i = 0; i < sizeof calls / sizeof calls[0]; ++i)
        if (strcmp(name, calls[i].name) == 0) return calls[i].fn;
    return NULL;
}

static void rig_reset(void) {
    rig_said[0] = 0;
    rig_answer_count = rig_pumped = rig_calls = rig_null = 0;
    rig_count = rig_bits = 0;
    memset(rig_waits, 0, sizeof rig_waits);
    memset(&rig_pick, 0, sizeof rig_pick);
    rig_pick.viewport_label = -1;
    rig_pick.segment = 0xFFFFFFFFu;
    rig_pick_segment_seen = 0;
    rig_rect_count = 0;
    rig_style_log[0] = 0;
    rig_old_pick = 0;
    rig_log[0] = 0;
    rig_navigation = 0;
    memset(&rig_snap_settings, 0, sizeof rig_snap_settings);
    rig_snap_sets = 0;
    memset(&rig_snap, 0, sizeof rig_snap);
    rig_snap_landed = 1;
    memset(rig_points, 0, sizeof rig_points);
    memset(rig_points_rgb, 0, sizeof rig_points_rgb);
    rig_points_size = 0.0f;
    rig_points_count = 0;
    rig_points_rgb_null = rig_points_calls = 0;
    rig_machining_reset();
    rig_animations_reset();
    rig_event_count = rig_event_next = rig_closes = rig_event_calls = 0;
    rig_event_size = 0;
    rig_event_refusal[0] = 0;
    rig_closing_set = 0;
    rig_pick_landed = 1;
}
static void rig_set_pick(uint32_t item, uint32_t node, uint32_t face, uint32_t clicks, uint32_t has_point, float x,
                         float y, float z) {
    rig_pick.item = item;
    rig_pick.node = node;
    rig_pick.face = face;
    rig_pick.clicks = clicks;
    rig_pick.has_point = has_point;
    rig_pick.point[0] = x;
    rig_pick.point[1] = y;
    rig_pick.point[2] = z;
}
static void rig_set_pick_label(int32_t label) { rig_pick.viewport_label = label; }
static void rig_set_old_pick(int on) { rig_old_pick = on != 0; }
static void rig_set_navigation(uint32_t n) { rig_navigation = n; }
static const char *rig_logged(void) { return rig_log; }
static void rig_say(const char *text) {
    strncpy(rig_said, text, sizeof rig_said - 1);
    rig_said[sizeof rig_said - 1] = 0;
}
static void rig_answer(int i, uint32_t a) {
    rig_answers[i] = a;
    rig_answer_count = i + 1;
}
static uint32_t rig_wait(int i) { return rig_waits[i]; }
static int rig_pumps(void) { return rig_pumped; }
static void rig_input_bits(uint32_t b) { rig_bits = b; }
static int rig_seen_null(void) { return rig_null; }
static uint32_t rig_seen_count(void) { return rig_count; }
static int rig_seen_calls(void) { return rig_calls; }
*/
import "C"

import "unsafe"

// Fn is the stand-in called name (the call's name in the table, "create_fails" for a
// create that answers NULL), or nil.
func Fn(name string) unsafe.Pointer {
	c := C.CString(name)
	defer C.free(unsafe.Pointer(c))
	return C.rig_fn(c)
}

// Calls is the stand-ins named, as view.RiggedForTest takes them: name in the table ->
// stand-in. "create_fails" replaces create.
func Calls(names ...string) map[string]unsafe.Pointer {
	out := map[string]unsafe.Pointer{}
	for _, n := range names {
		call := n
		switch n {
		case "create_fails":
			call = "create"
		case "pump_events":
			call = "pump"
		case "pick_result_or_none":
			call = "pick_result"
		}
		out[call] = Fn(n)
	}
	return out
}

// Reset forgets every answer and everything seen.
func Reset() { C.rig_reset() }

// Say is what last_error answers from now on ("": nothing).
func Say(text string) {
	c := C.CString(text)
	defer C.free(unsafe.Pointer(c))
	C.rig_say(c)
}

// PumpAnswers are pump's next answers, in order; OPEN after them.
func PumpAnswers(answers ...uint32) {
	for i, a := range answers {
		C.rig_answer(C.int(i), C.uint32_t(a))
	}
}

// Pumps is how many pump calls were made since Reset, and the wait each was given.
func Pumps() (n int, waits []uint32) {
	n = int(C.rig_pumps())
	for i := 0; i < n && i < 16; i++ {
		waits = append(waits, uint32(C.rig_wait(C.int(i))))
	}
	return n, waits
}

// InputBits is what input answers from now on.
func InputBits(bits uint32) { C.rig_input_bits(C.uint32_t(bits)) }

// Seen is what the last array-taking stand-in was given: whether its array was NULL, its
// count, and how many such calls were made since Reset.
func Seen() (null bool, count uint32, calls int) {
	return C.rig_seen_null() != 0, uint32(C.rig_seen_count()), int(C.rig_seen_calls())
}

// SetPick is the pick answer pick_result and run hand back from now on (item 0: nothing).
func SetPick(item, node, face, clicks uint32, hasPoint bool, point [3]float32) {
	h := C.uint32_t(0)
	if hasPoint {
		h = 1
	}
	C.rig_set_pick(C.uint32_t(item), C.uint32_t(node), C.uint32_t(face), C.uint32_t(clicks), h,
		C.float(point[0]), C.float(point[1]), C.float(point[2]))
}

// SetNavigation is what navigation answers from now on.
func SetNavigation(n uint32) { C.rig_set_navigation(C.uint32_t(n)) }

// Log is what set_double_click_frames, focus and navigation were called with since Reset,
// "; " between calls.
func Log() string { return C.GoString(C.rig_logged()) }

// StyleLog is what 1.28's drafting calls and 1.29's live-geometry and glyph calls were handed since Reset, one text each, joined by "; ".
func StyleLog() string { return C.GoString(C.rig_styles_logged()) }

// SetPickLabel is the viewport_label of the pick pick_result and run hand back (Reset: -1, none).
func SetPickLabel(label int32) { C.rig_set_pick_label(C.int32_t(label)) }

// OldPick makes pick_result and run write the pick only up to the fields before 1.28's label, as an older
// library does: the host's own buffer init is then what the label reads.
func OldPick(on bool) {
	v := 0
	if on {
		v = 1
	}
	C.rig_set_old_pick(C.int(v))
}

// SnapSettings is what the last set_snap was handed -- its size, kinds, aperture and marker
// -- and how many set_snap calls were made since Reset.
func SnapSettings() (size, kinds uint32, aperturePx float32, marker uint32, calls int) {
	s := C.rig_seen_snap_settings()
	return uint32(s.size), uint32(s.kinds), float32(s.aperture_px), uint32(s.marker), int(C.rig_snap_set_calls())
}

// Answer is a snap answer as snap_result hands it back: CadaclysmViewSnap's fields but size.
type Answer struct {
	Kind             uint32
	Point            [3]float64
	Item, Node, Face uint32
	Edge             uint32
	Tangent, Axis    [3]float32
	Radius           float64
	DistancePx       float32
	Clicks           uint32
}

// SetSnapAnswer is what snap_result hands back from now on (Kind 0: nothing snapped).
func SetSnapAnswer(a Answer) {
	var s C.CadaclysmViewSnap
	s.kind = C.uint32_t(a.Kind)
	s.item, s.node, s.face, s.edge = C.uint32_t(a.Item), C.uint32_t(a.Node), C.uint32_t(a.Face), C.uint32_t(a.Edge)
	for i := 0; i < 3; i++ {
		s.point[i] = C.double(a.Point[i])
		s.tangent[i] = C.float(a.Tangent[i])
		s.axis[i] = C.float(a.Axis[i])
	}
	s.radius = C.double(a.Radius)
	s.distance_px = C.float(a.DistancePx)
	s.clicks = C.uint32_t(a.Clicks)
	C.rig_set_snap_answer(&s)
}

// SnapLanded is whether snap_result answers (true after Reset); false answers false, with
// whatever Say set as the reason.
func SnapLanded(on bool) {
	l := C.int(0)
	if on {
		l = 1
	}
	C.rig_set_snap_landed(l)
}

// Points is what the last show_points was handed: its floats (up to 12), its rgb (nil for
// NULL) and its size, and how many show_points calls were made since Reset.
func Points() (positions []float32, rgb []float32, sizePx float32, calls int) {
	n := int(C.rig_point_count()) * 3
	if n > 12 {
		n = 12
	}
	for i := 0; i < n; i++ {
		positions = append(positions, float32(C.rig_point(C.int(i))))
	}
	if C.rig_point_rgb_null() == 0 {
		rgb = []float32{float32(C.rig_point_rgb(0)), float32(C.rig_point_rgb(1)), float32(C.rig_point_rgb(2))}
	}
	return positions, rgb, float32(C.rig_point_size()), int(C.rig_point_calls())
}

// ---- view ABI 1.7: the machining and timeline calls ----

// ProgramSeen is one program as show_machining was handed it.
type ProgramSeen struct {
	Size, Number, Shape                        uint32
	Diameter, FluteLength, Angle, CornerRadius float64
	Gcode                                      string
}

// MachiningSeen is what the last show_machining was handed (Calls: how many since Reset).
type MachiningSeen struct {
	Calls                            int
	Size, ProgramCount, ProgramSize  uint32        // the struct's, the count, the programs' stride
	Programs                         []ProgramSeen // up to four
	StockMin, StockMax               [3]float64
	PartNull                         bool
	PartVertices, PartIndices        uint32
	PartPositions                    []float32 // up to 12
	PartTriangles                    []uint32  // up to 12
	Cell, Tolerance, Skin, RapidRate float64
	SkinSet                          uint32
}

// Machining is what the last show_machining was handed, copied.
func Machining() MachiningSeen {
	m := C.rig_seen_machining()
	out := MachiningSeen{Calls: int(m.calls), Size: uint32(m.size), ProgramCount: uint32(m.program_count),
		ProgramSize: uint32(m.program_size), PartNull: m.part_null != 0, PartVertices: uint32(m.part_vertices),
		PartIndices: uint32(m.part_indices), Cell: float64(m.cell), Tolerance: float64(m.tolerance),
		Skin: float64(m.skin), RapidRate: float64(m.rapid_rate), SkinSet: uint32(m.skin_set)}
	for i := 0; i < 4 && i < int(m.program_count); i++ {
		p := &m.programs[i]
		out.Programs = append(out.Programs, ProgramSeen{Size: uint32(p.size), Number: uint32(p.number), Shape: uint32(p.shape),
			Diameter: float64(p.diameter), FluteLength: float64(p.flute), Angle: float64(p.angle), CornerRadius: float64(p.corner),
			Gcode: C.GoString(&p.gcode[0])})
	}
	for a := 0; a < 3; a++ {
		out.StockMin[a], out.StockMax[a] = float64(m.stock_min[a]), float64(m.stock_max[a])
	}
	for i := 0; i < 12 && i < 3*int(m.part_vertices); i++ {
		out.PartPositions = append(out.PartPositions, float32(m.part_positions[i]))
	}
	for i := 0; i < 12 && i < int(m.part_indices); i++ {
		out.PartTriangles = append(out.PartTriangles, uint32(m.part_triangles[i]))
	}
	return out
}

// SetInfo is what machining_info answers from now on.
func SetInfo(moves, move, nx, ny uint32, cell float32, min [2]float32, cycleTime float64) {
	C.rig_set_info(C.uint32_t(moves), C.uint32_t(move), C.uint32_t(nx), C.uint32_t(ny), C.float(cell),
		C.float(min[0]), C.float(min[1]), C.double(cycleTime))
}

// SetTimeline is what timeline_time, timeline_duration and timeline_playing answer.
func SetTimeline(time, duration float64, playing bool) {
	p := C.int(0)
	if playing {
		p = 1
	}
	C.rig_set_timeline(C.double(time), C.double(duration), p)
}

// Refusing makes the machining and transport calls that return a bool answer false (with
// last_error "refused by the rig" when `say` is set by the test), or true again.
func Refusing(on bool) {
	ok := C.int(1)
	if on {
		ok = 0
	}
	C.rig_set_calls_ok(ok)
}

// StatusAnswers are the texts timeline_status answers with, call after call (the last again
// after them): the library's two-call idiom measures with the first and fills from the next.
func StatusAnswers(texts ...string) {
	for _, t := range texts {
		c := C.CString(t)
		C.rig_add_status(c)
		C.free(unsafe.Pointer(c))
	}
}

// StatusCalls is how many timeline_status calls were made since Reset.
func StatusCalls() int { return int(C.rig_status_calls_made()) }

// InfoSize is the `size` machining_info was handed; HeightsCapacity the capacity
// machining_heights was handed.
func InfoSize() uint32        { return uint32(C.rig_seen_info_size()) }
func HeightsCapacity() uint32 { return uint32(C.rig_seen_heights_capacity()) }

// Event is one raw CadaclysmViewInputEvent for next_event's queue (view ABI 1.26): the
// header's numbers as given, nothing translated. PickItem/PickClicks, SnapKind/SnapEdge and
// Eye/Up fill the pick, snap and camera.
type Event struct {
	Kind, Modifiers                uint32
	X, Y, WheelY                   float32
	Button, Pointer, PointerID     uint32
	Width, Height, Repeat, Dropped uint32
	TimeMS                         float64
	Key                            string
	PickItem, PickClicks           uint32
	PickLabel                      *int32 // pick_viewport_label (1.28); nil: -1, none
	SnapKind, SnapEdge             uint32
	Eye, Up                        [3]float32
	// 1.30's tail: pick_segment (nil: UINT32_MAX, none) and pick_distance_px; the snap's label,
	// lock, guide count and guides.
	PickSegment    *uint32
	PickDistance   float32
	SnapLabel      string
	SnapLocked     bool
	SnapAngle      float32
	SnapGuideCount uint32
	SnapGuides     [12]float64
}

func push(e Event, closing bool) {
	k := C.CString(e.Key)
	defer C.free(unsafe.Pointer(k))
	c := C.int(0)
	if closing {
		c = 1
	}
	label := C.int32_t(-1)
	if e.PickLabel != nil {
		label = C.int32_t(*e.PickLabel)
	}
	C.rig_push_event(C.uint32_t(e.Kind), C.uint32_t(e.Modifiers), C.float(e.X), C.float(e.Y), C.float(e.WheelY),
		C.uint32_t(e.Button), C.uint32_t(e.Pointer), C.uint32_t(e.PointerID), C.uint32_t(e.Width), C.uint32_t(e.Height),
		C.uint32_t(e.Repeat), C.uint32_t(e.Dropped), C.double(e.TimeMS), k, C.uint32_t(e.PickItem), C.uint32_t(e.PickClicks),
		C.uint32_t(e.SnapKind), C.uint32_t(e.SnapEdge), C.float(e.Eye[0]), C.float(e.Eye[1]), C.float(e.Eye[2]),
		C.float(e.Up[0]), C.float(e.Up[1]), C.float(e.Up[2]), c, label)
	if closing {
		return
	}
	segment := C.uint32_t(0xFFFFFFFF)
	if e.PickSegment != nil {
		segment = C.uint32_t(*e.PickSegment)
	}
	l := C.CString(e.SnapLabel)
	defer C.free(unsafe.Pointer(l))
	var g [12]C.double
	for i := range g {
		g[i] = C.double(e.SnapGuides[i])
	}
	locked := C.int(0)
	if e.SnapLocked {
		locked = 1
	}
	C.rig_tail_last(segment, C.float(e.PickDistance), l, locked, C.float(e.SnapAngle), C.uint32_t(e.SnapGuideCount), &g[0])
}

// QueueEvents appends events to next_event's queue (rigged as "next_event").
func QueueEvents(events ...Event) {
	for _, e := range events {
		push(e, false)
	}
}

// ClosingEvent is the CLOSE event the next CLOSED answer of the "pump_events" pump queues: the
// window closing by itself.
func ClosingEvent(e Event) { push(e, true) }

// RefuseEvents makes next_event fail with text from now on ("": answer again).
func RefuseEvents(text string) {
	c := C.CString(text)
	defer C.free(unsafe.Pointer(c))
	C.rig_refuse_events(c)
}

// PickLanded is whether "pick_result_or_none" answers the rig's pick (true, as after Reset) or
// "no pick result".
func PickLanded(on bool) {
	c := C.int(0)
	if on {
		c = 1
	}
	C.rig_set_pick_landed(c)
}

// Closes is how many close calls were made since Reset.
func Closes() int { return int(C.rig_closes_made()) }

// EventCalls is how many next_event calls were made since Reset, and the size the last one
// was handed.
func EventCalls() (calls int, size uint32) {
	return int(C.rig_event_calls_made()), uint32(C.rig_event_size_seen())
}

// InputEventLayout is CadaclysmViewInputEvent's field offsets in the header's order (size,
// kind, time_ms, x, y, wheel_y, button, modifiers, pointer, pointer_id, width, height, repeat,
// dropped, pad0, key, pick, snap, camera, pick_viewport_label), then its size.
func InputEventLayout() [21]uintptr {
	var out [21]uintptr
	for i := range out {
		out[i] = uintptr(C.rig_input_event_layout(C.int(i)))
	}
	return out
}

// SeenBinding is one CadaclysmViewAnimationBinding play_animation was handed.
type SeenBinding struct {
	Target     string
	Item, Node uint32
}

// Played is what the last play_animation was handed: the animation's address (0 for NULL), the
// bindings array's NULL-ness and count, the first eight bindings, and how many animation calls
// of the four were made since Reset.
type Played struct {
	Animation    uintptr
	AnimNull     bool
	ArrayNull    bool
	Count        uint32
	Bindings     []SeenBinding
	AnimCalls    int
	RemovedTrack uint32
}

// PlayedAnimation reads back the last play_animation.
func PlayedAnimation() Played {
	p := Played{Animation: uintptr(C.rig_seen_play_anim()), AnimNull: C.rig_seen_play_anim_null() != 0,
		ArrayNull: C.rig_seen_play_array_null() != 0, Count: uint32(C.rig_seen_play_count()), AnimCalls: int(C.rig_seen_anim_calls()),
		RemovedTrack: uint32(C.rig_seen_removed_track())}
	for k := 0; k < int(p.Count) && k < 8; k++ {
		p.Bindings = append(p.Bindings, SeenBinding{Target: C.GoString(C.rig_seen_binding_target(C.int(k))),
			Item: uint32(C.rig_seen_binding_item(C.int(k))), Node: uint32(C.rig_seen_binding_node(C.int(k)))})
	}
	return p
}

// Visible is the item and flag the last set_item_visible was handed.
func Visible() (item uint32, on bool) { return uint32(C.rig_seen_vis_item()), C.rig_seen_vis_on() != 0 }

// Ghosts is what the last set_node_ghosts was handed: the item, whether the array was NULL,
// the count and the first eight nodes.
func Ghosts() (item uint32, null bool, count uint32, nodes []uint32) {
	for k := 0; k < int(C.rig_seen_ghost_count()) && k < 8; k++ {
		nodes = append(nodes, uint32(C.rig_seen_ghost_node(C.int(k))))
	}
	return uint32(C.rig_seen_ghost_item()), C.rig_seen_ghost_null() != 0, uint32(C.rig_seen_ghost_count()), nodes
}

// RefuseAnimations makes play_animation, timeline_remove, set_item_visible and set_node_ghosts
// fail with text from now on ("": answer again).
func RefuseAnimations(text string) {
	c := C.CString(text)
	defer C.free(unsafe.Pointer(c))
	C.rig_refuse_animations(c)
}

// BindingLayout is CadaclysmViewAnimationBinding's offsets (target, item, node) and size.
func BindingLayout() [4]uintptr {
	var out [4]uintptr
	for i := range out {
		out[i] = uintptr(C.rig_binding_layout(C.int(i)))
	}
	return out
}

// ---- view ABI 1.30: picking and snapping ----

// Layout130 is, from the header through C: the pick's size, segment and distance_px offsets;
// the snap's size, label and guides offsets; the event's frozen snap's size; the event's size
// and its camera, pick_segment and snap_guides offsets; the rect hit's size.
func Layout130() [12]uintptr {
	var out [12]uintptr
	for i := range out {
		out[i] = uintptr(C.rig_layout130(C.int(i)))
	}
	return out
}

// SetRectHits is what pick_rect answers from now on: each {item, kind, index} (at most 128).
func SetRectHits(hits [][3]uint32) {
	for k, h := range hits {
		C.rig_set_rect_hit(C.int(k), C.uint32_t(h[0]), C.uint32_t(h[1]), C.uint32_t(h[2]))
	}
	C.rig_set_rect_count(C.size_t(len(hits)))
}

// SetPickSegment is the segment and distance_px of the pick pick_result and run hand back
// (Reset: UINT32_MAX and 0, none).
func SetPickSegment(segment uint32, distancePx float32) {
	C.rig_set_pick_segment(C.uint32_t(segment), C.float(distancePx))
}

// PickSegmentSeen is the segment the last pick_result's buffer arrived with.
func PickSegmentSeen() uint32 { return uint32(C.rig_seen_pick_segment()) }

// EventBufferSeen is the pick_viewport_label and pick_segment the last next_event's buffer
// arrived with.
func EventBufferSeen() (label int32, segment uint32) {
	return int32(C.rig_seen_event_label()), uint32(C.rig_seen_event_segment())
}

// SetSnapTail is the 1.30 tail of the snap answer snap_result hands back: its label, whether
// it is locked and at what angle, guide_count and the twelve guide doubles. Set it after
// SetSnapAnswer, which clears it.
func SetSnapTail(label string, locked bool, angle float32, count uint32, guides [12]float64) {
	l := C.CString(label)
	defer C.free(unsafe.Pointer(l))
	var g [12]C.double
	for i := range g {
		g[i] = C.double(guides[i])
	}
	k := C.int(0)
	if locked {
		k = 1
	}
	C.rig_set_snap_tail(l, k, C.float(angle), C.uint32_t(count), &g[0])
}
