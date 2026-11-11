/* cadaclysm_view - the Cadaclysm viewer in a host's window, over a C ABI. Generated; do not edit. */

#ifndef CADACLYSM_VIEW_H
#define CADACLYSM_VIEW_H



#include <stdbool.h>
#include <stdint.h>
typedef struct CadaclysmScene CadaclysmScene;
typedef struct CadaclysmBlacksmithSolid CadaclysmBlacksmithSolid;

#define CADACLYSM_VIEW_ABI_MAJOR 1

/**
 * 1.5 appended `cadaclysm_view_parse_colour` (colour text for every colour this header takes).
 * 1.6 appended `cadaclysm_view_load_font`, `_show_text` and `_set_text` (text items) and
 * `CADACLYSM_VIEW_LAYER_TEXT`.
 * 1.7 the machining and timeline calls (`cadaclysm_view_show_machining` and the rest).
 * 1.8 grew `CadaclysmViewPick` (`clicks`, `has_point`, `point`) and appended
 * `cadaclysm_view_set_double_click_frames`, `_focus` and `_navigation`: a double click is
 * reported, and frames only when the host opts in.
 * 1.9 appended `cadaclysm_view_set_lighting` and `_lighting`: studio lighting beside the
 * headlight (`CADACLYSM_VIEW_LIGHTING_*`).
 * 1.10 appended the viewport cameras -- `cadaclysm_view_viewport_camera`,
 * `_set_viewport_camera`, `_set_viewport_rects`, `_aim`, `_set_pivot`, `_set_tap` and the
 * `_in` camera calls -- `CadaclysmViewViewportCamera` and `CadaclysmViewEvent.alt`.
 * 1.11 appended `cadaclysm_view_show_points`: a point cloud as one item, a disc a point.
 * 1.12 appended the texture targets -- `cadaclysm_view_create_on_device`, `_create_shared`,
 * `_texture` and `_release` -- and `CadaclysmViewDevice`, `CadaclysmViewShared` and
 * `CadaclysmViewTexture`: a view drawing into a texture the host samples, on the host's own
 * device or shared across devices on one GPU.
 * 1.13 appended `cadaclysm_view_set_occluded`: an item's lines and points where a surface
 * hides them -- not drawn, drawn, or dashed and dimmed.
 * 1.14 appended `cadaclysm_view_set_analysis` and `_analysis`, and `CadaclysmViewAnalysis`:
 * zebra stripes, isophotes or curvature colour over every surface, for judging it.
 * 1.15 added `CADACLYSM_VIEW_LIGHTING_SHOWROOM` to `cadaclysm_view_set_lighting`: a showroom
 * fixed in the world mirrored in a clear coat over the parts' colours.
 * 1.16 appended `CadaclysmViewViewport::layer_mask`, `cadaclysm_view_set_item_layer` and `cadaclysm_view_set_user_layer`.
 * 1.17 added `CADACLYSM_VIEW_WINDOW_KMS`: the view drawn straight onto a Linux display through
 * the kernel's mode setting, with no window system.
 * 1.18 appended `cadaclysm_view_set_finish`: an item's finish -- gloss, satin or matte -- so
 * rubber and trim draw under the showroom's lights without its clear coat.
 * 1.19 appended `cadaclysm_view_kms_info` and `cadaclysm_view_kms_probe`, and
 * `CadaclysmViewKmsInfo`: how a KMS view draws onto its display, and how one would.
 * 1.20 appended `cadaclysm_view_set_occluded_style` and `_occluded_style`, and
 * `CadaclysmViewOccludedStyle`: the dash, gap, dim and colour of every DASHED item's hidden
 * lines and points.
 * 1.21 appended `cadaclysm_view_show_solid_faces` and `CADACLYSM_VIEW_MATERIAL_*`: a solid
 * in a material and an opacity, all its faces or only some (a trim's ghost); and a shown
 * solid's faces are numbered as the solid numbers them, exact or as triangles.
 * 1.22 appended snapping: `CadaclysmViewSnapSettings`, `CadaclysmViewSnap`, the
 * `CADACLYSM_VIEW_SNAP_*` kinds and six calls -- the vertex, midpoint, arc centre, quadrant,
 * edge, face, grid or plane point under the cursor, and the marker the view draws there.
 */
#define CADACLYSM_VIEW_ABI_MINOR 22

#define CADACLYSM_VIEW_WINDOW_WIN32 1

#define CADACLYSM_VIEW_WINDOW_XLIB 2

#define CADACLYSM_VIEW_WINDOW_XCB 3

#define CADACLYSM_VIEW_WINDOW_WAYLAND 4

#define CADACLYSM_VIEW_WINDOW_APPKIT 5

/**
 * A display driven through KMS, with no X11 or Wayland (1.17): a Linux console, a Raspberry Pi,
 * a kiosk. The view takes the display over at the first draw and puts its previous picture
 * back at `cadaclysm_view_destroy`; the host feeds input (`cadaclysm_view_input`) from evdev or
 * libinput. Any Vulkan device draws it: one that imports DMA-BUFs (`VK_EXT_external_memory_dma_buf`
 * and `VK_EXT_image_drm_format_modifier`) into the display's own buffers -- GBM's
 * (`libgbm.so.1`, loaded at run time) or its own where it is the display's device -- and any
 * other, a software Vulkan included, offscreen with a copy into the display's buffers each frame
 * (`CADACLYSM_KMS_COPY=1` forces the copy). Linux only.
 */
#define CADACLYSM_VIEW_WINDOW_KMS 6

/**
 * `CadaclysmViewKmsInfo.path` (1.19): the display's buffers allocated by GBM on the display's
 * device and drawn into by the GPU, a second device -- a Raspberry Pi, most ARM boards. No copy.
 */
#define CADACLYSM_VIEW_KMS_GBM 1

/**
 * The GPU's own buffers, exported to the display, which is the same device -- a PC's AMD or
 * Intel GPU, virtio-gpu under Venus. No copy.
 */
#define CADACLYSM_VIEW_KMS_GPU 2

/**
 * Drawn offscreen and copied by the CPU into the display's buffers each frame: no Vulkan
 * device here imports them (a software Vulkan such as lavapipe), or `CADACLYSM_KMS_COPY=1`.
 */
#define CADACLYSM_VIEW_KMS_COPY 3

#define CADACLYSM_VIEW_SURFACES_EXACT 0

#define CADACLYSM_VIEW_SURFACES_TRIANGLES 1

#define CADACLYSM_VIEW_LIGHTING_HEADLIGHT 0

#define CADACLYSM_VIEW_LIGHTING_STUDIO 1

/**
 * A showroom mirrored in a clear coat (1.15): the View's; the other renderers refuse it.
 */
#define CADACLYSM_VIEW_LIGHTING_SHOWROOM 2

/**
 * An item's finish (`cadaclysm_view_set_finish`, 1.18): gloss, the default -- under showroom
 * lighting a clear coat mirroring the room, sharp and silver at a grazing angle.
 */
#define CADACLYSM_VIEW_FINISH_GLOSS 0

/**
 * Satin: a weaker, blurred coat -- the room's lights as soft glows, not their outlines.
 */
#define CADACLYSM_VIEW_FINISH_SATIN 1

/**
 * Matte: no mirror at all, a faint grey sheen at a grazing angle -- rubber, cloth, primer.
 */
#define CADACLYSM_VIEW_FINISH_MATTE 2

/**
 * A shown solid's material (`cadaclysm_view_show_solid_faces`, 1.21): the headlight every
 * other item is drawn with.
 */
#define CADACLYSM_VIEW_MATERIAL_DEFAULT 0

/**
 * Plastic.
 */
#define CADACLYSM_VIEW_MATERIAL_PLASTIC 1

/**
 * Metal: a dimmer diffuse and a broad highlight in the body's own colour.
 */
#define CADACLYSM_VIEW_MATERIAL_METAL 2

/**
 * Matte rubber: hardly any highlight.
 */
#define CADACLYSM_VIEW_MATERIAL_MATTE 3

/**
 * Gloss paint: a small, hard white highlight.
 */
#define CADACLYSM_VIEW_MATERIAL_PAINT 4

/**
 * Brushed metal: the highlight smeared along the surface.
 */
#define CADACLYSM_VIEW_MATERIAL_BRUSHED 5

/**
 * Glass: drawn at its opacity, dithered as any translucent part is.
 */
#define CADACLYSM_VIEW_MATERIAL_GLASS 6

/**
 * What a snap may land on (`CadaclysmViewSnapSettings.kinds`, 1.22), and the one it landed on
 * (`CadaclysmViewSnap.kind`): an item's vertex.
 */
#define CADACLYSM_VIEW_SNAP_VERTEX 1

/**
 * An edge's midpoint.
 */
#define CADACLYSM_VIEW_SNAP_MIDPOINT 2

/**
 * A circular edge's centre, found by hovering the edge or the centre.
 */
#define CADACLYSM_VIEW_SNAP_CENTRE 4

/**
 * A circular edge's quadrant point: 0, 90, 180 or 270 degrees around its axis.
 */
#define CADACLYSM_VIEW_SNAP_QUADRANT 8

/**
 * The nearest point on an edge.
 */
#define CADACLYSM_VIEW_SNAP_EDGE 16

/**
 * The point on the surface under the cursor.
 */
#define CADACLYSM_VIEW_SNAP_FACE 32

/**
 * The nearest grid intersection on the work plane (`cadaclysm_view_set_work_plane`), or on the
 * viewport's grid plane.
 */
#define CADACLYSM_VIEW_SNAP_GRID 64

/**
 * The point on the work plane, or the viewport's grid plane, under the cursor.
 */
#define CADACLYSM_VIEW_SNAP_PLANE 128

/**
 * Every kind.
 */
#define CADACLYSM_VIEW_SNAP_ALL 255

/**
 * `CadaclysmViewAnalysis.mode` (1.14): surfaces drawn as lit, the default.
 */
#define CADACLYSM_VIEW_ANALYSIS_NONE 0

/**
 * Zebra stripes: the surface as a mirror in a cylinder of light bands fixed to the camera.
 */
#define CADACLYSM_VIEW_ANALYSIS_ZEBRA 1

/**
 * Isophotes: dark lines of equal angle between the normal and one light.
 */
#define CADACLYSM_VIEW_ANALYSIS_ISOPHOTES 2

/**
 * Curvature as false colour, blue at `-range`, green at 0, red at `+range`: Gaussian.
 */
#define CADACLYSM_VIEW_ANALYSIS_GAUSSIAN 3

/**
 * Mean curvature.
 */
#define CADACLYSM_VIEW_ANALYSIS_MEAN 4

/**
 * The smaller principal curvature.
 */
#define CADACLYSM_VIEW_ANALYSIS_MIN 5

/**
 * The larger principal curvature.
 */
#define CADACLYSM_VIEW_ANALYSIS_MAX 6

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
 * Every text item, labels and world text (1.6).
 */
#define CADACLYSM_VIEW_LAYER_TEXT 5

#define CADACLYSM_VIEW_TEXT_LABEL 0

#define CADACLYSM_VIEW_TEXT_WORLD 1

/**
 * What an item's lines and points draw where a surface is in front of them
 * (`cadaclysm_view_set_occluded`, 1.13): not drawn (the default).
 */
#define CADACLYSM_VIEW_OCCLUDED_OFF 0

/**
 * Drawn through, as where they are visible.
 */
#define CADACLYSM_VIEW_OCCLUDED_SOLID 1

/**
 * Drawn through, dashed and dimmed; a point as a dimmed ring.
 */
#define CADACLYSM_VIEW_OCCLUDED_DASHED 2

/**
 * Text alignment: which point of the text's box sits at `at` (labels: at the anchor plus
 * `offset`). The baseline is not a choice: "bottom" is the box's bottom.
 */
#define CADACLYSM_VIEW_ALIGN_TOP_LEFT 0

