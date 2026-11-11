// Package view draws through a view library -- one that implements cadaclysm_view.h --
// opened at run time: the terminal (cadaclysm_terminal) by default, the GPU window
// (cadaclysm_view, on wgpu) after UseWgpu, any other with Use(path) or CADACLYSM_VIEW.
// Nothing of it is linked; a program that draws only meshes, lines, curves or images loads
// neither the reader nor the kernel. Python's cadaclysm.view, in Go.
//
// # Drawing
//
//	solid, _ := blacksmith.Sphere(10)
//	view.UseWgpu()          // else the terminal prints a still
//	solid.Show(nil)         // blocks until the window is closed
//	cam, _ := solid.View(&view.ShowOptions{View: "top"})
//
// A View of your own holds several items and stays open:
//
//	v, _ := view.New(&view.Options{Title: "Parts", Width: 900, Height: 600})
//	defer v.Close()
//	item, _ := v.ShowSolid(solid, blacksmith.DefaultTolerance, nil)
//	item.Colour([3]float32{0.9, 0.3, 0.1}) // or "#e64d1a", "tomato"
//	v.Frame()
//	v.Run()                 // or Pump in a loop of your own
//
// Offscreen needs no display (SSH, CI): Image and Save read its pixels. InWindow draws in
// a host's native window; the host forwards Input, Resize and Draw.
//
// # Where the library is found
//
// UseTerminal reads CADACLYSM_TERMINAL_LIBRARY, UseWgpu CADACLYSM_VIEW_LIBRARY (the library
// or its directory); otherwise beside the loaded reader, beside the executable, this
// package's ../../lib (an SDK checkout) and the repository's target/release, then the
// platform loader's path. Nothing found is "no view library: ...".
//
// # Colours
//
// Every colour argument is a Colour: numbers, or text the view library reads itself --
// "#rgb", "#rrggbb" or a CSS colour name, as in every wrapper.
//
// # Errors
//
// Every failure is an *Error: the library's own message ("the view library failed" when
// it left none), or the package's refusal in Python's words. A call on a closed View (or an
// Item of one) is "<cadaclysm_view_call>: the view is closed", and once the view's own
// window was closed "<cadaclysm_view_call>: the window is closed"; errors.Is matches them
// against ErrClosed and ErrWindowClosed.
//
// # Threads and lifetimes
//
// A View belongs to the goroutine that made it: New, Offscreen and InWindow lock that
// goroutine to its OS thread until Close, and every call of the view, Close included, must
// come from that goroutine -- the view library keeps its state and its last error per OS
// thread. A call from another goroutine is refused, as Python refuses another thread's:
// "<cadaclysm_view_call>: a view belongs to the thread that made it" ("close: ..." for
// Close, which then leaves the view and every thread lock as they were). The view knows
// its maker by its OS thread, which no other goroutine can run on while the view is alive;
// the one gap is a maker that ended without Close, whose thread id the system may reuse.
// Pump reaches the windows of the calling goroutine's thread only.
//
// On macOS a window of the view's own (New, Show, View) must be made on the main thread.
// Go starts main on it but may move it; lock it there before anything else runs, in
// package main:
//
//	func init() { runtime.LockOSThread() }
//
// This package does not do that itself: every program that imports the reader or the kernel
// imports it, and most never open a window.
//
// Close a View -- there is no finalizer, which would run on another thread. An item shown
// by handle (ShowSolid, ShowScene) keeps its solid or scene reachable until the item is
// removed or the view is closed. Scene.Close first removes the items of this thread's
// views that show the scene (Release); closing a solid yourself while it is shown is a
// use-after-free in the library. Show and View (on a solid, a scene, a node or a pose) draw
// in a view of their own, on the calling goroutine's thread for the call, which Scene.Close
// does not see while they run: do not close the scene they draw from another goroutine
// meanwhile.
package view

/*
#cgo CFLAGS: -I${SRCDIR} -I${SRCDIR}/../../include -I${SRCDIR}/../../../../cadaclysm-view-capi/include
// view_loader.h's camera arithmetic (atan2, asin, hypot, log) is libm's, separate from libc on glibc.
#cgo linux LDFLAGS: -ldl -lm
// syscall() is a GNU extension: defined before the first system header.
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#include <stdlib.h>
// <...>, not "...": on Windows cgo compiles its probes from %TEMP% (see cad.go).
#include <view_loader.h>
#if defined(__linux__)
#include <sys/syscall.h>
#include <unistd.h>
#elif !defined(_WIN32)
#include <pthread.h>
#endif

// The OS thread this runs on, as a number: a View remembers its own (Pump and Release
// reach the calling thread's views only).
static uint64_t cv_thread(void) {
#if defined(_WIN32)
    return (uint64_t)GetCurrentThreadId();
#elif defined(__linux__)
    return (uint64_t)syscall(SYS_gettid); // pthread_self() values are reused by glibc
#elif defined(__APPLE__)
    uint64_t id = 0;
    pthread_threadid_np(NULL, &id);
    return id;
#else
    return (uint64_t)(uintptr_t)pthread_self();
#endif
}

// Go cannot call a C function pointer: one forwarding call each.
static CvlTable *cv_table(void) { return (CvlTable *)calloc(1, sizeof(CvlTable)); }
static const char *cv_last_error(const CvlTable *t) { return t->last_error(); }
static bool cv_parse_colour(const CvlTable *t, const char *text, float *out) { return t->parse_colour(text, out); }
static void cv_destroy(const CvlTable *t, CadaclysmView *v) { t->destroy(v); }
static uint32_t cv_pump(const CvlTable *t, CadaclysmView *v, uint32_t ms) { return t->pump(v, ms); }
static bool cv_run(const CvlTable *t, CadaclysmView *v, CadaclysmViewCamera *c, CadaclysmViewPick *p) { return t->run(v, c, p); }
static bool cv_resize(const CvlTable *t, CadaclysmView *v, uint32_t w, uint32_t h) { return t->resize(v, w, h); }
static bool cv_needs_draw(const CvlTable *t, CadaclysmView *v) { return t->needs_draw(v); }
static bool cv_draw(const CvlTable *t, CadaclysmView *v) { return t->draw(v); }
static bool cv_size(const CvlTable *t, CadaclysmView *v, uint32_t *w, uint32_t *h) { return t->size(v, w, h); }
static bool cv_image(const CvlTable *t, CadaclysmView *v, uint8_t *rgba, size_t n) { return t->image(v, rgba, n); }
static uint32_t cv_show(const CvlTable *t, CadaclysmView *v, void *scene) { return t->show(v, (const CadaclysmScene *)scene); }
static bool cv_remove(const CvlTable *t, CadaclysmView *v, uint32_t item) { return t->remove(v, item); }
static bool cv_set_surfaces(const CvlTable *t, CadaclysmView *v, uint32_t s) { return t->set_surfaces(v, s); }
static void cv_orbit(const CvlTable *t, CadaclysmView *v, float dx, float dy) { t->orbit(v, dx, dy); }
static void cv_pan(const CvlTable *t, CadaclysmView *v, float dx, float dy) { t->pan(v, dx, dy); }
static void cv_zoom(const CvlTable *t, CadaclysmView *v, float s) { t->zoom(v, s); }
static bool cv_frame(const CvlTable *t, CadaclysmView *v, uint32_t item) { return t->frame(v, item); }
static bool cv_standard(const CvlTable *t, CadaclysmView *v, uint32_t w) { return t->standard(v, w); }
static void cv_set_orthographic(const CvlTable *t, CadaclysmView *v, bool on) { t->set_orthographic(v, on); }
static bool cv_set_layer(const CvlTable *t, CadaclysmView *v, uint32_t l, bool on) { return t->set_layer(v, l, on); }
static void cv_set_background(const CvlTable *t, CadaclysmView *v, const float *rgb) { t->set_background(v, rgb); }
static bool cv_set_lighting(const CvlTable *t, CadaclysmView *v, uint32_t l) { return t->set_lighting(v, l); }
static uint32_t cv_lighting(const CvlTable *t, CadaclysmView *v) { return t->lighting(v); }
static bool cv_set_occluded_style(const CvlTable *t, CadaclysmView *v, const CadaclysmViewOccludedStyle *s) { return t->set_occluded_style(v, s); }
static bool cv_occluded_style(const CvlTable *t, CadaclysmView *v, CadaclysmViewOccludedStyle *s) { return t->occluded_style(v, s); }
static bool cv_set_lod(const CvlTable *t, CadaclysmView *v, const CadaclysmViewLod *l) { return t->set_lod(v, l); }
static uint32_t cv_wake_ms(const CvlTable *t, CadaclysmView *v) { return t->wake_ms(v); }
static bool cv_set_node_visible(const CvlTable *t, CadaclysmView *v, uint32_t i, uint32_t n, bool on) { return t->set_node_visible(v, i, n, on); }
static bool cv_set_node_color(const CvlTable *t, CadaclysmView *v, uint32_t i, uint32_t n, const float *c) { return t->set_node_color(v, i, n, c); }
static bool cv_set_node_highlight(const CvlTable *t, CadaclysmView *v, uint32_t i, uint32_t n, const float *c) { return t->set_node_highlight(v, i, n, c); }
static bool cv_set_viewports(const CvlTable *t, CadaclysmView *v, const CadaclysmViewViewport *p, uint32_t n) { return t->set_viewports(v, p, n); }
static bool cv_frame_node(const CvlTable *t, CadaclysmView *v, uint32_t i, uint32_t n) { return t->frame_node(v, i, n); }
static void cv_set_double_click_frames(const CvlTable *t, CadaclysmView *v, bool on) { t->set_double_click_frames(v, on); }
static bool cv_focus(const CvlTable *t, CadaclysmView *v, const float *p) { return t->focus(v, p); }
static uint32_t cv_navigation(const CvlTable *t, CadaclysmView *v) { return t->navigation(v); }
static bool cv_pick_result(const CvlTable *t, CadaclysmView *v, CadaclysmViewPick *p) { return t->pick_result(v, p); }
static void cv_look(const CvlTable *t, CadaclysmView *v, float dx, float dy) { t->look(v, dx, dy); }
static void cv_dolly(const CvlTable *t, CadaclysmView *v, float r) { t->dolly(v, r); }
static uint32_t cv_input(const CvlTable *t, CadaclysmView *v, const CadaclysmViewEvent *e) { return t->input(v, e); }
static uint32_t cv_show_mesh(const CvlTable *t, CadaclysmView *v, const CadaclysmViewMesh *m) { return t->show_mesh(v, m); }
static uint32_t cv_show_lines(const CvlTable *t, CadaclysmView *v, const float *s, uint32_t n, const float *rgb) { return t->show_lines(v, s, n, rgb); }
static uint32_t cv_show_points(const CvlTable *t, CadaclysmView *v, const float *p, uint32_t n, const float *rgb, float size_px) { return t->show_points(v, p, n, rgb, size_px); }
static uint32_t cv_show_machining(const CvlTable *t, CadaclysmView *v, const CadaclysmViewMachining *m) { return t->show_machining(v, m); }
static bool cv_machining_seek(const CvlTable *t, CadaclysmView *v, uint32_t i, uint32_t to) { return t->machining_seek(v, i, to); }
static bool cv_machining_colour_by(const CvlTable *t, CadaclysmView *v, uint32_t i, uint32_t m) { return t->machining_colour_by(v, i, m); }
static bool cv_machining_overlays(const CvlTable *t, CadaclysmView *v, uint32_t i, bool p, bool tool) { return t->machining_overlays(v, i, p, tool); }
static bool cv_machining_info(const CvlTable *t, CadaclysmView *v, uint32_t i, CadaclysmViewMachiningInfo *o) { return t->machining_info(v, i, o); }
static bool cv_machining_heights(const CvlTable *t, CadaclysmView *v, uint32_t i, float *z, size_t n) { return t->machining_heights(v, i, z, n); }
static bool cv_timeline_play(const CvlTable *t, CadaclysmView *v, double s) { return t->timeline_play(v, s); }
static bool cv_timeline_pause(const CvlTable *t, CadaclysmView *v) { return t->timeline_pause(v); }
static bool cv_timeline_seek(const CvlTable *t, CadaclysmView *v, double s) { return t->timeline_seek(v, s); }
static bool cv_timeline_set_loop(const CvlTable *t, CadaclysmView *v, bool on) { return t->timeline_set_loop(v, on); }
static double cv_timeline_time(const CvlTable *t, CadaclysmView *v) { return t->timeline_time(v); }
static double cv_timeline_duration(const CvlTable *t, CadaclysmView *v) { return t->timeline_duration(v); }
static bool cv_timeline_playing(const CvlTable *t, CadaclysmView *v) { return t->timeline_playing(v); }
static size_t cv_timeline_status(const CvlTable *t, CadaclysmView *v, char *s, size_t n) { return t->timeline_status(v, s, n); }
static uint32_t cv_show_curves(const CvlTable *t, CadaclysmView *v, const float *b, uint32_t n, const float *rgb) { return t->show_curves(v, b, n, rgb); }
static uint32_t cv_show_image(const CvlTable *t, CadaclysmView *v, const CadaclysmViewImage *i) { return t->show_image(v, i); }
static bool cv_set_colour(const CvlTable *t, CadaclysmView *v, uint32_t i, const float *rgb) { return t->set_colour(v, i, rgb); }
static bool cv_set_xray(const CvlTable *t, CadaclysmView *v, uint32_t i, bool on) { return t->set_xray(v, i, on); }
static bool cv_set_occluded(const CvlTable *t, CadaclysmView *v, uint32_t i, uint32_t m) { return t->set_occluded(v, i, m); }
static bool cv_set_finish(const CvlTable *t, CadaclysmView *v, uint32_t i, uint32_t f) { return t->set_finish(v, i, f); }
static bool cv_set_face_colours(const CvlTable *t, CadaclysmView *v, uint32_t i, const uint32_t *f, const float *c, uint32_t n) { return t->set_face_colours(v, i, f, c, n); }
static bool cv_set_placement(const CvlTable *t, CadaclysmView *v, uint32_t i, const double *m) { return t->set_placement(v, i, m); }
static bool cv_set_node_transforms(const CvlTable *t, CadaclysmView *v, uint32_t i, const double *m, uint32_t n) { return t->set_node_transforms(v, i, m, n); }
static uint32_t cv_show_solid(const CvlTable *t, CadaclysmView *v, void *solid, double tol, const float *rgb) { return t->show_solid(v, (const CadaclysmBlacksmithSolid *)solid, tol, rgb); }
static uint32_t cv_show_solid_faces(const CvlTable *t, CadaclysmView *v, void *solid, double tol, const float *rgb, uint32_t material, float opacity, const uint32_t *faces, uint32_t count) { return t->show_solid_faces(v, (const CadaclysmBlacksmithSolid *)solid, tol, rgb, material, opacity, faces, count); }
static uint32_t cv_load_font(const CvlTable *t, const uint8_t *bytes, size_t n) { return t->load_font(bytes, n); }
static uint32_t cv_show_text(const CvlTable *t, CadaclysmView *v, const CadaclysmViewText *text) { return t->show_text(v, text); }
static bool cv_set_text(const CvlTable *t, CadaclysmView *v, uint32_t i, const char *text) { return t->set_text(v, i, text); }
static bool cv_set_snap(const CvlTable *t, CadaclysmView *v, const CadaclysmViewSnapSettings *s) { return t->set_snap(v, s); }
static bool cv_snap_result(const CvlTable *t, CadaclysmView *v, CadaclysmViewSnap *s) { return t->snap_result(v, s); }
static void cv_clear_snap(const CvlTable *t, CadaclysmView *v) { t->clear_snap(v); }
static bool cv_set_work_plane(const CvlTable *t, CadaclysmView *v, const double *o, const double *x, const double *n, double step) { return t->set_work_plane(v, o, x, n, step); }
static bool cv_clear_work_plane(const CvlTable *t, CadaclysmView *v) { return t->clear_work_plane(v); }
static int cv_draw_object(const CvlTable *t, int interactive, const char *default_view, void *solid, double tol,
                          void *scene, const double *transforms, uint32_t transform_count, const uint32_t *hide,
                          uint32_t hide_count, uint32_t node, const CvlShow *o, CadaclysmViewCamera *c,
                          CadaclysmViewPick *p, char *err, size_t n) {
    return cvl_draw_object(t, interactive, default_view, (const CadaclysmBlacksmithSolid *)solid, tol,
                           (const CadaclysmScene *)scene, transforms, transform_count, hide, hide_count, node, o, c,
                           p, err, n);
}

// The package's tests swap a library's calls for stand-ins through this (cgo is not
// allowed in a _test.go file): 1 when `name` is a call of the table.
static int cv_rig(CvlTable *t, const char *name, void *fn) {
#define CV_RIG(n_, r, p)                       \
    if (strcmp(name, #n_) == 0) {              \
        memcpy(&t->n_, &fn, sizeof fn);        \
        return 1;                              \
    }
    CVL_CALLS(CV_RIG)
#undef CV_RIG
    return 0;
}
*/
import "C"

