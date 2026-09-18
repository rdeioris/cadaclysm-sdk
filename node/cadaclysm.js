'use strict';
/**
 * The cadaclysm C ABI, as JavaScript objects: this file is the whole binding.
 *
 *     const cad = require('cadaclysm');
 *     const scene = cad.open('model.stp');
 *     for (const node of scene.walk()) console.log('  '.repeat(node.depth) + node.label);
 *     for (const node of scene.nodes()) if (node.canMesh) node.saveMesh(`${node.index}.stl`);
 *     scene.close();
 *
 * It uses `koffi` and the published header `include/cadaclysm.h`, the way any
 * program would -- no generated bindings, no build step. Drop it beside your
 * own script and point `CADACLYSM_LIBRARY` at the shared library if it is not
 * where this looks by default (the SDK's `lib/`, or `target/release` of the
 * repository this file ships in).
 *
 * Every array handed back here is a copy: a `Mesh` outlives `forgetMeshes()`
 * and `close()`. Strings are copied too. The one thing that must not outlive
 * the scene is the scene.
 */
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const koffi = require('koffi');

// ---- errors & enums --------------------------------------------------------

/** A call into the library failed, carrying what it said about it. */
class CadaclysmError extends Error {
  constructor(message) { super(message); this.name = 'CadaclysmError'; }
}

/** `CADACLYSM_NONE` in the header, and `UINT32_MAX` underneath. */
const NONE = 0xFFFFFFFF;

/**
 * The coordinate space to open a file into -- `CadaclysmConvention`, plus two
 * flags of this module's own packing (`FILE_UNITS`, `UV_WORLD`) that `open`
 * unpacks into the options struct, exactly as `cadaclysm.py` does.
 */
const Convention = Object.freeze({
  NATIVE: 0, UNREAL: 1, UNITY: 2, Y_UP: 3, BLENDER: 4,
  FILE_UNITS: 0x100, UV_WORLD: 0x200,
  /** A packed number from a name a user typed: `"unreal"`, `"unreal+file-units"`. */
  parse(text) {
    const [preset, ...flags] = String(text).trim().toLowerCase().split('+');
    const packed = { native: 0, unreal: 1, unity: 2, 'y-up': 3, blender: 4 }[preset];
    if (packed === undefined) {
      throw new CadaclysmError(`no convention called '${preset}': native, unreal, unity, y-up or blender`);
    }
    let out = packed;
    for (const flag of flags.filter(Boolean)) {
      if (flag !== 'file-units') throw new CadaclysmError(`no convention flag called '${flag}': file-units`);
      out |= Convention.FILE_UNITS;
    }
    return out;
  },
});

/** Which field of an attribute holds its value. One-based; zero is "not there". */
const ValueKind = Object.freeze({ NONE: 0, TEXT: 1, INTEGER: 2, REAL: 3, BOOLEAN: 4, LIST: 5, REFERENCE: 6 });

// ---- finding the library ---------------------------------------------------

function libraryName() {
  if (process.platform === 'win32') return 'cadaclysm_capi.dll';
  if (process.platform === 'darwin') return 'libcadaclysm_capi.dylib';
  return 'libcadaclysm_capi.so';
}

/** `dir` and every directory above it, nearest first. */
function ancestors(dir) {
  const out = [];
  for (let d = dir; ; d = path.dirname(d)) {
    out.push(d);
    if (path.dirname(d) === d) return out;
  }
}

/** The candidates the ladder tries after the environment, in order. */
function _searchedPaths() {
  const name = libraryName();
  const here = __dirname;
  const searched = [path.join(here, name)];
  // An SDK checkout keeps the library in `lib/` beside the wrappers; the
  // repository this example ships in keeps it in `target/release` (or
  // `target/debug`, a fallback for a machine that only built that).
  for (const a of ancestors(here)) searched.push(path.join(a, 'lib', name));
  for (const a of ancestors(here)) {
    searched.push(path.join(a, 'target', 'release', name), path.join(a, 'target', 'debug', name));
  }
  return searched;
}

function _notFoundMessage(searched) {
  return `${libraryName()} not found. Looked in:\n` + searched.map((p) => `    ${p}\n`).join('')
    + 'Build it with:\n    cargo build --release -p cadaclysm-capi\n'
    + 'or run fetch.py in an SDK checkout, or point CADACLYSM_LIBRARY at it.';
}

/**
 * Where the shared library is, preferring a release build over a debug one.
 * `CADACLYSM_LIBRARY` first (a file, or a directory holding it), then beside
 * this file, then `lib/` in any ancestor (the SDK layout), then `target/release`
 * or `target/debug` in any ancestor (this repository's layout).
 */
function libraryPath() {
  const override = process.env.CADACLYSM_LIBRARY;
  if (override) {
    let candidate = override;
    if (fs.existsSync(candidate) && fs.statSync(candidate).isDirectory()) candidate = path.join(candidate, libraryName());
    if (fs.existsSync(candidate)) return candidate;
    throw new CadaclysmError(`CADACLYSM_LIBRARY=${override} names nothing that exists`);
  }
  const searched = _searchedPaths();
  for (const candidate of searched) if (fs.existsSync(candidate)) return candidate;
  throw new CadaclysmError(_notFoundMessage(searched));
}

// ---- the ABI's types -------------------------------------------------------
// Declared by the header's names, in the header's field order, one field per
// line: `tests/bindings.rs` reads these blocks and compares them with the
// header, so a drifted field fails a cargo test rather than a customer.

koffi.opaque('CadaclysmScene');
koffi.opaque('CadaclysmMeshlets');
const CadaclysmWindow = koffi.struct('CadaclysmWindow', {
  kind: 'uint32_t',
  handle: 'void *',
  display: 'void *',
});

