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
 */
const fs = require('node:fs');
const path = require('node:path');
const koffi = require('koffi');

class BuildError extends Error {
  constructor(message) { super(message); this.name = 'BuildError'; }
}

const NONE = 0xFFFFFFFF;
const UNITS = { m: 0, mm: 1, in: 2 };

// ---- finding the library ---------------------------------------------------

function libraryName() {
  if (process.platform === 'win32') return 'cadaclysm_blacksmith.dll';
  if (process.platform === 'darwin') return 'libcadaclysm_blacksmith.dylib';
  return 'libcadaclysm_blacksmith.so';
}

function ancestors(dir) {
  const out = [];
  for (let d = dir; ; d = path.dirname(d)) { out.push(d); if (path.dirname(d) === d) return out; }
}

function _searchedPaths() {
  const name = libraryName();
  const searched = [path.join(__dirname, name)];
  for (const a of ancestors(__dirname)) searched.push(path.join(a, 'lib', name));
  for (const a of ancestors(__dirname)) searched.push(path.join(a, 'target', 'release', name), path.join(a, 'target', 'debug', name));
  return searched;
}

function _notFoundMessage(searched) {
  return `${libraryName()} not found. Looked in:\n` + searched.map((p) => `    ${p}\n`).join('')
    + 'Build it with:\n    cargo build --release -p cadaclysm-blacksmith-capi\n'
    + 'or run fetch.py in an SDK checkout, or point CADACLYSM_BLACKSMITH_LIBRARY at it.';
}

/** Where the shared library is: `CADACLYSM_BLACKSMITH_LIBRARY`, beside this file, an ancestor's `lib/`, an ancestor's `target/release` or `target/debug`. */
function libraryPath() {
  const override = process.env.CADACLYSM_BLACKSMITH_LIBRARY;
  if (override) {
    let candidate = override;
    if (fs.existsSync(candidate) && fs.statSync(candidate).isDirectory()) candidate = path.join(candidate, libraryName());
    if (fs.existsSync(candidate)) return candidate;
    throw new BuildError(`CADACLYSM_BLACKSMITH_LIBRARY=${override} names nothing that exists`);
  }
  const searched = _searchedPaths();
  for (const c of searched) if (fs.existsSync(c)) return c;
  throw new BuildError(_notFoundMessage(searched));
}

/** `schemas/ap203.exp`: `CADACLYSM_SCHEMAS/ap203.exp` if set, else `schemas/ap203.exp` in any ancestor. */
function defaultSchema() {
  const candidates = [];
  if (process.env.CADACLYSM_SCHEMAS) candidates.push(path.join(process.env.CADACLYSM_SCHEMAS, 'ap203.exp'));
  for (const a of ancestors(__dirname)) candidates.push(path.join(a, 'schemas', 'ap203.exp'));
  for (const c of candidates) if (fs.existsSync(c)) return c;
  throw new BuildError('ap203.exp not found; pass schema (a path or the schema\'s text)');
}

// ---- the ABI's types -------------------------------------------------------
// Declared by the header's names, in the header's field order, one field per
// line: `tests/bindings.rs` compares these blocks with the header.

koffi.opaque('CadaclysmBlacksmithPath');
koffi.opaque('CadaclysmBlacksmithProfile');
koffi.opaque('CadaclysmBlacksmithSolid');
koffi.opaque('CadaclysmBlacksmithSweepPath');