import (
	"errors"
	"fmt"
	"image"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
	"unsafe"
)

// Error is what a view library refused, in its own words, or the package's own refusal.
// A closed view's refusal unwraps to ErrClosed or ErrWindowClosed.
type Error struct {
	Message string
	err     error
}

func (e *Error) Error() string { return e.Message }

// Unwrap is ErrClosed or ErrWindowClosed for a closed view's refusal, else nil.
func (e *Error) Unwrap() error { return e.err }

// ErrClosed is what every call on a closed View (or an Item of one) wraps:
// "<cadaclysm_view_call>: the view is closed".
var ErrClosed = errors.New("the view is closed")

// ErrWindowClosed is what every call but Close wraps once the view's own window was
// closed -- its close button or the end of Run (seen by Pump), or Escape through Input:
// "<cadaclysm_view_call>: the window is closed".
var ErrWindowClosed = errors.New("the window is closed")

func refused(message string) error { return &Error{Message: message} }

// CadaclysmViewLod is three u32, 12 bytes: either bound goes negative, and the package fails
// to compile, if the header's struct ever differs.
var _ [unsafe.Sizeof(C.CadaclysmViewLod{}) - 12]struct{}
var _ [12 - unsafe.Sizeof(C.CadaclysmViewLod{})]struct{}

// lodLayout is the struct's size and its two later fields' offsets, for the layout test.
func lodLayout() (size, minTriangles, motion uintptr) {
	var l C.CadaclysmViewLod
	return unsafe.Sizeof(l), unsafe.Offsetof(l.min_triangles), unsafe.Offsetof(l.motion)
}

// CadaclysmViewSnapSettings is 16 bytes and CadaclysmViewSnap 88 (1.22): the package fails to
// compile if the header's structs ever differ.
var _ [unsafe.Sizeof(C.CadaclysmViewSnapSettings{}) - 16]struct{}
var _ [16 - unsafe.Sizeof(C.CadaclysmViewSnapSettings{})]struct{}
var _ [unsafe.Sizeof(C.CadaclysmViewSnap{}) - 88]struct{}
var _ [88 - unsafe.Sizeof(C.CadaclysmViewSnap{})]struct{}

// snapLayout is the snap answer's size and its fields' offsets, in the header's order, for
// the layout test.
func snapLayout() [12]uintptr {
	var s C.CadaclysmViewSnap
	return [12]uintptr{unsafe.Sizeof(s), unsafe.Offsetof(s.kind), unsafe.Offsetof(s.point), unsafe.Offsetof(s.item),
		unsafe.Offsetof(s.node), unsafe.Offsetof(s.face), unsafe.Offsetof(s.edge), unsafe.Offsetof(s.tangent),
		unsafe.Offsetof(s.axis), unsafe.Offsetof(s.radius), unsafe.Offsetof(s.distance_px), unsafe.Offsetof(s.clicks)}
}

// noDisplay is appended to a create failure that says "no display" (cvl_create_failed).
var noDisplay = C.CString(" -- draw without a display with view.Offscreen, or the terminal (view.UseTerminal())")

// Stand-ins for an empty array: a pointer the library reads nothing through, with count 0.
// NULL means "none" to the library (Python passes a non-NULL empty array).
var (
	standInF32 [1]C.float
	standInU32 [1]C.uint32_t
	standInF64 [1]C.double
	standInU8  [1]C.uint8_t
)

// cadaclysm_view.h's numbers, for the calls that take them.
const (
	WindowWin32   = C.CADACLYSM_VIEW_WINDOW_WIN32 // Window.Kind
	WindowXlib    = C.CADACLYSM_VIEW_WINDOW_XLIB
	WindowXcb     = C.CADACLYSM_VIEW_WINDOW_XCB
	WindowWayland = C.CADACLYSM_VIEW_WINDOW_WAYLAND
	WindowAppKit  = C.CADACLYSM_VIEW_WINDOW_APPKIT
	WindowKms     = C.CADACLYSM_VIEW_WINDOW_KMS // 1.17: Window.WindowId the connector, Window.Display an *C.int DRM fd or nil

	LayerSurfaces  = C.CADACLYSM_VIEW_LAYER_SURFACES // View.Layer
	LayerEdges     = C.CADACLYSM_VIEW_LAYER_EDGES
	LayerCurves    = C.CADACLYSM_VIEW_LAYER_CURVES
	LayerIsocurves = C.CADACLYSM_VIEW_LAYER_ISOCURVES
	LayerGrid      = C.CADACLYSM_VIEW_LAYER_GRID
	LayerText      = C.CADACLYSM_VIEW_LAYER_TEXT // every text item, labels and world text

	GridNone  = C.CADACLYSM_VIEW_GRID_NONE // Viewport.Grid
	GridTop   = C.CADACLYSM_VIEW_GRID_TOP
	GridFront = C.CADACLYSM_VIEW_GRID_FRONT
	GridRight = C.CADACLYSM_VIEW_GRID_RIGHT

	EventDown   = C.CADACLYSM_VIEW_EVENT_DOWN // Event.Kind
	EventMove   = C.CADACLYSM_VIEW_EVENT_MOVE
	EventUp     = C.CADACLYSM_VIEW_EVENT_UP
	EventCancel = C.CADACLYSM_VIEW_EVENT_CANCEL
	EventWheel  = C.CADACLYSM_VIEW_EVENT_WHEEL
	EventKey    = C.CADACLYSM_VIEW_EVENT_KEY

	PointerMouse = C.CADACLYSM_VIEW_POINTER_MOUSE // Event.Pointer
	PointerTouch = C.CADACLYSM_VIEW_POINTER_TOUCH
	PointerPen   = C.CADACLYSM_VIEW_POINTER_PEN

	ButtonLeft   = C.CADACLYSM_VIEW_BUTTON_LEFT // Event.Button
	ButtonMiddle = C.CADACLYSM_VIEW_BUTTON_MIDDLE
	ButtonRight  = C.CADACLYSM_VIEW_BUTTON_RIGHT

	InputClose  = C.CADACLYSM_VIEW_INPUT_CLOSE // Input's bits
	InputPicked = C.CADACLYSM_VIEW_INPUT_PICKED

	// Pump's answers of the library, for a test's stand-in.
	stateOpen   = C.CADACLYSM_VIEW_OPEN
	stateClosed = C.CADACLYSM_VIEW_CLOSED
)

// Colour is a colour argument, as Python's Colour: three numbers in 0..1 -- [3]float32 or
// *[3]float32 -- four where a call takes an alpha ([4]float32, *[4]float32; a call that
// takes none reads the first three), a []float32 of three or four, or text: a string,
// "#rgb", "#rrggbb" (the "#" optional) or one of the 148 CSS colour names, any case, read
// by the view library's own cadaclysm_view_parse_colour, so the forms are those of every
// wrapper. Text (or three numbers) where an alpha is taken means an alpha of 1. nil, or a
// nil pointer, is "none" where a call takes none (ShowSolid's rgb: the solid's own paint;
// NodeColour: the node's own colour) and refused where it does not. Text the library
// refuses is refused with its message; any other type is refused.
type Colour interface{}

// Solid is a kernel solid shown by handle: *blacksmith.Solid.
type Solid interface{ SolidHandle() unsafe.Pointer }

// Scene is a reader scene shown by handle: *cadaclysm.Scene.
type Scene interface{ SceneHandle() unsafe.Pointer }

// ---- the library ---------------------------------------------------------------------

// Library is a loaded view library. Never unloaded.
type Library struct {
	// Name is cadaclysm_view_name(): "cadaclysm-view <version>", "cadaclysm-terminal <version>", ...
	Name string
	// Path is the file it was loaded from.
	Path string
	t    *C.CvlTable
}

// IsTerminal is whether this is the terminal library.
func (l *Library) IsTerminal() bool { return C.cvl_is_terminal(l.t) != 0 }

// IsWgpu is whether this is the GPU window, cadaclysm_view on wgpu: the one whose Show runs
// a window. Any other library prints a still for Show.
func (l *Library) IsWgpu() bool { return C.cvl_is_wgpu(l.t) != 0 }

// rigged is a copy of l whose calls named in calls are replaced by the C functions given:
// the seam the package's own tests swap a library's answers through.
func (l *Library) rigged(calls map[string]unsafe.Pointer) (*Library, error) {
	t := C.cv_table()
	*t = *l.t
	for name, fn := range calls {
		cn := C.CString(name)
		ok := C.cv_rig(t, cn, fn)
		C.free(unsafe.Pointer(cn))
		if ok == 0 {
			C.free(unsafe.Pointer(t))
			return nil, refused(name + ": not a call of cadaclysm_view.h")
		}
	}
	return &Library{Name: l.Name, Path: l.Path, t: t}, nil
}

var (
	mu      sync.Mutex
	current *Library
	loaded  = map[string]*Library{}
)

// searchDirs are this package's build-time neighbours: an SDK checkout's lib/ and the
// repository's target/release.
func searchDirs() []string {
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		return nil
	}
	here := filepath.Dir(file)
	return []string{filepath.Join(here, "..", "..", "lib"), filepath.Join(here, "..", "..", "..", "..", "..", "target", "release")}
}

// cStrings is dirs as a C array, and what frees it.
func cStrings(dirs []string) (**C.char, func()) {
	if len(dirs) == 0 {
		return nil, func() {}
	}
	array := (**C.char)(C.malloc(C.size_t(len(dirs)) * C.size_t(unsafe.Sizeof((*C.char)(nil)))))
	items := unsafe.Slice(array, len(dirs))
	for i, d := range dirs {
		items[i] = C.CString(d)
	}
	return array, func() {
		for _, s := range items {
			C.free(unsafe.Pointer(s))
		}
		C.free(unsafe.Pointer(array))
	}
}

func find(stem, variable, what string, dirs []string) (string, error) {
	cs, cv, cw := C.CString(stem), C.CString(variable), C.CString(what)
	defer C.free(unsafe.Pointer(cs))
	defer C.free(unsafe.Pointer(cv))
	defer C.free(unsafe.Pointer(cw))
	array, free := cStrings(dirs)
	defer free()
	var out [C.CVL_PATH]C.char
	var msg [C.CVL_ERROR]C.char
	if C.cvl_find(cs, cv, cw, array, C.size_t(len(dirs)), &out[0], C.CVL_PATH, &msg[0], C.CVL_ERROR) == 0 {
		return "", refused(C.GoString(&msg[0]))
	}
	return C.GoString(&out[0]), nil
}

// checkABI is cvl_check_abi, which every open runs on the library's answer first: nil for
// 1.22 or a later 1.x, else the refusal naming `path`.
func checkABI(version uint32, path string) error {
	cp := C.CString(path)
	defer C.free(unsafe.Pointer(cp))
	var msg [C.CVL_ERROR]C.char
	if C.cvl_check_abi(C.uint32_t(version), cp, &msg[0], C.CVL_ERROR) == 0 {
		return refused(C.GoString(&msg[0]))
	}
	return nil
}

// choose opens `which` ("terminal", "wgpu", a path; "" for the default).
func choose(which string, remember bool) (*Library, error) {
	mu.Lock()
	defer mu.Unlock()
	if which == "" && current != nil {
		return current, nil
	}
	t := C.cv_table()
	var msg [C.CVL_ERROR]C.char
	dirs := searchDirs()
	array, free := cStrings(dirs)
	var ok C.int
	if which == "" {
		ok = C.cvl_default(t, array, C.size_t(len(dirs)), &msg[0], C.CVL_ERROR)
	} else {
		cw := C.CString(which)
		ok = C.cvl_use(t, cw, array, C.size_t(len(dirs)), &msg[0], C.CVL_ERROR)
		C.free(unsafe.Pointer(cw))
	}
	free()
	if ok == 0 {
		C.free(unsafe.Pointer(t))
		return nil, refused(C.GoString(&msg[0]))
	}
	path := C.GoString(&t.path[0])
	lib, seen := loaded[path]
	if seen {
		C.free(unsafe.Pointer(t))
	} else {
		lib = &Library{Name: C.GoString(&t.label[0]), Path: path, t: t}
		loaded[path] = lib
	}
	if remember || current == nil {
		current = lib
	}
	return lib, nil
}

// UseTerminal draws with the bundled terminal library from now on.
func UseTerminal() (*Library, error) { return choose("terminal", true) }

// UseWgpu draws with the GPU window, cadaclysm_view on wgpu, from now on.
func UseWgpu() (*Library, error) { return choose("wgpu", true) }

// Use draws with "terminal", "wgpu" or the view library at a path from now on.
func Use(which string) (*Library, error) {
	if which == "" {
		return nil, refused(`use: "terminal", "wgpu" or a path`)
	}
	return choose(which, true)
}

// Current is the library in use: the last Use*; else CADACLYSM_VIEW ("terminal", "wgpu" or
// a file); else the terminal. A failure is not remembered.
func Current() (*Library, error) { return choose("", false) }

// ---- views -----------------------------------------------------------------------------

// Options is how a View is made. Zero values are the defaults.
type Options struct {
	Title         string
	Width, Height uint32 // the own window's, logical pixels; 0: the library's
	Surfaces      string // "exact" (default) or "triangles"
	Up            string // "z" (default) or "y"
}

// Window is a host's native window: Kind is a CADACLYSM_VIEW_WINDOW_* value, Width and
// Height its client size in physical pixels.
type Window struct {
	Kind          uint32
	Handle        unsafe.Pointer
	ID            uint64
	Display       unsafe.Pointer
	Width, Height uint32
}

