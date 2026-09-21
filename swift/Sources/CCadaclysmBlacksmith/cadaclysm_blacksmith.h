/* cadaclysm_blacksmith - a C ABI over cadaclysm-blacksmith. Generated; do not edit. */

#ifndef CADACLYSM_BLACKSMITH_H
#define CADACLYSM_BLACKSMITH_H



#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

/**
 * Returned by any lookup that found nothing (a face no selector matched).
 */
#define CADACLYSM_BLACKSMITH_NONE UINT32_MAX

/**
 * `CadaclysmBlacksmithSvgOptions::background`'s "none" value: no `<rect>`
 * behind the drawing, the page left to whatever the viewer composites it
 * onto. Any other `background` is `0xRRGGBB`, opaque. The reader library's
 * `CADACLYSM_SVG_TRANSPARENT`, same value.
 */
#define CADACLYSM_BLACKSMITH_SVG_TRANSPARENT UINT32_MAX

/**
 * A bit of `CadaclysmBlacksmithSvgOptions::flags`: draw each solid's feature
 * edges -- the exact curves `cadaclysm_blacksmith_edge_polylines`'s
 * polylines are flattened from. The reader library's `CADACLYSM_SVG_EDGES`,
 * same value.
 */
#define CADACLYSM_BLACKSMITH_SVG_EDGES 1

/**
 * A bit of `flags`: free curves -- a solid has none, so this bit is accepted
 * and ignored. The reader library's `CADACLYSM_SVG_CURVES`, same value, kept
 * so a caller's flags mean the same thing on both libraries.
 */
#define CADACLYSM_BLACKSMITH_SVG_CURVES 2

/**
 * A bit of `flags`: isocurves -- a solid has none either, accepted and
 * ignored as `CURVES` above. The reader library's `CADACLYSM_SVG_ISOCURVES`,
 * same value.
 */
#define CADACLYSM_BLACKSMITH_SVG_ISOCURVES 4

/**
 * A bit of `flags`: write every line as straight segments that stay within
 * `tolerance` of the curve on the page, instead of being fitted back to
 * cubic Béziers -- for a consumer that reads no curves. The reader
 * library's `CADACLYSM_SVG_POLYLINES`, same value.
 */
#define CADACLYSM_BLACKSMITH_SVG_POLYLINES 8

/**
 * The hits of one call. Immutable; free with [`cadaclysm_blacksmith_hits_free`].
 */
typedef struct CadaclysmBlacksmithHits CadaclysmBlacksmithHits;

/**
 * An outline under construction: a start point and the segments drawn so far.
 * The one mutable object in this library; [`cadaclysm_blacksmith_path_end`]
 * consumes it.
 */
typedef struct CadaclysmBlacksmithPath CadaclysmBlacksmithPath;

/**
 * A closed 2D outline, with holes: what a sweep reads. Immutable. The outline a
 * viewer asks for (`profile_polylines`) is cached on it, per tolerance, like a
 * solid's tessellation.
 */
typedef struct CadaclysmBlacksmithProfile CadaclysmBlacksmithProfile;

/**
 * Profiles a boolean produced. Immutable; free with [`cadaclysm_blacksmith_profile_list_free`].
 */
typedef struct CadaclysmBlacksmithProfileList CadaclysmBlacksmithProfileList;

/**
 * An exact B-rep solid (or open sheet), with its tessellation and edge table
 * cached on first ask. Immutable.
 */
typedef struct CadaclysmBlacksmithSolid CadaclysmBlacksmithSolid;

/**
 * A 3D path under construction: where it starts and its pieces in order. Read
 * by [`cadaclysm_blacksmith_sweep`] and [`cadaclysm_blacksmith_sweep_open`],
 * which borrow it -- unlike [`crate::profile::CadaclysmBlacksmithPath`], it is
 * not consumed by sweeping, only by nothing at all: free it yourself with
 * [`cadaclysm_blacksmith_sweep_path_free`].
 */
typedef struct CadaclysmBlacksmithSweepPath CadaclysmBlacksmithSweepPath;

/**
 * A point in model space.
 */
typedef struct CadaclysmBlacksmithPoint {
  double x;
  double y;
  double z;
} CadaclysmBlacksmithPoint;

/**
 * Where a hit lands on one side. On a profile: `loop_index` (0 the boundary
 * or the open chain, then the holes in the order they were added), `segment`,
 * and `t` from 0 to 1 along it, with `face` NONE. On a solid's face: `face`
 * and its (`u`, `v`), with `loop_index` and `segment` NONE.
 */
typedef struct CadaclysmBlacksmithSpot {
  uint32_t loop_index;
  uint32_t segment;
  double t;
  uint32_t face;
  double u;
  double v;
} CadaclysmBlacksmithSpot;

/**
 * One hit, copied out. A point (`run` false): `start` and `end` are the same
 * point and each side's end spot is its start spot, `touch` true where the
 * curves are tangent there rather than crossing (where a side ends there: true
 * if the two continue each other smoothly, false at a corner or an end resting
 * at an angle). A run (`run` true): the two curves coincide from `start` to
 * `end`. A point at the join of two segments is reported once, on either: as
 * segment k at `t` 1 or as segment k + 1 at `t` 0.
 */
typedef struct CadaclysmBlacksmithHit {
  bool run;
  bool touch;
  struct CadaclysmBlacksmithPoint start;
  struct CadaclysmBlacksmithPoint end;
  struct CadaclysmBlacksmithSpot a_start;
  struct CadaclysmBlacksmithSpot a_end;
  struct CadaclysmBlacksmithSpot b_start;
  struct CadaclysmBlacksmithSpot b_end;
} CadaclysmBlacksmithHit;

/**
 * A solid's triangles, borrowed from it.
 */
typedef struct CadaclysmBlacksmithMesh {
  /**
   * Three floats per vertex.
   */
  const float *positions;
  /**
   * Three floats per vertex, unit, outward.
   */
  const float *normals;
  /**
   * Three per triangle, into `positions`.
   */
  const uint32_t *indices;
  uint32_t vertex_count;
  uint32_t index_count;
} CadaclysmBlacksmithMesh;

/**
 * How many triangles each face of a solid meshed to, borrowed from it.
 */
typedef struct CadaclysmBlacksmithFaceTriangles {
  /**
   * One count per face, in face order.
   */
  const uint32_t *counts;
  uint32_t face_count;
} CadaclysmBlacksmithFaceTriangles;

/**
 * Polylines borrowed from a solid (its feature edges) or a profile (its outline):
 * polyline `i` is `points[offsets[i] .. offsets[i + 1]]`, three floats a point.
 */
typedef struct CadaclysmBlacksmithPolylines {
  const float *points;
  /**
   * `polyline_count + 1` entries; the last equals `point_count`.
   */
  const uint32_t *offsets;
  uint32_t point_count;
  uint32_t polyline_count;
} CadaclysmBlacksmithPolylines;

/**
 * Colours borrowed from a solid, one per polyline of its feature edges:
 * `rgb[3 * i .. 3 * i + 3]` is polyline `i`'s, in 0..1, or `-1, -1, -1` for a
 * polyline on no coloured edge. `count` is 0 (and `rgb` null) where the solid
 * has no edge paint at all.
 */
typedef struct CadaclysmBlacksmithColours {
  const double *rgb;
  uint32_t count;
} CadaclysmBlacksmithColours;

/**
 * How a solid's wireframe is drawn: the camera in the viewer's words, the
 * page, the pen and which line sets. `size` is
 * `sizeof(CadaclysmBlacksmithSvgOptions)`, the struct's growth room, as in
 * `CadaclysmOpenOptions` on the reader library. Fill it with
 * [`cadaclysm_blacksmith_svg_options_init`] and change what you need.
 */
typedef struct CadaclysmBlacksmithSvgOptions {
  uint32_t size;
  /**
   * 0 = Z up, 1 = Y up.
   */
  uint32_t up;
  /**
   * Degrees about the up axis from +X: -90 looks from -Y, the front. Default -50.
   */
  double azimuth;
  /**
   * Degrees above the horizon. Default 28 -- with -50, the viewer's `iso`.
   */
  double elevation;
  /**
   * Vertical field of view in degrees; 0 (the default) is orthographic.
   */
  double fov;
  /**
   * viewBox width and height; 0 is 1000.
   */
  double width;
  double height;
  /**
   * Fraction of the content's extent left each side. Default 0.05.
   */
  double margin;
  /**
   * How far a written curve may stray, in page units. Default 0.1.
   */
  double tolerance;
  /**
   * Page units. Default 1.
   */
  double stroke_width;
  /**
   * 0xRRGGBB. Default black.
   */
  uint32_t stroke;
  /**
   * 0xRRGGBB, or `CADACLYSM_BLACKSMITH_SVG_TRANSPARENT` (the default) for none.
   */
  uint32_t background;
  /**
   * `CADACLYSM_BLACKSMITH_SVG_EDGES` (the default) | `CURVES` | `ISOCURVES`
   * | `POLYLINES`. The three line-set bits combine freely -- any one, any
   * two or all three (a solid has only edges to draw, so the other two
   * change nothing here); at least one must be set.
   */
  uint32_t flags;
} CadaclysmBlacksmithSvgOptions;

/**
 * One edge of a solid, borrowed from it: valid until the solid is freed.
 */
typedef struct CadaclysmBlacksmithEdge {
  /**
   * "line", "circle", "ellipse", "nurbs" or "other". Static.
   */
  const char *kind;
  /**
   * The faces that meet on it, in the solid's face order.
   */
  const uint32_t *faces;
  uint32_t face_count;
  /**
   * Six doubles per segment: the two ends of each trim piece of the edge.
   */
  const double *segments;
  uint32_t segment_count;
} CadaclysmBlacksmithEdge;

/**
 * One edge's exact curve, borrowed from the solid: valid until it is freed.
 * See [`cadaclysm_blacksmith_edge_curve`]'s doc for the range convention and
 * what each field means for each `kind`.
 */