#define CADACLYSM_VIEW_ALIGN_TOP 1

#define CADACLYSM_VIEW_ALIGN_TOP_RIGHT 2

#define CADACLYSM_VIEW_ALIGN_LEFT 3

#define CADACLYSM_VIEW_ALIGN_CENTRE 4

#define CADACLYSM_VIEW_ALIGN_RIGHT 5

#define CADACLYSM_VIEW_ALIGN_BOTTOM_LEFT 6

#define CADACLYSM_VIEW_ALIGN_BOTTOM 7

#define CADACLYSM_VIEW_ALIGN_BOTTOM_RIGHT 8

/**
 * A viewport camera's kind (`CadaclysmViewViewportCamera.kind`, 1.10).
 */
#define CADACLYSM_VIEW_CAMERA_ORBIT 0

#define CADACLYSM_VIEW_CAMERA_FLY 1

#define CADACLYSM_VIEW_CAMERA_ORTHO 2

#define CADACLYSM_VIEW_CAMERA_FIXED 3

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
 * takes the answer. A double click's answer says `clicks` 2; it frames what it hit, when
 * that call takes it, only after `cadaclysm_view_set_double_click_frames(view, true)`.
 */
#define CADACLYSM_VIEW_INPUT_PICKED 2

/**
 * `cadaclysm_view_navigation` (1.8): a left drag orbits about the target.
 */
#define CADACLYSM_VIEW_NAVIGATION_ORBIT 0

/**
 * `cadaclysm_view_navigation` (1.8): fly mode -- a left drag turns the view about the eye.
 * Entered by a fly key (W, A, S, D, E, Q) and kept after it is let go; Tab toggles it, and
 * framing, a standard view or `cadaclysm_view_focus` leave it.
 */
#define CADACLYSM_VIEW_NAVIGATION_FLY 1

/**
 * `cadaclysm_view_pump`: the view's own window is open.
 */
#define CADACLYSM_VIEW_OPEN 1

/**
 * `cadaclysm_view_pump`: the view's own window was closed (Escape or its close button).
 * Item and camera calls then fail with "the window is closed"; `cadaclysm_view_pick_result`
 * still answers the last pick that landed, but the camera the view ended on is only handed
 * back by `cadaclysm_view_run`. `cadaclysm_view_destroy` is still owed.
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
 * `CadaclysmViewProgram.tool_shape` (1.7): a flat end mill.
 */
#define CADACLYSM_VIEW_TOOL_FLAT 0

/**
 * `CadaclysmViewProgram.tool_shape` (1.7): a ball end mill.
 */
#define CADACLYSM_VIEW_TOOL_BALL 1

/**
 * `CadaclysmViewProgram.tool_shape` (1.7): a drill.
 */
#define CADACLYSM_VIEW_TOOL_DRILL 2

/**
 * `CadaclysmViewProgram.tool_shape` (1.7): a V-bit, its included angle in `tool_angle`.
 */
#define CADACLYSM_VIEW_TOOL_VBIT 3

/**
 * `CadaclysmViewProgram.tool_shape` (1.7): a bull-nose end mill, its corner radius in
 * `tool_corner_radius`.
 */
#define CADACLYSM_VIEW_TOOL_BULLNOSE 4

/**
 * `cadaclysm_view_machining_colour_by` (1.7): a ramp from the stock's bottom to its top, the
 * default.
 */
#define CADACLYSM_VIEW_COLOUR_BY_HEIGHT 0

/**
 * `cadaclysm_view_machining_colour_by` (1.7): by the tool whose cut is deepest in each cell.
 */
#define CADACLYSM_VIEW_COLOUR_BY_TOOL 1

/**
 * `cadaclysm_view_machining_colour_by` (1.7): by the stock's height less the part's in each
 * cell -- on target, material left, a gouge. Only for a machining shown with a part.
 */
#define CADACLYSM_VIEW_COLOUR_BY_DEVIATION 2

/**
 * How many user layers an item can be put on (1.16): 0 to 31.
 */
#define CADACLYSM_VIEW_USER_LAYERS 32

/**
 * `CadaclysmViewDevice.api`, `CadaclysmViewShared.api` (1.12): the host's graphics API.
 */
#define CADACLYSM_VIEW_API_D3D12 1

#define CADACLYSM_VIEW_API_VULKAN 2

#define CADACLYSM_VIEW_API_METAL 3

/**
 * Shared mode only: a D3D11 host imports the view's D3D12 textures.
 */
#define CADACLYSM_VIEW_API_D3D11 4

/**
 * `CadaclysmViewDevice.flags` (1.12): the device was created by wgpu, which enabled every core
 * feature its adapter supports and wgpu relies on; `enabled_features` may then be NULL. A wgpu
 * host (iced, egui, Slint, Bevy) sets it -- it cannot read its enabled features back anyway.
 */
#define CADACLYSM_VIEW_DEVICE_WGPU 1

/**
 * `CadaclysmViewShared.flags` (1.12): the host's Vulkan device enabled
 * `VK_KHR_external_semaphore_fd`/`_win32` and can import the fences as semaphores. Without it
 * Vulkan shared mode syncs on the CPU: no fences, `cadaclysm_view_draw` waits for its frame, the
 * host releases with `cadaclysm_view_release`. Ignored for D3D12, D3D11 and Metal.
 */
#define CADACLYSM_VIEW_SHARED_HOST_SEMAPHORES 1

/**
 * `CadaclysmViewTexture.kind` (1.12). Host device, Vulkan: `texture` is the `VkImage`.
 */
#define CADACLYSM_VIEW_TEXTURE_VULKAN_IMAGE 1

/**
 * Host device, Metal: `texture` is the `id<MTLTexture>`.
 */
#define CADACLYSM_VIEW_TEXTURE_METAL_TEXTURE 2

/**
 * Shared: `texture` is an NT handle (a D3D12 or D3D11 resource, or Vulkan memory exported
 * `OPAQUE_WIN32`).
 */
#define CADACLYSM_VIEW_TEXTURE_WIN32_HANDLE 3

/**
 * Shared: `fd` is Vulkan memory exported `OPAQUE_FD`.
 */
#define CADACLYSM_VIEW_TEXTURE_POSIX_FD 4

/**
 * Shared: an `IOSurfaceRef`. Reserved: no library produces it yet.
 */
#define CADACLYSM_VIEW_TEXTURE_IOSURFACE 5

/**
 * Shared, Metal: `texture` is an `MTLSharedTextureHandle` (`newSharedTextureWithHandle:`).
 */
#define CADACLYSM_VIEW_TEXTURE_METAL_SHARED 6

/**
 * Host device, D3D12 (libraries built with D3D12 host devices): `texture` is the
 * `ID3D12Resource*`, left in `PIXEL_SHADER_RESOURCE | NON_PIXEL_SHADER_RESOURCE`.
 */
#define CADACLYSM_VIEW_TEXTURE_D3D12_RESOURCE 7

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
   * HWND, `wl_surface*`, `NSView*`; unused for Xlib, XCB and KMS.
   */
  void *window;
  /**
   * Xlib `Window`, `xcb_window_t`; KMS: the connector's object id, 0 for the first
   * connected one; unused otherwise.
   */
  uint64_t window_id;
  /**
   * HINSTANCE, `Display*`, `xcb_connection_t*`, `wl_display*`; NULL on AppKit. KMS: an
   * `int*` naming an open DRM primary node (`/dev/dri/cardN`) the host keeps -- DRM master,
   * typically from its seat manager; the view duplicates it -- or NULL for the view to open
   * the first card with a connected display itself (master while nothing else is).
   */
  void *display;
  /**
   * The window's current client size in physical pixels (a Qt host multiplies its
   * logical size by `devicePixelRatio`). Pass the size the native window actually has
   * once it is mapped: on Qt, that is the first `paintEvent`, not `showEvent` -- at
   * `showEvent` the native window can still lag Qt's own layout, and a swapchain made
   * at a stale size is invalid on Vulkan. KMS: the display mode's size, 0 x 0 for the
   * connector's preferred mode; `cadaclysm_view_size` gives the size taken, and the view
   * keeps it (`cadaclysm_view_resize` to any other size is refused).
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
   * `sizeof` the struct as the caller built it: the 1.0 struct's (16 bytes: `size` through
   * `face`) or the whole 1.8 struct. Fields past it are not written, so a size ending inside
   * `point` gets only part of the point.
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
  /**
   * 1.8: 2 for a double click's pick, else 1 (a click, or a host's own
   * `cadaclysm_view_request_pick`).
   */
  uint32_t clicks;
  /**
   * 1.8: 1 where `point` is set -- a hit, on a library that reads depth; 0 for no hit, a
   * machining stock, and the terminal library.
   */
  uint32_t has_point;
  /**
   * 1.8: the point hit, in the coordinates the items were shown in (world).
   */
  float point[3];
} CadaclysmViewPick;

/**
 * How every surface is drawn for judging it (`cadaclysm_view_set_analysis`, 1.14). Curvature
 * is signed against the outward normal (a ball's outside is positive) and estimated from the
 * drawn normals for now.
 */
typedef struct CadaclysmViewAnalysis {
  /**
   * `sizeof` the struct as the caller built it; at least the 1.14 struct's.
   */
  uint32_t size;
  /**
   * `CADACLYSM_VIEW_ANALYSIS_*`.
   */
  uint32_t mode;
  /**
   * Zebra: black stripes round the turn (default 16); isophotes: lines over 90 degrees
   * (default 9, a line every 10). 0 the default; at most 256.
   */
  uint32_t count;
  /**
   * Zebra: the stripes' direction on screen, degrees: 0 upright, 90 lying.
   */
  float angle;
  /**
   * Zebra: the black share of a period, inside 0..1; 0 the default, 0.5.
   */
  float width;
  /**
   * Isophotes: towards the light in the camera's frame (x right, y up, z towards the
   * viewer); all zero the default, a headlight `(0, 0, 1)`.
   */
  float light[3];
  /**
   * Curvature: the value drawn full red (and, negative, full blue), in 1/length (1/length^2
   * for Gaussian); 0 automatic, `2 / radius` of the scene (squared for Gaussian).
   */
  double range;
} CadaclysmViewAnalysis;

/**
 * How every DASHED item's hidden lines and points look, view-wide
 * (`cadaclysm_view_set_occluded_style`, 1.20). Zeroes are the defaults.
 */
typedef struct CadaclysmViewOccludedStyle {
  /**
   * `sizeof` the struct as the caller built it; at least the 1.20 struct's.
   */
  uint32_t size;
  /**
   * A dash's length on screen, in points (times the view's point scale); 0: 6.
   */
  float dash;
  /**
   * The gap between dashes, in points; 0: 4.
   */
  float gap;
  /**
   * How much of an occluded dash's or ring's coverage is kept, (0, 1]; 0: 0.5.
   */
  float dim;
  /**
   * Nonzero: occluded dashes and rings take `colour` instead of their own.
   */
  uint32_t has_colour;
  /**
   * 0..1 RGB, as `cadaclysm_view_set_colour` takes it; read only where `has_colour`.
   */
  float colour[3];
} CadaclysmViewOccludedStyle;

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
  /**
   * Which user layers draw in this viewport (1.16): bit n shows layer n
   * (`cadaclysm_view_set_item_layer`). 0 shows every layer, as does a caller whose `size`
   * ends before it: a zero-filled struct draws as it did before 1.16. A mask therefore
   * cannot hide every user layer; `cadaclysm_view_set_user_layer` switches layers off.
   * Surfaces, edges, curves, lines, text and picking follow it; points and images follow
   * it only when this is the one viewport set, and otherwise draw in every viewport.
   * Machining stocks ignore user layers, and an image on a layer not drawn still counts
   * in bounds and framing.
   */
  uint32_t layer_mask;
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
   * Physical pixels from the window's top left. A Wheel event's too: with viewports set,
   * the pane it zooms (and the point it zooms toward); a wheel at 0, 0 zooms the pane there.
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
  /**
   * A Down event's only: whether Alt was held (1.10). Alt and the left button orbit the viewport's pivot.
   */
  uint32_t alt;
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

