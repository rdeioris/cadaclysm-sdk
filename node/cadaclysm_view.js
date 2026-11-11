'use strict';
/**
 * Drawing through cadaclysm_view.h: the terminal by default, the GPU window with
 * `useWgpu()`, a host's window with `View.inWindow`, or offscreen with `View.offscreen`.
 *
 *     const view = require('cadaclysm/view');
 *     view.useWgpu();
 *     const v = new view.View({ title: 'Part', width: 900, height: 600 });
 *     const item = v.showSolid(part);     // by handle: read in place, exact surfaces
 *     v.standard('iso'); v.frame();
 *     v.run();                            // blocks until the window is closed
 *
 * The library is loaded on first use, and the reader and kernel are not: a script that
 * only draws curves or meshes loads the view library alone. `solid.show()` replaces what
 * one shared window shows and returns; a 16 ms timer keeps every open window live and
 * holds the process until the last one is closed. An `Item` holds the object it shows. A
 * view nobody holds is destroyed by a `FinalizationRegistry`; `close()` does it at once.
 */
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const { constants: bufferConstants } = require('node:buffer');
const koffi = require('koffi');
// `using x = ...` looks up Symbol.dispose: Node 22 aliases it to Symbol.for('nodejs.dispose'),
// a V8 with its own Symbol.dispose does not, so name the one this runtime uses.
const DISPOSE = typeof Symbol.dispose === 'symbol' ? Symbol.dispose : Symbol.for('nodejs.dispose');

const ABI_MAJOR = 1;
// 1.5: `cadaclysm_view_parse_colour`, which every colour argument's text goes through.
// 1.6: text -- cadaclysm_view_show_text, _set_text, _load_font and the text layer.
// 1.7: the machining and timeline calls (showMachining, Machining, the transport).
// 1.8: the pick's `clicks` and `point`, cadaclysm_view_set_double_click_frames, _focus, _navigation.
// 1.9: cadaclysm_view_set_lighting and _lighting (headlight or studio).
// 1.10: the viewport cameras (bound; Node's own API for them comes later).
// 1.11: cadaclysm_view_show_points.
// 1.13: cadaclysm_view_set_occluded.
// 1.18: cadaclysm_view_set_finish.
// 1.20: cadaclysm_view_set_occluded_style and _occluded_style (View.occludedStyle).
// 1.21: cadaclysm_view_show_solid_faces (a solid in a material and an opacity, all or some faces).
// 1.22: snapping -- cadaclysm_view_set_snap, _request_snap_in, _snap_result, _clear_snap, _set_work_plane, _clear_work_plane.
const ABI_MINOR = 22;
const OPEN = 1;
const CLOSED = 2;
const SURFACES = Object.freeze({ exact: 0, triangles: 1 });
const TOOL_SHAPES = Object.freeze({ flat: 0, ball: 1, drill: 2, vbit: 3, bullnose: 4 });
const COLOUR_BY = Object.freeze({ height: 0, tool: 1, deviation: 2 });
const LIGHTING = Object.freeze({ headlight: 0, studio: 1 });
const OCCLUDED = Object.freeze({ off: 0, solid: 1, dashed: 2 });
const FINISH = Object.freeze({ gloss: 0, satin: 1, matte: 2 });
const MATERIAL = Object.freeze({ default: 0, plastic: 1, metal: 2, matte: 3, paint: 4, brushed: 5, glass: 6 });
// The CADACLYSM_VIEW_SNAP_* bits by the names setSnap takes and a snap's `kind` reports.
const SNAP_KINDS = Object.freeze({ vertex: 1, midpoint: 2, centre: 4, quadrant: 8, edge: 16, face: 32, grid: 64, plane: 128 });
const SNAP_NONE = 0xFFFFFFFF;   // CadaclysmViewSnap.edge where the snap is on no edge
const STANDARD = Object.freeze({ top: 0, front: 1, right: 2, iso: 3 });
const ALIGN = Object.freeze({ 'top-left': 0, top: 1, 'top-right': 2, left: 3, centre: 4, center: 4, right: 5,
  'bottom-left': 6, bottom: 7, 'bottom-right': 8 });
const TEXT_MODES = Object.freeze({ label: 0, world: 1 });
const LAYER = Object.freeze({ surfaces: 0, edges: 1, curves: 2, isocurves: 3, grid: 4, text: 5 });
const EVENT = Object.freeze({ pointer_down: 1, pointer_move: 2, pointer_up: 3, pointer_cancel: 4, wheel: 5, key: 6 });
const GRID = Object.freeze({ none: 0, top: 1, front: 2, right: 3 });
const LOD_MOTION = Object.freeze({ detailed: 0, smooth: 1 });
const NAVIGATION_FLY = 1;       // CADACLYSM_VIEW_NAVIGATION_FLY (ORBIT is 0)
const INPUT_CLOSE = 1;
const NONE_COMING = 0xFFFFFFFF;   // cadaclysm_view_wake_ms: no wake is coming
const POINTER = Object.freeze({ mouse: 0, touch: 1, pen: 2 });
const WINDOW = Object.freeze({ win32: 1, xlib: 2, xcb: 3, wayland: 4, appkit: 5 });
const VIEWS = Object.freeze({ front: [-90, 0], back: [90, 0], left: [180, 0], right: [0, 0], top: [-90, 90], bottom: [-90, -90], iso: [-50, 28] });
const ORBIT_PER_PIXEL = 0.01;   // cadaclysm_view::view::ORBIT_PER_PIXEL
const ZOOM_PER_STEP = 0.9;      // cadaclysm_view::view::ZOOM_PER_STEP

/** A view library could not be found, loaded, or refused a call -- with its own reason. */
class ViewError extends Error {
  constructor(message) { super(message); this.name = 'ViewError'; }
}

// ---- the ABI's types: one field per line, as tests/bindings.rs reads them ----------------

koffi.opaque('CadaclysmView');
koffi.struct('CadaclysmViewWindow', {
  size: 'uint32_t',
  kind: 'uint32_t',
  window: 'void *',
  window_id: 'uint64_t',
  display: 'void *',
  width: 'uint32_t',
  height: 'uint32_t',
});
koffi.struct('CadaclysmViewOptions', {
  size: 'uint32_t',
  surfaces: 'uint32_t',
  backend: 'uint32_t',
  y_up: 'uint32_t',
  title: 'const char *',
  width: 'uint32_t',
  height: 'uint32_t',
  offscreen: 'uint32_t',
});
koffi.struct('CadaclysmViewCamera', {
  size: 'uint32_t',
  eye: koffi.array('float', 3),
  target: koffi.array('float', 3),
  up: koffi.array('float', 3),
  orthographic: 'uint32_t',
});
koffi.struct('CadaclysmViewPick', {
  size: 'uint32_t',
  item: 'uint32_t',
  node: 'uint32_t',
  face: 'uint32_t',
  clicks: 'uint32_t',
  has_point: 'uint32_t',
  point: koffi.array('float', 3),
});
koffi.struct('CadaclysmViewLod', {
  size: 'uint32_t',
  min_triangles: 'uint32_t',
  motion: 'uint32_t',
});
koffi.struct('CadaclysmViewOccludedStyle', {
  size: 'uint32_t',
  dash: 'float',
  gap: 'float',
  dim: 'float',
  has_colour: 'uint32_t',
  colour: koffi.array('float', 3),
});
koffi.struct('CadaclysmViewSnapSettings', {
  size: 'uint32_t',
  kinds: 'uint32_t',
  aperture_px: 'float',
  marker: 'uint32_t',
});
koffi.struct('CadaclysmViewSnap', {
  size: 'uint32_t',
  kind: 'uint32_t',
  point: koffi.array('double', 3),
  item: 'uint32_t',
  node: 'uint32_t',
  face: 'uint32_t',
  edge: 'uint32_t',
  tangent: koffi.array('float', 3),
  axis: koffi.array('float', 3),
  radius: 'double',
  distance_px: 'float',
  clicks: 'uint32_t',
});
koffi.struct('CadaclysmViewViewport', {
  size: 'uint32_t',
  rect: koffi.array('uint32_t', 4),
  view: koffi.array('float', 16),
  projection: koffi.array('float', 16),
  eye: koffi.array('float', 3),
  grid: 'uint32_t',
  layer_mask: 'uint32_t',
});
koffi.struct('CadaclysmViewEvent', {
  size: 'uint32_t',
  kind: 'uint32_t',
  pointer_id: 'uint32_t',
  pointer: 'uint32_t',
  button: 'uint32_t',
  shift: 'uint32_t',
  x: 'float',
  y: 'float',
  wheel_y: 'float',
  key: 'const char *',
  key_down: 'uint32_t',
  time_ms: 'double',
  alt: 'uint32_t',
});
koffi.struct('CadaclysmViewMesh', {
  size: 'uint32_t',
  positions: 'const float *',
  vertex_count: 'uint32_t',
  normals: 'const float *',
  indices: 'const uint32_t *',
  index_count: 'uint32_t',
  edges: 'const float *',
  edge_count: 'uint32_t',
  rgb: 'const float *',
});
koffi.struct('CadaclysmViewImage', {
  size: 'uint32_t',
  corners: koffi.array('float', 12),
  rgba: 'const uint8_t *',
  width: 'uint32_t',
  height: 'uint32_t',
  opacity: 'float',
  flip_x: 'uint32_t',
  flip_y: 'uint32_t',
});
koffi.struct('CadaclysmViewText', {
  size: 'uint32_t',
  text: 'const char *',
  mode: 'uint32_t',
  at: koffi.array('float', 3),
  right: koffi.array('float', 3),
  up: koffi.array('float', 3),
  height: 'float',
  rgb: koffi.array('float', 3),
  align: 'uint32_t',
  offset: koffi.array('float', 2),
  box_rgba: koffi.array('float', 4),
  box_padding: 'float',
  on_top: 'uint32_t',
  font: 'uint32_t',
});
koffi.struct('CadaclysmViewViewportCamera', {
  size: 'uint32_t',
  kind: 'uint32_t',
  rect: koffi.array('uint32_t', 4),
  view: koffi.array('float', 16),
  projection: koffi.array('float', 16),
  eye: koffi.array('float', 3),
  target: koffi.array('float', 3),
  distance: 'float',
  yaw: 'float',
  pitch: 'float',
  orthographic: 'uint32_t',
  speed: 'float',
  radius: 'float',
  height: 'float',
  axis_view: koffi.array('float', 3),
  axis_right: koffi.array('float', 3),
  axis_up: koffi.array('float', 3),
});
koffi.struct('CadaclysmViewProgram', {
  size: 'uint32_t',
  tool_number: 'uint32_t',
  tool_shape: 'uint32_t',
  tool_diameter: 'double',
  tool_flute_length: 'double',
  tool_angle: 'double',
  tool_corner_radius: 'double',
  gcode: 'const char *',
});
koffi.struct('CadaclysmViewMachining', {
  size: 'uint32_t',
  program_count: 'uint32_t',
  programs: 'const CadaclysmViewProgram *',
  stock_min: koffi.array('double', 3),
  stock_max: koffi.array('double', 3),
  part_positions: 'const float *',
  part_indices: 'const uint32_t *',
  part_vertex_count: 'uint32_t',
  part_index_count: 'uint32_t',
  cell: 'double',
  tolerance: 'double',
  skin: 'double',
  rapid_rate: 'double',
  skin_set: 'uint32_t',
});
koffi.struct('CadaclysmViewMachiningInfo', {
  size: 'uint32_t',
  moves: 'uint32_t',
  move: 'uint32_t',
  nx: 'uint32_t',
  ny: 'uint32_t',
  cell: 'float',
  min: koffi.array('float', 2),
  cycle_time: 'double',
});
const SIZE = (name) => koffi.sizeof(name);

