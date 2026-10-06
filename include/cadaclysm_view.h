/* cadaclysm_view - the Cadaclysm viewer in a host's window, over a C ABI. Generated; do not edit. */

#ifndef CADACLYSM_VIEW_H
#define CADACLYSM_VIEW_H



#include <stdbool.h>
#include <stdint.h>
typedef struct CadaclysmScene CadaclysmScene;
typedef struct CadaclysmBlacksmithSolid CadaclysmBlacksmithSolid;

#define CADACLYSM_VIEW_ABI_MAJOR 1

#define CADACLYSM_VIEW_ABI_MINOR 4

#define CADACLYSM_VIEW_WINDOW_WIN32 1

#define CADACLYSM_VIEW_WINDOW_XLIB 2

#define CADACLYSM_VIEW_WINDOW_XCB 3

#define CADACLYSM_VIEW_WINDOW_WAYLAND 4

#define CADACLYSM_VIEW_WINDOW_APPKIT 5

#define CADACLYSM_VIEW_SURFACES_EXACT 0

#define CADACLYSM_VIEW_SURFACES_TRIANGLES 1

#define CADACLYSM_VIEW_BACKEND_ANY 0

#define CADACLYSM_VIEW_BACKEND_VULKAN 1

#define CADACLYSM_VIEW_BACKEND_D3D12 2

#define CADACLYSM_VIEW_BACKEND_METAL 3

#define CADACLYSM_VIEW_STANDARD_TOP 0

#define CADACLYSM_VIEW_STANDARD_FRONT 1

#define CADACLYSM_VIEW_STANDARD_RIGHT 2

#define CADACLYSM_VIEW_STANDARD_ISO 3

#define CADACLYSM_VIEW_LAYER_SURFACES 0

#define CADACLYSM_VIEW_LAYER_EDGES 1

#define CADACLYSM_VIEW_LAYER_CURVES 2

#define CADACLYSM_VIEW_LAYER_ISOCURVES 3

#define CADACLYSM_VIEW_LAYER_GRID 4

#define CADACLYSM_VIEW_GRID_NONE 0

#define CADACLYSM_VIEW_GRID_TOP 1

#define CADACLYSM_VIEW_GRID_FRONT 2

#define CADACLYSM_VIEW_GRID_RIGHT 3

#define CADACLYSM_VIEW_EVENT_DOWN 1

#define CADACLYSM_VIEW_EVENT_MOVE 2

#define CADACLYSM_VIEW_EVENT_UP 3

#define CADACLYSM_VIEW_EVENT_CANCEL 4

#define CADACLYSM_VIEW_EVENT_WHEEL 5

#define CADACLYSM_VIEW_EVENT_KEY 6

#define CADACLYSM_VIEW_POINTER_MOUSE 0

#define CADACLYSM_VIEW_POINTER_TOUCH 1

#define CADACLYSM_VIEW_POINTER_PEN 2

#define CADACLYSM_VIEW_BUTTON_LEFT 0

#define CADACLYSM_VIEW_BUTTON_MIDDLE 1

#define CADACLYSM_VIEW_BUTTON_RIGHT 2

/**
 * The user asked to close (Escape).
 */
#define CADACLYSM_VIEW_INPUT_CLOSE 1

/**
 * A pick was asked: its answer comes from `cadaclysm_view_pick_result`, which the host calls
 * after its draws until it answers. `cadaclysm_view_needs_draw` stays true until that call
 * takes the answer, and a double click frames what it hit only when it does.
 */
#define CADACLYSM_VIEW_INPUT_PICKED 2

/**
 * `cadaclysm_view_pump`: the view's own window is open.
 */
#define CADACLYSM_VIEW_OPEN 1

/**
 * `cadaclysm_view_pump`: the view's own window was closed (Escape or its close button).
 * Item and camera calls then fail with "the window is closed"; `cadaclysm_view_destroy` is
 * still owed.
 */
#define CADACLYSM_VIEW_CLOSED 2

/**
 * `CadaclysmViewLod.motion`: every frame drawn whole, but for levels within half a pixel.
 */
#define CADACLYSM_VIEW_LOD_DETAILED 0

/**
 * `CadaclysmViewLod.motion`: the frame rate held while moving, refined at rest.
 */
#define CADACLYSM_VIEW_LOD_SMOOTH 1

/**
 * One view. Opaque to C. It must be used from one thread only, the one that drives its
 * window (on AppKit, the main thread).
 */
typedef struct CadaclysmView CadaclysmView;

/**
 * The host's native window. The window must outlive the view.
 */
