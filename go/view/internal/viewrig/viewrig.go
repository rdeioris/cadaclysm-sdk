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
static void rig_fill(CadaclysmViewPick *p) {
    uint32_t size = p->size;
    CadaclysmViewPick answer = rig_pick;
    answer.size = size;
    memcpy(p, &answer, size < sizeof answer ? size : sizeof answer);
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
    rig_log[0] = 0;
    rig_navigation = 0;
    memset(rig_points, 0, sizeof rig_points);
    memset(rig_points_rgb, 0, sizeof rig_points_rgb);
    rig_points_size = 0.0f;
    rig_points_count = 0;
    rig_points_rgb_null = rig_points_calls = 0;
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
		if n == "create_fails" {
			call = "create"
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
