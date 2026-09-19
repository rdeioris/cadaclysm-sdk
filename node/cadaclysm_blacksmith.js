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
    from_brep: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_from_brep(const void *brep, const char *layout_id)'),
    brep_layout_id: f('const char *cadaclysm_blacksmith_brep_layout_id(void)'),
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
    profile_regular_polygon: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_regular_polygon(double cx, double cy, double radius, uint32_t sides, double angle)'),
    profile_spline: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_spline(const double *xy, size_t count, uint32_t degree, const double *weights, bool closed)'),
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
    manifold: f('bool cadaclysm_blacksmith_manifold(const CadaclysmBlacksmithSolid *solid, _Out_ uint32_t *out)'),
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
    coil: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_coil(const CadaclysmBlacksmithProfile *profile, const double *axis, double pitch, double turns)'),
    revolve_in_plane: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_revolve_in_plane(const CadaclysmBlacksmithProfile *profile, const double *frame, const double *axis, double angle)'),
    revolve_open_in_plane: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_revolve_open_in_plane(const CadaclysmBlacksmithProfile *profile, const double *frame, const double *axis, double angle)'),
    extrude_faces: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_extrude_faces(const CadaclysmBlacksmithSolid *sheet, double height)'),
    place: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_place(const CadaclysmBlacksmithSolid *solid, const double *frame)'),
    translate_profile: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_translate_profile(const CadaclysmBlacksmithProfile *profile, double dx, double dy)'),
    profile_round: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_round(const CadaclysmBlacksmithProfile *profile, double radius, const uint32_t *corners, size_t count, bool open)'),
    profile_close_loop: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_close_loop(const CadaclysmBlacksmithProfile *profile)'),
    profile_chain: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_chain(const CadaclysmBlacksmithProfile **pieces, size_t count, double tolerance)'),
    profile_from_loops: f('CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_from_loops(const CadaclysmBlacksmithProfile **loops, size_t count)'),
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
    push_pull: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_push_pull(const CadaclysmBlacksmithSolid *solid, uint32_t face, double distance, double tolerance, CadaclysmBlacksmithProgress *progress, void *user)'),
    merge_flush: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_merge_flush(const CadaclysmBlacksmithSolid *solid)'),
    split: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_split(const CadaclysmBlacksmithSolid *solid, const CadaclysmBlacksmithSolid *tool, double tolerance, CadaclysmBlacksmithProgress *progress, void *user)'),
    split_by_plane: f('CadaclysmBlacksmithSolid *cadaclysm_blacksmith_split_by_plane(const CadaclysmBlacksmithSolid *solid, const double *plane, double tolerance, CadaclysmBlacksmithProgress *progress, void *user)'),
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
  };
  return library;
}

// ---- helpers ------------------------------------------------------------------

