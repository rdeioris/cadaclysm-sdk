/* cadaclysm_view - the Cadaclysm viewer in a host's window, over a C ABI. Generated; do not edit. */

#ifndef CADACLYSM_VIEW_H
#define CADACLYSM_VIEW_H



#include <stdbool.h>
#include <stdint.h>
typedef struct CadaclysmScene CadaclysmScene;

#define CADACLYSM_VIEW_ABI_MAJOR 1

#define CADACLYSM_VIEW_ABI_MINOR 0

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
   * `CADACLYSM_VIEW_BACKEND_*`, default ANY: ANY honours the `CADACLYSM_WGPU_BACKEND`
   * environment variable where it is set, else picks the platform's best backend.
   */
  uint32_t backend;
  /**
   * 0: Z up (default), 1: Y up.
   */
  uint32_t y_up;
} CadaclysmViewOptions;

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
   * Reserved: 0 in this version.
   */
  uint32_t face;
} CadaclysmViewPick;

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
 * A view drawing into `window`. Create it after the host has loaded `cadaclysm_capi` (any
 * reader call). NULL on failure, with the reason: no `cadaclysm_capi` loaded, a reader too
 * old for this library, no adapter of the asked backend for the window, a bad struct.
 * `options` NULL: every default. On AppKit, create the view and draw it on the main thread.
 * Create it once the window is mapped at its final size: on Qt, that is the first
 * `paintEvent`, not `showEvent`.
 *
 * `window` must point at a `CadaclysmViewWindow`; `options` must be NULL or point at a
 * `CadaclysmViewOptions`.
 */
struct CadaclysmView *cadaclysm_view_create(const struct CadaclysmViewWindow *window,
                                            const struct CadaclysmViewOptions *options);

/**
 * Frees the view. NULL is allowed.
 *
 * `view` must be NULL or from `cadaclysm_view_create`, and is not used again.
 */
void cadaclysm_view_destroy(struct CadaclysmView *view);

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
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_draw(struct CadaclysmView *view);

/**
 * Shows `scene` (from `cadaclysm_open`). The item's id, 0 on failure. The scene must stay
 * open until the item is removed or the view destroyed: exact parts are built from it when
 * the surfaces mode changes.
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
 * Asks what is under pixel (`x`, `y`), in physical pixels from the window's top left (a
 * Qt host multiplies a mouse position by `devicePixelRatio`). The answer comes on a later
 * call to `cadaclysm_view_pick_result`, after a draw; `cadaclysm_view_needs_draw` is true
 * until it has. A pick requested before the view's first draw answers nothing (`item` 0).
 * A new request replaces one still pending. A device loss during a draw drops the pick
 * (its readback lived on the lost device); the host asks again.
 *
 * `view` must be NULL or a live view.
 */
void cadaclysm_view_request_pick(struct CadaclysmView *view, uint32_t x, uint32_t y);

/**
 * The answer to the last `cadaclysm_view_request_pick`, true once, when it has landed:
 * `out.item` 0 (and the rest 0) for nothing under the pixel. False, with "no pick result",
 * while none has landed or none was asked, or where a device loss dropped the pick in
 * flight (the host asks again); it never waits for the GPU. `out.size` must be at least
 * the 1.0 struct's.
 *
 * `view` must be NULL or a live view; `out` must be NULL or point at a `CadaclysmViewPick` of
 * `out->size` bytes.
 */
bool cadaclysm_view_pick_result(struct CadaclysmView *view, struct CadaclysmViewPick *out);

#ifdef __cplusplus
}  // extern "C"
#endif  // __cplusplus

#endif  /* CADACLYSM_VIEW_H */