// View is one view: an own window, an offscreen one, or one in a host's window.
type View struct {
	lib    *Library
	handle *C.CadaclysmView
	thread uint64 // the OS thread that made it
	own    bool   // a window of its own
	pumped bool   // a window of its own on the wgpu library: Pump reaches it
	closed bool   // that window was closed (its button, Escape, the end of Run)
	yUp    bool
	drawn  C.int          // drawn once: Pick draws a never-drawn view first
	owners map[uint32]any // what each item keeps reachable
}

// Item is one shown thing of a View.
type Item struct {
	view *View
	id   uint32
}

// Pick is what is under a pixel: Item 0 for nothing. Clicks is 2 for a double click's
// pick, else 1; Point is where the ray met the model, in the coordinates the items were
// shown in, when HasPoint -- false (and Point zero) where the library read no depth (no
// hit, a machining stock, the terminal library). Every field is a value, so two picks
// compare with ==.
type Pick struct {
	Item, Node, Face, Clicks uint32
	HasPoint                 bool
	Point                    [3]float32
}

// pickOf is a library's pick answer as a Pick.
func pickOf(p *C.CadaclysmViewPick) Pick {
	out := Pick{Item: uint32(p.item), Node: uint32(p.node), Face: uint32(p.face), Clicks: uint32(p.clicks)}
	if p.has_point != 0 {
		out.HasPoint = true
		out.Point = [3]float32{float32(p.point[0]), float32(p.point[1]), float32(p.point[2])}
	}
	return out
}

// SnapKind is a set of CADACLYSM_VIEW_SNAP_* bits: what SetSnap lets a snap land on, and,
// one bit alone, what a Snap landed on (0: nothing).
type SnapKind uint32

const (
	SnapVertex   SnapKind = C.CADACLYSM_VIEW_SNAP_VERTEX
	SnapMidpoint SnapKind = C.CADACLYSM_VIEW_SNAP_MIDPOINT
	SnapCentre   SnapKind = C.CADACLYSM_VIEW_SNAP_CENTRE // a circular edge's centre
	SnapQuadrant SnapKind = C.CADACLYSM_VIEW_SNAP_QUADRANT
	SnapEdge     SnapKind = C.CADACLYSM_VIEW_SNAP_EDGE
	SnapFace     SnapKind = C.CADACLYSM_VIEW_SNAP_FACE
	SnapGrid     SnapKind = C.CADACLYSM_VIEW_SNAP_GRID
	SnapPlane    SnapKind = C.CADACLYSM_VIEW_SNAP_PLANE
	SnapAll      SnapKind = C.CADACLYSM_VIEW_SNAP_ALL
)

var snapNames = [...]struct {
	kind SnapKind
	name string
}{{SnapVertex, "vertex"}, {SnapMidpoint, "midpoint"}, {SnapCentre, "centre"}, {SnapQuadrant, "quadrant"},
	{SnapEdge, "edge"}, {SnapFace, "face"}, {SnapGrid, "grid"}, {SnapPlane, "plane"}}

// String is the kinds' names, as Python's ("vertex", "midpoint", "centre", "quadrant",
// "edge", "face", "grid", "plane"), joined by "|"; "" for none.
func (k SnapKind) String() string {
	var names []string
	for _, n := range snapNames {
		if k&n.kind != 0 {
			names = append(names, n.name)
		}
	}
	return strings.Join(names, "|")
}

// Snap is what a snap found, as Python's Snap: Kind (0 where nothing in the kinds SetSnap
// chose lay within the aperture, or snapping is off), Point in world coordinates, the Item,
// Node and Face it lies on, its Edge when HasEdge (false for a face, grid or plane snap), the
// edge's unit Tangent there, a circular edge's Axis and Radius (zeros otherwise), DistancePx
// from the cursor, and Clicks: 0 for View.Snap and a hover, 1 for a click's snap, 2 for a
// double click's. Every field is a value, so two snaps compare with ==.
type Snap struct {
	Kind             SnapKind
	Point            [3]float64
	Item, Node, Face uint32
	Edge             uint32
	HasEdge          bool
	Tangent, Axis    [3]float32
	Radius           float64
	DistancePx       float32
	Clicks           uint32
}

// snapOf is a library's snap answer as a Snap.
func snapOf(s *C.CadaclysmViewSnap) Snap {
	out := Snap{Kind: SnapKind(s.kind), Item: uint32(s.item), Node: uint32(s.node), Face: uint32(s.face),
		Radius: float64(s.radius), DistancePx: float32(s.distance_px), Clicks: uint32(s.clicks)}
	if uint32(s.edge) != 0xFFFFFFFF {
		out.Edge, out.HasEdge = uint32(s.edge), true
	}
	for i := 0; i < 3; i++ {
		out.Point[i] = float64(s.point[i])
		out.Tangent[i] = float32(s.tangent[i])
		out.Axis[i] = float32(s.axis[i])
	}
	return out
}

// Navigation is how a left drag moves the camera: NavigationOrbit (about the target) or
// NavigationFly (the view turns about the eye).
type Navigation uint32

const (
	NavigationOrbit Navigation = C.CADACLYSM_VIEW_NAVIGATION_ORBIT
	NavigationFly   Navigation = C.CADACLYSM_VIEW_NAVIGATION_FLY
)

// String is "orbit" or "fly", as Python's View.navigation.
func (n Navigation) String() string {
	if n == NavigationFly {
		return "fly"
	}
	return "orbit"
}

// Camera is where Run or View left the camera (Azimuth and Elevation as ShowOptions takes
// them), and what was last clicked (nil: nothing).
type Camera struct {
	Eye, Target, Up    [3]float32
	Orthographic       bool
	Azimuth, Elevation float64
	Pick               *Pick
}

// The views of every thread, alive (not yet Closed). views and each view's handle, closed
// and owners are read across goroutines (Pump's count, Release) under viewsMu; only the
// view's own goroutine writes them, under it too.
var (
	viewsMu sync.Mutex
	views   []*View
)

func thread() uint64 { return uint64(C.cv_thread()) }

func create(w *C.CadaclysmViewWindow, o *Options, width, height, offscreen uint32) (*View, error) {
	if o == nil {
		o = &Options{}
	}
	var surfaces, yUp C.uint32_t
	switch o.Surfaces {
	case "", "exact":
	case "triangles":
		surfaces = C.CADACLYSM_VIEW_SURFACES_TRIANGLES
	default:
		return nil, refused(fmt.Sprintf("surfaces '%s': 'exact' or 'triangles'", o.Surfaces))
	}
	switch o.Up {
	case "", "z":
	case "y":
		yUp = 1
	default:
		return nil, refused(fmt.Sprintf("up '%s': 'y' or 'z'", o.Up))
	}
	lib, err := Current()
	if err != nil {
		return nil, err
	}
	var title *C.char
	if o.Title != "" {
		title = C.CString(o.Title)
		defer C.free(unsafe.Pointer(title))
	}
	runtime.LockOSThread() // until Close: the view's calls all come from this thread
	h := C.cvl_create(lib.t, w, title, C.uint32_t(width), C.uint32_t(height), surfaces, yUp, C.uint32_t(offscreen))
	if h == nil {
		var msg [C.CVL_ERROR]C.char
		C.cvl_create_failed(lib.t, noDisplay, &msg[0], C.CVL_ERROR)
		runtime.UnlockOSThread()
		return nil, refused(C.GoString(&msg[0]))
	}
	v := &View{lib: lib, handle: h, thread: thread(), own: w == nil && offscreen == 0, yUp: yUp == 1,
		owners: map[uint32]any{}}
	v.pumped = v.own && lib.IsWgpu()
	viewsMu.Lock()
	views = append(views, v)
	viewsMu.Unlock()
	return v, nil
}

// New opens a view in a window of its own (the terminal: drawn in the terminal).
func New(o *Options) (*View, error) {
	var w, h uint32
	if o != nil {
		w, h = o.Width, o.Height
	}
	return create(nil, o, w, h, 0)
}

// Offscreen is a view with no window and no display: a GPU adapter is enough. 0 x 0 is
// 1280 x 800. The terminal library refuses it.
func Offscreen(width, height uint32, o *Options) (*View, error) {
	if width == 0 {
		width = 1280
	}
	if height == 0 {
		height = 800
	}
	return create(nil, o, width, height, 1)
}

// InWindow draws in a host's native window; the host forwards Input, Resize and Draw.
func InWindow(win Window, o *Options) (*View, error) {
	if win.Width == 0 || win.Height == 0 {
		return nil, refused("a host's window needs a width and a height: its client size in physical pixels")
	}
	raw := C.CadaclysmViewWindow{}
	raw.size = C.uint32_t(unsafe.Sizeof(raw))
	raw.kind = C.uint32_t(win.Kind)
	raw.window = win.Handle
	raw.window_id = C.uint64_t(win.ID)
	raw.display = win.Display
	raw.width = C.uint32_t(win.Width)
	raw.height = C.uint32_t(win.Height)
	return create(&raw, o, win.Width, win.Height, 0)
}

// Library is the view library this view draws with.
func (v *View) Library() *Library { return v.lib }

// Closed is whether the view was closed (Close) or its window was (Run ended, Escape, its
// close button).
func (v *View) Closed() bool {
	viewsMu.Lock()
	defer viewsMu.Unlock()
	return v == nil || v.handle == nil || v.closed
}

// Close destroys the view and its window, then lets go of what its items kept. Idempotent.
// Refused from another goroutine than the one that made the view (see the package doc),
// which then changes nothing.
func (v *View) Close() error {
	if v == nil {
		return nil
	}
	viewsMu.Lock()
	h, owners := v.handle, v.owners
	viewsMu.Unlock()
	if h == nil {
		return nil
	}
	if !v.mine() {
		return refused("close: a view belongs to the thread that made it")
	}
	viewsMu.Lock()
	v.handle, v.owners = nil, nil
	for i, w := range views {
		if w == v {
			views = append(views[:i], views[i+1:]...)
			break
		}
	}
	viewsMu.Unlock()
	C.cv_destroy(v.lib.t, h) // the C view first, then what its items kept (C11)
	runtime.KeepAlive(owners)
	runtime.UnlockOSThread() // create's lock
	return nil
}

// mine is whether the calling goroutine made v. While v is alive its maker is locked to
// v.thread, and a locked thread runs no other goroutine; the lock here only holds this
// goroutine still for the read, and is undone at once (the maker's own lock nests).
func (v *View) mine() bool {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	return thread() == v.thread
}

// refusal is Python's _call: a closed view, another goroutine's view, a closed window, each
// refused with the C call's name. A closed view is checked first: Close unlocked its maker,
// which may since run on another thread.
func (v *View) refusal(call string) error {
	if v == nil || v.handle == nil {
		return &Error{Message: call + ": " + ErrClosed.Error(), err: ErrClosed}
	}
	if !v.mine() {
		return refused(call + ": a view belongs to the thread that made it")
	}
	if v.closed {
		return &Error{Message: call + ": " + ErrWindowClosed.Error(), err: ErrWindowClosed}
	}
	return nil
}

// failed is the library's own message, or Python's fallback when it left none.
func (v *View) failed() error { return refused(C.GoString(C.cvl_error(v.lib.t))) }

// said is whether the library left a message: a void call's refusal (Python's _void).
func (v *View) said() bool { return C.GoString(C.cv_last_error(v.lib.t)) != "" }

func (v *View) markClosed() {
	viewsMu.Lock()
	v.closed = true
	viewsMu.Unlock()
}

func (v *View) ok(call string, f func() C.bool) error {
	if err := v.refusal(call); err != nil {
		return err
	}
	if !bool(f()) {
		return v.failed()
	}
	return nil
}

func (v *View) act(call string, f func()) error {
	if err := v.refusal(call); err != nil {
		return err
	}
	f()
	if v.said() {
		return v.failed()
	}
	return nil
}

func (v *View) add(call string, f func() C.uint32_t, owner any) (*Item, error) {
	if err := v.refusal(call); err != nil {
		return nil, err
	}
	id := f()
	if id == 0 {
		return nil, v.failed()
	}
	if owner != nil {
		viewsMu.Lock()
		v.owners[uint32(id)] = owner
		viewsMu.Unlock()
	}
	return &Item{view: v, id: uint32(id)}, nil
}

func (v *View) forget(id uint32) {
	viewsMu.Lock()
	delete(v.owners, id)
	viewsMu.Unlock()
}

// count is n as the library's u32, or the refusal of more.
func count(n int, what string) (C.uint32_t, error) {
	if uint64(n) > math.MaxUint32 {
		return 0, refused(what + ": " + strconv.Itoa(n) + " is too many for the library")
	}
	return C.uint32_t(n), nil
}

// pixelBytes is width x height RGBA8 in bytes, checked: no product may wrap.
func pixelBytes(width, height uint32, what string) (uint64, error) {
	pixels := uint64(width) * uint64(height) // < 2^64
	if pixels > uint64(math.MaxInt)/4 {
		return 0, refused(fmt.Sprintf("%s: %d x %d pixels is too large", what, width, height))
	}
	return pixels * 4, nil
}

// paint is Python's _colour, as the library takes it: four floats (r, g, b, a; a call that
// reads three reads the first three), or nil for none. Text goes through the library's
// cadaclysm_view_parse_colour (alpha 1) and is refused with its message, else Python's
// "colour '<text>'".
func (l *Library) paint(c Colour) (*[4]C.float, error) {
	var n []float32
	switch x := c.(type) {
	case nil:
		return nil, nil
	case string:
		text := C.CString(x)
		defer C.free(unsafe.Pointer(text))
		var rgb [3]C.float
		if !bool(C.cv_parse_colour(l.t, text, &rgb[0])) {
			if said := C.GoString(C.cv_last_error(l.t)); said != "" {
				return nil, refused(said)
			}
			return nil, refused("colour '" + x + "'")
		}
		return &[4]C.float{rgb[0], rgb[1], rgb[2], 1}, nil
	case [3]float32:
		n = x[:]
	case *[3]float32:
		if x == nil {
			return nil, nil
		}
		n = x[:]
	case [4]float32:
		n = x[:]
	case *[4]float32:
		if x == nil {
			return nil, nil
		}
		n = x[:]
	case []float32:
		if len(x) != 3 && len(x) != 4 {
			return nil, refused(fmt.Sprintf("colour: 3 or 4 numbers, not %d", len(x)))
		}
		n = x
	default:
		return nil, refused(fmt.Sprintf("colour %v: numbers ([3]float32, [4]float32) or text, not a %T", c, c))
	}
	out := [4]C.float{0, 0, 0, 1}
	for k, f := range n {
		out[k] = C.float(f)
	}
	return &out, nil
}

// paintFor is c for `call` on v: v's refusal first (closed, another goroutine's), then the
// colour's; `required` refuses nil.
func (v *View) paintFor(call string, c Colour, required bool) (*C.float, error) {
	if err := v.refusal(call); err != nil {
		return nil, err
	}
	p, err := v.lib.paint(c)
	if err != nil {
		return nil, err
	}
	if p == nil {
		if required {
			return nil, refused("colour: nil is no colour (numbers or text)")
		}
		return nil, nil
	}
	return &p[0], nil
}

// floats is s's first element, or the stand-in for an empty s.
func floats(s []float32) *C.float {
	if len(s) == 0 {
		return &standInF32[0]
	}
	return (*C.float)(unsafe.Pointer(&s[0]))
}