// ---- the function table: every call of the header ------------------------------------
// A scene and a solid are `const void *` here: their koffi types belong to the reader's and
// the kernel's modules, and any koffi pointer passes as `void *`.

function _bind(l) {
  const f = (proto) => l.func(proto);
  return {
    abi_version: f('uint32_t cadaclysm_view_abi_version(void)'),
    last_error: f('const char *cadaclysm_view_last_error(void)'),
    name: f('const char *cadaclysm_view_name(void)'),
    parse_colour: f('bool cadaclysm_view_parse_colour(const char *text, _Out_ float *out)'),
    create: f('CadaclysmView *cadaclysm_view_create(const CadaclysmViewWindow *window, const CadaclysmViewOptions *options)'),
    destroy: f('void cadaclysm_view_destroy(CadaclysmView *view)'),
    pump: f('uint32_t cadaclysm_view_pump(CadaclysmView *view, uint32_t timeout_ms)'),
    run: f('bool cadaclysm_view_run(CadaclysmView *view, _Inout_ CadaclysmViewCamera *camera_out, _Inout_ CadaclysmViewPick *pick_out)'),
    resize: f('bool cadaclysm_view_resize(CadaclysmView *view, uint32_t width, uint32_t height)'),
    needs_draw: f('bool cadaclysm_view_needs_draw(const CadaclysmView *view)'),
    draw: f('bool cadaclysm_view_draw(CadaclysmView *view)'),
    show: f('uint32_t cadaclysm_view_show(CadaclysmView *view, const void *scene)'),
    remove: f('bool cadaclysm_view_remove(CadaclysmView *view, uint32_t item)'),
    set_surfaces: f('bool cadaclysm_view_set_surfaces(CadaclysmView *view, uint32_t surfaces)'),
    surfaces: f('uint32_t cadaclysm_view_surfaces(const CadaclysmView *view)'),
    orbit: f('void cadaclysm_view_orbit(CadaclysmView *view, float dx, float dy)'),
    pan: f('void cadaclysm_view_pan(CadaclysmView *view, float dx, float dy)'),
    zoom: f('void cadaclysm_view_zoom(CadaclysmView *view, float steps)'),
    frame: f('bool cadaclysm_view_frame(CadaclysmView *view, uint32_t item)'),
    standard: f('bool cadaclysm_view_standard(CadaclysmView *view, uint32_t which)'),
    set_orthographic: f('void cadaclysm_view_set_orthographic(CadaclysmView *view, bool on)'),
    set_layer: f('bool cadaclysm_view_set_layer(CadaclysmView *view, uint32_t layer, bool on)'),
    set_background: f('void cadaclysm_view_set_background(CadaclysmView *view, const float *rgb)'),
    set_lighting: f('bool cadaclysm_view_set_lighting(CadaclysmView *view, uint32_t lighting)'),
    lighting: f('uint32_t cadaclysm_view_lighting(const CadaclysmView *view)'),
    set_occluded_style: f('bool cadaclysm_view_set_occluded_style(CadaclysmView *view, const CadaclysmViewOccludedStyle *style)'),
    occluded_style: f('bool cadaclysm_view_occluded_style(const CadaclysmView *view, _Inout_ CadaclysmViewOccludedStyle *style)'),
    set_lod: f('bool cadaclysm_view_set_lod(CadaclysmView *view, const CadaclysmViewLod *lod)'),
    wake_ms: f('uint32_t cadaclysm_view_wake_ms(const CadaclysmView *view)'),
    set_node_visible: f('bool cadaclysm_view_set_node_visible(CadaclysmView *view, uint32_t item, uint32_t node, bool visible)'),
    set_node_color: f('bool cadaclysm_view_set_node_color(CadaclysmView *view, uint32_t item, uint32_t node, const float *rgba)'),
    set_node_highlight: f('bool cadaclysm_view_set_node_highlight(CadaclysmView *view, uint32_t item, uint32_t node, const float *rgba)'),
    set_viewports: f('bool cadaclysm_view_set_viewports(CadaclysmView *view, const CadaclysmViewViewport *viewports, uint32_t count)'),
    request_pick: f('void cadaclysm_view_request_pick(CadaclysmView *view, uint32_t x, uint32_t y)'),
    request_pick_in: f('void cadaclysm_view_request_pick_in(CadaclysmView *view, uint32_t viewport, uint32_t x, uint32_t y)'),
    pick_result: f('bool cadaclysm_view_pick_result(CadaclysmView *view, _Inout_ CadaclysmViewPick *out)'),
    set_snap: f('bool cadaclysm_view_set_snap(CadaclysmView *view, const CadaclysmViewSnapSettings *settings)'),
    request_snap_in: f('void cadaclysm_view_request_snap_in(CadaclysmView *view, uint32_t viewport, uint32_t x, uint32_t y)'),
    snap_result: f('bool cadaclysm_view_snap_result(CadaclysmView *view, _Inout_ CadaclysmViewSnap *out)'),
    clear_snap: f('void cadaclysm_view_clear_snap(CadaclysmView *view)'),
    set_work_plane: f('bool cadaclysm_view_set_work_plane(CadaclysmView *view, const double *origin, const double *x_axis, const double *normal, double step)'),
    clear_work_plane: f('bool cadaclysm_view_clear_work_plane(CadaclysmView *view)'),
    frame_node: f('bool cadaclysm_view_frame_node(CadaclysmView *view, uint32_t item, uint32_t node)'),
    look: f('void cadaclysm_view_look(CadaclysmView *view, float dx, float dy)'),
    dolly: f('void cadaclysm_view_dolly(CadaclysmView *view, float ratio)'),
    input: f('uint32_t cadaclysm_view_input(CadaclysmView *view, const CadaclysmViewEvent *event)'),
    show_mesh: f('uint32_t cadaclysm_view_show_mesh(CadaclysmView *view, const CadaclysmViewMesh *mesh)'),
    show_lines: f('uint32_t cadaclysm_view_show_lines(CadaclysmView *view, const float *segments, uint32_t segment_count, const float *rgb)'),
    show_points: f('uint32_t cadaclysm_view_show_points(CadaclysmView *view, const float *positions, uint32_t point_count, const float *rgb, float size_px)'),
    show_curves: f('uint32_t cadaclysm_view_show_curves(CadaclysmView *view, const float *beziers, uint32_t curve_count, const float *rgb)'),
    show_image: f('uint32_t cadaclysm_view_show_image(CadaclysmView *view, const CadaclysmViewImage *image)'),
    load_font: f('uint32_t cadaclysm_view_load_font(const uint8_t *bytes, size_t length)'),
    show_text: f('uint32_t cadaclysm_view_show_text(CadaclysmView *view, const CadaclysmViewText *text)'),
    set_text: f('bool cadaclysm_view_set_text(CadaclysmView *view, uint32_t item, const char *text)'),
    viewport_camera: f('bool cadaclysm_view_viewport_camera(const CadaclysmView *view, uint32_t viewport, _Inout_ CadaclysmViewViewportCamera *out)'),
    set_viewport_camera: f('bool cadaclysm_view_set_viewport_camera(CadaclysmView *view, uint32_t viewport, const CadaclysmViewViewportCamera *camera)'),
    set_viewport_rects: f('bool cadaclysm_view_set_viewport_rects(CadaclysmView *view, const uint32_t *rects, uint32_t count)'),
    aim: f('bool cadaclysm_view_aim(CadaclysmView *view, uint32_t viewport, const float *direction, const float *up)'),
    set_pivot: f('bool cadaclysm_view_set_pivot(CadaclysmView *view, uint32_t viewport, const float *point)'),
    set_tap: f('bool cadaclysm_view_set_tap(CadaclysmView *view, float px, double ms)'),
    orbit_in: f('void cadaclysm_view_orbit_in(CadaclysmView *view, uint32_t viewport, float dx, float dy)'),
    pan_in: f('void cadaclysm_view_pan_in(CadaclysmView *view, uint32_t viewport, float dx, float dy)'),
    zoom_in: f('void cadaclysm_view_zoom_in(CadaclysmView *view, uint32_t viewport, float steps)'),
    look_in: f('void cadaclysm_view_look_in(CadaclysmView *view, uint32_t viewport, float dx, float dy)'),
    dolly_in: f('void cadaclysm_view_dolly_in(CadaclysmView *view, uint32_t viewport, float ratio)'),
    frame_in: f('bool cadaclysm_view_frame_in(CadaclysmView *view, uint32_t viewport, uint32_t item)'),
    standard_in: f('bool cadaclysm_view_standard_in(CadaclysmView *view, uint32_t viewport, uint32_t which)'),
    set_colour: f('bool cadaclysm_view_set_colour(CadaclysmView *view, uint32_t item, const float *rgb)'),
    set_xray: f('bool cadaclysm_view_set_xray(CadaclysmView *view, uint32_t item, bool on)'),
    set_occluded: f('bool cadaclysm_view_set_occluded(CadaclysmView *view, uint32_t item, uint32_t mode)'),
    set_finish: f('bool cadaclysm_view_set_finish(CadaclysmView *view, uint32_t item, uint32_t finish)'),
    set_face_colours: f('bool cadaclysm_view_set_face_colours(CadaclysmView *view, uint32_t item, const uint32_t *faces, const float *rgba, uint32_t count)'),
    set_placement: f('bool cadaclysm_view_set_placement(CadaclysmView *view, uint32_t item, const double *matrix)'),
    set_node_transforms: f('bool cadaclysm_view_set_node_transforms(CadaclysmView *view, uint32_t item, const double *transforms, uint32_t count)'),
    show_machining: f('uint32_t cadaclysm_view_show_machining(CadaclysmView *view, const CadaclysmViewMachining *machining)'),
    machining_seek: f('bool cadaclysm_view_machining_seek(CadaclysmView *view, uint32_t item, uint32_t to)'),
    machining_colour_by: f('bool cadaclysm_view_machining_colour_by(CadaclysmView *view, uint32_t item, uint32_t mode)'),
    machining_overlays: f('bool cadaclysm_view_machining_overlays(CadaclysmView *view, uint32_t item, bool path, bool tool)'),
    machining_info: f('bool cadaclysm_view_machining_info(CadaclysmView *view, uint32_t item, _Inout_ CadaclysmViewMachiningInfo *out)'),
    machining_heights: f('bool cadaclysm_view_machining_heights(CadaclysmView *view, uint32_t item, _Out_ float *heights, size_t capacity)'),
    timeline_play: f('bool cadaclysm_view_timeline_play(CadaclysmView *view, double speed)'),
    timeline_pause: f('bool cadaclysm_view_timeline_pause(CadaclysmView *view)'),
    timeline_seek: f('bool cadaclysm_view_timeline_seek(CadaclysmView *view, double seconds)'),
    timeline_set_loop: f('bool cadaclysm_view_timeline_set_loop(CadaclysmView *view, bool on)'),
    timeline_time: f('double cadaclysm_view_timeline_time(const CadaclysmView *view)'),
    timeline_duration: f('double cadaclysm_view_timeline_duration(const CadaclysmView *view)'),
    timeline_playing: f('bool cadaclysm_view_timeline_playing(const CadaclysmView *view)'),
    timeline_status: f('size_t cadaclysm_view_timeline_status(const CadaclysmView *view, _Out_ uint8_t *text, size_t capacity)'),
    show_solid: f('uint32_t cadaclysm_view_show_solid(CadaclysmView *view, const void *solid, double tolerance, const float *rgb)'),
    show_solid_faces: f('uint32_t cadaclysm_view_show_solid_faces(CadaclysmView *view, const void *solid, double tolerance, const float *rgb, uint32_t material, float opacity, const uint32_t *faces, uint32_t face_count)'),
    image: f('bool cadaclysm_view_image(CadaclysmView *view, uint8_t *rgba, size_t capacity)'),
    size: f('bool cadaclysm_view_size(CadaclysmView *view, _Out_ uint32_t *width, _Out_ uint32_t *height)'),
    set_double_click_frames: f('void cadaclysm_view_set_double_click_frames(CadaclysmView *view, bool on)'),
    focus: f('bool cadaclysm_view_focus(CadaclysmView *view, const float *point)'),
    navigation: f('uint32_t cadaclysm_view_navigation(CadaclysmView *view)'),
  };
}