const CadaclysmConventionSpec = koffi.struct('CadaclysmConventionSpec', {
  x: 'uint32_t',
  y: 'uint32_t',
  z: 'uint32_t',
  units_per_metre: 'double',
  file_units: 'bool',
  winding: 'uint32_t',
});
// A caller's say in which member of a zip opens; not exposed through `_options`
// or `open` by this task, but the ABI type must still be declared correctly so
// `CadaclysmOpenOptions` below has the right size and layout.
const CadaclysmCandidate = koffi.struct('CadaclysmCandidate', {
  name: 'const char *',
  format: 'const char *',
  depth: 'size_t',
});
koffi.proto('size_t CadaclysmPick(const CadaclysmCandidate *candidates, size_t count, void *user)');
const CadaclysmOpenOptions = koffi.struct('CadaclysmOpenOptions', {
  size: 'size_t',
  convention: 'uint32_t',
  spec: 'const CadaclysmConventionSpec *',
  file_units: 'bool',
  uvs: 'uint32_t',
  colors: 'uint32_t',
  source_meters_per_unit: 'double',
  schemas: 'const char **',
  schema_count: 'size_t',
  schema_text: 'const uint8_t *',
  schema_length: 'size_t',
  pick: 'CadaclysmPick *',
  pick_user: 'void *',
});
const CadaclysmBounds = koffi.struct('CadaclysmBounds', {
  min: koffi.array('float', 3),
  max: koffi.array('float', 3),
});
const CadaclysmAttribute = koffi.struct('CadaclysmAttribute', {
  name: 'const char *',
  kind: 'uint32_t',
  text: 'const char *',
  integer: 'int64_t',
  real: 'double',
  boolean: 'bool',
});
const CadaclysmMesh = koffi.struct('CadaclysmMesh', {
  positions: 'const float *',
  normals: 'const float *',
  uvs: 'const float *',
  colors: 'const float *',
  indices: 'const uint32_t *',
  vertex_count: 'uint32_t',
  index_count: 'uint32_t',
});
const CadaclysmCollision = koffi.struct('CadaclysmCollision', {
  size: 'uint32_t',
  shape: 'uint32_t',
  confidence: 'uint32_t',
  axis: 'uint32_t',
  frame: koffi.array('double', 16),
  half_extent: koffi.array('double', 3),
  radius: 'double',
  height: 'double',
  error: 'double',
  hull_vertex_count: 'uint32_t',
  hull_index_count: 'uint32_t',
});
const CadaclysmCollisionHull = koffi.struct('CadaclysmCollisionHull', {
  positions: 'const float *',
  indices: 'const uint32_t *',
  vertex_count: 'uint32_t',
  index_count: 'uint32_t',
});
const CadaclysmPolylines = koffi.struct('CadaclysmPolylines', {
  positions: 'const float *',
  counts: 'const uint32_t *',
  polyline_count: 'uint32_t',
  vertex_count: 'uint32_t',
});
const CadaclysmBeziers = koffi.struct('CadaclysmBeziers', {
  points: 'const float *',
  weights: 'const float *',
  count: 'uint32_t',
});
const CadaclysmFace = koffi.struct('CadaclysmFace', {
  kind: 'uint32_t',
  reversed: 'uint32_t',
  transposed: 'uint32_t',
  reserved: 'uint32_t',
  origin: koffi.array('float', 4),
  ax: koffi.array('float', 4),
  ay: koffi.array('float', 4),
  az: koffi.array('float', 4),
  domain: koffi.array('float', 4),
  scalars: koffi.array('float', 4),
  loop_start: 'uint32_t',
  loop_count: 'uint32_t',
  profile_start: 'uint32_t',
  profile_count: 'uint32_t',
  profile2_start: 'uint32_t',
  profile2_count: 'uint32_t',
  nurbs_start: 'uint32_t',
  nurbs_count: 'uint32_t',
});
const CadaclysmSurfaces = koffi.struct('CadaclysmSurfaces', {
  faces: 'const CadaclysmFace *',
  face_count: 'uint32_t',
  loops: 'const uint32_t *',
  loop_count: 'uint32_t',
  points: 'const float *',
  point_count: 'uint32_t',
  profiles: 'const float *',
  profile_count: 'uint32_t',
  nurbs: 'const float *',
  nurbs_count: 'uint32_t',
});

// ---- the function table ----------------------------------------------------

let library = null;