/**
 * One program of a CAM job and the tool it runs with (`CadaclysmViewMachining.programs`,
 * 1.7): an array whose stride is the first element's `size`.
 */
typedef struct CadaclysmViewProgram {
  /**
   * `sizeof` the struct as the caller built it; every element of the array must carry
   * the same `size`.
   */
  uint32_t size;
  /**
   * The tool's number: `T<number>` in the status line.
   */
  uint32_t tool_number;
  /**
   * `CADACLYSM_VIEW_TOOL_*`.
   */
  uint32_t tool_shape;
  /**
   * mm.
   */
  double tool_diameter;
  /**
   * mm; 0: not given.
   */
  double tool_flute_length;
  /**
   * A V-bit's included angle, degrees; read only for `CADACLYSM_VIEW_TOOL_VBIT`.
   */
  double tool_angle;
  /**
   * A bull-nose's corner radius, mm; read only for `CADACLYSM_VIEW_TOOL_BULLNOSE`.
   */
  double tool_corner_radius;
  /**
   * The program's text: G-code, UTF-8, NUL-terminated.
   */
  const char *gcode;
} CadaclysmViewProgram;

/**
 * A CAM job (`cadaclysm_view_show_machining`, 1.7): its programs, the stock they cut and an
 * optional part. Zeroed fields are the defaults.
 */
typedef struct CadaclysmViewMachining {
  /**
   * `sizeof` the struct as the caller built it; fields past it take their defaults.
   */
  uint32_t size;
  /**
   * At least 1.
   */
  uint32_t program_count;
  /**
   * The programs, in the order they run.
   */
  const struct CadaclysmViewProgram *programs;
  /**
   * The blank's lowest corner, mm.
   */
  double stock_min[3];
  /**
   * The blank's highest corner, mm.
   */
  double stock_max[3];
  /**
   * The optional part, for colouring by deviation: three floats a vertex; NULL, 0 for none.
   */
  const float *part_positions;
  /**
   * Three a triangle.
   */
  const uint32_t *part_indices;
  uint32_t part_vertex_count;
  uint32_t part_index_count;
  /**
   * The stock's cell, mm; 0: the smallest tool diameter over 10, at most 0.1, raised to
   * fit the device.
   */
  double cell;
  /**
   * mm; 0: 0.05.
   */
  double tolerance;
  /**
   * mm; read only where `skin_set` is 1, else 0.3.
   */
  double skin;
  /**
   * mm/min; 0: 5000.
   */
  double rapid_rate;
  /**
   * 1: `skin` is given (0 is a valid skin).
   */
  uint32_t skin_set;
} CadaclysmViewMachining;

/**
 * A machining's facts (`cadaclysm_view_machining_info`, 1.7).
 */
typedef struct CadaclysmViewMachiningInfo {
  /**
   * `sizeof` the struct as the caller built it; at least the 1.7 struct's.
   */
  uint32_t size;
  /**
   * The reader's moves in the job.
   */
  uint32_t moves;
  /**
   * The moves done where the stock is now, as of the last draw or
   * `cadaclysm_view_machining_heights`.
   */
  uint32_t move;
  /**
   * The heights' grid, in cells.
   */
  uint32_t nx;
  uint32_t ny;
  /**
   * A cell's side, mm, after any raise to fit the device.
   */
  float cell;
  /**
   * Cell (0, 0)'s corner, mm.
   */
  float min[2];
  /**
   * The job's cycle time, seconds.
   */
  double cycle_time;
} CadaclysmViewMachiningInfo;

/**
 * One text item (1.6): a label in screen pixels anchored to a point, or text lying in a
 * plane of the model. Fields past the caller's `size` take their defaults.
 */
typedef struct CadaclysmViewText {
  /**
   * `sizeof` the struct as the caller built it.
   */
  uint32_t size;
  /**
   * UTF-8; "\n" starts a line.
   */
  const char *text;
  /**
   * `CADACLYSM_VIEW_TEXT_LABEL` or `_WORLD`.
   */
  uint32_t mode;
  /**
   * Label: the point it names; world: the text's origin.
   */
  float at[3];
  /**
   * World only: the baseline's direction (all zero: +X).
   */
  float right[3];
  /**
   * World only: the glyphs' up (all zero: +Y), made perpendicular to `right`.
   */
  float up[3];
  /**
   * Label: pixels; world: model units -- one line's advance.
   */
  float height;
  /**
   * The glyphs' colour, 0..1.
   */
  float rgb[3];
  /**
   * `CADACLYSM_VIEW_ALIGN_*`.
   */
  uint32_t align;
  /**
   * Label only: pixels from the anchor, right and up.
   */
  float offset[2];
  /**
   * Label only: the background box; alpha 0 = no box.
   */
  float box_rgba[4];
  /**
   * Label only: pixels between the text and the box's edge.
   */
  float box_padding;
  /**
   * Label only: 1 always drawn; 0 hidden while its anchor is hidden.
   */
  uint32_t on_top;
  /**
   * 0: the bundled font; else from `cadaclysm_view_load_font`.
   */
  uint32_t font;
} CadaclysmViewText;

/**
 * One viewport's camera (1.10): `cadaclysm_view_viewport_camera` fills it,
 * `cadaclysm_view_set_viewport_camera` reads it. Read back, `rect`, `view`, `projection` and
 * `eye` are what the viewport draws with now; the rest is the kind's state. Set, `kind` and
 * its fields are read (a fixed camera reads `view`, `projection` and `eye`), `rect` never
 * (`cadaclysm_view_set_viewport_rects`). Every field 4-aligned: 240 bytes.
 */
typedef struct CadaclysmViewViewportCamera {
  /**
   * `sizeof` the struct as the caller built it.
   */
  uint32_t size;
  /**
   * `CADACLYSM_VIEW_CAMERA_*`.
   */
  uint32_t kind;
  /**
   * Read back only: x, y, width, height, physical pixels from the window's top left.
   */
  uint32_t rect[4];
  /**
   * Column-major world-to-eye matrix, as `CadaclysmViewViewport.view`; set: a fixed camera's.
   */
  float view[16];
  /**
   * Column-major eye-to-clip matrix (depth 0..1); set: a fixed camera's.
   */
  float projection[16];
  /**
   * The eye, world; set: a fixed or fly camera's.
   */
  float eye[3];
  /**
   * An orbit camera's target, a fly camera's framed point (what the wheel dollies
   * towards), an ortho camera's centre; world.
   */
  float target[3];
  /**
   * Orbit: the eye's distance from the target (set: not positive takes 1).
   */
  float distance;
  /**
   * Orbit and fly: the heading, radians.
   */
  float yaw;
  /**
   * Orbit and fly: the pitch, radians.
   */
  float pitch;
  /**
   * Orbit: 1 draws orthographic.
   */
  uint32_t orthographic;
  /**
   * Fly: the fly keys' speed, world units a second (set: not positive takes 1).
   */
  float speed;
  /**
   * Fly and ortho: the scene's radius at the last frame (near/far, the dolly's bounds; set:
   * not positive takes 1).
   */
  float radius;
  /**
   * Ortho: the visible height, world units (set: not positive takes 100).
   */
  float height;
  /**
   * Ortho: the direction looked along, unit, world.
   */
  float axis_view[3];
  /**
   * Ortho: the screen's right, unit, perpendicular to `axis_view`.
   */
  float axis_right[3];
  /**
   * Ortho: the screen's up, unit, perpendicular to both.
   */
  float axis_up[3];
} CadaclysmViewViewportCamera;

/**
 * Host-device mode (1.12): the view built on the host's own device and queue, drawing into a
 * texture on that device. The host keeps the device, queue and instance alive until the view is
 * destroyed.
 */
typedef struct CadaclysmViewDevice {
  /**
   * `sizeof` the struct as the caller built it.
   */
  uint32_t size;
  /**
   * `CADACLYSM_VIEW_API_*`: Vulkan or Metal (D3D12 where the library has D3D12 host devices).
   */
  uint32_t api;
  /**
   * `CADACLYSM_VIEW_DEVICE_*`.
   */
  uint32_t flags;
  /**
   * `VkDevice` | `id<MTLDevice>` | `ID3D12Device*`.
   */
  void *device;
  /**
   * The queue the view submits on: `VkQueue` | `id<MTLCommandQueue>` | a DIRECT
   * `ID3D12CommandQueue*`. The view submits from wherever the host calls
   * `cadaclysm_view_draw`: the host serialises that with its own submissions.
   */
  void *queue;
  /**
   * Vulkan: the `VkInstance`.
   */
  void *instance;
  /**
   * Vulkan: the `VkPhysicalDevice`.
   */
  void *physical_device;
  /**
   * Vulkan: the queue's family.
   */
  uint32_t queue_family;
  /**
   * Vulkan: the queue's index in its family.
   */
  uint32_t queue_index;
  /**
   * Vulkan: the instance's `VK_API_VERSION`.
   */
  uint32_t api_version;
  /**
   * Vulkan: the instance extensions the host enabled.
   */
  const char *const *instance_extensions;
  uint32_t instance_extension_count;
  /**
   * Vulkan: the device extensions the host enabled.
   */
  const char *const *extensions;
  uint32_t extension_count;
  /**
   * Vulkan: the `VkPhysicalDeviceFeatures2` chain the device was created with (a device
   * cannot be asked what it enabled). NULL is refused unless `flags` has
   * `CADACLYSM_VIEW_DEVICE_WGPU`. wgpu enables and relies on `robustBufferAccess`,
   * `independentBlend`, `sampleRateShading`, `imageCubeArray`, `samplerAnisotropy`,
   * `fragmentStoresAndAtomics` and `multiDrawIndirect` wherever the GPU has them, and on the
   * extension features `timelineSemaphore`, `robustImageAccess`, `robustBufferAccess2`,
   * `robustImageAccess2` and `shaderZeroInitializeWorkgroupMemory` (read from the chain's
   * Vulkan 1.2 / 1.3 structs or their extension structs): the view refuses a device lacking
   * any the GPU supports, naming it.
   */
  const void *enabled_features;
  /**
   * The first texture's size, physical pixels.
   */
  uint32_t width;
  uint32_t height;
} CadaclysmViewDevice;

/**
 * Shared mode (1.12): the view on its own queue -- and its own device, except where the OS
 * hands out one device per GPU per process (D3D12, Metal) -- on the host's GPU, exporting its
 * textures and two fences as native shared handles.
 */
typedef struct CadaclysmViewShared {
  /**
   * `sizeof` the struct as the caller built it.
   */
  uint32_t size;
  /**
   * How the host imports: `CADACLYSM_VIEW_API_D3D12`, `_D3D11`, `_VULKAN` or `_METAL`.
   */
  uint32_t api;
  /**
   * Windows: the host adapter's LUID.
   */
  uint8_t adapter_luid[8];
  /**
   * Vulkan: `VkPhysicalDeviceIDProperties.deviceUUID`.
   */
  uint8_t device_uuid[16];
  /**
   * Vulkan: `VkPhysicalDeviceIDProperties.driverUUID` -- opaque handles import only into the
   * same driver.
   */
  uint8_t driver_uuid[16];
  /**
   * Metal: `MTLDevice.registryID`.
   */
  uint64_t registry_id;
  /**
   * `CADACLYSM_VIEW_SHARED_*`.
   */
  uint32_t flags;
  /**
   * The first textures' size, physical pixels.
   */
  uint32_t width;
  uint32_t height;
} CadaclysmViewShared;

/**
 * What `cadaclysm_view_texture` hands back (1.12): the texture to sample and how to sync.
 */