func uint32s(s []uint32) *C.uint32_t {
	if len(s) == 0 {
		return &standInU32[0]
	}
	return (*C.uint32_t)(unsafe.Pointer(&s[0]))
}

// SolidOptions is how ShowSolid draws a solid (view ABI 1.21). Material: "default",
// "plastic", "metal", "matte", "paint", "brushed" or "glass" ("" the default). Opacity: 0..1
// (nil: 1, opaque). Faces: the solid's face numbers to show alone, with no edges -- a trim's
// ghost (nil: every face). The item's faces are numbered as the solid numbers them.
type SolidOptions struct {
	Material string
	Opacity  *float32
	Faces    []uint32
}

// ShowSolid shows a kernel solid by handle, exact where its surfaces draw, triangles at
// tolerance otherwise; rgb (a Colour) nil keeps its paint. The item keeps the solid
// reachable. An options value (1.21) gives a material, an opacity and the faces to show
// alone; without one, or with a zero one, the 1.4 call.
func (v *View) ShowSolid(s Solid, tolerance float64, rgb Colour, options ...SolidOptions) (*Item, error) {
	h := s.SolidHandle()
	if h == nil {
		return nil, refused("solid: closed")
	}
	defer runtime.KeepAlive(s)
	if len(options) > 1 {
		return nil, refused("ShowSolid: one SolidOptions at most")
	}
	var o SolidOptions
	if len(options) == 1 {
		o = options[0]
	}
	material := C.uint32_t(C.CADACLYSM_VIEW_MATERIAL_DEFAULT)
	if o.Material != "" {
		m, ok := map[string]C.uint32_t{"default": C.CADACLYSM_VIEW_MATERIAL_DEFAULT, "plastic": C.CADACLYSM_VIEW_MATERIAL_PLASTIC,
			"metal": C.CADACLYSM_VIEW_MATERIAL_METAL, "matte": C.CADACLYSM_VIEW_MATERIAL_MATTE, "paint": C.CADACLYSM_VIEW_MATERIAL_PAINT,
			"brushed": C.CADACLYSM_VIEW_MATERIAL_BRUSHED, "glass": C.CADACLYSM_VIEW_MATERIAL_GLASS}[o.Material]
		if !ok {
			return nil, fmt.Errorf("material: %q is not \"default\", \"plastic\", \"metal\", \"matte\", \"paint\", \"brushed\" or \"glass\"", o.Material)
		}
		material = m
	}
	if o.Material == "" && o.Opacity == nil && o.Faces == nil {
		c, err := v.paintFor("cadaclysm_view_show_solid", rgb, false)
		if err != nil {
			return nil, err
		}
		return v.add("cadaclysm_view_show_solid", func() C.uint32_t {
			return C.cv_show_solid(v.lib.t, v.handle, h, C.double(tolerance), c)
		}, s)
	}
	c, err := v.paintFor("cadaclysm_view_show_solid_faces", rgb, false)
	if err != nil {
		return nil, err
	}
	opacity := C.float(1)
	if o.Opacity != nil {
		opacity = C.float(*o.Opacity)
	}
	var faces *C.uint32_t
	if o.Faces != nil {
		faces = uint32s(o.Faces)
	}
	defer runtime.KeepAlive(o.Faces)
	return v.add("cadaclysm_view_show_solid_faces", func() C.uint32_t {
		return C.cv_show_solid_faces(v.lib.t, v.handle, h, C.double(tolerance), c, material, opacity, faces, C.uint32_t(len(o.Faces)))
	}, s)
}

// ShowScene shows a reader scene by handle. The item keeps the scene reachable;
// Scene.Close removes it first.
func (v *View) ShowScene(s Scene) (*Item, error) {
	h := s.SceneHandle()
	if h == nil {
		if p, ok := s.(interface{ Path() string }); ok {
			return nil, refused(filepath.Base(p.Path()) + ": the scene is closed")
		}
		return nil, refused("the scene is closed")
	}
	defer runtime.KeepAlive(s)
	return v.add("cadaclysm_view_show", func() C.uint32_t { return C.cv_show(v.lib.t, v.handle, h) }, s)
}

// Mesh is plain triangles: Positions three floats a point, Indices three a triangle,
// Normals (empty: none) one a position, Edges (empty: none) two points a segment, RGB a
// Colour (nil: the library's default). Copied before ShowMesh returns.
type Mesh struct {
	Positions, Normals []float32
	Indices            []uint32
	Edges              []float32
	RGB                Colour
}

// ShowMesh shows plain triangles.
func (v *View) ShowMesh(m Mesh) (*Item, error) {
	if len(m.Positions)%3 != 0 {
		return nil, refused(fmt.Sprintf("positions is three numbers a point, not %d", len(m.Positions)))
	}
	if len(m.Normals) > 0 && len(m.Normals) != len(m.Positions) {
		return nil, refused(fmt.Sprintf("a mesh has %d positions but %d normals", len(m.Positions)/3, len(m.Normals)/3))
	}
	if len(m.Edges)%6 != 0 {
		return nil, refused(fmt.Sprintf("edges is two points a segment (6 numbers), not %d", len(m.Edges)))
	}
	vertices, err := count(len(m.Positions)/3, "show_mesh positions")
	if err != nil {
		return nil, err
	}
	indices, err := count(len(m.Indices), "show_mesh indices")
	if err != nil {
		return nil, err
	}
	edges, err := count(len(m.Edges)/6, "show_mesh edges")
	if err != nil {
		return nil, err
	}
	rgb, err := v.paintFor("cadaclysm_view_show_mesh", m.RGB, false)
	if err != nil {
		return nil, err
	}
	// The struct is Go memory handed to C: every Go pointer in it is pinned for the call.
	var pin runtime.Pinner
	defer pin.Unpin()
	raw := C.CadaclysmViewMesh{}
	raw.size = C.uint32_t(unsafe.Sizeof(raw))
	raw.positions = floats(m.Positions)
	raw.vertex_count = vertices
	raw.indices = uint32s(m.Indices)
	raw.index_count = indices
	if len(m.Positions) > 0 {
		pin.Pin(&m.Positions[0])
	}
	if len(m.Indices) > 0 {
		pin.Pin(&m.Indices[0])
	}
	if len(m.Normals) > 0 {
		pin.Pin(&m.Normals[0])
		raw.normals = (*C.float)(unsafe.Pointer(&m.Normals[0]))
	}
	if len(m.Edges) > 0 {
		pin.Pin(&m.Edges[0])
		raw.edges = (*C.float)(unsafe.Pointer(&m.Edges[0]))
	}
	raw.edge_count = edges
	if rgb != nil {
		pin.Pin(rgb)
		raw.rgb = rgb
	}
	return v.add("cadaclysm_view_show_mesh", func() C.uint32_t { return C.cv_show_mesh(v.lib.t, v.handle, &raw) }, nil)
}

// ShowLines shows segments, six floats (two points) each; rgb a Colour, nil the default.
func (v *View) ShowLines(segments []float32, rgb Colour) (*Item, error) {
	if len(segments)%6 != 0 {
		return nil, refused(fmt.Sprintf("segments is two points a segment (6 numbers), not %d", len(segments)))
	}
	n, err := count(len(segments)/6, "show_lines")
	if err != nil {
		return nil, err
	}
	c, err := v.paintFor("cadaclysm_view_show_lines", rgb, false)
	if err != nil {
		return nil, err
	}
	return v.add("cadaclysm_view_show_lines", func() C.uint32_t {
		return C.cv_show_lines(v.lib.t, v.handle, floats(segments), n, c)
	}, nil)
}

// ShowPoints shows points, three floats each: a disc sizePx device pixels across (1 to 64)
// at each, in rgb (a Colour, nil the edge colour), as one item. A point does not pick; the
// item is framed by its points' box. The library refuses a value that is not finite and a
// size out of range; the terminal library refuses points. Go has no default arguments: the
// other wrappers' default size is 8.
func (v *View) ShowPoints(positions []float32, rgb Colour, sizePx float32) (*Item, error) {
	if len(positions)%3 != 0 {
		return nil, refused(fmt.Sprintf("show_points: three numbers a point, not %d", len(positions)))
	}
	n, err := count(len(positions)/3, "show_points")
	if err != nil {
		return nil, err
	}
	c, err := v.paintFor("cadaclysm_view_show_points", rgb, false)
	if err != nil {
		return nil, err
	}
	return v.add("cadaclysm_view_show_points", func() C.uint32_t {
		return C.cv_show_points(v.lib.t, v.handle, floats(positions), n, c, C.float(sizePx))
	}, nil)
}

// A tool as the machining view takes it: Shape is "flat", "ball", "drill", "vbit" or
// "bullnose"; Angle is a V-bit's included angle, CornerRadius a bull-nose's; FluteLength 0 is
// not given.
type MachiningTool struct {
	Number                                     uint32
	Shape                                      string
	Diameter, FluteLength, Angle, CornerRadius float64
}

// MachiningProgram is one program of a job: G-code run with a tool.
type MachiningProgram struct {
	Tool  MachiningTool
	Gcode string
}

// MachiningStock is the blank: its lowest and highest corners, mm.
type MachiningStock struct{ Min, Max [3]float64 }

// MachiningPart is a mesh to colour by deviation against: Positions three floats a vertex,
// Indices three a triangle.
type MachiningPart struct {
	Positions []float32
	Indices   []uint32
}

// MachiningOptions: a nil field is the library's own default.
type MachiningOptions struct{ Cell, Tolerance, Skin, RapidRate *float64 }

// MachiningInfo is a machining's facts: its Moves, the Move done (as of the last draw), the
// heights' grid (Nx, Ny, Cell, Min) and the job's CycleTime in seconds.
type MachiningInfo struct {
	Moves, Move, Nx, Ny uint32
	Cell                float32
	Min                 [2]float32
	CycleTime           float64
}

// Machining is a CAM job shown in a View (ShowMachining): the stock is this item and the
// view's timeline plays it (View.Play, Seek, Status). Every Item method works on it too.
type Machining struct{ *Item }

// ShowMachining shows a CAM job on a stock, paused at its start: programs in run order, the
// stock box, an optional part (nil: none) for colouring by deviation, and options (nil: all
// defaults) whose nil fields are the library's own (tolerance 0.05, skin 0.3, rapid rate 5000
// mm/min). Play it with Play. A shape that is none of "flat", "ball", "drill", "vbit" or
// "bullnose", a number that is not finite, a NUL in the G-code, a part that is not whole
// triangles of x y z triples and an index past its vertices are refused before the library.
func (v *View) ShowMachining(programs []MachiningProgram, stock MachiningStock, part *MachiningPart, o *MachiningOptions) (*Machining, error) {
	shapes := map[string]C.uint32_t{"flat": C.CADACLYSM_VIEW_TOOL_FLAT, "ball": C.CADACLYSM_VIEW_TOOL_BALL,
		"drill": C.CADACLYSM_VIEW_TOOL_DRILL, "vbit": C.CADACLYSM_VIEW_TOOL_VBIT, "bullnose": C.CADACLYSM_VIEW_TOOL_BULLNOSE}
	finite := func(xs ...float64) bool {
		for _, x := range xs {
			if math.IsNaN(x) || math.IsInf(x, 0) {
				return false
			}
		}
		return true
	}
	n, err := count(len(programs), "show_machining")
	if err != nil {
		return nil, err
	}
	for _, p := range programs {
		if _, ok := shapes[p.Tool.Shape]; !ok {
			return nil, refused(fmt.Sprintf("shape '%s': one of flat, ball, drill, vbit, bullnose", p.Tool.Shape))
		}
		if !finite(p.Tool.Diameter, p.Tool.FluteLength, p.Tool.Angle, p.Tool.CornerRadius) {
			return nil, refused("tool: diameter, flute_length, angle and corner_radius are finite numbers")
		}
		if strings.IndexByte(p.Gcode, 0) >= 0 {
			return nil, refused("gcode: a NUL character cannot be sent (the C string ends there)")
		}
	}
	if !finite(stock.Min[0], stock.Min[1], stock.Min[2], stock.Max[0], stock.Max[1], stock.Max[2]) {
		return nil, refused("stock: min and max are finite numbers")
	}
	var vertices, indices C.uint32_t
	if part != nil {
		for _, x := range part.Positions {
			if !finite(float64(x)) {
				return nil, refused("part positions: finite numbers")
			}
		}
		if len(part.Positions)%3 != 0 {
			return nil, refused(fmt.Sprintf("part positions: %d numbers is not a whole number of x y z triples", len(part.Positions)))
		}
		if len(part.Indices)%3 != 0 {
			return nil, refused(fmt.Sprintf("part indices: %d is not a whole number of triangles", len(part.Indices)))
		}
		for _, k := range part.Indices {
			if uint64(k) >= uint64(len(part.Positions)/3) {
				return nil, refused(fmt.Sprintf("part indices: %d is past the last of %d vertices", k, len(part.Positions)/3))
			}
		}
		if vertices, err = count(len(part.Positions)/3, "show_machining part"); err != nil {
			return nil, err
		}
		if indices, err = count(len(part.Indices), "show_machining part"); err != nil {
			return nil, err
		}
	}
	if o != nil {
		for _, x := range []*float64{o.Cell, o.Tolerance, o.Skin, o.RapidRate} {
			if x != nil && !finite(*x) {
				return nil, refused("show_machining options: cell, tolerance, skin and rapid_rate are finite numbers")
			}
		}
	}

	// cgo's pointer rules: no Go pointer inside memory C reads, so every array the struct
	// points at is C memory, freed when the call returns.
	size := C.size_t(unsafe.Sizeof(C.CadaclysmViewProgram{}))
	base := C.calloc(C.size_t(len(programs))+1, size)
	defer C.free(base)
	raw := unsafe.Slice((*C.CadaclysmViewProgram)(base), len(programs)+1)
	for k, p := range programs {
		text := C.CString(p.Gcode)
		defer C.free(unsafe.Pointer(text))
		raw[k] = C.CadaclysmViewProgram{size: C.uint32_t(size), tool_number: C.uint32_t(p.Tool.Number), tool_shape: shapes[p.Tool.Shape],
			tool_diameter: C.double(p.Tool.Diameter), tool_flute_length: C.double(p.Tool.FluteLength), tool_angle: C.double(p.Tool.Angle),
			tool_corner_radius: C.double(p.Tool.CornerRadius), gcode: text}
	}
	m := (*C.CadaclysmViewMachining)(C.calloc(1, C.size_t(unsafe.Sizeof(C.CadaclysmViewMachining{}))))
	defer C.free(unsafe.Pointer(m))
	m.size, m.program_count, m.programs = C.uint32_t(unsafe.Sizeof(*m)), n, (*C.CadaclysmViewProgram)(base)
	for a := 0; a < 3; a++ {
		m.stock_min[a], m.stock_max[a] = C.double(stock.Min[a]), C.double(stock.Max[a])
	}
	if part != nil {
		positions := C.malloc((C.size_t(len(part.Positions)) + 1) * 4)
		defer C.free(positions)
		triangles := C.malloc((C.size_t(len(part.Indices)) + 1) * 4)
		defer C.free(triangles)
		copy(unsafe.Slice((*float32)(positions), len(part.Positions)+1), part.Positions)
		copy(unsafe.Slice((*uint32)(triangles), len(part.Indices)+1), part.Indices)
		m.part_positions, m.part_indices = (*C.float)(positions), (*C.uint32_t)(triangles)
		m.part_vertex_count, m.part_index_count = vertices, indices
	}
	if o != nil {
		if o.Cell != nil {
			m.cell = C.double(*o.Cell)
		}
		if o.Tolerance != nil {
			m.tolerance = C.double(*o.Tolerance)
		}
		if o.RapidRate != nil {
			m.rapid_rate = C.double(*o.RapidRate)
		}
		if o.Skin != nil {
			m.skin, m.skin_set = C.double(*o.Skin), 1
		}
	}
	item, err := v.add("cadaclysm_view_show_machining", func() C.uint32_t { return C.cv_show_machining(v.lib.t, v.handle, m) }, nil)
	runtime.KeepAlive(v)
	if err != nil {
		return nil, err
	}
	return &Machining{Item: item}, nil
}