// ---- the library choice --------------------------------------------------------------

function _fileName(base) {
  if (process.platform === 'win32') return `${base}.dll`;
  if (process.platform === 'darwin') return `lib${base}.dylib`;
  return `lib${base}.so`;
}

function _ancestors(dir) {
  const out = [];
  for (let d = dir; ; d = path.dirname(d)) { out.push(d); if (path.dirname(d) === d) return out; }
}

const LIBRARIES = Object.freeze({
  terminal: ['cadaclysm_terminal', 'CADACLYSM_TERMINAL_LIBRARY'],
  wgpu: ['cadaclysm_view', 'CADACLYSM_VIEW_LIBRARY'],
});

/** Where `which` ('terminal' or 'wgpu') is: its variable, beside this file, `lib/` or `target/{release,debug}` above it.
 * `override` and `here` stand in for the variable's value and this file's folder (tests). */
function _find(which, override = process.env[LIBRARIES[which][1]], here = __dirname) {
  const [base, variable] = LIBRARIES[which];
  const name = _fileName(base);
  if (override) {
    let candidate = override;
    const isDir = fs.existsSync(candidate) && fs.statSync(candidate).isDirectory();
    if (isDir) candidate = path.join(candidate, name);
    if (fs.existsSync(candidate)) return candidate;
    // Python's words: the terminal's variable also says which file a directory lacks.
    throw new ViewError(`${variable}=${override} names nothing that exists`
      + (which === 'terminal' && isDir ? ` (no ${name} in that directory)` : ''));
  }
  const searched = [path.join(here, name)];
  for (const a of _ancestors(here)) searched.push(path.join(a, 'lib', name));
  for (const a of _ancestors(here)) searched.push(path.join(a, 'target', 'release', name), path.join(a, 'target', 'debug', name));
  for (const candidate of searched) if (fs.existsSync(candidate)) return candidate;
  throw new ViewError(which === 'terminal'
    ? `no view library: the terminal library was not found (searched: ${searched.join(', ')}) `
      + '-- reinstall cadaclysm, set CADACLYSM_TERMINAL_LIBRARY to the library, or set CADACLYSM_VIEW'
    : `no view library: ${name} was not found (searched: ${searched.join(', ')}) `
      + `-- reinstall cadaclysm, set ${variable} to it, or useTerminal()`);
}

/** One loaded view library: `fn` is its function table, by the header's names less the prefix. */
class Library {
  constructor(fn, libraryPath) {
    const version = fn.abi_version();
    const major = version >>> 16, minor = version & 0xFFFF;
    if (major !== ABI_MAJOR || minor < ABI_MINOR) {
      throw new ViewError(`${libraryPath ?? 'view library'}: view ABI ${major}.${minor}, this wrapper needs ${ABI_MAJOR}.${ABI_MINOR} or a later ${ABI_MAJOR}.x`);
    }
    this.fn = fn;
    this.path = libraryPath;
    this.name = String(fn.name() ?? '');
  }
  /** 'wgpu' (cadaclysm_view), 'terminal' (cadaclysm_terminal), or 'other' (a library of your own) -- Python's `Library.kind`. */
  get kind() { return this.name.startsWith('cadaclysm-view ') ? 'wgpu' : this.name.startsWith('cadaclysm-terminal ') ? 'terminal' : 'other'; }
  lastError() { return String(this.fn.last_error() ?? ''); }
  /** The library's own reason, bare (Python's `_error`); `what` names the call for the reader of the code only. */
  failure(what) { return new ViewError(this.lastError() || 'the view library failed'); }
}

function _load(libraryPath) {
  let l;
  try { l = koffi.load(libraryPath); } catch (e) { throw new ViewError(`${libraryPath}: could not load the view library: ${e.message}`); }
  // The ABI version before the rest, so a library missing a newer call says its version
  // rather than "no such symbol".
  let abi;
  try { abi = l.func('uint32_t cadaclysm_view_abi_version(void)'); } catch (_) {
    throw new ViewError(`${libraryPath}: not a view library (no abi version)`);
  }
  const version = abi();
  if (version >>> 16 !== ABI_MAJOR || (version & 0xFFFF) < ABI_MINOR) {
    throw new ViewError(`${libraryPath}: view ABI ${version >>> 16}.${version & 0xFFFF}, this wrapper needs ${ABI_MAJOR}.${ABI_MINOR} or a later ${ABI_MAJOR}.x`);
  }
  let fn;
  try { fn = _bind(l); } catch (e) { throw new ViewError(`${libraryPath}: not a view library: ${e.message}`); }
  return new Library(fn, libraryPath);
}

let _current = null;

/** Draw with the terminal library (the default) from now on. */
function useTerminal() { return _choose(_load(_find('terminal'))); }
// A TTF/OTF font for every view of the library in use: bytes (Uint8Array, Buffer or
// ArrayBuffer), or a file's path. Its id for showText's `font`; font 0 is the bundled Liberation Sans.
// Choose the library first (useWgpu/useTerminal/use): a font id belongs to the library that
// loaded it, and means nothing -- or another font -- to a library chosen afterwards.
function loadFont(font) {
  let bytes;
  if (typeof font === 'string') {
    try { bytes = fs.readFileSync(font); } catch (e) { throw new ViewError(`loadFont: cannot read ${JSON.stringify(font)}: ${e.code ?? e.message}`); }
  } else if (font instanceof ArrayBuffer) bytes = new Uint8Array(font);
  else if (font instanceof Uint8Array) bytes = font;
  else throw new ViewError(`loadFont: a path, a Uint8Array or an ArrayBuffer, not ${font === null ? 'null' : typeof font === 'object' ? font.constructor?.name ?? 'object' : typeof font}`);
  const lib = current();
  const id = lib.fn.load_font(bytes, bytes.length);
  if (!id) throw lib.failure('loadFont');
  return id;
}
/** Draw with the GPU window library, `cadaclysm_view`, from now on. */
function useWgpu() { return _choose(_load(_find('wgpu'))); }
/** Draw with the library at `library` -- or, for tests, a table of the header's functions by their short names. */
function use(library) {
  return _choose(typeof library === 'string' ? _load(library) : new Library(library, null));
}
/** The one way a library becomes the choice: any but the wgpu window's prints stills to stdout. */
function _choose(library) {
  _current = library;
  if (library.kind !== 'wgpu') _blockingStdio();
  return library;
}
/** The library in use: the last `use*()`, else `CADACLYSM_VIEW` (`terminal`, `wgpu` or a path), else the terminal. */
function current() {
  if (_current) return _current;
  const chosen = process.env.CADACLYSM_VIEW;
  if (chosen === 'wgpu') return useWgpu();
  if (!chosen || chosen === 'terminal') return useTerminal();
  return use(chosen);
}

// ---- keeping windows live --------------------------------------------------------------

const _open = new Set();   // views with a window of the library's own, still open
let _timer = null;

/**
 * The timer's pump. A failing pump is reported once, and the window it failed on is let go
 * (closed state; its destroy is still owed to `close()`), so a persistent failure ends the
 * wait for windows as it does in Python's script-end wait instead of warning every 16 ms for
 * ever with the process held.
 */
function _tick() {
  try { pump(0); } catch (e) {
    process.emitWarning(e.message);
    for (const v of [..._open]) if (v._pumpFailed) v._markClosed();
    if (![..._open].some((v) => v._pointer !== null && !v._windowClosed) && _timer) { clearInterval(_timer); _timer = null; }
  }
}

function _watch(v) {
  _open.add(v);
  if (!_timer) {
    // ref'd on purpose: it holds the process. A pump error is warned, not thrown, from a timer.
    _timer = setInterval(_tick, 16);
  }
}

/** Blocks the thread `ms` milliseconds (pump's wait with no window of its own, pick's retry). */
function _sleep(ms) { if (ms > 0) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); }

/**
 * Handles every open window's events, draws what is owed, waits at most `timeoutMs` (on the
 * first window only), and answers how many windows are still open. With no window open it
 * just waits `timeoutMs`, so a loop around it does not spin (Python's `pump`). Every window's
 * state is taken (a closed one is marked closed) before a refusal is thrown. The timer calls
 * it every 16 ms; a script's own loop may too.
 */
function pump(timeoutMs = 0) {
  timeoutMs = Math.max(0, Number(timeoutMs) || 0);   // a negative wait is none, as Python's
  const alive = [..._open].filter((v) => v._pointer !== null && !v._windowClosed);
  if (alive.length === 0) {
    _sleep(timeoutMs);
    if (_timer) { clearInterval(_timer); _timer = null; }
    return 0;
  }
  const states = alive.map((v, i) => v._lib.fn.pump(v._pointer, i === 0 ? timeoutMs : 0));
  const errors = [];
  alive.forEach((v, i) => {
    if (states[i] === CLOSED) v._markClosed();
    else if (states[i] !== OPEN) { v._pumpFailed = true; errors.push(v._lib.failure('pump')); }
  });
  const open = [..._open].filter((v) => !v._windowClosed).length;
  if (open === 0 && _timer) { clearInterval(_timer); _timer = null; }
  if (errors.length) throw errors[0];
  return open;
}

// Every live view, weakly: `_release` walks it when a scene closes.
const _views = new Set();

/**
 * Removes every item that shows `obj` (a Scene -- directly, or through one of its nodes or
 * poses) from every live view, before `obj`'s handle is freed: `cadaclysm_view.h` requires a
 * shown scene to stay open until its item is removed or the view destroyed. A view whose
 * window the user closed is destroyed instead (the destroy it owed anyway), which drops every
 * item at once. `Scene.close()` calls this first. (Node runs one thread per module instance,
 * so Python's other-thread rule has nothing to guard here.)
 */
function _release(obj) {
  for (const ref of [..._views]) {
    const v = ref.deref();
    if (!v) { _views.delete(ref); continue; }
    if (v._pointer === null) continue;
    const showing = [...v._items.values()].filter((i) => i.shown === obj || i.shown?.scene === obj);
    if (showing.length === 0) continue;
    if (v._windowClosed) v.close();
    else for (const item of showing) item.remove();
  }
}

const _finalizer = new FinalizationRegistry(({ fn, pointer }) => { try { fn.destroy(pointer); } catch (_) { /* exiting */ } });

// ---- helpers ---------------------------------------------------------------------------

const _f32 = (a) => (a == null ? null : a instanceof Float32Array ? a : Float32Array.from(a));
const _u32 = (a) => (a == null ? null : a instanceof Uint32Array ? a : Uint32Array.from(a));
/**
 * A colour's numbers (Python's `_colour`): text -- '#rgb', '#rrggbb' or a CSS colour name, any
 * case -- read by the library's own `cadaclysm_view_parse_colour` (three, in 0..1; a ViewError
 * with the library's message where it is no colour), anything else as given. `lib`: the view's
 * library; none, the one in use.
 */