typedef struct CadaclysmViewTexture {
  /**
   * The caller sets it; the library writes at most this many bytes.
   */
  uint32_t size;
  /**
   * `CADACLYSM_VIEW_TEXTURE_*`.
   */
  uint32_t kind;
  /**
   * `VkImage` | `id<MTLTexture>` | `ID3D12Resource*` | an NT handle | an
   * `MTLSharedTextureHandle`. Owned by the view, valid until the next generation or
   * `cadaclysm_view_destroy`.
   */
  void *texture;
  /**
   * `CADACLYSM_VIEW_TEXTURE_POSIX_FD`: owned by the view; the host imports a `dup()`. -1
   * otherwise.
   */
  int32_t fd;
  /**
   * The allocation size a Vulkan memory import needs; 0 otherwise.
   */
  uint64_t memory_size;
  /**
   * R8G8B8A8 holding sRGB-encoded, opaque colour; viewable as UNORM or sRGB.
   */
  uint32_t width;
  uint32_t height;
  /**
   * The state it is left in: a `VkImageLayout` (`SHADER_READ_ONLY_OPTIMAL`), or
   * `D3D12_RESOURCE_STATES`; 0 on Metal. A host that uses it other than by sampling returns
   * it to this state afterwards (the hand-back contract).
   */
  uint32_t state;
  /**
   * Which texture of the ring this is.
   */
  uint32_t slot;
  /**
   * The ring's length: 1 in host-device mode, 3 in shared mode. A host imports one texture
   * per slot per generation.
   */
  uint32_t slot_count;
  /**
   * 0: a new generation's texture not drawn yet. Adopt it now -- import it and make the
   * host's first use (to sampled) -- before the next `cadaclysm_view_draw`.
   */
  uint32_t drawn;
  /**
   * Bumps when the textures are re-created (a resize, a device loss). Host device: the view
   * keeps a past generation alive until a submission of its own made after the change has
   * completed; the host drops its wraps of it once its work using them is submitted.
   */
  uint64_t generation;
  /**
   * Shared mode: the view signals it. An NT handle (a D3D12 / D3D11 fence, a Vulkan timeline
   * semaphore exported `OPAQUE_WIN32`) or an `MTLSharedEventHandle`; NULL in host-device
   * mode and in Vulkan shared mode without `CADACLYSM_VIEW_SHARED_HOST_SEMAPHORES`.
   */
  void *ready_fence;
  /**
   * Shared mode: the host signals it. The same kinds as `ready_fence`.
   */
  void *release_fence;
  /**
   * POSIX: the ready timeline semaphore's `OPAQUE_FD` fd, owned by the view (import a
   * `dup()`); -1 otherwise.
   */
  int32_t ready_fence_fd;
  /**
   * POSIX: the release semaphore's fd, as `ready_fence_fd`.
   */
  int32_t release_fence_fd;
  /**
   * Wait until `ready_fence` reaches it before sampling.
   */
  uint64_t ready_value;
  /**
   * Signal `release_fence` to it (or pass it to `cadaclysm_view_release`) once the host's
   * sampling work is submitted.
   */
  uint64_t release_value;
} CadaclysmViewTexture;

/**
 * How a KMS view draws onto its display (`cadaclysm_view_kms_info`, `cadaclysm_view_kms_probe`,
 * 1.19). The text fields are UTF-8, NUL-terminated, cut short at a character to fit.
 */
typedef struct CadaclysmViewKmsInfo {
  /**
   * `sizeof` the struct as the caller built it; at least the 1.19 struct's.
   */
  uint32_t size;
  /**
   * `CADACLYSM_VIEW_KMS_GBM`, `_GPU` or `_COPY`.
   */
  uint32_t path;
  /**
   * The scanout buffers' DRM format modifier (`DRM_FORMAT_MOD_LINEAR`, 0, for the GPU's own
   * buffers and the copy mode's).
   */
  uint64_t modifier;
  /**
   * The connector's KMS object id.
   */
  uint32_t connector;
  /**
   * The mode, in pixels, and its refresh in Hz.
   */
  uint32_t width;
  uint32_t height;
  uint32_t refresh;
  /**
   * The scanout buffers' DRM fourcc (`XB24` or `XR24`), little-endian as `drm_fourcc.h` packs it.
   */
  uint32_t fourcc;
  /**
   * The connector's name: "HDMI-A-1", "Virtual-1".
   */
  char connector_name[32];
  /**
   * The display's device: "/dev/dri/card1", or "fd 5" for one the host passed.
   */
  char card[64];
  /**
   * The Vulkan device that draws, and its driver: "V3D 7.1.7.0 (V3DV Mesa 26.2.2)".
   */
  char adapter[128];
} CadaclysmViewKmsInfo;

/**
 * How the view snaps (`cadaclysm_view_set_snap`, 1.22). Snapping starts off.
 */
typedef struct CadaclysmViewSnapSettings {
  /**
   * `sizeof` the struct as the caller built it; at least the 1.22 struct's.
   */
  uint32_t size;
  /**
   * The `CADACLYSM_VIEW_SNAP_*` kinds a snap may land on; 0 switches snapping off.
   */
  uint32_t kinds;
  /**
   * How far from the cursor a snap reaches, in points: 0 for the default, 10; otherwise
   * clamped to 2-32. Multiplied by the screen density.
   */
  float aperture_px;
  /**
   * 1: the view draws a marker at the last snap, shaped by its kind; 0: it draws none.
   */
  uint32_t marker;
} CadaclysmViewSnapSettings;

/**
 * A snap's answer (`cadaclysm_view_snap_result`, 1.22).
 */
typedef struct CadaclysmViewSnap {
  /**
   * `sizeof` the struct as the caller built it; at least the 1.22 struct's.
   */
  uint32_t size;
  /**
   * The one `CADACLYSM_VIEW_SNAP_*` kind it landed on; 0 for none (nothing in the kinds
   * asked for within the aperture, or snapping off), the other fields then zero.
   */
  uint32_t kind;
  /**
   * The snapped point, in world coordinates, as `cadaclysm_view_project_in` takes them.
   */
  double point[3];
  /**
   * The item, as the pick names it; 0 for `GRID` and `PLANE`.
   */
  uint32_t item;
  /**
   * The assembly node, as the pick names it; 0 where there is none.
   */
  uint32_t node;
  /**
   * The face under the cursor (`FACE`), or the face the snapped edge was found beside; 0
   * where there is none (a curves item, `GRID`, `PLANE`).
   */
  uint32_t face;
  /**
   * The item's edge the snap landed on; `0xFFFFFFFF` for `FACE`, `GRID` and `PLANE`.
   */
  uint32_t edge;
  /**
   * The edge's unit tangent at `point` (the edge kinds); zero otherwise.
   */
  float tangent[3];
  /**
   * `CENTRE` and `QUADRANT`: the arc's unit axis; zero otherwise.
   */
  float axis[3];
  /**
   * `CENTRE` and `QUADRANT`: the arc's radius; zero otherwise.
   */
  double radius;
  /**
   * From the cursor to `point`'s pixel, in physical pixels; 0 for `CENTRE` found by hovering
   * its arc, `FACE`, `GRID` and `PLANE`.
   */
  float distance_px;
  /**
   * 0 for the host's own request or a hover, 1 for a click's snap, 2 for a double click's.
   */
  uint32_t clicks;
} CadaclysmViewSnap;

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
 * A colour's text as r, g, b in 0..1, into `out[0..3]` (1.5): `"#rgb"`, `"#rrggbb"` (the
 * `#` optional) or one of the 148 CSS Color Module Level 4 names, matched case-insensitively
 * -- the same forms as the reader's `cadaclysm_parse_colour`, but as floats, the type every
 * colour of this header takes, and without the reader loaded. Text carries no alpha: a
 * wrapper filling a four-float `rgba` from text sets the alpha to 1. False, with
 * `cadaclysm_view_last_error` naming the text, for anything else (`transparent`,
 * `currentcolor`, `rgb(..)`, `#rgba`, ...), and for a NULL `text` or `out`; `out` is then
 * untouched. Needs no view.
 *
 * `text` must be NULL or a NUL-terminated string; `out` NULL or room for three floats.
 */
