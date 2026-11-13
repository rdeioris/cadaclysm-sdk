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
// `using x = ...` looks up Symbol.dispose: Node 22 aliases it to Symbol.for('nodejs.dispose'),
// a V8 with its own Symbol.dispose does not, so name the one this runtime uses.
const DISPOSE = typeof Symbol.dispose === 'symbol' ? Symbol.dispose : Symbol.for('nodejs.dispose');

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

/**
 * The libraries that carry the node API, in the order they are looked for: the single
 * library's flavours that hold it, then the separate library of earlier releases.
 * As `cadaclysm-capi-rt`'s `READER_STEMS`.
 */
const LIBRARY_STEMS = ['cadaclysm', 'cadaclysm_kernel_reader', 'cadaclysm_reader', 'cadaclysm_capi'];

/** `LIBRARY_STEMS` as this platform names the files. */
function libraryNames() {
  if (process.platform === 'win32') return LIBRARY_STEMS.map((s) => `${s}.dll`);
  const suffix = process.platform === 'darwin' ? 'dylib' : 'so';
  return LIBRARY_STEMS.map((s) => `lib${s}.${suffix}`);
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
  const here = __dirname;
  const places = [here];
  // An SDK checkout keeps the library in `lib/` beside the wrappers; the
  // repository this example ships in keeps it in `target/release` (or
  // `target/debug`, a fallback for a machine that only built that).
  for (const a of ancestors(here)) places.push(path.join(a, 'lib'));
  for (const a of ancestors(here)) places.push(path.join(a, 'target', 'release'), path.join(a, 'target', 'debug'));
  // Each place is asked for every name, in order: one library of any flavour
  // that holds the node API, else the separate library of earlier releases.
  return places.flatMap((place) => libraryNames().map((name) => path.join(place, name)));
}

function _notFoundMessage(searched) {
  return `none of ${libraryNames().join(', ')} found. Looked in:\n` + searched.map((p) => `    ${p}\n`).join('')
    + 'Build it with:\n    cargo build --release -p cadaclysm-capi\n'
    + 'or run fetch.py in an SDK checkout, or point CADACLYSM_LIBRARY at it.';
}

/**
 * Where the shared library is, preferring a release build over a debug one.
 * `CADACLYSM_LIBRARY` first (a file, or a directory holding it), then beside
 * this file, then `lib/` in any ancestor (the SDK layout), then `target/release`
 * or `target/debug` in any ancestor (this repository's layout). Each place is
 * asked for every name in `LIBRARY_STEMS`, in order.
 */