// SeekMove jumps the timeline to the end of move `move` (0: the untouched stock; Info's
// Moves: the end). The stock gets there over the next draws, or at once on Heights.
func (m *Machining) SeekMove(move uint32) error {
	defer runtime.KeepAlive(m.view)
	return m.ok("cadaclysm_view_machining_seek", func(v *View) C.bool {
		return C.cv_machining_seek(v.lib.t, v.handle, C.uint32_t(m.id), C.uint32_t(move))
	})
}

// ColourBy colours the stock: "height", "tool" or "deviation" (the last needs a part).
func (m *Machining) ColourBy(mode string) error {
	modes := map[string]C.uint32_t{"height": C.CADACLYSM_VIEW_COLOUR_BY_HEIGHT, "tool": C.CADACLYSM_VIEW_COLOUR_BY_TOOL,
		"deviation": C.CADACLYSM_VIEW_COLOUR_BY_DEVIATION}
	c, ok := modes[mode]
	if !ok {
		return refused(fmt.Sprintf("mode '%s': one of height, tool, deviation", mode))
	}
	defer runtime.KeepAlive(m.view)
	return m.ok("cadaclysm_view_machining_colour_by", func(v *View) C.bool {
		return C.cv_machining_colour_by(v.lib.t, v.handle, C.uint32_t(m.id), c)
	})
}

// Overlays turns the toolpath and the tool on or off (both are on when shown).
func (m *Machining) Overlays(path, tool bool) error {
	defer runtime.KeepAlive(m.view)
	return m.ok("cadaclysm_view_machining_overlays", func(v *View) C.bool {
		return C.cv_machining_overlays(v.lib.t, v.handle, C.uint32_t(m.id), C.bool(path), C.bool(tool))
	})
}

// Info is the job's moves, the move done, the heights' grid and its cycle time.
func (m *Machining) Info() (MachiningInfo, error) {
	defer runtime.KeepAlive(m.view)
	out := (*C.CadaclysmViewMachiningInfo)(C.calloc(1, C.size_t(unsafe.Sizeof(C.CadaclysmViewMachiningInfo{}))))
	defer C.free(unsafe.Pointer(out))
	out.size = C.uint32_t(unsafe.Sizeof(*out))
	if err := m.ok("cadaclysm_view_machining_info", func(v *View) C.bool {
		return C.cv_machining_info(v.lib.t, v.handle, C.uint32_t(m.id), out)
	}); err != nil {
		return MachiningInfo{}, err
	}
	return MachiningInfo{Moves: uint32(out.moves), Move: uint32(out.move), Nx: uint32(out.nx), Ny: uint32(out.ny),
		Cell: float32(out.cell), Min: [2]float32{float32(out.min[0]), float32(out.min[1])}, CycleTime: float64(out.cycle_time)}, nil
}

// Heights is the stock's heights now, Nx x Ny floats, row y then x (z[j*Nx+i]), mm; it
// waits for the GPU.
func (m *Machining) Heights() ([]float32, error) {
	info, err := m.Info()
	if err != nil {
		return nil, err
	}
	cells := uint64(info.Nx) * uint64(info.Ny)
	if cells > uint64(math.MaxInt)/4 {
		return nil, refused(fmt.Sprintf("heights: %d x %d cells is too large", info.Nx, info.Ny))
	}
	defer runtime.KeepAlive(m.view)
	z := C.malloc((C.size_t(cells) + 1) * 4) // never NULL, even for an empty grid
	defer C.free(z)
	if err := m.ok("cadaclysm_view_machining_heights", func(v *View) C.bool {
		return C.cv_machining_heights(v.lib.t, v.handle, C.uint32_t(m.id), (*C.float)(z), C.size_t(cells))
	}); err != nil {
		return nil, err
	}
	out := make([]float32, cells)
	copy(out, unsafe.Slice((*float32)(z), cells))
	return out, nil
}

// ShowCurves shows rational cubics, sixteen floats each (four x, y, z, w control points);
// rgb a Colour, nil the default.
func (v *View) ShowCurves(beziers []float32, rgb Colour) (*Item, error) {
	if len(beziers)%16 != 0 {
		return nil, refused(fmt.Sprintf("show_curves takes four x, y, z, w control points (16 numbers) a curve, not %d", len(beziers)))
	}
	n, err := count(len(beziers)/16, "show_curves")
	if err != nil {
		return nil, err
	}
	c, err := v.paintFor("cadaclysm_view_show_curves", rgb, false)
	if err != nil {
		return nil, err
	}
	return v.add("cadaclysm_view_show_curves", func() C.uint32_t {
		return C.cv_show_curves(v.lib.t, v.handle, floats(beziers), n, c)
	}, nil)
}

// ShowImage shows an RGBA8 picture of width x height pixels (exactly width * height * 4
// bytes, rows from the top) on the quad corners: bottom-left, bottom-right, top-right,
// top-left.
func (v *View) ShowImage(corners [12]float32, rgba []byte, width, height uint32, opacity float32) (*Item, error) {
	need, err := pixelBytes(width, height, "show_image")
	if err != nil {
		return nil, err
	}
	if uint64(len(rgba)) != need {
		return nil, refused(fmt.Sprintf("show_image: %d x %d pixels need %d bytes (rgba), not %d", width, height, need, len(rgba)))
	}
	var pin runtime.Pinner
	defer pin.Unpin()
	raw := C.CadaclysmViewImage{}
	raw.size = C.uint32_t(unsafe.Sizeof(raw))
	for i, c := range corners {
		raw.corners[i] = C.float(c)
	}
	raw.rgba = &standInU8[0]
	if len(rgba) > 0 {
		pin.Pin(&rgba[0])
		raw.rgba = (*C.uint8_t)(unsafe.Pointer(&rgba[0]))
	}
	raw.width, raw.height, raw.opacity = C.uint32_t(width), C.uint32_t(height), C.float(opacity)
	return v.add("cadaclysm_view_show_image", func() C.uint32_t { return C.cv_show_image(v.lib.t, v.handle, &raw) }, nil)
}

// ---- text ----------------------------------------------------------------------------

// TextOptions is ShowText's keywords, as Python's show_text. A nil *TextOptions, or a zero
// TextOptions{}, is every default: a white 12-pixel label, its bottom-left corner on the
// point, no box, padding 4, hidden where its point is, the bundled font. Go's zero values
// stand for the defaults where Python's defaults are not zero: an empty Mode is "label", an
// empty Align "bottom-left", a zero Size 12, a nil Colour "white", a nil Padding 4. Any
// other value reaches the library as given, which refuses a Size that is not finite and
// positive (a negative one, NaN) with its reason. DefaultTextOptions spells the defaults out.
type TextOptions struct {
	// Mode is "label" (a screen label: Size is its height in pixels, always facing the
	// viewer) or "world" (a quad in the scene: Size is its height in model units, laid along
	// Right and Up, turning and shrinking with the camera). "": "label".
	Mode string
	// Size is one line's height: pixels for a label, model units for world text. 0: 12.
	Size float32
	// Colour is the glyphs' colour (a Colour; the alpha is not drawn). nil: "white".
	Colour Colour
	// Align is which corner or edge of the text sits on the point: top-left, top, top-right,
	// left, centre (or center), right, bottom-left, bottom, bottom-right. "": "bottom-left".
	Align string
	// Offset nudges a label by pixels, right and up.
	Offset [2]float32
	// Box is a label's backing rectangle (a Colour: text or three numbers alpha 1, four as
	// given); nil: none.
	Box Colour
	// Padding is the pixels between a label and its box's edge; nil: 4.
	Padding *float32
	// OnTop draws a label even where its point is hidden.
	OnTop bool
	// Font is a LoadFont id; 0 the bundled font.
	Font uint32
	// Right and Up lay world text out: the baseline's direction and the glyphs' up (made
	// perpendicular to Right); nil: x and y.
	Right, Up *[3]float32
}

// DefaultTextOptions is ShowText's defaults spelled out (what a nil *TextOptions means).
func DefaultTextOptions() *TextOptions {
	padding := float32(4)
	return &TextOptions{Mode: "label", Size: 12, Colour: "white", Align: "bottom-left", Padding: &padding}
}

var textModes = []struct {
	name  string
	value C.uint32_t
}{{"label", C.CADACLYSM_VIEW_TEXT_LABEL}, {"world", C.CADACLYSM_VIEW_TEXT_WORLD}}

var textAligns = []struct {
	name  string
	value C.uint32_t
}{
	{"top-left", C.CADACLYSM_VIEW_ALIGN_TOP_LEFT}, {"top", C.CADACLYSM_VIEW_ALIGN_TOP},
	{"top-right", C.CADACLYSM_VIEW_ALIGN_TOP_RIGHT}, {"left", C.CADACLYSM_VIEW_ALIGN_LEFT},
	{"centre", C.CADACLYSM_VIEW_ALIGN_CENTRE}, {"center", C.CADACLYSM_VIEW_ALIGN_CENTRE},
	{"right", C.CADACLYSM_VIEW_ALIGN_RIGHT}, {"bottom-left", C.CADACLYSM_VIEW_ALIGN_BOTTOM_LEFT},
	{"bottom", C.CADACLYSM_VIEW_ALIGN_BOTTOM}, {"bottom-right", C.CADACLYSM_VIEW_ALIGN_BOTTOM_RIGHT},
}

// pyRepr is s as Python's repr writes a str in a message: in single quotes (double where it
// holds a single quote and no double one), backslash, the quote, \n, \r and \t escaped, any
// other control character as \xNN.
func pyRepr(s string) string {
	q := byte('\'')
	if strings.IndexByte(s, '\'') >= 0 && strings.IndexByte(s, '"') < 0 {
		q = '"'
	}
	var b strings.Builder
	b.WriteByte(q)
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '\\' || c == q:
			b.WriteByte('\\')
			b.WriteByte(c)
		case c == '\n':
			b.WriteString(`\n`)
		case c == '\r':
			b.WriteString(`\r`)
		case c == '\t':
			b.WriteString(`\t`)
		case c < 0x20 || c == 0x7f:
			fmt.Fprintf(&b, `\x%02x`, c)
		default:
			b.WriteByte(c)
		}
	}
	b.WriteByte(q)
	return b.String()
}

// named is value's number in table, or Python's "<what> '<value>': one of ..." refusal.
func named(table []struct {
	name  string
	value C.uint32_t
}, value, what string) (C.uint32_t, error) {
	names := make([]string, len(table))
	for k, e := range table {
		if e.name == value {
			return e.value, nil
		}
		names[k] = e.name
	}
	return 0, refused(what + " " + pyRepr(value) + ": one of " + strings.Join(names, ", "))
}

// textOf is text as the C string ShowText and SetText pass, freed by the caller: a NUL
// would end it there, silently -- refused instead, in Python's words.
func textOf(text string) (*C.char, error) {
	if strings.IndexByte(text, 0) >= 0 {
		return nil, refused("text " + pyRepr(text) + ": a NUL character cannot be shown (the C string ends there)")
	}
	return C.CString(text), nil
}

// ShowText shows text at the point at: a label or world text, as o says (nil: every
// default, see TextOptions). Item.SetText changes the string later. Refused: an unknown
// Mode or Align, a NUL in text, colour text the library refuses, and what the library
// refuses (a Size not finite and positive, world Right and Up parallel, an unknown font),
// with its reason.
func (v *View) ShowText(text string, at [3]float32, o *TextOptions) (*Item, error) {
	if o == nil {
		o = &TextOptions{}
	}
	modeName, alignName := o.Mode, o.Align
	if modeName == "" {
		modeName = "label"
	}
	if alignName == "" {
		alignName = "bottom-left"
	}
	mode, err := named(textModes, modeName, "mode")
	if err != nil {
		return nil, err
	}
	align, err := named(textAligns, alignName, "align")
	if err != nil {
		return nil, err
	}
	shown, err := textOf(text)
	if err != nil {
		return nil, err
	}
	defer C.free(unsafe.Pointer(shown))
	colour := o.Colour
	if colour == nil {
		colour = "white"
	}
	rgb, err := v.paintFor("cadaclysm_view_show_text", colour, true)
	if err != nil {
		return nil, err
	}
	box, err := v.lib.paint(o.Box)
	if err != nil {
		return nil, err
	}
	raw := C.CadaclysmViewText{}
	raw.size = C.uint32_t(unsafe.Sizeof(raw))
	raw.text = shown
	raw.mode = mode
	rgb3 := (*[4]C.float)(unsafe.Pointer(rgb))
	for k := 0; k < 3; k++ {
		raw.at[k] = C.float(at[k])
		if o.Right != nil {
			raw.right[k] = C.float(o.Right[k])
		}
		if o.Up != nil {
			raw.up[k] = C.float(o.Up[k])
		}
		raw.rgb[k] = rgb3[k]
	}
	raw.height = 12
	if o.Size != 0 {
		raw.height = C.float(o.Size)
	}
	raw.align = align
	raw.offset[0], raw.offset[1] = C.float(o.Offset[0]), C.float(o.Offset[1])
	if box != nil {
		raw.box_rgba = *box
	}
	raw.box_padding = 4
	if o.Padding != nil {
		raw.box_padding = C.float(*o.Padding)
	}
	if o.OnTop {
		raw.on_top = 1
	}
	raw.font = C.uint32_t(o.Font)
	return v.add("cadaclysm_view_show_text", func() C.uint32_t { return C.cv_show_text(v.lib.t, v.handle, &raw) }, nil)
}

// SetText replaces a text item's string, nothing else changed. Refused: a NUL in text, and
// an item that is not text (the library's reason).
func (i *Item) SetText(text string) error {
	shown, err := textOf(text)
	if err != nil {
		return err
	}
	defer C.free(unsafe.Pointer(shown))
	return i.ok("cadaclysm_view_set_text", func(v *View) C.bool {
		return C.cv_set_text(v.lib.t, v.handle, C.uint32_t(i.id), shown)
	})
}

// LoadFont loads a font for every view of the library in use (Current) from TTF or OTF
// bytes, copied in; its id for TextOptions.Font. 0 is the bundled font and needs no
// loading. Bytes that are no font are refused with the library's reason.
func LoadFont(font []byte) (uint32, error) {
	l, err := Current()
	if err != nil {
		return 0, err
	}
	bytes := &standInU8[0]
	if len(font) > 0 {
		var pin runtime.Pinner
		defer pin.Unpin()
		pin.Pin(&font[0])
		bytes = (*C.uint8_t)(unsafe.Pointer(&font[0]))
	}
	id := C.cv_load_font(l.t, bytes, C.size_t(len(font)))
	if id == 0 {
		return 0, refused(C.GoString(C.cvl_error(l.t)))
	}
	return uint32(id), nil
}