const CadaclysmBlacksmithMesh = koffi.struct('CadaclysmBlacksmithMesh', {
  positions: 'const float *',
  normals: 'const float *',
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
const CadaclysmBlacksmithEdge = koffi.struct('CadaclysmBlacksmithEdge', {
  kind: 'const char *',
  faces: 'const uint32_t *',
  face_count: 'uint32_t',
  segments: 'const double *',
  segment_count: 'uint32_t',
});
const CadaclysmBlacksmithProgress = koffi.proto('void CadaclysmBlacksmithProgress(const char *phase, size_t done, size_t total, void *user)');

// ---- the function table ----------------------------------------------------

let library = null;

function _lib() {
  if (library) return library;
  const l = koffi.load(libraryPath());
  const f = (proto) => l.func(proto);
  const string_free = f('void cadaclysm_blacksmith_string_free(void *s)');
  // An owned string: decoded to JS, then handed back to the library to free.
  koffi.disposable('CadaclysmBlacksmithOwnedString', 'str', string_free);
  library = {
    last_error: f('const char *cadaclysm_blacksmith_last_error(void)'),
    version: f('const char *cadaclysm_blacksmith_version(void)'),
    solid_free: f('void cadaclysm_blacksmith_solid_free(CadaclysmBlacksmithSolid *solid)'),
    profile_free: f('void cadaclysm_blacksmith_profile_free(CadaclysmBlacksmithProfile *profile)'),
    license_set: f('bool cadaclysm_blacksmith_license_set(const char *text_or_path)'),
    license_info: f('const char *cadaclysm_blacksmith_license_info(void)'),
    license_notice_count: f('uint64_t cadaclysm_blacksmith_license_notice_count(void)'),
    build_date: f('const char *cadaclysm_blacksmith_build_date(void)'),
    mesh: f('CadaclysmBlacksmithMesh cadaclysm_blacksmith_mesh(const CadaclysmBlacksmithSolid *solid, double tolerance)'),
    edge_polylines: f('CadaclysmBlacksmithPolylines cadaclysm_blacksmith_edge_polylines(const CadaclysmBlacksmithSolid *solid, double tolerance)'),
    bounds: f('bool cadaclysm_blacksmith_bounds(const CadaclysmBlacksmithSolid *solid, double tolerance, _Out_ double *min, _Out_ double *max)'),
    step: f('CadaclysmBlacksmithOwnedString cadaclysm_blacksmith_step(const CadaclysmBlacksmithSolid **solids, size_t count, const char *schema, uint32_t unit)'),
    string_free,
    profile_rect: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_rect(double w, double h)'),
    profile_circle: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_circle(double r)'),
    profile_slot: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_slot(double cx, double cy, double length, double r)'),
    profile_polygon: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_polygon(const double *xy, size_t count)'),
    profile_with_hole: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_with_hole(const CadaclysmBlacksmithProfile *outer, const CadaclysmBlacksmithProfile *hole)'),
    path_begin: f('CadaclysmBlacksmithPath *cadaclysm_blacksmith_path_begin(double x, double y)'),
    path_line_to: f('bool cadaclysm_blacksmith_path_line_to(CadaclysmBlacksmithPath *p, double x, double y)'),
    path_arc_to: f('bool cadaclysm_blacksmith_path_arc_to(CadaclysmBlacksmithPath *p, double x, double y, double cx, double cy, bool ccw)'),
    path_bezier_to: f('bool cadaclysm_blacksmith_path_bezier_to(CadaclysmBlacksmithPath *p, double c1x, double c1y, double c2x, double c2y, double x, double y)'),
    path_nurbs_to: f('bool cadaclysm_blacksmith_path_nurbs_to(CadaclysmBlacksmithPath *p, const double *control_xy, size_t control_count, const double *weights, const double *knots, size_t knot_count, uint32_t degree)'),
    path_end: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_path_end(CadaclysmBlacksmithPath *p)'),
    path_end_open: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_path_end_open(CadaclysmBlacksmithPath *p)'),
    path_free: f('void cadaclysm_blacksmith_path_free(CadaclysmBlacksmithPath *p)'),
    face_count: f('uint32_t cadaclysm_blacksmith_face_count(const CadaclysmBlacksmithSolid *solid)'),
    select_face: f('uint32_t cadaclysm_blacksmith_select_face(const CadaclysmBlacksmithSolid *solid, uint32_t kind, const double *v, uint32_t index)'),
    face_frame: f('bool cadaclysm_blacksmith_face_frame(const CadaclysmBlacksmithSolid *solid, uint32_t face, _Out_ double *out)'),
    face_kind: f('const char *cadaclysm_blacksmith_face_kind(const CadaclysmBlacksmithSolid *solid, uint32_t face)'),
    coloured: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_coloured(const CadaclysmBlacksmithSolid *solid, uint32_t face, double r, double g, double b)'),
    colour: f('bool cadaclysm_blacksmith_colour(const CadaclysmBlacksmithSolid *solid, uint32_t face, _Out_ double *out)'),
    edge_count: f('uint32_t cadaclysm_blacksmith_edge_count(const CadaclysmBlacksmithSolid *solid)'),
    edge: f('bool cadaclysm_blacksmith_edge(const CadaclysmBlacksmithSolid *solid, uint32_t i, _Out_ CadaclysmBlacksmithEdge *out)'),
    leaked_edges: f('uint32_t cadaclysm_blacksmith_leaked_edges(const CadaclysmBlacksmithSolid *solid, double tolerance)'),
    unpaired_edges: f('uint32_t cadaclysm_blacksmith_unpaired_edges(const CadaclysmBlacksmithSolid *solid, double tolerance)'),
    cuboid: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_cuboid(double x, double y, double z)'),
    cylinder: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_cylinder(double r, double h)'),
    cone: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_cone(double r, double h)'),
    sphere: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sphere(double r)'),
    torus: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_torus(double major, double minor)'),
    wedge: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_wedge(double x, double y, double z, double top_x)'),
    extrude: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_extrude(const CadaclysmBlacksmithProfile *profile, const double *frame, double height)'),
    extrude_open: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_extrude_open(const CadaclysmBlacksmithProfile *profile, const double *frame, double height)'),
    extrude_tapered: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_extrude_tapered(const CadaclysmBlacksmithProfile *profile, const double *frame, double height, double taper)'),
    extrude_open_tapered: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_extrude_open_tapered(const CadaclysmBlacksmithProfile *profile, const double *frame, double height, double taper)'),
    extrude_between: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_extrude_between(const CadaclysmBlacksmithProfile *profile, const double *frame, const double *bottom, const double *top)'),
    extrude_open_between: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_extrude_open_between(const CadaclysmBlacksmithProfile *profile, const double *frame, const double *bottom, const double *top)'),
    slant_of_plane: f('bool cadaclysm_blacksmith_slant_of_plane(const double *frame, const double *point, const double *normal, _Out_ double *out)'),
    loft: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_loft(const CadaclysmBlacksmithProfile *a, const double *frame_a, const CadaclysmBlacksmithProfile *b, const double *frame_b)'),
    loft_open: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_loft_open(const CadaclysmBlacksmithProfile *a, const double *frame_a, const CadaclysmBlacksmithProfile *b, const double *frame_b)'),
    revolve: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_revolve(const CadaclysmBlacksmithProfile *profile, const double *axis, double angle)'),
    revolve_open: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_revolve_open(const CadaclysmBlacksmithProfile *profile, const double *axis, double angle)'),
    extrude_faces: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_extrude_faces(const CadaclysmBlacksmithSolid *sheet, double height)'),
    place: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_place(const CadaclysmBlacksmithSolid *solid, const double *frame)'),
    translate_profile: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_translate_profile(const CadaclysmBlacksmithProfile *profile, double dx, double dy)'),
    profile_round: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_round(const CadaclysmBlacksmithProfile *profile, double radius, const uint32_t *corners, size_t count, bool open)'),
    face: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_face(const CadaclysmBlacksmithProfile *profile, const double *frame)'),
    face_sheet: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_face_sheet(const CadaclysmBlacksmithSolid *solid, uint32_t face)'),
    drop_faces: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_drop_faces(const CadaclysmBlacksmithSolid *solid, const uint32_t *faces, size_t count)'),
    trim: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_trim(const CadaclysmBlacksmithSolid *sheet, const CadaclysmBlacksmithSolid *tool, bool keep_inside, double tolerance, CadaclysmBlacksmithProgress *progress, void *user)'),
    translate: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_translate(const CadaclysmBlacksmithSolid *solid, double dx, double dy, double dz)'),
    rotate: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_rotate(const CadaclysmBlacksmithSolid *solid, const double *axis, double radians)'),
    mirror: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_mirror(const CadaclysmBlacksmithSolid *solid, const double *plane)'),
    join: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_join(const CadaclysmBlacksmithSolid *a, const CadaclysmBlacksmithSolid *b, double tolerance, CadaclysmBlacksmithProgress *progress, void *user)'),
    cut: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_cut(const CadaclysmBlacksmithSolid *a, const CadaclysmBlacksmithSolid *b, double tolerance, CadaclysmBlacksmithProgress *progress, void *user)'),
    common: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_common(const CadaclysmBlacksmithSolid *a, const CadaclysmBlacksmithSolid *b, double tolerance, CadaclysmBlacksmithProgress *progress, void *user)'),
    split_sheet: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_split_sheet(const CadaclysmBlacksmithSolid *sheet, const CadaclysmBlacksmithSolid *tool, double tolerance, CadaclysmBlacksmithProgress *progress, void *user)'),
    fillet: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_fillet(const CadaclysmBlacksmithSolid *solid, const uint32_t *edges, size_t count, double radius, double tolerance, CadaclysmBlacksmithProgress *progress, void *user)'),
    chamfer: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_chamfer(const CadaclysmBlacksmithSolid *solid, const uint32_t *edges, size_t count, double distance, double tolerance)'),
    shell: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_shell(const CadaclysmBlacksmithSolid *solid, double thickness, const uint32_t *open_faces, size_t count, double tolerance, CadaclysmBlacksmithProgress *progress, void *user)'),
    sweep_path_begin: f('CadaclysmBlacksmithSweepPath *cadaclysm_blacksmith_sweep_path_begin(double x, double y, double z)'),
    sweep_path_line_to: f('bool cadaclysm_blacksmith_sweep_path_line_to(CadaclysmBlacksmithSweepPath *p, double x, double y, double z)'),
    sweep_path_arc: f('bool cadaclysm_blacksmith_sweep_path_arc(CadaclysmBlacksmithSweepPath *p, double cx, double cy, double cz, double ax, double ay, double az, double angle)'),
    sweep_path_along: f('CadaclysmBlacksmithSweepPath *cadaclysm_blacksmith_sweep_path_along(const CadaclysmBlacksmithProfile *curve, const double *frame, double tolerance, bool open)'),
    sweep_path_free: f('void cadaclysm_blacksmith_sweep_path_free(CadaclysmBlacksmithSweepPath *p)'),
    sweep: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sweep(const CadaclysmBlacksmithProfile *profile, const double *frame, const CadaclysmBlacksmithSweepPath *path)'),
    sweep_open: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sweep_open(const CadaclysmBlacksmithProfile *profile, const double *frame, const CadaclysmBlacksmithSweepPath *path)'),
  };
  return library;
}

// ---- helpers ------------------------------------------------------------------

function _text(raw) { return raw == null ? '' : String(raw); }
function _lastError() { return _text(_lib().last_error()); }
/** Throw the library's own reason, or `what` if it left none. */
function _fail(what) { throw new BuildError(_lastError() || what); }
/** [r, g, b] from '#rgb', '#rrggbb' or three numbers; the range is the library's to check. */
function _rgb(colour) {
  if (typeof colour === 'string') {
    let h = colour.trim().replace(/^#/, '');
    if (/^([0-9a-f]{3}|[0-9a-f]{6})$/i.test(h)) {
      if (h.length === 3) h = [...h].map((c) => c + c).join('');
      return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16) / 255);
    }
  } else if (colour != null && typeof colour[Symbol.iterator] === 'function') {
    const v = [...colour].map(Number);
    if (v.length === 3) return v;
  }
  throw new BuildError(`coloured: a colour is "#rgb", "#rrggbb" or (r, g, b) in 0..1, not ${JSON.stringify(colour)}`);
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
/** A JS `(phase, done, total)` callback as the ABI's progress pointer, or null. */
function _progress(callback) {
  if (callback == null) return null;
  return (phase, done, total) => { callback(_text(phase), Number(done), Number(total)); };
}
function _floats(ptr, n) { return ptr == null ? null : n === 0 ? new Float32Array(0) : koffi.decode(ptr, 'float', n); }
function _uint32s(ptr, n) { return ptr == null ? null : n === 0 ? new Uint32Array(0) : koffi.decode(ptr, 'uint32_t', n); }
function _doublesAt(ptr, n) { return ptr == null ? null : n === 0 ? new Float64Array(0) : koffi.decode(ptr, 'double', n); }

// ---- module-level ---------------------------------------------------------------

function version() { return _text(_lib().version()); }
function buildDate() { return _text(_lib().build_date()); }
function license(textOrPath) { if (!_lib().license_set(String(textOrPath))) throw new BuildError(_lastError() || 'license refused'); }
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
  static path(start) { return new Path(start); }
  withHole(hole) { return new Profile(_lib().profile_with_hole(this._handle, hole._handle)); }
  translate(dx, dy) { return new Profile(_lib().translate_profile(this._handle, dx, dy)); }
  /**
   * Corners between two straight segments rounded by `radius`, with an exact tangent arc.
   * `corners` null rounds every one (the holes' too); otherwise it picks corners of the
   * boundary -- corner `k` is where segment `k` ends. `open` keeps an open chain's ends square.
   */
  round(radius, corners = null, open = false) {
    // A picked list, even an empty one, is a non-null array: null means every corner.
    const which = corners == null ? null : Uint32Array.from(Array.from(corners, Number));
    const list = which == null ? null : which.length ? which : new Uint32Array(1);
    return new Profile(_lib().profile_round(this._handle, radius, list, which == null ? 0 : which.length, !!open));
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
  _live() { if (!this._handle) throw new BuildError('path: already ended'); return this._handle; }
  _step(ok, what) { if (!ok) _fail(what); return this; }
  lineTo(x, y) { return this._step(_lib().path_line_to(this._live(), x, y), 'path_line_to'); }
  arcTo(x, y, [cx, cy], ccw = true) { return this._step(_lib().path_arc_to(this._live(), x, y, cx, cy, ccw), 'path_arc_to'); }
  bezierTo([c1x, c1y], [c2x, c2y], [x, y]) { return this._step(_lib().path_bezier_to(this._live(), c1x, c1y, c2x, c2y, x, y), 'path_bezier_to'); }
  /** `control`: every control point after the current one, the endpoint last; `weights`: one per control point including the current one, or null; `knots`: the full knot vector. */
  nurbsTo(control, knots, degree, weights = null) {
    const c = _flatPairs(control), k = Float64Array.from(knots, Number);
    const w = weights == null ? null : Float64Array.from(weights, Number);
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
    path._handle = _checked(_lib().sweep_path_along(curve._handle, _frame(frame), tolerance, !!open), 'sweep_path_along');
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
  [Symbol.for('nodejs.dispose')]() { this.close(); }
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

// ---- solids ---------------------------------------------------------------------

const _solidFinalizer = typeof FinalizationRegistry === 'function'
  ? new FinalizationRegistry((h) => { try { _lib().solid_free(h); } catch (_) { /* exiting */ } }) : null;

/** An exact B-rep solid (or open sheet). Immutable; every operation returns a new one. `close()` frees it. */
class Solid {
  constructor(handle) {
    this._pointer = _checked(handle, 'solid');
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
  [Symbol.for('nodejs.dispose')]() { this.close(); }
  // -- building
  static cuboid(x, y, z) { return new Solid(_lib().cuboid(x, y, z)); }
  static cylinder(r, h) { return new Solid(_lib().cylinder(r, h)); }
  static cone(r, h) { return new Solid(_lib().cone(r, h)); }
  static sphere(r) { return new Solid(_lib().sphere(r)); }
  static torus(major, minor) { return new Solid(_lib().torus(major, minor)); }
  static wedge(x, y, z, topX) { return new Solid(_lib().wedge(x, y, z, topX)); }
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
  static revolve(profile, axis, angle) { return new Solid(_lib().revolve(profile._handle, _axis(axis), angle)); }
  static revolveOpen(profile, axis, angle) { return new Solid(_lib().revolve_open(profile._handle, _axis(axis), angle)); }
  static sweep(profile, frame, sweepPath) { return new Solid(_lib().sweep(profile._handle, _frame(frame), sweepPath._live())); }
  static sweepOpen(profile, frame, sweepPath) { return new Solid(_lib().sweep_open(profile._handle, _frame(frame), sweepPath._live())); }
  /** Thicken an open sheet into a solid. */
  extrudeFaces(height) { return new Solid(_lib().extrude_faces(this._handle, height)); }
  /** The flat sheet `profile` bounds on `frame`: one planar face, holes as holes, facing the frame's z. */
  static face(profile, frame) { return new Solid(_lib().face(profile._handle, _frame(frame))); }
  /** Face `face` alone, as an open sheet: its surface, loops and exact edge curves. */
  faceSheet(face) { return new Solid(_lib().face_sheet(this._handle, face)); }
  /** Without the faces at `faces`; the rest keep their order. */
  dropFaces(faces) {
    const which = Uint32Array.from(Array.from(faces, Number));
    return new Solid(_lib().drop_faces(this._handle, which, which.length));
  }
  /**
   * Cut along the closed `tool` and keep one side: `keep` 'outside' (a hole punched
   * through) or 'inside' (the sheet cut to the tool's outline).
   */
  trim(tool, keep = 'outside', tolerance = 0.05, progress = null) {
    Solid._keep(keep);
    return new Solid(_lib().trim(this._handle, tool._handle, keep === 'inside', tolerance, _progress(progress), null));
  }
  static _keep(keep) { if (keep !== 'outside' && keep !== 'inside') throw new BuildError(`trim: keep must be 'outside' or 'inside', not '${keep}'`); }
  // -- moving
  place(frame) { return new Solid(_lib().place(this._handle, _frame(frame))); }
  translate(dx, dy, dz) { return new Solid(_lib().translate(this._handle, dx, dy, dz)); }
  rotate(axis, radians) { return new Solid(_lib().rotate(this._handle, _axis(axis), radians)); }
  /** Mirror across a plane given as a frame (origin, x, y, z; the plane is spanned by x and y). */
  mirror(plane) { return new Solid(_lib().mirror(this._handle, _frame(plane))); }
  // -- combining
  join(other, tolerance = 0.05, progress = null) { return new Solid(_lib().join(this._handle, other._handle, tolerance, _progress(progress), null)); }
  cut(other, tolerance = 0.05, progress = null) { return new Solid(_lib().cut(this._handle, other._handle, tolerance, _progress(progress), null)); }
  common(other, tolerance = 0.05, progress = null) { return new Solid(_lib().common(this._handle, other._handle, tolerance, _progress(progress), null)); }
  /**
   * This solid or sheet cut along `tool`'s boundary with nothing removed:
   * every face comes back as its pieces outside `tool` and then its pieces
   * inside, in this solid's own face order -- where a surface trim starts.
   * `tool` must be a closed solid.
   */
  splitSheet(tool, tolerance = 0.05, progress = null) { return new Solid(_lib().split_sheet(this._handle, tool._handle, tolerance, _progress(progress), null)); }
  // -- asking
  get faces() {
    const n = _lib().face_count(this._handle);
    if (n === 0 && _lastError()) _fail('face_count');
    return n;
  }
  faceKind(face) { const raw = _lib().face_kind(this._handle, face); if (raw == null) _fail('face_kind'); return String(raw); }
  /** `boundsAt(0.05)`. */
  get bounds() { return this.boundsAt(0.05); }
  /** `[[minX, minY, minZ], [maxX, maxY, maxZ]]` over the tessellation at `tolerance`. */
  boundsAt(tolerance) {
    const lo = new Float64Array(3), hi = new Float64Array(3);
    if (!_lib().bounds(this._handle, tolerance, lo, hi)) _fail('bounds');
    return [Array.from(lo), Array.from(hi)];
  }
  /**
   * How many edges of the mesh at `tolerance` are bound by anything other
   * than exactly two triangles -- zero for a closed solid. A seam two solids
   * share along a line does not count; a hole or a fold does.
   */
  leakedEdges(tolerance = 0.05) {
    const n = _lib().leaked_edges(this._handle, tolerance);
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
    const n = _lib().unpaired_edges(this._handle, tolerance);
    if (n === NONE) _fail('unpaired_edges');
    return n;
  }
  /** `leakedEdges(tolerance) === 0`. */
  isWatertight(tolerance = 0.05) { return this.leakedEdges(tolerance) === 0; }
  // -- out
  /** `{ positions, normals, indices }` as fresh typed arrays at `tolerance`. */
  mesh(tolerance = 0.05) {
    const m = _lib().mesh(this._handle, tolerance);
    if (m.positions == null) _fail('mesh');
    const n = m.vertex_count;
    return {
      positions: _floats(m.positions, n * 3) ?? new Float32Array(0),
      normals: _floats(m.normals, n * 3) ?? new Float32Array(0),
      indices: _uint32s(m.indices, m.index_count) ?? new Uint32Array(0),
      vertexCount: n, indexCount: m.index_count,
    };
  }
  /** The feature edges as an array of `Float32Array`s, three floats a point. */
  edgePolylines(tolerance = 0.05) {
    const p = _lib().edge_polylines(this._handle, tolerance);
    if (p.offsets == null) _fail('edge_polylines');
    const points = _floats(p.points, p.point_count * 3) ?? new Float32Array(0);
    const offsets = _uint32s(p.offsets, p.polyline_count + 1);
    const out = [];
    for (let i = 0; i < p.polyline_count; i++) out.push(points.slice(offsets[i] * 3, offsets[i + 1] * 3));
    return out;
  }
  stepText(schema = null, unit = 'mm') { return writeStepText([this], schema, unit); }
  step(filePath, schema = null, unit = 'mm') { fs.writeFileSync(filePath, this.stepText(schema, unit), 'utf8'); }
  // -- selecting and edges
  selectFace(selector) {
    const { kind, v, index } = selector._raw();
    const i = _lib().select_face(this._handle, kind, v, index);
    if (i === NONE) _fail('select_face');
    return i;
  }
  /** Twelve numbers: origin, x, y, z of the workplane on `face`. */
  faceFrame(face) {
    const out = new Float64Array(12);
    if (!_lib().face_frame(this._handle, face, out)) _fail('face_frame');
    return Array.from(out);
  }
  // -- colour
  /** This solid coloured -- `colour` is '#rgb', '#rrggbb' or [r, g, b] in 0..1 -- or with `face`
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
      out.push(new Edge(i, _text(raw.kind), faces, segments));
    }
    return out;
  }
  static _edgeIndices(edges) { return Uint32Array.from(Array.from(edges, (e) => (e instanceof Edge ? e.index : Number(e)))); }
  /** `edges`: `Edge` objects or their indices. */
  fillet(edges, radius, tolerance = 1e-6, progress = null) {
    const which = Solid._edgeIndices(edges);
    return new Solid(_lib().fillet(this._handle, which, which.length, radius, tolerance, _progress(progress), null));
  }
  chamfer(edges, distance, tolerance = 1e-6) {
    const which = Solid._edgeIndices(edges);
    return new Solid(_lib().chamfer(this._handle, which, which.length, distance, tolerance));
  }
  /** `open`: face indices removed so the hollow is reachable. */
  shell(thickness, open = [], tolerance = 1e-6, progress = null) {
    const which = Uint32Array.from(Array.from(open, Number));
    return new Solid(_lib().shell(this._handle, thickness, which, which.length, tolerance, _progress(progress), null));
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
  async joinAsync(other, tolerance = 0.05, progress = null) { return Solid._wrap(await this._async('joinAsync', { op: 'combine', which: 'join', b: _addressOf(other._handle), tolerance }, [other], progress)); }
  async cutAsync(other, tolerance = 0.05, progress = null) { return Solid._wrap(await this._async('cutAsync', { op: 'combine', which: 'cut', b: _addressOf(other._handle), tolerance }, [other], progress)); }
  async commonAsync(other, tolerance = 0.05, progress = null) { return Solid._wrap(await this._async('commonAsync', { op: 'combine', which: 'common', b: _addressOf(other._handle), tolerance }, [other], progress)); }
  async splitSheetAsync(tool, tolerance = 0.05, progress = null) { return Solid._wrap(await this._async('splitSheetAsync', { op: 'combine', which: 'split_sheet', b: _addressOf(tool._handle), tolerance }, [tool], progress)); }
  async filletAsync(edges, radius, tolerance = 1e-6, progress = null) { return Solid._wrap(await this._async('filletAsync', { op: 'fillet', edges: Solid._edgeIndices(edges), radius, tolerance }, [], progress)); }
  async chamferAsync(edges, distance, tolerance = 1e-6) { return Solid._wrap(await this._async('chamferAsync', { op: 'chamfer', edges: Solid._edgeIndices(edges), distance, tolerance })); }
  async shellAsync(thickness, open = [], tolerance = 1e-6, progress = null) { return Solid._wrap(await this._async('shellAsync', { op: 'shell', thickness, open: Uint32Array.from(Array.from(open, Number)), tolerance }, [], progress)); }
  async trimAsync(tool, keep = 'outside', tolerance = 0.05, progress = null) {
    Solid._keep(keep);
    return Solid._wrap(await this._async('trimAsync', { op: 'trim', b: _addressOf(tool._handle), keepInside: keep === 'inside', tolerance }, [tool], progress));
  }
  async meshAsync(tolerance = 0.05) { return this._async('meshAsync', { op: 'mesh', tolerance }); }
  async stepAsync(schema = null, unit = 'mm') {
    if (!(unit in UNITS)) throw new BuildError(`unit must be one of ${Object.keys(UNITS).sort().join(', ')}`);
    return this._async('stepAsync', { op: 'step', handles: [_addressOf(this._pointer)], schemaText: _schemaText(schema), unit: UNITS[unit] });
  }
  /** This solid as a reader `Scene`, through STEP text and `cadaclysm.openMemory`. */
  toScene(schema = null) {
    let cad;
    try { cad = require('./cadaclysm'); } catch (e) { throw new BuildError(`toScene needs the reader module beside this file: ${e.message}`); }
    const schemaPath = schema == null ? defaultSchema() : String(schema);
    return cad.openMemory(this.stepText(schemaPath), 'stp', { schema: schemaPath, name: 'solid.stp' });
  }
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

/** One edge of a solid as plain data: its index (what `fillet` takes), curve kind, the faces meeting on it, its segments' ends. */
class Edge {
  constructor(index, kind, faces, segments) { this.index = index; this.kind = kind; this.faces = faces; this.segments = segments; }
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

const _XY = [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1];
const _XZ = [0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -1, 0];
const _YZ = [0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0];

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

// ---- STEP -------------------------------------------------------------------------

/** `schema` is null (the default lookup), a path, or the schema's text. */
function _schemaText(schema) {
  if (schema == null) schema = defaultSchema();
  schema = String(schema);
  if (!schema.includes('\n') && fs.existsSync(schema)) return fs.readFileSync(schema, 'utf8');
  if (schema.includes('\n')) return schema;
  throw new BuildError(`schema: ${schema} is neither a file nor schema text`);
}

function writeStepText(solids, schema = null, unit = 'mm') {
  if (!(unit in UNITS)) throw new BuildError(`unit must be one of ${Object.keys(UNITS).sort().join(', ')}`);
  const handles = Array.from(solids, (s) => s._handle);
  const text = _lib().step(handles, handles.length, _schemaText(schema), UNITS[unit]);
  if (text == null) _fail('step');
  return text;
}

/** Several solids as one AP203 file, each its own body. */
function writeStep(filePath, solids, schema = null, unit = 'mm') { fs.writeFileSync(filePath, writeStepText(solids, schema, unit), 'utf8'); }

module.exports = {
  BuildError, NONE, UNITS, Axis,
  libraryPath, defaultSchema, version, buildDate, license, licenseInfo, licenseNoticeCount,
  Profile, Path, SweepPath, Slant, Solid, Selector, Edge, Workplane, writeStep, writeStepText,
  _lib, _lastError, _frame, _axis, _progress, _searchedPaths, _notFoundMessage, _floats, _uint32s,
};