bool cadaclysm_view_parse_colour(const char *text, float *out);

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
 * window of the view's own" where none is reachable. On Linux with no `DISPLAY` or
 * `WAYLAND_DISPLAY` (a console) the window is the whole display instead, through KMS (1.17):
 * the first connected output at its preferred mode, `title`, `width` and `height` unused, the
 * keyboards and mice read from `/dev/input` (the user in the `input` group) and grabbed --
 * the console under it gets none of their keys -- and an arrow on the display's cursor plane.
 * Escape or Ctrl+C closes it and gives the console back. It is refused, with that phrase and
 * the console's reason, where the display has another master (a compositor) or no keyboard
 * or mouse can be read, and while another such view is open; `CADACLYSM_VIEW_CONSOLE=0`
 * keeps to the plain refusal. Refused with "own windows belong to the thread that made the
 * first one" on any thread but the one whose windowless create came first; on macOS, that is
 * the main thread.
 * Refused with "another event loop already exists in this process" where the host or
 * another library has already made the process's one window event loop.
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
 * waits for `cadaclysm_view_pick_result` (a newer one replaces it). A double click's answer
 * says `clicks` 2; it frames what it hit as it lands only after
 * `cadaclysm_view_set_double_click_frames(view, true)`. The thread that makes the first own
 * window must outlive them: once it has exited, own windows are unavailable for the rest of
 * the process.
 *
 * With snapping on (`cadaclysm_view_set_snap`, 1.22) the mouse hovering the window snaps, and
 * the marker follows it, as `cadaclysm_view_input` describes; each answer waits for
 * `cadaclysm_view_snap_result`.
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
 * A pick still in flight when the window closes (a click, then Escape before the next frame)
 * is waited for briefly -- at most a quarter of a second -- and reported if it lands.
 * With snapping on (1.22) the mouse hovering the window snaps and shows the marker, as
 * `cadaclysm_view_input` describes; the last snap answer stays for
 * `cadaclysm_view_snap_result`.
 * Either out may be NULL, and neither out's own `size` is ever changed -- only the fields
 * after it -- so a host reusing the same struct across calls (a REPL's `run` in a loop)
 * keeps reading back the size it put there. Only for a view made with no window; false with
 * the reason on a refusal, as `cadaclysm_view_pump`'s -- including "the window is closed" for
 * a view whose window closed before this call. Can be called again later in the same
 * process, also after `pump`.
 *
 * The terminal library: the alternate screen and the orbit loop, through the gesture
 * handler -- drag orbits, right or Shift drag pans, the wheel zooms, `t` `f` `r` `i` the
 * standard views, Space frames all, `o` orthographic, `e` edges, `s` saves
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
 * pick or a snap waiting for its answer. A snap's answer that has landed and not been read
 * owes none, unlike a pick's: the draw that landed it drew its marker, and a hover's answers
 * are many and may go unread (1.22). True, too, while the device is lost or the document is
 * still owed to a rebuilt one: the next `cadaclysm_view_draw` rebuilds or re-uploads.
 * True while the view's timeline plays or a track is still catching up (1.7).
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
 * Ticks the view's timeline by the wall clock first (1.7): a track's refusal is reported
 * once, by the draw that meets it, after the frame is drawn.
 *
 * An offscreen view (1.4): renders without presenting -- nothing is shown anywhere -- and
 * lands a pick in flight, as a window's draw does; every draw lands a snap in flight (1.22); read the frame with `cadaclysm_view_image`.
 *
 * The items shown since the last draw are merged and uploaded here, all at once (a show
 * only keeps its item, so filling a view costs each item's own work): false with the reason
 * where the GPU rejects that upload. The items stay shown and draw nothing new until a later
 * show, remove or change uploads them again.
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
 * GPU. As `cadaclysm_view_draw`, it uploads the items shown since the last frame first, and
 * fails with the reason where the GPU rejects them.
 *
 * Every view: an offscreen one, the own window, a host's window (the frame is drawn
 * apart from what the window presents). False where `capacity` is too small (the reason says
 * how many bytes are needed) or `rgba` is NULL. The terminal library reads its picture from
 * its CPU raster.
 *
 * `view` must be NULL or a live view; `rgba` NULL or `capacity` writable bytes.
 */
bool cadaclysm_view_image(struct CadaclysmView *view, uint8_t *rgba, size_t capacity);

/**
 * Shows `scene` (from `cadaclysm_open`). The item's id, 0 on failure. Every show keeps its
 * item and leaves the upload to the next frame (`cadaclysm_view_draw`, `cadaclysm_view_image`),
 * which uploads every item shown since in one go; a show fails at once only where the items
 * with it would not fit the device's buffers, and a GPU rejecting the upload itself fails that
 * frame instead. The scene must stay
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
 * (the item is gone all the same). A machining (1.7) goes with its track off the timeline.
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
 * Viewport 0's: with viewports set, its camera moves (a fixed one does not).
 *
 * `view` must be NULL or a live view.
 */
void cadaclysm_view_orbit(struct CadaclysmView *view, float dx, float dy);

/**
 * Pans the camera by a drag of `dx`, `dy` pixels. A non-finite delta is ignored.
 * Viewport 0's: with viewports set, its camera moves (a fixed one does not).
 *
 * `view` must be NULL or a live view.
 */
void cadaclysm_view_pan(struct CadaclysmView *view, float dx, float dy);

/**
 * Zooms by `steps` wheel notches: positive zooms in. A non-finite value is ignored.
 * Viewport 0's: with viewports set, its camera moves (a fixed one does not).
 *
 * `view` must be NULL or a live view.
 */
void cadaclysm_view_zoom(struct CadaclysmView *view, float steps);

/**
 * Fits the camera to `item`, or to everything shown for 0. False where the item is not
 * shown, or there is nothing to fit.
 * Viewport 0's: with viewports set, its camera moves (a fixed one does not).
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_frame(struct CadaclysmView *view, uint32_t item);

/**
 * A standard view, `CADACLYSM_VIEW_STANDARD_*`: top looks down the up axis. False for
 * another value.
 * Viewport 0's: with viewports set, its camera moves (a fixed one does not).
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_standard(struct CadaclysmView *view, uint32_t which);

/**
 * An orthographic camera (`true`) or a perspective one.
 * Viewport 0's: with viewports set, its camera moves (a fixed one does not).
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
 * `CADACLYSM_VIEW_LAYER_TEXT` (1.6): every text item, labels and world text.
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_set_layer(struct CadaclysmView *view, uint32_t layer, bool on);

/**
 * Puts item `item` on user layer `layer`, 0..31 (1.16); every item starts on 0. It draws
 * where the layer is on (`cadaclysm_view_set_user_layer`) and, with viewports set, in
 * those whose `layer_mask` has bit `layer`. False for an item not shown or a layer past 31.
 * The terminal library accepts it too: with its one viewport, a mask lacking the item's
 * layer hides it.
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_set_item_layer(struct CadaclysmView *view, uint32_t item, uint32_t layer);

/**
 * Switches user layer `layer`, 0..31, on or off in every viewport (1.16); all start on.
 * False past 31.
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_set_user_layer(struct CadaclysmView *view, uint32_t layer, bool on);

/**
 * The colour the view is cleared to: `rgb`, three linear floats in 0..1 (clamped). A NULL
 * or non-finite colour is refused and changes nothing.
 *
 * `view` must be NULL or a live view; `rgb` must be NULL or point at 3 floats.
 */
void cadaclysm_view_set_background(struct CadaclysmView *view, const float *rgb);

/**
 * How plain parts are lit (1.9): `CADACLYSM_VIEW_LIGHTING_HEADLIGHT`, the default -- whatever
 * faces the camera is bright -- `CADACLYSM_VIEW_LIGHTING_STUDIO`, a key light fixed above
 * the model, ambient and a fill from the camera, so a top reads brighter than its sides from
 * anywhere, or (1.15) `CADACLYSM_VIEW_LIGHTING_SHOWROOM`, a showroom fixed in the world
 * mirrored in a clear coat over the colours (a terminal view draws it as studio). False,
 * changing nothing, with `cadaclysm_view_last_error` naming
 * `cadaclysm_view_set_lighting`, for another value or a NULL or closed view.
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_set_lighting(struct CadaclysmView *view, uint32_t lighting);

/**
 * The lighting in use, `CADACLYSM_VIEW_LIGHTING_*` (1.9); the headlight for a NULL view.
 *
 * `view` must be NULL or a live view.
 */
uint32_t cadaclysm_view_lighting(const struct CadaclysmView *view);

/**
 * Draw every surface for judging it (1.14), in place of the lighting: `analysis->mode`
 * `CADACLYSM_VIEW_ANALYSIS_ZEBRA` (zebra stripes, fixed to the camera),
 * `_ISOPHOTES` (lines of equal angle to one light), `_GAUSSIAN`, `_MEAN`, `_MIN` or `_MAX`
 * (curvature as false colour, blue negative, green zero, red positive), or `_NONE`; NULL is
 * NONE. Zeros take the defaults (see `CadaclysmViewAnalysis`). Edges, curves, the grid, text,
 * images, points and stocks are drawn as before. The terminal library accepts NONE only.
 * False, changing nothing, with `cadaclysm_view_last_error` naming the call, for a `size`
 * below the 1.14 struct's, an unknown mode or a value out of range.
 *
 * `view` must be NULL or a live view; `analysis` NULL or a `CadaclysmViewAnalysis` of
 * `analysis->size` bytes.
 */
bool cadaclysm_view_set_analysis(struct CadaclysmView *view,
                                 const struct CadaclysmViewAnalysis *analysis);

/**
 * The analysis in use (1.14), into `out` with every default filled in: only `out->size`
 * bytes are written, and `out->size` must be at least the 1.14 struct's. False for a NULL view
 * or `out`.
 *
 * `view` must be NULL or a live view; `out` NULL or a `CadaclysmViewAnalysis` of `out->size`
 * bytes.
 */
bool cadaclysm_view_analysis(const struct CadaclysmView *view, struct CadaclysmViewAnalysis *out);

/**
 * How every `CADACLYSM_VIEW_OCCLUDED_DASHED` item's hidden lines and points look (1.20):
 * the dash and gap in points, the share of coverage kept, and optionally one colour for all
 * of them, ahead of every other line colour. NULL, or a struct of zeroes, is the default: 6
 * points on, 4 off, half the coverage, each line's own colour. Never applies to SOLID or OFF.
 * Kept across uploads, removes and surface switches. No upload. The terminal library and
 * render-view keep it and draw as before (neither draws DASHED). False, changing nothing, with
 * `cadaclysm_view_last_error` naming the call and the field, for a `size` below the 1.20
 * struct's, a dash, gap or dim negative or not finite, a dim above 1, a dash or gap above
 * 1000 points, or a colour component outside 0..1 where `has_colour`.
 *
 * `view` must be NULL or a live view; `style` NULL or a `CadaclysmViewOccludedStyle` of
 * `style->size` bytes.
 */
bool cadaclysm_view_set_occluded_style(struct CadaclysmView *view,
                                       const struct CadaclysmViewOccludedStyle *style);

/**
 * The occluded style in use (1.20), resolved: the defaults as their values (6, 4, 0.5),
 * never zeroes; `has_colour` 0 or 1. Only `out->size` bytes are written, and `out->size`
 * must be at least the 1.20 struct's. False for a NULL view or `out`.
 *
 * `view` must be NULL or a live view; `out` NULL or a `CadaclysmViewOccludedStyle` of
 * `out->size` bytes.
 */
bool cadaclysm_view_occluded_style(const struct CadaclysmView *view,
                                   struct CadaclysmViewOccludedStyle *out);

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
 * 0 when one is owed now, and 0 while the timeline plays or a track is catching up (1.7);
 * `UINT32_MAX` when none is coming (and for a NULL view).
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
 * back the built-in camera. While set, each viewport's camera is fixed: orbit, pan, zoom,
 * look, dolly, frame and standard leave it; `cadaclysm_view_set_viewport_camera` gives a
 * viewport a camera the view moves (1.10). The array's stride is `viewports[0].size`; every
 * element carries the same `size`. False, changing nothing, for a mixed `size`, a value not
 * finite, a grid not a `CADACLYSM_VIEW_GRID_*`.
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
 * (and `node`, `face`, `has_point` 0) for nothing under the pixel. False, with "no pick
 * result", while none has landed or none was asked, or where a device loss dropped the pick
 * in flight (the host asks again); it never waits for the GPU. `out.size` must be at least
 * the 1.0 struct's; fields past it are not written.
 *
 * 1.8: `clicks` is 2 for a double click's pick, 1 for a click's or the host's own;
 * `has_point` 1 and `point` the point hit, in the coordinates the items were shown in, for a
 * hit -- 0 for no hit, a machining stock, and on the terminal library, which reads no depth.
 *
 * Until this call takes a landed answer, `cadaclysm_view_needs_draw` stays true, so a host
 * that forwards input must call it after its draws once an input returned PICKED, even
 * where it does not use the answer. With `cadaclysm_view_set_double_click_frames(view,
 * true)`, a double click's pick frames what it hit here, when this call takes the answer --
 * for a view in a host's window. A view with a window of its own frames it as the answer
 * lands, during a `cadaclysm_view_pump` or `cadaclysm_view_run`, since nothing else calls
 * this to take it. Off (the default), nothing moves: the host reads `clicks`.
 *
 * Still answers once the view's window is closed, unlike the item and camera calls: a click
 * just before Escape lands in a pump host's last pumps and is read here after the pump
 * answered `CADACLYSM_VIEW_CLOSED`.
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
 * Whether a double click frames what it hit (1.8) -- as every double click did before 1.8.
 * Off by default: a double click is then a pick answered with `clicks` 2, and the camera
 * stays where it is. A NULL view: nothing.
 *
 * `view` must be NULL or a live view.
 */
void cadaclysm_view_set_double_click_frames(struct CadaclysmView *view, bool on);

/**
 * The orbit point moved to `point` (1.8): three floats, in the coordinates the items were
 * shown in (a pick's `point`). The eye keeps its direction and distance from the target --
 * the camera moves sideways, the view does not turn. Leaves fly mode. False, changing
 * nothing, for a NULL view or point, a point not finite, or while viewports are set.
 *
 * `view` must be NULL or a live view; `point` NULL or three readable floats.
 */
bool cadaclysm_view_focus(struct CadaclysmView *view, const float *point);

/**
 * How a left drag moves the camera (1.8): `CADACLYSM_VIEW_NAVIGATION_ORBIT` (about the
 * target) or `_FLY` (the view turns about the eye). A fly key (W, A, S, D, E, Q) through
 * `cadaclysm_view_input` enters fly mode and it stays after the key is let go; Tab toggles
 * it; a frame, a standard view, a double click that frames and `cadaclysm_view_focus` leave
 * it. ORBIT for a NULL view.
 *
 * `view` must be NULL or a live view.
 */
uint32_t cadaclysm_view_navigation(struct CadaclysmView *view);

/**
 * Turns the camera about its eye by a drag of `dx`, `dy` pixels (fly). Non-finite: ignored.
 * Viewport 0's: with viewports set, its camera moves (a fixed one does not).
 *
 * `view` must be NULL or a live view.
 */
void cadaclysm_view_look(struct CadaclysmView *view, float dx, float dy);

/**
 * Scales the eye's distance by `ratio` (below 1 is closer), as a pinch does. Non-finite or
 * not positive: ignored.
 * Viewport 0's: with viewports set, its camera moves (a fixed one does not).
 *
 * `view` must be NULL or a live view.
 */
void cadaclysm_view_dolly(struct CadaclysmView *view, float ratio);

/**
 * Hands the view's gesture handler one event -- the same handler the own window and the web
 * use, so a host that forwards its window's events gets the same gestures: the left button
 * orbits (in fly mode, turns the view about the eye), the right (or Shift-left) pans, the
 * wheel zooms, a click picks, a double click picks with `clicks` 2, T/F/R/I standard views,
 * O orthographic, X exact/triangles, Space frames all, W/S/A/D/E/Q fly while held (and enter
 * fly mode, which stays: `cadaclysm_view_navigation`), Tab toggles fly mode, Escape asks to
 * close. Alt with the left button (`CadaclysmViewEvent.alt`, 1.10) orbits the viewport's
 * pivot (`cadaclysm_view_set_pivot`). What it asked of the host, as `CADACLYSM_VIEW_INPUT_*`
 * bits; 0 for an event that does nothing or is refused.
 *
 * With viewports set, each gesture is read by the camera under the press and moves that
 * viewport's camera: a left drag orbits an orbit camera, looks with a fly camera, pans an
 * ortho one; the wheel zooms an orbit camera, dollies a fly camera and zooms an ortho one
 * about the cursor; a fixed camera does not move. A drag stays with the viewport it started
 * in; the fly keys move the fly camera under the pointer, else the first. In fly mode
 * (`cadaclysm_view_navigation`) the orbit camera the fly keys move turns about its eye on a
 * left drag, as a fly camera does. A Wheel event's `x` and `y` name the pane it zooms (and
 * where it zooms toward): fill them with the pointer's position -- a wheel at 0, 0 zooms
 * the pane at the window's top left. A click's travel and time are
 * `cadaclysm_view_set_tap`'s.
 *
 * A click or double click asks a pick and returns `CADACLYSM_VIEW_INPUT_PICKED`: the host
 * then calls `cadaclysm_view_pick_result` after its draws until it answers.
 * `cadaclysm_view_needs_draw` stays true until that call takes the answer. A double click
 * moves nothing unless the host opted in with `cadaclysm_view_set_double_click_frames`: then
 * it frames what it hit when that call takes the answer.
 *
 * With snapping on (`cadaclysm_view_set_snap`, 1.22), a mouse move with no button down asks
 * the snap under the cursor, so the marker follows the hover. One snap is in flight at a
 * time: a move made meanwhile waits, the latest replacing the one before, and is asked when
 * that snap lands. A click asks a snap too, as well as its pick: `cadaclysm_view_snap_result`
 * then answers with `clicks` 1 (2 for a double click). A hover never replaces a click's snap,
 * in flight or answered and not read; the move waiting behind a click is dropped as the
 * click's answer lands, and the next move asks. A drag, or a touch, asks no snap. With
 * snapping off, as a view starts, input behaves exactly as at 1.19.
 *
 * The event carries no repeat flag: a host forwarding its system's key-downs drops the
 * auto-repeats of a held Tab, or fly mode flips at the repeat rate (a held fly key's
 * repeats are harmless).
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
 * Points, three floats each (x, y, z), drawn as one item: a disc of `size_px` device
 * pixels across (1 to 64, times the view's pixel ratio) in `rgb` (NULL: the edge colour),
 * at each. They never pick; the item is framed by its points' box. The item's id, 0 on
 * failure -- a value not finite, a size out of range.
 *
 * The terminal library: refuses (0, nothing shown) -- it has no way to draw a dot.
 *
 * `view` must be NULL or a live view; `positions` NULL or `point_count * 3` floats; `rgb`
 * NULL or three floats.
 */
uint32_t cadaclysm_view_show_points(struct CadaclysmView *view,
                                    const float *positions,
                                    uint32_t point_count,
                                    const float *rgb,
                                    float size_px);

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
 * How the item's lines and points draw where a surface is in front of them (1.13): its
 * edges and isocurves, a curves item's curves, a lines item's segments, a points item's
 * points -- never its triangles (`cadaclysm_view_set_xray`). `CADACLYSM_VIEW_OCCLUDED_OFF`
 * (not drawn, the default), `_SOLID` (drawn through) or `_DASHED` (drawn through, dashed
 * and dimmed; a point as a dimmed ring). Kept across uploads, removes of other items and
 * surface switches. An x-ray item's points draw through, solid, whatever this says. The
 * terminal accepts every mode and draws it as OFF. The render view library accepts OFF and
 * refuses SOLID and DASHED: it draws no occluded lines yet. False where the item is not
 * shown, `mode` is not one of the three, or the render view library refuses it.
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_set_occluded(struct CadaclysmView *view, uint32_t item, uint32_t mode);

/**
 * The item's finish (1.18): `CADACLYSM_VIEW_FINISH_GLOSS` (the default), `_SATIN` or
 * `_MATTE`, for its triangles and its exact faces. Under `CADACLYSM_VIEW_LIGHTING_SHOWROOM`
 * gloss is the clear coat mirroring the room, sharp and silver at a grazing angle; satin a
 * weaker, blurred coat; matte no mirror, a faint grey sheen -- a black tyre stays black.
 * Under studio lighting, which has no highlight, every finish draws as gloss; under the
 * headlight satin and matte draw a soft and a faint highlight riding the camera. Kept
 * across uploads, removes of other items and surface switches.
 * Uploads the scene again, as a show does: set it on each item as it is shown, not over a
 * finished scene item by item. The terminal accepts every finish and draws it as gloss; the
 * render view library accepts GLOSS and refuses SATIN and MATTE. False where the item is
 * not shown, `finish` is not one of the three, or the render view library refuses it.
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_set_finish(struct CadaclysmView *view, uint32_t item, uint32_t finish);

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
 * Shows a CAM job (1.7): `machining`'s programs, played in order on a stock of its box, with
 * its optional part for colouring by deviation; its track joins the view's timeline at time
 * 0, paused. The item's id -- the stock, an item like any other (framed, placed, coloured by
 * id); `cadaclysm_view_remove` takes the machining and its track away -- or 0 on failure: a
 * NULL or undersized struct, a programs stride off the struct's alignment, no programs, a tool
 * shape not a `CADACLYSM_VIEW_TOOL_*`, a program the G-code reader refuses (its line named), a
 * stock box that is not a box, a part index past its vertices, or what the stock refuses. Copied in; the struct, its programs and their text
 * are the caller's again when this returns.
 *
 * After a lost device the stock comes back under a new view id. Only `cadaclysm_view_remove`
 * and the `cadaclysm_view_machining_*` calls translate the id returned here to it; every other
 * call (`cadaclysm_view_frame`, `cadaclysm_view_set_colour`, ...) takes the id as given, so
 * after a loss it no longer reaches the stock.
 *
 * The terminal library refuses it: "stock: machining stocks need the GPU renderer".
 *
 * `view` must be NULL or a live view; `machining` NULL or a `CadaclysmViewMachining` whose
 * arrays and strings hold what its counts say.
 */
uint32_t cadaclysm_view_show_machining(struct CadaclysmView *view,
                                       const struct CadaclysmViewMachining *machining);

/**
 * Jumps the timeline to the end of move `to` of the machining `item` (0: the untouched stock;
 * its `moves`: the end), as the web's `Machining.seek(move)`; the stock gets there over the
 * next draws (at most 20,000 moves a draw) or at once on `cadaclysm_view_machining_heights`
 * (1.7). False for an id that is no machining, or a move past its end.
 *
 * The terminal library refuses it: it has no machining ("no machining N is shown").
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_machining_seek(struct CadaclysmView *view, uint32_t item, uint32_t to);

/**
 * Colours the machining `item`'s stock from the next draw (1.7): `CADACLYSM_VIEW_COLOUR_BY_*`.
 * False for an id that is no machining, another `mode`, or colouring by deviation a machining
 * shown with no part.
 *
 * The terminal library refuses it: it has no machining ("no machining N is shown").
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_machining_colour_by(struct CadaclysmView *view, uint32_t item, uint32_t mode);

/**
 * Turns the machining `item`'s toolpath and tool on or off (both on when shown), from the next
 * draw (1.7). False for an id that is no machining.
 *
 * The terminal library refuses it: it has no machining ("no machining N is shown").
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_machining_overlays(struct CadaclysmView *view,
                                       uint32_t item,
                                       bool path,
                                       bool tool);

/**
 * Fills `out` with the machining `item`'s facts (1.7): its `moves`, the `move` the stock is at
 * (as of the last draw or `cadaclysm_view_machining_heights`), the heights' grid `nx` x `ny`,
 * its `cell` and cell (0, 0)'s corner `min` in mm, and the job's `cycle_time` in seconds.
 * `out->size` is left as the caller set it. False for a NULL or undersized `out`, an id that
 * is no machining, or a stock lost with the GPU device and not drawn again yet.
 *
 * The terminal library refuses it: it has no machining ("no machining N is shown").
 *
 * `view` must be NULL or a live view; `out` NULL or a `CadaclysmViewMachiningInfo` of at
 * least `out->size` bytes.
 */
bool cadaclysm_view_machining_info(struct CadaclysmView *view,
                                   uint32_t item,
                                   struct CadaclysmViewMachiningInfo *out);

/**
 * Settles the machining `item`'s track at the timeline's time, with no limit on its work,
 * then reads its stock's heights back, blocking (it polls the device, at most 10 s), into
 * `heights` (1.7): `capacity` floats, at least `nx * ny` of `cadaclysm_view_machining_info`;
 * rows y then x (`z[j * nx + i]`), mm, as `Machining.heights()` on the web. False for an id
 * that is no machining, a NULL `heights`, a `capacity` too small (the reason says how many
 * floats are needed), or heights that did not land within 10 s.
 *
 * The terminal library refuses it: it has no machining ("no machining N is shown").
 *
 * `view` must be NULL or a live view; `heights` NULL or `capacity` writable floats.
 */
bool cadaclysm_view_machining_heights(struct CadaclysmView *view,
                                      uint32_t item,
                                      float *heights,
                                      size_t capacity);

/**
 * Plays the view's timeline at `speed` times real time (1.7): each `cadaclysm_view_draw` (so
 * `cadaclysm_view_pump` and `cadaclysm_view_run`) and `cadaclysm_view_image` moves it by the
 * wall-clock time since the last. At the end of a timeline that does not loop it starts
 * again from 0. False for a speed not positive and finite.
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_timeline_play(struct CadaclysmView *view, double speed);

/**
 * Stops the view's timeline where it is (1.7); a track still catching up to that time
 * carries on over the next draws.
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_timeline_pause(struct CadaclysmView *view);

/**
 * Sets the view's timeline to `seconds` (1.7), clamped to [0, duration], NaN as 0; every
 * track gets there over the next draws (a machining stamps at most 20,000 moves a draw),
 * playing or not: `cadaclysm_view_needs_draw` stays true until they have.
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_timeline_seek(struct CadaclysmView *view, double seconds);

/**
 * Whether playing past the end of the view's timeline wraps to its start (1.7); off when the
 * view is made.
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_timeline_set_loop(struct CadaclysmView *view, bool on);

/**
 * The view's timeline's clock, in seconds (1.7); 0 for a NULL view.
 *
 * `view` must be NULL or a live view.
 */
double cadaclysm_view_timeline_time(const struct CadaclysmView *view);

/**
 * The view's timeline's length in seconds (1.7): the latest end of its tracks, 0 with none
 * (always, in the terminal library) and for a NULL view.
 *
 * `view` must be NULL or a live view.
 */
double cadaclysm_view_timeline_duration(const struct CadaclysmView *view);

/**
 * Whether the view's timeline plays (1.7): it stops by itself at the end of a timeline that
 * does not loop. False for a NULL view.
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_timeline_playing(const struct CadaclysmView *view);

/**
 * Where the view's timeline's tracks are (1.7), one UTF-8 line per track in the order they
 * were added, joined by a newline with none after the last ("" with no tracks); a
 * machining's reads "move 120 of 2206 · T1 flat 6 mm · X10.0 Y20.0 Z5.0", as of the last
 * draw. Returns the text's length in bytes, not counting the NUL; writes it NUL-terminated
 * into `text` only when `capacity` is more than that length, else writes nothing (`text`
 * NULL with `capacity` 0 asks the length). 0 for a NULL view.
 *
 * `view` must be NULL or a live view; `text` NULL or `capacity` writable bytes.
 */
size_t cadaclysm_view_timeline_status(const struct CadaclysmView *view,
                                      char *text,
                                      size_t capacity);

/**
 * Shows a kernel solid by its handle, read in place: exact surfaces where they draw,
 * triangles at `tolerance` (0: 0.05) otherwise, its edges, its paint (or `rgb` over it).
 * The item's id, 0 on failure. The solid must stay alive until the item is removed or the
 * view destroyed. Needs `cadaclysm_blacksmith` loaded in the process; the view never links it.
 * Fails, with the reason, where the kernel is not loaded or is too old for this library (it
 * lacks a call the view reads a solid through).
 *
 * The item's faces -- what a pick reports and `cadaclysm_view_set_face_colours` takes --
 * are numbered as the solid numbers them (`cadaclysm_blacksmith_face_count`'s faces),
 * exact or as triangles.
 *
 * `view` must be NULL or a live view; `solid` NULL or a live solid of the loaded kernel;
 * `rgb` NULL or three floats.
 */
uint32_t cadaclysm_view_show_solid(struct CadaclysmView *view,
                                   const CadaclysmBlacksmithSolid *solid,
                                   double tolerance,
                                   const float *rgb);

/**
 * `cadaclysm_view_show_solid` in a material and an opacity, all the solid's faces or only
 * some (1.21): `material` one of `CADACLYSM_VIEW_MATERIAL_*`, `opacity` 0..1 (1 opaque),
 * `faces` NULL for every face, else `face_count` of the solid's face numbers to show
 * alone, with no edges -- a trim's ghost. The item's faces are numbered as the solid
 * numbers them, `faces` or not. 0 on failure: `cadaclysm_view_show_solid`'s, a material
 * not one of the seven, an opacity outside 0..1, or a face the solid does not have.
 *
 * `view` must be NULL or a live view; `solid` NULL or a live solid of the loaded kernel;
 * `rgb` NULL or three floats; `faces` NULL or `face_count` words.
 */
uint32_t cadaclysm_view_show_solid_faces(struct CadaclysmView *view,
                                         const CadaclysmBlacksmithSolid *solid,
                                         double tolerance,
                                         const float *rgb,
                                         uint32_t material,
                                         float opacity,
                                         const uint32_t *faces,
                                         uint32_t face_count);

/**
 * A font for every view of this library: TTF or OTF bytes, copied in. Font 0 is the
 * bundled one and needs no loading. The font's id; 0 on failure (bytes that are not a
 * font, an empty font, a font with no outlines), with the reason.
 *
 * `bytes` must be NULL or readable for `length` bytes.
 */
uint32_t cadaclysm_view_load_font(const uint8_t *bytes, size_t length);

/**
 * Text shown as one item (a label or world text, as `text->mode` says); its id, 0 on
 * failure (NULL or non-UTF-8 text, an unknown mode, align or font, a height not finite
 * and positive, a number not finite, world `right` and `up` parallel), with the reason.
 *
 * The terminal library: accepted with a difference -- a label is printed as terminal
 * characters over the picture, one character row a line whatever its `height`, at the
 * cell under its anchor (`offset` and `box_padding` turned into whole cells, alignment
 * counted in characters), and picked on those cells; world text draws into the picture.
 *
 * `view` must be NULL or a live view; `text` NULL or a `CadaclysmViewText` of
 * `text->size` bytes whose `text` is NULL or a NUL-terminated string.
 */
uint32_t cadaclysm_view_show_text(struct CadaclysmView *view, const struct CadaclysmViewText *text);

/**
 * The item's string replaced, nothing else changed. False for an item that is not text,
 * or text that is NULL or not UTF-8.
 *
 * `view` must be NULL or a live view; `text` NULL or a NUL-terminated string.
 */
bool cadaclysm_view_set_text(struct CadaclysmView *view, uint32_t item, const char *text);

/**
 * Viewport `viewport`'s camera: what it draws with now (rect, view, projection, eye) and its
 * kind and state, `CADACLYSM_VIEW_CAMERA_*`. With no viewports set, viewport 0 is the
 * built-in orbit camera. False past the last viewport. `out.size` must be at least the 1.10
 * struct's. The render view library refuses a viewport other than 0: it has the one camera.
 *
 * `view` must be NULL or a live view; `out` NULL or a `CadaclysmViewViewportCamera` of
 * `out->size` bytes.
 */
bool cadaclysm_view_viewport_camera(const struct CadaclysmView *view,
                                    uint32_t viewport,
                                    struct CadaclysmViewViewportCamera *out);

/**
 * Gives viewport `viewport` a camera of `camera->kind`, from that kind's fields (its `rect`
 * is not read: `cadaclysm_view_set_viewport_rects`). With no viewports set only an orbit
 * camera fits viewport 0. A `distance`, `speed`, `radius` or `height` that is not positive
 * takes its default (1, 1, 1, 100). False, changing nothing, for a value not finite, an ortho
 * basis that is not unit and perpendicular, a kind not `CADACLYSM_VIEW_CAMERA_*`. The render
 * view library refuses a viewport other than 0, and any kind but an orbit camera.
 *
 * `view` must be NULL or a live view; `camera` NULL or a struct of `camera->size` bytes.
 */
bool cadaclysm_view_set_viewport_camera(struct CadaclysmView *view,
                                        uint32_t viewport,
                                        const struct CadaclysmViewViewportCamera *camera);

/**
 * Moves the viewports: `count` rects of four `uint32_t` (x, y, width, height, physical
 * pixels), one a viewport, their cameras untouched -- an empty rect hides a viewport and
 * keeps its camera. False unless `count` is the number of viewports set. The render view
 * library refuses it: it has one camera, so one viewport.
 *
 * `view` must be NULL or a live view; `rects` NULL or `4 * count` readable `uint32_t`s.
 */
bool cadaclysm_view_set_viewport_rects(struct CadaclysmView *view,
                                       const uint32_t *rects,
                                       uint32_t count);

/**
 * Turns viewport `viewport`'s camera to look along `direction` (three floats, world): an
 * orbit camera from that side of its target, a fly camera at its pivot from where it is, an
 * ortho camera square to it with `up` (three floats) its screen up -- NULL, zero or along
 * the direction: +Y up for a look along Z, else +Z. False for a fixed camera, a zero or
 * non-finite direction, no such viewport. The render view library refuses a viewport other
 * than 0.
 *
 * `view` must be NULL or a live view; `direction`, `up` NULL or three floats each.
 */
bool cadaclysm_view_aim(struct CadaclysmView *view,
                        uint32_t viewport,
                        const float *direction,
                        const float *up);

/**
 * The point (three floats, world) Alt and the left button orbit viewport `viewport` about;
 * NULL: its own target again. The render view library refuses it: it has a single camera
 * with no pivot.
 *
 * `view` must be NULL or a live view; `point` NULL or three floats.
 */
bool cadaclysm_view_set_pivot(struct CadaclysmView *view, uint32_t viewport, const float *point);

/**
 * A click's most travel (`px`, physical pixels) and longest press (`ms`; 0: no limit) for
 * `cadaclysm_view_input` to pick. Default 10 px, 500 ms. False, changing nothing, for a
 * negative or non-finite value.
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_set_tap(struct CadaclysmView *view, float px, double ms);

/**
 * `cadaclysm_view_orbit` on viewport `viewport` (by its camera: a fly camera orbits its
 * pivot, an ortho one pans; a fixed one does not move). Past the last viewport: nothing.
 *
 * `view` must be NULL or a live view.
 */
void cadaclysm_view_orbit_in(struct CadaclysmView *view, uint32_t viewport, float dx, float dy);

/**
 * `cadaclysm_view_pan` on viewport `viewport`. Past the last viewport: nothing.
 *
 * `view` must be NULL or a live view.
 */
void cadaclysm_view_pan_in(struct CadaclysmView *view, uint32_t viewport, float dx, float dy);

/**
 * `cadaclysm_view_zoom` on viewport `viewport`: an ortho camera zooms about its centre, a
 * fly camera dollies. Past the last viewport: nothing.
 *
 * `view` must be NULL or a live view.
 */
void cadaclysm_view_zoom_in(struct CadaclysmView *view, uint32_t viewport, float steps);

/**
 * `cadaclysm_view_look` on viewport `viewport`. Past the last viewport: nothing.
 *
 * `view` must be NULL or a live view.
 */
void cadaclysm_view_look_in(struct CadaclysmView *view, uint32_t viewport, float dx, float dy);

/**
 * `cadaclysm_view_dolly` on viewport `viewport`. Past the last viewport: nothing.
 *
 * `view` must be NULL or a live view.
 */
void cadaclysm_view_dolly_in(struct CadaclysmView *view, uint32_t viewport, float ratio);

/**
 * `cadaclysm_view_frame` on viewport `viewport`: `item` 0 fits everything shown.
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_frame_in(struct CadaclysmView *view, uint32_t viewport, uint32_t item);

/**
 * `cadaclysm_view_standard` on viewport `viewport`: an ortho camera turns to the named
 * plane (ISO refused); a fly or fixed one answers true with nothing moved. False past the
 * last viewport.
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_standard_in(struct CadaclysmView *view, uint32_t viewport, uint32_t which);

/**
 * Creates a view on the host's own device and queue: it draws into a texture on that device,
 * handed back by `cadaclysm_view_texture` after each draw. NULL with the reason otherwise.
 *
 * **The host's objects.** `device` and `queue` (and for Vulkan `instance` and
 * `physical_device`) are the host's: it keeps them alive until `cadaclysm_view_destroy`, and the
 * view destroys none of them. The view submits on `queue` from wherever the host calls
 * `cadaclysm_view_draw`, so the host calls it where it submits its own work (or under its own
 * lock).
 *
 * **Sync.** Queue order: the host submits the work that samples the texture after the draw.
 * Every call on the view may submit on the host's queue or wait on it -- not only
 * `cadaclysm_view_draw`, but `cadaclysm_view_resize`, `cadaclysm_view_image`, a pick, and
 * `cadaclysm_view_destroy`, which waits until the queue is idle -- so the host makes all of them
 * where it submits its own work, or under its own queue lock.
 *
 * **Adopt first.** After a resize (and on the first frame) `cadaclysm_view_texture` reports the
 * new texture with `drawn` 0: the host makes its first use of it -- wraps it, transitions it to
 * sampled use -- before the next `cadaclysm_view_draw`.
 *
 * **Hand back.** The view leaves the texture in `state` (Vulkan `SHADER_READ_ONLY_OPTIMAL`;
 * D3D12 `PIXEL_SHADER_RESOURCE | NON_PIXEL_SHADER_RESOURCE`); a host that uses it other than by
 * sampling returns it to that state afterwards.
 *
 * **Vulkan features.** wgpu enables and relies on `robustBufferAccess`, `independentBlend`,
 * `sampleRateShading`, `imageCubeArray`, `samplerAnisotropy`, `fragmentStoresAndAtomics` and
 * `multiDrawIndirect` wherever the GPU has them, and on `timelineSemaphore`, `robustImageAccess`,
 * `robustBufferAccess2`, `robustImageAccess2` and `shaderZeroInitializeWorkgroupMemory` (in the
 * chain's `pNext`): a device lacking any of them the GPU supports is refused, naming it. `enabled_features` gives the device's features; a device wgpu made
 * passes `CADACLYSM_VIEW_DEVICE_WGPU` instead.
 *
 * D3D12 host devices need a library built with them (`dx12-host-device`); without, D3D12 is
 * refused in favour of `cadaclysm_view_create_shared`. A D3D11 device cannot host the view.
 *
 * `width` and `height` must fit the device's largest 2D texture.
 *
 * `device` must be NULL or point at a `CadaclysmViewDevice` of at least the 1.12 size;
 * `options` NULL or a `CadaclysmViewOptions`.
 */
struct CadaclysmView *cadaclysm_view_create_on_device(const struct CadaclysmViewDevice *device,
                                                      const struct CadaclysmViewOptions *options);

/**
 * Creates a view on its own queue -- and its own device, except where the OS hands out one
 * device per GPU per process (in-process D3D12 and Metal: the host's device, the view's own
 * queue) -- on the host's GPU, drawing into a ring of three textures it exports as native shared
 * handles, with a ready fence it signals and a release fence the host signals. NULL with the
 * reason otherwise.
 *
 * **The adapter** is the host's, by id: `adapter_luid` for a D3D12 or D3D11 host (a D3D12 view),
 * `device_uuid` and `driver_uuid` for a Vulkan host (OPAQUE handles import only into the same
 * driver), `registry_id` for a Metal host. Never by name.
 *
 * **The ring.** Frames are numbered from 1 and never reset: frame *n* has `ready_value` =
 * `release_value` = *n*. A draw takes a free slot -- never drawn in this generation, or released
 * by the host -- and never waits on the host: with none free, `cadaclysm_view_draw` returns false
 * ("no released texture: the host has not released a frame") and the frame stays owed.
 *
 * **Sync.** The host waits on its own queue for the ready fence to reach `ready_value` before it
 * samples, and signals the release fence to `release_value` once its sampling work is submitted
 * (D3D12 `ID3D12CommandQueue::Wait`/`Signal`, D3D11 `ID3D11DeviceContext4::Wait`/`Signal`, Metal
 * `encodeWaitForEvent`/`encodeSignalEvent`, Vulkan timeline semaphores). A Vulkan host without
 * `CADACLYSM_VIEW_SHARED_HOST_SEMAPHORES` gets no fences: `cadaclysm_view_draw` returns with its
 * frame done, and the host releases with `cadaclysm_view_release`. Vulkan images are handed over
 * in `SHADER_READ_ONLY_OPTIMAL`, released to `VK_QUEUE_FAMILY_EXTERNAL`: the host acquires each
 * from it before use and releases it back after.
 *
 * **Adopt first.** On creation and after every resize or rebuilt device (`generation` + 1) every
 * slot is new: the host imports each (`cadaclysm_view_texture` with `slot` 0, 1, 2) before the
 * next draw.
 *
 * `shared` must be NULL or point at a `CadaclysmViewShared` of at least the 1.12 size;
 * `options` NULL or a `CadaclysmViewOptions`.
 */
struct CadaclysmView *cadaclysm_view_create_shared(const struct CadaclysmViewShared *shared,
                                                   const struct CadaclysmViewOptions *options);

/**
 * The texture of the last draw -- or, on creation and right after a resize, the new texture
 * undrawn (`drawn` 0) for the host to adopt -- written to `out` up to `out->size` bytes. On a
 * host-device view: `kind` `VULKAN_IMAGE` (`texture` the `VkImage`, `state`
 * `VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL`), `METAL_TEXTURE` (the `id<MTLTexture>`, `state` 0)
 * or `D3D12_RESOURCE` (the `ID3D12Resource*`, `state` `PIXEL_SHADER_RESOURCE |
 * NON_PIXEL_SHADER_RESOURCE`); `slot` 0 of 1; no fences. Owned by the view: valid until the next
 * generation or `cadaclysm_view_destroy`. On a shared view: after a draw, the slot it filled
 * (`drawn` 1, its `ready_value` and `release_value`), whatever `out->slot` says; while the
 * generation is undrawn, the slot named by `out->slot` **on input** (`drawn` 0, values 0), so the
 * host adopts every slot of the three -- out of range refused; `kind` `WIN32_HANDLE` (an NT
 * handle in `texture`), `POSIX_FD` (`fd`; import a `dup()`) or `METAL_SHARED` (an
 * `MTLSharedTextureHandle`), the fences' handles or fds, `memory_size` for a Vulkan import,
 * `state` D3D12 `COMMON` / Vulkan `SHADER_READ_ONLY_OPTIMAL` / Metal 0. Every handle and fd is the
 * view's: valid until the next generation or `cadaclysm_view_destroy`; the host opens or imports
 * its own. False with the reason on a view that draws into a window or offscreen.
 *
 * `out->size` must reach at least `generation` (an older, shorter struct cannot carry the
 * texture): smaller is refused.
 *
 * `view` must be NULL or a live view; `out` NULL or a `CadaclysmViewTexture` whose `size` the
 * caller set.
 */
bool cadaclysm_view_texture(struct CadaclysmView *view, struct CadaclysmViewTexture *out);

/**
 * The host's release of `release_value` on the CPU, for a host that cannot signal the release
 * fence (Vulkan shared mode without `CADACLYSM_VIEW_SHARED_HOST_SEMAPHORES`), once its sampling
 * work has completed -- refused past the last frame drawn. On every other view a no-op that
 * returns true.
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_release(struct CadaclysmView *view, uint64_t release_value);

/**
 * Fills `out` with how the KMS `view` draws onto its display (1.19): its buffers' `path`
 * (`CADACLYSM_VIEW_KMS_GBM`, `_GPU` or `_COPY`), their format and modifier, the connector,
 * the mode, the display's device and the Vulkan device that draws. `out->size` is left as the
 * caller set it. A view of `CADACLYSM_VIEW_WINDOW_KMS` and a window of the view's own at a
 * console answer; false, with "draws onto no KMS display", for any other view, and for a NULL
 * or undersized `out`.
 *
 * The terminal library refuses it: "KMS displays need the wgpu view library".
 *
 * `view` must be NULL or a live view; `out` NULL or a `CadaclysmViewKmsInfo` of at least
 * `out->size` bytes.
 */
bool cadaclysm_view_kms_info(const struct CadaclysmView *view, struct CadaclysmViewKmsInfo *out);

/**
 * Fills `out` with how `cadaclysm_view_create` would draw onto the display `window` names
 * (1.19), without taking the display or drawing: a window of `CADACLYSM_VIEW_WINDOW_KMS`, read
 * as `create` reads it, or NULL for the display a window of the view's own takes at a console
 * (the first connected output at its preferred mode). The same output and Vulkan device are
 * chosen as `create` would choose; for `CADACLYSM_VIEW_KMS_GBM` one buffer is made and taken by
 * the display, then freed, so its modifier is the one `create` would get. False, with the
 * reason `create` would give, where it would be refused -- the display has another master (a
 * compositor), no connected output, no Vulkan device, the host's mode is not the connector's
 * -- and for a NULL or undersized `out`. Slow: it enumerates the Vulkan devices. While a KMS
 * view of this process is open, a probe that opens the display itself finds that view its
 * master and says so; `cadaclysm_view_kms_info` answers for it.
 *
 * The terminal library refuses it: "KMS displays need the wgpu view library".
 *
 * `window` must be NULL or point at a `CadaclysmViewWindow` of at least its `size` bytes,
 * `window->display` NULL or an `int`, an open DRM fd; `out` NULL or a `CadaclysmViewKmsInfo`
 * of at least `out->size` bytes.
 */
bool cadaclysm_view_kms_probe(const struct CadaclysmViewWindow *window,
                              struct CadaclysmViewKmsInfo *out);

/**
 * How the view snaps from now on: the `CADACLYSM_VIEW_SNAP_*` kinds a snap may land on (0
 * switches snapping off, as a new view starts), how far from the cursor it reaches
 * (`aperture_px` points, 0 for the default 10, otherwise clamped to 2-32, times the screen
 * density), and whether the view draws the marker at the last snap (`marker` 1). Turning
 * snapping or the marker off hides the marker shown.
 *
 * False, changing nothing, for a NULL or undersized `settings`, `kinds` with bits past
 * `CADACLYSM_VIEW_SNAP_ALL`, an `aperture_px` that is negative or not finite, and a `marker`
 * other than 0 or 1.
 *
 * The terminal library refuses it: "snapping needs the wgpu view library".
 *
 * `view` must be NULL or a live view; `settings` NULL or a `CadaclysmViewSnapSettings` of
 * at least `settings->size` bytes.
 */
bool cadaclysm_view_set_snap(struct CadaclysmView *view,
                             const struct CadaclysmViewSnapSettings *settings);

/**
 * Asks for the snap under pixel (`x`, `y`) of `viewport`, in physical pixels from its own top
 * left, as `cadaclysm_view_request_pick_in` asks for a pick. The answer comes on a later call
 * to `cadaclysm_view_snap_result`, after a draw; `cadaclysm_view_needs_draw` is true until it
 * has landed. A new request replaces one still pending; a device loss drops it.
 *
 * A view fed `cadaclysm_view_input`, or in its own window, also asks snaps itself once
 * snapping is on: under a mouse hovering with no button down, and under each click (the
 * answer's `clicks` 1 or 2). `snap_result` answers the latest; a hover's never replaces a
 * click's not read yet.
 *
 * The terminal library refuses it: "snapping needs the wgpu view library".
 *
 * `view` must be NULL or a live view.
 */
void cadaclysm_view_request_snap_in(struct CadaclysmView *view,
                                    uint32_t viewport,
                                    uint32_t x,
                                    uint32_t y);

/**
 * The answer to the last snap asked -- by `cadaclysm_view_request_snap_in`, or by the mouse
 * over a view in its own window or one fed `cadaclysm_view_input` -- into `out`, once it has
 * landed (a draw lands it). `kind` 0 where nothing in the kinds set lies within the aperture,
 * or snapping is off. False, with "no snap result", while none has landed; each answer is
 * read once. Still answers once the view's window is closed, as `cadaclysm_view_pick_result`
 * does.
 *
 * The terminal library refuses it: "snapping needs the wgpu view library".
 *
 * `view` must be NULL or a live view; `out` NULL or a `CadaclysmViewSnap` of at least
 * `out->size` bytes.
 */
bool cadaclysm_view_snap_result(struct CadaclysmView *view, struct CadaclysmViewSnap *out);

/**
 * Hides the snap marker and drops any snap asked and not yet answered, or answered and not
 * yet read. The next snap shows the marker again.
 *
 * The terminal library refuses it: "snapping needs the wgpu view library".
 *
 * `view` must be NULL or a live view.
 */
void cadaclysm_view_clear_snap(struct CadaclysmView *view);

/**
 * A work plane for `CADACLYSM_VIEW_SNAP_GRID` and `_PLANE` snaps in place of the viewport's
 * grid plane: its `origin`, its `x_axis` and its `normal`, three doubles each in world
 * coordinates (the axes need not be unit; the x axis is made square to the normal), and its
 * grid's `step`, 0 for the drawn grid's.
 *
 * False, changing nothing, for a NULL array, a value that is not finite, a negative `step`,
 * and an `x_axis` or `normal` of no length, or the two parallel.
 *
 * The terminal library refuses it: "snapping needs the wgpu view library".
 *
 * `view` must be NULL or a live view; `origin`, `x_axis` and `normal` NULL or three doubles
 * each.
 */
bool cadaclysm_view_set_work_plane(struct CadaclysmView *view,
                                   const double *origin,
                                   const double *x_axis,
                                   const double *normal,
                                   double step);

/**
 * Goes back to the viewport's grid plane for `CADACLYSM_VIEW_SNAP_GRID` and `_PLANE` snaps.
 *
 * The terminal library refuses it: "snapping needs the wgpu view library".
 *
 * `view` must be NULL or a live view.
 */
bool cadaclysm_view_clear_work_plane(struct CadaclysmView *view);

#ifdef __cplusplus
}  // extern "C"
#endif  // __cplusplus

#endif  /* CADACLYSM_VIEW_H */