// LoadFontFile is LoadFont of the file at path; a file that cannot be read is refused
// naming it: "<path>: the font could not be read (<why>)".
func LoadFontFile(path string) (uint32, error) {
	font, err := os.ReadFile(path)
	if err != nil {
		why := err.Error()
		var pe *os.PathError
		if errors.As(err, &pe) {
			why = pe.Err.Error()
		}
		return 0, &Error{Message: path + ": the font could not be read (" + why + ")", err: err}
	}
	return LoadFont(font)
}

// ID is the item's id, as Pick reports it.
func (i *Item) ID() uint32 { return i.id }

func (i *Item) ok(call string, f func(v *View) C.bool) error {
	v := i.view
	return v.ok(call, func() C.bool { return f(v) })
}

// Remove takes the item out of the view and lets go of what it showed.
func (i *Item) Remove() error {
	err := i.ok("cadaclysm_view_remove", func(v *View) C.bool { return C.cv_remove(v.lib.t, v.handle, C.uint32_t(i.id)) })
	if err == nil {
		i.view.forget(i.id)
	}
	return err
}

// Colour paints the whole item: numbers or text (a Colour; not nil).
func (i *Item) Colour(rgb Colour) error {
	c, err := i.view.paintFor("cadaclysm_view_set_colour", rgb, true)
	if err != nil {
		return err
	}
	return i.ok("cadaclysm_view_set_colour", func(v *View) C.bool {
		return C.cv_set_colour(v.lib.t, v.handle, C.uint32_t(i.id), c)
	})
}

// Placement is a column-major 4x4, kept across uploads; nil takes it back.
func (i *Item) Placement(m *[16]float64) error {
	return i.ok("cadaclysm_view_set_placement", func(v *View) C.bool {
		var p *C.double
		if m != nil {
			p = (*C.double)(unsafe.Pointer(&m[0]))
		}
		return C.cv_set_placement(v.lib.t, v.handle, C.uint32_t(i.id), p)
	})
}

// FaceColours paints faces (the item's pick numbering), one colour each (the alpha is not
// drawn): rgba is a [][4]float32, a [][3]float32, a []string of colour text or a []Colour,
// as long as faces; both empty (or nil): every face its own colour again.
func (i *Item) FaceColours(faces []uint32, rgba any) error {
	var list []Colour
	switch x := rgba.(type) {
	case nil:
	case [][4]float32:
		for _, c := range x {
			list = append(list, c)
		}
	case [][3]float32:
		for _, c := range x {
			list = append(list, c)
		}
	case []string:
		for _, c := range x {
			list = append(list, c)
		}
	case []Colour:
		list = x
	default:
		return refused(fmt.Sprintf("face_colours: a [][4]float32, [][3]float32, []string or []view.Colour, not a %T", rgba))
	}
	if len(faces) != len(list) {
		return refused(fmt.Sprintf("%d numbers (rgba, 4 a face), not %d", 4*uint64(len(faces)), 4*uint64(len(list))))
	}
	n, err := count(len(faces), "face_colours")
	if err != nil {
		return err
	}
	if err := i.view.refusal("cadaclysm_view_set_face_colours"); err != nil {
		return err
	}
	flat := make([]C.float, 0, 4*len(list))
	for _, c := range list {
		p, err := i.view.lib.paint(c)
		if err != nil {
			return err
		}
		if p == nil {
			return refused("face_colours: nil is no colour (numbers or text)")
		}
		flat = append(flat, p[:]...)
	}
	colours := &standInF32[0]
	if len(flat) > 0 {
		colours = &flat[0]
	}
	return i.ok("cadaclysm_view_set_face_colours", func(v *View) C.bool {
		return C.cv_set_face_colours(v.lib.t, v.handle, C.uint32_t(i.id), uint32s(faces), colours, n)
	})
}

// Frame fits the camera to this item.
func (i *Item) Frame() error {
	return i.ok("cadaclysm_view_frame", func(v *View) C.bool { return C.cv_frame(v.lib.t, v.handle, C.uint32_t(i.id)) })
}

// Xray draws the item's triangles through whatever is in front of them.
func (i *Item) Xray(on bool) error {
	return i.ok("cadaclysm_view_set_xray", func(v *View) C.bool {
		return C.cv_set_xray(v.lib.t, v.handle, C.uint32_t(i.id), C.bool(on))
	})
}

// Occluded sets how the item's lines and points draw where a surface hides them: "off"
// (not drawn, the default), "solid" (drawn through) or "dashed" (dashed and dimmed).
func (i *Item) Occluded(mode string) error {
	m, ok := map[string]C.uint32_t{"off": C.CADACLYSM_VIEW_OCCLUDED_OFF, "solid": C.CADACLYSM_VIEW_OCCLUDED_SOLID, "dashed": C.CADACLYSM_VIEW_OCCLUDED_DASHED}[mode]
	if !ok {
		return fmt.Errorf("occluded: %q is not \"off\", \"solid\" or \"dashed\"", mode)
	}
	return i.ok("cadaclysm_view_set_occluded", func(v *View) C.bool {
		return C.cv_set_occluded(v.lib.t, v.handle, C.uint32_t(i.id), m)
	})
}

// Finish sets the item's finish: "gloss" (an item shows with this until it is set) -- under
// the showroom lighting a clear coat mirroring the room, silver at a grazing angle -- "satin"
// (a weaker, blurred coat) or "matte" (no mirror, a faint sheen: rubber, cloth). Uploads the
// scene again, as a show does: set it as each item is shown rather than over a finished
// scene item by item.
func (i *Item) Finish(finish string) error {
	f, ok := map[string]C.uint32_t{"gloss": C.CADACLYSM_VIEW_FINISH_GLOSS, "satin": C.CADACLYSM_VIEW_FINISH_SATIN, "matte": C.CADACLYSM_VIEW_FINISH_MATTE}[finish]
	if !ok {
		return fmt.Errorf("finish: %q is not \"gloss\", \"satin\" or \"matte\"", finish)
	}
	return i.ok("cadaclysm_view_set_finish", func(v *View) C.bool {
		return C.cv_set_finish(v.lib.t, v.handle, C.uint32_t(i.id), f)
	})
}

// NodeVisible shows or hides a scene node (the reader's index) and its subtree.
func (i *Item) NodeVisible(node uint32, on bool) error {
	return i.ok("cadaclysm_view_set_node_visible", func(v *View) C.bool {
		return C.cv_set_node_visible(v.lib.t, v.handle, C.uint32_t(i.id), C.uint32_t(node), C.bool(on))
	})
}

// NodeColour colours a node's subtree: a Colour (the alpha is not drawn); nil: the node's
// own colour.
func (i *Item) NodeColour(node uint32, rgba Colour) error {
	p, err := i.view.paintFor("cadaclysm_view_set_node_color", rgba, false)
	if err != nil {
		return err
	}
	return i.ok("cadaclysm_view_set_node_color", func(v *View) C.bool {
		return C.cv_set_node_color(v.lib.t, v.handle, C.uint32_t(i.id), C.uint32_t(node), p)
	})
}

// NodeHighlight tints a node's subtree toward rgba's colour by its alpha (a Colour; text:
// alpha 1); nil clears.
func (i *Item) NodeHighlight(node uint32, rgba Colour) error {
	p, err := i.view.paintFor("cadaclysm_view_set_node_highlight", rgba, false)
	if err != nil {
		return err
	}
	return i.ok("cadaclysm_view_set_node_highlight", func(v *View) C.bool {
		return C.cv_set_node_highlight(v.lib.t, v.handle, C.uint32_t(i.id), C.uint32_t(node), p)
	})
}

// FrameNode fits the camera to one node of a scene item.
func (i *Item) FrameNode(node uint32) error {
	return i.ok("cadaclysm_view_frame_node", func(v *View) C.bool {
		return C.cv_frame_node(v.lib.t, v.handle, C.uint32_t(i.id), C.uint32_t(node))
	})
}

// NodeTransforms poses a shown scene: one column-major 4x4 per scene node, in index order
// (Pose.RawTransform's layout), drawn in place of each node's rest transform; nil restores
// the rest pose. An empty, non-nil list reaches the library, which refuses it.
func (i *Item) NodeTransforms(transforms [][16]float64) error {
	n, err := count(len(transforms), "node_transforms")
	if err != nil {
		return err
	}
	var p *C.double // nil: the rest pose
	if transforms != nil {
		p = &standInF64[0]
		if len(transforms) > 0 {
			p = (*C.double)(unsafe.Pointer(&transforms[0][0]))
		}
	}
	return i.ok("cadaclysm_view_set_node_transforms", func(v *View) C.bool {
		return C.cv_set_node_transforms(v.lib.t, v.handle, C.uint32_t(i.id), p, n)
	})
}

// Orbit turns the camera by a drag of dx, dy pixels.
func (v *View) Orbit(dx, dy float32) error {
	return v.act("cadaclysm_view_orbit", func() { C.cv_orbit(v.lib.t, v.handle, C.float(dx), C.float(dy)) })
}

// Pan moves the camera by a drag of dx, dy pixels.
func (v *View) Pan(dx, dy float32) error {
	return v.act("cadaclysm_view_pan", func() { C.cv_pan(v.lib.t, v.handle, C.float(dx), C.float(dy)) })
}

// Zoom moves the camera by wheel steps.
func (v *View) Zoom(steps float32) error {
	return v.act("cadaclysm_view_zoom", func() { C.cv_zoom(v.lib.t, v.handle, C.float(steps)) })
}

// Look turns the camera about its eye.
func (v *View) Look(dx, dy float32) error {
	return v.act("cadaclysm_view_look", func() { C.cv_look(v.lib.t, v.handle, C.float(dx), C.float(dy)) })
}

// Dolly moves the eye toward the target by ratio.
func (v *View) Dolly(ratio float32) error {
	return v.act("cadaclysm_view_dolly", func() { C.cv_dolly(v.lib.t, v.handle, C.float(ratio)) })
}

// Orthographic switches the projection.
func (v *View) Orthographic(on bool) error {
	return v.act("cadaclysm_view_set_orthographic", func() { C.cv_set_orthographic(v.lib.t, v.handle, C.bool(on)) })
}

// Background is the clear colour, linear 0..1: numbers or text (a Colour; not nil).
func (v *View) Background(rgb Colour) error {
	c, err := v.paintFor("cadaclysm_view_set_background", rgb, true)
	if err != nil {
		return err
	}
	return v.act("cadaclysm_view_set_background", func() { C.cv_set_background(v.lib.t, v.handle, c) })
}

// Standard is "top", "front", "right" or "iso".
func (v *View) Standard(name string) error {
	which := map[string]C.uint32_t{"top": C.CADACLYSM_VIEW_STANDARD_TOP, "front": C.CADACLYSM_VIEW_STANDARD_FRONT,
		"right": C.CADACLYSM_VIEW_STANDARD_RIGHT, "iso": C.CADACLYSM_VIEW_STANDARD_ISO}
	w, ok := which[name]
	if !ok {
		return refused(fmt.Sprintf("standard view '%s': one of top, front, right, iso", name))
	}
	return v.ok("cadaclysm_view_standard", func() C.bool { return C.cv_standard(v.lib.t, v.handle, w) })
}

// Frame fits the camera to everything shown.
func (v *View) Frame() error {
	return v.ok("cadaclysm_view_frame", func() C.bool { return C.cv_frame(v.lib.t, v.handle, 0) })
}

// Surfaces is "exact" or "triangles".
func (v *View) Surfaces(which string) error {
	var s C.uint32_t
	switch which {
	case "exact":
	case "triangles":
		s = C.CADACLYSM_VIEW_SURFACES_TRIANGLES
	default:
		return refused(fmt.Sprintf("surfaces '%s': 'exact' or 'triangles'", which))
	}
	return v.ok("cadaclysm_view_set_surfaces", func() C.bool { return C.cv_set_surfaces(v.lib.t, v.handle, s) })
}

// SetLighting is how plain parts are lit, as Python's View.lighting: "headlight" (the
// default) -- whatever faces the camera is bright -- or "studio", a key light fixed above
// the scene with an ambient and a camera fill. Another name is refused before C.
func (v *View) SetLighting(name string) error {
	var l C.uint32_t
	switch name {
	case "headlight":
	case "studio":
		l = C.CADACLYSM_VIEW_LIGHTING_STUDIO
	default:
		return refused(fmt.Sprintf("lighting '%s': 'headlight' or 'studio'", name))
	}
	return v.ok("cadaclysm_view_set_lighting", func() C.bool { return C.cv_set_lighting(v.lib.t, v.handle, l) })
}

// Lighting is the lighting in use: "headlight" or "studio".
func (v *View) Lighting() (string, error) {
	if err := v.refusal("cadaclysm_view_lighting"); err != nil {
		return "headlight", err
	}
	if C.cv_lighting(v.lib.t, v.handle) == C.CADACLYSM_VIEW_LIGHTING_STUDIO {
		return "studio", nil
	}
	return "headlight", nil
}

// OccludedStyle is how every "dashed" item's hidden lines and points look, as Python's
// OccludedStyle: a dash and a gap in points, the share of coverage kept (above 0, at most
// 1), and optionally one colour (0..1 RGB). Its zero value is the default: the library reads
// a zero dash, gap or dim as 6, 4 and 0.5.
type OccludedStyle struct {
	Dash, Gap, Dim float32
	Colour         *[3]float32
}

// DefaultOccludedStyle is the style a view starts with, as the library reports it.
func DefaultOccludedStyle() OccludedStyle { return OccludedStyle{Dash: 6, Gap: 4, Dim: 0.5} }

// SetOccludedStyle sets the view-wide occluded style; "solid" and "off" items never use it.
func (v *View) SetOccludedStyle(s OccludedStyle) error {
	raw := C.CadaclysmViewOccludedStyle{}
	raw.size = C.uint32_t(unsafe.Sizeof(raw))
	raw.dash, raw.gap, raw.dim = C.float(s.Dash), C.float(s.Gap), C.float(s.Dim)
	if s.Colour != nil {
		raw.has_colour = 1
		for i, c := range s.Colour {
			raw.colour[i] = C.float(c)
		}
	}
	return v.ok("cadaclysm_view_set_occluded_style", func() C.bool { return C.cv_set_occluded_style(v.lib.t, v.handle, &raw) })
}

// OccludedStyle reports the view's occluded style, the defaults as their values.
func (v *View) OccludedStyle() (OccludedStyle, error) {
	raw := C.CadaclysmViewOccludedStyle{}
	raw.size = C.uint32_t(unsafe.Sizeof(raw))
	if err := v.ok("cadaclysm_view_occluded_style", func() C.bool { return C.cv_occluded_style(v.lib.t, v.handle, &raw) }); err != nil {
		return OccludedStyle{}, err
	}
	s := OccludedStyle{Dash: float32(raw.dash), Gap: float32(raw.gap), Dim: float32(raw.dim)}
	if raw.has_colour != 0 {
		c := [3]float32{float32(raw.colour[0]), float32(raw.colour[1]), float32(raw.colour[2])}
		s.Colour = &c
	}
	return s, nil
}