/** The loaded library's functions, loading on first use. */
function _lib() {
  if (library) return library;
  const l = koffi.load(libraryPath());
  const f = (proto) => l.func(proto);
  library = {
    last_error: f('const char *cadaclysm_last_error(void)'),
    version: f('const char *cadaclysm_version(void)'),
    open: f('CadaclysmScene *cadaclysm_open(const char *path, const CadaclysmOpenOptions *options)'),
    open_memory: f('CadaclysmScene *cadaclysm_open_memory(const uint8_t *bytes, size_t length, const char *format, const CadaclysmOpenOptions *options)'),
    open_options_init: f('void cadaclysm_open_options_init(_Out_ CadaclysmOpenOptions *options)'),
    close: f('void cadaclysm_close(CadaclysmScene *scene)'),
    node_count: f('uint32_t cadaclysm_node_count(const CadaclysmScene *scene)'),
    root_count: f('uint32_t cadaclysm_root_count(const CadaclysmScene *scene)'),
    root: f('uint32_t cadaclysm_root(const CadaclysmScene *scene, uint32_t index)'),
    schema: f('const char *cadaclysm_schema(const CadaclysmScene *scene)'),
    schema_read: f('const char *cadaclysm_schema_read(const CadaclysmScene *scene)'),
    metres_per_unit: f('double cadaclysm_metres_per_unit(const CadaclysmScene *scene)'),
    bounds: f('CadaclysmBounds cadaclysm_bounds(const CadaclysmScene *scene)'),
    node_parent: f('uint32_t cadaclysm_node_parent(const CadaclysmScene *scene, uint32_t node)'),
    node_child_count: f('uint32_t cadaclysm_node_child_count(const CadaclysmScene *scene, uint32_t node)'),
    node_child: f('uint32_t cadaclysm_node_child(const CadaclysmScene *scene, uint32_t node, uint32_t index)'),
    node_depth: f('uint32_t cadaclysm_node_depth(const CadaclysmScene *scene, uint32_t node)'),
    node_name: f('const char *cadaclysm_node_name(const CadaclysmScene *scene, uint32_t node)'),
    node_kind: f('const char *cadaclysm_node_kind(const CadaclysmScene *scene, uint32_t node)'),
    node_id: f('const char *cadaclysm_node_id(const CadaclysmScene *scene, uint32_t node)'),
    node_color: f('bool cadaclysm_node_color(const CadaclysmScene *scene, uint32_t node, _Out_ float *rgba)'),
    node_transform: f('void cadaclysm_node_transform(const CadaclysmScene *scene, uint32_t node, _Out_ double *out)'),
    placement_count: f('uint32_t cadaclysm_placement_count(const CadaclysmScene *scene)'),
    placement_geometry: f('uint32_t cadaclysm_placement_geometry(const CadaclysmScene *scene, uint32_t placement)'),
    placement_select: f('uint32_t cadaclysm_placement_select(const CadaclysmScene *scene, uint32_t placement)'),
    placement_transform: f('void cadaclysm_placement_transform(const CadaclysmScene *scene, uint32_t placement, _Out_ double *out)'),
    node_attribute_count: f('uint32_t cadaclysm_node_attribute_count(const CadaclysmScene *scene, uint32_t node)'),
    node_attribute: f('CadaclysmAttribute cadaclysm_node_attribute(const CadaclysmScene *scene, uint32_t node, uint32_t index)'),
    query: f('uint32_t cadaclysm_query(const CadaclysmScene *scene, const char *filter, _Out_ uint32_t *out, uint32_t capacity)'),
    node_can_mesh: f('bool cadaclysm_node_can_mesh(const CadaclysmScene *scene, uint32_t node)'),
    node_visible: f('bool cadaclysm_node_visible(const CadaclysmScene *scene, uint32_t node)'),
    node_mesh: f('CadaclysmMesh cadaclysm_node_mesh(const CadaclysmScene *scene, uint32_t node)'),
    node_bounds: f('CadaclysmBounds cadaclysm_node_bounds(const CadaclysmScene *scene, uint32_t node)'),
    node_collision: f('bool cadaclysm_node_collision(const CadaclysmScene *scene, uint32_t node, uint32_t hull_budget, _Inout_ CadaclysmCollision *out)'),
    node_collision_hull: f('CadaclysmCollisionHull cadaclysm_node_collision_hull(const CadaclysmScene *scene, uint32_t node, uint32_t hull_budget)'),
    node_instance_of: f('uint32_t cadaclysm_node_instance_of(const CadaclysmScene *scene, uint32_t node)'),
    node_select_as: f('uint32_t cadaclysm_node_select_as(const CadaclysmScene *scene, uint32_t node)'),
    node_generator: f('const char *cadaclysm_node_generator(const CadaclysmScene *scene, uint32_t node)'),
    lod_levels: f('uint32_t cadaclysm_lod_levels(void)'),
    node_mesh_lod: f('CadaclysmMesh cadaclysm_node_mesh_lod(const CadaclysmScene *scene, uint32_t node, uint32_t level)'),
    node_lod_error: f('float cadaclysm_node_lod_error(const CadaclysmScene *scene, uint32_t node, uint32_t level)'),
    diagnostic_count: f('uint32_t cadaclysm_diagnostic_count(const CadaclysmScene *scene)'),
    diagnostic: f('const char *cadaclysm_diagnostic(const CadaclysmScene *scene, uint32_t index)'),
    geometry_diagnostic_count: f('uint32_t cadaclysm_geometry_diagnostic_count(const CadaclysmScene *scene)'),
    geometry_diagnostic: f('const char *cadaclysm_geometry_diagnostic(const CadaclysmScene *scene, uint32_t index)'),
    node_edges: f('CadaclysmPolylines cadaclysm_node_edges(const CadaclysmScene *scene, uint32_t node)'),
    node_edge_beziers: f('CadaclysmBeziers cadaclysm_node_edge_beziers(const CadaclysmScene *scene, uint32_t node)'),
    node_surfaces: f('CadaclysmSurfaces cadaclysm_node_surfaces(const CadaclysmScene *scene, uint32_t node)'),
    surface_matrix: f('void cadaclysm_surface_matrix(const CadaclysmScene *scene, _Out_ float *out)'),
    node_curve_beziers: f('CadaclysmBeziers cadaclysm_node_curve_beziers(const CadaclysmScene *scene, uint32_t node)'),
    node_isocurve_beziers: f('CadaclysmBeziers cadaclysm_node_isocurve_beziers(const CadaclysmScene *scene, uint32_t node)'),
    node_curves: f('CadaclysmPolylines cadaclysm_node_curves(const CadaclysmScene *scene, uint32_t node)'),
    node_isocurves: f('CadaclysmPolylines cadaclysm_node_isocurves(const CadaclysmScene *scene, uint32_t node)'),
    forget_meshes: f('void cadaclysm_forget_meshes(CadaclysmScene *scene)'),
    realize_all: f('uint32_t cadaclysm_realize_all(const CadaclysmScene *scene)'),
    realized: f('uint32_t cadaclysm_realized(const CadaclysmScene *scene)'),
    realize_total: f('uint32_t cadaclysm_realize_total(const CadaclysmScene *scene)'),
    cancel: f('void cadaclysm_cancel(const CadaclysmScene *scene)'),
    mesh_format_count: f('uint32_t cadaclysm_mesh_format_count(void)'),
    mesh_format: f('const char *cadaclysm_mesh_format(uint32_t index)'),
    mesh_format_extension: f('const char *cadaclysm_mesh_format_extension(uint32_t index)'),
    mesh_format_label: f('const char *cadaclysm_mesh_format_label(uint32_t index)'),
    format_count: f('uint32_t cadaclysm_format_count(void)'),
    format_name: f('const char *cadaclysm_format_name(uint32_t index)'),
    format_extensions: f('const char *cadaclysm_format_extensions(uint32_t index)'),
    node_save_mesh: f('bool cadaclysm_node_save_mesh(const CadaclysmScene *scene, uint32_t node, const char *path, const char *format)'),
    scene_save: f('bool cadaclysm_scene_save(const CadaclysmScene *scene, const char *path, const char *format)'),
    source_name: f('const char *cadaclysm_source_name(const CadaclysmScene *scene)'),
    pick_file: f('const char *cadaclysm_pick_file(const CadaclysmWindow *parent)'),
    pick_save: f('const char *cadaclysm_pick_save(const CadaclysmWindow *parent, const char *suggested_name)'),
    license_set: f('bool cadaclysm_license_set(const char *text_or_path)'),
    license_info: f('const char *cadaclysm_license_info(void)'),
    license_notice_count: f('uint64_t cadaclysm_license_notice_count(void)'),
    build_date: f('const char *cadaclysm_build_date(void)'),
    meshlets_build: f('CadaclysmMeshlets *cadaclysm_meshlets_build(const float *positions, const float *normals, size_t vertex_count, const uint32_t *indices, size_t index_count, uint32_t max_triangles, uint32_t max_vertices, int32_t levels)'),
    meshlets_count: f('uint32_t cadaclysm_meshlets_count(const CadaclysmMeshlets *handle)'),
    meshlet_triangle_count: f('uint32_t cadaclysm_meshlet_triangle_count(const CadaclysmMeshlets *handle, uint32_t index)'),
    meshlet_vertex_count: f('uint32_t cadaclysm_meshlet_vertex_count(const CadaclysmMeshlets *handle, uint32_t index)'),
    meshlet_level: f('uint32_t cadaclysm_meshlet_level(const CadaclysmMeshlets *handle, uint32_t index)'),
    meshlet_group: f('uint32_t cadaclysm_meshlet_group(const CadaclysmMeshlets *handle, uint32_t index)'),
    meshlet_error: f('float cadaclysm_meshlet_error(const CadaclysmMeshlets *handle, uint32_t index)'),
    meshlet_child_count: f('uint32_t cadaclysm_meshlet_child_count(const CadaclysmMeshlets *handle, uint32_t index)'),
    meshlet_positions: f('void cadaclysm_meshlet_positions(const CadaclysmMeshlets *handle, uint32_t index, _Out_ float *out)'),
    meshlet_normals: f('void cadaclysm_meshlet_normals(const CadaclysmMeshlets *handle, uint32_t index, _Out_ float *out)'),
    meshlet_indices: f('void cadaclysm_meshlet_indices(const CadaclysmMeshlets *handle, uint32_t index, _Out_ uint32_t *out)'),
    meshlet_children: f('void cadaclysm_meshlet_children(const CadaclysmMeshlets *handle, uint32_t index, _Out_ uint32_t *out)'),
    meshlets_free: f('void cadaclysm_meshlets_free(CadaclysmMeshlets *handle)'),
  };
  return library;
}

/** A borrowed C string as a JS string; `""` for null. */
function _text(raw) { return raw == null ? '' : String(raw); }

function _lastError() { return _text(_lib().last_error()); }

/** `n` floats at `ptr` as a fresh `Float32Array`, or `null` for a null pointer. */
function _floats(ptr, n) {
  if (ptr == null) return null;
  return n === 0 ? new Float32Array(0) : koffi.decode(ptr, 'float', n);
}
/** `n` uint32s at `ptr` as a fresh `Uint32Array`, or `null` for a null pointer. */
function _uint32s(ptr, n) {
  if (ptr == null) return null;
  return n === 0 ? new Uint32Array(0) : koffi.decode(ptr, 'uint32_t', n);
}

// ---- module-level functions --------------------------------------------------

/** The version of the library actually loaded, which is the one worth reporting. */
function version() { return _text(_lib().version()); }

/** When the loaded library was built, `YYYY-MM-DD`. */
function buildDate() { return _text(_lib().build_date()); }

/**
 * Load a license: the certificate text, or the path of a file holding it.
 * Without this the library looks in `CADACLYSM_LICENSE`, then for
 * `cadaclysm.lic` beside the executable and in the working directory. Throws
 * with the library's reason when the text does not verify; the previous
 * license, if any, stays in use.
 */
function license(textOrPath) {
  if (!_lib().license_set(String(textOrPath))) throw new CadaclysmError(_lastError() || 'license refused');
}

/**
 * One line about the license the library is running under. Never null: the
 * license line, or, without one, `unlicensed` (`unlicensed -- <reason>` when
 * a license was found but did not verify).
 */
function licenseInfo() { return String(_lib().license_info()); }