function libraryPath() {
  const override = process.env.CADACLYSM_LIBRARY;
  if (override) {
    if (fs.existsSync(override) && fs.statSync(override).isDirectory()) {
      for (const name of libraryNames()) if (fs.existsSync(path.join(override, name))) return path.join(override, name);
    } else if (fs.existsSync(override)) {
      return override;
    }
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
koffi.opaque('CadaclysmBrep');
koffi.opaque('CadaclysmMeshlets');
koffi.opaque('CadaclysmFemMesh');
koffi.opaque('CadaclysmPose');
koffi.opaque('CadaclysmHealth');
koffi.opaque('CadaclysmHeal');
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
// f64 twins (Task 11 of the f64-twins plan): CadaclysmMesh64/CadaclysmBeziers64/
// CadaclysmBounds64, beside CadaclysmBounds, in the header's field order.
const CadaclysmMesh64 = koffi.struct('CadaclysmMesh64', {
  positions: 'const double *',
  normals: 'const double *',
  uvs: 'const double *',
  colors: 'const float *',
  indices: 'const uint32_t *',
  vertex_count: 'uint32_t',
  index_count: 'uint32_t',
});
const CadaclysmBeziers64 = koffi.struct('CadaclysmBeziers64', {
  points: 'const double *',
  weights: 'const double *',
  count: 'uint32_t',
});
const CadaclysmBounds64 = koffi.struct('CadaclysmBounds64', {
  min: koffi.array('double', 3),
  max: koffi.array('double', 3),
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
const CadaclysmEdgeColors = koffi.struct('CadaclysmEdgeColors', {
  rgba: 'const float *',
  count: 'uint32_t',
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
  shared: 'const uint32_t *',
  shared_count: 'uint32_t',
  duplicate: 'const uint32_t *',
  duplicate_count: 'uint32_t',
});
const CadaclysmSvgOptions = koffi.struct('CadaclysmSvgOptions', {
  size: 'uint32_t',
  up: 'uint32_t',
  azimuth: 'double',
  elevation: 'double',
  fov: 'double',
  width: 'double',
  height: 'double',
  margin: 'double',
  tolerance: 'double',
  stroke_width: 'double',
  stroke: 'uint32_t',
  background: 'uint32_t',
  flags: 'uint32_t',
});
// The FEM surface mesh. `size` is how `CadaclysmFemOptions` grows, by
// `CadaclysmOpenOptions`'s rule: `cadaclysm_fem_options_init` fills the library's
// whole struct, and `femMesh` then writes this declaration's own `sizeof` into
// `size`, so a field the library has and this block does not is written past what
// the call reads. `tests/bindings.rs` pins all four of the structs below field for
// field, widths included, which is what keeps that rule honest.
const CadaclysmFemOptions = koffi.struct('CadaclysmFemOptions', {
  size: 'size_t',
  tolerance: 'double',
  max_size: 'double',
});
const CadaclysmFemMeshView = koffi.struct('CadaclysmFemMeshView', {
  nodes: 'const double *',
  node_count: 'uint32_t',
  triangles: 'const uint32_t *',
  triangle_count: 'uint32_t',
  triangle_face: 'const uint32_t *',
  node_kind: 'const uint32_t *',
  node_entity: 'const uint32_t *',
  face_count: 'uint32_t',
  edge_count: 'uint32_t',
  vertex_count: 'uint32_t',
  open_edge_count: 'uint32_t',
  folded_edge_count: 'uint32_t',
  watertight: 'bool',
  from_mesh: 'bool',
  min_angle: 'double',
  worst_triangle: 'uint32_t',
  longest_edge: 'double',
});
const CadaclysmFemEdge = koffi.struct('CadaclysmFemEdge', {
  id: 'uint32_t',
  nodes: 'const uint32_t *',
  node_count: 'uint32_t',
  runs: 'const uint32_t *',
  run_count: 'uint32_t',
  face_a: 'uint32_t',
  face_b: 'uint32_t',
  end_a: 'uint32_t',
  end_b: 'uint32_t',
  closed: 'bool',
  seam: 'bool',
});
const CadaclysmFemVertex = koffi.struct('CadaclysmFemVertex', {
  node: 'uint32_t',
  point: koffi.array('double', 3),
  has_position: 'bool',
});
// One of a pair's degrees of freedom (kinematic pairs, states -- task 6): which
// motion, about or along which contact-frame axis, and its optional range.
const CadaclysmFreedom = koffi.struct('CadaclysmFreedom', {
  motion: 'uint32_t',
  axis: 'uint32_t',
  has_lower: 'bool',
  lower: 'double',
  has_upper: 'bool',
  upper: 'double',
});
// Every date pair of a task (IFC work schedules): each `has_*` says its value is given.
const CadaclysmTaskTime = koffi.struct('CadaclysmTaskTime', {
  has_schedule_start: 'bool',
  schedule_start: 'double',
  has_schedule_finish: 'bool',
  schedule_finish: 'double',
  has_early_start: 'bool',
  early_start: 'double',
  has_early_finish: 'bool',
  early_finish: 'double',
  has_late_start: 'bool',
  late_start: 'double',
  has_late_finish: 'bool',
  late_finish: 'double',
  has_actual_start: 'bool',
  actual_start: 'double',
  has_actual_finish: 'bool',
  actual_finish: 'double',
  has_duration: 'bool',
  duration: 'double',
});
// One element's state on a date: `cadaclysm_schedule_at`'s rows.
const CadaclysmElementState = koffi.struct('CadaclysmElementState', {
  node: 'uint32_t',
  phase: 'uint32_t',
  progress: 'double',
  has_variance: 'bool',
  variance: 'double',
});

// ---- the function table ----------------------------------------------------

let library = null;
/** `[flavour, features]` of the loaded library; see `flavour()`. */
let _flavour = ['', ''];

/**
 * `[flavour, features]` for one of the single library's flavours, or `null` for a
 * separate library of an earlier release, which exports neither call.
 */
function _flavourOf(l) {
  try {
    return [l.func('const char *cadaclysm_flavour(void)')(), l.func('const char *cadaclysm_features(void)')()];
  } catch (e) {
    if (/^Cannot find function /.test(e.message)) return null;
    throw e;
  }
}

/**
 * `l.func(proto)`. On a flavour that leaves the function out, a function that
 * throws naming the flavour -- when called, not at load. A separate library of an
 * earlier release must have every function, as before (koffi's own error).
 */
function _bind(l, proto, flavoured) {
  try {
    return l.func(proto);
  } catch (e) {
    if (!flavoured || !/^Cannot find function /.test(e.message)) throw e;
    const name = /(\w+)\s*\(/.exec(proto)[1].replace(/^cadaclysm_(blacksmith_)?/, '');
    const [flavour, features] = flavoured;
    return () => {
      throw new CadaclysmError(`${name}: not in this library's flavour ('${flavour}', features ${features || 'none'}); the full flavour has it`);
    };
  }
}

/**
 * The loaded library's functions, loading on first use. A flavour of the single
 * library binds what it has: a function it leaves out throws naming the flavour,
 * when called. A flavour with no node API (the kernel flavour) is refused here.
 */
function _lib() {
  if (library) return library;
  const found = libraryPath();
  const l = koffi.load(found);
  const flavoured = _flavourOf(l);
  if (flavoured && !flavoured[1].split(',').includes('nodes')) {
    throw new CadaclysmError(`${found}: the '${flavoured[0]}' flavour has no node API; load cadaclysm, cadaclysm_kernel_reader or cadaclysm_reader`);
  }
  const f = (proto) => _bind(l, proto, flavoured);
  library = {
    last_error: f('const char *cadaclysm_last_error(void)'),
    version: f('const char *cadaclysm_version(void)'),
    open: f('CadaclysmScene *cadaclysm_open(const char *path, const CadaclysmOpenOptions *options)'),
    open_memory: f('CadaclysmScene *cadaclysm_open_memory(const uint8_t *bytes, size_t length, const char *format, const CadaclysmOpenOptions *options)'),
    open_options_init: f('void cadaclysm_open_options_init(_Out_ CadaclysmOpenOptions *options)'),
    close: f('void cadaclysm_close(CadaclysmScene *scene)'),
    node_brep: f('CadaclysmBrep *cadaclysm_node_brep(const CadaclysmScene *scene, uint32_t node)'),
    brep_release: f('void cadaclysm_brep_release(const CadaclysmBrep *brep)'),
    brep_layout_id: f('const char *cadaclysm_brep_layout_id(void)'),
    brep_manifold: f('bool cadaclysm_brep_manifold(const CadaclysmBrep *brep, _Out_ uint32_t *out)'),
    brep_sew: f('CadaclysmBrep *cadaclysm_brep_sew(const CadaclysmBrep *brep, double tolerance, double vertex, _Out_ uint32_t *out, _Out_ double *gaps)'),
    brep_health: f('CadaclysmHealth *cadaclysm_brep_health(const CadaclysmBrep *brep, double tolerance, bool mesh)'),
    brep_health_free: f('void cadaclysm_brep_health_free(CadaclysmHealth *health)'),
    brep_health_summary: f('bool cadaclysm_brep_health_summary(const CadaclysmHealth *health, _Out_ uint32_t *counts, _Out_ double *sizes)'),
    brep_health_free_edges: f('uint32_t cadaclysm_brep_health_free_edges(const CadaclysmHealth *health, _Out_ uint32_t *ids, _Out_ double *sizes)'),
    brep_health_wires: f('uint32_t cadaclysm_brep_health_wires(const CadaclysmHealth *health, _Out_ uint32_t *runs, _Out_ double *sizes)'),
    brep_health_small: f('uint32_t cadaclysm_brep_health_small(const CadaclysmHealth *health, _Out_ uint32_t *items, _Out_ double *sizes)'),
    brep_health_crack_edges: f('uint32_t cadaclysm_brep_health_crack_edges(const CadaclysmHealth *health, _Out_ uint32_t *ids)'),
    brep_healed: f('CadaclysmHeal *cadaclysm_brep_healed(const CadaclysmBrep *brep, double tolerance, uint32_t flags)'),
    brep_heal_body: f('const CadaclysmBrep *cadaclysm_brep_heal_body(const CadaclysmHeal *h)'),
    brep_heal_free: f('void cadaclysm_brep_heal_free(CadaclysmHeal *h)'),
    brep_heal_summary: f('bool cadaclysm_brep_heal_summary(const CadaclysmHeal *h, _Out_ uint32_t *counts, _Out_ double *sizes)'),
    brep_heal_fixes: f('uint32_t cadaclysm_brep_heal_fixes(const CadaclysmHeal *h, _Out_ uint32_t *items, _Out_ double *sizes)'),
    brep_heal_refused: f('uint32_t cadaclysm_brep_heal_refused(const CadaclysmHeal *h, _Out_ uint32_t *items, _Out_ double *sizes)'),
    brep_edge_tolerance: f('double cadaclysm_brep_edge_tolerance(const CadaclysmBrep *brep, uint32_t edge)'),
    node_count: f('uint32_t cadaclysm_node_count(const CadaclysmScene *scene)'),
    root_count: f('uint32_t cadaclysm_root_count(const CadaclysmScene *scene)'),
    root: f('uint32_t cadaclysm_root(const CadaclysmScene *scene, uint32_t index)'),
    schema: f('const char *cadaclysm_schema(const CadaclysmScene *scene)'),
    schema_read: f('const char *cadaclysm_schema_read(const CadaclysmScene *scene)'),
    metres_per_unit: f('double cadaclysm_metres_per_unit(const CadaclysmScene *scene)'),
    tolerances: f('bool cadaclysm_tolerances(const CadaclysmScene *scene, _Out_ double *absolute, _Out_ double *angular)'),
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
    node_bounds_placed: f('CadaclysmBounds cadaclysm_node_bounds_placed(const CadaclysmScene *scene, uint32_t node, const double *placement)'),
    // f64 twins (Task 11): the document's own double mesh and Béziers, and bounds
    // exact far from the origin -- see the doc comments on `mesh64`/`bounds64` below.
    node_mesh64: f('CadaclysmMesh64 cadaclysm_node_mesh64(const CadaclysmScene *scene, uint32_t node)'),
    node_edge_beziers64: f('CadaclysmBeziers64 cadaclysm_node_edge_beziers64(const CadaclysmScene *scene, uint32_t node)'),
    node_curve_beziers64: f('CadaclysmBeziers64 cadaclysm_node_curve_beziers64(const CadaclysmScene *scene, uint32_t node)'),
    node_isocurve_beziers64: f('CadaclysmBeziers64 cadaclysm_node_isocurve_beziers64(const CadaclysmScene *scene, uint32_t node)'),
    node_bounds64: f('CadaclysmBounds64 cadaclysm_node_bounds64(const CadaclysmScene *scene, uint32_t node)'),
    node_bounds_placed64: f('CadaclysmBounds64 cadaclysm_node_bounds_placed64(const CadaclysmScene *scene, uint32_t node, const double *placement)'),
    bounds64: f('CadaclysmBounds64 cadaclysm_bounds64(const CadaclysmScene *scene)'),
    node_is_meshed: f('bool cadaclysm_node_is_meshed(const CadaclysmScene *scene, uint32_t node)'),
    node_surface_edges: f('CadaclysmPolylines cadaclysm_node_surface_edges(const CadaclysmScene *scene, uint32_t node)'),
    node_surface_edge_beziers: f('CadaclysmBeziers cadaclysm_node_surface_edge_beziers(const CadaclysmScene *scene, uint32_t node)'),
    node_surface_isocurves: f('CadaclysmPolylines cadaclysm_node_surface_isocurves(const CadaclysmScene *scene, uint32_t node)'),
    node_surface_pick: f('bool cadaclysm_node_surface_pick(const CadaclysmScene *scene, uint32_t node, const double *from, const double *to, _Out_ double *out_point)'),
    node_surface_proxy_mesh: f('CadaclysmMesh cadaclysm_node_surface_proxy_mesh(const CadaclysmScene *scene, uint32_t node, uint32_t cells)'),
    node_triangle_estimate: f('int64_t cadaclysm_node_triangle_estimate(const CadaclysmScene *scene, uint32_t node)'),
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
    node_edge_colors: f('CadaclysmEdgeColors cadaclysm_node_edge_colors(const CadaclysmScene *scene, uint32_t node)'),
    node_surface_edge_colors: f('CadaclysmEdgeColors cadaclysm_node_surface_edge_colors(const CadaclysmScene *scene, uint32_t node)'),
    node_edge_beziers: f('CadaclysmBeziers cadaclysm_node_edge_beziers(const CadaclysmScene *scene, uint32_t node)'),
    node_surfaces: f('CadaclysmSurfaces cadaclysm_node_surfaces(const CadaclysmScene *scene, uint32_t node)'),
    surface_matrix: f('void cadaclysm_surface_matrix(const CadaclysmScene *scene, _Out_ float *out)'),
    node_curve_beziers: f('CadaclysmBeziers cadaclysm_node_curve_beziers(const CadaclysmScene *scene, uint32_t node)'),
    node_isocurve_beziers: f('CadaclysmBeziers cadaclysm_node_isocurve_beziers(const CadaclysmScene *scene, uint32_t node)'),
    node_curves: f('CadaclysmPolylines cadaclysm_node_curves(const CadaclysmScene *scene, uint32_t node)'),
    node_isocurves: f('CadaclysmPolylines cadaclysm_node_isocurves(const CadaclysmScene *scene, uint32_t node)'),
    forget_meshes: f('void cadaclysm_forget_meshes(CadaclysmScene *scene)'),
    realize_all: f('uint32_t cadaclysm_realize_all(const CadaclysmScene *scene)'),
    realize_meshes: f('uint32_t cadaclysm_realize_meshes(const CadaclysmScene *scene, uint32_t skip_surfaced)'),
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
    svg_options_init: f('void cadaclysm_svg_options_init(_Out_ CadaclysmSvgOptions *options)'),
    scene_svg_text: f('const char *cadaclysm_scene_svg_text(const CadaclysmScene *scene, const CadaclysmSvgOptions *options)'),
    scene_svg: f('bool cadaclysm_scene_svg(const CadaclysmScene *scene, const char *path, const CadaclysmSvgOptions *options)'),
    node_svg_text: f('const char *cadaclysm_node_svg_text(const CadaclysmScene *scene, uint32_t node, const CadaclysmSvgOptions *options)'),
    node_svg: f('bool cadaclysm_node_svg(const CadaclysmScene *scene, uint32_t node, const char *path, const CadaclysmSvgOptions *options)'),
    // BORROWED into a per-scene slot that the next silhouette call on that scene replaces.
    node_silhouette_beziers: f('CadaclysmBeziers64 cadaclysm_node_silhouette_beziers(const CadaclysmScene *scene, uint32_t node, const CadaclysmSvgOptions *options)'),
    source_name: f('const char *cadaclysm_source_name(const CadaclysmScene *scene)'),
    pick_file: f('const char *cadaclysm_pick_file(const CadaclysmWindow *parent)'),
    pick_save: f('const char *cadaclysm_pick_save(const CadaclysmWindow *parent, const char *suggested_name)'),
    parse_colour: f('bool cadaclysm_parse_colour(const char *text, _Out_ double *out)'),
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
    link_count: f('uint32_t cadaclysm_link_count(const CadaclysmScene *scene)'),
    link_name: f('const char *cadaclysm_link_name(const CadaclysmScene *scene, uint32_t link)'),
    link_node_count: f('uint32_t cadaclysm_link_node_count(const CadaclysmScene *scene, uint32_t link)'),
    link_node: f('uint32_t cadaclysm_link_node(const CadaclysmScene *scene, uint32_t link, uint32_t index)'),
    joint_count: f('uint32_t cadaclysm_joint_count(const CadaclysmScene *scene)'),
    joint_name: f('const char *cadaclysm_joint_name(const CadaclysmScene *scene, uint32_t joint)'),
    joint_start: f('uint32_t cadaclysm_joint_start(const CadaclysmScene *scene, uint32_t joint)'),
    joint_end: f('uint32_t cadaclysm_joint_end(const CadaclysmScene *scene, uint32_t joint)'),
    // Kinematic pairs, freedoms and mechanism states (task 6): how a joint moves, and
    // the named poses a file records.
    joint_pair_kind: f('int32_t cadaclysm_joint_pair_kind(const CadaclysmScene *scene, uint32_t joint)'),
    joint_pair_type: f('const char *cadaclysm_joint_pair_type(const CadaclysmScene *scene, uint32_t joint)'),
    joint_pair_kind_name: f('const char *cadaclysm_joint_pair_kind_name(const CadaclysmScene *scene, uint32_t joint)'),
    joint_pair_parameters: f('size_t cadaclysm_joint_pair_parameters(const CadaclysmScene *scene, uint32_t joint, _Out_ double *out, size_t capacity)'),
    joint_pair_pitch: f('double cadaclysm_joint_pair_pitch(const CadaclysmScene *scene, uint32_t joint)'),
    joint_pair_frames: f('bool cadaclysm_joint_pair_frames(const CadaclysmScene *scene, uint32_t joint, _Out_ double *out_start, _Out_ double *out_end)'),
    joint_freedom_count: f('uint32_t cadaclysm_joint_freedom_count(const CadaclysmScene *scene, uint32_t joint)'),
    joint_freedom: f('bool cadaclysm_joint_freedom(const CadaclysmScene *scene, uint32_t joint, uint32_t index, _Out_ CadaclysmFreedom *out)'),
    state_count: f('uint32_t cadaclysm_state_count(const CadaclysmScene *scene)'),
    state_name: f('const char *cadaclysm_state_name(const CadaclysmScene *scene, uint32_t state)'),
    state_value_count: f('uint32_t cadaclysm_state_value_count(const CadaclysmScene *scene, uint32_t state)'),
    state_value: f('uint32_t cadaclysm_state_value(const CadaclysmScene *scene, uint32_t state, uint32_t row, _Out_ uint32_t *joint, _Out_ double *values, uint32_t capacity)'),
    // Mechanism posing (posing plan 2): a scene posed by explicit values or by a
    // named state, copied eagerly into a wrapper Pose and freed -- see _copyPose.
    kinematics_base: f('uint32_t cadaclysm_kinematics_base(const CadaclysmScene *scene)'),
    pose: f('CadaclysmPose *cadaclysm_pose(const CadaclysmScene *scene, const uint32_t *joints, const uint32_t *counts, const double *values, uint32_t row_count, uint32_t ground)'),
    pose_state: f('CadaclysmPose *cadaclysm_pose_state(const CadaclysmScene *scene, uint32_t state, uint32_t ground)'),
    // Motion sequences: the file's INTERPOLATED_CONFIGURATION_SEQUENCEs, and a scene posed at a
    // parameter of one (copied eagerly into a wrapper Pose like `pose_state`).
    sequence_count: f('uint32_t cadaclysm_sequence_count(const CadaclysmScene *scene)'),
    sequence_name: f('const char *cadaclysm_sequence_name(const CadaclysmScene *scene, uint32_t sequence)'),
    sequence_closed: f('bool cadaclysm_sequence_closed(const CadaclysmScene *scene, uint32_t sequence)'),
    sequence_seconds_per_unit: f('double cadaclysm_sequence_seconds_per_unit(const CadaclysmScene *scene, uint32_t sequence)'),
    sequence_segment_count: f('uint32_t cadaclysm_sequence_segment_count(const CadaclysmScene *scene, uint32_t sequence)'),
    sequence_segment: f('bool cadaclysm_sequence_segment(const CadaclysmScene *scene, uint32_t sequence, uint32_t segment, _Out_ uint32_t *state, _Out_ double *t, _Out_ uint32_t *interpolation)'),
    // IFC work schedules: the programme a file records, its tasks and links, and the
    // elements' states on a date (`cadaclysm_schedule_at` fills `CadaclysmElementState` rows).
    schedule_count: f('uint32_t cadaclysm_schedule_count(const CadaclysmScene *scene)'),
    schedule_name: f('const char *cadaclysm_schedule_name(const CadaclysmScene *scene, uint32_t s)'),
    schedule_identification: f('const char *cadaclysm_schedule_identification(const CadaclysmScene *scene, uint32_t s)'),
    schedule_kind: f('uint32_t cadaclysm_schedule_kind(const CadaclysmScene *scene, uint32_t s)'),
    schedule_kind_name: f('const char *cadaclysm_schedule_kind_name(const CadaclysmScene *scene, uint32_t s)'),
    schedule_start: f('bool cadaclysm_schedule_start(const CadaclysmScene *scene, uint32_t s, _Out_ double *out)'),
    schedule_finish: f('bool cadaclysm_schedule_finish(const CadaclysmScene *scene, uint32_t s, _Out_ double *out)'),
    task_count: f('uint32_t cadaclysm_task_count(const CadaclysmScene *scene, uint32_t s)'),
    task_name: f('const char *cadaclysm_task_name(const CadaclysmScene *scene, uint32_t s, uint32_t t)'),
    task_identification: f('const char *cadaclysm_task_identification(const CadaclysmScene *scene, uint32_t s, uint32_t t)'),
    task_kind: f('uint32_t cadaclysm_task_kind(const CadaclysmScene *scene, uint32_t s, uint32_t t)'),
    task_kind_name: f('const char *cadaclysm_task_kind_name(const CadaclysmScene *scene, uint32_t s, uint32_t t)'),
    task_status: f('const char *cadaclysm_task_status(const CadaclysmScene *scene, uint32_t s, uint32_t t)'),
    task_milestone: f('bool cadaclysm_task_milestone(const CadaclysmScene *scene, uint32_t s, uint32_t t)'),
    task_parent: f('bool cadaclysm_task_parent(const CadaclysmScene *scene, uint32_t s, uint32_t t, _Out_ uint32_t *out)'),
    task_time: f('bool cadaclysm_task_time(const CadaclysmScene *scene, uint32_t s, uint32_t t, _Out_ CadaclysmTaskTime *out)'),
    task_node_count: f('uint32_t cadaclysm_task_node_count(const CadaclysmScene *scene, uint32_t s, uint32_t t)'),
    task_nodes: f('uint32_t cadaclysm_task_nodes(const CadaclysmScene *scene, uint32_t s, uint32_t t, _Out_ uint32_t *out, uint32_t capacity)'),
    task_link_count: f('uint32_t cadaclysm_task_link_count(const CadaclysmScene *scene, uint32_t s)'),
    task_link: f('bool cadaclysm_task_link(const CadaclysmScene *scene, uint32_t s, uint32_t l, _Out_ uint32_t *from, _Out_ uint32_t *to, _Out_ uint32_t *kind, _Out_ double *lag, _Out_ bool *has_lag)'),
    task_link_kind_name: f('const char *cadaclysm_task_link_kind_name(const CadaclysmScene *scene, uint32_t s, uint32_t l)'),
    schedule_at: f('int64_t cadaclysm_schedule_at(const CadaclysmScene *scene, uint32_t s, double date, uint32_t dates, CadaclysmElementState *out, uint32_t capacity)'),
    pose_sequence: f('CadaclysmPose *cadaclysm_pose_sequence(const CadaclysmScene *scene, uint32_t sequence, double t, uint32_t ground)'),
    pose_free: f('void cadaclysm_pose_free(CadaclysmPose *pose)'),
    pose_ground: f('uint32_t cadaclysm_pose_ground(const CadaclysmPose *pose)'),
    pose_node_count: f('uint32_t cadaclysm_pose_node_count(const CadaclysmPose *pose)'),
    pose_node_transform: f('void cadaclysm_pose_node_transform(const CadaclysmPose *pose, uint32_t node, _Out_ double *out)'),
    pose_unsolved_count: f('uint32_t cadaclysm_pose_unsolved_count(const CadaclysmPose *pose)'),
    pose_diagnostic_count: f('uint32_t cadaclysm_pose_diagnostic_count(const CadaclysmPose *pose)'),
    pose_diagnostic: f('const char *cadaclysm_pose_diagnostic(const CadaclysmPose *pose, uint32_t index)'),
    pose_unsolved: f('uint32_t cadaclysm_pose_unsolved(const CadaclysmPose *pose, uint32_t index)'),
    pose_out_of_range_count: f('uint32_t cadaclysm_pose_out_of_range_count(const CadaclysmPose *pose)'),
    pose_out_of_range: f('bool cadaclysm_pose_out_of_range(const CadaclysmPose *pose, uint32_t index, _Out_ uint32_t *joint, _Out_ uint32_t *freedom, _Out_ double *value)'),
    // The FEM surface mesh: a handle of the caller's own, and its accessors.
    // `cadaclysm_fem_mesh_msh_text` returns a `const char *` **borrowed** from the
    // handle -- a slot replaced by the next ask and gone when the mesh is freed --
    // where the kernel library's twin returns an owned `char *` its wrapper has to
    // release. koffi decodes a `const char *` into a JS string of its own on the
    // way out, so nothing here frees anything and the borrowed slot's lifetime
    // cannot be got wrong; see `FemMesh.mshText`.
    fem_options_init: f('void cadaclysm_fem_options_init(_Out_ CadaclysmFemOptions *options)'),
    node_fem_mesh: f('CadaclysmFemMesh *cadaclysm_node_fem_mesh(const CadaclysmScene *scene, uint32_t node, const double *placement, const CadaclysmFemOptions *options)'),
    fem_mesh_free: f('void cadaclysm_fem_mesh_free(CadaclysmFemMesh *m)'),
    fem_mesh_view: f('bool cadaclysm_fem_mesh_view(const CadaclysmFemMesh *m, _Out_ CadaclysmFemMeshView *out)'),
    fem_mesh_edge: f('bool cadaclysm_fem_mesh_edge(const CadaclysmFemMesh *m, uint32_t i, _Out_ CadaclysmFemEdge *out)'),
    fem_mesh_vertex: f('bool cadaclysm_fem_mesh_vertex(const CadaclysmFemMesh *m, uint32_t i, _Out_ CadaclysmFemVertex *out)'),
    fem_mesh_open_edge: f('bool cadaclysm_fem_mesh_open_edge(const CadaclysmFemMesh *m, uint32_t i, _Out_ uint32_t *a, _Out_ uint32_t *b, _Out_ uint32_t *brep_edge)'),
    fem_mesh_folded_edge: f('bool cadaclysm_fem_mesh_folded_edge(const CadaclysmFemMesh *m, uint32_t i, _Out_ uint32_t *a, _Out_ uint32_t *b, _Out_ uint32_t *brep_edge)'),
    fem_mesh_crossing_count: f('uint32_t cadaclysm_fem_mesh_crossing_count(const CadaclysmFemMesh *m)'),
    fem_mesh_crossing: f('bool cadaclysm_fem_mesh_crossing(const CadaclysmFemMesh *m, uint32_t i, _Out_ uint32_t *a, _Out_ uint32_t *b)'),
    fem_mesh_msh_text: f('const char *cadaclysm_fem_mesh_msh_text(const CadaclysmFemMesh *m)'),
    fem_mesh_save_msh: f('bool cadaclysm_fem_mesh_save_msh(const CadaclysmFemMesh *m, const char *path)'),
  };
  _flavour = flavoured || ['reader', ''];
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
/**
 * `n` uint32s at `ptr` as a fresh `Uint32Array`, or `null` for a null pointer.
 *
 * A typed array in hand is handed straight back, as the kernel module's twin does
 * for its wasm backend: here that is what lets `test/fem.test.js` push a C record
 * built by hand through `_femEdgeOf`, the run arithmetic being reachable by no
 * fixture in this repository.
 */
function _uint32s(ptr, n) {
  if (ptr == null) return null;
  if (ArrayBuffer.isView(ptr)) return ptr;
  return n === 0 ? new Uint32Array(0) : koffi.decode(ptr, 'uint32_t', n);
}
/** `n` doubles at `ptr` as a fresh `Float64Array`, or `null` for a null pointer -- the f64 twin of `_floats`. */
function _doubles(ptr, n) {
  if (ptr == null) return null;
  if (ArrayBuffer.isView(ptr)) return ptr;
  return n === 0 ? new Float64Array(0) : koffi.decode(ptr, 'double', n);
}

// ---- module-level functions --------------------------------------------------

/**
 * Which library this is: `'full'`, `'kernel-reader'` or `'reader'` for a flavour
 * of the single library, `'reader'` for the separate `cadaclysm_capi` of earlier
 * releases.
 */
function flavour() { _lib(); return _flavour[0]; }

/**
 * The features the library was built with, comma-separated (`'nodes,kernel,bim'`),
 * or `''` for the separate `cadaclysm_capi` of earlier releases.
 */
function features() { _lib(); return _flavour[1]; }

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

/** `Bounds` in `double`: the same box, unnarrowed -- exact far from the origin, where `Bounds`'s widened `float` is not. */
class Bounds64 {
  constructor(min, max) {
    this.min = Float64Array.from(min);
    this.max = Float64Array.from(max);
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

/**
 * `Mesh` in `double`: the document's own mesh -- positions/normals/uvs are the exact
 * f64 values `mesh()`'s `float` ones are narrowed from, same indices -- copied out at
 * call time, as `mesh()`'s `Float32Array`s are. Like `mesh()`'s copy, it survives
 * `Scene.forgetMeshes()` and `Scene.close()`. Colours stay `Float32Array`: RGBA in 0..1
 * needs no more precision, as `CadaclysmMesh64` says.
 */
class Mesh64 {
  constructor(positions, normals, uvs, colors, indices, vertexCount, indexCount) {
    this.positions = positions; this.normals = normals; this.uvs = uvs; this.colors = colors;
    this.indices = indices; this.vertexCount = vertexCount; this.indexCount = indexCount;
  }
  get triangleCount() { return Math.floor(this.indexCount / 3); }
}

/** A `CadaclysmMesh64` (by value) as a `Mesh64`. */
function _mesh64Of(raw) {
  const n = raw.vertex_count;
  return new Mesh64(
    _doubles(raw.positions, n * 3) ?? new Float64Array(0),
    _doubles(raw.normals, n * 3),
    _doubles(raw.uvs, n * 2),
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

/** A `CadaclysmEdgeColors` as `(number[] | null)[]`, one RGBA (or null, unstyled) per polyline. */
function _edgeColoursOf(raw) {
  if (!raw.rgba || !raw.count) return [];
  const f = _floats(raw.rgba, raw.count * 4);
  const out = [];
  for (let i = 0; i < raw.count; i++) out.push(f[4 * i + 3] < 0 ? null : Array.from(f.slice(4 * i, 4 * i + 4)));
  return out;
}

/** Rational cubic Bezier segments: 4 control points x 3 floats each, and 4 weights, per segment. */
class Beziers {
  constructor(points, weights, count) { this.points = points; this.weights = weights; this.count = count; }
}

function _beziersOf(raw) {
  return new Beziers(_floats(raw.points, raw.count * 12) ?? new Float32Array(0), _floats(raw.weights, raw.count * 4) ?? new Float32Array(0), raw.count);
}

/** `Beziers` in `double`: the same segments, unnarrowed -- see `edgeBeziers64`/`curveBeziers64`/`isocurveBeziers64`. */
class Beziers64 { constructor(points, weights, count) { this.points = points; this.weights = weights; this.count = count; } }

function _beziers64Of(raw) {
  return new Beziers64(_doubles(raw.points, raw.count * 12) ?? new Float64Array(0), _doubles(raw.weights, raw.count * 4) ?? new Float64Array(0), raw.count);
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

// ---- svg ----------------------------------------------------------------------

/** `CadaclysmSvgOptions.background`'s "none" value: no `<rect>` behind the drawing. */
const SVG_TRANSPARENT = 0xFFFFFFFF;

/**
 * The seven camera angles `SvgOptions.view` understands, degrees
 * `[azimuth, elevation]` -- the same table `cadaclysm_view.VIEWS` gives
 * Python's `show()` and `svg()` both.
 */
const SvgView = Object.freeze({
  front: Object.freeze([-90, 0]), back: Object.freeze([90, 0]), left: Object.freeze([180, 0]), right: Object.freeze([0, 0]),
  top: Object.freeze([-90, 90]), bottom: Object.freeze([-90, -90]), iso: Object.freeze([-50, 28]),
});

/** [r, g, b] in 0..1 from colour text -- '#rgb', '#rrggbb' or a CSS colour name -- read by the
 *  library's own parser; null if it refused the text. */
function _colourText(text) {
  const out = new Float64Array(3);
  return _lib().parse_colour(String(text), out) ? Array.from(out) : null;
}

/** A colour as the ABI's packed `0xRRGGBB`: `'#rgb'`, `'#rrggbb'`, a CSS colour name or an `[r, g, b]` triple (0..255). */
function _packedColour(colour, what) {
  if (typeof colour === 'string') {
    const rgb = _colourText(colour);
    if (rgb) return (Math.round(rgb[0] * 255) << 16) | (Math.round(rgb[1] * 255) << 8) | Math.round(rgb[2] * 255);
  } else if (colour != null && typeof colour[Symbol.iterator] === 'function') {
    const [r, g, b] = Array.from(colour, Number);
    if ([r, g, b].every(Number.isFinite)) return ((r & 0xff) << 16) | ((g & 0xff) << 8) | (b & 0xff);
  }
  throw new CadaclysmError(`${what}: a colour is '#rgb', '#rrggbb', a CSS colour name or [r, g, b] in 0..255, not ${JSON.stringify(colour)}`);
}

/**
 * `SvgOptions`'s own defaults, the same `cadaclysm_svg_options_init` fills:
 * the viewer's `iso`, orthographic, a 1000-square page, a black one-unit
 * stroke on nothing (transparent), and edges with each body's outline beside
 * them. `silhouettes` is on by default because a line set alone cannot draw
 * every body: a sphere's and a torus's only curves are the seams where their
 * one face meets itself, which are not edges of the body and are never
 * drawn, so those two came back as a blank page. Pass `silhouettes: false`
 * for the lines alone. Every field is optional on
 * `Scene.svgText`/`Scene.svg`/`Node.svgText`/`Node.svg` (and their `*Async`
 * twins); a field left out keeps its default here, not `undefined`.
 */
function svgOptionsDefaults() {
  return {
    view: 'iso', azimuth: null, elevation: null, up: null, fov: 0, width: 1000, height: 1000,
    margin: 0.05, tolerance: 0.1, stroke: '#000000', strokeWidth: 1, background: null,
    edges: true, curves: false, isocurves: false, polylines: false, silhouettes: true,
  };
}

/**
 * `options` (over `svgOptionsDefaults()`) packed into a `CadaclysmSvgOptions`:
 * `view` fills `azimuth`/`elevation` unless they are set directly, `up`
 * ('y'/'z') falls back to `defaultUp`. `cadaclysm_svg_options_init` fills the
 * struct first -- `size` included -- so a field this function never sets
 * still carries the library's own default rather than a zeroed struct's.
 */
function _svgOptions(options, defaultUp) {
  const o = { ...svgOptionsDefaults(), ...options };
  if (!(o.view in SvgView)) throw new CadaclysmError(`svg: view must be one of ${Object.keys(SvgView).join(', ')}, not ${JSON.stringify(o.view)}`);
  const [baseAzimuth, baseElevation] = SvgView[o.view];
  const raw = {};
  _lib().svg_options_init(raw);
  raw.up = String(o.up ?? defaultUp).toLowerCase() === 'y' ? 1 : 0;
  raw.azimuth = o.azimuth ?? baseAzimuth;
  raw.elevation = o.elevation ?? baseElevation;
  raw.fov = o.fov;
  raw.width = o.width;
  raw.height = o.height;
  raw.margin = o.margin;
  raw.tolerance = o.tolerance;
  raw.stroke_width = o.strokeWidth;
  raw.stroke = _packedColour(o.stroke, 'svg: stroke');
  raw.background = o.background == null ? SVG_TRANSPARENT : _packedColour(o.background, 'svg: background');
  // `silhouettes` (16) is a line set in its own right: on its own it draws an
  // outline-only page, and only naming nothing at all is refused.
  raw.flags = (o.edges ? 1 : 0) | (o.curves ? 2 : 0) | (o.isocurves ? 4 : 0) | (o.polylines ? 8 : 0)
    | (o.silhouettes ? 16 : 0);
  return raw;
}

// ---- breps --------------------------------------------------------------------

const _brepFinalizer = typeof FinalizationRegistry === 'function'
  ? new FinalizationRegistry((p) => { try { _lib().brep_release(p); } catch (_) { /* exiting */ } }) : null;

/**
 * A body's exact B-rep -- the trimmed surfaces its mesh is cut from -- shared
 * with the scene rather than copied: a reference of this object's own, given
 * back by `release()` (or the collector). Nothing here reads it; it is for the
 * blacksmith library, which operates on it without a copy
 * (`Solid.fromNode`). It outlives its scene for as long as anything holds it.
 * In the node's own frame and the file's own units and axes, whatever
 * convention the scene was opened with. The blacksmith library must come from
 * the same release; it checks `Brep.layoutId()` and refuses otherwise.
 */
class Brep {
  constructor(pointer) {
    this._pointer = pointer;
    if (_brepFinalizer) _brepFinalizer.register(this, pointer, this);
  }
  get pointer() {
    if (this._pointer === null) throw new CadaclysmError('brep: released');
    return this._pointer;
  }
  get released() { return this._pointer === null; }
  /** How this library lays a brep out in memory: its compiler, target and source. */
  static layoutId() { return _text(_lib().brep_layout_id()); }
  /**
   * Whether its faces make a manifold -- every edge bordered by one face or
   * two, the faces round every vertex one fan -- and whether it is closed:
   * `{ faces, edges, vertices, boundaryEdges, nonManifoldEdges,
   * nonManifoldVertices, isManifold, isClosed }`. Read off the topology the
   * file wrote, not a mesh: faces that name no shared edge (IGES, each surface
   * its own sheet; an IFC face written as one polygon) read as open however
   * well they meet in space.
   */
  get manifold() {
    const out = new Uint32Array(8);
    if (!_lib().brep_manifold(this.pointer, out)) throw new CadaclysmError(_lastError() || 'manifold');
    return {
      faces: out[0], edges: out[1], vertices: out[2],
      boundaryEdges: out[3], nonManifoldEdges: out[4], nonManifoldVertices: out[5],
      isManifold: out[6] === 1, isClosed: out[7] === 1,
    };
  }
  /**
   * This brep with its free edges sewn, and what was sewn: `{ brep, report }`,
   * the brep a new one (release it) and this one left as it was. Two free
   * edges become one shared edge where both their ends coincide within
   * `vertex` -- by default the rounding `manifold` merges vertices at -- and
   * their curves lie within `tolerance` of each other, by default `vertex`
   * too, so only edges that are one curve written twice are joined. A larger
   * `tolerance` also joins two curves between the same two vertices that part
   * by up to it; `vertex` is what decides which edges are candidates at all,
   * and raising it is what could close a slot. Nothing moves. `report` is
   * `{ pairs, freeBefore, freeAfter, refused, worstGap, tolerance, vertex }`:
   * the edges joined, the free edges before and after, how many groups of free
   * edges between the same two vertices were left free (too far apart for the
   * tolerance, or more than two), the widest gap sewed, and the two
   * tolerances used. Omitted or `undefined` takes the default.
   */
  sewed({ tolerance, vertex } = {}) {
    const counts = new Uint32Array(4);
    const gaps = new Float64Array(3);
    const p = _lib().brep_sew(this.pointer, tolerance ?? NaN, vertex ?? NaN, counts, gaps);
    if (p === null) throw new CadaclysmError(_lastError() || 'sew');
    return {
      brep: new Brep(p),
      report: {
        pairs: counts[0], freeBefore: counts[1], freeAfter: counts[2], refused: counts[3],
        worstGap: gaps[0], tolerance: gaps[1], vertex: gaps[2],
      },
    };
  }
  /**
   * What is wrong with this brep, as a `HealthReport`: the free edges (the sides one face
   * bounds) and the wires they chain into, each with its nearest partner and the gap to it;
   * the features below `tolerance`; the loose edges; and what `sewed` would join and leave.
   * Nothing moves. `tolerance` is an absolute length, by default `1e-4` times the diagonal;
   * omitted, NaN, infinite, zero or negative takes the default, and the report shows what was
   * used. `mesh: true` also meshes the brep and reports where the mesh cracks (`cracks`);
   * without it `cracks` is null.
   */
  health({ tolerance, mesh = false } = {}) {
    const l = _lib();
    const h = l.brep_health(this.pointer, tolerance ?? NaN, Boolean(mesh));
    if (h === null) throw new CadaclysmError(_lastError() || 'health');
    try {
      const counts = new Uint32Array(18), sizes = new Float64Array(8);
      if (!l.brep_health_summary(h, counts, sizes)) throw new CadaclysmError(_lastError() || 'health');
      const rows = (read, a, b) => {
        const n = read(h, null, null);
        const x = new Uint32Array(a * n), y = new Float64Array(b * n);
        if (n) read(h, x, y);
        return [x, y];
      };
      const [freeIds, freeSizes] = rows(l.brep_health_free_edges, 6, 2);
      const [wireRuns, wireSizes] = rows(l.brep_health_wires, 3, 2);
      const [smallItems, smallSizes] = rows(l.brep_health_small, 2, 1);
      const n = l.brep_health_crack_edges(h, null);
      const cracks = new Uint32Array(n);
      if (n) l.brep_health_crack_edges(h, cracks);
      return _healthReport(counts, sizes, freeIds, freeSizes, wireRuns, wireSizes, smallItems, smallSizes, cracks);
    } finally {
      l.brep_health_free(h);
    }
  }
  /**
   * This brep with its small features removed, and what was done: `{ brep, report }`, the
   * brep a new one (release it), the report a `HealReport`; this one is left as it was. It
   * heals what `health` lists as small at the same `tolerance` (omitted or `undefined` takes
   * the default, as `health`'s). `edges`, `faces` and `holes` (each true by default) switch
   * each kind of fix; a kind switched off is refused as `toggled`.
   */
  healed({ tolerance, edges = true, faces = true, holes = true } = {}) {
    const l = _lib();
    const h = l.brep_healed(this.pointer, tolerance ?? NaN, _healFlags({ edges, faces, holes }));
    if (h === null) throw new CadaclysmError(_lastError() || 'healed');
    try {
      const counts = new Uint32Array(11), sizes = new Float64Array(2);
      if (!l.brep_heal_summary(h, counts, sizes)) throw new CadaclysmError(_lastError() || 'healed');
      let n = l.brep_heal_fixes(h, null, null);
      const fixItems = new Uint32Array(2 * n), fixSizes = new Float64Array(2 * n);
      if (n) l.brep_heal_fixes(h, fixItems, fixSizes);
      n = l.brep_heal_refused(h, null, null);
      const refusedItems = new Uint32Array(3 * n), refusedSizes = new Float64Array(n);
      if (n) l.brep_heal_refused(h, refusedItems, refusedSizes);
      const report = _healReport(counts, sizes, fixItems, fixSizes, refusedItems, refusedSizes);
      const body = l.brep_heal_body(h);
      if (body === null) throw new CadaclysmError(_lastError() || 'healed');
      return { brep: new Brep(body), report };
    } finally {
      l.brep_heal_free(h);
    }
  }
  /**
   * How far brep edge `edge` (as a `HealFix` or `FreeEdge` names one) may lie off its curve:
   * 0 for an exact edge, the distance healing or sewing moved it where that is recorded, null
   * when no trim names the id (an edge healing removed).
   */
  edgeTolerance(edge) {
    const t = _lib().brep_edge_tolerance(this.pointer, edge >>> 0);
    return Number.isNaN(t) ? null : t;
  }
  release() {
    if (this._pointer === null) return;
    const p = this._pointer; this._pointer = null;
    if (_brepFinalizer) _brepFinalizer.unregister(this);
    _lib().brep_release(p);
  }
  [DISPOSE]() { this.release(); }
}

// ---- health and healing -------------------------------------------------------

/**
 * One free edge: a side only one face bounds (`trim`), the `edge` it lies on (null for a side
 * with no edge), the `face` it bounds and the free `wire` it is on, its nearest `partner` across
 * the gap (a row of `freeEdges`; null if there is none), how many of its two ends it
 * `sharedEnds` with that partner, its `length` and the `gap` to the partner (`Infinity` without one).
 */
class FreeEdge {
  constructor(trim, edge, face, wire, partner, sharedEnds, length, gap) {
    this.trim = trim; this.edge = edge; this.face = face; this.wire = wire;
    this.partner = partner; this.sharedEnds = sharedEnds; this.length = length; this.gap = gap;
  }
}

/** A chain of free edges end to end: the rows `first` to `first + count` of `freeEdges`, whether it `closed` on itself, its total `length` and the `widestGap` to any partner. */
class FreeWire {
  constructor(first, count, closed, length, widestGap) {
    this.first = first; this.count = count; this.closed = closed; this.length = length; this.widestGap = widestGap;
  }
}

/** Something below the tolerance: its `kind` ('short_edge', 'collapsed_edge', 'sliver_face', 'tiny_face', 'tiny_body' or 'small_hole'), its edge, face, body or loop `index`, and how small (`size`). */
class SmallFeature {
  constructor(kind, index, size) { this.kind = kind; this.index = index; this.size = size; }
}

/** What a mesh of the body shows (`health({ mesh: true })`): whether it is `watertight`, how many mesh edges are `open` or `folded`, how many `crossings`, and the body's `edges` the cracks lie along. */
class Cracks {
  constructor(watertight, open, folded, crossings, edges) {
    this.watertight = watertight; this.open = open; this.folded = folded; this.crossings = crossings; this.edges = edges;
  }
}

/**
 * What is wrong with a body, as plain data (`health`): the `tolerance` and `rounding` it judged
 * at and the body's `extent`; the `freeEdges`, their `wires`, the `small` features; the
 * `looseEdges` (`worstLoose` the widest); what sewing would do (`sewPairs` joined, `sewRefused`,
 * `sewWorstGap`); the mesh's `cracks` when asked for, else null; and the `worstGap` between a free
 * edge and its partner.
 */
class HealthReport {
  constructor(tolerance, rounding, extent, freeEdges, wires, small, looseEdges, worstLoose, sewPairs, sewRefused, sewWorstGap, cracks, worstGap) {
    this.tolerance = tolerance; this.rounding = rounding; this.extent = extent;
    this.freeEdges = freeEdges; this.wires = wires; this.small = small;
    this.looseEdges = looseEdges; this.worstLoose = worstLoose;
    this.sewPairs = sewPairs; this.sewRefused = sewRefused; this.sewWorstGap = sewWorstGap;
    this.cracks = cracks; this.worstGap = worstGap;
  }
  /** The free edges of wire number `wire` (an index into `wires`), in order. */
  wireEdges(wire) {
    const w = this.wires[wire];
    if (w === undefined) throw new RangeError(`wireEdges: wire ${wire} of ${this.wires.length}`);
    return this.freeEdges.slice(w.first, w.first + w.count);
  }
}

/** One small feature `healed` removed: its `kind` (as `SmallFeature.kind`), its `index` in the input, its `size`, and how far the vertices it merged `moved`. */
class HealFix {
  constructor(kind, index, size, moved) { this.kind = kind; this.index = index; this.size = size; this.moved = moved; }
}

/**
 * One small feature `healed` left, and why: `kind` and `index` as `HealFix`'s; `why` is
 * 'would_empty_loop', 'closed', 'seam', 'chain', 'neighbours_part', 'uneven', 'non_manifold',
 * 'has_holes', 'body_guard', 'toggled' or 'unsupported'; `figure` the chain's width or the
 * neighbours' gap, else 0.
 */
class HealRefusal {
  constructor(kind, index, why, figure) { this.kind = kind; this.index = index; this.why = why; this.figure = figure; }
}

/**
 * What `healed` did, as plain data: the `tolerance` it healed at, the furthest any trim `moved`,
 * whether the body guard refused fixes (`guarded`), the `fixes` made and the features `refused`;
 * and the body's health before and after -- its small features, free edges, whether it is
 * closed, and its non-manifold edges.
 */
class HealReport {
  constructor(tolerance, moved, guarded, fixes, refused, smallBefore, smallAfter, freeBefore, freeAfter,
    closedBefore, closedAfter, nonmanifoldBefore, nonmanifoldAfter) {
    this.tolerance = tolerance; this.moved = moved; this.guarded = guarded;
    this.fixes = fixes; this.refused = refused;
    this.smallBefore = smallBefore; this.smallAfter = smallAfter;
    this.freeBefore = freeBefore; this.freeAfter = freeAfter;
    this.closedBefore = closedBefore; this.closedAfter = closedAfter;
    this.nonmanifoldBefore = nonmanifoldBefore; this.nonmanifoldAfter = nonmanifoldAfter;
  }
}

const _HEALTH_KINDS = ['short_edge', 'collapsed_edge', 'sliver_face', 'tiny_face', 'tiny_body', 'small_hole'];
const _HEAL_WHYS = ['would_empty_loop', 'closed', 'seam', 'chain', 'neighbours_part', 'uneven', 'non_manifold',
  'has_holes', 'body_guard', 'toggled', 'unsupported'];

/** A code of the library's as its name in `names`, or a `RangeError` for a code this module does not know. */
function _named(names, code, what) {
  const name = names[code];
  if (name === undefined) throw new RangeError(`${what}: the library answered ${code}, which this module does not know`);
  return name;
}

/** The flat rows of the health C ABI (or the wasm object) as a `HealthReport`; any array-likes. */
function _healthReport(counts, sizes, freeIds, freeSizes, wireRuns, wireSizes, smallItems, smallSizes, crackEdges) {
  const id = (v) => (v === NONE ? null : Number(v));
  const freeEdges = [];
  for (let i = 0; i < freeIds.length / 6; i++) {
    freeEdges.push(new FreeEdge(Number(freeIds[6 * i]), id(freeIds[6 * i + 1]), Number(freeIds[6 * i + 2]), Number(freeIds[6 * i + 3]),
      id(freeIds[6 * i + 4]), Number(freeIds[6 * i + 5]), Number(freeSizes[2 * i]), Number(freeSizes[2 * i + 1])));
  }
  const wires = [];
  for (let i = 0; i < wireRuns.length / 3; i++) {
    wires.push(new FreeWire(Number(wireRuns[3 * i]), Number(wireRuns[3 * i + 1]), wireRuns[3 * i + 2] !== 0,
      Number(wireSizes[2 * i]), Number(wireSizes[2 * i + 1])));
  }
  const small = [];
  for (let i = 0; i < smallSizes.length; i++) {
    small.push(new SmallFeature(_named(_HEALTH_KINDS, smallItems[2 * i], 'health'), Number(smallItems[2 * i + 1]), Number(smallSizes[i])));
  }
  const cracks = counts[12] === 1
    ? new Cracks(counts[13] !== 0, Number(counts[14]), Number(counts[15]), Number(counts[16]), Array.from(crackEdges, Number))
    : null;
  return new HealthReport(Number(sizes[0]), Number(sizes[1]), Number(sizes[2]), freeEdges, wires, small,
    Number(counts[9]), Number(sizes[4]), Number(counts[10]), Number(counts[11]), Number(sizes[5]), cracks, Number(sizes[3]));
}

/** The flat rows of the heal C ABI (or the wasm object) as a `HealReport`; any array-likes. */
function _healReport(counts, sizes, fixItems, fixSizes, refusedItems, refusedSizes) {
  const fixes = [];
  for (let i = 0; i < fixItems.length / 2; i++) {
    fixes.push(new HealFix(_named(_HEALTH_KINDS, fixItems[2 * i], 'healed'), Number(fixItems[2 * i + 1]),
      Number(fixSizes[2 * i]), Number(fixSizes[2 * i + 1])));
  }
  const refused = [];
  for (let i = 0; i < refusedSizes.length; i++) {
    refused.push(new HealRefusal(_named(_HEALTH_KINDS, refusedItems[3 * i], 'healed'), Number(refusedItems[3 * i + 1]),
      _named(_HEAL_WHYS, refusedItems[3 * i + 2], 'healed'), Number(refusedSizes[i])));
  }
  return new HealReport(Number(sizes[0]), Number(sizes[1]), counts[2] !== 0, fixes, refused,
    Number(counts[3]), Number(counts[4]), Number(counts[5]), Number(counts[6]),
    counts[7] !== 0, counts[8] !== 0, Number(counts[9]), Number(counts[10]));
}

/** `healed`'s switches as the C ABI's flag bits: 1 edges, 2 faces, 4 holes; each on unless `false`. */
function _healFlags({ edges = true, faces = true, holes = true } = {}) {
  return (edges ? 1 : 0) | (faces ? 2 : 0) | (holes ? 4 : 0);
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

/**
 * A rigid body of the file's mechanism: the nodes that move together when a
 * joint moves it. From `Scene.links()`; borrows from the scene like `Node`.
 */
class Link {
  constructor(scene, index) { this.scene = scene; this.index = index; }
  equals(other) { return other instanceof Link && other.index === this.index && other.scene === this.scene; }
  get name() { return _text(_lib().link_name(this.scene._handle, this.index)); }
  /** The topmost node of each subtree this link moves, in node order: moving
   *  these moves everything under them. */
  nodes() {
    const l = _lib(); const h = this.scene._handle;
    const out = [];
    for (let i = 0, n = l.link_node_count(h, this.index); i < n; i++) out.push(new Node(this.scene, l.link_node(h, this.index, i)));
    return out;
  }
}

/**
 * A connection between two links of the file's mechanism, and, when the file
 * names one, the kinematic pair saying how it moves. From `Scene.joints()`.
 */
class Joint {
  constructor(scene, index) { this.scene = scene; this.index = index; }
  equals(other) { return other instanceof Joint && other.index === this.index && other.scene === this.scene; }
  get name() { return _text(_lib().joint_name(this.scene._handle, this.index)); }
  /** The link this joint starts at, in the file's order -- not a parent: a joint does not say which side moves. */
  get start() { return new Link(this.scene, _lib().joint_start(this.scene._handle, this.index)); }
  /** The link this joint ends at, in the file's order. */
  get end() { return new Link(this.scene, _lib().joint_end(this.scene._handle, this.index)); }
  /** How this joint moves: the kinematic pair naming it, or null when the file gives it none. */
  get pair() {
    const l = _lib(); const h = this.scene._handle;
    const kind = l.joint_pair_kind(h, this.index);
    if (kind < 0) return null;
    const typeName = l.joint_pair_type(h, this.index);
    const pitchRaw = l.joint_pair_pitch(h, this.index);
    const rawStart = new Float64Array(16); const rawEnd = new Float64Array(16);
    l.joint_pair_frames(h, this.index, rawStart, rawEnd);
    const freedoms = [];
    for (let i = 0, n = l.joint_freedom_count(h, this.index); i < n; i++) {
      const raw = {};
      if (!l.joint_freedom(h, this.index, i, raw)) continue;
      freedoms.push(new Freedom(
        _MOTIONS[raw.motion], _AXES[raw.axis],
        raw.has_lower ? raw.lower : null,
        raw.has_upper ? raw.upper : null,
      ));
    }
    const kindNameRaw = l.joint_pair_kind_name(h, this.index);
    const count = Number(l.joint_pair_parameters(h, this.index, null, 0));
    const parameters = new Float64Array(count);
    if (count > 0) l.joint_pair_parameters(h, this.index, parameters, count);
    return new Pair(
      _PAIR_KIND_NAMES[kind], typeName == null ? null : String(typeName),
      Number.isNaN(pitchRaw) ? null : pitchRaw,
      _rows(rawStart), _rows(rawEnd), rawStart, rawEnd, freedoms,
      kindNameRaw == null ? _PAIR_KIND_NAMES[kind] : String(kindNameRaw), Array.from(parameters),
    );
  }
}

// ---- pairs, freedoms and states ----------------------------------------------

const _PAIR_KIND_NAMES = [
  'revolute', 'prismatic', 'cylindrical', 'spherical', 'spherical_with_pin',
  'planar', 'universal', 'homokinetic', 'screw', 'fully_constrained',
  'unconstrained', 'low_order', 'other',
];
const _MOTIONS = ['rotation', 'translation'];
const _AXES = ['x', 'y', 'z'];

/** One degree of freedom of a `Pair`: which motion, about or along which
 *  contact-frame axis, and its optional range. From `Pair.freedoms()`. */
class Freedom {
  constructor(motion, axis, lower, upper) { this.motion = motion; this.axis = axis; this.lower = lower; this.upper = upper; }
}

/**
 * A kinematic pair: the kind of relative motion a joint allows between its two
 * links -- what `Joint.pair` returns.
 */
class Pair {
  constructor(kind, typeName, pitch, frameStart, frameEnd, rawFrameStart, rawFrameEnd, freedoms, kindName, parameters) {
    /** One of thirteen kinds: `revolute`, `prismatic`, `cylindrical`, `spherical`,
     *  `spherical_with_pin`, `planar`, `universal`, `homokinetic`, `screw`,
     *  `fully_constrained`, `unconstrained`, `low_order`, `other`. */
    this.kind = kind;
    /** For `other`: the pair's entity type name (`GEAR_PAIR`). null otherwise. */
    this.typeName = typeName;
    /** For `screw`: its pitch, a length per revolution in the scene's units. null otherwise. */
    this.pitch = pitch;
    /** The pair's contact frame fixed in its joint's `start` link, like `Node.transform`. */
    this.frameStart = frameStart;
    /** The pair's contact frame fixed in its joint's `end` link. */
    this.frameEnd = frameEnd;
    /** `frameStart` in the ABI's own column-major order, as 16 doubles -- like `Node.rawTransform`. */
    this.rawFrameStart = rawFrameStart;
    /** `frameEnd` in the ABI's own column-major order, as 16 doubles. */
    this.rawFrameEnd = rawFrameEnd;
    this._freedoms = freedoms;
    /** The kind by name, finer than `kind`: the same thirteen names, and `gear` and
     *  `rack_and_pinion` for the two coupled pairs `kind` reads as `other`. */
    this.kindName = kindName;
    /** The pair's own numbers, in the order `Assembly.pairWith` takes them: `screw`
     *  `[pitch]`, `rack_and_pinion` `[pinion_radius]`, `gear` `[radius_first, radius_second,
     *  ratio, bevel, helical_angle]` (always five, the ratio the second link's rotation over
     *  the first's); `[]` for every other kind. */
    this.parameters = parameters;
  }
  /** Its degrees of freedom, in the reader's per-kind order, each a `Freedom`. A
   *  `State`'s values compose in this order. */
  freedoms() { return this._freedoms; }
}

/** One row of a `State`: the joint it sets, and the values it sets it to. */
class StateValue {
  constructor(joint, values) { this.joint = joint; this.values = values; }
}

/**
 * A named pose of the file's mechanism: a `MECHANISM_STATE_REPRESENTATION`.
 * From `Scene.states()`.
 */
class State {
  constructor(index, name, values) { this.index = index; this.name = name; this.values = values; }
}

function _readState(scene, index) {
  const l = _lib(); const h = scene._handle;
  const name = _text(l.state_name(h, index));
  const rows = [];
  for (let row = 0, n = l.state_value_count(h, index); row < n; row++) {
    const jointOut = new Uint32Array(1);
    const count = l.state_value(h, index, row, jointOut, null, 0);
    const values = new Float64Array(count);
    l.state_value(h, index, row, jointOut, values, count);
    const joint = jointOut[0] === NONE ? null : new Joint(scene, jointOut[0]);
    rows.push(new StateValue(joint, Array.from(values)));
  }
  return new State(index, name, rows);
}

// A `cadaclysm::Interpolation`'s code (cadaclysm_sequence_segment) as the lower-case word.
const _INTERPOLATIONS = ['undefined', 'discontinuous', 'synchronous', 'linear'];

/** One step of a `Sequence`: the `State` it reaches, its parameter, and how the motion leaves it. */
class Segment {
  constructor(state, t, interpolation) { this.state = state; this.t = t; this.interpolation = interpolation; }
}

/**
 * A motion the file records: an `INTERPOLATED_CONFIGURATION_SEQUENCE`, its states at
 * increasing parameter values. From `Scene.sequences()`.
 *
 * `pose(t)` poses it at parameter `t`, in the file's own parameter: a segment is a keyframe
 * of its state, a `'discontinuous'` segment holds until the next and every other kind moves
 * linearly, an open sequence holds its ends and a `closed` one wraps. `secondsPerUnit` is
 * null where the file states no time unit (the parameter is then read as seconds).
 */
class Sequence {
  constructor(scene, index) { this._scene = scene; this.index = index; }
  /** The sequence's name: its representation's (`name #2` and on for further sequences in one representation). */
  get name() { return _text(_lib().sequence_name(this._scene._handle, this.index)); }
  /** Whether the motion returns to its first segment (its last is not discontinuous). */
  get closed() { return Boolean(_lib().sequence_closed(this._scene._handle, this.index)); }
  /** Seconds per unit of the parameter where the file states a time unit; null where it states none. */
  get secondsPerUnit() {
    const value = _lib().sequence_seconds_per_unit(this._scene._handle, this.index);
    return value === 0 ? null : value;
  }
  /** The segments, in file order (at least two). */
  get segments() {
    const l = _lib(); const h = this._scene._handle; const out = [];
    for (let i = 0, n = l.sequence_segment_count(h, this.index); i < n; i++) {
      const state = new Uint32Array(1); const t = new Float64Array(1); const interpolation = new Uint32Array(1);
      l.sequence_segment(h, this.index, i, state, t, interpolation);
      out.push(new Segment(_readState(this._scene, state[0]), t[0], _INTERPOLATIONS[interpolation[0]] ?? 'undefined'));
    }
    return out;
  }
  /** The first segment's parameter. */
  get start() { return this.segments[0].t; }
  /** The last segment's parameter (the closing span not included). */
  get end() { const segments = this.segments; return segments[segments.length - 1].t; }
  /** The mechanism posed at parameter `t`, with `ground` held fixed as `Scene.pose` does.
   *  Throws `CadaclysmError` for a `t` that is not finite. */
  pose(t, ground = null) {
    const groundIndex = ground === null ? NONE : ground.index;
    const ptr = _lib().pose_sequence(this._scene._handle, this.index, Number(t), groundIndex);
    if (!ptr) throw new CadaclysmError(_lastError());
    return _copyPose(this._scene, ptr);
  }
}

// The words of the C enums, indexed by their values (cadaclysm.h).
const _SCHEDULE_KINDS = ['planned', 'actual', 'baseline', 'notdefined', 'other'];
const _TASK_KINDS = [
  'attendance', 'construction', 'demolition', 'dismantle', 'disposal', 'installation',
  'logistic', 'maintenance', 'move', 'operation', 'removal', 'renovation', 'notdefined', 'other',
];
const _LINK_KINDS = ['finish_start', 'start_start', 'finish_finish', 'start_finish', 'notdefined', 'other'];
const _DATES = { scheduled: 0, actual: 1 };
const _PHASES = ['unbuilt', 'building', 'built', 'demolishing', 'demolished'];

/**
 * What one element is doing on a date: `WorkSchedule.at()`'s rows. `phase` is `'unbuilt'`,
 * `'building'`, `'built'`, `'demolishing'` or `'demolished'`; `progress` is 0..1 through the
 * window that governs the phase; `variance` is the seconds late (positive) or early
 * (negative) against the schedule, or null where there is none to give.
 */
class ElementState {
  constructor(node, phase, progress, variance) { this.node = node; this.phase = phase; this.progress = progress; this.variance = variance; }
}

/**
 * Every date pair a task gives, each a number (seconds since 1970-01-01T00:00, no zone:
 * `new Date(seconds * 1000)`, read with `toISOString()` or the `getUTC*` accessors) or null
 * where the file gives none. `duration` is in seconds.
 */
class TaskTime {
  constructor(raw) {
    const given = (name) => (raw['has_' + name] ? raw[name] : null);
    this.scheduleStart = given('schedule_start');
    this.scheduleFinish = given('schedule_finish');
    this.earlyStart = given('early_start');
    this.earlyFinish = given('early_finish');
    this.lateStart = given('late_start');
    this.lateFinish = given('late_finish');
    this.actualStart = given('actual_start');
    this.actualFinish = given('actual_finish');
    this.duration = given('duration');
  }
}

/** A sequence between two tasks of one schedule. From `WorkSchedule.links`; `lag` is in seconds, or null. */
class TaskLink {
  constructor(schedule, index, from, to, kind, lag) {
    this._schedule = schedule; this._index = index;
    /** The predecessor. */ this.from = from;
    /** The successor. */ this.to = to;
    /** `'finish_start'`, `'start_start'`, `'finish_finish'`, `'start_finish'`, `'notdefined'` or `'other'`. */
    this.kind = _LINK_KINDS[kind] ?? 'notdefined';
    this.lag = lag;
  }
  /** The text of a user-defined kind (`kind === 'other'`); `''` otherwise. */
  get kindName() { return _text(_lib().task_link_kind_name(this._schedule._scene._handle, this._schedule.index, this._index)); }
}

/**
 * One task of a `WorkSchedule`. From `WorkSchedule.tasks`. `kind` is `'attendance'`,
 * `'construction'`, `'demolition'`, `'dismantle'`, `'disposal'`, `'installation'`,
 * `'logistic'`, `'maintenance'`, `'move'`, `'operation'`, `'removal'`, `'renovation'`,
 * `'notdefined'` or `'other'`; `kindName` is the text of a user-defined one. `parent` is the
 * summary task nesting it (null at the top); `nodes` are the nodes it builds or removes.
 */
class Task {
  constructor(schedule, index) { this.schedule = schedule; this.index = index; }
  equals(other) { return other instanceof Task && other.index === this.index && other.schedule.equals(this.schedule); }
  /** The index of the work schedule this task belongs to (`scene.schedules()[i]`). */
  get scheduleIndex() { return this.schedule.index; }
  get name() { return _text(_lib().task_name(this.schedule._scene._handle, this.schedule.index, this.index)); }
  /** Its identification, `''` where none. */
  get identification() { return _text(_lib().task_identification(this.schedule._scene._handle, this.schedule.index, this.index)); }
  get kind() { return _TASK_KINDS[_lib().task_kind(this.schedule._scene._handle, this.schedule.index, this.index)] ?? 'notdefined'; }
  /** The text of a user-defined kind (`kind === 'other'`); `''` otherwise. */
  get kindName() { return _text(_lib().task_kind_name(this.schedule._scene._handle, this.schedule.index, this.index)); }
  /** Its status as the file writes it, `''` where none. */
  get status() { return _text(_lib().task_status(this.schedule._scene._handle, this.schedule.index, this.index)); }
  get milestone() { return Boolean(_lib().task_milestone(this.schedule._scene._handle, this.schedule.index, this.index)); }
  get parent() {
    const out = new Uint32Array(1);
    return _lib().task_parent(this.schedule._scene._handle, this.schedule.index, this.index, out) ? new Task(this.schedule, out[0]) : null;
  }
  get time() {
    const raw = {};
    _lib().task_time(this.schedule._scene._handle, this.schedule.index, this.index, raw);
    return new TaskTime(raw);
  }
  get nodes() {
    const l = _lib(); const h = this.schedule._scene._handle; const s = this.schedule.index;
    const count = l.task_node_count(h, s, this.index);
    const out = new Uint32Array(count);
    if (count > 0) l.task_nodes(h, s, this.index, out, count);
    return Array.from(out, (n) => new Node(this.schedule._scene, n));
  }
}

/**
 * A building's programme: an `IfcWorkSchedule` and the tasks it controls. From
 * `Scene.schedules()`. `at(date)` says what each element it names is doing on a date; dates
 * are numbers, seconds since 1970-01-01T00:00 (see `TaskTime`).
 */
class WorkSchedule {
  constructor(scene, index) { this._scene = scene; this.index = index; }
  equals(other) { return other instanceof WorkSchedule && other.index === this.index && other._scene === this._scene; }
  /** Its name, else its identification, else `schedule #k` (k from 1, in file order). */
  get name() { return _text(_lib().schedule_name(this._scene._handle, this.index)); }
  /** Its identification, `''` where none. */
  get identification() { return _text(_lib().schedule_identification(this._scene._handle, this.index)); }
  /** `'planned'`, `'actual'`, `'baseline'`, `'notdefined'` or `'other'`. */
  get kind() { return _SCHEDULE_KINDS[_lib().schedule_kind(this._scene._handle, this.index)] ?? 'notdefined'; }
  /** The text of a user-defined kind (`kind === 'other'`); `''` otherwise. */
  get kindName() { return _text(_lib().schedule_kind_name(this._scene._handle, this.index)); }
  /** The schedule's start, or null where the file gives none. */
  get start() { const out = new Float64Array(1); return _lib().schedule_start(this._scene._handle, this.index, out) ? out[0] : null; }
  /** The schedule's finish, or null where the file gives none. */
  get finish() { const out = new Float64Array(1); return _lib().schedule_finish(this._scene._handle, this.index, out) ? out[0] : null; }
  /** Its tasks, in file order. */
  get tasks() {
    const out = [];
    for (let i = 0, n = _lib().task_count(this._scene._handle, this.index); i < n; i++) out.push(new Task(this, i));
    return out;
  }
  /** Its task links (`IfcRelSequence`), in file order. */
  get links() {
    const l = _lib(); const h = this._scene._handle; const tasks = this.tasks; const out = [];
    for (let i = 0, n = l.task_link_count(h, this.index); i < n; i++) {
      const from = new Uint32Array(1); const to = new Uint32Array(1); const kind = new Uint32Array(1);
      const lag = new Float64Array(1); const hasLag = new Uint8Array(1);
      l.task_link(h, this.index, i, from, to, kind, lag, hasLag);
      out.push(new TaskLink(this, i, tasks[from[0]], tasks[to[0]], kind[0], hasLag[0] ? lag[0] : null));
    }
    return out;
  }
  /**
   * What each element this schedule names is doing on `date` (seconds since
   * 1970-01-01T00:00), in node order; elements no task names are not listed. `dates` is
   * `'scheduled'` or `'actual'`: which of a task's dates to play. Throws `Error` for any other
   * `dates` and `CadaclysmError` for a `date` that is not finite.
   */
  at(date, dates = 'scheduled') {
    if (!Object.prototype.hasOwnProperty.call(_DATES, dates)) throw new Error("dates must be 'scheduled' or 'actual'");
    const l = _lib(); const h = this._scene._handle; const which = _DATES[dates];
    const count = Number(l.schedule_at(h, this.index, Number(date), which, null, 0));
    if (count < 0) throw new CadaclysmError(_lastError());
    if (count === 0) return [];
    const buffer = Buffer.alloc(count * koffi.sizeof(CadaclysmElementState));
    l.schedule_at(h, this.index, Number(date), which, buffer, count);
    const rows = koffi.decode(buffer, 'CadaclysmElementState', count);
    return rows.map((r) => new ElementState(new Node(this._scene, r.node), _PHASES[r.phase] ?? 'unbuilt', r.progress, r.has_variance ? r.variance : null));
  }
}

/**
 * A posed mechanism: `Scene.pose()` or `Scene.poseState()`'s answer. The document
 * itself is unchanged.
 *
 * Copied eagerly out of the C handle at construction time (`_copyPose`), so a `Pose`
 * holds no C pointer and outlives the call that made it -- closing the scene does not
 * invalidate it.
 */
class Pose {
  constructor(scene, ground, unsolved, outOfRange, transforms, diagnostics = []) {
    this._scene = scene;
    /** The link held fixed. */
    this.ground = ground;
    /** Joints that close a loop and were not honoured, in file order. */
    this.unsolved = unsolved;
    /** `[joint, freedom index, value]` for every given value outside its freedom's range. */
    this.outOfRange = outOfRange;
    /** What the couplings (gear, rack and pinion, a loop-closing screw) could not solve, or
     *  found disagreeing, in file order, in the kernel's words:
     *  `coupling 'mesh': both 'a' and 'b' are given and disagree by 0.1`. */
    this.diagnostics = diagnostics;
    this._transforms = transforms;
  }
  /** `node`'s posed transform, as four rows -- the same type `Node.transform` returns. */
  transform(node) { return _rows(this.rawTransform(node)); }
  /** The same matrix in the ABI's own column-major order, as 16 doubles, exactly as
   *  `Node.rawTransform` lays them out. */
  rawTransform(node) { return this._transforms[node.index]; }
  /**
   * Draw this pose's scene as `Scene.show` does -- the scene by handle -- with every node's
   * posed transform handed to the view (`cadaclysm_view_set_node_transforms`). An unposed
   * pose (`scene.pose([])`) draws exactly what `Scene.show` does.
   */
  show(options = {}) { return require('./cadaclysm_view')._present(this._scene, { ...options, up: options.up ?? this._scene._defaultUp() }, 'show', this._transforms); }
  /** `Pose.show`'s orbiting twin; returns what `Scene.view` returns. */
  view(options = {}) { return require('./cadaclysm_view')._present(this._scene, { ...options, up: options.up ?? this._scene._defaultUp() }, 'view', this._transforms); }
}

/**
 * Reads everything out of a `CadaclysmPose *` into a `Pose`, then frees it (ruling 2 of
 * the posing plan: wrappers copy eagerly, never holding the C pointer). Runs in a
 * `try`/`finally` so an exception midway through copying still frees the handle.
 */
function _copyPose(scene, posePtr) {
  const l = _lib();
  try {
    const ground = new Link(scene, l.pose_ground(posePtr));
    const transforms = [];
    for (let node = 0, n = l.pose_node_count(posePtr); node < n; node++) {
      const raw = new Float64Array(16);
      l.pose_node_transform(posePtr, node, raw);
      transforms.push(raw);
    }
    const unsolved = [];
    for (let i = 0, n = l.pose_unsolved_count(posePtr); i < n; i++) {
      const joint = l.pose_unsolved(posePtr, i);
      if (joint !== NONE) unsolved.push(new Joint(scene, joint));
    }
    const outOfRange = [];
    for (let i = 0, n = l.pose_out_of_range_count(posePtr); i < n; i++) {
      const joint = new Uint32Array(1); const freedom = new Uint32Array(1); const value = new Float64Array(1);
      if (l.pose_out_of_range(posePtr, i, joint, freedom, value)) {
        outOfRange.push([new Joint(scene, joint[0]), freedom[0], value[0]]);
      }
    }
    const diagnostics = [];
    for (let i = 0, n = l.pose_diagnostic_count(posePtr); i < n; i++) {
      const text = l.pose_diagnostic(posePtr, i);
      if (text != null) diagnostics.push(String(text));
    }
    return new Pose(scene, ground, unsolved, outOfRange, transforms, diagnostics);
  } finally {
    l.pose_free(posePtr);
  }
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
  /** Draw it with the view library in use: on the wgpu library, in the one shared window (returns at once); elsewhere, a still. Options as `ShowOptions`. */
  show(options = {}) { return require('./cadaclysm_view')._present(this, { ...options, up: options.up ?? this.scene._defaultUp() }, 'show'); }
  /** Orbit it until the window is closed; the camera it was left at, and the last pick. */
  view(options = {}) { return require('./cadaclysm_view')._present(this, { ...options, up: options.up ?? this.scene._defaultUp() }, 'view'); }
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
  /** `bounds` in `double`: the same extent, unnarrowed -- exact far from the origin. */
  get bounds64() { const b = _lib().node_bounds64(this.scene._handle, this.index); return new Bounds64(b.min, b.max); }
  mesh() { return _meshOf(_lib().node_mesh(this.scene._handle, this.index)); }
  /**
   * `mesh()` in `double` (see `Mesh64`): positions/normals/uvs copied out at call time
   * as the exact f64 values `mesh()`'s `float` ones are narrowed from, same indices --
   * null for a part with nothing to mesh, where `mesh()` gives an empty `Mesh`. Like
   * `mesh()`'s copy, it survives `Scene.forgetMeshes()` and `Scene.close()`.
   */
  mesh64() {
    const raw = _lib().node_mesh64(this.scene._handle, this.index);
    return raw.positions == null ? null : _mesh64Of(raw);
  }
  /** Level 0 is `mesh()`; 1..`lodLevels()` share its vertices and use fewer of its indices. */
  meshLod(level) { return _meshOf(_lib().node_mesh_lod(this.scene._handle, this.index, level)); }
  /** How far a level moved the surface, in the scene's units; what to pick levels by. */
  lodError(level) { return _lib().node_lod_error(this.scene._handle, this.index, level); }
  /**
   * This node's body meshed for a solver, as a `FemMesh`: nodes welded by bits,
   * triangles wound outward, each node tagged with the lowest-dimension B-rep entity
   * it lies on, and every crack reported rather than closed. **Owned by you** --
   * `free()` it, or `using` it.
   *
   * `tolerance` is the chordal tolerance in model units, finite and above zero, and
   * **it alone governs how closely the mesh follows the geometry**. `maxSize` is a
   * size ceiling, finite and zero or more, 0 being no ceiling (curvature alone): **it
   * bounds the boundary and targets the interior**, which is not a
   * longest-element-edge guarantee. It adds boundary nodes without refining boundary
   * geometry, and `FemMesh.longestEdge` is what the mesh actually came to -- the
   * figure to check against it.
   *
   * Those two defaults are `FemOptions::default()`'s own, restated here so that the
   * signature says what a caller gets. **They are not `mesh()`'s 0.05**: the
   * library's struct is still filled by `cadaclysm_fem_options_init` first, so a
   * field added to it later defaults without this line being touched; only these two
   * are overwritten. `cadaclysm_blacksmith.js`'s `Solid.femMesh` restates the same
   * pair.
   *
   * `placement` is 16 numbers, column-major, as `boundsPlaced` takes them (null for
   * the identity), applied in double precision throughout. The kernel library's
   * `Solid.femMesh` takes **twelve** instead -- origin, x, y, z -- so a caller moving
   * between the two reformats the placement.
   *
   * **The space is the body's, not the scene's, for a B-rep -- and the scene's for a
   * mesh**, which `FemMesh.fromMesh` is the flag for; read it there, because under a
   * non-NATIVE convention the two are different spaces.
   *
   * Meshed in the part's own frame and following the hop from an instance to the
   * shape it draws that `mesh()` follows, so a node instanced six times meshes once,
   * where it is defined.
   *
   * **A cracked body is not a failure**: it comes back with `FemMesh.watertight`
   * false and its cracks in `openEdges()` / `foldedEdges()`, and nothing is welded
   * shut to make it look sound. Throws `CadaclysmError` for a tolerance or size the
   * mesher refuses, a placement that is not 16 numbers or is not finite and
   * invertible, a node with neither a brep nor a mesh (an assembly, a storey, a
   * layer, an empty definition, a curve), and a body that meshes to no triangles at
   * all.
   *
   * Prints the unlicensed notice once, here, and not again on either of `FemMesh`'s
   * `.msh` calls.
   */
  femMesh(tolerance = 0.01, maxSize = 0.0, placement = null) {
    const m = placement == null ? null : Float64Array.from(placement, Number);
    if (m !== null && m.length !== 16) throw new CadaclysmError(`femMesh: a placement is 16 numbers, not ${m.length}`);
    const pointer = _lib().node_fem_mesh(this.scene._handle, this.index, m, _femOptions(tolerance, maxSize));
    if (!pointer) throw new CadaclysmError(_lastError() || 'fem_mesh');
    return new FemMesh(pointer);
  }
  surfaces() { return _surfacesOf(_lib().node_surfaces(this.scene._handle, this.index)); }
  /** Its exact B-rep, for `Solid.fromNode`, or null where it has none (a mesh, a curve, a CSG body, an open OpenSCAD polyhedron, or an OpenSCAD file read without the kernel). */
  get brep() {
    const p = _lib().node_brep(this.scene._handle, this.index);
    return p ? new Brep(p) : null;
  }
  edges() { return _polylinesOf(_lib().node_edges(this.scene._handle, this.index)); }
  /** One RGBA per polyline of edges(), null for an edge the file does not style; [] when nothing is. */
  edgeColours() { return _edgeColoursOf(_lib().node_edge_colors(this.scene._handle, this.index)); }
  curves() { return _polylinesOf(_lib().node_curves(this.scene._handle, this.index)); }
  isocurves() { return _polylinesOf(_lib().node_isocurves(this.scene._handle, this.index)); }
  edgeBeziers() { return _beziersOf(_lib().node_edge_beziers(this.scene._handle, this.index)); }
  curveBeziers() { return _beziersOf(_lib().node_curve_beziers(this.scene._handle, this.index)); }
  isocurveBeziers() { return _beziersOf(_lib().node_isocurve_beziers(this.scene._handle, this.index)); }
  /** `edgeBeziers()`/`curveBeziers()`/`isocurveBeziers()` in `double`: the same segments, unnarrowed. */
  edgeBeziers64() { return _beziers64Of(_lib().node_edge_beziers64(this.scene._handle, this.index)); }
  curveBeziers64() { return _beziers64Of(_lib().node_curve_beziers64(this.scene._handle, this.index)); }
  isocurveBeziers64() { return _beziers64Of(_lib().node_isocurve_beziers64(this.scene._handle, this.index)); }
  /** The collision body, or null for a node that draws nothing. `hullBudget` 0 asks for the Unity limit. */
  collision(hullBudget = 0) {
    const out = { size: koffi.sizeof(CadaclysmCollision) };
    return _lib().node_collision(this.scene._handle, this.index, hullBudget, out) ? new Collision(out) : null;
  }
  collisionHull(hullBudget = 0) {
    const h = _lib().node_collision_hull(this.scene._handle, this.index, hullBudget);
    return new CollisionHull(_floats(h.positions, h.vertex_count * 3) ?? new Float32Array(0), _uint32s(h.indices, h.index_count) ?? new Uint32Array(0), h.vertex_count, h.index_count);
  }
  // -- the surface path: for a renderer drawing exact surfaces, never triangles --
  /** The box of what this node draws under `placement` (16 numbers, column-major, as `Placement.rawTransform`; null for the identity), from its surfaces; all zeros without surfaces. */
  boundsPlaced(placement = null) {
    const m = placement == null ? null : Float64Array.from(placement);
    if (m !== null && m.length !== 16) throw new CadaclysmError('boundsPlaced: a placement is 16 numbers');
    const b = _lib().node_bounds_placed(this.scene._handle, this.index, m);
    return new Bounds(b.min, b.max);
  }
  /** `boundsPlaced()` in `double`: the same box, unnarrowed. */
  boundsPlaced64(placement = null) {
    const m = placement == null ? null : Float64Array.from(placement);
    if (m !== null && m.length !== 16) throw new CadaclysmError('boundsPlaced64: a placement is 16 numbers');
    const b = _lib().node_bounds_placed64(this.scene._handle, this.index, m);
    return new Bounds64(b.min, b.max);
  }
  /** Whether its mesh has been built and is held. */
  get isMeshed() { return _lib().node_is_meshed(this.scene._handle, this.index); }
  /** Its face boundaries from its trimmed surfaces: the outline that costs no tessellation, in the surfaces' frame (`Scene.surfaceMatrix`); empty without surfaces. */
  surfaceEdges() { return _polylinesOf(_lib().node_surface_edges(this.scene._handle, this.index)); }
  /** Its edges as the exact curves where the reader has them without meshing (a Rhino extrusion's rims are its profile), empty elsewhere: try it before `surfaceEdges`, whose trims are thinned to the mesh tolerance. The same segments as `edgeBeziers`, in the same space -- not the surfaces' frame. */
  surfaceEdgeBeziers() { return _beziersOf(_lib().node_surface_edge_beziers(this.scene._handle, this.index)); }
  /** edgeColours() for surfaceEdges(). */
  surfaceEdgeColours() { return _edgeColoursOf(_lib().node_surface_edge_colors(this.scene._handle, this.index)); }
  /** Its isocurves from its trimmed surfaces, clipped to the trims, without meshing; in the surfaces' frame. */
  surfaceIsocurves() { return _polylinesOf(_lib().node_surface_isocurves(this.scene._handle, this.index)); }
  /** Where the segment `from`..`to` (in the surfaces' frame) first meets its surfaces, `[x, y, z]`, or null. */
  surfacePick(from, to) {
    const a = Float64Array.from(from), b = Float64Array.from(to);
    if (a.length !== 3 || b.length !== 3) throw new CadaclysmError('surfacePick: from and to are three numbers each');
    const out = new Float64Array(3);
    return _lib().node_surface_pick(this.scene._handle, this.index, a, b, out) ? Array.from(out) : null;
  }
  /** A coarse, unwelded mesh over its surfaces for ray tracing and distance fields, `cells` by `cells` a face; built once per part; empty without surfaces. */
  surfaceProxyMesh(cells) { return _meshOf(_lib().node_surface_proxy_mesh(this.scene._handle, this.index, cells)); }
  /** About how many triangles `mesh()` would give, without building it; -1 where the reader cannot say. */
  get triangleEstimate() { return Number(_lib().node_triangle_estimate(this.scene._handle, this.index)); }
  /** Write this node's own mesh (no placement) in one of `meshFormats()`; throws if it draws nothing. */
  saveMesh(filePath, format = 'stl') {
    if (!_lib().node_save_mesh(this.scene._handle, this.index, String(filePath), format)) {
      throw new CadaclysmError(_lastError() || `could not write ${filePath}`);
    }
  }
  async meshAsync() { const m = await this.scene._async('meshAsync', { op: 'mesh', node: this.index }); return new Mesh(m.positions, m.normals, m.uvs, m.colors, m.indices, m.vertexCount, m.indexCount); }
  /** `mesh64()`, on the worker thread. */
  async meshAsync64() {
    const m = await this.scene._async('meshAsync64', { op: 'mesh64', node: this.index });
    return m == null ? null : new Mesh64(m.positions, m.normals, m.uvs, m.colors, m.indices, m.vertexCount, m.indexCount);
  }
  async meshLodAsync(level) { const m = await this.scene._async('meshLodAsync', { op: 'meshLod', node: this.index, level }); return new Mesh(m.positions, m.normals, m.uvs, m.colors, m.indices, m.vertexCount, m.indexCount); }
  async saveMeshAsync(filePath, format = 'stl') { await this.scene._async('saveMeshAsync', { op: 'saveMesh', node: this.index, path: String(filePath), format }); }
  /**
   * This node's own wireframe as SVG text, in its own frame -- `Scene.svgText`'s
   * `options` (see `svgOptionsDefaults`), read from just this node rather than
   * every placement.
   */
  svgText(options = {}) {
    const raw = _svgOptions(options, this.scene._defaultUp());
    const ptr = _lib().node_svg_text(this.scene._handle, this.index, raw);
    if (ptr == null) throw new CadaclysmError(_lastError() || 'svg');
    return _text(ptr);
  }
  /**
   * This node's silhouette -- where its surfaces turn away from the eye, which no edge of it lies
   * on -- as rational cubic Beziers in `double`, from the camera `options` describes (see
   * `svgOptionsDefaults`): `view`, `azimuth`, `elevation`, `up`, `fov`, and `width` with
   * `tolerance`, which the library reads together as the page fraction `tolerance / width`.
   * Nothing else in the options changes the curves.
   *
   * A `Beziers64` whose arrays are the caller's own: the library keeps one silhouette slot per
   * scene and the next silhouette call on that scene -- for any node -- overwrites it, and
   * `koffi.decode` (`_doubles`) copies out of that slot, so a later call leaves this answer alone.
   *
   * A body with no silhouette (every face planar) answers `count` 0 with empty arrays, which is
   * not an error; a refused option, a body with no measurable geometry or a node holding no shape
   * of its own throws a `CadaclysmError`.
   */
  silhouetteBeziers(options = {}) {
    const raw = _svgOptions(options, this.scene._defaultUp());
    const curves = _lib().node_silhouette_beziers(this.scene._handle, this.index, raw);
    if (curves.points == null || curves.count === 0) {
      // The call clears the thread's error at entry and the empty answer sets none: a reason
      // here is this call's own refusal, none is the empty answer.
      const reason = _lastError();
      if (reason) throw new CadaclysmError(reason);
      return new Beziers64(new Float64Array(0), new Float64Array(0), 0);
    }
    return _beziers64Of(curves);
  }
  /** `svgText(options)` written to `filePath` by the library itself. */
  svg(filePath, options = {}) {
    const raw = _svgOptions(options, this.scene._defaultUp());
    if (!_lib().node_svg(this.scene._handle, this.index, String(filePath), raw)) {
      throw new CadaclysmError(_lastError() || `could not write ${filePath}`);
    }
  }
  /** `svgText`, on the worker thread. `options` is validated and packed here, on the
   * caller's thread, on purpose -- unlike `openAsync`, a bad option (an unknown `view`,
   * an out-of-range `fov` the library itself refuses) fails fast, before a message
   * ever reaches the worker. */
  async svgAsync(options = {}) {
    const raw = _svgOptions(options, this.scene._defaultUp());
    return this.scene._async('svgAsync', { op: 'svg', node: this.index, options: raw });
  }
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
    // Items of a view that show this scene go first: the view reads it in place until they do.
    // Looked up, never resolved: a cadaclysm.js copied without its view module has nothing to release.
    const viewModule = require.cache[path.join(__dirname, 'cadaclysm_view.js')];
    if (viewModule) viewModule.exports._release(this);
    const pointer = this._pointer;
    this._pointer = null;
    if (_finalizer) _finalizer.unregister(this);
    _lib().close(pointer);
  }
  [DISPOSE]() { this.close(); }
  /** Draw it with the view library in use: on the wgpu library, in the one shared window (returns at once); elsewhere, a still. Options as `ShowOptions`. */
  show(options = {}) { return require('./cadaclysm_view')._present(this, { ...options, up: options.up ?? this._defaultUp() }, 'show'); }
  /** Orbit it until the window is closed; the camera it was left at, and the last pick. */
  view(options = {}) { return require('./cadaclysm_view')._present(this, { ...options, up: options.up ?? this._defaultUp() }, 'view'); }
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
  /**
   * What the file declares about its own precision, `{ absolute, angular }`: the absolute
   * tolerance in the file's own unit (beside `metresPerUnit`, whatever convention the scene was
   * opened into) and the angular one in radians, null for one it does not declare -- a 3dm's
   * units and tolerances, STEP's uncertainty, SAT's `resabs`, IGES's resolution; other formats
   * declare nothing. Each body read from the file carries a copy, which the kernel's verbs given
   * a null tolerance work from.
   */
  get tolerances() {
    const absolute = new Float64Array(1), angular = new Float64Array(1);
    if (!_lib().tolerances(this._handle, absolute, angular)) throw new CadaclysmError('tolerances: the scene is closed');
    const declared = (v) => (Number.isNaN(v) ? null : v);
    return Object.freeze({ absolute: declared(absolute[0]), angular: declared(angular[0]) });
  }
  /** The whole document's box, which meshes all of it. */
  get bounds() { const b = _lib().bounds(this._handle); return new Bounds(b.min, b.max); }
  /** `bounds` in `double`: the same union box, unnarrowed. **This meshes all of it.** */
  get bounds64() { const b = _lib().bounds64(this._handle); return new Bounds64(b.min, b.max); }
  /** The 4x4 (16 floats, column-major) that puts `Node.surfaces()` in the space everything else is in. */
  get surfaceMatrix() { const out = new Float32Array(16); _lib().surface_matrix(this._handle, out); return out; }
  /**
   * `'y'` or `'z'`: which axis is up by default, from `this.convention` --
   * `Convention.UNITY` and `Convention.Y_UP` give `'y'`, every other
   * convention `'z'`. What `SvgOptions.up` falls back to when left out.
   * `Convention.FILE_UNITS`/`Convention.UV_WORLD` are masked out first, since
   * they OR into the packed convention this scene carries.
   */
  _defaultUp() {
    const base = this.convention & ~(Convention.FILE_UNITS | Convention.UV_WORLD);
    return base === Convention.UNITY || base === Convention.Y_UP ? 'y' : 'z';
  }
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
  /** The file's mechanism: each rigid body, from `link_count`/`link_name`. */
  links() {
    const out = [];
    for (let i = 0, n = _lib().link_count(this._handle); i < n; i++) out.push(new Link(this, i));
    return out;
  }
  /** The file's mechanism: each connection between two links. */
  joints() {
    const out = [];
    for (let i = 0, n = _lib().joint_count(this._handle); i < n; i++) out.push(new Joint(this, i));
    return out;
  }
  /** The file's named mechanism states, e.g. STEP's `MECHANISM_STATE_REPRESENTATION`.
   *  Empty for a file that records none. */
  states() {
    const out = [];
    for (let i = 0, n = _lib().state_count(this._handle); i < n; i++) out.push(_readState(this, i));
    return out;
  }
  /** The file's motion sequences, in file order. Empty for a file that records none. */
  sequences() {
    const out = [];
    for (let i = 0, n = _lib().sequence_count(this._handle); i < n; i++) out.push(new Sequence(this, i));
    return out;
  }
  /** The file's IFC work schedules, in file order. Empty for a file that records none. */
  schedules() {
    const out = [];
    for (let i = 0, n = _lib().schedule_count(this._handle); i < n; i++) out.push(new WorkSchedule(this, i));
    return out;
  }
  /** The link the file declares as the mechanism's base, or null when it declares
   *  none (the default ground is then the link on the most joints; see `pose`). */
  get base() {
    const index = _lib().kinematics_base(this._handle);
    return index === NONE ? null : new Link(this, index);
  }
  /**
   * The mechanism posed by `values`: an iterable of `[Joint, sequence of numbers]`
   * rows -- exactly `StateValue`'s shape, so `pose(state.values)` poses like
   * `poseState(state)` -- with `ground` (a `Link`, or null for the default ground)
   * held fixed. Values outside a freedom's range are used as given and reported in
   * the answer's `outOfRange`.
   *
   * Throws `CadaclysmError` on a bad row (a joint given twice, one with the wrong
   * number of values, ...) or a file with no mechanism, carrying
   * `cadaclysm_last_error`'s text unchanged.
   */
  pose(values = [], ground = null) {
    const rows = Array.from(values, (row) => (row instanceof StateValue ? [row.joint, row.values] : row));
    const n = rows.length;
    const joints = new Uint32Array(n);
    const counts = new Uint32Array(n);
    const flat = [];
    rows.forEach(([joint, rowValues], i) => {
      joints[i] = joint.index;
      counts[i] = rowValues.length;
      for (const v of rowValues) flat.push(v);
    });
    const groundIndex = ground === null ? NONE : ground.index;
    const ptr = _lib().pose(this._handle, joints, counts, new Float64Array(flat), n, groundIndex);
    if (!ptr) throw new CadaclysmError(_lastError());
    return _copyPose(this, ptr);
  }
  /** The mechanism posed by `state`'s values, with `ground` held fixed as `pose` does.
   *  Throws `CadaclysmError` as `pose` does. */
  poseState(state, ground = null) {
    const groundIndex = ground === null ? NONE : ground.index;
    const ptr = _lib().pose_state(this._handle, state.index, groundIndex);
    if (!ptr) throw new CadaclysmError(_lastError());
    return _copyPose(this, ptr);
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
  /** `realizeAll` leaving alone every node that carries surfaces when `skipSurfaced` is true; returns how many were built. */
  realizeMeshes(skipSurfaced = true) { return _lib().realize_meshes(this._handle, skipSurfaced ? 1 : 0); }
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
  // -- svg --
  /**
   * Every visible placement's wireframe as SVG text, from the camera
   * `options` describes (see `svgOptionsDefaults`) -- the library's own
   * camera, not a viewer. Borrowed by the library: copied out before this
   * returns, and replaced by this scene's next `svgText`/`svg` call.
   */
  svgText(options = {}) {
    const raw = _svgOptions(options, this._defaultUp());
    const ptr = _lib().scene_svg_text(this._handle, raw);
    if (ptr == null) throw new CadaclysmError(_lastError() || 'svg');
    return _text(ptr);
  }
  /** `svgText(options)` written to `filePath` by the library itself. */
  svg(filePath, options = {}) {
    const raw = _svgOptions(options, this._defaultUp());
    if (!_lib().scene_svg(this._handle, String(filePath), raw)) {
      throw new CadaclysmError(_lastError() || `could not write ${filePath}`);
    }
  }
  /** `svgText`, on the worker thread. `options` is validated and packed on the caller's
   * thread first (fail fast), unlike `openAsync`, which forwards its options unchecked. */
  async svgAsync(options = {}) {
    const raw = _svgOptions(options, this._defaultUp());
    return this._async('svgAsync', { op: 'svg', options: raw });
  }
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
  [DISPOSE]() { this.free(); }
}

// ---- the FEM surface mesh ---------------------------------------------------

/**
 * One B-rep edge of a FEM mesh: the chain of nodes along it, and where that chain
 * breaks. Plain data, copied out of the handle.
 *
 * `nodes` are this mesh's node indices in order along the edge, its end vertices
 * included; a closed edge repeats no node. **`runs` says where the chain breaks**:
 * read `nodes.subarray(runs[i], runs[i + 1])` (the last run to the end) as one
 * polyline and join nothing across a run boundary -- `chains()` does exactly that.
 * The two ends either side of a boundary are two points of the edge with no mesh
 * edge between them: a crack along the edge, or a stretch of it the mesher sampled
 * on one face only. `[0]` is the ordinary answer, and a caller reading `nodes` as
 * one polyline without looking here silently jumps the gap.
 *
 * `faces` is `[faceA, faceB]` and `ends` is `[endA, endB]`, the second of each
 * being `NONE` where there is none -- an open body's rim, or both ends at one
 * vertex (a closed edge, a circle's rim, a full-turn seam). **`0` is a real face
 * and a real vertex, not a sentinel.** Which end comes first is the first trim's
 * direction and means nothing else: the pair bounds the edge, it does not orient
 * it.
 *
 * `closed` where the nodes make one loop -- never where there is more than one
 * run. `seam` where one face bounds the edge twice, a closed surface's seam rather
 * than a real boundary; both `faces` are then that same face.
 *
 * `id` is **the body's own edge id**, not this mesh's edge index: `FemMesh.edges()`
 * is a densely renumbered subset of the body's edges, ascending by id, with every
 * edge collapsed to a point left out, so edge 0 of a STEP body's mesh routinely has
 * an `id` in the hundreds. Everything else that names an edge here means the index
 * -- a `nodeKind()` of 1 read through `nodeEntity()`, the third number of an
 * `openEdges()` or `foldedEdges()` row, and the `edge_<i>` physical group of
 * `mshText()` -- and this is the one way back from any of them to the topology the
 * file wrote.
 */
class FemEdge {
  constructor(id, nodes, runs, faces, ends, closed, seam) {
    this.id = id; this.nodes = nodes; this.runs = runs;
    this.faces = faces; this.ends = ends; this.closed = closed; this.seam = seam;
  }
  /**
   * `nodes` cut into one polyline per run: `runs.length` of them, together holding
   * every node once, and nothing joined across a boundary. Views into `nodes`
   * (`subarray`), so they cost nothing.
   */
  chains() {
    const out = [];
    for (let i = 0; i < this.runs.length; i++) {
      out.push(this.nodes.subarray(this.runs[i], i + 1 < this.runs.length ? this.runs[i + 1] : this.nodes.length));
    }
    return out;
  }
}

/** A `CadaclysmFemEdge` as a `FemEdge`. */
function _femEdgeOf(raw) {
  return new FemEdge(
    raw.id,
    _uint32s(raw.nodes, raw.node_count) ?? new Uint32Array(0),
    _uint32s(raw.runs, raw.run_count) ?? new Uint32Array(0),
    [raw.face_a, raw.face_b], [raw.end_a, raw.end_b],
    Boolean(raw.closed), Boolean(raw.seam),
  );
}

/**
 * One B-rep vertex of a FEM mesh: the node the mesh put there, if any, and where
 * the topology says it is, if that is known. Plain data.
 *
 * `node` is the mesh node at this vertex, or `NONE` where the mesh has none there.
 * **A sentinel here is ordinary, not a fault**: the analysis rebuilds a vertex
 * wherever two trims meet, and a pole's polyline runs give a sphere 48 of them
 * where the mesh has 2 points, so a caller walking these skips the sentinel rather
 * than treating it as a gap.
 *
 * `point` is where the vertex is, in the same space and under the same placement as
 * `FemMesh.nodes()` -- the file's own vertex rather than a mesh node, so the two can
 * differ by the reader's rounding. **Meaningless unless `hasPosition`**: it is
 * `[0, 0, 0]` then, which is a point no geometry has and which a solver would take
 * for a node at the origin.
 */
class FemVertex {
  constructor(node, point, hasPosition) { this.node = node; this.point = point; this.hasPosition = hasPosition; }
}

/** A `CadaclysmFemVertex` as a `FemVertex`. */
function _femVertexOf(raw) {
  return new FemVertex(raw.node, Float64Array.from(raw.point), Boolean(raw.has_position));
}

/**
 * One flattened crack census, row by row: `read(i, a, b, edge)` fills three
 * `Uint32Array`s of one and says whether it could. The shape `openEdges()` and
 * `foldedEdges()` share, so the two cannot drift -- and a pure function, so
 * `test/fem.test.js` can drive it over rows no fixture in this repository produces.
 *
 * `what` reads as prose here (`fem mesh open edge 3`), following `cadaclysm.py`'s own
 * `_census`; the kernel module names the C entry point instead (`fem_mesh_open_edge 3`),
 * following *its* Python twin. The two ABIs' wrappers word their refusals differently and
 * each one matches its own side.
 */
function _censusRows(read, count, what) {
  const a = new Uint32Array(1), b = new Uint32Array(1), edge = new Uint32Array(1);
  const out = [];
  for (let i = 0; i < count; i++) {
    if (!read(i, a, b, edge)) throw new CadaclysmError(_lastError() || `fem mesh ${what} ${i}`);
    out.push([a[0], b[0], edge[0]]);
  }
  return out;
}

// The same backstop as a scene's and a `Meshlets`': a `FemMesh` the collector reaps
// unfreed is freed then; `free()` is the contract.
const _femFinalizer = typeof FinalizationRegistry === 'function'
  ? new FinalizationRegistry((pointer) => { try { _lib().fem_mesh_free(pointer); } catch (_) { /* the process is going anyway */ } })
  : null;

/**
 * One body meshed for a solver: nodes welded by bits, triangles wound outward,
 * every node tagged with the lowest-dimension B-rep entity it lies on, and every
 * crack reported rather than closed. Built by `Node.femMesh`, and **owned by
 * you**: `free()` it, or `using` it where the runtime supports explicit resource
 * management.
 *
 * **Every array here is a copy**, decoded at call time as `mesh()`'s typed arrays
 * are, not a view into the library's memory -- this wrapper has no borrowed-view
 * machinery at all. So an array in hand needs no care: it survives `free()`,
 * `Scene.close()` and the collector, and nothing of the library's is left in it to
 * go stale. The price is that each call copies again, so hold the array rather than
 * asking twice in a loop.
 *
 * A handle rather than a snapshot all the same, because the *counts* and the
 * records are read through it: a call on a freed mesh throws. The owner of the
 * memory behind it is this object and not the scene -- `Scene.close()` neither
 * frees a FEM mesh nor stales one, and meshing the body again does not either.
 */
class FemMesh {
  constructor(pointer) {
    this._pointer = pointer;
    if (_femFinalizer) _femFinalizer.register(this, pointer, this);
    // Read once, here. Every pointer in the view is built with the handle and good
    // until it is freed (nothing in this ABI is built lazily), so asking again per
    // accessor would be one C call per array for the same answer.
    const raw = {};
    if (!_lib().fem_mesh_view(pointer, raw)) {
      const why = _lastError() || 'fem mesh view';
      this.free();
      throw new CadaclysmError(why);
    }
    this._raw = raw;
  }
  get _handle() { if (this._pointer === null) throw new CadaclysmError('fem mesh: freed'); return this._pointer; }
  /** The view, the handle checked first: every pointer in it is the handle's, and a freed handle's point at nothing. */
  get _live() { if (this._pointer === null) throw new CadaclysmError('fem mesh: freed'); return this._raw; }
  /** Whether `free()` has run. */
  get freed() { return this._pointer === null; }
  /** Give the mesh back. Idempotent; the collector does it otherwise. Arrays already copied out are unaffected. */
  free() {
    if (this._pointer === null) return;
    const p = this._pointer; this._pointer = null;
    if (_femFinalizer) _femFinalizer.unregister(this);
    _lib().fem_mesh_free(p);
  }
  [DISPOSE]() { this.free(); }
  // -- the flat arrays, copied
  /** Every node's position, three doubles each -- placed, and in the space `Node.femMesh` and `fromMesh` describe. */
  nodes() { const raw = this._live; return _doubles(raw.nodes, raw.node_count * 3) ?? new Float64Array(0); }
  /** Three node indices a triangle, wound outward. */
  triangles() { const raw = this._live; return _uint32s(raw.triangles, raw.triangle_count * 3) ?? new Uint32Array(0); }
  /** Which B-rep face each triangle lies on, one per triangle, into `faceCount`. */
  triangleFace() { const raw = this._live; return _uint32s(raw.triangle_face, raw.triangle_count) ?? new Uint32Array(0); }
  /** What each node lies on -- 0 a vertex, 1 an edge, 2 a face -- one per node: the lowest-dimension entity, as Gmsh classifies. `nodeEntity()` says which. */
  nodeKind() { const raw = this._live; return _uint32s(raw.node_kind, raw.node_count) ?? new Uint32Array(0); }
  /** Which vertex, edge or face each node lies on, by the matching `nodeKind()`: an index into `vertices()`, into `edges()`, or into the body's faces. */
  nodeEntity() { const raw = this._live; return _uint32s(raw.node_entity, raw.node_count) ?? new Uint32Array(0); }
  // -- the topology
  /** The body's faces; `triangleFace()` and a `nodeKind()` of 2 index them. */
  get faceCount() { return this._live.face_count; }
  /**
   * One `FemEdge` per B-rep edge, in the order a `nodeKind()` of 1 indexes them.
   * Empty for a `fromMesh` body, which has no B-rep edges at all. **This list's own
   * numbering, not the body's**: each `FemEdge.id` carries the body's own edge id.
   */
  edges() {
    const l = _lib(), h = this._handle, out = [];
    for (let i = 0, n = this._raw.edge_count; i < n; i++) {
      const raw = {};
      if (!l.fem_mesh_edge(h, i, raw)) throw new CadaclysmError(_lastError() || `fem mesh edge ${i}`);
      out.push(_femEdgeOf(raw));
    }
    return out;
  }
  /** One `FemVertex` per B-rep vertex, in the order a `nodeKind()` of 0 indexes them. Empty for a `fromMesh` body. */
  vertices() {
    const l = _lib(), h = this._handle, out = [];
    for (let i = 0, n = this._raw.vertex_count; i < n; i++) {
      const raw = {};
      if (!l.fem_mesh_vertex(h, i, raw)) throw new CadaclysmError(_lastError() || `fem mesh vertex ${i}`);
      out.push(_femVertexOf(raw));
    }
    return out;
  }
  /**
   * Every crack, as `[a, b, brepEdge]`: a directed mesh edge `(a, b)` with no
   * `(b, a)`, and the B-rep edge both nodes lie on or `NONE` where they share none.
   *
   * **Empty unless the body's topology is closed -- for a B-rep body**, whose mesh
   * is otherwise not asked about at all: such a body reports `watertight` false with
   * this and `foldedEdges()` both empty, and *that trio together* says "not asked",
   * not "nothing found".
   *
   * **A `fromMesh` body is the other case, and the opposite one.** A bare mesh
   * carries no topology to say whether it ought to close, so its census always runs
   * over the welded triangles: an open render mesh reports its cracks here with
   * `watertight` false, a closed one reports `watertight` true, and an empty census
   * there really does mean "nothing found".
   */
  openEdges() {
    const l = _lib(), h = this._handle;
    return _censusRows((i, a, b, e) => l.fem_mesh_open_edge(h, i, a, b, e), this._live.open_edge_count, 'open edge');
  }
  /**
   * Every fold, as `openEdges()` reports a crack: a directed mesh edge used by more
   * than one triangle.
   *
   * **A body can be folded without being open**, and the closure census's own pinned
   * rows are folds rather than open cracks -- a solid no thicker than a line leaves
   * no hole for an open edge to find. A caller that checks only `openEdges()` calls
   * such a body sound.
   */
  foldedEdges() {
    const l = _lib(), h = this._handle;
    return _censusRows((i, a, b, e) => l.fem_mesh_folded_edge(h, i, a, b, e), this._live.folded_edge_count, 'folded edge');
  }
  /**
   * Every pair of triangles that pass through each other, as `[a, b]` with `a < b`,
   * sorted: an edge of one through the other's interior. Their B-rep faces are
   * `triangleFace()[a]` and `[b]`.
   *
   * **Computed for every body, open or closed.** The census `watertight`,
   * `openEdges()` and `foldedEdges()` report is topological and cannot see a surface
   * passing through itself; a mesh is ready for a volume mesher when it is
   * `watertight` **and** this is empty -- Gmsh refuses one that crosses. A copy.
   */
  crossings() {
    const l = _lib(), h = this._handle;
    const count = l.fem_mesh_crossing_count(h);
    const a = new Uint32Array(1), b = new Uint32Array(1);
    const out = [];
    for (let i = 0; i < count; i++) {
      if (!l.fem_mesh_crossing(h, i, a, b)) throw new CadaclysmError(_lastError() || `fem mesh crossing ${i}`);
      out.push([a[0], b[0]]);
    }
    return out;
  }
  // -- the summary
  /**
   * The welded mesh closes -- and, for a B-rep body, so does the topology behind it.
   * **False for every B-rep body whose topology is not closed**, whose mesh is then
   * not asked about at all. A `fromMesh` body has no topology to ask of, so this says
   * only that its triangles close; `openEdges()` says what an empty census beside
   * each does and does not mean.
   */
  get watertight() { return Boolean(this._live.watertight); }
  /**
   * This came from the scene's own mesh rather than from a brep: one face, every node
   * on face 0, no edges and no vertices.
   *
   * **It is also which space the mesh is in.** A B-rep body's FEM mesh is in the
   * file's own units and axes, whatever `Convention` the scene was opened with,
   * because it is taken off the brep. A node with no brep falls back to the scene's
   * mesh, which *is* converted, so it comes back in the scene's convention, wound
   * counter-clockwise about the outward normal even where the convention winds the
   * other way. Under a non-NATIVE convention those are two different spaces.
   *
   * **And it is which contract `watertight`, `openEdges()` and `foldedEdges()` are
   * reporting under**: read `openEdges()`.
   */
  get fromMesh() { return Boolean(this._live.from_mesh); }
  /** The smallest interior angle of any triangle, in degrees. */
  get minAngle() { return this._live.min_angle; }
  /** The triangle with that angle: an index into `triangles()`. */
  get worstTriangle() { return this._live.worst_triangle; }
  /**
   * The longest triangle edge, placed. **The figure to check against
   * `Node.femMesh`'s `maxSize`, and the only one that says what the mesh actually
   * is**: `maxSize` bounds the boundary segments and merely targets the interior, and
   * one small enough to hit the mesher's own piece and station ceilings is not
   * honoured at all.
   */
  get longestEdge() { return this._live.longest_edge; }
  // -- out
  /**
   * The mesh as Gmsh 4.1 ASCII `.msh` text: an entity per B-rep vertex, edge and
   * face, a volume where the body closes, and a physical group naming each.
   *
   * **The library's text is borrowed from this handle** and replaced by the next
   * call on it -- this ABI's convention, and the opposite of the kernel library's,
   * where `cadaclysm_blacksmith_fem_mesh_msh_text` hands over an owned string to
   * free. Nothing here has to free anything either way: koffi copies a `char *` into
   * JavaScript on the way out, so what comes back is a string of your own that
   * outlives the handle.
   *
   * **No unlicensed notice is printed here.** `Node.femMesh` gave it once when the
   * mesh was built, and this ABI deliberately does not repeat it on either `.msh`
   * call -- where the kernel library notices on both of its writers and *not* on its
   * constructor. Each matches its own siblings, so moving the call to look like the
   * other side would break a convention.
   *
   * Throws `CadaclysmError` for a mesh the writer refuses, naming the field it cannot
   * honour, and for a freed handle.
   */
  mshText() {
    const raw = _lib().fem_mesh_msh_text(this._handle);
    if (raw == null) throw new CadaclysmError(_lastError() || 'msh text');
    return String(raw);
  }
  /**
   * `mshText()` written to `filePath` by the library itself: the same bytes from the
   * same writer, straight to the file rather than through the borrowed slot, so a
   * `mshText()` call on this handle from another thread cannot free the text under
   * the write. No notice here either; see `mshText`.
   */
  saveMsh(filePath) {
    if (!_lib().fem_mesh_save_msh(this._handle, String(filePath))) {
      throw new CadaclysmError(_lastError() || `could not write ${filePath}`);
    }
  }
  toString() {
    if (this.freed) return 'FemMesh(freed)';
    const raw = this._raw;
    return `FemMesh(nodes=${raw.node_count}, triangles=${raw.triangle_count}, watertight=${Boolean(raw.watertight)}, fromMesh=${Boolean(raw.from_mesh)})`;
  }
}

/** A `CadaclysmFemOptions` object: the library's own defaults, then `tolerance` and `maxSize`. */
function _femOptions(tolerance, maxSize) {
  const o = {};
  // `init` writes `sizeof(CadaclysmFemOptions)` bytes as the *library* knows that
  // type, into the struct declared above -- which is why `tests/bindings.rs` pins
  // the two field for field. `size` is then set to this declaration's own sizeof,
  // which is what the growth rule asks of a caller.
  _lib().fem_options_init(o);
  o.size = koffi.sizeof(CadaclysmFemOptions);
  o.tolerance = Number(tolerance);
  o.max_size = Number(maxSize);
  return o;
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
  CadaclysmError, NONE, Convention, ValueKind, SvgView,
  libraryPath, flavour, features, version, buildDate, license, licenseInfo, licenseNoticeCount, meshFormats, formats, lodLevels,
  svgOptionsDefaults,
  _lib, _text, _lastError, _floats, _uint32s, _doubles, _searchedPaths, _notFoundMessage, _libraryNames: libraryNames,
  Bounds, Bounds64, Attribute, Brep, HealthReport, FreeEdge, FreeWire, SmallFeature, Cracks, HealReport, HealFix, HealRefusal,
  _healthReport, _healReport, _healFlags, Placement, Node, Link, Joint, Pair, Freedom, State, StateValue, Segment, Sequence, ElementState, TaskTime, TaskLink, Task, WorkSchedule, Pose, Scene, open, openMemory, _openRaw, openAsync, openMemoryAsync, declaredSchema, resolveSchema, _options, _rows, _attribute,
  Mesh, Mesh64, Polylines, Beziers, Beziers64, Face, Surfaces, Collision, CollisionHull, Meshlets, pickFile, pickSave,
  FemMesh, FemEdge, FemVertex,
  _meshOf, _mesh64Of, _polylinesOf, _beziersOf, _beziers64Of, _surfacesOf, _svgOptions,
  _femEdgeOf, _femVertexOf, _censusRows, _femOptions,
};