typedef struct CadaclysmViewWindow {
  /**
   * `sizeof` the struct as the caller built it; fields past it take their defaults.
   */
  uint32_t size;
  /**
   * `CADACLYSM_VIEW_WINDOW_*`.
   */
  uint32_t kind;
  /**
   * HWND, `wl_surface*`, `NSView*`; unused for Xlib and XCB.
   */
  void *window;
  /**
   * Xlib `Window`, `xcb_window_t`; unused otherwise.
   */
  uint64_t window_id;
  /**
   * HINSTANCE, `Display*`, `xcb_connection_t*`, `wl_display*`; NULL on AppKit.
   */
  void *display;
  /**
   * The window's current client size in physical pixels (a Qt host multiplies its
   * logical size by `devicePixelRatio`). Pass the size the native window actually has
   * once it is mapped: on Qt, that is the first `paintEvent`, not `showEvent` -- at
   * `showEvent` the native window can still lag Qt's own layout, and a swapchain made
   * at a stale size is invalid on Vulkan.
   */
  uint32_t width;
  uint32_t height;
} CadaclysmViewWindow;

/**
 * How the view draws, chosen at create. Zeroed fields are the defaults.
 */
typedef struct CadaclysmViewOptions {
  /**
   * `sizeof` the struct as the caller built it; fields past it take their defaults.
   */
  uint32_t size;
  /**
   * `CADACLYSM_VIEW_SURFACES_*`, default EXACT.
   */
  uint32_t surfaces;
  /**
   * `CADACLYSM_VIEW_BACKEND_*`, default ANY: ANY honours the `CADACLYSM_VIEW_BACKEND`
   * environment variable where it is set (`gl` or `vulkan`, any other value refused),
   * then `CADACLYSM_WGPU_BACKEND`, else picks the platform's best backend.
   */
  uint32_t backend;
  /**
   * 0: Z up (default), 1: Y up.
   */
  uint32_t y_up;
  /**
   * UTF-8; NULL: "Cadaclysm". The own window's title (1.2): read only when
   * `cadaclysm_view_create` is given no window.
   */
  const char *title;
  /**
   * The own window's client size in logical pixels (1.2); 0: 1280 x 800. Read only when
   * `cadaclysm_view_create` is given no window.
   */
  uint32_t width;
  uint32_t height;
  /**
   * 1.4: with `cadaclysm_view_create` given no window, 1 makes a view with no window at
   * all -- a headless renderer `width` x `height` (0: 1280 x 800), drawn and read back with
   * `cadaclysm_view_image`; no display is needed, a GPU adapter is. `run` and `pump` refuse
   * it. 0 (the default): a window of the view's own. The terminal library refuses 1.
   */
  uint32_t offscreen;
} CadaclysmViewOptions;

/**
 * The camera the view ended on when `cadaclysm_view_run` returned, 1.2.
 */
typedef struct CadaclysmViewCamera {
  /**
   * `sizeof` the struct as the caller built it; at least the 1.2 struct's.
   */
  uint32_t size;
  float eye[3];
  float target[3];
  float up[3];
  /**
   * 0 or 1.
   */
  uint32_t orthographic;
} CadaclysmViewCamera;

/**
 * A pick's answer (`cadaclysm_view_pick_result`).
 */
typedef struct CadaclysmViewPick {
  /**
   * `sizeof` the struct as the caller built it; at least the 1.0 struct's.
   */
  uint32_t size;
  /**
   * 0: nothing under the pixel.
   */
  uint32_t item;
  /**
   * What a click should select: `cadaclysm_placement_select` of the drawing hit.
   */
  uint32_t node;
  /**
   * The item's face under the pixel (its pick numbering); 0 where the item has none.
   */
  uint32_t face;
} CadaclysmViewPick;

/**
 * Levels of detail, as `cadaclysm_view_set_lod` takes them (1.4).
 */
typedef struct CadaclysmViewLod {
  /**
   * `sizeof` the struct as the caller built it; at least the 1.4 struct's.
   */
  uint32_t size;
  /**
   * Parts with fewer triangles get no levels; 0: 2048.
   */
  uint32_t min_triangles;
  /**
   * `CADACLYSM_VIEW_LOD_*`, default DETAILED.
   */
  uint32_t motion;
} CadaclysmViewLod;

/**
 * One rectangle of the window and the camera the caller computed for it
 * (`cadaclysm_view_set_viewports`).
 */
typedef struct CadaclysmViewViewport {
  /**
   * `sizeof` the struct as the caller built it; every element of the array must carry
   * the same `size`.
   */
  uint32_t size;
  /**
   * x, y, width, height in physical pixels from the top left.
   */
  uint32_t rect[4];
  /**
   * World to eye, column-major.
   */
  float view[16];
  /**
   * Eye to clip, column-major, depth 0 near 1 far.
   */
  float projection[16];
  float eye[3];
  /**
   * `CADACLYSM_VIEW_GRID_*`.
   */
  uint32_t grid;
} CadaclysmViewViewport;

/**
 * One raw input event (`cadaclysm_view_input`): the same gesture handler every surface
 * feeds -- the own window, the web, and a host through this ABI.
 */