/**
 * How many unlicensed notices this library has printed to stderr in this
 * process. An application without a stderr to watch (a GUI, a game) can show
 * its own banner by polling this instead.
 */
function licenseNoticeCount() { return Number(_lib().license_notice_count()); }

/** Every format `Node.saveMesh` writes, as `[name, extension, label]`. */
function meshFormats() {
  const l = _lib();
  const out = [];
  for (let i = 0, n = l.mesh_format_count(); i < n; i++) {
    out.push([_text(l.mesh_format(i)), _text(l.mesh_format_extension(i)), _text(l.mesh_format_label(i))]);
  }
  return out;
}

/** Every format this build reads, as `[name, [extension, ...]]`. */
function formats() {
  const l = _lib();
  const out = [];
  for (let i = 0, n = l.format_count(); i < n; i++) {
    // Semicolon-separated in the header (`"step;stp"`), the separator dialogs want.
    out.push([_text(l.format_name(i)), _text(l.format_extensions(i)).split(';').filter(Boolean)]);
  }
  return out;
}

/** How many coarser levels `Node.meshLod` offers (`CADACLYSM_LOD_LEVELS`). */
function lodLevels() { return _lib().lod_levels(); }

// ---- plain values -----------------------------------------------------------

/** An axis-aligned box, or all zeros where there was nothing to bound. */
class Bounds {
  constructor(min, max) {
    this.min = Float32Array.from(min);
    this.max = Float32Array.from(max);
  }
  /** Whether this is the all-zero box the ABI uses for "nothing here". */
  get isEmpty() { return !this.min.some(Boolean) && !this.max.some(Boolean); }
  get size() { return [0, 1, 2].map((i) => this.max[i] - this.min[i]); }
  get centre() { return [0, 1, 2].map((i) => (this.min[i] + this.max[i]) / 2); }
}

/** A float written as cadaclysm's own Rust `Display` writes it: no exponent. */
function _decimalText(value) {
  if (Number.isNaN(value)) return 'NaN';
  if (!Number.isFinite(value)) return value > 0 ? 'inf' : '-inf';
  const s = String(value);
  if (!/e/i.test(s)) return s;
  // Expand `1e-7` / `1e21` the way Decimal(repr(v)) does in the Python wrapper.
  const [mantissa, exp] = s.toLowerCase().split('e');
  const e = Number(exp);
  const negative = mantissa.startsWith('-');
  const digits = mantissa.replace('-', '').replace('.', '');
  const point = (mantissa.replace('-', '').split('.')[0] || '').length + e;
  let out;
  if (point <= 0) out = '0.' + '0'.repeat(-point) + digits;
  else if (point >= digits.length) out = digits + '0'.repeat(point - digits.length);
  else out = digits.slice(0, point) + '.' + digits.slice(point);
  out = out.replace(/\.?0+$/, (m) => (m.startsWith('.') ? '' : m)) ;
  return (negative ? '-' : '') + out;
}

/**
 * One thing the file said about a node. `value` is the JS type the kind
 * names: string for TEXT/LIST/REFERENCE, number for INTEGER/REAL, boolean for
 * BOOLEAN, null for NONE.
 */
class Attribute {
  constructor(name, kind, value) { this.name = name; this.kind = kind; this.value = value; }
  /** The value rendered for display, as cadaclysm's own Rust `Display` does. */
  get text() {
    if (this.value === null) return '';
    if (this.kind === ValueKind.REAL) return _decimalText(this.value);
    if (this.kind === ValueKind.BOOLEAN) return this.value ? 'true' : 'false';
    return String(this.value);
  }
}

/** A `CadaclysmAttribute` as an `Attribute`, or null for the all-zero one past the end. */
function _attribute(raw) {
  if (raw.name == null) return null;
  const kind = raw.kind >= 0 && raw.kind <= 6 ? raw.kind : ValueKind.NONE;
  let value = null;
  if (kind === ValueKind.TEXT || kind === ValueKind.LIST || kind === ValueKind.REFERENCE) value = _text(raw.text);
  else if (kind === ValueKind.INTEGER) value = Number(raw.integer);
  else if (kind === ValueKind.REAL) value = raw.real;
  else if (kind === ValueKind.BOOLEAN) value = Boolean(raw.boolean);
  return new Attribute(_text(raw.name), kind, value);
}

/** A node's triangles in its own frame. Copies; safe to keep. */
class Mesh {
  constructor(positions, normals, uvs, colors, indices, vertexCount, indexCount) {
    this.positions = positions; this.normals = normals; this.uvs = uvs; this.colors = colors;
    this.indices = indices; this.vertexCount = vertexCount; this.indexCount = indexCount;
  }
  get triangleCount() { return Math.floor(this.indexCount / 3); }
}

/** A `CadaclysmMesh` (by value) as a `Mesh`. */
function _meshOf(raw) {
  const n = raw.vertex_count;
  return new Mesh(
    _floats(raw.positions, n * 3) ?? new Float32Array(0),
    _floats(raw.normals, n * 3),
    _floats(raw.uvs, n * 2),
    _floats(raw.colors, n * 4),
    _uint32s(raw.indices, raw.index_count) ?? new Uint32Array(0),
    n, raw.index_count,
  );
}

/** Feature edges or free curves, flattened: runs of points end to end, and a count per run. */
class Polylines {
  constructor(positions, counts, polylineCount, vertexCount) {
    this.positions = positions; this.counts = counts; this.polylineCount = polylineCount; this.vertexCount = vertexCount;
  }
  /** Endpoint index pairs, two per segment, for a GL_LINES-style draw. */
  segmentIndices() {
    let total = 0;
    for (const c of this.counts) if (c >= 2) total += c - 1;
    const out = new Uint32Array(total * 2);
    let start = 0, k = 0;
    for (const c of this.counts) {
      for (let i = 0; i + 1 < c; i++) { out[k++] = start + i; out[k++] = start + i + 1; }
      start += c;
    }
    return out;
  }
  /** The endpoints themselves, three floats a point, two points a segment. */
  segments() {
    const idx = this.segmentIndices();
    const out = new Float32Array(idx.length * 3);
    for (let i = 0; i < idx.length; i++) { const p = idx[i] * 3; out[i * 3] = this.positions[p]; out[i * 3 + 1] = this.positions[p + 1]; out[i * 3 + 2] = this.positions[p + 2]; }
    return out;
  }
}

function _polylinesOf(raw) {
  return new Polylines(
    _floats(raw.positions, raw.vertex_count * 3) ?? new Float32Array(0),
    _uint32s(raw.counts, raw.polyline_count) ?? new Uint32Array(0),
    raw.polyline_count, raw.vertex_count,
  );
}

/** Rational cubic Bezier segments: 4 control points x 3 floats each, and 4 weights, per segment. */
class Beziers {
  constructor(points, weights, count) { this.points = points; this.weights = weights; this.count = count; }
}

function _beziersOf(raw) {
  return new Beziers(_floats(raw.points, raw.count * 12) ?? new Float32Array(0), _floats(raw.weights, raw.count * 4) ?? new Float32Array(0), raw.count);
}

/**
 * One trimmed face: `kind` 0 plane, 1 cylinder, 2 cone, 3 sphere, 4 torus,
 * 5 revolution, 6 extrusion, 7 NURBS, 8 sum; `origin`/`ax`/`ay`/`az` the frame
 * (3 floats each); `domain` `(u_min, v_min, u_max, v_max)`; `scalars` kind-
 * dependent; `loops` an array of `Float32Array`s of `(u, v)` pairs, each
 * closing implicitly; `profile`, `profile2`, `nurbs` what a swept or NURBS
 * surface needs. See `CadaclysmFace` in the header.
 */