// Play plays the view's timeline at `speed` times real time: each Draw moves it on by the
// wall-clock time since the last. It stops at its end unless Loop is on; Play at the end
// starts again from 0.
func (v *View) Play(speed float64) error {
	if math.IsNaN(speed) || math.IsInf(speed, 0) {
		return refused("play speed: a finite number")
	}
	defer runtime.KeepAlive(v)
	return v.ok("cadaclysm_view_timeline_play", func() C.bool { return C.cv_timeline_play(v.lib.t, v.handle, C.double(speed)) })
}

// Pause stops the timeline where it is.
func (v *View) Pause() error {
	defer runtime.KeepAlive(v)
	return v.ok("cadaclysm_view_timeline_pause", func() C.bool { return C.cv_timeline_pause(v.lib.t, v.handle) })
}

// Seek sets the timeline's clock, clamped to [0, Duration].
func (v *View) Seek(seconds float64) error {
	if math.IsNaN(seconds) || math.IsInf(seconds, 0) {
		return refused("seek seconds: a finite number")
	}
	defer runtime.KeepAlive(v)
	return v.ok("cadaclysm_view_timeline_seek", func() C.bool { return C.cv_timeline_seek(v.lib.t, v.handle, C.double(seconds)) })
}

// Loop sets whether the timeline starts again at its end.
func (v *View) Loop(on bool) error {
	defer runtime.KeepAlive(v)
	return v.ok("cadaclysm_view_timeline_set_loop", func() C.bool { return C.cv_timeline_set_loop(v.lib.t, v.handle, C.bool(on)) })
}

// Time is the timeline's clock, seconds.
func (v *View) Time() (float64, error) {
	if err := v.refusal("cadaclysm_view_timeline_time"); err != nil {
		return 0, err
	}
	defer runtime.KeepAlive(v)
	return float64(C.cv_timeline_time(v.lib.t, v.handle)), nil
}

// Duration is the timeline's length, seconds: its longest track's.
func (v *View) Duration() (float64, error) {
	if err := v.refusal("cadaclysm_view_timeline_duration"); err != nil {
		return 0, err
	}
	defer runtime.KeepAlive(v)
	return float64(C.cv_timeline_duration(v.lib.t, v.handle)), nil
}

// Playing is whether the timeline plays.
func (v *View) Playing() (bool, error) {
	if err := v.refusal("cadaclysm_view_timeline_playing"); err != nil {
		return false, err
	}
	defer runtime.KeepAlive(v)
	return bool(C.cv_timeline_playing(v.lib.t, v.handle)), nil
}

// Status is one line per track at the clock's time, e.g. "move 370 of 638 - T1 flat 6 mm";
// none when nothing is on the timeline.
func (v *View) Status() ([]string, error) {
	if err := v.refusal("cadaclysm_view_timeline_status"); err != nil {
		return nil, err
	}
	defer runtime.KeepAlive(v)
	n := C.cv_timeline_status(v.lib.t, v.handle, nil, 0)
	for n > 0 {
		buffer := C.malloc(n + 1)
		got := C.cv_timeline_status(v.lib.t, v.handle, (*C.char)(buffer), n+1)
		if got < n+1 {
			text := C.GoStringN((*C.char)(buffer), C.int(got))
			C.free(buffer)
			if got == 0 { // the line emptied between the two calls
				return []string{}, nil
			}
			return strings.Split(text, "\n"), nil
		}
		C.free(buffer) // the line grew between the two calls: ask again with room for it
		n = got
	}
	return []string{}, nil
}

// Layer switches a CADACLYSM_VIEW_LAYER_* layer.
func (v *View) Layer(layer uint32, on bool) error {
	return v.ok("cadaclysm_view_set_layer", func() C.bool {
		return C.cv_set_layer(v.lib.t, v.handle, C.uint32_t(layer), C.bool(on))
	})
}

// Viewport is one pane: its rectangle (x, y, width, height in physical pixels from the top
// left), its camera's column-major view and projection, the eye, and a CADACLYSM_VIEW_GRID_* grid.
type Viewport struct {
	Rect             [4]uint32
	View, Projection [16]float32
	Eye              [3]float32
	Grid             uint32
}

// Viewports draws panes of their own cameras; nil or empty: the one camera again.
func (v *View) Viewports(list []Viewport) error {
	n, err := count(len(list), "viewports")
	if err != nil {
		return err
	}
	raw := make([]C.CadaclysmViewViewport, len(list))
	for i, p := range list {
		raw[i].size = C.uint32_t(unsafe.Sizeof(raw[i]))
		for k := 0; k < 4; k++ {
			raw[i].rect[k] = C.uint32_t(p.Rect[k])
		}
		for k := 0; k < 16; k++ {
			raw[i].view[k], raw[i].projection[k] = C.float(p.View[k]), C.float(p.Projection[k])
		}
		for k := 0; k < 3; k++ {
			raw[i].eye[k] = C.float(p.Eye[k])
		}
		raw[i].grid = C.uint32_t(p.Grid)
		raw[i].layer_mask = 0xFFFFFFFF // every user layer
	}
	var first *C.CadaclysmViewViewport // NULL, 0 for none, as Python's
	if len(raw) > 0 {
		first = &raw[0]
	}
	return v.ok("cadaclysm_view_set_viewports", func() C.bool { return C.cv_set_viewports(v.lib.t, v.handle, first, n) })
}

// Pick is what is under (x, y) of a viewport; Item 0 for nothing. As Python's pick: a view
// never drawn is drawn first; a failure is the library's own message, or "pick: the answer
// never landed (...)".
func (v *View) Pick(x, y, viewport uint32) (Pick, error) {
	call := "cadaclysm_view_draw"
	if v != nil && v.drawn != 0 {
		call = "cadaclysm_view_request_pick_in"
	}
	if err := v.refusal(call); err != nil {
		return Pick{}, err
	}
	var raw C.CadaclysmViewPick
	var msg [C.CVL_ERROR]C.char
	if C.cvl_pick(v.lib.t, v.handle, &v.drawn, C.uint32_t(viewport), C.uint32_t(x), C.uint32_t(y), &raw, &msg[0], C.CVL_ERROR) == 0 {
		return Pick{}, refused(C.GoString(&msg[0]))
	}
	return pickOf(&raw), nil
}

// LastPick is the newest pick answer that has landed, without asking or waiting -- Python's
// last_pick: a click or tap in the view's own window (Pump lands them as it draws), a
// double click's (Clicks 2), or one an Input asked for, landed by the draws after it.
// landed is false while none has; a click on nothing is landed with Item 0. Each answer is
// read once, and a newer one replaces one not read yet. A failure other than "no answer
// yet" is the library's own message.
func (v *View) LastPick() (pick Pick, landed bool, err error) {
	if err := v.refusal("cadaclysm_view_pick_result"); err != nil {
		return Pick{}, false, err
	}
	raw := C.CadaclysmViewPick{}
	raw.size = C.uint32_t(unsafe.Sizeof(raw))
	if C.cv_pick_result(v.lib.t, v.handle, &raw) {
		return pickOf(&raw), true, nil
	}
	said := C.GoString(C.cv_last_error(v.lib.t))
	if said != "" && !strings.HasSuffix(said, "no pick result") {
		return Pick{}, false, refused(said)
	}
	return Pick{}, false, nil
}

// SetSnap is what a snap may land on -- SnapAll, kinds or'ed together, or 0 to switch
// snapping off, as a view starts -- how far from the cursor a point kind may lie (aperturePx
// points; 0: the library's default, 10), and whether the view draws the marker at the snap.
// Once on, a mouse hovering over a view in its own window snaps, and so does a click
// (LastSnap reads them); Snap asks one at any pixel. Where kinds compete, a corner beats the
// face it sits on.
func (v *View) SetSnap(kinds SnapKind, aperturePx float32, marker bool) error {
	raw := C.CadaclysmViewSnapSettings{}
	raw.size = C.uint32_t(unsafe.Sizeof(raw))
	raw.kinds = C.uint32_t(kinds)
	raw.aperture_px = C.float(aperturePx)
	if marker {
		raw.marker = 1
	}
	return v.ok("cadaclysm_view_set_snap", func() C.bool { return C.cv_set_snap(v.lib.t, v.handle, &raw) })
}

// Snap is the snap under (x, y) of a viewport; Kind 0 where nothing in the kinds SetSnap
// chose lies there -- always, while snapping is off. As Pick: a view never drawn is drawn
// first, then frames until the answer lands; a failure is the library's own message, or
// "snap: the answer never landed (...)".
func (v *View) Snap(x, y, viewport uint32) (Snap, error) {
	call := "cadaclysm_view_draw"
	if v != nil && v.drawn != 0 {
		call = "cadaclysm_view_request_snap_in"
	}
	if err := v.refusal(call); err != nil {
		return Snap{}, err
	}
	var raw C.CadaclysmViewSnap
	var msg [C.CVL_ERROR]C.char
	if C.cvl_snap(v.lib.t, v.handle, &v.drawn, C.uint32_t(viewport), C.uint32_t(x), C.uint32_t(y), &raw, &msg[0], C.CVL_ERROR) == 0 {
		return Snap{}, refused(C.GoString(&msg[0]))
	}
	return snapOf(&raw), nil
}

// LastSnap is the newest snap answer that has landed, without asking or waiting -- Python's
// last_snap: a hover or click in the view's own window (Pump lands them as it draws), or one
// an Input asked for. landed is false while none has; a snap that found nothing is landed
// with Kind 0. Each answer is read once; a hover's never replaces a click's not read yet. A
// failure other than "no answer yet" is the library's own message.
func (v *View) LastSnap() (snap Snap, landed bool, err error) {
	if err := v.refusal("cadaclysm_view_snap_result"); err != nil {
		return Snap{}, false, err
	}
	raw := C.CadaclysmViewSnap{}
	raw.size = C.uint32_t(unsafe.Sizeof(raw))
	if C.cv_snap_result(v.lib.t, v.handle, &raw) {
		return snapOf(&raw), true, nil
	}
	said := C.GoString(C.cv_last_error(v.lib.t))
	if said != "" && !strings.HasSuffix(said, "no snap result") {
		return Snap{}, false, refused(said)
	}
	return Snap{}, false, nil
}

// ClearSnap hides the snap marker and drops any snap asked or answered and not yet read.
func (v *View) ClearSnap() error {
	return v.act("cadaclysm_view_clear_snap", func() { C.cv_clear_snap(v.lib.t, v.handle) })
}

// SetWorkPlane is the plane SnapGrid and SnapPlane snaps land on, in place of the ground
// grid: through origin, its grid lines along xAxis and across it, step apart (0: the ground
// grid's spacing). The axes need not be unit length, but must not be parallel.
func (v *View) SetWorkPlane(origin, xAxis, normal [3]float64, step float64) error {
	return v.ok("cadaclysm_view_set_work_plane", func() C.bool {
		return C.cv_set_work_plane(v.lib.t, v.handle, (*C.double)(unsafe.Pointer(&origin[0])),
			(*C.double)(unsafe.Pointer(&xAxis[0])), (*C.double)(unsafe.Pointer(&normal[0])), C.double(step))
	})
}

// ClearWorkPlane puts the ground grid back for SnapGrid and SnapPlane snaps.
func (v *View) ClearWorkPlane() error {
	return v.ok("cadaclysm_view_clear_work_plane", func() C.bool { return C.cv_clear_work_plane(v.lib.t, v.handle) })
}

// SetDoubleClickFrames is whether a double click frames what it hit (off by default: it is
// a pick answered with Clicks 2 and the camera stays). It applies where the view takes the
// pick itself (its own window, Pump, Run).
func (v *View) SetDoubleClickFrames(on bool) error {
	return v.act("cadaclysm_view_set_double_click_frames", func() {
		C.cv_set_double_click_frames(v.lib.t, v.handle, C.bool(on))
	})
}

// Focus moves the orbit point to point (as a Pick's Point): the eye keeps its direction and
// distance from it, so the camera moves sideways and does not turn. It leaves fly mode. A
// point not finite, or one while viewports are set, is the library's refusal.
func (v *View) Focus(point [3]float32) error {
	return v.ok("cadaclysm_view_focus", func() C.bool {
		return C.cv_focus(v.lib.t, v.handle, (*C.float)(unsafe.Pointer(&point[0])))
	})
}

// Navigation is how a left drag moves the camera. A fly key (W, A, S, D, E, Q) sent through
// Input enters fly mode and it stays after the key is let go; Tab toggles it; Frame,
// Standard and Focus leave it.
func (v *View) Navigation() (Navigation, error) {
	if err := v.refusal("cadaclysm_view_navigation"); err != nil {
		return NavigationOrbit, err
	}
	return Navigation(C.cv_navigation(v.lib.t, v.handle)), nil
}

// Draw draws one frame.
func (v *View) Draw() error {
	err := v.ok("cadaclysm_view_draw", func() C.bool { return C.cv_draw(v.lib.t, v.handle) })
	if err == nil {
		v.drawn = 1
	}
	return err
}

// Lod sets the levels of detail, as Python's View.lod: parts of minTriangles or more (0:
// the library's default, 2,048) get coarser levels, and a moving frame draws as motion
// says -- "detailed" or "smooth" (see WakeMs); "" turns them off (the default).
func (v *View) Lod(motion string, minTriangles uint32) error {
	if motion == "" {
		return v.ok("cadaclysm_view_set_lod", func() C.bool { return C.cv_set_lod(v.lib.t, v.handle, nil) })
	}
	lod := C.CadaclysmViewLod{}
	lod.size = C.uint32_t(unsafe.Sizeof(lod))
	lod.min_triangles = C.uint32_t(minTriangles)
	switch motion {
	case "detailed":
		lod.motion = C.CADACLYSM_VIEW_LOD_DETAILED
	case "smooth":
		lod.motion = C.CADACLYSM_VIEW_LOD_SMOOTH
	default:
		return refused(fmt.Sprintf("motion '%s': one of detailed, smooth or none", motion))
	}
	return v.ok("cadaclysm_view_set_lod", func() C.bool { return C.cv_set_lod(v.lib.t, v.handle, &lod) })
}

// WakeMs is how many milliseconds until NeedsDraw turns true by itself (a resting frame
// refining the picture; 0: one is owed now); coming false when none is.
func (v *View) WakeMs() (ms uint32, coming bool, err error) {
	if err := v.refusal("cadaclysm_view_wake_ms"); err != nil {
		return 0, false, err
	}
	got := uint32(C.cv_wake_ms(v.lib.t, v.handle))
	if got == math.MaxUint32 {
		return 0, false, nil
	}
	return got, true, nil
}

func camera(c *C.CadaclysmViewCamera, p *C.CadaclysmViewPick, yUp bool) Camera {
	var out Camera
	for i := 0; i < 3; i++ {
		out.Eye[i], out.Target[i], out.Up[i] = float32(c.eye[i]), float32(c.target[i]), float32(c.up[i])
	}
	out.Orthographic = c.orthographic != 0
	var az, el C.double
	y := C.int(0)
	if yUp {
		y = 1
	}
	C.cvl_angles(c, y, &az, &el)
	out.Azimuth, out.Elevation = float64(az), float64(el)
	if p.item != 0 {
		pick := pickOf(p)
		out.Pick = &pick
	}
	return out
}

