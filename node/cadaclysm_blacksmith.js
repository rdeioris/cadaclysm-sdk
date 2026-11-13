'use strict';
/**
 * The cadaclysm_blacksmith C ABI, as JavaScript objects: this file is the whole binding.
 *
 *     const { Axis, Profile, Selector, Workplane } = require('cadaclysm/blacksmith');
 *     const outline = Profile.rect(80, 40).withHole(Profile.circle(4));
 *     const plate = Workplane.xy().extrude(outline, 6).solid();
 *     const pin = Workplane.fromSolid(plate).faces(Selector.max(Axis.Z)).workplane().cylinder(4, 10).solid();
 *     const part = plate.join(pin);
 *     const corners = part.edges().filter((e) => e.isLine && Math.abs(e.direction[2]) > 0.99);
 *     part.fillet(corners, 1).step('plate.stp');
 *
 * Every array handed back is a copy. A build call makes a fresh `Solid`; every
 * step throws `BuildError` at once with the library's own text. `join`/`cut`/
 * `common` default `tolerance` to 0.05 (the tolerance the crate's own boolean
 * tests run at); `fillet`, `chamfer` and `shell` to 1e-6.
 *
 * Tolerances: every default stays what it is -- `a.join(b)` still means 0.05. Passing
 * `null` (or 0) as the `tolerance` of a verb that takes a distance tolerance -- a
 * boolean, fillet, shell, split, section, hit test, mesh, curve fit or profile verb --
 * opts into the model's own: `effectiveTolerance(...solids)`, the larger of the
 * loosest absolute tolerance the inputs declare and the option `tolerance.relative`
 * (default 1e-4) times their size. A solid declares what its file said
 * (`Solid.tolerances`, null for what it did not say; the reader's `Scene.tolerances` is
 * the file's), every verb's result inherits the loosest of its inputs', and
 * `Solid.withTolerances` sets it. `tolerance.angular` (default one degree) stands in
 * where nothing declares an angle.
 *
 * In a browser the same file runs over the wasm build of the library
 * (crates/cadaclysm-wasm, as the site's notebook loads it): `globalThis.cadaclysm`
 * holds the module's exports, `require` is the page's and hands back null for
 * koffi, and `_lib()` returns the shim in `_wasmLibrary` instead of the DLL's
 * function table. Everything above `_lib()` is the same code either way; what
 * needs a file system (`step`, `sat`, `Solid.open`) reads and writes whatever
 * `fs` the page provides, and the async verbs, which need a worker thread, throw.
 */
const fs = require('node:fs');
const path = require('node:path');
// `using x = ...` looks up Symbol.dispose: Node 22 aliases it to Symbol.for('nodejs.dispose'),
// a V8 with its own Symbol.dispose does not, so name the one this runtime uses.
const DISPOSE = typeof Symbol.dispose === 'symbol' ? Symbol.dispose : Symbol.for('nodejs.dispose');
// Node's `require` throws where koffi is not installed, and the wasm route has no use for
// it: kept as the reason `_lib()` gives if it is asked for the native library after all.
let _koffiMissing = null;
const koffi = (() => { try { return require('koffi'); } catch (e) { _koffiMissing = e; return null; } })() ?? _noKoffi();

/**
 * A kernel refusal, with the library's own text. `ids` is the sketch ids a `Sketch` refusal names --
 * the constraints a new constraint, value or reference conflicts with, or the entities still
 * using a point -- and empty for every other refusal.
 */
class BuildError extends Error {
  constructor(message, ids = []) { super(message); this.name = 'BuildError'; this.ids = ids; }
}

const NONE = 0xFFFFFFFF;
const UNITS = { m: 0, mm: 1, in: 2 };

// ---- finding the library ---------------------------------------------------

/**
 * The libraries that carry the kernel, in the order they are looked for: the single
 * library's flavours that hold it, then the separate library of earlier releases.
 * As `cadaclysm-capi-rt`'s `KERNEL_STEMS`.
 */
const LIBRARY_STEMS = ['cadaclysm', 'cadaclysm_kernel_reader', 'cadaclysm_kernel', 'cadaclysm_blacksmith'];

/** `LIBRARY_STEMS` as this platform names the files. */
function libraryNames() {
  if (process.platform === 'win32') return LIBRARY_STEMS.map((s) => `${s}.dll`);
  const suffix = process.platform === 'darwin' ? 'dylib' : 'so';
  return LIBRARY_STEMS.map((s) => `lib${s}.${suffix}`);
}

function ancestors(dir) {
  const out = [];
  for (let d = dir; ; d = path.dirname(d)) { out.push(d); if (path.dirname(d) === d) return out; }
}

function _searchedPaths() {
  const places = [__dirname];
  for (const a of ancestors(__dirname)) places.push(path.join(a, 'lib'));
  for (const a of ancestors(__dirname)) places.push(path.join(a, 'target', 'release'), path.join(a, 'target', 'debug'));
  // Each place is asked for every name, in order: one library of any flavour
  // that holds the kernel, else the separate library of earlier releases.
  return places.flatMap((place) => libraryNames().map((name) => path.join(place, name)));
}

function _notFoundMessage(searched) {
  return `none of ${libraryNames().join(', ')} found. Looked in:\n` + searched.map((p) => `    ${p}\n`).join('')
    + 'Build it with:\n    cargo build --release -p cadaclysm-blacksmith-capi\n'
    + 'or run fetch.py in an SDK checkout, or point CADACLYSM_LIBRARY (or, for the separate kernel library, CADACLYSM_BLACKSMITH_LIBRARY) at it.';
}

/**
 * Where the shared library is: `CADACLYSM_BLACKSMITH_LIBRARY` (the separate kernel
 * library's variable), then `CADACLYSM_LIBRARY` -- each a file or a directory --
 * then beside this file, an ancestor's `lib/`, an ancestor's `target/release` or
 * `target/debug`. Each place is asked for every name in `LIBRARY_STEMS`, in order.
 */
function libraryPath() {
  let variable = 'CADACLYSM_BLACKSMITH_LIBRARY';
  let override = process.env[variable];
  if (!override) { variable = 'CADACLYSM_LIBRARY'; override = process.env[variable]; }
  if (override) {
    const separateReader = libraryNames()[0].replace('cadaclysm', 'cadaclysm_capi');
    if (fs.existsSync(override) && fs.statSync(override).isDirectory()) {
      for (const name of libraryNames()) if (fs.existsSync(path.join(override, name))) return path.join(override, name);
    } else if (fs.existsSync(override) && !(variable === 'CADACLYSM_LIBRARY' && path.basename(override) === separateReader)) {
      return override;
    }
    // `CADACLYSM_LIBRARY` was the reader's alone before the single library: naming the
    // separate reader, or a directory with none of the kernel's names, it is not for this
    // library, and the search goes on.
    if (!(variable === 'CADACLYSM_LIBRARY' && fs.existsSync(override))) {
      throw new BuildError(`${variable}=${override} names nothing that exists`);
    }
  }
  const searched = _searchedPaths();
  for (const c of searched) if (fs.existsSync(c)) return c;
  throw new BuildError(_notFoundMessage(searched));
}

/**
 * `schemas/ap203.exp`: `CADACLYSM_SCHEMAS/ap203.exp` if set, else `schemas/ap203.exp` in any ancestor.
 *
 * The `ap203.exp` file this finds is no longer needed: the kernel writes against its
 * built-in AP203 when no schema is given. This function stays for compatibility and the
 * parity gates; nothing here calls it to write STEP any more.
 */
function defaultSchema() {
  const candidates = [];
  if (process.env.CADACLYSM_SCHEMAS) candidates.push(path.join(process.env.CADACLYSM_SCHEMAS, 'ap203.exp'));
  for (const a of ancestors(__dirname)) candidates.push(path.join(a, 'schemas', 'ap203.exp'));
  for (const c of candidates) if (fs.existsSync(c)) return c;
  throw new BuildError('ap203.exp not found (none is needed to write STEP: leave schema out for the built-in '
    + 'AP203, or pass a schema name, a .exp path or EXPRESS text)');
}

// ---- the ABI's types -------------------------------------------------------
// Declared by the header's names, in the header's field order, one field per
// line: `tests/bindings.rs` compares these blocks with the header.

koffi.opaque('CadaclysmBlacksmithAssembly');
koffi.opaque('CadaclysmBlacksmithCheck');
koffi.opaque('CadaclysmBlacksmithClashes');
koffi.opaque('CadaclysmBlacksmithClassifier');
koffi.opaque('CadaclysmBlacksmithCollider');
koffi.opaque('CadaclysmBlacksmithCollisions');
koffi.opaque('CadaclysmBlacksmithDocument');
koffi.opaque('CadaclysmBlacksmithFemMesh');
koffi.opaque('CadaclysmBlacksmithHeal');
koffi.opaque('CadaclysmBlacksmithHealth');
koffi.opaque('CadaclysmBlacksmithHistory');
koffi.opaque('CadaclysmBlacksmithHits');
koffi.opaque('CadaclysmBlacksmithInterpolator');
koffi.opaque('CadaclysmBlacksmithIntersection');
koffi.opaque('CadaclysmBlacksmithJob');
koffi.opaque('CadaclysmBlacksmithMeshThicknesses');
koffi.opaque('CadaclysmBlacksmithNurbsCurve');
koffi.opaque('CadaclysmBlacksmithOperations');
koffi.opaque('CadaclysmBlacksmithPath');
koffi.opaque('CadaclysmBlacksmithProfile');
koffi.opaque('CadaclysmBlacksmithProfileList');
koffi.opaque('CadaclysmBlacksmithPrograms');
koffi.opaque('CadaclysmBlacksmithProjector');
koffi.opaque('CadaclysmBlacksmithTriangleMesh');
koffi.opaque('CadaclysmBlacksmithHlr');
koffi.opaque('CadaclysmBlacksmithPage');
koffi.opaque('CadaclysmBlacksmithRTree');
koffi.opaque('CadaclysmBlacksmithRTreeHits');
koffi.opaque('CadaclysmBlacksmithRTreePairs');
koffi.opaque('CadaclysmBlacksmithRegions');
koffi.opaque('CadaclysmBlacksmithReport');
koffi.opaque('CadaclysmBlacksmithSamples');
koffi.opaque('CadaclysmBlacksmithSketch');
koffi.opaque('CadaclysmBlacksmithSolid');
koffi.opaque('CadaclysmBlacksmithStock');
koffi.opaque('CadaclysmBlacksmithSubd');
koffi.opaque('CadaclysmBlacksmithThicknessGauge');
koffi.opaque('CadaclysmBlacksmithThicknesses');
koffi.opaque('CadaclysmBlacksmithSweepPath');
koffi.opaque('CadaclysmBlacksmithSweptClashes');
koffi.opaque('CadaclysmBlacksmithTessellation');
koffi.opaque('CadaclysmBlacksmithTool');

const CadaclysmBlacksmithMesh = koffi.struct('CadaclysmBlacksmithMesh', {
  positions: 'const float *',
  normals: 'const float *',
  indices: 'const uint32_t *',
  vertex_count: 'uint32_t',
  index_count: 'uint32_t',
});
// f64 twin (Task 11 of the f64-twins plan): the same tessellation, unnarrowed positions
// and normals -- the index pointer is the very one CadaclysmBlacksmithMesh gives.
const CadaclysmBlacksmithMesh64 = koffi.struct('CadaclysmBlacksmithMesh64', {
  positions: 'const double *',
  normals: 'const double *',
  indices: 'const uint32_t *',
  vertex_count: 'uint32_t',
  index_count: 'uint32_t',
});
const CadaclysmBlacksmithPolylines = koffi.struct('CadaclysmBlacksmithPolylines', {
  points: 'const float *',
  offsets: 'const uint32_t *',
  point_count: 'uint32_t',
  polyline_count: 'uint32_t',
});
// One colour per polyline of edgePolylines(tolerance): count 0 (rgb null) where
// the solid has no edge paint at all; -1, -1, -1 for a polyline on no coloured edge.
const CadaclysmBlacksmithColours = koffi.struct('CadaclysmBlacksmithColours', {
  rgb: 'const double *',
  count: 'uint32_t',
});
// What a body measures, per unit density, each figure beside a bound on its own error. The four
// flags are int32 and come first, so every double after them is already eight-aligned and C adds no
// padding -- which is what lets koffi read it field for field. Pinned against the header by
// `cadaclysm-capi/tests/bindings.rs`.
const CadaclysmBlacksmithMassProperties = koffi.struct('CadaclysmBlacksmithMassProperties', {
  closed: 'int32_t',
  inverted: 'int32_t',
  accuracy_met: 'int32_t',
  from_mesh: 'int32_t',
  area: 'double',
  area_error: 'double',
  volume: 'double',
  volume_error: 'double',
  centroid: koffi.array('double', 3),
  centroid_error: 'double',
  inertia: koffi.array('double', 9),
  inertia_error: 'double',
  principal_moments: koffi.array('double', 3),
  principal_axes: koffi.array('double', 9),
});
// A closed body's box on its principal axes: `axes` row-major, row `i` axis `i`.
const CadaclysmBlacksmithOrientedBox = koffi.struct('CadaclysmBlacksmithOrientedBox', {
  centre: koffi.array('double', 3),
  axes: koffi.array('double', 9),
  half: koffi.array('double', 3),
});
// A measured length beside its error estimate; the two int32s are bools.
const CadaclysmBlacksmithLength = koffi.struct('CadaclysmBlacksmithLength', {
  length: 'double',
  error: 'double',
  accuracy_met: 'int32_t',
  from_polyline: 'int32_t',
});
// A point at an arc length: the point, the unit tangent, the curve parameter, the profile side
// (NONE on a solid's edge), the error estimate and a bool (int32) for a sampled polyline.
const CadaclysmBlacksmithAt = koffi.struct('CadaclysmBlacksmithAt', {
  point: koffi.array('double', 3),
  tangent: koffi.array('double', 3),
  parameter: 'double',
  segment: 'uint32_t',
  error: 'double',
  from_polyline: 'int32_t',
});
// A curve's bending at a parameter: kappa, the Frenet frame, the osculating circle's centre and a
// bool (int32) for whether there is one.
const CadaclysmBlacksmithCurvature = koffi.struct('CadaclysmBlacksmithCurvature', {
  kappa: 'double',
  tangent: koffi.array('double', 3),
  normal: koffi.array('double', 3),
  binormal: koffi.array('double', 3),
  centre: koffi.array('double', 3),
  has_centre: 'int32_t',
});
// How well two faces meet along their sides (`continuity`), one side of an N-sided patch's hole
// (a sheet's side, or a curve where `sheet` is null), what the patch reports, and what a join
// did; the C layout's own padding (a uint32_t before a double) is koffi's to place.
const CadaclysmBlacksmithContinuity = koffi.struct('CadaclysmBlacksmithContinuity', {
  gap: 'double',
  gap_at: koffi.array('double', 3),
  angle: 'double',
  angle_at: koffi.array('double', 3),
  curvature: 'double',
  curvature_at: koffi.array('double', 3),
  samples: 'uint32_t',
});
// How smoothly a curve runs through its own knots (`nurbs_curve_knot_continuity`): the largest
// tangent turn and curvature jump, each with its parameter and point -- 80 bytes, no padding.
const CadaclysmBlacksmithKnotContinuity = koffi.struct('CadaclysmBlacksmithKnotContinuity', {
  angle: 'double',
  angle_parameter: 'double',
  angle_at: koffi.array('double', 3),
  curvature: 'double',
  curvature_parameter: 'double',
  curvature_at: koffi.array('double', 3),
});
// Where a face's curvatures change sign (`curvature_turns`): seven counts, 28 bytes.
const CadaclysmBlacksmithCurvatureTurns = koffi.struct('CadaclysmBlacksmithCurvatureTurns', {
  gaussian_positive: 'uint32_t',
  gaussian_negative: 'uint32_t',
  gaussian_turns: 'uint32_t',
  mean_positive: 'uint32_t',
  mean_negative: 'uint32_t',
  mean_turns: 'uint32_t',
  samples: 'uint32_t',
});
// The worst highlight-line kink across an edge (`highlight_kink`): the angle, where, the light
// tube's point and direction, the samples -- 88 bytes with the tail padding.
const CadaclysmBlacksmithHighlightKink = koffi.struct('CadaclysmBlacksmithHighlightKink', {
  angle: 'double',
  at: koffi.array('double', 3),
  light_point: koffi.array('double', 3),
  light_direction: koffi.array('double', 3),
  samples: 'uint32_t',
});
const CadaclysmBlacksmithPatchBoundary =koffi.struct('CadaclysmBlacksmithPatchBoundary', {
  sheet: 'const CadaclysmBlacksmithSolid *',
  face: 'uint32_t',
  side: 'uint32_t',
  from: 'double',
  to: 'double',
  level: 'uint32_t',
  curve: 'const CadaclysmBlacksmithNurbsCurve *',
});
const CadaclysmBlacksmithPatchReport = koffi.struct('CadaclysmBlacksmithPatchReport', {
  faces: 'uint32_t',
  boundary: 'CadaclysmBlacksmithContinuity',
  internal: 'CadaclysmBlacksmithContinuity',
  corner_angle: 'double',
});
const CadaclysmBlacksmithJoinReport = koffi.struct('CadaclysmBlacksmithJoinReport', {
  sewn: 'uint32_t',
  naked_before: 'uint32_t',
  naked_after: 'uint32_t',
  refused: 'uint32_t',
  turned: 'uint32_t',
  worst_gap: 'double',
  closed: 'int32_t',
});
// One R-tree hit (search, within, nearest): the entry's id and the distance from the query point
// to its box, 0 for a search hit; and one overlapping pair of entry ids. Read out of an owned
// `RTreeHits` / `RTreePairs` list with `rtree_hits_at` / `rtree_pairs_at`.
const CadaclysmBlacksmithRTreeHit = koffi.struct('CadaclysmBlacksmithRTreeHit', {
  id: 'uint32_t',
  distance: 'double',
});
const CadaclysmBlacksmithRTreePair = koffi.struct('CadaclysmBlacksmithRTreePair', {
  a: 'uint32_t',
  b: 'uint32_t',
});
// One region of a solid (`finite` 0 for region 0, the infinite one; the box round its faces; how
// many face sides bound it and how many shells), and one of those sides: a face and `sense` +1
// where the region is in front of it, -1 behind. Read out of an owned `Regions` list with
// `regions_at` / `regions_side_at`.
const CadaclysmBlacksmithRegion = koffi.struct('CadaclysmBlacksmithRegion', {
  finite: 'int32_t',
  min: koffi.array('double', 3),
  max: koffi.array('double', 3),
  sides: 'uint32_t',
  shells: 'uint32_t',
});
const CadaclysmBlacksmithFaceSide = koffi.struct('CadaclysmBlacksmithFaceSide', {
  face: 'uint32_t',
  sense: 'int32_t',
});
// The closest points of two boundaries. `kind_*` are the library's **static** strings
// ("face", "edge", "vertex"), so `const char *` -- never `CadaclysmBlacksmithOwnedString`,
// which would hand them to `string_free`. `edge_*` is NONE where there is no fillet-table edge.
const CadaclysmBlacksmithClosest = koffi.struct('CadaclysmBlacksmithClosest', {
  distance: 'double',
  on_a: koffi.array('double', 3),
  on_b: koffi.array('double', 3),
  kind_a: 'const char *',
  index_a: 'uint32_t',
  edge_a: 'uint32_t',
  kind_b: 'const char *',
  index_b: 'uint32_t',
  edge_b: 'uint32_t',
  refined: 'int32_t',
});
// The nearest point of a solid (or one face) to a query point. `kind` is a static string, as
// `Closest`'s `kind_*` are; `edge` is NONE off an edge row, `uv` NaN off a face.
const CadaclysmBlacksmithPointFoot = koffi.struct('CadaclysmBlacksmithPointFoot', {
  distance: 'double',
  point: koffi.array('double', 3),
  kind: 'const char *',
  index: 'uint32_t',
  edge: 'uint32_t',
  uv: koffi.array('double', 2),
  normal: koffi.array('double', 3),
  refined: 'int32_t',
});
// The nearest points of two curves: side `a` the curve asked, side `b` the other.
const CadaclysmBlacksmithCurvePair = koffi.struct('CadaclysmBlacksmithCurvePair', {
  distance: 'double',
  t_a: 'double',
  point_a: koffi.array('double', 3),
  t_b: 'double',
  point_b: koffi.array('double', 3),
});
// The nearest points of a curve and a body: the curve's side, then the body's as a `PointFoot`;
// `crossing` 0 or 1 (koffi pads it to 144 bytes, as C does).
const CadaclysmBlacksmithCurveBodyFoot = koffi.struct('CadaclysmBlacksmithCurveBodyFoot', {
  distance: 'double',
  t: 'double',
  point_on_curve: koffi.array('double', 3),
  body: 'CadaclysmBlacksmithPointFoot',
  crossing: 'int32_t',
});
// The nearest point of a triangle mesh: `kind` 0 face, 1 edge, 2 vertex; an unused `vertices`
// slot is UINT32_MAX.
koffi.struct('CadaclysmBlacksmithMeshPoint', {
  point: koffi.array('double', 3),
  distance: 'double',
  triangle: 'uint32_t',
  kind: 'uint32_t',
  barycentric: koffi.array('double', 3),
  vertices: koffi.array('uint32_t', 2),
});
// The nearest points of a curve and a triangle mesh: the curve's side, then the mesh's as a mesh
// point; `crossing` 1 where the curve passes through the mesh.
koffi.struct('CadaclysmBlacksmithCurveMeshFoot', {
  distance: 'double',
  t: 'double',
  point_on_curve: koffi.array('double', 3),
  mesh: 'CadaclysmBlacksmithMeshPoint',
  crossing: 'int32_t',
});
// The nearest item of a set to a curve. Only the member `answer_kind` names is filled (0 `body`,
// 1 `pair`, 2 neither, 3 `mesh`); every byte of the others is zero -- a `kind` a null pointer --
// so it is never read. C writes the whole struct, `mesh` included.
const CadaclysmBlacksmithNearestObject = koffi.struct('CadaclysmBlacksmithNearestObject', {
  which: 'uint32_t',
  answer_kind: 'int32_t',
  distance: 'double',
  t: 'double',
  point_on_curve: koffi.array('double', 3),
  point_on_item: koffi.array('double', 3),
  body: 'CadaclysmBlacksmithCurveBodyFoot',
  pair: 'CadaclysmBlacksmithCurvePair',
  mesh: 'CadaclysmBlacksmithCurveMeshFoot',
});

const CadaclysmBlacksmithFaceTriangles = koffi.struct('CadaclysmBlacksmithFaceTriangles', {
  counts: 'const uint32_t *',
  face_count: 'uint32_t',
});
const CadaclysmBlacksmithEdge = koffi.struct('CadaclysmBlacksmithEdge', {
  kind: 'const char *',
  faces: 'const uint32_t *',
  face_count: 'uint32_t',
  segments: 'const double *',
  segment_count: 'uint32_t',
});
const CadaclysmBlacksmithPoint = koffi.struct('CadaclysmBlacksmithPoint', {
  x: 'double',
  y: 'double',
  z: 'double',
});
const CadaclysmBlacksmithSpot = koffi.struct('CadaclysmBlacksmithSpot', {
  loop_index: 'uint32_t',
  segment: 'uint32_t',
  t: 'double',
  face: 'uint32_t',
  u: 'double',
  v: 'double',
});
const CadaclysmBlacksmithHit = koffi.struct('CadaclysmBlacksmithHit', {
  run: 'bool',
  touch: 'bool',
  start: 'CadaclysmBlacksmithPoint',
  end: 'CadaclysmBlacksmithPoint',
  a_start: 'CadaclysmBlacksmithSpot',
  a_end: 'CadaclysmBlacksmithSpot',
  b_start: 'CadaclysmBlacksmithSpot',
  b_end: 'CadaclysmBlacksmithSpot',
});
const CadaclysmBlacksmithCurve = koffi.struct('CadaclysmBlacksmithCurve', {
  kind: 'const char *',
  origin: 'CadaclysmBlacksmithPoint',
  x: 'CadaclysmBlacksmithPoint',
  y: 'CadaclysmBlacksmithPoint',
  z: 'CadaclysmBlacksmithPoint',
  radius: 'double',
  radius2: 'double',
  t0: 'double',
  t1: 'double',
  degree: 'uint32_t',
  knots: 'const double *',
  knot_count: 'uint32_t',
  poles: 'const double *',
  pole_count: 'uint32_t',
  weights: 'const double *',
});
const CadaclysmBlacksmithChain = koffi.struct('CadaclysmBlacksmithChain', {
  points: 'const double *',
  point_count: 'uint32_t',
  face_a: 'uint32_t',
  face_b: 'uint32_t',
  closed: 'bool',
  tangent: 'bool',
  has_curve: 'bool',
});
const CadaclysmBlacksmithOverlap = koffi.struct('CadaclysmBlacksmithOverlap', {
  face_a: 'uint32_t',
  face_b: 'uint32_t',
  points: 'const double *',
  loop_offsets: 'const uint32_t *',
  point_count: 'uint32_t',
  loop_count: 'uint32_t',
});
// One finding of an argument check: `kind` a static string, `index`/`other` NONE and `size` 0
// where the kind gives none.
const CadaclysmBlacksmithFinding = koffi.struct('CadaclysmBlacksmithFinding', {
  kind: 'const char *',
  argument: 'uint32_t',
  index: 'uint32_t',
  other: 'uint32_t',
  size: 'double',
});
// An axis-aligned box: bit-compatible with six contiguous doubles (lo, then hi), which
// is how a Box crosses *into* a call (koffi has no cheaper way to pass a struct by value
// than its own fields); this struct is only ever an out-param, filled by the library.
const CadaclysmBlacksmithBox = koffi.struct('CadaclysmBlacksmithBox', {
  lo: koffi.array('double', 3),
  hi: koffi.array('double', 3),
});
const CadaclysmBlacksmithColliderStats = koffi.struct('CadaclysmBlacksmithColliderStats', {
  considered: 'uint32_t',
  world_boxes: 'uint32_t',
  oriented_boxes: 'uint32_t',
  skipped_share: 'uint32_t',
  cached: 'uint32_t',
  closed_form: 'uint32_t',
  meshed: 'uint32_t',
  refused: 'uint32_t',
  confirmed: 'uint32_t',
});
const CadaclysmBlacksmithCollisionHit = koffi.struct('CadaclysmBlacksmithCollisionHit', {
  a: 'uint32_t',
  b: 'uint32_t',
  overlap: 'bool',
  depth: 'double',
  positions: 'const double *',
  normals: 'const double *',
  indices: 'const uint32_t *',
  vertex_count: 'uint32_t',
  index_count: 'uint32_t',
  text: 'const char *',
});
// One pair of a clash call. `kind`, `kind_*` and `text` borrow from the clashes handle (the
// kinds are static strings), so `const char *` -- copied out as each row is read, never handed
// to `string_free`. `edge_*` is NONE where there is no fillet-table edge; `kind_*` is "none" for
// a penetrating or refused pair.
const CadaclysmBlacksmithClash = koffi.struct('CadaclysmBlacksmithClash', {
  a: 'uint32_t',
  b: 'uint32_t',
  kind: 'const char *',
  distance: 'double',
  on_a: koffi.array('double', 3),
  on_b: koffi.array('double', 3),
  kind_a: 'const char *',
  index_a: 'uint32_t',
  edge_a: 'uint32_t',
  kind_b: 'const char *',
  index_b: 'uint32_t',
  edge_b: 'uint32_t',
  refined: 'int32_t',
  depth: 'double',
  text: 'const char *',
});
// One pair of a swept clash call: its part indices, the first time it came within the clearance
// (in pose units) and how many time ranges it stays in clash, each read with
// `swept_clashes_interval`; its first `Clash` is row `i` of `swept_clashes_firsts`' list.
const CadaclysmBlacksmithSweptClash = koffi.struct('CadaclysmBlacksmithSweptClash', {
  a: 'uint32_t',
  b: 'uint32_t',
  first_time: 'double',
  interval_count: 'uint32_t',
});
// Wall thickness. `CadaclysmBlacksmithThicknessMesh` is borrowed from the gauge (copied out as
// it is read); the other three are plain records the library writes into an out-param.
// `vertex` is NONE for a reading at a point and `sphere` NaN for none; `found` false leaves the
// numbers of a face thickness NaN.
const CadaclysmBlacksmithThicknessMesh = koffi.struct('CadaclysmBlacksmithThicknessMesh', {
  positions: 'const double *',
  normals: 'const double *',
  indices: 'const uint32_t *',
  faces: 'const uint32_t *',
  vertex_count: 'uint32_t',
  triangle_count: 'uint32_t',
});
const CadaclysmBlacksmithFaceThickness = koffi.struct('CadaclysmBlacksmithFaceThickness', {
  found: 'bool',
  thickness: 'double',
  min: 'double',
  max: 'double',
  uniform: 'bool',
});
const CadaclysmBlacksmithThickness = koffi.struct('CadaclysmBlacksmithThickness', {
  body: 'uint32_t',
  vertex: 'uint32_t',
  face: 'uint32_t',
  point: koffi.array('double', 3),
  thickness: 'double',
  opposite: koffi.array('double', 3),
  opposite_body: 'uint32_t',
  opposite_face: 'uint32_t',
  knife: 'bool',
  exact_thickness: 'double',
  exact_opposite: koffi.array('double', 3),
  sphere: 'double',
});
const CadaclysmBlacksmithMeshThickness = koffi.struct('CadaclysmBlacksmithMeshThickness', {
  mesh: 'uint32_t',
  vertex: 'uint32_t',
  thickness: 'double',
  point: koffi.array('double', 3),
  opposite: koffi.array('double', 3),
  opposite_mesh: 'uint32_t',
  opposite_triangle: 'uint32_t',
  knife: 'bool',
});
// The FEM surface mesh, the kernel's twins of the reader's four. `size` is how
// `CadaclysmBlacksmithFemOptions` grows: the library's own
// `cadaclysm_blacksmith_fem_options_init` fills the whole struct and `femMesh` then
// writes this declaration's `sizeof` into `size`, so a field the library has and
// this block does not is written past what the call reads. Pinned field for field,
// widths included, by `cadaclysm-capi/tests/bindings.rs`'s
// `the_node_kernel_binding_matches_the_header` -- the reader crate's, which reads this
// library's header too. `cadaclysm-blacksmith-capi`'s own Node list is the older, weaker
// check (names and pointer-ness, no widths), which is why these four are pinned there.
const CadaclysmBlacksmithFemOptions = koffi.struct('CadaclysmBlacksmithFemOptions', {
  size: 'size_t',
  tolerance: 'double',
  max_size: 'double',
});
const CadaclysmBlacksmithFemMeshView = koffi.struct('CadaclysmBlacksmithFemMeshView', {
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
const CadaclysmBlacksmithFemEdge = koffi.struct('CadaclysmBlacksmithFemEdge', {
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
const CadaclysmBlacksmithFemVertex = koffi.struct('CadaclysmBlacksmithFemVertex', {
  node: 'uint32_t',
  point: koffi.array('double', 3),
  has_position: 'bool',
});
// The Kiln's SubD cage: `parts` and `smooth_mesh` are views into the cage's handle (the
// arrays good until it is freed), which `Subd` copies out with `koffi.decode` before the
// call returns; the report is plain figures.
const CadaclysmBlacksmithSubdParts = koffi.struct('CadaclysmBlacksmithSubdParts', {
  positions: 'const double *',
  vertex_count: 'uint32_t',
  face_sizes: 'const uint32_t *',
  face_count: 'uint32_t',
  face_indices: 'const uint32_t *',
  index_count: 'uint32_t',
  creases: 'const uint32_t *',
  crease_count: 'uint32_t',
  pins: 'const uint32_t *',
  pin_count: 'uint32_t',
  symmetry_axis: 'int32_t',
  symmetry_tolerance: 'double',
  selection_kind: 'uint32_t',
  selection: 'const uint32_t *',
  selection_count: 'uint32_t',
});
const CadaclysmBlacksmithSubdMesh = koffi.struct('CadaclysmBlacksmithSubdMesh', {
  positions: 'const double *',
  vertex_count: 'uint32_t',
  normals: 'const double *',
  indices: 'const uint32_t *',
  index_count: 'uint32_t',
  triangle_face: 'const uint32_t *',
});
const CadaclysmBlacksmithSubdReport = koffi.struct('CadaclysmBlacksmithSubdReport', {
  regular: 'uint32_t',
  refined: 'uint32_t',
  steps: 'uint32_t',
  levels: 'uint32_t',
  deviation: 'double',
  g1_angle_deg: 'double',
  deviation_at: koffi.array('double', 3),
  g1_at: koffi.array('double', 3),
});
const CadaclysmBlacksmithProgress = koffi.proto('void CadaclysmBlacksmithProgress(const char *phase, size_t done, size_t total, void *user)');
const CadaclysmBlacksmithDocumentProgress = koffi.proto('void CadaclysmBlacksmithDocumentProgress(const char *node, const char *phase, size_t done, size_t total, void *user)');
const CadaclysmBlacksmithSvgOptions = koffi.struct('CadaclysmBlacksmithSvgOptions', {
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
// The mechanical drawings' three records, field for field as the header has them (pinned by
// crates/cadaclysm-blacksmith-capi/tests/hlr_abi.rs).
koffi.struct('CadaclysmBlacksmithHlrOptions', {
  size: 'uint32_t',
  projection: 'uint32_t',
  direction: koffi.array('double', 3),
  up: koffi.array('double', 3),
  eye: koffi.array('double', 3),
  target: koffi.array('double', 3),
  tolerance: 'double',
  smooth_angle: 'double',
  feature_angle: 'double',
  iso: 'uint32_t',
  reserved: 'uint32_t',
});
koffi.struct('CadaclysmBlacksmithHlrLine', {
  kind: 'uint32_t',
  visible: 'uint32_t',
  solid: 'uint32_t',
  source_kind: 'uint32_t',
  source: 'uint32_t',
  source2: 'uint32_t',
  bezier_count: 'uint32_t',
  reserved: 'uint32_t',
  length2d: 'double',
  length3d: 'double',
});
koffi.struct('CadaclysmBlacksmithHlrReport', {
  candidates: 'uint32_t',
  segments: 'uint32_t',
  crossings: 'uint32_t',
  pieces: 'uint32_t',
  degenerate: 'uint32_t',
  rays: 'uint32_t',
  mesh_hits: 'uint32_t',
  rejected: 'uint32_t',
  grazes: 'uint32_t',
  unsettled: 'uint32_t',
  mesh_only: 'uint32_t',
  fallback_edges: 'uint32_t',
  failed_solids: 'uint32_t',
  reserved: 'uint32_t',
  candidate_length: 'double',
  degenerate_length: 'double',
  tolerance: 'double',
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
      throw new BuildError(`${name}: not in this library's flavour ('${flavour}', features ${features || 'none'}); the full flavour has it`);
    };
  }
}

/** The wasm module standing in for the shared library, or null: `globalThis.cadaclysm` with the blacksmith's exports on it. */
function _wasm() {
  const w = globalThis.cadaclysm;
  return w && typeof w.cadaclysm_blacksmith_version === 'function' ? w : null;
}

/**
 * What `koffi` is where there is none (a browser): the type declarations run against it
 * and keep nothing.
 *
 * Every member a declaration touches **at module load** has to be here, or the file
 * throws before `_lib()` is ever reached. `array` is one (`CadaclysmBlacksmithFemVertex`'s
 * fixed `point`), and it was missing until `web/test/notebook-javascript.mjs` found it;
 * `sizeof` is asked for only inside `_femOptions`, which does not ask it under the wasm,
 * but it costs nothing to answer.
 */
function _noKoffi() {
  const none = () => null;
  return { opaque: none, struct: none, proto: none, disposable: none, load: none, decode: none, address: none, as: none, array: none, sizeof: none };
}

/**
 * The same entry points over the wasm module, shaped so every `_lib().name(...)`
 * call site runs unchanged: a handle is an integer, a typed array is passed as it
 * is, an out-array is filled back, a failing call records its message for
 * `last_error` and returns the C ABI's null/false/NONE.
 *
 * A wasm export takes the C call's arguments minus the ones a JS value carries in
 * itself (an array's count, the progress `user` pointer, the out-arguments); it
 * returns what C wrote through an out-argument; and it throws an `Error` -- whose
 * message is the C ABI's own text -- where C returns null and leaves `last_error`.
 * The tables say which is which, per entry point; the rest of the module never
 * sees the difference. The tables are the Python module's (`_WasmLibrary` in
 * cadaclysm_blacksmith.py), argument positions being the C header's.
 */
function _wasmLibrary(w) {
  // what a failing call returns, by the C ABI's convention for that name: `false`
  // for the bool-returning verbs, a record with a null pointer in it for the
  // struct-returning ones, NONE for the u32 ones that reserve it, and 0 (a null
  // handle, or a count the caller checks `last_error` on) for everything else
  const BOOLS = new Set(['path_line_to', 'path_arc_to', 'path_bezier_to', 'path_nurbs_to', 'path_conic_to', 'path_parabola_by_vertex',
    'path_parabola_by_focus', 'sweep_path_line_to', 'sweep_path_arc',
    'slant_of_plane', 'face_frame', 'face_ref', 'frame_midplane', 'frame_through', 'bounds', 'bounds64', 'box', 'job_stock', 'edge', 'colour', 'profile_colour', 'edge_colour', 'parse_colour', 'manifold', 'license_set', 'hit', 'edge_curve',
    'mass_properties',
    // measure: C writes each answer through an out-param and returns a success flag; the wasm
    // exports return the answer (see `back`). `classifier_new` is a handle, 0 on a failure.
    'oriented_box', 'edge_length', 'profile_length', 'edge_point_at_length', 'profile_point_at_length', 'contains', 'classifier_contains', 'closest',
    'intersection_chain', 'intersection_curve', 'intersection_overlap', 'check_finding', 'hits_piece', 'assembly_link', 'assembly_joint',
    'assembly_pair', 'assembly_pair_with', 'assembly_state', 'assembly_sequence', 'assembly_base',
    'fem_mesh_view', 'fem_mesh_edge', 'fem_mesh_vertex', 'fem_mesh_open_edge', 'fem_mesh_folded_edge', 'fem_mesh_crossing',
    // collider: `solid_bounds_box`/`box_moved` write a Box out-param, `boxes_apart` a bool,
    // `collider_stats`/`collisions_hit` a record -- the C return is a plain success flag
    // either way, so a failure is `false` here too. `box_overlaps` is deliberately absent:
    // its C return **is** the answer, not a success flag.
    'solid_bounds_box', 'box_moved', 'boxes_apart', 'collider_stats', 'collisions_hit',
    // clash: `clashes_at` writes its row into an out-record, as `collisions_hit` does
    'clashes_at',
    // swept clash: a row record and an interval's two doubles, behind a success flag
    'swept_clashes_at', 'swept_clashes_interval',
    // wall thickness: the mesh, the face reading and each row are records C writes through an
    // out-param behind a success flag; the exports return them instead
    'thickness_gauge_mesh', 'thickness_gauge_face', 'thicknesses_at', 'mesh_thicknesses_at',
    // the R-tree: `rtree_insert`/`_insert_point` return nothing over the wasm and C's success
    // flag natively; `rtree_bounds` writes its 6 doubles (see `back`), and its export's throw
    // for an empty tree is `false` and `last_error`, as C's. `rtree_remove` is deliberately
    // absent: its C return **is** the answer (false for an absent entry, with no error).
    'rtree_insert', 'rtree_insert_point', 'rtree_bounds',
    // the triangle mesh: `triangle_mesh_bounds` writes its 6 doubles (OUT), C's return a success
    // flag; its export's throw is `false` and `last_error`, as C's
    'triangle_mesh_bounds',
    // the drawings: a line's record and report (`back`), its Béziers (OUT), and the page's four
    // `add_*`, whose exports return nothing where C returns a success flag
    'hlr_line', 'hlr_line_beziers2d', 'hlr_line_beziers3d', 'hlr_report',
    'page_add_view', 'page_add_profile', 'page_add_hatch', 'page_add_text',
    // the interpolator: `_at`/`_sample` write their doubles into the caller's array (see `back`),
    // C's return a success flag. `interpolator_cyclic` is absent: its C return **is** the
    // answer, as `rtree_remove`'s.
    'interpolator_at', 'interpolator_sample',
    // Its wasm export always throws ("the wasm writes no file"); `FemMesh.saveMsh`
    // never reaches it in the notebook, writing `mshText()` through the page's own
    // `fs` as `step`/`sat`/`svg` do, so this is the shape a direct `_lib()` call
    // would still get right rather than a path this module takes.
    'fem_mesh_save_msh',
    // `brep` the same: its export always throws ("the wasm writes no file"), C's false
    'brep',
    // job_machine's CAM report: item `i`'s location, x/y/z, written to a `double *`
    // out-param natively, returned as a plain array by the wasm export (see OUT below).
    'report_at',
    // Job's setters: plain bool verbs, as `job_set_clearance` and its siblings return
    // natively.
    'job_set_clearance', 'job_set_tolerance', 'job_set_spindle_dwell', 'job_set_resolution', 'job_set_name',
    // The four manual verbs: plain bool wasm exports too, as job_set_* above.
    'job_face', 'job_contour', 'job_pocket', 'job_drill',
    // the kernel options: `option_set` returns C's success flag, and `option_get`'s export
    // returns the value C writes through `*out` (see `back`)
    'option_set', 'option_get',
    // SubD: `subd_parts`/`subd_smooth_mesh` fill a views struct and `subd_pick` an id pair,
    // C returning a success flag; `subd_pick`'s null (nothing near) is `false` with an empty
    // `last_error` (see `back`)
    'subd_parts', 'subd_smooth_mesh', 'subd_pick',
    // the sketch: its mutators' `Js<()>` and the `double out[N]` writers, a plain success flag
    // in C either way. `is_construction`/`is_reference`/`is_joint_tangent`/`constraint_driving`
    // are absent, as `box_overlaps` is: their C return is the answer, not a success flag.
    'sketch_set_point', 'sketch_set_radius', 'sketch_set_construction', 'sketch_remove',
    'sketch_point', 'sketch_update_reference', 'sketch_set_value', 'sketch_set_driving',
    'sketch_solve', 'sketch_drag', 'sketch_diagnose', 'sketch_dof_part',
    // the transforms and quaternions: a success flag in C, the answer in the out-array (OUT); a
    // decomposition the map has none of throws, which is C's `false` -- the wrapper's null
    'transform_translation', 'transform_rotation', 'transform_mirror', 'transform_scale', 'transform_scale_xyz', 'transform_shear',
    'transform_plane_to_plane', 'transform_change_basis', 'transform_planar_projection', 'transform_project_along',
    'transform_compose', 'transform_inverse', 'transform_decompose_rigid', 'transform_decompose_similarity', 'transform_decompose_affine',
    'quaternion_from_axis_angle', 'quaternion_from_transform', 'quaternion_to_transform', 'quaternion_slerp',
    // the values: a success flag in C, the answer in the out-array (OUT, SCALARS; `frame_fit`'s
    // two outs in `back`)
    'value_check', 'value_bounds', 'value_transform', 'curve_value_point_at', 'curve_value_tangent_at', 'curve_value_length',
    'curve_value_closest_point', 'circle_through', 'arc_through', 'arc_from_start_tangent_end', 'ellipse_from_circle',
    'surface_value_point_at', 'surface_value_normal_at', 'surface_value_closest_point', 'surface_value_domain',
    'solid_value_area', 'solid_value_volume', 'cuboid_from_bounds', 'cuboid_around', 'cuboid_corners', 'cuboid_point_at',
    'cuboid_closest_point', 'frame_fit',
    'rectangle_corners', 'rectangle_area', 'rectangle_closest_point', 'triangle_area', 'triangle_perimeter',
    'triangle_centroid', 'triangle_circumcircle', 'triangle_point_at', 'triangle_barycentric',
    'triangle_closest_point', 'triangle_edge', 'ray_point_at', 'ray_closest_point',
    // identity: an origin C writes through two out-pointers (the export returns `[operand, id]`,
    // see `back`), and the edge and vertex references' out-arrays (OUT)
    'face_origin_at', 'edge_origin_at', 'edge_ref', 'vertex_ref',
    // tolerances: the declaration's two out-doubles (the export returns them, see `back`)
    'solid_tolerances',
    // NurbsCurve's readers: a success flag, the answer in the out-array (OUT) or the record (`back`);
    // `nurbs_curve_tween` writes its handles (`back`). `is_rational` and `is_closed` are absent, as
    // `box_overlaps` is: their C return is the answer
    'nurbs_curve_control_points', 'nurbs_curve_weights', 'nurbs_curve_knots', 'nurbs_curve_domain',
    'nurbs_curve_point', 'nurbs_curve_derivatives', 'nurbs_curve_curvature', 'nurbs_curve_length',
    'nurbs_curve_point_at_length', 'nurbs_curve_tween', 'nurbs_curve_knot_continuity',
    // the panel gap: a success flag, the two panels' handles in `back`
    'panel_gap',
    // a profile's Béziers (the out-array, OUT) and a chain's order (`back`)
    'profile_beziers', 'profile_chain_order', 'profile_loops',
    // the sheets' and an edge's continuity, a face's curvature turns and an edge's highlight
    // kink: a success flag, the record in `back`
    'continuity', 'edge_continuity', 'curvature_turns', 'highlight_kink',
    // the edges' and isocurves' Béziers: a success flag, the array in the out-argument (OUT)
    'edge_beziers', 'isocurve_beziers',
    // the document: the four calls whose export returns nothing and C a success flag
    'document_preview_begin', 'document_batch_begin', 'document_branch_rename', 'document_branch_delete']);
  // C names whose wasm export is spelled otherwise, by short name: the wasm's IFC export has no
  // `document_` in its name. Every other `bim_*` short is the wasm's `cadaclysm_bim_*` as it is.
  const RENAMED = { bim_document_export_ifc: 'cadaclysm_bim_export_ifc' };
  // the sketch's lent `const uint32_t *` lists, by the position of their `size_t *count`: the
  // export returns the list itself (a `Uint32Array`), which `back` hands on as the "pointer"
  // (`_uint32s` passes a typed array through) with its length written into the count
  const LISTS = { sketch_add_rect: 5, sketch_entities: 1, sketch_ends: 2, sketch_remove_entity: 2,
    sketch_constraints: 1, sketch_constraint_refs: 2, sketch_report_ids: 1, sketch_dof_list: 2, sketch_dof_part_list: 3 };
  const FAILS = { select_face: NONE, leaked_edges: NONE, unpaired_edges: NONE, mesh: { positions: null }, mesh64: { positions: null }, mesh_face_triangles: { counts: null },
    edge_polylines: { offsets: null }, profile_polylines: { offsets: null }, edge_polyline_colours: { rgb: null, count: 0 },
    step: null, sat_text: null, svg_text: null, drawing_svg_text: null, silhouette_beziers: null, face_kind: null, brep_layout_id: null,
    fem_mesh_msh_text: null, solid_name: null, solid_material: null, solid_style_location: null,
    solid_style_identification: null, assembly_name: null, assembly_place_solid: null,
    assembly_place_assembly: null, assembly_step: null, '3dm_bytes': null, assembly_3dm_bytes: null,
    // a mesh file's bytes: null; a face's round radius and chamfer distance: C's NaN for a bad face
    mesh_file: null, face_round_radius: NaN, face_chamfer_distance: NaN,
    // the wasm lists an assembly's parts in one call (`Assembly.parts`): null when it threw
    assembly_parts: null,
    // the CAM getters: NONE and NaN are the C ABI's own refusals for them
    tool_number: NONE, tool_shape: null, tool_diameter: NaN, tool_flute_length: NaN, tool_angle: NaN, tool_corner_radius: NaN,
    // the CAM lists' readers: C's UINT32_MAX for a refused count or tool, NaN for a refused figure
    operations_count: NONE, operations_param_count: NONE, operations_tool: NONE, operations_param_value: NaN,
    programs_count: NONE, programs_tool: NONE, report_count: NONE, report_bottom: NaN, report_top: NaN, report_size: NaN,
    // the sketch's ids start at 0, so a refused id-returning call must come back as C's NONE,
    // not the generic 0; its double readers as C's NaN; its lists as C's null
    sketch_add_point: NONE, sketch_add_line: NONE, sketch_add_circle: NONE, sketch_add_arc: NONE,
    sketch_add_bezier: NONE, sketch_add_conic: NONE, sketch_add_nurbs: NONE, sketch_kind: NONE,
    sketch_centre: NONE, sketch_reference: NONE, sketch_constrain: NONE,
    sketch_constraint_kind: NONE, sketch_constraint_sense: NONE, sketch_constraint_end: NONE,
    sketch_radius: NaN, sketch_measure: NaN, sketch_constraint_value: NaN,
    // edge_tolerance: NaN is C's "none"; a closed solid's throw is NaN with `last_error` set
    edge_tolerance: NaN,
    // the gauge's tolerance: NaN is C's refusal, which the export throws
    thickness_gauge_tolerance: NaN,
    // the two map classifiers: C's NONE and NaN are their refusals, which the exports throw
    transform_is_rigid: NONE, transform_is_similarity: NaN,
    // the values: containment's NONE; `value_size`'s export throws on an unknown kind, where
    // C answers 0
    solid_value_contains: NONE, value_size: 0, rectangle_contains: NONE,
    // identity: C's NONE for a refused count and for "no face has the id"; -2 for a malformed
    // face, edge or vertex reference (-1, "gone", is an answer); null for a refused attribute read
    face_with_id: NONE, edge_with_id: NONE, face_origin_count: NONE, edge_origin_count: NONE,
    find_face: -2, find_edge: -2, find_vertex: -2, attribute: null, face_attribute: null,
    // tolerances: C's NaN for a refusal, never the generic 0 (0 is an effective tolerance)
    effective_tolerance: NaN, vertex_tolerance: NaN,
    // closest point from a point: C's int32 -1 for a refusal (0 is "beyond max_distance")
    closest_point: -1, projector_closest_point: -1, face_closest_point: -1,
    edge_closest_point: -1, nurbs_curve_closest_point: -1,
    // closest points from a curve: the same (0, the export's null, is "beyond max_distance")
    nurbs_curve_closest_point_within: -1, nurbs_curve_closest_points: -1, curve_closest_points: -1,
    projector_curve_closest_points: -1, nurbs_curve_closest_object: -1,
    // closest points against a triangle mesh: the same
    triangle_mesh_closest_point: -1, triangle_mesh_curve_closest_points: -1,
    // a profile list's count: C reserves NONE for a node that is not one
    document_result_profile_count: NONE,
    // a page's SVG and DXF: C's null
    page_svg_text: null, page_dxf_text: null,
    ...Object.fromEntries(Object.keys(LISTS).map((short) => [short, null])) };
  // results that C writes into an out-array of doubles at this position, and the
  // wasm returns as an array (`bounds` fills two, `edge` and `hit` a record: see `back`)
  const OUT = { edge_beziers: 2, isocurve_beziers: 3, profile_beziers: 2, slant_of_plane: 3, face_frame: 2, face_ref: 2, frame_midplane: 2, frame_through: 3, report_at: 2,
    // the sketch's point (2), solve reports (3) and diagnoses (3)
    sketch_point: 2, sketch_update_reference: 3, sketch_set_value: 3, sketch_set_driving: 3,
    sketch_solve: 1, sketch_drag: 4, sketch_diagnose: 1, sketch_dof_part: 2,
    // the transforms and quaternions: their one out-array, last (passed on past the export's own
    // arguments, which it ignores, as `frame_midplane`'s is)
    transform_translation: 1, transform_rotation: 2, transform_mirror: 1, transform_scale: 2, transform_scale_xyz: 4,
    transform_shear: 3, transform_plane_to_plane: 2, transform_change_basis: 2, transform_planar_projection: 1,
    transform_project_along: 2, transform_compose: 2, transform_inverse: 1, transform_decompose_rigid: 2,
    transform_decompose_similarity: 2, transform_decompose_affine: 1, quaternion_from_axis_angle: 2,
    quaternion_from_transform: 1, quaternion_to_transform: 2, quaternion_slerp: 3,
    // the values: their one out-array, last (`cuboid_around`'s count dropped, its out not)
    value_check: 2, value_bounds: 2, value_transform: 3, curve_value_point_at: 3, curve_value_tangent_at: 3,
    curve_value_closest_point: 3, circle_through: 3, arc_through: 3, arc_from_start_tangent_end: 3,
    ellipse_from_circle: 1, surface_value_point_at: 4, surface_value_normal_at: 4, surface_value_closest_point: 3,
    surface_value_domain: 2, cuboid_from_bounds: 2, cuboid_around: 3, cuboid_corners: 1, cuboid_point_at: 4,
    cuboid_closest_point: 2, rectangle_corners: 1, rectangle_closest_point: 3, triangle_centroid: 1,
    triangle_circumcircle: 1, triangle_point_at: 4, triangle_barycentric: 2, triangle_closest_point: 2,
    triangle_edge: 2, ray_point_at: 2, ray_closest_point: 2,
    // a swept clash's interval, `[start, end]`
    swept_clashes_interval: 3,
    // the edge and vertex references
    edge_ref: 2, vertex_ref: 2,
    // a curve's reads: their one out-array, last
    nurbs_curve_control_points: 1, nurbs_curve_weights: 1, nurbs_curve_knots: 1, nurbs_curve_domain: 1,
    nurbs_curve_point: 2, nurbs_curve_derivatives: 3,
    // a triangle mesh's box, `min x, min y, min z, max x, max y, max z`
    triangle_mesh_bounds: 1,
    // a hidden-line view's line, sixteen doubles a Bézier
    hlr_line_beziers2d: 2, hlr_line_beziers3d: 2 };
  // the value calls whose export returns a plain number (not an array, as OUT's), written into
  // the one-double out-array at this position
  const SCALARS = { curve_value_length: 2, solid_value_area: 2, solid_value_volume: 2, rectangle_area: 1,
    triangle_area: 1, triangle_perimeter: 1 };
  // `uint64_t` arguments, by position: an id crosses into the wasm as a `BigInt` (the export's
  // `u64` refuses a plain number)
  const U64_ARGS = { face_with_id: [1], edge_with_id: [1] };
  // optional vectors, by position among the arguments the export takes
  const OPTIONAL_ARGS = { sweep_rail: [3], split_by_curve: [2], trim_by_curve: [2], extrude_to: [2],
    // a hole's `direction`, a rib's `toward` and a rectangular pattern's `direction2`
    hole: [3], hole_tool: [3], rib: [5], rib_tool: [5], pattern_rectangular: [3] };
  // `uint64_t` returns: the export's `BigInt`, handed back as a number, as koffi does (ids count
  // up from 1 per solid, far below 2**53)
  const U64_RETURNS = new Set(['face_id', 'edge_id']);
  // argument positions the C call has and the wasm call does not: an array's
  // count (a typed array knows its length), the progress `user` pointer, and
  // the out-arguments above
  const DROP = { profile_polygon: [1], path_nurbs_to: [2, 5], join: [4], document_evaluate_with: [3], merge: [4], cut: [4], common: [4], split_sheet: [4], trim: [5], drop_faces: [2],
    // job_machine: the drills array's own count (a typed array knows its length), as
    // every other array argument's count is dropped above.
    job_machine: [4],
    // job_machine_with: both arrays' own counts, the end mills' (3) and the drills' (5).
    job_machine_with: [3, 5],
    // job_machine_relieved: the same two counts.
    job_machine_relieved: [3, 5],
    // job_drill: the xy array's own count, the same way.
    job_drill: [3],
    // job_stock: the two out-arrays, written from the one six-number array (see `back`).
    job_stock: [1, 2],
    profile_round: [3], profile_spline: [1], profile_chain: [1], profile_from_loops: [1], profile_piece_count: [2], profile_piece: [2],
    profile_trim_count: [2], profile_trim_chain: [2], loft_through: [2], loft_through_open: [2], fillet: [2, 6], chamfer: [2], shell: [3, 6],
    thicken: [4], push_pull: [5], push_pull_faces: [2, 6], split: [4], split_by_plane: [4], split_by_profile: [5], step: [1], sat_text: [1], brep: [1], svg_text: [1], drawing_svg_text: [1, 3], profile_text: [4],
    // a `.3dm`'s solids count and its `size_t *len`, which `back` fills from the bytes returned
    '3dm_bytes': [1, 3], assembly_3dm_bytes: [2],
    // a mesh file's solids count and its `size_t *len` (as `3dm_bytes`'), the Béziers' out-arrays
    // (OUT), which the exports return instead
    mesh_file: [1, 6], edge_beziers: [2], isocurve_beziers: [3],
    // the count out-param: the export returns the curves' own array (see `back`)
    silhouette_beziers: [2],
    slant_of_plane: [3], face_frame: [2], face_ref: [2], bounds: [2, 3], bounds64: [2, 3], box: [1, 2], edge: [2], colour: [2], profile_colour: [1], edges_coloured: [2], edge_colour: [2], parse_colour: [1], manifold: [1], hit: [2], edge_curve: [2],
    intersect: [4], self_intersect: [3], check: [5], check_finding: [2], intersection_chain: [2], intersection_curve: [2], intersection_overlap: [2],
    solid_profile_hits: [5], hits_piece: [2, 3, 4], assembly_link: [3],
    // `assembly_state`'s row_count (args[5]) drops: joints/counts/values are arrays, each
    // carrying its own length, as `assembly_link`'s placement count does above.
    assembly_state: [5],
    // `assembly_posed`'s row_count (args[4]) drops the same way.
    assembly_posed: [4],
    // `assembly_sequence`'s count (args[5]) drops the same way: states/ts/interpolations are arrays.
    assembly_sequence: [5],
    // `fem_mesh`'s index counts the tuple `call` rewrites below, not the C call's:
    // the options struct becomes two scalars, so `user` has moved from 4 to 5.
    fem_mesh: [5], fem_mesh_view: [1], fem_mesh_edge: [2], fem_mesh_vertex: [2],
    fem_mesh_open_edge: [2, 3, 4], fem_mesh_folded_edge: [2, 3, 4], fem_mesh_crossing: [2, 3],
    // collider: `solid_bounds_box`/`box_moved` drop their Box out-param; `boxes_apart` its
    // bool out-param; `collider_new` its `solids` count and `allowed` count (a typed array
    // knows its own length); `collider_check` its `frame_count`; `collider_stats`/
    // `collisions_hit` their out-record.
    solid_bounds_box: [2], box_moved: [2], boxes_apart: [4],
    // the R-tree: the counts a typed array carries itself, and `rtree_bounds`' out-array,
    // which the export returns instead
    rtree_from_boxes: [2], rtree_from_points: [1], rtree_from_triangles: [1, 3], rtree_bounds: [1],
    // the interpolator: the sample and `t` counts (a typed array knows its length), and the
    // out-array and its length, which the export returns instead
    interpolator_new: [1], interpolator_at: [3, 4], interpolator_sample: [2, 4, 5],
    collider_new: [1, 5], collider_check: [2], collider_stats: [1], collisions_hit: [2],
    // clash: `collider_clash` drops its `frame_count`; `clash` both set counts and the
    // `allowed` pair count (typed arrays, `allowed` flat numbers); `clashes_at` its
    // out-record, which the export returns instead (see `back`)
    collider_clash: [2], clash: [1, 3, 7], clashes_at: [2],
    // swept clash: `collider_swept_clash` drops its `frame_count` (the export reads it off the
    // numbers and the pose count); `swept_clash` both set counts and its `allowed` pair count;
    // `swept_clashes_at` its out-record and `swept_clashes_interval` its out-array, which the
    // exports return instead (see `back`)
    collider_swept_clash: [3], swept_clash: [1, 4, 12], swept_clashes_at: [2], swept_clashes_interval: [3],
    // an assembly's sweep: `joint_count` (the joints and counts arrays know their length) and
    // the `allowed` pair count (the export takes the flat numbers)
    assembly_swept_clash: [3, 12],
    // wall thickness: `thickness_gauge_new` drops its solids count, `mesh_thickness` its mesh
    // count (typed arrays carry their lengths); the mesh, face and row readers their out-record,
    // which the export returns instead (see `back`). The three `*_free`s take only the handle.
    thickness_gauge_new: [1], thickness_gauge_mesh: [2], thickness_gauge_face: [5],
    thicknesses_at: [2], mesh_thicknesses_at: [2], mesh_thickness: [4],
    // `mass_properties` drops its CadaclysmBlacksmithMassProperties out-param: the export
    // returns the figures as a flat array of doubles instead. It was already in BOOLS and
    // missing here, so `.mass()` over the wasm handed back an unfilled struct.
    mass_properties: [2],
    // measure: each drops its out-param, which the export returns instead; `closest` also
    // drops `progress` and `user` -- its export takes no callback, so a progress is never called.
    oriented_box: [2], edge_length: [3], profile_length: [2], edge_point_at_length: [4], profile_point_at_length: [3], contains: [3], classifier_contains: [2], closest: [3, 4, 5],
    // closest point from a point: the foot out-param or the five doubles' out-array, which the
    // export returns instead (a foot object or null, a plain array: see `back`)
    closest_point: [4], projector_closest_point: [3], face_closest_point: [3],
    edge_closest_point: [3], nurbs_curve_closest_point: [2],
    // closest points from a curve: the out-param, which the export returns instead (null beyond
    // `max_distance`: see `back`); `nurbs_curve_closest_object`'s is the rewritten tuple's (`call`)
    nurbs_curve_closest_point_within: [3], nurbs_curve_closest_points: [3], curve_closest_points: [4],
    projector_curve_closest_points: [3], nurbs_curve_closest_object: [4],
    // the triangle mesh: the vertex and triangle counts (a typed array knows its length -- the
    // wrapper hands both arrays at their exact length, never padded), the box's out-array (OUT)
    // and the queries' out-param, which the exports return instead (null beyond `max_distance`:
    // see `back`)
    triangle_mesh_new: [1, 3], triangle_mesh_bounds: [1], triangle_mesh_closest_point: [3],
    triangle_mesh_curve_closest_points: [3],
    // the drawings: the solids' and meshes' counts (a typed array knows its length), and the
    // out-params, which the exports return instead (OUT, `back`)
    hlr: [1], hlr_mesh: [1], projected_outline: [1], hlr_line: [2], hlr_line_beziers2d: [2], hlr_line_beziers3d: [2],
    hlr_report: [1],
    // `option_get` drops its `*out`: the export returns the value instead
    option_get: [1],
    // SubD: the counts a typed array carries itself, and the out-params -- `subd_parts`/
    // `subd_smooth_mesh`'s struct, `subd_pick`'s id pair and `subd_to_solid`'s report --
    // which the exports return instead (see `back`)
    subd_from_parts: [1, 3, 5, 7, 9], subd_parts: [1], subd_transform: [3], subd_set_crease: [2], subd_set_pin: [2],
    subd_extrude: [2], subd_inset: [2], subd_subdivide: [2], subd_smooth_mesh: [2], subd_pick: [3], subd_to_solid: [4],
    // the counted verbs: their `inexact_out`, which the export returns beside the handle (see `back`)
    solid_transform: [2], solid_convert_to_nurbs: [2],
    // the values: the point counts (a typed array knows its length); `frame_fit`'s outs too,
    // which its export returns as 13 numbers instead (see `back`)
    cuboid_around: [2], frame_fit: [1, 2, 3],
    // the sketch: `add_nurbs`' point and knot counts, `constrain`'s ref count, `drag`'s count
    // and report, the other out-arrays (OUT) and every list's count (LISTS)
    sketch_add_nurbs: [4, 7], sketch_constrain: [3], sketch_drag: [3, 4],
    // identity: an origin's two out-pointers (the export returns the pair) and the references'
    // out-arrays
    face_origin_at: [3, 4], edge_origin_at: [3, 4], edge_ref: [2], vertex_ref: [2],
    // tolerances: the solids count (a typed array knows its length), the declaration's outs
    effective_tolerance: [1], solid_tolerances: [1, 2],
    // NurbsCurve: the point, weight, knot and curve counts (a typed array knows its length); a
    // fitted curve's `error_out` and the tweens' `out`, which `back` fills from the exports'
    // returns; the reads' out-arrays and records
    nurbs_curve_new: [1, 5], nurbs_curve_through: [1], nurbs_curve_fit: [1, 4],
    nurbs_curve_projected_to_face: [5], nurbs_curve_pulled_to_face: [4], nurbs_curve_joined: [1],
    nurbs_curve_tween: [7], nurbs_curve_control_points: [1], nurbs_curve_weights: [1],
    nurbs_curve_knots: [1], nurbs_curve_domain: [1], nurbs_curve_point: [2],
    nurbs_curve_derivatives: [3], nurbs_curve_curvature: [2], nurbs_curve_length: [2],
    nurbs_curve_point_at_length: [3],
    // fairing: the point count and the `error_out` (`back` fills it from the `[curve, error]`
    // return); the knot continuity's record, which the export returns as ten numbers
    nurbs_curve_fair: [1, 7], nurbs_curve_faired: [6], nurbs_curve_knot_continuity: [1], edge_continuity: [3],
    // surface fairing's `error_out` (`back` fills it from the `[solid, error]` return); the
    // curvature turns' and highlight kink's records, which the exports return as numbers
    surface_faired: [8], curvature_turns: [3], highlight_kink: [3],
    // the sheets from curves, the surface fillets, trim and join: every curve, sheet and edge count
    // (a typed array knows its length), and the error, rails and report C writes through an
    // out-argument, which the exports return after the solid (`back`); `n_sided_patch`'s are the
    // rewritten tuple's (see `call`)
    loft_curves: [1], sweep_rail: [2, 6], sweep_two_rails: [3, 5], edge_surface: [1, 3],
    network_surface: [1, 3, 5], continuity: [7], fillet_surfaces: [9, 10, 11], fillet_varying: [2], fillet_law: [2, 5],
    join_sheets: [1, 3], n_sided_patch: [4], recess: [7], mirror_join: [4],
    // holes, ribs and webs, patterns: every count (a typed array knows its length), the reports
    // and bottoms C writes, which the exports return after the solid, and the placements' `out`,
    // which the exports return instead of a count (`back`)
    hole: [2, 14, 15], hole_tool: [2], pattern: [2, 4], pattern_feature: [4, 6], web: [2], web_tool: [2],
    pattern_rectangular: [8, 9], pattern_circular: [5, 6], pattern_along: [5, 6],
    // the panel verbs: the offset's `error_out` and the panel gap's `out`, which `back` fills
    nurbs_curve_offset_on_sheet: [4], panel_gap: [5],
    // flange and extrude_to: the edges' count and the error out-argument
    flange: [2, 6], extrude_to: [2, 7],
    // the sketch curves: the point and Bézier counts, the piece counts and the out-arrays the
    // exports return instead (`OUT`, `back`)
    profile_polyline: [1], profile_from_beziers: [1], profile_beziers: [2],
    profile_loops: [1, 3], profile_chain_order: [1, 3],
    ...Object.fromEntries(Object.entries(OUT).filter(([short]) => short.startsWith('sketch_') && short !== 'sketch_drag').map(([short, at]) => [short, [at]])),
    ...Object.fromEntries(Object.entries(LISTS).map(([short, at]) => [short, [at]])) };
  let error = null;
  /** A `WebAssembly.RuntimeError`: the wasm trapped (a panic aborts, the tables stay borrowed), which no `last_error` can stand for. */
  const trapped = (e) => typeof WebAssembly !== 'undefined' && e instanceof WebAssembly.RuntimeError;
  /** One C argument as the wasm takes it: a handle array as a `Uint32Array`, `null` as an empty array where the C side reads none. */
  const arg = (a) => (Array.isArray(a) ? Uint32Array.from(a, Number) : a);
  /**
   * `CadaclysmBlacksmithSvgOptions`'s own twelve fields after `size`, in the C struct's
   * own order -- what `svg_text`/`drawing_svg_text` flatten a `_svgOptions()` object into
   * for the wasm exports in crates/cadaclysm-wasm/src/blacksmith.rs (wasm-bindgen has no
   * cheaper way to take a C struct from JS than one flat array). `up`/`stroke`/`background`/
   * `flags` are really u32 but carried as an integral f64 like the rest, matching the
   * exports' own doc comments.
   */
  const svgWords = (o) => Float64Array.of(
    o.up, o.azimuth, o.elevation, o.fov, o.width, o.height,
    o.margin, o.tolerance, o.stroke_width, o.stroke, o.background, o.flags,
  );
  /**
   * `CadaclysmBlacksmithHlrOptions`'s nineteen fields, `size` and `reserved` included, in the C
   * struct's order -- what `hlr`/`hlr_mesh`/`projected_outline` flatten `_hlrOptions()`'s object
   * into for the wasm exports (crates/cadaclysm-wasm/src/blacksmith.rs's `hlr_words`, which
   * reads and ignores the two).
   */
  const hlrWords = (o) => Float64Array.of(
    o.size ?? 0, o.projection, ...o.direction, ...o.up, ...o.eye, ...o.target,
    o.tolerance, o.smooth_angle, o.feature_angle, o.iso, o.reserved ?? 0,
  );
  /** The wasm's return, as the C call's: written into the out-argument and `true` where C fills one, the arrays under the C struct's names, else as it is. */
  function back(short, args, result) {
    if (short === 'mesh_file') {
      // the bytes themselves as the "pointer", their length into the dropped `size_t *len`
      args[6][0] = result.length;
      return result;
    }
    if (short === '3dm_bytes' || short === 'assembly_3dm_bytes') {
      // `{ bytes, notes }`: the bytes themselves as the "pointer" (their length into the dropped
      // `size_t *len`), and what C leaves in `last_error` on success
      args[args.length - 1][0] = result.bytes.length;
      error = String(result.notes || '') || null;
      return result.bytes;
    }
    if (short === 'profile_loops' || short === 'profile_chain_order') {
      // the padded loops / the `[index, turned]` pairs into C's `uint32_t` out-array
      args[3].set(result);
      return true;
    }
    if (short in LISTS) {
      // the ids as the "pointer", their count into the dropped `size_t *count` slot
      const count = args[LISTS[short]];
      count[0] = typeof count[0] === 'bigint' ? BigInt(result.length) : result.length;
      return result;
    }
    if (short === 'silhouette_beziers') {
      // sixteen doubles a curve; an empty array is the empty answer, which C gives as null
      args[2][0] = result.length / 16;
      return result.length ? result : null;
    }
    if (short === 'edge') {
      const raw = args[2];
      raw.kind = String(result.kind); raw.faces = result.faces; raw.face_count = result.faces.length;
      raw.segments = result.segments; raw.segment_count = result.segments.length / 6;
      return true;
    }
    if (short === 'hit') {
      const raw = args[2];
      raw.run = Boolean(result.run); raw.touch = Boolean(result.touch);
      for (const name of ['start', 'end']) { const p = result[name]; raw[name] = { x: p[0], y: p[1], z: p[2] }; }
      for (const name of ['a_start', 'a_end', 'b_start', 'b_end']) raw[name] = { ...result[name] };
      return true;
    }
    if (short === 'hits_piece') {
      args[2][0] = Boolean(result.inside);
      Object.assign(args[3], result.start); Object.assign(args[4], result.end);
      return true;
    }
    if (short === 'edge_curve' || short === 'intersection_curve') {
      const raw = args[2];
      raw.kind = String(result.kind);
      for (const name of ['origin', 'x', 'y', 'z']) { const p = result[name]; raw[name] = { x: p[0], y: p[1], z: p[2] }; }
      raw.radius = result.radius; raw.radius2 = result.radius2; raw.t0 = result.t0; raw.t1 = result.t1; raw.degree = result.degree;
      raw.knots = result.knots; raw.knot_count = result.knots.length;
      raw.poles = result.poles; raw.pole_count = result.poles.length / 3;
      raw.weights = result.weights ?? null;
      return true;
    }
    if (short === 'intersection_chain') {
      const raw = args[2];
      raw.points = result.points; raw.point_count = result.points.length / 3;
      raw.face_a = result.face_a; raw.face_b = result.face_b;
      raw.closed = result.closed; raw.tangent = result.tangent; raw.has_curve = result.has_curve;
      return true;
    }
    if (short === 'hlr_line' || short === 'hlr_report') {
      // the record, into the out-struct (args[2] / args[1]) under the C struct's own field names
      Object.assign(args[short === 'hlr_line' ? 2 : 1], result);
      return true;
    }
    if (short === 'check_finding') {
      // the record, into the out-struct at args[2]; `index`/`other` arrive as NONE where C writes NONE
      const raw = args[2];
      raw.kind = String(result.kind); raw.argument = result.argument;
      raw.index = result.index; raw.other = result.other; raw.size = result.size;
      return true;
    }
    if (short === 'intersection_overlap') {
      const raw = args[2];
      raw.face_a = result.face_a; raw.face_b = result.face_b;
      raw.points = result.points; raw.point_count = result.points.length / 3;
      raw.loop_offsets = result.loop_offsets; raw.loop_count = result.loop_offsets.length;
      return true;
    }
    if (short === 'solid_bounds_box' || short === 'box_moved') {
      // `result` is six numbers (lo, then hi), into the `Box` out-struct at args[2].
      const raw = args[2];
      raw.lo = result.slice(0, 3); raw.hi = result.slice(3, 6);
      return true;
    }
    if (short === 'boxes_apart') {
      args[4][0] = Boolean(result);
      return true;
    }
    if (short === 'mass_properties') {
      // 34 numbers in `CadaclysmBlacksmithMassProperties`' own field order, into the out
      // object at args[2] -- see the export's doc comment in crates/cadaclysm-wasm/src/
      // blacksmith.rs for why they cross flat. `_mass` reads these names.
      const v = Array.from(result);
      if (v.length !== 34) throw new Error(`mass_properties: the wasm returned ${v.length} figures, not 34`);
      const raw = args[2];
      [raw.closed, raw.inverted, raw.accuracy_met, raw.from_mesh] = v.slice(0, 4);
      [raw.area, raw.area_error, raw.volume, raw.volume_error] = v.slice(4, 8);
      raw.centroid = v.slice(8, 11); raw.centroid_error = v[11];
      raw.inertia = v.slice(12, 21); raw.inertia_error = v[21];
      raw.principal_moments = v.slice(22, 25); raw.principal_axes = v.slice(25, 34);
      return true;
    }
    if (short === 'oriented_box') {
      // 15 numbers: centre 3, axes 9 (row-major), half 3 -- into the out-struct at args[2].
      const v = Array.from(result);
      if (v.length !== 15) throw new Error(`oriented_box: the wasm returned ${v.length} figures, not 15`);
      const raw = args[2];
      raw.centre = v.slice(0, 3); raw.axes = v.slice(3, 12); raw.half = v.slice(12, 15);
      return true;
    }
    if (short === 'edge_length' || short === 'profile_length' || short === 'nurbs_curve_length') {
      // 4 numbers: length, error, accuracy_met and from_polyline as 1/0 -- into the out-struct
      // that is the C call's last argument.
      const v = Array.from(result);
      if (v.length !== 4) throw new Error(`${short}: the wasm returned ${v.length} figures, not 4`);
      const raw = args[short === 'edge_length' ? 3 : 2];
      [raw.length, raw.error, raw.accuracy_met, raw.from_polyline] = v;
      return true;
    }
    if (short === 'edge_point_at_length' || short === 'profile_point_at_length' || short === 'nurbs_curve_point_at_length') {
      // 10 numbers: point 3, tangent 3, parameter, segment (NONE as 4294967295), error, from_polyline 1/0
      // -- into the out-struct that is the C call's last argument.
      const raw = args[short === 'edge_point_at_length' ? 4 : 3];
      _atFromDoubles(raw, Array.from(result), short, 'not 10');
      return true;
    }
    if (short === 'fillet_surfaces') {
      // `[sheet, rail_a, rail_b, error]`: each into its out-array (args[9], args[10], args[11])
      const v = Array.from(result, Number);
      if (v.length !== 4) throw new Error(`${short}: the wasm returned ${v.length} figures, not 4`);
      args[9][0] = v[1]; args[10][0] = v[2]; args[11][0] = v[3];
      return v[0];
    }
    if (short === 'join_sheets') {
      // `[solid, sewn, naked_before, naked_after, refused, turned, worst_gap, closed]`: the report into args[3]
      const v = Array.from(result, Number);
      if (v.length !== 8) throw new Error(`${short}: the wasm returned ${v.length} figures, not 8`);
      const raw = args[3];
      [raw.sewn, raw.naked_before, raw.naked_after, raw.refused, raw.turned, raw.worst_gap, raw.closed] = v.slice(1, 8);
      return v[0];
    }
    if (short === 'recess') {
      // `[solid, sheet, fillet, walls, pane]`: the four face counts into the `uint32_t *faces_out` at args[7]
      const v = Array.from(result, Number);
      if (v.length !== 5) throw new Error(`${short}: the wasm returned ${v.length} figures, not 5`);
      for (let i = 0; i < 4; i++) args[7][i] = v[1 + i];
      return v[0];
    }
    if (short === 'mirror_join') {
      // `[solid, seams, squared, moved, gap, angle, curvature, naked]`: the report into the `double *report_out` at args[4]
      const v = Array.from(result, Number);
      if (v.length !== 8) throw new Error(`${short}: the wasm returned ${v.length} figures, not 8`);
      for (let i = 0; i < 7; i++) args[4][i] = v[1 + i];
      return v[0];
    }
    if (short === 'pattern_rectangular' || short === 'pattern_circular' || short === 'pattern_along') {
      // the placements themselves, 16 doubles each: C's count, and into `out` (last) when given
      const v = Array.from(result, Number);
      const out = args[args.length - 1];
      if (out != null) for (let i = 0; i < v.length; i++) out[i] = v[i];
      return v.length / 16;
    }
    if (short === 'pattern' || short === 'pattern_feature') {
      // `[solid, instances, booleans, missed]`: the report into the `double *report_out`, last
      const v = Array.from(result, Number);
      if (v.length !== 4) throw new Error(`${short}: the wasm returned ${v.length} figures, not 4`);
      const report = args[args.length - 1];
      if (report != null) for (let i = 0; i < 3; i++) report[i] = v[1 + i];
      return v[0];
    }
    if (short === 'hole') {
      // `[solid, holes, faces_added, bottom...]`: into the `double[2]` at args[14] and the bottoms at args[15]
      const v = Array.from(result, Number);
      if (v.length < 3) throw new Error(`${short}: the wasm returned ${v.length} figures, not 3 or more`);
      if (args[14] != null) { args[14][0] = v[1]; args[14][1] = v[2]; }
      if (args[15] != null) for (let i = 3; i < v.length; i++) args[15][i - 3] = v[i];
      return v[0];
    }
    if (short === 'continuity' || short === 'edge_continuity') {
      // 13 numbers in the struct's field order, into the out-record (the C call's last argument)
      const v = Array.from(result, Number);
      if (v.length !== 13) throw new Error(`${short}: the wasm returned ${v.length} figures, not 13`);
      _continuityInto(args[args.length - 1], v, 0);
      return true;
    }
    if (short === 'curvature_turns') {
      // 7 counts in `CadaclysmBlacksmithCurvatureTurns`'s field order, into the out-record at args[3]
      const v = Array.from(result, Number);
      if (v.length !== 7) throw new Error(`${short}: the wasm returned ${v.length} figures, not 7`);
      const raw = args[3];
      raw.gaussian_positive = v[0]; raw.gaussian_negative = v[1]; raw.gaussian_turns = v[2];
      raw.mean_positive = v[3]; raw.mean_negative = v[4]; raw.mean_turns = v[5]; raw.samples = v[6];
      return true;
    }
    if (short === 'highlight_kink') {
      // 11 numbers in `CadaclysmBlacksmithHighlightKink`'s field order, into the out-record at args[3]
      const v = Array.from(result, Number);
      if (v.length !== 11) throw new Error(`${short}: the wasm returned ${v.length} figures, not 11`);
      const raw = args[3];
      raw.angle = v[0]; raw.at = v.slice(1, 4); raw.light_point = v.slice(4, 7); raw.light_direction = v.slice(7, 10);
      raw.samples = v[10];
      return true;
    }
    if (short === 'nurbs_curve_knot_continuity') {
      // 10 numbers in `CadaclysmBlacksmithKnotContinuity`'s field order, into the out-record at args[1]
      const v = Array.from(result, Number);
      if (v.length !== 10) throw new Error(`${short}: the wasm returned ${v.length} figures, not 10`);
      const raw = args[1];
      raw.angle = v[0]; raw.angle_parameter = v[1]; raw.angle_at = v.slice(2, 5);
      raw.curvature = v[5]; raw.curvature_parameter = v[6]; raw.curvature_at = v.slice(7, 10);
      return true;
    }
    if (short === 'n_sided_patch') {
      // `[solid, faces, boundary (13), internal (13), corner_angle]`: the report into args[4]
      const v = Array.from(result, Number);
      if (v.length !== 29) throw new Error(`${short}: the wasm returned ${v.length} figures, not 29`);
      const raw = args[4];
      raw.faces = v[1]; raw.boundary = {}; raw.internal = {};
      _continuityInto(raw.boundary, v, 2); _continuityInto(raw.internal, v, 15);
      raw.corner_angle = v[28];
      return v[0];
    }
    if (short === 'sweep_rail' || short === 'sweep_two_rails' || short === 'edge_surface' || short === 'network_surface'
      || short === 'flange' || short === 'extrude_to' || short === 'surface_faired') {
      // `[sheet, error]`: the error into the one-double `error_out` array, last, the handle returned
      const v = Array.from(result, Number);
      if (v.length !== 2) throw new Error(`${short}: the wasm returned ${v.length} figures, not 2`);
      args[args.length - 1][0] = v[1];
      return v[0];
    }
    if (short === 'nurbs_curve_fit' || short === 'nurbs_curve_projected_to_face' || short === 'nurbs_curve_pulled_to_face'
      || short === 'nurbs_curve_fair' || short === 'nurbs_curve_faired' || short === 'nurbs_curve_offset_on_sheet') {
      // `[curve, error]`: the error into the one-double `error_out` array, last, the handle returned
      const v = Array.from(result, Number);
      if (v.length !== 2) throw new Error(`${short}: the wasm returned ${v.length} figures, not 2`);
      args[args.length - 1][0] = v[1];
      return v[0];
    }
    if (short === 'panel_gap') {
      // `[left, right]`: the two panels' handles, into the caller's `out` array (args[5])
      const handles = Array.from(result, Number);
      if (handles.length !== 2) throw new Error(`${short}: the wasm returned ${handles.length} handles, not 2`);
      args[5][0] = handles[0]; args[5][1] = handles[1];
      return true;
    }
    if (short === 'nurbs_curve_tween') {
      // the tweens' handles, into the caller's `out` array (args[7])
      const handles = Array.from(result, Number);
      for (let i = 0; i < handles.length; i++) args[7][i] = handles[i];
      return true;
    }
    if (short === 'nurbs_curve_curvature') {
      // 14 numbers: kappa, tangent, normal, binormal, centre, has_centre -- into the out-struct at args[2]
      const v = Array.from(result, Number);
      if (v.length !== 14) throw new Error(`${short}: the wasm returned ${v.length} figures, not 14`);
      const raw = args[2];
      raw.kappa = v[0]; raw.tangent = v.slice(1, 4); raw.normal = v.slice(4, 7);
      raw.binormal = v.slice(7, 10); raw.centre = v.slice(10, 13); raw.has_centre = v[13];
      return true;
    }
    if (_DIVIDES.has(short)) {
      // a flat array, 10 numbers a sample: the list itself, which `_samples` reads
      const v = Array.from(result);
      if (v.length % 10 !== 0) throw new Error(`${short}: the wasm returned ${v.length} figures, not a multiple of 10`);
      return { doubles: v };
    }
    if (short === 'rtree_bounds') {
      // 6 numbers, min then max, into the `double[6]` out-array at args[1]
      const v = Array.from(result);
      if (v.length !== 6) throw new Error(`rtree_bounds: the wasm returned ${v.length} figures, not 6`);
      args[1].set(v);
      return true;
    }
    if (_RTREE_QUERIES.has(short)) {
      // a flat array, 2 numbers a row -- `(id, distance)` or `(a, b)`: the list itself, which
      // `_rtreeHits`/`_rtreePairs` read. An object, so an empty answer is not the 0 a refusal is.
      const v = Array.from(result);
      if (v.length % 2 !== 0) throw new Error(`${short}: the wasm returned ${v.length} figures, not 2 a row`);
      return { rows: v };
    }
    if (short === 'interpolator_at' || short === 'interpolator_sample') {
      // the values, into the caller's out-array -- args[3] and its length args[4] for `_at`,
      // args[4] and args[5] for `_sample` -- refused as C refuses an `out_len` too short
      const at = short === 'interpolator_at' ? 3 : 4;
      const v = Array.from(result), outLen = args[at + 1];
      if (v.length > outLen) { error = `${short}: out holds ${outLen} numbers, not ${v.length}`; return false; }
      args[at].set(v);
      return true;
    }
    if (short === 'regions') {
      // a flat array, 9 numbers a region and then 2 a side: the list itself, which `_regions`
      // reads. An object, so the answer is never the 0 a refusal is.
      return { regionRows: Array.from(result) };
    }
    if (short === 'contains' || short === 'classifier_contains') {
      // the containment code, into the one-element `Uint32Array` at the C call's last argument
      args[short === 'contains' ? 3 : 2][0] = Number(result);
      return true;
    }
    if (short === 'closest') {
      // the record, into the out-struct at args[5]: `on_*` arrive as `Float64Array`s, `edge_*`
      // as NONE where C writes NONE, `refined` as a bool
      const raw = args[5];
      raw.distance = result.distance;
      raw.on_a = Array.from(result.on_a); raw.on_b = Array.from(result.on_b);
      raw.kind_a = String(result.kind_a); raw.index_a = result.index_a; raw.edge_a = result.edge_a;
      raw.kind_b = String(result.kind_b); raw.index_b = result.index_b; raw.edge_b = result.edge_b;
      raw.refined = result.refined ? 1 : 0;
      return true;
    }
    if (short === 'closest_point' || short === 'projector_closest_point' || short === 'face_closest_point') {
      // the foot object into the out-struct and C's 1; the export's null (beyond `max_distance`)
      // is C's 0, the struct untouched. `edge` arrives as NONE where C writes NONE, `uv` as NaN
      // off a face, `refined` as a bool
      if (result === null || result === undefined) return 0;
      const raw = args[short === 'closest_point' ? 4 : 3];
      raw.distance = result.distance; raw.point = Array.from(result.point);
      raw.kind = String(result.kind); raw.index = result.index; raw.edge = result.edge;
      raw.uv = Array.from(result.uv); raw.normal = Array.from(result.normal);
      raw.refined = result.refined ? 1 : 0;
      return 1;
    }
    if (short === 'edge_closest_point' || short === 'nurbs_curve_closest_point') {
      // five doubles into the out-array, C's 1
      const v = Array.from(result, Number);
      if (v.length !== 5) throw new Error(`${short}: the wasm returned ${v.length} figures, not 5`);
      args[short === 'edge_closest_point' ? 3 : 2].set(v);
      return 1;
    }
    if (short === 'nurbs_curve_closest_point_within' || short === 'nurbs_curve_closest_points' || short === 'curve_closest_points'
      || short === 'projector_curve_closest_points' || short === 'nurbs_curve_closest_object'
      || short === 'triangle_mesh_closest_point' || short === 'triangle_mesh_curve_closest_points') {
      // the export's null (beyond `max_distance`) is C's 0, the out-param untouched; else its
      // answer into the out-param in the C struct's shape, and C's 1
      if (result === null || result === undefined) return 0;
      const pointFoot = (raw, r) => {
        raw.distance = r.distance; raw.point = Array.from(r.point);
        raw.kind = String(r.kind); raw.index = r.index; raw.edge = r.edge;
        raw.uv = Array.from(r.uv); raw.normal = Array.from(r.normal);
        raw.refined = r.refined ? 1 : 0;
        return raw;
      };
      const bodyFoot = (raw, r) => {
        raw.distance = r.distance; raw.t = r.t; raw.point_on_curve = Array.from(r.point_on_curve);
        raw.body = pointFoot({}, r.body); raw.crossing = r.crossing ? 1 : 0;
        return raw;
      };
      const curvePair = (raw, r) => {
        raw.distance = r.distance; raw.t_a = r.t_a; raw.point_a = Array.from(r.point_a);
        raw.t_b = r.t_b; raw.point_b = Array.from(r.point_b);
        return raw;
      };
      // a mesh point: the export's `kind` string as C's number; `vertices` the export's own 0-2
      // numbers as they are -- never padded to C's two UINT32_MAX-marked slots, which `MeshPoint`
      // drops on the native route
      const meshPoint = (raw, r) => {
        raw.point = Array.from(r.point); raw.distance = r.distance; raw.triangle = r.triangle;
        raw.kind = _MESH_KINDS.indexOf(String(r.kind)); raw.barycentric = Array.from(r.barycentric);
        raw.vertices = Array.from(r.vertices, Number);
        return raw;
      };
      const curveMesh = (raw, r) => {
        raw.distance = r.distance; raw.t = r.t; raw.point_on_curve = Array.from(r.point_on_curve);
        raw.mesh = meshPoint({}, r.mesh); raw.crossing = r.crossing ? 1 : 0;
        return raw;
      };
      if (short === 'nurbs_curve_closest_point_within') {
        const v = Array.from(result, Number);
        if (v.length !== 5) throw new Error(`${short}: the wasm returned ${v.length} figures, not 5`);
        args[3].set(v);
      } else if (short === 'nurbs_curve_closest_points') {
        curvePair(args[3], result);
      } else if (short === 'nurbs_curve_closest_object') {
        // only the member `answer_kind` names is present, and only it is written
        const raw = args[4];
        raw.which = result.which; raw.answer_kind = result.answer_kind; raw.distance = result.distance; raw.t = result.t;
        raw.point_on_curve = Array.from(result.point_on_curve); raw.point_on_item = Array.from(result.point_on_item);
        if (result.answer_kind === 0) raw.body = bodyFoot({}, result.body);
        if (result.answer_kind === 1) raw.pair = curvePair({}, result.pair);
        if (result.answer_kind === 3) raw.mesh = curveMesh({}, result.mesh);
      } else if (short === 'triangle_mesh_closest_point') {
        meshPoint(args[3], result);
      } else if (short === 'triangle_mesh_curve_closest_points') {
        curveMesh(args[3], result);
      } else {
        bodyFoot(args[short === 'curve_closest_points' ? 4 : 3], result);
      }
      return 1;
    }
    if (short === 'collider_stats') {
      const raw = args[1];
      for (const name of ['considered', 'world_boxes', 'oriented_boxes', 'skipped_share', 'cached', 'closed_form', 'meshed', 'refused', 'confirmed']) raw[name] = result[name];
      return true;
    }
    if (short === 'collisions_hit') {
      const raw = args[2];
      raw.a = result.a; raw.b = result.b; raw.overlap = Boolean(result.overlap); raw.depth = result.depth;
      raw.positions = result.positions; raw.normals = result.normals; raw.indices = result.indices;
      raw.vertex_count = result.positions.length / 3; raw.index_count = result.indices.length;
      raw.text = result.text;
      return true;
    }
    if (short === 'clashes_at') {
      // the row, into the out-struct at args[2]: `on_*` arrive as `Float64Array`s, `edge_*` as
      // NONE where C writes NONE, `refined` as a bool
      const raw = args[2];
      raw.a = result.a; raw.b = result.b; raw.kind = String(result.kind); raw.distance = result.distance;
      raw.on_a = Array.from(result.on_a); raw.on_b = Array.from(result.on_b);
      raw.kind_a = String(result.kind_a); raw.index_a = result.index_a; raw.edge_a = result.edge_a;
      raw.kind_b = String(result.kind_b); raw.index_b = result.index_b; raw.edge_b = result.edge_b;
      raw.refined = result.refined ? 1 : 0; raw.depth = result.depth; raw.text = String(result.text);
      return true;
    }
    if (short === 'swept_clashes_at') {
      // the row, into the out-struct at args[2]
      const raw = args[2];
      raw.a = result.a; raw.b = result.b; raw.first_time = result.first_time; raw.interval_count = result.interval_count;
      return true;
    }
    if (short === 'thickness_gauge_mesh') {
      // the copies, into the out-struct at args[2] under the C struct's names: the typed arrays
      // are handed on as they are (`_doublesAt`/`_uint32s` read them like a pointer)
      const raw = args[2];
      raw.positions = result.positions; raw.normals = result.normals;
      raw.indices = result.indices; raw.faces = result.faces;
      raw.vertex_count = result.positions.length / 3; raw.triangle_count = result.faces.length;
      return true;
    }
    if (short === 'thickness_gauge_face') {
      // `{found, ...}` into the out-struct at args[5]; a null number is C's NaN
      const raw = args[5];
      raw.found = Boolean(result.found); raw.uniform = Boolean(result.uniform);
      raw.thickness = result.thickness ?? NaN; raw.min = result.min ?? NaN; raw.max = result.max ?? NaN;
      return true;
    }
    if (short === 'thicknesses_at') {
      // the row, into the out-struct at args[2]; null `vertex` is C's NONE, null `sphere` NaN
      const raw = args[2];
      raw.body = result.body; raw.face = result.face; raw.vertex = result.vertex ?? NONE;
      raw.point = Array.from(result.point); raw.thickness = result.thickness; raw.opposite = Array.from(result.opposite);
      raw.opposite_body = result.opposite_body; raw.opposite_face = result.opposite_face;
      raw.knife = Boolean(result.knife); raw.exact_thickness = result.exact_thickness;
      raw.exact_opposite = Array.from(result.exact_opposite); raw.sphere = result.sphere ?? NaN;
      return true;
    }
    if (short === 'mesh_thicknesses_at') {
      const raw = args[2];
      raw.mesh = result.mesh; raw.vertex = result.vertex; raw.thickness = result.thickness;
      raw.point = Array.from(result.point); raw.opposite = Array.from(result.opposite);
      raw.opposite_mesh = result.opposite_mesh; raw.opposite_triangle = result.opposite_triangle;
      raw.knife = Boolean(result.knife);
      return true;
    }
    if (short === 'fem_mesh_view') {
      // The arrays and the summary, into the out-struct at args[1]. The typed arrays
      // are handed on as they are: `_doublesAt`/`_uint32s` read a typed array the
      // same way they read a pointer, so `FemMesh`'s accessors need no branch of
      // their own. The wasm object carries the counts the C struct does.
      const raw = args[1];
      for (const name of ['nodes', 'triangles', 'triangle_face', 'node_kind', 'node_entity', 'node_count', 'triangle_count',
        'face_count', 'edge_count', 'vertex_count', 'open_edge_count', 'folded_edge_count',
        'watertight', 'from_mesh', 'min_angle', 'worst_triangle', 'longest_edge']) raw[name] = result[name];
      return true;
    }
    if (short === 'fem_mesh_edge') {
      // The record, into the out-struct at args[2]. The counts are the arrays' own
      // lengths: the wasm object carries no `node_count`/`run_count`, a typed array
      // knowing its own length.
      const raw = args[2];
      raw.id = result.id;
      raw.nodes = result.nodes; raw.node_count = result.nodes.length;
      raw.runs = result.runs; raw.run_count = result.runs.length;
      raw.face_a = result.face_a; raw.face_b = result.face_b;
      raw.end_a = result.end_a; raw.end_b = result.end_b;
      raw.closed = result.closed; raw.seam = result.seam;
      return true;
    }
    if (short === 'fem_mesh_vertex') {
      const raw = args[2];
      raw.node = result.node; raw.point = result.point; raw.has_position = result.has_position;
      return true;
    }
    if (short === 'fem_mesh_open_edge' || short === 'fem_mesh_folded_edge') {
      // A census row, into the three one-element `Uint32Array`s at args[2..4].
      args[2][0] = result.a; args[3][0] = result.b; args[4][0] = result.brep_edge;
      return true;
    }
    if (short === 'fem_mesh_crossing') {
      // A crossing row, into the two one-element `Uint32Array`s at args[2..3] --
      // `fem_mesh_open_edge`/`fem_mesh_folded_edge`'s shape with no third field.
      args[2][0] = result.a; args[3][0] = result.b;
      return true;
    }
    if (short === 'subd_parts') {
      // The copies, into the out-struct at args[1], under the C struct's names: `Subd` reads
      // them through `_doublesAt`/`_uint32s`, which pass a typed array through as it is. The
      // counts are the C struct's (vertices, faces, pairs), not the arrays' lengths.
      const raw = args[1];
      const kind = Number(result.selection_kind);
      raw.positions = result.positions; raw.vertex_count = result.positions.length / 3;
      raw.face_sizes = result.face_sizes; raw.face_count = result.face_sizes.length;
      raw.face_indices = result.face_indices; raw.index_count = result.face_indices.length;
      raw.creases = result.creases; raw.crease_count = result.creases.length / 2;
      raw.pins = result.pins; raw.pin_count = result.pins.length;
      raw.symmetry_axis = Number(result.symmetry_axis); raw.symmetry_tolerance = Number(result.symmetry_tolerance);
      raw.selection_kind = kind; raw.selection = result.selection;
      raw.selection_count = kind === 1 ? result.selection.length / 2 : result.selection.length;
      return true;
    }
    if (short === 'subd_smooth_mesh') {
      const raw = args[2];
      raw.positions = result.positions; raw.vertex_count = result.positions.length / 3;
      raw.normals = result.normals; raw.indices = result.indices; raw.index_count = result.indices.length;
      raw.triangle_face = result.triangle_face;
      return true;
    }
    if (short === 'subd_pick') {
      // `[a, b]` into C's two-id out-array; null is "nothing near", which C gives as `false`
      // with an **empty** `last_error` -- never a refusal's text, and never the `null` that
      // says no call failed.
      if (result == null) { error = ''; return false; }
      args[3][0] = result[0]; args[3][1] = result[1];
      return true;
    }
    if (short === 'solid_transform' || short === 'solid_convert_to_nurbs') {
      // `[solid, inexact]`: the count into the `uint32_t *inexact_out` at args[2], the handle returned
      args[2][0] = result[1];
      return result[0];
    }
    if (short === 'subd_to_solid') {
      // `[solid, report]`: the report into the out-struct at args[4], the handle returned.
      const [handle, report] = result;
      const raw = args[4];
      for (const name of ['regular', 'refined', 'steps', 'levels', 'deviation', 'g1_angle_deg']) raw[name] = Number(report[name]);
      raw.deviation_at = Array.from(report.deviation_at); raw.g1_at = Array.from(report.g1_at);
      return handle;
    }
    if (short === 'colour' || short === 'profile_colour' || short === 'edge_colour') { if (result == null) return false; args[short === 'profile_colour' ? 1 : 2].set(result); return true; }
    if (short === 'parse_colour') { if (result == null) return false; args[1].set(result); return true; }
    if (short === 'option_get') { args[1][0] = result; return true; }
    if (short === 'solid_tolerances') {   // `[absolute, angular]`, into the two out-arrays
      const v = Array.from(result, Number);
      if (args[1] != null) args[1][0] = v[0];
      if (args[2] != null) args[2][0] = v[1];
      return true;
    }
    if (short === 'manifold') { args[1].set(result); return true; }
    if (short === 'bounds' || short === 'bounds64') { args[2].set(result.slice(0, 3)); args[3].set(result.slice(3, 6)); return true; }
    if (short === 'box' || short === 'job_stock') { args[1].set(result.slice(0, 3)); args[2].set(result.slice(3, 6)); return true; }
    if (short === 'frame_fit') {
      // 13 numbers: the frame into `out` (args[2]), the deviation into `deviation_out` (args[3]), if asked
      const v = Array.from(result);
      if (v.length !== 13) throw new Error(`frame_fit: the wasm returned ${v.length} figures, not 13`);
      args[2].set(v.slice(0, 12));
      if (args[3] != null) args[3][0] = v[12];
      return true;
    }
    if (short === 'face_origin_at' || short === 'edge_origin_at') {
      const v = Array.from(result, Number);
      if (v.length !== 2) throw new Error(`${short}: the wasm returned ${v.length} numbers, not 2`);
      args[3][0] = v[0]; args[4][0] = v[1];
      return true;
    }
    if (U64_RETURNS.has(short)) return Number(result);
    if (short in SCALARS) { args[SCALARS[short]][0] = Number(result); return true; }
    if (short in OUT) { args[OUT[short]].set(result); return true; }
    if (BOOLS.has(short)) return true;
    if (short === 'mesh' || short === 'mesh64') return { ...result, vertex_count: result.positions.length / 3, index_count: result.indices.length };
    if (short === 'edge_polylines' || short === 'profile_polylines') return { ...result, point_count: result.points.length / 3, polyline_count: result.offsets.length - 1 };
    if (short === 'edge_polyline_colours') return { rgb: result.length ? result : null, count: result.length / 3 };
    if (short === 'mesh_face_triangles') return { counts: result, face_count: result.length };
    return result;
  }
  const shim = {
    // the two the C side owns memory for, and the browser has none
    last_error: () => error,
    string_free: () => {},
    // a `.3dm`'s bytes come back as a `Uint8Array` of the page's own, nothing to release
    bytes_free: () => {},
    // the curves come back as a JS array; there is no C block to release
    silhouette_beziers_free: () => {},
    /** Every body a file draws, as solid handles -- the wasm reads the file itself, readers and kernel being one module. The wasm's own export, not a C entry point (named so `tests/bindings.rs` does not take it for one). */
    open_file(bytes, extension) {
      const read = w['cadaclysm_blacksmith_' + 'open_file'];
      try { return Array.from(read(bytes, extension), Number); } catch (e) { if (trapped(e)) throw e; throw new BuildError(e.message); }
    },
    // -- identity: a history is one flat array over the wasm (`_wasmHistory`), not a handle, and
    // C's readers are answered from it here; `history_free` has nothing to free (the wasm's own
    // export of that name is the document undo history's, which this never reaches)
    history: (out, inputs, count) => wasmHistoryOf('history', out, inputs, count),
    edge_history: (out, inputs, count) => wasmHistoryOf('edge_history', out, inputs, count),
    history_free: () => {},
    history_kept_count: (h) => h.kept.length,
    history_kept_at(h, i, operand, id, outId) {
      const row = entry('history_kept_at', h.kept, i);
      if (row === null) return false;
      [[operand[0], id[0]], outId[0]] = row;
      return true;
    },
    history_modified_count: (h) => h.modified.length,
    history_modified_at(h, i, operand, id) {
      const row = entry('history_modified_at', h.modified, i);
      if (row === null) return false;
      [operand[0], id[0]] = row[0];
      return true;
    },
    history_modified_output_count(h, i) {
      const row = entry('history_modified_output_count', h.modified, i);
      return row === null ? NONE : row[1].length;
    },
    history_modified_output_at(h, i, j) {
      const row = entry('history_modified_output_at', h.modified, i);
      if (row === null) return 0;
      if (!(j >= 0 && j < row[1].length)) { error = `history_modified_output_at: output ${j} of ${row[1].length}`; return 0; }
      return row[1][j];
    },
    history_generated_count: (h) => h.generated.length,
    history_generated_at(h, i) {
      const row = entry('history_generated_at', h.generated, i);
      return row === null ? 0 : row;
    },
    history_deleted_count: (h) => h.deleted.length,
    history_deleted_at(h, i, operand, id) {
      const row = entry('history_deleted_at', h.deleted, i);
      if (row === null) return false;
      [operand[0], id[0]] = row;
      return true;
    },
    // -- attributes: the wasm hands a solid's (a face's) keys and values over as two whole
    // lists; C's count and `_at` readers are answered from them, each refusal under its own C name
    attribute_count(solid) {
      const keys = texts('attribute_count', 'attribute_keys', solid);
      return keys === null ? 0 : keys.length;
    },
    face_attribute_count(solid, face) {
      const keys = texts('face_attribute_count', 'face_attribute_keys', solid, face);
      return keys === null ? NONE : keys.length;
    },
    attribute_key_at: (solid, i) => textAt('attribute_key_at', texts('attribute_key_at', 'attribute_keys', solid), i),
    attribute_value_at: (solid, i) => textAt('attribute_value_at', texts('attribute_value_at', 'attribute_values', solid), i),
    face_attribute_key_at: (solid, face, i) => textAt('face_attribute_key_at', texts('face_attribute_key_at', 'face_attribute_keys', solid, face), i),
    face_attribute_value_at: (solid, face, i) => textAt('face_attribute_value_at', texts('face_attribute_value_at', 'face_attribute_values', solid, face), i),
  };
  /** One history export's flat array as a `_wasmHistory`, or 0 (C's null) with `last_error` set. */
  function wasmHistoryOf(short, out, inputs, count) {
    error = null;
    const handles = Uint32Array.from(Array.from(inputs).slice(0, count), Number);
    let flat;
    try { flat = w['cadaclysm_blacksmith_' + short](out, handles); } catch (e) {
      if (trapped(e)) throw e;
      error = String(e && e.message ? e.message : e).replace(/^Error: /, '');
      return 0;
    }
    return _wasmHistory(flat);
  }
  /** Row `i` of a history list, or null with `last_error` set under `what`. */
  function entry(what, rows, i) {
    error = null;
    if (!(i >= 0 && i < rows.length)) { error = `${what}: entry ${i} of ${rows.length}`; return null; }
    return rows[i];
  }
  /** A whole list export's texts, or null with its refusal renamed to the C reader `what`. */
  function texts(what, short, ...args) {
    const result = proxy[short](...args);
    if (error !== null) {
      const colon = error.indexOf(':');
      if (colon >= 0) error = what + error.slice(colon);
      return null;
    }
    return Array.from(result, String);
  }
  function textAt(what, list, i) {
    if (list === null) return null;
    if (!(i >= 0 && i < list.length)) { error = `${what}: attribute ${i} of ${list.length}`; return null; }
    return list[i];
  }
  const proxy = new Proxy(shim, {
    get(target, short) {
      if (short in target || typeof short !== 'string') return target[short];
      // the building documents' entry points keep their own `cadaclysm_bim_` prefix in the wasm
      const name = RENAMED[short] ?? (short.startsWith('bim_') ? `cadaclysm_${short}` : `cadaclysm_blacksmith_${short}`);
      const fn = w[name];
      if (typeof fn !== 'function') throw new BuildError(`the wasm module has no ${name}: rebuild it with \`sh web/build.sh\``);
      const dropped = DROP[short] ?? [];
      const call = (...args) => {
        error = null;
        if (short === 'select_face' && args[2] == null) args[2] = new Float64Array(0);   // the direction, unread for kinds 0/1/3
        // `b` null with a zero count is "`a` against itself" in C; the export reads an empty
        // array the same way, and has no null to read (an empty `others` never gets here:
        // `clash` refuses it first, since the export would read it as one set)
        if (short === 'clash' && args[2] == null) args[2] = [];
        // one set: `b` and `poses_b` null with a zero count, empty arrays to the export
        if (short === 'swept_clash' && args[3] == null) { args[3] = []; args[5] = new Float64Array(0); }
        // `at` null is "over the face's vertices" in C; the export reads an empty array as that
        if (short === 'thickness_gauge_face' && args[3] == null) args[3] = new Float64Array(0);
        // `b` null is "no second argument" in C; the export reads handle 0 as that
        if (short === 'check' && args[1] == null) args[1] = 0;
        if (short === 'fem_mesh') {
          // cadaclysm_blacksmith_fem_mesh(solid, frame, tolerance, max_size, progress)
          // in crates/cadaclysm-wasm/src/blacksmith.rs: the options struct (args[2], the
          // plain object `_femOptions` built) becomes its two fields, because the export
          // takes them as scalars and has no options-init to fill a struct. `frame` stays
          // as it is -- `null` for the identity, which that export reads as the identity;
          // never a zero-length array, which it refuses as a frame of no numbers.
          const o = args[2];
          args = [args[0], args[1], o.tolerance, o.max_size, args[3], args[4]];
        }
        if (short === 'hlr' || short === 'hlr_mesh' || short === 'projected_outline') {
          // cadaclysm_blacksmith_hlr(solids: &[u32], words: &[f64]) and its two siblings in
          // crates/cadaclysm-wasm/src/blacksmith.rs: the options (args[2], `_hlrOptions`'s plain
          // object) become `hlrWords`' flat array; DROP's [1] drops the count.
          args = [args[0], args[1], hlrWords(args[2])];
        }
        if (short === 'svg_text') {
          // cadaclysm_blacksmith_svg_text(solids: &[u32], words: &[f64]) in
          // crates/cadaclysm-wasm/src/blacksmith.rs: `args[2]` (the plain object
          // _svgOptions() built) becomes `svgWords`'s flat array.
          args = [args[0], args[1], svgWords(args[2])];
        }
        if (short === 'silhouette_beziers') {
          // cadaclysm_blacksmith_silhouette_beziers(solid: u32, words: &[f64]) in
          // crates/cadaclysm-wasm/src/blacksmith.rs: the same `svgWords` flattening as
          // svg_text, the options behind args[1]; DROP's [2] drops the count, which
          // `back` fills from the returned array's length.
          args = [args[0], svgWords(args[1]), args[2]];
        }
        if (short === 'drawing_svg_text') {
          // cadaclysm_blacksmith_drawing_svg_text(solids: &[u32], profiles: &[u32], words: &[f64])
          // in crates/cadaclysm-wasm/src/blacksmith.rs: the same `svgWords` flattening as
          // svg_text above, with the options struct now behind args[4] (solids, solid_count,
          // profiles, profile_count, options) -- DROP's [1, 3] drops both counts, leaving
          // solids, profiles and words in that order.
          args = [args[0], args[1], args[2], args[3], svgWords(args[4])];
        }
        if (short === 'assembly_pair') {
          // cadaclysm_blacksmith_assembly_pair(assembly, joint, kind, frame, end_frame, lower,
          // upper, pitch) in crates/cadaclysm-wasm/src/blacksmith.rs: lower/upper (args[5],
          // args[6]) fold has_lower/has_upper (args[7], args[8]) into themselves as `NaN`
          // standing for "this side unbounded", the wasm export's own convention; freedom_count
          // (args[9]) drops, since a typed array carries its own length.
          const [assembly, joint, kind, frame, endFrame, lower, upper, hasLower, hasUpper, count, pitch] = args;
          let loNan = null, upNan = null;
          if (lower != null) {
            loNan = new Float64Array(count);
            upNan = new Float64Array(count);
            for (let i = 0; i < count; i++) {
              loNan[i] = hasLower[i] ? lower[i] : NaN;
              upNan[i] = hasUpper[i] ? upper[i] : NaN;
            }
          }
          args = [assembly, joint, kind, frame, endFrame, loNan, upNan, pitch];
        }
        if (short === 'assembly_pair_with') {
          // cadaclysm_blacksmith_assembly_pair_with(assembly, joint, kind, frame, end_frame,
          // lower, upper, params): the ranges fold as assembly_pair's do, and param_count
          // (args[11]) drops with freedom_count -- params (args[10]) is a typed array
          // carrying its own length, never null.
          const [assembly, joint, kind, frame, endFrame, lower, upper, hasLower, hasUpper, count, params] = args;
          let loNan = null, upNan = null;
          if (lower != null) {
            loNan = new Float64Array(count);
            upNan = new Float64Array(count);
            for (let i = 0; i < count; i++) {
              loNan[i] = hasLower[i] ? lower[i] : NaN;
              upNan[i] = hasUpper[i] ? upper[i] : NaN;
            }
          }
          args = [assembly, joint, kind, frame, endFrame, loNan, upNan, params.subarray(0, args[11])];
        }
        // `assembly_sequence`'s states (2 after the name) and interpolations (4) are names too.
        // `assembly_link`'s placements, and `assembly_state`'s joints, are names, not handles:
        // cadaclysm_blacksmith_assembly_link/_state in crates/cadaclysm-wasm/src/blacksmith.rs
        // take a `Vec<String>`, so `arg`'s generic array rule (a JS array is a handle list,
        // turned into a `Uint32Array`) must not touch them.
        if (short === 'n_sided_patch') {
          // cadaclysm_blacksmith_n_sided_patch(ids, ranges, bulge, tolerance): the rows (args[0],
          // args[1] of them) cross as their handles and indices, 5 a row (a null sheet or curve 0),
          // and the range's two ends, 2 a row; the report (args[4]) is `back`'s
          const rows = args[0].slice(0, args[1]);
          args = [Uint32Array.from(rows.flatMap((b) => [b.sheet ?? 0, b.face, b.side, b.level, b.curve ?? 0]), Number),
            Float64Array.from(rows.flatMap((b) => [b.from, b.to])), args[2], args[3], args[4]];
        }
        if (short === 'nurbs_curve_closest_object') {
          // cadaclysm_blacksmith_nurbs_curve_closest_object(curve, items, max_distance, tolerance):
          // C's kinds and five arrays (each kind taking the next of its array, as C reads them)
          // become the export's one list of one-key objects, `{solid}`, `{curve}`, `{point}`,
          // `{projector}` or `{mesh}`; the out-param (args[4] after the rewrite) is `back`'s
          const [curve, kinds, count, solids, , curves, , points, , projectors, , meshes, , maxDistance, tolerance, out] = args;
          const next = [0, 0, 0, 0, 0];
          const items = [];
          for (let i = 0; i < count; i++) {
            const kind = kinds[i], k = next[kind]++;
            if (kind === 0) items.push({ solid: solids[k] });
            else if (kind === 1) items.push({ curve: curves[k] });
            else if (kind === 2) items.push({ point: Array.from(points.subarray(3 * k, 3 * k + 3)) });
            else if (kind === 3) items.push({ projector: projectors[k] });
            else items.push({ mesh: meshes[k] });
          }
          args = [curve, items, maxDistance, tolerance, out];
        }
        const passed = args.filter((_, i) => !dropped.includes(i))
          // the nearest object's items are objects, not a handle list for `arg`
          .map((a, i) => (short === 'nurbs_curve_closest_object' && i === 1 ? a : ((short === 'assembly_link' || short === 'assembly_state') && i === 2)
            || ((short === 'assembly_posed' || short === 'assembly_swept_clash') && i === 1)
            || (short === 'assembly_sequence' && (i === 2 || i === 4))
            // `mesh_file`'s names (2 after the dropped count): a `Option<Vec<String>>`, null as it is
            || (short === 'mesh_file' && i === 2 && a != null) ? Array.from(a, String) : arg(a)));
        // the optional `up` / `direction`: NULL natively, undefined over the wasm -- never an empty array
        if (short in OPTIONAL_ARGS) for (const i of OPTIONAL_ARGS[short]) if (passed[i] === null) passed[i] = undefined;
        if (short in U64_ARGS) for (const i of U64_ARGS[short]) passed[i] = BigInt(passed[i]);
        let result;
        try { result = fn(...passed); } catch (e) {
          if (trapped(e)) throw e;   // not a refusal: the kernel is dead, and the page reboots it
          error = String(e && e.message ? e.message : e).replace(/^Error: /, '');
          return short in FAILS ? FAILS[short] : BOOLS.has(short) ? false : 0;
        }
        return back(short, args, result);
      };
      target[short] = call;   // resolved once; `Solid.close` asks for `solid_free` per solid
      return call;
    },
  });
  return proxy;
}

/**
 * A history over the wasm: the export's one flat `u64` array, parsed into the four lists
 * `History` has -- `nk`, then `(operand, id, out)` each; `nm`, then `(operand, id, n, outs...)`
 * each; `ng`, then the ids; `nd`, then `(operand, id)` each. `_wasmLibrary` answers C's
 * `history_*` readers from it, so `Solid.history` reads one code path. Python's `_WasmHistory`.
 */
function _wasmHistory(flatIn) {
  const flat = Array.from(flatIn, Number);
  let at = 0;
  const take = (n) => {
    if (at + n > flat.length) throw new BuildError(`history: the wasm returned ${flat.length} numbers, cut short at ${at}`);
    const out = flat.slice(at, at + n);
    at += n;
    return out;
  };
  const kept = [];
  for (let k = take(1)[0]; k > 0; k--) { const [operand, id, out] = take(3); kept.push([[operand, id], out]); }
  const modified = [];
  for (let k = take(1)[0]; k > 0; k--) { const [operand, id, n] = take(3); modified.push([[operand, id], take(n)]); }
  const generated = take(take(1)[0]);
  const deleted = [];
  for (let k = take(1)[0]; k > 0; k--) { const [operand, id] = take(2); deleted.push([operand, id]); }
  if (at !== flat.length) throw new BuildError(`history: the wasm returned ${flat.length} numbers, ${flat.length - at} past the lists`);
  return { kept, modified, generated, deleted };
}

const _DIVIDES = new Set(['edge_divide_by_count', 'edge_divide_by_length', 'profile_divide_by_count', 'profile_divide_by_length',
  'nurbs_curve_divide_by_count', 'nurbs_curve_divide_by_length', 'nurbs_curve_plane_hits', 'nurbs_curve_face_hits',
  'nurbs_curve_inflections', 'curvature_turn_points']);
// The R-tree's queries: C hands back an owned `RTreeHits *` / `RTreePairs *` read row by row and
// freed, the wasm a flat array of 2 doubles a row with no list handle -- so `rtree_hits_*` /
// `rtree_pairs_*` are native only.
const _RTREE_QUERIES = new Set(['rtree_search', 'rtree_within', 'rtree_nearest', 'rtree_ray', 'rtree_overlaps', 'rtree_self_overlaps']);

/** The wasm's thirteen figures from `at` (`CadaclysmBlacksmithContinuity`'s fields in order), into `raw`. */
function _continuityInto(raw, v, at) {
  raw.gap = v[at]; raw.gap_at = v.slice(at + 1, at + 4);
  raw.angle = v[at + 4]; raw.angle_at = v.slice(at + 5, at + 8);
  raw.curvature = v[at + 8]; raw.curvature_at = v.slice(at + 9, at + 12);
  raw.samples = v[at + 12];
}

/** The wasm's ten figures for one sample, into an out-struct shaped like `CadaclysmBlacksmithAt`. */
function _atFromDoubles(raw, v, what, notTen) {
  if (v.length !== 10) throw new Error(`${what}: the wasm returned ${v.length} figures, ${notTen}`);
  raw.point = v.slice(0, 3); raw.tangent = v.slice(3, 6);
  [raw.parameter, raw.segment, raw.error, raw.from_polyline] = v.slice(6, 10);
}

/**
 * The loaded library's functions, loading on first use. A flavour of the single
 * library binds what it has: a function it leaves out (the writers and parts in the
 * kernel and kernel-reader flavours) throws naming the flavour, when called. A
 * flavour with no kernel (the reader flavour) is refused here.
 */
function _lib() {
  if (library) return library;
  const w = _wasm();
  if (w) { library = _wasmLibrary(w); _flavour = ['wasm', '']; return library; }
  if (_koffiMissing) throw _koffiMissing;
  const found = libraryPath();
  const l = koffi.load(found);
  const flavoured = _flavourOf(l);
  if (flavoured && !flavoured[1].split(',').includes('kernel')) {
    throw new BuildError(`${found}: the '${flavoured[0]}' flavour has no kernel; load cadaclysm, cadaclysm_kernel_reader or cadaclysm_kernel`);
  }
  const f = (proto) => _bind(l, proto, flavoured);
  const string_free = f('void cadaclysm_blacksmith_string_free(void *s)');
  // An owned string: decoded to JS, then handed back to the library to free.
  koffi.disposable('CadaclysmBlacksmithOwnedString', 'str', string_free);
  library = {
    last_error: f('const char *cadaclysm_blacksmith_last_error(void)'),
    version: f('const char *cadaclysm_blacksmith_version(void)'),
    solid_free: f('void cadaclysm_blacksmith_solid_free(CadaclysmBlacksmithSolid *solid)'),
    // `named` returns a fresh handle (an owned pointer, not owned text); `solid_name` is a
    // **borrowed** `const char *` into the solid's own slot, so it is declared `const char *`,
    // never `CadaclysmBlacksmithOwnedString` -- that would hand the slot to `string_free` and
    // double-free it (see `the_node_kernel_binding_frees_every_owned_string`).
    named: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_named(const CadaclysmBlacksmithSolid *solid, const char *name)'),
    solid_name: f('const char *cadaclysm_blacksmith_solid_name(const CadaclysmBlacksmithSolid *solid)'),
    // the material and the outside style: set as `named` is, lent back as `solid_name` is
    with_material: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_with_material(const CadaclysmBlacksmithSolid *solid, const char *material)'),
    solid_material: f('const char *cadaclysm_blacksmith_solid_material(const CadaclysmBlacksmithSolid *solid)'),
    styled: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_styled(const CadaclysmBlacksmithSolid *solid, const char *location, const char *identification)'),
    solid_style_location: f('const char *cadaclysm_blacksmith_solid_style_location(const CadaclysmBlacksmithSolid *solid)'),
    solid_style_identification: f('const char *cadaclysm_blacksmith_solid_style_identification(const CadaclysmBlacksmithSolid *solid)'),
    from_brep: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_from_brep(const void *brep, const char *layout_id)'),
    brep_layout_id: f('const char *cadaclysm_blacksmith_brep_layout_id(void)'),
    profile_free: f('void cadaclysm_blacksmith_profile_free(CadaclysmBlacksmithProfile *profile)'),
    license_set: f('bool cadaclysm_blacksmith_license_set(const char *text_or_path)'),
    license_info: f('const char *cadaclysm_blacksmith_license_info(void)'),
    license_notice_count: f('uint64_t cadaclysm_blacksmith_license_notice_count(void)'),
    build_date: f('const char *cadaclysm_blacksmith_build_date(void)'),
    mesh: f('CadaclysmBlacksmithMesh cadaclysm_blacksmith_mesh(const CadaclysmBlacksmithSolid *solid, double tolerance)'),
    // f64 twins (Task 11): the same tessellation's own double positions/normals, and
    // bounds exact far from the origin -- see the doc comments on `mesh64`/`bounds64` below.
    mesh64: f('CadaclysmBlacksmithMesh64 cadaclysm_blacksmith_mesh64(const CadaclysmBlacksmithSolid *solid, double tolerance)'),
    mesh_face_triangles: f('CadaclysmBlacksmithFaceTriangles cadaclysm_blacksmith_mesh_face_triangles(const CadaclysmBlacksmithSolid *solid, double tolerance)'),
    edge_polylines: f('CadaclysmBlacksmithPolylines cadaclysm_blacksmith_edge_polylines(const CadaclysmBlacksmithSolid *solid, double tolerance)'),
    edge_polyline_colours: f('CadaclysmBlacksmithColours cadaclysm_blacksmith_edge_polyline_colours(const CadaclysmBlacksmithSolid *solid, double tolerance)'),
    // A held tessellation: the accessors below borrow from the handle, not the solid, and
    // stay valid until `tessellation_free` whatever happens to the solid meanwhile. Node
    // copies every array as `mesh`/`mesh64`/`mesh_face_triangles`/`edge_polylines` above
    // already do, so it holds nothing itself -- these are declared for the parity gate
    // and for a caller of `_lib()` who wants the handle directly.
    tessellation: f('CadaclysmBlacksmithTessellation *cadaclysm_blacksmith_tessellation(const CadaclysmBlacksmithSolid *solid, double tolerance)'),
    tessellation_free: f('void cadaclysm_blacksmith_tessellation_free(CadaclysmBlacksmithTessellation *tessellation)'),
    tessellation_mesh: f('CadaclysmBlacksmithMesh cadaclysm_blacksmith_tessellation_mesh(const CadaclysmBlacksmithTessellation *tessellation)'),
    tessellation_mesh64: f('CadaclysmBlacksmithMesh64 cadaclysm_blacksmith_tessellation_mesh64(const CadaclysmBlacksmithTessellation *tessellation)'),
    tessellation_face_triangles: f('CadaclysmBlacksmithFaceTriangles cadaclysm_blacksmith_tessellation_face_triangles(const CadaclysmBlacksmithTessellation *tessellation)'),
    tessellation_edge_polylines: f('CadaclysmBlacksmithPolylines cadaclysm_blacksmith_tessellation_edge_polylines(const CadaclysmBlacksmithTessellation *tessellation)'),
    bounds: f('bool cadaclysm_blacksmith_bounds(const CadaclysmBlacksmithSolid *solid, double tolerance, _Out_ double *min, _Out_ double *max)'),
    bounds64: f('bool cadaclysm_blacksmith_bounds64(const CadaclysmBlacksmithSolid *solid, double tolerance, _Out_ double *min, _Out_ double *max)'),
    box: f('bool cadaclysm_blacksmith_box(const CadaclysmBlacksmithSolid *solid, _Out_ double *min, _Out_ double *max)'),
    step: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_step(const CadaclysmBlacksmithSolid **solids, size_t count, const char *schema, uint32_t unit)'),
    sat_text: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_sat_text(const CadaclysmBlacksmithSolid **solids, size_t count, uint32_t unit)'),
    sat: f('bool cadaclysm_blacksmith_sat(const CadaclysmBlacksmithSolid **solids, size_t count, const char *path, uint32_t unit)'),
    // A `.3dm` is OWNED bytes, not a string: `*len` of them, freed by `bytes_free(bytes, len)`
    // with that same length -- never `string_free`. On success a non-null `last_error` holds
    // the writer's notes, one a line.
    '3dm_bytes': f('uint8_t *cadaclysm_blacksmith_3dm_bytes(const CadaclysmBlacksmithSolid **solids, size_t count, uint32_t unit, _Out_ size_t *len)'),
    '3dm': f('bool cadaclysm_blacksmith_3dm(const CadaclysmBlacksmithSolid **solids, size_t count, const char *path, uint32_t unit)'),
    assembly_3dm_bytes: f('uint8_t *cadaclysm_blacksmith_assembly_3dm_bytes(const CadaclysmBlacksmithAssembly *assembly, uint32_t unit, _Out_ size_t *len)'),
    assembly_3dm: f('bool cadaclysm_blacksmith_assembly_3dm(const CadaclysmBlacksmithAssembly *assembly, const char *path, uint32_t unit)'),
    bytes_free: f('void cadaclysm_blacksmith_bytes_free(uint8_t *bytes, size_t len)'),
    brep_text: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_brep_text(const CadaclysmBlacksmithSolid **solids, size_t count)'),
    brep: f('bool cadaclysm_blacksmith_brep(const CadaclysmBlacksmithSolid **solids, size_t count, const char *path)'),
    svg_options_init: f('void cadaclysm_blacksmith_svg_options_init(_Out_ CadaclysmBlacksmithSvgOptions *options)'),
    svg_text: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_svg_text(const CadaclysmBlacksmithSolid **solids, size_t count, const CadaclysmBlacksmithSvgOptions *options)'),
    svg: f('bool cadaclysm_blacksmith_svg(const CadaclysmBlacksmithSolid **solids, size_t count, const char *path, const CadaclysmBlacksmithSvgOptions *options)'),
    // OWNED, but not as a string: a `double *` of `*count * 16` doubles, freed by the matching
    // `_free(data, count)` -- not `string_free`, and the count must be the one this call wrote.
    silhouette_beziers: f('double *cadaclysm_blacksmith_silhouette_beziers(const CadaclysmBlacksmithSolid *solid, const CadaclysmBlacksmithSvgOptions *options, _Out_ uint32_t *count)'),
    silhouette_beziers_free: f('void cadaclysm_blacksmith_silhouette_beziers_free(double *data, uint32_t count)'),
    // The FEM surface mesh: a handle of the caller's own, and its accessors.
    // `cadaclysm_blacksmith_fem_mesh_msh_text` returns an **owned** `char *` -- this
    // library's convention, as `step`/`sat_text`/`brep_text` above -- where the
    // reader library's twin borrows a slot on its handle and frees nothing. So it is
    // declared as the same `CadaclysmBlacksmithOwnedString`: koffi decodes the string
    // and hands the pointer back to `cadaclysm_blacksmith_string_free`, once. Getting
    // that wrong leaks silently in one direction and takes the process down in the
    // other, which is why `test/fem.test.js` asks one handle for its text twice.
    fem_options_init: f('void cadaclysm_blacksmith_fem_options_init(_Out_ CadaclysmBlacksmithFemOptions *options)'),
    fem_mesh: f('CadaclysmBlacksmithFemMesh *cadaclysm_blacksmith_fem_mesh(const CadaclysmBlacksmithSolid *solid, const double *placement, const CadaclysmBlacksmithFemOptions *options, CadaclysmBlacksmithProgress *progress, void *user)'),
    fem_mesh_free: f('void cadaclysm_blacksmith_fem_mesh_free(CadaclysmBlacksmithFemMesh *m)'),
    fem_mesh_view: f('bool cadaclysm_blacksmith_fem_mesh_view(const CadaclysmBlacksmithFemMesh *m, _Out_ CadaclysmBlacksmithFemMeshView *out)'),
    fem_mesh_edge: f('bool cadaclysm_blacksmith_fem_mesh_edge(const CadaclysmBlacksmithFemMesh *m, uint32_t i, _Out_ CadaclysmBlacksmithFemEdge *out)'),
    fem_mesh_vertex: f('bool cadaclysm_blacksmith_fem_mesh_vertex(const CadaclysmBlacksmithFemMesh *m, uint32_t i, _Out_ CadaclysmBlacksmithFemVertex *out)'),
    fem_mesh_open_edge: f('bool cadaclysm_blacksmith_fem_mesh_open_edge(const CadaclysmBlacksmithFemMesh *m, uint32_t i, _Out_ uint32_t *a, _Out_ uint32_t *b, _Out_ uint32_t *brep_edge)'),
    fem_mesh_folded_edge: f('bool cadaclysm_blacksmith_fem_mesh_folded_edge(const CadaclysmBlacksmithFemMesh *m, uint32_t i, _Out_ uint32_t *a, _Out_ uint32_t *b, _Out_ uint32_t *brep_edge)'),
    fem_mesh_crossing_count: f('uint32_t cadaclysm_blacksmith_fem_mesh_crossing_count(const CadaclysmBlacksmithFemMesh *m)'),
    fem_mesh_crossing: f('bool cadaclysm_blacksmith_fem_mesh_crossing(const CadaclysmBlacksmithFemMesh *m, uint32_t i, _Out_ uint32_t *a, _Out_ uint32_t *b)'),
    fem_mesh_msh_text: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_fem_mesh_msh_text(const CadaclysmBlacksmithFemMesh *m)'),
    fem_mesh_save_msh: f('bool cadaclysm_blacksmith_fem_mesh_save_msh(const CadaclysmBlacksmithFemMesh *m, const char *path)'),
    // `drawing_svg_text`/`drawing_svg`: `svg_text`/`svg` with a second handle list, the
    // profiles on the same page (Task 5a, 2026-09-23) -- refusing in the same words
    // (both read "svg" as their own `what`, not "drawing_svg"), so `writeSvgText`/
    // `writeSvg` call these two unconditionally, a solids-only list included, and
    // `svg_text`/`svg` stay declared only because 0.6.0 says they still work.
    drawing_svg_text: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_drawing_svg_text(const CadaclysmBlacksmithSolid **solids, size_t solid_count, const CadaclysmBlacksmithProfile **profiles, size_t profile_count, const CadaclysmBlacksmithSvgOptions *options)'),
    drawing_svg: f('bool cadaclysm_blacksmith_drawing_svg(const CadaclysmBlacksmithSolid **solids, size_t solid_count, const CadaclysmBlacksmithProfile **profiles, size_t profile_count, const char *path, const CadaclysmBlacksmithSvgOptions *options)'),
    string_free,
    profile_rect: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_rect(double w, double h)'),
    profile_circle: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_circle(double r)'),
    profile_slot: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_slot(double cx, double cy, double length, double r)'),
    profile_polygon: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_polygon(const double *xy, size_t count)'),
    profile_regular_polygon: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_regular_polygon(double cx, double cy, double radius, uint32_t sides, double angle)'),
    profile_circumscribed_polygon: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_circumscribed_polygon(double cx, double cy, double radius, uint32_t sides, double angle)'),
    profile_star: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_star(double cx, double cy, double outer, double inner, uint32_t points, double angle)'),
    profile_spline: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_spline(const double *xy, size_t count, uint32_t degree, const double *weights, bool closed)'),
    profile_with_hole: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_with_hole(const CadaclysmBlacksmithProfile *outer, const CadaclysmBlacksmithProfile *hole)'),
    profile_hits: f('CadaclysmBlacksmithHits *cadaclysm_blacksmith_profile_hits(const CadaclysmBlacksmithProfile *a, const CadaclysmBlacksmithProfile *b, double tolerance)'),
    hits_free: f('void cadaclysm_blacksmith_hits_free(CadaclysmBlacksmithHits *hits)'),
    hit_count: f('uint32_t cadaclysm_blacksmith_hit_count(const CadaclysmBlacksmithHits *hits)'),
    hit: f('bool cadaclysm_blacksmith_hit(const CadaclysmBlacksmithHits *hits, uint32_t i, _Out_ CadaclysmBlacksmithHit *out)'),
    solid_profile_hits: f('CadaclysmBlacksmithHits *cadaclysm_blacksmith_solid_profile_hits(const CadaclysmBlacksmithSolid *solid, const CadaclysmBlacksmithProfile *profile, const double *frame, double tolerance, CadaclysmBlacksmithProgress *progress, void *user)'),
    hits_piece_count: f('uint32_t cadaclysm_blacksmith_hits_piece_count(const CadaclysmBlacksmithHits *hits)'),
    hits_piece: f('bool cadaclysm_blacksmith_hits_piece(const CadaclysmBlacksmithHits *hits, uint32_t i, _Out_ bool *inside, _Out_ CadaclysmBlacksmithSpot *start, _Out_ CadaclysmBlacksmithSpot *end)'),
    hits_piece_profile: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_hits_piece_profile(const CadaclysmBlacksmithHits *hits, uint32_t i)'),
    profile_common: f('CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_profile_common(const CadaclysmBlacksmithProfile *a, const CadaclysmBlacksmithProfile *b, double tolerance)'),
    profile_to_arcs: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_to_arcs(const CadaclysmBlacksmithProfile *p, double tolerance)'),
    profile_offset: f('CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_profile_offset(const CadaclysmBlacksmithProfile *p, double distance, double tolerance)'),
    solid_section: f('CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_solid_section(const CadaclysmBlacksmithSolid *s, double z, double tolerance)'),
    profile_text: f('CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_profile_text(const char *text, double size, const char *font, const uint8_t *font_bytes, size_t font_len, const char *halign, const char *valign, double spacing, const char *direction)'),
    profile_list_count: f('uint32_t cadaclysm_blacksmith_profile_list_count(const CadaclysmBlacksmithProfileList *list)'),
    profile_list_get: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_list_get(const CadaclysmBlacksmithProfileList *list, uint32_t i)'),
    profile_list_free: f('void cadaclysm_blacksmith_profile_list_free(CadaclysmBlacksmithProfileList *list)'),
    path_begin: f('CadaclysmBlacksmithPath *cadaclysm_blacksmith_path_begin(double x, double y)'),
    path_line_to: f('bool cadaclysm_blacksmith_path_line_to(CadaclysmBlacksmithPath *p, double x, double y)'),
    path_arc_to: f('bool cadaclysm_blacksmith_path_arc_to(CadaclysmBlacksmithPath *p, double x, double y, double cx, double cy, bool ccw)'),
    path_bezier_to: f('bool cadaclysm_blacksmith_path_bezier_to(CadaclysmBlacksmithPath *p, double c1x, double c1y, double c2x, double c2y, double x, double y)'),
    path_conic_to: f('bool cadaclysm_blacksmith_path_conic_to(CadaclysmBlacksmithPath *p, double x, double y, double cx, double cy, double weight)'),
    path_parabola_by_vertex: f('bool cadaclysm_blacksmith_path_parabola_by_vertex(CadaclysmBlacksmithPath *p, double x, double y, double vx, double vy)'),
    path_parabola_by_focus: f('bool cadaclysm_blacksmith_path_parabola_by_focus(CadaclysmBlacksmithPath *p, double x, double y, double fx, double fy)'),
    path_parabola: f('CadaclysmBlacksmithPath *cadaclysm_blacksmith_path_parabola(double vx, double vy, double ax, double ay, double focal, double from, double to)'),
    path_nurbs_to: f('bool cadaclysm_blacksmith_path_nurbs_to(CadaclysmBlacksmithPath *p, const double *control_xy, size_t control_count, const double *weights, const double *knots, size_t knot_count, uint32_t degree)'),
    path_end: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_path_end(CadaclysmBlacksmithPath *p)'),
    path_end_open: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_path_end_open(CadaclysmBlacksmithPath *p)'),
    path_free: f('void cadaclysm_blacksmith_path_free(CadaclysmBlacksmithPath *p)'),
    face_count: f('uint32_t cadaclysm_blacksmith_face_count(const CadaclysmBlacksmithSolid *solid)'),
    select_face: f('uint32_t cadaclysm_blacksmith_select_face(const CadaclysmBlacksmithSolid *solid, uint32_t kind, const double *v, uint32_t index)'),
    face_frame: f('bool cadaclysm_blacksmith_face_frame(const CadaclysmBlacksmithSolid *solid, uint32_t face, _Out_ double *out)'),
    mass_properties: f('bool cadaclysm_blacksmith_mass_properties(const CadaclysmBlacksmithSolid *solid, double accuracy, _Out_ CadaclysmBlacksmithMassProperties *out)'),
    // The oriented box, the lengths, containment and the closest points. A point crosses in as
    // three doubles; the containment code comes back through a one-element `Uint32Array`.
    oriented_box: f('bool cadaclysm_blacksmith_oriented_box(const CadaclysmBlacksmithSolid *solid, double accuracy, _Out_ CadaclysmBlacksmithOrientedBox *out)'),
    // Arc length: a point at an arc length, and a divide's owned `Samples` list (freed with
    // `samples_free`, read with `samples_count`/`samples_at`). Over the wasm the divides return a
    // flat array instead and there is no handle (see `back`).
    edge_point_at_length: f('bool cadaclysm_blacksmith_edge_point_at_length(const CadaclysmBlacksmithSolid *solid, uint32_t edge, double s, double accuracy, _Out_ CadaclysmBlacksmithAt *out)'),
    edge_divide_by_count: f('CadaclysmBlacksmithSamples *cadaclysm_blacksmith_edge_divide_by_count(const CadaclysmBlacksmithSolid *solid, uint32_t edge, uint32_t n, double accuracy)'),
    edge_divide_by_length: f('CadaclysmBlacksmithSamples *cadaclysm_blacksmith_edge_divide_by_length(const CadaclysmBlacksmithSolid *solid, uint32_t edge, double step, double accuracy)'),
    profile_point_at_length: f('bool cadaclysm_blacksmith_profile_point_at_length(const CadaclysmBlacksmithProfile *profile, double s, double accuracy, _Out_ CadaclysmBlacksmithAt *out)'),
    profile_divide_by_count: f('CadaclysmBlacksmithSamples *cadaclysm_blacksmith_profile_divide_by_count(const CadaclysmBlacksmithProfile *profile, uint32_t n, double accuracy)'),
    profile_divide_by_length: f('CadaclysmBlacksmithSamples *cadaclysm_blacksmith_profile_divide_by_length(const CadaclysmBlacksmithProfile *profile, double step, double accuracy)'),
    samples_count: f('uint32_t cadaclysm_blacksmith_samples_count(const CadaclysmBlacksmithSamples *samples)'),
    samples_at: f('bool cadaclysm_blacksmith_samples_at(const CadaclysmBlacksmithSamples *samples, uint32_t i, _Out_ CadaclysmBlacksmithAt *out)'),
    samples_free: f('void cadaclysm_blacksmith_samples_free(CadaclysmBlacksmithSamples *samples)'),
    edge_length: f('bool cadaclysm_blacksmith_edge_length(const CadaclysmBlacksmithSolid *solid, uint32_t edge, double accuracy, _Out_ CadaclysmBlacksmithLength *out)'),
    profile_length: f('bool cadaclysm_blacksmith_profile_length(const CadaclysmBlacksmithProfile *profile, double accuracy, _Out_ CadaclysmBlacksmithLength *out)'),
    // NurbsCurve: curves in space. Every builder returns a new handle (freed with `nurbs_curve_free`)
    // or null with `last_error`; the divides and hits return the arc-length `Samples` list above.
    // Optional arrays (weights, knots, tangents, direction) are NULL when absent, never empty.
    nurbs_curve_new: f('CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_new(const double *xyz, size_t count, const double *weights, uint32_t degree, const double *knots, size_t knot_count)'),
    nurbs_curve_through: f('CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_through(const double *xyz, size_t count, uint32_t degree, bool closed, const double *start, const double *end)'),
    nurbs_curve_fit: f('CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_fit(const double *xyz, size_t count, uint32_t degree, double tolerance, _Out_ double *error_out)'),
    nurbs_curve_fair: f('CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_fair(const double *xyz, size_t count, uint32_t degree, double tolerance, bool no_inflection, double span_from, double span_to, _Out_ double *error_out)'),
    nurbs_curve_faired: f('CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_faired(const CadaclysmBlacksmithNurbsCurve *curve, uint32_t degree, double tolerance, bool no_inflection, double span_from, double span_to, _Out_ double *error_out)'),
    nurbs_curve_inflections: f('CadaclysmBlacksmithSamples *cadaclysm_blacksmith_nurbs_curve_inflections(const CadaclysmBlacksmithNurbsCurve *curve)'),
    nurbs_curve_knot_continuity: f('bool cadaclysm_blacksmith_nurbs_curve_knot_continuity(const CadaclysmBlacksmithNurbsCurve *curve, _Out_ CadaclysmBlacksmithKnotContinuity *out)'),
    nurbs_curve_from_edge: f('CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_from_edge(const CadaclysmBlacksmithSolid *solid, uint32_t edge)'),
    nurbs_curve_from_face_isocurve: f('CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_from_face_isocurve(const CadaclysmBlacksmithSolid *solid, uint32_t face, bool along_u, double at)'),
    nurbs_curve_blend: f('CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_blend(const CadaclysmBlacksmithNurbsCurve *a, bool a_end, const CadaclysmBlacksmithNurbsCurve *b, bool b_end, uint32_t continuity, double bulge)'),
    nurbs_curve_projected_to_plane: f('CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_projected_to_plane(const CadaclysmBlacksmithNurbsCurve *curve, const double *origin, const double *normal, const double *direction)'),
    nurbs_curve_projected_to_face: f('CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_projected_to_face(const CadaclysmBlacksmithNurbsCurve *curve, const CadaclysmBlacksmithSolid *solid, uint32_t face, const double *direction, double tolerance, _Out_ double *error_out)'),
    nurbs_curve_offset_on_sheet: f('CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_offset_on_sheet(const CadaclysmBlacksmithNurbsCurve *curve, const CadaclysmBlacksmithSolid *solid, double distance, double tolerance, _Out_ double *error_out)'),
    nurbs_curve_pulled_to_face: f('CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_pulled_to_face(const CadaclysmBlacksmithNurbsCurve *curve, const CadaclysmBlacksmithSolid *solid, uint32_t face, double tolerance, _Out_ double *error_out)'),
    nurbs_curve_reversed: f('CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_reversed(const CadaclysmBlacksmithNurbsCurve *curve)'),
    nurbs_curve_trimmed: f('CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_trimmed(const CadaclysmBlacksmithNurbsCurve *curve, double t0, double t1)'),
    nurbs_curve_extended: f('CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_extended(const CadaclysmBlacksmithNurbsCurve *curve, bool at_start, double length)'),
    nurbs_curve_elevated: f('CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_elevated(const CadaclysmBlacksmithNurbsCurve *curve, uint32_t by)'),
    nurbs_curve_joined: f('CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_joined(const CadaclysmBlacksmithNurbsCurve **curves, size_t count, double tolerance)'),
    // the tweens' handles are written into the caller's array of `count` pointers
    nurbs_curve_tween: f('bool cadaclysm_blacksmith_nurbs_curve_tween(const CadaclysmBlacksmithNurbsCurve *a, const CadaclysmBlacksmithNurbsCurve *b, uint32_t count, uint32_t method, uint32_t samples, bool align, double tolerance, _Out_ CadaclysmBlacksmithNurbsCurve **out)'),
    nurbs_curve_transformed: f('CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_transformed(const CadaclysmBlacksmithNurbsCurve *curve, const double *matrix)'),
    nurbs_curve_clone: f('CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_nurbs_curve_clone(const CadaclysmBlacksmithNurbsCurve *curve)'),
    nurbs_curve_free: f('void cadaclysm_blacksmith_nurbs_curve_free(CadaclysmBlacksmithNurbsCurve *curve)'),
    nurbs_curve_degree: f('uint32_t cadaclysm_blacksmith_nurbs_curve_degree(const CadaclysmBlacksmithNurbsCurve *curve)'),
    nurbs_curve_control_count: f('uint32_t cadaclysm_blacksmith_nurbs_curve_control_count(const CadaclysmBlacksmithNurbsCurve *curve)'),
    nurbs_curve_knot_count: f('uint32_t cadaclysm_blacksmith_nurbs_curve_knot_count(const CadaclysmBlacksmithNurbsCurve *curve)'),
    nurbs_curve_control_points: f('bool cadaclysm_blacksmith_nurbs_curve_control_points(const CadaclysmBlacksmithNurbsCurve *curve, _Out_ double *xyz)'),
    nurbs_curve_weights: f('bool cadaclysm_blacksmith_nurbs_curve_weights(const CadaclysmBlacksmithNurbsCurve *curve, _Out_ double *weights)'),
    nurbs_curve_knots: f('bool cadaclysm_blacksmith_nurbs_curve_knots(const CadaclysmBlacksmithNurbsCurve *curve, _Out_ double *knots)'),
    // `is_rational` and `is_closed` return the answer, not a success flag
    nurbs_curve_is_rational: f('bool cadaclysm_blacksmith_nurbs_curve_is_rational(const CadaclysmBlacksmithNurbsCurve *curve)'),
    nurbs_curve_is_closed: f('bool cadaclysm_blacksmith_nurbs_curve_is_closed(const CadaclysmBlacksmithNurbsCurve *curve)'),
    nurbs_curve_domain: f('bool cadaclysm_blacksmith_nurbs_curve_domain(const CadaclysmBlacksmithNurbsCurve *curve, _Out_ double *out)'),
    nurbs_curve_point: f('bool cadaclysm_blacksmith_nurbs_curve_point(const CadaclysmBlacksmithNurbsCurve *curve, double t, _Out_ double *out)'),
    nurbs_curve_derivatives: f('bool cadaclysm_blacksmith_nurbs_curve_derivatives(const CadaclysmBlacksmithNurbsCurve *curve, double t, uint32_t order, _Out_ double *out)'),
    nurbs_curve_curvature: f('bool cadaclysm_blacksmith_nurbs_curve_curvature(const CadaclysmBlacksmithNurbsCurve *curve, double t, _Out_ CadaclysmBlacksmithCurvature *out)'),
    nurbs_curve_length: f('bool cadaclysm_blacksmith_nurbs_curve_length(const CadaclysmBlacksmithNurbsCurve *curve, double accuracy, _Out_ CadaclysmBlacksmithLength *out)'),
    nurbs_curve_point_at_length: f('bool cadaclysm_blacksmith_nurbs_curve_point_at_length(const CadaclysmBlacksmithNurbsCurve *curve, double s, double accuracy, _Out_ CadaclysmBlacksmithAt *out)'),
    nurbs_curve_divide_by_count: f('CadaclysmBlacksmithSamples *cadaclysm_blacksmith_nurbs_curve_divide_by_count(const CadaclysmBlacksmithNurbsCurve *curve, uint32_t n, double accuracy)'),
    nurbs_curve_divide_by_length: f('CadaclysmBlacksmithSamples *cadaclysm_blacksmith_nurbs_curve_divide_by_length(const CadaclysmBlacksmithNurbsCurve *curve, double step, double accuracy)'),
    nurbs_curve_plane_hits: f('CadaclysmBlacksmithSamples *cadaclysm_blacksmith_nurbs_curve_plane_hits(const CadaclysmBlacksmithNurbsCurve *curve, const double *origin, const double *normal)'),
    nurbs_curve_face_hits: f('CadaclysmBlacksmithSamples *cadaclysm_blacksmith_nurbs_curve_face_hits(const CadaclysmBlacksmithNurbsCurve *curve, const CadaclysmBlacksmithSolid *solid, uint32_t face, double tolerance)'),
    curve_value_to_nurbs: f('CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_curve_value_to_nurbs(uint32_t kind, const double *value)'),
    // Sheets from curves, continuity, surface fillets, trim and join. The errors, the rails and
    // the reports come back through out-arguments (an array of one, or a record).
    loft_curves: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_loft_curves(const CadaclysmBlacksmithNurbsCurve **sections, size_t count, uint32_t degree, bool loose, bool closed)'),
    sweep_rail: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sweep_rail(const CadaclysmBlacksmithNurbsCurve *rail, const CadaclysmBlacksmithNurbsCurve **sections, size_t count, uint32_t frame, const double *up, double tolerance, _Out_ double *error_out)'),
    sweep_two_rails: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sweep_two_rails(const CadaclysmBlacksmithNurbsCurve *rail_a, const CadaclysmBlacksmithNurbsCurve *rail_b, const CadaclysmBlacksmithNurbsCurve **sections, size_t count, double tolerance, _Out_ double *error_out)'),
    edge_surface: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_edge_surface(const CadaclysmBlacksmithNurbsCurve **curves, size_t count, double tolerance, _Out_ double *error_out)'),
    network_surface: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_network_surface(const CadaclysmBlacksmithNurbsCurve **u_curves, size_t u_count, const CadaclysmBlacksmithNurbsCurve **v_curves, size_t v_count, double tolerance, _Out_ double *error_out)'),
    continuity: f('bool cadaclysm_blacksmith_continuity(const CadaclysmBlacksmithSolid *a, uint32_t face_a, uint32_t side_a, const CadaclysmBlacksmithSolid *b, uint32_t face_b, uint32_t side_b, uint32_t samples, _Out_ CadaclysmBlacksmithContinuity *out)'),
    edge_continuity: f('bool cadaclysm_blacksmith_edge_continuity(const CadaclysmBlacksmithSolid *solid, uint32_t edge, uint32_t samples, _Out_ CadaclysmBlacksmithContinuity *out)'),
    surface_faired: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_surface_faired(const CadaclysmBlacksmithSolid *solid, uint32_t face, double tolerance, uint32_t degree, uint32_t controls_u, uint32_t controls_v, const int32_t *keep, uint32_t no_inflection, _Out_ double *error_out)'),
    curvature_turns: f('bool cadaclysm_blacksmith_curvature_turns(const CadaclysmBlacksmithSolid *solid, uint32_t face, uint32_t samples, _Out_ CadaclysmBlacksmithCurvatureTurns *out)'),
    curvature_turn_points: f('CadaclysmBlacksmithSamples *cadaclysm_blacksmith_curvature_turn_points(const CadaclysmBlacksmithSolid *solid, uint32_t face, uint32_t samples, bool mean)'),
    highlight_kink: f('bool cadaclysm_blacksmith_highlight_kink(const CadaclysmBlacksmithSolid *solid, uint32_t edge, uint32_t samples, _Out_ CadaclysmBlacksmithHighlightKink *out)'),
    match_side: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_match_side(const CadaclysmBlacksmithSolid *a, uint32_t face_a, uint32_t side_a, const CadaclysmBlacksmithSolid *b, uint32_t face_b, uint32_t side_b, uint32_t level)'),
    blend_sides: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_blend_sides(const CadaclysmBlacksmithSolid *a, uint32_t face_a, uint32_t side_a, const CadaclysmBlacksmithSolid *b, uint32_t face_b, uint32_t side_b, uint32_t level, double bulge)'),
    n_sided_patch: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_n_sided_patch(const CadaclysmBlacksmithPatchBoundary *boundaries, size_t count, double bulge, double tolerance, _Out_ CadaclysmBlacksmithPatchReport *report_out)'),
    fillet_surfaces: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_fillet_surfaces(const CadaclysmBlacksmithSolid *a, uint32_t face_a, const CadaclysmBlacksmithSolid *b, uint32_t face_b, double radius_start, double radius_end, bool flip_a, bool flip_b, double tolerance, _Out_ CadaclysmBlacksmithNurbsCurve **rail_a, _Out_ CadaclysmBlacksmithNurbsCurve **rail_b, _Out_ double *error_out)'),
    fillet_varying: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_fillet_varying(const CadaclysmBlacksmithSolid *solid, const uint32_t *edges, size_t count, double radius_start, double radius_end, double tolerance)'),
    fillet_law: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_fillet_law(const CadaclysmBlacksmithSolid *solid, const uint32_t *edges, size_t count, const double *shares, const double *radii, size_t station_count, double tolerance)'),
    split_by_curve: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_split_by_curve(const CadaclysmBlacksmithSolid *sheet, const CadaclysmBlacksmithNurbsCurve *curve, const double *direction, double tolerance)'),
    trim_by_curve: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_trim_by_curve(const CadaclysmBlacksmithSolid *sheet, const CadaclysmBlacksmithNurbsCurve *curve, const double *direction, bool keep_inside, double tolerance)'),
    flange: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_flange(const CadaclysmBlacksmithSolid *sheet, const uint32_t *edges, size_t count, const CadaclysmBlacksmithNurbsCurve *section, double tolerance, bool join, _Out_ double *error_out)'),
    extrude_to: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_extrude_to(const CadaclysmBlacksmithSolid *sheet, const uint32_t *edges, size_t count, const double *direction, const CadaclysmBlacksmithSolid *target, double tolerance, bool join, _Out_ double *error_out)'),
    join_sheets: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_join_sheets(const CadaclysmBlacksmithSolid **sheets, size_t count, double tolerance, _Out_ CadaclysmBlacksmithJoinReport *report)'),
    split_along_curve: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_split_along_curve(const CadaclysmBlacksmithSolid *sheet, const CadaclysmBlacksmithNurbsCurve *curve, double tolerance)'),
    panel_gap: f('bool cadaclysm_blacksmith_panel_gap(const CadaclysmBlacksmithSolid *sheet, const CadaclysmBlacksmithNurbsCurve *curve, double gap, double flange, double tolerance, _Out_ CadaclysmBlacksmithSolid **out)'),
    recess: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_recess(const CadaclysmBlacksmithSolid *sheet, const CadaclysmBlacksmithNurbsCurve *outline, double depth, double draft, double fillet, bool pane, double tolerance, _Out_ uint32_t *faces_out)'),
    mirror_join: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_mirror_join(const CadaclysmBlacksmithSolid *half, const double *plane, double snap, double tolerance, _Out_ double *report_out)'),
    pattern_rectangular: f('uint32_t cadaclysm_blacksmith_pattern_rectangular(const double *direction1, uint32_t count1, double spacing1, const double *direction2, uint32_t count2, double spacing2, bool symmetric, const uint32_t *skip, uint32_t skip_count, _Out_ double *out)'),
    pattern_circular: f('uint32_t cadaclysm_blacksmith_pattern_circular(const double *axis, uint32_t count, double angle, bool symmetric, const uint32_t *skip, uint32_t skip_count, _Out_ double *out)'),
    pattern_along: f('uint32_t cadaclysm_blacksmith_pattern_along(const CadaclysmBlacksmithNurbsCurve *curve, uint32_t count, double spacing, uint32_t orient, const uint32_t *skip, uint32_t skip_count, _Out_ double *out)'),
    pattern: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_pattern(const CadaclysmBlacksmithSolid *solid, const double *transforms, uint32_t count, double tolerance, _Out_ double *report_out)'),
    pattern_feature: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_pattern_feature(const CadaclysmBlacksmithSolid *solid, const CadaclysmBlacksmithSolid *tool, uint32_t op, const double *transforms, uint32_t count, double tolerance, _Out_ double *report_out)'),
    hole: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_hole(const CadaclysmBlacksmithSolid *solid, const double *points, uint32_t count, double diameter, const double *direction, uint32_t extent, double depth, double tip_angle, uint32_t face, uint32_t head, double head_diameter, double head_depth, double head_angle, double tolerance, _Out_ double *report_out, _Out_ double *bottoms_out)'),
    hole_tool: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_hole_tool(const CadaclysmBlacksmithSolid *solid, const double *points, uint32_t count, double diameter, const double *direction, uint32_t extent, double depth, double tip_angle, uint32_t face, uint32_t head, double head_diameter, double head_depth, double head_angle, double tolerance)'),
    rib: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_rib(const CadaclysmBlacksmithSolid *solid, const CadaclysmBlacksmithNurbsCurve *curve, const double *plane, double thickness, uint32_t side, const double *toward, double tolerance)'),
    rib_tool: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_rib_tool(const CadaclysmBlacksmithSolid *solid, const CadaclysmBlacksmithNurbsCurve *curve, const double *plane, double thickness, uint32_t side, const double *toward, double tolerance)'),
    web: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_web(const CadaclysmBlacksmithSolid *solid, const CadaclysmBlacksmithNurbsCurve **curves, uint32_t count, const double *plane, double thickness, uint32_t side, double depth, bool both_ways, double tolerance)'),
    web_tool: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_web_tool(const CadaclysmBlacksmithSolid *solid, const CadaclysmBlacksmithNurbsCurve **curves, uint32_t count, const double *plane, double thickness, uint32_t side, double depth, bool both_ways, double tolerance)'),
    contains: f('bool cadaclysm_blacksmith_contains(const CadaclysmBlacksmithSolid *solid, const double *point, double tolerance, _Out_ uint32_t *out)'),
    classifier_new: f('CadaclysmBlacksmithClassifier *cadaclysm_blacksmith_classifier_new(const CadaclysmBlacksmithSolid *solid, double tolerance)'),
    classifier_contains: f('bool cadaclysm_blacksmith_classifier_contains(const CadaclysmBlacksmithClassifier *classifier, const double *point, _Out_ uint32_t *out)'),
    classifier_free: f('void cadaclysm_blacksmith_classifier_free(CadaclysmBlacksmithClassifier *classifier)'),
    closest: f('bool cadaclysm_blacksmith_closest(const CadaclysmBlacksmithSolid *a, const CadaclysmBlacksmithSolid *b, double tolerance, CadaclysmBlacksmithProgress *progress, void *user, _Out_ CadaclysmBlacksmithClosest *out)'),
    // Closest point from a point: 1 found, 0 beyond `max_distance` (`out` untouched), -1 refused.
    closest_point: f('int32_t cadaclysm_blacksmith_closest_point(const CadaclysmBlacksmithSolid *solid, const double *p, double max_distance, double tolerance, _Out_ CadaclysmBlacksmithPointFoot *out)'),
    projector_new: f('CadaclysmBlacksmithProjector *cadaclysm_blacksmith_projector_new(const CadaclysmBlacksmithSolid *solid, double tolerance)'),
    projector_closest_point: f('int32_t cadaclysm_blacksmith_projector_closest_point(const CadaclysmBlacksmithProjector *projector, const double *p, double max_distance, _Out_ CadaclysmBlacksmithPointFoot *out)'),
    projector_free: f('void cadaclysm_blacksmith_projector_free(CadaclysmBlacksmithProjector *projector)'),
    face_closest_point: f('int32_t cadaclysm_blacksmith_face_closest_point(const CadaclysmBlacksmithSolid *solid, uint32_t face, const double *p, _Out_ CadaclysmBlacksmithPointFoot *out)'),
    edge_closest_point: f('int32_t cadaclysm_blacksmith_edge_closest_point(const CadaclysmBlacksmithSolid *solid, uint32_t edge, const double *p, _Out_ double *out)'),
    nurbs_curve_closest_point: f('int32_t cadaclysm_blacksmith_nurbs_curve_closest_point(const CadaclysmBlacksmithNurbsCurve *curve, const double *p, _Out_ double *out)'),
    // Closest points from a curve: 1 found, 0 beyond `max_distance` (`out` untouched), -1 refused.
    nurbs_curve_closest_point_within: f('int32_t cadaclysm_blacksmith_nurbs_curve_closest_point_within(const CadaclysmBlacksmithNurbsCurve *curve, const double *p, double max_distance, _Out_ double *out)'),
    nurbs_curve_closest_points: f('int32_t cadaclysm_blacksmith_nurbs_curve_closest_points(const CadaclysmBlacksmithNurbsCurve *a, const CadaclysmBlacksmithNurbsCurve *b, double max_distance, _Out_ CadaclysmBlacksmithCurvePair *out)'),
    curve_closest_points: f('int32_t cadaclysm_blacksmith_curve_closest_points(const CadaclysmBlacksmithSolid *solid, const CadaclysmBlacksmithNurbsCurve *curve, double max_distance, double tolerance, _Out_ CadaclysmBlacksmithCurveBodyFoot *out)'),
    projector_curve_closest_points: f('int32_t cadaclysm_blacksmith_projector_curve_closest_points(const CadaclysmBlacksmithProjector *projector, const CadaclysmBlacksmithNurbsCurve *curve, double max_distance, _Out_ CadaclysmBlacksmithCurveBodyFoot *out)'),
    nurbs_curve_closest_object: f('int32_t cadaclysm_blacksmith_nurbs_curve_closest_object(const CadaclysmBlacksmithNurbsCurve *curve, const uint8_t *kinds, uint32_t count, const CadaclysmBlacksmithSolid **solids, uint32_t n_solids, const CadaclysmBlacksmithNurbsCurve **curves, uint32_t n_curves, const double *points, uint32_t n_points, const CadaclysmBlacksmithProjector **projectors, uint32_t n_projectors, const CadaclysmBlacksmithTriangleMesh **meshes, uint32_t n_meshes, double max_distance, double tolerance, _Out_ CadaclysmBlacksmithNearestObject *out)'),
    // A triangle mesh and the nearest points against it: 1 found, 0 beyond `max_distance` (`out`
    // untouched), -1 refused.
    triangle_mesh_new: f('CadaclysmBlacksmithTriangleMesh *cadaclysm_blacksmith_triangle_mesh_new(const double *positions, uint32_t vertex_count, const uint32_t *indices, uint32_t triangle_count)'),
    solid_triangle_mesh: f('CadaclysmBlacksmithTriangleMesh *cadaclysm_blacksmith_solid_triangle_mesh(const CadaclysmBlacksmithSolid *solid, double tolerance)'),
    triangle_mesh_free: f('void cadaclysm_blacksmith_triangle_mesh_free(CadaclysmBlacksmithTriangleMesh *mesh)'),
    triangle_mesh_vertex_count: f('uint32_t cadaclysm_blacksmith_triangle_mesh_vertex_count(const CadaclysmBlacksmithTriangleMesh *mesh)'),
    triangle_mesh_triangle_count: f('uint32_t cadaclysm_blacksmith_triangle_mesh_triangle_count(const CadaclysmBlacksmithTriangleMesh *mesh)'),
    triangle_mesh_bounds: f('bool cadaclysm_blacksmith_triangle_mesh_bounds(const CadaclysmBlacksmithTriangleMesh *mesh, _Out_ double *out)'),
    triangle_mesh_closest_point: f('int32_t cadaclysm_blacksmith_triangle_mesh_closest_point(const CadaclysmBlacksmithTriangleMesh *mesh, const double *p, double max_distance, _Out_ CadaclysmBlacksmithMeshPoint *out)'),
    triangle_mesh_curve_closest_points: f('int32_t cadaclysm_blacksmith_triangle_mesh_curve_closest_points(const CadaclysmBlacksmithTriangleMesh *mesh, const CadaclysmBlacksmithNurbsCurve *curve, double max_distance, _Out_ CadaclysmBlacksmithCurveMeshFoot *out)'),
    // Mechanical drawings: hidden-line removal, the projected outline, the page and DXF profiles.
    hlr_options_init: f('void cadaclysm_blacksmith_hlr_options_init(_Out_ CadaclysmBlacksmithHlrOptions *options)'),
    hlr: f('CadaclysmBlacksmithHlr *cadaclysm_blacksmith_hlr(const CadaclysmBlacksmithSolid **solids, size_t count, const CadaclysmBlacksmithHlrOptions *options)'),
    hlr_mesh: f('CadaclysmBlacksmithHlr *cadaclysm_blacksmith_hlr_mesh(const CadaclysmBlacksmithTriangleMesh **meshes, size_t count, const CadaclysmBlacksmithHlrOptions *options)'),
    hlr_line_count: f('uint32_t cadaclysm_blacksmith_hlr_line_count(const CadaclysmBlacksmithHlr *hlr)'),
    hlr_line: f('bool cadaclysm_blacksmith_hlr_line(const CadaclysmBlacksmithHlr *hlr, uint32_t i, _Out_ CadaclysmBlacksmithHlrLine *out)'),
    hlr_line_beziers2d: f('bool cadaclysm_blacksmith_hlr_line_beziers2d(const CadaclysmBlacksmithHlr *hlr, uint32_t i, _Out_ double *out)'),
    hlr_line_beziers3d: f('bool cadaclysm_blacksmith_hlr_line_beziers3d(const CadaclysmBlacksmithHlr *hlr, uint32_t i, _Out_ double *out)'),
    hlr_report: f('bool cadaclysm_blacksmith_hlr_report(const CadaclysmBlacksmithHlr *hlr, _Out_ CadaclysmBlacksmithHlrReport *out)'),
    hlr_free: f('void cadaclysm_blacksmith_hlr_free(CadaclysmBlacksmithHlr *hlr)'),
    projected_outline: f('CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_projected_outline(const CadaclysmBlacksmithSolid **solids, size_t count, const CadaclysmBlacksmithHlrOptions *options)'),
    page_new: f('CadaclysmBlacksmithPage *cadaclysm_blacksmith_page_new(uint32_t units)'),
    page_add_view: f('bool cadaclysm_blacksmith_page_add_view(CadaclysmBlacksmithPage *page, const CadaclysmBlacksmithHlr *hlr, double x, double y, double scale)'),
    page_add_profile: f('bool cadaclysm_blacksmith_page_add_profile(CadaclysmBlacksmithPage *page, const CadaclysmBlacksmithProfile *profile, const char *layer, double x, double y)'),
    page_add_hatch: f('bool cadaclysm_blacksmith_page_add_hatch(CadaclysmBlacksmithPage *page, const CadaclysmBlacksmithProfile *profile, const char *layer, const char *pattern, double angle, double scale, double x, double y)'),
    page_add_text: f('bool cadaclysm_blacksmith_page_add_text(CadaclysmBlacksmithPage *page, const char *text, const char *layer, double x, double y, double height, double angle, const char *halign, const char *valign)'),
    page_entity_count: f('uint32_t cadaclysm_blacksmith_page_entity_count(const CadaclysmBlacksmithPage *page)'),
    page_svg_text: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_page_svg_text(const CadaclysmBlacksmithPage *page)'),
    page_dxf_text: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_page_dxf_text(const CadaclysmBlacksmithPage *page)'),
    page_free: f('void cadaclysm_blacksmith_page_free(CadaclysmBlacksmithPage *page)'),
    dxf_profiles: f('CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_dxf_profiles(const char *text, double tolerance)'),
    face_ref: f('bool cadaclysm_blacksmith_face_ref(const CadaclysmBlacksmithSolid *solid, uint32_t face, _Out_ double *out)'),
    find_face: f('int32_t cadaclysm_blacksmith_find_face(const CadaclysmBlacksmithSolid *solid, const double *face_ref, int32_t hint, double tolerance)'),
    // identity and attributes (plan C2): ids, origins, attributes, history, edge and vertex
    // references. The attribute texts are **borrowed** from the solid (`const char *`, as
    // `solid_name`), copied by koffi and never freed; a history handle is read whole into a
    // `History` and freed at once (`Solid._history`).
    solid_tracked: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_solid_tracked(const CadaclysmBlacksmithSolid *solid)'),
    solid_is_tracked: f('bool cadaclysm_blacksmith_solid_is_tracked(const CadaclysmBlacksmithSolid *solid)'),
    face_id: f('uint64_t cadaclysm_blacksmith_face_id(const CadaclysmBlacksmithSolid *solid, uint32_t face)'),
    face_with_id: f('uint32_t cadaclysm_blacksmith_face_with_id(const CadaclysmBlacksmithSolid *solid, uint64_t id)'),
    face_origin_count: f('uint32_t cadaclysm_blacksmith_face_origin_count(const CadaclysmBlacksmithSolid *solid, uint32_t face)'),
    face_origin_at: f('bool cadaclysm_blacksmith_face_origin_at(const CadaclysmBlacksmithSolid *solid, uint32_t face, uint32_t i, _Out_ uint32_t *operand, _Out_ uint64_t *id)'),
    edge_id: f('uint64_t cadaclysm_blacksmith_edge_id(const CadaclysmBlacksmithSolid *solid, uint32_t edge)'),
    edge_with_id: f('uint32_t cadaclysm_blacksmith_edge_with_id(const CadaclysmBlacksmithSolid *solid, uint64_t id)'),
    edge_origin_count: f('uint32_t cadaclysm_blacksmith_edge_origin_count(const CadaclysmBlacksmithSolid *solid, uint32_t edge)'),
    edge_origin_at: f('bool cadaclysm_blacksmith_edge_origin_at(const CadaclysmBlacksmithSolid *solid, uint32_t edge, uint32_t i, _Out_ uint32_t *operand, _Out_ uint64_t *id)'),
    origins_through: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_origins_through(const CadaclysmBlacksmithSolid *out, const CadaclysmBlacksmithSolid *via)'),
    with_attribute: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_with_attribute(const CadaclysmBlacksmithSolid *solid, const char *key, const char *value)'),
    without_attribute: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_without_attribute(const CadaclysmBlacksmithSolid *solid, const char *key)'),
    attribute: f('const char *cadaclysm_blacksmith_attribute(const CadaclysmBlacksmithSolid *solid, const char *key)'),
    attribute_count: f('uint32_t cadaclysm_blacksmith_attribute_count(const CadaclysmBlacksmithSolid *solid)'),
    attribute_key_at: f('const char *cadaclysm_blacksmith_attribute_key_at(const CadaclysmBlacksmithSolid *solid, uint32_t i)'),
    attribute_value_at: f('const char *cadaclysm_blacksmith_attribute_value_at(const CadaclysmBlacksmithSolid *solid, uint32_t i)'),
    with_face_attribute: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_with_face_attribute(const CadaclysmBlacksmithSolid *solid, uint32_t face, const char *key, const char *value)'),
    without_face_attribute: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_without_face_attribute(const CadaclysmBlacksmithSolid *solid, uint32_t face, const char *key)'),
    face_attribute: f('const char *cadaclysm_blacksmith_face_attribute(const CadaclysmBlacksmithSolid *solid, uint32_t face, const char *key)'),
    face_attribute_count: f('uint32_t cadaclysm_blacksmith_face_attribute_count(const CadaclysmBlacksmithSolid *solid, uint32_t face)'),
    face_attribute_key_at: f('const char *cadaclysm_blacksmith_face_attribute_key_at(const CadaclysmBlacksmithSolid *solid, uint32_t face, uint32_t i)'),
    face_attribute_value_at: f('const char *cadaclysm_blacksmith_face_attribute_value_at(const CadaclysmBlacksmithSolid *solid, uint32_t face, uint32_t i)'),
    history: f('CadaclysmBlacksmithHistory *cadaclysm_blacksmith_history(const CadaclysmBlacksmithSolid *out, const CadaclysmBlacksmithSolid **inputs, size_t count)'),
    edge_history: f('CadaclysmBlacksmithHistory *cadaclysm_blacksmith_edge_history(const CadaclysmBlacksmithSolid *out, const CadaclysmBlacksmithSolid **inputs, size_t count)'),
    history_free: f('void cadaclysm_blacksmith_history_free(CadaclysmBlacksmithHistory *history)'),
    history_kept_count: f('uint32_t cadaclysm_blacksmith_history_kept_count(const CadaclysmBlacksmithHistory *history)'),
    history_kept_at: f('bool cadaclysm_blacksmith_history_kept_at(const CadaclysmBlacksmithHistory *history, uint32_t i, _Out_ uint32_t *operand, _Out_ uint64_t *id, _Out_ uint64_t *out_id)'),
    history_modified_count: f('uint32_t cadaclysm_blacksmith_history_modified_count(const CadaclysmBlacksmithHistory *history)'),
    history_modified_at: f('bool cadaclysm_blacksmith_history_modified_at(const CadaclysmBlacksmithHistory *history, uint32_t i, _Out_ uint32_t *operand, _Out_ uint64_t *id)'),
    history_modified_output_count: f('uint32_t cadaclysm_blacksmith_history_modified_output_count(const CadaclysmBlacksmithHistory *history, uint32_t i)'),
    history_modified_output_at: f('uint64_t cadaclysm_blacksmith_history_modified_output_at(const CadaclysmBlacksmithHistory *history, uint32_t i, uint32_t j)'),
    history_generated_count: f('uint32_t cadaclysm_blacksmith_history_generated_count(const CadaclysmBlacksmithHistory *history)'),
    history_generated_at: f('uint64_t cadaclysm_blacksmith_history_generated_at(const CadaclysmBlacksmithHistory *history, uint32_t i)'),
    history_deleted_count: f('uint32_t cadaclysm_blacksmith_history_deleted_count(const CadaclysmBlacksmithHistory *history)'),
    history_deleted_at: f('bool cadaclysm_blacksmith_history_deleted_at(const CadaclysmBlacksmithHistory *history, uint32_t i, _Out_ uint32_t *operand, _Out_ uint64_t *id)'),
    edge_ref: f('bool cadaclysm_blacksmith_edge_ref(const CadaclysmBlacksmithSolid *solid, uint32_t edge, _Out_ double *out)'),
    find_edge: f('int32_t cadaclysm_blacksmith_find_edge(const CadaclysmBlacksmithSolid *solid, const double *edge_ref, double tolerance)'),
    vertex_count: f('uint32_t cadaclysm_blacksmith_vertex_count(const CadaclysmBlacksmithSolid *solid)'),
    vertex_ref: f('bool cadaclysm_blacksmith_vertex_ref(const CadaclysmBlacksmithSolid *solid, uint32_t vertex, _Out_ double *out)'),
    find_vertex: f('int32_t cadaclysm_blacksmith_find_vertex(const CadaclysmBlacksmithSolid *solid, const double *vertex_ref, double tolerance)'),
    face_kind: f('const char *cadaclysm_blacksmith_face_kind(const CadaclysmBlacksmithSolid *solid, uint32_t face)'),
    coloured: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_coloured(const CadaclysmBlacksmithSolid *solid, uint32_t face, double r, double g, double b)'),
    colour: f('bool cadaclysm_blacksmith_colour(const CadaclysmBlacksmithSolid *solid, uint32_t face, _Out_ double *out)'),
    edges_coloured: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_edges_coloured(const CadaclysmBlacksmithSolid *solid, const uint32_t *edges, size_t count, double r, double g, double b)'),
    edge_colour: f('bool cadaclysm_blacksmith_edge_colour(const CadaclysmBlacksmithSolid *solid, uint32_t edge, _Out_ double *out)'),
    edge_count: f('uint32_t cadaclysm_blacksmith_edge_count(const CadaclysmBlacksmithSolid *solid)'),
    edge: f('bool cadaclysm_blacksmith_edge(const CadaclysmBlacksmithSolid *solid, uint32_t i, _Out_ CadaclysmBlacksmithEdge *out)'),
    edge_curve: f('bool cadaclysm_blacksmith_edge_curve(const CadaclysmBlacksmithSolid *solid, uint32_t i, _Out_ CadaclysmBlacksmithCurve *out)'),
    intersect: f('CadaclysmBlacksmithIntersection *cadaclysm_blacksmith_intersect(const CadaclysmBlacksmithSolid *a, const CadaclysmBlacksmithSolid *b, double tolerance, CadaclysmBlacksmithProgress *progress, void *user)'),
    self_intersect: f('CadaclysmBlacksmithIntersection *cadaclysm_blacksmith_self_intersect(const CadaclysmBlacksmithSolid *solid, double tolerance, CadaclysmBlacksmithProgress *progress, void *user)'),
    intersection_free: f('void cadaclysm_blacksmith_intersection_free(CadaclysmBlacksmithIntersection *intersection)'),
    intersection_chain_count: f('uint32_t cadaclysm_blacksmith_intersection_chain_count(const CadaclysmBlacksmithIntersection *intersection)'),
    intersection_chain: f('bool cadaclysm_blacksmith_intersection_chain(const CadaclysmBlacksmithIntersection *intersection, uint32_t i, _Out_ CadaclysmBlacksmithChain *out)'),
    intersection_curve: f('bool cadaclysm_blacksmith_intersection_curve(const CadaclysmBlacksmithIntersection *intersection, uint32_t i, _Out_ CadaclysmBlacksmithCurve *out)'),
    intersection_overlap_count: f('uint32_t cadaclysm_blacksmith_intersection_overlap_count(const CadaclysmBlacksmithIntersection *intersection)'),
    intersection_overlap: f('bool cadaclysm_blacksmith_intersection_overlap(const CadaclysmBlacksmithIntersection *intersection, uint32_t i, _Out_ CadaclysmBlacksmithOverlap *out)'),
    check: f('CadaclysmBlacksmithCheck *cadaclysm_blacksmith_check(const CadaclysmBlacksmithSolid *a, const CadaclysmBlacksmithSolid *b, const char *operation, double tolerance, CadaclysmBlacksmithProgress *progress, void *user)'),
    check_free: f('void cadaclysm_blacksmith_check_free(CadaclysmBlacksmithCheck *check)'),
    check_count: f('uint32_t cadaclysm_blacksmith_check_count(const CadaclysmBlacksmithCheck *check)'),
    check_finding: f('bool cadaclysm_blacksmith_check_finding(const CadaclysmBlacksmithCheck *check, uint32_t i, _Out_ CadaclysmBlacksmithFinding *out)'),
    // The collider. `a`/`b`/`box_` cross *in* as six contiguous doubles (lo then hi) -- as a
    // frame crosses in as twelve -- bit-compatible with `CadaclysmBlacksmithBox`; only an
    // out-param is the real struct.
    solid_bounds_box: f('bool cadaclysm_blacksmith_solid_bounds_box(const CadaclysmBlacksmithSolid *solid, double tolerance, _Out_ CadaclysmBlacksmithBox *out)'),
    box_moved: f('bool cadaclysm_blacksmith_box_moved(const double *box_, const double *frame, _Out_ CadaclysmBlacksmithBox *out)'),
    box_overlaps: f('bool cadaclysm_blacksmith_box_overlaps(const double *a, const double *b)'),
    boxes_apart: f('bool cadaclysm_blacksmith_boxes_apart(const double *a, const double *frame_a, const double *b, const double *frame_b, _Out_ bool *apart)'),
    collider_new: f('CadaclysmBlacksmithCollider *cadaclysm_blacksmith_collider_new(const CadaclysmBlacksmithSolid **solids, uint32_t count, double tolerance, const uint32_t *groups, const uint32_t *allowed, uint32_t allowed_count)'),
    collider_free: f('void cadaclysm_blacksmith_collider_free(CadaclysmBlacksmithCollider *collider)'),
    collider_group_count: f('uint32_t cadaclysm_blacksmith_collider_group_count(const CadaclysmBlacksmithCollider *collider)'),
    collider_stats: f('bool cadaclysm_blacksmith_collider_stats(const CadaclysmBlacksmithCollider *collider, _Out_ CadaclysmBlacksmithColliderStats *out)'),
    collider_check: f('CadaclysmBlacksmithCollisions *cadaclysm_blacksmith_collider_check(CadaclysmBlacksmithCollider *collider, const double *frames, uint32_t frame_count, uint32_t share_k, uint32_t share_n)'),
    collisions_free: f('void cadaclysm_blacksmith_collisions_free(CadaclysmBlacksmithCollisions *collisions)'),
    collisions_count: f('uint32_t cadaclysm_blacksmith_collisions_count(const CadaclysmBlacksmithCollisions *collisions)'),
    collisions_hit: f('bool cadaclysm_blacksmith_collisions_hit(const CadaclysmBlacksmithCollisions *collisions, uint32_t i, _Out_ CadaclysmBlacksmithCollisionHit *out)'),
    collisions_solid: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_collisions_solid(const CadaclysmBlacksmithCollisions *collisions, uint32_t i)'),
    // Clash: `collider_clash` takes its frames as `collider_check` does; `clash` two handle
    // arrays (`b` null with count 0 for one set) and `allowed` as a pair count. The rows are
    // read with `clashes_at` and rebuilt with `clashes_solid`/`clashes_intersect` (an
    // intersection handle, read as `intersect`'s).
    collider_clash: f('CadaclysmBlacksmithClashes *cadaclysm_blacksmith_collider_clash(CadaclysmBlacksmithCollider *collider, const double *frames, uint32_t frame_count, double clearance, uint32_t share_k, uint32_t share_n)'),
    clash: f('CadaclysmBlacksmithClashes *cadaclysm_blacksmith_clash(const CadaclysmBlacksmithSolid **a, uint32_t a_count, const CadaclysmBlacksmithSolid **b, uint32_t b_count, double tolerance, double clearance, const uint32_t *allowed, uint32_t allowed_count)'),
    clashes_free: f('void cadaclysm_blacksmith_clashes_free(CadaclysmBlacksmithClashes *clashes)'),
    clashes_count: f('uint32_t cadaclysm_blacksmith_clashes_count(const CadaclysmBlacksmithClashes *clashes)'),
    clashes_at: f('bool cadaclysm_blacksmith_clashes_at(const CadaclysmBlacksmithClashes *clashes, uint32_t i, _Out_ CadaclysmBlacksmithClash *out)'),
    clashes_solid: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_clashes_solid(const CadaclysmBlacksmithClashes *clashes, uint32_t i)'),
    clashes_intersect: f('CadaclysmBlacksmithIntersection *cadaclysm_blacksmith_clashes_intersect(const CadaclysmBlacksmithClashes *clashes, uint32_t i)'),
    // Swept clash: `collider_swept_clash` takes `pose_count` poses of `frame_count` frames each,
    // pose by pose; `swept_clash` each set's poses (`b` and `poses_b` null with count 0 for one
    // set) and `allowed` as a pair count. A row is read with `swept_clashes_at` and
    // `swept_clashes_interval`; `swept_clashes_firsts` is an owned clashes list, one row per
    // swept row, read as `collider_clash`'s.
    collider_swept_clash: f('CadaclysmBlacksmithSweptClashes *cadaclysm_blacksmith_collider_swept_clash(CadaclysmBlacksmithCollider *collider, const double *poses, uint32_t pose_count, uint32_t frame_count, double clearance, double resolution, uint32_t max_steps, uint32_t share_k, uint32_t share_n)'),
    swept_clash: f('CadaclysmBlacksmithSweptClashes *cadaclysm_blacksmith_swept_clash(const CadaclysmBlacksmithSolid **a, uint32_t a_count, const double *poses_a, const CadaclysmBlacksmithSolid **b, uint32_t b_count, const double *poses_b, uint32_t pose_count, double tolerance, double clearance, double resolution, uint32_t max_steps, const uint32_t *allowed, uint32_t allowed_count)'),
    swept_clashes_free: f('void cadaclysm_blacksmith_swept_clashes_free(CadaclysmBlacksmithSweptClashes *swept)'),
    swept_clashes_count: f('uint32_t cadaclysm_blacksmith_swept_clashes_count(const CadaclysmBlacksmithSweptClashes *swept)'),
    swept_clashes_at: f('bool cadaclysm_blacksmith_swept_clashes_at(const CadaclysmBlacksmithSweptClashes *swept, uint32_t i, _Out_ CadaclysmBlacksmithSweptClash *out)'),
    swept_clashes_interval: f('bool cadaclysm_blacksmith_swept_clashes_interval(const CadaclysmBlacksmithSweptClashes *swept, uint32_t i, uint32_t k, _Out_ double *out)'),
    swept_clashes_firsts: f('CadaclysmBlacksmithClashes *cadaclysm_blacksmith_swept_clashes_firsts(const CadaclysmBlacksmithSweptClashes *swept)'),
    // Wall thickness: a gauge over solids, its readings as list handles read with `*_at` into
    // out-records and freed at once, and `mesh_thickness` over plain meshes laid end to end.
    thickness_gauge_new: f('CadaclysmBlacksmithThicknessGauge *cadaclysm_blacksmith_thickness_gauge_new(const CadaclysmBlacksmithSolid **solids, uint32_t count, double tolerance)'),
    thickness_gauge_free: f('void cadaclysm_blacksmith_thickness_gauge_free(CadaclysmBlacksmithThicknessGauge *gauge)'),
    thickness_gauge_body_count: f('uint32_t cadaclysm_blacksmith_thickness_gauge_body_count(const CadaclysmBlacksmithThicknessGauge *gauge)'),
    thickness_gauge_tolerance: f('double cadaclysm_blacksmith_thickness_gauge_tolerance(const CadaclysmBlacksmithThicknessGauge *gauge)'),
    thickness_gauge_mesh: f('bool cadaclysm_blacksmith_thickness_gauge_mesh(const CadaclysmBlacksmithThicknessGauge *gauge, uint32_t body, _Out_ CadaclysmBlacksmithThicknessMesh *out)'),
    thickness_gauge_measure: f('CadaclysmBlacksmithThicknesses *cadaclysm_blacksmith_thickness_gauge_measure(const CadaclysmBlacksmithThicknessGauge *gauge, double maximum, double sharp_angle)'),
    thickness_gauge_at: f('CadaclysmBlacksmithThicknesses *cadaclysm_blacksmith_thickness_gauge_at(const CadaclysmBlacksmithThicknessGauge *gauge, uint32_t body, uint32_t face, const double *point, double maximum, double sharp_angle)'),
    thickness_gauge_face: f('bool cadaclysm_blacksmith_thickness_gauge_face(const CadaclysmBlacksmithThicknessGauge *gauge, uint32_t body, uint32_t face, const double *at, double maximum, _Out_ CadaclysmBlacksmithFaceThickness *out)'),
    thicknesses_free: f('void cadaclysm_blacksmith_thicknesses_free(CadaclysmBlacksmithThicknesses *list)'),
    thicknesses_count: f('uint32_t cadaclysm_blacksmith_thicknesses_count(const CadaclysmBlacksmithThicknesses *list)'),
    thicknesses_at: f('bool cadaclysm_blacksmith_thicknesses_at(const CadaclysmBlacksmithThicknesses *list, uint32_t i, _Out_ CadaclysmBlacksmithThickness *out)'),
    mesh_thickness: f('CadaclysmBlacksmithMeshThicknesses *cadaclysm_blacksmith_mesh_thickness(const double *positions, const uint32_t *vertex_counts, const uint32_t *indices, const uint32_t *triangle_counts, uint32_t mesh_count, double maximum, double sharp_angle)'),
    mesh_thicknesses_free: f('void cadaclysm_blacksmith_mesh_thicknesses_free(CadaclysmBlacksmithMeshThicknesses *list)'),
    mesh_thicknesses_count: f('uint32_t cadaclysm_blacksmith_mesh_thicknesses_count(const CadaclysmBlacksmithMeshThicknesses *list)'),
    mesh_thicknesses_at: f('bool cadaclysm_blacksmith_mesh_thicknesses_at(const CadaclysmBlacksmithMeshThicknesses *list, uint32_t i, _Out_ CadaclysmBlacksmithMeshThickness *out)'),
    // The R-tree: a mutable handle (insert and remove change it in place). A box crosses as 6
    // doubles `[minx, miny, minz, maxx, maxy, maxz]`, a point as 3. The queries return owned
    // `RTreeHits` / `RTreePairs` lists, read with `_count`/`_at` and freed with `_free`.
    rtree_new: f('CadaclysmBlacksmithRTree *cadaclysm_blacksmith_rtree_new(void)'),
    rtree_from_boxes: f('CadaclysmBlacksmithRTree *cadaclysm_blacksmith_rtree_from_boxes(const uint32_t *ids, const double *boxes, uint32_t n)'),
    rtree_from_points: f('CadaclysmBlacksmithRTree *cadaclysm_blacksmith_rtree_from_points(const double *xyz, uint32_t n)'),
    rtree_from_triangles: f('CadaclysmBlacksmithRTree *cadaclysm_blacksmith_rtree_from_triangles(const double *xyz, uint32_t n_points, const uint32_t *indices, uint32_t n_triangles)'),
    solid_face_tree: f('CadaclysmBlacksmithRTree *cadaclysm_blacksmith_solid_face_tree(const CadaclysmBlacksmithSolid *solid)'),
    rtree_insert: f('bool cadaclysm_blacksmith_rtree_insert(CadaclysmBlacksmithRTree *tree, uint32_t id, const double *box_)'),
    rtree_insert_point: f('bool cadaclysm_blacksmith_rtree_insert_point(CadaclysmBlacksmithRTree *tree, uint32_t id, const double *p)'),
    rtree_remove: f('bool cadaclysm_blacksmith_rtree_remove(CadaclysmBlacksmithRTree *tree, uint32_t id, const double *box_)'),
    rtree_count: f('uint32_t cadaclysm_blacksmith_rtree_count(const CadaclysmBlacksmithRTree *tree)'),
    rtree_bounds: f('bool cadaclysm_blacksmith_rtree_bounds(const CadaclysmBlacksmithRTree *tree, _Out_ double *out)'),
    rtree_free: f('void cadaclysm_blacksmith_rtree_free(CadaclysmBlacksmithRTree *tree)'),
    rtree_search: f('CadaclysmBlacksmithRTreeHits *cadaclysm_blacksmith_rtree_search(const CadaclysmBlacksmithRTree *tree, const double *box_)'),
    rtree_within: f('CadaclysmBlacksmithRTreeHits *cadaclysm_blacksmith_rtree_within(const CadaclysmBlacksmithRTree *tree, const double *p, double r)'),
    rtree_nearest: f('CadaclysmBlacksmithRTreeHits *cadaclysm_blacksmith_rtree_nearest(const CadaclysmBlacksmithRTree *tree, const double *p, uint32_t k)'),
    rtree_ray: f('CadaclysmBlacksmithRTreeHits *cadaclysm_blacksmith_rtree_ray(const CadaclysmBlacksmithRTree *tree, const double *origin, const double *direction, double max_t)'),
    rtree_hits_count: f('uint32_t cadaclysm_blacksmith_rtree_hits_count(const CadaclysmBlacksmithRTreeHits *hits)'),
    rtree_hits_at: f('bool cadaclysm_blacksmith_rtree_hits_at(const CadaclysmBlacksmithRTreeHits *hits, uint32_t i, _Out_ CadaclysmBlacksmithRTreeHit *out)'),
    rtree_hits_free: f('void cadaclysm_blacksmith_rtree_hits_free(CadaclysmBlacksmithRTreeHits *hits)'),
    rtree_overlaps: f('CadaclysmBlacksmithRTreePairs *cadaclysm_blacksmith_rtree_overlaps(const CadaclysmBlacksmithRTree *a, const CadaclysmBlacksmithRTree *b, double slack)'),
    rtree_self_overlaps: f('CadaclysmBlacksmithRTreePairs *cadaclysm_blacksmith_rtree_self_overlaps(const CadaclysmBlacksmithRTree *tree, double slack)'),
    rtree_pairs_count: f('uint32_t cadaclysm_blacksmith_rtree_pairs_count(const CadaclysmBlacksmithRTreePairs *pairs)'),
    rtree_pairs_at: f('bool cadaclysm_blacksmith_rtree_pairs_at(const CadaclysmBlacksmithRTreePairs *pairs, uint32_t i, _Out_ CadaclysmBlacksmithRTreePair *out)'),
    rtree_pairs_free: f('void cadaclysm_blacksmith_rtree_pairs_free(CadaclysmBlacksmithRTreePairs *pairs)'),
    // The interpolator: an immutable handle. `_at`/`_sample` write into the caller's array, sized
    // `dimension` / `n * dimension`; a mode is one of CADACLYSM_BLACKSMITH_INTERPOLATE_* (0..4).
    interpolator_new: f('CadaclysmBlacksmithInterpolator *cadaclysm_blacksmith_interpolator_new(const double *samples, uint32_t count, uint32_t dimension, bool cyclic)'),
    interpolator_count: f('uint32_t cadaclysm_blacksmith_interpolator_count(const CadaclysmBlacksmithInterpolator *interpolator)'),
    interpolator_dimension: f('uint32_t cadaclysm_blacksmith_interpolator_dimension(const CadaclysmBlacksmithInterpolator *interpolator)'),
    interpolator_cyclic: f('bool cadaclysm_blacksmith_interpolator_cyclic(const CadaclysmBlacksmithInterpolator *interpolator)'),
    interpolator_at: f('bool cadaclysm_blacksmith_interpolator_at(const CadaclysmBlacksmithInterpolator *interpolator, double t, uint32_t mode, _Out_ double *out, uint32_t out_len)'),
    interpolator_sample: f('bool cadaclysm_blacksmith_interpolator_sample(const CadaclysmBlacksmithInterpolator *interpolator, const double *ts, uint32_t n, uint32_t mode, _Out_ double *out, uint32_t out_len)'),
    interpolator_free: f('void cadaclysm_blacksmith_interpolator_free(CadaclysmBlacksmithInterpolator *interpolator)'),
    // The Kiln's SubD cage. Every edit returns a new handle (or null and `last_error`), the
    // input untouched; `subd_pick` is false with an **empty** `last_error` for nothing near.
    subd_cuboid: f('CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_cuboid(double sx, double sy, double sz, uint32_t nx, uint32_t ny, uint32_t nz)'),
    subd_cylinder: f('CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_cylinder(double radius, double height, uint32_t sides, uint32_t rings, bool creased_rims)'),
    subd_sphere: f('CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_sphere(double radius, uint32_t segments)'),
    subd_torus: f('CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_torus(double major, double minor, uint32_t around, uint32_t tube)'),
    subd_from_parts: f('CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_from_parts(const double *positions, uint32_t vertex_count, const uint32_t *face_sizes, uint32_t face_count, const uint32_t *face_indices, uint32_t index_count, const uint32_t *creases, uint32_t crease_count, const uint32_t *pins, uint32_t pin_count, int32_t symmetry_axis, double symmetry_tolerance)'),
    subd_parts: f('bool cadaclysm_blacksmith_subd_parts(const CadaclysmBlacksmithSubd *subd, _Out_ CadaclysmBlacksmithSubdParts *out)'),
    subd_free: f('void cadaclysm_blacksmith_subd_free(CadaclysmBlacksmithSubd *subd)'),
    subd_transform: f('CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_transform(const CadaclysmBlacksmithSubd *subd, uint32_t kind, const uint32_t *ids, uint32_t id_count, const double *matrix)'),
    subd_set_crease: f('CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_set_crease(const CadaclysmBlacksmithSubd *subd, const uint32_t *edges, uint32_t edge_count, bool on)'),
    subd_set_pin: f('CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_set_pin(const CadaclysmBlacksmithSubd *subd, const uint32_t *vertices, uint32_t vertex_count, bool on)'),
    subd_extrude: f('CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_extrude(const CadaclysmBlacksmithSubd *subd, const uint32_t *faces, uint32_t face_count, double distance)'),
    subd_subdivide: f('CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_subdivide(const CadaclysmBlacksmithSubd *subd, const uint32_t *faces, uint32_t face_count)'),
    subd_inset: f('CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_inset(const CadaclysmBlacksmithSubd *subd, const uint32_t *faces, uint32_t face_count, double amount, bool individual)'),
    subd_insert_loop: f('CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_insert_loop(const CadaclysmBlacksmithSubd *subd, uint32_t a, uint32_t b, double at)'),
    subd_mirror_on: f('CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_mirror_on(const CadaclysmBlacksmithSubd *subd, uint32_t axis)'),
    subd_mirror_off: f('CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_mirror_off(const CadaclysmBlacksmithSubd *subd)'),
    subd_full: f('CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_full(const CadaclysmBlacksmithSubd *subd)'),
    subd_edge_loop: f('CadaclysmBlacksmithSubd *cadaclysm_blacksmith_subd_edge_loop(const CadaclysmBlacksmithSubd *subd, uint32_t a, uint32_t b)'),
    subd_smooth_mesh: f('bool cadaclysm_blacksmith_subd_smooth_mesh(const CadaclysmBlacksmithSubd *subd, uint32_t levels, _Out_ CadaclysmBlacksmithSubdMesh *out)'),
    subd_pick: f('bool cadaclysm_blacksmith_subd_pick(const CadaclysmBlacksmithSubd *subd, const double *point, uint32_t kind, _Out_ uint32_t *out)'),
    subd_to_solid: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_subd_to_solid(const CadaclysmBlacksmithSubd *subd, double tolerance, double g1_angle_deg, uint32_t max_levels, _Out_ CadaclysmBlacksmithSubdReport *report)'),
    // the 2D constraint sketcher (`Sketch`). A `const uint32_t *` list is lent until the next
    // call on the same sketch and its `size_t *count` filled through a one-element
    // `BigUint64Array`; `Sketch._lent` copies it out at once.
    sketch_new: f('CadaclysmBlacksmithSketch *cadaclysm_blacksmith_sketch_new(void)'),
    sketch_free: f('void cadaclysm_blacksmith_sketch_free(CadaclysmBlacksmithSketch *s)'),
    sketch_from_profile: f('CadaclysmBlacksmithSketch *cadaclysm_blacksmith_sketch_from_profile(const CadaclysmBlacksmithProfile *profile, bool infer, double tolerance)'),
    sketch_add_point: f('uint32_t cadaclysm_blacksmith_sketch_add_point(CadaclysmBlacksmithSketch *s, double x, double y)'),
    sketch_add_line: f('uint32_t cadaclysm_blacksmith_sketch_add_line(CadaclysmBlacksmithSketch *s, uint32_t a, uint32_t b)'),
    sketch_add_circle: f('uint32_t cadaclysm_blacksmith_sketch_add_circle(CadaclysmBlacksmithSketch *s, uint32_t centre, double r)'),
    sketch_add_arc: f('uint32_t cadaclysm_blacksmith_sketch_add_arc(CadaclysmBlacksmithSketch *s, uint32_t centre, uint32_t start, uint32_t end)'),
    sketch_add_bezier: f('uint32_t cadaclysm_blacksmith_sketch_add_bezier(CadaclysmBlacksmithSketch *s, uint32_t start, double c1x, double c1y, double c2x, double c2y, double x, double y)'),
    sketch_add_conic: f('uint32_t cadaclysm_blacksmith_sketch_add_conic(CadaclysmBlacksmithSketch *s, uint32_t start, double cx, double cy, double x, double y, double weight)'),
    sketch_add_nurbs: f('uint32_t cadaclysm_blacksmith_sketch_add_nurbs(CadaclysmBlacksmithSketch *s, uint32_t start, uint32_t degree, const double *xy, size_t count, const double *weights, const double *knots, size_t knot_count)'),
    sketch_add_rect: f('const uint32_t *cadaclysm_blacksmith_sketch_add_rect(CadaclysmBlacksmithSketch *s, double x0, double y0, double x1, double y1, _Out_ size_t *count)'),
    sketch_kind: f('uint32_t cadaclysm_blacksmith_sketch_kind(const CadaclysmBlacksmithSketch *s, uint32_t id)'),
    sketch_entities: f('const uint32_t *cadaclysm_blacksmith_sketch_entities(CadaclysmBlacksmithSketch *s, _Out_ size_t *count)'),
    sketch_point: f('bool cadaclysm_blacksmith_sketch_point(const CadaclysmBlacksmithSketch *s, uint32_t id, _Out_ double *out)'),
    sketch_set_point: f('bool cadaclysm_blacksmith_sketch_set_point(CadaclysmBlacksmithSketch *s, uint32_t id, double x, double y)'),
    sketch_radius: f('double cadaclysm_blacksmith_sketch_radius(const CadaclysmBlacksmithSketch *s, uint32_t id)'),
    sketch_set_radius: f('bool cadaclysm_blacksmith_sketch_set_radius(CadaclysmBlacksmithSketch *s, uint32_t id, double r)'),
    sketch_centre: f('uint32_t cadaclysm_blacksmith_sketch_centre(const CadaclysmBlacksmithSketch *s, uint32_t id)'),
    sketch_ends: f('const uint32_t *cadaclysm_blacksmith_sketch_ends(CadaclysmBlacksmithSketch *s, uint32_t id, _Out_ size_t *count)'),
    sketch_set_construction: f('bool cadaclysm_blacksmith_sketch_set_construction(CadaclysmBlacksmithSketch *s, uint32_t id, bool on)'),
    sketch_is_construction: f('bool cadaclysm_blacksmith_sketch_is_construction(const CadaclysmBlacksmithSketch *s, uint32_t id)'),
    sketch_is_reference: f('bool cadaclysm_blacksmith_sketch_is_reference(const CadaclysmBlacksmithSketch *s, uint32_t id)'),
    sketch_remove_entity: f('const uint32_t *cadaclysm_blacksmith_sketch_remove_entity(CadaclysmBlacksmithSketch *s, uint32_t id, _Out_ size_t *count)'),
    sketch_reference: f('uint32_t cadaclysm_blacksmith_sketch_reference(CadaclysmBlacksmithSketch *s, const CadaclysmBlacksmithSketch *other, uint32_t entity)'),
    sketch_update_reference: f('bool cadaclysm_blacksmith_sketch_update_reference(CadaclysmBlacksmithSketch *s, uint32_t id, const CadaclysmBlacksmithSketch *other, _Out_ double *report)'),
    sketch_constrain: f('uint32_t cadaclysm_blacksmith_sketch_constrain(CadaclysmBlacksmithSketch *s, uint32_t kind, const uint32_t *refs, size_t ref_count, double value, bool driving, uint32_t sense, uint32_t end)'),
    sketch_constraints: f('const uint32_t *cadaclysm_blacksmith_sketch_constraints(CadaclysmBlacksmithSketch *s, _Out_ size_t *count)'),
    sketch_constraint_kind: f('uint32_t cadaclysm_blacksmith_sketch_constraint_kind(const CadaclysmBlacksmithSketch *s, uint32_t id)'),
    sketch_constraint_refs: f('const uint32_t *cadaclysm_blacksmith_sketch_constraint_refs(CadaclysmBlacksmithSketch *s, uint32_t id, _Out_ size_t *count)'),
    sketch_constraint_value: f('double cadaclysm_blacksmith_sketch_constraint_value(const CadaclysmBlacksmithSketch *s, uint32_t id)'),
    sketch_constraint_driving: f('bool cadaclysm_blacksmith_sketch_constraint_driving(const CadaclysmBlacksmithSketch *s, uint32_t id)'),
    sketch_constraint_sense: f('uint32_t cadaclysm_blacksmith_sketch_constraint_sense(const CadaclysmBlacksmithSketch *s, uint32_t id)'),
    sketch_constraint_end: f('uint32_t cadaclysm_blacksmith_sketch_constraint_end(const CadaclysmBlacksmithSketch *s, uint32_t id)'),
    sketch_is_joint_tangent: f('bool cadaclysm_blacksmith_sketch_is_joint_tangent(const CadaclysmBlacksmithSketch *s, uint32_t id)'),
    sketch_remove: f('bool cadaclysm_blacksmith_sketch_remove(CadaclysmBlacksmithSketch *s, uint32_t id)'),
    sketch_set_value: f('bool cadaclysm_blacksmith_sketch_set_value(CadaclysmBlacksmithSketch *s, uint32_t id, double value, _Out_ double *report)'),
    sketch_set_driving: f('bool cadaclysm_blacksmith_sketch_set_driving(CadaclysmBlacksmithSketch *s, uint32_t id, bool driving, _Out_ double *report)'),
    sketch_measure: f('double cadaclysm_blacksmith_sketch_measure(const CadaclysmBlacksmithSketch *s, uint32_t id)'),
    sketch_solve: f('bool cadaclysm_blacksmith_sketch_solve(CadaclysmBlacksmithSketch *s, _Out_ double *report)'),
    sketch_drag: f('bool cadaclysm_blacksmith_sketch_drag(CadaclysmBlacksmithSketch *s, const uint32_t *points, const double *xy, size_t count, _Out_ double *report)'),
    sketch_report_ids: f('const uint32_t *cadaclysm_blacksmith_sketch_report_ids(const CadaclysmBlacksmithSketch *s, _Out_ size_t *count)'),
    sketch_diagnose: f('bool cadaclysm_blacksmith_sketch_diagnose(CadaclysmBlacksmithSketch *s, _Out_ double *out)'),
    sketch_dof_list: f('const uint32_t *cadaclysm_blacksmith_sketch_dof_list(CadaclysmBlacksmithSketch *s, uint32_t which, _Out_ size_t *count)'),
    sketch_dof_part: f('bool cadaclysm_blacksmith_sketch_dof_part(const CadaclysmBlacksmithSketch *s, uint32_t part, _Out_ double *out)'),
    sketch_dof_part_list: f('const uint32_t *cadaclysm_blacksmith_sketch_dof_part_list(CadaclysmBlacksmithSketch *s, uint32_t part, uint32_t which, _Out_ size_t *count)'),
    sketch_profiles: f('CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_sketch_profiles(const CadaclysmBlacksmithSketch *s, double tolerance)'),
    sketch_open_chains: f('CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_sketch_open_chains(const CadaclysmBlacksmithSketch *s, double tolerance)'),
    leaked_edges: f('uint32_t cadaclysm_blacksmith_leaked_edges(const CadaclysmBlacksmithSolid *solid, double tolerance)'),
    unpaired_edges: f('uint32_t cadaclysm_blacksmith_unpaired_edges(const CadaclysmBlacksmithSolid *solid, double tolerance)'),
    manifold: f('bool cadaclysm_blacksmith_manifold(const CadaclysmBlacksmithSolid *solid, _Out_ uint32_t *out)'),
    face_round_radius: f('double cadaclysm_blacksmith_face_round_radius(const CadaclysmBlacksmithSolid *solid, uint32_t face)'),
    face_chamfer_distance: f('double cadaclysm_blacksmith_face_chamfer_distance(const CadaclysmBlacksmithSolid *solid, uint32_t face)'),
    edge_bezier_count: f('uint32_t cadaclysm_blacksmith_edge_bezier_count(const CadaclysmBlacksmithSolid *solid, double tolerance)'),
    edge_beziers: f('bool cadaclysm_blacksmith_edge_beziers(const CadaclysmBlacksmithSolid *solid, double tolerance, _Out_ double *out)'),
    isocurve_bezier_count: f('uint32_t cadaclysm_blacksmith_isocurve_bezier_count(const CadaclysmBlacksmithSolid *solid, uint32_t density, double tolerance)'),
    isocurve_beziers: f('bool cadaclysm_blacksmith_isocurve_beziers(const CadaclysmBlacksmithSolid *solid, uint32_t density, double tolerance, _Out_ double *out)'),
    // OWNED bytes, as `3dm_bytes`': `*len` of them, freed by `bytes_free(bytes, len)`
    mesh_file: f('uint8_t *cadaclysm_blacksmith_mesh_file(const CadaclysmBlacksmithSolid **solids, size_t count, const char *format, const char **names, const double *looks, double tolerance, _Out_ size_t *len)'),
    cuboid: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_cuboid(double x, double y, double z)'),
    cylinder: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_cylinder(double r, double h)'),
    cone: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_cone(double r, double h)'),
    sphere: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sphere(double r)'),
    torus: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_torus(double major, double minor)'),
    wedge: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_wedge(double x, double y, double z, double top_x)'),
    pyramid: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_pyramid(uint32_t sides, double r, double h)'),
    extrude: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_extrude(const CadaclysmBlacksmithProfile *profile, const double *frame, double height)'),
    extrude_open: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_extrude_open(const CadaclysmBlacksmithProfile *profile, const double *frame, double height)'),
    extrude_tapered: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_extrude_tapered(const CadaclysmBlacksmithProfile *profile, const double *frame, double height, double taper)'),
    extrude_open_tapered: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_extrude_open_tapered(const CadaclysmBlacksmithProfile *profile, const double *frame, double height, double taper)'),
    extrude_between: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_extrude_between(const CadaclysmBlacksmithProfile *profile, const double *frame, const double *bottom, const double *top)'),
    extrude_open_between: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_extrude_open_between(const CadaclysmBlacksmithProfile *profile, const double *frame, const double *bottom, const double *top)'),
    slant_of_plane: f('bool cadaclysm_blacksmith_slant_of_plane(const double *frame, const double *point, const double *normal, _Out_ double *out)'),
    frame_midplane: f('bool cadaclysm_blacksmith_frame_midplane(const double *a, const double *b, _Out_ double *out)'),
    frame_through: f('bool cadaclysm_blacksmith_frame_through(const double *p, const double *q, const double *r, _Out_ double *out)'),
    // the transforms (16 doubles, row-major) and quaternions (w x y z): a success flag, the answer in `out`
    transform_translation: f('bool cadaclysm_blacksmith_transform_translation(const double *v, _Out_ double *out)'),
    transform_rotation: f('bool cadaclysm_blacksmith_transform_rotation(const double *axis, double radians, _Out_ double *out)'),
    transform_mirror: f('bool cadaclysm_blacksmith_transform_mirror(const double *plane, _Out_ double *out)'),
    transform_scale: f('bool cadaclysm_blacksmith_transform_scale(const double *centre, double k, _Out_ double *out)'),
    transform_scale_xyz: f('bool cadaclysm_blacksmith_transform_scale_xyz(const double *frame, double sx, double sy, double sz, _Out_ double *out)'),
    transform_shear: f('bool cadaclysm_blacksmith_transform_shear(const double *plane, const double *dir, double factor, _Out_ double *out)'),
    transform_plane_to_plane: f('bool cadaclysm_blacksmith_transform_plane_to_plane(const double *a, const double *b, _Out_ double *out)'),
    transform_change_basis: f('bool cadaclysm_blacksmith_transform_change_basis(const double *from, const double *to, _Out_ double *out)'),
    transform_planar_projection: f('bool cadaclysm_blacksmith_transform_planar_projection(const double *plane, _Out_ double *out)'),
    transform_project_along: f('bool cadaclysm_blacksmith_transform_project_along(const double *plane, const double *dir, _Out_ double *out)'),
    transform_compose: f('bool cadaclysm_blacksmith_transform_compose(const double *a, const double *b, _Out_ double *out)'),
    transform_inverse: f('bool cadaclysm_blacksmith_transform_inverse(const double *m, _Out_ double *out)'),
    transform_is_rigid: f('uint32_t cadaclysm_blacksmith_transform_is_rigid(const double *m, double tolerance)'),
    transform_is_similarity: f('double cadaclysm_blacksmith_transform_is_similarity(const double *m, double tolerance)'),
    transform_decompose_rigid: f('bool cadaclysm_blacksmith_transform_decompose_rigid(const double *m, double tolerance, _Out_ double *out)'),
    transform_decompose_similarity: f('bool cadaclysm_blacksmith_transform_decompose_similarity(const double *m, double tolerance, _Out_ double *out)'),
    transform_decompose_affine: f('bool cadaclysm_blacksmith_transform_decompose_affine(const double *m, _Out_ double *out)'),
    quaternion_from_axis_angle: f('bool cadaclysm_blacksmith_quaternion_from_axis_angle(const double *dir, double radians, _Out_ double *out)'),
    quaternion_from_transform: f('bool cadaclysm_blacksmith_quaternion_from_transform(const double *m, _Out_ double *out)'),
    quaternion_to_transform: f('bool cadaclysm_blacksmith_quaternion_to_transform(const double *q, const double *centre, _Out_ double *out)'),
    quaternion_slerp: f('bool cadaclysm_blacksmith_quaternion_slerp(const double *a, const double *b, double s, _Out_ double *out)'),
    // value geometry: flat arrays of doubles tagged with a kind (CADACLYSM_BLACKSMITH_VALUE_*)
    value_size: f('uint32_t cadaclysm_blacksmith_value_size(uint32_t kind)'),
    value_check: f('bool cadaclysm_blacksmith_value_check(uint32_t kind, const double *value, _Out_ double *out)'),
    value_bounds: f('bool cadaclysm_blacksmith_value_bounds(uint32_t kind, const double *value, _Out_ double *out)'),
    value_transform: f('bool cadaclysm_blacksmith_value_transform(uint32_t kind, const double *value, const double *matrix, _Out_ double *out)'),
    curve_value_point_at: f('bool cadaclysm_blacksmith_curve_value_point_at(uint32_t kind, const double *value, double t, _Out_ double *out)'),
    curve_value_tangent_at: f('bool cadaclysm_blacksmith_curve_value_tangent_at(uint32_t kind, const double *value, double t, _Out_ double *out)'),
    curve_value_length: f('bool cadaclysm_blacksmith_curve_value_length(uint32_t kind, const double *value, _Out_ double *out)'),
    curve_value_closest_point: f('bool cadaclysm_blacksmith_curve_value_closest_point(uint32_t kind, const double *value, const double *point, _Out_ double *out)'),
    circle_through: f('bool cadaclysm_blacksmith_circle_through(const double *a, const double *b, const double *c, _Out_ double *out)'),
    arc_through: f('bool cadaclysm_blacksmith_arc_through(const double *a, const double *b, const double *c, _Out_ double *out)'),
    arc_from_start_tangent_end: f('bool cadaclysm_blacksmith_arc_from_start_tangent_end(const double *a, const double *tangent, const double *c, _Out_ double *out)'),
    ellipse_from_circle: f('bool cadaclysm_blacksmith_ellipse_from_circle(const double *value, _Out_ double *out)'),
    surface_value_point_at: f('bool cadaclysm_blacksmith_surface_value_point_at(uint32_t kind, const double *value, double u, double v, _Out_ double *out)'),
    surface_value_normal_at: f('bool cadaclysm_blacksmith_surface_value_normal_at(uint32_t kind, const double *value, double u, double v, _Out_ double *out)'),
    surface_value_closest_point: f('bool cadaclysm_blacksmith_surface_value_closest_point(uint32_t kind, const double *value, const double *point, _Out_ double *out)'),
    surface_value_domain: f('bool cadaclysm_blacksmith_surface_value_domain(uint32_t kind, const double *value, _Out_ double *out)'),
    surface_value_nurbs_sheet: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_surface_value_nurbs_sheet(uint32_t kind, const double *value)'),
    solid_value_contains: f('uint32_t cadaclysm_blacksmith_solid_value_contains(uint32_t kind, const double *value, const double *point, double tolerance)'),
    solid_value_area: f('bool cadaclysm_blacksmith_solid_value_area(uint32_t kind, const double *value, _Out_ double *out)'),
    solid_value_volume: f('bool cadaclysm_blacksmith_solid_value_volume(uint32_t kind, const double *value, _Out_ double *out)'),
    solid_value_to_solid: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_solid_value_to_solid(uint32_t kind, const double *value)'),
    cuboid_from_bounds: f('bool cadaclysm_blacksmith_cuboid_from_bounds(const double *min, const double *max, _Out_ double *out)'),
    cuboid_around: f('bool cadaclysm_blacksmith_cuboid_around(const double *frame, const double *xyz, size_t count, _Out_ double *out)'),
    cuboid_corners: f('bool cadaclysm_blacksmith_cuboid_corners(const double *value, _Out_ double *out)'),
    cuboid_point_at: f('bool cadaclysm_blacksmith_cuboid_point_at(const double *value, double sx, double sy, double sz, _Out_ double *out)'),
    cuboid_closest_point: f('bool cadaclysm_blacksmith_cuboid_closest_point(const double *value, const double *point, _Out_ double *out)'),
    frame_fit: f('bool cadaclysm_blacksmith_frame_fit(const double *xyz, size_t count, _Out_ double *out, _Out_ double *deviation_out)'),
    // the rectangle, the triangle and the ray (value kinds 9-11, plan B4)
    rectangle_corners: f('bool cadaclysm_blacksmith_rectangle_corners(const double *value, _Out_ double *out)'),
    rectangle_area: f('bool cadaclysm_blacksmith_rectangle_area(const double *value, _Out_ double *out)'),
    rectangle_closest_point: f('bool cadaclysm_blacksmith_rectangle_closest_point(const double *value, const double *point, bool include_interior, _Out_ double *out)'),
    rectangle_contains: f('uint32_t cadaclysm_blacksmith_rectangle_contains(const double *value, const double *point, double tolerance)'),
    rectangle_to_sheet: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_rectangle_to_sheet(const double *value)'),
    triangle_area: f('bool cadaclysm_blacksmith_triangle_area(const double *value, _Out_ double *out)'),
    triangle_perimeter: f('bool cadaclysm_blacksmith_triangle_perimeter(const double *value, _Out_ double *out)'),
    triangle_centroid: f('bool cadaclysm_blacksmith_triangle_centroid(const double *value, _Out_ double *out)'),
    triangle_circumcircle: f('bool cadaclysm_blacksmith_triangle_circumcircle(const double *value, _Out_ double *out)'),
    triangle_point_at: f('bool cadaclysm_blacksmith_triangle_point_at(const double *value, double wa, double wb, double wc, _Out_ double *out)'),
    triangle_barycentric: f('bool cadaclysm_blacksmith_triangle_barycentric(const double *value, const double *point, _Out_ double *out)'),
    triangle_closest_point: f('bool cadaclysm_blacksmith_triangle_closest_point(const double *value, const double *point, _Out_ double *out)'),
    triangle_edge: f('bool cadaclysm_blacksmith_triangle_edge(const double *value, uint32_t index, _Out_ double *out)'),
    triangle_to_sheet: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_triangle_to_sheet(const double *value)'),
    ray_point_at: f('bool cadaclysm_blacksmith_ray_point_at(const double *value, double t, _Out_ double *out)'),
    ray_closest_point: f('bool cadaclysm_blacksmith_ray_closest_point(const double *value, const double *point, _Out_ double *out)'),
    loft: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_loft(const CadaclysmBlacksmithProfile *a, const double *frame_a, const CadaclysmBlacksmithProfile *b, const double *frame_b)'),
    loft_open: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_loft_open(const CadaclysmBlacksmithProfile *a, const double *frame_a, const CadaclysmBlacksmithProfile *b, const double *frame_b)'),
    loft_through: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_loft_through(const CadaclysmBlacksmithProfile **profiles, const double *frames, size_t count)'),
    loft_through_open: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_loft_through_open(const CadaclysmBlacksmithProfile **profiles, const double *frames, size_t count)'),
    revolve: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_revolve(const CadaclysmBlacksmithProfile *profile, const double *axis, double angle)'),
    revolve_open: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_revolve_open(const CadaclysmBlacksmithProfile *profile, const double *axis, double angle)'),
    coil: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_coil(const CadaclysmBlacksmithProfile *profile, const double *axis, double pitch, double turns)'),
    revolve_in_plane: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_revolve_in_plane(const CadaclysmBlacksmithProfile *profile, const double *frame, const double *axis, double angle)'),
    revolve_open_in_plane: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_revolve_open_in_plane(const CadaclysmBlacksmithProfile *profile, const double *frame, const double *axis, double angle)'),
    extrude_faces: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_extrude_faces(const CadaclysmBlacksmithSolid *sheet, double height)'),
    place: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_place(const CadaclysmBlacksmithSolid *solid, const double *frame)'),
    translate_profile: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_translate_profile(const CadaclysmBlacksmithProfile *profile, double dx, double dy)'),
    profile_rotate: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_rotate(const CadaclysmBlacksmithProfile *profile, double cx, double cy, double radians)'),
    profile_scale: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_scale(const CadaclysmBlacksmithProfile *profile, double cx, double cy, double sx, double sy)'),
    profile_mirror: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_mirror(const CadaclysmBlacksmithProfile *profile, double px, double py, double dx, double dy)'),
    profile_transform2d: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_transform2d(const CadaclysmBlacksmithProfile *profile, const double *m)'),
    profile_coloured: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_coloured(const CadaclysmBlacksmithProfile *profile, double r, double g, double b)'),
    profile_colour: f('bool cadaclysm_blacksmith_profile_colour(const CadaclysmBlacksmithProfile *profile, _Out_ double *out)'),
    parse_colour: f('bool cadaclysm_blacksmith_parse_colour(const char *text, _Out_ double *out)'),
    option_set: f('bool cadaclysm_blacksmith_option_set(const char *name, double value)'),
    option_get: f('bool cadaclysm_blacksmith_option_get(const char *name, _Out_ double *out)'),
    profile_round: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_round(const CadaclysmBlacksmithProfile *profile, double radius, const uint32_t *corners, size_t count, bool open)'),
    profile_close_loop: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_close_loop(const CadaclysmBlacksmithProfile *profile)'),
    profile_polylines: f('CadaclysmBlacksmithPolylines cadaclysm_blacksmith_profile_polylines(const CadaclysmBlacksmithProfile *profile, double tolerance)'),
    profile_polyline: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_polyline(const double *xy, size_t count, bool closed)'),
    profile_arc: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_arc(double cx, double cy, double r, double a0, double a1)'),
    profile_arc_through: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_arc_through(double x0, double y0, double xm, double ym, double x1, double y1)'),
    profile_ellipse: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_ellipse(double cx, double cy, double rx, double ry)'),
    profile_from_beziers: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_from_beziers(const double *beziers, size_t count, bool recognise)'),
    profile_bezier_count: f('uint32_t cadaclysm_blacksmith_profile_bezier_count(const CadaclysmBlacksmithProfile *profile)'),
    profile_beziers: f('bool cadaclysm_blacksmith_profile_beziers(const CadaclysmBlacksmithProfile *profile, const double *frame, _Out_ double *out)'),
    profile_loops: f('bool cadaclysm_blacksmith_profile_loops(const CadaclysmBlacksmithProfile **pieces, size_t count, double tolerance, _Out_ uint32_t *out)'),
    profile_chain_order: f('bool cadaclysm_blacksmith_profile_chain_order(const CadaclysmBlacksmithProfile **pieces, size_t count, double tolerance, _Out_ uint32_t *out)'),
    profile_chain: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_chain(const CadaclysmBlacksmithProfile **pieces, size_t count, double tolerance)'),
    profile_from_loops: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_from_loops(const CadaclysmBlacksmithProfile **loops, size_t count)'),
    profile_piece_count: f('uint32_t cadaclysm_blacksmith_profile_piece_count(const CadaclysmBlacksmithProfile *profile, const CadaclysmBlacksmithProfile **cutters, size_t count, double tolerance)'),
    profile_piece: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_piece(const CadaclysmBlacksmithProfile *profile, const CadaclysmBlacksmithProfile **cutters, size_t count, uint32_t index, double tolerance)'),
    profile_trim_count: f('uint32_t cadaclysm_blacksmith_profile_trim_count(const CadaclysmBlacksmithProfile *profile, const CadaclysmBlacksmithProfile **cutters, size_t count, uint32_t piece, double tolerance)'),
    profile_trim_chain: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_trim_chain(const CadaclysmBlacksmithProfile *profile, const CadaclysmBlacksmithProfile **cutters, size_t count, uint32_t piece, uint32_t index, double tolerance)'),
    face: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_face(const CadaclysmBlacksmithProfile *profile, const double *frame)'),
    face_sheet: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_face_sheet(const CadaclysmBlacksmithSolid *solid, uint32_t face)'),
    drop_faces: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_drop_faces(const CadaclysmBlacksmithSolid *solid, const uint32_t *faces, size_t count)'),
    health: f('CadaclysmBlacksmithHealth *cadaclysm_blacksmith_health(const CadaclysmBlacksmithSolid *solid, double tolerance, bool mesh)'),
    health_free: f('void cadaclysm_blacksmith_health_free(CadaclysmBlacksmithHealth *health)'),
    health_summary: f('bool cadaclysm_blacksmith_health_summary(const CadaclysmBlacksmithHealth *health, _Out_ uint32_t *counts, _Out_ double *sizes)'),
    health_free_edges: f('uint32_t cadaclysm_blacksmith_health_free_edges(const CadaclysmBlacksmithHealth *health, _Out_ uint32_t *ids, _Out_ double *sizes)'),
    health_wires: f('uint32_t cadaclysm_blacksmith_health_wires(const CadaclysmBlacksmithHealth *health, _Out_ uint32_t *runs, _Out_ double *sizes)'),
    health_small: f('uint32_t cadaclysm_blacksmith_health_small(const CadaclysmBlacksmithHealth *health, _Out_ uint32_t *items, _Out_ double *sizes)'),
    health_crack_edges: f('uint32_t cadaclysm_blacksmith_health_crack_edges(const CadaclysmBlacksmithHealth *health, _Out_ uint32_t *ids)'),
    healed: f('CadaclysmBlacksmithHeal *cadaclysm_blacksmith_healed(const CadaclysmBlacksmithSolid *solid, double tolerance, uint32_t flags)'),
    heal_body: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_heal_body(const CadaclysmBlacksmithHeal *h)'),
    heal_free: f('void cadaclysm_blacksmith_heal_free(CadaclysmBlacksmithHeal *h)'),
    heal_summary: f('bool cadaclysm_blacksmith_heal_summary(const CadaclysmBlacksmithHeal *h, _Out_ uint32_t *counts, _Out_ double *sizes)'),
    heal_fixes: f('uint32_t cadaclysm_blacksmith_heal_fixes(const CadaclysmBlacksmithHeal *h, _Out_ uint32_t *items, _Out_ double *sizes)'),
    heal_refused: f('uint32_t cadaclysm_blacksmith_heal_refused(const CadaclysmBlacksmithHeal *h, _Out_ uint32_t *items, _Out_ double *sizes)'),
    edge_tolerance: f('double cadaclysm_blacksmith_edge_tolerance(const CadaclysmBlacksmithSolid *solid, uint32_t edge)'),
    effective_tolerance: f('double cadaclysm_blacksmith_effective_tolerance(const CadaclysmBlacksmithSolid **solids, size_t count)'),
    solid_tolerances: f('bool cadaclysm_blacksmith_solid_tolerances(const CadaclysmBlacksmithSolid *solid, _Out_ double *absolute, _Out_ double *angular)'),
    solid_with_tolerances: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_solid_with_tolerances(const CadaclysmBlacksmithSolid *solid, double absolute, double angular)'),
    vertex_tolerance: f('double cadaclysm_blacksmith_vertex_tolerance(const CadaclysmBlacksmithSolid *solid, double x, double y, double z)'),
    trim: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_trim(const CadaclysmBlacksmithSolid *sheet, const CadaclysmBlacksmithSolid *tool, bool keep_inside, double tolerance, CadaclysmBlacksmithProgress *progress, void *user)'),
    translate: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_translate(const CadaclysmBlacksmithSolid *solid, double dx, double dy, double dz)'),
    scaled: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_scaled(const CadaclysmBlacksmithSolid *solid, double factor)'),
    rotate: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_rotate(const CadaclysmBlacksmithSolid *solid, const double *axis, double radians)'),
    mirror: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_mirror(const CadaclysmBlacksmithSolid *solid, const double *plane)'),
    // any affine map, and the NURBS rewrite: the trims each lost through `inexact_out`
    solid_transform: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_solid_transform(const CadaclysmBlacksmithSolid *solid, const double *matrix, _Out_ uint32_t *inexact_out)'),
    solid_convert_to_nurbs: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_solid_convert_to_nurbs(const CadaclysmBlacksmithSolid *solid, uint32_t level, _Out_ uint32_t *inexact_out)'),
    join: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_join(const CadaclysmBlacksmithSolid *a, const CadaclysmBlacksmithSolid *b, double tolerance, CadaclysmBlacksmithProgress *progress, void *user)'),
    cut: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_cut(const CadaclysmBlacksmithSolid *a, const CadaclysmBlacksmithSolid *b, double tolerance, CadaclysmBlacksmithProgress *progress, void *user)'),
    common: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_common(const CadaclysmBlacksmithSolid *a, const CadaclysmBlacksmithSolid *b, double tolerance, CadaclysmBlacksmithProgress *progress, void *user)'),
    // The merge: `join`'s shape, its answer a non-manifold body. Its regions (and any solid's) come
    // as an owned `Regions` list, read with `_count`/`_at`/`_side_at` and freed with `_free`.
    merge: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_merge(const CadaclysmBlacksmithSolid *a, const CadaclysmBlacksmithSolid *b, double tolerance, CadaclysmBlacksmithProgress *progress, void *user)'),
    regions: f('CadaclysmBlacksmithRegions *cadaclysm_blacksmith_regions(const CadaclysmBlacksmithSolid *solid)'),
    regions_count: f('uint32_t cadaclysm_blacksmith_regions_count(const CadaclysmBlacksmithRegions *regions)'),
    regions_at: f('bool cadaclysm_blacksmith_regions_at(const CadaclysmBlacksmithRegions *regions, uint32_t i, _Out_ CadaclysmBlacksmithRegion *out)'),
    regions_side_at: f('bool cadaclysm_blacksmith_regions_side_at(const CadaclysmBlacksmithRegions *regions, uint32_t i, uint32_t k, _Out_ CadaclysmBlacksmithFaceSide *out)'),
    regions_free: f('void cadaclysm_blacksmith_regions_free(CadaclysmBlacksmithRegions *regions)'),
    region_solid: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_region_solid(const CadaclysmBlacksmithSolid *solid, uint32_t region)'),
    split_sheet: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_split_sheet(const CadaclysmBlacksmithSolid *sheet, const CadaclysmBlacksmithSolid *tool, double tolerance, CadaclysmBlacksmithProgress *progress, void *user)'),
    fillet: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_fillet(const CadaclysmBlacksmithSolid *solid, const uint32_t *edges, size_t count, double radius, double tolerance, CadaclysmBlacksmithProgress *progress, void *user)'),
    chamfer: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_chamfer(const CadaclysmBlacksmithSolid *solid, const uint32_t *edges, size_t count, double distance, double tolerance)'),
    shell: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_shell(const CadaclysmBlacksmithSolid *solid, double thickness, const uint32_t *open_faces, size_t count, double tolerance, CadaclysmBlacksmithProgress *progress, void *user)'),
    thicken: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_thicken(const CadaclysmBlacksmithSolid *solid, double thickness, double tolerance, CadaclysmBlacksmithProgress *progress, void *user)'),
    push_pull: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_push_pull(const CadaclysmBlacksmithSolid *solid, uint32_t face, double distance, double tolerance, CadaclysmBlacksmithProgress *progress, void *user)'),
    push_pull_faces: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_push_pull_faces(const CadaclysmBlacksmithSolid *solid, const uint32_t *faces, size_t count, double distance, double tolerance, CadaclysmBlacksmithProgress *progress, void *user)'),
    merge_flush: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_merge_flush(const CadaclysmBlacksmithSolid *solid)'),
    refillet: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_refillet(const CadaclysmBlacksmithSolid *solid, uint32_t face, double radius, double tolerance)'),
    unfillet: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_unfillet(const CadaclysmBlacksmithSolid *solid, uint32_t face)'),
    rechamfer: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_rechamfer(const CadaclysmBlacksmithSolid *solid, uint32_t face, double distance, double tolerance)'),
    unchamfer: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_unchamfer(const CadaclysmBlacksmithSolid *solid, uint32_t face)'),
    split: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_split(const CadaclysmBlacksmithSolid *solid, const CadaclysmBlacksmithSolid *tool, double tolerance, CadaclysmBlacksmithProgress *progress, void *user)'),
    split_by_plane: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_split_by_plane(const CadaclysmBlacksmithSolid *solid, const double *plane, double tolerance, CadaclysmBlacksmithProgress *progress, void *user)'),
    split_by_profile: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_split_by_profile(const CadaclysmBlacksmithSolid *solid, const CadaclysmBlacksmithProfile *profile, const double *frame, double tolerance, CadaclysmBlacksmithProgress *progress, void *user)'),
    lump_count: f('uint32_t cadaclysm_blacksmith_lump_count(const CadaclysmBlacksmithSolid *solid)'),
    lump: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_lump(const CadaclysmBlacksmithSolid *solid, uint32_t index)'),
    sweep_path_begin: f('CadaclysmBlacksmithSweepPath *cadaclysm_blacksmith_sweep_path_begin(double x, double y, double z)'),
    sweep_path_line_to: f('bool cadaclysm_blacksmith_sweep_path_line_to(CadaclysmBlacksmithSweepPath *p, double x, double y, double z)'),
    sweep_path_arc: f('bool cadaclysm_blacksmith_sweep_path_arc(CadaclysmBlacksmithSweepPath *p, double cx, double cy, double cz, double ax, double ay, double az, double angle)'),
    sweep_path_along: f('CadaclysmBlacksmithSweepPath *cadaclysm_blacksmith_sweep_path_along(const CadaclysmBlacksmithProfile *curve, const double *frame, double tolerance, bool open)'),
    sweep_path_free: f('void cadaclysm_blacksmith_sweep_path_free(CadaclysmBlacksmithSweepPath *p)'),
    sweep: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sweep(const CadaclysmBlacksmithProfile *profile, const double *frame, const CadaclysmBlacksmithSweepPath *path)'),
    sweep_open: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sweep_open(const CadaclysmBlacksmithProfile *profile, const double *frame, const CadaclysmBlacksmithSweepPath *path)'),
    pipe: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_pipe(const CadaclysmBlacksmithSweepPath *path, double radius, double thickness)'),
    // -- CAM: tools, stock and a job -- `Job.machine` recognises a part and appends
    // what makes it; `report()` and `operations()` read the result back.
    tool_flat: f('CadaclysmBlacksmithTool *cadaclysm_blacksmith_tool_flat(uint32_t number, double diameter, double flute_length, double feed, double plunge, double rpm)'),
    tool_ball: f('CadaclysmBlacksmithTool *cadaclysm_blacksmith_tool_ball(uint32_t number, double diameter, double flute_length, double feed, double plunge, double rpm)'),
    tool_drill: f('CadaclysmBlacksmithTool *cadaclysm_blacksmith_tool_drill(uint32_t number, double diameter, double flute_length, double feed, double rpm)'),
    tool_with_ramp_angle: f('CadaclysmBlacksmithTool *cadaclysm_blacksmith_tool_with_ramp_angle(const CadaclysmBlacksmithTool *t, double degrees)'),
    tool_free: f('void cadaclysm_blacksmith_tool_free(CadaclysmBlacksmithTool *t)'),
    tool_number: f('uint32_t cadaclysm_blacksmith_tool_number(const CadaclysmBlacksmithTool *t)'),
    tool_shape: f('const char *cadaclysm_blacksmith_tool_shape(const CadaclysmBlacksmithTool *t)'),
    tool_diameter: f('double cadaclysm_blacksmith_tool_diameter(const CadaclysmBlacksmithTool *t)'),
    tool_flute_length: f('double cadaclysm_blacksmith_tool_flute_length(const CadaclysmBlacksmithTool *t)'),
    tool_angle: f('double cadaclysm_blacksmith_tool_angle(const CadaclysmBlacksmithTool *t)'),
    tool_corner_radius: f('double cadaclysm_blacksmith_tool_corner_radius(const CadaclysmBlacksmithTool *t)'),
    stock_box: f('CadaclysmBlacksmithStock *cadaclysm_blacksmith_stock_box(double min_x, double min_y, double min_z, double max_x, double max_y, double max_z)'),
    stock_around: f('CadaclysmBlacksmithStock *cadaclysm_blacksmith_stock_around(const CadaclysmBlacksmithSolid *s, double margin)'),
    stock_free: f('void cadaclysm_blacksmith_stock_free(CadaclysmBlacksmithStock *s)'),
    job_new: f('CadaclysmBlacksmithJob *cadaclysm_blacksmith_job_new(const CadaclysmBlacksmithStock *stock, double safe_z)'),
    job_set_clearance: f('bool cadaclysm_blacksmith_job_set_clearance(CadaclysmBlacksmithJob *j, double clearance)'),
    job_set_tolerance: f('bool cadaclysm_blacksmith_job_set_tolerance(CadaclysmBlacksmithJob *j, double tolerance)'),
    job_set_spindle_dwell: f('bool cadaclysm_blacksmith_job_set_spindle_dwell(CadaclysmBlacksmithJob *j, double seconds)'),
    job_set_resolution: f('bool cadaclysm_blacksmith_job_set_resolution(CadaclysmBlacksmithJob *j, double resolution)'),
    job_set_name: f('bool cadaclysm_blacksmith_job_set_name(CadaclysmBlacksmithJob *j, const char *name)'),
    // The four manual verbs, and write_camotics's own file list -- header order, beside
    // job_machine's own binding below.
    job_face: f('bool cadaclysm_blacksmith_job_face(CadaclysmBlacksmithJob *j, const CadaclysmBlacksmithTool *t, double z, double stepover, double stepdown)'),
    job_contour: f('bool cadaclysm_blacksmith_job_contour(CadaclysmBlacksmithJob *j, const CadaclysmBlacksmithTool *t, const CadaclysmBlacksmithProfile *p, double top, double bottom, uint32_t side, double stepdown, bool climb, bool open)'),
    job_pocket: f('bool cadaclysm_blacksmith_job_pocket(CadaclysmBlacksmithJob *j, const CadaclysmBlacksmithTool *t, const CadaclysmBlacksmithProfile *p, double top, double bottom, double stepover, double stepdown)'),
    job_drill: f('bool cadaclysm_blacksmith_job_drill(CadaclysmBlacksmithJob *j, const CadaclysmBlacksmithTool *t, const double *xy, size_t count, double top, double bottom, double peck)'),
    job_machine: f('CadaclysmBlacksmithReport *cadaclysm_blacksmith_job_machine(CadaclysmBlacksmithJob *j, const CadaclysmBlacksmithSolid *part, const CadaclysmBlacksmithTool *end_mill, const CadaclysmBlacksmithTool *const *drills, size_t drill_count, double stepover, double stepdown, double skin, double peck)'),
    job_machine_with: f('CadaclysmBlacksmithReport *cadaclysm_blacksmith_job_machine_with(CadaclysmBlacksmithJob *j, const CadaclysmBlacksmithSolid *part, const CadaclysmBlacksmithTool *const *end_mills, size_t end_mill_count, const CadaclysmBlacksmithTool *const *drills, size_t drill_count, double stepover, double stepdown, double skin, double peck)'),
    job_machine_relieved: f('CadaclysmBlacksmithReport *cadaclysm_blacksmith_job_machine_relieved(CadaclysmBlacksmithJob *j, const CadaclysmBlacksmithSolid *part, const CadaclysmBlacksmithTool *const *end_mills, size_t end_mill_count, const CadaclysmBlacksmithTool *const *drills, size_t drill_count, double stepover, double stepdown, double skin, double peck, bool corner_relief)'),
    job_operations: f('CadaclysmBlacksmithOperations *cadaclysm_blacksmith_job_operations(const CadaclysmBlacksmithJob *j)'),
    job_gcode: f('CadaclysmBlacksmithPrograms *cadaclysm_blacksmith_job_gcode(const CadaclysmBlacksmithJob *j)'),
    job_camotics: f('CadaclysmBlacksmithPrograms *cadaclysm_blacksmith_job_camotics(const CadaclysmBlacksmithJob *j, const char *stem)'),
    job_stock: f('bool cadaclysm_blacksmith_job_stock(const CadaclysmBlacksmithJob *j, _Out_ double *min, _Out_ double *max)'),
    job_free: f('void cadaclysm_blacksmith_job_free(CadaclysmBlacksmithJob *j)'),
    report_count: f('uint32_t cadaclysm_blacksmith_report_count(const CadaclysmBlacksmithReport *r)'),
    report_kind: f('const char *cadaclysm_blacksmith_report_kind(const CadaclysmBlacksmithReport *r, uint32_t i)'),
    report_at: f('bool cadaclysm_blacksmith_report_at(const CadaclysmBlacksmithReport *r, uint32_t i, _Out_ double *out)'),
    report_size: f('double cadaclysm_blacksmith_report_size(const CadaclysmBlacksmithReport *r, uint32_t i)'),
    report_top: f('double cadaclysm_blacksmith_report_top(const CadaclysmBlacksmithReport *r, uint32_t i)'),
    report_bottom: f('double cadaclysm_blacksmith_report_bottom(const CadaclysmBlacksmithReport *r, uint32_t i)'),
    report_reason: f('const char *cadaclysm_blacksmith_report_reason(const CadaclysmBlacksmithReport *r, uint32_t i)'),
    report_region: f('CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_report_region(const CadaclysmBlacksmithReport *r, uint32_t i)'),
    report_text: f('const char *cadaclysm_blacksmith_report_text(const CadaclysmBlacksmithReport *r)'),
    report_free: f('void cadaclysm_blacksmith_report_free(CadaclysmBlacksmithReport *r)'),
    operations_count: f('uint32_t cadaclysm_blacksmith_operations_count(const CadaclysmBlacksmithOperations *l)'),
    operations_kind: f('const char *cadaclysm_blacksmith_operations_kind(const CadaclysmBlacksmithOperations *l, uint32_t i)'),
    operations_tool: f('uint32_t cadaclysm_blacksmith_operations_tool(const CadaclysmBlacksmithOperations *l, uint32_t i)'),
    operations_param_count: f('uint32_t cadaclysm_blacksmith_operations_param_count(const CadaclysmBlacksmithOperations *l, uint32_t i)'),
    operations_param_name: f('const char *cadaclysm_blacksmith_operations_param_name(const CadaclysmBlacksmithOperations *l, uint32_t i, uint32_t k)'),
    operations_param_value: f('double cadaclysm_blacksmith_operations_param_value(const CadaclysmBlacksmithOperations *l, uint32_t i, uint32_t k)'),
    operations_free: f('void cadaclysm_blacksmith_operations_free(CadaclysmBlacksmithOperations *l)'),
    programs_count: f('uint32_t cadaclysm_blacksmith_programs_count(const CadaclysmBlacksmithPrograms *l)'),
    programs_tool: f('uint32_t cadaclysm_blacksmith_programs_tool(const CadaclysmBlacksmithPrograms *l, uint32_t i)'),
    programs_name: f('const char *cadaclysm_blacksmith_programs_name(const CadaclysmBlacksmithPrograms *l, uint32_t i)'),
    programs_text: f('const char *cadaclysm_blacksmith_programs_text(const CadaclysmBlacksmithPrograms *l, uint32_t i)'),
    programs_free: f('void cadaclysm_blacksmith_programs_free(CadaclysmBlacksmithPrograms *l)'),
    // -- assemblies: `assembly_name` borrows, like `solid_name`; the three that follow return
    // owned text (the placement's or the file's), freed the same way `step`/`sat_text` are.
    assembly_new: f('CadaclysmBlacksmithAssembly *cadaclysm_blacksmith_assembly_new(const char *name)'),
    assembly_free: f('void cadaclysm_blacksmith_assembly_free(CadaclysmBlacksmithAssembly *assembly)'),
    assembly_name: f('const char *cadaclysm_blacksmith_assembly_name(const CadaclysmBlacksmithAssembly *assembly)'),
    assembly_place_solid: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_assembly_place_solid(CadaclysmBlacksmithAssembly *assembly, const CadaclysmBlacksmithSolid *solid, const double *frame, const char *name)'),
    assembly_place_assembly: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_assembly_place_assembly(CadaclysmBlacksmithAssembly *assembly, CadaclysmBlacksmithAssembly *placed, const double *frame, const char *name)'),
    assembly_step: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_assembly_step(const CadaclysmBlacksmithAssembly *assembly, const char *schema, uint32_t unit)'),
    // koffi marshals a JS string array into `const char **` for the call's duration, as
    // `CadaclysmOpenOptions.schemas` already does in cadaclysm.js.
    assembly_link: f('bool cadaclysm_blacksmith_assembly_link(CadaclysmBlacksmithAssembly *assembly, const char *name, const char **placements, size_t count)'),
    assembly_joint: f('bool cadaclysm_blacksmith_assembly_joint(CadaclysmBlacksmithAssembly *assembly, const char *name, const char *start, const char *end)'),
    // `frame`/`end_frame`, `lower`/`upper` and `has_lower`/`has_upper` stay alive for the call's
    // duration as the caller's typed arrays; either all four of lower/upper/has_lower/has_upper
    // are null (freedom_count 0) or all four are non-null with freedom_count entries each.
    assembly_pair_with: f('bool cadaclysm_blacksmith_assembly_pair_with(CadaclysmBlacksmithAssembly *assembly, const char *joint, const char *kind, const double *frame, const double *end_frame, const double *lower, const double *upper, const bool *has_lower, const bool *has_upper, size_t freedom_count, const double *params, size_t param_count)'),
    assembly_pair: f('bool cadaclysm_blacksmith_assembly_pair(CadaclysmBlacksmithAssembly *assembly, const char *joint, const char *kind, const double *frame, const double *end_frame, const double *lower, const double *upper, const bool *has_lower, const bool *has_upper, size_t freedom_count, double pitch)'),
    // koffi marshals the joints string array into `const char **`, as `assembly_link` does.
    // koffi marshals the states and interpolations string arrays into `const char *const *`, as `assembly_state`'s joints.
    assembly_sequence: f('bool cadaclysm_blacksmith_assembly_sequence(CadaclysmBlacksmithAssembly *assembly, const char *name, const char *const *states, const double *ts, const char *const *interpolations, size_t count, bool seconds)'),
    assembly_state: f('bool cadaclysm_blacksmith_assembly_state(CadaclysmBlacksmithAssembly *assembly, const char *name, const char **joints, const uint32_t *counts, const double *values, size_t row_count)'),
    // Returns a NEW assembly (null on refusal); `state` and `ground` may be null.
    assembly_posed: f('CadaclysmBlacksmithAssembly *cadaclysm_blacksmith_assembly_posed(const CadaclysmBlacksmithAssembly *assembly, const char **joints, const uint32_t *counts, const double *values, size_t row_count, const char *state, const char *ground)'),
    // The solids under an assembly, depth first: `part_path` is OWNED text, decoded and handed
    // back to `string_free` once, and null past `part_count`.
    assembly_part_count: f('uint32_t cadaclysm_blacksmith_assembly_part_count(const CadaclysmBlacksmithAssembly *assembly)'),
    assembly_part_path: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_assembly_part_path(const CadaclysmBlacksmithAssembly *assembly, uint32_t i)'),
    // The mechanism sweep: `joints` and `counts` laid out as `assembly_posed`'s, `values`
    // key-major (keyframe 0's values for every joint, then keyframe 1's), `ground` null for
    // none, and `allowed` a flat list of `allowed_count` pairs. A swept clashes handle, read
    // as `collider_swept_clash`'s.
    assembly_swept_clash: f('CadaclysmBlacksmithSweptClashes *cadaclysm_blacksmith_assembly_swept_clash(const CadaclysmBlacksmithAssembly *assembly, const char *const *joints, const uint32_t *counts, size_t joint_count, const double *values, uint32_t key_count, const char *ground, double tolerance, double clearance, double resolution, uint32_t max_steps, const uint32_t *allowed, uint32_t allowed_count, bool joined)'),
    assembly_base: f('bool cadaclysm_blacksmith_assembly_base(CadaclysmBlacksmithAssembly *assembly, const char *link)'),
    pair_freedom_count: f('uint32_t cadaclysm_blacksmith_pair_freedom_count(const char *kind)'),
    // -- the document: every `char *` is owned text (decoded, then `string_free`d), a NULL one a
    // refusal with `last_error`; `undo`/`redo`'s text `null` is "nothing to do", not a refusal.
    document_new: f('CadaclysmBlacksmithDocument *cadaclysm_blacksmith_document_new(const char *units)'),
    document_load: f('CadaclysmBlacksmithDocument *cadaclysm_blacksmith_document_load(const char *text)'),
    document_free: f('void cadaclysm_blacksmith_document_free(CadaclysmBlacksmithDocument *doc)'),
    document_save: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_document_save(const CadaclysmBlacksmithDocument *doc)'),
    document_apply: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_document_apply(CadaclysmBlacksmithDocument *doc, const char *op, const char *message)'),
    document_preview: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_document_preview(CadaclysmBlacksmithDocument *doc, const char *op)'),
    document_preview_begin: f('bool cadaclysm_blacksmith_document_preview_begin(CadaclysmBlacksmithDocument *doc)'),
    document_end_preview: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_document_end_preview(CadaclysmBlacksmithDocument *doc)'),
    document_batch_begin: f('bool cadaclysm_blacksmith_document_batch_begin(CadaclysmBlacksmithDocument *doc, const char *message)'),
    document_batch_end: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_document_batch_end(CadaclysmBlacksmithDocument *doc)'),
    document_batch_abort: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_document_batch_abort(CadaclysmBlacksmithDocument *doc)'),
    document_undo: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_document_undo(CadaclysmBlacksmithDocument *doc)'),
    document_redo: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_document_redo(CadaclysmBlacksmithDocument *doc)'),
    document_params: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_document_params(const CadaclysmBlacksmithDocument *doc)'),
    document_evaluate: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_document_evaluate(CadaclysmBlacksmithDocument *doc, bool cheap_only)'),
    document_evaluate_with: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_document_evaluate_with(CadaclysmBlacksmithDocument *doc, bool cheap_only, CadaclysmBlacksmithDocumentProgress *progress, void *user)'),
    document_result_kind: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_document_result_kind(const CadaclysmBlacksmithDocument *doc, const char *id)'),
    document_result_solid: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_document_result_solid(const CadaclysmBlacksmithDocument *doc, const char *id)'),
    document_result_profile: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_document_result_profile(const CadaclysmBlacksmithDocument *doc, const char *id)'),
    document_result_profile_count: f('uint32_t cadaclysm_blacksmith_document_result_profile_count(const CadaclysmBlacksmithDocument *doc, const char *id)'),
    document_result_profile_at: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_document_result_profile_at(const CadaclysmBlacksmithDocument *doc, const char *id, uint32_t i)'),
    document_result_nurbs_curve: f('CadaclysmBlacksmithNurbsCurve *cadaclysm_blacksmith_document_result_nurbs_curve(const CadaclysmBlacksmithDocument *doc, const char *id)'),
    document_result_subd: f('CadaclysmBlacksmithSubd *cadaclysm_blacksmith_document_result_subd(const CadaclysmBlacksmithDocument *doc, const char *id)'),
    document_value: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_document_value(const CadaclysmBlacksmithDocument *doc, const char *id)'),
    document_errors: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_document_errors(const CadaclysmBlacksmithDocument *doc)'),
    document_kinds: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_document_kinds(void)'),
    document_solid_body: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_document_solid_body(const CadaclysmBlacksmithSolid *solid)'),
    document_profile_path: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_document_profile_path(const CadaclysmBlacksmithProfile *profile)'),
    document_branch_new: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_document_branch_new(CadaclysmBlacksmithDocument *doc, const char *name, const char *at)'),
    document_branch_switch: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_document_branch_switch(CadaclysmBlacksmithDocument *doc, const char *name_or_commit_id)'),
    document_tips: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_document_tips(const CadaclysmBlacksmithDocument *doc)'),
    document_branch_rename: f('bool cadaclysm_blacksmith_document_branch_rename(CadaclysmBlacksmithDocument *doc, const char *old, const char *new_)'),
    document_branch_delete: f('bool cadaclysm_blacksmith_document_branch_delete(CadaclysmBlacksmithDocument *doc, const char *name)'),
    document_branch_list: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_document_branch_list(const CadaclysmBlacksmithDocument *doc)'),
    document_log: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_document_log(const CadaclysmBlacksmithDocument *doc, const char *branch)'),
    // -- the building documents: the same handle, `document_free`d; their own `cadaclysm_bim_` prefix
    bim_document_new: f('CadaclysmBlacksmithDocument *cadaclysm_bim_document_new(const char *units)'),
    bim_document_load: f('CadaclysmBlacksmithDocument *cadaclysm_bim_document_load(const char *text)'),
    bim_kinds: f('CadaclysmBlacksmithOwnedString cadaclysm_bim_kinds(void)'),
    bim_document_export_ifc: f('CadaclysmBlacksmithOwnedString cadaclysm_bim_document_export_ifc(CadaclysmBlacksmithDocument *doc, const char *options_json)'),
  };
  _flavour = flavoured || ['kernel', ''];
  return library;
}

// ---- helpers ------------------------------------------------------------------

function _text(raw) { return raw == null ? '' : String(raw); }
function _lastError() { return _text(_lib().last_error()); }
/** Throw the library's own reason, or `what` if it left none. */
function _fail(what) { throw new BuildError(_lastError() || what); }
/** The eight counts `cadaclysm_blacksmith_manifold` writes, as a record. */
function _manifold(row) {
  return {
    faces: row[0], edges: row[1], vertices: row[2],
    boundaryEdges: row[3], nonManifoldEdges: row[4], nonManifoldVertices: row[5],
    isManifold: row[6] === 1, isClosed: row[7] === 1,
  };
}

/**
 * What a solid measures, per unit density, each figure beside a bound on its own error, as a
 * record with a `weight(density)` on it.
 *
 * Per unit density is the primitive: a body's weight is `density * volume` and its inertia scales
 * the same way, so `weight` is the only figure that takes one. Nothing here multiplies by a density
 * on your behalf -- an assembly of two materials would have to undo it.
 *
 * `volume`, `centroid`, `inertia` and `principalMoments` mean something only where `closed`. Where
 * `accuracyMet` is false the refinement stopped before the accuracy asked for: the figures are
 * honest, they are simply less certain, and the errors say by how much.
 */
function _mass(raw) {
  const rows = (flat) => [
    [flat[0], flat[1], flat[2]], [flat[3], flat[4], flat[5]], [flat[6], flat[7], flat[8]],
  ];
  return {
    closed: raw.closed !== 0,
    inverted: raw.inverted !== 0,
    accuracyMet: raw.accuracy_met !== 0,
    fromMesh: raw.from_mesh !== 0,
    area: raw.area,
    areaError: raw.area_error,
    volume: raw.volume,
    volumeError: raw.volume_error,
    centroid: Array.from(raw.centroid),
    centroidError: raw.centroid_error,
    inertia: rows(raw.inertia),
    inertiaError: raw.inertia_error,
    principalMoments: Array.from(raw.principal_moments),
    principalAxes: rows(raw.principal_axes),
    /** `density * volume`, in whatever units the model and the density agree on. */
    weight(density) { return density * this.volume; },
  };
}

/** Nine row-major numbers as three rows of three. */
function _rows3(flat) { return [[flat[0], flat[1], flat[2]], [flat[3], flat[4], flat[5]], [flat[6], flat[7], flat[8]]]; }

/**
 * A closed solid's box on its principal axes (`Solid.orientedBox`), as a frozen record: `centre`,
 * three unit `axes` (row `i` is axis `i`, orthonormal and right-handed) and the `half` extent along
 * each. Not the minimal box in general; where two moments are equal the axes in their plane are a
 * free choice. `half` is grown by the tolerance the measurement settled on; `centre` is the box's
 * middle, not the centroid.
 */
function _orientedBoxOf(raw) {
  return Object.freeze({ centre: Array.from(raw.centre), axes: _rows3(raw.axes), half: Array.from(raw.half) });
}

/**
 * A measured length (`Solid.edgeLength`, `Profile.length`) beside an estimate of its error, as a
 * frozen record. `error` estimates the distance from the true length; where `accuracyMet` is false
 * the refinement stopped at its depth limit. `fromPolyline` says the curve was a sampled polyline.
 */
function _lengthOf(raw) {
  return Object.freeze({ length: raw.length, error: raw.error, accuracyMet: raw.accuracy_met !== 0, fromPolyline: raw.from_polyline !== 0 });
}

/**
 * The closest points between two solids' boundaries (`Solid.closest`), side `a` the solid asked
 * and side `b` the other, as a frozen record. `kindA`/`kindB` are 'face', 'edge' or 'vertex',
 * `indexA`/`indexB` the kernel's id for that feature, and `edgeA`/`edgeB` the index `fillet` and
 * `Solid.edges` use for an edge feature -- null for a face, a vertex, or an edge the fillet table
 * does not hold. `refined` false is the mesh's answer, within the tolerance of the true minimum.
 */
function _closestOf(raw) {
  return Object.freeze({
    distance: raw.distance,
    onA: Array.from(raw.on_a),
    onB: Array.from(raw.on_b),
    kindA: _text(raw.kind_a),
    indexA: raw.index_a,
    edgeA: raw.edge_a === NONE ? null : raw.edge_a,
    kindB: _text(raw.kind_b),
    indexB: raw.index_b,
    edgeB: raw.edge_b === NONE ? null : raw.edge_b,
    refined: Boolean(raw.refined),
  });
}

/**
 * The nearest point of a solid (or of one face) to a query point (`Solid.closestPoint`,
 * `Projector.closestPoint`, `Solid.faceClosestPoint`), frozen. `point` lies on the body's
 * boundary -- a query inside a closed body is answered by its nearest boundary point, not 0 --
 * and `distance` is from the query point to it. What the point lies on is named as `Closest`
 * names each side: `kind` is 'face', 'edge' or 'vertex', `index` the kernel's id for it, and
 * `edge` the index `Solid.edges` uses -- what `edgeLength`, `fillet` and `Solid.edgeClosestPoint`
 * take -- for an edge foot; null for a face, a vertex, and an edge the fillet table does not hold.
 * Read `edge`, not `index`, for the public edge number. `uv` is the face parameter of a foot
 * inside a face, null for an edge or a vertex foot. `normal` is unit: a face foot's outward
 * normal; an edge or vertex foot's direction from the foot to the query point; on the body
 * (`distance` 0) the mean of the adjacent faces' outward normals. `refined` true: refined onto
 * the exact geometry, `distance` never below the true minimum and within the tolerance of it;
 * false is the mesh's answer, within `[d - 2/3 tolerance, d + tolerance]` of the true minimum `d`.
 */
class PointFoot {
  constructor(raw) {
    const u = raw.uv[0], v = raw.uv[1];
    this.point = Array.from(raw.point);
    this.distance = raw.distance;
    this.kind = _text(raw.kind);
    this.index = raw.index;
    this.edge = raw.edge === NONE ? null : raw.edge;
    this.uv = Number.isNaN(u) || Number.isNaN(v) ? null : [u, v];
    this.normal = Array.from(raw.normal);
    this.refined = Boolean(raw.refined);
    Object.freeze(this);
  }
}

/** A query's optional `maxDistance` / `tolerance` as the C ABI takes it: undefined or null is NaN (no limit, unset). */
function _unset(x) { return x == null ? NaN : x; }

/**
 * The nearest points of two curves (`NurbsCurve.closestPoints`, and a `NearestObject`'s answer for
 * a curve), frozen: side `a` on the curve asked, `pointA` at its parameter `tA`; side `b` on the
 * other, `pointB` at `tB`; `distance` apart (0 where they cross). Exact.
 */
class CurvePair {
  constructor(raw) {
    this.distance = raw.distance;
    this.tA = raw.t_a;
    this.pointA = Array.from(raw.point_a);
    this.tB = raw.t_b;
    this.pointB = Array.from(raw.point_b);
    Object.freeze(this);
  }
}

/**
 * The nearest points of a curve and a solid's boundary (`Solid.curveClosestPoints`,
 * `Projector.curveClosestPoints`, and a `NearestObject`'s answer for a solid or a projector),
 * frozen: `pointOnCurve` at the curve's parameter `t`, and `pointOnBody`, `distance` apart. The
 * body's side is named as a `PointFoot` names its point -- `kind`, `index`, `edge` (the public edge
 * number for an edge foot, else null: read it, not `index`), `uv`, `normal`, `refined`. `crossing`
 * true where the curve passes through the boundary: `distance` is then exactly 0 and the earliest
 * crossing in `t` answers.
 */
class CurveBodyFoot {
  constructor(raw) {
    const body = new PointFoot(raw.body);
    this.distance = raw.distance;
    this.t = raw.t;
    this.pointOnCurve = Array.from(raw.point_on_curve);
    this.pointOnBody = body.point;
    this.kind = body.kind;
    this.index = body.index;
    this.edge = body.edge;
    this.uv = body.uv;
    this.normal = body.normal;
    this.refined = body.refined;
    this.crossing = Boolean(raw.crossing);
    Object.freeze(this);
  }
}

/**
 * The nearest of a list of things to a curve (`NurbsCurve.closestObject`), frozen: `which` the
 * item's index in the list, `distance` from `pointOnCurve` (at the curve's parameter `t`) to
 * `pointOnItem`. The item's own answer is `body` (a `CurveBodyFoot`) for a solid or a projector,
 * `pair` (a `CurvePair`, side `a` the curve asked) for a curve, `mesh` (a `CurveMeshFoot`) for a
 * `TriangleMesh`, and none of them (all null) for a point.
 */
class NearestObject {
  constructor(raw) {
    this.which = raw.which;
    this.distance = raw.distance;
    this.t = raw.t;
    this.pointOnCurve = Array.from(raw.point_on_curve);
    this.pointOnItem = Array.from(raw.point_on_item);
    // only the member `answer_kind` names is read: the other is zero bytes (a null `kind`)
    this.body = raw.answer_kind === 0 ? new CurveBodyFoot(raw.body) : null;
    this.pair = raw.answer_kind === 1 ? new CurvePair(raw.pair) : null;
    this.mesh = raw.answer_kind === 3 ? new CurveMeshFoot(raw.mesh) : null;
    Object.freeze(this);
  }
}

/** A mesh point's `kind`, by C's number: 0 a face, 1 an edge, 2 a vertex. */
const _MESH_KINDS = ['face', 'edge', 'vertex'];

/**
 * The nearest point of a `TriangleMesh` to a query point (`TriangleMesh.closestPoint`), frozen:
 * `point` on the mesh, `distance` to it, and `triangle` the lowest-numbered triangle holding it --
 * where it lies on an edge or a vertex several triangles share, the lower triangle answers.
 * `barycentric` are its three weights on `triangle`'s corners in index order, summing to 1;
 * `kind` what it lies on, 'face' (inside `triangle`), 'edge' or 'vertex', and `vertices` names
 * that: an edge's two vertex indices ascending, a vertex's one, none (an empty array) for a face.
 * Exact: no tolerance, no `refined` figure.
 */
class MeshPoint {
  constructor(raw) {
    const kind = _MESH_KINDS[raw.kind];
    if (kind === undefined) throw new BuildError(`triangle mesh: unknown point kind ${raw.kind}`);
    this.point = Array.from(raw.point);
    this.distance = raw.distance;
    this.triangle = raw.triangle;
    this.barycentric = Array.from(raw.barycentric);
    this.kind = kind;
    // C marks an unused slot UINT32_MAX; the wasm hands only the used ones
    this.vertices = Array.from(raw.vertices, Number).filter((v) => v !== NONE);
    Object.freeze(this);
  }
}

/**
 * The nearest points of a curve and a `TriangleMesh` (`TriangleMesh.curveClosestPoints`, and a
 * `NearestObject`'s answer for a mesh), frozen: `pointOnCurve` at the curve's parameter `t`, and
 * `pointOnMesh`, `distance` apart. The mesh's side is named as a `MeshPoint` names its point,
 * flat -- `triangle`, `barycentric`, `kind`, `vertices`. `crossing` true where the curve passes
 * through a triangle: `distance` is then exactly 0, at the earliest crossing in `t`; a curve that
 * touches without passing through is distance 0 and false. Exact.
 */
class CurveMeshFoot {
  constructor(raw) {
    const mesh = new MeshPoint(raw.mesh);
    this.distance = raw.distance;
    this.t = raw.t;
    this.pointOnCurve = Array.from(raw.point_on_curve);
    this.pointOnMesh = mesh.point;
    this.triangle = mesh.triangle;
    this.barycentric = mesh.barycentric;
    this.kind = mesh.kind;
    this.vertices = mesh.vertices;
    this.crossing = Boolean(raw.crossing);
    Object.freeze(this);
  }
}

/**
 * A point at an arc length (`Solid.edgePointAtLength`, `Profile.pointAtLength`, the samples of a
 * divide), as a frozen record: `point`, the unit `tangent`, the curve's own `parameter`, the
 * profile `segment` (the side; null on a solid's edge), an `error` estimate of the arc length
 * and `fromPolyline` for a curve that was a sampled polyline.
 */
function _atOf(raw) {
  return Object.freeze({
    point: Array.from(raw.point),
    tangent: Array.from(raw.tangent),
    parameter: raw.parameter,
    segment: raw.segment === NONE ? null : raw.segment,
    error: raw.error,
    fromPolyline: raw.from_polyline !== 0,
  });
}

/** `n` as the C `uint32_t`, or the refusal the Python wrapper's `ValueError` gives. */
function _count(n, what) {
  if (typeof n !== 'number' || !Number.isInteger(n)) throw new BuildError(`${what}: n must be a whole number, not ${n}`);
  if (n < 0 || n > NONE) throw new BuildError(`${what}: n is out of range: ${n}`);
  return n;
}

/** A divide's list as `At` records; a native list is read with `samples_count`/`samples_at` and freed on every path. */
function _samples(list, what) {
  if (list.doubles) {
    const out = [];
    for (let k = 0; k < list.doubles.length; k += 10) {
      const raw = {};
      _atFromDoubles(raw, list.doubles.slice(k, k + 10), what, 'not 10');
      out.push(_atOf(raw));
    }
    return out;
  }
  const l = _lib();
  try {
    const n = l.samples_count(list);
    const out = [];
    for (let i = 0; i < n; i++) {
      const raw = {};
      if (!l.samples_at(list, i, raw)) _fail('samples_at');
      out.push(_atOf(raw));
    }
    return out;
  } finally {
    l.samples_free(list);
  }
}

const _CONTAINMENT = ['outside', 'inside', 'on'];
/** A containment code as Python's string; any other code is a refusal naming `what`. */
function _containment(code, what) {
  if (!(Number.isInteger(code) && code >= 0 && code < _CONTAINMENT.length)) throw new BuildError(`${what}: the library answered ${code}, not a containment code`);
  return _CONTAINMENT[code];
}

/** [r, g, b] in 0..1 from colour text -- '#rgb', '#rrggbb' or a CSS colour name -- read by the
 *  library's own parser; null if it refused the text. */
function _colourText(text) {
  const out = new Float64Array(3);
  return _lib().parse_colour(String(text), out) ? Array.from(out) : null;
}

/** [r, g, b] from '#rgb', '#rrggbb', a CSS colour name or three numbers; the range is the library's to check. */
function _rgb(colour) {
  if (typeof colour === 'string') {
    const rgb = _colourText(colour);
    if (rgb) return rgb;
  } else if (colour != null && typeof colour[Symbol.iterator] === 'function') {
    const v = [...colour].map(Number);
    if (v.length === 3) return v;
  }
  throw new BuildError(`coloured: a colour is "#rgb", "#rrggbb", a CSS colour name or (r, g, b) in 0..1, not ${JSON.stringify(colour)}`);
}
// A list argument as indices: `value` must be a list -- any iterable but a string -- and
// each item an index (a whole number, 0 to 4294967295) or, where `edges`, an `Edge`.
// Refused here, named, before the kernel is asked: one edge is `[edge]`, never read as none.
function _indices(value, call, param, edges = false) {
  const described = (v) => (v instanceof Edge ? 'an Edge'
    : typeof v === 'string' ? JSON.stringify(v)
    // An array or other non-string iterable item prints its own way (`String([1])`
    // is "1"; a list of Edges is "[object Object],..."), not the item's own kind.
    : (v != null && typeof v !== 'number' && typeof v !== 'boolean' && typeof v[Symbol.iterator] === 'function') ? 'a list'
    : String(v));
  if (value == null || typeof value === 'string' || typeof value[Symbol.iterator] !== 'function') {
    throw new TypeError(`${call}: ${param} must be a list of ${edges ? 'Edge objects or indices' : 'indices'}, not ${described(value)}`);
  }
  const out = [];
  let i = 0;
  for (const item of value) {
    if (edges && item instanceof Edge) out.push(item.index);
    else if (typeof item === 'number' && Number.isInteger(item) && item >= 0 && item <= 0xffffffff) out.push(item);
    else throw new TypeError(`${call}: ${param}[${i}] is not ${edges ? 'an Edge or an index' : 'an index'}: ${described(item)}`);
    i++;
  }
  return Uint32Array.from(out);
}
// A list argument of names: `value` must be a list -- any iterable but a string -- and each
// item a string. Refused here, named, before the kernel is asked: one name is `[name]`,
// never split into characters.
function _names(value, call, param) {
  const described = (v) => (typeof v === 'string' ? JSON.stringify(v)
    : (v != null && typeof v !== 'number' && typeof v !== 'boolean' && typeof v[Symbol.iterator] === 'function') ? 'a list'
    : String(v));
  if (value == null || typeof value === 'string' || typeof value[Symbol.iterator] !== 'function') {
    throw new TypeError(`${call}: ${param} must be a list of names, not ${described(value)}`);
  }
  const out = [];
  let i = 0;
  for (const item of value) {
    if (typeof item !== 'string') throw new TypeError(`${call}: ${param}[${i}] is not a name: ${described(item)}`);
    out.push(item);
    i++;
  }
  return out;
}
// A pair's ranges argument: `null` (no ranges), or any iterable but a string -- each item
// `null` (both sides unbounded) or a `[lower, upper]` pair with either side `null`. Refused
// here, named, before the kernel is asked, as `_names` refuses a bare string for a list of
// names.
function _ranges(value, call) {
  const described = (v) => (typeof v === 'string' ? JSON.stringify(v)
    : (v != null && typeof v !== 'number' && typeof v !== 'boolean' && typeof v[Symbol.iterator] === 'function') ? 'a list'
    : String(v));
  if (value == null || typeof value === 'string' || typeof value[Symbol.iterator] !== 'function') {
    throw new TypeError(`${call}: ranges must be a list of [lower, upper] pairs, not ${described(value)}`);
  }
  const rows = Array.from(value);
  // Each entry is `null` (both sides unbounded) or a [lower, upper] pair -- never a bare
  // number or other non-iterable, which Python's own `r[0]`/`r[1]` indexing would refuse
  // (a Python non-sequence range entry raises `TypeError: '<type>' object is not
  // subscriptable`); refused here, named, rather than silently read as "both unbounded".
  rows.forEach((r, i) => {
    if (r != null && (typeof r === 'string' || typeof r[Symbol.iterator] !== 'function')) {
      throw new TypeError(`${call}: ranges[${i}] is not a [lower, upper] pair: ${described(r)}`);
    }
  });
  return rows;
}
// A state's rows argument: a `Map`, or any iterable but a string, of `[joint, values]` pairs.
// Refused here, named, before the kernel is asked, as `_names` refuses a bare string for a
// list of names.
function _stateRows(value, call) {
  const described = (v) => (typeof v === 'string' ? JSON.stringify(v)
    : (v != null && typeof v !== 'number' && typeof v !== 'boolean' && typeof v[Symbol.iterator] === 'function') ? 'a list'
    : String(v));
  if (value == null || typeof value === 'string' || (!(value instanceof Map) && typeof value[Symbol.iterator] !== 'function')) {
    throw new TypeError(`${call}: rows must be a Map or a list of [joint, values] pairs, not ${described(value)}`);
  }
  const rows = value instanceof Map ? Array.from(value) : Array.from(value);
  return rows.map((row, i) => {
    if (row == null || typeof row[Symbol.iterator] !== 'function') throw new TypeError(`${call}: rows[${i}] is not a [joint, values] pair: ${described(row)}`);
    const [joint, values] = row;
    if (typeof joint !== 'string') throw new TypeError(`${call}: rows[${i}][0] is not a name: ${described(joint)}`);
    return [joint, Array.from(values, Number)];
  });
}
// A joint key as the kernel reads it: a string as it is; an array (any iterable but a string)
// of names, each backslash and slash in a name escaped with a backslash, joined by "/".
function _jointPath(key) {
  if (typeof key === 'string') return key;
  if (key == null || typeof key[Symbol.iterator] !== 'function') throw new TypeError(`posed: a joint key must be a path string or a list of names, not ${String(key)}`);
  return Array.from(key, (n) => String(n).replace(/[\\/]/g, '\\$&')).join('/');
}
// `posed`'s values argument: nothing, a `Map`, a plain object, or an iterable of `[key, values]`
// pairs -- a value one number for a one-freedom joint, else a list.
function _posedRows(value) {
  if (value == null) return [];
  if (typeof value === 'string' || typeof value !== 'object') throw new TypeError(`posed: values must be a Map, an object or a list of [joint, values] pairs, not ${typeof value === 'string' ? JSON.stringify(value) : String(value)}`);
  const pairs = value instanceof Map ? Array.from(value)
    : typeof value[Symbol.iterator] === 'function' ? Array.from(value) : Object.entries(value);
  return pairs.map((row, i) => {
    if (row == null || typeof row[Symbol.iterator] !== 'function') throw new TypeError(`posed: values[${i}] is not a [joint, values] pair`);
    const [key, v] = row;
    if (typeof v === 'number' || typeof v === 'bigint') return [_jointPath(key), [Number(v)]];
    if (v == null || typeof v === 'string' || typeof v[Symbol.iterator] !== 'function') throw new TypeError(`posed: values[${i}][1] must be a number or a list of numbers, not ${String(v)}`);
    return [_jointPath(key), Array.from(v, Number)];
  });
}
/** A face index for the C call, NONE for the whole solid; a negative one would wrap to NONE. */
function _faceOrNone(solid, face, what) {
  if (face == null) return NONE;
  if (!Number.isInteger(face) || face < 0 || face >= NONE) throw new BuildError(`${what}: face ${face} is not one of the solid's ${solid.faces}`);
  return face;
}
function _checked(handle, what) { if (!handle) _fail(what); return handle; }
function _doubles(values, count, what) {
  const flat = Array.from(values, Number);
  if (flat.length !== count) throw new BuildError(`${what}: expected ${count} numbers, got ${flat.length}`);
  return Float64Array.from(flat);
}
/** Twelve numbers, or `[[ox,oy,oz],[xx,xy,xz],[yx,yy,yz],[zx,zy,zz]]`. */
function _frame(frame) { const a = Array.from(frame); return _doubles(a.length === 4 ? a.flat() : a, 12, 'frame'); }
/** Six numbers, or `[[px,py,pz],[dx,dy,dz]]`. */
function _axis(axis) { const a = Array.from(axis); return _doubles(a.length === 2 ? a.flat() : a, 6, 'axis'); }
function _flatPairs(points) { return Float64Array.from(Array.from(points).flat().map(Number)); }
/** A verb's distance tolerance as the C ABI takes it: null is unset, NaN, which the library
 * works at the inputs' `effectiveTolerance` (as it does 0). */
function _tol(tolerance) { return tolerance === null ? NaN : tolerance; }
/** A fair's `noInflection` as the C ABI takes it: the flag and the span's two ends, NaN for an open (null) one. */
function _noInflection(span) {
  if (span === null || span === undefined || span === false) return [false, 0, 0];
  if (span === true) return [true, NaN, NaN];
  const [lo, hi] = span;
  return [true, lo === null || lo === undefined ? NaN : Number(lo), hi === null || hi === undefined ? NaN : Number(hi)];
}
/** A JS `(phase, done, total)` callback as the ABI's progress pointer, or null. */
function _progress(callback) {
  if (callback == null) return null;
  return (phase, done, total) => { callback(_text(phase), Number(done), Number(total)); };
}
// A pointer is decoded; the wasm shim's arrays arrive already typed and are handed on.
/** The profiles of a list the library handed back (null: throw), each a handle of its own, the list freed. */
function _profileList(h, what) {
  const l = _lib();
  _checked(h, what);
  try {
    const n = l.profile_list_count(h);
    const out = [];
    for (let i = 0; i < n; i++) out.push(new Profile(l.profile_list_get(h, i)));
    return out;
  } finally {
    l.profile_list_free(h);
  }
}
function _floats(ptr, n) { return ptr == null ? null : ArrayBuffer.isView(ptr) ? ptr : n === 0 ? new Float32Array(0) : koffi.decode(ptr, 'float', n); }
function _uint32s(ptr, n) { return ptr == null ? null : ArrayBuffer.isView(ptr) ? ptr : n === 0 ? new Uint32Array(0) : koffi.decode(ptr, 'uint32_t', n); }
function _doublesAt(ptr, n) { return ptr == null ? null : ArrayBuffer.isView(ptr) ? ptr : n === 0 ? new Float64Array(0) : koffi.decode(ptr, 'double', n); }
/** `n` xyz triples at `ptr`, copied out as `[x, y, z]` arrays. */
function _pointsAt(ptr, n) {
  const flat = _doublesAt(ptr, 3 * n) ?? new Float64Array(0);
  const points = [];
  for (let k = 0; k < flat.length; k += 3) points.push(Array.from(flat.subarray(k, k + 3)));
  return points;
}

// ---- svg --------------------------------------------------------------------------
// Kept separate from the reader's own (cadaclysm.js), which has a scene to default
// `up` from -- this one has none, a solid carrying no convention of its own.

/** `CadaclysmBlacksmithSvgOptions.background`'s "none" value: no `<rect>` behind the drawing. */
const SVG_TRANSPARENT = 0xFFFFFFFF;

/**
 * The seven camera angles `SvgOptions.view` understands, degrees
 * `[azimuth, elevation]` -- the same table the reader's own `SvgView` gives
 * (`cadaclysm_view.VIEWS` in Python).
 */
const SvgView = Object.freeze({
  front: Object.freeze([-90, 0]), back: Object.freeze([90, 0]), left: Object.freeze([180, 0]), right: Object.freeze([0, 0]),
  top: Object.freeze([-90, 90]), bottom: Object.freeze([-90, -90]), iso: Object.freeze([-50, 28]),
});

/** A colour as the ABI's packed `0xRRGGBB`: `'#rgb'`, `'#rrggbb'`, a CSS colour name or an `[r, g, b]` triple (0..255). */
function _packedColour(colour, what) {
  if (typeof colour === 'string') {
    const rgb = _colourText(colour);
    if (rgb) return (Math.round(rgb[0] * 255) << 16) | (Math.round(rgb[1] * 255) << 8) | Math.round(rgb[2] * 255);
  } else if (colour != null && typeof colour[Symbol.iterator] === 'function') {
    const [r, g, b] = Array.from(colour, Number);
    if ([r, g, b].every(Number.isFinite)) return ((r & 0xff) << 16) | ((g & 0xff) << 8) | (b & 0xff);
  }
  throw new BuildError(`${what}: a colour is '#rgb', '#rrggbb', a CSS colour name or [r, g, b] in 0..255, not ${JSON.stringify(colour)}`);
}

/**
 * `SvgOptions`'s own defaults, the same `cadaclysm_blacksmith_svg_options_init`
 * fills: the viewer's `iso`, orthographic, a 1000-square page, a black
 * one-unit stroke on nothing (transparent), and edges with each solid's
 * outline beside them. `silhouettes` is on by default because a line set
 * alone cannot draw every body: a sphere's and a torus's only curves are
 * their seams, which are not edges of the body and are never drawn, so those
 * two came back as a blank page. Pass `silhouettes: false` for the lines
 * alone. Every field is
 * optional on `Solid.svgText`/`Solid.svg`/`Solid.svgAsync`, `writeSvgText` and
 * `writeSvg`; a field left out keeps its default here, not `undefined`. `up`
 * defaults to `'z'` when left out -- a solid carries no convention of its own.
 */
function svgOptionsDefaults() {
  return {
    view: 'iso', azimuth: null, elevation: null, up: null, fov: 0, width: 1000, height: 1000,
    margin: 0.05, tolerance: 0.1, stroke: '#000000', strokeWidth: 1, background: null,
    edges: true, curves: false, isocurves: false, polylines: false, silhouettes: true, hidden: null,
  };
}

/** `svg`'s `hidden`: CADACLYSM_BLACKSMITH_SVG_HIDDEN_REMOVED (32) and _HIDDEN_DASHED (64). */
const _SVG_HIDDEN = { removed: 32, dashed: 64 };

/**
 * `options` (over `svgOptionsDefaults()`) packed into a `CadaclysmBlacksmithSvgOptions`:
 * `view` fills `azimuth`/`elevation` unless they are set directly, `up`
 * ('y'/'z') defaults to `'z'`, a solid carrying no convention of its own.
 * `cadaclysm_blacksmith_svg_options_init` fills the struct first -- `size`
 * included -- so a field this function never sets still carries the
 * library's own default rather than a zeroed struct's. Skipped under the wasm
 * build: there is no `cadaclysm_blacksmith_svg_options_init` export (the wasm
 * side has no `size`/growth-safety concept, and every field below is set
 * unconditionally anyway), and calling it would throw "the wasm module has no
 * ...: rebuild it" before this function ever returns.
 */
function _svgOptions(options) {
  const o = { ...svgOptionsDefaults(), ...options };
  if (!(o.view in SvgView)) throw new BuildError(`svg: view must be one of ${Object.keys(SvgView).join(', ')}, not ${JSON.stringify(o.view)}`);
  const [baseAzimuth, baseElevation] = SvgView[o.view];
  const raw = {};
  if (!_wasm()) _lib().svg_options_init(raw);
  raw.up = String(o.up ?? 'z').toLowerCase() === 'y' ? 1 : 0;
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
  // `hidden`: null draws every line; 'removed' draws what is seen of each solid (hidden-line
  // removal, the solids hiding one another); 'dashed' draws that and the hidden lines dashed.
  if (o.hidden != null && !Object.prototype.hasOwnProperty.call(_SVG_HIDDEN, o.hidden)) {
    throw new BuildError(`svg: hidden must be null, 'removed' or 'dashed', not ${JSON.stringify(o.hidden)}`);
  }
  raw.flags = (o.edges ? 1 : 0) | (o.curves ? 2 : 0) | (o.isocurves ? 4 : 0) | (o.polylines ? 8 : 0)
    | (o.silhouettes ? 16 : 0) | (o.hidden == null ? 0 : _SVG_HIDDEN[o.hidden]);
  return raw;
}

// ---- module-level ---------------------------------------------------------------

/**
 * Which library this is: `'full'`, `'kernel-reader'` or `'kernel'` for a flavour of
 * the single library, `'kernel'` for the separate `cadaclysm_blacksmith` of earlier
 * releases, `'wasm'` in the browser.
 */
function flavour() { _lib(); return _flavour[0]; }

/**
 * The features the library was built with, comma-separated
 * (`'nodes,kernel,write-breps,write-meshes,bim,parts'`), or `''` for the separate
 * `cadaclysm_blacksmith` of earlier releases and in the browser.
 */
function features() { _lib(); return _flavour[1]; }

function version() { return _text(_lib().version()); }
function buildDate() { return _text(_lib().build_date()); }
function license(textOrPath) { if (!_lib().license_set(String(textOrPath))) throw new BuildError(_lastError() || 'license refused'); }
/**
 * Set a kernel option, by its name, for the whole process from the next call on:
 * `boolean.mesh_budget`, `boolean.finest_tolerance`, `profile_boolean.point_budget`,
 * `measure.default_accuracy`, `step.validation_properties`, `step.validation_accuracy`,
 * `tolerance.relative` or `tolerance.angular`.
 * Throws -- and changes nothing -- for a name that is not an
 * option or a value it does not take, saying which and what it takes. The last two stamp a
 * written STEP part file with each body's measured area, volume and centroid, there for the
 * kernel that reads the file to check the transfer against; off by default, since it
 * measures every body in the file at `step.validation_accuracy` (1e-5).
 */
function setOption(name, value) {
  if (!_lib().option_set(String(name), Number(value))) throw new BuildError(_lastError() || `option '${name}' refused`);
}
/**
 * The tolerance a verb given a null (or 0) `tolerance` works at over `solids`: the larger of
 * the loosest absolute tolerance they declare (`Solid.tolerances`) and
 * `option('tolerance.relative')` times the largest of their sizes, never finer than their
 * coordinates can represent. 0 for no solids, or solids with nothing to size by -- which a verb
 * refuses.
 */
function effectiveTolerance(...solids) {
  const handles = solids.map((s) => s._handle);
  const t = _lib().effective_tolerance(handles, handles.length);
  if (Number.isNaN(t)) _fail('effective_tolerance');
  return t;
}
/**
 * A kernel option's value, by its name: what `setOption` last set, else its default.
 * Throws for a name that is not an option, listing the ones there are.
 */
function option(name) {
  const out = new Float64Array(1);
  if (!_lib().option_get(String(name), out)) throw new BuildError(_lastError() || `no option '${name}'`);
  return out[0];
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

let _worker = null;
/**
 * A result nobody will hold: the worker finished a call whose progress
 * callback had thrown. A built solid crosses as `{ address }` (a BigInt koffi
 * accepts as the pointer); free it here rather than leak it.
 */
function _orphan(r) { if (r && typeof r.address === 'bigint') _lib().solid_free(r.address); }
function _run(message, transfer, onProgress) {
  if (_wasm()) return Promise.reject(new BuildError('the async verbs run the library in a worker thread, which the wasm build has none of: call the plain verb'));
  if (!_worker) _worker = require('./worker');
  return _worker.run('builder', message, transfer, onProgress, _orphan).catch((e) => { throw new BuildError(e.message); });
}

/**
 * The address to hand the worker for `pointer`: itself, if this handle is
 * already a BigInt address (a solid built by a previous async call), else
 * `koffi.address(pointer)`. `koffi.as()` cannot rebuild a real pointer from a
 * raw address -- it only tags an existing value for a call -- so an
 * async-built `Solid` simply keeps its `_pointer` as the BigInt the worker
 * returned; koffi accepts that directly wherever a pointer argument is due.
 */
function _addressOf(pointer) { return typeof pointer === 'bigint' ? pointer : koffi.address(pointer); }

// ---- profiles -------------------------------------------------------------------

const _profileFinalizer = typeof FinalizationRegistry === 'function'
  ? new FinalizationRegistry((h) => { try { _lib().profile_free(h); } catch (_) { /* exiting */ } }) : null;

/** A closed outline with holes, in its own x/y. Immutable; every method returns a new one. */
class Profile {
  constructor(handle) {
    this._handle = _checked(handle, 'profile');
    if (_profileFinalizer) _profileFinalizer.register(this, handle);
  }
  static rect(w, h) { return new Profile(_lib().profile_rect(w, h)); }
  static circle(r) { return new Profile(_lib().profile_circle(r)); }
  static slot([cx, cy], length, r) { return new Profile(_lib().profile_slot(cx, cy, length, r)); }
  static polygon(points) { const xy = _flatPairs(points); return new Profile(_lib().profile_polygon(xy, xy.length / 2)); }
  /** A regular polygon of `sides` sides (at least 3) on the circle of `radius` about `centre`, its first corner at `angle` radians. */
  static regularPolygon([cx, cy], radius, sides, angle = 0) {
    const n = _rtreeU32(sides, 'profile_regular_polygon', 'sides');
    return new Profile(_lib().profile_regular_polygon(cx, cy, radius, n, angle));
  }
  /**
   * A regular polygon of `sides` sides (at least 3) whose sides touch the circle of `radius` about
   * `centre` -- the polygon across flats, a nut's hex: its corners on the circle of
   * `radius / cos(pi / sides)`, each side's midpoint on the circle of `radius`, the first corner at
   * `angle` radians on the same ray as `regularPolygon`'s. `sides` is a whole number from 0 to
   * 4294967295, checked here; under 3 is the library's refusal.
   */
  static circumscribedPolygon([cx, cy], radius, sides, angle = 0) {
    const n = _rtreeU32(sides, 'profile_circumscribed_polygon', 'sides');
    return new Profile(_lib().profile_circumscribed_polygon(cx, cy, radius, n, angle));
  }
  /** A star of `points` tips (at least 3) on the circle of `outer` about `centre`, its inner corners on the circle of `inner` (positive, under `outer`), the first tip at `angle` radians. */
  static star([cx, cy], outer, inner, points, angle = 0) {
    const n = _rtreeU32(points, 'profile_star', 'points');
    return new Profile(_lib().profile_star(cx, cy, outer, inner, n, angle));
  }
  /**
   * A spline of `degree` through the control polygon `points` (`weights` one per point, or null):
   * open, from the first point to the last; `closed`, periodic and smooth through its own start.
   */
  static spline(points, degree = 3, weights = null, closed = false) {
    const xy = _flatPairs(points);
    const w = weights == null ? null : Float64Array.from(weights, Number);
    // The library reads exactly one weight per point, whatever the array holds.
    if (w && w.length !== xy.length / 2) {
      throw new BuildError(`spline: ${w.length} weights for ${xy.length / 2} points; give one per point`);
    }
    return new Profile(_lib().profile_spline(xy, xy.length / 2, Math.max(0, degree | 0), w, !!closed));
  }
  /** A polyline through `points` (at least two), open, or `closed` with a side back to the first. */
  static polyline(points, closed = false) {
    const xy = _flatPairs(points);
    return new Profile(_lib().profile_polyline(xy, xy.length / 2, !!closed));
  }
  /**
   * The arc of radius `r` about `centre` from angle `a0` counter-clockwise to `a1` (radians from the
   * sketch's x axis), one exact arc, open: `a1` is brought past `a0` when it is not. Equal angles are
   * the whole circle, closed, starting at `a0`. Throws for a radius not positive and finite.
   */
  static arc([cx, cy], r, a0, a1) { return new Profile(_lib().profile_arc(cx, cy, r, a0, a1)); }
  /** The arc from `start` through `through` to `end`, one exact arc, open. Throws when the three are in a line. */
  static arcThrough([x0, y0], [xm, ym], [x1, y1]) { return new Profile(_lib().profile_arc_through(x0, y0, xm, ym, x1, y1)); }
  /** The ellipse about `centre` with semi-axes `rx` along x and `ry` along y, closed: four exact quarter conics. */
  static ellipse([cx, cy], rx, ry) { return new Profile(_lib().profile_ellipse(cx, cy, rx, ry)); }
  /**
   * Rational cubic Béziers end to end -- sixteen numbers each, `x y z w` per control point, the
   * record `beziers()` hands back -- as one open profile. `recognise`: a straight Bézier becomes an
   * exact line and a circular one an exact arc; `false` keeps every Bézier as the exact cubic it is.
   */
  static fromBeziers(beziers, recognise = true) {
    const flat = Float64Array.from(Array.from(beziers).map(Number));
    if (flat.length % 16) throw new BuildError(`profile_from_beziers: ${flat.length} numbers are not whole Béziers of sixteen`);
    return new Profile(_lib().profile_from_beziers(flat, flat.length / 16, !!recognise));
  }
  /**
   * This profile as rational cubic Béziers, sixteen numbers each (`x y z w` per control point): the
   * outline from its start, then each hole's. On the sketch plane (z = 0), or with `frame` (twelve
   * numbers, a `Frame`) carried onto that frame's plane. A `Float64Array`.
   */
  beziers(frame = null) {
    const l = _lib();
    const out = new Float64Array(16 * l.profile_bezier_count(this._handle));
    if (!l.profile_beziers(this._handle, frame == null ? null : _frame(frame), out)) _fail('profile_beziers');
    return out;
  }
  /**
   * The closed loops among `pieces`, each read by its two ends, as a CAD sketch finds them: ends
   * meet within `tolerance`; a corner of three or more ends is ambiguous and no loop runs through it;
   * a piece whose own ends meet is a loop of its own. Each loop is its pieces' indices in the order it
   * runs, from its lowest. Throws for a piece with holes or nothing drawn.
   */
  static loops(pieces, tolerance = 1e-6) {
    const handles = Array.from(pieces, (p) => p._handle);
    const out = new Uint32Array(2 * handles.length);
    const l = _lib();
    if (!l.profile_loops(handles, handles.length, _tol(tolerance), out)) _fail('profile_loops');
    const found = [];
    // records `len, i, i, ...`, then zeros: a length of 0 ends the list
    for (let at = 0; at < out.length && out[at] > 0; at += 1 + out[at]) found.push(Array.from(out.subarray(at + 1, at + 1 + out[at])));
    return found;
  }
  /** The order `chain` takes `pieces` in: per piece `[index, turned]`, `turned` whether it was reversed to meet. Throws as `chain` does. */
  static chainOrder(pieces, tolerance = 1e-6) {
    const handles = Array.from(pieces, (p) => p._handle);
    const out = new Uint32Array(2 * handles.length);
    if (!_lib().profile_chain_order(handles, handles.length, _tol(tolerance), out)) _fail('profile_chain_order');
    return Array.from({ length: handles.length }, (_, i) => [out[2 * i], out[2 * i + 1] !== 0]);
  }
  static path(start) { return new Path(start); }
  /**
   * Start drawing on the arc of the parabola with `vertex`, axis direction `axis` and focal
   * length `focal`, over the across-axis coordinates `from..to`: the path begins at the arc's
   * first point and holds the arc -- a reflector from rim to rim, `Profile.parabola([0, 0], [0, 1], 20, -50, 50)`
   * a dish 100 wide opening up.
   */
  static parabola([vx, vy], [ax, ay], focal, from, to) {
    return Path._fromHandle(_checked(_lib().path_parabola(vx, vy, ax, ay, focal, from, to), 'path_parabola'));
  }
  /**
   * Open profiles joined end to end into one -- the forge's merge. The pieces may come in any
   * order and either way round: each next one is the first of the rest with an end within
   * `tolerance` of either end of the chain so far, reversed where that makes it meet. Every
   * segment is kept exactly. Closed where the chain's two ends meet, otherwise an open chain.
   */
  static chain(pieces, tolerance = 1e-6) {
    const handles = Array.from(pieces, (p) => p._handle);
    return new Profile(_lib().profile_chain(handles, handles.length, _tol(tolerance)));
  }
  /**
   * Closed loops, in any order, as one profile: the loop enclosing the most area is the boundary
   * and every other a hole in it, in the order given. Throws, naming loops by their index, for a
   * loop that is open, empty or of no area, loops that cross or touch, a hole outside the boundary
   * or inside another hole.
   */
  static fromLoops(loops) {
    const handles = Array.from(loops, (p) => p._handle);
    return new Profile(_lib().profile_from_loops(handles, handles.length));
  }
  /** This profile closed -- the forge's sketch "close": a straight segment from its end back to its start where it stops short. */
  closeLoop() { return new Profile(_lib().profile_close_loop(this._handle)); }
  /**
   * This curve cut where the `cutters` cross, touch or run along it -- the sketch trim's pieces:
   * in order along the curve from its start, each an open profile of portions of this one's own
   * segments (a line's stretch a line, an arc's an arc, a spline's the same spline over part of
   * its domain). One piece, this curve, where nothing cuts it; a closed curve's piece round its
   * start is one piece. Cuts closer than `tolerance` to each other fold onto one.
   */
  pieces(cutters, tolerance = 1e-6) {
    const handles = Array.from(cutters, (p) => p._handle);
    const n = _lib().profile_piece_count(this._handle, handles, handles.length, _tol(tolerance));
    if (n === 0) _fail('profile_piece_count');
    const found = [];
    for (let i = 0; i < n; i++) found.push(new Profile(_lib().profile_piece(this._handle, handles, handles.length, i, _tol(tolerance))));
    return found;
  }
  /**
   * This curve with piece `piece` of `pieces` taken away -- the sketch trim: what is left, as
   * open profiles. One for a closed curve (its other pieces run together from where the removed
   * one ended), the stretches before and after for an open one, none where the piece was the
   * whole curve. Throws for a piece the curve does not have.
   */
  trim(cutters, piece, tolerance = 1e-6) {
    const handles = Array.from(cutters, (p) => p._handle);
    const n = _lib().profile_trim_count(this._handle, handles, handles.length, piece, _tol(tolerance));
    if (n === 0 && _lastError()) _fail('profile_trim_count');
    const found = [];
    for (let i = 0; i < n; i++) found.push(new Profile(_lib().profile_trim_chain(this._handle, handles, handles.length, piece, i, _tol(tolerance))));
    return found;
  }
  withHole(hole) { return new Profile(_lib().profile_with_hole(this._handle, hole._handle)); }
  /**
   * The perimeter of the outer loop -- holes are not counted -- as
   * `{ length, error, accuracyMet, fromPolyline }`, its exact curves measured to the relative
   * `accuracy` (0 or less asks for the library's default). Throws for an accuracy that is NaN,
   * infinite or 1 or more.
   */
  length(accuracy = 0) {
    const out = {};
    if (!_lib().profile_length(this._handle, accuracy, out)) _fail('profile_length');
    return _lengthOf(out);
  }
  /**
   * The point `s` along the outer loop from its start, as `{ point, tangent, parameter, segment,
   * error, fromPolyline }`; `segment` is the side and `parameter` that side's own. `accuracy` is
   * relative; 0 or less asks for the default. Throws for an `s` outside the loop or an `accuracy`
   * that is not finite.
   */
  pointAtLength(s, accuracy = 0) {
    const out = {};
    if (!_lib().profile_point_at_length(this._handle, s, accuracy, out)) _fail('profile_point_at_length');
    return _atOf(out);
  }
  /** The outer loop in `n` pieces of equal arc length, as `At` records: `n` samples, a profile's outer loop being closed. */
  divideByCount(n, accuracy = 0) {
    _count(n, 'profile_divide_by_count');
    return _samples(_checked(_lib().profile_divide_by_count(this._handle, n, accuracy), 'profile_divide_by_count'), 'profile_divide_by_count');
  }
  /** The outer loop every `step` of arc length from its start, as `At` records; the short last piece is kept. */
  divideByLength(step, accuracy = 0) {
    return _samples(_checked(_lib().profile_divide_by_length(this._handle, step, accuracy), 'profile_divide_by_length'), 'profile_divide_by_length');
  }
  /**
   * The outline, then each hole, as `Float32Array`s of x, y, z at z = 0, within `tolerance` of the
   * profile's arcs and splines -- what a viewer draws it with. A closed loop repeats its first point
   * at the end; an open chain (a profile ended open) stays open, the segments it has. Copies.
   */
  polylines(tolerance = 0.05) {
    const p = _lib().profile_polylines(this._handle, _tol(tolerance));
    if (p.offsets == null) _fail('profile_polylines');
    const points = _floats(p.points, p.point_count * 3) ?? new Float32Array(0);
    const offsets = _uint32s(p.offsets, p.polyline_count + 1);
    const out = [];
    for (let i = 0; i < p.polyline_count; i++) out.push(points.slice(offsets[i] * 3, offsets[i + 1] * 3));
    return out;
  }
  /**
   * This profile with every free-form side (a Bezier, a conic, a NURBS) replaced by lines and
   * arcs within `tolerance` of it -- what a G-code writer can say. Lines and arcs pass through as
   * they are, every loop closes on itself exactly, holes are converted the same way. Throws
   * `BuildError` for a `tolerance` not positive and finite, or a spline that does not evaluate.
   */
  toArcs(tolerance = 0.01) { return new Profile(_lib().profile_to_arcs(this._handle, _tol(tolerance))); }
  /**
   * This profile grown by `distance` (shrunk where it is negative), as zero or more profiles, all
   * lines and arcs: outward corners rounded by `|distance|`, holes moving against the boundary (a
   * hole shrinks as the profile grows). Free-form sides are fitted to `tolerance` first
   * (`toArcs`). A shrink that eats the whole profile is an empty array. Throws `BuildError` for a
   * `distance` not finite, a `tolerance` not positive and finite, a loop with no sides, or loops
   * that cross or touch.
   */
  offset(distance, tolerance = 0.01) {
    return _profileList(_lib().profile_offset(this._handle, distance, _tol(tolerance)), 'profile_offset');
  }
  /**
   * Where this profile's curves cross, touch or run along `other`'s, both read in one plane, as
   * `Hit` values ordered along this profile. Points closer than `tolerance` merge; two curves
   * within `tolerance` of each other for longer than it are one run when they part only where one
   * ends or the stretch is flat -- one curve following the other, offset within `tolerance` or
   * tilted by under about half of it, even where it leaves mid-both; a tangency or a shallow
   * crossing is one point. A loop that stops short of its start is an open chain.
   */
  hits(other, tolerance = 1e-6) {
    const l = _lib();
    const h = _checked(l.profile_hits(this._handle, other._handle, _tol(tolerance)), 'profile_hits');
    try {
      const n = l.hit_count(h);
      const out = [];
      for (let i = 0; i < n; i++) {
        const raw = {};
        if (!l.hit(h, i, raw)) _fail('hit');
        out.push(_hitOf(raw));
      }
      return out;
    } finally {
      l.hits_free(h);
    }
  }
  /**
   * The region this profile and `other` share, both read in one plane, as zero or more profiles
   * -- each boundary counter-clockwise, each hole clockwise, arcs and splines kept exact. Both
   * must be closed and simple. No shared area is an empty array. Throws `BuildError` for a
   * `tolerance` not positive and finite, or a profile open or crossing itself.
   */
  common(other, tolerance = 1e-6) {
    return _profileList(_lib().profile_common(this._handle, other._handle, _tol(tolerance)), 'profile_common');
  }
  /**
   * `text` set in a font, one profile per closed shape -- a letter with its counters as
   * holes (`o` one, `8` two; `i` is two profiles) -- on the sketch plane, the baseline
   * along x from the origin, each outline counter-clockwise and its holes clockwise, a
   * curved side the font's own cubic Bezier kept exactly: an extruded `O` has curved
   * walls. `size` is roughly the height of a capital. `font` is a family, optionally
   * with a style (`'Liberation Sans:style=Bold'`), a font file's path, or empty for the
   * bundled Liberation Sans Regular -- which also serves when the family is not found;
   * `fontBytes` (a Uint8Array or Buffer) a font file's bytes, used instead of `font`
   * when given. `halign` is 'left', 'center' or 'right'; `valign` 'baseline', 'bottom',
   * 'center' or 'top'; `spacing` multiplies the gap between glyphs; `direction` 'ltr'
   * or 'rtl'. Empty text is an empty array. Throws `BuildError` for a size or spacing
   * not positive and finite, an alignment or direction not one of those words, font
   * bytes that are not a font.
   */
  static text(text, size = 10, font = '', halign = 'left', valign = 'baseline', spacing = 1, direction = 'ltr', fontBytes = null) {
    const bytes = fontBytes == null ? null : fontBytes instanceof Uint8Array ? fontBytes : new Uint8Array(fontBytes);
    return _profileList(_lib().profile_text(String(text), size, String(font), bytes, bytes == null ? 0 : bytes.length,
      String(halign), String(valign), spacing, String(direction)), 'profile_text');
  }
  translate(dx, dy) { return new Profile(_lib().translate_profile(this._handle, dx, dy)); }
  /** This outline turned `radians` (counter-clockwise) about `centre`. */
  rotate(centre, radians) {
    const [cx, cy] = _doubles(centre, 2, 'profile_rotate');
    return new Profile(_lib().profile_rotate(this._handle, cx, cy, Number(radians)));
  }
  /**
   * This outline scaled by `sx`, `sy` about `centre`: an arc stays an arc where the two are equal
   * in size, and becomes exact conics otherwise. A negative factor mirrors; a zero one is singular
   * and throws `BuildError`.
   */
  scale(centre, sx, sy) {
    const [cx, cy] = _doubles(centre, 2, 'profile_scale');
    return new Profile(_lib().profile_scale(this._handle, cx, cy, Number(sx), Number(sy)));
  }
  /** This outline reflected across the line through `point` along `direction`; a zero `direction` throws `BuildError`. */
  mirror(point, direction) {
    const [px, py] = _doubles(point, 2, 'profile_mirror');
    const [dx, dy] = _doubles(direction, 2, 'profile_mirror');
    return new Profile(_lib().profile_mirror(this._handle, px, py, dx, dy));
  }
  /** This outline under the 2D affine map `m`, six numbers row-major (2x3): `x' = m0 x + m1 y + m2`, `y' = m3 x + m4 y + m5`. A singular map throws `BuildError`. */
  transform2d(m) { return new Profile(_lib().profile_transform2d(this._handle, _doubles(m, 6, 'profile_transform2d'))); }
  /** This outline coloured -- `colour` is '#rgb', '#rrggbb', a CSS colour name or [r, g, b] in 0..1: how it is drawn.
   *  The verbs that make a profile from one carry it; a solid made from it takes nothing. */
  coloured(colour) {
    const [r, g, b] = _rgb(colour);
    return new Profile(_lib().profile_coloured(this._handle, r, g, b));
  }
  /** The outline's colour as [r, g, b] in 0..1, or null. */
  get colour() {
    const out = new Float64Array(3);
    if (_lib().profile_colour(this._handle, out)) return Array.from(out);
    if (_lastError()) _fail('profile_colour');
    return null;
  }
  /**
   * This profile as a `Document`'s `profile.path` node holds it, parsed: `{start, segments, holes,
   * colour}`, its exact segments (lines, arcs, Beziers, conics, NURBS) never flattened. What
   * `Document.addProfile` puts in a document.
   */
  documentPath() { return JSON.parse(_ownedText(_lib().document_profile_path(this._handle), 'document_profile_path')); }
  /**
   * Corners between two straight segments rounded by `radius`, with an exact tangent arc.
   * `corners` null rounds every one (the holes' too); otherwise it picks corners of the
   * boundary -- corner `k` is where segment `k` ends. `open` keeps an open chain's ends square.
   */
  round(radius, corners = null, open = false) {
    // A picked list, even an empty one, is a non-null array: null means every corner -- and
    // the empty case needs a different shape per backend, exactly as `Solid.edgesColoured`
    // explains: koffi turns a zero-length array's pointer into null, which would round EVERY
    // corner, while the wasm export reads the array's own length and so must be handed the
    // empty array itself, or it rounds corner 0.
    const which = corners == null ? null : _indices(corners, 'round', 'corners');
    const list = which == null ? null : which.length || _wasm() ? which : new Uint32Array(1);
    return new Profile(_lib().profile_round(this._handle, radius, list, which == null ? 0 : which.length, !!open));
  }
  /**
   * This profile's own loops as SVG text, from directly above by default -- a sketch lies
   * in z = 0, so its own plane already is the page, unlike a solid's `Solid.svgText`
   * (`view: 'iso'`), which has no plane of its own to prefer. The rest of `options` is
   * `svgOptionsDefaults()`'s.
   */
  svgText(options = {}) { return writeSvgText([this], { view: 'top', ...options }); }
  /** `svgText(options)` written to `filePath` by the library itself. */
  svg(filePath, options = {}) { writeSvg(filePath, [this], { view: 'top', ...options }); }
  /**
   * `svgText`, on the worker thread. `options` is validated and packed on the caller's
   * thread first (fail fast), same as `Solid.svgAsync`. A profile carries no busy lock of
   * its own -- immutable, freed only by the finalizer -- so this reaches the worker
   * directly through `_run` rather than through `Solid`'s per-call lock.
   */
  async svgAsync(options = {}) {
    const raw = _svgOptions({ view: 'top', ...options });
    return _run({ op: 'svg', profileHandles: [_addressOf(this._handle)], options: raw });
  }
}

const _pathFinalizer = typeof FinalizationRegistry === 'function'
  ? new FinalizationRegistry((h) => { try { _lib().path_free(h); } catch (_) { /* exiting */ } }) : null;

/** An outline drawn a segment at a time; `end()` closes it into a `Profile` and consumes the builder. */
class Path {
  constructor([x, y]) {
    this._handle = _checked(_lib().path_begin(x, y), 'path_begin');
    if (_pathFinalizer) _pathFinalizer.register(this, this._handle, this);
  }
  /** A path already begun elsewhere (`Profile.parabola`'s starter), taking over its handle. */
  static _fromHandle(handle) {
    const path = Object.create(Path.prototype);
    path._handle = handle;
    if (_pathFinalizer) _pathFinalizer.register(path, handle, path);
    return path;
  }
  _live() { if (!this._handle) throw new BuildError('path: already ended'); return this._handle; }
  _step(ok, what) { if (!ok) _fail(what); return this; }
  lineTo(x, y) { return this._step(_lib().path_line_to(this._live(), x, y), 'path_line_to'); }
  arcTo(x, y, [cx, cy], ccw = true) { return this._step(_lib().path_arc_to(this._live(), x, y, cx, cy, ccw), 'path_arc_to'); }
  bezierTo([c1x, c1y], [c2x, c2y], [x, y]) { return this._step(_lib().path_bezier_to(this._live(), c1x, c1y, c2x, c2y, x, y), 'path_bezier_to'); }
  /**
   * A conic arc to (`x`, `y`) through `control` with middle weight `weight`: under 1 an
   * elliptical arc, 1 a parabola, over 1 a hyperbola -- the rational quadratic Bezier, kept exact.
   */
  conicTo(x, y, [cx, cy], weight) { return this._step(_lib().path_conic_to(this._live(), x, y, cx, cy, weight), 'path_conic_to'); }
  /** A parabolic arc to (`x`, `y`) whose end tangents meet at `control`: `conicTo` with weight 1. */
  parabolaTo(x, y, control) { return this.conicTo(x, y, control, 1.0); }
  /** A hyperbolic arc to (`x`, `y`) through `control` with middle `weight` over 1. */
  hyperbolaTo(x, y, control, weight) {
    if (!(weight > 1.0)) throw new BuildError('hyperbola_to: the weight must be over 1 (1 is a parabola, under 1 an ellipse)');
    return this.conicTo(x, y, control, weight);
  }
  /**
   * The parabolic arc to (`x`, `y`) with `vertex`: its axis and focal length solved from the
   * two ends. Throws when no parabola with that vertex passes through both.
   */
  parabolaByVertex(x, y, [vx, vy]) { return this._step(_lib().path_parabola_by_vertex(this._live(), x, y, vx, vy), 'path_parabola_by_vertex'); }
  /**
   * The parabolic arc to (`x`, `y`) with `focus`: of the two through the ends, the one whose
   * vertex lies between the ends' projections, then the one whose arc cups the focus (the
   * focus between the arc and its chord), then the more symmetric; with the focus beyond
   * the chord that is the arch over the ends, not the shallow dish -- draw that one with
   * `Profile.parabola`.
   */
  parabolaByFocus(x, y, [fx, fy]) { return this._step(_lib().path_parabola_by_focus(this._live(), x, y, fx, fy), 'path_parabola_by_focus'); }
  /** `control`: every control point after the current one, the endpoint last; `weights`: one per control point including the current one, or null; `knots`: the full knot vector. */
  nurbsTo(control, knots, degree, weights = null) {
    const c = _flatPairs(control), k = Float64Array.from(knots, Number);
    const w = weights == null ? null : Float64Array.from(weights, Number);
    // The library reads one weight per control point plus the current point's.
    const n = c.length / 2;
    if (w && w.length !== n + 1) {
      throw new BuildError(`nurbs_to: ${w.length} weights for ${n + 1} control points ` +
        `(the current point and ${n} given); give one per point`);
    }
    return this._step(_lib().path_nurbs_to(this._live(), c, c.length / 2, w, k, k.length, degree), 'path_nurbs_to');
  }
  /** The path as it stands, unclosed: an open chain for `extrudeOpen`, `sweepOpen`, `loftOpen`. Consumes the builder. */
  endOpen() {
    const h = this._live(); this._handle = null;
    if (_pathFinalizer) _pathFinalizer.unregister(this);
    return new Profile(_lib().path_end_open(h));
  }
  end() {
    const h = this._live(); this._handle = null;
    if (_pathFinalizer) _pathFinalizer.unregister(this);
    return new Profile(_lib().path_end(h));
  }
}

const _sweepPathFinalizer = typeof FinalizationRegistry === 'function'
  ? new FinalizationRegistry((h) => { try { _lib().sweep_path_free(h); } catch (_) { /* exiting */ } }) : null;

/** A 3D path of lines and arcs a profile is swept along. Borrowed by `sweep`, so reusable; `close()` frees it. */
class SweepPath {
  constructor([x, y, z]) {
    this._handle = _checked(_lib().sweep_path_begin(x, y, z), 'sweep_path_begin');
    if (_sweepPathFinalizer) _sweepPathFinalizer.register(this, this._handle, this);
  }
  static at(point) { return new SweepPath(point); }
  /**
   * The path the 2D chain `curve` (usually `Path.endOpen()`) draws on `frame`: lines and arcs
   * as they are, a Bezier or spline fitted with tangent biarcs within `tolerance`. `open`
   * false closes the path back to its start along the side a profile leaves implicit.
   */
  static along(curve, frame, tolerance = 0.05, open = true) {
    const path = Object.create(SweepPath.prototype);
    path._handle = _checked(_lib().sweep_path_along(curve._handle, _frame(frame), _tol(tolerance), !!open), 'sweep_path_along');
    if (_sweepPathFinalizer) _sweepPathFinalizer.register(path, path._handle, path);
    return path;
  }
  _live() { if (!this._handle) throw new BuildError('sweep_path: closed'); return this._handle; }
  _step(ok, what) { if (!ok) _fail(what); return this; }
  lineTo([x, y, z]) { return this._step(_lib().sweep_path_line_to(this._live(), x, y, z), 'sweep_path_line_to'); }
  /** Turn `angle` radians (in `(0, 2pi]`) about the axis through `centre` along `axis`. */
  arc([cx, cy, cz], [ax, ay, az], angle) { return this._step(_lib().sweep_path_arc(this._live(), cx, cy, cz, ax, ay, az, angle), 'sweep_path_arc'); }
  close() {
    if (this._handle) {
      const h = this._handle; this._handle = null;
      if (_sweepPathFinalizer) _sweepPathFinalizer.unregister(this);
      _lib().sweep_path_free(h);
    }
  }
  [DISPOSE]() { this.close(); }
}

// ---- slants ---------------------------------------------------------------------

/**
 * A plane a sweep starts or ends on, read as a height over the sketch plane at
 * each point: `at + grad . p`. Flat (`grad` zero) for `extrude`'s own caps;
 * sloped for a mitre -- the mitred end of a sweep's straight piece, where it
 * meets the plane bisecting its corner with the next.
 */
class Slant {
  constructor(at, grad = [0, 0]) {
    const [gx, gy] = grad;
    this.at = Number(at);
    this.grad = Object.freeze([Number(gx), Number(gy)]);
    Object.freeze(this);
  }
  static flat(at) { return new Slant(at); }
  /**
   * The plane through `point` square to `normal`, read as heights over
   * `frame`. Throws `BuildError` when the plane holds the sweep direction
   * itself (`normal` square to `frame`'s z), so no height is on it.
   */
  static ofPlane(frame, point, normal) {
    const out = new Float64Array(3);
    if (!_lib().slant_of_plane(_frame(frame), _doubles(point, 3, 'point'), _doubles(normal, 3, 'normal'), out)) _fail('slant_of_plane');
    return new Slant(out[0], [out[1], out[2]]);
  }
  _raw() { return Float64Array.of(this.at, this.grad[0], this.grad[1]); }
}

/** A `Slant`, or a bare number treated as `Slant.flat(value)`. */
function _slant(value) { return value instanceof Slant ? value : Slant.flat(value); }

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

// ---- solids ---------------------------------------------------------------------

const _solidFinalizer = typeof FinalizationRegistry === 'function'
  ? new FinalizationRegistry((h) => { try { _lib().solid_free(h); } catch (_) { /* exiting */ } }) : null;

/** An exact B-rep solid (or open sheet). Immutable; every operation returns a new one. `close()` frees it. */
// A boolean's result with its flush faces merged when `merge`; the unmerged one closed. One verb
// to the caller: on a tracked result the merge's origins read back through the boolean's
// (`origins_through`), so they name the boolean's operands, not the faces between the two steps.
function _merged(solid, merge) {
  if (!merge) return solid;
  try {
    const merged = solid.mergeFlush();
    if (!solid.isTracked) return merged;
    try { return new Solid(_lib().origins_through(merged._handle, solid._handle)); } finally { merged.close(); }
  } finally { solid.close(); }
}

/**
 * What a verb did to its inputs' faces (or edges), read off the result's ids and origins alone
 * (`Solid.history`, `Solid.edgeHistory`). An input is named `[operand, id]`: the operand its
 * index in the inputs as passed (a boolean's target 0, its tool 1), the id its `faceId`. Every
 * list is in `[operand, id]` order, `generated` in id order; frozen, as are its lists:
 *
 * - `kept`: an input that became exactly one output, keeping its id -- `[[operand, id], outId]`;
 * - `modified`: an input split, merged or renumbered -- `[[operand, id], [outIds]]`, a split's
 *   first piece, which keeps the id, first;
 * - `generated`: the outputs with no origin (a fillet's round, the faces a split cuts);
 * - `deleted`: the inputs no output names (a cut tool's caps), `[operand, id]` each.
 */
class History {
  constructor(kept, modified, generated, deleted) {
    const deep = (v) => (Array.isArray(v) ? Object.freeze(v.map(deep)) : v);
    this.kept = deep(kept);
    this.modified = deep(modified);
    this.generated = deep(generated);
    this.deleted = deep(deleted);
    Object.freeze(this);
  }
  toString() {
    return `History(kept=${this.kept.length}, modified=${this.modified.length}, generated=${this.generated.length}, deleted=${this.deleted.length})`;
  }
}

/** The four lists of history handle `h` (the C handle, or the wasm shim's `_wasmHistory`), read through C's readers; the caller frees it. */
function _readHistory(l, h) {
  const operand = [0], id = [0], out = [0];
  const kept = [], modified = [], generated = [], deleted = [];
  for (let i = 0, n = l.history_kept_count(h); i < n; i++) {
    if (!l.history_kept_at(h, i, operand, id, out)) _fail('history_kept_at');
    kept.push([[Number(operand[0]), Number(id[0])], Number(out[0])]);
  }
  for (let i = 0, n = l.history_modified_count(h); i < n; i++) {
    if (!l.history_modified_at(h, i, operand, id)) _fail('history_modified_at');
    const m = l.history_modified_output_count(h, i);
    if (m === NONE) _fail('history_modified_output_count');
    const outs = [];
    for (let j = 0; j < m; j++) outs.push(Number(l.history_modified_output_at(h, i, j)));
    modified.push([[Number(operand[0]), Number(id[0])], outs]);
  }
  for (let i = 0, n = l.history_generated_count(h); i < n; i++) generated.push(Number(l.history_generated_at(h, i)));
  for (let i = 0, n = l.history_deleted_count(h); i < n; i++) {
    if (!l.history_deleted_at(h, i, operand, id)) _fail('history_deleted_at');
    deleted.push([Number(operand[0]), Number(id[0])]);
  }
  return new History(kept, modified, generated, deleted);
}

/** An id argument: a whole number from 0 to 2**53 - 1 (a `number`), or a `bigint` below 2**64. */
function _id(value, what) {
  const ok = typeof value === 'bigint' ? value >= 0n && value < (1n << 64n) : Number.isSafeInteger(value) && value >= 0;
  if (!ok) throw new BuildError(`${what}: ${String(value)} is not an id (a whole number from 0 to 2**64 - 1)`);
  return typeof value === 'bigint' ? value : BigInt(value);
}

/** A key or value argument: a string (koffi would otherwise send a number's text or refuse late). */
function _attributeText(text, what, kind) {
  if (typeof text !== 'string') throw new TypeError(`${what}: a ${kind} is a string, not ${text === null ? 'null' : typeof text}`);
  return text;
}

/** A read-only `Map` in the order given (key order): `set`, `delete` and `clear` throw. */
function _frozenMap(entries) {
  const map = new Map(entries);
  const refuse = () => { throw new TypeError('attributes are read-only'); };
  Object.defineProperties(map, { set: { value: refuse }, delete: { value: refuse }, clear: { value: refuse } });
  return Object.freeze(map);
}

/** The attributes C lists by count and `_at`, in key order, as a `_frozenMap`. */
function _attributeMap(count, keyAt, valueAt, ...args) {
  const out = [];
  for (let i = 0; i < count; i++) {
    const k = keyAt(...args, i), v = valueAt(...args, i);
    if (k == null || v == null) _fail('attributes');
    out.push([String(k), String(v)]);
  }
  return _frozenMap(out);
}

/** `withAttributes`' argument: a `Map`, an iterable of `[key, value]` pairs, or a plain object, sorted by key. */
function _attributeEntries(attributes, what) {
  if (attributes == null) throw new TypeError(`${what}: attributes are a Map, [key, value] pairs or an object`);
  const entries = attributes instanceof Map || typeof attributes[Symbol.iterator] === 'function'
    ? Array.from(attributes, (pair) => [pair[0], pair[1]]) : Object.entries(attributes);
  return entries.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
}

class Solid {
  constructor(handle) {
    this._pointer = _checked(handle, 'solid');
    this._inexactTrims = 0;
    this._sheetError = null;
    this._patchReport = null;
    /** Locked by an in-flight async call: the call's name, or null. */
    this._busy = null;
    if (_solidFinalizer) _solidFinalizer.register(this, handle, this);
  }
  get _handle() {
    if (!this._pointer) throw new BuildError('solid: closed');
    if (this._busy) throw new BuildError(`busy: ${this._busy} in progress`);
    return this._pointer;
  }
  get closed() { return this._pointer === null; }
  close() {
    if (this._pointer === null) return;
    if (this._busy) throw new BuildError(`busy: ${this._busy} in progress`);
    const h = this._pointer; this._pointer = null;
    if (_solidFinalizer) _solidFinalizer.unregister(this);
    _lib().solid_free(h);
  }
  [DISPOSE]() { this.close(); }
  /** Draw it with the view library in use: on the wgpu library, in the one shared window (returns at once); elsewhere, a still. Options as `ShowOptions`. */
  show(options = {}) { return require('./cadaclysm_view')._present(this, options, 'show'); }
  /** Orbit it until the window is closed; the camera it was left at, and the last pick. */
  view(options = {}) { return require('./cadaclysm_view')._present(this, options, 'view'); }
  // -- building
  static cuboid(x, y, z) { return new Solid(_lib().cuboid(x, y, z)); }
  static cylinder(r, h) { return new Solid(_lib().cylinder(r, h)); }
  static cone(r, h) { return new Solid(_lib().cone(r, h)); }
  static sphere(r) { return new Solid(_lib().sphere(r)); }
  static torus(major, minor) { return new Solid(_lib().torus(major, minor)); }
  static wedge(x, y, z, topX) { return new Solid(_lib().wedge(x, y, z, topX)); }
  /** A right pyramid of `sides` sides (at least 3): its base the regular polygon of circumradius `r` on z=0, its first corner on +x, its tip at (0, 0, `h`). */
  static pyramid(sides, r, h) { return new Solid(_lib().pyramid(Math.max(0, sides | 0), r, h)); }
  // -- sheets from curves: one face on one NURBS surface
  /**
   * The sheet lofted through the section curves `sections` (`NurbsCurve`s), `degree` across them
   * (lowered to fit); `loose` shapes it by them instead, through the first and last only;
   * `closed` makes it periodic across them, the last section back to the first.
   */
  static loftCurves(sections, degree = 3, loose = false, closed = false) {
    const list = _curveHandles(sections);
    return new Solid(_lib().loft_curves(list, list.length, _curveU32(degree, 'loft_curves: degree'), Boolean(loose), Boolean(closed)));
  }
  /**
   * `sections` swept along `rail`, each carried by the rail's frame from the rail point nearest its
   * centre and blended between: `frame` `'rmf'` rotation-minimising, `'fixed'` keeping `up` upright.
   * Fitted within `tolerance`; the sheet's `sheetError` says how close.
   */
  static sweepRail(rail, sections, frame = 'rmf', up = null, tolerance = 1e-3) {
    if (frame !== 'rmf' && frame !== 'fixed') throw new BuildError(`sweep_rail: frame is 'rmf' or 'fixed', not '${String(frame)}'`);
    const list = _curveHandles(sections);
    const err = new Float64Array(1);
    return _sheetWithError(_lib().sweep_rail(rail._handle, list, list.length, frame === 'rmf' ? 0 : 1, _curveVec3(up), _tol(tolerance), err), err);
  }
  /**
   * `sections` swept between two rails: each section's first end on `railA` and last on `railB`,
   * carried by the rotation and uniform scale that keep them there, the rails matched by arc
   * length. Fitted within `tolerance` (`sheetError`).
   */
  static sweepTwoRails(railA, railB, sections, tolerance = 1e-3) {
    const list = _curveHandles(sections);
    const err = new Float64Array(1);
    return _sheetWithError(_lib().sweep_two_rails(railA._handle, railB._handle, list, list.length, _tol(tolerance), err), err);
  }
  /**
   * The Coons sheet of 2, 3 or 4 boundary curves meeting end to end within `tolerance` (in order
   * round the boundary, each either way round): exact for non-rational boundaries, rational ones
   * fitted first (`sheetError`).
   */
  static edgeSurface(curves, tolerance = 1e-3) {
    const list = _curveHandles(curves);
    const err = new Float64Array(1);
    return _sheetWithError(_lib().edge_surface(list, list.length, _tol(tolerance), err), err);
  }
  /**
   * The Gordon sheet of a curve network: `uCurves` (in order across the other way) and `vCurves`,
   * every one of the first crossing every one of the second within `tolerance`. `sheetError` is the
   * largest distance from the sheet to the curves given.
   */
  static networkSurface(uCurves, vCurves, tolerance = 1e-3) {
    const u = _curveHandles(uCurves), v = _curveHandles(vCurves);
    const err = new Float64Array(1);
    return _sheetWithError(_lib().network_surface(u, u.length, v, v.length, _tol(tolerance), err), err);
  }
  /**
   * The rolling-ball fillet between `a`'s face `faceA` and `b`'s face `faceB` (their whole NURBS
   * surfaces): the ball on the side each face's normal points to (`flipA` / `flipB`: the other
   * side), of `radius`, or running linearly from `radius` to `radiusEnd` along the fillet. Returns
   * `[sheet, railA, railB]`: the fillet sheet (its `sheetError` set) and the contact curves on `a`
   * and `b` (`NurbsCurve`s the caller owns), to trim them back with `trimByCurve` and join with
   * `joinSheets`.
   */
  static filletSurfaces(a, b, radius, radiusEnd = null, flipA = false, flipB = false, tolerance = 1e-3, faceA = 0, faceB = 0) {
    const end = radiusEnd == null ? radius : radiusEnd;
    const ra = [null], rb = [null], err = new Float64Array(1);
    const h = _lib().fillet_surfaces(a._handle, _curveU32(faceA, 'fillet_surfaces: face_a'), b._handle, _curveU32(faceB, 'fillet_surfaces: face_b'),
      Number(radius), Number(end), Boolean(flipA), Boolean(flipB), _tol(tolerance), ra, rb, err);
    if (!h) _fail('fillet_surfaces');
    const railA = NurbsCurve._of(ra[0], 'fillet_surfaces'), railB = NurbsCurve._of(rb[0], 'fillet_surfaces');
    return [_sheetWithError(h, err), railA, railB];
  }
  /** A sheet spanning from `a`'s side to `b`'s, meeting each at G`level` (1 or 2); `bulge` scales how far it leaves each edge along its neighbour's tangent. */
  static blendSides(a, sideA, b, sideB, level = 2, bulge = 1, faceA = 0, faceB = 0) {
    return new Solid(_lib().blend_sides(a._handle, _curveU32(faceA, 'blend_sides: face_a'), _sheetSide(sideA), b._handle,
      _curveU32(faceB, 'blend_sides: face_b'), _sheetSide(sideB), _curveU32(level, 'blend_sides: level'), Number(bulge)));
  }
  /**
   * The sheet filling a hole of 3 or more sides: N four-sided NURBS faces round a central point,
   * G1 or G2 to each other. Each boundary, in order round the hole and either way round, is a
   * `NurbsCurve` (met at G0), a sheet's side `[sheet, side]` or `[sheet, side, level]` (level 0, 1
   * or 2; 2 by default), or an object `{ sheet, side, level = 2, face = 0, range = [0, 1] }`
   * (`range` the part of the side's parameter, backwards `[1, 0]`). A side is `'u0'`, `'u1'`,
   * `'v0'` or `'v1'`. The boundaries must meet end to end within `tolerance`; `bulge` scales how
   * far the patch leaves each neighbour along its tangent.
   *
   * Face `i` meets boundary `i`'s second half along its `'v0'` side and boundary `i + 1`'s first
   * half along its `'u1'`, so `continuity` measures each neighbour; the result's `patchReport`
   * holds the worst of them, measured the same way.
   */
  static nSidedPatch(boundaries, bulge = 1, tolerance = 0.01) {
    const rows = Array.from(boundaries, (b, i) => {
      if (b instanceof NurbsCurve) return { sheet: null, face: 0, side: 0, from: 0, to: 1, level: 0, curve: b._handle };
      let sheet, side, level = 2, face = 0, range = [0, 1];
      if (Array.isArray(b)) {
        if (b.length < 2 || b.length > 3) throw new BuildError(`n_sided_patch: boundary ${i} is [sheet, side] or [sheet, side, level]`);
        [sheet, side] = b;
        if (b.length === 3) level = b[2];
      } else if (b !== null && typeof b === 'object') {
        const unknown = Object.keys(b).filter((k) => !['sheet', 'side', 'level', 'face', 'range'].includes(k));
        if (unknown.length) throw new BuildError(`n_sided_patch: boundary ${i}: unknown keys ${JSON.stringify(unknown.sort())}`);
        ({ sheet, side } = b);
        if (b.level !== undefined) level = b.level;
        if (b.face !== undefined) face = b.face;
        if (b.range !== undefined) range = b.range;
      } else throw new BuildError(`n_sided_patch: boundary ${i} is a NurbsCurve, [sheet, side] or an object`);
      if (!(sheet instanceof Solid)) throw new BuildError(`n_sided_patch: boundary ${i}: sheet is a Solid`);
      return { sheet: sheet._handle, face: _curveU32(face, 'n_sided_patch: face'), side: _sheetSide(side), from: Number(range[0]),
        to: Number(range[1]), level: _curveU32(level, 'n_sided_patch: level'), curve: null };
    });
    const out = {};
    const solid = new Solid(_lib().n_sided_patch(rows, rows.length, Number(bulge), _tol(tolerance), out));
    solid._patchReport = new PatchReport(out);
    return solid;
  }
  /**
   * `sheets` joined into one body, their faces in order: `[solid, report]`, a `JoinReport` of what
   * was done. Every two naked edges whose ends and curves agree within `tolerance` (0: a rounding
   * of the body's size) are sewn into one -- a gap closed is kept as that edge's own tolerance --
   * the faces turned to agree, and a closed result turned to face out, a solid the booleans,
   * `mass` and the writers take. Edges with exact curves are compared to the tolerance however
   * coarsely each was sampled. At a tolerance above 0 a T-junction is sewn too: one sheet's edge
   * along part of another's is first cut where the other's corner lies on it.
   */
  static joinSheets(sheets, tolerance = 0) {
    const list = Array.from(sheets, (s) => s._handle);
    const report = {};
    const joined = new Solid(_lib().join_sheets(list, list.length, _tol(tolerance), report));
    return [joined, new JoinReport(report)];
  }
  static extrude(profile, frame, height) { return new Solid(_lib().extrude(profile._handle, _frame(frame), height)); }
  static extrudeOpen(profile, frame, height) { return new Solid(_lib().extrude_open(profile._handle, _frame(frame), height)); }
  static extrudeTapered(profile, frame, height, taper) { return new Solid(_lib().extrude_tapered(profile._handle, _frame(frame), height, taper)); }
  static extrudeOpenTapered(profile, frame, height, taper) { return new Solid(_lib().extrude_open_tapered(profile._handle, _frame(frame), height, taper)); }
  /**
   * `extrude` between two planes instead of two heights: `bottom` and `top`
   * are each a `Slant` (or a bare number, `Slant.flat(number)`). With both
   * flat this *is* `extrude`, bit for bit; with a slope it is the mitred end
   * of a sweep's straight piece. Throws where the top plane comes down to or
   * through the bottom across the profile.
   */
  static extrudeBetween(profile, frame, bottom, top) { return new Solid(_lib().extrude_between(profile._handle, _frame(frame), _slant(bottom)._raw(), _slant(top)._raw())); }
  /** `extrudeBetween` without the caps: an open sheet of walls, as `extrudeOpen` is to `extrude`. */
  static extrudeOpenBetween(profile, frame, bottom, top) { return new Solid(_lib().extrude_open_between(profile._handle, _frame(frame), _slant(bottom)._raw(), _slant(top)._raw())); }
  static loft(a, frameA, b, frameB) { return new Solid(_lib().loft(a._handle, _frame(frameA), b._handle, _frame(frameB))); }
  static loftOpen(a, frameA, b, frameB) { return new Solid(_lib().loft_open(a._handle, _frame(frameA), b._handle, _frame(frameB))); }
  /**
   * The solid smooth through every section -- `[profile, frame]` pairs, in order: each wall
   * interpolates its side across all the profiles (cubic through four or more, quadratic
   * through three, `loft` through two), capped by the first and the last.
   */
  static loftThrough(sections) { return Solid._loftedThrough(sections, 'loft_through'); }
  /** `loftThrough` without the caps: the sheet through the curves. */
  static loftThroughOpen(sections) { return Solid._loftedThrough(sections, 'loft_through_open'); }
  static _loftedThrough(sections, which) {
    const all = Array.from(sections);
    const handles = all.map(([p]) => p._handle);
    const frames = Float64Array.from(all.flatMap(([, f]) => Array.from(_frame(f))));
    return new Solid(_lib()[which](handles, frames, handles.length));
  }
  static revolve(profile, axis, angle) { return new Solid(_lib().revolve(profile._handle, _axis(axis), angle)); }
  static revolveOpen(profile, axis, angle) { return new Solid(_lib().revolve_open(profile._handle, _axis(axis), angle)); }
  /**
   * `profile` coiled about `axis` (a point and a direction): read as `revolve` reads it -- x the
   * distance from the axis, y along it -- and turned `turns` times while climbing `pitch` along
   * the axis each turn: a spring, a thread. The two ends are the profile itself, flat; from a
   * full turn up the pitch must be taller than the profile.
   */
  static coil(profile, axis, pitch, turns) { return new Solid(_lib().coil(profile._handle, _axis(axis), pitch, turns)); }
  /**
   * `profile`, drawn on `frame`, swung `angle` radians about the axis through the sketch points `a`
   * and `b` (`[x, y]` on the frame): the profile and its axis drawn together. The profile may lie on
   * either side of the axis and touch it, not cross it; the sweep starts where it is drawn.
   */
  static revolveInPlane(profile, frame, [ax, ay], [bx, by], angle) { return new Solid(_lib().revolve_in_plane(profile._handle, _frame(frame), Float64Array.of(ax, ay, bx, by), angle)); }
  /** `revolveInPlane` for a curve: its segments swung into a sheet. */
  static revolveOpenInPlane(profile, frame, [ax, ay], [bx, by], angle) { return new Solid(_lib().revolve_open_in_plane(profile._handle, _frame(frame), Float64Array.of(ax, ay, bx, by), angle)); }
  static sweep(profile, frame, sweepPath) { return new Solid(_lib().sweep(profile._handle, _frame(frame), sweepPath._live())); }
  static sweepOpen(profile, frame, sweepPath) { return new Solid(_lib().sweep_open(profile._handle, _frame(frame), sweepPath._live())); }
  /** A circle of `radius` swept along `sweepPath`, square to its start: a rod, or with a positive `thickness` a tube whose walls are that thick. */
  static pipe(sweepPath, radius, thickness = 0) { return new Solid(_lib().pipe(sweepPath._live(), radius, thickness)); }
  /** Thicken an open sheet into a solid. */
  extrudeFaces(height) { return new Solid(_lib().extrude_faces(this._handle, height)); }
  /** The flat sheet `profile` bounds on `frame`: one planar face, holes as holes, facing the frame's z. */
  static face(profile, frame) { return new Solid(_lib().face(profile._handle, _frame(frame))); }
  /** Face `face` alone, as an open sheet: its surface, loops and exact edge curves. */
  faceSheet(face) { return new Solid(_lib().face_sheet(this._handle, face)); }
  /** Without the faces at `faces`; the rest keep their order. */
  dropFaces(faces) {
    const which = _indices(faces, 'dropFaces', 'faces');
    return new Solid(_lib().drop_faces(this._handle, which, which.length));
  }
  /**
   * What is wrong with this solid, as a `HealthReport`: the free edges (the sides one face
   * bounds) and the wires they chain into, each with its nearest partner and the gap to it;
   * the features below `tolerance`; the loose edges; and what sewing would join and leave.
   * Nothing moves. `tolerance` is an absolute length, by default `1e-4` times the diagonal;
   * omitted, NaN, infinite, zero or negative takes the default, and the report shows what was
   * used. `mesh: true` also meshes the solid and reports where the mesh cracks (`cracks`);
   * without it `cracks` is null.
   */
  health({ tolerance, mesh = false } = {}) {
    const l = _lib();
    const solid = this._handle, tol = tolerance ?? NaN;
    if (_wasm()) {
      // one object of flat rows instead of a handle read through six accessors
      const r = l.health(solid, tol, Boolean(mesh));
      if (!r) _fail('health');
      return _healthReport(r.counts, r.sizes, r.freeEdgeIds, r.freeEdgeSizes, r.wireRuns, r.wireSizes, r.smallItems, r.smallSizes, r.crackEdges);
    }
    const h = _checked(l.health(solid, tol, Boolean(mesh)), 'health');
    try {
      const counts = new Uint32Array(18), sizes = new Float64Array(8);
      if (!l.health_summary(h, counts, sizes)) _fail('health');
      const rows = (read, a, b) => {
        const n = read(h, null, null);
        const x = new Uint32Array(a * n), y = new Float64Array(b * n);
        if (n) read(h, x, y);
        return [x, y];
      };
      const [freeIds, freeSizes] = rows(l.health_free_edges, 6, 2);
      const [wireRuns, wireSizes] = rows(l.health_wires, 3, 2);
      const [smallItems, smallSizes] = rows(l.health_small, 2, 1);
      const n = l.health_crack_edges(h, null);
      const cracks = new Uint32Array(n);
      if (n) l.health_crack_edges(h, cracks);
      return _healthReport(counts, sizes, freeIds, freeSizes, wireRuns, wireSizes, smallItems, smallSizes, cracks);
    } finally {
      l.health_free(h);
    }
  }
  /**
   * This solid with its small features removed, and what was done: `{ solid, report }`, the
   * solid a new one, the report a `HealReport`; this one is left as it was. It heals what
   * `health` lists as small at the same `tolerance` (omitted or `undefined` takes the default,
   * as `health`'s). `edges`, `faces` and `holes` (each true by default) switch each kind of
   * fix; a kind switched off is refused as `toggled`.
   */
  healed({ tolerance, edges = true, faces = true, holes = true } = {}) {
    const l = _lib();
    const solid = this._handle, tol = tolerance ?? NaN, flags = _healFlags({ edges, faces, holes });
    if (_wasm()) {
      // one object of flat rows with the healed solid's handle in it, instead of a report handle
      const r = l.healed(solid, tol, flags);
      if (!r) _fail('healed');
      const report = _healReport(r.counts, r.sizes, r.fixItems, r.fixSizes, r.refusedItems, r.refusedSizes);
      return { solid: new Solid(r.solid), report };
    }
    const h = _checked(l.healed(solid, tol, flags), 'healed');
    try {
      const counts = new Uint32Array(11), sizes = new Float64Array(2);
      if (!l.heal_summary(h, counts, sizes)) _fail('healed');
      let n = l.heal_fixes(h, null, null);
      const fixItems = new Uint32Array(2 * n), fixSizes = new Float64Array(2 * n);
      if (n) l.heal_fixes(h, fixItems, fixSizes);
      n = l.heal_refused(h, null, null);
      const refusedItems = new Uint32Array(3 * n), refusedSizes = new Float64Array(n);
      if (n) l.heal_refused(h, refusedItems, refusedSizes);
      const report = _healReport(counts, sizes, fixItems, fixSizes, refusedItems, refusedSizes);
      return { solid: new Solid(_checked(l.heal_body(h), 'healed')), report };
    } finally {
      l.heal_free(h);
    }
  }
  /**
   * How far brep edge `edge` (as a `HealFix` or `FreeEdge` names one) may lie off its curve:
   * 0 for an exact edge, the distance healing or sewing moved it where that is recorded, null
   * when no trim names the id (an edge healing removed).
   */
  edgeTolerance(edge) {
    const l = _lib();
    const t = l.edge_tolerance(this._handle, edge >>> 0);
    if (Number.isNaN(t) && _lastError()) _fail('edge_tolerance');
    return Number.isNaN(t) ? null : t;
  }
  /**
   * What this solid declares about its own precision, `{ absolute, angular }`: read from its
   * file, inherited through every verb from the loosest of its inputs, or set by
   * `withTolerances`; null in a field nothing declared. A verb given a null `tolerance` works at
   * `effectiveTolerance`, which takes it into account.
   */
  get tolerances() {
    const absolute = new Float64Array(1), angular = new Float64Array(1);
    if (!_lib().solid_tolerances(this._handle, absolute, angular)) _fail('solid_tolerances');
    const declared = (v) => (Number.isNaN(v) ? null : v);
    return Object.freeze({ absolute: declared(absolute[0]), angular: declared(angular[0]) });
  }
  /**
   * A new solid: this one declaring `absolute` (a length) and `angular` (radians) instead of
   * what it declared, its name, paint and marks kept. null or undefined (or 0) declares nothing
   * for that field; a negative or infinite value throws `BuildError`.
   */
  withTolerances(absolute = null, angular = null) {
    const unset = (v) => (v == null ? NaN : Number(v));
    return new Solid(_checked(_lib().solid_with_tolerances(this._handle, unset(absolute), unset(angular)), 'solid_with_tolerances'));
  }
  /**
   * How loose this solid's vertex at `point` is, where its producer said (an OCCT `.brep`
   * records one per vertex): the tolerance of the nearest recorded vertex within its own
   * tolerance of `point`. null where none is recorded there.
   */
  vertexTolerance(point) {
    const [x, y, z] = _doubles(point, 3, 'vertex_tolerance');
    const t = _lib().vertex_tolerance(this._handle, x, y, z);
    if (Number.isNaN(t) && _lastError()) _fail('vertex_tolerance');
    return Number.isNaN(t) ? null : t;
  }
  /**
   * Cut along the closed `tool` and keep one side: `keep` 'outside' (a hole punched
   * through) or 'inside' (the sheet cut to the tool's outline).
   */
  trim(tool, keep = 'outside', tolerance = 0.05, progress = null) {
    Solid._keep(keep);
    return new Solid(_lib().trim(this._handle, tool._handle, keep === 'inside', _tol(tolerance), _progress(progress), null));
  }
  static _keep(keep) { if (keep !== 'outside' && keep !== 'inside') throw new BuildError(`trim: keep must be 'outside' or 'inside', not '${keep}'`); }
  // -- moving
  place(frame) { return new Solid(_lib().place(this._handle, _frame(frame))); }
  /**
   * This solid cut by the plane `Z = z`: its closed outlines there, in XY, nested into profiles
   * with holes (boundaries counter-clockwise, holes clockwise), a line or a circle crossing kept
   * exact and any other curve as lines within `tolerance`. A plane that misses the solid is an
   * empty array. Throws `BuildError` for a `z` not finite, a `tolerance` not positive and finite,
   * a face lying in the plane (section a little above or below it), or a crossing that does not
   * close.
   */
  section(z, tolerance = 0.05) {
    return _profileList(_lib().solid_section(this._handle, z, _tol(tolerance)), 'solid_section');
  }
  translate(dx, dy, dz) { return new Solid(_lib().translate(this._handle, dx, dy, dz)); }
  /** This solid scaled by `factor` about the origin: every length times `factor`, exactly. */
  scaled(factor) { return new Solid(_lib().scaled(this._handle, factor)); }
  rotate(axis, radians) { return new Solid(_lib().rotate(this._handle, _axis(axis), radians)); }
  /** Mirror across a plane given as a frame (origin, x, y, z; the plane is spanned by x and y). */
  mirror(plane) { return new Solid(_lib().mirror(this._handle, _frame(plane))); }
  /**
   * This solid through the affine map `t` -- a `Transform`, or 16 numbers row-major (or four rows
   * of four) -- exact, its colours and name kept. A rigid map or a similarity keeps every surface's
   * kind; a map within 1e-6 of a similarity is applied as the exact similarity nearest it. Any
   * other map (a non-uniform scale, a shear) turns the curved surfaces into their exact NURBS and
   * maps those. The result's `inexactTrims` counts the trims this call lost. Throws `BuildError`
   * for a singular map (it flattens the solid), a non-finite one, or a non-affine one.
   */
  transform(t) {
    const lost = new Uint32Array(1);
    const out = new Solid(_lib().solid_transform(this._handle, _matrix(t, 'solid_transform'), lost));
    out._inexactTrims = lost[0];
    return out;
  }
  /**
   * This solid with its surfaces rewritten as their exact NURBS: `'procedural'` the revolutions,
   * extrusions and sums; `'analytic'` those and the cylinders, cones, spheres and tori; `'all'`
   * (the default) everything, planes and edge curves too. Colours and name kept; `inexactTrims`
   * counts the trims this call lost, as `transform`'s does.
   */
  convertToNurbs(level = 'all') {
    if (typeof level !== 'string' || !Object.prototype.hasOwnProperty.call(_NURBS_LEVELS, level)) {
      throw new BuildError(`convert_to_nurbs: level ${typeof level === 'string' ? `'${level}'` : String(level)} is not "procedural", "analytic" or "all"`);
    }
    const lost = new Uint32Array(1);
    const out = new Solid(_lib().solid_convert_to_nurbs(this._handle, _NURBS_LEVELS[level], lost));
    out._inexactTrims = lost[0];
    return out;
  }
  /**
   * On a solid from `transform` or `convertToNurbs`, the trims **that call** lost: face boundaries
   * kept only as a polyline lifted through the old surface. Per call, not the solid's history; 0
   * for a rigid map or a similarity, and on every other solid.
   */
  get inexactTrims() { return this._inexactTrims; }
  /** On a sheet from `sweepRail`, `sweepTwoRails`, `edgeSurface`, `networkSurface`, `filletSurfaces`, `flange` or `extrudeTo`, how far its fit is from what was asked (a distance); null on every other solid. */
  get sheetError() { return this._sheetError; }
  /** On the sheet from `nSidedPatch`, its `PatchReport`; null on every other solid. */
  get patchReport() { return this._patchReport; }
  /**
   * How well face `face`'s side `side` (`'u0'`, `'u1'`, `'v0'`, `'v1'`: a boundary isocurve of its
   * NURBS surface) meets `other`'s face `otherFace` along `otherSide`: a `Continuity`, the largest
   * gap, angle between the normals and difference of curvature across the edge, with where each is.
   */
  continuity(side, other, otherSide, face = 0, otherFace = 0, samples = 64) {
    const out = {};
    if (!_lib().continuity(this._handle, _curveU32(face, 'continuity: face'), _sheetSide(side), other._handle,
      _curveU32(otherFace, 'continuity: other_face'), _sheetSide(otherSide), _curveU32(samples, 'continuity: samples'), out)) _fail('continuity');
    return new Continuity(out);
  }
  /**
   * How well the two faces of edge `edge` (an `Edge` or its index) meet along it: `samples` points
   * along the edge, each projected onto both faces, and the largest gap, angle between the faces'
   * normals (a square crease reads pi/2) and difference of their normal curvatures across it --
   * `continuity`'s figures for any two faces of one body, of any kind of surface.
   */
  edgeContinuity(edge, samples = 64) {
    const e = edge instanceof Edge ? edge.index : edge;
    const out = {};
    if (!_lib().edge_continuity(this._handle, _curveU32(e, 'edge_continuity: edge'), _curveU32(samples, 'edge_continuity: samples'), out)) _fail('edge_continuity');
    return new Continuity(out);
  }
  /**
   * Face `face` faired, as a sheet of its own: the smoothest surface within `tolerance` of its
   * NURBS surface -- least squares plus its third derivatives squared (what a zebra's ripple
   * costs), weighed as heavily as the tolerance allows. A sheet lofted through traced sections
   * wobbles between them; this spends the tolerance on smoothness.
   *
   * `controls` null fairs on the face's own net, its degree raised to `degree` (3 to 7) and its
   * spans split to a dozen each way at least, so a kept side is kept exactly; `[nU, nV]` fairs on
   * a uniform net that size, its kept sides within the tolerance. `keep` says what each side keeps
   * -- one level for all four, or per side as an object by `u0`, `u1`, `v0`, `v1` or a 4-array in
   * that order: null free to move, 0 its position, 1 the tangent plane across it, 2 the curvature
   * too (what `matched` gave it with a neighbour). `noInflection` `'u'`, `'v'` or `'uv'` holds the
   * isocurves along those directions from turning their curvature over, which turns a roof lofted
   * through wobbly sections into a dome. Throws `BuildError` where no such fair is within the
   * tolerance. Its `sheetError` is the largest distance found between the two surfaces.
   */
  faired(tolerance = 1e-3, degree = 3, controls = null, keep = 2, noInflection = null, face = 0) {
    let levels;
    if (Array.isArray(keep)) {
      if (keep.length !== 4) throw new BuildError(`keep takes 4 levels (u0, u1, v0, v1), not ${keep.length}`);
      levels = keep;
    } else if (keep !== null && typeof keep === 'object') {
      const unknown = Object.keys(keep).filter((side) => !Object.hasOwn(_SHEET_SIDES, side)).sort();
      if (unknown.length) throw new BuildError(`a side is 'u0', 'u1', 'v0' or 'v1', not '${unknown[0]}'`);
      levels = ['u0', 'u1', 'v0', 'v1'].map((side) => (Object.hasOwn(keep, side) ? keep[side] : 2));
    } else {
      levels = [keep, keep, keep, keep];
    }
    const held = { u: 1, v: 2, uv: 3, vu: 3 };
    if (noInflection !== null && noInflection !== undefined && noInflection !== '' && !Object.hasOwn(held, noInflection)) {
      throw new BuildError(`no_inflection is 'u', 'v', 'uv' or null, not '${String(noInflection)}'`);
    }
    const [cu, cv] = controls === null || controls === undefined ? [0, 0] : controls;
    const arr = Int32Array.from(levels, (k) => (k === null || k === undefined ? -1 : k));
    const err = new Float64Array(1);
    return _sheetWithError(_lib().surface_faired(this._handle, _curveU32(face, 'surface_faired: face'), _tol(tolerance),
      _curveU32(degree, 'surface_faired: degree'), _curveU32(cu, 'surface_faired: controls'), _curveU32(cv, 'surface_faired: controls'),
      arr, held[noInflection] ?? 0, err), err);
  }
  /**
   * Where face `face`'s Gaussian and mean curvature change sign, on a grid of `samples` steps each
   * way over its surface (8 at fewest): how many separate areas of each sign, and the points
   * between opposite signs, as a `CurvatureTurns`. A dome or a saddle reads one area of one sign
   * and no turn; a sheet whose sections wobble reads several -- the surface's form of
   * `NurbsCurve.inflections`.
   */
  curvatureTurns(face = 0, samples = 32) {
    const f = _curveU32(face, 'curvature_turns: face'), n = _curveU32(samples, 'curvature_turns: samples');
    const out = {};
    if (!_lib().curvature_turns(this._handle, f, n, out)) _fail('curvature_turns');
    const points = (mean) => ((mean ? out.mean_turns : out.gaussian_turns)
      ? _samples(_checked(_lib().curvature_turn_points(this._handle, f, n, mean), 'curvature_turn_points'), 'curvature_turn_points') : []);
    return new CurvatureTurns(out, points(false), points(true));
  }
  /**
   * The worst kink of the highlight lines crossing edge `edge` (an `Edge` or its index), at
   * `samples` points along it (16 at fewest), as a `HighlightKink`: the lines of straight light
   * tubes parallel to the surface a body's size away, every tube direction tried. They run on
   * through an edge where the two faces' curvatures agree (G2) and kink where it jumps -- a
   * fillet's seam with a flat face among them. Beside `edgeContinuity`'s curvature jump, this is
   * the number a zebra shows.
   */
  highlightKink(edge, samples = 64) {
    const e = edge instanceof Edge ? edge.index : edge;
    const out = {};
    if (!_lib().highlight_kink(this._handle, _curveU32(e, 'highlight_kink: edge'), _curveU32(samples, 'highlight_kink: samples'), out)) _fail('highlight_kink');
    return new HighlightKink(out);
  }
  /** Face `face` as a sheet of its own, its side `side` bent to meet `other`'s `otherSide` at G`level`: 0 position, 1 tangent plane, 2 curvature. The opposite side stays where it was. */
  matched(side, other, otherSide, level = 2, face = 0, otherFace = 0) {
    return new Solid(_lib().match_side(this._handle, _curveU32(face, 'match_side: face'), _sheetSide(side), other._handle,
      _curveU32(otherFace, 'match_side: other_face'), _sheetSide(otherSide), _curveU32(level, 'match_side: level')));
  }
  /**
   * This sheet cut along `curve` -- one lying on it, say projected or pulled onto it -- and nothing
   * removed: every face comes back in its pieces outside the cutter, then its pieces inside, each
   * a face, as `splitSheet` orders them. The cutter is `curve` run along `direction` (null: the
   * mean of the sheet's normals along the curve) through the whole sheet. A closed curve's inside
   * is the island it bounds; an open curve's is the side left of its run, seen from where
   * `direction` points, and an open curve is run on straight past both ends, so it should cross the
   * sheet's boundary.
   */
  splitByCurve(curve, direction = null, tolerance = 0.05) {
    return new Solid(_lib().split_by_curve(this._handle, curve._handle, _curveVec3(direction), _tol(tolerance)));
  }
  /**
   * This sheet cut along `curve` and one side thrown away (see `splitByCurve`): `keep` `'inside'`
   * keeps the island a closed curve bounds, `'outside'` the sheet with the hole; for an open curve
   * `'left'` (the same as `'inside'`) keeps the side left of its run seen from where `direction`
   * points, `'right'` the other. Throws `BuildError` where nothing of the sheet lies on the kept side.
   */
  trimByCurve(curve, keep = 'outside', direction = null, tolerance = 0.05) {
    if (keep !== 'outside' && keep !== 'inside' && keep !== 'left' && keep !== 'right') {
      throw new BuildError(`trim_by_curve: keep must be 'outside', 'inside', 'left' or 'right', not '${String(keep)}'`);
    }
    return new Solid(_lib().trim_by_curve(this._handle, curve._handle, _curveVec3(direction), keep === 'inside' || keep === 'left', _tol(tolerance)));
  }
  /**
   * `section` swept along each of `edges` (naked edges of this sheet: `Edge` objects or their
   * indices) on the face's own frame: at every point of the edge the section's `x` runs outward
   * from the face -- square to the edge, in the face's tangent plane -- and its `y` along the face's
   * normal, so a section from `(0, 0)` to `(0, -10)` turns the edge under by 10 all along it however
   * the panel curves, `(0, 0)` to `(10, 0)` carries the face on, and a lip stands proud with `y > 0`.
   * `section` is a `NurbsCurve` in the plane `z = 0` starting at the origin. With `join` the sweeps
   * come back sewn to this sheet (its faces first, then one per edge), else alone, sewn to each
   * other. Each sweep is fitted within `tolerance`; `sheetError` says how close. Throws
   * `BuildError` for an edge bordered by two faces, a section not starting at the origin, and
   * sweeps that did not sew on.
   */
  flange(edges, section, tolerance = 1e-3, join = true) {
    const which = _indices(edges, 'flange', 'edges', true);
    const err = new Float64Array(1);
    return _sheetWithError(_lib().flange(this._handle, which, which.length, section._handle, _tol(tolerance), Boolean(join), err), err);
  }
  /**
   * Each of `edges` (naked edges of this sheet: `Edge` objects or their indices) slid along
   * `direction` until it meets `target`: every point of the edge travels along the direction to its
   * first hit on `target`'s faces (trimmed, not their whole surfaces). One wall per edge -- the
   * edge's own curve swept straight, bounded by the curve through the hits, fitted within
   * `tolerance` of every hit (`sheetError`) -- so a wheel arch cut in a panel runs in to the well's
   * inner wall as its liner. With `join` the walls come back sewn to this sheet (its faces first,
   * then one per edge), else alone, sewn to each other. Throws `BuildError` naming the point whose
   * line misses the target.
   */
  extrudeTo(edges, direction, target, tolerance = 1e-3, join = true) {
    const which = _indices(edges, 'extrude_to', 'edges', true);
    const err = new Float64Array(1);
    return _sheetWithError(_lib().extrude_to(this._handle, which, which.length, _curveVec3(direction), target._handle,
      _tol(tolerance), Boolean(join), err), err);
  }
  /**
   * This sheet cut along `curve`, a curve lying on it (within ten times `tolerance`), with no
   * direction: the cut is made in each face's own parameters, so it follows the curve however far
   * the sheet rolls, and runs across the seams of a joined sheet. An open curve is carried on along
   * the sheet past both ends to its boundary; a closed one cuts out the island it bounds. Nothing
   * is removed. Where the cut lies on the curve the rim is one edge carrying the curve's own span
   * exactly. Refused where the curve leaves the sheet.
   */
  splitAlongCurve(curve, tolerance = 0.01) {
    return new Solid(_lib().split_along_curve(this._handle, curve._handle, _tol(tolerance)));
  }
  /**
   * This sheet parted along `curve` (lying on it, as for split_along_curve) into two panels with a
   * shut line between them: each trimmed back `gap / 2` from the curve along the sheet, with a
   * flange `flange` along the faces' outward normals on its cut edge only (negative turns it under;
   * 0 for none), ending square where the curve runs off the sheet. The panel left of the curve's
   * run (seen from the outward side) first, then the right one; a loop run counter-clockwise from
   * that side has the island on its left. Refused where the curve leaves the sheet or the gap
   * leaves nothing of a panel. Returns `[left, right]`.
   */
  panelGap(curve, gap = 4, flange = -10, tolerance = 0.01) {
    const out = [null, null];
    if (!_lib().panel_gap(this._handle, curve._handle, Number(gap), Number(flange), _tol(tolerance), out)) _fail('panel_gap');
    return [new Solid(out[0]), new Solid(out[1])];
  }
  /**
   * This sheet with an opening recessed into it along `outline` -- a window, a lamp, a grille or
   * an air intake set into a panel: `[solid, [sheet, fillet, walls, pane]]`, how many of the
   * result's faces are each part's, the faces in that order.
   *
   * `outline` is a closed curve on the sheet (one face or several joined); each of its points is
   * found on the sheet, so it may stand a little off it. The walls run back `depth` along the
   * sheet's own normal at every point of the rim -- not along one view -- behind the face
   * (against its normal; negative: in front), leaning in toward the opening by `draft` radians
   * (negative: out) and meeting on the mitre at the outline's corners. `fillet` above 0 rounds
   * the rim between the sheet and the walls (the outline must then be smooth). `pane` closes the
   * back with one patch whose four sides end where the outline turns most, so it does not twist.
   * Every piece is sewn to the next: only the sheet's own boundary is left naked, and the walls'
   * foot without a pane. Throws `BuildError` for an outline that is not closed, a corner with a
   * fillet, or a fillet deeper than the walls.
   */
  recess(outline, depth, draft = 0, fillet = 0, pane = true, tolerance = 0.05) {
    const faces = new Uint32Array(4);
    const out = new Solid(_lib().recess(this._handle, outline._handle, Number(depth), Number(draft), Number(fillet), Boolean(pane), _tol(tolerance), faces));
    return [out, [faces[0], faces[1], faces[2], faces[3]]];
  }
  /**
   * This half and its reflection across `plane` (a frame, its z the plane's normal) joined into
   * one symmetric body -- half a car, a hull or a bottle modelled once -- the half's faces first:
   * `[solid, report]`, a `SymmetryReport` of how well the seam on the plane meets.
   *
   * With `snap` above 0, every NURBS face that is its whole surface and has a side whose control
   * points all lie within `snap` of the plane is squared to it first: that side pulled onto the
   * plane, the next row of control points stood straight off it along the normal (keeping its
   * distance from the plane). The surface then crosses the plane at 90 degrees, so it meets its
   * mirror tangent and curvature continuous; nothing past that row moves. `snap` 0 mirrors the
   * half as it is, a crease wherever it leans. The halves are sewn within `tolerance` (0: a
   * rounding of the body's size). Throws `BuildError` for a half on both sides of the plane, no
   * edge of it on the plane, or a face that cannot be squared (its next row on the plane or past
   * it).
   */
  mirrorJoin(plane, snap = 0, tolerance = 0) {
    const report = new Float64Array(7);
    const out = new Solid(_lib().mirror_join(this._handle, _frame(plane), Number(snap), _tol(tolerance), report));
    return [out, new SymmetryReport(report)];
  }
  // -- holes, ribs and webs, patterns
  /**
   * This body and its copies at `transforms` (rigid `Transform`s or 16 numbers each, typically
   * from `Pattern`; instance 0 the identity keeps the original) as one body -- a pattern of
   * bodies: `[solid, report]`, a `PatternReport`. Copies apart from each other are put together
   * with no boolean at all; copies that overlap are joined, one boolean a group. Throws
   * `BuildError` for no transforms or one that is not rigid.
   */
  pattern(transforms, tolerance = null) {
    const [flat, n] = _transforms(transforms, 'pattern');
    const report = new Float64Array(3);
    const out = new Solid(_lib().pattern(this._handle, flat, n, _tol(tolerance), report));
    return [out, new PatternReport(report)];
  }
  /**
   * `tool` (any closed solid, typically a `...Tool` method's result) placed at each of
   * `transforms` and applied to this body by `op`, `'cut'` or `'join'` -- a pattern of features
   * (Fusion's compute type *identical*): `[solid, report]`. Copies apart from each other go into
   * one multi-lump tool and one boolean; overlapping copies fall into a few groups. A copy that
   * shares no volume with the body is `missed`: dropped for a cut, kept as a body of its own for
   * a join. Throws `BuildError` for an unknown `op`, no transforms, one not rigid, or a tool that
   * is not closed.
   */
  patternFeature(tool, op, transforms, tolerance = null) {
    const code = _featureChoice(_FEATURE_OPS, op, 'pattern_feature', 'op');
    const [flat, n] = _transforms(transforms, 'pattern_feature');
    const report = new Float64Array(3);
    const out = new Solid(_lib().pattern_feature(this._handle, tool._handle, code, flat, n, _tol(tolerance), report));
    return [out, new PatternReport(report)];
  }
  /**
   * This body drilled at `points` (one point, or several: one hole each, all one spec, one cut)
   * -- the bore an exact cylinder of `diameter`, a counterbore an exact cylinder, a countersink
   * and a drill point exact cones: `[solid, report]`, a `HoleReport`.
   *
   * Options: `direction`, the drilling direction into the material shared by every point (null:
   * each point along the inward normal of the face it lies on; on an edge, the lowest-numbered
   * face's). `extent`: `'through'` everything ahead of the point; `'blind'`, `depth` of full bore
   * then a drill point of included angle `tipAngle` (0 or pi: a flat bottom); `'to_face'`, until
   * the axis first meets face `face`, the bore ending on it; `'to_next'`, until the bore first
   * leaves the material. `head`: null, or `'counterbore'` (`headDiameter` across, `headDepth`
   * deep) or `'countersink'` (`headDiameter` across at the point, included angle `headAngle`),
   * measured from the point. Angles in radians. Throws `BuildError` for an unknown `extent` or
   * `head`, a diameter not positive, a depth or face its extent does not take, a head not wider
   * than the bore, an angle out of range, a point not on a face with no direction, a hole that
   * removes nothing, or a face the axis never meets.
   */
  hole(points, diameter, options = {}) {
    const args = _holeArgs(this, 'hole', points, diameter, options);
    const n = args[2];
    const report = new Float64Array(2), bottoms = new Float64Array(Math.max(n, 1));
    const out = new Solid(_lib().hole(...args, report, bottoms));
    return [out, new HoleReport(report, bottoms.subarray(0, n))];
  }
  /** The tool `hole` cuts with, from the same arguments: a closed solid, one lump a point -- for `patternFeature` or a boolean of your own. */
  holeTool(points, diameter, options = {}) {
    return new Solid(_lib().hole_tool(..._holeArgs(this, 'hole_tool', points, diameter, options)));
  }
  /**
   * This body with a rib along `curve`, an open curve lying in `plane` (a frame): the region of
   * the plane between the curve and the body on the `toward` side (a direction in the plane;
   * null: toward the body's nearest point), the curve's ends carried on along their tangents to
   * the body, thickened `thickness` along the plane's normal -- `side` `'both'` (half each side),
   * `'front'` (+z) or `'back'` (-z) -- and joined. Throws `BuildError` for an unknown `side`, a
   * curve closed or not in the plane, a thickness not positive, a slab that meets nothing, or a
   * region not closed by the body.
   */
  rib(curve, plane, thickness, { side = 'both', toward = null, tolerance = null } = {}) {
    const code = _featureChoice(_RIB_SIDES, side, 'rib', 'side');
    return new Solid(_lib().rib(this._handle, curve._handle, _frame(plane), Number(thickness), code, _curveVec3(toward), _tol(tolerance)));
  }
  /** The slab `rib` joins, alone, from the same arguments. */
  ribTool(curve, plane, thickness, { side = 'both', toward = null, tolerance = null } = {}) {
    const code = _featureChoice(_RIB_SIDES, side, 'rib_tool', 'side');
    return new Solid(_lib().rib_tool(this._handle, curve._handle, _frame(plane), Number(thickness), code, _curveVec3(toward), _tol(tolerance)));
  }
  /**
   * This body with a web along each of `curves` (one open `NurbsCurve` or several, in `plane`):
   * each offset in the plane to `thickness` -- `side` `'both'`, `'left'` or `'right'` of the
   * curve's run, the plane's normal up -- its ends carried along their tangents to the body, its
   * walls run along the plane's normal until they meet the body (`depth` null) or for `depth`,
   * one way (the normal's) or both when `bothWays`. All the webs are one tool and one join;
   * crossing curves make a network. Throws `BuildError` for an unknown `side`, no curves, one
   * closed or not in the plane, a thickness not positive, or walls that meet nothing or are not
   * closed by the body.
   */
  web(curves, plane, thickness, { side = 'both', depth = null, bothWays = false, tolerance = null } = {}) {
    const code = _featureChoice(_WEB_SIDES, side, 'web', 'side');
    const list = _curveHandles(curves instanceof NurbsCurve ? [curves] : curves);
    return new Solid(_lib().web(this._handle, list, list.length, _frame(plane), Number(thickness), code,
      depth == null ? NaN : Number(depth), Boolean(bothWays), _tol(tolerance)));
  }
  /** The walls `web` joins, alone, from the same arguments. */
  webTool(curves, plane, thickness, { side = 'both', depth = null, bothWays = false, tolerance = null } = {}) {
    const code = _featureChoice(_WEB_SIDES, side, 'web_tool', 'side');
    const list = _curveHandles(curves instanceof NurbsCurve ? [curves] : curves);
    return new Solid(_lib().web_tool(this._handle, list, list.length, _frame(plane), Number(thickness), code,
      depth == null ? NaN : Number(depth), Boolean(bothWays), _tol(tolerance)));
  }
  // -- combining
  /** This solid and `other` as one; `merge` merges the flush faces the join leaves (`mergeFlush`), off by default. */
  join(other, tolerance = 0.05, progress = null, merge = false) { return _merged(new Solid(_lib().join(this._handle, other._handle, _tol(tolerance), _progress(progress), null)), merge); }
  cut(other, tolerance = 0.05, progress = null, merge = false) { return _merged(new Solid(_lib().cut(this._handle, other._handle, _tol(tolerance), _progress(progress), null)), merge); }
  common(other, tolerance = 0.05, progress = null, merge = false) { return _merged(new Solid(_lib().common(this._handle, other._handle, _tol(tolerance), _progress(progress), null)), merge); }
  /**
   * This solid or sheet cut along `tool`'s boundary with nothing removed:
   * every face comes back as its pieces outside `tool` and then its pieces
   * inside, in this solid's own face order -- where a surface trim starts.
   * `tool` must be a closed solid.
   */
  splitSheet(tool, tolerance = 0.05, progress = null) { return new Solid(_lib().split_sheet(this._handle, tool._handle, _tol(tolerance), _progress(progress), null)); }
  /**
   * This solid and `other` as one body that keeps every piece -- a union that keeps the inside
   * pieces: its regions are this solid less `other`, the two together, and `other` less this one
   * (those that are not empty), the walls between them faces of both. The body is non-manifold
   * where a wall meets the outside, so the verbs that need a manifold solid (the booleans, fillet,
   * chamfer, shell, thicken, the mass) refuse it; take its cells with `regions` and `regionSolid`.
   * Built exactly: both solids closed, every face a plane, cylinder, cone, sphere or torus.
   */
  merge(other, tolerance = 0.05, progress = null) { return new Solid(_lib().merge(this._handle, other._handle, _tol(tolerance), _progress(progress), null)); }
  /**
   * The regions of space this solid's faces bound, region 0 the infinite one, as plain
   * `{ index, finite, box, sides, shells }` objects: two for an ordinary solid (outside, inside),
   * one per cell for a merge's body, one more per cavity. `sides` lists `{ face, sense }`, sense +1
   * where the region is the side the face's normal points to and -1 the other, ascending by face
   * then sense; `shells` is 1 plus one per void inside it.
   */
  regions() { return _regions(_lib().regions(this._handle)); }
  /**
   * Finite region `region` (an index into `regions()`) as a closed solid of its own: the faces
   * bounding it, each turned to point out of it, each keeping its colour. `region` is a whole
   * number from 0 to 4294967295, checked here; region 0 (the infinite one) or one past the count
   * is the library's refusal.
   */
  regionSolid(region) {
    const h = this._handle;
    const i = _rtreeU32(region, 'region_solid', 'region');
    return new Solid(_lib().region_solid(h, i));
  }
  /**
   * Where this solid's faces cross or coincide with `other`'s, at `tolerance`, as an
   * `Intersection`: `chains` along the curves the faces meet on and `overlaps` where a
   * face pair coincides. Neither solid is changed; either may be an open sheet. No
   * crossing is an empty result, never an error.
   *
   * Each `Chain`'s points are within `tolerance` of both faces' exact surfaces; there is
   * one chain per face pair per branch -- chains are not joined across a face boundary or
   * a closed curve's seam, so join them by matching ends. A chain's `curve` is its exact
   * curve where the kernel found one every point lies within `tolerance` of, else null;
   * `tangent` is set where the surfaces are near-tangent along the chain or the snap did
   * not settle (the points are then the best estimate) -- a closed chain that does not go
   * once round its own curve (a sliver where two surfaces barely cross) has no curve,
   * `tangent` still true. An `Overlap` is a coincident face pair with the shared region's
   * rings (outer first, holes after), which may be empty for a partial overlap of curved faces whose
   * outlines cross. Known limit: a crossing narrower than `tolerance` -- two surfaces
   * passing within it without their meshes crossing -- can be missed; near-tangent
   * contact is where this bites.
   *
   * `progress(phase, done, total)` hears `meet` on the exact route; `mesh`, `cull`,
   * `cross`, `snap` and `curve` where it falls back to the mesh route.
   * Throws `BuildError` for a `tolerance` not positive and finite, a solid with no faces,
   * or one that meshes to nothing.
   */
  intersect(other, tolerance = 0.05, progress = null) {
    const l = _lib();
    return _intersectionOf(l, _checked(l.intersect(this._handle, other._handle, _tol(tolerance), _progress(progress), null), 'intersect'));
  }
  /**
   * Where this solid passes through itself, at `tolerance`, as an `Intersection` --
   * `intersect`'s result with this solid on both sides, so each `Chain` and `Overlap` names
   * two faces of this solid. Never along its own topology: faces meeting at their shared
   * edges and vertices are not a crossing, so a clean solid is an empty result, never an
   * error. A chain whose two faces are one face is that face folding through itself, and
   * has no `curve`. The solid is not changed; it may be an open sheet.
   *
   * The solid is meshed once and crossed against itself, the exact face-pair engine
   * refining each crossing of two faces, so the mesh route's known limit holds: a crossing
   * narrower than `tolerance` -- two faces passing within it without their meshes crossing
   * -- can be missed.
   *
   * `progress(phase, done, total)` hears `mesh`, `cull`, `cross`, `snap` and `curve`.
   * Throws `BuildError` for a `tolerance` not positive and finite, a solid with no faces,
   * or one that meshes to nothing.
   */
  selfIntersections(tolerance = 0.05, progress = null) {
    const l = _lib();
    return _intersectionOf(l, _checked(l.self_intersect(this._handle, _tol(tolerance), _progress(progress), null), 'self_intersect'));
  }
  /**
   * What is wrong with this solid (and `other`, if given) as the arguments of `operation`, at
   * `tolerance`, as an array of `Finding` -- OCCT's `BRepAlgoAPI_Check`, gathered from what the
   * kernel already measures. An empty array is a valid pair; nothing is changed.
   *
   * Each argument is checked alone whatever the operation: no faces (`no_faces`), features
   * smaller than `tolerance` as `health` finds them (`short_edge`, `collapsed_edge`,
   * `sliver_face`, `tiny_face`, `tiny_body`, `small_hole`), shared edges whose sides part
   * (`loose_edge`), and where it passes through itself as `selfIntersections` finds it
   * (`self_intersection`, `self_overlap`, or `unmeshable` where it could not be meshed to
   * look). `operation` -- `'join'`, `'cut'`, `'common'`, `'split_sheet'`, `'trim'`, `'merge'`
   * or `'intersect'` -- adds what that verb refuses each argument for: a boolean wants both
   * closed (`open`, one finding per free edge) and holding no region wall (`region_wall`, a
   * merge's body); a split or trim only its tool (`other`) closed; a merge closed manifolds
   * (`non_manifold`) of planes, cylinders, cones, spheres and tori (`face_kind`, per face).
   * Without `other`, this solid is held to what the operation asks of its first argument. A
   * free edge is no fault without an operation that asks for a closed solid: an open sheet is
   * a fine body.
   *
   * Not checked: an edge's curve leaving its face's surface, a surface only C0 inside a face,
   * sub-shapes a boolean would merge.
   *
   * `progress(phase, done, total)` hears `health`, then `mesh`, `cull`, `cross`, `snap` and
   * `curve`. Throws `BuildError` for an unknown operation or a `tolerance` not positive and
   * finite.
   */
  check(other = null, operation = null, tolerance = 0.05, progress = null) {
    const l = _lib();
    const op = operation == null ? null : String(operation);
    const h = _checked(l.check(this._handle, other == null ? null : other._handle, op, _tol(tolerance), _progress(progress), null), 'check');
    try {
      const out = [];
      const n = l.check_count(h);
      for (let i = 0; i < n; i++) {
        const raw = {};
        if (!l.check_finding(h, i, raw)) _fail('check_finding');
        out.push(new Finding(String(raw.kind), Number(raw.argument), raw.index === NONE ? null : Number(raw.index),
          raw.other === NONE ? null : Number(raw.other), Number(raw.size)));
      }
      return out;
    } finally {
      l.check_free(h);
    }
  }
  /**
   * Where `profile`, placed on `frame`, pierces this solid's faces, and the pieces its loops cut
   * into, as a `SolidHits`. Neither is changed.
   *
   * A point hit lies within `tolerance` of the segment's exact curve and of the face's exact
   * surface, inside the face's trim; its profile spot (`aStart`: loop, segment, t) and face spot
   * (`bStart`: face, u, v) evaluate to the point within `tolerance`; `touch` where the curve's
   * tangent lies within 1e-3 (sine) of the surface's tangent plane there (a graze), false at a
   * crossing. A run is a stretch of one segment lying within `tolerance` of one face and inside
   * it, longer than `tolerance`. Hits within `tolerance` of each other merge (a hit at a segment
   * join reported once, as `(k, t = 1)`; a closed loop's closing join reads `(0, 0)`).
   * Every point is in world space (the frame applied).
   *
   * Pieces only for a closed body -- an open body has none -- in loop order, covering every loop
   * exactly; a piece's spots read a segment join as the next segment's start `(k + 1, 0)`, and an
   * open chain runs from `(0, 0)` to `(n - 1, 1)`; a loop no hit cuts is one closed piece.
   * `inside` by the piece middle's winding number over the body's mesh; a piece lying on the
   * surface is inside. Known limit: a segment passing within `tolerance` of a face without
   * crossing its mesh can be missed (near-tangent grazes).
   *
   * `progress(phase, done, total)` hears `mesh`, `cull`, `hits` and `pieces`. Throws
   * `BuildError` for a `tolerance` not positive and finite, a solid with no faces or that meshes
   * to nothing, a profile with no segments, or a free-form segment that is not an evaluable
   * NURBS curve.
   */
  hits(profile, frame, tolerance = 0.05, progress = null) {
    const l = _lib();
    const h = _checked(l.solid_profile_hits(this._handle, profile._handle, _frame(frame), _tol(tolerance), _progress(progress), null), 'solid_profile_hits');
    try {
      const hits = [];
      const n = l.hit_count(h);
      for (let i = 0; i < n; i++) {
        const raw = {};
        if (!l.hit(h, i, raw)) _fail('hit');
        hits.push(_hitOf(raw));
      }
      const pieces = [];
      const m = l.hits_piece_count(h);
      for (let i = 0; i < m; i++) {
        const inside = [false], start = {}, end = {};
        if (!l.hits_piece(h, i, inside, start, end)) _fail('hits_piece');
        const own = new Profile(_checked(l.hits_piece_profile(h, i), 'hits_piece_profile'));
        pieces.push(new Piece(Boolean(inside[0]), _spotOf(start), _spotOf(end), own));
      }
      return new SolidHits(hits, pieces);
    } finally {
      l.hits_free(h);
    }
  }
  // -- asking
  get faces() {
    const n = _lib().face_count(this._handle);
    if (n === 0 && _lastError()) _fail('face_count');
    return n;
  }
  faceKind(face) { const raw = _lib().face_kind(this._handle, face); if (raw == null) _fail('face_kind'); return String(raw); }
  /** `boundsAt(0.05)`. */
  /**
   * The solid's axis-aligned box, `[[minX, minY, minZ], [maxX, maxY, maxZ]]`, at the same cost
   * whatever its size: its mesh at a thousandth of its own extent, in `double`, so the box is
   * inside the exact one and short of it by at most that. Worked out once per solid, apart from
   * the tessellation `mesh` caches. `boundsAt` is the box of the mesh at a tolerance you name.
   */
  get bounds() {
    const lo = new Float64Array(3), hi = new Float64Array(3);
    if (!_lib().box(this._handle, lo, hi)) _fail('box');
    return [Array.from(lo), Array.from(hi)];
  }
  /** `[[minX, minY, minZ], [maxX, maxY, maxZ]]` over the tessellation at `tolerance`. */
  boundsAt(tolerance) {
    const lo = new Float64Array(3), hi = new Float64Array(3);
    if (!_lib().bounds(this._handle, tolerance, lo, hi)) _fail('bounds');
    return [Array.from(lo), Array.from(hi)];
  }
  /** `boundsAt64(0.05)`. */
  get bounds64() { return this.boundsAt64(0.05); }
  /** `boundsAt(tolerance)` from the same tessellation's own unnarrowed positions -- exact far from the origin, where `boundsAt`'s widened `float` is not. */
  boundsAt64(tolerance) {
    const lo = new Float64Array(3), hi = new Float64Array(3);
    if (!_lib().bounds64(this._handle, tolerance, lo, hi)) _fail('bounds64');
    return [Array.from(lo), Array.from(hi)];
  }
  /**
   * How many edges of the mesh at `tolerance` are bound by anything other
   * than exactly two triangles -- zero for a closed solid. A seam two solids
   * share along a line does not count; a hole or a fold does.
   */
  leakedEdges(tolerance = 0.05) {
    const n = _lib().leaked_edges(this._handle, _tol(tolerance));
    if (n === NONE) _fail('leaked_edges');
    return n;
  }
  /**
   * How many edges of the mesh at `tolerance` have directed triangle uses
   * that do not cancel out -- zero for a closed, consistently oriented solid.
   * Unlike `leakedEdges` this counts a fold (two triangles running the same
   * way) and not a seam two solids share along a line.
   */
  unpairedEdges(tolerance = 0.05) {
    const n = _lib().unpaired_edges(this._handle, _tol(tolerance));
    if (n === NONE) _fail('unpaired_edges');
    return n;
  }
  /** `leakedEdges(tolerance) === 0`. */
  isWatertight(tolerance = 0.05) { return this.leakedEdges(_tol(tolerance)) === 0; }
  /**
   * Whether the faces make a manifold -- every edge bordered by one face or
   * two, the faces round every vertex one fan -- and whether it is closed:
   * `{ faces, edges, vertices, boundaryEdges, nonManifoldEdges,
   * nonManifoldVertices, isManifold, isClosed }`. Read off the solid's
   * topology, not a mesh, so it takes no tolerance; whether the faces all
   * face out is `unpairedEdges`'s question.
   */
  get manifold() {
    const out = new Uint32Array(8);
    if (!_lib().manifold(this._handle, out)) _fail('manifold');
    return _manifold(out);
  }
  /**
   * The radius of the round face `face` belongs to -- a fillet's face that `unfillet` can take
   * back -- 0 where it is none. Throws `BuildError` for a face the solid does not have.
   */
  faceRoundRadius(face) {
    const r = _lib().face_round_radius(this._handle, face);
    if (Number.isNaN(r)) _fail('face_round_radius');
    return r;
  }
  /**
   * The distance of the chamfer face `face` belongs to -- a bevel `unchamfer` can take back --
   * 0 where it is none. Throws `BuildError` for a face the solid does not have.
   */
  faceChamferDistance(face) {
    const d = _lib().face_chamfer_distance(this._handle, face);
    if (Number.isNaN(d)) _fail('face_chamfer_distance');
    return d;
  }
  /**
   * The edges as rational cubic Béziers, sixteen numbers each (`x y z w` per control point, the
   * point Cartesian and its weight beside it) -- what a viewer draws the edges by: exact where an
   * edge's curve has a Bézier form, flattened within `tolerance` where it has none (null: the
   * solid's effective tolerance). A `Float64Array`.
   */
  edgeBeziers(tolerance = null) {
    const l = _lib();
    const t = _tol(tolerance);
    const n = 16 * l.edge_bezier_count(this._handle, t);
    // never a zero-length array: koffi passes that as NULL, which the fill refuses
    const out = new Float64Array(Math.max(1, n));
    if (!l.edge_beziers(this._handle, t, out)) _fail('edge_beziers');
    return out.slice(0, n);
  }
  /**
   * The faces' isoparametric curves as rational cubic Béziers, sixteen numbers each as
   * `edgeBeziers` gives them: `density` interior lines each way on every curved face, clipped to
   * the face, plus the lines at the ends of its parameter span; a flat face draws none. Exact
   * where the surface has a closed form for the line, flattened within `tolerance` elsewhere
   * (null: the solid's effective tolerance). A `Float64Array`.
   */
  isocurveBeziers(density = 4, tolerance = null) {
    const l = _lib();
    const t = _tol(tolerance);
    const n = 16 * l.isocurve_bezier_count(this._handle, density, t);
    const out = new Float64Array(Math.max(1, n));
    if (!l.isocurve_beziers(this._handle, density, t, out)) _fail('isocurve_beziers');
    return out.slice(0, n);
  }
  /**
   * What this solid measures, per unit density, each figure beside a bound on its own error.
   * `accuracy` is relative and 0 asks for the library's default. The volume-side figures mean
   * something only where `closed`; where `accuracyMet` is false the refinement stopped early and
   * the figures are honest but less certain, which the errors say.
   */
  mass(accuracy = 0) {
    const out = {};
    if (!_lib().mass_properties(this._handle, accuracy, out)) _fail('mass_properties');
    return _mass(out);
  }
  /**
   * This closed solid's box on its principal axes, `{ centre, axes, half }` -- tight along a clear
   * long direction, not the minimal box in general. `accuracy` is the relative accuracy of the
   * inertia the axes come from; 0 or less asks for the box's own default, 1e-5. Throws for an open
   * body, or an `accuracy` that is NaN or infinite.
   */
  orientedBox(accuracy = 0) {
    const out = {};
    if (!_lib().oriented_box(this._handle, accuracy, out)) _fail('oriented_box');
    return _orientedBoxOf(out);
  }
  /**
   * The length of edge `edge` (an index into `edges()`) over its own range, as
   * `{ length, error, accuracyMet, fromPolyline }`, measured to the relative `accuracy` (0 asks
   * for the default). Throws for an edge past the end or one with no curve to measure.
   */
  edgeLength(edge, accuracy = 0) {
    const out = {};
    if (!_lib().edge_length(this._handle, edge, accuracy, out)) _fail('edge_length');
    return _lengthOf(out);
  }
  /**
   * The point of edge `edge` (an index into `edges()`) `s` along it, measured from the start of its
   * curve range, as `{ point, tangent, parameter, segment, error, fromPolyline }` (`segment` is null
   * on an edge). `accuracy` is relative; 0 or less asks for the default. Throws for an edge past
   * the end or without a curve, an `s` outside the edge, or an `accuracy` that is not finite.
   */
  edgePointAtLength(edge, s, accuracy = 0) {
    const out = {};
    if (!_lib().edge_point_at_length(this._handle, edge, s, accuracy, out)) _fail('edge_point_at_length');
    return _atOf(out);
  }
  /**
   * Edge `edge` in `n` pieces of equal arc length, as `At` records: `n + 1` samples from its start
   * to its end, or `n` for an edge that closes on itself. `n` is 1 to 1,000,000.
   */
  edgeDivideByCount(edge, n, accuracy = 0) {
    _count(n, 'edge_divide_by_count');
    return _samples(_checked(_lib().edge_divide_by_count(this._handle, edge, n, accuracy), 'edge_divide_by_count'), 'edge_divide_by_count');
  }
  /** Edge `edge` every `step` of arc length from its start, as `At` records; the short last piece is kept. */
  edgeDivideByLength(edge, step, accuracy = 0) {
    return _samples(_checked(_lib().edge_divide_by_length(this._handle, edge, step, accuracy), 'edge_divide_by_length'), 'edge_divide_by_length');
  }
  /**
   * Where `point` is relative to this closed solid: 'inside', 'outside', or 'on' within
   * `tolerance` of its boundary -- absolute, in model units. Meshes the body every call; for more
   * than a few points build a `classifier` once. Throws for an open body, a point not finite, or
   * a `tolerance` not positive and finite.
   */
  contains(point, tolerance = 0.05) {
    const out = new Uint32Array([NONE]);
    if (!_lib().contains(this._handle, _doubles(point, 3, 'contains'), _tol(tolerance), out)) _fail('contains');
    return _containment(out[0], 'contains');
  }
  /**
   * A `Classifier` for this closed solid at `tolerance` (absolute, in model units): the body
   * meshed once, then asked point after point. It keeps its own reference to the body, so it
   * goes on answering after this solid is closed.
   */
  classifier(tolerance = 0.05) { return new Classifier(this, _tol(tolerance)); }
  /**
   * The closest points between this solid's boundary and `other`'s, to `tolerance` (absolute, in
   * model units), as `{ distance, onA, onB, kindA, indexA, edgeA, kindB, indexB, edgeB, refined }`;
   * this solid is side `a`. Boundaries are measured, not volumes. `progress(phase, done, total)`
   * hears 'meshing', 'pruning' and 'refining'; over the wasm it is never called. Throws for a
   * `tolerance` not positive and finite or a solid with no faces.
   */
  closest(other, tolerance = 0.05, progress = null) {
    const out = {};
    if (!_lib().closest(this._handle, other._handle, _tol(tolerance), _progress(progress), null, out)) _fail('closest');
    return _closestOf(out);
  }
  /**
   * The nearest point of this solid's boundary to `p`, as a `PointFoot`, or null where it lies
   * beyond `maxDistance` (undefined, null, NaN or Infinity: no limit; a point a rounding error
   * past it is not beyond, so 0 finds a point on the body). `tolerance` -- absolute, in model
   * units -- is unset when undefined, null, 0 or NaN, and the tolerance policy then resolves it to
   * the solid's effective tolerance; it sizes the mesh search only: a `refined` false answer is
   * within `[d - 2/3 tolerance, d + tolerance]` of the true distance `d`. Meshes the body every
   * call: for more than a few points build a `projector` once. Throws for a point not finite, a
   * negative `maxDistance`, a negative or infinite `tolerance`, or a body that meshes to nothing.
   */
  closestPoint(p, maxDistance, tolerance) {
    const out = {};
    const found = _lib().closest_point(this._handle, _doubles(p, 3, 'closest_point'), _unset(maxDistance), _unset(tolerance), out);
    if (found < 0) _fail('closest_point');
    return found ? new PointFoot(out) : null;
  }
  /**
   * A `Projector` for this solid at `tolerance` (undefined, null, 0 or NaN: unset, which the
   * tolerance policy resolves to the solid's effective tolerance): the body meshed once, then
   * asked `closestPoint` point after point. It keeps its own reference to the body, so it goes on
   * answering after this solid is closed. Open bodies and sheets are accepted.
   */
  projector(tolerance) { return new Projector(this, tolerance); }
  /**
   * This solid's **measuring** tessellation as a `TriangleMesh`: the mesh the measuring queries
   * search, within a third of `tolerance` of the surface -- finer than the display mesh `mesh`
   * gives at the same tolerance. Answers against it are exact for the mesh, not for the body.
   * `tolerance` -- absolute, in model units; undefined, null, 0 or NaN is unset, the solid's
   * effective tolerance. The mesh is a copy: it answers on after this solid is closed. Throws for
   * a negative or infinite tolerance, or a body that meshes to nothing.
   */
  triangleMesh(tolerance) {
    return Object.create(TriangleMesh.prototype)._adopt(_lib().solid_triangle_mesh(this._handle, _unset(tolerance)), 'solid_triangle_mesh');
  }
  /**
   * The nearest point to `p` of face `face` alone, inside its trims or on its boundary, as a
   * `PointFoot`: exact, no mesh, always `refined`. Throws for a face past the end
   * (`face_closest_point: face 99 of 6`), a point not finite, or a face that gives no point.
   */
  faceClosestPoint(face, p) {
    const out = {};
    if (_lib().face_closest_point(this._handle, face, _doubles(p, 3, 'face_closest_point'), out) < 0) _fail('face_closest_point');
    return new PointFoot(out);
  }
  /**
   * The nearest point to `p` of edge `edge` (an index into `edges()` -- a `PointFoot`'s `edge` --
   * or the `Edge` itself), on its own curve over its range, as `{ t, point, distance }`, `t` the parameter `edges()`'s
   * curve and `edgePointAtLength` use. Exact, no mesh. Throws for an edge past the end, one with
   * no exact curve, or a point not finite.
   */
  edgeClosestPoint(edge, p) {
    const out = new Float64Array(5);
    if (_lib().edge_closest_point(this._handle, edge instanceof Edge ? edge.index : edge, _doubles(p, 3, 'edge_closest_point'), out) < 0) _fail('edge_closest_point');
    return Object.freeze({ t: out[0], point: [out[1], out[2], out[3]], distance: out[4] });
  }
  /**
   * The nearest points of `curve` and this solid's boundary, as a `CurveBodyFoot` -- `crossing`
   * true, distance 0, where the curve passes through the boundary (the earliest crossing in `t`)
   * -- or null where the body lies beyond `maxDistance` (undefined, null, NaN or Infinity: no
   * limit). `tolerance` -- absolute, in model units; undefined, null, 0 or NaN is unset, the
   * solid's effective tolerance -- sizes the march along the curve and the mesh search: a
   * `refined` false answer is within `[d - 2/3 tolerance, d + tolerance]` of the true distance
   * `d`. Meshes the body every call: for more than a few curves build a `projector` once. Throws
   * for a negative `maxDistance` or a negative or infinite `tolerance`.
   */
  curveClosestPoints(curve, maxDistance, tolerance) {
    const out = {};
    const found = _lib().curve_closest_points(this._handle, curve._handle, _unset(maxDistance), _unset(tolerance), out);
    if (found < 0) _fail('curve_closest_points');
    return found ? new CurveBodyFoot(out) : null;
  }
  /**
   * One thickness for face `face` of this solid alone, on a `ThicknessGauge` meshed at `tolerance`
   * (default 0.01), used once and freed -- build the gauge for more than one face. `at` and
   * `maximum` as for `ThicknessGauge.thicknessAtFace` (`maximum` has no default); null where
   * nothing is found.
   */
  thicknessAtFace(face, { at = null, maximum, tolerance = 0.01 } = {}) {
    const gauge = new ThicknessGauge([this], tolerance);
    try {
      return gauge.thicknessAtFace(0, face, { at, maximum });
    } finally {
      gauge.close();
    }
  }
  /** This solid's box at `tolerance`: its boolean mesh, padded by twice that -- the
   *  broad phase's own bound (`Collider` builds one per part at construction). */
  boundsBox(tolerance = 0.05) {
    const out = {};
    if (!_lib().solid_bounds_box(this._handle, _tol(tolerance), out)) _fail('solid_bounds_box');
    return _boxOf(out);
  }
  // -- out
  /** `{ positions, normals, indices }` as fresh typed arrays at `tolerance`. */
  mesh(tolerance = 0.05) {
    const m = _lib().mesh(this._handle, _tol(tolerance));
    if (m.positions == null) _fail('mesh');
    const n = m.vertex_count;
    return {
      positions: _floats(m.positions, n * 3) ?? new Float32Array(0),
      normals: _floats(m.normals, n * 3) ?? new Float32Array(0),
      indices: _uint32s(m.indices, m.index_count) ?? new Uint32Array(0),
      vertexCount: n, indexCount: m.index_count,
    };
  }
  /**
   * `mesh(tolerance)` in `double`: `{ positions, normals, indices }` with
   * `positions`/`normals` copied out at call time as the exact f64 values
   * `mesh()`'s widened `float` positions are narrowed from -- exact far from the
   * origin, where `mesh()`'s are not. Reads from the same tessellation cache as
   * `mesh()`; meshing at another tolerance through either refills that cache, but
   * this copy, once returned, is unaffected.
   */
  mesh64(tolerance = 0.05) {
    const m = _lib().mesh64(this._handle, _tol(tolerance));
    if (m.positions == null) _fail('mesh64');
    const n = m.vertex_count;
    return {
      positions: _doublesAt(m.positions, n * 3) ?? new Float64Array(0),
      normals: _doublesAt(m.normals, n * 3) ?? new Float64Array(0),
      indices: _uint32s(m.indices, m.index_count) ?? new Uint32Array(0),
      vertexCount: n, indexCount: m.index_count,
    };
  }
  /** The feature edges as an array of `Float32Array`s, three floats a point. */
  edgePolylines(tolerance = 0.05) {
    const p = _lib().edge_polylines(this._handle, _tol(tolerance));
    if (p.offsets == null) _fail('edge_polylines');
    const points = _floats(p.points, p.point_count * 3) ?? new Float32Array(0);
    const offsets = _uint32s(p.offsets, p.polyline_count + 1);
    const out = [];
    for (let i = 0; i < p.polyline_count; i++) out.push(points.slice(offsets[i] * 3, offsets[i + 1] * 3));
    return out;
  }
  /**
   * This solid meshed for a solver, as a `FemMesh`: nodes welded by bits -- two mesh
   * points are one node only where their coordinates are the same doubles, so no
   * tolerance ever merges two distinct points and a crack stays a crack -- triangles
   * wound outward, and every node tagged with the lowest-dimension B-rep entity it lies
   * on. **Owned by you**: `free()` it, or `using` it.
   *
   * `tolerance` is the chordal tolerance in model units, finite and above zero, and
   * **it alone governs how closely the mesh follows the geometry**. `maxSize` is a size
   * ceiling, `0` for none (curvature alone): it splits boundary segments to at most
   * that length and lays interior stations `maxSize / √2` apart as a **target**, and it
   * adds nodes without refining the boundary geometry -- a caller that wants the rim
   * nearer its curve lowers the `tolerance`. `FemMesh.longestEdge` is what the mesh
   * actually came to, and the figure to check.
   *
   * Those two defaults are `FemOptions::default()`'s own, **not the 0.05 that `mesh`
   * and every other tolerance here default to**, and they are restated in this
   * signature because there is nothing to ask in a browser: the wasm kernel has no
   * `fem_options_init` export. The DLL's own init is still called where there is one,
   * so a field added to the struct later defaults without this line being touched.
   *
   * `placement` is a `Frame` or **twelve** numbers -- origin, x, y, z -- as every frame
   * here, and null for the identity, a solid meshed in its own coordinates being the
   * common case. The reader library's `Node.femMesh` takes **sixteen**, column-major,
   * so a caller moving between the two reformats the placement.
   *
   * `progress(phase, done, total)` hears **`'meshing'`** and **`'welding'`**. An opened
   * phase is not a promise of a closed one: a refused call opens no phase at all, and a
   * solid that meshes to no triangles reports `meshing` through to `1 of 1` and then
   * throws with no `welding`.
   *
   * **A cracked solid is not a failure**: it comes back with `FemMesh.watertight` false
   * and its cracks in `openEdges()` / `foldedEdges()`, and nothing is welded shut to
   * make it look sound. Throws `BuildError` for a tolerance or `maxSize` the mesher
   * refuses, a placement that is not twelve finite numbers or is not invertible, a
   * closed solid this library cannot mesh, and a solid that meshes to no triangles.
   *
   * **No unlicensed notice here**: `FemMesh.mshText` and `FemMesh.saveMsh` print it,
   * this library noticing on its writers rather than on its builders -- where the
   * reader library notices in its own constructor and on neither `.msh` call.
   */
  femMesh(tolerance = 0.01, maxSize = 0.0, placement = null, progress = null) {
    // null, never an empty array: the wasm export reads `null` as the identity and
    // refuses a zero-length frame as twelve numbers it did not get.
    const frame = placement == null ? null : _frame(placement);
    return new FemMesh(_lib().fem_mesh(this._handle, frame, _femOptions(tolerance, maxSize), _progress(progress), null));
  }
  /** A colour per polyline of `edgePolylines(tolerance)`, as drawn: [r, g, b], or null for a polyline
   *  on no coloured edge; an empty array where the solid has no edge paint at all. Copied out, but
   *  it fills the solid's cache at `tolerance` first, as `edgePolylines` does. */
  edgePolylineColours(tolerance = 0.05) {
    const c = _lib().edge_polyline_colours(this._handle, _tol(tolerance));
    if (c.rgb == null) { if (_lastError()) _fail('edge_polyline_colours'); return []; }
    const values = _doublesAt(c.rgb, 3 * c.count);
    const out = [];
    for (let i = 0; i < c.count; i++) out.push(values[3 * i] < 0 ? null : [values[3 * i], values[3 * i + 1], values[3 * i + 2]]);
    return out;
  }
  stepText(schema = null, unit = 'mm') { return writeStepText([this], schema, unit); }
  step(filePath, schema = null, unit = 'mm') { fs.writeFileSync(filePath, this.stepText(schema, unit), 'utf8'); }
  /** The solid as ACIS SAT text: analytic surfaces as their own records, splines and swept surfaces as exact NURBS. */
  satText(unit = 'mm') { return writeSatText([this], unit); }
  /** `satText` written to `filePath` by the library itself. */
  sat(filePath, unit = 'mm') { writeSat(filePath, [this], unit); }
  /** The solid as a Rhino `.3dm`'s bytes: its exact brep, named and coloured as the solid is; see `rhino3dmBytes`. */
  rhino3dmBytes(unit = 'mm') { return rhino3dmBytes([this], unit); }
  /** `rhino3dmBytes` written to `filePath` by the library itself. */
  write3dm(filePath, unit = 'mm') { write3dm(filePath, [this], unit); }
  /** This solid as OCCT `.brep` text: the exact surfaces and curves, with a
   *  curve in each face's own parameters for every edge, so OCCT's `BRepTools::Read`
   *  gives a shape `BRepCheck_Analyzer` finds valid. No unit is declared -- a `.brep`
   *  carries none -- so the numbers are the numbers. */
  brepText() { return writeBrepText([this]); }
  /** `brepText()` written to `filePath`, by the library itself. */
  brep(filePath) { writeBrep(filePath, [this]); }
  /**
   * This solid's own wireframe as SVG text, from the camera `options`
   * describes (see `svgOptionsDefaults`) -- the library's own camera, not a
   * viewer. Owned by this call: decoded and released before it returns.
   */
  svgText(options = {}) { return writeSvgText([this], options); }
  /** `svgText(options)` written to `filePath` by the library itself. */
  svg(filePath, options = {}) { writeSvg(filePath, [this], options); }
  /**
   * This solid's silhouette -- where its surfaces turn away from the eye, which no edge of it
   * lies on -- as rational cubic Beziers in `double`, from the camera `options` describes (see
   * `svgOptionsDefaults`): `view`, `azimuth`, `elevation`, `up`, `fov`, and `width` with
   * `tolerance`, which the library reads together as the page fraction `tolerance / width`.
   * Nothing else in the options changes the curves.
   *
   * `{ points, weights, count }`: `points` holds twelve numbers a curve (four control points,
   * x y z), `weights` four. The library hands over an owned block; this copies it out and
   * releases it before it returns, whichever way it returns, so there is nothing to free.
   *
   * A body with no silhouette (every face planar) answers `count` 0 with empty arrays, which is
   * not an error; a refused option or a body with no measurable geometry throws a `BuildError`.
   */
  silhouetteBeziers(options = {}) {
    const raw = _svgOptions(options);
    const l = _lib();
    const count = new Uint32Array(1);
    const data = l.silhouette_beziers(this._handle, raw, count);
    if (data == null) {
      // The call clears the thread's error at entry and the empty answer sets none: a reason
      // here is this call's own refusal, none is the empty answer.
      if (_lastError()) _fail('silhouette_beziers');
      return { points: new Float64Array(0), weights: new Float64Array(0), count: 0 };
    }
    const n = count[0];
    try {
      const block = _doublesAt(data, n * 16) ?? new Float64Array(0);
      const points = new Float64Array(n * 12), weights = new Float64Array(n * 4);
      for (let c = 0; c < n; c++) {
        points.set(block.subarray(c * 16, c * 16 + 12), c * 12);
        weights.set(block.subarray(c * 16 + 12, c * 16 + 16), c * 4);
      }
      return { points, weights, count: n };
    } finally {
      l.silhouette_beziers_free(data, n);
    }
  }
  /** `svgText`, on the worker thread. `options` is validated and packed on the caller's
   * thread first (fail fast), same as the reader's `Scene.svgAsync`/`Node.svgAsync`. */
  async svgAsync(options = {}) {
    const raw = _svgOptions(options);
    return this._async('svgAsync', { op: 'svg', handles: [_addressOf(this._pointer)], options: raw });
  }
  // -- selecting and edges
  selectFace(selector) {
    const { kind, v, index } = selector._raw();
    const i = _lib().select_face(this._handle, kind, v, index);
    if (i === NONE) _fail('select_face');
    return i;
  }
  /**
   * An `RTree` over this solid's faces: one entry per face, its id the face index the other face
   * calls take, its box holding the face (the box the boolean's broad phase pairs faces by, grown
   * by a thousandth of the solid's extent). No faces give an empty tree. The tree is its own and
   * outlives the solid.
   */
  faceTree() {
    return Object.create(RTree.prototype)._adopt(_lib().solid_face_tree(this._handle), 'solid_face_tree');
  }
  /** Twelve numbers: origin, x, y, z of the workplane on `face`. */
  faceFrame(face) {
    const out = new Float64Array(12);
    if (!_lib().face_frame(this._handle, face, out)) _fail('face_frame');
    return Array.from(out);
  }
  /** Face `face` by what it is, eight numbers: the surface's kind (plane 0, cylinder 1,
   * cone 2, sphere 3, torus 4, NURBS 5, revolution 6, extrusion 7, sum 8), a point on the
   * surface at the face's middle (x y z), the outward normal there (x y z), and the face's
   * extent -- what a feature made on the face keeps, to find the face again with
   * `findFace` when the solid has been rebuilt with its faces moved, split or renumbered.
   * Take it before any move you apply to the solid, and look it up on the unmoved one. */
  faceRef(face) {
    const out = new Float64Array(8);
    if (!_lib().face_ref(this._handle, face, out)) _fail('face_ref');
    return Array.from(out);
  }
  /** The face `faceRef` (from `faceRef`) refers to: among the faces of that kind whose
   * surface passes through the point, facing the same way, the one the point lies in --
   * or, where it lies in none, the one whose boundary comes nearest. `hint` is the index
   * the face had, preferred among faces that fit equally well; `tolerance` how far the
   * point may sit off a surface to still be on it. Null where the face is gone. */
  findFace(faceRef, hint = null, tolerance = 1e-3) {
    const ref = Float64Array.from(faceRef, Number);
    if (ref.length !== 8) throw new BuildError('find_face: a face reference is eight numbers');
    const found = _lib().find_face(this._handle, ref, hint === null || hint === undefined ? -1 : hint, _tol(tolerance));
    if (found === -2) _fail('find_face');
    return found < 0 ? null : found;
  }
  /** Edge `edge` (an index into `edges()`) by what it is, fifteen numbers: its kind (line 0,
   * circle 1, ellipse 2, B-spline 3, other 4), its midpoint (x y z), its unit tangent there
   * (x y z), its length, the outward normals there of the two faces meeting on it (x y z each;
   * an open sheet's rim gives its one face's twice), and its span -- how far from the midpoint
   * `findEdge` may look on a resized solid. `faceRef`'s twin. Throws for an edge past the table
   * or one with no length. */
  edgeRef(edge) {
    const out = new Float64Array(15);
    if (!_lib().edge_ref(this._handle, edge, out)) _fail('edge_ref');
    return Array.from(out);
  }
  /** The edge `edgeRef` (from `edgeRef`) refers to: of the edges of that kind passing within
   * `tolerance` of its midpoint and running the same way, the one of nearest length; where none
   * does (the solid was resized), the edge of that kind running the same way between faces
   * facing the same two ways, the only one or the one clearly nearest, no farther than the span.
   * Null where the edge is gone; throws for a malformed reference or a tolerance not positive. */
  findEdge(edgeRef, tolerance = 1e-3) {
    const ref = Float64Array.from(edgeRef, Number);
    if (ref.length !== 15) throw new BuildError('find_edge: an edge reference is fifteen finite numbers');
    const found = _lib().find_edge(this._handle, ref, _tol(tolerance));
    if (found === -2) _fail('find_edge');
    return found < 0 ? null : found;
  }
  /** How many vertices this solid has: its edges' ends, welded, in the order `vertexRef` and `findVertex` index. */
  get vertexCount() {
    const n = _lib().vertex_count(this._handle);
    if (n === 0 && _lastError()) _fail('vertex_count');
    return n;
  }
  /** Vertex `vertex` by where it is: `[x, y, z]`. Throws for a vertex the solid does not have. */
  vertexRef(vertex) {
    const out = new Float64Array(3);
    if (!_lib().vertex_ref(this._handle, vertex, out)) _fail('vertex_ref');
    return Array.from(out);
  }
  /** The vertex nearest `vertexRef` (a `vertexRef`, or any point) within `tolerance`; null where
   * no vertex is that near. Throws for a point that is not three finite numbers or a tolerance
   * not positive. */
  findVertex(vertexRef, tolerance = 1e-3) {
    const ref = Float64Array.from(vertexRef, Number);
    if (ref.length !== 3) throw new BuildError('find_vertex: a vertex reference is three finite numbers');
    const found = _lib().find_vertex(this._handle, ref, _tol(tolerance));
    if (found === -2) _fail('find_vertex');
    return found < 0 ? null : found;
  }
  // -- identity: ids on faces and edges, where each came from, and a verb's history
  /** This solid tracked: its faces numbered 1..n in face order and its edges 1..m in the edge
   * table's order, each its own origin. Tracking is opt-in and rides on from here: a verb on a
   * tracked solid gives a tracked result. A tracked solid comes back as it is. */
  tracked() { return new Solid(_lib().solid_tracked(this._handle)); }
  /** Whether this solid carries face and edge ids (`tracked`, made from a tracked solid, or given an attribute). */
  get isTracked() {
    const t = _lib().solid_is_tracked(this._handle);
    if (!t && _lastError()) _fail('solid_is_tracked');
    return Boolean(t);
  }
  _idOf(short, index) {
    const id = Number(_lib()[short](this._handle, index));
    if (id === 0) {
      if (_lastError()) _fail(short);
      return null;
    }
    return id;
  }
  _withId(short, id) {
    const found = _lib()[short](this._handle, _id(id, short));
    if (found === NONE) {
      if (_lastError()) _fail(short);
      return null;
    }
    return found;
  }
  _origins(what, index) {
    const l = _lib();
    const n = l[`${what}_origin_count`](this._handle, index);
    if (n === NONE) _fail(`${what}_origin_count`);
    const operand = [0], id = [0], out = [];
    for (let i = 0; i < n; i++) {
      if (!l[`${what}_origin_at`](this._handle, index, i, operand, id)) _fail(`${what}_origin_at`);
      out.push(Object.freeze([Number(operand[0]), Number(id[0])]));
    }
    return out;
  }
  /** Face `face`'s id (a number), null where this solid is untracked. An id stays with its face
   * through every verb that keeps the face; ids are not written to files (use `faceRef` there).
   * Throws for a face the solid does not have. */
  faceId(face) { return this._idOf('face_id', face); }
  /** The face whose id is `id`, null where no face has it. */
  faceWithId(id) { return this._withId('face_with_id', id); }
  /** The input faces face `face` came from, as `[operand, id]` pairs (a boolean's target 0, its
   * tool 1): the face it lies on most first; empty for a generated face or an untracked solid. */
  faceOrigins(face) { return this._origins('face', face); }
  /** Edge `edge`'s id (an index into `edges()`), as `faceId`. */
  edgeId(edge) { return this._idOf('edge_id', edge); }
  /** The edge whose id is `id`, null where no edge has it. */
  edgeWithId(id) { return this._withId('edge_with_id', id); }
  /** The input edge edge `edge` lies on, as `faceOrigins`: one `[operand, id]`, or none for a new edge. */
  edgeOrigins(edge) { return this._origins('edge', edge); }
  _history(short, inputs) {
    const l = _lib();
    const handles = inputs.map((s) => s._handle);
    const h = l[short](this._handle, handles, handles.length);
    if (!h) _fail(short);
    try { return _readHistory(l, h); } finally { l.history_free(h); }
  }
  /** What the verb that made this solid did to the faces of `inputs` -- passed in its operand
   * order (`a.cut(b).history(a, b)`) -- as a `History`. Throws where this solid or an input is
   * untracked, or an origin names an operand past the inputs. */
  history(...inputs) { return this._history('history', inputs); }
  /** `history` for the edges, by edge id. */
  edgeHistory(...inputs) { return this._history('edge_history', inputs); }
  // -- attributes: text on a solid (written to STEP files) and on its faces (in memory)
  /** This solid's attributes, a read-only `Map` in key order (built once per solid). A solid's
   * attributes go with it through every verb (a verb's result takes its first operand's) and are
   * written to STEP files as user-defined attributes. */
  get attributes() {
    if (this._attributes === undefined) {
      const l = _lib(), h = this._handle;
      const n = l.attribute_count(h);
      if (n === 0 && _lastError()) _fail('attribute_count');
      this._attributes = _attributeMap(n, l.attribute_key_at, l.attribute_value_at, h);
    }
    return this._attributes;
  }
  /** Attribute `key`, null where this solid has none. */
  attribute(key) {
    const raw = _lib().attribute(this._handle, _attributeText(key, 'attribute', 'key'));
    if (raw == null) {
      if (_lastError()) _fail('attribute');
      return null;
    }
    return String(raw);
  }
  /** This solid with attribute `key` set to `value`, over any it had: a new solid, tracked if this one was not. An empty key is refused. */
  withAttribute(key, value) {
    return new Solid(_lib().with_attribute(this._handle, _attributeText(key, 'with_attribute', 'key'), _attributeText(value, 'with_attribute', 'value')));
  }
  /** This solid with every attribute given (a `Map`, `[key, value]` pairs or an object) set, in key order. */
  withAttributes(attributes) {
    let out = this;
    for (const [key, value] of _attributeEntries(attributes, 'with_attributes')) {
      const next = out.withAttribute(key, value);
      if (out !== this) out.close();
      out = next;
    }
    return out;
  }
  /** This solid without attribute `key`: a new solid, equal to this one where it had none. */
  withoutAttribute(key) { return new Solid(_lib().without_attribute(this._handle, _attributeText(key, 'without_attribute', 'key'))); }
  /** Face `face`'s attributes, a read-only `Map` in key order. They follow the face's id through
   * verbs (each piece of a split face has its parent's) and stay in memory. Throws for a face the
   * solid does not have. */
  faceAttributes(face) {
    const l = _lib(), h = this._handle;
    const n = l.face_attribute_count(h, face);
    if (n === NONE) _fail('face_attribute_count');
    return _attributeMap(n, l.face_attribute_key_at, l.face_attribute_value_at, h, face);
  }
  /** Face `face`'s attribute `key`, null where it has none. Throws for a face the solid does not have. */
  faceAttribute(face, key) {
    const raw = _lib().face_attribute(this._handle, face, _attributeText(key, 'face_attribute', 'key'));
    if (raw == null) {
      if (_lastError()) _fail('face_attribute');
      return null;
    }
    return String(raw);
  }
  /** This solid with face `face`'s attribute `key` set to `value`: a new solid, tracked if this one was not. */
  withFaceAttribute(face, key, value) {
    const what = 'with_face_attribute';
    return new Solid(_lib().with_face_attribute(this._handle, face, _attributeText(key, what, 'key'), _attributeText(value, what, 'value')));
  }
  /** This solid with every attribute given set on face `face`, in key order. */
  withFaceAttributes(face, attributes) {
    let out = this;
    for (const [key, value] of _attributeEntries(attributes, 'with_face_attributes')) {
      const next = out.withFaceAttribute(face, key, value);
      if (out !== this) out.close();
      out = next;
    }
    return out;
  }
  /** This solid without face `face`'s attribute `key`: a new solid, equal to this one where the face had none. */
  withoutFaceAttribute(face, key) {
    return new Solid(_lib().without_face_attribute(this._handle, face, _attributeText(key, 'without_face_attribute', 'key')));
  }
  // -- naming
  /**
   * This solid, named `name`. The name rides through an operation with exactly one source
   * solid (`place`, `translate`, `coloured`, `fillet`, ...) and is dropped by one with two or
   * more (`join`, `cut`, `common`, ...) and by a fresh primitive or sweep -- see `name`. It is
   * what `Assembly.place` defaults a placement's own name to, and the product name a lone named
   * solid gets when written to STEP (`step`/`stepText`). Refused for an empty name.
   */
  named(name) { return new Solid(_lib().named(this._handle, name)); }
  /**
   * This solid's name, or null if it has none -- what `named` set, kept or dropped by whatever
   * built this solid (see `named`). The library's borrowed pointer is null for both "no name"
   * and a failure, so this never consults `last_error` -- same as Python's own `.name` -- and it
   * reads the raw result itself rather than through `_text`, which maps null to `''` and would
   * erase the distinction. Over the wasm route the export returns `''` for "no name" instead of
   * null (there is no null `const char *` there), so both are folded the same way: `raw ? ... : null`.
   */
  get name() { const raw = _lib().solid_name(this._handle); return raw ? String(raw) : null; }
  // -- material and look defined outside the file
  /**
   * This solid made of `material` -- a name, written to STEP as the product's
   * MATERIAL_DESIGNATION. Kept by every operation as the solid's colour is: a move keeps it, a
   * boolean's result is made of its first solid's. Writing it moves `step`'s default schema to
   * AP242; a named schema without the entity drops it, as it drops a colour. Refused when blank.
   */
  withMaterial(material) { return new Solid(_lib().with_material(this._handle, material)); }
  /** What this solid is made of, or null -- read as `name` is (`''` over wasm folds to null too). */
  get material() { const raw = _lib().solid_material(this._handle); return raw ? String(raw) : null; }
  /**
   * This solid drawn in a style defined outside the file: `identification` the style's name in
   * the library at `location` -- a MaterialX or MDL file and a material in it, say. Either may
   * be null, not both. Written to STEP as an EXTERNALLY_DEFINED_STYLE beside the solid's colour,
   * which a reader without the library draws instead (AP242 or AP214: the default schema moves
   * to AP242). Kept as `withMaterial`'s material is.
   */
  styled(location = null, identification = null) {
    return new Solid(_lib().styled(this._handle, location ?? null, identification ?? null));
  }
  /** Where this solid's outside style lives (`styled`'s `location`), or null. */
  get styleLocation() { const raw = _lib().solid_style_location(this._handle); return raw ? String(raw) : null; }
  /** This solid's outside style's name in its library (`styled`'s `identification`), or null. */
  get styleIdentification() { const raw = _lib().solid_style_identification(this._handle); return raw ? String(raw) : null; }
  // -- colour
  /** This solid coloured -- `colour` is '#rgb', '#rrggbb', a CSS colour name or [r, g, b] in 0..1 -- or with `face`
   *  just that face, whose colour then wins over the solid's. What is made from a coloured solid
   *  inherits: a move keeps every colour; a boolean, fillet, chamfer or shell gives each face the
   *  colour of the face it lies on (a cut's bore the tool's), and a new face the solid's. */
  coloured(colour, face = null) {
    const [r, g, b] = _rgb(colour);
    return new Solid(_lib().coloured(this._handle, _faceOrNone(this, face, 'coloured'), r, g, b));
  }
  /** The solid's colour, [r, g, b] in 0..1, or null. */
  get colour() { return this._colour(NONE); }
  /** `face`'s colour as drawn -- its own, else the solid's -- or null. */
  faceColour(face) { return this._colour(_faceOrNone(this, face, 'colour')); }
  _colour(face) {
    const out = new Float64Array(3);
    if (_lib().colour(this._handle, face, out)) return Array.from(out);
    if (_lastError()) _fail('colour');
    return null;
  }
  /** This solid with its edges coloured: every edge, or with `edges` (`Edge` objects or indices,
   *  as `fillet` takes them) just those, whose colour then wins over the all-edges one. An empty
   *  list colours no edge. Inherited as face colours are: a move keeps every one, a boolean or a
   *  fillet gives each edge the colour of the input edge it lies on, a new edge the all-edges one. */
  edgesColoured(colour, edges = null) {
    const [r, g, b] = _rgb(colour);
    if (edges == null) return new Solid(_lib().edges_coloured(this._handle, null, 0, r, g, b));
    const which = _indices(edges, 'edgesColoured', 'edges', true);
    // A picked list, even an empty one, is a non-null array: null means every edge. The wasm side
    // reads a Uint32Array's own length, so the real (possibly empty) array is exactly right; koffi
    // instead turns a zero-length typed array's pointer into null regardless of the count passed
    // beside it, so the native route needs a throwaway one-element array in its place -- `count`
    // stays the real, zero, length, and the C side never reads that element back. `Profile.round`
    // picks its corners the same way and needs the same branch.
    const list = which.length || _wasm() ? which : new Uint32Array(1);
    return new Solid(_lib().edges_coloured(this._handle, list, which.length, r, g, b));
  }
  /** Edge `edge`'s (an `Edge` or its index) colour as drawn -- its own, else the solid's edge colour -- or null. */
  edgeColour(edge) {
    const out = new Float64Array(3);
    if (_lib().edge_colour(this._handle, edge instanceof Edge ? edge.index : Number(edge), out)) return Array.from(out);
    if (_lastError()) _fail('edge_colour');
    return null;
  }
  /**
   * This solid as a `Document`'s `solid.body` node holds it, parsed: the kernel's own B-rep as a
   * record of its tables, every number as it is, and its colours. What `Document.addSolid` puts in
   * a document.
   */
  documentBody() { return JSON.parse(_ownedText(_lib().document_solid_body(this._handle), 'document_solid_body')); }
  /** The edges a fillet indexes, as `Edge` records (copied; safe to keep). */
  edges() {
    const l = _lib(); const h = this._handle;
    const n = l.edge_count(h);
    if (n === 0 && _lastError()) _fail('edge_count');
    const out = [];
    for (let i = 0; i < n; i++) {
      const raw = {};
      if (!l.edge(h, i, raw)) _fail('edge');
      const faces = Array.from(_uint32s(raw.faces, raw.face_count) ?? []);
      const flat = _doublesAt(raw.segments, raw.segment_count * 6) ?? new Float64Array(0);
      const segments = [];
      for (let k = 0; k < flat.length; k += 6) segments.push([Array.from(flat.subarray(k, k + 3)), Array.from(flat.subarray(k + 3, k + 6))]);
      out.push(new Edge(i, _text(raw.kind), faces, segments, Solid._edgeCurve(l, h, i)));
    }
    return out;
  }
  /** Edge `i`'s exact curve copied out, or null for an edge with none (the library's "has no exact curve"); any other refusal throws. */
  static _edgeCurve(l, h, i) {
    const raw = {};
    if (l.edge_curve(h, i, raw)) return _curveOf(raw);
    if (/has no exact curve/.test(_lastError())) return null;
    _fail('edge_curve');
  }
  /**
   * `edges`: `Edge` objects or their indices. A spline edge -- the crease between two faces on NURBS
   * surfaces, running from one free edge of the shell to another -- is rounded by a ball rolled along
   * it, in a call of its own (not with straight or circular edges); `tolerance` is then the fillet
   * surface's fit. `radiusEnd` (spline edges only) runs the radius linearly from `radius` to it in
   * arc length along the edge, `radius` at the end where the edge's curve starts.
   */
  fillet(edges, radius, tolerance = 1e-6, progress = null, radiusEnd = null) {
    const which = _indices(edges, 'fillet', 'edges', true);
    if (radiusEnd != null && radiusEnd !== radius) {
      return new Solid(_lib().fillet_varying(this._handle, which, which.length, radius, Number(radiusEnd), _tol(tolerance)));
    }
    return new Solid(_lib().fillet(this._handle, which, which.length, radius, _tol(tolerance), _progress(progress), null));
  }
  /**
   * A chain of spline edges rounded with the radius following a law along it: `law` is the radius
   * at stations along the chain, each `[share, radius]` -- the share of the chain's arc length from
   * its start, 0 to 1 -- run through smoothly by a monotone cubic, so the radius never swings past
   * its stations, and held flat before the first station and after the last. `edges` (`Edge`
   * objects or indices) must run end to end into one open chain, each running on tangent into the
   * next; the chain runs the way the first edge's curve does. One edge is a chain of one.
   * `tolerance` is the fillet surfaces' fit.
   */
  filletLaw(edges, law, tolerance = 1e-6) {
    const which = _indices(edges, 'fillet_law', 'edges', true);
    const stations = Array.from(law, (st) => {
      const [f, r] = Array.from(st, Number);
      return [f, r];
    });
    const shares = Float64Array.from(stations, (st) => st[0]);
    const radii = Float64Array.from(stations, (st) => st[1]);
    return new Solid(_lib().fillet_law(this._handle, which, which.length, shares, radii, stations.length, _tol(tolerance)));
  }
  chamfer(edges, distance, tolerance = 1e-6) {
    const which = _indices(edges, 'chamfer', 'edges', true);
    return new Solid(_lib().chamfer(this._handle, which, which.length, distance, _tol(tolerance)));
  }
  /** `open`: face indices removed so the hollow is reachable. */
  /**
   * Face `face` pushed out by `distance` along its outward normal (pulled in, negative) as a face extrude does it: the prism over it joined on (cut out), and the flush faces
   * merged -- a box's top raised is one taller box of six faces. A face on a cylinder, a cone, a
   * sphere or a torus moves out along its normal instead, the surface a step out (a boss fatter,
   * a bore or a countersink narrower, a dome fuller), the flat faces beside it carried along; any
   * other curved face is refused.
   *
   * `face` may be a list of faces, pushed together as a press-pull on a selection: each by
   * its own rule, one after another, each found again after the pushes before it renumbered the
   * faces -- a box's top and a side pushed 5 is the box 5 taller and 5 wider. A face on the same
   * curved surface as one before it, and joined to it, moved with that one and is not pushed twice.
   */
  pushPull(face, distance, tolerance = 0.05, progress = null) {
    if (typeof face === 'number') {
      if (Number.isInteger(face) && face >= 0 && face <= 0xffffffff) {
        return new Solid(_lib().push_pull(this._handle, face, distance, _tol(tolerance), _progress(progress), null));
      }
      throw new TypeError(`pushPull: face must be a face index or a list of indices, not ${face}`);
    }
    if (face == null || typeof face === 'string' || face instanceof Edge || typeof face[Symbol.iterator] !== 'function') {
      const described = face instanceof Edge ? 'an Edge' : typeof face === 'string' ? JSON.stringify(face) : String(face);
      throw new TypeError(`pushPull: face must be a face index or a list of indices, not ${described}`);
    }
    const which = _indices(face, 'pushPull', 'face');
    return new Solid(_lib().push_pull_faces(this._handle, which, which.length, distance, _tol(tolerance), _progress(progress), null));
  }
  /**
   * This solid split by `tool` into bodies: a closed `tool` gives the parts
   * outside it, then the parts inside; a flat sheet splits by the whole plane it lies on. Each
   * connected part is a body of its own.
   */
  split(tool, tolerance = 0.05, progress = null) {
    const all = new Solid(_lib().split(this._handle, tool._handle, _tol(tolerance), _progress(progress), null));
    try { return all.lumps(); } finally { all.close(); }
  }
  /** This solid split by the plane through `plane`'s origin, square to its z: the bodies in front of it first, then those behind. */
  splitByPlane(plane, tolerance = 0.05, progress = null) {
    const all = new Solid(_lib().split_by_plane(this._handle, _frame(plane), _tol(tolerance), _progress(progress), null));
    try { return all.lumps(); } finally { all.close(); }
  }
  /**
   * This solid split by the closed `profile` drawn on `frame`, pushed straight through it
   * along the frame's z both ways: the bodies outside the profile first, then those inside.
   * Where the plane lies along z does not matter.
   */
  splitByProfile(profile, frame, tolerance = 0.05, progress = null) {
    const all = new Solid(_lib().split_by_profile(this._handle, profile._handle, _frame(frame), _tol(tolerance), _progress(progress), null));
    try { return all.lumps(); } finally { all.close(); }
  }
  /** This solid's connected bodies, each a solid of its own -- faces sharing an edge are one body -- in the order of their first faces. */
  lumps() {
    const n = _lib().lump_count(this._handle);
    if (n === 0) _fail('lump_count');
    const bodies = [];
    try {
      for (let i = 0; i < n; i++) bodies.push(new Solid(_lib().lump(this._handle, i)));
    } catch (e) {
      for (const b of bodies) b.close();
      throw e;
    }
    return bodies;
  }
  /** This solid with its flush faces merged, and the vertices left mid-way along a straight edge taken out. */
  mergeFlush() { return new Solid(_lib().merge_flush(this._handle)); }
  /**
   * The round `face` belongs to -- a fillet's bands, balls and rim bands joined to that face --
   * made again at `radius`, as a press-pull on a fillet face: taken back to the sharp edges
   * it replaced, and those rounded again.
   */
  refillet(face, radius, tolerance = 1e-6) { return new Solid(_lib().refillet(this._handle, face, radius, _tol(tolerance))); }
  /** The round `face` belongs to taken off, the faces beside it sharp again -- the delete of a fillet face. */
  unfillet(face) { return new Solid(_lib().unfillet(this._handle, face)); }
  /**
   * The chamfer `face` belongs to -- its bevels, flat or round a rim, and the corner triangles
   * joined to that face -- cut again at `distance`, as a press-pull on a chamfer face.
   */
  rechamfer(face, distance, tolerance = 1e-6) { return new Solid(_lib().rechamfer(this._handle, face, distance, _tol(tolerance))); }
  /** The chamfer `face` belongs to taken off, the faces beside it sharp again -- the delete of a chamfer face. */
  unchamfer(face) { return new Solid(_lib().unchamfer(this._handle, face)); }
  shell(thickness, open = [], tolerance = 1e-6, progress = null) {
    const which = _indices(open, 'shell', 'open');
    return new Solid(_lib().shell(this._handle, thickness, which, which.length, _tol(tolerance), _progress(progress), null));
  }
  /**
   * This sheet made a solid `thickness` thick: its faces, their twins moved
   * `thickness` along the faces' normals (against them for a negative thickness), and a wall round
   * every open edge. A closed sheet thickens to a hollow.
   */
  thicken(thickness, tolerance = 1e-6, progress = null) {
    return new Solid(_lib().thicken(this._handle, thickness, _tol(tolerance), _progress(progress), null));
  }
  /** Run `message` on the worker with this solid (and `others`) locked as `name`. */
  async _async(name, message, others = [], progress = null) {
    const all = [this, ...others];
    for (const s of all) { if (!s._pointer) throw new BuildError('solid: closed'); if (s._busy) throw new BuildError(`busy: ${s._busy} in progress`); }
    for (const s of all) s._busy = name;
    try {
      return await _run({ ...message, a: _addressOf(this._pointer), withProgress: progress != null }, [], progress);
    } finally { for (const s of all) s._busy = null; }
  }
  /** A newly built `Solid` from a worker reply's raw BigInt address; koffi accepts it as-is. */
  static _wrap(r) { return new Solid(r.address); }
  async joinAsync(other, tolerance = 0.05, progress = null) { return Solid._wrap(await this._async('joinAsync', { op: 'combine', which: 'join', b: _addressOf(other._handle), tolerance: _tol(tolerance) }, [other], progress)); }
  async cutAsync(other, tolerance = 0.05, progress = null) { return Solid._wrap(await this._async('cutAsync', { op: 'combine', which: 'cut', b: _addressOf(other._handle), tolerance: _tol(tolerance) }, [other], progress)); }
  async commonAsync(other, tolerance = 0.05, progress = null) { return Solid._wrap(await this._async('commonAsync', { op: 'combine', which: 'common', b: _addressOf(other._handle), tolerance: _tol(tolerance) }, [other], progress)); }
  async splitSheetAsync(tool, tolerance = 0.05, progress = null) { return Solid._wrap(await this._async('splitSheetAsync', { op: 'combine', which: 'split_sheet', b: _addressOf(tool._handle), tolerance: _tol(tolerance) }, [tool], progress)); }
  async filletAsync(edges, radius, tolerance = 1e-6, progress = null) { return Solid._wrap(await this._async('filletAsync', { op: 'fillet', edges: _indices(edges, 'filletAsync', 'edges', true), radius, tolerance: _tol(tolerance) }, [], progress)); }
  async chamferAsync(edges, distance, tolerance = 1e-6) { return Solid._wrap(await this._async('chamferAsync', { op: 'chamfer', edges: _indices(edges, 'chamferAsync', 'edges', true), distance, tolerance: _tol(tolerance) })); }
  async shellAsync(thickness, open = [], tolerance = 1e-6, progress = null) { return Solid._wrap(await this._async('shellAsync', { op: 'shell', thickness, open: _indices(open, 'shellAsync', 'open'), tolerance: _tol(tolerance) }, [], progress)); }
  async thickenAsync(thickness, tolerance = 1e-6, progress = null) { return Solid._wrap(await this._async('thickenAsync', { op: 'thicken', thickness, tolerance: _tol(tolerance) }, [], progress)); }
  async trimAsync(tool, keep = 'outside', tolerance = 0.05, progress = null) {
    Solid._keep(keep);
    return Solid._wrap(await this._async('trimAsync', { op: 'trim', b: _addressOf(tool._handle), keepInside: keep === 'inside', tolerance: _tol(tolerance) }, [tool], progress));
  }
  async meshAsync(tolerance = 0.05) { return this._async('meshAsync', { op: 'mesh', tolerance: _tol(tolerance) }); }
  /** `mesh64(tolerance)`, on the worker thread. */
  async meshAsync64(tolerance = 0.05) { return this._async('meshAsync64', { op: 'mesh64', tolerance }); }
  async stepAsync(schema = null, unit = 'mm') {
    if (!(unit in UNITS)) throw new BuildError(`unit must be one of ${Object.keys(UNITS).sort().join(', ')}`);
    return this._async('stepAsync', { op: 'step', handles: [_addressOf(this._pointer)], schemaText: _schemaText(schema), unit: UNITS[unit] });
  }
  async satAsync(unit = 'mm') {
    if (!(unit in UNITS)) throw new BuildError(`unit must be one of ${Object.keys(UNITS).sort().join(', ')}`);
    return this._async('satAsync', { op: 'sat', handles: [_addressOf(this._pointer)], unit: UNITS[unit] });
  }
  /** This solid as a reader `Scene`, through STEP text and `cadaclysm.openMemory`. */
  // -- from files
  /**
   * The body `node` of a reader `Scene` draws, as a solid -- sharing the
   * reader's brep, not copying it. `node`: a `Node` or its index. The scene can
   * be closed before the solid is. `placed` puts it where the node's
   * `transform` does, which is where its mesh draws; a node at the identity
   * stays shared, a moved one is a moved copy. In the file's own units and
   * axes. The reader's library must come from the same release as this one's.
   */
  static fromNode(scene, node, placed = true) {
    const cad = _reader('fromNode');
    if (!(node instanceof cad.Node)) node = new cad.Node(scene, Number(node));
    const label = `from_node: node ${node.index} (${_label(node)})`;
    const solid = _fromBrep(node, label);
    if (!solid) {
      throw new BuildError(`${label} has no brep: only a B-rep body has one (STEP, ACIS, Rhino, OCCT .brep, IGES, IFC, OpenSCAD), not a mesh, a curve or a CSG body`);
    }
    if (!placed) return solid;
    const m = node.transform;
    if (scene.convention !== cad.Convention.NATIVE && !_isIdentity(m)) {
      solid.close();
      throw new BuildError("from_node: placed=True needs the scene opened with Convention.NATIVE -- the brep is in the file's own axes and the node's transform is not; open NATIVE, or pass placed false");
    }
    return solid._placed(m, 'from_node');
  }
  /**
   * The body a CAD file holds, as a solid: a STEP (AP203/214/242), ACIS `.sat`,
   * Rhino `.3dm`, OCCT `.brep`, IGES, IFC or OpenSCAD file, read where it draws, in the
   * file's own units and axes. A file drawing several bodies needs `body`
   * (0-based, in drawing order) or `openAll`. Fillet and chamfer want line and
   * circle edges; booleans take any surface, but the new edges they trace on a
   * free-form (NURBS) face are not always writable back to STEP; and every verb
   * meshes its operands first, so its cost grows with the body's face count.
   */
  static open(filePath, body = null) {
    const solids = Solid.openAll(filePath);
    const name = require('node:path').basename(String(filePath));
    if (body == null && solids.length === 1) return solids[0];
    if (body == null || !Number.isInteger(body) || body < 0 || body >= solids.length) {
      for (const s of solids) s.close();
      throw new BuildError(body == null
        ? `open: ${name} holds ${solids.length} bodies: pass body= (0 to ${solids.length - 1}), or use Solid.open_all`
        : `open: ${name} has no body ${body}: it holds ${solids.length}`);
    }
    solids.forEach((s, i) => { if (i !== body) s.close(); });
    return solids[body];
  }
  /** Every body a CAD file draws, as solids placed where it draws them: one per placement. See `open`. */
  static openAll(filePath) {
    if (_wasm()) {
      // The wasm reads the file itself, readers and kernel being one module: the bytes
      // from whatever `fs` the page provides (the notebook's: the files its open button read).
      const extension = require('node:path').extname(String(filePath)).replace(/^\./, '').toLowerCase();
      let bytes;
      try { bytes = fs.readFileSync(String(filePath)); } catch (e) { throw new BuildError(`open: ${e.message}`); }
      return _lib().open_file(new Uint8Array(bytes), extension).map((h) => new Solid(h));
    }
    const cad = _reader('open');
    let scene;
    try { scene = cad.open(String(filePath)); } catch (e) { throw new BuildError(`open: ${e.message}`); }
    const solids = [];
    try {
      for (const placement of scene.placements()) {
        const node = placement.geometry;
        const what = `open: ${_label(node)}`;
        const solid = _fromBrep(node, what);
        if (solid) solids.push(solid._placed(placement.transform, what));
      }
    } catch (e) {
      for (const s of solids) s.close();
      throw e;
    } finally {
      scene.close();
    }
    if (!solids.length) {
      const extension = require('node:path').extname(String(filePath)).replace(/^\./, '').toLowerCase();
      throw new BuildError(`open: the .${extension} file draws no B-rep body -- only a STEP, ACIS, Rhino, OCCT .brep, IGES, IFC or OpenSCAD body can be a solid, not a mesh, a curve or a CSG body`);
    }
    return solids;
  }
  /** This solid moved by a row-major 4x4 placement: itself at the identity, a moved copy for a rigid move (this one closed), refused for a scale or shear. */
  _placed(m, what) {
    if (_isIdentity(m)) return this;
    try {
      for (let a = 0; a < 3; a++) {
        for (let b = 0; b < 3; b++) {
          const dot = m[0][a] * m[0][b] + m[1][a] * m[1][b] + m[2][a] * m[2][b];
          if (Math.abs(dot - (a === b ? 1 : 0)) > 1e-9) throw new BuildError(`${what}: the placement scales or shears, which a brep cannot follow`);
        }
      }
      return this.place([m[0][3], m[1][3], m[2][3], m[0][0], m[1][0], m[2][0], m[0][1], m[1][1], m[2][1], m[0][2], m[1][2], m[2][2]]);
    } finally {
      this.close();
    }
  }
  /**
   * This solid as a reader `Scene`, through STEP text and `cadaclysm.openMemory`.
   * `schema` is as `stepText` takes it; the reader is given the schema's path only
   * when it names an existing file, since it carries every built-in schema itself
   * and there is no file here to read a `FILE_SCHEMA` line out of.
   */
  toScene(schema = null) {
    let cad;
    try { cad = require('./cadaclysm'); } catch (e) { throw new BuildError(`toScene needs the reader module beside this file: ${e.message}`); }
    const schemaPath = schema != null && _isSchemaFile(String(schema)) ? String(schema) : null;
    return cad.openMemory(this.stepText(schema), 'stp', { schema: schemaPath, name: 'solid.stp' });
  }
}

// ---- CAM: tools, stock and a job ---------------------------------------------------
// The whole job surface, matching `cadaclysm_blacksmith.py`'s object model name for name:
// `Job`'s manual verbs (`face`/`contour`/`pocket`/`drill`), the automatic `machine`,
// `report()`'s items, `operations()`, `gcode()` and `writeCamotics`, and a job's `stock` and
// `tools` read back. `Tool` has the flat, ball and drill makers.

const _toolFinalizer = typeof FinalizationRegistry === 'function'
  ? new FinalizationRegistry((h) => { try { _lib().tool_free(h); } catch (_) { /* exiting */ } }) : null;

/** A tool's size as the library read it, or its refusal: NaN is only ever a failure here. */
function _toolSize(v, what) {
  if (Number.isNaN(v)) _fail(what);
  return v;
}

/** A cutter: Grbl tool `number` (1 to 255, the `T` word), `diameter` and `fluteLength` in
 * mm, `feed` and `plunge` in mm/min, `rpm` its spindle speed, ramping into its cuts at
 * `rampAngle` degrees. Immutable; a job keeps its own copy. */
class Tool {
  constructor(handle) {
    this._handle = _checked(handle, 'tool');
    if (_toolFinalizer) _toolFinalizer.register(this, handle);
  }
  static _ramped(handle, rampAngle, what) {
    const tool = new Tool(_checked(handle, what));
    if (rampAngle === 3.0) return tool;   // the library's own default: no second handle
    return new Tool(_lib().tool_with_ramp_angle(tool._handle, rampAngle));
  }
  /** A flat end mill. Throws for a `number` outside 1..255, a size, feed or speed not
   * positive and finite, or a `rampAngle` outside (0, 90]. */
  static flat(number, diameter, fluteLength, feed, plunge, rpm, rampAngle = 3.0) {
    return Tool._ramped(_lib().tool_flat(number, diameter, fluteLength, feed, plunge, rpm), rampAngle, 'tool_flat');
  }
  /** A ball end mill, as `flat` but its tip a half sphere of the diameter; in 2.5D it
   * cuts where a flat does, `bottom` being the tip. */
  static ball(number, diameter, fluteLength, feed, plunge, rpm, rampAngle = 3.0) {
    return Tool._ramped(_lib().tool_ball(number, diameter, fluteLength, feed, plunge, rpm), rampAngle, 'tool_ball');
  }
  /** A drill, plunging at `feed`. A job takes it for automatic holes, or its own `drill`. */
  static drill(number, diameter, fluteLength, feed, rpm) {
    return new Tool(_lib().tool_drill(number, diameter, fluteLength, feed, rpm));
  }
  /** The Grbl tool number, 1 to 255 (the `T` word). */
  get number() {
    const n = _lib().tool_number(this._handle);
    if (n === NONE) _fail('tool_number');
    return n;
  }
  /** The cutting end: `'flat'`, `'ball'`, `'drill'`, `'vbit'` or `'bullnose'`. */
  get shape() {
    const s = _lib().tool_shape(this._handle);
    if (!s) _fail('tool_shape');
    return s;
  }
  /** The cutting diameter, in mm. */
  get diameter() { return _toolSize(_lib().tool_diameter(this._handle), 'tool_diameter'); }
  /** How far up the cutting edge reaches from the tip, in mm. */
  get fluteLength() { return _toolSize(_lib().tool_flute_length(this._handle), 'tool_flute_length'); }
  /** A V-bit's included angle, in degrees; `null` for every other shape. */
  get angle() { return this.shape === 'vbit' ? _toolSize(_lib().tool_angle(this._handle), 'tool_angle') : null; }
  /** A bull-nose's corner radius, in mm; `null` for every other shape. */
  get cornerRadius() { return this.shape === 'bullnose' ? _toolSize(_lib().tool_corner_radius(this._handle), 'tool_corner_radius') : null; }
}

const _stockFinalizer = typeof FinalizationRegistry === 'function'
  ? new FinalizationRegistry((h) => { try { _lib().stock_free(h); } catch (_) { /* exiting */ } }) : null;

/** The block of material a job cuts, an axis-aligned box. Immutable; a job keeps its own
 * copy. */
class Stock {
  constructor(handle) {
    this._handle = _checked(handle, 'stock');
    if (_stockFinalizer) _stockFinalizer.register(this, handle);
  }
  /** The box from `min` (x, y, z) to `max`. Throws unless every min is below its max and
   * all six are finite. */
  static box(min, max) {
    const [x0, y0, z0] = min, [x1, y1, z1] = max;
    return new Stock(_lib().stock_box(x0, y0, z0, x1, y1, z1));
  }
  /** `solid`'s bounds grown by `margin` in -X, +X, -Y, +Y and +Z; the bottom stays at the
   * solid's lowest Z. Throws for a `margin` negative or not finite. */
  static around(solid, margin = 0) { return new Stock(_lib().stock_around(solid._handle, margin)); }
}

/** One file a job wrote: a Grbl program -- `tool` its `T` number, `name` `<job name>-T<n>`
 * (or `<job name>-<k>-T<n>` for a repeated tool), `text` its G-code. Read-only. */
class Program {
  constructor(tool, name, text) { this.tool = tool; this.name = name; this.text = text; Object.freeze(this); }
}

function _programs(handle, what) {
  const l = _lib();
  _checked(handle, what);
  try {
    const n = l.programs_count(handle);
    const out = [];
    for (let i = 0; i < n; i++) out.push(new Program(l.programs_tool(handle, i), l.programs_name(handle, i), l.programs_text(handle, i)));
    return out;
  } finally {
    l.programs_free(handle);
  }
}

/** One operation of a `Job`, read back by `job.operations()`: `kind` ("face", "contour",
 * "pocket" or "drill"), `tool` (its Grbl T number) and `params` -- a plain object, in the
 * kind-specific order the operation stores. In `params`: `side` reads as
 * `"outside"`/`"inside"`/`"on"`; `climb` and `open` as `bool`; `points` as an integer; a
 * `NaN` `peck` as `null`; every other value stays a number. Read-only. */
/** What makes two tools the same cutter: shape, diameter, flute length and the shape's
 * own angle or corner radius. */
function _toolKey(t) { return [t.shape, t.diameter, t.fluteLength, t.angle, t.cornerRadius].join('|'); }

class Operation {
  constructor(kind, tool, params) { this.kind = kind; this.tool = tool; this.params = params; Object.freeze(this); }
}

/** A value's name for a "must be a Foo, not <this>" message: its constructor's name for
 * an object, `null`/`undefined` spelled out, `typeof` otherwise. */
function _typeName(v) {
  if (v === null || v === undefined) return String(v);
  return typeof v === 'object' ? (v.constructor?.name ?? 'object') : typeof v;
}

/** One `operations_param_value`, typed as the spec picks by its name (mirrors Python's
 * `_operation_param`). */
function _operationParam(name, value) {
  if (name === 'side') return { 0: 'outside', 1: 'inside', 2: 'on' }[value] ?? value;
  if (name === 'climb' || name === 'open') return Boolean(value);
  if (name === 'points') return Math.trunc(value);
  if (name === 'peck') return Number.isNaN(value) ? null : value;
  return value;
}

function _operations(handle, what) {
  const l = _lib();
  _checked(handle, what);
  try {
    const n = l.operations_count(handle);
    const out = [];
    for (let i = 0; i < n; i++) {
      const kind = l.operations_kind(handle, i);
      const tool = l.operations_tool(handle, i);
      const paramCount = l.operations_param_count(handle, i);
      const params = {};
      for (let k = 0; k < paramCount; k++) {
        const name = l.operations_param_name(handle, i, k);
        params[name] = _operationParam(name, l.operations_param_value(handle, i, k));
      }
      out.push(new Operation(kind, tool, params));
    }
    return out;
  } finally {
    l.operations_free(handle);
  }
}

/** One thing `job.machine()` left uncut: `kind` (`"corner"`, `"hole"`, `"slope"`,
 * `"undercut"`, `"too_deep"` or `"relief"`), `at` (`[x, y, z]`), `size` (its meaning per
 * `kind`; for a relief, how far the notch reaches into each wall, in mm), `reason` (one sentence naming the tool involved), `region` (its XY area, as a list
 * of `Profile`), and `top` and `bottom` (the highest and lowest Z it stands at, from the
 * band's top down to its floor). Read-only. */
class ReportItem {
  constructor(kind, at, size, reason, region, top, bottom) {
    this.kind = kind; this.at = at; this.size = size; this.reason = reason; this.region = region;
    this.top = top; this.bottom = bottom;
    Object.freeze(this);
  }
}

/**
 * What `job.machine()` could not make, read eagerly when it returns: a plain array of
 * `ReportItem`, in order -- `length`, iteration and indexing read the items, as any array
 * does -- with a non-enumerable `text` (the kernel's own report text, one line per item or
 * "nothing left uncut") and a matching `toString()`, so `` `${report}` `` and
 * `String(report)` print it. There is no `Report` class of its own: Python's `Report`
 * wraps a list for `len`/`iter`/`str`, which a plain array already gives for free here.
 */
function _report(handle, what) {
  const l = _lib();
  _checked(handle, what);
  try {
    const n = l.report_count(handle);
    const items = [];
    for (let i = 0; i < n; i++) {
      const kind = l.report_kind(handle, i);
      const at = new Float64Array(3);
      if (!l.report_at(handle, i, at)) _fail('report_at');
      const size = l.report_size(handle, i);
      const top = l.report_top(handle, i);
      const bottom = l.report_bottom(handle, i);
      const reason = l.report_reason(handle, i);
      const region = _profileList(l.report_region(handle, i), 'report_region');
      items.push(new ReportItem(kind, Array.from(at), size, reason, region, top, bottom));
    }
    const text = l.report_text(handle);
    Object.defineProperty(items, 'text', { value: text, enumerable: false });
    items.toString = () => text;
    return items;
  } finally {
    l.report_free(handle);
  }
}

const _jobFinalizer = typeof FinalizationRegistry === 'function'
  ? new FinalizationRegistry((h) => { try { _lib().job_free(h); } catch (_) { /* exiting */ } }) : null;

// `contour`'s `side`, as cadaclysm_blacksmith.py's `_SIDES` maps it for the C call.
const _JOB_SIDES = { outside: 0, inside: 1, on: 2 };
// A NUL truncates silently going through the native call, so a name or a CAMotics stem with
// one in it is refused here, in the kernel's own words for a name with a control character in
// it, as the Python SDK does.
const _NUL_NAME_ERROR = 'job: a name must be non-empty and without brackets, slashes, quotes, control characters, or : * ? < > |';
const _rejectNul = (s) => { if (String(s).includes('\0')) throw new BuildError(_NUL_NAME_ERROR); };

/**
 * A machining job on a `Stock`: operations kept in the order they are added, written as
 * one Grbl 1.1 program per run of operations sharing a tool. Mutable -- each operation is
 * added in place, and a refused one leaves the job as it was. `safeZ` is the absolute Z of
 * rapids between operations and at a program's start and end, above the stock's top;
 * `clearance` is how far an operation enters and leaves its passes above its top;
 * `tolerance` fits free-form sides and offsets; `name` names the programs (`<name>-T<n>`);
 * every program waits `spindleDwell` seconds after starting the spindle; `resolution` is
 * the CAMotics project's voxel size in mm. Throws for a `safeZ` not above the stock, or a
 * setting the job refuses. `close()` frees this handle.
 */
class Job {
  // Positional, with defaults, name for name and in the same order as
  // cadaclysm_blacksmith.py's `Job.__init__(self, stock, safe_z, clearance=1.0,
  // tolerance=0.01, name="job", spindle_dwell=2.0, resolution=0.1)` -- this file's own
  // convention for a call with several optional settings (`Solid.join`, `Solid.cut`), not
  // an options object.
  constructor(stock, safeZ, clearance = 1.0, tolerance = 0.01, name = 'job', spindleDwell = 2.0, resolution = 0.1) {
    _rejectNul(name);
    this._tools = new Map();
    const l = _lib();
    this._handle = _checked(l.job_new(stock._handle, safeZ), 'job_new');
    if (_jobFinalizer) _jobFinalizer.register(this, this._handle, this);
    // the library starts at the same defaults, so only what differs is set
    if (clearance !== 1.0 && !l.job_set_clearance(this._handle, clearance)) _fail('job_set_clearance');
    if (tolerance !== 0.01 && !l.job_set_tolerance(this._handle, tolerance)) _fail('job_set_tolerance');
    if (spindleDwell !== 2.0 && !l.job_set_spindle_dwell(this._handle, spindleDwell)) _fail('job_set_spindle_dwell');
    if (resolution !== 0.1 && !l.job_set_resolution(this._handle, resolution)) _fail('job_set_resolution');
    if (name !== 'job' && !l.job_set_name(this._handle, String(name))) _fail('job_set_name');
  }
  get _live() {
    if (!this._handle) throw new BuildError('job: closed');
    return this._handle;
  }
  get closed() { return this._handle === null; }
  _keep(...tools) { for (const t of tools) this._tools.set(t.number, t); }
  /** The stock's box as the job holds it, `[[minX, minY, minZ], [maxX, maxY, maxZ]]` --
   * what `Stock.box` was given, or what `Stock.around` worked out. */
  get stock() {
    const lo = new Float64Array(3), hi = new Float64Array(3);
    if (!_lib().job_stock(this._live, lo, hi)) _fail('job_stock');
    return [Array.from(lo), Array.from(hi)];
  }
  /** The tools this job was given -- by `face`, `contour`, `pocket`, `drill` and `machine`
   * (its end mill and each drill it used) -- by Grbl number, so a `Program.tool` finds its
   * tool. A refused call adds none; the later of two tools with one number wins. A new
   * `Map` each time. */
  get tools() { return new Map(this._tools); }
  close() {
    if (this._handle === null) return;
    const h = this._handle; this._handle = null;
    if (_jobFinalizer) _jobFinalizer.unregister(this);
    _lib().job_free(h);
  }
  [DISPOSE]() { this.close(); }
  /**
   * Face the stock's top down to `z`, in zigzag rows along X `stepover` apart and passes at
   * most `stepdown` deep, with `tool`. Added to the job in place. Throws for a drill, a `z`
   * above the stock's top, a stepover past the tool's diameter, ...
   */
  face(tool, z, stepover, stepdown) {
    if (!_lib().job_face(this._live, tool._handle, z, stepover, stepdown)) _fail('job_face');
    this._keep(tool);
  }
  /**
   * Cut along `profile` from `top` to `bottom` in passes at most `stepdown` deep, with
   * `tool`: `side` "outside" the profile, "inside" it, or "on" its line; `climb` for climb
   * milling, else conventional; `open` to cut the outline as an open chain (only "on" its
   * line, and with no holes). Throws `BuildError` for any other `side`, or what the job
   * otherwise refuses.
   */
  contour(tool, profile, top, bottom, side = 'outside', stepdown = 1.0, climb = true, open = false) {
    const code = typeof side === 'string' ? _JOB_SIDES[side] : undefined;
    if (code === undefined) throw new BuildError("side must be 'outside', 'inside' or 'on'");
    if (!_lib().job_contour(this._live, tool._handle, profile._handle, top, bottom, code, stepdown, Boolean(climb), Boolean(open))) {
      _fail('job_contour');
    }
    this._keep(tool);
  }
  /**
   * Clear `profile` -- its holes left standing as islands -- from `top` to `bottom`, in
   * rings `stepover` apart (at most the tool's radius) and passes at most `stepdown` deep,
   * with `tool`. Throws for what the job refuses; a pocket too small for the tool is refused
   * by `gcode()`, naming the operation.
   */
  pocket(tool, profile, top, bottom, stepover, stepdown) {
    if (!_lib().job_pocket(this._live, tool._handle, profile._handle, top, bottom, stepover, stepdown)) _fail('job_pocket');
    this._keep(tool);
  }
  /**
   * Drill a hole at each (x, y) of `points` from `top` to `bottom` with `tool`, pecking
   * `peck` deep at a time (retracting between pecks), or straight to depth for `null`.
   * Throws `BuildError` for a point that is not two numbers, or what the job otherwise
   * refuses (a tool that is not a drill, no points, ...).
   */
  drill(tool, points, top, bottom, peck = null) {
    const pairs = Array.from(points, (p) => Array.from(p, Number));
    if (pairs.some((p) => p.length !== 2)) throw new BuildError('drill: every point must be (x, y)');
    const xy = Float64Array.from(pairs.flat());
    if (!_lib().job_drill(this._live, tool._handle, xy, pairs.length, top, bottom, peck == null ? NaN : peck)) _fail('job_drill');
    this._keep(tool);
  }
  /**
   * Recognise `part` and append the operations that make it: faced, contoured and
   * pocketed with `endMill` -- or with several end mills, largest first, given as an
   * array: each later one cleans what the earlier ones left (inside corners, regions too
   * narrow for them, holes no drill matches), and the report then lists only what none of
   * them reached -- its holes drilled with whichever of `drills` fits each -- a tool per
   * required diameter. `stepover` and `stepdown` default to the kernel's own
   * (`null`, the default, asks for that); `skin` (at least 0, default 0.3) is how far
   * above the part's lowest point the outline stops, so the part stays attached to the
   * stock -- `0` cuts through; `peck` defaults to none (a drill straight to depth).
   * `drills` may be one `Tool` as well as an array of them. Returns the machining's
   * `Report` (see `_report`) of what could not be cut. Throws for a `part` that is not a
   * solid handle, an `endMill` (or an element of an `endMill` array) or a drill that is not
   * a `Tool`, or what the kernel refuses (a drill as `endMill`, an empty array of end
   * mills, one not smaller than the one before, ...); the job changes only on success -- a refusal leaves it
   * exactly as it was. Throws when two of the offered tools share a number but are
   * different tools; `Job.tools` keeps only the tools the added operations use.
   * With `cornerRelief` true, every inside corner the smallest end mill leaves is relieved
   * with a dog-bone instead -- a cut along the corner's bisector until the cutter touches
   * the corner -- and reported as a `relief` item in place of the corner item; `false` (the
   * default) is the call without it. A single `endMill` is relieved as a list of one.
   */
  machine(part, endMill, drills = [], stepover = null, stepdown = null, skin = 0.3, peck = null, cornerRelief = false) {
    // Checked here, before the C call: a wrong type would otherwise hit `part._handle` or
    // `t._handle` on a value with no such property and raise a confusing TypeError of its
    // own -- `undefined` reaching the library as a handle, rather than this one naming the
    // argument (mirrors Python's `Job.machine`, which raises the same way for the same
    // reason).
    if (!(part instanceof Solid)) throw new TypeError(`machine: part must be a Solid, not ${_typeName(part)}`);
    let mills = null;
    if (!(endMill instanceof Tool)) {
      if (!Array.isArray(endMill)) throw new TypeError(`machine: endMill must be a Tool, not ${_typeName(endMill)}`);
      mills = endMill.slice();
      // a `null` goes on to the kernel, which names its index (`job_machine_with: null end mill 1`)
      mills.forEach((t, i) => {
        if (t !== null && !(t instanceof Tool)) throw new TypeError(`machine: endMill[${i}] must be a Tool, not ${_typeName(t)}`);
      });
    }
    const allMills = mills === null ? [endMill] : mills.filter((t) => t !== null);
    const tools = drills instanceof Tool ? [drills] : Array.from(drills);
    // A plain array of handles, not a Uint32Array: native handles are koffi pointer
    // objects (only the wasm backend's handles are small integers), and the wasm shim's
    // own `arg()` turns a plain array into a `Uint32Array` for that backend already.
    const handles = tools.map((t, i) => {
      if (!(t instanceof Tool)) throw new TypeError(`machine: drills[${i}] must be a Tool, not ${_typeName(t)}`);
      return t._handle;
    });
    // Two offered tools under one number must be one tool: a program can only pick one
    // tool per number (the kernel's own rule for an earlier operation's tool).
    const offered = new Map();
    for (const t of [...allMills, ...tools]) {
      const other = offered.get(t.number);
      if (other === undefined) offered.set(t.number, t);
      else if (other !== t && _toolKey(other) !== _toolKey(t)) {
        throw new Error(`machine: tool T${t.number} differs from the tool T${other.number} offered with it`);
      }
    }
    const before = this.operations().length;
    const options = [stepover == null ? NaN : stepover, stepdown == null ? NaN : stepdown, skin, peck == null ? NaN : peck];
    let handle;
    let name;
    if (cornerRelief) {
      const list = mills === null ? [endMill] : mills;
      handle = _lib().job_machine_relieved(this._live, part._handle, list.map((t) => (t === null ? null : t._handle)), list.length, handles, handles.length, ...options, true);
      name = 'job_machine_relieved';
    } else {
      handle = mills === null
        ? _lib().job_machine(this._live, part._handle, endMill._handle, handles, handles.length, ...options)
        : _lib().job_machine_with(this._live, part._handle, mills.map((t) => (t === null ? null : t._handle)), mills.length, handles, handles.length, ...options);
      name = mills === null ? 'job_machine' : 'job_machine_with';
    }
    const report = _report(handle, name);
    // only a tool a program uses can be found by its T number
    const used = new Set(this.operations().slice(before).map((op) => op.tool));
    this._keep(...[...allMills, ...tools].filter((t) => used.has(t.number)));
    return report;
  }
  /** Every operation added to this job so far, in order -- whether added by
   * `face`/`contour`/`pocket`/`drill` or by `machine`. */
  operations() { return _operations(_lib().job_operations(this._live), 'job_operations'); }
  /** The job as Grbl 1.1 programs, one per run of consecutive operations sharing a tool
   * (T1, T2, T1 gives three), each named `<name>-T<n>` (or `<name>-<k>-T<n>` for run `k`
   * of a repeated tool); an array of length 0 for a job with no operations. Throws for an
   * operation whose geometry the tool cannot cut (named by its index and kind). */
  gcode() { return _programs(_lib().job_gcode(this._live), 'job_gcode'); }
  /**
   * A CAMotics project at `filePath` and its files beside it, named after the project's
   * file stem (`out/part.camotics` writes `out/part-T1.nc`), not the job's name: each
   * program, a simulation copy of it (`.sim.nc`, which the project lists), and the project
   * last. Creates the directory. Returns the paths written, the project last, written here
   * (not by the library) with `fs`, exactly as the programs' own text reads. Throws for a
   * path with no file stem, what `gcode()` refuses, or a file that cannot be written.
   */
  writeCamotics(filePath) {
    filePath = String(filePath);
    const stem = path.basename(filePath, path.extname(filePath));
    _rejectNul(stem);
    const files = _programs(_lib().job_camotics(this._live, stem), 'job_camotics');
    const folder = path.dirname(filePath);
    try {
      fs.mkdirSync(folder, { recursive: true });
      const written = [];
      files.forEach((program, i) => {
        const at = i === files.length - 1 ? filePath : path.join(folder, program.name);
        fs.writeFileSync(at, program.text, 'utf8');
        written.push(at);
      });
      return written;
    } catch (e) {
      if (e instanceof BuildError) throw e;
      throw new BuildError(`job_camotics: ${filePath}: ${e.message}`);
    }
  }
}

const _assemblyFinalizer = typeof FinalizationRegistry === 'function'
  ? new FinalizationRegistry((h) => { try { _lib().assembly_free(h); } catch (_) { /* exiting */ } }) : null;

/**
 * A mutable tree of placements: a name, and zero or more solids or other assemblies placed in
 * it at a frame. Unlike `Solid`, placing shares rather than copies -- placing one assembly
 * under another does not snapshot it, so a later placement on the shared one shows up wherever
 * it already sits. `close()` frees this handle; it does not free what was placed in it if that
 * is still reachable from somewhere else (another assembly, or a variable still holding it).
 */
class Assembly {
  constructor(name) {
    this._handle = _checked(_lib().assembly_new(name), 'assembly_new');
    if (_assemblyFinalizer) _assemblyFinalizer.register(this, this._handle, this);
  }
  get _live() {
    if (!this._handle) throw new BuildError('assembly: closed');
    return this._handle;
  }
  get closed() { return this._handle === null; }
  close() {
    if (this._handle === null) return;
    const h = this._handle; this._handle = null;
    if (_assemblyFinalizer) _assemblyFinalizer.unregister(this);
    _lib().assembly_free(h);
  }
  [DISPOSE]() { this.close(); }
  /** This assembly's own name, given when it was made. */
  get name() { return _text(_lib().assembly_name(this._live)); }
  /**
   * Place `thing` (a `Solid` or another `Assembly`) at `frame` (twelve numbers, right-handed
   * and orthonormal) in this assembly, called `name` -- or, left null, `thing`'s own name
   * (`Solid.name`, or `"part"` for an unnamed solid, or the placed assembly's own `name`),
   * numbered past any already taken here (`"bolt"`, `"bolt 2"`, ...). An explicit `name`
   * already taken here throws. Placing an assembly that is this one, or anywhere above this
   * one in the tree already, throws, naming the cycle, since writing that out would never
   * terminate. Returns the placement's name.
   */
  place(thing, frame, name = null) {
    const f = _frame(frame);
    let raw, what;
    if (thing instanceof Solid) { raw = _lib().assembly_place_solid(this._live, thing._handle, f, name); what = 'assembly_place_solid'; }
    else if (thing instanceof Assembly) { raw = _lib().assembly_place_assembly(this._live, thing._live, f, name); what = 'assembly_place_assembly'; }
    else throw new BuildError('assembly: place takes a Solid or an Assembly');
    if (raw == null) _fail(what);
    return String(raw);
  }
  /**
   * Declare a rigid link called `name` over `placements` (any iterable of names of
   * placements of this assembly itself -- not of assemblies placed in it; give those their
   * own mechanism). A placed assembly in a link moves as one piece. An empty name, a name
   * taken by another link here, no placements, a placement named twice, one this assembly
   * does not have, or one already in another link throws; the assembly is left as it was.
   * Written as an AP242 kinematic link when this assembly is written; see spec
   * 2026-09-25-blacksmith-mechanisms-design.md for the rules. `placements` a bare string,
   * not a list, throws a `TypeError` before any call -- `link("x", "bolt")` would otherwise
   * silently split into the placements `b`, `o`, `l`, `t`.
   */
  link(name, placements) {
    const names = _names(placements, 'link', 'placements');
    if (!_lib().assembly_link(this._live, name, names, names.length)) _fail('assembly_link');
  }
  /**
   * Connect this assembly's links `start` and `end` (kept in that order) as a joint called
   * `name`, written as an AP242 kinematic joint. An empty name, a name taken by another
   * joint here, a link this assembly does not have, a link joined to itself, or a
   * (start, end) pair already joined throws; the reverse pair is a different joint.
   */
  joint(name, start, end) {
    if (!_lib().assembly_joint(this._live, name, start, end)) _fail('assembly_joint');
  }
  /**
   * Give joint `joint` its pair: `kind` (a name of the kind table -- `revolute`, `prismatic`,
   * `cylindrical`, `screw`, `spherical`, `spherical_with_pin`, `planar`, `universal`,
   * `homokinetic`, `fully_constrained` or `unconstrained`), the contact `frame` at rest, an
   * optional `endFrame` (the frame the pair reaches at its rest values; `frame` itself when
   * omitted), `ranges` (an array, one entry per freedom of `kind`, each `null` or a `[lower,
   * upper]` pair with either side `null`; omitted entirely for a kind that allows none), and
   * `pitch` (required and non-zero for `screw`, refused for any other kind). Throws the
   * kernel's own text when a rule refuses it; the assembly is then unchanged.
   */
  pair(joint, kind, frame, { endFrame = null, ranges = null, pitch = null } = {}) {
    const f = _frame(frame);
    const ef = endFrame == null ? null : _frame(endFrame);
    let lower = null, upper = null, hasLower = null, hasUpper = null, freedomCount = 0;
    if (ranges != null) {
      const rows = _ranges(ranges, 'pair');
      freedomCount = rows.length;
      // `ranges` being given -- even `[]` -- must reach the C ABI as non-null pointers
      // with count 0, never as "no ranges" (all four null, which only an omitted `ranges`
      // means); koffi passes a zero-length typed array's buffer as a null pointer, so a
      // trailing dummy element is padded on to keep it non-null. `freedomCount` below
      // stays the real (possibly 0) count, so the C ABI never reads the padding.
      const bufLen = freedomCount || 1;
      lower = new Float64Array(bufLen);
      upper = new Float64Array(bufLen);
      hasLower = new Uint8Array(bufLen);
      hasUpper = new Uint8Array(bufLen);
      rows.forEach((r, i) => {
        const lo = r == null ? null : r[0];
        const hi = r == null ? null : r[1];
        if (lo != null) { lower[i] = Number(lo); hasLower[i] = 1; }
        if (hi != null) { upper[i] = Number(hi); hasUpper[i] = 1; }
      });
    }
    const pitchArg = pitch == null ? NaN : Number(pitch);
    if (!_lib().assembly_pair(this._live, joint, kind, f, ef, lower, upper, hasLower, hasUpper, freedomCount, pitchArg)) _fail('assembly_pair');
  }
  /**
   * `pair` with the kind's own numbers in place of the pitch, for the coupled pairs: `kind` any
   * name `pair` takes, or `gear` or `rack_and_pinion`; `params` `[pitch]` for a screw,
   * `[pinionRadius]` for a rack and pinion, `[radiusFirst, radiusSecond, ratio]` or those plus
   * `[bevel, helicalAngle]` (radians) for a gear -- the ratio the second link's rotation over the
   * first's, signed (two meshing external gears turn opposite ways, so theirs is negative) --
   * and none for any other kind. `frame`, `endFrame` and `ranges` read as in `pair`. Throws the
   * kernel's own text when a rule refuses it (a wrong number of parameters among them); the
   * assembly is then unchanged.
   */
  pairWith(joint, kind, frame, { endFrame = null, ranges = null, params = [] } = {}) {
    const f = _frame(frame);
    const ef = endFrame == null ? null : _frame(endFrame);
    if (params == null || typeof params === 'string' || typeof params[Symbol.iterator] !== 'function') {
      throw new TypeError(`pairWith: params must be a list of numbers, not ${typeof params === 'string' ? JSON.stringify(params) : String(params)}`);
    }
    const values = Array.from(params, Number);
    let lower = null, upper = null, hasLower = null, hasUpper = null, freedomCount = 0;
    if (ranges != null) {
      const rows = _ranges(ranges, 'pairWith');
      freedomCount = rows.length;
      const bufLen = freedomCount || 1;   // non-null pointers for an empty `ranges`, as in `pair`
      lower = new Float64Array(bufLen);
      upper = new Float64Array(bufLen);
      hasLower = new Uint8Array(bufLen);
      hasUpper = new Uint8Array(bufLen);
      rows.forEach((r, i) => {
        const lo = r == null ? null : r[0];
        const hi = r == null ? null : r[1];
        if (lo != null) { lower[i] = Number(lo); hasLower[i] = 1; }
        if (hi != null) { upper[i] = Number(hi); hasUpper[i] = 1; }
      });
    }
    const raw = new Float64Array(values.length || 1);   // padded: koffi passes an empty array as null
    raw.set(values);
    if (!_lib().assembly_pair_with(this._live, joint, kind, f, ef, lower, upper, hasLower, hasUpper, freedomCount, raw, values.length)) _fail('assembly_pair_with');
  }
  /**
   * Add a named state to this assembly: `rows` is a `Map` or an iterable of `[joint, values]`
   * pairs, each joint's values in its pair's freedom order. Throws the kernel's own text when
   * a rule refuses it; the assembly is then unchanged. `rows` a bare string, or an item not a
   * `[joint, values]` pair, throws a `TypeError` before any call.
   */
  state(name, rows) {
    const entries = _stateRows(rows, 'state');
    const joints = entries.map(([joint]) => joint);
    const counts = Uint32Array.from(entries, ([, values]) => values.length);
    const flat = Float64Array.from(entries.flatMap(([, values]) => values));
    if (!_lib().assembly_state(this._live, name, joints, counts, flat, entries.length)) _fail('assembly_state');
  }
  /**
   * This assembly with its mechanism posed, as a NEW `Assembly` the caller owns (`close()` it);
   * this one is unchanged either way. `values` is a `Map`, a plain object, or an iterable of
   * `[joint, value]` pairs (or omitted): a joint a path of placement names then the joint's name
   * joined by "/" (a "/" or backslash inside a name escaped with a backslash), or an array of the names,
   * which this escapes and joins; a value one number for a one-freedom joint, else a list in the
   * pair's freedom order (radians, the assembly's units). `state` is a state's path (a string or
   * an array of names), applied first and overridden row by row; `ground` one of this assembly's
   * own links, held fixed. A sub-assembly no key reaches is shared with this one. Throws the
   * kernel's own text when it refuses.
   */
  posed(values = null, { state = null, ground = null } = {}) {
    const rows = _posedRows(values);
    const pad = (a) => (a.length || _wasm() ? a : new a.constructor(1));   // koffi passes an empty array as null; the count says 0
    const joints = pad(rows.map(([joint]) => joint));
    const counts = pad(Uint32Array.from(rows, ([, v]) => v.length));
    const flat = pad(Float64Array.from(rows.flatMap(([, v]) => v)));
    const handle = _lib().assembly_posed(this._live, joints, counts, flat, rows.length,
      state == null ? null : _jointPath(state), ground == null ? null : String(ground));
    if (!handle) _fail('assembly_posed');
    const posed = Object.create(Assembly.prototype);
    posed._handle = handle;
    if (_assemblyFinalizer) _assemblyFinalizer.register(posed, handle, posed);
    return posed;
  }
  /**
   * The placement path of every solid under this assembly, at any depth: depth first,
   * placements in order, names joined by "/" with a "/" or backslash inside a name escaped with
   * a backslash (as `posed`'s keys). The index `sweptClash`'s rows use.
   */
  parts() {
    const l = _lib();
    if (_wasm()) {
      // the wasm lists them in one call (a JS string needs no free)
      const names = l.assembly_parts(this._live);
      if (names == null) _fail('assembly_parts');
      return Array.from(names, String);
    }
    const count = l.assembly_part_count(this._live);
    const out = [];
    for (let i = 0; i < count; i++) {
      // owned text: koffi decodes it and hands the pointer back to `string_free`
      const path = l.assembly_part_path(this._live, i);
      if (path == null) _fail('assembly_part_path');
      out.push(String(path));
    }
    return out;
  }
  /**
   * Every pair of this assembly's solids (indexed as `parts()` lists them) that penetrates,
   * touches or comes within `clearance` of the other anywhere while this assembly's own
   * mechanism moves through `keyframes`, as `SweptClash` rows in pair order. Each keyframe is
   * `posed`'s `values` (a `Map`, a plain object, or an iterable of `[joint, value]` pairs), and
   * every keyframe names the same joints with as many values each (the first fixes their
   * order); time runs in keyframe units, keyframe `k` at time `k`. Between two keyframes each
   * joint value moves linearly and each link is posed from those values, so a link swinging
   * about a joint goes round its arc, not along its chord. Only this assembly's own joints
   * move: a sub-assembly rides the link its placement is in. `ground` is one of this
   * assembly's links held fixed (null for its default); solids in no link stay still. Pairs on
   * two links a joint joins are not tested unless `joined`; `allowed` pairs of part indices,
   * flattened as `clash`'s (`[a0, b0, a1, b1, ...]`), are never tested. `tolerance` meshes the
   * parts; `resolution` and `maxSteps` as `Collider.sweptClash`. Throws `BuildError` in the
   * kernel's `swept_clash:` words -- here, before the library is called, for keyframes naming
   * different joints, a joint given twice, a joint with a different number of values than in
   * keyframe 0, or an `allowed` as `clash` refuses it.
   */
  sweptClash(keyframes, { clearance = 0, tolerance = 0.05, resolution = 1e-3, maxSteps = 100000, allowed = [], ground = null, joined = false } = {}) {
    const rows = Array.from(keyframes, (k) => _posedRows(k));
    const first = rows.length ? rows[0] : [];
    const keys = first.map(([j]) => j);
    const counts = first.map(([, v]) => v.length);
    const flat = first.flatMap(([, v]) => v);
    rows.slice(1).forEach((row, i) => {
      // C takes one joint set for every keyframe: a later keyframe naming other joints is
      // refused here, in the kernel's words, before C is called
      const k = i + 1;
      const named = row.map(([j]) => j);
      for (const j of keys.concat(named)) {
        if (!named.includes(j)) throw new BuildError(`swept_clash: joint '${j}' is in keyframe 0 and not in keyframe ${k}`);
        if (!keys.includes(j)) throw new BuildError(`swept_clash: joint '${j}' is in keyframe ${k} and not in keyframe 0`);
      }
      const twice = named.find((j, n) => named.indexOf(j) !== n);
      if (twice !== undefined) throw new BuildError(`swept_clash: joint '${twice}' is given twice`);
      const values = new Map(row);
      keys.forEach((j, n) => {
        const v = values.get(j);
        if (v.length !== counts[n]) throw new BuildError(`swept_clash: joint '${j}' has ${counts[n]} values in keyframe 0 and ${v.length} in keyframe ${k}`);
        flat.push(...v);
      });
    });
    const allowedArr = _clashAllowed(allowed, 'swept_clash');
    const pad = (a) => (a.length || _wasm() ? a : new a.constructor(1));   // koffi passes an empty array as null; the count says 0
    const h = _lib().assembly_swept_clash(this._live, pad(keys), pad(Uint32Array.from(counts)), keys.length, pad(Float64Array.from(flat)),
      rows.length, ground == null ? null : String(ground), _tol(tolerance), clearance, resolution, maxSteps, pad(allowedArr), allowedArr.length / 2, Boolean(joined));
    return _sweptClashesOf(_checked(h, 'assembly_swept_clash'));
  }
  /**
   * Add a named motion sequence over this assembly's states: `segments` are `[state name,
   * parameter, interpolation]` rows, the interpolation one of `'undefined'`, `'discontinuous'`,
   * `'synchronous'` or `'linear'`, and `seconds` writes the parameter's unit as the second.
   * Closed or open is the last segment's interpolation: closed unless it is `'discontinuous'`.
   * Throws the kernel's own text when a rule refuses it; the assembly is then unchanged.
   */
  sequence(name, segments, seconds = false) {
    const rows = Array.from(segments, (row, i) => {
      if (row == null || typeof row[Symbol.iterator] !== 'function') throw new TypeError(`sequence: segments[${i}] is not a [state, t, interpolation] row`);
      const [state, t, interpolation] = row;
      return [String(state), Number(t), String(interpolation)];
    });
    const states = rows.map(([state]) => state);
    const ts = Float64Array.from(rows, ([, t]) => t);
    const interpolations = rows.map(([, , interpolation]) => interpolation);
    if (!_lib().assembly_sequence(this._live, name, states, ts, interpolations, rows.length, Boolean(seconds))) _fail('assembly_sequence');
  }
  /**
   * Declare this assembly's base link. Throws the kernel's own text when a rule refuses it
   * (an empty name, one this assembly does not have, or one already declared); the assembly
   * is then unchanged.
   */
  base(link) {
    if (!_lib().assembly_base(this._live, link)) _fail('assembly_base');
  }
  /**
   * This assembly, and everything placed under it, as one STEP file: this assembly the root
   * product, each sub-assembly and each distinct part (the same solid with the same paint and
   * name) written once, each placement an occurrence named as it was placed. `schema` and
   * `unit` as `writeStepText`. Throws where this assembly, or a sub-assembly reachable from it,
   * places nothing -- a reader would never show it.
   */
  stepText(schema = null, unit = 'mm') {
    if (!(unit in UNITS)) throw new BuildError(`unit must be one of ${Object.keys(UNITS).sort().join(', ')}`);
    const text = _lib().assembly_step(this._live, _schemaText(schema), UNITS[unit]);
    if (text == null) _fail('assembly_step');
    return text;
  }
  /** `stepText` written to `filePath`. */
  step(filePath, schema = null, unit = 'mm') { fs.writeFileSync(filePath, this.stepText(schema, unit), 'utf8'); }
  /** This assembly as a reader `Scene`, through STEP text and `cadaclysm.openMemory` -- `Solid.toScene`'s own door, over the whole tree instead of one solid. */
  /**
   * This assembly, and everything placed under it, as one Rhino `.3dm`: each distinct part (as
   * `stepText` counts them) a block holding its body, each sub-assembly a block of references
   * to what it places -- nested assemblies are nested blocks -- and this assembly's own
   * placements references at the top of the file, on a layer named after it. Each reference
   * is named as its placement was. `unit` and the warnings as `rhino3dmBytes`. Throws, as
   * `stepText` does, for an assembly reachable from this one that places nothing.
   */
  rhino3dmBytes(unit = 'mm') {
    if (!(unit in UNITS)) throw new BuildError(`unit must be one of ${Object.keys(UNITS).sort().join(', ')}`);
    const len = _sizeSlot();
    return _taken3dm(_lib().assembly_3dm_bytes(this._live, UNITS[unit], len), len, 'assembly_3dm_bytes');
  }
  /** `rhino3dmBytes` written to `filePath` by the library itself, which names the file in its refusal when it cannot. */
  write3dm(filePath, unit = 'mm') {
    if (_wasm()) { _write3dmBytes(filePath, this.rhino3dmBytes(unit), 'assembly_3dm'); return; }
    if (!(unit in UNITS)) throw new BuildError(`unit must be one of ${Object.keys(UNITS).sort().join(', ')}`);
    if (!_lib().assembly_3dm(this._live, String(filePath), UNITS[unit])) _fail('assembly_3dm');
    _warn3dm();
  }
  toScene(schema = null) {
    let cad;
    try { cad = require('./cadaclysm'); } catch (e) { throw new BuildError(`toScene needs the reader module beside this file: ${e.message}`); }
    const schemaPath = schema != null && _isSchemaFile(String(schema)) ? String(schema) : null;
    return cad.openMemory(this.stepText(schema), 'stp', { schema: schemaPath, name: 'assembly.stp' });
  }
}

function _reader(what) {
  try { return require('./cadaclysm'); } catch (e) { throw new BuildError(`${what} needs the reader module beside this file: ${e.message}`); }
}
function _label(node) { return node.name || node.kind || String(node.index); }
function _isIdentity(m) { return m.every((row, i) => row.every((v, j) => v === (i === j ? 1 : 0))); }
/** The node's brep as a solid, shared, or null where it has none. */
function _fromBrep(node, what) {
  const brep = node.brep;
  if (!brep) return null;
  try {
    const cad = _reader('fromNode');
    return new Solid(_checked(_lib().from_brep(brep.pointer, cad.Brep.layoutId()), what));
  } finally {
    brep.release();
  }
}
/** How the loaded library lays a brep out in memory; `Solid.fromNode` works only where it equals the reader's `Brep.layoutId()`. */
function brepLayoutId() { return _text(_lib().brep_layout_id()); }
/** The pair kind `kind`'s freedom count (`spherical` 3, `revolute` 1, `fully_constrained` 0,
 *  and 0 for a name not in the kind table). */
function pairFreedomCount(kind) { return Number(_lib().pair_freedom_count(String(kind))); }

// ---- the FEM surface mesh -------------------------------------------------------

/**
 * One B-rep edge of a FEM mesh: the chain of nodes along it, and where that chain
 * breaks. Plain data, copied out of the handle.
 *
 * `nodes` are this mesh's node indices in order along the edge, its end vertices
 * included; a closed edge repeats no node. **`runs` says where the chain breaks**:
 * read `nodes.subarray(runs[i], runs[i + 1])` (the last run to the end) as one
 * polyline and join nothing across a run boundary -- `chains()` does exactly that.
 * The two ends either side of a boundary are two points of the edge with no mesh
 * edge between them. `[0]` is the ordinary answer, and a caller reading `nodes` as
 * one polyline without looking here silently jumps the gap.
 *
 * `faces` is `[faceA, faceB]` and `ends` is `[endA, endB]`, the second of each being
 * `NONE` where there is none -- an open sheet's rim, or both ends at one vertex.
 * **`0` is a real face and a real vertex, not a sentinel**, and `faces` numbers the
 * solid's faces as `Solid.faceKind` does. `closed` where the nodes make one loop,
 * never with more than one run; `seam` where one face bounds the edge twice, and both
 * `faces` are then that same face.
 *
 * `id` is **the solid's own edge id**, not this mesh's edge index: `FemMesh.edges()`
 * is a densely renumbered subset of the solid's edges, with every edge collapsed to a
 * point left out, so a sphere -- whose two pole runs collapse -- reports its seam as
 * edge 0 with an `id` of 1. Everything else that names an edge means the index. It is
 * not a row of `Solid.edges()` either, that table being the solid's edges grouped by
 * geometry; the id names the topological edge, which is what the `.msh` entities and
 * the censuses speak in.
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

/** A `CadaclysmBlacksmithFemEdge` as a `FemEdge`. */
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
 * One B-rep vertex of a FEM mesh: the node the mesh put there, if any, and where the
 * topology says it is, if that is known. Plain data.
 *
 * `node` is the mesh node at this vertex, or `NONE` where the mesh has none there.
 * **A sentinel here is ordinary, not a fault**: the analysis rebuilds a vertex
 * wherever two trims meet, so a sphere has 48 of them where the mesh has 2 points,
 * and a caller walking these skips the sentinel rather than treating it as a gap.
 *
 * `point` is where the topology says the vertex is, in the same space and under the
 * same placement as `FemMesh.nodes()`. **Meaningless unless `hasPosition`**: it is
 * `[0, 0, 0]` then, a point no geometry has and one a solver would read as a node at
 * the origin.
 */
class FemVertex {
  constructor(node, point, hasPosition) { this.node = node; this.point = point; this.hasPosition = hasPosition; }
}

/** A `CadaclysmBlacksmithFemVertex` as a `FemVertex`. */
function _femVertexOf(raw) {
  return new FemVertex(raw.node, Float64Array.from(raw.point), Boolean(raw.has_position));
}

/**
 * One flattened crack census, row by row: `read(i, a, b, edge)` fills three
 * `Uint32Array`s of one and says whether it could. The shape `openEdges()` and
 * `foldedEdges()` share, so the two cannot drift -- and a pure function, so
 * `test/fem.test.js` can drive it over rows no fixture in this repository produces.
 *
 * `what` is the C entry point's own name, as every other refusal in this module spells
 * one (`fem_mesh_edge 3`) and as `cadaclysm_blacksmith.py`'s own `_census` does. The
 * reader module says `fem mesh open edge 3` instead, following *its* Python twin: the two
 * ABIs' wrappers word their errors differently, and each one matches its own side.
 */
function _censusRows(read, count, what) {
  const a = new Uint32Array(1), b = new Uint32Array(1), edge = new Uint32Array(1);
  const out = [];
  for (let i = 0; i < count; i++) {
    if (!read(i, a, b, edge)) _fail(`${what} ${i}`);
    out.push([a[0], b[0], edge[0]]);
  }
  return out;
}

// The same backstop as a `Solid`'s: a `FemMesh` the collector reaps unfreed is freed
// then; `free()` is the contract.
const _femFinalizer = typeof FinalizationRegistry === 'function'
  ? new FinalizationRegistry((h) => { try { _lib().fem_mesh_free(h); } catch (_) { /* exiting */ } }) : null;

/**
 * One solid meshed for a solver: nodes welded by bits, triangles wound outward, every
 * node tagged with the lowest-dimension B-rep entity it lies on, and every crack
 * reported rather than closed. Built by `Solid.femMesh`, and **owned by you**:
 * `free()` it, or `using` it where the runtime supports explicit resource management.
 *
 * **Every array here is a copy**, decoded at call time as `Solid.mesh`'s typed arrays
 * are, not a view into the library's memory -- this wrapper has no borrowed-view
 * machinery at all. So an array in hand needs no care: it survives `free()`,
 * `Solid.close()` and the collector. The price is that each call copies again, so hold
 * the array rather than asking twice in a loop.
 *
 * A handle rather than a snapshot all the same, because the counts and the records are
 * read through it: a call on a freed mesh throws. The memory behind it is **this**
 * object's and not the solid's -- `Solid.close()` does not free a FEM mesh, and the
 * solid's tessellation cache, meshed again at another tolerance, does not touch it.
 * `Solid.mesh`'s views are the other shape, and are stale after either.
 */
class FemMesh {
  constructor(handle) {
    this._pointer = _checked(handle, 'fem_mesh');
    if (_femFinalizer) _femFinalizer.register(this, handle, this);
    // Read once, here: every pointer in the view is built with the handle and good
    // until it is freed, so asking again per accessor would be one C call per array
    // for the same answer.
    const raw = {};
    if (!_lib().fem_mesh_view(this._pointer, raw)) {
      const why = _lastError() || 'fem_mesh_view';
      this.free();
      throw new BuildError(why);
    }
    this._raw = raw;
  }
  get _handle() { if (this._pointer === null) throw new BuildError('fem mesh: freed'); return this._pointer; }
  /** The view, the handle checked first: every pointer in it is the handle's, and a freed handle's point at nothing. */
  get _live() { if (this._pointer === null) throw new BuildError('fem mesh: freed'); return this._raw; }
  /** Whether `free()` has run. */
  get freed() { return this._pointer === null; }
  /** Give the mesh back. Idempotent; the collector does it otherwise. Arrays already copied out are unaffected. */
  free() {
    if (this._pointer === null) return;
    const h = this._pointer; this._pointer = null;
    if (_femFinalizer) _femFinalizer.unregister(this);
    _lib().fem_mesh_free(h);
  }
  [DISPOSE]() { this.free(); }
  // -- the flat arrays, copied
  /** Every node's position, three doubles each: placed by `Solid.femMesh`'s placement, in the solid's own coordinates otherwise. */
  nodes() { const raw = this._live; return _doublesAt(raw.nodes, raw.node_count * 3) ?? new Float64Array(0); }
  /** Three node indices a triangle, wound outward -- a mirroring placement is wound back. */
  triangles() { const raw = this._live; return _uint32s(raw.triangles, raw.triangle_count * 3) ?? new Uint32Array(0); }
  /** Which face each triangle lies on, one per triangle: the same faces `Solid.faceKind` names. */
  triangleFace() { const raw = this._live; return _uint32s(raw.triangle_face, raw.triangle_count) ?? new Uint32Array(0); }
  /** What each node lies on -- 0 a vertex, 1 an edge, 2 a face -- one per node: the lowest-dimension entity, as Gmsh classifies. `nodeEntity()` says which. */
  nodeKind() { const raw = this._live; return _uint32s(raw.node_kind, raw.node_count) ?? new Uint32Array(0); }
  /** Which vertex, edge or face each node lies on, by the matching `nodeKind()`: an index into `vertices()`, into `edges()`, or into the solid's faces. */
  nodeEntity() { const raw = this._live; return _uint32s(raw.node_entity, raw.node_count) ?? new Uint32Array(0); }
  // -- the topology
  /** The solid's faces -- the same faces `Solid.faces` counts. */
  get faceCount() { return this._live.face_count; }
  /**
   * One `FemEdge` per B-rep edge, in the order a `nodeKind()` of 1 indexes them.
   * **Not `Solid.edges()`' numbering**: these are the manifold analysis's, ascending
   * by edge id.
   */
  edges() {
    const l = _lib(), h = this._handle, out = [];
    for (let i = 0, n = this._raw.edge_count; i < n; i++) {
      const raw = {};
      if (!l.fem_mesh_edge(h, i, raw)) _fail(`fem_mesh_edge ${i}`);
      out.push(_femEdgeOf(raw));
    }
    return out;
  }
  /** One `FemVertex` per B-rep vertex, in the order a `nodeKind()` of 0 indexes them. */
  vertices() {
    const l = _lib(), h = this._handle, out = [];
    for (let i = 0, n = this._raw.vertex_count; i < n; i++) {
      const raw = {};
      if (!l.fem_mesh_vertex(h, i, raw)) _fail(`fem_mesh_vertex ${i}`);
      out.push(_femVertexOf(raw));
    }
    return out;
  }
  /**
   * Every crack, as `[a, b, brepEdge]`: a directed mesh edge `(a, b)` with no
   * `(b, a)`, and the B-rep edge both nodes lie on or `NONE` where they share none.
   *
   * **Empty unless the solid's topology is closed**, whose mesh is otherwise not asked
   * about at all: an open sheet from `Solid.face`, `faceSheet`, `dropFaces` or
   * `extrudeOpen` makes no claim to enclose anything, so its rim is not a crack. Such
   * a solid reports `watertight` false with this and `foldedEdges()` both empty, and
   * **that trio of answers together** says "not asked", not "nothing found". That rule
   * holds here without exception, where the reader library has one: every solid has a
   * B-rep behind it, so this library has no mesh-only body.
   */
  openEdges() {
    const l = _lib(), h = this._handle;
    return _censusRows((i, a, b, e) => l.fem_mesh_open_edge(h, i, a, b, e), this._live.open_edge_count, 'fem_mesh_open_edge');
  }
  /**
   * Every fold, as `openEdges()` reports a crack: a directed mesh edge used by more
   * than one triangle.
   *
   * **A solid can be folded without being open** -- one no thicker than a line leaves
   * no hole for an open edge to find -- and the closure census's own known-bad bodies
   * are folds rather than open cracks. A caller that checks `openEdges()` alone calls
   * such a solid sound. Empty under the same rule.
   */
  foldedEdges() {
    const l = _lib(), h = this._handle;
    return _censusRows((i, a, b, e) => l.fem_mesh_folded_edge(h, i, a, b, e), this._live.folded_edge_count, 'fem_mesh_folded_edge');
  }
  /**
   * Every pair of triangles that pass through each other, as `[a, b]` with `a < b`,
   * sorted: an edge of one through the other's interior. Their faces are
   * `triangleFace()[a]` and `[b]`.
   *
   * **Computed for every solid, open or closed.** The census `watertight`,
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
      if (!l.fem_mesh_crossing(h, i, a, b)) _fail(`fem_mesh_crossing ${i}`);
      out.push([a[0], b[0]]);
    }
    return out;
  }
  // -- the summary
  /** The topology is closed and the welded mesh is too. **False for every solid whose topology is not closed**; read `openEdges()` for what an empty census beside a false here does and does not mean. */
  get watertight() { return Boolean(this._live.watertight); }
  /**
   * **Always false here**, and kept so the two ABIs hand back one struct: a `Solid`
   * always has a B-rep, so this library has no mesh-only body to report. The reader's
   * `Node.femMesh` sets it for a node with no B-rep, where it also says which space the
   * mesh is in and whether the crack census spoke from the triangles alone.
   */
  get fromMesh() { return Boolean(this._live.from_mesh); }
  /** The smallest interior angle of any triangle, in degrees. */
  get minAngle() { return this._live.min_angle; }
  /** The triangle with that angle: an index into `triangles()`. */
  get worstTriangle() { return this._live.worst_triangle; }
  /**
   * The longest triangle edge, placed. **The figure to check against `Solid.femMesh`'s
   * `maxSize`, and the only one that says what the mesh actually is**: `maxSize` bounds
   * the boundary segments and merely targets the interior, and one small enough to reach
   * the mesher's own piece and station ceilings is not honoured at all.
   */
  get longestEdge() { return this._live.longest_edge; }
  // -- out
  /**
   * The mesh as Gmsh 4.1 ASCII `.msh` text: an entity per B-rep vertex, edge and face,
   * a volume where the solid closes, and a physical group naming each.
   *
   * **On this side of the ABI the library's text is owned and handed over**, released
   * by this wrapper as every other text this library writes -- `stepText`, `satText`,
   * `brepText`. Two asks give two independent texts, and neither dies with the handle.
   * The reader library's own `mshText` is the other way round: it borrows a slot on its
   * handle, replaced by the next call and gone with the mesh. A reader porting one
   * side's reasoning onto the other leaks or double-frees.
   *
   * **The unlicensed notice is printed here**, on this writer and on `saveMsh`, and
   * **not** by `Solid.femMesh`: meshing is not a licensed output and the `.msh` file is,
   * which is where `satText` and `brepText` put theirs too. The reader library notices
   * in its constructor instead and on neither `.msh` call.
   *
   * Throws `BuildError` for a mesh the writer refuses, naming the field it cannot
   * honour, and for a freed handle.
   */
  mshText() {
    const text = _lib().fem_mesh_msh_text(this._handle);
    if (text == null) _fail('fem_mesh_msh_text');
    return text;
  }
  /** `mshText()` written to `filePath` by the library itself, replacing any file there. Prints the unlicensed notice; see `mshText`. */
  saveMsh(filePath) {
    if (!_lib().fem_mesh_save_msh(this._handle, String(filePath))) _fail(`fem_mesh_save_msh: ${filePath}`);
  }
  toString() {
    if (this.freed) return 'FemMesh(freed)';
    const raw = this._raw;
    return `FemMesh(nodes=${raw.node_count}, triangles=${raw.triangle_count}, watertight=${Boolean(raw.watertight)})`;
  }
}

/** A `CadaclysmBlacksmithFemOptions` object: the library's own defaults, then `tolerance` and `maxSize`. */
function _femOptions(tolerance, maxSize) {
  const o = {};
  // `init` writes `sizeof(CadaclysmBlacksmithFemOptions)` bytes as the *library* knows
  // that type, into the struct declared at the top of this file -- which is why
  // `tests/bindings.rs` pins the two field for field. `size` is then set to this
  // declaration's own sizeof, which is what the growth rule asks of a caller.
  //
  // Neither happens in a browser: the wasm has no `fem_options_init` export (its
  // `fem_mesh` takes the two numbers as scalars, both set below), exactly as
  // `_svgOptions` finds for `svg_options_init`, and there is no koffi there to ask a
  // struct's size of. `size` is dropped by the shim, so leaving it out costs nothing.
  if (!_wasm()) {
    _lib().fem_options_init(o);
    o.size = koffi.sizeof(CadaclysmBlacksmithFemOptions);
  }
  o.tolerance = Number(tolerance);
  o.max_size = Number(maxSize);
  return o;
}

// ---- selecting ------------------------------------------------------------------

const Axis = Object.freeze({ X: 0, Y: 1, Z: 2 });

/** Which face: furthest along an axis, furthest against it, by outward normal, or by index. */
class Selector {
  constructor(kind, v = null, index = 0) { this._kind = kind; this._v = v; this._index = index; }
  static max(axis) { return new Selector(0, null, axis); }
  static min(axis) { return new Selector(1, null, axis); }
  static normal(direction) { return new Selector(2, _doubles(direction, 3, 'normal'), 0); }
  static index(i) { return new Selector(3, null, Number(i)); }
  _raw() { return { kind: this._kind, v: this._v, index: this._index }; }
}

/**
 * One edge's, or one intersection chain's, exact curve as plain data copied out
 * (`Edge.curve`, `Chain.curve`): `kind` is `line`, `circle`, `ellipse`, `parabola`, `hyperbola` or `nurbs`.
 *
 * `t0..t1` is the edge's parameter range on its own curve: a line's fraction (0..1 over
 * `origin -> origin + x`, where `x` is the full `to - from`, NOT unit -- so
 * `point(t) = origin + x*t`); a circle's or ellipse's angle in radians about `origin` in
 * the `x, y` plane (`point(t) = origin + x*radius*cos(t) + y*radius2*sin(t)`,
 * `radius2 = radius` for a circle); a NURBS's knot parameter
 * (`knots[degree] <= t0 < t1 <= knots[n]`). Frame vectors `x, y, z` are unit for conics;
 * for a line `x` is the direction with length = the line's length and `y, z` are zero.
 *
 * `origin`, `x`, `y`, `z` are `[x, y, z]` arrays (all zero for a NURBS, whose radii are 0
 * too). For a conic or a line `degree` is 0 and `knots`, `poles` are empty; for a NURBS
 * `knots` is the knot vector, `poles` an array of `[x, y, z]` points
 * (`knots.length === poles.length + degree + 1`) and `weights` one per pole, or null for
 * a non-rational (plain B-spline) curve -- null for a conic or a line too.
 */
class Curve {
  constructor(kind, origin, x, y, z, radius, radius2, t0, t1, degree, knots, poles, weights) {
    this.kind = kind; this.origin = origin; this.x = x; this.y = y; this.z = z;
    this.radius = radius; this.radius2 = radius2; this.t0 = t0; this.t1 = t1; this.degree = degree;
    this.knots = knots; this.poles = poles; this.weights = weights;
  }
  /**
   * This curve as a value: a line `Line(origin, origin + x)`; a circle a `Circle` over a full
   * turn, else the `Arc` over `t0..t1`; an ellipse its whole `Ellipse` (the range stays here:
   * there is no elliptical-arc value); any other kind null.
   */
  get value() {
    const frame = [...this.origin, ...this.x, ...this.y, ...this.z];
    if (this.kind === 'line') return new Line(this.origin, this.origin.map((o, i) => o + this.x[i]));
    if (this.kind === 'circle') {
      if (this.t1 - this.t0 >= 2 * Math.PI - 1e-12) return new Circle(frame, this.radius);
      return new Arc(frame, this.radius, [this.t0, this.t1]);
    }
    if (this.kind === 'ellipse') return new Ellipse(frame, this.radius, this.radius2);
    return null;
  }
}

function _curveOf(raw) {
  const p = (q) => [q.x, q.y, q.z];
  const knots = Array.from(_doublesAt(raw.knots, raw.knot_count) ?? []);
  const flat = _doublesAt(raw.poles, raw.pole_count * 3) ?? new Float64Array(0);
  const poles = [];
  for (let k = 0; k < flat.length; k += 3) poles.push(Array.from(flat.subarray(k, k + 3)));
  const weights = raw.weights == null ? null : Array.from(_doublesAt(raw.weights, raw.pole_count));
  return new Curve(_text(raw.kind), p(raw.origin), p(raw.x), p(raw.y), p(raw.z), raw.radius, raw.radius2, raw.t0, raw.t1, raw.degree, knots, poles, weights);
}

/**
 * One edge of a solid as plain data: its index (what `fillet` takes), curve kind, the faces
 * meeting on it, its segments' ends, and its exact `Curve` (null for an edge with none,
 * kind `other`).
 */
class Edge {
  constructor(index, kind, faces, segments, curve = null) { this.index = index; this.kind = kind; this.faces = faces; this.segments = segments; this.curve = curve; }
  get isLine() { return this.kind === 'line'; }
  /** Unit direction of a line edge (from its first segment), else null. */
  get direction() {
    if (!this.isLine || !this.segments.length) return null;
    const [a, b] = this.segments[0];
    const d = [b[0] - a[0], b[1] - a[1], b[2] - a[2]];
    const n = Math.hypot(...d);
    return n > 0 ? d.map((x) => x / n) : null;
  }
}

/**
 * Where a hit lands on one side: a profile's `loopIndex` (0 the boundary or the open chain, then
 * the holes in the order they were added), `segment`, and `t` from 0 to 1 along it, with `face`
 * NONE -- or a solid's `face` at (`u`, `v`), with `loopIndex` and `segment` NONE.
 */
class Spot {
  constructor(loopIndex, segment, t, face, u, v) {
    this.loopIndex = loopIndex; this.segment = segment; this.t = t;
    this.face = face; this.u = u; this.v = v;
  }
}

/**
 * What `Solid.hits` found, copied out: `hits` (`Hit`, ordered along the profile; `aStart`/`aEnd`
 * on the profile, `bStart`/`bEnd` on the solid's faces: `face` at (`u`, `v`)) and `pieces`
 * (`Piece`, empty for an open body).
 */
class SolidHits {
  constructor(hits, pieces) { this.hits = hits; this.pieces = pieces; }
}

/**
 * One stretch of a profile loop between two cuts (`SolidHits.pieces`): `inside` (by its middle's
 * winding number over the body; a piece lying on the surface is inside), `start`/`end` (profile
 * `Spot` values -- a segment join reads as the next segment's start `(k + 1, 0)`, an open chain
 * runs from `(0, 0)` to `(n - 1, 1)`; a loop no hit cuts is one closed piece) and `profile`, the
 * piece's own open chain (what `SweepPath.along(.., open = true)` sweeps).
 */
class Piece {
  constructor(inside, start, end, profile) { this.inside = inside; this.start = start; this.end = end; this.profile = profile; }
}

/**
 * What `Solid.intersect` found, copied out: `chains` (one per face pair per branch) and
 * `overlaps` (one per coincident face pair). Both empty where the solids do not meet.
 */
class Intersection {
  constructor(chains, overlaps) { this.chains = chains; this.overlaps = overlaps; }
}

/**
 * One branch of one face pair's crossing (`Intersection.chains`): `points` (`[x, y, z]`
 * arrays in walk order; a closed chain does not repeat its first point), `closed`, `faces`
 * (`[face in a, face in b]`), `tangent` (the surfaces near-tangent along it, or the snap
 * unsettled -- the points their best estimate) and `curve`, its exact `Curve` over the
 * chain's own `t0..t1`, or null where the kernel found none. A chain may stop at a face
 * boundary or a closed curve's seam and continue as another: join chains by matching ends.
 */
class Chain {
  constructor(points, closed, faces, tangent, curve = null) {
    this.points = points; this.closed = closed; this.faces = faces; this.tangent = tangent; this.curve = curve;
  }
}

/**
 * A face of `a` and a face of `b` that coincide (`Intersection.overlaps`): `faces`
 * (`[face in a, face in b]`) and `loops`, the shared region's rings as arrays of `[x, y, z]`
 * points (outer first, holes after; each ring closed without repeating its first point) --
 * empty for a partial overlap of curved faces whose outlines cross.
 */
class Overlap {
  constructor(faces, loops) { this.faces = faces; this.loops = loops; }
}

/**
 * One thing wrong with one argument (`Solid.check`): `kind` names it, `argument` is 0 for the
 * solid checked and 1 for `other`, and `index`, `other` and `size` are what the kind gives
 * (null, null and 0 where it gives none): `open` -- the edge (null for a trim naming none),
 * its face, its length; `face_kind` -- the face; `short_edge` -- the edge, its length;
 * `collapsed_edge` -- the trim; `sliver_face` -- the face, its width; `tiny_face` -- the face,
 * its area; `tiny_body` -- its diagonal; `small_hole` -- the loop, its area or width;
 * `loose_edge` -- the edge, how far its sides part; `self_intersection` -- the two faces (one
 * face twice for a fold), the crossing's length; `self_overlap` -- the two faces.
 */
class Finding {
  constructor(kind, argument, index, other, size) {
    this.kind = kind; this.argument = argument; this.index = index; this.other = other; this.size = size;
  }
}

/** `box` as six contiguous doubles (lo then hi): bit-compatible with
 *  `CadaclysmBlacksmithBox`, which is how a `Box` crosses *into* a call -- as a frame
 *  does, twelve doubles rather than a `Frame` object. */
function _boxWords(box) { return Float64Array.of(...box.lo, ...box.hi); }
function _boxOf(raw) { return new Box(Array.from(raw.lo), Array.from(raw.hi)); }

/**
 * An axis-aligned box: `lo` and `hi`, three-tuples. The broad phase's own shape
 * (`Solid.boundsBox`, `Collider`'s own boxes): cheap to move and to test against
 * another, before anything is meshed.
 */
class Box {
  constructor(lo, hi) {
    this.lo = Array.from(_doubles(lo, 3, 'Box'));
    this.hi = Array.from(_doubles(hi, 3, 'Box'));
  }
  /** This box moved by `frame` (rigid), boxed again on the world axes -- not this
   *  box's corners individually moved, which would not in general be a box at all:
   *  the *bounding* box of the moved corners. */
  moved(frame) {
    const out = {};
    if (!_lib().box_moved(_boxWords(this), _frame(frame), out)) _fail('box_moved');
    return _boxOf(out);
  }
  /** Whether this box and `other` share a point (touching counts). */
  overlaps(other) { return Boolean(_lib().box_overlaps(_boxWords(this), _boxWords(other))); }
}

/**
 * True only if box `a` at `frameA` and box `b` at `frameB` cannot touch -- a separating
 * axis among the boxes' face normals and edge-direction crosses; touching is not apart.
 * Sharper than moving each box and asking `overlaps`, which boxes the *result* on the
 * world axes again and so can call two oriented boxes overlapping when they are not.
 */
function boxesApart(a, frameA, b, frameB) {
  const apart = [false];
  if (!_lib().boxes_apart(_boxWords(a), _frame(frameA), _boxWords(b), _frame(frameB), apart)) _fail('boxes_apart');
  return Boolean(apart[0]);
}

/** An intersection handle (`Solid.intersect`'s, `Clash.intersect`'s) read out into an `Intersection`, freed on every path. */
function _intersectionOf(l, h) {
  try {
    const chains = [];
    const n = l.intersection_chain_count(h);
    for (let i = 0; i < n; i++) {
      const raw = {};
      if (!l.intersection_chain(h, i, raw)) _fail('intersection_chain');
      let curve = null;
      if (raw.has_curve) {
        const rawCurve = {};
        if (!l.intersection_curve(h, i, rawCurve)) _fail('intersection_curve');
        curve = _curveOf(rawCurve);
      }
      chains.push(new Chain(_pointsAt(raw.points, raw.point_count), Boolean(raw.closed), [raw.face_a, raw.face_b], Boolean(raw.tangent), curve));
    }
    const overlaps = [];
    const m = l.intersection_overlap_count(h);
    for (let i = 0; i < m; i++) {
      const raw = {};
      if (!l.intersection_overlap(h, i, raw)) _fail('intersection_overlap');
      const points = _pointsAt(raw.points, raw.point_count);
      const starts = Array.from(_uint32s(raw.loop_offsets, raw.loop_count) ?? []);
      const loops = starts.map((start, r) => points.slice(start, r + 1 < starts.length ? starts[r + 1] : raw.point_count));
      overlaps.push(new Overlap([raw.face_a, raw.face_b], loops));
    }
    return new Intersection(chains, overlaps);
  } finally {
    l.intersection_free(h);
  }
}

const _collisionsFinalizer = typeof FinalizationRegistry === 'function'
  ? new FinalizationRegistry((h) => { try { _lib().collisions_free(h); } catch (_) { /* exiting */ } }) : null;

/**
 * Keeps one `collider.check` answer alive for as long as any `CollisionHit` of it is
 * reachable: each hit holds one of these, and once the last one is unreachable the
 * registry frees the handle -- the same idiom `Intersection` copies out to plain data
 * with, except a `CollisionHit` needs the handle itself back for `solid()`.
 */
class _CollisionsHandle {
  constructor(handle) {
    this._pointer = handle;
    if (_collisionsFinalizer) _collisionsFinalizer.register(this, handle, this);
  }
}

/**
 * One pair `Collider.check` found overlapping (`kind === 'overlap'`), or could not
 * decide (`kind === 'refused'`, `text` says why): `depth` the thinnest side of the
 * overlap's world box (0 for a refused pair), `positions`/`normals` world xyz triples
 * (three per triangle, unwelded) and `indices` into them -- all empty for a refused pair.
 *
 * `solid()` rebuilds the exact overlap now, from the frames `check` found it at; this
 * keeps the collisions handle behind every hit of one `check` call alive until the last
 * of them is unreachable.
 */
class CollisionHit {
  constructor(a, b, kind, depth, text, positions, normals, indices, keeper, index) {
    this.a = a; this.b = b; this.kind = kind; this.depth = depth; this.text = text;
    this.positions = positions; this.normals = normals; this.indices = indices;
    this._keeper = keeper; this._index = index;
  }
  /** The exact overlap of this pair at the frames it was found at, as a new solid.
   *  Throws for a refused pair, or a collisions handle already closed some other way. */
  solid() {
    const h = this._keeper._pointer;
    if (!h) throw new BuildError('collision hit: the collisions handle is closed');
    return new Solid(_checked(_lib().collisions_solid(h, this._index), 'collisions_solid'));
  }
}

function _collisionHitOf(raw, keeper, index) {
  const n = raw.vertex_count, m = raw.index_count;
  return new CollisionHit(raw.a, raw.b, raw.overlap ? 'overlap' : 'refused', raw.depth, _text(raw.text),
    _doublesAt(raw.positions, n * 3) ?? new Float64Array(0),
    _doublesAt(raw.normals, n * 3) ?? new Float64Array(0),
    _uint32s(raw.indices, m) ?? new Uint32Array(0),
    keeper, index);
}

const _clashesFinalizer = typeof FinalizationRegistry === 'function'
  ? new FinalizationRegistry((h) => { try { _lib().clashes_free(h); } catch (_) { /* exiting */ } }) : null;

/**
 * Keeps one clash call's answer alive for as long as any `Clash` of it is reachable: each row
 * holds one of these, and once the last one is unreachable the registry frees the handle -- as
 * `_CollisionsHandle` does for `CollisionHit`, because `solid()` and `intersect()` need the
 * handle itself back.
 */
class _ClashesHandle {
  constructor(handle) {
    this._pointer = handle;
    if (_clashesFinalizer) _clashesFinalizer.register(this, handle, this);
  }
}

/**
 * One pair a clash call found: `a`, `b` the part indices (for one set or a collider `a < b`;
 * for two sets `a` indexes the first and `b` the second), `kind` one of `'penetrating'`,
 * `'touching'` (the boundaries within the tolerance of each other), `'too_close'` (apart by
 * more than the tolerance but less than the clearance) or `'refused'` (the pair could not be
 * decided; `text` says why).
 *
 * `distance` is the gap between the two boundaries (0 for a penetrating or refused pair);
 * `onA` and `onB` are world points -- the closest pair, or for a penetrating pair the centre of
 * the overlap's world box (the origin for a refused one). `kindA`, `indexA`, `edgeA` (and `B`)
 * say what each point lies on exactly as `Solid.closest` does -- `'face'`, `'edge'` or
 * `'vertex'`, the kernel's id, and the fillet-table index (null for a face, a vertex or an
 * edge the table does not hold) -- and for a penetrating or refused pair `kindA`/`kindB` are
 * `'none'` with `index*` and `edge*` null. `refined` is true where the distance is measured on
 * the exact surfaces. `depth` is the thinnest side of a penetrating pair's overlap box (0
 * otherwise).
 *
 * `solid()` rebuilds a penetrating pair's shared volume now; `intersect()` where the two parts
 * cross or coincide (any pair but a refused one). Both use the placement the pair was found
 * at. This keeps the clashes handle behind every row of one call alive until the last of them
 * is unreachable.
 */
class Clash {
  constructor(raw, keeper, index) {
    this.a = raw.a; this.b = raw.b; this.kind = _text(raw.kind); this.distance = raw.distance;
    this.onA = Array.from(raw.on_a); this.onB = Array.from(raw.on_b);
    this.kindA = _text(raw.kind_a); this.kindB = _text(raw.kind_b);
    const noneA = this.kindA === 'none', noneB = this.kindB === 'none';
    this.indexA = noneA ? null : raw.index_a;
    this.edgeA = noneA || raw.edge_a === NONE ? null : raw.edge_a;
    this.indexB = noneB ? null : raw.index_b;
    this.edgeB = noneB || raw.edge_b === NONE ? null : raw.edge_b;
    this.refined = Boolean(raw.refined); this.depth = raw.depth; this.text = _text(raw.text);
    this._keeper = keeper; this._index = index;
  }
  get _handle() {
    const h = this._keeper._pointer;
    if (!h) throw new BuildError('clash: the clashes handle is closed');
    return h;
  }
  /** The exact shared volume of this penetrating pair at the placement it was found at, as a
   *  new solid. Throws for a pair that is not penetrating. */
  solid() {
    return new Solid(_checked(_lib().clashes_solid(this._handle, this._index), 'clashes_solid'));
  }
  /** Where this pair's two parts cross or coincide at the placement it was found at, as
   *  `Solid.intersect` reports it (a touching pair's shared face is an `Overlap`). Throws for a
   *  refused pair. */
  intersect() {
    const l = _lib();
    return _intersectionOf(l, _checked(l.clashes_intersect(this._handle, this._index), 'clashes_intersect'));
  }
}

/** A clashes handle read out into rows, each keeping the handle alive; freed at once if empty, or if a row cannot be read. */
function _clashesOf(h) {
  const l = _lib();
  const count = l.clashes_count(h);
  if (count === 0) { l.clashes_free(h); return []; }
  const keeper = new _ClashesHandle(h);
  const rows = [];
  for (let i = 0; i < count; i++) {
    const raw = {};
    if (!l.clashes_at(h, i, raw)) {
      const why = _lastError() || 'clashes_at';
      if (_clashesFinalizer) _clashesFinalizer.unregister(keeper);
      keeper._pointer = null;
      l.clashes_free(h);
      throw new BuildError(why);
    }
    rows.push(new Clash(raw, keeper, i));
  }
  return rows;
}

/**
 * One pair a swept clash call found: `a`, `b` the part indices (for one set or a collider
 * `a < b`; for two sets `a` indexes the first and `b` the second). `firstTime` is the first time
 * the pair came within the clearance, in pose units (pose `k` at time `k`; for a refused pair the
 * time it was refused at), and `first` the `Clash` there -- its kind, distance, points, features
 * and depth, at the frames the motion places the parts at that time, so `first.solid()` and
 * `first.intersect()` rebuild the contact there. `intervals` are the time ranges the pair stays
 * in clash, `[start, end]` pairs, ascending and disjoint (none for a refused pair).
 */
class SweptClash {
  constructor(a, b, firstTime, first, intervals) {
    this.a = a; this.b = b; this.firstTime = firstTime; this.first = first; this.intervals = intervals;
  }
}

/**
 * A swept clashes handle read out into rows and freed on every path; each row's `first` a
 * `Clash` of the handle's first rows (`swept_clashes_firsts`), which keep their own clashes
 * handle alive. A row that cannot be read frees that handle at once too.
 */
function _sweptClashesOf(h) {
  const l = _lib();
  let firsts = [];
  try {
    const count = l.swept_clashes_count(h);
    if (count === 0) return [];
    firsts = _clashesOf(_checked(l.swept_clashes_firsts(h), 'swept_clashes_firsts'));
    const rows = [], span = new Float64Array(2);
    for (let i = 0; i < count; i++) {
      const raw = {};
      if (!l.swept_clashes_at(h, i, raw)) _fail('swept_clashes_at');
      const intervals = [];
      for (let k = 0; k < raw.interval_count; k++) {
        if (!l.swept_clashes_interval(h, i, k, span)) _fail('swept_clashes_interval');
        intervals.push([span[0], span[1]]);
      }
      rows.push(new SweptClash(raw.a, raw.b, raw.first_time, firsts[i], intervals));
    }
    return rows;
  } catch (e) {
    const keeper = firsts.length ? firsts[0]._keeper : null;
    if (keeper && keeper._pointer) {
      const f = keeper._pointer;
      if (_clashesFinalizer) _clashesFinalizer.unregister(keeper);
      keeper._pointer = null;
      l.clashes_free(f);
    }
    throw e;
  } finally {
    l.swept_clashes_free(h);
  }
}

/** A swept clash call's poses as frames: each pose a list of 12-number frames. */
function _sweptPoses(poses) { return Array.from(poses, (pose) => Array.from(pose, (f) => _frame(f))); }
/** Poses of frames laid out pose by pose, as the C ABI reads them. */
function _sweptFlat(frames) { return Float64Array.from(frames.flatMap((pose) => pose.flatMap((f) => Array.from(f)))); }

const _classifierFinalizer = typeof FinalizationRegistry === 'function'
  ? new FinalizationRegistry((h) => { try { _lib().classifier_free(h); } catch (_) { /* exiting */ } }) : null;

/**
 * A closed solid meshed once and asked where point after point lies (`Solid.classifier`):
 * `contains(point)` is 'inside', 'outside', or 'on' within `tolerance` of the boundary. It keeps
 * its own reference to the solid's body, so it answers on after that `Solid` is closed. Calls on
 * one classifier take turns (a lock inside the library). `close()` frees this handle; so does
 * leaving a `using` block or the garbage collector. Throws for an open body or a `tolerance` not
 * positive and finite.
 */
class Classifier {
  constructor(solid, tolerance = 0.05) {
    this._pointer = _checked(_lib().classifier_new(solid._handle, _tol(tolerance)), 'classifier_new');
    if (_classifierFinalizer) _classifierFinalizer.register(this, this._pointer, this);
  }
  get _handle() {
    if (!this._pointer) throw new BuildError('classifier: closed');
    return this._pointer;
  }
  get closed() { return this._pointer === null; }
  close() {
    if (this._pointer === null) return;
    const h = this._pointer; this._pointer = null;
    if (_classifierFinalizer) _classifierFinalizer.unregister(this);
    _lib().classifier_free(h);
  }
  [DISPOSE]() { this.close(); }
  /** Where `point` is: 'inside', 'outside', or 'on' within the tolerance of the boundary. Throws for a point not finite. */
  contains(point) {
    const out = new Uint32Array([NONE]);
    if (!_lib().classifier_contains(this._handle, _doubles(point, 3, 'classifier_contains'), out)) _fail('classifier_contains');
    return _containment(out[0], 'classifier_contains');
  }
}

const _projectorFinalizer = typeof FinalizationRegistry === 'function'
  ? new FinalizationRegistry((h) => { try { _lib().projector_free(h); } catch (_) { /* exiting */ } }) : null;

/**
 * A solid meshed once and asked for its nearest point to point after point (`Solid.projector`):
 * `closestPoint(p, maxDistance)` answers as `Solid.closestPoint` does, keeping the mesh, its
 * search tree and each face's trim judge between queries. It keeps its own reference to the
 * solid's body, so it answers on after that `Solid` is closed. Calls on one projector take turns
 * (a lock inside the library); build one per thread to ask in parallel. `close()` frees this
 * handle; so does leaving a `using` block or the garbage collector. Throws for a negative or
 * infinite `tolerance` or a body that meshes to nothing.
 */
class Projector {
  constructor(solid, tolerance) {
    this._pointer = _checked(_lib().projector_new(solid._handle, _unset(tolerance)), 'projector_new');
    if (_projectorFinalizer) _projectorFinalizer.register(this, this._pointer, this);
  }
  get _handle() {
    if (!this._pointer) throw new BuildError('projector: closed');
    return this._pointer;
  }
  get closed() { return this._pointer === null; }
  close() {
    if (this._pointer === null) return;
    const h = this._pointer; this._pointer = null;
    if (_projectorFinalizer) _projectorFinalizer.unregister(this);
    _lib().projector_free(h);
  }
  [DISPOSE]() { this.close(); }
  /**
   * The nearest point of the body's boundary to `p`, as a `PointFoot`, or null beyond
   * `maxDistance` (undefined, null, NaN or Infinity: no limit) -- `Solid.closestPoint`'s answer,
   * at the projector's tolerance. Throws for a point not finite or a negative `maxDistance`.
   */
  closestPoint(p, maxDistance) {
    const out = {};
    const found = _lib().projector_closest_point(this._handle, _doubles(p, 3, 'projector_closest_point'), _unset(maxDistance), out);
    if (found < 0) _fail('projector_closest_point');
    return found ? new PointFoot(out) : null;
  }
  /**
   * The nearest points of `curve` and the body's boundary, as a `CurveBodyFoot`, or null beyond
   * `maxDistance` (undefined, null, NaN or Infinity: no limit) -- `Solid.curveClosestPoints`'
   * answer, at the projector's tolerance. The projector's lock is held for the whole curve query.
   * Throws for a negative `maxDistance`.
   */
  curveClosestPoints(curve, maxDistance) {
    const out = {};
    const found = _lib().projector_curve_closest_points(this._handle, curve._handle, _unset(maxDistance), out);
    if (found < 0) _fail('projector_curve_closest_points');
    return found ? new CurveBodyFoot(out) : null;
  }
}

const _triangleMeshFinalizer = typeof FinalizationRegistry === 'function'
  ? new FinalizationRegistry((h) => { try { _lib().triangle_mesh_free(h); } catch (_) { /* exiting */ } }) : null;

/**
 * A mesh's positions or indices -- `[x, y, z]` triples, one flat list, or a typed array -- as
 * one flat list, refused by `what`'s name (by index) where it is neither.
 */
function _meshNumbers(values, what, name) {
  if (values == null || typeof values === 'string' || typeof values[Symbol.iterator] !== 'function') {
    throw new BuildError(`${what}: the ${name}s are not a list: ${_rtreeShown(values)}`);
  }
  const items = Array.from(values);
  if (items.every((v) => typeof v === 'number')) {
    if (items.length % 3) throw new BuildError(`${what}: ${items.length} flat ${name} numbers are not 3 a ${name}`);
    return items;
  }
  const flat = [];
  items.forEach((item, i) => {
    const parts = item != null && typeof item !== 'string' && typeof item[Symbol.iterator] === 'function' ? Array.from(item) : null;
    if (!parts || parts.length !== 3) throw new BuildError(`${what}: ${name} ${i} is not 3 numbers: ${_rtreeShown(item)}`);
    flat.push(...parts);
  });
  return flat;
}

/**
 * A triangle mesh and its search tree, built once and immutable: nearest points (`closestPoint`)
 * and nearest points to a curve (`curveClosestPoints`) are answered exactly against it -- no
 * tolerance, no `refined` figure. `positions` are the vertices, `indices` the triangles (three
 * vertex indices each, any winding); each `[x, y, z]` triples, one flat list of numbers, or a
 * typed array. Both are copied. A zero-area triangle is accepted and answers as its longest
 * edge. `Solid.triangleMesh` gives a solid's own. Nothing in it changes after it is built.
 * `close()` frees this handle; so does leaving a `using` block or the garbage collector. Throws
 * for no triangles, an index past the vertex count, a coordinate that is not finite, or a shape
 * that is not 3 numbers a vertex and 3 whole indices a triangle.
 */
class TriangleMesh {
  constructor(positions, indices) {
    const what = 'triangle_mesh_new';
    const flat = _meshNumbers(positions, what, 'vertex').map((v, n) => {
      if (typeof v !== 'number') throw new BuildError(`${what}: vertex ${Math.floor(n / 3)} has a coordinate that is not a number: ${_rtreeShown(v)}`);
      return v;
    });
    const ids = _meshNumbers(indices, what, 'triangle').map((k, n) => _rtreeU32(k, what, `triangle ${Math.floor(n / 3)}'s index`));
    // each array at its exact length: the wasm export reads the lengths, C the counts
    this._adopt(_lib().triangle_mesh_new(Float64Array.from(flat), flat.length / 3, Uint32Array.from(ids), ids.length / 3), what);
  }
  _adopt(handle, what) {
    this._pointer = _checked(handle, what);
    if (_triangleMeshFinalizer) _triangleMeshFinalizer.register(this, this._pointer, this);
    return this;
  }
  get _handle() {
    if (!this._pointer) throw new BuildError('triangle_mesh: closed');
    return this._pointer;
  }
  get closed() { return this._pointer === null; }
  close() {
    if (this._pointer === null) return;
    const h = this._pointer; this._pointer = null;
    if (_triangleMeshFinalizer) _triangleMeshFinalizer.unregister(this);
    _lib().triangle_mesh_free(h);
  }
  [DISPOSE]() { this.close(); }
  /** How many vertices the mesh holds. */
  get vertexCount() { return _lib().triangle_mesh_vertex_count(this._handle); }
  /** How many triangles the mesh holds. */
  get triangleCount() { return _lib().triangle_mesh_triangle_count(this._handle); }
  /** The box of every vertex as `[min, max]`. */
  get bounds() {
    const out = new Float64Array(6);
    if (!_lib().triangle_mesh_bounds(this._handle, out)) _fail('triangle_mesh_bounds');
    return [Array.from(out.subarray(0, 3)), Array.from(out.subarray(3, 6))];
  }
  /**
   * The nearest point of the mesh to `p`, as a `MeshPoint` -- exact, the lower triangle where
   * several share the point -- or null where it lies beyond `maxDistance` (undefined, null, NaN
   * or Infinity: no limit; a point on the mesh is within 0). Throws for a point not finite or a
   * negative `maxDistance`.
   */
  closestPoint(p, maxDistance) {
    const what = 'triangle_mesh_closest_point';
    const out = {};
    const found = _lib().triangle_mesh_closest_point(this._handle, _doubles(p, 3, what), _unset(maxDistance), out);
    if (found < 0) _fail(what);
    return found ? new MeshPoint(out) : null;
  }
  /**
   * The nearest points of `curve` and the mesh, as a `CurveMeshFoot` -- exact; `crossing` true and
   * distance 0 at the earliest crossing in `t`; among equal distances the lower triangle, then
   * the lower `t` -- or null where the mesh lies farther than `maxDistance` (undefined, null, NaN
   * or Infinity: no limit). A mesh has no inside: a curve within a closed mesh answers its
   * distance to the triangles. Throws for a curve that is not valid or a negative `maxDistance`.
   */
  curveClosestPoints(curve, maxDistance) {
    const what = 'triangle_mesh_curve_closest_points';
    const out = {};
    const found = _lib().triangle_mesh_curve_closest_points(this._handle, curve._handle, _unset(maxDistance), out);
    if (found < 0) _fail(what);
    return found ? new CurveMeshFoot(out) : null;
  }
}

// ---- mechanical drawings: hidden lines, the projected outline, pages, DXF profiles ----

/** `HlrLine.kind`, as `CADACLYSM_BLACKSMITH_HLR_SHARP` .. `_BOUNDARY` number them. */
const HLR_KINDS = Object.freeze(['sharp', 'smooth', 'outline', 'iso', 'boundary']);
const _HLR_SOURCES = ['edge', 'face', 'mesh_edge'];
/** `new Page(units)`: the DXF unit codes `cadaclysm_blacksmith_page_new` takes. */
const PAGE_UNITS = Object.freeze({ unitless: 0, in: 1, ft: 2, mm: 4, cm: 5, m: 6 });

function _hlrXyz(what, name, v) {
  const a = Array.from(v ?? [], Number);
  if (a.length !== 3) throw new BuildError(`${what}: ${name} must be three numbers, got ${JSON.stringify(v)}`);
  return a;
}

/**
 * A view's words packed into `CadaclysmBlacksmithHlrOptions`: `eye` given is a perspective from
 * it toward `target`, otherwise a parallel view along `direction` (from the eye toward the
 * model; default `[0, 1, 0]`, the front). Every field is set here, so the wasm (which has no
 * `hlr_options_init`) and the native library read the same struct; natively the init fills
 * `size` first.
 */
function _hlrOptions(what, options = {}) {
  const o = options ?? {};
  if (o.eye != null && o.direction != null) throw new BuildError(`${what}: give direction (parallel) or eye (perspective), not both`);
  const raw = {};
  if (!_wasm()) _lib().hlr_options_init(raw);
  raw.projection = o.eye != null ? 1 : 0;
  raw.direction = o.direction != null ? _hlrXyz(what, 'direction', o.direction) : [0, 1, 0];
  raw.up = o.up != null ? _hlrXyz(what, 'up', o.up) : [0, 0, 1];
  raw.eye = o.eye != null ? _hlrXyz(what, 'eye', o.eye) : [0, 0, 0];
  raw.target = o.target != null ? _hlrXyz(what, 'target', o.target) : [0, 0, 0];
  raw.tolerance = o.tolerance == null ? 0 : Number(o.tolerance);
  raw.smooth_angle = o.smoothAngle == null ? Math.PI / 180 : Number(o.smoothAngle);
  raw.feature_angle = o.featureAngle == null ? Math.PI / 6 : Number(o.featureAngle);
  raw.iso = o.iso == null ? 0 : Number(o.iso);
  raw.reserved = 0;
  return raw;
}

/**
 * `n` Béziers of sixteen doubles -- `x y z w` per control point, the point Cartesian and its
 * weight beside it -- as `{ points, weights, count }`, `silhouetteBeziers`' shape: twelve
 * numbers a Bézier (four points, x y z) and four weights.
 */
function _hlrBeziers(flat, n) {
  const points = new Float64Array(n * 12), weights = new Float64Array(n * 4);
  for (let k = 0; k < 4 * n; k++) {
    points.set(flat.subarray(4 * k, 4 * k + 3), 3 * k);
    weights[k] = flat[4 * k + 3];
  }
  return { points, weights, count: n };
}

const _hlrFinalizer = typeof FinalizationRegistry === 'function'
  ? new FinalizationRegistry((h) => { try { _lib().hlr_free(h); } catch (_) { /* exiting */ } }) : null;
const _pageFinalizer = typeof FinalizationRegistry === 'function'
  ? new FinalizationRegistry((h) => { try { _lib().page_free(h); } catch (_) { /* exiting */ } }) : null;

/**
 * One line of a hidden-line view: `kind` one of `HLR_KINDS`, `visible`, the index of the `solid`
 * (or mesh) it belongs to, its `source` -- `['edge', id]`, `['face', index]` or
 * `['mesh_edge', a, b]` -- and its curve as rational cubic Béziers on the view plane
 * (`beziers2d`, z 0) and in space (`beziers3d`), Bézier for Bézier the same span, each
 * `{ points, weights, count }` as `Solid.silhouetteBeziers` gives them.
 */
class HlrLine {
  constructor(kind, visible, solid, source, beziers2d, beziers3d, length2d, length3d) {
    this.kind = kind; this.visible = visible; this.solid = solid; this.source = source;
    this.beziers2d = beziers2d; this.beziers3d = beziers3d; this.length2d = length2d; this.length3d = length3d;
    Object.freeze(this);
  }
}

/**
 * A hidden-line view of solids or meshes (`hlr`, `hlrMesh`): its `lines`, what the removal did
 * (`report`, counts and lengths) and the `tolerance` it worked at. Placed on a drawing with
 * `Page.addView`. Immutable; `close()` frees its handle, as leaving a `using` block or the
 * garbage collector does.
 */
class Hlr {
  constructor(handle, what) {
    this._pointer = _checked(handle, what);
    if (_hlrFinalizer) _hlrFinalizer.register(this, this._pointer, this);
    const l = _lib();
    const n = l.hlr_line_count(this._pointer);
    const lines = [];
    for (let i = 0; i < n; i++) {
      const raw = {};
      if (!l.hlr_line(this._pointer, i, raw)) _fail('hlr_line');
      const m = Number(raw.bezier_count);
      // never a zero-length array: koffi passes that as NULL, which the fill refuses
      const b2 = new Float64Array(Math.max(1, 16 * m)), b3 = new Float64Array(Math.max(1, 16 * m));
      if (!l.hlr_line_beziers2d(this._pointer, i, b2)) _fail('hlr_line_beziers2d');
      if (!l.hlr_line_beziers3d(this._pointer, i, b3)) _fail('hlr_line_beziers3d');
      const kind = _HLR_SOURCES[raw.source_kind];
      const source = kind === 'mesh_edge' ? [kind, Number(raw.source), Number(raw.source2)] : [kind, Number(raw.source)];
      lines.push(new HlrLine(HLR_KINDS[raw.kind], Boolean(raw.visible), Number(raw.solid), Object.freeze(source),
        _hlrBeziers(b2, m), _hlrBeziers(b3, m), Number(raw.length2d), Number(raw.length3d)));
    }
    const r = {};
    if (!l.hlr_report(this._pointer, r)) _fail('hlr_report');
    this.lines = Object.freeze(lines);
    this.report = Object.freeze({
      candidates: r.candidates, segments: r.segments, crossings: r.crossings, pieces: r.pieces, degenerate: r.degenerate,
      rays: r.rays, meshHits: r.mesh_hits, rejected: r.rejected, grazes: r.grazes, unsettled: r.unsettled,
      meshOnly: r.mesh_only, fallbackEdges: r.fallback_edges, failedSolids: r.failed_solids,
      candidateLength: r.candidate_length, degenerateLength: r.degenerate_length,
    });
    this.tolerance = Number(r.tolerance);
  }
  get _handle() {
    if (!this._pointer) throw new BuildError('hlr: closed');
    return this._pointer;
  }
  get closed() { return this._pointer === null; }
  close() {
    if (this._pointer === null) return;
    const h = this._pointer; this._pointer = null;
    if (_hlrFinalizer) _hlrFinalizer.unregister(this);
    _lib().hlr_free(h);
  }
  [DISPOSE]() { this.close(); }
  get length() { return this.lines.length; }
  /** The lines seen. */
  visible() { return this.lines.filter((line) => line.visible); }
  /** The lines hidden. */
  hidden() { return this.lines.filter((line) => !line.visible); }
}

function _hlrHandles(items, what, kind) {
  const handles = Array.from(items ?? [], (s) => {
    if (s == null || s._handle === undefined) throw new BuildError(`${what}: not a ${kind}: ${String(s)}`);
    return s._handle;
  });
  return handles;
}

/**
 * Hidden-line removal of `solids`, each where it stands, every solid hiding the others: what a
 * drawing of them shows, and what it shows only dashed. `options`: `direction` (from the eye
 * toward the model; default `[0, 1, 0]`, the front) with `up` the page's up (default
 * `[0, 0, 1]`), or `eye` and `target` for a perspective; `iso` isocurves each way on every face;
 * `smoothAngle` (radians, default one degree) how near tangent two faces are for the edge
 * between them to be `smooth`; `tolerance` null or 0 the solids' effective tolerance. View
 * coordinates are the camera's (x right, y up). Throws `BuildError` for no solids and refused
 * words, naming `hlr`.
 */
function hlr(solids, options = {}) {
  const handles = _hlrHandles(solids, 'hlr', 'Solid');
  const raw = _hlrOptions('hlr', options);
  return new Hlr(_lib().hlr(handles, handles.length, raw), 'hlr');
}

/**
 * `hlr` of `TriangleMesh`es, each a solid of flat triangles: its lines are the edges whose
 * triangles turn by more than `featureAngle` (radians, default thirty degrees), the edges of one
 * triangle, and the edges between a triangle facing the eye and one facing away (outlines); the
 * triangles hide exactly. Each line's `source` is `['mesh_edge', a, b]`.
 */
function hlrMesh(meshes, options = {}) {
  const handles = _hlrHandles(meshes, 'hlr_mesh', 'TriangleMesh');
  const raw = _hlrOptions('hlr_mesh', options);
  return new Hlr(_lib().hlr_mesh(handles, handles.length, raw), 'hlr_mesh');
}

/**
 * The boundary of the union of the solids' projections, as closed `Profile`s in view
 * coordinates (as `hlr`'s): each outer loop counter-clockwise with its holes clockwise inside it
 * -- a through hole seen along its axis is a hole. `hlr`'s options.
 */
function projectedOutline(solids, options = {}) {
  const handles = _hlrHandles(solids, 'projected_outline', 'Solid');
  const raw = _hlrOptions('projected_outline', options);
  return _profileList(_lib().projected_outline(handles, handles.length, raw), 'projected_outline');
}

function _pageAt(at, what) {
  const a = Array.from(at ?? [0, 0], Number);
  if (a.length !== 2) throw new BuildError(`${what}: at must be two numbers, got ${JSON.stringify(at)}`);
  return a;
}

/**
 * A flat drawing page in `units` (`'mm'`, `'cm'`, `'m'`, `'in'`, `'ft'` or `'unitless'`):
 * hidden-line views, profiles, hatches and text placed on it, written as SVG (`svg()`) or DXF
 * R2000 (`dxf()`). Layers are made on first use: a view's own -- `visible`, `outline`, `smooth`,
 * `iso`, `hidden` (dashed) -- and any other name continuous, colour 7. Mutable: each `add*`
 * changes the page and returns it. `close()` frees its handle, as leaving a `using` block or the
 * garbage collector does.
 */
class Page {
  constructor(units = 'mm') {
    if (!Object.prototype.hasOwnProperty.call(PAGE_UNITS, units)) {
      throw new BuildError(`page_new: units ${JSON.stringify(units)}: one of ${Object.keys(PAGE_UNITS).join(', ')}`);
    }
    this._pointer = _checked(_lib().page_new(PAGE_UNITS[units]), 'page_new');
    if (_pageFinalizer) _pageFinalizer.register(this, this._pointer, this);
  }
  get _handle() {
    if (!this._pointer) throw new BuildError('page: closed');
    return this._pointer;
  }
  get closed() { return this._pointer === null; }
  close() {
    if (this._pointer === null) return;
    const h = this._pointer; this._pointer = null;
    if (_pageFinalizer) _pageFinalizer.unregister(this);
    _lib().page_free(h);
  }
  [DISPOSE]() { this.close(); }
  /** How many entities the page holds. */
  get entityCount() { return _lib().page_entity_count(this._handle); }
  /**
   * `view`'s lines on the page, a view point `p` landing at `at + scale * p`: each line as the
   * entities that draw it best (lines, arcs, circles, elliptical arcs, splines).
   */
  addView(view, at = [0, 0], scale = 1) {
    const [x, y] = _pageAt(at, 'page_add_view');
    if (!_lib().page_add_view(this._handle, view._handle, x, y, Number(scale))) _fail('page_add_view');
    return this;
  }
  /** `profile`'s outline and holes on `layer` (null: `0`), moved by `at`. */
  addProfile(profile, at = [0, 0], layer = null) {
    const [x, y] = _pageAt(at, 'page_add_profile');
    if (!_lib().page_add_profile(this._handle, profile._handle, layer == null ? null : String(layer), x, y)) _fail('page_add_profile');
    return this;
  }
  /**
   * `profile` hatched (its holes left out) on `layer` (null: `hatch`), moved by `at`: `pattern`
   * `SOLID`, `ANSI31`, `ANSI37` or `ANSI32`/`STEEL`, turned `angle` radians, its spacing times
   * `scale`.
   */
  addHatch(profile, pattern = 'ANSI31', angle = 0, scale = 1, at = [0, 0], layer = null) {
    const [x, y] = _pageAt(at, 'page_add_hatch');
    if (!_lib().page_add_hatch(this._handle, profile._handle, layer == null ? null : String(layer), String(pattern),
      Number(angle), Number(scale), x, y)) _fail('page_add_hatch');
    return this;
  }
  /**
   * One line of `text` on `layer` (null: `text`) at `at`, `height` tall, turned `angle` radians;
   * `halign` `left`/`center`/`right`, `valign` `baseline`/`bottom`/`middle`/`top`.
   */
  addText(text, at, height, angle = 0, halign = 'left', valign = 'baseline', layer = null) {
    const [x, y] = _pageAt(at, 'page_add_text');
    if (!_lib().page_add_text(this._handle, String(text), layer == null ? null : String(layer), x, y, Number(height), Number(angle),
      String(halign), String(valign))) _fail('page_add_text');
    return this;
  }
  /** The page as an SVG document, one group per layer. */
  svg() {
    const s = _lib().page_svg_text(this._handle);
    if (s == null) _fail('page_svg_text');
    return s;
  }
  /** The page as DXF R2000 (`AC1015`) text: the same text for the same page. */
  dxf() {
    const s = _lib().page_dxf_text(this._handle);
    if (s == null) _fail('page_dxf_text');
    return s;
  }
}

/**
 * A DXF file's closed loops as `Profile`s: its lines, arcs, circles, ellipses, polylines and
 * splines (blocks inserted) chained end to end within `tolerance` (null: the effective tolerance
 * over the drawing's extents) into closed loops, holes nested in the loops around them. Throws
 * `BuildError` for text that is not DXF, naming the line it stopped at.
 */
function dxfProfiles(text, tolerance = null) {
  return _profileList(_lib().dxf_profiles(String(text), _tol(tolerance)), 'dxf_profiles');
}

const _colliderFinalizer = typeof FinalizationRegistry === 'function'
  ? new FinalizationRegistry((h) => { try { _lib().collider_free(h); } catch (_) { /* exiting */ } }) : null;

/**
 * Parts meshed once, asked pose after pose which of them interfere. `close()` frees this
 * handle; so does leaving a `using` block or the garbage collector.
 */
class Collider {
  /**
   * `solids` at rest, meshed at `tolerance`; `groups` one group index per solid (null:
   * each solid its own group -- `check` then takes one frame per solid), `allowed` pairs
   * of part indices never tested (designed contacts, flattened: `[a0, b0, a1, b1, ...]`).
   */
  constructor(solids, tolerance = 0.05, groups = null, allowed = []) {
    const handles = Array.from(solids, (s) => s._handle);
    if (groups != null && groups.length !== handles.length) {
      throw new BuildError(`Collider: groups must have one entry per solid (${handles.length} solids, ${groups.length} groups)`);
    }
    const groupsArr = groups == null ? null : Uint32Array.from(groups, Number);
    const allowedArr = Uint32Array.from(allowed, Number);
    const h = _lib().collider_new(handles, handles.length, _tol(tolerance), groupsArr, allowedArr, allowedArr.length / 2);
    this._pointer = _checked(h, 'collider_new');
    if (_colliderFinalizer) _colliderFinalizer.register(this, this._pointer, this);
  }
  get _handle() {
    if (!this._pointer) throw new BuildError('collider: closed');
    return this._pointer;
  }
  get closed() { return this._pointer === null; }
  close() {
    if (this._pointer === null) return;
    const h = this._pointer; this._pointer = null;
    if (_colliderFinalizer) _colliderFinalizer.unregister(this);
    _lib().collider_free(h);
  }
  [DISPOSE]() { this.close(); }
  /** How many groups this collider has -- the highest group index past the constructor, plus one. */
  get groupCount() { return _lib().collider_group_count(this._handle); }
  /** Counts of the last `check` call (all zero before the first one): `considered`,
   *  `worldBoxes`, `orientedBoxes`, `skippedShare`, `cached`, `closedForm`, `meshed`,
   *  `refused`, `confirmed` -- see the C ABI's own doc on `CadaclysmBlacksmithColliderStats`
   *  for what each counts. */
  get stats() {
    const out = {};
    if (!_lib().collider_stats(this._handle, out)) _fail('collider_stats');
    return {
      considered: out.considered, worldBoxes: out.world_boxes, orientedBoxes: out.oriented_boxes,
      skippedShare: out.skipped_share, cached: out.cached, closedForm: out.closed_form,
      meshed: out.meshed, refused: out.refused, confirmed: out.confirmed,
    };
  }
  /**
   * The pairs that interfere, or could not be decided, with each group placed at its
   * matching frame in `frames` (one per group, in group order). `share`: `null`, every
   * pair past the box filters is decided now; `[k, n]`, only those whose index is `k`
   * modulo `n` (the shares of one pose are disjoint and cover it). `[k, 0]` is the same as
   * `null`: the C ABI reads `n` 0 as every pair.
   */
  check(frames, share = null) {
    const flat = Float64Array.from(Array.from(frames).flatMap((f) => Array.from(_frame(f))));
    const [shareK, shareN] = share ?? [0, 0];
    const l = _lib();
    const h = _checked(l.collider_check(this._handle, flat, flat.length / 12, shareK, shareN), 'collider_check');
    const count = l.collisions_count(h);
    if (count === 0) { l.collisions_free(h); return []; }
    const keeper = new _CollisionsHandle(h);
    const hits = [];
    for (let i = 0; i < count; i++) {
      const raw = {};
      if (!l.collisions_hit(h, i, raw)) _fail('collisions_hit');
      hits.push(_collisionHitOf(raw, keeper, i));
    }
    return hits;
  }
  /**
   * Every pair of parts that penetrates, touches or lies within `clearance` of the other, as
   * `Clash` rows in pair order, with each group placed at its matching frame in `frames` (as for
   * `check`). `clearance` is zero or more, in model units: a pair apart by more than the
   * collider's tolerance but less than it is `'too_close'`. `share` as for `check`. The collider
   * keeps each part's closest mesh (at a third of its tolerance) for its lifetime once a pair
   * needed one. Throws `BuildError` for a negative or non-finite `clearance`, the wrong number
   * of frames or a bad `share`.
   */
  clash(frames, clearance = 0, share = null) {
    const flat = Float64Array.from(Array.from(frames).flatMap((f) => Array.from(_frame(f))));
    const [shareK, shareN] = share ?? [0, 0];
    const h = _lib().collider_clash(this._handle, flat, flat.length / 12, clearance, shareK, shareN);
    return _clashesOf(_checked(h, 'collider_clash'));
  }
  /**
   * Every pair of parts that penetrates, touches or comes within `clearance` of the other
   * anywhere on the path through `poses` -- not only at the poses -- as `SweptClash` rows in pair
   * order. `poses` is two or more poses, each the `frames` `clash` takes (one frame per group).
   * Between two poses each group moves rigidly about the centre of its rest box: that point on
   * the straight line between its two places, the rotation turning at a steady rate the shorter
   * way round. Time runs in pose units, pose `k` at time `k`.
   *
   * No moment where the true gap is below `clearance` less the collider's tolerance (for
   * clearance 0: no penetration deeper than the tolerance) falls between two steps.
   * `resolution` (in (0, 1], a fraction of a segment) is how closely an interval's end is found;
   * `maxSteps` the pose-wise tests one pair may take -- a pair that needs more is a `'refused'`
   * row. `share` as for `check`, over the pairs whose swept boxes meet. The pose caches `check`
   * and `clash` keep are neither read nor filled. Throws `BuildError` for fewer than two poses,
   * the wrong number of frames in a pose, a bad frame, `clearance`, `resolution` or `share`, or
   * `maxSteps` 0.
   */
  sweptClash(poses, clearance = 0, resolution = 1e-3, maxSteps = 100000, share = null) {
    const frames = _sweptPoses(poses);
    if (new Set(frames.map((pose) => pose.length)).size > 1) {
      // C reads every pose at one frame count: say the first pose that is off, in the kernel's words
      const groups = this.groupCount;
      const n = frames.find((pose) => pose.length !== groups).length;
      throw new BuildError(`collider_swept_clash: ${n} frames for ${groups} groups`);
    }
    const [shareK, shareN] = share ?? [0, 0];
    const h = _lib().collider_swept_clash(this._handle, _sweptFlat(frames), frames.length, frames.length ? frames[0].length : 0,
      clearance, resolution, maxSteps, shareK, shareN);
    return _sweptClashesOf(_checked(h, 'collider_swept_clash'));
  }
}

// ---- the R-tree -----------------------------------------------------------------------------

/** A number as the R-tree calls take one: a `number` (NaN included -- whether it is a coordinate or a distance is the library's to say), never a string or a bool. */
const _rtreeNumber = (v) => typeof v === 'number';
const _rtreeShown = (v) => { if (typeof v === 'number') return String(v); try { return JSON.stringify(v) ?? String(v); } catch (_) { return String(v); } };

/** An id or a `k` as the C ABI's `uint32_t`, refused by `call`'s name -- never wrapped by koffi or the wasm. */
function _rtreeU32(value, call, name) {
  if (typeof value !== 'number' || !Number.isInteger(value)) throw new BuildError(`${call}: ${name} must be a whole number, not ${_rtreeShown(value)}`);
  if (value < 0 || value > NONE) throw new BuildError(`${call}: ${name} is out of range: ${value}`);
  return value;
}

/** A radius, slack or limit, refused by `call`'s name when it is not a number. */
function _rtreeReal(value, call, name) {
  if (!_rtreeNumber(value)) throw new BuildError(`${call}: ${name} ${_rtreeShown(value)} is not a number`);
  return value;
}

/** `p` as 3 numbers, or null when it is not 3 numbers (a string is not). */
function _rtreeTriple(p) {
  if (p == null || typeof p === 'string' || typeof p.length !== 'number') return null;
  const v = Array.from(p);
  return v.length === 3 && v.every(_rtreeNumber) ? v : null;
}

/** A query point as 3 doubles, refused by `call`'s name when it is not 3 numbers. */
function _rtreePoint(point, call) {
  const v = _rtreeTriple(point);
  if (!v) throw new BuildError(`${call}: a point is 3 numbers, not ${_rtreeShown(point)}`);
  return Float64Array.from(v);
}

/**
 * A box as the C ABI's 6 doubles `[minx, miny, minz, maxx, maxy, maxz]`, and whether it was given
 * as a point: a `Box` (`lo`/`hi`), `[min, max]` (two triples), `{ min, max }`, 6 numbers, or a
 * point (3 numbers, a zero box). The shape is refused here by `what`; a NaN or an inverted box is
 * the library's.
 */
function _rtreeBox(box, what) {
  if (box instanceof Box) return { words: Float64Array.of(...box.lo, ...box.hi), point: false };
  if (box != null && typeof box === 'object' && !(typeof box.length === 'number') && 'min' in box && 'max' in box) {
    const lo = _rtreeTriple(box.min), hi = _rtreeTriple(box.max);
    if (lo && hi) return { words: Float64Array.of(...lo, ...hi), point: false };
  }
  if (box != null && typeof box !== 'string' && typeof box.length === 'number') {
    const v = Array.from(box);
    if ((v.length === 3 || v.length === 6) && v.every(_rtreeNumber)) {
      return v.length === 3 ? { words: Float64Array.of(...v, ...v), point: true } : { words: Float64Array.from(v), point: false };
    }
    if (v.length === 2) {
      const lo = _rtreeTriple(v[0]), hi = _rtreeTriple(v[1]);
      if (lo && hi) return { words: Float64Array.of(...lo, ...hi), point: false };
    }
  }
  throw new BuildError(`${what}: a box is [min, max] (two triples), a Box, { min, max }, 6 numbers or a point, not ${_rtreeShown(box)}`);
}

/** Points (3 numbers each) as one flat `Float64Array`, the shape refused by index under `what`. */
function _rtreePointsFlat(points, what, name = 'point') {
  const flat = [];
  let i = 0;
  for (const p of points) {
    const v = _rtreeTriple(p);
    if (!v) throw new BuildError(`${what}: ${name} ${i} is not 3 numbers: ${_rtreeShown(p)}`);
    flat.push(...v);
    i++;
  }
  return Float64Array.from(flat);
}

/**
 * A search/within/nearest answer as `[id, distance]` pairs: the native list read and freed on
 * every path, or the wasm's flat array cut 2 at a time. A null list is the call's refusal.
 */
function _rtreeHits(list, what) {
  _checked(list, what);
  if (list.rows) {
    const v = list.rows, out = [];
    for (let k = 0; k < v.length; k += 2) out.push([v[k], v[k + 1]]);
    return out;
  }
  const l = _lib();
  try {
    const n = l.rtree_hits_count(list);
    const out = [];
    for (let i = 0; i < n; i++) {
      const raw = {};
      if (!l.rtree_hits_at(list, i, raw)) _fail('rtree_hits_at');
      out.push([raw.id, raw.distance]);
    }
    return out;
  } finally {
    l.rtree_hits_free(list);
  }
}

/** An overlaps answer as `[a, b]` id pairs, read as `_rtreeHits` reads hits. */
function _rtreePairs(list, what) {
  _checked(list, what);
  if (list.rows) {
    const v = list.rows, out = [];
    for (let k = 0; k < v.length; k += 2) out.push([v[k], v[k + 1]]);
    return out;
  }
  const l = _lib();
  try {
    const n = l.rtree_pairs_count(list);
    const out = [];
    for (let i = 0; i < n; i++) {
      const raw = {};
      if (!l.rtree_pairs_at(list, i, raw)) _fail('rtree_pairs_at');
      out.push([raw.a, raw.b]);
    }
    return out;
  } finally {
    l.rtree_pairs_free(list);
  }
}

const _rtreeFinalizer = typeof FinalizationRegistry === 'function'
  ? new FinalizationRegistry((h) => { try { _lib().rtree_free(h); } catch (_) { /* exiting */ } }) : null;

/**
 * A spatial index over boxes with ids (an R*-tree): `search` a box for the entries it meets,
 * `within` / `nearest` a point for the closest, `overlaps` / `selfOverlaps` for every pair of
 * boxes that meet. Ids are the caller's own (whole numbers, 0 to 4294967295) and may repeat; an
 * entry is an id and its box, and the same `[id, box]` twice is two entries. Touching boxes meet.
 *
 * A box is `[min, max]` -- two `[x, y, z]` triples -- a `Box`, `{ min, max }`, or 6 numbers; a
 * point `[x, y, z]` stands for a zero box. Answers come in a fixed order: `search` ids
 * ascending, `within` / `nearest` by distance then id, pairs ascending. `slack` is the largest
 * gap between two boxes that still pair. The tree changes in place (`insert`, `remove`).
 * `close()` frees it; so does leaving a `using` block or the garbage collector.
 */
class RTree {
  /** An empty tree. */
  constructor() { this._adopt(_lib().rtree_new(), 'rtree_new'); }
  _adopt(handle, what) {
    this._pointer = _checked(handle, what);
    if (_rtreeFinalizer) _rtreeFinalizer.register(this, this._pointer, this);
    return this;
  }
  /**
   * A tree over `[id, box]` pairs at once, packed (sort-tile-recursive): fuller and faster to
   * query than the same entries inserted one by one. Throws for the first entry whose box is not
   * a box (a NaN, an infinity, `min > max`), by index.
   */
  static fromBoxes(entries) {
    const ids = [], flat = [];
    let i = 0;
    for (const entry of entries) {
      if (entry == null || typeof entry === 'string' || typeof entry.length !== 'number' || entry.length !== 2) {
        throw new BuildError(`rtree_from_boxes: entry ${i} is not an [id, box] pair: ${_rtreeShown(entry)}`);
      }
      ids.push(_rtreeU32(entry[0], `rtree_from_boxes: entry ${i}`, 'id'));
      flat.push(..._rtreeBox(entry[1], `rtree_from_boxes: entry ${i}`).words);
      i++;
    }
    const h = _lib().rtree_from_boxes(Uint32Array.from(ids), Float64Array.from(flat), ids.length);
    return Object.create(RTree.prototype)._adopt(h, 'rtree_from_boxes');
  }
  /** A tree over `points`, each a zero box whose id is its index. Throws for the first point with a NaN or infinite coordinate, by index. */
  static fromPoints(points) {
    const flat = _rtreePointsFlat(points, 'rtree_from_points');
    return Object.create(RTree.prototype)._adopt(_lib().rtree_from_points(flat, flat.length / 3), 'rtree_from_points');
  }
  /**
   * A tree over a mesh's triangles -- RhinoCommon's `RTree.CreateMeshFaceTree`: one entry per
   * triangle of `triangles` (three indices into `positions`, each `[x, y, z]`), its id the
   * triangle's index, its box its three corners' box. Throws for the first corner past the points
   * or at a point with a NaN or infinite coordinate, by triangle and point; points no triangle
   * uses are not checked.
   */
  static fromTriangles(positions, triangles) {
    const flat = _rtreePointsFlat(positions, 'rtree_from_triangles');
    const indices = [];
    let i = 0;
    for (const tri of triangles) {
      const parts = tri != null && typeof tri !== 'string' && typeof tri.length === 'number' ? Array.from(tri) : null;
      if (!parts || parts.length !== 3) throw new BuildError(`rtree_from_triangles: triangle ${i} is not 3 indices: ${_rtreeShown(tri)}`);
      for (const k of parts) indices.push(_rtreeU32(k, 'rtree_from_triangles', `triangle ${i}'s index`));
      i++;
    }
    const h = _lib().rtree_from_triangles(flat, flat.length / 3, Uint32Array.from(indices), indices.length / 3);
    return Object.create(RTree.prototype)._adopt(h, 'rtree_from_triangles');
  }
  get _handle() {
    if (!this._pointer) throw new BuildError('rtree: closed');
    return this._pointer;
  }
  get closed() { return this._pointer === null; }
  close() {
    if (this._pointer === null) return;
    const h = this._pointer; this._pointer = null;
    if (_rtreeFinalizer) _rtreeFinalizer.unregister(this);
    _lib().rtree_free(h);
  }
  [DISPOSE]() { this.close(); }
  /** How many entries the tree holds. */
  get count() { return _lib().rtree_count(this._handle); }
  /** The union of every entry's box as `[min, max]`, or null for an empty tree. */
  get bounds() {
    const h = this._handle;
    const l = _lib();
    if (l.rtree_count(h) === 0) return null;
    const out = new Float64Array(6);
    if (!l.rtree_bounds(h, out)) _fail('rtree_bounds');
    return [Array.from(out.subarray(0, 3)), Array.from(out.subarray(3, 6))];
  }
  /** Add the entry `[id, box]`, `box` a box or a point. Throws, leaving the tree as it was, for a box that is not a box or a point that is not finite. */
  insert(id, box) {
    const h = this._handle;
    const n = _rtreeU32(id, 'rtree_insert', 'id');
    const { words, point } = _rtreeBox(box, 'rtree_insert');
    const l = _lib();
    if (point) {
      if (!l.rtree_insert_point(h, n, words.subarray(0, 3))) _fail('rtree_insert_point');
    } else if (!l.rtree_insert(h, n, words)) {
      _fail('rtree_insert');
    }
  }
  /**
   * Take out one entry equal to `[id, box]` -- the box it was inserted with, compared coordinate
   * by coordinate (a point's is its zero box) -- and say whether there was one: false, not an
   * error, when there is none. Throws for a box that is not a box.
   */
  remove(id, box) {
    const h = this._handle;
    const n = _rtreeU32(id, 'rtree_remove', 'id');
    const { words } = _rtreeBox(box, 'rtree_remove');
    const l = _lib();
    if (l.rtree_remove(h, n, words)) return true;
    if (_lastError()) _fail('rtree_remove');
    return false;
  }
  /** The ids of every entry whose box meets `box` (touching counts), ascending. */
  search(box) {
    const h = this._handle;
    const { words } = _rtreeBox(box, 'rtree_search');
    return _rtreeHits(_lib().rtree_search(h, words), 'rtree_search').map(([id]) => id);
  }
  /** Every entry whose box is within `r` of `point` (0 inside the box), as `[id, distance]` by distance then id. */
  within(point, r) {
    const h = this._handle;
    const p = _rtreePoint(point, 'rtree_within');
    return _rtreeHits(_lib().rtree_within(h, p, _rtreeReal(r, 'rtree_within', 'radius')), 'rtree_within');
  }
  /** The `k` entries nearest `point`, as `[id, distance]` by distance then id; all of them when `k` is over the count. */
  nearest(point, k) {
    const h = this._handle;
    const p = _rtreePoint(point, 'rtree_nearest');
    return _rtreeHits(_lib().rtree_nearest(h, p, _rtreeU32(k, 'rtree_nearest', 'k')), 'rtree_nearest');
  }
  /**
   * Every entry whose box the ray `origin + t * direction`, `0 <= t <= maxT`, meets, as
   * `[id, t]` by `t` then id, `t` where the ray enters the box (0 when `origin` is inside it).
   * Touching counts. `t` is in units of `direction`'s length, which is not normalised; `maxT`
   * defaults to `Infinity`. Throws for an origin or direction not finite, a zero direction, or a
   * `maxT` negative or NaN.
   */
  ray(origin, direction, maxT = Infinity) {
    const h = this._handle;
    const o = _rtreeTriple(origin), d = _rtreeTriple(direction);
    if (!o) throw new BuildError(`rtree_ray: an origin is 3 numbers, not ${_rtreeShown(origin)}`);
    if (!d) throw new BuildError(`rtree_ray: a direction is 3 numbers, not ${_rtreeShown(direction)}`);
    const t = _rtreeReal(maxT, 'rtree_ray', 'max_t');
    return _rtreeHits(_lib().rtree_ray(h, Float64Array.from(o), Float64Array.from(d), t), 'rtree_ray');
  }
  /** Every pair `[a, b]`, `a` an entry of this tree and `b` one of `other` (this tree too, if it is), at most `slack` apart, ascending. */
  overlaps(other, slack = 0) {
    const h = this._handle;
    if (!(other instanceof RTree)) throw new BuildError(`rtree_overlaps: other must be an RTree, not ${_rtreeShown(other)}`);
    const o = other._handle;
    return _rtreePairs(_lib().rtree_overlaps(h, o, _rtreeReal(slack, 'rtree_overlaps', 'slack')), 'rtree_overlaps');
  }
  /** Every unordered pair of distinct entries at most `slack` apart, once each as `[smaller id, larger id]`, ascending. */
  selfOverlaps(slack = 0) {
    const h = this._handle;
    return _rtreePairs(_lib().rtree_self_overlaps(h, _rtreeReal(slack, 'rtree_self_overlaps', 'slack')), 'rtree_self_overlaps');
  }
}

/** `x` as Rust's `{}` prints an f64 -- the kernel's refusals quote numbers that way. */
function _rustNumber(x) {
  if (Number.isNaN(x)) return 'NaN';
  if (!Number.isFinite(x)) return x > 0 ? 'inf' : '-inf';
  // String() is the shortest round-trip digits, as Rust's are; Rust lays them out without an
  // exponent, and keeps the sign of -0.
  const sign = x < 0 || Object.is(x, -0) ? '-' : '';
  const [mantissa, exponent = '0'] = String(Math.abs(x)).split('e');
  const [whole, fraction = ''] = mantissa.split('.');
  let digits = (whole + fraction).replace(/^0+/, '');
  let shift = Number(exponent) - fraction.length;
  const stripped = digits.replace(/0+$/, '');
  shift += digits.length - stripped.length;
  digits = stripped;
  if (digits === '') return `${sign}0`;
  if (shift >= 0) return sign + digits + '0'.repeat(shift);
  const point = digits.length + shift;
  return point > 0 ? `${sign}${digits.slice(0, point)}.${digits.slice(point)}` : `${sign}0.${'0'.repeat(-point)}${digits}`;
}

/** `hay` and `needles` as triples, refused as the kernel's `closest_points` / `k_neighbors` refuse: the first hay point, then needle, not finite (or not 3 numbers), by index. */
function _pointTriples(call, hay, needles) {
  return [['hay', hay], ['needle', needles]].map(([name, points]) => {
    const flat = _rtreePointsFlat(points, call, `${name} point`);
    const triples = [];
    for (let k = 0; k < flat.length; k += 3) {
      const p = Array.from(flat.subarray(k, k + 3));
      if (!p.every(Number.isFinite)) throw new BuildError(`${call}: ${name} point ${k / 3} is not finite`);
      triples.push(p);
    }
    return triples;
  });
}

/**
 * For each needle, the indices of the `hay` points within `limit` of it, by distance then index
 * -- one `RTree` over `hay` answers every needle. Throws for a `limit` negative or NaN, then the
 * first hay point and the first needle not finite, by index.
 */
function closestPoints(hay, needles, limit) {
  _rtreeReal(limit, 'closest_points', 'limit');
  if (!(limit >= 0)) throw new BuildError(`closest_points: limit ${_rustNumber(limit)} is not a distance`);
  const [hayPoints, points] = _pointTriples('closest_points', hay, needles);
  const tree = RTree.fromPoints(hayPoints);
  try {
    return points.map((p) => tree.within(p, limit).map(([i]) => i));
  } finally {
    tree.close();
  }
}

/**
 * For each needle, the indices of the `k` nearest `hay` points, by distance then index (all of
 * them when `k` is over the hay count). Throws for the first hay point and the first needle not
 * finite, by index, then a `k` that is not a whole number from 0 to 1,000,000.
 */
function kNeighbors(hay, needles, k) {
  const [hayPoints, points] = _pointTriples('k_neighbors', hay, needles);
  _rtreeU32(k, 'k_neighbors', 'k');
  if (k > 1_000_000) throw new BuildError(`k_neighbors: k ${k} is not at most 1000000`);
  const tree = RTree.fromPoints(hayPoints);
  try {
    return points.map((p) => tree.nearest(p, k).map(([i]) => i));
  } finally {
    tree.close();
  }
}

/**
 * Every pair of `parts` -- or, with `others`, every part of `parts` against every part of
 * `others` -- that penetrates, touches or lies within `clearance` of the other, as `Clash`
 * rows, the solids as they stand. `tolerance` is the meshing tolerance, absolute. `allowed`
 * pairs of part indices never tested (designed contacts, flattened as `Collider`'s:
 * `[a0, b0, a1, b1, ...]`); with `others` a pair is (index in `parts`, index in `others`). In a
 * row `a` indexes `parts` and `b` indexes `others` (or `parts` again). Throws `BuildError` for
 * an empty `others`, an `allowed` of odd length or with an entry that is not a whole number
 * from 0 to 4294967295, a negative or non-finite `clearance`, a `tolerance` not positive and
 * finite, an `allowed` index out of range or a part that is not a closed solid.
 */
function clash(parts, others = null, clearance = 0, tolerance = 0.05, allowed = []) {
  const first = Array.from(parts, (s) => s._handle);
  const second = others == null ? null : Array.from(others, (s) => s._handle);
  // the wasm export reads an empty `b` as one set, and C refuses it: refused here for both
  if (second !== null && second.length === 0) throw new BuildError('clash: an empty set');
  const allowedArr = _clashAllowed(allowed, 'clash');
  const h = _lib().clash(first, first.length, second, second === null ? 0 : second.length, _tol(tolerance), clearance, allowedArr, allowedArr.length / 2);
  return _clashesOf(_checked(h, 'clash'));
}

/** `allowed` flattened pairs as a `Uint32Array`, refused with `what`'s prefix for an odd length or an entry that is not a whole number from 0 to 4294967295. */
function _clashAllowed(allowed, what) {
  const flat = Array.from(allowed);
  if (flat.length % 2 !== 0) throw new BuildError(`${what}: allowed is ${flat.length} numbers, not pairs`);
  const index = (v) => typeof v === 'number' && Number.isInteger(v) && v >= 0 && v <= NONE;
  for (let i = 0; i < flat.length; i += 2) {
    if (!index(flat[i]) || !index(flat[i + 1])) {
      throw new BuildError(`${what}: allowed pair (${_rtreeShown(flat[i])}, ${_rtreeShown(flat[i + 1])}) is not two indices`);
    }
  }
  return Uint32Array.from(flat);
}

/**
 * Every pair of `parts` -- or, with `others`, every part of `parts` against every part of
 * `others` -- that penetrates, touches or comes within `clearance` of the other anywhere on a
 * path, as `SweptClash` rows. Each part is its own group: pose `k` of `poses` is one frame per
 * part of `parts`, and pose `k` of `otherPoses` one per part of `others` (the two go together,
 * and have as many poses). The motion between poses, the guarantee, `resolution` and `maxSteps`
 * are `Collider.sweptClash`'s. `tolerance` is the meshing tolerance, absolute. `allowed` pairs of
 * part indices never tested, flattened as `clash`'s (`[a0, b0, a1, b1, ...]`); with `others` a
 * pair is (index in `parts`, index in `others`). In a row `a` indexes `parts` and `b` indexes
 * `others` (or `parts` again). Throws `BuildError` as `Collider.sweptClash` does, and for
 * `others` without `otherPoses` (or the other way round), poses counts that differ between the
 * sets, a pose with the wrong number of frames, an empty `others`, an `allowed` as `clash`
 * refuses it, an `allowed` index out of range or a part that is not a closed solid.
 */
function sweptClash(parts, poses, others = null, otherPoses = null, clearance = 0, tolerance = 0.05, resolution = 1e-3, maxSteps = 100000, allowed = []) {
  if ((others == null) !== (otherPoses == null)) throw new BuildError('swept_clash: others and other_poses go together');
  const first = Array.from(parts, (s) => s._handle);
  const second = others == null ? null : Array.from(others, (s) => s._handle);
  const framesA = _sweptPoses(poses);
  const framesB = otherPoses == null ? null : _sweptPoses(otherPoses);
  // C reads each set's poses at its part count: the kernel's own checks, in its order
  if (framesB !== null && framesB.length !== framesA.length) {
    throw new BuildError(`swept_clash: ${framesA.length} poses for set a, ${framesB.length} for set b`);
  }
  for (const [name, frames, n] of [['a', framesA, first.length], ['b', framesB ?? [], second === null ? 0 : second.length]]) {
    frames.forEach((pose, k) => {
      if (pose.length !== n) throw new BuildError(`swept_clash: pose ${k} of set ${name} has ${pose.length} frames for ${n} parts`);
    });
  }
  // the wasm export reads an empty `b` as one set, and C refuses it: refused here for both
  if (second !== null && second.length === 0) throw new BuildError('swept_clash: an empty set');
  const allowedArr = _clashAllowed(allowed, 'swept_clash');
  const h = _lib().swept_clash(first, first.length, _sweptFlat(framesA), second, second === null ? 0 : second.length,
    framesB === null ? null : _sweptFlat(framesB), framesA.length, _tol(tolerance), clearance, resolution, maxSteps, allowedArr, allowedArr.length / 2);
  return _sweptClashesOf(_checked(h, 'swept_clash'));
}

// ---- wall thickness ------------------------------------------------------------------------

/**
 * One wall-thickness reading on a solid (`ThicknessGauge.thickness` / `.thicknessAt`, `thickness`).
 * `point` lies on face `face` of body `body` (the body's index in the gauge): at vertex `vertex`
 * of that body's measuring mesh (`ThicknessGauge.mesh`), or `vertex` null for a reading at a
 * point. `thickness` is the nearest-opposing-wall rule on the measuring mesh, to `opposite` on
 * face `oppositeFace` of body `oppositeBody`; `knife` marks a knife edge (thickness 0,
 * `opposite` == `point`). `exactOpposite` is `opposite` moved onto its exact face where its foot
 * lies within the tolerance and inside the face's trims, `exactThickness` the distance to it.
 * `sphere` is the diameter of the largest ball tangent at `point` that holds none of the
 * surfaces, null where none under the maximum does (0 on a knife edge). Points are `[x, y, z]`.
 */
class Thickness {
  constructor(raw) {
    this.body = raw.body;
    this.vertex = raw.vertex === NONE ? null : raw.vertex;
    this.face = raw.face;
    this.point = Array.from(raw.point);
    this.thickness = raw.thickness;
    this.opposite = Array.from(raw.opposite);
    this.oppositeBody = raw.opposite_body;
    this.oppositeFace = raw.opposite_face;
    this.knife = Boolean(raw.knife);
    this.exactThickness = raw.exact_thickness;
    this.exactOpposite = Array.from(raw.exact_opposite);
    this.sphere = Number.isNaN(raw.sphere) ? null : raw.sphere;
  }
}

/**
 * A face's thickness, found (`ThicknessGauge.thicknessAtFace`, `Solid.thicknessAtFace`; where
 * nothing is found those answer null): `thickness` the median of the face's vertex readings (or
 * the reading at `at`), `min` and `max` their extremes, `uniform` whether `max - min` is within
 * the gauge's tolerance.
 */
class FaceThickness {
  constructor(raw) {
    this.thickness = raw.thickness; this.min = raw.min; this.max = raw.max; this.uniform = Boolean(raw.uniform);
  }
}

/**
 * A body's measuring mesh (`ThicknessGauge.mesh`), copied out of the gauge: `positions` and
 * `normals` (unit, outward) one `[x, y, z]` per vertex -- a reading's `vertex` indexes them; no
 * vertex is shared between two faces --, `triangles` three vertex indices each, and `faces` the
 * B-rep face of each triangle.
 */
class ThicknessMesh {
  constructor(positions, normals, triangles, faces) {
    this.positions = positions; this.normals = normals; this.triangles = triangles; this.faces = faces;
  }
}

/**
 * One reading on a plain mesh (`meshThickness`): vertex `vertex` of mesh `mesh`, at `point`,
 * reads `thickness` to `opposite` on triangle `oppositeTriangle` of mesh `oppositeMesh` (both
 * indices within that mesh). `knife`: a knife edge, thickness 0 and `opposite` == `point`.
 */
class MeshThickness {
  constructor(raw) {
    this.mesh = raw.mesh; this.vertex = raw.vertex; this.thickness = raw.thickness;
    this.point = Array.from(raw.point); this.opposite = Array.from(raw.opposite);
    this.oppositeMesh = raw.opposite_mesh; this.oppositeTriangle = raw.opposite_triangle;
    this.knife = Boolean(raw.knife);
  }
}

/** A thicknesses handle (null: throw `what`'s refusal) read out into rows and freed on every path. */
function _thicknessesOf(h, what) {
  const l = _lib();
  _checked(h, what);
  try {
    const rows = [];
    for (let i = 0, n = l.thicknesses_count(h); i < n; i++) {
      const raw = {};
      if (!l.thicknesses_at(h, i, raw)) throw new BuildError(_lastError() || 'thicknesses_at');
      rows.push(new Thickness(raw));
    }
    return rows;
  } finally {
    l.thicknesses_free(h);
  }
}

/** A number the gauge calls take, refused by `what`'s name when it is not one (NaN and the sign are the library's to say). */
function _thicknessNumber(value, what, words) {
  if (typeof value !== 'number') throw new BuildError(`${what}: ${words}, got ${_rtreeShown(value)}`);
  return value;
}
const _thicknessMaximum = (v, what) => _thicknessNumber(v, what, 'the maximum must be positive and finite');
const _thicknessSharp = (v, what) => _thicknessNumber(v, what, 'the sharp angle must be zero or positive and finite');

/** A point as three doubles, refused by `what`'s name when it is not three numbers. */
function _thicknessPoint(point, what) {
  const v = point == null || typeof point === 'string' || typeof point.length !== 'number' ? null : Array.from(point);
  if (v === null || !v.every((x) => typeof x === 'number')) throw new BuildError(`${what}: a point is 3 numbers, got ${_rtreeShown(point)}`);
  if (v.length !== 3) throw new BuildError(`${what}: a point is 3 numbers, got ${v.length}`);
  return Float64Array.from(v);
}

const _thicknessGaugeFinalizer = typeof FinalizationRegistry === 'function'
  ? new FinalizationRegistry((h) => { try { _lib().thickness_gauge_free(h); } catch (_) { /* exiting */ } }) : null;

/**
 * Wall thickness (the nearest-opposing-wall rule: each vertex reads to the nearest triangle that
 * faces against one of its own faces, with the vertex behind it) over `solids`, measured against
 * each other: each solid meshed once at `tolerance` -- absolute, in model units (default 0.01) --
 * then asked as often as needed. A reading's `body` is the solid's index in `solids`. The gauge
 * keeps its own reference to the bodies, so it answers on after the `Solid`s are closed.
 * `close()` frees this handle; so does leaving a `using` block or the garbage collector. Throws
 * `BuildError` for a `tolerance` not positive and finite.
 */
class ThicknessGauge {
  constructor(solids, tolerance = 0.01) {
    const handles = Array.from(solids, (s) => s._handle);
    _thicknessNumber(_tol(tolerance), 'thickness_gauge_new', 'the tolerance must be positive and finite');
    this._pointer = _checked(_lib().thickness_gauge_new(handles, handles.length, _tol(tolerance)), 'thickness_gauge_new');
    if (_thicknessGaugeFinalizer) _thicknessGaugeFinalizer.register(this, this._pointer, this);
  }
  get _handle() {
    if (!this._pointer) throw new BuildError('thickness_gauge: closed');
    return this._pointer;
  }
  get closed() { return this._pointer === null; }
  close() {
    if (this._pointer === null) return;
    const h = this._pointer; this._pointer = null;
    if (_thicknessGaugeFinalizer) _thicknessGaugeFinalizer.unregister(this);
    _lib().thickness_gauge_free(h);
  }
  [DISPOSE]() { this.close(); }
  /** How many bodies the gauge measures. */
  get bodyCount() { return _lib().thickness_gauge_body_count(this._handle); }
  /** The tolerance the gauge meshed its bodies at. */
  get tolerance() {
    const value = _lib().thickness_gauge_tolerance(this._handle);
    if (Number.isNaN(value)) _fail('thickness_gauge_tolerance');
    return value;
  }
  /**
   * One reading per measuring-mesh vertex that has one within `maximum` (positive and finite), by
   * body then vertex; vertices whose interior angle is under `sharpAngle` radians (zero or more,
   * 0 by default) are knife edges. Throws `BuildError` for a bad limit.
   */
  thickness(maximum, sharpAngle = 0) {
    const what = 'thickness_gauge_measure';
    const h = this._handle;
    return _thicknessesOf(_lib().thickness_gauge_measure(h, _thicknessMaximum(maximum, what), _thicknessSharp(sharpAngle, what)), what);
  }
  /**
   * The reading at `point`'s foot on face `face` of body `body` (its `vertex` null), or null where
   * the foot lies off the face or the wall is thicker than `maximum`. Throws `BuildError` for a
   * body or face past the end, a point not finite or a bad limit.
   */
  thicknessAt(body, face, point, maximum, sharpAngle = 0) {
    const what = 'thickness_gauge_at';
    const h = this._handle;
    const p = _thicknessPoint(point, what);
    const rows = _thicknessesOf(_lib().thickness_gauge_at(h, _rtreeU32(body, what, 'body'), _rtreeU32(face, what, 'face'), p,
      _thicknessMaximum(maximum, what), _thicknessSharp(sharpAngle, what)), what);
    return rows.length ? rows[0] : null;
  }
  /**
   * One thickness for face `face` of body `body`: measured at `at`'s foot on the face or, with
   * `at` null (the default), over the face's vertices; the other bodies are measured with it. The
   * `maximum` has no default. Null where nothing is found (nothing reads under `maximum`, or
   * `at`'s foot lies off the face). Throws `BuildError` for a body or face past the end, an `at`
   * not finite or a bad maximum.
   */
  thicknessAtFace(body, face, { at = null, maximum } = {}) {
    const what = 'thickness_gauge_face';
    const h = this._handle;
    const where = at == null ? null : _thicknessPoint(at, what);
    const out = {};
    if (!_lib().thickness_gauge_face(h, _rtreeU32(body, what, 'body'), _rtreeU32(face, what, 'face'), where, _thicknessMaximum(maximum, what), out)) _fail(what);
    return out.found ? new FaceThickness(out) : null;
  }
  /** Body `body`'s measuring mesh, copied out (it outlives the gauge). Throws `BuildError` for a body past the end. */
  mesh(body) {
    const what = 'thickness_gauge_mesh';
    const h = this._handle;
    const raw = {};
    if (!_lib().thickness_gauge_mesh(h, _rtreeU32(body, what, 'body'), raw)) _fail(what);
    const n = raw.vertex_count, t = raw.triangle_count;
    const positions = Array.from(_doublesAt(raw.positions, n * 3) ?? []);
    const normals = Array.from(_doublesAt(raw.normals, n * 3) ?? []);
    const indices = Array.from(_uint32s(raw.indices, t * 3) ?? []);
    const faces = Array.from(_uint32s(raw.faces, t) ?? []);
    const triples = (flat, k) => Array.from({ length: k }, (_, i) => [flat[3 * i], flat[3 * i + 1], flat[3 * i + 2]]);
    return new ThicknessMesh(triples(positions, n), triples(normals, n), triples(indices, t), faces);
  }
}

/** `new ThicknessGauge(solids, tolerance).thickness(maximum, sharpAngle)` on a gauge used once and freed: every reading within `maximum` on the solids, measured against each other. */
function thickness(solids, maximum, sharpAngle = 0, tolerance = 0.01) {
  const gauge = new ThicknessGauge(solids, _tol(tolerance));
  try {
    return gauge.thickness(maximum, sharpAngle);
  } finally {
    gauge.close();
  }
}

/**
 * The nearest-opposing-wall rule on plain meshes measured against each other: each mesh a
 * `{ positions, triangles }` object or a `[positions, triangles]` pair -- `[x, y, z]` points and
 * triples of indices into its own points. One reading per vertex that has one within `maximum`
 * (positive and finite), by mesh then vertex; `sharpAngle` as for `ThicknessGauge.thickness`.
 * Throws `BuildError` for a mesh that is not such a pair, a triangle past its mesh, a position
 * not finite or a bad limit.
 */
function meshThickness(meshes, maximum, sharpAngle = 0) {
  const what = 'mesh_thickness';
  const positions = [], indices = [], vertexCounts = [], triangleCounts = [];
  const asList = (v) => (v != null && typeof v !== 'string' && typeof v[Symbol.iterator] === 'function' ? Array.from(v) : null);
  Array.from(meshes).forEach((mesh, m) => {
    const pair = Array.isArray(mesh) && mesh.length === 2 ? mesh
      : mesh != null && typeof mesh === 'object' && !Array.isArray(mesh) && 'positions' in mesh && 'triangles' in mesh ? [mesh.positions, mesh.triangles] : null;
    const points = pair === null ? null : asList(pair[0]);
    const triangles = pair === null ? null : asList(pair[1]);
    if (points === null || triangles === null) throw new BuildError(`${what}: mesh ${m} is not a (positions, triangles) pair`);
    points.forEach((p, i) => {
      const xyz = asList(p);
      if (xyz === null || xyz.length !== 3 || !xyz.every((v) => typeof v === 'number')) throw new BuildError(`${what}: mesh ${m} position ${i} is not three numbers`);
      positions.push(...xyz);
    });
    vertexCounts.push(points.length);
    triangles.forEach((t, i) => {
      const ijk = asList(t);
      if (ijk === null || ijk.length !== 3 || !ijk.every((v) => typeof v === 'number' && Number.isInteger(v) && v >= 0 && v <= NONE)) {
        throw new BuildError(`${what}: mesh ${m} triangle ${i} is not three indices`);
      }
      indices.push(...ijk);
    });
    triangleCounts.push(triangles.length);
  });
  const l = _lib();
  const h = l.mesh_thickness(Float64Array.from(positions), Uint32Array.from(vertexCounts), Uint32Array.from(indices), Uint32Array.from(triangleCounts),
    vertexCounts.length, _thicknessMaximum(maximum, what), _thicknessSharp(sharpAngle, what));
  _checked(h, what);
  try {
    const rows = [];
    for (let i = 0, n = l.mesh_thicknesses_count(h); i < n; i++) {
      const raw = {};
      if (!l.mesh_thicknesses_at(h, i, raw)) throw new BuildError(_lastError() || 'mesh_thicknesses_at');
      rows.push(new MeshThickness(raw));
    }
    return rows;
  } finally {
    l.mesh_thicknesses_free(h);
  }
}

// ---- merge regions --------------------------------------------------------------------------

/** One side of one face, as a region lists it: a plain frozen `{ face, sense }`. */
const _faceSide = (face, sense) => Object.freeze({ face, sense });
/** One region, as `Solid.regions` answers it: a plain frozen `{ index, finite, box, sides, shells }`. */
const _region = (index, finite, lo, hi, sides, shells) => Object.freeze({ index, finite, box: new Box(lo, hi), sides: Object.freeze(sides), shells });

/**
 * A solid's regions: the native `CadaclysmBlacksmithRegions *` read and freed on every path, or the
 * wasm's flat array -- per region `finite, min x3, max x3, sides, shells`, then `sides` pairs
 * `(face, sense)` -- which must decode exactly. A null list is the call's refusal.
 */
function _regions(list) {
  _checked(list, 'regions');
  if (list.regionRows) {
    const v = list.regionRows, out = [];
    const odd = () => new BuildError(`regions: the wasm returned ${v.length} figures, which are not whole regions`);
    let k = 0;
    while (k < v.length) {
      if (k + 9 > v.length) throw odd();
      const n = v[k + 7], shells = v[k + 8];
      if (!Number.isInteger(n) || n < 0 || k + 9 + 2 * n > v.length) throw odd();
      const sides = [];
      for (let j = 0; j < n; j++) sides.push(_faceSide(v[k + 9 + 2 * j], v[k + 10 + 2 * j]));
      out.push(_region(out.length, v[k] === 1, v.slice(k + 1, k + 4), v.slice(k + 4, k + 7), sides, shells));
      k += 9 + 2 * n;
    }
    return out;
  }
  const l = _lib();
  try {
    const n = l.regions_count(list);
    const out = [];
    for (let i = 0; i < n; i++) {
      const raw = {};
      if (!l.regions_at(list, i, raw)) _fail('regions_at');
      const sides = [];
      for (let k = 0; k < raw.sides; k++) {
        const side = {};
        if (!l.regions_side_at(list, i, k, side)) _fail('regions_side_at');
        sides.push(_faceSide(side.face, side.sense));
      }
      out.push(_region(i, raw.finite !== 0, Array.from(raw.min), Array.from(raw.max), sides, raw.shells));
    }
    return out;
  } finally {
    l.regions_free(list);
  }
}

// ---- the interpolator -----------------------------------------------------------------------

/** The interpolator's modes by name, at the C constants' values (`CADACLYSM_BLACKSMITH_INTERPOLATE_*`). */
const _INTERPOLATOR_MODES = Object.freeze({ nearest: 0, linear: 1, cosine: 2, cubic: 3, catmull_rom: 4 });

/** A mode's C value; a name not among the five is refused here, before any call. */
function _interpolatorMode(mode) {
  if (typeof mode === 'string' && Object.prototype.hasOwnProperty.call(_INTERPOLATOR_MODES, mode)) return _INTERPOLATOR_MODES[mode];
  throw new TypeError(`interpolator: mode ${_rtreeShown(mode)} is not one of ${Object.keys(_INTERPOLATOR_MODES).join(', ')}`);
}

/** `v` as numbers, or null when it is not a list of numbers (a string is not). */
function _interpolatorRow(v) {
  if (v == null || typeof v === 'string' || typeof v.length !== 'number') return null;
  const row = Array.from(v);
  return row.every((x) => typeof x === 'number') ? row : null;
}

const _interpolatorFinalizer = typeof FinalizationRegistry === 'function'
  ? new FinalizationRegistry((h) => { try { _lib().interpolator_free(h); } catch (_) { /* exiting */ } }) : null;

/**
 * A list of samples read at a fractional index, as Rhino's `Interpolator`: `t = 2` is sample 2,
 * `t = 2.5` halfway between samples 2 and 3. `samples` are numbers (dimension 1, answered as
 * numbers) or equal-length arrays of numbers -- 2D, 3D or any dimension, answered as arrays, each
 * component read on its own. An open list clamps `t` to `[0, count - 1]`; a `cyclic` one wraps it
 * with period `count`.
 *
 * The modes are Python's names: `'nearest'`, `'linear'` (the default), `'cosine'`, `'cubic'` and
 * `'catmull_rom'`; a name not among them throws a `TypeError` before any call. An interpolator
 * never changes once made. `close()` frees it; so does leaving a `using` block or the garbage
 * collector.
 */
class Interpolator {
  constructor(samples, cyclic = false) {
    this._pointer = null;
    const rows = Array.from(samples);
    let flat, dimension;
    if (rows.length && rows.every((v) => typeof v === 'number')) {
      flat = rows; dimension = 1;
    } else {
      const tuples = rows.map(_interpolatorRow);
      if (tuples.some((row) => row === null)) throw new TypeError('interpolator: samples are all numbers or all arrays of numbers');
      dimension = tuples.length ? tuples[0].length : 1;
      if (tuples.some((row) => row.length !== dimension)) {
        throw new TypeError(`interpolator: samples differ in length (${[...new Set(tuples.map((row) => row.length))].sort((a, b) => a - b).join(', ')})`);
      }
      flat = tuples.flat();
    }
    this._dimension = dimension;
    this._pointer = _checked(_lib().interpolator_new(Float64Array.from(flat), rows.length, dimension, Boolean(cyclic)), 'interpolator_new');
    if (_interpolatorFinalizer) _interpolatorFinalizer.register(this, this._pointer, this);
  }
  get _handle() {
    if (!this._pointer) throw new BuildError('interpolator: closed');
    return this._pointer;
  }
  get closed() { return this._pointer === null; }
  close() {
    if (this._pointer === null) return;
    const h = this._pointer; this._pointer = null;
    if (_interpolatorFinalizer) _interpolatorFinalizer.unregister(this);
    _lib().interpolator_free(h);
  }
  [Symbol.for('nodejs.dispose')]() { this.close(); }
  /** How many samples. */
  get count() { return _lib().interpolator_count(this._handle); }
  /** How many numbers per sample: 1 answers numbers, more answers arrays. */
  get dimension() { return _lib().interpolator_dimension(this._handle); }
  /** Whether `t` wraps round the list (else it is clamped to the ends). */
  get cyclic() { return Boolean(_lib().interpolator_cyclic(this._handle)); }
  /** `d` numbers as an answer: a number at dimension 1, an array otherwise. */
  _value(values) { return this._dimension === 1 ? values[0] : Array.from(values); }
  /** The value at the fractional index `t` by `mode` (`'linear'` by default). Throws `BuildError` for a `t` that is NaN or infinite. */
  at(t, mode = 'linear') {
    const m = _interpolatorMode(mode), h = this._handle;
    if (typeof t !== 'number') throw new TypeError(`interpolator_at: t must be a number, not ${_rtreeShown(t)}`);
    const d = this._dimension;
    const out = new Float64Array(d);
    if (!_lib().interpolator_at(h, t, m, out, d)) _fail('interpolator_at');
    return this._value(out);
  }
  /**
   * The values at every `t` of `ts` by `mode`, as `at` reads each, in one call. Throws `BuildError`
   * for a value of `t` that is NaN or infinite (by its index) and more than 1,000,000 values.
   */
  sample(ts, mode = 'linear') {
    const m = _interpolatorMode(mode), h = this._handle;
    const values = Array.from(ts);
    values.forEach((t, k) => { if (typeof t !== 'number') throw new TypeError(`interpolator_sample: t ${k} must be a number, not ${_rtreeShown(t)}`); });
    if (!values.length) return [];
    const d = this._dimension;
    const out = new Float64Array(values.length * d);
    if (!_lib().interpolator_sample(h, Float64Array.from(values), values.length, m, out, out.length)) _fail('interpolator_sample');
    const answers = [];
    for (let k = 0; k < out.length; k += d) answers.push(this._value(out.subarray(k, k + d)));
    return answers;
  }
  /** The sample at `floor(t + 1/2)` (a half rounds up), after the clamp or wrap. */
  nearest(t) { return this.at(t, 'nearest'); }
  /** Straight between the two samples either side of `t`. */
  linear(t) { return this.at(t, 'linear'); }
  /** Between the two samples either side of `t` on a cosine ease, flat at every sample. */
  cosine(t) { return this.at(t, 'cosine'); }
  /** Bourke's cubic over the four samples about `t`, through every sample. */
  cubic(t) { return this.at(t, 'cubic'); }
  /** The Catmull-Rom spline over the four samples about `t`: through every sample, C1. */
  catmullRom(t) { return this.at(t, 'catmull_rom'); }
}

// ---- NurbsCurve: curves in space ------------------------------------------------------------

/** `NurbsCurve.tween`'s methods, as `cadaclysm_blacksmith_nurbs_curve_tween` numbers them. */
const _TWEEN_METHODS = Object.freeze({ plain: 0, matching: 1, sampling: 2 });

/** `value` as a C `uint32_t`: a whole number from 0 to 4294967295, refused here, named, rather than wrapped by koffi. */
function _curveU32(value, what) {
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 0 || value > 0xffffffff) {
    throw new BuildError(`${what} must be a whole number from 0 to 4294967295, not ${String(value)}`);
  }
  return value;
}

/** Points as the flat array of three numbers each, and their count; an empty list padded for koffi, which passes a zero-length array as null. */
function _curveXyz(points, what) {
  const flat = [];
  for (const p of points) {
    const q = Array.from(p, Number);
    if (q.length !== 3) throw new BuildError(`${what}: a point has three coordinates, not ${q.length}`);
    flat.push(...q);
  }
  const n = flat.length / 3;
  return [n || _wasm() ? Float64Array.from(flat) : new Float64Array(3), n];
}

/** A direction as three numbers, or null for the C ABI's NULL (never an empty array). */
function _curveVec3(v) {
  if (v == null) return null;
  const q = Array.from(v, Number);
  if (q.length !== 3) throw new BuildError(`a vector has three coordinates, not ${q.length}`);
  return Float64Array.from(q);
}

/** An optional list of numbers as an array, or null for none -- an empty list is not none. */
function _curveNumbers(v) {
  if (v == null) return null;
  const q = Float64Array.from(Array.from(v, Number));
  return q.length || _wasm() ? q : null;
}

/** Curves as the list of their handles. */
function _curveHandles(curves) { return Array.from(curves, (c) => c._handle); }

const _SHEET_SIDES = Object.freeze({ u0: 0, u1: 1, v0: 2, v1: 3 });
/** A sheet's side name as the C ABI's number. */
function _sheetSide(side) {
  if (typeof side !== 'string' || !Object.hasOwn(_SHEET_SIDES, side)) throw new BuildError(`a side is 'u0', 'u1', 'v0' or 'v1', not '${String(side)}'`);
  return _SHEET_SIDES[side];
}

/** A fitted sheet's handle as a `Solid` carrying the error its fit reached. */
function _sheetWithError(handle, err) {
  const s = new Solid(handle);
  s._sheetError = err[0];
  return s;
}

/**
 * How well two faces meet along their sides (`Solid.continuity`): the largest `gap` between the
 * sides (G0), the largest `angle` between their normals in radians (G1), the largest difference of
 * normal `curvature` across the edge (G2), each with where it was found (`gapAt`, `angleAt`,
 * `curvatureAt`, points), and how many points were asked (`samples`). Frozen.
 */
class Continuity {
  constructor(raw) {
    this.gap = raw.gap;
    this.gapAt = Array.from(raw.gap_at);
    this.angle = raw.angle;
    this.angleAt = Array.from(raw.angle_at);
    this.curvature = raw.curvature;
    this.curvatureAt = Array.from(raw.curvature_at);
    this.samples = raw.samples;
    Object.freeze(this);
  }
}

/**
 * How smoothly a curve runs through its own knots (`NurbsCurve.knotContinuity`; a closed curve's
 * seam among them): the largest turn of its tangent in radians (`angle`) and the largest jump of
 * its curvature vector `kappa * normal` (`curvature`), each with the parameter (`angleParameter`,
 * `curvatureParameter`) and the point (`angleAt`, `curvatureAt`) it was found at. A curve with no
 * inner knot reads zero at its start. Frozen.
 */
class KnotContinuity {
  constructor(raw) {
    this.angle = raw.angle;
    this.angleParameter = raw.angle_parameter;
    this.angleAt = Array.from(raw.angle_at);
    this.curvature = raw.curvature;
    this.curvatureParameter = raw.curvature_parameter;
    this.curvatureAt = Array.from(raw.curvature_at);
    Object.freeze(this);
  }
}

/**
 * Where a face's curvatures change sign (`Solid.curvatureTurns`): how many separate areas the
 * sample grid finds where the Gaussian curvature is positive and negative (`gaussianPositive`,
 * `gaussianNegative`) and the mean curvature (`meanPositive`, `meanNegative`, about the face's
 * outward normal), and the points between opposite signs (`gaussianTurns`, `meanTurns`: `At`
 * records, `tangent` the face's unit normal there, `parameter` its `u`), and the grid's steps
 * (`samples`). A sample within a millionth of the face's size of flat is neither sign. Frozen.
 */
class CurvatureTurns {
  constructor(raw, gaussianTurns, meanTurns) {
    this.gaussianPositive = raw.gaussian_positive;
    this.gaussianNegative = raw.gaussian_negative;
    this.gaussianTurns = gaussianTurns;
    this.meanPositive = raw.mean_positive;
    this.meanNegative = raw.mean_negative;
    this.meanTurns = meanTurns;
    this.samples = raw.samples;
    Object.freeze(this);
  }
}

/**
 * The worst kink of the highlight lines crossing an edge (`Solid.highlightKink`): the `angle` in
 * radians (0 to pi/2) between a line on one face and the same line on the other, the point `at`
 * along the edge, and the light that shows it -- a straight tube through `lightPoint` along
 * `lightDirection` (unit) -- from `samples` points along the edge. Frozen.
 */
class HighlightKink {
  constructor(raw) {
    this.angle = raw.angle;
    this.at = Array.from(raw.at);
    this.lightPoint = Array.from(raw.light_point);
    this.lightDirection = Array.from(raw.light_direction);
    this.samples = raw.samples;
    Object.freeze(this);
  }
}

/**
 * How well an N-sided patch (`Solid.nSidedPatch`) meets: `faces` sub-patches, the worst `boundary`
 * `Continuity` against the neighbours (the gap over every side, the angle over those met at G1 or
 * G2, the curvature jump over those at G2), the worst `internal` one across the patch's own spokes,
 * and `cornerAngle` (radians), the most a corner of the hole leaves no patch able to meet: zero
 * where the neighbours meet each other at G1. Frozen.
 */
class PatchReport {
  constructor(raw) {
    this.faces = raw.faces;
    this.boundary = new Continuity(raw.boundary);
    this.internal = new Continuity(raw.internal);
    this.cornerAngle = raw.corner_angle;
    Object.freeze(this);
  }
}

/**
 * What `Solid.joinSheets` did: `sewn` edges (each two naked edges become one shared edge), the
 * widest `worstGap` between two sewn edges (0 where all met exactly), the naked edges -- bordered
 * by one face -- `nakedBefore` (once the T-junctions are cut) and `nakedAfter`, `refused` groups of
 * naked edges that share both ends but were left apart (too far apart, or three or more), faces
 * `turned`, and whether the result is `closed`: a solid. Frozen.
 */
class JoinReport {
  constructor(raw) {
    this.sewn = raw.sewn;
    this.worstGap = raw.worst_gap;
    this.nakedBefore = raw.naked_before;
    this.nakedAfter = raw.naked_after;
    this.refused = raw.refused;
    this.turned = raw.turned;
    this.closed = Boolean(raw.closed);
    Object.freeze(this);
  }
}

/**
 * What `Solid.mirrorJoin` did: the `seams` (edges on the plane, one face of the half and one of
 * its mirror), the faces `squared` to the plane and the furthest a control point `moved` doing
 * it; the seam's worst `gap`, `angle` between the two sides' normals (radians) and `curvature`
 * (the largest difference of their normal curvatures in any one direction); and the `naked`
 * edges left on the body. Frozen.
 */
class SymmetryReport {
  constructor(raw) {
    this.seams = raw[0];
    this.squared = raw[1];
    this.moved = raw[2];
    this.gap = raw[3];
    this.angle = raw[4];
    this.curvature = raw[5];
    this.naked = raw[6];
    Object.freeze(this);
  }
}

// The C ABI's codes for the holes, ribs and webs, patterns choices (`CADACLYSM_BLACKSMITH_HOLE_*`, ...).
const _HOLE_EXTENTS = Object.freeze({ through: 0, blind: 1, to_face: 2, to_next: 3 });
const _HOLE_HEADS = Object.freeze({ simple: 0, counterbore: 1, countersink: 2 });
const _FEATURE_OPS = Object.freeze({ cut: 0, join: 1 });
const _RIB_SIDES = Object.freeze({ both: 0, front: 1, back: 2 });
const _WEB_SIDES = Object.freeze({ both: 0, left: 1, right: 2 });
const _ORIENTS = Object.freeze({ fixed: 0, path: 1 });

/** `value`'s code in `table` (null: a head's `'simple'`); `BuildError` naming the call and the choices otherwise. */
function _featureChoice(table, value, what, name) {
  if (value === null && table === _HOLE_HEADS) return 0;
  if (typeof value === 'string' && Object.hasOwn(table, value)) return table[value];
  const known = Object.keys(table).map((k) => `'${k}'`).join(', ');
  throw new BuildError(`${what}: ${name} ${typeof value === 'string' ? `'${value}'` : String(value)} is not one of ${known}`);
}

/** Transforms (or 16 numbers each) as the flat C array of 16 doubles each, and their count. */
function _transforms(transforms, what) {
  const list = Array.from(transforms, (t) => _matrix(t, what));
  const flat = new Float64Array(16 * list.length);
  list.forEach((m, i) => flat.set(m, 16 * i));
  return [list.length || _wasm() ? flat : new Float64Array(16), list.length];
}

/** Instance indices to leave out, as the C array: null for none natively (koffi passes an empty array as null anyway), the empty array over the wasm. */
function _skips(skip) {
  const s = Array.from(skip, Number);
  for (const i of s) if (!Number.isInteger(i) || i < 0) throw new BuildError(`skip: instance index ${i} is not a whole number from 0`);
  return s.length || _wasm() ? Uint32Array.from(s) : null;
}

/** A hole's (or its tool's) C arguments, after the solid; `o` the options object. */
function _holeArgs(solid, what, points, diameter, o) {
  const { direction = null, extent = 'through', depth = null, tipAngle = 118 * Math.PI / 180, face = null, head = null,
    headDiameter = 0, headDepth = 0, headAngle = Math.PI / 2, tolerance = null } = o;
  const ext = _featureChoice(_HOLE_EXTENTS, extent, what, 'extent');
  const kind = _featureChoice(_HOLE_HEADS, head, what, 'head');
  const list = Array.from(points);
  const [flat, n] = _curveXyz(list.length === 3 && list.every((v) => typeof v === 'number') ? [list] : list, what);
  return [solid._handle, flat, n, Number(diameter), _curveVec3(direction), ext, depth == null ? NaN : Number(depth), Number(tipAngle),
    face == null ? NONE : Number(face), kind, Number(headDiameter), Number(headDepth), Number(headAngle), _tol(tolerance)];
}

/**
 * What `Solid.pattern` or `Solid.patternFeature` did: the `instances` placed (after the skips),
 * the `booleans` run (copies apart from each other share one), and the copies of a feature's
 * tool `missed` -- sharing no volume with the body, dropped for a cut and kept as a body of their
 * own for a join. Frozen.
 */
class PatternReport {
  constructor(raw) {
    this.instances = raw[0];
    this.booleans = raw[1];
    this.missed = raw[2];
    Object.freeze(this);
  }
}

/**
 * What `Solid.hole` did: the `holes` drilled (one a point), per hole the `bottoms` -- the
 * distance along the axis from the point to where the bore ends, the drill point excluded
 * (`depth` for a blind hole; for the others the deepest point of the material it passes, rim
 * included) -- and `facesAdded`, the result's faces on no surface of the body. Frozen.
 */
class HoleReport {
  constructor(raw, bottoms) {
    this.holes = raw[0];
    this.bottoms = Object.freeze(Array.from(bottoms, Number));
    this.facesAdded = raw[1];
    Object.freeze(this);
  }
}

/**
 * Placements for `Solid.pattern` and `Solid.patternFeature`: lists of rigid `Transform`s,
 * instance 0 the identity (the original). `skip` leaves instances out by index (Fusion's
 * suppressed instances), 0 included. Angles are radians.
 */
class Pattern {
  constructor() { throw new TypeError('Pattern: a namespace of static functions, not a class to construct'); }
  static _placements(what, call) {
    const n = call(null);
    if (!n) _fail(what);
    const out = new Float64Array(16 * n);
    if (call(out) !== n) _fail(what);
    const placements = [];
    for (let i = 0; i < n; i++) placements.push(new Transform(out.subarray(16 * i, 16 * i + 16)));
    return placements;
  }
  /**
   * `count1` instances `spacing1` apart along `direction1`, times `count2` `spacing2` apart along
   * `direction2` (null: one row); row-major, direction 1 fastest. `symmetric` puts `count` on
   * each side of the original along each direction (`2 count - 1`, at offsets `0, +s, -s, +2s,
   * ...`). Throws `BuildError` for a count of 0, a spacing not finite, a zero direction, a skip
   * past the count, or every instance skipped.
   */
  static rectangular(direction1, count1, spacing1, direction2 = null, count2 = 1, spacing2 = 0, symmetric = false, skip = []) {
    const s = _skips(skip);
    const d1 = _doubles(direction1, 3, 'pattern_rectangular'), d2 = _curveVec3(direction2);
    return Pattern._placements('pattern_rectangular', (out) => _lib().pattern_rectangular(
      d1, _curveU32(count1, 'pattern_rectangular: count1'), Number(spacing1), d2, _curveU32(count2, 'pattern_rectangular: count2'), Number(spacing2),
      Boolean(symmetric), s, s == null ? 0 : s.length, out));
  }
  /**
   * `count` instances about the line through `axisPoint` along `axisDirection`: a full turn
   * (`angle` 2 pi) spaces them evenly, less spreads them over `angle` with both ends occupied.
   * `symmetric` spreads `count` over `angle` on each side (not with a full turn). Radians,
   * right-handed about the direction.
   */
  static circular(axisPoint, axisDirection, count, angle = 2 * Math.PI, symmetric = false, skip = []) {
    const s = _skips(skip);
    const axis = _doubles([...Array.from(axisPoint), ...Array.from(axisDirection)], 6, 'pattern_circular');
    return Pattern._placements('pattern_circular', (out) => _lib().pattern_circular(
      axis, _curveU32(count, 'pattern_circular: count'), Number(angle), Boolean(symmetric), s, s == null ? 0 : s.length, out));
  }
  /**
   * `count` instances along `curve` by arc length from its start, `spacing` apart, or spread over
   * its whole length with both ends occupied (`spacing` null). `orient` `'fixed'` translates each
   * copy; `'path'` also turns it by the curve's rotation-minimising frame from the first
   * instance's.
   */
  static along(curve, count, spacing = null, orient = 'fixed', skip = []) {
    const code = _featureChoice(_ORIENTS, orient, 'pattern_along', 'orient');
    const s = _skips(skip);
    return Pattern._placements('pattern_along', (out) => _lib().pattern_along(
      curve._handle, _curveU32(count, 'pattern_along: count'), spacing == null ? NaN : Number(spacing), code, s, s == null ? 0 : s.length, out));
  }
}

const _nurbsCurveFinalizer = typeof FinalizationRegistry === 'function'
  ? new FinalizationRegistry((h) => { try { _lib().nurbs_curve_free(h); } catch (_) { /* exiting */ } }) : null;

/**
 * A curve's bending at a parameter (`NurbsCurve.curvature`): `kappa` (1 / radius), the unit
 * `tangent`, the unit `normal` toward the centre, the `binormal` (`tangent x normal`) and the
 * `centre` of the osculating circle -- null on a straight piece, where `kappa` is 0 and `normal`
 * and `binormal` are zero. Frozen.
 */
class Curvature {
  constructor(raw) {
    this.kappa = raw.kappa;
    this.tangent = Array.from(raw.tangent);
    this.normal = Array.from(raw.normal);
    this.binormal = Array.from(raw.binormal);
    this.centre = raw.has_centre ? Array.from(raw.centre) : null;
    Object.freeze(this);
  }
}

/**
 * A curve in space -- always a NURBS, so a line, an arc or a conic is an exact rational one --
 * to model with: built through points, read off an edge or a face, projected onto a plane or a
 * face, trimmed, extended and blended; asked for its points, derivatives, curvature, length and
 * crossings. Immutable; every edit returns a new curve. `close()` frees it; so does leaving a
 * `using` block or the garbage collector.
 *
 * Not `Curve`, which is the plain data an edge's curve is copied out as; `NurbsCurve.fromEdge`
 * turns an edge into one of these. A face here is its whole surface: projecting onto, pulling to
 * and crossing a face ignore its trims.
 */
class NurbsCurve {
  /**
   * The curve with control points `points`, of `degree` (1 to 7), `weights` one per point
   * (positive) or null, and the full knot vector `knots` (`points.length + degree + 1` values,
   * non-decreasing) or null for clamped and uniform.
   */
  constructor(points, degree = 3, weights = null, knots = null) {
    this._pointer = null;
    this.fitError = null;
    const [xyz, n] = _curveXyz(points, 'nurbs_curve_new');
    const w = weights == null ? null : Array.from(weights, Number);
    const k = knots == null ? null : Array.from(knots, Number);
    if (w !== null && w.length !== n) throw new BuildError(`nurbs_curve_new: ${w.length} weights for ${n} points; give one per point`);
    this._adopt(_lib().nurbs_curve_new(
      xyz, n, _curveNumbers(w), _curveU32(degree, 'nurbs_curve_new: degree'), _curveNumbers(k), k === null ? 0 : k.length), 'nurbs_curve_new');
  }
  _adopt(handle, what, fitError = null) {
    this._pointer = _checked(handle, what);
    this.fitError = fitError;
    if (_nurbsCurveFinalizer) _nurbsCurveFinalizer.register(this, this._pointer, this);
  }
  static _of(handle, what, fitError = null) {
    const c = Object.create(NurbsCurve.prototype);
    c._pointer = null;
    c.fitError = null;
    c._adopt(handle, what, fitError);
    return c;
  }
  get _handle() {
    if (!this._pointer) throw new BuildError('nurbs_curve: closed');
    return this._pointer;
  }
  get closed() { return this._pointer === null; }
  close() {
    if (this._pointer === null) return;
    const h = this._pointer; this._pointer = null;
    if (_nurbsCurveFinalizer) _nurbsCurveFinalizer.unregister(this);
    _lib().nurbs_curve_free(h);
  }
  [Symbol.for('nodejs.dispose')]() { this.close(); }

  // ---- building -----------------------------------------------------------------------

  /**
   * The curve of `degree` (1 to 7) through `points` in order, chord-length parametrised.
   * `closed` closes it back to the first point, smooth across the seam; an open curve may leave
   * along `startTangent` and arrive along `endTangent` (directions; their length does not matter).
   */
  static through(points, degree = 3, closed = false, startTangent = null, endTangent = null) {
    const [xyz, n] = _curveXyz(points, 'nurbs_curve_through');
    return NurbsCurve._of(_lib().nurbs_curve_through(
      xyz, n, _curveU32(degree, 'nurbs_curve_through: degree'), Boolean(closed), _curveVec3(startTangent), _curveVec3(endTangent)), 'nurbs_curve_through');
  }
  /**
   * A curve of `degree` within `tolerance` of every point, through the first and the last (least
   * squares); its `fitError` is the largest distance from a point to it. A null `tolerance` asks
   * for the inputs' effective tolerance.
   */
  static fit(points, degree = 3, tolerance = 1e-3) {
    const [xyz, n] = _curveXyz(points, 'nurbs_curve_fit');
    const err = new Float64Array(1);
    const h = _lib().nurbs_curve_fit(xyz, n, _curveU32(degree, 'nurbs_curve_fit: degree'), _tol(tolerance), err);
    return NurbsCurve._of(h, 'nurbs_curve_fit', err[0]);
  }
  /**
   * The smoothest curve of `degree` (3 to 7) within `tolerance` of every point, through the first
   * and the last: least squares plus the curvature's derivative squared, weighed as heavily as the
   * tolerance allows -- where `fit` follows the points' noise, this spends the tolerance on a calm
   * curvature comb. `noInflection` true keeps the curvature from turning over anywhere; a pair of
   * point indices `[i, j]` (fractions between points, null an open end) only between those points.
   * Throws `BuildError` where no such curve is within the tolerance. Its `fitError` is the largest
   * distance from a point to it; a null `tolerance` asks for the inputs' effective tolerance.
   */
  static fair(points, degree = 5, tolerance = 1e-3, noInflection = null) {
    const [xyz, n] = _curveXyz(points, 'nurbs_curve_fair');
    const [held, lo, hi] = _noInflection(noInflection);
    const err = new Float64Array(1);
    const h = _lib().nurbs_curve_fair(xyz, n, _curveU32(degree, 'nurbs_curve_fair: degree'), _tol(tolerance), held, lo, hi, err);
    return NurbsCurve._of(h, 'nurbs_curve_fair', err[0]);
  }
  /** Edge `edge` (an `Edge` or its index) of `solid` as an exact NURBS over the edge's own span of its curve, running the way the edge runs. */
  static fromEdge(solid, edge) {
    const e = edge instanceof Edge ? edge.index : edge;
    return NurbsCurve._of(_lib().nurbs_curve_from_edge(solid._handle, _curveU32(e, 'nurbs_curve_from_edge: edge')), 'nurbs_curve_from_edge');
  }
  /** The isocurve of face `face` of `solid`'s surface: along `u` at `v = at` when `alongU`, else along `v` at `u = at`. NURBS faces only. */
  static isocurve(solid, face, alongU, at) {
    return NurbsCurve._of(_lib().nurbs_curve_from_face_isocurve(
      solid._handle, _curveU32(face, 'nurbs_curve_from_face_isocurve: face'), Boolean(alongU), Number(at)), 'nurbs_curve_from_face_isocurve');
  }
  /**
   * The curve bridging `a` (at its end when `aEnd`, else its start) to `b` (at its end when
   * `bEnd`, else its start): `continuity` 1 matches position and tangent (a cubic), 2 also the
   * curvature (a quintic); `bulge` (positive) scales how far the tangents reach.
   */
  static blend(a, aEnd, b, bEnd, continuity = 2, bulge = 1) {
    return NurbsCurve._of(_lib().nurbs_curve_blend(
      a._handle, Boolean(aEnd), b._handle, Boolean(bEnd), _curveU32(continuity, 'nurbs_curve_blend: continuity'), Number(bulge)), 'nurbs_curve_blend');
  }
  /**
   * `curves` joined end to end into one curve (Rhino's JoinCurves): in the order given, each
   * turned where needed so its start meets the previous one's end within `tolerance` (the joint
   * placed at the midpoint of the two ends). All are raised to the highest degree among them and
   * each runs over `k..k + 1`, joined C0 -- a corner stays a corner; a rational curve keeps its
   * points. One curve gives a copy; none, or a gap past `tolerance`, throws `BuildError` naming
   * the two curves.
   */
  static joined(curves, tolerance = 1e-6) {
    const list = Array.from(curves);
    const handles = list.map((c) => c._handle);
    const joined = _lib().nurbs_curve_joined(handles, handles.length, Number(tolerance));
    return NurbsCurve._of(joined, 'nurbs_curve_joined');
  }
  /**
   * `count` curves blending evenly from this curve to `other` (Rhino's CreateTweenCurves family),
   * tween `i` at the fraction `(i + 1) / (count + 1)`. `method`:
   *
   * - `'plain'`: control point by control point; the curves must already share one structure
   *   (degree, control-point count, knots), as Rhino's CreateTweenCurves needs.
   * - `'matching'`: the curves made compatible exactly (degree elevation, knot merging), then
   *   blended in homogeneous coordinates -- rational curves stay rational.
   * - `'sampling'`: both divided by arc length into `samples` pieces (required here, refused
   *   otherwise), and a cubic interpolated through the blended samples.
   *
   * `align` turns `other`, and moves a closed curve's seam, to line it up with this one first.
   * A null `tolerance` asks for the inputs' effective tolerance. A count of 0, one curve closed
   * and the other open, plain on curves that are not compatible, or too few samples throws
   * `BuildError`.
   */
  tween(other, count, method = 'matching', samples = null, align = true, tolerance = null) {
    if (!Object.hasOwn(_TWEEN_METHODS, method)) {
      throw new BuildError(`nurbs_curve_tween: method must be one of ${Object.keys(_TWEEN_METHODS).join(', ')}, not ${JSON.stringify(method)}`);
    }
    if (method === 'sampling') {
      if (samples == null) throw new BuildError('nurbs_curve_tween: sampling needs samples');
    } else if (samples != null) {
      throw new BuildError(`nurbs_curve_tween: samples is read only by sampling, not ${method}`);
    }
    const n = _curveU32(count, 'nurbs_curve_tween: count');
    const s = samples == null ? 0 : _curveU32(samples, 'nurbs_curve_tween: samples');
    const out = new Array(n).fill(null);
    if (!_lib().nurbs_curve_tween(this._handle, other._handle, n, _TWEEN_METHODS[method], s, Boolean(align), _tol(tolerance), out)) _fail('nurbs_curve_tween');
    // every handle is adopted before any can throw, so a refusal frees the rest through their owners
    return out.map((h) => NurbsCurve._of(h, 'nurbs_curve_tween'));
  }

  // ---- edits ----------------------------------------------------------------------------

  /** This curve projected onto the plane through `origin` with `normal`, along `direction` (null: the normal). Exact. */
  projectedToPlane(origin, normal, direction = null) {
    return NurbsCurve._of(_lib().nurbs_curve_projected_to_plane(
      this._handle, _curveVec3(origin), _curveVec3(normal), _curveVec3(direction)), 'nurbs_curve_projected_to_plane');
  }
  /**
   * This curve projected along `direction` onto face `face` of `solid` (its whole surface),
   * fitted within `tolerance`; the result's `fitError` is the largest distance between it and the
   * surface. Throws `BuildError` where a point's ray misses.
   */
  projectedToFace(solid, face, direction, tolerance = 1e-3) {
    const err = new Float64Array(1);
    const h = _lib().nurbs_curve_projected_to_face(
      this._handle, solid._handle, _curveU32(face, 'nurbs_curve_projected_to_face: face'), _curveVec3(direction), _tol(tolerance), err);
    return NurbsCurve._of(h, 'nurbs_curve_projected_to_face', err[0]);
  }
  /** This curve pulled onto face `face` of `solid` (its whole surface): every point to its nearest surface point, fitted within `tolerance` (`fitError` as for the projection). */
  pulledToFace(solid, face, tolerance = 1e-3) {
    const err = new Float64Array(1);
    const h = _lib().nurbs_curve_pulled_to_face(
      this._handle, solid._handle, _curveU32(face, 'nurbs_curve_pulled_to_face: face'), _tol(tolerance), err);
    return NurbsCurve._of(h, 'nurbs_curve_pulled_to_face', err[0]);
  }
  /**
   * This curve, lying on the sheet `solid` (any of its faces, within ten times `tolerance`), offset
   * `distance` along it: each point walked that far across the sheet, square to the curve -- left
   * of its run seen from the outward side for a positive distance -- over the seams of a joined
   * sheet, and fitted within `tolerance`. `fitError` is the larger of the fit's error and its
   * distance off the sheet. Refused where the curve does not lie on the sheet.
   */
  offsetOnSheet(solid, distance, tolerance = 1e-3) {
    const err = new Float64Array(1);
    const h = _lib().nurbs_curve_offset_on_sheet(this._handle, solid._handle, Number(distance), _tol(tolerance), err);
    return NurbsCurve._of(h, 'nurbs_curve_offset_on_sheet', err[0]);
  }
  /** The same curve run the other way over the same domain. */
  reversed() { return NurbsCurve._of(_lib().nurbs_curve_reversed(this._handle), 'nurbs_curve_reversed'); }
  /** The part from `t0` to `t1` (`t0 < t1`, inside the domain), over `t0..t1`. */
  trimmed(t0, t1) { return NurbsCurve._of(_lib().nurbs_curve_trimmed(this._handle, Number(t0), Number(t1)), 'nurbs_curve_trimmed'); }
  /** This curve continued `length` past its end (or start) along its own end polynomial -- position, tangent and curvature there unchanged, every old parameter its old point. */
  extended(length, atStart = false) {
    return NurbsCurve._of(_lib().nurbs_curve_extended(this._handle, Boolean(atStart), Number(length)), 'nurbs_curve_extended');
  }
  /** The same curve at degree `degree + by` (at most 12). */
  elevated(by = 1) { return NurbsCurve._of(_lib().nurbs_curve_elevated(this._handle, _curveU32(by, 'nurbs_curve_elevated: by')), 'nurbs_curve_elevated'); }
  /** This curve through the affine map `t` (a `Transform`, or 16 numbers): its control points mapped, weights and knots kept -- exact. A singular map (a projection) is allowed. */
  transformed(t) {
    return NurbsCurve._of(_lib().nurbs_curve_transformed(this._handle, _matrix(t, 'nurbs_curve_transformed')), 'nurbs_curve_transformed');
  }
  /** A copy: the same curve, a handle of its own. */
  clone() { return NurbsCurve._of(_lib().nurbs_curve_clone(this._handle), 'nurbs_curve_clone'); }

  // ---- reading --------------------------------------------------------------------------

  /** The degree. */
  get degree() { return _lib().nurbs_curve_degree(this._handle); }
  /** The control points, as `[x, y, z]` arrays. */
  get controlPoints() {
    const l = _lib(), h = this._handle;
    const n = l.nurbs_curve_control_count(h);
    const out = new Float64Array(3 * n);
    if (!l.nurbs_curve_control_points(h, out)) _fail('nurbs_curve_control_points');
    return Array.from({ length: n }, (_, i) => [out[3 * i], out[3 * i + 1], out[3 * i + 2]]);
  }
  /** The weights, one per control point (all 1 for a curve that is not rational). */
  get weights() {
    const l = _lib(), h = this._handle;
    const out = new Float64Array(l.nurbs_curve_control_count(h));
    if (!l.nurbs_curve_weights(h, out)) _fail('nurbs_curve_weights');
    return Array.from(out);
  }
  /** The full knot vector. */
  get knots() {
    const l = _lib(), h = this._handle;
    const out = new Float64Array(l.nurbs_curve_knot_count(h));
    if (!l.nurbs_curve_knots(h, out)) _fail('nurbs_curve_knots');
    return Array.from(out);
  }
  /** The parameter range, `[start, end]`. */
  get domain() {
    const out = new Float64Array(2);
    if (!_lib().nurbs_curve_domain(this._handle, out)) _fail('nurbs_curve_domain');
    return [out[0], out[1]];
  }
  /** Whether any weight differs from the others. */
  get isRational() { return Boolean(_lib().nurbs_curve_is_rational(this._handle)); }
  /** Whether the curve ends where it starts. */
  get isClosed() { return Boolean(_lib().nurbs_curve_is_closed(this._handle)); }
  /** The point at parameter `t`, inside the domain. */
  point(t) {
    const out = new Float64Array(3);
    if (!_lib().nurbs_curve_point(this._handle, Number(t), out)) _fail('nurbs_curve_point');
    return Array.from(out);
  }
  /**
   * The nearest point of the curve to `p` over its whole domain, as a `CurveFoot`: its parameter
   * `t`, the `point`, and `unique` -- false where another point of the curve is as near (a point
   * on a circle's axis) and `point` is a pick among them. Exact. With `maxDistance`, null where
   * that point lies beyond it (undefined, null, NaN or Infinity: no limit, the same answer as with
   * none). Throws for a point not finite or a negative `maxDistance`.
   */
  closestPoint(p, maxDistance) {
    const out = new Float64Array(5);
    if (maxDistance == null) {
      if (_lib().nurbs_curve_closest_point(this._handle, _doubles(p, 3, 'nurbs_curve_closest_point'), out) < 0) _fail('nurbs_curve_closest_point');
    } else {
      const found = _lib().nurbs_curve_closest_point_within(this._handle, _doubles(p, 3, 'nurbs_curve_closest_point_within'), maxDistance, out);
      if (found < 0) _fail('nurbs_curve_closest_point_within');
      if (!found) return null;
    }
    return new CurveFoot(out[0], [out[1], out[2], out[3]], out[4] !== 0);
  }
  /**
   * The nearest points of this curve and `other`, as a `CurvePair` (side `a` this curve, distance
   * 0 where they cross; among equal distances the smallest `tA`, then `tB`), or null where they
   * lie farther apart than `maxDistance` (undefined, null, NaN or Infinity: no limit). Exact.
   * Throws for a negative `maxDistance`.
   */
  closestPoints(other, maxDistance) {
    const out = {};
    const found = _lib().nurbs_curve_closest_points(this._handle, other._handle, _unset(maxDistance), out);
    if (found < 0) _fail('nurbs_curve_closest_points');
    return found ? new CurvePair(out) : null;
  }
  /**
   * The item of `items` nearest to this curve, as a `NearestObject` -- `which` its index -- or
   * null where none lies within `maxDistance` (undefined, null, NaN or Infinity: no limit) or the
   * list is empty. Each item is a `Solid`, a `NurbsCurve`, a `Projector`, a `TriangleMesh`
   * (answered exactly) or a point (3 numbers). Items are asked in order, each with the best
   * distance so far as its limit; equal distances go to the earlier item. `tolerance` (undefined, null, 0 or NaN: each solid's effective tolerance)
   * sizes each solid's search; a projector keeps its own, and its lock is held for the whole curve
   * query. Throws for an item that is none of those (naming its index), a point not finite, a
   * negative `maxDistance` or a negative or infinite `tolerance`.
   */
  closestObject(items, maxDistance, tolerance) {
    const what = 'nurbs_curve_closest_object';
    const kinds = [], solids = [], curves = [], points = [], projectors = [], meshes = [];
    // every item held here until the call returns, so none a generator made fresh is collected
    // (and its handle freed by a finalizer) while the library still reads it
    const held = Array.from(items);
    let i = 0;
    for (const item of held) {
      if (item instanceof Solid) { kinds.push(0); solids.push(item._handle); }
      else if (item instanceof NurbsCurve) { kinds.push(1); curves.push(item._handle); }
      else if (item instanceof Projector) { kinds.push(3); projectors.push(item._handle); }
      else if (item instanceof TriangleMesh) { kinds.push(4); meshes.push(item._handle); }
      else if ((Array.isArray(item) || ArrayBuffer.isView(item)) && item.length === 3 && Array.from(item).every((v) => typeof v === 'number')) {
        kinds.push(2); points.push(...item);
      } else {
        let shown;
        try { shown = JSON.stringify(item); } catch (_) { shown = String(item); }
        throw new BuildError(`${what}: item ${i}: not a Solid, a NurbsCurve, a Projector, a TriangleMesh or a point of 3 numbers, got ${shown ?? String(item)}`);
      }
      i++;
    }
    // empty arrays go as null pointers (C reads none when their count is 0)
    const out = {};
    const found = _lib().nurbs_curve_closest_object(this._handle, kinds.length ? Uint8Array.from(kinds) : null, kinds.length,
      solids.length ? solids : null, solids.length, curves.length ? curves : null, curves.length,
      points.length ? Float64Array.from(points) : null, points.length / 3, projectors.length ? projectors : null, projectors.length,
      meshes.length ? meshes : null, meshes.length, _unset(maxDistance), _unset(tolerance), out);
    held.length = 0;
    if (found < 0) _fail(what);
    return found ? new NearestObject(out) : null;
  }
  /** The point and its derivatives at `t` up to `order` (at most 8): `[C, C', C'', ...]`, `order + 1` points. */
  derivatives(t, order = 2) {
    const k = _curveU32(order, 'nurbs_curve_derivatives: order');
    const out = new Float64Array(3 * (Math.min(k, 8) + 1));
    if (!_lib().nurbs_curve_derivatives(this._handle, Number(t), k, out)) _fail('nurbs_curve_derivatives');
    return Array.from({ length: k + 1 }, (_, i) => [out[3 * i], out[3 * i + 1], out[3 * i + 2]]);
  }
  /** The curvature and Frenet frame at `t`, as a `Curvature`. */
  curvature(t) {
    const out = {};
    if (!_lib().nurbs_curve_curvature(this._handle, Number(t), out)) _fail('nurbs_curve_curvature');
    return new Curvature(out);
  }
  /** The curve's length (a `Length` record), to the relative `accuracy` (0 asks for the default). */
  length(accuracy = 0) {
    const out = {};
    if (!_lib().nurbs_curve_length(this._handle, accuracy, out)) _fail('nurbs_curve_length');
    return _lengthOf(out);
  }
  /** The point at arc length `s` from the curve's start, as an `At` record. */
  pointAtLength(s, accuracy = 0) {
    const out = {};
    if (!_lib().nurbs_curve_point_at_length(this._handle, s, accuracy, out)) _fail('nurbs_curve_point_at_length');
    return _atOf(out);
  }
  /** The curve in `n` pieces of equal arc length, as `At` records: `n + 1` samples, `n` for a closed curve. */
  divideByCount(n, accuracy = 0) {
    return _samples(_checked(_lib().nurbs_curve_divide_by_count(this._handle, _count(n, 'nurbs_curve_divide_by_count'), accuracy), 'nurbs_curve_divide_by_count'), 'nurbs_curve_divide_by_count');
  }
  /** Samples every `step` of arc length from the start, as `At` records; a closed curve never repeats it. */
  divideByLength(step, accuracy = 0) {
    return _samples(_checked(_lib().nurbs_curve_divide_by_length(this._handle, step, accuracy), 'nurbs_curve_divide_by_length'), 'nurbs_curve_divide_by_length');
  }
  /**
   * Where the curve crosses the plane through `origin` with `normal`, in parameter order, as `At`
   * records (`error` each point's distance from the plane). Throws `BuildError` for a curve lying
   * in the plane; a touch that does not cross is not listed.
   */
  planeHits(origin, normal) {
    return _samples(_checked(_lib().nurbs_curve_plane_hits(this._handle, _curveVec3(origin), _curveVec3(normal)), 'nurbs_curve_plane_hits'), 'nurbs_curve_plane_hits');
  }
  /** Where the curve crosses face `face` of `solid` (its whole surface), within `tolerance` of it, in parameter order, as `At` records (`error` each point's distance from the surface). */
  faceHits(solid, face, tolerance = 1e-3) {
    return _samples(_checked(_lib().nurbs_curve_face_hits(
      this._handle, solid._handle, _curveU32(face, 'nurbs_curve_face_hits: face'), _tol(tolerance)), 'nurbs_curve_face_hits'), 'nurbs_curve_face_hits');
  }
  /**
   * This curve faired: the smoothest curve of `degree` within `tolerance` of it, from its start to
   * its end, as `NurbsCurve.fair` makes one from points; `noInflection`'s pair is this curve's own
   * parameters here. Its `fitError` is the largest distance found between them.
   */
  faired(degree = 5, tolerance = 1e-3, noInflection = null) {
    const [held, lo, hi] = _noInflection(noInflection);
    const err = new Float64Array(1);
    const h = _lib().nurbs_curve_faired(this._handle, _curveU32(degree, 'nurbs_curve_faired: degree'), _tol(tolerance), held, lo, hi, err);
    return NurbsCurve._of(h, 'nurbs_curve_faired', err[0]);
  }
  /**
   * Where the curvature turns from one side to the other, in parameter order, as `At` records
   * (`error` zero): the comb flipping sides. Empty for a curve that bends one way only.
   */
  inflections() {
    return _samples(_checked(_lib().nurbs_curve_inflections(this._handle), 'nurbs_curve_inflections'), 'nurbs_curve_inflections');
  }
  /** The largest turn of the tangent and jump of the curvature at the curve's knots, as a `KnotContinuity`. */
  knotContinuity() {
    const out = {};
    if (!_lib().nurbs_curve_knot_continuity(this._handle, out)) _fail('nurbs_curve_knot_continuity');
    return new KnotContinuity(out);
  }
  /**
   * A curvature comb to draw: at `n + 1` even parameters, the curve point and that point moved by
   * `-scale * kappa * normal` (out of the bend), as `[point, tooth]` pairs. Straight stretches
   * give zero teeth.
   */
  comb(n = 64, scale = 1) {
    const [lo, hi] = this.domain;
    const steps = Math.max(Math.trunc(n), 1);
    const out = [];
    for (let i = 0; i <= steps; i++) {
      const t = lo + (hi - lo) * i / steps;
      const k = this.curvature(t);
      const p = this.point(t);
      out.push([p, [p[0] - scale * k.kappa * k.normal[0], p[1] - scale * k.kappa * k.normal[1], p[2] - scale * k.kappa * k.normal[2]]]);
    }
    return out;
  }
  toString() {
    const [lo, hi] = this.domain;
    return `NurbsCurve(degree=${this.degree}, controls=${this.controlPoints.length}, rational=${this.isRational}, domain=(${lo}, ${hi}))`;
  }
}

// ---- the Kiln: the SubD cage --------------------------------------------------------------

const _SUBD_AXES = Object.freeze({ x: 0, y: 1, z: 2 });
const _SUBD_KINDS = Object.freeze({ vertices: 0, edges: 1, faces: 2 });
const _SUBD_PICKS = Object.freeze({ vertex: 0, edge: 1, face: 2 });
const _subdShown = (v) => (typeof v === 'string' ? JSON.stringify(v) : Array.isArray(v) ? `[${v.map(_subdShown).join(', ')}]` : String(v));
const _isList = (v) => v != null && typeof v !== 'string' && typeof v[Symbol.iterator] === 'function';

/** A count or id as the C ABI reads it (a whole number, 0 to 4294967295), refused here, named, rather than wrapped by koffi. */
function _subdCount(value, what) {
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 0 || value > 0xffffffff) {
    throw new TypeError(`${what} must be a whole number from 0 to 4294967295, not ${_subdShown(value)}`);
  }
  return value;
}
function _subdAxis(axis, what) {
  const key = typeof axis === 'string' ? axis.toLowerCase() : null;
  if (key === null || !Object.hasOwn(_SUBD_AXES, key)) throw new BuildError(`${what}: axis must be 'x', 'y' or 'z', not ${_subdShown(axis)}`);
  return _SUBD_AXES[key];
}
/** `[a, b]` vertex pairs -- edges -- as the flat ids the C ABI reads. */
function _subdPairs(value, call, param) {
  if (!_isList(value)) throw new TypeError(`${call}: ${param} must be a list of [a, b] vertex pairs, not ${_subdShown(value)}`);
  const flat = [];
  let i = 0;
  for (const pair of value) {
    const ab = _isList(pair) ? Array.from(pair) : null;
    if (ab === null || ab.length !== 2) throw new TypeError(`${call}: ${param}[${i}] is not an [a, b] vertex pair: ${_subdShown(pair)}`);
    flat.push(..._indices(ab, call, `${param}[${i}]`));
    i++;
  }
  return Uint32Array.from(flat);
}
/** Flat ids read back as `[a, b]` pairs. */
function _subdPairsOf(ids) {
  const out = [];
  for (let i = 0; i + 1 < ids.length; i += 2) out.push([ids[i], ids[i + 1]]);
  return out;
}
/** `n` ids or doubles copied out of a view (a koffi pointer, or the wasm's typed array), as a plain array or a `Float64Array`. */
function _subdIds(ptr, n) { return n === 0 ? [] : Array.from(_uint32s(ptr, n)); }
function _subdDoubles(ptr, n) { return n === 0 ? new Float64Array(0) : Float64Array.from(_doublesAt(ptr, n)); }
function _subdUints(ptr, n) { return n === 0 ? new Uint32Array(0) : Uint32Array.from(_uint32s(ptr, n)); }
/** Positions as the flat doubles the C ABI reads: a flat run of three a vertex, or `[x, y, z]` each. */
function _subdPoints(positions, call) {
  if (!_isList(positions)) throw new TypeError(`${call}: positions must be numbers, three a vertex, not ${_subdShown(positions)}`);
  const items = Array.from(positions);
  let flat = items;
  if (items.length > 0 && typeof items[0] !== 'number') {
    flat = [];
    items.forEach((p, i) => {
      const xyz = _isList(p) ? Array.from(p, Number) : [];
      if (xyz.length !== 3) throw new BuildError(`${call}: positions[${i}] must be [x, y, z], not ${_subdShown(p)}`);
      flat.push(...xyz);
    });
  }
  if (flat.length % 3) throw new BuildError(`${call}: positions must be three numbers a vertex, not ${flat.length}`);
  return Float64Array.from(flat, Number);
}
/** Sixteen numbers column-major, as the C ABI reads them, or a 4x4 of rows (row-major, as Python's `transform` takes one). */
function _subdMatrix(matrix) {
  if (!_isList(matrix)) throw new BuildError(`transform matrix: sixteen numbers column-major or a 4x4, not ${_subdShown(matrix)}`);
  const rows = Array.from(matrix, (row) => (_isList(row) ? Array.from(row) : row));
  if (rows.some(Array.isArray)) {
    if (rows.length !== 4 || !rows.every((row) => Array.isArray(row) && row.length === 4)) {
      throw new BuildError(`transform: a nested matrix must be 4x4 (four rows of four numbers), not rows of [${rows.map((row) => (Array.isArray(row) ? row.length : 1)).join(', ')}]`);
    }
    const columns = [];
    for (let c = 0; c < 4; c++) for (let r = 0; r < 4; r++) columns.push(rows[r][c]);
    return _doubles(columns, 16, 'transform matrix');
  }
  return _doubles(rows, 16, 'transform matrix');
}

/**
 * One level of a cage's smooth surface, as `Subd.smoothMesh` returns it, copied out of the cage
 * so it outlives it. `positions` and `normals` are 3n doubles -- limit positions and unit outward
 * limit normals; `indices` three vertex ids a triangle; `triangleFace` the face of the **full**
 * cage each triangle lies on (on a mirrored half, face `f` of the half is `f` and its reflection
 * `f + faces.length`).
 */
class SubdMesh {
  constructor(positions, normals, indices, triangleFace) {
    this.positions = positions; this.normals = normals; this.indices = indices; this.triangleFace = triangleFace;
  }
}
function _subdMeshOf(raw) {
  const n = raw.vertex_count, m = raw.index_count;
  return new SubdMesh(_subdDoubles(raw.positions, 3 * n), _subdDoubles(raw.normals, 3 * n),
    _subdUints(raw.indices, m), _subdUints(raw.triangle_face, m / 3));
}

/**
 * What `Subd.toSolid` did and how close it came: `regular` patches exact from their own net and
 * `refined` ones from a refined neighbourhood; the Catmull-Clark `steps` taken first (1 or 2);
 * `levels`, the deepest local refinement a patch took (0 when none was refined); the largest
 * `deviation` from the limit surface, as a fraction of the cage's bounding-box diagonal; the
 * largest tangent break `g1AngleDeg` across a side that is not creased, in degrees; and the world
 * points they were measured at, `deviationAt` and `g1At`.
 */
class SubdReport {
  constructor(raw) {
    this.regular = raw.regular; this.refined = raw.refined; this.steps = raw.steps; this.levels = raw.levels;
    this.deviation = raw.deviation; this.g1AngleDeg = raw.g1_angle_deg;
    this.deviationAt = Array.from(raw.deviation_at, Number); this.g1At = Array.from(raw.g1_at, Number);
  }
}

const _subdFinalizer = typeof FinalizationRegistry === 'function'
  ? new FinalizationRegistry((h) => { try { _lib().subd_free(h); } catch (_) { /* exiting */ } }) : null;

/**
 * A Catmull-Clark control cage: positions, faces, creased edges, pinned vertices, an optional
 * mirror plane, and the selection of the edit that made it. Immutable: every edit returns a new
 * `Subd`, with `selection` naming what that edit touched. `toSolid` turns it into an exact B-rep.
 * `close()` frees this handle; so does leaving a `using` block or the garbage collector. A
 * refusal throws `BuildError` with the kernel's own words. An edge is `[a, b]`; a selection is
 * `{kind: 'vertices' | 'edges' | 'faces', ids}`, an edge selection's ids `[a, b]` pairs.
 */
class Subd {
  constructor(handle) {
    this._pointer = _checked(handle, 'subd');
    if (_subdFinalizer) _subdFinalizer.register(this, this._pointer, this);
  }
  get _handle() {
    if (!this._pointer) throw new BuildError('subd: closed');
    return this._pointer;
  }
  get closed() { return this._pointer === null; }
  close() {
    if (this._pointer === null) return;
    const h = this._pointer; this._pointer = null;
    if (_subdFinalizer) _subdFinalizer.unregister(this);
    _lib().subd_free(h);
  }
  [DISPOSE]() { this.close(); }

  // -- the primitives
  /** A box of `size` (x, y, z), centred on the origin, with `segments` quads along each axis (1 to 1024). */
  static cuboid(size = [2, 2, 2], segments = [1, 1, 1]) {
    const [sx, sy, sz] = _doubles(size ?? [2, 2, 2], 3, 'cuboid size');
    const counts = _indices(segments ?? [1, 1, 1], 'cuboid', 'segments');
    if (counts.length !== 3) throw new BuildError(`cuboid segments: expected 3 numbers, got ${counts.length}`);
    return new Subd(_lib().subd_cuboid(sx, sy, sz, counts[0], counts[1], counts[2]));
  }
  /**
   * A cylinder along +Z: one n-gon cap per end with `sides` sides and `rings` bands of quads
   * between them; with `creasedRims` the two rim loops are creased, so the caps stay flat. The
   * rims are creased by default, which is what converts: an uncreased cylinder of 7 or more
   * sides is refused by `toSolid` at the default tolerances.
   */
  static cylinder(radius = 1, height = 2, sides = 8, rings = 1, creasedRims = true) {
    return new Subd(_lib().subd_cylinder(Number(radius ?? 1), Number(height ?? 2), _subdCount(sides ?? 8, 'cylinder sides'),
      _subdCount(rings ?? 1, 'cylinder rings'), Boolean(creasedRims ?? true)));
  }
  /** A quad ball of `radius`: a cube grid with `segments` quads per edge, each vertex pushed out to the radius. */
  static sphere(radius = 1, segments = 2) {
    return new Subd(_lib().subd_sphere(Number(radius ?? 1), _subdCount(segments ?? 2, 'sphere segments')));
  }
  /** A torus around +Z: `around` steps about the axis at `major`, `tube` steps round the tube of `minor`, all quads. */
  static torus(major = 3, minor = 1, around = 12, tube = 8) {
    return new Subd(_lib().subd_torus(Number(major ?? 3), Number(minor ?? 1), _subdCount(around ?? 12, 'torus around'),
      _subdCount(tube ?? 8, 'torus tube')));
  }
  /**
   * A cage from its parts, the lossless inverse of reading them back: `positions` (a flat run of
   * three a vertex, or `[x, y, z]` each), `faces` lists of vertex ids, `creases` `[a, b]` pairs
   * that are edges, `pins` vertex ids, and `symmetry` null or `{axis: 'x' | 'y' | 'z',
   * tolerance}` for a mirrored half, as `symmetry` reports it. The new cage selects nothing.
   */
  static fromParts(positions, faces, creases = [], pins = [], symmetry = null) {
    const points = _subdPoints(positions, 'from_parts');
    if (!_isList(faces)) throw new TypeError(`from_parts: faces must be a list of vertex-id lists, not ${_subdShown(faces)}`);
    const sizes = [], loop = [];
    let i = 0;
    for (const face of faces) {
      const ids = _indices(face, 'from_parts', `faces[${i}]`);
      sizes.push(ids.length);
      loop.push(...ids);
      i++;
    }
    const creaseIds = _subdPairs(creases, 'from_parts', 'creases');
    const pinIds = _indices(pins, 'from_parts', 'pins');
    let axis = -1, tolerance = 0;
    if (symmetry != null) {
      const [name, within] = Array.isArray(symmetry) ? symmetry : [symmetry.axis, symmetry.tolerance];
      axis = _subdAxis(name, 'from_parts symmetry');
      tolerance = Number(within);
    }
    return new Subd(_lib().subd_from_parts(points, points.length / 3, Uint32Array.from(sizes), sizes.length,
      Uint32Array.from(loop), loop.length, creaseIds, creaseIds.length / 2, pinIds, pinIds.length, axis, tolerance));
  }

  // -- the parts, every one a copy
  _parts(read) {
    const out = {};
    if (!_lib().subd_parts(this._handle, out)) _fail('subd_parts');
    return read(out);
  }
  /** The cage's vertices, a `Float64Array` of 3n numbers of your own: a copy. */
  get positions() { return this._parts((p) => _subdDoubles(p.positions, 3 * p.vertex_count)); }
  /** Each face's vertex ids, in loop order. */
  get faces() {
    return this._parts((p) => {
      const sizes = _subdIds(p.face_sizes, p.face_count), loop = _subdIds(p.face_indices, p.index_count);
      const faces = [];
      let at = 0;
      for (const size of sizes) { faces.push(loop.slice(at, at + size)); at += size; }
      return faces;
    });
  }
  /** The creased edges, each `[smaller id, larger id]`, sorted. */
  get creases() { return this._parts((p) => _subdPairsOf(_subdIds(p.creases, 2 * p.crease_count))); }
  /** The pinned vertices: they refine as corners and stay put. */
  get pins() { return this._parts((p) => _subdIds(p.pins, p.pin_count)); }
  /** Null for an ordinary cage; for a mirrored half, `{axis, tolerance}`: the plane's axis and how far from it a vertex counts as on it. */
  get symmetry() {
    return this._parts((p) => (p.symmetry_axis < 0 ? null : { axis: 'xyz'[p.symmetry_axis], tolerance: p.symmetry_tolerance }));
  }
  /**
   * What the edit that made this cage touched: `{kind: 'vertices' | 'faces', ids}` or
   * `{kind: 'edges', ids: [[a, b], ...]}`; null for a cage no edit selected (a primitive,
   * `fromParts`, the mirror calls).
   */
  get selection() {
    return this._parts((p) => {
      if (p.selection_kind > 2) return null;
      if (p.selection_kind === 1) return { kind: 'edges', ids: _subdPairsOf(_subdIds(p.selection, 2 * p.selection_count)) };
      return { kind: p.selection_kind === 0 ? 'vertices' : 'faces', ids: _subdIds(p.selection, p.selection_count) };
    });
  }

  // -- the edits, every one a new cage
  _edit(make, what) { return new Subd(_checked(make(), what)); }
  _selected(selection, call) {
    if (selection == null || typeof selection !== 'object' || Array.isArray(selection)) {
      throw new TypeError(`${call}: selection must be {kind: 'vertices' | 'edges' | 'faces', ids}, not ${_subdShown(selection)}`);
    }
    const { kind, ids } = selection;
    if (typeof kind !== 'string' || !Object.hasOwn(_SUBD_KINDS, kind)) {
      throw new BuildError(`${call}: kind must be 'vertices', 'edges' or 'faces', not ${_subdShown(kind)}`);
    }
    const flat = kind === 'edges' ? _subdPairs(ids, call, 'selection ids') : _indices(ids, call, 'selection ids');
    return [_SUBD_KINDS[kind], flat, kind === 'edges' ? flat.length / 2 : flat.length];
  }
  /**
   * A new cage with the selected elements moved by `matrix`, and the same elements selected.
   * `selection` is `{kind, ids}`; `matrix` sixteen numbers column-major, or a 4x4 of rows
   * (row-major); a rotation about a point is baked in by the caller.
   */
  transform(selection, matrix) {
    const [kind, ids, count] = this._selected(selection, 'transform');
    const m = _subdMatrix(matrix);
    return this._edit(() => _lib().subd_transform(this._handle, kind, ids, count, m), 'subd_transform');
  }
  /** A new cage with `edges` (`[a, b]` pairs) creased, or un-creased when `on` is false; it selects them. */
  crease(edges, on = true) {
    const flat = _subdPairs(edges, 'crease', 'edges');
    return this._edit(() => _lib().subd_set_crease(this._handle, flat, flat.length / 2, Boolean(on ?? true)), 'subd_set_crease');
  }
  /** A new cage with `vertices` pinned (they refine as corners and stay put), or released when `on` is false; it selects them. */
  pin(vertices, on = true) {
    const ids = _indices(vertices, 'pin', 'vertices');
    return this._edit(() => _lib().subd_set_pin(this._handle, ids, ids.length, Boolean(on ?? true)), 'subd_set_pin');
  }
  /** A new cage with `faces` pushed out by `distance` along each connected region's average normal, a quad wall on each boundary edge; it selects the moved faces. */
  extrude(faces, distance) {
    const ids = _indices(faces, 'extrude', 'faces');
    return this._edit(() => _lib().subd_extrude(this._handle, ids, ids.length, Number(distance)), 'subd_extrude');
  }
  /** A new cage with `faces` shrunk by `amount`, in (0, 1), within their surface and a ring of quads round each region (each face, with `individual`); it selects the inner faces. */
  inset(faces, amount, individual = false) {
    const ids = _indices(faces, 'inset', 'faces');
    return this._edit(() => _lib().subd_inset(this._handle, ids, ids.length, Number(amount), Boolean(individual ?? false)), 'subd_inset');
  }
  /** A new cage with `faces` subdivided once by the Catmull-Clark rules (the whole cage when no faces are given): each face becomes quads round a new point, and an unpicked face beside them takes the new edge points as corners. The whole cage keeps its smooth surface exactly. The new cage selects the new faces. */
  subdivide(faces = []) {
    const ids = _indices(faces, 'subdivide', 'faces');
    return this._edit(() => _lib().subd_subdivide(this._handle, ids, ids.length), 'subd_subdivide');
  }
  /** A new cage with a loop of edges cut across the ring of quads through `edge` (`[a, b]`), at `a + at * (b - a)` with `at` in (0, 1); it selects the new loop. */
  insertLoop(edge, at = 0.5) {
    const [a, b] = _subdPairs([edge], 'insert_loop', 'edge');
    return this._edit(() => _lib().subd_insert_loop(this._handle, a, b, Number(at ?? 0.5)), 'subd_insert_loop');
  }
  /** The loop of edges through `edge`, straight across each valence-four vertex, the picked edge first, each `[smaller, larger]`; empty when `edge` is not an edge of the cage. */
  edgeLoop(edge) {
    const [a, b] = _subdPairs([edge], 'edge_loop', 'edge');
    const looped = this._edit(() => _lib().subd_edge_loop(this._handle, a, b), 'subd_edge_loop');
    try {
      const selection = looped.selection;
      return selection ? selection.ids : [];
    } finally { looped.close(); }
  }
  /** The positive half of the cage across the plane perpendicular to `axis` ('x', 'y' or 'z'), as a mirrored cage: every later edit keeps it symmetric. */
  mirrorOn(axis) {
    const k = _subdAxis(axis, 'mirror_on');
    return this._edit(() => _lib().subd_mirror_on(this._handle, k), 'subd_mirror_on');
  }
  /** The mirror baked: the whole cage as an ordinary one, no longer mirrored. */
  mirrorOff() { return this._edit(() => _lib().subd_mirror_off(this._handle), 'subd_mirror_off'); }
  /** The whole cage of a mirrored half -- the half's vertices first, then their reflections -- or a copy of an ordinary cage. */
  full() { return this._edit(() => _lib().subd_full(this._handle), 'subd_full'); }

  // -- the surface
  /** The smooth surface refined `levels` times (1 to 6), as a `SubdMesh` of copies. */
  smoothMesh(levels = 3) {
    const n = _subdCount(levels ?? 3, 'smooth_mesh levels');
    const out = {};
    if (!_lib().subd_smooth_mesh(this._handle, n, out)) _fail('subd_smooth_mesh');
    return _subdMeshOf(out);
  }
  /**
   * The cage element of `kind` ('vertex', 'edge' or 'face') under `point`, a point on or near the
   * smooth surface: a vertex or face id, or an edge as `[a, b]` with the smaller id first. Null
   * when nothing is within 0.05 of the cage's diagonal -- not an error; a point that is not finite
   * is refused.
   */
  pick(point, kind) {
    if (typeof kind !== 'string' || !Object.hasOwn(_SUBD_PICKS, kind)) {
      throw new BuildError(`pick: kind must be 'vertex', 'edge' or 'face', not ${_subdShown(kind)}`);
    }
    const at = _doubles(point, 3, 'pick point');
    const out = new Uint32Array(2);
    const l = _lib();
    if (!l.subd_pick(this._handle, at, _SUBD_PICKS[kind], out)) {
      // Nothing near leaves an empty `last_error`; a refusal's text is never empty.
      if (_lastError() === '') return null;
      _fail('subd_pick');
    }
    return kind === 'edge' ? [out[0], out[1]] : out[0];
  }
  /**
   * The cage as an exact solid, one NURBS face per patch, and a `SubdReport` of what the
   * conversion did, as `{solid, report}`. `tolerance` is the largest deviation from the limit
   * surface as a fraction of the cage's diagonal, `g1Angle` the largest tangent break across an
   * uncreased side in degrees, `maxLevels` the deepest local refinement (2 to 6). A `tolerance`
   * or `g1Angle` of 0 or less, or a `maxLevels` of 0, takes the default. A cage that cannot be
   * held within them is refused with the figures it measured.
   */
  toSolid(tolerance = 1e-4, g1Angle = 0.1, maxLevels = 6) {
    const report = {};
    const h = _lib().subd_to_solid(this._handle, Number(tolerance ?? 1e-4), Number(g1Angle ?? 0.1), _subdCount(maxLevels ?? 6, 'to_solid maxLevels'), report);
    const solid = new Solid(h);
    return { solid, report: new SubdReport(report) };
  }
}

// ---- the 2D constraint sketcher ----------------------------------------------------------

// The C ABI's codes, by position; JavaScript speaks the names (Python's, snake_case).
const _SKETCH_ENTITY_KINDS = ['point', 'line', 'circle', 'arc', 'free_curve'];
const _SKETCH_CONSTRAINT_KINDS = [
  'coincident', 'point_on_line', 'point_on_circle', 'horizontal', 'vertical', 'parallel', 'perpendicular',
  'collinear', 'tangent', 'tangent_at_end', 'concentric', 'equal_length', 'equal_radius', 'midpoint',
  'symmetric', 'fix', 'distance', 'point_line_distance', 'line_distance', 'circle_line_distance',
  'circle_distance', 'horizontal_distance', 'vertical_distance', 'length', 'angle', 'radius', 'diameter',
];
const _SKETCH_SENSES = ['auto', 'positive', 'negative'];
const _SKETCH_ENDS = ['start', 'end'];
const _SKETCH_STATUSES = ['converged', 'conflicting', 'diverged'];
const _SKETCH_STATES = ['under', 'full', 'over'];
// `sketch_dof_list`'s and `sketch_dof_part_list`'s `which`
const _DOF_REDUNDANT = 0, _DOF_CONFLICTING = 1, _DOF_FREE_ENTITIES = 2;
const _PART_CONSTRAINTS = 0, _PART_REDUNDANT = 1, _PART_CONFLICTING = 2, _PART_FREE_ENTITIES = 3;

/** `value` as a u32 id for `call`'s `param`: a number that is a whole number from 0; anything else (null, '', true, an array, ...) is refused before the call. */
function _sketchArg(value, call, param) {
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 0 || value > 0xFFFFFFFF) {
    throw new BuildError(`${call}: ${param} must be an id (a whole number from 0), not ${_sketchShown(value)}`);
  }
  return value;
}
/** A plain object's key (always a string) as a u32 id: only the decimal spelling of one, refused in `_sketchArg`'s words otherwise. */
function _sketchKey(key, call, param) {
  const n = Number(key);
  if (!/^(0|[1-9][0-9]*)$/.test(key) || n > 0xFFFFFFFF) {
    throw new BuildError(`${call}: ${param} must be an id (a whole number from 0), not ${_sketchShown(key)}`);
  }
  return n;
}
/** A refused argument as the message shows it: strings quoted, so '' and '3' read apart from 3. */
function _sketchShown(value) {
  if (typeof value === 'string') return `'${value}'`;
  if (Array.isArray(value)) return `[${value.join(', ')}]`;
  return String(value);
}
/** An id the library handed back (NONE: throw the library's reason). */
function _sketchId(value, what) { if (value === NONE) _fail(what); return value; }
/** A code the library handed back, as its name (NONE or out of range: throw the library's reason). */
function _sketchNamed(table, code, what) {
  if (code === NONE || !Number.isInteger(code) || code < 0 || code >= table.length) _fail(what);
  return table[code];
}
/** A name the caller gave, as its code; an unknown name is refused naming the call and the parameter. */
function _sketchCode(table, name, call, param) {
  const i = table.indexOf(name);
  if (i < 0) throw new BuildError(`${call}: ${param} must be one of ${table.map((v) => `'${v}'`).join(', ')}, not '${String(name)}'`);
  return i;
}
/** A count the library wrote as a double, exactly: a whole number in range, else refused naming the call. */
function _sketchWhole(value, what) {
  if (!Number.isInteger(value) || value < 0 || value > 0x7FFFFFFF) {
    throw new BuildError(`${what}: the library answered ${value}, not a whole number in range`);
  }
  return value;
}
/** `points` as a flat `Float64Array` of x, y, each point checked to be a pair. */
function _sketchPairs(points, what) {
  const flat = [];
  for (const p of points) {
    const xy = Array.from(p, Number);
    if (xy.length !== 2) throw new BuildError(`${what}: each point is an [x, y] pair, not [${xy.join(', ')}]`);
    flat.push(xy[0], xy[1]);
  }
  return Float64Array.from(flat);
}
/** A `size_t *count` out-slot: 8 bytes natively, a plain one-element array the shim writes under the wasm. */
function _sizeSlot() { return _wasm() ? [0] : new BigUint64Array(1); }

/**
 * What a solve did: `status` ('converged', 'conflicting' or 'diverged'), how many `iterations`,
 * the largest constraint residual left (`maxResidual`), and `ids`: the constraints a conflict ran
 * into, or the worst ones of a diverged solve (empty when it converged). Plain data.
 */
class SolveReport {
  constructor(status, iterations, maxResidual, ids) {
    this.status = status; this.iterations = iterations; this.maxResidual = maxResidual; this.ids = ids;
  }
  get converged() { return this.status === 'converged'; }
}

/**
 * One independent part of a diagnosed sketch: its `params` (unknowns), how many stay `free`, its
 * `state` ('under', 'full' or 'over'), its `constraints`, the `redundant` and `conflicting` ones
 * among them, and its `freeEntities`. Plain data.
 */
class PartDof {
  constructor(params, free, state, constraints, redundant, conflicting, freeEntities) {
    this.params = params; this.free = free; this.state = state;
    this.constraints = constraints; this.redundant = redundant; this.conflicting = conflicting; this.freeEntities = freeEntities;
  }
}

/**
 * A sketch's degrees of freedom (`Sketch.diagnose`): how many are `free`, its `state` ('under',
 * 'full' or 'over'), the `redundant` and `conflicting` constraint ids, the `freeEntities`
 * (entities that can still move), and the independent `parts` it splits into. Plain data.
 */
class Dof {
  constructor(free, state, redundant, conflicting, freeEntities, parts) {
    this.free = free; this.state = state;
    this.redundant = redundant; this.conflicting = conflicting; this.freeEntities = freeEntities; this.parts = parts;
  }
}

const _sketchFinalizer = typeof FinalizationRegistry === 'function'
  ? new FinalizationRegistry((h) => { try { _lib().sketch_free(h); } catch (_) { /* exiting */ } }) : null;

/**
 * A 2D sketch of points, lines, circles, arcs and free curves held by geometric constraints and
 * dimensions, solved on request:
 *
 *     const s = new Sketch();
 *     const [corners, sides] = s.addRect([0, 0], [40, 30]);
 *     s.fix(corners[0]);
 *     s.length(sides[0], 60);
 *     s.solve();
 *     const plate = Solid.extrude(s.profiles()[0], Frame.xy(), 10);
 *
 * Entities and constraints are named by integer ids. Entity kinds are 'point', 'line', 'circle',
 * 'arc' and 'free_curve'; constraint kinds the snake_case names of the methods that add them
 * ('point_line_distance', ...) -- but for `radiusOf`, whose kind is 'radius' (`radius(id)` reads a
 * circle's radius). Senses are 'auto', 'positive' or 'negative'; ends 'start' or 'end'.
 *
 * A refused call throws `BuildError` with the library's text and, as its `ids`, the ids the
 * refusal names: the constraints a new constraint, value or reference conflicts with, the
 * entities still using a point (empty when it names none). The `SolveReport`s of `solve`, `drag`,
 * `setValue`, `setDriving` and `updateReference` carry a returned report's ids the same way.
 * `close()` frees this handle; so does leaving a `using` block or the garbage collector.
 */
class Sketch {
  constructor() { this._own(_lib().sketch_new(), 'sketch_new'); }
  /**
   * A sketch of `profile`'s lines, arcs and curves joined end to end, holes included; with
   * `infer` the obvious constraints (horizontal, vertical, tangent joints, ...) too. Ends within
   * `tolerance` count as joined.
   */
  static fromProfile(profile, infer = true, tolerance = 1e-6) {
    const s = Object.create(Sketch.prototype);
    s._own(_lib().sketch_from_profile(profile._handle, Boolean(infer ?? true), Number(tolerance ?? 1e-6)), 'sketch_from_profile');
    return s;
  }
  _own(handle, what) {
    this._pointer = _checked(handle, what);
    if (_sketchFinalizer) _sketchFinalizer.register(this, this._pointer, this);
  }
  get _handle() {
    if (!this._pointer) throw new BuildError('sketch: closed');
    return this._pointer;
  }
  get closed() { return this._pointer === null; }
  close() {
    if (!this._pointer) return;
    const h = this._pointer; this._pointer = null;
    if (_sketchFinalizer) _sketchFinalizer.unregister(this);
    _lib().sketch_free(h);
  }
  [DISPOSE]() { this.close(); }

  /** A u32 list the library lends until the next call on this sketch, copied into a plain array (null: a refusal, `_fail`'s or, with `refusal`, `_refused`'s). */
  _lent(name, args, refusal = false) {
    const count = _sizeSlot();
    const ptr = _lib()[name](this._handle, ...args, count);
    if (ptr == null) { if (refusal) this._refused(name); _fail(name); }
    return Array.from(_uint32s(ptr, Number(count[0])));
  }
  /**
   * `_fail` for a call that can be refused with ids (`constrain`, `removeEntity`, `setValue`,
   * `setDriving`, `updateReference`, `drag`): the reason first -- under the wasm the next call
   * clears it -- then the ids `report_ids` holds.
   */
  _refused(what) {
    const reason = _lastError() || what;
    const count = _sizeSlot();
    const ptr = _lib().sketch_report_ids(this._handle, count);
    throw new BuildError(reason, ptr == null ? [] : Array.from(_uint32s(ptr, Number(count[0]))));
  }
  _solved(done, report, what) {
    if (!done) this._refused(what);
    const ids = this._lent('sketch_report_ids', []);
    return new SolveReport(_sketchNamed(_SKETCH_STATUSES, report[0], what), _sketchWhole(report[1], what), report[2], ids);
  }
  _id(value, call, param) { return _sketchArg(value, call, param); }

  // -- entities
  /** A free point at (`x`, `y`); a coordinate that is not finite is refused. */
  addPoint(x, y) { return _sketchId(_lib().sketch_add_point(this._handle, Number(x), Number(y)), 'sketch_add_point'); }
  /** A line between the points `a` and `b`. */
  addLine(a, b) {
    const h = this._handle;
    return _sketchId(_lib().sketch_add_line(h, this._id(a, 'sketch_add_line', 'a'), this._id(b, 'sketch_add_line', 'b')), 'sketch_add_line');
  }
  /** A circle of radius `r` about the point `centre`. */
  addCircle(centre, r) {
    const h = this._handle;
    return _sketchId(_lib().sketch_add_circle(h, this._id(centre, 'sketch_add_circle', 'centre'), Number(r)), 'sketch_add_circle');
  }
  /** A counter-clockwise arc about the point `centre` from the point `start` to the point `end`. */
  addArc(centre, start, end) {
    const h = this._handle;
    return _sketchId(_lib().sketch_add_arc(h, this._id(centre, 'sketch_add_arc', 'centre'), this._id(start, 'sketch_add_arc', 'start'),
      this._id(end, 'sketch_add_arc', 'end')), 'sketch_add_arc');
  }
  /** A cubic Bezier free curve from the point `start` through the controls `c1` and `c2` to a new end point at `to`; the curve owns its control points. */
  addBezier(start, c1, c2, to) {
    const h = this._handle;
    const [c1x, c1y, c2x, c2y, x, y] = _sketchPairs([c1, c2, to], 'sketch_add_bezier');
    return _sketchId(_lib().sketch_add_bezier(h, this._id(start, 'sketch_add_bezier', 'start'), c1x, c1y, c2x, c2y, x, y), 'sketch_add_bezier');
  }
  /** A rational quadratic (conic) free curve from the point `start` with the control `control` of `weight` to a new end point at `to`. */
  addConic(start, control, to, weight) {
    const h = this._handle;
    const [cx, cy, x, y] = _sketchPairs([control, to], 'sketch_add_conic');
    return _sketchId(_lib().sketch_add_conic(h, this._id(start, 'sketch_add_conic', 'start'), cx, cy, x, y, Number(weight)), 'sketch_add_conic');
  }
  /**
   * A NURBS free curve of `degree` from the point `start` through the control `points` after it,
   * on `knots`; `weights` null for a plain B-spline, or one per control point counting the start
   * (`points.length + 1`).
   */
  addNurbs(start, points, knots, degree = 3, weights = null) {
    const h = this._handle;
    const xy = _sketchPairs(points, 'sketch_add_nurbs');
    const n = xy.length / 2;
    const k = Float64Array.from(knots, Number);
    const d = degree ?? 3;
    if (typeof d !== 'number' || !Number.isInteger(d)) throw new BuildError(`sketch_add_nurbs: degree must be a whole number, not ${_sketchShown(d)}`);
    if (d < 0) throw new BuildError(`sketch_add_nurbs: degree must not be negative, not ${d}`);
    if (d > 0xFFFFFFFF) throw new BuildError(`sketch_add_nurbs: degree must be at most ${0xFFFFFFFF}, not ${d}`);
    // The library reads exactly `n + 1` weights whatever the array holds: check here.
    const w = weights == null ? null : Float64Array.from(weights, Number);
    if (w && w.length !== n + 1) {
      throw new BuildError(`sketch_add_nurbs: ${w.length} weights for ${n + 1} control points (the start and ${n} given); give one per point`);
    }
    return _sketchId(_lib().sketch_add_nurbs(h, this._id(start, 'sketch_add_nurbs', 'start'), d, xy, n, w, k, k.length), 'sketch_add_nurbs');
  }
  /** The rectangle with opposite corners `a` and `b`: `[corners, sides]`, its four corner points counter-clockwise from `a` and its four sides (side `i` from corner `i`). */
  addRect(a, b) {
    const [x0, y0, x1, y1] = _sketchPairs([a, b], 'sketch_add_rect');
    const ids = this._lent('sketch_add_rect', [x0, y0, x1, y1]);
    return [ids.slice(0, 4), ids.slice(4)];
  }
  /** The kind of entity `id`: 'point', 'line', 'circle', 'arc' or 'free_curve'. */
  kind(id) { const h = this._handle; return _sketchNamed(_SKETCH_ENTITY_KINDS, _lib().sketch_kind(h, this._id(id, 'sketch_kind', 'id')), 'sketch_kind'); }
  /** The live entity ids, ascending. */
  entities() { return this._lent('sketch_entities', []); }
  /** The point `id`'s position, `[x, y]`. */
  point(id) {
    const h = this._handle;
    const out = new Float64Array(2);
    if (!_lib().sketch_point(h, this._id(id, 'sketch_point', 'id'), out)) _fail('sketch_point');
    return [out[0], out[1]];
  }
  /** Moves the point `id` to (`x`, `y`) without solving. */
  setPoint(id, x, y) {
    const h = this._handle;
    if (!_lib().sketch_set_point(h, this._id(id, 'sketch_set_point', 'id'), Number(x), Number(y))) _fail('sketch_set_point');
  }
  /** The radius of the circle or arc `id` (the RADIUS constraint is `radiusOf`). */
  radius(id) {
    const h = this._handle;
    const r = _lib().sketch_radius(h, this._id(id, 'sketch_radius', 'id'));
    if (Number.isNaN(r)) _fail('sketch_radius');
    return r;
  }
  /** Sets the circle `id`'s radius to `r` without solving. */
  setRadius(id, r) {
    const h = this._handle;
    if (!_lib().sketch_set_radius(h, this._id(id, 'sketch_set_radius', 'id'), Number(r))) _fail('sketch_set_radius');
  }
  /** The centre point of the circle or arc `id`. */
  centre(id) { const h = this._handle; return _sketchId(_lib().sketch_centre(h, this._id(id, 'sketch_centre', 'id')), 'sketch_centre'); }
  /** The points entity `id` runs between: a line's `[a, b]`, an arc's `[start, end]`, a free curve's `[start, controls..., end]`. */
  ends(id) { return this._lent('sketch_ends', [this._id(id, 'sketch_ends', 'id')]); }
  /** Marks entity `id` as construction geometry (kept out of profiles), or back. */
  setConstruction(id, on = true) {
    const h = this._handle;
    if (!_lib().sketch_set_construction(h, this._id(id, 'sketch_set_construction', 'id'), Boolean(on ?? true))) _fail('sketch_set_construction');
  }
  /** Whether entity `id` is construction geometry (false for an unknown id). */
  isConstruction(id) { const h = this._handle; return Boolean(_lib().sketch_is_construction(h, this._id(id, 'sketch_is_construction', 'id'))); }
  /** Whether entity `id` is a reference copy of another sketch's (false for an unknown id). */
  isReference(id) { const h = this._handle; return Boolean(_lib().sketch_is_reference(h, this._id(id, 'sketch_is_reference', 'id'))); }
  /** Removes entity `id` and the constraints on it: the removed constraint ids. Refused for a point that lines or circles still use. */
  removeEntity(id) { return this._lent('sketch_remove_entity', [this._id(id, 'sketch_remove_entity', 'id')], true); }
  /** A fixed construction copy of `other`'s entity `entity`, kept in step by `updateReference`. `other` must be another sketch. */
  reference(other, entity) {
    const h = this._handle;
    return _sketchId(_lib().sketch_reference(h, other._handle, this._id(entity, 'sketch_reference', 'entity')), 'sketch_reference');
  }
  /** Refreshes the reference `id` from `other` and re-solves. */
  updateReference(id, other) {
    const h = this._handle;
    const report = new Float64Array(3);
    return this._solved(_lib().sketch_update_reference(h, this._id(id, 'sketch_update_reference', 'id'), other._handle, report),
      report, 'sketch_update_reference');
  }

  // -- constraints: each returns the new constraint's id
  _constrain(kind, refs, value = 0, driving = true, sense = 'auto', end = 'start') {
    const h = this._handle;
    const senseCode = _sketchCode(_SKETCH_SENSES, sense ?? 'auto', kind, 'sense');
    const endCode = _sketchCode(_SKETCH_ENDS, end ?? 'start', kind, 'end');
    const ids = Uint32Array.from(refs, (r) => this._id(r, kind, 'id'));
    const got = _lib().sketch_constrain(h, _SKETCH_CONSTRAINT_KINDS.indexOf(kind), ids, ids.length,
      Number(value), Boolean(driving ?? true), senseCode, endCode);
    if (got === NONE) this._refused('sketch_constrain');
    return got;
  }
  coincident(a, b) { return this._constrain('coincident', [a, b]); }
  pointOnLine(point, line) { return this._constrain('point_on_line', [point, line]); }
  /** `circle` a circle or an arc. */
  pointOnCircle(point, circle) { return this._constrain('point_on_circle', [point, circle]); }
  /** The points `a` and `b` level with each other. */
  horizontal(a, b) { return this._constrain('horizontal', [a, b]); }
  /** The points `a` and `b` one above the other. */
  vertical(a, b) { return this._constrain('vertical', [a, b]); }
  parallel(a, b) { return this._constrain('parallel', [a, b]); }
  perpendicular(a, b) { return this._constrain('perpendicular', [a, b]); }
  collinear(a, b) { return this._constrain('collinear', [a, b]); }
  tangent(a, b, sense = 'auto') { return this._constrain('tangent', [a, b], 0, true, sense); }
  /** The free curve `curve` tangent to `other` at its `end` ('start' or 'end'). */
  tangentAtEnd(curve, other, end = 'start') { return this._constrain('tangent_at_end', [curve, other], 0, true, 'auto', end); }
  concentric(a, b) { return this._constrain('concentric', [a, b]); }
  equalLength(a, b) { return this._constrain('equal_length', [a, b]); }
  equalRadius(a, b) { return this._constrain('equal_radius', [a, b]); }
  midpoint(point, line) { return this._constrain('midpoint', [point, line]); }
  /** The points `a` and `b` mirror images across the line `about`. */
  symmetric(a, b, about) { return this._constrain('symmetric', [a, b, about]); }
  fix(entity) { return this._constrain('fix', [entity]); }
  distance(a, b, value, driving = true) { return this._constrain('distance', [a, b], value, driving); }
  pointLineDistance(point, line, value, driving = true, sense = 'auto') { return this._constrain('point_line_distance', [point, line], value, driving, sense); }
  lineDistance(a, b, value, driving = true, sense = 'auto') { return this._constrain('line_distance', [a, b], value, driving, sense); }
  circleLineDistance(circle, line, value, driving = true, sense = 'auto') { return this._constrain('circle_line_distance', [circle, line], value, driving, sense); }
  circleDistance(a, b, value, driving = true) { return this._constrain('circle_distance', [a, b], value, driving); }
  horizontalDistance(a, b, value, driving = true) { return this._constrain('horizontal_distance', [a, b], value, driving); }
  verticalDistance(a, b, value, driving = true) { return this._constrain('vertical_distance', [a, b], value, driving); }
  length(line, value, driving = true) { return this._constrain('length', [line], value, driving); }
  /** The angle from line `a` to line `b`, in radians. */
  angle(a, b, value, driving = true) { return this._constrain('angle', [a, b], value, driving); }
  /** The RADIUS dimension (kind 'radius') -- `radius(id)` reads a radius instead. */
  radiusOf(circle, value, driving = true) { return this._constrain('radius', [circle], value, driving); }
  diameter(circle, value, driving = true) { return this._constrain('diameter', [circle], value, driving); }

  /** The live constraint ids, ascending. */
  constraints() { return this._lent('sketch_constraints', []); }
  /** The kind of constraint `id`, e.g. 'point_line_distance'. */
  constraintKind(id) {
    const h = this._handle;
    return _sketchNamed(_SKETCH_CONSTRAINT_KINDS, _lib().sketch_constraint_kind(h, this._id(id, 'sketch_constraint_kind', 'id')), 'sketch_constraint_kind');
  }
  /** The entity ids constraint `id` was made on, in the order given. */
  constraintRefs(id) { return this._lent('sketch_constraint_refs', [this._id(id, 'sketch_constraint_refs', 'id')]); }
  /** The value of the dimension `id`; null for a constraint that is not a dimension. An unknown id throws. */
  constraintValue(id) {
    const h = this._handle;
    const v = _lib().sketch_constraint_value(h, this._id(id, 'sketch_constraint_value', 'id'));
    if (Number.isNaN(v)) {
      if (_lastError()) _fail('sketch_constraint_value');
      return null;
    }
    return v;
  }
  /** Whether the dimension `id` drives the geometry (false for a constraint that is not a dimension). An unknown id throws. */
  constraintDriving(id) {
    const h = this._handle;
    const driving = Boolean(_lib().sketch_constraint_driving(h, this._id(id, 'sketch_constraint_driving', 'id')));
    if (!driving && _lastError()) _fail('sketch_constraint_driving');
    return driving;
  }
  /** The sense of constraint `id`; 'auto' for a kind without one. */
  constraintSense(id) {
    const h = this._handle;
    return _sketchNamed(_SKETCH_SENSES, _lib().sketch_constraint_sense(h, this._id(id, 'sketch_constraint_sense', 'id')), 'sketch_constraint_sense');
  }
  /** The end ('start' or 'end') of the free curve a `tangentAtEnd` constraint `id` holds; 'start' for a kind without one. */
  constraintEnd(id) {
    const h = this._handle;
    return _sketchNamed(_SKETCH_ENDS, _lib().sketch_constraint_end(h, this._id(id, 'sketch_constraint_end', 'id')), 'sketch_constraint_end');
  }
  /** Whether the tangent constraint `id` joins two curves end to end. */
  isJointTangent(id) { const h = this._handle; return Boolean(_lib().sketch_is_joint_tangent(h, this._id(id, 'sketch_is_joint_tangent', 'id'))); }
  /** Removes the constraint `id`. */
  remove(id) { const h = this._handle; if (!_lib().sketch_remove(h, this._id(id, 'sketch_remove', 'id'))) _fail('sketch_remove'); }
  /** Sets the dimension `id` to `value` and re-solves. */
  setValue(id, value) {
    const h = this._handle;
    const report = new Float64Array(3);
    return this._solved(_lib().sketch_set_value(h, this._id(id, 'sketch_set_value', 'id'), Number(value), report), report, 'sketch_set_value');
  }
  /** Makes the dimension `id` drive the geometry (true) or only report it, and re-solves. */
  setDriving(id, driving) {
    const h = this._handle;
    const report = new Float64Array(3);
    return this._solved(_lib().sketch_set_driving(h, this._id(id, 'sketch_set_driving', 'id'), Boolean(driving), report), report, 'sketch_set_driving');
  }
  /** What the geometry measures for the dimension `id` right now. */
  measure(id) {
    const h = this._handle;
    const v = _lib().sketch_measure(h, this._id(id, 'sketch_measure', 'id'));
    if (Number.isNaN(v)) _fail('sketch_measure');
    return v;
  }

  // -- solving and diagnosis
  /** Solves the sketch. A conflicting or diverged solve is reported, not thrown. */
  solve() {
    const h = this._handle;
    const report = new Float64Array(3);
    return this._solved(_lib().sketch_solve(h, report), report, 'sketch_solve');
  }
  /**
   * Drags each point id in `moves` (a `Map` or a plain object of id to `[x, y]`) towards its
   * target while the constraints hold, as a live gesture would (the moves are sent in ascending id order). Refused for an id that is not a
   * point, and for `moves` that is null or not an object (`{}` is no moves: a plain solve).
   */
  drag(moves) {
    const h = this._handle;
    if (moves === null || typeof moves !== 'object') {
      throw new BuildError(`sketch_drag: moves must be a Map or an object of id to [x, y], not ${_sketchShown(moves)}`);
    }
    const isMap = moves instanceof Map;
    const entries = (isMap ? Array.from(moves) : Object.entries(moves))
      .map(([id, p]) => [isMap ? this._id(id, 'sketch_drag', 'id') : _sketchKey(id, 'sketch_drag', 'id'), p]);
    entries.sort((x, y) => x[0] - y[0]);   // ascending ids: the solve must not depend on insertion order
    const ids = Uint32Array.from(entries, ([id]) => id);
    const xy = _sketchPairs(entries.map(([, p]) => p), 'sketch_drag');
    const report = new Float64Array(3);
    return this._solved(_lib().sketch_drag(h, ids, xy, ids.length, report), report, 'sketch_drag');
  }
  /** The sketch's degrees of freedom, whole and per independent part. */
  diagnose() {
    const h = this._handle;
    const lib = _lib();
    const out = new Float64Array(3);
    if (!lib.sketch_diagnose(h, out)) _fail('sketch_diagnose');
    const free = _sketchWhole(out[0], 'sketch_diagnose');
    const state = _sketchNamed(_SKETCH_STATES, out[1], 'sketch_diagnose');
    const partCount = _sketchWhole(out[2], 'sketch_diagnose');
    const [redundant, conflicting, freeEntities] = [_DOF_REDUNDANT, _DOF_CONFLICTING, _DOF_FREE_ENTITIES]
      .map((which) => this._lent('sketch_dof_list', [which]));
    const parts = [];
    const part = new Float64Array(3);
    for (let i = 0; i < partCount; i++) {
      if (!lib.sketch_dof_part(h, i, part)) _fail('sketch_dof_part');
      const params = _sketchWhole(part[0], 'sketch_dof_part');
      const partFree = _sketchWhole(part[1], 'sketch_dof_part');
      const partState = _sketchNamed(_SKETCH_STATES, part[2], 'sketch_dof_part');
      const lists = [_PART_CONSTRAINTS, _PART_REDUNDANT, _PART_CONFLICTING, _PART_FREE_ENTITIES]
        .map((which) => this._lent('sketch_dof_part_list', [i, which]));
      parts.push(new PartDof(params, partFree, partState, ...lists));
    }
    return new Dof(free, state, redundant, conflicting, freeEntities, parts);
  }
  /** The closed loops as profiles (nested loops become holes; construction geometry left out); ends within `tolerance` join. */
  profiles(tolerance = 1e-6) { return _profileList(_lib().sketch_profiles(this._handle, Number(tolerance ?? 1e-6)), 'sketch_profiles'); }
  /** The paths that do not close, as profiles; ends within `tolerance` join. */
  openChains(tolerance = 1e-6) { return _profileList(_lib().sketch_open_chains(this._handle, Number(tolerance ?? 1e-6)), 'sketch_open_chains'); }
}

/**
 * One place two curves meet, copied out. A point (`run` false): `start` equals `end`, and
 * `touch` is true where the curves are tangent rather than crossing. A run (`run` true): they
 * coincide from `start` to `end`. `aStart`/`aEnd` are where on the first curve,
 * `bStart`/`bEnd` where on the second, as `Spot` values.
 */
class Hit {
  constructor(run, touch, start, end, aStart, aEnd, bStart, bEnd) {
    this.run = run; this.touch = touch; this.start = start; this.end = end;
    this.aStart = aStart; this.aEnd = aEnd; this.bStart = bStart; this.bEnd = bEnd;
  }
}

function _spotOf(raw) { return new Spot(raw.loop_index, raw.segment, raw.t, raw.face, raw.u, raw.v); }
function _hitOf(raw) {
  return new Hit(Boolean(raw.run), Boolean(raw.touch), [raw.start.x, raw.start.y, raw.start.z], [raw.end.x, raw.end.y, raw.end.z],
    _spotOf(raw.a_start), _spotOf(raw.a_end), _spotOf(raw.b_start), _spotOf(raw.b_end));
}

const _XY = [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1];
const _XZ = [0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -1, 0];
const _YZ = [0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0];

/** How far from square a frame's axes may be (the cosine between two of them). */
const _SQUARE = 1e-6;
const _dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const _cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
function _unit(v, what) {
  const p = Array.from(_doubles(v, 3, what));
  const n = Math.hypot(...p);
  if (!(n > 1e-12 && Number.isFinite(n))) throw new BuildError(`${what} has no direction`);
  return p.map((c) => c / n);
}

/**
 * An origin and three unit axes, square to each other and right-handed
 * (z = x × y): the plane a profile is drawn on (its x/y) and the direction it
 * is built along (its z). Iterates as the twelve numbers every call taking a
 * `frame` reads, so pass it wherever one goes. Immutable.
 *
 * The constructor normalises the axes and throws `BuildError` when they are
 * not square or not right-handed.
 */
class Frame {
  constructor(origin, x, y, z) {
    const o = Array.from(_doubles(origin, 3, 'Frame: origin'));
    if (!o.every(Number.isFinite)) throw new BuildError('Frame: origin must be three finite numbers');
    const [ux, uy, uz] = [_unit(x, 'Frame: x'), _unit(y, 'Frame: y'), _unit(z, 'Frame: z')];
    if (Math.max(Math.abs(_dot(ux, uy)), Math.abs(_dot(uy, uz)), Math.abs(_dot(uz, ux))) > _SQUARE) {
      throw new BuildError('Frame: the axes are not square to each other');
    }
    if (_dot(_cross(ux, uy), uz) < 0) throw new BuildError('Frame: the axes are left-handed (z must be x × y)');
    this._v = Object.freeze([...o, ...ux, ...uy, ...uz].map((c) => c + 0)); // + 0: no -0 to print or compare
    Object.freeze(this);
  }
  /** Twelve numbers or four triples -- what `Solid.faceFrame` and `Workplane.frame` hand back -- checked as the constructor checks. */
  static of(frame) {
    const v = Array.from(_frame(frame));
    return new Frame(v.slice(0, 3), v.slice(3, 6), v.slice(6, 9), v.slice(9, 12));
  }
  /** The plane midway between the planes of frames a and b: halfway between parallel planes, on a's axes; for planes that meet, the plane bisecting them through the line they meet on, its x along that line. */
  static midplane(a, b) {
    const out = new Float64Array(12);
    if (!_lib().frame_midplane(_frame(a), _frame(b), out)) _fail('frame_midplane');
    return Frame.of(out);
  }
  /** The plane through three points: its origin p, its x towards q, its z the normal they turn about counter-clockwise. Throws for three points on one line. */
  static through(p, q, r) {
    const out = new Float64Array(12);
    if (!_lib().frame_through(_doubles(p, 3, 'p'), _doubles(q, 3, 'q'), _doubles(r, 3, 'r'), out)) _fail('frame_through');
    return Frame.of(out);
  }
  /** The world XY plane through `origin`: z up, as `Workplane.xy`. */
  static xy(origin = [0, 0, 0]) { return new Frame(origin, _XY.slice(3, 6), _XY.slice(6, 9), _XY.slice(9, 12)); }
  /** The world XZ plane through `origin`: x along X, y along Z, so z is -Y, as `Workplane.xz`. */
  static xz(origin = [0, 0, 0]) { return new Frame(origin, _XZ.slice(3, 6), _XZ.slice(6, 9), _XZ.slice(9, 12)); }
  /** The world YZ plane through `origin`: x along Y, y along Z, so z is +X, as `Workplane.yz`. */
  static yz(origin = [0, 0, 0]) { return new Frame(origin, _YZ.slice(3, 6), _YZ.slice(6, 9), _YZ.slice(9, 12)); }
  /**
   * The plane through `origin` square to `normal` (the frame's z). Its x axis
   * is `x` laid onto that plane; with none, world X laid onto it, or world Y
   * when the normal is within about 25° of X -- the axes `Solid.faceFrame`
   * gives a face facing `normal`. So a normal along +Z, -Y or +X gives exactly
   * `xy`, `xz` or `yz`.
   */
  static at(origin, normal, x = null) {
    const z = _unit(normal, 'Frame.at: normal');
    const hint = _unit(x ?? (Math.abs(z[0]) <= 0.9 ? [1, 0, 0] : [0, 1, 0]), 'Frame.at: x');
    const d = _dot(hint, z);
    if (Math.abs(d) > 1 - _SQUARE) throw new BuildError('Frame.at: x lies along the normal');
    const ax = _unit(hint.map((h, i) => h - d * z[i]), 'Frame.at: x');
    return new Frame(origin, ax, _cross(z, ax), z);
  }
  get origin() { return this._v.slice(0, 3); }
  get x() { return this._v.slice(3, 6); }
  get y() { return this._v.slice(6, 9); }
  get z() { return this._v.slice(9, 12); }
  /** This frame moved by (`dx`, `dy`, `dz`) in world coordinates. */
  translate(dx, dy, dz) {
    const o = this.origin;
    return new Frame([o[0] + dx, o[1] + dy, o[2] + dz], this.x, this.y, this.z);
  }
  /** This frame moved `distance` along its own z. */
  offset(distance) { return this.translate(...this.z.map((c) => distance * c)); }
  /** The same plane facing the other way: x and y swapped, z reversed. */
  flipped() { return new Frame(this.origin, this.y, this.x, this.z.map((c) => -c)); }
  /** This frame turned `radians` about `axis` through its origin (`Transform.rotation`). */
  rotated(radians, axis) {
    const r = Transform.rotation(this.origin, axis, radians).rows;
    const turn = (d) => [0, 1, 2].map((i) => r[4 * i] * d[0] + r[4 * i + 1] * d[1] + r[4 * i + 2] * d[2]);
    return new Frame(this.origin, turn(this.x), turn(this.y), turn(this.z));
  }
  /** `p` in this frame's coordinates. */
  toLocal(p) {
    const o = this.origin;
    const d = Array.from(_valuePoint(p, 'Frame.toLocal'), (c, i) => c - o[i]);
    return [_dot(d, this.x), _dot(d, this.y), _dot(d, this.z)];
  }
  /** How far `p` sits above the plane, along z (negative below). */
  distanceTo(p) {
    const o = this.origin;
    return _dot(Array.from(_valuePoint(p, 'Frame.distanceTo'), (c, i) => c - o[i]), this.z);
  }
  /** `p` dropped onto the plane along z. */
  closestPoint(p) {
    const q = Array.from(_valuePoint(p, 'Frame.closestPoint'));
    const d = this.distanceTo(q), z = this.z;
    return q.map((c, i) => c - d * z[i]);
  }
  /**
   * The least-squares plane through `points` (three or more, not on one line) as a frame, and the
   * largest distance any point sits off it: `{ frame, deviation }`.
   */
  static fit(points) {
    const [xyz, n] = _valuePoints(points, 'frame_fit');
    const out = new Float64Array(12), deviation = new Float64Array(1);
    if (!_lib().frame_fit(xyz, n, out, deviation)) _fail('frame_fit');
    return { frame: Frame.of(out), deviation: deviation[0] };
  }
  /** Whether `other` is a frame with the same twelve numbers. */
  equals(other) { return other instanceof Frame && this._v.every((c, i) => c === other._v[i]); }
  [Symbol.iterator]() { return this._v[Symbol.iterator](); }
  toString() { return `Frame(origin=[${this.origin}], x=[${this.x}], y=[${this.y}], z=[${this.z}])`; }
}

/** `Solid.convertToNurbs`'s levels: CADACLYSM_BLACKSMITH_NURBS_PROCEDURAL, _ANALYTIC and _ALL. */
const _NURBS_LEVELS = Object.freeze({ procedural: 0, analytic: 1, all: 2 });
/** How far from rigid, or from a similarity, a map may be and still be told one, by default. */
const _MAP_TOLERANCE = 1e-9;
const _IDENTITY_ROWS = Object.freeze([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]);
/** Sixteen numbers, or four rows of four -- four plain numbers are not, and fall to the caller's count check. */
function _flat16(rows) {
  const flat = Array.from(rows);
  const isRow = (row) => row != null && typeof row !== 'string' && typeof row[Symbol.iterator] === 'function';
  return flat.length === 4 && flat.every(isRow) ? flat.flatMap((row) => Array.from(row)) : flat;
}
/** A `Transform`, 16 numbers row-major or four rows of four, as the C array. */
function _matrix(t, what) { return _doubles(t instanceof Transform ? t.rows : _flat16(t), 16, what); }

/**
 * An affine map of space: a 4x4 matrix, row-major, its bottom row `0 0 0 1`. Immutable, with
 * nothing to free; iterates as its 16 numbers. `a.compose(b)` is `a` after `b`.
 *
 * The constructors and the decompositions are the library's own, so every wrapper computes them
 * alike. A frame argument is a `Frame`, 12 numbers or four triples; one within 1e-6 of
 * right-handed and orthonormal is squared up, any other throws `BuildError`.
 */
class Transform {
  constructor(rows = _IDENTITY_ROWS) {
    const r = _flat16(rows).map((v) => Number(v) + 0); // + 0: no -0 to print or compare
    if (r.length !== 16) throw new BuildError(`Transform: a matrix is 16 numbers, got ${r.length}`);
    if (!r.every(Number.isFinite)) throw new BuildError('Transform: not finite');
    if (r[12] !== 0 || r[13] !== 0 || r[14] !== 0 || r[15] !== 1) {
      throw new BuildError('Transform: the bottom row must be 0 0 0 1 (a projective map is not affine)');
    }
    this._rows = Object.freeze(r);
    Object.freeze(this);
  }
  static _made(what, call) {
    const out = new Float64Array(16);
    if (!call(out)) _fail(what);
    return new Transform(out);
  }
  /** The map 16 numbers state, row-major (or four rows of four). */
  static fromRows(rows) { return new Transform(rows); }
  /** The map that moves nothing. */
  static identity() { return new Transform(); }
  /** `p + v`. */
  static translation(v) { return Transform._made('transform_translation', (out) => _lib().transform_translation(_doubles(v, 3, 'transform_translation'), out)); }
  /** A turn of `radians` about the line through `point` along `direction`, right-handed. */
  static rotation(point, direction, radians) {
    const axis = _doubles([...Array.from(point), ...Array.from(direction)], 6, 'transform_rotation');
    return Transform._made('transform_rotation', (out) => _lib().transform_rotation(axis, Number(radians), out));
  }
  /** The reflection across `plane` (its z the normal). */
  static mirror(plane) { return Transform._made('transform_mirror', (out) => _lib().transform_mirror(_frame(plane), out)); }
  /** A uniform scale by `k` about `centre`. */
  static scale(centre, k) { return Transform._made('transform_scale', (out) => _lib().transform_scale(_doubles(centre, 3, 'transform_scale'), Number(k), out)); }
  /** A scale by `sx`, `sy`, `sz` along `frame`'s axes, about its origin. */
  static scaleXyz(frame, sx, sy, sz) {
    return Transform._made('transform_scale_xyz', (out) => _lib().transform_scale_xyz(_frame(frame), Number(sx), Number(sy), Number(sz), out));
  }
  /** Every point slid along `direction` by `factor` times its height above `plane`; `direction` is normalised and must lie in the plane. */
  static shear(plane, direction, factor) {
    return Transform._made('transform_shear', (out) => _lib().transform_shear(_frame(plane), _doubles(direction, 3, 'transform_shear'), Number(factor), out));
  }
  /** The rigid map sending frame `a` onto frame `b`. */
  static planeToPlane(a, b) { return Transform._made('transform_plane_to_plane', (out) => _lib().transform_plane_to_plane(_frame(a), _frame(b), out)); }
  /** Coordinates in frame `from` to coordinates in frame `to`: a change of basis. */
  static changeBasis(from, to) { return Transform._made('transform_change_basis', (out) => _lib().transform_change_basis(_frame(from), _frame(to), out)); }
  /** The orthogonal projection onto `plane` -- singular by design. */
  static planarProjection(plane) { return Transform._made('transform_planar_projection', (out) => _lib().transform_planar_projection(_frame(plane), out)); }
  /** The parallel projection onto `plane` along `direction`, which must not lie in it. */
  static projectAlong(plane, direction) {
    return Transform._made('transform_project_along', (out) => _lib().transform_project_along(_frame(plane), _doubles(direction, 3, 'transform_project_along'), out));
  }
  /** The 16 numbers, row-major (a copy). */
  get rows() { return this._rows.slice(); }
  /** Where the map takes the point `p`. */
  point(p) {
    const [x, y, z] = _doubles(p, 3, 'point');
    const r = this._rows;
    return [r[0] * x + r[1] * y + r[2] * z + r[3], r[4] * x + r[5] * y + r[6] * z + r[7], r[8] * x + r[9] * y + r[10] * z + r[11]];
  }
  /** This map after `other`: `a.compose(b).point(p)` is `a.point(b.point(p))`. */
  compose(other) {
    if (!(other instanceof Transform)) throw new BuildError('transform_compose: other must be a Transform');
    return Transform._made('transform_compose', (out) => _lib().transform_compose(_matrix(this, 'transform_compose'), _matrix(other, 'transform_compose'), out));
  }
  /** The map undoing this one; throws `BuildError` for a singular map. */
  inverse() { return Transform._made('transform_inverse', (out) => _lib().transform_inverse(_matrix(this, 'transform_inverse'), out)); }
  /** Whether the linear part is orthogonal (`AᵀA = I` to `tolerance`, by default 1e-9): a rotation or a mirror. */
  isRigid(tolerance = _MAP_TOLERANCE) {
    const r = _lib().transform_is_rigid(_matrix(this, 'transform_is_rigid'), Number(tolerance));
    if (r === NONE) _fail('transform_is_rigid');
    return r === 1;
  }
  /** The scale `k` where the linear part is `k` times an orthogonal one (to `tolerance`, relative to `k²`; by default 1e-9), else null. */
  isSimilarity(tolerance = _MAP_TOLERANCE) {
    const k = _lib().transform_is_similarity(_matrix(this, 'transform_is_similarity'), Number(tolerance));
    if (Number.isNaN(k)) _fail('transform_is_similarity');
    return k > 0 ? k : null;
  }
  /** `{ translation, orthogonal }` for a rigid map, else null. */
  decomposeRigid(tolerance = _MAP_TOLERANCE) {
    if (!this.isRigid(tolerance)) return null;
    const out = new Float64Array(19);
    if (!_lib().transform_decompose_rigid(_matrix(this, 'transform_decompose_rigid'), Number(tolerance), out)) _fail('transform_decompose_rigid');
    return { translation: Array.from(out.subarray(0, 3)), orthogonal: new Transform(out.subarray(3, 19)) };
  }
  /** `{ translation, orthogonal, k }` for a similarity, else null. */
  decomposeSimilarity(tolerance = _MAP_TOLERANCE) {
    if (this.isSimilarity(tolerance) === null) return null;
    const out = new Float64Array(20);
    if (!_lib().transform_decompose_similarity(_matrix(this, 'transform_decompose_similarity'), Number(tolerance), out)) _fail('transform_decompose_similarity');
    return { translation: Array.from(out.subarray(0, 3)), orthogonal: new Transform(out.subarray(3, 19)), k: out[19] };
  }
  /**
   * The polar split of the map: `{ translation, rotation, axes, stretch }` with the linear part
   * `rotation · axes · diag(stretch) · axesᵀ` -- `rotation` carrying the mirror, `axes` a proper
   * rotation whose columns are the stretch directions, the stretches largest first. Null for a
   * singular map or one stretched past 1e7:1, which has no unique split.
   */
  decomposeAffine() {
    const out = new Float64Array(38);
    if (!_lib().transform_decompose_affine(_matrix(this, 'transform_decompose_affine'), out)) return null;
    return {
      translation: Array.from(out.subarray(0, 3)), rotation: new Transform(out.subarray(3, 19)),
      axes: new Transform(out.subarray(19, 35)), stretch: Array.from(out.subarray(35, 38)),
    };
  }
  /** Whether `other` is a transform with the same sixteen numbers. */
  equals(other) { return other instanceof Transform && this._rows.every((v, i) => v === other._rows[i]); }
  [Symbol.iterator]() { return this._rows[Symbol.iterator](); }
  toString() { return `Transform([${this._rows.join(', ')}])`; }
}

/**
 * A rotation as `w + xi + yj + zk`. Immutable; iterates as `w, x, y, z`. `q` and `-q` are the
 * same rotation; a non-unit one is normalised wherever it becomes a rotation, a zero one throws
 * `BuildError` there. `a.multiply(b)` turns by `b`, then `a`. `equals` is by components, so `q`
 * does not equal `-q` although the two turn alike.
 */
class Quaternion {
  constructor(w = 1, x = 0, y = 0, z = 0) {
    const q = [w, x, y, z].map((v) => Number(v) + 0); // + 0: no -0 to print or compare
    if (!q.every(Number.isFinite)) throw new BuildError('Quaternion: not finite');
    this._q = Object.freeze(q);
    Object.freeze(this);
  }
  static _made(what, call) {
    const out = new Float64Array(4);
    if (!call(out)) _fail(what);
    return new Quaternion(out[0], out[1], out[2], out[3]);
  }
  /** The turn of `radians` about `direction`, right-handed. */
  static fromAxisAngle(direction, radians) {
    return Quaternion._made('quaternion_from_axis_angle', (out) => _lib().quaternion_from_axis_angle(_doubles(direction, 3, 'quaternion_from_axis_angle'), Number(radians), out));
  }
  /** The rotation in `t`'s linear part (its translation ignored); throws `BuildError` unless that is a proper rotation, orthogonal to 1e-9. */
  static fromTransform(t) { return Quaternion._made('quaternion_from_transform', (out) => _lib().quaternion_from_transform(_matrix(t, 'quaternion_from_transform'), out)); }
  /** From `a` (`s = 0`) to `b` (`s = 1`) the shorter way. */
  static slerp(a, b, s) {
    return Quaternion._made('quaternion_slerp', (out) => _lib().quaternion_slerp(_doubles(a, 4, 'quaternion_slerp'), _doubles(b, 4, 'quaternion_slerp'), Number(s), out));
  }
  /** This rotation as a `Transform` fixing `centre`. */
  toTransform(centre = [0, 0, 0]) {
    return Transform._made('quaternion_to_transform', (out) => _lib().quaternion_to_transform(_doubles(this._q, 4, 'quaternion_to_transform'), _doubles(centre, 3, 'quaternion_to_transform'), out));
  }
  get w() { return this._q[0]; }
  get x() { return this._q[1]; }
  get y() { return this._q[2]; }
  get z() { return this._q[3]; }
  /** The length of `vs`, scaled by its largest component first, as the ABI's `quaternion_from` does: squaring 1e200 overflows and 1e-170 underflows. */
  static _norm(vs) {
    const big = Math.max(...vs.map(Math.abs));
    return big === 0 ? 0 : big * Math.sqrt(vs.reduce((sum, v) => sum + (v / big) ** 2, 0));
  }
  get length() { return Quaternion._norm(this._q); }
  /** The turn, in `[0, 2π]`. */
  get angle() { return 2 * Math.atan2(Quaternion._norm(this._q.slice(1)), this.w); }
  /** The turn's axis, null for the identity. */
  get axis() {
    const big = Math.max(...this._q.slice(1).map(Math.abs));
    if (big === 0) return null;
    const v = this._q.slice(1).map((c) => c / big);
    const n = Math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    return [v[0] / n, v[1] / n, v[2] / n];
  }
  /** The opposite turn. */
  conjugate() { return new Quaternion(this.w, -this.x, -this.y, -this.z); }
  /** The same rotation at unit length, scaled by its largest component before the square root, so 1e200 and 1e-170 normalise. */
  normalized() {
    const big = Math.max(...this._q.map(Math.abs));
    if (big === 0) throw new BuildError('Quaternion.normalized: the quaternion is zero');
    const v = this._q.map((c) => c / big);
    const n = Math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2] + v[3] * v[3]);
    return new Quaternion(v[0] / n, v[1] / n, v[2] / n, v[3] / n);
  }
  /** The product: turns by `o`, then by this one. */
  multiply(o) {
    if (!(o instanceof Quaternion)) throw new BuildError('Quaternion.multiply: o must be a Quaternion');
    const a = this._q, b = o._q;
    return new Quaternion(a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
      a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2],
      a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1],
      a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0]);
  }
  /** Whether `other` is a quaternion with the same four numbers. */
  equals(other) { return other instanceof Quaternion && this._q.every((v, i) => v === other._q[i]); }
  [Symbol.iterator]() { return this._q[Symbol.iterator](); }
  toString() { return `Quaternion(${this._q.join(', ')})`; }
}

// ---- value geometry (plan B3): Interval, the feet, the nine values -------------------------

/**
 * A parameter range `t0..t1`, in either order: `length` and `swapped` keep the order, the set
 * operations (`grown`, `union`, `intersect`) answer increasing. Immutable; iterates as
 * `[t0, t1]`, so a pair of numbers goes wherever an `Interval` does. The kernel's own interval
 * arithmetic, in plain JavaScript.
 */
class Interval {
  constructor(t0, t1) {
    const t = [Number(t0) + 0, Number(t1) + 0]; // + 0: no -0 to print or compare
    if (!t.every(Number.isFinite)) throw new BuildError('Interval: not finite');
    this._t = Object.freeze(t);
    Object.freeze(this);
  }
  /** An `Interval`, or two numbers, as an `Interval`. */
  static of(value) {
    if (value instanceof Interval) return value;
    const t = value == null || typeof value === 'string' || typeof value[Symbol.iterator] !== 'function' ? null : Array.from(value);
    if (t === null) throw new BuildError(`Interval: an interval is 2 numbers, got ${value}`);
    if (t.length !== 2) throw new BuildError(`Interval: an interval is 2 numbers, got ${t.length}`);
    return new Interval(t[0], t[1]);
  }
  get t0() { return this._t[0]; }
  get t1() { return this._t[1]; }
  /** `t1 - t0`: negative for a decreasing interval. */
  get length() { return this._t[1] - this._t[0]; }
  get mid() { return 0.5 * (this._t[0] + this._t[1]); }
  get min() { return Math.min(this._t[0], this._t[1]); }
  get max() { return Math.max(this._t[0], this._t[1]); }
  get isIncreasing() { return this._t[0] < this._t[1]; }
  get isSingleton() { return this._t[0] === this._t[1]; }
  swapped() { return new Interval(this._t[1], this._t[0]); }
  /** The increasing interval holding this one and `t`. */
  grown(t) { return new Interval(Math.min(this.min, Number(t)), Math.max(this.max, Number(t))); }
  /** The increasing interval holding this one and `o`. */
  union(o) {
    const b = Interval.of(o);
    return new Interval(Math.min(this.min, b.min), Math.max(this.max, b.max));
  }
  /** The increasing overlap, null where the two are apart; touching is a singleton. */
  intersect(o) {
    const b = Interval.of(o);
    const t0 = Math.max(this.min, b.min), t1 = Math.min(this.max, b.max);
    return t0 <= t1 ? new Interval(t0, t1) : null;
  }
  /** Whether `t` lies in the closed range, either order. */
  contains(t) { return this.min <= t && t <= this.max; }
  /** `t0 + s (t1 - t0)`: the fraction `s` of the way from `t0` (outside `0..1` extrapolates). */
  parameterAt(s) { return this._t[0] + s * (this._t[1] - this._t[0]); }
  /** The fraction `t` sits from `t0` toward `t1`; null for a singleton. */
  normalizedParameterAt(t) {
    const length = this.length;
    return length !== 0 ? (t - this._t[0]) / length : null;
  }
  /** Whether `other` is an interval with the same two ends, in the same order. */
  equals(other) { return other instanceof Interval && this._t[0] === other._t[0] && this._t[1] === other._t[1]; }
  [Symbol.iterator]() { return this._t[Symbol.iterator](); }
  toString() { return `Interval(${this._t[0]}, ${this._t[1]})`; }
}

/**
 * The closest point of a curve value: its parameter `t`, the `point`, and `unique` -- false
 * where the answer is a fixed pick among equals (a circle's axis, an arc's two equidistant ends).
 */
class CurveFoot {
  constructor(t, point, unique) { this.t = t; this.point = point; this.unique = unique; Object.freeze(this); }
}

/**
 * The closest point of a surface value: its parameters `u`, `v`, the `point`, and `unique`
 * (false where the answer is a pick among equals, a sphere's centre).
 */
class SurfaceFoot {
  constructor(u, v, point, unique) { this.u = u; this.v = v; this.point = point; this.unique = unique; Object.freeze(this); }
}

// CADACLYSM_BLACKSMITH_VALUE_*: the kind each value array is tagged with.
const _VALUE_LINE = 0, _VALUE_CIRCLE = 1, _VALUE_ARC = 2, _VALUE_ELLIPSE = 3, _VALUE_SPHERE = 4;
const _VALUE_CYLINDER = 5, _VALUE_CONE = 6, _VALUE_TORUS = 7, _VALUE_CUBOID = 8;
const _VALUE_RECTANGLE = 9, _VALUE_TRIANGLE = 10, _VALUE_RAY = 11;
/** Each kind's name, as the library's own refusals spell it. */
const _VALUE_NAMES = Object.freeze(['line', 'circle', 'arc', 'ellipse', 'sphere', 'cylinder', 'cone', 'torus', 'cuboid',
  'rectangle', 'triangle', 'ray']);

/** A point as the value calls take it: three numbers, or `"<call>: a point is 3 numbers, got N"`. */
function _valuePoint(point, what) { return _thicknessPoint(point, what); }

/**
 * `cadaclysm_blacksmith_<name>(kind, value, ...args, out)` -- `kind` null for a call that takes
 * none -- its `out` doubles back as an array, or the library's refusal thrown. The koffi and the
 * wasm routes alike: `_lib()` is either.
 */
function _valueCall(name, kind, v, args, out) {
  const buf = new Float64Array(out);
  const lead = kind == null ? [] : [kind];
  if (!_lib()[name](...lead, Float64Array.from(v), ...args, buf)) _fail(name);
  return Array.from(buf);
}

/** Points (triples) as one flat array and their count; an empty one padded for koffi, which passes a zero-length array as null. */
function _valuePoints(points, what) {
  const flat = [];
  for (const p of points) flat.push(..._valuePoint(p, what));
  const n = flat.length / 3;
  return [n || _wasm() ? Float64Array.from(flat) : new Float64Array(3), n];
}

/**
 * `values` checked by the library: a count other than `value_size`'s is refused here, in the
 * library's own sentence, the rest (and the squaring up of the frame) by `value_check`.
 */
function _valueChecked(kind, values) {
  const v = Array.from(values, Number);
  const n = _lib().value_size(kind);
  if (v.length !== n) throw new BuildError(`value_check: a ${_VALUE_NAMES[kind]} is ${n} numbers, got ${v.length}`);
  return _valueCall('value_check', kind, v, [], n);
}

/**
 * What every value class shares: its canonical array (squared up by the library's `value_check`
 * at construction, so a refusal is the library's), immutability, equality by kind and array,
 * iteration as the array, `bounds` and `transform`.
 */
class _Value {
  /** Set the checked array and freeze: the last step of every constructor. */
  _init(values) {
    this._v = Object.freeze(_valueChecked(this.constructor._KIND, values));
    Object.freeze(this);
  }
  /** A value from an array the library handed back, already canonical. */
  static _of(values) {
    const o = Object.create(this.prototype);
    o._v = Object.freeze(Array.from(values, Number));
    return Object.freeze(o);
  }
  /** The value its raw numbers state (the layout `values` gives), checked as the constructor checks. */
  static fromValues(values) {
    const o = Object.create(this.prototype);
    o._init(values);
    return o;
  }
  /** The canonical numbers (a copy). */
  get values() { return this._v.slice(); }
  /** The world box, `[min, max]`. */
  bounds() {
    const b = _valueCall('value_bounds', this.constructor._KIND, this._v, [], 6);
    return [b.slice(0, 3), b.slice(3, 6)];
  }
  /**
   * This value under `t` (a `Transform`, or 16 numbers), a value of the same type. A line takes
   * any map keeping its ends apart, an ellipse any keeping it an ellipse; the rest only a
   * similarity (`Ellipse.fromCircle` first for a circle).
   */
  transform(t) {
    return this.constructor._of(_valueCall('value_transform', this.constructor._KIND, this._v, [_matrix(t, 'value_transform')], this._v.length));
  }
  /** Whether `other` is a value of the same kind with the same numbers. */
  equals(other) {
    return other instanceof _Value && other.constructor._KIND === this.constructor._KIND
      && other._v.length === this._v.length && this._v.every((c, i) => c === other._v[i]);
  }
  [Symbol.iterator]() { return this._v[Symbol.iterator](); }
  toString() { return `${this.constructor.name}(${this._v.join(', ')})`; }
}

class _CurveValue extends _Value {
  /**
   * The point at `t`: a line's `t` runs 0..1, a circle's and an arc's is the angle from the
   * frame's x toward its y, an ellipse's the eccentric angle.
   */
  pointAt(t) { return _valueCall('curve_value_point_at', this.constructor._KIND, this._v, [Number(t)], 3); }
  /** The unit tangent at `t`. */
  tangentAt(t) { return _valueCall('curve_value_tangent_at', this.constructor._KIND, this._v, [Number(t)], 3); }
  /** The length (an ellipse's perimeter in closed form). */
  length() { return _valueCall('curve_value_length', this.constructor._KIND, this._v, [], 1)[0]; }
  /** The `CurveFoot` nearest `p`. */
  closestPoint(p) {
    const what = 'curve_value_closest_point';
    const f = _valueCall(what, this.constructor._KIND, this._v, [_valuePoint(p, what)], 5);
    return new CurveFoot(f[0], f.slice(1, 4), f[4] !== 0);
  }
  /** How far `p` lies from the curve. */
  distanceTo(p) {
    const q = Array.from(_valuePoint(p, 'curve_value_closest_point'));
    const foot = this.closestPoint(q);
    return Math.hypot(foot.point[0] - q[0], foot.point[1] - q[1], foot.point[2] - q[2]);
  }
  /** The exact NURBS form, as a `NurbsCurve`. */
  toNurbs() {
    return NurbsCurve._of(_lib().curve_value_to_nurbs(this.constructor._KIND, Float64Array.from(this._v)), 'curve_value_to_nurbs');
  }
}

/** The segment from `start` to `end`; its parameter runs 0..1. */
class Line extends _CurveValue {
  constructor(start, end) { super(); this._init([..._valuePoint(start, 'Line'), ..._valuePoint(end, 'Line')]); }
  get start() { return this._v.slice(0, 3); }
  get end() { return this._v.slice(3, 6); }
}
Line._KIND = _VALUE_LINE;

/** A curve on a frame: a circle, an arc, an ellipse. */
class _ConicValue extends _CurveValue {
  /** The frame the curve lies on: its centre, the x its angles start from, its normal. */
  get frame() { return Frame.of(this._v.slice(0, 12)); }
}

/** The circle of `radius` about the frame's origin in its x-y plane, counter-clockwise about its z, from its x. */
class Circle extends _ConicValue {
  constructor(frame, radius) { super(); this._init([..._frame(frame), Number(radius)]); }
  /** The circle through three points, x toward `a`, turning `a`, `b`, `c` counter-clockwise. */
  static through(a, b, c) {
    const what = 'circle_through';
    return Circle._of(_valueCall(what, null, _valuePoint(a, what), [_valuePoint(b, what), _valuePoint(c, what)], 13));
  }
  get radius() { return this._v[12]; }
}
Circle._KIND = _VALUE_CIRCLE;

/** The part of a circle over `angle` (an `Interval` or two numbers, increasing by at most a full turn). */
class Arc extends _ConicValue {
  constructor(frame, radius, angle) {
    super();
    const a = Interval.of(angle);
    this._init([..._frame(frame), Number(radius), a.t0, a.t1]);
  }
  /** The arc from `a` through `b` to `c`. */
  static through(a, b, c) {
    const what = 'arc_through';
    return Arc._of(_valueCall(what, null, _valuePoint(a, what), [_valuePoint(b, what), _valuePoint(c, what)], 15));
  }
  /** The arc leaving `a` along `tangent` and ending at `c`. */
  static fromStartTangentEnd(a, tangent, c) {
    const what = 'arc_from_start_tangent_end';
    return Arc._of(_valueCall(what, null, _valuePoint(a, what), [_valuePoint(tangent, what), _valuePoint(c, what)], 15));
  }
  get radius() { return this._v[12]; }
  get angle() { return new Interval(this._v[13], this._v[14]); }
  get start() { return this.pointAt(this._v[13]); }
  get end() { return this.pointAt(this._v[14]); }
  get mid() { return this.pointAt(0.5 * (this._v[13] + this._v[14])); }
}
Arc._KIND = _VALUE_ARC;

/** The ellipse of radius `r1` along the frame's x and `r2` along its y. */
class Ellipse extends _ConicValue {
  constructor(frame, r1, r2) { super(); this._init([..._frame(frame), Number(r1), Number(r2)]); }
  /** `circle` as an ellipse of two equal radii -- which takes any map that keeps it one. */
  static fromCircle(circle) {
    if (!(circle instanceof Circle)) throw new BuildError(`ellipse_from_circle: a Circle, not ${circle?.constructor?.name ?? circle}`);
    return Ellipse._of(_valueCall('ellipse_from_circle', null, circle._v, [], 14));
  }
  get r1() { return this._v[12]; }
  get r2() { return this._v[13]; }
}
Ellipse._KIND = _VALUE_ELLIPSE;

/** A closed shape: containment, area, volume and the B-rep solid. */
class _SolidValue extends _Value {
  /** The frame the shape is placed on: its origin and axes. */
  get frame() { return Frame.of(this._v.slice(0, 12)); }
  /**
   * Whether `p` lies inside the closed shape or within `tolerance` of it. NaN is unset: the
   * shape's own effective tolerance (`tolerance.relative` times its diagonal); 0 is exact.
   */
  contains(p, tolerance = 1e-9) {
    const what = 'solid_value_contains';
    const r = _lib().solid_value_contains(this.constructor._KIND, Float64Array.from(this._v), _valuePoint(p, what), Number(tolerance));
    if (r === NONE) _fail(what);
    return r === 1;
  }
  /** The boundary's area, a cylinder's and a cone's caps included. */
  area() { return _valueCall('solid_value_area', this.constructor._KIND, this._v, [], 1)[0]; }
  volume() { return _valueCall('solid_value_volume', this.constructor._KIND, this._v, [], 1)[0]; }
  /** The closed B-rep solid. */
  toSolid() {
    return new Solid(_checked(_lib().solid_value_to_solid(this.constructor._KIND, Float64Array.from(this._v)), 'solid_value_to_solid'));
  }
}

class _SurfaceValue extends _SolidValue {
  pointAt(u, v) { return _valueCall('surface_value_point_at', this.constructor._KIND, this._v, [Number(u), Number(v)], 3); }
  /** The outward unit normal at `(u, v)`. */
  normalAt(u, v) { return _valueCall('surface_value_normal_at', this.constructor._KIND, this._v, [Number(u), Number(v)], 3); }
  /** The `SurfaceFoot` nearest `p`. */
  closestPoint(p) {
    const what = 'surface_value_closest_point';
    const f = _valueCall(what, this.constructor._KIND, this._v, [_valuePoint(p, what)], 6);
    return new SurfaceFoot(f[0], f[1], f.slice(2, 5), f[5] !== 0);
  }
  /** How far `p` lies from the surface. */
  distanceTo(p) {
    const q = Array.from(_valuePoint(p, 'surface_value_closest_point'));
    const foot = this.closestPoint(q);
    return Math.hypot(foot.point[0] - q[0], foot.point[1] - q[1], foot.point[2] - q[2]);
  }
  /** The `u` and `v` ranges. */
  domain() {
    const d = _valueCall('surface_value_domain', this.constructor._KIND, this._v, [], 4);
    return [new Interval(d[0], d[1]), new Interval(d[2], d[3])];
  }
  /** The surface alone as an open sheet on its exact NURBS form. */
  toNurbsSheet() {
    return new Solid(_checked(_lib().surface_value_nurbs_sheet(this.constructor._KIND, Float64Array.from(this._v)), 'surface_value_nurbs_sheet'));
  }
}

/** The sphere of `radius` about the frame's origin; `u` the longitude from its x, `v` the latitude toward its z. */
class Sphere extends _SurfaceValue {
  constructor(frame, radius) { super(); this._init([..._frame(frame), Number(radius)]); }
  get radius() { return this._v[12]; }
}
Sphere._KIND = _VALUE_SPHERE;

/** The cylinder of `radius` about the frame's z over `height` (an increasing `Interval` along z, or two numbers), capped. */
class Cylinder extends _SurfaceValue {
  constructor(frame, radius, height) {
    super();
    const h = Interval.of(height);
    this._init([..._frame(frame), Number(radius), h.t0, h.t1]);
  }
  get radius() { return this._v[12]; }
  get height() { return new Interval(this._v[13], this._v[14]); }
}
Cylinder._KIND = _VALUE_CYLINDER;

/** The cone of base `radius` on the frame's x-y plane, its apex `height` up its z, capped. */
class Cone extends _SurfaceValue {
  constructor(frame, radius, height) { super(); this._init([..._frame(frame), Number(radius), Number(height)]); }
  get radius() { return this._v[12]; }
  get height() { return this._v[13]; }
}
Cone._KIND = _VALUE_CONE;

/** The torus of `major` radius about the frame's z and `minor` radius about that circle. */
class Torus extends _SurfaceValue {
  constructor(frame, major, minor) { super(); this._init([..._frame(frame), Number(major), Number(minor)]); }
  get major() { return this._v[12]; }
  get minor() { return this._v[13]; }
}
Torus._KIND = _VALUE_TORUS;

/** The box over `x`, `y`, `z` (increasing `Interval`s, or pairs) along its frame's axes. */
class Cuboid extends _SolidValue {
  constructor(frame, x, y, z) {
    super();
    const [a, b, c] = [Interval.of(x), Interval.of(y), Interval.of(z)];
    this._init([..._frame(frame), a.t0, a.t1, b.t0, b.t1, c.t0, c.t1]);
  }
  /** The world-aligned box from `min` to `max`. */
  static fromBounds(min, max) {
    const what = 'cuboid_from_bounds';
    return Cuboid._of(_valueCall(what, null, _valuePoint(min, what), [_valuePoint(max, what)], 18));
  }
  /** The tightest box holding `points`, aligned to `frame`. */
  static around(frame, points) {
    const what = 'cuboid_around';
    const [xyz, n] = _valuePoints(points, what);
    return Cuboid._of(_valueCall(what, null, _frame(frame), [xyz, n], 18));
  }
  get x() { return new Interval(this._v[12], this._v[13]); }
  get y() { return new Interval(this._v[14], this._v[15]); }
  get z() { return new Interval(this._v[16], this._v[17]); }
  /** The eight corners: the `z0` face counter-clockwise about +z from `(x0, y0)`, then the `z1` face in the same order. */
  corners() {
    const c = _valueCall('cuboid_corners', null, this._v, [], 24);
    const out = [];
    for (let k = 0; k < 24; k += 3) out.push(c.slice(k, k + 3));
    return out;
  }
  /** The point the fractions `sx`, `sy`, `sz` of the way along each range. */
  pointAt(sx, sy, sz) { return _valueCall('cuboid_point_at', null, this._v, [Number(sx), Number(sy), Number(sz)], 3); }
  /** The closest point of the solid box: `p` itself inside. */
  closestPoint(p) {
    const what = 'cuboid_closest_point';
    return _valueCall(what, null, this._v, [_valuePoint(p, what)], 3);
  }
}
Cuboid._KIND = _VALUE_CUBOID;

/**
 * The rectangle over `x` and `y` (increasing `Interval`s, or pairs) in its frame's x-y plane. As a
 * curve it is its boundary: `t` runs 0..4, one unit a side from corner `(x0, y0)` counter-clockwise
 * about the frame's z, clamped outside that range; `closestPoint` is the boundary's, not unique on a
 * tie (the centre).
 */
class Rectangle extends _CurveValue {
  constructor(frame, x, y) {
    super();
    const [a, b] = [Interval.of(x), Interval.of(y)];
    this._init([..._frame(frame), a.t0, a.t1, b.t0, b.t1]);
  }
  /** The frame the rectangle lies on: its ranges run along the frame's x and y. */
  get frame() { return Frame.of(this._v.slice(0, 12)); }
  get x() { return new Interval(this._v[12], this._v[13]); }
  get y() { return new Interval(this._v[14], this._v[15]); }
  /** The four corners: `(x0, y0)`, `(x1, y0)`, `(x1, y1)`, `(x0, y1)`. */
  corners() {
    const c = _valueCall('rectangle_corners', null, this._v, [], 12);
    const out = [];
    for (let k = 0; k < 12; k += 3) out.push(c.slice(k, k + 3));
    return out;
  }
  /** The filled rectangle's area. */
  area() { return _valueCall('rectangle_area', null, this._v, [], 1)[0]; }
  /** `p` projected onto the plane and clamped into the filled rectangle with the interior, else the boundary's closest point. */
  closestPointIn(p, includeInterior = true) {
    const what = 'rectangle_closest_point';
    return _valueCall(what, null, this._v, [_valuePoint(p, what), Boolean(includeInterior)], 3);
  }
  /**
   * Where `p`, projected onto the plane, lies: `'inside'`, `'outside'`, or `'on'` within
   * `tolerance` of the boundary. Null (the default) or NaN is unset: the rectangle's own effective
   * tolerance (`tolerance.relative` times its diagonal); 0 is exact.
   */
  contains(p, tolerance = null) {
    const what = 'rectangle_contains';
    const tol = tolerance == null ? NaN : Number(tolerance);
    const r = _lib().rectangle_contains(Float64Array.from(this._v), _valuePoint(p, what), tol);
    if (r === NONE) _fail(what);
    return _containment(r, what);
  }
  /** The filled rectangle as a one-face planar sheet facing the frame's z. */
  toSheet() { return new Solid(_checked(_lib().rectangle_to_sheet(Float64Array.from(this._v)), 'rectangle_to_sheet')); }
}
Rectangle._KIND = _VALUE_RECTANGLE;

/** The triangle `a`, `b`, `c`; a degenerate one (collinear or coincident points) is refused. */
class Triangle extends _Value {
  constructor(a, b, c) { super(); this._init([..._valuePoint(a, 'Triangle'), ..._valuePoint(b, 'Triangle'), ..._valuePoint(c, 'Triangle')]); }
  get a() { return this._v.slice(0, 3); }
  get b() { return this._v.slice(3, 6); }
  get c() { return this._v.slice(6, 9); }
  area() { return _valueCall('triangle_area', null, this._v, [], 1)[0]; }
  /** The sum of the three sides. */
  perimeter() { return _valueCall('triangle_perimeter', null, this._v, [], 1)[0]; }
  /** The area centroid, the vertices' mean. */
  centroid() { return _valueCall('triangle_centroid', null, this._v, [], 3); }
  /** The `Circle` through `a`, `b`, `c`: its x toward `a`, turning them counter-clockwise. */
  circumcircle() { return Circle._of(_valueCall('triangle_circumcircle', null, this._v, [], 13)); }
  /** The point of barycentric weights `wa`, `wb`, `wc`, used as given. */
  pointAt(wa, wb, wc) { return _valueCall('triangle_point_at', null, this._v, [Number(wa), Number(wb), Number(wc)], 3); }
  /** The weights `[wa, wb, wc]`, summing to 1, of `p` projected onto the plane. */
  barycentric(p) {
    const what = 'triangle_barycentric';
    return _valueCall(what, null, this._v, [_valuePoint(p, what)], 3);
  }
  /** The closest point of the filled triangle to `p`, exact. */
  closestPoint(p) {
    const what = 'triangle_closest_point';
    return _valueCall(what, null, this._v, [_valuePoint(p, what)], 3);
  }
  /** How far `p` lies from the filled triangle. */
  distanceTo(p) {
    const q = Array.from(_valuePoint(p, 'triangle_closest_point'));
    const c = this.closestPoint(q);
    return Math.hypot(c[0] - q[0], c[1] - q[1], c[2] - q[2]);
  }
  /** Edge `i` as a `Line`: 0 `a` to `b`, 1 `b` to `c`, 2 `c` to `a`. */
  edge(i) { return Line._of(_valueCall('triangle_edge', null, this._v, [Number(i)], 6)); }
  /** The filled triangle as a one-face planar sheet, its normal turning `a`, `b`, `c` counter-clockwise. */
  toSheet() { return new Solid(_checked(_lib().triangle_to_sheet(Float64Array.from(this._v)), 'triangle_to_sheet')); }
}
Triangle._KIND = _VALUE_TRIANGLE;

/**
 * The half-line from `position` along `direction`. The direction is kept as given, not unitised,
 * so `t` counts lengths of it. A ray has no `bounds`: the library refuses it.
 */
class Ray extends _Value {
  constructor(position, direction) { super(); this._init([..._valuePoint(position, 'Ray'), ..._valuePoint(direction, 'Ray')]); }
  get position() { return this._v.slice(0, 3); }
  get direction() { return this._v.slice(3, 6); }
  /** `position + t * direction`, any `t` (behind the start too). */
  pointAt(t) { return _valueCall('ray_point_at', null, this._v, [Number(t)], 3); }
  /** The `CurveFoot` on the ray nearest `p`: `t` clamped at 0 (behind the start: the start). Always unique. */
  closestPoint(p) {
    const what = 'ray_closest_point';
    const f = _valueCall(what, null, this._v, [_valuePoint(p, what)], 4);
    return new CurveFoot(f[0], f.slice(1, 4), true);
  }
  /** How far `p` lies from the ray. */
  distanceTo(p) {
    const q = Array.from(_valuePoint(p, 'ray_closest_point'));
    const foot = this.closestPoint(q);
    return Math.hypot(foot.point[0] - q[0], foot.point[1] - q[1], foot.point[2] - q[2]);
  }
}
Ray._KIND = _VALUE_RAY;

/** The fluent chain mirroring the Rust `Workplane`: a frame, the solid so far, the face last picked. A build call replaces the solid. */
class Workplane {
  constructor(frame, solid = null) { this.frame = Array.from(_frame(frame)); this._solid = solid; this._selected = null; }
  static xy() { return new Workplane(_XY); }
  static xz() { return new Workplane(_XZ); }
  static yz() { return new Workplane(_YZ); }
  static on(frame) { return new Workplane(frame); }
  static fromSolid(solid) { return new Workplane(_XY, solid); }
  _set(solid) { this._solid = solid; this._selected = null; return this; }
  cuboid(x, y, z) { return this._set(Solid.cuboid(x, y, z).place(this.frame)); }
  cylinder(r, h) { return this._set(Solid.cylinder(r, h).place(this.frame)); }
  extrude(profile, height) { return this._set(Solid.extrude(profile, this.frame, height)); }
  /** The flat sheet `profile` bounds on this workplane's frame. */
  face(profile) { return this._set(Solid.face(profile, this.frame)); }
  /** About this workplane's own y axis through its origin. */
  revolve(profile, angle) { return this._set(Solid.revolve(profile, [this.frame.slice(0, 3), this.frame.slice(6, 9)], angle)); }
  /** Slide the current solid, keeping the face selection. */
  translate(dx, dy, dz) {
    if (this._solid === null) throw new BuildError('translate: the workplane holds no solid (BuildError::Empty)');
    this._solid = this._solid.translate(dx, dy, dz);
    return this;
  }
  faces(selector) {
    if (this._solid === null) throw new BuildError('faces: the workplane holds no solid (BuildError::Empty)');
    this._selected = this._solid.selectFace(selector);
    return this;
  }
  /** Adopt the frame on the face last picked; a no-op if none is. */
  workplane() { if (this._solid !== null && this._selected !== null) this.frame = this._solid.faceFrame(this._selected); return this; }
  solid() { if (this._solid === null) throw new BuildError('solid: nothing was built (BuildError::Empty)'); return this._solid; }
}

// ---- the document: a node graph of constructive verbs, with parameters and a history ----

/** Owned text a `document_*` call returned (koffi decoded and freed it; the wasm returns the string itself); null (or the wasm's 0) raises the library's reason. */
function _ownedText(raw, what) {
  if (raw == null || raw === 0) _fail(what);
  return String(raw);
}

/** An optional commit message as C takes it: empty or none is null. */
function _documentMessage(message) { return message ? String(message) : null; }

/**
 * One commit of a `Document`'s history: its `id` (`c0` is the root), its `parents` (ids), the
 * `message` it was recorded with, its `author` and `time` (null when not set), and the `ops` it
 * applied, each as the JSON record that was sent. Frozen.
 */
class Commit {
  constructor(row) {
    this.id = String(row.id);
    this.parents = Object.freeze(Array.from(row.parents ?? [], String));
    this.message = row.message ?? null;
    this.author = row.author ?? null;
    this.time = row.time ?? null;
    this.ops = Object.freeze(Array.from(row.ops ?? []));
    Object.freeze(this);
  }
}

/**
 * `Document.params`: the document's parameters, name to value (a number, or an `"=expression"`),
 * shaped like a `Map`. Reading asks the document every time; `set` sends a `param` op (one
 * commit), `delete` one with a null value.
 */
class DocumentParams {
  constructor(document) { this._document = document; }
  _read() { return JSON.parse(this._document._text('params', (l, h) => l.document_params(h))); }
  /** The parameter's value, or undefined when there is none of that name. */
  get(name) { const p = this._read(); return Object.prototype.hasOwnProperty.call(p, name) ? p[name] : undefined; }
  has(name) { return Object.prototype.hasOwnProperty.call(this._read(), name); }
  /** Sets (or adds) a parameter: a `param` op, one commit. Null is refused: `delete` it instead. Returns this. */
  set(name, value) {
    if (value == null) throw new BuildError('document_params: a parameter cannot be null: delete it instead');
    this._document.apply({ op: 'param', name: String(name), value });
    return this;
  }
  /** Removes a parameter, one commit: false when there was none of that name; a parameter a node reads is refused. */
  delete(name) {
    if (!this.has(name)) return false;
    this._document.apply({ op: 'param', name: String(name), value: null });
    return true;
  }
  keys() { return Object.keys(this._read()); }
  get size() { return this.keys().length; }
  /** Every parameter as a plain object, name to value. */
  toObject() { return this._read(); }
}

const _documentFinalizer = typeof FinalizationRegistry === 'function'
  ? new FinalizationRegistry((h) => { try { _lib().document_free(h); } catch (_) { /* exiting */ } }) : null;

/**
 * A model as data: a graph of nodes (`profile.rect`, `solid.extrude`, `measure.mass`, ...), each
 * a blacksmith verb reading other nodes by id, with named parameters any number can be an
 * `"=expression"` of, evaluated incrementally, and edited by ops that are undoable and branch.
 * Every edit is one commit; the whole thing -- nodes, parameters, history, branches -- saves as
 * JSON text and loads back to the same document. `Document.kinds()` lists the node kinds.
 *
 *     const doc = new Document('mm');
 *     doc.params.set('w', 200);
 *     const r = doc.add('profile.rect', { w: '=w', h: 100 });
 *     const x = doc.add('solid.extrude', { profile: r, frame: 'xy', distance: 10 });
 *     const solid = doc.result(x);        // a Solid
 *     doc.set(x, { distance: 80, message: 'taller' });
 *     doc.undo();
 *
 * A refused op throws `BuildError` with the reason, and the document is unchanged. `result`,
 * `value`, `errors` and `evaluate` bring the nodes up to date first. `close()` frees the
 * document; so does leaving a `using` block or the garbage collector. One thread at a time.
 */
class Document {
  /** An empty document counting lengths in `units` (`mm`, `cm`, `m`, `in` or `ft`). */
  constructor(units = 'mm') {
    this._pointer = null;
    this._adopt(_lib().document_new(String(units)), 'document_new');
  }
  _adopt(handle, what) {
    this._pointer = _checked(handle, what);
    if (_documentFinalizer) _documentFinalizer.register(this, this._pointer, this);
  }
  static _of(handle, what) {
    const d = Object.create(Document.prototype);
    d._pointer = null;
    d._adopt(handle, what);
    return d;
  }
  /** The document `save` wrote as `text`: its nodes, parameters, history and branches. */
  static load(text) { return Document._of(_lib().document_load(String(text)), 'document_load'); }
  /** The document saved in the file `filePath`. */
  static open(filePath) { return Document.load(fs.readFileSync(filePath, 'utf8')); }
  /** Every node kind the library knows, one record a kind (`name`, `inputs`, `output`, `cost`, `help`). */
  static kinds() { return JSON.parse(_ownedText(_lib().document_kinds(), 'document_kinds')); }

  // -- building documents
  /**
   * An empty building document: the blacksmith kinds and the `bim.*` ones, with a hidden
   * `bim.project` node whose guid seeds every IFC GlobalId it exports.
   */
  static newBim(units = 'mm') {
    const doc = Document._of(_lib().bim_document_new(String(units)), 'bim_document_new');
    if (_wasm()) {
      // The wasm's `_new` is the editor's, whose starter batch adds the project; the C one adds
      // it itself. Here it is added as C adds it: hidden, one commit (Python's, under Pyodide).
      const guid = globalThis.crypto?.randomUUID ? globalThis.crypto.randomUUID() : require('node:crypto').randomUUID();
      doc.apply({ op: 'add', node: { id: 'project', kind: 'bim.project', hidden: true, guid } }, 'ifc project');
    }
    return doc;
  }
  /** A saved building document, opened with the `bim.*` kinds. */
  static loadBim(text) { return Document._of(_lib().bim_document_load(String(text)), 'bim_document_load'); }
  /** The building document saved in the file `filePath`. */
  static openBim(filePath) { return Document.loadBim(fs.readFileSync(filePath, 'utf8')); }
  /** Every node kind a building document knows: the blacksmith's and the `bim.*` ones. */
  static bimKinds() { return JSON.parse(_ownedText(_lib().bim_kinds(), 'bim_kinds')); }
  /**
   * The building as IFC text (`schema` `IFC4` or `IFC2X3`, `geometry` `parametric` or `exact`);
   * with `filePath`, also written to that file. `timestamp` (Unix seconds) defaults to now. A
   * refused export throws `BuildError` with one reason a line (`node: reason`); its `refusals` is
   * a list of `[node, reason]`, `node` null for a reason on the whole document. A refusal writes
   * no file.
   */
  exportIfc(filePath = null, { schema = 'IFC4', geometry = 'parametric', timestamp = null, name = '' } = {}) {
    const options = JSON.stringify({ schema, geometry, timestamp: timestamp == null ? Math.floor(Date.now() / 1000) : timestamp, name });
    let text;
    try {
      text = _ownedText(_lib().bim_document_export_ifc(this._handle, options), 'bim_document_export_ifc');
    } catch (e) {
      const message = e instanceof BuildError ? e.message : '';
      const start = message.indexOf('{"refusals"');
      if (start < 0) throw e;
      const refusals = JSON.parse(message.slice(start)).refusals.map((r) => [r.node ?? null, r.reason]);
      const err = new BuildError(refusals.map(([n, r]) => (n ? `${n}: ${r}` : r)).join('\n'));
      err.refusals = refusals;
      throw err;
    }
    if (filePath != null) fs.writeFileSync(filePath, text, 'utf8');
    return text;
  }

  get _handle() {
    if (!this._pointer) throw new BuildError('document: closed');
    return this._pointer;
  }
  get closed() { return this._pointer === null; }
  close() {
    if (this._pointer === null) return;
    const h = this._pointer; this._pointer = null;
    if (_documentFinalizer) _documentFinalizer.unregister(this);
    _lib().document_free(h);
  }
  [DISPOSE]() { this.close(); }
  /** `call(lib, handle)`'s owned text (a null one raises the library's reason under `document_<what>`). */
  _text(what, call) { return _ownedText(call(_lib(), this._handle), 'document_' + what); }
  _json(what, call) { return JSON.parse(this._text(what, call)); }
  toString() { return this._pointer === null ? 'Document(closed)' : `Document(branch=${JSON.stringify(this.branch)}, head=${JSON.stringify(this.head.id)})`; }

  // -- saving
  /** The document as JSON text; with `filePath`, also written to that file. */
  save(filePath = null) {
    const text = this._text('save', (l, h) => l.document_save(h));
    if (filePath != null) fs.writeFileSync(filePath, text, 'utf8');
    return text;
  }

  // -- editing
  /**
   * Applies one op (a record, or its JSON text: `{op: 'add', node: {...}}`, `set`, `remove`,
   * `rename`, `param`) and records it as one commit with `message`. The changed set,
   * `{added: [ids], changed: [ids], removed: [ids], params: [names]}`.
   */
  apply(op, message = null) {
    const text = typeof op === 'string' ? op : JSON.stringify(op);
    return this._json('apply', (l, h) => l.document_apply(h, text, _documentMessage(message)));
  }
  /**
   * A new node of `kind` (`'profile.rect'`) with `fields` (`{w: 10, h: '=w', profile: 'r1'}`),
   * one commit. Its id is made up unless `fields.id` gives one; it is returned. `fields.message`
   * is the commit's message, not a field.
   */
  add(kind, fields = {}) {
    const { message = null, ...rest } = fields;
    return this.apply({ op: 'add', node: { kind, ...rest } }, message).added[0];
  }
  /**
   * A node holding `solid` exactly as it is: a `solid.body` (a `sheet.body` with `sheet: true`)
   * carrying the kernel's own B-rep (`Solid.documentBody()`), its colours kept. Its id is
   * returned; `id`, `name` and `message` as for `add`.
   */
  addSolid(solid, { sheet = false, ...fields } = {}) {
    return this.add(sheet ? 'sheet.body' : 'solid.body', { body: solid.documentBody(), ...fields });
  }
  /** A `profile.path` node holding `profile` exactly (`Profile.documentPath()`). Its id is returned; `id`, `name` and `message` as for `add`. */
  addProfile(profile, fields = {}) { return this.add('profile.path', { path: profile.documentPath(), ...fields }); }
  /** Sets `fields` of node `id`, one commit; the changed set. `fields.message` is the commit's message, not a field. */
  set(id, fields = {}) {
    const { message = null, ...rest } = fields;
    return this.apply({ op: 'set', id, fields: rest }, message);
  }
  /** Removes node `id`. Refused while another node reads it, unless `cascade` takes those with it. */
  remove(id, { cascade = false, message = null } = {}) {
    const op = { op: 'remove', id };
    if (cascade) op.cascade = true;
    return this.apply(op, message);
  }
  /** Gives node `id` the display name `name` (null clears it). */
  rename(id, name, message = null) { return this.apply({ op: 'rename', id, name: name ?? null }, message); }
  /** The parameters: `get`, `set` (a `param` op), `delete`, `has`, `keys()`, `size`, `toObject()`. */
  get params() { return new DocumentParams(this); }
  /**
   * `doc.batch('slot and fillet', () => { ... })`: the ops `body` applies are applied live and
   * recorded as one commit with `message` (which may be left out). An error thrown by `body`
   * rolls every op of the batch back and is thrown on. `body` runs synchronously; its result is
   * returned.
   */
  batch(message, body) {
    if (typeof message === 'function') { body = message; message = null; }
    if (!_lib().document_batch_begin(this._handle, _documentMessage(message))) _fail('document_batch_begin');
    const out = this._scoped(body, 'batch', 'batch_abort', (l, h) => l.document_batch_abort(h));
    this._text('batch_end', (l, h) => l.document_batch_end(h));
    return out;
  }
  /**
   * `doc.preview(() => { ... })`: the ops `body` applies are applied (and evaluate) but never
   * recorded, and are taken back on leaving, normally or by an error: a drag, a what-if.
   */
  preview(body) {
    if (!_lib().document_preview_begin(this._handle)) _fail('document_preview_begin');
    const out = this._scoped(body, 'preview', 'end_preview', (l, h) => l.document_end_preview(h));
    this._text('end_preview', (l, h) => l.document_end_preview(h));
    return out;
  }
  /** `body()`, cleaned up by `undo` when it throws: a refused clean-up never hides the body's own error. */
  _scoped(body, scope, what, undo) {
    let out;
    try {
      out = body();
      if (out && typeof out.then === 'function') throw new BuildError(`document_${scope}: the body must be synchronous`);
    } catch (e) {
      try { this._text(what, undo); } catch (cleanup) { if (!(cleanup instanceof BuildError)) throw cleanup; }
      throw e;
    }
    return out;
  }
  /**
   * One drag frame: applies `op` without recording it, after taking back the last frame. The
   * changed set, relative to the state before the drag. Needs no `preview` scope; `endPreview()`
   * takes the drag back.
   */
  previewFrame(op) {
    const text = typeof op === 'string' ? op : JSON.stringify(op);
    return this._json('preview', (l, h) => l.document_preview(h, text));
  }
  /** Takes back an open drag (or preview); the changed set of doing so. */
  endPreview() { return this._json('end_preview', (l, h) => l.document_end_preview(h)); }

  // -- history
  /** Takes back the head commit. False when there was nothing to take back. */
  undo() { return this._text('undo', (l, h) => l.document_undo(h)).trim() !== 'null'; }
  /** Puts back the commit `undo` took back. False when there was nothing to put back. */
  redo() { return this._text('redo', (l, h) => l.document_redo(h)).trim() !== 'null'; }
  _branchList() { return this._json('branch_list', (l, h) => l.document_branch_list(h)); }
  /** Whether `undo` has a commit to take back. */
  get canUndo() { return Boolean(this._branchList().can_undo); }
  /** Whether `redo` has a commit to put back. */
  get canRedo() { return Boolean(this._branchList().can_redo); }
  /** The current branch's name, or null when the head is detached (switched to a commit id). */
  get branch() { return this._branchList().branch ?? null; }
  /** Every branch, name to the id of its tip commit. */
  get branches() { return { ...this._branchList().branches }; }
  /** A new branch `name`. Without `at` it starts at the head and the document switches onto it; with `at` (a commit id) it starts there. */
  branchNew(name, at = null) {
    this._text('branch_new', (l, h) => l.document_branch_new(h, String(name), at ? String(at) : null));
  }
  /** Moves the head to the branch of that name, else to the commit of that id (which detaches the head: `branch` is then null). */
  switch(nameOrCommitId) { this._text('branch_switch', (l, h) => l.document_branch_switch(h, String(nameOrCommitId))); }
  /** Renames branch `old` to `name`; refused when `old` is missing or `name` is taken. */
  branchRename(old, name) {
    if (!_lib().document_branch_rename(this._handle, String(old), String(name))) _fail('document_branch_rename');
  }
  /** Deletes branch `name`; the current branch is refused. Its commits stay, as tips. */
  branchDelete(name) {
    if (!_lib().document_branch_delete(this._handle, String(name))) _fail('document_branch_delete');
  }
  /** The tips of the lines no branch names -- what an undo followed by an edit leaves behind -- each a whole `Commit`. */
  tips() { return this._json('tips', (l, h) => l.document_tips(h)).map((row) => new Commit(row)); }
  /** The commits of `branch`'s line, newest first, the root `c0` last; null is the line from the head back to the root. */
  log(branch = null) {
    return this._json('log', (l, h) => l.document_log(h, branch ? String(branch) : null)).map((row) => new Commit(row));
  }
  /** The commit the document is at. */
  get head() { return this.log()[0]; }

  // -- evaluating and reading back
  /** Evaluates the stale nodes (only the cheap kinds with `cheapOnly`); the status of every node, `{id, state: 'ok'|'error'|'blocked'|'pending', ...}`. */
  evaluate({ cheapOnly = false } = {}) { return this._json('evaluate', (l, h) => l.document_evaluate(h, Boolean(cheapOnly))); }
  /**
   * `evaluate`, every kernel call's progress heard by `progress(node, phase, done, total)`:
   * `node` the id of the node being built (a progress bar, or a note of which node was being
   * built when the process died). The same statuses; a cheap-only pass reports nothing.
   * `progress` runs on this thread, often, and must not touch the document.
   */
  evaluateWith(progress, { cheapOnly = false } = {}) {
    const cb = progress == null ? null : (node, phase, done, total) => { progress(_text(node), _text(phase), Number(done), Number(total)); };
    return this._json('evaluate_with', (l, h) => l.document_evaluate_with(h, Boolean(cheapOnly), cb, null));
  }
  /** The nodes the evaluation left in error or blocked, `{id, state, message}`. */
  errors() {
    this.evaluate();
    return this._json('errors', (l, h) => l.document_errors(h));
  }
  /** Node `id`'s value, parsed: a number, a list (a point), a record, text. Throws `BuildError` for a node with none. */
  value(id) {
    this.evaluate();
    return this._value(String(id));
  }
  _value(key) { return this._json('value', (l, h) => l.document_value(h, key)); }
  /** Node `key`'s profile list, a new `Profile` each; refused (C's NONE) for a node that is not one. */
  _profiles(key) {
    const l = _lib(), h = this._handle;
    const count = l.document_result_profile_count(h, key);
    if (count === NONE) _fail('document_result_profile_count');
    return Array.from({ length: count }, (_, i) => new Profile(l.document_result_profile_at(h, key, i)));
  }
  /**
   * What node `id` evaluated to, by its kind: a `Solid` (solids and sheets), a `Profile`, an array
   * of `Profile`, a `NurbsCurve`, a `Subd`, an array of these (a node laced over a list, each item
   * also readable as `id#i`), or the `value` of a number, point, record, list and the like; null
   * for no such node or one that failed. Each handle is the caller's own and outlives the document.
   */
  result(id) {
    this.evaluate();
    const key = String(id);
    const l = _lib(), h = this._handle;
    const kind = this._text('result_kind', () => l.document_result_kind(h, key));
    if (kind === 'solid' || kind === 'sheet') return new Solid(l.document_result_solid(h, key));
    if (kind === 'profile') return new Profile(l.document_result_profile(h, key));
    if (kind === 'profiles') return this._profiles(key);
    if (kind === 'nurbs') return NurbsCurve._of(l.document_result_nurbs_curve(h, key), 'document_result_nurbs_curve');
    if (kind === 'subd') return new Subd(l.document_result_subd(h, key));
    if (kind === 'value' || kind === 'curve') return this._value(key);   // a plane curve has no handle: its value
    if (kind === 'list') {   // a laced node's: each item read as its own result, `id#0`, `id#1`, ...
      const count = this._value(key).length;
      return Array.from({ length: count }, (_, i) => this.result(`${key}#${i}`));
    }
    return null;
  }
}

// ---- STEP -------------------------------------------------------------------------

/**
 * `schema` is null (the built-in AP203), the path of a schema file, a built-in schema's
 * name, or a custom schema's own EXPRESS text -- see `writeStepText`.
 */
function _isSchemaFile(schema) {
  if (schema.includes('\n')) return false;
  try {
    return !!fs.statSync(schema, { throwIfNoEntry: false })?.isFile();
  } catch {
    // Not a name the file system will look up (ENAMETOOLONG for long one-line text on
    // Linux and macOS, EINVAL and the like elsewhere): then it is not a file, it is text.
    return false;
  }
}

function _schemaText(schema) {
  if (schema == null) return null;
  schema = String(schema);
  if (_isSchemaFile(schema)) return fs.readFileSync(schema, 'utf8');
  return schema;
}

/**
 * Several solids as one part file's text, each its own body. `schema` is one of four
 * things: null (the kernel's built-in AP203); the path of a schema file (no newline in
 * it, naming an existing file), read and sent as EXPRESS text; the bare name of a
 * built-in schema (case-insensitive, e.g.
 * `"AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF"` -- an unknown name throws
 * `BuildError`); or a custom schema's own EXPRESS text.
 */
function writeStepText(solids, schema = null, unit = 'mm') {
  if (!(unit in UNITS)) throw new BuildError(`unit must be one of ${Object.keys(UNITS).sort().join(', ')}`);
  const handles = Array.from(solids, (s) => s._handle);
  const text = _lib().step(handles, handles.length, _schemaText(schema), UNITS[unit]);
  if (text == null) _fail('step');
  return text;
}

/** One STEP file (AP203 unless `schema` names another), each solid its own body. */
function writeStep(filePath, solids, schema = null, unit = 'mm') { fs.writeFileSync(filePath, writeStepText(solids, schema, unit), 'utf8'); }

/** Several solids as one ACIS SAT file, each its own body. */
function writeSatText(solids, unit = 'mm') {
  if (!(unit in UNITS)) throw new BuildError(`unit must be one of ${Object.keys(UNITS).sort().join(', ')}`);
  const handles = Array.from(solids, (s) => s._handle);
  const text = _lib().sat_text(handles, handles.length, UNITS[unit]);
  if (text == null) _fail('sat_text');
  return text;
}

/** `writeSatText` written to `filePath` by the library itself, which names the file in its refusal when it cannot. */
function writeSat(filePath, solids, unit = 'mm') {
  if (!(unit in UNITS)) throw new BuildError(`unit must be one of ${Object.keys(UNITS).sort().join(', ')}`);
  const handles = Array.from(solids, (s) => s._handle);
  if (!_lib().sat(handles, handles.length, String(filePath), UNITS[unit])) _fail('sat');
}

/**
 * What a `.3dm` write did not write as itself -- `last_error` on a success, a line each --
 * said as one `process.emitWarning` per line (`console.warn` where there is no `process`).
 */
function _warn3dm() {
  for (const line of (_lastError() || '').split('\n').filter(Boolean)) {
    if (typeof process !== 'undefined' && typeof process.emitWarning === 'function') process.emitWarning(`3dm: ${line}`);
    else console.warn(`3dm: ${line}`);
  }
}

/** The bytes a `.3dm` call handed over, copied out into a `Buffer` and released with `bytes_free` (never `string_free`), its notes warned; null is the failure `last_error` names. */
function _taken3dm(ptr, len, what) {
  if (ptr == null) _fail(what);
  _warn3dm();
  const n = Number(len[0]);
  if (ArrayBuffer.isView(ptr)) return Buffer.from(ptr);   // the wasm's own bytes
  try {
    return Buffer.from(koffi.decode(ptr, 'uint8_t', n));
  } finally {
    _lib().bytes_free(ptr, n);
  }
}

/** The wasm's file form: the bytes written through the page's own `fs`, refused in the C writer's words. */
function _write3dmBytes(filePath, data, what) {
  try { fs.writeFileSync(filePath, data); } catch (e) { throw new BuildError(`${what}: ${filePath}: ${e.message}`); }
}

/**
 * Several solids as one Rhino `.3dm` (version 8, which Rhino 8 and 9 open), one object each:
 * its exact brep, or -- where a body has no exact form there -- its mesh, with a warning
 * saying so (`process.emitWarning`, each starting "3dm: "). Each object is named as its solid
 * is, coloured with the solid's own colour (a face's or an edge's own is left out) and carries
 * the solid's attributes as user text. `unit` is the file's: the numbers written are the
 * numbers held. A `Buffer`.
 */
function rhino3dmBytes(solids, unit = 'mm') {
  if (!(unit in UNITS)) throw new BuildError(`unit must be one of ${Object.keys(UNITS).sort().join(', ')}`);
  const handles = Array.from(solids, (s) => s._handle);
  const len = _sizeSlot();
  return _taken3dm(_lib()['3dm_bytes'](handles, handles.length, UNITS[unit], len), len, '3dm_bytes');
}

/**
 * Several solids meshed at `tolerance` (null: each one's effective tolerance) -- each the mesh
 * `Solid.mesh` hands out -- as one file's bytes in `format`: `'stl'` (binary, every solid in one
 * body), `'stl-ascii'` (one body named as the first solid), `'obj'` (one named object a solid, no
 * material library), `'glb'` or `'gltf'` (one named node a solid in a material of its own; the
 * `.gltf` with its buffer embedded). `names` one a solid (null: each solid's own name, else
 * `Solid 1`, `Solid 2`, ...). `looks` one a solid, six numbers each -- linear `[r, g, b, a,
 * metallic, roughness]` in 0..1 -- the glTF's materials (null: each solid's own colour); STL and
 * OBJ ignore them. A `Buffer`.
 */
function meshFile(solids, format = 'stl', names = null, looks = null, tolerance = null) {
  const handles = Array.from(solids, (s) => s._handle);
  let cNames = null;
  if (names != null) {
    cNames = Array.from(names, String);
    if (cNames.length !== handles.length) throw new BuildError(`mesh_file: ${cNames.length} names for ${handles.length} solids`);
  }
  let cLooks = null;
  if (looks != null) {
    cLooks = Float64Array.from(Array.from(looks, (look) => Array.from(look, Number)).flat());
    if (cLooks.length !== 6 * handles.length) throw new BuildError(`mesh_file: ${cLooks.length} look values for ${handles.length} solids -- 6 a solid`);
  }
  const len = _sizeSlot();
  const l = _lib();
  const ptr = l.mesh_file(handles, handles.length, String(format), cNames, cLooks, _tol(tolerance), len);
  if (ptr == null) _fail('mesh_file');
  if (ArrayBuffer.isView(ptr)) return Buffer.from(ptr);   // the wasm's own bytes, nothing to free
  const n = Number(len[0]);
  try {
    return Buffer.from(koffi.decode(ptr, 'uint8_t', n));
  } finally {
    l.bytes_free(ptr, n);
  }
}

/** `rhino3dmBytes` written to `filePath` by the library itself, which names the file in its refusal when it cannot. */
function write3dm(filePath, solids, unit = 'mm') {
  if (_wasm()) { _write3dmBytes(filePath, rhino3dmBytes(solids, unit), '3dm'); return; }
  if (!(unit in UNITS)) throw new BuildError(`unit must be one of ${Object.keys(UNITS).sort().join(', ')}`);
  const handles = Array.from(solids, (s) => s._handle);
  if (!_lib()['3dm'](handles, handles.length, String(filePath), UNITS[unit])) _fail('3dm');
  _warn3dm();
}
/** Several solids as one `.brep`, each its own solid under one compound (one solid is
 *  the file's root). */
function writeBrepText(solids) {
  const handles = Array.from(solids, (s) => s._handle);
  const text = _lib().brep_text(handles, handles.length);
  if (text == null) _fail('brep_text');
  return text;
}

/** `writeBrepText` written to `filePath` by the library itself. */
function writeBrep(filePath, solids) {
  const handles = Array.from(solids, (s) => s._handle);
  if (!_lib().brep(handles, handles.length, String(filePath))) _fail('brep');
}

/**
 * `things` (any mix of `Solid` and `Profile`, in any order) split into its solids' and
 * profiles' handles, each in the order it was given; throws for anything in `things`
 * that is neither.
 */
function _drawables(things) {
  const solidHandles = [];
  const profileHandles = [];
  for (const t of things) {
    if (t instanceof Solid) solidHandles.push(t._handle);
    else if (t instanceof Profile) profileHandles.push(t._handle);
    else throw new BuildError('svg: only solids and profiles can be drawn');
  }
  return { solidHandles, profileHandles };
}

/**
 * The solids and profiles in `things` (any mix of `Solid` and `Profile`, in any order)
 * as one SVG drawing -- a `<g id="solid-<i>">` per solid then a `<g id="profile-<i>">`
 * per profile, from the camera `options` describes (see `svgOptionsDefaults`). Always
 * `cadaclysm_blacksmith_drawing_svg_text`, solids-only calls included: it refuses in the
 * same words `cadaclysm_blacksmith_svg_text` always did (both read `"svg"`, not
 * `"drawing_svg"`, as their own `what`), so a list of solids alone draws -- and fails --
 * exactly as it always did. Owned by the library: decoded and released before this
 * returns.
 */
function writeSvgText(things, options = {}) {
  const { solidHandles, profileHandles } = _drawables(things);
  const raw = _svgOptions(options);
  const text = _lib().drawing_svg_text(solidHandles, solidHandles.length, profileHandles, profileHandles.length, raw);
  if (text == null) _fail('svg_text');
  return text;
}

/**
 * `writeSvgText` written to `filePath` by the library itself, which names the file in
 * its refusal when it cannot. There is no `cadaclysm_blacksmith_drawing_svg` wasm export
 * -- the same gap `sat` (as opposed to `satText`) has -- so this throws "the wasm module
 * has no cadaclysm_blacksmith_drawing_svg: rebuild it" under the wasm build; write the
 * text `writeSvgText` already knows how to get through whatever filesystem the page
 * provides instead.
 */
function writeSvg(filePath, things, options = {}) {
  const { solidHandles, profileHandles } = _drawables(things);
  const raw = _svgOptions(options);
  if (!_lib().drawing_svg(solidHandles, solidHandles.length, profileHandles, profileHandles.length, String(filePath), raw)) _fail('svg');
}

module.exports = {
  BuildError, NONE, UNITS, Axis, SvgView,
  libraryPath, flavour, features, defaultSchema, version, buildDate, license, licenseInfo, licenseNoticeCount, brepLayoutId, pairFreedomCount,
  setOption, option, effectiveTolerance,
  svgOptionsDefaults,
  Frame, Transform, Quaternion, Interval, CurveFoot, SurfaceFoot, Line, Circle, Arc, Ellipse, Sphere, Cylinder, Cone, Torus, Cuboid, Rectangle, Triangle, Ray, Profile, Path, SweepPath, Slant, Solid, History, Assembly, Selector, Edge, Curve, Intersection, Chain, Overlap, Finding, Hit, Spot, SolidHits, Piece, Workplane, writeStep, writeStepText, writeSat, writeSatText, write3dm, rhino3dmBytes, meshFile, writeBrep, writeBrepText, writeSvg, writeSvgText,
  FemMesh, FemEdge, FemVertex,
  Box, boxesApart, Collider, CollisionHit, Clash, clash, SweptClash, sweptClash,
  Thickness, FaceThickness, ThicknessMesh, MeshThickness, ThicknessGauge, thickness, meshThickness,
  Classifier, Projector, PointFoot, CurvePair, CurveBodyFoot, NearestObject, TriangleMesh, MeshPoint, CurveMeshFoot,
  Hlr, HlrLine, Page, HLR_KINDS, PAGE_UNITS, hlr, hlrMesh, projectedOutline, dxfProfiles,
  RTree, closestPoints, kNeighbors,
  Interpolator,
  NurbsCurve, Curvature, Continuity, KnotContinuity, CurvatureTurns, HighlightKink, PatchReport, JoinReport, SymmetryReport,
  Pattern, PatternReport, HoleReport,
  Subd, SubdMesh, SubdReport,
  HealthReport, FreeEdge, FreeWire, SmallFeature, Cracks, HealReport, HealFix, HealRefusal,
  Sketch, SolveReport, Dof, PartDof,
  Tool, Stock, Job, Program, Operation, ReportItem,
  Document, Commit, DocumentParams,
  _lib, _wasmLibrary, _wasmHistory, _readHistory, _lastError, _frame, _axis, _progress, _searchedPaths, _notFoundMessage, _floats, _uint32s, _doublesAt, _svgOptions,
  _femEdgeOf, _femVertexOf, _censusRows, _femOptions, _containment,
  _healthReport, _healReport, _healFlags,
};