class Face {
  constructor(fields) { Object.assign(this, fields); }
}

/** A part's faces as surfaces and trims, in the file's own frame (see `Scene.surfaceMatrix`). */
class Surfaces {
  constructor(faces) { this.faces = faces; }
  get length() { return this.faces.length; }
  [Symbol.iterator]() { return this.faces[Symbol.iterator](); }
}

function _surfacesOf(raw) {
  if (!raw.face_count) return new Surfaces([]);
  const faces = koffi.decode(raw.faces, 'CadaclysmFace', raw.face_count);
  const loops = _uint32s(raw.loops, raw.loop_count * 2) ?? new Uint32Array(0);
  const points = _floats(raw.points, raw.point_count * 2) ?? new Float32Array(0);
  const profiles = _floats(raw.profiles, raw.profile_count * 4) ?? new Float32Array(0);
  const nurbs = _floats(raw.nurbs, raw.nurbs_count) ?? new Float32Array(0);
  const out = [];
  for (const f of faces) {
    const rings = [];
    for (let k = 0; k < f.loop_count; k++) {
      const start = loops[(f.loop_start + k) * 2], length = loops[(f.loop_start + k) * 2 + 1];
      rings.push(points.slice(start * 2, (start + length) * 2));
    }
    out.push(new Face({
      kind: f.kind, reversed: Boolean(f.reversed), transposed: Boolean(f.transposed),
      origin: f.origin.slice(0, 3), ax: f.ax.slice(0, 3), ay: f.ay.slice(0, 3), az: f.az.slice(0, 3),
      domain: Float32Array.from(f.domain), scalars: Float32Array.from(f.scalars),
      loops: rings,
      profile: profiles.slice(f.profile_start * 4, (f.profile_start + f.profile_count) * 4),
      profile2: profiles.slice(f.profile2_start * 4, (f.profile2_start + f.profile2_count) * 4),
      nurbs: nurbs.slice(f.nurbs_start, f.nurbs_start + f.nurbs_count),
    }));
  }
  return new Surfaces(out);
}

/** What a node turned out to be for a physics engine; `frame` and `halfExtent` are always the true oriented box. */
class Collision {
  constructor(raw) {
    this.shape = raw.shape; this.confidence = raw.confidence; this.axis = raw.axis;
    this.frame = Float64Array.from(raw.frame); this.halfExtent = Float64Array.from(raw.half_extent);
    this.radius = raw.radius; this.height = raw.height; this.error = raw.error;
    this.hullVertexCount = raw.hull_vertex_count; this.hullIndexCount = raw.hull_index_count;
  }
  /** 0 none, 1 box, 2 sphere, 3 capsule, 4 cylinder, 5 hull. */
  get shapeName() { return ['none', 'box', 'sphere', 'capsule', 'cylinder', 'hull'][this.shape] ?? String(this.shape); }
}

class CollisionHull {
  constructor(positions, indices, vertexCount, indexCount) {
    this.positions = positions; this.indices = indices; this.vertexCount = vertexCount; this.indexCount = indexCount;
  }
}

/** 16 column-major numbers as a row-major 4x4 array of rows. */
function _rows(flat) {
  return [0, 1, 2, 3].map((r) => [0, 1, 2, 3].map((c) => flat[c * 4 + r]));
}

// ---- placements -------------------------------------------------------------

/**
 * One drawing of one node's geometry, at one place. Iterate
 * `scene.placements()` to draw, and nodes to build a tree: a Rhino block's
 * members draw once per placement of it rather than once on their own.
 */
class Placement {
  constructor(scene, index) { this.scene = scene; this.index = index; }
  /** The node whose mesh, edges and curves this draws. */
  get geometry() { return new Node(this.scene, _lib().placement_geometry(this.scene._handle, this.index)); }
  /** What a click on this drawing should select. */
  get select() { return new Node(this.scene, _lib().placement_select(this.scene._handle, this.index)); }
  /** Where to draw it, composed to the root, column-major, 16 doubles. */
  get rawTransform() {
    const out = new Float64Array(16);
    _lib().placement_transform(this.scene._handle, this.index, out);
    return out;
  }
  /** The same matrix as four rows, so `m[r][c]` reads as in a textbook. */
  get transform() { return _rows(this.rawTransform); }
}

// ---- nodes ------------------------------------------------------------------

/**
 * One node of the document: an assembly, a shape, a placement. A handle rather
 * than a snapshot -- every property asks the scene when read, so nothing goes
 * stale and nothing is built that a caller never looks at.
 */