typedef struct CadaclysmViewEvent {
  /**
   * `sizeof` the struct as the caller built it; fields past it take their defaults.
   */
  uint32_t size;
  /**
   * `CADACLYSM_VIEW_EVENT_*`.
   */
  uint32_t kind;
  uint32_t pointer_id;
  /**
   * `CADACLYSM_VIEW_POINTER_*`.
   */
  uint32_t pointer;
  /**
   * `CADACLYSM_VIEW_BUTTON_*`; a Down event's only.
   */
  uint32_t button;
  /**
   * A Down event's only: whether Shift was held.
   */
  uint32_t shift;
  /**
   * Physical pixels from the window's top left.
   */
  float x;
  float y;
  /**
   * The wheel's deltaY: negative is forward.
   */
  float wheel_y;
  /**
   * A Key event's only: `KeyboardEvent.code`, e.g. "KeyT"; UTF-8, NUL-terminated.
   */
  const char *key;
  /**
   * A Key event's only: whether the key went down (true) or up (false).
   */
  uint32_t key_down;
  /**
   * Any monotonic clock, milliseconds: a Down or Up event's only.
   */
  double time_ms;
} CadaclysmViewEvent;

/**
 * A mesh of plain arrays, copied in when shown: positions, optional normals, triangles,
 * optional edge segments, an optional colour.
 */
typedef struct CadaclysmViewMesh {
  /**
   * `sizeof` the struct as the caller built it; fields past it take their defaults.
   */
  uint32_t size;
  /**
   * Three floats a vertex.
   */
  const float *positions;
  uint32_t vertex_count;
  /**
   * NULL, or three a vertex.
   */
  const float *normals;
  /**
   * Three a triangle.
   */
  const uint32_t *indices;
  uint32_t index_count;
  /**
   * Six floats a segment; NULL, 0 for none.
   */
  const float *edges;
  uint32_t edge_count;
  /**
   * NULL: the default colour.
   */
  const float *rgb;
} CadaclysmViewMesh;

/**
 * A reference image on a quad, copied in when shown.
 */
typedef struct CadaclysmViewImage {
  /**
   * `sizeof` the struct as the caller built it; fields past it take their defaults.
   */
  uint32_t size;
  /**
   * bottom-left, bottom-right, top-right, top-left
   */
  float corners[12];
  /**
   * rows top first
   */
  const uint8_t *rgba;
  uint32_t width;
  uint32_t height;
  /**
   * 0..1; 0 in a zeroed struct means 1
   */
  float opacity;
  uint32_t flip_x;
  uint32_t flip_y;
} CadaclysmViewImage;