typedef struct CadaclysmBlacksmithCurve {
  /**
   * "line", "circle", "ellipse" or "nurbs". Static.
   */
  const char *kind;
  struct CadaclysmBlacksmithPoint origin;
  struct CadaclysmBlacksmithPoint x;
  struct CadaclysmBlacksmithPoint y;
  struct CadaclysmBlacksmithPoint z;
  double radius;
  double radius2;
  double t0;
  double t1;
  uint32_t degree;
  /**
   * The knot vector, `NULL` (with `knot_count` 0) for a conic or a line.
   */
  const double *knots;
  uint32_t knot_count;
  /**
   * Three doubles per control point, `NULL` (with `pole_count` 0) for a
   * conic or a line.
   */
  const double *poles;
  uint32_t pole_count;
  /**
   * One weight per pole, or `NULL` for a non-rational (plain B-spline)
   * curve, a conic or a line.
   */
  const double *weights;
} CadaclysmBlacksmithCurve;

/**
 * Where a long operation reports: `phase` is a short static name ("snap",
 * "clip", ...), `done` of `total` steps within it, `user` whatever was passed
 * in. Called on the calling thread, often -- once per vertex in some phases --
 * so a sink that forwards elsewhere throttles itself. Must not call back into
 * this library. Null means silent.
 */
typedef void (*CadaclysmBlacksmithProgress)(const char *phase, size_t done, size_t total, void *user);