class Node {
  constructor(scene, index) { this.scene = scene; this.index = index; }
  equals(other) { return other instanceof Node && other.index === this.index && other.scene === this.scene; }
  get name() { return _text(_lib().node_name(this.scene._handle, this.index)); }
  get id() { return _text(_lib().node_id(this.scene._handle, this.index)); }
  get kind() { return _text(_lib().node_kind(this.scene._handle, this.index)); }
  /** The file's opening state, not inherited; `visibleNow` walks the parents. */
  get visible() { return Boolean(_lib().node_visible(this.scene._handle, this.index)); }
  get visibleNow() {
    for (let node = this; node !== null; node = node.parent) if (!node.visible) return false;
    return true;
  }
  /** Rhino's idea: locked by its own flag or its layer's; `false` elsewhere. */
  get locked() {
    const a = this.attributes().find((x) => x.name === 'Locked');
    return a ? Boolean(a.value) : false;
  }
  get label() { return this.name || this.kind || `#${this.index}`; }
  get depth() { return _lib().node_depth(this.scene._handle, this.index); }
  /** Empty for a node that draws nothing. */
  get generator() { return _text(_lib().node_generator(this.scene._handle, this.index)); }
  get parent() { return this.scene._nodeOrNone(_lib().node_parent(this.scene._handle, this.index)); }
  children() {
    const l = _lib(); const h = this.scene._handle;
    const out = [];
    for (let i = 0, n = l.node_child_count(h, this.index); i < n; i++) out.push(new Node(this.scene, l.node_child(h, this.index, i)));
    return out;
  }
  /** The part whose geometry this one is a placement of, or null. */
  get instanceOf() { return this.scene._nodeOrNone(_lib().node_instance_of(this.scene._handle, this.index)); }
  /** The node a click here should select: itself, or the object it represents. */
  get selectAs() {
    const chosen = _lib().node_select_as(this.scene._handle, this.index);
    return chosen === NONE ? this : new Node(this.scene, chosen);
  }
  attributes() {
    const l = _lib(); const h = this.scene._handle;
    const out = [];
    for (let i = 0, n = l.node_attribute_count(h, this.index); i < n; i++) {
      const a = _attribute(l.node_attribute(h, this.index, i));
      if (a) out.push(a);
    }
    return out;
  }
  /** Asks for nothing to be built; structure nodes answer false. */
  get canMesh() { return Boolean(_lib().node_can_mesh(this.scene._handle, this.index)); }
  /** The node's own transform, column-major, 16 doubles. */
  get rawTransform() {
    const out = new Float64Array(16);
    _lib().node_transform(this.scene._handle, this.index, out);
    return out;
  }
  get transform() { return _rows(this.rawTransform); }
  /** The node's own colour as `[r, g, b, a]`, or null where the file gave none. */
  get color() {
    const rgba = new Float32Array(4);
    return _lib().node_color(this.scene._handle, this.index, rgba) ? Array.from(rgba) : null;
  }
  /** Builds the geometry if it has not been built. */
  get bounds() { const b = _lib().node_bounds(this.scene._handle, this.index); return new Bounds(b.min, b.max); }
  mesh() { return _meshOf(_lib().node_mesh(this.scene._handle, this.index)); }
  /** Level 0 is `mesh()`; 1..`lodLevels()` share its vertices and use fewer of its indices. */
  meshLod(level) { return _meshOf(_lib().node_mesh_lod(this.scene._handle, this.index, level)); }
  /** How far a level moved the surface, in the scene's units; what to pick levels by. */
  lodError(level) { return _lib().node_lod_error(this.scene._handle, this.index, level); }
  surfaces() { return _surfacesOf(_lib().node_surfaces(this.scene._handle, this.index)); }
  edges() { return _polylinesOf(_lib().node_edges(this.scene._handle, this.index)); }
  curves() { return _polylinesOf(_lib().node_curves(this.scene._handle, this.index)); }
  isocurves() { return _polylinesOf(_lib().node_isocurves(this.scene._handle, this.index)); }
  edgeBeziers() { return _beziersOf(_lib().node_edge_beziers(this.scene._handle, this.index)); }
  curveBeziers() { return _beziersOf(_lib().node_curve_beziers(this.scene._handle, this.index)); }
  isocurveBeziers() { return _beziersOf(_lib().node_isocurve_beziers(this.scene._handle, this.index)); }
  /** The collision body, or null for a node that draws nothing. `hullBudget` 0 asks for the Unity limit. */
  collision(hullBudget = 0) {
    const out = { size: koffi.sizeof(CadaclysmCollision) };
    return _lib().node_collision(this.scene._handle, this.index, hullBudget, out) ? new Collision(out) : null;
  }
  collisionHull(hullBudget = 0) {
    const h = _lib().node_collision_hull(this.scene._handle, this.index, hullBudget);
    return new CollisionHull(_floats(h.positions, h.vertex_count * 3) ?? new Float32Array(0), _uint32s(h.indices, h.index_count) ?? new Uint32Array(0), h.vertex_count, h.index_count);
  }
  /** Write this node's own mesh (no placement) in one of `meshFormats()`; throws if it draws nothing. */
  saveMesh(filePath, format = 'stl') {
    if (!_lib().node_save_mesh(this.scene._handle, this.index, String(filePath), format)) {
      throw new CadaclysmError(_lastError() || `could not write ${filePath}`);
    }
  }
  async meshAsync() { const m = await this.scene._async('meshAsync', { op: 'mesh', node: this.index }); return new Mesh(m.positions, m.normals, m.uvs, m.colors, m.indices, m.vertexCount, m.indexCount); }
  async meshLodAsync(level) { const m = await this.scene._async('meshLodAsync', { op: 'meshLod', node: this.index, level }); return new Mesh(m.positions, m.normals, m.uvs, m.colors, m.indices, m.vertexCount, m.indexCount); }
  async saveMeshAsync(filePath, format = 'stl') { await this.scene._async('saveMeshAsync', { op: 'saveMesh', node: this.index, path: String(filePath), format }); }
  /** Depth-first, this node first. */
  *walk() {
    const stack = [this];
    while (stack.length) {
      const node = stack.pop();
      yield node;
      stack.push(...node.children().reverse());
    }
  }
}

// ---- the scene ---------------------------------------------------------------

const _finalizer = typeof FinalizationRegistry === 'function'
  ? new FinalizationRegistry((pointer) => { try { _lib().close(pointer); } catch (_) { /* the process is going anyway */ } })
  : null;

/** An open document. Close it when done, or `using scene = ...` where available. */
class Scene {
  constructor(pointer, filePath, schemaPath, convention) {
    this._pointer = pointer;
    /** Locked by an in-flight async call: the call's name, or null. */
    this._busy = null;
    this.path = filePath;
    this.schemaPath = schemaPath;
    this.convention = convention;
    if (_finalizer) _finalizer.register(this, pointer, this);
  }
  /** The raw handle, refusing a closed or busy scene so no dangling pointer reaches C. */
  get _handle() {
    if (this._pointer === null) throw new CadaclysmError(`${path.basename(this.path)}: the scene is closed`);
    if (this._busy) throw new CadaclysmError(`busy: ${this._busy} in progress`);
    return this._pointer;
  }
  get closed() { return this._pointer === null; }
  /** Give the scene back. Idempotent. */
  close() {
    if (this._pointer === null) return;
    if (this._busy) throw new CadaclysmError(`busy: ${this._busy} in progress`);
    const pointer = this._pointer;
    this._pointer = null;
    if (_finalizer) _finalizer.unregister(this);
    _lib().close(pointer);
  }
  [Symbol.for('nodejs.dispose')]() { this.close(); }
  // -- the file --
  get version() { return version(); }
  get schema() { return _text(_lib().schema(this._handle)); }
  get schemaRead() { return _text(_lib().schema_read(this._handle)); }
  /** Whether the file read under a schema other than the one it declared (bare names compared). */
  get substituted() {
    const read = this.schemaRead;
    if (!read) return false;
    const bare = (e) => e.split('{')[0].trim().replace(/^\.+|\.+$/g, '').toLowerCase();
    return !this.schema.split(',').map(bare).includes(bare(read));
  }
  /** The archive member this was read from (`open` on a `.zip` chose one), or null for a plain file. */
  get sourceName() { const raw = _lib().source_name(this._handle); return raw ? String(raw) : null; }
  get metresPerUnit() { return _lib().metres_per_unit(this._handle); }
  /** The whole document's box, which meshes all of it. */
  get bounds() { const b = _lib().bounds(this._handle); return new Bounds(b.min, b.max); }
  /** The 4x4 (16 floats, column-major) that puts `Node.surfaces()` in the space everything else is in. */
  get surfaceMatrix() { const out = new Float32Array(16); _lib().surface_matrix(this._handle, out); return out; }
  diagnostics() {
    const l = _lib(); const h = this._handle; const out = [];
    for (let i = 0, n = l.diagnostic_count(h); i < n; i++) out.push(_text(l.diagnostic(h, i)));
    return out;
  }
  geometryDiagnostics() {
    const l = _lib(); const h = this._handle; const out = [];
    for (let i = 0, n = l.geometry_diagnostic_count(h); i < n; i++) out.push(_text(l.geometry_diagnostic(h, i)));
    return out;
  }
  // -- nodes --
  get nodeCount() { return _lib().node_count(this._handle); }
  node(index) {
    const count = this.nodeCount;
    if (!(Number.isInteger(index) && index >= 0 && index < count)) throw new CadaclysmError(`node ${index} of ${count}`);
    return new Node(this, index);
  }
  nodes() { const out = []; for (let i = 0, n = this.nodeCount; i < n; i++) out.push(new Node(this, i)); return out; }
  _nodeOrNone(index) { return index === NONE ? null : new Node(this, index); }
  roots() {
    const l = _lib(); const h = this._handle; const out = [];
    for (let i = 0, n = l.root_count(h); i < n; i++) { const r = l.root(h, i); if (r !== NONE) out.push(new Node(this, r)); }
    return out;
  }
  *walk() { for (const root of this.roots()) yield* root.walk(); }
  /** Node indices matching a filter expression; throws with the parser's message on a bad one. */
  query(filter) {
    const l = _lib(); const h = this._handle;
    const total = l.query(h, filter, null, 0);
    if (total === 0) {
      const reason = _lastError();
      if (reason) throw new CadaclysmError(`${path.basename(this.path)}: ${reason}`);
      return [];
    }
    const out = new Uint32Array(total);
    const written = l.query(h, filter, out, total);
    return Array.from(out.subarray(0, Math.min(written, total)));
  }
  placements() {
    const out = [];
    for (let i = 0, n = _lib().placement_count(this._handle); i < n; i++) out.push(new Placement(this, i));
    return out;
  }
  // -- building geometry --
  /** Mesh every part over every core; returns how many were built. */
  realizeAll() { return _lib().realize_all(this._handle); }
  get realized() { return _lib().realized(this._pointerOrThrow()); }
  get realizeTotal() { return _lib().realize_total(this._pointerOrThrow()); }
  /** One-way, for the life of the scene; allowed while an async realize runs. */
  cancel() { _lib().cancel(this._pointerOrThrow()); }
  /** Drop every built mesh; the next ask rebuilds. */
  forgetMeshes() { _lib().forget_meshes(this._handle); }
  /** The handle ignoring the busy lock: for the calls the header allows from another thread. */
  _pointerOrThrow() {
    if (this._pointer === null) throw new CadaclysmError(`${path.basename(this.path)}: the scene is closed`);
    return this._pointer;
  }
  /** Run `message` on the worker with this scene locked as `name`. */
  async _async(name, message) {
    const pointer = this._pointerOrThrow();
    if (this._busy) throw new CadaclysmError(`busy: ${this._busy} in progress`);
    this._busy = name;
    try { return await _run({ ...message, address: _addressOf(pointer) }); } finally { this._busy = null; }
  }
  /** `realizeAll` off the event loop; `cancel()` still works meanwhile. */
  realizeAllAsync() { return this._async('realizeAllAsync', { op: 'realizeAll' }); }
  // -- writing --
  /**
   * Write the whole scene to `filePath`: `'glb'` (binary glTF), `'gltf'`
   * (text glTF, one file either way) or `'obj'` (Wavefront, every placement
   * baked to its own named object, a `.mtl` beside it under the same stem when
   * anything has a colour). Every placement of every shape, named and placed as
   * the tree is, a material per colour -- where `Node.saveMesh` writes one
   * node's mesh on its own. Coordinates are the scene's own, in the convention
   * it was opened with (`Convention.Y_UP` for the Y-up metres glTF specifies).
   * Throws `CadaclysmError` on any other format or a failed write.
   */
  save(filePath, format = 'glb') {
    if (!_lib().scene_save(this._handle, String(filePath), format)) {
      throw new CadaclysmError(_lastError() || `could not write ${filePath}`);
    }
  }
  async saveAsync(filePath, format = 'glb') { await this._async('saveAsync', { op: 'save', path: String(filePath), format }); }
}