function _colour(value, lib = null) {
  if (typeof value === 'string') {
    const library = lib ?? current();
    const out = new Float32Array(3);
    if (!library.fn.parse_colour(value, out)) throw new ViewError(library.lastError() || `colour ${JSON.stringify(value)}`);
    return Array.from(out);
  }
  return Array.from(value);
}
/** Exactly three numbers as floats (Python's `_f32(rgb, 3)`: C reads three); text through `_colour`. */
function _rgb(rgb, what = 'rgb', lib = null) {
  if (rgb == null) return null;
  const v = _colour(rgb, lib);
  if (v.length !== 3) throw new ViewError(`${what}: 3 numbers, not ${v.length}`);
  return Float32Array.from(v);
}
/** Text, or three or four numbers, as four floats (alpha 1 where there is none). */
function _rgba(c, what = 'rgba', lib = null) {
  if (c == null) return null;
  const v = _colour(c, lib);
  if (v.length !== 3 && v.length !== 4) throw new ViewError(`${what}: 3 or 4 numbers, not ${v.length}`);
  return Float32Array.from([v[0], v[1], v[2], v.length > 3 ? v[3] : 1]);
}
/** Exactly `n` numbers as doubles (a matrix: C reads sixteen). */
function _doubles(a, n, what) {
  if (a == null) return null;
  const v = Array.from(a);
  if (v.length !== n) throw new ViewError(`${what}: ${n} numbers, not ${v.length}`);
  return Float64Array.from(v);
}
/**
 * koffi hands an empty typed array to C as NULL, which the library reads as "none" (no
 * transforms: the rest pose; no segments: refused). Python hands it an empty array, so an empty
 * list goes as a one-element stand-in; the count passed stays 0.
 */
const _nonNull = (a) => (a.length ? a : new a.constructor(1));
/** A whole number of `unit`-float records: segments, curves. */
function _floatsOf(a, unit, what, noun) {
  const f = _f32(a);
  if (f.length % unit) throw new ViewError(`${what}: ${unit} numbers a ${noun}, not ${f.length}`);
  return f;
}
// Text for a C string: a NUL would end it early, so it is refused rather than cut.
function _textOf(text, what) {
  if (typeof text !== 'string') throw new ViewError(`${what}: text is a string, not ${typeof text}`);
  if (text.includes('\0')) throw new ViewError(`text ${JSON.stringify(text)}: a NUL character cannot be shown (the C string ends there)`);
  return text;
}

// `n` finite numbers, as an array koffi copies into a fixed array field. Only an array or a
// typed array: a string is array-like too, and "123" would otherwise be [1, 2, 3].
function _fixed(values, n, what) {
  if (!Array.isArray(values) && !(ArrayBuffer.isView(values) && !(values instanceof DataView))) {
    throw new ViewError(`${what}: ${n} finite numbers, not ${_kind(values)}`);
  }
  const a = Array.from(values, Number);
  if (a.length !== n || !a.every(Number.isFinite)) throw new ViewError(`${what}: ${n} finite numbers`);
  return a;
}
/** A `[tool, gcode]` (or `{ tool, gcode }`) as CadaclysmViewProgram, refused as Python's `_program` refuses. */
function _program(p) {
  const [tool, gcode] = Array.isArray(p) ? p : [p?.tool, p?.gcode];
  if (tool == null || ['number', 'shape', 'diameter'].some((k) => tool[k] == null)) throw new ViewError('showMachining: tool needs number, shape and diameter');
  if (!Number.isInteger(Number(tool.number))) throw new ViewError(`showMachining: tool number ${tool.number} is not a whole number`);
  if (Math.trunc(Number(tool.number)) < 0) throw new ViewError(`showMachining: tool number ${tool.number} is negative`);
  if (!Object.hasOwn(TOOL_SHAPES, tool.shape)) throw new ViewError(`showMachining: shape '${tool.shape}': one of ${Object.keys(TOOL_SHAPES).join(', ')}`);
  return {
    size: SIZE('CadaclysmViewProgram'), tool_number: Math.trunc(Number(tool.number)), tool_shape: TOOL_SHAPES[tool.shape],
    tool_diameter: Number(tool.diameter), tool_flute_length: Number(tool.flute_length ?? 0), tool_angle: Number(tool.angle ?? 0),
    tool_corner_radius: Number(tool.corner_radius ?? 0), gcode: String(gcode),
  };
}

/** A part's `{ positions, indices }` (or `[positions, indices]`) checked as Python's `_part_arrays`. */
function _part(part) {
  const [positions, indices] = Array.isArray(part) ? part : [part?.positions, part?.indices];
  const flat = (a) => Array.from(a ?? []).flatMap((e) => (typeof e === 'number' ? [e] : Array.from(e ?? [])));
  const p = _f32(flat(positions));
  const raw = flat(indices);
  if (raw.some((k) => !Number.isInteger(Number(k)))) throw new ViewError('showMachining: part indices must be whole numbers');
  if (raw.some((k) => k < 0)) throw new ViewError('showMachining: part indices must not be negative');
  if (p.length % 3) throw new ViewError(`showMachining: part positions: ${p.length} numbers is not a whole number of x y z triples`);
  if (raw.length % 3) throw new ViewError(`showMachining: part indices: ${raw.length} is not a whole number of triangles`);
  const vertices = p.length / 3;
  let top = -1;
  for (const k of raw) if (k > top) top = k;
  if (top >= vertices) throw new ViewError(`showMachining: part indices: ${top} is past the last of ${vertices} vertices`);
  return { p, i: Uint32Array.from(raw), vertices };
}

// A number showText copies into a float field: finite, or refused naming the field.
function _finite(value, what) {
  if (typeof value !== 'number' || !Number.isFinite(value)) throw new ViewError(`${what}: a finite number, not ${_kind(value)}`);
  return value;
}
// What a refused value was, for the message.
function _kind(value) {
  if (value === null) return 'null';
  if (typeof value === 'number' || typeof value === 'string') return JSON.stringify(value) ?? String(value);
  if (typeof value === 'object') return value.constructor?.name ?? 'object';
  return typeof value;
}
// A font id from loadFont (0 = the bundled font): a whole number the u32 field holds.
function _fontId(font) {
  if (!Number.isInteger(font) || font < 0 || font > 0xFFFFFFFF) throw new ViewError(`showText font: a font id from loadFont (a whole number, 0 or more), not ${_kind(font)}`);
  return font;
}
function _name(table, value, what) {
  if (!(value in table)) throw new ViewError(`${what} ${JSON.stringify(value)}: one of ${Object.keys(table).join(', ')}`);
  return table[value];
}

const _CRC = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; }
  return t;
})();
function _crc32(bytes) { let c = 0xFFFFFFFF; for (const b of bytes) c = _CRC[(c ^ b) & 0xFF] ^ (c >>> 8); return (c ^ 0xFFFFFFFF) >>> 0; }