#ifdef __cplusplus
extern "C" {
#endif // __cplusplus

/**
 * Why the last call failed, or null if it succeeded.
 *
 * Borrowed, and good until the next call on this thread.
 *
 * # Safety
 * The returned pointer must not be freed or kept past the next call.
 */
const char *cadaclysm_blacksmith_last_error(void);

/**
 * The library's version, as `"0.1.0"`. Static; never freed.
 */
const char *cadaclysm_blacksmith_version(void);

/**
 * Release a solid. Null is a no-op.
 *
 * # Safety
 * `solid` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_solid_free(struct CadaclysmBlacksmithSolid *solid);

/**
 * Release a profile. Null is a no-op.
 *
 * # Safety
 * `profile` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_profile_free(struct CadaclysmBlacksmithProfile *profile);

/**
 * Where `a`'s curves cross, touch or run along `b`'s, both read in one plane:
 * runs where two sides (lines, arcs or splines) stay within `tolerance` of
 * each other for longer than it, parting only where one of them ends or the
 * stretch is flat -- one curve following the other, offset within
 * `tolerance` or tilted by under about half of it, even where it leaves
 * mid-both -- and points, merged within `tolerance`, ordered along `a`. An
 * end within `tolerance` of the other curve meets it. A loop is its segments
 * alone -- one that stops short of its start is an open chain. Null (and
 * `last_error`) for a null profile, a `tolerance` not positive and finite, or
 * a spline segment that does not evaluate. No hits at all is a handle with a
 * count of 0.
 *
 * # Safety
 * `a` and `b` live profiles.
 */
struct CadaclysmBlacksmithHits *cadaclysm_blacksmith_profile_hits(const struct CadaclysmBlacksmithProfile *a,
                                                                  const struct CadaclysmBlacksmithProfile *b,
                                                                  double tolerance);

/**
 * Release hits. Null is a no-op.
 *
 * # Safety
 * `hits` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_hits_free(struct CadaclysmBlacksmithHits *hits);

/**
 * How many hits. 0 (and `last_error`) for null.
 *
 * # Safety
 * `hits` live.
 */
uint32_t cadaclysm_blacksmith_hit_count(const struct CadaclysmBlacksmithHits *hits);

/**
 * Hit `i` into `out`. `false` (and `last_error`) for null `hits`, a null
 * `out`, or `i` out of range.
 *
 * # Safety
 * `hits` live; `out` a valid struct.
 */
bool cadaclysm_blacksmith_hit(const struct CadaclysmBlacksmithHits *hits,
                              uint32_t i,
                              struct CadaclysmBlacksmithHit *out);

/**
 * This library's brep layout: the compiler, target, profile and source it was
 * built from, as one string. Equal to the reader library's
 * `cadaclysm_brep_layout_id()` exactly when the two can share a brep. Static;
 * never freed.
 */
const char *cadaclysm_blacksmith_brep_layout_id(void);

/**
 * A solid over an imported body's exact brep, **shared with the reader, not
 * copied**: `brep` is what the reader library's `cadaclysm_node_brep` returned,
 * `layout_id` what its `cadaclysm_brep_layout_id` returns.
 *
 * The solid takes a reference of its own; the caller's is still the caller's,
 * to give back with `cadaclysm_brep_release` whether this succeeded or not. The
 * scene the brep came from may be closed before or after the solid is freed --
 * the brep lives until the last holder lets go of it.
 *
 * **Both libraries must come from the same release.** A brep is a Rust
 * structure with no stable layout, so the two layout ids are compared first
 * and anything but an exact match is refused (null, `last_error` set
 * `"from_brep: ..."`, naming both) before `brep` is read. And **both must
 * allocate from the process heap** -- whichever library lets go last frees
 * the brep -- which the shipped libraries do (neither installs a custom Rust
 * `#[global_allocator]`); a build of either that does breaks this.
 *
 * Also refused: a null `brep` or `layout_id`, and a brep with no faces. What
 * a solid from a file can then do depends on its geometry: fillet and chamfer
 * want line and circle edges; booleans take any surface, but the new edges they
 * trace on a free-form (NURBS) face are not always writable back to STEP; and
 * every verb meshes its operands at its tolerance first, so its cost scales
 * with the body's face count.
 *
 * # Safety
 * `brep` null or a live pointer from `cadaclysm_node_brep` not yet released;
 * `layout_id` null or a NUL-terminated string.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_from_brep(const void *brep,
                                                                const char *layout_id);

/**
 * Load a license from `text_or_path`: the certificate text itself, or the
 * path of a file holding it. Replaces the one in use. Null forgets the one in
 * use, so the next call resolves from the environment and the search paths
 * again. Returns false without changing anything when the text does not
 * verify, with the reason at [`cadaclysm_blacksmith_last_error`].
 *
 * # Safety
 * `text_or_path` must be null or a valid null-terminated string.
 */
bool cadaclysm_blacksmith_license_set(const char *text_or_path);

/**
 * The license in use, as one line -- `customer=Acme Ltd expiry=2027-09-15
 * entitlements=import,kernel seats=20` -- or, without one, `unlicensed`
 * (`unlicensed -- <reason>` when a license was found but did not verify).
 * Never null. Borrowed, and good until the next call on this thread.
 */
const char *cadaclysm_blacksmith_license_info(void);

/**
 * How many unlicensed notices this library has printed in this process; an
 * application can show its own banner instead of the stderr line.
 */
uint64_t cadaclysm_blacksmith_license_notice_count(void);

/**
 * The date this library was built, `"YYYY-MM-DD"`. A paid license is good for
 * every build dated on or before the day its updates end. Static; never freed.
 */
const char *cadaclysm_blacksmith_build_date(void);

/**
 * Tessellate at `tolerance` (chordal deviation, in the solid's own units) --
 * or hand back the tessellation already made at exactly this tolerance. The
 * pointers borrow from the solid and stay valid until it is freed or meshed
 * again at a *different* tolerance. Faces are meshed watertight, vertices
 * welded by position. All-null and `last_error` on failure.
 *
 * # Safety
 * `solid` live.
 */
struct CadaclysmBlacksmithMesh cadaclysm_blacksmith_mesh(const struct CadaclysmBlacksmithSolid *solid,
                                                         double tolerance);

/**
 * The triangles each face contributed to the mesh [`cadaclysm_blacksmith_mesh`]
 * gives at the same `tolerance`: one count per face in face order, summing to
 * that mesh's `index_count / 3`. The mesher writes a face's triangles together
 * and the faces in order, so face `f`'s triangles are the `counts[f]` that
 * follow the first `sum(counts[..f])`; a face that meshed to nothing counts
 * zero. What a viewer colours a face by. Same cache and lifetime rule as the
 * mesh. Null `counts` and `last_error` on failure.
 *
 * # Safety
 * `solid` live.
 */
struct CadaclysmBlacksmithFaceTriangles cadaclysm_blacksmith_mesh_face_triangles(const struct CadaclysmBlacksmithSolid *solid,
                                                                                 double tolerance);

/**
 * The feature edges the mesher locked at `tolerance`, as polylines that lie on
 * the mesh [`cadaclysm_blacksmith_mesh`] gives at the same tolerance. Same
 * cache and lifetime rule as the mesh.
 *
 * # Safety
 * `solid` live.
 */
struct CadaclysmBlacksmithPolylines cadaclysm_blacksmith_edge_polylines(const struct CadaclysmBlacksmithSolid *solid,
                                                                        double tolerance);

/**
 * A colour per polyline of [`cadaclysm_blacksmith_edge_polylines`] at the same
 * `tolerance`: `count` equals that call's `polyline_count`, and polyline `i`
 * draws in `rgb[3 * i .. 3 * i + 3]` (`r, g, b` in 0..1, or `-1, -1, -1` for a
 * polyline on no coloured edge). A solid with no edge paint gives `count` 0 and
 * a null `rgb`: nothing to colour, not an error. The same empty struct comes
 * back on a bad tolerance or argument, with `last_error` set -- a caller tells
 * "no paint" from "error" by `last_error`, exactly as it tells an empty
 * [`cadaclysm_blacksmith_edge_polylines`] from a failed one. Same cache and
 * lifetime rule as the mesh.
 *
 * # Safety
 * `solid` live.
 */
struct CadaclysmBlacksmithColours cadaclysm_blacksmith_edge_polyline_colours(const struct CadaclysmBlacksmithSolid *solid,
                                                                             double tolerance);

/**
 * The outline, then each hole, as polylines at z = 0, within `tolerance` of its
 * arcs and splines: a closed loop repeats its first point at the end; an open
 * chain (a profile ended open) is the segments it has. What a viewer draws a
 * profile with. The arrays belong to the profile and stay valid until it is
 * freed or this is called on it again with another tolerance.
 *
 * # Safety
 * `profile` live.
 */
struct CadaclysmBlacksmithPolylines cadaclysm_blacksmith_profile_polylines(const struct CadaclysmBlacksmithProfile *profile,
                                                                           double tolerance);

/**
 * The solid's axis-aligned bounds, over the positions of the solid's cached
 * tessellation at `tolerance` (so curved faces are within that of the truth)
 * -- the same cache [`cadaclysm_blacksmith_mesh`] fills and reuses, so a
 * second call at the same tolerance costs nothing extra. `false` on a null
 * solid or a non-positive, non-finite tolerance.
 *
 * # Safety
 * `solid` live; `min`, `max` three doubles each.
 */
bool cadaclysm_blacksmith_bounds(const struct CadaclysmBlacksmithSolid *solid,
                                 double tolerance,
                                 double *min,
                                 double *max);

/**
 * `count` solids as one STEP part file, each its own `MANIFOLD_SOLID_BREP`,
 * through `cadaclysm_step_ap::write_breps`. `schema` is NULL for the built-in
 * AP203 (`CONFIG_CONTROL_DESIGN`), the name of a built-in schema
 * (`AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF`, …; case-insensitive) --
 * a built-in schema must carry every entity the writer emits, as AP203 and
 * AP242 do and AP214's `AUTOMOTIVE_DESIGN` does not -- or the EXPRESS source
 * text of a custom schema. `unit` 0 = metre, 1 = millimetre, 2 = inch, and
 * says what the solids' lengths are. The text is owned: release it with
 * [`cadaclysm_blacksmith_string_free`]. Null and `last_error` on failure.
 *
 * # Safety
 * `solids` `count` live solids; `schema` NULL or a NUL-terminated string.
 */
char *cadaclysm_blacksmith_step(const struct CadaclysmBlacksmithSolid *const *solids,
                                size_t count,
                                const char *schema,
                                uint32_t unit);

/**
 * `count` solids as one ACIS SAT file, each its own `body`, through
 * `cadaclysm_acis::write_breps`: the analytic surfaces as their own records, spline
 * surfaces (and the swept surfaces SAT has no plain record for) as exact NURBS
 * blobs. `unit` is as for [`cadaclysm_blacksmith_step`] and goes into the header
 * as millimetres per unit. The text is owned: release it with
 * [`cadaclysm_blacksmith_string_free`]. Null and `last_error` on failure.
 *
 * # Safety
 * `solids` `count` live solids.
 */
char *cadaclysm_blacksmith_sat_text(const struct CadaclysmBlacksmithSolid *const *solids,
                                    size_t count,
                                    uint32_t unit);

/**
 * [`cadaclysm_blacksmith_sat_text`] written to `path`, replacing any file there.
 * `false` and `last_error` on failure, including the file's.
 *
 * # Safety
 * `solids` `count` live solids; `path` a NUL-terminated string.
 */
bool cadaclysm_blacksmith_sat(const struct CadaclysmBlacksmithSolid *const *solids,
                              size_t count,
                              const char *path,
                              uint32_t unit);

/**
 * `count` solids as one OCCT `.brep` file, each its own solid under one
 * compound (a single solid is the file's root), through
 * `cadaclysm_brep_file::write_breps`: the exact surfaces and curves, with a curve
 * in each face's own parameters for every edge, so `BRepTools::Read` gives a
 * shape `BRepCheck_Analyzer` finds valid. No unit is declared: a `.brep` carries
 * none, and the numbers written are the numbers held. The text is owned: release
 * it with [`cadaclysm_blacksmith_string_free`]. Null and `last_error` on failure.
 *
 * # Safety
 * `solids` `count` live solids.
 */
char *cadaclysm_blacksmith_brep_text(const struct CadaclysmBlacksmithSolid *const *solids,
                                     size_t count);

/**
 * The defaults: the viewer's `iso`, orthographic, a 1000-square page, black
 * edges one unit wide on nothing.
 *
 * # Safety
 * `options` must be null or writable.
 */
void cadaclysm_blacksmith_svg_options_init(struct CadaclysmBlacksmithSvgOptions *options);

/**
 * [`abi::svg`] of `count` solids: the wireframe as SVG from the camera the
 * options' words describe. The text is owned: release it with
 * [`cadaclysm_blacksmith_string_free`]. Null and `last_error` on failure.
 *
 * # Safety
 * `solids` `count` live solids; `options` a struct filled by
 * [`cadaclysm_blacksmith_svg_options_init`].
 */
char *cadaclysm_blacksmith_svg_text(const struct CadaclysmBlacksmithSolid *const *solids,
                                    size_t count,
                                    const struct CadaclysmBlacksmithSvgOptions *options);

/**
 * [`cadaclysm_blacksmith_brep_text`] written to `path`. False and `last_error`
 * on failure, which includes the file not being writable.
 *
 * # Safety
 * `solids` `count` live solids; `path` a NUL-terminated string.
 */
bool cadaclysm_blacksmith_brep(const struct CadaclysmBlacksmithSolid *const *solids,
                               size_t count,
                               const char *path);

/**
 * [`cadaclysm_blacksmith_svg_text`] written to `path`, replacing any file
 * there. `false` and `last_error` on failure, including the file's.
 *
 * # Safety
 * `solids` `count` live solids; `path` a NUL-terminated string; `options` as
 * `cadaclysm_blacksmith_svg_text`.
 */
bool cadaclysm_blacksmith_svg(const struct CadaclysmBlacksmithSolid *const *solids,
                              size_t count,
                              const char *path,
                              const struct CadaclysmBlacksmithSvgOptions *options);

/**
 * Release a string this library handed over as owned (`cadaclysm_blacksmith_step`,
 * `cadaclysm_blacksmith_sat_text`, `cadaclysm_blacksmith_brep_text`,
 * `cadaclysm_blacksmith_svg_text`).
 * Null is a no-op.
 *
 * # Safety
 * `s` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_string_free(char *s);

/**
 * A rectangle `w` by `h` centred on the origin. Null (and `last_error`) unless
 * both are positive and finite.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_rect(double w, double h);

/**
 * A circle of radius `r` about the origin: two semicircular arcs, so an
 * extrusion of it is two exact cylinder walls.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_circle(double r);

/**
 * A stadium: a `length`-long slot of end radius `r`, centred at (`cx`, `cy`),
 * running along x. `length` must exceed `2 * r`.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_slot(double cx,
                                                                     double cy,
                                                                     double length,
                                                                     double r);

/**
 * A closed polygon through `count` points, `xy` holding two doubles each, in
 * order, with a side back to the first as its last segment. At least three points.
 *
 * # Safety
 * `xy` must point at `2 * count` doubles.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_polygon(const double *xy,
                                                                        size_t count);

/**
 * A regular polygon of `sides` sides (at least 3) on the circle of `radius`
 * about (`cx`, `cy`), its first corner at `angle` radians from the sketch's x
 * axis, the rest counter-clockwise; its side back to the first corner a segment
 * of its own.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_regular_polygon(double cx,
                                                                                double cy,
                                                                                double radius,
                                                                                uint32_t sides,
                                                                                double angle);

/**
 * A spline of `degree` through the control polygon `xy` (`count` points),
 * `weights` null or one per point. Open, it is clamped -- it starts on the
 * first point and ends on the last, an open chain; `closed`, it is periodic,
 * smooth through its own start, a closed profile. The degree is lowered to fit
 * the points. Refused for a degree of zero, too few points (two open, three
 * closed), a point or weight not finite, a weight not positive.
 *
 * # Safety
 * `xy` must point at `2 * count` doubles; `weights` null or `count` doubles.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_spline(const double *xy,
                                                                       size_t count,
                                                                       uint32_t degree,
                                                                       const double *weights,
                                                                       bool closed);

/**
 * `profile` with its corners between two straight segments rounded by
 * `radius`, as a new profile: both lines cut back and an exact tangent arc put
 * between them. `corners` null rounds every such corner, the holes' too;
 * otherwise its `count` indices pick the corners of the boundary to round --
 * corner `k` is where segment `k` ends -- and a picked corner that is not
 * between two lines is refused. `open` treats the profile as an open chain,
 * its two ends kept square; closed, the corner where the last segment meets
 * the first (across the closing side, drawn or implicit) is rounded too.
 * Refused where the radius does not fit.
 *
 * # Safety
 * `profile` a live profile; `corners` null or `count` indices.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_round(const struct CadaclysmBlacksmithProfile *profile,
                                                                      double radius,
                                                                      const uint32_t *corners,
                                                                      size_t count,
                                                                      bool open);

/**
 * `count` open profiles joined end to end into one new profile, the kernel's
 * merge: in any order and either way round, each next piece the first of the
 * rest with an end within `tolerance` of either end of the chain so far,
 * reversed where that makes it meet. Every segment is kept exactly; a joint is
 * the chain's own point. Where the chain's two ends meet within `tolerance`
 * the result is closed (its last segment landing on its start), otherwise an
 * open chain. Refused (null, `last_error` "chain: ...") for no pieces, a
 * tolerance not positive and finite, a piece empty, with holes or closed on
 * its own, or a piece that meets none of the others -- named by its index.
 * The pieces are untouched.
 *
 * # Safety
 * `pieces` `count` live profiles.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_chain(const struct CadaclysmBlacksmithProfile *const *pieces,
                                                                      size_t count,
                                                                      double tolerance);

/**
 * How many pieces `profile` is cut into where the `cutters` (`count` profiles)
 * cross, touch or run along it -- the sketch trim's pieces: 1 where nothing cuts
 * it. `tolerance` is how close two curves must come to meet; cuts closer than it
 * to each other fold onto one. 0 and `last_error` for a null or empty profile.
 * Piece `index` is [`cadaclysm_blacksmith_profile_piece`].
 *
 * # Safety
 * `profile` live; `cutters` null or `count` live profiles.
 */
uint32_t cadaclysm_blacksmith_profile_piece_count(const struct CadaclysmBlacksmithProfile *profile,
                                                  const struct CadaclysmBlacksmithProfile *const *cutters,
                                                  size_t count,
                                                  double tolerance);

/**
 * Piece `index` of `profile` cut by the `cutters` (see
 * [`cadaclysm_blacksmith_profile_piece_count`]) as a new open profile: portions
 * of the profile's own segments -- a line's stretch a line, an arc's an arc, a
 * spline's the same spline over part of its domain -- in order along the curve
 * from its start; a closed curve's piece round its start is one piece. Null
 * and `last_error` for an index past the pieces.
 *
 * # Safety
 * `profile` live; `cutters` null or `count` live profiles.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_piece(const struct CadaclysmBlacksmithProfile *profile,
                                                                      const struct CadaclysmBlacksmithProfile *const *cutters,
                                                                      size_t count,
                                                                      uint32_t index,
                                                                      double tolerance);

/**
 * How many chains `profile` is left in with piece `piece` (of
 * [`cadaclysm_blacksmith_profile_piece_count`]) taken away -- the sketch trim:
 * 1 for a closed curve, 1 or 2 for an open one, 0 where the piece was the whole
 * curve. 0 and `last_error` for a piece the curve does not have -- tell the two
 * apart by `last_error` being set. Chain `index` is
 * [`cadaclysm_blacksmith_profile_trim_chain`].
 *
 * # Safety
 * `profile` live; `cutters` null or `count` live profiles.
 */
uint32_t cadaclysm_blacksmith_profile_trim_count(const struct CadaclysmBlacksmithProfile *profile,
                                                 const struct CadaclysmBlacksmithProfile *const *cutters,
                                                 size_t count,
                                                 uint32_t piece,
                                                 double tolerance);

/**
 * Chain `index` of what is left of `profile` with piece `piece` taken away (see
 * [`cadaclysm_blacksmith_profile_trim_count`]) as a new open profile: a closed
 * curve's one chain starts where the removed piece ended and runs round to where
 * it began; an open curve's are the stretches before and after. Null and
 * `last_error` for an index past the chains.
 *
 * # Safety
 * `profile` live; `cutters` null or `count` live profiles.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_trim_chain(const struct CadaclysmBlacksmithProfile *profile,
                                                                           const struct CadaclysmBlacksmithProfile *const *cutters,
                                                                           size_t count,
                                                                           uint32_t piece,
                                                                           uint32_t index,
                                                                           double tolerance);

/**
 * `loops` (`count` closed profiles, no holes of their own) as one profile:
 * the loop enclosing the most area its boundary, every other a hole in it,
 * in the order given. Refused -- null, with the reason in `last_error`,
 * naming loops by their index -- for a loop that is open, empty or of no area,
 * loops that cross or touch, a hole outside the boundary or inside another.
 *
 * # Safety
 * `loops` `count` live profiles.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_from_loops(const struct CadaclysmBlacksmithProfile *const *loops,
                                                                           size_t count);

/**
 * `profile` closed, as a new profile -- the forge's sketch "close": where its
 * last segment stops short of its start, a straight segment back to it; where it
 * already comes back within 1e-9 of its extent, its last segment made to land on
 * the start exactly. A closed profile comes back as it is. Holes are closed the
 * same way.
 *
 * # Safety
 * `profile` a live profile.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_close_loop(const struct CadaclysmBlacksmithProfile *profile);

/**
 * `profile` coloured (`r`, `g`, `b`), each in 0..1: how its outline is drawn.
 * The verbs that make a profile from one carry it; a solid made from it takes
 * nothing (colour a solid with [`cadaclysm_blacksmith_coloured`]).
 *
 * # Safety
 * `profile` live.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_coloured(const struct CadaclysmBlacksmithProfile *profile,
                                                                         double r,
                                                                         double g,
                                                                         double b);

/**
 * `profile`'s colour as three doubles into `out`. `false` where it has none,
 * and, with `last_error` set, on a null argument.
 *
 * # Safety
 * `profile` live; `out` three doubles.
 */
bool cadaclysm_blacksmith_profile_colour(const struct CadaclysmBlacksmithProfile *profile,
                                         double *out);

/**
 * `outer` with `hole` cut from it, as a new profile; both inputs are untouched.
 * A hole must lie inside the outer boundary and clear of other holes -- this
 * does not check, the sweep that consumes it reports.
 *
 * # Safety
 * Both must be live profiles from this library.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_with_hole(const struct CadaclysmBlacksmithProfile *outer,
                                                                          const struct CadaclysmBlacksmithProfile *hole);

/**
 * Start an outline at (`x`, `y`). Free it with [`cadaclysm_blacksmith_path_free`]
 * if it is never ended.
 */
struct CadaclysmBlacksmithPath *cadaclysm_blacksmith_path_begin(double x, double y);

/**
 * A straight segment to (`x`, `y`).
 *
 * # Safety
 * `p` must be a live path.
 */
bool cadaclysm_blacksmith_path_line_to(struct CadaclysmBlacksmithPath *p, double x, double y);

/**
 * A circular arc to (`x`, `y`) about (`cx`, `cy`), counter-clockwise if `ccw`.
 * The centre must be equidistant from the current point and the end; the
 * sweep that consumes the profile reports one that is not.
 *
 * # Safety
 * `p` must be a live path.
 */
bool cadaclysm_blacksmith_path_arc_to(struct CadaclysmBlacksmithPath *p,
                                      double x,
                                      double y,
                                      double cx,
                                      double cy,
                                      bool ccw);

/**
 * A cubic Bezier to (`x`, `y`) with interior control points `c1` and `c2`; the
 * first control point is the current point.
 *
 * # Safety
 * `p` must be a live path.
 */
bool cadaclysm_blacksmith_path_bezier_to(struct CadaclysmBlacksmithPath *p,
                                         double c1x,
                                         double c1y,
                                         double c2x,
                                         double c2y,
                                         double x,
                                         double y);

/**
 * A NURBS segment. `control_xy` holds every control point **after** the
 * current point, the endpoint last (`control_count` of them, two doubles each);
 * `weights`, if not null, one per control point *including* the current point
 * (`control_count + 1`); `knots` the full repeated knot vector, `knot_count` =
 * `control_count + 1 + degree + 1`. This is `Segment::Nurbs`'s own rule.
 *
 * # Safety
 * `p` must be a live path; the arrays as long as described.
 */
bool cadaclysm_blacksmith_path_nurbs_to(struct CadaclysmBlacksmithPath *p,
                                        const double *control_xy,
                                        size_t control_count,
                                        const double *weights,
                                        const double *knots,
                                        size_t knot_count,
                                        uint32_t degree);

/**
 * Close the path into a profile, consuming the builder (it is invalid after
 * this call whether or not it succeeds). Fails unless the last segment ends at
 * the start point, within 1e-9 of the outline's own extent.
 *
 * # Safety
 * `p` must be a live path; it must not be used or freed afterwards.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_path_end(struct CadaclysmBlacksmithPath *p);

/**
 * The path as it stands, open, as a profile -- consuming the builder as
 * `path_end` does, but without asking the last segment to reach the start.
 * An open sweep (`extrude_open`, `extrude_open_tapered`, `sweep_open`,
 * `loft_open`) draws its segments' walls and nothing across the gap; a closed
 * one closes the gap with a straight side, as it closes every profile.
 *
 * # Safety
 * `p` must be a live path; it must not be used or freed afterwards.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_path_end_open(struct CadaclysmBlacksmithPath *p);

/**
 * Release a path that was never ended. Null is a no-op.
 *
 * # Safety
 * `p` must not have been passed to `path_end`.
 */
void cadaclysm_blacksmith_path_free(struct CadaclysmBlacksmithPath *p);

/**
 * The region `a` and `b` share: zero or more profiles, each outer loop
 * counter-clockwise and each hole clockwise, arcs and splines kept exact. An
 * arc kept from an input can still come out split at that input's own seam
 * point (two circles' lens is four arcs, one pair per circle) -- exact, not
 * an approximation. Two loops of a result may touch at a point (two holes
 * whose corners meet, one from each input): a right point set that the verbs
 * needing simple loops -- extrude, a boolean taking it as an input -- refuse.
 * Both must be closed and simple. Null (and `last_error`) for a null profile,
 * a `tolerance` not positive and finite, an open or self-crossing profile, a
 * `tolerance` too fine for these profiles (following their arcs and splines to
 * a tenth of it would take more than 8 million points, about 128 MB), and, as
 * a defect rather than an outcome, a result that fails to close. No shared
 * area is a list with a count of 0.
 *
 * # Safety
 * `a` and `b` live profiles.
 */
struct CadaclysmBlacksmithProfileList *cadaclysm_blacksmith_profile_common(const struct CadaclysmBlacksmithProfile *a,
                                                                           const struct CadaclysmBlacksmithProfile *b,
                                                                           double tolerance);

/**
 * How many profiles. 0 (and `last_error`) for null.
 *
 * # Safety
 * `list` live.
 */
uint32_t cadaclysm_blacksmith_profile_list_count(const struct CadaclysmBlacksmithProfileList *list);

/**
 * Profile `i`, as a handle of its own: free it with [`cadaclysm_blacksmith_profile_free`].
 * Null (and `last_error`) when `i` is out of range.
 *
 * # Safety
 * `list` live.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_list_get(const struct CadaclysmBlacksmithProfileList *list,
                                                                         uint32_t i);

/**
 * Release a list. Null is a no-op. Profiles taken from it with
 * `profile_list_get` are independent and outlive it.
 *
 * # Safety
 * `list` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_profile_list_free(struct CadaclysmBlacksmithProfileList *list);

/**
 * Faces in the solid's own order; indices into this are what
 * [`cadaclysm_blacksmith_select_face`] returns and `shell` takes.
 *
 * # Safety
 * `solid` live.
 */
uint32_t cadaclysm_blacksmith_face_count(const struct CadaclysmBlacksmithSolid *solid);

/**
 * The face a selector picks, or `CADACLYSM_BLACKSMITH_NONE` (and `last_error`)
 * if none does. `kind` 0 = the face furthest along axis `index` (0 x, 1 y, 2 z);
 * 1 = furthest against it; 2 = the face whose outward normal is nearest the
 * direction in `v` (three doubles, need not be unit); 3 = the face at `index`.
 * `v` is read only for kind 2, `index` only for kinds 0, 1 and 3.
 *
 * # Safety
 * `solid` live; `v` three doubles when `kind` is 2.
 */
uint32_t cadaclysm_blacksmith_select_face(const struct CadaclysmBlacksmithSolid *solid,
                                          uint32_t kind,
                                          const double *v,
                                          uint32_t index);

/**
 * The workplane on a face, twelve doubles into `out`: origin at the face's
 * boundary centroid, z its outward normal, x world X laid onto the face
 * (world Y on a face facing close to X) -- what `Workplane::workplane`
 * adopts. `false` if the face's boundary or normal cannot be read.
 *
 * # Safety
 * `solid` live; `out` twelve doubles.
 */
bool cadaclysm_blacksmith_face_frame(const struct CadaclysmBlacksmithSolid *solid,
                                     uint32_t face,
                                     double *out);

/**
 * Face `face` by what it is, eight doubles into `out`: the surface's kind (plane 0,
 * cylinder 1, cone 2, sphere 3, torus 4, NURBS 5, revolution 6, extrusion 7, sum 8),
 * a point on the surface at the face's middle (x y z), the outward normal there
 * (x y z), and the face's extent -- a reference a feature made on the face keeps, to
 * find the face again with [`cadaclysm_blacksmith_find_face`] when the solid has
 * been rebuilt with its faces moved, split or renumbered. Take it off the solid
 * before any move you apply to it, and look it up on the unmoved one. `false` and
 * `last_error` for a face the solid does not have, or with nothing to read.
 *
 * # Safety
 * `solid` live; `out` eight doubles.
 */
bool cadaclysm_blacksmith_face_ref(const struct CadaclysmBlacksmithSolid *solid,
                                   uint32_t face,
                                   double *out);

/**
 * The face of `solid` that `face_ref` (eight doubles, as
 * [`cadaclysm_blacksmith_face_ref`] lays them out) refers to: among the faces of that
 * kind whose surface passes through the point, facing the same way, the one the
 * point lies in -- or, where it lies in none (the face shrank away, a hole opened
 * under it), the one whose boundary comes nearest. `hint` is the index the face had,
 * preferred among faces that fit equally well (negative for none); `tolerance` how
 * far the point may sit off a surface to still be on it. -1 where the face is gone
 * (no `last_error`); -2 and `last_error` for a null solid or a malformed reference.
 *
 * # Safety
 * `solid` live; `face_ref` eight doubles.
 */
int32_t cadaclysm_blacksmith_find_face(const struct CadaclysmBlacksmithSolid *solid,
                                       const double *face_ref,
                                       int32_t hint,
                                       double tolerance);

/**
 * The solid's colour, or with `face` not `CADACLYSM_BLACKSMITH_NONE` that
 * face's as drawn (its own, else the solid's), as three doubles into `out`.
 * `false` where there is none -- and, with `last_error` set, on a bad face or
 * a null argument.
 *
 * # Safety
 * `solid` live; `out` three doubles.
 */
bool cadaclysm_blacksmith_colour(const struct CadaclysmBlacksmithSolid *solid,
                                 uint32_t face,
                                 double *out);

/**
 * Edge `edge`'s colour as drawn -- its own, else the solid's edge colour -- as
 * three doubles into `out`. `false` where there is none, and, with `last_error`
 * set, on a bad edge or a null argument.
 *
 * # Safety
 * `solid` live; `out` three doubles.
 */
bool cadaclysm_blacksmith_edge_colour(const struct CadaclysmBlacksmithSolid *solid,
                                      uint32_t edge,
                                      double *out);

/**
 * The face's surface kind: "plane", "cylinder", "cone", "sphere", "torus",
 * "nurbs", "revolution", "extrusion", "other", or "none" for a face without a
 * surface. Static; never freed. Null (and `last_error`) for a face out of range.
 *
 * # Safety
 * `solid` live.
 */
const char *cadaclysm_blacksmith_face_kind(const struct CadaclysmBlacksmithSolid *solid,
                                           uint32_t face);

/**
 * Edges in a stable order (by each edge's first trim), computed on first ask.
 * An index into this list is what `cadaclysm_blacksmith_fillet` takes. Edges
 * without an exact curve -- a boolean's edge on surfaces the intersection
 * module does not know -- are not listed.
 *
 * # Safety
 * `solid` live.
 */
uint32_t cadaclysm_blacksmith_edge_count(const struct CadaclysmBlacksmithSolid *solid);

/**
 * Edge `i` into `out`. `false` (and `last_error`) if `i` is out of range.
 *
 * # Safety
 * `solid` live; `out` a valid struct.
 */
bool cadaclysm_blacksmith_edge(const struct CadaclysmBlacksmithSolid *solid,
                               uint32_t i,
                               struct CadaclysmBlacksmithEdge *out);

/**
 * Edge `i`'s exact curve, borrowed from the solid: valid until it is freed
 * (the solid caches its curve table on first ask, like [`CadaclysmBlacksmithEdge`]
 * does its own table).
 *
 * The range convention: `t0..t1` is the edge's parameter range on its own
 * curve -- a line's fraction (`0..1` over `origin -> origin + x`, where `x`
 * is the full `to - from`, NOT unit, so `point(t) = origin + x*t`); a
 * circle's or ellipse's angle in radians about `origin` in the `x, y` plane
 * (`point(t) = origin + x*radius*cos(t) + y*radius2*sin(t)`, `radius2 ==
 * radius` for a circle); a NURBS's knot parameter (`knots[degree] <= t0 < t1
 * <= knots[n]`). Frame vectors `x, y, z` are unit for a conic; for a line
 * `x` is the direction with length equal to the line's own length and `y, z`
 * are zero. Always `t0 < t1`: an edge whose segments run against its curve's
 * own parameter reports the same range -- read the direction from the
 * edge's `segments`, not from the range.
 *
 * `kind` is one of "line", "circle", "ellipse" or "nurbs" -- static, never
 * freed. For a conic or a line `degree` is 0 and `knots`, `poles`, `weights`
 * are null with zero counts; for a NURBS `origin, x, y, z` are zero and
 * `radius, radius2` are 0. `poles` is three doubles per control point;
 * `weights` is null for a non-rational (plain B-spline) curve, otherwise one
 * weight per pole.
 *
 * `false` (and `last_error`) for a null `solid`, a null `out`, `i` out of
 * range, or an edge whose kind is "other" (no exact curve).
 *
 * # Safety
 * `solid` live; `out` a valid struct.
 */
bool cadaclysm_blacksmith_edge_curve(const struct CadaclysmBlacksmithSolid *solid,
                                     uint32_t i,
                                     struct CadaclysmBlacksmithCurve *out);

/**
 * How many edges of a fresh mesh of the solid at `tolerance` are bound by
 * anything other than exactly two triangles -- zero for a closed solid. Meshes
 * at full double precision every call ([`bs::leaked_edges`]) rather than
 * reusing [`cadaclysm_blacksmith_mesh`]'s cache: that cache is stored as `f32`
 * for a renderer's sake, and `f32`'s precision falls off with a coordinate's
 * own magnitude -- a solid modelled a long way from the origin can drop enough
 * precision in the cache to weld (or fail to weld) a shared edge wrongly, which
 * this check exists to catch, not to repeat. A seam two solids share along a
 * line -- four triangles meeting on it, two running each way -- pairs off and
 * does *not* count here; a genuine hole (one triangle) or a fold (two running
 * the same way) does. `CADACLYSM_BLACKSMITH_NONE` (and `last_error`) on a null
 * solid or a non-positive, non-finite tolerance.
 *
 * # Safety
 * `solid` live.
 */
uint32_t cadaclysm_blacksmith_leaked_edges(const struct CadaclysmBlacksmithSolid *solid,
                                           double tolerance);

/**
 * How many edges of a fresh mesh of the solid at `tolerance` have directed
 * triangle uses that do not pair off -- zero for a closed, consistently
 * oriented solid. Where [`cadaclysm_blacksmith_leaked_edges`] asks for exactly
 * two triangles on an edge, this asks that they run opposite ways and cancel:
 * the seam two solids share along a line pairs off (two triangles each way)
 * and is *not* counted here even though four triangles meet there, while a
 * fold -- two triangles running the same way -- is. The question a boolean's
 * operands must answer, since inside and outside are as well defined either
 * side of such a seam as of any other edge. Meshes at full double precision
 * every call, for the same reason [`cadaclysm_blacksmith_leaked_edges`] does
 * rather than reading the `f32` render cache. Same failure shape as
 * [`cadaclysm_blacksmith_leaked_edges`].
 *
 * # Safety
 * `solid` live.
 */
uint32_t cadaclysm_blacksmith_unpaired_edges(const struct CadaclysmBlacksmithSolid *solid,
                                             double tolerance);

/**
 * Whether the solid's faces make a manifold, read off its topology -- the edges
 * and loops it is made of -- rather than a mesh: nothing is tessellated, so it
 * takes no tolerance. Eight counts into `out`, in order: faces, edges,
 * vertices, boundary edges (bordered by one face), non-manifold edges (by
 * three or more), non-manifold vertices (where the faces round a point make
 * more than one fan: two solids touching at a corner), then `1` if it is a
 * manifold (no non-manifold edge or vertex) and `1` if it is also closed (no
 * boundary edge: it encloses a solid), else `0`. A sheet is a manifold that is
 * not closed.
 *
 * Orientation is not asked -- whether the faces all face out is
 * [`cadaclysm_blacksmith_unpaired_edges`]'s question, on a mesh. `false` (and
 * `last_error`) on a null argument.
 *
 * # Safety
 * `solid` live; `out` eight `uint32_t`.
 */
bool cadaclysm_blacksmith_manifold(const struct CadaclysmBlacksmithSolid *solid, uint32_t *out);

/**
 * A box `x` by `y` by `z`, centred on the origin. Six planes.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_cuboid(double x, double y, double z);

/**
 * A cylinder of radius `r`, height `h`, based on z=0 and rising along +z.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_cylinder(double r, double h);

/**
 * A cone of base radius `r` and height `h`, apex up.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_cone(double r, double h);

/**
 * A sphere of radius `r` about the origin.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sphere(double r);

/**
 * A torus of ring radius `major` and tube radius `minor`, about z.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_torus(double major, double minor);

/**
 * A wedge: a box `x` by `y` by `z` whose top face is narrowed to `top_x` along x.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_wedge(double x,
                                                            double y,
                                                            double z,
                                                            double top_x);

/**
 * `profile` swept `height` along the frame's z, closed with two caps. The
 * profile's own x/y are the frame's x/y.
 *
 * # Safety
 * `profile` a live profile; `frame` twelve doubles.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_extrude(const struct CadaclysmBlacksmithProfile *profile,
                                                              const double *frame,
                                                              double height);

/**
 * [`cadaclysm_blacksmith_extrude`] without the caps: an open sheet of walls.
 *
 * # Safety
 * As `extrude`.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_extrude_open(const struct CadaclysmBlacksmithProfile *profile,
                                                                   const double *frame,
                                                                   double height);

/**
 * [`cadaclysm_blacksmith_extrude`] between two planes instead of two heights:
 * `bottom` and `top` are each three doubles -- `at`, `grad.x`, `grad.y` -- a
 * plane read as its height over the sketch plane at each point,
 * `at + grad · p`. The profile's walls run from where `bottom` cuts them to
 * where `top` does, the caps lying on those planes. With both flat this *is*
 * `cadaclysm_blacksmith_extrude` (bit for bit: a flat slant's height is its
 * `at`); with a slope it is the mitred end of a sweep's straight piece.
 * [`cadaclysm_blacksmith_slant_of_plane`] builds a slant from a plane
 * through a point.
 *
 * Refused (null, `last_error` set `"extrude_between: ..."`) where the top
 * plane comes down to or through the bottom across the profile -- a mitre
 * too sharp for the profile's width -- besides `extrude`'s own refusals.
 *
 * # Safety
 * `profile` a live profile; `frame` twelve doubles; `bottom`, `top` three
 * doubles each.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_extrude_between(const struct CadaclysmBlacksmithProfile *profile,
                                                                      const double *frame,
                                                                      const double *bottom,
                                                                      const double *top);

/**
 * [`cadaclysm_blacksmith_extrude_between`] without the caps: an open sheet of
 * walls running from `bottom` to `top`, as [`cadaclysm_blacksmith_extrude_open`]
 * is to [`cadaclysm_blacksmith_extrude`]. The same refusals.
 *
 * # Safety
 * As `extrude_between`.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_extrude_open_between(const struct CadaclysmBlacksmithProfile *profile,
                                                                           const double *frame,
                                                                           const double *bottom,
                                                                           const double *top);

/**
 * The plane midway between the planes of frames `a` and `b` (twelve doubles each),
 * twelve doubles into `out` -- Fusion's midplane: for parallel planes the one halfway
 * between, on `a`'s axes; for planes that meet, the plane bisecting them through the
 * line they meet on, its x along that line. `false` and `last_error` for a frame with
 * no normal.
 *
 * # Safety
 * `a`, `b` twelve doubles each; `out` twelve writable doubles.
 */
bool cadaclysm_blacksmith_frame_midplane(const double *a, const double *b, double *out);

/**
 * The plane through the points `p`, `q` and `r` (three doubles each), twelve doubles
 * into `out`: its origin `p`, its x towards `q`, its z the normal the three turn
 * about counter-clockwise -- Fusion's plane through three points. `false` and
 * `last_error` for three points on one line.
 *
 * # Safety
 * `p`, `q`, `r` three doubles each; `out` twelve writable doubles.
 */
bool cadaclysm_blacksmith_frame_through(const double *p,
                                        const double *q,
                                        const double *r,
                                        double *out);

/**
 * The plane through `point` square to `normal`, read as heights over
 * `frame` and written to `out` (`at`, `grad.x`, `grad.y`, for
 * [`cadaclysm_blacksmith_extrude_between`]). `false`, with `last_error` set,
 * when the plane holds the sweep direction itself -- `normal` square to
 * `frame`'s z -- so no height is on it.
 *
 * # Safety
 * `frame` twelve doubles; `point`, `normal` three doubles each; `out` three
 * writable doubles.
 */
bool cadaclysm_blacksmith_slant_of_plane(const double *frame,
                                         const double *point,
                                         const double *normal,
                                         double *out);

/**
 * [`cadaclysm_blacksmith_extrude`] with a draft: the walls lean out by `taper`
 * radians as they rise (in, when negative -- the profile is walked
 * counter-clockwise, and a positive taper leans to the right of that walk),
 * every wall exact -- a plane off a line, a cone off an arc. A taper of zero is
 * `extrude` itself; one that would close a side before the top is refused.
 *
 * # Safety
 * As `extrude`.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_extrude_tapered(const struct CadaclysmBlacksmithProfile *profile,
                                                                      const double *frame,
                                                                      double height,
                                                                      double taper);

/**
 * [`cadaclysm_blacksmith_extrude_tapered`] without the caps: the drafted walls
 * alone, leaning to the right of the curve's walk.
 *
 * # Safety
 * As `extrude`.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_extrude_open_tapered(const struct CadaclysmBlacksmithProfile *profile,
                                                                           const double *frame,
                                                                           double height,
                                                                           double taper);

/**
 * The solid between profile `a` drawn on `frame_a` and profile `b` drawn on
 * `frame_b`: ruled walls between matching sides, capped by the two profiles.
 * The profiles must have the same number of sides and no holes; `b` is turned
 * to start from the side nearest `a`'s first.
 *
 * # Safety
 * `a`, `b` live profiles; `frame_a`, `frame_b` twelve doubles each.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_loft(const struct CadaclysmBlacksmithProfile *a,
                                                           const double *frame_a,
                                                           const struct CadaclysmBlacksmithProfile *b,
                                                           const double *frame_b);

/**
 * [`cadaclysm_blacksmith_loft`] without the caps: the sheet ruled between the
 * two curves.
 *
 * # Safety
 * As `loft`.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_loft_open(const struct CadaclysmBlacksmithProfile *a,
                                                                const double *frame_a,
                                                                const struct CadaclysmBlacksmithProfile *b,
                                                                const double *frame_b);

/**
 * The solid smooth through `count` profiles, each on its frame (`frames` twelve
 * doubles a profile, in order): every wall interpolates its side across all the
 * profiles -- cubic through four or more, quadratic through three, the ruled
 * [`cadaclysm_blacksmith_loft`] through two -- capped by the first and the last. The
 * profiles must have the same number of sides and no holes.
 *
 * # Safety
 * `profiles` `count` live profiles; `frames` `12 * count` doubles.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_loft_through(const struct CadaclysmBlacksmithProfile *const *profiles,
                                                                   const double *frames,
                                                                   size_t count);

/**
 * [`cadaclysm_blacksmith_loft_through`] without the caps: the sheet through the curves.
 *
 * # Safety
 * As `loft_through`.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_loft_through_open(const struct CadaclysmBlacksmithProfile *const *profiles,
                                                                        const double *frames,
                                                                        size_t count);

/**
 * `profile` swung `angle` radians about `axis` (a point and a direction). The
 * profile is read with x as radius and y as height along the axis, so it must
 * lie to one side of the axis.
 *
 * # Safety
 * `profile` a live profile; `axis` six doubles.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_revolve(const struct CadaclysmBlacksmithProfile *profile,
                                                              const double *axis,
                                                              double angle);

/**
 * `profile` coiled about `axis` (a point and a direction): read like
 * [`cadaclysm_blacksmith_revolve`]'s -- x the distance from the axis, y along it --
 * and turned `turns` times while climbing `pitch` along the axis each turn, a
 * spring or a thread. The walls follow the helix to a few millionths of the
 * radius; the two ends are the profile itself, flat. Null and `last_error` for an
 * open profile or one with holes, one reaching the axis, turns that are not
 * positive, or -- from a full turn up -- a pitch no taller than the profile.
 *
 * # Safety
 * `profile` a live profile; `axis` six doubles.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_coil(const struct CadaclysmBlacksmithProfile *profile,
                                                           const double *axis,
                                                           double pitch,
                                                           double turns);

/**
 * [`cadaclysm_blacksmith_revolve`] without the end caps of a partial turn.
 *
 * # Safety
 * As `revolve`.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_revolve_open(const struct CadaclysmBlacksmithProfile *profile,
                                                                   const double *axis,
                                                                   double angle);

/**
 * `profile`, drawn on `frame`, swung `angle` radians about the axis through
 * the sketch points (`axis[0]`, `axis[1]`) and (`axis[2]`, `axis[3]`), in the
 * frame's own x and y, into a closed solid -- the profile and its axis drawn
 * together, as a sketch draws them, rather than the profile in (radius,
 * height) as `cadaclysm_blacksmith_revolve` reads it. The profile may lie on
 * either side of the axis and touch it, not cross it; the sweep starts where
 * the profile is drawn, turning right-handed about the axis.
 *
 * # Safety
 * `profile` a live profile; `frame` twelve doubles; `axis` four.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_revolve_in_plane(const struct CadaclysmBlacksmithProfile *profile,
                                                                       const double *frame,
                                                                       const double *axis,
                                                                       double angle);

/**
 * As `revolve_in_plane`, for a curve: the profile's own segments swung into a
 * sheet, no caps.
 *
 * # Safety
 * As `revolve_in_plane`.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_revolve_open_in_plane(const struct CadaclysmBlacksmithProfile *profile,
                                                                            const double *frame,
                                                                            const double *axis,
                                                                            double angle);

/**
 * Every face of `sheet` pushed `height` along its own normal, walled and
 * closed: the sheet as a solid of that thickness.
 *
 * # Safety
 * `sheet` a live solid.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_extrude_faces(const struct CadaclysmBlacksmithSolid *sheet,
                                                                    double height);

/**
 * The planar sheet `profile` bounds on `frame` (twelve doubles: origin, x, y,
 * z): one face on the plane of `frame`, its normal `frame`'s z whichever way
 * round the profile was drawn, each hole a hole through it, every edge the
 * exact line, arc or spline its segment is. An open sheet: raise it with
 * [`cadaclysm_blacksmith_extrude_faces`], trim it with
 * [`cadaclysm_blacksmith_trim`]. Refused where the profile encloses no area or
 * a hole does not lie inside the boundary.
 *
 * # Safety
 * `profile` a live profile; `frame` twelve doubles.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_face(const struct CadaclysmBlacksmithProfile *profile,
                                                           const double *frame);

/**
 * Face `face` of `solid` (an index below [`cadaclysm_blacksmith_face_count`])
 * alone, as an open sheet: its surface, its loops and the exact curves its
 * edges carry, the rest of the solid left behind. What extruding a solid's
 * face starts from.
 *
 * # Safety
 * `solid` a live solid.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_face_sheet(const struct CadaclysmBlacksmithSolid *solid,
                                                                 uint32_t face);

/**
 * `solid` without the faces at `faces` (`count` indices; repeats allowed): the
 * rest keep their surfaces, loops and curves, in their order, so an index into
 * the result is the input's with the dropped ones closed up. Refused for an
 * index the solid has no face at, or where nothing would be left.
 *
 * # Safety
 * `solid` a live solid; `faces` `count` indices.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_drop_faces(const struct CadaclysmBlacksmithSolid *solid,
                                                                 const uint32_t *faces,
                                                                 size_t count);

/**
 * `solid`, built about the origin, moved onto `frame`: its origin to the
 * frame's origin, its axes to the frame's. What `Workplane::cuboid` and
 * `::cylinder` do after building the primitive.
 *
 * # Safety
 * `solid` a live solid; `frame` twelve doubles.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_place(const struct CadaclysmBlacksmithSolid *solid,
                                                            const double *frame);

/**
 * `profile` shifted by (`dx`, `dy`) in its own plane -- to push a revolve's
 * profile off the axis, or a hole off centre.
 *
 * # Safety
 * `profile` a live profile.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_translate_profile(const struct CadaclysmBlacksmithProfile *profile,
                                                                          double dx,
                                                                          double dy);

/**
 * `solid` moved by (`dx`, `dy`, `dz`).
 *
 * # Safety
 * `solid` a live solid.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_translate(const struct CadaclysmBlacksmithSolid *solid,
                                                                double dx,
                                                                double dy,
                                                                double dz);

/**
 * `solid` turned `radians` about `axis` (a point and a direction).
 *
 * # Safety
 * `solid` a live solid; `axis` six doubles.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_rotate(const struct CadaclysmBlacksmithSolid *solid,
                                                             const double *axis,
                                                             double radians);

/**
 * `solid` reflected across `plane` (a frame; its z is the plane's normal).
 *
 * # Safety
 * `solid` a live solid; `plane` twelve doubles.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_mirror(const struct CadaclysmBlacksmithSolid *solid,
                                                             const double *plane);

/**
 * `solid` coloured (`r`, `g`, `b`), each in 0..1: the whole solid, or with
 * `face` not `CADACLYSM_BLACKSMITH_NONE` just that face, whose colour then wins
 * over the solid's. What is made from a coloured solid inherits: a rigid move
 * keeps every colour, and a boolean, fillet, chamfer or shell gives each face
 * the colour of the input face it lies on -- a cut's bore the tool's -- and a
 * new face (a round, a shell's inner wall) the solid's.
 *
 * # Safety
 * `solid` a live solid.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_coloured(const struct CadaclysmBlacksmithSolid *solid,
                                                               uint32_t face,
                                                               double r,
                                                               double g,
                                                               double b);

/**
 * `solid` with its edges coloured (`r`, `g`, `b`), each in 0..1: every edge when
 * `edges` is null, else the `count` edges listed (the indices
 * [`cadaclysm_blacksmith_edge`] and [`cadaclysm_blacksmith_fillet`] use), whose
 * colour then wins over the all-edges one. Null and empty differ: a null `edges`
 * colours every edge, a non-null `edges` with `count` 0 colours none (the list
 * is read as `fillet` reads its own), so a wrapper keeps "none" and "empty"
 * distinct. A rigid move keeps every edge colour;
 * a boolean, fillet, chamfer or shell gives each edge the colour of the input
 * edge it lies on, and a new edge (a cut's rim, a round's edges) the all-edges
 * colour. Read back with [`cadaclysm_blacksmith_edge_colour`].
 *
 * # Safety
 * `solid` a live solid; `edges` null or `count` indices.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_edges_coloured(const struct CadaclysmBlacksmithSolid *solid,
                                                                     const uint32_t *edges,
                                                                     size_t count,
                                                                     double r,
                                                                     double g,
                                                                     double b);

/**
 * `a ∪ b`, an exact B-rep whose faces are pieces of the inputs' own faces; only
 * the new edges, where the two meet, are found on the meshes at `tolerance`.
 *
 * # Safety
 * `a`, `b` live solids; `progress` null or a valid callback.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_join(const struct CadaclysmBlacksmithSolid *a,
                                                           const struct CadaclysmBlacksmithSolid *b,
                                                           double tolerance,
                                                           CadaclysmBlacksmithProgress progress,
                                                           void *user);

/**
 * `a − b`. See [`cadaclysm_blacksmith_join`].
 *
 * # Safety
 * As `join`.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_cut(const struct CadaclysmBlacksmithSolid *a,
                                                          const struct CadaclysmBlacksmithSolid *b,
                                                          double tolerance,
                                                          CadaclysmBlacksmithProgress progress,
                                                          void *user);

/**
 * `a ∩ b`. See [`cadaclysm_blacksmith_join`].
 *
 * # Safety
 * As `join`.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_common(const struct CadaclysmBlacksmithSolid *a,
                                                             const struct CadaclysmBlacksmithSolid *b,
                                                             double tolerance,
                                                             CadaclysmBlacksmithProgress progress,
                                                             void *user);

/**
 * `sheet` cut along `tool`'s boundary and nothing removed: every face of
 * `sheet` comes back in its pieces outside `tool` and its pieces inside,
 * each piece a face. The faces come out in `sheet`'s own face order, each
 * face's outside pieces before its inside pieces, so an index into the
 * result names a piece for as long as `sheet` and `tool` stand. `sheet` may
 * be an open sheet; `tool` must be a closed solid. What a surface trim
 * starts from -- the pieces to throw away are chosen afterwards.
 *
 * # Safety
 * `sheet`, `tool` live solids; `progress` null or a valid callback.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_split_sheet(const struct CadaclysmBlacksmithSolid *sheet,
                                                                  const struct CadaclysmBlacksmithSolid *tool,
                                                                  double tolerance,
                                                                  CadaclysmBlacksmithProgress progress,
                                                                  void *user);

/**
 * `sheet` cut along the closed `tool`'s boundary and the pieces on one side
 * thrown away -- [`cadaclysm_blacksmith_split_sheet`] and
 * [`cadaclysm_blacksmith_drop_faces`] in one: `keep_inside` false keeps what
 * lies outside the tool (a hole punched through the sheet), true what lies
 * inside it (the sheet cut to the tool's outline). The kept pieces come out in
 * `sheet`'s face order. Refused where nothing lies on the kept side, and as
 * the split refuses.
 *
 * # Safety
 * `sheet`, `tool` live solids; `progress` null or a valid callback.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_trim(const struct CadaclysmBlacksmithSolid *sheet,
                                                           const struct CadaclysmBlacksmithSolid *tool,
                                                           bool keep_inside,
                                                           double tolerance,
                                                           CadaclysmBlacksmithProgress progress,
                                                           void *user);

/**
 * `solid` with the edges at `edges` (indices into the list
 * [`cadaclysm_blacksmith_edge`] walks) rounded to `radius`.
 *
 * # Safety
 * `solid` live; `edges` `count` indices; `progress` null or valid.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_fillet(const struct CadaclysmBlacksmithSolid *solid,
                                                             const uint32_t *edges,
                                                             size_t count,
                                                             double radius,
                                                             double tolerance,
                                                             CadaclysmBlacksmithProgress progress,
                                                             void *user);

/**
 * [`cadaclysm_blacksmith_fillet`] with a flat bevel instead of a ball: every
 * picked edge cut back by `distance` along both its faces, the cut a plane (a
 * cone round a circular edge). The same edges, the same refusals.
 *
 * # Safety
 * `solid` live; `edges` `count` indices.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_chamfer(const struct CadaclysmBlacksmithSolid *solid,
                                                              const uint32_t *edges,
                                                              size_t count,
                                                              double distance,
                                                              double tolerance);

/**
 * `solid` with the round face `face` belongs to made again at `radius` -- the
 * fillet's bands, balls and rim bands joined to that face taken back to the sharp
 * edges they replaced and those rounded again, as Fusion's press-pull on a fillet
 * face. Null and `last_error` for a face that is not a round of straight edges
 * between planes or of circular rims, or a radius that does not fit.
 *
 * # Safety
 * `solid` live.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_refillet(const struct CadaclysmBlacksmithSolid *solid,
                                                               uint32_t face,
                                                               double radius,
                                                               double tolerance);

/**
 * `solid` with the round face `face` belongs to taken off, the faces beside it made
 * sharp again -- Fusion's delete of a fillet face. The same refusals as
 * [`cadaclysm_blacksmith_refillet`].
 *
 * # Safety
 * `solid` live.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_unfillet(const struct CadaclysmBlacksmithSolid *solid,
                                                               uint32_t face);

/**
 * `solid` with the chamfer face `face` belongs to cut again at `distance` -- its
 * bevels (flat between two planes, cones round rims) and the corner triangles joined
 * to that face taken back to the sharp edges they cut and those bevelled again, as
 * Fusion's press-pull on a chamfer face. Null and `last_error` for a face that is not
 * a chamfer's bevel, or a distance that does not fit.
 *
 * # Safety
 * `solid` live.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_rechamfer(const struct CadaclysmBlacksmithSolid *solid,
                                                                uint32_t face,
                                                                double distance,
                                                                double tolerance);

/**
 * `solid` with the chamfer face `face` belongs to taken off, the faces beside it
 * made sharp again. The same refusals as [`cadaclysm_blacksmith_rechamfer`].
 *
 * # Safety
 * `solid` live.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_unchamfer(const struct CadaclysmBlacksmithSolid *solid,
                                                                uint32_t face);

/**
 * Face `face` of `solid` pushed out by `distance` along its outward normal (pulled
 * in, negative) the way a CAD program extrudes a face: the prism over it joined on
 * (cut out) at `tolerance`, and the result's flush faces merged -- a box's top
 * raised is one taller box of six faces. A face on a cylinder, a cone, a sphere or a
 * torus moves out along its normal instead, the surface a step out (a boss fatter, a
 * bore or a countersink narrower, a dome fuller), the planes beside it carried along.
 * Null and `last_error` for any other curved face, a curved one with anything but a
 * plane it can follow beside it, reaching a cone's apex, pushed to its axis or centre,
 * off a plane beside it or into another edge, a face the solid does not have, a zero
 * or non-finite distance, or what the boolean refuses.
 *
 * # Safety
 * `solid` live; `progress` null or valid.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_push_pull(const struct CadaclysmBlacksmithSolid *solid,
                                                                uint32_t face,
                                                                double distance,
                                                                double tolerance,
                                                                CadaclysmBlacksmithProgress progress,
                                                                void *user);

/**
 * `solid` with the `count` faces at `faces` pushed out by `distance` together (pulled
 * in, negative) -- Fusion's press-pull on a selection: each face by
 * [`cadaclysm_blacksmith_push_pull`]'s rule for it, one after another in the order
 * given, each found again by a point inside it after the pushes before it renumbered the
 * faces. A box's top and a side pushed 5 is the box 5 taller and 5 wider. A face on the
 * same curved surface as one before it, and joined to it, moved with that one and is
 * not pushed twice. Null and `last_error` for no faces, a face an earlier push took
 * away, and whatever [`cadaclysm_blacksmith_push_pull`] refuses of a face.
 *
 * # Safety
 * `solid` live; `faces` `count` indices; `progress` null or valid.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_push_pull_faces(const struct CadaclysmBlacksmithSolid *solid,
                                                                      const uint32_t *faces,
                                                                      size_t count,
                                                                      double distance,
                                                                      double tolerance,
                                                                      CadaclysmBlacksmithProgress progress,
                                                                      void *user);

/**
 * `solid` split by `tool` into bodies -- Fusion's Split Body. A closed `tool`
 * gives the part outside it, then the part inside; a flat sheet splits by the
 * whole plane it lies on. Every connected part is a body, and the bodies come
 * back side by side in one solid: take them apart with
 * [`cadaclysm_blacksmith_lump_count`] and [`cadaclysm_blacksmith_lump`]. Null and
 * `last_error` for a tool that does not cross the solid, or a curved sheet.
 *
 * # Safety
 * `solid`, `tool` live; `progress` null or valid.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_split(const struct CadaclysmBlacksmithSolid *solid,
                                                            const struct CadaclysmBlacksmithSolid *tool,
                                                            double tolerance,
                                                            CadaclysmBlacksmithProgress progress,
                                                            void *user);

/**
 * `solid` split by the plane through `plane`'s origin square to its z (a frame,
 * twelve doubles): the bodies in front of it, then those behind, side by side in
 * one solid -- see [`cadaclysm_blacksmith_split`].
 *
 * # Safety
 * `solid` live; `plane` twelve doubles; `progress` null or valid.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_split_by_plane(const struct CadaclysmBlacksmithSolid *solid,
                                                                     const double *plane,
                                                                     double tolerance,
                                                                     CadaclysmBlacksmithProgress progress,
                                                                     void *user);

/**
 * How many connected bodies `solid` is -- faces sharing an edge are one body. A
 * split's result is several; a boolean's can be. 0 and `last_error` for a null
 * solid.
 *
 * # Safety
 * `solid` live.
 */
uint32_t cadaclysm_blacksmith_lump_count(const struct CadaclysmBlacksmithSolid *solid);

/**
 * Body `index` of `solid` (see [`cadaclysm_blacksmith_lump_count`]) as a solid of
 * its own, its faces in `solid`'s order and colours. Null and `last_error` for an
 * index the solid has no body at.
 *
 * # Safety
 * `solid` live.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_lump(const struct CadaclysmBlacksmithSolid *solid,
                                                           uint32_t index);

/**
 * `solid` with its flush faces merged, as a new solid: planar faces on one plane,
 * facing one way and meeting along their edges, made one face, and every vertex
 * left in the middle of a straight edge taken out -- the seams a join leaves where
 * two parts are flush. A solid with nothing to merge comes back as it was.
 *
 * # Safety
 * `solid` live.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_merge_flush(const struct CadaclysmBlacksmithSolid *solid);

/**
 * `solid` hollowed to a wall `thickness` thick (inward for a positive
 * thickness, outward -- the solid becoming the cavity -- for a negative one),
 * with the faces at `open_faces` removed so the hollow is reachable.
 *
 * # Safety
 * `solid` live; `open_faces` `count` indices; `progress` null or valid.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_shell(const struct CadaclysmBlacksmithSolid *solid,
                                                            double thickness,
                                                            const uint32_t *open_faces,
                                                            size_t count,
                                                            double tolerance,
                                                            CadaclysmBlacksmithProgress progress,
                                                            void *user);

/**
 * `solid`, a sheet, made a solid `thickness` thick -- Fusion's Thicken: its faces,
 * their twins moved `thickness` along the faces' normals (against them for a negative
 * thickness), and a wall round every open edge. Two faces of a folded sheet meet on
 * their offsets' mitre; a closed sheet thickens to a hollow. Free-form (NURBS) faces
 * offset by a fit held to `tolerance`. Null and `last_error` for a thickness a face
 * cannot take (a radius used up, a free-form offset folding over).
 *
 * # Safety
 * `solid` live; `progress` null or valid.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_thicken(const struct CadaclysmBlacksmithSolid *solid,
                                                              double thickness,
                                                              double tolerance,
                                                              CadaclysmBlacksmithProgress progress,
                                                              void *user);

/**
 * Start a sweep path at (`x`, `y`, `z`): where the first piece begins. Free it
 * with [`cadaclysm_blacksmith_sweep_path_free`] once done with it -- sweeping
 * only borrows a path, so a path built here is never consumed on its own.
 */
struct CadaclysmBlacksmithSweepPath *cadaclysm_blacksmith_sweep_path_begin(double x,
                                                                           double y,
                                                                           double z);

/**
 * A straight piece to (`x`, `y`, `z`).
 *
 * # Safety
 * `p` must be a live sweep path.
 */
bool cadaclysm_blacksmith_sweep_path_line_to(struct CadaclysmBlacksmithSweepPath *p,
                                             double x,
                                             double y,
                                             double z);

/**
 * A circular piece turning `angle` radians about the axis through (`cx`, `cy`,
 * `cz`) with direction (`ax`, `ay`, `az`) (need not be unit) -- the axis's own
 * sense is which way it turns, `axis × radial` the direction of travel.
 * `angle` must lie in `(0, 2π]`; the sweep that reads the path is what checks
 * and reports that, not this call.
 *
 * # Safety
 * `p` must be a live sweep path.
 */
bool cadaclysm_blacksmith_sweep_path_arc(struct CadaclysmBlacksmithSweepPath *p,
                                         double cx,
                                         double cy,
                                         double cz,
                                         double ax,
                                         double ay,
                                         double az,
                                         double angle);

/**
 * The sweep path the 2D chain `curve` draws on `frame` (twelve doubles): a
 * line a straight piece, an arc a circular one about `frame`'s z, a Bezier or
 * spline fitted with biarcs -- pairs of arcs tangent to each other and to the
 * curve -- within `tolerance`, so the path is tangent throughout. `open` walks
 * the segments as given; closed, the path also runs back to the start along
 * the side a profile leaves implicit. Refused for a chain with holes or no
 * length. Free the path with [`cadaclysm_blacksmith_sweep_path_free`].
 *
 * # Safety
 * `curve` a live profile; `frame` twelve doubles.
 */
struct CadaclysmBlacksmithSweepPath *cadaclysm_blacksmith_sweep_path_along(const struct CadaclysmBlacksmithProfile *curve,
                                                                           const double *frame,
                                                                           double tolerance,
                                                                           bool open);

/**
 * Release a sweep path. Null is a no-op. Call this whether or not the path
 * was ever swept -- and even after it was swept more than once, since
 * [`cadaclysm_blacksmith_sweep`]/[`cadaclysm_blacksmith_sweep_open`] never
 * take ownership of it.
 *
 * # Safety
 * `p` must have come from this library and not have been freed already.
 */
void cadaclysm_blacksmith_sweep_path_free(struct CadaclysmBlacksmithSweepPath *p);

/**
 * `profile`, drawn on `frame` (its `x`/`y` the profile's own axes), carried
 * along `path` into a closed solid: a straight piece of the path is an
 * extrusion of the profile, a circular piece a revolution about the arc's
 * axis -- so a circle along an arc is an exact torus wall, a rectangle along a
 * line an exact box, nothing approximated. Two straight pieces may meet at a
 * mitred corner; a corner next to a curved piece may not. Caps close the two
 * ends of an open path; a path that returns to its start with matching
 * tangents (a full circle, a mitred loop) has none. `frame`'s origin must be
 * where `path` starts, and `path` must leave square to `frame`'s plane
 * (either face of it). `path` is only *borrowed* here -- it is not consumed,
 * and the same path may be swept again, open or closed, or by another call to
 * this function.
 *
 * # Safety
 * `profile` and `path` live; `frame` twelve doubles.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sweep(const struct CadaclysmBlacksmithProfile *profile,
                                                            const double *frame,
                                                            const struct CadaclysmBlacksmithSweepPath *path);

/**
 * A circle of `radius` swept along `path`, square to its start -- Fusion's Pipe:
 * a rod, or with a positive `thickness` a tube whose walls are that thick. `path`
 * is borrowed, as by [`cadaclysm_blacksmith_sweep`]. Null and `last_error` for a
 * radius that is not positive, a thickness that is negative or reaches the
 * radius, or what the sweep refuses.
 *
 * # Safety
 * `path` live.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_pipe(const struct CadaclysmBlacksmithSweepPath *path,
                                                           double radius,
                                                           double thickness);

/**
 * [`cadaclysm_blacksmith_sweep`] for a curve rather than a face: the profile's
 * own segments carried into a *sheet*, one wall per segment per piece, no
 * caps and no closing wall -- the way [`cadaclysm_blacksmith_extrude_open`] is
 * to [`cadaclysm_blacksmith_extrude`]. The profile need not enclose anything,
 * only have a segment. `path` is only borrowed, as in `sweep`.
 *
 * # Safety
 * As [`cadaclysm_blacksmith_sweep`].
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_sweep_open(const struct CadaclysmBlacksmithProfile *profile,
                                                                 const double *frame,
                                                                 const struct CadaclysmBlacksmithSweepPath *path);

#ifdef __cplusplus
}  // extern "C"
#endif  // __cplusplus

#endif  /* CADACLYSM_BLACKSMITH_H */