// ---- meshlets ---------------------------------------------------------------

// The same backstop as a scene's: a `Meshlets` the collector reaps unfreed is
// freed then; `free()` is the contract.
const _meshletsFinalizer = typeof FinalizationRegistry === 'function'
  ? new FinalizationRegistry((pointer) => { try { _lib().meshlets_free(pointer); } catch (_) { /* the process is going anyway */ } })
  : null;

/** A mesh split into meshlets, optionally with coarser levels above them. */
class Meshlets {
  constructor(pointer) {
    this._pointer = pointer;
    if (_meshletsFinalizer) _meshletsFinalizer.register(this, pointer, this);
  }
  /**
   * `positions` 3 floats a vertex, `normals` the same or null, `indices` 3 a
   * triangle; `maxTriangles`/`maxVertices` are the consumer's own limits (Nanite
   * 128/256, mesh shaders 124/64); `levels` 0 for one level.
   */
  static build(positions, normals, indices, { maxTriangles, maxVertices, levels = 0 }) {
    if (!(maxTriangles > 0 && maxVertices > 0)) throw new CadaclysmError('meshlets: maxTriangles and maxVertices are required');
    const p = Float32Array.from(positions), i = Uint32Array.from(indices);
    const n = normals == null ? null : Float32Array.from(normals);
    // `vertex_count` is `p.length / 3` as a `size_t`: a stray float would be
    // truncated away silently, and normals of another length read past their end.
    if (p.length % 3 !== 0 || i.length % 3 !== 0) throw new CadaclysmError('meshlets: positions must hold three floats a vertex and indices three a triangle');
    if (n !== null && n.length !== p.length) throw new CadaclysmError('meshlets: normals must hold one per vertex, three floats each');
    const pointer = _lib().meshlets_build(p, n, p.length / 3, i, i.length, maxTriangles, maxVertices, levels);
    if (!pointer) throw new CadaclysmError(_lastError() || 'meshlets: build failed');
    return new Meshlets(pointer);
  }
  get _handle() { if (this._pointer === null) throw new CadaclysmError('meshlets: freed'); return this._pointer; }
  get count() { return _lib().meshlets_count(this._handle); }
  triangleCount(i) { return _lib().meshlet_triangle_count(this._handle, i); }
  vertexCount(i) { return _lib().meshlet_vertex_count(this._handle, i); }
  level(i) { return _lib().meshlet_level(this._handle, i); }
  group(i) { return _lib().meshlet_group(this._handle, i); }
  error(i) { return _lib().meshlet_error(this._handle, i); }
  childCount(i) { return _lib().meshlet_child_count(this._handle, i); }
  /** One meshlet's arrays and numbers, copied out. */
  meshlet(i) {
    const l = _lib(); const h = this._handle;
    const vertexCount = l.meshlet_vertex_count(h, i), triangleCount = l.meshlet_triangle_count(h, i), childCount = l.meshlet_child_count(h, i);
    const positions = new Float32Array(vertexCount * 3), normals = new Float32Array(vertexCount * 3);
    const indices = new Uint32Array(triangleCount * 3), children = new Uint32Array(childCount);
    l.meshlet_positions(h, i, positions); l.meshlet_normals(h, i, normals); l.meshlet_indices(h, i, indices); l.meshlet_children(h, i, children);
    return { index: i, level: l.meshlet_level(h, i), group: l.meshlet_group(h, i), error: l.meshlet_error(h, i), vertexCount, triangleCount, positions, normals, indices, children };
  }
  free() {
    if (this._pointer === null) return;
    const p = this._pointer; this._pointer = null;
    if (_meshletsFinalizer) _meshletsFinalizer.unregister(this);
    _lib().meshlets_free(p);
  }
  [Symbol.for('nodejs.dispose')]() { this.free(); }
}

// ---- the pickers -------------------------------------------------------------

/** The library's own file dialog; null if cancelled or no dialog is available. Blocks. */
function pickFile() { const raw = _lib().pick_file(null); return raw == null ? null : String(raw); }
/** The library's own save dialog; null if cancelled. */
function pickSave(suggestedName = '') { const raw = _lib().pick_save(null, suggestedName); return raw == null ? null : String(raw); }

// ---- opening ----------------------------------------------------------------

/** The schema a STEP or IFC file says it speaks, from its own header; `""` if none. */
function declaredSchema(model) {
  const fd = fs.openSync(model, 'r');
  try {
    const head = Buffer.alloc(8192);
    const n = fs.readSync(fd, head, 0, head.length, 0);
    const m = /FILE_SCHEMA\s*\(\s*\(\s*'([^']+)'/i.exec(head.toString('latin1', 0, n));
    return m ? m[1] : '';
  } finally { fs.closeSync(fd); }
}

function _plain(name) { return name.toUpperCase().replace(/[^A-Z0-9]/g, ''); }