#ifdef __cplusplus
extern "C" {
#endif // __cplusplus

/**
 * `(CADACLYSM_VIEW_ABI_MAJOR << 16) | CADACLYSM_VIEW_ABI_MINOR` of this library.
 */
uint32_t cadaclysm_view_abi_version(void);

/**
 * Why this thread's last call failed; "" after one that did not. Valid until this thread's
 * next call.
 */
const char *cadaclysm_view_last_error(void);

/**
 * Which library this is, and its version: "cadaclysm-view <version>" (this library, wgpu) or
 * "cadaclysm-terminal <version>" (the terminal's), so a wrapper knows what it loaded (1.3).
 * Static; never NULL.
 */
const char *cadaclysm_view_name(void);

/**
 * A view drawing into `window`. A view needs no reader: a scene needs `cadaclysm_capi`
 * loaded when it is shown. NULL on failure, with the reason: no adapter of the asked backend
 * for the window, a bad struct.
 * `options` NULL: every default. On AppKit, create the view and draw it on the main thread.
 * Create it once the window is mapped at its final size: on Qt, that is the first
 * `paintEvent`, not `showEvent`.
 *
 * `window` NULL: the library opens a window of its own (1.2), titled and sized by
 * `options`, and `cadaclysm_view_pump` keeps it answering. Refused with "no display for a
 * window of the view's own" where none is reachable (no `DISPLAY` or `WAYLAND_DISPLAY` on
 * Linux), and with "own windows belong to the thread that made the first one" on any
 * thread but the one whose windowless create came first; on macOS, that is the main thread.
 * The terminal library (`cadaclysm_terminal`) draws only to the process's own terminal: a
 * `window` is refused ("the terminal draws only to its own output"), and `window` NULL probes
 * the terminal once (its graphics protocol and cell size). A `width` of 0 is the terminal's
 * width; a `height` of 0 is 1280 x 800's aspect of the width, capped (the width scaled with
 * it) so the picture, its caption and a spare row fit the screen. `title` is the picture's
 * caption (NULL: "Cadaclysm"); the environment variable `CADACLYSM_TERMINAL_GRAPHICS` forces
 * `sixel`, `kitty` or `blocks`.
 *
 * With `options->offscreen` 1 (1.4) and `window` NULL: a view with no window, `width` x
 * `height` (0: 1280 x 800), needing no display -- drawn with `cadaclysm_view_draw` and read
 * with `cadaclysm_view_image`; `run` and `pump` refuse it. The terminal library refuses it.
 *
 * `window` must be NULL or point at a `CadaclysmViewWindow`; `options` must be NULL or
 * point at a `CadaclysmViewOptions`.
 */
struct CadaclysmView *cadaclysm_view_create(const struct CadaclysmViewWindow *window,
                                            const struct CadaclysmViewOptions *options);

/**
 * Frees the view, and closes its own window if it has one. NULL is allowed. A view with a
 * window of its own is freed only on the thread that made it; elsewhere it is kept, with
 * the reason.
 *
 * `view` must be NULL or from `cadaclysm_view_create`, and is not used again.
 */
void cadaclysm_view_destroy(struct CadaclysmView *view);

/**
 * Handles pending events for every open window of a view's own, draws what is owed, and
 * waits at most `timeout_ms` for events. `CADACLYSM_VIEW_OPEN`, or `CADACLYSM_VIEW_CLOSED`
 * once this view's window is closed (Escape or its close button); 0 on a refusal: only a
 * view with a window of its own is pumped, and only on the thread that made it. A closed
 * view's pump still handles the other own windows and waits, then answers CLOSED.
 *
 * The terminal library: one live picture at the bottom of the output, redrawn in place when
 * the view needs a draw -- unless something was written after it (a script's `print`, a
 * still, another view), which then keeps it and gets a fresh picture below. Raw mode and
 * mouse reporting are on only during the call, and the cursor reports it asks for are read
 * inside it, so a script's own output and `input()` between pumps behave normally; a
 * terminal that does not answer them is drawn over in place, with no mouse. The bytes read
 * go through the gesture handler. `CADACLYSM_VIEW_OPEN`, or `CADACLYSM_VIEW_CLOSED` after `q`
 * or Escape; a closed view's pump reads and writes nothing. Where stdout is not a terminal
 * (piped, CI), one still is printed and the answer is `CADACLYSM_VIEW_CLOSED`. Only a view
 * made with no window is pumped.
 *
 * Picks, the host's and the window's own clicks alike, land as the pump draws; each answer
 * waits for `cadaclysm_view_pick_result` (a newer one replaces it), and a double click
 * frames what it hit as its answer lands. The thread that makes the first own window must
 * outlive them: once it has exited, own windows are unavailable for the rest of the process.
 * A panic inside the pump (in a draw, say) is caught and reported, but leaves that window's
 * view in an unknown state. `view` must be NULL or a live view.
 */
uint32_t cadaclysm_view_pump(struct CadaclysmView *view, uint32_t timeout_ms);

/**
 * Blocks until the user closes the view's window (sharing the loop this view's window pumps
 * with every other own window), drawing on demand and waiting otherwise. Then fills
 * `camera_out` with the camera the view ended on (`eye`, `target`, `up`, `orthographic`) and
 * `pick_out` with the last pick that landed while this call ran (`item` 0, the rest 0, for
 * none), taking it -- a later `cadaclysm_view_pick_result` or `run` does not report it again.
 * A pick still in flight when the window closes is not landed and so is not reported at all.
 * Either out may be NULL, and neither out's own `size` is ever changed -- only the fields
 * after it -- so a host reusing the same struct across calls (a REPL's `run` in a loop)
 * keeps reading back the size it put there. Only for a view made with no window; false with
 * the reason on a refusal, as `cadaclysm_view_pump`'s -- including "the window is closed" for
 * a view whose window closed before this call. Can be called again later in the same
 * process, also after `pump`.
 *
 * The terminal library: the alternate screen and the orbit loop, through the gesture
 * handler -- drag orbits, right or Shift drag pans, the wheel zooms, `t` `f` `r` `i` the
 * standard views, Space frames all, `o` orthographic, `x` exact surfaces, `e` edges, `s` saves
 * `cadaclysm-view.png`, a click picks. `q` or Escape leaves; the last still is printed into
 * the scrollback and the camera and last pick are returned. The view stays open. Where
 * stdout is not a terminal, one still is printed and the call returns true at once.
 *
 * `view` must be NULL or a live view; `camera_out` must be NULL or point at a
 * `CadaclysmViewCamera` of at least `camera_out->size` bytes; `pick_out` must be NULL or
 * point at a `CadaclysmViewPick` of at least `pick_out->size` bytes.
 */
bool cadaclysm_view_run(struct CadaclysmView *view,
                        struct CadaclysmViewCamera *camera_out,
                        struct CadaclysmViewPick *pick_out);

/**
 * The window's new size in physical pixels (a Qt host multiplies its logical size by
 * `devicePixelRatio`). False for a NULL view or a zero size.
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_resize(struct CadaclysmView *view, uint32_t width, uint32_t height);

/**
 * Whether a draw is owed: a change, an upload or exact refinement still settling, a
 * pick waiting for its answer. True, too, while the device is lost or the document is
 * still owed to a rebuilt one: the next `cadaclysm_view_draw` rebuilds or re-uploads.
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_needs_draw(const struct CadaclysmView *view);

/**
 * Draws and presents to the window. On AppKit, call it on the main thread. False with a
 * reason where the device was lost and could not be rebuilt yet (the next draw tries
 * again), or where this draw lost the device or the GPU reported an error while drawing.
 * A loss is reported once, by the draw that finds it; the next draw rebuilds the device.
 * While the rebuild itself keeps failing, each draw returns false with the rebuild's
 * reason. A rebuild, or a retried re-upload onto a rebuilt device, drops a pick in flight
 * (`cadaclysm_view_request_pick`) -- its readback lived on the lost device and would never
 * land; the host asks again. False, too, from the third draw in a row whose window gave
 * no frame to present (usually a `cadaclysm_view_resize` size that is not the window's
 * current client size) until a frame is presented or the view is resized.
 *
 * An offscreen view (1.4): renders without presenting -- nothing is shown anywhere -- and
 * lands a pick in flight, as a window's draw does; read the frame with `cadaclysm_view_image`.
 *
 * The terminal library: prints one still -- the picture and a caption -- into the
 * scrollback (as sixel where stdout is not a terminal).
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_draw(struct CadaclysmView *view);

/**
 * The size `cadaclysm_view_image` writes, in physical pixels: the view's drawing size, as
 * `cadaclysm_view_resize` last set it (1.4). False for a NULL out.
 *
 * `view` must be NULL or a live view; `width` and `height` NULL or writable.
 */
bool cadaclysm_view_size(struct CadaclysmView *view, uint32_t *width, uint32_t *height);

/**
 * Draws one frame at the view's size (`cadaclysm_view_size`) and writes it to `rgba`:
 * `width * height * 4` bytes, RGBA8, rows from the top (1.4). Synchronous: it waits for the
 * GPU. Every view: an offscreen one, the own window, a host's window (the frame is drawn
 * apart from what the window presents). False where `capacity` is too small (the reason says
 * how many bytes are needed) or `rgba` is NULL. The terminal library reads its picture from
 * its CPU raster.
 *
 * `view` must be NULL or a live view; `rgba` NULL or `capacity` writable bytes.
 */
bool cadaclysm_view_image(struct CadaclysmView *view, uint8_t *rgba, size_t capacity);

/**
 * Shows `scene` (from `cadaclysm_open`). The item's id, 0 on failure. The scene must stay
 * open until the item is removed or the view destroyed: exact parts are built from it when
 * the surfaces mode changes. Fails, with the reason, where `cadaclysm_capi` is not loaded in
 * the process or is a reader too old for this library (it lacks a call the view reads
 * through); a reader loaded later is found by the next call.
 *
 * `view` must be NULL or a live view; `scene` must be NULL or a live scene of the loaded reader.
 */
uint32_t cadaclysm_view_show(struct CadaclysmView *view, const CadaclysmScene *scene);

/**
 * Takes an item away. False where it is not shown, or where uploading what remains failed
 * (the item is gone all the same).
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_remove(struct CadaclysmView *view, uint32_t item);

/**
 * `CADACLYSM_VIEW_SURFACES_EXACT` or `_TRIANGLES`. False for another value.
 *
 * The terminal library: accepted with a difference -- it has no exact pass, so
 * `CADACLYSM_VIEW_SURFACES_EXACT` is taken but `cadaclysm_view_surfaces` still reads back
 * `CADACLYSM_VIEW_SURFACES_TRIANGLES`, and every surface draws as triangles.
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_set_surfaces(struct CadaclysmView *view, uint32_t surfaces);

/**
 * What draws: `_EXACT` only where it was asked for and the device draws it.
 * `CADACLYSM_VIEW_SURFACES_TRIANGLES` for a NULL view.
 *
 * `view` must be NULL or a live view.
 */
uint32_t cadaclysm_view_surfaces(const struct CadaclysmView *view);

/**
 * Orbits the camera by a drag of `dx`, `dy` pixels (in orthographic, pans). A non-finite
 * delta is ignored.
 *
 * `view` must be NULL or a live view.
 */
void cadaclysm_view_orbit(struct CadaclysmView *view, float dx, float dy);

/**
 * Pans the camera by a drag of `dx`, `dy` pixels. A non-finite delta is ignored.
 *
 * `view` must be NULL or a live view.
 */
void cadaclysm_view_pan(struct CadaclysmView *view, float dx, float dy);

/**
 * Zooms by `steps` wheel notches: positive zooms in. A non-finite value is ignored.
 *
 * `view` must be NULL or a live view.
 */
void cadaclysm_view_zoom(struct CadaclysmView *view, float steps);

/**
 * Fits the camera to `item`, or to everything shown for 0. False where the item is not
 * shown, or there is nothing to fit.
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_frame(struct CadaclysmView *view, uint32_t item);

/**
 * A standard view, `CADACLYSM_VIEW_STANDARD_*`: top looks down the up axis. False for
 * another value.
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_standard(struct CadaclysmView *view, uint32_t which);

/**
 * An orthographic camera (`true`) or a perspective one.
 *
 * `view` must be NULL or a live view.
 */
void cadaclysm_view_set_orthographic(struct CadaclysmView *view, bool on);

/**
 * Switches a layer, `CADACLYSM_VIEW_LAYER_*`, on or off. False for another value.
 *
 * The terminal library: `CADACLYSM_VIEW_LAYER_EDGES` also switches `CADACLYSM_VIEW_LAYER_CURVES`
 * (an SDK's B-rep edges are drawn there as curves, so the two must move together for `on`/`off`
 * to mean "the drawing's edges"); `CADACLYSM_VIEW_LAYER_GRID` is accepted but draws nothing.
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_set_layer(struct CadaclysmView *view, uint32_t layer, bool on);

/**
 * The colour the view is cleared to: `rgb`, three linear floats in 0..1 (clamped). A NULL
 * or non-finite colour is refused and changes nothing.
 *
 * `view` must be NULL or a live view; `rgb` must be NULL or point at 3 floats.
 */
void cadaclysm_view_set_background(struct CadaclysmView *view, const float *rgb);

/**
 * The view's level-of-detail policy, for the device the host runs on (1.4). NULL -- the
 * default -- builds no levels and draws every frame whole. Otherwise the view builds coarser
 * levels for every part of `lod->min_triangles` or more, in the background after each show,
 * and draws moving frames as `lod->motion` says: `CADACLYSM_VIEW_LOD_DETAILED` keeps every
 * frame whole but for levels within half a pixel; `CADACLYSM_VIEW_LOD_SMOOTH` holds the frame
 * rate while moving and refines the picture once the camera rests -- a host drawing on demand
 * then wakes at `cadaclysm_view_wake_ms`. `min_triangles` of 0 is the default threshold
 * (2048), not "every part". The terminal library accepts it and draws every part
 * whole, as before. False, changing nothing, for a NULL view, a `size` below the 1.4 struct's
 * or an unknown motion.
 *
 * `view` must be NULL or a live view; `lod` must be NULL or point at `lod->size` bytes.
 */
bool cadaclysm_view_set_lod(struct CadaclysmView *view, const struct CadaclysmViewLod *lod);

/**
 * Milliseconds until `cadaclysm_view_needs_draw` turns true by itself, rounded up: a resting
 * frame, chiefly under `CADACLYSM_VIEW_LOD_SMOOTH`, refining the picture once the camera
 * stops -- a `CADACLYSM_VIEW_LOD_DETAILED` view with levels adopted can owe one too, when a
 * frame drew levels coarser than the scene. A host drawing on demand sets a timer for it and
 * draws if `cadaclysm_view_needs_draw` then says so. A level build running on its thread
 * owes one when it finishes, and asks to be looked in on every 100 ms until then (the view's
 * own window is woken instead): the frame that adopts its levels frees the scene it held.
 * 0 when one is owed now; `UINT32_MAX`
 * when none is coming (and for a NULL view).
 *
 * `view` must be NULL or a live view.
 */
uint32_t cadaclysm_view_wake_ms(const struct CadaclysmView *view);

/**
 * Shows or hides `node` (the reader's node index) of `item` and its whole subtree. False
 * where the item is not shown or the node is out of range.
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_set_node_visible(struct CadaclysmView *view,
                                     uint32_t item,
                                     uint32_t node,
                                     bool visible);

/**
 * Colours `node` of `item` and its whole subtree: `rgba` four floats in 0..1 (clamped;
 * the alpha is not used), NULL clears. A node colour wins over the node's own; a face's
 * does not change. False where the item is not shown, the node is out of range, or a
 * component is not finite.
 *
 * `view` must be NULL or a live view; `rgba` must be NULL or point at 4 floats.
 */
bool cadaclysm_view_set_node_color(struct CadaclysmView *view,
                                   uint32_t item,
                                   uint32_t node,
                                   const float *rgba);

/**
 * Highlights `node` of `item` and its whole subtree: tinted toward `rgba`'s RGB by its
 * alpha, the strength (0 leaves the colour, 1 is the tint; each clamped into 0..1), over
 * whatever colour it draws in. NULL clears. False as `cadaclysm_view_set_node_color`.
 *
 * `view` must be NULL or a live view; `rgba` must be NULL or point at 4 floats.
 */
bool cadaclysm_view_set_node_highlight(struct CadaclysmView *view,
                                       uint32_t item,
                                       uint32_t node,
                                       const float *rgba);

/**
 * Splits the window into viewports, each drawn by the matrices it carries; NULL or 0 puts
 * back the built-in camera. While set, orbit, pan, zoom, look, dolly, frame and standard do
 * nothing. The array's stride is `viewports[0].size`; every element carries the same `size`.
 * False, changing nothing, for a mixed `size`, a value not finite, a grid not a
 * `CADACLYSM_VIEW_GRID_*`.
 *
 * The terminal library: refuses (false, changing nothing) more than one viewport; one
 * viewport is accepted and drawn over the whole picture.
 *
 * `view` must be NULL or a live view; `viewports` NULL or `count` elements of
 * `viewports[0].size` bytes each.
 */
bool cadaclysm_view_set_viewports(struct CadaclysmView *view,
                                  const struct CadaclysmViewViewport *viewports,
                                  uint32_t count);

/**
 * Asks what is under pixel (`x`, `y`) of viewport 0, in physical pixels from its top left
 * (a Qt host multiplies a mouse position by `devicePixelRatio`); `cadaclysm_view_request_pick_in(view, 0, x, y)`.
 *
 * `view` must be NULL or a live view.
 */
void cadaclysm_view_request_pick(struct CadaclysmView *view,
                                 uint32_t x,
                                 uint32_t y);

/**
 * Asks what is under pixel (`x`, `y`) of `viewport`, in physical pixels from its own top
 * left (the window's while no viewports are set, viewport 0 then being the built-in
 * camera). The answer comes on a later call to `cadaclysm_view_pick_result`, after a draw;
 * `cadaclysm_view_needs_draw` is true until it has. A pick requested before the view's
 * first draw, or naming a viewport past those set, answers nothing (`item` 0). A new
 * request replaces one still pending. A device loss during a draw drops the pick (its
 * readback lived on the lost device); the host asks again.
 *
 * `view` must be NULL or a live view.
 */
void cadaclysm_view_request_pick_in(struct CadaclysmView *view,
                                    uint32_t viewport,
                                    uint32_t x,
                                    uint32_t y);

/**
 * The answer to the last pick asked -- by `cadaclysm_view_request_pick`,
 * `cadaclysm_view_request_pick_in`, or `cadaclysm_view_input` (a click or double click,
 * reported by `CADACLYSM_VIEW_INPUT_PICKED`) -- true once, when it has landed: `out.item` 0
 * (and the rest 0) for nothing under the pixel. False, with "no pick result", while none
 * has landed or none was asked, or where a device loss dropped the pick in flight (the host
 * asks again); it never waits for the GPU. `out.size` must be at least the 1.0 struct's.
 *
 * Until this call takes a landed answer, `cadaclysm_view_needs_draw` stays true, so a host
 * that forwards input must call it after its draws once an input returned PICKED, even
 * where it does not use the answer. A double click's pick frames what it hit here, when this
 * call takes the answer -- for a view in a host's window. A view with a window of its own
 * frames it as the answer lands, during a `cadaclysm_view_pump` or `cadaclysm_view_run`,
 * since nothing else calls this to take it.
 *
 * `view` must be NULL or a live view; `out` must be NULL or point at a `CadaclysmViewPick` of
 * `out->size` bytes.
 */
bool cadaclysm_view_pick_result(struct CadaclysmView *view, struct CadaclysmViewPick *out);

/**
 * Fits the camera to `node` of `item` and its subtree. False where the item is not a shown
 * scene or the node is out of range.
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_frame_node(struct CadaclysmView *view, uint32_t item, uint32_t node);

/**
 * Turns the camera about its eye by a drag of `dx`, `dy` pixels (fly). Non-finite: ignored.
 *
 * `view` must be NULL or a live view.
 */
void cadaclysm_view_look(struct CadaclysmView *view, float dx, float dy);

/**
 * Scales the eye's distance by `ratio` (below 1 is closer), as a pinch does. Non-finite or
 * not positive: ignored.
 *
 * `view` must be NULL or a live view.
 */
void cadaclysm_view_dolly(struct CadaclysmView *view, float ratio);

/**
 * Hands the view's gesture handler one event -- the same handler the own window and the web
 * use, so a host that forwards its window's events gets the same gestures: the left button
 * orbits, the right (or Shift-left) pans, the wheel zooms, a click picks, a double click
 * frames what it hits, T/F/R/I standard views, O orthographic, X exact/triangles, Space
 * frames all, W/S/A/D/E/Q fly while held, Escape asks to close. What it asked of the host,
 * as `CADACLYSM_VIEW_INPUT_*` bits; 0 for an event that does nothing or is refused.
 *
 * A click or double click asks a pick and returns `CADACLYSM_VIEW_INPUT_PICKED`: the host
 * then calls `cadaclysm_view_pick_result` after its draws until it answers.
 * `cadaclysm_view_needs_draw` stays true until that call takes the answer, and a double
 * click frames what it hit only when it does.
 *
 * `view` must be NULL or a live view; `event` NULL or a `CadaclysmViewEvent` whose `key` is
 * NULL or UTF-8 text.
 */
uint32_t cadaclysm_view_input(struct CadaclysmView *view, const struct CadaclysmViewEvent *event);

/**
 * A mesh of the caller's arrays -- positions, optional normals, triangles, optional edge
 * segments -- in `rgb` (NULL: the default colour). The item's id, 0 on failure: a NULL or
 * undersized struct, a count that is not whole, an index past the vertices, a value that is
 * not finite. Copied in; `mesh` and its arrays are the caller's again when this returns.
 *
 * `view` must be NULL or a live view; `mesh` NULL or a `CadaclysmViewMesh` whose arrays hold
 * the counts it gives.
 */
uint32_t cadaclysm_view_show_mesh(struct CadaclysmView *view, const struct CadaclysmViewMesh *mesh);

/**
 * Straight segments, six floats each (two xyz points), drawn as one item on the curves
 * layer in `rgb` (NULL: the curves' colour). They never pick. The item's id, 0 on failure.
 *
 * `view` must be NULL or a live view; `segments` NULL or `segment_count * 6` floats; `rgb`
 * NULL or three floats.
 */
uint32_t cadaclysm_view_show_lines(struct CadaclysmView *view,
                                   const float *segments,
                                   uint32_t segment_count,
                                   const float *rgb);

/**
 * Rational cubic Beziers, sixteen floats each (four control points as x, y, z, weight),
 * drawn as one item on the curves layer in `rgb` (NULL: the curves' colour): exact curves
 * where the exact pass runs, sampled where it does not. They never pick. The item's id, 0
 * on failure -- a value not finite, a weight not positive.
 *
 * The terminal library: accepted with a difference -- it has no exact pass, so every curve
 * is sampled as a polyline, there or not.
 *
 * `view` must be NULL or a live view; `beziers` NULL or `curve_count * 16` floats; `rgb`
 * NULL or three floats.
 */
uint32_t cadaclysm_view_show_curves(struct CadaclysmView *view,
                                    const float *beziers,
                                    uint32_t curve_count,
                                    const float *rgb);

/**
 * A reference image on a quad in the model: `corners` bottom-left, bottom-right, top-right,
 * top-left; `rgba` `width * height` pixels, rows top first; `opacity` 0..1 (0 in a zeroed
 * struct is 1). Drawn after the opaque geometry, both sides; never picks. The item's id, 0
 * on failure.
 *
 * The terminal library: refuses (0, nothing shown) -- it has no way to draw a textured quad.
 *
 * `view` must be NULL or a live view; `image` NULL or a `CadaclysmViewImage` whose `rgba`
 * holds `width * height * 4` bytes.
 */
uint32_t cadaclysm_view_show_image(struct CadaclysmView *view,
                                   const struct CadaclysmViewImage *image);

/**
 * Recolours an item in place (no upload): `rgb` three floats in 0..1. False where the item
 * is not shown or `rgb` is NULL or not finite.
 *
 * `view` must be NULL or a live view; `rgb` NULL or three floats.
 */
bool cadaclysm_view_set_colour(struct CadaclysmView *view, uint32_t item, const float *rgb);

/**
 * Draws the item's triangles after everything else, depth-tested but without writing depth, so
 * an overlay shows through the parts in front of it (`on` true) -- or normally again (false).
 * Kept across uploads, removes of other items and surface switches. Exact surfaces and pick
 * treat the item as ordinary geometry. The terminal accepts it and draws the item as ordinary
 * geometry. False where the item is not shown.
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_set_xray(struct CadaclysmView *view, uint32_t item, bool on);

/**
 * Colours faces of an item: `faces[i]` in `rgba[4 * i ..]` (alpha unused), `count` of
 * them; `faces` NULL clears every face colour. Face numbers are the item's pick numbers.
 * False where the item is not shown or a value is not finite.
 *
 * `view` must be NULL or a live view; `faces` NULL or `count` words; `rgba` `4 * count` floats.
 */
bool cadaclysm_view_set_face_colours(struct CadaclysmView *view,
                                     uint32_t item,
                                     const uint32_t *faces,
                                     const float *rgba,
                                     uint32_t count);

/**
 * Moves an item by `matrix`, sixteen doubles column-major (entry `4 * col + row`), kept
 * across uploads; NULL puts it back where it was shown. False where the item is not shown
 * or a number is not finite.
 *
 * `view` must be NULL or a live view; `matrix` NULL or sixteen doubles.
 */
bool cadaclysm_view_set_placement(struct CadaclysmView *view, uint32_t item, const double *matrix);

/**
 * Poses `item`'s scene: one world transform per node, `count` arrays of sixteen doubles
 * each, column-major (entry `4 * col + row`; `count` the scene's node count), drawn in
 * place of each node's rest transform. NULL with `count` 0 restores the rest pose. False,
 * with the reason on `cadaclysm_view_last_error`, where the item is not a shown scene, the
 * count differs from the scene's node count, or a matrix is not finite or not rigid.
 *
 * `view` must be NULL or a live view; `transforms` must be NULL (with `count` 0) or point
 * at `count` arrays of sixteen doubles.
 */
bool cadaclysm_view_set_node_transforms(struct CadaclysmView *view,
                                        uint32_t item,
                                        const double *transforms,
                                        uint32_t count);

/**
 * Shows a kernel solid by its handle, read in place: exact surfaces where they draw,
 * triangles at `tolerance` (0: 0.05) otherwise, its edges, its paint (or `rgb` over it).
 * The item's id, 0 on failure. The solid must stay alive until the item is removed or the
 * view destroyed. Needs `cadaclysm_blacksmith` loaded in the process; the view never links it.
 * Fails, with the reason, where the kernel is not loaded or is too old for this library (it
 * lacks a call the view reads a solid through).
 *
 * `view` must be NULL or a live view; `solid` NULL or a live solid of the loaded kernel;
 * `rgb` NULL or three floats.
 */
uint32_t cadaclysm_view_show_solid(struct CadaclysmView *view,
                                   const CadaclysmBlacksmithSolid *solid,
                                   double tolerance,
                                   const float *rgb);

#ifdef __cplusplus
}  // extern "C"
#endif  // __cplusplus

#endif  /* CADACLYSM_VIEW_H */