/** RGBA8 rows from the top as a PNG: the signature, IHDR, one zlib IDAT, IEND. */
function _png(width, height, rgba) {
  const stride = width * 4;
  const raw = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y++) Buffer.from(rgba.buffer, rgba.byteOffset + y * stride, stride).copy(raw, y * (stride + 1) + 1);
  const chunk = (type, data) => {
    const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
    const head = Buffer.alloc(4); head.writeUInt32BE(data.length);
    const tail = Buffer.alloc(4); tail.writeUInt32BE(_crc32(body));
    return Buffer.concat([head, body, tail]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0); ihdr.writeUInt32BE(height, 4); ihdr[8] = 8; ihdr[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}

// ---- View and Item ---------------------------------------------------------------------

/** One thing a view shows. It holds the object it shows, so a solid or scene dropped by the caller stays drawable. */
class Item {
  constructor(v, id, shown) { this.view = v; this.id = id; this.shown = shown; }
  _ok(ok, what) { if (!ok) throw this.view._lib.failure(what); }
  remove() {
    this._ok(this.view._lib.fn.remove(this.view._live('cadaclysm_view_remove'), this.id), 'remove');
    this.view._items.delete(this.id);
    this.shown = null;
  }
  /**
   * Poses a shown scene: one world transform per node (sixteen numbers each, column-major,
   * `Pose.rawTransform`'s layout -- every node of the scene, in index order), drawn in place
   * of each node's rest transform. null restores the rest pose.
   */
  nodeTransforms(transforms) {
    if (transforms == null) { this._ok(this.view._lib.fn.set_node_transforms(this.view._live('cadaclysm_view_set_node_transforms'), this.id, null, 0), 'nodeTransforms'); return; }
    const list = Array.from(transforms);
    const flat = new Float64Array(16 * list.length);
    list.forEach((m, k) => {
      if (m.length !== 16) throw new ViewError(`transform ${k}: 16 numbers, not ${m.length}`);
      flat.set(m, 16 * k);
    });
    this._ok(this.view._lib.fn.set_node_transforms(this.view._live('cadaclysm_view_set_node_transforms'), this.id, _nonNull(flat), list.length), 'nodeTransforms');
  }
  colour(rgb) {
    const c = _rgb(rgb, 'colour', this.view._lib);
    if (!c) throw new ViewError('colour: 3 numbers, not none');
    this._ok(this.view._lib.fn.set_colour(this.view._live('cadaclysm_view_set_colour'), this.id, c), 'colour');
  }
  /** Sixteen numbers, column-major, or null to put it back. */
  placement(matrix) {
    this._ok(this.view._lib.fn.set_placement(this.view._live('cadaclysm_view_set_placement'), this.id, _doubles(matrix, 16, 'placement')), 'placement');
  }
  /**
   * `faces` (pick numbers) coloured by `rgba`: one colour a face -- text, or 3 or 4 numbers (the
   * alpha is not drawn; text and 3 numbers mean alpha 1) -- or four numbers a face, flat; `faces`
   * null clears every one.
   */
  faceColours(faces, rgba) {
    const f = _u32(faces);
    if (f == null) { this._ok(this.view._lib.fn.set_face_colours(this.view._live('cadaclysm_view_set_face_colours'), this.id, null, null, 0), 'faceColours'); return; }
    const lib = this.view._lib;
    const c = _f32(Array.from(rgba ?? []).flatMap((e) => (typeof e === 'number' ? [e] : Array.from(_rgba(e, 'faceColours', lib)))));
    if (c.length !== 4 * f.length) throw new ViewError(`faceColours: ${4 * f.length} numbers (rgba, 4 a face), not ${c.length}`);
    this._ok(this.view._lib.fn.set_face_colours(this.view._live('cadaclysm_view_set_face_colours'), this.id, _nonNull(f), _nonNull(c), f.length), 'faceColours');
  }
  /** The text item's string replaced, nothing else changed (cadaclysm_view_set_text). */
  setText(text) {
    const t = _textOf(text, 'setText');
    this._ok(this.view._lib.fn.set_text(this.view._live('cadaclysm_view_set_text'), this.id, t), 'setText');
  }
  frame() { this._ok(this.view._lib.fn.frame(this.view._live('cadaclysm_view_frame'), this.id), 'frame'); }
  xray(on) { this._ok(this.view._lib.fn.set_xray(this.view._live('cadaclysm_view_set_xray'), this.id, Boolean(on)), 'xray'); }
  /** How its lines and points draw where a surface hides them: 'off' (an item shows with it until set), 'solid' or 'dashed'. */
  occluded(mode) {
    if (typeof mode !== 'string' || !Object.hasOwn(OCCLUDED, mode)) throw new TypeError(`occluded: '${mode}' is not 'off', 'solid' or 'dashed'`);
    this._ok(this.view._lib.fn.set_occluded(this.view._live('cadaclysm_view_set_occluded'), this.id, OCCLUDED[mode]), 'occluded');
  }
  /**
   * The item's finish: 'gloss' (an item shows with this until it is set) -- under the showroom
   * lighting a clear coat mirroring the room, silver at a grazing angle -- 'satin' (a weaker,
   * blurred coat) or 'matte' (no mirror, a faint sheen: rubber, cloth). Uploads the scene again,
   * as a show does: set it as each item is shown rather than over a finished scene item by item.
   */
  finish(finish) {
    if (typeof finish !== 'string' || !Object.hasOwn(FINISH, finish)) throw new TypeError(`finish: '${finish}' is not 'gloss', 'satin' or 'matte'`);
    this._ok(this.view._lib.fn.set_finish(this.view._live('cadaclysm_view_set_finish'), this.id, FINISH[finish]), 'finish');
  }
  nodeVisible(node, on) { this._ok(this.view._lib.fn.set_node_visible(this.view._live('cadaclysm_view_set_node_visible'), this.id, node, Boolean(on)), 'nodeVisible'); }
  nodeColour(node, rgba) { this._ok(this.view._lib.fn.set_node_color(this.view._live('cadaclysm_view_set_node_color'), this.id, node, _rgba(rgba, 'nodeColour', this.view._lib)), 'nodeColour'); }
  /** Tint `node` toward `rgba`'s colour by its alpha; null clears. */
  nodeHighlight(node, rgba) { this._ok(this.view._lib.fn.set_node_highlight(this.view._live('cadaclysm_view_set_node_highlight'), this.id, node, _rgba(rgba, 'nodeHighlight', this.view._lib)), 'nodeHighlight'); }
  frameNode(node) { this._ok(this.view._lib.fn.frame_node(this.view._live('cadaclysm_view_frame_node'), this.id, node), 'frameNode'); }
}

/** A CAM job shown in a View (`View.showMachining`): the stock is this item; the view's timeline plays it. */
class Machining extends Item {
  seekMove(move) {
    if (!Number.isInteger(move) || move < 0) throw new ViewError(`seekMove: a whole number of moves, 0 or more, not ${_kind(move)}`);
    this._ok(this.view._lib.fn.machining_seek(this.view._live('cadaclysm_view_machining_seek'), this.id, move), 'seekMove');
  }
  colourBy(mode) {
    if (!Object.hasOwn(COLOUR_BY, mode)) throw new ViewError(`mode '${mode}': one of ${Object.keys(COLOUR_BY).join(', ')}`);
    this._ok(this.view._lib.fn.machining_colour_by(this.view._live('cadaclysm_view_machining_colour_by'), this.id, COLOUR_BY[mode]), 'colourBy');
  }
  overlays(path = true, tool = true) {
    this._ok(this.view._lib.fn.machining_overlays(this.view._live('cadaclysm_view_machining_overlays'), this.id, Boolean(path), Boolean(tool)), 'overlays');
  }
  /** `{ moves, move, nx, ny, cell, min: [x, y], cycleTime }`. */
  info() {
    const out = { size: SIZE('CadaclysmViewMachiningInfo') };
    this._ok(this.view._lib.fn.machining_info(this.view._live('cadaclysm_view_machining_info'), this.id, out), 'info');
    return { moves: out.moves, move: out.move, nx: out.nx, ny: out.ny, cell: out.cell, min: [out.min[0], out.min[1]], cycleTime: out.cycle_time };
  }
  /** The stock's heights now, `nx * ny` floats, row y then x (`z[j * nx + i]`), mm; waits for the GPU. */
  heights() {
    const { nx, ny } = this.info();
    const z = new Float32Array(nx * ny);
    this._ok(this.view._lib.fn.machining_heights(this.view._live('cadaclysm_view_machining_heights'), this.id, _nonNull(z), z.length), 'heights');
    return z;
  }
}

// Python flushes stdout before a still is printed; Node has no flush, and on POSIX a write to a
// full pipe is queued and sent later, so a still the library writes straight to the same file
// descriptor would overtake it. Blocking writes -- what Node already does for a pipe on Windows,
// and for files and terminals everywhere -- send each write before it returns. Set when a library
// that prints (the terminal, or one of your own) becomes the choice, never for the wgpu window's
// or an offscreen program. The residue: Node has no synchronous drain, so output already queued
// when that happens (more than a pipe-full written before the first terminal draw) can still
// arrive after the first still.
function _blockingStdio() {
  for (const stream of [process.stdout, process.stderr]) {
    try { stream._handle?.setBlocking?.(true); } catch { /* not a stream libuv owns: nothing queues */ }
  }
}

const _HOW = Symbol('how');
/** A whole number of pixels a uint32_t holds. */
const _pixels = (n) => Number.isInteger(n) && n >= 0 && n <= 0xFFFFFFFF;

class View {
  /** A window of the library's own: `title`, `width`, `height` (0: 1280 x 800), `surfaces` ('exact'), `up` ('z'), `backend` (0). */
  constructor(options = {}, how = null) {
    const lib = current();
    const h = how && how[_HOW] ? how : { window: null, offscreen: false, width: options.width ?? 0, height: options.height ?? 0 };
    if (!_pixels(h.width) || !_pixels(h.height)) {
      throw new ViewError(`width=${h.width}, height=${h.height}: a size is pixels, 0 or more (0 = the library decides)`);
    }
    this._lib = lib;
    this._items = new Map();
    this._windowClosed = false;
    this._drawn = false;
    this._yUp = String(options.up ?? 'z').toLowerCase() === 'y';
    const raw = {
      size: SIZE('CadaclysmViewOptions'), surfaces: _name(SURFACES, options.surfaces ?? 'exact', 'surfaces'),
      backend: options.backend ?? 0, y_up: this._yUp ? 1 : 0, title: options.title ?? null,
      width: h.width, height: h.height, offscreen: h.offscreen ? 1 : 0,
    };
    const pointer = lib.fn.create(h.window, raw);
    if (!pointer) {
      let why = lib.lastError() || 'the view library failed';
      if (why.includes('no display')) why += ' -- draw without a display with View.offscreen(width, height), or the terminal (useTerminal())';
      throw new ViewError(why);
    }
    this._pointer = pointer;
    this._own = !h.window && !h.offscreen;
    _finalizer.register(this, { fn: lib.fn, pointer }, this);
    this._ref = new WeakRef(this);
    _views.add(this._ref);
    if (this._own && lib.kind === 'wgpu') _watch(this);
  }
  /** A view drawing into a host's window: `{ kind: 'win32'|'xlib'|'xcb'|'wayland'|'appkit', window, windowId, display, width, height }`. */
  static inWindow(window, options = {}) {
    const raw = {
      size: SIZE('CadaclysmViewWindow'), kind: _name(WINDOW, window.kind, 'window kind'),
      window: window.window ?? null, window_id: window.windowId ?? 0, display: window.display ?? null,
      width: window.width, height: window.height,
    };
    return new View(options, { [_HOW]: true, window: raw, offscreen: false, width: window.width, height: window.height });
  }
  /** A view with no window and no display, `width` x `height` pixels. */
  static offscreen(width, height, options = {}) {
    return new View(options, { [_HOW]: true, window: null, offscreen: true, width, height });
  }
  /** The live pointer, refusing a closed view or a closed window. */
  _live(call = 'view') {
    if (this._pointer === null) throw new ViewError(`${call}: the view is closed`);
    if (this._windowClosed) throw new ViewError(`${call}: the window is closed`);
    return this._pointer;
  }
  _item(id, shown, what) {
    if (!id) throw this._lib.failure(what);
    const item = new Item(this, id, shown);
    this._items.set(id, item);
    return item;
  }
  _ok(ok, what) { if (!ok) throw this._lib.failure(what); }
  /** A call with no result: a refusal is the library's last error (Python's `_void`). */
  _void(name, ...args) {
    this._lib.fn[name](this._live(`cadaclysm_view_${name}`), ...args);
    const why = this._lib.lastError();
    if (why) throw new ViewError(why);
  }
  get closed() { return this._pointer === null || this._windowClosed; }
  /** Show `obj`: a blacksmith Solid, a Scene or a Node by handle. */
  show(obj, rgb = null, tolerance = 0.05) {
    const name = obj?.constructor?.name;
    if (name === 'Solid' && '_handle' in obj) return this.showSolid(obj, tolerance, rgb);
    if (name === 'Scene' && '_handle' in obj) return this.showScene(obj);
    if (name === 'Node' && obj.scene && typeof obj.index === 'number') return this.showNode(obj);
    throw new ViewError(`show: a Solid, Scene or Node, not ${name ?? typeof obj}`);
  }
  /**
   * A kernel solid, read in place. `options` (view ABI 1.21): `material` 'default', 'plastic',
   * 'metal', 'matte', 'paint', 'brushed' or 'glass'; `opacity` 0..1 (1 opaque); `faces` the
   * solid's face numbers to show alone, with no edges -- a trim's ghost (null: every face).
   * Without any of them, the 1.4 call. The item's faces are numbered as the solid numbers them.
   */
  showSolid(solid, tolerance = 0.05, rgb = null, { material = null, opacity = null, faces = null } = {}) {
    if (material != null && (typeof material !== 'string' || !Object.hasOwn(MATERIAL, material))) {
      throw new TypeError(`material: '${material}' is not 'default', 'plastic', 'metal', 'matte', 'paint', 'brushed' or 'glass'`);
    }
    const colour = _rgb(rgb, 'showSolid', this._lib);
    if (material == null && opacity == null && faces == null) {
      return this._item(this._lib.fn.show_solid(this._live('cadaclysm_view_show_solid'), solid._handle, tolerance, colour), solid, 'showSolid');
    }
    const only = faces == null ? null : _u32(faces);
    return this._item(this._lib.fn.show_solid_faces(this._live('cadaclysm_view_show_solid_faces'), solid._handle, tolerance, colour,
      MATERIAL[material ?? 'default'], opacity ?? 1, only == null ? null : _nonNull(only), only == null ? 0 : only.length), solid, 'showSolid');
  }
  showScene(scene, shown = scene) {
    return this._item(this._lib.fn.show(this._live('cadaclysm_view_show'), scene._handle), shown, 'showScene');
  }
  /** The node's scene by handle, with every node outside this one hidden. */
  showNode(node) {
    const item = this.showScene(node.scene, node);
    const chain = [];
    for (let at = node; at; at = at.parent) chain.unshift(at);
    let level = node.scene.roots();
    for (const on of chain) {
      for (const other of level) if (other.index !== on.index) item.nodeVisible(other.index, false);
      level = on.children();
    }
    return item;
  }
  /** `{ positions, indices, normals?, edges?, rgb? }`: three floats a vertex, three indices a triangle, six floats an edge. */
  showMesh(mesh) {
    if (mesh == null || mesh.positions == null || mesh.indices == null) throw new ViewError('showMesh: positions and indices are required');
    const positions = _f32(mesh.positions), normals = _f32(mesh.normals), indices = _u32(mesh.indices), edges = _f32(mesh.edges);
    if (normals && normals.length !== positions.length) throw new ViewError(`showMesh: ${positions.length / 3} positions but ${normals.length / 3} normals`);
    if (edges && edges.length % 6) throw new ViewError(`showMesh: edges are two points a segment (6 numbers), not ${edges.length}`);
    const raw = {
      size: SIZE('CadaclysmViewMesh'), positions, vertex_count: Math.floor(positions.length / 3), normals,
      indices, index_count: indices.length, edges, edge_count: edges ? edges.length / 6 : 0, rgb: _rgb(mesh.rgb, 'showMesh rgb', this._lib),
    };
    return this._item(this._lib.fn.show_mesh(this._live('cadaclysm_view_show_mesh'), raw), null, 'showMesh');
  }
  /** Six floats a segment. */
  showLines(segments, rgb = null) {
    const s = _floatsOf(segments, 6, 'showLines', 'segment');
    return this._item(this._lib.fn.show_lines(this._live('cadaclysm_view_show_lines'), _nonNull(s), s.length / 6, _rgb(rgb, 'showLines rgb', this._lib)), null, 'showLines');
  }
  /**
   * Points, three numbers each (a flat run, or `[x, y, z]` a point): a disc `sizePx` device
   * pixels across (1 to 64) at each, in `colour` (null: the edge colour; any colour `showLines`
   * takes), as one item. A point does not pick; the item is framed by its points' box. The
   * library refuses a number that is not finite and a size outside 1..64.
   */
  showPoints(positions, colour = null, sizePx = 8) {
    const items = ArrayBuffer.isView(positions) ? positions : Array.from(positions ?? []);
    const flat = !ArrayBuffer.isView(items) && items.length && typeof items[0] !== 'number'
      ? items.flatMap((q) => {
        const xyz = Array.from(q ?? []);
        if (xyz.length !== 3) throw new ViewError(`showPoints: three numbers a point, not ${xyz.length}`);
        return xyz;
      })
      : items;
    const p = _f32(flat);
    if (p.length % 3) throw new ViewError(`showPoints: three numbers a point, not ${p.length}`);
    const rgb = _rgb(colour, 'showPoints rgb', this._lib);
    return this._item(this._lib.fn.show_points(this._live('cadaclysm_view_show_points'), _nonNull(p), p.length / 3, rgb, Number(sizePx ?? 8)), null, 'showPoints');
  }
  /**
   * A CAM job on a stock, paused at its start: `programs` in run order as `[tool, gcode]` --
   * `tool` `{ number, shape ('flat'|'ball'|'drill'|'vbit'|'bullnose'), diameter, flute_length?, angle?, corner_radius? }`;
   * `stock` `[[minX, minY, minZ], [maxX, maxY, maxZ]]`; `part` `{ positions, indices }` for colouring by
   * deviation; `cell`, `tolerance`, `skin` and `rapidRate` as the library's (absent: its defaults). Play it with `play()`.
   */
  showMachining(programs, stock, part = null, { cell, tolerance, skin, rapidRate } = {}) {
    const made = Array.from(programs ?? []).map(_program);
    const [lo, hi] = stock ?? [];
    if (lo == null || hi == null) throw new ViewError('showMachining: stock is [[minX, minY, minZ], [maxX, maxY, maxZ]]');
    const raw = {
      size: SIZE('CadaclysmViewMachining'), program_count: made.length, programs: made,
      stock_min: Array.from(_doubles(lo, 3, 'showMachining stock min')), stock_max: Array.from(_doubles(hi, 3, 'showMachining stock max')),
      part_positions: null, part_indices: null, part_vertex_count: 0, part_index_count: 0,
      cell: _finite(cell ?? 0, 'showMachining cell'), tolerance: _finite(tolerance ?? 0, 'showMachining tolerance'),
      skin: _finite(skin ?? 0, 'showMachining skin'), rapid_rate: _finite(rapidRate ?? 0, 'showMachining rapidRate'),
      skin_set: skin == null ? 0 : 1,
    };
    if (part != null) {
      const { p, i, vertices } = _part(part);
      Object.assign(raw, { part_positions: _nonNull(p), part_indices: _nonNull(i), part_vertex_count: vertices, part_index_count: i.length });
    }
    const id = this._lib.fn.show_machining(this._live('cadaclysm_view_show_machining'), raw);
    if (!id) throw this._lib.failure('showMachining');
    const item = new Machining(this, id, null);
    this._items.set(id, item);
    return item;
  }
  /** Sixteen floats a rational cubic: four control points as x, y, z, w. */
  showCurves(beziers, rgb = null) {
    const b = _floatsOf(beziers, 16, 'showCurves', 'curve');
    return this._item(this._lib.fn.show_curves(this._live('cadaclysm_view_show_curves'), _nonNull(b), b.length / 16, _rgb(rgb, 'showCurves rgb', this._lib)), null, 'showCurves');
  }
  /** `corners`: twelve floats, bottom-left, bottom-right, top-right, top-left; `rgba` rows from the top, `width * height * 4` bytes. */
  showImage(corners, rgba, width, height, opacity = 1) {
    const c = Array.from(corners);
    if (c.length < 12) throw new ViewError(`showImage: corners are 12 numbers, not ${c.length}`);
    if (!Number.isInteger(width) || !Number.isInteger(height) || width < 0 || height < 0 || width > 0xFFFFFFFF || height > 0xFFFFFFFF) {
      throw new ViewError(`showImage: a size of ${width} x ${height} pixels`);
    }
    const pixels = rgba instanceof Uint8Array ? rgba : Uint8Array.from(rgba);
    const need = BigInt(width) * BigInt(height) * 4n;
    if (need !== BigInt(pixels.length)) throw new ViewError(`showImage: ${width} x ${height} pixels need ${need} bytes (w * h * 4), not ${pixels.length}`);
    const raw = { size: SIZE('CadaclysmViewImage'), corners: c.slice(0, 12), rgba: pixels, width, height, opacity, flip_x: 0, flip_y: 0 };
    return this._item(this._lib.fn.show_image(this._live('cadaclysm_view_show_image'), raw), null, 'showImage');
  }
  // -- the camera
  orbit(dx, dy) { this._void('orbit', dx, dy); }
  pan(dx, dy) { this._void('pan', dx, dy); }
  zoom(steps) { this._void('zoom', steps); }
  look(dx, dy) { this._void('look', dx, dy); }
  dolly(ratio) { this._void('dolly', ratio); }
  standard(name) { this._ok(this._lib.fn.standard(this._live('cadaclysm_view_standard'), _name(STANDARD, name, 'standard view')), 'standard'); }
  /** Fit the camera to everything shown. */
  frame() { this._ok(this._lib.fn.frame(this._live('cadaclysm_view_frame'), 0), 'frame'); }
  orthographic(on) { this._void('set_orthographic', Boolean(on)); }
  /**
   * Whether a double click frames what it hit (off by default: it is a pick answered with
   * `clicks` 2 and the camera stays). Applies where the view takes the pick itself (its own
   * window, `pump`, `run`); a host reading picks frames if it chooses.
   */
  setDoubleClickFrames(on) { this._void('set_double_click_frames', Boolean(on)); }
  /**
   * Moves the orbit point to `point` ([x, y, z], as a pick's `point`): the eye keeps its
   * direction and distance from it, so the camera moves sideways and does not turn. Leaves fly
   * mode. Throws for other than three numbers before the call, and the library's reason for a
   * point that is not finite, or while viewports are set.
   */
  focus(point) {
    const v = point == null || typeof point === 'string' ? [] : Array.from(point, Number);
    if (v.length !== 3) throw new ViewError(`focus: 3 numbers, not ${point == null || typeof point === 'string' ? _kind(point) : v.length}`);
    this._ok(this._lib.fn.focus(this._live('cadaclysm_view_focus'), Float32Array.from(v)), 'focus');
  }
  /**
   * How a left drag moves the camera: 'orbit' (about the target) or 'fly' (the view turns about
   * the eye). A fly key (W, A, S, D, E, Q) sent through `input` enters fly mode and it stays after
   * the key is let go; Tab toggles it; `frame`, `standard` and `focus` leave it.
   */
  get navigation() { return this._lib.fn.navigation(this._live('cadaclysm_view_navigation')) === NAVIGATION_FLY ? 'fly' : 'orbit'; }
  /** `[{ rect: [x, y, w, h], view: 16, projection: 16, eye: 3, grid: 'none'|'top'|'front'|'right' }]`, matrices column-major. */
  viewports(list) {
    const exact = (a, n, what) => { const v = Array.from(a ?? []); if (v.length !== n) throw new ViewError(`viewport ${what}: ${n} numbers, not ${v.length}`); return v; };
    const raw = list.map((v) => ({ size: SIZE('CadaclysmViewViewport'), rect: exact(v.rect, 4, 'rect'), view: exact(v.view, 16, 'view'), projection: exact(v.projection, 16, 'projection'), eye: exact(v.eye, 3, 'eye'), grid: _name(GRID, v.grid ?? 'none', 'grid'), layer_mask: 0xFFFFFFFF }));
    this._ok(this._lib.fn.set_viewports(this._live('cadaclysm_view_set_viewports'), raw, raw.length), 'viewports');
  }
  layer(name, on) { this._ok(this._lib.fn.set_layer(this._live('cadaclysm_view_set_layer'), _name(LAYER, name, 'layer'), Boolean(on)), 'layer'); }
  /** The clear colour: text ('#rgb', '#rrggbb', a CSS name) or three numbers in 0..1. */
  background(rgb) { this._void('set_background', _rgb(rgb ?? [], 'background', this._lib)); }
  get surfaces() { return this._lib.fn.surfaces(this._live('cadaclysm_view_surfaces')) === 1 ? 'triangles' : 'exact'; }
  set surfaces(name) { this._ok(this._lib.fn.set_surfaces(this._live('cadaclysm_view_set_surfaces'), _name(SURFACES, name, 'surfaces')), 'surfaces'); }
  /** How every 'dashed' item's hidden lines and points look, view-wide: { dash, gap } in points (6, 4), dim the coverage kept (0.5), colour [r, g, b] or null. Set null for the default; set keys are all optional. */
  get occludedStyle() {
    const out = { size: SIZE('CadaclysmViewOccludedStyle'), dash: 0, gap: 0, dim: 0, has_colour: 0, colour: [0, 0, 0] };
    this._ok(this._lib.fn.occluded_style(this._live('cadaclysm_view_occluded_style'), out), 'occludedStyle');
    return { dash: out.dash, gap: out.gap, dim: out.dim, colour: out.has_colour ? Array.from(out.colour) : null };
  }
  set occludedStyle(style) {
    if (style == null) { this._ok(this._lib.fn.set_occluded_style(this._live('cadaclysm_view_set_occluded_style'), null), 'occludedStyle'); return; }
    const colour = style.colour == null ? null : _rgb(style.colour, 'occludedStyle colour', this._lib);
    const raw = { size: SIZE('CadaclysmViewOccludedStyle'), dash: style.dash ?? 6, gap: style.gap ?? 4, dim: style.dim ?? 0.5, has_colour: colour ? 1 : 0, colour: colour ? Array.from(colour) : [0, 0, 0] };
    this._ok(this._lib.fn.set_occluded_style(this._live('cadaclysm_view_set_occluded_style'), raw), 'occludedStyle');
  }
  /** How plain parts are lit, as Python's View.lighting: 'headlight' (the default) or 'studio' (a key light fixed above the scene, an ambient and a camera fill). */
  get lighting() { return this._lib.fn.lighting(this._live('cadaclysm_view_lighting')) === 1 ? 'studio' : 'headlight'; }
  set lighting(name) { this._ok(this._lib.fn.set_lighting(this._live('cadaclysm_view_set_lighting'), _name(LIGHTING, name, 'lighting')), 'lighting'); }
  // -- the timeline --
  /** Play at `speed` times real time; it stops at its end unless `loop()` is on; at the end it starts again from 0. */
  play(speed = 1) { this._ok(this._lib.fn.timeline_play(this._live('cadaclysm_view_timeline_play'), Number(speed)), 'play'); }
  pause() { this._ok(this._lib.fn.timeline_pause(this._live('cadaclysm_view_timeline_pause')), 'pause'); }
  /** Set the clock, clamped to [0, duration]. */
  seek(seconds) { this._ok(this._lib.fn.timeline_seek(this._live('cadaclysm_view_timeline_seek'), Number(seconds)), 'seek'); }
  loop(on = true) { this._ok(this._lib.fn.timeline_set_loop(this._live('cadaclysm_view_timeline_set_loop'), Boolean(on)), 'loop'); }
  get time() { return this._lib.fn.timeline_time(this._live('cadaclysm_view_timeline_time')); }
  get duration() { return this._lib.fn.timeline_duration(this._live('cadaclysm_view_timeline_duration')); }
  get playing() { return Boolean(this._lib.fn.timeline_playing(this._live('cadaclysm_view_timeline_playing'))); }
  /** One line per track at the clock's time, e.g. "move 370 of 638 \u00b7 T1 flat 6 mm \u00b7 X12.3 Y-4.0 Z7.0". */
  status() {
    const p = this._live('cadaclysm_view_timeline_status');
    let n = Number(this._lib.fn.timeline_status(p, null, 0));
    while (n) {
      const buf = Buffer.alloc(n + 1);
      const got = Number(this._lib.fn.timeline_status(p, buf, n + 1));
      if (got < n + 1) return got ? buf.toString('utf8', 0, got).split('\n') : [];   // 0: the line emptied between the calls
      n = got;   // the line grew between the two calls: ask again with room for it
    }
    return [];
  }
  get needsDraw() { return Boolean(this._lib.fn.needs_draw(this._live('cadaclysm_view_needs_draw'))); }
  // -- the rest
  /** What is under pixel (x, y) of `viewport`: `{ item, node, face, clicks, point }`, or null for nothing. */
  // A view never drawn is drawn first: the library answers a pick from the frame it has drawn.
  // A failure other than "no answer yet" throws at once with the library's own message.
  pick(x, y, viewport = 0) {
    if (!this._drawn) this.draw();
    const p = this._live('cadaclysm_view_request_pick_in');
    this._void('request_pick_in', viewport, x, y);
    const out = _rawPick();
    let waiting = '';
    for (let i = 0; i < 200; i++) {
      this.draw();
      if (this._lib.fn.pick_result(p, out)) return out.item ? _pick(out) : null;
      waiting = this._lib.lastError();
      if (waiting && !waiting.endsWith('no pick result')) throw new ViewError(waiting);
      _sleep(10);
    }
    throw new ViewError(`pick: the answer never landed (${waiting || 'no error reported'})`);
  }
  /**
   * The newest pick answer that has landed, without asking or waiting (Python's `last_pick`):
   * a click or tap in the view's own window (`pump` lands them as it draws), a double click's
   * (`clicks` 2), or one an `input` asked for, landed by the draws after it. `undefined` while
   * none has; `null` for a click on nothing; else `{ item, node, face, clicks, point }`. Each
   * answer is read once, and a newer one replaces one not read yet. A failure other than "no
   * answer yet" throws the library's own message.
   */
  lastPick() {
    const out = _rawPick();
    if (this._lib.fn.pick_result(this._live('cadaclysm_view_pick_result'), out)) return out.item ? _pick(out) : null;
    const waiting = this._lib.lastError();
    if (waiting && !waiting.endsWith('no pick result')) throw new ViewError(waiting);
    return undefined;
  }
  /**
   * What a snap may land on (cadaclysm_view.py's `set_snap`): 'all' (the default), one kind's name,
   * an array of names, or null to switch snapping off -- 'vertex', 'midpoint', 'centre' (a circular
   * edge's), 'quadrant', 'edge', 'face', 'grid' and 'plane'. `aperturePx`: how far from the cursor
   * a point kind may lie (0: the library's default, 10 points); `marker`: whether the view draws its
   * marker at the snap. A view starts with snapping off; once on, a mouse over a view in its own
   * window snaps, and so does a click (`lastSnap` reads them); `snap` asks one at any pixel.
   */
  setSnap(kinds = 'all', options = {}) {
    const o = options ?? {};
    let bits = 0;
    if (kinds === 'all') bits = 0xFF;
    else if (kinds !== null) {
      for (const name of typeof kinds === 'string' ? [kinds] : Array.isArray(kinds) ? kinds : [kinds]) {
        if (!Object.hasOwn(SNAP_KINDS, name)) throw new ViewError(`snap kind ${_kind(name)}: one of ${Object.keys(SNAP_KINDS).join(', ')}`);
        bits |= SNAP_KINDS[name];
      }
    }
    const raw = { size: SIZE('CadaclysmViewSnapSettings'), kinds: bits, aperture_px: _finite(o.aperturePx ?? 0, 'setSnap aperturePx'), marker: (o.marker ?? true) ? 1 : 0 };
    this._ok(this._lib.fn.set_snap(this._live('cadaclysm_view_set_snap'), raw), 'setSnap');
  }
  /**
   * The snap under pixel (x, y) of `viewport`: `{ kind, point, item, node, face, edge, tangent, axis,
   * radius, distancePx, clicks }`, or null where nothing in the kinds setSnap chose lies there --
   * always null while snapping is off. Draws until the answer lands, as `pick` does (a never-drawn
   * view first). A failure other than "no answer yet" throws at once with the library's own message.
   */
  snap(x, y, viewport = 0) {
    if (!this._drawn) this.draw();
    const p = this._live('cadaclysm_view_request_snap_in');
    this._void('request_snap_in', viewport, x, y);
    const out = _rawSnap();
    let waiting = '';
    for (let i = 0; i < 200; i++) {
      this.draw();
      if (this._lib.fn.snap_result(p, out)) return out.kind ? _snap(out) : null;
      waiting = this._lib.lastError();
      if (waiting && !waiting.endsWith('no snap result')) throw new ViewError(waiting);
      _sleep(10);
    }
    throw new ViewError(`snap: the answer never landed (${waiting || 'no error reported'})`);
  }
  /**
   * The newest snap answer that has landed, without asking or waiting (cadaclysm_view.py's
   * `last_snap`): a hover or click in the view's own window (`pump` lands them as it draws), or one
   * `snap` asked. `undefined` while none has; `null` for a snap that found nothing; else a snap.
   * Each answer is read once; a hover's never replaces a click's not read yet.
   */
  lastSnap() {
    const out = _rawSnap();
    if (this._lib.fn.snap_result(this._live('cadaclysm_view_snap_result'), out)) return out.kind ? _snap(out) : null;
    const waiting = this._lib.lastError();
    if (waiting && !waiting.endsWith('no snap result')) throw new ViewError(waiting);
    return undefined;
  }
  /** Hides the snap marker and drops any snap asked or answered and not yet read. */
  clearSnap() { this._void('clear_snap'); }
  /**
   * The plane 'grid' and 'plane' snaps land on, in place of the ground grid: through `origin`, its
   * grid lines along `xAxis` and across it, `step` apart (0: the ground grid's spacing), facing
   * `normal`. `xAxis` and `normal` need not be unit length but must not be parallel. null as
   * `origin` puts the ground grid back.
   */
  setWorkPlane(origin, xAxis = [1, 0, 0], normal = [0, 0, 1], step = 0) {
    if (origin == null) { this._ok(this._lib.fn.clear_work_plane(this._live('cadaclysm_view_clear_work_plane')), 'setWorkPlane'); return; }
    const o = Float64Array.from(_fixed(origin, 3, 'setWorkPlane origin'));
    const x = Float64Array.from(_fixed(xAxis, 3, 'setWorkPlane xAxis'));
    const n = Float64Array.from(_fixed(normal, 3, 'setWorkPlane normal'));
    this._ok(this._lib.fn.set_work_plane(this._live('cadaclysm_view_set_work_plane'), o, x, n, _finite(step, 'setWorkPlane step')), 'setWorkPlane');
  }
  draw() { this._ok(this._lib.fn.draw(this._live('cadaclysm_view_draw')), 'draw'); this._drawn = true; }
  /** Blocks until the window is closed; the camera it ended on and the last pick. */
  run() {
    const cam = { size: SIZE('CadaclysmViewCamera'), eye: [0, 0, 0], target: [0, 0, 0], up: [0, 0, 0], orthographic: 0 };
    const pick = _rawPick();
    this._ok(this._lib.fn.run(this._live('cadaclysm_view_run'), cam, pick), 'run');
    this._markClosed();
    return _camera(cam, pick, this._yUp);
  }
  /**
   * Text shown as one item: a label (pixels, anchored to `at`) or world text (`mode: 'world'`,
   * lying in the plane of `right` and `up` through `at`). See cadaclysm_view_show_text.
   */
  showText(text, at, options = {}) {
    const o = options ?? {};
    const raw = {
      size: SIZE('CadaclysmViewText'),
      text: _textOf(text, 'showText'),
      mode: _name(TEXT_MODES, o.mode ?? 'label', 'mode'),
      at: _fixed(at, 3, 'showText at'),
      right: o.right == null ? [0, 0, 0] : _fixed(o.right, 3, 'showText right'),
      up: o.up == null ? [0, 0, 0] : _fixed(o.up, 3, 'showText up'),
      height: _finite(o.size ?? 12, 'showText size'),
      rgb: Array.from(_rgb(o.colour ?? 'white', 'showText colour', this._lib)),
      align: _name(ALIGN, o.align ?? 'bottom-left', 'align'),
      offset: o.offset == null ? [0, 0] : _fixed(o.offset, 2, 'showText offset'),
      box_rgba: o.box == null ? [0, 0, 0, 0] : Array.from(_rgba(o.box, 'showText box', this._lib)),
      box_padding: _finite(o.padding ?? 4, 'showText padding'),
      on_top: o.onTop ? 1 : 0,
      font: _fontId(o.font ?? 0),
    };
    return this._item(this._lib.fn.show_text(this._live('cadaclysm_view_show_text'), raw), null, 'showText');
  }
  /** One frame read back: `{ width, height, rgba }`, RGBA8, rows from the top. */
  image() {
    const p = this._live('cadaclysm_view_image');
    const w = [0], h = [0];
    if (!this._lib.fn.size(p, w, h)) throw this._lib.failure('image');   // the size the next frame is drawn at
    const need = BigInt(w[0]) * BigInt(h[0]) * 4n;
    if (need > BigInt(bufferConstants.MAX_LENGTH)) throw new ViewError(`image: ${w[0]} x ${h[0]} pixels (${need} bytes) is too large to read back`);
    const rgba = new Uint8Array(Number(need));
    if (!this._lib.fn.image(p, rgba, rgba.length)) throw this._lib.failure('image');
    return { width: w[0], height: h[0], rgba };
  }
  save(filePath) { const img = this.image(); fs.writeFileSync(filePath, _png(img.width, img.height, img.rgba)); }
  /**
   * `{ type: 'pointer_down'|'pointer_move'|'pointer_up'|'pointer_cancel'|'wheel'|'key', x, y, button,
   * shift, pointer, pointerId, wheelY, key, keyDown (default true), timeMs (default now) }` ->
   * the INPUT_* bits. On a window of the view's own, the close bit (Escape) ends it as the user
   * closing the window does: closed state, calls throw "window closed"; `close()` still owes the destroy.
   */
  input(event) {
    const raw = {
      size: SIZE('CadaclysmViewEvent'), kind: _name(EVENT, event.type, 'event type'), pointer_id: event.pointerId ?? 0,
      pointer: _name(POINTER, event.pointer ?? 'mouse', 'pointer'), button: event.button ?? 0, shift: event.shift ? 1 : 0,
      x: event.x ?? 0, y: event.y ?? 0, wheel_y: event.wheelY ?? 0, key: event.key ?? null,
      key_down: (event.keyDown ?? true) ? 1 : 0, time_ms: event.timeMs ?? performance.now(),
    };
    const bits = this._lib.fn.input(this._live('cadaclysm_view_input'), raw);
    if (!bits && this._lib.lastError()) throw this._lib.failure('input');
    if ((bits & INPUT_CLOSE) && this._own) this._markClosed();
    return bits;
  }
  resize(width, height) { this._ok(this._lib.fn.resize(this._live('cadaclysm_view_resize'), width, height), 'resize'); }
  /** `[width, height]`: what `image()` reads, in physical pixels. */
  get size() {
    const w = [0], h = [0];
    this._ok(this._lib.fn.size(this._live('cadaclysm_view_size'), w, h), 'size');
    return [w[0], h[0]];
  }
  /**
   * Levels of detail: parts of `minTriangles` or more (0: the library's 2,048) get coarser
   * levels, built in the background after each show; a moving frame draws as `motion` says --
   * 'detailed' keeps every frame whole but for levels within half a pixel, 'smooth' holds the
   * frame rate and refines once the camera rests (see `wakeMs`). `motion` null turns levels off.
   */
  lod(motion = 'detailed', minTriangles = 0) {
    if (motion == null) { this._ok(this._lib.fn.set_lod(this._live('cadaclysm_view_set_lod'), null), 'lod'); return; }
    if (!Number.isInteger(minTriangles) || minTriangles < 0 || minTriangles > 0xFFFFFFFF) throw new ViewError(`lod: minTriangles is a count from 0 to 4294967295, not ${minTriangles}`);
    const raw = { size: SIZE('CadaclysmViewLod'), min_triangles: minTriangles, motion: _name(LOD_MOTION, motion, 'motion') };
    this._ok(this._lib.fn.set_lod(this._live('cadaclysm_view_set_lod'), raw), 'lod');
  }
  /** Milliseconds until `needsDraw` turns true by itself; 0 when a draw is owed now, null when none is coming. */
  get wakeMs() { const ms = this._lib.fn.wake_ms(this._live('cadaclysm_view_wake_ms')); return ms === NONE_COMING ? null : ms; }
  /** The window closed (its close button, Escape, the end of `run`): closed state; the shared window is let go. */
  _markClosed() {
    this._windowClosed = true;
    _open.delete(this);
    if (_sharedView === this) { _sharedView = null; this.close(); }
  }
  /** Every item removed (the shared window's `show()` replaces what it shows). */
  _clear() { for (const item of [...this._items.values()]) item.remove(); }
  /** Destroy the view (and its window). Idempotent. */
  close() {
    if (this._pointer === null) return;
    const p = this._pointer;
    this._pointer = null;
    _open.delete(this);
    _finalizer.unregister(this);
    _views.delete(this._ref);
    for (const ref of [..._views]) if (ref.deref() === undefined) _views.delete(ref);   // views nobody held
    for (const item of this._items.values()) item.shown = null;
    this._items.clear();
    this._lib.fn.destroy(p);
  }
  [DISPOSE]() { this.close(); }
}

/** The camera `run` left, with `azimuth`/`elevation` as `show()` takes them (cadaclysm_view.py's `_camera`). */
function _camera(cam, pick, yUp) {
  const eye = Array.from(cam.eye), target = Array.from(cam.target), up = Array.from(cam.up);
  let d = eye.map((e, i) => e - target[i]);
  let upO = up;
  if (yUp) { d = [d[0], -d[2], d[1]]; upO = [up[0], -up[2], up[1]]; }
  const length = Math.hypot(...d) || 1;
  d = d.map((c) => c / length);
  const deg = 180 / Math.PI;
  let azimuth;
  if (Math.hypot(d[0], d[1]) < 1e-4) {
    const sign = d[2] < 0 ? -1 : 1;
    azimuth = Math.atan2(-sign * upO[1], -sign * upO[0]) * deg;
  } else azimuth = Math.atan2(d[1], d[0]) * deg;
  const elevation = Math.asin(Math.max(-1, Math.min(1, d[2]))) * deg;
  return { eye, target, up, orthographic: Boolean(cam.orthographic), azimuth, elevation,
    pick: pick.item ? _pick(pick) : null };
}

/** A CadaclysmViewPick for the library to fill: `size` set, every other field zero. */
function _rawPick() {
  return { size: SIZE('CadaclysmViewPick'), item: 0, node: 0, face: 0, clicks: 0, has_point: 0, point: [0, 0, 0] };
}

/**
 * A hit as every pick answer carries it (cadaclysm_view.py's `_pick_dict`): the item, node and
 * face, `clicks` (2 for a double click, else 1) and `point` -- where the ray met the model, in the
 * coordinates the items were shown in -- or null where the library read no depth (no hit to
 * place, a machining stock, the terminal library).
 */
function _pick(raw) {
  return { item: raw.item, node: raw.node, face: raw.face, clicks: raw.clicks,
    point: raw.has_point ? Array.from(raw.point) : null };
}

/** A CadaclysmViewSnap for the library to fill: `size` set, every other field zero. */
function _rawSnap() {
  return { size: SIZE('CadaclysmViewSnap'), kind: 0, point: [0, 0, 0], item: 0, node: 0, face: 0, edge: 0,
    tangent: [0, 0, 0], axis: [0, 0, 0], radius: 0, distance_px: 0, clicks: 0 };
}

/**
 * A snap answer as cadaclysm_view.py's `_snap_dict`, camelCase: the kind's name, the point snapped
 * to (in the coordinates the items were shown in), the item, node and face, the edge (null for a
 * face, grid or plane snap), the edge's tangent, a circle's axis and radius, the cursor's distance
 * in pixels, and clicks (0 for `snap` and a hover, 1 or 2 for a click's).
 */
function _snap(raw) {
  const kind = Object.keys(SNAP_KINDS).find((k) => SNAP_KINDS[k] === raw.kind) ?? String(raw.kind);
  return { kind, point: Array.from(raw.point), item: raw.item, node: raw.node, face: raw.face,
    edge: raw.edge === SNAP_NONE ? null : raw.edge, tangent: Array.from(raw.tangent), axis: Array.from(raw.axis),
    radius: raw.radius, distancePx: raw.distance_px, clicks: raw.clicks };
}

/** Forget the library, the shared window and the window list (tests; nothing of this module's own may leak between them). */
function _reset() {
  _current = null;
  _sharedView = null;
  _open.clear();
  if (_timer) { clearInterval(_timer); _timer = null; }
}

// ---- show() and view() on the objects --------------------------------------------------

let _sharedView = null;    // the window `show()` replaces the contents of
function _shared() {
  if (_sharedView && (_sharedView._pointer === null || _sharedView._windowClosed)) _sharedView = null;
  return _sharedView;
}

/**
 * The camera the options ask for: top straight down, any other angle an orbit from the
 * front, then `fit` -- `frame(0)`, and for a node `frameNode` -- and only then the zoom, since
 * framing resets the distance a zoom sets (cadaclysm_view.py's `_aim` and `_zoom`). The camera
 * calls are not checked, as Python's are; `fit`'s own refusals (a node's) are.
 */
function _aim(v, o, fit) {
  const fn = v._lib.fn, p = v._live('cadaclysm_view_standard');
  const [baseAz, baseEl] = Array.isArray(o.view) ? o.view : VIEWS[o.view];
  const az = o.azimuth ?? baseAz, el = o.elevation ?? baseEl;
  if (el >= 90 && az === -90) fn.standard(p, STANDARD.top);
  else {
    fn.standard(p, STANDARD.front);
    const dx = -((az + 90) * Math.PI / 180) / ORBIT_PER_PIXEL;
    const dy = (el * Math.PI / 180) / ORBIT_PER_PIXEL;
    if (dx || dy) fn.orbit(p, dx, dy);
  }
  fn.frame(p, 0);
  fit();
  if (o.zoom != null && o.zoom > 0) fn.zoom(p, Math.log(o.zoom) / -Math.log(ZOOM_PER_STEP));
}

function _title(obj) {
  const scene = obj?.constructor?.name === 'Node' ? obj.scene : obj;
  if (scene?.constructor?.name === 'Scene') return path.basename(String(scene.path));
  return 'Solid';
}

/**
 * `obj.show()` (`mode` 'show') and `obj.view()` ('view'), by handle on every library
 * (cadaclysm_view.py's `present`). The wgpu library: `show` replaces what the shared window
 * shows, draws, and returns -- the timer keeps it live. Any other library (the terminal, one
 * of your own): `show` prints one still from a fresh view. `view` everywhere: a fresh view, run
 * until closed; the camera and last pick come back. `transforms`, for a scene: one posed world
 * transform per node (`Pose.show`), set on its item before drawing.
 */
function _present(obj, options = {}, mode = 'show', transforms = null) {
  // An option set to undefined is not given (Python's None): the default stands.
  options = Object.fromEntries(Object.entries(options ?? {}).filter(([, value]) => value !== undefined));
  const o = { view: 'iso', edges: true, tolerance: 0.05, ...options, up: options.up ?? 'z' };
  const kind = transforms ? 'Pose' : obj?.constructor?.name;
  if ('tolerance' in options && (kind === 'Scene' || kind === 'Node' || kind === 'Pose')) {
    throw new ViewError(`${kind}.${mode} takes no tolerance: a document is drawn at the tolerance it was read with`);
  }
  if (Array.isArray(o.view)) {
    if (o.view.length !== 2 || !o.view.every(Number.isFinite)) throw new ViewError(`view ${JSON.stringify(o.view)}: an [azimuth, elevation] pair, or one of ${Object.keys(VIEWS).join(', ')}`);
  } else if (!Object.hasOwn(VIEWS, o.view)) throw new ViewError(`view ${JSON.stringify(o.view)}: one of ${Object.keys(VIEWS).join(', ')}`);
  const up = String(o.up ?? 'z').toLowerCase();
  if (up !== 'y' && up !== 'z') throw new ViewError(`up ${JSON.stringify(o.up)}: 'y' or 'z'`);
  const width = o.width ?? 0, height = o.height ?? 0;
  if (!_pixels(width) || !_pixels(height)) throw new ViewError(`width=${width}, height=${height}: a size is pixels, 0 or more (0 = the library decides)`);
  const library = current();
  const shared = library.kind === 'wgpu' && mode === 'show';
  const viewOptions = { title: o.title ?? _title(obj), width, height, up };
  let v;
  if (shared) {
    v = _shared();
    if (v && v._yUp !== (up === 'y')) { v.close(); v = null; }
    if (!v) { v = new View(viewOptions); _sharedView = v; } else v._clear();
  } else v = new View(viewOptions);
  try {
    const item = v.show(obj, o.rgb ?? null, o.tolerance);
    if (transforms) item.nodeTransforms(transforms);
    v.layer('edges', o.edges);
    const isNode = obj?.constructor?.name === 'Node';
    _aim(v, o, isNode ? () => item.frameNode(obj.index) : () => {});
    if (mode === 'show') { v.draw(); return undefined; }
    return v.run();
  } finally { if (!shared) v.close(); }
}

module.exports = {
  ViewError, View, Item, Machining, Library, useTerminal, useWgpu, use, current, pump, loadFont,
  OPEN, CLOSED, VIEWS, _find, _camera, _pick, _png, _reset, _open, _release, _views, _present, _aim, _shared,
};