// Run blocks until the window is closed: the camera it was left at, and the last pick.
// The window is then closed (as Python's run): every call but Close refuses.
func (v *View) Run() (Camera, error) {
	if err := v.refusal("cadaclysm_view_run"); err != nil {
		return Camera{}, err
	}
	c := C.CadaclysmViewCamera{}
	c.size = C.uint32_t(unsafe.Sizeof(c))
	p := C.CadaclysmViewPick{}
	p.size = C.uint32_t(unsafe.Sizeof(p))
	if !bool(C.cv_run(v.lib.t, v.handle, &c, &p)) {
		return Camera{}, v.failed()
	}
	v.markClosed()
	return camera(&c, &p, v.yUp), nil
}

// Size is what Image reads, in physical pixels.
func (v *View) Size() (width, height uint32, err error) {
	var w, h C.uint32_t
	if err := v.ok("cadaclysm_view_size", func() C.bool { return C.cv_size(v.lib.t, v.handle, &w, &h) }); err != nil {
		return 0, 0, err
	}
	return uint32(w), uint32(h), nil
}

// Image draws one frame at the view's current size and reads it back.
func (v *View) Image() (*image.RGBA, error) {
	w, h, err := v.Size()
	if err != nil {
		return nil, err
	}
	if _, err := pixelBytes(w, h, "image"); err != nil {
		return nil, err
	}
	img := image.NewRGBA(image.Rect(0, 0, int(w), int(h)))
	at := &standInU8[0]
	if len(img.Pix) > 0 {
		at = (*C.uint8_t)(unsafe.Pointer(&img.Pix[0]))
	}
	if err := v.ok("cadaclysm_view_image", func() C.bool {
		return C.cv_image(v.lib.t, v.handle, at, C.size_t(len(img.Pix)))
	}); err != nil {
		return nil, err
	}
	return img, nil
}

// Save writes Image as a PNG.
func (v *View) Save(path string) error {
	img, err := v.Image()
	if err != nil {
		return err
	}
	cp := C.CString(path)
	defer C.free(unsafe.Pointer(cp))
	var msg [C.CVL_ERROR]C.char
	at := &standInU8[0]
	if len(img.Pix) > 0 {
		at = (*C.uint8_t)(unsafe.Pointer(&img.Pix[0]))
	}
	b := img.Bounds()
	if C.cvl_write_png(cp, at, C.uint32_t(b.Dx()), C.uint32_t(b.Dy()), &msg[0], C.CVL_ERROR) == 0 {
		return refused(C.GoString(&msg[0]))
	}
	return nil
}

// Event is a host's input, as CadaclysmViewEvent's fields (Kind: CADACLYSM_VIEW_EVENT_*).
// KeyDown is a key event's direction: false is the key going up.
type Event struct {
	Kind, PointerID, Pointer, Button uint32
	Shift                            bool
	X, Y, WheelY                     float32
	Key                              string
	KeyDown                          bool
	TimeMS                           float64
}

// Input hands the view's gesture handler an event: the CADACLYSM_VIEW_INPUT_* bits. On a
// window of the view's own the close bit (Escape) closes it, as the user closing it does;
// Close still owes the destroy.
func (v *View) Input(e Event) (uint32, error) {
	if err := v.refusal("cadaclysm_view_input"); err != nil {
		return 0, err
	}
	raw := C.CadaclysmViewEvent{}
	raw.size = C.uint32_t(unsafe.Sizeof(raw))
	raw.kind, raw.pointer_id, raw.pointer, raw.button = C.uint32_t(e.Kind), C.uint32_t(e.PointerID), C.uint32_t(e.Pointer), C.uint32_t(e.Button)
	if e.Shift {
		raw.shift = 1
	}
	raw.x, raw.y, raw.wheel_y = C.float(e.X), C.float(e.Y), C.float(e.WheelY)
	if e.Key != "" {
		k := C.CString(e.Key)
		defer C.free(unsafe.Pointer(k))
		raw.key = k
	}
	if e.KeyDown {
		raw.key_down = 1
	}
	raw.time_ms = C.double(e.TimeMS)
	bits := uint32(C.cv_input(v.lib.t, v.handle, &raw))
	if bits == 0 && v.said() {
		return 0, v.failed()
	}
	if bits&C.CADACLYSM_VIEW_INPUT_CLOSE != 0 && v.own {
		v.markClosed()
	}
	return bits, nil
}

// Resize sets the view's size in physical pixels.
func (v *View) Resize(width, height uint32) error {
	return v.ok("cadaclysm_view_resize", func() C.bool {
		return C.cv_resize(v.lib.t, v.handle, C.uint32_t(width), C.uint32_t(height))
	})
}

// NeedsDraw is whether the view owes a frame.
func (v *View) NeedsDraw() (bool, error) {
	if err := v.refusal("cadaclysm_view_needs_draw"); err != nil {
		return false, err
	}
	return bool(C.cv_needs_draw(v.lib.t, v.handle)), nil
}

// Pump handles the events of every open window of this thread's own (New, on the wgpu
// library), draws what is owed, waits at most timeout (negative: none; capped at
// 2^32-1 ms): the number of such windows of every goroutine still open -- for a program's
// own loop. Call it from the goroutine that made the windows. As Python's pump: with none
// of this thread's own it just waits timeout, so a loop around it does not spin; a window
// whose pump failed stays open; every window is pumped before the first failure is
// returned.
func Pump(timeout time.Duration) (int, error) {
	ms := uint32(0)
	if timeout > 0 {
		if timeout/time.Millisecond >= math.MaxUint32 {
			ms = math.MaxUint32
		} else {
			ms = uint32(timeout / time.Millisecond)
		}
	}
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	me := thread()
	viewsMu.Lock()
	var alive []*View
	for _, v := range views {
		if v.pumped && v.handle != nil && !v.closed && v.thread == me {
			alive = append(alive, v)
		}
	}
	viewsMu.Unlock()
	var first error
	if len(alive) == 0 {
		if ms > 0 {
			time.Sleep(time.Duration(ms) * time.Millisecond)
		}
	} else {
		for i, v := range alive {
			wait := C.uint32_t(0)
			if i == 0 {
				wait = C.uint32_t(ms)
			}
			switch C.cv_pump(v.lib.t, v.handle, wait) {
			case C.CADACLYSM_VIEW_OPEN:
			case C.CADACLYSM_VIEW_CLOSED:
				v.markClosed()
			default:
				if first == nil {
					first = v.failed()
				}
			}
		}
	}
	viewsMu.Lock()
	open := 0
	for _, v := range views {
		if v.pumped && v.handle != nil && !v.closed {
			open++
		}
	}
	viewsMu.Unlock()
	return open, first
}

// same is owner == o, for owners whose type can be compared.
func same(owner, o any) bool {
	if o == nil || reflect.TypeOf(o) != reflect.TypeOf(owner) || !reflect.TypeOf(o).Comparable() {
		return false
	}
	return o == owner
}

// Release removes every item showing owner (a Scene or a Solid shown by handle) from the
// views of the calling goroutine's thread -- a view whose window the user closed is closed
// now, the Close it owed anyway -- before owner's handle is freed: Scene.Close calls it
// first. A view of another thread cannot be called from this one, so when one still shows
// owner this returns Python's refusal after this thread's views are done, and the caller
// keeps owner open (it leaks rather than crashes).
func Release(owner any) error {
	if owner == nil {
		return nil
	}
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	me := thread()
	type shown struct {
		v   *View
		ids []uint32
	}
	var mine []shown
	foreign := 0
	viewsMu.Lock()
	for _, v := range views {
		if v.handle == nil {
			continue
		}
		var ids []uint32
		for id, o := range v.owners {
			if same(owner, o) {
				ids = append(ids, id)
			}
		}
		if len(ids) == 0 {
			continue
		}
		if v.thread != me {
			foreign++
		} else {
			mine = append(mine, shown{v, ids})
		}
	}
	viewsMu.Unlock()
	for _, s := range mine {
		if s.v.closed {
			s.v.Close()
			continue
		}
		for _, id := range s.ids {
			C.cv_remove(s.v.lib.t, s.v.handle, C.uint32_t(id))
			s.v.forget(id)
		}
	}
	if foreign > 0 {
		return refused(fmt.Sprintf("%d view(s) made on another thread still show this -- close them from their own "+
			"thread first; it stays open until then", foreign))
	}
	return nil
}

// ---- Show/View on the objects ---------------------------------------------------------

// ShowOptions are Show/View's keywords, as Python's; nil or zero values are the defaults.
// View is front, back, left, right, top, bottom or iso ("": iso); Azimuth/Elevation
// override it; Zoom is a multiple of the fit (0: the fit); Up "y" or "z" ("": the scene's
// own up axis, "z" for a solid); NoEdges hides the B-rep edges; Width and Height are the
// window's (0: the library's); Hint is the terminal's graphics protocol for this draw;
// Title ("": the scene's file name, "Solid" for a solid); Tolerance is a solid's (0: 0.05)
// and refused for a Scene, Node or Pose, which is drawn at the tolerance it was read with.
type ShowOptions struct {
	View               string
	Azimuth, Elevation *float64
	Zoom               float64
	Up                 string
	NoEdges            bool
	Width, Height      uint32
	Hint, Title        string
	Tolerance          float64
}

// Focus narrows a scene to one node: every node in Hide hidden (the siblings along the
// path from the node's root down to it), Node framed.
type Focus struct {
	Node uint32
	Hide []uint32
}

// draw is show()/view() on an object: a fresh view of it (cvl_draw_object). The wgpu
// library runs its window for both; any other prints a still for Show (interactive false)
// and runs for View. cvl_draw_object flushes C stdio first, as Python flushes before a
// still; Go's own os.Stdout and os.Stderr are unbuffered, so nothing of Go's waits.
func draw(solid, scene unsafe.Pointer, tolerance float64, transforms [][16]float64, label, defaultUp string,
	focus *Focus, o *ShowOptions, interactive bool) (Camera, error) {
	if o == nil {
		o = &ShowOptions{}
	}
	up := o.Up
	if up == "" {
		up = defaultUp
	}
	if up != "y" && up != "z" {
		return Camera{}, refused(fmt.Sprintf("up '%s': 'y' or 'z'", up))
	}
	posedCount, err := count(len(transforms), "node_transforms")
	if err != nil {
		return Camera{}, err
	}
	node := C.uint32_t(C.CVL_NO_NODE)
	hide := &standInU32[0]
	var hideCount C.uint32_t
	if focus != nil {
		node = C.uint32_t(focus.Node)
		hide = uint32s(focus.Hide)
		if hideCount, err = count(len(focus.Hide), "hide"); err != nil {
			return Camera{}, err
		}
	}
	lib, err := Current()
	if err != nil {
		return Camera{}, err
	}
	cs := C.CvlShow{}
	var strs []*C.char
	cstr := func(s string) *C.char {
		if s == "" {
			return nil
		}
		c := C.CString(s)
		strs = append(strs, c)
		return c
	}
	defer func() {
		for _, c := range strs {
			C.free(unsafe.Pointer(c))
		}
	}()
	title := o.Title
	if title == "" {
		title = label
	}
	cs.view, cs.title, cs.hint = cstr(o.View), cstr(title), cstr(o.Hint)
	cs.width, cs.height = C.uint32_t(o.Width), C.uint32_t(o.Height)
	if up == "y" {
		cs.y_up = 1
	}
	cs.azimuth, cs.elevation = C.double(math.NaN()), C.double(math.NaN())
	if o.Azimuth != nil {
		cs.azimuth = C.double(*o.Azimuth)
	}
	if o.Elevation != nil {
		cs.elevation = C.double(*o.Elevation)
	}
	cs.zoom = C.double(o.Zoom)
	if !o.NoEdges {
		cs.edges = 1
	}
	cs.no_display = noDisplay
	var posed *C.double // nil: no pose
	if transforms != nil {
		posed = &standInF64[0]
		if len(transforms) > 0 {
			posed = (*C.double)(unsafe.Pointer(&transforms[0][0]))
		}
	}
	c := C.CadaclysmViewCamera{}
	c.size = C.uint32_t(unsafe.Sizeof(c))
	p := C.CadaclysmViewPick{}
	p.size = C.uint32_t(unsafe.Sizeof(p))
	mode := C.int(0)
	if interactive {
		mode = 1
	}
	defaultView := cstr("iso")
	var msg [C.CVL_ERROR]C.char
	runtime.LockOSThread() // the view lives and dies inside the call, on this thread
	defer runtime.UnlockOSThread()
	if C.cv_draw_object(lib.t, mode, defaultView, solid, C.double(tolerance), scene, posed, posedCount, hide, hideCount,
		node, &cs, &c, &p, &msg[0], C.CVL_ERROR) == 0 {
		return Camera{}, refused(C.GoString(&msg[0]))
	}
	return camera(&c, &p, up == "y"), nil
}

// noTolerance is Python's refusal of a tolerance for a document, in Go's method names.
func noTolerance(kind string, o *ShowOptions, interactive bool) error {
	if o == nil || o.Tolerance == 0 {
		return nil
	}
	call := ".Show"
	if interactive {
		call = ".View"
	}
	return refused(kind + call + " takes no tolerance: a document is drawn at the tolerance it was read with")
}

// DrawSolid is Solid.Show (interactive false) and Solid.View (true).
func DrawSolid(s Solid, o *ShowOptions, interactive bool) (Camera, error) {
	h := s.SolidHandle()
	if h == nil {
		return Camera{}, refused("solid: closed")
	}
	defer runtime.KeepAlive(s)
	tolerance := 0.05
	if o != nil && o.Tolerance != 0 {
		tolerance = o.Tolerance
	}
	return draw(h, nil, tolerance, nil, "Solid", "z", nil, o, interactive)
}

// DrawScene is Scene.Show/View and, with a Focus, Node.Show/View: label is the window's
// title (the file's name), defaultUp the scene's own up axis.
func DrawScene(s Scene, label, defaultUp string, focus *Focus, o *ShowOptions, interactive bool) (Camera, error) {
	kind := "Scene"
	if focus != nil {
		kind = "Node"
	}
	if err := noTolerance(kind, o, interactive); err != nil {
		return Camera{}, err
	}
	h := s.SceneHandle()
	if h == nil {
		return Camera{}, refused(label + ": the scene is closed")
	}
	defer runtime.KeepAlive(s)
	return draw(nil, h, 0, nil, label, defaultUp, focus, o, interactive)
}

// DrawPose is Pose.Show/View: the scene by handle, every node at its posed transform
// (cadaclysm_view_set_node_transforms), as Python's Pose.show.
func DrawPose(s Scene, label, defaultUp string, transforms [][16]float64, o *ShowOptions, interactive bool) (Camera, error) {
	if err := noTolerance("Pose", o, interactive); err != nil {
		return Camera{}, err
	}
	h := s.SceneHandle()
	if h == nil {
		return Camera{}, refused(label + ": the scene is closed")
	}
	defer runtime.KeepAlive(s)
	if transforms == nil {
		transforms = [][16]float64{} // a pose: reaches the library, which refuses a wrong count
	}
	return draw(nil, h, 0, transforms, label, defaultUp, nil, o, interactive)
}