function _text(raw) { return raw == null ? '' : String(raw); }
function _lastError() { return _text(_lib().last_error()); }
/** Throw the library's own reason, or `what` if it left none. */
function _fail(what) { throw new BuildError(_lastError() || what); }
/** [r, g, b] from '#rgb', '#rrggbb' or three numbers; the range is the library's to check. */
/** The eight counts `cadaclysm_blacksmith_manifold` writes, as a record. */
function _manifold(row) {
  return {
    faces: row[0], edges: row[1], vertices: row[2],
    boundaryEdges: row[3], nonManifoldEdges: row[4], nonManifoldVertices: row[5],
    isManifold: row[6] === 1, isClosed: row[7] === 1,
  };
}

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
  /** A regular polygon of `sides` sides (at least 3) on the circle of `radius` about `centre`, its first corner at `angle` radians. */
  static regularPolygon([cx, cy], radius, sides, angle = 0) { return new Profile(_lib().profile_regular_polygon(cx, cy, radius, Math.max(0, sides | 0), angle)); }
  /**
   * A spline of `degree` through the control polygon `points` (`weights` one per point, or null):
   * open, from the first point to the last; `closed`, periodic and smooth through its own start.
   */
  static spline(points, degree = 3, weights = null, closed = false) {
    const xy = _flatPairs(points);
    const w = weights == null ? null : Float64Array.from(weights, Number);
    return new Profile(_lib().profile_spline(xy, xy.length / 2, Math.max(0, degree | 0), w, !!closed));
  }
  static path(start) { return new Path(start); }
  /**
   * Open profiles joined end to end into one -- the forge's merge. The pieces may come in any
   * order and either way round: each next one is the first of the rest with an end within
   * `tolerance` of either end of the chain so far, reversed where that makes it meet. Every
   * segment is kept exactly. Closed where the chain's two ends meet, otherwise an open chain.
   */
  static chain(pieces, tolerance = 1e-6) {
    const handles = Array.from(pieces, (p) => p._handle);
    return new Profile(_lib().profile_chain(handles, handles.length, tolerance));
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
// A boolean's result with its flush faces merged when `merge`; the unmerged one closed.
function _merged(solid, merge) {
  if (!merge) return solid;
  try { return solid.mergeFlush(); } finally { solid.close(); }
}

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
  /** A circle of `radius` swept along `sweepPath`, square to its start -- Fusion's Pipe: a rod, or with a positive `thickness` a tube whose walls are that thick. */
  static pipe(sweepPath, radius, thickness = 0) { return new Solid(_lib().pipe(sweepPath._live(), radius, thickness)); }
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
  /** This solid and `other` as one; `merge` merges the flush faces the join leaves (`mergeFlush`), off by default. */
  join(other, tolerance = 0.05, progress = null, merge = false) { return _merged(new Solid(_lib().join(this._handle, other._handle, tolerance, _progress(progress), null)), merge); }
  cut(other, tolerance = 0.05, progress = null, merge = false) { return _merged(new Solid(_lib().cut(this._handle, other._handle, tolerance, _progress(progress), null)), merge); }
  common(other, tolerance = 0.05, progress = null, merge = false) { return _merged(new Solid(_lib().common(this._handle, other._handle, tolerance, _progress(progress), null)), merge); }
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
  /**
   * Face `face` pushed out by `distance` along its outward normal (pulled in, negative) the way
   * Fusion and Rhino extrude a face: the prism over it joined on (cut out), and the flush faces
   * merged -- a box's top raised is one taller box of six faces. A face on a cylinder, a cone, a
   * sphere or a torus moves out along its normal instead, the surface a step out (a boss fatter,
   * a bore or a countersink narrower, a dome fuller), the flat faces beside it carried along; any
   * other curved face is refused.
   */
  pushPull(face, distance, tolerance = 0.05, progress = null) {
    return new Solid(_lib().push_pull(this._handle, face, distance, tolerance, _progress(progress), null));
  }
  /**
   * This solid split by `tool` into bodies -- Fusion's Split Body: a closed `tool` gives the parts
   * outside it, then the parts inside; a flat sheet splits by the whole plane it lies on. Each
   * connected part is a body of its own.
   */
  split(tool, tolerance = 0.05, progress = null) {
    const all = new Solid(_lib().split(this._handle, tool._handle, tolerance, _progress(progress), null));
    try { return all.lumps(); } finally { all.close(); }
  }
  /** This solid split by the plane through `plane`'s origin, square to its z: the bodies in front of it first, then those behind. */
  splitByPlane(plane, tolerance = 0.05, progress = null) {
    const all = new Solid(_lib().split_by_plane(this._handle, _frame(plane), tolerance, _progress(progress), null));
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
      throw new BuildError(`${label} has no brep: only a B-rep body has one (STEP, ACIS, Rhino, OCCT .brep, IGES, IFC), not a mesh, a curve or a CSG body`);
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
   * Rhino `.3dm`, OCCT `.brep`, IGES or IFC file, read where it draws, in the
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
      throw new BuildError(`open: the .${extension} file draws no B-rep body -- only a STEP, ACIS, Rhino, OCCT .brep, IGES or IFC body can be a solid, not a mesh, a curve or a CSG body`);
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
  /** Whether `other` is a frame with the same twelve numbers. */
  equals(other) { return other instanceof Frame && this._v.every((c, i) => c === other._v[i]); }
  [Symbol.iterator]() { return this._v[Symbol.iterator](); }
  toString() { return `Frame(origin=[${this.origin}], x=[${this.x}], y=[${this.y}], z=[${this.z}])`; }
}

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

module.exports = {
  BuildError, NONE, UNITS, Axis,
  libraryPath, defaultSchema, version, buildDate, license, licenseInfo, licenseNoticeCount, brepLayoutId,
  Frame, Profile, Path, SweepPath, Slant, Solid, Selector, Edge, Workplane, writeStep, writeStepText,
  _lib, _lastError, _frame, _axis, _progress, _searchedPaths, _notFoundMessage, _floats, _uint32s,
};
