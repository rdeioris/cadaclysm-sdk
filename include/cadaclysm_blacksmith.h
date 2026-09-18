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
 * An outline under construction: a start point and the segments drawn so far.
 * The one mutable object in this library; [`cadaclysm_blacksmith_path_end`]
 * consumes it.
 */
typedef struct CadaclysmBlacksmithPath CadaclysmBlacksmithPath;

/**
 * A closed 2D outline, with holes: what a sweep reads. Immutable.
 */
typedef struct CadaclysmBlacksmithProfile CadaclysmBlacksmithProfile;

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
 * A solid's feature edges as polylines, borrowed from it: polyline `i` is
 * `points[offsets[i] .. offsets[i + 1]]`, three floats a point.
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
 * `count` solids as one AP203 part file, each its own `MANIFOLD_SOLID_BREP`,
 * through `cadaclysm_step_ap::write_breps`. `schema` is the source text of
 * `ap203.exp`; `unit` 0 = metre, 1 = millimetre, 2 = inch, and says what the
 * solids' lengths are. The text is owned: release it with
 * [`cadaclysm_blacksmith_string_free`]. Null and `last_error` on failure.
 *
 * # Safety
 * `solids` `count` live solids; `schema` a NUL-terminated string.
 */
char *cadaclysm_blacksmith_step(const struct CadaclysmBlacksmithSolid *const *solids,
                                size_t count,
                                const char *schema,
                                uint32_t unit);

/**
 * Release a string this library handed over as owned (`cadaclysm_blacksmith_step`).
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
 * order; the closing side is implied. At least three points.
 *
 * # Safety
 * `xy` must point at `2 * count` doubles.
 */
struct CadaclysmBlacksmithProfile *cadaclysm_blacksmith_profile_polygon(const double *xy,
                                                                        size_t count);

/**
 * `profile` with its corners between two straight segments rounded by
 * `radius`, as a new profile: both lines cut back and an exact tangent arc put
 * between them. `corners` null rounds every such corner, the holes' too;
 * otherwise its `count` indices pick the corners of the boundary to round --
 * corner `k` is where segment `k` ends -- and a picked corner that is not
 * between two lines is refused. `open` treats the profile as an open chain,
 * its two ends kept square; closed, the corner where the last segment meets
 * the first (across the implicit closing side) is rounded too. Refused where
 * the radius does not fit.
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
 * boundary centroid, z its outward normal -- what `Workplane::workplane`
 * adopts. `false` if the face's boundary or normal cannot be read.
 *
 * # Safety
 * `solid` live; `out` twelve doubles.
 */
bool cadaclysm_blacksmith_face_frame(const struct CadaclysmBlacksmithSolid *solid,
                                     uint32_t face,
                                     double *out);

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
 * [`cadaclysm_blacksmith_revolve`] without the end caps of a partial turn.
 *
 * # Safety
 * As `revolve`.
 */
struct CadaclysmBlacksmithSolid *cadaclysm_blacksmith_revolve_open(const struct CadaclysmBlacksmithProfile *profile,
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