/**
 * `schema` resolved to `{ chosen, fallbacks }`: a file is taken as given; a
 * directory is matched against what the model declares, and where nothing
 * matches every `.exp` in it comes back as fallbacks to try in turn.
 */
function resolveSchema(model, schema) {
  if (schema == null) return { chosen: null, fallbacks: [] };
  schema = String(schema);
  if (!fs.existsSync(schema)) throw new CadaclysmError(`schema ${schema} is neither a file nor a directory`);
  if (fs.statSync(schema).isFile()) return { chosen: schema, fallbacks: [] };
  const available = fs.readdirSync(schema).filter((f) => f.endsWith('.exp')).sort().map((f) => path.join(schema, f));
  if (!available.length) throw new CadaclysmError(`no .exp schemas in ${schema}`);
  const declared = _plain(declaredSchema(model));
  const matches = available.filter((exp) => {
    const stem = _plain(path.basename(exp, '.exp'));
    return declared && (declared.startsWith(stem) || stem.startsWith(declared));
  });
  if (matches.length) {
    return { chosen: matches.reduce((a, b) => (_plain(path.basename(b, '.exp')).length > _plain(path.basename(a, '.exp')).length ? b : a)), fallbacks: [] };
  }
  return { chosen: null, fallbacks: available };
}

/** A `CadaclysmOpenOptions` object from `{ schema, convention, colors, sourceMetersPerUnit }`. */
function _options({ schema = null, convention = Convention.NATIVE, colors = false, sourceMetersPerUnit = 0 } = {}) {
  const o = {};
  _lib().open_options_init(o);
  const packed = Number(convention);
  o.convention = packed & ~(Convention.FILE_UNITS | Convention.UV_WORLD);
  o.file_units = Boolean(packed & Convention.FILE_UNITS);
  o.uvs = packed & Convention.UV_WORLD ? 1 : 0;
  o.colors = colors ? 1 : 0;
  o.source_meters_per_unit = Number(sourceMetersPerUnit);
  if (schema != null) { o.schemas = [String(schema)]; o.schema_count = 1; }
  return o;
}

/** `open`'s work without the `Scene`: `{ pointer, schemaPath }`, or throws. Shared with the worker. */
function _openRaw(filePath, options = {}) {
  filePath = String(filePath);
  if (!fs.existsSync(filePath)) throw new CadaclysmError(`${filePath}: no such file`);
  const l = _lib();
  const { schema = null, ...rest } = options;
  if (schema != null && fs.existsSync(String(schema)) && fs.statSync(String(schema)).isDirectory()) {
    const pointer = l.open(filePath, _options({ ...rest, schema }));
    if (pointer) return { pointer, schemaPath: String(schema) };
    throw new CadaclysmError(`${path.basename(filePath)}: ${_lastError()}`);
  }
  const { chosen, fallbacks } = resolveSchema(filePath, schema);
  const candidates = chosen !== null || !fallbacks.length ? [chosen] : fallbacks;
  for (const candidate of candidates) {
    const pointer = l.open(filePath, _options({ ...rest, schema: candidate }));
    if (pointer) return { pointer, schemaPath: candidate };
  }
  throw new CadaclysmError(`${path.basename(filePath)}: ${_lastError()}`);
}

/**
 * Open a CAD file. `options`: `schema` (an `.exp` file or a directory of them,
 * matched against what the file declares), `convention` (a `Convention`,
 * OR'd with `FILE_UNITS`/`UV_WORLD`), `colors`, `sourceMetersPerUnit`.
 * Throws `CadaclysmError` with the library's reason; never returns null.
 */
function open(filePath, options = {}) {
  const { pointer, schemaPath } = _openRaw(filePath, options);
  return new Scene(pointer, String(filePath), schemaPath, Number(options.convention ?? Convention.NATIVE));
}

/**
 * Open a CAD file already in memory. `format` names the kind as an extension
 * would (`"step"`, `"ifc"`, `"scad"`, ...); `bytes` is a Buffer, Uint8Array,
 * ArrayBuffer or string. `options` as `open`, plus `name` for messages.
 */
function openMemory(bytes, format, options = {}) {
  const { name = '<memory>', ...rest } = options;
  const buffer = typeof bytes === 'string' ? Buffer.from(bytes, 'utf8')
    : bytes instanceof ArrayBuffer ? Buffer.from(bytes) : Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const pointer = _lib().open_memory(buffer, buffer.length, String(format).replace(/^\./, ''), _options(rest));
  if (!pointer) throw new CadaclysmError(`${name}: ${_lastError()}`);
  return new Scene(pointer, name, rest.schema == null ? null : String(rest.schema), Number(rest.convention ?? Convention.NATIVE));
}

// ---- the async twins --------------------------------------------------------------

let _worker = null;
function _run(message, transfer, onProgress) {
  if (!_worker) _worker = require('./worker');
  return _worker.run('reader', message, transfer, onProgress).catch((e) => { throw new CadaclysmError(e.message); });
}

/**
 * The address to hand the worker for `pointer`: itself, if this handle is
 * already a BigInt address (a scene built by a previous async call), else
 * `koffi.address(pointer)`. `koffi.as()` cannot rebuild a real pointer from a
 * raw address -- it only tags an existing value for a call -- so an
 * async-opened `Scene` simply keeps its `_pointer` as the BigInt the worker
 * returned; koffi accepts that directly wherever a pointer argument is due.
 */
function _addressOf(pointer) { return typeof pointer === 'bigint' ? pointer : koffi.address(pointer); }

/** `open`, on a worker thread. */
async function openAsync(filePath, options = {}) {
  filePath = String(filePath);
  if (!fs.existsSync(filePath)) throw new CadaclysmError(`${filePath}: no such file`);
  const { address, schemaPath } = await _run({ op: 'open', path: filePath, options: { ...options, schema: options.schema == null ? null : String(options.schema) } });
  return new Scene(address, filePath, schemaPath, Number(options.convention ?? Convention.NATIVE));
}

/** `openMemory`, on a worker thread; `bytes` is copied to the worker. */
async function openMemoryAsync(bytes, format, options = {}) {
  const { name = '<memory>', ...rest } = options;
  const buffer = typeof bytes === 'string' ? Buffer.from(bytes, 'utf8')
    : bytes instanceof ArrayBuffer ? Buffer.from(bytes) : Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const copy = new Uint8Array(buffer.length); copy.set(buffer);
  let address;
  try {
    ({ address } = await _run({ op: 'openMemory', bytes: copy, format: String(format).replace(/^\./, ''), options: { ...rest, schema: rest.schema == null ? null : String(rest.schema) } }, [copy.buffer]));
  } catch (e) { throw new CadaclysmError(`${name}: ${e.message}`); }
  return new Scene(address, name, rest.schema == null ? null : String(rest.schema), Number(rest.convention ?? Convention.NATIVE));
}

module.exports = {
  CadaclysmError, NONE, Convention, ValueKind,
  libraryPath, version, buildDate, license, licenseInfo, licenseNoticeCount, meshFormats, formats, lodLevels,
  _lib, _text, _lastError, _floats, _uint32s, _searchedPaths, _notFoundMessage,
  Bounds, Attribute, Placement, Node, Scene, open, openMemory, _openRaw, openAsync, openMemoryAsync, declaredSchema, resolveSchema, _options, _rows, _attribute,
  Mesh, Polylines, Beziers, Face, Surfaces, Collision, CollisionHull, Meshlets, pickFile, pickSave,
  _meshOf, _polylinesOf, _beziersOf, _surfacesOf,
};
